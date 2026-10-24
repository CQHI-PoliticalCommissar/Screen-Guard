/**
 * 错误信息格式化（纯函数，无任何依赖，可直接被 LocalUnit 覆盖）。
 *
 * ## 为什么需要它
 *
 * 全库此前统一用 `JSON.stringify(err)` 打日志，但它的输出**取决于异常对象是否可枚举**：
 *
 * - HarmonyOS 的 `BusinessError`（系统 API 抛出）带可枚举的 `code` / `message`，
 *   打出来是有用信息：`{"code":13900002}`、`{"code":9800005,"message":"…"}`。
 * - **原生异常不行**。`JSON.parse` 抛的 `SyntaxError`、`TypeError`，
 *   它们的 `message` 是**不可枚举**属性，`JSON.stringify` 直接返回 `{}`。
 *   实机证据：`DataBackupManager: 备份文件解析失败：{}` —— 错误发生了，日志里却什么都没留下。
 *
 * 也就是说，恰恰在最需要排查的「数据被写坏 / 类型写错」这类故障上，日志是空的。
 *
 * ## 口径
 *
 * 依次尝试：`message` → `code`/`message` 组合 → `String(err)`，
 * 保证任何输入都产出一段**非空且能定位**的文字。
 */

/** 异常对象上我们关心的两个字段（按结构化子类型声明，规避 ArkTS 不支持的索引签名） */
interface ErrorLike {
  code?: number | string;
  message?: string;
}

/** 单条错误日志的最大长度，超出截断，避免超长内容刷爆 hilog */
const MAX_ERROR_LENGTH = 300;

function truncate(text: string): string {
  return text.length > MAX_ERROR_LENGTH ? text.slice(0, MAX_ERROR_LENGTH) + '…(已截断)' : text;
}

/** 把任意捕获到的值格式化成一行可读文本（永不抛异常、永不返回空串） */
export function formatError(err: Object): string {
  if (err === null || err === undefined) {
    return 'undefined';
  }
  if (typeof err === 'string') {
    return truncate(err);
  }
  if (typeof err === 'number' || typeof err === 'boolean') {
    return truncate(String(err));
  }

  const e = err as ErrorLike;
  const code = e.code;
  const message = e.message;

  // HarmonyOS BusinessError：code + message 都有时组合输出，信息量最大
  if (code !== undefined && code !== null && typeof message === 'string' && message.length > 0) {
    return truncate('code=' + String(code) + ' message=' + message);
  }
  // 原生异常（SyntaxError / TypeError 等）：只有 message，但它不可枚举，必须显式取
  if (typeof message === 'string' && message.length > 0) {
    return truncate(message);
  }
  if (code !== undefined && code !== null) {
    return truncate('code=' + String(code));
  }
  return truncate('[' + typeof err + ' 无可读信息]');
}