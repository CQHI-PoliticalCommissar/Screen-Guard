// 删除错误的导入（FlexDirection 等为全局可用，无需导入）
// import { FlexDirection, FlexWrap, FlexAlign } from '@ohos.multimodalInput';

import {
  IOS26_BLUE,
  IOS26_GREEN,
  IOS26_WHITE,
  ThemeColor
} from './iOS26Theme';
import { ALL_WEEKDAYS, WEEKDAY_LABELS, formatHourMinute } from '../models/HealthTypes';

/**
 * 健康提醒配置控件（设置页 · 健康提醒卡片内部复用）
 * 支持：开关 / 间隔选择 / 自定义间隔 / 起止时段 / 星期重复 / 提醒标题与内容 / 删除（可选）
 * 展开状态跟随开关：开启时自动展开，收起折叠仅显示标题行
 * 说明：本地编辑态（intervalInput/localTitle/localContent）与父数据通过 @Watch 双向同步，
 *       输入内容在提交（onSubmit/onBlur）时才回写父组件
 */
@Component
export struct HealthReminderControl {
  /** 提醒名称（如：久坐提醒） */
  @Prop title: string = '';
  /** 提醒副标题（如：每 60 分钟提醒一次） */
  @Prop subtitle: string = '';

  // 1. 重命名 enabled → isEnabled（避免与基类方法冲突）
  @Prop @Watch('onEnabledChange') isEnabled: boolean = false;
  /**
   * 父级强制重同步令牌：父级值与 isEnabled 相同时 @Prop 不会下发，开关会停在用户拨上的状态。
   * 父级自增该字段即触发重新读取 isEnabled 完成拉回。
   */
  @Prop @Watch('onToggleRevisionChange') toggleRevision: number = 0;
  // 2. 函数型属性移除 @Prop
  onToggle: (enabled: boolean) => void = () => {};
  onDelete: (() => void) | undefined = undefined;

  /** 可选间隔选项（分钟数组，渲染为 chip 按钮） */
  @Prop intervalOptions: number[] = [];
  @Prop @Watch('onIntervalChange') selectedInterval: number = 0;
  onSelectInterval: (interval: number) => void = () => {};
  onApplyCustomInterval: (minutes: number) => void = () => {};

  /** 提醒活跃时段：起始时间（时/分） */
  @Prop startHour: number = 0;
  @Prop startMinute: number = 0;
  /** 提醒活跃时段：结束时间（时/分） */
  @Prop endHour: number = 0;
  @Prop endMinute: number = 0;
  onOpenStart: () => void = () => {};
  onOpenEnd: () => void = () => {};

  /** 重复星期集合（0 = 周日 ... 6 = 周六） */
  @Prop weekdays: number[] = [];
  onToggleWeekday: (day: number) => void = () => {};

  /** 自定义提醒标题 / 内容（留空使用默认文案） */
  @Prop @Watch('onTitleChange') customTitle: string = '';
  @Prop @Watch('onContentChange') customContent: string = '';
  onChangeTitle: (value: string) => void = () => {};
  onChangeContent: (value: string) => void = () => {};

  /** 主题强调色（区分不同提醒类型） */
  @Prop accentColor: string = IOS26_BLUE;
  // 注：边框色一律由 accentColor + 暗色模式推算（见 getBorderColor），不做外部注入——
  // 原先有个 borderColorValue @Prop，但 Settings 的 4 个调用点无一传入，是恒假的死分支。

  /** 自定义间隔输入框文本 */
  @State intervalInput: string = '';
  /** 本地编辑中的标题（提交时回写父组件） */
  @State localTitle: string = '';
  /** 本地编辑中的内容（提交时回写父组件） */
  @State localContent: string = '';
  /** 是否展开显示详细配置 */
  @State isExpanded: boolean = false;
  /** 本地开关状态（Tween 双向绑定，@Watch 从父数据同步） */
  @State isOnState: boolean = false;
  /** 暗色模式标记 */
  @StorageProp('isDarkMode') isDarkMode: boolean = false;

