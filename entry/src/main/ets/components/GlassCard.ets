import { curves } from '@kit.ArkUI';
import { ThemeColor } from './iOS26Theme';

/**
 * 液态玻璃卡片组件
 * HarmonyOS NEXT 沉浸光感风格
 * - 半透明磨砂玻璃材质 + 动态光影
 * - 顶部高光描边，模拟玻璃边缘反光
 * - 按压凹陷反馈 + 悬浮阴影 + 弹性入场动画
 * - 支持暗色模式：深色半透明背景 + 柔光描边
 */
@Component
export struct GlassCard {
  /** 是否处于按压状态（触摸按下时为 true，驱动按压凹陷反馈） */
  @State isPressed: boolean = false;
  /** 入场动画延迟（毫秒），用于卡片依次浮现 */
  @Prop delay: number = 0;
  /** 卡片整体不透明度（父级入场动画驱动） */
  @Prop cardOpacity: number = 1;
  /** 卡片入场 Y 轴位移（父级入场动画驱动） */
  @Prop cardTranslateY: number = 0;
  /** 卡片宽度 */
  @Prop cardWidth: string = '100%';
  /** 卡片外边距 */
  @Prop cardMargin: Margin | Length = 0;
  /** 卡片内容插槽 */
  @BuilderParam content: () => void = this.defaultContent;
  /** 卡片点击回调（由父组件注入）；未注入时卡片不可点击，也不展示按压反馈 */
  onCardClick: (() => void) | undefined = undefined;
  /**
   * 无障碍语义标签（仅在注入 onCardClick 时生效）。
   * 入口卡片需要播报"停用时间，点击进入设置"这类信息，否则读屏只会把整卡文本平铺念完。
   */
  @Prop accessibilityLabel: string = '';

  /** 暗色模式标记（从 AppStorage 响应式获取） */
  @StorageProp('isDarkMode') isDarkMode: boolean = false;

  @Builder
  defaultContent() {
  }

  /**
   * 玻璃底缘折射光：与顶部高光对称但更弱，给卡片"厚度"。
   * 真实玻璃在深色背景上底缘会聚一次折射亮边，缺了它卡片会显得贴在背景上而非悬浮。
   * 用 .overlay 叠在卡片上（见 build() 注释：overlay() 是单值修饰符，
   * 顶缘高光不能也走 overlay，否则会被本 builder 顶掉）。
   */
  @Builder
  bottomRefract() {
    Column()
      .width('72%')
      .height(1)
      .linearGradient({
        direction: GradientDirection.Right,
        colors: [['rgba(255,255,255,0)', 0],
          [ThemeColor.glassEdgeRefract(this.isDarkMode), 0.5],
          ['rgba(255,255,255,0)', 1]]
      })
  }


