/**
 * AI 回复正文的 Markdown 块级解析 + 行内样式（对应 iOS `DesignSystem/AgentMarkdown.swift`
 * 与 Web `components/markdown.tsx` + globals.css 的 `.markdown` 排版）。
 *
 * 选型同 iOS：自研轻量块级解析，行内语法自己拆成带样式的片段（ArkUI 用 `Text + Span` 渲染）。
 * - 块级：标题、段落、围栏代码块、有序/无序/任务列表（可嵌套）、引用、分隔线、GFM 表格、图片——
 *   覆盖 LLM 回复里实际出现的全部结构；
 * - 行内：粗体、斜体、删除线、行内代码、链接；
 * - 图片：`![说明](地址)` 拆成独立的图片块；外层包着链接的 `[![说明](图)](链接)` 整体算一张图。
 * 版式取 Web 移动端档：正文 17pt、行高约 28pt，标题 1.25/1.15/1.05em。
 */

/** 图片链接：外层链接（`[![说明](图)](链接)`）整体算一张图，不能只拆里面的图 */
class LinkedImageMatch {
  readonly start: number;
  readonly end: number;
  readonly alt: string;
  readonly url: string;
  readonly link: string;

  constructor(start: number, end: number, alt: string, url: string, link: string) {
    this.start = start;
    this.end = end;
    this.alt = alt;
    this.url = url;
    this.link = link;
  }
}

/** 块级结构（ArkTS 没有带关联值的枚举，用 kind + 载荷字段） */
export class AgentMarkdownBlock {
  /** 'heading' | 'paragraph' | 'code' | 'list' | 'quote' | 'rule' | 'table' | 'image' */
  readonly kind: string;
  /** heading：1..6 */
  level: number = 1;
  /** heading / paragraph / code / rule */
  text: string = '';
  /** code：围栏语言标记 */
  language: string = '';
  /** list */
  items: AgentMarkdownListItem[] = [];
  ordered: boolean = false;
  start: number = 1;
  /** quote：内部块 */
  inner: AgentMarkdownBlock[] = [];
  /** table */
  header: string[] = [];
  rows: string[][] = [];
  /** image */
  alt: string = '';
  url: string = '';
  link: string = '';

  constructor(kind: string) {
    this.kind = kind;
  }

  static heading(level: number, text: string): AgentMarkdownBlock {
    const block: AgentMarkdownBlock = new AgentMarkdownBlock('heading');
    block.level = level;
    block.text = text;
    return block;
  }

  static paragraph(text: string): AgentMarkdownBlock {
    const block: AgentMarkdownBlock = new AgentMarkdownBlock('paragraph');
    block.text = text;
    return block;
  }

  static code(language: string, text: string): AgentMarkdownBlock {
    const block: AgentMarkdownBlock = new AgentMarkdownBlock('code');
    block.language = language;
    block.text = text;
    return block;
  }

  static list(ordered: boolean, start: number, items: AgentMarkdownListItem[]): AgentMarkdownBlock {
    const block: AgentMarkdownBlock = new AgentMarkdownBlock('list');
    block.ordered = ordered;
    block.start = start;
    block.items = items;
    return block;
  }

  static quote(inner: AgentMarkdownBlock[]): AgentMarkdownBlock {
    const block: AgentMarkdownBlock = new AgentMarkdownBlock('quote');
    block.inner = inner;
    return block;
  }

  static rule(): AgentMarkdownBlock {
    return new AgentMarkdownBlock('rule');
  }

  static table(header: string[], rows: string[][]): AgentMarkdownBlock {
    const block: AgentMarkdownBlock = new AgentMarkdownBlock('table');
    block.header = header;
    block.rows = rows;
    return block;
  }

  static image(alt: string, url: string, link: string): AgentMarkdownBlock {
    const block: AgentMarkdownBlock = new AgentMarkdownBlock('image');
    block.alt = alt;
    block.url = url;
    block.link = link;
    return block;
  }

  isHeading(): boolean {
    return this.kind === 'heading';
  }
}

/** 列表项：checked 有值时是任务列表 */
export class AgentMarkdownListItem {
  checked: boolean = false;
  /** true = 任务列表项（勾选框），false = 普通列表项 */
  hasCheck: boolean = false;
  blocks: AgentMarkdownBlock[] = [];

