/**
 * 首页卡片组件集合：每张卡片独立为一个 @Component，供 HomeCardItem 按 id 调用。
 * 卡片**只读 @Observed 的 HomeCardData**（Index 的 1s tick 负责写入），
 * 不再各自持有 Manager 单例 —— 普通字段不参与 ArkUI 依赖追踪，直接读会冻结在首次渲染。
 * 卡片自身只需声明 @StorageProp('isDarkMode') 跟随深浅色。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { curves } from '@kit.ArkUI';
import { GlassCard } from '../../components/GlassCard';
import {
  IOS26_WHITE,
  ThemeColor
} from '../../components/iOS26Theme';
import { WEEKDAY_LABELS, WeeklyTrendInfo, UnlockInsights, formatHourMinute } from '../../models/HealthTypes';
import { showToastSafe } from '../../models/UiUtils';
import { ThemeManager } from '../../managers/ThemeManager';
import { FocusStats } from '../../managers/FocusModeManager';
import { OngoingReminderScheduler, ActiveAlert } from '../../managers/OngoingReminderScheduler';

const HOME_CARD_CHART_HEIGHT = 96;
const HOME_CARD_BAR_MAX_HEIGHT = 62;
const HOME_CARD_BAR_WIDTH = 20;
const HOME_CARD_UNLOCK_BAR_MAX_HEIGHT = 48;
const HOME_CARD_UNLOCK_CHART_HEIGHT = 52;

/**
 * 首页卡片数据集：卡片组件通过 @ObjectLink 共享这一份数据。
 *
 * 为什么不能让卡片直接读 manager：
 * manager 是普通字段，不参与 ArkUI 依赖追踪，
 * 卡片会「冻结在首次渲染那一刻」——实机实测：
 * Index 每秒自增 tick，卡片仍然只在启动时取过一次数据（hilog 仅 2 条记录），
 * 后续再不重新渲染。改用 @Observed + @ObjectLink 后，Index 改属性时才会真正触发卡片重渲染。
 */
@Observed
export class HomeCardData {
  /** 今日使用秒数（整分钟对齐，与原内联总量口径一致） */
  totalSeconds: number = 0;
  /** 连续达标天数 */
  streakDays: number = 0;
  /** 每日限额文案（如「3小时」） */
  dailyLimitText: string = '';
  /** 每日限额（分钟） */
  dailyLimitMinutes: number = 0;
  /** 是否处于免打扰时段 */
  isInDowntime: boolean = false;
  /** 免打扰功能是否已启用（区分"关了"与"开着但不在时段内"） */
  downtimeEnabled: boolean = false;
  /** 免打扰副标题（含剩余时长） */
  downtimeSubtitleText: string = '';
  /** 近 7 天使用趋势 */
  weeklyTrendInfo: WeeklyTrendInfo = {
    dailyMinutes: [0, 0, 0, 0, 0, 0, 0],
    averageMinutes: 0,
    maxMinutes: 0,
    totalMinutes: 0,
    trendDirection: 'stable',
    trendDeltaPercent: 0,
    todayRank: 0
  };
  /** 解锁洞察 */
  unlockInsights: UnlockInsights = {
    todayUnlockCount: 0,
    yesterdayUnlockCount: 0,
    weeklyUnlockCounts: [0, 0, 0, 0, 0, 0, 0],
    peakHour: 0,
    peakHourCount: 0,
    hourlyUnlockCounts: [],
    trendDirection: 'stable',
    trendDeltaPercent: 0
  };
  /** 专注统计 */
  focusStats: FocusStats = {
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
  /** 已解锁成就数 */
  achievementCount: number = 0;
  /** 成就总数 */
  totalAchievements: number = 0;
  /** 今日完成目标数 */
  goalCompletedCount: number = 0;
  /** 目标总数 */
  goalTotalCount: number = 0;
  /** 连续打卡天数 */
  goalStreak: number = 0;
  /** 正在提醒（⏰）的条目 */
  activeAlerts: ActiveAlert[] = [];
  /** 当前强调色（含 # 的十六进制） */
  accentColorHex: string = '';
}

const TAG = 'HomeCards';

/** ==================== 1. 今日屏幕使用卡片 ==================== */
@Component
export struct HomeUsageCard {
  @Prop delay: number = 0;
  @Prop cardOpacity: number = 0;
  @Prop cardTranslateY: number = 0;
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  /** 刷新信号：父组件只在卡片数据**实际变化**时自增（@ObjectLink 之外的兜底重建信号） */
  @Prop tick: number = 0;
  /** 卡片数据（响应式）：由父组件通过 @ObjectLink 共享 */
  @ObjectLink cardData: HomeCardData;
  /** 当前强调色（用户可在设置页切换）：直接读 ThemeManager，配合 tick 刷新保证不会滞留旧值 */
  private getAccentHex(): string {
    // 读 cardData（Index 的 tick 在数据变化时才写入）而不是直接问 manager：
    // manager 是普通字段、不参与 ArkUI 依赖追踪，直接读会把颜色冻结在首次渲染那一刻
    const hex: string = this.cardData.accentColorHex;
    return hex.length > 0 ? hex : ThemeManager.getInstance().getAccentColorHex(this.isDarkMode);
  }

