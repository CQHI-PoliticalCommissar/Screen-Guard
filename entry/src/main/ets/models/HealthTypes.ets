/**
 * 健康使用手机 - 核心数据模型与类型定义
 * 所有数据本地处理，不上传云端
 */

import { deriveAccentFillColor, normalizeHexColor } from './AccentColorMath';

/**
 * 自定义强调色「填充色」推导的记忆化缓存。
 *
 * `accentFillHex` 在一次页面渲染里会被调用几十次（按钮/进度条/胶囊），而自定义色的
 * 填充推导需要最多 24 次插值 + 对比度计算。缓存键 = 规范化色值 + 明暗标记。
 * 纯函数、同入参必同出参，缓存不会改变可见行为。
 */
const customAccentFillCache: Map<string, string> = new Map();

/** 健康状态等级：正常 / 警告 / 紧急 */
export enum HealthStatus {
  NORMAL = 'normal',
  WARNING = 'warning',
  EMERGENCY = 'emergency'
}

/** 感知灯颜色（对应各健康状态的色值） */
export enum LightSenseColor {
  NORMAL = '#4ECDC4',
  WARNING = '#FFB347',
  EMERGENCY = '#FF6B6B'
}

/** 应用使用记录：单个应用在今日的累计使用情况 */
export interface AppUsageInfo {
  bundleName: string;
  appName: string;
  durationSeconds: number;
  category: AppCategory;
  icon?: Resource;
}

/** 应用分类（用于停用时间 / 分类限额等管控规则） */
export enum AppCategory {
  SOCIAL = 'social',
  VIDEO = 'video',
  GAME = 'game',
  PRODUCTIVITY = 'productivity',
  SYSTEM = 'system',
  OTHER = 'other'
}

export const STATUS_COLOR_MAP: Record<HealthStatus, string> = {
  [HealthStatus.NORMAL]: LightSenseColor.NORMAL,
  [HealthStatus.WARNING]: LightSenseColor.WARNING,
  [HealthStatus.EMERGENCY]: LightSenseColor.EMERGENCY
};

/**
 * 应用包名
 */
export const APP_BUNDLE_NAME = 'com.soviet.cyberselfdiscipline';

/**
 * 应用显示名（通知标题/附加文案等处使用）。
 * 集中定义以避免各manager 各自硬编码字面量导致改名时漏改。
 */
export const SELF_APP_NAME = '萤光守护';

/**
 * 周内所有天（0 = 周日 ... 6 = 周六）
 */
export const ALL_WEEKDAYS: number[] = [0, 1, 2, 3, 4, 5, 6];

/**
 * 历史数据保留期：120 天（毫秒）。
 * 此前 `UsageStatsManager` 与 `FocusModeManager` 各写一份逐字节相同的私有常量。
 * ⚠️ `DailyGoalManager` 的打卡历史保留期是 **90 天**（语义不同，不要用这个常量）。
 *
 * 30 → 120 的原因（2026-10-24 审计）：`AchievementManager` 有「连续 100 天达标」
 * （streak_100）成就，而 `computeStreakDays` 逐日回溯、缺一天即中断；历史只留 30 天时
 * 该成就**物理不可达**。120 天给 100 天留出余量，存储增量仅每天一条 {date,totalMinutes}。
 */
export const HISTORY_RETENTION_MS = 120 * 24 * 60 * 60 * 1000;

/**
 * 连续天数回溯上限：365 天。
 * 此前 `UsageStatsManager` 与 `DailyGoalManager` 各写一份。
 */
export const MAX_STREAK_LOOKBACK_DAYS = 365;

/**
 * 星期简称标签
 */
export const WEEKDAY_LABELS: string[] = ['日', '一', '二', '三', '四', '五', '六'];

/**
 * 星期全称标签。
 * 单字版 `WEEKDAY_LABELS` 早已收敛到此处，但全称版此前仍有两份逐字节相同的私有副本
 * （`Sleep.WEEKDAY_FULL_LABELS` 与 `ReminderTimeUtils.WEEKDAY_NAMES`），一并收敛。
 */
export const WEEKDAY_FULL_LABELS: string[] = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];

/**
   * 免打扰提醒规则。
   *
   * ⚠️ 旧名「停用时间规则」有严重误导性：字面意思像"到点锁住手机"，而它**只发提醒**，
   * 没有任何限制/阻断应用使用的能力。注释与 UI 文案都必须按「提醒」口径书写，
   * 否则用户会以为到点手机被管控、找不到原因。
   */
