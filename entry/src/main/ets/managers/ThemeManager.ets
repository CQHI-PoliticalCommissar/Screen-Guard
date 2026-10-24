import { formatError } from '../models/ErrUtils';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PreferenceManager } from './PreferenceManager';
import { ACCENT_COLOR_PRESETS, DEFAULT_ACCENT_COLOR_KEY } from '../models/HealthTypes';
import { deriveAccentTextColor, normalizeHexColor } from '../models/AccentColorMath';
import {
  HomeCardConfigEntry,
  defaultHomeCardConfig,
  migrateLegacyHomeCardConfig,
  parseHomeCardConfig,
  visibleHomeCardIds
} from '../models/HomeCardLayout';

const DOMAIN = 0x0000;
const TAG = 'ThemeManager';

const PREFS_KEY_THEME_MODE = 'theme_mode';
const PREFS_KEY_ACCENT_COLOR = 'accent_color';
/**
 * 旧版首页布局键：只存"可见卡片 id 列表"，隐藏卡片的位置会丢失。
 * 仅用于迁移读取，新代码一律写 PREFS_KEY_HOME_CARD_LAYOUT。
 */
const PREFS_KEY_HOME_CARD_CONFIG = 'home_card_config';
/** 新版首页布局键：完整 9 张卡片的顺序 + 每张的显隐标记。 */
const PREFS_KEY_HOME_CARD_LAYOUT = 'home_card_layout';


/**
 * 外观偏好：跟随系统 / 始终浅色 / 始终深色。
 *
 * 存字符串而非数字枚举：偏好文件是明文 JSON，数字一旦将来调整顺序会导致
 * 老用户配置被静默误解（改成外观完全不同的模式）。字符串可读且天然向后兼容。
 */
export type ThemeMode = 'system' | 'light' | 'dark';

function normalizeThemeMode(raw: string): ThemeMode {
  if (raw === 'light' || raw === 'dark') {
    return raw;
  }
  // 其它值（含老版本没有该键时读到的默认空串）一律按"跟随系统"处理
  return 'system';
}

/**
 * 归一化强调色配置：预设 key 或自定义颜色（`#RRGGBB`）。
 *
 * 两种形态共用同一个偏好键（`accent_color`）与同一个内存字段：
 * 以 `#` 开头的合法颜色一律视为自定义色，其余按预设 key 处理。
 * 这样老用户已存的 `'blue'` 不需要迁移，新写入的自定义色也能直接读回。
 */
function normalizeAccentKey(raw: string): string {
  const custom: string = normalizeHexColor(raw);
  if (custom.length > 0) {
    return custom;
  }
  if (ACCENT_COLOR_PRESETS.some((p) => p.key === raw)) {
    return raw;
  }
  return DEFAULT_ACCENT_COLOR_KEY;
}

/**
 * 外观（深浅色）管理器。
 *
 * 改造前的现状（2026-10-13）：`EntryAbility.onCreate` 把 colorMode 固定为
 * `COLOR_MODE_NOT_SET`（跟随系统），随后靠 `onConfigurationUpdate` 读系统配置写入
 * `AppStorage.isDarkMode`，13 个 struct 各挂一个 `@StorageProp('isDarkMode')` 订阅。
 * **整条响应链本来就是通的**——缺的只有两件事：
 * 1. 用户没有应用内切换入口（只能去系统设置改）；
 * 2. 用户的选择无处持久化（AppStorage 非 PersistentStorage，进程一退就没了）。
 *
 * 所以本管理器刻意不接管配色逻辑，只做两件事：持久化用户选择 + 调用
 * `setColorMode` 让系统把新模式同步给应用（进而触发既有的 `onConfigurationUpdate`
 * → `updateColorMode` → AppStorage → 全局自动重渲染）。
 * **不要在这里直接写 AppStorage**，那会绕过系统配置导致两处状态不一致。
 */
export class ThemeManager {
  private static instance?: ThemeManager;

  static getInstance(): ThemeManager {
    if (!ThemeManager.instance) {
      ThemeManager.instance = new ThemeManager();
    }
    return ThemeManager.instance;
  }

  private pref?: PreferenceManager;
  private currentMode: ThemeMode = 'system';
  private lastApplied: ThemeMode = 'system';
  /**
   * 当前选中的强调色预设 key，或用户自定义的 `#RRGGBB`。
   * 持久化到 prefs；默认第一项（蓝色）。
   */
  private currentAccentKey: string = DEFAULT_ACCENT_COLOR_KEY;
  /**
   * 首页布局版本号（内存态，写入/重置时自增）。
   *
   * 首页 1s tick 每秒都要判断"布局是否变了"，而布局可能一整天都不改一次。
   * 原先的写法是每秒 `prefs.getString` + `JSON.parse` 一次；用自增版本号做门控后，
   * 每秒只剩一次数字比较，只有真正写入/重置后才重读解析。
   */
  private homeCardLayoutVersion: number = 0;
  /**
   * `getAccentColorHex` 的推导缓存。
   *
   * 自定义色的文本色需要最多 24 次对比度计算；而首页 1s tick、设置页每次重渲染
   * 都会问一次「当前强调色是什么」。缓存 (来源色, 是否暗色) → 结果，避免每秒重复推算。
   */
  private derivedAccentSource: string = '';
  private derivedAccentIsDark: boolean = false;
  private derivedAccentHex: string = '';

