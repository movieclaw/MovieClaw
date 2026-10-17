import {
  JsonList,
  JsonMap,
  JsonValue,
  jsonArrayValue,
  jsonAt,
  jsonBoolValue,
  jsonGet,
  jsonIntValue,
  jsonObjectValue,
  jsonStringValue
} from '../api/JsonValue';
import { Formatters } from '../common/Formatters';

/**
 * AI 会话的展示时间线（对应 iOS `Features/Agent/AgentTimeline.swift` 与 Web `lib/agent-conversations.tsx`）。
 *
 * 事实源在服务端（JSONL 轨迹 + SQLite 索引），这里只是它的渲染形态：
 * - 「一轮」= 一条 user 消息 + Agent 的完整产出，是前端从消息序列派生的展示分组，不是协议实体；
 * - 每轮产出是按发生顺序排列的「段」：处理过程块（思考 + 工具调用，折叠展示）与正文交替出现，
 *   上下文压缩作为分隔卡片插在中间——与 agent loop 的实际执行顺序一致（仿 Claude 的呈现模型）；
 * - 历史回放（轨迹 entries）与实时流（SSE 事件）归约到同一套结构，渲染层不区分来源。
 *
 * ArkTS 没有带关联值的枚举，所以用「kind 字符串 + 载荷字段」的类来承载 iOS 的
 * `AgentSegment` / `AgentProcessItem`。
 */

/** 工具参数展开后的展示形态：bash 原文或美化 JSON（对应 iOS `AgentCodeLanguage`） */
export class AgentCodeDetail {
  readonly code: string;
  /** 'bash' | 'json' */
  readonly lang: string;

  constructor(code: string, lang: string) {
    this.code = code;
    this.lang = lang;
  }
}

/** 一次工具调用及其回执（对应 iOS `AgentToolCall`） */
export class AgentToolCall {
  readonly id: string;
  readonly name: string;
  /** 展示用摘要 `name({...})`；参数生成中为逐片追加的半成品 */
  label: string;
  /** 定稿后的结构化参数（生成式 UI 按它绘制卡片）；null = 未定稿 */
  args: JsonMap | null;
  /** 参数是否已生成完整；true 视为已完整（回放数据） */
  argsDone: boolean;
  /** 执行回执；null = 执行中 */
  output: string | null;
  isError: boolean;

  constructor(id: string, name: string, label: string, args: JsonMap | null = null,
    argsDone: boolean = true, output: string | null = null, isError: boolean = false) {
    this.id = id;
    this.name = name;
    this.label = label;
    this.args = args;
    this.argsDone = argsDone;
    this.output = output;
    this.isError = isError;
  }

  /** 参数仍在流式生成（此时行只作进度展示、不可展开） */
  streaming(): boolean {
    return !this.argsDone;
  }

  /** 已失败：流式期间由回执标记，回放数据靠 runner 的失败前缀识别 */
  failed(): boolean {
    if (this.isError) {
      return true;
    }
    return this.output !== null && this.output.startsWith('工具执行失败：');
  }

  /** 标签括号里的原始参数文本 */
  rawInner(): string {
    const head: number = this.name.length + 1;
    if (this.label.length <= head) {
      return '';
    }
    let inner: string = this.label.substring(head);
    if (inner.endsWith(')')) {
      inner = inner.substring(0, inner.length - 1);
    }
    return inner;
  }

  /** 单行参数摘要（清单态）：bash 压成一行命令，其余压成「键: 值」串 */
  summary(): string {
    const args: JsonMap | null = this.args;
    if (args !== null) {
      if (this.name === 'bash') {
        const command: JsonValue | undefined = args['command'];
        if (typeof command === 'string') {
          return command.split(/\s+/).filter((piece: string): boolean => piece.length > 0).join(' ');
        }
      }
      const parts: string[] = [];
      const keys: string[] = Object.keys(args);
      for (const key of keys) {
        const value: JsonValue | undefined = args[key];
        if (typeof value === 'string') {
          parts.push(`${key}: ${value}`);
        } else {
          parts.push(`${key}: ${AgentJsonText.render(value, false)}`);
        }
      }
      return parts.join(', ');
    }
    const raw: string = this.rawInner();
    return raw === '{}' ? '' : raw;
  }

