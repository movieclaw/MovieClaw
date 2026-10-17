/**
 * 命名模板的纯逻辑（镜像 iOS `SettingsBScrapeModel.swift` 的 `SettingsBScrapeNaming`、
 * Web `scrape-settings-section` 的渲染器与轻校验）。
 *
 * 渲染三步与后端一一对应（后端 `services/library/naming.py`）：
 * ① 整组丢弃占位符全空的括号组 → ② 替换占位符 → ③ 收缩清洗。
 * 改后端规则时 Web / iOS 与这里都要同步改；这里只做「边打字边看结果」的预览
 * 与即时反馈，真正落盘与保存校验以后端为准。
 */

/** 占位符按钮：按钮上写中文名，插入的是 key */
export class NamingToken {
  readonly key: string;
  readonly name: string;

  constructor(key: string, name: string) {
    this.key = key;
    this.name = name;
  }
}

/** 占位符分组（片名与编号 / 季集 / 文件规格 / 来源） */
export class NamingTokenGroup {
  readonly label: string;
  readonly tokens: NamingToken[];

  constructor(label: string, tokens: NamingToken[]) {
    this.label = label;
    this.tokens = tokens;
  }
}

/** 一个命名模板字段 */
export class NamingField {
  /** 后端字段名 */
  readonly key: string;
  readonly label: string;
  readonly note: string;
  /** 留空时使用的默认模板 */
  readonly fallback: string;
  /** 该字段允许的占位符 */
  readonly tokens: string[];

  constructor(key: string, label: string, note: string, fallback: string, tokens: string[]) {
    this.key = key;
    this.label = label;
    this.note = note;
    this.fallback = fallback;
    this.tokens = tokens;
  }
}

export class ScrapeNaming {
  /** 片名类占位符：同一模板里值相同的只保留第一次出现（「风筝 (风筝)」→「风筝」） */
  static readonly titleTokens: string[] = ['title', 'original_title', 'english_title'];
  /** 超长时可截短的自由文本占位符；编号、年份、规格不截 */
  static readonly shrinkableTokens: string[] = [
    'title', 'original_title', 'english_title', 'episode_title', 'season_name', 'release_name'
  ];
  /** 单段名字字节上限与截短保底，与后端 MAX_SEGMENT_BYTES / _SHRINK_FLOOR_BYTES 一致 */
  static readonly maxSegmentBytes: number = 200;
  static readonly shrinkFloorBytes: number = 30;

  static readonly commonTokens: string[] = ['title', 'original_title', 'english_title', 'year', 'tmdb_id', 'imdb_id', 'douban_id'];
  static readonly fileAttrTokens: string[] = [
    'resolution', 'video_codec', 'hdr', 'bit_depth', 'audio',
    'media_source', 'release_group', 'site', 'release_name'
  ];

  static readonly fields: NamingField[] = [
    new NamingField('naming_entry_dir', '条目目录', '电影与剧集共用', '{title} ({year})', ScrapeNaming.commonTokens),
    new NamingField('naming_movie_file', '电影文件名', '', '{title} ({year})',
      ScrapeNaming.commonTokens.concat(ScrapeNaming.fileAttrTokens)),
    new NamingField('naming_season_dir', '季目录', '', 'Season {season:02d}',
      ScrapeNaming.commonTokens.concat(['season', 'season_name'])),
    new NamingField('naming_episode_file', '剧集文件名', '', '{title} ({year}) - S{season:02d}E{episode:02d}',
      ScrapeNaming.commonTokens.concat(ScrapeNaming.fileAttrTokens)
        .concat(['season', 'season_name', 'episode', 'episode_title']))
  ];

