import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { Theme } from '../theme/AppTheme';
import { PageTopBar } from '../common/PageTopBar';
import { ShellChrome } from '../common/ShellChrome';
import { AppModel } from '../common/AppModel';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { EventStream, ServerEvent, StreamHandle } from '../common/EventStream';
import {
  LlmModelOptionView,
  SessionMessageAcceptedView,
  SessionRetryPayload,
  SessionStartPayload,
  SkillView,
  SessionSummary,
  SessionTranscriptView
} from '../api/Models';
import { JsonValue } from '../api/JsonValue';
import { LibraryRouteParams } from '../library/LibraryDetailPage';
import { ItemRouteParams } from '../library/LibraryItemDetailPage';
import { DiscoverDetailParams } from '../discover/DiscoverDetailPage';
import { SubscriptionParams } from '../subscriptions/SubscriptionDetailPage';
import {
  AgentHandoff,
  AgentStreamEvent,
  AgentTimeline,
  AgentTurn
} from './AgentTimeline';
import { AgentRow, AgentTranscriptLayout } from './AgentTranscriptRows';
import { AgentSkillText, AgentSlashQuery } from './AgentSkills';
import { AgentAttachment, AgentAttachments } from './AgentAttachments';
import { AgentSessionsSignal } from './AgentSessionsSignal';
import { AgentCatalog, AgentThinking } from './AgentCatalog';
import { AgentMediaCardSpec, AgentMediaCardsBlockView } from './AgentMediaCards';
import { AgentMarkdownBlocksView } from './AgentMarkdownViews';
import {
  AgentCompactionCardView,
  AgentHandoffCardView,
  AgentProcessBlockView,
  AgentStreamingCursorView,
  AgentTurnErrorView,
  AgentTurnFooterView,
  AgentUserBubbleView
} from './AgentTurnViews';

/** 路由表注册用（router_map.json 的 buildMethod） */
@Builder
export function ChatBuilder() {
  ChatPage()
}

/** 会话页的路由参数（会序列化，不要用 instanceof） */
export class ChatParams {
  readonly sessionId: string;

  constructor(sessionId: string) {
    this.sessionId = sessionId;
  }

  static of(param: Object | undefined | null): ChatParams | null {
    if (param === undefined || param === null) {
      // 没带参数也是「新会话」
      return new ChatParams('');
    }
    const raw: ChatParams = param as ChatParams;
    const id: string = raw.sessionId;
    // 空 id 合法：表示**新会话**（同 iOS `.newSession`）——会话在第一条消息时才由服务端建出来
    if (id === undefined || id === null) {
      return new ChatParams('');
    }
    return new ChatParams(id);
  }
}

/** Transcript 列表的 LazyForEach 数据源（只建可视区附近的行） */
class AgentRowSource implements IDataSource {
  private rows: AgentRow[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): AgentRow {
    return this.rows[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const at: number = this.listeners.indexOf(listener);
    if (at >= 0) {
      this.listeners.splice(at, 1);
    }
  }

  setRows(rows: AgentRow[]): void {
    this.rows = rows;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }
}

/**
 * AI 会话页（对应 iOS `AgentConversationView` 那一套）。
 *
 * **显示对齐 iOS**：消息列按「轮次 → 段 → 块」拆行渲染（见 `AgentTranscriptRows`）——
 * 用户右侧气泡、Agent 整栏 Markdown 正文不套气泡、思考与工具调用收进「处理过程」折叠块、
 * 压缩/续接/错误卡片、轮次页脚（耗时 + 复制）、流式光标、`show_media_cards` 生成式卡片。
 *
 * **真流式（SSE）**：接 `/sessions/{id}/events`，事件按 iOS 的归约规则合进当前轮次
 * （`AgentTimeline.applyEvent`）——text/thinking 增量并入末尾段、工具事件建/补工具条目；
 * 事件按 80ms 合并应用一次（同 iOS 的批量），终态立即冲刷。
 * 断线按事件序号（`Last-Event-ID`）续传，HTTP 错误结束跟随。
 */
@ComponentV2
export struct ChatPage {
  private navStack: NavPathStack = new NavPathStack();
  private chrome: ShellChrome = ShellChrome.shared;
  private started: boolean = false;
  private sessionId: string = '';

  /** 「＋」面板：每次打开现拉技能清单（服务端改技能即生效，同 iOS） */
  private async loadSkillsForMenu(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      this.skills = await api.skillsList();
    } catch (error) {
      this.skills = [];
    }
  }

  /** 可选模型清单（同 iOS `AgentCatalog.modelOptions`：一分钟内不重复请求） */
  private loadModels(): void {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    AgentCatalog.modelOptions(api).then((list: LlmModelOptionView[]): void => {
      this.models = list;
    }).catch((): void => {
    });
  }

  // MARK: 事件流句柄与定时器（页面消失/停止必须全清）
  private stream: StreamHandle | null = null;
  private rowSource: AgentRowSource = new AgentRowSource();
  private scroller: Scroller = new Scroller();
  /** 已确认到的事件序号游标（Last-Event-ID 续传用） */
  private lastId: number = 0;
  /** 断线重连退避（ms），0.5 起、最长 5s */
  private retryDelay: number = 500;
  private retryTimer: number = -1;
  /** 事件批量合并（80ms）与待应用队列 */
  private flushTimer: number = -1;
  private pending: AgentStreamEvent[] = [];
  /** 事件归约到哪一轮（乐观轮次在服务端受理前用本地 id） */
  private streamTurnId: string = '';
  private localSeq: number = 0;
  /** 进入会话后的贴底期：内容边渲染边长高，这段时间一直锚在底部 */
  private pinnedToBottom: boolean = true;
  private pinTimer: number = -1;
  /** 贴底连打：懒加载列表一次跳不到真底部（行高要边渲染边量），连打几次直到稳定 */
  private stickTimer: number = -1;
  private stickCount: number = 0;

