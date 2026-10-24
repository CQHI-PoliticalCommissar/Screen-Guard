import { describe, it, expect } from '@ohos/hypium';
import {
  clampInt,
  normalizeReminderFields,
  resolveCustomNotificationId,
  MIN_INTERVAL_MINUTES,
  MAX_INTERVAL_MINUTES,
  MAX_HOUR,
  MAX_MINUTE,
  DEFAULT_START_HOUR,
  DEFAULT_END_HOUR
} from '../main/ets/models/ReminderConfigMath';
import { UNLOCK_DEDUPE_MS, shouldCountUnlock } from '../main/ets/models/ScreenStateMath';
import { formatError } from '../main/ets/models/ErrUtils';
import { DailyGoalManager } from '../main/ets/managers/DailyGoalManager';
import {
  HealthReminderConfig,
  CustomReminderItem,
  copyReminderConfig,
  copyCustomReminderItem
} from '../main/ets/models/ReminderItemTypes';
import {
  computeSleepScore,
  generateSleepAdvices,
  SCORE_MIN,
  SCORE_MAX
} from '../main/ets/models/SleepScoreMath';
import {
  STREAK_BONUS_CAP,
  computeFocusPoints,
  computeLongestStreak,
  StreakSession
} from '../main/ets/models/FocusStatsMath';
import { HealthStatus, LightSenseColor, AppCategory, STATUS_COLOR_MAP, getDayStartTimestamp, formatDate, formatHourMinute, getTodayDateString, isYesterdayDateKey, ACCENT_COLOR_PRESETS, accentTextHex, accentFillHex } from '../main/ets/models/HealthTypes';
import {
  ACCENT_BG_DARK,
  ACCENT_BG_LIGHT,
  MIN_ACCENT_CONTRAST,
  contrastRatio,
  deriveAccentFillColor,
  deriveAccentTextColor,
  describeHexInputError,
  normalizeHexColor
} from '../main/ets/models/AccentColorMath';
import { greetingWithNickname, normalizeNickname } from '../main/ets/models/Personalization';
import {
  isInActiveWindow,
  nextActiveStartMs,
  dateKey,
  dateKeyFromDate,
  todayAtMs,
  formatRemain,
  formatTime,
  formatDateTime,
  OngoingReminderSpec
} from '../main/ets/managers/ReminderTimeUtils';
import {
  ScreenOnRecord,
  DailyUsageEntry,
  sumRecordSeconds,
  computeLiveSeconds,
  splitSessionAtMidnight,
  mergeDailyHistory,
  computeStreakDays,
  computeUsedDaysStreak,
  computeOverlapInWindow,
  sumSecondsInWindow,
  computeLimitTierIndex,
  limitTiersToClearFlag,
  limitTiersToCancel,
  limitTiersSupersededBy,
  isInDowntimeRange,
  LIMIT_TIER_NONE,
  LIMIT_TIER_50,
  LIMIT_TIER_80,
  LIMIT_TIER_100
} from '../main/ets/models/UsageStatsMath';
import {
  ALERT_SHOW_MS,
  ONESHOT_ALERT_SHOW_MS,
  MIN_EFFECTIVE_INTERVAL_MS,
  deriveIntervalInitState,
  deriveDailyInitDateKey,
  intervalTickStep,
  dailyTickStep,
  oneShotTickStep,
  shouldPublish,
  OneShotPhase
} from '../main/ets/models/ReminderScheduleMath';
import {
  HomeCardConfigEntry,
  defaultHomeCardConfig,
  isHomeCardVisible,
  migrateLegacyHomeCardConfig,
  moveHomeCardInConfig,
  parseHomeCardConfig,
  setHomeCardVisible,
  visibleHomeCardCount,
  visibleHomeCardIds,
  visibleIndexOfHomeCard
} from '../main/ets/models/HomeCardLayout';

/**
 * 由 (id, visible) 扁平序列拼出布局 JSON 文本。
 * 不用对象字面量是为了绕开 ArkTS 的"无类型对象字面量"限制。
 */
function layoutJson(pairs: string[]): string {
  const parts: string[] = [];
  for (let i = 0; i + 1 < pairs.length; i += 2) {
    parts.push('{"id":"' + pairs[i] + '","visible":' + pairs[i + 1] + '}');
  }
  return '[' + parts.join(',') + ']';
}

/** 与 HarmonyOS BusinessError 同形的测试替身（避免测试文件直接依赖 @kit） */
interface BusinessErrorLike {
  code: number;
  message?: string;
}

// 测试辅助：以 2026-10-10 为基准构造一条亮屏记录（startMin/endMin 为距当日 00:00 的分钟数）
function makeRec(date: string, startMin: number, endMin: number): ScreenOnRecord {
  const base = new Date(2026, 9, 10, 0, 0, 0, 0).getTime();
  const r: ScreenOnRecord = {
    date: date,
    startTime: base + startMin * 60000,
    endTime: base + endMin * 60000
  };
  return r;
}

// 测试辅助：构造一条专注会话（辅助函数必须在模块级，不能定义在 describe 回调内）
function sess(startTime: number, completed: boolean): StreakSession {
  return { startTime: startTime, completed: completed };
}

// 测试辅助：计算某 hex 与白色之间的 WCAG 对比度（用于锁定强调色填充色可承载白字）
function contrastWithWhite(hex: string): number {
  const r: number = parseInt(hex.substring(1, 3), 16) / 255;
  const g: number = parseInt(hex.substring(3, 5), 16) / 255;
  const b: number = parseInt(hex.substring(5, 7), 16) / 255;
  let rr: number = r;
  let gg: number = g;
  let bb: number = b;
  if (rr > 0.03928) { rr = Math.pow((rr + 0.055) / 1.055, 2.4); } else { rr = rr / 12.92; }
  if (gg > 0.03928) { gg = Math.pow((gg + 0.055) / 1.055, 2.4); } else { gg = gg / 12.92; }
  if (bb > 0.03928) { bb = Math.pow((bb + 0.055) / 1.055, 2.4); } else { bb = bb / 12.92; }
  const l: number = 0.2126 * rr + 0.7152 * gg + 0.0722 * bb;
  return 1.05 / (l + 0.05);
}

