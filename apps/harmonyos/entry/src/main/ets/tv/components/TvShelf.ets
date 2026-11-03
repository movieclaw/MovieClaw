/**
 * TV 横滑内容行（对应参考端 DesignSystem/TVCards.swift 的 TVShelf + Home/TVHomeView 的行装配）：
 * - 行标题随行内焦点加亮（有卡拿到焦点行标题就点亮，全部让出就压暗）；
 * - 横滑 List（clip(false)：焦点放大与浮动片名画进行间空隙，不被行边缘裁掉）；
 * - 方向键在行间移动按几何就近落点（ArkUI 焦点系统默认行为，即「焦点分区最近落点」）；
 * - 「查看全部」尾卡：行数据超一屏时由调用方开 onSeeAll，尾卡与该行卡片同大小。
 *
 * 行内卡片按 TvShelfCard 数据渲染（海报卡/横版剧照卡/分集卡/库卡/类型卡/人物卡），
 * 数据 → 卡片的工厂（fromUpNext/fromItem/...）集中在这里，页面只管把行数据拍成数组。
 */
import { TvColors } from '../theme/TvTheme';
import { TvMetrics } from '../theme/TvTheme';
import { TvType } from '../theme/TvTheme';
import { TvMotion } from '../theme/TvTheme';
import { TvArt } from '../theme/TvTheme';
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
  TvCardCaption,
  TvEpisodeCard,
  TvFormat,
  TvGenreCard,
  TvLandscapeCard,
  TvLibraryCard,
  TvPersonCard,
  TvPosterCard,
  TvSeeAllCard
} from './TvCards';

/**
 * 一行里的一张卡：TvShelf 按数据渲染行内卡片，页面把行数据（继续观看/收藏/库/类型/影人）
 * 拍成 TvShelfCard[] 传进来。key 行内唯一（焦点上报与大图防抖都靠它）。
 */
export class TvShelfCard {
  readonly key: string;
  /** poster | landscape | episode | library | genre | person */
  readonly kind: string;
  readonly title: string;
  subtitle: string | null = null;
  imageUrl: string = '';
  cardWidth: number = TvMetrics.posterWidth;
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
  caption: string = TvCardCaption.focused;
  defaultFocused: boolean = false;
  /** requestFocus 定位 key（页签锚点；每屏至多一处） */
  focusKey: string = '';

  constructor(key: string, kind: string, title: string) {
    this.key = key;
    this.kind = kind;
    this.title = title;
  }

  /** 解析好的 URL 再按显示宽度补 &w=（后端按 w 降采样出图；等价参考端 api.image(width:)） */
  private static sized(url: string | null, vpWidth: number): string {
    if (url === null) {
      return '';
    }
    const px: number = TvArt.pxWidth(vpWidth);
    return `${url}${url.includes('?') ? '&' : '?'}w=${px}`;
  }

  /** 「接下来继续」的横版卡：分集剧照 + 进度 + 「S2 E6 · 剩 18 分钟」暗带 */
  static fromUpNext(item: UpNextItemView, origin: string, defaultFocused: boolean): TvShelfCard {
    const isEpisode: boolean = item.kind === 'tv';
    const stillRaw: string | null = isEpisode
      ? (item.episode_still_url ?? item.backdrop_url ?? null)
      : (item.backdrop_url ?? item.poster_url ?? null);
    const card: TvShelfCard = new TvShelfCard(`upnext_${item.media_item_id}`, 'landscape', item.title);
    card.cardWidth = TvMetrics.landscapeWidth;
    card.imageUrl = TvShelfCard.sized(
      ImageUrls.resolve(origin, stillRaw, ImageVariant.landscapeCard), TvMetrics.landscapeWidth);
    card.subtitle = TvShelfCard.upNextSubtitle(item);
    card.progress = (item.progress_percent ?? 0) / 100;
    card.badge = item.advanced ? '下一集' : null;
    card.detail = TvShelfCard.upNextBand(item);
    card.caption = TvCardCaption.always;
    card.defaultFocused = defaultFocused;
    return card;
  }

