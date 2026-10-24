/**
 * 每周洞察页面
 * 聚合屏幕使用、睡眠、专注、目标、成就五维数据的周度汇总，
 * 作为首页趋势卡的深度详情页，不复用首页已有的周趋势卡。
 * 不申请新权限，全部复用既有 Manager 数据。
 */
import { formatError } from '../models/ErrUtils';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { GlassCard } from '../components/GlassCard';
import { AmbientLight } from '../components/AmbientLight';
import {
  IOS26_WHITE,
  ThemeColor
} from '../components/iOS26Theme';
import { showToastSafe } from '../models/UiUtils';
import {
  WeeklyTrendInfo,
  UnlockInsights,
  WEEKDAY_LABELS,
  formatHourMinute
} from '../models/HealthTypes';
import { UsageStatsManager } from '../managers/UsageStatsManager';
import { SleepManager } from '../managers/SleepManager';
import { FocusModeManager, FocusStats } from '../managers/FocusModeManager';
import { DailyGoalManager } from '../managers/DailyGoalManager';
import { AchievementManager } from '../managers/AchievementManager';

const TAG = 'InsightsPage';

/** 趋势图绘图区高度（vp） */
const TREND_CHART_HEIGHT = 96;
/** 趋势图柱体最大高度（vp） */
const TREND_BAR_MAX_HEIGHT = 62;
/** 趋势图柱体宽度（vp） */
const TREND_BAR_WIDTH = 20;

interface SleepOverview {
  sleepDurationMinutes: number;
  preSleepUsageMinutes: number;
  score: number;
  goalMinutes: number;
}

interface GoalOverview {
  total: number;
  completed: number;
  todayCheckedIn: boolean;
  streak: number;
}