  /** 展开后的参数明细：bash 取 command 按 shell 展示，其余美化 JSON；解析失败原样展示括号内文本 */
  inputDetail(): AgentCodeDetail | null {
    const args: JsonMap | null = this.args;
    if (args !== null) {
      if (this.name === 'bash') {
        const command: JsonValue | undefined = args['command'];
        if (typeof command === 'string') {
          return new AgentCodeDetail(command, 'bash');
        }
      }
      if (Object.keys(args).length === 0) {
        return null;
      }
      return new AgentCodeDetail(AgentJsonText.render(args, true), 'json');
    }
    const raw: string = this.rawInner();
    if (raw.length === 0 || raw === '{}') {
      return null;
    }
    return new AgentCodeDetail(raw, 'json');
  }
}

/** 处理过程条目：一段思维链或一次工具调用（对应 iOS `AgentProcessItem`） */
export class AgentProcessItem {
  /** 'thinking' | 'tool' */
  readonly kind: string;
  readonly text: string;
  readonly tool: AgentToolCall | null;

  private constructor(kind: string, text: string, tool: AgentToolCall | null) {
    this.kind = kind;
    this.text = text;
    this.tool = tool;
  }

  static thinking(text: string): AgentProcessItem {
    return new AgentProcessItem('thinking', text, null);
  }

  static tool(call: AgentToolCall): AgentProcessItem {
    return new AgentProcessItem('tool', '', call);
  }
}

/** 时间线段（对应 iOS `AgentSegment`）：处理过程 / 正文 / 上下文压缩 */
export class AgentSegment {
  /** 'process' | 'text' | 'compaction' */
  readonly kind: string;
  /** process：思考与工具调用按发生顺序 */
  readonly items: AgentProcessItem[];
  /** text：正文（增量拼接） */
  text: string;
  /** compaction：交接摘要 */
  summary: string;
  tokensBefore: number;
  tokensAfter: number;

  constructor(kind: string, items: AgentProcessItem[] = [], text: string = '',
    summary: string = '', tokensBefore: number = -1, tokensAfter: number = -1) {
    this.kind = kind;
    this.items = items;
    this.text = text;
    this.summary = summary;
    this.tokensBefore = tokensBefore;
    this.tokensAfter = tokensAfter;
  }

  static process(items: AgentProcessItem[]): AgentSegment {
    return new AgentSegment('process', items);
  }

  static text(text: string): AgentSegment {
    return new AgentSegment('text', [], text);
  }

  static compaction(summary: string, before: number, after: number): AgentSegment {
    return new AgentSegment('compaction', [], '', summary, before, after);
  }
}

/** 用户消息携带的一张图片（回放数据按 attachmentId 走附件下载接口） */
export class AgentTurnImage {
  readonly attachmentId: string;
  readonly name: string;

  constructor(attachmentId: string, name: string) {
    this.attachmentId = attachmentId;
    this.name = name;
  }
}

/** 一轮对话（对应 iOS `AgentTurn`） */
export class AgentTurn {
  readonly id: string;
  /** 开启本轮的 user message 稳定编号：「改写这条提问」的 retry 锚点；空 = 服务端尚未受理 */
  messageId: string;
  input: string;
  images: AgentTurnImage[];
  /** 'running' | 'done' | 'error' */
  status: string;
  /** 本轮开始时间（ms）；-1 = 未知 */
  startedAt: number;
  endedAt: number;
  segments: AgentSegment[];
  /** agent_done 的耗时（ms）；-1 = 未知 */
  elapsedMs: number;
  error: string;
  /** 用户主动停止 */
  stopped: boolean;
  /** 回放派生：本轮没有以「无工具调用的正文」收尾（停机、崩溃、模型报错） */
  interrupted: boolean;
  /** 本轮请求的模型引用；'' = 默认模型（同 iOS `modelRef`） */
  modelRef: string;
  /** 本轮生效的思维链档位；'' = 模型默认（同 iOS `thinkingLevel`） */
  thinkingLevel: string;

