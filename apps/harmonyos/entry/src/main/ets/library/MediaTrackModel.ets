/**
 * 轨道展示的中性模型（对应 iOS MediaTrackSection.swift 的 TrackModel / TrackEntry /
 * TrackLanguageGroup / TrackTone；Web media-track-rows.tsx 同源）。
 *
 * 音轨与字幕拍平成同一种结构（TrackEntry），折叠行的语言芯片、弹层的分组列表、
 * 字幕预览页共用一份分组 / 排序 / 格式化逻辑，只写一遍。
 *
 * 排序口径（同 iOS / Web）：默认轨所在语言组第一 → 简中 → 繁中 → 中文/粤语 →
 * 其余按条数降序 → 双语与未标语言垫底；组内：默认 → 内封 → 外挂 → AI 生成。
 */
import { trackLanguageLabel } from '../common/LanguageLabels';
import {
  AudioStreamView,
  LibraryFileView,
  SubtitleStreamView,
  TrackDefaultsView
} from '../api/Models';

/** 音轨编码 → 用户认知的完整读法（列表行主文案用） */
const AUDIO_CODEC_LABELS: Record<string, string> = {
  'aac': 'AAC', 'ac3': 'Dolby Digital', 'eac3': 'Dolby Digital+', 'truehd': 'Dolby TrueHD',
  'dts': 'DTS', 'flac': 'FLAC', 'opus': 'Opus', 'mp3': 'MP3', 'vorbis': 'Vorbis'
};

/** 同一批编码的紧凑写法（行首格式色块用） */
const AUDIO_FORMAT_TOKENS: Record<string, string> = {
  'aac': 'AAC', 'ac3': 'AC3', 'eac3': 'EAC3', 'truehd': 'TrueHD', 'dts': 'DTS',
  'flac': 'FLAC', 'opus': 'Opus', 'mp3': 'MP3', 'vorbis': 'Vorbis'
};

const SUBTITLE_CODEC_TOKENS: Record<string, string> = {
  'subrip': 'SRT', 'srt': 'SRT', 'ass': 'ASS', 'ssa': 'SSA', 'hdmv_pgs_subtitle': 'PGS',
  'dvd_subtitle': 'VobSub', 'mov_text': 'Text', 'webvtt': 'VTT', 'vtt': 'VTT',
  'sub': 'VobSub', 'sup': 'PGS'
};

/** 有序：按中文名反查语言码时取第一个命中（同 iOS languageLabels 的数组顺序） */
const LANGUAGE_CODES: string[] = ['chs', 'cht', 'chi', 'zho', 'cmn', 'yue', 'eng', 'jpn', 'kor',
  'fre', 'fra', 'ger', 'deu', 'spa', 'rus', 'ita', 'por', 'tha', 'hin'];

/** 这是一款中文软件：中文优先；简繁刻意不合并——它们正是用户真正要区分的东西 */
const LANGUAGE_RANKS: Record<string, number> = {
  'chs': 1, 'cht': 2, 'chi': 3, 'zho': 3, 'cmn': 3, 'yue': 4, 'eng': 5, 'jpn': 6, 'kor': 7
};
const RANK_OTHER: number = 40;
const RANK_BILINGUAL: number = 80;
const RANK_UNKNOWN: number = 90;

const UNKNOWN_LANGUAGE: string = '未标语言';

/** 这些 profile 只是编码内部档次，单独展示反而让人困惑；只有 DTS-HD MA 这类更有信息量的才顶替 codec */
const GENERIC_PROFILES: string[] = ['lc', 'main', 'high', 'baseline', 'main 10'];

/** 音轨行右端常显的最高规格：评分先看编码档次再看声道数 */
const AUDIO_CODEC_TIERS: Record<string, number> = {
  'truehd': 5, 'dts': 4, 'eac3': 3, 'flac': 3, 'ac3': 2, 'opus': 1, 'aac': 1
};

const RESOLUTION_LABELS: Record<string, string> = {
  '4320p': '8K', '2160p': '4K', '1440p': '2K', '1080p': '1080p',
  '720p': '720p', '4k': '4K', '2k': '2K'
};

/** 弹层里打开字幕预览所需的定位信息（预览接口的轨引用 + 展示用短标签） */
export class TrackPreviewInfo {
  readonly stream: SubtitleStreamView;
  readonly track: string;
  readonly label: string;

  constructor(stream: SubtitleStreamView, track: string, label: string) {
    this.stream = stream;
    this.track = track;
    this.label = label;
  }
}

