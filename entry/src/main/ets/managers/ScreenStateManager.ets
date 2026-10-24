import { formatError } from '../models/ErrUtils';
import { commonEventManager, power, BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { UNLOCK_DEDUPE_MS, shouldCountUnlock } from '../models/ScreenStateMath';

const TAG = 'ScreenStateManager';

export interface ScreenStateListener {
  onScreenOn(now: number): void;
  onScreenOff(now: number): void;
  onScreenUnlocked(now: number): void;
}

/**
 * 屏幕状态管理器
 * 通过 commonEvent 动态订阅 + power.isActive 轮询双通道检测手机亮灭屏与解锁：
 * - 订阅通道（SCREEN_ON/SCREEN_OFF/SCREEN_UNLOCKED）在前台即时响应，无需权限；
 * - 轮询通道（power.isActive）是后台兜底——HarmonyOS 动态订阅在应用后台不投递事件，
 *   依赖 KEEP_BACKGROUND_RUNNING 长时任务保持进程存活，周期 poll 检测灭屏→亮屏跳变。
 * 解锁去重：同一亮屏事件（订阅 SCREEN_UNLOCKED 与轮询跳变）通过时间窗去重，只计一次。
 * 局限：进程被杀后计时丢失（与应用内常驻通知一致），应用存活期间统计可靠。
 */
export class ScreenStateManager {
  private static instance: ScreenStateManager;

  static getInstance(): ScreenStateManager {
    if (!ScreenStateManager.instance) {
      ScreenStateManager.instance = new ScreenStateManager();
    }
    return ScreenStateManager.instance;
  }

  private listener: ScreenStateListener | null = null;
  private subscriber: commonEventManager.CommonEventSubscriber | null = null;
  private screenOn: boolean = false;
  private baselineEstablished: boolean = false;
  private lastUnlockAt: number = 0;
  private started: boolean = false;
  /** poll() 调用计数，仅用于日志节流 */
  private pollCount: number = 0;
  /**
   * 订阅代次令牌：createSubscriber 是异步的，stop() 可能在其 resolve 之前被调用。
   * 每次 start()/stop() 自增，resolve 时若令牌已失效说明期间发生过 stop 或重新 start，
   * 此时必须把刚拿到的 subscriber 立刻退订，否则会留下泄漏订阅（stop 后仍回调，
   * 二次 start 还会覆盖 handle 造成解锁重复计数）。
   */
  private subscribeToken: number = 0;

  setListener(listener: ScreenStateListener | null): void {
    this.listener = listener;
  }

  start(): void {
    if (this.started) {
      // 早退分支：screenOn 保持首次 start 时读到的值，不会重新求值。
      // 实机验证（2026-10-10）：这不是隐患 —— 即使缓存值是 stale 的 false，
      // HealthStateManager 的聚合循环每 5s 调 poll()，applyState 会把跳变纠正回来
      // 并回调 onScreenOn 开启会话。保留此日志用于观测重置路径。
      hilog.info(0x0000, TAG, '%{public}s',
        '[start] 已在运行，早退；screenOn(缓存)=' + (this.screenOn ? 'true' : 'false'));
      return;
    }
    this.started = true;
    this.subscribeToken++;
    // 建立基线（不触发回调），避免冷启动把当前亮屏误计为新解锁
    this.screenOn = this.queryActive();
    this.baselineEstablished = true;
    hilog.info(0x0000, TAG, '%{public}s',
      '[start] 首次启动，power.isActive()=' + (this.screenOn ? 'true' : 'false'));
    this.subscribeEvents(this.subscribeToken);
  }

  stop(): void {
    if (!this.started) {
      return;
    }
    this.started = false;
    this.baselineEstablished = false;
    // 自增令牌使在途的 createSubscriber 回调失效（其 resolve 时会自行退订）
    this.subscribeToken++;
    if (this.subscriber) {
      commonEventManager.unsubscribe(this.subscriber, (err: BusinessError) => {
        // `callback?: AsyncCallback<void>` —— err 永远非空，code===0 才是成功，
        // 与 loadContent 同源（见 EntryAbility.loadMainContent 的注释与实机证据）。
        if (err && err.code !== 0) {
          hilog.warn(0x0000, TAG, '%{public}s', '退订屏幕事件失败：' + formatError(err));
        }
      });
      this.subscriber = null;
    }
  }

  isScreenOn(): boolean {
    return this.screenOn;
  }

  /** 主动轮询当前亮灭屏状态，检测状态跳变（后台兜底入口） */
  poll(): void {
    const active = this.queryActive();
    // 节流到状态变化或每 30 次一条，避免 5s 聚合循环刷屏
    this.pollCount++;
    if (active !== this.screenOn || this.pollCount % 30 === 0) {
      hilog.info(0x0000, TAG, '%{public}s',
        '[poll] #' + this.pollCount + ' isActive=' + (active ? 'true' : 'false') +
        ' screenOn=' + (this.screenOn ? 'true' : 'false'));
    }
    this.applyState(active, true);
  }

  private queryActive(): boolean {
    try {
      return power.isActive();
    } catch (err) {
      hilog.warn(0x0000, TAG, '%{public}s', '查询屏幕状态失败：' + formatError(err));
      return this.screenOn;
    }
  }

  private subscribeEvents(token: number): void {
    const subscribeInfo: commonEventManager.CommonEventSubscribeInfo = {
      events: [
        commonEventManager.Support.COMMON_EVENT_SCREEN_ON,
        commonEventManager.Support.COMMON_EVENT_SCREEN_OFF,
        commonEventManager.Support.COMMON_EVENT_SCREEN_UNLOCKED
      ]
    };
    commonEventManager.createSubscriber(subscribeInfo).then((subscriber: commonEventManager.CommonEventSubscriber) => {
      // 期间已 stop() 或重新 start()：本次订阅已过期，立即退订，避免泄漏
      if (token !== this.subscribeToken || !this.started) {
        commonEventManager.unsubscribe(subscriber, (err: BusinessError) => {
          if (err && err.code !== 0) {
            hilog.warn(0x0000, TAG, '%{public}s', '退订过期屏幕事件订阅失败：' + formatError(err));
          }
        });
        hilog.info(0x0000, TAG, '%{public}s', '创建订阅者期间已停止/重启，取消本次订阅');
        return;
      }
      this.subscriber = subscriber;
      commonEventManager.subscribe(subscriber, (err: BusinessError, data: commonEventManager.CommonEventData) => {
        // 同上：AsyncCallback 的 err 永远非空，code===0 即成功。
        if (err && err.code !== 0) {
          hilog.warn(0x0000, TAG, '%{public}s', '接收屏幕事件失败：' + formatError(err));
          return;
        }
        this.handleEvent(data.event);
      });
    }).catch((err: Error) => {
      hilog.warn(0x0000, TAG, '%{public}s', '创建屏幕事件订阅者失败：' + formatError(err));
    });
  }

  private handleEvent(event: string): void {
    hilog.info(0x0000, TAG, '%{public}s', '[handleEvent] 收到 ' + event);
    if (event === commonEventManager.Support.COMMON_EVENT_SCREEN_ON) {
      this.applyState(true, false);
    } else if (event === commonEventManager.Support.COMMON_EVENT_SCREEN_OFF) {
      this.applyState(false, false);
    } else if (event === commonEventManager.Support.COMMON_EVENT_SCREEN_UNLOCKED) {
      this.applyState(true, false);
      this.triggerUnlock();
    }
  }

  private applyState(active: boolean, fromPoll: boolean): void {
    if (!this.baselineEstablished) {
      this.screenOn = active;
      this.baselineEstablished = true;
      hilog.info(0x0000, TAG, '%{public}s',
        '[applyState] 建立基线 active=' + (active ? 'true' : 'false'));
      return;
    }
    if (active === this.screenOn) {
      return;
    }
    this.screenOn = active;
    hilog.info(0x0000, TAG, '%{public}s',
      '[applyState] 跳变 -> ' + (active ? '亮屏' : '灭屏') + '（来源 ' +
      (fromPoll ? 'poll' : 'commonEvent') + '）');
    if (active) {
      if (this.listener) {
        this.listener.onScreenOn(Date.now());
      }
      // 轮询检测到的灭→亮跳变视为一次解锁兜底（后台收不到 SCREEN_UNLOCKED 事件）
      if (fromPoll) {
        this.triggerUnlock();
      }
    } else if (this.listener) {
      this.listener.onScreenOff(Date.now());
    }
  }

  private triggerUnlock(): void {
    const now = Date.now();
    // 去重算术见 models/ScreenStateMath.shouldCountUnlock（有单测锁定）：
    // 订阅 SCREEN_UNLOCKED 与轮询的灭→亮跳变会为同一次解锁各报一次。
    if (!shouldCountUnlock(now, this.lastUnlockAt, UNLOCK_DEDUPE_MS)) {
      return;
    }
    this.lastUnlockAt = now;
    if (this.listener) {
      this.listener.onScreenUnlocked(now);
    }
  }
}
