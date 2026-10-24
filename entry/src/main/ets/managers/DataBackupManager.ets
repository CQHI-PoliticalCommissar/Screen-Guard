import { formatError } from '../models/ErrUtils';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { picker, fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { SleepManager } from './SleepManager';
import { UsageStatsManager, UnlockBackupData, DailyUsageEntry } from './UsageStatsManager';
import { PreferenceManager, PreferenceEntry } from './PreferenceManager';
import { ReminderService } from './ReminderService';
import { HealthReminderManager, ReminderBackupData } from './HealthReminderManager';
import { HealthReminderConfig } from '../models/ReminderItemTypes';
import { DowntimeRule, SleepData, SleepPreferences } from '../models/HealthTypes';
import { BedtimeConfig } from './ReminderService';
import { AchievementManager, AchievementBackupData } from './AchievementManager';
import { DailyGoalManager, DailyGoalBackupData } from './DailyGoalManager';
import { FocusModeManager, FocusBackupData } from './FocusModeManager';
import { ThemeManager } from './ThemeManager';

const TAG = 'DataBackupManager';
const BACKUP_VERSION = 1;
/**
 * 导出文件名前缀。
 *
 * 此前是固定文件名「数字健康守护者备份.json」：用户在同一目录重复导出时，
 * 系统文件选择器会静默覆盖上一份备份，而界面仍提示"已导出"——旧快照就此丢失。
 * 现在改为 `数字健康守护者备份_YYYYMMDD_HHmmss.json`，同一分钟内重复导出才会重名。
 *
 * ⚠️ 只改文件名，不改内容与校验逻辑：导入侧 `isValidBackupData` 是纯内容校验，
 * 与文件名无关，所以历史备份（旧命名）仍可正常导入。
 */
const BACKUP_FILE_PREFIX = '数字健康守护者备份_';
const BACKUP_SUFFIX = '.json';

/** 最后备份/恢复时间偏好键 */
const PREFS_KEY_LAST_BACKUP_TIME = 'last_backup_time';
/** 已备份文件 URI 列表偏好键（用于保留期管理） */
const PREFS_KEY_BACKUP_URIS = 'backup_uris';
/** 保留的备份文件最大数量，超出时删除最旧的 */
const MAX_BACKUP_FILES = 10;

/**
 * 导入失败原因。`boolean` 返回值无法区分"用户取消"与"文件不对"，
 * 界面只能一律提示"格式不正确"，属误导性提示（2026-10-13 修复）。
 *
 * ⚠️ `FILE_NOT_FOUND` / `PERMISSION_DENIED` 是 2026-10-13 实机后追加的：
 * `fileIo` 读取所选文件时抛的是 `13900002 No such file or directory` /
 * `13900012 Permission denied` 这类**IO 错误**，原先全部落进 NONE，
 * 界面提示「导入失败，请稍后重试」——用户既不知道文件读不到、也不知道该换哪个文件，
 * 只能反复重试同一次点击。
 */
export enum ImportFailureReason {
  NONE,
  CANCELLED,
  INVALID_FILE,
  /** 所选文件无法读取：不存在 / 已删除 / 选择器返回了失效 URI */
  FILE_NOT_FOUND,
  /** 所选文件无读取权限 */
  PERMISSION_DENIED,
  /** 其他 IO 错误 */
  IO_ERROR
}

/**
 * `fileIo` 业务错误码（来源：SDK `@ohos.file.fileuri.d.ts` 的 @throws 注释）。
 * 与后台任务的 9800005 同理，只能以实际抛出的错误码为准。
 */
const FILE_ERR_NO_SUCH_FILE = 13900002;
const FILE_ERR_PERMISSION_DENIED = 13900012;

/** 按 fileIo 错误码归类；无法识别时归为 IO_ERROR（而非 NONE） */
function classifyFileError(code: number | undefined): ImportFailureReason {
  if (code === FILE_ERR_NO_SUCH_FILE) {
    return ImportFailureReason.FILE_NOT_FOUND;
  }
  if (code === FILE_ERR_PERMISSION_DENIED) {
    return ImportFailureReason.PERMISSION_DENIED;
  }
  return ImportFailureReason.IO_ERROR;
}

/** 数字补零到两位（文件名时间戳用） */
function pad2(value: number): string {
  return value.toString().padStart(2, '0');
}

/**
 * 生成带时间戳的导出文件名：`数字健康守护者备份_YYYYMMDD_HHmmss.json`。
 *
 * 时间取自本地时区（用户看到的日期/时间即文件管理器里显示的），
 * 与 `exportTime` 使用的 UTC ISO 串无关——后者是备份内容，前者只是文件名。
 *
 * @param now 生成文件名的时刻（显式传入，便于将来单测；当前调用方传 `new Date()`）
 */
function buildBackupFileName(now: Date): string {
  const datePart = `${now.getFullYear()}${pad2(now.getMonth() + 1)}${pad2(now.getDate())}`;
  const timePart = `${pad2(now.getHours())}${pad2(now.getMinutes())}${pad2(now.getSeconds())}`;
  return `${BACKUP_FILE_PREFIX}${datePart}_${timePart}${BACKUP_SUFFIX}`;
}

/** 上一次 exportData 是否为「用户主动取消」 */
let lastExportCancelled: boolean = false;
/** 上一次 exportData 是否为「真实异常失败」 */
let lastExportFailed: boolean = false;
/** 上一次 importData 的具体失败原因（取消/格式/IO） */
let lastImportReason: ImportFailureReason = ImportFailureReason.NONE;

interface BackupData {
  version: number;
  exportTime: string;
  sleepData: SleepData;
  sleepPreferences: SleepPreferences;
  /** 睡眠历史。「重置所有数据」会删 sleep_history，故必须进备份 */
  sleepHistory?: SleepData[];
  downtimeRule: DowntimeRule;
  totalDailyLimitMinutes: number;
  todayAccumulatedSeconds: number;
  dailyHistory: DailyUsageEntry[];
  bedtimeConfig: BedtimeConfig;
  focusData?: FocusBackupData;
  achievementData?: AchievementBackupData;
  unlockData?: UnlockBackupData;
  reminderData?: ReminderBackupData;
  /** 每日目标与打卡历史。「重置所有数据」会删 daily_goals / checkin_history，故必须进备份 */
  goalData?: DailyGoalBackupData;
}

/** 备份前摘要：各类数据的条目数，供导出前向用户展示 */
interface BackupSummary {
  goals: number;
  checkins: number;
  sleepHistory: number;
  focusHistory: number;
  achievements: number;
  unlockRecords: number;
  reminders: number;
}

/**
 * 数据备份与恢复管理器
 * 使用系统 DocumentViewPicker + fileIo 实现真实文件导入/导出
 */
export class DataBackupManager {
  private static instance: DataBackupManager;

  static getInstance(): DataBackupManager {
    if (!DataBackupManager.instance) {
      DataBackupManager.instance = new DataBackupManager();
    }
    return DataBackupManager.instance;
  }

  /** 上一次备份/恢复的本地时间（YYYY-MM-DD HH:mm:ss） */
  private lastBackupTime: string = '';
  /** 已备份文件 URI 列表（用于保留期管理） */
  private backupUris: string[] = [];

  /**
   * 导出应用数据到用户选择的 JSON 文件
   */
 async exportData(context: common.Context): Promise<boolean> {
    // 两个 sticky 标记必须在每次导出开始时复位：否则"先失败一次、再取消一次"会把
    // 取消误报成失败（Settings 先判 wasLastExportFailed 再判取消）。
    lastExportFailed = false;
    lastExportCancelled = false;
    try {
      const win = await window.getLastWindow(context);
      const documentPicker = new picker.DocumentViewPicker(context, win);
      const options = new picker.DocumentSaveOptions();
      // 文件名带本地时间戳，避免同一目录重复导出时系统选择器静默覆盖旧备份
      options.newFileNames = [buildBackupFileName(new Date())];
      options.fileSuffixChoices = [BACKUP_SUFFIX];

      const uris = await documentPicker.save(options);
      if (!uris || uris.length === 0) {
        hilog.info(0x0000, TAG, '%{public}s', '用户取消导出');
        lastExportCancelled = true;
        return false;
      }
      lastExportCancelled = false;

      const backup: BackupData = {
        version: BACKUP_VERSION,
        exportTime: new Date().toISOString(),
        sleepData: SleepManager.getInstance().getSleepData(),
        sleepPreferences: SleepManager.getInstance().getSleepPreferences(),
        sleepHistory: SleepManager.getInstance().exportSleepHistory(),
        downtimeRule: UsageStatsManager.getInstance().getDowntimeRule(),
        totalDailyLimitMinutes: UsageStatsManager.getInstance().getTotalDailyLimitMinutes(),
        todayAccumulatedSeconds: UsageStatsManager.getInstance().getSelfUsageSeconds(),
        dailyHistory: UsageStatsManager.getInstance().getDailyHistory(),
        bedtimeConfig: ReminderService.getInstance().getBedtimeReminderTime(),
        focusData: FocusModeManager.getInstance().exportData(),
        achievementData: AchievementManager.getInstance().exportData(),
        unlockData: UsageStatsManager.getInstance().exportUnlockData(),
        reminderData: HealthReminderManager.getInstance().exportData(),
        goalData: DailyGoalManager.getInstance().exportData()
      };

      const content = JSON.stringify(backup, null, 2);
      const file = await fileIo.open(uris[0],
        fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        await fileIo.write(file.fd, content);
      } finally {
        try {
          await fileIo.close(file);
        } catch (err) {
          hilog.warn(0x0000, TAG, '%{public}s', '关闭导出文件失败：' + formatError(err));
        }
      }

hilog.info(0x0000, TAG, '%{public}s', '数据已导出到：' + uris[0]);
      // 记录最后备份时间与备份 URI，执行保留期管理
      const now = new Date();
      this.lastBackupTime = `${now.getFullYear()}-${pad2(now.getMonth() + 1)}-${pad2(now.getDate())} ${pad2(now.getHours())}:${pad2(now.getMinutes())}:${pad2(now.getSeconds())}`;
      this.backupUris.push(uris[0]);
      this.applyBackupRetention();
      this.persistBackupMeta();
      return true;
    } catch (err) {
      hilog.error(0x0000, TAG, '%{public}s', '导出数据失败：' + formatError(err));
      // 真实 IO/序列化异常（磁盘满、无权限、JSON 循环引用等）。必须与"用户取消"区分开，
      // 否则调用方一律提示"已取消导出"，用户不会重试（2026-10-13 修复）。
      lastExportFailed = true;
      return false;
    }
  }

  /** 上一次 exportData 是否因**用户主动取消**而返回 false（而非真实失败） */
  wasLastExportCancelled(): boolean {
    return lastExportCancelled;
  }

  /** 上一次 exportData 是否因**真实异常**失败 */
  wasLastExportFailed(): boolean {
    return lastExportFailed;
  }

  /** 获取最后备份/恢复的本地时间字符串（首次调用时从 Preferences 懒加载） */
  getLastBackupTime(): string {
    if (!this.lastBackupTime) {
      this.loadBackupMeta();
    }
    return this.lastBackupTime;
  }

  /** 从 Preferences 加载最后备份时间与备份 URI 列表 */
  private loadBackupMeta(): void {
    try {
      const pref = PreferenceManager.getInstance();
      const time = pref.getString(PREFS_KEY_LAST_BACKUP_TIME, '');
      if (time) {
        this.lastBackupTime = time;
      }
      const urisJson = pref.getString(PREFS_KEY_BACKUP_URIS, '');
      if (urisJson) {
        const parsed = JSON.parse(urisJson) as string[];
        if (Array.isArray(parsed)) {
          this.backupUris = parsed;
        }
      }
    } catch (err) {
      hilog.warn(0x0000, TAG, '%{public}s', '加载备份元数据失败：' + formatError(err));
    }
  }

  /** 获取备份前摘要：各类数据的条目数，供导出前向用户展示 */
  getBackupSummary(): BackupSummary {
    return {
      goals: DailyGoalManager.getInstance().getAllGoals().length,
      checkins: DailyGoalManager.getInstance().getCheckinHistory().length,
      sleepHistory: SleepManager.getInstance().exportSleepHistory().length,
      focusHistory: FocusModeManager.getInstance().exportData().history.length,
      achievements: AchievementManager.getInstance().getTotalAchievementCount(),
      unlockRecords: UsageStatsManager.getInstance().exportUnlockData().records.length,
      reminders: HealthReminderManager.getInstance().getCustomItems().length + 3
    };
  }

  /** 将最后备份时间与 URI 列表落盘到 Preferences */
  private persistBackupMeta(): void {
    const entries: PreferenceEntry[] = [
      { key: PREFS_KEY_LAST_BACKUP_TIME, value: this.lastBackupTime },
      { key: PREFS_KEY_BACKUP_URIS, value: JSON.stringify(this.backupUris) }
    ];
    PreferenceManager.getInstance().setBatch(entries);
  }

  /** 备份保留期：超出 MAX_BACKUP_FILES 时精简 URI 列表。
   * 注意：fileIo 无跨 URI 删除能力，此处仅精简内存/偏好中的 URI 记录；
   * 实际旧文件需用户在文件管理器中手动删除。
   */
  private applyBackupRetention(): void {
    if (this.backupUris.length <= MAX_BACKUP_FILES) {
      return;
    }
    this.backupUris = this.backupUris.slice(-MAX_BACKUP_FILES);
    this.persistBackupMeta();
    hilog.warn(0x0000, TAG, '%{public}s', '备份文件超过保留期上限，已精简 URI 记录（实际文件请用户在文件管理器中清理）。');
  }

/**
   * 校验备份文件的原始文本：JSON 解析 + 逐字段类型校验。
   * 抽成公有方法是为了让「畸形备份必须被拒」这条安全边界可在测试中直接验证
   * （importData 依赖 DocumentViewPicker，无法在自动化测试里驱动文件选择）。
   * @returns true 表示该文本可安全恢复
   */
  isValidBackupText(text: string): boolean {
    try {
      const backup = JSON.parse(text) as BackupData;
      return this.isValidBackupData(backup);
    } catch (err) {
      hilog.error(0x0000, TAG, '备份文件解析失败：' + formatError(err));
      return false;
    }
  }

  /**
   * 从用户选择的 JSON 文件恢复应用数据
   */
  async importData(context: common.Context): Promise<boolean> {
    try {
      const win = await window.getLastWindow(context);
      const documentPicker = new picker.DocumentViewPicker(context, win);
      const options = new picker.DocumentSelectOptions();
      options.fileSuffixFilters = [BACKUP_SUFFIX];
      options.maxSelectNumber = 1;

      const uris = await documentPicker.select(options);
      if (!uris || uris.length === 0) {
        hilog.info(0x0000, TAG, '%{public}s', '用户取消导入');
        lastImportReason = ImportFailureReason.CANCELLED;
        return false;
      }
      const text = await this.readTextFromUri(uris[0]);
      if (!this.isValidBackupText(text)) {
        hilog.error(0x0000, TAG, '%{public}s', '备份文件格式无效');
        lastImportReason = ImportFailureReason.INVALID_FILE;
        return false;
      }
      const backup = JSON.parse(text) as BackupData;
      await this.restoreBackupData(backup);
      hilog.info(0x0000, TAG, '%{public}s', '数据已从文件恢复：' + uris[0]);
      lastImportReason = ImportFailureReason.NONE;
      // 记录最后恢复时间
      const now = new Date();
      this.lastBackupTime = `${now.getFullYear()}-${pad2(now.getMonth() + 1)}-${pad2(now.getDate())} ${pad2(now.getHours())}:${pad2(now.getMinutes())}:${pad2(now.getSeconds())}`;
      this.persistBackupMeta();
      return true;
    } catch (err) {
      // ⚠️ 这里接的是 fileIo / JSON 解析抛出的异常，原先一律返回 false 且不记录原因，
      // 界面只能提示「导入失败，请稍后重试」——用户看到的是一个无从下手的提示。
      // 实机复现（2026-10-13）：模拟器上所选文件读不到，抛 13900002，
      // 界面显示的却是「请稍后重试」，用户反复点同一个坏文件毫无进展。
      const e = err as BusinessError;
      const code = e && e.code !== undefined ? e.code : undefined;
      lastImportReason = classifyFileError(code);
      hilog.error(0x0000, TAG, '%{public}s', '导入数据失败：' + formatError(err));
      return false;
    }
  }

  /**
   * 上一次 importData 失败的原因。用于让界面给出**准确**提示：
   * 「用户取消」与「文件格式不正确」必须分开——用户在文件选择器里按返回却被告知
   * 「文件格式不正确」，会误以为自己选错了文件、甚至把备份删掉（2026-10-13 修复）。
   */
  getLastImportFailure(): ImportFailureReason {
    return lastImportReason;
  }

/**
   * 读取选择器返回的 URI。
   *
   * ⚠️ 原实现是 `fileIo.readText(uris[0])`——**导入功能在实机上 100% 失败**，
   * 抛 `13900002 No such file or directory`。根因不是模拟器缺件、也不是文件被删：
   * `readText(filePath)` 的入参是**沙箱文件路径**，而 `DocumentViewPicker.select()`
   * 返回的是 `file://docs/...` 形式的 URI，它只接受能当路径解析的字符串，
   * 于是被当成一个不存在的文件。
   * 同一文件里 `exportData` 走的是 `fileIo.open(uri) + write`——**那条路是对的**
   * （导出在实机验证过能落盘），读写两侧写法不对称本身就是最强的旁证。
   *
   * 现在按 open/read/close 的方式读，与导出侧对称。`fileIo.close` 放finally，
   * 读失败也要归还 fd。
   */
  private async readTextFromUri(uri: string): Promise<string> {
    // open 失败必须上抛（调用方据此提示「导入失败」），所以这里**不吞异常**：
    // 包进 try 只是为了让 fileIo 的 @throws 调用处于受控范围，异常原样继续抛给上层。
    let file: fileIo.File | null = null;
    try {
      file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
      const stat = await fileIo.stat(file.fd);
      const size = stat.size;
      if (size <= 0) {
        return '';
      }
      const buffer = new ArrayBuffer(size);
      const readLength = await fileIo.read(file.fd, buffer);
      // decodeWithStream 自 API 12 起 deprecated，官方替代为 decodeToString（行为一致）
      return new util.TextDecoder('utf-8').decodeToString(new Uint8Array(buffer, 0, readLength));
    } catch (err) {
      // 打开/读取失败必须让上层感知（据此提示「导入失败」，并按 BusinessError.code 分类）：
      // 记一条可读日志后原样上抛；ArkTS 限制 throw 只能抛 Error 及其子类，故显式收窄类型。
      hilog.error(0x0000, TAG, '%{public}s', '读取备份文件失败：' + formatError(err));
      throw err as Error;
    } finally {
      if (file !== null) {
        try {
          await fileIo.close(file);
        } catch (err) {
          hilog.warn(0x0000, TAG, '%{public}s', '关闭导入文件失败：' + formatError(err));
        }
      }
    }
  }

  /**
   * 备份文件格式校验。
   * 原实现对 sleepData / sleepPreferences / downtimeRule 只做真值检查，
   * 一个 `"sleepPreferences": "hello"` 的文件即可通过校验并流入各 manager
   *（属性访问得到 undefined → 后续算术产出 NaN）。这里改为逐字段类型检查，
   * 让畸形文件在入口就被拒绝，而不是在各消费方留下难排查的损坏状态。
   */
  private isValidBackupData(data: BackupData): boolean {
    if (!data || typeof data.version !== 'number' || data.version !== BACKUP_VERSION) {
      return false;
    }
    if (typeof data.totalDailyLimitMinutes !== 'number') {
      return false;
    }
    if (!Number.isFinite(data.todayAccumulatedSeconds) || data.todayAccumulatedSeconds < 0) {
      return false;
    }
    if (!Array.isArray(data.dailyHistory)) {
      return false;
    }
    if (!data.sleepData ||
      typeof data.sleepData.sleepDurationMinutes !== 'number' ||
      typeof data.sleepData.preSleepUsageMinutes !== 'number' ||
      typeof data.sleepData.score !== 'number') {
      return false;
    }
    if (!data.sleepPreferences ||
      typeof data.sleepPreferences.sleepGoalMinutes !== 'number' ||
      typeof data.sleepPreferences.bedtimeReminderOffsetMinutes !== 'number' ||
      typeof data.sleepPreferences.preSleepRestrictionMinutes !== 'number' ||
      typeof data.sleepPreferences.enablePreSleepRestriction !== 'boolean') {
      return false;
    }
    if (!data.downtimeRule ||
      typeof data.downtimeRule.startHour !== 'number' ||
      typeof data.downtimeRule.startMinute !== 'number' ||
      typeof data.downtimeRule.endHour !== 'number' ||
      typeof data.downtimeRule.endMinute !== 'number' ||
      typeof data.downtimeRule.enabled !== 'boolean' ||
      !Array.isArray(data.downtimeRule.restrictedCategories)) {
      return false;
    }
    if (!data.bedtimeConfig ||
      typeof data.bedtimeConfig.hour !== 'number' ||
      typeof data.bedtimeConfig.minute !== 'number' ||
      typeof data.bedtimeConfig.enabled !== 'boolean') {
      return false;
    }
    // 2026-08-06 新增的 4 组可选字段同样必须逐字段校验：
    // 它们与上面几组走的是同一条"畸形数据 → 属性访问得 undefined → 算术产出 NaN 并落盘续命"链路，
    // 但此前一直只被真值检查放过（一个 `"focusData": "hello"` 的备份即可通过校验并流入 importData）。
    if (data.focusData !== undefined && data.focusData !== null && !this.isValidFocusBackup(data.focusData)) {
      return false;
    }
    if (data.achievementData !== undefined && data.achievementData !== null &&
      !this.isValidAchievementBackup(data.achievementData)) {
      return false;
    }
    if (data.unlockData !== undefined && data.unlockData !== null && !this.isValidUnlockBackup(data.unlockData)) {
      return false;
    }
    if (data.reminderData !== undefined && data.reminderData !== null &&
      !this.isValidReminderBackup(data.reminderData)) {
      return false;
    }
    // 2026-10-13 新增的两个可选字段同样要校验，否则畸形值会流入 importSleepHistory /
    // DailyGoalManager.importData 造成状态损坏
    if (data.sleepHistory !== undefined && data.sleepHistory !== null) {
      if (!Array.isArray(data.sleepHistory)) {
        return false;
      }
      for (const record of data.sleepHistory) {
        if (!record || typeof record.sleepDurationMinutes !== 'number' ||
          !Number.isFinite(record.sleepDurationMinutes)) {
          return false;
        }
      }
    }
    if (data.goalData !== undefined && data.goalData !== null && !this.isValidGoalBackup(data.goalData)) {
      return false;
    }
    return true;
  }

  /** 每日目标备份校验：goals / checkins 必须是数组，元素最小结构正确 */
  private isValidGoalBackup(data: DailyGoalBackupData): boolean {
    if (!data || !Array.isArray(data.goals) || !Array.isArray(data.checkins)) {
      return false;
    }
    for (const goal of data.goals) {
      if (!goal || typeof goal.id !== 'string' || goal.id.length === 0 ||
        typeof goal.name !== 'string') {
        return false;
      }
    }
    for (const entry of data.checkins) {
      if (!entry || typeof entry.date !== 'string' || entry.date.length === 0) {
        return false;
      }
    }
    // goalDate 可选（旧备份没有）。带了就必须形如 YYYY-MM-DD：
    // 它会被直接写进 lastGoalDate 并参与跨日判据，放任畸形值等于让下一次
    // checkNewDay() 必然判定为新的一天，把刚恢复的目标进度清零。
    if (data.goalDate !== undefined && !/^\d{4}-\d{2}-\d{2}$/.test(data.goalDate)) {
      return false;
    }
    return true;
  }

  /**
   * 专注数据校验：history 必须是数组，且每条会话的 6 个字段类型正确；
   * 三个数值字段还要求有限（NaN 会经 JSON.stringify 序列化成 null 落盘续命）。
   */
  private isValidFocusBackup(data: FocusBackupData): boolean {
    if (!data || !Array.isArray(data.history) ||
      !Number.isFinite(data.totalPoints) ||
      !Number.isFinite(data.currentStreak) ||
      !Number.isFinite(data.focusDurationMinutes)) {
      return false;
    }
    for (const item of data.history) {
      if (!item ||
        !Number.isFinite(item.startTime) ||
        !Number.isFinite(item.endTime) ||
        !Number.isFinite(item.durationMinutes) ||
        !Number.isFinite(item.pointsEarned) ||
        typeof item.completed !== 'boolean' ||
        typeof item.interrupted !== 'boolean') {
        return false;
      }
    }
    return true;
  }

  /**
   * 成就数据校验：形如 { "<成就id>": { unlocked: boolean, unlockedAt?: number } } 的字典。
   * Record 是索引类型，只能经 Object.entries 逐项遍历（ArkTS 禁 for-in 与按 key 索引访问）。
   */
  private isValidAchievementBackup(data: AchievementBackupData): boolean {
    if (!data || typeof data !== 'object') {
      return false;
    }
    const entries = Object.entries(data);
    for (const entry of entries) {
      const saved = entry[1];
      if (!saved || typeof saved.unlocked !== 'boolean') {
        return false;
      }
      if (saved.unlockedAt !== undefined && !Number.isFinite(saved.unlockedAt)) {
        return false;
      }
    }
    return true;
  }

  /**
   * 解锁数据校验：records 每条需 { timestamp:number, hour:number }，
   * dailyHistory 每条还需 unlockCount 与 hourlyCounts（长度 24 的数值数组）。
   */
  private isValidUnlockBackup(data: UnlockBackupData): boolean {
    if (!data || !Array.isArray(data.records) || !Array.isArray(data.dailyHistory)) {
      return false;
    }
    for (const record of data.records) {
      if (!record || !Number.isFinite(record.timestamp) || !Number.isFinite(record.hour)) {
        return false;
      }
    }
    for (const entry of data.dailyHistory) {
      if (!entry || typeof entry.date !== 'string' ||
        !Number.isFinite(entry.unlockCount) ||
        !this.isFiniteNumberArray(entry.hourlyCounts)) {
        return false;
      }
    }
    return true;
  }

  private isFiniteNumberArray(counts: number[]): boolean {
    if (!Array.isArray(counts)) {
      return false;
    }
    for (const value of counts) {
      if (!Number.isFinite(value)) {
        return false;
      }
    }
    return true;
  }

  /**
   * 健康提醒配置校验：三条内置配置逐字段类型检查 + 自定义项数组逐项检查。
   * 可选文本字段（title/content）允许缺省，但给出时必须是字符串；
   * weekdays 必须存在且是数值数组（OngoingReminderScheduler 直接按数组长度与索引判定）。
   */
  private isValidReminderBackup(data: ReminderBackupData): boolean {
    if (!data ||
      !this.isValidReminderConfig(data.sedentary) ||
      !this.isValidReminderConfig(data.eye) ||
      !this.isValidReminderConfig(data.water) ||
      !Array.isArray(data.customItems)) {
      return false;
    }
    for (const item of data.customItems) {
      if (!item ||
        typeof item.id !== 'string' ||
        typeof item.name !== 'string' ||
        typeof item.content !== 'string' ||
        typeof item.enabled !== 'boolean' ||
        !Number.isFinite(item.intervalMinutes) ||
        !Number.isFinite(item.startHour) ||
        !Number.isFinite(item.startMinute) ||
        !Number.isFinite(item.endHour) ||
        !Number.isFinite(item.endMinute) ||
        !Number.isFinite(item.notificationId) ||
        !this.isFiniteNumberArray(item.weekdays)) {
        return false;
      }
    }
    return true;
  }

  private isValidReminderConfig(config: HealthReminderConfig): boolean {
    if (!config ||
      typeof config.enabled !== 'boolean' ||
      !Number.isFinite(config.intervalMinutes) ||
      !Number.isFinite(config.startHour) ||
      !Number.isFinite(config.startMinute) ||
      !Number.isFinite(config.endHour) ||
      !Number.isFinite(config.endMinute)) {
      return false;
    }
    if (config.title !== undefined && typeof config.title !== 'string') {
      return false;
    }
    if (config.content !== undefined && typeof config.content !== 'string') {
      return false;
    }
    // weekdays 在 loadCustomItems / normalizeConfig 里会直接按数组遍历，缺省或非数组都必须拒绝
    if (!Array.isArray(config.weekdays)) {
      return false;
    }
    return this.isFiniteNumberArray(config.weekdays);
  }

private async restoreBackupData(backup: BackupData): Promise<void> {
    const sleepManager = SleepManager.getInstance();
    sleepManager.updateSleepData(backup.sleepData);
    sleepManager.setSleepPreferences(backup.sleepPreferences);
    // 睡眠历史：「重置所有数据」会删 sleep_history，必须一并恢复，否则建议入睡永远失去依据。
    // 缺失字段（旧版本备份）时 importSleepHistory 保持现状不清空。
    sleepManager.importSleepHistory(backup.sleepHistory);

    const usageManager = UsageStatsManager.getInstance();
    usageManager.setTotalDailyLimitMinutes(backup.totalDailyLimitMinutes);
    usageManager.setDowntimeRule(backup.downtimeRule);
    usageManager.setDailyHistory(backup.dailyHistory);
    usageManager.setSelfUsageSeconds(backup.todayAccumulatedSeconds);

    // 按恢复的停用时间规则重排常驻提醒（否则进程存活期间停用提醒仍保持备份前的时间/开关状态）
    const downtimeRule = backup.downtimeRule;
    if (downtimeRule && downtimeRule.enabled) {
      ReminderService.getInstance().scheduleDowntimeReminder(
        downtimeRule.startHour,
        downtimeRule.startMinute,
        true
      ).catch((err: Error) => {
        hilog.warn(0x0000, TAG, '%{public}s', '恢复停用时间提醒失败：' + err.message);
      });
    } else {
      ReminderService.getInstance().cancelDowntimeReminder().catch((err: Error) => {
        hilog.warn(0x0000, TAG, '%{public}s', '取消停用时间提醒失败：' + err.message);
      });
    }

    const reminderService = ReminderService.getInstance();
    reminderService.scheduleBedtimeReminder(
      backup.bedtimeConfig.hour,
      backup.bedtimeConfig.minute,
      backup.bedtimeConfig.enabled
    ).catch((err: Error) => {
      hilog.warn(0x0000, TAG, '%{public}s', '恢复睡前提醒配置失败：' + err.message);
    });

    // 专注数据（历史/积分/连续次数/专注时长）
    if (backup.focusData) {
      FocusModeManager.getInstance().importData(backup.focusData);
    }

    // 成就解锁状态
    if (backup.achievementData) {
      AchievementManager.getInstance().importData(backup.achievementData);
    }

    // 解锁记录（当日 + 每日历史）
    if (backup.unlockData) {
      UsageStatsManager.getInstance().importUnlockData(backup.unlockData);
    }

    // 健康提醒配置（内置久坐/用眼/喝水 + 自定义项），并重新注册常驻提醒
    if (backup.reminderData) {
      // 必须 await：importData 内部要重新注册常驻提醒（异步）。原先是 fire-and-forget，
      // 调用方 importData 拿到 true 后立刻刷新设置页，此刻恢复尚未完成，
      // 用户会看到自定义提醒列表仍是导入前的旧条目/旧开关状态，退出重进才对。
      try {
        await HealthReminderManager.getInstance().importData(backup.reminderData);
      } catch (err) {
        hilog.warn(0x0000, TAG, '%{public}s', '恢复健康提醒配置失败：' + formatError(err));
      }
    }

    // 每日目标与打卡历史：「重置所有数据」会删 daily_goals / checkin_history，
    // 原先不在备份范围内 —— 导出后重置再导入，这部分数据永久丢失。
    DailyGoalManager.getInstance().importData(backup.goalData);
  }

  /**
   * 重置全部数据：清空使用时长、限额规则、停用时间、睡前提醒、周趋势历史
   * 注意：使用真实清空逻辑（删除 Preferences 键 + 重置内存值）
   */
  async resetAllData(): Promise<boolean> {
    try {
      const pref = PreferenceManager.getInstance();

// 1. 清空 Preference 中的全部业务键
      const keysToDelete: string[] = [
        'downtime_rule',
        'total_daily_limit_minutes',
        // 旧键名兜底清理：统计口径已由「本应用前台」改为「真实亮屏」，foreground_records 不再写入
        'foreground_records',
        'screen_on_records',
        'daily_usage_history',
        'sleep_data',
        'sleep_preferences',
        'sleep_history',
        'bedtime_hour',
        'bedtime_minute',
        'bedtime_enabled',
        'last_health_sync_time',
        'focus_history',
        'focus_points',
        'focus_streak',
        'focus_duration_minutes',
        'focus_allowed_bundles',
        'today_accumulated_seconds',
        'today_accumulated_date',
        'unlock_history',
        'daily_unlock_history',
        'persistent_notification_id',
        'achievements',
        'daily_goals',
        'checkin_history',
        'daily_goals_date',
        // 昨日自定义目标快照：不删的话，重置后「复制昨日目标」仍能把重置前的目标还原回来
        'custom_goals_yesterday',
        'motivational_quotes_seen',
        'sedentary_reminder',
        'eye_reminder',
        'water_reminder',
        'custom_health_reminders',
        // 首页卡片布局：重置后回到默认全部显示且默认顺序
        // 新键 = 完整 9 项顺序 + 显隐标记；旧键 = 仅可见列表（迁移用，一并清掉）
        'home_card_layout',
        'home_card_config'
      ];
// deleteBatch 在刷盘失败时返回 false，此时不得继续重置内存态并向用户报成功
      const deleted = await pref.deleteBatch(keysToDelete);
      if (!deleted) {
        hilog.error(0x0000, TAG, '%{public}s', '[重置] 删除 Preferences 业务键失败，已中止重置');
        return false;
      }
      hilog.info(0x0000, TAG, '%{public}s', '[重置] 已删除所有 Preferences 业务键');

      // 1.5 首页布局缓存失效：上面删掉了 home_card_layout，但 ThemeManager 的版本号是内存态，
      // 不推进它的话，首页 1s tick 会认为"布局没变"而继续按重置前的顺序/显隐渲染。
      ThemeManager.getInstance().invalidateHomeCardLayout();

      // 2. 取消全部提醒（内置健康提醒 + 睡前/停用 + 护眼/专注 + 自定义项），并恢复内置提醒默认配置
      ReminderService.getInstance().cancelAllReminders();
      await HealthReminderManager.getInstance().resetAll();
      FocusModeManager.getInstance().resetAll();
      hilog.info(0x0000, TAG, '%{public}s', '[重置] 已取消全部提醒并清空专注数据');

      // 2.5 撤掉全部预警常驻通知（限额三档 + 停用预警）。
      // ⚠️ 必须在这里显式做：这些通知是 isUnremovable 的，划不掉；跨日清零靠应用存活才执行，
      // 进程被杀就永久残留一条文案与界面矛盾的横幅。initialize() 里刻意不做（会与补发竞态）。
      UsageStatsManager.getInstance().resetAlertNotifications();

      // 3. 重新初始化各 Manager（其内部会从 Preferences 重新读取，由于已清空会取默认值）
      UsageStatsManager.getInstance().initialize();
      SleepManager.getInstance().initialize();
      AchievementManager.getInstance().initialize();
      DailyGoalManager.getInstance().initialize();
      hilog.info(0x0000, TAG, '%{public}s', '[重置] 已重新初始化所有 Manager');
      return true;
    } catch (err) {
      hilog.error(0x0000, TAG, '%{public}s', '[重置] 失败：' + formatError(err));
      return false;
    }
  }
}
