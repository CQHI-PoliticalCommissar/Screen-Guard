/**
 * 专注模式页面
 * 番茄钟计时器 + 游戏化激励
 */
import { FocusModeManager, POMODORO_DURATION_MINUTES, SHORT_BREAK_MINUTES, LONG_BREAK_MINUTES } from '../managers/FocusModeManager';
import { GlassCard } from '../components/GlassCard';
import { AmbientLight } from '../components/AmbientLight';
import { AppLifecycleTracker } from '../managers/AppLifecycleTracker';
import {
  IOS26_WHITE,
  ThemeColor
} from '../components/iOS26Theme';

@Component
export struct FocusMode {
  /** 用户强调色（跟随设置页「强调色」选择，全应用一致） */
  @StorageLink('accentColorHex') accentColorHex: string = '#0066CC';
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  @State isActive: boolean = false;
  @State remainingSeconds: number = POMODORO_DURATION_MINUTES * 60;
  @State sessionType: 'focus' | 'short_break' | 'long_break' = 'focus';
  @State showCompletion: boolean = false;
  @State pointsEarned: number = 0;
  @State currentStreak: number = 0;
  @State focusDuration: number = POMODORO_DURATION_MINUTES;

  // 专注时长可选值（分钟）
  private focusDurations: number[] = [15, 25, 45, 60];

  // 统计数据
  @State totalPoints: number = 0;
  @State todaySessions: number = 0;
  @State todayMinutes: number = 0;
  @State longestStreak: number = 0;

  private focusManager: FocusModeManager = FocusModeManager.getInstance();
  private refreshTimer: number = -1;

  aboutToAppear(): void {
    this.focusManager.initialize();
    this.focusDuration = this.focusManager.getFocusDurationMinutes();
    // 从备份恢复的专注时长可能不在 15/25/45/60 之内（备份是合法 JSON，manager 侧只按
    // [5,180] 钳位后接受）。此时四个时长 chip 会**全部不高亮**，而计时器却按那个值走，
    // 用户无从判断当前设置的是多少分钟。故把该值补进选项列表。
    if (this.focusDurations.indexOf(this.focusDuration) < 0) {
      this.focusDurations = [...this.focusDurations, this.focusDuration].sort((a: number, b: number) => a - b);
    }
    const state = this.focusManager.getCurrentState();
    this.isActive = state.isActive;
    this.sessionType = state.sessionType;
    if (state.isActive) {
      this.remainingSeconds = state.remainingSeconds;
    } else {
      this.remainingSeconds = this.focusDuration * 60;
    }
    this.loadStats();
    this.focusManager.setOnTick((seconds: number) => {
      this.remainingSeconds = seconds;
    });
    this.focusManager.setOnComplete(() => {
      this.onSessionComplete();
    });

    // 定期刷新统计数据（统计仅在会话切换时变化，无需每秒轮询）
    // 退到后台跳过：页面仍挂载时后台重算统计无意义，回前台下一周期自动恢复
    this.refreshTimer = setInterval(() => {
      if (!AppLifecycleTracker.getInstance().isForeground()) {
        return;
      }
      this.loadStats();
    }, 30000);
  }

  aboutToDisappear(): void {
    if (this.refreshTimer !== -1) {
      clearInterval(this.refreshTimer);
      this.refreshTimer = -1;
    }
    // 释放回调引用，避免计时器继续持有已销毁的页面闭包
    this.focusManager.setOnTick(null);
    this.focusManager.setOnComplete(null);
  }

  /** 从 FocusModeManager 拉取统计摘要并刷新页面状态 */
  private loadStats(): void {
    const stats = this.focusManager.getStats();
    // 与首页 refreshUI 同一口径：统计只在会话切换时变化，
    // 30s 轮询绝大多数时候拿到的是同一组数字，逐项 !== 守卫可避免无谓的状态写入。
    if (this.totalPoints !== stats.totalPoints) {
      this.totalPoints = stats.totalPoints;
    }
    if (this.todaySessions !== stats.todaySessions) {
      this.todaySessions = stats.todaySessions;
    }
    if (this.todayMinutes !== stats.todayMinutes) {
      this.todayMinutes = stats.todayMinutes;
    }
    if (this.longestStreak !== stats.longestStreak) {
      this.longestStreak = stats.longestStreak;
    }
    if (this.currentStreak !== stats.currentStreak) {
      this.currentStreak = stats.currentStreak;
    }
  }

