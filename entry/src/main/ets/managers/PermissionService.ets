import { formatError } from '../models/ErrUtils';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { abilityAccessCtrl, bundleManager, common, Permissions } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';

const TAG = 'PermissionService';

/**
 * 运行时权限服务
 * 处理后台运行、传感器、通知、健康数据等敏感权限的请求与缓存
 */
export class PermissionService {
  private static instance: PermissionService;
  static getInstance(): PermissionService {
    if (!PermissionService.instance) {
      PermissionService.instance = new PermissionService();
    }
    return PermissionService.instance;
  }

/**
   * 请求应用运行所需的关键权限
   *
   * ⚠️ 这里**只列 user_grant 权限**（可在运行时弹窗申请）：
   * - `ohos.permission.READ_HEALTH_DATA`：user_grant，需用户同意。
   * - `ohos.permission.KEEP_BACKGROUND_RUNNING`：**system_grant**，安装即自动授予，
   *   运行时弹窗对它无效。它只在 `module.json5` 中声明（配 `when: "always"` 的
   *   `usedScene`），因此不再放进本列表——列进来只会产生一条永不执行的申请路径，
   *   上架审核看代码容易判为"申请了用不上的权限"。
   * - `ohos.permission.NOTIFICATION_CONTROLLER`：系统级，三方应用无法申请。
   *   通知使能改由 `notificationManager.requestEnableNotification` 单独处理。
   */
  async requestRequiredPermissions(context: common.Context): Promise<boolean> {
    const requiredPermissions: Permissions[] = [
      'ohos.permission.READ_HEALTH_DATA'
    ];
    const permissionsGranted = await this.requestPermissions(context, requiredPermissions);

    // 通知渠道权限需单独请求（结果同样计入总结果，避免日志误报权限已全部授予）
    const notificationGranted = await this.requestNotificationPermission(context);

    return permissionsGranted && notificationGranted;
  }

  /**
   * 请求通知使能权限
   */
  async requestNotificationPermission(context: common.Context): Promise<boolean> {
    try {
      const enabled = notificationManager.isNotificationEnabledSync();
      if (enabled) {
        return true;
      }
      await notificationManager.requestEnableNotification(context as common.UIAbilityContext);
      return notificationManager.isNotificationEnabledSync();
    } catch (err) {
      hilog.warn(0x0000, TAG, '%{public}s', '请求通知权限失败：' + formatError(err));
      return false;
    }
  }

  private async getAccessTokenId(): Promise<number> {
    const applicationInfo = await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
    return applicationInfo.appInfo.accessTokenId;
  }

  async requestPermissions(context: common.Context, permissions: Permissions[]): Promise<boolean> {
    const atManager = abilityAccessCtrl.createAtManager();
    const tokenID = await this.getAccessTokenId();

    const permissionsToRequest: Permissions[] = [];
    for (const permission of permissions) {
      try {
        const authStatus = await atManager.checkAccessToken(tokenID, permission);
        if (authStatus !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
          permissionsToRequest.push(permission);
        }
      } catch (err) {
        hilog.warn(0x0000, TAG, '%{public}s', `检查权限失败 ${permission}: ${formatError(err)}`);
        permissionsToRequest.push(permission);
      }
    }

    if (permissionsToRequest.length === 0) {
      hilog.info(0x0000, TAG, '%{public}s', '所有必需权限已授予');
      return true;
    }

    try {
      const result = await atManager.requestPermissionsFromUser(context as common.UIAbilityContext, permissionsToRequest);
      let allGranted = true;
      result.authResults.forEach((status, index) => {
        const permission = result.permissions[index] as Permissions;
        if (status !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
          allGranted = false;
          hilog.warn(0x0000, TAG, '%{public}s', `权限未授予 ${permission}`);
        }
      });
      return allGranted;
    } catch (err) {
      hilog.error(0x0000, TAG, '%{public}s', '请求权限失败：' + formatError(err));
      return false;
    }
  }
}
