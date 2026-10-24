import { ThemeColor, IOS26_WHITE } from './iOS26Theme';
import { DialogShell } from './DialogShell';

/**
 * 首启隐私同意弹窗
 *
 * 《个人信息保护法》要求：涉及收集个人信息的应用，必须在**首次启动**向用户展示
 * 隐私政策并取得同意，且**在同意之前不得收集任何信息**。
 *
 * 本组件承载该弹窗，挂在首页根节点上。约定：
 * - `onAgree`：`onAppear` 时调用（同意后才允许申请权限、开始统计）；
 * - `onDisagree`：用户选择不同意时调用，调用方需退出应用；
 * - 同意状态由调用方持久化，二次启动不再弹。
 *
 * ⚠️ 弹窗内容与 `pages/PrivacyPolicy` 必须一致：政策页面是全文，本弹窗是摘要 + 入口。
 */
@Component
export struct PrivacyConsentDialog {
  /** 用户强调色（跟随设置页「强调色」选择，全应用一致） */
  @StorageLink('accentColorHex') accentColorHex: string = '#0066CC';
  /** 用户点击「同意并继续」 */
  onAgree: () => void = () => {};
  /** 用户点击「不同意」 */
  onDisagree: () => void = () => {};
  @StorageProp('isDarkMode') isDarkMode: boolean = false;

  build() {
    DialogShell({
      // 遮罩点击**不**关闭：这是合规弹窗，必须让用户明确做出选择
      onDismiss: () => {}
    }) {
      this.Content()
    }
  }

  @Builder
  Content() {
    Column({ space: 14 }) {
      Text('欢迎使用萤光守护')
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor(ThemeColor.label(this.isDarkMode))

      Text('在开始之前，请了解我们会接触到哪些数据：')
        .fontSize(13)
        .fontColor(ThemeColor.labelSecondary(this.isDarkMode))
        .lineHeight(20)
        .width('100%')

      Column({ space: 8 }) {
        Text('· 屏幕亮起与熄灭的时间点，用于统计每日屏幕使用时长')
          .fontSize(12).fontColor(ThemeColor.labelSecondary(this.isDarkMode)).lineHeight(18)
        Text('· 屏幕解锁事件，用于统计解锁次数')
          .fontSize(12).fontColor(ThemeColor.labelSecondary(this.isDarkMode)).lineHeight(18)
        Text('· 睡眠数据，仅在您主动点击「从华为运动健康同步」后读取')
          .fontSize(12).fontColor(ThemeColor.labelSecondary(this.isDarkMode)).lineHeight(18)
      }
      .width('100%')

      Text('所有数据仅保存在您的设备本机。本应用没有网络访问权限，不会上传任何数据，也不会与第三方共享。')
        .fontSize(12)
        .fontColor(ThemeColor.labelSecondary(this.isDarkMode))
        .lineHeight(18)
        .width('100%')

      Text('查看完整隐私政策 ›')
        .fontSize(13)
        .fontColor(ThemeColor.accentColor(this.accentColorHex, this.isDarkMode))
        .width('100%')
        .accessibilityLevel('yes')
        .accessibilityText('查看完整隐私政策')
        .onClick(() => {
          this.getUIContext().getRouter().pushUrl({ url: 'pages/PrivacyPolicy' });
        })

      Row({ space: 12 }) {
        Button('不同意并退出')
          .fontSize(15)
          .fontColor(ThemeColor.labelSecondary(this.isDarkMode))
          .backgroundColor(ThemeColor.inputBg(this.isDarkMode))
          .layoutWeight(1)
          .height(46)
          .borderRadius(23)
          .onClick(() => { this.onDisagree(); })

        Button('同意并继续')
          .fontSize(15)
          .fontColor(IOS26_WHITE)
          .backgroundColor(ThemeColor.accentColorFill(this.accentColorHex, this.isDarkMode))
          .layoutWeight(1)
          .height(46)
          .borderRadius(23)
          .onClick(() => { this.onAgree(); })
      }
      .width('100%')
      .margin({ top: 4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}