  build() {
    GlassCard({ delay: this.delay, cardOpacity: this.cardOpacity, cardTranslateY: this.cardTranslateY }) {
      Column({ space: 16 }) {
        Row() {
          Column({ space: 2 }) {
            Text('今日屏幕使用').fontSize(17).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
            Text(this.getStreakText()).fontSize(11).fontColor(ThemeColor.labelSecondary(this.isDarkMode))
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)

          Text(this.getPercentText())
            .fontSize(12).fontWeight(FontWeight.Medium).fontColor(this.getUsageColor())
            .padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .backgroundColor(ThemeColor.withAlpha(this.getUsageColor(), '14'))
            .borderRadius(14)
        }.width('100%')

        Column({ space: 16 }) {
          Column({ space: 4 }) {
            Row({ space: 6 }) {
              if (this.getTotalUsageHoursText() !== '0') {
                Text(this.getTotalUsageHoursText())
                  .fontSize(48).fontWeight(FontWeight.Bold).fontColor(ThemeColor.label(this.isDarkMode))
                  .animation({ duration: 300, curve: Curve.EaseOut })
                Text('小时')
                  .fontSize(22).fontWeight(FontWeight.Medium).fontColor(ThemeColor.labelSecondary(this.isDarkMode))
                  .margin({ bottom: 8 })
              }
              if (this.getTotalUsageRemainderText().length > 0) {
                Text(this.getTotalUsageRemainderText())
                  .fontSize(this.getTotalUsageHoursText() !== '0' ? 18 : 44)
                  .fontWeight(this.getTotalUsageHoursText() !== '0' ? FontWeight.Normal : FontWeight.Bold)
                  .fontColor(ThemeColor.label(this.isDarkMode))
                  .animation({ duration: 300, curve: Curve.EaseOut })
                  .margin({ bottom: this.getTotalUsageHoursText() !== '0' ? 10 : 0 })
              }
            }
            .alignItems(VerticalAlign.Bottom)

            Text('今日使用').fontSize(13).fontColor(ThemeColor.labelSecondary(this.isDarkMode))
          }.width('100%').alignItems(HorizontalAlign.Center)

          Stack({ alignContent: Alignment.Start }) {
            Row().width('100%').height(10).borderRadius(5).backgroundColor(ThemeColor.fill(this.isDarkMode))
            Row().width((this.getUsageProgress() * 100) + '%').height(10).borderRadius(5)
              .backgroundColor(this.getUsageColor())
          }.width('100%').height(10)
        }
        .width('100%')

        Row() {
          this.StatLimit()
          Divider().vertical(true).height(28).color(ThemeColor.separator(this.isDarkMode))
          this.StatUsed()
          Divider().vertical(true).height(28).color(ThemeColor.separator(this.isDarkMode))
          this.StatStreak()
        }
        .width('100%').alignItems(VerticalAlign.Center)
      }
    }
  }

  private getPercentText(): string {
    return Math.round(this.getUsageProgress() * 100) + '%';
  }
  /** 今日使用秒数（整分钟对齐）：与 Index.refreshUI 的 totalSeconds 同口径，避免“已用百分比”与进度条在秒与整分钟两种口径下不一致 */
  private getTotalSeconds(): number {
    return Math.floor(this.cardData.totalSeconds / 60) * 60;
  }
  private getUsageColor(): string {
    const limitSec: number = this.cardData.dailyLimitMinutes * 60;
    if (limitSec <= 0) { return ThemeColor.accentColor(this.cardData.accentColorHex, this.isDarkMode); }
    const ratio: number = this.cardData.totalSeconds / limitSec;
    if (ratio >= 1) { return ThemeColor.accentRed(this.isDarkMode); }
    if (ratio >= 0.75) { return ThemeColor.accentOrange(this.isDarkMode); }
    return ThemeColor.accentGreen(this.isDarkMode);
  }
  private getTotalUsageHoursText(): string {
    return Math.floor(this.getTotalSeconds() / 60 / 60).toString();
  }
  private getTotalUsageRemainderText(): string {
    const minutes: number = Math.floor(this.getTotalSeconds() / 60);
    const hours: number = Math.floor(minutes / 60);
    const rest: number = minutes % 60;
    if (hours <= 0) { return rest + '分钟'; }
    return rest > 0 ? rest + '分' : '';
  }
  private getUsageProgress(): number {
    // 与 getUsageColor / 其余卡片一致：读 cardData（Index 每秒 tick 写入的响应式数据），
    // 别再直接问 manager —— manager 是普通字段，不参与 ArkUI 依赖追踪。
    const limitSec: number = this.cardData.dailyLimitMinutes * 60
    if (limitSec <= 0) { return 0 }
    return Math.min(1, this.getTotalSeconds() / limitSec)
  }
  private getStreakText(): string {
    const streak: number = this.cardData.streakDays;
    if (streak > 0) { return `连续 ${streak} 天达标`; }
    // streakDays 为 0 有两种成因，不能共用一句话：① 今日已超限（用量超限额）；
    // ② 今日尚未达标。若一律显示“今日开始健康达标”，①会与同屏的“已超今日限额”状态徽标自相矛盾
    const limitMinutes: number = this.cardData.dailyLimitMinutes;
    // 等于限额也算"已超"：与 Index 状态徽标（ratio >= 1）和三档预警同口径
    if (this.getTotalSeconds() >= limitMinutes * 60) { return '今日已超限'; }
    return '今日尚未达标';
  }
  @Builder
  StatLimit() {
    Column({ space: 3 }) {
      Text(this.cardData.dailyLimitText)
        .fontSize(15).fontWeight(FontWeight.Bold).fontColor(ThemeColor.accentColor(this.getAccentHex(), this.isDarkMode))
      Text('限额').fontSize(11).fontColor(ThemeColor.labelSecondary(this.isDarkMode))
    }.layoutWeight(1).alignItems(HorizontalAlign.Center)
  }
  @Builder
  StatUsed() {
    Column({ space: 3 }) {
      Text(Math.round(this.getUsageProgress() * 100) + '%')
        .fontSize(15).fontWeight(FontWeight.Bold).fontColor(this.getUsageColor())
      Text('已用').fontSize(11).fontColor(ThemeColor.labelSecondary(this.isDarkMode))
    }.layoutWeight(1).alignItems(HorizontalAlign.Center)
  }
  @Builder
  StatStreak() {
    Column({ space: 3 }) {
      Text(this.cardData.streakDays > 0 ? this.cardData.streakDays + ' 天' : '未开始')
        .fontSize(15).fontWeight(FontWeight.Bold).fontColor(ThemeColor.accentGreen(this.isDarkMode))
      Text('连续达标').fontSize(11).fontColor(ThemeColor.labelSecondary(this.isDarkMode))
    }.layoutWeight(1).alignItems(HorizontalAlign.Center)
  }
}

/** ==================== 2. 停用时间卡片 ==================== */
@Component
export struct HomeDowntimeCard {
  @Prop delay: number = 0;
  @Prop cardOpacity: number = 0;
  @Prop cardTranslateY: number = 0;
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  /** 刷新信号：父组件只在卡片数据**实际变化**时自增（@ObjectLink 之外的兜底重建信号） */
  @Prop tick: number = 0;
  /** 卡片数据（响应式）：由父组件通过 @ObjectLink 共享 */
  @ObjectLink cardData: HomeCardData;
  /** 导航回调：点击卡片时由父组件执行跳转（依赖 Index 的 controller / router） */
  onNavigate: ((target: string) => void) | undefined = undefined;

