import { formatError } from '../models/ErrUtils';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { AppLifecycleTracker } from '../managers/AppLifecycleTracker';
import { HealthStateManager } from '../managers/HealthStateManager';
import { ThemeManager } from '../managers/ThemeManager';
import { HomeCardItem, HomeCardData } from './components/HomeCards';
import { Sleep } from './Sleep';
import { Settings } from './Settings';
import { FocusMode } from './FocusMode';
import { GlassCard } from '../components/GlassCard';
import { AmbientLight } from '../components/AmbientLight';
import {
  HdsNavigation,
  HdsTabs,
  HdsTabsController
} from '@kit.UIDesignKit';
import { curves, SymbolGlyphModifier } from '@kit.ArkUI';
import { WeeklyTrendInfo, UnlockInsights, WEEKDAY_LABELS, formatHourMinute, DowntimeRule } from '../models/HealthTypes';
import { showToastSafe } from '../models/UiUtils';
import { FocusModeManager, FocusStats } from '../managers/FocusModeManager';
import { AchievementManager } from '../managers/AchievementManager';
import { DailyGoalManager } from '../managers/DailyGoalManager';
import { OngoingReminderScheduler, ActiveAlert } from '../managers/OngoingReminderScheduler';
import { PreferenceManager } from '../managers/PreferenceManager';
import { UsageStatsManager } from '../managers/UsageStatsManager';
import { AppLaunchGate, PRIVACY_CONSENT_KEY } from '../managers/AppLaunchGate';
import { PrivacyConsentDialog } from '../components/PrivacyConsentDialog';
import { greetingWithNickname } from '../models/Personalization';
import {
  IOS26_WHITE,
  IOS26_DARK_FILL,
  ThemeColor
} from '../components/iOS26Theme';

/** 趋势图绘图区高度（vp）：数值文本 + 柱体 */
function createWeeklyTrendInfo(): WeeklyTrendInfo {
  return {
    dailyMinutes: [0, 0, 0, 0, 0, 0, 0],
    averageMinutes: 0,
    maxMinutes: 0,
    totalMinutes: 0,
    trendDirection: 'stable',
    trendDeltaPercent: 0,
    todayRank: 0
  };
}

function createUnlockInsights(): UnlockInsights {
  return {
    todayUnlockCount: 0,
    yesterdayUnlockCount: 0,
    weeklyUnlockCounts: [0, 0, 0, 0, 0, 0, 0],
    peakHour: 0,
    peakHourCount: 0,
    hourlyUnlockCounts: [],
    trendDirection: 'stable',
    trendDeltaPercent: 0
  };
}

function createFocusStats(): FocusStats {
  return {
    totalSessions: 0,
    completedSessions: 0,
    totalMinutes: 0,
    totalPoints: 0,
    currentStreak: 0,
    longestStreak: 0,
    todaySessions: 0,
    todayMinutes: 0,
    weekSessions: 0,
    weekMinutes: 0
  };
}

const TREND_CHART_HEIGHT = 96;
/** 柱体最大高度（vp）：下方留白供柱顶数值、同时给限额参考线留出显示空间 */
const TREND_BAR_MAX_HEIGHT = 62;
/** 趋势图柱体宽度（vp） */
const TREND_BAR_WIDTH = 20;
/** 解锁柱状图的最大柱高（vp）。比使用趋势更重要：解锁是次要指标，不应与主数据争夺视觉权重。 */
const UNLOCK_BAR_MAX_HEIGHT = 48;
const UNLOCK_CHART_HEIGHT = 52;

/**
 * 健康使用手机 - 主页
 * iOS 26 Liquid Glass 流态玻璃风格
 * - HdsNavigation + HdsTabs（HDS 系统组件）
 * - systemMaterialEffect(ADAPTIVE, ADAPTIVE) 沉浸光感
 * - 多彩流态渐变背景 + 玻璃卡片 + interpolatingSpring 弹性动效 */
@Entry
@Component
struct Index {
  @State totalSeconds: number = 0;
  @State isInDowntime: boolean = false;
  /**
   * 免打扰提醒卡的副标题（区分「已生效」与「还剩多久」）。
   *
   * 必须落成 `@State`：其数据源是 `usageManager.getDowntimeRule()`，
   * 在 build 里直接调方法取数，ArkUI 追踪不到 —— 设置页改了时段回首页仍是旧值。
   * （refreshUI 里同名局部变量的注释）
   */
  @State downtimeSubtitleText: string = '';
  @State usageProgress: number = 0;
  @State streakDays: number = 0;
  /**
   * 每日限额的显示文案（如 "3小时" / "45分钟"）。
   *
   * 必须落成 @State：限额存在 manager 里，而 manager 是普通字段、不参与 ArkUI
   * 依赖追踪，StatLimit 体内直接调 getDailyLimitText() 取不到任何状态依赖。
   */
  @State dailyLimitText: string = '';
  /**
   * 每日限额的数值（原始分钟数）（`dailyLimitText` 的数值来源）。
   *
   * `dailyLimitText` 同理必须落成 @State：趋势图的图例文案、比例尺上限与限额参考线
   * 都直接读 manager，而 manager 不参与 ArkUI 依赖追踪，限额改了这些节点不重渲染。
   * 2026-10-18 实机复现：限额 180 → 240 后，首页「限额」瓦片正确显示 4小时（走 @State），
   * 而趋势图图例仍显示「限额 3小时」，4 秒也不刷新。这是「UI 不刷新」家族第 6 例。
   * （前 5 例：ForEach key ×4、@Builder 按值传参 ×2）。
   */
  @State dailyLimitMinutes: number = 0;
  @State weeklyTrendInfo: WeeklyTrendInfo = createWeeklyTrendInfo();

