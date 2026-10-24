/**
 * SleepScoreMath —— 睡前习惯评分与改善建议的纯计算内核
 *
 * `SleepManager` 的数据层依赖 `preferences`、华为运动健康 IPC 与定时器，无法整体单测；
 * 但"这段睡眠该打多少分"和"该给用户提什么建议"是两段纯算术，
 * 且都直接显示在睡前页（评分环 / 改善建议列表），故抽出。
 *
 * 口径要点（**只固化现状、不改语义**）：
 * - 评分从 100 分起扣，扣完钳到 [0, 100]；
 * - 睡眠时长的**不扣分区间是 7–9 小时**（420–540 分钟）：360–420 仍扣 10 分，
 *   仅"看起来在 6–9 小时内"不足以不扣分（阈值见下方三个常量）；
 * - 建议列表恒非空：无任何异常项时给一条兜底的正面评价。
 *
 * ⚠️ 文案逐字照搬 `SleepManager` 原实现，改动前必须先读原文核对，
 * 不可凭语义重写（用户可见文本）。
 */

/** 评分下限 */
export const SCORE_MIN = 0;
/** 评分上限（也是起扣基准分） */
export const SCORE_MAX = 100;

/**
 * 睡眠时长扣分阈值（分钟）—— **仅在未提供睡眠目标时使用**（保持历史口径 7–9 小时为佳）。
 *
 * 一旦用户设置了睡眠目标（goalMinutes 有效），阈值改按目标的比例推导，见
 * {@link DURATION_LOW_RATIO} 等。原先无论用户把目标设成 4 小时还是 12 小时，
 * 都按固定的 360/420/540 判分 —— 目标 4 小时时睡 5 小时会同时出现
 * 「进度 100%（达标）」与「评分 80 需要注意」两种互相矛盾的结论。
 */
const DURATION_LOW_MINUTES = 360;
const DURATION_SOFT_LOW_MINUTES = 420;
const DURATION_HIGH_MINUTES = 540;

/** 有目标时的相对阈值：低于目标的 85% 扣 20 分 */
const DURATION_LOW_RATIO = 0.85;
/** 有目标时的相对阈值：低于目标本身扣 10 分 */
const DURATION_GAP_RATIO = 1.0;
/** 有目标时的相对阈值：超过目标的 135% 扣 5 分（睡过多） */
const DURATION_HIGH_RATIO = 1.35;

/** 睡眠目标为有效值（可用于比例判分） */
function hasGoal(goalMinutes?: number): boolean {
  return goalMinutes !== undefined && goalMinutes > 0 && Number.isFinite(goalMinutes);
}

/** 睡前使用扣分阈值（分钟）—— 超过它扣 20 分 */
const PRE_SLEEP_HIGH_MINUTES = 60;
/** 睡前使用扣分阈值（分钟）—— 超过它扣 10 分 */
const PRE_SLEEP_SOFT_MINUTES = 30;

/** 深睡时长建议的下限阈值（分钟）—— 低于它给"深睡偏少"建议 */
const DEEP_SLEEP_LOW_MINUTES = 60;

/** 睡前使用时长超过阈值时，建议文案里给出的默认休息窗口（分钟） */
const DEFAULT_PRESLEEP_REST_MINUTES = 60;

/**
 * 计算睡前习惯评分
 *
 * @param sleepDurationMinutes 本次睡眠时长（分钟）
 * @param preSleepUsageMinutes 睡前使用时长（分钟）
 * @param goalMinutes 用户设置的睡眠目标（分钟）。传入有效值时，睡眠时长的判分
 *                   按目标比例推导；不传或非法时沿用固定阈值（7–9 小时为佳）的历史口径。
 * @returns 0–100 的整数分
 */