  /** 卡片底部暗带里的紧凑写法（同参考端 TVHomeView.upNextBand） */
  private static upNextBand(item: UpNextItemView): string | null {
    const parts: string[] = [];
    if (item.kind === 'tv') {
      parts.push(`S${item.season_number} E${item.episode_number}`);
    }
    if (item.position_ms > 0) {
      const remaining: string | null = TvFormat.remaining(item.position_ms, item.duration_ms ?? null);
      if (remaining !== null) {
        parts.push(remaining);
      }
    } else if (item.duration_ms !== null && item.duration_ms !== undefined && item.duration_ms >= 60000) {
      parts.push(TvFormat.duration(item.duration_ms / 60000));
    }
    return parts.length === 0 ? null : parts.join(' · ');
  }

  /** 图下副标题（同参考端 TVHomeView.upNextSubtitle） */
  private static upNextSubtitle(item: UpNextItemView): string | null {
    const parts: string[] = [];
    if (item.kind === 'tv') {
      parts.push(`第 ${item.season_number} 季 第 ${item.episode_number} 集`);
    }
    if (item.position_ms > 0) {
      const remaining: string | null = TvFormat.remaining(item.position_ms, item.duration_ms ?? null);
      if (remaining !== null) {
        parts.push(remaining);
      }
    }
    return parts.length === 0 ? null : parts.join(' · ');
  }

  /** 海报行的海报卡（最近添加/收藏/合集成员/相似推荐……） */
  static fromItem(item: LibraryItemView, origin: string, defaultFocused: boolean): TvShelfCard {
    const card: TvShelfCard = new TvShelfCard(`item_${item.media_item_id}`, 'poster', item.title);
    card.imageUrl = TvShelfCard.sized(
      ImageUrls.resolve(origin, item.poster_url ?? item.backdrop_url ?? null, null), TvMetrics.posterWidth);
    card.subtitle = item.year !== null && item.year !== undefined ? `${item.year}` : null;
    card.caption = TvCardCaption.focused;
    card.defaultFocused = defaultFocused;
    return card;
  }

  /** 收藏行的海报卡（FavoriteItemView 与 LibraryItemView 字段同名） */
  static fromFavorite(item: FavoriteItemView, origin: string, defaultFocused: boolean): TvShelfCard {
    const card: TvShelfCard = new TvShelfCard(`fav_${item.media_item_id}`, 'poster', item.title);
    card.imageUrl = TvShelfCard.sized(
      ImageUrls.resolve(origin, item.poster_url ?? item.backdrop_url ?? null, null), TvMetrics.posterWidth);
    card.subtitle = item.year !== null && item.year !== undefined ? `${item.year}` : null;
    card.caption = TvCardCaption.focused;
    card.defaultFocused = defaultFocused;
    return card;
  }

  /** 「我的媒体库」行的库卡（服务端 21:10 拼贴封面） */
  static fromLibrary(library: LibraryView, origin: string, defaultFocused: boolean): TvShelfCard {
    const card: TvShelfCard = new TvShelfCard(`library_${library.id}`, 'library', library.name);
    card.cardWidth = TvMetrics.libraryCardWidth;
    card.count = library.stats.item_count;
    card.imageUrl = TvShelfCard.sized(
      ImageUrls.resolve(origin, `/libraries/${library.id}/cover`, null), TvMetrics.libraryCardWidth);
    card.defaultFocused = defaultFocused;
    return card;
  }

  /** 「我的媒体库」行里接在库后面的合集卡（虚拟库卡片） */
  static fromCollection(collection: CollectionView, origin: string, defaultFocused: boolean): TvShelfCard {
    const card: TvShelfCard = new TvShelfCard(`collection_${collection.id}`, 'library', collection.name);
    card.cardWidth = TvMetrics.libraryCardWidth;
    card.count = collection.item_count;
    card.collection = true;
    card.imageUrl = TvShelfCard.sized(
      ImageUrls.resolve(origin, `/collections/${collection.id}/cover`, null), TvMetrics.libraryCardWidth);
    card.defaultFocused = defaultFocused;
    return card;
  }

