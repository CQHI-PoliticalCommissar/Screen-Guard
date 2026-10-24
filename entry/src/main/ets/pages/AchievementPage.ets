import { formatError } from '../models/ErrUtils';
import { hilog } from '@kit.PerformanceAnalysisKit';
/**
 * 成就详情页面
 * 展示所有成就及解锁进度
 */
import { AchievementManager, Achievement } from '../managers/AchievementManager';
import { GlassCard } from '../components/GlassCard';
import { AmbientLight } from '../components/AmbientLight';
import { AppLifecycleTracker } from '../managers/AppLifecycleTracker';
import {
  ThemeColor
} from '../components/iOS26Theme';

@Entry
@Component
struct AchievementPage {
  /** 用户强调色（跟随设置页「强调色」选择，全应用一致） */
  @StorageLink('accentColorHex') accentColorHex: string = '#0066CC';
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  @State achievements: Achievement[] = [];
  @State completionRate: number = 0;
  @State cardOpacity: number = 0;
  @State cardY: number = 30;

  private achievementManager: AchievementManager = AchievementManager.getInstance();

  private entranceTimerId: number = -1;

  /**
   * 可见期轮询刷新定时器。
   * 聚合循环（前台 5s / 后台 30s）会实时解锁成就，但页面自身不重建，
   * 因此需要周期性重拉快照，否则用户停留本页时看不到新解锁。
   */
  private refreshTimerId: number = -1;

  /** 上一次快照的指纹，用于跳过无变化的重拉（避免无谓的 @State 赋值与 ForEach diff） */
  private lastSnapshotKey: string = '';

  aboutToAppear(): void {
    this.loadAchievements();
    this.entranceTimerId = setTimeout(() => {
      this.cardOpacity = 1;
      this.cardY = 0;
      this.entranceTimerId = -1;
    }, 100);

    this.startRefreshTimer();
  }

  aboutToDisappear(): void {
    if (this.entranceTimerId >= 0) {
      clearTimeout(this.entranceTimerId);
      this.entranceTimerId = -1;
    }
    if (this.refreshTimerId >= 0) {
      clearInterval(this.refreshTimerId);
      this.refreshTimerId = -1;
    }
  }

  /** 页面每次显示时立即刷新一次（自其他页返回时先补一次，不必等轮询） */
  onPageShow(): void {
    this.loadAchievements();
    this.startRefreshTimer();
  }

  /** 启动可见期轮询；已存在则不重复创建 */
  private startRefreshTimer(): void {
    if (this.refreshTimerId >= 0) {
      return;
    }
    this.refreshTimerId = setInterval(() => {
      // 退到后台即跳过 3s 轮询（loadAchievements 会深拷贝 14 项成就并重建整列表）；
      // 回前台后下一周期自动恢复
      if (!AppLifecycleTracker.getInstance().isForeground()) {
        return;
      }
      this.loadAchievements();
    }, 3000);
  }

  /**
   * 拉取全部成就与总完成度。
   * getAllAchievements() 返回深拷贝，故需整体重新赋给 @State 才能触发 UI 更新。
   */
  private loadAchievements(): void {
    try {
      // 守卫必须走在深拷贝**之前**：本方法由 3s 轮询驱动，而 getAllAchievements()
      // 每次要 new 14 个 9 字段对象。指纹直接取 manager 的实现，页面不再自带一份
      // 拼接逻辑（此前两份格式还不一致，一旦各自改动就会静默错判）。
      const snapshotKey = this.achievementManager.getAchievementsSnapshotKey();
      if (snapshotKey === this.lastSnapshotKey) {
        return;
      }
      this.lastSnapshotKey = snapshotKey;
      const latest: Achievement[] = this.achievementManager.getAllAchievements();
      this.achievements = latest;
      this.completionRate = this.achievementManager.getCompletionRate();
    } catch (err) {
      hilog.error(0x0000, 'AchievementPage', '%{public}s', 'loadAchievements failed: ' + formatError(err));
    }
  }

  /** 成就等级对应颜色（铜/银/金/白金） */
  private getTierColor(tier: string): string {
    switch (tier) {
      case 'bronze':
        return ThemeColor.tierBronze(this.isDarkMode);
      case 'silver':
        return ThemeColor.tierSilver(this.isDarkMode);
      case 'gold':
        return ThemeColor.tierGold(this.isDarkMode);
      case 'platinum':
        return ThemeColor.tierPlatinum(this.isDarkMode);
      default:
        return ThemeColor.systemGray(this.isDarkMode);
    }
  }

  /** 成就等级中文名（铜牌/银牌/金牌/白金） */
  private getTierName(tier: string): string {
    switch (tier) {
      case 'bronze':
        return '铜牌';
      case 'silver':
        return '银牌';
      case 'gold':
        return '金牌';
      case 'platinum':
        return '白金';
      default:
        return '';
    }
  }

  /** 成就进度百分比（0~100），target 非法时返回 0 */
  private getProgressPercent(achievement: Achievement): number {
    if (achievement.target <= 0) {
      return 0;
    }
    return Math.min(100, (achievement.progress / achievement.target) * 100);
  }

