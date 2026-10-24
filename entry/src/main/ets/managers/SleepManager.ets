import { formatError } from '../models/ErrUtils';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SleepData, SleepPreferences } from '../models/HealthTypes';
import { PreferenceManager } from './PreferenceManager';
import { HealthDataService } from './HealthDataService';
import { UsageStatsManager } from './UsageStatsManager';
import { computeSleepScore, generateSleepAdvices } from '../models/SleepScoreMath';

const TAG = 'SleepManager';

interface BedtimeInfo {
  hour: number;
  minute: number;
}

const PREFS_KEY_SLEEP_DATA = 'sleep_data';
const PREFS_KEY_SLEEP_PREFS = 'sleep_preferences';
const PREFS_KEY_SLEEP_HISTORY = 'sleep_history';
/** 睡眠历史保留条数（loadHistory / saveHistory / importSleepHistory 三处共用同一口径） */
const MAX_SLEEP_HISTORY = 30;
const PRE_SLEEP_WINDOW_HOURS = 2;
const DEFAULT_SLEEP_GOAL_MINUTES = 480;
const DEFAULT_BEDTIME_OFFSET_MINUTES = 30;
const DEFAULT_ENABLE_PRE_SLEEP_RESTRICTION = false;
const DEFAULT_PRE_SLEEP_RESTRICTION_MINUTES = 60;

/** 构造默认睡眠偏好（字段初始化、键缺失/损坏回退共用，避免默认值散落多处） */
function buildDefaultPreferences(): SleepPreferences {
  return {
    sleepGoalMinutes: DEFAULT_SLEEP_GOAL_MINUTES,
    bedtimeReminderOffsetMinutes: DEFAULT_BEDTIME_OFFSET_MINUTES,
    enablePreSleepRestriction: DEFAULT_ENABLE_PRE_SLEEP_RESTRICTION,
    preSleepRestrictionMinutes: DEFAULT_PRE_SLEEP_RESTRICTION_MINUTES
  };
}
const DEFAULT_DOWNTIME_START_MINUTES = 22 * 60;

/** 华为运动健康同步的结果（四态，替代原先压成 boolean 的 true/false） */
export enum HealthSyncOutcome {
  /** 成功读到并写入睡眠数据 */
  SUCCESS,
  /** 用户未授权健康数据，或本 SDK 不支持该能力 */
  NOT_AUTHORIZED,
  /** 已授权，但没有可用的睡眠记录（当天没戴设备等） */
  NO_DATA,
  /**
   * 本设备/本次调用根本不具备该能力（未注入 Context，或系统不支持 HealthStore）。
   * 与 `NOT_AUTHORIZED` 分开：后者去系统设置里能找到开关，这个找不到。
   */
  UNAVAILABLE,
  /** 其他异常 */
  ERROR
}
const DEFAULT_WAKE_HOUR = 7;
const DEFAULT_WAKE_MINUTE = 30;

export const MIN_SLEEP_DURATION_MINUTES = 0;
export const MAX_SLEEP_DURATION_MINUTES = 720;
export const MIN_PRE_SLEEP_USAGE_MINUTES = 0;
/**
 * 睡前使用时长上限。
 *
 * ⚠️ 必须 ≥ `MAX_PRE_SLEEP_RESTRICTION_MINUTES`（统计窗口最大 180 分钟）。
 * 原值为 120：用户把「睡前统计窗口」拖到 180，某晚窗口内亮屏 150 分钟，
 * 睡前页却只显示 120 —— 设置页写的可配范围与实际能记录的上限自相矛盾，
 * 且评分按 120 封顶、再多也不会进一步扣分。
 */
export const MAX_PRE_SLEEP_USAGE_MINUTES = 180;
export const MIN_SLEEP_GOAL_MINUTES = 240;
export const MAX_SLEEP_GOAL_MINUTES = 720;
export const MIN_BEDTIME_OFFSET_MINUTES = 5;
export const MAX_BEDTIME_OFFSET_MINUTES = 120;
export const MIN_PRE_SLEEP_RESTRICTION_MINUTES = 15;
export const MAX_PRE_SLEEP_RESTRICTION_MINUTES = 180;