  // @Watch：父组件数据变化时重同步本地状态，避免“数据更新 UI 不更新”
  private onEnabledChange(): void {
    this.isOnState = this.isEnabled;
  }

/**
   * 父级强制拉回（发布失败或权限被拒的回滚路径）：
   * 重新读取 isEnabled，并同步收起配置面板——回滚后提醒为关闭态，面板不应残留展开。
   */
  private onToggleRevisionChange(): void {
    this.isOnState = this.isEnabled;
    this.isExpanded = this.isEnabled;
  }

  private onIntervalChange(): void {
    this.intervalInput = this.selectedInterval.toString();
  }

  private onTitleChange(): void {
    this.localTitle = this.customTitle;
  }

  private onContentChange(): void {
    this.localContent = this.customContent;
  }

  aboutToAppear(): void {
    this.intervalInput = this.selectedInterval.toString();
    this.localTitle = this.customTitle;
    this.localContent = this.customContent;
    this.isExpanded = this.isEnabled;
    this.isOnState = this.isEnabled;
  }

  /** 展开 / 折叠详细配置 */
  private toggleExpand(): void {
    this.isExpanded = !this.isExpanded;
  }

  private getDayLabel(day: number): string {
    return WEEKDAY_LABELS[day];
  }

  /** 选中预置间隔（同步输入框文案并回调父组件） */
  private handleSelectInterval(interval: number): void {
    this.intervalInput = interval.toString();
    this.onSelectInterval(interval);
  }

  /** 应用自定义间隔：仅接受 1~720 的整数分钟，非法输入回退为当前选中值 */
  private applyCustomInterval(): void {
    const n = Number(this.intervalInput);
    if (n >= 1 && n <= 720 && Math.floor(n) === n) {
      this.onApplyCustomInterval(n);
    } else {
      this.intervalInput = this.selectedInterval.toString();
    }
  }

  /** 标题变更时提交到父组件（仅在确有变化时回调） */
  private commitTitle(): void {
    if (this.localTitle !== this.customTitle) {
      this.onChangeTitle(this.localTitle);
    }
  }

  /** 内容变更时提交到父组件（仅在确有变化时回调） */
  private commitContent(): void {
    if (this.localContent !== this.customContent) {
      this.onChangeContent(this.localContent);
    }
  }

  build() {
    Column() {
      Row() {
        Column({ space: 2 }) {
          Text(this.title)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemeColor.label(this.isDarkMode))
            // 单行省略：标题行右侧挤着 32vp 删除 + 32vp 箭头 + Toggle，
            // 长名称换行会把行撑高并使 Toggle 偏离视觉中线
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.subtitle)
            .fontSize(11)
            .fontColor(ThemeColor.systemGray(this.isDarkMode))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)

        if (this.onDelete !== undefined) {
          // 显式 32×32：字号仅 12，原本隐式热区约 24×18vp，低于可点热区阈值
          Text('删除')
            .fontSize(12)
            .fontColor(ThemeColor.accentRed(this.isDarkMode))
            .width(32)
            .height(32)
            .textAlign(TextAlign.Center)
            // 无障碍：补上所属提醒名，避免读屏只播报一个孤立的"删除"
            .accessibilityLevel('yes')
            .accessibilityText(`删除${this.title}提醒`)
            .onClick(() => {
              if (this.onDelete !== undefined) {
                this.onDelete();
              }
            })
        }

        // 显式 32×32：折叠箭头热区同理（原约 34×24vp）
        Text('›')
          .fontSize(20)
          .fontColor(ThemeColor.systemGray(this.isDarkMode))
          .width(32)
          .height(32)
          .textAlign(TextAlign.Center)
          .rotate({ angle: this.isExpanded ? 90 : 0 })
          .animation({ duration: 200, curve: Curve.EaseInOut })
          // 无障碍：内容仅 "›"，且旋转后的展开态读屏无从感知，故显式播报当前动作
          .accessibilityLevel('yes')
          .accessibilityText(this.isExpanded ? '收起配置' : '展开配置')
          .onClick(() => {
            this.toggleExpand();
          })

        Toggle({ type: ToggleType.Switch, isOn: $$this.isOnState })
          .selectedColor(IOS26_GREEN)
          // Toggle 自身无标签，兄弟 Text 不会被读屏与之关联；显式播报提醒名与当前状态
          .accessibilityText(`${this.title}${this.isOnState ? '，已开启' : '，已关闭'}`)
          .accessibilityLevel('yes')
          .onChange((isOn: boolean) => {
            this.isOnState = isOn;
            if (isOn) {
              this.isExpanded = true;
            }
            this.onToggle(isOn);
          });
      }.width('100%').alignItems(VerticalAlign.Center)

