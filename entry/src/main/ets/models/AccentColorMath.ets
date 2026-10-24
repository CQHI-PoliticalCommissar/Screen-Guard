/**
 * 自定义强调色的纯函数内核。
 *
 * 为什么单独成文件：
 * 1. 项目硬约束 #6 —— 可测试的纯逻辑一律放 `models/`，不读单例、不读 prefs、不调 `Date.now()`；
 * 2. 用户自选颜色后，**文本色与填充色都不能直接用它**：
 *    - 文本色要能在页面背景上读得清（WCAG AA ≥ 4.5:1）；
 *    - 填充色要能承载白色文字（同样 ≥ 4.5:1），否则深色模式下的浅色强调色会让白字糊掉。
 *    这两个推导都有明确的数值契约，适合用 LocalUnit 锁死。
 *
 * 推导策略（刻意简单、可解释）：
 * 以用户所选颜色为起点，向「黑 / 白」按固定步长插值，取**第一个**满足对比度要求的结果。
 * 这样既保留了色相，又能保证结果一定是合法颜色（不需要解方程，也不会出现越界值）。
 */

/** 文本/填充对比度下限（WCAG AA 正常文本） */
export const MIN_ACCENT_CONTRAST = 4.5;

/**
 * 浅色模式参考背景：浅色渐变里**最暗**的一档（#E6EDFF）。
 * 深色文字在更亮的背景（白卡）上对比度只会更高，故按最暗背景推导即可覆盖全部场景。
 */
export const ACCENT_BG_LIGHT = '#E6EDFF';
/**
 * 暗色模式参考背景：比实际玻璃卡更亮一档（#2A2A3A）。
 * 浅色文字在更暗的背景上对比度更高，取偏亮值是为了给半透明玻璃卡留出安全余量。
 */
export const ACCENT_BG_DARK = '#2A2A3A';

/** 推导时向目标色插值的步数：24 步 ≈ 每步 4.2%，足够细且最多 24 次对比度计算 */
const DERIVE_STEPS = 24;

/** RGB 三元组（ArkTS 不允许无类型对象字面量，故显式声明） */
interface RgbColor {
  r: number;
  g: number;
  b: number;
}

/** 十六进制字符校验（只认 0-9a-fA-F，不引正则以避开 ArkTS 正则实现的边界差异） */
function isHexText(text: string): boolean {
  for (let i = 0; i < text.length; i++) {
    const c: string = text.charAt(i).toLowerCase();
    const isDigit: boolean = c >= '0' && c <= '9';
    const isLetter: boolean = c >= 'a' && c <= 'f';
    if (!isDigit && !isLetter) {
      return false;
    }
  }
  return text.length > 0;
}

/**
 * 规范化用户输入的颜色：`#RRGGBB` / `RRGGBB` / `#RGB` / `RGB` → `#RRGGBB`（大写）。
 * 非法输入返回空串，由调用方决定回退（本函数不做任何「猜色」）。
 *
 * 只接受 3 位与 6 位写法：#RGBA / rgba() / 颜色名一律拒绝 —— 自定义入口的
 * 提示文案写的就是 #RRGGBB，接受别的写法只会让「为什么这个颜色没生效」更难解释。
 */
export function normalizeHexColor(raw: string): string {
  const trimmed: string = raw === undefined || raw === null ? '' : raw.trim();
  if (trimmed.length === 0) {
    return '';
  }
  const body: string = trimmed.charAt(0) === '#' ? trimmed.substring(1) : trimmed;
  if (body.length !== 3 && body.length !== 6) {
    return '';
  }
  if (!isHexText(body)) {
    return '';
  }
  if (body.length === 3) {
    const expanded: string = body.charAt(0) + body.charAt(0) +
      body.charAt(1) + body.charAt(1) +
      body.charAt(2) + body.charAt(2);
    return '#' + expanded.toUpperCase();
  }
  return '#' + body.toUpperCase();
}

function parseHex(hex: string): RgbColor {
  const rgb: RgbColor = {
    r: parseInt(hex.substring(1, 3), 16),
    g: parseInt(hex.substring(3, 5), 16),
    b: parseInt(hex.substring(5, 7), 16)
  };
  return rgb;
}

function toHex(rgb: RgbColor): string {
  const r: string = clampChannel(rgb.r).toString(16).padStart(2, '0');
  const g: string = clampChannel(rgb.g).toString(16).padStart(2, '0');
  const b: string = clampChannel(rgb.b).toString(16).padStart(2, '0');
  return ('#' + r + g + b).toUpperCase();
}