  build() {
    GlassCard({ delay: this.delay, cardOpacity: this.cardOpacity, cardTranslateY: this.cardTranslateY,
      accessibilityLabel: '免打扰提醒设置，点击进入设置页',
      onCardClick: () => { this.onNavigate?.('settings'); } }) {
      Row() {
        Column({ space: 4 }) {
          Text('免打扰提醒').fontSize(17).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
          Text(this.getDowntimeSubtitleText())
            .fontSize(13).fontColor(this.isInDowntime() ? ThemeColor.accentIndigo(this.isDarkMode) : ThemeColor.labelSecondary(this.isDarkMode))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)

        Row({ space: 6 }) {
          Column().width(6).height(6).borderRadius(3)
            .backgroundColor(this.getDowntimeStateColor())
          Text(this.getDowntimeStateText())
            .fontSize(12).fontColor(this.getDowntimeStateColor())
        }
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        .backgroundColor(ThemeColor.withAlpha(this.getDowntimeStateColor(), '14'))
        .borderRadius(12).animation({ duration: 300, curve: Curve.EaseOut })
      }.width('100%')
    }
  }

  private isInDowntime(): boolean { return this.cardData.isInDowntime; }
  private getDowntimeSubtitleText(): string {
    return this.cardData.downtimeSubtitleText;
  }
  /**
   * 免打扰状态三态文案。
   * 原实现只有「提醒中 / 未开启」两态：已启用但当前不在时段内也被显示成"未开启"，
   * 与设置页开关为开直接矛盾，用户会反复去重开。
   */
  private getDowntimeStateText(): string {
    if (this.isInDowntime()) {
      return '提醒中';
    }
    return this.cardData.downtimeEnabled ? '待生效' : '未开启';
  }

  private getDowntimeStateColor(): string {
    if (this.isInDowntime()) {
      return ThemeColor.accentRed(this.isDarkMode);
    }
    return this.cardData.downtimeEnabled
      ? ThemeColor.accentIndigo(this.isDarkMode)
      : ThemeColor.accentGreen(this.isDarkMode);
  }
}

/** ==================== 3. 周趋势图卡片 ==================== */
@Component
export struct HomeTrendCard {
  @Prop delay: number = 0;
  @Prop cardOpacity: number = 0;
  @Prop cardTranslateY: number = 0;
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  /** 刷新信号：父组件只在卡片数据**实际变化**时自增（@ObjectLink 之外的兜底重建信号） */
  @Prop tick: number = 0;
  /** 卡片数据（响应式）：由父组件通过 @ObjectLink 共享 */
  @ObjectLink cardData: HomeCardData;

  /** 柱体颜色 memo：一次渲染里 getBarColor 被调 28 次（7 柱 × 4），用 Map 去重 */
  private barColorCache: Map<number, string> = new Map();
  private barColorCacheLimit: number = -1;
  private barColorCacheDark: boolean | null = null;
  /** 比例尺 memo：同一次渲染里 getBarHeight × 7 + getLimitLineOffset × 3 共 10 次调用 */
  private trendScaleCacheArray: number[] | null = null;
  private trendScaleCacheLimit: number = -1;
  private trendScaleCacheValue: number = 60;

  build() {
    GlassCard({ delay: this.delay, cardOpacity: this.cardOpacity, cardTranslateY: this.cardTranslateY }) {
      Column({ space: 16 }) {
        Row() {
          Text('近7天使用趋势').fontSize(17).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
          Blank()
          Column({ space: 3 }) {
            Text('日均 ' + this.cardData.weeklyTrendInfo.averageMinutes + '分钟')
              .fontSize(12).fontColor(ThemeColor.labelSecondary(this.isDarkMode))
            if (this.getLimitLineOffset() >= 0) {
              Row({ space: 5 }) {
                Column().width(10).height(1).backgroundColor(this.getLimitLineColor())
                Text('限额 ' + this.cardData.dailyLimitText)
                  .fontSize(11).fontColor(ThemeColor.labelSecondary(this.isDarkMode))
              }.alignItems(VerticalAlign.Center)
            }
            Text(this.getTrendText()).fontSize(11).fontColor(this.getTrendColor()).fontWeight(FontWeight.Medium)
          }.alignItems(HorizontalAlign.End)
        }.width('100%')

        Stack({ alignContent: Alignment.Bottom }) {
          Row() {
            ForEach(this.cardData.weeklyTrendInfo.dailyMinutes, (minutes: number, index: number) => {
              Column({ space: 6 }) {
                // 柱顶数值：0 也照常显示（否则无数据的日子与有数据的日子无法区分）
                Text('' + minutes)
                  .fontSize(index === 6 ? 11 : 10)
                  .fontWeight(index === 6 ? FontWeight.Bold : FontWeight.Normal)
                  .fontColor(minutes <= 0
                    ? ThemeColor.systemGray(this.isDarkMode)
                    : (index === 6 ? this.getBarColor(minutes) : ThemeColor.labelSecondary(this.isDarkMode)))
                Column()
                  .width(HOME_CARD_BAR_WIDTH)
                  .height(this.getBarHeight(minutes))
                  .borderRadius(6)
                  .linearGradient({
                    direction: GradientDirection.Bottom,
                    colors: minutes <= 0
                      ? [[ThemeColor.fill(this.isDarkMode), 1], [ThemeColor.fill(this.isDarkMode), 1]]
                      : [[this.getBarColor(minutes), 1], [ThemeColor.withAlpha(this.getBarColor(minutes), '66'), 1]]
                  })
                  .border({ width: 0.5, color: ThemeColor.withAlpha(this.getBarColor(minutes), '66'), radius: 6 })
                  .shadow({ radius: 4, color: ThemeColor.withAlpha(this.getBarColor(minutes), '22'), offsetX: 0, offsetY: 1 })
                  .animation({ duration: 700, delay: 200 + index * 80, curve: curves.interpolatingSpring(0, 1, 170, 14) })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Center)
              .justifyContent(FlexAlign.End)
            }, (minutes: number, index: number) => 'trend_' + index + '_' + minutes)
          }
          .width('100%').height(HOME_CARD_CHART_HEIGHT).alignItems(VerticalAlign.Bottom)

          if (this.getLimitLineOffset() >= 0) {
            Column().width('100%').height(1).backgroundColor(this.getLimitLineColor()).margin({ bottom: this.getLimitLineOffset() })
          }
        }
        .width('100%').height(HOME_CARD_CHART_HEIGHT)
        .accessibilityLevel('yes')
        .accessibilityText(this.getTrendChartAccessibilityText())

        Row() {
          ForEach(this.cardData.weeklyTrendInfo.dailyMinutes, (_m: number, index: number) => {
            Text(this.getWeekDayLabel(index))
              .fontSize(11).fontColor(index === 6 ? ThemeColor.accentGreen(this.isDarkMode) : ThemeColor.labelSecondary(this.isDarkMode))
              .fontWeight(index === 6 ? FontWeight.Medium : FontWeight.Normal)
              .textAlign(TextAlign.Center).layoutWeight(1)
          }, (_m: number, index: number) => 'trend_label_' + index)
        }
      }
      .width('100%')
    }
  }

