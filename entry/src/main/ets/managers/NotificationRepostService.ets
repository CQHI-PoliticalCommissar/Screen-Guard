import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';
import { OngoingReminderScheduler } from './OngoingReminderScheduler';

const TAG = 'NotificationRepostService';
const POLLING_INTERVAL_MS = 30000; // 30秒检查一次
/** 空闲降频间隔：连续若干周期无任何重发时改用 5 分钟检查，把后台唤醒次数降到 1/10 */
const IDLE_POLLING_INTERVAL_MS = 300000;
/** 连续多少个周期"零重发"后进入空闲降频 */
const IDLE_CYCLES_THRESHOLD = 3;
const REPOST_COOLDOWN_MS = 600000; // 10分钟重发冷却，防止「删除-重发」死循环

// 通知类型枚举（也是各提醒在通知栏中的唯一 ID）
export enum NotificationType {
  SEDENTARY = 1001,      // 久坐提醒
  EYE = 1002,            // 用眼提醒
  WATER = 1003,          // 喝水提醒
  BEDTIME = 1004,        // 睡前提醒
  DOWNTIME = 1005,       // 停用时间提醒
  DOWNTIME_ALERT = 1006, // 停用时间预警
  TOTAL_LIMIT_50 = 1007, // 每日限额 50% 预警
  TOTAL_LIMIT_80 = 1008, // 每日限额 80% 预警
  TOTAL_LIMIT_100 = 1009, // 每日限额 100% 预警
  EYE_REST = 1010,       // 护眼休息提醒（专注结束后的休息引导）
  FOCUS = 1011,          // 专注完成提醒
  CUSTOM_BASE = 2000     // 自定义提醒起始 ID（后续自定义项从该基数递增分配）
}

// 通知重新发布回调类型
type RepostCallback = (notificationId: number) => Promise<boolean>;

/**
 * 通知重新发布服务
 * 使用定时轮询机制检查通知是否被删除，自动重新发布
 */
export class NotificationRepostService {
  private static instance: NotificationRepostService;
  private registeredCallbacks: Map<number, RepostCallback> = new Map();
private pollingTimerId: number = -1;
  private isPolling: boolean = false;
  /** 连续零重发的周期数，达到阈值后轮询降频 */
  private idleCycles: number = 0;
  /** 当前生效的轮询间隔（用于降频/恢复时重设定时器） */
  private currentIntervalMs: number = POLLING_INTERVAL_MS;
  private lastRepostTimes: Map<number, number> = new Map();
  private repostingIds: Set<number> = new Set();

  static getInstance(): NotificationRepostService {
    if (!NotificationRepostService.instance) {
      NotificationRepostService.instance = new NotificationRepostService();
    }
    return NotificationRepostService.instance;
  }

/**
   * 启动定时轮询检查通知状态
   */
  startPolling(): void {
    if (this.isPolling) {
      hilog.info(0x0000, TAG, '%{public}s', '[轮询] 已在运行中，跳过');
      return;
    }

    this.isPolling = true;
    this.currentIntervalMs = POLLING_INTERVAL_MS;
    this.armPollingTimer();
    hilog.info(0x0000, TAG, '%{public}s', '[轮询] 已启动，间隔=' + this.currentIntervalMs + 'ms');
  }

  /**
   * 实际设定定时器。所有轮询状态变化都经此重设，避免多份 setInterval 失控。
   *
   * isPolling 守卫不可省：checkNotifications 是 async，getActiveNotifications() 的 await
   * 期间可能发生 stopPolling()（onDestroy 的 clearAllCallbacks、最后一个回调注销）。
   * await 返回后 updatePollingFrequency 仍会走到这里，若不加守卫就会在 stopPolling
   * 之后重新 setInterval —— 造出一个 isPolling=false 却仍在跑的"僵尸定时器"，
   * 永不停止（registeredCallbacks 已清空时 checkNotifications 每轮首行就 return，
   * 但定时器本身一直唤醒），正是本服务 2026-10-02 轮降频改造想消除的后台空耗。
   */
  private armPollingTimer(): void {
    if (this.pollingTimerId >= 0) {
      clearInterval(this.pollingTimerId);
      this.pollingTimerId = -1;
    }
    if (!this.isPolling) {
      return;
    }
    this.pollingTimerId = setInterval(() => {
      this.checkNotifications().catch((err: Error) => {
        hilog.error(0x0000, TAG, '%{public}s', '[轮询] 检查通知失败: ' + err.message);
      });
    }, this.currentIntervalMs);
  }

  /**
   * 停止定时轮询
   */
  stopPolling(): void {
    if (this.pollingTimerId >= 0) {
      clearInterval(this.pollingTimerId);
      this.pollingTimerId = -1;
    }
    this.isPolling = false;
    this.idleCycles = 0;
    this.currentIntervalMs = POLLING_INTERVAL_MS;
    hilog.info(0x0000, TAG, '%{public}s', '[轮询] 已停止');
  }

