/**
 * UsageStatsMath —— 使用时长统计的纯计算内核
 *
 * 背景：`UsageStatsManager` 有 1400+ 行，其中的累计、跨日拆分、连续天数、
 * 窗口重叠等算法原本直接写在与实例状态、prefs、`Date.now()` 交织的方法体里，
 * **无法单元测试**（LocalUnit 环境没有 PreferenceManager，也没有真实电源服务）。
 * 而这恰恰是该文件 bug 史最密集的地方——历史上出现过：
 *   - 翻倍累计（watermark 与进行中会话重复累加）
 *   - 跨午夜窗口翻倍（isCrossMidnight 分支用 currentDate 当"昨天"）
 *   - 今日使用继承昨日值（prefs 里没记当天日期）
 *   - 每 10s 空转重发（间隔 <= 0 时倒计时永不成立但文案每轮都变）
 *
 * 本模块把上述算法抽为**无副作用纯函数**：全部入参显式传入（含"现在"），
 * 不读单例、不读 prefs、不调用 `Date.now()`。manager 改为委托调用，行为不变。
 *
 * 约定：本模块内所有函数都**不做入参钳位**——非法值按调用方的语义自然传播，
 * 避免"顺手加固"变成静默的行为变更。
 */

/** 一条已结算的亮屏会话记录 */
export interface ScreenOnRecord {
  /** 会话归属日期 YYYY-MM-DD（以会话开始时刻的本地日期为准） */
  date: string;
  /** 会话开始时间戳（毫秒） */
  startTime: number;
  /** 会话结束时间戳（毫秒） */
  endTime: number;
}

/** 每日历史条目 */
export interface DailyUsageEntry {
  date: string;
  totalMinutes: number;
}

/**
 * 跨日拆分的结果
 * ArkTS 不允许对象字面量作为类型声明（arkts-no-obj-literals-as-types），
 * 故必须用显式 interface。
 */
interface MidnightSplit {
  /** 归属于昨日的秒数 */
  yesterdaySeconds: number;
  /** 今日段的新起点（= 午夜时间戳）；未跨午夜时原样返回入参 */
  nextSessionStart: number;
}

/**
 * 统计指定日期的已结算亮屏记录总秒数（不含进行中会话）
 * @param records 全部亮屏记录
 * @param date 目标日期 YYYY-MM-DD
 */
export function sumRecordSeconds(records: ScreenOnRecord[], date: string): number {
  let total = 0;
  for (let i = 0; i < records.length; i++) {
    const r = records[i];
    if (r.date === date) {
      total += Math.floor((r.endTime - r.startTime) / 1000);
    }
  }
  return total;
}

/**
 * 计算"今日亮屏"的实时秒数（live）= 今日已结算记录 + 进行中会话已流逝秒数
 *
 * 语义要点（与 watermark 的关系由调用方决定）：
 * 这是**不含 watermark 的纯实时口径**。它每次冷启动从 0 起算，
 * 因此调用方必须用 `max(watermark, live)`，否则会被 watermark 钉住显示。
 *
 * @param records 全部亮屏记录
 * @param currentDate 当前日期 YYYY-MM-DD
 * @param currentSessionStart 进行中会话的开始时间戳，<= 0 表示无进行中会话
 * @param now 当前时间戳（显式传入以便测试）
 */
export function computeLiveSeconds(
  records: ScreenOnRecord[],
  currentDate: string,
  currentSessionStart: number,
  now: number
): number {
  let total = sumRecordSeconds(records, currentDate);
  if (currentSessionStart > 0) {
    total += Math.floor((now - currentSessionStart) / 1000);
  }
  return total;
}