/**
 * 睡眠质量建议管理器
 * 结合睡眠时长、睡前使用时长、心率变异性生成入睡建议
 * 真实环境可通过华为运动健康 API（Health Sensor Framework）接入穿戴设备数据
 */
export class SleepManager {
  private static instance: SleepManager;

  static getInstance(): SleepManager {
    if (!SleepManager.instance) {
      SleepManager.instance = new SleepManager();
    }
    return SleepManager.instance;
  }

  private sleepData: SleepData = {
    sleepDurationMinutes: 0,
    preSleepUsageMinutes: 0,
    score: 0
  };

  private usageManager?: UsageStatsManager;
  private sleepHistory: SleepData[] = [];
  private preferences: SleepPreferences = buildDefaultPreferences();

  initialize(): void {
    hilog.info(0x0000, TAG, '%{public}s', '初始化睡眠管理器');
    this.sleepData = {
      sleepDurationMinutes: 0,
      preSleepUsageMinutes: 0,
      score: 0,
      deepSleepMinutes: 0,
      shallowSleepMinutes: 0,
      dreamSleepMinutes: 0
    };
    this.loadFromPreferences();
    this.loadPreferences();
    // 评分是「睡眠数据 + 当前睡眠目标」的派生值。旧版本改目标后只重算了内存分数、
    // 没有落盘 ⇒ 重启会从 prefs 读回旧分数，与新目标/建议文案自相矛盾。
    // 有数据时按当前目标重算一次，只有真的变了才落盘（避免每次启动都写 prefs）。
    if (this.hasSleepData()) {
      const previousScore: number = this.sleepData.score;
      this.calculateScore();
      if (this.sleepData.score !== previousScore) {
        this.saveToPreferences();
      }
    }
    this.loadHistory();
  }

  /** 注入使用统计管理器（用于按亮屏记录计算睡前使用时长） */
  setUsageManager(usageManager: UsageStatsManager): void {
    this.usageManager = usageManager;
  }

  /**
   * 跨日清零：新的一天重置今日睡前使用时长
   * 昨晚睡眠时长作为历史数据保留（已记入 sleepHistory），不在此清除
   */
  onDateChanged(): void {
    if (this.sleepData.preSleepUsageMinutes > 0) {
      this.updateSleepData({ preSleepUsageMinutes: 0 });
    }
  }

  /**
   * 根据亮屏记录统计睡前使用时长
   * 窗口为停用时间开始前的「睡前限制窗口」至停用时间开始：
   * 启用睡前使用限制时按 preSleepRestrictionMinutes 配置（默认 1 小时），否则保持默认 2 小时
   */
  updatePreSleepUsageFromRecords(): void {
    if (!this.usageManager) {
      return;
    }
    const bedtimeMinutes = this.getBedtimeMinutes();
    const windowMinutes = this.preferences.enablePreSleepRestriction
      ? this.preferences.preSleepRestrictionMinutes
      : PRE_SLEEP_WINDOW_HOURS * 60;
    const windowStartMinutes = (bedtimeMinutes - windowMinutes + 1440) % 1440;

    const usageSeconds = this.usageManager.getUsageSecondsInWindow(
      windowStartMinutes,
      bedtimeMinutes
    );
    const usageMinutes = Math.floor(usageSeconds / 60);

    if (usageMinutes > 0) {
      this.updateSleepData({ preSleepUsageMinutes: usageMinutes });
    }
  }

  private loadFromPreferences(): void {
    try {
      const json = PreferenceManager.getInstance().getString(PREFS_KEY_SLEEP_DATA, '');
      if (json) {
        const saved = JSON.parse(json) as SleepData;
        this.sleepData = {
          sleepDurationMinutes: saved.sleepDurationMinutes || 0,
          preSleepUsageMinutes: saved.preSleepUsageMinutes || 0,
          score: saved.score || 0,
          deepSleepMinutes: saved.deepSleepMinutes || 0,
          shallowSleepMinutes: saved.shallowSleepMinutes || 0,
          dreamSleepMinutes: saved.dreamSleepMinutes || 0
        };
      }
    } catch (err) {
      hilog.error(0x0000, TAG, '%{public}s', '读取睡眠数据失败：' + formatError(err));
    }
  }

