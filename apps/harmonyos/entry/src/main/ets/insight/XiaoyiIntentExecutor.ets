import { InsightIntentExecutor, insightIntent } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { ContinuationBridge, ContinuationTarget } from '../common/ContinuationBridge';
import { DevConfig } from '../common/DevConfig';
import { intentToContinuationTarget } from './XiaoyiIntentModel';

export { intentToContinuationTarget };

/**
 * 小艺意图框架统一执行器（`insight_intent.json` 唯一 `srcEntry`，禁止 ArkGuard 混淆）：
 * 冷启动时先确保主窗口内容挂载，再将解析出的意图压入 `ContinuationBridge` 待执行槽位。
 */
export default class XiaoyiIntentExecutor extends InsightIntentExecutor {
  async onExecuteInUIAbilityForegroundMode(
    name: string,
    param: Record<string, Object>,
    pageLoader: window.WindowStage
  ): Promise<insightIntent.ExecuteResult> {
    const target: ContinuationTarget = intentToContinuationTarget(name, param);
    ContinuationBridge.shared().handOff(target);

    try {
      const isCar: boolean = deviceInfo.deviceType === 'car';
      const isTv: boolean = deviceInfo.deviceType === 'tv' || DevConfig.forceTvMode;
      const entryPage: string = isCar ? 'car/CarIndex' : (isTv ? 'tv/TvIndex' : 'pages/Index');
      await pageLoader.loadContent(entryPage);
    } catch (_err) {
      // 已挂载主窗口时保持既有栈，由 @Monitor('continuation.pendingSeq') 即时消费
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
