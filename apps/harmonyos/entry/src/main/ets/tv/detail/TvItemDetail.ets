/**
 * TV 条目详情页（US3 + 大屏增强）：
 * - 首屏：剧照原图 + 动态主光呼吸光晕 + ClearLogo/片名 + 事实行 + HDR Vivid / Audio Vivid / 杜比视界规格小标签
 *   + 可聚焦按确认展开全文的剧情简介 + 主次操作按钮；
 * - 新增：多片源版本选择胶囊（Remux / 4K HDR / 1080p 指定文件起播）+ 客厅五星个人评分排；
 * - 接入 ContinuationBridge 流转发布：详情页浏览中流转至手机/平板自动落同一部作品。
 */
import { AppModel } from '../../common/AppModel';
import { ContinuationBridge } from '../../common/ContinuationBridge';
import { Formatters } from '../../common/Formatters';
import { ImageUrls, ImageVariant } from '../../common/ImageUrls';
import { RemoteImage } from '../../common/RemoteImage';
import { MovieClawApi } from '../../api/Endpoints';
import {
  AudioStreamView,
  CollectionSeriesView,
  EpisodeView,
  ItemCollectionRef,
  LibraryFileView,
  LibraryItemDetailView,
  LibraryItemView,
  LocalMetaView,
  PlaybackMarksRequest,
  PlaybackMarksView,
  PlaybackStateView,
  SeasonEpisodesView,
  UpNextItemView
} from '../../api/Models';
import { LibraryHomeStore } from '../../library/LibraryHomeStore';
import { TvEpisodeCard, TvFormat, TvPillButton, TvStateView } from '../components/TvCards';
import { TvFocus } from '../components/TvFocus';
import { TvFocusable } from '../components/TvFocusable';
import { TvShelf, TvShelfCard } from '../components/TvShelf';
import { TvStageAction, TvStageBackdrop, TvStageBlock } from '../components/TvStage';
import {
  TvCollectionRoute,
  TvDetailRoute,
  TvPersonRoute,
  TvPlayRequest,
  TvUiState,
  TvWallRoute
} from '../model/TvUiState';
import { TvPlayback } from '../playback/TvPlaybackHost';
import { TvArt, TvColors, TvMetrics, TvType } from '../theme/TvTheme';

class TvCastPerson {
  readonly name: string;
  readonly role: string | null;
  readonly avatarUrl: string;
  readonly personId: number | null;
  readonly isActor: boolean;

  constructor(name: string, role: string | null, avatarUrl: string, personId: number | null, isActor: boolean = false) {
    this.name = name;
    this.role = role;
    this.avatarUrl = avatarUrl;
    this.personId = personId;
    this.isActor = isActor;
  }
}

class TvEpisodeRange {
  readonly index: number;
  readonly first: number;
  readonly last: number;

  constructor(index: number, first: number, last: number) {
    this.index = index;
    this.first = first;
    this.last = last;
  }

  label(): string {
    return `${this.first}–${this.last}`;
  }

  contains(episodeNumber: number): boolean {
    return episodeNumber >= this.first && episodeNumber <= this.last;
  }
}

function resolutionHeightOf(raw: string | null | undefined): number | null {
  if (raw === null || raw === undefined) {
    return null;
  }
  const normalized: string = raw.trim().toLowerCase();
  if (normalized === '8k') {
    return 4320;
  }
  if (normalized === '4k' || normalized === 'uhd') {
    return 2160;
  }
  if (normalized === '2k') {
    return 1440;
  }
  const digits: string = normalized.replace(/[^0-9]/g, '');
  return digits.length === 0 ? null : Number(digits);
}

function clockOf(ms: number): string {
  const total: number = Math.floor(ms / 1000);
  const minutes: number = Math.floor(total / 60);
  const seconds: number = total % 60;
  return `${minutes}:${seconds < 10 ? '0' : ''}${seconds}`;
}

function anchorEpisodeOf(episodes: EpisodeView[]): EpisodeView | null {
  if (episodes.length === 0) {
    return null;
  }
  for (const ep of episodes) {
    if (ep.position_ms > 0) {
      return ep;
    }
  }
  for (const ep of episodes) {
    if (!ep.played && ep.owned) {
      return ep;
    }
  }
  return episodes[0];
}

function anchorEpisodeOfResult(result: SeasonEpisodesView): EpisodeView | null {
  const resume: number | null = result.resume_episode ?? null;
  if (resume !== null) {
    for (const ep of result.episodes) {
      if (ep.episode_number === resume) {
        return ep;
      }
    }
  }
  return anchorEpisodeOf(result.episodes);
}

function buildEpisodeRanges(episodes: EpisodeView[]): TvEpisodeRange[] {
  const size: number = 50;
  if (episodes.length <= size) {
    return [];
  }
  const numbers: number[] = [];
  for (const ep of episodes) {
    numbers.push(ep.episode_number);
  }
  numbers.sort((a: number, b: number): number => a - b);
  const out: TvEpisodeRange[] = [];
  for (const n of numbers) {
    const index: number = Math.floor(Math.max(0, n - 1) / size);
    const last: TvEpisodeRange | undefined = out[out.length - 1];
    if (last !== undefined && last.index === index) {
      out[out.length - 1] = new TvEpisodeRange(index, last.first, n);
    } else {
      out.push(new TvEpisodeRange(index, n, n));
    }
  }
  return out;
}

function castPeopleOf(detail: LibraryItemDetailView, origin: string): TvCastPerson[] {
  const meta: LocalMetaView | null = detail.local_meta ?? null;
  if (meta === null) {
    return [];
  }
  const out: TvCastPerson[] = [];
  if (meta.director_credits.length > 0) {
    for (const dir of meta.director_credits) {
      out.push(new TvCastPerson(dir.name, '导演',
        ImageUrls.resolve(origin, dir.thumb_url ?? null, null) ?? '', dir.tmdb_person_id));
    }
  } else {
    for (const name of meta.directors) {
      out.push(new TvCastPerson(name, '导演', '', null));
    }
  }
  for (const actor of meta.actors) {
    const role: string | null = actor.role ?? null;
    out.push(new TvCastPerson(actor.name,
      role === null ? null : `饰 ${role}`,
      ImageUrls.resolve(origin, actor.thumb_url ?? null, null) ?? '',
      actor.tmdb_person_id ?? null, true));
  }
  return out;
}

