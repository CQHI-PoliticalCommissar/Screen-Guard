import { formatError } from '../models/ErrUtils';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { notificationManager } from '@kit.NotificationKit';
import { HealthStateManager } from '../managers/HealthStateManager';
import { DataBackupManager, ImportFailureReason } from '../managers/DataBackupManager';
import { GlassCard } from '../components/GlassCard';
import { DialogShell } from '../components/DialogShell';
import { AmbientLight } from '../components/AmbientLight';
import { HealthReminderControl } from '../components/HealthReminderControl';
import { ReminderService } from '../managers/ReminderService';
import { BackgroundServiceManager } from '../managers/BackgroundServiceManager';
import { ThemeManager, ThemeMode } from '../managers/ThemeManager';
import { HealthReminderManager } from '../managers/HealthReminderManager';
import { HealthReminderConfig, CustomReminderItem } from '../models/ReminderItemTypes';
import { PermissionService } from '../managers/PermissionService';
import { common } from '@kit.AbilityKit';
import { ALL_WEEKDAYS, WEEKDAY_LABELS, formatHourMinute, DowntimeRule, ACCENT_COLOR_PRESETS, DEFAULT_ACCENT_COLOR_KEY, AccentColorPreset, HOME_CARD_ITEMS, HomeCardItem } from '../models/HealthTypes';
import {
  HomeCardConfigEntry,
  defaultHomeCardConfig,
  isHomeCardVisible,
  moveHomeCardInConfig,
  setHomeCardVisible,
  visibleHomeCardCount,
  visibleIndexOfHomeCard
} from '../models/HomeCardLayout';
import { showToastSafe } from '../models/UiUtils';
import {
  SleepManager,
  MIN_PRE_SLEEP_RESTRICTION_MINUTES,
  MAX_PRE_SLEEP_RESTRICTION_MINUTES,
  MIN_BEDTIME_OFFSET_MINUTES,
  MAX_BEDTIME_OFFSET_MINUTES,
  MIN_SLEEP_GOAL_MINUTES,
  MAX_SLEEP_GOAL_MINUTES
} from '../managers/SleepManager';
import {
  IOS26_BLUE,
  IOS26_GREEN,
  IOS26_ORANGE,
  IOS26_PURPLE,
  IOS26_WHITE,
  ThemeColor
} from '../components/iOS26Theme';
import { MIN_TOTAL_LIMIT_MINUTES, MAX_TOTAL_LIMIT_MINUTES } from '../managers/UsageStatsManager';
import { describeHexInputError, normalizeHexColor } from '../models/AccentColorMath';
import { MAX_NICKNAME_LENGTH, normalizeNickname, PREFS_KEY_NICKNAME } from '../models/Personalization';
import { PreferenceManager } from '../managers/PreferenceManager';

const DEFAULT_REMINDER_COUNT = 3;

/**
 * 系统文件选择器（DocumentViewPicker）调用的超时上限（毫秒）。
 *
 * 该调用在系统缺少文件选择器应用时**既不 resolve 也不 reject**（实机复现：模拟器未预装
 * DocumentsUI，点「导出数据」后 Promise 永不返回），故必须由调用方兜一个超时，
 * 否则 `isExporting` 永为 true、按钮永久卡在「导出中...」且整行被 `.enabled(false)` 禁用。
 *
 * ⚠️ 但这个超时**无法区分"选择器不存在"与"用户正在文件管理器里翻找"**——两者都是
 * Promise 悬空。所以取值必须按"假阳性代价低"的原则定：
 * 原先 60 秒在真机上会造成**真实可发生的误报**（用户在文件管理器里挑个目录超过 1 分钟，
 * 回来看到「导出超时：系统文件选择器无响应」，而文件其实已经选好了）。
 * 现取 10 分钟：翻找再久也不会误报；而真·无响应（缺 DocumentsUI 的模拟器/定制系统）
 * 仍会在 10 分钟内被兜住。代价是那种环境下按钮要多卡 10 分钟才恢复——
 * 相比让正常用户丢一次导出，这个取舍划算。
 */
const PICKER_TIMEOUT_MS = 600000;

/** 外观选项的展示模型（ArkTS 不允许用无类型对象字面量，故显式声明接口） */
interface AppearanceOption {
  value: ThemeMode;
  label: string;
}

/**
 * 外观三选项。
 *
 * 刻意做成模块级常量而非在 `@Builder` / `build` 里现构造：
 * ForEach 的数据源若每次渲染都是新数组，key 相同却实例不同，会白白重建子组件。
 */
const APPEARANCE_OPTIONS: AppearanceOption[] = [
  { value: 'system', label: '跟随系统' },
  { value: 'light', label: '浅色' },
  { value: 'dark', label: '深色' }
];

/**
 * 时间选择弹窗的标题（按模式）。
 *
 * 模块级纯函数：打开弹窗时（事件回调，普通 JS 上下文）算好写进 `@State
 * timePickerTitleText`，弹窗的 `@Builder` 只读那个状态。
 *
 * ⚠️ 本文件曾经把标题写成 `Text(this.getTimePickerTitle())`——**点一下「免打扰结束时间」
 * 就把整个应用点崩了**。实机崩溃栈（/data/log/faultlog）：
 *   E AceStateMgmt: @Component 'DialogShell'[650] has error in update func: undefined is not callable
 *   E ArkCompiler:   TypeError: undefined is not callable
 *   at anonymous entry (Settings.ets:1850:17)      ← `Text(this.getTimePickerTitle())`
 *   at timePickerForm entry (Settings.ets:1849:25)
 *   at initialRender entry (components/DialogShell.ets:34:9)
 * → AppKit `is about to exit due to RuntimeError`，进程被系统杀掉。
 *
 * **根因**（重要，勿回退）：`timePickerForm` 原先是**按值**传给 `DialogShell` 的
 * `@BuilderParam`（`content: this.timePickerForm`），而按值传入的 builder 在执行时
 * **`this` 并不是本组件**——`this.getTimePickerTitle`、`this.tempHour` 全是 undefined。
 * 把标题挪进 `@State` 后崩溃点只是后移一行到 `this.tempHour.toString()`，**并未解决**；
 * 真正的修法是改用 `DialogShell({...}) { this.timePickerForm() }` 尾随插槽（见 build()）。
 *
 * 当时另两个弹窗（重置确认 / 添加自定义提醒）没崩，只是因为它们在 build 期
 * 只读 `@State` 与字面量，没有 `this.<方法>()` 之类会抛异常的调用——
 * 但它们的取值其实**同样是 undefined**，属于静默错误渲染。已一并改为尾随插槽。
 */
function timePickerTitleFor(mode: string): string {
  switch (mode) {
    case 'downtimeStart':
      return '选择免打扰开始时间';
    case 'downtimeEnd':
      return '选择免打扰结束时间';
    case 'sedentaryStart':
      return '选择久坐提醒开始时间';
    case 'sedentaryEnd':
      return '选择久坐提醒结束时间';
    case 'eyeStart':
      return '选择用眼提醒开始时间';
    case 'eyeEnd':
      return '选择用眼提醒结束时间';
    case 'waterStart':
      return '选择喝水提醒开始时间';
    case 'waterEnd':
      return '选择喝水提醒结束时间';
    case 'customStart':
      return '选择自定义提醒开始时间';
    case 'customEnd':
      return '选择自定义提醒结束时间';
    default:
      return '选择睡前提醒时间';
  }
}


/**
 * 设置页面 - 作为 HdsTabs 的 TabContent 组件
 * 沉浸光感液态玻璃风格，与首页统一设计语言
 */
@Component
export struct Settings {
  @StorageProp('isDarkMode') isDarkMode: boolean = false;

  @State totalLimit: number = 180;
  @State themeMode: ThemeMode = 'system';
  /** 用户强调色（跟随设置页「强调色」选择，全应用一致） */
  @StorageLink('accentColorHex') accentColorHex: string = '#0066CC';
  /** 当前强调色配置：预设 key（blue/green…）或自定义颜色（#RRGGBB） */
  @State accentKey: string = DEFAULT_ACCENT_COLOR_KEY;
  /** 自定义强调色输入框内容（仅草稿，点「应用」才生效） */
  @State customAccentInput: string = '';
  /** 个性化称呼草稿；点「保存」才写入 prefs 与 AppStorage */
  @State nicknameDraft: string = '';
  @State personalCardOpacity: number = 0;
  @State personalCardY: number = 30;
  /**
   * 首页卡片布局：完整 9 张卡片的顺序 + 每张的显隐标记。
   * 存"完整顺序"而非"仅可见列表"，隐藏的卡片重新显示时才能回到原位。
   */
  @State homeCardConfig: HomeCardConfigEntry[] = defaultHomeCardConfig();
  @State appearanceCardOpacity: number = 0;
  @State appearanceCardY: number = 30;
  private appearanceOptions: AppearanceOption[] = APPEARANCE_OPTIONS;
  @State downtimeEnabled: boolean = true;
  @State startHour: number = 22;
  @State startMinute: number = 0;
  @State endHour: number = 7;
  @State endMinute: number = 0;
  @State isExporting: boolean = false;
  @State isImporting: boolean = false;
  @State lastBackupTime: string = '';
  @State showBackupSummary: boolean = false;
  @State backupSummaryText: string = '';

  // 入场动画
  @State limitCardOpacity: number = 0;
  @State limitCardY: number = 30;
  @State downtimeCardOpacity: number = 0;
  @State downtimeCardY: number = 30;
  @State dataCardOpacity: number = 0;
  @State dataCardY: number = 30;
  @State sleepCardOpacity: number = 0;
  @State sleepCardY: number = 30;
  @State bedtimeCardOpacity: number = 0;
  @State bedtimeCardY: number = 30;

  // 睡眠目标
  @State sleepGoalMinutes: number = 480;
  @State healthCardOpacity: number = 0;
  @State healthCardY: number = 30;

  // 睡前提醒
  @State bedtimeEnabled: boolean = false;
  @State bedtimeHour: number = 22;
  @State bedtimeMinute: number = 0;

  // 睡前使用限制（统计窗口 + 睡前提醒提前量）
  @State preSleepRestrictionEnabled: boolean = false;
  @State preSleepRestrictionMinutes: number = 60;
  @State bedtimeOffsetMinutes: number = 30;
  @State restrictionCardOpacity: number = 0;
  @State restrictionCardY: number = 30;

  // 重置确认对话框
  @State showResetConfirm: boolean = false;
  @State isResetting: boolean = false;

  // 时间选择对话框
  @State showTimePicker: boolean = false;
  @State tempHour: number = 22;
  @State tempMinute: number = 0;
  @State timePickerMode: string = 'bedtime';
  /**
   * 弹窗标题，**在 `openTimePicker()` 里算好存进来**，不由 `@Builder` 现调方法算。
   * 原因见文件头 `timePickerTitleFor()` 的注释：按值传给 `DialogShell` 的 builder
   * 在首次渲染时调不到组件方法，实机点「结束时间 07:00」会直接崩掉整个应用。
   */
  @State timePickerTitleText: string = '选择睡前提醒时间';

  // 健康提醒
  @State sedentaryEnabled: boolean = false;
  @State sedentaryInterval: number = 45;
  @State sedentaryStartHour: number = 9;
  @State sedentaryStartMinute: number = 0;
  @State sedentaryEndHour: number = 21;
  @State sedentaryEndMinute: number = 0;
  @State eyeEnabled: boolean = false;
  @State eyeInterval: number = 20;
  @State eyeStartHour: number = 9;
  @State eyeStartMinute: number = 0;
  @State eyeEndHour: number = 21;
  @State eyeEndMinute: number = 0;
  @State waterEnabled: boolean = false;
  @State waterInterval: number = 60;
  @State waterStartHour: number = 9;
  @State waterStartMinute: number = 0;
  @State waterEndHour: number = 21;
  @State waterEndMinute: number = 0;

  // 健康提醒自定义字段
  @State sedentaryCustomTitle: string = '';
  @State sedentaryCustomContent: string = '';
  @State sedentaryWeekdays: number[] = [...ALL_WEEKDAYS];
  @State eyeCustomTitle: string = '';
  @State eyeCustomContent: string = '';
  @State eyeWeekdays: number[] = [...ALL_WEEKDAYS];
  @State waterCustomTitle: string = '';
  @State waterCustomContent: string = '';
  @State waterWeekdays: number[] = [...ALL_WEEKDAYS];
  /**
   * 健康提醒子组件开关强制重同步令牌。
   * 子组件 Toggle 用 `$$` 双向绑定本地 @State，父级 @State 值未变化时 @Prop 不下发、
   * 子组件 @Watch 不触发，用户拨上的"开"会留在界面上（实机确认）。
   * 该字段自增即可让子组件重新读一次 isEnabled 完成拉回。
   */
  @State healthToggleRevision: number = 0;

  // 自定义提醒项
  @State customItems: CustomReminderItem[] = [];
  @State customPickerItemId: string = '';
  @State showAddCustom: boolean = false;
  @State newCustomName: string = '';

  private usageManager = HealthStateManager.getInstance().usageManager;
  private reminderService = ReminderService.getInstance();
  private healthReminderManager = HealthReminderManager.getInstance();
  private context: common.UIAbilityContext = AppStorage.get('context') as common.UIAbilityContext;
  /** 入场动画定时器句柄（aboutToDisappear 时统一清理） */
  private entranceTimerIds: number[] = [];

  /**
   * 「各 manager 已就绪」回调（与 aboutToAppear 的 onReady 配对，aboutToDisappear 解绑）。
   * 抽成稳定的字段引用而非匿名函数，才能让 offReady 摘得掉。
   */
  private readonly onManagersReady = (): void => {
    this.refreshSettings();
  };

