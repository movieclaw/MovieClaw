/**
 * 车机横滑内容行（对应 TV 端 tv/components/TvShelf.ets 的触屏版）：
 * - 行标题 + 横滑卡片 List + 「查看全部」尾卡（行数据超一屏时由调用方开 onSeeAll）；
 * - 行内卡片按 CarRowCard 数据渲染（海报卡/横版大卡/分集卡/库卡/类型卡/人物卡），
 *   数据 → 卡片的工厂（fromUpNext/fromItem/...）集中在这里，页面只管把行数据拍成数组；
 * - 触屏模型：无焦点加亮/焦点放大（TV 的 clip(false) 是为焦点放大留的余量，触屏按压缩放不外溢）。
 */
import { CarColors } from '../theme/CarTheme';
import { CarMetrics } from '../theme/CarTheme';
import { CarType } from '../theme/CarTheme';
import { CarArt } from '../theme/CarTheme';
import { ImageUrls } from '../../common/ImageUrls';
import { ImageVariant } from '../../common/ImageUrls';
import {
  CollectionView,
  FavoriteItemView,
  LibraryItemView,
  LibraryKindGenreView,
  LibraryView,
  PersonView,
  UpNextItemView
} from '../../api/Models';
import {
  CarEpisodeCard,
  CarFormat,
  CarGenreCard,
  CarLandscapeCard,
  CarLibraryCard,
  CarPersonCard,
  CarPosterCard,
  CarSeeAllCard
} from './CarCards';

/**
 * 一行里的一张卡：CarShelf 按数据渲染行内卡片，页面把行数据（继续观看/收藏/库/类型/影人）
 * 拍成 CarRowCard[] 传进来。key 行内唯一（页面按它回查业务对象取路由参数）。
 */
export class CarRowCard {
  readonly key: string;
  /** poster | landscape | episode | library | genre | person */
  readonly kind: string;
  readonly title: string;
  subtitle: string | null = null;
  imageUrl: string = '';
  cardWidth: number = CarMetrics.posterWidth;
  /** 0～1 观看进度 */
  progress: number = 0;
  badge: string | null = null;
  /** 横版卡底部暗带的一行说明 */
  detail: string | null = null;
  note: string | null = null;
  count: number = 0;
  collection: boolean = false;
  mediaKind: string = 'movie';
  role: string | null = null;
  airDate: string | null = null;
  overview: string | null = null;
  worksCount: number = 0;

  constructor(key: string, kind: string, title: string) {
    this.key = key;
    this.kind = kind;
    this.title = title;
  }

  /** 解析好的 URL 再按显示宽度补 &w=（后端按 w 降采样出图；px 档位见 CarArt） */
  static sizedUrl(url: string | null, vpWidth: number): string {
    if (url === null) {
      return '';
    }
    const px: number = CarArt.pxWidth(vpWidth);
    return `${url}${url.includes('?') ? '&' : '?'}w=${px}`;
  }

  /** 「接下来继续」的横版大卡：分集剧照 + 进度 + 「S2 E6 · 剩 18 分钟」暗带 */
  static fromUpNext(item: UpNextItemView, origin: string): CarRowCard {
    const isEpisode: boolean = item.kind === 'tv';
    const stillRaw: string | null = isEpisode
      ? (item.episode_still_url ?? item.backdrop_url ?? null)
      : (item.backdrop_url ?? item.poster_url ?? null);
    const card: CarRowCard = new CarRowCard(`upnext_${item.media_item_id}`, 'landscape', item.title);
    card.cardWidth = CarMetrics.landscapeBigWidth;
    card.imageUrl = CarRowCard.sizedUrl(
      ImageUrls.resolve(origin, stillRaw, ImageVariant.landscapeCard), CarMetrics.landscapeBigWidth);
    card.subtitle = CarRowCard.upNextSubtitle(item);
    card.progress = (item.progress_percent ?? 0) / 100;
    card.badge = item.advanced ? '下一集' : null;
    card.detail = CarRowCard.upNextBand(item);
    return card;
  }

  /** 卡片底部暗带里的紧凑写法（口径同 TV 端 upNextBand） */
  private static upNextBand(item: UpNextItemView): string | null {
    const parts: string[] = [];
    if (item.kind === 'tv') {
      parts.push(`S${item.season_number} E${item.episode_number}`);
    }
    if (item.position_ms > 0) {
      const remaining: string | null = CarFormat.remaining(item.position_ms, item.duration_ms ?? null);
      if (remaining !== null) {
        parts.push(remaining);
      }
    } else if (item.duration_ms !== null && item.duration_ms !== undefined && item.duration_ms >= 60000) {
      parts.push(CarFormat.duration(item.duration_ms / 60000));
    }
    return parts.length === 0 ? null : parts.join(' · ');
  }