  constructor(id: string, messageId: string, input: string, images: AgentTurnImage[],
    status: string, startedAt: number) {
    this.id = id;
    this.messageId = messageId;
    this.input = input;
    this.images = images;
    this.status = status;
    this.startedAt = startedAt;
    this.endedAt = -1;
    this.segments = [];
    this.elapsedMs = -1;
    this.error = '';
    this.stopped = false;
    this.interrupted = false;
    this.modelRef = '';
    this.thinkingLevel = '';
  }

  running(): boolean {
    return this.status === 'running';
  }

  /** 本轮全部正文（页脚「复制」用） */
  answerText(): string {
    const chunks: string[] = [];
    for (const segment of this.segments) {
      if (segment.kind === 'text') {
        chunks.push(segment.text);
      }
    }
    return chunks.join('\n\n').trim();
  }
}

/** 派生会话的来源（会话级卡片，只展示来源关系） */
export class AgentHandoff {
  readonly sourceId: string;
  readonly sourceTitle: string;

  constructor(sourceId: string, sourceTitle: string) {
    this.sourceId = sourceId;
    this.sourceTitle = sourceTitle;
  }
}

/** 轨迹回放的产物：轮次 + 来源卡片 + 是否仍在运行 */
export class AgentTranscript {
  readonly turns: AgentTurn[];
  readonly handoff: AgentHandoff | null;
  readonly running: boolean;
  readonly title: string;

  constructor(turns: AgentTurn[], handoff: AgentHandoff | null, running: boolean, title: string) {
    this.turns = turns;
    this.handoff = handoff;
    this.running = running;
    this.title = title;
  }
}

/** 实时事件（SSE data 载荷，见后端 `movieclaw_agent/events.py`） */
export class AgentStreamEvent {
  readonly type: string;
  readonly delta: string;
  /** tool_call_start / tool_call_delta / tool_result 的目标调用 */
  readonly toolCallId: string;
  /** tool_call_start：仅名称；tool_call：参数完整的调用 */
  readonly toolCallIdOfStart: string;
  readonly toolName: string;
  readonly toolArgs: JsonMap | null;
  readonly toolRawArgs: string;
  readonly hasToolCall: boolean;
  readonly resultOutput: string;
  readonly resultIsError: boolean;
  readonly compactionSummary: string;
  readonly tokensBefore: number;
  readonly tokensAfter: number;
  readonly elapsedMs: number;
  readonly error: string;

  private constructor(type: string, delta: string, toolCallId: string, toolCallIdOfStart: string,
    toolName: string, toolArgs: JsonMap | null, toolRawArgs: string, hasToolCall: boolean,
    resultOutput: string, resultIsError: boolean, compactionSummary: string,
    tokensBefore: number, tokensAfter: number, elapsedMs: number, error: string) {
    this.type = type;
    this.delta = delta;
    this.toolCallId = toolCallId;
    this.toolCallIdOfStart = toolCallIdOfStart;
    this.toolName = toolName;
    this.toolArgs = toolArgs;
    this.toolRawArgs = toolRawArgs;
    this.hasToolCall = hasToolCall;
    this.resultOutput = resultOutput;
    this.resultIsError = resultIsError;
    this.compactionSummary = compactionSummary;
    this.tokensBefore = tokensBefore;
    this.tokensAfter = tokensAfter;
    this.elapsedMs = elapsedMs;
    this.error = error;
  }

  /** 终态事件：收到后本次运行结束，事件流不再重连 */
  terminal(): boolean {
    return this.type === 'agent_done' || this.type === 'agent_error' || this.type === 'agent_cancelled';
  }

