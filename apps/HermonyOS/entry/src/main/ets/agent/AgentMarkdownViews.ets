import { LengthMetrics } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { Theme } from '../theme/AppTheme';
import { RemoteImage } from '../common/RemoteImage';
import { ImageUrls } from '../common/ImageUrls';
import { AppModel } from '../common/AppModel';
import {
  AgentInline,
  AgentInlineSegment,
  AgentMarkdownBlock,
  AgentMarkdownListItem,
  AgentMarkdownParser
} from './AgentMarkdown';

/**
 * Markdown 正文的 ArkUI 渲染（对应 iOS `AgentMarkdownBlocks` / `AgentMarkdownBlockView`）。
 *
 * 行内样式用原生 `Text + Span`（粗体/斜体/删除线/行内代码/链接），块级用 Column/Row/Scroll 拼：
 * 版式逐值照 iOS——正文 17pt、行距 0.6em、标题 1.25/1.15/1.05em 加粗、
 * 代码块 0.82em 等宽 + 右上角复制、引用左侧 3px 竖线、表格横向可滚动。
 */

/** 复制到系统剪贴板（顶部函数：`@Builder` / 静态上下文里不能用 `this`） */
export function copyPlainText(text: string): void {
  const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
  pasteboard.getSystemPasteboard().setDataSync(data);
}

/** 行内 Markdown 文本（粗体/斜体/删除线/行内代码/链接） */
@ComponentV2
export struct AgentInlineText {
  @Require @Param text: string;
  @Param textSize: number = 15;
  @Param color: string = Theme.text;
  /** 行距（iOS 正文为 0.6em，标题 3pt） */
  @Param lineSpacing: number = 0;
  /** 可长按选择复制（同 iOS `.textSelection(.enabled)`） */
  @Param selectable: boolean = true;
  /** 段内字重（标题、表头用加粗；组件不能链式 .fontWeight，只能当参数传） */
  @Param weight: FontWeight = FontWeight.Normal;

  @Event onLink: (url: string) => void = (url: string): void => {
  };

  @Local private segments: AgentInlineSegment[] = [];

  aboutToAppear(): void {
    this.segments = AgentInline.parse(this.text);
  }

  @Monitor('text')
  private onTextChanged(): void {
    this.segments = AgentInline.parse(this.text);
  }

  build() {
    Text() {
      ForEach(this.segments, (segment: AgentInlineSegment) => {
        Span(segment.text)
          .fontSize(segment.kind === 'code' ? this.textSize * 0.86 : this.textSize)
          .fontColor(segment.kind === 'link' ? AgentInline.linkColor : this.color)
          .fontWeight(segment.bold ? FontWeight.Bold : this.weight)
          .fontStyle(segment.italic ? FontStyle.Italic : FontStyle.Normal)
          .fontFamily(segment.kind === 'code' ? 'monospace' : '')
          .textBackgroundStyle(segment.kind === 'code'
            ? { color: 'rgba(255, 255, 255, 0.09)', radius: 4 } : { color: Color.Transparent, radius: 0 })
          .decoration({
            type: segment.strike ? TextDecorationType.LineThrough
              : (segment.kind === 'link' ? TextDecorationType.Underline : TextDecorationType.None),
            color: segment.kind === 'link' ? AgentInline.linkColor : this.color
          })
          .onClick((): void => {
            if (segment.kind === 'link') {
              this.onLink(segment.url);
            }
          })
      }, (segment: AgentInlineSegment, index: number): string => `${index}-${segment.kind}-${segment.text.length}`)
    }
    .fontSize(this.textSize)
    .fontColor(this.color)
    .lineSpacing(LengthMetrics.vp(this.lineSpacing))
    .copyOption(this.selectable ? CopyOptions.InApp : CopyOptions.None)
    .width('100%')
    .textAlign(TextAlign.Start)
  }
}

/** 围栏代码块：横向滚动 + 右上角常驻复制（手指划选代码在移动端很难用） */
@ComponentV2
export struct AgentCodeBlockView {
  @Require @Param code: string;
  /** 正文字号；代码用它的 0.82 倍 */
  @Param textSize: number = 15;
  @Param selectable: boolean = true;