export interface DowntimeRule {
  startHour: number;
  startMinute: number;
  endHour: number;
  endMinute: number;
  /**
   * 预留字段，**当前版本未生效**。
   *
   * ⚠️ 本功能最终定位是「提醒」——它只发通知，没有任何限制/阻断应用使用的能力。
   * 该字段被完整持久化、备份、校验，却**没有任何一处读它的值做决策**
   * （消费函数 `isCategoryRestricted()` 早已删除，`bundleToCategory` 这类包名→分类映射也不存在），
   * 设置页同样没有对应入口。即「免打扰时段限制视频/游戏/社交」这个承诺**从未生效过**。
   *
   * 保留字段本身是为了**备份向后兼容**（老备份里的该字段能被安全忽略，而不是被判为格式错误）。
   * ⚠️ 不要因为它还在就以为功能存在；若日后要真做拦截，需要同时补齐：包名→分类映射、
   * 拦截判定接入点、以及设置页的分类选择 UI —— 三者缺一不可。
   */
  restrictedCategories: AppCategory[];
  enabled: boolean;
}

/** 睡眠数据：昨晚睡眠时长、睡前使用时长与质量评分 */
export interface SleepData {
  sleepDurationMinutes: number;
  preSleepUsageMinutes: number;
  score: number;
  deepSleepMinutes?: number;
  shallowSleepMinutes?: number;
  dreamSleepMinutes?: number;
}

/** 睡眠偏好设置 */
export interface SleepPreferences {
  sleepGoalMinutes: number;
  bedtimeReminderOffsetMinutes: number;
  enablePreSleepRestriction: boolean;
  preSleepRestrictionMinutes: number;
}

/** 健康胶囊聚合数据（桌面服务卡片 widget / HealthCard 展示） */
export interface HealthCapsuleData {
  eyeUsageSeconds: number;
  remainingMinutes: number;
  status: HealthStatus;
  streakDays: number;
}

/** 周使用趋势信息 */
export interface WeeklyTrendInfo {
  dailyMinutes: number[];
  averageMinutes: number;
  maxMinutes: number;
  totalMinutes: number;
  trendDirection: 'up' | 'down' | 'stable';
  trendDeltaPercent: number;
  todayRank: number;
}

/** 解锁洞察：今日/昨日/本周解锁统计与高峰时段 */
export interface UnlockInsights {
  todayUnlockCount: number;
  yesterdayUnlockCount: number;
  weeklyUnlockCounts: number[];
  peakHour: number;
  peakHourCount: number;
  hourlyUnlockCounts: number[];
  trendDirection: 'up' | 'down' | 'stable';
  trendDeltaPercent: number;
}

/**
 * 将 YYYY-MM-DD 日期字符串转换为当天 00:00:00 的时间戳
 */
export function getDayStartTimestamp(dateStr: string): number {
  return new Date(dateStr + 'T00:00:00').getTime();
}

/**
 * 格式化日期为 YYYY-MM-DD
 */
export function formatDate(date: Date): string {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
}

/**
 * 时刻格式化：小时+分钟 → HH:MM（两位补零）
 *
 * 此前全库有 6 处各自重复这段 padStart 拼接（Settings/HealthReminderControl 的私有
 * formatTime、UsageStatsManager.formatTimeRange、Index 的停用时间与高峰时段），
 * 统一收敛到此处以免各自漂移。刻意不做钳位：入参非法时与原实现一样原样输出。
 */
export function formatHourMinute(hour: number, minute: number): string {
  return `${hour.toString().padStart(2, '0')}:${minute.toString().padStart(2, '0')}`;
}

/**
 * 今天的日期字符串（YYYY-MM-DD），按秒桶记忆化。 *
 * 此前 `UsageStatsManager` 与 `DailyGoalManager` 各有一份逐字节相同的私有副本
 * `formatDate(new Date())`，而首页 1s tick 的链路上它被调用 5 次
 * （checkDateRollover / refreshUsage / getWeeklyTrendInfo / getTodayUnlockCount /
 * getUnlockInsights），即每秒 5 次 Date 分配 + 5 次 padStart 拼接，
 * 而结果在同一天内恒定不变。
 *
 * 收敛到此并加秒桶缓存：同一秒内 `formatDate` 结果逐字节相同，
 * 跨午夜（00:00:00）必然落入新的秒桶自动失效，语义等价。
 * 顺带消除两套"今天"判据各自漂移的可能（跨日清零依赖它）。
 */
