/**
 * 每日自律打卡管理器
 * 基于微习惯理论，使用心理学引导设计
 */
import { formatError } from '../models/ErrUtils';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PreferenceManager, PreferenceEntry } from './PreferenceManager';
import { UsageStatsManager } from './UsageStatsManager';
import { FocusModeManager } from './FocusModeManager';
import { getDayStartTimestamp, formatDate, getTodayDateString, isYesterdayDateKey, MAX_STREAK_LOOKBACK_DAYS } from '../models/HealthTypes';

const TAG = 'DailyGoalManager';
const PREFS_KEY_DAILY_GOALS = 'daily_goals';
const PREFS_KEY_CHECKIN_HISTORY = 'checkin_history';
const PREFS_KEY_GOALS_DATE = 'daily_goals_date';
/** 昨日自定义目标快照：跨日重置前保存，供「复制昨日」恢复使用 */
const PREFS_KEY_YESTERDAY_CUSTOM_GOALS = 'custom_goals_yesterday';

/** 昨日自定义目标快照（不含完成状态，次日恢复时从 0 重新开始） */
interface YesterdaySnapshot {
  goalDate: string;
  goals: CustomGoalDef[];
}

/** 自定义目标定义（用于昨日快照与模板，不含 id/完成态） */
export interface CustomGoalDef {
  name: string;
  description: string;
  target: number;
  unit: string;
}

/** 常用目标模板预设 */
const GOAL_TEMPLATES: CustomGoalDef[] = [
  { name: '喝水', description: '每天喝足够的水', target: 8, unit: '杯' },
  { name: '阅读', description: '每天阅读一段时间', target: 30, unit: '分钟' },
  { name: '散步', description: '每天户外散步', target: 30, unit: '分钟' },
  { name: '冥想', description: '每天冥想放松', target: 10, unit: '分钟' },
  { name: '早起', description: '每天早起', target: 1, unit: '次' },
];
/**
 * 打卡历史保留期 90 天。
 * 与 models 的 30 天 HISTORY_RETENTION_MS 语义不同（打卡记录要长期留存以支撑连续天数），
 * 故本地保留、不共用。
 */
const CHECKIN_HISTORY_RETENTION_MS = 90 * 24 * 60 * 60 * 1000;

/** 使用控制目标的兜底分钟数（用户未配置限额时的默认值） */
const DEFAULT_USAGE_GOAL_MINUTES = 180;

/** 把分钟数格式化为目标卡描述用的中文（与首页 formatMinutes 同口径） */
function formatLimitForGoal(minutes: number): string {
  const hours = Math.floor(minutes / 60);
  const rest = minutes % 60;
  if (hours <= 0) {
    return rest + '分钟';
  }
  if (rest === 0) {
    return hours + '小时';
  }
  return hours + '小时' + rest + '分';
}

/** 今日目标计数摘要（仅本文件内部使用：外部只通过 getGoalCounts 取值，无需引用本类型） */
interface GoalCounts {
  /** 今日目标总数 */
  total: number;
  /** 其中已完成的数量 */
  completed: number;
}

export interface DailyGoal {
  id: string;
  name: string;
  description: string;
  target: number;
  current: number;
  unit: string;
  checkType: 'unlock_count' | 'focus_minutes' | 'usage_limit' | 'custom';
  completed: boolean;
  completedAt?: number;
}

export interface DailyCheckin {
  date: string;
  completedGoals: string[];
  totalGoals: number;
  streak: number;
  reflection?: string;
}

/**
 * 备份中的每日目标与打卡历史。
 *
 * 定义在此处而非 `DataBackupManager`：manager 的 `exportData()` 要用它作返回类型，
 * 放到备份类里会造成模块循环依赖。
 */