function fileVersionLabel(file: LibraryFileView): string {
  const parts: string[] = [];
  if (file.resolution !== null && file.resolution !== undefined && file.resolution.length > 0) {
    parts.push(file.resolution.toUpperCase());
  }
  if (file.hdr !== null && file.hdr !== undefined && file.hdr.length > 0) {
    parts.push(file.hdr);
  }
  if (file.video_codec !== null && file.video_codec !== undefined && file.video_codec.length > 0) {
    parts.push(file.video_codec.toUpperCase());
  }
  if (file.size_bytes > 0) {
    parts.push(Formatters.bytes(file.size_bytes));
  }
  return parts.length > 0 ? parts.join(' · ') : `版本 #${file.id}`;
}

@ComponentV2
struct DetailPill {
  @Param label: string = '';
  @Param selected: boolean = false;
  @Param onActivate: (() => void) | null = null;
  @Local active: boolean = false;

  build() {
    TvFocusable({
      focusScale: 1.06,
      cornerRadius: 999,
      onActivate: (): void => {
        const cb = this.onActivate;
        if (cb !== null) {
          cb();
        }
      },
      onFocusGained: (active: boolean): void => {
        this.active = active;
      }
    }) {
      Text(this.label)
        .fontSize(TvType.footnote)
        .fontWeight(600)
        .fontColor(this.active ? '#0b0d12'
          : (this.selected ? TvColors.text : TvColors.textMuted))
        .maxLines(1)
        .padding({ left: 18, right: 18, top: 7, bottom: 7 })
        .backgroundColor(this.active ? '#f3f5f9'
          : (this.selected ? 'rgba(255, 255, 255, 0.16)' : 'rgba(255, 255, 255, 0.06)'))
        .borderRadius(999)
    }
  }
}

@ComponentV2
export struct TvItemDetail {
  @Param libraryId: number = 0;
  @Param itemId: number = 0;
  @Local ui: TvUiState = TvUiState.shared;

  @Local detail: LibraryItemDetailView | null = null;
  @Local failed: boolean = false;
  @Local favorite: boolean | null = null;
  @Local userRating: number = 0;
  @Local selectedFileId: number | null = null;
  @Local plotModalOpen: boolean = false;
  @Local watched: PlaybackStateView | null = null;
  @Local season: number | null = null;
  @Local selectedEpisode: EpisodeView | null = null;
  @Local episodes: EpisodeView[] = [];
  @Local browseSeason: number | null = null;
  @Local browseEpisodes: EpisodeView[] = [];
  @Local browseAnchor: number | null = null;
  @Local browseRanges: TvEpisodeRange[] = [];
  @Local browseWatched: boolean = false;
  @Local similar: LibraryItemView[] = [];
  @Local series: CollectionSeriesView | null = null;
  @Local castPeople: TvCastPerson[] = [];
  @Local pageHeight: number = 0;

  private marking: boolean = false;
  private playedHere: boolean = false;
  private episodeScroller: Scroller = new Scroller();
  private mainScroller: Scroller = new Scroller();
  private boundRoute: TvDetailRoute | null = null;

  aboutToAppear(): void {
    const routes = this.ui.routes;
    if (routes.length > 0) {
      const top = routes[routes.length - 1];
      if (top instanceof TvDetailRoute && top.itemId === this.itemId) {
        this.boundRoute = top;
        this.ui.registerRouteBack(top, (): boolean => {
          if (this.plotModalOpen) {
            this.plotModalOpen = false;
            return true;
          }
          return false;
        });
      }
    }
    this.reload();
  }

  aboutToDisappear(): void {
    if (this.boundRoute !== null) {
      this.ui.unregisterRouteBack(this.boundRoute);
      this.boundRoute = null;
    }
    ContinuationBridge.shared().clearActive();
  }

  @Monitor('ui.playerRequest')
  onPlayerRequestChange(): void {
    const request: TvPlayRequest | null = this.ui.playerRequest;
    if (request !== null) {
      if (request.itemId === this.itemId) {
        this.playedHere = true;
      }
      return;
    }
    if (this.playedHere) {
      this.playedHere = false;
      this.refreshAfterPlayback();
    }
  }