  /** 解析 SSE 的 data 载荷；解不开返回 null（调用方只推进游标） */
  static parse(data: string): AgentStreamEvent | null {
    let payload: JsonMap | null = null;
    try {
      payload = JSON.parse(data) as JsonMap;
    } catch (error) {
      return null;
    }
    if (payload === null) {
      return null;
    }
    const type: string = jsonStringValue(jsonGet(payload, 'type')) ?? '';
    const delta: string = jsonStringValue(jsonGet(payload, 'delta')) ?? '';
    const toolCallId: string = jsonStringValue(jsonGet(payload, 'tool_call_id')) ?? '';

    const call: JsonMap | null = jsonObjectValue(jsonGet(payload, 'tool_call'));
    let startId: string = '';
    let name: string = '';
    let args: JsonMap | null = null;
    let rawArgs: string = '';
    if (call !== null) {
      startId = jsonStringValue(jsonGet(call, 'id')) ?? '';
      name = jsonStringValue(jsonGet(call, 'name')) ?? '';
      args = jsonObjectValue(jsonGet(call, 'arguments'));
      rawArgs = jsonStringValue(jsonGet(call, 'raw_arguments')) ?? '';
    }

    const result: JsonMap | null = jsonObjectValue(jsonGet(payload, 'tool_result'));
    let resultOutput: string = '';
    let resultIsError: boolean = false;
    if (result !== null) {
      resultOutput = jsonStringValue(jsonGet(result, 'output')) ?? '';
      resultIsError = jsonBoolValue(jsonGet(result, 'is_error')) ?? false;
    }

    const compaction: JsonMap | null = jsonObjectValue(jsonGet(payload, 'compaction'));
    let summary: string = '';
    let tokensBefore: number = -1;
    let tokensAfter: number = -1;
    if (compaction !== null) {
      summary = jsonStringValue(jsonGet(compaction, 'summary')) ?? '';
      tokensBefore = jsonIntValue(jsonGet(compaction, 'tokens_before')) ?? -1;
      tokensAfter = jsonIntValue(jsonGet(compaction, 'tokens_after')) ?? -1;
    }

    const runResult: JsonMap | null = jsonObjectValue(jsonGet(payload, 'result'));
    const elapsedMs: number = runResult === null
      ? -1 : (jsonIntValue(jsonGet(runResult, 'elapsed_ms')) ?? -1);
    const error: string = jsonStringValue(jsonGet(payload, 'error')) ?? '';

    return new AgentStreamEvent(type, delta, toolCallId, startId, name, args, rawArgs,
      call !== null, resultOutput, resultIsError, summary, tokensBefore, tokensAfter, elapsedMs, error);
  }
}

/** JSON 展示（键序按模型给出的顺序：JSON.parse 保序） */
export class AgentJsonText {
  static render(value: JsonValue | undefined, pretty: boolean): string {
    if (value === undefined) {
      return 'null';
    }
    if (pretty) {
      return JSON.stringify(value, null, 2) ?? 'null';
    }
    return JSON.stringify(value) ?? 'null';
  }
}

/** 轨迹 → 展示轮次 / 实时事件归约 / 过程块文案（对应 iOS `enum AgentTimeline`） */
export class AgentTimeline {
  /** 回答正文字号（同 iOS `AgentTranscriptLayout.textSize`） */
  static readonly TEXT_SIZE: number = 15;
  static readonly TURN_SPACING: number = 32;
  static readonly ANSWER_SPACING: number = 12;
  static readonly SEGMENT_SPACING: number = 10;

  /** 轨迹 entries → 轮次 + 来源卡片（`running` 时最后一轮交给事件流重建） */
  static parse(entries: JsonValue[], running: boolean, title: string): AgentTranscript {
    const turns: AgentTurn[] = AgentTimeline.turnsFrom(entries);
    if (running && turns.length > 0) {
      // 运行中的会话从事件 0 完整回放：轨迹快照与事件游标不同步，
      // 正在跑那一轮落盘的局部产出要先丢掉，整轮交给事件流重建，避免重复
      const last: AgentTurn = turns[turns.length - 1];
      last.status = 'running';
      last.segments = [];
      last.endedAt = -1;
      last.elapsedMs = -1;
      last.error = '';
      last.stopped = false;
      last.interrupted = false;
    }
    return new AgentTranscript(turns, AgentTimeline.handoffOf(entries), running, title);
  }

