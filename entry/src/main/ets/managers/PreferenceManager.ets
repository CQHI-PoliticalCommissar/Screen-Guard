import { formatError } from '../models/ErrUtils';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const TAG = 'PreferenceManager';
const PREFERENCES_NAME = 'health_prefs';

/**
 * 批量写入条目
 */
export interface PreferenceEntry {
  key: string;
  value: string | number | boolean;
}

/**
 * 本地偏好设置管理器
 * 持久化存储应用限额、停用时间、专注模式等用户配置
 */
export class PreferenceManager {
  private static instance: PreferenceManager;

  static getInstance(): PreferenceManager {
    if (!PreferenceManager.instance) {
      PreferenceManager.instance = new PreferenceManager();
    }
    return PreferenceManager.instance;
  }

  private pref?: preferences.Preferences;

  /**
   * 初始化偏好存储（幂等：已初始化则直接返回）
   * @param context 用于获取 preferences 的应用上下文
   */
  async init(context: common.Context): Promise<void> {
    if (this.pref) {
      return;
    }
    try {
      this.pref = preferences.getPreferencesSync(context, { name: PREFERENCES_NAME });
    } catch (err) {
      hilog.error(0x0000, TAG, '%{public}s', '初始化偏好设置失败：' + formatError(err));
    }
  }

  /** 写入字符串键值（写后立即 flush 落盘） */
  async setString(key: string, value: string): Promise<void> {
    await this.putAndFlush(key, value);
  }

  /** 读取字符串键值，异常/未初始化时返回默认值 */
  getString(key: string, defaultValue: string = ''): string {
    if (!this.pref) {
      return defaultValue;
    }
    try {
      return this.pref.getSync(key, defaultValue) as string;
    } catch (err) {
      return defaultValue;
    }
  }

  /** 写入数字键值（写后立即 flush 落盘） */
  async setNumber(key: string, value: number): Promise<void> {
    await this.putAndFlush(key, value);
  }

  /** 读取数字键值：非有限数值视为脏数据回退默认值 */
  getNumber(key: string, defaultValue: number = 0): number {
    if (!this.pref) {
      return defaultValue;
    }
    try {
      const value = this.pref.getSync(key, defaultValue) as number;
      return typeof value === 'number' && Number.isFinite(value) ? value : defaultValue;
    } catch (err) {
      return defaultValue;
    }
  }

  /** 读取布尔键值，异常/未初始化时返回默认值 */
  getBoolean(key: string, defaultValue: boolean = false): boolean {
    if (!this.pref) {
      return defaultValue;
    }
    try {
      return this.pref.getSync(key, defaultValue) as boolean;
    } catch (err) {
      return defaultValue;
    }
  }

  /**
   * 写入布尔键值（写后立即 flush 落盘）
   *
   * 本方法曾于 2026-08-04 轮作为"无调用方的死代码"删除，2026-10-13 为
   * 隐私同意状态（`AppLaunchGate.PRIVACY_CONSENT_KEY`）重新启用。
   */
  async setBoolean(key: string, value: boolean): Promise<void> {
    await this.putAndFlush(key, value);
  }

  /**
   * 单个键写入并落盘
   *
   * 约定：本类所有写方法的异常都在内部捕获并记日志，**从不 reject**。
   * 因此调用方无需（也不应）再套 `.catch(() => {})` —— 那种 catch 是永不触发的死代码，
   * 且会掩盖"若将来真的改成 rethrow"的意图。真正需要感知失败时请改用
   * `delete/deleteBatch` 的 boolean 返回值。
   */
  private async putAndFlush(key: string, value: string | number | boolean): Promise<void> {
    if (!this.pref) {
      return;
    }
    try {
      this.pref.putSync(key, value);
      await this.pref.flush();
    } catch (err) {
      hilog.error(0x0000, TAG, '%{public}s', '保存数据失败 [' + key + ']：' + formatError(err));
    }
  }

  /**
   * 批量写入多个键值对，仅触发一次落盘
   */
  async setBatch(entries: PreferenceEntry[]): Promise<void> {
    if (!this.pref || entries.length === 0) {
      return;
    }
    try {
      for (const entry of entries) {
        this.pref.putSync(entry.key, entry.value);
      }
      await this.pref.flush();
    } catch (err) {
      hilog.error(0x0000, TAG, '%{public}s', '批量保存失败：' + formatError(err));
    }
  }

  /**
   * 批量删除多个键，仅触发一次落盘
   */
  async deleteBatch(keys: string[]): Promise<boolean> {
    if (!this.pref) {
      return false;
    }
    if (keys.length === 0) {
      return true;
    }
    try {
      for (const key of keys) {
        this.pref.deleteSync(key);
      }
      await this.pref.flush();
      return true;
    } catch (err) {
      hilog.error(0x0000, TAG, '%{public}s', '批量删除失败：' + formatError(err));
      return false;
    }
  }

  /**
   * 删除指定键
   */
  async delete(key: string): Promise<boolean> {
    if (!this.pref) {
      return false;
    }
    try {
      this.pref.deleteSync(key);
      await this.pref.flush();
      return true;
    } catch (err) {
      hilog.error(0x0000, TAG, '%{public}s', '删除键失败 [' + key + ']：' + formatError(err));
      return false;
    }
  }
}