  @Local private copied: boolean = false;
  private resetTimer: number = -1;

  aboutToDisappear(): void {
    if (this.resetTimer >= 0) {
      clearTimeout(this.resetTimer);
      this.resetTimer = -1;
    }
  }

  private copy(): void {
    copyPlainText(this.code);
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
    Stack({ alignContent: Alignment.TopEnd }) {
      Scroll() {
        Text(this.code)
          .fontSize(this.textSize * 0.82)
          .fontFamily('monospace')
          .fontColor('rgba(243, 245, 249, 0.88)')
          .lineSpacing(LengthMetrics.vp(this.textSize * 0.82 * 0.45))
          .copyOption(this.selectable ? CopyOptions.InApp : CopyOptions.None)
          .padding({ left: 14, right: 42, top: 12, bottom: 12 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .align(Alignment.TopStart)
      .backgroundColor('rgba(255, 255, 255, 0.04)')
      .borderRadius(10)
      .border({ width: 1, color: 'rgba(255, 255, 255, 0.07)' })

      Row() {
        SymbolGlyph(this.copied ? $r('sys.symbol.checkmark') : $r('sys.symbol.doc_filled_on_doc'))
          .fontSize(12)
          .fontColor([this.copied ? Theme.ok : Theme.textFaint])
      }
      .width(28)
      .height(28)
      .justifyContent(FlexAlign.Center)
      .backgroundColor('rgba(28, 28, 32, 0.9)')
      .borderRadius(7)
      .border({ width: 1, color: Theme.line })
      .margin({ top: 6, right: 6 })
      .onClick((): void => {
        this.copy();
      })
    }
    .width('100%')
  }
}

/** Markdown 块列表（对应 iOS `AgentMarkdownBlocks`） */
@ComponentV2
export struct AgentMarkdownBlocksView {
  @Require @Param blocks: AgentMarkdownBlock[];
  @Param textSize: number = 15;

  @Event onLink: (url: string) => void = (url: string): void => {
  };

  /** 段间距 0.75em，标题前再多 0.65em（Web：h1..h4 margin-top 1.4em） */
  private topSpace(index: number): number {
    if (index === 0) {
      return 0;
    }
    return this.blocks[index].isHeading() ? this.textSize * 0.65 : 0;
  }

  build() {
    Column() {
      ForEach(this.blocks, (block: AgentMarkdownBlock, index: number) => {
        Column() {
          if (block.kind === 'heading') {
            this.HeadingBlock(block)
          } else if (block.kind === 'paragraph') {
            AgentInlineText({
              text: block.text,
              textSize: this.textSize,
              color: Theme.text,
              lineSpacing: this.textSize * 0.6,
              onLink: this.onLink
            })
          } else if (block.kind === 'code') {
            AgentCodeBlockView({ code: block.text, textSize: this.textSize })
          } else if (block.kind === 'image') {
            this.ImageBlock(block)
          } else if (block.kind === 'list') {
            this.ListBlock(block)
          } else if (block.kind === 'quote') {
            this.QuoteBlock(block)
          } else if (block.kind === 'rule') {
            this.RuleBlock()
          } else if (block.kind === 'table') {
            this.TableBlock(block)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ top: this.topSpace(index) })
      }, (block: AgentMarkdownBlock, index: number): string => `${index}-${block.kind}-${block.text.length}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ bottom: this.textSize * 0.75 })
  }

  @Builder
  HeadingBlock(block: AgentMarkdownBlock) {
    AgentInlineText({
      text: block.text,
      textSize: this.textSize * (block.level === 1 ? 1.25 : (block.level === 2 ? 1.15 : 1.05)),
      color: Theme.text,
      lineSpacing: 3,
      weight: FontWeight.Bold,
      onLink: this.onLink
    })
  }

  @Builder
  ImageBlock(block: AgentMarkdownBlock) {
    RemoteImage({
      url: ImageUrls.resolve(AppModel.origin(), block.url, null) ?? '',
      fit: true,
      placeholderText: block.alt.length > 0 ? block.alt : '图片加载失败'
    })
      .width('100%')
      .constraintSize({ maxHeight: 420 })
      .borderRadius(10)
      .onClick((): void => {
        if (block.link.length > 0) {
          this.onLink(block.link);
        }
      })
  }

  @Builder
  ListBlock(block: AgentMarkdownBlock) {
    Column() {
      ForEach(block.items, (item: AgentMarkdownListItem, index: number) => {
        Row({ space: 6 }) {
          Row() {
            if (item.hasCheck) {
              SymbolGlyph(item.checked ? $r('sys.symbol.checkmark_square_fill') : $r('sys.symbol.square'))
                .fontSize(this.textSize * 0.85)
                .fontColor([Theme.textMuted])
            } else if (block.ordered) {
              Text(`${block.start + index}.`)
                .fontSize(this.textSize)
                .fontColor(Theme.textMuted)
            } else {
              Text('•')
                .fontSize(this.textSize)
                .fontColor(Theme.textMuted)
            }
          }
          .constraintSize({ minWidth: this.textSize * 1.1 })
          .justifyContent(FlexAlign.End)

          AgentMarkdownBlocksView({ blocks: item.blocks, textSize: this.textSize, onLink: this.onLink })
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
        .padding({ bottom: this.textSize * 0.3 })
      }, (item: AgentMarkdownListItem, index: number): string => `${index}-${item.blocks.length}-${item.checked}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  QuoteBlock(block: AgentMarkdownBlock) {
    Row() {
      Divider()
        .vertical(true)
        .strokeWidth(3)
        .color('rgba(255, 255, 255, 0.14)')
        .height('100%')
      AgentMarkdownBlocksView({ blocks: block.inner, textSize: this.textSize, onLink: this.onLink })
        .layoutWeight(1)
        .padding({ left: this.textSize * 0.6 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ left: this.textSize * 0.3 })
  }

  @Builder
  RuleBlock() {
    Divider()
      .strokeWidth(1)
      .color('rgba(255, 255, 255, 0.1)')
      .margin({ top: this.textSize * 0.6, bottom: this.textSize * 0.6 })
  }

  /** 表格：横向可滚动（列多时不至于把字挤成一列一个字），单元格细描边、表头浅底加粗 */
  @Builder
  TableBlock(block: AgentMarkdownBlock) {
    Scroll() {
      Grid() {
        ForEach(block.header, (cell: string, index: number) => {
          GridItem() {
            this.TableCell(cell, true)
          }
        }, (cell: string, index: number): string => `h-${index}-${cell.length}`)
        ForEach(block.rows, (row: string[], rowIndex: number) => {
          ForEach(row, (cell: string, cellIndex: number) => {
            GridItem() {
              this.TableCell(cell, rowIndex % 2 === 0)
            }
          }, (cell: string, cellIndex: number): string => `r-${rowIndex}-${cellIndex}-${cell.length}`)
        }, (row: string[], rowIndex: number): string => `row-${rowIndex}-${row.length}`)
      }
      .columnsTemplate(this.tableTemplate(block.header.length))
      .columnsGap(0)
      .rowsGap(0)
      .width(Math.max(block.header.length, 1) * 104)
      .constraintSize({ minWidth: '100%' })
      .border({ width: 1, color: 'rgba(255, 255, 255, 0.1)' })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .align(Alignment.TopStart)
  }

  /** 表格列模板：每列等宽 */
  private tableTemplate(columns: number): string {
    let template: string = '';
    for (let i = 0; i < Math.max(columns, 1); i++) {
      template += i === 0 ? '1fr' : ' 1fr';
    }
    return template;
  }

  @Builder
  TableCell(cell: string, bold: boolean) {
    AgentInlineText({
      text: cell.replace(/<br>/g, '\n'),
      textSize: this.textSize * 0.93,
      color: Theme.text,
      lineSpacing: 3,
      selectable: true,
      weight: bold ? FontWeight.Bold : FontWeight.Normal,
      onLink: this.onLink
    })
      .layoutWeight(1)
      .padding({ left: 12, right: 12, top: 7, bottom: 7 })
      .backgroundColor(bold ? 'rgba(255, 255, 255, 0.04)' : Color.Transparent)
      .border({ width: 0.5, color: 'rgba(255, 255, 255, 0.1)' })
  }
}
