/**
 * 专注模式管理器
 * 基于番茄钟理论，帮助用户集中注意力
 * 游戏化设计：专注成功获得积分，累积成就
 */
import { formatError } from '../models/ErrUtils';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { STREAK_BONUS_CAP, computeFocusPoints, computeLongestStreak } from '../models/FocusStatsMath';
import { PreferenceManager, PreferenceEntry } from './PreferenceManager';
import { ReminderService } from './ReminderService';
import { HISTORY_RETENTION_MS } from '../models/HealthTypes';

const TAG = 'FocusModeManager';
const PREFS_KEY_FOCUS_HISTORY = 'focus_history';
const PREFS_KEY_FOCUS_POINTS = 'focus_points';
const PREFS_KEY_FOCUS_STREAK = 'focus_streak';
const PREFS_KEY_FOCUS_DURATION = 'focus_duration_minutes';
export const POMODORO_DURATION_MINUTES = 25;
export const SHORT_BREAK_MINUTES = 5;
export const LONG_BREAK_MINUTES = 15;
const MIN_FOCUS_DURATION_MINUTES = 5;
const MAX_FOCUS_DURATION_MINUTES = 180;
const SESSIONS_BEFORE_LONG_BREAK = 4;
const EYE_REST_DELAY_SECONDS = 60;

interface FocusSession {
  startTime: number;
  endTime: number;
  durationMinutes: number;
  completed: boolean;
  pointsEarned: number;
  interrupted: boolean;
}

export interface FocusStats {
  totalSessions: number;
  completedSessions: number;
  totalMinutes: number;
  totalPoints: number;
  currentStreak: number;
  longestStreak: number;
  todaySessions: number;
  todayMinutes: number;
  weekSessions: number;
  weekMinutes: number;
}

interface FocusModeState {
  isActive: boolean;
  startTime: number;
  durationMinutes: number;
  remainingSeconds: number;
  sessionType: 'focus' | 'short_break' | 'long_break';
  completedSessionsInCycle: number;
}

interface FocusSessionBackup {
  startTime: number;
  endTime: number;
  durationMinutes: number;
  completed: boolean;
  pointsEarned: number;
  interrupted: boolean;
}

export interface FocusBackupData {
  history: FocusSessionBackup[];
  totalPoints: number;
  currentStreak: number;
  focusDurationMinutes: number;
}

export class FocusModeManager {
  private static instance: FocusModeManager;

  static getInstance(): FocusModeManager {
    if (!FocusModeManager.instance) {
      FocusModeManager.instance = new FocusModeManager();
    }
    return FocusModeManager.instance;
  }

  private focusHistory: FocusSession[] = [];
  private totalPoints: number = 0;
  private currentStreak: number = 0;
  private longestStreak: number = 0;
  private focusDurationMinutes: number = POMODORO_DURATION_MINUTES;
  private statsCache: FocusStats | null = null;
  private statsCacheDay: number = -1;

  private currentState: FocusModeState = {
    isActive: false,
    startTime: 0,
    durationMinutes: 0,
    remainingSeconds: 0,
    sessionType: 'focus',
    completedSessionsInCycle: 0
  };

  private timerId: number = -1;
  private onTickCallback: ((remainingSeconds: number) => void) | null = null;
  private onCompleteCallback: (() => void) | null = null;
  private initialized: boolean = false;
  private reminderService: ReminderService = ReminderService.getInstance();

  initialize(): void {
    if (this.initialized) {
      return;
    }
    hilog.info(0x0000, TAG, '%{public}s', '[初始化] 专注模式管理器');
    this.loadFromPreferences();
    this.initialized = true;
  }