  private saveToPreferences(): void {
    PreferenceManager.getInstance().setString(PREFS_KEY_SLEEP_DATA, JSON.stringify(this.sleepData));
  }

  /** 返回睡眠数据的副本，避免页面持有活引用导致跨日后仍渲染昨日数据 */
  getSleepData(): SleepData {
    return {
      sleepDurationMinutes: this.sleepData.sleepDurationMinutes,
      preSleepUsageMinutes: this.sleepData.preSleepUsageMinutes,
      score: this.sleepData.score,
      deepSleepMinutes: this.sleepData.deepSleepMinutes,
      shallowSleepMinutes: this.sleepData.shallowSleepMinutes,
      dreamSleepMinutes: this.sleepData.dreamSleepMinutes
    };
  }

  /**
   * 导出睡眠历史（副本）。
   *
   * 「重置所有数据」会删掉 `sleep_history`，而历史是「建议入睡」与平均睡眠时长的
   * 唯一来源——原先它不在备份范围内，用户导出后重置再导入，历史就永久丢失了。
   */
  exportSleepHistory(): SleepData[] {
    // ⚠️ 不能写成 `map(record => ({...}))`：ArkTS 禁无类型对象字面量
    // （arkts-no-untyped-obj-literals），必须先声明具体类型的局部变量。
    const copies: SleepData[] = [];
    for (const record of this.sleepHistory) {
      copies.push({
        sleepDurationMinutes: record.sleepDurationMinutes,
        preSleepUsageMinutes: record.preSleepUsageMinutes,
        score: record.score,
        deepSleepMinutes: record.deepSleepMinutes,
        shallowSleepMinutes: record.shallowSleepMinutes,
        dreamSleepMinutes: record.dreamSleepMinutes
      });
    }
    return copies;
  }

  /**
   * 导入睡眠历史。逐条过滤非法字段后按保留期截断（与 loadHistory 同一口径）。
   * 入参为空/非数组时**不清空**现有历史：备份里没这个字段属于旧版本备份，不应覆盖。
   */
  importSleepHistory(history?: SleepData[]): void {
    if (!Array.isArray(history)) {
      return;
    }
    const records: SleepData[] = [];
    for (const record of history) {
      if (!record || typeof record.sleepDurationMinutes !== 'number' || !Number.isFinite(record.sleepDurationMinutes)) {
        continue;
      }
      records.push({
        sleepDurationMinutes: record.sleepDurationMinutes,
        preSleepUsageMinutes: record.preSleepUsageMinutes || 0,
        score: record.score || 0,
        deepSleepMinutes: record.deepSleepMinutes || 0,
        shallowSleepMinutes: record.shallowSleepMinutes || 0,
        dreamSleepMinutes: record.dreamSleepMinutes || 0
      });
    }
    this.sleepHistory = records.slice(-MAX_SLEEP_HISTORY);
    this.saveHistory();
  }

  /** 返回睡眠偏好的副本，避免外部原地修改污染持久化态 */
  getSleepPreferences(): SleepPreferences {
    return {
      sleepGoalMinutes: this.preferences.sleepGoalMinutes,
      bedtimeReminderOffsetMinutes: this.preferences.bedtimeReminderOffsetMinutes,
      enablePreSleepRestriction: this.preferences.enablePreSleepRestriction,
      preSleepRestrictionMinutes: this.preferences.preSleepRestrictionMinutes
    };
  }