  constructor(blocks: AgentMarkdownBlock[], hasCheck: boolean = false, checked: boolean = false) {
    this.blocks = blocks;
    this.hasCheck = hasCheck;
    this.checked = checked;
  }
}

/** 行内片段：一段文字 + 它带的样式（ArkUI `Span` 逐段渲染） */
export class AgentInlineSegment {
  /** 'text' | 'code' | 'link' */
  readonly kind: string;
  readonly text: string;
  readonly bold: boolean;
  readonly italic: boolean;
  readonly strike: boolean;
  readonly url: string;

  constructor(kind: string, text: string, bold: boolean = false, italic: boolean = false,
    strike: boolean = false, url: string = '') {
    this.kind = kind;
    this.text = text;
    this.bold = bold;
    this.italic = italic;
    this.strike = strike;
    this.url = url;
  }
}

/** 行内 Markdown → 带样式的片段（粗体/斜体/删除线/行内代码/链接） */
export class AgentInline {
  /** 链接颜色（同 iOS `AgentInline.linkColor`） */
  static readonly linkColor: string = '#8AB4FF';

  static parse(text: string): AgentInlineSegment[] {
    const segments: AgentInlineSegment[] = [];
    let plain: string = '';
    let i: number = 0;
    const pushPlain = (): void => {
      if (plain.length > 0) {
        segments.push(new AgentInlineSegment('text', plain));
        plain = '';
      }
    };
    while (i < text.length) {
      const ch: string = text.charAt(i);

      // 行内代码
      if (ch === '`') {
        const close: number = text.indexOf('`', i + 1);
        if (close > i + 1) {
          pushPlain();
          segments.push(new AgentInlineSegment('code', text.substring(i + 1, close)));
          i = close + 1;
          continue;
        }
      }

      // 粗体（** 或 __）
      if ((ch === '*' || ch === '_') && text.charAt(i + 1) === ch) {
        const marker: string = ch + ch;
        const close: number = text.indexOf(marker, i + 2);
        if (close > i + 2) {
          pushPlain();
          segments.push(new AgentInlineSegment('text', text.substring(i + 2, close), true));
          i = close + 2;
          continue;
        }
      }

      // 删除线
      if (ch === '~' && text.charAt(i + 1) === '~') {
        const close: number = text.indexOf('~~', i + 2);
        if (close > i + 2) {
          pushPlain();
          segments.push(new AgentInlineSegment('text', text.substring(i + 2, close), false, false, true));
          i = close + 2;
          continue;
        }
      }

      // 斜体（* 或 _）
      if (ch === '*' || ch === '_') {
        const close: number = text.indexOf(ch, i + 1);
        if (close > i + 1) {
          pushPlain();
          segments.push(new AgentInlineSegment('text', text.substring(i + 1, close), false, true));
          i = close + 1;
          continue;
        }
      }

      // 链接 [文字](地址)
      if (ch === '[') {
        const link: AgentLinkHit | null = AgentInline.linkAt(text, i);
        if (link !== null) {
          pushPlain();
          segments.push(link.segment);
          i = link.next;
          continue;
        }
      }

      plain += ch;
      i += 1;
    }
    pushPlain();
    if (segments.length === 0) {
      segments.push(new AgentInlineSegment('text', text));
    }
    return segments;
  }

  private static linkAt(text: string, at: number): AgentLinkHit | null {
    const closeBracket: number = text.indexOf(']', at + 1);
    if (closeBracket < 0 || text.charAt(closeBracket + 1) !== '(') {
      return null;
    }
    const closeParen: number = text.indexOf(')', closeBracket + 2);
    if (closeParen < 0) {
      return null;
    }
    const label: string = text.substring(at + 1, closeBracket);
    const url: string = text.substring(closeBracket + 2, closeParen).trim();
    if (url.length === 0) {
      return null;
    }
    return new AgentLinkHit(new AgentInlineSegment('link', label, false, false, false, url), closeParen + 1);
  }
}

/** 链接命中：片段 + 下一个扫描位置 */
class AgentLinkHit {
  readonly segment: AgentInlineSegment;
  readonly next: number;

  constructor(segment: AgentInlineSegment, next: number) {
    this.segment = segment;
    this.next = next;
  }
}

/** 列表标记 */
class MarkdownListMarker {
  readonly indent: number;
  readonly ordered: boolean;
  readonly number: number;
  /** 列表项正文相对行首的缩进（续行与嵌套内容以它为基准） */
  readonly contentIndent: number;
  readonly content: string;