  aboutToAppear(): void {
    // 先按当前内存态取一次（首帧必须立即有值，否则卡片空白/闪烁）。
    // ⚠️ 但这里读到的多半是各 manager 的**默认值**：EntryAbility 的 manager 初始化挂在
    // 隐私闸门与权限申请之后（实机日志：页面 13.34s 渲染完成 → 14.78s 权限返回
    // → 14.87s manager 才初始化完），而 HdsTabs 会**常驻**所有 TabContent，
    // 切走再切回不会重新触发 `aboutToAppear`，于是这一次「读到默认值」的结果会被永久烙进 UI：
    //   设备 prefs 里 sleepGoalMinutes=360（6 小时），冷启动后设置页却一直显示「8小时」，
    //   而睡前页（每次 30s 可见期轮询）显示正确的「目标 6小时」——同一设置两页不同值。
    this.refreshSettings();

    // 真正的修复：等 EntryAbility 广播「全部 manager 就绪」后再取一次（见 onReady 注释）。
    // 已排除的修法（勿重复尝试）：① `@Prop active` + Tab 切换驱动 —— 实机装包验证无效
    // （HdsTabs 的 `.onChange` 在用户点击切 Tab 时未触发）；② 500ms × 12 次的有限次重试 ——
    // 只是把竞态窗口猜成 6 秒，且用户拖滑块时可能把正在拖的值改回去。
    HealthStateManager.getInstance().onReady(this.onManagersReady);

    // 各卡片按 50ms 间隔依次入场（透明度 + 位移动画）
    this.entranceTimerIds.push(setTimeout(() => {
      this.appearanceCardOpacity = 1;
      this.appearanceCardY = 0;
    }, 100));

    this.entranceTimerIds.push(setTimeout(() => {
      this.personalCardOpacity = 1;
      this.personalCardY = 0;
    }, 120));

    this.entranceTimerIds.push(setTimeout(() => {
      this.limitCardOpacity = 1;
      this.limitCardY = 0;
    }, 130));

    this.entranceTimerIds.push(setTimeout(() => {
      this.sleepCardOpacity = 1;
      this.sleepCardY = 0;
    }, 150));

    this.entranceTimerIds.push(setTimeout(() => {
      this.downtimeCardOpacity = 1;
      this.downtimeCardY = 0;
    }, 200));

    this.entranceTimerIds.push(setTimeout(() => {
      this.bedtimeCardOpacity = 1;
      this.bedtimeCardY = 0;
    }, 250));

    this.entranceTimerIds.push(setTimeout(() => {
      this.restrictionCardOpacity = 1;
      this.restrictionCardY = 0;
    }, 280));

    this.entranceTimerIds.push(setTimeout(() => {
      this.healthCardOpacity = 1;
      this.healthCardY = 0;
    }, 300));

    this.entranceTimerIds.push(setTimeout(() => {
      this.dataCardOpacity = 1;
      this.dataCardY = 0;
    }, 400));
  }

  // 页面消失时清理入场动画定时器，避免快速反复进出导致多段动画叠加互相覆盖
  aboutToDisappear(): void {
    // 解绑就绪回调：否则回调会一直持有本组件（manager 是单例，生命周期比页面长）
    HealthStateManager.getInstance().offReady(this.onManagersReady);
    for (let i = 0; i < this.entranceTimerIds.length; i++) {
      clearTimeout(this.entranceTimerIds[i]);
    }
    this.entranceTimerIds = [];
  }

  // 将睡眠分钟数格式化为"X小时Y分"的中文可读文案
  private formatSleepGoal(minutes: number): string {
    const hours = Math.floor(minutes / 60);
    const mins = minutes % 60;
    return mins > 0 ? `${hours}小时${mins}分` : `${hours}小时`;
  }

  /** 外观卡片右侧的当前状态摘要 */
  private getAppearanceSummaryText(): string {
    if (this.themeMode === 'light') {
      return '浅色';
    }
    if (this.themeMode === 'dark') {
      return '深色';
    }
    return this.isDarkMode ? '跟随系统（深色）' : '跟随系统（浅色）';
  }

  /**
   * 切换外观。
   *
   * 不在此处直接写 `AppStorage.set('isDarkMode', …)` —— 那会绕过系统配置，
   * 导致「界面色」与「系统实际下发的 colorMode」两处状态不一致
   * （例如系统仍处浅色、用户已选深色，下一次 `onConfigurationUpdate` 又把界面弹回去）。
   * 正确做法是 `setColorMode` → 系统异步下发新配置 → `EntryAbility.updateColorMode`
   * 写入 AppStorage → 13 个 `@StorageProp('isDarkMode')` 自动重渲染。
   * 所以本方法返回后 UI 会有一次极短的过渡，不是缺陷。
   */
  private changeThemeMode(mode: ThemeMode): void {
    if (this.themeMode === mode) {
      return;
    }
    const context = this.context;
    if (!context) {
      this.showToast('无法获取上下文，外观设置未生效');
      return;
    }
    this.themeMode = mode;
    ThemeManager.getInstance().setMode(context, mode).then((persisted: boolean) => {
      if (!persisted) {
        this.showToast('外观已切换，但未能保存，下次启动可能恢复');
      }
    }).catch(() => {
      this.showToast('外观已切换，但未能保存，下次启动可能恢复');
    });
  }

  /**
   * 切换强调色预设：持久化到 prefs，并立即刷新首页显示（首页 1s tick 会读取新色值重渲染）。
   */
  private changeAccentColor(key: string): void {
    const preset = ACCENT_COLOR_PRESETS.find((p) => p.key === key);
    if (!preset) {
      return;
    }
    const targetHex = this.isDarkMode ? preset.dark : preset.light;
    if (this.accentKey === key && this.accentColorHex === targetHex) {
      return;
    }
    const context = this.context;
    if (!context) {
      this.showToast('无法获取上下文，强调色设置未生效');
      return;
    }
    ThemeManager.getInstance().setAccentKey(context, key).then(() => {
      this.accentColorHex = targetHex;
      this.accentKey = key;
      // 从自定义色切回预设时清空输入框，避免输入框里残留一个"看起来还生效"的色值
      this.customAccentInput = '';
    }).catch(() => {
      this.showToast('强调色已切换，但未能保存，下次启动可能恢复');
    });
  }

  /**
   * 应用自定义强调色（任意 `#RRGGBB`）。
   *
   * 只校验格式，不限制色相：文本色/填充色由 `models/AccentColorMath` 按 WCAG 推导，
   * 因此用户选很浅或很深的颜色也不会出现读不清的文字或糊掉的白字。
   */
  private applyCustomAccent(): void {
    const errorText: string = describeHexInputError(this.customAccentInput);
    if (errorText.length > 0) {
      this.showToast(errorText);
      return;
    }
    const hex: string = normalizeHexColor(this.customAccentInput);
    const context = this.context;
    if (!context) {
      this.showToast('无法获取上下文，强调色设置未生效');
      return;
    }
    ThemeManager.getInstance().setAccentKey(context, hex).then((persisted: boolean) => {
      // @StorageLink('accentColorHex') 会随 ThemeManager.publishAccent() 自动更新，无需回写
      this.customAccentInput = hex;
      this.accentKey = hex;
      this.showToast(persisted ? `已应用自定义强调色 ${hex}` : `已应用 ${hex}，但未能保存，下次启动可能恢复`);
    }).catch(() => {
      this.showToast('强调色已切换，但未能保存，下次启动可能恢复');
    });
  }

  /**
   * 保存个性化称呼。
   *
   * 双写：prefs（持久化）+ AppStorage（首页 @StorageProp 订阅）。
   * 称呼只在本机保存，不参与任何统计、不上传。
   */
  private saveNickname(): void {
    const name: string = normalizeNickname(this.nicknameDraft);
    this.nicknameDraft = name;
    PreferenceManager.getInstance().setString(PREFS_KEY_NICKNAME, name);
    AppStorage.setOrCreate<string>('userNickname', name);
    this.showToast(name.length > 0 ? `已保存称呼「${name}」` : '已清除称呼');
  }

  /**
   * 首页布局列表的展示顺序：可见卡片按**当前首页顺序**在前，隐藏卡片按**布局里的位置**附在后面。
   *
   * 为什么不用 HOME_CARD_ITEMS 固定顺序：↑/↓ 实际是在"可见卡片序列"里换位，
   * 若列表仍按默认顺序显示，隐藏过卡片或调过序之后，用户看到的"上一行/下一行"
   * 就与真正被换位的对象对不上（例如隐藏了"近7天使用趋势"后，
   * 点"解锁洞察"的 ↑ 会与"免打扰提醒"换位，而不是它视觉上的上一行）。
   */
  private getHomeLayoutRows(): HomeCardItem[] {
    const visible: HomeCardItem[] = [];
    const hidden: HomeCardItem[] = [];
    for (let i = 0; i < this.homeCardConfig.length; i++) {
      const entry: HomeCardConfigEntry = this.homeCardConfig[i];
      const item: HomeCardItem | undefined =
        HOME_CARD_ITEMS.find((it: HomeCardItem) => it.id === entry.id);
      if (item === undefined) {
        continue;
      }
      if (entry.visible) {
        visible.push(item);
      } else {
        hidden.push(item);
      }
    }
    return visible.concat(hidden);
  }

  /**
   * 把某张卡片设为指定显隐状态（**按目标值写**，不做翻转）。
   *
   * 反转模型的写法（`toggleHomeCard` 读取当前值再取反）与 Toggle 的 `onChange(on)`
   * 在"拒绝隐藏最后一张"时会错位：模型没变、开关却被用户拨到了另一边，
   * 下一次点击与视觉状态相反。这里按 `visible` 目标值推进，拒绝路径也不会改变模型。
   * 同时 Toggle 在"只剩一张可见"时被禁用，正常操作根本走不到拒绝分支。
   */
  private setHomeCardVisibleTo(id: string, visible: boolean): void {
    const current: boolean = isHomeCardVisible(this.homeCardConfig, id);
    if (current === visible) {
      return;
    }
    if (!visible && visibleHomeCardCount(this.homeCardConfig) <= 1) {
      this.showToast('至少保留一张首页卡片');
      return;
    }
    this.persistHomeCardConfig(setHomeCardVisible(this.homeCardConfig, id, visible));
  }

  /**
   * 将指定卡片上移/下移一位（在**可见卡片序列**里换位）。
   * 隐藏的卡片不参与排序；已在首/末位时不动（箭头已淡化）。
   */
  private moveHomeCard(id: string, offset: number): void {
    const before: number = visibleIndexOfHomeCard(this.homeCardConfig, id);
    if (before < 0) {
      return;
    }
    const next: HomeCardConfigEntry[] = moveHomeCardInConfig(this.homeCardConfig, id, offset);
    if (visibleIndexOfHomeCard(next, id) === before) {
      return;
    }
    this.persistHomeCardConfig(next);
  }

  /** 持久化首页卡片布局；写入后立即刷新本页状态，首页按版本号门控读取新配置 */
  private persistHomeCardConfig(config: HomeCardConfigEntry[], successToast: string = '首页布局已保存'): void {
    this.homeCardConfig = config;
    const context = this.context;
    if (!context) {
      this.showToast('无法获取上下文，首页布局未保存');
      return;
    }
    ThemeManager.getInstance().setHomeCardLayout(context, config).then(() => {
      this.showToast(successToast);
    }).catch(() => {
      this.showToast('首页布局已调整，但未能保存，下次启动可能恢复');
    });
  }

  /** 一键恢复默认首页布局（顺序与显隐全部回到出厂默认） */
  private resetHomeLayout(): void {
    this.persistHomeCardConfig(defaultHomeCardConfig(), '已恢复默认首页布局');
  }


  // 从各管理器加载全部设置项（限额/睡眠目标/停用时间/睡前提醒/睡前使用限制/健康提醒/自定义项）
  private refreshSettings(): void {
    this.themeMode = ThemeManager.getInstance().getMode();
    this.totalLimit = this.usageManager.getTotalDailyLimitMinutes();
    const sleepPrefs = SleepManager.getInstance().getSleepPreferences();
    this.sleepGoalMinutes = sleepPrefs.sleepGoalMinutes;
    this.preSleepRestrictionEnabled = sleepPrefs.enablePreSleepRestriction;
    this.preSleepRestrictionMinutes = sleepPrefs.preSleepRestrictionMinutes;
    this.bedtimeOffsetMinutes = sleepPrefs.bedtimeReminderOffsetMinutes;

    const downtime = this.usageManager.getDowntimeRule();
    this.downtimeEnabled = downtime.enabled;
    this.startHour = downtime.startHour;
    this.startMinute = downtime.startMinute;
    this.endHour = downtime.endHour;
    this.endMinute = downtime.endMinute;

    const bedtimeConfig = this.reminderService.getBedtimeReminderTime();
    this.bedtimeEnabled = bedtimeConfig.enabled;
    this.bedtimeHour = bedtimeConfig.hour;
    this.bedtimeMinute = bedtimeConfig.minute;

    // 加载健康提醒配置
    const sedentaryConfig = this.healthReminderManager.getSedentaryConfig();
    this.sedentaryEnabled = sedentaryConfig.enabled;
    this.sedentaryInterval = sedentaryConfig.intervalMinutes;
    this.sedentaryStartHour = sedentaryConfig.startHour;
    this.sedentaryStartMinute = sedentaryConfig.startMinute;
    this.sedentaryEndHour = sedentaryConfig.endHour;
    this.sedentaryEndMinute = sedentaryConfig.endMinute;
    this.sedentaryCustomTitle = sedentaryConfig.title ?? '';
    this.sedentaryCustomContent = sedentaryConfig.content ?? '';
    this.sedentaryWeekdays = [...this.normalizeWeekdays(sedentaryConfig.weekdays)];

    const eyeConfig = this.healthReminderManager.getEyeConfig();
    this.eyeEnabled = eyeConfig.enabled;
    this.eyeInterval = eyeConfig.intervalMinutes;
    this.eyeStartHour = eyeConfig.startHour;
    this.eyeStartMinute = eyeConfig.startMinute;
    this.eyeEndHour = eyeConfig.endHour;
    this.eyeEndMinute = eyeConfig.endMinute;
    this.eyeCustomTitle = eyeConfig.title ?? '';
    this.eyeCustomContent = eyeConfig.content ?? '';
    this.eyeWeekdays = [...this.normalizeWeekdays(eyeConfig.weekdays)];

    const waterConfig = this.healthReminderManager.getWaterConfig();
    this.waterEnabled = waterConfig.enabled;
    this.waterInterval = waterConfig.intervalMinutes;
    this.waterStartHour = waterConfig.startHour;
    this.waterStartMinute = waterConfig.startMinute;
    this.waterEndHour = waterConfig.endHour;
    this.waterEndMinute = waterConfig.endMinute;
    this.waterCustomTitle = waterConfig.title ?? '';
    this.waterCustomContent = waterConfig.content ?? '';
    this.waterWeekdays = [...this.normalizeWeekdays(waterConfig.weekdays)];

    this.customItems = this.healthReminderManager.getCustomItems();

    // 读取最后备份/恢复时间
    this.lastBackupTime = DataBackupManager.getInstance().getLastBackupTime();

    // 读取当前强调色（按暗色模式取 light/dark 十六进制）
    this.accentColorHex = ThemeManager.getInstance().getAccentColorHex(this.isDarkMode);
    // 强调色配置值（预设 key 或自定义 #RRGGBB）与自定义输入框回显
    this.accentKey = ThemeManager.getInstance().getAccentKey();
    this.customAccentInput = ThemeManager.getInstance().getCustomAccentHex();

    // 个性化称呼（只在本机保存，不上传）
    this.nicknameDraft = PreferenceManager.getInstance().getString(PREFS_KEY_NICKNAME, '');

    // 读取首页卡片布局（可见卡片 id 列表，顺序即显示顺序）
    this.homeCardConfig = ThemeManager.getInstance().getHomeCardLayout();
  }