  /**
   * 只读取睡眠目标分钟数（标量）。
   *
   * 供睡前页高频只读场景使用：getSleepPreferences() 有意返回副本，每次调用即一个新
   * 对象，而睡前页渲染一次要取 4 次（进度 ×2 + 目标文案 ×2）。标量不存在被改写的
   * 可能，故单独开一个无分配的只读口。**不要**用它替代需要其余三个字段的场景。
   */
  getSleepGoalMinutes(): number {
    return this.preferences.sleepGoalMinutes;
  }

/**
   * 数值安全钳位。
   * 备份恢复是唯一能让外部数据进入这里的入口，而 JSON 允许把数字写成字符串
   * （如 "sleepGoalMinutes": "480"）。此时 Math.min(MAX, "480") 先做字符串→数值强转尚可，
   * 但遇到 "abc" 会得到 NaN，再经 Math.max(MIN, NaN) 仍是 NaN —— NaN 会被
   * JSON.stringify 序列化成 null 落盘，重启后 loadPreferences 把 null 直接赋给 number 字段，
   * 页面显示 "null 小时"，且该损坏值会长期驻留。
   * 因此这里显式拒绝非有限数：无效值一律回退到 fallback（调用点传当前值，即保持原状不动）。
   */
  private safeClamp(value: number, min: number, max: number, fallback: number): number {
    if (typeof value !== 'number' || !Number.isFinite(value)) {
      return fallback;
    }
    return Math.max(min, Math.min(max, value));
  }

  /** 更新睡眠偏好（各字段独立钳位到合法范围后落盘；非法值保持原值不变） */
  setSleepPreferences(prefs: Partial<SleepPreferences>): void {
    const previousGoal = this.preferences.sleepGoalMinutes;
    if (prefs.sleepGoalMinutes !== undefined) {
      this.preferences.sleepGoalMinutes = this.safeClamp(prefs.sleepGoalMinutes,
        MIN_SLEEP_GOAL_MINUTES, MAX_SLEEP_GOAL_MINUTES, this.preferences.sleepGoalMinutes);
    }
    if (prefs.bedtimeReminderOffsetMinutes !== undefined) {
      this.preferences.bedtimeReminderOffsetMinutes = this.safeClamp(prefs.bedtimeReminderOffsetMinutes,
        MIN_BEDTIME_OFFSET_MINUTES, MAX_BEDTIME_OFFSET_MINUTES, this.preferences.bedtimeReminderOffsetMinutes);
    }
    if (prefs.enablePreSleepRestriction !== undefined) {
      this.preferences.enablePreSleepRestriction = prefs.enablePreSleepRestriction;
    }
    if (prefs.preSleepRestrictionMinutes !== undefined) {
      this.preferences.preSleepRestrictionMinutes = this.safeClamp(prefs.preSleepRestrictionMinutes,
        MIN_PRE_SLEEP_RESTRICTION_MINUTES, MAX_PRE_SLEEP_RESTRICTION_MINUTES, this.preferences.preSleepRestrictionMinutes);
    }
    this.savePreferences();

    // ⚠️ 睡眠目标是**评分公式的输入**（见 calculateScore 的注释），改目标必须重算，
    // 否则睡前页会自相矛盾：评分环仍显示按旧目标算出的分数，而建议列表
    // （generateAdvice 每次实时读当前 preferences）已按新目标给出
    // 「距离你设定的 8小时目标还差约 4小时」——同一屏两个口径。
    //
    // 触发示例：睡 400 分钟，目标 4 小时 → 评分 95；把目标拖到 8 小时后
    // 正确评分应为 80，但原实现一直停在 95。
    //
    // 只在目标**真的变了**时重算：savePreferences 每次都落盘，
    // 若无条件重算则打开设置页反复保存会产生无谓的 prefs 写入。
    if (this.preferences.sleepGoalMinutes !== previousGoal) {
      this.calculateScore();
      // 必须落盘：评分是派生值，但 prefs 里存了一份快照；不写回的话重启后
      // loadFromPreferences 会读回按旧目标算的分数（见 initialize 里的重算兜底）。
      this.saveToPreferences();
    }
  }

