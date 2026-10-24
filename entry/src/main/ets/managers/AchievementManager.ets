/**
 * 成就与激励系统
 * 游戏化设计，激励长期自律行为
 */
import { formatError } from '../models/ErrUtils';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PreferenceManager } from './PreferenceManager';
import { UsageStatsManager } from './UsageStatsManager';
import { FocusModeManager } from './FocusModeManager';

const TAG = 'AchievementManager';
const PREFS_KEY_ACHIEVEMENTS = 'achievements';

interface AchievementSavedData {
  unlocked: boolean;
  unlockedAt?: number;
}

export type AchievementBackupData = Record<string, AchievementSavedData>;

export interface Achievement {
  id: string;
  name: string;
  description: string;
  icon: string;
  tier: 'bronze' | 'silver' | 'gold' | 'platinum';
  unlocked: boolean;
  unlockedAt?: number;
  progress: number;
  target: number;
}

export class AchievementManager {
  private static instance: AchievementManager;

  static getInstance(): AchievementManager {
    if (!AchievementManager.instance) {
      AchievementManager.instance = new AchievementManager();
    }
    return AchievementManager.instance;
  }

  private achievements: Map<string, Achievement> = new Map();

  initialize(): void {
    hilog.info(0x0000, TAG, '%{public}s', '[初始化] 成就系统');
    this.defineAchievements();
    this.loadFromPreferences();
    this.checkAllAchievements();
    this.checkUnlockAchievements();
  }

  private defineAchievements(): void {
    // 连续达标天数成就
    this.defineAchievement('streak_7', '坚持一周', '连续7天屏幕使用达标', '🔥', 'bronze', 7);
    this.defineAchievement('streak_30', '月度勇士', '连续30天屏幕使用达标', '⭐', 'silver', 30);
    this.defineAchievement('streak_100', '百日传奇', '连续100天屏幕使用达标', '🏆', 'gold', 100);

    // 专注时长成就
    this.defineAchievement('focus_60', '专注学徒', '累计专注60分钟', '📚', 'bronze', 60);
    this.defineAchievement('focus_300', '专注达人', '累计专注300分钟', '🎯', 'silver', 300);
    this.defineAchievement('focus_600', '专注大师', '累计专注600分钟', '🧠', 'gold', 600);

    // 专注次数成就
    this.defineAchievement('focus_sessions_10', '专注新手', '完成10次专注会话', '🌱', 'bronze', 10);
    this.defineAchievement('focus_sessions_50', '专注专家', '完成50次专注会话', '🌿', 'silver', 50);
    this.defineAchievement('focus_sessions_100', '专注宗师', '完成100次专注会话', '🌳', 'gold', 100);

    // 解锁控制成就
    this.defineAchievement('unlock_low_30', '自控新星', '单日解锁次数少于30次', '💫', 'bronze', 1);
    this.defineAchievement('unlock_low_20', '自控达人', '单日解锁次数少于20次', '✨', 'silver', 1);
    this.defineAchievement('unlock_low_10', '自控大师', '单日解锁次数少于10次', '🌟', 'gold', 1);

    // 坚持成就
this.defineAchievement('dedication_week', '一周践行者', '连续7天使用手机', '📅', 'bronze', 7);
    this.defineAchievement('dedication_month', '月度践行者', '连续30天使用手机', '📆', 'silver', 30);
  }

  /** 注册一条成就定义（初始未解锁、进度 0） */
  private defineAchievement(
    id: string,
    name: string,
    description: string,
    icon: string,
    tier: 'bronze' | 'silver' | 'gold' | 'platinum',
    target: number
  ): void {
    this.achievements.set(id, {
      id: id,
      name: name,
      description: description,
      icon: icon,
      tier: tier,
      unlocked: false,
      progress: 0,
      target: target
    });
  }

  private loadFromPreferences(): void {
    try {
      const pref = PreferenceManager.getInstance();
      const json = pref.getString(PREFS_KEY_ACHIEVEMENTS, '');
      if (json) {
        const saved = JSON.parse(json) as Record<string, AchievementSavedData>;
        const entries = Object.entries(saved);
        for (const entry of entries) {
          const id = entry[0];
          const data = entry[1];
          const achievement = this.achievements.get(id);
          if (achievement) {
            achievement.unlocked = data.unlocked;
            achievement.unlockedAt = data.unlockedAt;
          }
        }
      }
    } catch (err) {
      hilog.error(0x0000, TAG, '%{public}s', '加载成就数据失败：' + formatError(err));
    }
  }