  // Unlock insights stats (unlock counts & peak hour)
  @State unlockInsights: UnlockInsights = createUnlockInsights();
  @State focusStats: FocusStats = createFocusStats();
  @State achievementCount: number = 0;
  @State totalAchievements: number = 0;
  @State goalCompletedCount: number = 0;
  @State goalTotalCount: number = 0;
  @State goalStreak: number = 0;

  // 提醒暂停：当前正在提醒（⏰）的条目，供首页“提醒暂停”卡片展示与操作
  @State activeAlerts: ActiveAlert[] = [];
  private reminderScheduler: OngoingReminderScheduler = OngoingReminderScheduler.getInstance();


  // 入场动画
  @State cardOpacity: number = 0;
  @State cardY: number = 30;

  /** 暗色模式标记 */
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  /**
   * 个性化称呼（设置页「个性化」卡片维护）。
   * 用 @StorageProp 而不是读 prefs：问候语在 build 里渲染，只有 AppStorage 变化
   * 才能触发重渲染（与 isDarkMode / accentColorHex 同一套响应式范式）。
   */
  @StorageProp('userNickname') userNickname: string = '';
  /** 当前强调色十六进制值（由 ThemeManager 读取，按暗色模式取 light/dark 值） */
  /** 用户强调色（跟随设置页「强调色」选择，全应用一致） */
  @StorageLink('accentColorHex') accentColorHex: string = '#0066CC';
  /** Tab 图标缓存对应的强调色 + 深浅色组合；变化时重建缓存 */
  @State tabIconThemeKey: string = '';
  /** 首页卡片布局配置：可见卡片的 id 列表，数组顺序即显示顺序 */
  @State homeCardConfig: string[] = [];
  /**
   * 已读入的首页布局版本号（见 `ThemeManager.getHomeCardLayoutVersion`）。
   *
   * 布局是低频变更项，没必要每秒重读 prefs + JSON.parse；版本号一变就重读，
   * 版本号不变则整段跳过（1s tick 的热路径）。
   */
  private homeCardLayoutVersion: number = -1;
  /**
   * 卡片刷新信号：**只在卡片数据实际变化时**自增，作为 @ObjectLink 之外的兜底重建信号。
   * （原实现每秒自增，使 9 张卡片每秒整体重建一次；见 syncCardData 的注释。）
   */
  @State homeCardTick: number = 0;
  /**
   * 首页卡片数据（@Observed）：卡片组件通过 @ObjectLink 共享这一个对象。
   * 卡片不能直接读 manager：manager 是普通字段、不参与 ArkUI 依赖追踪，
   * 卡片会冻结在首次渲染（实机实测：开机后 5 分钟内仍只取过一次数据）。
   * 改用响应式对象后，每次 refreshUI 写入属性就会触发卡片重渲染。
   */
  @State cardData: HomeCardData = new HomeCardData();

  // HDS Tabs
  @State selectedTab: number = 0;
  /**
   * 每次切到「睡前」Tab 时，作为 Sleep 页的主动刷新信号。
   * HdsTabs 保留已挂载页面，切 Tab 不重建，Sleep 的 onPageShow 也不触发，
   * 靠这个 @Prop 让睡前页立即重拉设置页刚改过的睡眠目标等数据（对应 Sleep.tabActivation）。
   */
  @State sleepTabActivation: number = 0;

  /** 趋势图渲染期记忆化（详见 getBarColor / getTrendScaleMax 的注释） */
  private controller: HdsTabsController = new HdsTabsController();
  private homeScroller: Scroller = new Scroller();
  private tabIconCache: Map<string, SymbolGlyphModifier> = new Map();

  private stateManager: HealthStateManager = HealthStateManager.getInstance();
  private usageManager: UsageStatsManager = this.stateManager.usageManager;
  private refreshTimer: number = -1;
  /** 入场动画定时器句柄（页面消失时清理，避免重复进入时动画叠加） */
  private entranceTimerId: number = -1;

  /**
   * 首次启动的隐私同意弹窗。
   *
   * 《个人信息保护法》要求收集个人信息须取得用户同意。本应用在用户点「同意并继续」之前**不会**启动统计与提醒服务（EntryAbility 按同一状态门控）。
   * 同意状态落盘在 preferences，二次启动不再弹。
   */
  @State needPrivacyConsent: boolean = false;

