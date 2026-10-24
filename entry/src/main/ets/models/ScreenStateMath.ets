/**
 * ScreenStateMath —— 屏幕状态统计的纯算术内核
 *
 * `ScreenStateManager` 本身依赖 `power.isActive()` 与 commonEvent 订阅，
 * **在 LocalUnit 环境里完全不可测**（无设备电源服务）。但其中"解锁去重"是一段
 * 纯算术，且它决定"今日解锁次数"这个用户可见的数字是否准确，故单独抽出。
 *
 * 去重的必要性：同一次解锁可能同时来自两个通道——
 *   - 订阅通道 `SCREEN_UNLOCKED` 事件；
 *   - 轮询通道检测到 灭屏 → 亮屏 的跳变（后台收不到事件时的兜底）。
 * 前台两条都会到达，若不去重，一次解锁会被计成两次。
 */

/** 去重时间窗（毫秒） */
export const UNLOCK_DEDUPE_MS = 3000;

/**
 * 判断一次解锁是否应当计入统计
 *
 * @param now 本次解锁时刻
 * @param lastUnlockAt 上一次已计入统计的解锁时刻（0 = 从未计入）
 * @param dedupeMs 去重窗口
 * @returns true = 应计入并把 lastUnlockAt 更新为 now；false = 落在窗口内，应丢弃
 */
export function shouldCountUnlock(now: number, lastUnlockAt: number, dedupeMs: number): boolean {
  return now - lastUnlockAt >= dedupeMs;
}