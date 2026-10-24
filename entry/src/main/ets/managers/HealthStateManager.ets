import { formatError } from '../models/ErrUtils';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  getTodayDateString,
  HealthCapsuleData,
  HealthStatus
} from '../models/HealthTypes';
import { UsageStatsManager } from './UsageStatsManager';
import { SleepManager } from './SleepManager';
import { BackgroundServiceManager } from './BackgroundServiceManager';
import { HealthReminderManager } from './HealthReminderManager';
import { DailyGoalManager } from './DailyGoalManager';
import { AchievementManager } from './AchievementManager';
import HealthFormAbility from '../widget/HealthFormAbility';
import { Context } from '@kit.AbilityKit';
import { ScreenStateManager } from './ScreenStateManager';

const TAG = 'HealthStateManager';
const AGGREGATE_INTERVAL_MS = 5000;
const AGGREGATE_INTERVAL_BACKGROUND_MS = 30000;

/**
 * 健康状态聚合管理器（核心枢纽）
 * - 周期聚合手机亮屏使用时长/剩余限额/健康等级/连续达标天数 → 健康胶囊数据
 * - 前台 5s 聚合、后台降频 30s；跨日即时清零；聚合循环驱动成就/亮屏轮询/表单刷新
 * - 数据无变化时跳过对象分配与通知刷新，避免每 5 秒触发系统级更新
 */
export class HealthStateManager {
  private static instance: HealthStateManager;

  // 子管理器（单例）
  usageManager: UsageStatsManager = UsageStatsManager.getInstance();
  sleepManager: SleepManager = SleepManager.getInstance();
  private backgroundManager: BackgroundServiceManager = BackgroundServiceManager.getInstance();
  private healthReminderManager: HealthReminderManager = HealthReminderManager.getInstance();

  // 全局状态：健康胶囊聚合结果
  private capsuleData: HealthCapsuleData = {
    eyeUsageSeconds: 0,
    remainingMinutes: 180,
    status: HealthStatus.NORMAL,
    streakDays: 0
  };

  // 监听回调（页面订阅胶囊数据变化）
  private stateListeners: Array<(data: HealthCapsuleData) => void> = [];

  private aggregateTimerId: number = -1;
  private hasAggregatedOnce: boolean = false;
  private isForeground: boolean = true;
  /** 本管理器已联动处理跨日的日期（初值取今天，避免启动当天误触发一次联动重置） */
  private lastRolloverDate: string = getTodayDateString();

  static getInstance(): HealthStateManager {
    if (!HealthStateManager.instance) {
      HealthStateManager.instance = new HealthStateManager();
    }
    return HealthStateManager.instance;
  }

  private initialized: boolean = false;

  /**
   * 「各 manager 已载入 prefs」的就绪通知回调表（页面用）。
   *
   * 背景（2026-10-15 实机发现的真实缺陷）：`EntryAbility` 的 manager 初始化挂在
   * 隐私闸门与权限申请之后，冷启动实测顺序是「页面 13.34s 渲染完成 → 14.78s 权限返回
   * → 14.87s manager 才初始化完」。而 HdsTabs 常驻所有 TabContent，切走再切回**不会**
   * 重新触发 `aboutToAppear`，于是页面首帧那次「读到默认值」的结果会被永久烙进 UI
   * （设备 prefs 里 sleepGoalMinutes=360，冷启动后设置页却一直显示 8 小时）。
   *
   * 修法用的是**事件驱动**而非"起个定时器重复取值"：后者只是把竞态窗口猜成 6 秒，
   * 且常驻轮询会在用户拖滑块时把正在拖的值改回去。
   */
  private readyCallbacks: Array<() => void> = [];
  private managersReady: boolean = false;

  /**
   * 注册「manager 就绪」回调。若已就绪则**立即同步调用**（页面注册时多半已就绪）。
   * 页面必须在 `aboutToDisappear` 里配对调用 {@link offReady}，否则会持有已销毁的组件。
   */
  onReady(callback: () => void): void {
    if (this.managersReady) {
      callback();
      return;
    }
    this.readyCallbacks.push(callback);
  }

  /** 解除注册（配对 onReady） */
  offReady(callback: () => void): void {
    const index = this.readyCallbacks.indexOf(callback);
    if (index >= 0) {
      this.readyCallbacks.splice(index, 1);
    }
  }

