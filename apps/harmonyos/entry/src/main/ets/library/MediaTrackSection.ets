import { Theme } from '../theme/AppTheme';
import {
  AudioStreamView,
  LibraryFileView,
  SubtitleStreamView,
  TrackDefaultsView
} from '../api/Models';

/** 轨道语言的中文名（同 iOS TrackModel.languageLabels 的常用子集）；未收录的回退原码 */
const LANGUAGE_LABELS: Record<string, string> = {
  'chs': '简体中文', 'cht': '繁体中文', 'chi': '中文', 'zho': '中文', 'cmn': '中文',
  'yue': '粤语', 'eng': '英语', 'jpn': '日语', 'kor': '韩语', 'fre': '法语', 'fra': '法语',
  'ger': '德语', 'deu': '德语', 'spa': '西班牙语', 'rus': '俄语', 'ita': '意大利语',
  'por': '葡萄牙语', 'tha': '泰语', 'hin': '印地语'
};

/** 音轨编码 → 用户认知的读法（同 iOS audioCodecLabels） */
const AUDIO_CODEC_LABELS: Record<string, string> = {
  'aac': 'AAC', 'ac3': 'Dolby Digital', 'eac3': 'Dolby Digital+', 'truehd': 'Dolby TrueHD',
  'dts': 'DTS', 'flac': 'FLAC', 'opus': 'Opus', 'mp3': 'MP3', 'vorbis': 'Vorbis'
};

function languageLabel(code: string | null | undefined): string {
  if (code === null || code === undefined || code.length === 0 || code === 'und') {
    return '未标语言';
  }
  const label: string | undefined = LANGUAGE_LABELS[code.toLowerCase()];
  return label !== undefined ? label : code;
}

function audioCodecName(codec: string | null | undefined): string {
  if (codec === null || codec === undefined || codec.length === 0) {
    return '未知格式';
  }
  const label: string | undefined = AUDIO_CODEC_LABELS[codec.toLowerCase()];
  return label !== undefined ? label : codec.toUpperCase();
}

