import { formatError } from '../models/ErrUtils';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PreferenceManager } from './PreferenceManager';
import { NotificationType } from './NotificationRepostService';
import { OngoingReminderScheduler } from './OngoingReminderScheduler';
import { OngoingReminderSpec } from './ReminderTimeUtils';
import { ALL_WEEKDAYS } from '../models/HealthTypes';
import {
  MIN_INTERVAL_MINUTES,
  DEFAULT_START_HOUR,
  DEFAULT_START_MINUTE,
  DEFAULT_END_HOUR,
  DEFAULT_END_MINUTE,
  normalizeReminderFields,
  resolveCustomNotificationId
} from '../models/ReminderConfigMath';
import {
  HealthReminderConfig,
  CustomReminderItem,
  copyReminderConfig,
  copyCustomReminderItem
} from '../models/ReminderItemTypes';

const TAG = 'HealthReminderManager';
const CUSTOM_REMINDERS_PREFS_KEY = 'custom_health_reminders';

export interface ReminderBackupData {
  sedentary: HealthReminderConfig;
  eye: HealthReminderConfig;
  water: HealthReminderConfig;
  customItems: CustomReminderItem[];
}

interface ReminderInfo {
  key: string;
  config: HealthReminderConfig;
  prefsKey: string;
  title: string;
  content: string;
  notificationType: NotificationType;
  defaultIntervalMinutes: number;
}


function createDefaultConfig(intervalMinutes: number): HealthReminderConfig {
  return { enabled: false, intervalMinutes: intervalMinutes, startHour: DEFAULT_START_HOUR, startMinute: DEFAULT_START_MINUTE, endHour: DEFAULT_END_HOUR, endMinute: DEFAULT_END_MINUTE, weekdays: [...ALL_WEEKDAYS] };
}

const DEFAULT_SEDENTARY: HealthReminderConfig = createDefaultConfig(45);
const DEFAULT_EYE: HealthReminderConfig = createDefaultConfig(20);
const DEFAULT_WATER: HealthReminderConfig = createDefaultConfig(60);

/**
 * 规范化提醒配置：钳位间隔与起止时刻。
 * 调度器 intervalTick 依赖 intervalMinutes > 0 才会触发，非法值会造成通知每轮
 * tick 都被改写并重发（文案含 HH:MM 永不重复），故所有写入口都需经过此函数。
 * 数值钳位规则见 models/ReminderConfigMath.normalizeReminderFields（有单测锁定）。
 */
function normalizeConfig(src: HealthReminderConfig, fallbackIntervalMinutes: number = MIN_INTERVAL_MINUTES): HealthReminderConfig {
  const f = normalizeReminderFields(
    src.intervalMinutes, src.startHour, src.startMinute, src.endHour, src.endMinute,
    src.weekdays ?? [], fallbackIntervalMinutes);
  return {
    enabled: src.enabled === true,
    intervalMinutes: f.intervalMinutes,
    startHour: f.startHour,
    startMinute: f.startMinute,
    endHour: f.endHour,
    endMinute: f.endMinute,
    title: src.title,
    content: src.content,
    weekdays: f.weekdays
  };
}

/** 自定义提醒的间隔/时刻同样需要钳位（与内置提醒共用调度引擎），且**原地修改**入参 */
function normalizeCustomItem(item: CustomReminderItem, fallbackIntervalMinutes: number = MIN_INTERVAL_MINUTES): void {
  const f = normalizeReminderFields(
    item.intervalMinutes, item.startHour, item.startMinute, item.endHour, item.endMinute,
    item.weekdays ?? [], fallbackIntervalMinutes);
  item.intervalMinutes = f.intervalMinutes;
  item.startHour = f.startHour;
  item.startMinute = f.startMinute;
  item.endHour = f.endHour;
  item.endMinute = f.endMinute;
  item.weekdays = f.weekdays;
}

/**
 * 健康提醒管理器
 * - 久坐提醒：每隔一定时间提醒用户起身活动
 * - 用眼提醒：20-20-20法则提醒
 * - 喝水提醒：定时提醒喝水
 * - 自定义提醒：用户自建的任意提醒项
 */
export class HealthReminderManager {
  private static instance: HealthReminderManager;

  private reminders: ReminderInfo[] = [];

  private customItems: CustomReminderItem[] = [];

