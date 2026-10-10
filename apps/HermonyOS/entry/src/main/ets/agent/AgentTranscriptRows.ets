import { AgentHandoff, AgentProcessItem, AgentSegment, AgentTimeline, AgentTurn } from './AgentTimeline';
import { AgentMediaCardEntry, AgentMediaCardGroup, AgentMediaCards } from './AgentMediaCards';
import { AgentMarkdownBlock, AgentMarkdownParser } from './AgentMarkdown';

/**
 * 会话消息列的「行」（对应 iOS `AgentTranscriptRows.swift`）。
 *
 * 为什么不按「一轮」渲染：一轮对话常有几千 vp 高（长回答、表格、代码），
 * 拆成段落级的行（提问气泡 / 处理过程 / 卡片组 / 每个 Markdown 块 / 页脚）之后，
 * 列表能只构建、排版最底下一屏，长会话不再整轮卡住。
 *
 * 视觉间距与 iOS 完全一致：轮与轮之间 32、提问到回答 12、段与段 10、
 * 段内 Markdown 块之间 0.75em、标题前再多 0.65em，摊到每行的 `spacing` 上。
 */

/** 提问行的字段（不必整轮携带：流式时这一轮在变，气泡本身没变） */
export class AgentRowQuestion {
  readonly messageId: string;
  readonly input: string;

  constructor(messageId: string, input: string) {
    this.messageId = messageId;
    this.input = input;
  }
}

/** 消息列的一行 */
export class AgentRow {
  readonly id: string;
  /** handoff | question | process | mediaCards | markdown | cursor | compaction | error | footer */
  readonly kind: string;
  /** 与上一行之间的间距（vp） */
  spacing: number;
  readonly handoff: AgentHandoff | null;
  readonly question: AgentRowQuestion | null;
  readonly processItems: AgentProcessItem[];
  readonly active: boolean;
  readonly group: AgentMediaCardGroup | null;
  readonly block: AgentMarkdownBlock | null;
  readonly compaction: AgentSegment | null;
  readonly errorText: string;
  readonly footerTurn: AgentTurn | null;

  private constructor(id: string, kind: string, spacing: number, handoff: AgentHandoff | null,
    question: AgentRowQuestion | null, processItems: AgentProcessItem[], active: boolean,
    group: AgentMediaCardGroup | null, block: AgentMarkdownBlock | null, compaction: AgentSegment | null,
    errorText: string, footerTurn: AgentTurn | null) {
    this.id = id;
    this.kind = kind;
    this.spacing = spacing;
    this.handoff = handoff;
    this.question = question;
    this.processItems = processItems;
    this.active = active;
    this.group = group;
    this.block = block;
    this.compaction = compaction;
    this.errorText = errorText;
    this.footerTurn = footerTurn;
  }

  static handoffRow(handoff: AgentHandoff): AgentRow {
    return new AgentRow(`handoff-${handoff.sourceId}`, 'handoff', 0, handoff, null, [], false,
      null, null, null, '', null);
  }

  static questionRow(id: string, spacing: number, question: AgentRowQuestion): AgentRow {
    return new AgentRow(id, 'question', spacing, null, question, [], false, null, null, null, '', null);
  }

  static processRow(id: string, spacing: number, items: AgentProcessItem[], active: boolean): AgentRow {
    return new AgentRow(id, 'process', spacing, null, null, items, active, null, null, null, '', null);
  }

  static mediaCardsRow(id: string, spacing: number, group: AgentMediaCardGroup): AgentRow {
    return new AgentRow(id, 'mediaCards', spacing, null, null, [], false, group, null, null, '', null);
  }

  static markdownRow(id: string, spacing: number, block: AgentMarkdownBlock): AgentRow {
    return new AgentRow(id, 'markdown', spacing, null, null, [], false, null, block, null, '', null);
  }

  static cursorRow(id: string, spacing: number): AgentRow {
    return new AgentRow(id, 'cursor', spacing, null, null, [], false, null, null, null, '', null);
  }

  static compactionRow(id: string, spacing: number, segment: AgentSegment): AgentRow {
    return new AgentRow(id, 'compaction', spacing, null, null, [], false, null, null, segment, '', null);
  }

  static errorRow(id: string, spacing: number, message: string): AgentRow {
    return new AgentRow(id, 'error', spacing, null, null, [], false, null, null, null, message, null);
  }

  static footerRow(id: string, spacing: number, turn: AgentTurn): AgentRow {
    return new AgentRow(id, 'footer', spacing, null, null, [], false, null, null, null, '', turn);
  }
}

