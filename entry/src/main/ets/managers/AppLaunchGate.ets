import { hilog } from '@kit.PerformanceAnalysisKit';
import { PreferenceManager } from './PreferenceManager';

const TAG = 'AppLaunchGate';

/** 隐私同意状态的偏好键 */
export const PRIVACY_CONSENT_KEY = 'privacy_consent_agreed';

/**
 * 服务启动闸门（隐私合规）
 *
 * 《个人信息保护法》要求：收集个人信息须先取得用户同意。因此 `EntryAbility`
 * **不得**在用户同意之前启动任何会读取用户数据的服务（亮屏统计、提醒调度、
 * 健康状态聚合等）。
 *
 * 流程：
 * 1. `EntryAbility.onCreate` 完成 preferences 初始化后，把服务启动闭包注册到本类。
 *    若用户此前已同意过（`PRIVACY_CONSENT_KEY === true`），立即启动；
 *    否则挂起，等待首页弹窗取得同意。
 * 2. 首页 `PrivacyConsentDialog` 的「同意并继续」回调落盘状态后调用
 *    {@link notifyConsented}，闸门在此启动挂起的服务。
 *
 * 之所以做成单例而非直接在 EntryAbility 里暴露方法：Ability 实例不是页面能持有的对象，
 * 且服务启动跨越 preferences 异步初始化，用一个显式的挂起点比让页面反向调用 Ability 清晰。
 */
export class AppLaunchGate {
  private static instance: AppLaunchGate;

  static getInstance(): AppLaunchGate {
    if (!AppLaunchGate.instance) {
      AppLaunchGate.instance = new AppLaunchGate();
    }
    return AppLaunchGate.instance;
  }

  /** 已同意时为 true；未注册任何启动闭包（即 preferences 尚未初始化完成）时视为 false */
  private startFn: (() => void) | null = null;
  private started: boolean = false;

  /** 用户是否已同意隐私政策（以落盘值为准） */
  static hasConsented(): boolean {
    return PreferenceManager.getInstance().getBoolean(PRIVACY_CONSENT_KEY, false) === true;
  }

  /**
   * 注册服务启动闭包。
   * @param startFn 启动全部服务的闭包；在本方法内部或 {@link notifyConsented} 时被调用一次
   */
  register(startFn: () => void): void {
    this.startFn = startFn;
    if (AppLaunchGate.hasConsented()) {
      this.launch();
    } else {
      hilog.info(0x0000, TAG, '%{public}s', '等待用户同意隐私政策，服务暂未启动');
    }
  }

  /** 用户同意后由首页调用 */
  notifyConsented(): void {
    hilog.info(0x0000, TAG, '%{public}s', '用户已同意隐私政策，启动服务');
    this.launch();
  }

  private launch(): void {
    if (this.started || this.startFn === null) {
      return;
    }
    this.started = true;
    const fn = this.startFn;
    this.startFn = null;
    fn();
  }
}