  private getUsageColor(): string {
    const limitSec: number = this.cardData.dailyLimitMinutes * 60;
    if (limitSec <= 0) { return ThemeColor.accentColor(this.cardData.accentColorHex, this.isDarkMode); }
    const ratio: number = this.cardData.totalSeconds / limitSec;
    if (ratio >= 1) { return ThemeColor.accentRed(this.isDarkMode); }
    if (ratio >= 0.75) { return ThemeColor.accentOrange(this.isDarkMode); }
    return ThemeColor.accentGreen(this.isDarkMode);
  }
  private getLimitLineColor(): string { return ThemeColor.withAlpha(this.getUsageColor(), '66') }
  private getLimitLineOffset(): number {
    const limitMinutes: number = this.cardData.dailyLimitMinutes
    if (limitMinutes <= 0) { return -1 }
    return this.getBarHeight(limitMinutes)
  }
  private getBarHeight(minutes: number): number {
    const scale: number = this.getTrendScaleMax()
    return Math.max(4, Math.min(HOME_CARD_BAR_MAX_HEIGHT, (minutes / scale) * HOME_CARD_BAR_MAX_HEIGHT))
  }
  private getTrendScaleMax(): number {
    const limitMinutes: number = this.cardData.dailyLimitMinutes;
    const arr: number[] = this.cardData.weeklyTrendInfo.dailyMinutes;
    // 记忆化：同一次渲染里被调 10 次，每次都要遍历 7 元素数组
    if (this.trendScaleCacheArray === arr && this.trendScaleCacheLimit === limitMinutes) {
      return this.trendScaleCacheValue;
    }
    let maxMinutes: number = 60;
    for (let i = 0; i < arr.length; i++) {
      if (arr[i] > maxMinutes) {
        maxMinutes = arr[i];
      }
    }
    const value: number = Math.max(maxMinutes, limitMinutes);
    this.trendScaleCacheArray = arr;
    this.trendScaleCacheLimit = limitMinutes;
    this.trendScaleCacheValue = value;
    return value;
  }
  private getBarColor(minutes: number): string {
    const limitMinutes: number = this.cardData.dailyLimitMinutes;
    // 限额或暗色模式一变即整表失效
    if (this.barColorCacheLimit !== limitMinutes || this.barColorCacheDark !== this.isDarkMode) {
      this.barColorCache.clear();
      this.barColorCacheLimit = limitMinutes;
      this.barColorCacheDark = this.isDarkMode;
    }
    const cached: string | undefined = this.barColorCache.get(minutes);
    if (cached !== undefined) { return cached; }
    let color: string;
    if (minutes >= limitMinutes) {
      color = ThemeColor.accentRed(this.isDarkMode);
    } else if (minutes >= limitMinutes * 0.75) {
      color = ThemeColor.accentOrange(this.isDarkMode);
    } else {
      color = ThemeColor.accentGreen(this.isDarkMode);
    }
    this.barColorCache.set(minutes, color);
    return color;
  }
  private getTrendColor(): string {
    const info: WeeklyTrendInfo = this.cardData.weeklyTrendInfo;
    if (info.trendDirection === 'up') {
      return ThemeColor.accentRed(this.isDarkMode);
    } else if (info.trendDirection === 'down') {
      return ThemeColor.accentGreen(this.isDarkMode);
    }
    return ThemeColor.systemGray(this.isDarkMode);
  }
  private getTrendText(): string {
    const info: WeeklyTrendInfo = this.cardData.weeklyTrendInfo
    if (info.trendDirection === 'up') { return `较上周上升${info.trendDeltaPercent}%` }
    if (info.trendDirection === 'down') { return `较上周下降${Math.abs(info.trendDeltaPercent)}%` }
    return '使用习惯稳定'
  }
  private getTrendChartAccessibilityText(): string {
    const parts: string[] = []
    for (let i = 0; i < this.cardData.weeklyTrendInfo.dailyMinutes.length; i++) {
      parts.push(this.getWeekDayLabel(i) + ' ' + this.cardData.weeklyTrendInfo.dailyMinutes[i] + '分钟')
    }
    return '已使用 ' + this.cardData.dailyLimitText + '，日均 ' + this.cardData.weeklyTrendInfo.averageMinutes +
      '分钟，' + this.getTrendText() + '，' + parts.join('、');
  }
  /** 趋势图标签：统一加“周”前缀；且从最旧的那天开始算起（近 7 天） */
  private getWeekDayLabel(index: number): string {
    const today: number = new Date().getDay();
    const dayIndex: number = (today - 6 + index + 7) % 7;
    return '周' + WEEKDAY_LABELS[dayIndex];
  }
}

/** ==================== 4. 解锁洞察卡片 ==================== */
@Component
export struct HomeUnlockCard {
  @Prop delay: number = 0;
  @Prop cardOpacity: number = 0;
  @Prop cardTranslateY: number = 0;
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  /** 刷新信号：父组件只在卡片数据**实际变化**时自增（@ObjectLink 之外的兜底重建信号） */
  @Prop tick: number = 0;
  /** 卡片数据（响应式）：由父组件通过 @ObjectLink 共享 */
  @ObjectLink cardData: HomeCardData;
  build() {
    GlassCard({ delay: this.delay, cardOpacity: this.cardOpacity, cardTranslateY: this.cardTranslateY }) {
      Column({ space: 12 }) {
        Row() {
          Column({ space: 4 }) {
            Text('解锁洞察').fontSize(17).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
            Text('今日解锁 ' + this.cardData.unlockInsights.todayUnlockCount + ' 次')
              .fontSize(13).fontColor(ThemeColor.labelSecondary(this.isDarkMode))
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)

          Column({ space: 4 }) {
            Text(this.cardData.unlockInsights.todayUnlockCount > 0
              ? formatHourMinute(this.cardData.unlockInsights.peakHour, 0) : '--')
              .fontSize(16).fontWeight(FontWeight.Bold).fontColor(ThemeColor.accentOrange(this.isDarkMode))
            Text('高峰时段').fontSize(11).fontColor(ThemeColor.systemGray(this.isDarkMode))
          }.alignItems(HorizontalAlign.End)
        }.width('100%')

        Row({ space: 8 }) {
          Text('较昨日').fontSize(12).fontColor(ThemeColor.labelSecondary(this.isDarkMode))
          Text(this.getUnlockTrendText()).fontSize(12).fontColor(this.getUnlockTrendColor()).fontWeight(FontWeight.Medium)
        }.width('100%')

        Stack({ alignContent: Alignment.Bottom }) {
          Row() {
            ForEach(this.cardData.unlockInsights.weeklyUnlockCounts, (count: number, index: number) => {
              Column() {
                Row() {
                  Column()
                    .width(HOME_CARD_BAR_WIDTH)
                    .height(this.getUnlockBarHeight(count))
                    .borderRadius(5)
                    .backgroundColor(this.getUnlockBarColor(count, index === 6))
                    .opacity(count <= 0 ? 0.25 : 1)
                    .animation({ duration: 600, delay: 200 + index * 60, curve: curves.interpolatingSpring(0, 1, 170, 14) })
                }
                .width('100%').alignItems(VerticalAlign.Bottom).justifyContent(FlexAlign.End)
              }
              .layoutWeight(1).height(HOME_CARD_UNLOCK_CHART_HEIGHT).justifyContent(FlexAlign.End)
            }, (count: number, index: number) => 'unlock_bar_' + index + '_' + count)
          }
          .width('100%').height(HOME_CARD_UNLOCK_CHART_HEIGHT).alignItems(VerticalAlign.Bottom)
        }
        .width('100%').height(HOME_CARD_UNLOCK_CHART_HEIGHT)
        .accessibilityLevel('yes')
        .accessibilityText(this.getUnlockChartAccessibilityText())

        Row() {
          ForEach(this.cardData.unlockInsights.weeklyUnlockCounts, (_c: number, index: number) => {
            Text(this.getWeekDayLabel(index))
              .fontSize(11).fontColor(index === 6 ? ThemeColor.accentGreen(this.isDarkMode) : ThemeColor.labelSecondary(this.isDarkMode))
              .fontWeight(index === 6 ? FontWeight.Medium : FontWeight.Normal)
              .textAlign(TextAlign.Center).layoutWeight(1)
          }, (_c: number, index: number) => 'unlock_label_' + index)
        }
      }
      .width('100%')
    }
  }