  /** 专注会话完成回调：记录本次积分并展示完成面板 */
  private onSessionComplete(): void {
    const state = this.focusManager.getCurrentState();
    if (state.sessionType === 'focus') {
      this.showCompletion = true;
      this.pointsEarned = this.focusManager.getLastSessionPoints();
      this.loadStats();
    }
    this.isActive = false;
    this.sessionType = state.sessionType;
  }

  /** 秒数格式化为 MM:SS */
  private formatTime(seconds: number): string {
    const mins = Math.floor(seconds / 60);
    const secs = seconds % 60;
    return `${mins.toString().padStart(2, '0')}:${secs.toString().padStart(2, '0')}`;
  }

  /** 进度百分比：空闲态按完成面板/就绪区分，活动态按剩余时长推算 */
  private getProgressPercent(): number {
    if (!this.isActive) {
      // 空闲态：完成面板显示 100%，准备就绪显示 0（不沿用上次会话的过期 duration 数据）
      return this.showCompletion ? 100 : 0;
    }
    const state = this.focusManager.getCurrentState();
    const totalSeconds = state.durationMinutes > 0 ? state.durationMinutes * 60 : this.focusDuration * 60;
    return ((totalSeconds - this.remainingSeconds) / totalSeconds) * 100;
  }

  private getStatusText(): string {
    if (!this.isActive) {
      return '准备就绪';
    }
    if (this.sessionType === 'focus') {
      return '专注中';
    } else if (this.sessionType === 'short_break') {
      return '短休息';
    } else {
      return '长休息';
    }
  }

  private getStatusColor(): string {
    if (!this.isActive) {
      return ThemeColor.systemGray(this.isDarkMode);
    }
    if (this.sessionType === 'focus') {
      return ThemeColor.accentColor(this.accentColorHex, this.isDarkMode);
    } else if (this.sessionType === 'short_break') {
      return ThemeColor.accentGreen(this.isDarkMode);
    } else {
      return ThemeColor.accentIndigo(this.isDarkMode);
    }
  }

  /** 启动一轮专注会话，成功后同步 UI 状态 */
  private startFocus(): void {
    this.showCompletion = false;
    const ok = this.focusManager.startFocusSession(this.focusDuration);
    if (ok) {
      this.isActive = true;
      this.sessionType = 'focus';
      this.remainingSeconds = this.focusDuration * 60;
      this.loadStats();
    }
  }

  /** 选择专注时长并持久化（活动期间不允许修改） */
  private selectFocusDuration(minutes: number): void {
    if (this.isActive) {
      return;
    }
    this.focusDuration = minutes;
    this.focusManager.setFocusDurationMinutes(minutes);
    this.remainingSeconds = minutes * 60;
  }

  /** 开始休息会话（短/长休息由 Manager 按番茄节奏决定），长休息后重置循环 */
  private startBreak(): void {
    const breakType = this.focusManager.getNextBreakType();
    const ok = this.focusManager.startBreak(breakType);
    if (ok) {
      this.isActive = true;
      this.showCompletion = false;
      this.sessionType = breakType === 'long' ? 'long_break' : 'short_break';
      this.remainingSeconds = breakType === 'long' ? LONG_BREAK_MINUTES * 60 : SHORT_BREAK_MINUTES * 60;
      this.loadStats();
      if (breakType === 'long') {
        this.focusManager.resetCycle();
      }
    }
  }

  /** 中断当前会话，撤除相关常驻提醒并回到就绪态 */
  private interruptSession(): void {
    const ok = this.focusManager.interruptSession();
    if (ok) {
      this.isActive = false;
      this.showCompletion = false;
      this.remainingSeconds = this.focusDuration * 60;
      this.sessionType = 'focus';
      this.loadStats();
    }
  }