  /**
   * 轨迹 entries → 展示轮次：user 消息开启新一轮；assistant 的思考、正文、tool_calls 按
   * 「thinking → text → 工具」并入时间线（与流式事件顺序一致）；tool 消息按 tool_call_id 合并进调用卡片。
   */
  static turnsFrom(entries: JsonValue[]): AgentTurn[] {
    const turns: AgentTurn[] = [];
    // 每轮是否已正常收尾（终答 = 无 tool_calls 的 assistant 正文）
    const closed: boolean[] = [];
    for (const entry of entries) {
      const map: JsonMap | null = jsonObjectValue(entry);
      if (map === null) {
        continue;
      }
      const type: string = jsonStringValue(jsonGet(map, 'type')) ?? '';
      if (type === 'handoff') {
        continue; // 会话级来源卡片，旧消息不在新会话里派生成可重试的轮次
      }
      if (type === 'compaction') {
        if (turns.length === 0) {
          continue;
        }
        const summary: string = jsonStringValue(jsonGet(map, 'summary')) ?? '';
        const before: number = jsonIntValue(jsonGet(map, 'tokens_before')) ?? -1;
        const after: number = jsonIntValue(jsonGet(map, 'tokens_after')) ?? -1;
        const turn: AgentTurn = turns[turns.length - 1];
        turn.segments.push(AgentSegment.compaction(summary, before, after));
        turn.endedAt = Formatters.date(jsonStringValue(jsonGet(map, 'timestamp'))) ?? turn.endedAt;
        continue;
      }
      if (type !== 'message') {
        continue;
      }
      const messageId: string = jsonStringValue(jsonGet(map, 'message_id')) ?? '';
      const timestamp: string = jsonStringValue(jsonGet(map, 'timestamp')) ?? '';
      const message: JsonMap | null = jsonObjectValue(jsonGet(map, 'message'));
      if (message === null) {
        continue;
      }
      const role: string = jsonStringValue(jsonGet(message, 'role')) ?? 'assistant';
      const finishReason: string = jsonStringValue(jsonGet(map, 'finish_reason')) ?? '';

      if (role === 'user') {
        const turn: AgentTurn = new AgentTurn(messageId, messageId,
          AgentMessageText.textOf(jsonGet(message, 'content')), AgentMessageText.imagesOf(jsonGet(message, 'content')),
          'done', Formatters.date(timestamp) ?? -1);
        turn.modelRef = jsonStringValue(jsonGet(map, 'model')) ?? '';
        turn.thinkingLevel = jsonStringValue(jsonGet(map, 'thinking_level')) ?? '';
        turns.push(turn);
        closed.push(false);
        continue;
      }
      if (turns.length === 0) {
        continue;
      }
      const turn: AgentTurn = turns[turns.length - 1];
      if (role === 'assistant') {
        AgentTimeline.appendThinking(turn, AgentMessageText.thinkingOf(jsonGet(message, 'content')));
        AgentTimeline.appendText(turn, AgentMessageText.textOf(jsonGet(message, 'content')));
        const calls: JsonList | null = jsonArrayValue(jsonGet(message, 'tool_calls'));
        if (calls !== null) {
          for (let i = 0; i < calls.length; i++) {
            const call: JsonMap | null = jsonAt(calls, i) as JsonMap | null;
            if (call === null) {
              continue;
            }
            const id: string = jsonStringValue(jsonGet(call, 'id')) ?? '';
            const name: string = jsonStringValue(jsonGet(call, 'name')) ?? '';
            const args: JsonMap | null = jsonObjectValue(jsonGet(call, 'arguments'));
            const raw: string = jsonStringValue(jsonGet(call, 'raw_arguments')) ?? '';
            const useArgs: JsonMap | null = args !== null && Object.keys(args).length > 0 ? args : null;
            AgentTimeline.appendTool(turn, new AgentToolCall(id, name,
              AgentTimeline.label(name, useArgs, raw), useArgs));
          }
        }
        if (finishReason === 'aborted') {
          turn.stopped = true;
        }
        const endedMs: number | null = Formatters.date(timestamp);
        if (endedMs !== null) {
          turn.endedAt = endedMs;
        }
        closed[turns.length - 1] = (calls === null || calls.length === 0) && finishReason !== 'aborted';
        continue;
      }
      if (role === 'tool') {
        const toolCallId: string = jsonStringValue(jsonGet(message, 'tool_call_id')) ?? '';
        AgentTimeline.patchToolOutput(turn, toolCallId, AgentMessageText.textOf(jsonGet(message, 'content')), false);
        const endedMs: number | null = Formatters.date(timestamp);
        if (endedMs !== null) {
          turn.endedAt = endedMs;
        }
      }
    }
    for (let i = 0; i < turns.length; i++) {
      if (!closed[i] && !turns[i].stopped) {
        turns[i].interrupted = true;
      }
    }
    return turns;
  }