  /**
   * 按本轮是否发生重发，切换轮询频率。
   *
   * 背景：本服务注册的内置提醒 / 睡前 / 停用 / 限额预警回调在初始化时一律注册且从不解绑，
   * 而常驻提醒由 OngoingReminderScheduler 自带 10s 定时器持续刷新、预警文案也只在越线时才有意义。
   * 因此绝大多数周期里没有任何通知需要重发，30s 一次的 getActiveNotifications() 纯属空转。
   * 连续 3 个周期零重发即降频到 5 分钟；一旦再次发生重发立即回到 30s。
   * 注意不能直接停轮询：提醒被重新开启后没有任何发布点会回调 registerCallback，
   * 彻底停摆将丢失这层"通知被误删后重发"的保险。
   *
   * @param reposted 本轮触发重发的通知数量
   */
  private updatePollingFrequency(reposted: number): void {
    const wantIdle = reposted === 0;
    if (wantIdle) {
      this.idleCycles = Math.min(this.idleCycles + 1, IDLE_CYCLES_THRESHOLD);
    } else {
      this.idleCycles = 0;
    }
    const wantInterval = this.idleCycles >= IDLE_CYCLES_THRESHOLD ? IDLE_POLLING_INTERVAL_MS : POLLING_INTERVAL_MS;
    if (wantInterval === this.currentIntervalMs) {
      return;
    }
    this.currentIntervalMs = wantInterval;
    this.armPollingTimer();
    hilog.info(0x0000, TAG, '%{public}s', '[轮询] 频率切换，间隔=' + wantInterval + 'ms');
  }

  /**
   * 检查所有注册的通知是否还在活跃列表中
   */
private async checkNotifications(): Promise<void> {
    if (this.registeredCallbacks.size === 0) {
      return;
    }

    // 本轮触发重发的通知数量，用于决定下一轮是保持 30s 还是降到 5min
    let reposted = 0;
    try {
      const activeNotifications = await notificationManager.getActiveNotifications();
      const activeIds = new Set(activeNotifications.map(n => n.id));

      // 检查每个注册的通知是否还在活跃列表中
      this.registeredCallbacks.forEach((callback: RepostCallback, notificationId: number) => {
        // 常驻提醒由 OngoingReminderScheduler 的定时器持续更新，无需轮询重发
        if (OngoingReminderScheduler.getInstance().isScheduled(notificationId)) {
          return;
        }
        // 正在展示或仍在排期中（未触发）的通知不需要重发
        if (activeIds.has(notificationId)) {
          return;
        }
        // 该通知正在重发中，避免并发重复发布
        if (this.repostingIds.has(notificationId)) {
          return;
        }
        const now = Date.now();
        const lastRepost = this.lastRepostTimes.get(notificationId) ?? 0;
        if (now - lastRepost < REPOST_COOLDOWN_MS) {
          return;
        }
        this.repostingIds.add(notificationId);
        this.lastRepostTimes.set(notificationId, now);
        reposted++;
        // 措辞保持中性：缺席既可能是被删除，也可能是该提醒本就处于关闭态从未发布
        hilog.info(0x0000, TAG, '%{public}s', `[检查] 通知 ${notificationId} 不在活跃列表中，尝试重发`);
        this.handleNotificationDeleted(notificationId, callback).catch((err: Error) => {
          hilog.error(0x0000, TAG, '%{public}s', '[重发] 异常: ' + err.message);
        }).finally(() => {
          this.repostingIds.delete(notificationId);
        });
      });
    } catch (err) {
      const error = err as BusinessError;
      hilog.error(0x0000, TAG, '%{public}s', '[检查] 获取活跃通知失败: code=' + error.code + ', message=' + error.message);
    }
    // 上面 await 期间可能已 stopPolling（进程销毁 / 回调全部注销）。
    // 此时不应再改轮询频率，否则会经 armPollingTimer 在停止后重新拉起定时器。
    if (!this.isPolling) {
      return;
    }
    this.updatePollingFrequency(reposted);
  }

  /**
   * 注册通知重新发布回调
   * @param notificationId 通知ID（对应 NotificationType）
   * @param callback 重新发布回调函数
   */
  registerCallback(notificationId: number, callback: RepostCallback): void {
    this.registeredCallbacks.set(notificationId, callback);
    // 懒启动：仅在存在待守护的通知时轮询，避免空轮询空耗
    if (!this.isPolling) {
      this.startPolling();
    }
    hilog.info(0x0000, TAG, '%{public}s', `[注册回调] 通知ID=${notificationId} 已注册重发回调`);
  }

  /**
   * 取消注册通知重新发布回调
   */
  unregisterCallback(notificationId: number): void {
    this.registeredCallbacks.delete(notificationId);
    this.lastRepostTimes.delete(notificationId);
    this.repostingIds.delete(notificationId);
    // 最后一个回调注销后停止轮询，减少后台空转
    if (this.registeredCallbacks.size === 0) {
      this.stopPolling();
    }
    hilog.info(0x0000, TAG, '%{public}s', `[取消注册] 通知ID=${notificationId} 已取消重发回调`);
  }

  /**
   * 处理通知删除事件
   */
  private async handleNotificationDeleted(notificationId: number, callback: RepostCallback): Promise<void> {
    hilog.info(0x0000, TAG, '%{public}s', `[重发通知] 开始重新发布通知，ID=${notificationId}`);
    try {
      const success = await callback(notificationId);
      if (success) {
        hilog.info(0x0000, TAG, '%{public}s', `[重发通知] 成功，ID=${notificationId}`);
      } else {
        hilog.warn(0x0000, TAG, '%{public}s', `[重发通知] 失败，ID=${notificationId}`);
      }
    } catch (err) {
      const error = err as BusinessError;
      hilog.error(0x0000, TAG, '%{public}s', `[重发通知] 异常: code=${error.code}, message=${error.message}`);
    }
  }

  /**
   * 清理所有注册的回调并停止轮询
   */
  clearAllCallbacks(): void {
    this.stopPolling();
    this.registeredCallbacks.clear();
    this.lastRepostTimes.clear();
    this.repostingIds.clear();
    hilog.info(0x0000, TAG, '%{public}s', '[清理] 已清除所有重发回调并停止轮询');
  }
}