import { formatError } from '../models/ErrUtils';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppCategory, AppUsageInfo, DowntimeRule, UnlockInsights, WeeklyTrendInfo, APP_BUNDLE_NAME, SELF_APP_NAME, getDayStartTimestamp, formatDate, formatHourMinute, getTodayDateString, HISTORY_RETENTION_MS, MAX_STREAK_LOOKBACK_DAYS } from '../models/HealthTypes';
import { PreferenceManager, PreferenceEntry } from './PreferenceManager';
import { notificationManager } from '@kit.NotificationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { PersistentNotificationManager } from './PersistentNotificationManager';
import { NotificationRepostService, NotificationType } from './NotificationRepostService';
import { ScreenStateManager, ScreenStateListener } from './ScreenStateManager';
// 累计/跨日拆分/连续天数/窗口重叠的纯计算内核（全部有单测锁定，见 models/UsageStatsMath.ets）
// 注意：ScreenOnRecord / DailyUsageEntry 两个结构化类型本文件已各有一份定义，
// 且被 export 给他处引用，故不从纯函数模块 import 类型，只 import 函数。
import {
  sumRecordSeconds,
  computeLiveSeconds,
  splitSessionAtMidnight,
  mergeDailyHistory,
  computeStreakDays,
  computeUsedDaysStreak,
  computeOverlapInWindow,
  sumSecondsInWindow,
  computeLimitTierIndex,
  limitTiersToClearFlag,
  limitTiersToCancel,
  limitTiersSupersededBy,
  LIMIT_TIER_NONE,
  LIMIT_TIER_50,
  LIMIT_TIER_80,
  LIMIT_TIER_100,
  isInDowntimeRange,
} from '../models/UsageStatsMath';

const TAG = 'UsageStatsManager';
const DEFAULT_TOTAL_LIMIT_MINUTES = 180;
/**
 * 每日总使用时长限额的合法范围。
 * 设置页滑块此前硬编码 30/480，与 manager 边界各写一份（与 2026-10-01 轮修掉的
 * SleepManager 常量外泄同类，此处当时漏改）；备份恢复更是完全绕过滑块，
 * 一个 totalDailyLimitMinutes: 0 的备份即可让 checkUsageAlerts 的 totalLimitSeconds>0
 * 分支永不成立、getStreakDays 直接返回 0，预警与连续天数被静默关闭。
 */
export const MIN_TOTAL_LIMIT_MINUTES = 30;
export const MAX_TOTAL_LIMIT_MINUTES = 480;
// 50%/80% 两档阈值已随 computeLimitTierIndex 迁入 models/UsageStatsMath（判定逻辑单一来源）
const PREFS_KEY_DOWNTIME_RULE = 'downtime_rule';
const PREFS_KEY_TOTAL_LIMIT = 'total_daily_limit_minutes';
const PREFS_KEY_SCREEN_ON_RECORDS = 'screen_on_records';
const PREFS_KEY_DAILY_HISTORY = 'daily_usage_history';
const PREFS_KEY_TODAY_SECONDS = 'today_accumulated_seconds';
const PREFS_KEY_TODAY_DATE = 'today_accumulated_date';
const PREFS_KEY_UNLOCK_HISTORY = 'unlock_history';
const PREFS_KEY_DAILY_UNLOCK_HISTORY = 'daily_unlock_history';

interface ScreenOnRecord {
  date: string;
  startTime: number;
  endTime: number;
}

export interface DailyUsageEntry {
  date: string;
  totalMinutes: number;
}

interface UnlockRecord {
  timestamp: number;
  hour: number;
}

interface DailyUnlockEntry {
  date: string;
  unlockCount: number;
  hourlyCounts: number[];
}

interface TodayUnlockStats {
  hourlyCounts: number[];
  totalCount: number;
}

/** 一档限额预警的标题与正文 */
interface TierAlertText {
  title: string;
  text: string;
}

interface UnlockRecordBackup {
  timestamp: number;
  hour: number;
}

interface DailyUnlockEntryBackup {
  date: string;
  unlockCount: number;
  hourlyCounts: number[];
}

export interface UnlockBackupData {
  records: UnlockRecordBackup[];
  dailyHistory: DailyUnlockEntryBackup[];
}

function createDefaultDowntimeRule(): DowntimeRule {
  return {
    startHour: 22,
    startMinute: 0,
    endHour: 7,
    endMinute: 0,
    // 预留字段，当前版本未生效（见 DowntimeRule.restrictedCategories 的注释）。
    // 默认给空数组而不是「视频/游戏/社交」——填一个从未被消费的列表，
    // 只会让人以为存在分类拦截能力。这里必须与"本功能只是提醒"的定位一致。
    restrictedCategories: [],
    enabled: true
  };
}

/**
 * 免打扰时段的可读描述。
 *
 * ⚠️ 起止时刻相同时必须输出「全天」而不是 `22:00 - 22:00`：
 * 该配置在 `isInDowntime` 里语义是**全天免打扰**（见该方法注释），
 * 若照原样拼接，提醒文案会变成自我否定的一句：
 * 「当前时间处于免打扰时段（22:00 - 22:00）」——用户读到只会以为程序坏了。
 */
function formatTimeRange(rule: DowntimeRule): string {
  if (rule.startHour === rule.endHour && rule.startMinute === rule.endMinute) {
    return '全天';
  }
  return `${formatHourMinute(rule.startHour, rule.startMinute)} - ${formatHourMinute(rule.endHour, rule.endMinute)}`;
}

/**
 * 每日限额预警三档（由低到高）。
 * checkUsageAlerts 是互斥的 else-if 链，同一时刻只有「当前最高档」会被发出；
 * 但已发出的低档常驻通知不可被用户划掉，会一直留在通知栏，故高档触发时需按序撤除低档。
 */
const TOTAL_LIMIT_TIER_IDS: number[] = [
  NotificationType.TOTAL_LIMIT_50,
  NotificationType.TOTAL_LIMIT_80,
  NotificationType.TOTAL_LIMIT_100
];

/** 与 TOTAL_LIMIT_TIER_IDS 同下标的 alertSentFlags 键名，用于按档位清标记。 */
const TOTAL_LIMIT_TIER_FLAGS: string[] = ['total_limit_50', 'total_limit_80', 'total_limit_100'];

/**
 * 三档限额预警的文案，与 TOTAL_LIMIT_TIER_IDS 同下标（50% / 80% / 100%）。
 * 此前 `checkUsageAlerts` 与 `repostTotalLimitAlert` 各写一份逐字相同的文案，
 * 改措辞漏改一处就会让"首次发布"与"重发"的通知栏文案不一致。
 */
const TOTAL_LIMIT_TIER_ALERTS: TierAlertText[] = [
  {
    title: '今日屏幕使用时间已过半',
    text: '您今日屏幕使用已达到总限额的 50%，可适当安排休息。'
  },
  {
    title: '今日屏幕使用时间即将超额',
    text: '您今日屏幕使用已达到总限额的 80%，注意控制使用时间。'
  },
  {
    title: '今日屏幕使用时间已超额',
    text: '您已达到今日设定的屏幕使用总限额，建议休息一下。'
  }
];

/** 预警档位字符串 → 通知 ID（与 registerCallback 注册重发回调时的档位参数对应） */
function levelNotificationId(level: string): number {
  if (level === '100') {
    return NotificationType.TOTAL_LIMIT_100;
  }
  if (level === '80') {
    return NotificationType.TOTAL_LIMIT_80;
  }
  return NotificationType.TOTAL_LIMIT_50;
}

interface TrendResult {
  trendDirection: 'up' | 'down' | 'stable';
  trendDeltaPercent: number;
}

function computeTrend(recent3: number, previous3: number): TrendResult {
  let trendDirection: 'up' | 'down' | 'stable' = 'stable';
  let trendDeltaPercent = 0;
  if (previous3 > 0) {
    trendDeltaPercent = Math.round(((recent3 - previous3) / previous3) * 100);
    if (trendDeltaPercent > 5) {
      trendDirection = 'up';
    } else if (trendDeltaPercent < -5) {
      trendDirection = 'down';
    }
  } else if (recent3 > 0) {
    trendDirection = 'up';
    trendDeltaPercent = 100;
  }
  const result: TrendResult = { trendDirection, trendDeltaPercent };
  return result;
}

/**
 * 屏幕使用时长统计管理器（亮屏统计口径）
 * 统计源为手机真实亮屏时间（ScreenStateManager 检测亮灭屏），而非本应用前台时长。
 * 功能：
 * 1. 使用时长统计（亮屏会话记录、今日累计）
 * 2. 停用时间管理（downtimeRule、isInDowntime）
 * 3. 每日总限额（totalDailyLimitMinutes）
 * 4. 连续达标天数（streakDays）
 * 5. 周趋势统计（weeklyTrendInfo、dailyHistory）
 * 6. 使用预警通知（总限额和停用时间）
 * 7. 真实解锁次数统计（订阅 SCREEN_UNLOCKED + 轮询灭屏→亮屏跳变兜底）
 */
export class UsageStatsManager implements ScreenStateListener {
  private static instance: UsageStatsManager;

