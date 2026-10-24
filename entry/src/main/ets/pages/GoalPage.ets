import { formatError } from '../models/ErrUtils';
import { hilog } from '@kit.PerformanceAnalysisKit';
/**
 * 每日目标 / 打卡页面
 * 接通 DailyGoalManager 全部打卡与目标能力：
 * - 连续打卡天数、今日打卡状态、每日语录、鼓励语
 * - 内置目标自动追踪（解锁/专注/使用时长），自定义目标手动标记完成
 * - 添加/删除自定义目标、打卡历史
 */
import { DailyGoalManager, DailyGoal, DailyCheckin, CustomGoalDef } from '../managers/DailyGoalManager';
import { showToastSafe } from '../models/UiUtils';
import { GlassCard } from '../components/GlassCard';
import { DialogShell } from '../components/DialogShell';
import { AmbientLight } from '../components/AmbientLight';
import {
  IOS26_WHITE,
  ThemeColor
} from '../components/iOS26Theme';

@Entry
@Component
struct GoalPage {
  /** 用户强调色（跟随设置页「强调色」选择，全应用一致） */
  @StorageLink('accentColorHex') accentColorHex: string = '#0066CC';
  @State goals: DailyGoal[] = [];
  @State streak: number = 0;
  @State todayCheckin: DailyCheckin | null = null;
  @State quote: string = '';
  @State encouragement: string = '';
  @State history: DailyCheckin[] = [];
  @State cardOpacity: number = 0;
  @State cardY: number = 30;
  @StorageProp('isDarkMode') isDarkMode: boolean = false;

  @State showAddGoal: boolean = false;
  @State showDeleteConfirm: boolean = false;
  @State showTemplateDialog: boolean = false;
  @State pendingDeleteId: string = '';
  @State pendingDeleteName: string = '';
  @State hasYesterdaySnapshot: boolean = false;

  @State newGoalName: string = '';
  @State newGoalDescription: string = '';
  @State newGoalTarget: string = '';
  @State newGoalUnit: string = '';

  private goalManager: DailyGoalManager = DailyGoalManager.getInstance();
  /** 入场动画定时器句柄（页面消失时清理，避免重复进入时动画叠加打架） */
  private entranceTimerId: number = -1;