  /** 占位符按类别分组展示，按钮上写中文名（与 Web TOKEN_GROUPS 同一份） */
  static readonly tokenGroups: NamingTokenGroup[] = [
    new NamingTokenGroup('片名与编号', [
      new NamingToken('title', '片名'),
      new NamingToken('original_title', '原名'),
      new NamingToken('english_title', '英文名'),
      new NamingToken('year', '年份'),
      new NamingToken('tmdb_id', 'TMDB ID'),
      new NamingToken('imdb_id', 'IMDb ID'),
      new NamingToken('douban_id', '豆瓣 ID')
    ]),
    new NamingTokenGroup('季集', [
      new NamingToken('season', '季号'),
      new NamingToken('season_name', '季名'),
      new NamingToken('episode', '集号'),
      new NamingToken('episode_title', '集名')
    ]),
    new NamingTokenGroup('文件规格', [
      new NamingToken('resolution', '分辨率'),
      new NamingToken('video_codec', '视频编码'),
      new NamingToken('hdr', 'HDR'),
      new NamingToken('bit_depth', '位深'),
      new NamingToken('audio', '音轨')
    ]),
    new NamingTokenGroup('来源', [
      new NamingToken('media_source', '片源'),
      new NamingToken('release_group', '发布组'),
      new NamingToken('site', '站点'),
      new NamingToken('release_name', '原始文件名')
    ])
  ];

  /** 只用于取 .source，exec 一律用 `new RegExp(...)` 造全新实例（全局正则有 lastIndex 状态） */
  private static readonly tokenRE: RegExp = /\{([A-Za-z0-9_]+)(?::0(\d)d)?\}/g;
  private static readonly bracketGroupRE: RegExp = /[(\[【][^()\[\]【】]*[)\]】]/g;

  private static movieMap: Map<string, string> | null = null;
  private static episodeMap: Map<string, string> | null = null;

  static fieldByKey(key: string): NamingField {
    for (const field of ScrapeNaming.fields) {
      if (field.key === key) {
        return field;
      }
    }
    return ScrapeNaming.fields[3];
  }

  /** 前端侧轻校验：与后端同口径，只为即时反馈；能否保存以后端返回为准 */
  static errorFor(field: NamingField, template: string): string | null {
    if (template.trim().length === 0) {
      return null; // 空 = 用默认模板
    }
    if (template.indexOf('/') >= 0 || template.indexOf('\\') >= 0) {
      return '不能包含路径分隔符（目录层级是固定的）';
    }
    const unknown: string[] = [];
    for (const name of ScrapeNaming.tokensIn(template)) {
      if (field.tokens.indexOf(name) < 0 && unknown.indexOf(name) < 0) {
        unknown.push(name);
      }
    }
    if (unknown.length > 0) {
      const parts: string[] = [];
      for (const name of unknown) {
        parts.push(`{${name}}`);
      }
      return `不可用的占位符：${parts.join('、')}`;
    }
    return null;
  }

  /** 生效模板：留空时用默认模板 */
  static effective(field: NamingField, value: string): string {
    const trimmed: string = value.trim();
    return trimmed.length === 0 ? field.fallback : trimmed;
  }

  /** 模板里出现的占位符名（按出现顺序去重） */
  static tokensIn(template: string): string[] {
    const out: string[] = [];
    const re: RegExp = new RegExp(ScrapeNaming.tokenRE.source, 'g');
    let match: RegExpExecArray | null = re.exec(template);
    while (match !== null) {
      const name: string | undefined = match[1];
      if (name !== undefined && name.length > 0 && out.indexOf(name) < 0) {
        out.push(name);
      }
      match = re.exec(template);
    }
    return out;
  }

  /** 渲染：片名去重 → 渲染 → 超长时逐个截短最长的自由文本（与后端 render 同序） */
  static render(template: string, sample: Map<string, string>): string {
    const ctx: Map<string, string> = ScrapeNaming.copyOf(sample);
    const seen: Set<string> = new Set<string>();
    for (const name of ScrapeNaming.tokensIn(template)) {
      if (ScrapeNaming.titleTokens.indexOf(name) < 0) {
        continue;
      }
      const value: string = ScrapeNaming.tokenValue(ctx, name, null).toLowerCase();
      if (value.length === 0) {
        continue;
      }
      if (seen.has(value)) {
        ctx.set(name, '');
      }
      seen.add(value);
    }
    let text: string = ScrapeNaming.renderOnce(template, ctx);
    const rounds: number = ScrapeNaming.shrinkableTokens.length * 2;
    for (let i: number = 0; i < rounds; i++) {
      const over: number = ScrapeNaming.byteLen(text) - ScrapeNaming.maxSegmentBytes;
      if (over <= 0) {
        return text;
      }
      let bestName: string = '';
      let bestLen: number = -1;
      for (const token of ScrapeNaming.shrinkableTokens) {
        const len: number = ScrapeNaming.byteLen(ScrapeNaming.tokenValue(ctx, token, null));
        if (len > bestLen) {
          bestLen = len;
          bestName = token;
        }
      }
      if (bestName.length === 0 || bestLen <= ScrapeNaming.shrinkFloorBytes) {
        break;
      }
      const cut: string = ScrapeNaming.cutBytes(ScrapeNaming.tokenValue(ctx, bestName, null),
        Math.max(bestLen - over, ScrapeNaming.shrinkFloorBytes));
      ctx.set(bestName, ScrapeNaming.trimEdges(cut));
      text = ScrapeNaming.renderOnce(template, ctx);
    }
    const result: string = ScrapeNaming.sanitize(ScrapeNaming.cutBytes(text, ScrapeNaming.maxSegmentBytes));
    return result.length === 0 ? '未命名' : result;
  }