  static getInstance(): UsageStatsManager {
    if (!UsageStatsManager.instance) {
      UsageStatsManager.instance = new UsageStatsManager();
    }
    return UsageStatsManager.instance;
  }

  private todayUsage: AppUsageInfo[] = [];
  private downtimeRule: DowntimeRule = createDefaultDowntimeRule();
  private totalDailyLimitMinutes: number = DEFAULT_TOTAL_LIMIT_MINUTES;

  private screenOnRecords: ScreenOnRecord[] = [];
  private currentScreenOnStart: number = 0;
  private currentDate: string = getTodayDateString();

  private dailyHistory: DailyUsageEntry[] = [];
  private todayAccumulatedSeconds: number = 0;

  private refreshTimerId: number = -1;
  private lastPersistTime: number = 0;
  private readonly PERSIST_INTERVAL_MS = 10000;
  private lastPublishedMinutes: number = -1;
  private recordsDirty: boolean = false;
  private lastPersistedSeconds: number = -1;

  private liveSecondsCache: number = 0;
  private liveSecondsCacheSecond: number = -1;

  private alertSentFlags: Map<string, boolean> = new Map();

  // 洞察数据缓存（内容仅在分钟/数据变更时变化，避免每秒重复分配与计算）
  private weeklyTrendCache: WeeklyTrendInfo | null = null;
  private weeklyTrendCacheKey: string = '';
  private unlockInsightsCache: UnlockInsights | null = null;
  private unlockInsightsCacheKey: string = '';
  private streakCache: number = 0;
  private streakCacheKey: string = '';
  /**
   * dailyHistory 版本号：每次内容发生变化（增/改/删/整体替换）自增。
   * getAppUsedDaysStreak 的缓存键依赖它，用版本号而非数组长度是为了覆盖
   * "中间某条被原地改写"这类长度不变的场景。
   * 自增点见 cleanupOldHistory()（被 onDateChanged / loadFromPreferences /
   * persistDailyHistory / setDailyHistory 四处调用，统一在此自增）
   * 与 loadFromPreferences() 开头的清空。
   */
  private dailyHistoryVersion: number = 0;
  private appUsedDaysStreakCache: number = 0;
  private appUsedDaysStreakCacheKey: string = '';

  // 解锁次数追踪
  private unlockRecords: UnlockRecord[] = [];
  private dailyUnlockHistory: DailyUnlockEntry[] = [];

  // 解锁次数缓存（按天缓存，跨日失效）
  private todayUnlockCache: number = -1;
  private todayUnlockCacheDate: string = '';
  private computeTodayUnlockStatsCache: TodayUnlockStats | null = null;
  private computeTodayUnlockStatsCacheDate: string = '';

  initialize(): void {
    hilog.info(0x0000, TAG, '%{public}s', '[初始化] 开始初始化使用统计管理器');
    // 重新初始化（如重置数据）时丢弃可能遗留的进行中会话，避免旧会话时间污染新统计
    this.currentScreenOnStart = 0;
    this.weeklyTrendCache = null;
    this.unlockInsightsCache = null;
    this.computeTodayUnlockStatsCache = null;
    this.computeTodayUnlockStatsCacheDate = '';
    this.streakCacheKey = '';
    this.appUsedDaysStreakCacheKey = '';
    // ⚠️ 与 onDateChanged 的清零清单保持一致。原先漏了 todayUnlockCache，
    // 而 loadFromPreferences() 会把 unlockRecords 清空 —— 于是首页「今日解锁 0 次」
    // （走 getUnlockInsights，缓存被清了）与「每日目标 → 解锁控制」仍显示重置前的 12/30
    // （走 getTodayUnlockCount，缓存还留着）互相矛盾，直到下一次解锁或重启才对上。
    this.todayUnlockCache = -1;
    this.todayUnlockCacheDate = '';
    // 重置数据后不应继续沿用重置前已触发的预警标记，否则当日限额/停用预警被压制到跨日
    this.alertSentFlags.clear();
    this.loadFromPreferences();

    // 接线屏幕状态检测：亮灭屏/解锁事件驱动统计（commonEvent 订阅 + power.isActive 轮询兜底）
    ScreenStateManager.getInstance().setListener(this);
    ScreenStateManager.getInstance().start();
    // 冷启动时若屏幕已亮（典型场景：用户正在使用手机时打开应用），立即开启今日亮屏会话；
    // 若屏幕已灭则等待 SCREEN_ON 事件或轮询检测到亮屏跳变后再开启
    if (ScreenStateManager.getInstance().isScreenOn() && this.currentScreenOnStart <= 0) {
      this.currentScreenOnStart = Date.now();
      this.invalidateLiveSecondsCache();
    }
    // 实机验证（2026-10-10）：重置路径上缓存值与真实状态一致（screenOn=true / 会话已开启），
    // 且即便不一致，ScreenStateManager.poll() 每 5s 自愈。此日志保留用于观测重置路径。
    hilog.info(0x0000, TAG, '%{public}s', '[初始化] 亮屏会话：isScreenOn=' +
      (ScreenStateManager.getInstance().isScreenOn() ? 'true' : 'false') +
      ' currentScreenOnStart=' + (this.currentScreenOnStart > 0 ? '已开启' : '未开启'));

    const today = getTodayDateString();
    const todayEntry = this.dailyHistory.find(entry => entry.date === today);
    // loadFromPreferences 已读取 PREFS_KEY_TODAY_SECONDS，这里直接复用，避免重复读偏好存储
    this.todayAccumulatedSeconds = Math.max(this.todayAccumulatedSeconds, (todayEntry ? todayEntry.totalMinutes * 60 : 0));

    // 注册使用预警通知的重发回调
    const repostService = NotificationRepostService.getInstance();
    repostService.registerCallback(NotificationType.DOWNTIME_ALERT, async () => {
      return await this.repostDowntimeAlert();
    });
    repostService.registerCallback(NotificationType.TOTAL_LIMIT_50, async () => {
      return await this.repostTotalLimitAlert('50');
    });
    repostService.registerCallback(NotificationType.TOTAL_LIMIT_80, async () => {
      return await this.repostTotalLimitAlert('80');
    });
    repostService.registerCallback(NotificationType.TOTAL_LIMIT_100, async () => {
      return await this.repostTotalLimitAlert('100');
    });

    // refreshUsage 是 async 且内部无 try/catch，全部 6 处调用点必须显式挂 .catch：
    // initialize、30s 刷新定时器、onScreenOn、onScreenOff，以及备份恢复路径上的
    // setSelfUsageSeconds / setDailyHistory（后两处静默失败会让用户以为恢复成功）。
    // 按方法名而非行号定位，避免后续改动再次让行号漂移。
    this.refreshUsage().catch((err: Error) => {
      hilog.error(0x0000, TAG, '%{public}s', '[初始化] 刷新使用数据失败：' + formatError(err));
    });
    this.startRefreshTimer();
  }

  /** 启动 30s 数据刷新定时器，并在启动时立即发布一次常驻使用时长通知 */
  private startRefreshTimer(): void {
    if (this.refreshTimerId >= 0) {
      clearInterval(this.refreshTimerId);
    }
    this.refreshTimerId = setInterval(() => {
      // 运行中跨日即时清零（应用常驻后台/前台过午夜也能在 30 秒内归零）
      this.checkDateRollover();
      this.refreshUsage().catch((err: Error) => {
        hilog.error(0x0000, TAG, '%{public}s', '[定时刷新] 刷新使用数据失败：' + formatError(err));
      });
      if (this.recordsDirty) {
        this.saveScreenOnRecords();
      }
      this.persistDailyHistory();
      // 更新常驻通知内容（分钟数未变化时跳过，避免频繁调用系统通知接口）
      // 注意：publishPersistent 是 async，函数体内的任何异常（含同步 throw）都会转成
      // rejected Promise，外层 try/catch **永远不会触发**——原写法是一段看起来有兜底、
      // 实际不生效的死代码。这里改用 .catch 让日志真正兜住。
      const minutes = Math.floor(this.todayAccumulatedSeconds / 60);
      if (minutes !== this.lastPublishedMinutes) {
        this.lastPublishedMinutes = minutes;
        PersistentNotificationManager.getInstance()
          .publishPersistent(SELF_APP_NAME, `今日已使用 ${minutes} 分钟`)
          .catch((err: Error) => {
            hilog.warn(0x0000, TAG, '%{public}s', '更新常驻通知失败: ' + formatError(err));
          });
      }
    }, 30000);
    // 初始发布常驻通知（同上：必须用 .catch，try/catch 对 async 函数无效）
    const initialMinutes = Math.floor(this.todayAccumulatedSeconds / 60);
    this.lastPublishedMinutes = initialMinutes;
    PersistentNotificationManager.getInstance()
      .publishPersistent(SELF_APP_NAME, `今日已使用 ${initialMinutes} 分钟`)
      .catch((err: Error) => {
        hilog.warn(0x0000, TAG, '%{public}s', '发布初始常驻通知失败: ' + formatError(err));
      });
  }

