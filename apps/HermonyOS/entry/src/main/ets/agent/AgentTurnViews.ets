import { LengthMetrics } from '@kit.ArkUI';
import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { RemoteImage } from '../common/RemoteImage';
import { AgentToolCall, AgentProcessItem, AgentTurn, AgentTurnImage, AgentTimeline, AgentCodeDetail }
  from './AgentTimeline';
import { AgentSkillText } from './AgentSkills';
import { copyPlainText } from './AgentMarkdownViews';

/**
 * 会话时间线里一轮的各个组成部分（对应 iOS `Features/Agent/AgentTurnViews.swift`）。
 *
 * 呈现取舍（与 iOS / Web 一致，刻意做减法）：
 * - 用户消息右侧气泡；Agent 回应整栏正文，不挂头像、不套气泡（ChatGPT / Claude 同款版式）；
 * - 思考与工具调用收进「处理过程」折叠块：进行中显示实时状态，完成后一句话总结；展开后工具调用
 *   只列单行摘要，点某一行才展开参数与输出——一轮动辄十几次调用，全量平铺等于没有排版；
 * - 轮次页脚只留耗时（进行中是进度环 + 实时秒数）与「复制」，模型/token 这些排查信息不上屏。
 */

/** 代码着色片段 */
export class AgentCodeSpan {
  readonly text: string;
  readonly color: string;

  constructor(text: string, color: string) {
    this.text = text;
    this.color = color;
  }
}

/** 轻量代码高亮（配色取 Shiki github-dark，与 iOS `AgentCodeHighlighter` 同规则，只用于工具参数） */
export class AgentCodeHighlighter {
  private static readonly keyColor: string = '#7EE787';
  private static readonly stringColor: string = '#A5D6FF';
  private static readonly numberColor: string = '#79C0FF';
  private static readonly keywordColor: string = '#FF7B72';
  private static readonly commandColor: string = '#D2A8FF';
  private static readonly commentColor: string = '#8B949E';

  static highlight(code: string, lang: string, base: string): AgentCodeSpan[] {
    if (lang === 'plain' || code.length >= 20000) {
      return [new AgentCodeSpan(code, base)];
    }
    const colors: string[] = [];
    for (let i = 0; i < code.length; i++) {
      colors.push(base);
    }
    const paint = (pattern: RegExp, color: string): void => {
      pattern.lastIndex = 0;
      let match: RegExpExecArray | null = pattern.exec(code);
      while (match !== null) {
        const from: number = match.index;
        const to: number = match.index + match[0].length;
        for (let i = from; i < to && i < colors.length; i++) {
          colors[i] = color;
        }
        if (match[0].length === 0) {
          pattern.lastIndex += 1;
        }
        match = pattern.exec(code);
      }
    };
    if (lang === 'json') {
      paint(/-?\b\d+(\.\d+)?([eE][+-]?\d+)?\b/g, AgentCodeHighlighter.numberColor);
      paint(/\b(true|false|null)\b/g, AgentCodeHighlighter.numberColor);
      paint(/"(?:[^"\\]|\\.)*"/g, AgentCodeHighlighter.stringColor);
      paint(/"(?:[^"\\]|\\.)*"(?=\s*:)/g, AgentCodeHighlighter.keyColor);
    } else if (lang === 'bash') {
      paint(/(?<=\s|^)--?[A-Za-z][\w-]*/g, AgentCodeHighlighter.numberColor);
      paint(/(?:^|(?<=[|;&]\s?))\s*[A-Za-z_][\w.-]*/gm, AgentCodeHighlighter.commandColor);
      paint(/\b(if|then|else|fi|for|do|done|while|case|esac|in|function|export|sudo)\b/g,
        AgentCodeHighlighter.keywordColor);
      paint(/"(?:[^"\\]|\\.)*"|'[^']*'/g, AgentCodeHighlighter.stringColor);
      paint(/(?:^|\s)#.*$/gm, AgentCodeHighlighter.commentColor);
    }
    const spans: AgentCodeSpan[] = [];
    let start: number = 0;
    for (let i = 1; i <= code.length; i++) {
      if (i === code.length || colors[i] !== colors[start]) {
        spans.push(new AgentCodeSpan(code.substring(start, i), colors[start]));
        start = i;
      }
    }
    return spans;
  }
}