/** 一条轨道的中性描述（音轨 / 字幕拍平；折叠芯片、列表行、预览页共用） */
export class TrackEntry {
  readonly id: string;
  /** 分组键：面向用户的语言名（chi/zho/cmn 会并成同一个「中文」） */
  readonly language: string;
  /** 语言排序权重，越小越靠前 */
  readonly rank: number;
  /** 行首色块文案：SRT / ASS / PGS / TrueHD… */
  readonly format: string;
  /** 格式色块的色调（srt/ass/pgs/vobsub/text/ai/other） */
  readonly tone: string;
  /** 主文案：音轨给规格，字幕给文件名或内封轨号 */
  readonly primary: string;
  /** 次文案：音轨给轨号，字幕给来源（内封 / 外挂 / AI 外挂） */
  readonly secondary: string;
  /** 属性标记：默认 / 强制 */
  readonly flags: string[];
  /** 是否外挂字幕文件；音轨恒为 false */
  readonly external: boolean;
  /** 组内排序：默认 → 内封 → 外挂 → AI 生成 */
  readonly order: number;
  /** 可删除的外挂字幕文件名；内封轨与音轨为 null（长在容器里，删不掉） */
  readonly deletable: string | null;
  /** 仅字幕有：点击后打开预览所需的一切 */
  readonly preview: TrackPreviewInfo | null;

  constructor(id: string, language: string, rank: number, format: string, tone: string,
    primary: string, secondary: string, flags: string[], external: boolean, order: number,
    deletable: string | null, preview: TrackPreviewInfo | null) {
    this.id = id;
    this.language = language;
    this.rank = rank;
    this.format = format;
    this.tone = tone;
    this.primary = primary;
    this.secondary = secondary;
    this.flags = flags;
    this.external = external;
    this.order = order;
    this.deletable = deletable;
    this.preview = preview;
  }
}

/** 语言分组（折叠行的芯片、列表的分区共用） */
export class TrackLanguageGroup {
  readonly language: string;
  readonly entries: TrackEntry[];
  readonly rank: number;

  constructor(language: string, entries: TrackEntry[], rank: number) {
    this.language = language;
    this.entries = entries;
    this.rank = rank;
  }

  hasDefault(): boolean {
    for (const entry of this.entries) {
      if (entry.order === 0) {
        return true;
      }
    }
    return false;
  }
}

// MARK: - 格式色块的色调（只承担格式识别，刻意低饱和，避免重新变成徽章墙）

/** 色调 → 底色（同 iOS TrackTone.background） */
export function trackToneBackground(tone: string): string {
  if (tone === 'srt') {
    return 'rgba(125,212,252,0.10)';
  }
  if (tone === 'ass') {
    return 'rgba(196,181,253,0.10)';
  }
  if (tone === 'pgs') {
    return 'rgba(252,212,77,0.10)';
  }
  if (tone === 'vobsub') {
    return 'rgba(252,186,115,0.10)';
  }
  if (tone === 'text') {
    return 'rgba(102,232,250,0.10)';
  }
  if (tone === 'ai') {
    return 'rgba(205,214,230,0.12)';
  }
  return 'rgba(255,255,255,0.065)';
}

/** 色调 → 前景字色（同 iOS TrackTone.foreground） */
export function trackToneForeground(tone: string): string {
  if (tone === 'srt') {
    return 'rgba(224,242,254,0.90)';
  }
  if (tone === 'ass') {
    return 'rgba(237,233,255,0.90)';
  }
  if (tone === 'pgs') {
    return 'rgba(255,242,199,0.90)';
  }
  if (tone === 'vobsub') {
    return 'rgba(255,237,214,0.90)';
  }
  if (tone === 'text') {
    return 'rgba(207,250,255,0.90)';
  }
  if (tone === 'ai') {
    return 'rgba(238,242,248,0.90)';
  }
  return 'rgba(255,255,255,0.75)';
}

// MARK: - 语言

/** 语言码 → 排序权重（未标/und 垫底） */
export function trackLanguageRank(code: string | null | undefined): number {
  if (code === null || code === undefined || code.length === 0 || code === 'und') {
    return RANK_UNKNOWN;
  }
  const rank: number | undefined = LANGUAGE_RANKS[code.toLowerCase()];
  return rank !== undefined ? rank : RANK_OTHER;
}

// MARK: - 音轨