/** 轮次 → 行的拆分规则（对应 iOS `enum AgentTranscriptLayout`） */
export class AgentTranscriptLayout {
  static rows(turns: AgentTurn[], handoff: AgentHandoff | null, running: boolean): AgentRow[] {
    const rows: AgentRow[] = [];
    if (handoff !== null) {
      rows.push(AgentRow.handoffRow(handoff));
    }
    for (const turn of turns) {
      AgentTranscriptLayout.turnRows(turn, running, rows);
    }
    // 整列第一行不留间距
    if (rows.length > 0) {
      rows[0].spacing = 0;
    }
    return rows;
  }

  private static turnRows(turn: AgentTurn, running: boolean, rows: AgentRow[]): void {
    const active: boolean = turn.running() && running;
    rows.push(AgentRow.questionRow(`${turn.id}.q`, AgentTimeline.TURN_SPACING,
      new AgentRowQuestion(turn.messageId, turn.input)));
    let gap: number = AgentTimeline.ANSWER_SPACING;

    for (let index = 0; index < turn.segments.length; index++) {
      const segment: AgentSegment = turn.segments[index];
      const isLast: boolean = index === turn.segments.length - 1;

      if (segment.kind === 'process') {
        const entries: AgentMediaCardEntry[] = AgentMediaCards.groupsIn(segment.items);
        if (AgentTranscriptLayout.visibleProcessItems(segment.items).length > 0) {
          rows.push(AgentRow.processRow(`${turn.id}.${index}p`, gap, segment.items,
            active && isLast));
          gap = AgentTimeline.SEGMENT_SPACING;
        }
        for (const entry of entries) {
          rows.push(AgentRow.mediaCardsRow(`${turn.id}.${index}m${entry.id}`, gap, entry.group));
          gap = AgentTimeline.SEGMENT_SPACING;
        }
        continue;
      }

      if (segment.kind === 'text') {
        const blocks: AgentMarkdownBlock[] = AgentMarkdownParser.parse(segment.text);
        const signature: string = `${segment.text.length}`;
        for (let b = 0; b < blocks.length; b++) {
          if (b > 0) {
            gap = AgentTimeline.TEXT_SIZE * 0.75
              + (blocks[b].isHeading() ? AgentTimeline.TEXT_SIZE * 0.65 : 0);
          }
          rows.push(AgentRow.markdownRow(`${turn.id}.${index}b${b}-${signature}-${blocks[b].text.length}`,
            gap, blocks[b]));
          gap = AgentTimeline.SEGMENT_SPACING;
        }
        if (active && isLast) {
          // 光标紧贴正文（与正文同处一个间距 0 的容器，自带 4pt 上边距）
          rows.push(AgentRow.cursorRow(`${turn.id}.${index}c`, blocks.length > 0 ? 0 : gap));
          gap = AgentTimeline.SEGMENT_SPACING;
        }
        continue;
      }

      if (segment.kind === 'compaction') {
        rows.push(AgentRow.compactionRow(
          `${turn.id}.${index}z-${segment.summary.length}-${segment.tokensBefore}-${segment.tokensAfter}`,
          gap, segment));
        gap = AgentTimeline.SEGMENT_SPACING;
      }
    }

    if (turn.status === 'error' && turn.error.length > 0) {
      rows.push(AgentRow.errorRow(`${turn.id}.e-${turn.error.length}`, gap, turn.error));
      gap = AgentTimeline.SEGMENT_SPACING;
    }
    if (AgentTranscriptLayout.hasFooter(turn)) {
      rows.push(AgentRow.footerRow(
        `${turn.id}.f-${turn.status}-${turn.elapsedMs}-${turn.stopped}-${turn.interrupted}-${turn.answerText().length}`,
        gap, turn));
    }
  }

  /** 折叠块里要列的条目（去掉生成式 UI 的绘制调用；为空则整块不出现） */
  static visibleProcessItems(items: AgentProcessItem[]): AgentProcessItem[] {
    const out: AgentProcessItem[] = [];
    for (const item of items) {
      if (item.tool !== null && AgentMediaCards.isMediaCardsTool(item.tool.name)) {
        continue;
      }
      out.push(item);
    }
    return out;
  }

  /** 页脚会不会画出东西（与 `AgentTurnFooterView` 的分支一致） */
  private static hasFooter(turn: AgentTurn): boolean {
    if (turn.status === 'error') {
      return false;
    }
    if (turn.running()) {
      return true;
    }
    return turn.elapsedMs >= 0 || turn.endedAt >= 0 && turn.startedAt >= 0
      || turn.stopped || turn.interrupted || turn.answerText().length > 0;
  }
}