export interface DailyGoalBackupData {
  goals: DailyGoal[];
  checkins: DailyCheckin[];
  /**
   * 导出这份备份时的「今天」（`lastGoalDate`），用于恢复后跨日判据不错乱。
   *
   * ⚠️ 可选字段、`BACKUP_VERSION` 保持 1：旧备份没有它，此时恢复保持原行为（见 `importData`）。
   * 不加这个字段会导致**静默数据丢失**：跨日导入时 `checkNewDay()` 判为新的一天，
   * 把刚恢复的自定义目标进度全部清零，而内置目标由 `setupDefaultGoals` 重推导、看不出异常。
   */
  goalDate?: string;
}

export class DailyGoalManager {
  private static instance: DailyGoalManager;

  static getInstance(): DailyGoalManager {
    if (!DailyGoalManager.instance) {
      DailyGoalManager.instance = new DailyGoalManager();
    }
    return DailyGoalManager.instance;
  }

  private dailyGoals: Map<string, DailyGoal> = new Map();
  private checkinHistory: DailyCheckin[] = [];
  private currentStreak: number = 0;
  /** 上次落盘时使用控制目标的值，用于判断限额变化是否需要重存（-1 = 尚未落盘） */
  private usageTarget: number = -1;
  private lastGoalDate: string = '';

  // 缓存 updateGoalProgress 的输入值，避免每秒重复计算
  private lastUnlockCount: number = -1;
  private lastFocusMinutes: number = -1;
  private lastUsageMinutes: number = -1;

  // 鼓励性语录
  private readonly motivationalQuotes: string[] = [
    '每一次坚持，都是对自己承诺的兑现。',
    '小步快跑，比大步摔倒更接近终点。',
    '今天的努力，是明天的礼物。',
    '自律不是限制自由，而是创造更多自由。',
    '改变始于一个小小的决定。',
    '你比想象中更有力量。',
    '每一个清晨都是新的开始。',
    '微习惯，大改变。',
    '持续的行动胜过完美的计划。',
    '相信自己，你已经在路上了。'
  ];

  /**
   * 目标卡副标题文案池。
   *
   * ⚠️ 2026-10-13 重写：原语池是**破戒场景**的引导语（「失败不是终点，放弃才是。」
   * 「每一次跌倒都是为了更好地站起来。」），但它用于**任何**未全部完成的状态。
   * 实机走查发现已完成 2/3 目标的用户看到「失败不是终点」——用户明明在前进，
   * 文案却预设了"你失败了"，既冒犯也与事实矛盾。
   * 现全部改为正向/中性表述，在任意完成度下读起来都成立。
   */
  private readonly encouragingMessages: string[] = [
    '今天也在为自己的习惯加分。',
    '一点一点积累，就从此刻开始。',
    '完成任意一个目标，今天就算达标。',
    '改变需要时间，给自己一点耐心。',
    '进步的路上，偶尔停下也是前进。'
  ];

  /**
   * 内置目标的 id 全集。
   *
   * 抽成常量是因为它有两处必须保持同步的用途（`setupDefaultGoals` 建目标、
   * `importData` 排除它们）。此前后者把 `focus_session` 误写成 `focus_time`，
   * 造成"导出→导入一次，内置专注目标即可被用户删除"这一真实缺陷。
   */
  static readonly BUILTIN_GOAL_IDS: string[] = ['unlock_control', 'focus_session', 'usage_control'];

  initialize(): void {
    hilog.info(0x0000, TAG, '%{public}s', '[初始化] 每日打卡管理器');
    // 单例会被重复初始化（「重置所有数据」路径会再次调用）：先清空内存态。
    // 否则 resetAllData 只删了 prefs，这次 initialize 里的 saveToPreferences()
    // 会把"重置前"的自定义目标与打卡历史原样写回去 —— 重置等于没做。
    this.dailyGoals.clear();
    this.checkinHistory = [];
    this.currentStreak = 0;
    this.lastGoalDate = '';
    this.usageTarget = -1;
    this.lastUnlockCount = -1;
    this.lastFocusMinutes = -1;
    this.lastUsageMinutes = -1;
    this.setupDefaultGoals();
    this.loadFromPreferences();
    this.checkNewDay();
    this.updateGoalProgress();
  }

