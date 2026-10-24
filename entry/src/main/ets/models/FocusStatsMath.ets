/**
 * FocusStatsMath —— 专注积分与连击统计的纯计算内核
 *
 * `FocusModeManager` 的计时链路依赖 `setInterval` 与 prefs，无法整体单测；
 * 但"完成一场专注给多少积分"和"历史里最长连续完成了几场"是两段纯算术，
 * 且都直接显示在「我的专注统计」上（积分 / 当前连续 / 最长连续），故抽出。
 *
 * 口径要点（AGENTS 多轮记为"需用户确认"，此处**只固化现状、不改语义**）：
 * 连击加成按**完成本场之后**的连击数发放（2026-08-14 轮从"自增前"改为"自增后"），
 * 即首场 45 分钟 = 45 + min(1×2, 50) = 47 分。
 */

/** 连击加成上限 */
export const STREAK_BONUS_CAP = 50;
/** 每场连击的加成点数 */
const STREAK_BONUS_PER_STREAK = 2;

/** 计算专注积分所需的最小会话信息 */
export interface StreakSession {
  startTime: number;
  completed: boolean;
}

/**
 * 计算一场专注获得的积分
 *
 * @param durationMinutes 本场专注时长（分钟），1 分钟 = 1 基础积分
 * @param streakAfterThisSession 完成本场**之后**的连击数（调用方需先自增）
 * @param cap 连击加成上限
 */
export function computeFocusPoints(durationMinutes: number, streakAfterThisSession: number, cap: number): number {
  return durationMinutes + Math.min(streakAfterThisSession * STREAK_BONUS_PER_STREAK, cap);
}

/**
 * 基于历史会话重算最长连续完成次数
 *
 * 连续的定义：按 `startTime` 升序排列后，`completed` 连续为真的最长一段；
 * 任一未完成的会话（中断）都会打断连续。
 *
 * ⚠️ **不修改入参数组**：调用方传的是实例内的历史数组，
 * 排序必须在副本上做（原实现 `[...history].sort(...)` 就是如此）。
 *
 * @param history 全部历史会话（内部不会被修改）
 */
export function computeLongestStreak(history: StreakSession[]): number {
  const sorted = history.slice().sort((a: StreakSession, b: StreakSession) => a.startTime - b.startTime);
  let maxStreak = 0;
  let current = 0;
  for (let i = 0; i < sorted.length; i++) {
    if (sorted[i].completed) {
      current++;
      if (current > maxStreak) {
        maxStreak = current;
      }
    } else {
      current = 0;
    }
  }
  return maxStreak;
}