  constructor(indent: number, ordered: boolean, number: number, contentIndent: number, content: string) {
    this.indent = indent;
    this.ordered = ordered;
    this.number = number;
    this.contentIndent = contentIndent;
    this.content = content;
  }
}

/** 行进游标：块级解析要边看边吃行 */
class MarkdownLines {
  readonly lines: string[];
  index: number = 0;

  constructor(lines: string[]) {
    this.lines = lines;
  }

  hasNext(): boolean {
    return this.index < this.lines.length;
  }

  peek(): string {
    return this.lines[this.index];
  }

  peekAt(offset: number): string | null {
    const at: number = this.index + offset;
    return at < this.lines.length ? this.lines[at] : null;
  }

  next(): string {
    const line: string = this.lines[this.index];
    this.index += 1;
    return line;
  }
}

export class AgentMarkdownParser {
  /** 图片语法：`![说明](地址 "可选标题")` */
  private static readonly imagePattern: RegExp = /!\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)/g;
  /** 带链接的图片：`[![说明](图)](链接)` */
  private static readonly linkedImagePattern: RegExp =
    /\[!\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)/g;
  /** 行内代码（成对反引号包住的部分）：里面的 `![x](y)` 是字面文字，不是图片 */
  private static readonly codeSpanPattern: RegExp = /(`+)[\s\S]*?\1/g;

  static parse(text: string): AgentMarkdownBlock[] {
    const normalized: string = text.replace(/\r\n/g, '\n');
    return AgentMarkdownParser.parseLines(new MarkdownLines(normalized.split('\n')));
  }

  private static parseLines(state: MarkdownLines): AgentMarkdownBlock[] {
    const blocks: AgentMarkdownBlock[] = [];
    let paragraph: string[] = [];

    const flushParagraph = (): void => {
      if (paragraph.length === 0) {
        return;
      }
      // 段内软换行按空格连接（与浏览器渲染一致）；行尾两空格或反斜杠是硬换行
      let text: string = '';
      for (let i = 0; i < paragraph.length; i++) {
        const line: string = paragraph[i];
        const hard: boolean = line.endsWith('  ') || line.endsWith('\\');
        let content: string = line.trim();
        if (content.endsWith('\\')) {
          content = content.substring(0, content.length - 1);
        }
        text += content;
        if (i < paragraph.length - 1) {
          text += hard ? '\n' : ' ';
        }
      }
      paragraph = [];
      const pieces: AgentMarkdownBlock[] = AgentMarkdownParser.splitImages(text);
      for (const piece of pieces) {
        blocks.push(piece);
      }
    };

    while (state.hasNext()) {
      const line: string = state.peek();
      const trimmed: string = line.trim();

      if (trimmed.length === 0) {
        flushParagraph();
        state.next();
        continue;
      }

      // 围栏代码块
      const fence: string = AgentMarkdownParser.fenceMarker(trimmed);
      if (fence.length > 0) {
        flushParagraph();
        const language: string = trimmed.substring(fence.length).trim();
        const indent: number = AgentMarkdownParser.leadingSpaces(line);
        const body: string[] = [];
        state.next();
        while (state.hasNext()) {
          const next: string = state.next();
          if (next.trim().startsWith(fence)) {
            break;
          }
          // 列表内缩进的代码块：去掉与围栏同宽的前导空格
          const strip: number = Math.min(indent, AgentMarkdownParser.leadingSpaces(next));
          body.push(next.substring(strip));
        }
        blocks.push(AgentMarkdownBlock.code(language, body.join('\n')));
        continue;
      }

      // 标题
      const heading: number = AgentMarkdownParser.headingLevel(trimmed);
      if (heading > 0) {
        flushParagraph();
        let text: string = trimmed;
        while (text.startsWith('#')) {
          text = text.substring(1);
        }
        text = text.trim().replace(/\s+#+$/, '');
        blocks.push(AgentMarkdownBlock.heading(heading, text));
        state.next();
        continue;
      }

      // 分隔线（放在列表判断前：「- - -」「***」不是列表）
      if (AgentMarkdownParser.isRule(trimmed)) {
        // 段落后紧跟的「---」是 Setext 二级标题
        if (paragraph.length > 0 && /^-+$/.test(trimmed)) {
          const text: string = paragraph.join(' ').trim();
          paragraph = [];
          blocks.push(AgentMarkdownBlock.heading(2, text));
        } else {
          flushParagraph();
          blocks.push(AgentMarkdownBlock.rule());
        }
        state.next();
        continue;
      }

      // 引用
      if (trimmed.startsWith('>')) {
        flushParagraph();
        const body: string[] = [];
        while (state.hasNext()) {
          const next: string = state.peek();
          const t: string = next.trim();
          if (t.startsWith('>')) {
            let content: string = t.substring(1);
            if (content.startsWith(' ')) {
              content = content.substring(1);
            }
            body.push(content);
          } else if (t.length > 0 && body.length > 0 && body[body.length - 1].length > 0
            && !AgentMarkdownParser.isRule(t)
            && AgentMarkdownParser.fenceMarker(t).length === 0
            && AgentMarkdownParser.headingLevel(t) === 0
            && AgentMarkdownParser.listMarker(next) === null) {
            body.push(t); // 惰性续行
          } else {
            break;
          }
          state.next();
        }
        blocks.push(AgentMarkdownBlock.quote(AgentMarkdownParser.parseLines(new MarkdownLines(body))));
        continue;
      }

      // 表格：表头行 + 分隔行
      const nextLine: string | null = state.peekAt(1);
      if (trimmed.includes('|') && nextLine !== null
        && AgentMarkdownParser.isTableSeparator(nextLine)) {
        flushParagraph();
        const header: string[] = AgentMarkdownParser.tableCells(trimmed);
        state.next();
        state.next();
        const rows: string[][] = [];
        while (state.hasNext()) {
          const next: string = state.peek();
          const t: string = next.trim();
          if (t.length === 0 || !t.includes('|')) {
            break;
          }
          let cells: string[] = AgentMarkdownParser.tableCells(t);
          while (cells.length < header.length) {
            cells.push('');
          }
          rows.push(cells.slice(0, header.length));
          state.next();
        }
        blocks.push(AgentMarkdownBlock.table(header, rows));
        continue;
      }

      // 列表
      const marker: MarkdownListMarker | null = AgentMarkdownParser.listMarker(line);
      if (marker !== null) {
        flushParagraph();
        const list: AgentMarkdownBlock = AgentMarkdownParser.parseList(state, marker);
        blocks.push(list);
        continue;
      }

      paragraph.push(line);
      state.next();
    }
    flushParagraph();
    return blocks;
  }

  // MARK: 列表

  private static parseList(state: MarkdownLines, first: MarkdownListMarker): AgentMarkdownBlock {
    const items: AgentMarkdownListItem[] = [];
    let marker: MarkdownListMarker | null = null;
    let body: string[] = [];

    const closeItem = (): void => {
      if (marker === null) {
        return;
      }
      let lines: string[] = body;
      let hasCheck: boolean = false;
      let checked: boolean = false;
      if (lines.length > 0) {
        const head: string = lines[0];
        if (head.startsWith('[ ] ')) {
          hasCheck = true;
          checked = false;
          lines[0] = head.substring(4);
        } else if (head.toLowerCase().startsWith('[x] ')) {
          hasCheck = true;
          checked = true;
          lines[0] = head.substring(4);
        }
      }
      while (lines.length > 0 && lines[lines.length - 1].trim().length === 0) {
        lines = lines.slice(0, lines.length - 1);
      }
      items.push(new AgentMarkdownListItem(AgentMarkdownParser.parseLines(new MarkdownLines(lines)),
        hasCheck, checked));
      marker = null;
      body = [];
    };

    while (state.hasNext()) {
      const line: string = state.peek();
      const trimmed: string = line.trim();
      const current: MarkdownListMarker | null = marker;
      const itemMarker: MarkdownListMarker | null = AgentMarkdownParser.listMarker(line);
      const contentIndent: number = current !== null ? current.contentIndent : first.contentIndent;

      if (itemMarker !== null && itemMarker.indent < contentIndent && itemMarker.indent >= first.indent - 1) {
        // 同级新列表项（有序/无序换了类型就结束本列表）
        if (itemMarker.ordered !== first.ordered) {
          break;
        }
        closeItem();
        marker = itemMarker;
        body = [itemMarker.content];
        state.next();
        continue;
      }

      if (current === null) {
        break;
      }
      const indent: number = AgentMarkdownParser.leadingSpaces(line);
      if (trimmed.length === 0) {
        // 空行：后面还有缩进内容或同类列表项才算列表继续
        const nextNonEmpty: string | null = AgentMarkdownParser.nextNonEmpty(state);
        let continues: boolean = false;
        if (nextNonEmpty !== null) {
          const nextIndent: number = AgentMarkdownParser.leadingSpaces(nextNonEmpty);
          if (nextIndent >= current.contentIndent) {
            continues = true;
          } else {
            const m: MarkdownListMarker | null = AgentMarkdownParser.listMarker(nextNonEmpty);
            if (m !== null && m.ordered === first.ordered && m.indent < current.contentIndent) {
              continues = true;
            }
          }
        }
        if (!continues) {
          break;
        }
        body.push('');
      } else if (indent >= current.contentIndent
        || (indent > first.indent && itemMarker !== null)) {
        // 缩进续行 / 嵌套列表：去掉本项正文缩进后归入本项
        body.push(line.substring(Math.min(indent, current.contentIndent)));
      } else if (itemMarker === null
        && AgentMarkdownParser.fenceMarker(trimmed).length === 0
        && AgentMarkdownParser.headingLevel(trimmed) === 0
        && body[body.length - 1].trim().length > 0) {
        body.push(trimmed); // 惰性续行
      } else {
        break;
      }
      state.next();
    }
    closeItem();
    return AgentMarkdownBlock.list(first.ordered, first.number, items);
  }

  private static nextNonEmpty(state: MarkdownLines): string | null {
    let offset: number = 1;
    while (true) {
      const line: string | null = state.peekAt(offset);
      if (line === null) {
        return null;
      }
      if (line.trim().length > 0) {
        return line;
      }
      offset += 1;
    }
  }

  // MARK: 小工具

  private static leadingSpaces(line: string): number {
    let count: number = 0;
    while (count < line.length && line.charAt(count) === ' ') {
      count += 1;
    }
    return count;
  }

  /** 围栏标记：``` 或 ~~~，返回整串反引号/波浪线；空串 = 不是围栏 */
  private static fenceMarker(trimmed: string): string {
    if (trimmed.startsWith('```')) {
      return AgentMarkdownParser.repeatChar('`', AgentMarkdownParser.countLeading(trimmed, '`'));
    }
    if (trimmed.startsWith('~~~')) {
      return AgentMarkdownParser.repeatChar('~', AgentMarkdownParser.countLeading(trimmed, '~'));
    }
    return '';
  }

  private static countLeading(text: string, ch: string): number {
    let count: number = 0;
    while (count < text.length && text.charAt(count) === ch) {
      count += 1;
    }
    return count;
  }

  private static repeatChar(ch: string, count: number): string {
    let out: string = '';
    for (let i = 0; i < count; i++) {
      out += ch;
    }
    return out;
  }

  /** 标题层级；0 = 不是标题 */
  private static headingLevel(trimmed: string): number {
    const hashes: number = AgentMarkdownParser.countLeading(trimmed, '#');
    if (hashes < 1 || hashes > 6) {
      return 0;
    }
    const rest: string = trimmed.substring(hashes);
    return rest.length === 0 || rest.startsWith(' ') ? hashes : 0;
  }

  private static isRule(trimmed: string): boolean {
    const compact: string = trimmed.replace(/ /g, '');
    if (compact.length < 3) {
      return false;
    }
    const first: string = compact.charAt(0);
    if (first !== '-' && first !== '*' && first !== '_') {
      return false;
    }
    for (let i = 0; i < compact.length; i++) {
      if (compact.charAt(i) !== first) {
        return false;
      }
    }
    return true;
  }

  private static isTableSeparator(line: string): boolean {
    const t: string = line.trim();
    if (!t.includes('-')) {
      return false;
    }
    return /^\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?$/.test(t);
  }

  private static tableCells(line: string): string[] {
    let t: string = line.trim();
    if (t.startsWith('|')) {
      t = t.substring(1);
    }
    if (t.endsWith('|') && !t.endsWith('\\|')) {
      t = t.substring(0, t.length - 1);
    }
    // 单元格里转义的竖线 \| 不是分隔符
    const placeholder: string = '\uE000';
    const pieces: string[] = t.replace(/\\\|/g, placeholder).split('|');
    const cells: string[] = [];
    for (const piece of pieces) {
      cells.push(piece.replace(new RegExp(placeholder, 'g'), '|').trim());
    }
    return cells;
  }

  /** 列表标记：`- ` / `* ` / `+ ` / `1. ` / `1) ` */
  private static listMarker(line: string): MarkdownListMarker | null {
    const indent: number = AgentMarkdownParser.leadingSpaces(line);
    const rest: string = line.substring(indent);
    if (rest.length >= 2) {
      const first: string = rest.charAt(0);
      if ((first === '-' || first === '*' || first === '+') && rest.charAt(1) === ' ') {
        return new MarkdownListMarker(indent, false, 0, indent + 2, rest.substring(2));
      }
    }
    let digits: number = 0;
    while (digits < rest.length && /[0-9]/.test(rest.charAt(digits))) {
      digits += 1;
    }
    if (digits > 0 && digits <= 9 && rest.length > digits + 1) {
      const delimiter: string = rest.charAt(digits);
      if ((delimiter === '.' || delimiter === ')') && rest.charAt(digits + 1) === ' ') {
        return new MarkdownListMarker(indent, true, Number(rest.substring(0, digits)),
          indent + digits + 2, rest.substring(digits + 2));
      }
    }
    return null;
  }

  // MARK: 段落里的图片

  /**
   * 段落里的图片拆成独立的图片块，前后文字仍是段落（ArkUI 行内文本不渲染图片）。
   * 边界处理同 Web react-markdown：行内代码里的不算图片；外面包着链接的整体算一张图
   */
  static splitImages(text: string): AgentMarkdownBlock[] {
    if (!text.includes('![')) {
      return [AgentMarkdownBlock.paragraph(text)];
    }
    const codeSpans: number[][] = [];
    AgentMarkdownParser.codeSpanPattern.lastIndex = 0;
    let codeMatch: RegExpExecArray | null = AgentMarkdownParser.codeSpanPattern.exec(text);
    while (codeMatch !== null) {
      codeSpans.push([codeMatch.index, codeMatch.index + codeMatch[0].length]);
      codeMatch = AgentMarkdownParser.codeSpanPattern.exec(text);
    }
    const inCode = (start: number, end: number): boolean => {
      for (const span of codeSpans) {
        if (start < span[1] && end > span[0]) {
          return true;
        }
      }
      return false;
    };

    const found: LinkedImageMatch[] = [];
    AgentMarkdownParser.linkedImagePattern.lastIndex = 0;
    let linked: RegExpExecArray | null = AgentMarkdownParser.linkedImagePattern.exec(text);
    while (linked !== null) {
      const end: number = linked.index + linked[0].length;
      if (!inCode(linked.index, end)) {
        found.push(new LinkedImageMatch(linked.index, end, linked[1], linked[2], linked[3]));
      }
      linked = AgentMarkdownParser.linkedImagePattern.exec(text);
    }
    AgentMarkdownParser.imagePattern.lastIndex = 0;
    let bare: RegExpExecArray | null = AgentMarkdownParser.imagePattern.exec(text);
    while (bare !== null) {
      const end: number = bare.index + bare[0].length;
      let overlaps: boolean = false;
      for (const item of found) {
        if (bare.index < item.end && end > item.start) {
          overlaps = true;
          break;
        }
      }
      if (!overlaps && !inCode(bare.index, end)) {
        found.push(new LinkedImageMatch(bare.index, end, bare[1], bare[2], ''));
      }
      bare = AgentMarkdownParser.imagePattern.exec(text);
    }
    if (found.length === 0) {
      return [AgentMarkdownBlock.paragraph(text)];
    }
    found.sort((a: LinkedImageMatch, b: LinkedImageMatch): number => a.start - b.start);

    const blocks: AgentMarkdownBlock[] = [];
    let cursor: number = 0;
    const appendText = (from: number, to: number): void => {
      const piece: string = text.substring(from, to).trim();
      if (piece.length > 0) {
        blocks.push(AgentMarkdownBlock.paragraph(piece));
      }
    };
    for (const item of found) {
      appendText(cursor, item.start);
      blocks.push(AgentMarkdownBlock.image(item.alt, item.url, item.link));
      cursor = item.end;
    }
    appendText(cursor, text.length);
    return blocks.length === 0 ? [AgentMarkdownBlock.paragraph(text)] : blocks;
  }
}