  /** 预览样例（电影）：一部 4K 电影，字段齐全便于看清每个占位符的效果（与 Web 同一组样例） */
  static movieSample(): Map<string, string> {
    if (ScrapeNaming.movieMap === null) {
      ScrapeNaming.movieMap = ScrapeNaming.buildSample([
        'title', '沙丘：第二部',
        'original_title', 'Dune: Part Two',
        'english_title', 'Dune: Part Two',
        'year', '2024',
        'tmdb_id', '693134',
        'imdb_id', 'tt15239678',
        'douban_id', '35575567',
        'resolution', '2160p',
        'video_codec', 'HEVC',
        'hdr', 'DV',
        'bit_depth', '10bit',
        'audio', 'TrueHD Atmos 7.1',
        'media_source', 'BluRay',
        'release_group', 'FRDS',
        'site', 'hdsky',
        'release_name', 'Dune.Part.Two.2024.2160p.BluRay.DV.HEVC.TrueHD.7.1.Atmos-FRDS'
      ]);
    }
    return ScrapeNaming.movieMap;
  }

  /** 预览样例（剧集）：SDR，不给 hdr，演示 {hdr} 渲染为空后的收缩 */
  static episodeSample(): Map<string, string> {
    if (ScrapeNaming.episodeMap === null) {
      ScrapeNaming.episodeMap = ScrapeNaming.buildSample([
        'title', '风筝',
        'original_title', '风筝',
        'english_title', 'Kite',
        'year', '2017',
        'tmdb_id', '68035',
        'imdb_id', 'tt6952510',
        'douban_id', '26340419',
        'season', '1',
        'season_name', '第 1 季',
        'episode', '3',
        'episode_title', '延安来的姑娘',
        'resolution', '1080p',
        'video_codec', 'H.264',
        'bit_depth', '8bit',
        'audio', 'AAC 2.0',
        'media_source', 'WEB-DL',
        'release_group', 'CHDWEB',
        'site', 'chdbits',
        'release_name', 'Kite.2017.S01E03.1080p.WEB-DL.H264.AAC-CHDWEB'
      ]);
    }
    return ScrapeNaming.episodeMap;
  }

  // MARK: 渲染内部

  private static renderOnce(template: string, ctx: Map<string, string>): string {
    // ① 占位符全空的括号组连同组内字面文本一起丢弃（收掉 "[tmdbid-]" 这种残留）
    const dropped: string = ScrapeNaming.replaceAll(template, ScrapeNaming.bracketGroupRE,
      (match: string): string => {
        const names: string[] = ScrapeNaming.tokensIn(match);
        if (names.length === 0) {
          return match;
        }
        for (const name of names) {
          if (ScrapeNaming.tokenValue(ctx, name, null).length > 0) {
            return match;
          }
        }
        return '';
      });
    // ② 替换占位符
    const filled: string = ScrapeNaming.replaceAll(dropped, ScrapeNaming.tokenRE,
      (match: string, groups: string[]): string => {
        const pad: string | null = groups.length > 1 ? groups[1] : null;
        return ScrapeNaming.tokenValue(ctx, groups[0], pad);
      });
    // ③ 收缩：括号内侧 → 重复分隔符 → 多余空白 → 首尾分隔符
    let collapsed: string = filled;
    collapsed = collapsed.replace(/([(\[【])[\s\-–]+/g, '$1');
    collapsed = collapsed.replace(/[\s\-–]+([)\]】])/g, '$1');
    collapsed = collapsed.replace(/(?:\s*-\s*){2,}/g, ' - ');
    collapsed = collapsed.replace(/\s{2,}/g, ' ');
    collapsed = collapsed.replace(/^[\s\-–.]+|[\s\-–.]+$/g, '');
    const result: string = ScrapeNaming.sanitize(collapsed);
    return result.length === 0 ? '未命名' : result;
  }

