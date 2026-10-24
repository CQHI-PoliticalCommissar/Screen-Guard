/**
 * 页面层共用的轻量 UI 工具。
 *
 * ⚠️ 与 models/ 下其余模块不同：本文件依赖 hilog 与 ArkUI 的 UIContext，
 * **不是「零依赖纯函数内核」**，不要把可单测的计算逻辑放进这里。
 */

import { formatError } from './ErrUtils';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 弹一个 2 秒 toast；失败（页面已卸载、UIContext 失效等）只记日志、不抛。
 *
 * 此前 Settings / GoalPage / Sleep 三处各有一份逐字相同的私有 `showToast`
 * （仅 hilog 的 tag 与前缀不同），收拢至此后 toast 的时长与失败处理只有一处定义。
 *
 * @param ctx 调用页面的 UIContext（传 `this.getUIContext()`）
 * @param tag hilog 业务 tag，与各页面既有写法一致
 * @param pageName 日志前缀，用于区分是哪个页面的 toast 失败
 * @param message 展示文案
 */
export function showToastSafe(ctx: UIContext, tag: string, pageName: string, message: string): void {
  try {
    ctx.getPromptAction().showToast({ message: message, duration: 2000 });
  } catch (err) {
    hilog.error(0x0000, tag, '%{public}s', pageName + ' showToast failed: ' + formatError(err));
  }
}