  /** 轨迹里的 handoff entry → 来源卡片 */
  static handoffOf(entries: JsonValue[]): AgentHandoff | null {
    for (const entry of entries) {
      const map: JsonMap | null = jsonObjectValue(entry);
      if (map === null) {
        continue;
      }
      if ((jsonStringValue(jsonGet(map, 'type')) ?? '') !== 'handoff') {
        continue;
      }
      const sourceId: string = jsonStringValue(jsonGet(map, 'source_session_id')) ?? '';
      const sourceTitle: string = jsonStringValue(jsonGet(map, 'source_title')) ?? '';
      return new AgentHandoff(sourceId, sourceTitle);
    }
    return null;
  }

  // MARK: 段的归约（思考/工具事件并入末尾 process 块，正文增量并入末尾 text 段）

  static appendThinking(turn: AgentTurn, delta: string): void {
    if (delta.length === 0) {
      return;
    }
    if (turn.segments.length > 0 && turn.segments[turn.segments.length - 1].kind === 'process') {
      const items: AgentProcessItem[] = turn.segments[turn.segments.length - 1].items;
      if (items.length > 0 && items[items.length - 1].kind === 'thinking') {
        const head: string = items[items.length - 1].text;
        items[items.length - 1] = AgentProcessItem.thinking(head + delta);
      } else {
        items.push(AgentProcessItem.thinking(delta));
      }
      return;
    }
    turn.segments.push(AgentSegment.process([AgentProcessItem.thinking(delta)]));
  }

  static appendText(turn: AgentTurn, delta: string): void {
    if (delta.length === 0) {
      return;
    }
    if (turn.segments.length > 0 && turn.segments[turn.segments.length - 1].kind === 'text') {
      const segment: AgentSegment = turn.segments[turn.segments.length - 1];
      segment.text = segment.text + delta;
      return;
    }
    turn.segments.push(AgentSegment.text(delta));
  }

  static appendTool(turn: AgentTurn, tool: AgentToolCall): void {
    if (turn.segments.length > 0 && turn.segments[turn.segments.length - 1].kind === 'process') {
      turn.segments[turn.segments.length - 1].items.push(AgentProcessItem.tool(tool));
      return;
    }
    turn.segments.push(AgentSegment.process([AgentProcessItem.tool(tool)]));
  }

  static appendCompaction(turn: AgentTurn, summary: string, before: number, after: number): void {
    turn.segments.push(AgentSegment.compaction(summary, before, after));
  }

  /** 从后往前找到指定 id 的工具条目并按回调打补丁（ArkTS 无 inout，直接改对象） */
  static patchToolById(turn: AgentTurn, id: string): AgentToolCall | null {
    if (id.length === 0) {
      return null;
    }
    for (let s = turn.segments.length - 1; s >= 0; s--) {
      const segment: AgentSegment = turn.segments[s];
      if (segment.kind !== 'process') {
        continue;
      }
      for (let i = segment.items.length - 1; i >= 0; i--) {
        const tool: AgentToolCall | null = segment.items[i].tool;
        if (tool !== null && tool.id === id) {
          return tool;
        }
      }
    }
    return null;
  }