/**
 * 跨日拆分：把"进行中的会话"按午夜切成昨日段与今日段
 *
 * 返回值中 `nextSessionStart` 是今日段的新起点，调用方应写回
 * `currentScreenOnStart`。昨日段秒数加到昨日累计上。
 *
 * 关键设计（修复"翻倍累计"与"跨午夜误记昨日"两个历史 bug）：
 * - 昨日段以 **records 精确求和** 为基础，**不以 watermark 为基**；
 *   watermark 经 refreshUsage 已含进行中会话时长，再叠加昨日段会翻倍。
 * - 仅当会话确实跨过午夜（start < midnight <= now）才拆分；
 *   不跨午夜时 nextSessionStart 原样返回，不做任何事。
 *
 * @param currentSessionStart 进行中会话开始时间戳，<= 0 表示无
 * @param midnightMs 当日 00:00:00 的时间戳
 * @param now 当前时间戳
 */
export function splitSessionAtMidnight(
  currentSessionStart: number,
  midnightMs: number,
  now: number
): MidnightSplit {
  if (currentSessionStart <= 0 || currentSessionStart >= midnightMs) {
    // 无进行中会话，或会话完全落在今日（未跨午夜）——不拆分
    return { yesterdaySeconds: 0, nextSessionStart: currentSessionStart };
  }
  const yesterdayEnd = Math.min(now, midnightMs);
  const result: MidnightSplit = {
    yesterdaySeconds: Math.floor((yesterdayEnd - currentSessionStart) / 1000),
    nextSessionStart: midnightMs
  };
  return result;
}

/**
 * 把昨日累计秒数写入每日历史（取 max，不覆盖已有更大值）
 *
 * @param history 每日历史（**原地修改**，返回值即同一引用）
 * @param yesterdayDate 昨日日期 YYYY-MM-DD
 * @param yesterdaySeconds 昨日累计秒数
 */
export function mergeDailyHistory(
  history: DailyUsageEntry[],
  yesterdayDate: string,
  yesterdaySeconds: number
): DailyUsageEntry[] {
  const minutes = Math.floor(yesterdaySeconds / 60);
  if (minutes <= 0) {
    return history;
  }
  for (let i = 0; i < history.length; i++) {
    if (history[i].date === yesterdayDate) {
      if (minutes > history[i].totalMinutes) {
        history[i].totalMinutes = minutes;
      }
      return history;
    }
  }
  history.push({ date: yesterdayDate, totalMinutes: minutes });
  return history;
}

/**
 * 达标连续天数：今日低于限额即计 1，往前连续"低于限额"的天数
 *
 * ⚠️ 边界口径与三档预警 / 首页「已超今日限额」一致：**等于限额也算已超**（`>=`），
 * 否则会出现"同一分钟显示已超额、却仍算连续达标"的自相矛盾。
 *
 * @param history 每日历史
 * @param todayMinutes 今日总分钟数（watermark 与 live 取大后的结果）
 * @param limitMinutes 每日限额（<= 0 视为"无限额"，直接返回 0）
 * @param today 今天 YYYY-MM-DD（显式传入以便测试；history 应不含该日）
 * @param lookback 最多回溯天数
 */
export function computeStreakDays(
  history: DailyUsageEntry[],
  todayMinutes: number,
  limitMinutes: number,
  today: string,
  lookback: number
): number {
  if (limitMinutes <= 0) {
    return 0;
  }
  if (todayMinutes >= limitMinutes) {
    return 0;
  }
  const map = new Map<string, number>();
  for (let i = 0; i < history.length; i++) {
    map.set(history[i].date, history[i].totalMinutes);
  }
  // 从"昨天"开始往前回溯（今天已在上面单独判定）
  let streak = 1;
  for (let i = 1; i <= lookback; i++) {
    const minutes = map.get(shiftDate(today, -i));
    if (minutes === undefined || minutes >= limitMinutes) {
      break;
    }
    streak++;
  }
  return streak;
}

/**
 * 连续使用天数：今日已使用则从今天起算，否则从昨天起算；
 * 往前连续存在"真实亮屏使用"（totalMinutes > 0）的天数。
 *
 * 与 computeStreakDays 的区别：口径是"是否用过"（>0）而非"是否达标"（<=limit）。
 * 今日尚未使用**不打断**连续（从昨天起算）。
 *
 * @param history 每日历史（不含今日）
 * @param usedToday 今日是否已有亮屏使用
 * @param today 今天 YYYY-MM-DD（显式传入以便测试；history 应不含该日）
 * @param lookback 最多回溯天数
 */
