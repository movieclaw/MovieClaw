/**
 * 车机条目详情页（US4，两截结构，对齐 TV 端 tv/detail/TvItemDetail.ets 的触屏裁剪版）：
 *
 * 首屏：剧照原图铺满 + 左下亮度渐变罩 + 文案块（Logo/片名、事实行、画质/HDR/音频小标签、
 * 「第 X 季第 Y 集」、简介三行）+ 操作按钮行（继续 第X季第Y集·mm:ss / 从头播放 / 收藏 /
 * 标为已看，全部触控目标 ≥48vp）+ 右下演职员两行 + 左上返回按钮。
 *
 * 下半截（整页下滑）：剧集 = 选季胶囊 + 分集卡横排（剧照+进度+集名+接着看/已看/缺集角标）；
 * 相似推荐行（电影以横向大卡呈现、剧集以海报卡呈现——「电影=横向卡」）；演职员行
 * （人物卡进影人路由）；页面底层垫同一张剧照的模糊版。系列/合集等重信息结构按 spec 简化省略。
 *
 * 数据：libraryItemsGet（详情+演职员）、libraryItemsListEpisodes（分集，锚点听服务端）、
 * playbackResume（主按钮三态：播放/继续/重新播放）、playbackMarksGet/Set（收藏/已看，即时反馈）。
 * 播放器关闭（playerRequest 置空）后重拉续播与分集刷新按钮。无片源：播放/已看置灰，可浏览可收藏。
 */
import { AppModel } from '../../common/AppModel';
import { MovieClawApi } from '../../api/Endpoints';
import {
  AudioStreamView,
  EpisodeView,
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
  CarDetailRoute,
  CarPersonRoute,
  CarPlayRequest,
  CarUiState
} from '../model/CarUiState';
import {
  CarEpisodeCard,
  CarFormat,
  CarPillButton,
  CarStateView
} from '../components/CarCards';
import { CarRowCard, CarShelf } from '../components/CarRows';
import { CarPlayback } from '../player/CarAvPlayerEngine';
import { CarArt } from '../theme/CarTheme';
import { CarColors } from '../theme/CarTheme';
import { CarMetrics } from '../theme/CarTheme';
import { CarType } from '../theme/CarTheme';

/** 相似推荐的轻量载体（@Local 数组元素用稳定类，key 回查业务字段） */
class LibraryItemViewLite {
  readonly mediaItemId: number;
  readonly libraryId: number;
  readonly title: string;
  readonly year: number | null;
  readonly posterUrl: string | null;
  readonly backdropUrl: string | null;

  constructor(mediaItemId: number, libraryId: number, title: string, year: number | null,
    posterUrl: string | null, backdropUrl: string | null) {
    this.mediaItemId = mediaItemId;
    this.libraryId = libraryId;
    this.title = title;
    this.year = year;
    this.posterUrl = posterUrl;
    this.backdropUrl = backdropUrl;
  }

  static of(view: LibraryItemView): LibraryItemViewLite {
    return new LibraryItemViewLite(
      view.media_item_id,
      view.library_id ?? 0,
      view.title,
      view.year ?? null,
      view.poster_url ?? null,
      view.backdrop_url ?? null);
  }
}