  private setupDefaultGoals(): void {
    // 基于微习惯理论，从小目标开始
    this.dailyGoals.set('unlock_control', {
      id: 'unlock_control',
      name: '解锁控制',
      description: '今日解锁少于30次',
      target: 30,
      current: 0,
      unit: '次',
      checkType: 'unlock_count',
      completed: false
    });

    this.dailyGoals.set('focus_session', {
      id: 'focus_session',
      name: '专注时光',
      description: '今日专注至少30分钟',
      target: 30,
      current: 0,
      unit: '分钟',
      checkType: 'focus_minutes',
      completed: false
    });

    this.dailyGoals.set('usage_control', {
      id: 'usage_control',
      name: '使用控制',
      description: '',
      target: this.getConfiguredDailyLimitMinutes(),
      current: 0,
      unit: '分钟',
      checkType: 'usage_limit',
      completed: false
    });
  }

  /**
   * 读取用户配置的每日总限额（分钟）。
   *
   * `UsageStatsManager` 是单例且在本 manager 之后初始化，直接 import 可能拿到未初始化的实例，
   * 故用 try/catch 包住并回退到 180 分钟（该常量的默认值）。description 在 updateGoalProgress
   * 里按真实值刷新，此处的初始描述只保证首次展示不是空的。
   */
  private getConfiguredDailyLimitMinutes(): number {
    try {
      const minutes = UsageStatsManager.getInstance().getTotalDailyLimitMinutes();
      return typeof minutes === 'number' && minutes > 0 ? minutes : DEFAULT_USAGE_GOAL_MINUTES;
    } catch (err) {
      return DEFAULT_USAGE_GOAL_MINUTES;
    }
  }

  /** 从偏好加载目标/打卡历史/日期与连续天数（loadFromPreferences 内部再重算） */
  private loadFromPreferences(): void {
    try {
      const pref = PreferenceManager.getInstance();

      const goalsJson = pref.getString(PREFS_KEY_DAILY_GOALS, '');
      if (goalsJson) {
        const saved = JSON.parse(goalsJson) as Record<string, DailyGoal>;
        const entries = Object.entries(saved);
        for (let i = 0; i < entries.length; i++) {
          const id = entries[i][0];
          const goal = entries[i][1];
          this.dailyGoals.set(id, goal);
        }
      }

      const historyJson = pref.getString(PREFS_KEY_CHECKIN_HISTORY, '');
      if (historyJson) {
        const parsed = JSON.parse(historyJson) as DailyCheckin[];
        if (Array.isArray(parsed)) {
          this.checkinHistory = parsed;
          this.cleanupOldHistory();
        }
      }

      this.lastGoalDate = pref.getString(PREFS_KEY_GOALS_DATE, '');

      this.calculateCurrentStreak();
    } catch (err) {
      hilog.error(0x0000, TAG, '%{public}s', '加载打卡数据失败：' + formatError(err));
    }
  }

  /** 落盘目标/打卡历史/日期（一次批量写入） */
  private saveToPreferences(): void {
    const goalsData: Record<string, DailyGoal> = {};
    this.dailyGoals.forEach((goal, id) => {
      goalsData[id] = goal;
    });

    const entries: PreferenceEntry[] = [
      { key: PREFS_KEY_DAILY_GOALS, value: JSON.stringify(goalsData) },
      { key: PREFS_KEY_CHECKIN_HISTORY, value: JSON.stringify(this.checkinHistory) },
      { key: PREFS_KEY_GOALS_DATE, value: this.lastGoalDate }
    ];
    // setBatch 是 async，异常转 rejected Promise，外层 try/catch 永不执行（假兜底）。
    // 写入失败的真实日志由 PreferenceManager.setBatch 内部输出。
    PreferenceManager.getInstance().setBatch(entries);
  }

