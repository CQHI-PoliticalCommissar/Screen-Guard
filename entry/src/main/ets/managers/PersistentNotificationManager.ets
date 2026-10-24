import { formatError } from '../models/ErrUtils';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { notificationManager } from '@kit.NotificationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { PreferenceManager } from './PreferenceManager';
import { SELF_APP_NAME } from '../models/HealthTypes';

const TAG = 'PersistentNotificationManager';
const PERSISTENT_ID_PREFS_KEY = 'persistent_notification_id';

/**
 * 常驻通知 ID 专用高位段。
 * NotificationType 占用 1001–1011、自定义提醒从 2000 起递增，若沿用
 * `Date.now() % 1000000`（0–999999）会与这两段重叠，撞号时两条通知互相覆盖。
 */
const PERSISTENT_ID_BASE = 9000000;
/** ID 抖动幅度（避免同一毫秒内重复生成同一 ID） */
const PERSISTENT_ID_SPAN = 1000000;

interface NotificationRequestNormal {
  title: string;
  text: string;
  additionalText?: string;
}

interface NotificationRequestContent {
  notificationContentType: number;
  normal: NotificationRequestNormal;
}

interface NotificationRequest {
  id: number;
  content: NotificationRequestContent;
  autoDeleted?: boolean;
  isOngoing?: boolean;
  isUnremovable?: boolean;
}

/**
 * 管理应用在通知栏显示的常驻（ongoing）通知
 * 提供发布、更新、取消接口
 */
export class PersistentNotificationManager {
  private static instance: PersistentNotificationManager;

  /** 当前常驻通知 ID（首次生成后落盘复用，保证跨重启覆盖同一通知） */
  private currentId: number = -1;

  static getInstance(): PersistentNotificationManager {
    if (!PersistentNotificationManager.instance) {
      PersistentNotificationManager.instance = new PersistentNotificationManager();
    }
    return PersistentNotificationManager.instance;
  }

  private constructor() {
    // 从偏好恢复上次生成的 ID，避免重启后发布成重复通知
    this.currentId = PreferenceManager.getInstance().getNumber(PERSISTENT_ID_PREFS_KEY, -1);
  }

/**
   * 解析本次发布使用的通知 ID：
   * 优先复用上次落盘的 ID（保证跨重启覆盖同一条通知）；旧版本用
   * `Date.now() % 1000000` 写入的低位 ID 可能与 NotificationType / 自定义提醒撞号，
   * 一律重新生成到专用高位段。
   */
  private resolveId(): number {
    if (this.currentId >= PERSISTENT_ID_BASE) {
      return this.currentId;
    }
    return PERSISTENT_ID_BASE + (Date.now() % PERSISTENT_ID_SPAN);
  }

  /**
   * 发布或更新常驻通知
   * @param title 标题
   * @param text 文本内容
   */
  async publishPersistent(title: string, text: string): Promise<number> {
    try {
      if (!notificationManager.isNotificationEnabledSync()) {
        hilog.warn(0x0000, TAG, '%{public}s', '通知未启用，无法发布常驻通知');
        return -1;
      }

      const id = this.resolveId();

      const req: NotificationRequest = {
        id,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: { title, text, additionalText: SELF_APP_NAME }
        },
        autoDeleted: false,
        isOngoing: true,
        isUnremovable: true
      };

      await notificationManager.publish(req);
      if (this.currentId !== id) {
        // 仅在 ID 首次生成或从旧低位段迁移时落盘，后续复用同一 ID 不再重复写偏好
        PreferenceManager.getInstance().setNumber(PERSISTENT_ID_PREFS_KEY, id);
        // 迁移场景：旧低位 ID 曾发布过的常驻通知需要撤除，否则会与新 ID 的通知并存。
        // 失败必须留痕：撤不掉就是两条 isUnremovable 横幅同时挂在通知栏，且无法再撤回。
        if (this.currentId >= 0) {
          const staleId = this.currentId;
          notificationManager.cancel(staleId).catch((cancelErr: Error) => {
            const bizErr = cancelErr as BusinessError;
            if (bizErr.code === 1600007) {
              return;
            }
            hilog.error(0x0000, TAG, '%{public}s',
              `[publishPersistent] 撤除旧低位常驻通知失败：id=${staleId} code=${bizErr.code} message=${bizErr.message}`);
          });
        }
      }
      this.currentId = id;
      hilog.info(0x0000, TAG, '%{public}s', `[publishPersistent] 已发布/更新，ID=${id}`);
      return id;
    } catch (err) {
      hilog.error(0x0000, TAG, '%{public}s', '[publishPersistent] 失败: ' + formatError(err));
      return -1;
    }
  }

}