  /**
   * 亮屏事件（ScreenStateListener）：开启今日亮屏会话；跨日时先结算昨日
   * 屏幕熄灭后重新点亮（含解锁点亮）都会触发，与应用的可见性无关
   */
  onScreenOn(now: number): void {
    this.checkDateRollover();
    if (this.currentScreenOnStart <= 0) {
      this.currentScreenOnStart = now;
      this.invalidateLiveSecondsCache();
    }
    this.refreshUsage().catch((err: Error) => {
      hilog.error(0x0000, TAG, '%{public}s', '[亮屏] 刷新使用数据失败：' + formatError(err));
    });
  }

  /**
   * 检测跨日：日期变化时立即清零今日统计并保存昨日数据
   * 供亮屏切换、聚合循环与页面 tick 周期性调用
   */
  checkDateRollover(): boolean {
    const today = getTodayDateString();
    if (today === this.currentDate) {
      return false;
    }
    this.onDateChanged();
    return true;
  }

  private onDateChanged(): void {
    const today = getTodayDateString();
    const midnightMs = getDayStartTimestamp(today);

    // 昨日总量 = 昨日已完成记录 + 进行中会话的昨日段（start→00:00）。
    // 注意不能用 todayAccumulatedSeconds（watermark）：它经 refreshUsage 已含进行中会话时长，
    // 若再叠加昨日段会翻倍；records 在 cleanupOldScreenOnRecords 前仍保留昨日数据，可精确求和。
    // 拆分算法见 models/UsageStatsMath.splitSessionAtMidnight（有单测锁定）。
    const split = splitSessionAtMidnight(this.currentScreenOnStart, midnightMs, Date.now());
    let yesterdaySeconds = sumRecordSeconds(this.screenOnRecords, this.currentDate) + split.yesterdaySeconds;
    this.currentScreenOnStart = split.nextSessionStart;

    // 将昨日累计写入每日历史（此刻 currentDate 仍为昨日）
    const yesterday = this.currentDate;
    mergeDailyHistory(this.dailyHistory, yesterday, yesterdaySeconds);
    if (Math.floor(yesterdaySeconds / 60) > 0) {
      this.cleanupOldHistory();
    }
    PreferenceManager.getInstance().setString(PREFS_KEY_DAILY_HISTORY, JSON.stringify(this.dailyHistory));

    // 今日统计清零
    this.currentDate = getTodayDateString();
    this.todayAccumulatedSeconds = 0;
    this.invalidateLiveSecondsCache();
    this.alertSentFlags.clear();
    this.cancelAlertNotifications();
    this.unlockRecords = [];
    this.weeklyTrendCache = null;
    this.weeklyTrendCacheKey = '';
    this.unlockInsightsCache = null;
    this.unlockInsightsCacheKey = '';
    this.streakCacheKey = '';
    this.appUsedDaysStreakCacheKey = '';
    this.todayUnlockCache = -1;
    this.todayUnlockCacheDate = '';
    this.lastPublishedMinutes = -1;
    this.lastPersistedSeconds = -1;

    hilog.info(0x0000, TAG, '%{public}s', '[跨日] 已清零今日统计，切换至 ' + this.currentDate);
  }

  /**
   * 灭屏事件（ScreenStateListener）：结算当前亮屏会话写入记录并持久化
   */
  onScreenOff(now: number): void {
    // 先结算跨日：若灭屏发生在 00:00 之后、但聚合循环的 checkDateRollover 还没跑到，
    // 此时 currentDate 仍是昨天，后面 push 的记录会把**跨午夜后的那一段**也记到昨天，
    // 导致昨日虚高、今日偏少（窗口最长 = 聚合间隔 5s/30s，但能完全避免）。
    this.checkDateRollover();
    if (this.currentScreenOnStart > 0) {
      const durationSinceLastPersist = now - this.lastPersistTime;

      // 注意：不再 here += seconds —— todayAccumulatedSeconds 是纯 watermark，
      // 由 refreshUsage 的 max(live) 每 30s 维护；若再累加，会与进行中会话被折入的时长重复计数
      this.screenOnRecords.push({
        date: this.currentDate,
        startTime: this.currentScreenOnStart,
        endTime: now
      });
      this.recordsDirty = true;
      this.currentScreenOnStart = 0;
      this.invalidateLiveSecondsCache();

      this.saveScreenOnRecords();
      if (durationSinceLastPersist >= this.PERSIST_INTERVAL_MS) {
        this.persistDailyHistory();
      }
      this.refreshUsage().catch((err: Error) => {
        hilog.error(0x0000, TAG, '%{public}s', '[灭屏] 刷新使用数据失败：' + formatError(err));
      });
    }
  }

  /**
   * 解锁事件（ScreenStateListener）：记录真实解锁次数
   * 去重由 ScreenStateManager 统一处理（订阅 SCREEN_UNLOCKED 与轮询灭→亮跳变只计一次）
   */
  onScreenUnlocked(now: number): void {
    this.recordUnlock();
  }

  /**
   * 持久化数组的逐字段有限性过滤（4 组共用同一判据）。
   *
   * 背景：JSON.parse 对数组只保证"是数组"，元素可以是任意形状。prefs 是沙箱内可被
   * 手工改写/跨版本迁移的存储，一个 `{"date":"2026-10-11","totalMinutes":"abc"}` 就能让
   * `computeStreakDays` 用字符串参与比较（`"abc" > limit` 恒 false → 该天被当作"未超限"，
   * 连续达标天数虚高），或让 `sumRecordSeconds` 累出 NaN 并经 `todayAccumulatedSeconds`
   * 渗进首页显示。
   *
   * ⚠️ `typeof x === 'number'` **挡不住 NaN**，而 NaN 经 `JSON.stringify` 会序列化成
   * `null` 落盘续命（与 2026-10-02 轮在 SleepManager 修过的同款问题），故必须用
   * `Number.isFinite`。
   *
   * 备份恢复路径（`setDailyHistory` / `setDowntimeRule`）已有逐字段校验，此处补齐
   * prefs 载入路径，使两条入口口径一致。正常数据的过滤结果为空，行为不变。
   */
  private filterValidScreenOnRecords(records: ScreenOnRecord[]): ScreenOnRecord[] {
    return records.filter(r => r && typeof r.date === 'string' &&
      Number.isFinite(r.startTime) && Number.isFinite(r.endTime) && r.endTime >= r.startTime);
  }

  private filterValidDailyHistory(history: DailyUsageEntry[]): DailyUsageEntry[] {
    return history.filter(e => e && typeof e.date === 'string' &&
      typeof e.totalMinutes === 'number' && Number.isFinite(e.totalMinutes) && e.totalMinutes >= 0);
  }

  private filterValidUnlockRecords(records: UnlockRecord[]): UnlockRecord[] {
    return records.filter(r => r && Number.isFinite(r.timestamp) &&
      Number.isFinite(r.hour) && r.hour >= 0 && r.hour <= 23);
  }

  private filterValidDailyUnlockHistory(history: DailyUnlockEntry[]): DailyUnlockEntry[] {
    return history.filter(e => e && typeof e.date === 'string' &&
      Number.isFinite(e.unlockCount) && e.unlockCount >= 0 &&
      Array.isArray(e.hourlyCounts) && e.hourlyCounts.length === 24 &&
      e.hourlyCounts.every(v => Number.isFinite(v)));
  }

  /**
   * 安全解析 prefs 里存的 JSON 字符串，解析失败按"键缺失"处理（返回 null）。
   *
   * ⚠️ 此前本方法内 8 个读取点**共用一个 try**：任意一个键的内容被写坏（写入截断、
   * 跨版本迁移、手工改写沙箱文件）时，`JSON.parse` 抛出会让**后面全部读取都不执行**，
   * 内存停在字段初始值 —— 损坏一个配置项，却导致限额回落默认、今日用量与解锁历史全归零，
   * 而用户只在 hilog 里看到一行 error。逐键隔离后，单个坏键只影响它自己。
   */
  private parseStoredJson<T>(raw: string, key: string): T | null {
    if (!raw) {
      return null;
    }
    try {
      return JSON.parse(raw) as T;
    } catch (err) {
      hilog.error(0x0000, TAG, '%{public}s',
        `[存储] 键 ${key} 的 JSON 解析失败，已按缺省处理：` + formatError(err));
      return null;
    }
  }