  private getUnlockBarHeight(count: number): number {
    return Math.max(3, Math.min(HOME_CARD_UNLOCK_BAR_MAX_HEIGHT, (count / this.getUnlockScaleMax()) * HOME_CARD_UNLOCK_BAR_MAX_HEIGHT))
  }
  private getUnlockScaleMax(): number {
    const arr: number[] = this.cardData.unlockInsights.weeklyUnlockCounts
    let max: number = 0
    for (let i = 0; i < arr.length; i++) { if (arr[i] > max) { max = arr[i] } }
    return Math.max(10, max)
  }
  private getUnlockBarColor(count: number, isToday: boolean): string {
    if (count <= 0) { return ThemeColor.systemGray(this.isDarkMode) }
    return isToday ? ThemeColor.accentOrange(this.isDarkMode) : ThemeColor.withAlpha(ThemeColor.accentOrange(this.isDarkMode), '59')
  }
  private getUnlockTrendColor(): string {
    const insights: UnlockInsights = this.cardData.unlockInsights;
    if (insights.todayUnlockCount < insights.yesterdayUnlockCount) {
      return ThemeColor.accentGreen(this.isDarkMode);
    } else if (insights.todayUnlockCount > insights.yesterdayUnlockCount) {
      return ThemeColor.accentRed(this.isDarkMode);
    }
    return ThemeColor.systemGray(this.isDarkMode);
  }
  private getUnlockTrendText(): string {
    const insights: UnlockInsights = this.cardData.unlockInsights
    if (insights.todayUnlockCount < insights.yesterdayUnlockCount) { return `减少 ${insights.yesterdayUnlockCount - insights.todayUnlockCount} 次` }
    if (insights.todayUnlockCount > insights.yesterdayUnlockCount) { return `增加 ${insights.todayUnlockCount - insights.yesterdayUnlockCount} 次` }
    return '持平'
  }
  private getUnlockChartAccessibilityText(): string {
    const arr: number[] = this.cardData.unlockInsights.weeklyUnlockCounts
    const parts: string[] = []
    for (let i = 0; i < arr.length; i++) { parts.push(this.getWeekDayLabel(i) + ' ' + arr[i] + '次') }
    return '本周解锁次数，今日 ' + this.cardData.unlockInsights.todayUnlockCount + ' 次，' + parts.join('、');
  }
  /** 趋势图标签：统一加“周”前缀；且从最旧的那天开始算起（近 7 天） */
  private getWeekDayLabel(index: number): string {
    const today: number = new Date().getDay();
    const dayIndex: number = (today - 6 + index + 7) % 7;
    return '周' + WEEKDAY_LABELS[dayIndex];
  }
}

/** ==================== 5. 每日目标入口卡片 ==================== */
@Component
export struct HomeGoalCard {
  @Prop delay: number = 0;
  @Prop cardOpacity: number = 0;
  @Prop cardTranslateY: number = 0;
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  /** 刷新信号：父组件只在卡片数据**实际变化**时自增（@ObjectLink 之外的兜底重建信号） */
  @Prop tick: number = 0;
  /** 卡片数据（响应式）：由父组件通过 @ObjectLink 共享 */
  @ObjectLink cardData: HomeCardData;
  /** 当前强调色（用户可在设置页切换）：直接读 ThemeManager，配合 tick 刷新保证不会滞留旧值 */
  private getAccentHex(): string {
    // 读 cardData（Index 的 tick 在数据变化时才写入）而不是直接问 manager：
    // manager 是普通字段、不参与 ArkUI 依赖追踪，直接读会把颜色冻结在首次渲染那一刻
    const hex: string = this.cardData.accentColorHex;
    return hex.length > 0 ? hex : ThemeManager.getInstance().getAccentColorHex(this.isDarkMode);
  }