  private normalizeWeekdays(weekdays?: number[]): number[] {
    // 未配置或配置为空时兜底为每周七天
    return weekdays && weekdays.length > 0 ? weekdays : ALL_WEEKDAYS;
  }

  private showToast(message: string): void {
    showToastSafe(this.getUIContext(), 'SettingsPage', 'Settings', message);
  }

  /**
   * 查询系统通知总开关，**永不抛异常**。
   *
   * `isNotificationEnabledSync()` 声明了 @throws（系统服务不可用时会抛），而本页三处调用
   * 都在 async 流程里：一旦抛出，用户看到的是「点了开关没反应 + 开关停在中间态」。
   * 查询失败按「未开启」处理，让流程继续走到 requestNotificationPermission 的授权分支。
   */
  private isNotificationEnabled(): boolean {
    try {
      return notificationManager.isNotificationEnabledSync();
    } catch (err) {
      hilog.warn(0x0000, 'SettingsPage', '%{public}s', '查询通知使能状态失败：' + formatError(err));
      return false;
    }
  }

  private async updateDowntimeEnabled(enabled: boolean): Promise<void> {
    // 停用时间开关：持久化规则，并同步调度/取消停用时间常驻提醒
    this.downtimeEnabled = enabled;
    const rule = this.usageManager.getDowntimeRule();
    rule.enabled = enabled;
    this.usageManager.setDowntimeRule(rule);

    // 调度或取消停用时间提醒
    try {
      const success = await this.reminderService.scheduleDowntimeReminder(rule.startHour, rule.startMinute, enabled);
      if (!success && enabled) {
        this.downtimeEnabled = false;
        rule.enabled = false;
        this.usageManager.setDowntimeRule(rule);
        this.showToast('提醒设置失败，请检查通知权限');
        return;
      }
    } catch (err) {
      hilog.error(0x0000, 'SettingsPage', '%{public}s', 'Settings updateDowntimeEnabled failed: ' + formatError(err));
      if (enabled) {
        this.downtimeEnabled = false;
        rule.enabled = false;
        this.usageManager.setDowntimeRule(rule);
        this.showToast('提醒设置失败，请检查通知权限');
        return;
      }
    }

    this.showToast(enabled ? '已开启免打扰提醒' : '已关闭免打扰提醒');
  }

  // 睡前提醒实际触发时间 = 设定时间 − 睡前提醒提前量（跨午夜回绕）
  private getEffectiveBedtimeText(): string {
    const offset = this.bedtimeOffsetMinutes;
    const total = (this.bedtimeHour * 60 + this.bedtimeMinute - offset + 1440) % 1440;
    return formatHourMinute(Math.floor(total / 60), total % 60);
  }

  // 自定义提醒副标题：间隔 + 时段；仅在星期不是"每天"时追加上星期摘要
  private getCustomReminderSubtitle(item: CustomReminderItem): string {
    const startText = formatHourMinute(item.startHour, item.startMinute);
    const endText = formatHourMinute(item.endHour, item.endMinute);
    let text = `每 ${item.intervalMinutes} 分钟 · ${startText}-${endText}`;
    const dayText = this.getCustomReminderWeekdayText(item.weekdays);
    if (dayText.length > 0) {
      text += ` · ${dayText}`;
    }
    return text;
  }

  // 星期摘要：空集或全 7 天返回空串；工作日/周末用简称，其余逐日拼接（周X…）
  private getCustomReminderWeekdayText(weekdays: number[]): string {
    const valid: number[] = [];
    for (let i = 0; i < weekdays.length; i++) {
      const day = weekdays[i];
      if (Number.isInteger(day) && day >= 0 && day <= 6 && !valid.includes(day)) {
        valid.push(day);
      }
    }
    valid.sort((a: number, b: number) => a - b);
    if (valid.length === 0 || valid.length === 7) {
      return '';
    }
    if (valid.length === 5 && valid[0] === 1 && valid[4] === 5) {
      return '工作日';
    }
    if (valid.length === 2 && valid[0] === 0 && valid[1] === 6) {
      return '周末';
    }
    let text = '';
    for (let i = 0; i < valid.length; i++) {
      text += '周' + WEEKDAY_LABELS[valid[i]];
    }
    return text;
  }

  /**
 * 给可能挂起的系统调用加超时保护。
 *
 * ⚠️ 没有这层保护时的真实故障：`documentPicker.save()/select()` 在**系统缺少文件选择器
 * 应用**（部分模拟器镜像、未预装 DocumentsUI 的设备）时不会 reject、Promise 永远不
 * resolve，于是 `isExporting` / `isImporting` 永为 true，按钮永久卡在「导出中...」，
 * 页面所有相关操作都被 `.enabled(false)` 禁用，用户只能杀应用重启。
 * 实机复现：模拟器无 DocumentsUI 能力，点「导出数据」后 17 秒仍卡在「导出中...」。
 *
 * @param task 待执行的系统调用
 * @param timeoutMs 超时时长
 * @param label 超时提示里的操作名（导出/导入）
 * @returns 任务的 boolean 结果；**null 表示超时**
 */
  private async withTimeout(task: Promise<boolean>, timeoutMs: number, label: string): Promise<boolean | null> {
    let timerId: number = -1;
    const timeoutTask = new Promise<null>((resolve) => {
      timerId = setTimeout(() => {
        resolve(null);
      }, timeoutMs);
    });
    // 用 try/finally 清定时器：task 若 reject 会直接跳出 await，原实现只在正常返回后
    // clearTimeout，10 分钟的超时定时器会继续持有页面闭包（内存泄漏 + 迟到 toast）。
    let result: boolean | null = null;
    try {
      result = await Promise.race([task, timeoutTask]);
    } finally {
      if (timerId !== -1) {
        clearTimeout(timerId);
        timerId = -1;
      }
    }
    if (result === null) {
      hilog.warn(0x0000, 'SettingsPage', '%{public}s', `Settings ${label} timed out after ${timeoutMs}ms`);
      this.showToast(`${label}超时：系统文件选择器无响应，请重试`);
      return null;
    }
    return result;
  }

  /** 导出入口：先显示备份前摘要，用户确认后再执行真实导出 */
  private async exportData(): Promise<void> {
    const summary = DataBackupManager.getInstance().getBackupSummary();
    this.backupSummaryText = `本次备份将包含：${summary.goals} 个目标、${summary.checkins} 条打卡记录、${summary.sleepHistory} 条睡眠历史、${summary.focusHistory} 条专注记录、${summary.achievements} 个成就、${summary.unlockRecords} 条解锁记录、${summary.reminders} 条提醒配置。`;
    this.showBackupSummary = true;
  }

  /** 执行真实的导出操作（由备份前摘要弹窗的确认按钮调用） */
  private async doExportData(): Promise<void> {
    this.showBackupSummary = false;
    this.isExporting = true;
    try {
      const backup = DataBackupManager.getInstance();
      const result = await this.withTimeout(backup.exportData(this.context), PICKER_TIMEOUT_MS, '导出');
      if (result === null) {
        return;
      }
      if (result) {
        // 导出成功后立即回填「最后备份」文案：DataBackupManager 已更新该值，
        // 但本页是 HdsTabs 常驻页面，不主动刷新会一直停在「从未备份」/旧时间。
        this.lastBackupTime = backup.getLastBackupTime();
        this.showToast('数据已导出到文件');
      } else if (backup.wasLastExportFailed()) {
        // 真实 IO/序列化异常（磁盘满、无权限等）。必须与"用户取消"分开报，
        // 否则用户遇到真失败时看到「已取消导出」，会以为自己点的取消、不会重试。
        this.showToast('导出失败，请检查存储空间后重试');
      } else {
        this.showToast('已取消导出');
      }
    } catch (err) {
      hilog.error(0x0000, 'SettingsPage', '%{public}s', 'Settings exportData failed: ' + formatError(err));
      this.showToast('导出失败：' + (err instanceof Error ? err.message : '未知错误'));
    } finally {
      this.isExporting = false;
    }
  }

  private async importData(): Promise<void> {
    this.isImporting = true;
    try {
      const backup = DataBackupManager.getInstance();
      const result = await this.withTimeout(backup.importData(this.context), PICKER_TIMEOUT_MS, '导入');
      if (result === null) {
        return;
      }
      if (result) {
        this.refreshSettings();
        this.showToast('数据已成功导入');
        return;
      }
      // 三态区分：用户在文件选择器按返回 ≠ 文件格式错误。
      // 原先一律提示「文件格式不正确」，会让人误以为备份文件坏了、进而删掉它。
      //
      // 2026-10-13 实机补充：模拟器上所选文件读不到（fileIo 抛 13900002）时，
      // 原先会落到兜底分支显示「请稍后重试」——对一个读不到的文件重试毫无意义。
      // 现按真实失败原因分类，每条都给出用户下一步能做的事。
      const reason = backup.getLastImportFailure();
      if (reason === ImportFailureReason.CANCELLED) {
        this.showToast('已取消导入');
      } else if (reason === ImportFailureReason.INVALID_FILE) {
        this.showToast('导入失败：文件格式不正确，请选择本应用导出的备份文件');
      } else if (reason === ImportFailureReason.FILE_NOT_FOUND) {
        this.showToast('导入失败：读不到所选文件，它可能已被删除或移动，请重新选择');
      } else if (reason === ImportFailureReason.PERMISSION_DENIED) {
        this.showToast('导入失败：没有读取该文件的权限，请改选「下载」目录中的备份');
      } else {
        this.showToast('导入失败，请稍后重试');
      }
    } catch (err) {
      hilog.error(0x0000, 'SettingsPage', '%{public}s', 'Settings importData failed: ' + formatError(err));
      this.showToast('导入失败：' + (err instanceof Error ? err.message : '未知错误'));
    } finally {
      this.isImporting = false;
    }
  }

  /** 免打扰提醒重排失败时的回滚：恢复配置与 @State，并按原时段重排提醒 */
  private rollbackDowntimeRule(oldRule: DowntimeRule): void {
    this.usageManager.setDowntimeRule(oldRule);
    this.startHour = oldRule.startHour;
    this.startMinute = oldRule.startMinute;
    this.endHour = oldRule.endHour;
    this.endMinute = oldRule.endMinute;
    if (this.downtimeEnabled) {
      this.reminderService.scheduleDowntimeReminder(oldRule.startHour, oldRule.startMinute, true)
        .catch((err: Error) => {
          hilog.warn(0x0000, 'SettingsPage', '%{public}s',
            'Settings rollback downtime reminder failed: ' + err.message);
        });
    }
  }

  private async resetAllData(): Promise<void> {
    this.isResetting = true;
    try {
      const success = await DataBackupManager.getInstance().resetAllData();
      if (success) {
        this.refreshSettings();
        this.showToast('已重置所有数据');
      } else {
        this.showToast('重置失败，请稍后重试');
      }
    } catch (err) {
      hilog.error(0x0000, 'SettingsPage', '%{public}s', 'Settings resetAllData failed: ' + formatError(err));
      this.showToast('重置失败：' + (err instanceof Error ? err.message : '未知错误'));
    } finally {
      this.isResetting = false;
      this.showResetConfirm = false;
    }
  }

  private async toggleBedtime(enabled: boolean): Promise<void> {
    // 睡前提醒开关：先乐观更新 UI，调度失败则回滚开关状态
    this.bedtimeEnabled = enabled;
    const success = await this.scheduleBedtime(this.bedtimeHour, this.bedtimeMinute, enabled);
    if (!success) {
      this.bedtimeEnabled = !enabled;
    }
  }

  // 调度或取消睡前提醒，失败时返回 false（内部已弹出对应提示）
  private async scheduleBedtime(hour: number, minute: number, enabled: boolean): Promise<boolean> {
    try {
      if (enabled) {
        // 确保通知总开关已开启（常驻提醒通知依赖它）
        if (!this.isNotificationEnabled()) {
          const granted = await PermissionService.getInstance().requestNotificationPermission(this.context);
          if (!granted) {
            this.showToast('需要先在系统设置中开启通知才能设置睡前提醒');
            return false;
          }
        }
      }

      const success = await this.reminderService.scheduleBedtimeReminder(hour, minute, enabled);
      if (success) {
        if (enabled) {
          this.showToast(`已开启睡前提醒（${formatHourMinute(hour, minute)}）`);
        } else {
          this.showToast('已关闭睡前提醒');
        }
      } else {
        this.showToast('设置失败，请稍后重试');
      }
      return success;
    } catch (err) {
      hilog.error(0x0000, 'SettingsPage', '%{public}s', 'Settings scheduleBedtime failed: ' + formatError(err));
      const errorMsg = err instanceof Error ? err.message : '设置失败，请稍后重试';
      if (errorMsg.includes('权限')) {
        this.showToast('需要后台提醒权限，请在系统设置中授予权限');
      } else {
        this.showToast(errorMsg);
      }
      return false;
    }
  }