  private loadFromPreferences(): void {
    this.dailyHistory = [];
    // 走的是"清空"分支时不会经过 cleanupOldHistory，需在此自增
    this.dailyHistoryVersion++;
    this.screenOnRecords = [];
    this.unlockRecords = [];
    this.dailyUnlockHistory = [];

    try {
      const pref = PreferenceManager.getInstance();

      const parsedRule = this.parseStoredJson<Partial<DowntimeRule>>(
        pref.getString(PREFS_KEY_DOWNTIME_RULE, ''), PREFS_KEY_DOWNTIME_RULE);
      if (parsedRule && typeof parsedRule.startHour === 'number' &&
          typeof parsedRule.startMinute === 'number' &&
          typeof parsedRule.endHour === 'number' && typeof parsedRule.endMinute === 'number' &&
          Array.isArray(parsedRule.restrictedCategories)) {
        this.downtimeRule = parsedRule as DowntimeRule;
      } else {
        // 键不存在 = 「重置所有数据」删过它（resetAllData 会删 PREFS_KEY_DOWNTIME_RULE）；
        // 键存在但内容坏掉同样走这里。
        // 不回默认的话，内存里会残留重置前的时段：设置页与首页仍显示旧值，
        // checkUsageAlerts 也继续按旧时段发免打扰横幅，只有重启应用才恢复。
        // （与 totalDailyLimitMinutes 走 getNumber(key, DEFAULT) 能正确回默认、
        //   SleepManager.loadPreferences/loadHistory 已补 else 分支保持一致）
        this.downtimeRule = createDefaultDowntimeRule();
      }

      this.totalDailyLimitMinutes = pref.getNumber(PREFS_KEY_TOTAL_LIMIT, DEFAULT_TOTAL_LIMIT_MINUTES);

      const parsedRecords = this.parseStoredJson<ScreenOnRecord[]>(
        pref.getString(PREFS_KEY_SCREEN_ON_RECORDS, ''), PREFS_KEY_SCREEN_ON_RECORDS);
      if (parsedRecords) {
        this.screenOnRecords = this.filterValidScreenOnRecords(parsedRecords);
        this.cleanupOldScreenOnRecords();
      }

      const parsedHistory = this.parseStoredJson<DailyUsageEntry[]>(
        pref.getString(PREFS_KEY_DAILY_HISTORY, ''), PREFS_KEY_DAILY_HISTORY);
      if (parsedHistory) {
        this.dailyHistory = this.filterValidDailyHistory(parsedHistory);
        this.cleanupOldHistory();
      }

      this.todayAccumulatedSeconds = pref.getNumber(PREFS_KEY_TODAY_SECONDS, 0);

      // 持久化的今日累计若属于过去日期（例如昨晚最后落盘后应用被杀），新的一天启动时丢弃，
      // 避免今日使用时长/预警/周趋势显示昨日数据（昨日总量已保存在 dailyHistory 中）
      const todayDateStr = pref.getString(PREFS_KEY_TODAY_DATE, '');
      if (todayDateStr && todayDateStr !== getTodayDateString()) {
        this.todayAccumulatedSeconds = 0;
      }

      // 加载解锁历史数据
      const parsedUnlock = this.parseStoredJson<UnlockRecord[]>(
        pref.getString(PREFS_KEY_UNLOCK_HISTORY, ''), PREFS_KEY_UNLOCK_HISTORY);
      if (parsedUnlock) {
        this.unlockRecords = this.filterValidUnlockRecords(parsedUnlock);
        this.cleanupOldUnlockRecords();
      }

      const parsedDailyUnlock = this.parseStoredJson<DailyUnlockEntry[]>(
        pref.getString(PREFS_KEY_DAILY_UNLOCK_HISTORY, ''), PREFS_KEY_DAILY_UNLOCK_HISTORY);
      if (parsedDailyUnlock) {
        this.dailyUnlockHistory = this.filterValidDailyUnlockHistory(parsedDailyUnlock);
        this.cleanupOldUnlockHistory();
      }
    } catch (err) {
      hilog.error(0x0000, TAG, '%{public}s', '从本地存储读取配置失败：' + formatError(err));
    }
    this.invalidateLiveSecondsCache();
    this.lastPersistedSeconds = -1;
  }

  private saveScreenOnRecords(): void {
    this.cleanupOldScreenOnRecords();
    this.recordsDirty = false;
    PreferenceManager.getInstance().setString(PREFS_KEY_SCREEN_ON_RECORDS, JSON.stringify(this.screenOnRecords));
  }

  private cleanupOldScreenOnRecords(): void {
    const today = getTodayDateString();
    const yesterday = this.currentDate;
    // 先只读扫描判断是否真的需要过滤：screenOnRecords 本身只含今天/昨天，
    // 绝大多数情况下 filter 一个都滤不掉，白白分配一个新数组并替换引用。
    let needFilter = false;
    for (let i = 0; i < this.screenOnRecords.length; i++) {
      const recordDate = this.screenOnRecords[i].date;
      if (recordDate !== today && recordDate !== yesterday) {
        needFilter = true;
        break;
      }
    }
    if (needFilter) {
      const filtered = this.screenOnRecords.filter(record => record.date === today || record.date === yesterday);
      if (filtered.length !== this.screenOnRecords.length) {
        this.recordsDirty = true;
      }
      this.screenOnRecords = filtered;
    }
    this.invalidateLiveSecondsCache();
  }

  private cleanupOldHistory(): void {
    // 无论本次是否真的过滤掉条目都要自增：调用方（onDateChanged /
    // loadFromPreferences / persistDailyHistory / setDailyHistory）都可能刚刚
    // 改动过 dailyHistory，而 cleanupOldHistory 是它们的统一收口点。
    this.dailyHistoryVersion++;
    const cutoff = Date.now() - HISTORY_RETENTION_MS;
    this.dailyHistory = this.dailyHistory.filter(entry => {
      const entryTime = getDayStartTimestamp(entry.date);
      return entryTime >= cutoff;
    });
  }

  private persistDailyHistory(): void {
    const now = Date.now();
    if (now - this.lastPersistTime < this.PERSIST_INTERVAL_MS) {
      return;
    }
    this.lastPersistTime = now;

    const today = getTodayDateString();
    if (this.currentDate !== today) {
      return;
    }

    const liveSeconds = this.computeTodayScreenOnSeconds();
    const totalSeconds = Math.max(this.todayAccumulatedSeconds, liveSeconds);
    const totalMinutes = Math.floor(totalSeconds / 60);

    // 内容无变化时跳过落盘：空闲/后台（无进行中会话）场景下避免每 30s 写入同一份数据；
    // 会话进行中 live 持续增长，该值每 30s 变化，watermark 仍按原节奏落盘，崩溃恢复语义不变
    if (totalSeconds === this.lastPersistedSeconds) {
      return;
    }
    this.lastPersistedSeconds = totalSeconds;

    const entries: PreferenceEntry[] = [
      { key: PREFS_KEY_TODAY_SECONDS, value: totalSeconds },
      { key: PREFS_KEY_TODAY_DATE, value: today }
    ];

    if (totalMinutes <= 0) {
      PreferenceManager.getInstance().setBatch(entries);
      return;
    }

    const existingIndex = this.dailyHistory.findIndex(entry => entry.date === today);
    if (existingIndex >= 0) {
      const existing = this.dailyHistory[existingIndex];
      if (existing.totalMinutes < totalMinutes) {
        existing.totalMinutes = totalMinutes;
      }
    } else {
      this.dailyHistory.push({ date: today, totalMinutes });
    }
    this.cleanupOldHistory();

    entries.push({ key: PREFS_KEY_DAILY_HISTORY, value: JSON.stringify(this.dailyHistory) });
    PreferenceManager.getInstance().setBatch(entries);
  }

  async refreshUsage(): Promise<void> {
    const today = getTodayDateString();
    this.cleanupOldScreenOnRecords();

    const liveSeconds = this.computeTodayScreenOnSeconds();
    const finalSeconds = Math.max(this.todayAccumulatedSeconds, liveSeconds);
    this.todayAccumulatedSeconds = finalSeconds;

    this.todayUsage = [{
      bundleName: APP_BUNDLE_NAME,
      appName: SELF_APP_NAME,
      durationSeconds: finalSeconds,
      category: AppCategory.PRODUCTIVITY
    }];

    this.checkUsageAlerts();
  }

  /**
   * 计算今日亮屏记录的总秒数（不含当前持久化值）
   */
  private computeTodayScreenOnSeconds(): number {
    const nowSec = Math.floor(Date.now() / 1000);
    if (this.liveSecondsCacheSecond === nowSec) {
      return this.liveSecondsCache;
    }
    // 纯计算见 models/UsageStatsMath.computeLiveSeconds（有单测锁定）
    const totalSeconds = computeLiveSeconds(
      this.screenOnRecords, this.currentDate, this.currentScreenOnStart, Date.now());
    this.liveSecondsCache = totalSeconds;
    this.liveSecondsCacheSecond = nowSec;
    return totalSeconds;
  }

  private invalidateLiveSecondsCache(): void {
    this.liveSecondsCacheSecond = -1;
  }

  getTotalUsageSeconds(): number {
    return this.todayUsage.reduce((sum, app) => sum + app.durationSeconds, 0);
  }

  getStreakDays(): number {
    const limitMinutes = this.totalDailyLimitMinutes;
    if (limitMinutes <= 0) {
      return 0;
    }

    const todayLiveSeconds = this.computeTodayScreenOnSeconds();
    const todayTotalSeconds = Math.max(this.todayAccumulatedSeconds, todayLiveSeconds);
    const todayMinutes = Math.floor(todayTotalSeconds / 60);
    const cacheKey = this.currentDate + '_' + todayMinutes.toString() + '_' + limitMinutes.toString();
    if (this.streakCacheKey === cacheKey) {
      return this.streakCache;
    }

    let streak = computeStreakDays(
      this.dailyHistory, todayMinutes, limitMinutes, this.currentDate, MAX_STREAK_LOOKBACK_DAYS);
    this.streakCache = streak;
    this.streakCacheKey = cacheKey;
    return this.streakCache;
  }