  /**
   * 广播就绪。由 `EntryAbility.initializeManagers` 在**全部** manager 初始化完成后调用。
   * 幂等：重复调用不会重复广播（重置数据后 `resetAllData` 会再走一遍初始化，
   * 那一刻已注册的页面回调应视为"已消费过"，由页面自己的取值逻辑决定要不要再取一次）。
   */
  notifyReady(): void {
    if (this.managersReady) {
      return;
    }
    this.managersReady = true;
    const callbacks = this.readyCallbacks;
    this.readyCallbacks = [];
    for (let i = 0; i < callbacks.length; i++) {
      try {
        callbacks[i]();
      } catch (err) {
        // 单个页面回调异常不能影响其余回调，更不能影响启动流程
        hilog.error(0x0000, TAG, '%{public}s', '就绪回调执行失败：' + formatError(err));
      }
    }
  }

  setContext(context: Context): void {
    this.backgroundManager.setContext(context);
  }

  /** 前台回调：恢复 5s 高频聚合 */
  onAppForeground(): void {
    this.isForeground = true;
    this.restartAggregationTimer();
  }

  /** 后台回调：降频至 30s 聚合以降低功耗 */
  onAppBackground(): void {
    this.isForeground = false;
    this.restartAggregationTimer();
  }

  async initialize(): Promise<void> {
    if (this.initialized) {
      return;
    }
    this.initialized = true;

    hilog.info(0x0000, TAG, '%{public}s', '初始化健康状态管理器');
    this.usageManager.initialize();
    this.sleepManager.setUsageManager(this.usageManager);
    this.sleepManager.initialize();

    // 初始化健康提醒管理器
    try {
      await this.healthReminderManager.initialize();
    } catch (err) {
      hilog.error(0x0000, TAG, '%{public}s', '初始化健康提醒管理器失败：' + formatError(err));
    }

    // 启动后台长时任务，确保应用在后台仍可被唤醒/保活
    try {
      await this.backgroundManager.startBackgroundTask();
    } catch (err) {
      hilog.error(0x0000, TAG, '%{public}s', '启动后台任务失败：' + formatError(err));
    }

    // 启动全局轮询：前台每5秒聚合一次，后台降频至30秒以减少功耗
    this.restartAggregationTimer();

    // 立即聚合一次，避免首次进入页面 5 秒内显示默认数据
    this.aggregateState();
  }

  /** 按前后台状态重启聚合定时器（前台 5s / 后台 30s） */
  private restartAggregationTimer(): void {
    if (this.aggregateTimerId >= 0) {
      clearInterval(this.aggregateTimerId);
      this.aggregateTimerId = -1;
    }
    if (!this.initialized) {
      return;
    }
    const interval = this.isForeground ? AGGREGATE_INTERVAL_MS : AGGREGATE_INTERVAL_BACKGROUND_MS;
    this.aggregateTimerId = setInterval(() => {
      this.aggregateState();
    }, interval);
  }

  /** 聚合一次健康状态并通知监听者 */
  aggregateState(): void {
    // 跨日即时清零：应用运行中（前后台 5s/30s 聚合循环）检测日期变化，今日统计立即归零
    this.checkDateRollover();

    // 后台兜底：轮询亮灭屏状态（HarmonyOS 动态订阅在应用后台不投递事件，依赖
    // KEEP_BACKGROUND_RUNNING 长时任务保活；power.isActive 无需权限，灭→亮跳变计一次解锁）
    ScreenStateManager.getInstance().poll();

    // 周期性重算进度型成就（专注分钟/次数、连续达标天数），无需等待重启或跨日
    AchievementManager.getInstance().refreshAchievements();

    // 手机亮屏时长（真实数据）
    const selfUsage = this.usageManager.getSelfUsageMinutes();
    // 总限额 = 配置的每日总限额（与亮屏用量同一口径，2026-08-09 起不再限定本应用）
    const totalLimit = this.usageManager.getTotalDailyLimitMinutes();
    const remainingMinutes = Math.max(0, totalLimit - selfUsage);

    // 综合健康状态（基于剩余限额时间）
    let status = HealthStatus.NORMAL;
    if (remainingMinutes <= 0) {
      status = HealthStatus.EMERGENCY;
    } else if (remainingMinutes <= 30) {
      status = HealthStatus.WARNING;
    }

    const nextEyeUsageSeconds = selfUsage * 60;
    const nextRemainingMinutes = Math.floor(remainingMinutes);
    const nextStreakDays = this.usageManager.getStreakDays();

    // 数据未变化时跳过对象分配、通知与卡片刷新，避免每 5 秒触发系统级更新
    const changed = !this.hasAggregatedOnce ||
      nextEyeUsageSeconds !== this.capsuleData.eyeUsageSeconds ||
      nextRemainingMinutes !== this.capsuleData.remainingMinutes ||
      status !== this.capsuleData.status ||
      nextStreakDays !== this.capsuleData.streakDays;

    this.hasAggregatedOnce = true;
    if (!changed) {
      return;
    }

    this.capsuleData = {
      eyeUsageSeconds: nextEyeUsageSeconds,
      remainingMinutes: nextRemainingMinutes,
      status: status,
      streakDays: nextStreakDays
    };
    this.notifyListeners();
    HealthFormAbility.updateAllForms();
  }