let todayDateCache: string = '';
let todayDateCacheSecond: number = -1;

export function getTodayDateString(): string {
  const second = Math.floor(Date.now() / 1000);
  if (todayDateCacheSecond === second) {
    return todayDateCache;
  }
  todayDateCache = formatDate(new Date());
  todayDateCacheSecond = second;
  return todayDateCache;
}

/**
 * 判断某个 `YYYY-MM-DD` 是否为「nowMs 所在日期的前一天」（本地时区）。
 *
 * 抽成纯函数的原因：DailyGoalManager 的「昨日目标快照」在两处各写了一份日期判据，
 * 其中一处误写成「等于今天」，导致按钮亮着却永远复制失败且很难发现。
 * 判据收口到这里 + LocalUnit 锁定后，逻辑再也不会各自漂移。
 */
export function isYesterdayDateKey(dateKey: string, nowMs: number): boolean {
  return dateKey === formatDate(new Date(nowMs - 24 * 60 * 60 * 1000));
}

/**
 * 强调色预设：用户可在设置里选其一，影响全应用按钮、进度条、卡片标题色等。
 * 浅色/暗色分别存两套十六进制值（不含 #），ThemeColor.accentColor* 会按 isDarkMode 取用。
 * 默认第一项（蓝色）保持与旧版一致，老用户无感知。
 */
export interface AccentColorPreset {
  key: string;
  /** 预设名（设置页「强调色」下拉项文案） */
  label: string;
  /** 浅色模式下的文本色：作为文字/图标色，须满足 WCAG AA */
  light: string;
  /** 深色模式下的文本色：作为文字/图标色，须满足 WCAG AA */
  dark: string;
  /** 浅色模式下的填充色：承载白色文本，对比度须 ≥ 4.5:1 */
  lightFill: string;
  /** 深色模式下的填充色：承载白色文本，对比度须 ≥ 4.5:1 */
  darkFill: string;
}

/** 可选强调色预设列表，顺序即设置页显示顺序。第一项为默认值。 */
export const ACCENT_COLOR_PRESETS: AccentColorPreset[] = [
  { key: 'blue', label: '蓝色', light: '#0066CC', dark: '#6CB6FF', lightFill: '#0066CC', darkFill: '#3578C4' },
  { key: 'green', label: '绿色', light: '#1B7A34', dark: '#4ADE80', lightFill: '#1B7A34', darkFill: '#1F7A43' },
  { key: 'red', label: '红色', light: '#CC2936', dark: '#FF6B6B', lightFill: '#CC2936', darkFill: '#CC3530' },
  { key: 'orange', label: '橙色', light: '#9A6400', dark: '#FFB84D', lightFill: '#9A6400', darkFill: '#996000' },
  { key: 'purple', label: '紫色', light: '#4A47CC', dark: '#9B8FFF', lightFill: '#4A47CC', darkFill: '#4A47B8' },
  { key: 'cyan', label: '青色', light: '#0077A3', dark: '#4DC9FF', lightFill: '#0077A3', darkFill: '#1A7699' }
];

/** 默认强调色预设 key（蓝色） */
export const DEFAULT_ACCENT_COLOR_KEY = 'blue';


/**
 * 把「旧系统强调色 / 提醒类型身份色」归一到强调色预设 key。
 * 返回空串表示该 hex 不对应任何预设（此时应原样返回）。
 *
 * 背景：HealthReminderControl 按提醒类型注入固定的 IOS26_* 身份色，
 * 而用户强调色用的是另一套 hex。两套值若不归一，主题层就要维护两份映射。
 */
function accentPresetKeyForHex(hex: string): string {
  if (hex === '#0A84FF' || hex === '#007AFF') {
    return 'blue';
  }
  if (hex === '#30D158' || hex === '#34C759') {
    return 'green';
  }
  if (hex === '#FF9F0A' || hex === '#FF9500') {
    return 'orange';
  }
  if (hex === '#FF453A' || hex === '#FF3B30') {
    return 'red';
  }
  if (hex === '#5E5CE6' || hex === '#AF52DE') {
    return 'purple';
  }
  return '';
}

/**
 * 强调色 → 文本色（作为文字/图标色）。
 *
 * 规则：
 * ① 预设自身的 light/dark 文本色原样返回（它们已按当前模式选好）；
 * ② 旧系统色 / 提醒身份色 → 映射到对应预设的 light/dark 文本色；
 * ③ 其余原样返回。
 */