  /** 参数未定稿的最后一个调用（个别端点分片不带 id 时的兜底归属） */
  static lastStreamingTool(turn: AgentTurn): AgentToolCall | null {
    for (let s = turn.segments.length - 1; s >= 0; s--) {
      const segment: AgentSegment = turn.segments[s];
      if (segment.kind !== 'process') {
        continue;
      }
      for (let i = segment.items.length - 1; i >= 0; i--) {
        const tool: AgentToolCall | null = segment.items[i].tool;
        if (tool !== null && !tool.argsDone) {
          return tool;
        }
      }
    }
    return null;
  }

  static patchToolOutput(turn: AgentTurn, id: string, output: string, isError: boolean): void {
    const tool: AgentToolCall | null = AgentTimeline.patchToolById(turn, id);
    if (tool === null) {
      return;
    }
    tool.output = output;
    tool.isError = isError;
  }

  // MARK: 实时事件归约（与 Web applyAgentEvent 同规则）

  static applyEvent(turn: AgentTurn, event: AgentStreamEvent): void {
    if (event.type === 'thinking_delta') {
      AgentTimeline.appendThinking(turn, event.delta);
      return;
    }
    if (event.type === 'text_delta') {
      AgentTimeline.appendText(turn, event.delta);
      return;
    }
    if (event.type === 'tool_call_start') {
      // 名称一确定就落条目，用户立刻看到「正在调用哪个工具」
      AgentTimeline.appendTool(turn,
        new AgentToolCall(event.toolCallIdOfStart, event.toolName, `${event.toolName}(`, null, false));
      return;
    }
    if (event.type === 'tool_call_delta') {
      if (event.delta.length === 0) {
        return;
      }
      const hit: AgentToolCall | null = AgentTimeline.patchToolById(turn, event.toolCallId);
      const target: AgentToolCall | null = hit !== null ? hit : AgentTimeline.lastStreamingTool(turn);
      if (target !== null) {
        target.label = target.label + event.delta;
      }
      return;
    }
    if (event.type === 'tool_call') {
      if (!event.hasToolCall) {
        return;
      }
      const label: string = AgentTimeline.label(event.toolCallIdOfStart, event.toolArgs, event.toolRawArgs);
      const hit: AgentToolCall | null = AgentTimeline.patchToolById(turn, event.toolCallIdOfStart);
      if (hit !== null) {
        hit.label = label;
        hit.args = event.toolArgs;
        hit.argsDone = true;
      } else {
        AgentTimeline.appendTool(turn, new AgentToolCall(event.toolCallIdOfStart, event.toolName,
          label, event.toolArgs, true));
      }
      return;
    }
    if (event.type === 'tool_result') {
      AgentTimeline.patchToolOutput(turn, event.toolCallId, event.resultOutput, event.resultIsError);
      return;
    }
    if (event.type === 'context_compacted') {
      AgentTimeline.appendCompaction(turn, event.compactionSummary, event.tokensBefore, event.tokensAfter);
      return;
    }
    if (event.type === 'agent_done') {
      turn.status = 'done';
      turn.elapsedMs = event.elapsedMs;
      return;
    }
    if (event.type === 'agent_error') {
      turn.status = 'error';
      turn.error = event.error.length > 0 ? event.error : '运行失败，原因未知';
      return;
    }
    if (event.type === 'agent_cancelled') {
      turn.status = 'done';
      turn.stopped = true;
    }
  }

  // MARK: 文案

  /** 定稿标签 `name({...})` */
  static label(name: string, args: JsonMap | null, raw: string): string {
    if (args !== null && Object.keys(args).length > 0) {
      return `${name}(${AgentJsonText.render(args, false)})`;
    }
    return `${name}(${raw.length > 0 ? raw : '{}'})`;
  }

  /** 进行中的处理块此刻在做什么：取末尾条目推导 */
  static processStatus(items: AgentProcessItem[]): string {
    if (items.length === 0) {
      return '思考中…';
    }
    const tail: AgentToolCall | null = items[items.length - 1].tool;
    if (tail === null) {
      return '思考中…';
    }
    if (!tail.argsDone) {
      return `准备调用 ${tail.name}…`;
    }
    if (tail.output === null) {
      return `正在执行 ${tail.name}…`;
    }
    return '思考中…'; // 工具已返回，正在等模型的下一步
  }