  /**
   * 连续使用应用天数：今日已有亮屏使用则从今天起算，否则从昨天起算，
   * 往前连续存在真实亮屏使用（每日历史 totalMinutes > 0）的天数。
   * 口径与打卡连续天数一致——今日尚未使用不打断连续。
   *
   * 缓存：本方法原本每 5s（前台）/30s（后台）就要重建一次 ≤30 项的 Map
   * 并逐日回扫（最多 365 天），而同一条链路上同族的 getStreakDays 早已有
   * streakCacheKey 缓存——这里是唯一漏网的。
   * 缓存键覆盖全部输入：日期 + 今日是否有使用 + dailyHistory 版本号，
   * 任何一条 dailyHistory 改动都必须经下方 5 个 bump 点之一，
   * 自增 version 即自动失效。
   */
  getAppUsedDaysStreak(): number {
    const usedToday = this.computeTodayScreenOnSeconds() > 0 || this.todayAccumulatedSeconds > 0;
    const cacheKey = this.currentDate + '_' + (usedToday ? '1' : '0') + '_' + this.dailyHistoryVersion;
    if (this.appUsedDaysStreakCacheKey === cacheKey) {
      return this.appUsedDaysStreakCache;
    }

    // 纯计算见 models/UsageStatsMath.computeUsedDaysStreak（有单测锁定）
    const streak = computeUsedDaysStreak(
      this.dailyHistory, usedToday, this.currentDate, MAX_STREAK_LOOKBACK_DAYS);
    this.appUsedDaysStreakCache = streak;
    this.appUsedDaysStreakCacheKey = cacheKey;
    return streak;
  }

  getSelfUsageMinutes(): number {
    return Math.floor(this.getSelfUsageSeconds() / 60);
  }

  getSelfUsageSeconds(): number {
    // 实时口径：已累计基线 与「今日记录 + 进行中会话」取大，跨日拆分后 currentScreenOnStart 为 00:00，
    // 因此返回值始终与真实使用相符，无需等待 30s 定时刷新
    return Math.max(this.todayAccumulatedSeconds, this.computeTodayScreenOnSeconds());
  }

  setSelfUsageSeconds(seconds: number): void {
    this.todayAccumulatedSeconds = Math.max(0, seconds);
    this.lastPersistedSeconds = -1;
    this.weeklyTrendCache = null;
    this.streakCacheKey = '';
    this.appUsedDaysStreakCacheKey = '';
    this.unlockInsightsCache = null;
    const batch: PreferenceEntry[] = [
      { key: PREFS_KEY_TODAY_SECONDS, value: this.todayAccumulatedSeconds },
      { key: PREFS_KEY_TODAY_DATE, value: getTodayDateString() }
    ];
    PreferenceManager.getInstance().setBatch(batch);
    this.refreshUsage().catch((err: Error) => {
      hilog.error(0x0000, TAG, '%{public}s', '[设置用量] 刷新使用数据失败：' + formatError(err));
    });
    // ⚠️ 用量**下降**（备份恢复是唯一入口）同样要让已失效的横幅撤掉：
    // 白天已用 180/限额 180 → 100% 横幅在列 → 导入一份用量更小的备份 →
    // 首页显示 60 分钟，通知栏却还挂着「今日屏幕使用时间已超额」。
    // refreshUsage() 内无 await，函数体是同步跑完的，因此这里读到的 todayUsage 已是新值。
    this.syncTierAlertNotifications();
  }

  getDailyHistory(): DailyUsageEntry[] {
    return this.dailyHistory.slice();
  }

  setDailyHistory(history: DailyUsageEntry[]): void {
    // 复用与 prefs 载入路径同一套逐字段判据（含 Number.isFinite，
// 挡 NaN 经 JSON.stringify 序列化成 null 落盘续命）
    this.dailyHistory = this.filterValidDailyHistory(history);
    this.cleanupOldHistory();
    this.weeklyTrendCache = null;
    this.streakCacheKey = '';
    this.appUsedDaysStreakCacheKey = '';
    PreferenceManager.getInstance().setString(PREFS_KEY_DAILY_HISTORY, JSON.stringify(this.dailyHistory));
    this.refreshUsage().catch((err: Error) => {
      hilog.error(0x0000, TAG, '%{public}s', '[设置历史] 刷新使用数据失败：' + formatError(err));
    });
  }

  getDowntimeRule(): DowntimeRule {
    const rule = this.downtimeRule;
    return {
      startHour: rule.startHour,
      startMinute: rule.startMinute,
      endHour: rule.endHour,
      endMinute: rule.endMinute,
      restrictedCategories: rule.restrictedCategories.slice(),
      enabled: rule.enabled
    };
  }

setDowntimeRule(rule: DowntimeRule): void {
    /**
     * 停用时间规则的入参有两个来源：设置页时间选择器，以及备份恢复（外部 JSON）。
     * 原实现直接按引用存入、零校验：备份里 startHour: 99 会让 formatTimeRange 输出
     * "99:00 - 7:00" 直接进停用预警通知文案，且 isInDowntime 的时刻比较随之失真；
     * 按引用存储还与 getDowntimeRule（2026-10-10 轮已改为返回副本）不对称。
     * 故此处逐字段校验并拷贝一份，任一字段非法则整体沿用当前值。
     */
    const hours = [rule.startHour, rule.endHour];
    const minutes = [rule.startMinute, rule.endMinute];
    for (let i = 0; i < hours.length; i++) {
      const h = hours[i];
      if (typeof h !== 'number' || !Number.isFinite(h) || h < 0 || h > 23 || Math.floor(h) !== h) {
        return;
      }
    }
    for (let i = 0; i < minutes.length; i++) {
      const m = minutes[i];
      if (typeof m !== 'number' || !Number.isFinite(m) || m < 0 || m > 59 || Math.floor(m) !== m) {
        return;
      }
    }
    if (!Array.isArray(rule.restrictedCategories) || typeof rule.enabled !== 'boolean') {
      return;
    }
    this.downtimeRule = {
      startHour: rule.startHour,
      startMinute: rule.startMinute,
      endHour: rule.endHour,
      endMinute: rule.endMinute,
      restrictedCategories: rule.restrictedCategories.slice(),
      enabled: rule.enabled
    };
    PreferenceManager.getInstance().setString(PREFS_KEY_DOWNTIME_RULE, JSON.stringify(this.downtimeRule));
    // ⚠️ 改完规则必须同步已发出的停用预警，否则横幅文案会与界面直接矛盾：
    // 23:50 处于停用时段、横幅已挂着，用户把开关关掉 → isInDowntime() 立刻为 false，
    // 但「当前处于免打扰时段（22:00 - 07:00）」仍挂在通知栏且 isUnremovable 划不掉；
    // 改时段同理，横幅里的时段是旧值。限额侧有 syncTierAlertNotifications，停用侧此前没有镜像实现。
    // 附带修好标记残留：标记不清的话，当天再次进入停用时段会被 sendUsageAlert 首行短路、彻底不再提醒。
    this.syncDowntimeAlertNotification();
  }

  /**
   * 停用预警的对称同步：仅当**当前已不在**停用时段时撤除并清标记。
   *
   * 与 `syncTierAlertNotifications` 同构（只撤"已不成立"的那一条，不主动发新的），
   * 保证规则没变时完全不做任何操作、不会无故打扰。
   */
  private syncDowntimeAlertNotification(): void {
    if (this.isInDowntime()) {
      return;
    }
    this.alertSentFlags.delete('downtime_alert');
    this.cancelAlertNotification(NotificationType.DOWNTIME_ALERT, '撤除已不成立的停用预警');
  }

  /**
   * 「重置所有数据」时撤掉全部预警常驻通知。
   *
   * ⚠️ 必须由重置路径显式调用，**不能**塞进 initialize()：initialize() 同时也是冷启动入口，
   * 在那里撤除会和随后的 checkUsageAlerts() 补发形成竞态（cancel 是异步的，可能落在 publish 之后，
   * 结果横幅被撤掉又不再补发）。
   *
   * 不撤的后果：这些预警是 `isUnremovable` 的，跨日清零（onDateChanged）也要靠应用存活才会执行，
   * 进程被杀就永久残留一条点不掉、且文案与界面矛盾的横幅；同时标记已清空，用量重新越线还会再发一条。
   */
  resetAlertNotifications(): void {
    this.alertSentFlags.clear();
    this.cancelAlertNotifications();
  }

  getTotalDailyLimitMinutes(): number {
    return this.totalDailyLimitMinutes;
  }

setTotalDailyLimitMinutes(minutes: number): void {
    // 备份恢复是唯一能绕过设置页滑块（30–480）写入本值的入口，故在 manager 侧兜底钳位：
    // 非有限数（JSON 里写成字符串）回退默认，区间外收拢到边界。
    if (typeof minutes !== 'number' || !Number.isFinite(minutes)) {
      minutes = DEFAULT_TOTAL_LIMIT_MINUTES;
    } else {
      minutes = Math.round(Math.max(MIN_TOTAL_LIMIT_MINUTES, Math.min(MAX_TOTAL_LIMIT_MINUTES, minutes)));
    }
    this.totalDailyLimitMinutes = minutes;
    this.weeklyTrendCache = null;
    this.streakCacheKey = '';
    this.appUsedDaysStreakCacheKey = '';
    this.syncTierAlertNotifications();
    PreferenceManager.getInstance().setNumber(PREFS_KEY_TOTAL_LIMIT, this.totalDailyLimitMinutes);
  }