  aboutToAppear(): void {
    this.quote = this.goalManager.getMotivationalQuote();
    this.encouragement = this.goalManager.getEncouragingMessage();
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

  /** 页面数据刷新：先按今日真实统计重推导内置目标，再读取全部展示数据 */
  private loadData(): void {
    // 先用今日真实统计重推导内置目标，再读取展示
    this.goalManager.updateGoalProgress();
    this.goals = this.goalManager.getAllGoals();
    this.streak = this.goalManager.getCurrentStreak();
    this.todayCheckin = this.goalManager.getTodayCheckin();
    this.history = this.goalManager.getCheckinHistory().reverse();
    // 检查是否有昨日自定义目标快照可供复制
    this.hasYesterdaySnapshot = this.goalManager.hasYesterdaySnapshot();
  }

  /** 今日是否已打卡（存在今日打卡记录） */
  private getCheckedInToday(): boolean {
    return this.todayCheckin !== null;
  }

  /** 已完成目标数；一次渲染内被调用 3 次（概览/ 卡标题 / 卡副标题判定），
   * 原 filter() 每次都生成一份完整数组 → 单次渲染 3 个多余数组，改为零分配单趟计数 */
  private getCompletedCount(): number {
    let count = 0;
    for (let i = 0; i < this.goals.length; i++) {
      if (this.goals[i].completed) {
        count++;
      }
    }
    return count;
  }

  /** 单条目标进度百分比（0~100），target 非法时返回 0 */
  private getGoalProgressPercent(goal: DailyGoal): number {
    if (goal.target <= 0) {
      return 0;
    }
    return Math.min(100, (goal.current / goal.target) * 100);
  }

  /** 进度条颜色：已完成绿，进行中蓝 */
  private getProgressColor(goal: DailyGoal): string {
    return goal.completed ? ThemeColor.accentGreen(this.isDarkMode) : ThemeColor.accentColor(this.accentColorHex, this.isDarkMode);
  }

  /** 是否为自定义目标（可手动完成/删除） */
  private isCustom(goal: DailyGoal): boolean {
    return goal.checkType === 'custom';
  }

  /**
   * 目标列表摘要文案。
   *
   * ⚠️ 鼓励语池（`DailyGoalManager.encouragingMessages`）是**破戒时的引导语**，
   * 情绪偏重（「失败不是终点，放弃才是。」）。首次打开该页时 0 个目标完成，
   * 此时展示这类文案等于一上来就否定用户，与"今日目标"的激励语境冲突。
   * 故按完成度分档：全部完成 → 完成语；**一个都没完成 → 中性引导**；部分完成 → 鼓励语。
   */
  private getGoalSummaryText(): string {
    const completed = this.getCompletedCount();
    if (this.goals.length > 0 && completed === this.goals.length) {
      return '全部目标已完成，继续保持！';
    }
    if (completed === 0) {
      return '完成任意一个目标即可开始累计连续打卡';
    }
    return this.encouragement;
  }

  /** 今日打卡：已打过则忽略；成功提示连续天数，失败提示先完成目标 */
  private onCheckin(): void {
    if (this.getCheckedInToday()) {
      return;
    }
    const ok = this.goalManager.checkin();
    if (ok) {
      this.showToast(`打卡成功，连续 ${this.goalManager.getCurrentStreak()} 天`);
    } else {
      this.showToast('今日还没有完成的目标，先完成一个目标吧');
    }
    this.loadData();
  }

  /** 切换自定义目标完成态，成功后刷新列表 */
  private onToggleCustom(goal: DailyGoal): void {
    if (this.goalManager.toggleCustomGoalDone(goal.id)) {
      this.loadData();
    }
  }

  /** 打开添加目标弹窗并清空表单 */
  private openAddGoal(): void {
    this.newGoalName = '';
    this.newGoalDescription = '';
    this.newGoalTarget = '';
    this.newGoalUnit = '';
    this.showAddGoal = true;
  }

  /** 确认添加自定义目标：校验名称/数值后构造 DailyGoal 落库 */
  private confirmAddGoal(): void {
    const name = this.newGoalName.trim();
    const target = Number(this.newGoalTarget);
    if (name.length === 0) {
      this.showToast('请输入目标名称');
      return;
    }
    if (!Number.isFinite(target) || target <= 0) {
      this.showToast('请输入有效的目标数值');
      return;
    }
    const description = this.newGoalDescription.trim();
    const unit = this.newGoalUnit.trim();
    const goal: DailyGoal = {
      id: 'custom_' + Date.now() + '_' + this.goals.length,
      name: name,
      description: description.length > 0 ? description : '自定义目标',
      target: target,
      current: 0,
      unit: unit.length > 0 ? unit : '次',
      checkType: 'custom',
      completed: false
    };
    this.goalManager.addCustomGoal(goal);
    this.showAddGoal = false;
    this.showToast('已添加目标');
    this.loadData();
  }

  /** 请求删除目标：记录待删项并弹出确认框 */
  private requestDeleteGoal(goal: DailyGoal): void {
    this.pendingDeleteId = goal.id;
    this.pendingDeleteName = goal.name;
    this.showDeleteConfirm = true;
  }

  /** 确认删除待删目标并关闭弹窗 */
  private confirmDeleteGoal(): void {
    if (this.pendingDeleteId.length > 0) {
      this.goalManager.removeGoal(this.pendingDeleteId);
      this.showToast('已删除目标');
    }
    this.pendingDeleteId = '';
    this.pendingDeleteName = '';
    this.showDeleteConfirm = false;
    this.loadData();
  }

  /** 打卡历史日期 "YYYY-MM-DD" 格式化为 "X月X日" */
  private formatHistoryDate(dateStr: string): string {
    const parts = dateStr.split('-');
    if (parts.length === 3) {
      return `${Number(parts[1])}月${Number(parts[2])}日`;
    }
    return dateStr;
  }

  private showToast(message: string): void {
    showToastSafe(this.getUIContext(), 'GoalPage', 'GoalPage', message);
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 全局多彩液态渐变背景
      // ⚠️ 必须挂 expandSafeArea：根 Stack 上的 expandSafeArea 只让**容器**延伸进安全区，
      // 子组件仍被裁在安全区内，于是状态栏/导航条区域会露出根 Stack 的默认白底，
      // 形成一条明显的白带（实机截图取证）。首页正常是因为它的渐变 Column 单独挂了这一行。
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
              hilog.error(0x0000, 'GoalPage', '%{public}s', '返回失败: ' + formatError(err));
            }
          })

          Text('每日目标')
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
            // 打卡状态卡片
            GlassCard({
              delay: 0,
              cardOpacity: this.cardOpacity,
              cardTranslateY: this.cardY,
              cardWidth: '90%',
              cardMargin: { top: 8 }
            }) {
              Row() {
                Column({ space: 4 }) {
                  Text('连续打卡').fontSize(13).fontColor(ThemeColor.systemGray(this.isDarkMode))
                  Row({ space: 6 }) {
                    Text(`${this.streak}`)
                      .fontSize(40).fontWeight(FontWeight.Bold).fontColor(ThemeColor.accentColor(this.accentColorHex, this.isDarkMode))
                    Text('天').fontSize(15).fontColor(ThemeColor.labelSecondary(this.isDarkMode))
                  }
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Column({ space: 10 }) {
                  Text(this.getCheckedInToday() ? '今日已打卡' : '今日未打卡')
                    .fontSize(13).fontColor(this.getCheckedInToday() ? ThemeColor.accentGreen(this.isDarkMode) : ThemeColor.systemGray(this.isDarkMode))
                  Button(this.getCheckedInToday() ? '✓ 已打卡' : '今日打卡')
                    .fontSize(14)
                    .fontColor(IOS26_WHITE)
                    .backgroundColor(this.getCheckedInToday() ? ThemeColor.accentGreenFill(this.isDarkMode) : ThemeColor.accentColorFill(this.accentColorHex, this.isDarkMode))
                    .height(40)
                    .borderRadius(20)
                    .padding({ left: 20, right: 20 })
                    .enabled(!this.getCheckedInToday())
                    .onClick(() => { this.onCheckin(); })
                  // 未打卡时说明门槛：此前按钮灰/蓝都点不动（需先完成一个目标），
                  // 但页面不告诉用户为什么，点了只会弹一句 toast。
                  // 直接把门槛写在按钮下方，省掉一次"点了才知道"的往返。
                  if (!this.getCheckedInToday() && this.goals.length > 0 && this.getCompletedCount() === 0) {
                    Text('完成任一目标后可打卡')
                      .fontSize(11)
                      .fontColor(ThemeColor.systemGray(this.isDarkMode))
                      .maxLines(1)
                  }
                }
                .alignItems(HorizontalAlign.End)
              }
              .width('100%')
              .padding(20)
            }

            // 每日语录
            GlassCard({
              delay: 100,
              cardOpacity: this.cardOpacity,
              cardTranslateY: this.cardY,
              cardWidth: '90%'
            }) {
              Column({ space: 8 }) {
                Text('今日语录').fontSize(13).fontColor(ThemeColor.systemGray(this.isDarkMode))
                Text(this.quote)
                  .fontSize(15).fontColor(ThemeColor.label(this.isDarkMode)).lineHeight(22)
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding(20)
            }

            // 今日目标列表
            GlassCard({
              delay: 200,
              cardOpacity: this.cardOpacity,
              cardTranslateY: this.cardY,
              cardWidth: '90%'
            }) {
              Column({ space: 12 }) {
                Row() {
                  Column({ space: 4 }) {
                    Text('今日目标').fontSize(17).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
                    Text(this.getGoalSummaryText())
                      .fontSize(12).fontColor(ThemeColor.labelSecondary(this.isDarkMode))
                      // 未全部完成时返回 DailyGoalManager 的内置鼓励语（30+ 字），
                      // 右侧是固定宽度的"完成 x/y"，不截断会换行把整卡撑高
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)

                  Text(`完成 ${this.getCompletedCount()}/${this.goals.length}`)
                    .fontSize(13).fontColor(this.getCompletedCount() === this.goals.length && this.goals.length > 0
                      ? ThemeColor.accentGreen(this.isDarkMode) : ThemeColor.systemGray(this.isDarkMode))
                }
                .width('100%')

                // 快捷操作：复制昨日 / 使用模板
                Row({ space: 8 }) {
                  Button(this.hasYesterdaySnapshot ? '复制昨日目标' : '无昨日目标')
                    .fontSize(12)
                    .fontColor(this.hasYesterdaySnapshot ? IOS26_WHITE : ThemeColor.systemGray(this.isDarkMode))
                    .backgroundColor(this.hasYesterdaySnapshot ? ThemeColor.accentColorFill(this.accentColorHex, this.isDarkMode) : ThemeColor.inputBg(this.isDarkMode))
                    .borderRadius(16)
                    .padding({ left: 12, right: 12 })
                    .height(32)
                    .enabled(this.hasYesterdaySnapshot)
                    .onClick(() => {
                      const ok = this.goalManager.copyYesterdayCustomGoals();
                      if (ok) {
                        this.showToast('已从昨日恢复自定义目标');
                        this.loadData();
                      } else {
                        this.showToast('没有可用的昨日目标');
                      }
                    })
                  Button('使用模板')
                    .fontSize(12)
                    .fontColor(IOS26_WHITE)
                    .backgroundColor(ThemeColor.accentColorFill(this.accentColorHex, this.isDarkMode))
                    .borderRadius(16)
                    .padding({ left: 12, right: 12 })
                    .height(32)
                    .onClick(() => {
                      this.showTemplateDialog = true;
                    })
                }
                .width('100%')

                ForEach(this.goals, (goal: DailyGoal) => {
                  Column({ space: 8 }) {
                    Row() {
                      Text(goal.completed ? '✓' : '○')
                        .fontSize(18)
                        .fontColor(goal.completed ? ThemeColor.accentGreen(this.isDarkMode) : ThemeColor.systemGray(this.isDarkMode))

                      Column({ space: 2 }) {
                        Text(goal.name)
                          .fontSize(15).fontWeight(FontWeight.Medium)
                          .fontColor(goal.completed ? ThemeColor.labelSecondary(this.isDarkMode) : ThemeColor.label(this.isDarkMode))
                          // 自定义目标名上限 20 字（AddGoalDialog 的 maxLength），
                          // 同一行右侧还有「完成」按钮 + ✕ 两个固定宽度元素；
                          // 不截断则长名换行会撑高整行，使左侧 ✓/○ 与下方进度条偏离视觉中线
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                        Text(goal.description)
                          .fontSize(12).fontColor(ThemeColor.systemGray(this.isDarkMode))
                          // 描述上限 50 字，同处被挤压的 layoutWeight(1) Column 内，
                          // 最坏可换 4 行；限 2 行兼顾可读与卡高稳定
                          .maxLines(2)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                      }
                      .layoutWeight(1)
                      .alignItems(HorizontalAlign.Start)
                      .margin({ left: 8 })

                      if (this.isCustom(goal)) {
                        Button(goal.completed ? '取消' : '完成')
                          .fontSize(12)
                          .fontColor(goal.completed ? ThemeColor.accentColor(this.accentColorHex, this.isDarkMode) : IOS26_WHITE)
                          .backgroundColor(goal.completed ? ThemeColor.accentTint('0,122,255', 0.12, this.isDarkMode) : ThemeColor.accentColorFill(this.accentColorHex, this.isDarkMode))
                          .height(32)
                          .borderRadius(16)
                          .padding({ left: 12, right: 12 })
                          // 无障碍：多个自定义目标并存时，通用的"完成/取消"文案会让读屏
                          // 连续播报 N 次"完成"而无法区分，必须带上目标名
                          .accessibilityText(`${goal.completed ? '取消完成' : '标记完成'}目标 ${goal.name}`)
                          .onClick(() => { this.onToggleCustom(goal); })

                        Text('✕')
                          .fontSize(16).fontColor(ThemeColor.systemGray(this.isDarkMode))
                          .width(32).height(32).textAlign(TextAlign.Center)
                          .onClick(() => { this.requestDeleteGoal(goal); })
                          .accessibilityText(`删除目标 ${goal.name}`)
                          .accessibilityLevel('yes')
                      }
                    }
                    .width('100%')

                    Stack({ alignContent: Alignment.Start }) {
                      Row().width('100%').height(6).borderRadius(3).backgroundColor(ThemeColor.fill(this.isDarkMode))
                      Row().width(this.getGoalProgressPercent(goal) + '%').height(6).borderRadius(3)
                        .backgroundColor(this.getProgressColor(goal))
                    }
.width('100%').height(6)
                    // 无障碍：进度条是无文本的视觉元素，读屏只会播裸百分数，
                    // 且听不出属于哪个目标——带上目标名
                    .accessibilityLevel('yes')
                    .accessibilityText(`${goal.name} 进度 ${Math.round(this.getGoalProgressPercent(goal))}%`)

                    Row() {
                      Text(`${goal.current} / ${goal.target} ${goal.unit}`)
                        .fontSize(11).fontColor(ThemeColor.labelSecondary(this.isDarkMode))
                      Blank()
                      Text(goal.completed ? '已完成' : '进行中')
                        .fontSize(11).fontColor(goal.completed ? ThemeColor.accentGreen(this.isDarkMode) : ThemeColor.accentColor(this.accentColorHex, this.isDarkMode))
                    }
                    .width('100%')

                    Divider().color(ThemeColor.accentTint('60,60,67', 0.08, this.isDarkMode)).margin({ top: 4 })
                  }
                  .width('100%')
                }, (goal: DailyGoal) => goal.id + '_' + goal.current + '_' + (goal.completed ? '1' : '0'))

                Button('+ 添加自定义目标')
                  .fontSize(14)
                  .fontColor(ThemeColor.accentColor(this.accentColorHex, this.isDarkMode))
                  .backgroundColor(ThemeColor.accentTint('0,122,255', 0.08, this.isDarkMode))
                  .height(44)
                  .width('100%')
                  .borderRadius(22)
                  .onClick(() => { this.openAddGoal(); })
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding(20)
            }

            // 打卡历史
            GlassCard({
              delay: 300,
              cardOpacity: this.cardOpacity,
              cardTranslateY: this.cardY,
              cardWidth: '90%'
            }) {
              Column({ space: 10 }) {
                Text('打卡历史').fontSize(17).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))

                if (this.history.length === 0) {
                  // 空态给一个可执行的下一步，而不是只说"没有数据"：
                  // 用户第一次进来看见这句话，并不知道该去上面完成一个目标
                  Column({ space: 6 }) {
                    Text('还没有打卡记录')
                      .fontSize(13).fontColor(ThemeColor.systemGray(this.isDarkMode))
                    Text('完成一个今日目标后即可打卡')
                      .fontSize(11).fontColor(ThemeColor.systemGray(this.isDarkMode))
                  }
                  .width('100%')
                  .alignItems(HorizontalAlign.Start)
                  .padding({ top: 8, bottom: 8 })
                } else {
                  ForEach(this.history, (entry: DailyCheckin) => {
                    Row() {
                      Text(this.formatHistoryDate(entry.date))
                        .fontSize(14).fontColor(ThemeColor.label(this.isDarkMode))
                      Blank()
                      Text(`完成 ${entry.completedGoals.length}/${entry.totalGoals}`)
                        .fontSize(12).fontColor(ThemeColor.labelSecondary(this.isDarkMode))
                      Text(`连续 ${entry.streak} 天`)
                        .fontSize(12).fontWeight(FontWeight.Medium)
                        .fontColor(entry.streak > 0 ? ThemeColor.accentGreen(this.isDarkMode) : ThemeColor.systemGray(this.isDarkMode))
                    }
                    .width('100%')
                    .padding({ top: 6, bottom: 6 })
                  }, (entry: DailyCheckin) => entry.date)
                }
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
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

      // 添加自定义目标弹窗
      //
      // ⚠️ 直接在 build() 里调 DialogShell（尾随插槽），不要经由中间的 @Builder
      // + `content: this.xxxForm` 按值传参：按值传给 `@BuilderParam` 的 builder 执行时
      // `this` **不是**本组件，`deleteGoalForm` 里的 `「${this.pendingDeleteName}」`
      // 会渲染成 `「undefined」`。实机崩溃证据见 Settings.ets 文件头 timePickerTitleFor() 注释。
      if (this.showAddGoal) {
        DialogShell({ onDismiss: () => { this.showAddGoal = false; } }) {
          this.addGoalForm()
        }
      }

      // 删除确认弹窗
      if (this.showDeleteConfirm) {
        DialogShell({ onDismiss: () => { this.showDeleteConfirm = false; } }) {
          this.deleteGoalForm()
        }
      }

      // 使用模板弹窗
      if (this.showTemplateDialog) {
        DialogShell({ onDismiss: () => { this.showTemplateDialog = false; } }) {
          this.templateForm()
        }
      }
    }
    .width('100%')
    .height('100%')
    // 内容延伸进顶部安全区：内层 Scroll 上的 expandSafeArea 会被这层 Column 裁掉
    // （实机 dump：Scroll 恒为 y=535，页面顶部 137px 被系统状态栏区域占成黑带）。
    // 必须加在根 Stack 才生效 —— 与 Index.ets build() 的根 Stack 同理。
    // 标题行自带 margin({top:50}) 补偿状态栏高度，延伸后仍保持视觉位置不变。
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /** 「添加自定义目标」弹窗的内容（外壳见 build() 里的尾随插槽调用） */
  @Builder
  addGoalForm() {
    Scroll() {
      Column({ space: 14 }) {
        Text('添加自定义目标')
          .fontSize(17).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))

        TextInput({ placeholder: '目标名称，如「喝水」', text: $$this.newGoalName })
          .fontSize(14).fontColor(ThemeColor.label(this.isDarkMode)).height(40).width('100%')
          .borderRadius(8).backgroundColor(ThemeColor.accentTint('0,122,255', 0.05, this.isDarkMode))
          .maxLength(20).accessibilityText('目标名称')

        TextInput({ placeholder: '目标描述（可选）', text: $$this.newGoalDescription })
          .fontSize(14).fontColor(ThemeColor.label(this.isDarkMode)).height(40).width('100%')
          .borderRadius(8).backgroundColor(ThemeColor.accentTint('0,122,255', 0.05, this.isDarkMode))
          .maxLength(50).accessibilityText('目标描述，可选')

        Row({ space: 10 }) {
          TextInput({ placeholder: '目标数值', text: $$this.newGoalTarget })
            .type(InputType.Number)
            .fontSize(14).fontColor(ThemeColor.label(this.isDarkMode)).height(40)
            .layoutWeight(1)
            .borderRadius(8).backgroundColor(ThemeColor.accentTint('0,122,255', 0.05, this.isDarkMode))
            .maxLength(6).accessibilityText('目标数值')

          TextInput({ placeholder: '单位（次/分钟）', text: $$this.newGoalUnit })
            .fontSize(14).fontColor(ThemeColor.label(this.isDarkMode)).height(40)
            .layoutWeight(1)
            .borderRadius(8).backgroundColor(ThemeColor.accentTint('0,122,255', 0.05, this.isDarkMode))
            .maxLength(6).accessibilityText('单位')
        }
        .width('100%')

        Row({ space: 12 }) {
          Button('取消')
            .fontSize(15).fontColor(ThemeColor.systemGray(this.isDarkMode))
            .backgroundColor(ThemeColor.inputBg(this.isDarkMode))
            .layoutWeight(1)
            .onClick(() => { this.showAddGoal = false; })

          Button('添加')
            .fontSize(15).fontColor(IOS26_WHITE)
            .backgroundColor(ThemeColor.accentColorFill(this.accentColorHex, this.isDarkMode))
            .layoutWeight(1)
            .onClick(() => { this.confirmAddGoal(); })
        }
        .width('100%')
      }
    }
    // 限高 + 可滚动：键盘弹起（ArkUI 默认 OFFSET 避让会上移页面）压缩可用高度后，
    // 4 个输入框 + 按钮行仍可完整访问，不会被裁切
    .constraintSize({ maxHeight: '80%' })
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  /** 「删除目标」确认弹窗的内容（外壳见 build() 里的尾随插槽调用） */
  @Builder
  deleteGoalForm() {
    Column({ space: 16 }) {
      Text('删除目标')
        .fontSize(17).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))

      Text(`「${this.pendingDeleteName}」删除后无法恢复。`)
        .fontSize(13).fontColor(ThemeColor.systemGray(this.isDarkMode))
        .textAlign(TextAlign.Start)

      Row({ space: 12 }) {
        Button('取消')
          .fontSize(15).fontColor(ThemeColor.systemGray(this.isDarkMode))
          .backgroundColor(ThemeColor.inputBg(this.isDarkMode))
          .layoutWeight(1)
          .onClick(() => { this.showDeleteConfirm = false; })

        Button('删除')
          .fontSize(15).fontColor(IOS26_WHITE)
          .backgroundColor(ThemeColor.accentRedFill(this.isDarkMode))
          .layoutWeight(1)
          .onClick(() => { this.confirmDeleteGoal(); })
      }
      .width('100%')
    }
  }

  /** 「使用模板」弹窗的内容：列出常用目标模板，点击添加 */
  @Builder
  templateForm() {
    Column({ space: 14 }) {
      Text('选择目标模板')
        .fontSize(17).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
      Text('模板添加后可在列表中修改名称、数值与单位')
        .fontSize(12).fontColor(ThemeColor.labelSecondary(this.isDarkMode))

      ForEach(this.goalManager.getGoalTemplates(), (t: CustomGoalDef, index: number) => {
        Row() {
          Column({ space: 4 }) {
            Text(t.name).fontSize(15).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
            Text(t.description).fontSize(11).fontColor(ThemeColor.labelSecondary(this.isDarkMode))
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Text(`${t.target}${t.unit}`)
            .fontSize(13).fontColor(ThemeColor.accentColor(this.accentColorHex, this.isDarkMode))
            .fontWeight(FontWeight.Medium)
        }
        .width('100%')
        .padding({ top: 8, bottom: 8 })
        .onClick(() => {
          const ok = this.goalManager.addGoalFromTemplate(index);
          if (ok) {
            this.showToast('已添加模板目标');
            this.showTemplateDialog = false;
            this.loadData();
          } else {
            this.showToast('该目标已存在');
          }
        })
      }, (t: CustomGoalDef, index: number) => `template_${index}_${t.name}`)

      Button('取消')
        .fontSize(15).fontColor(ThemeColor.systemGray(this.isDarkMode))
        .backgroundColor(ThemeColor.inputBg(this.isDarkMode))
        .width('100%')
        .height(44)
        .borderRadius(22)
        .onClick(() => { this.showTemplateDialog = false; })
    }
    .width('100%')
    .padding(20)
  }
}