/** 等宽代码（工具参数用；不着色的语言传 'plain'） */
@ComponentV2
export struct AgentCodeText {
  @Require @Param code: string;
  @Param lang: string = 'plain';
  @Param textSize: number = 13;
  @Param color: string = 'rgba(243, 245, 249, 0.88)';

  @Local private spans: AgentCodeSpan[] = [];

  aboutToAppear(): void {
    this.spans = AgentCodeHighlighter.highlight(this.code, this.lang, this.color);
  }

  @Monitor('code', 'lang')
  private onCodeChanged(): void {
    this.spans = AgentCodeHighlighter.highlight(this.code, this.lang, this.color);
  }

  build() {
    Text() {
      ForEach(this.spans, (span: AgentCodeSpan) => {
        Span(span.text)
          .fontFamily('monospace')
          .fontSize(this.textSize)
          .fontColor(span.color)
      }, (span: AgentCodeSpan, index: number): string => `${index}-${span.color}-${span.text.length}`)
    }
    .fontFamily('monospace')
    .fontSize(this.textSize)
    .lineSpacing(LengthMetrics.vp(this.textSize * 0.45))
    .copyOption(CopyOptions.InApp)
    .width('100%')
    .textAlign(TextAlign.Start)
  }
}

/** 用户提问气泡 + 浮现的行内操作（复制 / 改写重问） */
@ComponentV2
export struct AgentUserBubbleView {
  @Require @Param text: string;
  @Param images: AgentTurnImage[] = [];
  @Param sessionId: string = '';
  /** 已知技能名（小写）；空 = 名单未就绪（不过滤 token） */
  @Param knownSkills: string[] = [];
  /** 运行中不给改写入口（服务端会拒绝替换正在写轨迹的会话） */
  @Param canEdit: boolean = false;

  @Event onEdit: () => void = (): void => {
  };

  @Local private revealed: boolean = false;
  @Local private copied: boolean = false;
  @Local private skillNames: string[] = [];
  @Local private plainText: string = '';
  private resetTimer: number = -1;

  aboutToAppear(): void {
    this.parse();
  }

  @Monitor('text', 'knownSkills')
  private onTextChanged(): void {
    this.parse();
  }

  aboutToDisappear(): void {
    if (this.resetTimer >= 0) {
      clearTimeout(this.resetTimer);
      this.resetTimer = -1;
    }
  }

  private parse(): void {
    const parsed = AgentSkillText.parseTokens(this.text, this.knownSkills);
    this.skillNames = parsed.names;
    this.plainText = parsed.text;
  }

  private attachmentUrl(attachmentId: string): string {
    if (this.sessionId.length === 0) {
      return '';
    }
    return `${AppModel.origin()}/api/v1/sessions/${this.sessionId}/attachments/${attachmentId}`;
  }

  private copy(): void {
    copyPlainText(this.text);
    this.copied = true;
    if (this.resetTimer >= 0) {
      clearTimeout(this.resetTimer);
    }
    this.resetTimer = setTimeout((): void => {
      this.resetTimer = -1;
      this.copied = false;
    }, 1500);
  }

