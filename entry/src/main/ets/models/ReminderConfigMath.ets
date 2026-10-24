/**
 * ReminderConfigMath —— 健康提醒配置的归一化纯函数内核
 *
 * 背景：提醒的间隔与起止时刻若为非法值（如备份文件里的 `intervalMinutes: 0`
 * 或 `startHour: 99`），调度器会出两类问题——`intervalMinutes <= 0` 让触发分支
 * 永不成立且文案每 10s 都变（空转重发，2026-10-01 轮 #9 的真实 bug）；
 * `startHour=99 > endHour` 被当成「跨午夜窗口」，使提醒在几乎全天误触发。
 * 2026-10-01 轮为此加了 `normalizeConfig` / `normalizeCustomItem`，但它们写在
 * `HealthReminderManager`（715 行、与 prefs/调度器/通知交织）里，**无法单元测试**。
 *
 * 本模块把这些钳位规则抽为无副作用纯函数：全部入参显式传入，
 * 不读单例、不读 prefs、不调 `Date.now()`。
 *
 * 约定：**不做"顺手加固"**——只固化已存在的语义，包括那些看起来奇怪的地方
 * （如非有限数回退到"调用方给的默认值"而非区间下界）。
 */

/** 提醒间隔合法范围（分钟） */
export const MIN_INTERVAL_MINUTES = 1;
export const MAX_INTERVAL_MINUTES = 1440;

const MIN_TIME_PART = 0;
export const MAX_HOUR = 23;
export const MAX_MINUTE = 59;

/**
 * 默认活跃时段 09:00–21:00。
 * 这是全库唯一的"默认时段"定义：`ReminderTimeUtils` 的时段判据、
 * `HealthReminderManager` 的内置/自定义默认配置都引用它，
 * 改动默认值时三处不会再各自漂移。
 */
export const DEFAULT_START_HOUR = 9;
export const DEFAULT_START_MINUTE = 0;
export const DEFAULT_END_HOUR = 21;
export const DEFAULT_END_MINUTE = 0;

/**
 * 钳位单个数值
 *
 * 非有限数（NaN / Infinity，以及 JSON 解析出的 undefined）→ 回退 `fallback`；
 * 其余取整后收拢到 [min, max]。
 *
 * ⚠️ `fallback` 由调用方决定，不是区间下界：例如 `startHour` 非法时回退 9
 * 而不是 0，否则一个写坏的备份会让提醒时段变成「00:00 起」。
 *
 * @param value 待钳位值
 * @param min 下界（含）
 * @param max 上界（含）
 * @param fallback 非有限数时的回退值
 */
export function clampInt(value: number, min: number, max: number, fallback: number): number {
  if (!Number.isFinite(value)) {
    return fallback;
  }
  return Math.max(min, Math.min(max, Math.floor(value)));
}

/** 归一化后的提醒数值字段（title/content/enabled 不属于数值钳位范围，由调用方保留） */
interface NormalizedReminderFields {
  intervalMinutes: number;
  startHour: number;
  startMinute: number;
  endHour: number;
  endMinute: number;
  weekdays: number[];
}

/**
 * 归一化一组提醒数值字段
 *
 * @param intervalMinutes 间隔分钟数
 * @param startHour 起始小时
 * @param startMinute 起始分钟
 * @param endHour 结束小时
 * @param endMinute 结束分钟
 * @param weekdays 星期集合；空数组/非法一律回退「全周」
 * @param fallbackIntervalMinutes 间隔非法时的回退值（内置提醒传各自的默认间隔）
 */
export function normalizeReminderFields(
  intervalMinutes: number,
  startHour: number,
  startMinute: number,
  endHour: number,
  endMinute: number,
  weekdays: number[],
  fallbackIntervalMinutes: number
): NormalizedReminderFields {
  const days = normalizeWeekdays(weekdays);
  return {
    intervalMinutes: clampInt(intervalMinutes, MIN_INTERVAL_MINUTES, MAX_INTERVAL_MINUTES, fallbackIntervalMinutes),
    startHour: clampInt(startHour, MIN_TIME_PART, MAX_HOUR, DEFAULT_START_HOUR),
    startMinute: clampInt(startMinute, MIN_TIME_PART, MAX_MINUTE, DEFAULT_START_MINUTE),
    endHour: clampInt(endHour, MIN_TIME_PART, MAX_HOUR, DEFAULT_END_HOUR),
    endMinute: clampInt(endMinute, MIN_TIME_PART, MAX_MINUTE, DEFAULT_END_MINUTE),
    weekdays: days
  };
}

/**
 * 星期集合归一化：只保留 0–6 的整数，去重；过滤后为空则回退「全周」。
 *
 * 原实现只判 `length > 0`，于是 `[7]` / `[-1]` / `[NaN]` 原样通过：
 * 调度器用 `weekdays.includes(date.getDay())` 判定，这类值永远不命中 ⇒
 * 设置页开关显示「开」、星期芯片却全未选中，提醒**永不触发**且无任何报错。
 * 这正是本函数 JSDoc 承诺过、但实现漏掉的分支。
 */
export function normalizeWeekdays(weekdays: number[]): number[] {
  const out: number[] = [];
  const seen: boolean[] = [false, false, false, false, false, false, false];
  if (weekdays) {
    for (let i = 0; i < weekdays.length; i++) {
      const v: number = weekdays[i];
      if (typeof v !== 'number' || !Number.isFinite(v) || Math.floor(v) !== v) {
        continue;
      }
      if (v < 0 || v > 6 || seen[v]) {
        continue;
      }
      seen[v] = true;
      out.push(v);
    }
  }
  return out.length > 0 ? out : [0, 1, 2, 3, 4, 5, 6];
}

/**
 * 归一化自定义提醒的 notificationId 分配
 *
 * 规则（`importData` 与 `loadCustomItems` 必须共用同一条，否则两条路径行为分叉）：
 * **仅当入参 id 严格大于"已见的最大值"时才沿用**，否则分配一个更大的新 id。
 *
 * 为什么不能只判 `>= CUSTOM_BASE`：持久化数据里出现重复 id 时（备份被手工改写、
 * 多次导入叠加），两条提醒会共用同一个通知 id —— 横幅只能显示最后一条，
 * repost 回调互相覆盖，删除也只能撤掉其中一条。
 *
 * @param candidate 持久化数据里记录的 id（非数字/低于 base 一律视为不可用）
 * @param base 自定义提醒 id 段的起点
 * @param maxSeen 当前已见的最大 id（分配后需回写为返回值）
 * @returns [实际使用的 id, 新的 maxSeen]
 */
export function resolveCustomNotificationId(
  candidate: number,
  base: number,
  maxSeen: number
): number[] {
  if (typeof candidate === 'number' && Number.isFinite(candidate)
    && candidate >= base && candidate > maxSeen) {
    return [candidate, candidate];
  }
  const next = maxSeen + 1;
  return [next, next];
}