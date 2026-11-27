/**
 * TV 大屏发现页（鸿蒙智慧屏独占页签，超越 Apple TV 缺失的多源榜单发现能力）：
 * - 顶部四视角切换胶囊（电影 · TMDB / 剧集 · TMDB / 电影 · 豆瓣 / 剧集 · 豆瓣），磁盘快照秒开；
 * - 全屏联动 TvStageBackdrop + TvStageBlock：焦点停在任一榜单海报，背景与简介即刻跟随；
 * - 已入库作品支持客厅一键起播/进详情，未入库作品支持遥控器一键智能订阅。
 */
import { AppModel } from '../../common/AppModel';
import { ImageUrls } from '../../common/ImageUrls';
import { Permissions } from '../../common/Permissions';
import { MovieClawApi } from '../../api/Endpoints';
import {
  DiscoveredTitleView,
  DiscoveryPageView,
  LibraryView,
  MediaKind,
  MediaSource,
  PrepareView,
  SubscriptionCreatePayload,
  SubscriptionView
} from '../../api/Models';
import {
  DiscoverFailure,
  DiscoverFeed,
  DiscoverRow,
  DiscoverRowState,
  DiscoverStore
} from '../../discover/DiscoverStore';
import { TvCardCaption, TvStateView } from '../components/TvCards';
import { TvFocus } from '../components/TvFocus';
import { TvFocusable } from '../components/TvFocusable';
import { TvShelf, TvShelfCard } from '../components/TvShelf';
import { TvStageAction, TvStageBackdrop, TvStageBlock } from '../components/TvStage';
import { TvDetailRoute, TvPlayRequest, TvUiState } from '../model/TvUiState';
import { TvPlayback } from '../playback/TvPlaybackHost';
import { TvArt, TvColors, TvMetrics, TvType } from '../theme/TvTheme';

class TvViewpoint {
  readonly key: string;
  readonly mediaType: string;
  readonly source: string;
  readonly label: string;

  constructor(mediaType: string, source: string, label: string) {
    this.key = `${mediaType}:${source}`;
    this.mediaType = mediaType;
    this.source = source;
    this.label = label;
  }
}

const VIEWPOINTS: TvViewpoint[] = [
  new TvViewpoint('movie', 'tmdb', '电影 · TMDB'),
  new TvViewpoint('tv', 'tmdb', '剧集 · TMDB'),
  new TvViewpoint('movie', 'douban', '电影 · 豆瓣'),
  new TvViewpoint('tv', 'douban', '剧集 · 豆瓣')
];

function heroRefOfPage(page: DiscoveryPageView): string {
  for (const section of page.sections) {
    if (section.presentation === 'hero') {
      return section.collection_ref;
    }
  }
  return '';
}

@ComponentV2
struct TvViewpointPill {
  @Param label: string = '';
  @Param selected: boolean = false;
  @Param focusKey: string = '';
  @Param onPick: (() => void) | null = null;
  @Local active: boolean = false;