  build() {
    Column({ space: 6 }) {
      Row() {
        Column({ space: 8 }) {
          if (this.skillNames.length > 0) {
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.skillNames, (name: string) => {
                Text(`⚡ ${name}`)
                  .fontSize(13)
                  .fontColor(Theme.textMuted)
                  .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                  .backgroundColor('rgba(255, 255, 255, 0.08)')
                  .borderRadius(8)
                  .margin({ right: 6, bottom: 2 })
              }, (name: string, index: number): string => `skill-${index}-${name}`)
            }
            .width('100%')
          }
          if (this.images.length > 0) {
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.images, (image: AgentTurnImage) => {
                RemoteImage({
                  url: this.attachmentUrl(image.attachmentId),
                  fit: true,
                  placeholderSymbol: $r('sys.symbol.ohos_photo')
                })
                  .constraintSize({ maxWidth: 200, maxHeight: 160 })
                  .borderRadius(10)
                  .border({ width: 1, color: 'rgba(255, 255, 255, 0.1)' })
                  .margin({ right: 8, bottom: 4 })
              }, (image: AgentTurnImage, index: number): string => `img-${index}-${image.attachmentId}`)
            }
            .width('100%')
          }
          if (this.plainText.length > 0) {
            Text(this.plainText)
              .fontSize(15)
              .fontColor(Theme.text)
              .lineSpacing(LengthMetrics.vp(5))
              .copyOption(CopyOptions.InApp)
              .width('100%')
              .textAlign(TextAlign.Start)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .backgroundColor('rgba(255, 255, 255, 0.1)')
        .borderRadius(18)
        .constraintSize({ maxWidth: '86%' })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .onClick((): void => {
        this.getUIContext().animateTo({ duration: 150, curve: Curve.EaseOut }, (): void => {
          this.revealed = !this.revealed;
        });
      })
      .bindContextMenu(this.BubbleMenu(), ResponseType.LongPress)

      if (this.revealed) {
        Row({ space: 8 }) {
          if (this.canEdit) {
            Row({ space: 3 }) {
              SymbolGlyph($r('sys.symbol.pencil_line'))
                .fontSize(11)
                .fontColor([Theme.textFaint])
              Text('改写')
                .fontSize(12)
                .fontColor(Theme.textFaint)
            }
            .padding({ left: 4, right: 4, top: 2, bottom: 2 })
            .onClick((): void => {
              this.revealed = false;
              this.onEdit();
            })
          }
          Row({ space: 3 }) {
            SymbolGlyph(this.copied ? $r('sys.symbol.checkmark') : $r('sys.symbol.doc_filled_on_doc'))
              .fontSize(11)
              .fontColor([Theme.textFaint])
            Text(this.copied ? '已复制' : '复制')
              .fontSize(12)
              .fontColor(Theme.textFaint)
          }
          .padding({ left: 4, right: 4, top: 2, bottom: 2 })
          .onClick((): void => {
            this.copy();
          })
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.End)
  }

  @Builder
  BubbleMenu() {
    Menu() {
      MenuItem({ content: '复制', startIcon: $r('sys.symbol.doc_filled_on_doc') })
        .onClick((): void => {
          this.copy();
        })
      if (this.canEdit) {
        MenuItem({ content: '改写这条提问', startIcon: $r('sys.symbol.pencil_line') })
          .onClick((): void => {
            this.onEdit();
          })
      }
    }
  }
}

/** 处理过程折叠块：进行中显示实时状态、完成后一句话总结；点开看思考与工具调用 */
@ComponentV2
export struct AgentProcessBlockView {
  @Require @Param items: AgentProcessItem[];
  @Param active: boolean = false;

  @Local private open: boolean = false;
  @Local private dim: boolean = false;
  private pulseTimer: number = -1;

  aboutToAppear(): void {
    this.syncPulse();
  }

  @Monitor('active')
  private onActiveChanged(): void {
    this.syncPulse();
  }

  aboutToDisappear(): void {
    this.stopPulse();
  }

  /** 生成中的文案呼吸（iOS `AgentPulse`：0.9s 来回） */
  private syncPulse(): void {
    if (this.active) {
      if (this.pulseTimer < 0) {
        this.pulseTimer = setInterval((): void => {
          this.dim = !this.dim;
        }, 900);
      }
    } else {
      this.stopPulse();
    }
  }

  private stopPulse(): void {
    if (this.pulseTimer >= 0) {
      clearInterval(this.pulseTimer);
      this.pulseTimer = -1;
      this.dim = false;
    }
  }

  /** 折叠块里要列的条目（去掉生成式 UI 的绘制调用：它的产出是紧随其后的卡片） */
  private visibleItems(): AgentProcessItem[] {
    const out: AgentProcessItem[] = [];
    for (const item of this.items) {
      const tool: AgentToolCall | null = item.tool;
      if (tool !== null && tool.name === 'show_media_cards_v1') {
        continue;
      }
      out.push(item);
    }
    return out;
  }