function clampChannel(value: number): number {
  if (value < 0) {
    return 0;
  }
  if (value > 255) {
    return 255;
  }
  return Math.round(value);
}

/** sRGB 通道 → WCAG 线性亮度分量 */
function channelToLinear(value: number): number {
  const c: number = value / 255;
  return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
}

/** WCAG 相对亮度（0=黑，1=白） */
function relativeLuminance(hex: string): number {
  const normalized: string = normalizeHexColor(hex);
  if (normalized.length === 0) {
    return 0;
  }
  const rgb: RgbColor = parseHex(normalized);
  return 0.2126 * channelToLinear(rgb.r) +
    0.7152 * channelToLinear(rgb.g) +
    0.0722 * channelToLinear(rgb.b);
}

/**
 * WCAG 对比度（1 ~ 21）。任一端非法时返回 1（最差），
 * 让「算不出来」在断言里表现为失败而不是意外通过。
 */
export function contrastRatio(a: string, b: string): number {
  const la: number = relativeLuminance(a);
  const lb: number = relativeLuminance(b);
  const lighter: number = Math.max(la, lb);
  const darker: number = Math.min(la, lb);
  const ratio: number = (lighter + 0.05) / (darker + 0.05);
  return Number.isFinite(ratio) ? ratio : 1;
}

function blend(from: RgbColor, to: RgbColor, step: number): RgbColor {
  const t: number = step / DERIVE_STEPS;
  const result: RgbColor = {
    r: from.r + (to.r - from.r) * t,
    g: from.g + (to.g - from.g) * t,
    b: from.b + (to.b - from.b) * t
  };
  return result;
}

/**
 * 由用户所选颜色推导「文本/图标色」：保证在对应模式的页面背景上 ≥ 4.5:1。
 *
 * - 用色本身已达标 → 原样返回（保留用户选择的准确颜色）；
 * - 未达标 → 向黑（浅色模式）/ 向白（暗色模式）逐步插值，取首个达标值；
 * - 极端情况（理论上到不了）→ 返回纯黑/纯白。
 */
export function deriveAccentTextColor(hex: string, isDark: boolean): string {
  const base: string = normalizeHexColor(hex);
  if (base.length === 0) {
    return isDark ? '#6CB6FF' : '#0066CC';
  }
  const background: string = isDark ? ACCENT_BG_DARK : ACCENT_BG_LIGHT;
  if (contrastRatio(base, background) >= MIN_ACCENT_CONTRAST) {
    return base;
  }
  const from: RgbColor = parseHex(base);
  const to: RgbColor = isDark
    ? { r: 255, g: 255, b: 255 }
    : { r: 0, g: 0, b: 0 };
  for (let step = 1; step <= DERIVE_STEPS; step++) {
    const candidate: string = toHex(blend(from, to, step));
    if (contrastRatio(candidate, background) >= MIN_ACCENT_CONTRAST) {
      return candidate;
    }
  }
  return isDark ? '#FFFFFF' : '#000000';
}

/**
 * 由用户所选颜色推导「填充色」：保证承载白色文字时 ≥ 4.5:1。
 *
 * 只向黑插值：填充色上的文字恒为白色（`IOS26_WHITE`），把底色压暗是唯一正确的方向。
 */
export function deriveAccentFillColor(hex: string): string {
  const base: string = normalizeHexColor(hex);
  if (base.length === 0) {
    return '#0066CC';
  }
  if (contrastRatio(base, '#FFFFFF') >= MIN_ACCENT_CONTRAST) {
    return base;
  }
  const from: RgbColor = parseHex(base);
  const to: RgbColor = { r: 0, g: 0, b: 0 };
  for (let step = 1; step <= DERIVE_STEPS; step++) {
    const candidate: string = toHex(blend(from, to, step));
    if (contrastRatio(candidate, '#FFFFFF') >= MIN_ACCENT_CONTRAST) {
      return candidate;
    }
  }
  return '#000000';
}

/**
 * 用户输入的简要校验结果，供设置页决定提示文案。
 * 返回空串表示可用；否则是给用户看的原因。
 */
export function describeHexInputError(raw: string): string {
  const trimmed: string = raw.trim();
  if (trimmed.length === 0) {
    return '请输入颜色值，例如 #4A47CC';
  }
  if (normalizeHexColor(trimmed).length > 0) {
    return '';
  }
  return '颜色格式不对，请用 #RRGGBB（如 #4A47CC）或 #RGB';
}