  private saveToPreferences(): void {
    try {
      const data: Record<string, AchievementSavedData> = {};
      this.achievements.forEach((achievement, id) => {
        const item: AchievementSavedData = {
          unlocked: achievement.unlocked,
          unlockedAt: achievement.unlockedAt
        };
        data[id] = item;
      });
      // PreferenceManager 内部已catch 并记日志、从不 reject，故不挂 .catch（挂上也是永不触发的死代码）
      PreferenceManager.getInstance().setString(PREFS_KEY_ACHIEVEMENTS, JSON.stringify(data));
    } catch (err) {
      hilog.error(0x0000, TAG, '%{public}s', '保存成就数据失败：' + formatError(err));
    }
  }

  /**
   * 检查所有成就
   */
  private checkAllAchievements(): void {
    const unlockedBefore = this.getUnlockedAchievementCount();
    this.checkStreakAchievements();
    this.checkFocusAchievements();
    this.checkDedicationAchievements();
    if (this.getUnlockedAchievementCount() !== unlockedBefore) {
      this.saveToPreferences();
    }
  }

  private checkStreakAchievements(): void {
    const streakDays = UsageStatsManager.getInstance().getStreakDays();

    this.updateAchievementProgress('streak_7', streakDays);
    this.updateAchievementProgress('streak_30', streakDays);
    this.updateAchievementProgress('streak_100', streakDays);
  }

  private checkFocusAchievements(): void {
    const stats = FocusModeManager.getInstance().getStats();

    // 专注时长成就
    this.updateAchievementProgress('focus_60', stats.totalMinutes);
    this.updateAchievementProgress('focus_300', stats.totalMinutes);
    this.updateAchievementProgress('focus_600', stats.totalMinutes);

    // 专注次数成就
    this.updateAchievementProgress('focus_sessions_10', stats.totalSessions);
    this.updateAchievementProgress('focus_sessions_50', stats.totalSessions);
    this.updateAchievementProgress('focus_sessions_100', stats.totalSessions);
  }

  /**
   * 坚持成就：连续使用应用天数（基于真实亮屏使用每日历史）
   */
  private checkDedicationAchievements(): void {
    const usedDays = UsageStatsManager.getInstance().getAppUsedDaysStreak();
    this.updateAchievementProgress('dedication_week', usedDays);
    this.updateAchievementProgress('dedication_month', usedDays);
  }

  /**
   * 实时重算进度型成就（专注时长/次数、连续达标天数），供聚合循环周期性调用
   * 专注会话完成、跨日等数据变化后无需重启应用即可解锁
   */
  refreshAchievements(): void {
    this.checkAllAchievements();
  }

  /**
   * 检查解锁成就（启动时与跨日时调用）
   * 基于最近一个已完成日的真实解锁数据评估；无已完成日数据时不授予，
   * 避免首次启动时"今日解锁 0 次"平凡解锁全部档位
   */
  checkUnlockAchievements(): void {
    const unlockedBefore = this.getUnlockedAchievementCount();
    const lastDayCount = UsageStatsManager.getInstance().getLastCompletedDayUnlockCount();

    if (lastDayCount < 0) {
      return;
    }

    // 这三枚是"阈值类"成就（解锁次数低于 N 即达标），语义上进度只有 0/1 两档。
    // 原实现直接调 unlockAchievement 而不写 progress，导致成就页永远显示
    // 「0/1」+ 0% 进度条，直到解锁当天才跳变，解锁后也不回填。
    if (lastDayCount < 30) {
      this.updateAchievementProgress('unlock_low_30', 1);
    }
    if (lastDayCount < 20) {
      this.updateAchievementProgress('unlock_low_20', 1);
    }
    if (lastDayCount < 10) {
      this.updateAchievementProgress('unlock_low_10', 1);
    }

    if (this.getUnlockedAchievementCount() !== unlockedBefore) {
      this.saveToPreferences();
    }
  }

