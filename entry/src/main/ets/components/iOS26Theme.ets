/**
 * iOS 26 Liquid Glass 设计语言 · 色板与玻璃材质令牌
 * 说明：Curve / ShadowOptions 为 ArkUI 全局声明，无需 import。
 */

// ===== 系统强调色（浅色/暗色通用）=====
// 仅导出被其他文件真实引用的调色板令牌
import { accentTextHex, accentFillHex } from '../models/HealthTypes';

export const IOS26_BLUE: string = '#007AFF';
export const IOS26_WHITE: string = '#FFFFFF';
export const IOS26_GREEN: string = '#34C759';
export const IOS26_ORANGE: string = '#FF9500';
export const IOS26_PURPLE: string = '#AF52DE';

type GradientStops = [string, number][];

// ===== 浅色模式文本色 =====
const IOS26_LABEL: string = '#1D1D1F';
const IOS26_LABEL_SECONDARY: string = '#3C3C43';
// 由 #6E6E73 加深到 #636366：对白仍 5.4:1（达标，勿再浅），但与二级文本拉开一档 ——
// 三级文本用在副标题下方的说明文案上，原来与二级几乎同深、层级读不出来。
const IOS26_SYSTEM_GRAY: string = '#636366';

// ===== 浅色模式填充 / 分隔 =====
// fill 原 #F2F2F7 在白卡上仅 1.05:1，滑块轨道与进度条空槽几乎看不见；
// 加深到 #E6E8EF 后对白卡 1.15:1，配合新增的卡片描边可清晰区分。
const IOS26_FILL: string = '#E6E8EF';
const IOS26_FILL_WEAK: string = '#FFFFFF';
// 0.16 → 0.22：浅色玻璃上的两行指标分隔线原来几乎不可见。
const IOS26_SEPARATOR: string = 'rgba(60,60,67,0.22)';

// ===== 暗色模式文本色 =====
const IOS26_DARK_LABEL: string = '#FFFFFF';
const IOS26_DARK_LABEL_SECONDARY: string = '#EBEBF5';
const IOS26_DARK_SYSTEM_GRAY: string = '#8E8E93';

// ===== 暗色模式填充 / 分隔 =====
export const IOS26_DARK_FILL: string = '#1C1C1E';
const IOS26_DARK_FILL_WEAK: string = '#2C2C2E';
const IOS26_DARK_SEPARATOR: string = 'rgba(84,84,88,0.36)';

// ===== 玻璃材质令牌（浅色：半透明白 + 高光描边）=====
const GLASS_BG_LIGHT: string = 'rgba(255,255,255,0.72)';
const GLASS_BG_PRESSED_LIGHT: string = 'rgba(255,255,255,0.84)';
const GLASS_BG_HOVER_LIGHT: string = 'rgba(255,255,255,0.80)';
// ⚠️ 浅色描边不能用白色：卡片底色本身已接近纯白，白描边叠加后不可见，
// 反而把顶/底缘的两条亮边衬得更硬。改用极淡的中性冷灰，只提供边界不抢注意力。
const GLASS_BORDER_LIGHT: string = 'rgba(90,90,105,0.14)';
const GLASS_BORDER_PRESSED_LIGHT: string = 'rgba(90,90,105,0.10)';
const GLASS_SHADOW_LIGHT: string = '#26000000';
const GLASS_SHADOW_PRESSED_LIGHT: string = '#14000000';
const GLASS_SHADOW_HOVER_LIGHT: string = '#1C000000';

// ===== 玻璃材质令牌（暗色：半透明深灰 + 柔光描边）=====
const GLASS_BG_DARK: string = 'rgba(28,28,30,0.72)';
const GLASS_BG_PRESSED_DARK: string = 'rgba(28,28,30,0.84)';
const GLASS_BG_HOVER_DARK: string = 'rgba(28,28,30,0.80)';
const GLASS_BORDER_DARK: string = 'rgba(255,255,255,0.12)';
const GLASS_BORDER_PRESSED_DARK: string = 'rgba(255,255,255,0.20)';
const GLASS_SHADOW_DARK: string = '#40000000';
const GLASS_SHADOW_PRESSED_DARK: string = '#30000000';
const GLASS_SHADOW_HOVER_DARK: string = '#38000000';

// ===== 输入框背景 =====
// 浅色：纯白 0.9 在浅色玻璃卡上会与卡片底色几乎同色、输入框"消失"，
// 改用一个极淡的冷灰蓝底，输入框边界由底色差而非描边提供。
const INPUT_BG_LIGHT: string = 'rgba(255,255,255,0.94)';
const INPUT_BG_DARK: string = 'rgba(44,44,46,0.9)';
const INPUT_BG_HOVER_LIGHT: string = 'rgba(255,255,255,1.0)';
const INPUT_BG_HOVER_DARK: string = 'rgba(44,44,46,1.0)';

