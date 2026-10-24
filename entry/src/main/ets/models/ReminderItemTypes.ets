/**
 * 健康提醒的数据类型与防御性拷贝。
 *
 * 这两个 interface 与两个 copy 函数原先定义在 `managers/HealthReminderManager` 内，
 * 但它们是**纯数据结构与纯拷贝**，与实例状态、prefs、通知系统全无关系，
 * 却因此完全无法被 LocalUnit 覆盖——而拷贝函数恰恰是最容易漏字段的地方：
 *
 * - `copyReminderConfig` / `copyCustomReminderItem` 少复制一个字段，
 *   `Settings` 自定义提醒列表的 ForEach 复合 key 就会缺一项，
 *   触发本项目已踩坑 4 次的「key 未变化 → ArkUI 不重建子组件」陈旧渲染；
 * - `getCustomItems()` 每次都经 `copyCustomReminderItem` 返回副本，
 *   少复制字段等于让外部拿到残缺对象并原地改写污染持久化态。
 *
 * 搬到此处后由 `ReminderItemCopy.test` 的字段级用例钉死。
 * 硬约定同其余 models 纯函数内核：**不读单例、不读 prefs、不调用 Date.now()**。
 */

import { ALL_WEEKDAYS } from './HealthTypes';

/**
 * 健康提醒配置
 */
export interface HealthReminderConfig {
  enabled: boolean;
  intervalMinutes: number;
  startHour: number;
  startMinute: number;
  endHour: number;
  endMinute: number;
  title?: string;
  content?: string;
  weekdays?: number[];
}

/**
 * 自定义提醒项
 */
export interface CustomReminderItem {
  id: string;
  name: string;
  content: string;
  intervalMinutes: number;
  enabled: boolean;
  startHour: number;
  startMinute: number;
  endHour: number;
  endMinute: number;
  weekdays: number[];
  notificationId: number;
}

/**
 * 星期数组的防御性拷贝；空/缺失时回退为「每天」。
 *
 * 注意：判据是**长度 > 0** 而非真值——`[0]`（仅周日）长度 1，是合法配置不能被回退覆盖。
 */
function copyWeekdays(weekdays?: number[]): number[] {
  return weekdays && weekdays.length > 0 ? [...weekdays] : [...ALL_WEEKDAYS];
}

/**
 * 配置的防御性拷贝。weekdays 必复制成新数组，调用方原地改写不会污染源对象。
 */
export function copyReminderConfig(src: HealthReminderConfig): HealthReminderConfig {
  return {
    enabled: src.enabled,
    intervalMinutes: src.intervalMinutes,
    startHour: src.startHour,
    startMinute: src.startMinute,
    endHour: src.endHour,
    endMinute: src.endMinute,
    title: src.title,
    content: src.content,
    weekdays: copyWeekdays(src.weekdays)
  };
}

/**
 * 自定义提醒项的防御性拷贝。
 *
 * ⚠️ 新增字段时**必须**同步到这里：`Settings.ets` 的自定义提醒 ForEach 复合 key
 * 覆盖了本接口的全部可变字段，漏一个字段会让该字段的变化不再触发行重建。
 */
export function copyCustomReminderItem(src: CustomReminderItem): CustomReminderItem {
  return {
    id: src.id,
    name: src.name,
    content: src.content,
    intervalMinutes: src.intervalMinutes,
    enabled: src.enabled,
    startHour: src.startHour,
    startMinute: src.startMinute,
    endHour: src.endHour,
    endMinute: src.endMinute,
    weekdays: copyWeekdays(src.weekdays),
    notificationId: src.notificationId
  };
}