import { ThemeColor } from './iOS26Theme';

/**
 * 通用玻璃弹窗外壳
 *
 * 此前 GoalPage 的「添加目标 / 删除确认」与 Settings 的「添加自定义提醒 / 确认重置」
 * 四个弹窗各自复制了同一套外壳：全屏 Stack + 可点击关闭的遮罩 + 80% 宽玻璃面板
 * （含 padding 20 / 圆角 20 / 背景模糊 20 / 悬浮阴影）。改圆角或阴影要动四处，
 * 漏改就会让两个页面的弹窗长得不一样。
 *
 * 收敛后：外壳只有这一份，调用方只提供内容插槽。
 * 遮罩点击关闭走 `onDismiss` 参数（GoalPage 原有 DialogMask 是逐字复制的，
 * 一并并入本组件）。
 */
@Component
export struct DialogShell {
  /** 点击遮罩时的回调 */
  onDismiss: () => void = () => {};
  /** 弹窗内容插槽（@BuilderParam：由调用方传入一个 @Builder 方法） */
  @BuilderParam content: () => void;
  /** 暗色模式标记（玻璃底色随其切换） */
  @StorageProp('isDarkMode') isDarkMode: boolean = false;

  build() {
    Stack() {
      // 遮罩：铺满全屏，点击关闭。放在内容之下故先声明。
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(ThemeColor.dialogMask())
        .onClick(() => { this.onDismiss(); })

      Column() {
        this.content()
      }
      .width('80%')
      .padding(20)
      .backgroundColor(ThemeColor.glassBg(this.isDarkMode))
      .borderRadius(20)
      .backdropBlur(20)
      .shadow({ radius: 20, color: ThemeColor.shadowColor(this.isDarkMode), offsetX: 0, offsetY: 8 })
    }
    .width('100%')
    .height('100%')
  }
}