  /** 图下副标题（口径同 TV 端 upNextSubtitle） */
  private static upNextSubtitle(item: UpNextItemView): string | null {
    const parts: string[] = [];
    if (item.kind === 'tv') {
      parts.push(`第 ${item.season_number} 季 第 ${item.episode_number} 集`);
    }
    if (item.position_ms > 0) {
      const remaining: string | null = CarFormat.remaining(item.position_ms, item.duration_ms ?? null);
      if (remaining !== null) {
        parts.push(remaining);
      }
    }
    return parts.length === 0 ? null : parts.join(' · ');
  }

  /** 收藏行的横版大卡（spec AC2：收藏以可横滑的大卡行展示，点击进详情） */
  static fromFavorite(item: FavoriteItemView, origin: string): CarRowCard {
    const card: CarRowCard = new CarRowCard(`fav_${item.media_item_id}`, 'landscape', item.title);
    card.cardWidth = CarMetrics.landscapeBigWidth;
    card.imageUrl = CarRowCard.sizedUrl(
      ImageUrls.resolve(origin, item.backdrop_url ?? item.poster_url ?? null,
        ImageVariant.landscapeCard), CarMetrics.landscapeBigWidth);
    card.subtitle = item.year !== null && item.year !== undefined ? `${item.year}` : null;
    return card;
  }

  /** 海报行的海报卡（最近添加/合集成员/相似推荐……） */
  static fromItem(item: LibraryItemView, origin: string): CarRowCard {
    const card: CarRowCard = new CarRowCard(`item_${item.media_item_id}`, 'poster', item.title);
    card.imageUrl = CarRowCard.sizedUrl(
      ImageUrls.resolve(origin, item.poster_url ?? item.backdrop_url ?? null, null), CarMetrics.posterWidth);
    card.subtitle = item.year !== null && item.year !== undefined ? `${item.year}` : null;
    return card;
  }

  /** 「我的媒体库」行的库卡（服务端 21:10 拼贴封面） */
  static fromLibrary(library: LibraryView, origin: string): CarRowCard {
    const card: CarRowCard = new CarRowCard(`library_${library.id}`, 'library', library.name);
    card.cardWidth = CarMetrics.libraryCardWidth;
    card.count = library.stats.item_count;
    card.imageUrl = CarRowCard.sizedUrl(
      ImageUrls.resolve(origin, `/libraries/${library.id}/cover`, null), CarMetrics.libraryCardWidth);
    return card;
  }

  /** 「我的媒体库」行里接在库后面的合集卡（虚拟库卡片） */
  static fromCollection(collection: CollectionView, origin: string): CarRowCard {
    const card: CarRowCard = new CarRowCard(`collection_${collection.id}`, 'library', collection.name);
    card.cardWidth = CarMetrics.libraryCardWidth;
    card.count = collection.item_count;
    card.collection = true;
    card.imageUrl = CarRowCard.sizedUrl(
      ImageUrls.resolve(origin, `/collections/${collection.id}/cover`, null), CarMetrics.libraryCardWidth);
    return card;
  }

  /** 「按类型找」行的类型卡 */
  static fromGenre(genre: LibraryKindGenreView, kind: string, origin: string): CarRowCard {
    const card: CarRowCard = new CarRowCard(`genre_${kind}_${genre.value}`, 'genre', genre.label);
    card.cardWidth = CarMetrics.landscapeBigWidth;
    card.count = genre.count;
    card.mediaKind = kind;
    card.imageUrl = CarRowCard.sizedUrl(
      ImageUrls.resolve(origin, genre.cover_url ?? null, ImageVariant.landscapeCard),
      CarMetrics.landscapeBigWidth);
    return card;
  }

  /** 演职员行的人物卡（作品数取 PersonView.credits 数量） */
  static fromPerson(person: PersonView, role: string | null, origin: string): CarRowCard {
    const card: CarRowCard = new CarRowCard(`person_${person.tmdb_person_id}`, 'person', person.name);
    card.cardWidth = 160;
    card.role = role;
    card.worksCount = person.credits.length;
    card.imageUrl = CarRowCard.sizedUrl(
      ImageUrls.resolve(origin, person.avatar_url ?? null, null), 160);
    return card;
  }

  /** 分集卡（详情页选集横排） */
  static fromEpisode(key: string, epTitle: string, stillRaw: string | null, origin: string,
    progress: number, badge: string | null, airDate: string | null, overview: string | null): CarRowCard {
    const card: CarRowCard = new CarRowCard(key, 'episode', epTitle);
    card.cardWidth = CarMetrics.landscapeBigWidth;
    card.imageUrl = CarRowCard.sizedUrl(
      ImageUrls.resolve(origin, stillRaw, ImageVariant.landscapeCard), CarMetrics.landscapeBigWidth);
    card.progress = progress;
    card.badge = badge;
    card.airDate = airDate;
    card.overview = overview;
    return card;
  }
}