  private initialized: boolean = false;

  private initPromise: Promise<void> | null = null;

  static getInstance(): HealthReminderManager {
    if (!HealthReminderManager.instance) {
      HealthReminderManager.instance = new HealthReminderManager();
    }
    return HealthReminderManager.instance;
  }

  /** 初始化（幂等，并发调用共享同一次初始化 Promise；失败后允许重试） */
  async initialize(): Promise<void> {
    if (this.initialized) {
      return;
    }
    if (!this.initPromise) {
      this.initPromise = this.doInitialize().catch((err: Error) => {
        hilog.error(0x0000, TAG, '%{public}s', '初始化失败，下次调用将重试: ' + formatError(err));
        this.initPromise = null;
        throw err;
      });
    }
    await this.initPromise;
  }

  /** 最近一次常驻通知发布失败的错误信息（供设置页回滚提示） */
  getLastPublishError(): string {
    return OngoingReminderScheduler.getInstance().lastPublishError();
  }

  /** 实际初始化流程：内置提醒 + 自定义项加载、注册重发回调、按配置幂等注册常驻提醒 */
  private async doInitialize(): Promise<void> {
    this.reminders = [
      this.createReminderInfo('sedentary', 'sedentary_reminder', '久坐提醒',
        '您已连续使用手机较长时间，建议起身活动一下，伸展身体。', NotificationType.SEDENTARY,
        false, 45, 9, 0, 21, 0),
      this.createReminderInfo('eye', 'eye_reminder', '用眼提醒',
        '请遵循20-20-20法则：每使用20分钟，看向20英尺（约6米）外的物体，持续20秒，让眼睛得到放松。', NotificationType.EYE,
        false, 20, 9, 0, 21, 0),
      this.createReminderInfo('water', 'water_reminder', '喝水提醒',
        '记得补充水分！建议每天饮水1500-2000毫升，保持身体健康。', NotificationType.WATER,
        false, 60, 9, 0, 21, 0)
    ];

    this.loadFromPreferences();
    this.loadCustomItems();
    this.initialized = true;
    this.initPromise = null;

    // ⚠️ 这里刻意**不**为内置/自定义提醒注册 NotificationRepostService 重发回调。
    // 常驻提醒由 OngoingReminderScheduler 每 10s 持续更新文案，且标记 isUnremovable，
    // 而重发回调体本身只会返回 isScheduled(...)，与 NotificationRepostService 的守卫同源：
    //   - 提醒启用中 → entries 里有它 → 守卫 `isScheduled(id)` 命中，回调根本不会被调用；
    //   - 提醒关闭   → 回调被调用，但第一行 `!config.enabled` 直接返回 false。
    // 即无论如何都不可能真正重发一条通知。保留它只是让 registeredCallbacks 永远非空，
    // 把轮询的懒启动/停摆语义搅浑（历史遗留的空转回调）。

    // 常驻通知模式：按当前配置幂等注册。常驻通知由 JS 定时器驱动，
    // 进程存活时即持续生效；触发时刻由调度引擎计算，无需系统级托管。
    for (let i = 0; i < this.reminders.length; i++) {
      const info = this.reminders[i];
      if (info.config.enabled) {
        this.registerBuiltin(info.key, false);
      }
    }
    for (let i = 0; i < this.customItems.length; i++) {
      if (this.customItems[i].enabled) {
        this.registerCustom(this.customItems[i]);
      }
    }
  }

  /** 构造一条内置提醒的注册信息（默认配置） */
  private createReminderInfo(
    key: string, prefsKey: string, title: string, content: string,
    notificationType: NotificationType,
    enabled: boolean, intervalMinutes: number,
    startHour: number, startMinute: number, endHour: number, endMinute: number
  ): ReminderInfo {
    return {
      key: key,
      config: {
        enabled: enabled,
        intervalMinutes: intervalMinutes,
        startHour: startHour,
        startMinute: startMinute,
        endHour: endHour,
        endMinute: endMinute,
        weekdays: [...ALL_WEEKDAYS]
      },
      prefsKey: prefsKey,
      title: title,
      content: content,
      notificationType: notificationType,
      defaultIntervalMinutes: intervalMinutes
    };
  }