/** 声道数 → 惯用布局标签（channel_layout 可用时优先，去掉 (side) 等后缀） */
export function trackChannelsLabel(stream: AudioStreamView): string | null {
  const layout: string = stream.channel_layout ?? '';
  if (layout.length > 0) {
    const parts: string[] = layout.split('(');
    const compact: string = parts[0].trim();
    if (compact.length > 0) {
      const first: number = compact.charCodeAt(0);
      if (first >= 48 && first <= 57) {
        return compact;
      }
    }
  }
  const channels: number | null = stream.channels ?? null;
  if (channels === null) {
    return null;
  }
  if (channels === 1) {
    return '单声道';
  }
  if (channels === 2) {
    return '2.0';
  }
  if (channels === 6) {
    return '5.1';
  }
  if (channels === 7) {
    return '6.1';
  }
  if (channels === 8) {
    return '7.1';
  }
  return `${channels} 声道`;
}

/** 有信息量的 profile（LC/Main/High 这类通用档不算） */
export function trackInformativeProfile(stream: AudioStreamView): string | null {
  const profile: string = (stream.profile ?? '').trim();
  if (profile.length === 0) {
    return null;
  }
  const lower: string = profile.toLowerCase();
  for (const generic of GENERIC_PROFILES) {
    if (lower === generic) {
      return null;
    }
  }
  return profile;
}

/** 音轨编码 → 用户认知的完整读法 */
export function trackAudioCodecName(stream: AudioStreamView): string | null {
  const codec: string = stream.codec ?? '';
  if (codec.length === 0) {
    return null;
  }
  const label: string | undefined = AUDIO_CODEC_LABELS[codec.toLowerCase()];
  return label !== undefined ? label : codec.toUpperCase();
}

/** 音轨 → 列表行主文案：格式（有信息量的 profile 优先）· 声道 */
export function trackAudioSpecLabel(stream: AudioStreamView): string {
  const codec: string = trackInformativeProfile(stream) ?? trackAudioCodecName(stream) ?? '未知格式';
  const channels: string | null = trackChannelsLabel(stream);
  return channels !== null ? `${codec} · ${channels}` : codec;
}

/** 音轨行首的紧凑格式码 */
export function trackAudioFormatToken(stream: AudioStreamView): string {
  const codec: string = stream.codec ?? '';
  if (codec.length === 0) {
    return '音轨';
  }
  const token: string | undefined = AUDIO_FORMAT_TOKENS[codec.toLowerCase()];
  return token !== undefined ? token : codec.toUpperCase();
}

/** 音轨与字幕共用低饱和色系，颜色只帮助快速区分常见编码族 */
export function trackAudioTone(stream: AudioStreamView): string {
  const codec: string = (stream.codec ?? '').toLowerCase();
  if (codec === 'aac' || codec === 'mp3') {
    return 'srt';
  }
  if (codec === 'truehd') {
    return 'ass';
  }
  if (codec === 'ac3' || codec === 'eac3') {
    return 'pgs';
  }
  if (codec === 'dts') {
    return 'vobsub';
  }
  if (codec === 'flac' || codec === 'opus' || codec === 'vorbis') {
    return 'text';
  }
  return 'other';
}

/**
 * 音轨行右端常显的最高规格。摘要行要自己回答「这片音质到什么档次」；
 * 只有一条音轨时芯片已写格式，不重复挂（同 iOS topAudioSpec）。
 */
export function trackTopAudioSpec(streams: AudioStreamView[]): string | null {
  if (streams.length < 2) {
    return null;
  }
  let best: AudioStreamView | null = null;
  let bestScore: number = -1;
  for (const stream of streams) {
    const codec: string = stream.codec ?? '';
    const tier: number | undefined = AUDIO_CODEC_TIERS[codec.toLowerCase()];
    const score: number = (tier !== undefined ? tier : 0) * 100 + (stream.channels ?? 0);
    if (score > bestScore) {
      bestScore = score;
      best = stream;
    }
  }
  if (best === null) {
    return null;
  }
  const codec: string | null = trackInformativeProfile(best) ?? trackAudioCodecName(best);
  const channels: string | null = trackChannelsLabel(best);
  const parts: string[] = [];
  if (codec !== null && codec.length > 0) {
    parts.push(codec);
  }
  if (channels !== null && channels.length > 0) {
    parts.push(channels);
  }
  return parts.length > 0 ? parts.join(' ') : null;
}

// MARK: - 字幕