  /** 由 EntryAbility 在 PreferenceManager 初始化后调用 */
  initialize(pref: PreferenceManager): void {
    this.pref = pref;
    this.currentMode = normalizeThemeMode(pref.getString(PREFS_KEY_THEME_MODE, 'system'));
    this.currentAccentKey = normalizeAccentKey(pref.getString(PREFS_KEY_ACCENT_COLOR, DEFAULT_ACCENT_COLOR_KEY));
  }

  getMode(): ThemeMode {
    return this.currentMode;
  }

  /**
   * 当前强调色配置值：预设 key（如 `blue`）或自定义颜色（如 `#4A47CC`）。
   */
  getAccentKey(): string {
    return this.currentAccentKey;
  }

  /** 用户自定义颜色的原始值；当前是预设时返回空串（供设置页回显输入框） */
  getCustomAccentHex(): string {
    return normalizeHexColor(this.currentAccentKey);
  }

  /**
   * 根据预设 key / 自定义颜色与暗色模式取对应的十六进制颜色。
   *
   * 自定义颜色不能直接拿去当文本色：用户可能选一个很浅的黄，深色模式下它在
   * 深色背景上、浅色模式下它在白色卡片上都会读不清。这里统一交给
   * `models/AccentColorMath.deriveAccentTextColor` 推导（保证 ≥4.5:1）。
   */
  getAccentColorHex(isDark: boolean): string {
    const custom: string = normalizeHexColor(this.currentAccentKey);
    if (custom.length > 0) {
      if (this.derivedAccentSource === custom && this.derivedAccentIsDark === isDark &&
        this.derivedAccentHex.length > 0) {
        return this.derivedAccentHex;
      }
      const derived: string = deriveAccentTextColor(custom, isDark);
      this.derivedAccentSource = custom;
      this.derivedAccentIsDark = isDark;
      this.derivedAccentHex = derived;
      return derived;
    }
    const preset = ACCENT_COLOR_PRESETS.find((p) => p.key === this.currentAccentKey);
    if (!preset) {
      return isDark ? '#6CB6FF' : '#0066CC';
    }
    return isDark ? preset.dark : preset.light;
  }

  /**
   * 把当前强调色发布到 AppStorage，供各页面/组件用 @StorageLink 响应式读取。
   *
   * 强调色 hex 依赖暗色模式（同一预设有 light/dark 两套值），而 isDarkMode 由
   * EntryAbility 的 updateColorMode 写入 AppStorage，因此这里统一从 AppStorage
   * 读 isDarkMode，避免 ThemeManager 与各页面各持一份状态。
   */
  publishAccent(): void {
    const isDark: boolean = AppStorage.get<boolean>('isDarkMode') ?? false;
    AppStorage.setOrCreate<string>('accentColorHex', this.getAccentColorHex(isDark));
  }

  /**
   * 把用户选择的强调色持久化。返回是否成功写入偏好。
   *
   * `key` 既可以是预设 key（`blue` / `green` …），也可以是自定义颜色（`#RRGGBB`）；
   * 非法值会被归一化为默认蓝色，不会写入脏数据。
   */
  async setAccentKey(context: common.Context, key: string): Promise<boolean> {
    const normalized = normalizeAccentKey(key);
    if (normalized === this.currentAccentKey) {
      this.publishAccent();
      return true;
    }
    this.currentAccentKey = normalized;
    if (!this.pref) {
      hilog.warn(DOMAIN, TAG, '%{public}s', 'PreferenceManager 未初始化，强调色选择不会被持久化');
      return false;
    }
    await this.pref.setString(PREFS_KEY_ACCENT_COLOR, normalized);
    this.publishAccent();
    return true;
  }