  private loadFromPreferences(): void {
    const pref = PreferenceManager.getInstance();
    for (let i = 0; i < this.reminders.length; i++) {
      const info = this.reminders[i];
      const json = pref.getString(info.prefsKey, '');
      if (json) {
        try {
const parsed = JSON.parse(json) as HealthReminderConfig;
          // 读盘同样钳位：旧版本或异常写入的非法值不得进入调度引擎。
          // 必须带各自的默认间隔：缺字段时若回退成 MIN_INTERVAL_MINUTES(1)，会变成每分钟一条横幅。
          info.config = normalizeConfig(parsed, info.defaultIntervalMinutes);
        } catch (err) {
          hilog.error(0x0000, TAG, '%{public}s', `解析${info.title}配置失败`);
        }
      }
    }
  }

  private loadCustomItems(): void {
    const json = PreferenceManager.getInstance().getString(CUSTOM_REMINDERS_PREFS_KEY, '');
    if (!json) {
      return;
    }
    try {
      const parsed = JSON.parse(json) as CustomReminderItem[];
      if (!Array.isArray(parsed)) {
        return;
      }
      this.customItems = [];
      let maxNotificationId = NotificationType.CUSTOM_BASE - 1;
      for (let i = 0; i < parsed.length; i++) {
        const p = parsed[i];
        if (!p || !p.id) {
          continue;
        }
// notificationId 归一：与 importData 共用同一条规则（见 models/ReminderConfigMath
        // resolveCustomNotificationId）。原先两条路径规则不同（这里只判 >= CUSTOM_BASE，
        // importData 判"严格大于已见最大值"），导致重复 id 会让两条提醒共用一个通知 id：
        // 横幅只能显示最后一条、registerCallback 互相覆盖、删除只能撤掉其中一条。
        const resolved = resolveCustomNotificationId(p.notificationId, NotificationType.CUSTOM_BASE, maxNotificationId);
        const notificationId = resolved[0];
        maxNotificationId = resolved[1];
        this.customItems.push({
          id: p.id,
          name: p.name || '自定义提醒',
          content: p.content || '',
          intervalMinutes: p.intervalMinutes > 0 ? p.intervalMinutes : 60,
          enabled: !!p.enabled,
          startHour: typeof p.startHour === 'number' ? p.startHour : 9,
          startMinute: typeof p.startMinute === 'number' ? p.startMinute : 0,
          endHour: typeof p.endHour === 'number' ? p.endHour : 21,
          endMinute: typeof p.endMinute === 'number' ? p.endMinute : 0,
          weekdays: Array.isArray(p.weekdays) && p.weekdays.length > 0 ? p.weekdays : [...ALL_WEEKDAYS],
          notificationId: notificationId
        });
        normalizeCustomItem(this.customItems[this.customItems.length - 1]);
      }
    } catch (err) {
      hilog.error(0x0000, TAG, '%{public}s', '解析自定义提醒配置失败');
    }
  }

  private getInfoByKey(key: string): ReminderInfo | undefined {
    for (let i = 0; i < this.reminders.length; i++) {
      if (this.reminders[i].key === key) {
        return this.reminders[i];
      }
    }
    return undefined;
  }

  private getCustomItemInternal(id: string): CustomReminderItem | undefined {
    for (let i = 0; i < this.customItems.length; i++) {
      if (this.customItems[i].id === id) {
        return this.customItems[i];
      }
    }
    return undefined;
  }

  private getEffectiveTitle(info: ReminderInfo): string {
    const custom = info.config.title;
    if (custom && custom.trim().length > 0) {
      return custom;
    }
    return info.title;
  }

  private getEffectiveContent(info: ReminderInfo): string {
    const custom = info.config.content;
    if (custom && custom.trim().length > 0) {
      return custom;
    }
    return info.content;
  }

private getWeekdays(config: HealthReminderConfig): number[] {
    // 返回拷贝而非 config.weekdays 本体：该结果会被塞进交给调度器的 spec，
    // 与 getDowntimeRule / copyReminderConfig 保持同一防御口径，避免跨模块原地改写配置
    return config.weekdays && config.weekdays.length > 0 ? [...config.weekdays] : [...ALL_WEEKDAYS];
  }