@Entry
@Component
struct InsightsPage {
  /** 用户强调色（跟随设置页「强调色」选择，全应用一致） */
  @StorageLink('accentColorHex') accentColorHex: string = '#0066CC';
  @State weeklyTrend: WeeklyTrendInfo = {
    dailyMinutes: [0, 0, 0, 0, 0, 0, 0],
    averageMinutes: 0,
    maxMinutes: 0,
    totalMinutes: 0,
    trendDirection: 'stable',
    trendDeltaPercent: 0,
    todayRank: 0
  };
  @State unlockInsights: UnlockInsights = {
    todayUnlockCount: 0,
    yesterdayUnlockCount: 0,
    weeklyUnlockCounts: [0, 0, 0, 0, 0, 0, 0],
    peakHour: 0,
    peakHourCount: 0,
    hourlyUnlockCounts: [],
    trendDirection: 'stable',
    trendDeltaPercent: 0
  };
  @State sleepOverview: SleepOverview = {
    sleepDurationMinutes: 0,
    preSleepUsageMinutes: 0,
    score: 0,
    goalMinutes: 480
  };
  @State focusStats: FocusStats = {
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
  @State goalOverview: GoalOverview = {
    total: 0,
    completed: 0,
    todayCheckedIn: false,
    streak: 0
  };
  @State achievementCount: number = 0;
  @State totalAchievements: number = 0;
  @State cardOpacity: number = 0;
  @State cardY: number = 30;
  @StorageProp('isDarkMode') isDarkMode: boolean = false;

  private usageManager = UsageStatsManager.getInstance();
  private sleepManager = SleepManager.getInstance();
  private goalManager = DailyGoalManager.getInstance();
  private achievementManager = AchievementManager.getInstance();
  private entranceTimerId: number = -1;

  aboutToAppear(): void {
    this.loadData();
    this.entranceTimerId = setTimeout(() => {
      this.cardOpacity = 1;
      this.cardY = 0;
      this.entranceTimerId = -1;
    }, 100);
  }

  aboutToDisappear(): void {
    if (this.entranceTimerId !== -1) {
      clearTimeout(this.entranceTimerId);
      this.entranceTimerId = -1;
    }
  }

  private loadData(): void {
    this.weeklyTrend = this.usageManager.getWeeklyTrendInfo();
    this.unlockInsights = this.usageManager.getUnlockInsights();

    const sleepPrefs = this.sleepManager.getSleepPreferences();
    const sleepData = this.sleepManager.getSleepData();
    this.sleepOverview = {
      sleepDurationMinutes: sleepData.sleepDurationMinutes,
      preSleepUsageMinutes: sleepData.preSleepUsageMinutes,
      score: sleepData.score,
      goalMinutes: sleepPrefs.sleepGoalMinutes
    };

    this.focusStats = FocusModeManager.getInstance().getStats();

    const counts = this.goalManager.getGoalCounts();
    const todayCheckin = this.goalManager.getTodayCheckin();
    this.goalOverview = {
      total: counts.total,
      completed: counts.completed,
      todayCheckedIn: todayCheckin !== null,
      streak: this.goalManager.getCurrentStreak()
    };

    this.achievementCount = this.achievementManager.getUnlockedAchievementCount();
    this.totalAchievements = this.achievementManager.getTotalAchievementCount();
  }

  private getUsageColor(): string {
    const limitSec = this.usageManager.getTotalDailyLimitMinutes() * 60;
    if (limitSec <= 0) {
      return ThemeColor.accentColor(this.accentColorHex, this.isDarkMode);
    }
    const ratio = this.weeklyTrend.averageMinutes * 60 / limitSec;
    if (ratio >= 1) {
      return ThemeColor.accentRed(this.isDarkMode);
    } else if (ratio >= 0.75) {
      return ThemeColor.accentOrange(this.isDarkMode);
    }
    return ThemeColor.accentGreen(this.isDarkMode);
  }

  private getGoalCompletionRate(): number {
    if (this.goalOverview.total <= 0) {
      return 0;
    }
    return Math.round((this.goalOverview.completed / this.goalOverview.total) * 100);
  }

  private getAchievementRate(): number {
    if (this.totalAchievements <= 0) {
      return 0;
    }
    return Math.round((this.achievementCount / this.totalAchievements) * 100);
  }

  private getWeekDayLabel(index: number): string {
    // 数据顺序是「6 天前 → 今天」（UsageStatsManager.getWeeklyTrendInfo 的倒序循环），
    // 不能直接把 index 当星期几：index 0 是 6 天前，不是周日。
    // 与 HomeCards 的趋势图标签同一换算口径。
    const today: number = new Date().getDay();
    const dayIndex: number = (today - 6 + index + 7) % 7;
    return '周' + WEEKDAY_LABELS[dayIndex];
  }

  /** 单根柱体高度：4vp 下限避免"有数据但看不清"，40vp 上限给限额线留空间 */
  private getBarHeight(minutes: number): number {
    const scale = this.getTrendScaleMax();
    return Math.max(4, Math.min(TREND_BAR_MAX_HEIGHT, (minutes / scale) * TREND_BAR_MAX_HEIGHT));
  }

  /** 趋势图纵向比例尺上限（分钟）：纳入每日限额，使限额参考线恒可见 */
  private getTrendScaleMax(): number {
    const limitMinutes = this.usageManager.getTotalDailyLimitMinutes();
    const arr = this.weeklyTrend.dailyMinutes;
    let maxMinutes = 60;
    for (let i = 0; i < arr.length; i++) {
      if (arr[i] > maxMinutes) {
        maxMinutes = arr[i];
      }
    }
    return Math.max(maxMinutes, limitMinutes);
  }

  private getBarColor(minutes: number): string {
    const limitMinutes = this.usageManager.getTotalDailyLimitMinutes();
    if (minutes >= limitMinutes) {
      return ThemeColor.accentRed(this.isDarkMode);
    } else if (minutes >= limitMinutes * 0.75) {
      return ThemeColor.accentOrange(this.isDarkMode);
    }
    return ThemeColor.accentGreen(this.isDarkMode);
  }

  private getLimitLineColor(): string {
    return ThemeColor.withAlpha(this.getUsageColor(), '66');
  }

  private getLimitLineOffset(): number {
    const limitMinutes = this.usageManager.getTotalDailyLimitMinutes();
    if (limitMinutes <= 0) {
      return -1;
    }
    return this.getBarHeight(limitMinutes);
  }

  private formatMinutes(minutes: number): string {
    const hours = Math.floor(minutes / 60);
    const mins = minutes % 60;
    return hours > 0 ? hours + '小时' + (mins > 0 ? mins + '分' : '') : mins + '分钟';
  }

  private onBack(): void {
    try {
      this.getUIContext().getRouter().back();
    } catch (err) {
      hilog.error(0x0000, TAG, '%{public}s', '返回失败: ' + formatError(err));
    }
  }

  private showToast(message: string): void {
    showToastSafe(this.getUIContext(), TAG, 'InsightsPage', message);
  }

  // ================= 构建函数 =================

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 全局多彩液态渐变背景
      Column().width('100%').height('100%')
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .linearGradient({
          direction: GradientDirection.Bottom,
          colors: ThemeColor.gradient(this.isDarkMode)
        })

      // 随手机姿态变化的环境光晕
      AmbientLight()

      Column() {
        // 标题栏
        Row() {
          Button() {
            Text('←')
              .fontSize(20)
              .fontColor(ThemeColor.accentColor(this.accentColorHex, this.isDarkMode))
          }
          .backgroundColor('transparent')
          .width(40)
          .height(40)
          .accessibilityText('返回')
          .onClick(() => { this.onBack(); })

          Text('每周洞察')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(ThemeColor.label(this.isDarkMode))
            .layoutWeight(1)
            .textAlign(TextAlign.Center)

          Blank().width(40)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .margin({ top: 50 })

        Scroll() {
          Column({ space: 16 }) {
            // ===== 周度屏幕使用概览（带趋势图） =====
            GlassCard({
              delay: 0,
              cardOpacity: this.cardOpacity,
              cardTranslateY: this.cardY,
              cardWidth: '90%',
              cardMargin: { top: 8 }
            }) {
              Column({ space: 16 }) {
                Row() {
                  Text('本周屏幕使用').fontSize(17).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
                  Blank()
                  Text(this.weeklyTrend.totalMinutes + '分钟')
                    .fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.getUsageColor())
                }
                .width('100%')
                .justifyContent(FlexAlign.Center)

                // 7 天柱状图：每日使用分钟 + 限额参考线（专用绘图，不复用首页卡片）
                Stack({ alignContent: Alignment.Bottom }) {
                  Row() {
                    ForEach(this.weeklyTrend.dailyMinutes, (minutes: number, index: number) => {
                      Column({ space: 6 }) {
                        Column()
                          .width(TREND_BAR_WIDTH)
                          .height(this.getBarHeight(minutes))
                          .borderRadius(6)
                          .linearGradient({
                            direction: GradientDirection.Bottom,
                            colors: minutes <= 0
                              ? [[ThemeColor.fill(this.isDarkMode), 1], [ThemeColor.fill(this.isDarkMode), 1]]
                              : [
                                  [this.getBarColor(minutes), 1],
                                  [ThemeColor.withAlpha(this.getBarColor(minutes), '66'), 1]
                                ]
                          })
                          .border({ width: 0.5, color: ThemeColor.withAlpha(this.getBarColor(minutes), '66'), radius: 6 })
                      }
                      .layoutWeight(1)
                      .alignItems(HorizontalAlign.Center)
                      .justifyContent(FlexAlign.End)
                    }, (minutes: number, index: number) => 'insight_trend_' + index + '_' + minutes)
                  }
                  .width('100%')
                  .height(TREND_CHART_HEIGHT)
                  .alignItems(VerticalAlign.Bottom)

                  // 限额参考线
                  if (this.getLimitLineOffset() >= 0) {
                    Column()
                      .width('100%')
                      .height(1)
                      .backgroundColor(this.getLimitLineColor())
                      .margin({ bottom: this.getLimitLineOffset() })
                  }
                }
                .width('100%')
                .height(TREND_CHART_HEIGHT)

                // 星期标签
                Row() {
                  ForEach(this.weeklyTrend.dailyMinutes, (_minutes: number, index: number) => {
                    Text(this.getWeekDayLabel(index))
                      .fontSize(11)
                      .fontColor(ThemeColor.labelSecondary(this.isDarkMode))
                      .textAlign(TextAlign.Center)
                      .layoutWeight(1)
                  }, (_minutes: number, index: number) => 'insight_label_' + index)
                }
                .width('100%')

                Row({ space: 12 }) {
                  Column({ space: 2 }) {
                    Text('日均').fontSize(11).fontColor(ThemeColor.labelSecondary(this.isDarkMode))
                    Text(this.weeklyTrend.averageMinutes + '分钟')
                      .fontSize(13).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
                  }
                  Column({ space: 2 }) {
                    Text('峰值').fontSize(11).fontColor(ThemeColor.labelSecondary(this.isDarkMode))
                    Text(this.weeklyTrend.maxMinutes + '分钟')
                      .fontSize(13).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
                  }
                  Column({ space: 2 }) {
                    Text('连续达标').fontSize(11).fontColor(ThemeColor.labelSecondary(this.isDarkMode))
                    Text(this.usageManager.getStreakDays() + '天')
                      .fontSize(13).fontWeight(FontWeight.Medium).fontColor(ThemeColor.accentGreen(this.isDarkMode))
                  }
                }
                .width('100%')
              }
              .width('100%')
              .padding(20)
            }

            // ===== 睡眠达成卡片 =====
            GlassCard({
              delay: 100,
              cardOpacity: this.cardOpacity,
              cardTranslateY: this.cardY,
              cardWidth: '90%'
            }) {
              Column({ space: 16 }) {
                Row() {
                  Text('睡眠达成').fontSize(17).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
                  Blank()
                  Text(this.sleepOverview.score + '分')
                    .fontSize(20).fontWeight(FontWeight.Bold).fontColor(ThemeColor.accentOrange(this.isDarkMode))
                }
                .width('100%')
                .justifyContent(FlexAlign.Center)

                Row({ space: 12 }) {
                  Column({ space: 2 }) {
                    Text('昨晚时长').fontSize(11).fontColor(ThemeColor.labelSecondary(this.isDarkMode))
                    Text(this.formatMinutes(this.sleepOverview.sleepDurationMinutes))
                      .fontSize(13).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
                  }
                  Column({ space: 2 }) {
                    Text('目标时长').fontSize(11).fontColor(ThemeColor.labelSecondary(this.isDarkMode))
                    Text(this.formatMinutes(this.sleepOverview.goalMinutes))
                      .fontSize(13).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
                  }
                  Column({ space: 2 }) {
                    Text('睡前使用').fontSize(11).fontColor(ThemeColor.labelSecondary(this.isDarkMode))
                    Text(this.formatMinutes(this.sleepOverview.preSleepUsageMinutes))
                      .fontSize(13).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
                  }
                }
                .width('100%')
              }
              .width('100%')
              .padding(20)
            }

            // ===== 专注时长周报卡片 =====
            GlassCard({
              delay: 200,
              cardOpacity: this.cardOpacity,
              cardTranslateY: this.cardY,
              cardWidth: '90%'
            }) {
              Column({ space: 16 }) {
                Row() {
                  Text('专注时长').fontSize(17).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
                  Blank()
                  Text(this.focusStats.weekMinutes + '分钟')
                    .fontSize(20).fontWeight(FontWeight.Bold).fontColor(ThemeColor.accentColor(this.accentColorHex, this.isDarkMode))
                }
                .width('100%')
                .justifyContent(FlexAlign.Center)

                Row({ space: 12 }) {
                  Column({ space: 2 }) {
                    Text('本周会话').fontSize(11).fontColor(ThemeColor.labelSecondary(this.isDarkMode))
                    Text(this.focusStats.weekSessions + '次')
                      .fontSize(13).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
                  }
                  Column({ space: 2 }) {
                    Text('今日时长').fontSize(11).fontColor(ThemeColor.labelSecondary(this.isDarkMode))
                    Text(this.formatMinutes(this.focusStats.todayMinutes))
                      .fontSize(13).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
                  }
                  Column({ space: 2 }) {
                    Text('累积积分').fontSize(11).fontColor(ThemeColor.labelSecondary(this.isDarkMode))
                    Text(this.focusStats.totalPoints + '分')
                      .fontSize(13).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
                  }
                }
                .width('100%')
              }
              .width('100%')
              .padding(20)
            }

            // ===== 目标完成率卡片 =====
            GlassCard({
              delay: 300,
              cardOpacity: this.cardOpacity,
              cardTranslateY: this.cardY,
              cardWidth: '90%'
            }) {
              Column({ space: 16 }) {
                Row() {
                  Text('目标完成率').fontSize(17).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
                  Blank()
                  Text(this.getGoalCompletionRate() + '%')
                    .fontSize(20).fontWeight(FontWeight.Bold).fontColor(ThemeColor.accentGreen(this.isDarkMode))
                }
                .width('100%')
                .justifyContent(FlexAlign.Center)

                Row({ space: 12 }) {
                  Column({ space: 2 }) {
                    Text('今日目标').fontSize(11).fontColor(ThemeColor.labelSecondary(this.isDarkMode))
                    Text(this.goalOverview.completed + '/' + this.goalOverview.total)
                      .fontSize(13).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
                  }
                  Column({ space: 2 }) {
                    Text('今日打卡').fontSize(11).fontColor(ThemeColor.labelSecondary(this.isDarkMode))
                    Text(this.goalOverview.todayCheckedIn ? '已打卡' : '未打卡')
                      .fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.goalOverview.todayCheckedIn ? ThemeColor.accentGreen(this.isDarkMode) : ThemeColor.systemGray(this.isDarkMode))
                  }
                  Column({ space: 2 }) {
                    Text('连续打卡').fontSize(11).fontColor(ThemeColor.labelSecondary(this.isDarkMode))
                    Text(this.goalOverview.streak + '天')
                      .fontSize(13).fontWeight(FontWeight.Medium).fontColor(ThemeColor.accentGreen(this.isDarkMode))
                  }
                }
                .width('100%')
              }
              .width('100%')
              .padding(20)
            }

            // ===== 成就解锁进度卡片 =====
            GlassCard({
              delay: 400,
              cardOpacity: this.cardOpacity,
              cardTranslateY: this.cardY,
              cardWidth: '90%'
            }) {
              Column({ space: 16 }) {
                Row() {
                  Text('成就解锁').fontSize(17).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
                  Blank()
                  Text(this.getAchievementRate() + '%')
                    .fontSize(20).fontWeight(FontWeight.Bold).fontColor(ThemeColor.tierGold(this.isDarkMode))
                }
                .width('100%')
                .justifyContent(FlexAlign.Center)

                Stack({ alignContent: Alignment.Center }) {
                  Progress({ value: this.getAchievementRate(), total: 100, type: ProgressType.Ring })
                    .width(52).height(52)
                    .color(ThemeColor.tierGold(this.isDarkMode))
                    .style({ strokeWidth: 4 })
                  Text(this.getAchievementRate() + '%')
                    .fontSize(11).fontWeight(FontWeight.Medium)
                    .fontColor(ThemeColor.label(this.isDarkMode))
                }
                .width(52).height(52)

                Row() {
                  Text('已解锁').fontSize(11).fontColor(ThemeColor.labelSecondary(this.isDarkMode))
                  Blank()
                  Text(this.achievementCount + '/' + this.totalAchievements)
                    .fontSize(13).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
                }
                .width('100%')
              }
              .width('100%')
              .padding(20)
            }

            Column().height(120)
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 12, bottom: 16 })
        }
        .width('100%').layoutWeight(1).backgroundColor('transparent')
        .scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
      }
      .width('100%').height('100%')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    .width('100%')
    .height('100%')
    .backgroundColor('transparent')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
