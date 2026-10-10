import { display } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { Theme } from '../theme/AppTheme';
import { WindowInsets } from '../common/WindowInsets';
import { SharePanel, shareMessage } from './ShareSheet';
import { ArtworkPickerSheet } from './ArtworkPickerSheet';
import { TransferItemSheet } from './TransferItemSheet';
import { Permissions } from '../common/Permissions';
import { DirectorView, ReidentifyResultView, ShareCreateRequest, ShareView } from '../api/Models';
import { PlayerParams } from '../player/PlayerPage';
import { AppModel } from '../common/AppModel';
import { RemoteImage } from '../common/RemoteImage';
import { ImmersiveHeroBackdrop } from '../common/ImmersiveHero';
import { ImageUrls, ImageVariant } from '../common/ImageUrls';
import { AppFooter } from '../common/AppFooter';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import {
  EpisodeView,
  LibraryFileView,
  LibraryItemDetailView,
  LibraryView,
  PlaybackMarksRequest,
  PlaybackStateView,
  SeasonEpisodesView,
  SubscriptionView
} from '../api/Models';
import { libraryBytes } from './LibraryShared';
import { PersonParams } from '../discover/PersonDetailPage';
import { SubscribeCenter } from '../subscriptions/SubscribeCenter';
import { SubscriptionParams } from '../subscriptions/SubscriptionDetailPage';

/**
 * 条目详情页路由参数。
 *
 * 与 LibraryRouteParams 同理：**不要用 `instanceof` 判断**——`pushPathByName` 传过来的参数
 * 会被序列化，到 `onReady` 时已经是普通对象，原型链断了。按字段取值并校验。
 */
export class ItemRouteParams {
  readonly libraryId: number;
  readonly mediaItemId: number;
  readonly season: number | null;
  readonly episode: number | null;

  constructor(libraryId: number, mediaItemId: number, season: number | null = null,
    episode: number | null = null) {
    this.libraryId = libraryId;
    this.mediaItemId = mediaItemId;
    this.season = season;
    this.episode = episode;
  }

  static of(param: Object | undefined | null): ItemRouteParams | null {
    if (param === undefined || param === null) {
      return null;
    }
    const raw: ItemRouteParams = param as ItemRouteParams;
    const libraryId: number = raw.libraryId;
    const mediaItemId: number = raw.mediaItemId;
    if (!Number.isFinite(libraryId) || !Number.isFinite(mediaItemId)
      || libraryId <= 0 || mediaItemId <= 0) {
      return null;
    }
    const season: number = raw.season as number;
    const episode: number = raw.episode as number;
    return new ItemRouteParams(Math.floor(libraryId), Math.floor(mediaItemId),
      Number.isFinite(season) ? Math.floor(season) : null,
      Number.isFinite(episode) ? Math.floor(episode) : null);
  }
}

/** 路由表注册用（router_map.json 的 buildMethod） */
@Builder
export function LibraryItemBuilder() {
  LibraryItemDetailPage()
}

/**
 * 条目详情页（对齐 iOS 端 Features/Library/LibraryItemDetailView.swift）。
 *
 * 结构：沉浸剧照 → 标题区（盖在剧照下半部）→ 简介（4 行可展开）→ 剧集/章节/演职员/文件。
 * 取数与 iOS 一致：`libraryItemsGet` 与 `libraryGet` **并发**发出（iOS 用 async let），
 * 404 落兜底态，其它错误保留已显示内容。
 *
 * 本轮暂缓（对应 iOS 的暂缓项，见 docs/harmonyos-port.md）：章节缩略条、相关链接、
 * 管理员动作（刷新元数据/生成章节/删除/转移/换海报/重新识别）、分享。
 * 播放键先给提示——播放器还没做（用户已定「最后做」）。
 */
/** 演职员卡上的一人（对应 iOS `CastPerson`）：名字 + 副标题（导演 / 饰 角色）+ 头像地址 + 影人页链接 */
class CastPerson {
  readonly name: string;
  readonly subtitle: string | null;
  /** 已解析成可请求地址的头像（空串 = 没有头像，用首字母兜底） */
  readonly avatar: string;
  /** TMDB 影人 ID；有值时这一格链到库内影人页（null = 不可点，同 iOS personId） */
  readonly personId: number | null;

  constructor(name: string, subtitle: string | null, avatar: string, personId: number | null = null) {
    this.name = name;
    this.subtitle = subtitle;
    this.avatar = avatar;
    this.personId = personId;
  }

  key(): string {
    return `${this.name}-${this.subtitle ?? ''}`;
  }
}

@Component
export struct LibraryItemDetailPage {
  private navStack: NavPathStack = new NavPathStack();
  private libraryId: number = 0;
  private mediaItemId: number = 0;
  /** 分享面板（本页 sheet 槽位是空的，直接占）。本页是 V1 `@Component`，所以用 `@State` 不是 `@Local`。 */
  @State private showShare: boolean = false;
  @State private shareBusy: boolean = false;
  @State private share: ShareView | null = null;
  /** 更换图片弹层（对应 iOS `.artwork` sheet） */
  @State private showArtwork: boolean = false;
  /** 转移条目弹层（对应 iOS `.transfer` sheet） */
  @State private showTransfer: boolean = false;
  /** 条目级管理动作在途 */
  @State private actionBusy: boolean = false;
  /** 初始季/集（从剧集列表点进来时带） */
  private initialSeason: number | null = null;
  private initialEpisode: number | null = null;
  private started: boolean = false;

  @State private detail: LibraryItemDetailView | null = null;
  @State private library: LibraryView | null = null;
  @State private failed: boolean = false;
  @State private refreshing: boolean = false;
  /** 沉浸大图高度：与 iOS 一致，取值见 `Theme.heroHeight`（订阅轮播同款，保证两页取景一致） */
  @State private heroHeight: number = Theme.heroHeight;

  /** 观看进度（播放键的「继续观看 12:34」用它） */
  @State private watched: PlaybackStateView | null = null;
  /** 收藏（null = 还没问到） */
  @State private favorite: boolean | null = null;
  /** 标记请求在途：防连点 */
  @State private marking: boolean = false;

