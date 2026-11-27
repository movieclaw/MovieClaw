import { FormExtensionAbility, formBindingData, formInfo, formProvider } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { WidgetSync } from '../common/WidgetSync';

function pushForms(formIds: string[], payload: Record<string, Object>): void {
  const binding: formBindingData.FormBindingData = formBindingData.createFormBindingData(payload);
  for (const id of formIds) {
    formProvider.updateForm(id, binding).catch((): void => {
    });
  }
}

/**
 * 鸿蒙桌面万能卡片扩展能力（支持 2×2 与 2×4「继续观看」卡片）：
 * 卡片添加、定时刷新与移除生命周期钩子。
 */
export default class EntryFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    WidgetSync.shared.bindUpdater(pushForms);
    const params: Record<string, Object> | undefined = want.parameters;
    const formId: string = params !== undefined && params['ohos.extra.param.key.form_identity'] !== undefined
      ? `${params['ohos.extra.param.key.form_identity']}` : '';
    const dimRaw: number = params !== undefined && params['ohos.extra.param.key.form_dimension'] !== undefined
      ? Number(params['ohos.extra.param.key.form_dimension']) : 3;
    const dimension: number = Number.isFinite(dimRaw) && dimRaw > 0 ? dimRaw : 3;

    if (formId.length > 0) {
      WidgetSync.shared.registerForm(formId, dimension, this.context);
    }
    return formBindingData.createFormBindingData(WidgetSync.shared.currentPayload(dimension));
  }

  onUpdateForm(formId: string): void {
    WidgetSync.shared.bindUpdater(pushForms);
    WidgetSync.shared.refreshForm(formId, this.context);
  }

  onRemoveForm(formId: string): void {
    WidgetSync.shared.unregisterForm(formId, this.context);
  }

  onAcquireFormState(_want: Want): formInfo.FormState {
    return formInfo.FormState.READY;
  }
}
