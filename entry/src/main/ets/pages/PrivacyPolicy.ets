import { ThemeColor, IOS26_WHITE } from '../components/iOS26Theme';
import { AmbientLight } from '../components/AmbientLight';
import { curves } from '@kit.ArkUI';

/**
 * 隐私政策页面
 *
 * 上架必备：《个人信息保护法》要求收集个人信息的应用必须提供隐私政策，
 * 且首次启动须在**用户同意之前**完成展示。本页为该展示的载体。
 *
 * ⚠️ 内容需与实际实现保持一致。当前实现的三个事实（写文案时不要夸大）：
 * - 应用**没有申请网络权限**（全库无 `ohos.permission.INTERNET`），
 *   所有数据仅存于设备本地 preferences 与健康数据沙箱，不会上传到任何服务器；
 * - 手机亮屏时长 / 解锁次数来自系统亮灭屏事件与 `power.isActive()`，仅在本机统计；
 * - 健康数据（睡眠）仅在用户主动点击「从华为运动健康同步」时才读取，
 *   读取后仅用于生成睡前建议，同样不外传。
 */
@Entry
@Component
struct PrivacyPolicy {
  /** 用户强调色（跟随设置页「强调色」选择，全应用一致） */
  @StorageLink('accentColorHex') accentColorHex: string = '#0066CC';
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  @State scrollY: number = 0;

  private readonly sections: PrivacySection[] = PRIVACY_SECTIONS;

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 背景与 GoalPage / AchievementPage 同款（渐变 + 环境光晕），保持全应用视觉一致
      Column().width('100%').height('100%')
        // ⚠️ 必须挂 expandSafeArea：根 Stack 上的 expandSafeArea 只让容器延伸进安全区，
        // 子组件仍被裁在安全区内，状态栏/导航条区域会露出默认白底形成白带（实机截图取证）。
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .linearGradient({
          direction: GradientDirection.Bottom,
          colors: ThemeColor.gradient(this.isDarkMode)
        })

      AmbientLight()
      Column() {
        this.buildHeader()
        Scroll() {
          Column({ space: 16 }) {
            Text('萤光守护是一款完全在本机运行的数字健康工具。本政策说明它会接触哪些数据、为什么需要，以及如何控制。')
              .fontSize(13)
              .fontColor(ThemeColor.labelSecondary(this.isDarkMode))
              .lineHeight(21)

            ForEach(this.sections, (section: PrivacySection) => {
              Column({ space: 6 }) {
                Text(section.title)
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(ThemeColor.label(this.isDarkMode))
                Text(section.body)
                  .fontSize(13)
                  .fontColor(ThemeColor.labelSecondary(this.isDarkMode))
                  .lineHeight(21)
              }
              .alignItems(HorizontalAlign.Start)
              .width('100%')
              .padding({ left: 14, right: 14, top: 12, bottom: 12 })
              .backgroundColor(ThemeColor.glassBg(this.isDarkMode))
              .borderRadius(14)
              .border({ width: 1, color: ThemeColor.glassBorder(this.isDarkMode) })
            }, (section: PrivacySection) => section.title)
          }
          .width('100%')
          .padding({ left: 20, right: 20, bottom: 32 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')
      .padding({ left: 20, right: 20, top: 16 })
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  buildHeader() {
    Row() {
      Text('‹')
        .fontSize(28)
        .fontColor(ThemeColor.accentColor(this.accentColorHex, this.isDarkMode))
        .width(48)
        .height(48)
        .textAlign(TextAlign.Center)
        .accessibilityLevel('yes')
        .accessibilityText('返回')
        .onClick(() => { this.getUIContext().getRouter().back(); })

      Text('隐私政策')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(ThemeColor.label(this.isDarkMode))
        .layoutWeight(1)

      Text('')
        .width(48)
    }
    .width('100%')
    .height(56)
    .padding({ bottom: 8 })
    .animation({ duration: 240, curve: curves.interpolatingSpring(0, 1, 190, 22) })
  }
}

/** 隐私政策的一个章节 */
interface PrivacySection {
  title: string;
  body: string;
}

/**
 * 政策正文。
 *
 * ⚠️ 改动本文件前请先核对实际实现，**不要写入应用做不到的承诺**：
 * 例如若将来加入网络同步，必须同时修改「我们如何存储」与「我们如何共享」两节。
 */
const PRIVACY_SECTIONS: PrivacySection[] = [
  {
    title: '一、我们收集哪些信息',
    body: '本应用不会收集您的姓名、手机号、位置、通讯录或设备标识等身份信息，也不会通过网络传输任何数据。应用仅在您的设备本机使用以下信息：\n\n' +
      '· 屏幕亮起与熄灭的时间点：用于统计每日屏幕使用时长。这来自操作系统的亮灭屏事件通知，精确到「您何时在看屏幕」，不含屏幕内容，也不区分您在使用哪个应用。\n' +
      '· 屏幕解锁事件：用于统计每日解锁次数。\n' +
      '· 睡眠数据（仅在您主动点击「从华为运动健康同步」后读取）：包括睡眠时长、深睡与浅睡等阶段数据，用于计算您的睡前习惯评分并给出建议。\n' +
      '· 您在应用内主动填写的内容：如自定义提醒的名称与文案、每日目标、睡前使用时长、个性化称呼与自定义强调色等。'
  },
  {
    title: '二、我们如何使用这些信息',
    body: '上述信息仅用于向您展示统计结果、计算评分并生成建议，不用于广告、画像或任何形式的对外提供。屏幕使用统计的默认口径是整台手机的亮屏时长，而非某一个应用的使用时长。'
  },
  {
    title: '三、我们如何存储',
    body: '所有数据均保存在您设备本机的应用私有存储中，不会离开您的设备。本应用未申请网络访问权限，因此不存在数据上传至服务器的可能。\n\n' +
      '当您主动使用「导出数据」功能时，应用会在您选择的位置生成一份备份文件。该文件由您自行保管，删除应用不会自动删除它。'
  },
  {
    title: '四、我们如何共享',
    body: '我们不会与任何第三方共享、出售或转让您的信息。本应用不含第三方统计、广告或追踪 SDK，也不包含任何网络请求代码。'
  },
  {
    title: '五、权限及其用途',
    body: '· 屏幕亮灭屏事件与后台运行：用于在应用未打开时持续统计亮屏时长。此权限由系统在安装时自动授予。\n' +
      '· 健康数据（睡眠）：仅在您点击「从华为运动健康同步」时才会申请与读取。未授权不影响其他功能。\n' +
      '· 通知：用于向您发送提醒。您可以在系统设置中随时关闭通知，应用的其他功能不受影响。'
  },
  {
    title: '六、您的控制权',
    body: '您可以随时在「设置 → 数据管理」中：\n\n' +
      '· 导出数据到您选择的位置，作为备份；\n' +
      '· 导入此前导出的备份；\n' +
      '· 重置所有数据，清空本机保存的全部统计与配置。\n\n' +
      '卸载应用会一并删除本机数据。若您此前导出过备份文件，该文件由您自行管理。'
  },
  {
    title: '七、未成年人保护',
    body: '本应用面向一般用户。若使用者为未成年人，请在监护人陪同下使用并由监护人代为管理相关设置。'
  },
  {
    title: '八、联系我们',
    body: '如您对本政策有任何疑问，或发现本应用存在隐私问题，欢迎通过开源项目的 Issues 页面与我们联系。'
  }
];