  aboutToAppear(): void {
    this.initTabIcons();
    // 首页卡片布局：首帧就读取持久化配置，避免首帧无卡片后再补上（1s tick 后才读到）
    this.homeCardConfig = ThemeManager.getInstance().getHomeCardConfig();
    // 记录读取时的布局版本号：此后只有版本号变化（设置页写入 / 重置数据）才重新解析
    this.homeCardLayoutVersion = ThemeManager.getInstance().getHomeCardLayoutVersion();
    this.needPrivacyConsent = PreferenceManager.getInstance().getBoolean(PRIVACY_CONSENT_KEY, false) !== true;

    if (!this.needPrivacyConsent) {
      this.startRefreshLoop();
    }

    this.entranceTimerId = setTimeout(() => {
      this.cardOpacity = 1;
      this.cardY = 0;
      this.entranceTimerId = -1;
    }, 100);
  }

  /** 1s 数据刷新定时器。与入场动画分开，因为隐私弹窗同意前不应开始读取统计数据。 */
  private startRefreshLoop(): void {
    if (this.refreshTimer !== -1) {
      return;
    }
    this.refreshTimer = setInterval(() => {
      this.refreshUI();
    }, 1000);
    this.refreshUI();
  }

  /** 用户同意隐私政策：落盘状态 → 关闭弹窗 → 启动统计与权限申请。 */
  private onPrivacyAgree(): void {
    PreferenceManager.getInstance().setBoolean(PRIVACY_CONSENT_KEY, true);
    this.needPrivacyConsent = false;
    this.startRefreshLoop();
    AppLaunchGate.getInstance().notifyConsented();
  }