  /** 当前季的集列表（null = 还没拿到） */
  @State private episodes: SeasonEpisodesView | null = null;
  /** 集列表拉失败：与「加载中」分开，否则失败会一直转圈（对应 iOS SeasonEpisodesSection 的 failed） */
  @State private episodesFailed: boolean = false;
  @State private season: number = 1;
  /** 选中的集（剧集才有；电影恒为 null） */
  @State private selectedEpisode: EpisodeView | null = null;

  @State private plotExpanded: boolean = false;

  // MARK: 派生

  /** 电影为 true，剧集为 false（同 iOS `detail?.kind != "tv"`） */
  private isMovie(): boolean {
    const detail: LibraryItemDetailView | null = this.detail;
    return detail === null ? true : detail.kind !== 'tv';
  }

  /** 当前展示的文件：电影是本体的文件，剧集是选中集的文件 */
  private currentFiles(): LibraryFileView[] {
    const detail: LibraryItemDetailView | null = this.detail;
    if (detail === null) {
      return [];
    }
    if (this.isMovie()) {
      return detail.files;
    }
    const picked: EpisodeView | null = this.selectedEpisode;
    if (picked === null || picked === undefined) {
      return [];
    }
    const ids: number[] = picked.file_ids;
    const out: LibraryFileView[] = [];
    for (const file of detail.files) {
      if (ids.indexOf(file.id) >= 0) {
        out.push(file);
      }
    }
    return out;
  }

  /** 当前播放单元（电影是 S0E0，剧集是选中集） */
  private playUnitSeason(): number {
    const picked: EpisodeView | null = this.selectedEpisode;
    return picked === null || picked === undefined ? 0 : picked.episode_number;
  }

  /** 简介：剧集优先用当前集的 overview，退回本体的 plot（同 iOS） */
  private plotText(): string {
    const detail: LibraryItemDetailView | null = this.detail;
    if (detail === null) {
      return '';
    }
    if (!this.isMovie()) {
      const picked: EpisodeView | null = this.selectedEpisode;
      if (picked !== null && picked !== undefined) {
        const overview: string | null = picked.overview ?? null;
        if (overview !== null && overview.length > 0) {
          return overview;
        }
      }
    }
    const meta = detail.local_meta;
    if (meta === null || meta === undefined) {
      return '';
    }
    return meta.plot ?? '';
  }

  /** 条目 Logo 地址（有就用它当标题） */
  private logoUrl(detail: LibraryItemDetailView): string {
    const raw: string | null = detail.logo_url ?? null;
    return ImageUrls.resolve(AppModel.origin(), raw, ImageVariant.landscapeCard) ?? '';
  }

  /** 剧集当前集：「第 N 季 第 M 集 - 集名」（对应 iOS） */
  private episodeLine(): string {
    const picked: EpisodeView | null = this.selectedEpisode;
    if (picked === null || picked === undefined) {
      return '';
    }
    const name: string = picked.name ?? '';
    const head: string = `第 ${this.season} 季 第 ${picked.episode_number} 集`;
    return name.length > 0 ? `${head} - ${name}` : head;
  }

  /**
   * 事实行（对应 iOS `factsLine`）：**年份 · 时长 · 评分 · 分辨率 · HDR**，用 ` · ` 连接。
   * 顺序和内容都照 iOS 来——之前我写成了「★评分 · 年份 · 时长」，顺序是错的。
   */
  private factsLine(detail: LibraryItemDetailView): string {
    const parts: string[] = [];
    const year: number | null = detail.year ?? null;
    if (year !== null && year > 0) {
      parts.push(`${year}`);
    }
    const runtime: number = this.runtimeMinutes(detail);
    if (runtime > 0) {
      parts.push(this.runtimeText(runtime));
    }
    const meta = detail.local_meta;
    const rating: number | null = meta === null || meta === undefined ? null : (meta.rating ?? null);
    if (rating !== null && rating > 0) {
      parts.push(`★ ${rating.toFixed(1)}`);
    }
    const resolutions: string[] = this.resolutionLabels(detail);
    if (resolutions.length > 0) {
      parts.push(resolutions.join(' / '));
    }
    const hdrs: string[] = this.hdrLabels(detail);
    if (hdrs.length > 0) {
      parts.push(hdrs.join(' / '));
    }
    return parts.join('  ·  ');
  }

  /** 时长：优先刮削到的分钟数，其次从文件时长换算（同 iOS） */
  private runtimeMinutes(detail: LibraryItemDetailView): number {
    const meta = detail.local_meta;
    const scraped: number | null = meta === null || meta === undefined ? null : (meta.runtime_minutes ?? null);
    if (scraped !== null && scraped > 0) {
      return scraped;
    }
    for (const file of detail.files) {
      const seconds: number | null = file.duration_seconds ?? null;
      if (seconds !== null && seconds > 0) {
        return Math.round(seconds / 60);
      }
    }
    return 0;
  }

  private runtimeText(minutes: number): string {
    if (minutes < 60) {
      return `${minutes} 分钟`;
    }
    const h: number = Math.floor(minutes / 60);
    const m: number = minutes % 60;
    return m > 0 ? `${h} 小时 ${m} 分钟` : `${h} 小时`;
  }

  /** 参与统计的文件：电影是本体在架文件，剧集是当前集的（同 iOS） */
  private statFiles(detail: LibraryItemDetailView): LibraryFileView[] {
    if (this.isMovie()) {
      const out: LibraryFileView[] = [];
      for (const file of detail.files) {
        if (file.state === 'in_place') {
          out.push(file);
        }
      }
      return out;
    }
    return this.currentFiles();
  }

  /** 分辨率标签：去重后按 iOS 的名字映射（2160p → 4K 等） */
  private resolutionLabels(detail: LibraryItemDetailView): string[] {
    const seen: string[] = [];
    for (const file of this.statFiles(detail)) {
      const raw: string | null = file.resolution ?? null;
      if (raw !== null && raw.length > 0 && seen.indexOf(raw) < 0) {
        seen.push(raw);
      }
    }
    seen.sort((a: string, b: string): number => a < b ? 1 : -1);
    const out: string[] = [];
    for (const raw of seen) {
      out.push(LibraryItemDetailPage.resolutionLabel(raw));
    }
    return out;
  }

  private static resolutionLabel(raw: string): string {
    const key: string = raw.trim().toLowerCase();
    if (key === '4320p') {
      return '8K';
    }
    if (key === '2160p' || key === '4k') {
      return '4K';
    }
    if (key === '1440p' || key === '2k') {
      return '2K';
    }
    return raw;
  }