  private headerText(): string {
    const items: AgentProcessItem[] = this.visibleItems();
    return this.active ? AgentTimeline.processStatus(items) : AgentTimeline.processSummary(items);
  }

  build() {
    if (this.visibleItems().length > 0) {
      Column({ space: 6 }) {
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(11)
            .fontColor([Theme.textFaint])
            .rotate({ angle: this.open ? 90 : 0 })
          Text(this.headerText())
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textFaint)
            .opacity(this.active && this.dim ? 0.45 : 1)
        }
        .padding({ top: 6, bottom: 6 })
        .onClick((): void => {
          this.getUIContext().animateTo({ duration: 180, curve: Curve.EaseOut }, (): void => {
            this.open = !this.open;
          });
        })

        if (this.open) {
          Row() {
            Divider()
              .vertical(true)
              .strokeWidth(2)
              .color('rgba(255, 255, 255, 0.08)')
              .height('100%')
            Column({ space: 8 }) {
              ForEach(this.visibleItems(), (item: AgentProcessItem, index: number) => {
                if (item.kind === 'thinking') {
                  Text(item.text)
                    .fontSize(13)
                    .fontColor(Theme.textFaint)
                    .lineSpacing(LengthMetrics.vp(3))
                    .copyOption(CopyOptions.InApp)
                    .width('100%')
                    .textAlign(TextAlign.Start)
                } else if (item.tool !== null) {
                  AgentToolRowView({ tool: item.tool })
                }
              }, (item: AgentProcessItem, index: number): string =>
                `pi-${index}-${item.kind}-${item.text.length}-${item.tool === null ? 0 : item.tool.label.length}`)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .padding({ left: 12 })
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }
}

/** 单次工具调用：默认一行摘要，点开看参数与输出 */
@ComponentV2
export struct AgentToolRowView {
  @Require @Param tool: AgentToolCall;

  @Local private open: boolean = false;

  /** 工具名配色（iOS `AgentToolRow.nameColor`） */
  private static readonly nameColor: string = '#9FC6E8';

  private tailLabel(): string {
    const head: number = this.tool.name.length + 1;
    if (this.tool.label.length <= head) {
      return '';
    }
    const rest: string = this.tool.label.substring(head);
    return rest.length > 300 ? rest.substring(rest.length - 300) : rest;
  }

  private detail(): AgentCodeDetail | null {
    return this.tool.inputDetail();
  }

  build() {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(9)
          .fontColor([Theme.textFaint])
          .rotate({ angle: this.open ? 90 : 0 })
        Text(this.tool.name)
          .fontSize(12)
          .fontFamily('monospace')
          .fontColor(AgentToolRowView.nameColor)
        if (this.tool.streaming()) {
          Text(this.tailLabel())
            .fontSize(12)
            .fontFamily('monospace')
            .fontColor(Theme.textFaint)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
            .textAlign(TextAlign.End)
        } else {
          Text(this.tool.summary())
            .fontSize(12)
            .fontFamily('monospace')
            .fontColor(Theme.textFaint)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
            .textAlign(TextAlign.Start)
        }
        if (this.tool.streaming() || this.tool.output === null) {
          LoadingProgress()
            .width(14)
            .height(14)
            .color(Theme.textFaint)
        } else {
          Text(this.tool.failed() ? '✗' : '✓')
            .fontSize(12)
            .fontColor(this.tool.failed() ? Theme.danger : Theme.textFaint)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ top: 2, bottom: 2 })
      .onClick((): void => {
        if (this.tool.streaming()) {
          return;
        }
        this.getUIContext().animateTo({ duration: 150, curve: Curve.EaseOut }, (): void => {
          this.open = !this.open;
        });
      })

      if (this.open && !this.tool.streaming()) {
        Column({ space: 6 }) {
          if (this.detail() !== null) {
            AgentCodeText({
              code: this.detail()!.code,
              lang: this.detail()!.lang,
              textSize: 12
            })
          }
          if (this.tool.output !== null) {
            Scroll() {
              Text(this.tool.output)
                .fontSize(12)
                .fontFamily('monospace')
                .fontColor(this.tool.failed() ? Theme.danger : Theme.textMuted)
                .lineSpacing(LengthMetrics.vp(2))
                .copyOption(CopyOptions.InApp)
                .width('100%')
                .textAlign(TextAlign.Start)
            }
            .scrollable(ScrollDirection.Vertical)
            .scrollBar(BarState.Auto)
            .constraintSize({ maxHeight: 176 })
            .width('100%')
            .align(Alignment.TopStart)
          } else {
            Text('执行中…')
              .fontSize(12)
              .fontColor(Theme.textFaint)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .backgroundColor('rgba(255, 255, 255, 0.02)')
        .borderRadius(8)
        .border({ width: 1, color: 'rgba(255, 255, 255, 0.05)' })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

/** 上下文压缩分隔卡片：横线 + 居中标签，点开看交接摘要 */
@ComponentV2
export struct AgentCompactionCardView {
  @Param summary: string = '';
  @Param tokensBefore: number = -1;
  @Param tokensAfter: number = -1;

  @Local private open: boolean = false;

  private label(): string {
    if (this.tokensBefore >= 0 && this.tokensAfter >= 0) {
      return `已压缩上下文（${this.tokensBefore} → ${this.tokensAfter} tokens）`;
    }
    return '已压缩上下文';
  }

  build() {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Divider()
          .strokeWidth(1)
          .color('rgba(255, 255, 255, 0.08)')
          .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(9)
          .fontColor([Theme.textFaint])
          .rotate({ angle: this.open ? 90 : 0 })
        Text(this.label())
          .fontSize(12)
          .fontColor(Theme.textFaint)
        Divider()
          .strokeWidth(1)
          .color('rgba(255, 255, 255, 0.08)')
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ top: 6, bottom: 6 })
      .onClick((): void => {
        this.getUIContext().animateTo({ duration: 180, curve: Curve.EaseOut }, (): void => {
          this.open = !this.open;
        });
      })

      if (this.open) {
        Row() {
          Divider()
            .vertical(true)
            .strokeWidth(2)
            .color('rgba(255, 255, 255, 0.08)')
            .height('100%')
          Column({ space: 6 }) {
            Text(this.summary)
              .fontSize(13)
              .fontColor(Theme.textFaint)
              .copyOption(CopyOptions.InApp)
              .width('100%')
              .textAlign(TextAlign.Start)
            Text('此前的对话已由交接摘要替代。多次压缩可能降低模型准确性，建议适时开启新会话。')
              .fontSize(12)
              .fontColor(Theme.textFaint)
              .width('100%')
              .textAlign(TextAlign.Start)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          .padding({ left: 12 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

/** 派生会话的来源卡片：只展示来源关系，不把旧消息重复画一遍 */
@ComponentV2
export struct AgentHandoffCardView {
  @Param sourceId: string = '';
  @Param sourceTitle: string = '';

  @Event onOpenSource: () => void = (): void => {
  };

  private title(): string {
    if (this.sourceTitle.length > 0) {
      return this.sourceTitle;
    }
    return `会话 ${this.sourceId.substring(0, Math.min(8, this.sourceId.length))}`;
  }

  build() {
    Row() {
      Column({ space: 4 }) {
        Text(`已从「${this.title()}」续接上下文`)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
          .width('100%')
          .textAlign(TextAlign.Start)
        Text('这是一个独立的新会话；后续操作不会改写原会话。')
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Row({ space: 2 }) {
        Text('查看原会话')
          .fontSize(12)
          .fontColor(Theme.textMuted)
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(11)
          .fontColor([Theme.textMuted])
      }
      .padding({ top: 6, bottom: 6 })
      .onClick((): void => {
        this.onOpenSource();
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor('rgba(255, 255, 255, 0.025)')
    .borderRadius(12)
    .border({ width: 1, color: 'rgba(255, 255, 255, 0.08)' })
  }
}

/** 本轮以错误收尾时的红色提示卡片 */
@ComponentV2
export struct AgentTurnErrorView {
  @Param message: string = '';

  build() {
    Text(this.message)
      .fontSize(13)
      .fontColor(Theme.danger)
      .copyOption(CopyOptions.InApp)
      .width('100%')
      .textAlign(TextAlign.Start)
      .padding({ left: 14, right: 14, top: 10, bottom: 10 })
      .backgroundColor('rgba(255, 107, 107, 0.1)')
      .borderRadius(12)
      .border({ width: 1, color: 'rgba(255, 107, 107, 0.3)' })
  }
}

/** 一轮的收尾行：进行中 = 进度环 + 实时耗时；完成 = 已停止/已中断 + 耗时 + 复制 */
@ComponentV2
export struct AgentTurnFooterView {
  @Require @Param turn: AgentTurn;

  @Local private copied: boolean = false;
  @Local private nowMs: number = Date.now();
  private tickTimer: number = -1;
  private resetTimer: number = -1;

  aboutToAppear(): void {
    if (this.turn.running()) {
      this.tickTimer = setInterval((): void => {
        this.nowMs = Date.now();
      }, 1000);
    }
  }

  aboutToDisappear(): void {
    if (this.tickTimer >= 0) {
      clearInterval(this.tickTimer);
      this.tickTimer = -1;
    }
    if (this.resetTimer >= 0) {
      clearTimeout(this.resetTimer);
      this.resetTimer = -1;
    }
  }

  private liveSeconds(): number {
    if (this.turn.startedAt <= 0) {
      return 0;
    }
    return Math.max(0, (this.nowMs - this.turn.startedAt) / 1000);
  }

  private doneDuration(): string {
    if (this.turn.elapsedMs >= 0) {
      return AgentTimeline.duration(this.turn.elapsedMs / 1000, true);
    }
    if (this.turn.endedAt > 0 && this.turn.startedAt > 0) {
      return AgentTimeline.duration((this.turn.endedAt - this.turn.startedAt) / 1000, false);
    }
    return '';
  }

  private answer(): string {
    return this.turn.answerText();
  }

  private copy(): void {
    copyPlainText(this.answer());
    this.copied = true;
    if (this.resetTimer >= 0) {
      clearTimeout(this.resetTimer);
    }
    this.resetTimer = setTimeout((): void => {
      this.resetTimer = -1;
      this.copied = false;
    }, 1500);
  }

  build() {
    if (this.turn.status !== 'error') {
      if (this.turn.running()) {
        Row({ space: 8 }) {
          LoadingProgress()
            .width(14)
            .height(14)
            .color(Theme.textFaint)
          Text(AgentTimeline.duration(this.liveSeconds(), false))
            .fontSize(12)
            .fontColor(Theme.textFaint)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      } else {
        Row({ space: 8 }) {
          if (this.turn.stopped) {
            Text('已停止')
              .fontSize(12)
              .fontColor(Theme.textFaint)
          } else if (this.turn.interrupted) {
            Text('已中断')
              .fontSize(12)
              .fontColor(Theme.textFaint)
          }
          if (this.doneDuration().length > 0) {
            Text(this.doneDuration())
              .fontSize(12)
              .fontColor(Theme.textFaint)
          }
          if (this.answer().length > 0) {
            Row({ space: 3 }) {
              SymbolGlyph(this.copied ? $r('sys.symbol.checkmark') : $r('sys.symbol.doc_filled_on_doc'))
                .fontSize(11)
                .fontColor([Theme.textFaint])
              Text(this.copied ? '已复制' : '复制')
                .fontSize(12)
                .fontColor(Theme.textFaint)
            }
            .padding({ left: 4, right: 4, top: 2, bottom: 2 })
            .onClick((): void => {
              this.copy();
            })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
    }
  }
}

/** 流式光标：正文尾部的呼吸圆点 */
@ComponentV2
export struct AgentStreamingCursorView {
  @Local private dim: boolean = false;
  private pulseTimer: number = -1;

  aboutToAppear(): void {
    this.pulseTimer = setInterval((): void => {
      this.dim = !this.dim;
    }, 900);
  }

  aboutToDisappear(): void {
    if (this.pulseTimer >= 0) {
      clearInterval(this.pulseTimer);
      this.pulseTimer = -1;
    }
  }

  build() {
    Circle()
      .width(10)
      .height(10)
      .fill(Theme.textMuted)
      .opacity(this.dim ? 0.45 : 1)
      .margin({ top: 4 })
  }
}