export default function localUnitTest() {
  describe('HealthTypes', () => {
    it('formatDate_pads_single_digit_month_and_day', 0, () => {
      expect(formatDate(new Date(2026, 0, 5))).assertEqual('2026-01-05');
    });

    it('formatDate_pads_two_digit_month_and_day', 0, () => {
      expect(formatDate(new Date(2026, 10, 25))).assertEqual('2026-11-25');
    });

    it('formatDate_uses_full_year', 0, () => {
      expect(formatDate(new Date(2030, 11, 31))).assertEqual('2030-12-31');
    });

    it('getDayStartTimestamp_returns_midnight_of_same_day', 0, () => {
      const ts = getDayStartTimestamp('2026-08-03');
      const d = new Date(ts);
      expect(d.getFullYear()).assertEqual(2026);
      expect(d.getMonth()).assertEqual(7);
      expect(d.getDate()).assertEqual(3);
      expect(d.getHours()).assertEqual(0);
      expect(d.getMinutes()).assertEqual(0);
    });

    it('getDayStartTimestamp_is_leap_year_safe', 0, () => {
      const ts = getDayStartTimestamp('2024-02-29');
      expect(new Date(ts).getDate()).assertEqual(29);
    });

    it('status_color_map_matches_light_sense_colors', 0, () => {
      expect(STATUS_COLOR_MAP[HealthStatus.NORMAL]).assertEqual(LightSenseColor.NORMAL);
      expect(STATUS_COLOR_MAP[HealthStatus.WARNING]).assertEqual(LightSenseColor.WARNING);
      expect(STATUS_COLOR_MAP[HealthStatus.EMERGENCY]).assertEqual(LightSenseColor.EMERGENCY);
    });

    it('health_status_enum_has_all_states', 0, () => {
      expect(HealthStatus.NORMAL).assertEqual('normal');
      expect(HealthStatus.WARNING).assertEqual('warning');
      expect(HealthStatus.EMERGENCY).assertEqual('emergency');
    });

    it('app_category_enum_values_are_stable', 0, () => {
      expect(AppCategory.SOCIAL).assertEqual('social');
      expect(AppCategory.VIDEO).assertEqual('video');
      expect(AppCategory.GAME).assertEqual('game');
      expect(AppCategory.PRODUCTIVITY).assertEqual('productivity');
      expect(AppCategory.SYSTEM).assertEqual('system');
      expect(AppCategory.OTHER).assertEqual('other');
    });

    it('formatHourMinute_pads_single_digit_hour_and_minute', 0, () => {
      expect(formatHourMinute(8, 5)).assertEqual('08:05');
      expect(formatHourMinute(0, 0)).assertEqual('00:00');
    });

    it('formatHourMinute_keeps_two_digit_hour_and_minute', 0, () => {
      expect(formatHourMinute(23, 59)).assertEqual('23:59');
      expect(formatHourMinute(9, 30)).assertEqual('09:30');
    });

    // 刻意锁死"不钳位"契约：本函数是第 13 轮从 6 份重复实现收敛而来的，
    // 原实现对越界/非法入参原样输出（如 '99:75'）。若将来有人"顺手加固"改成钳位，
    // 备份恢复路径注入的非法时刻在停用时间/健康提醒文案上的表现就会静默改变。
    it('formatHourMinute_does_not_clamp_out_of_range_input', 0, () => {
      expect(formatHourMinute(99, 75)).assertEqual('99:75');
      expect(formatHourMinute(-1, -5)).assertEqual('-1:-5');
    });

    // ===== getTodayDateString =====
    // 这是全库**零单测却承担 27 处生产引用**的日期判据：跨日清零（checkDateRollover）
    // 与跨日打卡判定（DailyGoalManager.checkNewDay）读的是同一份"今天"，
    // 它一旦算错，两处跨日行为会同时静默损坏（清零不发生 / 目标被误清空）。
    it('getTodayDateString_matches_formatDate_of_now', 0, () => {
      expect(getTodayDateString()).assertEqual(formatDate(new Date()));
    });

    it('getTodayDateString_has_padded_YYYY_MM_DD_shape', 0, () => {
      // 正则锁形状：4 位年 - 2 位月 - 2 位日，任何补零/截断改动都会被抓到
      expect(/^\d{4}-\d{2}-\d{2}$/.test(getTodayDateString())).assertTrue();
    });

    it('getTodayDateString_is_stable_within_the_same_second_bucket', 0, () => {
      // 秒桶缓存的契约：同一秒内多次调用必须逐字节相同（它是首页 1s tick 上被调 5 次的热点）
      const first = getTodayDateString();
      expect(getTodayDateString()).assertEqual(first);
      expect(getTodayDateString()).assertEqual(first);
    });

    it('getTodayDateString_uses_local_calendar_date_not_utc', 0, () => {
      // 锁死"本地日期"口径：若有人把实现改成 UTC（如 toISOString().slice(0,10)），
      // 在本地 00:00-08:00 这段 UTC 仍是前一天，跨日清零与打卡判定会整体偏移。
      // 手工按 getFullYear/getMonth/getDate 拼一次即是对照系（UTC 版本必然不等）。
      const d = new Date();
      const y = d.getFullYear().toString();
      const mo = (d.getMonth() + 1).toString().padStart(2, '0');
      const da = d.getDate().toString().padStart(2, '0');
      expect(getTodayDateString()).assertEqual(y + '-' + mo + '-' + da);
    });

    it('getTodayDateString_is_never_empty', 0, () => {
      // 缓存初始值 todayDateCache='' 且 todayDateCacheSecond=-1，
      // 若秒桶判定写错（-1 === Math.floor(now/1000) 恒假/恒真），首调就会返回空串
      expect(getTodayDateString().length > 0).assertTrue();
    });
  });

  describe('ReminderTimeUtils', () => {
    it('isInActiveWindow_within_window_returns_true', 0, () => {
      const spec: OngoingReminderSpec = { notificationId: 1, title: 't', content: 'c', unremovable: true, startHour: 9, startMinute: 0, endHour: 18, endMinute: 0, weekdays: [1, 2, 3, 4, 5] };
      // 2026-08-03 是周一（day=1）
      expect(isInActiveWindow(spec, new Date(2026, 7, 3, 10, 0))).assertTrue();
      expect(isInActiveWindow(spec, new Date(2026, 7, 3, 9, 0))).assertTrue();
      expect(isInActiveWindow(spec, new Date(2026, 7, 3, 18, 0))).assertTrue();
    });

    it('isInActiveWindow_outside_window_or_weekday_returns_false', 0, () => {
      const spec: OngoingReminderSpec = { notificationId: 1, title: 't', content: 'c', unremovable: true, startHour: 9, startMinute: 0, endHour: 18, endMinute: 0, weekdays: [1, 2, 3, 4, 5] };
      expect(isInActiveWindow(spec, new Date(2026, 7, 3, 8, 59))).assertFalse();
      expect(isInActiveWindow(spec, new Date(2026, 7, 3, 18, 1))).assertFalse();
      // 2026-08-02 是周日（day=0），不在 [1,2,3,4,5] 中
      expect(isInActiveWindow(spec, new Date(2026, 7, 2, 10, 0))).assertFalse();
      const noWeekdays: OngoingReminderSpec = { notificationId: 2, title: 't', content: 'c', unremovable: true, startHour: 9, endHour: 18, weekdays: [] };
      expect(isInActiveWindow(noWeekdays, new Date(2026, 7, 3, 10, 0))).assertFalse();
    });

    it('isInActiveWindow_cross_midnight_window', 0, () => {
      const spec: OngoingReminderSpec = { notificationId: 3, title: 't', content: 'c', unremovable: true, startHour: 22, startMinute: 0, endHour: 6, endMinute: 0, weekdays: [0, 1, 2, 3, 4, 5, 6] };
      expect(isInActiveWindow(spec, new Date(2026, 7, 3, 23, 0))).assertTrue();
      expect(isInActiveWindow(spec, new Date(2026, 7, 4, 3, 0))).assertTrue();
      expect(isInActiveWindow(spec, new Date(2026, 7, 3, 12, 0))).assertFalse();
    });

    it('isInActiveWindow_cross_midnight_early_segment_belongs_to_previous_weekday', 0, () => {
      // 仅周一活跃的 22:00-02:00 窗口：
      // 2026-08-03 是周一(day=1)，故周一 23:00 与周二 01:00 均应活跃（后者归属周一的窗口），
      // 而周二 23:00（周三窗口未开启）与周日 01:00（归属周六，未开启）应为 false。
      const mondayOnly: OngoingReminderSpec = { notificationId: 5, title: 't', content: 'c', unremovable: true, startHour: 22, startMinute: 0, endHour: 2, endMinute: 0, weekdays: [1] };
      expect(isInActiveWindow(mondayOnly, new Date(2026, 7, 3, 23, 0))).assertTrue();  // 周一 23:00
      expect(isInActiveWindow(mondayOnly, new Date(2026, 7, 4, 1, 0))).assertTrue();   // 周二 01:00 → 属周一窗口
      expect(isInActiveWindow(mondayOnly, new Date(2026, 7, 4, 2, 0))).assertTrue();   // 边界 end 闭区间
      expect(isInActiveWindow(mondayOnly, new Date(2026, 7, 4, 2, 1))).assertFalse();  // 越过 end
      expect(isInActiveWindow(mondayOnly, new Date(2026, 7, 4, 23, 0))).assertFalse(); // 周二晚间未开启
      // 周一 00:00 归属周日窗口（周日未开启）→ false
      expect(isInActiveWindow(mondayOnly, new Date(2026, 7, 3, 0, 30))).assertFalse();
    });

    it('nextActiveStartMs_returns_next_active_window_start', 0, () => {
      const spec: OngoingReminderSpec = { notificationId: 4, title: 't', content: 'c', unremovable: true, startHour: 9, startMinute: 0, weekdays: [1] };
      // 周一 20:00 之后的下一个活跃开始 = 下周一 09:00
      const next = nextActiveStartMs(spec, new Date(2026, 7, 3, 20, 0).getTime());
      const d = new Date(next);
      expect(d.getFullYear()).assertEqual(2026);
      expect(d.getMonth()).assertEqual(7);
      expect(d.getDate()).assertEqual(10);
      expect(d.getHours()).assertEqual(9);
      expect(d.getMinutes()).assertEqual(0);
      // 周一 08:00 之前的下一个活跃开始 = 当天 09:00
      const sameDay = new Date(nextActiveStartMs(spec, new Date(2026, 7, 3, 8, 0).getTime()));
      expect(sameDay.getDate()).assertEqual(3);
      expect(sameDay.getHours()).assertEqual(9);
    });

    it('dateKey_formats_padded_local_date', 0, () => {
      expect(dateKey(new Date(2026, 0, 5).getTime())).assertEqual('2026-01-05');
      expect(dateKey(new Date(2026, 10, 25).getTime())).assertEqual('2026-11-25');
    });

    it('formatRemain_uses_sensible_units', 0, () => {
      expect(formatRemain(30000)).assertEqual('30 秒');
      expect(formatRemain(0)).assertEqual('0 秒');
      expect(formatRemain(90000)).assertEqual('1 分钟');
      expect(formatRemain(61000)).assertEqual('1 分钟');
      expect(formatRemain(3600000)).assertEqual('1 小时');
      expect(formatRemain(5400000)).assertEqual('1 小时 30 分钟');
    });

    it('formatTime_pads_hour_and_minute', 0, () => {
      expect(formatTime(new Date(2026, 7, 3, 9, 5).getTime())).assertEqual('09:05');
      expect(formatTime(new Date(2026, 7, 3, 22, 30).getTime())).assertEqual('22:30');
    });

    it('formatDateTime_today_and_tomorrow', 0, () => {
      const today = new Date();
      today.setHours(9, 5, 0, 0);
      expect(formatDateTime(today.getTime())).assertEqual('今天 09:05');
      const tomorrow = new Date();
      tomorrow.setDate(tomorrow.getDate() + 1);
      tomorrow.setHours(20, 0, 0, 0);
      expect(formatDateTime(tomorrow.getTime())).assertEqual('明天 20:00');
    });

    it('formatDateTime_far_date_uses_weekday_name', 0, () => {
      const far = new Date();
      far.setDate(far.getDate() + 6);
      far.setHours(12, 0, 0, 0);
      const result = formatDateTime(far.getTime());
      expect(result).assertContain('12:00');
      expect(result.startsWith('今天')).assertFalse();
      expect(result.startsWith('明天')).assertFalse();
    });

    // ===== dateKeyFromDate =====
    // dateKey 只是它的委托包装（2026-10-06 第 4 轮为 10s tick 共享 Date 实例而拆出），
    // 包装层有单测、真正的拼接实现一直没有直接用例。
    it('dateKeyFromDate_matches_dateKey_for_the_same_instant', 0, () => {
      expect(dateKeyFromDate(new Date(2026, 7, 3, 9, 5))).assertEqual(dateKey(new Date(2026, 7, 3, 9, 5).getTime()));
      expect(dateKeyFromDate(new Date(2026, 0, 1, 23, 59))).assertEqual('2026-01-01');
    });

    it('dateKeyFromDate_does_not_mutate_the_input_date', 0, () => {
      // 契约：只用 getFullYear/getMonth/getDate，绝不 set* 改传入的 Date。
      // 该函数与同一个 Date 实例共享给 intervalTick / dailyTick（2026-10-06 第 4 轮），
      // 一旦改动入参，10s tick 的排期计算会被静默污染。
      const d = new Date(2026, 7, 3, 9, 5, 30, 250);
      const before = d.getTime();
      dateKeyFromDate(d);
      expect(d.getTime()).assertEqual(before);
      expect(d.getHours()).assertEqual(9);
      expect(d.getMinutes()).assertEqual(5);
      expect(d.getSeconds()).assertEqual(30);
    });

    it('dateKeyFromDate_keeps_month_and_day_padded_across_boundaries', 0, () => {
      // 月末/年末/闰年：跨日判据在这些日子最容易出现 '2026-1-1' 或 '2024-2-30'
      expect(dateKeyFromDate(new Date(2026, 11, 31, 23, 59, 59))).assertEqual('2026-12-31');
      expect(dateKeyFromDate(new Date(2024, 1, 29, 12))).assertEqual('2024-02-29');
      expect(dateKeyFromDate(new Date(2026, 8, 9, 0, 0, 0))).assertEqual('2026-09-09');
    });

    // ===== todayAtMs =====
    it('todayAtMs_lands_on_today_at_the_given_wall_clock_time', 0, () => {
      const ms = todayAtMs(9, 5);
      const d = new Date(ms);
      const today = new Date();
      expect(d.getFullYear()).assertEqual(today.getFullYear());
      expect(d.getMonth()).assertEqual(today.getMonth());
      expect(d.getDate()).assertEqual(today.getDate());
      expect(d.getHours()).assertEqual(9);
      expect(d.getMinutes()).assertEqual(5);
      expect(d.getSeconds()).assertEqual(0);
      expect(d.getMilliseconds()).assertEqual(0);
    });

    it('todayAtMs_is_zeroed_out_at_midnight_and_end_of_day', 0, () => {
      expect(new Date(todayAtMs(0, 0)).getHours()).assertEqual(0);
      expect(new Date(todayAtMs(23, 59)).getMinutes()).assertEqual(59);
    });

    it('todayAtMs_does_not_clamp_out_of_range_input', 0, () => {
      // 刻意锁死"不钳位"契约：setHours 对越界值按 JS 语义进位，
      // 若将来有人加钳位，备份注入的非法时刻在提醒排期上的表现会静默改变。
      const overflow = new Date(todayAtMs(25, 0));
      const base = new Date(todayAtMs(1, 0));
      // ⚠️ 不能写成 `overflow.getDate() === base.getDate() + 1`：月末会变成
      // 1 vs 32 而假失败（2026-10 审计发现）。用 Date 构造器进位，跨月/跨年都正确。
      const expected = new Date(base.getFullYear(), base.getMonth(), base.getDate() + 1, 1, 0, 0, 0);
      expect(overflow.getTime()).assertEqual(expected.getTime());
    });

    it('todayAtMs_handles_month_and_year_boundaries', 0, () => {
      // 24 点 = 次日 00:00（与 0 点相差整 24h）；这条不依赖"今天是几号"，月末/年末都不假失败
      const zero = new Date(todayAtMs(0, 0));
      const lastHour = new Date(todayAtMs(24, 0));
      expect(lastHour.getTime() - zero.getTime()).assertEqual(24 * 3600 * 1000);
      expect(lastHour.getHours()).assertEqual(0);
    });
  });

  // 以下用例锁定的都是 UsageStatsManager 历史上**真实出过 bug** 的算法。
  // 2026-10-10 把这些计算从 manager（与 prefs/实例状态/Date.now 交织，无法单测）
  // 抽到 models/UsageStatsMath 纯函数模块后，才有条件把它们钉死。
  describe('UsageStatsMath', () => {
    const D = '2026-10-10';
    const D1 = '2026-10-09';
    const D2 = '2026-10-08';

    // ---- sumRecordSeconds ----
    it('sumRecordSeconds_only_counts_the_matching_date', 0, () => {
      const records: ScreenOnRecord[] = [makeRec(D, 0, 10), makeRec(D, 100, 130), makeRec(D1, 0, 60)];
      expect(sumRecordSeconds(records, D)).assertEqual((10 + 30) * 60);   // 600+1800 秒
      expect(sumRecordSeconds(records, D1)).assertEqual(60 * 60);
      expect(sumRecordSeconds(records, '2026-10-07')).assertEqual(0);
    });

    it('sumRecordSeconds_truncates_partial_seconds', 0, () => {
      const r: ScreenOnRecord = { date: D, startTime: 0, endTime: 5500 };
      expect(sumRecordSeconds([r], D)).assertEqual(5);
    });

    // ---- computeLiveSeconds ----
    it('computeLiveSeconds_adds_ongoing_session_to_todays_records', 0, () => {
      const base = new Date(2026, 9, 10, 12, 0, 0, 0).getTime();
      const records: ScreenOnRecord[] = [makeRec(D, 0, 10)];
      // 进行中会话从 12:00 开始，now=12:05 → 300 秒
      expect(computeLiveSeconds(records, D, base, base + 300000)).assertEqual(600 + 300);
    });

    it('computeLiveSeconds_ignores_ongoing_session_when_start_is_zero', 0, () => {
      const records: ScreenOnRecord[] = [makeRec(D, 0, 10)];
      const base = new Date(2026, 9, 10, 12, 0, 0, 0).getTime();
      expect(computeLiveSeconds(records, D, 0, base)).assertEqual(600);
    });

    // 回归用例（真实 bug 2026-08-04「翻倍累计」）：
    // watermark 与 live 取大是正确的，但 onScreenOff 若再 `+= seconds` 就会翻倍。
    // 本用例锁定 live 的口径：进行中会话只算一次，不因 records 里已有它而重复。
    it('computeLiveSeconds_does_not_double_count_a_settled_session', 0, () => {
      const records: ScreenOnRecord[] = [makeRec(D, 0, 10)];
      const base = new Date(2026, 9, 10, 0, 0, 0, 0).getTime();
      const start = base;
      const now = base + 600000;
      // 模拟：会话尚未结算（records 里没有它），只靠 currentScreenOnStart 计
      expect(computeLiveSeconds([], D, start, now)).assertEqual(600);
      // 结算后 records 里有它，进行中会话已清零 —— 仍是 600，不是 1200
      const settled: ScreenOnRecord[] = [makeRec(D, 0, 10)];
      expect(computeLiveSeconds(settled, D, 0, now)).assertEqual(600);
    });

    // ---- splitSessionAtMidnight（跨日拆分，真实 bug 重灾区）----
    it('splitSessionAtMidnight_splits_a_session_that_crossed_midnight', 0, () => {
      const midnight = new Date(2026, 9, 10, 0, 0, 0, 0).getTime();
      const start = new Date(2026, 9, 9, 23, 30, 0, 0).getTime();   // 昨日 23:30
      const now = new Date(2026, 9, 10, 0, 30, 0, 0).getTime();    // 今日 00:30
      const r = splitSessionAtMidnight(start, midnight, now);
      expect(r.yesterdaySeconds).assertEqual(30 * 60);
      expect(r.nextSessionStart).assertEqual(midnight);
    });

    it('splitSessionAtMidnight_leaves_a_session_started_today_untouched', 0, () => {
      const midnight = new Date(2026, 9, 10, 0, 0, 0, 0).getTime();
      const start = new Date(2026, 9, 10, 8, 0, 0, 0).getTime();
      const now = new Date(2026, 9, 10, 9, 0, 0, 0).getTime();
      const r = splitSessionAtMidnight(start, midnight, now);
      expect(r.yesterdaySeconds).assertEqual(0);
      expect(r.nextSessionStart).assertEqual(start);
    });

    it('splitSessionAtMidnight_handles_no_ongoing_session', 0, () => {
      const midnight = new Date(2026, 9, 10, 0, 0, 0, 0).getTime();
      const now = new Date(2026, 9, 10, 1, 0, 0, 0).getTime();
      const r = splitSessionAtMidnight(0, midnight, now);
      expect(r.yesterdaySeconds).assertEqual(0);
      expect(r.nextSessionStart).assertEqual(0);
    });

    // 回归用例（真实 bug 2026-08-04「跨午夜会话全段误记昨日」）：
    // 修复前把 start→now 整段算进昨日，00:00 之后的部分也被算成昨天。
    it('splitSessionAtMidnight_does_not_count_post_midnight_time_as_yesterday', 0, () => {
      const midnight = new Date(2026, 9, 10, 0, 0, 0, 0).getTime();
      const start = new Date(2026, 9, 9, 23, 50, 0, 0).getTime();  // 跨了 10 分钟
      const now = new Date(2026, 9, 10, 2, 0, 0, 0).getTime();    // 跨了 2 小时
      const r = splitSessionAtMidnight(start, midnight, now);
      // 只有 23:50→00:00 这 10 分钟属于昨日，而非整段 2 小时 10 分钟
      expect(r.yesterdaySeconds).assertEqual(600);
    });

    it('splitSessionAtMidnight_caps_yesterday_at_midnight_when_now_is_before_it', 0, () => {
      const midnight = new Date(2026, 9, 10, 0, 0, 0, 0).getTime();
      const start = new Date(2026, 9, 9, 23, 0, 0, 0).getTime();
      const now = new Date(2026, 9, 9, 23, 59, 0, 0).getTime();  // 仍在昨日（时钟被回拨的极端情形）
      const r = splitSessionAtMidnight(start, midnight, now);
      expect(r.yesterdaySeconds).assertEqual(59 * 60);
    });

    // ---- mergeDailyHistory ----
    it('mergeDailyHistory_appends_when_date_absent', 0, () => {
      const h: DailyUsageEntry[] = [];
      mergeDailyHistory(h, D, 600);
      expect(h.length).assertEqual(1);
      expect(h[0].date).assertEqual(D);
      expect(h[0].totalMinutes).assertEqual(10);
    });

    it('mergeDailyHistory_takes_max_and_never_shrinks', 0, () => {
      const h: DailyUsageEntry[] = [{ date: D, totalMinutes: 30 }];
      mergeDailyHistory(h, D, 600);          // 10 分钟 < 已有 30
      expect(h[0].totalMinutes).assertEqual(30);
      mergeDailyHistory(h, D, 3600);         // 60 分钟 > 已有 30
      expect(h[0].totalMinutes).assertEqual(60);
    });

    it('mergeDailyHistory_ignores_sub_minute_totals', 0, () => {
      const h: DailyUsageEntry[] = [];
      mergeDailyHistory(h, D, 59);
      expect(h.length).assertEqual(0);
    });

    // ---- computeStreakDays ----
    it('computeStreakDays_counts_today_and_consecutive_days_under_limit', 0, () => {
      // 今日 60 分钟，限额 180；昨天/前天也达标 → 应为 3
      const h: DailyUsageEntry[] = [
        { date: D1, totalMinutes: 100 },
        { date: D2, totalMinutes: 120 }
      ];
      expect(computeStreakDays(h, 60, 180, D, 365)).assertEqual(3);
    });

    it('computeStreakDays_is_zero_when_today_exceeds_limit', 0, () => {
      const h: DailyUsageEntry[] = [{ date: D1, totalMinutes: 100 }];
      expect(computeStreakDays(h, 200, 180, D, 365)).assertEqual(0);
    });

    it('computeStreakDays_treats_exactly_limit_as_exceeded', 0, () => {
      // 与三档预警 / 首页「已超今日限额」同口径：等于限额也算已超。
      expect(computeStreakDays([], 180, 180, D, 365)).assertEqual(0);
      expect(computeStreakDays([{ date: D1, totalMinutes: 180 }], 60, 180, D, 365)).assertEqual(1);
      expect(computeStreakDays([{ date: D1, totalMinutes: 179 }], 60, 180, D, 365)).assertEqual(2);
    });

    it('computeStreakDays_stops_at_first_day_over_limit', 0, () => {
      const h: DailyUsageEntry[] = [
        { date: D1, totalMinutes: 100 },
        { date: D2, totalMinutes: 200 }   // 超限，打断
      ];
      expect(computeStreakDays(h, 60, 180, D, 365)).assertEqual(2);
    });

    it('computeStreakDays_stops_at_a_gap_in_history', 0, () => {
      // 昨天有、前天没有 → 连续中断（不能跨空洞）
      const h: DailyUsageEntry[] = [{ date: D1, totalMinutes: 100 }];
      expect(computeStreakDays(h, 60, 180, D, 365)).assertEqual(2);
    });

    it('computeStreakDays_is_zero_when_limit_is_not_positive', 0, () => {
      const h: DailyUsageEntry[] = [{ date: D1, totalMinutes: 100 }];
      expect(computeStreakDays(h, 60, 0, D, 365)).assertEqual(0);
    });

    it('computeStreakDays_respects_lookback_limit', 0, () => {
      const h: DailyUsageEntry[] = [
        { date: '2026-10-09', totalMinutes: 10 },
        { date: '2026-10-08', totalMinutes: 10 },
        { date: '2026-10-07', totalMinutes: 10 }
      ];
      expect(computeStreakDays(h, 10, 180, D, 2)).assertEqual(3);   // 今天 + 回溯 2 天
    });

    // ---- computeUsedDaysStreak ----
    it('computeUsedDaysStreak_counts_today_when_used', 0, () => {
      const h: DailyUsageEntry[] = [{ date: D1, totalMinutes: 5 }];
      expect(computeUsedDaysStreak(h, true, D, 365)).assertEqual(2);
    });

    it('computeUsedDaysStreak_does_not_break_when_today_unused', 0, () => {
      // 今日未使用，从昨天起算 —— 这是与 computeStreakDays 的关键口径差异
      const h: DailyUsageEntry[] = [{ date: D1, totalMinutes: 5 }];
      expect(computeUsedDaysStreak(h, false, D, 365)).assertEqual(1);
    });

    it('computeUsedDaysStreak_ignores_days_with_zero_usage', 0, () => {
      const h: DailyUsageEntry[] = [
        { date: D1, totalMinutes: 0 },     // 存在但没用过 → 打断
        { date: D2, totalMinutes: 5 }
      ];
      expect(computeUsedDaysStreak(h, true, D, 365)).assertEqual(1);
    });

    // ---- computeOverlapInWindow（睡前窗口，真实 bug 2026-10-01「跨午夜窗口翻倍」）----
    it('computeOverlapInWindow_same_day_window', 0, () => {
      // 窗口 21:00-22:00，会话 20:30-22:30 → 重叠 1 小时
      const start = new Date(2026, 9, 10, 20, 30, 0, 0).getTime();
      const end = new Date(2026, 9, 10, 22, 30, 0, 0).getTime();
      expect(computeOverlapInWindow(start, end, 21 * 60, 22 * 60)).assertEqual(3600);
    });

    it('computeOverlapInWindow_returns_zero_when_no_overlap', 0, () => {
      const start = new Date(2026, 9, 10, 10, 0, 0, 0).getTime();
      const end = new Date(2026, 9, 10, 11, 0, 0, 0).getTime();
      expect(computeOverlapInWindow(start, end, 21 * 60, 22 * 60)).assertEqual(0);
    });

    it('computeOverlapInWindow_cross_midnight_two_segments', 0, () => {
      // 窗口 22:00-02:00（跨午夜）：第一段 22:00-24:00，第二段 00:00-02:00
      // 会话 23:00-01:00 → 各 1 小时，共 2 小时
      const start = new Date(2026, 9, 10, 23, 0, 0, 0).getTime();
      const end = new Date(2026, 9, 11, 1, 0, 0, 0).getTime();
      expect(computeOverlapInWindow(start, end, 22 * 60, 2 * 60)).assertEqual(2 * 3600);
    });

    it('computeOverlapInWindow_cross_midnight_partial_each_segment', 0, () => {
      // 窗口 22:00-02:00；会话 21:00-01:00 → 第一段 22:00-24:00 = 2h，第二段 00:00-01:00 = 1h
      const start = new Date(2026, 9, 10, 21, 0, 0, 0).getTime();
      const end = new Date(2026, 9, 11, 1, 0, 0, 0).getTime();
      expect(computeOverlapInWindow(start, end, 22 * 60, 2 * 60)).assertEqual(3 * 3600);
    });

    it('computeOverlapInWindow_cross_midnight_counts_each_day_only_once', 0, () => {
      // 关键回归：一条 23:00-01:00 的会话在 22:00-02:00 窗口内只算 2 小时，
      // 而**不是**两段各算一次变成 4 小时（历史 bug：两轮循环命中同一批记录）
      const start = new Date(2026, 9, 10, 23, 0, 0, 0).getTime();
      const end = new Date(2026, 9, 11, 1, 0, 0, 0).getTime();
      const r: ScreenOnRecord = { date: D, startTime: start, endTime: end };
      // D 既是今天也是"昨天"传入时，只应扫一次
      const total = sumSecondsInWindow([r], D, D, 22 * 60, 2 * 60);
      expect(total).assertEqual(2 * 3600);
    });

    it('computeOverlapInWindow_anchored_window_counts_after_midnight', 0, () => {
      // 凌晨查询（如 00:10）时窗口是「昨晚 22:30 → 今天 00:30」。
      // 以窗口起始日（昨天）为锚 → 今天 00:10-00:20 计 10 分钟；
      // 以记录自身日期为锚（旧实现）→ 0，这就是"凌晨那半段永远漏计"的根因。
      const windowDay = new Date(2026, 9, 10, 0, 0, 0, 0).getTime();
      const start = new Date(2026, 9, 11, 0, 10, 0, 0).getTime();
      const end = new Date(2026, 9, 11, 0, 20, 0, 0).getTime();
      expect(computeOverlapInWindow(start, end, 22 * 60 + 30, 30, windowDay)).assertEqual(600);
      expect(computeOverlapInWindow(start, end, 22 * 60 + 30, 30)).assertEqual(0);
    });

    it('sumSecondsInWindow_uses_explicit_window_anchor', 0, () => {
      const rec: ScreenOnRecord = {
        date: '2026-10-11',
        startTime: new Date(2026, 9, 11, 0, 10, 0, 0).getTime(),
        endTime: new Date(2026, 9, 11, 0, 20, 0, 0).getTime()
      };
      const windowDay = new Date(2026, 9, 10, 0, 0, 0, 0).getTime();
      expect(sumSecondsInWindow([rec], '2026-10-11', '2026-10-10', 22 * 60 + 30, 30, windowDay))
        .assertEqual(600);
    });

    // ---- sumSecondsInWindow ----
    it('sumSecondsInWindow_same_day_window_scans_today_only', 0, () => {
      const todayRec: ScreenOnRecord = {
        date: D,
        startTime: new Date(2026, 9, 10, 21, 0, 0, 0).getTime(),
        endTime: new Date(2026, 9, 10, 21, 30, 0, 0).getTime()
      };
      const yesterdayRec: ScreenOnRecord = {
        date: D1,
        startTime: new Date(2026, 9, 10, 21, 0, 0, 0).getTime(),  // 同一时刻但归属昨天
        endTime: new Date(2026, 9, 10, 21, 30, 0, 0).getTime()
      };
      // 非跨午夜窗口 → 昨天不参与扫描
      expect(sumSecondsInWindow([todayRec, yesterdayRec], D, D1, 21 * 60, 22 * 60)).assertEqual(1800);
    });

    it('sumSecondsInWindow_cross_midnight_also_scans_yesterday', 0, () => {
      // 昨天的会话跨到了今天的凌晨窗口内
      const yesterdayRec: ScreenOnRecord = {
        date: D1,
        startTime: new Date(2026, 9, 9, 23, 0, 0, 0).getTime(),
        endTime: new Date(2026, 9, 10, 1, 0, 0, 0).getTime()
      };
      // 窗口 22:00-02:00 跨午夜 → 昨天的记录也参与
      expect(sumSecondsInWindow([yesterdayRec], D, D1, 22 * 60, 2 * 60)).assertEqual(2 * 3600);
    });

    it('sumSecondsInWindow_cross_midnight_does_not_double_todays_record', 0, () => {
      // 今天的记录只扫一次，即便 yesterday 传了不同的日期
      const todayRec: ScreenOnRecord = {
        date: D,
        startTime: new Date(2026, 9, 10, 23, 0, 0, 0).getTime(),
        endTime: new Date(2026, 9, 11, 1, 0, 0, 0).getTime()
      };
      expect(sumSecondsInWindow([todayRec], D, D1, 22 * 60, 2 * 60)).assertEqual(2 * 3600);
    });
  });

  // ============================================================
  // ReminderScheduleMath —— 常驻提醒调度内核
  // 每条用例对应一个真实出过 bug 的场景，不是凑数。
  // ============================================================
  describe('ReminderScheduleMath', () => {
    const T0 = new Date(2026, 9, 10, 9, 0, 0, 0).getTime();  // 2026-10-10 09:00 本地时间戳
    const MIN = 60000;
    const TODAY = '2026-10-10';
    const YESTERDAY = '2026-10-09';

    // ---- deriveIntervalInitState：锚点保留 / fireNow 滥用 ----

    it('deriveIntervalInitState_first_registration_counts_a_full_interval_from_now', 0, () => {
      // 首次注册：无 fireNow、无历史锚点 → 从注册时刻起计
      const r = deriveIntervalInitState(T0, true, false, 0, 0);
      expect(r.lastFireAt).assertEqual(T0);
      expect(r.alertUntil).assertEqual(0);
    });

    it('deriveIntervalInitState_fireNow_inside_active_window_fires_immediately', 0, () => {
      // 用户"关闭→开启"且正处于活跃时段 → 立即触发一次并进入展示期
      const r = deriveIntervalInitState(T0, true, true, 0, 0);
      expect(r.lastFireAt).assertEqual(T0);
      expect(r.alertUntil).assertEqual(T0 + ALERT_SHOW_MS);
    });

    it('deriveIntervalInitState_fireNow_outside_active_window_does_not_fire', 0, () => {
      // fireNow 只在活跃时段内生效：窗口外开启不应弹 ⏰，应等窗口开启
      const r = deriveIntervalInitState(T0, false, true, 0, 0);
      expect(r.lastFireAt).assertEqual(T0);
      expect(r.alertUntil).assertEqual(0);
    });

    it('deriveIntervalInitState_keeps_existing_anchor_when_config_changes', 0, () => {
      // 改间隔/时段/标题不得打乱既有触发节奏（2026-08-03 第二轮修复的真实语义）
      const anchor = T0 - 7 * MIN;
      const alert = anchor + 5000;
      const r = deriveIntervalInitState(T0, true, false, anchor, alert);
      expect(r.lastFireAt).assertEqual(anchor);
      expect(r.alertUntil).assertEqual(alert);
    });

    it('deriveIntervalInitState_fireNow_wins_over_existing_anchor', 0, () => {
      // 分支顺序：fireNow 在锚点保留之前 —— 重新开启必须立刻响一次
      const anchor = T0 - 7 * MIN;
      const r = deriveIntervalInitState(T0, true, true, anchor, 0);
      expect(r.lastFireAt).assertEqual(T0);
      expect(r.alertUntil).assertEqual(T0 + ALERT_SHOW_MS);
    });

    // ---- deriveDailyInitDateKey：不补发 + 同日不重复 ----

    it('deriveDailyInitDateKey_marks_today_as_fired_when_target_already_passed', 0, () => {
      // 10:00 注册、目标 09:00 → 视为今天已触发过，避免开机时补发
      const now = new Date(2026, 9, 10, 10, 0, 0, 0).getTime();
      const target = new Date(2026, 9, 10, 9, 0, 0, 0).getTime();
      expect(deriveDailyInitDateKey(now, target, TODAY, YESTERDAY, '')).assertEqual(TODAY);
    });

    it('deriveDailyInitDateKey_marks_yesterday_when_target_not_reached', 0, () => {
      // 08:00 注册、目标 09:00 → 待触发，记昨天使本轮自然落入待触发分支
      const now = new Date(2026, 9, 10, 8, 0, 0, 0).getTime();
      const target = new Date(2026, 9, 10, 9, 0, 0, 0).getTime();
      expect(deriveDailyInitDateKey(now, target, TODAY, YESTERDAY, '')).assertEqual(YESTERDAY);
    });

    it('deriveDailyInitDateKey_keeps_existing_marker_to_avoid_same_day_refire', 0, () => {
      // 设置改动后重新注册，今天已触发过的标记必须保留（否则当天响第二次）
      const now = new Date(2026, 9, 10, 10, 0, 0, 0).getTime();
      const target = new Date(2026, 9, 10, 9, 0, 0, 0).getTime();
      expect(deriveDailyInitDateKey(now, target, TODAY, YESTERDAY, TODAY)).assertEqual(TODAY);
    });

    it('deriveDailyInitDateKey_existing_marker_wins_even_when_target_moved_to_later', 0, () => {
      // 把睡前时间从 09:00 改到 20:00，此刻 10:00 早已"过点"：
      // 若不沿用旧标记，会误判成今天已触发而当天再响一次
      const now = new Date(2026, 9, 10, 10, 0, 0, 0).getTime();
      const target = new Date(2026, 9, 10, 20, 0, 0, 0).getTime();
      expect(deriveDailyInitDateKey(now, target, TODAY, YESTERDAY, TODAY)).assertEqual(TODAY);
    });

    // ---- intervalTickStep：锚点推进 / 展示期 / 非正间隔兜底 ----

    it('intervalTickStep_does_not_fire_before_the_interval_elapses', 0, () => {
      const r = intervalTickStep(T0, 0, 45, true, T0 + 20 * MIN);
      expect(r.alerting).assertEqual(false);
      expect(r.nextFireMs).assertEqual(T0 + 45 * MIN);
    });

    it('intervalTickStep_fires_when_the_interval_has_elapsed', 0, () => {
      const r = intervalTickStep(T0, 0, 45, true, T0 + 45 * MIN);
      expect(r.alerting).assertEqual(true);
      expect(r.lastFireAt).assertEqual(T0 + 45 * MIN);
      expect(r.alertUntil).assertEqual(T0 + 45 * MIN + ALERT_SHOW_MS);
    });

    it('intervalTickStep_stays_in_alert_during_the_show_window', 0, () => {
      // 触发后 30 秒展示期内，每轮都应保持 ⏰ 文案且**不推进锚点**
      const alertUntil = T0 + ALERT_SHOW_MS;
      const r = intervalTickStep(T0, alertUntil, 45, true, T0 + 10 * 1000);
      expect(r.alerting).assertEqual(true);
      expect(r.lastFireAt).assertEqual(T0);
    });

    it('intervalTickStep_clears_alert_when_leaving_the_active_window', 0, () => {
      // 离开活跃时段必须清掉展示期，否则下次回到时段内第一轮会闪现过期 ⏰
      const r = intervalTickStep(T0, T0 + ALERT_SHOW_MS, 45, false, T0 + 5 * 1000);
      expect(r.alertUntil).assertEqual(0);
      expect(r.alerting).assertEqual(false);
    });

    it('intervalTickStep_zero_interval_falls_back_to_one_minute', 0, () => {
      // intervalMinutes <= 0 的兜底（2026-10-01 轮 #9 的真实修复）：
      // 不兜底则触发分支永不成立、文案每轮都变 → 每 10s 空转重发
      const r = intervalTickStep(T0, 0, 0, true, T0 + 30 * 1000);
      expect(r.alerting).assertEqual(false);
      expect(r.nextFireMs).assertEqual(T0 + MIN_EFFECTIVE_INTERVAL_MS);
    });

    it('intervalTickStep_zero_interval_eventually_fires_within_a_minute', 0, () => {
      // 兜底的目标：触发分支"终将成立"
      const r = intervalTickStep(T0, 0, 0, true, T0 + MIN_EFFECTIVE_INTERVAL_MS);
      expect(r.alerting).assertEqual(true);
    });

    it('intervalTickStep_negative_interval_also_falls_back', 0, () => {
      const r = intervalTickStep(T0, 0, -30, true, T0 + 10 * 1000);
      expect(r.nextFireMs).assertEqual(T0 + MIN_EFFECTIVE_INTERVAL_MS);
    });

    it('intervalTickStep_exact_interval_boundary_fires', 0, () => {
      // 边界：now 恰好等于 lastFireAt + interval 应触发（>= 而非 >）
      const r = intervalTickStep(T0, 0, 45, true, T0 + 45 * MIN);
      expect(r.alerting).assertEqual(true);
    });

    // ---- dailyTickStep：同日去重 / 已过不补发 ----

    it('dailyTickStep_fires_once_when_target_is_reached', 0, () => {
      const target = new Date(2026, 9, 10, 22, 0, 0, 0).getTime();
      const r = dailyTickStep(YESTERDAY, 0, target, TODAY, target);
      expect(r.alerting).assertEqual(true);
      expect(r.lastFireDateKey).assertEqual(TODAY);
    });

    it('dailyTickStep_does_not_refire_on_the_same_day', 0, () => {
      // 同日去重：今天已触发过，之后每轮都只是"下次提醒"
      const target = new Date(2026, 9, 10, 22, 0, 0, 0).getTime();
      const now = target + 60 * MIN;
      const r = dailyTickStep(TODAY, 0, target, TODAY, now);
      expect(r.alerting).assertEqual(false);
      expect(r.nextFireMs).assertEqual(target + 86400000);
    });

    it('dailyTickStep_does_not_backfill_when_registered_after_target', 0, () => {
      // 23:00 才开机而目标是 22:00：不补发，直接排到次日。
      // 注意"不补发"是由**注册期**的 deriveDailyInitDateKey 把标记置为 TODAY 实现的，
      // 不是 tick 期保证的——若这里传 YESTERDAY 就构造了一个真实代码不可能产生的状态。
      const target = new Date(2026, 9, 10, 22, 0, 0, 0).getTime();
      const now = target + 60 * MIN;
      const r = dailyTickStep(TODAY, 0, target, TODAY, now);
      expect(r.alerting).assertEqual(false);
      expect(r.nextFireMs).assertEqual(target + 86400000);
    });

    it('dailyTickStep_counts_down_to_todays_target_before_it_arrives', 0, () => {
      // 未到点：显示今日目标时刻，而非次日
      const target = new Date(2026, 9, 10, 22, 0, 0, 0).getTime();
      const now = new Date(2026, 9, 10, 20, 0, 0, 0).getTime();
      const r = dailyTickStep(YESTERDAY, 0, target, TODAY, now);
      expect(r.alerting).assertEqual(false);
      expect(r.nextFireMs).assertEqual(target);
    });

    it('dailyTickStep_stays_in_alert_during_the_show_window', 0, () => {
      const target = new Date(2026, 9, 10, 22, 0, 0, 0).getTime();
      const alertUntil = target + ALERT_SHOW_MS;
      const r = dailyTickStep(YESTERDAY, alertUntil, target, TODAY, target + 5 * 1000);
      expect(r.alerting).assertEqual(true);
      expect(r.lastFireDateKey).assertEqual(YESTERDAY);
    });

    // ---- oneShotTickStep：倒计时 → 展示 → 移除 ----

    it('oneShotTickStep_counts_down_before_the_deadline', 0, () => {
      const fireAt = T0 + 60 * MIN;
      const r = oneShotTickStep(fireAt, 0, T0);
      expect(r.phase).assertEqual(OneShotPhase.COUNTING);
      expect(r.remainMs).assertEqual(60 * MIN);
    });

    it('oneShotTickStep_alerts_after_the_deadline', 0, () => {
      const fireAt = T0 + 60 * MIN;
      const r = oneShotTickStep(fireAt, 0, fireAt + 1000);
      expect(r.phase).assertEqual(OneShotPhase.ALERTING);
      expect(r.alertUntil).assertEqual(fireAt + 1000 + ONESHOT_ALERT_SHOW_MS);
    });

    it('oneShotTickStep_finishes_after_the_show_window', 0, () => {
      // 展示期从**首次观察到已到点的那一轮**起算（tick 有 10s 步长，不是精确到 fireAt），
      // 故必须先跑一轮拿到 alertUntil，再用该截止时刻去判 FINISHED
      const fireAt = T0 + 60 * MIN;
      const first = oneShotTickStep(fireAt, 0, fireAt + 1000);
      const r = oneShotTickStep(fireAt, first.alertUntil, first.alertUntil);
      expect(r.phase).assertEqual(OneShotPhase.FINISHED);
    });

    it('oneShotTickStep_does_not_extend_the_show_window_on_later_ticks', 0, () => {
      // 关键回归：若每轮都重置展示期，FINISHED 永远到不了，一次性提醒会永远留在通知栏
      const fireAt = T0 + 60 * MIN;
      const first = oneShotTickStep(fireAt, 0, fireAt);
      const later = oneShotTickStep(fireAt, first.alertUntil, fireAt + 10 * 1000);
      expect(later.alertUntil).assertEqual(first.alertUntil);
      expect(later.phase).assertEqual(OneShotPhase.ALERTING);
    });

    it('oneShotTickStep_exact_deadline_is_already_fired', 0, () => {
      // 边界：remain === 0 属于已到点（remain > 0 才倒计时）
      const fireAt = T0 + 60 * MIN;
      const r = oneShotTickStep(fireAt, 0, fireAt);
      expect(r.phase).assertEqual(OneShotPhase.ALERTING);
    });

    // ---- shouldPublish：文案去重 ----

    it('shouldPublish_skips_when_text_is_unchanged', 0, () => {
      expect(shouldPublish('下次提醒：今天 22:00', '下次提醒：今天 22:00')).assertEqual(false);
    });

    it('shouldPublish_proceeds_when_text_changes', 0, () => {
      expect(shouldPublish('⏰ 久坐提醒', '下次提醒：今天 22:00')).assertEqual(true);
    });

    it('shouldPublish_proceeds_on_first_publish_from_empty_text', 0, () => {
      expect(shouldPublish('', '即将提醒：还有 30 分钟')).assertEqual(true);
    });
  });

  // ============================================================
  // 限额预警三档 —— 收敛后的单一判定来源 + 标记/通知两条撤除链
  // ============================================================
  describe('UsageStatsMath 限额预警档位', () => {
    // 限额 180 分钟 = 10800 秒；阈值 50%=5400s(90min) 80%=8640s(144min)
    const LIM180 = 180;

    // ---- computeLimitTierIndex：阈值判定 ----

    it('limit_tier_none_below_half', 0, () => {
      expect(computeLimitTierIndex(89 * 60, LIM180)).assertEqual(LIMIT_TIER_NONE);
    });

    it('limit_tier_50_at_exact_half_boundary', 0, () => {
      // 边界用 >= ：恰好 90 分钟即应进入 50% 档
      expect(computeLimitTierIndex(90 * 60, LIM180)).assertEqual(LIMIT_TIER_50);
    });

    it('limit_tier_80_at_exact_80_boundary', 0, () => {
      expect(computeLimitTierIndex(144 * 60, LIM180)).assertEqual(LIMIT_TIER_80);
    });

    it('limit_tier_100_at_exact_limit', 0, () => {
      expect(computeLimitTierIndex(180 * 60, LIM180)).assertEqual(LIMIT_TIER_100);
    });

    it('limit_tier_none_when_limit_is_zero', 0, () => {
      // 限额 <= 0 视为无限额：任何用量都不应触发
      expect(computeLimitTierIndex(99999 * 60, 0)).assertEqual(LIMIT_TIER_NONE);
    });

    it('limit_tier_is_monotonic_in_usage', 0, () => {
      // 单调性：三档互斥且只取最高档，不允许出现"用量更大反而档位更低"
      let prev = LIMIT_TIER_NONE;
      for (let m = 0; m <= 400; m += 5) {
        const t = computeLimitTierIndex(m * 60, LIM180);
        expect(t >= prev).assertEqual(true);
        prev = t;
      }
    });

    // ---- limitTiersToClearFlag / limitTiersToCancel ----

    it('sync_clears_flags_of_all_non_current_tiers', 0, () => {
      // 不变式：flag 为 true ⟺ 该档横幅在通知栏里。
      // 当前档以外的全部要清 —— 含当前档以下（那些横幅早已被更高档撤除，
      // 留着标记会挡住"抬高限额后重新落回该档"的重发）。
      const clear = limitTiersToClearFlag(LIMIT_TIER_50);
      expect(clear.length).assertEqual(2);
      expect(clear.indexOf(LIMIT_TIER_50)).assertEqual(-1);
      expect(clear.indexOf(LIMIT_TIER_80) >= 0).assertEqual(true);
      expect(clear.indexOf(LIMIT_TIER_100) >= 0).assertEqual(true);
    });

    it('sync_cancels_only_tiers_above_current', 0, () => {
      // 通知只撤"当前档以上"：当前档以下的横幅早被更高档撤除，重复撤除是无谓的 IPC
      expect(limitTiersToCancel(LIMIT_TIER_50).join(',')).assertEqual('1,2');
      expect(limitTiersToCancel(LIMIT_TIER_80).join(',')).assertEqual('2');
      expect(limitTiersToCancel(LIMIT_TIER_100).join(',')).assertEqual('');
    });

    it('sync_with_no_active_tier_cancels_and_clears_everything', 0, () => {
      expect(limitTiersToClearFlag(LIMIT_TIER_NONE).length).assertEqual(3);
      expect(limitTiersToCancel(LIMIT_TIER_NONE).join(',')).assertEqual('0,1,2');
    });

    it('supersede_targets_below_not_above', 0, () => {
      // 两个方向别混用：被取代的是"更低档"，限额变更后失效的是"更高档"
      expect(limitTiersSupersededBy(LIMIT_TIER_50).join(',')).assertEqual('');
      expect(limitTiersSupersededBy(LIMIT_TIER_80).join(',')).assertEqual('0');
      expect(limitTiersSupersededBy(LIMIT_TIER_100).join(',')).assertEqual('0,1');
    });

    it('supersede_then_relax_allow_the_lower_tier_to_realert', 0, () => {
      // ★ 本轮修复的真实缺陷回归：
      // 1) 用量 90min → 50% 档发出，flag50 = true
      // 2) 用量 145min → 80% 档发出，撤除 50% 横幅（且必须清 flag50）
      // 3) 抬高限额到 240min，用量落回 50% 档
      // 4) 期望：50% 档**能再次发出**
      const fired: boolean[] = [false, false, false];
      const send = (tier: number): void => {
        fired[tier] = true;
      };
      const clearFlag = (tier: number): void => {
        fired[tier] = false;
      };
      const onSupersede = (firedTier: number): void => {
        send(firedTier);
        for (const t of limitTiersSupersededBy(firedTier)) {
          clearFlag(t);          // 撤除横幅即清标记（本轮修复点）
        }
      };
      const onLimitChanged = (currentTier: number): void => {
        for (const t of limitTiersToClearFlag(currentTier)) {
          clearFlag(t);
        }
      };

      send(computeLimitTierIndex(90 * 60, LIM180));            // 步骤 1
      expect(computeLimitTierIndex(90 * 60, LIM180)).assertEqual(LIMIT_TIER_50);
      expect(fired[LIMIT_TIER_50]).assertEqual(true);

      // 步骤 2：80% 档触发并取代 50% 档
      const t80 = computeLimitTierIndex(145 * 60, LIM180);
      expect(t80).assertEqual(LIMIT_TIER_80);
      onSupersede(t80);
      expect(fired[LIMIT_TIER_50]).assertEqual(false);
      expect(fired[LIMIT_TIER_80]).assertEqual(true);

      // 步骤 3：抬高限额 180 → 240，用量 145min 落回 50% 档
      const after = computeLimitTierIndex(145 * 60, 240);
      expect(after).assertEqual(LIMIT_TIER_50);
      onLimitChanged(after);      // syncTierAlertNotifications 清"当前档以外"
      expect(fired[LIMIT_TIER_50]).assertEqual(false);

      // 步骤 4：checkUsageAlerts 再次求值 → 必须能重发（这是修复前会失败的一步）
      send(computeLimitTierIndex(145 * 60, 240));
      expect(fired[LIMIT_TIER_50]).assertEqual(true);
    });

    it('lowered_tier_keeps_its_own_flag_so_it_does_not_realert', 0, () => {
      // 反向对照：当前档自己的标记**不能**被 sync 清掉，
      // 否则每次改限额都会把当前横幅重发一遍（改一次响一次 = 新的骚扰）。
      const fired: boolean[] = [true, false, false];   // 50% 档已发出
      const current = LIMIT_TIER_50;
      const cleared = limitTiersToClearFlag(current);
      for (const t of cleared) {
        fired[t] = false;
      }
      expect(fired[LIMIT_TIER_50]).assertEqual(true);
      expect(cleared.indexOf(LIMIT_TIER_50)).assertEqual(-1);
    });
  });

  // ============================================================
  // ReminderConfigMath —— 提醒配置钳位（2026-10-01 轮 #9 的真实修复，此前无单测）
  // ============================================================
  describe('ReminderConfigMath', () => {
    const ALL7 = [0, 1, 2, 3, 4, 5, 6];

    // ---- clampInt ----

    it('clamp_keeps_value_inside_range', 0, () => {
      expect(clampInt(45, 1, 1440, 1)).assertEqual(45);
    });

    it('clamp_pulls_up_below_min', 0, () => {
      // 间隔 0 会让调度器触发分支永不成立 → 空转重发，必须收拢到下界
      expect(clampInt(0, MIN_INTERVAL_MINUTES, MAX_INTERVAL_MINUTES, 1)).assertEqual(1);
      expect(clampInt(-30, MIN_INTERVAL_MINUTES, MAX_INTERVAL_MINUTES, 1)).assertEqual(1);
    });

    it('clamp_pulls_down_above_max', 0, () => {
      expect(clampInt(99999, MIN_INTERVAL_MINUTES, MAX_INTERVAL_MINUTES, 1)).assertEqual(MAX_INTERVAL_MINUTES);
      expect(clampInt(99, 0, MAX_HOUR, DEFAULT_START_HOUR)).assertEqual(MAX_HOUR);
      expect(clampInt(75, 0, MAX_MINUTE, 0)).assertEqual(MAX_MINUTE);
    });

    it('clamp_non_finite_falls_back_not_to_lower_bound', 0, () => {
      // ★ 关键语义：回退值由调用方给，**不是区间下界**。
      // 若 startHour 非法时回退 0 而非 9，一个写坏的备份会让提醒时段变成 00:00 起。
      expect(clampInt(NaN, 0, MAX_HOUR, DEFAULT_START_HOUR)).assertEqual(DEFAULT_START_HOUR);
      expect(clampInt(Infinity, 0, MAX_HOUR, DEFAULT_START_HOUR)).assertEqual(DEFAULT_START_HOUR);
      expect(clampInt(-Infinity, 0, MAX_HOUR, DEFAULT_END_HOUR)).assertEqual(DEFAULT_END_HOUR);
    });

    it('clamp_truncates_decimals', 0, () => {
      expect(clampInt(45.9, 1, 1440, 1)).assertEqual(45);
      expect(clampInt(9.5, 0, MAX_HOUR, 9)).assertEqual(9);
    });

    // ---- normalizeReminderFields ----

    it('normalize_keeps_valid_config_untouched', 0, () => {
      const f = normalizeReminderFields(45, 9, 30, 21, 15, [1, 3, 5], 45);
      expect(f.intervalMinutes).assertEqual(45);
      expect(f.startHour).assertEqual(9);
      expect(f.startMinute).assertEqual(30);
      expect(f.endHour).assertEqual(21);
      expect(f.endMinute).assertEqual(15);
      expect(f.weekdays.join(',')).assertEqual('1,3,5');
    });

    it('normalize_empty_weekdays_falls_back_to_whole_week', 0, () => {
      const f = normalizeReminderFields(45, 9, 0, 21, 0, [], 45);
      expect(f.weekdays.join(',')).assertEqual(ALL7.join(','));
    });

    it('normalize_invalid_weekdays_are_filtered_and_deduped', 0, () => {
      // 越界/非整数/非有限值/重复项都不得进入调度器：
      // 原实现只判 length>0，[7] 这种值会让提醒"永不触发"且没有任何报错。
      const f = normalizeReminderFields(45, 9, 0, 21, 0, [7, -1, 3, 3, NaN, Infinity, 1.5], 45);
      expect(f.weekdays.join(',')).assertEqual('3');
      const g = normalizeReminderFields(45, 9, 0, 21, 0, [7, -1], 45);
      expect(g.weekdays.join(',')).assertEqual(ALL7.join(','));
    });

    it('normalize_returns_a_copy_of_weekdays_not_the_same_array', 0, () => {
      // 外部持有者若原地改写返回值，不得污染调用方的数组
      const src = [1, 2, 3];
      const f = normalizeReminderFields(45, 9, 0, 21, 0, src, 45);
      f.weekdays[0] = 9;
      expect(src[0]).assertEqual(1);
    });

    it('normalize_start_after_end_is_left_alone_as_cross_midnight', 0, () => {
      // start > end 是**合法**的跨午夜时段（如 22:00–07:00），不得被"纠正"
      const f = normalizeReminderFields(45, 22, 0, 7, 0, ALL7, 45);
      expect(f.startHour).assertEqual(22);
      expect(f.endHour).assertEqual(7);
    });

    it('normalize_uses_caller_fallback_only_for_non_finite_interval', 0, () => {
      // fallback **只对非有限数生效**：0 是有限数，按区间下界收拢成 1，
      // 不是回退到调用方给的默认值（importData 另有 hasValidInterval 判断负责那件事）。
      expect(normalizeReminderFields(0, 9, 0, 21, 0, ALL7, 45).intervalMinutes).assertEqual(MIN_INTERVAL_MINUTES);
      expect(normalizeReminderFields(NaN, 9, 0, 21, 0, ALL7, 45).intervalMinutes).assertEqual(45);
      expect(normalizeReminderFields(NaN, 9, 0, 21, 0, ALL7, 20).intervalMinutes).assertEqual(20);
      expect(normalizeReminderFields(NaN, 9, 0, 21, 0, ALL7, 60).intervalMinutes).assertEqual(60);
    });

    // ---- resolveCustomNotificationId ----

    it('custom_id_is_kept_when_strictly_above_max_seen', 0, () => {
      const r = resolveCustomNotificationId(2005, 2000, 2003);
      expect(r[0]).assertEqual(2005);
      expect(r[1]).assertEqual(2005);
    });

    it('custom_duplicate_id_gets_a_new_one', 0, () => {
      // ★ 重复 id 会让两条提醒共用一个通知 id（横幅只显示最后一条、
      // repost 回调互相覆盖、删除只能撤掉一条）——本条是那道防线
      const r = resolveCustomNotificationId(2003, 2000, 2003);
      expect(r[0]).assertEqual(2004);
    });

    it('custom_id_below_base_is_reallocated', 0, () => {
      const r = resolveCustomNotificationId(1001, 2000, 1999);
      expect(r[0]).assertEqual(2000);
    });

    it('custom_non_finite_id_is_reallocated', 0, () => {
      // 备份里的 id 若是 null/字符串，JSON.parse 后可能是 NaN —— 必须重新分配
      const r = resolveCustomNotificationId(NaN, 2000, 1999);
      expect(r[0]).assertEqual(2000);
    });

    it('custom_ids_are_unique_when_allocated_in_sequence', 0, () => {
      // 模拟持久化数据里 [2000, 2000, 2000] 三个重复 id
      let maxSeen = 1999;
      const ids: number[] = [];
      for (const candidate of [2000, 2000, 2000]) {
        const r = resolveCustomNotificationId(candidate, 2000, maxSeen);
        ids.push(r[0]);
        maxSeen = r[1];
      }
      expect(ids.join(',')).assertEqual('2000,2001,2002');
    });
  });

  // ============================================================
  // ScreenStateMath —— 解锁去重（决定"今日解锁次数"这个用户可见数字）
  // ============================================================
  describe('ScreenStateMath', () => {
    it('unlock_first_ever_is_counted', 0, () => {
      expect(shouldCountUnlock(10000, 0, UNLOCK_DEDUPE_MS)).assertEqual(true);
    });

    it('unlock_within_dedupe_window_is_dropped', 0, () => {
      // 同一次解锁会由 SCREEN_UNLOCKED 事件与轮询跳变各报一次
      expect(shouldCountUnlock(10000, 9900, UNLOCK_DEDUPE_MS)).assertEqual(false);
      expect(shouldCountUnlock(10000, 7001, UNLOCK_DEDUPE_MS)).assertEqual(false);
    });

    it('unlock_at_exact_window_boundary_is_counted', 0, () => {
      // 边界用 >= ：恰好等于窗口长度应算新的一次
      expect(shouldCountUnlock(13000, 10000, UNLOCK_DEDUPE_MS)).assertEqual(true);
    });

    it('unlock_beyond_window_is_counted', 0, () => {
      expect(shouldCountUnlock(20000, 10000, UNLOCK_DEDUPE_MS)).assertEqual(true);
    });
  });

  // ============================================================
  // FocusStatsMath —— 专注积分与最长连击
  // ============================================================
  describe('FocusStatsMath', () => {
    it('points_equal_duration_for_the_first_session', 0, () => {
      // 首场 45 分钟 = 45 + min(1×2, 50) = 47（按"完成本场后的连击数"发放）
      expect(computeFocusPoints(45, 1, STREAK_BONUS_CAP)).assertEqual(47);
    });

    it('points_grow_with_streak_then_cap', 0, () => {
      expect(computeFocusPoints(25, 2, STREAK_BONUS_CAP)).assertEqual(29);
      expect(computeFocusPoints(25, 10, STREAK_BONUS_CAP)).assertEqual(45);
      // 第 25 场起加成封顶 50
      expect(computeFocusPoints(25, 25, STREAK_BONUS_CAP)).assertEqual(75);
      expect(computeFocusPoints(25, 100, STREAK_BONUS_CAP)).assertEqual(75);
    });

    it('longest_streak_counts_consecutive_completed_sessions', 0, () => {
      const h = [sess(1, true), sess(2, true), sess(3, true)];
      expect(computeLongestStreak(h)).assertEqual(3);
    });

    it('longest_streak_is_broken_by_an_interrupted_session', 0, () => {
      const h = [sess(1, true), sess(2, true), sess(3, false), sess(4, true)];
      expect(computeLongestStreak(h)).assertEqual(2);
    });

    it('longest_streak_handles_unsorted_history', 0, () => {
      // 历史数组不保证按时间有序（备份恢复后尤其如此）
      const h = [sess(30, true), sess(10, true), sess(20, true)];
      expect(computeLongestStreak(h)).assertEqual(3);
    });

    it('longest_streak_does_not_mutate_the_input_array', 0, () => {
      // 调用方传的是实例内的历史数组，排序必须在副本上做
      const h = [sess(30, true), sess(10, true)];
      computeLongestStreak(h);
      expect(h[0].startTime).assertEqual(30);
    });

    it('longest_streak_is_zero_for_empty_history', 0, () => {
      expect(computeLongestStreak([])).assertEqual(0);
    });

    it('longest_streak_is_zero_when_all_interrupted', 0, () => {
      expect(computeLongestStreak([sess(1, false), sess(2, false)])).assertEqual(0);
    });
  });

  // ============================================================
  // SleepScoreMath —— 睡前习惯评分与改善建议
  // （睡前页评分环 + 建议列表的用户可见文案；抽离前这段逻辑零单测覆盖）
  // ============================================================
  describe('SleepScoreMath', () => {
    // ---------- 评分 ----------
    it('score_is_full_when_everything_is_in_the_ideal_band', 0, () => {
      // 睡眠 420–540 分钟、睡前使用 ≤30 分钟：不扣任何一分
      expect(computeSleepScore(480, 30)).assertEqual(SCORE_MAX);
      expect(computeSleepScore(420, 0)).assertEqual(SCORE_MAX);
      expect(computeSleepScore(540, 30)).assertEqual(SCORE_MAX);
    });

    it('short_sleep_under_six_hours_costs_twenty', 0, () => {
      expect(computeSleepScore(359, 0)).assertEqual(80);
    });

    it('short_sleep_between_six_and_seven_hours_costs_ten', 0, () => {
      expect(computeSleepScore(360, 0)).assertEqual(90);
      expect(computeSleepScore(419, 0)).assertEqual(90);
    });

    it('boundary_at_seven_hours_is_not_penalised', 0, () => {
      // 420 是 else-if 的上界：<420 才扣，恰好 420 不扣
      expect(computeSleepScore(420, 0)).assertEqual(SCORE_MAX);
    });

    it('over_sleep_above_nine_hours_costs_five', 0, () => {
      expect(computeSleepScore(541, 0)).assertEqual(95);
    });

    it('boundary_at_nine_hours_is_not_penalised', 0, () => {
      // 540 不满足 >540，不扣分
      expect(computeSleepScore(540, 0)).assertEqual(SCORE_MAX);
    });

    it('pre_sleep_over_sixty_minutes_costs_twenty', 0, () => {
      expect(computeSleepScore(480, 61)).assertEqual(80);
    });

    it('pre_sleep_between_thirty_and_sixty_costs_ten', 0, () => {
      expect(computeSleepScore(480, 31)).assertEqual(90);
      expect(computeSleepScore(480, 60)).assertEqual(90);
    });

    it('boundary_at_thirty_minutes_is_not_penalised', 0, () => {
      // 30 不满足 >30，不扣分
      expect(computeSleepScore(480, 30)).assertEqual(SCORE_MAX);
    });

    it('boundary_at_sixty_minutes_is_not_penalised', 0, () => {
      // 60 不满足 >60，只按 >30 扣 10
      expect(computeSleepScore(480, 60)).assertEqual(90);
    });

    it('both_penalties_stack_additively', 0, () => {
      // 短睡 -20 + 睡前超标 -20 = 60
      expect(computeSleepScore(300, 90)).assertEqual(60);
    });

    it('reachable_score_range_is_60_to_100_and_the_clamp_never_binds', 0, () => {
      // 最大扣分 = 短睡 20 + 睡前超标 20 = 40，故任何入参的得分都不可能低于 60；
      // 上下界钳位在本口径下是**防御性代码、永远不会真正生效**。
      // 若将来新增扣分项使最低分逼近 0，钳位才会开始起作用——本用例即该变化的哨兵。
      expect(computeSleepScore(0, 100000)).assertEqual(60);
      expect(computeSleepScore(-999, -999)).assertEqual(80);
      expect(computeSleepScore(-999, -999) >= SCORE_MIN).assertEqual(true);
    });

    it('score_never_exceeds_the_maximum', 0, () => {
      // 超长睡眠仍要扣 5 分，故极端入参得到 95 而非满分
      expect(computeSleepScore(100000, -100000)).assertEqual(95);
      expect(computeSleepScore(480, 0)).assertEqual(SCORE_MAX);
    });

    // ---------- 建议 ----------
    it('advice_list_is_never_empty', 0, () => {
      // 无任何异常项时给兜底正面评价，睡前页直接 ForEach 渲染，恒非空才不会渲染出空白
      const advices = generateSleepAdvices(480, 30, 120, false, 60);
      expect(advices.length).assertEqual(1);
      expect(advices[0]).assertEqual('睡眠状态良好，请保持规律作息');
    });

    it('advice_falls_back_to_positive_when_deep_sleep_is_unknown', 0, () => {
      // undefined 深睡视为 0，不触发"深睡偏少"建议
      const advices = generateSleepAdvices(480, 30, undefined, false, 60);
      expect(advices.length).assertEqual(1);
    });

    it('advice_flags_pre_sleep_overuse_with_default_rest_window', 0, () => {
      const advices = generateSleepAdvices(480, 45, 120, false, 90);
      expect(advices.length).assertEqual(1);
      expect(advices[0]).assertEqual('睡前使用手机 45 分钟，建议睡前60分钟放下手机');
    });

    it('advice_uses_configured_window_when_pre_sleep_restriction_is_on', 0, () => {
      const advices = generateSleepAdvices(480, 45, 120, true, 90);
      expect(advices[0]).assertEqual('睡前使用手机 45 分钟，建议睡前90分钟放下手机');
    });

    it('advice_flags_short_sleep', 0, () => {
      const advices = generateSleepAdvices(300, 0, 120, false, 60);
      expect(advices.length).assertEqual(1);
      expect(advices[0]).assertEqual('昨晚睡眠约 5小时，建议今晚争取 7-8小时');
    });

    it('advice_flags_low_deep_sleep_only_when_below_one_hour', 0, () => {
      expect(generateSleepAdvices(480, 0, 30, false, 60).length).assertEqual(1);
      // 恰好 60 分钟不触发（条件是 < 60）
      expect(generateSleepAdvices(480, 0, 60, false, 60).length).assertEqual(1);
      expect(generateSleepAdvices(480, 0, 60, false, 60)[0])
        .assertEqual('睡眠状态良好，请保持规律作息');
      expect(generateSleepAdvices(480, 0, 45, false, 60)[0])
        .assertEqual('深睡仅 45 分钟，睡前避免饮酒或过度兴奋');
    });

    it('advice_can_stack_all_three_items', 0, () => {
      const advices = generateSleepAdvices(300, 45, 30, false, 60);
      expect(advices.length).assertEqual(3);
      expect(advices[0]).assertEqual('睡前使用手机 45 分钟，建议睡前60分钟放下手机');
      expect(advices[1]).assertEqual('昨晚睡眠约 5小时，建议今晚争取 7-8小时');
      expect(advices[2]).assertEqual('深睡仅 30 分钟，睡前避免饮酒或过度兴奋');
    });

    it('advice_order_is_stable', 0, () => {
      // 建议顺序即渲染顺序，ForEach 的 key 含 advice 文本，顺序变化会导致整列表重建
      const advices = generateSleepAdvices(300, 45, 30, false, 60);
      expect(advices[0].indexOf('睡前使用')).assertEqual(0);
    });
  });

  // ===== ReminderItemTypes：两个防御性拷贝函数 =====
  // 为什么必须钉死：`copyCustomReminderItem` 是 `getCustomItems()` / `getCustomItem()`
  // 的实现，而 Settings 自定义提醒列表的 ForEach 复合 key 覆盖了该接口的**全部可变字段**。
  // 拷贝少一个字段 ⇒ key 缺项 ⇒ ArkUI 对相同 key 不重建子组件 ⇒ 陈旧渲染（本项目已踩 4 次）。
  // 这两个函数原先是 HealthReminderManager 内的模块级私有函数，**完全无法被单测覆盖**。
  describe('ReminderItemTypes', () => {
    it('copyReminderConfig_copies_every_field', 0, () => {
      const src: HealthReminderConfig = {
        enabled: true, intervalMinutes: 45,
        startHour: 8, startMinute: 30, endHour: 22, endMinute: 15,
        title: '自定义标题', content: '自定义正文',
        weekdays: [1, 3, 5]
      };
      const c = copyReminderConfig(src);
      expect(c.enabled).assertEqual(true);
      expect(c.intervalMinutes).assertEqual(45);
      expect(c.startHour).assertEqual(8);
      expect(c.startMinute).assertEqual(30);
      expect(c.endHour).assertEqual(22);
      expect(c.endMinute).assertEqual(15);
      expect(c.title).assertEqual('自定义标题');
      expect(c.content).assertEqual('自定义正文');
      const copiedDays: number[] = c.weekdays ?? [];
      expect(copiedDays.length).assertEqual(3);
      expect(copiedDays[0]).assertEqual(1);
      expect(copiedDays[2]).assertEqual(5);
    });

    it('copyReminderConfig_keeps_optional_fields_undefined', 0, () => {
      // title/content/weekdays 在接口里都是可选的（备份里可能缺省）。
      // 若拷贝时改成 `?? '默认值'`，界面上就会凭空出现一个用户从未写过的标题。
      const src: HealthReminderConfig = {
        enabled: false, intervalMinutes: 20,
        startHour: 9, startMinute: 0, endHour: 21, endMinute: 0
      };
      const c = copyReminderConfig(src);
      expect(c.title === undefined).assertTrue();
      expect(c.content === undefined).assertTrue();
    });

    it('copyReminderConfig_returns_a_new_object_and_a_new_weekdays_array', 0, () => {
      // 防御性拷贝的全部意义：外部原地改写不得污染源对象
      const src: HealthReminderConfig = {
        enabled: true, intervalMinutes: 30,
        startHour: 9, startMinute: 0, endHour: 21, endMinute: 0,
        weekdays: [0, 1]
      };
      const c = copyReminderConfig(src);
      const copiedDays: number[] = c.weekdays ?? [];
      c.intervalMinutes = 999;
      copiedDays[0] = 6;
      expect(src.intervalMinutes).assertEqual(30);
      const srcDays: number[] = src.weekdays ?? [];
      expect(srcDays[0]).assertEqual(0);
    });

    it('copyReminderConfig_falls_back_to_every_day_when_weekdays_empty_or_missing', 0, () => {
      const empty: HealthReminderConfig = {
        enabled: true, intervalMinutes: 45,
        startHour: 9, startMinute: 0, endHour: 21, endMinute: 0, weekdays: []
      };
      expect((copyReminderConfig(empty).weekdays ?? []).length).assertEqual(7);
      const missing: HealthReminderConfig = {
        enabled: true, intervalMinutes: 45,
        startHour: 9, startMinute: 0, endHour: 21, endMinute: 0
      };
      expect((copyReminderConfig(missing).weekdays ?? []).length).assertEqual(7);
    });

    it('copyReminderConfig_keeps_a_single_day_weekdays_array', 0, () => {
      // 边界：判据是 length>0 而非真值。`[0]`（仅周日）是合法配置，
      // 若误用真值判据会被回退成"每天"，把用户的"仅周日提醒"悄悄改成每天提醒。
      const onlySunday: HealthReminderConfig = {
        enabled: true, intervalMinutes: 45,
        startHour: 9, startMinute: 0, endHour: 21, endMinute: 0, weekdays: [0]
      };
      const c = copyReminderConfig(onlySunday);
      const singleDay: number[] = c.weekdays ?? [];
      expect(singleDay.length).assertEqual(1);
      expect(singleDay[0]).assertEqual(0);
    });

    it('copyCustomReminderItem_copies_every_field', 0, () => {
      const src: CustomReminderItem = {
        id: 'custom_1', name: '喝水', content: '起身活动',
        intervalMinutes: 60, enabled: true,
        startHour: 8, startMinute: 0, endHour: 20, endMinute: 30,
        weekdays: [0, 2, 4, 6], notificationId: 2000
      };
      const c = copyCustomReminderItem(src);
      expect(c.id).assertEqual('custom_1');
      expect(c.name).assertEqual('喝水');
      expect(c.content).assertEqual('起身活动');
      expect(c.intervalMinutes).assertEqual(60);
      expect(c.enabled).assertEqual(true);
      expect(c.startHour).assertEqual(8);
      expect(c.startMinute).assertEqual(0);
      expect(c.endHour).assertEqual(20);
      expect(c.endMinute).assertEqual(30);
      expect(c.weekdays.length).assertEqual(4);
      expect(c.weekdays[3]).assertEqual(6);
      // notificationId 是自定义提醒的通知身份键，备份/导入流程依赖它，漏复制会串号
      expect(c.notificationId).assertEqual(2000);
    });

    it('copyCustomReminderItem_returns_a_new_object_and_a_new_weekdays_array', 0, () => {
      // Settings 的 saveCustomChangeWithRollback 正是"原地改 item 的某个字段再回滚"，
      // 若拷贝没深拷贝 weekdays，回滚会连星期的改动一起丢掉。
      const src: CustomReminderItem = {
        id: 'custom_2', name: '护眼', content: '眺望远方',
        intervalMinutes: 20, enabled: true,
        startHour: 9, startMinute: 0, endHour: 21, endMinute: 0,
        weekdays: [1, 2], notificationId: 2001
      };
      const c = copyCustomReminderItem(src);
      c.name = '改过的名字';
      c.enabled = false;
      c.weekdays[1] = 6;
      expect(src.name).assertEqual('护眼');
      expect(src.enabled).assertEqual(true);
      expect(src.weekdays[1]).assertEqual(2);
    });

    it('copyCustomReminderItem_falls_back_to_every_day_when_weekdays_empty', 0, () => {
      // 自定义项的 weekdays 在接口里是必填，但持久化数据被手工改写/多次导入叠加时可能是空数组
      const src: CustomReminderItem = {
        id: 'custom_3', name: 'x', content: 'y',
        intervalMinutes: 30, enabled: false,
        startHour: 9, startMinute: 0, endHour: 21, endMinute: 0,
        weekdays: [], notificationId: 2002
      };
      expect(copyCustomReminderItem(src).weekdays.length).assertEqual(7);
    });

    it('copied_weekdays_array_equals_source_but_is_not_the_same_reference', 0, () => {
      // ArkTS 禁索引访问，无法直接比引用；改用"改副本不影响源"等效断言
      const src: CustomReminderItem = {
        id: 'custom_4', name: 'x', content: 'y',
        intervalMinutes: 30, enabled: false,
        startHour: 9, startMinute: 0, endHour: 21, endMinute: 0,
        weekdays: [1, 2, 3], notificationId: 2003
      };
      const c = copyCustomReminderItem(src);
      c.weekdays.push(4);
      expect(c.weekdays.length).assertEqual(4);
      expect(src.weekdays.length).assertEqual(3);
    });
  });

  // ===== SleepScoreMath 的「睡眠目标感知」分支（2026-10-13 新增）=====
  // 原实现无论用户把睡眠目标设成 4 小时还是 12 小时，都按固定 360/420/540 判分，
  // 导致「目标 4 小时 + 睡 5 小时」同时出现「进度 100% 达标」与「评分 80 需要注意」。
  // 这里锁定目标驱动后的行为，并确认不传目标时旧口径逐字节不变（向后兼容）。
  describe('SleepScoreMath 睡眠目标感知', () => {
    it('goal_4h_meets_at_5h_without_penalty', 0, () => {
      // 目标 240 分钟，睡 300 分钟（5h）——按旧口径会扣 20 分（300 < 360）
      expect(computeSleepScore(300, 0, 240)).assertEqual(100);
    });

    it('goal_8h_penalises_5h_sleep', 0, () => {
      // 目标 480 分钟（8h），睡 300 分钟（5h）—— 300 < 480*0.85=408，扣 20
      expect(computeSleepScore(300, 0, 480)).assertEqual(80);
    });

    it('goal_8h_mildly_short_sleep_costs_10', 0, () => {
      // 目标 480，睡 440：408 <= 440 < 480，扣 10
      expect(computeSleepScore(440, 0, 480)).assertEqual(90);
    });

    it('goal_12h_does_not_reward_9h_sleep', 0, () => {
      // 目标 720（12h），睡 540（9h）：540 < 612（目标 85%）⇒ 扣 20。
      // 目标调大后同样的 9 小时会被判为不足——这是目标驱动的预期行为：
      // 旧口径把 9 小时当"恰到好处"，但用户既然设了 12 小时，说明他不满足于 9 小时。
      expect(computeSleepScore(540, 0, 720)).assertEqual(80);
    });

    it('goal_4h_punishes_oversleep_at_6h', 0, () => {
      // 目标 240，睡 360：360 > 240*1.35=324，扣 5（睡过多）
      expect(computeSleepScore(360, 0, 240)).assertEqual(95);
    });

    it('without_goal_keeps_legacy_fixed_thresholds', 0, () => {
      // 不传目标 → 沿用 7–9 小时为佳的历史口径，与新增参数之前逐字节一致。
      // 边界说明：360 恰好**不满足** `< 360`，落入 `< 420` 的轻度不足档，扣 10 ⇒ 90
      expect(computeSleepScore(300, 0)).assertEqual(80);
      expect(computeSleepScore(360, 0)).assertEqual(90);
      expect(computeSleepScore(400, 0)).assertEqual(90);
      expect(computeSleepScore(480, 0)).assertEqual(100);
      expect(computeSleepScore(600, 0)).assertEqual(95);
    });

    it('invalid_goal_falls_back_to_legacy_thresholds', 0, () => {
      // 非法目标（0 / 负数 / NaN）不得让判分崩掉，退回旧口径
      expect(computeSleepScore(300, 0, 0)).assertEqual(80);
      expect(computeSleepScore(300, 0, -100)).assertEqual(80);
      expect(computeSleepScore(300, 0, NaN)).assertEqual(80);
    });

    it('pre_sleep_penalty_still_applies_with_goal', 0, () => {
      // 睡前使用扣分与目标分支正交：目标达标但睡前用 90 分钟 → 100-20=80
      expect(computeSleepScore(300, 90, 240)).assertEqual(80);
    });

    it('advice_with_goal_references_the_users_own_target', 0, () => {
      // 目标驱动时不再说"建议争取 7-8 小时"这种与用户设置矛盾的话，
      // 而是引用用户自己设的目标小时数。
      // 场景取**未达标**：目标 240（4h）睡 200（3h20）⇒ 200 < 240，触发建议
      const advices = generateSleepAdvices(200, 0, undefined, false, 60, 240);
      expect(advices[0].indexOf('7-8小时')).assertEqual(-1);
      expect(advices[0].indexOf('4小时目标') >= 0).assertTrue();
    });

    it('advice_with_goal_is_silent_when_target_met', 0, () => {
      // 达标（目标 240 睡 300）就不该出现"距离目标还差…"的建议，只剩兜底语
      const advices = generateSleepAdvices(300, 0, undefined, false, 60, 240);
      expect(advices[0].indexOf('还差')).assertEqual(-1);
    });

    it('advice_without_goal_keeps_legacy_wording', 0, () => {
      const advices = generateSleepAdvices(300, 0, undefined, false, 60);
      expect(advices[0]).assertEqual('昨晚睡眠约 5小时，建议今晚争取 7-8小时');
    });
  });

  describe('免打扰时段边界', () => {
    it('daytime_window_includes_both_ends', 0, () => {
      // 09:00-17:00 = 540..1020
      expect(isInDowntimeRange(539, 540, 1020)).assertEqual(false);
      expect(isInDowntimeRange(540, 540, 1020)).assertEqual(true);
      expect(isInDowntimeRange(1020, 540, 1020)).assertEqual(true);
      expect(isInDowntimeRange(1021, 540, 1020)).assertEqual(false);
    });

    it('cross_midnight_window_covers_both_ends', 0, () => {
      // 22:00-07:00 = 1320..420
      expect(isInDowntimeRange(1319, 1320, 420)).assertEqual(false);
      expect(isInDowntimeRange(1320, 1320, 420)).assertEqual(true);
      expect(isInDowntimeRange(420, 1320, 420)).assertEqual(true);
      expect(isInDowntimeRange(421, 1320, 420)).assertEqual(false);
      expect(isInDowntimeRange(0, 1320, 420)).assertEqual(true);
    });

    it('equal_start_and_end_means_all_day_not_one_minute', 0, () => {
      // ⚠️ 这条是防"修正"用例。免打扰是【禁用】窗口，起止相同 = 一整天都禁用；
      // 若把判别符 `<` 误改成 `<=`（对齐 ReminderTimeUtils.isInActiveWindow），
      // 语义会退化成"只有那一分钟被禁"，用户设 22:00-22:00 反而其余时间照常。
      // 两者的极值方向刻意相反，见 UsageStatsMath.isInDowntimeRange 的注释。
      for (let m = 0; m < 1440; m++) {
        if (!isInDowntimeRange(m, 1320, 1320)) {
          expect(`全天语义在 ${m} 分钟处被破坏`).assertEqual('never');
        }
      }
      expect(true).assertEqual(true);
    });

    it('equal_start_and_end_via_the_plain_zero_window', 0, () => {
      // 00:00-00:00 同样应视为全天
      expect(isInDowntimeRange(0, 0, 0)).assertEqual(true);
      expect(isInDowntimeRange(719, 0, 0)).assertEqual(true);
      expect(isInDowntimeRange(1439, 0, 0)).assertEqual(true);
    });
  });

  // ⚠️ 本组是"字面量漂移"的防线，两条都对应真实发生过 / 可能发生的数据损坏路径。
  describe('每日目标 内置目标 id 与备份日期', () => {
    it('builtin_goal_ids_contains_the_real_focus_session_id', 0, () => {
      // 内置"专注时光"目标在 DailyGoalManager.setupDefaultGoals 里的真实 id 是 focus_session。
      // 备份恢复靠 BUILTIN_GOAL_IDS 决定跳过哪些目标；一旦这个表里写成 focus_time（历史上就写错过），
      // focus_session 会被当成自定义目标导入 → checkType 被硬编码成 'custom'
      // → GoalPage 多出「✕」→ 用户一点就把它删掉 → updateGoalProgress 取不到 focus_session，
      // 内置目标在本会话内彻底消失，且没有任何报错。
      const ids: string[] = DailyGoalManager.BUILTIN_GOAL_IDS;
      expect(ids.indexOf('focus_session') >= 0).assertEqual(true);
      expect(ids.indexOf('focus_time') >= 0).assertEqual(false);
    });

    it('builtin_goal_ids_cover_all_three_builtin_goals', 0, () => {
      const ids: string[] = DailyGoalManager.BUILTIN_GOAL_IDS;
      expect(ids.length).assertEqual(3);
      expect(ids.indexOf('unlock_control') >= 0).assertEqual(true);
      expect(ids.indexOf('usage_control') >= 0).assertEqual(true);
    });

    it('yesterday_date_key_matches_only_the_previous_day', 0, () => {
      // 真实缺陷：快照判据一处写「等于昨天」、一处写「等于今天」，
      // 于是「复制昨日目标」按钮亮着却永远复制失败。
      const now: number = new Date(2026, 9, 24, 10, 0, 0).getTime();
      expect(isYesterdayDateKey('2026-10-23', now)).assertEqual(true);
      expect(isYesterdayDateKey('2026-10-24', now)).assertEqual(false);
      expect(isYesterdayDateKey('2026-10-22', now)).assertEqual(false);
      // 凌晨与月初边界：昨天可能落在上个月
      const earlyMorning: number = new Date(2026, 9, 24, 0, 0, 30).getTime();
      expect(isYesterdayDateKey('2026-10-23', earlyMorning)).assertEqual(true);
      const firstDayOfMonth: number = new Date(2026, 9, 1, 8, 0, 0).getTime();
      expect(isYesterdayDateKey('2026-09-30', firstDayOfMonth)).assertEqual(true);
      // 非法/空值不应命中
      expect(isYesterdayDateKey('', now)).assertEqual(false);
      expect(isYesterdayDateKey('2026-13-01', now)).assertEqual(false);
    });
  });

  // ⚠️ 这组用例是 formatError 存在的**全部理由**：JSON.stringify 对原生异常返回 '{}'，
  // 实机证据「备份文件解析失败：{}」——错误发生了、日志里却什么都没留下。
  describe('formatError 错误可读性', () => {
    it('syntax_error_message_is_not_lost', 0, () => {
      // JSON.parse 的失败正是本项目最常见的"数据被写坏"故障，必须能看到原因
      let caught: Object = 'never';
      try {
        JSON.parse('{bad json');
      } catch (err) {
        caught = err as Object;
      }
      const text = formatError(caught);
      expect(text === '{}').assertEqual(false);
      expect(text.length > 0).assertEqual(true);
      expect(text.indexOf('JSON') >= 0).assertEqual(true);
    });

    it('business_error_reports_both_code_and_message', 0, () => {
      const e: BusinessErrorLike = { code: 13900002, message: 'No such file or directory' };
      expect(formatError(e as Object)).assertEqual('code=13900002 message=No such file or directory');
    });

    it('code_only_error_does_not_produce_empty_text', 0, () => {
      const e: BusinessErrorLike = { code: 9800005 };
      expect(formatError(e as Object)).assertEqual('code=9800005');
    });

    it('string_error_is_returned_verbatim', 0, () => {
      expect(formatError('plain failure' as Object)).assertEqual('plain failure');
    });

    it('an_empty_object_still_produces_readable_text', 0, () => {
      // 空串会让 "xxx失败：" 这种日志行看起来像没报过错，必须保证任何输入都产出非空文本
      const empty: BusinessErrorLike = { code: 0 };
      expect(formatError(empty as Object).length > 0).assertEqual(true);
    });

    it('oversized_message_is_truncated', 0, () => {
      const long = new Array<string>(500).fill('x').join('');
      expect(formatError(long as Object).indexOf('已截断') > 0).assertEqual(true);
    });
  });

  describe('HomeCardLayout 首页布局', () => {
    it('default_config_holds_all_cards_in_default_order', 0, () => {
      const base: HomeCardConfigEntry[] = defaultHomeCardConfig();
      expect(base.length).assertEqual(9);
      expect(base[0].id).assertEqual('usage');
      expect(base[2].id).assertEqual('trend');
      expect(base[8].id).assertEqual('achievement');
      expect(visibleHomeCardCount(base)).assertEqual(9);
    });

    it('re_showing_a_hidden_card_restores_its_original_position', 0, () => {
      // 这是本次改造的核心：旧结构只存"可见列表"，隐藏后再显示会被追加到末尾。
      const base: HomeCardConfigEntry[] = defaultHomeCardConfig();
      const hidden: HomeCardConfigEntry[] = setHomeCardVisible(base, 'trend', false);
      expect(visibleHomeCardCount(hidden)).assertEqual(8);
      expect(visibleHomeCardIds(hidden).indexOf('trend')).assertEqual(-1);
      // 隐藏时它在完整列表里的槽位不变
      expect(hidden[2].id).assertEqual('trend');
      expect(hidden[2].visible).assertEqual(false);
      // 重新显示 → 回到原位（第 3 位），不是末尾
      const shown: HomeCardConfigEntry[] = setHomeCardVisible(hidden, 'trend', true);
      const ids: string[] = visibleHomeCardIds(shown);
      expect(ids.length).assertEqual(9);
      expect(ids[2]).assertEqual('trend');
    });

    it('toggling_visibility_never_changes_the_order', 0, () => {
      const base: HomeCardConfigEntry[] = defaultHomeCardConfig();
      const hidden: HomeCardConfigEntry[] = setHomeCardVisible(base, 'usage', false);
      const shown: HomeCardConfigEntry[] = setHomeCardVisible(hidden, 'usage', true);
      for (let i = 0; i < base.length; i++) {
        expect(shown[i].id).assertEqual(base[i].id);
      }
    });

    it('move_swaps_two_visible_cards_and_keeps_hidden_slots', 0, () => {
      const base: HomeCardConfigEntry[] = defaultHomeCardConfig();
      const withHidden: HomeCardConfigEntry[] = setHomeCardVisible(base, 'trend', false);
      // 可见序列是 usage,downtime,unlock,...；把 unlock 上移一位
      const moved: HomeCardConfigEntry[] = moveHomeCardInConfig(withHidden, 'unlock', -1);
      const ids: string[] = visibleHomeCardIds(moved);
      expect(ids[0]).assertEqual('usage');
      expect(ids[1]).assertEqual('unlock');
      expect(ids[2]).assertEqual('downtime');
      // 隐藏的 trend 仍占着完整列表的第 3 个槽位
      expect(moved[2].id).assertEqual('trend');
      expect(moved[2].visible).assertEqual(false);
    });

    it('move_does_not_reorder_a_hidden_card', 0, () => {
      const base: HomeCardConfigEntry[] = defaultHomeCardConfig();
      const withHidden: HomeCardConfigEntry[] = setHomeCardVisible(base, 'trend', false);
      const before: string[] = visibleHomeCardIds(withHidden);
      const moved: HomeCardConfigEntry[] = moveHomeCardInConfig(withHidden, 'trend', -1);
      const after: string[] = visibleHomeCardIds(moved);
      expect(after.length).assertEqual(before.length);
      for (let i = 0; i < before.length; i++) {
        expect(after[i]).assertEqual(before[i]);
      }
    });

    it('move_is_a_noop_at_the_first_and_last_visible_position', 0, () => {
      const base: HomeCardConfigEntry[] = defaultHomeCardConfig();
      const up: HomeCardConfigEntry[] = moveHomeCardInConfig(base, 'usage', -1);
      expect(visibleHomeCardIds(up)[0]).assertEqual('usage');
      const down: HomeCardConfigEntry[] = moveHomeCardInConfig(base, 'achievement', 1);
      expect(visibleHomeCardIds(down)[8]).assertEqual('achievement');
    });

    it('visible_count_and_index_match_the_visible_sequence', 0, () => {
      const base: HomeCardConfigEntry[] = defaultHomeCardConfig();
      expect(visibleIndexOfHomeCard(base, 'usage')).assertEqual(0);
      expect(visibleIndexOfHomeCard(base, 'achievement')).assertEqual(8);
      const hidden: HomeCardConfigEntry[] = setHomeCardVisible(base, 'usage', false);
      expect(visibleHomeCardCount(hidden)).assertEqual(8);
      expect(visibleIndexOfHomeCard(hidden, 'usage')).assertEqual(-1);
      expect(visibleIndexOfHomeCard(hidden, 'downtime')).assertEqual(0);
      expect(isHomeCardVisible(hidden, 'usage')).assertEqual(false);
      expect(isHomeCardVisible(hidden, 'downtime')).assertEqual(true);
    });

    it('the_result_is_a_copy_and_does_not_alias_the_input', 0, () => {
      const base: HomeCardConfigEntry[] = defaultHomeCardConfig();
      const changed: HomeCardConfigEntry[] = setHomeCardVisible(base, 'usage', false);
      expect(changed === base).assertEqual(false);
      expect(visibleHomeCardCount(base)).assertEqual(9);
      expect(visibleHomeCardCount(changed)).assertEqual(8);
    });

    it('parse_rejects_garbage', 0, () => {
      expect(parseHomeCardConfig('') === null).assertEqual(true);
      expect(parseHomeCardConfig('{bad') === null).assertEqual(true);
      expect(parseHomeCardConfig('{"a":1}') === null).assertEqual(true);
      expect(parseHomeCardConfig('[]') === null).assertEqual(true);
    });

    it('parse_drops_unknown_ids_and_dedupes', 0, () => {
      const raw: string = layoutJson(['usage', 'true', 'usage', 'false', 'not_a_card', 'true']);
      const parsed: HomeCardConfigEntry[] | null = parseHomeCardConfig(raw);
      expect(parsed !== null).assertEqual(true);
      const list: HomeCardConfigEntry[] = parsed === null ? [] : parsed;
      expect(list.length).assertEqual(9);
      expect(list[0].id).assertEqual('usage');
      expect(list[0].visible).assertEqual(true);
    });

    it('parse_appends_missing_ids', 0, () => {
      const raw: string = layoutJson(['trend', 'true']);
      const parsed: HomeCardConfigEntry[] | null = parseHomeCardConfig(raw);
      const list: HomeCardConfigEntry[] = parsed === null ? [] : parsed;
      expect(list.length).assertEqual(9);
      expect(list[0].id).assertEqual('trend');
      expect(list[8].visible).assertEqual(true);
    });

    it('legacy_migration_preserves_the_visible_order', 0, () => {
      // 旧格式只存可见列表：这里"解锁洞察"被移到了"免打扰提醒"前面
      const raw: string = JSON.stringify(
        ['usage', 'unlock', 'downtime', 'goal', 'insights', 'reminder', 'focus', 'achievement']);
      const migrated: HomeCardConfigEntry[] | null = migrateLegacyHomeCardConfig(raw);
      expect(migrated !== null).assertEqual(true);
      const list: HomeCardConfigEntry[] = migrated === null ? [] : migrated;
      const ids: string[] = visibleHomeCardIds(list);
      expect(ids.length).assertEqual(8);
      expect(ids[0]).assertEqual('usage');
      expect(ids[1]).assertEqual('unlock');
      expect(ids[2]).assertEqual('downtime');
    });

    it('legacy_migration_keeps_the_hidden_card_in_the_default_slot', 0, () => {
      const raw: string = JSON.stringify(
        ['usage', 'unlock', 'downtime', 'goal', 'insights', 'reminder', 'focus', 'achievement']);
      const migrated: HomeCardConfigEntry[] | null = migrateLegacyHomeCardConfig(raw);
      const list: HomeCardConfigEntry[] = migrated === null ? [] : migrated;
      expect(list[2].id).assertEqual('trend');
      expect(list[2].visible).assertEqual(false);
    });

    it('legacy_migration_rejects_empty_and_invalid_input', 0, () => {
      expect(migrateLegacyHomeCardConfig('') === null).assertEqual(true);
      expect(migrateLegacyHomeCardConfig('{bad') === null).assertEqual(true);
      expect(migrateLegacyHomeCardConfig('[]') === null).assertEqual(true);
    });
  });

  describe('强调色映射', () => {
    it('accentTextHex_returns_preset_hex_unchanged', 0, () => {
      expect(accentTextHex('#0066CC', false)).assertEqual('#0066CC');
      expect(accentTextHex('#6CB6FF', true)).assertEqual('#6CB6FF');
      expect(accentTextHex('#1B7A34', false)).assertEqual('#1B7A34');
      expect(accentTextHex('#4ADE80', true)).assertEqual('#4ADE80');
      expect(accentTextHex('#CC2936', false)).assertEqual('#CC2936');
      expect(accentTextHex('#FF6B6B', true)).assertEqual('#FF6B6B');
      expect(accentTextHex('#9A6400', false)).assertEqual('#9A6400');
      expect(accentTextHex('#FFB84D', true)).assertEqual('#FFB84D');
      expect(accentTextHex('#4A47CC', false)).assertEqual('#4A47CC');
      expect(accentTextHex('#9B8FFF', true)).assertEqual('#9B8FFF');
      expect(accentTextHex('#0077A3', false)).assertEqual('#0077A3');
      expect(accentTextHex('#4DC9FF', true)).assertEqual('#4DC9FF');
    });

    it('accentFillHex_maps_preset_light_and_dark_to_their_fill', 0, () => {
      expect(accentFillHex('#0066CC', false)).assertEqual('#0066CC');
      expect(accentFillHex('#6CB6FF', true)).assertEqual('#3578C4');
      expect(accentFillHex('#1B7A34', false)).assertEqual('#1B7A34');
      expect(accentFillHex('#4ADE80', true)).assertEqual('#1F7A43');
      expect(accentFillHex('#CC2936', false)).assertEqual('#CC2936');
      expect(accentFillHex('#FF6B6B', true)).assertEqual('#CC3530');
      expect(accentFillHex('#9A6400', false)).assertEqual('#9A6400');
      expect(accentFillHex('#FFB84D', true)).assertEqual('#996000');
      expect(accentFillHex('#4A47CC', false)).assertEqual('#4A47CC');
      expect(accentFillHex('#9B8FFF', true)).assertEqual('#4A47B8');
      expect(accentFillHex('#0077A3', false)).assertEqual('#0077A3');
      expect(accentFillHex('#4DC9FF', true)).assertEqual('#1A7699');
    });

    it('accentTextHex_maps_identity_colors_to_the_matching_preset', 0, () => {
      expect(accentTextHex('#007AFF', false)).assertEqual('#0066CC');
      expect(accentTextHex('#007AFF', true)).assertEqual('#6CB6FF');
      expect(accentTextHex('#34C759', false)).assertEqual('#1B7A34');
      expect(accentTextHex('#34C759', true)).assertEqual('#4ADE80');
      expect(accentTextHex('#FF9500', false)).assertEqual('#9A6400');
      expect(accentTextHex('#FF9500', true)).assertEqual('#FFB84D');
      expect(accentTextHex('#FF3B30', false)).assertEqual('#CC2936');
      expect(accentTextHex('#FF3B30', true)).assertEqual('#FF6B6B');
      expect(accentTextHex('#AF52DE', false)).assertEqual('#4A47CC');
      expect(accentTextHex('#AF52DE', true)).assertEqual('#9B8FFF');
    });

    it('accentFillHex_maps_identity_colors_to_the_matching_preset_fill', 0, () => {
      expect(accentFillHex('#007AFF', false)).assertEqual('#0066CC');
      expect(accentFillHex('#007AFF', true)).assertEqual('#3578C4');
      expect(accentFillHex('#34C759', false)).assertEqual('#1B7A34');
      expect(accentFillHex('#34C759', true)).assertEqual('#1F7A43');
      expect(accentFillHex('#FF9500', false)).assertEqual('#9A6400');
      expect(accentFillHex('#FF9500', true)).assertEqual('#996000');
      expect(accentFillHex('#FF3B30', false)).assertEqual('#CC2936');
      expect(accentFillHex('#FF3B30', true)).assertEqual('#CC3530');
      expect(accentFillHex('#AF52DE', false)).assertEqual('#4A47CC');
      expect(accentFillHex('#AF52DE', true)).assertEqual('#4A47B8');
    });

    it('accentTextHex_and_accentFillHex_keep_legacy_system_colors', 0, () => {
      expect(accentTextHex('#0A84FF', false)).assertEqual('#0066CC');
      expect(accentTextHex('#0A84FF', true)).assertEqual('#6CB6FF');
      expect(accentTextHex('#30D158', true)).assertEqual('#4ADE80');
      expect(accentTextHex('#FF9F0A', true)).assertEqual('#FFB84D');
      expect(accentTextHex('#FF453A', true)).assertEqual('#FF6B6B');
      expect(accentTextHex('#5E5CE6', true)).assertEqual('#9B8FFF');
      expect(accentTextHex('#BF5AF2', false)).assertEqual('#9B3FD6');
      expect(accentTextHex('#BF5AF2', true)).assertEqual('#DA8FFF');
      expect(accentFillHex('#BF5AF2', false)).assertEqual('#9B3FD6');
      expect(accentFillHex('#BF5AF2', true)).assertEqual('#9848C2');
    });

    it('accent_mapping_passes_unknown_hex_through', 0, () => {
      expect(accentTextHex('#123456', false)).assertEqual('#123456');
      expect(accentTextHex('#123456', true)).assertEqual('#123456');
      expect(accentFillHex('#123456', false)).assertEqual('#123456');
      expect(accentFillHex('#123456', true)).assertEqual('#123456');
    });

    it('every_accent_preset_fill_carries_white_text_at_wcag_aa', 0, () => {
      expect(contrastWithWhite('#0066CC') >= 4.5).assertEqual(true);
      expect(contrastWithWhite('#3578C4') >= 4.5).assertEqual(true);
      expect(contrastWithWhite('#1B7A34') >= 4.5).assertEqual(true);
      expect(contrastWithWhite('#1F7A43') >= 4.5).assertEqual(true);
      expect(contrastWithWhite('#CC2936') >= 4.5).assertEqual(true);
      expect(contrastWithWhite('#CC3530') >= 4.5).assertEqual(true);
      expect(contrastWithWhite('#9A6400') >= 4.5).assertEqual(true);
      expect(contrastWithWhite('#996000') >= 4.5).assertEqual(true);
      expect(contrastWithWhite('#4A47CC') >= 4.5).assertEqual(true);
      expect(contrastWithWhite('#4A47B8') >= 4.5).assertEqual(true);
      expect(contrastWithWhite('#0077A3') >= 4.5).assertEqual(true);
      expect(contrastWithWhite('#1A7699') >= 4.5).assertEqual(true);
    });

    it('all_accent_presets_fill_meet_wcag_aa', 0, () => {
      expect(ACCENT_COLOR_PRESETS.length).assertEqual(6);
      for (let i = 0; i < ACCENT_COLOR_PRESETS.length; i++) {
        expect(contrastWithWhite(ACCENT_COLOR_PRESETS[i].lightFill) >= 4.5).assertEqual(true);
        expect(contrastWithWhite(ACCENT_COLOR_PRESETS[i].darkFill) >= 4.5).assertEqual(true);
      }
    });
  });

  describe('自定义强调色', () => {
    it('normalize_hex_color_accepts_common_formats', 0, () => {
      expect(normalizeHexColor('#4a47cc')).assertEqual('#4A47CC');
      expect(normalizeHexColor('4A47CC')).assertEqual('#4A47CC');
      expect(normalizeHexColor('#4A4')).assertEqual('#44AA44');
      expect(normalizeHexColor('  #4A47CC  ')).assertEqual('#4A47CC');
    });

    it('normalize_hex_color_rejects_invalid_input', 0, () => {
      expect(normalizeHexColor('')).assertEqual('');
      expect(normalizeHexColor('blue')).assertEqual('');
      expect(normalizeHexColor('#12345')).assertEqual('');
      expect(normalizeHexColor('#GGGGGG')).assertEqual('');
      expect(normalizeHexColor('#12 34 5')).assertEqual('');
      expect(normalizeHexColor('rgba(1,2,3,1)')).assertEqual('');
    });

    it('derive_text_color_meets_wcag_on_both_backgrounds', 0, () => {
      // 覆盖"很浅/很深/高饱和"三类极端输入：推导结果必须两种模式都达标
      const samples: string[] = ['#FFD700', '#00FFFF', '#FF69B4', '#7FFF00', '#123456', '#FFFFFF', '#000000'];
      for (let i = 0; i < samples.length; i++) {
        const darkText: string = deriveAccentTextColor(samples[i], true);
        expect(contrastRatio(darkText, ACCENT_BG_DARK) >= MIN_ACCENT_CONTRAST).assertEqual(true);
        const lightText: string = deriveAccentTextColor(samples[i], false);
        expect(contrastRatio(lightText, ACCENT_BG_LIGHT) >= MIN_ACCENT_CONTRAST).assertEqual(true);
      }
    });

    it('derive_text_color_keeps_readable_color_unchanged', 0, () => {
      expect(deriveAccentTextColor('#1B7A34', false)).assertEqual('#1B7A34');
      expect(deriveAccentTextColor('#4ADE80', true)).assertEqual('#4ADE80');
    });

    it('derive_fill_color_carries_white_text', 0, () => {
      const samples: string[] = ['#FFD700', '#00FFFF', '#FF69B4', '#7FFF00', '#FFFFFF', '#4A47CC', '#000000'];
      for (let i = 0; i < samples.length; i++) {
        expect(contrastRatio(deriveAccentFillColor(samples[i]), '#FFFFFF') >= MIN_ACCENT_CONTRAST).assertEqual(true);
      }
    });

    it('accent_fill_maps_custom_light_color_to_readable_fill', 0, () => {
      // 浅金 #FFD700 直接当填充时白字只有 ~1.4:1，必须被压暗
      const fill: string = accentFillHex('#FFD700', false);
      expect(fill === '#FFD700').assertEqual(false);
      expect(contrastWithWhite(fill) >= 4.5).assertEqual(true);
    });

    it('accent_text_passes_custom_hex_through_unchanged', 0, () => {
      // 文本色由 ThemeManager 先用 deriveAccentTextColor 推导过，映射层保持透传
      expect(accentTextHex('#FFD700', false)).assertEqual('#FFD700');
      expect(accentTextHex('#FFD700', true)).assertEqual('#FFD700');
    });

    it('describe_hex_input_error_explains_invalid_values', 0, () => {
      expect(describeHexInputError('').length > 0).assertEqual(true);
      expect(describeHexInputError('blue').length > 0).assertEqual(true);
      expect(describeHexInputError('#4A47CC')).assertEqual('');
    });

    it('contrast_ratio_matches_known_wcag_values', 0, () => {
      expect(Math.abs(contrastRatio('#000000', '#FFFFFF') - 21) < 0.01).assertEqual(true);
      expect(Math.abs(contrastRatio('#FFFFFF', '#FFFFFF') - 1) < 0.01).assertEqual(true);
    });
  });

  describe('个性化称呼', () => {
    it('normalize_nickname_trims_and_rejects_blank', 0, () => {
      expect(normalizeNickname('  小萤  ')).assertEqual('小萤');
      expect(normalizeNickname('')).assertEqual('');
      expect(normalizeNickname('   ')).assertEqual('');
      expect(normalizeNickname('\n\t')).assertEqual('');
    });

    it('normalize_nickname_strips_control_chars_and_collapses_spaces', 0, () => {
      expect(normalizeNickname('小\n萤')).assertEqual('小萤');
      expect(normalizeNickname('小  萤')).assertEqual('小 萤');
      expect(normalizeNickname('小\t萤\r\n')).assertEqual('小萤');
    });

    it('normalize_nickname_truncates_without_splitting_emoji', 0, () => {
      // 11 个汉字 + emoji（2 个码元）= 13，截到 12 时不能把 emoji 切成半个
      const normalized: string = normalizeNickname('一二三四五六七八九十一😀');
      expect(normalized).assertEqual('一二三四五六七八九十一');
      expect(normalized.length).assertEqual(11);
    });

    it('greeting_appends_nickname_only_when_present', 0, () => {
      expect(greetingWithNickname('早上好', '小萤')).assertEqual('早上好，小萤');
      expect(greetingWithNickname('早上好', '   ')).assertEqual('早上好');
      expect(greetingWithNickname('早上好', '')).assertEqual('早上好');
      expect(greetingWithNickname('早上好', '小萤\n')).assertEqual('早上好，小萤');
    });
  });
}