  private loadPreferences(): void {
    try {
      const json = PreferenceManager.getInstance().getString(PREFS_KEY_SLEEP_PREFS, '');
      if (json) {
        const saved = JSON.parse(json) as SleepPreferences;
        this.preferences = {
          sleepGoalMinutes: saved.sleepGoalMinutes ?? DEFAULT_SLEEP_GOAL_MINUTES,
          bedtimeReminderOffsetMinutes: saved.bedtimeReminderOffsetMinutes ?? DEFAULT_BEDTIME_OFFSET_MINUTES,
          enablePreSleepRestriction: saved.enablePreSleepRestriction ?? DEFAULT_ENABLE_PRE_SLEEP_RESTRICTION,
          preSleepRestrictionMinutes: saved.preSleepRestrictionMinutes ?? DEFAULT_PRE_SLEEP_RESTRICTION_MINUTES
        };
      } else {
        // 键已删除（重置所有数据）：恢复默认，避免睡眠目标/睡前限制在本次会话继续沿用旧值
        this.preferences = buildDefaultPreferences();
      }
    } catch (err) {
      this.preferences = buildDefaultPreferences();
      hilog.error(0x0000, TAG, '%{public}s', '读取睡眠偏好失败：' + formatError(err));
    }
  }

  private savePreferences(): void {
    PreferenceManager.getInstance().setString(PREFS_KEY_SLEEP_PREFS, JSON.stringify(this.preferences));
  }

  private loadHistory(): void {
    try {
      const json = PreferenceManager.getInstance().getString(PREFS_KEY_SLEEP_HISTORY, '');
      if (json) {
        const records = JSON.parse(json) as SleepData[];
        if (Array.isArray(records)) {
          this.sleepHistory = records.slice(-MAX_SLEEP_HISTORY);
        } else {
          this.sleepHistory = [];
        }
      } else {
        // 键已删除（重置全部数据）：清空内存态，避免历史残留在本次会话继续生效
        this.sleepHistory = [];
      }
    } catch (err) {
      hilog.error(0x0000, TAG, '%{public}s', '读取睡眠历史失败：' + formatError(err));
    }
  }

  private saveHistory(): void {
    PreferenceManager.getInstance().setString(PREFS_KEY_SLEEP_HISTORY, JSON.stringify(this.sleepHistory.slice(-MAX_SLEEP_HISTORY)));
  }

  /**
   * 获取历史平均睡眠时长（分钟）
   */
  getAverageSleepMinutes(): number {
    if (this.sleepHistory.length === 0) {
      // 无历史时返回**用户自己的目标**，而不是 DEFAULT_SLEEP_GOAL_MINUTES（480）。
      // 原实现让新用户把目标从 8 小时改成 4 小时后，「建议入睡」仍按 8 小时算、纹丝不动，
      // 与同屏的目标文案和进度条自相矛盾（实机走查发现）。
      return this.preferences.sleepGoalMinutes;
    }
    const total = this.sleepHistory.reduce((sum, item) => sum + item.sleepDurationMinutes, 0);
    return Math.round(total / this.sleepHistory.length);
  }

  /**
   * 根据目标睡眠时长和历史作息，计算建议入睡时间
   */
  getSuggestedBedtime(): BedtimeInfo {
    const avgSleep = this.getAverageSleepMinutes();
    const goal = this.preferences.sleepGoalMinutes;
    const neededSleep = Math.max(avgSleep, goal);

    const now = new Date();
    const wakeTime = new Date(now);
    // 优先以停用时间结束时间为起床时间（用户配置），否则默认 7:30 起床
    const downtime = this.usageManager?.getDowntimeRule();
    if (downtime && downtime.enabled) {
      wakeTime.setHours(downtime.endHour, downtime.endMinute, 0, 0);
    } else {
      wakeTime.setHours(DEFAULT_WAKE_HOUR, DEFAULT_WAKE_MINUTE, 0, 0);
    }
    if (wakeTime.getTime() <= now.getTime()) {
      wakeTime.setDate(wakeTime.getDate() + 1);
    }

    const bedtime = new Date(wakeTime.getTime() - neededSleep * 60000);
    return { hour: bedtime.getHours(), minute: bedtime.getMinutes() } as BedtimeInfo;
  }