  /** 检测是否为新的一天（以独立日期字段为准，首次启动/跨日才重置目标进度） */
  private checkNewDay(): void {
    const today = getTodayDateString();
    if (this.lastGoalDate === today) {
      return;
    }
    // 跨日前先保存昨日自定义目标快照，供「复制昨日」恢复使用。
    // 内置目标由 setupDefaultGoals 重新推导，无需保存。
    this.saveYesterdaySnapshot();
    // 新的一天（或首次初始化）：重置全部目标进度并记录重置日期。
    // 以独立日期字段为准，避免"今日已完成但未打卡"的目标在重启后被误清空。
    this.resetDailyGoals();
    this.lastGoalDate = today;
    this.saveToPreferences();
  }

  /**
   * 跨日清零：新的一天重置所有目标进度
   * 由 HealthStateManager 的跨日检测周期性调用
   */
  onDateChanged(): void {
    this.checkNewDay();
  }

  private resetDailyGoals(): void {
    this.dailyGoals.forEach(goal => {
      goal.current = 0;
      goal.completed = false;
      goal.completedAt = undefined;
    });
    // 先让"输入缓存"失效，否则 updateGoalProgress 会因"三项输入未变"早退，
    // 反向目标（解锁/使用控制）本该在 0 用量下重新判为完成，却停在 false。
    this.lastUnlockCount = -1;
    this.lastFocusMinutes = -1;
    this.lastUsageMinutes = -1;
    this.updateGoalProgress();
  }

  /** 保存昨日自定义目标快照（跨日重置前调用）。仅保存 custom 类型目标的定义，不含完成状态。 */
  private saveYesterdaySnapshot(): void {
    const customGoals: CustomGoalDef[] = [];
    this.dailyGoals.forEach(goal => {
      if (goal.checkType === 'custom') {
        customGoals.push({
          name: goal.name,
          description: goal.description,
          target: goal.target,
          unit: goal.unit
        });
      }
    });
    const snapshot: YesterdaySnapshot = {
      goalDate: this.lastGoalDate || getTodayDateString(),
      goals: customGoals
    };
    const entries: PreferenceEntry[] = [
      { key: PREFS_KEY_YESTERDAY_CUSTOM_GOALS, value: JSON.stringify(snapshot) }
    ];
    PreferenceManager.getInstance().setBatch(entries);
  }

  /**
   * 读取并校验「昨日自定义目标快照」。
   *
   * 快照里的 `goalDate` 是**被离开的那一天**（跨日重置前写入），因此判据恒为「等于昨天」。
   * 这个判断原先在两处各写了一份，且副本（copyYesterdayCustomGoals）误写成「等于今天」——
   * 于是「复制昨日目标」按钮亮着、点下去却永远提示「没有可用的昨日目标」。
   * 现在两处共用本方法，避免再次漂移。
   */
  private readYesterdaySnapshot(): YesterdaySnapshot | null {
    try {
      const pref = PreferenceManager.getInstance();
      const json = pref.getString(PREFS_KEY_YESTERDAY_CUSTOM_GOALS, '');
      if (!json) {
        return null;
      }
      const snapshot = JSON.parse(json) as YesterdaySnapshot;
      if (!snapshot || !isYesterdayDateKey(snapshot.goalDate, Date.now())) {
        return null;
      }
      if (!Array.isArray(snapshot.goals) || snapshot.goals.length === 0) {
        return null;
      }
      return snapshot;
    } catch (err) {
      hilog.error(0x0000, TAG, '%{public}s', '读取昨日快照失败：' + formatError(err));
      return null;
    }
  }

  /** 判断是否存在昨日自定义目标快照（日期为昨日且包含至少一个自定义目标） */
  hasYesterdaySnapshot(): boolean {
    return this.readYesterdaySnapshot() !== null;
  }