  /**
   * 限额变更后重算当前生效档位，并撤除已不再成立的高档预警。
   *
   * 背景（2026-10-02 实机实测）：把限额从 30 分钟调回 180 分钟后，用量 54 分钟只剩 30%，
   * 但「今日屏幕使用时间已超额 / 您已达到今日设定的屏幕使用总限额」仍整条挂在通知栏——
   * 其文案断言的状态已不成立。原先只有 cancelAlertNotifications 会清预警，而它仅在
   * 跨日重置（onDateChanged）时触发；checkUsageAlerts 的 else-if 链也只在"升档"方向有
   * cancelSupersededTierAlerts，"降档"（抬限额 / 备份恢复出更大的限额）无人处理。
   *
   * 这里与档位取代同源处理：仅当某高档已不再对应当前用量时才撤除并清其 flag，
   * 使用量重新越线还能再次提醒；档位未变则不做任何操作，不会无故打扰。
   */
  private syncTierAlertNotifications(): void {
    const currentIndex = computeLimitTierIndex(this.getTotalUsageSeconds(), this.totalDailyLimitMinutes);
    // 标记与通知分开处理：标记清"当前档以外的全部"（含当前档以下——那些横幅
    // 早已被更高档撤除，留着标记会挡住重新成立时的重发），通知只撤"当前档以上"。
    const clearFlags = limitTiersToClearFlag(currentIndex);
    for (let i = 0; i < clearFlags.length; i++) {
      this.alertSentFlags.delete(TOTAL_LIMIT_TIER_FLAGS[clearFlags[i]]);
    }
    const toCancel = limitTiersToCancel(currentIndex);
    for (let i = 0; i < toCancel.length; i++) {
      this.cancelTierNotification(TOTAL_LIMIT_TIER_IDS[toCancel[i]]);
    }
  }

  private checkUsageAlerts(): void {
    if (this.isInDowntime()) {
      const rule = this.downtimeRule;
      this.sendUsageAlert('downtime_alert', NotificationType.DOWNTIME_ALERT, '当前处于免打扰时段',
        `当前时间处于免打扰时段（${formatTimeRange(rule)}），建议减少屏幕使用，保护身心健康。`);
    }

    // 档位判定统一走 computeLimitTierIndex（原先此处是一份独立的 else-if 副本）
    const tierIndex = computeLimitTierIndex(this.getTotalUsageSeconds(), this.totalDailyLimitMinutes);
    if (tierIndex === LIMIT_TIER_100) {
      const alert = TOTAL_LIMIT_TIER_ALERTS[LIMIT_TIER_100];
      this.sendUsageAlert('total_limit_100', NotificationType.TOTAL_LIMIT_100, alert.title, alert.text);
    } else if (tierIndex === LIMIT_TIER_80) {
      const alert = TOTAL_LIMIT_TIER_ALERTS[LIMIT_TIER_80];
      this.sendUsageAlert('total_limit_80', NotificationType.TOTAL_LIMIT_80, alert.title, alert.text);
    } else if (tierIndex === LIMIT_TIER_50) {
      const alert = TOTAL_LIMIT_TIER_ALERTS[LIMIT_TIER_50];
      this.sendUsageAlert('total_limit_50', NotificationType.TOTAL_LIMIT_50, alert.title, alert.text);
    }
  }

private sendUsageAlert(flag: string, notificationId: number, title: string, text: string): void {
    if (this.alertSentFlags.get(flag)) {
      return;
    }

    try {
      // 先检查通知使能再标记已发送：否则通知关闭时越线会白白烧掉当日该档预警，
      // 用户当天再开启通知也补发不出来（与 repost*Alert 的判断顺序保持一致）
      if (!notificationManager.isNotificationEnabledSync()) {
        return;
      }
      this.alertSentFlags.set(flag, true);
      this.cancelSupersededTierAlerts(notificationId);
      notificationManager.publish({
        id: notificationId,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: { title, text, additionalText: SELF_APP_NAME }
        },
        isOngoing: true,
        isUnremovable: true
      }).catch((err: Error) => {
        // 发布失败必须回滚标记：标记语义是"该档横幅已在通知栏"，烧掉后当天不会再补发
        this.alertSentFlags.delete(flag);
        hilog.warn(0x0000, TAG, '%{public}s', '发送使用预警通知失败：' + err.message);
      });
    } catch (err) {
      hilog.error(0x0000, TAG, '%{public}s', '发送使用预警通知异常：' + formatError(err));
    }
  }

/**
   * 撤除已被更高档限额预警取代的低档通知。
   * 三档预警为互斥关系，而预警通知是 isUnremovable（用户无法手动划掉），
   * 跨日才由 cancelAlertNotifications 统一清理；若不按档撤除，通知栏会同时挂着
   * 「已过半 / 即将超额 / 已超额」等互相矛盾的常驻通知。
   *
   * 撤除通知的同时**必须清掉对应标记**：标记的语义是"该档横幅当前在通知栏里"。
   * 原实现只撤通知、不清标记，于是被取代的低档标记会一直为 true。之后用户
   * 抬高限额、用量重新落回该档区间时，sendUsageAlert 会因标记为 true 直接 return，
   * 横幅永远发不出来（现象见 models/UsageStatsMath.limitTiersToClearFlag 的注释）。
   */
  private cancelSupersededTierAlerts(notificationId: number): void {
    const tierIndex = TOTAL_LIMIT_TIER_IDS.indexOf(notificationId);
    if (tierIndex <= 0) {
      return;
    }
    const superseded = limitTiersSupersededBy(tierIndex);
    for (let i = 0; i < superseded.length; i++) {
      this.alertSentFlags.delete(TOTAL_LIMIT_TIER_FLAGS[superseded[i]]);
      this.cancelTierNotification(TOTAL_LIMIT_TIER_IDS[superseded[i]]);
    }
  }

  /**
   * 撤除单条限额预警通知。
   *
   * 原实现是空 catch，把失败彻底吞掉：2026-10-02 实机核验时无法判断高档预警是否真的
   * 取代了低档，只能靠反复重开通知栏反推文本。改为记录真实 code，但 1600007
   * （notification does not exist）属于预期情形——直接跨档（如 50%→100%）时中间档
   * 本就没发布过，属正常而非故障，不记日志以免每次跨档都刷 error。
   *
   * 原先与 cancelAlertNotification 是两份逐行相同的副本（仅日志文案不同），
   * 现统一为 cancelAlertNotification(id, reason)，1600007 白名单只有一处需维护。
   */
  private cancelTierNotification(notificationId: number): void {
    this.cancelAlertNotification(notificationId, '撤除被取代的限额预警');
  }

  /**
   * 取消全部使用预警常驻通知（跨日重置时调用，避免昨日预警残留到新的一天）
   *
   * 原实现是空 catch，撤除失败完全不可见：残留的 isUnremovable 横幅会挂到新的一天，
   * 而日志里没有任何线索。此处统一走 cancelAlertNotification，与 cancelTierNotification
   * 同样把真实 code 记下来，并同样忽略预期内的 1600007（该档位本就未发布过）。
   */
  private cancelAlertNotifications(): void {
    for (let i = 0; i < TOTAL_LIMIT_TIER_IDS.length; i++) {
      this.cancelAlertNotification(TOTAL_LIMIT_TIER_IDS[i], '撤除预警常驻通知');
    }
    this.cancelAlertNotification(NotificationType.DOWNTIME_ALERT, '撤除停用预警常驻通知');
  }

  /**
   * 撤除单条预警常驻通知（跨日清理、档位取代共用）。
   * 1600007（notification does not exist）属预期情形，不记日志以免每次跨档刷 error。
   * @param reason 日志里的场景描述，便于区分是哪条路径发起的撤除
   */
  private cancelAlertNotification(notificationId: number, reason: string): void {
    notificationManager.cancel(notificationId).catch((err: Error) => {
      const bizErr = err as BusinessError;
      if (bizErr.code === 1600007) {
        return;
      }
      hilog.error(0x0000, TAG, '%{public}s', reason + '失败：id=' +
        notificationId + ' code=' + bizErr.code + ' message=' + bizErr.message);
    });
  }


  /**
   * 重新发布停用时间预警通知（通知被删除后强制重发）
   */
  private async repostDowntimeAlert(): Promise<boolean> {
    if (!this.isInDowntime()) {
      return false;
    }
    const rule = this.downtimeRule;
    const timeRange = formatTimeRange(rule);
    try {
      if (!notificationManager.isNotificationEnabledSync()) {
        return false;
      }
      await notificationManager.publish({
        id: NotificationType.DOWNTIME_ALERT,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: '当前处于免打扰时段',
            text: `当前时间处于免打扰时段（${timeRange}），建议减少屏幕使用，保护身心健康。`,
            additionalText: SELF_APP_NAME
          }
        },
        isOngoing: true,
        isUnremovable: true
      });
      hilog.info(0x0000, TAG, '%{public}s', '[重发停用时间预警] 成功');
      return true;
    } catch (err) {
      const errorMsg = err instanceof Error ? err.message : formatError(err);
      hilog.error(0x0000, TAG, '%{public}s', '[重发停用时间预警] 失败: ' + errorMsg);
      return false;
    }
  }