      if (this.isExpanded) {
        Column({ space: 10 }) {
          Row() {
            Text('间隔').fontSize(12).fontColor(ThemeColor.systemGray(this.isDarkMode))
            Blank()
            Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap, justifyContent: FlexAlign.End }) {
              ForEach(this.intervalOptions, (interval: number) => {
                Button(interval + '分钟')
                  .fontSize(12)
                  .fontColor(this.selectedInterval === interval ? IOS26_WHITE : this.getAccentTextColor())
                  .backgroundColor(this.selectedInterval === interval ? this.getAccentFillColor() : ThemeColor.chipBg(this.accentColor, this.isDarkMode))
                  .height(32)
                  .padding({ left: 10, right: 10 })
                  .margin({ bottom: 4 })
                  .borderRadius(16)
                  .onClick(() => {
                    this.handleSelectInterval(interval);
                  })
                  .accessibilityText(`提醒间隔 ${interval} 分钟${this.selectedInterval === interval ? '，已选择' : ''}`)
                  .accessibilitySelected(this.selectedInterval === interval);
              }, (interval: number) => interval.toString())
            }
            .width('70%')
          }.width('100%').alignItems(VerticalAlign.Center)

          Row({ space: 8 }) {
            Text('自定义间隔').fontSize(12).fontColor(ThemeColor.systemGray(this.isDarkMode))
            Blank()
            TextInput({ placeholder: '分钟', text: $$this.intervalInput })
              .type(InputType.Number)
              .fontSize(12)
              .fontColor(ThemeColor.label(this.isDarkMode))
              .height(32)
              .width(76)
              .borderRadius(8)
              .backgroundColor(ThemeColor.inputBg(this.isDarkMode))
              .maxLength(4)
              .accessibilityText('自定义提醒间隔，单位分钟')
              .onSubmit(() => {
                this.applyCustomInterval();
              })
            Button('应用')
              .fontSize(12)
              .fontColor(IOS26_WHITE)
              .backgroundColor(this.getAccentFillColor())
              .height(32)
              .padding({ left: 12, right: 12 })
.borderRadius(16)
                .accessibilityText(`应用自定义间隔，当前 ${this.intervalInput} 分钟`)
                .onClick(() => {
                  this.applyCustomInterval();
                })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Row() {
            Text('时段').fontSize(12).fontColor(ThemeColor.systemGray(this.isDarkMode))
            Blank()
            Row({ space: 8 }) {
              Button(formatHourMinute(this.startHour, this.startMinute))
                .fontSize(12)
                .fontColor(this.getAccentTextColor())
                .backgroundColor(ThemeColor.chipBg(this.accentColor, this.isDarkMode))
                .height(32)
                .padding({ left: 10, right: 10 })
                .borderRadius(16)
                .accessibilityText(`开始时间 ${formatHourMinute(this.startHour, this.startMinute)}，点击修改`)
                .onClick(() => {
                  this.onOpenStart();
                })
              Button(formatHourMinute(this.endHour, this.endMinute))
                .fontSize(12)
                .fontColor(this.getAccentTextColor())
                .backgroundColor(ThemeColor.chipBg(this.accentColor, this.isDarkMode))
                .height(32)
                .padding({ left: 10, right: 10 })
                .borderRadius(16)
                .accessibilityText(`结束时间 ${formatHourMinute(this.endHour, this.endMinute)}，点击修改`)
                .onClick(() => {
                  this.onOpenEnd();
                })
            }
            .width('70%')
            .justifyContent(FlexAlign.End)
          }.width('100%').alignItems(VerticalAlign.Center)

          // 星期 chip 7 枚 × 32vp + 6×5vp 间隔 = 254vp。与「重复」标签同排时
          // 本行可用宽仅约 235vp（面板 259vp − 标签 24vp），会溢出面板右边缘 19vp，
          // 故标签独占一行、chip 行占满整宽；窄屏（可用 < 254vp）自动折行而非溢出。
          Column({ space: 6 }) {
            Text('重复').fontSize(12).fontColor(ThemeColor.systemGray(this.isDarkMode))
            // 间隔用 SpaceBetween 自适应：本机容器 259vp → 实际间隔约 5.8vp；
            // 窄屏（容器 < 224vp）自动折行而非溢出，chip 尺寸恒定 32vp 不可压缩
            Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
              ForEach(ALL_WEEKDAYS, (day: number) => {
                Text(this.getDayLabel(day))
                  .fontSize(12)
                  .fontColor(this.weekdays.includes(day) ? IOS26_WHITE : this.getAccentTextColor())
                  .backgroundColor(this.weekdays.includes(day) ? this.getAccentFillColor() : ThemeColor.chipBg(this.accentColor, this.isDarkMode))
                  // 无障碍热区下限 32vp，不可为了排版压缩
                  .width(32)
                  .height(32)
                  .textAlign(TextAlign.Center)
                  .borderRadius(16)
                  .onClick(() => {
                    this.onToggleWeekday(day);
                  })
                  // 选中态只由背景/字色表达，读屏无法感知，故显式暴露为 selected 状态
                  .accessibilityText(`周${this.getDayLabel(day)} ${this.weekdays.includes(day) ? '已选中' : '未选中'}`)
                  .accessibilitySelected(this.weekdays.includes(day))
                  .accessibilityLevel('yes');
              }, (day: number) => day.toString())
            }
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          Column({ space: 6 }) {
            Text('提醒内容').fontSize(12).fontColor(ThemeColor.systemGray(this.isDarkMode))

            TextInput({ placeholder: '提醒标题（留空使用默认）', text: $$this.localTitle })
              .fontSize(12)
              .fontColor(ThemeColor.label(this.isDarkMode))
              .height(34)
              .width('100%')
              .borderRadius(8)
              .backgroundColor(ThemeColor.inputBg(this.isDarkMode))
              .maxLength(20)
              .accessibilityText('提醒标题，留空使用默认')
              .onSubmit(() => {
                this.commitTitle();
              })
              .onBlur(() => {
                this.commitTitle();
              })

            TextInput({ placeholder: '提醒内容（留空使用默认）', text: $$this.localContent })
              .fontSize(12)
              .fontColor(ThemeColor.label(this.isDarkMode))
              .height(34)
              .width('100%')
              .borderRadius(8)
              .backgroundColor(ThemeColor.inputBg(this.isDarkMode))
              .maxLength(50)
              .accessibilityText('提醒内容，留空使用默认')
              .onSubmit(() => {
                this.commitContent();
              })
              .onBlur(() => {
                this.commitContent();
              })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .margin({ top: 8 })
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(ThemeColor.glassBg(this.isDarkMode))
    .borderRadius(20)
    .border({ width: 1, color: this.getBorderColor() })
  }

  /** 将强调色转为满足 WCAG AA 对比度的文本色 */
  private getAccentTextColor(): string {
    return ThemeColor.accentTextColor(this.accentColor, this.isDarkMode);
  }

  /** 将强调色转为满足 WCAG AA 的填充色（承载白色文本） */
  private getAccentFillColor(): string {
    return ThemeColor.accentFillColor(this.accentColor, this.isDarkMode);
  }

  /** 计算边框色：从 accentColor 解析 RGB 后按暗色模式生成半透明边框色 */
  private getBorderColor(): string {
    // 从 accentColor hex 解析 RGB 后生成半透明边框色
    const hex = this.accentColor.replace('#', '');
    const r = parseInt(hex.substring(0, 2), 16);
    const g = parseInt(hex.substring(2, 4), 16);
    const b = parseInt(hex.substring(4, 6), 16);
    return ThemeColor.accentBorder(`${r},${g},${b}`, 0.16, this.isDarkMode);
  }
}