  /**
   * 跨日检测并联动清零：日期变化时同步重置 使用统计/睡眠今日值/每日目标
   * 由聚合循环与页面 tick 周期性调用
   *
   * ⚠️ 联动判据**必须由本管理器自己比对日期**，不能沿用 `usageManager.checkDateRollover()`
   * 的返回值：`UsageStatsManager` 有另外三处独立调用点（30s 刷新定时器、`onScreenOn`、
   * `initialize` 路径），任意一处先跑到都会把 `currentDate` 推进到今天并返回 true，
   * 而那个返回值在那些调用点被丢弃 —— 于是本方法随后拿到 false，
   * `SleepManager`/`DailyGoalManager`/`AchievementManager` 的跨日重置**当天永远不会执行**
   * （直到下次冷启动 initialize）。实测最可能的触发者是"过零点后第一次亮屏解锁"：
   * `onScreenOn` 先消费掉这次跨日。
   *
   * 改为：先无条件让 usageManager 自行完成今日统计清零（幂等，已清过则返回 false），
   * 再按**自己的**日期判据决定是否向下游联动。
   */
  checkDateRollover(): void {
    // 幂等：今日已清零时内部直接返回 false，无需关心返回值
    this.usageManager.checkDateRollover();

    const today = getTodayDateString();
    if (today === this.lastRolloverDate) {
      return;
    }
    this.lastRolloverDate = today;
    this.sleepManager.onDateChanged();
    DailyGoalManager.getInstance().onDateChanged();
    // 跨日时按昨日（已完成的日）真实解锁次数评估"单日解锁少于 N 次"成就
    AchievementManager.getInstance().checkUnlockAchievements();
  }

  addStateListener(listener: (data: HealthCapsuleData) => void): void {
    this.stateListeners.push(listener);
  }

  removeStateListener(listener: (data: HealthCapsuleData) => void): void {
    const index = this.stateListeners.indexOf(listener);
    if (index >= 0) {
      this.stateListeners.splice(index, 1);
    }
  }

  private notifyListeners(): void {
    this.stateListeners.forEach(listener => listener(this.capsuleData));
  }

  getCapsuleData(): HealthCapsuleData {
    return this.capsuleData;
  }

  /** 销毁：停止聚合定时器、后台长时任务与屏幕状态监听 */
  destroy(): void {
    if (this.aggregateTimerId >= 0) {
      clearInterval(this.aggregateTimerId);
      this.aggregateTimerId = -1;
    }
    this.stateListeners.length = 0;
    this.backgroundManager.stopBackgroundTask();
    ScreenStateManager.getInstance().stop();
    // ⚠️ 必须复位 initialized，否则能力被销毁但进程存活时（本应用申请了 KEEP_BACKGROUND_RUNNING
    // 长时任务，这种组合是存在的），下次拉起会在 initialize() 的守卫处直接 return ——
    // ScreenStateManager.start() 永不再被调用、聚合定时器也没重建，于是亮灭屏事件与轮询
    // **双通道同时死掉**，亮屏统计从此刻起不再累计（records 只能由 onScreenOff 写入，而回调不再来）。
    // 复位后下一次 initialize() 会重新接线并重新求值屏幕状态，是自愈的。
    this.initialized = false;
    // 就绪状态一并复位：能力销毁后能力会被重新创建，manager 会重新载入 prefs，
    // 此时残留的 managersReady=true 会让重新注册的页面回调被立刻（用旧内存态）调用。
    this.managersReady = false;
    this.readyCallbacks.length = 0;
  }
}