  /**
   * 取内置提醒（久坐/用眼/喝水）的配置副本，三者同形：
   * 优先取已注册的配置，取不到（未初始化/键缺失）则回退到该类型的默认常量。
   * 返回的必然是 `copyReminderConfig` 的结果，外部原地改写不会污染 manager 内部态。
   */
  private getBuiltinConfig(key: string, fallback: HealthReminderConfig): HealthReminderConfig {
    const info = this.getInfoByKey(key);
    return copyReminderConfig(info ? info.config : fallback);
  }

  getSedentaryConfig(): HealthReminderConfig {
    return this.getBuiltinConfig('sedentary', DEFAULT_SEDENTARY);
  }

  getEyeConfig(): HealthReminderConfig {
    return this.getBuiltinConfig('eye', DEFAULT_EYE);
  }

  getWaterConfig(): HealthReminderConfig {
    return this.getBuiltinConfig('water', DEFAULT_WATER);
  }

  async setSedentaryConfig(config: HealthReminderConfig): Promise<boolean> {
    return await this.setReminderConfig('sedentary', config);
  }

  async setEyeConfig(config: HealthReminderConfig): Promise<boolean> {
    return await this.setReminderConfig('eye', config);
  }

  async setWaterConfig(config: HealthReminderConfig): Promise<boolean> {
    return await this.setReminderConfig('water', config);
  }

  /**
   * 保存提醒配置。返回是否发布成功；关闭状态下恒为 true，开启状态下仅当提醒发布成功时为 true。
   */
  private async setReminderConfig(key: string, config: HealthReminderConfig): Promise<boolean> {
    let info = this.getInfoByKey(key);
    if (!info) {
      // 设置发生在 initialize() 之前（如启动竞态）：先完成初始化再重试
      await this.initialize();
      info = this.getInfoByKey(key);
      if (!info) {
        return false;
      }
    }
    const wasEnabled = info.config.enabled;
    // 经 normalizeConfig 钳位后再落盘与调度，避免非法间隔/时刻污染持久化态与调度引擎。
    // 同样要带 defaultIntervalMinutes，否则缺失字段会被钳成 1 分钟。
    info.config = normalizeConfig(config, info.defaultIntervalMinutes);

    await PreferenceManager.getInstance().setString(info.prefsKey, JSON.stringify(info.config));

    // 判断依据必须是**钳位后**的 info.config.enabled，而非入参 config.enabled：
    // normalizeConfig 用 `src.enabled === true` 归一（把 1/"true" 等真值一律收敛为 false），
    // 若这里仍读入参，传 1 会"落盘关闭、内存关闭、却已注册常驻通知"——
    // 用户看到开关是关的却仍有提醒，且进程重启后通知又凭空消失。
    if (info.config.enabled) {
      // 仅在“关闭→开启”切换时即时触发一次（直观确认已生效）；
      // 其余配置修改（间隔/时段/星期/标题/内容）保持既有触发节奏，不额外触发、不重置倒计时
      return await this.startReminder(key, !wasEnabled);
    }
    // 关闭：取消该条的常驻通知
    OngoingReminderScheduler.getInstance().unregister(info.notificationType);
    return true;
  }

  private async startReminder(key: string, fireFirstImmediately: boolean = false): Promise<boolean> {
    const info = this.getInfoByKey(key);
    if (!info) {
      return false;
    }
    const spec = this.buildIntervalSpec(
      this.getEffectiveTitle(info), this.getEffectiveContent(info),
      info.config, info.notificationType);
    const ok = OngoingReminderScheduler.getInstance().register(spec, fireFirstImmediately);
    if (ok) {
      hilog.info(0x0000, TAG, '%{public}s', `已注册${info.title}常驻提醒，通知Id=${info.notificationType}`);
    }
    return ok;
  }

  /**
   * 由内置提醒配置生成常驻间隔提醒的调度规格
   */
  private buildIntervalSpec(title: string, content: string, config: HealthReminderConfig, notificationId: number): OngoingReminderSpec {
    return {
      notificationId: notificationId,
      title: title,
      content: content,
      unremovable: true,
      banner: true,
      intervalMinutes: config.intervalMinutes,
      startHour: config.startHour,
      startMinute: config.startMinute,
      endHour: config.endHour,
      endMinute: config.endMinute,
      weekdays: this.getWeekdays(config)
    };
  }

