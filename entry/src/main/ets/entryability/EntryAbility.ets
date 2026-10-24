import { formatError } from '../models/ErrUtils';
import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { PreferenceManager } from '../managers/PreferenceManager';
import { AppLaunchGate } from '../managers/AppLaunchGate';
import { HealthStateManager } from '../managers/HealthStateManager';
import { AppLifecycleTracker } from '../managers/AppLifecycleTracker';
import { BackgroundServiceManager } from '../managers/BackgroundServiceManager';
import { PermissionService } from '../managers/PermissionService';
import { ReminderService } from '../managers/ReminderService';
import { NotificationRepostService } from '../managers/NotificationRepostService';
import { FocusModeManager } from '../managers/FocusModeManager';
import { AchievementManager } from '../managers/AchievementManager';
import { DailyGoalManager } from '../managers/DailyGoalManager';
import { HealthDataService } from '../managers/HealthDataService';
import { ThemeColor } from '../components/iOS26Theme';
import { ThemeManager } from '../managers/ThemeManager';
import { PREFS_KEY_NICKNAME } from '../models/Personalization';

const DOMAIN = 0x0000;
const TAG = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  /** 应用冷启动回调：设置色彩模式并注入全局上下文 */
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onCreate');

    // 注入 UIAbilityContext，供文件选择器等系统能力使用
    AppStorage.setOrCreate('context', this.context);

    // 检测当前系统色彩模式并写入 AppStorage，供全局组件响应暗色模式
    this.updateColorMode();
  }

  /** 系统配置变更回调（含色彩模式切换），实时同步暗色模式标记 */
  onConfigurationUpdate(newConfig: Configuration): void {
    this.updateColorMode(newConfig);
    // 用户在应用内改外观时系统才会下发新配置，此时状态栏文字色必须跟着换。
    // 原实现只在 onWindowStageCreate 设一次，切换外观后状态栏会与页面配色不一致。
    this.refreshSystemBars();
  }

  /** 读取系统色彩模式并更新 AppStorage 中的 isDarkMode 标记 */
  private updateColorMode(config?: Configuration): void {
    try {
      const colorMode = config
        ? config.colorMode
        : this.context.config.colorMode;
      const isDark = colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      AppStorage.setOrCreate<boolean>('isDarkMode', isDark);
      // 强调色有 light/dark 两套值，暗色模式切换后必须重新发布
      ThemeManager.getInstance().publishAccent();
      hilog.info(DOMAIN, TAG, '%{public}s', `Color mode updated: isDark=${isDark}`);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'Failed to get colorMode. Cause: %{public}s', formatError(err));
      AppStorage.setOrCreate<boolean>('isDarkMode', false);
    }
  }

  /** 应用销毁回调：释放常驻通知回调与健康监测资源 */
  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
    NotificationRepostService.getInstance().clearAllCallbacks();
    HealthStateManager.getInstance().destroy();
  }

  /**
   * 按当前外观同步系统状态栏/导航栏文字色。
   *
   * 单独抽出来的原因：`onConfigurationUpdate` 在用户于应用内切换外观时也会被调用，
   * 若只在 `onWindowStageCreate` 里设置一次，切换后页面配色变了、状态栏文字色却不变
   * （深色页面配深色文字，状态栏内容直接看不见）。
   */
  private refreshSystemBars(windowStage?: window.WindowStage): void {
    const isDark = AppStorage.get<boolean>('isDarkMode') ?? false;
    const barContentColor = ThemeColor.statusBarContent(isDark);
    if (!windowStage) {
      window.getLastWindow(this.context).then((windowClass: window.Window) => {
        this.applySystemBars(windowClass, barContentColor);
      }).catch((err: Error) => {
        hilog.warn(DOMAIN, TAG, 'Failed to get last window. Cause: %{public}s', err.message);
      });
      return;
    }
    windowStage.getMainWindow().then((windowClass: window.Window) => {
      this.applySystemBars(windowClass, barContentColor);
    }).catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, 'Failed to get main window. Cause: %{public}s', err.message);
    });
  }

  private applySystemBars(windowClass: window.Window, barContentColor: string): void {
    windowClass.setWindowSystemBarProperties({
      statusBarColor: '#00000000',
      navigationBarColor: '#00000000',
      statusBarContentColor: barContentColor,
      navigationBarContentColor: barContentColor,
      enableStatusBarAnimation: false,
      enableNavigationBarAnimation: false
    }).catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, 'Failed to set system bar properties. Cause: %{public}s', err.message);
    });
  }

  /** 主窗口创建回调：设置系统栏外观 + 初始化各管理器 + 加载首页 */
  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageCreate');

    // 注：系统栏外观在偏好就绪、外观确定之后再设一次（见下方 init 回调），
    // 这里的首设只覆盖"偏好加载失败"的兜底路径。

    // 初始化本地偏好存储（必须先完成，再读取限额等配置）
    PreferenceManager.getInstance().init(this.context).then(() => {
      // 偏好就绪后再把 ThemeManager 接上：它需要读已保存的外观选择。
      ThemeManager.getInstance().initialize(PreferenceManager.getInstance());
      // 偏好就绪后发布一次强调色（含用户上次选择的预设）
      ThemeManager.getInstance().publishAccent();
      ThemeManager.getInstance().applySavedMode(this.context);
      // 个性化称呼：首页首帧问候就要用到，故与外观同批在 loadContent 之前发布到 AppStorage。
      // 页面用 @StorageProp('userNickname') 订阅，设置页保存后改 AppStorage 即全局生效。
      AppStorage.setOrCreate<string>('userNickname',
        PreferenceManager.getInstance().getString(PREFS_KEY_NICKNAME, ''));
      // 外观已定，此时再设系统栏，文字色才与首帧配色一致
      this.refreshSystemBars(windowStage);
      // ⚠️ 合规闸门：本闭包内的**所有**服务都会读取用户数据（亮屏统计、提醒调度、
      // 健康状态聚合）。《个人信息保护法》要求先取得用户同意，故整体挂到 AppLaunchGate 上：
      // 已同意过 → 立即执行；首次启动 → 挂起，等首页隐私弹窗的「同意并继续」回调触发。
      AppLaunchGate.getInstance().register(() => {
        this.startServices();
      });
      this.loadMainContent(windowStage);
    }).catch((err: Error) => {
      hilog.error(DOMAIN, TAG, 'Failed to init preferences. Cause: %{public}s', err.message);
      // 偏好初始化失败也必须把页面加载出来，否则用户看到的是白屏。
      // 此时外观保持系统当前模式（ThemeManager.applySavedMode 会退回 'system'）。
      this.loadMainContent(windowStage);
    });
  }

  /**
   * 加载首页。
   *
   * ⚠️ 必须在 `PreferenceManager.init()` 完成**之后**调用，不能与它并行：
   * 用户的深/浅色偏好存在 prefs 里，而 prefs 是异步加载的。若并行 `loadContent`，
   * 页面首帧会按系统当前模式渲染，再被切成用户所选，肉眼可见一次闪烁
   * （实测日志：`isDark=false → isDark=false → isDark=true`）。
   *
   * 同理，系统栏文字色也放在 prefs 就绪后设置（见调用处）。
   */
  private loadMainContent(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      // ⚠️ 判据是 `err.code !== 0`，**不是** `if (err)`。
      // `loadContent` 的回调签名是 `AsyncCallback<void>`（SDK `@ohos.window.d.ts` 实证），
      // 即 `err: BusinessError` **永远非空**，`code === 0` 才是成功。
      // 原实现写成 `if (err)`，于是每次冷启动都走进失败分支：
      // 实机证据（2026-10-15 完整冷启动日志）——
      //   19:38:26.337 E EntryAbility: Failed to load the content. Cause: code=0
      //   19:38:26.354 I EXACT_PREREAD: Push page info <... pageUrl: pages.Index>   ← 17ms 后页面已推入
      //   19:38:27.599 I WMSMain: NotifyCompleteFirstFrameDrawing                   ← 首帧已绘制
      // 全日志 `Succeeded in loading the content.` 出现 **0** 次。
      // 即：页面每次都加载成功，却被记成 ERROR；真正的失败反而会被这条噪声淹没
      // （这正是「每次冷启动一条 code=0」的成因，不是平台噪声）。
      if (err && err.code !== 0) {
        // ⚠️ 这里原来打的是 err.message，实机日志实测输出为「Failed to load the content. Cause:」后面空白 ——
        // loadContent 的回调错误常常不带可读 message，白白丢掉唯一一次"页面加载失败"的现场。
        // 改用 formatError：它会依次尝试 message → code/message → String(err)，保证非空。
        hilog.error(DOMAIN, TAG, 'Failed to load the content. Cause: %{public}s', formatError(err));
        return;
      }
      hilog.info(DOMAIN, TAG, '%{public}s', 'Succeeded in loading the content.');
    });
  }

  /**
   * 启动全部数据相关服务。仅在用户同意隐私政策后被调用（见 {@link AppLaunchGate}）。
   */
  private startServices(): void {
    // 请求运行时所必需权限（必须在提醒服务初始化之前）
    PermissionService.getInstance().requestRequiredPermissions(this.context).then((permissionGranted: boolean) => {
      hilog.info(DOMAIN, TAG, 'Permission request result: %{public}s', String(permissionGranted));
      this.initializeManagers();
    }).catch((err: Error) => {
      hilog.error(DOMAIN, TAG, 'Failed to request permissions. Cause: %{public}s', err.message);
      // 权限申请失败也要继续初始化其余功能：除健康数据同步外，其余功能不依赖该权限
      this.initializeManagers();
    });
  }

  /** 各管理器与提醒服务的初始化（须在 preferences 就绪、权限申请之后） */
  private async initializeManagers(): Promise<void> {
      const reminderService: ReminderService = ReminderService.getInstance();
      reminderService.setContext(this.context);

      // 华为运动健康读写的 Context 同样在启动期统一注入。
      // 原先只在睡前页「从手表同步」按钮的点击回调里注入（Sleep.ets 的 getHostContext），
      // 与其余 manager 的注入时机不一致：任何不经过那个按钮的调用路径都拿不到 context，
      // 而失败会一路被压成「未授权」，把用户引去系统设置里找并不存在的开关。
      HealthDataService.getInstance().setContext(this.context);

      // 启动健康状态监测（含后台长时任务）
      const healthManager = HealthStateManager.getInstance();
      healthManager.setContext(this.context);
      try {
        await healthManager.initialize();
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'Failed to initialize HealthStateManager. Cause: %{public}s', (err as Error).message);
      }

      // 初始化新增功能管理器
      try {
        FocusModeManager.getInstance().initialize();
        AchievementManager.getInstance().initialize();
        DailyGoalManager.getInstance().initialize();
        hilog.info(DOMAIN, TAG, 'New feature managers initialized successfully');
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'Failed to initialize new feature managers. Cause: %{public}s', (err as Error).message);
      }

      // 启动通知轮询检查（自动重发被删除的通知）
      try {
        NotificationRepostService.getInstance().startPolling();
        hilog.info(DOMAIN, TAG, 'Notification repost polling started');
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'Failed to start notification repost polling. Cause: %{public}s', (err as Error).message);
      }

      // 启动提醒服务（睡前提醒、停用时间提醒）恢复调度
      try {
        await reminderService.init();

        // 恢复提醒调度。所有提醒均为通知栏常驻通知（isOngoing），由 OngoingReminderScheduler 驱动。
        // 注意：READ_HEALTH_DATA 在部分设备不受支持，被拒不应阻塞提醒的恢复调度。

        // 恢复睡前提醒
        const bedtimeConfig = reminderService.getBedtimeReminderTime();
        if (bedtimeConfig.enabled) {
          try {
            const success = await reminderService.scheduleBedtimeReminder(bedtimeConfig.hour, bedtimeConfig.minute, true);
            if (!success) {
              hilog.warn(DOMAIN, TAG, 'Failed to schedule bedtime reminder');
            }
          } catch (err) {
            hilog.warn(DOMAIN, TAG, 'Failed to schedule bedtime reminder. Cause: %{public}s', (err as Error).message);
          }
        }

        // 恢复停用时间提醒
        const downtimeRule = healthManager.usageManager.getDowntimeRule();
        if (downtimeRule.enabled) {
          try {
            const success = await reminderService.scheduleDowntimeReminder(downtimeRule.startHour, downtimeRule.startMinute, true);
            if (!success) {
              hilog.warn(DOMAIN, TAG, 'Failed to schedule downtime reminder');
            }
          } catch (err) {
            hilog.warn(DOMAIN, TAG, 'Failed to schedule downtime reminder. Cause: %{public}s', (err as Error).message);
          }
        }
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'Failed to init reminder service. Cause: %{public}s', (err as Error).message);
      }

      // 广播「全部 manager 已就绪」。
      // 页面（当前只有设置页）用它解决冷启动烙默认值的问题：HdsTabs 常驻所有 TabContent，
      // 页面的 aboutToAppear 早于本方法执行，切 Tab 也不再重新触发，只能在这里补一次取值。
      // 放在最后是为了确保各 manager 的 prefs 都已载入（此前通知过一次）。
      HealthStateManager.getInstance().notifyReady();
      hilog.info(DOMAIN, TAG, '%{public}s', 'All managers ready');
  }

  /** 窗口销毁回调：释放 UI 相关资源 */
  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageDestroy');
  }

  /** 应用回到前台：同步前后台标记并通知健康监测（5s 聚合） */
  onForeground(): void {
    // 长时任务若曾被系统限流而停止，回前台是重新申请的合适时机
    // （此时应用可见，用户也不会看到"莫名其妙的后台启动"）。
    // 失败时不再重复调用：retryIfNeeded 内部有 started 守卫。
    BackgroundServiceManager.getInstance().retryIfNeeded();
    // Ability has brought to foreground
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onForeground');
    AppLifecycleTracker.getInstance().setForeground(true);
    HealthStateManager.getInstance().onAppForeground();
  }

  /** 应用退到后台：同步前后台标记并通知健康监测（30s 聚合） */
  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onBackground');
    AppLifecycleTracker.getInstance().setForeground(false);
    HealthStateManager.getInstance().onAppBackground();
  }
}