// ===== Chip 背景（未选中态）=====
// 浅色 0.10 → 0.14：浅色玻璃卡上 0.10 的蓝几乎看不出选中/未选出的差别

// ===== 背景渐变 =====
// 浅色模式原先是「全色环彩虹」（#007AFF 蓝 → #00D4FF 青 → #FF2D92 品红 → #FFCC00 黄 → #34C759 绿）。
// 问题（实机截图取证）：① 五色跨度接近整个色轮，色相在 1320px 高度上要绕一圈，
// 任一卡片后面都可能是饱和色，白玻璃压上去被染色、卡片之间底色突变；
// ② 品红/黄两个色停亮度高，与玻璃卡的白色高光争夺注意力；
// ③ 白卡上的正文（#1D1D1F）与背景的对比度随滚动剧烈变化。
//
// 改为「同色系单向渐变」：蓝 → 靛 → 紫，全程保持高明度低饱和，
// 只提供冷暖倾向而不抢内容；卡片底色在整个滚动过程中平滑变化。
// 亮度自上而下**前 60% 下降、末两档回升**（按亮度公式实测：241.95→236.81→233.37
// →233.93→236.71），末两档的回升是刻意留的柔和收尾，避免画面底部"压得太死"；
// 内容区（卡片最密集处）落在最暗档，卡片边界更清晰，视觉重心自然落在卡片上。
const GRADIENT_LIGHT: GradientStops = [
  ['#EAF3FF', 0],
  ['#E6EDFF', 0.28],
  ['#EAE7FF', 0.56],
  ['#F0E6FF', 0.8],
  ['#F3E9FF', 1]
];
const GRADIENT_DARK: GradientStops = [
  ['#1A1A2E', 0], ['#16213E', 0.3], ['#0F3460', 0.6], ['#5856D6', 1]
];

export class ThemeColor {
  // ===== 强调色（文本/填充）=====
  /** 强调蓝色文本：浅 #0066CC，暗 #6CB6FF */
  static accentBlue(isDark: boolean): string {
    return isDark ? '#6CB6FF' : '#0066CC';
  }

  /** 强调蓝色填充（承载白色文本 ≥4.5:1） */
  static accentBlueFill(isDark: boolean): string {
    return isDark ? '#3578C4' : '#0066CC';
  }

  /** 强调绿色文本：浅 #1B7A34，暗 #4ADE80 */
  static accentGreen(isDark: boolean): string {
    return isDark ? '#4ADE80' : '#1B7A34';
  }

  static accentGreenFill(isDark: boolean): string {
    return isDark ? '#22884A' : '#1B7A34';
  }

  /** 强调红色文本：浅 #CC2936，暗 #FF6B6B */
  static accentRed(isDark: boolean): string {
    return isDark ? '#FF6B6B' : '#CC2936';
  }

  static accentRedFill(isDark: boolean): string {
    return isDark ? '#CC3530' : '#CC2936';
  }

  static accentOrange(isDark: boolean): string {
    return isDark ? '#FFB84D' : '#9A6400';
  }

  static accentIndigo(isDark: boolean): string {
    return isDark ? '#9B8FFF' : '#4A47CC';
  }

  /**
   * 根据十六进制颜色取强调色文本色（浅色/暗色）。
   * 适用于用户自定义强调色，委托现有 accentTextColor。
   * @param hex 强调色十六进制（如 '#0066CC'），不含 #
   * @param isDark 当前是否为暗色模式
   */
  /**
   * 把 #RRGGBB 颜色串转为 'r,g,b'。
   * accentTint / accentBorder 的契约是「不含 # 的 RGB 串」，直接传 hex 会生成
   * 非法 CSS（rgba(#0066CC,0.14)），ArkUI 会回退成纯黑。
   * 非法输入回退到默认强调蓝。
   */
  static hexToRgb(hex: string): string {
    if (!hex || hex.length < 7) {
      return '0,102,204';
    }
    const r = parseInt(hex.substring(1, 3), 16);
    const g = parseInt(hex.substring(3, 5), 16);
    const b = parseInt(hex.substring(5, 7), 16);
    if (isNaN(r) || isNaN(g) || isNaN(b)) {
      return '0,102,204';
    }
    return `${r},${g},${b}`;
  }

  static accentColor(hex: string, isDark: boolean): string {
    return ThemeColor.accentTextColor(hex, isDark);
  }