  private async saveTimePicker(): Promise<void> {
    // 时间选择器确定：按模式分发保存（睡前/停用时间/健康提醒时段/自定义提醒时段）
    if (this.timePickerMode === 'bedtime') {
      const oldHour = this.bedtimeHour;
      const oldMinute = this.bedtimeMinute;
      this.bedtimeHour = this.tempHour;
      this.bedtimeMinute = this.tempMinute;
      const ok = await this.scheduleBedtime(this.bedtimeHour, this.bedtimeMinute, this.bedtimeEnabled);
      if (!ok) {
        this.bedtimeHour = oldHour;
        this.bedtimeMinute = oldMinute;
        this.showTimePicker = false;
        return;
      }
      // scheduleBedtime 内部已提示当前睡前提醒状态（含新时间），此处不重复 toast
    } else if (this.timePickerMode === 'downtimeStart' || this.timePickerMode === 'downtimeEnd') {
      const rule = this.usageManager.getDowntimeRule();
      // 改时间前先留存旧规则：重排提醒失败时必须把配置与 @State 一起回滚，
      // 否则首页显示新时段、通知栏却仍按旧时间响（或干脆没有）。
      // 与上方 bedtime 分支、健康提醒分支的 oldConfig 回滚保持同一口径。
      const oldRule = this.usageManager.getDowntimeRule();
      if (this.timePickerMode === 'downtimeStart') {
        rule.startHour = this.tempHour;
        rule.startMinute = this.tempMinute;
      } else {
        rule.endHour = this.tempHour;
        rule.endMinute = this.tempMinute;
      }
      this.usageManager.setDowntimeRule(rule);
      this.startHour = rule.startHour;
      this.startMinute = rule.startMinute;
      this.endHour = rule.endHour;
      this.endMinute = rule.endMinute;

      if (this.downtimeEnabled) {
        try {
          const success = await this.reminderService.scheduleDowntimeReminder(rule.startHour, rule.startMinute, true);
          if (!success) {
            this.rollbackDowntimeRule(oldRule);
            this.showToast('提醒设置失败，已恢复原时段');
            this.showTimePicker = false;
            return;
          }
        } catch (err) {
          hilog.error(0x0000, 'SettingsPage', '%{public}s', 'Settings saveTimePicker downtime failed: ' + formatError(err));
          this.rollbackDowntimeRule(oldRule);
          this.showToast('提醒设置失败，已恢复原时段');
          this.showTimePicker = false;
          return;
        }
      }

      // ⚠️ 起止相同时必须改口播，否则用户会读到「已更新免打扰提醒为 22:00 — 22:00」，
      // 而它的真实语义是**全天免打扰**（见 UsageStatsManager.isInDowntime）。
      // 用户多半是把某个时刻误设成了起止相同，这里明确说明才不会以为程序出错。
      // 分隔符与首页 `22:00 — 07:00` 一致（原为 ASCII 连字符，两处写法不同）
      if (this.startHour === this.endHour && this.startMinute === this.endMinute) {
        this.showToast('开始与结束时间相同，免打扰提醒已设为全天');
      } else {
        this.showToast(`已更新免打扰提醒为 ${formatHourMinute(this.startHour, this.startMinute)} — ${formatHourMinute(this.endHour, this.endMinute)}`);
      }
    } else if (this.timePickerMode === 'customStart' || this.timePickerMode === 'customEnd') {
      await this.saveCustomTimePicker();
    } else {
      const config = this.reminderConfigForMode(this.timePickerMode);
      const oldConfig: HealthReminderConfig = {
        enabled: config.enabled,
        intervalMinutes: config.intervalMinutes,
        startHour: config.startHour,
        startMinute: config.startMinute,
        endHour: config.endHour,
        endMinute: config.endMinute,
        title: config.title,
        content: config.content,
        weekdays: config.weekdays ? [...config.weekdays] : undefined
      };
      const isStart = this.timePickerMode.endsWith('Start');
      if (isStart) {
        config.startHour = this.tempHour;
        config.startMinute = this.tempMinute;
      } else {
        config.endHour = this.tempHour;
        config.endMinute = this.tempMinute;
      }
      const ok = await this.reminderSetConfigForMode(this.timePickerMode, config);
      if (!ok) {
        // 发布失败：回滚到原时段并重新保存，避免已开启的提醒被取消后未重新发布
        await this.reminderSetConfigForMode(this.timePickerMode, oldConfig);
        this.syncReminderStateVars(this.timePickerMode);
        this.showToast('提醒时段更新失败，请检查提醒权限后重试');
      } else {
        this.syncReminderStateVars(this.timePickerMode);
        this.showToast(`已更新提醒时段：${formatHourMinute(config.startHour, config.startMinute)} - ${formatHourMinute(config.endHour, config.endMinute)}`);
      }
    }
    this.showTimePicker = false;
  }

  private cancelTimePicker(): void {
    this.showTimePicker = false;
  }

  // 打开时间选择器：按模式预填当前值作为初始值
  private openTimePicker(mode: string): void {
    this.timePickerMode = mode;
    this.timePickerTitleText = timePickerTitleFor(mode);
    if (mode === 'bedtime') {
      this.tempHour = this.bedtimeHour;
      this.tempMinute = this.bedtimeMinute;
    } else if (mode === 'downtimeStart' || mode === 'downtimeEnd') {
      const downtime = this.usageManager.getDowntimeRule();
      this.tempHour = mode === 'downtimeStart' ? downtime.startHour : downtime.endHour;
      this.tempMinute = mode === 'downtimeStart' ? downtime.startMinute : downtime.endMinute;
    } else {
      const config = this.reminderConfigForMode(mode);
      this.tempHour = mode.endsWith('End') ? config.endHour : config.startHour;
      this.tempMinute = mode.endsWith('End') ? config.endMinute : config.startMinute;
    }
    this.showTimePicker = true;
  }

  private reminderKeyForMode(mode: string): string {
    // 由时间选择模式名推导健康提醒类型键（sedentary/eye/water，空表示非健康提醒）
    if (mode.startsWith('sedentary')) return 'sedentary';
    if (mode.startsWith('eye')) return 'eye';
    if (mode.startsWith('water')) return 'water';
    return '';
  }

  // 取对应类型的健康提醒配置对象
  private reminderConfigForMode(mode: string): HealthReminderConfig {
    const key = this.reminderKeyForMode(mode);
    if (key === 'sedentary') return this.healthReminderManager.getSedentaryConfig();
    if (key === 'eye') return this.healthReminderManager.getEyeConfig();
    return this.healthReminderManager.getWaterConfig();
  }

  private async reminderSetConfigForMode(mode: string, config: HealthReminderConfig): Promise<boolean> {
    // 将配置对象写入对应类型的提醒管理器，返回发布是否成功
    const key = this.reminderKeyForMode(mode);
    if (key === 'sedentary') return await this.healthReminderManager.setSedentaryConfig(config);
    else if (key === 'eye') return await this.healthReminderManager.setEyeConfig(config);
    else return await this.healthReminderManager.setWaterConfig(config);
  }

  // 保存成功后把管理器中最新时段同步回本页状态变量
  private syncReminderStateVars(mode: string): void {
    const key = this.reminderKeyForMode(mode);
    const config = this.reminderConfigForMode(mode);
    if (key === 'sedentary') {
      this.sedentaryStartHour = config.startHour;
      this.sedentaryStartMinute = config.startMinute;
      this.sedentaryEndHour = config.endHour;
      this.sedentaryEndMinute = config.endMinute;
    } else if (key === 'eye') {
      this.eyeStartHour = config.startHour;
      this.eyeStartMinute = config.startMinute;
      this.eyeEndHour = config.endHour;
      this.eyeEndMinute = config.endMinute;
    } else if (key === 'water') {
      this.waterStartHour = config.startHour;
      this.waterStartMinute = config.startMinute;
      this.waterEndHour = config.endHour;
      this.waterEndMinute = config.endMinute;
    }
  }

  // ========== 健康提醒 ==========

  // 根据本页当前 UI 状态 + 管理器原始配置，组装一份完整的健康提醒配置
  private buildReminderConfig(key: string): HealthReminderConfig {
    if (key === 'sedentary') {
      const c = this.healthReminderManager.getSedentaryConfig();
      c.enabled = this.sedentaryEnabled;
      c.intervalMinutes = this.sedentaryInterval;
      c.startHour = this.sedentaryStartHour;
      c.startMinute = this.sedentaryStartMinute;
      c.endHour = this.sedentaryEndHour;
      c.endMinute = this.sedentaryEndMinute;
      c.title = this.sedentaryCustomTitle || undefined;
      c.content = this.sedentaryCustomContent || undefined;
      c.weekdays = [...this.sedentaryWeekdays];
      return c;
    }
    if (key === 'eye') {
      const c = this.healthReminderManager.getEyeConfig();
      c.enabled = this.eyeEnabled;
      c.intervalMinutes = this.eyeInterval;
      c.startHour = this.eyeStartHour;
      c.startMinute = this.eyeStartMinute;
      c.endHour = this.eyeEndHour;
      c.endMinute = this.eyeEndMinute;
      c.title = this.eyeCustomTitle || undefined;
      c.content = this.eyeCustomContent || undefined;
      c.weekdays = [...this.eyeWeekdays];
      return c;
    }
    const c = this.healthReminderManager.getWaterConfig();
    c.enabled = this.waterEnabled;
    c.intervalMinutes = this.waterInterval;
    c.startHour = this.waterStartHour;
    c.startMinute = this.waterStartMinute;
    c.endHour = this.waterEndHour;
    c.endMinute = this.waterEndMinute;
    c.title = this.waterCustomTitle || undefined;
    c.content = this.waterCustomContent || undefined;
    c.weekdays = [...this.waterWeekdays];
    return c;
  }

  private async saveReminderImmediate(key: string): Promise<boolean> {
    // 用当前 UI 状态立即保存提醒配置（含发布常驻通知）
    return await this.reminderSetConfigForMode(key, this.buildReminderConfig(key));
  }

  private setHealthEnabled(key: string, enabled: boolean): void {
    if (key === 'sedentary') this.sedentaryEnabled = enabled;
    else if (key === 'eye') this.eyeEnabled = enabled;
    else this.waterEnabled = enabled;
  }

  /** 强制把子组件 Toggle 的可视状态拉回与父级一致（父级值未变化时 @Prop 不会下发） */
  private forceSyncToggleState(key: string, enabled: boolean): void {
    this.setHealthEnabled(key, enabled);
    // 父级写同值不产生 @Prop 下发，且同一帧内的多次写入会被 ArkUI 合批折叠，
    // "先写相反值再写回"的技巧因此完全无效（2026-10-02 实机确认：Toggle 仍停在开启）。
    // 改为自增 revision，让子组件 @Watch 在下一帧必然重新读一次 isEnabled 完成拉回。
    this.healthToggleRevision++;
  }

  private getHealthInterval(key: string): number {
    if (key === 'sedentary') return this.sedentaryInterval;
    if (key === 'eye') return this.eyeInterval;
    return this.waterInterval;
  }

  private setHealthInterval(key: string, value: number): void {
    if (key === 'sedentary') this.sedentaryInterval = value;
    else if (key === 'eye') this.eyeInterval = value;
    else this.waterInterval = value;
  }

  /**
   * 先提交 UI 变更并保存提醒，发布失败时回滚并重新保存，
   * 避免出现“开关/数值已变更、但系统内提醒已取消且未重新发布”的悬挂状态
   */
  private async saveHealthChangeWithRollback(key: string, commit: () => void, rollback: () => void, successToast: string): Promise<void> {
    commit();
    const ok = await this.saveReminderImmediate(key);
    if (!ok) {
      rollback();
      await this.saveReminderImmediate(key);
      const reason = this.healthReminderManager.getLastPublishError();
      this.showToast(reason ? `设置失败：${reason}` : '设置失败，请检查提醒权限后重试');
      return;
    }
    if (successToast) {
      this.showToast(successToast);
    }
  }

  private async toggleHealthReminder(key: string, enabled: boolean, label: string): Promise<void> {
    try {
      if (enabled) {
        // 确保通知总开关已开启（常驻提醒通知依赖它）
        if (!this.isNotificationEnabled()) {
          const granted = await PermissionService.getInstance().requestNotificationPermission(this.context);
          if (!granted) {
            // 同步开关状态并持久化，避免子组件开关停留在"已开启"而实际未生效。
            // 此处父级状态本就是 false，直接赋值不会触发子组件 @Watch，需强制翻转一次
            this.forceSyncToggleState(key, false);
            await this.saveReminderImmediate(key);
            this.showToast(`开启${label}提醒需要先在系统设置中开启通知`);
            return;
          }
        }
      }
      // 提交变更并保存；发布失败时由 saveHealthChangeWithRollback 回滚 UI 并恢复原配置
      await this.saveHealthChangeWithRollback(
        key,
        () => this.setHealthEnabled(key, enabled),
        () => this.setHealthEnabled(key, !enabled),
        enabled ? `已开启${label}提醒` : `已关闭${label}提醒`
      );
    } catch (err) {
      // 异常兜底：强制关回并持久化，避免开关状态与实际调度不一致
      hilog.error(0x0000, 'SettingsPage', '%{public}s', `Settings toggleHealthReminder failed: ${formatError(err)}`);
      this.forceSyncToggleState(key, false);
      await this.saveReminderImmediate(key);
      this.showToast(`${enabled ? '开启' : '关闭'}${label}提醒失败，请稍后重试`);
    }
  }

  // 更新健康提醒间隔（分钟），失败时回滚间隔值
  private async selectHealthInterval(key: string, interval: number): Promise<void> {
    const prev = this.getHealthInterval(key);
    await this.saveHealthChangeWithRollback(
      key,
      () => this.setHealthInterval(key, interval),
      () => this.setHealthInterval(key, prev),
      `提醒间隔已更新为${interval}分钟`
    );
  }

  private getWeekdaysArray(key: string): number[] {
    if (key === 'sedentary') return this.sedentaryWeekdays;
    if (key === 'eye') return this.eyeWeekdays;
    return this.waterWeekdays;
  }

  private setWeekdaysArray(key: string, arr: number[]): void {
    if (key === 'sedentary') this.sedentaryWeekdays = arr;
    else if (key === 'eye') this.eyeWeekdays = arr;
    else this.waterWeekdays = arr;
  }

  private async toggleHealthWeekday(key: string, day: number): Promise<void> {
    // 切换某天是否参与该提醒（至少保留一天），失败时回滚星期数组
    const prev = [...this.getWeekdaysArray(key)];
    const next = [...prev];
    const idx = next.indexOf(day);
    if (idx >= 0) {
      if (next.length <= 1) {
        this.showToast('至少保留一天');
        return;
      }
      next.splice(idx, 1);
    } else {
      next.push(day);
    }
    next.sort((a: number, b: number) => a - b);
    await this.saveHealthChangeWithRollback(
      key,
      () => this.setWeekdaysArray(key, next),
      () => this.setWeekdaysArray(key, prev),
      ''
    );
  }