  /**
   * 复制昨日自定义目标到今日。
   * 仅当快照日期为昨日且存在自定义目标时才恢复；内置目标不复制（由 setupDefaultGoals 已存在）。
   * 返回是否成功恢复。
   */
  copyYesterdayCustomGoals(): boolean {
    const snapshot = this.readYesterdaySnapshot();
    if (snapshot === null) {
      return false;
    }
    let added = 0;
    for (const def of snapshot.goals) {
      const goal: DailyGoal = {
        id: 'custom_' + Date.now() + '_' + this.dailyGoals.size + '_' + added,
        name: typeof def.name === 'string' && def.name.length > 0 ? def.name : '自定义目标',
        description: typeof def.description === 'string' ? def.description : '',
        target: typeof def.target === 'number' && def.target > 0 ? def.target : 1,
        unit: typeof def.unit === 'string' && def.unit.length > 0 ? def.unit : '次',
        checkType: 'custom',
        current: 0,
        completed: false
      };
      this.dailyGoals.set(goal.id, goal);
      added++;
    }
    if (added > 0) {
      this.saveToPreferences();
      return true;
    }
    return false;
  }

  /** 获取所有目标模板预设 */
  getGoalTemplates(): CustomGoalDef[] {
    return [...GOAL_TEMPLATES];
  }

  /**
   * 从模板添加一个自定义目标。
   * @param templateIndex 模板在 GOAL_TEMPLATES 中的索引
   * @returns 是否成功添加
   */
  addGoalFromTemplate(templateIndex: number): boolean {
    if (templateIndex < 0 || templateIndex >= GOAL_TEMPLATES.length) {
      return false;
    }
    const def = GOAL_TEMPLATES[templateIndex];
    // 避免重复添加同名自定义目标
    const exists = Array.from(this.dailyGoals.values()).some(
      g => g.checkType === 'custom' && g.name === def.name
    );
    if (exists) {
      return false;
    }
    const goal: DailyGoal = {
      id: 'custom_' + Date.now() + '_' + this.dailyGoals.size,
      name: def.name,
      description: def.description,
      target: def.target,
      unit: def.unit,
      checkType: 'custom',
      current: 0,
      completed: false
    };
    this.dailyGoals.set(goal.id, goal);
    this.saveToPreferences();
    return true;
  }

  private cleanupOldHistory(): void {
    const cutoff = Date.now() - CHECKIN_HISTORY_RETENTION_MS;
    this.checkinHistory = this.checkinHistory.filter(entry => {
      const entryTime = getDayStartTimestamp(entry.date);
      return entryTime >= cutoff;
    });
  }

