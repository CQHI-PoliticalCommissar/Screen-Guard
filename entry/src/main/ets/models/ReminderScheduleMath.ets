/**
 * ReminderScheduleMath —— 常驻提醒调度的纯计算内核
 *
 * 背景：`OngoingReminderScheduler` 每 10s 跑一次 tick，对每条提醒做一次状态推进，
 * 历史上在这里出过两个真实缺陷：
 *   - **fireNow 滥用**（2026-08-03 第二轮）：每次保存配置都传 fireNow=true，导致
 *     "打开开关后立即响一次"的语义扩散成"改设置就重置倒计时"，间隔提醒变成随机短间隔反复触发。
 *   - **每 10s 空转重发**（2026-10-01 轮 #9）：intervalMinutes <= 0 时触发分支永不成立，
 *     但"下次提醒 HH:MM"文案每轮都变，`lastPublishedText` 去重拦不住 → 每 10s 调用一次系统通知接口。
 * 另有一条防御：**撤不掉上一进程的常驻通知**（2026-10-01 轮 #8）。
 *
 * 这些逻辑原本写在与 `notificationManager`（系统 IPC）、`setInterval`、单例 `entries` Map
 * 交织的方法体里，**无法单元测试**（LocalUnit 环境没有通知服务）。
 * 本模块把它们抽为**无副作用纯函数**：全部入参显式传入（含"现在"），
 * 不读单例、不调 `Date.now()`、不碰通知接口。manager 改为委托调用，行为不变。
 *
 * 约定：
 * - 本模块内所有函数都**不做入参钳位**——非法值按调用方的语义自然传播，
 *   避免"顺手加固"变成静默的行为变更。
 * - 返回值一律用显式 interface（ArkTS 禁止对象字面量作为类型声明）。
 * - 函数只返回**状态迁移结果**，文案拼装仍留在 manager（依赖 `formatDateTime` 等格式化函数，
 *   而后者内部读 `new Date()`，放进本模块会破坏"不调用 Date.now()"的约定）。
 */

/** 触发后提醒文案保持显示的时长（间隔/每日提醒），毫秒 */
export const ALERT_SHOW_MS = 30000;
/** 一次性提醒触发后保持显示的时长，之后自动移除，毫秒 */
export const ONESHOT_ALERT_SHOW_MS = 60000;
/** 非正间隔的兜底值（1 分钟）：非法配置不应让提醒永空转，毫秒 */
export const MIN_EFFECTIVE_INTERVAL_MS = 60000;
/** 一天毫秒数（每日提醒推算次日目标时刻用） */
const DAY_MS = 86400000;

/** 一次性提醒当前所处的阶段 */
export enum OneShotPhase {
  /** 倒计时中，显示"即将提醒：还有 …" */
  COUNTING,
  /** 已触发，处于展示期，显示 ⏰ 文案 */
  ALERTING,
  /** 展示期已过，应移除该提醒 */
  FINISHED
}

/** 间隔提醒初始状态推导结果 */
interface IntervalInitResult {
  lastFireAt: number;
  alertUntil: number;
}

/** 间隔提醒单次 tick 的状态迁移结果 */
interface IntervalTickResult {
  lastFireAt: number;
  alertUntil: number;
  /** true = 本轮应显示 ⏰ 提醒文案；false = 应显示"下次提醒…" */
  alerting: boolean;
  /** 仅在 !alerting 且处于活跃时段时有意义：下一次触发时刻；其余情况为 0 */
  nextFireMs: number;
}

/** 每日提醒单次 tick 的状态迁移结果 */
interface DailyTickResult {
  lastFireDateKey: string;
  alertUntil: number;
  alerting: boolean;
  /** 仅在 !alerting 时有意义：下一次触发时刻（今天未到 = 今日目标，已过 = 次日目标）；alerting 时为 0 */
  nextFireMs: number;
}

/** 一次性提醒单次 tick 的状态迁移结果 */
interface OneShotTickResult {
  phase: OneShotPhase;
  /** 更新后的展示截止时间（COUNTING 时原样返回入参） */
  alertUntil: number;
  /** 仅 COUNTING 时有意义：剩余毫秒数 */
  remainMs: number;
}

