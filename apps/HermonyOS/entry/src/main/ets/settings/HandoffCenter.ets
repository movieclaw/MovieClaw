import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import {
  HandoffPromptView,
  HandoffRequest,
  LlmModelOptionView,
  SessionMessageAcceptedView,
  SessionStartPayload
} from '../api/Models';

/**
 * 「交给 AI 分析」（对应 iOS `ActivityHandoffButton` / Web 的 `HandoffButton`）。
 *
 * 产品语义照 iOS：每条待处理事项有**两个出口**——第一个是确定性的（去处理 / 重试 / 删除），
 * 这个按钮负责「**不知道该怎么办**」：工单由**后端带着现场自检组装**（前端不拼），
 * 起会话后跳到会话页。**未接入模型时整个不渲染**。
 *
 * 流程是**两步**（iOS 那边也是两步，只是包在一个方法里）：
 * 1. `sessionHandoffPrompt({kind, ref})` → `{title, prompt}`：后端组装诊断工单；
 * 2. `sessionStart({content: prompt})` → `{session_id}`：把工单当成会话的**首条用户消息**提交。
 *
 * **鸿蒙这边还差最后一段**：没有 AI 会话页（`ChatPage`），所以起完会话没地方读。
 * 本模块先做到「工单能生成、会话能起」，并把工单内容摊给用户看；
 * 会话页是独立的一大块（流式消息、工具调用展示、附件…），留到之后。
 */
export class HandoffCenter {
  private static available: boolean = false;
  private static checked: boolean = false;

  /**
   * 有没有接入模型。**没接入就整个不渲染**——给一个点了必然失败的按钮比不给更糟。
   * 结果缓存：这是「配置」而不是「状态」，一次会话里不会变。
   */
  static async ensureChecked(api: MovieClawApi): Promise<boolean> {
    if (HandoffCenter.checked) {
      return HandoffCenter.available;
    }
    try {
      const options: LlmModelOptionView[] = await api.llmModels();
      HandoffCenter.available = options.length > 0;
    } catch (error) {
      HandoffCenter.available = false;
    }
    HandoffCenter.checked = true;
    return HandoffCenter.available;
  }

  static isAvailable(): boolean {
    return HandoffCenter.available;
  }
}

/** 一次交接的结果：工单内容 + 起好的会话 id（会话页还没做，先拿在手里） */
export class HandoffResult {
  readonly title: string;
  readonly prompt: string;
  readonly sessionId: string;

  constructor(title: string, prompt: string, sessionId: string) {
    this.title = title;
    this.prompt = prompt;
    this.sessionId = sessionId;
  }
}

/**
 * 执行一次交接。
 *
 * `kind` 取值与后端一致：`notice`（ref = 告警 id）/ `download`（ref = info_hash）/ `job`（ref = 任务 id）。
 */
export async function runHandoff(api: MovieClawApi, kind: string, ref: string): Promise<HandoffResult> {
  const request: HandoffRequest = { kind: kind, ref: ref };
  const ticket: HandoffPromptView = await api.sessionHandoffPrompt(request);
  const payload: SessionStartPayload = { content: ticket.prompt };
  const accepted: SessionMessageAcceptedView = await api.sessionStart(payload);
  return new HandoffResult(ticket.title, ticket.prompt, accepted.session_id);
}

/** 交接失败的统一文案（把后端的话透出来，别自己编） */
export function handoffMessage(error: Object): string {
  if (error instanceof ApiError) {
    return error.message.length > 0 ? error.message : `发起失败（${error.status}）`;
  }
  const text: string = `${error}`;
  return text.length > 0 ? text : '无法发起 AI 分析';
}
