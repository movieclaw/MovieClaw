import { display } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { Theme } from '../theme/AppTheme';
import { WindowInsets } from '../common/WindowInsets';
import { Formatters } from '../common/Formatters';
import { SharePanel, shareMessage } from './ShareSheet';
import { ArtworkPickerSheet } from './ArtworkPickerSheet';
import { TransferItemSheet } from './TransferItemSheet';
import { DeleteItemSheet, DeleteFileSheet } from './DeleteItemSheet';
import { MediaTrackSection } from './MediaTrackSection';
import { ReidentifySheet } from './ReidentifySheet';
import { Permissions } from '../common/Permissions';
import { DirectorView, ShareCreateRequest, ShareView } from '../api/Models';
import { PlayerParams } from '../player/PlayerPage';
import { AppModel } from '../common/AppModel';
import { RemoteImage } from '../common/RemoteImage';
import { ImmersiveHeroBackdrop } from '../common/ImmersiveHero';
import { ImageUrls, ImageVariant } from '../common/ImageUrls';
import { AppFooter } from '../common/AppFooter';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import {
  ChapterView,
  CollectionSeriesView,
  EpisodeView,
  FileOriginView,
  LibraryFileView,
  LibraryItemDetailView,
  LibraryItemView,
  PlaybackMarksRequest,
  PlaybackStateView,
  SeasonEpisodesView,
  SeriesPartView,
  LibraryView,
  SubscriptionView
} from '../api/Models';
import { libraryBytes } from './LibraryShared';
import {
  EpisodeRange,
  EpisodeRanges,
  anchorEpisode,
  watchedAnyEpisode
} from './EpisodeRanges';
import { PersonParams } from '../discover/PersonDetailPage';
import { DiscoverDetailParams } from '../discover/DiscoverDetailPage';
import { SubscribeCenter } from '../subscriptions/SubscribeCenter';
import { SubscriptionParams } from '../subscriptions/SubscriptionDetailPage';
import { OfflineStore } from '../offline/OfflineStore';
import { OfflineProgress, OfflineUnit } from '../offline/OfflineModels';
import {
  OfflineDownloadChoices,
  OfflineDownloadControl,
  OfflineEpisodeChoice,
  OfflineEpisodeDownloadMark,
  OfflineItemDownloadButton,
  OfflineProfileSheet
} from '../offline/OfflineUi';

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
 * 本轮暂缓（对应 iOS 的暂缓项）：章节缩略条、相关链接、
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
  /** 在线请求失败回落了本机副本：只读模式（对应 iOS `localOnly`）。下载/管理/分享入口隐藏，进度取本机 */
  @State private localOnly: boolean = false;
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
  /** 分段时正在显示的段（`EpisodeRange.index`）；不分段时无意义 */
  @State private episodeRangeIndex: number | null = null;
  /** 「全部分集」宫格面板（一季超过 50 集才有入口） */
  @State private showAllEpisodes: boolean = false;

  /** 下载面板：电影传选中的文件号，剧集传 -1（面板自己拉整季集表算范围） */
  @State private showDownloadSheet: boolean = false;
  @State private downloadFileId: number = -1;

  @State private plotExpanded: boolean = false;

  /** 删除条目后果单（iOS DeleteItemSheet）：打开后弹层自己拉详情与预览 */
  @State private showDeleteItem: boolean = false;
  /** 删除单文件后果单（iOS DeleteFileSheet）：先记目标再开 */
  @State private showDeleteFile: boolean = false;
  private deleteFileTarget: LibraryFileView | null = null;
  /** 文件行展开态（一次只展开一行；iOS LibraryFileRow.expanded） */
  @State private expandedFileId: number = -1;
  /** 相似推荐（库内）与电影的作品系列：详情到手后拉一次（iOS ItemRelated） */
  @State private similarItems: LibraryItemView[] = [];
  @State private seriesRow: CollectionSeriesView | null = null;
  /** 重新识别：两阶段修正面板（iOS ReidentifySheet） */
  @State private showReidentify: boolean = false;

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

  /** 在位文件（轨道区只认 state == "in_place"，同 iOS availableFiles） */
  private inPlaceFiles(): LibraryFileView[] {
    const out: LibraryFileView[] = [];
    for (const file of this.currentFiles()) {
      if (file.state === 'in_place') {
        out.push(file);
      }
    }
    return out;
  }

  /** 当前播放单元的季（电影是 0，剧集是选中的那一季） */
  private playUnitSeasonNumber(): number {
    return !this.isMovie() && this.selectedEpisode !== null ? this.season : 0;
  }
  /** 当前播放单元的集（电影是 0，剧集是选中的那一集） */
  private playUnitEpisodeNumber(): number {
    const picked: EpisodeView | null = this.selectedEpisode;
    return !this.isMovie() && picked !== null ? picked.episode_number : 0;
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
    // 冷启动直达详情时本机目录可能还没读完：先等它，不然请求失败回落时会把「有副本」判成「没有」（同 iOS）
    await OfflineStore.shared.waitUntilLoaded();
    const libraryId: number = this.libraryId;
    const mediaItemId: number = this.mediaItemId;
    // 请求失败时的回落对象：本机存的详情（没下载过就是 null）
    const local: LibraryItemDetailView | null =
      OfflineStore.shared.downloadedItemIds.has(mediaItemId)
        ? OfflineStore.shared.detail(mediaItemId) : null;
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
      this.localOnly = false;
      this.pickInitialEpisode(detail);
      this.loadEpisodes();
      this.loadResume();
      this.loadRelated();
    } catch (error) {
      if (local !== null) {
        // 连不上服务器 / 服务器返回 404 但本机还有副本：停在本机数据上，
        // 只显示本机有的文件与季（只读，同 iOS reload 的 catch 分支）
        this.detail = OfflineStore.shared.offlineDetail(local);
        if (this.library === null) {
          this.library = OfflineStore.shared.library(mediaItemId);
        }
        this.localOnly = true;
        this.failed = false;
        this.pickInitialEpisode(this.detail as LibraryItemDetailView);
        this.loadEpisodes();
        this.loadResume();
        return;
      }
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

  // MARK: 相似推荐 + 作品系列（iOS ItemRelated；顺序 演职员 → 相似 → 系列，2026-10-12 用户定）

  /**
   * 两行的取数规则（同 iOS ItemRelated.load）：电影有系列合集时相似推荐先排除同系列的片
   * （系列那一行已经按上映顺序列全了），系列行拉不出来再拉一次不排除的；系列一行只在
   * 拉得到上游档案（available）且不止一部时才出（本地 NFO 定的系列没有上游档案）。
   */
  private async loadRelated(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    const detail: LibraryItemDetailView | null = this.detail;
    if (api === null || detail === null || this.localOnly) {
      return;
    }
    const seriesId: number | null = detail.kind !== 'tv' ? (detail.series_collection_id ?? null) : null;
    let series: CollectionSeriesView | null = null;
    if (seriesId !== null) {
      try {
        const fresh: CollectionSeriesView = await api.collectionSeriesGet(seriesId);
        if (fresh.available && fresh.parts.length > 1) {
          series = fresh;
        }
      } catch (error) {
        // 拉不到就不出系列行
      }
    }
    let items: LibraryItemView[] = [];
    try {
      items = await api.uiLibraryItemsSimilar(this.libraryId, this.mediaItemId, undefined,
        seriesId !== null ? true : undefined);
    } catch (error) {
      // 没有相似的片、接口失败：整行不出
    }
    if (seriesId !== null && series === null) {
      // 系列行最后没出来：再拉一次不排除的，否则续集哪儿都看不到
      try {
        items = await api.uiLibraryItemsSimilar(this.libraryId, this.mediaItemId, undefined, false);
      } catch (error) {
        // 保持第一轮的结果
      }
    }
    this.seriesRow = series;
    this.similarItems = items;
  }

  // MARK: 章节（iOS ChapterStripSection；素材搬自 ShareItemView 的 ChaptersBlock）

  /** 当前单元带章节的文件（取第一个有章节的；电影多版本就是选中的第一份） */
  private chapterSourceFile(): LibraryFileView | null {
    const files: LibraryFileView[] = this.currentFiles();
    for (const file of files) {
      const chapters: ChapterView[] | null | undefined = file.chapters;
      if (chapters !== null && chapters !== undefined && chapters.length > 0) {
        return file;
      }
    }
    return null;
  }

  private chapters(): ChapterView[] {
    const file: LibraryFileView | null = this.chapterSourceFile();
    if (file === null) {
      return [];
    }
    return (file.chapters as ChapterView[]);
  }

  /** 章节标题（可能为 null：合成章节与无名章节） */
  private chapterTitle(chapter: ChapterView): string {
    return chapter.title ?? '';
  }

  /** 章节的起播毫秒：帧图位置优先，没有退章节起点（同 iOS ChapterCard.startMs） */
  private chapterStart(chapter: ChapterView): number {
    const frame: number | null = chapter.frame_ms ?? null;
    return frame !== null ? frame : chapter.start_ms;
  }

  /** 续播位置落在哪一章（start ≤ pos < end，末章无 end 视为到片尾） */
  private resumeMs(): number {
    const state: PlaybackStateView | null = this.watched;
    return state !== null && !state.played ? (state.position_ms ?? 0) : 0;
  }

  private isResumeChapter(chapter: ChapterView): boolean {
    const resume: number = this.resumeMs();
    if (resume <= 0) {
      return false;
    }
    const end: number | null = chapter.end_ms ?? null;
    return resume >= chapter.start_ms && (end === null || resume < end);
  }

  /** 从这一章起播：带上当前的季/集（同 play，只是续播位置换成章起点） */
  private playFromChapter(chapter: ChapterView): void {
    const picked: EpisodeView | null = this.selectedEpisode;
    const season: number = !this.isMovie() && picked !== null ? this.season : 0;
    const episode: number = !this.isMovie() && picked !== null ? picked.episode_number : 0;
    this.navStack.pushPathByName('player',
      new PlayerParams(this.mediaItemId, 0, season, episode, this.chapterStart(chapter)));
  }

  private chapterUrl(chapter: ChapterView): string {
    const resolved: string | null =
      ImageUrls.resolve(AppModel.origin(), chapter.image_url ?? null, null);
    return resolved !== null ? resolved : '';
  }

  private chapterClock(ms: number): string {
    const total: number = Math.max(0, Math.floor(ms / 1000));
    const h: number = Math.floor(total / 3600);
    const m: number = Math.floor((total % 3600) / 60);
    const s: number = total % 60;
    return h > 0 ? `${h}:${Formatters.pad2(m)}:${Formatters.pad2(s)}` : `${m}:${Formatters.pad2(s)}`;
  }

  // MARK: 文件行（iOS LibraryFileRow：可展开、待回收态、删除/恢复/清理）

  private toggleFile(fileId: number): void {
    this.expandedFileId = this.expandedFileId === fileId ? -1 : fileId;
  }

  private openDeleteFile(file: LibraryFileView): void {
    this.deleteFileTarget = file;
    this.showDeleteFile = true;
  }

  /** 把待回收的文件恢复为在位版本 */
  private async restoreFile(file: LibraryFileView): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null || this.actionBusy) {
      return;
    }
    this.actionBusy = true;
    try {
      await api.libraryItemsRestoreFile(this.libraryId, this.mediaItemId, file.id);
      this.toastText('已恢复');
      await this.reload();
    } catch (error) {
      this.toastText(LibraryItemDetailPage.describe(error));
    } finally {
      this.actionBusy = false;
    }
  }

  /** 立即清理一个待回收的文件（真删磁盘，同 iOS onPurge 直接执行） */
  private async purgeFile(file: LibraryFileView): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null || this.actionBusy) {
      return;
    }
    this.actionBusy = true;
    try {
      await api.libraryItemsPurgeFile(this.libraryId, this.mediaItemId, file.id);
      this.toastText('已清理');
      await this.reload();
    } catch (error) {
      this.toastText(LibraryItemDetailPage.describe(error));
    } finally {
      this.actionBusy = false;
    }
  }

  /** 待回收倒计时（同 iOS purgeCountdown）：预计 N 天 N 小时后自动清理 / 不自动清理 */
  private purgeCountdown(raw: string | null): string {
    if (raw === null || raw.length === 0) {
      return '不自动清理';
    }
    const dateMs: number | null = Formatters.date(raw);
    if (dateMs === null) {
      return '即将自动清理';
    }
    const delta: number = dateMs - Date.now();
    if (delta <= 0) {
      return '即将自动清理';
    }
    const days: number = Math.floor(delta / 86400000);
    const hours: number = Math.floor((delta % 86400000) / 3600000);
    if (days > 0) {
      return `预计 ${days} 天 ${hours} 小时后自动清理`;
    }
    if (hours > 0) {
      return `预计 ${hours} 小时后自动清理`;
    }
    return '预计 1 小时内自动清理';
  }

  /** 文件所在的目录（同 iOS LibraryFileRow.directory：去掉文件名） */
  private fileDirectory(path: string): string {
    let normalized: string = path;
    while (normalized.endsWith('/') || normalized.endsWith('\\')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    const slash: number = Math.max(normalized.lastIndexOf('/'), normalized.lastIndexOf('\\'));
    if (slash < 0) {
      return '—';
    }
    if (slash === 0) {
      return normalized.substring(0, 1);
    }
    return normalized.substring(0, slash);
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
    // 刷新前这一季的锚点：刷新后锚点变了要跟着选中新锚点，没变不动（保留用户在别的段的浏览）
    const previousAnchor: number | null = this.currentAnchorNumber();
    // 请求失败时的回落对象：本机存的这一季（没下载过就是 null）
    const local: SeasonEpisodesView | null =
      OfflineStore.shared.downloadedItemIds.has(mediaItemId)
        ? OfflineStore.shared.season(mediaItemId, season) : null;
    try {
      const view: SeasonEpisodesView = await api.libraryItemsListEpisodes(libraryId, mediaItemId, season);
      // 拉的过程中换了季就丢弃
      if (season !== this.season) {
        return;
      }
      this.episodes = view;
      this.episodesFailed = false;
      this.pickEpisode(view, previousAnchor);
    } catch (error) {
      // 拉的过程中换了季就丢弃
      if (season !== this.season) {
        return;
      }
      if (local !== null) {
        // 回落本机存档：只显示本机有的集、进度取本机（同 iOS 的 OfflineFallback）
        this.episodes = OfflineStore.shared.offlineSeason(local, mediaItemId);
        this.episodesFailed = false;
        this.pickEpisode(this.episodes as SeasonEpisodesView, previousAnchor);
        return;
      }
      this.episodes = null;
      this.episodesFailed = true;
    }
  }

  /**
   * 选中集：优先路由指定的那一集；否则落在本季的锚点（服务端给的接着看的那一集，
   * 没给退回客户端规则）。刷新后锚点变了就选中新锚点、段跟过去；没变不动。
   */
  private pickEpisode(view: SeasonEpisodesView, previousAnchor: number | null): void {
    const list: EpisodeView[] = view.episodes;
    if (list.length === 0) {
      this.selectedEpisode = null;
      this.episodeRangeIndex = null;
      return;
    }
    const wanted: number | null = this.initialEpisode;
    if (wanted !== null) {
      for (const episode of list) {
        if (episode.episode_number === wanted) {
          this.lockEpisode(episode);
          return;
        }
      }
    }
    const anchor: EpisodeView | null = anchorEpisode(view);
    if (this.selectedEpisode === null) {
      this.lockEpisode(anchor);
      return;
    }
    // 播放回来锚点变了（看完 1050 → 1051）：选中新锚点、段跟过去
    const anchorNumber: number = anchor === null ? 0 : anchor.episode_number;
    if (anchor !== null && anchorNumber !== (previousAnchor ?? 0)) {
      this.lockEpisode(anchor);
    }
  }

  /** 选中一集并把段锁到它所在的段（对齐 iOS `lock`） */
  private lockEpisode(episode: EpisodeView | null): void {
    this.selectedEpisode = episode;
    this.episodeRangeIndex = episode === null ? null : EpisodeRanges.indexOf(episode.episode_number);
  }

  /** 本季的段：不分段时为空 */
  private episodeRanges(): EpisodeRange[] {
    const view: SeasonEpisodesView | null = this.episodes;
    return view === null ? [] : EpisodeRanges.ranges(view.episodes);
  }

  /** 本季锚点集号（服务端锚点优先，退回客户端规则；-1 = 没有） */
  private currentAnchorNumber(): number {
    const view: SeasonEpisodesView | null = this.episodes;
    if (view === null) {
      return -1;
    }
    const anchor: EpisodeView | null = anchorEpisode(view);
    return anchor === null ? -1 : anchor.episode_number;
  }

  /** 当前段：状态里的段找得到用它，找不到退回第一段 */
  private currentRange(): EpisodeRange | null {
    const ranges: EpisodeRange[] = this.episodeRanges();
    const index: number | null = this.episodeRangeIndex;
    for (const range of ranges) {
      if (range.index === index) {
        return range;
      }
    }
    return ranges.length > 0 ? ranges[0] : null;
  }

  /** 本季要显示的集：分段时只放当前段的（对齐 iOS 横排只放当前段的集） */
  private shownEpisodes(): EpisodeView[] {
    const view: SeasonEpisodesView | null = this.episodes;
    if (view === null) {
      return [];
    }
    const range: EpisodeRange | null = this.currentRange();
    if (range === null) {
      return view.episodes;
    }
    const out: EpisodeView[] = [];
    for (const episode of view.episodes) {
      if (range.contains(episode.episode_number)) {
        out.push(episode);
      }
    }
    return out;
  }

  /** 本季在库的集数（「在库 X / Y 集」） */
  private ownedEpisodeCount(): number {
    const view: SeasonEpisodesView | null = this.episodes;
    if (view === null) {
      return 0;
    }
    let count: number = 0;
    for (const episode of view.episodes) {
      if (episode.owned) {
        count += 1;
      }
    }
    return count;
  }

  /** 这张集卡要不要标「接着看」：本季有观看记录且它是锚点（短季同样标，对齐 iOS） */
  private isResumeEpisode(episode: EpisodeView): boolean {
    const view: SeasonEpisodesView | null = this.episodes;
    if (view === null || !watchedAnyEpisode(view)) {
      return false;
    }
    return episode.episode_number === this.currentAnchorNumber();
  }

  /** 手动换段：段里有锚点选锚点，否则段首（对齐 iOS `switchRange`） */
  private switchRange(target: EpisodeRange): void {
    const view: SeasonEpisodesView | null = this.episodes;
    if (view === null) {
      return;
    }
    const number: number = EpisodeRanges.entry(target, this.currentAnchorNumber() >= 0
      ? this.currentAnchorNumber() : null);
    for (const episode of view.episodes) {
      if (episode.episode_number === number) {
        this.lockEpisode(episode);
        return;
      }
    }
  }

  /** 宫格里点了一集：关面板、选中那一集、段跟过去 */
  private pickFromGrid(episodeNumber: number): void {
    const view: SeasonEpisodesView | null = this.episodes;
    if (view === null) {
      return;
    }
    this.showAllEpisodes = false;
    for (const episode of view.episodes) {
      if (episode.episode_number === episodeNumber) {
        this.lockEpisode(episode);
        return;
      }
    }
  }

  /** 本机进度 → 播放键要的观看状态（同 iOS `localWatched`） */
  private localWatched(season: number, episode: number): PlaybackStateView | null {
    const local: OfflineProgress | null =
      OfflineStore.shared.localProgress(this.mediaItemId, season, episode);
    if (local === null) {
      return null;
    }
    const view: PlaybackStateView = {
      position_ms: local.positionMs,
      played: local.played,
      play_count: local.played ? 1 : 0,
      duration_ms: local.durationMs,
      audio_track: null,
      subtitle_track: null,
      ended_by_admin: false
    };
    return view;
  }

  /**
   * 当前单元的观看进度（播放键文案用）。只读模式 / 服务器要不到时取本机进度
   * （同 iOS `loadResume`：先服务器，拿不到回落 `localWatched`）。
   */
  private async loadResume(): Promise<void> {
    const season: number = this.playUnitSeasonNumber();
    const episode: number = this.playUnitEpisodeNumber();
    if (this.localOnly) {
      this.watched = this.localWatched(season, episode);
      return;
    }
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    try {
      this.watched = await api.playbackResume(this.mediaItemId, season, episode);
    } catch (error) {
      this.watched = this.localWatched(season, episode);
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
      const body: PlaybackMarksRequest = {
        media_item_id: this.mediaItemId,
        season_number: this.playUnitSeasonNumber(),
        episode_number: this.playUnitEpisodeNumber(),
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
    this.episodeRangeIndex = null;
    this.loadEpisodes();
  }

  /** 选集：换简介、换文件区、换播放键的进度；段跟到它所在的段 */
  private onEpisodePick(episode: EpisodeView): void {
    this.lockEpisode(episode);
    this.loadResume();
  }

  /** 播放：带上续播位置（服务端会按能力判定档位，需要转码时直接回 HLS 地址） */
  private onPlay(): void {
    const state: PlaybackStateView | null = this.watched;
    const resume: number = state !== null && !state.played ? (state.position_ms ?? 0) : 0;
    // 电影：季集传 0；剧集：带上选中的那一集（同 iOS play）——
    // 服务端按它开会话，播放器也靠它找本机副本、拉本季分集
    const picked: EpisodeView | null = this.selectedEpisode;
    const season: number = !this.isMovie() && picked !== null ? this.season : 0;
    const episode: number = !this.isMovie() && picked !== null ? picked.episode_number : 0;
    this.navStack.pushPathByName('player', new PlayerParams(this.mediaItemId, 0, season, episode, resume));
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
      // 只读模式（回落本机副本）收掉下载/管理/分享：全要走服务器，离线点了也只会失败（同 iOS readOnly 收 ⋯ 菜单）
      if (!this.localOnly) {
        // 下载入口（对应 iOS ⋯ 菜单里的「下载」组）：电影直接选画质，剧集选范围
        OfflineItemDownloadButton({
          mediaItemId: this.mediaItemId,
          isMovie: this.isMovie(),
          fileIds: this.downloadableFileIds(),
          selectedSeason: this.isMovie() ? -1 : this.season,
          selectedEpisode: this.selectedEpisode === null ? -1 : (this.selectedEpisode as EpisodeView).episode_number,
          canDownload: Permissions.fromSession(AppModel.shared.session).canDownloadVideo,
          onOpenMovie: (): void => {
            this.openMovieDownload();
          },
          onOpenSeries: (): void => {
            this.openSeriesDownload();
          }
        })
          .margin({ right: 8 })
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

  // MARK: 离线下载

  /** 电影当前可下载的文件（选中的版本在前，供顶栏按钮判断要不要出现） */
  private downloadableFileIds(): number[] {
    const out: number[] = [];
    const files: LibraryFileView[] = this.currentFiles();
    for (const file of files) {
      out.push(file.id);
    }
    return out;
  }

  /** 打开电影的下载画质面板：选中的版本在前 */
  private openMovieDownload(): void {
    const files: LibraryFileView[] = this.currentFiles();
    this.downloadFileId = files.length > 0 ? files[0].id : -1;
    this.showDownloadSheet = true;
  }

  /** 打开剧集的下载范围面板（面板自己拉整季集表） */
  private openSeriesDownload(): void {
    this.downloadFileId = -1;
    this.showDownloadSheet = true;
  }

  /** 下载面板标题 */
  private downloadSheetTitle(): string {
    const detail: LibraryItemDetailView | null = this.detail;
    return detail !== null ? detail.title : '';
  }

  /** 选中的集要传给范围算法的文件号：选中版本的文件优先，退回这一集在库的任一文件 */
  private selectedDownloadFile(): number | null {
    const files: LibraryFileView[] = this.currentFiles();
    if (files.length > 0) {
      return files[0].id;
    }
    const picked: EpisodeView | null = this.selectedEpisode;
    if (picked !== null && picked.file_ids.length > 0) {
      return picked.file_ids[0];
    }
    return null;
  }

  /**
   * 剧集下载范围面板的整张集表（对应 iOS `OfflineEpisodeSelection.load`）：
   * 逐季拉集列表，只收在库的；`local` 标记交给范围算法排除本机已有的。
   */
  private async buildSeriesChoices(): Promise<OfflineDownloadChoices> {
    const api: MovieClawApi | null = AppModel.shared.api;
    const detail: LibraryItemDetailView | null = this.detail;
    if (api === null || detail === null) {
      return new OfflineDownloadChoices([], null);
    }
    const multiSeason: boolean = detail.seasons.length > 1;
    const seasons: number[] = detail.seasons.length > 0 ? detail.seasons : [this.season];
    const selected: OfflineEpisodeChoice[] = [];
    for (const season of seasons) {
      let view: SeasonEpisodesView;
      try {
        view = await api.libraryItemsListEpisodes(this.libraryId, this.mediaItemId, season);
      } catch (error) {
        // 这一季拉不到就跳过，别的季照常
        continue;
      }
      for (const episode of view.episodes) {
        if (!episode.owned) {
          continue;
        }
        const ids: number[] = episode.file_ids;
        const file: number | null = ids.length > 0 ? ids[0] : null;
        const unit: OfflineUnit | null =
          OfflineStore.shared.unitOf(this.mediaItemId, season, episode.episode_number);
        let local: string | null = null;
        if (unit !== null) {
          local = unit.playable ? 'done' : 'active';
        }
        selected.push(new OfflineEpisodeChoice(season, episode.episode_number, file, episode.played, local));
      }
    }
    const picked: EpisodeView | null = this.selectedEpisode;
    return OfflineDownloadChoices.make(selected, this.season,
      picked !== null ? picked.episode_number : null,
      this.selectedDownloadFile(), multiSeason);
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
      MenuItem({ content: '重新识别…' })
        .onClick(() => {
          this.showReidentify = true;
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
  /**
   * 「重新识别」走两阶段修正面板（iOS ReidentifySheet）：先重走识别链出只读预览，
   * 人按组拍板（采纳/自己搜/标为非独立作品）才落库。旧的一步落库版会把机器
   * 高置信的错挂原样重演一遍，已废弃。
   */

  /**
   * 「删除条目」走后果单（iOS DeleteItemSheet）：全站唯一真删磁盘的操作，
   * 讲透后果 → 勾选「我已明白」→ 红色按钮 → 结果凭据。旧的「文件会进回收站」
   * 确认框与后端「彻底删除、不可恢复」的语义不符，已废弃。
   */
  private confirmDelete(): void {
    this.showDeleteItem = true;
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
            if (this.chapters().length > 0 || detail.chapters_pending) {
              this.ChaptersBlock()
            }
            this.CastRow()
            if (this.similarItems.length > 0) {
              this.SimilarRow()
            }
            if (this.seriesRow !== null) {
              this.SeriesRow(this.seriesRow as CollectionSeriesView)
            }
            this.FileSection()
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ top: 24, bottom: 48 })
          .bindSheet($$this.showDeleteFile, this.DeleteFileSheetContent(), {
            height: SheetSize.LARGE,
            dragBar: true,
            showClose: false,
            backgroundColor: Theme.bg
          })
          AppFooter()
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .bindSheet($$this.showDeleteItem, this.DeleteItemSheetContent(), {
          height: SheetSize.LARGE,
          dragBar: true,
          showClose: false,
          backgroundColor: Theme.bg
        })
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .height('100%')
      .edgeEffect(EdgeEffect.None)
      .padding({ bottom: Theme.tabBarInset })
      .bindSheet($$this.showReidentify, this.ReidentifySheetContent(), {
        height: SheetSize.LARGE,
        dragBar: true,
        showClose: false,
        backgroundColor: Theme.bg
      })
    }
    .onRefreshing(() => {
      this.reload().then((): void => {
        this.refreshing = false;
      });
    })
    .width('100%')
    .height('100%')
    .bindSheet($$this.showDownloadSheet, this.DownloadSheetContent(), {
      detents: [SheetSize.MEDIUM, SheetSize.LARGE],
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.bg
    })
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
      // 媒体轨道区（iOS MediaTrackSection，位于元数据行下、播放键上）：
      // 只认在位文件（state == "in_place"，同 iOS availableFiles）
      MediaTrackSection({ files: this.inPlaceFiles() })
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
      // 电影：下载状态条（进度、暂停/继续/取消都在条上，对应 iOS `OfflineDownloadControl`）
      if (this.isMovie()) {
        OfflineDownloadControl({ mediaItemId: this.mediaItemId, title: detail.title })
      }
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

  /** 一排段胶囊（对齐 iOS `EpisodeRangeChips`）：选中的段白底黑字，锚点所在的段右上角橙点 */
  @Builder
  RangeChipsRow() {
    Scroll() {
      Row({ space: 8 }) {
        ForEach(this.episodeRanges(), (range: EpisodeRange) => {
          Stack({ alignContent: Alignment.TopEnd }) {
            Text(range.label())
              .fontSize(13)
              .fontWeight(this.currentRange() !== null
                && (this.currentRange() as EpisodeRange).index === range.index ? 600 : 400)
              .fontColor(this.currentRange() !== null
                && (this.currentRange() as EpisodeRange).index === range.index ? '#0b0d12' : Theme.textMuted)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .backgroundColor(this.currentRange() !== null
                && (this.currentRange() as EpisodeRange).index === range.index ? Color.White : Theme.glassFill)
              .borderRadius(14)
            if (this.currentAnchorNumber() >= 0 && range.contains(this.currentAnchorNumber())) {
              Circle()
                .width(5)
                .height(5)
                .fill(Theme.warning)
                .margin({ top: 4, right: 5 })
            }
          }
          .onClick(() => {
            this.switchRange(range);
          })
        }, (range: EpisodeRange) => `${range.index}`)
      }
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
  }

  /** 剧集：季切换 + 本季集列表；一季超过 50 集分段（段胶囊 + 「全部 N 集」宫格入口） */
  @Builder
  SeasonBlock(detail: LibraryItemDetailView) {
    Column({ space: 12 }) {
      Row() {
        Text('剧集')
          .fontSize(17)
          .fontWeight(600)
          .fontColor(Theme.text)
        Blank()
        if (this.episodes !== null) {
          if (this.episodeRanges().length > 0) {
            Row({ space: 2 }) {
              Text(`全部 ${this.episodes.episodes.length} 集`)
                .fontSize(14)
                .fontColor(Theme.textMuted)
              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(12)
                .fontWeight(600)
                .fontColor([Theme.textMuted])
            }
            .onClick(() => {
              this.showAllEpisodes = true;
            })
          } else {
            Text(`在库 ${this.ownedEpisodeCount()} / ${this.episodes.episodes.length} 集`)
              .fontSize(14)
              .fontColor(Theme.textFaint)
          }
        }
      }
      .width('100%')

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

      // 段胶囊：选中的段白底黑字，锚点所在的段带橙点
      if (this.episodeRanges().length > 0) {
        this.RangeChipsRow()
      }

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
          ForEach(this.shownEpisodes(), (episode: EpisodeView) => {
            this.EpisodeRow(episode)
          }, (episode: EpisodeView) => `${episode.episode_number}`)
        }
        .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
    .bindSheet($$this.showAllEpisodes, this.EpisodeGridSheetContent(), {
      detents: [SheetSize.MEDIUM, SheetSize.LARGE],
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.bg
    })
  }

  /** 「全部分集」面板内容（对齐 iOS `EpisodeGridSheet`）：段胶囊 + 5 列数字宫格 */
  /** 下载画质/范围面板（电影选画质，剧集选范围，见 OfflineProfileSheet） */
  @Builder
  DownloadSheetContent() {
    OfflineProfileSheet({
      fileId: this.downloadFileId,
      title: this.downloadSheetTitle(),
      choices: (): Promise<OfflineDownloadChoices> => {
        return this.buildSeriesChoices();
      },
      onDone: (): void => {
        this.showDownloadSheet = false;
      }
    })
  }

  @Builder
  EpisodeGridSheetContent() {
    if (this.episodes !== null) {
      EpisodeGridSheet({
        episodes: this.episodes.episodes,
        ranges: this.episodeRanges(),
        anchor: this.currentAnchorNumber(),
        selectedNumber: this.selectedEpisode === null ? -1 : (this.selectedEpisode as EpisodeView).episode_number,
        onPick: (episodeNumber: number): void => {
          this.pickFromGrid(episodeNumber);
        },
        onClose: (): void => {
          this.showAllEpisodes = false;
        }
      })
    }
  }

  /** 删除条目后果单（iOS DeleteItemSheet） */
  @Builder
  DeleteItemSheetContent() {
    DeleteItemSheet({
      libraryId: this.libraryId,
      mediaItemId: this.mediaItemId,
      title: this.detail !== null ? this.detail.title : '',
      onClose: (): void => {
        this.showDeleteItem = false;
      },
      onDeleted: (): void => {
        this.showDeleteItem = false;
        this.navStack.pop();
      }
    })
  }

  /** 删除单文件后果单（iOS DeleteFileSheet）：目标在打开前记进 deleteFileTarget */
  @Builder
  DeleteFileSheetContent() {
    if (this.deleteFileTarget !== null) {
      DeleteFileSheet({
        libraryId: this.libraryId,
        mediaItemId: this.mediaItemId,
        fileId: (this.deleteFileTarget as LibraryFileView).id,
        fileName: (this.deleteFileTarget as LibraryFileView).file_name,
        filePath: (this.deleteFileTarget as LibraryFileView).file_path,
        sizeBytes: (this.deleteFileTarget as LibraryFileView).size_bytes,
        missing: (this.deleteFileTarget as LibraryFileView).missing,
        seasonNumber: this.playUnitSeasonNumber(),
        episodeNumber: this.playUnitEpisodeNumber(),
        onClose: (): void => {
          this.showDeleteFile = false;
        },
        onDeleted: (): void => {
          this.showDeleteFile = false;
          this.reload();
        },
        onItemDeleted: (): void => {
          this.showDeleteFile = false;
          this.navStack.pop();
        }
      })
    }
  }

  /** 重新识别：两阶段修正面板（iOS ReidentifySheet） */
  @Builder
  ReidentifySheetContent() {
    ReidentifySheet({
      libraryId: this.libraryId,
      mediaItemId: this.mediaItemId,
      onClose: (): void => {
        this.showReidentify = false;
      },
      onApplied: (): void => {
        this.reload();
      }
    })
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
        Row({ space: 6 }) {
          if (this.isResumeEpisode(episode)) {
            Text('接着看')
              .fontSize(10)
              .fontWeight(700)
              .fontColor('#0b0d12')
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              .backgroundColor(Theme.warning)
              .borderRadius(4)
          }
          Text(episode.name !== null && episode.name !== undefined && episode.name.length > 0
            ? episode.name : `第 ${episode.episode_number} 集`)
            .fontSize(15)
            .fontColor(episode.owned ? Theme.text : Theme.textFaint)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
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
      // 行尾的本机下载小标（本机已下 / 在下才有，见 OfflineEpisodeDownloadMark）
      OfflineEpisodeDownloadMark({
        mediaItemId: this.mediaItemId,
        season: this.season,
        episode: episode.episode_number
      })
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

  /**
   * 章节条（iOS ChapterStripSection）：当前播放单元的章节横向一排，
   * 16:9 章节图 + 左下角时间戳，点哪章从哪章播；续播位置落点章打高亮。
   * 章节还在生成时（chapters_pending）出一行提示。
   */
  @Builder
  ChaptersBlock() {
    Column({ space: 12 }) {
      Text('章节')
        .fontSize(17)
        .fontWeight(600)
        .fontColor(Theme.text)
      if (this.chapters().length > 0) {
        Scroll() {
          Row({ space: 10 }) {
            ForEach(this.chapters(), (chapter: ChapterView) => {
              this.ChapterCard(chapter)
            }, (chapter: ChapterView) => `${chapter.index}-${this.chapterStart(chapter)}`)
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
      } else if ((this.detail as LibraryItemDetailView).chapters_pending) {
        Text('章节还在生成中，稍后再来看看。')
          .fontSize(12)
          .fontColor(Theme.textFaint)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  ChapterCard(chapter: ChapterView) {
    Column({ space: 6 }) {
      Stack({ alignContent: Alignment.BottomStart }) {
        if (this.chapterUrl(chapter).length > 0) {
          RemoteImage({ url: this.chapterUrl(chapter) })
            .width('100%')
            .height('100%')
        } else {
          // 没有章节图：拿标题首字占位
          Column({ space: 4 }) {
            Text(this.chapterTitle(chapter).length > 0 ? this.chapterTitle(chapter).substring(0, 1) : '·')
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .fontColor('rgba(255,255,255,0.25)')
            Text(this.chapterClock(this.chapterStart(chapter)))
              .fontSize(11)
              .fontColor('rgba(255,255,255,0.45)')
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor(Theme.surfaceRaised)
        }
        Text(this.chapterClock(this.chapterStart(chapter)))
          .fontSize(10)
          .fontColor(Color.White)
          .padding({ left: 5, right: 5, top: 2, bottom: 2 })
          .backgroundColor('rgba(0,0,0,0.55)')
          .borderRadius(5)
          .margin(6)
      }
      .width(136)
      .aspectRatio(16 / 9)
      .borderRadius(9)
      .clip(true)
      .border({
        width: this.isResumeChapter(chapter) ? 2 : 1,
        color: this.isResumeChapter(chapter) ? Theme.accentStrong : Theme.line
      })
      Text(this.chapterTitle(chapter).length > 0 ? this.chapterTitle(chapter) : `第 ${chapter.index + 1} 章`)
        .fontSize(11)
        .fontColor(Theme.text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width(136)
    .alignItems(HorizontalAlign.Start)
    .onClick(() => this.playFromChapter(chapter))
  }

  /**
   * 相似推荐（iOS ItemRelated 的 similar 行）：库内已有的相似条目，
   * 横向海报卡，点进库内详情页。
   */
  @Builder
  SimilarRow() {
    Column({ space: 12 }) {
      Text('相似推荐')
        .fontSize(17)
        .fontWeight(600)
        .fontColor(Theme.text)
      Scroll() {
        Row({ space: 12 }) {
          ForEach(this.similarItems, (item: LibraryItemView) => {
            Column({ space: 4 }) {
              RemoteImage({
                url: this.similarPosterUrl(item),
                placeholderSymbol: $r('sys.symbol.film')
              })
                .width('100%')
                .aspectRatio(2 / 3)
                .borderRadius(10)
                .clip(true)
                .border({ width: 1, color: Theme.line })
              Text(item.title)
                .fontSize(12)
                .fontColor(Theme.text)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              if (item.year !== null && item.year !== undefined) {
                Text(`${item.year}`)
                  .fontSize(11)
                  .fontColor(Theme.textFaint)
              }
            }
            .width(96)
            .alignItems(HorizontalAlign.Start)
            .onClick(() => this.openSimilar(item))
          }, (item: LibraryItemView) => `${item.media_item_id}`)
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 作品系列（iOS ItemRelated 的 series 行）：这部片所在的电影系列按上映顺序排开；
   * 没入库的部压暗，点去发现页补档；本片不压暗，带「本片」角标。
   */
  @Builder
  SeriesRow(series: CollectionSeriesView) {
    Column({ space: 12 }) {
      Text(series.series_name !== null && series.series_name !== undefined && series.series_name.length > 0
        ? series.series_name : '系列')
        .fontSize(17)
        .fontWeight(600)
        .fontColor(Theme.text)
      Text(`按上映顺序 · 共 ${series.parts.length} 部，已入库 ${series.owned_count} 部`)
        .fontSize(12)
        .fontColor(Theme.textFaint)
      Scroll() {
        Row({ space: 12 }) {
          ForEach(series.parts, (part: SeriesPartView) => {
            this.SeriesPartCard(series, part)
          }, (part: SeriesPartView) => `${part.tmdb_id}`)
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  SeriesPartCard(series: CollectionSeriesView, part: SeriesPartView) {
    Column({ space: 4 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        RemoteImage({
          url: this.seriesPosterUrl(part),
          placeholderSymbol: $r('sys.symbol.film')
        })
          .width('100%')
          .aspectRatio(2 / 3)
          .borderRadius(10)
          .clip(true)
          .border({ width: 1, color: Theme.line })
          .opacity(this.isCurrentSeriesPart(series, part) || part.media_item_id !== null ? 1 : 0.45)
        if (this.isCurrentSeriesPart(series, part)) {
          Text('本片')
            .fontSize(10)
            .fontWeight(700)
            .fontColor('#0b0d12')
            .padding({ left: 5, right: 5, top: 2, bottom: 2 })
            .backgroundColor(Theme.warning)
            .borderRadius(5)
            .margin(5)
        }
      }
      .width('100%')
      Text(part.title)
        .fontSize(12)
        .fontColor(part.media_item_id !== null ? Theme.text : Theme.textFaint)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (part.release_date !== null && part.release_date !== undefined && part.release_date.length >= 4) {
        Text(part.release_date.substring(0, 4))
          .fontSize(11)
          .fontColor(Theme.textFaint)
      }
    }
    .width(96)
    .alignItems(HorizontalAlign.Start)
    .onClick(() => this.openSeriesPart(part))
  }

  /** 相似条目海报地址 */
  private similarPosterUrl(item: LibraryItemView): string {
    const resolved: string | null =
      ImageUrls.resolve(AppModel.origin(), item.poster_url, ImageVariant.posterCard);
    return resolved !== null ? resolved : '';
  }

  /** 系列某一部海报地址 */
  private seriesPosterUrl(part: SeriesPartView): string {
    const resolved: string | null =
      ImageUrls.resolve(AppModel.origin(), part.poster_url ?? null, ImageVariant.posterCard);
    return resolved !== null ? resolved : '';
  }

  /** 库内相似条目点进库内详情 */
  private openSimilar(item: LibraryItemView): void {
    if (item.library_id !== null && item.library_id !== undefined && item.media_item_id >= 0) {
      this.navStack.pushPathByName('libraryItem',
        new ItemRouteParams(item.library_id, item.media_item_id));
    }
  }

  /** 这个部是不是当前这部片（媒体条目 ID 对得上） */
  private isCurrentSeriesPart(series: CollectionSeriesView, part: SeriesPartView): boolean {
    const detail: LibraryItemDetailView | null = this.detail;
    const itemId: number | null = part.media_item_id ?? null;
    return detail !== null && itemId !== null && itemId === detail.media_item_id;
  }

  /** 系列里的某一部：已入库点进库内详情（落在当前库），没入库去发现页补档 */
  private openSeriesPart(part: SeriesPartView): void {
    const itemId: number | null = part.media_item_id ?? null;
    if (itemId !== null && itemId >= 0) {
      this.navStack.pushPathByName('libraryItem', new ItemRouteParams(this.libraryId, itemId));
      return;
    }
    this.navStack.pushPathByName('discoverDetail',
      new DiscoverDetailParams(`tmdb:movie:${part.tmdb_id}`));
  }

  @Builder
  FileSection() {
    if (this.currentFiles().length > 0) {
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          Text(this.isMovie() ? `文件 · ${this.currentFiles().length} 个` : `第 ${this.season} 季 · 当前集文件`)
            .fontSize(17)
            .fontWeight(600)
            .fontColor(Theme.text)
        }
        .width('100%')
        ForEach(this.currentFiles(), (file: LibraryFileView) => {
          this.FileRow(file)
        }, (file: LibraryFileView) => `${file.id}`)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
    }
  }

  /** 一个文件行（iOS LibraryFileRow）：点行展开，展开后是这份文件的台账 + 操作 */
  @Builder
  FileRow(file: LibraryFileView) {
    Column({ space: 0 }) {
      Row({ space: 10 }) {
        Column({ space: 3 }) {
          Text(file.file_name)
            .fontSize(14)
            .fontColor(file.missing ? Theme.warn : Theme.text)
            .decoration({ type: this.fileTrashed(file) ? TextDecorationType.LineThrough : TextDecorationType.None })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.fileSpec(file))
            .fontSize(12)
            .fontColor(Theme.textFaint)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Blank()
        if (this.fileTrashed(file)) {
          this.FileTag('待回收', Theme.warn)
        } else if (file.missing) {
          this.FileTag('缺失', Theme.warn)
        } else if (file.kept_at !== null && file.kept_at !== undefined) {
          this.FileTag('多版本', Theme.textFaint)
        }
        if (!this.fileTrashed(file) && !file.missing) {
          Button('删除', { type: ButtonType.Normal, stateEffect: false })
            .controlSize(ControlSize.NORMAL)
            .fontSize(11)
            .fontWeight(400)
            .fontColor(Theme.textFaint)
            .constraintSize({ minWidth: 0, minHeight: 0 })
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .backgroundColor(Theme.glassFill)
            .borderRadius(8)
            .onClick(() => this.openDeleteFile(file))
        }
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(14)
          .fontColor([Theme.textFaint])
          .rotate({ angle: this.expandedFileId === file.id ? 180 : 0 })
      }
      .width('100%')
      .padding({ left: 12, right: 10, top: 10, bottom: 10 })
      .onClick(() => this.toggleFile(file.id))
      if (this.expandedFileId === file.id) {
        this.FileDetails(file)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(Theme.glassFill)
    .borderRadius(10)
  }

  @Builder
  FileTag(text: string, color: string) {
    Text(text)
      .fontSize(11)
      .fontColor(color)
      .padding({ left: 7, right: 7, top: 2, bottom: 2 })
      .backgroundColor(Theme.glassFill)
      .borderRadius(6)
  }

  /** 展开的文件详情（iOS LibraryFileRow 展开区：目录/入库时间/来源/规格/待回收操作） */
  @Builder
  FileDetails(file: LibraryFileView) {
    Column({ space: 0 }) {
      Divider()
        .color(Theme.line)
        .margin({ top: 2, bottom: 10 })
      if (this.fileTrashed(file)) {
        Column({ space: 8 }) {
          if (file.trash_note !== null && file.trash_note !== undefined && file.trash_note.length > 0) {
            Text(file.trash_note as string)
              .fontSize(12)
              .fontColor(Theme.textFaint)
          }
          Text(this.purgeCountdown(file.purge_after ?? null))
            .fontSize(12)
            .fontColor(Theme.textFaint)
          Text('还在磁盘上，要占空间；恢复它就回到在位版本，或立即清理彻底删除。')
            .fontSize(12)
            .fontColor(Theme.textFaint)
          Row({ space: 8 }) {
            Button('恢复')
              .controlSize(ControlSize.NORMAL)
              .buttonStyle(ButtonStyleMode.NORMAL)
              .backgroundColor(Theme.glassFill)
              .fontColor(Theme.text)
              .onClick(() => this.restoreFile(file))
            Button('立即清理')
              .controlSize(ControlSize.NORMAL)
              .buttonStyle(ButtonStyleMode.NORMAL)
              .backgroundColor(Theme.danger)
              .fontColor(Color.White)
              .onClick(() => this.purgeFile(file))
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 12, right: 12, bottom: 12 })
      } else {
        Column({ space: 6 }) {
          ForEach(this.specRows(file), (row: FileSpecRow) => {
            Row({ space: 8 }) {
              Text(row.label)
                .fontSize(12)
                .fontColor(Theme.textFaint)
                .width(64)
              Text(row.value)
                .fontSize(12)
                .fontColor(Theme.text)
                .layoutWeight(1)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
          }, (row: FileSpecRow) => row.label)
          if (file.kept_at !== null && file.kept_at !== undefined) {
            Text(this.keptHint(file))
              .fontSize(12)
              .fontColor(Theme.textFaint)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 12, right: 12, bottom: 12 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 这份文件是否处于待回收状态 */
  private fileTrashed(file: LibraryFileView): boolean {
    return file.state === 'trashed';
  }

  /** 多版本保留提示：同单元里留着几份，这一份是 kept_at 标的那份 */
  private keptHint(file: LibraryFileView): string {
    const kept: string | null = file.kept_at ?? null;
    const label: string = kept !== null ? Formatters.dateTime(kept) : '较早';
    return `同一${this.isMovie() ? '部影片' : '集'}保留了多份文件；这一份（${label}入库）被标为保留版本，通常对应字幕组或来源不同的版本。`;
  }

  /**
   * 展开区规格行（同 iOS LibraryFileRow.specRows）。
   * 折叠时的一行摘要走 fileSpec()，展开后分行列全：目录/体积/画质/帧率/来源/入库时间。
   */
  private specRows(file: LibraryFileView): FileSpecRow[] {
    const rows: FileSpecRow[] = [];
    rows.push(new FileSpecRow('保存目录', this.fileDirectory(file.file_path)));
    rows.push(new FileSpecRow('体积', libraryBytes(file.size_bytes)));
    const picture: string[] = [];
    const resolution: string | null = file.resolution ?? null;
    if (resolution !== null && resolution.length > 0) {
      picture.push(LibraryItemDetailPage.resolutionLabel(resolution));
    }
    const codec: string | null = file.video_codec ?? null;
    if (codec !== null && codec.length > 0) {
      picture.push(LibraryItemDetailPage.codecLabel(codec));
    }
    const hdr: string | null = file.hdr ?? null;
    if (hdr !== null && hdr.length > 0) {
      picture.push(hdr);
    }
    const frameRate: number | null = file.frame_rate ?? null;
    if (frameRate !== null && frameRate > 0) {
      picture.push(`${LibraryItemDetailPage.frameRateText(frameRate)} fps`);
    }
    if (picture.length > 0) {
      rows.push(new FileSpecRow('画质', picture.join(' · ')));
    }
    rows.push(new FileSpecRow('来源', this.fileOriginText(file)));
    const added: string = file.added_at;
    if (added.length > 0) {
      rows.push(new FileSpecRow('入库时间', Formatters.dateTime(added)));
    }
    return rows;
  }

  /** 来源一行（iOS fileSourceLabel：origin.kind == detail 用 detail，否则 label） */
  private fileOriginText(file: LibraryFileView): string {
    const origin: FileOriginView | null = file.origin ?? null;
    if (origin === null || origin === undefined) {
      return '未识别';
    }
    if (origin.kind === 'detail') {
      const detail: string | null = origin.detail ?? null;
      if (detail !== null && detail.length > 0) {
        return detail;
      }
    }
    return origin.label.length > 0 ? origin.label : '未识别';
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

  private static codecLabel(codec: string): string {
    const map: Record<string, string> = {
      'hevc': 'HEVC',
      'h265': 'HEVC',
      'h264': 'H.264',
      'av1': 'AV1',
      'vp9': 'VP9',
      'vc1': 'VC-1',
      'mpeg2video': 'MPEG-2'
    };
    const mapped: string | undefined = map[codec.toLowerCase()];
    return mapped !== undefined ? mapped : codec.toUpperCase();
  }

  private static frameRateText(frameRate: number): string {
    const rounded: string = `${Math.round(frameRate * 1000) / 1000}`;
    return rounded.endsWith('.0') ? rounded.substring(0, rounded.length - 2) : rounded;
  }
}

/** 展开区的一行「标签 + 值」（iOS LibraryFileRow.specRows 的行） */
class FileSpecRow {
  readonly label: string;
  readonly value: string;

  constructor(label: string, value: string) {
    this.label = label;
    this.value = value;
  }
}

/**
 * 「全部分集」面板（对齐 iOS `EpisodeGridSheet`）：段胶囊（打开时落在锚点的段）
 * + 5 列数字宫格。格子：已看 ✓、进度条、缺集虚线、锚点橙边、选中白底。
 * 点格子交给分集区：关面板、选中那一集、段跟过去。
 */
@Component
struct EpisodeGridSheet {
  @Prop episodes: EpisodeView[] = [];
  @Prop ranges: EpisodeRange[] = [];
  /** 锚点集号（-1 = 没有） */
  @Prop anchor: number = -1;
  /** 选中的集号（-1 = 没有） */
  @Prop selectedNumber: number = -1;
  /** 打开时落在锚点（或选中集）所在的段 */
  @State private rangeIndex: number = 0;
  onPick: (episodeNumber: number) => void = (): void => {
  };
  onClose: () => void = (): void => {
  };

  aboutToAppear(): void {
    const start: number = this.anchor >= 0 ? this.anchor : this.selectedNumber;
    if (start >= 0) {
      const range: EpisodeRange | null = EpisodeRanges.rangeContaining(start, this.ranges);
      this.rangeIndex = range === null ? 0 : range.index;
    }
  }

  private currentRange(): EpisodeRange | null {
    for (const range of this.ranges) {
      if (range.index === this.rangeIndex) {
        return range;
      }
    }
    return this.ranges.length > 0 ? this.ranges[0] : null;
  }

  private shownEpisodes(): EpisodeView[] {
    const range: EpisodeRange | null = this.currentRange();
    if (range === null) {
      return this.episodes;
    }
    const out: EpisodeView[] = [];
    for (const episode of this.episodes) {
      if (range.contains(episode.episode_number)) {
        out.push(episode);
      }
    }
    return out;
  }

  private ownedCount(): number {
    let count: number = 0;
    for (const episode of this.episodes) {
      if (episode.owned) {
        count += 1;
      }
    }
    return count;
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text('全部分集')
          .fontSize(17)
          .fontWeight(600)
          .fontColor(Theme.text)
        Text(`在库 ${this.ownedCount()} / ${this.episodes.length}`)
          .fontSize(12)
          .fontColor(Theme.textFaint)
        Blank()
        Text('完成')
          .fontSize(14)
          .fontWeight(500)
          .fontColor(Theme.textMuted)
          .onClick(() => {
            this.onClose();
          })
      }
      .width('100%')
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 16 })

      this.SheetRangeChipsRow()

      Scroll() {
        Grid() {
          ForEach(this.shownEpisodes(), (episode: EpisodeView) => {
            GridItem() {
              this.GridCell(episode)
            }
          }, (episode: EpisodeView) => `${episode.episode_number}`)
        }
        .columnsTemplate('1fr 1fr 1fr 1fr 1fr')
        .columnsGap(8)
        .rowsGap(8)
        .width('100%')
        .padding({ left: Theme.pagePadding, right: Theme.pagePadding, bottom: 30 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  /** 一排段胶囊（面板自己的选中态）：选中的段白底黑字，锚点所在的段右上角橙点 */
  @Builder
  SheetRangeChipsRow() {
    Scroll() {
      Row({ space: 8 }) {
        ForEach(this.ranges, (range: EpisodeRange) => {
          Stack({ alignContent: Alignment.TopEnd }) {
            Text(range.label())
              .fontSize(13)
              .fontWeight(this.currentRange() !== null
                && (this.currentRange() as EpisodeRange).index === range.index ? 600 : 400)
              .fontColor(this.currentRange() !== null
                && (this.currentRange() as EpisodeRange).index === range.index ? '#0b0d12' : Theme.textMuted)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .backgroundColor(this.currentRange() !== null
                && (this.currentRange() as EpisodeRange).index === range.index ? Color.White : Theme.glassFill)
              .borderRadius(14)
            if (this.anchor >= 0 && range.contains(this.anchor)) {
              Circle()
                .width(5)
                .height(5)
                .fill(Theme.warning)
                .margin({ top: 4, right: 5 })
            }
          }
          .onClick(() => {
            this.rangeIndex = range.index;
          })
        }, (range: EpisodeRange) => `${range.index}`)
      }
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
  }

  /** 宫格的一格：数字 + 已看勾 / 进度条 / 缺集虚线 / 锚点橙边 / 选中白底 */
  @Builder
  GridCell(episode: EpisodeView) {
    Stack({ alignContent: Alignment.BottomStart }) {
      Text(`${episode.episode_number}`)
        .fontSize(15)
        .fontWeight(this.selectedNumber === episode.episode_number ? 600 : 400)
        .fontColor(this.cellInk(episode))
        .width('100%')
        .height(46)
        .textAlign(TextAlign.Center)
        .backgroundColor(this.cellFill(episode))
        .borderRadius(10)
      if (this.selectedNumber !== episode.episode_number && !episode.owned) {
        // 缺集：虚线描边
        Column()
          .width('100%')
          .height(46)
          .borderRadius(10)
          .border({
            width: 1,
            color: 'rgba(255,255,255,0.15)',
            style: BorderStyle.Dashed
          })
      }
      if (episode.played) {
        // 已看勾：右上角
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(9)
            .fontWeight(700)
            .fontColor([Theme.ok])
        }
        .width(16)
        .height(16)
        .position({ x: '100%', y: 0 })
        .markAnchor({ x: '100%', y: 0 })
      }
      if ((episode.progress_percent ?? 0) > 0) {
        // 看了一半：底部进度条
        Row() {
          Column()
            .width(`${Math.min(99, Math.max(1, Math.round(episode.progress_percent ?? 0)))}%`)
            .height(3)
            .backgroundColor(Theme.accent2)
        }
        .width('100%')
      }
    }
    .width('100%')
    .borderRadius(10)
    .border(this.anchor === episode.episode_number
      ? { width: 2, color: Theme.warning }
      : { width: 0 })
    .onClick(() => {
      this.onPick(episode.episode_number);
    })
  }

  private cellFill(episode: EpisodeView): ResourceColor {
    if (this.selectedNumber === episode.episode_number) {
      return Color.White;
    }
    if (!episode.owned) {
      return Color.Transparent;
    }
    if (episode.played) {
      return 'rgba(255,255,255,0.03)';
    }
    return 'rgba(255,255,255,0.06)';
  }

  private cellInk(episode: EpisodeView): ResourceColor {
    if (this.selectedNumber === episode.episode_number) {
      return '#0b0d12';
    }
    if (!episode.owned) {
      return Theme.textFaint;
    }
    if (episode.played) {
      return Theme.textMuted;
    }
    return Theme.text;
  }
}