  /** HDR 标签：按 iOS 的优先级排序（杜比视界 > HDR10+ > HDR10 > HLG > HDR） */
  private hdrLabels(detail: LibraryItemDetailView): string[] {
    const order: string[] = ['Dolby Vision', 'HDR10+', 'HDR10', 'HLG', 'HDR'];
    const seen: string[] = [];
    for (const file of this.statFiles(detail)) {
      const raw: string | null = file.hdr ?? null;
      if (raw !== null && raw.length > 0 && seen.indexOf(raw) < 0) {
        seen.push(raw);
      }
    }
    seen.sort((a: string, b: string): number => {
      const ai: number = order.indexOf(a);
      const bi: number = order.indexOf(b);
      return (ai < 0 ? 99 : ai) - (bi < 0 ? 99 : bi);
    });
    return seen;
  }

  private seriesName(detail: LibraryItemDetailView): string {
    const name: string | null = detail.series_name ?? null;
    return name ?? '';
  }

  /** 合集：最多列 3 个，其余收成「还有 N 个」（同 iOS） */
  private collectionsText(detail: LibraryItemDetailView): string {
    const names: string[] = [];
    const total: number = detail.collections.length;
    const shown: number = Math.min(3, total);
    for (let i = 0; i < shown; i++) {
      names.push(detail.collections[i].name);
    }
    if (total > 3) {
      return `${names.join(' · ')} · 还有 ${total - 3} 个`;
    }
    return names.join(' · ');
  }

  private genres(): string[] {
    const detail: LibraryItemDetailView | null = this.detail;
    if (detail === null || detail.local_meta === null || detail.local_meta === undefined) {
      return [];
    }
    return detail.local_meta.genres;
  }

  /**
   * 演职员（对应 iOS `castRow`）：导演在前，再演员。
   *
   * **要带上 `thumb_url`**——之前这里只取了名字、把头像字段整个漏掉了，
   * 界面上就只剩一排文字胶囊（用户反馈「演员图片没有显示」）。
   * 头像走 `ImageVariant.posterCard`（2:3 竖图，同 iOS 的 `.posterCard`）。
   */
  private castPeople(): CastPerson[] {
    const detail: LibraryItemDetailView | null = this.detail;
    if (detail === null || detail.local_meta === null || detail.local_meta === undefined) {
      return [];
    }
    const meta = detail.local_meta;
    const out: CastPerson[] = [];
    // 导演：优先用 director_credits（有头像与 tmdb id），没有就退回纯名字
    const credits: DirectorView[] = meta.director_credits;
    if (credits.length > 0) {
      for (const d of credits) {
        out.push(new CastPerson(d.name, '导演', this.avatarUrl(d.thumb_url ?? null),
          d.tmdb_person_id > 0 ? d.tmdb_person_id : null));
      }
    } else {
      for (const name of meta.directors) {
        out.push(new CastPerson(name, '导演', ''));
      }
    }
    for (const actor of meta.actors) {
      const name: string = actor.name ?? '';
      if (name.length === 0) {
        continue;
      }
      const role: string | null = actor.role ?? null;
      out.push(new CastPerson(name,
        role !== null && role.length > 0 ? `饰 ${role}` : null,
        this.avatarUrl(actor.thumb_url ?? null),
        (actor.tmdb_person_id ?? 0) > 0 ? actor.tmdb_person_id as number : null));
    }
    return out;
  }

  /** 头像地址（相对路径要拼服务器地址；后端地址自带 ?v= 时也能正确接参数，见 ImageUrls） */
  private avatarUrl(raw: string | null): string {
    const resolved: string | null = ImageUrls.resolve(AppModel.origin(), raw, ImageVariant.posterCard);
    return resolved !== null ? resolved : '';
  }

  /** 当前服务器 origin（图片地址要用它拼） */
  private posterUrl(): string {
    const detail: LibraryItemDetailView | null = this.detail;
    if (detail === null) {
      return '';
    }
    const model: AppModel = AppModel.shared;
    const origin: string = model.client !== null ? model.client.origin : '';
    const raw: string | null = detail.backdrop_url ?? detail.poster_url ?? null;
    // **不传派生变体**：iOS 取的是原图（`api.image(detail.backdropUrl ?? detail.posterUrl)`），
    // 传变体会让后端把竖版海报按横版裁切——订阅轮播那边之前就是这么错的
    return ImageUrls.resolve(origin, raw, null) ?? '';
  }

  // MARK: 加载

  private start(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    this.reload();
    this.loadFavorite();
  }

  /**
   * 拉条目与所属库（并发，同 iOS 的 `async let item / lib`）。
   * 404 → 兜底态（条目已不存在）；其它错误：已有内容就保留，首次加载才落兜底态。
   */
  private async reload(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    const libraryId: number = this.libraryId;
    const mediaItemId: number = this.mediaItemId;
    try {
      const itemPending: Promise<LibraryItemDetailView> =
        api.libraryItemsGet(libraryId, mediaItemId);
      const libPending: Promise<LibraryView | null> =
        api.libraryGet(libraryId).catch((): LibraryView | null => null);
      const detail: LibraryItemDetailView = await itemPending;
      const library: LibraryView | null = await libPending;
      this.detail = detail;
      if (library !== null) {
        this.library = library;
      }
      this.failed = false;
      this.pickInitialEpisode(detail);
      this.loadEpisodes();
      this.loadResume();
    } catch (error) {
      const status: number | null = error instanceof ApiError ? error.status : null;
      if (status === 404) {
        this.failed = true;
      } else if (this.detail === null) {
        this.failed = true;
      }
    }
  }

  /** 收藏态（单独一路，同 iOS 的 `.task { favorite = ... }`） */
  private async loadFavorite(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    try {
      const marks = await api.playbackMarksGet(this.mediaItemId);
      this.favorite = marks.is_favorite;
    } catch (error) {
      this.favorite = null;
    }
  }

