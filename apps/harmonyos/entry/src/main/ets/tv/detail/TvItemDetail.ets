/**
 * TV 条目详情页（US3，两截结构，对应参考端 Library/TVItemDetailView.swift）：
 *
 * 首屏：剧照原图铺满 + 左下文案块（Logo/片名、事实行、画质/HDR/音频小标签、
 * 「第 X 季第 Y 集」、简介三行）+ 按钮行（继续 第X季第Y集·mm:ss / 从头播放 /
 * 收藏 / 标为已看）+ 右下演职员两行；首屏比整页矮 60vp，露出下一截上沿提示下方有内容。
 *
 * 下半截（整页下滑）：片名 → 选季胶囊（长剧集再加分段页签）→ 分集卡横排
 * （剧照+进度+集名+首播+接着看/已看/缺集角标）→ 演职员行（人物卡可进影人路由）→
 * 相似推荐 → 作品系列「已有 n / 共 m」→ 所属合集文字按钮；页面底层垫同一张剧照的模糊版。
 *
 * 数据：libraryItemsGet（详情+演职员）、libraryItemsListEpisodes（分集，锚点听服务端）、
 * playbackResume（主按钮三态：播放/继续/重新播放）、playbackMarksGet/Set（收藏/已看）、
 * uiLibraryItemsSimilar + collectionSeriesGet（相似推荐与作品系列，同 ItemRelated 规则）。
 * 播放器关闭（playerRequest 置空）后重拉续播与分集刷新按钮（FR-015）。
 */
import { AppModel } from '../../common/AppModel';
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
import { ImageUrls } from '../../common/ImageUrls';
import { ImageVariant } from '../../common/ImageUrls';
import { LibraryHomeStore } from '../../library/LibraryHomeStore';
import { RemoteImage } from '../../common/RemoteImage';
import {
  TvCollectionRoute,
  TvDetailRoute,
  TvPersonRoute,
  TvPlayRequest,
  TvUiState
} from '../model/TvUiState';
import { TvStageAction, TvStageBackdrop, TvStageBlock } from '../components/TvStage';
import { TvEpisodeCard, TvFormat, TvStateView } from '../components/TvCards';
import { TvShelf, TvShelfCard } from '../components/TvShelf';
import { TvFocusable } from '../components/TvFocusable';
import { TvPlayback } from '../player/TvAvPlayerEngine';
import { TvColors } from '../theme/TvTheme';
import { TvMetrics } from '../theme/TvTheme';
import { TvType } from '../theme/TvTheme';
import { TvArt } from '../theme/TvTheme';

/** 首屏右下与演职员行共用的一位影人 */
class TvCastPerson {
  readonly name: string;
  readonly role: string | null;
  readonly avatarUrl: string;
  readonly personId: number | null;

  constructor(name: string, role: string | null, avatarUrl: string, personId: number | null) {
    this.name = name;
    this.role = role;
    this.avatarUrl = avatarUrl;
    this.personId = personId;
  }
}

/** 长剧集分段选集的一段（每 50 集一段，docs/design/long-season-episode-ranges.md） */
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

/** 「2160p」「4K」「8K」→ 画面高度；解析不出返回 null */
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

/** 毫秒 → 「mm:ss」 */
function clockOf(ms: number): string {
  const total: number = Math.floor(ms / 1000);
  const minutes: number = Math.floor(total / 60);
  const seconds: number = total % 60;
  return `${minutes}:${seconds < 10 ? '0' : ''}${seconds}`;
}

/** 本季接着看的那一集（客户端兜底：看了一半的 → 第一个没看过有片源的 → 第一集） */
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

/** 服务端锚点优先（resume_episode），没有走客户端规则 */
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

/** 一季的段：超过 50 集才分段（界面保持原样），段名用段内实际首末集号 */
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

/** 详情的演职员：结构化导演在前（没有退回姓名），演员跟着（同参考端 castPeople） */
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
      actor.tmdb_person_id ?? null));
  }
  return out;
}