  private loadFromPreferences(): void {
    try {
      const pref = PreferenceManager.getInstance();

      const historyJson = pref.getString(PREFS_KEY_FOCUS_HISTORY, '');
      if (historyJson) {
        const parsed = JSON.parse(historyJson) as FocusSession[];
        if (Array.isArray(parsed)) {
          this.focusHistory = parsed;
          this.cleanupOldHistory();
        }
      } else {
        // 键已删除（「重置所有数据」）：必须清空内存态。
        // 与 SleepManager.loadPreferences 同源缺陷（那里 2026-08-10 轮已补过 else）。
        // 当前 initialize() 有 initialized 守卫、冷启动路径本就读得到值，故此前不可达；
        // 但守卫一旦去掉、或将来加一条复用本方法的重新载入路径，就会重演
        // 「重置后专注历史/积分仍显示旧值直到进程重启」。
        this.focusHistory = [];
      }

      this.totalPoints = pref.getNumber(PREFS_KEY_FOCUS_POINTS, 0);
      this.currentStreak = pref.getNumber(PREFS_KEY_FOCUS_STREAK, 0);
      const duration = pref.getNumber(PREFS_KEY_FOCUS_DURATION, POMODORO_DURATION_MINUTES);
      this.focusDurationMinutes = this.safeClampFocusDuration(duration, POMODORO_DURATION_MINUTES);
      // ⚠️ 这里必须**直接赋值**而不是走 calculateLongestStreak（它是 Math.max(旧值, 新算值)）。
      // totalPoints / currentStreak 都被整体覆盖，唯独最长连击取 max → 同一进程内导入旧备份时
      // 它会保留恢复前的更大值，与刚恢复进来的历史自相矛盾
      // （今天已连 8 场 → 导入只有 3 连击的备份 → 页面「最长连续 8」而历史列表只有 3）。
      // 冷启动导入不受影响，是因为 exportData 不导出 longestStreak、内存里本就是 0。
      this.longestStreak = computeLongestStreak(this.focusHistory);
      this.statsCache = null;
    } catch (err) {
      hilog.error(0x0000, TAG, '%{public}s', '加载专注历史失败：' + formatError(err));
    }
  }

  private cleanupOldHistory(): void {
    const cutoff = Date.now() - HISTORY_RETENTION_MS;
    const originalLength = this.focusHistory.length;
    this.focusHistory = this.focusHistory.filter(session => session.startTime >= cutoff);
    if (this.focusHistory.length !== originalLength) {
      this.saveToPreferences();
    }
  }

  private saveToPreferences(): void {
    const entries: PreferenceEntry[] = [
      { key: PREFS_KEY_FOCUS_HISTORY, value: JSON.stringify(this.focusHistory) },
      { key: PREFS_KEY_FOCUS_POINTS, value: this.totalPoints },
      { key: PREFS_KEY_FOCUS_STREAK, value: this.currentStreak },
      { key: PREFS_KEY_FOCUS_DURATION, value: this.focusDurationMinutes }
    ];
    // setBatch 是 async 函数，函数体内的任何异常（含同步 throw）都会转成 rejected Promise，
    // 因此外层 try/catch **永远不会执行**——原写法是一段看起来有兜底、实际不生效的死代码。
    // 真正的错误日志由 PreferenceManager.setBatch 内部那一条输出（带上下文，见其 catch）。
    PreferenceManager.getInstance().setBatch(entries);
  }

/**
   * 专注时长安全钳位（与 SleepManager.safeClamp 同口径）
   * 非有限数（NaN / Infinity）回退 fallback，其余钳到 [MIN, MAX] 并取整。
   * 裸 `Math.max/min` 遇 NaN 会原样返回 NaN：一旦写进偏好就长期驻留，
   * 且 startFocusSession 会用 NaN 计算 remainingSeconds，使 1s 定时器首次 tick
   * 就判定会话完成、白送一次完成记录与积分。
   */
  private safeClampFocusDuration(value: number, fallback: number): number {
    if (!Number.isFinite(value)) {
      return fallback;
    }
    return Math.max(MIN_FOCUS_DURATION_MINUTES, Math.min(MAX_FOCUS_DURATION_MINUTES, Math.round(value)));
  }

  /**
   * 开始专注会话
   * @param durationMinutes 未传入时使用用户配置的专注时长（默认 25 分钟）
   * @returns true 成功启动，false 被拒绝（已有会话进行中）
   */
  startFocusSession(durationMinutes?: number): boolean {
    if (this.currentState.isActive) {
      hilog.warn(0x0000, TAG, '已有专注会话进行中');
      return false;
    }
    // 入参必须钳位：非正/NaN 时 remainingSeconds <= 0，1s 定时器首次 tick 就判定会话完成，
    // 白送一次「完成」记录与积分；超大值则会让「专注完成」一次性常驻通知长期不触发
    const raw = durationMinutes ?? this.focusDurationMinutes;
    const duration = this.safeClampFocusDuration(raw, this.focusDurationMinutes);

    this.currentState = {
      isActive: true,
      startTime: Date.now(),
      durationMinutes: duration,
      remainingSeconds: duration * 60,
      sessionType: 'focus',
      completedSessionsInCycle: this.currentState.completedSessionsInCycle
    };

    // 常驻通知提醒：专注开始即排一条「专注完成」倒计时通知，结束瞬间转为 ⏰ 提醒
    this.reminderService.cancelAllFocusReminders();
    this.reminderService.cancelEyeRestReminder();
    this.reminderService.scheduleFocusCompleteReminder(duration);

    this.startTimer();
    hilog.info(0x0000, TAG, '%{public}s', `[专注开始] 时长: ${duration} 分钟`);
    return true;
  }