  build() {
    Stack() {
      // 全局多彩液态渐变背景
      Column().width('100%').height('100%')
        .linearGradient({
          angle: 135,
          colors: ThemeColor.gradient(this.isDarkMode)
        })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      // 随手机姿态变化的环境光晕
      AmbientLight()

      // 可滚动内容：页面可上下滑动，过界带回弹（通过 7.1.1.5.9 滑动过界回弹规则）
      Scroll() {
      Column() {
        // 标题
        Text('专注模式')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor(ThemeColor.label(this.isDarkMode))
          .margin({ top: 60, bottom: 30 })

      // 计时器卡片
      Column() {
        GlassCard() {
          Column() {
            // 状态文本
            Text(this.getStatusText())
              .fontSize(18)
              .fontColor(this.getStatusColor())
              .margin({ bottom: 20 })

            // 倒计时显示：非活动态不再展示一个"看起来在跑、其实没在跑"的大字倒计时。
            // 此前无论空闲还是完成面板都渲染 45:00/00:00 这类占位数字，
            // 用户分不清"这是倒计时归零后的残留"还是"当前计时"。
            // 活动态字号也由 72 降到 64：72pt 在窄屏上会把 4 位以上的剩余时间挤到贴边。
            Text(this.isActive ? this.formatTime(this.remainingSeconds) : this.formatTime(this.focusDuration * 60))
              .fontSize(64)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.isActive ? ThemeColor.label(this.isDarkMode) : ThemeColor.labelSecondary(this.isDarkMode))
              .margin({ bottom: 30 })

            // 进度条：空闲态淡出（此时进度恒为 0 或 100，画一条满/空条纯属噪音）
            Progress({ value: this.getProgressPercent(), total: 100, type: ProgressType.Linear })
              .width('80%')
              .height(8)
              .color(this.getStatusColor())
              .opacity(this.isActive ? 1 : 0.35)
              .margin({ bottom: 30 })

            // 控制按钮
            if (!this.isActive) {
              if (this.showCompletion) {
                // 完成后显示
                Column() {
                  Text('专注完成！')
                    .fontSize(20)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(ThemeColor.accentGreen(this.isDarkMode))
                    .margin({ bottom: 10 })

                  Text(`获得 ${this.pointsEarned} 积分`)
                    .fontSize(16)
                    .fontColor(ThemeColor.systemGray(this.isDarkMode))
                    .margin({ bottom: 20 })

                  this.FocusDurationSelector()

                  Row() {
                    Button('开始休息')
                      .fontSize(16)
                      .backgroundColor(ThemeColor.accentGreenFill(this.isDarkMode))
                      .fontColor(IOS26_WHITE)
                      .borderRadius(22)
                      .width(120)
                      .height(44)
                      .onClick(() => {
                        this.startBreak();
                      })
                      .margin({ right: 10 })

                    Button('继续专注')
                      .fontSize(16)
                      .backgroundColor(ThemeColor.accentColorFill(this.accentColorHex, this.isDarkMode))
                      .fontColor(IOS26_WHITE)
                      .borderRadius(22)
                      .width(120)
                      .height(44)
                      .onClick(() => {
                        this.startFocus();
                      })
                  }
                }
              } else {
                // 初始状态
                Column({ space: 16 }) {
                  this.FocusDurationSelector()

                  Button('开始专注')
                    .fontSize(18)
                    .backgroundColor(ThemeColor.accentColorFill(this.accentColorHex, this.isDarkMode))
                    .fontColor(IOS26_WHITE)
                    .borderRadius(25)
                    .width(200)
                    .height(50)
                    .onClick(() => {
                      this.startFocus();
                    })
                }
              }
            } else {
              // 活动状态
              Row() {
                Button('中断')
                  .fontSize(16)
                  .backgroundColor(ThemeColor.accentRedFill(this.isDarkMode))
                  .fontColor(IOS26_WHITE)
                  .borderRadius(22)
                  .width(120)
                  .height(44)
                  .onClick(() => {
                    this.interruptSession();
                  })
              }
            }
          }
          .width('100%')
          .padding(30)
        }
      }
      .width('90%')
      .margin({ bottom: 30 })

      // 统计数据
      Column() {
        GlassCard() {
          Column() {
            Text('我的专注统计')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor(ThemeColor.label(this.isDarkMode))
              .margin({ bottom: 20 })

            Row() {
              this.StatTotalPoints()
              this.StatTodaySessions()
              this.StatTodayMinutes()
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceAround)

            Row() {
              this.StatCurrentStreak()
              this.StatLongestStreak()
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceAround)
            .margin({ top: 15 })
          }
          .width('100%')
          .padding(20)
        }
      }
      .width('90%')
    }
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
  }

  /**
   * 专注统计的五个数值块。
   *
   * 刻意拆成五个无参 @Builder，而不是原先的 `StatItem(label, value)`：ArkUI **不追踪
   * @Builder 参数里的状态依赖**，`Text(value)` 渲染的是调用处算好并按值传入的字符串，
   * 于是五个数字只在首次渲染时取值，完成一场专注后 totalPoints / todaySessions /
   * todayMinutes / currentStreak 全部不会更新（loadStats 的 !== 守卫确实在写 @State，
   * 但没人重新渲染）。与 `Index` 的 StatLimit/StatUsed/StatStreak 属同一类缺陷，
   * 2026-10-07 在首页实机取证。
   *
   * 代价是五行结构重复——这正是"不复用 @Builder"的必要成本：任何一层把 value/label
   * 作为参数传下去，冻结就会原样复现。五个 @State 均在**体内**读取，依赖才会被登记。
   */
  @Builder
  StatTotalPoints() {
    Column() {
      Text(this.totalPoints.toString())
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
        .fontColor(ThemeColor.accentColor(this.accentColorHex, this.isDarkMode))

      Text('总积分')
        .fontSize(12)
        .fontColor(ThemeColor.systemGray(this.isDarkMode))
        .margin({ top: 5 })
    }
  }

  @Builder
  StatTodaySessions() {
    Column() {
      Text(this.todaySessions.toString())
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
        .fontColor(ThemeColor.accentColor(this.accentColorHex, this.isDarkMode))

      Text('今日次数')
        .fontSize(12)
        .fontColor(ThemeColor.systemGray(this.isDarkMode))
        .margin({ top: 5 })
    }
  }

  @Builder
  StatTodayMinutes() {
    Column() {
      Text(`${this.todayMinutes}分`)
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
        .fontColor(ThemeColor.accentColor(this.accentColorHex, this.isDarkMode))

      Text('今日时长')
        .fontSize(12)
        .fontColor(ThemeColor.systemGray(this.isDarkMode))
        .margin({ top: 5 })
    }
  }

  @Builder
  StatCurrentStreak() {
    Column() {
      Text(this.currentStreak.toString())
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
        .fontColor(ThemeColor.accentColor(this.accentColorHex, this.isDarkMode))

      Text('当前连续')
        .fontSize(12)
        .fontColor(ThemeColor.systemGray(this.isDarkMode))
        .margin({ top: 5 })
    }
  }

  @Builder
  StatLongestStreak() {
    Column() {
      Text(this.longestStreak.toString())
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
        .fontColor(ThemeColor.accentColor(this.accentColorHex, this.isDarkMode))

      Text('最长连续')
        .fontSize(12)
        .fontColor(ThemeColor.systemGray(this.isDarkMode))
        .margin({ top: 5 })
    }
  }

  @Builder
  FocusDurationSelector() {
    Column({ space: 8 }) {
      Text('专注时长').fontSize(13).fontColor(ThemeColor.systemGray(this.isDarkMode))
      Row({ space: 10 }) {
        ForEach(this.focusDurations, (minutes: number) => {
          Text(minutes + '分')
            .fontSize(14)
            .fontColor(this.focusDuration === minutes ? IOS26_WHITE : ThemeColor.label(this.isDarkMode))
            .backgroundColor(this.focusDuration === minutes ? ThemeColor.accentColorFill(this.accentColorHex, this.isDarkMode) : ThemeColor.glassBg(this.isDarkMode))
            .borderRadius(16)
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .onClick(() => {
              this.selectFocusDuration(minutes);
            })
            // 无障碍：这 4 枚 chip 是纯 Text 伪按钮。本文件此前 accessibilityText /
            // accessibilityLevel 均为 0，读屏只能把它们当静态文本念"15分/25分/…"，
            // 无法聚焦、无法激活，也听不出当前选中的是哪一个。
            // 做法照抄 HealthReminderControl 星期 chip 的既有约定。
            .accessibilityLevel('yes')
            .accessibilityText(`专注时长 ${minutes} 分钟${this.focusDuration === minutes ? '，已选择' : ''}`)
            .accessibilitySelected(this.focusDuration === minutes)
        }, (minutes: number) => minutes.toString())
      }
    }
  }
}
