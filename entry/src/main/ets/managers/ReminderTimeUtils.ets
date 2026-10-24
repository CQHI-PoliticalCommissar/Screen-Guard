/**
 * 提醒时间工具
 * 纯函数集合：活跃时段判断、下次触发时刻、时间格式化。
 * 不依赖任何平台能力，便于本地单元测试。
 */

import { WEEKDAY_FULL_LABELS } from '../models/HealthTypes';
import {
  DEFAULT_START_HOUR,
  DEFAULT_START_MINUTE,
  DEFAULT_END_HOUR,
  DEFAULT_END_MINUTE
} from '../models/ReminderConfigMath';

/** 常驻提醒调度规格 */
export interface OngoingReminderSpec {
  notificationId: number;
  title: string;
  content: string;
  /** true 时用户无法从通知栏手动划掉（与"今日使用时长"常驻通知一致） */
  unremovable: boolean;
  /** 间隔提醒（久坐/用眼/喝水/自定义）：活跃时段内每 intervalMinutes 分钟触发一次 */
  intervalMinutes?: number;
  startHour?: number;
  startMinute?: number;
  endHour?: number;
  endMinute?: number;
  weekdays?: number[];
  /** 每日固定时刻提醒（睡前/停用时间）：每天 dailyHour:dailyMinute 触发一次 */
  dailyHour?: number;
  dailyMinute?: number;
  /** 一次性提醒（护眼/专注完成）：注册后 oneShotSeconds 秒触发一次，随后自动移除 */
  oneShotSeconds?: number;
  /**
   * 是否让这条通知以**横幅**形式在通知栏弹出（`notificationFlags.bannerEnabled`）。
   *
   * 只给"到点该行动了"的定时提醒开：免打扰 / 睡前 / 久坐 / 用眼 / 喝水 / 护眼 / 专注完成。
   * 「今日使用时长」常驻通知**刻意不开** —— 它每 30 秒刷新一次文案，
   * 开横幅会变成不停弹横幅的骚扰。
   *
   * ⚠️ 这**不是**"霸屏"（full-screen intent）。本 SDK 的 `NotificationRequest`
   * 根本没有 `isFullScreenIntent` 字段——真正的全屏通知普通应用拿不到。
   * 横幅能否弹出还取决于用户在系统设置里对本应用是否开启了「横幅通知」，应用侧无法强制。
   */
  banner?: boolean;
}


/**
 * 判断给定时刻是否处于活跃时段（星期 + 起止时间窗，支持跨午夜 start>end）
 *
 * 跨午夜（start > end）时的星期归属：`00:00`–`endMinute` 这段属于**前一天**开启的
 * 窗口，因此用「当前时刻减一天的星期」判定，否则「仅周一 22:00–02:00」在周二 01:00
 * 会被误判为非活跃。
 */
export function isInActiveWindow(spec: OngoingReminderSpec, date: Date): boolean {
  const weekdays = spec.weekdays ?? [];
  if (weekdays.length === 0) {
    return false;
  }
  const cur = date.getHours() * 60 + date.getMinutes();
  const start = (spec.startHour ?? DEFAULT_START_HOUR) * 60 + (spec.startMinute ?? DEFAULT_START_MINUTE);
  const end = (spec.endHour ?? DEFAULT_END_HOUR) * 60 + (spec.endMinute ?? DEFAULT_END_MINUTE);
  if (start <= end) {
    // 不跨午夜：星期与时间窗都在同一天内
    return weekdays.includes(date.getDay()) && cur >= start && cur <= end;
  }
  // 跨午夜：start 当天（用当天星期）
  if (cur >= start) {
    return weekdays.includes(date.getDay());
  }
  // 跨午夜：end 当天（归属前一天，用前一天星期；周日的前一天是周六）
  if (cur <= end) {
    return weekdays.includes((date.getDay() + 6) % 7);
  }
  return false;
}

/**
 * 计算 baseMs 之后（严格大于）的下一个活跃时段开始时刻
 */
export function nextActiveStartMs(spec: OngoingReminderSpec, baseMs: number): number {
  const startHour = spec.startHour ?? DEFAULT_START_HOUR;
  const startMinute = spec.startMinute ?? DEFAULT_START_MINUTE;
  const weekdays = spec.weekdays ?? [];
  for (let offset = 0; offset <= 7; offset++) {
    // d 是循环内新建的局部变量，除下面的 setHours 外无其他持有者，
    // 因此直接复用而不再 `new Date(d)` 复制一份（每次调用省一半 Date 分配；
    // 本方法由 10s tick 的提醒调度器驱动，会被反复调用）
    const d = new Date(baseMs + offset * 86400000);
    if (weekdays.includes(d.getDay())) {
      d.setHours(startHour, startMinute, 0, 0);
      if (d.getTime() > baseMs) {
        return d.getTime();
      }
    }
  }
  return baseMs + 86400000;
}

/**
 * 时间戳转本地日期键 YYYY-MM-DD
 */
export function dateKey(ms: number): string {
  return dateKeyFromDate(new Date(ms));
}

/**
 * Date 转本地日期键 YYYY-MM-DD。
 * 拆分出来是为了让 10s tick 的提醒调度器能把同一个 Date 实例传给所有条目，
 * 避免每条目每 tick 各建一次 Date（这些方法只读取，不修改传入的 Date）。
 */
export function dateKeyFromDate(d: Date): string {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

/**
 * 当日 dailyHour:dailyMinute 对应的本地时间戳
 */
export function todayAtMs(hour: number, minute: number): number {
  const d = new Date();
  d.setHours(hour, minute, 0, 0);
  return d.getTime();
}

/**
 * 剩余时长格式化：X 秒 / X 分钟 / X 小时 / X 小时 Y 分钟
 */
export function formatRemain(ms: number): string {
  const sec = Math.max(0, Math.ceil(ms / 1000));
  if (sec < 60) {
    return `${sec} 秒`;
  }
  const min = Math.floor(sec / 60);
  if (min < 60) {
    return `${min} 分钟`;
  }
  const h = Math.floor(min / 60);
  const m = min % 60;
  if (m === 0) {
    return `${h} 小时`;
  }
  return `${h} 小时 ${m} 分钟`;
}

/**
 * 时间戳格式化为 HH:MM
 */
export function formatTime(ms: number): string {
  const d = new Date(ms);
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
}

/**
 * 时刻格式化：今天/明天 HH:MM，更远则星期 HH:MM
 */
export function formatDateTime(ms: number): string {
  const d = new Date(ms);
  const now = new Date();
  const startNow = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  const startTarget = new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  const diff = Math.round((startTarget - startNow) / 86400000);
  const hm = formatTime(ms);
  if (diff === 0) {
    return `今天 ${hm}`;
  }
  if (diff === 1) {
    return `明天 ${hm}`;
  }
  return `${WEEKDAY_FULL_LABELS[d.getDay()]} ${hm}`;
}