/**
 * 间隔提醒的初始状态推导
 *
 * 三条分支的**顺序即语义**（2026-08-03 第二/三轮反复调整过）：
 * 1. `fireNow && 处于活跃时段` → 立即触发一次并进入展示期。
 *    仅"关闭→开启"这一种场景才传 fireNow=true，否则每次保存配置都会重置倒计时。
 * 2. 已有条目且曾触发过 → **保留原调度锚点**，只更新文案/配置。
 *    改动间隔、时段、标题、内容不得打乱既有触发节奏。
 * 3. 首次注册 → 从注册时刻起计一个完整间隔。
 *
 * @param now 注册时刻
 * @param inActiveWindow 当前是否处于活跃时段（由调用方算，传入以保持本模块无 Date 依赖）
 * @param fireNow 是否请求立即触发一次
 * @param existingLastFireAt 已有条目的上次触发时间（0 = 无条目 / 未曾触发）
 * @param existingAlertUntil 已有条目的展示截止时间
 */
export function deriveIntervalInitState(
  now: number,
  inActiveWindow: boolean,
  fireNow: boolean,
  existingLastFireAt: number,
  existingAlertUntil: number
): IntervalInitResult {
  if (fireNow && inActiveWindow) {
    return { lastFireAt: now, alertUntil: now + ALERT_SHOW_MS };
  }
  if (existingLastFireAt > 0) {
    return { lastFireAt: existingLastFireAt, alertUntil: existingAlertUntil };
  }
  return { lastFireAt: now, alertUntil: 0 };
}

/**
 * 每日提醒的初始"上次触发日"推导
 *
 * 目标时刻已过 → 视为今天已触发过（避免开机/打开设置时补发）；
 * 尚未到 → 记昨天，使本轮自然落入"待触发"分支。
 * 已有条目且带日期标记时**一律沿用旧值**，避免设置改动导致当天重复触发。
 *
 * @param now 注册时刻
 * @param targetMs 今日 dailyHour:dailyMinute 的时间戳
 * @param todayKey 今天 YYYY-MM-DD
 * @param yesterdayKey 昨天 YYYY-MM-DD
 * @param existingDateKey 已有条目的标记（空串 = 无）
 */
export function deriveDailyInitDateKey(
  now: number,
  targetMs: number,
  todayKey: string,
  yesterdayKey: string,
  existingDateKey: string
): string {
  let key = now >= targetMs ? todayKey : yesterdayKey;
  if (existingDateKey.length > 0) {
    key = existingDateKey;
  }
  return key;
}

/**
 * 间隔提醒单次 tick 的状态推进
 *
 * 分支顺序有讲究，勿调换：
 * 1. **先判活跃时段**，且离开时段时把 alertUntil 清零
 *    ——否则上一轮残留的展示期会让"回到时段内"的第一轮仍显示旧 ⏰ 文案。
 * 2. 仍在展示期 → 保持 ⏰ 文案。
 * 3. 到达下一个整间隔 → 触发一次，重置展示期。
 * 4. 否则显示"下次提醒：还有 …（HH:MM）"。
 *
 * 非正间隔兜底（2026-10-01 轮 #9 的真实修复）：`intervalMinutes <= 0` 时
 * 触发分支永不成立，而文案里的 HH:MM 每轮都变、去重拦不住 → 每 10s 重发。
 * 故触发判定与"下次提醒"都用最小有效间隔（1 分钟）兜底，保证触发分支终将成立。
 *
 * @param lastFireAt 上次触发时间
 * @param alertUntil 展示截止时间
 * @param intervalMinutes 配置间隔（分钟）；传 0 或负数走兜底
 * @param inActiveWindow 当前是否处于活跃时段
 * @param now 当前时刻
 */
