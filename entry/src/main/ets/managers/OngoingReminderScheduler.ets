import { formatError } from '../models/ErrUtils';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { notificationManager } from '@kit.NotificationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { SELF_APP_NAME } from '../models/HealthTypes';
import { OngoingReminderSpec, isInActiveWindow, nextActiveStartMs, dateKey, dateKeyFromDate, todayAtMs, formatRemain, formatTime, formatDateTime } from './ReminderTimeUtils';
import {
  deriveIntervalInitState,
  deriveDailyInitDateKey,
  intervalTickStep,
  dailyTickStep,
  oneShotTickStep,
  shouldPublish,
  OneShotPhase
} from '../models/ReminderScheduleMath';

const TAG = 'OngoingReminderScheduler';

/**
 * `NotificationFlagStatus.TYPE_OPEN` 的取值。
 *
 * ⚠️ 这个 enum **只能这样用**：`NotificationFlagStatus` 只声明在 SDK 的
 * `ets/api/notification/notificationFlags.d.ts` 里，`@ohos.notificationManager`
 * 与 `@kit.NotificationKit` 都**没有**再导出它（全 SDK 检索只有那一处声明），
 * 所以拿不到可 import 的公开路径，只能固化数值。
 * 数值来源同上文件：`TYPE_NONE = 0` / `TYPE_OPEN = 1` / `TYPE_CLOSE = 2`（`@since 11`，稳定契约）。
 * 若将来 SDK 调整，这里必须同步改——可用 SDK 的 `notificationFlags.d.ts` 核对。
 */
const NOTIFICATION_FLAG_OPEN = 1;

/** 状态/触发检查间隔（毫秒） */
const TICK_MS = 10000;

interface Entry {
  spec: OngoingReminderSpec;
  /** 间隔提醒：上次触发时间（毫秒）；0 = 尚未触发 */
  lastFireAt: number;
  /** 每日提醒：上次触发日期（YYYY-MM-DD），避免重复触发 */
  lastFireDateKey: string;
  /** 一次性提醒：应触发时刻（毫秒） */
  fireAt: number;
  /** 提醒文案保持显示的截止时间 */
  alertUntil: number;
  /** 暂停截止时间（毫秒）；0 = 未暂停 */
  snoozeUntil: number;
  /** 当前是否正在提醒（⏰ 状态），供 UI 读取展示 */
  isAlerting: boolean;
  lastPublishedText: string;
}

/**
 * 常驻提醒调度器
 * 所有提醒都以"常驻（ongoing）通知"的形式出现在通知栏，与"今日使用时长"通知同一方法：
 * 纯 notificationManager.publish + JS 定时器驱动，不依赖代理提醒、系统日历或特殊权限。
 * 定时器每 TICK_MS 检查一次：到点把该条通知的文案切换为提醒内容，其余时间显示下次触发时间；
 * 文案未变化时跳过发布，避免频繁调用系统通知接口。
 * 局限：进程被系统回收后定时器停止（与常驻使用时长通知一致）；应用存活期间始终可靠。
 */
/**
 * 首页“提醒暂停”卡片使用的提醒条目简况。
 */
export interface ActiveAlert {
  id: number;
  title: string;
  content: string;
}

export class OngoingReminderScheduler {
  private static instance: OngoingReminderScheduler;

  private entries: Map<number, Entry> = new Map();

  private timerId: number = -1;

  private lastError: string = '';

  static getInstance(): OngoingReminderScheduler {
    if (!OngoingReminderScheduler.instance) {
      OngoingReminderScheduler.instance = new OngoingReminderScheduler();
    }
    return OngoingReminderScheduler.instance;
  }

  isScheduled(notificationId: number): boolean {
    return this.entries.has(notificationId);
  }

  lastPublishError(): string {
    return this.lastError;
  }

  /**
   * 获取当前正在提醒（⏰ 状态）的全部条目，供首页“提醒暂停”卡片展示与操作。
   */
  getActiveAlerts(): ActiveAlert[] {
    const result: ActiveAlert[] = [];
    this.entries.forEach((entry: Entry, id: number) => {
      if (entry.isAlerting) {
        result.push({ id, title: entry.spec.title, content: entry.spec.content });
      }
    });
    return result;
  }