/** 小胶囊（选季 / 分段页签 / 所属合集文字按钮）：选中的垫浅底，获焦白底黑字微放大 */
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

  // —— 数据 ——
  @Local detail: LibraryItemDetailView | null = null;
  @Local failed: boolean = false;
  @Local favorite: boolean | null = null;
  /** 首屏当前单元（整部片 / 接着看的那一集）的续播态 */
  @Local watched: PlaybackStateView | null = null;
  /** 首屏那一季与它的锚点集 */
  @Local season: number | null = null;
  @Local selectedEpisode: EpisodeView | null = null;
  @Local episodes: EpisodeView[] = [];
  /** 下半截正在浏览的季（选季胶囊只切这里，首屏不变） */
  @Local browseSeason: number | null = null;
  @Local browseEpisodes: EpisodeView[] = [];
  @Local browseAnchor: number | null = null;
  @Local browseRanges: TvEpisodeRange[] = [];
  /** 本季有人看过才亮「接着看」角标 */
  @Local browseWatched: boolean = false;
  @Local similar: LibraryItemView[] = [];
  @Local series: CollectionSeriesView | null = null;
  @Local castPeople: TvCastPerson[] = [];
  @Local pageHeight: number = 0;

  private marking: boolean = false;
  /** 本条目在本页起播过（播放器关闭后据此重拉续播） */
  private playedHere: boolean = false;
  private episodeScroller: Scroller = new Scroller();
  private mainScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.reload();
  }

  /** 播放器开/关：关的是本条目这一次播放 → 重拉续播与分集（FR-015） */
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

  // MARK: - 加载

  private async reload(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      this.failed = true;
      return;
    }
    this.loadFavorite(api);
    try {
      const fresh: LibraryItemDetailView = await api.libraryItemsGet(this.libraryId, this.itemId);
      // 相似推荐与系列并行拉（同 ItemRelated 规则）
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
      // 分集读完再出页面（先出会闪「没有可播放的分集」）
      await related;
      this.detail = fresh;
      this.castPeople = castPeopleOf(fresh, AppModel.origin());
      this.failed = false;
      this.loadResume();
      const anchor: number | null = this.browseAnchor;
      if (anchor !== null) {
        setTimeout((): void => {
          this.tryScrollToEpisode(anchor, false);
        }, 120);
      }
    } catch (error) {
      if (this.detail === null) {
        this.failed = true;
      }
    }
  }

  /** 相似推荐 + 作品系列（电影且有系列合集时相似推荐排除同系列；系列没出来再拉一次不排除的） */
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
      } catch (error) {
        series = null;
      }
    }
    let items: LibraryItemView[] = [];
    try {
      items = await similarTask;
    } catch (error) {
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
    } catch (error) {
      return [];
    }
  }

  /** 首屏打开哪一季：「接下来继续」里的那一季优先，别的开第一个有片源的季 */
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

  /** 下半截换一季（首屏那一季不动） */
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
    } catch (error) {
    }
  }

  private async loadFavorite(api: MovieClawApi): Promise<void> {
    try {
      const marks: PlaybackMarksView = await api.playbackMarksGet(this.itemId);
      this.favorite = marks.is_favorite;
    } catch (error) {
    }
  }

  /** 首屏当前单元的续播态（主按钮三态：播放/继续 mm:ss/重新播放） */
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
    } catch (error) {
      this.watched = null;
    }
  }

  /** 播放器关闭后：锚点可能挪了（看完了这一集），首屏与横排跟到新锚点 */
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
    } catch (error) {
      return;
    }
    if (this.browseSeason !== null && this.browseSeason !== seasonNumber) {
      const browseNumber: number = this.browseSeason;
      try {
        const result: SeasonEpisodesView =
          await api.libraryItemsListEpisodes(this.libraryId, this.itemId, browseNumber);
        this.applyBrowseResult(result);
      } catch (error) {
      }
    }
  }

  // MARK: - 写操作（收藏 / 标为已看，即时反馈）

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
    } catch (error) {
      this.favorite = !next;
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
        } catch (error) {
        }
      }
    } catch (error) {
    } finally {
      this.marking = false;
    }
  }

  // MARK: - 起播

  /** 首屏主按钮起播：startMs null = 续播（服务端决定），0 = 从头 */
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
    // playback-first：先建引擎预协商，再挂播放器视图（视图 adopt 接管）
    const request: TvPlayRequest = new TvPlayRequest(
      this.libraryId,
      this.itemId,
      seasonNumber,
      episodeNumber,
      null,
      startMs,
      detail.title,
      isMovie ? null
        : TvFormat.episodeLine(seasonNumber ?? 0, episodeNumber ?? 0, selected === null ? null : (selected.name ?? null)),
      !isMovie);
    TvPlayback.begin(request);
    TvUiState.shared.openPlayer(request);
  }

  /** 下半截点一张分集卡起播那一集（缺集不可点） */
  private playEpisode(ep: EpisodeView): void {
    const detail: LibraryItemDetailView | null = this.detail;
    const browseSeason: number | null = this.browseSeason;
    if (!ep.owned || detail === null || browseSeason === null) {
      return;
    }
    // playback-first：先建引擎预协商，再挂播放器视图（视图 adopt 接管）
    const request: TvPlayRequest = new TvPlayRequest(
      this.libraryId,
      this.itemId,
      browseSeason,
      ep.episode_number,
      null,
      null,
      detail.title,
      TvFormat.episodeLine(browseSeason, ep.episode_number, ep.name ?? null),
      true);
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

  /** 主按钮上的「第 1 季第 3 集」；特别篇写「特别篇第 2 集」 */
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

  /** 事实行：年份 · 类型（前两个） · 片长（电影）/ 共 X 季（剧集两季以上） */
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

  /** 画质 / HDR / 音频小标签：在位文件里各挑最好的那一档 */
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
    const hdrPriority: string[] = ['Dolby Vision', 'HDR10+', 'HDR10', 'HLG', 'HDR'];
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
      }
    }
    if (hdrText !== null) {
      badges.push(hdrText === 'Dolby Vision' ? 'DOLBY VISION' : hdrText.toUpperCase());
    }
    let atmos: boolean = false;
    let dtsX: boolean = false;
    let maxChannels: number = -1;
    for (const file of sources) {
      const streams: AudioStreamView[] = file.audio_streams ?? [];
      for (const stream of streams) {
        const described: string =
          `${stream.profile ?? ''} ${stream.title ?? ''} ${stream.codec ?? ''}`.toLowerCase();
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
    if (atmos) {
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

  /** 简介：电影写整部，剧集写接着看的那一集（没有退整部） */
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

  /** 右下演职员：导演一行、主演两位一行；没有不画 */
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
        } catch (error) {
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

  /** 演职员行的人物卡 */
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
    if (person === undefined || person.personId === null) {
      return;
    }
    TvUiState.shared.pushRoute(new TvPersonRoute(person.personId, person.name));
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

  /** 系列一行：按上映顺序排，这一部标「本片」，库里没有的标「未入库」 */
  private seriesCards(): TvShelfCard[] {
    const series: CollectionSeriesView | null = this.series;
    if (series === null) {
      return [];
    }
    const origin: string = AppModel.origin();
    const out: TvShelfCard[] = [];
    for (const part of series.parts) {
      const card: TvShelfCard = new TvShelfCard(`part_${part.tmdb_id}`, 'poster', part.title);
      const resolved: string | null =
        ImageUrls.resolve(origin, part.poster_url ?? null, null);
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

  /** 「所属合集」里不再列系列本身：上面已经有系列一行 */
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

  // MARK: - 布局

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

  /** 页面底层垫的剧照模糊版（下滑后露出来） */
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

  /** 首屏比整页矮 60vp：底部露出下一截的上沿，提示下面还有内容 */
  private stageHeight(): number {
    // 首屏铺满整屏（用户要求：详情就是满屏大图，不在底边露下一截）
    return this.pageHeight > 0 ? this.pageHeight : TvMetrics.screenHeight;
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
    }
    .width('100%')
    .height('100%')
    .backgroundColor(TvColors.bg)
    .onAreaChange((oldArea: Area, newArea: Area): void => {
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

  /** 首屏：剧照原图铺满 + 文案块贴底 + 右下演职员 */
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
        actions: this.stageActions(),
        defaultFocusFirstAction: true,
        bottomInset: 14
      })
      this.StageCredits()
    }
    .width('100%')
    .height(this.stageHeight())
  }

  /** 右下角演职员两行（导演 / 主演），下沿与按钮一排对齐 */
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

  /** 下半截：分集（剧集）→ 演职员 → 相似推荐 → 系列 → 所属合集 */
  @Builder
  private LowerSection() {
    Column({ space: TvMetrics.rowGap }) {
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
  }

  /** 分集区：选季胶囊（长剧集再加分段页签）+ 分集卡横排 */
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

  /** 选季胶囊：焦点/点击切到哪一季，下面横排就换成那一季（首屏那一季不动） */
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

  /** 分段页签（长剧集）：点哪一段，横排跳到那一段的入口集（锚点或段首） */
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

  /** 所属合集：一排文字按钮，按下进那个合集 */
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
}