  /** 导航回调：点击卡片时由父组件执行跳转（依赖 Index 的 controller / router） */
  onNavigate: ((target: string) => void) | undefined = undefined;
  build() {
    GlassCard({ delay: this.delay, cardOpacity: this.cardOpacity, cardTranslateY: this.cardTranslateY,
      accessibilityLabel: '每日目标与打卡，点击进入',
      onCardClick: () => { this.onNavigate?.('goal'); } }) {
      Row() {
        Column({ space: 4 }) {
          Text('每日目标').fontSize(17).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
          Text(this.cardData.goalTotalCount > 0
            ? `今日完成 ${this.cardData.goalCompletedCount}/${this.cardData.goalTotalCount} · 连续打卡 ${this.cardData.goalStreak} 天`
            : '设定目标，开始打卡')
            .fontSize(13).fontColor(ThemeColor.labelSecondary(this.isDarkMode))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)

        Text(this.cardData.goalTotalCount > 0 && this.cardData.goalCompletedCount === this.cardData.goalTotalCount ? '✓ 全部完成' : '去打卡')
          .fontSize(12)
          .fontColor(this.cardData.goalTotalCount > 0 && this.cardData.goalCompletedCount === this.cardData.goalTotalCount
            ? ThemeColor.accentGreen(this.isDarkMode) : ThemeColor.accentColor(this.getAccentHex(), this.isDarkMode))
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .backgroundColor(ThemeColor.withAlpha(this.cardData.goalTotalCount > 0 && this.cardData.goalCompletedCount === this.cardData.goalTotalCount
            ? ThemeColor.accentGreen(this.isDarkMode) : ThemeColor.accentColor(this.getAccentHex(), this.isDarkMode), '14'))
          .borderRadius(12)
      }.width('100%')
    }
  }
}

/** ==================== 6. 每周洞察入口卡片 ==================== */
@Component
export struct HomeInsightsCard {
  @Prop delay: number = 0;
  @Prop cardOpacity: number = 0;
  @Prop cardTranslateY: number = 0;
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  /** 刷新信号：父组件只在卡片数据**实际变化**时自增（@ObjectLink 之外的兜底重建信号） */
  @Prop tick: number = 0;
  /** 卡片数据（响应式）：由父组件通过 @ObjectLink 共享 */
  @ObjectLink cardData: HomeCardData;
  /** 当前强调色（用户可在设置页切换）：直接读 ThemeManager，配合 tick 刷新保证不会滞留旧值 */
  private getAccentHex(): string {
    // 读 cardData（Index 的 tick 在数据变化时才写入）而不是直接问 manager：
    // manager 是普通字段、不参与 ArkUI 依赖追踪，直接读会把颜色冻结在首次渲染那一刻
    const hex: string = this.cardData.accentColorHex;
    return hex.length > 0 ? hex : ThemeManager.getInstance().getAccentColorHex(this.isDarkMode);
  }

  /** 导航回调：点击卡片时由父组件执行跳转（依赖 Index 的 controller / router） */
  onNavigate: ((target: string) => void) | undefined = undefined;

  build() {
    GlassCard({ delay: this.delay, cardOpacity: this.cardOpacity, cardTranslateY: this.cardTranslateY,
      accessibilityLabel: '每周洞察，点击进入',
      onCardClick: () => { this.onNavigate?.('insights'); } }) {
      Row() {
        Column({ space: 4 }) {
          Text('每周洞察').fontSize(17).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
          Text('屏幕·睡眠·专注·目标·成就').fontSize(13).fontColor(ThemeColor.labelSecondary(this.isDarkMode))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)

        Text('进入').fontSize(12)
          .fontColor(ThemeColor.accentColor(this.getAccentHex(), this.isDarkMode))
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .backgroundColor(ThemeColor.withAlpha(ThemeColor.accentColor(this.getAccentHex(), this.isDarkMode), '14'))
          .borderRadius(12)
      }.width('100%')
    }
  }
}

/** ==================== 7. 提醒暂停卡片 ==================== */
@Component
export struct HomeReminderCard {
  @Prop delay: number = 0;
  @Prop cardOpacity: number = 0;
  @Prop cardTranslateY: number = 0;
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  /** 刷新信号：父组件只在卡片数据**实际变化**时自增（@ObjectLink 之外的兜底重建信号） */
  @Prop tick: number = 0;
  /** 卡片数据（响应式）：由父组件通过 @ObjectLink 共享 */
  @ObjectLink cardData: HomeCardData;
  /** 当前强调色（用户可在设置页切换）：直接读 ThemeManager，配合 tick 刷新保证不会滞留旧值 */
  private getAccentHex(): string {
    // 读 cardData（Index 的 tick 在数据变化时才写入）而不是直接问 manager：
    // manager 是普通字段、不参与 ArkUI 依赖追踪，直接读会把颜色冻结在首次渲染那一刻
    const hex: string = this.cardData.accentColorHex;
    return hex.length > 0 ? hex : ThemeManager.getInstance().getAccentColorHex(this.isDarkMode);
  }


