import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { PreferenceManager, PreferenceEntry } from './PreferenceManager';
import { NotificationType } from './NotificationRepostService';
import { OngoingReminderScheduler } from './OngoingReminderScheduler';
import { UsageStatsManager } from './UsageStatsManager';
import { SleepManager } from './SleepManager';

const TAG = 'ReminderService';
const PREFS_KEY_BEDTIME_HOUR = 'bedtime_hour';
const PREFS_KEY_BEDTIME_MINUTE = 'bedtime_minute';
const PREFS_KEY_BEDTIME_ENABLED = 'bedtime_enabled';

export interface BedtimeConfig {
  hour: number;
  minute: number;
  enabled: boolean;
}

/**
 * 提醒服务
 * 统一封装常驻通知提醒，支持睡前、护眼休息、专注完成等多种提醒。
 * 所有提醒均为通知栏常驻通知（isOngoing），由 OngoingReminderScheduler 驱动，
 * 纯 notificationManager.publish，不依赖代理提醒/系统日历/特殊权限。
 */
export class ReminderService {
  private static instance: ReminderService;
  private context: common.Context | null = null;
  private initialized: boolean = false;
  private usageManager: UsageStatsManager = UsageStatsManager.getInstance();

  static getInstance(): ReminderService {
    if (!ReminderService.instance) {
      ReminderService.instance = new ReminderService();
    }
    return ReminderService.instance;
  }

  setContext(context: common.Context): void {
    this.context = context;
  }

  /** 初始化：注册通知删除重发回调（幂等） */
  async init(): Promise<void> {
    if (this.initialized) {
      return;
    }
    this.initialized = true;

    if (!this.context) {
      hilog.warn(0x0000, TAG, '%{public}s', '[初始化] 未设置 context');
    }

    // ⚠️ 刻意**不**为睡前/停用提醒注册 NotificationRepostService 重发回调。
    // 回调体只会返回 OngoingReminderScheduler.isScheduled(...)，
    // 而该守卫与回调的触发前提同源 —— 启用中时被守卫挡掉、关闭时回调体第一行就 return false，
    // 永远不可能真正重发一条通知。常驻通知本身由调度引擎持续更新且不可移除。

    hilog.info(0x0000, TAG, '%{public}s', '[初始化] 完成');
  }

  /** 读取睡前提醒配置（默认 22:00 关闭） */
  getBedtimeReminderTime(): BedtimeConfig {
    const pref = PreferenceManager.getInstance();
    return {
      hour: pref.getNumber(PREFS_KEY_BEDTIME_HOUR, 22),
      minute: pref.getNumber(PREFS_KEY_BEDTIME_MINUTE, 0),
      enabled: pref.getBoolean(PREFS_KEY_BEDTIME_ENABLED, false)
    };
  }

  /**
   * 调度睡前提醒（每日常驻通知）
   * 实际触发时间 = 设定时间 − 睡前提醒提前量（bedtimeReminderOffsetMinutes），
   * 偏好中仍保存用户设定的原始时间，仅注册时向前平移
   */
  async scheduleBedtimeReminder(hour: number, minute: number, enabled: boolean): Promise<boolean> {
    const pref = PreferenceManager.getInstance();
    const entries: PreferenceEntry[] = [
      { key: PREFS_KEY_BEDTIME_HOUR, value: hour },
      { key: PREFS_KEY_BEDTIME_MINUTE, value: minute },
      { key: PREFS_KEY_BEDTIME_ENABLED, value: enabled }
    ];
    // 不挂 .catch：PreferenceManager.setBatch 内部已 catch 并记日志、从不 reject
    pref.setBatch(entries);

    const scheduler = OngoingReminderScheduler.getInstance();
    if (!enabled) {
      scheduler.unregister(NotificationType.BEDTIME);
      return true;
    }

    const offsetMinutes = SleepManager.getInstance().getSleepPreferences().bedtimeReminderOffsetMinutes;
    const effectiveTotal = (hour * 60 + minute - offsetMinutes + 1440) % 1440;
    const effectiveHour = Math.floor(effectiveTotal / 60);
    const effectiveMinute = effectiveTotal % 60;

    return scheduler.register({
      notificationId: NotificationType.BEDTIME,
      title: '睡前提醒',
      content: '放下手机，为健康睡眠做准备吧',
      unremovable: true,
      banner: true,
      dailyHour: effectiveHour,
      dailyMinute: effectiveMinute
    });
  }

  /**
   * 取消睡前提醒
   */
  async cancelBedtimeReminder(): Promise<void> {
    OngoingReminderScheduler.getInstance().unregister(NotificationType.BEDTIME);
  }

  /**
   * 调度停用时间提醒（每日常驻通知）
   */
  async scheduleDowntimeReminder(startHour: number, startMinute: number, enabled: boolean): Promise<boolean> {
    const scheduler = OngoingReminderScheduler.getInstance();
    if (!enabled) {
      scheduler.unregister(NotificationType.DOWNTIME);
      return true;
    }
    return scheduler.register({
      notificationId: NotificationType.DOWNTIME,
      title: '免打扰时段提醒',
      content: '减少屏幕使用，保护身心健康',
      unremovable: true,
      banner: true,
      dailyHour: startHour,
      dailyMinute: startMinute
    });
  }

  /**
   * 取消停用时间提醒
   */
  async cancelDowntimeReminder(): Promise<void> {
    OngoingReminderScheduler.getInstance().unregister(NotificationType.DOWNTIME);
  }

  /**
   * 调度护眼休息提醒（从现在起 N 秒后触发的一次性常驻通知）
   */
  async scheduleEyeRestReminder(triggerSeconds: number): Promise<boolean> {
    if (triggerSeconds <= 0) {
      return false;
    }
    return OngoingReminderScheduler.getInstance().register({
      notificationId: NotificationType.EYE_REST,
      title: '该让眼睛休息一下了',
      content: '眺望远方 20 秒，缓解视疲劳',
      unremovable: true,
      banner: true,
      oneShotSeconds: triggerSeconds
    });
  }

  /**
   * 取消护眼休息提醒
   */
  async cancelEyeRestReminder(): Promise<void> {
    OngoingReminderScheduler.getInstance().unregister(NotificationType.EYE_REST);
  }

  /**
   * 调度专注完成提醒（一次性常驻通知，专注结束后触发）
   * @param focusMinutes 专注时长（分钟）
   */
  async scheduleFocusCompleteReminder(focusMinutes: number): Promise<boolean> {
    return OngoingReminderScheduler.getInstance().register({
      notificationId: NotificationType.FOCUS,
      title: '专注时间结束',
      content: `本次专注 ${focusMinutes} 分钟，休息一下吧`,
      unremovable: true,
      banner: true,
      oneShotSeconds: focusMinutes * 60
    });
  }

  /**
   * 取消所有专注完成提醒
   */
  async cancelAllFocusReminders(): Promise<void> {
    OngoingReminderScheduler.getInstance().unregister(NotificationType.FOCUS);
  }

  /**
   * 取消当前应用已发布的全部提醒（睡前 + 停用时间 + 护眼 + 专注）
   */
  cancelAllReminders(): void {
    this.cancelBedtimeReminder();
    this.cancelDowntimeReminder();
    this.cancelEyeRestReminder();
    this.cancelAllFocusReminders();
    hilog.info(0x0000, TAG, '%{public}s', '[取消全部提醒] 已完成');
  }
}