export function computeSleepScore(
  sleepDurationMinutes: number,
  preSleepUsageMinutes: number,
  goalMinutes?: number
): number {
  let score = SCORE_MAX;

  // 睡眠时长：优先按用户目标判，未设目标时按 7–9 小时判
  if (hasGoal(goalMinutes)) {
    const goal = goalMinutes as number;
    if (sleepDurationMinutes < goal * DURATION_LOW_RATIO) {
      score -= 20;
    } else if (sleepDurationMinutes < goal * DURATION_GAP_RATIO) {
      score -= 10;
    } else if (sleepDurationMinutes > goal * DURATION_HIGH_RATIO) {
      score -= 5;
    }
  } else if (sleepDurationMinutes < DURATION_LOW_MINUTES) {
    // 不扣分区间是 7–9 小时（420–540）
    score -= 20;
  } else if (sleepDurationMinutes < DURATION_SOFT_LOW_MINUTES) {
    score -= 10;
  } else if (sleepDurationMinutes > DURATION_HIGH_MINUTES) {
    score -= 5;
  }

  // 睡前使用时间：超过 30 分钟扣分
  if (preSleepUsageMinutes > PRE_SLEEP_HIGH_MINUTES) {
    score -= 20;
  } else if (preSleepUsageMinutes > PRE_SLEEP_SOFT_MINUTES) {
    score -= 10;
  }

  return Math.max(SCORE_MIN, Math.min(SCORE_MAX, score));
}

/**
 * 生成睡前改善建议
 *
 * 恒返回**至少一条**建议（无异常项时给兜底的正面评价），供睡前页直接 ForEach 渲染。
 *
 * @param sleepDurationMinutes 本次睡眠时长（分钟）
 * @param preSleepUsageMinutes 睡前使用时长（分钟）
 * @param deepSleepMinutes 深睡时长（分钟），undefined/null 视为 0
 * @param enablePreSleepRestriction 是否启用了自定义睡前统计窗口
 * @param preSleepRestrictionMinutes 自定义统计窗口（分钟），仅在上一项为 true 时采用
 * @param goalMinutes 用户设置的睡眠目标（分钟）。有效时按目标给建议，避免目标设成 4 小时
 *                   却被告知「建议今晚争取 7-8 小时」这种自相矛盾的话。
 */
export function generateSleepAdvices(
  sleepDurationMinutes: number,
  preSleepUsageMinutes: number,
  deepSleepMinutes: number | undefined,
  enablePreSleepRestriction: boolean,
  preSleepRestrictionMinutes: number,
  goalMinutes?: number
): string[] {
  const advices: string[] = [];

  if (preSleepUsageMinutes > PRE_SLEEP_SOFT_MINUTES) {
    // 启用睡前使用限制时按配置窗口给出放下手机的提前量建议，否则维持默认「1 小时」
    const restMinutes = enablePreSleepRestriction ? preSleepRestrictionMinutes : DEFAULT_PRESLEEP_REST_MINUTES;
    advices.push(`睡前使用手机 ${preSleepUsageMinutes} 分钟，建议睡前${restMinutes}分钟放下手机`);
  }

  const actualHours = Math.floor(sleepDurationMinutes / 60);
  if (hasGoal(goalMinutes)) {
    // 有目标：只在他确实没睡够时才提建议，并引用**他自己的目标**
    const goal = goalMinutes as number;
    if (sleepDurationMinutes < goal) {
      const gapHours = Math.max(1, Math.round((goal - sleepDurationMinutes) / 60));
      advices.push(`昨晚睡眠约 ${actualHours}小时，距离你设定的 ${Math.round(goal / 60)}小时目标还差约 ${gapHours}小时`);
    }
  } else if (sleepDurationMinutes < DURATION_SOFT_LOW_MINUTES) {
    advices.push(`昨晚睡眠约 ${actualHours}小时，建议今晚争取 7-8小时`);
  }

  const deepMinutes = deepSleepMinutes ?? 0;
  if (deepMinutes > 0 && deepMinutes < DEEP_SLEEP_LOW_MINUTES) {
    advices.push(`深睡仅 ${deepMinutes} 分钟，睡前避免饮酒或过度兴奋`);
  }

  if (advices.length === 0) {
    advices.push('睡眠状态良好，请保持规律作息');
  }

  return advices;
}