  /** 解锁时间格式化为 "X月X日解锁"；缺少时间戳（旧数据/手工改过的 prefs）时不显示 1970 年 */
  private formatDate(timestamp: number): string {
    if (!Number.isFinite(timestamp) || timestamp <= 0) {
      return '已解锁';
    }
    const date = new Date(timestamp);
    return `${date.getMonth() + 1}月${date.getDate()}日解锁`;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 全局多彩液态渐变背景
      // ⚠️ 必须挂 expandSafeArea：根 Stack 上的 expandSafeArea 只让容器延伸进安全区，
      // 子组件仍被裁在安全区内，状态栏/导航条区域会露出默认白底形成白带（实机截图取证）。
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
        // 无障碍：内容仅 "←"，读屏只会播报箭头符号，需显式语义标签
        .accessibilityText('返回')
        .onClick(() => {
          try {
            this.getUIContext().getRouter().back();
          } catch (err) {
            hilog.error(0x0000, 'AchievementPage', '%{public}s', '返回失败: ' + formatError(err));
          }
        })

        Text('我的成就')
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

      // 总体进度
      GlassCard({
        delay: 0,
        cardOpacity: this.cardOpacity,
        cardTranslateY: this.cardY,
        cardWidth: '90%',
        cardMargin: { top: 16 }
      }) {
        Row() {
          Column({ space: 4 }) {
            Text('成就完成度')
              .fontSize(16)
              .fontColor(ThemeColor.systemGray(this.isDarkMode))
            Text(`${this.completionRate}%`)
              .fontSize(36)
              .fontWeight(FontWeight.Bold)
              .fontColor(ThemeColor.accentColor(this.accentColorHex, this.isDarkMode))
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Stack() {
            Progress({ value: this.completionRate, total: 100, type: ProgressType.Ring })
              .width(70)
              .height(70)
              .color(ThemeColor.accentColor(this.accentColorHex, this.isDarkMode))
              .backgroundColor(ThemeColor.fillWeak(this.isDarkMode))
              .style({ strokeWidth: 6 })
              // 无障碍：Progress 自身只会被读成一个孤立百分数，而左侧还有一行
              // 同值的 Text 会重复播报一次。内环设 'no'（只隐藏自身、不影响子节点），
              // 由外层 Stack 承载唯一一份语义。
              .accessibilityLevel('no')
          }
          .accessibilityLevel('yes')
          .accessibilityText('成就完成度，已完成 ' + this.completionRate + '%')
        }
        .width('100%')
        .padding(20)
      }

      // 成就列表
      // 原为 List —— 但本 SDK 的 List 不支持 expandSafeArea 穿透（实机：加在 List 与根 Stack 上
      // 均无效，页面顶部 137px 始终是系统状态栏黑带），而 Scroll 可以。
      // 14 项固定条目无懒加载需求，ListItem 的居中改由每项的 alignSelf(Center) 承担，等价。
      Scroll() {
        // ListItem 的 alignListItem(Center) 在 Scroll 下改由这一层的 alignItems 承担：
        // GlassCard 是自定义组件，ArkTS 不允许在其属性链上直接调 alignSelf / alignItems
        // （编译报 10505001 Cannot find name 'alignSelf'），必须由父 Column 居中。
        Column({ space: 12 }) {
          ForEach(this.achievements, (achievement: Achievement) => {
            GlassCard({
              delay: 100,
              cardOpacity: this.cardOpacity,
              cardTranslateY: this.cardY,
              cardWidth: '90%'
            }) {
              Row() {
                // 成就图标
                Text(achievement.icon)
                  .fontSize(36)
                  .opacity(achievement.unlocked ? 1 : 0.3)

                Column({ space: 6 }) {
                  Row() {
                    Text(achievement.name)
                      .fontSize(16)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(achievement.unlocked ? ThemeColor.label(this.isDarkMode) : ThemeColor.systemGray(this.isDarkMode))

                    Text(this.getTierName(achievement.tier))
                      .fontSize(11)
                      .fontColor(this.getTierColor(achievement.tier))
                      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                      .backgroundColor(ThemeColor.withAlpha(this.getTierColor(achievement.tier), '22'))
                      .borderRadius(4)
                      .margin({ left: 8 })
                  }

                  Text(achievement.description)
                    .fontSize(13)
                    .fontColor(ThemeColor.systemGray(this.isDarkMode))

                  // 进度条
                  if (!achievement.unlocked) {
                    Stack({ alignContent: Alignment.Start }) {
                      Column()
                        .width('100%')
                        .height(4)
                        .backgroundColor(ThemeColor.inputBg(this.isDarkMode))
                        .borderRadius(2)

                      Column()
                        .width(this.getProgressPercent(achievement) + '%')
                        .height(4)
                        .backgroundColor(ThemeColor.accentColor(this.accentColorHex, this.isDarkMode))
                        .borderRadius(2)
                    }
                    .width('100%')
                    .margin({ top: 8 })

                    Text(`${achievement.progress}/${achievement.target}`)
                      .fontSize(11)
                      .fontColor(ThemeColor.systemGray(this.isDarkMode))
                      .margin({ top: 4 })
                  } else {
                    Text(this.formatDate(achievement.unlockedAt || 0))
                      .fontSize(11)
                      .fontColor(ThemeColor.accentGreen(this.isDarkMode))
                      .margin({ top: 4 })
                  }
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                .margin({ left: 16 })
              }
.width('100%')
              .padding(16)
            }
          // key 必须包含进度与解锁态：ArkUI ForEach 对相同 key 不重建子组件，
          // 仅用 achievement.id 会让进度条/解锁态停留在首次渲染的旧值
          }, (achievement: Achievement) =>
            `${achievement.id}_${achievement.progress}_${achievement.unlocked ? 1 : 0}`)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ top: 8, bottom: 80 })
      .scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    .width('100%')
    .height('100%')
    // 内容延伸进顶部/底部安全区：内层 List 上的 expandSafeArea 会被这层 Column 裁掉
    // （实机截图：页面顶部 137px 是系统状态栏黑带，与 GoalPage 改前完全一致）。
    // 必须加在根 Stack 才生效 —— 与 GoalPage / Index.ets 同理。
    // 标题行自带 margin({top:50}) 补偿状态栏高度，延伸后视觉位置不变。
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
  }
}