export function computeUsedDaysStreak(
  history: DailyUsageEntry[],
  usedToday: boolean,
  today: string,
  lookback: number
): number {
  const map = new Map<string, number>();
  for (let i = 0; i < history.length; i++) {
    map.set(history[i].date, history[i].totalMinutes);
  }
  let streak = usedToday ? 1 : 0;
  for (let i = 1; i < lookback; i++) {
    const minutes = map.get(shiftDate(today, -i));
    if (minutes === undefined || minutes <= 0) {
      break;
    }
    streak++;
  }
  return streak;
}

/**
 * 一段亮屏会话与"日分钟窗口"的重叠秒数（用于睡前窗口统计）
 *
 * 默认以**会话开始时刻**的本地日期为锚点构造窗口；跨午夜场景下调用方可以显式传入
 * `windowStartDayMs`（窗口起始那天的 00:00），把窗口固定到"昨晚"而不是"记录自己那一天"。
 * `startMinutes <= endMinutes` 为当日窗口；否则视为跨午夜，
 * 拆成 [startMinutes, 1440) 与次日 [0, endMinutes) 两段分别求交。
 *
 * @param startTime 会话开始时间戳
 * @param endTime 会话结束时间戳
 * @param startMinutes 窗口起始（当日 00:00 起的分钟刻度）
 * @param endMinutes 窗口结束
 * @param windowStartDayMs 窗口起始那天的 00:00 时间戳（0 = 用会话开始日，保持旧行为）
 */
export function computeOverlapInWindow(
  startTime: number,
  endTime: number,
  startMinutes: number,
  endMinutes: number,
  windowStartDayMs: number = 0
): number {
  const anchor = windowStartDayMs > 0 ? new Date(windowStartDayMs) : new Date(startTime);
  const year = anchor.getFullYear();
  const month = anchor.getMonth();
  const day = anchor.getDate();

  if (startMinutes <= endMinutes) {
    const winStart = new Date(year, month, day, Math.floor(startMinutes / 60), startMinutes % 60, 0).getTime();
    const winEnd = new Date(year, month, day, Math.floor(endMinutes / 60), endMinutes % 60, 0).getTime();
    const s = Math.max(startTime, winStart);
    const e = Math.min(endTime, winEnd);
    return e > s ? Math.floor((e - s) / 1000) : 0;
  }

  // 跨午夜：两段分别求交后相加
  let total = 0;
  const seg1End = new Date(year, month, day + 1, 0, 0, 0).getTime();
  const seg1Start = new Date(year, month, day, Math.floor(startMinutes / 60), startMinutes % 60, 0).getTime();
  const s1 = Math.max(startTime, seg1Start);
  const e1 = Math.min(endTime, seg1End);
  if (e1 > s1) {
    total += Math.floor((e1 - s1) / 1000);
  }
  const seg2Start = new Date(year, month, day + 1, 0, 0, 0).getTime();
  const seg2End = new Date(year, month, day + 1, Math.floor(endMinutes / 60), endMinutes % 60, 0).getTime();
  const s2 = Math.max(startTime, seg2Start);
  const e2 = Math.min(endTime, seg2End);
  if (e2 > s2) {
    total += Math.floor((e2 - s2) / 1000);
  }
  return total;
}

/**
 * 统计落在"日分钟窗口"内的亮屏秒数（跨午夜窗口需同时扫描昨天与今天的记录）
 *
 * 这里刻意**不接受 currentDate** 作为"昨天"：该字段跟踪的是今天，
 * 两次循环会命中同一批记录导致睡前使用时长翻倍（2026-10-01 轮修复的真实 bug）。
 * "昨天"一律由调用方基于明确的 today 字符串推导。
 *
 * @param records 全部亮屏记录
 * @param today 今天 YYYY-MM-DD
 * @param yesterday 昨天 YYYY-MM-DD（跨午夜时才会被扫描）
 * @param startMinutes 窗口起始分钟刻度
 * @param endMinutes 窗口结束分钟刻度
 * @param windowStartDayMs 窗口起始那天的 00:00（0 = 按每条记录的日期各自锚定，保持旧行为）
 */