  /**
   * 睡前窗口的**终点锚点**（分钟刻度，即"该在哪一刻停止看手机"）。
   *
   * 取停用时间的开始时刻；停用时间关闭时回落到默认 22:00。
   *
   * ⚠️ 勿读成"窗口起点"——起点由调用方按窗口长度倒推：
   * `updatePreSleepUsageFromRecords` 里算 `(本方法返回值 − windowMinutes + 1440) % 1440`。
   * 窗口长度本身也是可配置的（`preSleepRestrictionMinutes` 15–180，默认 60；
   * 关闭睡前使用限制时才是 `PRE_SLEEP_WINDOW_HOURS × 60 = 120`），不是固定的 2 小时。
   */
  private getBedtimeMinutes(): number {
    if (this.usageManager) {
      const downtime = this.usageManager.getDowntimeRule();
      if (downtime.enabled) {
        return downtime.startHour * 60 + downtime.startMinute;
      }
    }
    return DEFAULT_DOWNTIME_START_MINUTES;
  }

  /**
   * 更新睡眠数据（字段独立钳位），重算评分并落盘；
   * 携带完整睡眠时长时追加历史记录（与最近一条相同则跳过，避免重复）
   */
  updateSleepData(data: Partial<SleepData>): void {
if (data.sleepDurationMinutes !== undefined) {
      this.sleepData.sleepDurationMinutes = this.safeClamp(data.sleepDurationMinutes,
        MIN_SLEEP_DURATION_MINUTES, MAX_SLEEP_DURATION_MINUTES, this.sleepData.sleepDurationMinutes);
    }
    if (data.preSleepUsageMinutes !== undefined) {
      this.sleepData.preSleepUsageMinutes = this.safeClamp(data.preSleepUsageMinutes,
        MIN_PRE_SLEEP_USAGE_MINUTES, MAX_PRE_SLEEP_USAGE_MINUTES, this.sleepData.preSleepUsageMinutes);
    }
    if (data.score !== undefined) {
      this.sleepData.score = data.score;
    }
    if (data.deepSleepMinutes !== undefined) {
      this.sleepData.deepSleepMinutes = data.deepSleepMinutes;
    }
    if (data.shallowSleepMinutes !== undefined) {
      this.sleepData.shallowSleepMinutes = data.shallowSleepMinutes;
    }
    if (data.dreamSleepMinutes !== undefined) {
      this.sleepData.dreamSleepMinutes = data.dreamSleepMinutes;
    }
    this.calculateScore();
    this.saveToPreferences();

    // 当包含完整睡眠时长时，存入历史用于趋势分析（与最近一条相同则跳过，避免重复记录）
    if (data.sleepDurationMinutes !== undefined && data.sleepDurationMinutes > 0) {
      const last = this.sleepHistory.length > 0 ? this.sleepHistory[this.sleepHistory.length - 1] : null;
      if (!last
        || last.sleepDurationMinutes !== this.sleepData.sleepDurationMinutes
        || last.preSleepUsageMinutes !== this.sleepData.preSleepUsageMinutes
        || last.score !== this.sleepData.score) {
        this.sleepHistory.push({
          sleepDurationMinutes: this.sleepData.sleepDurationMinutes,
          preSleepUsageMinutes: this.sleepData.preSleepUsageMinutes,
          score: this.sleepData.score,
          deepSleepMinutes: this.sleepData.deepSleepMinutes,
          shallowSleepMinutes: this.sleepData.shallowSleepMinutes,
          dreamSleepMinutes: this.sleepData.dreamSleepMinutes
        });
        this.saveHistory();
      }
    }
  }

  /** 依据睡眠时长与睡前使用时长扣分制计算睡眠质量评分（0~100） */
  private calculateScore(): void {
    // 纯计算已抽至 models/SleepScoreMath（可单测），此处仅传参。
    // 必须传入用户设置的睡眠目标：否则目标设成 4 小时时，睡 5 小时会同时出现
    // 「进度 100% 达标」与「评分 80 需要注意」两种互相矛盾的结论。
    this.sleepData.score = computeSleepScore(
      this.sleepData.sleepDurationMinutes,
      this.sleepData.preSleepUsageMinutes,
      this.preferences.sleepGoalMinutes);
  }