  /**
   * 获取用户配置的专注时长（分钟）
   */
  getFocusDurationMinutes(): number {
    return this.focusDurationMinutes;
  }

  /**
   * 设置用户配置的专注时长（分钟），立即持久化
   */
  setFocusDurationMinutes(minutes: number): void {
    this.focusDurationMinutes = this.safeClampFocusDuration(minutes, this.focusDurationMinutes);
    this.saveToPreferences();
    hilog.info(0x0000, TAG, '%{public}s', `[专注时长] 已设置为 ${this.focusDurationMinutes} 分钟`);
  }

  /**
   * 开始休息时间
   * @returns true 成功启动，false 被拒绝（已有会话进行中）
   */
  startBreak(breakType: 'short' | 'long'): boolean {
    if (this.currentState.isActive) {
      hilog.warn(0x0000, TAG, '%{public}s', '已有会话进行中，无法开始休息');
      return false;
    }

    const durationMinutes = breakType === 'short' ? SHORT_BREAK_MINUTES : LONG_BREAK_MINUTES;

    this.currentState = {
      isActive: true,
      startTime: Date.now(),
      durationMinutes: durationMinutes,
      remainingSeconds: durationMinutes * 60,
      sessionType: breakType === 'short' ? 'short_break' : 'long_break',
      completedSessionsInCycle: this.currentState.completedSessionsInCycle
    };

    this.startTimer();
    hilog.info(0x0000, TAG, '%{public}s', `[休息开始] 类型: ${breakType}, 时长: ${durationMinutes} 分钟`);
    return true;
  }

  /** 启动 1s 倒计时定时器（已有定时器则先清除，避免重复） */
  private startTimer(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
    }

