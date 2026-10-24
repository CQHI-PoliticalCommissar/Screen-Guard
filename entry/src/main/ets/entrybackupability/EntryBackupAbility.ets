import { hilog } from '@kit.PerformanceAnalysisKit';
import { BackupExtensionAbility, BundleVersion } from '@kit.CoreFileKit';

const DOMAIN = 0x0000;
const TAG = 'EntryBackupAbility';

export default class EntryBackupAbility extends BackupExtensionAbility {
  /** 系统备份回调：交由系统框架处理数据备份 */
  async onBackup() {
    hilog.info(DOMAIN, TAG, 'onBackup ok');
    await Promise.resolve();
  }

  /** 系统恢复回调：交由系统框架处理数据恢复 */
  async onRestore(bundleVersion: BundleVersion) {
    hilog.info(DOMAIN, TAG, 'onRestore ok %{public}s', JSON.stringify(bundleVersion));
    await Promise.resolve();
  }
}