  private async changeHealthTitle(key: string, value: string): Promise<void> {
    // 修改提醒标题，失败时回滚原标题
    const prev = key === 'sedentary' ? this.sedentaryCustomTitle
      : key === 'eye' ? this.eyeCustomTitle : this.waterCustomTitle;
    await this.saveHealthChangeWithRollback(
      key,
      () => {
        if (key === 'sedentary') this.sedentaryCustomTitle = value;
        else if (key === 'eye') this.eyeCustomTitle = value;
        else this.waterCustomTitle = value;
      },
      () => {
        if (key === 'sedentary') this.sedentaryCustomTitle = prev;
        else if (key === 'eye') this.eyeCustomTitle = prev;
        else this.waterCustomTitle = prev;
      },
      ''
    );
  }

  private async changeHealthContent(key: string, value: string): Promise<void> {
    // 修改提醒内容，失败时回滚原内容
    const prev = key === 'sedentary' ? this.sedentaryCustomContent
      : key === 'eye' ? this.eyeCustomContent : this.waterCustomContent;
    await this.saveHealthChangeWithRollback(
      key,
      () => {
        if (key === 'sedentary') this.sedentaryCustomContent = value;
        else if (key === 'eye') this.eyeCustomContent = value;
        else this.waterCustomContent = value;
      },
      () => {
        if (key === 'sedentary') this.sedentaryCustomContent = prev;
        else if (key === 'eye') this.eyeCustomContent = prev;
        else this.waterCustomContent = prev;
      },
      ''
    );
  }

  // ========== 自定义提醒项 ==========

  private async refreshCustomItems(): Promise<void> {
    // 重新加载自定义提醒列表
    this.customItems = this.healthReminderManager.getCustomItems();
  }

/**
   * 保存自定义提醒变更，发布失败时回滚并重新保存，
   * 与内置提醒 saveHealthChangeWithRollback 同策略（修复"开关已开但提醒未生效"的悬挂态）
   */
  private async saveCustomChangeWithRollback(
    id: string,
    commit: (item: CustomReminderItem) => void,
    rollback: (item: CustomReminderItem) => void,
    successToast: string
  ): Promise<boolean> {
    const item = this.healthReminderManager.getCustomItem(id);
    if (!item) {
      return false;
    }
    commit(item);
    const ok = await this.healthReminderManager.updateCustomItem(item);
    if (!ok) {
      rollback(item);
      await this.healthReminderManager.updateCustomItem(item);
      await this.refreshCustomItems();
      // 回滚后配置值与渲染前完全相同 → ForEach key 未变、子组件不会重建，
      // 仍停留在用户拨上的"开"。自增 revision 强制子组件重读 isEnabled（与内置提醒同因同解）。
      this.healthToggleRevision++;
      const reason = this.healthReminderManager.getLastPublishError();
      this.showToast(reason ? `设置失败：${reason}` : '设置失败，请检查提醒权限后重试');
      return false;
    }
    await this.refreshCustomItems();
    if (successToast) {
      this.showToast(successToast);
    }
    return true;
  }

  private async toggleCustomItem(id: string, enabled: boolean): Promise<void> {
    const item = this.healthReminderManager.getCustomItem(id);
    if (!item) return;
    // 与内置提醒（toggleHealthReminder）同一口径：开启前先确保通知总开关已开启。
    // 原实现直接提交，开启时若系统通知被关，只会弹一句「Notification disabled」的失败 toast，
    // 用户既不知道要去哪开，也没有机会在这次交互里授权。
    if (enabled && !this.isNotificationEnabled()) {
      const granted = await PermissionService.getInstance().requestNotificationPermission(this.context);
      if (!granted) {
        // 与内置提醒同因同解：父级 enabled 一直是 false→false，@Prop 不下发、子组件
        // @Watch 不触发；ForEach key 在 enabled 未变时也不变 ⇒ 开关会停在"开"。
        // 必须自增 revision 强制子组件重读 isEnabled。
        this.healthToggleRevision++;
        this.refreshCustomItems();
        this.showToast(`开启「${item.name}」提醒需要先在系统设置中开启通知`);
        return;
      }
    }
    await this.saveCustomChangeWithRollback(
      id,
      (cur: CustomReminderItem) => { cur.enabled = enabled; },
      (cur: CustomReminderItem) => { cur.enabled = !enabled; },
      enabled ? `已开启「${item.name}」提醒` : `已关闭「${item.name}」提醒`
    );
  }

  private async selectCustomItemInterval(id: string, interval: number): Promise<void> {
    const item = this.healthReminderManager.getCustomItem(id);
    if (!item) return;
    await this.saveCustomChangeWithRollback(
      id,
      (cur: CustomReminderItem) => { cur.intervalMinutes = interval; },
      (cur: CustomReminderItem) => { cur.intervalMinutes = item.intervalMinutes; },
      `「${item.name}」间隔已更新为${interval}分钟`
    );
  }

  private async toggleCustomItemWeekday(id: string, day: number): Promise<void> {
    const item = this.healthReminderManager.getCustomItem(id);
    if (!item) return;
    const prevWeekdays: number[] = [...item.weekdays];
    const idx = item.weekdays.indexOf(day);
    if (idx >= 0) {
      if (item.weekdays.length <= 1) {
        this.showToast('至少保留一天');
        return;
      }
      item.weekdays.splice(idx, 1);
    } else {
      item.weekdays.push(day);
    }
    item.weekdays.sort((a: number, b: number) => a - b);
    await this.saveCustomChangeWithRollback(
      id,
      (cur: CustomReminderItem) => { cur.weekdays = [...item.weekdays]; },
      (cur: CustomReminderItem) => { cur.weekdays = [...prevWeekdays]; },
      ''
    );
  }

  private async changeCustomItemTitle(id: string, value: string): Promise<void> {
    const item = this.healthReminderManager.getCustomItem(id);
    if (!item) return;
    await this.saveCustomChangeWithRollback(
      id,
      (cur: CustomReminderItem) => { cur.name = value; },
      (cur: CustomReminderItem) => { cur.name = item.name; },
      ''
    );
  }

  private async changeCustomItemContent(id: string, value: string): Promise<void> {
    const item = this.healthReminderManager.getCustomItem(id);
    if (!item) return;
    await this.saveCustomChangeWithRollback(
      id,
      (cur: CustomReminderItem) => { cur.content = value; },
      (cur: CustomReminderItem) => { cur.content = item.content; },
      ''
    );
  }

  private async removeCustomItem(id: string): Promise<void> {
    const item = this.healthReminderManager.getCustomItem(id);
    if (!item) return;
    await this.healthReminderManager.removeCustomItem(id);
    await this.refreshCustomItems();
    this.showToast(`已删除「${item.name}」提醒`);
  }

  private openCustomTimePicker(id: string, isStart: boolean): void {
    const item = this.healthReminderManager.getCustomItem(id);
    if (!item) return;
    this.timePickerMode = isStart ? 'customStart' : 'customEnd';
    this.timePickerTitleText = timePickerTitleFor(this.timePickerMode);
    this.customPickerItemId = id;
    this.tempHour = isStart ? item.startHour : item.endHour;
    this.tempMinute = isStart ? item.startMinute : item.endMinute;
    this.showTimePicker = true;
  }

private async saveCustomTimePicker(): Promise<void> {
    const item = this.healthReminderManager.getCustomItem(this.customPickerItemId);
    if (item) {
      const isStart = this.timePickerMode === 'customStart';
      const prevHour = isStart ? item.startHour : item.endHour;
      const prevMinute = isStart ? item.startMinute : item.endMinute;
      const ok = await this.saveCustomChangeWithRollback(
        this.customPickerItemId,
        (cur: CustomReminderItem) => {
          if (isStart) {
            cur.startHour = this.tempHour;
            cur.startMinute = this.tempMinute;
          } else {
            cur.endHour = this.tempHour;
            cur.endMinute = this.tempMinute;
          }
        },
        (cur: CustomReminderItem) => {
          if (isStart) {
            cur.startHour = prevHour;
            cur.startMinute = prevMinute;
          } else {
            cur.endHour = prevHour;
            cur.endMinute = prevMinute;
          }
        },
        ''
      );
      if (!ok) {
        this.showTimePicker = false;
        return;
      }
      this.showToast('已更新提醒时段');
    }
    this.showTimePicker = false;
  }

  private async addCustomReminder(): Promise<void> {
    const name = this.newCustomName.trim();
    if (!name) {
      this.showToast('请输入提醒名称');
      return;
    }
    const item = await this.healthReminderManager.addCustomItem(name);
    if (item) {
      await this.refreshCustomItems();
      this.showToast(`已添加「${item.name}」提醒`);
    }
    this.newCustomName = '';
    this.showAddCustom = false;
  }