  /**
   * 根据十六进制颜色取强调色填充色（承载白色文本，≥4.5:1）。
   * 适用于用户自定义强调色，委托现有 accentFillColor。
   * @param hex 强调色十六进制（如 '#0066CC'），不含 #
   * @param isDark 当前是否为暗色模式
   */
  static accentColorFill(hex: string, isDark: boolean): string {
    return ThemeColor.accentFillColor(hex, isDark);
  }

  /**
   * 根据十六进制颜色取强调色淡背景。
   * 适用于用户自定义强调色，委托现有 accentTint。
   * @param hex 强调色十六进制（含 #，如 '#0066CC'）
   * @param lightOpacity 浅色模式不透明度（如 0.08）
   * @param isDark 当前是否为暗色模式
   */
  static accentColorTint(hex: string, lightOpacity: number, isDark: boolean): string {
    return ThemeColor.accentTint(ThemeColor.hexToRgb(hex), lightOpacity, isDark);
  }

  /**
   * 根据十六进制颜色取强调色边框。
   * 适用于用户自定义强调色，委托现有 accentBorder。
   * @param hex 强调色十六进制（如 '#0066CC'），不含 #
   * @param lightOpacity 浅色模式不透明度（如 0.1）
   * @param isDark 当前是否为暗色模式
   */
  static accentColorBorder(hex: string, lightOpacity: number, isDark: boolean): string {
    return ThemeColor.accentBorder(ThemeColor.hexToRgb(hex), lightOpacity, isDark);
  }

  /**
   * 通用强调色文本色映射：将系统强调色映射为满足 WCAG AA 的文本色。
   * @param accentColor 系统强调色（#RRGGBB），如 '#0A84FF'
   */
  static accentTextColor(accentColor: string, isDark: boolean): string {
    return accentTextHex(accentColor, isDark);
  }

  /**
   * 通用强调色填充色映射（需承载白色文本）
   */
  static accentFillColor(accentColor: string, isDark: boolean): string {
    return accentFillHex(accentColor, isDark);
  }

  // ===== 渐变 =====
  /** 背景渐变色停 */
  static gradient(isDark: boolean): GradientStops {
    return isDark ? GRADIENT_DARK : GRADIENT_LIGHT;
  }

  // ===== 阴影 =====
  /** 卡片阴影色（浅色 20% 黑，暗色 40% 黑） */
  static shadowColor(isDark: boolean): string {
    return isDark ? '#66000000' : '#33000000';
  }

  /** 弹窗/对话框背后的遮罩 */
  static dialogMask(): string {
    return 'rgba(0,0,0,0.4)';
  }

  // ===== 玻璃材质 =====
  static glassBg(isDark: boolean, pressed: boolean = false, hover: boolean = false): string {
    if (isDark) {
      if (pressed) {
        return GLASS_BG_PRESSED_DARK;
      }
      if (hover) {
        return GLASS_BG_HOVER_DARK;
      }
      return GLASS_BG_DARK;
    }
    if (pressed) {
      return GLASS_BG_PRESSED_LIGHT;
    }
    if (hover) {
      return GLASS_BG_HOVER_LIGHT;
    }
    return GLASS_BG_LIGHT;
  }

  static glassBorder(isDark: boolean, pressed: boolean = false): string {
    if (isDark) {
      return pressed ? GLASS_BORDER_PRESSED_DARK : GLASS_BORDER_DARK;
    }
    return pressed ? GLASS_BORDER_PRESSED_LIGHT : GLASS_BORDER_LIGHT;
  }

  static glassShadow(isDark: boolean, pressed: boolean = false, hover: boolean = false): string {
    if (isDark) {
      if (pressed) {
        return GLASS_SHADOW_PRESSED_DARK;
      }
      if (hover) {
        return GLASS_SHADOW_HOVER_DARK;
      }
      return GLASS_SHADOW_DARK;
    }
    if (pressed) {
      return GLASS_SHADOW_PRESSED_LIGHT;
    }
    if (hover) {
      return GLASS_SHADOW_HOVER_LIGHT;
    }
    return GLASS_SHADOW_LIGHT;
  }

  /**
   * 玻璃卡片顶部高光描边中心值
   *
   * ⚠️ 浅色模式由 0.85/0.65 降到 0.70/0.52，**不是随手调参**：
   * 玻璃卡有三条独立的亮边（顶缘高光 / 底缘折射 / border），浅色下它们叠在一起。
   * 原先顶缘 0.85 + 底缘 0.55 + 白描边 0.85 三者叠加，在白卡上形成一条
   * 过曝的白带，把卡片顶边"烧"成一条硬白线（实机截图取证）。
   * 其中 0.55 的底缘与 0.85 的白描边均为**历史值**：底缘现为 0.30、描边已改为
   * 中性灰 rgba(90,90,105,0.14)，故浅色实际比值是 0.70/0.30≈2.3:1，
   * "顶强于底约 2.5:1"是**暗色模式**（0.25 / 0.10）的实测值。
   */
  static glassHighlightCenter(isDark: boolean, pressed: boolean = false): string {
    if (isDark) {
      return pressed ? 'rgba(255,255,255,0.20)' : 'rgba(255,255,255,0.25)';
    }
    return pressed ? 'rgba(255,255,255,0.52)' : 'rgba(255,255,255,0.70)';
  }