export function intervalTickStep(
  lastFireAt: number,
  alertUntil: number,
  intervalMinutes: number,
  inActiveWindow: boolean,
  now: number
): IntervalTickResult {
  if (!inActiveWindow) {
    // 不在活跃时段：展示期立即失效，避免下次回到时段内时闪现过期 ⏰
    return { lastFireAt: lastFireAt, alertUntil: 0, alerting: false, nextFireMs: 0 };
  }
  const intervalMs = intervalMinutes * 60000;
  if (now < alertUntil) {
    return { lastFireAt: lastFireAt, alertUntil: alertUntil, alerting: true, nextFireMs: 0 };
  }
  const effectiveIntervalMs = intervalMs > 0 ? intervalMs : MIN_EFFECTIVE_INTERVAL_MS;
  if (now >= lastFireAt + effectiveIntervalMs) {
    return { lastFireAt: now, alertUntil: now + ALERT_SHOW_MS, alerting: true, nextFireMs: 0 };
  }
  const effectiveNextFire = intervalMs > 0
    ? lastFireAt + intervalMs
    : lastFireAt + MIN_EFFECTIVE_INTERVAL_MS;
  return { lastFireAt: lastFireAt, alertUntil: alertUntil, alerting: false, nextFireMs: effectiveNextFire };
}

/**
 * 每日提醒单次 tick 的状态推进
 *
 * - 展示期内保持 ⏰ 文案；
 * - 到点且今天尚未触发过 → 触发一次并记下今天的日期键（同日去重）；
 * - 已过点则推算到次日同一时刻，**不补发**。
 *
 * @param lastFireDateKey 上次触发日期键
 * @param alertUntil 展示截止时间
 * @param targetMs 今日目标时刻（由调用方用 `todayAtMs` 计算）
 * @param todayKey 今天 YYYY-MM-DD
 * @param now 当前时刻
 */
export function dailyTickStep(
  lastFireDateKey: string,
  alertUntil: number,
  targetMs: number,
  todayKey: string,
  now: number
): DailyTickResult {
  if (now < alertUntil) {
    return { lastFireDateKey: lastFireDateKey, alertUntil: alertUntil, alerting: true, nextFireMs: 0 };
  }
  if (now >= targetMs && lastFireDateKey !== todayKey) {
    return { lastFireDateKey: todayKey, alertUntil: now + ALERT_SHOW_MS, alerting: true, nextFireMs: 0 };
  }
  const next = now >= targetMs ? targetMs + DAY_MS : targetMs;
  return { lastFireDateKey: lastFireDateKey, alertUntil: alertUntil, alerting: false, nextFireMs: next };
}

/**
 * 一次性提醒单次 tick 的状态推进
 *
 * 关键：**首次触发时设置展示截止时间，之后不再重置**
 * ——若每轮都重置，FINISHED 分支永远到不了，一次性提醒会永远留在通知栏。
 *
 * @param fireAt 应触发时刻
 * @param alertUntil 展示截止时间（0 = 尚未触发过）
 * @param now 当前时刻
 */
export function oneShotTickStep(fireAt: number, alertUntil: number, now: number): OneShotTickResult {
  const remain = fireAt - now;
  if (remain > 0) {
    return { phase: OneShotPhase.COUNTING, alertUntil: alertUntil, remainMs: remain };
  }
  const until = alertUntil === 0 ? now + ONESHOT_ALERT_SHOW_MS : alertUntil;
  if (now < until) {
    return { phase: OneShotPhase.ALERTING, alertUntil: until, remainMs: 0 };
  }
  return { phase: OneShotPhase.FINISHED, alertUntil: until, remainMs: 0 };
}

/**
 * 文案去重判定：本轮文案与上次完全一致时跳过 `notificationManager.publish`
 *
 * 这是每 10s tick 的第一道成本闸——提醒条目数 = 内置 3 + 睡前 + 停用 + 自定义 N。
 * 注意它**拦不住**"文案每轮都变"的空转（见 intervalTickStep 的间隔兜底注释），
 * 两者是互补的防线。
 */
export function shouldPublish(lastPublishedText: string, text: string): boolean {
  return lastPublishedText !== text;
}