export function sumSecondsInWindow(
  records: ScreenOnRecord[],
  today: string,
  yesterday: string,
  startMinutes: number,
  endMinutes: number,
  windowStartDayMs: number = 0
): number {
  const crossMidnight = startMinutes > endMinutes;
  let total = 0;
  for (let i = 0; i < records.length; i++) {
    const r = records[i];
    const isToday = r.date === today;
    const isYesterday = crossMidnight && r.date === yesterday;
    if (isToday || isYesterday) {
      total += computeOverlapInWindow(r.startTime, r.endTime, startMinutes, endMinutes, windowStartDayMs);
    }
  }
  return total;
}

/**
 * 本地日期格式化 YYYY-MM-DD
 * 与 models/HealthTypes.formatDate 实现一致，但此处不 import 以保持本模块零依赖
 */
function formatDateLocal(d: Date): string {
  const y = d.getFullYear().toString();
  const m = (d.getMonth() + 1).toString().padStart(2, '0');
  const day = d.getDate().toString().padStart(2, '0');
  return y + '-' + m + '-' + day;
}

/** 在 YYYY-MM-DD 上做偏移，返回同样格式的日期字符串 */
function shiftDate(dateStr: string, days: number): string {
  const base = new Date(dateStr + 'T00:00:00');
  base.setDate(base.getDate() + days);
  return formatDateLocal(base);
}

/** 每日限额预警的档位序号 */
export const LIMIT_TIER_NONE = -1;
export const LIMIT_TIER_50 = 0;
export const LIMIT_TIER_80 = 1;
export const LIMIT_TIER_100 = 2;
/** 档位总数（三档：50% / 80% / 100%），下标即档位序号 */
const LIMIT_TIER_COUNT = 3;

/**
 * 计算当前生效的最高预警档位
 *
 * 三档互斥，同一时刻只应有一条限额预警横幅在通知栏。
 *
 * 背景：这段 else-if 链原先在 `checkUsageAlerts`、`syncTierAlertNotifications`、
 * `repostTotalLimitAlert` 三处各写一遍，且"未达任何档"的处理各不相同
 * （一处直接落空、一处用 0 表示、一处提前 return），极易走偏成互相矛盾的判定。
 * 抽为单一来源后三处共用。
 *
 * @param totalSeconds 今日已使用秒数
 * @param limitMinutes 每日限额（分钟）；<= 0 视为无限制，任何用量都不触发预警
 */
export function computeLimitTierIndex(totalSeconds: number, limitMinutes: number): number {
  const limitSeconds = limitMinutes * 60;
  if (limitSeconds <= 0) {
    return LIMIT_TIER_NONE;
  }
  if (totalSeconds >= limitSeconds) {
    return LIMIT_TIER_100;
  }
  if (totalSeconds >= limitSeconds * 0.8) {
    return LIMIT_TIER_80;
  }
  if (totalSeconds >= limitSeconds * 0.5) {
    return LIMIT_TIER_50;
  }
  return LIMIT_TIER_NONE;
}

/**
 * 限额变更后需要**清除 alertSentFlags 标记**的档位下标。
 *
 * 不变式：`alertSentFlags[tier] === true` ⟺ 该档横幅当前就在通知栏里。
 *
 * 曾经的缺陷：高档触发时 `cancelSupersededTierAlerts` 只撤除低档**通知**、不清低档**标记**，
 * 而抬限额的 `syncTierAlertNotifications` 又只清"当前档以上"的标记。于是
 * 「先越 50% → 再越 80%（50% 被撤除但标记仍在）→ 抬高限额让用量落回 50% 档」
 * 这条路径上，50% 档标记仍为 true，`sendUsageAlert` 直接 return，
 * **横幅永远发不出来**——尽管 `syncTierAlertNotifications` 的注释承诺
 * "使用量重新越线还能再次提醒"。
 *
 * ⇒ 除当前档外，其余档位一律清标记：当前档以上是"通知已撤除"，
 * 当前档以下是"通知早已被更高档撤除"，两者都不该留下阻止重发的标记。
 *
 * @param currentIndex 当前生效档位（见 computeLimitTierIndex）
 */