  @Local private turns: AgentTurn[] = [];
  @Local private handoff: AgentHandoff | null = null;
  @Local private title: string = '会话';
  @Local private running: boolean = false;
  @Local private loading: boolean = true;
  @Local private failed: boolean = false;
  @Local private errorMessage: string = '';
  @Local private draft: string = '';
  @Local private sending: boolean = false;
  @Local private nearBottom: boolean = true;
  /** 已知技能名（小写）；空 = 名单还没回来（气泡不过滤 token） */
  @Local private knownSkills: string[] = [];
  /** 正在改写的提问（messageId）；空 = 普通追问 */
  @Local private editTarget: string = '';
  @Local private editSeed: string = '';
  @Local private retrying: boolean = false;
  /** 可选模型清单（空 = 拿不到/没接入，不显示模型胶囊） */
  @Local private models: LlmModelOptionView[] = [];
  /** 输入区工具行的弹层（'model' = 模型+档位 / 'plus' = 使用技能）。
   *  **同一个组件上只能挂一个 `bindSheet`**：挂两个时只有最后那个生效（实测模型面板因此点不开） */
  @Local private showComposerSheet: boolean = false;
  @Local private sheetKind: string = '';
  @Local private skills: SkillView[] = [];
  /** 待发送的图片附件（上传成功的才进托盘，同 iOS `draft.images`） */
  @Local private attachments: AgentAttachment[] = [];
  @Local private uploading: number = 0;
  @Local private uploadError: string = '';
  /** 「/」技能快选（同 iOS `slashActive` / `slashMatches`） */
  @Local private slashActive: boolean = false;
  @Local private slashMatches: SkillView[] = [];
  private slashStart: number = -1;
  /**
   * 输入法高度（vp）。沉浸式布局（`setWindowLayoutFullScreen(true)`）下系统不再替我们避让，
   * 键盘会直接盖住输入区下半截（实测「发送」和工具行被盖住），所以自己监听键盘高度往上顶。
   */
  @Local private keyboardInset: number = 0;
  private keyboardWindow: window.Window | null = null;
  /** 有没有动过模型/档位选择（没动过就不传，服务端沿用上一条；动过但选「默认」传 default） */
  @Local private modelTouched: boolean = false;
  @Local private modelValue: string = '';
  @Local private thinkingTouched: boolean = false;
  @Local private thinkingValue: string = '';

  aboutToAppear(): void {
    this.pinTimer = setTimeout((): void => {
      this.pinTimer = -1;
      this.pinnedToBottom = false;
    }, 1500);
    this.loadSkills();
    this.loadModels();
    this.observeKeyboard();
  }

  /** 监听输入法高度：弹出把输入区顶上去，收起还原（同 iOS 贴键盘） */
  private observeKeyboard(): void {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    window.getLastWindow(context).then((win: window.Window): void => {
      this.keyboardWindow = win;
      win.on('keyboardHeightChange', (height: number): void => {
        this.keyboardInset = height > 0 ? px2vp(height) : 0;
        if (this.nearBottom || this.pinnedToBottom) {
          this.startStick();
        }
      });
    }).catch((): void => {
    });
  }