/** 首屏右下与演职员行共用的一位影人 */
class CarCastPerson {
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
class CarEpisodeRange {
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
function buildEpisodeRanges(episodes: EpisodeView[]): CarEpisodeRange[] {
  const size: number = 50;
  if (episodes.length <= size) {
    return [];
  }
  const numbers: number[] = [];
  for (const ep of episodes) {
    numbers.push(ep.episode_number);
  }
  numbers.sort((a: number, b: number): number => a - b);
  const out: CarEpisodeRange[] = [];
  for (const n of numbers) {
    const index: number = Math.floor(Math.max(0, n - 1) / size);
    const last: CarEpisodeRange | undefined = out[out.length - 1];
    if (last !== undefined && last.index === index) {
      out[out.length - 1] = new CarEpisodeRange(index, last.first, n);
    } else {
      out.push(new CarEpisodeRange(index, n, n));
    }
  }
  return out;
}

/** 详情的演职员：结构化导演在前（没有退回姓名），演员跟着 */
function castPeopleOf(detail: LibraryItemDetailView, origin: string): CarCastPerson[] {
  const meta: LocalMetaView | null = detail.local_meta ?? null;
  if (meta === null) {
    return [];
  }
  const out: CarCastPerson[] = [];
  if (meta.director_credits.length > 0) {
    for (const dir of meta.director_credits) {
      out.push(new CarCastPerson(dir.name, '导演',
        ImageUrls.resolve(origin, dir.thumb_url ?? null, null) ?? '', dir.tmdb_person_id));
    }
  } else {
    for (const name of meta.directors) {
      out.push(new CarCastPerson(name, '导演', '', null));
    }
  }
  for (const actor of meta.actors) {
    const role: string | null = actor.role ?? null;
    out.push(new CarCastPerson(actor.name,
      role === null ? null : `饰 ${role}`,
      ImageUrls.resolve(origin, actor.thumb_url ?? null, null) ?? '',
      actor.tmdb_person_id ?? null));
  }
  return out;
}

/** 小胶囊（选季 / 分段页签）：选中的垫浅底，触控目标 ≥48vp */
@ComponentV2
struct CarDetailPill {
  @Param label: string = '';
  @Param selected: boolean = false;
  @Param onActivate: (() => void) | null = null;
  @Local pressed: boolean = false;

  build() {
    Row() {
      Text(this.label)
        .fontSize(CarType.footnote)
        .fontWeight(600)
        .fontColor(this.selected ? CarColors.text : CarColors.textMuted)
        .maxLines(1)
    }
    .padding({ left: 22, right: 22 })
    .constraintSize({ minHeight: CarMetrics.minTouch })
    .justifyContent(FlexAlign.Center)
    .borderRadius(999)
    .backgroundColor(this.pressed ? CarColors.glassFillHover
      : (this.selected ? CarColors.accentSoft : 'rgba(255, 255, 255, 0.06)'))
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down) {
        this.pressed = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressed = false;
      }
    })
    .onClick((): void => {
      const cb = this.onActivate;
      if (cb !== null) {
        cb();
      }
    })
  }
}

@ComponentV2
export struct CarItemDetail {
  @Param libraryId: number = 0;
  @Param itemId: number = 0;
  @Local ui: CarUiState = CarUiState.shared;

  // —— 数据 ——
  @Local detail: LibraryItemDetailView | null = null;
  @Local failed: boolean = false;
  @Local favorite: boolean | null = null;
  /** 首屏当前单元（整部片 / 接着看的那一集）的续播态 */
  @Local watched: PlaybackStateView | null = null;
  /** 首屏那一季与它的锚点集 */
  @Local season: number | null = null;
  @Local selectedEpisode: EpisodeView | null = null;
  /** 下半截正在浏览的季（选季胶囊只切这里，首屏不变） */
  @Local browseSeason: number | null = null;
  @Local browseEpisodes: EpisodeView[] = [];
  @Local browseAnchor: number | null = null;
  @Local browseRanges: CarEpisodeRange[] = [];
  /** 本季有人看过才亮「接着看」角标 */
  @Local browseWatched: boolean = false;
  @Local similar: LibraryItemViewLite[] = [];
  @Local castPeople: CarCastPerson[] = [];
  @Local pageHeight: number = 0;