  private scheduler: OngoingReminderScheduler = OngoingReminderScheduler.getInstance();

  /**
   * 正在提醒的条目：**直接读 cardData**，不再自持 @State + 1s 定时器。
   *
   * 原实现让本卡片另起一个 setInterval，每秒把 cardData.activeAlerts 再
   * JSON.stringify 比较一遍 —— 而 Index 的 1s tick 本来就在做同一件事（且已做等价比较）。
   * 同一份数据被轮询两遍、字符串化两遍，还给「已切走但仍挂载」的首页常驻了一个定时器。
   */
  private getActiveAlerts(): ActiveAlert[] {
    return this.cardData.activeAlerts;
  }

  private showToast(message: string): void {
    showToastSafe(this.getUIContext(), 'HomeReminderCard', 'HomeReminderCard', message);
  }

  build() {
    GlassCard({ delay: this.delay, cardOpacity: this.cardOpacity, cardTranslateY: this.cardTranslateY }) {
      Column({ space: 8 }) {
        Row() {
          Text('提醒暂停').fontSize(17).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
          Blank()
          Text(this.getActiveAlerts().length > 0 ? `${this.getActiveAlerts().length} 条` : '无')
            .fontSize(15).fontWeight(FontWeight.Bold)
            .fontColor(this.getActiveAlerts().length > 0 ? ThemeColor.accentOrange(this.isDarkMode) : ThemeColor.labelSecondary(this.isDarkMode))
        }
        .width('100%')

        if (this.getActiveAlerts().length > 0) {
          ForEach(this.getActiveAlerts(), (alert: ActiveAlert) => {
            Row({ space: 8 }) {
              Column({ space: 2 }) {
                Text(alert.title).fontSize(14).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(alert.content).fontSize(11).fontColor(ThemeColor.labelSecondary(this.isDarkMode))
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .layoutWeight(1).alignItems(HorizontalAlign.Start)

              Row({ space: 6 }) {
                Button('暂停 15 分')
                  .fontSize(11).fontColor(IOS26_WHITE)
                  .backgroundColor(ThemeColor.accentColorFill(this.getAccentHex(), this.isDarkMode))
                  .borderRadius(16).padding({ left: 8, right: 8 }).height(30)
                  .onClick(() => {
                    const ok: boolean = this.scheduler.snooze(alert.id, 15)
                    if (ok) {
                      // 列表由 Index 下一秒的 tick 统一回填（cardData.activeAlerts），无需本地手动刷新
                      this.showToast(`已暂停 ${alert.title} 15 分钟`);
                    }
                  })
                // 按钮语义是"收起本次提醒"，不是"关闭这条提醒"：
                // dismiss 只注销内存调度、不写 prefs，设置页仍显示开启、下次到点还会再提醒。
                // 用「收起」避免用户以为已经永久关闭。
                Button('收起')
                  .fontSize(11).fontColor(ThemeColor.accentRed(this.isDarkMode))
                  .backgroundColor(ThemeColor.withAlpha(ThemeColor.accentRed(this.isDarkMode), '0.1'))
                  .borderRadius(16).padding({ left: 8, right: 8 }).height(30)
                  .onClick(() => {
                    const ok: boolean = this.scheduler.dismiss(alert.id)
                    if (ok) {
                      this.showToast(`已收起本次提醒：${alert.title}`);
                    }
                  })
              }
            }
            .width('100%')
          }, (alert: ActiveAlert) => `alert_${alert.id}`)
        } else {
          Text('暂无正在提醒的内容')
            .fontSize(13).fontColor(ThemeColor.labelSecondary(this.isDarkMode))
            .width('100%').textAlign(TextAlign.Center)
        }
      }
      .width('100%').padding(16)
    }
  }
}

/** ==================== 8. 专注模式快捷入口卡片 ==================== */
@Component
export struct HomeFocusCard {
  @Prop delay: number = 0;
  @Prop cardOpacity: number = 0;
  @Prop cardTranslateY: number = 0;
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  /** 刷新信号：父组件只在卡片数据**实际变化**时自增（@ObjectLink 之外的兜底重建信号） */
  @Prop tick: number = 0;
  /** 卡片数据（响应式）：由父组件通过 @ObjectLink 共享 */
  @ObjectLink cardData: HomeCardData;
  /** 当前强调色（用户可在设置页切换）：直接读 ThemeManager，配合 tick 刷新保证不会滞留旧值 */
  private getAccentHex(): string {
    // 读 cardData（Index 的 tick 在数据变化时才写入）而不是直接问 manager：
    // manager 是普通字段、不参与 ArkUI 依赖追踪，直接读会把颜色冻结在首次渲染那一刻
    const hex: string = this.cardData.accentColorHex;
    return hex.length > 0 ? hex : ThemeManager.getInstance().getAccentColorHex(this.isDarkMode);
  }