  private async reload(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      this.failed = true;
      return;
    }
    this.loadMarks(api);
    try {
      const fresh: LibraryItemDetailView = await api.libraryItemsGet(this.libraryId, this.itemId);
      const related: Promise<void> = this.loadRelated(api, fresh);
      if (fresh.kind === 'tv' && fresh.seasons.length > 0) {
        const start: number | null = this.startSeasonOf(fresh);
        if (start !== null) {
          const result: SeasonEpisodesView =
            await api.libraryItemsListEpisodes(this.libraryId, this.itemId, start);
          this.applySeasonResult(result, false);
          this.applyBrowseResult(result);
        }
      }
      await related;
      this.detail = fresh;
      this.castPeople = castPeopleOf(fresh, AppModel.origin());
      this.failed = false;
      ContinuationBridge.shared().publishItem(
        AppModel.origin(),
        this.libraryId,
        this.itemId,
        this.season ?? 0,
        this.selectedEpisode?.episode_number ?? 0,
        fresh.title
      );
      this.loadResume();
      const anchor: number | null = this.browseAnchor;
      if (anchor !== null) {
        setTimeout((): void => {
          this.tryScrollToEpisode(anchor, false);
        }, 120);
      }
    } catch (_error) {
      if (this.detail === null) {
        this.failed = true;
      }
    }
  }

  private async loadRelated(api: MovieClawApi, fresh: LibraryItemDetailView): Promise<void> {
    const isMovie: boolean = fresh.kind !== 'tv';
    const seriesId: number | null = isMovie ? (fresh.series_collection_id ?? null) : null;
    const similarTask: Promise<LibraryItemView[]> = this.fetchSimilar(api, seriesId !== null);
    let series: CollectionSeriesView | null = null;
    if (seriesId !== null) {
      try {
        const freshSeries: CollectionSeriesView = await api.collectionSeriesGet(seriesId);
        if (freshSeries.available && freshSeries.parts.length > 1) {
          series = freshSeries;
        }
      } catch (_error) {
        series = null;
      }
    }
    let items: LibraryItemView[] = [];
    try {
      items = await similarTask;
    } catch (_error) {
      items = [];
    }
    if (seriesId !== null && series === null) {
      items = await this.fetchSimilar(api, false);
    }
    this.similar = items;
    this.series = series;
  }

  private async fetchSimilar(api: MovieClawApi, excludeSeries: boolean): Promise<LibraryItemView[]> {
    try {
      return await api.uiLibraryItemsSimilar(this.libraryId, this.itemId,
        undefined, excludeSeries ? true : undefined);
    } catch (_error) {
      return [];
    }
  }

  private startSeasonOf(detail: LibraryItemDetailView): number | null {
    const seasons: number[] = detail.seasons;
    if (seasons.length === 0) {
      return null;
    }
    const upNext: UpNextItemView[] = LibraryHomeStore.shared.upNext ?? [];
    for (const item of upNext) {
      if (item.media_item_id === this.itemId && item.kind === 'tv') {
        if (seasons.includes(item.season_number)) {
          return item.season_number;
        }
        break;
      }
    }
    const owned: Set<number> = new Set<number>();
    for (const file of detail.files) {
      if (file.state === 'in_place') {
        owned.add(file.season_number);
      }
    }
    for (const s of seasons) {
      if (s > 0 && owned.has(s)) {
        return s;
      }
    }
    for (const s of seasons) {
      if (owned.has(s)) {
        return s;
      }
    }
    for (const s of seasons) {
      if (s > 0) {
        return s;
      }
    }
    return seasons[0];
  }

  private applySeasonResult(result: SeasonEpisodesView, keepSelection: boolean): void {
    this.season = result.season_number;
    this.episodes = result.episodes;
    const current: EpisodeView | null = this.selectedEpisode;
    if (keepSelection && current !== null) {
      for (const ep of result.episodes) {
        if (ep.episode_number === current.episode_number) {
          this.selectedEpisode = ep;
          return;
        }
      }
    }
    this.selectedEpisode = anchorEpisodeOfResult(result);
  }

  private applyBrowseResult(result: SeasonEpisodesView): void {
    this.browseSeason = result.season_number;
    this.browseEpisodes = result.episodes;
    const anchor: EpisodeView | null = anchorEpisodeOfResult(result);
    this.browseAnchor = anchor === null ? null : anchor.episode_number;
    this.browseRanges = buildEpisodeRanges(result.episodes);
    let watched: boolean = false;
    for (const ep of result.episodes) {
      if (ep.played || ep.position_ms > 0) {
        watched = true;
        break;
      }
    }
    this.browseWatched = watched;
  }

  private async loadBrowse(seasonNumber: number): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    try {
      const result: SeasonEpisodesView =
        await api.libraryItemsListEpisodes(this.libraryId, this.itemId, seasonNumber);
      this.applyBrowseResult(result);
      this.tryScrollToEpisode(this.browseAnchor ?? 1, false);
    } catch (_error) {
    }
  }

  private async loadMarks(api: MovieClawApi): Promise<void> {
    try {
      const marks: PlaybackMarksView = await api.playbackMarksGet(this.itemId);
      this.favorite = marks.is_favorite;
      this.userRating = marks.user_rating ?? 0;
    } catch (_error) {
    }
  }

  private async loadResume(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    const detail: LibraryItemDetailView | null = this.detail;
    if (api === null || detail === null) {
      return;
    }
    let unitSeason: number | null = null;
    let unitEpisode: number | null = null;
    if (detail.kind !== 'tv') {
      unitSeason = 0;
      unitEpisode = 0;
    } else if (this.season !== null && this.selectedEpisode !== null) {
      unitSeason = this.season;
      unitEpisode = this.selectedEpisode.episode_number;
    }
    if (unitSeason === null || unitEpisode === null) {
      this.watched = null;
      return;
    }
    try {
      this.watched = await api.playbackResume(this.itemId, unitSeason, unitEpisode);
    } catch (_error) {
      this.watched = null;
    }
  }

  private async refreshAfterPlayback(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    const detail: LibraryItemDetailView | null = this.detail;
    if (api === null || detail === null) {
      return;
    }
    this.loadResume();
    if (detail.kind !== 'tv' || this.season === null) {
      return;
    }
    const seasonNumber: number = this.season;
    try {
      const result: SeasonEpisodesView =
        await api.libraryItemsListEpisodes(this.libraryId, this.itemId, seasonNumber);
      this.applySeasonResult(result, false);
      if (this.browseSeason === seasonNumber) {
        this.applyBrowseResult(result);
      }
    } catch (_error) {
      return;
    }
    if (this.browseSeason !== null && this.browseSeason !== seasonNumber) {
      const browseNumber: number = this.browseSeason;
      try {
        const result: SeasonEpisodesView =
          await api.libraryItemsListEpisodes(this.libraryId, this.itemId, browseNumber);
        this.applyBrowseResult(result);
      } catch (_error) {
      }
    }
  }

  // MARK: - 写操作（收藏 / 已看 / 五星评分）

  private async toggleFavorite(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null || this.marking) {
      return;
    }
    this.marking = true;
    const next: boolean = !(this.favorite === true);
    this.favorite = next;
    const body: PlaybackMarksRequest = { media_item_id: this.itemId, favorite: next };
    try {
      const marks: PlaybackMarksView = await api.playbackMarksSet(body);
      this.favorite = marks.is_favorite;
    } catch (_error) {
      this.favorite = !next;
    } finally {
      this.marking = false;
    }
  }

  private async setRating(stars: number): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null || this.marking) {
      return;
    }
    this.marking = true;
    const prev: number = this.userRating;
    const target: number = stars === prev ? 0 : stars;
    this.userRating = target;
    const body: PlaybackMarksRequest = {
      media_item_id: this.itemId,
      user_rating: target > 0 ? target * 2 : 0
    };
    try {
      const marks: PlaybackMarksView = await api.playbackMarksSet(body);
      this.userRating = marks.user_rating ?? 0;
    } catch (_error) {
      this.userRating = prev;
    } finally {
      this.marking = false;
    }
  }

  private async togglePlayed(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    const detail: LibraryItemDetailView | null = this.detail;
    if (api === null || detail === null || this.marking) {
      return;
    }
    this.marking = true;
    const isMovie: boolean = detail.kind !== 'tv';
    const unitSeason: number = isMovie ? 0 : (this.season ?? 0);
    const selected: EpisodeView | null = this.selectedEpisode;
    const unitEpisode: number = isMovie ? 0 : (selected === null ? 0 : selected.episode_number);
    const next: boolean = !(this.watched !== null && this.watched.played);
    const body: PlaybackMarksRequest = {
      media_item_id: this.itemId,
      season_number: isMovie ? null : unitSeason,
      episode_number: isMovie ? null : unitEpisode,
      played: next
    };
    try {
      await api.playbackMarksSet(body);
      this.loadResume();
      if (!isMovie && this.season !== null) {
        const seasonNumber: number = this.season;
        try {
          const result: SeasonEpisodesView =
            await api.libraryItemsListEpisodes(this.libraryId, this.itemId, seasonNumber);
          this.applySeasonResult(result, true);
        } catch (_error) {
        }
      }
    } catch (_error) {
    } finally {
      this.marking = false;
    }
  }

  // MARK: - 多版本片源与起播

  private unitFiles(): LibraryFileView[] {
    const detail: LibraryItemDetailView | null = this.detail;
    if (detail === null) {
      return [];
    }
    const out: LibraryFileView[] = [];
    for (const file of detail.files) {
      if (file.state !== 'in_place') {
        continue;
      }
      if (detail.kind !== 'tv') {
        out.push(file);
      } else if (this.season !== null && this.selectedEpisode !== null
        && file.season_number === this.season
        && file.episode_number === this.selectedEpisode.episode_number) {
        out.push(file);
      }
    }
    return out;
  }

  private play(startMs: number | null): void {
    const detail: LibraryItemDetailView | null = this.detail;
    if (detail === null) {
      return;
    }
    const isMovie: boolean = detail.kind !== 'tv';
    const selected: EpisodeView | null = this.selectedEpisode;
    const seasonNumber: number | null = isMovie ? null : this.season;
    const episodeNumber: number | null =
      isMovie ? null : (selected === null ? null : selected.episode_number);
    if (!isMovie && (seasonNumber === null || episodeNumber === null)) {
      return;
    }
    const request: TvPlayRequest = new TvPlayRequest(
      this.libraryId,
      this.itemId,
      seasonNumber,
      episodeNumber,
      this.selectedFileId,
      startMs,
      detail.title,
      isMovie ? null
        : TvFormat.episodeLine(seasonNumber ?? 0, episodeNumber ?? 0, selected === null ? null : (selected.name ?? null)),
      !isMovie
    );
    TvPlayback.begin(request);
    TvUiState.shared.openPlayer(request);
  }

  private playEpisode(ep: EpisodeView): void {
    const detail: LibraryItemDetailView | null = this.detail;
    const browseSeason: number | null = this.browseSeason;
    if (!ep.owned || detail === null || browseSeason === null) {
      return;
    }
    const request: TvPlayRequest = new TvPlayRequest(
      this.libraryId,
      this.itemId,
      browseSeason,
      ep.episode_number,
      null,
      null,
      detail.title,
      TvFormat.episodeLine(browseSeason, ep.episode_number, ep.name ?? null),
      true
    );
    TvPlayback.begin(request);
    TvUiState.shared.openPlayer(request);
  }

  // MARK: - 首屏派生

  private isTv(): boolean {
    const detail: LibraryItemDetailView | null = this.detail;
    return detail !== null && detail.kind === 'tv';
  }

  private canPlay(): boolean {
    const detail: LibraryItemDetailView | null = this.detail;
    if (detail === null) {
      return false;
    }
    if (detail.kind !== 'tv') {
      for (const file of detail.files) {
        if (file.state === 'in_place') {
          return true;
        }
      }
      return false;
    }
    const selected: EpisodeView | null = this.selectedEpisode;
    return selected !== null && selected.owned;
  }

  private unitLabel(): string | null {
    const detail: LibraryItemDetailView | null = this.detail;
    if (detail === null || detail.kind !== 'tv') {
      return null;
    }
    const seasonNumber: number | null = this.season;
    const selected: EpisodeView | null = this.selectedEpisode;
    if (seasonNumber === null || selected === null) {
      return null;
    }
    return seasonNumber === 0
      ? `特别篇第 ${selected.episode_number} 集`
      : `第 ${seasonNumber} 季第 ${selected.episode_number} 集`;
  }

  private stageActions(): TvStageAction[] {
    const detail: LibraryItemDetailView | null = this.detail;
    if (detail === null) {
      return [];
    }
    const watched: PlaybackStateView | null = this.watched;
    const position: number = watched === null ? 0 : watched.position_ms;
    const finished: boolean = watched !== null && watched.played;
    const canPlay: boolean = this.canPlay();
    const resumable: boolean = canPlay && position > 0;
    const verb: string = resumable ? '继续' : (finished ? '重新播放' : '播放');
    const parts: string[] = [verb];
    const unitLabel: string | null = this.unitLabel();
    if (unitLabel !== null) {
      parts.push(unitLabel);
    }
    if (resumable) {
      parts.push(clockOf(position));
    }
    const playLabel: string = parts.length > 2
      ? `${parts[0]} ${parts[1]} · ${parts[2]}` : parts.join(' ');
    const actions: TvStageAction[] = [];
    if (canPlay) {
      actions.push(new TvStageAction('play', playLabel, true,
        $r('sys.symbol.play_fill'), (): void => {
          this.play(null);
        }));
      if (resumable) {
        actions.push(new TvStageAction('restart', '从头播放', false,
          $r('sys.symbol.backward_end_fill'), (): void => {
            this.play(0);
          }));
      }
    }
    actions.push(new TvStageAction('favorite', this.favorite === true ? '已收藏' : '收藏', false,
      $r('sys.symbol.heart'), (): void => {
        this.toggleFavorite();
      }));
    if (canPlay) {
      actions.push(new TvStageAction('played', finished ? '已看完' : '标为已看', false,
        $r('sys.symbol.checkmark_circle'), (): void => {
          this.togglePlayed();
        }));
    }
    return actions;
  }

  private stageMetaLine(): string | null {
    const detail: LibraryItemDetailView | null = this.detail;
    if (detail === null) {
      return null;
    }
    const meta: LocalMetaView | null = detail.local_meta ?? null;
    const parts: string[] = [];
    if (detail.year !== null && detail.year !== undefined) {
      parts.push(`${detail.year}`);
    }
    const genres: string[] = meta === null ? [] : meta.genres;
    for (let i = 0; i < genres.length && i < 2; i++) {
      parts.push(genres[i]);
    }
    if (detail.kind !== 'tv') {
      const runtime: number | null = this.runtimeMinutes();
      if (runtime !== null && runtime > 0) {
        parts.push(TvFormat.duration(runtime));
      }
    } else {
      let seasonCount: number = 0;
      for (const s of detail.seasons) {
        if (s > 0) {
          seasonCount++;
        }
      }
      if (seasonCount >= 2) {
        parts.push(`共 ${seasonCount} 季`);
      }
    }
    return parts.length === 0 ? null : parts.join(' · ');
  }

  private runtimeMinutes(): number | null {
    const detail: LibraryItemDetailView | null = this.detail;
    if (detail === null) {
      return null;
    }
    const meta: LocalMetaView | null = detail.local_meta ?? null;
    if (meta !== null && meta.runtime_minutes !== null && meta.runtime_minutes !== undefined
      && meta.runtime_minutes > 0) {
      return meta.runtime_minutes;
    }
    for (const file of detail.files) {
      if (file.duration_seconds !== null && file.duration_seconds !== undefined
        && file.duration_seconds > 0) {
        return Math.round(file.duration_seconds / 60);
      }
    }
    return null;
  }

  private mediaBadgeTexts(): string[] {
    const detail: LibraryItemDetailView | null = this.detail;
    if (detail === null) {
      return [];
    }
    const sources: LibraryFileView[] = [];
    for (const file of detail.files) {
      if (file.state === 'in_place') {
        sources.push(file);
      }
    }
    const badges: string[] = [];
    let bestHeight: number = -1;
    for (const file of sources) {
      const height: number | null = resolutionHeightOf(file.resolution);
      if (height !== null && height > bestHeight) {
        bestHeight = height;
      }
    }
    if (bestHeight >= 4320) {
      badges.push('8K');
    } else if (bestHeight >= 2160) {
      badges.push('4K');
    } else if (bestHeight >= 720) {
      badges.push('HD');
    }
    const hdrPriority: string[] = ['HDR Vivid', 'Dolby Vision', 'HDR10+', 'HDR10', 'HLG', 'HDR'];
    let hdrText: string | null = null;
    let hdrRank: number = 99;
    for (const file of sources) {
      const raw: string = file.hdr ?? '';
      if (raw.length === 0) {
        continue;
      }
      const rank: number = hdrPriority.indexOf(raw);
      if (rank >= 0 && rank < hdrRank) {
        hdrRank = rank;
        hdrText = raw;
      } else if (rank < 0 && hdrText === null) {
        hdrText = raw;
      }
    }
    if (hdrText !== null) {
      badges.push(hdrText === 'Dolby Vision' ? 'DOLBY VISION' : hdrText.toUpperCase());
    }
    let audioVivid: boolean = false;
    let atmos: boolean = false;
    let dtsX: boolean = false;
    let maxChannels: number = -1;
    for (const file of sources) {
      const streams: AudioStreamView[] = file.audio_streams ?? [];
      for (const stream of streams) {
        const described: string =
          `${stream.profile ?? ''} ${stream.title ?? ''} ${stream.codec ?? ''}`.toLowerCase();
        if (described.includes('av3a') || described.includes('vivid')) {
          audioVivid = true;
        }
        if (described.includes('atmos')) {
          atmos = true;
        }
        if (described.includes('dts:x') || described.includes('dts-x')) {
          dtsX = true;
        }
        const channels: number = stream.channels ?? -1;
        if (channels > maxChannels) {
          maxChannels = channels;
        }
      }
    }
    if (audioVivid) {
      badges.push('AUDIO VIVID');
    } else if (atmos) {
      badges.push('DOLBY ATMOS');
    } else if (dtsX) {
      badges.push('DTS:X');
    } else if (maxChannels >= 8) {
      badges.push('7.1');
    } else if (maxChannels >= 6) {
      badges.push('5.1');
    }
    return badges;
  }

  private stageHeadline(): string | null {
    const detail: LibraryItemDetailView | null = this.detail;
    if (detail === null || detail.kind !== 'tv') {
      return null;
    }
    const seasonNumber: number | null = this.season;
    const selected: EpisodeView | null = this.selectedEpisode;
    if (seasonNumber === null || selected === null) {
      return null;
    }
    return TvFormat.episodeLine(seasonNumber, selected.episode_number, selected.name ?? null);
  }

  private stageOverview(): string | null {
    const detail: LibraryItemDetailView | null = this.detail;
    if (detail === null) {
      return null;
    }
    const meta: LocalMetaView | null = detail.local_meta ?? null;
    const plot: string | null = meta === null ? null : (meta.plot ?? null);
    if (detail.kind !== 'tv') {
      return plot;
    }
    const selected: EpisodeView | null = this.selectedEpisode;
    if (selected === null) {
      return plot;
    }
    const epOverview: string | null = selected.overview ?? null;
    return epOverview !== null && epOverview.length > 0 ? epOverview : plot;
  }

  private creditDirector(): string | null {
    for (const person of this.castPeople) {
      if (person.role === '导演') {
        return person.name;
      }
    }
    return null;
  }

  private creditActors(): string | null {
    const names: string[] = [];
    for (const person of this.castPeople) {
      if (person.role !== '导演') {
        names.push(person.name);
        if (names.length === 2) {
          break;
        }
      }
    }
    return names.length === 0 ? null : names.join('、');
  }

  // MARK: - 下半截派生与交互

  private seasonNumbers(): number[] {
    const detail: LibraryItemDetailView | null = this.detail;
    return detail === null ? [] : detail.seasons;
  }

  private selectRange(range: TvEpisodeRange): void {
    const anchor: number | null = this.browseAnchor;
    const entry: number = anchor !== null && range.contains(anchor) ? anchor : range.first;
    this.tryScrollToEpisode(entry, true);
  }

  private tryScrollToEpisode(episodeNumber: number, smooth: boolean): void {
    for (let i = 0; i < this.browseEpisodes.length; i++) {
      if (this.browseEpisodes[i].episode_number === episodeNumber) {
        try {
          this.episodeScroller.scrollToIndex(i, smooth);
        } catch (_error) {
        }
        return;
      }
    }
  }

  private epTitleOf(ep: EpisodeView): string {
    const name: string = (ep.name ?? '').trim();
    if (name.length === 0 || /^(第\s*\d+\s*集|Episode\s*\d+)$/i.test(name)) {
      return `第 ${ep.episode_number} 集`;
    }
    return `第 ${ep.episode_number} 集 · ${name}`;
  }

  private epStillUrl(ep: EpisodeView): string {
    const resolved: string | null =
      ImageUrls.resolve(AppModel.origin(), ep.still_url ?? null, ImageVariant.landscapeCard);
    if (resolved === null) {
      return '';
    }
    return `${resolved}${resolved.includes('?') ? '&' : '?'}w=${TvArt.pxWidth(TvMetrics.landscapeWidth)}`;
  }

  private epBadgeOf(ep: EpisodeView): string | null {
    if (!ep.owned) {
      return '缺集';
    }
    if (this.browseWatched && this.browseAnchor !== null && ep.episode_number === this.browseAnchor) {
      return '接着看';
    }
    if (ep.played) {
      return '已看';
    }
    return null;
  }

  private castCards(): TvShelfCard[] {
    const out: TvShelfCard[] = [];
    for (let i = 0; i < this.castPeople.length; i++) {
      const person: TvCastPerson = this.castPeople[i];
      const card: TvShelfCard = new TvShelfCard(`cast_${i}`, 'person', person.name);
      card.cardWidth = 133;
      card.role = person.role;
      if (person.avatarUrl !== '') {
        card.imageUrl =
          `${person.avatarUrl}${person.avatarUrl.includes('?') ? '&' : '?'}w=${TvArt.pxWidth(133)}`;
      }
      out.push(card);
    }
    return out;
  }

  private openCast(card: TvShelfCard): void {
    const index: number = Number(card.key.substring('cast_'.length));
    const person: TvCastPerson | undefined = this.castPeople[index];
    if (person === undefined) {
      return;
    }
    if (person.personId !== null) {
      TvUiState.shared.pushRoute(new TvPersonRoute(person.personId, person.name));
      return;
    }
    const actor: string = person.name.trim();
    if (!person.isActor || actor === '') {
      return;
    }
    let title: string = '媒体库';
    for (const library of LibraryHomeStore.shared.libraries ?? []) {
      if (library.id === this.libraryId) {
        title = library.name;
      }
    }
    TvUiState.shared.pushRoute(new TvWallRoute(this.libraryId, title, null, actor));
  }

  private similarCards(): TvShelfCard[] {
    const origin: string = AppModel.origin();
    const out: TvShelfCard[] = [];
    for (const item of this.similar) {
      out.push(TvShelfCard.fromItem(item, origin, false));
    }
    return out;
  }

  private openSimilar(card: TvShelfCard): void {
    const id: number = Number(card.key.substring('item_'.length));
    for (const item of this.similar) {
      if (item.media_item_id === id) {
        TvUiState.shared.pushRoute(
          new TvDetailRoute(item.library_id ?? this.libraryId, item.media_item_id));
        return;
      }
    }
  }

  private seriesTitle(): string {
    const series: CollectionSeriesView | null = this.series;
    return series === null ? '系列' : (series.series_name ?? '系列');
  }

  private seriesDetail(): string {
    const series: CollectionSeriesView | null = this.series;
    return series === null ? '' : `已有 ${series.owned_count} / 共 ${series.total}`;
  }

  private seriesCards(): TvShelfCard[] {
    const series: CollectionSeriesView | null = this.series;
    if (series === null) {
      return [];
    }
    const origin: string = AppModel.origin();
    const out: TvShelfCard[] = [];
    for (const part of series.parts) {
      const card: TvShelfCard = new TvShelfCard(`part_${part.tmdb_id}`, 'poster', part.title);
      const resolved: string | null = ImageUrls.resolve(origin, part.poster_url ?? null, null);
      card.imageUrl = resolved === null ? '' : `${resolved}${resolved.includes('?') ? '&' : '?'}w=${TvArt.pxWidth(TvMetrics.posterWidth)}`;
      card.subtitle = part.release_date !== null && part.release_date !== undefined
        ? part.release_date.substring(0, 4) : null;
      const missing: boolean = (part.media_item_id ?? null) === null;
      card.badge = part.media_item_id === this.itemId ? '本片' : (missing ? '未入库' : null);
      out.push(card);
    }
    return out;
  }

  private openSeriesPart(card: TvShelfCard): void {
    const series: CollectionSeriesView | null = this.series;
    if (series === null) {
      return;
    }
    const id: number = Number(card.key.substring('part_'.length));
    for (const part of series.parts) {
      if (part.tmdb_id !== id) {
        continue;
      }
      if (part.media_item_id === this.itemId) {
        this.mainScroller.scrollEdge(Edge.Top);
        return;
      }
      if (part.media_item_id !== null && part.media_item_id !== undefined) {
        TvUiState.shared.pushRoute(new TvDetailRoute(this.libraryId, part.media_item_id));
      }
      return;
    }
  }

  private otherCollections(): ItemCollectionRef[] {
    const detail: LibraryItemDetailView | null = this.detail;
    if (detail === null) {
      return [];
    }
    if (this.series === null) {
      return detail.collections;
    }
    const seriesId: number | null = detail.series_collection_id ?? null;
    if (seriesId === null) {
      return detail.collections;
    }
    return detail.collections.filter((ref: ItemCollectionRef): boolean => ref.id !== seriesId);
  }

  private detailTitle(): string {
    const detail: LibraryItemDetailView | null = this.detail;
    return detail === null ? '' : detail.title;
  }

  private heroBackdropUrl(): string {
    const detail: LibraryItemDetailView | null = this.detail;
    if (detail === null) {
      return '';
    }
    const resolved: string | null = ImageUrls.resolve(AppModel.origin(),
      detail.backdrop_url ?? detail.poster_url ?? null, null);
    return resolved === null ? '' : `${resolved}${resolved.includes('?') ? '&' : '?'}w=1920`;
  }

  private ambientUrl(): string {
    const detail: LibraryItemDetailView | null = this.detail;
    const raw: string | null = detail === null
      ? null : (detail.backdrop_url ?? detail.poster_url ?? null);
    const resolved: string | null = ImageUrls.resolve(AppModel.origin(), raw, null);
    return resolved === null ? '' : `${resolved}${resolved.includes('?') ? '&' : '?'}w=320`;
  }

  private logoUrl(): string {
    const detail: LibraryItemDetailView | null = this.detail;
    if (detail === null) {
      return '';
    }
    const resolved: string | null =
      ImageUrls.resolve(AppModel.origin(), detail.logo_url ?? null, null);
    return resolved === null ? '' : `${resolved}${resolved.includes('?') ? '&' : '?'}w=1900`;
  }

  private stageHeight(): number {
    return this.pageHeight > 0 ? this.pageHeight : TvMetrics.screenHeight;
  }

  private starCount(): number {
    if (this.userRating <= 0) {
      return 0;
    }
    return Math.min(5, Math.max(1, Math.round(this.userRating / 2)));
  }

  build() {
    Stack() {
      this.AmbientBackdrop()
      if (this.failed) {
        TvStateView({
          symbol: $r('sys.symbol.film'),
          title: '未能加载该条目',
          message: '条目可能已被删除或网络不可用。',
          actionTitle: '返回',
          defaultFocusAction: true,
          onAction: (): void => {
            TvUiState.shared.popRoute();
          }
        })
      } else if (this.detail === null) {
        Column() {
          LoadingProgress()
            .width(48)
            .height(48)
            .color(TvColors.textMuted)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll(this.mainScroller) {
          Column() {
            this.StageSection()
            this.LowerSection()
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .fadingEdge(false)
      }

      if (this.plotModalOpen && this.stageOverview() !== null) {
        this.PlotModal(this.stageOverview() as string)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(TvColors.bg)
    .onAreaChange((_oldArea: Area, newArea: Area): void => {
      const height = newArea.height;
      if (typeof height === 'number') {
        this.pageHeight = height;
      }
    })
  }

  @Builder
  private AmbientBackdrop() {
    Stack() {
      Stack() {
        RemoteImage({ url: this.ambientUrl(), placeholderText: '' })
      }
      .width('100%')
      .height('100%')
      .blur(24)
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0, 0, 0, 0.72)')
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private StageSection() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      TvStageBackdrop({ imageUrl: this.heroBackdropUrl() })
      TvStageBlock({
        title: this.detailTitle(),
        logoUrl: this.logoUrl(),
        headline: this.stageHeadline(),
        metaLine: this.stageMetaLine(),
        badgeTexts: this.mediaBadgeTexts(),
        overview: this.stageOverview(),
        overviewLines: 3,
        onOverviewActivate: (this.stageOverview() ?? '').length > 60 ? (): void => {
          this.plotModalOpen = true;
          setTimeout((): void => {
            TvFocus.request(this.getUIContext(), 'tv_plot_modal_close');
          }, 80);
        } : null,
        actions: this.stageActions(),
        defaultFocusFirstAction: true,
        bottomInset: 14
      })
      this.StageCredits()
    }
    .width('100%')
    .height(this.stageHeight())
  }

  @Builder
  private StageCredits() {
    Column({ space: 6 }) {
      if (this.creditDirector() !== null) {
        Text() {
          Span('导演  ')
            .fontColor(TvColors.textMuted)
          Span(this.creditDirector() ?? '')
            .fontColor(TvColors.text)
        }
        .fontSize(TvType.footnote)
        .maxLines(1)
      }
      if (this.creditActors() !== null) {
        Text() {
          Span('主演  ')
            .fontColor(TvColors.textMuted)
          Span(this.creditActors() ?? '')
            .fontColor(TvColors.text)
        }
        .fontSize(TvType.footnote)
        .maxLines(1)
      }
    }
    .alignItems(HorizontalAlign.Start)
    .constraintSize({ maxWidth: 340 })
    .margin({ right: TvMetrics.edge, bottom: 34 })
    .shadow({ radius: 8, color: 'rgba(0, 0, 0, 0.55)' })
  }

  @Builder
  private LowerSection() {
    Column({ space: TvMetrics.rowGap }) {
      // 多版本片源与五星个人评分控制带
      this.VersionAndRatingBar()

      if (this.isTv() && this.seasonNumbers().length > 0) {
        this.EpisodeSection()
      }
      if (this.castCards().length > 0) {
        TvShelf({
          title: '演职员',
          cards: this.castCards(),
          onActivate: (card: TvShelfCard): void => {
            this.openCast(card);
          }
        })
      }
      if (this.similarCards().length > 0) {
        TvShelf({
          title: '相似推荐',
          cards: this.similarCards(),
          onActivate: (card: TvShelfCard): void => {
            this.openSimilar(card);
          }
        })
      }
      if (this.series !== null) {
        TvShelf({
          title: this.seriesTitle(),
          detail: this.seriesDetail(),
          cards: this.seriesCards(),
          onActivate: (card: TvShelfCard): void => {
            this.openSeriesPart(card);
          }
        })
      }
      if (this.otherCollections().length > 0) {
        this.CollectionsRow()
      }
      Column()
        .height(TvMetrics.edge)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 24 })
  }

  @Builder
  private VersionAndRatingBar() {
    Column({ space: 18 }) {
      if (this.unitFiles().length > 1) {
        Column({ space: 10 }) {
          Text('片源版本选择')
            .fontSize(TvType.footnote)
            .fontWeight(600)
            .fontColor(TvColors.textMuted)
          Scroll() {
            Row({ space: 10 }) {
              DetailPill({
                label: '智能优选',
                selected: this.selectedFileId === null,
                onActivate: (): void => {
                  this.selectedFileId = null;
                }
              })
              ForEach(this.unitFiles(), (file: LibraryFileView) => {
                DetailPill({
                  label: fileVersionLabel(file),
                  selected: this.selectedFileId === file.id,
                  onActivate: (): void => {
                    this.selectedFileId = file.id;
                  }
                })
              }, (file: LibraryFileView) => `ver_${file.id}`)
            }
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
      }

      Row({ space: 10 }) {
        Text('我的评分')
          .fontSize(TvType.footnote)
          .fontWeight(600)
          .fontColor(TvColors.textMuted)
          .margin({ right: 6 })
        ForEach([1, 2, 3, 4, 5], (star: number) => {
          DetailPill({
            label: star <= this.starCount() ? `★ ${star * 2}分` : `☆ ${star * 2}分`,
            selected: star === this.starCount(),
            onActivate: (): void => {
              this.setRating(star);
            }
          })
        }, (star: number) => `star_${star}`)
      }
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: TvMetrics.edge, right: TvMetrics.edge })
  }

  @Builder
  private EpisodeSection() {
    Column({ space: 12 }) {
      this.SeasonTabs()
      if (this.browseRanges.length > 0) {
        this.RangeTabs()
      }
      this.EpisodeRow()
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private SeasonTabs() {
    Scroll() {
      Row({ space: 10 }) {
        ForEach(this.seasonNumbers(), (seasonNumber: number) => {
          DetailPill({
            label: seasonNumber === 0 ? '特别篇' : `第 ${seasonNumber} 季`,
            selected: seasonNumber === this.browseSeason,
            onActivate: (): void => {
              this.loadBrowse(seasonNumber);
            }
          })
        }, (seasonNumber: number) => `season_${seasonNumber}`)
      }
      .padding({ left: TvMetrics.edge, right: TvMetrics.edge })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .fadingEdge(false)
    .width('100%')
  }

  @Builder
  private RangeTabs() {
    Scroll() {
      Row({ space: 8 }) {
        ForEach(this.browseRanges, (range: TvEpisodeRange) => {
          DetailPill({
            label: range.label(),
            selected: this.browseAnchor !== null && range.contains(this.browseAnchor),
            onActivate: (): void => {
              this.selectRange(range);
            }
          })
        }, (range: TvEpisodeRange) => `range_${range.index}_${range.first}_${range.last}`)
      }
      .padding({ left: TvMetrics.edge, right: TvMetrics.edge })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .fadingEdge(false)
    .width('100%')
  }

  @Builder
  private EpisodeRow() {
    List({ space: TvMetrics.cardGap, scroller: this.episodeScroller }) {
      ForEach(this.browseEpisodes, (ep: EpisodeView) => {
        ListItem() {
          TvEpisodeCard({
            epTitle: this.epTitleOf(ep),
            imageUrl: this.epStillUrl(ep),
            progress: ep.position_ms > 0 ? (ep.progress_percent ?? 0) / 100 : 0,
            badge: this.epBadgeOf(ep),
            airDate: ep.owned ? (ep.air_date ?? null) : null,
            overview: ep.overview ?? null,
            onActivate: (): void => {
              this.playEpisode(ep);
            }
          })
        }
      }, (ep: EpisodeView) => `ep_${ep.episode_number}`)
    }
    .listDirection(Axis.Horizontal)
    .width('100%')
    .clip(false)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.None)
    .fadingEdge(false)
    .padding({ left: TvMetrics.edge, right: TvMetrics.edge })
  }

  @Builder
  private CollectionsRow() {
    Column({ space: 12 }) {
      Text('所属合集')
        .fontSize(TvType.rowTitle)
        .fontWeight(600)
        .fontColor(TvColors.textMuted)
      Row({ space: 10 }) {
        ForEach(this.otherCollections(), (ref: ItemCollectionRef) => {
          DetailPill({
            label: ref.name,
            onActivate: (): void => {
              TvUiState.shared.pushRoute(new TvCollectionRoute(ref.id, ref.name));
            }
          })
        }, (ref: ItemCollectionRef) => `col_${ref.id}`)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: TvMetrics.edge, right: TvMetrics.edge })
  }

  @Builder
  private PlotModal(plot: string) {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0, 0, 0, 0.76)')
        .onClick((): void => {
          this.plotModalOpen = false;
        })

      Column({ space: 20 }) {
        Text(this.detailTitle())
          .fontSize(TvType.playerTitle)
          .fontWeight(FontWeight.Bold)
          .fontColor(TvColors.text)
          .maxLines(1)
        Scroll() {
          Text(plot)
            .fontSize(20)
            .fontColor('rgba(243, 245, 249, 0.90)')
            .lineHeight(32)
        }
        .constraintSize({ maxHeight: 340 })
        .scrollBar(BarState.Off)

        TvPillButton({
          label: '关闭',
          prominent: true,
          focusKey: 'tv_plot_modal_close',
          defaultFocused: true,
          onActivate: (): void => {
            this.plotModalOpen = false;
          }
        })
      }
      .width(760)
      .padding({ left: 40, right: 40, top: 34, bottom: 30 })
      .borderRadius(26)
      .backgroundColor('rgba(16, 18, 26, 0.96)')
      .border({ width: 1, color: TvColors.lineStrong })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
  }
}