/** 外挂字幕文件名按「.」拆开的小写段 */
function subtitleFileTokens(stream: SubtitleStreamView): string[] {
  const name: string = stream.file_name ?? '';
  if (name.length === 0) {
    return [];
  }
  return name.toLowerCase().split('.');
}

/** AI 生成字幕：标题以 ai- 开头，或文件名段里有 ai / ai-*（同 iOS isAiSubtitle） */
export function trackIsAiSubtitle(stream: SubtitleStreamView): boolean {
  const title: string = stream.title ?? '';
  if (title.toLowerCase().startsWith('ai-')) {
    return true;
  }
  const tokens: string[] = subtitleFileTokens(stream);
  for (const token of tokens) {
    if (token === 'ai' || token.startsWith('ai-')) {
      return true;
    }
  }
  return false;
}

/** AI 生成字幕的标题里编了目标语言，翻译回中文读法（双语保留两个语言） */
export function trackGeneratedSubtitleLabel(stream: SubtitleStreamView): string | null {
  const title: string = (stream.title ?? '').toLowerCase().trim();
  if (title.length === 0) {
    return null;
  }
  if (title.startsWith('ai-bilingual-')) {
    const parts: string[] = title.substring('ai-bilingual-'.length).split('-');
    if (parts.length === 2) {
      const first: string = trackLanguageLabel(parts[0]) ?? parts[0];
      const second: string = trackLanguageLabel(parts[1]) ?? parts[1];
      return `${first} + ${second}`;
    }
  }
  if (title === 'ai-chs') {
    return '简体中文';
  }
  if (title === 'ai-cht') {
    return '繁体中文';
  }
  return null;
}

/** 字幕 → 分组用的语言名（AI 产物的语言写在标题里，优先认它） */
export function trackSubtitleLanguageName(stream: SubtitleStreamView): string {
  const generated: string | null = trackGeneratedSubtitleLabel(stream);
  if (generated !== null) {
    return generated;
  }
  return trackLanguageLabel(stream.language) ?? UNKNOWN_LANGUAGE;
}

/** 字幕行首的紧凑格式码 */
export function trackSubtitleFormatToken(stream: SubtitleStreamView): string {
  const codec: string = stream.codec ?? '';
  if (codec.length === 0) {
    return '字幕';
  }
  const token: string | undefined = SUBTITLE_CODEC_TOKENS[codec.toLowerCase()];
  return token !== undefined ? token : codec.toUpperCase();
}

/** AI 产物沿用主按钮的冷银色，与其他格式色块保持同一层级 */
export function trackSubtitleTone(stream: SubtitleStreamView): string {
  if (trackIsAiSubtitle(stream)) {
    return 'ai';
  }
  const codec: string = (stream.codec ?? '').toLowerCase();
  if (codec === 'subrip' || codec === 'srt') {
    return 'srt';
  }
  if (codec === 'ass' || codec === 'ssa') {
    return 'ass';
  }
  if (codec === 'hdmv_pgs_subtitle' || codec === 'sup') {
    return 'pgs';
  }
  if (codec === 'dvd_subtitle' || codec === 'sub') {
    return 'vobsub';
  }
  if (codec === 'mov_text' || codec === 'webvtt' || codec === 'vtt') {
    return 'text';
  }
  return 'other';
}

/** 外挂字幕的来源标记：AI 外挂 / PGS 转换 / 外挂（列表行次文案） */
export function trackExternalSubtitleSuffix(stream: SubtitleStreamView): string {
  const tokens: string[] = subtitleFileTokens(stream);
  for (const token of tokens) {
    if (token === 'ai' || token.startsWith('ai-')) {
      return 'AI 外挂';
    }
  }
  for (const token of tokens) {
    if (token === 'pgs-ocr') {
      return 'PGS 转换';
    }
  }
  return '外挂';
}

/**
 * 外挂字幕的行内标签：去掉与视频同名的那段前缀，只留区分用的 token 段。
 * 外挂字幕全都以视频文件名开头，完整文件名截断后几条长得一模一样；完整路径仍在删除确认框里给全。
 */
export function trackExternalSubtitleLabel(fileName: string | null, videoStem: string): string {
  if (fileName === null) {
    return '外挂字幕';
  }
  if (videoStem.length > 0 && fileName.toLowerCase().startsWith(videoStem.toLowerCase())) {
    let rest: string = fileName.substring(videoStem.length);
    if (rest.startsWith('.')) {
      rest = rest.substring(1);
    }
    if (rest.length > 0) {
      return rest;
    }
  }
  return fileName;
}