  /**
   * 暂停指定提醒：在 snoozeMinutes 分钟内不再触发该提醒，仅为应用内快捷操作，
   * 不涉及系统通知操作按钮（当前 API 不可用）。
   * @returns 是否成功暂停（条目存在即成功）
   */
  snooze(notificationId: number, snoozeMinutes: number): boolean {
    const entry = this.entries.get(notificationId);
    if (!entry) {
      return false;
    }
    entry.snoozeUntil = Date.now() + snoozeMinutes * 60 * 1000;
    entry.isAlerting = false;
    hilog.info(0x0000, TAG, '%{public}s', '[暂停] id=${notificationId} ${entry.spec.title} ${snoozeMinutes} 分钟');
    this.tick();
    return true;
  }

  /**
   * 取消指定提醒：移除常驻通知与条目，等同于关闭该提醒。
   * @returns 是否成功取消（条目存在即成功）
   */
  dismiss(notificationId: number): boolean {
    if (!this.entries.has(notificationId)) {
      return false;
    }
    this.unregister(notificationId);
    return true;
  }

  /**
   * 注册/更新一条常驻提醒（相同 notificationId 覆盖旧配置）。
   * 返回通知总开关是否已开启（关闭时仍注册，但无法展示；调用方应据此回滚 UI）。
   * @param fireNow 注册后立即触发一次（用户主动开启时即时确认）
   */
  register(spec: OngoingReminderSpec, fireNow: boolean = false): boolean {
    const now = Date.now();
    const existing = this.entries.get(spec.notificationId);
    const entry: Entry = {
      spec: spec,
      lastFireAt: 0,
      lastFireDateKey: '',
      fireAt: now + (spec.oneShotSeconds ?? 0) * 1000,
      alertUntil: 0,
      snoozeUntil: 0,
      isAlerting: false,
      lastPublishedText: ''
    };
    // 初始状态推导见 models/ReminderScheduleMath（纯函数，有单测锁定）：
    // 每日 / 一次性 / 间隔三条分支的判定顺序本身即语义，勿在调用方重排。
    if (spec.dailyHour !== undefined && spec.dailyMinute !== undefined) {
      // 每日提醒：目标时刻已过则视为今天已触发过（避免开机/设置时补发），否则待触发
      const target = todayAtMs(spec.dailyHour, spec.dailyMinute);
      entry.lastFireDateKey = deriveDailyInitDateKey(
        now, target, dateKey(now), dateKey(now - 86400000), existing ? existing.lastFireDateKey : '');
    } else if (spec.oneShotSeconds !== undefined) {
      // 一次性提醒：从注册时刻起倒计时（fireAt 已在上面的初始值里算好）
      entry.fireAt = now + spec.oneShotSeconds * 1000;
    } else {
      // 间隔提醒：fireNow 仅在"关闭→开启"时为 true；已有条目保留原调度锚点
      const init = deriveIntervalInitState(
        now,
        isInActiveWindow(spec, new Date(now)),
        fireNow,
        existing ? existing.lastFireAt : 0,
        existing ? existing.alertUntil : 0);
      entry.lastFireAt = init.lastFireAt;
      entry.alertUntil = init.alertUntil;
    }
    this.entries.set(spec.notificationId, entry);
    this.ensureTimer();
    hilog.info(0x0000, TAG, '%{public}s',
      `[注册] id=${spec.notificationId} ${spec.title} fireNow=${fireNow}, 常驻通知已就绪`);
    this.tick();
    try {
      return notificationManager.isNotificationEnabledSync();
    } catch (err) {
      hilog.warn(0x0000, TAG, '%{public}s', '[注册] 查询通知使能状态失败: ' + formatError(err));
      return false;
    }
  }

