import { InsightIntentExecutor, insightIntent } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { ContinuationBridge, ContinuationTarget } from '../common/ContinuationBridge';
import { DevConfig } from '../common/DevConfig';
import EntryAbility from '../entryability/EntryAbility';
import { intentToContinuationTarget } from './XiaoyiIntentModel';

export { intentToContinuationTarget };

/**
 * 小艺意图框架统一执行器（`insight_intent.json` 唯一 `srcEntry`，禁止 ArkGuard 混淆）：
 * 冷启动时仅在主窗口尚未挂载时加载根页，热/温启动保持既有页面栈，由 `ContinuationBridge` 即时消费意图。
 */
export default class XiaoyiIntentExecutor extends InsightIntentExecutor {
  async onExecuteInUIAbilityForegroundMode(
    name: string,
    param: Record<string, Object>,
    pageLoader: window.WindowStage
  ): Promise<insightIntent.ExecuteResult> {
    const target: ContinuationTarget = intentToContinuationTarget(name, param);
    ContinuationBridge.shared().handOff(target);

    if (!EntryAbility.contentLoaded) {
      try {
        const isCar: boolean = deviceInfo.deviceType === 'car';
        const isTv: boolean = deviceInfo.deviceType === 'tv' || DevConfig.forceTvMode;
        const entryPage: string = isCar ? 'car/CarIndex' : (isTv ? 'tv/TvIndex' : 'pages/Index');
        await pageLoader.loadContent(entryPage);
        EntryAbility.contentLoaded = true;
      } catch (_err) {
      }
    }

    const resultPayload: Record<string, Object> = {
      'intentName': name,
      'targetKind': target.kind
    };
    const res: insightIntent.ExecuteResult = {
      code: 0,
      result: resultPayload
    };
    return res;
  }
}
