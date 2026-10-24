import { formatError } from '../models/ErrUtils';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent, Context } from '@kit.AbilityKit';
import { APP_BUNDLE_NAME } from '../models/HealthTypes';

const TAG = 'BackgroundServiceManager';

/** 启动失败后的重试间隔（毫秒） */
const RETRY_INTERVAL_MS = 5 * 60 * 1000;

/**
 * 「设备不支持 TASK_KEEPING 长时任务」的系统业务错误码。
 *
 * 与 `canIUse()` 的能力查询不同：该查询在部分设备（含本项目测试用的模拟器）
 * 返回 true，但真实调用会被拒。只能以调用结果为准，故在 catch 里按错误码判定。
 */
const ERR_CODE_TASK_KEEPING_UNSUPPORTED = 9800005;

/**
 * 后台长时任务管理器
 * 使用 continuousTask 保证健康监测在后台持续运行
 * 需要 ohos.permission.KEEP_BACKGROUND_RUNNING 权限并在 module.json5 中声明 backgroundModes
 */
export class BackgroundServiceManager {
  private static instance: BackgroundServiceManager;

  static getInstance(): BackgroundServiceManager {
    if (!BackgroundServiceManager.instance) {
      BackgroundServiceManager.instance = new BackgroundServiceManager();
    }
    return BackgroundServiceManager.instance;
  }

  private context?: Context;
  private started: boolean = false;
  /**
   * 最近一次启动/停止失败的原因（业务错误码 + 描述），空串表示无失败。
   *
   * 受管控设备上长时任务会被系统限流（典型 code=9800005 Continuous Task verification failed），
   * 原实现只写一条 hilog 就放弃，且 `started` 保持 false 导致**永不再重试**。
   * 而 `ScreenStateManager` 的动态 commonEvent 订阅在后台不投递事件，
   * 亮屏统计几乎完全依赖该长时任务保活 —— 于是用户的数字会悄悄冻结，
   * 界面上却一切正常、没有任何地方能看出"后台统计已停"。
   *
   * 现把失败原因暴露给设置页展示（见 `Settings` 的「数据管理」卡片）。
   */
  private lastError: string = '';
  /**
   * 长时任务是否被判定为**该设备根本不支持**（而非临时失败）。
   *
   * 实机复现（2026-10-13 模拟器）：`canIUse('...ContinuousTask')` **返回 true**，
   * 但 `startBackgroundRunning()` 抛 `code=9800005 Continuous Task verification failed.
   * TASK_KEEPING background mode only supported in particular device.`。
   *
   * 该错误是**永久性**的设备能力缺失，不是限流/繁忙：重试永远不会成功，
   * 用户也无法通过任何设置解决。所以必须与"临时失败"分开：
   * - 置位后**停止一切重试**（否则每 5 分钟空转一次，无限重复）；
   * - 界面**不显示**红色警告（见 `Settings`）——对着一个用户无法处理的设备限制
   *   反复报警是纯噪音，比不报警更糟。
   */
  private unsupported: boolean = false;

  /**
   * 后台长时任务是否因设备能力缺失而无法启用。
   *
   * 为 true 时界面不应把它显示成故障：前台的亮屏统计照常工作，
   * 只有退到后台后统计才会停止，用户无需处理。
   */
  isUnsupported(): boolean {
    return this.unsupported;
  }

  setContext(context: Context): void {
    this.context = context;
  }

  /** 后台长时任务当前是否在运行 */
  isRunning(): boolean {
    return this.started;
  }

  /** 最近一次后台任务失败的原因；空串表示无失败记录 */
  getLastError(): string {
    return this.lastError;
  }

  async startBackgroundTask(): Promise<void> {
    // 已判定设备不支持：直接返回，不再重复尝试（同上，永久性失败）。
    if (this.unsupported) {
      return;
    }
    if (this.started || !this.context) {
      return;
    }

    if (!this.canUseBackgroundTask()) {
      this.unsupported = true;
      this.lastError = '当前设备不支持后台长时任务';
      hilog.warn(0x0000, TAG, '%{public}s', '当前设备不支持后台长时任务能力');
      return;
    }

    try {
      const wantAgentObj = await wantAgent.getWantAgent({
        wants: [
          {
            bundleName: APP_BUNDLE_NAME,
            abilityName: 'EntryAbility'
          }
        ],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });

      await backgroundTaskManager.startBackgroundRunning(this.context, ['dataTransfer', 'taskKeeping'], wantAgentObj);
      this.started = true;
      this.lastError = '';
      hilog.info(0x0000, TAG, '%{public}s', '后台长时任务已启动');
    } catch (err) {
      // 记录业务错误码，便于界面区分"设备不支持"与"被系统限流"
      const e = err as BusinessError;
      this.lastError = e && e.code !== undefined ? `code=${e.code} ${e.message ?? ''}` : String(err);
      hilog.error(0x0000, TAG, '%{public}s', '启动后台任务失败：' + formatError(err));
      if (e && e.code === ERR_CODE_TASK_KEEPING_UNSUPPORTED) {
        // 永久性设备限制：置位后 scheduleRetry 的所有后续调用都会被
        // startBackgroundTask 开头的 unsupported 守卫挡掉，不再空转。
        this.unsupported = true;
        hilog.warn(0x0000, TAG, '%{public}s', '设备不支持 TASK_KEEPING，停止重试');
        return;
      }
      this.scheduleRetry();
    }
  }

  /**
   * 失败后延迟重试。
   *
   * 长时任务可能被系统限流/回收，稍后重试比"永不重试"好；
   * 用成员字段而非立即递归，避免连续失败时形成定时器风暴。
   */
  private scheduleRetry(): void {
    if (this.retryTimer !== -1) {
      return;
    }
    this.retryTimer = setTimeout(() => {
      this.retryTimer = -1;
      this.startBackgroundTask();
    }, RETRY_INTERVAL_MS);
  }

  /** 供页面/生命周期在合适时机手动触发一次重试（如应用回到前台） */
  retryIfNeeded(): void {
    if (this.unsupported) {
      return;
    }
    if (!this.started) {
      this.startBackgroundTask();
    }
  }

  private retryTimer: number = -1;

  async stopBackgroundTask(): Promise<void> {
    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    if (!this.started || !this.context) {
      return;
    }

    if (!this.canUseBackgroundTask()) {
      this.started = false;
      return;
    }

    try {
      await backgroundTaskManager.stopBackgroundRunning(this.context);
      this.started = false;
      this.lastError = '';
      hilog.info(0x0000, TAG, '%{public}s', '后台长时任务已停止');
    } catch (err) {
      hilog.error(0x0000, TAG, '%{public}s', '停止后台任务失败：' + formatError(err));
    }
  }

  private canUseBackgroundTask(): boolean {
    return canIUse('SystemCapability.ResourceSchedule.BackgroundTaskManager.ContinuousTask');
  }
}
