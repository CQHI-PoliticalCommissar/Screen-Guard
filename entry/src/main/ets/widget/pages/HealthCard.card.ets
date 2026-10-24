import { HealthStateManager } from '../../managers/HealthStateManager';
import { HealthCapsuleData, HealthStatus } from '../../models/HealthTypes';

/**
 * 原子化服务卡片 - 屏幕使用时间
 * iOS 26 液态玻璃风格
 * - 通过 $r() 资源引用自动适配系统深浅色模式
 * - 卡片运行在独立进程，无法使用 AppStorage/@StorageProp
 */
@Entry
@Component
struct HealthCard {
  @State capsuleData: HealthCapsuleData = HealthStateManager.getInstance().getCapsuleData();
  @State breathScale: number = 1.3;
  @State ringPulse: number = 1.0;
  private usageManager = HealthStateManager.getInstance().usageManager;
  private stateListener: (data: HealthCapsuleData) => void = (data) => {
    this.capsuleData = data;
  };

  /** 卡片出现：初始化状态并订阅健康数据变化监听 */
  aboutToAppear(): void {
    HealthStateManager.getInstance().initialize().catch((err: Error) => {
      console.error('HealthCard initialize failed: ' + err.message);
    });
    HealthStateManager.getInstance().addStateListener(this.stateListener);
    this.breathScale = 1.3;
    this.ringPulse = 1.02;
  }

  /** 卡片消失：移除健康数据变化监听 */
  aboutToDisappear(): void {
    HealthStateManager.getInstance().removeStateListener(this.stateListener);
  }

  /**
   * 按日限额计算使用进度百分比（0-100，限额为 0 时为 0）
   *
   * ⚠️ 必须与下方中心数字同源：都用 `capsuleData.eyeUsageSeconds`。
   * 原先这里读 `usageManager.getTotalUsageSeconds()`（即 `todayUsage`，只由
   * `refreshUsage()` 每 30s 覆写），而中心数字读 `capsuleData.eyeUsageSeconds`
   * （由 5s 聚合链路刷新）——同一个"今日用量"取了两个刷新节奏不同的源，
   * 环与数字最长可差 30s 不一致（如数字「1时1分」而环仍按 60 分钟算）。
   */
  private getUsageProgress(): number {
    const limitSec = this.usageManager.getTotalDailyLimitMinutes() * 60;
    if (limitSec <= 0) {
      return 0;
    }
    return Math.min(100, (this.capsuleData.eyeUsageSeconds / limitSec) * 100);
  }

  /** 状态色：预警橙 / 超限红 / 正常绿 */
  private getStatusColor(): ResourceStr {
    switch (this.capsuleData.status) {
      case HealthStatus.WARNING:
        return $r('app.color.status_warning');
      case HealthStatus.EMERGENCY:
        return $r('app.color.status_emergency');
      default:
        return $r('app.color.status_normal');
    }
  }

  /** 秒数格式化为 "X时X分" / "X分钟" */
  private formatUsage(seconds: number): string {
    const mins = Math.floor(seconds / 60);
    const hrs = Math.floor(mins / 60);
    const remMins = mins % 60;
    if (hrs > 0) {
      return `${hrs}时${remMins}分`;
    }
    return `${remMins}分钟`;
  }

  /** 进度百分比文本 */
  private getPercentText(): string {
    return `${Math.round(this.getUsageProgress())}%`;
  }

  /** 连续达标文案：有连续天数显示 "X天"，否则显示 "今日" */
  private getStreakText(): string {
    if (this.capsuleData.streakDays > 0) {
      return `${this.capsuleData.streakDays}天`;
    }
    return '今日';
  }

  build() {
    Column({ space: 10 }) {
      // 顶部标题栏
      Row() {
        Column() {
          Text('屏幕使用时间')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // 状态点（带呼吸动画）
        Stack() {
          Circle()
            .width(12)
            .height(12)
            .fill(this.getStatusColor())
            .opacity(0.5)
            .blur(6)
            .scale({ x: this.breathScale, y: this.breathScale })
            .animation({ duration: 1200, iterations: -1, playMode: PlayMode.AlternateReverse, curve: Curve.EaseInOut })

          Circle()
            .width(8)
            .height(8)
            .fill(this.getStatusColor())
        }
        .width(16)
        .height(16)
      }
      .width('100%')

      // 使用时长 + 进度环
      Stack() {
        // 外层装饰环（微弱脉动）
        Circle()
          .width(80)
          .height(80)
          .fill('#00000000')
          .border({ width: 1, color: $r('app.color.card_border') })
          .scale({ x: this.ringPulse, y: this.ringPulse })
          .animation({ duration: 2500, iterations: -1, playMode: PlayMode.AlternateReverse, curve: Curve.EaseInOut })

        // 进度环
        Progress({ value: this.getUsageProgress(), total: 100, type: ProgressType.Ring })
          .width(70)
          .height(70)
          .color(this.getStatusColor())
          .backgroundColor($r('app.color.progress_track'))
          .style({ strokeWidth: 6 })
          .animation({ duration: 600, curve: Curve.EaseInOut })

        // 中心内容
        Column({ space: 2 }) {
          Text(this.formatUsage(this.capsuleData.eyeUsageSeconds))
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.getStatusColor())
          
          Text(this.getPercentText())
            .fontSize(10)
            .fontColor($r('app.color.text_secondary'))
        }
      }
      .width('100%')
      .height(90)
      .alignContent(Alignment.Center)

      // 底部信息
      Row() {
        // 连续达标
        Text(this.getStreakText())
          .fontSize(10)
          .fontColor(this.capsuleData.streakDays > 0 ? $r('app.color.status_normal') : $r('app.color.text_secondary'))
          .fontWeight(this.capsuleData.streakDays > 0 ? FontWeight.Medium : FontWeight.Normal)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .backgroundColor(this.capsuleData.streakDays > 0 ? $r('app.color.streak_bg_active') : $r('app.color.streak_bg_inactive'))
          .borderRadius(6)
        
        Text(`剩${this.capsuleData.remainingMinutes}分`)
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding(14)
    .backgroundColor($r('app.color.card_background'))
    .border({ width: 0.5, color: $r('app.color.card_border') })
    .borderRadius(16)
    .backgroundBlurStyle(BlurStyle.Thin)
    .shadow({ radius: 12, color: '#00000012', offsetX: 0, offsetY: 3 })
  }
}