  private static tokenValue(ctx: Map<string, string>, name: string, pad: string | null): string {
    const raw: string | undefined = ctx.get(name);
    if (raw === undefined || raw.length === 0) {
      return '';
    }
    let text: string = ScrapeNaming.sanitize(raw);
    if (pad !== null && pad.length > 0 && text.length > 0) {
      const width: number = Number.parseInt(pad, 10);
      if (Number.isFinite(width) && ScrapeNaming.isDigits(text) && text.length < width) {
        let prefix: string = '';
        for (let i: number = 0; i < width - text.length; i++) {
          prefix += '0';
        }
        text = prefix + text;
      }
    }
    return text;
  }

  /** 清洗非法文件名字符；连续空白合并为单个空格 */
  private static sanitize(value: string): string {
    let v: string = value.replace(/[\\/:*?"<>|]/g, ' ');
    v = v.replace(/\s+/g, ' ');
    return v.replace(/^[\s.]+|[\s.]+$/g, '');
  }

  /** 按 UTF-8 字节数截断，不切坏多字节字符（代理对按 4 字节整段处理） */
  private static cutBytes(text: string, limit: number): string {
    let out: string = '';
    let used: number = 0;
    let i: number = 0;
    while (i < text.length) {
      const code: number = text.charCodeAt(i);
      let size: number = 1;
      let unit: number = 1;
      if (code < 0x80) {
        size = 1;
      } else if (code < 0x800) {
        size = 2;
      } else if (code >= 0xD800 && code <= 0xDBFF) {
        size = 4;
        unit = 2;
      } else {
        size = 3;
      }
      if (used + size > limit) {
        break;
      }
      out += text.substring(i, i + unit);
      used += size;
      i += unit;
    }
    return out;
  }

  /** UTF-8 字节数 */
  private static byteLen(text: string): number {
    let total: number = 0;
    let i: number = 0;
    while (i < text.length) {
      const code: number = text.charCodeAt(i);
      if (code < 0x80) {
        total += 1;
        i += 1;
      } else if (code < 0x800) {
        total += 2;
        i += 1;
      } else if (code >= 0xD800 && code <= 0xDBFF) {
        total += 4;
        i += 2;
      } else {
        total += 3;
        i += 1;
      }
    }
    return total;
  }

  private static trimEdges(text: string): string {
    return text.replace(/^[ .\-]+|[ .\-]+$/g, '');
  }

  private static isDigits(text: string): boolean {
    for (let i: number = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i);
      if (code < 48 || code > 57) {
        return false;
      }
    }
    return true;
  }

  private static copyOf(src: Map<string, string>): Map<string, string> {
    const out: Map<string, string> = new Map<string, string>();
    src.forEach((value: string, key: string): void => {
      out.set(key, value);
    });
    return out;
  }

  private static buildSample(pairs: string[]): Map<string, string> {
    const map: Map<string, string> = new Map<string, string>();
    for (let i: number = 0; i + 1 < pairs.length; i += 2) {
      map.set(pairs[i], pairs[i + 1]);
    }
    return map;
  }

  /**
   * 回调式全局替换（JS `replace(re, fn)` 的手写等价）：按匹配在原文中的位置重建结果串。
   * 每次调用都造全新 `RegExp`，避免全局正则的 `lastIndex` 状态串场。
   */
  private static replaceAll(text: string, re: RegExp, transform: (match: string, groups: string[]) => string): string {
    const regex: RegExp = new RegExp(re.source, 'g');
    let out: string = '';
    let last: number = 0;
    let match: RegExpExecArray | null = regex.exec(text);
    while (match !== null) {
      const groups: string[] = [];
      for (let i: number = 1; i < match.length; i++) {
        groups.push(match[i] === undefined ? '' : `${match[i]}`);
      }
      const at: number = match.index;
      out += text.substring(last, at) + transform(match[0], groups);
      last = at + match[0].length;
      if (match[0].length === 0) {
        regex.lastIndex += 1;
      }
      match = regex.exec(text);
    }
    return out + text.substring(last);
  }
}