function channelsLabel(channels: number | null | undefined): string {
  if (channels === null || channels === undefined) {
    return '';
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

/** 一个语言分组的摘要芯片（含默认轨标记，iOS TrackRowView 的芯片 + defaultNote） */
class TrackChip {
  readonly text: string;
  readonly detail: string;
  readonly isDefault: boolean;

  constructor(text: string, detail: string, isDefault: boolean) {
    this.text = text;
    this.detail = detail;
    this.isDefault = isDefault;
  }

  key(): string {
    return `${this.text}|${this.detail}|${this.isDefault}`;
  }
}

/**
 * 条目详情的媒体轨道区（iOS MediaTrackSection.swift 的可搬子集）：
 * - 多版本（同一部片多个在位文件）时给版本选择菜单；
 * - 音轨 / 字幕各一行：按语言分组的芯片摘要 + 「全部轨道」展开整单；
 * - 默认轨（`playback_defaults`）的芯片带「默认」角标，展开行里注明原因。
 *
 * 交互部分（轨道列表弹层、字幕预览、AI 字幕生成、外挂字幕删除）留待后续批次。
 */
@Component
export struct MediaTrackSection {
  /** 当前播放单元的在位文件（state == "in_place"；外面过滤） */
  @Prop files: LibraryFileView[] = [];
  @State private selectedFileId: number = -1;
  @State private expanded: boolean = false;

  /** 选中的文件：外部指定的，否则第一个 */
  private selectedFile(): LibraryFileView | null {
    for (const file of this.files) {
      if (file.id === this.selectedFileId) {
        return file;
      }
    }
    return this.files.length > 0 ? this.files[0] : null;
  }

  /** 默认音轨在 audio_streams 里的下标（`embedded:<k>`）；没有为 -1 */
  private defaultAudioIndex(file: LibraryFileView): number {
    const defaults: TrackDefaultsView | null | undefined = file.playback_defaults;
    if (defaults === null || defaults === undefined) {
      return -1;
    }
    const ref: string | null = defaults.audio_track ?? null;
    if (ref === null || !ref.startsWith('embedded:')) {
      return -1;
    }
    const index: number = Number(ref.substring('embedded:'.length));
    return Number.isFinite(index) && index >= 0 ? Math.floor(index) : -1;
  }

  /** 默认字幕在 subtitle_streams 里的下标；外挂（external:）与没有都返回 -1 */
  private defaultSubtitleIndex(file: LibraryFileView): number {
    const defaults: TrackDefaultsView | null | undefined = file.playback_defaults;
    if (defaults === null || defaults === undefined) {
      return -1;
    }
    const ref: string | null = defaults.subtitle_track ?? null;
    if (ref === null || !ref.startsWith('embedded:')) {
      return -1;
    }
    const index: number = Number(ref.substring('embedded:'.length));
    return Number.isFinite(index) && index >= 0 ? Math.floor(index) : -1;
  }

  private audioChips(file: LibraryFileView): TrackChip[] {
    const streams: AudioStreamView[] = file.audio_streams ?? [];
    const defaultIndex: number = this.defaultAudioIndex(file);
    const groups: Record<string, AudioStreamView[]> = {};
    const groupDefaults: Record<string, boolean> = {};
    const order: string[] = [];
    for (let i: number = 0; i < streams.length; i++) {
      const stream: AudioStreamView = streams[i];
      const key: string = languageLabel(stream.language);
      if (groups[key] === undefined) {
        groups[key] = [];
        groupDefaults[key] = false;
        order.push(key);
      }
      (groups[key] as AudioStreamView[]).push(stream);
      if (i === defaultIndex) {
        groupDefaults[key] = true;
      }
    }
    const chips: TrackChip[] = [];
    for (const key of order) {
      const group: AudioStreamView[] = groups[key] as AudioStreamView[];
      const codec: string = group[0].codec ?? '';
      chips.push(new TrackChip(key, group.length === 1 ? audioCodecName(codec) : `×${group.length}`,
        groupDefaults[key]));
    }
    return chips;
  }

  private audioLines(file: LibraryFileView): string[] {
    const streams: AudioStreamView[] = file.audio_streams ?? [];
    const defaultIndex: number = this.defaultAudioIndex(file);
    const defaults: TrackDefaultsView | null | undefined = file.playback_defaults;
    const note: string = defaults === null || defaults === undefined ? '' : defaults.audio_note;
    const lines: string[] = [];
    for (let i: number = 0; i < streams.length; i++) {
      const stream: AudioStreamView = streams[i];
      const parts: string[] = [audioCodecName(stream.codec), channelsLabel(stream.channels),
        languageLabel(stream.language)];
      const title: string | null = stream.title ?? null;
      if (title !== null && title.length > 0) {
        parts.push(title);
      }
      if (i === defaultIndex) {
        parts.push(`默认（${note}）`);
      }
      const line: string = parts.filter((part: string): boolean => part.length > 0).join(' · ');
      lines.push(`轨 ${i + 1} · ${line}`);
    }
    return lines;
  }

  private subtitleChips(file: LibraryFileView): TrackChip[] {
    const streams: SubtitleStreamView[] = file.subtitle_streams;
    const defaultIndex: number = this.defaultSubtitleIndex(file);
    const groups: Record<string, SubtitleStreamView[]> = {};
    const groupDefaults: Record<string, boolean> = {};
    const order: string[] = [];
    for (let i: number = 0; i < streams.length; i++) {
      const stream: SubtitleStreamView = streams[i];
      const key: string = languageLabel(stream.language);
      if (groups[key] === undefined) {
        groups[key] = [];
        groupDefaults[key] = false;
        order.push(key);
      }
      (groups[key] as SubtitleStreamView[]).push(stream);
      if (i === defaultIndex) {
        groupDefaults[key] = true;
      }
    }
    const chips: TrackChip[] = [];
    for (const key of order) {
      const group: SubtitleStreamView[] = groups[key] as SubtitleStreamView[];
      const codec: string = group[0].codec ?? '';
      chips.push(new TrackChip(key, group.length === 1 ? subtitleCodecShort(codec) : `×${group.length}`,
        groupDefaults[key]));
    }
    return chips;
  }

  private subtitleLines(file: LibraryFileView): string[] {
    const streams: SubtitleStreamView[] = file.subtitle_streams;
    const defaultIndex: number = this.defaultSubtitleIndex(file);
    const lines: string[] = [];
    for (let i: number = 0; i < streams.length; i++) {
      const stream: SubtitleStreamView = streams[i];
      const parts: string[] = [subtitleCodecShort(stream.codec), languageLabel(stream.language),
        stream.external ? '外挂' : '内封'];
      const title: string | null = (stream.file_name ?? stream.title) ?? null;
      if (title !== null && title.length > 0) {
        parts.push(title);
      }
      if (stream.forced) {
        parts.push('强制');
      }
      if (i === defaultIndex) {
        parts.push('默认');
      }
      lines.push(parts.join(' · '));
    }
    return lines;
  }

  build() {
    if (this.files.length > 0 && this.selectedFile() !== null) {
      Column({ space: 10 }) {
        // 多版本：同一部片多个在位文件时选看哪个的轨道（iOS versionPicker）
        if (this.files.length > 1) {
          Row({ space: 8 }) {
            Text('版本')
              .fontSize(13)
              .fontColor(Theme.textFaint)
            Text(this.versionLabel(this.selectedFile() as LibraryFileView))
              .fontSize(13)
              .fontColor(Theme.text)
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .backgroundColor(Theme.glassFillHover)
              .borderRadius(14)
              .bindMenu(this.VersionMenu())
          }
          .width('100%')
        }
        this.TrackLineRow('音轨', this.audioChips(this.selectedFile() as LibraryFileView),
          this.audioLines(this.selectedFile() as LibraryFileView), '尚未探测')
        this.TrackLineRow('字幕', this.subtitleChips(this.selectedFile() as LibraryFileView),
          this.subtitleLines(this.selectedFile() as LibraryFileView), '无内封或外挂字幕')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ top: 4 })
    }
  }

  /** 版本菜单：文件名 + 体积，勾当前选中 */
  @Builder
  VersionMenu() {
    Menu() {
      ForEach(this.files, (file: LibraryFileView) => {
        MenuItem({ content: this.versionLabel(file) })
          .onClick(() => {
            this.selectedFileId = file.id;
          })
      }, (file: LibraryFileView) => `${file.id}`)
    }
  }

  @Builder
  TrackLineRow(label: string, chips: TrackChip[], lines: string[], emptyText: string) {
    if (chips.length === 0) {
      Row({ space: 16 }) {
        Text(label)
          .fontSize(15)
          .fontColor(Theme.textFaint)
          .width(40)
        Text(emptyText)
          .fontSize(15)
          .fontColor(Theme.textMuted)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    } else {
      Column({ space: 6 }) {
        Scroll() {
          Row({ space: 6 }) {
            Text(label)
              .fontSize(15)
              .fontColor(Theme.textFaint)
            ForEach(chips, (chip: TrackChip) => {
              this.TrackChipView(chip)
            }, (chip: TrackChip) => chip.key())
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        if (this.expanded) {
          Column({ space: 4 }) {
            ForEach(lines, (line: string) => {
              Text(line)
                .fontSize(13)
                .fontColor('rgba(255,255,255,0.7)')
                .width('100%')
                .padding({ left: 4, right: 4, top: 3, bottom: 3 })
            }, (line: string) => line)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: 52 })
        }
        Text(this.expanded ? '收起' : '全部轨道')
          .fontSize(13)
          .fontColor(Theme.textFaint)
          .onClick(() => {
            this.expanded = !this.expanded;
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** 芯片：语言 + 编码摘要；默认轨加「默认」角标（iOS defaultNote 的徽标形态） */
  @Builder
  TrackChipView(chip: TrackChip) {
    Row({ space: 6 }) {
      Text(chip.text)
        .fontSize(13)
        .fontColor('rgba(255,255,255,0.85)')
      if (chip.isDefault) {
        Text('默认')
          .fontSize(10)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.accent)
          .padding({ left: 5, right: 5, top: 1, bottom: 1 })
          .borderRadius(6)
          .border({ width: 1, color: Theme.accentSoft })
      }
      Text(chip.detail)
        .fontSize(11)
        .fontWeight(FontWeight.Medium)
        .fontColor('rgba(255,255,255,0.5)')
    }
    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
    .backgroundColor('rgba(255,255,255,0.075)')
    .borderRadius(16)
  }

  /** 版本菜单的一行：文件名 + 体积 */
  private versionLabel(file: LibraryFileView): string {
    return `${file.file_name} · ${bytesShort(file.size_bytes)}`;
  }
}

function bytesShort(value: number): string {
  const units: string[] = ['B', 'KB', 'MB', 'GB', 'TB'];
  let v: number = value;
  let i: number = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  const rounded: number = Math.round(v * 10) / 10;
  return `${rounded} ${units[i]}`;
}

/** 字幕编码 → 紧凑读法（同 ShareItemView subtitleCodecLabels） */
function subtitleCodecShort(codec: string | null | undefined): string {
  if (codec === null || codec === undefined || codec.length === 0) {
    return '字幕';
  }
  const labels: Record<string, string> = {
    'subrip': 'SRT', 'srt': 'SRT', 'ass': 'ASS', 'ssa': 'SSA', 'hdmv_pgs_subtitle': 'PGS',
    'dvd_subtitle': 'VobSub', 'mov_text': 'Text', 'webvtt': 'VTT', 'vtt': 'VTT',
    'sub': 'VobSub', 'sup': 'PGS'
  };
  const label: string | undefined = labels[codec.toLowerCase()];
  return label !== undefined ? label : codec.toUpperCase();
}