  /**
   * 获取首页卡片布局：完整 9 张卡片的顺序 + 每张的显隐标记。
   *
   * 读取顺序：新键 → 旧键（迁移）→ 默认布局。
   * 旧键只存"可见列表"，隐藏卡片的位置信息已丢失，迁移时把可见卡片按旧顺序
   * 填回默认骨架、隐藏卡片留在各自默认位置（见 migrateLegacyHomeCardConfig）。
   */
  getHomeCardLayout(): HomeCardConfigEntry[] {
    if (!this.pref) {
      return defaultHomeCardConfig();
    }
    const rawLayout: string = this.pref.getString(PREFS_KEY_HOME_CARD_LAYOUT, '');
    if (rawLayout) {
      const parsed: HomeCardConfigEntry[] | null = parseHomeCardConfig(rawLayout);
      if (parsed !== null) {
        return parsed;
      }
      hilog.warn(DOMAIN, TAG, '%{public}s', '解析首页布局配置失败，回退默认布局');
    }
    const rawLegacy: string = this.pref.getString(PREFS_KEY_HOME_CARD_CONFIG, '');
    if (rawLegacy) {
      const migrated: HomeCardConfigEntry[] | null = migrateLegacyHomeCardConfig(rawLegacy);
      if (migrated !== null) {
        return migrated;
      }
      hilog.warn(DOMAIN, TAG, '%{public}s', '迁移旧版首页布局配置失败，回退默认布局');
    }
    return defaultHomeCardConfig();
  }

  /**
   * 首页可见卡片 id 列表（数组顺序即显示顺序）。
   * 首页 1s tick 每秒读一次，故内部只做一次 prefs 读取 + 一次解析。
   */
  getHomeCardConfig(): string[] {
    return visibleHomeCardIds(this.getHomeCardLayout());
  }

  /**
   * 首页布局版本号：写入/重置后自增。
   * 调用方（Index 的 1s tick）只在版本号变化时才重读布局，避免每秒解析一次 JSON。
   */
  getHomeCardLayoutVersion(): number {
    return this.homeCardLayoutVersion;
  }

  /**
   * 使首页布局读取失效。
   * 用于偏好被**绕过本类**清空的场景（如 DataBackupManager「重置所有数据」），
   * 否则版本号不变 ⇒ 首页会继续按重置前的顺序/显隐渲染。
   */
  invalidateHomeCardLayout(): void {
    this.homeCardLayoutVersion++;
  }

  /**
   * 持久化首页卡片布局（完整顺序 + 显隐标记）。返回是否成功写入偏好。
   */
  async setHomeCardLayout(context: common.Context, layout: HomeCardConfigEntry[]): Promise<boolean> {
    if (!this.pref) {
      hilog.warn(DOMAIN, TAG, '%{public}s', 'PreferenceManager 未初始化，首页布局不会被持久化');
      return false;
    }
    await this.pref.setString(PREFS_KEY_HOME_CARD_LAYOUT, JSON.stringify(layout));
    this.homeCardLayoutVersion++;
    return true;
  }

  /** 把用户选择应用到系统配置，并持久化。返回是否成功写入偏好 */
  async setMode(context: common.Context, mode: ThemeMode): Promise<boolean> {
    const applied = this.applyColorMode(context, mode);
    this.currentMode = mode;
    if (!this.pref) {
      hilog.warn(DOMAIN, TAG, '%{public}s', 'PreferenceManager 未初始化，外观选择不会被持久化');
      return false;
    }
    await this.pref.setString(PREFS_KEY_THEME_MODE, mode);
    return applied;
  }

  /**
   * 在应用启动时应用已保存的外观选择。
   *
   * 调用时机很关键，见 `EntryAbility.onWindowStageCreate`：那里把 `loadContent`
   * 放进了 `PreferenceManager.init()` 的回调里，必须先应用外观再渲染首帧。
   * 若两者并行，页面会先按系统当前模式渲染出第一帧、再切成用户所选，肉眼可见一次闪烁。
   *
   * ⚠️ 这里**不能**靠 AppStorage 之类的进程内缓存来抢时间：冷启动是全新进程，
   * 任何内存态都是空的（实测加过 AppStorage 镜像，冷启动日志仍是
   * `isDark=false → false → true`，首帧照样错）。持久化只能来自 prefs，
   * 而 prefs 是异步的 —— 所以唯一的正确解法是**让渲染等它**。
   */
  applySavedMode(context: common.Context): void {
    if (this.pref) {
      this.currentMode = normalizeThemeMode(this.pref.getString(PREFS_KEY_THEME_MODE, 'system'));
    } else {
      this.currentMode = 'system';
    }
    this.applyColorMode(context, this.currentMode);
  }

  /**
   * 调 `setColorMode` 让系统下发新配置。
   *
   * `COLOR_MODE_NOT_SET` 表示跟随系统。注意这里的返回值只代表"调用成功"，
   * 实际生效结果由随后的 `onConfigurationUpdate` 异步告知，
   * 故不做回滚——系统不接受时它会保持原状，界面自然不会变。
   */
  private applyColorMode(context: common.Context, mode: ThemeMode): boolean {
    let colorMode: ConfigurationConstant.ColorMode;
    if (mode === 'light') {
      colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    } else if (mode === 'dark') {
      colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } else {
      colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    }
    try {
      context.getApplicationContext().setColorMode(colorMode);
      this.lastApplied = mode;
      hilog.info(DOMAIN, TAG, '%{public}s', `外观已应用：${mode}`);
      return true;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '%{public}s', 'setColorMode 失败：' + formatError(err));
      return false;
    }
  }
}