  /**
   * 更新目标进度（自动调用）
   * 仅当底层数据实际变化时重新计算，避免每秒重复调用其他 Manager
   */
  updateGoalProgress(): void {
    // 获取当前底层数据
    const unlockCount = UsageStatsManager.getInstance().getTodayUnlockCount();
    const stats = FocusModeManager.getInstance().getStats();
    const focusMinutes = stats.todayMinutes;
    const usageMinutes = UsageStatsManager.getInstance().getSelfUsageMinutes();

    // 检查是否有实际变化
    if (unlockCount === this.lastUnlockCount &&
        focusMinutes === this.lastFocusMinutes &&
        usageMinutes === this.lastUsageMinutes) {
      return; // 无变化，跳过重新计算
    }

    // 更新缓存
    this.lastUnlockCount = unlockCount;
    this.lastFocusMinutes = focusMinutes;
    this.lastUsageMinutes = usageMinutes;

    let changed = false;

    // 更新解锁控制（反向目标：解锁次数低于目标值才算完成）
    const unlockGoal = this.dailyGoals.get('unlock_control');
    if (unlockGoal) {
      const beforeCurrent = unlockGoal.current;
      const beforeCompleted = unlockGoal.completed;
      const beforeCompletedAt = unlockGoal.completedAt;
      unlockGoal.current = unlockCount;
      unlockGoal.completed = unlockGoal.current < unlockGoal.target;
      if (unlockGoal.completed && !unlockGoal.completedAt) {
        unlockGoal.completedAt = Date.now();
      }
      if (unlockGoal.current !== beforeCurrent || unlockGoal.completed !== beforeCompleted ||
        unlockGoal.completedAt !== beforeCompletedAt) {
        changed = true;
      }
    }

    // 更新专注时长
    const focusGoal = this.dailyGoals.get('focus_session');
    if (focusGoal) {
      const beforeCurrent = focusGoal.current;
      const beforeCompleted = focusGoal.completed;
      const beforeCompletedAt = focusGoal.completedAt;
      focusGoal.current = focusMinutes;
      this.checkGoalCompletion(focusGoal);
      if (focusGoal.current !== beforeCurrent || focusGoal.completed !== beforeCompleted ||
        focusGoal.completedAt !== beforeCompletedAt) {
        changed = true;
      }
    }

    // 更新使用时长
    const usageGoal = this.dailyGoals.get('usage_control');
    if (usageGoal) {
      const beforeCurrent = usageGoal.current;
      const beforeCompleted = usageGoal.completed;
      const beforeCompletedAt = usageGoal.completedAt;
      // 目标值与描述跟随用户的「每日总限额」设置，而不是写死 180。
      // 原实现下用户把限额从 3 小时调到 8 小时，GoalPage 仍写「屏幕使用不超过3小时」，
      // 而首页趋势图的限额参考线已是 8 小时 —— 同一个"今日可用时长"两个口径。
      usageGoal.target = this.getConfiguredDailyLimitMinutes();
      usageGoal.description = `屏幕使用不超过${formatLimitForGoal(this.getConfiguredDailyLimitMinutes())}`;
      usageGoal.current = usageMinutes;
      // 使用时长是反向目标：当前值低于目标值才算完成
      usageGoal.completed = usageGoal.current <= usageGoal.target;
      if (usageGoal.completed && !usageGoal.completedAt) {
        usageGoal.completedAt = Date.now();
      }
      if (usageGoal.current !== beforeCurrent || usageGoal.completed !== beforeCompleted ||
        usageGoal.completedAt !== beforeCompletedAt || usageGoal.target !== this.usageTarget) {
        this.usageTarget = usageGoal.target;
        changed = true;
      }
    }

    // 无变化时跳过落盘，减少不必要的偏好存储写入
    if (changed) {
      this.saveToPreferences();
    }
  }

  private checkGoalCompletion(goal: DailyGoal): void {
    if (goal.completed) {
      return;
    }

    // 正向目标：当前值达到或超过目标值
    goal.completed = goal.current >= goal.target;

    if (goal.completed) {
      goal.completedAt = Date.now();
    }
  }

  /**
   * 用户手动打卡
   */
  checkin(): boolean {
    this.updateGoalProgress();

    const completedGoals = Array.from(this.dailyGoals.values()).filter(g => g.completed);
    if (completedGoals.length === 0) {
      return false;
    }

    // 记录打卡
    const today = getTodayDateString();
    const existingIndex = this.checkinHistory.findIndex(c => c.date === today);

    const checkin: DailyCheckin = {
      date: today,
      completedGoals: completedGoals.map(g => g.id),
      totalGoals: this.dailyGoals.size,
      streak: 0,
      reflection: undefined
    };

    if (existingIndex >= 0) {
      this.checkinHistory[existingIndex] = checkin;
    } else {
      this.checkinHistory.push(checkin);
    }

    this.cleanupOldHistory();
    this.calculateCurrentStreak();
    // 打卡记录的 streak 以重算后的连续天数为准（与 getCurrentStreak 保持一致）
    const recordIndex = this.checkinHistory.findIndex(c => c.date === today);
    if (recordIndex >= 0) {
      this.checkinHistory[recordIndex].streak = this.currentStreak;
    }
    this.saveToPreferences();

    return true;
  }

  /**
   * 重算连续打卡天数：从今天（允许未打卡）向前连续有打卡记录的天数
   */
  private calculateCurrentStreak(): void {
    let streak = 0;
    const now = new Date();

    const checkinMap = new Map<string, DailyCheckin>();
    for (let i = 0; i < this.checkinHistory.length; i++) {
      checkinMap.set(this.checkinHistory[i].date, this.checkinHistory[i]);
    }

    for (let i = 0; i < MAX_STREAK_LOOKBACK_DAYS; i++) {
      const date = new Date(now.getTime() - i * 24 * 60 * 60 * 1000);
      const dateStr = formatDate(date);

      const entry = checkinMap.get(dateStr);
      if (entry && entry.completedGoals.length > 0) {
        streak++;
      } else if (i > 0) { // 允许今天还没打卡
        break;
      }
    }

    this.currentStreak = streak;
  }