/** 一行横滑内容：行标题 + 横滑卡片 List + 「查看全部」尾卡 */
@ComponentV2
export struct CarShelf {
  @Param title: string = '';
  /** 标题右侧的说明（如「12 部」） */
  @Param detail: string | null = null;
  @Param cards: CarRowCard[] = [];
  /** 「查看全部」尾卡上写的总数；不显示尾卡时忽略 */
  @Param seeAllTotal: number | null = null;
  /** 是否显示「查看全部」尾卡（回调 onSeeAll 必须非空才可点） */
  @Param seeAll: boolean = false;
  @Param onActivate: ((card: CarRowCard) => void) | null = null;
  @Param onSeeAll: (() => void) | null = null;

  /** 尾卡与该行卡片同宽 */
  private seeAllWidth(): number {
    const first: CarRowCard | undefined = this.cards[0];
    return first === undefined ? CarMetrics.posterWidth : first.cardWidth;
  }

  /** 尾卡高度比跟随行内卡片形状 */
  private seeAllRatio(): number {
    const first: CarRowCard | undefined = this.cards[0];
    if (first === undefined) {
      return 1.5;
    }
    if (first.kind === 'landscape' || first.kind === 'episode' || first.kind === 'genre') {
      return 9 / 16;
    }
    if (first.kind === 'library') {
      return 9 / 16;
    }
    if (first.kind === 'person') {
      return 1.5;
    }
    return 1.5;
  }

  build() {
    Column() {
      Row({ space: 10 }) {
        Text(this.title)
          .fontSize(CarType.rowTitle)
          .fontWeight(600)
          .fontColor(CarColors.text)
          .maxLines(1)
        if (this.detail !== null) {
          Text(this.detail)
            .fontSize(CarType.footnote)
            .fontColor(CarColors.textFaint)
            .maxLines(1)
        }
      }
      .width('100%')
      .padding({ left: CarMetrics.edge, right: CarMetrics.edge })
      .alignItems(VerticalAlign.Bottom)

      List({ space: CarMetrics.cardGap }) {
        ForEach(this.cards, (card: CarRowCard) => {
          ListItem() {
            this.CardFace(card)
          }
        }, (card: CarRowCard) => card.key)

        if (this.seeAll) {
          ListItem() {
            CarSeeAllCard({
              total: this.seeAllTotal,
              cardWidth: this.seeAllWidth(),
              heightRatio: this.seeAllRatio(),
              onActivate: (): void => {
                const cb = this.onSeeAll;
                if (cb !== null) {
                  cb();
                }
              }
            })
          }
        }
      }
      .listDirection(Axis.Horizontal)
      .width('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .fadingEdge(false)
      .padding({ left: CarMetrics.edge, right: CarMetrics.edge })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 按数据分派到具体卡片组件 */
  @Builder
  private CardFace(card: CarRowCard) {
    if (card.kind === 'landscape') {
      CarLandscapeCard({
        title: card.title,
        subtitle: card.subtitle,
        imageUrl: card.imageUrl,
        cardWidth: card.cardWidth,
        progress: card.progress,
        badge: card.badge,
        detail: card.detail,
        onActivate: (): void => {
          const cb = this.onActivate;
          if (cb !== null) {
            cb(card);
          }
        }
      })
    } else if (card.kind === 'episode') {
      CarEpisodeCard({
        epTitle: card.title,
        imageUrl: card.imageUrl,
        cardWidth: card.cardWidth,
        progress: card.progress,
        badge: card.badge,
        airDate: card.airDate,
        overview: card.overview,
        onActivate: (): void => {
          const cb = this.onActivate;
          if (cb !== null) {
            cb(card);
          }
        }
      })
    } else if (card.kind === 'library') {
      CarLibraryCard({
        name: card.title,
        count: card.count,
        imageUrl: card.imageUrl,
        collection: card.collection,
        cardWidth: card.cardWidth,
        onActivate: (): void => {
          const cb = this.onActivate;
          if (cb !== null) {
            cb(card);
          }
        }
      })
    } else if (card.kind === 'genre') {
      CarGenreCard({
        label: card.title,
        count: card.count,
        mediaKind: card.mediaKind,
        imageUrl: card.imageUrl,
        cardWidth: card.cardWidth,
        onActivate: (): void => {
          const cb = this.onActivate;
          if (cb !== null) {
            cb(card);
          }
        }
      })
    } else if (card.kind === 'person') {
      CarPersonCard({
        name: card.title,
        role: card.role,
        imageUrl: card.imageUrl,
        worksCount: card.worksCount,
        cardWidth: card.cardWidth,
        onActivate: (): void => {
          const cb = this.onActivate;
          if (cb !== null) {
            cb(card);
          }
        }
      })
    } else {
      CarPosterCard({
        title: card.title,
        subtitle: card.subtitle,
        imageUrl: card.imageUrl,
        cardWidth: card.cardWidth,
        progress: card.progress,
        badge: card.badge,
        note: card.note,
        onActivate: (): void => {
          const cb = this.onActivate;
          if (cb !== null) {
            cb(card);
          }
        }
      })
    }
  }
}