export function limitTiersToClearFlag(currentIndex: number): number[] {
  const out: number[] = [];
  for (let i = 0; i < LIMIT_TIER_COUNT; i++) {
    if (i !== currentIndex) {
      out.push(i);
    }
  }
  return out;
}

/**
 * 限额变更后需要**撤除通知**的档位下标。
 *
 * 只撤当前档**以上**的：当前档以下的横幅在更高档触发时就已被撤除，
 * 无需重复发一次系统调用（撤除不存在会返回 1600007，已在调用方白名单）。
 */
export function limitTiersToCancel(currentIndex: number): number[] {
  const out: number[] = [];
  for (let i = currentIndex + 1; i < LIMIT_TIER_COUNT; i++) {
    out.push(i);
  }
  return out;
}

/**
 * 某档预警触发时，被它**取代**（应撤除横幅并清标记）的更低档下标。
 *
 * 与 `limitTiersToCancel` 方向相反、语义不同，别混用：
 * - `limitTiersToCancel(cur)`：限额变更后，当前档**以上**已失效、需撤除的档位；
 * - `limitTiersSupersededBy(t)`：t 档触发时，被它挤掉的**低档**。
 *
 * 清标记的理由同 limitTiersToClearFlag：标记语义是"该档横幅当前在通知栏里"，
 * 横幅一旦被撤除，标记就必须跟着清，否则该档状态重新成立时无法重发。
 *
 * @param tierIndex 刚触发的档位（见 computeLimitTierIndex）
 */
export function limitTiersSupersededBy(tierIndex: number): number[] {
  const out: number[] = [];
  for (let i = 0; i < tierIndex; i++) {
    out.push(i);
  }
  return out;
}

/**
 * 判断某分钟数是否落在「免打扰时段」内。
 *
 * ⚠️ **判别符必须是 `<`，不可改成 `<=`** —— 这里与
 * `ReminderTimeUtils.isInActiveWindow` 刻意相反，勿"顺手对齐"：
 *
 * - `start <  end`：当日内的普通区间；
 * - `start >= end`：跨午夜区间（`start > end`）**或全天**（`start == end`）。
 *   此时 `m >= start || m <= end` 在起止相同时对任意 m 恒为 true，正是我们要的语义：
 *   「免打扰时段」是**禁用**窗口，用户把起止设成同一时刻就是想要一整天都禁用。
 *
 * 反例：若改成 `<=`，起止相同时会退化成"只有那一分钟被禁"（`m>=start && m<=end`），
 * 与用户意图完全相反。`ReminderTimeUtils` 用 `<=` 是因为它判定的是**提醒的活跃窗口**，
 * 极值方向本就相反 —— 2026-10-13 曾有人据其把这里改成 `<=`。
 *
 * 配套：`UsageStatsManager.formatTimeRange` 在起止相同时输出「全天」，
 * 避免出现「当前处于免打扰时段（22:00 - 22:00）」这种自我否定文案。
 *
 * @param currentMinutes 当前时刻（当天 00:00 起的分钟数）
 * @param startMinutes  免打扰开始
 * @param endMinutes    免打扰结束
 */
export function isInDowntimeRange(currentMinutes: number, startMinutes: number, endMinutes: number): boolean {
  if (startMinutes < endMinutes) {
    return currentMinutes >= startMinutes && currentMinutes <= endMinutes;
  }
  return currentMinutes >= startMinutes || currentMinutes <= endMinutes;
}