  build() {
    Stack() {
      // 全局多彩液态渐变背景（与首页统一）
      Column().width('100%').height('100%')
        .linearGradient({
          direction: GradientDirection.Bottom,
          colors: ThemeColor.gradient(this.isDarkMode)
        })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      // 随手机姿态变化的环境光晕
      AmbientLight()

      // ⚠️ 2026-10-14：这里曾做过「常规/提醒/数据」分段改造，现已整体回退。
      // 原因：分段切换的 onClick 点了不触发（在 switchSection 里打的 hilog 埋点
      // 实机一条都没输出，说明事件根本没进），而卡片是按分段用 if 守卫的，
      // 于是页面永远停在第一段，后 4 张（睡前提醒/睡前使用限制/健康提醒/数据管理）
      // **无法访问** —— 睡前提醒开不了、健康提醒改不了、数据导不出。
      // 分段是体验优化，不能让设置页长时间不可用，故先恢复线性排列。
      // 根因未查明（ArkUI 对兄弟 Text + ForEach 的 onClick 命中存疑），
      // 若日后重做，务必先在小范围验证切段真的生效，再加卡片守卫。
      Scroll() {
        Column({ space: 24 }) {
          // 外观卡片：深浅色模式。
          // 改造前应用只能跟随系统，用户必须离开应用去系统设置才能改；此处补上应用内入口。
          // 三个选项用 chip 而非 Toggle —— 它是三选一的单选，不该伪装成开关。
          GlassCard({ delay: 0, cardOpacity: this.appearanceCardOpacity, cardTranslateY: this.appearanceCardY }) {
            Column({ space: 14 }) {
              Row() {
                Text('外观').fontSize(17).fontWeight(FontWeight.Medium)
                  .fontColor(ThemeColor.label(this.isDarkMode))
                  .alignSelf(ItemAlign.Start)
                Blank()
                Text(this.getAppearanceSummaryText())
                  .fontSize(15)
                  .fontColor(ThemeColor.accentColor(this.accentColorHex, this.isDarkMode))
                  .fontWeight(FontWeight.Medium)
              }.width('100%')

              Row({ space: 10 }) {
                ForEach(this.appearanceOptions, (opt: AppearanceOption) => {
                  Text(opt.label)
                    .fontSize(14)
                    .fontWeight(this.themeMode === opt.value ? FontWeight.Medium : FontWeight.Normal)
                    .fontColor(this.themeMode === opt.value
                      ? ThemeColor.accentColor(this.accentColorHex, this.isDarkMode)
                      : ThemeColor.labelSecondary(this.isDarkMode))
                    .textAlign(TextAlign.Center)
                    .layoutWeight(1)
                    .padding({ top: 10, bottom: 10 })
                    .backgroundColor(this.themeMode === opt.value
                      ? ThemeColor.accentColorTint(this.accentColorHex, 0.14, this.isDarkMode)
                      : ThemeColor.inputBg(this.isDarkMode))
                    .borderRadius(12)
                    .accessibilityLevel('yes')
                    .accessibilitySelected(this.themeMode === opt.value)
                    .accessibilityText(`${opt.label}${this.themeMode === opt.value ? '，已选择' : ''}`)
                    .onClick(() => {
                      this.changeThemeMode(opt.value);
                    })
                }, (opt: AppearanceOption) => opt.value)
              }.width('100%')

              Text('跟随系统会随手机的外观设置自动切换')
                .fontSize(11)
                .fontColor(ThemeColor.systemGray(this.isDarkMode))
                .alignSelf(ItemAlign.Start)
                .lineHeight(16)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }

          // 强调色设置卡片：可从六种预设色中选其一，影响全应用按钮、进度条、标题等
          GlassCard({ delay: 0, cardOpacity: this.appearanceCardOpacity, cardTranslateY: this.appearanceCardY }) {
            Column({ space: 14 }) {
              Row() {
                Text('强调色').fontSize(17).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
                  .alignSelf(ItemAlign.Start)
                Blank()
                Column()
                  .width(20).height(20).borderRadius(10)
                  .backgroundColor(ThemeColor.accentColor(this.accentColorHex, this.isDarkMode))
                  .border({ width: 1, color: ThemeColor.separator(this.isDarkMode) })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)

              Row({ space: 8 }) {
                ForEach(ACCENT_COLOR_PRESETS, (preset: AccentColorPreset) => {
                  Column({ space: 6 }) {
                    Column()
                      .width(32).height(32).borderRadius(16)
                      .backgroundColor(this.isDarkMode ? preset.dark : preset.light)
                      // 选中环用中性色，避免与同色填充糊在一起看不出选中
                      .border({ width: this.accentKey === preset.key ? 3 : 0, color: ThemeColor.label(this.isDarkMode) })
                      .accessibilityLevel('yes')
                      .accessibilitySelected(this.accentKey === preset.key)
                      .accessibilityText(`${preset.label}${this.accentKey === preset.key ? '，已选择' : ''}`)
                    Text(preset.label).fontSize(11)
                      .fontColor(this.accentKey === preset.key
                        ? ThemeColor.accentColor(this.accentColorHex, this.isDarkMode)
                        : ThemeColor.labelSecondary(this.isDarkMode))
                  }
                  // 整个「色块 + 标签」都可点：此前只有圆点挂了 onClick，点标签完全无反应
                  .onClick(() => { this.changeAccentColor(preset.key); })
                }, (preset: AccentColorPreset) => preset.key)
              }.width('100%')

              // 自定义强调色：6 个预设装不下的个人偏好（品牌色/习惯色）
              Row({ space: 8 }) {
                Column()
                  .width(28).height(28).borderRadius(14)
                  .backgroundColor(normalizeHexColor(this.customAccentInput).length > 0
                    ? normalizeHexColor(this.customAccentInput)
                    : ThemeColor.inputBg(this.isDarkMode))
                  .border({ width: 1, color: ThemeColor.separator(this.isDarkMode) })
                TextInput({ placeholder: '#4A47CC', text: $$this.customAccentInput })
                  .layoutWeight(1)
                  .height(38)
                  .fontSize(14)
                  .maxLength(7)
                  .backgroundColor(ThemeColor.inputBg(this.isDarkMode))
                  .borderRadius(10)
                  .fontColor(ThemeColor.label(this.isDarkMode))
                  .placeholderColor(ThemeColor.systemGray(this.isDarkMode))
                  .onSubmit(() => { this.applyCustomAccent(); })
                  .accessibilityText('自定义强调色，输入 #RRGGBB 颜色值')
                Button('应用')
                  .fontSize(14).height(38)
                  .fontColor(IOS26_WHITE)
                  .backgroundColor(ThemeColor.accentColorFill(this.accentColorHex, this.isDarkMode))
                  .borderRadius(10).padding({ left: 16, right: 16 })
                  .onClick(() => { this.applyCustomAccent(); })
                  .accessibilityText('应用自定义强调色')
              }.width('100%').alignItems(VerticalAlign.Center)

              Text(this.accentKey.charAt(0) === '#'
                ? `当前使用自定义颜色 ${this.accentKey}`
                : '也可以输入任意 #RRGGBB 颜色，文字与按钮会自动调整为可读的对比度')
                .fontSize(11).fontColor(ThemeColor.systemGray(this.isDarkMode))
                .alignSelf(ItemAlign.Start).lineHeight(16)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }

          // 个性化称呼卡片：首页问候语会带上这个称呼
          GlassCard({ delay: 0, cardOpacity: this.personalCardOpacity, cardTranslateY: this.personalCardY }) {
            Column({ space: 14 }) {
              Row() {
                Text('个性化').fontSize(17).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
                  .alignSelf(ItemAlign.Start)
                Blank()
                Text(this.nicknameDraft.length > 0 ? this.nicknameDraft : '未设置')
                  .fontSize(15).fontColor(ThemeColor.accentColor(this.accentColorHex, this.isDarkMode))
                  .fontWeight(FontWeight.Medium)
              }.width('100%')

              Row({ space: 8 }) {
                TextInput({ placeholder: '给自己起个称呼（可留空）', text: $$this.nicknameDraft })
                  .layoutWeight(1).height(38).fontSize(14)
                  .maxLength(MAX_NICKNAME_LENGTH)
                  .backgroundColor(ThemeColor.inputBg(this.isDarkMode))
                  .borderRadius(10)
                  .fontColor(ThemeColor.label(this.isDarkMode))
                  .placeholderColor(ThemeColor.systemGray(this.isDarkMode))
                  .onSubmit(() => { this.saveNickname(); })
                  .accessibilityText('个性化称呼')
                Button('保存')
                  .fontSize(14).height(38)
                  .fontColor(IOS26_WHITE)
                  .backgroundColor(ThemeColor.accentColorFill(this.accentColorHex, this.isDarkMode))
                  .borderRadius(10).padding({ left: 16, right: 16 })
                  .onClick(() => { this.saveNickname(); })
                  .accessibilityText('保存称呼')
              }.width('100%').alignItems(VerticalAlign.Center)

              Text('首页问候会显示为「早上好，小萤」；称呼只保存在本机，不上传')
                .fontSize(11).fontColor(ThemeColor.systemGray(this.isDarkMode))
                .alignSelf(ItemAlign.Start).lineHeight(16)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }

          // 首页布局卡片：可显示/隐藏单张卡片，并上移下移调整顺序
          GlassCard({ delay: 0, cardOpacity: this.appearanceCardOpacity, cardTranslateY: this.appearanceCardY }) {
            Column({ space: 12 }) {
              Row() {
                Text('首页布局').fontSize(17).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
                  .alignSelf(ItemAlign.Start)
                Blank()
                Text(`显示 ${visibleHomeCardCount(this.homeCardConfig)}/${HOME_CARD_ITEMS.length}`)
                  .fontSize(12).fontColor(ThemeColor.labelSecondary(this.isDarkMode))
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)

              ForEach(this.getHomeLayoutRows(), (item: HomeCardItem) => {
                Row({ space: 10 }) {
                  // 显示开关：关闭时卡片从首页隐藏，但仍可在此重新开启
                  Toggle({ type: ToggleType.Switch, isOn: isHomeCardVisible(this.homeCardConfig, item.id) })
                    .selectedColor(ThemeColor.accentColor(this.accentColorHex, this.isDarkMode))
                    .width(44)
                    // 只剩一张可见卡时禁用开关：从源头避免"拨到关但模型拒绝"的视觉错位
                    .enabled(!isHomeCardVisible(this.homeCardConfig, item.id)
                      || visibleHomeCardCount(this.homeCardConfig) > 1)
                    .onChange((on: boolean) => {
                      this.setHomeCardVisibleTo(item.id, on);
                    })
                    .accessibilityText(`${item.label}，${isHomeCardVisible(this.homeCardConfig, item.id) ? '已显示' : '已隐藏'}`)

                  Column({ space: 2 }) {
                    Text(item.label).fontSize(14).fontWeight(FontWeight.Medium)
                      .fontColor(isHomeCardVisible(this.homeCardConfig, item.id)
                        ? ThemeColor.label(this.isDarkMode) : ThemeColor.systemGray(this.isDarkMode))
                    Text(isHomeCardVisible(this.homeCardConfig, item.id) ? '显示在首页' : '已隐藏')
                      .fontSize(11).fontColor(ThemeColor.labelSecondary(this.isDarkMode))
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)

                  // 上移 / 下移：只在已显示的卡片之间调整顺序。
                  // 隐藏卡片不参与排序，因此不渲染箭头（避免"点了没反应"）；
                  // 已显示但处在首/末位的卡片，箭头淡化表示不可再移。
                  if (isHomeCardVisible(this.homeCardConfig, item.id)) {
                    Text('↑').fontSize(16).fontColor(ThemeColor.labelSecondary(this.isDarkMode))
                      .width(32).height(32).textAlign(TextAlign.Center)
                      .opacity(visibleIndexOfHomeCard(this.homeCardConfig, item.id) <= 0 ? 0.3 : 1)
                      .accessibilityLevel('yes')
                      .accessibilityText(`将${item.label}上移`)
                      .onClick(() => { this.moveHomeCard(item.id, -1); })

                    Text('↓').fontSize(16).fontColor(ThemeColor.labelSecondary(this.isDarkMode))
                      .width(32).height(32).textAlign(TextAlign.Center)
                      .opacity(visibleIndexOfHomeCard(this.homeCardConfig, item.id) >= visibleHomeCardCount(this.homeCardConfig) - 1 ? 0.3 : 1)
                      .accessibilityLevel('yes')
                      .accessibilityText(`将${item.label}下移`)
                      .onClick(() => { this.moveHomeCard(item.id, 1); })
                  }
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)
                // key 必须含可见状态：否则 Toggle 内部状态不会跟随重建
                // （本项目第 4 次"UI 不刷新"家族类 bug）
                // 还必须含位置：↑/↓ 的淡化状态依赖"是否处在首/末位"，
                // 调序后位置变了但 key 不变 → 淡化状态陈旧（本项目第 5 次同族问题）
              }, (item: HomeCardItem, index: number) =>
                item.id + '_' + (isHomeCardVisible(this.homeCardConfig, item.id) ? '1' : '0') + '_' + index)

              Divider().color(ThemeColor.separator(this.isDarkMode))

              // 一键恢复默认：手工调乱之后不必逐项回忆原始顺序
              Button('恢复默认布局')
                .fontSize(13)
                .fontColor(ThemeColor.labelSecondary(this.isDarkMode))
                .backgroundColor(ThemeColor.inputBg(this.isDarkMode))
                .borderRadius(12)
                .height(38)
                .width('100%')
                .onClick(() => { this.resetHomeLayout(); })
                .accessibilityText('恢复默认首页布局')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }

        // 每日总限额卡片
        GlassCard({ delay: 0, cardOpacity: this.limitCardOpacity, cardTranslateY: this.limitCardY }) {
          Column({ space: 16 }) {
            Row() {
              Text('每日总限额').fontSize(17).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
              Blank()
              Text(this.totalLimit + ' 分钟')
                .fontSize(15).fontColor(ThemeColor.accentColor(this.accentColorHex, this.isDarkMode)).fontWeight(FontWeight.Medium)
            }.width('100%')

Slider({
              value: this.totalLimit,
              min: MIN_TOTAL_LIMIT_MINUTES,
              max: MAX_TOTAL_LIMIT_MINUTES,
              step: 15,
              style: SliderStyle.OutSet
            })
.blockColor(IOS26_BLUE)
              .trackColor(ThemeColor.accentColor(this.accentColorHex, this.isDarkMode))
              .selectedColor(IOS26_BLUE)
              .showSteps(false)
              .width('100%')
              // 无障碍：可见标签是上方独立的 Text，Slider 自身不带语义时读屏只会
              // 播报裸数值（如"180"），与"每日总限额"失去关联
              .accessibilityText(`每日总限额，当前 ${this.totalLimit} 分钟`)
              .onChange((value: number, mode: SliderChangeMode) => {
                const rounded = Math.round(value);
                this.totalLimit = rounded;
                // 拖动过程中仅更新本地状态，松手/点击结束才落盘，避免拖动过程反复写偏好存储
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  this.usageManager.setTotalDailyLimitMinutes(rounded);
                }
              })

            Row() {
              Text(`${MIN_TOTAL_LIMIT_MINUTES}分钟`).fontSize(11).fontColor(ThemeColor.systemGray(this.isDarkMode))
              Blank()
              Text(`${MAX_TOTAL_LIMIT_MINUTES / 60}小时`).fontSize(11).fontColor(ThemeColor.systemGray(this.isDarkMode))
            }.width('100%')
          }.width('100%')
        }

        // 睡眠目标卡片
        GlassCard({ delay: 50, cardOpacity: this.sleepCardOpacity, cardTranslateY: this.sleepCardY }) {
          Column({ space: 16 }) {
            Row() {
              Text('睡眠目标').fontSize(17).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
              Blank()
              Text(this.formatSleepGoal(this.sleepGoalMinutes))
                .fontSize(15).fontColor(ThemeColor.accentColor(this.accentColorHex, this.isDarkMode)).fontWeight(FontWeight.Medium)
            }.width('100%')

            Slider({
              value: this.sleepGoalMinutes,
              min: MIN_SLEEP_GOAL_MINUTES,
              max: MAX_SLEEP_GOAL_MINUTES,
              step: 30,
              style: SliderStyle.OutSet
            })
              .blockColor(IOS26_BLUE)
              .trackColor(ThemeColor.accentColor(this.accentColorHex, this.isDarkMode))
              .selectedColor(IOS26_BLUE)
.showSteps(false)
              .width('100%')
              // 无障碍：Slider 自身需带语义，否则读屏只播裸时长、与"睡眠目标"标签失去关联
              .accessibilityText(`睡眠目标，当前 ${this.formatSleepGoal(this.sleepGoalMinutes)}`)
              .onChange((value: number, mode: SliderChangeMode) => {
                const rounded = Math.round(value);
                this.sleepGoalMinutes = rounded;
                // 拖动过程中仅更新本地状态，松手/点击结束才落盘，避免拖动过程反复写偏好存储
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  SleepManager.getInstance().setSleepPreferences({ sleepGoalMinutes: rounded });
                }
              })

            Row() {
              Text(`${MIN_SLEEP_GOAL_MINUTES / 60}小时`).fontSize(11).fontColor(ThemeColor.systemGray(this.isDarkMode))
              Blank()
              Text(`${MAX_SLEEP_GOAL_MINUTES / 60}小时`).fontSize(11).fontColor(ThemeColor.systemGray(this.isDarkMode))
            }.width('100%')
          }.width('100%')
        }

        // 停用时间卡片
        GlassCard({ delay: 100, cardOpacity: this.downtimeCardOpacity, cardTranslateY: this.downtimeCardY }) {
          Column({ space: 16 }) {
            Row() {
              Column({ space: 4 }) {
                Text('免打扰提醒').fontSize(17).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
                // ⚠️ 副标题必须写明"不会阻断手机使用"：本功能**只发提醒**，
                // 没有任何限制/阻断能力 —— 标题也从「免打扰时段」改成「免打扰提醒」，
                // 配合旧名极易让用户以为到点手机会被锁住。
                Text('到点会弹通知提醒你放下手机，不会阻断手机使用')
                  .fontSize(12).fontColor(ThemeColor.systemGray(this.isDarkMode))
                  .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)

Toggle({ type: ToggleType.Switch, isOn: $$this.downtimeEnabled })
              .selectedColor(IOS26_GREEN)
              // 无障碍：标签是左侧独立 Text，Toggle 自身不带语义时读屏只播"开关"
              .accessibilityText('免打扰提醒开关')
              .onChange((isOn: boolean) => {
                this.updateDowntimeEnabled(isOn);
              })
            }.width('100%')

            if (this.downtimeEnabled) {
              Divider().color(ThemeColor.separator(this.isDarkMode))

              Row() {
                Text('开始时间').fontSize(14).fontColor(ThemeColor.label(this.isDarkMode))
                Blank()
Text(formatHourMinute(this.startHour, this.startMinute))
                  .fontSize(14).fontColor(ThemeColor.accentColor(this.accentColorHex, this.isDarkMode))
                  // 显式 32 高：值文本字号仅 14，原本隐式热区约 17vp，低于可点热区阈值
                  .height(32)
                  .padding({ left: 8 })
                  .textAlign(TextAlign.Center)
                  // 无障碍：Text + onClick 不会被读屏识别为按钮，需显式声明角色与可聚焦
                  .accessibilityLevel('yes')
                  .accessibilityText(`免打扰提醒开始时间，当前 ${formatHourMinute(this.startHour, this.startMinute)}，点击修改`)
                  .onClick(() => {
                    this.openTimePicker('downtimeStart');
                  })
              }.width('100%')

              Row() {
                Text('结束时间').fontSize(14).fontColor(ThemeColor.label(this.isDarkMode))
                Blank()
Text(formatHourMinute(this.endHour, this.endMinute))
                  .fontSize(14).fontColor(ThemeColor.accentColor(this.accentColorHex, this.isDarkMode))
                  .height(32)
                  .padding({ left: 8 })
                  .textAlign(TextAlign.Center)
                  // 无障碍：Text + onClick 不会被读屏识别为按钮，需显式声明角色与可聚焦
                  .accessibilityLevel('yes')
                  .accessibilityText(`免打扰提醒结束时间，当前 ${formatHourMinute(this.endHour, this.endMinute)}，点击修改`)
                  .onClick(() => {
                    this.openTimePicker('downtimeEnd');
                  })
              }.width('100%')
            }
          }.width('100%')
        }

        // 睡前提醒卡片
        GlassCard({ delay: 150, cardOpacity: this.bedtimeCardOpacity, cardTranslateY: this.bedtimeCardY }) {
          Column({ space: 16 }) {
            Row() {
              Column({ space: 4 }) {
                Text('睡前提醒').fontSize(17).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
                Text('按设定时间（可提前）提醒休息').fontSize(12).fontColor(ThemeColor.systemGray(this.isDarkMode))
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)

Toggle({ type: ToggleType.Switch, isOn: $$this.bedtimeEnabled })
              .selectedColor(IOS26_GREEN)
              // 无障碍：标签是左侧独立 Text，Toggle 自身不带语义时读屏只播"开关"
              .accessibilityText('睡前提醒')
              .onChange((isOn: boolean) => {
                this.toggleBedtime(isOn);
              })
            }.width('100%')

            if (this.bedtimeEnabled) {
              Divider().color(ThemeColor.separator(this.isDarkMode))

              Row() {
                Text('提醒时间').fontSize(14).fontColor(ThemeColor.label(this.isDarkMode))
                Blank()
                Button(formatHourMinute(this.bedtimeHour, this.bedtimeMinute))
                  .fontSize(14).fontColor(ThemeColor.accentColor(this.accentColorHex, this.isDarkMode))
                  .backgroundColor(ThemeColor.accentTint('0,122,255', 0.1, this.isDarkMode))
                  .height(32)
                  .onClick(() => {
                    this.openTimePicker('bedtime');
                  })
                  // 无障碍：按钮文本只有裸 HH:mm，读屏只会念"二十二点零零"，
                  // 既不知道是睡前提醒、也不知道点它是为了改时间。
                  // 同类的停用时间起止文本与健康提醒起止按钮此前已补齐，此处漏掉。
                  .accessibilityText('睡前提醒时间，当前 ' +
                    formatHourMinute(this.bedtimeHour, this.bedtimeMinute) + '，点击修改')
              }.width('100%')

              if (this.bedtimeOffsetMinutes > 0) {
                Row() {
                  Text(`实际提醒 ${this.getEffectiveBedtimeText()}（提前 ${this.bedtimeOffsetMinutes} 分钟）`)
                    .fontSize(11).fontColor(ThemeColor.systemGray(this.isDarkMode))
                }.width('100%')
              }
            }
          }.width('100%')
        }

        // 睡前使用限制卡片（自定义睡前统计窗口 + 睡前提醒提前量）
        GlassCard({ delay: 180, cardOpacity: this.restrictionCardOpacity, cardTranslateY: this.restrictionCardY }) {
          Column({ space: 16 }) {
            Row() {
              Column({ space: 4 }) {
                Text('睡前使用限制').fontSize(17).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
                Text('自定义睡前统计窗口与提醒提前量').fontSize(12).fontColor(ThemeColor.systemGray(this.isDarkMode))
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)

Toggle({ type: ToggleType.Switch, isOn: $$this.preSleepRestrictionEnabled })
              .selectedColor(IOS26_GREEN)
              // 无障碍：标签是左侧独立 Text，Toggle 自身不带语义时读屏只播"开关"
              .accessibilityText('睡前使用限制')
              .onChange((isOn: boolean) => {
                this.preSleepRestrictionEnabled = isOn;
                SleepManager.getInstance().setSleepPreferences({ enablePreSleepRestriction: isOn });
              })
            }.width('100%')

            Divider().color(ThemeColor.separator(this.isDarkMode))

            // 睡前统计窗口：仅限制开启时生效（禁用态灰显）
            Row() {
              Text('统计窗口').fontSize(14).fontColor(this.preSleepRestrictionEnabled
                ? ThemeColor.label(this.isDarkMode) : ThemeColor.systemGray(this.isDarkMode))
              Blank()
              Text(`${this.preSleepRestrictionMinutes} 分钟`).fontSize(14)
                .fontColor(this.preSleepRestrictionEnabled
                  ? ThemeColor.accentColor(this.accentColorHex, this.isDarkMode) : ThemeColor.systemGray(this.isDarkMode))
            }.width('100%')

            Slider({
              value: this.preSleepRestrictionMinutes,
              min: MIN_PRE_SLEEP_RESTRICTION_MINUTES,
              max: MAX_PRE_SLEEP_RESTRICTION_MINUTES,
              step: 15,
              style: SliderStyle.OutSet
            })
              .blockColor(IOS26_BLUE)
              .trackColor(ThemeColor.accentColor(this.accentColorHex, this.isDarkMode))
              .selectedColor(IOS26_BLUE)
.width('100%')
              .enabled(this.preSleepRestrictionEnabled)
              // 无障碍：Slider 需自带语义，读屏才能把数值与"统计窗口"关联
              .accessibilityText(`睡前统计窗口，当前 ${this.preSleepRestrictionMinutes} 分钟`)
              .onChange((value: number, mode: SliderChangeMode) => {
                const rounded = Math.round(value);
                this.preSleepRestrictionMinutes = rounded;
                // 拖动过程中仅更新本地状态，松手/点击结束才落盘
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  SleepManager.getInstance().setSleepPreferences({ preSleepRestrictionMinutes: rounded });
                }
              })

            // 睡前提醒提前量：对已开启的睡前提醒立即生效
            Row() {
              Text('提醒提前量').fontSize(14).fontColor(ThemeColor.label(this.isDarkMode))
              Blank()
              Text(`${this.bedtimeOffsetMinutes} 分钟`).fontSize(14).fontColor(ThemeColor.accentColor(this.accentColorHex, this.isDarkMode))
            }.width('100%')

            Slider({
              value: this.bedtimeOffsetMinutes,
              min: MIN_BEDTIME_OFFSET_MINUTES,
              max: MAX_BEDTIME_OFFSET_MINUTES,
              step: 5,
              style: SliderStyle.OutSet
            })
              .blockColor(IOS26_BLUE)
              .trackColor(ThemeColor.accentColor(this.accentColorHex, this.isDarkMode))
              .selectedColor(IOS26_BLUE)
.width('100%')
              // 无障碍：Slider 需自带语义，读屏才能把数值与"提醒提前量"关联
              .accessibilityText(`睡前提醒提前量，当前 ${this.bedtimeOffsetMinutes} 分钟`)
              .onChange((value: number, mode: SliderChangeMode) => {
                const rounded = Math.round(value);
                this.bedtimeOffsetMinutes = rounded;
                // 拖动过程中仅更新本地状态，松手/点击结束才落盘并重排已开启的睡前提醒
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  SleepManager.getInstance().setSleepPreferences({ bedtimeReminderOffsetMinutes: rounded });
                  if (this.bedtimeEnabled) {
                    // 刻意不 await：scheduleBedtime 内部已自行 toast 成功/失败，
                    // 滑块回调是同步路径，等它会把 onChange 拖成异步。快速连续拖动
                    // 会产生重叠调用，但每日提醒重排是幂等的（OngoingReminderScheduler
                    // 复用同一 notificationId），结果与串行执行一致。
                    this.scheduleBedtime(this.bedtimeHour, this.bedtimeMinute, true);
                  }
                }
              })

            // 详细原理解释区块
            Column({ space: 8 }) {
              Text('使用说明').fontSize(13).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
                .alignSelf(ItemAlign.Start)

              Text('「睡前使用」统计的是你每天睡前的手机亮屏时长。数据来源是手机屏幕的真实点亮时间，而非屏幕上的应用内容。')
                .fontSize(12).fontColor(ThemeColor.labelSecondary(this.isDarkMode)).lineHeight(18)

              Text('统计原理').fontSize(13).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
                .alignSelf(ItemAlign.Start)

              Text('系统会在免打扰时段的开始时刻之前划定一个统计窗口（免打扰时段未启用时以 22:00 为基准；窗口默认2小时，开启此功能后可自定义 15-180分钟），统计该窗口内所有屏幕亮起的总时长。例如免打扰时段为 22:00、窗口为 60分钟，则 21:00-22:00 期间的亮屏总时长即为睡前使用时长。')
                .fontSize(12).fontColor(ThemeColor.labelSecondary(this.isDarkMode)).lineHeight(18)

              Text('建议开启此功能并结合自身作息调整窗口大小，以获得更准确的睡前使用数据。')
                .fontSize(12).fontColor(ThemeColor.labelSecondary(this.isDarkMode)).lineHeight(18)

              Text('提醒提前量').fontSize(13).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
                .alignSelf(ItemAlign.Start)

              Text('设置睡前提醒的实际触发时间。例如睡前时间为 22:30、提前量为 30分钟，则提醒在 22:00 触发。')
                .fontSize(12).fontColor(ThemeColor.labelSecondary(this.isDarkMode)).lineHeight(18)
            }.width('100%')
          }.width('100%')
        }

        // 健康提醒卡片
        GlassCard({ delay: 200, cardOpacity: this.healthCardOpacity, cardTranslateY: this.healthCardY }) {
          Column({ space: 16 }) {
            Row() {
              Column({ space: 4 }) {
                Text('健康提醒').fontSize(17).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
                Text('把提醒拆成更容易执行的习惯块').fontSize(12).fontColor(ThemeColor.systemGray(this.isDarkMode))
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)

              Text(`${DEFAULT_REMINDER_COUNT + this.customItems.length} 项`).fontSize(12).fontColor(ThemeColor.accentColor(this.accentColorHex, this.isDarkMode))
            }.width('100%')

            Column({ space: 12 }) {
              HealthReminderControl({
                title: '久坐提醒',
                subtitle: '定时提醒起身活动',
                isEnabled: this.sedentaryEnabled,
                toggleRevision: this.healthToggleRevision,
                onToggle: (isOn: boolean) => {
                  this.toggleHealthReminder('sedentary', isOn, '久坐');
                },
                intervalOptions: [15, 30, 45, 60],
                selectedInterval: this.sedentaryInterval,
                onSelectInterval: (interval: number) => {
                  this.selectHealthInterval('sedentary', interval);
                },
                onApplyCustomInterval: (minutes: number) => {
                  this.selectHealthInterval('sedentary', minutes);
                },
                startHour: this.sedentaryStartHour,
                startMinute: this.sedentaryStartMinute,
                endHour: this.sedentaryEndHour,
                endMinute: this.sedentaryEndMinute,
                onOpenStart: () => {
                  this.openTimePicker('sedentaryStart');
                },
                onOpenEnd: () => {
                  this.openTimePicker('sedentaryEnd');
                },
                weekdays: this.sedentaryWeekdays,
                onToggleWeekday: (day: number) => {
                  this.toggleHealthWeekday('sedentary', day);
                },
                customTitle: this.sedentaryCustomTitle,
                customContent: this.sedentaryCustomContent,
                onChangeTitle: (value: string) => {
                  this.changeHealthTitle('sedentary', value);
                },
                onChangeContent: (value: string) => {
                  this.changeHealthContent('sedentary', value);
                },
                accentColor: IOS26_BLUE
              })

              HealthReminderControl({
                title: '用眼提醒',
                subtitle: '遵循 20-20-20 护眼法则',
                isEnabled: this.eyeEnabled,
                toggleRevision: this.healthToggleRevision,
                onToggle: (isOn: boolean) => {
                  this.toggleHealthReminder('eye', isOn, '用眼');
                },
                intervalOptions: [15, 20, 30],
                selectedInterval: this.eyeInterval,
                onSelectInterval: (interval: number) => {
                  this.selectHealthInterval('eye', interval);
                },
                onApplyCustomInterval: (minutes: number) => {
                  this.selectHealthInterval('eye', minutes);
                },
                startHour: this.eyeStartHour,
                startMinute: this.eyeStartMinute,
                endHour: this.eyeEndHour,
                endMinute: this.eyeEndMinute,
                onOpenStart: () => {
                  this.openTimePicker('eyeStart');
                },
                onOpenEnd: () => {
                  this.openTimePicker('eyeEnd');
                },
                weekdays: this.eyeWeekdays,
                onToggleWeekday: (day: number) => {
                  this.toggleHealthWeekday('eye', day);
                },
                customTitle: this.eyeCustomTitle,
                customContent: this.eyeCustomContent,
                onChangeTitle: (value: string) => {
                  this.changeHealthTitle('eye', value);
                },
                onChangeContent: (value: string) => {
                  this.changeHealthContent('eye', value);
                },
                accentColor: IOS26_GREEN
              })

              HealthReminderControl({
                title: '喝水提醒',
                subtitle: '定时提醒补充水分',
                isEnabled: this.waterEnabled,
                toggleRevision: this.healthToggleRevision,
                onToggle: (isOn: boolean) => {
                  this.toggleHealthReminder('water', isOn, '喝水');
                },
                intervalOptions: [30, 60, 90, 120],
                selectedInterval: this.waterInterval,
                onSelectInterval: (interval: number) => {
                  this.selectHealthInterval('water', interval);
                },
                onApplyCustomInterval: (minutes: number) => {
                  this.selectHealthInterval('water', minutes);
                },
                startHour: this.waterStartHour,
                startMinute: this.waterStartMinute,
                endHour: this.waterEndHour,
                endMinute: this.waterEndMinute,
                onOpenStart: () => {
                  this.openTimePicker('waterStart');
                },
                onOpenEnd: () => {
                  this.openTimePicker('waterEnd');
                },
                weekdays: this.waterWeekdays,
                onToggleWeekday: (day: number) => {
                  this.toggleHealthWeekday('water', day);
                },
                customTitle: this.waterCustomTitle,
                customContent: this.waterCustomContent,
                onChangeTitle: (value: string) => {
                  this.changeHealthTitle('water', value);
                },
                onChangeContent: (value: string) => {
                  this.changeHealthContent('water', value);
                },
                accentColor: IOS26_ORANGE
              })

              ForEach(this.customItems, (item: CustomReminderItem) => {
                HealthReminderControl({
                  title: item.name,
                  subtitle: this.getCustomReminderSubtitle(item),
                  isEnabled: item.enabled,
                  toggleRevision: this.healthToggleRevision,
                  onToggle: (isOn: boolean) => {
                    this.toggleCustomItem(item.id, isOn);
                  },
                  onDelete: () => {
                    this.removeCustomItem(item.id);
                  },
                  intervalOptions: [15, 30, 60, 90, 120],
                  selectedInterval: item.intervalMinutes,
                  onSelectInterval: (interval: number) => {
                    this.selectCustomItemInterval(item.id, interval);
                  },
                  onApplyCustomInterval: (minutes: number) => {
                    this.selectCustomItemInterval(item.id, minutes);
                  },
                  startHour: item.startHour,
                  startMinute: item.startMinute,
                  endHour: item.endHour,
                  endMinute: item.endMinute,
                  onOpenStart: () => {
                    this.openCustomTimePicker(item.id, true);
                  },
                  onOpenEnd: () => {
                    this.openCustomTimePicker(item.id, false);
                  },
                  weekdays: item.weekdays,
                  onToggleWeekday: (day: number) => {
                    this.toggleCustomItemWeekday(item.id, day);
                  },
                  customTitle: item.name,
                  customContent: item.content,
                  onChangeTitle: (value: string) => {
                    this.changeCustomItemTitle(item.id, value);
                  },
                  onChangeContent: (value: string) => {
                    this.changeCustomItemContent(item.id, value);
                  },
                  accentColor: IOS26_PURPLE
                })
              }, (item: CustomReminderItem) =>
                item.id + '_' + (item.enabled ? '1' : '0') + '_' + item.name + '_' + item.content + '_' +
                item.intervalMinutes + '_' + item.startHour + '_' + item.startMinute + '_' +
                item.endHour + '_' + item.endMinute + '_' + item.weekdays.join(','))

              Button('+ 添加自定义提醒')
                .fontSize(13)
                .fontColor(ThemeColor.accentColor(this.accentColorHex, this.isDarkMode))
                .backgroundColor(ThemeColor.accentTint('0,122,255', 0.08, this.isDarkMode))
                .borderRadius(12)
                .height(36)
                .width('100%')
                .onClick(() => {
                  this.newCustomName = '';
                  this.showAddCustom = true;
                })
            }.width('100%')
          }.width('100%')
        }

        // 数据管理卡片
        GlassCard({ delay: 200, cardOpacity: this.dataCardOpacity, cardTranslateY: this.dataCardY }) {
          Column({ space: 16 }) {
            Text('数据管理').fontSize(17).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
              // ArkUI Column 的 alignItems 默认 Center，本行是全宽 Column 的直接子节点，
              // 不显式左对齐就会被居中——实机实测 x 中心 660（= 屏宽中心），
              // 而同卡内按钮从 x=155 起，形成页内唯一一处两套对齐。
              .alignSelf(ItemAlign.Start)

            Row({ space: 16 }) {
              Button(this.isExporting ? '导出中...' : '导出数据')
                .fontSize(14)
                .fontColor(IOS26_WHITE)
                .backgroundColor(ThemeColor.accentColorFill(this.accentColorHex, this.isDarkMode))
                .borderRadius(12)
                .layoutWeight(1)
                .enabled(!this.isExporting)
                .onClick(() => {
                  this.exportData();
                })

              Button(this.isImporting ? '导入中...' : '导入数据')
                .fontSize(14)
                .fontColor(ThemeColor.accentColor(this.accentColorHex, this.isDarkMode))
                .backgroundColor(ThemeColor.accentTint('0,122,255', 0.1, this.isDarkMode))
                .borderRadius(12)
                .layoutWeight(1)
                .enabled(!this.isImporting)
                .onClick(() => {
                  this.importData();
                })
            }.width('100%')

            Button('重置所有数据')
              .fontSize(14)
              .fontColor(ThemeColor.accentRed(this.isDarkMode))
              .backgroundColor(ThemeColor.accentTint('255,59,48', 0.1, this.isDarkMode))
              .borderRadius(12)
              .width('100%')
              .onClick(() => {
                this.showResetConfirm = true;
              })

            // 最后备份时间
            if (this.lastBackupTime) {
              Text(`最后备份：${this.lastBackupTime}`)
                .fontSize(11)
                .fontColor(ThemeColor.labelSecondary(this.isDarkMode))
                .width('100%')
                .padding({ top: 4 })
            } else {
              Text('最后备份：从未备份')
                .fontSize(11)
                .fontColor(ThemeColor.labelSecondary(this.isDarkMode))
                .width('100%')
                .padding({ top: 4 })
            }

            // 后台统计状态：**仅在"可重试的真实故障"时**提示。
            //
            // ⚠️ 不要对「设备不支持长时任务」（code=9800005）显示这里的警告：
            // 实机复现（2026-10-13 模拟器）该错误是**永久性设备能力缺失**，重试无效、
            // 用户也没有任何设置可改，对它反复报警是纯噪音。而且此时**前台统计完全正常**，
            // 只有退到后台后才停止——报成"屏幕使用时长可能不更新"属于过度警告。
            // `isUnsupported()` 为 true 时静默降级，不在此展示（见 BackgroundServiceManager）。
            if (!BackgroundServiceManager.getInstance().isRunning() &&
              !BackgroundServiceManager.getInstance().isUnsupported()) {
              Text('后台统计未运行：' +
                (BackgroundServiceManager.getInstance().getLastError() || '长时任务未启动') +
                '。退到后台时屏幕使用时长与解锁记录可能停止更新，请保持应用在前台一段时间后重试。')
                .fontSize(11)
                .fontColor(ThemeColor.accentOrange(this.isDarkMode))
                .lineHeight(16)
                .width('100%')
                .padding({ top: 8 })
            }
          }.width('100%')
        }

        // 底部留白
          Column().height(80)
        .width('100%')
          }
        .padding({ left: 20, right: 20, top: 20 })
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
      // 注：extendSafeArea 不加在这里 —— 本页挂在 TabContent 内，Scroll 会被 HdsNavigation
      // 裁在 y=137，加了无效（实机 dump 验证）。生效点是本 build() 的根节点，
      // 它自己就挂了 expandSafeArea。

      // 重置确认对话框
      //
      // ⚠️ 三个弹窗都**直接在 build() 里调 DialogShell**（尾随插槽写法），
      // 不再经由中间的 `@Builder` 包装 + `content: this.xxxForm` 按值传参。
      // 原因见文件头 `timePickerTitleFor()` 的注释与实机崩溃栈：
      // 按值传给 `@BuilderParam` 的 builder 执行时 `this` **不是**本组件——
      // `this.tempHour` / `this.getTimePickerTitle()` 全是 undefined，
      // 点「免打扰结束时间」直接 `TypeError` 让整个应用被系统杀掉。
      // 尾随插槽写法由 PrivacyConsentDialog 早已实机验证可用。
      if (this.showResetConfirm) {
        DialogShell({ onDismiss: () => { this.showResetConfirm = false; } }) {
          this.resetConfirmForm()
        }
      }

      if (this.showTimePicker) {
        DialogShell({ onDismiss: () => { this.cancelTimePicker(); } }) {
          this.timePickerForm()
        }
      }

      if (this.showAddCustom) {
        DialogShell({ onDismiss: () => { this.showAddCustom = false; } }) {
          this.addCustomForm()
        }
      }

      // 备份前摘要弹窗
      if (this.showBackupSummary) {
        DialogShell({ onDismiss: () => { this.showBackupSummary = false; } }) {
          this.backupSummaryForm()
        }
      }
    }
.width('100%')
    .height('100%')
    .backgroundColor('transparent')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /**
   * 时间选择弹窗的内容。
   *
   * ⚠️ 只能由 `build()` 里的 `DialogShell({...}) { this.timePickerForm() }` 尾随插槽调用，
   * **不要**写成 `content: this.timePickerForm` 按值传参——那样 builder 内的
   * `this.tempHour` / `this.timePickerTitleText` 全是 undefined，实机点一下就崩。
   * 见文件头 `timePickerTitleFor()` 的注释与崩溃栈。
   */
  @Builder
  timePickerForm() {
    Column({ space: 16 }) {
      Text(this.timePickerTitleText)
        .fontSize(17).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))

      Row({ space: 8 }) {
        // 无障碍：内容仅 "-"/"+"，读屏只会播报符号；显式说明调整的是小时还是分钟、步长多少
        Button('-').fontSize(20).fontColor(ThemeColor.label(this.isDarkMode)).backgroundColor(ThemeColor.inputBg(this.isDarkMode)).width(60).height(60)
          .accessibilityText(`小时减一，当前 ${this.tempHour} 点`)
          .borderRadius(30).onClick(() => { this.tempHour = (this.tempHour + 23) % 24; });
        Text(this.tempHour.toString().padStart(2, '0')).fontSize(36).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode));
        Button('+').fontSize(20).fontColor(ThemeColor.label(this.isDarkMode)).backgroundColor(ThemeColor.inputBg(this.isDarkMode)).width(60).height(60)
          .accessibilityText(`小时加一，当前 ${this.tempHour} 点`)
          .borderRadius(30).onClick(() => { this.tempHour = (this.tempHour + 1) % 24; });
      }.alignItems(VerticalAlign.Center).justifyContent(FlexAlign.Center)