  private registerBuiltin(key: string, fireNow: boolean): void {
    const info = this.getInfoByKey(key);
    if (!info) {
      return;
    }
    OngoingReminderScheduler.getInstance().register(this.buildIntervalSpec(
      this.getEffectiveTitle(info), this.getEffectiveContent(info), info.config, info.notificationType), fireNow);
  }

  // ==================== 自定义提醒 ====================

  getCustomItems(): CustomReminderItem[] {
    return this.customItems.map((item: CustomReminderItem) => copyCustomReminderItem(item));
  }

  getCustomItem(id: string): CustomReminderItem | undefined {
    const item = this.getCustomItemInternal(id);
    return item ? copyCustomReminderItem(item) : undefined;
  }

  async addCustomItem(name: string): Promise<CustomReminderItem | null> {
    let maxNotificationId = NotificationType.CUSTOM_BASE - 1;
    for (let i = 0; i < this.customItems.length; i++) {
      if (this.customItems[i].notificationId > maxNotificationId) {
        maxNotificationId = this.customItems[i].notificationId;
      }
    }
    const item: CustomReminderItem = {
      id: 'custom_' + Date.now(),
      name: name && name.trim().length > 0 ? name.trim() : '自定义提醒',
      content: '该休息一下，起身活动活动吧。',
      intervalMinutes: 60,
      enabled: false,
startHour: DEFAULT_START_HOUR,
      startMinute: DEFAULT_START_MINUTE,
      endHour: DEFAULT_END_HOUR,
      endMinute: DEFAULT_END_MINUTE,
      weekdays: [...ALL_WEEKDAYS],
      notificationId: maxNotificationId + 1
    };
    this.customItems.push(item);
    await this.persistCustomItems();
    return copyCustomReminderItem(item);
  }

  /**
   * 更新并持久化一条自定义提醒。
   * 返回 false 表示项不存在或重新注册/发布失败，调用方应回滚 UI 并提示失败。
   */
  async updateCustomItem(item: CustomReminderItem): Promise<boolean> {
    const existing = this.getCustomItemInternal(item.id);
    if (!existing) {
      return false;
    }
    const wasEnabled = existing.enabled;
    existing.name = item.name;
    existing.content = item.content;
    existing.intervalMinutes = item.intervalMinutes;
    existing.enabled = item.enabled;
    existing.startHour = item.startHour;
    existing.startMinute = item.startMinute;
    existing.endHour = item.endHour;
    existing.endMinute = item.endMinute;
    existing.weekdays = item.weekdays && item.weekdays.length > 0 ? [...item.weekdays] : [...ALL_WEEKDAYS];
    normalizeCustomItem(existing);
    await this.persistCustomItems();
    return this.rescheduleCustomItem(existing, wasEnabled);
  }

  async removeCustomItem(id: string): Promise<void> {
    const idx = this.customItems.findIndex((item: CustomReminderItem) => item.id === id);
    if (idx < 0) {
      return;
    }
    const item = this.customItems[idx];
    OngoingReminderScheduler.getInstance().unregister(item.notificationId);
    this.customItems.splice(idx, 1);
    await this.persistCustomItems();
  }

  async resetCustomItems(): Promise<void> {
    for (let i = 0; i < this.customItems.length; i++) {
      OngoingReminderScheduler.getInstance().unregister(this.customItems[i].notificationId);
    }
    this.customItems = [];
    await PreferenceManager.getInstance().delete(CUSTOM_REMINDERS_PREFS_KEY);
  }

  private async persistCustomItems(): Promise<void> {
    await PreferenceManager.getInstance().setString(CUSTOM_REMINDERS_PREFS_KEY, JSON.stringify(this.customItems));
  }

private registerCustom(item: CustomReminderItem, fireNow: boolean = false): boolean {
    return OngoingReminderScheduler.getInstance().register({
      notificationId: item.notificationId,
      title: item.name,
      content: item.content,
      unremovable: true,
      banner: true,
      intervalMinutes: item.intervalMinutes,
      startHour: item.startHour,
      startMinute: item.startMinute,
      endHour: item.endHour,
      endMinute: item.endMinute,
      weekdays: item.weekdays && item.weekdays.length > 0 ? item.weekdays : [...ALL_WEEKDAYS]
    }, fireNow);
  }