  /**
   * 获取随机鼓励语录
   */
  getMotivationalQuote(): string {
    const index = Math.floor(Math.random() * this.motivationalQuotes.length);
    return this.motivationalQuotes[index];
  }

  /**
   * 获取心理学引导文案（破戒时）
   */
  getEncouragingMessage(): string {
    const index = Math.floor(Math.random() * this.encouragingMessages.length);
    return this.encouragingMessages[index];
  }

  /**
   * 获取所有目标
   */
  getAllGoals(): DailyGoal[] {
    return Array.from(this.dailyGoals.values());
  }

  /**
   * 获取今日目标计数摘要（总数 + 已完成数）。
   *
   * 首页 1 秒 tick 只需要这两个数字，原先走getAllGoals() 会先Array.from 复制一份
   * 数组、调用方再 .filter() 又生成一份，每秒白分配两个数组。此处单趟遍历 Map
   * 直接计数，仅分配一个结果对象。
   */
  getGoalCounts(): GoalCounts {
    let completed = 0;
    this.dailyGoals.forEach((goal: DailyGoal) => {
      if (goal.completed) {
        completed++;
      }
    });
    return { total: this.dailyGoals.size, completed: completed };
  }

  /**
   * 获取今日打卡状态
   */
  getTodayCheckin(): DailyCheckin | null {
    const today = getTodayDateString();
    return this.checkinHistory.find(c => c.date === today) || null;
  }

  /**
   * 获取连续打卡天数
   */
  getCurrentStreak(): number {
    return this.currentStreak;
  }

  /**
 * 获取打卡历史
 */
  getCheckinHistory(): DailyCheckin[] {
    return this.checkinHistory.slice();
  }

  /**
   * 导出目标与打卡历史（副本），供备份使用。
   *
   * 「重置所有数据」会删掉 `daily_goals` / `checkin_history` 两个键，而它们原先
   * 不在备份范围内——用户导出后重置再导入，全部目标与打卡记录永久丢失。
   */
  exportData(): DailyGoalBackupData {
    const goals: DailyGoal[] = [];
    this.dailyGoals.forEach((goal: DailyGoal) => {
      goals.push({
        id: goal.id,
        name: goal.name,
        description: goal.description,
        current: goal.current,
        target: goal.target,
        unit: goal.unit,
        completed: goal.completed,
        completedAt: goal.completedAt,
        checkType: goal.checkType
      });
    });
    const checkins: DailyCheckin[] = [];
    for (const entry of this.checkinHistory) {
      const copy: DailyCheckin = {
        date: entry.date,
        completedGoals: entry.completedGoals.slice(),
        totalGoals: entry.totalGoals,
        streak: entry.streak
      };
      if (entry.reflection !== undefined) {
        copy.reflection = entry.reflection;
      }
      checkins.push(copy);
    }
    return { goals: goals, checkins: checkins, goalDate: this.lastGoalDate };
  }

