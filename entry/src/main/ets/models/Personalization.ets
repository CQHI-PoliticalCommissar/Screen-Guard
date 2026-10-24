/**
 * 个性化称呼（昵称）的纯函数内核。
 *
 * 称呼只影响首页问候文案（「早上好，小萤」），不参与任何统计口径，
 * 但它是用户可自由输入的文本，必须先做规范化再落盘/上屏：
 *  - 去掉首尾空白、控制字符（换行/制表符会把单行问候撑成两行）；
 *  - 连续空格折叠成一个，避免「小  萤」这种视觉异常；
 *  - 超长截断且**不切断代理对**（emoji 是 2 个 UTF-16 码元，截半个会显示成乱码方块）。
 *
 * 不读单例 / 不读 prefs / 不调 `Date.now()`（项目硬约束 #6），可直接被 LocalUnit 覆盖。
 */

/** 称呼偏好键（与其余业务键一样存放在 health_prefs 里） */
export const PREFS_KEY_NICKNAME = 'user_nickname';

/**
 * 称呼最大长度（按 UTF-16 码元计）。
 * 12 个汉字足够表达，超过会让首页问候行挤压状态徽标。
 */
export const MAX_NICKNAME_LENGTH = 12;

/**
 * 规范化称呼：去控制字符、折叠空白、截断。
 * 全空白/非法输入返回空串（调用方据此回退为「不带称呼」的默认问候）。
 */
export function normalizeNickname(raw: string): string {
  const trimmed: string = raw === undefined || raw === null ? '' : raw.trim();
  if (trimmed.length === 0) {
    return '';
  }
  let cleaned: string = '';
  let lastWasSpace: boolean = false;
  for (let i = 0; i < trimmed.length; i++) {
    const code: number = trimmed.charCodeAt(i);
    // 控制字符（含 \n \t \r）直接丢弃；空格与全角空格折叠
    if (code < 0x20 || code === 0x7F) {
      continue;
    }
    const isSpace: boolean = code === 0x20 || code === 0x3000;
    if (isSpace) {
      if (!lastWasSpace && cleaned.length > 0) {
        cleaned += ' ';
      }
      lastWasSpace = true;
      continue;
    }
    cleaned += trimmed.charAt(i);
    lastWasSpace = false;
  }
  return truncateWithoutSplittingSurrogate(cleaned.trim());
}

/** 按码元截断，但不把代理对切成两半（否则 emoji 会渲染成乱码） */
function truncateWithoutSplittingSurrogate(text: string): string {
  if (text.length <= MAX_NICKNAME_LENGTH) {
    return text;
  }
  let cut: string = text.substring(0, MAX_NICKNAME_LENGTH);
  const lastCode: number = cut.charCodeAt(cut.length - 1);
  const isHighSurrogate: boolean = lastCode >= 0xD800 && lastCode <= 0xDBFF;
  if (isHighSurrogate) {
    cut = cut.substring(0, cut.length - 1);
  }
  return cut.trim();
}

/**
 * 组合首页问候语：有称呼时加「，称呼」，没有时保持原样。
 *
 * 称呼在函数内部再规范化一次：调用方可能直接传用户输入（如预览），
 * 这样「问候语永远不含控制字符」这条保证不依赖调用方纪律。
 */
export function greetingWithNickname(greeting: string, nickname: string): string {
  const name: string = normalizeNickname(nickname);
  return name.length > 0 ? `${greeting}，${name}` : greeting;
}