  /**
   * 选起始集：路由带了季/集就用它（且该集确实在库），否则用库里有的第一季的第一集。
   * 对应 iOS SeasonEpisodesSection 的 requestedSeason 兜底链。
   */
  private pickInitialEpisode(detail: LibraryItemDetailView): void {
    const seasons: number[] = detail.seasons;
    if (seasons.length === 0) {
      return;
    }
    let season: number = seasons[0];
    const wantedSeason: number | null = this.initialSeason;
    if (wantedSeason !== null && seasons.indexOf(wantedSeason) >= 0) {
      season = wantedSeason;
    }
    this.season = season;
  }

  /** 拉当前季的集列表 */
  private async loadEpisodes(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null || this.isMovie()) {
      return;
    }
    const libraryId: number = this.libraryId;
    const mediaItemId: number = this.mediaItemId;
    const season: number = this.season;
    try {
      const view: SeasonEpisodesView = await api.libraryItemsListEpisodes(libraryId, mediaItemId, season);
      // 拉的过程中换了季就丢弃
      if (season !== this.season) {
        return;
      }
      this.episodes = view;
      this.episodesFailed = false;
      this.pickEpisode(view);
    } catch (error) {
      this.episodes = null;
      this.episodesFailed = true;
    }
  }

  /** 选中集：优先路由指定的那一集，否则取第一集 */
  private pickEpisode(view: SeasonEpisodesView): void {
    const list: EpisodeView[] = view.episodes;
    if (list.length === 0) {
      this.selectedEpisode = null;
      return;
    }
    const wanted: number | null = this.initialEpisode;
    if (wanted !== null) {
      for (const episode of list) {
        if (episode.episode_number === wanted) {
          this.selectedEpisode = episode;
          return;
        }
      }
    }
    if (this.selectedEpisode === null) {
      this.selectedEpisode = list[0];
    }
  }

  /** 当前单元的观看进度（播放键文案用） */
  private async loadResume(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    const season: number = this.playUnitSeason();
    try {
      this.watched = await api.playbackResume(this.mediaItemId, season, season);
    } catch (error) {
      this.watched = null;
    }
  }

  // MARK: 动作

  /** 标记已看 / 未看（POST /playback/marks，同 iOS toggleWatched） */
  private async toggleWatched(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null || this.marking) {
      return;
    }
    const next: boolean = !(this.watched !== null && this.watched.played);
    this.marking = true;
    try {
      const season: number = this.playUnitSeason();
      const body: PlaybackMarksRequest = {
        media_item_id: this.mediaItemId,
        season_number: season,
        episode_number: season,
        played: next
      };
      await api.playbackMarksSet(body);
      await this.loadResume();
      const toaster = this.getUIContext().getPromptAction();
      toaster.showToast({ message: next ? '已标记为已看' : '已标记为未看' });
    } catch (error) {
      const toaster = this.getUIContext().getPromptAction();
      toaster.showToast({ message: '标记失败，请重试' });
    } finally {
      this.marking = false;
    }
  }

  /** 收藏 / 取消收藏 */
  private async toggleFavorite(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null || this.marking) {
      return;
    }
    const next: boolean = !(this.favorite ?? false);
    this.marking = true;
    this.favorite = next;
    try {
      const body: PlaybackMarksRequest = { media_item_id: this.mediaItemId, favorite: next };
      const marks = await api.playbackMarksSet(body);
      this.favorite = marks.is_favorite;
    } catch (error) {
      this.favorite = !next;
      const toaster = this.getUIContext().getPromptAction();
      toaster.showToast({ message: '操作失败，请重试' });
    } finally {
      this.marking = false;
    }
  }

  /** 切季：重新拉这一季的集 */
  private onSeasonPick(season: number): void {
    if (season === this.season) {
      return;
    }
    this.season = season;
    this.selectedEpisode = null;
    this.loadEpisodes();
  }

  /** 选集：换简介、换文件区、换播放键的进度 */
  private onEpisodePick(episode: EpisodeView): void {
    this.selectedEpisode = episode;
    this.loadResume();
  }

  /** 播放：播放器还没做，先明确提示（用户已定「最后做播放器」） */
  /** 播放：带上续播位置（服务端会按能力判定档位，需要转码时直接回 HLS 地址） */
  private onPlay(): void {
    const state: PlaybackStateView | null = this.watched;
    const resume: number = state !== null && !state.played ? (state.position_ms ?? 0) : 0;
    // 详情页是「一部作品」而不是某一集，季集传 0 让服务端挑该看的那一集
    this.navStack.pushPathByName('player', new PlayerParams(this.mediaItemId, 0, 0, 0, resume));
  }

  // MARK: 视图

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
        if (this.failed) {
          this.FailedState()
        } else if (this.detail === null) {
          this.LoadingState()
        } else {
          this.Content(this.detail as LibraryItemDetailView)
        }
        this.TopBar()
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg)
      // 沉浸式：剧照大图铺到状态栏下面
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
      .bindSheet($$this.showArtwork, this.ArtworkSheetContent(), {
        height: SheetSize.LARGE,
        dragBar: true,
        showClose: false,
        backgroundColor: Theme.bg
      })
    }
    .hideTitleBar(true)
    .bindSheet($$this.showShare, this.ShareSheetContent(), {
      height: SheetSize.MEDIUM,
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.bg
    })
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
      const params: ItemRouteParams | null =
        ItemRouteParams.of(ctx.pathInfo.param as Object | undefined);
      if (params !== null) {
        this.libraryId = params.libraryId;
        this.mediaItemId = params.mediaItemId;
        this.initialSeason = params.season;
        this.initialEpisode = params.episode;
        this.start();
      }
    })
  }

  /** 返回键：浮在剧照上（iOS 是系统导航栏，这里自绘保持深色一致） */
  @Builder
  TopBar() {
    Row() {
      // 用 Stack 把字形居中：`SymbolGlyph` 自己带字形边距，直接给 width/height 时
      // 图标会偏在圆钮左边，看着「歪」（实测）
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(22)
          .fontColor([Theme.text])
      }
      .width(40)
      .height(40)
      .backgroundColor('rgba(0, 0, 0, 0.35)')
      .borderRadius(20)
      .onClick(() => {
        this.navStack.pop();
      })
      Blank()
      // 管理员动作（对应 iOS 条目详情的 ⋯ 菜单）
      if (this.canManage()) {
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.more'))
            .fontSize(20)
            .fontColor([Theme.text])
        }
        .width(40)
        .height(40)
        .backgroundColor('rgba(0, 0, 0, 0.35)')
        .borderRadius(20)
        .bindMenu(this.ItemActionsMenu())
        .margin({ right: 8 })
      }
      // 分享：生成一条不用登录就能看的公开链接（对应 iOS `LibraryShareSheet`）
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($r('sys.symbol.paperplane'))
          .fontSize(20)
          .fontColor([Theme.text])
      }
      .width(40)
      .height(40)
      .backgroundColor('rgba(0, 0, 0, 0.35)')
      .borderRadius(20)
      .onClick(() => {
        this.openShare();
      })
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 8 + WindowInsets.top })
    .bindSheet($$this.showTransfer, this.TransferSheetContent(), {
      height: SheetSize.LARGE,
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.bg
    })
  }

  /** 打开分享面板：先拉一次已有的链接（没有就是「还没建过」） */
  /** 有没有管理权限（决定 ⋯ 菜单出不出来） */
  /** 把错误转成人话（`ApiError` 里已经是后端原话） */
  private static describe(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '操作失败';
  }

  private canManage(): boolean {
    return Permissions.fromSession(AppModel.shared.session).isAdmin;
  }

  /** 洗版：已有订阅直接去订阅详情跑一轮洗版；没有则以洗版模式打开订阅对话框（同 iOS `upgrade`） */
  private async upgrade(): Promise<void> {
    const detail: LibraryItemDetailView | null = this.detail;
    if (detail === null) {
      return;
    }
    const tmdb: number = detail.tmdb_id ?? 0;
    const kind: string = detail.kind === 'tv' ? 'tv' : 'movie';
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api !== null && tmdb > 0) {
      try {
        const subs: SubscriptionView[] = await api.subscriptionsList(kind);
        for (const sub of subs) {
          if (sub.media.tmdb_id === tmdb) {
            this.navStack.pushPathByName('subscriptionDetail', new SubscriptionParams(sub.id, true));
            return;
          }
        }
      } catch (error) {
        // 拿不到订阅清单就退回「以洗版模式打开订阅对话框」
      }
    }
    SubscribeCenter.present(`tmdb:${kind}:${tmdb}`, detail.title, true);
  }

  @Builder
  ItemActionsMenu() {
    Menu() {
      MenuItem({ content: this.actionBusy ? '正在处理…' : '刷新元数据' })
        .onClick(() => {
          this.refreshMetadata();
        })
      MenuItem({ content: '重新识别' })
        .onClick(() => {
          this.reidentify();
        })
      if (this.detail !== null && this.detail.source === 'tmdb') {
        MenuItem({ content: '更换图片…' })
          .onClick(() => {
            this.showArtwork = true;
          })
      }
      MenuItem({ content: '转移到其他库…' })
        .onClick(() => {
          this.showTransfer = true;
        })
      // 洗版：已有订阅直接去订阅详情跑一轮；没有则以洗版模式打开订阅对话框（同 iOS `upgrade`）
      MenuItem({ content: '洗版' })
        .onClick(() => {
          this.upgrade();
        })
      MenuItem({ content: '删除条目' })
        .onClick(() => {
          this.confirmDelete();
        })
    }
  }

  /**
   * 刷新元数据：**只重拉 TMDB 的资料与图片，不动身份**（身份错了要用「重新识别」）。
   * 这个区分很重要——用户看到「海报旧了」该点刷新，看到「认成了别的片」该点重新识别；
   * 混在一起会让人用错工具然后以为功能坏了。
   */
  private async refreshMetadata(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null || this.actionBusy) {
      return;
    }
    this.actionBusy = true;
    try {
      await api.libraryItemsRefreshMetadata(this.libraryId, this.mediaItemId);
      this.toastText('已开始刷新，稍后下拉看看');
      await this.reload();
    } catch (error) {
      this.toastText(LibraryItemDetailPage.describe(error));
    } finally {
      this.actionBusy = false;
    }
  }

  /** 重新识别：身份认错了才用它；结果要**逐项报**（认出几个 / 没认出几个 / 换了条目） */
  private async reidentify(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null || this.actionBusy) {
      return;
    }
    this.actionBusy = true;
    try {
      const result: ReidentifyResultView =
        await api.libraryItemsReidentify(this.libraryId, this.mediaItemId);
      const rows: string[] = [result.message];
      rows.push(`认出 ${result.identified} 个 · 没认出 ${result.unidentified} 个`);
      if (result.skipped_missing > 0) {
        rows.push(`跳过 ${result.skipped_missing} 个（文件不在）`);
      }
      if (result.kept_on_error > 0) {
        rows.push(`出错但保留了原匹配 ${result.kept_on_error} 个`);
      }
      if (result.changed) {
        // 换了条目 = 用户现在看的这个页面已经不是同一部片了，必须明说
        rows.push(`已经换成「${result.new_title ?? '另一条'}」，返回后请重新打开`);
      }
      this.getUIContext().showAlertDialog({
        title: '重新识别',
        message: rows.join('\n'),
        primaryButton: {
          value: '知道了',
          action: (): void => {
          }
        }
      });
      await this.reload();
    } catch (error) {
      this.toastText(LibraryItemDetailPage.describe(error));
    } finally {
      this.actionBusy = false;
    }
  }

  private confirmDelete(): void {
    this.getUIContext().showAlertDialog({
      title: '删除条目',
      message: '把这条从媒体库里移除？\n\n'
        + '磁盘上的文件会进回收站（不是直接删除，之后还能恢复）。',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '删除',
        action: (): void => {
          this.deleteItem();
        }
      }
    });
  }

  private async deleteItem(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null || this.actionBusy) {
      return;
    }
    this.actionBusy = true;
    try {
      await api.libraryItemsDelete(this.libraryId, this.mediaItemId);
      this.toastText('已移除，文件在回收站里');
      this.navStack.pop();
    } catch (error) {
      this.toastText(LibraryItemDetailPage.describe(error));
    } finally {
      this.actionBusy = false;
    }
  }

  private toastText(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2500 });
  }

  private async openShare(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    this.showShare = true;
    this.shareBusy = true;
    try {
      this.share = await api.libraryItemsShareGet(this.libraryId, this.mediaItemId);
    } catch (error) {
      // 拿不到就当没建过，用户还能新建
      this.share = null;
    } finally {
      this.shareBusy = false;
    }
  }

  private async createShare(days: number, password: string): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    this.shareBusy = true;
    try {
      const payload: ShareCreateRequest = {
        expires_in_days: days > 0 ? days : null,
        password: password.length > 0 ? password : null
      };
      this.share = await api.libraryItemsShareCreate(this.libraryId, this.mediaItemId, payload);
      this.getUIContext().getPromptAction().showToast({ message: '链接已生成' });
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({ message: shareMessage(error) });
    } finally {
      this.shareBusy = false;
    }
  }

  private async revokeShare(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    this.shareBusy = true;
    try {
      await api.libraryItemsShareRevoke(this.libraryId, this.mediaItemId);
      this.share = null;
      this.getUIContext().getPromptAction().showToast({ message: '已停止分享' });
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({ message: shareMessage(error) });
    } finally {
      this.shareBusy = false;
    }
  }

  /** 分享面板的壳：标题 + 内容 */
  @Builder
  ShareSheetContent() {
    Column({ space: 12 }) {
      Text('分享')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .padding({ top: 16 })
      SharePanel({
        share: this.share,
        busy: this.shareBusy,
        onCreate: (days: number, password: string): void => {
          this.createShare(days, password);
        },
        onRevoke: (): void => {
          this.revokeShare();
        }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  /** 更换图片弹层：候选图网格（背景 / 海报两页签，点选即落盘并加锁） */
  @Builder
  ArtworkSheetContent() {
    ArtworkPickerSheet({
      libraryId: this.libraryId,
      mediaItemId: this.mediaItemId,
      onChanged: (): void => {
        this.reload();
      },
      onClose: (): void => {
        this.showArtwork = false;
      }
    })
  }

  /** 转移条目弹层：选目标库 → 只读预检 → 确认转移 → 轮询到结论页 */
  @Builder
  TransferSheetContent() {
    TransferItemSheet({
      libraryId: this.libraryId,
      mediaItemId: this.mediaItemId,
      title: this.detail !== null ? this.detail.title : '',
      onDone: (): void => {
        this.reload();
      },
      onClose: (): void => {
        this.showTransfer = false;
      }
    })
  }

  @Builder
  LoadingState() {    Column({ space: 10 }) {
      LoadingProgress()
        .width(24)
        .height(24)
        .color(Theme.textMuted)
      Text('正在读取本地刮削信息…')
        .fontSize(15)
        .fontColor(Theme.textMuted)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  FailedState() {
    Column({ space: 14 }) {
      Text('未能加载该条目')
        .fontSize(17)
        .fontWeight(600)
        .fontColor(Theme.text)
      Text('条目可能已被删除或重新识别为其他作品，请返回后查看。')
        .fontSize(15)
        .fontColor(Theme.textMuted)
        .textAlign(TextAlign.Center)
      Text('返回')
        .fontSize(15)
        .fontWeight(600)
        .fontColor(Theme.accentStrong)
        .padding({ left: 20, right: 20, top: 10, bottom: 10 })
        .backgroundColor(Theme.glassFill)
        .borderRadius(20)
        .border({ width: 1, color: Theme.lineStrong })
        .onClick(() => {
          this.navStack.pop();
        })
    }
    .width('100%')
    .height('100%')
    .padding(24)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  Content(detail: LibraryItemDetailView) {
    Refresh({ refreshing: $$this.refreshing }) {
      Scroll() {
        Column({ space: 0 }) {
          this.Hero()
          this.Header(detail)
          if (this.plotText().length > 0) {
            this.PlotBlock()
          }
          Column({ space: 24 }) {
            if (!this.isMovie() && detail.seasons.length > 0) {
              this.SeasonBlock(detail)
            }
            this.CastRow()
            this.FileSection()
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ top: 24, bottom: 48 })
          AppFooter()
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .height('100%')
      .edgeEffect(EdgeEffect.None)
      .padding({ bottom: Theme.tabBarInset })
    }
    .onRefreshing(() => {
      this.reload().then((): void => {
        this.refreshing = false;
      });
    })
    .width('100%')
    .height('100%')
  }

  /** 沉浸剧照：高度 = min(屏宽 × 1.15, 屏高 × 0.62)，底部渐变融进底色（同 iOS hero） */
  @Builder
  Hero() {
    // 与订阅轮播**共用同一份底图实现**（common/ImmersiveHero.ets），别再各写一遍
    ImmersiveHeroBackdrop(this.posterUrl(), this.heroHeight)
  }

  @Builder
  Header(detail: LibraryItemDetailView) {
    Column({ space: 8 }) {
      // 标题：有条目 Logo 就用 Logo（对应 iOS `titleArt`，最多 260×96、底线左对齐），没有才写字
      if (this.logoUrl(detail).length > 0) {
        /*
         * 片名 Logo 的尺寸。
         *
         * **不能用 `constraintSize` + `width('100%')`**：`constraintSize` 加在自定义组件上不生效，
         * `width('100%')` 又让它占满整列（≈298vp），配上默认的 Cover 就把透明底的片名 Logo
         * **拉伸裁切成一团白色涂抹**（实测就是这个问题，片名整个看不见）。
         * `fit: true`（Contain）保住 Logo 自身比例；尺寸按 iOS 的比例定
         * （iOS `maxWidth 260 / maxHeight 96` 占 393pt 屏宽的 66%；本机 330vp → 218vp）。
         */
        RemoteImage({ url: this.logoUrl(detail), fit: true })
          .width(218)
          .height(80)
      } else {
        Text(detail.title)
          .fontFamily('serif')
          .fontSize(28)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      // 剧集：当前集（对应 iOS「第 N 季 第 M 集 - 集名」）
      if (!this.isMovie() && this.episodeLine().length > 0) {
        Text(this.episodeLine())
          .fontSize(15)
          .fontColor(Theme.textMuted)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      // 事实行：年份 · 时长 · 评分 · 分辨率 · HDR（对应 iOS `factsLine`）
      if (this.factsLine(detail).length > 0) {
        Text(this.factsLine(detail))
          .fontSize(15)
          .fontColor(Theme.text)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      // 类型：纯文本用 · 连接（iOS 是文本，不是胶囊）
      if (this.genres().length > 0) {
        Text(this.genres().join(' · '))
          .fontSize(15)
          .fontColor(Theme.textMuted)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      if (this.seriesName(detail).length > 0) {
        this.MetaLinkRow('系列', this.seriesName(detail))
      }
      if (detail.collections.length > 0) {
        this.MetaLinkRow('合集', this.collectionsText(detail))
      }
      this.PlayAction(detail)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    // 盖到剧照下半部（iOS 用 -150，这里按剧照高度比例取，小屏也不会顶掉标题）
    .margin({ top: -(this.heroHeight * 0.34) })
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
  }

  /** 「系列 / 合集」这种 标签 + 值 的行（对应 iOS `metaLinkRow`，标签固定宽 34） */
  @Builder
  MetaLinkRow(label: string, value: string) {
    Row({ space: 14 }) {
      Text(label)
        .fontSize(13)
        .fontColor(Theme.textFaint)
        .width(34)
        .textAlign(TextAlign.Start)
      Text(value)
        .fontSize(15)
        .fontColor(Theme.text)
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  /**
   * 播放区（对应 iOS `playAction`）：
   * **播放键独占一行通栏**，下面一行才是「收藏 · 标为已看」两颗次键，
   * 再下面是续播进度条与「看过 N 次」。原来三颗挤一行是不对的。
   */
  @Builder
  PlayAction(detail: LibraryItemDetailView) {
    Column({ space: 12 }) {
      Button(this.playLabel())
        .width('100%')
        .height(46)
        .fontSize(16)
        .fontWeight(600)
        .fontColor('#0b0d12')
        .backgroundColor(Theme.accent)
        .borderRadius(14)
        .onClick(() => {
          this.onPlay();
        })

      Row({ space: 10 }) {
        Button(this.favorite === true ? '已收藏' : '收藏')
          .height(42)
          .fontSize(14)
          .fontColor(this.favorite === true ? Theme.danger : Theme.text)
          .backgroundColor(Theme.surfaceRaised)
          .borderRadius(12)
          .border({ width: 1, color: Theme.line })
          .enabled(!this.marking)
          .onClick(() => {
            this.toggleFavorite();
          })
        Button(this.watchedLabel())
          .height(42)
          .fontSize(14)
          .fontColor(this.played() ? Theme.ok : Theme.text)
          .backgroundColor(Theme.surfaceRaised)
          .borderRadius(12)
          .border({ width: 1, color: Theme.line })
          .enabled(!this.marking)
          .onClick(() => {
            this.toggleWatched();
          })
      }
      .width('100%')

      // 续播进度条 + 「剩余 X 分钟」（对应 iOS item-progress）
      if (this.resumeText().length > 0) {
        Column({ space: 6 }) {
          Row() {
            Row()
              .width(`${this.resumePercent()}%`)
              .height(4)
              .backgroundColor(Theme.text)
          }
          .width('100%')
          .height(4)
          .backgroundColor('rgba(255,255,255,0.15)')
          .borderRadius(2)
          .justifyContent(FlexAlign.Start)
          Text(this.resumeText())
            .fontSize(12)
            .fontColor(Theme.textMuted)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      if (this.played() && this.playCount() > 1) {
        Text(`看过 ${this.playCount()} 次`)
          .fontSize(12)
          .fontColor(Theme.textFaint)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 10 })
  }

  private played(): boolean {
    const state: PlaybackStateView | null = this.watched;
    return state !== null && state.played;
  }

  private playCount(): number {
    const state: PlaybackStateView | null = this.watched;
    return state === null ? 0 : (state.play_count ?? 0);
  }

  /** 续播百分比（iOS：2% 起，避免看不到） */
  private resumePercent(): number {
    const state: PlaybackStateView | null = this.watched;
    if (state === null || state.played) {
      return 0;
    }
    const position: number = state.position_ms ?? 0;
    const duration: number = state.duration_ms ?? 0;
    if (position <= 0 || duration <= 0) {
      return 0;
    }
    return Math.min(100, Math.max(2, Math.round(position * 100 / duration)));
  }

  /** 进度文字：只说还剩多少（iOS：剩余 X 分钟 / 即将看完） */
  private resumeText(): string {
    const state: PlaybackStateView | null = this.watched;
    if (state === null || state.played) {
      return '';
    }
    const position: number = state.position_ms ?? 0;
    const duration: number = state.duration_ms ?? 0;
    if (position <= 0 || duration <= 0 || duration <= position) {
      return '';
    }
    const minutes: number = Math.round((duration - position) / 60000);
    return minutes >= 1 ? `剩余 ${minutes} 分钟` : '即将看完';
  }

  /** 播放键文案：有进度就是「继续观看 mm:ss」，看完或没看过就是「播放」（同 iOS） */
  private playLabel(): string {
    const state: PlaybackStateView | null = this.watched;
    if (state === null || state.played) {
      return '播放';
    }
    const position: number = state.position_ms ?? 0;
    if (position <= 0) {
      return '播放';
    }
    return `继续观看 ${this.clock(position)}`;
  }

  /** 与 iOS 一致：「标为已看」/「已看完」 */
  private watchedLabel(): string {
    return this.played() ? '已看完' : '标为已看';
  }

  private clock(ms: number): string {
    const total: number = Math.floor(ms / 1000);
    const h: number = Math.floor(total / 3600);
    const m: number = Math.floor((total % 3600) / 60);
    const s: number = total % 60;
    return h > 0 ? `${h}:${this.pad(m)}:${this.pad(s)}` : `${m}:${this.pad(s)}`;
  }

  private pad(value: number): string {
    return value < 10 ? `0${value}` : `${value}`;
  }

  /** 简介：4 行折叠，点一下展开/收起（同 iOS ExpandablePlot 的用法） */
  @Builder
  PlotBlock() {
    Column({ space: 6 }) {
      Text(this.plotText())
        .fontSize(15)
        .fontColor(Theme.textMuted)
        .lineHeight(23)
        .maxLines(this.plotExpanded ? 100 : 4)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.plotExpanded ? '收起' : '展开')
        .fontSize(13)
        .fontColor(Theme.textFaint)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 16 })
    .onClick(() => {
      this.plotExpanded = !this.plotExpanded;
    })
  }

  /** 剧集：季切换 + 本季集列表 */
  @Builder
  SeasonBlock(detail: LibraryItemDetailView) {
    Column({ space: 12 }) {
      Text('剧集')
        .fontSize(17)
        .fontWeight(600)
        .fontColor(Theme.text)
      Scroll() {
        Row({ space: 8 }) {
          ForEach(detail.seasons, (season: number) => {
            Text(`第 ${season} 季`)
              .fontSize(14)
              .fontColor(season === this.season ? '#0b0d12' : Theme.text)
              .padding({ left: 14, right: 14, top: 8, bottom: 8 })
              .backgroundColor(season === this.season ? Theme.accent : Theme.glassFill)
              .borderRadius(16)
              .onClick(() => {
                this.onSeasonPick(season);
              })
          }, (season: number) => `${season}`)
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')

      if (this.episodesFailed) {
        Row({ space: 10 }) {
          Text('剧集列表加载失败')
            .fontSize(14)
            .fontColor(Theme.textMuted)
          Text('重试')
            .fontSize(14)
            .fontWeight(600)
            .fontColor(Theme.accentStrong)
            .onClick(() => {
              this.episodesFailed = false;
              this.loadEpisodes();
            })
        }
      } else if (this.episodes === null) {
        LoadingProgress()
          .width(18)
          .height(18)
          .color(Theme.textFaint)
      } else {
        Column({ space: 2 }) {
          ForEach(this.episodes.episodes, (episode: EpisodeView) => {
            this.EpisodeRow(episode)
          }, (episode: EpisodeView) => `${episode.episode_number}`)
        }
        .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
  }

  @Builder
  EpisodeRow(episode: EpisodeView) {
    Row({ space: 12 }) {
      Text(`${episode.episode_number}`)
        .fontSize(15)
        .fontWeight(600)
        .fontColor(this.isPicked(episode) ? Theme.accentStrong : Theme.textFaint)
        .width(28)
      Column({ space: 3 }) {
        Text(episode.name !== null && episode.name !== undefined && episode.name.length > 0
          ? episode.name : `第 ${episode.episode_number} 集`)
          .fontSize(15)
          .fontColor(episode.owned ? Theme.text : Theme.textFaint)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (!episode.owned) {
          Text('未入库')
            .fontSize(12)
            .fontColor(Theme.textFaint)
        } else if (episode.played) {
          Text('已看')
            .fontSize(12)
            .fontColor(Theme.ok)
        } else if ((episode.progress_percent ?? 0) > 0) {
          Text(`已看 ${Math.round(episode.progress_percent ?? 0)}%`)
            .fontSize(12)
            .fontColor(Theme.textFaint)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 10, bottom: 10 })
    .backgroundColor(this.isPicked(episode) ? Theme.glassFillHover : Color.Transparent)
    .borderRadius(10)
    .onClick(() => {
      this.onEpisodePick(episode);
    })
  }

  private isPicked(episode: EpisodeView): boolean {
    const picked: EpisodeView | null = this.selectedEpisode;
    return picked !== null && picked.episode_number === episode.episode_number;
  }

  /**
   * 演职员：横向一行竖卡（对应 iOS `castCard`）——
   * 2:3 圆角卡片里垫名字首字母、上面叠头像，下面名字与「导演 / 饰 角色」。
   */
  @Builder
  CastRow() {
    if (this.castPeople().length > 0) {
      Column({ space: 12 }) {
        Text('演职员')
          .fontSize(17)
          .fontWeight(600)
          .fontColor(Theme.text)
        Scroll() {
          Row({ space: 12 }) {
            ForEach(this.castPeople(), (person: CastPerson) => {
              Column({ space: 2 }) {
                Stack({ alignContent: Alignment.Center }) {
                  // 占位底色 + 首字母：头像没到位时先顶上（同 iOS 的 ZStack）
                  Column()
                    .width('100%')
                    .height('100%')
                    .backgroundColor(Theme.surfaceRaised)
                  Text(Permissions.initialsOf(person.name))
                    .fontSize(24)
                    .fontWeight(FontWeight.Bold)
                    .fontColor('rgba(255,255,255,0.3)')
                  if (person.avatar.length > 0) {
                    RemoteImage({
                      url: person.avatar,
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

                Text(person.name)
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Theme.text)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .margin({ top: 6 })
                if (person.subtitle !== null) {
                  Text(person.subtitle as string)
                    .fontSize(11)
                    .fontColor(Theme.textFaint)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
              }
              .width(96)
              .alignItems(HorizontalAlign.Start)
              .onClick(() => {
                // 有 TMDB 影人 ID 才可点，进库内影人页（同 iOS NavigationLink(.person)）
                const id: number | null = person.personId;
                if (id !== null && id > 0) {
                  this.navStack.pushPathByName('person', new PersonParams(id));
                }
              })
            }, (person: CastPerson) => person.key())
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
  }

  @Builder
  FileSection() {
    if (this.currentFiles().length > 0) {
      Column({ space: 10 }) {
        Text(this.isMovie() ? '文件' : `第 ${this.season} 季 · 当前集文件`)
          .fontSize(17)
          .fontWeight(600)
          .fontColor(Theme.text)
        ForEach(this.currentFiles(), (file: LibraryFileView) => {
          this.FileRow(file)
        }, (file: LibraryFileView) => `${file.id}`)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
    }
  }

  @Builder
  FileRow(file: LibraryFileView) {
    Column({ space: 4 }) {
      Text(file.file_name)
        .fontSize(14)
        .fontColor(file.missing ? Theme.warn : Theme.text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.fileSpec(file))
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor(Theme.glassFill)
    .borderRadius(10)
  }

  /** 一行规格：分辨率 · 编码 · HDR · 体积（缺失的文件标出来） */
  private fileSpec(file: LibraryFileView): string {
    const parts: string[] = [];
    if (file.missing) {
      parts.push('文件缺失');
    }
    const resolution: string | null = file.resolution ?? null;
    if (resolution !== null && resolution.length > 0) {
      parts.push(resolution);
    }
    const codec: string | null = file.video_codec ?? null;
    if (codec !== null && codec.length > 0) {
      parts.push(codec.toUpperCase());
    }
    const hdr: string | null = file.hdr ?? null;
    if (hdr !== null && hdr.length > 0) {
      parts.push(hdr);
    }
    parts.push(libraryBytes(file.size_bytes));
    return parts.join('  ·  ');
  }
}