  /**
   * 取消指定提醒的常驻通知
   */
  unregister(notificationId: number): void {
    const entry = this.entries.get(notificationId);
    if (!entry) {
      // 内存中无该条目（如进程重启后执行「重置所有数据」）：仍需按 id 撤销，
      // 否则上一进程发布的常驻通知（isOngoing/isUnremovable）永远留在通知栏且无人更新或撤除
      this.cancelNotification(notificationId);
      return;
    }
    this.entries.delete(notificationId);
    this.cancelNotification(notificationId);
    this.stopTimerIfEmpty();
    hilog.info(0x0000, TAG, '%{public}s', `[取消] id=${notificationId} ${entry.spec.title}`);
  }

  /**
   * 确保常驻提醒定时器已启动
   */
  private ensureTimer(): void {
    if (this.timerId >= 0) {
      return;
    }
    this.timerId = setInterval(() => {
      this.tick();
    }, TICK_MS);
    hilog.info(0x0000, TAG, '%{public}s', `[定时器] 已启动，间隔=${TICK_MS}ms`);
  }

  private stopTimerIfEmpty(): void {
    if (this.entries.size === 0 && this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
      hilog.info(0x0000, TAG, '%{public}s', '[定时器] 已停止（无待提醒项）');
    }
  }

  private tick(): void {
    const now = Date.now();
    // 本 tick 的共享 Date 实例：isInActiveWindow / dateKeyFromDate 只读取不修改，
    // 且 now 对所有条目相同，因此每 tick 建一次即可。此前是每条目各建一次
    // （条目数 = 内置 3 + 睡前 + 停用 + 自定义 N，10s 一轮）。
    const nowDate = new Date(now);
    const toRemove: number[] = [];
    this.entries.forEach((entry: Entry, id: number) => {
      const spec = entry.spec;
      let text = '';
      // 暂停优先：正在暂停期内显示暂停文案，不进入正常触发逻辑
      if (entry.snoozeUntil > 0 && now < entry.snoozeUntil) {
        const mins = Math.ceil((entry.snoozeUntil - now) / 60000);
        text = `已暂停 ${mins} 分钟`;
        entry.isAlerting = false;
      } else {
        // 暂停已过期，清除标记
        entry.snoozeUntil = 0;
        if (spec.oneShotSeconds !== undefined) {
          text = this.oneShotTick(entry, spec, now);
        } else if (spec.dailyHour !== undefined && spec.dailyMinute !== undefined) {
          text = this.dailyTick(entry, spec, now, nowDate);
        } else {
          text = this.intervalTick(entry, spec, now, nowDate);
        }
        // 根据文案是否为 ⏰ 提醒更新 isAlerting 状态
        entry.isAlerting = text.startsWith('⏰');
      }
      if (text.length === 0) {
        toRemove.push(id);
        return;
      }
      this.publish(id, spec, text);
    });
    for (let i = 0; i < toRemove.length; i++) {
      this.unregister(toRemove[i]);
    }
  }

  /** 间隔提醒 tick：活跃时段内每 intervalMinutes 触发一次，非活跃时段显示下次进入时段时间 */
  private intervalTick(entry: Entry, spec: OngoingReminderSpec, now: number, nowDate: Date): string {
    const inActive = isInActiveWindow(spec, nowDate);
    // 状态推进见 models/ReminderScheduleMath.intervalTickStep（含非正间隔兜底）
    const r = intervalTickStep(entry.lastFireAt, entry.alertUntil, spec.intervalMinutes ?? 0, inActive, now);
    entry.lastFireAt = r.lastFireAt;
    entry.alertUntil = r.alertUntil;
    if (!inActive) {
      const next = nextActiveStartMs(spec, now);
      return `下次提醒：${formatDateTime(next)}`;
    }
    if (r.alerting) {
      return `⏰ ${spec.content}`;
    }
    return `下次提醒：还有 ${formatRemain(r.nextFireMs - now)}（${formatTime(r.nextFireMs)}）`;
  }

  /** 每日提醒 tick：每天目标时刻触发一次（同日去重），已过时不补发 */
  private dailyTick(entry: Entry, spec: OngoingReminderSpec, now: number, nowDate: Date): string {
    const target = todayAtMs(spec.dailyHour!, spec.dailyMinute!);
    // 状态推进见 models/ReminderScheduleMath.dailyTickStep
    const r = dailyTickStep(entry.lastFireDateKey, entry.alertUntil, target, dateKeyFromDate(nowDate), now);
    entry.lastFireDateKey = r.lastFireDateKey;
    entry.alertUntil = r.alertUntil;
    if (r.alerting) {
      return `⏰ ${spec.content}`;
    }
    return `下次提醒：${formatDateTime(r.nextFireMs)}`;
  }