      Row({ space: 8 }) {
        // 分钟步长：每次按 -15/+15 分钟调整（与加号对称）
        Button('-').fontSize(20).fontColor(ThemeColor.label(this.isDarkMode)).backgroundColor(ThemeColor.inputBg(this.isDarkMode)).width(60).height(60)
          .accessibilityText(`分钟减十五，当前 ${this.tempMinute} 分`)
          .borderRadius(30).onClick(() => { this.tempMinute = (this.tempMinute + 45) % 60; });
        Text(this.tempMinute.toString().padStart(2, '0')).fontSize(36).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode));
        Button('+').fontSize(20).fontColor(ThemeColor.label(this.isDarkMode)).backgroundColor(ThemeColor.inputBg(this.isDarkMode)).width(60).height(60)
          .accessibilityText(`分钟加十五，当前 ${this.tempMinute} 分`)
          .borderRadius(30).onClick(() => { this.tempMinute = (this.tempMinute + 15) % 60; });
      }.alignItems(VerticalAlign.Center).justifyContent(FlexAlign.Center)

      Row({ space: 12 }) {
        Button('取消')
          .fontSize(15)
          .fontColor(ThemeColor.systemGray(this.isDarkMode))
          .backgroundColor(ThemeColor.inputBg(this.isDarkMode))
          .layoutWeight(1)
          .onClick(() => { this.cancelTimePicker(); });
        Button('确定')
          .fontSize(15)
          .fontColor(IOS26_WHITE)
          .backgroundColor(ThemeColor.accentColorFill(this.accentColorHex, this.isDarkMode))
          .layoutWeight(1)
          .onClick(async () => { await this.saveTimePicker(); });
      }.width('100%')
    }
  }

  /** 重置确认弹窗的内容（外壳见 build() 里的尾随插槽调用） */
  @Builder
  resetConfirmForm() {
    Column({ space: 16 }) {
      Text('确认重置？')
        .fontSize(17).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))

      Text('此操作将清除所有使用记录、限额设置和历史数据，且无法恢复。')
        .fontSize(13).fontColor(ThemeColor.systemGray(this.isDarkMode))
        .textAlign(TextAlign.Start)

      Row({ space: 12 }) {
        Button('取消')
          .fontSize(15)
          .fontColor(ThemeColor.systemGray(this.isDarkMode))
          .backgroundColor(ThemeColor.inputBg(this.isDarkMode))
          .layoutWeight(1)
          .onClick(() => { this.showResetConfirm = false; })

        Button(this.isResetting ? '重置中...' : '确认重置')
          .fontSize(15)
          .fontColor(IOS26_WHITE)
          .backgroundColor(ThemeColor.accentRedFill(this.isDarkMode))
          .layoutWeight(1)
          .enabled(!this.isResetting)
          .onClick(() => { this.resetAllData(); })
      }.width('100%')
    }
  }

  @Builder
  addCustomForm() {
    Scroll() {
      Column({ space: 16 }) {
        Text('添加自定义提醒')
          .fontSize(17).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))

        TextInput({ placeholder: '提醒名称，如「吃药提醒」', text: $$this.newCustomName })
          .fontSize(14)
          .fontColor(ThemeColor.label(this.isDarkMode))
          .height(40)
          .width('100%')
          .borderRadius(8)
          .backgroundColor(ThemeColor.accentTint('0,122,255', 0.05, this.isDarkMode))
          .maxLength(20)
          .accessibilityText('自定义提醒名称')

        Row({ space: 12 }) {
          Button('取消')
            .fontSize(15)
            .fontColor(ThemeColor.systemGray(this.isDarkMode))
            .backgroundColor(ThemeColor.inputBg(this.isDarkMode))
            .layoutWeight(1)
            .onClick(() => { this.showAddCustom = false; })

Button('添加')
            .fontSize(15)
            .fontColor(IOS26_WHITE)
            .backgroundColor(ThemeColor.accentColorFill(this.accentColorHex, this.isDarkMode))
            .layoutWeight(1)
            .onClick(() => { this.addCustomReminder(); })
        }.width('100%')
      }
    }
    // 限高 + 可滚动：键盘弹起（ArkUI 默认 OFFSET 避让会上移页面）压缩可用高度后，
    // 输入框与「添加」按钮仍完整可达
    .constraintSize({ maxHeight: '80%' })
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  /** 备份前摘要弹窗的内容：列出本次备份将包含的数据，用户确认后才执行导出 */
  @Builder
  backupSummaryForm() {
    Column({ space: 16 }) {
      Text('备份前摘要')
        .fontSize(17).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode))
      Text(this.backupSummaryText)
        .fontSize(13).fontColor(ThemeColor.labelSecondary(this.isDarkMode))
        .textAlign(TextAlign.Start)
        .lineHeight(20)
      Text('点击「确认导出」后将打开系统文件选择器，请选择保存位置。')
        .fontSize(11).fontColor(ThemeColor.labelSecondary(this.isDarkMode))
        .textAlign(TextAlign.Start)
      Row({ space: 12 }) {
        Button('取消')
          .fontSize(15).fontColor(ThemeColor.systemGray(this.isDarkMode))
          .backgroundColor(ThemeColor.inputBg(this.isDarkMode))
          .layoutWeight(1)
          .onClick(() => { this.showBackupSummary = false; })
        Button('确认导出')
          .fontSize(15).fontColor(IOS26_WHITE)
          .backgroundColor(ThemeColor.accentColorFill(this.accentColorHex, this.isDarkMode))
          .layoutWeight(1)
          .onClick(() => { this.doExportData(); })
      }.width('100%')
    }
    .width('100%')
    .padding(20)
  }
}

