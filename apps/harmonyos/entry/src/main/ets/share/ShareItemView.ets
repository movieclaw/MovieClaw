import { common } from '@kit.AbilityKit';
import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { MovieClawApi } from '../api/Endpoints';
import { RemoteImage } from '../common/RemoteImage';
import { ImageUrls } from '../common/ImageUrls';
import { libraryBytes } from '../library/LibraryShared';
import { shareExpiryHint } from '../common/ShareLinks';
import { ShareLocalProgress } from './ShareProgress';
import {
  AudioStreamView,
  ChapterView,
  EpisodeView,
  SeasonEpisodesView,
  SharedFileView,
  SharedItemView,
  SubtitleStreamView
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

/** 字幕编码 → 紧凑读法（同 iOS subtitleCodecLabels） */
const SUBTITLE_CODEC_LABELS: Record<string, string> = {
  'subrip': 'SRT', 'srt': 'SRT', 'ass': 'ASS', 'ssa': 'SSA', 'hdmv_pgs_subtitle': 'PGS',
  'dvd_subtitle': 'VobSub', 'mov_text': 'Text', 'webvtt': 'VTT', 'vtt': 'VTT',
  'sub': 'VobSub', 'sup': 'PGS'
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

function subtitleCodecName(codec: string | null | undefined): string {
  if (codec === null || codec === undefined || codec.length === 0) {
    return '字幕';
  }
  const label: string | undefined = SUBTITLE_CODEC_LABELS[codec.toLowerCase()];
  return label !== undefined ? label : codec.toUpperCase();
}

/** 声道 → 惯用布局（5.1 / 7.1…，同 iOS channelsLabel 的数字映射） */
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

/** 分辨率读法（同 Web formatVideoResolution） */
function resolutionLabel(resolution: string): string {
  const normalized: string = resolution.trim().toLowerCase();
  const key: string = normalized.length > 0 && /^[0-9]+$/.test(normalized) ? `${normalized}p` : normalized;
  const labels: Record<string, string> = {
    '4320p': '8K', '2160p': '4K', '1440p': '2K', '1080p': '1080p', '720p': '720p',
    '4k': '4K', '2k': '2K'
  };
  const label: string | undefined = labels[key];
  return label !== undefined ? label : resolution;
}

/** 片长读法（同 Web formatRuntimeMinutes） */
function runtimeLabel(minutes: number): string {
  if (minutes < 60) {
    return `${minutes} 分钟`;
  }
  const rest: number = minutes % 60;
  return rest > 0 ? `${Math.floor(minutes / 60)} 小时 ${rest} 分钟` : `${Math.floor(minutes / 60)} 小时`;
}

function clockText(ms: number): string {
  const total: number = Math.max(0, Math.floor(ms / 1000));
  const h: number = Math.floor(total / 3600);
  const m: number = Math.floor((total % 3600) / 60);
  const s: number = total % 60;
  const mm: string = m < 10 ? `0${m}` : `${m}`;
  const ss: string = s < 10 ? `0${s}` : `${s}`;
  return h > 0 ? `${h}:${mm}:${ss}` : `${m}:${ss}`;
}

/** 一个语言分组的摘要芯片文案（同 iOS TrackRowView 的芯片） */
class TrackChip {
  readonly text: string;
  readonly detail: string;

  constructor(text: string, detail: string) {
    this.text = text;
    this.detail = detail;
  }
}

/** 一条轨道在展开列表里的整行文案 */
class TrackLine {
  readonly text: string;

  constructor(text: string) {
    this.text = text;
  }
}

/**
 * 分享页的影片页（照 iOS `ShareItemView`，Web `shared-item-view.tsx`）：
 * 详情页的浏览面，去掉一切管理与站内入口。
 *
 * 剧照铺底（固定在背后）→ 顶栏（返回 + 字标 + 链接到期提示）→ 标题、季集行、规格事实、类型、
 * 文件规格行、音轨 / 字幕（只读）→ 播放 → 简介 → （剧集）季集横滚 → 章节条 → 演职员 → 外部词条。
 * 播放走带 shareSlug 的 PlayerParams，播放器用 /share/{slug}/playback 接口族，进度只存本机。
 */
@ComponentV2
export struct ShareItemView {
  @Require @Param slug: string;
  /** 合集分享时看哪一部；条目分享不传（范围就那一个） */
  @Param mediaItemId: number | null = null;
  /** 合集分享才有「返回合集」 */
  @Param fromCollection: boolean = false;
  /** 播放：参数 = 条目 id、季、集、起播毫秒 */
  @Require @Param onPlay: (mediaItemId: number, season: number, episode: number, startMs: number) => void;
  /** 关闭访客页（页签栈出栈） */
  @Require @Param onClose: () => void;
  /** 返回合集名单 */
  @Require @Param onBack: () => void;

  @Local private item: SharedItemView | null = null;
  @Local private failed: string = '';
  /** 剧集选中的一集 */
  @Local private selectedEpisode: EpisodeView | null = null;
  @Local private selectedSeason: number = 0;
  /** 分集区当前展示的季（iOS 的 season 覆盖态） */
  @Local private episodeSeason: number = 0;
  @Local private episodes: SeasonEpisodesView | null = null;
  @Local private episodesFailed: boolean = false;
  /** 本机续播位置（毫秒）；0 = 没看过 */
  @Local private resumeMs: number = 0;
  @Local private plotExpanded: boolean = false;
  @Local private tracksExpanded: boolean = false;
  private generation: number = 0;
  private episodeGeneration: number = 0;

  aboutToAppear(): void {
    this.load();
  }

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  private origin(): string {
    return AppModel.shared.client !== null ? AppModel.shared.client.origin : '';
  }

  // MARK: 取数

  private async load(): Promise<void> {
    const api = this.api();
    if (api === null) {
      this.failed = '还没有连上服务器';
      return;
    }
    const generation: number = ++this.generation;
    try {
      const loaded: SharedItemView =
        await api.shareItem(this.slug, this.mediaItemId !== null ? this.mediaItemId : undefined);
      if (generation !== this.generation) {
        return;
      }
      this.item = loaded;
      this.failed = '';
      if (this.isTv(loaded)) {
        this.episodeSeason = this.initialSeason(loaded);
        this.loadEpisodes(loaded, this.episodeSeason);
      } else {
        this.updateResume(loaded, 0, 0);
      }
    } catch (error) {
      if (generation !== this.generation) {
        return;
      }
      this.failed = ShareItemView.loadErrorText(error);
    }
  }

  private static loadErrorText(error: Object): string {
    const err = error as Error;
    if (err !== null && err.message !== undefined && err.message.length > 0) {
      return err.message;
    }
    return '无法连接到服务器，请检查网络后重试';
  }

  /** 默认落在第一个在库的季（同 iOS currentSeason 的取值顺序） */
  private initialSeason(item: SharedItemView): number {
    const owned: Set<number> = new Set<number>();
    for (const file of item.files) {
      owned.add(file.season_number);
    }
    for (const season of item.seasons) {
      if (owned.has(season)) {
        return season;
      }
    }
    return item.seasons.length > 0 ? item.seasons[0] : 1;
  }

  private async loadEpisodes(item: SharedItemView, season: number): Promise<void> {
    const api = this.api();
    if (api === null) {
      this.episodesFailed = true;
      return;
    }
    const generation: number = ++this.episodeGeneration;
    this.episodes = null;
    this.episodesFailed = false;
    try {
      const data: SeasonEpisodesView =
        await api.shareEpisodes(this.slug, season, this.mediaItemId !== null ? this.mediaItemId : undefined);
      if (generation !== this.episodeGeneration) {
        return;
      }
      this.episodes = data;
      // 默认选第一个在库的集
      let first: EpisodeView | null = null;
      for (const episode of data.episodes) {
        if (episode.owned) {
          first = episode;
          break;
        }
      }
      const picked: EpisodeView | null = first !== null ? first
        : (data.episodes.length > 0 ? data.episodes[0] : null);
      if (picked !== null) {
        this.selectEpisode(item, data.season_number, picked);
      }
    } catch (error) {
      if (generation !== this.episodeGeneration) {
        return;
      }
      this.episodesFailed = true;
    }
  }

  /** 选集：记下集与它的文件，并刷新本机续播点 */
  private selectEpisode(item: SharedItemView, season: number, episode: EpisodeView): void {
    this.selectedSeason = season;
    this.selectedEpisode = episode;
    this.updateResume(item, season, episode.episode_number);
  }

  private updateResume(item: SharedItemView, season: number, episode: number): void {
    ShareLocalProgress.read(this.slug, item.media_item_id, season, episode).then((positionMs: number): void => {
      this.resumeMs = positionMs;
    });
  }

  // MARK: 派生

  private currentItem(): SharedItemView | null {
    return this.item;
  }

  private isTv(item: SharedItemView | null): boolean {
    return item !== null && item.kind === 'tv';
  }

  /** 当前在放的那组文件：电影 = 全部；剧集 = 选中集的文件 */
  private trackFiles(): SharedFileView[] {
    const item: SharedItemView | null = this.item;
    if (item === null) {
      return [];
    }
    if (!this.isTv(item)) {
      return item.files;
    }
    const episode: EpisodeView | null = this.selectedEpisode;
    if (episode === null) {
      return [];
    }
    return item.files.filter((file: SharedFileView): boolean =>
      file.season_number === this.selectedSeason && file.episode_number === episode.episode_number);
  }

  private availableFiles(): SharedFileView[] {
    return this.trackFiles().filter((file: SharedFileView): boolean => file.state === 'in_place');
  }

  private currentFile(): SharedFileView | null {
    const files: SharedFileView[] = this.availableFiles();
    return files.length > 0 ? files[0] : null;
  }

  private canPlay(): boolean {
    const item: SharedItemView | null = this.item;
    if (item === null) {
      return false;
    }
    return this.availableFiles().length > 0 && (!this.isTv(item) || this.selectedEpisode !== null);
  }

  /** 简介：电影用条目的；剧集优先选中集的 */
  private plotText(): string {
    const item: SharedItemView | null = this.item;
    if (item === null) {
      return '';
    }
    if (this.isTv(item)) {
      const episode: EpisodeView | null = this.selectedEpisode;
      if (episode !== null && episode.overview !== null && episode.overview !== undefined
        && episode.overview.length > 0) {
        return episode.overview;
      }
    }
    const plot: string | null | undefined = item.local_meta !== null && item.local_meta !== undefined
      ? item.local_meta.plot : null;
    return plot !== null && plot !== undefined ? plot : '';
  }

  /** 年份 · 片长 · 分辨率 · HDR（片长 NFO 优先，其次任意文件的实测时长；不足一分钟的短片不显示） */
  private factsText(): string {
    const item: SharedItemView | null = this.item;
    if (item === null) {
      return '';
    }
    const available: SharedFileView[] = this.availableFiles();
    const parts: string[] = [];
    if (item.year !== null && item.year !== undefined) {
      parts.push(`${item.year}`);
    }
    let runtime: number | null = null;
    if (item.local_meta !== null && item.local_meta !== undefined) {
      runtime = item.local_meta.runtime_minutes ?? null;
    }
    if (runtime === null || runtime === 0) {
      for (const file of item.files) {
        const probed: number | null = file.duration_seconds ?? null;
        if (probed !== null && probed >= 60) {
          runtime = Math.round(probed / 60);
          break;
        }
      }
    }
    if (runtime !== null && runtime > 0) {
      parts.push(runtimeLabel(runtime));
    }
    const resolutions: string[] = [];
    for (const file of available) {
      const raw: string | null = file.resolution ?? null;
      if (raw !== null && raw.length > 0 && !resolutions.includes(resolutionLabel(raw))) {
        resolutions.push(resolutionLabel(raw));
      }
    }
    if (resolutions.length > 0) {
      parts.push(resolutions.join(' / '));
    }
    const hdr: string[] = [];
    for (const file of available) {
      const value: string | null = file.hdr ?? null;
      if (value !== null && value.length > 0 && !hdr.includes(value)) {
        hdr.push(value);
      }
    }
    if (hdr.length > 0) {
      parts.push(hdr.join(' / '));
    }
    return parts.join(' · ');
  }

  private genresText(): string {
    const item: SharedItemView | null = this.item;
    if (item === null || item.local_meta === null || item.local_meta === undefined) {
      return '';
    }
    return item.local_meta.genres.join(' · ');
  }

  /** 文件规格行：容器 · 编码 · 体积 ·（多版本时）共 N 个版本 */
  private specText(): string {
    const current: SharedFileView | null = this.currentFile();
    if (current === null) {
      return '';
    }
    const available: SharedFileView[] = this.availableFiles();
    const parts: string[] = [];
    if (current.container !== null && current.container !== undefined) {
      parts.push(current.container.toUpperCase());
    }
    if (current.video_codec !== null && current.video_codec !== undefined) {
      parts.push(current.video_codec.toUpperCase());
    }
    parts.push(libraryBytes(current.size_bytes));
    if (available.length > 1) {
      parts.push(`共 ${available.length} 个版本`);
    }
    return parts.join(' · ');
  }

  // MARK: 播放

  private playFrom(startMs: number): void {
    const item: SharedItemView | null = this.item;
    if (item === null || !this.canPlay()) {
      return;
    }
    const season: number = this.isTv(item) ? this.selectedSeason : 0;
    const episode: number = this.isTv(item) && this.selectedEpisode !== null
      ? (this.selectedEpisode as EpisodeView).episode_number : 0;
    this.onPlay(item.media_item_id, season, episode, startMs);
  }

  // MARK: 布局

  build() {
    if (this.failed.length > 0) {
      Column({ space: 12 }) {
        this.HeaderRow()
        Text(this.failed)
          .fontSize(15)
          .fontColor('rgba(255,255,255,0.8)')
          .textAlign(TextAlign.Center)
          .padding({ left: 24, right: 24 })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    } else if (this.item !== null) {
      Stack() {
        this.Backdrop()
        Scroll() {
          Column() {
            this.HeaderRow()
            Column().height(150)
            this.TitleBlock()
            this.SectionsBlock()
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .align(Alignment.TopStart)
      }
      .width('100%')
      .height('100%')
    } else {
      Column({ space: 12 }) {
        this.HeaderRow()
        Row({ space: 10 }) {
          LoadingProgress()
            .width(20)
            .height(20)
            .color('rgba(255,255,255,0.6)')
          Text('正在读取影片信息…')
            .fontSize(15)
            .fontColor('rgba(255,255,255,0.6)')
        }
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    }
  }

  /** 剧照铺底：固定在视口，内容从下方的渐变板上浮出 */
  @Builder
  Backdrop() {
    Stack() {
      RemoteImage({ url: this.backdropUrl(), placeholderSymbol: $r('sys.symbol.film') })
        .width('100%')
        .height('100%')
      Column() {
        Column()
          .width('100%')
          .layoutWeight(1)
          .linearGradient({
            angle: 180,
            colors: [
              ['rgba(7,8,12,0.15)', 0],
              ['rgba(7,8,12,0.75)', 0.45],
              ['#07080C', 0.75]
            ]
          })
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
  }

  private backdropUrl(): string {
    const item: SharedItemView | null = this.item;
    if (item === null) {
      return '';
    }
    const backdrop: string | null = item.backdrop_url ?? null;
    const raw: string | null = backdrop !== null ? backdrop : (item.poster_url ?? null);
    const resolved: string | null = ImageUrls.resolve(this.origin(), raw ?? null, null);
    return resolved !== null ? resolved : '';
  }

  /** 顶栏：返回 + （合集分享才有）返回合集 + 字标 + 链接到期提示 */
  @Builder
  HeaderRow() {
    Row({ space: 10 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(22)
          .fontColor(['rgba(255,255,255,0.85)'])
      }
      .width(36)
      .height(36)
      .backgroundColor('rgba(255,255,255,0.08)')
      .borderRadius(18)
      .onClick(() => {
        this.onClose();
      })
      if (this.fromCollection) {
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(14)
            .fontColor(['rgba(255,255,255,0.85)'])
          Text('返回合集')
            .fontSize(15)
            .fontColor('rgba(255,255,255,0.85)')
        }
        .padding({ left: 12, right: 14, top: 8, bottom: 8 })
        .backgroundColor('rgba(255,255,255,0.08)')
        .borderRadius(18)
        .onClick(() => {
          this.onBack();
        })
      }
      Text('MOVIECLAW')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor('rgba(255,255,255,0.7)')
        .letterSpacing(3)
      Blank()
      if (this.item !== null) {
        Text(`链接 ${shareExpiryHint(this.item.expires_at)}`)
          .fontSize(12)
          .fontColor('rgba(255,255,255,0.55)')
      }
    }
    .width('100%')
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: Theme.statusBarInset + 8 })
  }

  /** 标题 + 季集行 + 事实行 + 类型 + 文件规格 + 音轨/字幕 + 播放 + 简介 */
  @Builder
  TitleBlock() {
    Column({ space: 10 }) {
      Text(this.item !== null ? this.item.title : '')
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
        .fontColor('#ffffff')
      if (this.isTv(this.item) && this.selectedEpisode !== null) {
        Text(this.episodeSubtitle(this.selectedEpisode as EpisodeView))
          .fontSize(15)
          .fontColor('rgba(255,255,255,0.65)')
      }
      if (this.factsText().length > 0) {
        Text(this.factsText())
          .fontSize(15)
          .fontColor('rgba(255,255,255,0.8)')
      }
      if (this.genresText().length > 0) {
        Text(this.genresText())
          .fontSize(15)
          .fontColor('rgba(255,255,255,0.72)')
      }
      if (this.currentFile() !== null) {
        Text(this.specText())
          .fontSize(12)
          .fontColor('rgba(255,255,255,0.5)')
        Column() {
          this.TrackRows(this.currentFile() as SharedFileView)
        }
        .width('100%')
        .padding({ top: 4 })
      }
      if (this.canPlay()) {
        this.PlayBlock()
      } else {
        Text(this.emptyPlayText())
          .fontSize(15)
          .fontColor('rgba(255,255,255,0.55)')
          .padding({ top: 8 })
      }
      if (this.plotText().length > 0) {
        this.PlotBlock()
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
  }

  private episodeSubtitle(episode: EpisodeView): string {
    const name: string | null = episode.name ?? null;
    const base: string = `第 ${this.selectedSeason} 季 第 ${episode.episode_number} 集`;
    return name !== null && name.length > 0 ? `${base} - ${name}` : base;
  }

  private emptyPlayText(): string {
    if (!this.isTv(this.item) || this.selectedEpisode !== null) {
      return '暂时没有可播放的文件。';
    }
    return '请选择一集。';
  }

  /** 音轨 / 字幕（只读）：芯片摘要 + 点开整单 */
  @Builder
  TrackRows(file: SharedFileView) {
    Column({ space: 10 }) {
      this.TrackLineRow('音轨', this.audioChips(file), this.audioLines(file),
        file.audio_streams === null || file.audio_streams === undefined ? '尚未探测' : '文件内没有音轨')
      this.TrackLineRow('字幕', this.subtitleChips(file), this.subtitleLines(file), '无内封或外挂字幕')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  TrackLineRow(label: string, chips: TrackChip[], lines: TrackLine[], emptyText: string) {
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
        Row({ space: 6 }) {
          Text(label)
            .fontSize(15)
            .fontColor(Theme.textFaint)
            .width(40)
          ForEach(chips, (chip: TrackChip) => {
            Row({ space: 6 }) {
              Text(chip.text)
                .fontSize(13)
                .fontColor('rgba(255,255,255,0.85)')
              Text(chip.detail)
                .fontSize(11)
                .fontWeight(FontWeight.Medium)
                .fontColor('rgba(255,255,255,0.5)')
            }
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .backgroundColor('rgba(255,255,255,0.075)')
            .borderRadius(16)
          }, (chip: TrackChip) => chip.text + chip.detail)
        }
        .width('100%')
        if (this.tracksExpanded) {
          Column({ space: 4 }) {
            ForEach(lines, (line: TrackLine) => {
              Text(line.text)
                .fontSize(13)
                .fontColor('rgba(255,255,255,0.7)')
                .width('100%')
                .padding({ left: 4, right: 4, top: 3, bottom: 3 })
            }, (line: TrackLine) => line.text)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: 56 })
        }
        Text(this.tracksExpanded ? '收起' : '全部轨道')
          .fontSize(13)
          .fontColor(Theme.textFaint)
          .onClick(() => {
            this.tracksExpanded = !this.tracksExpanded;
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** 音轨摘要芯片：按语言分组，`中文 ×2` / `英语 AAC` */
  private audioChips(file: SharedFileView): TrackChip[] {
    const streams: AudioStreamView[] = file.audio_streams ?? [];
    const groups: Record<string, AudioStreamView[]> = {};
    const order: string[] = [];
    for (const stream of streams) {
      const key: string = languageLabel(stream.language);
      if (groups[key] === undefined) {
        groups[key] = [];
        order.push(key);
      }
      (groups[key] as AudioStreamView[]).push(stream);
    }
    const chips: TrackChip[] = [];
    for (const key of order) {
      const group: AudioStreamView[] = groups[key] as AudioStreamView[];
      const codec: string = group[0].codec ?? '';
      chips.push(new TrackChip(key, group.length === 1 ? audioCodecName(codec) : `×${group.length}`));
    }
    return chips;
  }

  private audioLines(file: SharedFileView): TrackLine[] {
    const streams: AudioStreamView[] = file.audio_streams ?? [];
    const lines: TrackLine[] = [];
    for (let i: number = 0; i < streams.length; i++) {
      const stream: AudioStreamView = streams[i];
      const parts: string[] = [audioCodecName(stream.codec), channelsLabel(stream.channels),
        languageLabel(stream.language)];
      const title: string | null = stream.title ?? null;
      if (title !== null && title.length > 0) {
        parts.push(title);
      }
      lines.push(new TrackLine(`轨 ${i + 1} · ${parts.filter((part: string): boolean => part.length > 0).join(' · ')}`));
    }
    return lines;
  }

  private subtitleChips(file: SharedFileView): TrackChip[] {
    const streams: SubtitleStreamView[] = file.subtitle_streams;
    const groups: Record<string, SubtitleStreamView[]> = {};
    const order: string[] = [];
    for (const stream of streams) {
      const key: string = languageLabel(stream.language);
      if (groups[key] === undefined) {
        groups[key] = [];
        order.push(key);
      }
      (groups[key] as SubtitleStreamView[]).push(stream);
    }
    const chips: TrackChip[] = [];
    for (const key of order) {
      const group: SubtitleStreamView[] = groups[key] as SubtitleStreamView[];
      const codec: string = group[0].codec ?? '';
      chips.push(new TrackChip(key, group.length === 1 ? subtitleCodecName(codec) : `×${group.length}`));
    }
    return chips;
  }

  private subtitleLines(file: SharedFileView): TrackLine[] {
    const streams: SubtitleStreamView[] = file.subtitle_streams;
    const lines: TrackLine[] = [];
    for (const stream of streams) {
      const parts: string[] = [subtitleCodecName(stream.codec), languageLabel(stream.language),
        stream.external ? '外挂' : '内封'];
      const title: string | null = (stream.file_name ?? stream.title) ?? null;
      if (title !== null && title.length > 0) {
        parts.push(title);
      }
      if (stream.forced) {
        parts.push('强制');
      }
      lines.push(new TrackLine(parts.join(' · ')));
    }
    return lines;
  }

  /** 播放键 + 续播信息（访客口径：本机只有位置，进度条是空条、文案只有「看到 hh:mm」） */
  @Builder
  PlayBlock() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.play_fill'))
          .fontSize(16)
          .fontColor(['#0b0d12'])
        Text(this.resumeMs > 0 ? '继续观看' : '播放')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#0b0d12')
      }
      .width('100%')
      .height(44)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(Theme.accent)
      .borderRadius(22)
      .margin({ top: 8 })
      .onClick(() => {
        this.playFrom(0);
      })
      if (this.resumeMs > 0) {
        Column({ space: 6 }) {
          Column()
            .width('100%')
            .height(4)
            .backgroundColor('rgba(255,255,255,0.15)')
            .borderRadius(2)
          Text(`看到 ${clockText(this.resumeMs)}`)
            .fontSize(12)
            .fontColor('rgba(255,255,255,0.6)')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 简介：4 行折叠，点一下展开/收起（同 iOS ExpandablePlot） */
  @Builder
  PlotBlock() {
    Column({ space: 6 }) {
      Text(this.plotText())
        .fontSize(15)
        .fontColor('rgba(255,255,255,0.62)')
        .lineHeight(23)
        .maxLines(this.plotExpanded ? 100 : 4)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.plotExpanded ? '收起' : '展开')
        .fontSize(13)
        .fontColor('rgba(255,255,255,0.36)')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 8 })
    .onClick(() => {
      this.plotExpanded = !this.plotExpanded;
    })
  }

  /** 下方分区：分集 / 章节 / 演职员 / 外部词条 */
  @Builder
  SectionsBlock() {
    Column({ space: 24 }) {
      if (this.isTv(this.item) && this.item !== null && (this.item as SharedItemView).seasons.length > 0) {
        this.EpisodesBlock(this.item as SharedItemView)
      }
      if (this.chapters().length > 0) {
        this.ChaptersBlock()
      }
      if (this.castPeople().length > 0) {
        this.CastBlock()
      }
      this.ExternalLinksBlock()
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 28, bottom: 120 })
  }

  /** 分集区：季选择 + 在库计数 + 200 宽 16:9 横滚集卡 */
  @Builder
  EpisodesBlock(item: SharedItemView) {
    Column({ space: 12 }) {
      Row({ space: 10 }) {
        Text('分集')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
        if (item.seasons.length > 1) {
          Row({ space: 4 }) {
            Text(this.seasonLabel(item, this.currentSeason(item)))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.text)
            SymbolGlyph($r('sys.symbol.chevron_down'))
              .fontSize(12)
              .fontColor([Theme.text])
          }
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(16)
          .bindMenu(this.SeasonMenu(item))
        } else {
          Text(this.seasonLabel(item, this.currentSeason(item)))
            .fontSize(14)
            .fontColor(Theme.textMuted)
        }
        if (this.episodes !== null) {
          Text(`在库 ${this.ownedCount(this.episodes as SeasonEpisodesView)} / ${(this.episodes as SeasonEpisodesView).episodes.length} 集`)
            .fontSize(14)
            .fontColor(Theme.textFaint)
        }
      }
      .width('100%')
      if (this.episodesFailed) {
        Text('分集信息加载失败，请稍后重试。')
          .fontSize(14)
          .fontColor(Theme.textMuted)
      } else if (this.episodes !== null) {
        Scroll() {
          Row({ space: 12 }) {
            ForEach((this.episodes as SeasonEpisodesView).episodes, (episode: EpisodeView) => {
              this.EpisodeCard(this.episodes as SeasonEpisodesView, episode)
            }, (episode: EpisodeView) => `${episode.episode_number}`)
          }
          .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
      } else {
        Row({ space: 8 }) {
          LoadingProgress()
            .width(16)
            .height(16)
            .color(Theme.textFaint)
          Text('正在读取分集信息…')
            .fontSize(14)
            .fontColor(Theme.textMuted)
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  SeasonMenu(item: SharedItemView) {
    Menu() {
      ForEach(item.seasons, (season: number) => {
        MenuItem({ content: this.seasonLabel(item, season) })
          .onClick(() => {
            this.episodeSeason = season;
            this.loadEpisodes(item, season);
          })
      }, (season: number) => `${season}`)
    }
  }

  /** 当前展示的季：未手动切过时落在第一个在库的季 */
  private currentSeason(item: SharedItemView): number {
    return this.episodeSeason > 0 ? this.episodeSeason : this.initialSeason(item);
  }

  private seasonLabel(item: SharedItemView, season: number): string {
    const name: string = season === 0 ? '特别篇' : `第 ${season} 季`;
    let owned: boolean = false;
    for (const file of item.files) {
      if (file.season_number === season) {
        owned = true;
        break;
      }
    }
    return owned ? name : `${name} · 未入库`;
  }

  private ownedCount(data: SeasonEpisodesView): number {
    let count: number = 0;
    for (const episode of data.episodes) {
      if (episode.owned) {
        count++;
      }
    }
    return count;
  }

  private isPicked(episode: EpisodeView): boolean {
    const picked: EpisodeView | null = this.selectedEpisode;
    return picked !== null && picked.episode_number === episode.episode_number;
  }

  /** 一张集卡：16:9 剧照 + 选中描边 + 缺角标 + 单行标题；缺集整体压暗 */
  @Builder
  EpisodeCard(data: SeasonEpisodesView, episode: EpisodeView) {
    Column({ space: 6 }) {
      Stack() {
        if (episode.still_url !== null && episode.still_url !== undefined) {
          RemoteImage({ url: this.stillUrl(episode) })
            .width('100%')
            .height('100%')
        } else {
          Column() {
            Text(`${episode.episode_number}`)
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor('rgba(255,255,255,0.25)')
          }
          .width('100%')
          .height('100%')
          .backgroundColor(Theme.surfaceRaised)
          .justifyContent(FlexAlign.Center)
        }
        if (!episode.owned) {
          Text('缺')
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.warning)
            .padding({ left: 5, right: 5, top: 1, bottom: 1 })
            .backgroundColor('rgba(0,0,0,0.6)')
            .borderRadius(4)
            .position({ x: '78%', y: 6 })
        }
      }
      .width('100%')
      .aspectRatio(16 / 9)
      .borderRadius(12)
      .clip(true)
      .border({
        width: this.isPicked(episode) ? 2 : 1,
        color: this.isPicked(episode) ? 'rgba(255,255,255,0.85)' : 'rgba(255,255,255,0.08)'
      })
      Text(`${episode.episode_number}. ${this.episodeName(episode)}`)
        .fontSize(13)
        .fontWeight(this.isPicked(episode) ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.isPicked(episode) ? '#ffffff' : Theme.text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width(200)
    .alignItems(HorizontalAlign.Start)
    .opacity(episode.owned ? 1 : 0.45)
    .onClick(() => {
      const item: SharedItemView | null = this.item;
      if (item !== null) {
        this.selectEpisode(item, data.season_number, episode);
      }
    })
  }

  private episodeName(episode: EpisodeView): string {
    const name: string | null = episode.name ?? null;
    return name !== null && name.length > 0 ? name : `第 ${episode.episode_number} 集`;
  }

  private stillUrl(episode: EpisodeView): string {
    const resolved: string | null = ImageUrls.resolve(this.origin(), episode.still_url ?? null, null);
    return resolved !== null ? resolved : '';
  }

  /** 当前文件的章节 */
  private chapters(): ChapterView[] {
    const current: SharedFileView | null = this.currentFile();
    if (current === null || current.chapters === null || current.chapters === undefined) {
      return [];
    }
    return current.chapters;
  }

  private chapterStart(chapter: ChapterView): number {
    const frame: number | null = chapter.frame_ms ?? null;
    return frame !== null ? frame : chapter.start_ms;
  }

  /** 上次看到的位置落在哪一章：start ≤ pos < end（末章无 end 视为到片尾） */
  private isResumeChapter(chapter: ChapterView): boolean {
    if (this.resumeMs <= 0) {
      return false;
    }
    const end: number | null = chapter.end_ms ?? null;
    return this.resumeMs >= chapter.start_ms && (end === null || this.resumeMs < end);
  }

  /** 章节横排：16:9 章节图（或深色占位 + 大号时间戳）+ 左下角时间戳 + 标题；点它从该章起播 */
  @Builder
  ChaptersBlock() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Text('章节')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
        Text(`${this.chapters().length} 个章节`)
          .fontSize(14)
          .fontColor(Theme.textFaint)
      }
      .width('100%')
      Scroll() {
        Row({ space: 12 }) {
          ForEach(this.chapters(), (chapter: ChapterView) => {
            this.ChapterCard(chapter)
          }, (chapter: ChapterView) => `${chapter.index}`)
        }
        .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  ChapterCard(chapter: ChapterView) {
    Column({ space: 8 }) {
      Stack({ alignContent: Alignment.BottomStart }) {
        if (chapter.image_url !== null && chapter.image_url !== undefined) {
          RemoteImage({ url: this.chapterUrl(chapter) })
            .width('100%')
            .height('100%')
        } else {
          Column() {
            Text(clockText(this.chapterStart(chapter)))
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor('rgba(255,255,255,0.2)')
          }
          .width('100%')
          .height('100%')
          .backgroundColor(Theme.surfaceRaised)
          .justifyContent(FlexAlign.Center)
        }
        if (this.isResumeChapter(chapter)) {
          Text('上次看到这里')
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor('#ffffff')
            .padding({ left: 6, right: 6, top: 1, bottom: 1 })
            .backgroundColor('#9fb0c9')
            .borderRadius(4)
            .position({ x: '52%', y: 6 })
        }
        Text(clockText(this.chapterStart(chapter)))
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor('rgba(255,255,255,0.9)')
          .padding({ left: 6, right: 6, top: 1, bottom: 1 })
          .backgroundColor('rgba(0,0,0,0.6)')
          .borderRadius(4)
          .margin(6)
      }
      .width('100%')
      .aspectRatio(16 / 9)
      .borderRadius(12)
      .clip(true)
      .border({ width: 1, color: 'rgba(255,255,255,0.08)' })
      Text(chapter.title !== null && chapter.title !== undefined && chapter.title.length > 0
        ? chapter.title : `第 ${chapter.index + 1} 章`)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width(200)
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.playFrom(this.chapterStart(chapter));
    })
  }

  private chapterUrl(chapter: ChapterView): string {
    const resolved: string | null = ImageUrls.resolve(this.origin(), chapter.image_url ?? null, null);
    return resolved !== null ? resolved : '';
  }

  // MARK: 演职员

  private castPeople(): string[][] {
    const item: SharedItemView | null = this.item;
    if (item === null || item.local_meta === null || item.local_meta === undefined) {
      return [];
    }
    const meta = item.local_meta;
    const people: string[][] = [];
    if (meta.director_credits.length > 0) {
      for (const credit of meta.director_credits) {
        people.push([credit.name, '导演', credit.thumb_url ?? '']);
      }
    } else {
      const seen: string[] = [];
      for (const name of meta.directors) {
        if (!seen.includes(name)) {
          seen.push(name);
        }
      }
      for (const name of seen) {
        people.push([name, '导演', '']);
      }
    }
    for (const actor of meta.actors) {
      const role: string | null = actor.role ?? null;
      people.push([actor.name, role !== null && role.length > 0 ? `饰 ${role}` : '', actor.thumb_url ?? '']);
    }
    return people;
  }

  /** 演职员横排（访客页不给影人跳转，点不出任何东西） */
  @Builder
  CastBlock() {
    Column({ space: 12 }) {
      Text('演职员')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
      Scroll() {
        Row({ space: 12 }) {
          ForEach(this.castPeople(), (person: string[]) => {
            Column({ space: 2 }) {
              Stack({ alignContent: Alignment.Center }) {
                Column()
                  .width('100%')
                  .height('100%')
                  .backgroundColor(Theme.surfaceRaised)
                Text(person[0].length > 0 ? person[0].substring(0, 1) : '?')
                  .fontSize(24)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('rgba(255,255,255,0.3)')
                if (person[2].length > 0) {
                  RemoteImage({
                    url: this.castAvatar(person[2]),
                    placeholderSymbol: $r('sys.symbol.person')
                  })
                    .width('100%')
                    .height('100%')
                }
              }
              .width(96)
              .aspectRatio(2 / 3)
              .borderRadius(12)
              .clip(true)
              .border({ width: 1, color: Theme.line })
              Text(person[0])
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.text)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ top: 6 })
              if (person[1].length > 0) {
                Text(person[1])
                  .fontSize(11)
                  .fontColor(Theme.textFaint)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
            }
            .width(96)
            .alignItems(HorizontalAlign.Start)
          }, (person: string[]) => person.join('|'))
        }
        .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  private castAvatar(raw: string): string {
    const resolved: string | null = ImageUrls.resolve(this.origin(), raw, null);
    return resolved !== null ? resolved : '';
  }

  /** 外部词条：TMDB / IMDb / 豆瓣（浏览器打开） */
  @Builder
  ExternalLinksBlock() {
    if (this.hasExternalLinks()) {
      Column({ space: 12 }) {
        Column()
          .width('100%')
          .height(1)
          .backgroundColor('rgba(255,255,255,0.04)')
        Row({ space: 16 }) {
          Text('相关链接')
            .fontSize(12)
            .fontColor(Theme.textFaint)
          if (this.item !== null && this.item.tmdb_id !== null && this.item.tmdb_id !== undefined) {
            Text('TMDB ↗')
              .fontSize(12)
              .fontColor('rgba(255,255,255,0.7)')
              .onClick(() => {
                this.openUrl(this.tmdbUrl(this.item as SharedItemView));
              })
          }
          if (this.item !== null && this.item.imdb_id !== null && this.item.imdb_id !== undefined) {
            Text('IMDb ↗')
              .fontSize(12)
              .fontColor('rgba(255,255,255,0.7)')
              .onClick(() => {
                this.openUrl(`https://www.imdb.com/title/${(this.item as SharedItemView).imdb_id}/`);
              })
          }
          if (this.item !== null && this.item.douban_id !== null && this.item.douban_id !== undefined) {
            Text('豆瓣 ↗')
              .fontSize(12)
              .fontColor('rgba(255,255,255,0.7)')
              .onClick(() => {
                this.openUrl(`https://movie.douban.com/subject/${(this.item as SharedItemView).douban_id}/`);
              })
          }
        }
        .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
    }
  }

  private hasExternalLinks(): boolean {
    const item: SharedItemView | null = this.item;
    return item !== null && ((item.tmdb_id !== null && item.tmdb_id !== undefined)
      || (item.imdb_id !== null && item.imdb_id !== undefined)
      || (item.douban_id !== null && item.douban_id !== undefined));
  }

  private tmdbUrl(item: SharedItemView): string {
    const kind: string = item.kind === 'tv' ? 'tv' : 'movie';
    return `https://www.themoviedb.org/${kind}/${item.tmdb_id}`;
  }

  private openUrl(url: string): void {
    const context: common.UIAbilityContext = getContext() as common.UIAbilityContext;
    context.openLink(url).catch((): void => {
      this.getUIContext().getPromptAction().showToast({ message: '打不开链接' });
    });
  }
}