  private marking: boolean = false;
  /** 本条目在本页起播过（播放器关闭后据此重拉续播） */
  private playedHere: boolean = false;
  private episodeScroller: Scroller = new Scroller();
  private mainScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.reload();
  }

  /** 播放器开/关：关的是本条目这一次播放 → 重拉续播与分集 */
  @Monitor('ui.playerRequest')
  onPlayerRequestChange(): void {
    const request: CarPlayRequest | null = this.ui.playerRequest;
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
      // 相似推荐并行拉
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

  /** 相似推荐（电影且有待拉系列时简化省略系列结构，只拉相似） */
  private async loadRelated(api: MovieClawApi, fresh: LibraryItemDetailView): Promise<void> {
    const similarTask: Promise<LibraryItemViewLite[]> = this.fetchSimilar(api, fresh);
    const items: LibraryItemViewLite[] = await similarTask;
    this.similar = items;
  }

  private async fetchSimilar(api: MovieClawApi,
    fresh: LibraryItemDetailView): Promise<LibraryItemViewLite[]> {
    try {
      const isMovie: boolean = fresh.kind !== 'tv';
      const seriesId: number | null = isMovie ? (fresh.series_collection_id ?? null) : null;
      const views = await api.uiLibraryItemsSimilar(this.libraryId, this.itemId,
        undefined, seriesId !== null ? true : undefined);
      const out: LibraryItemViewLite[] = [];
      for (const view of views) {
        out.push(LibraryItemViewLite.of(view));
      }
      return out;
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

  // MARK: - 起播（US5 前占位承接：打开播放器覆盖层，引擎 T016/T018 接入）

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
    const request: CarPlayRequest = new CarPlayRequest(
      this.libraryId,
      this.itemId,
      seasonNumber,
      episodeNumber,
      null,
      startMs,
      detail.title,
      isMovie ? null
        : CarFormat.episodeLine(seasonNumber ?? 0, episodeNumber ?? 0, selected === null ? null : (selected.name ?? null)),
      this.coverFor(isMovie, selected),
      !isMovie);
    // playback-first：按下播放先预建会话（不等播放器视图挂载）
    CarPlayback.begin(request);
    CarUiState.shared.openPlayer(request);
  }

  /** 下半截点一张分集卡起播那一集（缺集不可点） */
  private playEpisode(ep: EpisodeView): void {
    const detail: LibraryItemDetailView | null = this.detail;
    const browseSeason: number | null = this.browseSeason;
    if (!ep.owned || detail === null || browseSeason === null) {
      return;
    }
    const request: CarPlayRequest = new CarPlayRequest(
      this.libraryId,
      this.itemId,
      browseSeason,
      ep.episode_number,
      null,
      null,
      detail.title,
      CarFormat.episodeLine(browseSeason, ep.episode_number, ep.name ?? null),
      this.coverFor(false, ep),
      true);
    // playback-first：按下播放先预建会话（不等播放器视图挂载）
    CarPlayback.begin(request);
    CarUiState.shared.openPlayer(request);
  }

  /** mini 条封面：剧集取分集剧照，电影取背景图，再回落海报 */
  private coverFor(isMovie: boolean, episode: EpisodeView | null): string {
    const detail: LibraryItemDetailView | null = this.detail;
    if (detail === null) {
      return '';
    }
    const raw: string | null = isMovie
      ? (detail.backdrop_url ?? detail.poster_url ?? null)
      : ((episode !== null ? (episode.still_url ?? null) : null)
        ?? detail.backdrop_url ?? detail.poster_url ?? null);
    return ImageUrls.resolve(AppModel.origin(), raw, null) ?? '';
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

  /** 主按钮文案：「继续 第 1 季第 3 集 · 12:34」/「播放」/「重新播放」 */
  private playLabel(): string {
    const watched: PlaybackStateView | null = this.watched;
    const position: number = watched === null ? 0 : watched.position_ms;
    const finished: boolean = watched !== null && watched.played;
    const verb: string = position > 0 ? '继续' : (finished ? '重新播放' : '播放');
    const parts: string[] = [verb];
    const unitLabel: string | null = this.unitLabel();
    if (unitLabel !== null) {
      parts.push(unitLabel);
    }
    if (position > 0) {
      parts.push(clockOf(position));
    }
    return parts.length > 2 ? `${parts[0]} ${parts[1]} · ${parts[2]}` : parts.join(' ');
  }

  private resumable(): boolean {
    const watched: PlaybackStateView | null = this.watched;
    return this.canPlay() && watched !== null && watched.position_ms > 0;
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
        parts.push(CarFormat.duration(runtime));
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
    return CarFormat.episodeLine(seasonNumber, selected.episode_number, selected.name ?? null);
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

  private selectRange(range: CarEpisodeRange): void {
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
    return `${resolved}${resolved.includes('?') ? '&' : '?'}w=${CarArt.pxWidth(CarMetrics.landscapeBigWidth)}`;
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
  private castCards(): CarRowCard[] {
    const out: CarRowCard[] = [];
    for (let i = 0; i < this.castPeople.length; i++) {
      const person: CarCastPerson = this.castPeople[i];
      const card: CarRowCard = new CarRowCard(`cast_${i}`, 'person', person.name);
      card.cardWidth = 160;
      card.role = person.role;
      if (person.avatarUrl !== '') {
        card.imageUrl =
          `${person.avatarUrl}${person.avatarUrl.includes('?') ? '&' : '?'}w=${CarArt.pxWidth(160)}`;
      }
      out.push(card);
    }
    return out;
  }

  private openCast(card: CarRowCard): void {
    const index: number = Number(card.key.substring('cast_'.length));
    const person: CarCastPerson | undefined = this.castPeople[index];
    if (person === undefined || person.personId === null) {
      return;
    }
    CarUiState.shared.pushRoute(new CarPersonRoute(person.personId, person.name));
  }

  /** 相似推荐：电影以横向大卡呈现（宽屏画布上 16:9 更耐看），剧集以海报卡呈现 */
  private similarCards(): CarRowCard[] {
    const origin: string = AppModel.origin();
    const out: CarRowCard[] = [];
    const isMovie: boolean = !this.isTv();
    for (const item of this.similar) {
      const card: CarRowCard = new CarRowCard(`item_${item.mediaItemId}`, isMovie ? 'landscape' : 'poster', item.title);
      if (isMovie) {
        card.cardWidth = CarMetrics.landscapeBigWidth;
        card.imageUrl = CarRowCard.sizedUrl(
          ImageUrls.resolve(origin, item.backdropUrl ?? item.posterUrl ?? null,
            ImageVariant.landscapeCard), CarMetrics.landscapeBigWidth);
      } else {
        card.imageUrl = CarRowCard.sizedUrl(
          ImageUrls.resolve(origin, item.posterUrl ?? item.backdropUrl ?? null, null),
          CarMetrics.posterWidth);
      }
      card.subtitle = item.year !== null ? `${item.year}` : null;
      out.push(card);
    }
    return out;
  }

  private openSimilar(card: CarRowCard): void {
    const id: number = Number(card.key.substring('item_'.length));
    for (const item of this.similar) {
      if (item.mediaItemId === id) {
        CarUiState.shared.pushRoute(
          new CarDetailRoute(item.libraryId > 0 ? item.libraryId : this.libraryId, item.mediaItemId));
        return;
      }
    }
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
    return resolved === null ? '' : `${resolved}${resolved.includes('?') ? '&' : '?'}w=1200`;
  }

  build() {
    Stack() {
      this.AmbientBackdrop()
      if (this.failed) {
        CarStateView({
          symbol: $r('sys.symbol.film'),
          title: '未能加载该条目',
          message: '条目可能已被删除或网络不可用。',
          actionTitle: '返回',
          onAction: (): void => {
            CarUiState.shared.popRoute();
          }
        })
      } else if (this.detail === null) {
        Column() {
          LoadingProgress()
            .width(48)
            .height(48)
            .color(CarColors.textMuted)
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
    .backgroundColor(CarColors.bg)
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

  /** 首屏：剧照原图铺满 + 左下渐变罩与文案块 + 右下演职员 + 左上返回 */
  @Builder
  private StageSection() {
    Stack({ alignContent: Alignment.BottomStart }) {
      Stack() {
        RemoteImage({ url: this.heroBackdropUrl(), placeholderText: this.detailTitle() })
      }
      .width('100%')
      .height('100%')

      // 左下亮度渐变罩：文案块压得住
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [['rgba(0, 0, 0, 0)', 0.28], ['rgba(0, 0, 0, 0.45)', 0.6], ['rgba(0, 0, 0, 0.88)', 1]]
        })

      // 左上返回
      Stack() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(24)
          .fontColor([CarColors.text])
      }
      .width(CarMetrics.minTouch)
      .height(CarMetrics.minTouch)
      .borderRadius(999)
      .backgroundColor(CarColors.glassFill)
      .position({ x: CarMetrics.edge, y: 22 })
      .onClick((): void => {
        CarUiState.shared.popRoute();
      })

      this.StageInfo()
      this.StageCredits()
    }
    .width('100%')
    .height(this.pageHeight > 0 ? this.pageHeight : 600)
  }

  /** 左下文案块：Logo/标题 → 集数行 → 事实行 → 小标签 → 简介 → 操作按钮行 */
  @Builder
  private StageInfo() {
    Column({ space: 10 }) {
      if (this.logoUrl() !== '') {
        Row() {
          RemoteImage({ url: this.logoUrl(), fit: true, placeholderText: '' })
        }
        .constraintSize({ maxWidth: 560, maxHeight: 76 })
        .alignItems(VerticalAlign.Top)
      } else {
        Text(this.detailTitle())
          .fontSize(CarType.heroTitle)
          .fontWeight(FontWeight.Bold)
          .fontColor(CarColors.text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: 700 })
      }
      if (this.stageHeadline() !== null) {
        Text(this.stageHeadline() ?? '')
          .fontSize(CarType.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(CarColors.text)
          .maxLines(1)
      }
      if (this.stageMetaLine() !== null) {
        Text(this.stageMetaLine() ?? '')
          .fontSize(CarType.footnote)
          .fontColor(CarColors.textMuted)
          .maxLines(1)
      }
      if (this.mediaBadgeTexts().length > 0) {
        Row({ space: 8 }) {
          ForEach(this.mediaBadgeTexts(), (badge: string) => {
            Text(badge)
              .fontSize(11)
              .fontWeight(FontWeight.Bold)
              .fontColor(CarColors.text)
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .backgroundColor('rgba(255, 255, 255, 0.16)')
              .borderRadius(6)
          }, (badge: string) => badge)
        }
      }
      if (this.stageOverview() !== null) {
        Text(this.stageOverview() ?? '')
          .fontSize(CarType.footnote)
          .fontColor(CarColors.textMuted)
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: 640 })
      }
      this.StageActions()
    }
    .alignItems(HorizontalAlign.Start)
    .padding({ left: CarMetrics.edge, right: 24, bottom: 26 })
    .width('100%')
    .constraintSize({ maxWidth: 860 })
  }

  /** 操作按钮行：继续/播放（无片源置灰） / 从头播放 / 收藏 / 标为已看（全部 ≥48vp） */
  @Builder
  private StageActions() {
    Row({ space: 12 }) {
      CarPillButton({
        label: this.playLabel(),
        symbol: $r('sys.symbol.play_fill'),
        filled: true,
        disabled: !this.canPlay(),
        onActivate: (): void => {
          this.play(null);
        }
      })
      if (this.resumable()) {
        CarPillButton({
          label: '从头播放',
          symbol: $r('sys.symbol.backward_end_fill'),
          onActivate: (): void => {
            this.play(0);
          }
        })
      }
      CarPillButton({
        label: this.favorite === true ? '已收藏' : '收藏',
        symbol: this.favorite === true ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'),
        onActivate: (): void => {
          this.toggleFavorite();
        }
      })
      CarPillButton({
        label: this.watched !== null && this.watched.played ? '已看完' : '标为已看',
        symbol: $r('sys.symbol.checkmark_circle'),
        disabled: !this.canPlay(),
        onActivate: (): void => {
          this.togglePlayed();
        }
      })
    }
    .alignItems(VerticalAlign.Center)
    .margin({ top: 4 })
  }

  /** 右下角演职员两行（导演 / 主演） */
  @Builder
  private StageCredits() {
    Column({ space: 6 }) {
      if (this.creditDirector() !== null) {
        Text() {
          Span('导演  ')
            .fontColor(CarColors.textMuted)
          Span(this.creditDirector() ?? '')
            .fontColor(CarColors.text)
        }
        .fontSize(CarType.footnote)
        .maxLines(1)
      }
      if (this.creditActors() !== null) {
        Text() {
          Span('主演  ')
            .fontColor(CarColors.textMuted)
          Span(this.creditActors() ?? '')
            .fontColor(CarColors.text)
        }
        .fontSize(CarType.footnote)
        .maxLines(1)
      }
    }
    .alignItems(HorizontalAlign.Start)
    .constraintSize({ maxWidth: 320 })
    .position({ x: '100%', y: '100%' })
    .markAnchor({ x: '100%', y: '100%' })
    .offset({ x: -CarMetrics.edge, y: -34 })
    .shadow({ radius: 8, color: 'rgba(0, 0, 0, 0.55)' })
  }

  /** 下半截：分集（剧集）→ 演职员 → 相似推荐（系列/合集按 spec 简化省略） */
  @Builder
  private LowerSection() {
    Column({ space: CarMetrics.rowGap }) {
      if (this.isTv() && this.seasonNumbers().length > 0) {
        this.EpisodeSection()
      }
      if (this.castCards().length > 0) {
        CarShelf({
          title: '演职员',
          cards: this.castCards(),
          onActivate: (card: CarRowCard): void => {
            this.openCast(card);
          }
        })
      }
      if (this.similarCards().length > 0) {
        CarShelf({
          title: '相似推荐',
          cards: this.similarCards(),
          onActivate: (card: CarRowCard): void => {
            this.openSimilar(card);
          }
        })
      }
      Column()
        .height(CarMetrics.edge)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 8 })
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

  /** 选季胶囊：点哪一季，下面横排就换成那一季（首屏那一季不动） */
  @Builder
  private SeasonTabs() {
    Scroll() {
      Row({ space: 10 }) {
        ForEach(this.seasonNumbers(), (seasonNumber: number) => {
          CarDetailPill({
            label: seasonNumber === 0 ? '特别篇' : `第 ${seasonNumber} 季`,
            selected: seasonNumber === this.browseSeason,
            onActivate: (): void => {
              this.loadBrowse(seasonNumber);
            }
          })
        }, (seasonNumber: number) => `season_${seasonNumber}`)
      }
      .padding({ left: CarMetrics.edge, right: CarMetrics.edge })
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
        ForEach(this.browseRanges, (range: CarEpisodeRange) => {
          CarDetailPill({
            label: range.label(),
            selected: this.browseAnchor !== null && range.contains(this.browseAnchor),
            onActivate: (): void => {
              this.selectRange(range);
            }
          })
        }, (range: CarEpisodeRange) => `range_${range.index}_${range.first}_${range.last}`)
      }
      .padding({ left: CarMetrics.edge, right: CarMetrics.edge })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .fadingEdge(false)
    .width('100%')
  }

  @Builder
  private EpisodeRow() {
    List({ space: CarMetrics.cardGap, scroller: this.episodeScroller }) {
      ForEach(this.browseEpisodes, (ep: EpisodeView) => {
        ListItem() {
          CarEpisodeCard({
            epTitle: this.epTitleOf(ep),
            imageUrl: this.epStillUrl(ep),
            cardWidth: CarMetrics.landscapeBigWidth,
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
    .edgeEffect(EdgeEffect.Spring)
    .fadingEdge(false)
    .padding({ left: CarMetrics.edge, right: CarMetrics.edge })
  }
}