/**
   * 重新发布总限额预警通知（通知被删除后强制重发）
   * @param level '50' | '80' | '100'，对应注册重发回调时绑定的档位
   */
  private async repostTotalLimitAlert(level: string): Promise<boolean> {
    // 档位判定统一走 computeLimitTierIndex（原先此处是第三份独立的 else-if 副本）。
    // 判据与 checkUsageAlerts 一致：先算出「当前仍生效的最高档」，
    // 再要求它正好等于本回调绑定的档位。若按单档独立判据，已被更高档取代的低档
    // 会被重发服务重新挂回通知栏，与 cancelSupersededTierAlerts 形成反复拉锯。
    const tierIndex = computeLimitTierIndex(this.getTotalUsageSeconds(), this.totalDailyLimitMinutes);
    const currentId = tierIndex === LIMIT_TIER_NONE ? 0 : TOTAL_LIMIT_TIER_IDS[tierIndex];
    if (tierIndex === LIMIT_TIER_NONE || currentId !== levelNotificationId(level)) {
      return false;
    }

    // 文案与 checkUsageAlerts 共用同一张档位表，避免"首次发布"与"重发"两处措辞漂移
    const alert = TOTAL_LIMIT_TIER_ALERTS[tierIndex];

    try {
      if (!notificationManager.isNotificationEnabledSync()) {
        return false;
      }
      await notificationManager.publish({
        id: currentId,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: { title: alert.title, text: alert.text, additionalText: SELF_APP_NAME }
        },
        isOngoing: true,
        isUnremovable: true
      });
      hilog.info(0x0000, TAG, '%{public}s', `[重发总限额预警 ${level}%] 成功`);
      return true;
    } catch (err) {
      const errorMsg = err instanceof Error ? err.message : formatError(err);
      hilog.error(0x0000, TAG, '%{public}s', `[重发总限额预警 ${level}%] 失败: ` + errorMsg);
      return false;
    }
  }

  /**
   * 当前是否处于免打扰时段。
   *
   * 判定逻辑抽至纯函数 `UsageStatsMath.isInDowntimeRange`（有单测锁定）。
   *
   * ⚠️ 起止时刻相同 = **全天免打扰**，判别符必须是 `<`，勿改成 `<=` ——
   * 它与 `ReminderTimeUtils.isInActiveWindow` 的 `<=` 刻意相反（后者判定的是
   * "提醒的活跃窗口"，起止相同时只该活跃那一分钟；本方法是"禁用窗口"，
   * 起止相同表示一整天都禁用）。2026-10-13 曾有人据其把这里"修正"成 `<=`。
   */
  isInDowntime(): boolean {
    if (!this.downtimeRule.enabled) {
      return false;
    }
    const now = new Date();
    return isInDowntimeRange(now.getHours() * 60 + now.getMinutes(),
      this.downtimeRule.startHour * 60 + this.downtimeRule.startMinute,
      this.downtimeRule.endHour * 60 + this.downtimeRule.endMinute);
  }

  getWeeklyTrendInfo(): WeeklyTrendInfo {
    this.persistDailyHistory();

    const todayStr = getTodayDateString();
    const liveMinutes = Math.floor(this.computeTodayScreenOnSeconds() / 60);
    const cacheKey = todayStr + '_' + liveMinutes.toString();
    if (this.weeklyTrendCache && this.weeklyTrendCacheKey === cacheKey) {
      return this.weeklyTrendCache;
    }

    // 缓存未命中才需要当前时刻（下方按日回溯 7 天用），命中时每秒省一个 Date 分配
    const now = new Date();

    const dailyMinutes: number[] = [];
    const historyMap = new Map<string, number>();
    for (let i = 0; i < this.dailyHistory.length; i++) {
      historyMap.set(this.dailyHistory[i].date, this.dailyHistory[i].totalMinutes);
    }

    for (let i = 6; i >= 0; i--) {
      const date = new Date(now.getTime() - i * 24 * 60 * 60 * 1000);
      const dateStr = formatDate(date);

      let minutes = historyMap.get(dateStr) ?? 0;
      if (i === 0) {
        const liveSeconds = this.computeTodayScreenOnSeconds();
        minutes = Math.max(minutes, Math.floor(liveSeconds / 60));
      }
      dailyMinutes.push(minutes);
    }

    const totalMinutes = dailyMinutes.reduce((a, b) => a + b, 0);
    const averageMinutes = Math.round(totalMinutes / 7);
    const maxMinutes = Math.max(...dailyMinutes);

    const recent3 = dailyMinutes.slice(4, 7).reduce((a, b) => a + b, 0) / 3;
    const previous3 = dailyMinutes.slice(1, 4).reduce((a, b) => a + b, 0) / 3;
    const trend = computeTrend(recent3, previous3);

    const todayMinutes = dailyMinutes[6];
    const sorted = [...dailyMinutes].sort((a, b) => b - a);
    const todayRank = sorted.indexOf(todayMinutes);

    this.weeklyTrendCache = {
      dailyMinutes,
      averageMinutes,
      maxMinutes,
      totalMinutes,
      trendDirection: trend.trendDirection,
      trendDeltaPercent: trend.trendDeltaPercent,
      todayRank
    };
    this.weeklyTrendCacheKey = cacheKey;
    return this.weeklyTrendCache;
  }

  // 睡前窗口的重叠秒数计算直接调用 models/UsageStatsMath.computeOverlapInWindow
  // （含跨午夜两段拆分，有单测锁定），不再经同名私有方法二次转发。

  /**
   * 统计亮屏记录落在 [startMinutes, endMinutes]（当日分钟刻度）内的总秒数
   * 供 SleepManager 计算睡前窗口使用；窗口的**长度与锚点都由调用方决定**
   * （见其 updatePreSleepUsageFromRecords：锚点取停用开始时刻，长度取
   * preSleepRestrictionMinutes，15–180 分钟可配置）
   * 跨午夜窗口（startMinutes > endMinutes）时同时查昨天和今天的记录
   */
  getUsageSecondsInWindow(startMinutes: number, endMinutes: number): number {
    const today = getTodayDateString();
    const isCrossMidnight = startMinutes > endMinutes;
    // 窗口锚点：跨午夜窗口在「凌晨」（当前分钟 < endMinutes）时应锚到**昨天**。
    // 否则今天 00:00–endMinutes 的亮屏会被按"今晚"的窗口去算而落空，
    // 而它其实属于昨晚那个睡前窗口（2026-10-24 审计发现的"凌晨那半段恒为 0"）。
    let windowStartDayMs: number = getDayStartTimestamp(today);
    const now: Date = new Date();
    const nowMinutes: number = now.getHours() * 60 + now.getMinutes();
    if (isCrossMidnight && nowMinutes < endMinutes) {
      windowStartDayMs -= 86400000;
    }

    // 跨午夜窗口（startMinutes > endMinutes）需同时统计昨天与今天的记录：
    // 昨天的亮屏会话可能跨入今天的凌晨窗口。今天的日期恒为 today，
    // 昨天则由 today 往前推一天得出——不可用 currentDate（它跟踪的是今天，
    // 否则两次循环会命中同一批记录导致睡前使用时长翻倍）。
    // 纯计算见 models/UsageStatsMath.sumSecondsInWindow（有单测锁定）。
    const yesterdayDate = formatDate(new Date(getDayStartTimestamp(today) - 86400000));
    let totalSeconds = sumSecondsInWindow(
      this.screenOnRecords, today, yesterdayDate, startMinutes, endMinutes, windowStartDayMs);

    // 进行中会话（仅在当前日期一致时参与，避免与已结算记录重复）
    if (this.currentScreenOnStart > 0 && this.currentDate === today) {
      totalSeconds += computeOverlapInWindow(
        this.currentScreenOnStart, Date.now(), startMinutes, endMinutes, windowStartDayMs);
    }

    return totalSeconds;
  }

  /**
   * 清理旧的解锁记录（只保留今天的）
   */
  private cleanupOldUnlockRecords(): void {
    const today = getTodayDateString();
    const todayStart = getDayStartTimestamp(today);
    this.unlockRecords = this.unlockRecords.filter(record => record.timestamp >= todayStart);
  }

  /**
   * 清理旧的每日解锁历史（保留30天）
   */
  private cleanupOldUnlockHistory(): void {
    const cutoff = Date.now() - HISTORY_RETENTION_MS;
    this.dailyUnlockHistory = this.dailyUnlockHistory.filter(entry => {
      const entryTime = getDayStartTimestamp(entry.date);
      return entryTime >= cutoff;
    });
  }

  /**
   * 记录一次解锁事件
   */
  private recordUnlock(): void {
    const now = Date.now();
    const hour = new Date(now).getHours();

    this.unlockRecords.push({
      timestamp: now,
      hour: hour
    });
    this.unlockInsightsCache = null;
    this.todayUnlockCache = -1;
    this.computeTodayUnlockStatsCache = null;

    this.cleanupOldUnlockRecords();
    this.persistUnlockData();
  }

  /**
   * 计算今日解锁统计（按小时分布 + 总次数）
   */
  private computeTodayUnlockStats(): TodayUnlockStats {
    const today = getTodayDateString();
    if (this.computeTodayUnlockStatsCache && this.computeTodayUnlockStatsCacheDate === today) {
      return this.computeTodayUnlockStatsCache;
    }
    const todayStartMs = getDayStartTimestamp(today);
    const hourlyCounts: number[] = new Array<number>(24).fill(0);
    let totalCount = 0;
    this.unlockRecords.forEach(record => {
      if (record.timestamp >= todayStartMs) {
        hourlyCounts[record.hour]++;
        totalCount++;
      }
    });
    const result: TodayUnlockStats = {
      hourlyCounts: hourlyCounts,
      totalCount: totalCount
    };
    this.computeTodayUnlockStatsCache = result;
    this.computeTodayUnlockStatsCacheDate = today;
    return result;
  }

  /**
   * 持久化解锁数据
   */
  private persistUnlockData(): void {
    PreferenceManager.getInstance().setString(PREFS_KEY_UNLOCK_HISTORY, JSON.stringify(this.unlockRecords));

    const today = getTodayDateString();
    const stats = this.computeTodayUnlockStats();
    const todayUnlockCount = stats.totalCount;
    const hourlyCounts = stats.hourlyCounts;

    const existingIndex = this.dailyUnlockHistory.findIndex(entry => entry.date === today);
    if (existingIndex >= 0) {
      this.dailyUnlockHistory[existingIndex].unlockCount = todayUnlockCount;
      this.dailyUnlockHistory[existingIndex].hourlyCounts = hourlyCounts;
    } else {
      this.dailyUnlockHistory.push({
        date: today,
        unlockCount: todayUnlockCount,
        hourlyCounts: hourlyCounts
      });
    }

    this.cleanupOldUnlockHistory();
    PreferenceManager.getInstance().setString(PREFS_KEY_DAILY_UNLOCK_HISTORY, JSON.stringify(this.dailyUnlockHistory));
  }

  /**
   * 获取今日解锁次数
   *
   * 首页 1 秒 tick 经 DailyGoalManager 调用，故不复用 computeTodayUnlockStats：
   * 那条路径每次要new 一个 24 长度数组并组装结果对象，而这里只需要总数。
   * 改为单趟计数，零分配，语义与 stats.totalCount 完全一致。
   */
  getTodayUnlockCount(): number {
    const today = getTodayDateString();
    if (this.todayUnlockCache >= 0 && this.todayUnlockCacheDate === today) {
      return this.todayUnlockCache;
    }
    const todayStartMs = getDayStartTimestamp(today);
    const records = this.unlockRecords;
    let total = 0;
    for (let i = 0; i < records.length; i++) {
      if (records[i].timestamp >= todayStartMs) {
        total++;
      }
    }
    this.todayUnlockCache = total;
    this.todayUnlockCacheDate = today;
    return total;
  }

  /**
   * 获取最近一个已完成日的解锁次数（用于"单日解锁少于 N 次"成就判定）
   * @returns 最近一个已完成日的解锁次数；-1 表示没有已完成日数据（此时不授予成就）
   */
  getLastCompletedDayUnlockCount(): number {
    const today = getTodayDateString();
    let latest: DailyUnlockEntry | null = null;
    for (let i = 0; i < this.dailyUnlockHistory.length; i++) {
      const entry = this.dailyUnlockHistory[i];
      if (entry.date !== today && (!latest || entry.date > latest.date)) {
        latest = entry;
      }
    }
    return latest ? latest.unlockCount : -1;
  }

  /**
   * 获取解锁洞察数据
   */
  getUnlockInsights(): UnlockInsights {
    const today = getTodayDateString();
    if (this.unlockInsightsCache && this.unlockInsightsCacheKey === today) {
      return this.unlockInsightsCache;
    }

    const yesterday = new Date(Date.now() - 24 * 60 * 60 * 1000);
    const yesterdayStr = formatDate(yesterday);

    const stats = this.computeTodayUnlockStats();
    const todayUnlockCount = stats.totalCount;
    const hourlyUnlockCounts = stats.hourlyCounts;

    const historyMap = new Map<string, DailyUnlockEntry>();
    for (let i = 0; i < this.dailyUnlockHistory.length; i++) {
      historyMap.set(this.dailyUnlockHistory[i].date, this.dailyUnlockHistory[i]);
    }

    const yesterdayEntry = historyMap.get(yesterdayStr);
    const yesterdayUnlockCount = yesterdayEntry ? yesterdayEntry.unlockCount : 0;

    const weeklyUnlockCounts: number[] = [];
    const now = new Date();
    for (let i = 6; i >= 0; i--) {
      const date = new Date(now.getTime() - i * 24 * 60 * 60 * 1000);
      const dateStr = formatDate(date);
      const entry = historyMap.get(dateStr);
      weeklyUnlockCounts.push(entry ? entry.unlockCount : 0);
    }

    let peakHour = 0;
    let peakHourCount = 0;
    hourlyUnlockCounts.forEach((count: number, hour: number) => {
      if (count > peakHourCount) {
        peakHourCount = count;
        peakHour = hour;
      }
    });

    const recent3 = weeklyUnlockCounts.slice(4, 7).reduce((a, b) => a + b, 0) / 3;
    const previous3 = weeklyUnlockCounts.slice(1, 4).reduce((a, b) => a + b, 0) / 3;
    const trend = computeTrend(recent3, previous3);

    this.unlockInsightsCache = {
      todayUnlockCount,
      yesterdayUnlockCount,
      weeklyUnlockCounts,
      peakHour,
      peakHourCount,
      hourlyUnlockCounts,
      trendDirection: trend.trendDirection,
      trendDeltaPercent: trend.trendDeltaPercent
    };
    this.unlockInsightsCacheKey = today;
    return this.unlockInsightsCache;
  }

  /**
   * 导出一键解锁记录（用于备份）
   */
  exportUnlockData(): UnlockBackupData {
    return {
      records: this.unlockRecords.map((record: UnlockRecord): UnlockRecordBackup => {
        const backup: UnlockRecordBackup = {
          timestamp: record.timestamp,
          hour: record.hour
        };
        return backup;
      }),
      dailyHistory: this.dailyUnlockHistory.map((entry: DailyUnlockEntry): DailyUnlockEntryBackup => {
        const backup: DailyUnlockEntryBackup = {
          date: entry.date,
          unlockCount: entry.unlockCount,
          hourlyCounts: [...entry.hourlyCounts]
        };
        return backup;
      })
    };
  }

  /**
   * 导入解锁记录（备份恢复）
   */
  importUnlockData(data: UnlockBackupData): void {
    // 与 prefs 载入路径共用同一套逐字段过滤，避免两条恢复入口口径不一
    if (data && Array.isArray(data.records)) {
      const restored: UnlockRecord[] = data.records.map((record: UnlockRecordBackup): UnlockRecord => {
        const item: UnlockRecord = {
          timestamp: record.timestamp,
          hour: record.hour
        };
        return item;
      });
      this.unlockRecords = this.filterValidUnlockRecords(restored);
    }
    if (data && Array.isArray(data.dailyHistory)) {
      const restored: DailyUnlockEntry[] = data.dailyHistory.map((entry: DailyUnlockEntryBackup): DailyUnlockEntry => {
        const item: DailyUnlockEntry = {
          date: entry.date,
          unlockCount: entry.unlockCount,
          hourlyCounts: Array.isArray(entry.hourlyCounts) ? entry.hourlyCounts : new Array<number>(24).fill(0)
        };
        return item;
      });
      this.dailyUnlockHistory = this.filterValidDailyUnlockHistory(restored);
    }
    // 三个缓存必须一起清：它们分别由 getTodayUnlockCount（今日解锁/每日目标「解锁控制」）
    // 与 computeTodayUnlockStats（首页「今日解锁 N 次」与高峰时段）读取，
    // 而后两者都会被 getUnlockInsights 间接用到 —— 只清 unlockInsightsCache 等于清了个寂寞，
    // 首页与每日目标会继续显示恢复前的旧值，直到下一次真实解锁或进程重启。
    this.unlockInsightsCache = null;
    this.unlockInsightsCacheKey = '';
    this.todayUnlockCache = -1;
    this.todayUnlockCacheDate = '';
    this.computeTodayUnlockStatsCache = null;
    this.computeTodayUnlockStatsCacheDate = '';
    PreferenceManager.getInstance().setString(PREFS_KEY_UNLOCK_HISTORY, JSON.stringify(this.unlockRecords));
    PreferenceManager.getInstance().setString(PREFS_KEY_DAILY_UNLOCK_HISTORY, JSON.stringify(this.dailyUnlockHistory));
  }
}
