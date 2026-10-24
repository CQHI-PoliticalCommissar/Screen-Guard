import { formatError } from '../models/ErrUtils';
import { formBindingData, FormExtensionAbility, formInfo, formProvider } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { HealthStateManager } from '../managers/HealthStateManager';
import { STATUS_COLOR_MAP } from '../models/HealthTypes';

interface HealthFormData {
  eyeUsage: string;
  remainingMinutes: number;
  statusColor: string;
}

/**
 * 健康服务卡片 ExtensionAbility
 * 处理卡片生命周期与真实数据绑定
 */
export default class HealthFormAbility extends FormExtensionAbility {
  private static activeFormIds: string[] = [];

  /** 卡片添加回调：登记卡片 ID 并返回初始数据 */
  onAddForm(want: Want): formBindingData.FormBindingData {
    const formId = want.parameters?.['ohos.extra.param.key.form_identity'] as string;
    if (formId && HealthFormAbility.activeFormIds.indexOf(formId) < 0) {
      HealthFormAbility.activeFormIds.push(formId);
    }
    console.info('HealthFormAbility onAddForm, formId: ' + formId);
    return formBindingData.createFormBindingData(this.buildFormData());
  }

  onCastToNormal(formId: string): void {
    console.info('HealthFormAbility onCastToNormal, formId: ' + formId);
  }

  /** 系统定时刷新回调：更新该卡片数据 */
  onUpdateForm(formId: string): void {
    console.info('HealthFormAbility onUpdateForm, formId: ' + formId);
    this.updateFormInternal(formId);
  }

  onFormEvent(formId: string, message: string): void {
    console.info('HealthFormAbility onFormEvent, formId: ' + formId + ', message: ' + message);
  }

  /** 卡片移除回调：从登记表剔除该卡片 ID */
  onRemoveForm(formId: string): void {
    console.info('HealthFormAbility onRemoveForm, formId: ' + formId);
    const index = HealthFormAbility.activeFormIds.indexOf(formId);
    if (index >= 0) {
      HealthFormAbility.activeFormIds.splice(index, 1);
    }
  }

  onConfigurationUpdate(): void {
    console.info('HealthFormAbility onConfigurationUpdate');
  }

  onAcquireFormState?(want: Want): formInfo.FormState {
    return formInfo.FormState.READY;
  }

  /**
   * 刷新所有活动卡片，由 HealthStateManager 定时调用
   */
  static updateAllForms(): void {
    if (HealthFormAbility.activeFormIds.length === 0) {
      return;
    }
    const data = HealthFormAbility.buildStaticFormData();
    const bindingData = formBindingData.createFormBindingData(data);
    HealthFormAbility.activeFormIds.forEach((formId) => {
      try {
        formProvider.updateForm(formId, bindingData);
      } catch (err) {
        console.error('HealthFormAbility updateForm failed: ' + formatError(err));
      }
    });
  }

  /** 单张卡片数据刷新（含异常兜底） */
  private updateFormInternal(formId: string): void {
    try {
      formProvider.updateForm(formId, formBindingData.createFormBindingData(this.buildFormData()));
    } catch (err) {
      console.error('HealthFormAbility updateForm failed: ' + formatError(err));
    }
  }

  /** 构建单卡数据（委托静态方法） */
  private buildFormData(): HealthFormData {
    return HealthFormAbility.buildStaticFormData();
  }

  /** 从健康状态管理器取胶囊数据并映射为卡片渲染所需字段 */
  private static buildStaticFormData(): HealthFormData {
    const stateManager = HealthStateManager.getInstance();
    const capsuleData = stateManager.getCapsuleData();

    return {
      eyeUsage: HealthFormAbility.formatSeconds(capsuleData.eyeUsageSeconds),
      remainingMinutes: capsuleData.remainingMinutes,
      statusColor: STATUS_COLOR_MAP[capsuleData.status]
    };
  }

  /** 秒数格式化为 M:SS（卡片眼疲劳计时文案） */
  private static formatSeconds(seconds: number): string {
    const mins = Math.floor(seconds / 60);
    const secs = seconds % 60;
    return `${mins}:${secs.toString().padStart(2, '0')}`;
  }
}