  /** 已完成处理块的一句话总结，如「已思考，执行 1 次命令，调用 2 次工具」 */
  static processSummary(items: AgentProcessItem[]): string {
    let hasThinking: boolean = false;
    let commands: number = 0;
    let others: number = 0;
    for (const item of items) {
      if (item.kind === 'thinking') {
        hasThinking = true;
        continue;
      }
      const tool: AgentToolCall | null = item.tool;
      if (tool === null) {
        continue;
      }
      if (tool.name === 'bash') {
        commands += 1;
      } else {
        others += 1;
      }
    }
    const parts: string[] = [];
    if (hasThinking) {
      parts.push('思考');
    }
    if (commands > 0) {
      parts.push(`执行 ${commands} 次命令`);
    }
    if (others > 0) {
      parts.push(`调用 ${others} 次工具`);
    }
    return parts.length === 0 ? '处理过程' : `已${parts.join('，')}`;
  }

  /** 耗时文案：不足一分钟按秒（终态保留一位小数），超过则「x 分 y 秒」 */
  static duration(seconds: number, precise: boolean): string {
    const s: number = Math.max(0, seconds);
    if (s < 60) {
      return precise ? `${s.toFixed(1)}s` : `${Math.floor(s)}s`;
    }
    const minutes: number = Math.floor(s / 60);
    return `${minutes} 分 ${Math.floor(s) - minutes * 60} 秒`;
  }
}

/** 消息 content 的取值helper：正文 / 思考 / 图片（对应 iOS `AgentWireMessage`） */
export class AgentMessageText {
  /** 正文纯文本（text 块拼接） */
  static textOf(content: JsonValue | null | undefined): string {
    return AgentMessageText.partsOf(content, 'text');
  }

  /** 思考内容（thinking 块拼接，仅 assistant） */
  static thinkingOf(content: JsonValue | null | undefined): string {
    return AgentMessageText.partsOf(content, 'thinking');
  }

  /** 用户消息里的图片引用（没有 attachment_id 的历史块跳过） */
  static imagesOf(content: JsonValue | null | undefined): AgentTurnImage[] {
    const images: AgentTurnImage[] = [];
    const parts: JsonList | null = jsonArrayValue(content);
    if (parts === null) {
      return images;
    }
    for (let i = 0; i < parts.length; i++) {
      const part: JsonMap | null = jsonAt(parts, i) as JsonMap | null;
      if (part === null) {
        continue;
      }
      if ((jsonStringValue(jsonGet(part, 'type')) ?? '') !== 'image') {
        continue;
      }
      const id: string = jsonStringValue(jsonGet(part, 'attachment_id')) ?? '';
      if (id.length === 0) {
        continue;
      }
      images.push(new AgentTurnImage(id, jsonStringValue(jsonGet(part, 'name')) ?? ''));
    }
    return images;
  }

  /** content 可能是纯字符串，也可能是内容块数组 */
  private static partsOf(content: JsonValue | null | undefined, kind: string): string {
    if (content === null || content === undefined) {
      return '';
    }
    const direct: string | null = jsonStringValue(content);
    if (direct !== null) {
      return kind === 'text' ? direct : '';
    }
    const parts: JsonList | null = jsonArrayValue(content);
    if (parts === null) {
      return '';
    }
    const chunks: string[] = [];
    for (let i = 0; i < parts.length; i++) {
      const part: JsonMap | null = jsonAt(parts, i) as JsonMap | null;
      if (part === null) {
        continue;
      }
      if ((jsonStringValue(jsonGet(part, 'type')) ?? '') !== kind) {
        continue;
      }
      const text: string | null = jsonStringValue(jsonGet(part, 'text'));
      if (text !== null && text.length > 0) {
        chunks.push(text);
      }
    }
    return chunks.join('');
  }
}
