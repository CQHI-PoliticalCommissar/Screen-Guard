/**
 * 应用生命周期追踪器
 * 替代 AppStorage，在 EntryAbility 前后台切换时同步更新状态
 * 供页面读取前台标志，避免引入 ArkUI 存储兼容问题
 */
export class AppLifecycleTracker {
  private static instance: AppLifecycleTracker;

  static getInstance(): AppLifecycleTracker {
    if (!AppLifecycleTracker.instance) {
      AppLifecycleTracker.instance = new AppLifecycleTracker();
    }
    return AppLifecycleTracker.instance;
  }

  /** 是否处于前台（默认 true：冷启动 UI 优先，与 HealthStateManager 聚合节奏一致） */
  private inForeground: boolean = true;

  /** 由 EntryAbility 前后台回调调用，更新前台标志 */
  setForeground(value: boolean): void {
    this.inForeground = value;
  }

  /** 读取当前是否处于前台 */
  isForeground(): boolean {
    return this.inForeground;
  }
}