  build() {
    TvFocusable({
      focusScale: 1.05,
      cornerRadius: 999,
      focusKey: this.focusKey,
      onActivate: (): void => {
        const cb = this.onPick;
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
        .fontColor(this.active ? '#0b0d12' : (this.selected ? TvColors.text : TvColors.textMuted))
        .padding({ left: 20, right: 20, top: 9, bottom: 9 })
        .backgroundColor(this.active ? '#f3f5f9'
          : (this.selected ? 'rgba(255, 255, 255, 0.18)' : TvColors.glassFill))
        .borderRadius(999)
    }
  }
}

@ComponentV2
export struct TvDiscoverPage {
  @Local mediaType: string = 'movie';
  @Local source: string = 'tmdb';
  @Local feed: DiscoverFeed = new DiscoverFeed('movie', 'tmdb');
  @Local focusedTitle: DiscoveredTitleView | null = null;
  @Local subscribedRefs: Set<string> = new Set<string>();
  @Local busyRef: string = '';
  private defaultLibraryByKind: Map<string, number> = new Map<string, number>();
  private token: number = 0;
  private itemIndex: Map<string, DiscoveredTitleView> = new Map<string, DiscoveredTitleView>();

  aboutToAppear(): void {
    const origin: string = AppModel.origin();
    DiscoverStore.shared.ensureRestored(origin);
    this.feed = DiscoverStore.shared.feed(this.mediaType, this.source, origin);
    this.loadAux();
    this.loadFeed();
    setTimeout((): void => {
      TvFocus.request(this.getUIContext(), 'tv_tab_anchor');
    }, 120);
  }

  private async loadAux(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    api.libraryList()
      .then((libs: LibraryView[]): void => {
        const map: Map<string, number> = new Map<string, number>();
        for (const lib of libs) {
          if (lib.viewer_access && !map.has(lib.media_type)) {
            map.set(lib.media_type, lib.id);
          }
        }
        this.defaultLibraryByKind = map;
      })
      .catch((): void => {
      });

    if (Permissions.fromSession(AppModel.shared.session).canSubscribe) {
      api.subscriptionsList()
        .then((subs: SubscriptionView[]): void => {
          const set: Set<string> = new Set<string>();
          for (const sub of subs) {
            set.add(`tmdb:${sub.media.kind}:${sub.media.tmdb_id}`);
            if (sub.media.douban_id !== null && sub.media.douban_id !== undefined) {
              set.add(`douban:${sub.media.douban_id}`);
            }
          }
          this.subscribedRefs = set;
        })
        .catch((): void => {
        });
    }
  }

  private switchViewpoint(vp: TvViewpoint): void {
    if (vp.mediaType === this.mediaType && vp.source === this.source) {
      return;
    }
    this.mediaType = vp.mediaType;
    this.source = vp.source;
    this.focusedTitle = null;
    this.feed = DiscoverStore.shared.feed(vp.mediaType, vp.source, AppModel.origin());
    this.loadFeed();
  }

  private async loadFeed(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    const feed: DiscoverFeed = this.feed;
    if (feed.loaded) {
      this.pickDefaultHero(feed);
      return;
    }
    feed.loaded = true;
    const token: number = ++this.token;
    feed.failure = null;

    let page: DiscoveryPageView;
    try {
      page = await api.uiDiscoveryGet(this.mediaType as MediaKind, this.source as MediaSource);
    } catch (err) {
      if (token !== this.token) {
        return;
      }
      feed.loaded = false;
      feed.failure = new DiscoverFailure(`${err}`);
      return;
    }
    if (token !== this.token) {
      return;
    }
    feed.layout = page;
    const heroRef: string = heroRefOfPage(page);
    const built: DiscoverRow[] = [];
    for (const section of page.sections) {
      if (section.presentation !== 'hero') {
        const kept: DiscoverRow | null = feed.findRow(section.collection_ref);
        built.push(kept !== null
          ? kept
          : new DiscoverRow(section.collection_ref, section.title, section.supports_full_listing));
      }
    }
    feed.rows = built;
    if (heroRef.length === 0) {
      feed.hero = [];
    }

    const tasks: Promise<void>[] = [];
    if (heroRef.length > 0) {
      tasks.push(this.fetchSection(api, feed, heroRef, 10, true, token));
    }
    for (const section of page.sections) {
      if (section.presentation !== 'hero') {
        tasks.push(this.fetchSection(api, feed, section.collection_ref, section.preview_limit, false, token));
      }
    }
    await Promise.all(tasks);
    if (token !== this.token) {
      return;
    }
    if (feed.allRowsFailed()) {
      feed.loaded = false;
      feed.failure = new DiscoverFailure('发现榜单加载失败');
    } else {
      DiscoverStore.shared.saveSnapshot(AppModel.origin());
      this.pickDefaultHero(feed);
    }
  }

  private async fetchSection(api: MovieClawApi, feed: DiscoverFeed, ref: string, limit: number,
    isHero: boolean, token: number): Promise<void> {
    try {
      const view = await api.discoverBrowseCollection(ref, limit > 0 ? limit : undefined);
      if (token !== this.token) {
        return;
      }
      if (isHero) {
        feed.hero = view.titles;
        this.pickDefaultHero(feed);
      } else {
        const row: DiscoverRow | null = feed.findRow(ref);
        if (row !== null) {
          row.items = view.titles;
          row.state = DiscoverRowState.loaded;
        }
      }
    } catch (_err) {
      if (token !== this.token) {
        return;
      }
      if (isHero) {
        if (feed.hero === null) {
          feed.hero = [];
        }
      } else {
        const row: DiscoverRow | null = feed.findRow(ref);
        if (row !== null && row.state !== DiscoverRowState.loaded) {
          row.state = DiscoverRowState.failed;
        }
      }
    }
  }

  private pickDefaultHero(feed: DiscoverFeed): void {
    if (this.focusedTitle !== null) {
      return;
    }
    const heroList: DiscoveredTitleView[] = feed.hero ?? [];
    if (heroList.length > 0) {
      this.focusedTitle = heroList[0];
      return;
    }
    for (const r of feed.rows) {
      if (r.items.length > 0) {
        this.focusedTitle = r.items[0];
        return;
      }
    }
  }

  private activeItem(): DiscoveredTitleView | null {
    if (this.focusedTitle !== null) {
      return this.focusedTitle;
    }
    const heroList: DiscoveredTitleView[] = this.feed.hero ?? [];
    if (heroList.length > 0) {
      return heroList[0];
    }
    for (const r of this.feed.rows) {
      if (r.items.length > 0) {
        return r.items[0];
      }
    }
    return null;
  }

  private stageBackdropUrl(): string {
    const item: DiscoveredTitleView | null = this.activeItem();
    if (item === null) {
      return '';
    }
    const raw: string | null = item.backdrop_url ?? (item.poster_url.length > 0 ? item.poster_url : null);
    const resolved: string | null = ImageUrls.resolve(AppModel.origin(), raw, null);
    return resolved === null ? '' : `${resolved}${resolved.includes('?') ? '&' : '?'}w=1920`;
  }

  private stageMetaLine(item: DiscoveredTitleView): string | null {
    const parts: string[] = [];
    if (item.release_year !== null && item.release_year !== undefined) {
      parts.push(`${item.release_year}`);
    }
    for (let i = 0; i < item.genres.length && i < 2; i++) {
      parts.push(item.genres[i]);
    }
    if (item.provider_rating > 0) {
      const prefix: string = item.provider === 'douban' ? '豆瓣' : 'TMDB';
      parts.push(`${prefix} ${item.provider_rating.toFixed(1)}`);
    }
    if (item.extent_label.length > 0) {
      parts.push(item.extent_label);
    }
    return parts.length > 0 ? parts.join(' · ') : null;
  }

  private stageActions(item: DiscoveredTitleView): TvStageAction[] {
    const actions: TvStageAction[] = [];
    const status = item.library_status ?? null;
    if (status !== null && status.library_count > 0 && status.media_item_id > 0) {
      const kind: string = item.media_type ?? this.mediaType;
      const libId: number = this.defaultLibraryByKind.get(kind) ?? 0;
      actions.push(new TvStageAction('play', '立即播放', true, $r('sys.symbol.play_fill'), (): void => {
        const req: TvPlayRequest = new TvPlayRequest(
          libId,
          status.media_item_id,
          kind === 'tv' ? 1 : null,
          kind === 'tv' ? 1 : null,
          null,
          null,
          item.title,
          null,
          kind === 'tv'
        );
        TvPlayback.begin(req);
        TvUiState.shared.openPlayer(req);
      }));
      if (libId > 0) {
        actions.push(new TvStageAction('detail', '库内详情', false, $r('sys.symbol.info_circle'), (): void => {
          TvUiState.shared.pushRoute(new TvDetailRoute(libId, status.media_item_id));
        }));
      }
      return actions;
    }

    if (Permissions.fromSession(AppModel.shared.session).canSubscribe) {
      const subscribed: boolean = this.subscribedRefs.has(item.title_ref);
      const busy: boolean = this.busyRef === item.title_ref;
      actions.push(new TvStageAction(
        'subscribe',
        busy ? '正在订阅…' : (subscribed ? '已订阅' : '一键订阅'),
        !subscribed,
        subscribed ? $r('sys.symbol.checkmark_circle') : $r('sys.symbol.plus'),
        (): void => {
          this.subscribeItem(item);
        }
      ));
    }
    return actions;
  }

  private cardsForDiscoverList(keyPrefix: string, items: DiscoveredTitleView[]): TvShelfCard[] {
    const origin: string = AppModel.origin();
    const out: TvShelfCard[] = [];
    for (const item of items) {
      const key: string = `${keyPrefix}_${item.title_ref}`;
      this.itemIndex.set(key, item);
      const card: TvShelfCard = new TvShelfCard(key, 'poster', item.title);
      const resolved: string | null = ImageUrls.resolve(
        origin,
        item.poster_url.length > 0 ? item.poster_url : (item.backdrop_url ?? null),
        null
      );
      card.imageUrl = resolved === null ? ''
        : `${resolved}${resolved.includes('?') ? '&' : '?'}w=${TvArt.pxWidth(TvMetrics.posterWidth)}`;
      const subParts: string[] = [];
      if (item.release_year !== null && item.release_year !== undefined) {
        subParts.push(`${item.release_year}`);
      }
      if (item.provider_rating > 0) {
        subParts.push(`★ ${item.provider_rating.toFixed(1)}`);
      }
      card.subtitle = subParts.length > 0 ? subParts.join(' · ') : null;
      if ((item.library_status?.library_count ?? 0) > 0) {
        card.badge = '已入库';
      } else if (this.subscribedRefs.has(item.title_ref)) {
        card.badge = '已订阅';
      }
      card.caption = TvCardCaption.focused;
      out.push(card);
    }
    return out;
  }

  private activateCard(card: TvShelfCard): void {
    const item: DiscoveredTitleView | undefined = this.itemIndex.get(card.key);
    if (item === undefined) {
      return;
    }
    const status = item.library_status ?? null;
    if (status !== null && status.library_count > 0 && status.media_item_id > 0) {
      const kind: string = item.media_type ?? this.mediaType;
      const libId: number = this.defaultLibraryByKind.get(kind) ?? 0;
      if (libId > 0) {
        TvUiState.shared.pushRoute(new TvDetailRoute(libId, status.media_item_id));
        return;
      }
    }
    this.subscribeItem(item);
  }

  private async subscribeItem(item: DiscoveredTitleView): Promise<void> {
    if (!Permissions.fromSession(AppModel.shared.session).canSubscribe) {
      this.toast('当前账号无订阅权限');
      return;
    }
    if (this.subscribedRefs.has(item.title_ref)) {
      this.toast(`《${item.title}》已在订阅队列中`);
      return;
    }
    if (this.busyRef.length > 0) {
      return;
    }
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    this.busyRef = item.title_ref;
    try {
      const preview: PrepareView = await api.uiSubscriptionsPreviewTitle({ title_ref: item.title_ref });
      if (preview.existing_subscription_id !== null && preview.existing_subscription_id !== undefined
        && preview.existing_subscription_id > 0) {
        const next: Set<string> = new Set<string>(this.subscribedRefs);
        next.add(item.title_ref);
        this.subscribedRefs = next;
        this.toast(`《${item.title}》已在订阅中`);
        return;
      }
      const isTv: boolean = (item.media_type ?? this.mediaType) === 'tv';
      const seasons: number[] = [];
      if (isTv) {
        if (preview.suggested_seasons.length > 0) {
          for (const s of preview.suggested_seasons) {
            seasons.push(s);
          }
        } else {
          for (const s of preview.seasons) {
            if (s.season_number > 0) {
              seasons.push(s.season_number);
            }
          }
        }
      }
      const payload: SubscriptionCreatePayload = {
        title_ref: item.title_ref,
        selected_seasons: isTv && seasons.length > 0 ? seasons : null,
        follow_future: isTv ? true : null,
        selection_mode: preview.smart !== null && preview.smart !== undefined ? 'smart' : null
      };
      await api.subscriptionsCreate(payload);
      const next: Set<string> = new Set<string>(this.subscribedRefs);
      next.add(item.title_ref);
      this.subscribedRefs = next;
      this.toast(`已订阅《${item.title}》`);
    } catch (_err) {
      this.toast('订阅请求未完成，请在手机或网页端核对规则配置');
    } finally {
      this.busyRef = '';
    }
  }

  private toast(msg: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: msg });
    } catch (_err) {
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      TvStageBackdrop({ imageUrl: this.stageBackdropUrl(), kenBurns: true })

      if (this.feed.failure !== null && this.feed.rows.length === 0) {
        TvStateView({
          symbol: $r('sys.symbol.sparkles'),
          title: '发现榜单暂不可用',
          message: this.feed.failure.message,
          actionTitle: '重试',
          defaultFocusAction: true,
          onAction: (): void => {
            this.feed.loaded = false;
            this.loadFeed();
          }
        })
      } else {
        Scroll() {
          Column({ space: TvMetrics.rowGap }) {
            // 顶部视角切换排（与左上侧边栏胶囊同行对齐）
            Row({ space: 12 }) {
              ForEach(VIEWPOINTS, (vp: TvViewpoint, idx: number) => {
                TvViewpointPill({
                  label: vp.label,
                  selected: vp.mediaType === this.mediaType && vp.source === this.source,
                  focusKey: idx === 0 ? 'tv_tab_anchor' : '',
                  onPick: (): void => {
                    this.switchViewpoint(vp);
                  }
                })
              }, (vp: TvViewpoint) => vp.key)
            }
            .padding({ left: TvMetrics.edge + 150, right: TvMetrics.edge, top: 40 })

            if (this.activeItem() !== null) {
              Column() {
                TvStageBlock({
                  title: (this.activeItem() as DiscoveredTitleView).title,
                  metaLine: this.stageMetaLine(this.activeItem() as DiscoveredTitleView),
                  overview: (this.activeItem() as DiscoveredTitleView).overview,
                  overviewLines: 2,
                  actions: this.stageActions(this.activeItem() as DiscoveredTitleView),
                  defaultFocusFirstAction: false,
                  bottomInset: 18
                })
              }
              .width('100%')
              .height(340)
            }

            if ((this.feed.hero ?? []).length > 0) {
              TvShelf({
                title: '焦点精选',
                cards: this.cardsForDiscoverList('hero', this.feed.hero ?? []),
                onActivate: (card: TvShelfCard): void => {
                  this.activateCard(card);
                },
                onCardFocus: (card: TvShelfCard, active: boolean): void => {
                  if (active) {
                    const hit: DiscoveredTitleView | undefined = this.itemIndex.get(card.key);
                    if (hit !== undefined) {
                      this.focusedTitle = hit;
                    }
                  }
                }
              })
            }

            ForEach(this.feed.rows, (row: DiscoverRow) => {
              if (row.state === DiscoverRowState.loaded && row.items.length > 0) {
                TvShelf({
                  title: row.title,
                  cards: this.cardsForDiscoverList(row.ref, row.items),
                  onActivate: (card: TvShelfCard): void => {
                    this.activateCard(card);
                  },
                  onCardFocus: (card: TvShelfCard, active: boolean): void => {
                    if (active) {
                      const hit: DiscoveredTitleView | undefined = this.itemIndex.get(card.key);
                      if (hit !== undefined) {
                        this.focusedTitle = hit;
                      }
                    }
                  }
                })
              }
            }, (row: DiscoverRow) => row.ref)

            Column().height(TvMetrics.edge)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .height('100%')
  }
}