  build() {
    // ⚠️ 未注入 onCardClick 的纯展示卡片不响应按压态（26 处卡片中 22 处是纯展示）。
    // ⚠️ 结构敏感（2026-10-11 实机像素取证，勿回退）：两条亮边必须叠在玻璃体之上。
    // glassBg 是 72% 不透明，若把亮边画在玻璃体之前，只会透出 28% —— 实测顶缘 0.25 与
    // 底缘 0.10 被压成同一个有效亮度（约 0.058），"顶部强于底部"的 2.5:1 关系完全丢失。
    //
    // 顶缘与底缘必须用**两种不同的机制**，因为每种机制一次只能定位一条线：
    //   · 顶缘：Stack 兄弟节点 + margin({top:1})，alignContent(Alignment.Top) 把它钉在顶。
    //     （实测 eff≈0.25，吻合声明值。）
    //   · 底缘：.overlay(builder, {align: Bottom, offset:{y:-6}})。
    //     （实测 eff≈0.10，吻合声明值；offset 单位 vp，-6vp ≈ 上抬 18px 落在卡内底缘。）
    //
    // 试过但不可行的写法（均实机取证失败，勿再尝试）：
    //   ① 底缘用 .align(Alignment.Bottom) 作 Stack 子节点 —— 本 SDK 不生效，落到顶部与
    //      高光重叠（合成 0.325 白，两值双双失配）；
    //   ② 底缘放进 100% 高 flex 容器 + FlexAlign.End —— Stack 高度由玻璃体决定，子组件
    //      height('100%') 循环依赖塌缩为 0，整条不渲染；
    //   ③ 两条线都放进单个 .overlay 内的 Column(height 100% + SpaceBetween) —— overlay
    //      内容的 height('100%') 同样解析为 0，Column 塌缩，底缘子组件被裁掉不渲染；
    //   ④ 两次 .overlay() 分别叠顶/底 —— overlay() 是单值修饰符，只有最后一次生效，
    //      顶缘高光完全消失。
    Stack({ alignContent: Alignment.Top }) {
      Column() {
        this.content()
      }
      .width('100%')
      .padding(24)
      .backgroundColor(ThemeColor.glassBg(this.isDarkMode, this.isPressed))
      .border({
        width: 0.5,
        color: ThemeColor.glassBorder(this.isDarkMode, this.isPressed)
      })
      .borderRadius(28)
      .backgroundBlurStyle(this.isDarkMode ? BlurStyle.Regular : BlurStyle.Thick)
      .shadow({
        radius: this.isPressed ? 8 : 20,
        color: ThemeColor.glassShadow(this.isDarkMode, this.isPressed),
        offsetX: 0,
        offsetY: this.isPressed ? 4 : 10
      })
      // 轻量抬升：未按压时给一点点立体感，按压时归零（与阴影/缩放共同构成凹陷反馈）
      .translate({ y: this.isPressed ? 0 : -1 })
      .scale({ x: this.isPressed ? 0.994 : 1, y: this.isPressed ? 0.994 : 1 })
      .brightness(this.isPressed ? 0.97 : 1)
      .saturate(this.isDarkMode ? 1.1 : 1.35)
      .animation({ duration: 180, curve: Curve.EaseOut })

      // 玻璃顶部高光边（暗色模式下减弱）。Stack 兄弟节点，margin top 1vp 贴顶。
      // ⚠️ 此处**不要**再挂 .opacity(this.cardOpacity)：父 Stack 已有（见下方），子节点再挂一次
      // 会让顶缘变成 cardOpacity² × 0.25，而底缘在 overlay 里只有 cardOpacity × 0.10 ——
      // 静止态两者相等（cardOpacity=1 时测不出），但入场动画期间顶/底比从设计的 2.5:1
      // 塌到约 1.1:1，顶缘显得比预期暗一倍。
      Column()
        .width('88%')
        .height(1)
        .linearGradient({
          direction: GradientDirection.Right,
          colors: [['rgba(255,255,255,0)', 0],
            [ThemeColor.glassHighlightCenter(this.isDarkMode, this.isPressed), 0.5],
            ['rgba(255,255,255,0)', 1]]
        })
        .margin({ top: 1 })
    }
    .width(this.cardWidth)
    .margin(this.cardMargin)
    .alignSelf(ItemAlign.Center)
    // 底缘折射光：overlay 叠在整张卡（含圆角）之上，align Bottom + offset 贴到卡内底缘。
    // 平时与按压时位置一致，随卡片整体的 translate/scale/brightness 一起变换。
    .overlay(this.bottomRefract(), { align: Alignment.Bottom, offset: { x: 0, y: -6 } })
    .opacity(this.cardOpacity)
    .translate({ y: this.cardTranslateY })
    .scale({ x: 0.96 + 0.04 * this.cardOpacity, y: 0.96 + 0.04 * this.cardOpacity })
    .onTouch((event: TouchEvent) => {
      // TouchType 枚举为 { Down=0, Up=1, Move=2, Cancel=3 }，按下才置 true
      // 未注入 onCardClick 的纯展示卡片不响应按压态
      if (this.onCardClick === undefined) {
        return;
      }
      this.isPressed = Number(event.type) === 0;
    })
    .onClick(() => {
      this.onCardClick?.();
    })
    // 无障碍：纯展示卡 'no'（不可聚焦，后代文本仍可读，不影响卡内控件）；
    // 入口卡 'yes' + 语义标签。
    // 注：空 onClick 也会让节点进入可点击语义树，与 'no' 分流相抵，但改法需要把
    // 整条链按卡片类型拆成两个 @Builder —— ArkUI 的 @Builder 返回 void、无法在其后
    // 链式挂属性（实测报 "Property 'onTouch' does not exist on type 'void'"），
    // 故保留现状：'no' 分流已解决读屏播报问题，空 onClick 仅残留为无障碍树的轻微噪声。
    .accessibilityLevel(this.onCardClick === undefined ? 'no' : 'yes')
    .accessibilityText(this.accessibilityLabel)
    .animation({ duration: 240, curve: curves.interpolatingSpring(0, 1, 190, 22), delay: this.delay })
  }
}