    this.timerId = setInterval(() => {
      this.currentState.remainingSeconds--;

      if (this.onTickCallback) {
        this.onTickCallback(this.currentState.remainingSeconds);
      }

      if (this.currentState.remainingSeconds <= 0) {
        this.onSessionComplete();
      }
    }, 1000);
  }

  /**
   * 手动中断专注会话
   * @returns true 成功中断，false 无进行中会话
   */
  interruptSession(): boolean {
    if (!this.currentState.isActive) {
      return false;
    }

const endTime = Date.now();
    const actualMinutes = Math.floor((endTime - this.currentState.startTime) / 60000);
    // 只有打断「专注」才算打断连击；打断休息不应清零专注连击
    const isFocusSession = this.currentState.sessionType === 'focus';

    // 记录中断的会话（不获得积分）。
    // ⚠️ 休息会话不入 focusHistory：它是 completed:false，若写进去会在
    // computeLongestStreak 中充当"断链"，把本应连续的专注场次切开。
    if (isFocusSession) {
      const session: FocusSession = {
        startTime: this.currentState.startTime,
        endTime: endTime,
        durationMinutes: actualMinutes,
        completed: false,
        pointsEarned: 0,
        interrupted: true
      };

      this.focusHistory.push(session);
      this.currentStreak = 0; // 中断重置连续次数
      this.statsCache = null; // 历史已变，统计缓存失效（与 onSessionComplete 同口径）
      this.saveToPreferences();
    }

    // 中断时撤掉本会话的常驻提醒
    this.reminderService.cancelAllFocusReminders();
    this.reminderService.cancelEyeRestReminder();

    this.stopTimer();
    this.currentState.isActive = false;

    hilog.info(0x0000, TAG, isFocusSession ? '[专注中断] 连续次数已重置' : '[休息中断] 专注连击不受影响');
    return true;
  }

  private onSessionComplete(): void {
    this.stopTimer();

    if (this.currentState.sessionType === 'focus') {
      // 先更新连续次数，再按「新连击数」计算积分加成（完成本会话后即计入本场连击）
      this.currentStreak++;
      this.longestStreak = Math.max(this.longestStreak, this.currentStreak);
      const points = this.calculatePoints(this.currentState.durationMinutes);

      const session: FocusSession = {
        startTime: this.currentState.startTime,
        endTime: Date.now(),
        durationMinutes: this.currentState.durationMinutes,
        completed: true,
        pointsEarned: points,
        interrupted: false
      };

      this.focusHistory.push(session);
      this.totalPoints += points;
      this.currentState.completedSessionsInCycle++;
      this.statsCache = null;

      this.saveToPreferences();
      hilog.info(0x0000, TAG, '%{public}s', `[专注完成] 获得 ${points} 积分，连续 ${this.currentStreak} 次`);

      // 专注结束后稍后提醒护眼休息（衔接「专注完成」通知，约 1 分钟后弹出）
      this.reminderService.scheduleEyeRestReminder(EYE_REST_DELAY_SECONDS);
    }

    this.currentState.isActive = false;

    if (this.onCompleteCallback) {
      this.onCompleteCallback();
    }
  }

  /** 停止倒计时定时器 */
  private stopTimer(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  /**
   * 计算专注积分
   * 基础积分 + 连续加成（连续次数已在调用方先行累加，此处按完成本场后的「新连击数」发放）
   */
  private calculatePoints(durationMinutes: number): number {
    // 纯计算见 models/FocusStatsMath.computeFocusPoints（有单测锁定）
    return computeFocusPoints(durationMinutes, this.currentStreak, STREAK_BONUS_CAP);
  }

  /** 基于历史会话重算最长连续完成次数（会话按时间排序后统计连续 completed） */
  private calculateLongestStreak(): void {
    // 纯计算见 models/FocusStatsMath.computeLongestStreak（内部排序副本，不改入参数组）
    this.longestStreak = Math.max(this.longestStreak, computeLongestStreak(this.focusHistory));
  }

  /**
   * 设置倒计时回调（传 null 可解除注册，页面销毁时释放避免持有失效闭包）
   */
  setOnTick(callback: ((remainingSeconds: number) => void) | null): void {
    this.onTickCallback = callback;
  }

  /**
   * 设置完成回调（传 null 可解除注册）
   */
  setOnComplete(callback: (() => void) | null): void {
    this.onCompleteCallback = callback;
  }

/**
   * 获取当前状态
   * 返回显式副本：内部 currentState 被 1s 定时器原地改写，直接返回会让调用方持有活对象
   */
  getCurrentState(): FocusModeState {
    return {
      isActive: this.currentState.isActive,
      startTime: this.currentState.startTime,
      durationMinutes: this.currentState.durationMinutes,
      remainingSeconds: this.currentState.remainingSeconds,
      sessionType: this.currentState.sessionType,
      completedSessionsInCycle: this.currentState.completedSessionsInCycle
    };
  }

  /**
   * 获取专注统计（按当日缓存：同日多次调用复用结果，避免重复扫描历史）
   * 会话按 startTime 归属日期统计 今日/本周/累计 完成数与时长的聚合视图
   */
  getStats(): FocusStats {
    const todayStart = new Date();
    todayStart.setHours(0, 0, 0, 0);
    // 提升为局部常量：原先在下方 for 循环里逐条调用 getTime()，历史越长重复计算越多
    const todayStartMs = todayStart.getTime();
    if (this.statsCache && this.statsCacheDay === todayStartMs) {
      return this.statsCache;
    }

    const weekStart = todayStartMs - 6 * 24 * 60 * 60 * 1000;

    let totalSessions = 0;
    let totalMinutes = 0;
    let todaySessions = 0;
    let todayMinutes = 0;
    let weekSessions = 0;
    let weekMinutes = 0;

    for (let i = 0; i < this.focusHistory.length; i++) {
      const s = this.focusHistory[i];
      if (!s.completed) {
        continue;
      }
      totalSessions++;
      totalMinutes += s.durationMinutes;
      if (s.startTime >= weekStart) {
        weekSessions++;
        weekMinutes += s.durationMinutes;
        if (s.startTime >= todayStartMs) {
          todaySessions++;
          todayMinutes += s.durationMinutes;
        }
      }
    }

    this.statsCache = {
      totalSessions,
      completedSessions: totalSessions,
      totalMinutes,
      totalPoints: this.totalPoints,
      currentStreak: this.currentStreak,
      longestStreak: this.longestStreak,
      todaySessions,
      todayMinutes,
      weekSessions,
      weekMinutes
    };
    this.statsCacheDay = todayStart.getTime();
    return this.statsCache;
  }

  /**
   * 获取最近一次已完成专注会话获得的积分（用于完成页提示）
   */
  getLastSessionPoints(): number {
    for (let i = this.focusHistory.length - 1; i >= 0; i--) {
      if (this.focusHistory[i].completed) {
        return this.focusHistory[i].pointsEarned;
      }
    }
    return 0;
  }

  /**
   * 是否应该进行长休息
   */
  private shouldTakeLongBreak(): boolean {
    return this.currentState.completedSessionsInCycle >= SESSIONS_BEFORE_LONG_BREAK;
  }

  /**
   * 获取下次休息类型
   */
  getNextBreakType(): 'short' | 'long' {
    return this.shouldTakeLongBreak() ? 'long' : 'short';
  }

  /**
   * 重置周期计数
   */
  resetCycle(): void {
    this.currentState.completedSessionsInCycle = 0;
  }

  /**
   * 导出专注数据（用于备份）
   */
  exportData(): FocusBackupData {
    return {
      history: this.focusHistory.map((session: FocusSession): FocusSessionBackup => {
        const backup: FocusSessionBackup = {
          startTime: session.startTime,
          endTime: session.endTime,
          durationMinutes: session.durationMinutes,
          completed: session.completed,
          pointsEarned: session.pointsEarned,
          interrupted: session.interrupted
        };
        return backup;
      }),
      totalPoints: this.totalPoints,
      currentStreak: this.currentStreak,
      focusDurationMinutes: this.focusDurationMinutes
    };
  }

  /**
   * 重置全部专注数据（数据重置时调用）：撤除提醒、停止计时、清空历史/积分/连续次数，专注时长恢复默认
   */
  resetAll(): void {
    this.reminderService.cancelAllFocusReminders();
    this.reminderService.cancelEyeRestReminder();
    this.stopTimer();
    this.onTickCallback = null;
    this.onCompleteCallback = null;
    this.currentState = {
      isActive: false,
      startTime: 0,
      durationMinutes: 0,
      remainingSeconds: 0,
      sessionType: 'focus',
      completedSessionsInCycle: 0
    };
    this.focusHistory = [];
    this.totalPoints = 0;
    this.currentStreak = 0;
    this.longestStreak = 0;
    this.focusDurationMinutes = POMODORO_DURATION_MINUTES;
    this.statsCache = null;
    this.statsCacheDay = -1;
    this.saveToPreferences();
    hilog.info(0x0000, TAG, '%{public}s', '[重置] 专注数据已清空');
  }

  /**
   * 导入专注数据（备份恢复）
   */
  importData(data: FocusBackupData): void {
    if (data && Array.isArray(data.history)) {
      this.focusHistory = data.history.map((session: FocusSessionBackup): FocusSession => {
        const restored: FocusSession = {
          startTime: session.startTime,
          endTime: session.endTime,
          durationMinutes: session.durationMinutes,
          completed: session.completed,
          pointsEarned: session.pointsEarned,
          interrupted: session.interrupted
        };
        return restored;
      });
    }
    this.totalPoints = typeof data?.totalPoints === 'number' ? data.totalPoints : 0;
    this.currentStreak = typeof data?.currentStreak === 'number' ? data.currentStreak : 0;
    if (typeof data?.focusDurationMinutes === 'number') {
      this.focusDurationMinutes = this.safeClampFocusDuration(data.focusDurationMinutes, this.focusDurationMinutes);
    }
    // ⚠️ 必须**直接赋值**，不能走 calculateLongestStreak()（那是 Math.max 合并）：
    // 进程内存活期间导入一份历史更少的备份时，max 会保留恢复前的更大值，
    // 出现「最长连击 8、历史列表只有 3 条」且不可回退（与 loadFromPreferences 同口径）。
    this.longestStreak = computeLongestStreak(this.focusHistory);
    this.statsCache = null;
    this.saveToPreferences();
  }
}