  /**
   * 重排单条自定义提醒；返回 false 表示重新注册/发布失败（如通知总开关关闭），
   * 调用方需据此回滚 UI，避免出现"开关已开但提醒未生效"的悬挂态。
   */
  private async rescheduleCustomItem(item: CustomReminderItem, wasEnabled: boolean = false): Promise<boolean> {
    if (item.enabled) {
      // 仅在“关闭→开启”切换时即时触发一次；其余编辑保持既有触发节奏
      return this.registerCustom(item, !wasEnabled);
    }
    OngoingReminderScheduler.getInstance().unregister(item.notificationId);
    return true;
  }

  /**
   * 重置全部健康提醒：注销内置/自定义提醒的常驻通知，并将内置提醒配置恢复默认。
   * 用于"重置全部数据"场景（调用前需先删除对应偏好键，保证与重新启动后的默认状态一致）。
   */
  async resetAll(): Promise<void> {
    for (let i = 0; i < this.reminders.length; i++) {
      const info = this.reminders[i];
      OngoingReminderScheduler.getInstance().unregister(info.notificationType);
      info.config = createDefaultConfig(info.defaultIntervalMinutes);
    }
    await this.resetCustomItems();
  }

  /**
   * 导出全部健康提醒配置（用于备份）
   */
  exportData(): ReminderBackupData {
    return {
      sedentary: this.getSedentaryConfig(),
      eye: this.getEyeConfig(),
      water: this.getWaterConfig(),
      customItems: this.getCustomItems()
    };
  }

  /**
   * 导入全部健康提醒配置（备份恢复），并按恢复后的配置重新注册常驻提醒
   */
  async importData(data: ReminderBackupData): Promise<void> {
    await this.initialize();

    const applyConfig = (key: string, config?: HealthReminderConfig): void => {
      const info = this.getInfoByKey(key);
      if (!info) {
        return;
      }
      // 备份文件由用户在文件选择器中指定，可能被手工改写或由旧版本写出，字段可能缺失/越界。
      // 与 setReminderConfig 写入口走同一套 normalizeConfig 钳位，否则非法时刻（如 startHour=99）
      // 会被调度器当成「跨午夜窗口」，使提醒在几乎全天误触发。
      const raw = config ? copyReminderConfig(config) : createDefaultConfig(info.defaultIntervalMinutes);
      const normalized = normalizeConfig(raw);
      const hasValidInterval = typeof raw.intervalMinutes === 'number'
        && Number.isFinite(raw.intervalMinutes) && raw.intervalMinutes > 0;
      if (!hasValidInterval) {
        normalized.intervalMinutes = info.defaultIntervalMinutes;
      }
      info.config = normalized;
    };
    applyConfig('sedentary', data?.sedentary);
    applyConfig('eye', data?.eye);
    applyConfig('water', data?.water);

    const pref = PreferenceManager.getInstance();
    for (let i = 0; i < this.reminders.length; i++) {
      await pref.setString(this.reminders[i].prefsKey, JSON.stringify(this.reminders[i].config));
    }

    // 替换自定义提醒整组：先注销旧的常驻通知与回调，再写入新组
    for (let i = 0; i < this.customItems.length; i++) {
      OngoingReminderScheduler.getInstance().unregister(this.customItems[i].notificationId);
    }

    const items: CustomReminderItem[] = [];
    let maxNotificationId = NotificationType.CUSTOM_BASE - 1;
    if (data && Array.isArray(data.customItems)) {
      for (let i = 0; i < data.customItems.length; i++) {
        const p = data.customItems[i];
        if (!p || !p.id) {
          continue;
        }
        const copy = copyCustomReminderItem(p);
        normalizeCustomItem(copy);
        const resolved = resolveCustomNotificationId(copy.notificationId, NotificationType.CUSTOM_BASE, maxNotificationId);
        copy.notificationId = resolved[0];
        maxNotificationId = resolved[1];
        items.push(copy);
      }
    }
    this.customItems = items;
    await this.persistCustomItems();

    // 按恢复后的配置重新注册常驻提醒
    for (let i = 0; i < this.reminders.length; i++) {
      const info = this.reminders[i];
      OngoingReminderScheduler.getInstance().unregister(info.notificationType);
      if (info.config.enabled) {
        this.registerBuiltin(info.key, false);
      }
    }
    for (let i = 0; i < this.customItems.length; i++) {
      const item = this.customItems[i];
      if (item.enabled) {
        this.registerCustom(item, false);
      }
    }
  }
}