/** 视频文件名去掉扩展名 */
export function trackVideoStem(fileName: string): string {
  const dot: number = fileName.lastIndexOf('.');
  if (dot < 0 || dot === fileName.length - 1) {
    return fileName;
  }
  return fileName.substring(0, dot);
}

/** 外挂字幕与视频同目录，据此还原它的完整路径（删除确认框要摆给用户看） */
export function trackSiblingPath(videoPath: string, filename: string): string {
  const slash: number = videoPath.lastIndexOf('/');
  const backslash: number = videoPath.lastIndexOf('\\');
  const cut: number = Math.max(slash, backslash);
  if (cut < 0) {
    return filename;
  }
  return videoPath.substring(0, cut + 1) + filename;
}

/** 字幕预览接口使用的中性轨引用：内封按序号，外挂按文件名 */
export function trackSubtitleTrackRef(stream: SubtitleStreamView, index: number): string | null {
  if (!stream.external) {
    return `embedded:${index}`;
  }
  const name: string = stream.file_name ?? '';
  return name.length > 0 ? `external:${name}` : null;
}

/** 字幕的排序权重：双语 → 未标 → 按码 → AI 产物按中文名反查 → 其余 */
export function trackSubtitleRank(stream: SubtitleStreamView, language: string): number {
  if (language.indexOf(' + ') >= 0) {
    return RANK_BILINGUAL;
  }
  if (language === UNKNOWN_LANGUAGE) {
    return RANK_UNKNOWN;
  }
  const byCode: number = trackLanguageRank(stream.language);
  if (byCode !== RANK_UNKNOWN) {
    return byCode;
  }
  for (const code of LANGUAGE_CODES) {
    if (trackLanguageLabel(code) === language) {
      return trackLanguageRank(code);
    }
  }
  return RANK_OTHER;
}

// MARK: - 版本选择

/** 版本选择的一行：「分辨率 — 文件名」（没有分辨率就只给文件名） */
export function trackFileOptionLabel(file: LibraryFileView): string {
  const resolution: string = file.resolution ?? '';
  if (resolution.length === 0) {
    return file.file_name;
  }
  return `${trackFormatVideoResolution(resolution)} — ${file.file_name}`;
}

/** 同 Web formatVideoResolution：4320p→8K、2160p→4K、纯数字加 p 后再映射 */
export function trackFormatVideoResolution(resolution: string): string {
  const normalized: string = resolution.trim().toLowerCase();
  let key: string = normalized;
  if (normalized.length > 0) {
    let allDigits: boolean = true;
    for (let i: number = 0; i < normalized.length; i++) {
      const c: number = normalized.charCodeAt(i);
      if (c < 48 || c > 57) {
        allDigits = false;
        break;
      }
    }
    if (allDigits) {
      key = `${normalized}p`;
    }
  }
  const label: string | undefined = RESOLUTION_LABELS[key];
  return label !== undefined ? label : resolution;
}

// MARK: - 拍平成 TrackEntry

/**
 * 「默认」标给哪条：有服务端的 playback_defaults 就标起播时真会放的那条，
 * 没有（原盘、没探测过）退回片源的默认旗标（同 iOS audioEntries / subtitleEntries）。
 */
export function trackAudioEntries(streams: AudioStreamView[], defaults: TrackDefaultsView | null): TrackEntry[] {
  const entries: TrackEntry[] = [];
  for (let index: number = 0; index < streams.length; index++) {
    const stream: AudioStreamView = streams[index];
    const isDefault: boolean = defaults !== null
      ? (defaults.audio_track ?? '') === `embedded:${index}`
      : stream.default;
    const spec: string = trackAudioSpecLabel(stream);
    const title: string = (stream.title ?? '').trim();
    const flags: string[] = [];
    if (isDefault) {
      flags.push('默认');
    }
    entries.push(new TrackEntry(
      `audio:${index}`,
      trackLanguageLabel(stream.language) ?? UNKNOWN_LANGUAGE,
      trackLanguageRank(stream.language),
      trackAudioFormatToken(stream),
      trackAudioTone(stream),
      title.length === 0 ? spec : `${spec} · ${title}`,
      `轨 ${index + 1}`,
      flags,
      false,
      isDefault ? 0 : 1,
      null,
      null
    ));
  }
  return entries;
}