  /** 一次性提醒 tick：倒计时结束后触发，展示期过后返回空串由调用方移除该提醒 */
  private oneShotTick(entry: Entry, spec: OngoingReminderSpec, now: number): string {
    // 状态推进见 models/ReminderScheduleMath.oneShotTickStep（展示期只设一次，否则永不移除）
    const r = oneShotTickStep(entry.fireAt, entry.alertUntil, now);
    entry.alertUntil = r.alertUntil;
    if (r.phase === OneShotPhase.COUNTING) {
      return `即将提醒：还有 ${formatRemain(r.remainMs)}`;
    }
    entry.lastFireAt = now;
    if (r.phase === OneShotPhase.ALERTING) {
      return `⏰ ${spec.content}`;
    }
    return '';
  }

  /** 发布/更新常驻通知：文案未变化时跳过；发布前重置错误记录 */
  private publish(id: number, spec: OngoingReminderSpec, text: string): void {
    const entry = this.entries.get(id);
    if (!entry) {
      return;
    }
    if (!shouldPublish(entry.lastPublishedText, text)) {
      return;
    }
    // 每次新发布前重置错误记录，避免上次失败消息污染后续失败提示
    this.lastError = '';
    notificationManager.publish({
      id: id,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: { title: spec.title, text: text, additionalText: SELF_APP_NAME }
      },
      isOngoing: true,
      isUnremovable: spec.unremovable,
      // 横幅：让"到点该行动了"的提醒真的能被看见。默认关闭，由 spec.banner 逐条开启。
      // 注：isOngoing 的常驻通知同样可以横幅——两者不互斥。
      notificationFlags: spec.banner === true ? {
        bannerEnabled: NOTIFICATION_FLAG_OPEN,
        soundEnabled: NOTIFICATION_FLAG_OPEN,
        vibrationEnabled: NOTIFICATION_FLAG_OPEN
      } : undefined
    }).then(() => {
      // ⚠️ 成功之后才记「已发布」。
      // 原先是在 publish() 之前就写 lastPublishedText 且失败不回滚，等于「记忆里已发布、
      // 通知栏里其实没有」，去重闸会把后续同文案的发布全部挡掉。
      // 对每日/一次性提醒是致命的：⏰ 文案在整个展示期（30s/60s）内逐字不变，
      // 那唯一一次发布一旦失败（通知被临时禁用 / IPC 抖动 / 通知数超限），这次提醒当天彻底丢失；
      // 而 NotificationRepostService 的兜底在展示期内被 isScheduled 守卫跳过，两道防线同时失效。
      // 间隔提醒因为文案含倒计时、每分钟必变，下一轮会自然补发，所以此前没暴露。
      entry.lastPublishedText = text;
    }).catch((err: Error) => {
      this.lastError = err.message;
      entry.lastPublishedText = '';
      hilog.warn(0x0000, TAG, '%{public}s', `[发布] id=${id} 失败: ${err.message}（下轮重试）`);
    });
  }

  /**
   * 取消指定常驻通知。
   *
   * 失败不能静默：这是常驻通知唯一的撤销通道，撤除失败会留下 isUnremovable 的僵尸
   * 通知——用户看到一条点不掉的横幅，而日志里没有任何线索。
   * 1600007（notification does not exist）属预期情形（进程重启后内存里已无该条目），
   * 不记日志以免每次重登都刷 error。
   */
  private cancelNotification(id: number): void {
    notificationManager.cancel(id).catch((err: Error) => {
      const bizErr = err as BusinessError;
      if (bizErr.code === 1600007) {
        return;
      }
      hilog.error(0x0000, TAG, '%{public}s',
        `[取消] id=${id} 失败: code=${bizErr.code} message=${bizErr.message}`);
    });
  }
}