export function accentTextHex(accentColor: string, isDark: boolean): string {
  for (let i = 0; i < ACCENT_COLOR_PRESETS.length; i++) {
    const p = ACCENT_COLOR_PRESETS[i];
    if (accentColor === p.light || accentColor === p.dark) {
      return accentColor;
    }
  }
  const key = accentPresetKeyForHex(accentColor);
  if (key.length > 0) {
    for (let i = 0; i < ACCENT_COLOR_PRESETS.length; i++) {
      const p = ACCENT_COLOR_PRESETS[i];
      if (p.key === key) {
        return isDark ? p.dark : p.light;
      }
    }
  }
  // 无对应预设的旧系统色（HarmonyOS 品牌紫）：保留原有映射
  if (accentColor === '#BF5AF2') {
    return isDark ? '#DA8FFF' : '#9B3FD6';
  }
  return accentColor;
}

/**
 * 强调色 → 填充色（承载白色文本，对比度须 ≥ 4.5:1）。
 *
 * 规则与 accentTextHex 对称，但取的是预设的 lightFill/darkFill。
 * 关键：深色模式下预设的 dark 文本色很亮（如紫 #9B8FFF 仅约 2.1:1），
 * 直接拿它当填充会让白字糊掉，必须换成配套的深色 fill。
 */
export function accentFillHex(accentColor: string, isDark: boolean): string {
  for (let i = 0; i < ACCENT_COLOR_PRESETS.length; i++) {
    const p = ACCENT_COLOR_PRESETS[i];
    if (accentColor === p.light) {
      return p.lightFill;
    }
    if (accentColor === p.dark) {
      return p.darkFill;
    }
  }
  const key = accentPresetKeyForHex(accentColor);
  if (key.length > 0) {
    for (let i = 0; i < ACCENT_COLOR_PRESETS.length; i++) {
      const p = ACCENT_COLOR_PRESETS[i];
      if (p.key === key) {
        return isDark ? p.darkFill : p.lightFill;
      }
    }
  }
  if (accentColor === '#BF5AF2') {
    return isDark ? '#9848C2' : '#9B3FD6';
  }
  // 自定义强调色（用户自选、不在预设表里）：不能原样当填充 ——
  // 暗色模式下自定义色的「文本色」是提亮过的浅色，直接当填充会让白字糊掉。
  // 交给纯函数按「承载白字 ≥4.5:1」压暗；非法输入仍按原样返回，保持历史行为。
  const normalized: string = normalizeHexColor(accentColor);
  if (normalized.length === 0) {
    return accentColor;
  }
  const cacheKey: string = normalized + '_' + (isDark ? 'dark' : 'light');
  const cached: string | undefined = customAccentFillCache.get(cacheKey);
  if (cached !== undefined) {
    return cached;
  }
  const derived: string = deriveAccentFillColor(normalized);
  customAccentFillCache.set(cacheKey, derived);
  return derived;
}

/**
 * 首页卡片元数据：用于「首页布局」设置（显示/隐藏 + 上移下移排序）。
 *
 * id 与持久化的布局配置（models/HomeCardLayout）一一对应，改动会让
 * 已保存的用户布局失效，故 id 必须保持稳定。
 */
export interface HomeCardItem {
  /** 卡片唯一标识 */
  id: string;
  /** 设置页与首页显示的卡片名 */
  label: string;
  /** 默认展示顺序（越小越靠前） */
  defaultOrder: number;
  /** 默认是否显示在首页 */
  defaultVisible: boolean;
}

/** 全部首页卡片（9 张，顺序即 defaultOrder 升序） */
export const HOME_CARD_ITEMS: HomeCardItem[] = [
  { id: 'usage', label: '今日屏幕使用', defaultOrder: 0, defaultVisible: true },
  { id: 'downtime', label: '免打扰提醒', defaultOrder: 1, defaultVisible: true },
  { id: 'trend', label: '近7天使用趋势', defaultOrder: 2, defaultVisible: true },
  { id: 'unlock', label: '解锁洞察', defaultOrder: 3, defaultVisible: true },
  { id: 'goal', label: '每日目标', defaultOrder: 4, defaultVisible: true },
  { id: 'insights', label: '每周洞察', defaultOrder: 5, defaultVisible: true },
  { id: 'reminder', label: '提醒暂停', defaultOrder: 6, defaultVisible: true },
  { id: 'focus', label: '专注模式', defaultOrder: 7, defaultVisible: true },
  { id: 'achievement', label: '我的成就', defaultOrder: 8, defaultVisible: true }
];