  /** 用户不同意：按合规要求退出应用，不进入任何功能。 */
  private onPrivacyDisagree(): void {
    // terminateSelf 挂在 UIAbilityContext 上，不是 UIContext
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      ctx.terminateSelf();
    } catch (err) {
      // 退出失败也不能把用户留在"未同意"的半残界面里：至少把异常记下来便于定位
      hilog.error(0x0000, 'IndexPage', '%{public}s', '退出应用失败: ' + formatError(err));
    }
  }

  aboutToDisappear(): void {
    if (this.refreshTimer !== -1) {
      clearInterval(this.refreshTimer);
      this.refreshTimer = -1;
    }
    if (this.entranceTimerId !== -1) {
      clearTimeout(this.entranceTimerId);
      this.entranceTimerId = -1;
    }
  }

  private refreshUI(): void {
    // 首页数据仅首页可见时需要刷新；切到其他 Tab 时跳过，避免无谓的统计开销
    if (this.selectedTab !== 0) {
      return;
    }

    // 跨日即时清零：秒粒度检测日期变化，今日统计/剩余额度立即归零
    this.stateManager.checkDateRollover();

    // 应用退到后台时暂停统计刷新，回前台后由下一个 tick 自行恢复
    if (!AppLifecycleTracker.getInstance().isForeground()) {
      return;
    }

    // 统计口径：今日使用 = 手机真实亮屏时长（ScreenStateManager 检测亮灭屏）
    // 以下 10 个变量全部加 !== 守卫：getSelfUsageMinutes 返回整分钟，60 次 tick 里
    // 59 次数值并不变；原先无条件写入会让 setter 每秒都被调用。
    // 对象状态（trend/insights/focusStats）本来就有 diff 守卫，此处补齐标量侧，口径一致。
    const selfMinutes: number = this.usageManager.getSelfUsageMinutes();
    const totalSeconds: number = selfMinutes * 60;
    if (this.totalSeconds !== totalSeconds) {
      this.totalSeconds = totalSeconds;
    }

    const isInDowntime: boolean = this.usageManager.isInDowntime();
    if (this.isInDowntime !== isInDowntime) {
      this.isInDowntime = isInDowntime;
    }

    // ⚠️ 免打扰副标题必须落成 @State，不能在 build 里直接写 `Text(this.getDowntimeSubtitleText())`：
    // 该方法读的是 manager 里的时段配置，**不是**组件的状态，ArkUI 追踪不到它；
    // 连 `isInDowntime` 这个布尔没翻转（比方用户在设置页把 22:00–02:00 改成 22:00–07:00，
    // 而当前本就在停用时段内），整张卡就不会重渲染，副标题会一直停在旧区间。
    // 实机复现（2026-10-15）：设置页已显示 22:00 / 07:00，首页仍显示「22:00 – 02:00」。
    // 这是本项目 5 例「UI 不刷新」家族（ForEach key ×2、@Builder 参数 ×2、非响应式取数 ×1）。
    const downtimeSubtitleText = this.getDowntimeSubtitleText();
    if (this.downtimeSubtitleText !== downtimeSubtitleText) {
      this.downtimeSubtitleText = downtimeSubtitleText;
    }

    const usageProgress: number = this.getUsageProgress();
    if (this.usageProgress !== usageProgress) {
      this.usageProgress = usageProgress;
    }

    // 强调色：由 ThemeManager 统一发布到 AppStorage（'accentColorHex'），本页用 @StorageLink 订阅。
    // 这里**不能**回写：@StorageLink 是双向绑定，回写会与发布方互相覆盖。
    // Tab 图标颜色被烤进缓存的 SymbolGlyphModifier（initTabIcons 只在 aboutToAppear 调一次），
    // 强调色或深浅色变化后必须重建缓存，否则 Tab 图标颜色会停在旧值。
    const accentHex: string = ThemeManager.getInstance().getAccentColorHex(this.isDarkMode);
    const tabIconThemeKey: string = accentHex + '_' + this.isDarkMode;
    if (this.tabIconThemeKey !== tabIconThemeKey) {
      this.tabIconThemeKey = tabIconThemeKey;
      this.refreshTabIcons();
    }

    // 首页卡片布局：只在版本号变化时重读（设置页写入 / 重置数据会自增版本号）。
    // 原实现每秒无条件 getHomeCardConfig()：一次 prefs getSync + 一次 JSON.parse + 数组分配，
    // 而布局可能一整天都不改一次。
    const themeManager: ThemeManager = ThemeManager.getInstance();
    const layoutVersion: number = themeManager.getHomeCardLayoutVersion();
    if (this.homeCardLayoutVersion !== layoutVersion) {
      this.homeCardLayoutVersion = layoutVersion;
      const cardConfig: string[] = themeManager.getHomeCardConfig();
      if (!this.isStringArrayEqual(this.homeCardConfig, cardConfig)) {
        this.homeCardConfig = cardConfig;
      }
    }

    // 限额文案同样要落成 @State（StatLimit 体内读取），详见上方注释
    const limitMinutes: number = this.usageManager.getTotalDailyLimitMinutes();
    if (this.dailyLimitMinutes !== limitMinutes) {
      this.dailyLimitMinutes = limitMinutes;
    }
    const dailyLimitText: string = this.formatMinutes(limitMinutes);
    if (this.dailyLimitText !== dailyLimitText) {
      this.dailyLimitText = dailyLimitText;
    }

    const streakDays: number = this.usageManager.getStreakDays();
    if (this.streakDays !== streakDays) {
      this.streakDays = streakDays;
    }

    // 对象状态只在内容变化时赋值，避免每秒触发整卡重渲染
    const trend: WeeklyTrendInfo = this.usageManager.getWeeklyTrendInfo();
    if (!this.isWeeklyTrendEqual(this.weeklyTrendInfo, trend)) {
      this.weeklyTrendInfo = trend;
    }

    const insights: UnlockInsights = this.usageManager.getUnlockInsights();
    if (!this.isUnlockInsightsEqual(this.unlockInsights, insights)) {
      this.unlockInsights = insights;
    }

    const focusStats = FocusModeManager.getInstance().getStats();
    if (!this.isFocusStatsEqual(this.focusStats, focusStats)) {
      this.focusStats = focusStats;
    }

    const achievementManager = AchievementManager.getInstance();
    const achievementCount = achievementManager.getUnlockedAchievementCount();
    if (this.achievementCount !== achievementCount) {
      this.achievementCount = achievementCount;
    }
    const totalAchievements = achievementManager.getTotalAchievementCount();
    if (this.totalAchievements !== totalAchievements) {
      this.totalAchievements = totalAchievements;
    }

    // 每日目标摘要（自动追踪更新，updateGoalProgress 按今日真实统计推导）
    const goalManager = DailyGoalManager.getInstance();
    goalManager.updateGoalProgress();
    const goalCounts = goalManager.getGoalCounts();
    if (this.goalTotalCount !== goalCounts.total) {
      this.goalTotalCount = goalCounts.total;
    }
    if (this.goalCompletedCount !== goalCounts.completed) {
      this.goalCompletedCount = goalCounts.completed;
    }
    const goalStreak = goalManager.getCurrentStreak();
    if (this.goalStreak !== goalStreak) {
      this.goalStreak = goalStreak;
    }

    // 刷新正在提醒（⏰）的条目列表，供“提醒暂停”卡片展示
    const alerts: ActiveAlert[] = this.reminderScheduler.getActiveAlerts();
    if (!this.isActiveAlertsEqual(this.activeAlerts, alerts)) {
      this.activeAlerts = alerts;
    }

    // 把卡片需要的数据写入 @Observed 对象：属性变化会触发卡片重渲染。
    // ⚠️ 只在值真的变化时才赋值 + 推进 tick：@Observed 的 setter 每次赋值都会通知订阅者，
    // 原先每秒无条件写 16 个字段再 tick++，等于 9 张卡片每秒整体重建一次。
    // 这些字段最短的变化粒度是「分钟」，空闲时本就不该产生重渲染。
    if (this.syncCardData()) {
      this.homeCardTick++;
    }
  }

  /** 把当前统计值同步进 @Observed 的 cardData，返回是否有字段真的变化。 */
  private syncCardData(): boolean {
    const data: HomeCardData = this.cardData;
    let changed: boolean = false;
    if (data.totalSeconds !== this.totalSeconds) { data.totalSeconds = this.totalSeconds; changed = true; }
    if (data.streakDays !== this.streakDays) { data.streakDays = this.streakDays; changed = true; }
    if (data.dailyLimitText !== this.dailyLimitText) { data.dailyLimitText = this.dailyLimitText; changed = true; }
    if (data.dailyLimitMinutes !== this.dailyLimitMinutes) { data.dailyLimitMinutes = this.dailyLimitMinutes; changed = true; }
    if (data.isInDowntime !== this.isInDowntime) { data.isInDowntime = this.isInDowntime; changed = true; }
    // 卡片需要区分「功能关了」与「开着但不在时段内」，故把 enabled 也带下去
    const downtimeEnabled: boolean = this.usageManager.getDowntimeRule().enabled;
    if (data.downtimeEnabled !== downtimeEnabled) { data.downtimeEnabled = downtimeEnabled; changed = true; }
    if (data.downtimeSubtitleText !== this.downtimeSubtitleText) { data.downtimeSubtitleText = this.downtimeSubtitleText; changed = true; }
    // 对象字段在 refreshUI 里已做等价比较，引用不同即代表内容真的变了
    if (data.weeklyTrendInfo !== this.weeklyTrendInfo) { data.weeklyTrendInfo = this.weeklyTrendInfo; changed = true; }
    if (data.unlockInsights !== this.unlockInsights) { data.unlockInsights = this.unlockInsights; changed = true; }
    if (data.focusStats !== this.focusStats) { data.focusStats = this.focusStats; changed = true; }
    if (data.achievementCount !== this.achievementCount) { data.achievementCount = this.achievementCount; changed = true; }
    if (data.totalAchievements !== this.totalAchievements) { data.totalAchievements = this.totalAchievements; changed = true; }
    if (data.goalCompletedCount !== this.goalCompletedCount) { data.goalCompletedCount = this.goalCompletedCount; changed = true; }
    if (data.goalTotalCount !== this.goalTotalCount) { data.goalTotalCount = this.goalTotalCount; changed = true; }
    if (data.goalStreak !== this.goalStreak) { data.goalStreak = this.goalStreak; changed = true; }
    if (data.activeAlerts !== this.activeAlerts) { data.activeAlerts = this.activeAlerts; changed = true; }
    if (data.accentColorHex !== this.accentColorHex) { data.accentColorHex = this.accentColorHex; changed = true; }
    return changed;
  }

  // 比较两期周趋势对象是否等价，避免内容变化时触发页面重渲染
  private isWeeklyTrendEqual(a: WeeklyTrendInfo, b: WeeklyTrendInfo): boolean {
    if (a.trendDirection !== b.trendDirection || a.trendDeltaPercent !== b.trendDeltaPercent ||
      a.averageMinutes !== b.averageMinutes || a.maxMinutes !== b.maxMinutes ||
      a.totalMinutes !== b.totalMinutes || a.todayRank !== b.todayRank) {
      return false;
    }
    return this.isNumberArrayEqual(a.dailyMinutes, b.dailyMinutes);
  }

  // 比较两组解锁洞察是否等价（含周分布与小时分布数组）
  private isUnlockInsightsEqual(a: UnlockInsights, b: UnlockInsights): boolean {
    if (a.todayUnlockCount !== b.todayUnlockCount || a.yesterdayUnlockCount !== b.yesterdayUnlockCount ||
      a.peakHour !== b.peakHour || a.peakHourCount !== b.peakHourCount ||
      a.trendDirection !== b.trendDirection || a.trendDeltaPercent !== b.trendDeltaPercent) {
      return false;
    }
    return this.isNumberArrayEqual(a.weeklyUnlockCounts, b.weeklyUnlockCounts) &&
      this.isNumberArrayEqual(a.hourlyUnlockCounts, b.hourlyUnlockCounts);
  }

  private isNumberArrayEqual(a: number[], b: number[]): boolean {
    if (a.length !== b.length) {
      return false;
    }
    for (let i = 0; i < a.length; i++) {
      if (a[i] !== b[i]) {
        return false;
      }
    }
    return true;
  }

  /**
   * 字符串数组比较（首页卡片 id 顺序）。
   * 原实现用 `JSON.stringify` 两次再比对字符串：每秒都会分配两个字符串并全量拷贝内容，
   * 而这里只关心「长度 + 逐项相等」。
   */
  private isStringArrayEqual(a: string[], b: string[]): boolean {
    if (a.length !== b.length) {
      return false;
    }
    for (let i = 0; i < a.length; i++) {
      if (a[i] !== b[i]) {
        return false;
      }
    }
    return true;
  }

  /** 提醒列表比较：项数、顺序，以及 id/标题/内容任一变化都需要重建卡片 */
  private isActiveAlertsEqual(a: ActiveAlert[], b: ActiveAlert[]): boolean {
    if (a.length !== b.length) {
      return false;
    }
    for (let i = 0; i < a.length; i++) {
      if (a[i].id !== b[i].id || a[i].title !== b[i].title || a[i].content !== b[i].content) {
        return false;
      }
    }
    return true;
  }

  private isFocusStatsEqual(a: FocusStats, b: FocusStats): boolean {
    return a.totalSessions === b.totalSessions &&
      a.completedSessions === b.completedSessions &&
      a.totalMinutes === b.totalMinutes &&
      a.totalPoints === b.totalPoints &&
      a.currentStreak === b.currentStreak &&
      a.longestStreak === b.longestStreak &&
      a.todaySessions === b.todaySessions &&
      a.todayMinutes === b.todayMinutes &&
      a.weekSessions === b.weekSessions &&
      a.weekMinutes === b.weekMinutes;
  }


  private getDowntimeTimeRange(): string {
    const downtime: DowntimeRule = this.usageManager.getDowntimeRule();
    // 起止相同 = 全天免打扰（见 UsageStatsManager.isInDowntime 的语义注释）。
    // 此处若照原样拼接会显示成「02:00 – 22:00」，用户会以为程序坏了。
    if (downtime.startHour === downtime.endHour && downtime.startMinute === downtime.endMinute) {
      return '全天';
    }
    const start = formatHourMinute(downtime.startHour, downtime.startMinute);
    const end = formatHourMinute(downtime.endHour, downtime.endMinute);
    return `${start} — ${end}`;
  }

  /**
   * 停用时间卡副标题：把"区间"与"还剩多久生效/多久后开始"合成一句。
   * 此前只有裸区间，配合右侧"停用中/未开始"两字，用户仍需自己心算距生效还有多久。
   * 这里直接给出结论，避免用户为了确认一件事去做减法。
   */
  private getDowntimeSubtitleText(): string {
    const range: string = this.getDowntimeTimeRange();
    if (!this.isInDowntime) {
      return range;
    }
    const remaining: number = this.getMinutesUntilDowntimeEnd();
    if (remaining <= 0) {
      return range;
    }
    return `${range} · 还剩 ${this.formatMinutes(remaining)}`;
  }

  /** 停用时段距离结束的剩余分钟数；非停用状态或数据不可用时返回 0 */
  private getMinutesUntilDowntimeEnd(): number {
    const rule: DowntimeRule = this.usageManager.getDowntimeRule();
    const now = new Date();
    const current = now.getHours() * 60 + now.getMinutes();
    const end = rule.endHour * 60 + rule.endMinute;
    // 起止相同 = 全天免打扰（见 UsageStatsManager.isInDowntime）：
    // 既没有"结束时刻"，也算不出「还剩 X 小时」——那会让全天设置看起来像会提前结束。
    // 返回 0 使副标题显示「全天」。
    if (rule.startHour * 60 + rule.startMinute === end) {
      return 0;
    }
    if (rule.startHour * 60 + rule.startMinute <= rule.endHour * 60 + rule.endMinute) {
      // 非跨午夜时段
      return Math.max(0, end - current);
    }
    // 跨午夜：此刻处于 [start, 24:00) 或 [0, end)
    if (current >= rule.startHour * 60 + rule.startMinute) {
      return Math.max(0, 1440 - current + end);
    }
    return Math.max(0, end - current);
  }

  private formatMinutes(minutes: number): string {
    const hours = Math.floor(minutes / 60);
    const mins = minutes % 60;
    return hours > 0 ? hours + '小时' + (mins > 0 ? mins + '分' : '') : mins + '分钟';
  }



  private getUsageColor(): string {
    // 同上：走 @State 才能在限额变化时重渲染（颜色随档位跨档而变）
    const limitSec = this.dailyLimitMinutes * 60;
    if (limitSec <= 0) {
      return ThemeColor.accentColor(this.accentColorHex, this.isDarkMode);
    }
    const ratio = this.totalSeconds / limitSec;
    if (ratio >= 1) {
      return ThemeColor.accentRed(this.isDarkMode);
    } else if (ratio >= 0.75) {
      return ThemeColor.accentOrange(this.isDarkMode);
    }
    return ThemeColor.accentGreen(this.isDarkMode);
  }

  private getUsageProgress(): number {
    const limitSec = this.dailyLimitMinutes * 60;
    if (limitSec <= 0) {
      return 0;
    }
    return Math.min(1, this.totalSeconds / limitSec);
  }


  /**
   * 首页头部日期文案（如 "10月22日 周二"）。
   * WEEKDAY_LABELS 为单字（日），必须补"周"前缀，否则与趋势图标签一致时
   * 会出现"10月22日 二"这类缺前缀的短标签。
   */
  private getHeaderDateText(): string {
    const now: Date = new Date();
    const month: number = now.getMonth() + 1;
    const date: number = now.getDate();
    const weekday: string = WEEKDAY_LABELS[now.getDay()];
    return `${month}月${date}日 周${weekday}`;
  }

  /** 按时段问候语，深夜用更安静的措辞；有称呼时拼成「早上好，小萤」 */
  private getGreetingText(): string {
    const hour = new Date().getHours();
    let greeting: string = '晚上好';
    if (hour < 5) {
      greeting = '夜深了';
    } else if (hour < 11) {
      greeting = '早上了';
    } else if (hour < 14) {
      greeting = '中午好';
    } else if (hour < 18) {
      greeting = '下午好';
    }
    // 规范化（去控制字符/截断）在纯函数里做，避免用户输入把单行问候撑成两行
    return greetingWithNickname(greeting, this.userNickname);
  }

  /** 头部右侧的状态摘要（一句话概括当前用量处于风险区间） */
  private getStatusSummaryText(): string {
    if (this.isInDowntime) {
      return '免打扰提醒中';
    }
    const p = this.usageProgress;
    if (p >= 1) {
      return '已超今日限额';
    }
    if (p >= 0.75) {
      return '接近今日限额';
    }
    if (p > 0) {
      return '使用中';
    }
    return '状态良好';
  }

  /** 状态摘要配色，与 getUsageColor 同一套风险色语义 */
  private getStatusSummaryColor(): string {
    if (this.isInDowntime) {
      return ThemeColor.accentIndigo(this.isDarkMode);
    }
    return this.getUsageColor();
  }


  /**
   * 首页卡片导航：卡片组件通过回调把“跳到哪里”的决策交回本页处理。
   * 原内联卡片直接调 controller / router，拆成独立组件后必须由父组件负责实际跳转。
   */
  private handleHomeCardNavigate(target: string): void {
    if (target === 'settings') {
      this.controller.changeIndex(3);
      this.onTabChanged(3);
    } else if (target === 'focus') {
      this.controller.changeIndex(1);
      this.onTabChanged(1);
    } else if (target === 'goal') {
      this.pushPage('pages/GoalPage');
    } else if (target === 'insights') {
      this.pushPage('pages/InsightsPage');
    } else if (target === 'achievement') {
      this.pushPage('pages/AchievementPage');
    }
  }

  /** 跳转到指定页面（失败只记日志，不影响主界面） */
  private pushPage(url: string): void {
    try {
      this.getUIContext().getRouter().pushUrl({ url: url });
    } catch (err) {
      hilog.error(0x0000, 'IndexPage', '%{public}s', '跳转页面失败: ' + formatError(err));
    }
  }

  private onTabChanged(index: number): void {
    // 埋点：用于查看 `HdsTabs` 的 `.onChange` 在**用户点击底栏**时是否真的触发。
    // 2026-10-15 曾据「`active` 始终为 false」推断不触发，但那次抓日志前先执行了
    // `hilog -r` 清缓冲，把应用自己的日志一起冲掉了（第二次踩在这里的工具坑），
    // 该结论**尚未证实**，需重新取证。切勿据此改代码。
    hilog.info(0x0000, 'IndexPage', '%{public}s', 'onTabChanged index=' + index);
    this.selectedTab = index;
    if (index === 0) {
      this.refreshUI();
    } else if (index === 2) {
      // 切到睡前 Tab：推一次刷新信号，立即反映设置页刚改的睡眠目标/睡前窗口
      this.sleepTabActivation++;
    }
  }

  /**
   * 重建 Tab 图标缓存。
   * initTabIcons 把颜色烤进 SymbolGlyphModifier（不可变对象），
   * 强调色或深浅色变化后必须重建，否则 Tab 图标颜色会停在旧值。
   */
  private refreshTabIcons(): void {
    this.tabIconCache.clear();
    this.initTabIcons();
  }

  private initTabIcons(): void {
    const names: string[] = ['star', 'timer', 'moon_fill', 'gearshape'];
    const secondaryColor = ThemeColor.labelSecondary(this.isDarkMode);
    names.forEach((name: string) => {
      this.tabIconCache.set(name + '_normal',
        new SymbolGlyphModifier($r('sys.symbol.' + name))
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          .fontColor([secondaryColor]));
      this.tabIconCache.set(name + '_selected',
        new SymbolGlyphModifier($r('sys.symbol.' + name))
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          .fontColor([ThemeColor.accentColor(this.accentColorHex, this.isDarkMode)]));
    });
  }

  private getTabIcon(name: string, selected: boolean): SymbolGlyphModifier {
    const key = name + (selected ? '_selected' : '_normal');
    const cached: SymbolGlyphModifier | undefined = this.tabIconCache.get(key);
    if (cached) {
      return cached;
    }
    return new SymbolGlyphModifier($r('sys.symbol.' + name))
      .renderingStrategy(SymbolRenderingStrategy.SINGLE)
      .fontColor([selected ? ThemeColor.accentColor(this.accentColorHex, this.isDarkMode) : ThemeColor.labelSecondary(this.isDarkMode)]);
  }

  // ========= 首页 Tab 内容 =========
  /**
   * 底部摘要三块统计瓦片。
   *
   * 刻意拆成三个无参 @Builder，而不是原先那个 `SummaryItem(label, value, color)`：
   * ArkUI **不追踪 @Builder 参数里的状态依赖**，`Text(value)` 渲染的是调用处算好并
   * 按值传入的字符串，于是三块瓦片只在首次渲染时取值、此后永不刷新。
   * 2026-10-07 实机证据：限额持久化为 120 分钟时，三块瓦片在冷启动后 t+2s～t+25s
   * 一直显示"3小时 / 0% / 1 天"（而 120 分钟对应的是 80%，0% 均为 manager 的**默认值**——首次渲染
   * 发生在异步 prefs 载入之前），而同一张卡片右上角的环形百分比正确显示 100%。
   * 改成无参版本后，各自的**体内**读取 @State（dailyLimitText / usageProgress /
   * streakDays），依赖正常登记，数值随 1s tick 一起刷新。 */


  @Builder
  HomeTabContent() {
    Stack() {
      Scroll(this.homeScroller) {
        Column({ space: 16 }) {
          // 顶部问候区：把"今天 + 当前状态"提到卡片之前，建立首页信息层级
          // （此前首屏直接是"今日屏幕使用"卡，缺少时间与状态的落点）
          Row() {
            Column({ space: 4 }) {
              Text(this.getGreetingText())
                // 带称呼时略降字号：给「早上好，小萤」留出与状态徽标并排的空间
                .fontSize(this.userNickname.length > 0 ? 26 : 28)
                .fontWeight(FontWeight.Bold)
                .fontColor(ThemeColor.label(this.isDarkMode))
                // 称呼较长时允许折到第二行，而不是把右侧状态徽标挤出屏幕
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.getHeaderDateText())
                .fontSize(12)
                .fontColor(ThemeColor.labelSecondary(this.isDarkMode))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            // 状态徽标：与风险色语义联动，一眼看出当前是否需要干预
            Row({ space: 6 }) {
              Column()
                .width(6).height(6).borderRadius(3)
                .backgroundColor(this.getStatusSummaryColor())
              Text(this.getStatusSummaryText())
                .fontSize(12)
                .fontColor(this.getStatusSummaryColor())
                .fontWeight(FontWeight.Medium)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .padding({ left: 12, right: 14, top: 8, bottom: 8 })
            .backgroundColor(ThemeColor.withAlpha(this.getStatusSummaryColor(), '14'))
            .borderRadius(16)
            // 无障碍：徽标只有展示的状态色与文字，加个前缀让读屏明确这是"当前状态"
            .accessibilityLevel('yes')
            .accessibilityText('当前状态：' + this.getStatusSummaryText())
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .opacity(this.cardOpacity)
          .translate({ y: this.cardY })
          // 首页卡片：按 homeCardConfig 的顺序与显隐渲染，每张卡片独立 @Component
          ForEach(this.homeCardConfig, (cardId: string, index: number) => {
            HomeCardItem({
              cardId: cardId,
              delay: index * 100,
              cardOpacity: this.cardOpacity,
              cardTranslateY: this.cardY,
              cardData: this.cardData,
              tick: this.homeCardTick,
              onNavigate: (target: string) => { this.handleHomeCardNavigate(target); }
            })
          }, (cardId: string, index: number) => cardId + '_' + index)
          Column().height(120)
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 12, bottom: 16 })
      }
      .width('100%').layoutWeight(1).backgroundColor('transparent')
      .scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
      // 这里 extendSafeArea 不加在这 —— TabContent 内的 Scroll 会被 HdsNavigation 裁在
      // y=137，加了无效（实机 dump 验证）。生效点在 build() 的根 Stack 上。
    }
    .width('100%').height('100%')
  }


  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column().width('100%').height('100%')
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .linearGradient({
          direction: GradientDirection.Bottom,
          colors: ThemeColor.gradient(this.isDarkMode)
        })

      AmbientLight()

      HdsNavigation() {
        HdsTabs({ controller: this.controller }) {
          TabContent() {
            this.HomeTabContent()
          }
          .tabBar(new BottomTabBarStyle({
            normal: this.getTabIcon('star', false),
            selected: this.getTabIcon('star', true)
          }, '首页'))
          TabContent() {
            FocusMode()
          }
          .tabBar(new BottomTabBarStyle({
            normal: this.getTabIcon('timer', false),
            selected: this.getTabIcon('timer', true)
          }, '专注'))
          TabContent() {
            Sleep({ tabActivation: this.sleepTabActivation })
          }
          .tabBar(new BottomTabBarStyle({
            normal: this.getTabIcon('moon_fill', false),
            selected: this.getTabIcon('moon_fill', true)
          }, '睡前'))
          TabContent() {
            Settings()
          }
          .tabBar(new BottomTabBarStyle({
            normal: this.getTabIcon('gearshape', false),
            selected: this.getTabIcon('gearshape', true)
          }, '设置'))
        }
        .width('100%').height('100%').backgroundColor('transparent')
        .barBackgroundColor(this.isDarkMode ? IOS26_DARK_FILL : IOS26_WHITE)
        .barBackgroundBlurStyle(BlurStyle.NONE)
        .barOverlap(false).vertical(false).barPosition(BarPosition.End)
        .animationDuration(320)
        .onChange((index: number) => {
          this.onTabChanged(index);
        })
      }
      .width('100%').height('100%').backgroundColor('transparent')
      .mode(NavigationMode.Stack).hideBackButton(true).hideToolBar(true)
      .hideTitleBar(true)
      .systemBarStyle(
        { statusBarContentColor: ThemeColor.statusBarContent(this.isDarkMode) },
        { statusBarContentColor: ThemeColor.statusBarContent(this.isDarkMode) }
      )
      if (this.needPrivacyConsent) {
        PrivacyConsentDialog({
          onAgree: () => { this.onPrivacyAgree(); },
          onDisagree: () => { this.onPrivacyDisagree(); }
        })
      }
    }
    .width('100%').height('100%')
    .backgroundColor('transparent')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
  }
}