  /** 更新指定成就进度，达标且未解锁时立即解锁 */
  private updateAchievementProgress(id: string, progress: number): void {
    const achievement = this.achievements.get(id);
    if (!achievement) {
      return;
    }

    achievement.progress = progress;

    if (!achievement.unlocked && progress >= achievement.target) {
      this.unlockAchievement(id);
    }
  }

  /** 解锁指定成就并记录解锁时间（已解锁则忽略） */
  private unlockAchievement(id: string): void {
    const achievement = this.achievements.get(id);
    if (!achievement || achievement.unlocked) {
      return;
    }

    achievement.unlocked = true;
    achievement.unlockedAt = Date.now();

    hilog.info(0x0000, TAG, '%{public}s', `[成就解锁] ${achievement.name}: ${achievement.description}`);
  }

  /**
   * 获取所有成就的"变更指纹"：id:progress:unlocked 逐项拼接。
   *
   * 用途：成就页 3s 轮询原本先调 getAllAchievements()（14 个对象的深拷贝）
   * 再算指纹比对，守卫落在拷贝**之后**，于是"无变化"的周期仍白做 14 次对象分配
   * + 1 个约 400 字符的 key 串。改为由 manager 提供本方法，页面先比指纹、
   * 命中即 return，不再取深拷贝。
   *
   * 页面已于 2026-10-06 删除自带的 buildSnapshotKey（第二份拼接逻辑），
   * 直接复用本方法，故口径天然一致——只有这一处拼接实现。
   */
  getAchievementsSnapshotKey(): string {
    const parts: string[] = [];
    this.achievements.forEach((achievement: Achievement, id: string) => {
      parts.push(id + ':' + achievement.progress.toString() + ':' + (achievement.unlocked ? '1' : '0'));
    });
    return parts.join('|');
  }

  /**
   * 获取所有成就
   * 返回深拷贝：管理器会原地修改这些对象（刷新进度/解锁），若返回同一批引用，
   * 页面持有的 @State 数组不会感知变化，ForEach key 也不变 → 新解锁的成就无法实时刷新
   */
  getAllAchievements(): Achievement[] {
    const list: Achievement[] = [];
    this.achievements.forEach((achievement: Achievement) => {
      list.push({
        id: achievement.id,
        name: achievement.name,
        description: achievement.description,
        icon: achievement.icon,
        tier: achievement.tier,
        unlocked: achievement.unlocked,
        unlockedAt: achievement.unlockedAt,
        progress: achievement.progress,
        target: achievement.target
      });
    });
    return list;
  }

  /**
   * 获取已解锁成就数量（避免每次分配数组）
   */
  getUnlockedAchievementCount(): number {
    let count = 0;
    this.achievements.forEach(achievement => {
      if (achievement.unlocked) {
        count++;
      }
    });
    return count;
  }

  /**
   * 获取成就总数
   */
  getTotalAchievementCount(): number {
    return this.achievements.size;
  }

  /**
   * 获取总体完成率
   */
  getCompletionRate(): number {
    const total = this.achievements.size;
    const unlocked = this.getUnlockedAchievementCount();
    return total > 0 ? Math.round((unlocked / total) * 100) : 0;
  }

  /**
   * 导出成就解锁状态（用于备份）
   */
  exportData(): AchievementBackupData {
    const data: AchievementBackupData = {};
    this.achievements.forEach((achievement, id) => {
      const item: AchievementSavedData = {
        unlocked: achievement.unlocked,
        unlockedAt: achievement.unlockedAt
      };
      data[id] = item;
    });
    return data;
  }

  /**
   * 导入成就解锁状态（备份恢复）
   */
  importData(data: AchievementBackupData): void {
    if (!data) {
      return;
    }
    const entries = Object.entries(data);
    for (const entry of entries) {
      const id = entry[0];
      const saved = entry[1];
      const achievement = this.achievements.get(id);
      if (achievement && saved) {
        achievement.unlocked = !!saved.unlocked;
        achievement.unlockedAt = saved.unlockedAt;
      }
    }
    this.saveToPreferences();
  }
}