  /**
   * 玻璃底缘折射光（与顶部高光对称但更弱，给卡片"厚度"）。
   * 真实玻璃在深色背景上底缘会聚一次折射亮边，缺了它卡片会显得贴在背景上而非悬浮。
   */
  static glassEdgeRefract(isDark: boolean): string {
    return isDark ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.30)';
  }

  // ===== 输入框 / Chip 背景 =====
  static inputBg(isDark: boolean, hover: boolean = false): string {
    if (isDark) {
      return hover ? INPUT_BG_HOVER_DARK : INPUT_BG_DARK;
    }
    return hover ? INPUT_BG_HOVER_LIGHT : INPUT_BG_LIGHT;
  }

  /**
   * chip 未选中态背景：跟随强调色的淡色背景。
   * @param hex 强调色十六进制（#RRGGBB）
   */
  static chipBg(hex: string, isDark: boolean, hover: boolean = false): string {
    return ThemeColor.accentColorTint(hex, hover ? 0.20 : 0.14, isDark);
  }

  // ===== 基础语义色 =====
  static fill(isDark: boolean): string {
    return isDark ? IOS26_DARK_FILL : IOS26_FILL;
  }

  static fillWeak(isDark: boolean): string {
    return isDark ? IOS26_DARK_FILL_WEAK : IOS26_FILL_WEAK;
  }

  static separator(isDark: boolean): string {
    return isDark ? IOS26_DARK_SEPARATOR : IOS26_SEPARATOR;
  }

  static label(isDark: boolean): string {
    return isDark ? IOS26_DARK_LABEL : IOS26_LABEL;
  }

  static labelSecondary(isDark: boolean): string {
    return isDark ? IOS26_DARK_LABEL_SECONDARY : IOS26_LABEL_SECONDARY;
  }

  static systemGray(isDark: boolean): string {
    return isDark ? IOS26_DARK_SYSTEM_GRAY : IOS26_SYSTEM_GRAY;
  }

  /** 系统栏文字色：浅色模式深灰，暗色模式浅灰 */
  static statusBarContent(isDark: boolean): string {
    return isDark ? '#FFEBEBF5' : '#FF3C3C43';
  }

  /**
   * 强调色淡背景：暗色模式下提高不透明度以保持可见性
   * @param baseRgb 如 '0,122,255'（不含 rgba 前缀和后缀）
   * @param lightOpacity 浅色模式不透明度（如 0.08）
   */
  static accentTint(baseRgb: string, lightOpacity: number, isDark: boolean): string {
    const darkOpacity = Math.min(lightOpacity * 2.2, 0.35);
    return `rgba(${baseRgb},${isDark ? darkOpacity : lightOpacity})`;
  }

  /** 强调色边框：暗色模式下略微增亮 */
  static accentBorder(baseRgb: string, lightOpacity: number, isDark: boolean): string {
    const darkOpacity = Math.min(lightOpacity * 1.6, 0.3);
    return `rgba(${baseRgb},${isDark ? darkOpacity : lightOpacity})`;
  }

  /**
   * 为 6 位 #RRGGBB 颜色附加 2 位十六进制 alpha，生成合法的 #AARRGGBB 字符串。
   * ArkUI 8 位色值为 #AARRGGBB（alpha 在前）。
   * @param alphaHex 如 '14'（=7.8% 不透明度）
   */
  static withAlpha(hexColor: string, alphaHex: string): string {
    return '#' + alphaHex + hexColor.slice(1);
  }

  // ===== 成就等级色 =====
  /** 铜牌色 */
  static tierBronze(isDark: boolean): string {
    return isDark ? '#D4956A' : '#7A5233';
  }

  /** 银牌色 */
  static tierSilver(isDark: boolean): string {
    return isDark ? '#D4D4D4' : '#5F5F5F';
  }

  /** 金牌色 */
  static tierGold(isDark: boolean): string {
    return isDark ? '#FFD700' : '#6E5C00';
  }

  /** 白金 */
  static tierPlatinum(isDark: boolean): string {
    return isDark ? '#E5E4E2' : '#5F5F5F';
  }
}