  /** 「按类型找」行的类型卡 */
  static fromGenre(genre: LibraryKindGenreView, kind: string, origin: string,
    defaultFocused: boolean): TvShelfCard {
    const card: TvShelfCard = new TvShelfCard(`genre_${kind}_${genre.value}`, 'genre', genre.label);
    card.cardWidth = TvMetrics.landscapeWidth;
    card.count = genre.count;
    card.mediaKind = kind;
    card.imageUrl = TvShelfCard.sized(
      ImageUrls.resolve(origin, genre.cover_url ?? null, ImageVariant.landscapeCard),
      TvMetrics.landscapeWidth);
    card.defaultFocused = defaultFocused;
    return card;
  }

  /** 演职员行的人物卡 */
  static fromPerson(person: PersonView, role: string | null, origin: string,
    defaultFocused: boolean): TvShelfCard {
    const card: TvShelfCard = new TvShelfCard(`person_${person.tmdb_person_id}`, 'person', person.name);
    card.cardWidth = 133;
    card.role = role;
    card.imageUrl = TvShelfCard.sized(
      ImageUrls.resolve(origin, person.avatar_url ?? null, null), 133);
    card.defaultFocused = defaultFocused;
    return card;
  }

  /** 分集卡（详情页选集横排） */
  static fromEpisode(key: string, epTitle: string, stillRaw: string | null, origin: string,
    progress: number, badge: string | null, airDate: string | null, overview: string | null,
    defaultFocused: boolean): TvShelfCard {
    const card: TvShelfCard = new TvShelfCard(key, 'episode', epTitle);
    card.cardWidth = TvMetrics.landscapeWidth;
    card.imageUrl = TvShelfCard.sized(
      ImageUrls.resolve(origin, stillRaw, ImageVariant.landscapeCard), TvMetrics.landscapeWidth);
    card.progress = progress;
    card.badge = badge;
    card.airDate = airDate;
    card.overview = overview;
    card.defaultFocused = defaultFocused;
    return card;
  }
}

/** 一行横滑内容：行标题（随行内焦点加亮）+ 横滑卡片 List + 「查看全部」尾卡 */
@ComponentV2
export struct TvShelf {
  @Param title: string = '';
  /** 标题右侧的说明（如「12 部」） */
  @Param detail: string | null = null;
  @Param cards: TvShelfCard[] = [];
  /** 「查看全部」尾卡上写的总数；不显示尾卡时忽略 */
  @Param seeAllTotal: number | null = null;
  /** 是否显示「查看全部」尾卡（回调 onSeeAll 必须非空才可点） */
  @Param seeAll: boolean = false;
  @Param onActivate: ((card: TvShelfCard) => void) | null = null;
  /** 行内卡片焦点变化上报（首页大图区防抖跟随靠它） */
  @Param onCardFocus: ((card: TvShelfCard, active: boolean) => void) | null = null;
  @Param onSeeAll: (() => void) | null = null;

  @Local rowFocused: boolean = false;
  private activeKeys: Set<string> = new Set<string>();

  private cardFocused(card: TvShelfCard, active: boolean): void {
    if (active) {
      this.activeKeys.add(card.key);
    } else {
      this.activeKeys.delete(card.key);
    }
    this.rowFocused = this.activeKeys.size > 0;
    const cb = this.onCardFocus;
    if (cb !== null) {
      cb(card, active);
    }
  }

  private activate(card: TvShelfCard): void {
    const cb = this.onActivate;
    if (cb !== null) {
      cb(card);
    }
  }

  /** 尾卡与该行卡片同宽 */
  private seeAllWidth(): number {
    const first: TvShelfCard | undefined = this.cards[0];
    return first === undefined ? TvMetrics.posterWidth : first.cardWidth;
  }

  /** 尾卡高度比跟随行内卡片形状 */
  private seeAllRatio(): number {
    const first: TvShelfCard | undefined = this.cards[0];
    if (first === undefined) {
      return 1.5;
    }
    if (first.kind === 'landscape' || first.kind === 'genre' || first.kind === 'library') {
      return 9 / 16;
    }
    return 1.5;
  }