  /** 导航回调：点击卡片时由父组件执行跳转（依赖 Index 的 controller / router） */
  onNavigate: ((target: string) => void) | undefined = undefined;
  build() {
    GlassCard({ delay: this.delay, cardOpacity: this.cardOpacity, cardTranslateY: this.cardTranslateY,
      accessibilityLabel: '专注模式，点击进入',
      onCardClick: () => { this.onNavigate?.('focus'); } }) {
      Row() {
        Column({ space: 4 }) {
          Text('专注模式').fontSize(17).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
          Row({ space: 8 }) {
            Text('积分 ' + this.cardData.focusStats.totalPoints)
              .fontSize(13).fontColor(ThemeColor.labelSecondary(this.isDarkMode)).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text('今日 ' + this.cardData.focusStats.todayMinutes + '分钟')
              .fontSize(13).fontColor(ThemeColor.labelSecondary(this.isDarkMode)).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)

        Button('开始专注')
          .fontSize(14).backgroundColor(ThemeColor.accentColorFill(this.getAccentHex(), this.isDarkMode))
          .fontColor(IOS26_WHITE).borderRadius(18).height(36).padding({ left: 16, right: 16 })
          .onClick(() => { this.onNavigate?.('focus'); })
      }.width('100%')
    }
  }
}

/** ==================== 9. 成就徽章展示卡片 ==================== */
@Component
export struct HomeAchievementCard {
  @Prop delay: number = 0;
  @Prop cardOpacity: number = 0;
  @Prop cardTranslateY: number = 0;
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  /** 刷新信号：父组件只在卡片数据**实际变化**时自增（@ObjectLink 之外的兜底重建信号） */
  @Prop tick: number = 0;
  /** 卡片数据（响应式）：由父组件通过 @ObjectLink 共享 */
  @ObjectLink cardData: HomeCardData;
  /** 导航回调：点击卡片时由父组件执行跳转（依赖 Index 的 controller / router） */
  onNavigate: ((target: string) => void) | undefined = undefined;
  build() {
    GlassCard({ delay: this.delay, cardOpacity: this.cardOpacity, cardTranslateY: this.cardTranslateY,
      accessibilityLabel: '我的成就，点击进入',
      onCardClick: () => { this.onNavigate?.('achievement'); } }) {
      Column({ space: 16 }) {
        Row() {
          Text('我的成就').fontSize(17).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
          Blank()
          Text(this.getAchievementRate() + '%')
            .fontSize(20).fontWeight(FontWeight.Bold).fontColor(ThemeColor.tierGold(this.isDarkMode))
        }
        .width('100%').alignItems(VerticalAlign.Center)

        Stack({ alignContent: Alignment.Center }) {
          Progress({ value: this.getAchievementRate(), total: 100, type: ProgressType.Ring })
            .width(52).height(52).color(ThemeColor.tierGold(this.isDarkMode)).style({ strokeWidth: 4 })
          Text(this.getAchievementRate() + '%').fontSize(11).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
          .accessibilityLevel('yes')
          .accessibilityText('成就解锁进度，已解锁 ' + this.cardData.achievementCount +
            '/' + this.cardData.totalAchievements + '，完成' + this.getAchievementRate() + '%')
        }
        .width(52).height(52)

        Row() {
          Text('已解锁').fontSize(11).fontColor(ThemeColor.labelSecondary(this.isDarkMode))
          Blank()
          Text(this.cardData.achievementCount + '/' + this.cardData.totalAchievements)
            .fontSize(13).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
        }
      }
      .width('100%')
    }
  }

  private getAchievementRate(): number {
    const total: number = this.cardData.totalAchievements
    if (total <= 0) { return 0 }
    return Math.round((this.cardData.achievementCount / total) * 100)
  }
}

/** ==================== 统一入口组件 ==================== */
@Component
export struct HomeCardItem {
  @Prop cardId: string;
  @Prop delay: number = 0;
  @Prop cardOpacity: number = 0;
  @Prop cardTranslateY: number = 0;
  /** 刷新信号：父组件只在卡片数据实际变化时自增，原样透传给所有子卡片 */
  @Prop tick: number = 0;
  /** 卡片数据（响应式）：由父组件通过 @ObjectLink 共享 */
  @ObjectLink cardData: HomeCardData;
  /** 导航回调：透传给需要跳转的子卡片 */
  onNavigate: ((target: string) => void) | undefined = undefined;

  build() {
    if (this.cardId === 'usage') {
      HomeUsageCard({ delay: this.delay, cardOpacity: this.cardOpacity, cardTranslateY: this.cardTranslateY , tick: this.tick, cardData: this.cardData})
    } else if (this.cardId === 'downtime') {
      HomeDowntimeCard({ delay: this.delay, cardOpacity: this.cardOpacity, cardTranslateY: this.cardTranslateY, onNavigate: this.onNavigate , tick: this.tick, cardData: this.cardData})
    } else if (this.cardId === 'trend') {
      HomeTrendCard({ delay: this.delay, cardOpacity: this.cardOpacity, cardTranslateY: this.cardTranslateY , tick: this.tick, cardData: this.cardData})
    } else if (this.cardId === 'unlock') {
      HomeUnlockCard({ delay: this.delay, cardOpacity: this.cardOpacity, cardTranslateY: this.cardTranslateY , tick: this.tick, cardData: this.cardData})
    } else if (this.cardId === 'goal') {
      HomeGoalCard({ delay: this.delay, cardOpacity: this.cardOpacity, cardTranslateY: this.cardTranslateY, onNavigate: this.onNavigate , tick: this.tick, cardData: this.cardData})
    } else if (this.cardId === 'insights') {
      HomeInsightsCard({ delay: this.delay, cardOpacity: this.cardOpacity, cardTranslateY: this.cardTranslateY, onNavigate: this.onNavigate , tick: this.tick, cardData: this.cardData})
    } else if (this.cardId === 'reminder') {
      HomeReminderCard({ delay: this.delay, cardOpacity: this.cardOpacity, cardTranslateY: this.cardTranslateY , tick: this.tick, cardData: this.cardData})
    } else if (this.cardId === 'focus') {
      HomeFocusCard({ delay: this.delay, cardOpacity: this.cardOpacity, cardTranslateY: this.cardTranslateY, onNavigate: this.onNavigate , tick: this.tick, cardData: this.cardData})
    } else if (this.cardId === 'achievement') {
      HomeAchievementCard({ delay: this.delay, cardOpacity: this.cardOpacity, cardTranslateY: this.cardTranslateY, onNavigate: this.onNavigate , tick: this.tick, cardData: this.cardData})
    }
  }
}