  aboutToDisappear(): void {
    this.chrome.pop('chat');
    this.closeStream();
    // 离开会话页：「我的」页的「最近会话」要被通知重拉（新会话 / 标题变化都在这一趟里发生）
    AgentSessionsSignal.shared.bump();
    if (this.keyboardWindow !== null) {
      this.keyboardWindow.off('keyboardHeightChange');
      this.keyboardWindow = null;
    }
    if (this.pinTimer >= 0) {
      clearTimeout(this.pinTimer);
      this.pinTimer = -1;
    }
    if (this.stickTimer >= 0) {
      clearTimeout(this.stickTimer);
      this.stickTimer = -1;
    }
  }

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  /** 技能清单（气泡判断「哪些 token 是已知技能」用；失败不影响主流程） */
  private async loadSkills(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      const list = await api.skillsList();
      const names: string[] = [];
      for (const skill of list) {
        const name: string = skill.name;
        if (name !== undefined && name !== null && name.length > 0) {
          names.push(name.toLowerCase());
        }
      }
      this.knownSkills = names;
    } catch (error) {
      // 名单拿不到就不过滤：token 原样显示，不影响会话
    }
  }

  // MARK: 事件流

  /** 关掉流句柄与全部定时器（页面消失 / 停止任务时调）。 */
  private closeStream(): void {
    if (this.stream !== null) {
      this.stream.close();
      this.stream = null;
    }
    if (this.retryTimer >= 0) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    if (this.flushTimer >= 0) {
      clearTimeout(this.flushTimer);
      this.flushTimer = -1;
    }
    this.pending = [];
  }

  /** 打开 `/sessions/{id}/events`；带 Last-Event-ID 续传。 */
  private startStream(): void {
    if (this.stream !== null) {
      return;
    }
    const client = AppModel.shared.client;
    if (client === null || this.sessionId.length === 0) {
      return;
    }
    const es = new EventStream(client.origin, client.getToken());
    const last: string | undefined = this.lastId > 0 ? String(this.lastId) : undefined;
    const self = this;
    this.stream = es.open(`/sessions/${this.sessionId}/events`,
      { lastEventId: last },
      {
        onEvent: (ev: ServerEvent): void => {
          self.onStreamEvent(ev);
        },
        onError: (err: ApiError): void => {
          self.onStreamError(err);
        },
        onEnd: (): void => {
          self.onStreamEnd();
        }
      });
  }

  /** 一条 SSE 事件：按序号过滤重放/心跳，推进游标；解码失败也推进游标（iOS 语义） */
  private onStreamEvent(ev: ServerEvent): void {
    if (ev.id === null || ev.id.length === 0) {
      return; // 注释心跳没有 id
    }
    const seq: number = Number(ev.id);
    if (!Number.isFinite(seq) || seq <= this.lastId) {
      return; // 重放的旧事件跳过
    }
    this.lastId = Math.trunc(seq);
    this.retryDelay = 500;

    const event: AgentStreamEvent | null = AgentStreamEvent.parse(ev.data);
    if (event === null) {
      return; // 解码失败：游标已推进，静默跳过
    }
    this.pending.push(event);
    if (event.terminal()) {
      this.flushEvents();
      this.finishStream();
      return;
    }
    if (this.flushTimer < 0) {
      this.flushTimer = setTimeout((): void => {
        this.flushTimer = -1;
        this.flushEvents();
      }, 80);
    }
  }

  /** 把缓冲的事件归约进当前轮次（同 iOS `flush`） */
  private flushEvents(): void {
    if (this.pending.length === 0) {
      return;
    }
    const target: AgentTurn | null = this.turnById(this.streamTurnId);
    if (target !== null) {
      for (const event of this.pending) {
        AgentTimeline.applyEvent(target, event);
      }
    }
    this.pending = [];
    this.rebuildRows();
  }

  /** 本轮结束：收尾并重拉轨迹（拿服务端权威结果与可能的自动命名） */
  private finishStream(): void {
    this.closeStream();
    this.running = false;
    this.load(true).then((): void => {
      this.scrollToBottom(true);
    }).catch((): void => {
    });
  }

  /** HTTP 错误结束跟随（404 特判）；网络错误退避重连。流的 401 不踢会话，只当普通错误。 */
  private onStreamError(err: ApiError): void {
    if (err.status > 0) {
      const target: AgentTurn | null = this.turnById(this.streamTurnId);
      const message: string = err.status === 404
        ? '运行记录不存在或已过期，可能是服务已重启，请重新发起任务'
        : (err.message.length > 0 ? err.message : `请求失败（${err.status}）`);
      this.closeStream();
      this.running = false;
      if (target !== null) {
        target.status = 'error';
        target.error = message;
      }
      this.rebuildRows();
    } else {
      // 网络错误：保留游标，退避后带 Last-Event-ID 重连
      this.scheduleReconnect();
    }
  }

  /** 流正常结束：仍在跑说明是意外断开，重连；否则收尾。 */
  private onStreamEnd(): void {
    if (this.running) {
      this.scheduleReconnect();
    } else {
      this.closeStream();
    }
  }

  private scheduleReconnect(): void {
    if (this.stream !== null) {
      this.stream.close();
      this.stream = null;
    }
    if (this.retryTimer >= 0) {
      clearTimeout(this.retryTimer);
    }
    const delay: number = this.retryDelay;
    this.retryTimer = setTimeout((): void => {
      this.retryTimer = -1;
      this.retryDelay = Math.min(this.retryDelay * 2, 5000);
      if (this.running) {
        this.startStream();
      }
    }, delay);
  }

  private turnById(id: string): AgentTurn | null {
    for (const turn of this.turns) {
      if (turn.id === id) {
        return turn;
      }
    }
    return this.turns.length > 0 ? this.turns[this.turns.length - 1] : null;
  }

  // MARK: 加载

  private async load(silent: boolean = false): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.sessionId.length === 0) {
      return;
    }
    if (!silent) {
      this.loading = true;
    }
    try {
      const view: SessionTranscriptView = await api.sessionGetTranscript(this.sessionId);
      this.applyTranscript(view);
      this.failed = false;
      this.errorMessage = '';
    } catch (error) {
      // 轮询/流期间的静默失败不打扰，只在首次加载时报
      if (!silent) {
        this.failed = true;
        this.errorMessage = this.messageOf(error);
      }
    } finally {
      this.loading = false;
      // running 期间接上事件流（已在跟就不重连）
      if (this.running && this.stream === null) {
        if (this.streamTurnId.length === 0 && this.turns.length > 0) {
          this.streamTurnId = this.turns[this.turns.length - 1].id;
        }
        this.startStream();
      }
    }
  }

  private applyTranscript(view: SessionTranscriptView): void {
    const session: SessionSummary = view.session;
    const entries: JsonValue[] = view.entries as JsonValue[];
    const running: boolean = session.running;
    const transcript = AgentTimeline.parse(entries, running, this.titleOf(session));
    this.turns = transcript.turns;
    this.handoff = transcript.handoff;
    this.title = transcript.title;
    this.running = running;
    if (running && this.turns.length > 0 && this.streamTurnId.length === 0) {
      this.streamTurnId = this.turns[this.turns.length - 1].id;
    }
    this.rebuildRows();
    this.startStick();
  }

  private titleOf(session: SessionSummary): string {
    const title: string = session.title ?? '';
    if (title.length > 0) {
      return title;
    }
    const prompt: string = session.last_prompt ?? '';
    if (prompt.length > 0) {
      return prompt;
    }
    return '未命名会话';
  }

  private rebuildRows(): void {
    const rows: AgentRow[] = AgentTranscriptLayout.rows(this.turns, this.handoff, this.running);
    this.rowSource.setRows(rows);
    if ((this.nearBottom || this.pinnedToBottom) && this.stickTimer < 0) {
      this.stickCount = 0;
      this.pumpStick();
    }
  }

  /**
   * 贴底期：内容边渲染边长高，一次 `scrollToIndex` 跳不到真底部（懒加载只量到可视区附近），
   * 连打几次直到高度稳定。用户一拖动就结束贴底，之后回到「贴近底部才跟随」。
   */
  private startStick(): void {
    this.nearBottom = true;
    this.pinnedToBottom = true;
    this.stickCount = 0;
    if (this.stickTimer >= 0) {
      clearTimeout(this.stickTimer);
      this.stickTimer = -1;
    }
    this.pumpStick();
  }

  private pumpStick(): void {
    if (this.stickCount > 8) {
      return;
    }
    this.stickCount += 1;
    this.scrollToBottom(false);
    this.stickTimer = setTimeout((): void => {
      this.stickTimer = -1;
      this.pumpStick();
    }, 70);
  }

  private scrollToBottom(animated: boolean): void {
    const total: number = this.rowSource.totalCount();
    if (total === 0) {
      return;
    }
    this.scroller.scrollToIndex(total - 1, !animated, ScrollAlign.END);
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '加载失败';
  }

  // MARK: 动作

  private async send(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const content: string = this.draft.trim();
    if (api === null || this.sending || this.uploading > 0) {
      return;
    }
    if (content.length === 0 && this.attachments.length === 0) {
      return;
    }
    if (this.editTarget.length > 0) {
      await this.submitRetry(api, content);
      return;
    }
    this.sending = true;
    const turnId: string = `local-${Date.now()}-${this.localSeq}`;
    this.localSeq += 1;
    const turn: AgentTurn = new AgentTurn(turnId, '', content, [], 'running', Date.now());
    this.turns.push(turn);
    this.streamTurnId = turnId;
    this.running = true;
    this.draft = '';
    this.nearBottom = true;
    this.pinnedToBottom = true;
    this.lastId = 0;
    this.retryDelay = 500;
    this.rebuildRows();
    try {
      const payload: SessionStartPayload = {
        content: content
      };
      // **新会话不能带空 session_id**：服务端校验要求它是合法会话号（实测空串直接 422
      // 「body.session_id String should have...」）。没有 id 就整条不带，服务端据此建新会话。
      if (this.sessionId.length > 0) {
        payload.session_id = this.sessionId;
      }
      if (this.attachments.length > 0) {
        const ids: string[] = [];
        for (const attachment of this.attachments) {
          ids.push(attachment.attachmentId);
        }
        payload.attachments = ids;
      }
      const model: string | null = this.wire(this.modelTouched, this.modelValue);
      if (model !== null) {
        payload.model = model;
      }
      const thinking: string | null = this.wire(this.thinkingTouched, this.thinkingValue);
      if (thinking !== null) {
        payload.thinking_level = thinking;
      }
      const accepted: SessionMessageAcceptedView = await api.sessionStart(payload);
      // 新会话（进来时没有 id）：服务端这时候才给出 session_id，接上它再开事件流
      if (this.sessionId.length === 0 && accepted.session_id.length > 0) {
        this.sessionId = accepted.session_id;
        // 新建了会话：列表页立刻知道（用户可能直接切页签走，不走 aboutToDisappear）
        AgentSessionsSignal.shared.bump();
      }
      turn.messageId = accepted.message_id;
      this.attachments = [];
      this.uploadError = '';
      this.startStream();
    } catch (error) {
      turn.status = 'error';
      turn.error = this.messageOf(error);
      this.running = false;
      this.rebuildRows();
    } finally {
      this.sending = false;
    }
  }

  /** 改写重问：确认后服务端一次完成「丢弃旧轨迹 + 提交新问题」，成功后本地替换时间线 */
  private async submitRetry(api: MovieClawApi, content: string): Promise<void> {
    const messageId: string = this.editTarget;
    let index: number = -1;
    for (let i = 0; i < this.turns.length; i++) {
      if (this.turns[i].messageId === messageId) {
        index = i;
        break;
      }
    }
    if (index < 0) {
      this.toast('这条提问已不在当前会话里');
      this.cancelEdit();
      return;
    }
    const confirmed: boolean = await this.confirm('重新提交这条提问？',
      '这条提问及其之后的对话会被新问题替换，原记录无法恢复。', '替换并重新提问');
    if (!confirmed) {
      return;
    }
    this.retrying = true;
    try {
      const payload: SessionRetryPayload = {
        message_id: messageId,
        content: content
      };
      const model: string | null = this.wire(this.modelTouched, this.modelValue);
      if (model !== null) {
        payload.model = model;
      }
      const thinking: string | null = this.wire(this.thinkingTouched, this.thinkingValue);
      if (thinking !== null) {
        payload.thinking_level = thinking;
      }
      const accepted: SessionMessageAcceptedView = await api.sessionRetry(this.sessionId, payload);
      const turnId: string = `local-${Date.now()}-${this.localSeq}`;
      this.localSeq += 1;
      const original: AgentTurn = this.turns[index];
      const turn: AgentTurn = new AgentTurn(turnId, accepted.message_id, content, original.images,
        'running', Date.now());
      this.turns = this.turns.slice(0, index).concat([turn]);
      this.streamTurnId = turnId;
      this.running = true;
      this.draft = '';
      this.editTarget = '';
      this.editSeed = '';
      this.nearBottom = true;
      this.pinnedToBottom = true;
      this.lastId = 0;
      this.retryDelay = 500;
      this.rebuildRows();
      this.startStream();
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.retrying = false;
    }
  }

  /** 线上值：没动过不传（服务端沿用）；显式默认传 'default' */
  private wire(touched: boolean, value: string): string | null {
    if (!touched) {
      return null;
    }
    return value.length === 0 ? 'default' : value;
  }

  /** 会话当前生效的模型 / 档位 = 最近一轮有值的轨迹信封值（同 iOS `turns.last(where:)`） */
  private sessionModel(): string {
    for (let i = this.turns.length - 1; i >= 0; i--) {
      if (this.turns[i].modelRef.length > 0) {
        return this.turns[i].modelRef;
      }
    }
    return '';
  }

  private sessionThinking(): string {
    for (let i = this.turns.length - 1; i >= 0; i--) {
      if (this.turns[i].thinkingLevel.length > 0) {
        return this.turns[i].thinkingLevel;
      }
    }
    return '';
  }

  private displayedModel(): string {
    return this.modelTouched ? this.modelValue : this.sessionModel();
  }

  private displayedThinking(): string {
    return this.thinkingTouched ? this.thinkingValue : this.sessionThinking();
  }

  /** 当前生效模型的档位菜单（决定控件长相） */
  private thinkingStops(): string[] {
    const hit: LlmModelOptionView | null = AgentCatalog.resolve(this.models, this.displayedModel());
    return hit === null ? [] : AgentThinking.stops(hit.thinking_levels);
  }

  /** 进入改写态：把原文放进输入框（同 iOS `retryTarget` + `draft.load`） */
  private startEdit(messageId: string, input: string): void {
    if (this.running || this.retrying || messageId.length === 0) {
      return;
    }
    this.editTarget = messageId;
    this.editSeed = AgentSkillText.toTokenForm(input);
    this.draft = this.editSeed;
  }

  private cancelEdit(): void {
    this.editTarget = '';
    this.editSeed = '';
    this.draft = '';
  }

  private confirm(title: string, message: string, confirmTitle: string): Promise<boolean> {
    return new Promise<boolean>((resolve: (value: boolean) => void): void => {
      this.getUIContext().showAlertDialog({
        title: title,
        message: message,
        primaryButton: {
          value: confirmTitle,
          fontColor: Theme.danger,
          action: (): void => {
            resolve(true);
          }
        },
        secondaryButton: {
          value: '取消',
          action: (): void => {
            resolve(false);
          }
        },
        cancel: (): void => {
          resolve(false);
        }
      });
    });
  }

  private confirmStop(): void {
    this.getUIContext().showAlertDialog({
      title: '停止',
      message: '让 AI 停下当前这一轮？已经说过的内容会保留。',
      primaryButton: {
        value: '继续跑',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '停止',
        action: (): void => {
          this.stop();
        }
      }
    });
  }

  private async stop(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    // 真正终态由事件流 / 重拉 transcript 确认，不在这里伪造
    try {
      await api.sessionStop(this.sessionId);
      this.toast('已发送停止请求');
    } catch (error) {
      this.toast(this.messageOf(error));
    }
  }

  // MARK: 链接与卡片跳转

  /** 正文里的链接：站内（相对路径 / 本站）走原生路由，外链交给系统浏览器 */
  private openLink(url: string): void {
    if (url.length === 0) {
      return;
    }
    if (url.startsWith('/sessions/')) {
      const rest: string = url.substring('/sessions/'.length);
      const id: string = rest.split('?')[0];
      if (id.length > 0) {
        this.navStack.pushPathByName('chat', new ChatParams(id));
      }
      return;
    }
    let target: string = url;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      target = `${AppModel.origin()}${url.startsWith('/') ? url : `/${url}`}`;
    }
    const context: common.UIAbilityContext = getContext() as common.UIAbilityContext;
    context.openLink(target).catch((): void => {
      this.toast('打不开链接');
    });
  }

  /** 生成式 UI 卡片：点卡进对应产品页（与发现页 / 媒体库页同一条路由） */
  private openCard(spec: AgentMediaCardSpec, libraryId: number): void {
    if (spec.kind === 'library') {
      this.navStack.pushPathByName('libraryDetail', new LibraryRouteParams(spec.libraryId));
      return;
    }
    if (spec.kind === 'title') {
      this.navStack.pushPathByName('discoverDetail', new DiscoverDetailParams(spec.titleRef));
      return;
    }
    if (spec.kind === 'subscription') {
      this.navStack.pushPathByName('subscriptionDetail', new SubscriptionParams(spec.subscriptionId));
      return;
    }
    if (libraryId > 0) {
      this.navStack.pushPathByName('libraryItem', new ItemRouteParams(libraryId, spec.mediaItemId,
        spec.season >= 0 ? spec.season : null, spec.episode > 0 ? spec.episode : null));
    }
  }

  // MARK: 视图

  build() {
    NavDestination() {
      Column() {
        // 自绘顶栏：原生标题栏在沉浸式布局下不避让状态栏（会压住时钟、返回键上半截点不动）
        PageTopBar({ title: this.title, onBack: (): void => {
          this.navStack.pop();
        }})
        if (this.failed) {
          this.ErrorState()
        } else if (this.loading && this.turns.length === 0) {
          this.LoadingState()
        } else {
          this.Transcript()
        }
        this.Composer()
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg)
      .bindSheet($$this.showComposerSheet, this.ComposerSheet(), {
        height: SheetSize.FIT_CONTENT,
        dragBar: true,
        showClose: false,
        backgroundColor: Theme.bg
      })
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
      // 整屏页：收起底部标签栏（iOS 同款行为）
      this.chrome.push('chat');
      const params: ChatParams | null = ChatParams.of(ctx.pathInfo.param as Object | undefined);
      if (params !== null && !this.started) {
        this.started = true;
        this.sessionId = params.sessionId;
        if (this.sessionId.length === 0) {
          // 新会话：还没有 id，先给空会话的首屏（标题「新会话」），发第一条消息时才建
          this.title = '新会话';
          this.loading = false;
        } else {
          this.load();
        }
      }
    })
  }

  @Builder
  LoadingState() {
    Column({ space: 10 }) {
      LoadingProgress().width(24).height(24).color(Theme.textMuted)
      Text('正在加载会话…').fontSize(13).fontColor(Theme.textFaint)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  ErrorState() {
    Column({ space: 10 }) {
      Text('无法打开会话').fontSize(16).fontColor(Theme.text)
      Text(this.errorMessage).fontSize(14).fontColor(Theme.textMuted).textAlign(TextAlign.Center)
      Text('重试').fontSize(14).fontColor(Theme.accentStrong).onClick((): void => {
        this.load();
      })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding({ left: 24, right: 24 })
  }

  @Builder
  Transcript() {
    Stack({ alignContent: Alignment.Bottom }) {
      List({ scroller: this.scroller }) {
        LazyForEach(this.rowSource, (row: AgentRow) => {
          ListItem() {
            this.RowView(row)
          }
          .padding({ top: row.spacing })
        }, (row: AgentRow): string => row.id)
      }
      .layoutWeight(1)
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .cachedCount(6)
      .padding({ left: 16, right: 16, top: 12, bottom: 16 })
      .onScrollIndex((start: number, end: number): void => {
        const total: number = this.rowSource.totalCount();
        this.nearBottom = total === 0 || end >= total - 2;
        if (!this.nearBottom) {
          this.pinnedToBottom = false;
        }
      })
      // 输入法弹出/收起会改变列表高度：贴底时跟着重新贴底（同 iOS 贴底跟随）
      .onAreaChange((oldValue: Area, newValue: Area): void => {
        if (this.nearBottom || this.pinnedToBottom) {
          this.startStick();
        }
      })

      if (!this.nearBottom) {
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_down'))
            .fontSize(15)
            .fontColor([Theme.text])
        }
        .width(36)
        .height(36)
        .justifyContent(FlexAlign.Center)
        .backgroundColor('rgba(30, 30, 34, 0.9)')
        .borderRadius(18)
        .border({ width: 1, color: Theme.line })
        .margin({ bottom: 12 })
        .onClick((): void => {
          this.nearBottom = true;
          this.scrollToBottom(true);
        })
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  /** 一行分派（对应 iOS `AgentTranscriptRowView` 的 switch） */
  @Builder
  RowView(row: AgentRow) {
    if (row.kind === 'handoff' && row.handoff !== null) {
      AgentHandoffCardView({
        sourceId: row.handoff.sourceId,
        sourceTitle: row.handoff.sourceTitle,
        onOpenSource: (): void => {
          this.navStack.pushPathByName('chat', new ChatParams(row.handoff!.sourceId));
        }
      })
    } else if (row.kind === 'question' && row.question !== null) {
      AgentUserBubbleView({
        text: row.question.input,
        sessionId: this.sessionId,
        knownSkills: this.knownSkills,
        canEdit: !this.running && !this.retrying,
        onEdit: (): void => {
          this.startEdit(row.question!.messageId, row.question!.input);
        }
      })
    } else if (row.kind === 'process') {
      AgentProcessBlockView({ items: row.processItems, active: row.active })
    } else if (row.kind === 'mediaCards' && row.group !== null) {
      AgentMediaCardsBlockView({
        group: row.group,
        onOpen: (spec: AgentMediaCardSpec, libraryId: number): void => {
          this.openCard(spec, libraryId);
        }
      })
    } else if (row.kind === 'markdown' && row.block !== null) {
      AgentMarkdownBlocksView({
        blocks: [row.block],
        textSize: AgentTimeline.TEXT_SIZE,
        onLink: (url: string): void => {
          this.openLink(url);
        }
      })
    } else if (row.kind === 'cursor') {
      AgentStreamingCursorView()
    } else if (row.kind === 'compaction' && row.compaction !== null) {
      AgentCompactionCardView({
        summary: row.compaction.summary,
        tokensBefore: row.compaction.tokensBefore,
        tokensAfter: row.compaction.tokensAfter
      })
    } else if (row.kind === 'error') {
      AgentTurnErrorView({ message: row.errorText })
    } else if (row.kind === 'footer' && row.footerTurn !== null) {
      AgentTurnFooterView({ turn: row.footerTurn })
    }
  }

  /**
   * 输入区（逐值照 iOS `AgentComposer`）：**一张圆角卡**里装
   * 「多行输入（最多 6 行）→ 工具行」，工具行 = ＋（图片/技能）· 模型（文字 + ▼）· 发送箭头；
   * 卡片外是页面底色，不是整条色带。
   */
  @Builder
  Composer() {
    Column({ space: 8 }) {
      if (this.editTarget.length > 0) {
        Row() {
          Text('正在改写较早的提问，发送后将替换其后的对话')
            .fontSize(12)
            .fontColor(Theme.textMuted)
            .layoutWeight(1)
          Text('取消改写')
            .fontSize(12)
            .fontColor(Theme.textFaint)
            .onClick((): void => {
              this.cancelEdit();
            })
        }
        .width('100%')
        .padding({ left: 8, right: 8 })
      }

      Column() {
        if (this.slashActive) {
          this.SlashMenu()
        }
        this.Tray()
        TextArea({ text: this.draft, placeholder: this.placeholderText() })
          .width('100%')
          .fontSize(15)
          .fontColor(Theme.text)
          .backgroundColor(Color.Transparent)
          .padding({ left: 16, right: 16, top: 14, bottom: 4 })
          .maxLines(6)
          .barState(BarState.Off)
          .enabled(!this.running)
          .onChange((value: string): void => {
            this.draft = value;
            this.refreshSlash();
          })

        Row({ space: 4 }) {
          // ＋：图片 / 技能（iOS 同一颗按钮出 popover）
          Row() {
            SymbolGlyph($r('sys.symbol.plus'))
              .fontSize(20)
              .fontColor([Theme.textMuted])
          }
          .width(44)
          .height(44)
          .justifyContent(FlexAlign.Center)
          .onClick((): void => {
            this.sheetKind = 'plus';
            this.showComposerSheet = true;
            this.loadSkillsForMenu();
          })

          if (this.models.length > 0) {
            Row({ space: 4 }) {
              Text(this.modelLabel())
                .fontSize(13)
                .fontColor(Theme.textMuted)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              SymbolGlyph($r('sys.symbol.chevron_down'))
                .fontSize(10)
                .fontColor([Theme.textMuted])
            }
            .constraintSize({ maxWidth: 200 })
            .height(44)
            .padding({ left: 10, right: 10 })
            .onClick((): void => {
              this.sheetKind = 'model';
              this.showComposerSheet = true;
            })
          }

          Blank()

          // 发送 / 停止（iOS：44×44 圆角 12、白 10% 底；停止时是一个小方块）
          Row() {
            if (this.running) {
              Row()
                .width(11)
                .height(11)
                .backgroundColor(Theme.text)
                .borderRadius(3)
            } else {
              SymbolGlyph($r('sys.symbol.arrow_right'))
                .fontSize(19)
                .fontWeight(FontWeight.Bold)
                .fontColor([Theme.text])
            }
          }
          .width(44)
          .height(44)
          .justifyContent(FlexAlign.Center)
          .backgroundColor('rgba(255, 255, 255, 0.1)')
          .borderRadius(12)
          .opacity(this.canSubmit() ? 1 : 0.4)
          .onClick((): void => {
            if (this.running) {
              this.confirmStop();
            } else if (this.canSubmit()) {
              this.send();
            }
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ left: 8, right: 8, bottom: 8 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .backgroundColor('rgba(255, 255, 255, 0.05)')
      .borderRadius(22)
      .border({ width: 1, color: 'rgba(255, 255, 255, 0.07)' })
    }
    .width('100%')
    // 键盘弹出时座位落在键盘上方（这时手势条已被键盘盖住）；否则让开小白条
    .padding({
      left: 12,
      right: 12,
      top: 8,
      bottom: this.keyboardInset > 0 ? 60 : 8 + Theme.safeBottomInset
    })
    .backgroundColor(Theme.bg)
  }

  /** 能不能发（同 iOS `canSubmit`：没在跑、没有上传中的图、草稿或图片非空） */
  private canSubmit(): boolean {
    if (this.running || this.uploading > 0) {
      return false;
    }
    return this.draft.trim().length > 0 || this.attachments.length > 0;
  }

  // MARK: 「/」技能快选

  /** 草稿变化时重算快选：命中候选才展开（同 iOS `.onChange(of: draft.text)`） */
  private refreshSlash(): void {
    const slash: AgentSlashQuery | null = AgentSkillText.slashQuery(this.draft);
    if (slash === null) {
      this.slashActive = false;
      this.slashMatches = [];
      this.slashStart = -1;
      return;
    }
    this.slashStart = slash.start;
    if (this.skills.length === 0) {
      this.loadSkillsForMenu();
    }
    this.slashMatches = AgentSkillText.slashMatches(slash.query, this.skills);
    this.slashActive = this.slashMatches.length > 0;
  }

  /** 选中一项：抹掉输入的查询串，把技能按 token 形态插到最前（同 iOS `pickSlash`） */
  private pickSlash(name: string): void {
    if (this.slashStart >= 0 && this.slashStart <= this.draft.length) {
      this.draft = this.draft.substring(0, this.slashStart);
    }
    this.insertSkill(name);
    this.slashActive = false;
    this.slashMatches = [];
    this.slashStart = -1;
  }

  @Builder
  SlashMenu() {
    Column({ space: 0 }) {
      Text('使用技能')
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .width('100%')
        .textAlign(TextAlign.Start)
        .padding({ left: 10, top: 6, bottom: 2 })
      List() {
        ForEach(this.slashMatches, (skill: SkillView) => {
          ListItem() {
            Column({ space: 2 }) {
              Text(skill.name)
                .fontSize(14)
                .fontColor(Theme.text)
                .width('100%')
                .textAlign(TextAlign.Start)
              if (skill.description.length > 0) {
                Text(skill.description)
                  .fontSize(12)
                  .fontColor(Theme.textFaint)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                  .textAlign(TextAlign.Start)
              }
            }
            .width('100%')
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .onClick((): void => {
              this.pickSlash(skill.name);
            })
          }
        }, (skill: SkillView): string => `slash-${skill.name}`)
      }
      .width('100%')
      .height(this.slashMatches.length > 4 ? 200 : this.slashMatches.length * 48)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .padding(6)
    .backgroundColor(Theme.surfaceRaised)
    .borderRadius(16)
    .margin({ left: 8, right: 8, top: 8 })
  }

  // MARK: 附件托盘

  /** 附件托盘：缩略图 + 文件名 + 移除；上传中/失败也在这条上交代（同 iOS `tray`） */
  @Builder
  Tray() {
    if (this.attachments.length > 0 || this.uploading > 0 || this.uploadError.length > 0) {
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.attachments, (attachment: AgentAttachment) => {
          Row({ space: 8 }) {
            Image(attachment.uri)
              .width(28)
              .height(28)
              .objectFit(ImageFit.Cover)
              .borderRadius(6)
              .backgroundColor('rgba(255, 255, 255, 0.08)')
            Text(attachment.name)
              .fontSize(12)
              .fontColor(Theme.textMuted)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: 110 })
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(11)
              .fontColor([Theme.textFaint])
              .onClick((): void => {
                const kept: AgentAttachment[] = [];
                for (const item of this.attachments) {
                  if (item.attachmentId !== attachment.attachmentId) {
                    kept.push(item);
                  }
                }
                this.attachments = kept;
              })
          }
          .padding(4)
          .backgroundColor('rgba(255, 255, 255, 0.05)')
          .borderRadius(8)
          .border({ width: 1, color: 'rgba(255, 255, 255, 0.06)' })
          .margin({ right: 8, bottom: 4 })
        }, (attachment: AgentAttachment): string => `att-${attachment.attachmentId}`)

        if (this.uploading > 0) {
          Row({ space: 6 }) {
            LoadingProgress().width(14).height(14).color(Theme.textFaint)
            Text('上传中…').fontSize(12).fontColor(Theme.textFaint)
          }
          .height(36)
          .padding({ left: 10, right: 10 })
          .backgroundColor('rgba(255, 255, 255, 0.05)')
          .borderRadius(8)
          .margin({ right: 8, bottom: 4 })
        }
        if (this.uploadError.length > 0) {
          Text(this.uploadError)
            .fontSize(12)
            .fontColor(Theme.danger)
            .height(36)
            .margin({ bottom: 4 })
        }
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 12 })
    }
  }

  // MARK: 图片

  /** 还能再加几张（同 iOS：一条消息最多 4 张） */
  private canAddImages(): boolean {
    return this.attachments.length + this.uploading < AgentAttachments.MAX_PER_MESSAGE;
  }

  /** 三种来源共用：选 → 压缩 → 上传 → 进托盘（逐张，失败只提示不打断其它） */
  private async addImages(source: string): Promise<void> {
    this.uploadError = '';
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const client = AppModel.shared.client;
    if (client === null) {
      return;
    }
    const room: number = AgentAttachments.MAX_PER_MESSAGE - this.attachments.length - this.uploading;
    if (room <= 0) {
      this.uploadError = `一条消息最多发送 ${AgentAttachments.MAX_PER_MESSAGE} 张图片`;
      return;
    }
    let uris: string[] = [];
    try {
      if (source === 'library') {
        uris = await AgentAttachments.pickFromLibrary(room);
      } else if (source === 'camera') {
        const shot: string = await AgentAttachments.capture(context);
        uris = shot.length > 0 ? [shot] : [];
      } else {
        uris = await AgentAttachments.pickFiles(context, room);
      }
    } catch (error) {
      this.uploadError = '打开选择器失败，请重试';
      return;
    }
    if (uris.length === 0) {
      return;
    }
    if (uris.length > room) {
      this.uploadError = `一条消息最多发送 ${AgentAttachments.MAX_PER_MESSAGE} 张图片`;
      uris = uris.slice(0, room);
    }
    for (const uri of uris) {
      this.uploading += 1;
      try {
        const attachment: AgentAttachment = await AgentAttachments.prepareAndUpload(client, context,
          uri, '');
        this.attachments = this.attachments.concat([attachment]);
      } catch (error) {
        this.uploadError = this.messageOf(error);
      } finally {
        this.uploading -= 1;
      }
    }
  }

  /** 输入框占位（同 iOS：锁定 / 改写 / 生成中 / 默认四态） */
  private placeholderText(): string {
    if (this.editTarget.length > 0) {
      return '修改问题后发送，将从这里重新生成回答';
    }
    if (this.running) {
      return '生成中，可先输入下一条…';
    }
    return '随心输入，描述一个新任务…';
  }

  /** 工具行上的模型文案（同 iOS：`resolve(...)?.label ?? '模型'`） */
  private modelLabel(): string {
    const hit: LlmModelOptionView | null = AgentCatalog.resolve(this.models, this.displayedModel());
    return hit !== null ? hit.label : '模型';
  }

  /** 「＋」：使用技能（点一项插成 `/skill:名字 `，同 iOS `addSkill`） */
  @Builder
  PlusSheet() {
    Column({ space: 8 }) {
      if (this.canAddImages()) {
        Text('上传图片')
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .width('100%')
          .padding({ left: 10, top: 4 })
        this.PlusRow('照片图库', 'sys.symbol.ohos_photo', 'library')
        this.PlusRow('拍照', 'sys.symbol.camera', 'camera')
        this.PlusRow('选取文件', 'sys.symbol.folder', 'files')
        Divider().strokeWidth(0.5).color(Theme.line).margin({ left: 10, right: 10, top: 4 })
      }
      Text('使用技能')
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .width('100%')
        .padding({ left: 10, top: 4 })
      if (this.skills.length === 0) {
        Text('暂无可用技能')
          .fontSize(13)
          .fontColor(Theme.textFaint)
          .padding({ left: 10, bottom: 12 })
      } else {
        List() {
          ForEach(this.skills, (skill: SkillView) => {
            ListItem() {
              Column({ space: 2 }) {
                Text(skill.name)
                  .fontSize(14)
                  .fontColor(Theme.text)
                  .width('100%')
                  .textAlign(TextAlign.Start)
                if (skill.description.length > 0) {
                  Text(skill.description)
                    .fontSize(12)
                    .fontColor(Theme.textFaint)
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                    .textAlign(TextAlign.Start)
                }
              }
              .width('100%')
              .padding({ left: 10, right: 10, top: 8, bottom: 8 })
              .onClick((): void => {
                this.insertSkill(skill.name);
                this.showComposerSheet = false;
              })
            }
          }, (skill: SkillView): string => `skill-${skill.name}`)
        }
        .width('100%')
        .height(this.skills.length > 5 ? 260 : this.skills.length * 56)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .padding({ left: 6, right: 6, bottom: 16 })
    .backgroundColor(Theme.bg)
  }

  /** 「＋」面板里的一行（上传图片来源；同 iOS `imageSourceRow`） */
  @Builder
  PlusRow(title: string, symbol: string, source: string) {
    Row({ space: 10 }) {
      SymbolGlyph($r(symbol))
        .fontSize(16)
        .fontColor([Theme.textMuted])
      Text(title)
        .fontSize(14)
        .fontColor(Theme.text)
        .layoutWeight(1)
        .textAlign(TextAlign.Start)
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 10, bottom: 10 })
    .onClick((): void => {
      this.showComposerSheet = false;
      this.addImages(source);
    })
  }

  /** 技能插进草稿（token 形态，服务端发送时展开；同 iOS 的 chip 行） */
  private insertSkill(name: string): void {
    const token: string = AgentSkillText.token(name);
    this.draft = this.draft.length === 0 ? token : `${token}${this.draft}`;
  }

  /** 工具行弹层内容：模型面板 / 技能面板（一个 sheet 两个形态，避免同一组件挂两个 bindSheet） */
  @Builder
  ComposerSheet() {
    if (this.sheetKind === 'model') {
      this.ModelSheet()
    } else {
      this.PlusSheet()
    }
  }

  /** 模型 + 思维链档位面板（同 iOS `AgentModelMenu`：选模型收起，调档位不收起） */
  @Builder
  ModelSheet() {
    Column({ space: 8 }) {
      Text('模型')
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .width('100%')
        .padding({ left: 10, top: 4 })
      List() {
        ForEach(this.models, (option: LlmModelOptionView) => {
          ListItem() {
            Row() {
              Text(option.label)
                .fontSize(14)
                .fontColor(this.isCurrentModel(option) ? Theme.text : Theme.textMuted)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              if (this.isCurrentModel(option)) {
                SymbolGlyph($r('sys.symbol.checkmark'))
                  .fontSize(13)
                  .fontColor([Theme.text])
              }
            }
            .width('100%')
            .padding({ left: 10, right: 10, top: 9, bottom: 9 })
            .onClick((): void => {
              // 选回默认项即「默认」：续聊沿用，设置页改默认后自动跟随
              this.modelTouched = true;
              this.modelValue = option.is_default ? '' : option.ref;
              // 换模型后旧档位可能不在新菜单里，显式清回默认
              this.thinkingTouched = true;
              this.thinkingValue = '';
              this.showComposerSheet = false;
            })
          }
        }, (option: LlmModelOptionView): string => `model-${option.ref}`)
      }
      .width('100%')
      .height(this.models.length > 5 ? 240 : this.models.length * 40)
      .scrollBar(BarState.Off)

      Divider().strokeWidth(0.5).color(Theme.line).margin({ left: 10, right: 10, top: 4, bottom: 4 })

      if (this.thinkingStops().length === 0) {
        Text('该模型不支持调节思考强度')
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .padding({ left: 10, bottom: 6 })
      } else {
        Text(`思维链强度 · ${AgentThinking.label(this.displayedThinking())}`)
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .padding({ left: 10 })
        Flex({ wrap: FlexWrap.Wrap }) {
          this.ThinkingChip('', '默认')
          ForEach(this.thinkingStops(), (level: string) => {
            this.ThinkingChip(level, AgentThinking.label(level))
          }, (level: string): string => `stop-${level}`)
        }
        .width('100%')
        .padding({ left: 10, right: 10, bottom: 8 })
      }
    }
    .width('100%')
    .padding({ left: 6, right: 6, bottom: 16 })
    .backgroundColor(Theme.bg)
  }

  @Builder
  ThinkingChip(level: string, label: string) {
    Text(label)
      .fontSize(13)
      .fontColor(this.displayedThinking() === level ? '#0b0d12' : Theme.textMuted)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .backgroundColor(this.displayedThinking() === level ? Theme.accent : Theme.glassFill)
      .borderRadius(14)
      .margin({ right: 8, top: 8 })
      .onClick((): void => {
        this.thinkingTouched = true;
        this.thinkingValue = level;
      })
  }

  /** 面板里当前选中的模型（没动过时按会话生效值判断） */
  private isCurrentModel(option: LlmModelOptionView): boolean {
    const value: string = this.displayedModel();
    if (value.length === 0) {
      return option.is_default;
    }
    return option.ref === value;
  }
}