  build() {
    Column() {
      Row({ space: 10 }) {
        Text(this.title)
          .fontSize(TvType.rowTitle)
          .fontWeight(600)
          .fontColor(this.rowFocused ? TvColors.text : TvColors.textMuted)
          .maxLines(1)
          .animation({ duration: TvMotion.focusMs, curve: Curve.EaseOut })
        if (this.detail !== null) {
          Text(this.detail)
            .fontSize(TvType.footnote)
            .fontColor(TvColors.textFaint)
            .maxLines(1)
        }
      }
      .width('100%')
      .padding({ left: TvMetrics.edge, right: TvMetrics.edge })
      .alignItems(VerticalAlign.Bottom)

      List({ space: TvMetrics.cardGap }) {
        ForEach(this.cards, (card: TvShelfCard) => {
          ListItem() {
            this.CardFace(card)
          }
        }, (card: TvShelfCard) => card.key)

        if (this.seeAll) {
          ListItem() {
            TvSeeAllCard({
              total: this.seeAllTotal,
              cardWidth: this.seeAllWidth(),
              heightRatio: this.seeAllRatio(),
              onActivate: (): void => {
                const cb = this.onSeeAll;
                if (cb !== null) {
                  cb();
                }
              },
              onFocusGained: (active: boolean): void => {
                if (active) {
                  this.activeKeys.add('seeAll');
                } else {
                  this.activeKeys.delete('seeAll');
                }
                this.rowFocused = this.activeKeys.size > 0;
              }
            })
          }
        }
      }
      .listDirection(Axis.Horizontal)
      .width('100%')
      .clip(false)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.None)
      .fadingEdge(false)
      .padding({ left: TvMetrics.edge, right: TvMetrics.edge })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 按数据分派到具体卡片组件 */
  @Builder
  private CardFace(card: TvShelfCard) {
    if (card.kind === 'landscape') {
      TvLandscapeCard({
        title: card.title,
        subtitle: card.subtitle,
        imageUrl: card.imageUrl,
        cardWidth: card.cardWidth,
        progress: card.progress,
        badge: card.badge,
        detail: card.detail,
        caption: card.caption,
        defaultFocused: card.defaultFocused,
        focusKey: card.focusKey,
        onActivate: (): void => {
          this.activate(card);
        },
        onFocusGained: (active: boolean): void => {
          this.cardFocused(card, active);
        }
      })
    } else if (card.kind === 'episode') {
      TvEpisodeCard({
        epTitle: card.title,
        imageUrl: card.imageUrl,
        cardWidth: card.cardWidth,
        progress: card.progress,
        badge: card.badge,
        airDate: card.airDate,
        overview: card.overview,
        defaultFocused: card.defaultFocused,
        onActivate: (): void => {
          this.activate(card);
        },
        onFocusGained: (active: boolean): void => {
          this.cardFocused(card, active);
        }
      })
    } else if (card.kind === 'library') {
      TvLibraryCard({
        name: card.title,
        count: card.count,
        imageUrl: card.imageUrl,
        collection: card.collection,
        cardWidth: card.cardWidth,
        defaultFocused: card.defaultFocused,
        focusKey: card.focusKey,
        onActivate: (): void => {
          this.activate(card);
        },
        onFocusGained: (active: boolean): void => {
          this.cardFocused(card, active);
        }
      })
    } else if (card.kind === 'genre') {
      TvGenreCard({
        label: card.title,
        count: card.count,
        mediaKind: card.mediaKind,
        imageUrl: card.imageUrl,
        cardWidth: card.cardWidth,
        defaultFocused: card.defaultFocused,
        focusKey: card.focusKey,
        onActivate: (): void => {
          this.activate(card);
        },
        onFocusGained: (active: boolean): void => {
          this.cardFocused(card, active);
        }
      })
    } else if (card.kind === 'person') {
      TvPersonCard({
        name: card.title,
        role: card.role,
        imageUrl: card.imageUrl,
        cardWidth: card.cardWidth,
        defaultFocused: card.defaultFocused,
        onActivate: (): void => {
          this.activate(card);
        },
        onFocusGained: (active: boolean): void => {
          this.cardFocused(card, active);
        }
      })
    } else {
      TvPosterCard({
        title: card.title,
        subtitle: card.subtitle,
        imageUrl: card.imageUrl,
        cardWidth: card.cardWidth,
        progress: card.progress,
        badge: card.badge,
        caption: card.caption,
        note: card.note,
        defaultFocused: card.defaultFocused,
        focusKey: card.focusKey,
        onActivate: (): void => {
          this.activate(card);
        },
        onFocusGained: (active: boolean): void => {
          this.cardFocused(card, active);
        }
      })
    }
  }
}