  /** 生成入睡建议文案（无问题时返回正向鼓励语） */
  generateAdvice(): string[] {
    // 纯计算已抽至 models/SleepScoreMath（可单测），此处仅传参
    return generateSleepAdvices(
      this.sleepData.sleepDurationMinutes,
      this.sleepData.preSleepUsageMinutes,
      this.sleepData.deepSleepMinutes,
      this.preferences.enablePreSleepRestriction,
      this.preferences.preSleepRestrictionMinutes,
      this.preferences.sleepGoalMinutes);
  }

  /**
   * 是否已有可用于评分的睡眠数据。
   *
   * 全新安装时 sleepDurationMinutes 与 preSleepUsageMinutes 都是 0，若直接评分会得到
   * 「0 < 360 → 扣 20 → 80 分 → 习惯良好」——一个字数据都没有却拿到正面评价（实机取证）。
   * 页面据此显示「暂无数据」而不是评分。
   */
  hasSleepData(): boolean {
    return this.sleepData.sleepDurationMinutes > 0 || this.sleepData.preSleepUsageMinutes > 0;
  }

  /**
   * 从华为运动健康服务（HealthServiceKit）读取真实睡眠数据
   * 真机运行需：登录华为账号、同意健康隐私协议、授予 READ_HEALTH_DATA 权限
   * 授权失败或无数据时保留用户手动输入数据作为兜底
   *
   * 返回**具体失败原因**而非 boolean：「未授权」与「没有睡眠记录」对用户是两种完全不同
   * 的处境，原实现把两者合并成一句「未授权或无数据」，用户既不知道该去授权、
   * 也不知道自己其实已授权只是那天没戴表。
   */
  async syncFromWearable(): Promise<HealthSyncOutcome> {
    try {
      const result = await HealthDataService.getInstance().syncHealthData();
      if (!result.authorized) {
        hilog.warn(0x0000, TAG, '%{public}s',
          result.unavailable === true ? '健康数据能力不可用' : '华为运动健康数据未授权');
        return result.unavailable === true ? HealthSyncOutcome.UNAVAILABLE : HealthSyncOutcome.NOT_AUTHORIZED;
      }
      if (!result.sleep) {
        hilog.info(0x0000, TAG, '%{public}s', '未从华为运动健康读取到有效睡眠数据');
        return HealthSyncOutcome.NO_DATA;
      }

      this.updateSleepData({
        sleepDurationMinutes: result.sleep.durationMinutes,
        score: result.sleep.score,
        deepSleepMinutes: result.sleep.deepSleepMinutes,
        shallowSleepMinutes: result.sleep.shallowSleepMinutes,
        dreamSleepMinutes: result.sleep.dreamSleepMinutes
      });
      hilog.info(0x0000, TAG, '%{public}s', '已从华为运动健康同步睡眠数据');
      return HealthSyncOutcome.SUCCESS;
    } catch (err) {
      hilog.error(0x0000, TAG, '%{public}s', '同步华为运动健康数据失败：' + formatError(err));
      return HealthSyncOutcome.ERROR;
    }
  }

  /**
   * 从用户输入同步数据（真实数据来源：用户手动记录）
   */
  syncFromInput(sleepDurationMinutes: number, preSleepUsageMinutes: number): void {
    this.updateSleepData({
      sleepDurationMinutes: Math.max(MIN_SLEEP_DURATION_MINUTES, Math.min(MAX_SLEEP_DURATION_MINUTES, sleepDurationMinutes)),
      preSleepUsageMinutes: Math.max(MIN_PRE_SLEEP_USAGE_MINUTES, Math.min(MAX_PRE_SLEEP_USAGE_MINUTES, preSleepUsageMinutes))
    });
  }
}
