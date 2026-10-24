import { GravityTiltManager } from '../managers/GravityTiltManager';
import { AppLifecycleTracker } from '../managers/AppLifecycleTracker';

// 光晕尺寸（px）：暖色 / 冷色 / 顶部高光
const GLOW_WARM_SIZE = 720;
const GLOW_COOL_SIZE = 640;
const GLOW_SHEEN_SIZE = 900;
// 姿态偏移系数：光晕随 tiltX/tiltY 的移动范围（px）
const WARM_RANGE_X = 130;
const WARM_RANGE_Y = 170;
const COOL_RANGE_X = 100;
const COOL_RANGE_Y = 130;

/**
 * 环境光晕组件
 * HarmonyOS NEXT 沉浸光感
 * - 通过 GravityTiltManager 共享重力传感器订阅，随手机姿态变换光晕位置
 * - 暖色 + 冷色双光晕 + 顶部高光，模拟真实环境光
 * - 缓慢呼吸脉动，营造玻璃质感
 * - 暗色模式下调整光晕亮度/对比度，避免在深色背景上过曝
 * 注意：必须放置在其他组件下层（Stack 底层），且不会拦截触摸事件
 */
@Component
export struct AmbientLight {
  /** 重力传感器输出的 X 轴倾角（AppStorage 共享，-1 ~ 1） */
  @StorageLink('tiltX') tiltX: number = 0;
  /** 重力传感器输出的 Y 轴倾角（AppStorage 共享，-1 ~ 1） */
  @StorageLink('tiltY') tiltY: number = 0;
  /** 呼吸动画相位（0 或 1，每 3s 翻转一次） */
  @State breathing: number = 0;
  /** 暗色模式标记 */
  @StorageProp('isDarkMode') isDarkMode: boolean = false;

  /** 呼吸定时器句柄（-1 表示未启动） */
  private breathTimer: number = -1;

  aboutToAppear(): void {
    // 增加重力传感器引用计数并订阅
    GravityTiltManager.getInstance().acquire();

    // 每 3 秒翻转一次呼吸相位。
    // 应用退到后台时跳过相位翻转：写 @State 会重建 3 个大尺寸径向渐变
    // （720/640/900px）并重启 3000ms 动画，属纯后台空耗（页面仍挂载）。
    // 前台时行为与原先完全一致，不影响观感。
    this.breathTimer = setInterval(() => {
      if (!AppLifecycleTracker.getInstance().isForeground()) {
        return;
      }
      this.breathing = this.breathing >= 1 ? 0 : 1;
    }, 3000);
  }

  aboutToDisappear(): void {
    // 释放重力传感器引用（无 AmbientLight 挂载时自动停止传感器）
    GravityTiltManager.getInstance().release();

    // 停止呼吸动画
    if (this.breathTimer !== -1) {
      clearInterval(this.breathTimer);
      this.breathTimer = -1;
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 暖色光晕（随姿态移动）
      // 浅色模式不透明度随背景渐变整体调淡：背景改浅之后，原 0.40 的暖光晕会在
      // 浅蓝底上压出一块明显的黄褐斑，与"冷调同色系"背景冲突（实机截图取证）。
      Column()
        .width(GLOW_WARM_SIZE).height(GLOW_WARM_SIZE)
        .radialGradient({
          center: ['50%', '50%'],
          radius: GLOW_WARM_SIZE / 2,
          colors: this.isDarkMode
            ? [['rgba(255,205,112,0.22)', 0], ['rgba(255,205,112,0)', 1]]
            : [['rgba(255,186,120,0.20)', 0], ['rgba(255,186,120,0)', 1]]
        })
        .translate({ x: this.tiltX * WARM_RANGE_X, y: this.tiltY * WARM_RANGE_Y })
        .animation({ duration: 600, curve: Curve.EaseOut })

      // 冷色光晕（与暖光反向移动）
      // 浅色模式由 0.36 提到 0.42：背景整体变浅后，冷光晕是唯一还能让玻璃卡
      // 显出"背后有光源"的元素，过弱则整页发白失去立体感。
      Column()
        .width(GLOW_COOL_SIZE).height(GLOW_COOL_SIZE)
        .radialGradient({
          center: ['50%', '50%'],
          radius: GLOW_COOL_SIZE / 2,
          colors: this.isDarkMode
            ? [['rgba(130,185,255,0.20)', 0], ['rgba(130,185,255,0)', 1]]
            : [['rgba(120,170,255,0.42)', 0], ['rgba(120,170,255,0)', 1]]
        })
        .translate({ x: -this.tiltX * COOL_RANGE_X, y: -this.tiltY * COOL_RANGE_Y })
        .animation({ duration: 700, curve: Curve.EaseOut })

      // 顶部高光（暗色模式下更微弱的扫光，避免白色过曝）
      // 浅色模式由 0.34 降到 0.20：顶部高光的职责是"玻璃上沿受光"，
      // 而背景渐变顶部本身已是高明度蓝，再叠一层白只会让首屏偏灰。
      Column()
        .width(GLOW_SHEEN_SIZE).height(GLOW_SHEEN_SIZE)
        .radialGradient({
          center: ['50%', '50%'],
          radius: GLOW_SHEEN_SIZE / 2,
          colors: this.isDarkMode
            ? [['rgba(255,255,255,0.12)', 0], ['rgba(255,255,255,0)', 1]]
            : [['rgba(255,255,255,0.20)', 0], ['rgba(255,255,255,0)', 1]]
        })
        .translate({ x: 0, y: -GLOW_SHEEN_SIZE * 0.3 })
        .opacity(this.isDarkMode ? 0.15 + this.breathing * 0.15 : 0.2 + this.breathing * 0.15)
        .animation({ duration: 3000, curve: Curve.EaseInOut })
    }
    .width('100%').height('100%')
    .scale({
      x: 1 + this.breathing * 0.05,
      y: 1 + this.breathing * 0.05
    })
    .animation({ duration: 3000, curve: Curve.EaseInOut })
  }
}