export function trackSubtitleEntries(streams: SubtitleStreamView[], videoStem: string,
  defaults: TrackDefaultsView | null): TrackEntry[] {
  const entries: TrackEntry[] = [];
  // 内封轨在界面上按「内封里的第几条」编号：subtitle_streams 里内封与外挂混在一起，
  // 直接用混合下标会给出错误的轨号
  let embeddedOrdinal: number = 0;
  for (let index: number = 0; index < streams.length; index++) {
    const stream: SubtitleStreamView = streams[index];
    const language: string = trackSubtitleLanguageName(stream);
    const format: string = trackSubtitleFormatToken(stream);
    const external: boolean = stream.external;
    if (!external) {
      embeddedOrdinal += 1;
    }
    const track: string | null = trackSubtitleTrackRef(stream, index);
    const isDefault: boolean = defaults !== null
      ? (track !== null && (defaults.subtitle_track ?? '') === track)
      : stream.default;
    const title: string = (stream.title ?? '').trim();
    const hasTitle: boolean = title.length > 0;
    const primary: string = external
      ? trackExternalSubtitleLabel(stream.file_name ?? null, videoStem)
      : (hasTitle ? title : `内封轨 ${embeddedOrdinal}`);
    const label: string = `${primary} · ${language} · ${format}`;
    const flags: string[] = [];
    if (isDefault) {
      flags.push('默认');
    }
    if (stream.forced) {
      flags.push('强制');
    }
    const ai: boolean = trackIsAiSubtitle(stream);
    entries.push(new TrackEntry(
      `subtitle:${track !== null ? track : `unknown:${index}`}`,
      language,
      trackSubtitleRank(stream, language),
      format,
      trackSubtitleTone(stream),
      primary,
      external ? trackExternalSubtitleSuffix(stream) : (hasTitle ? `内封轨 ${embeddedOrdinal}` : '内封'),
      flags,
      external,
      isDefault ? 0 : (ai ? 3 : (external ? 2 : 1)),
      // 外挂（含 AI 生成）是磁盘上的独立文件，可以单独删；内封轨要删得重封装视频本体，不给入口
      external ? (stream.file_name ?? null) : null,
      track !== null ? new TrackPreviewInfo(stream, track, label) : null
    ));
  }
  return entries;
}

/**
 * 列表第一组下面的说明：会放哪条（标「默认」的那条）、为什么；
 * 字幕默认不开时直接说为什么不开（同 iOS defaultNote）。
 */
export function trackDefaultNote(defaults: TrackDefaultsView, kind: string): string | null {
  if (kind === 'audio') {
    const track: string = defaults.audio_track ?? '';
    if (track.length === 0 || defaults.audio_note.length === 0) {
      return null;
    }
    return `标「默认」的这条会自动播放：${defaults.audio_note}`;
  }
  if (defaults.subtitle_note.length === 0) {
    return null;
  }
  const track: string = defaults.subtitle_track ?? '';
  return track.length > 0
    ? `标「默认」的这条会自动打开：${defaults.subtitle_note}`
    : defaults.subtitle_note;
}

/** 按语言分组并排序（默认组第一 → 语言权重 → 条数降序 → 名称），组内按 order 稳定排序 */
export function trackGroupByLanguage(entries: TrackEntry[]): TrackLanguageGroup[] {
  const order: string[] = [];
  const buckets: Record<string, TrackEntry[]> = {};
  for (const entry of entries) {
    const bucket: TrackEntry[] | undefined = buckets[entry.language];
    if (bucket === undefined) {
      order.push(entry.language);
      buckets[entry.language] = [entry];
    } else {
      bucket.push(entry);
    }
  }
  const groups: TrackLanguageGroup[] = [];
  for (const language of order) {
    const list: TrackEntry[] = buckets[language] as TrackEntry[];
    list.sort((a: TrackEntry, b: TrackEntry): number => a.order - b.order);
    let rank: number = list.length > 0 ? list[0].rank : RANK_OTHER;
    for (const entry of list) {
      if (entry.rank < rank) {
        rank = entry.rank;
      }
    }
    groups.push(new TrackLanguageGroup(language, list, rank));
  }
  groups.sort((a: TrackLanguageGroup, b: TrackLanguageGroup): number => {
    const aDefault: boolean = a.hasDefault();
    const bDefault: boolean = b.hasDefault();
    if (aDefault !== bDefault) {
      return aDefault ? -1 : 1;
    }
    if (a.rank !== b.rank) {
      return a.rank - b.rank;
    }
    if (a.entries.length !== b.entries.length) {
      return b.entries.length - a.entries.length;
    }
    return a.language < b.language ? -1 : 1;
  });
  return groups;
}