  /**
   * 导入目标与打卡历史。
   *
   * ⚠️ 只导入**自定义**目标：内置三个目标（解锁/专注/使用控制）由 `setupDefaultGoals`
   * 按当前统计重新推导，若把备份里的旧进度也恢复，用户会看到已过期的一致性状态。
   * 入参缺失时保持现状（旧版本备份没有这两个字段，不应因此清空）。
   */
  importData(data?: DailyGoalBackupData): void {
    if (!data) {
      return;
    }
    if (Array.isArray(data.goals)) {
      // ⚠️ 这三个 id 必须与 `setupDefaultGoals` 建的完全一致，否则内置目标会被当成
      // 自定义目标导入（checkType 硬编码为 'custom'，于是多出「完成」「✕」按钮），
      // 用户一点 ✕ 就会 `delete` 掉内置目标，导致 `updateGoalProgress` 里
      // `dailyGoals.get('focus_session')` 返回 undefined、本次会话内该目标彻底消失，
      // 要重启应用才恢复。
      // 本条曾因写成 'focus_time'（真实 id 是 'focus_session'）而失效，2026-10-13 修复。
      const builtinIds: string[] = DailyGoalManager.BUILTIN_GOAL_IDS;
      for (const goal of data.goals) {
        if (!goal || typeof goal.id !== 'string' || builtinIds.indexOf(goal.id) >= 0) {
          continue;
        }
        const restored: DailyGoal = {
          id: goal.id,
          name: typeof goal.name === 'string' && goal.name.length > 0 ? goal.name : '自定义目标',
          description: typeof goal.description === 'string' ? goal.description : '',
          current: typeof goal.current === 'number' && Number.isFinite(goal.current) ? goal.current : 0,
          target: typeof goal.target === 'number' && goal.target > 0 ? goal.target : 1,
          unit: typeof goal.unit === 'string' && goal.unit.length > 0 ? goal.unit : '次',
          completed: goal.completed === true,
          checkType: 'custom'
        };
        if (typeof goal.completedAt === 'number') {
          restored.completedAt = goal.completedAt;
        }
        this.dailyGoals.set(restored.id, restored);
      }
    }
    if (Array.isArray(data.checkins)) {
      const restored: DailyCheckin[] = [];
      for (const entry of data.checkins) {
        if (!entry || typeof entry.date !== 'string' || entry.date.length === 0) {
          continue;
        }
        restored.push({
          date: entry.date,
          completedGoals: Array.isArray(entry.completedGoals) ? entry.completedGoals.slice() : [],
          totalGoals: typeof entry.totalGoals === 'number' ? entry.totalGoals : 0,
          streak: typeof entry.streak === 'number' ? entry.streak : 0
        });
      }
      this.checkinHistory = restored;
      // 与 loadFromPreferences 同口径：按保留期裁剪（90 天），不按条数
      this.cleanupOldHistory();
      this.calculateCurrentStreak();
    }
    // ⚠️ 必须放在 saveToPreferences() 之前，且**只在备份里确实带了这个字段时**才写。
    // 恢复的备份声称自己是「哪一天」，就以它为准 —— 否则紧接着 5 秒一次的
    // checkNewDay()（HealthStateManager 聚合循环驱动）会拿当前 lastGoalDate 比对，
    // 判定为跨日并 resetDailyGoals()，把刚恢复的自定义目标进度清零。
    // 旧备份没有 goalDate ⇒ 保持原 lastGoalDate 不动（向后兼容，行为与修复前一致）。
    if (typeof data.goalDate === 'string' && data.goalDate.length > 0) {
      this.lastGoalDate = data.goalDate;
    }
    this.saveToPreferences();
  }

  /**
   * 添加自定义目标
   */
  addCustomGoal(goal: DailyGoal): void {
    this.dailyGoals.set(goal.id, goal);
    this.saveToPreferences();
  }

  /**
   * 切换自定义目标的今日完成状态（仅 custom 类型）
   * 自动追踪型目标由 updateGoalProgress 按真实统计推导，不可手动切换
   */
  toggleCustomGoalDone(id: string): boolean {
    const goal = this.dailyGoals.get(id);
    if (!goal || goal.checkType !== 'custom') {
      return false;
    }
    if (goal.completed) {
      goal.current = 0;
      goal.completed = false;
      goal.completedAt = undefined;
    } else {
      goal.current = goal.target;
      goal.completed = true;
      goal.completedAt = Date.now();
    }
    this.saveToPreferences();
    return true;
  }

  /**
   * 移除目标
   */
  removeGoal(id: string): void {
    this.dailyGoals.delete(id);
    this.saveToPreferences();
  }
}
