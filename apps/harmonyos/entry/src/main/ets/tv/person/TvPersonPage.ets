/**
 * TV 影人档案页（10 英尺客厅交互）：
 * 并行拉取库内影人（`GET /people/{id}`）与 TMDB 完整影视履历（`GET /discover/people/{id}`），
 * 库内已收录作品一键进详情，未入库作品支持遥控器一键智能订阅。
 */
import { AppModel } from '../../common/AppModel';
import { ImageUrls, ImageVariant } from '../../common/ImageUrls';
import { Permissions } from '../../common/Permissions';
import { RemoteImage } from '../../common/RemoteImage';
import { MovieClawApi } from '../../api/Endpoints';
import {
  DiscoveredPersonDetailsView,
  DiscoveredTitleView,
  LibraryView,
  PersonCreditView,
  PersonView,
  PrepareView,
  SubscriptionCreatePayload,
  SubscriptionView
} from '../../api/Models';
import { TvCardCaption, TvPillButton, TvPosterCard, TvStateView } from '../components/TvCards';
import { TvShelf, TvShelfCard } from '../components/TvShelf';
import { TvStageBackdrop } from '../components/TvStage';
import { TvDetailRoute, TvUiState } from '../model/TvUiState';
import { TvArt, TvColors, TvMetrics, TvType } from '../theme/TvTheme';

@ComponentV2
export struct TvPersonPage {
  @Param tmdbPersonId: number = 0;
  @Param personName: string = '';

  @Local loading: boolean = true;
  @Local failed: boolean = false;
  @Local localPerson: PersonView | null = null;
  @Local discoveredPerson: DiscoveredPersonDetailsView | null = null;
  @Local subscribedRefs: Set<string> = new Set<string>();
  @Local busyRef: string = '';
  @Local backdropUrl: string = '';
  private defaultLibraryByKind: Map<string, number> = new Map<string, number>();

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null || this.tmdbPersonId <= 0) {
      this.loading = false;
      this.failed = true;
      return;
    }
    this.loading = true;
    this.failed = false;

    const tasks: Promise<void>[] = [
      api.peopleShow(this.tmdbPersonId)
        .then((p: PersonView): void => {
          this.localPerson = p;
        })
        .catch((): void => {
        }),
      api.discoverGetPersonDetails(this.tmdbPersonId)
        .then((d: DiscoveredPersonDetailsView): void => {
          this.discoveredPerson = d;
        })
        .catch((): void => {
        }),
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
        })
    ];

    if (Permissions.fromSession(AppModel.shared.session).canSubscribe) {
      tasks.push(
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
          })
      );
    }

    await Promise.all(tasks);
    this.loading = false;
    if (this.localPerson === null && this.discoveredPerson === null) {
      this.failed = true;
      return;
    }
    this.pickInitialBackdrop();
  }

  private pickInitialBackdrop(): void {
    const origin: string = AppModel.origin();
    if (this.discoveredPerson !== null) {
      for (const item of this.discoveredPerson.titles) {
        const raw: string | null = item.backdrop_url ?? (item.poster_url.length > 0 ? item.poster_url : null);
        const resolved: string | null = ImageUrls.resolve(origin, raw, null);
        if (resolved !== null) {
          this.backdropUrl = `${resolved}${resolved.includes('?') ? '&' : '?'}w=1920`;
          return;
        }
      }
    }
    if (this.localPerson !== null) {
      for (const c of this.localPerson.credits) {
        const resolved: string | null = ImageUrls.resolve(origin, c.poster_url ?? null, null);
        if (resolved !== null) {
          this.backdropUrl = `${resolved}${resolved.includes('?') ? '&' : '?'}w=1280`;
          return;
        }
      }
    }
  }

  private displayName(): string {
    if (this.localPerson !== null && this.localPerson.name.length > 0) {
      return this.localPerson.name;
    }
    if (this.discoveredPerson !== null && this.discoveredPerson.name.length > 0) {
      return this.discoveredPerson.name;
    }
    return this.personName;
  }

  private originalName(): string {
    const orig: string = this.localPerson?.original_name ?? '';
    return orig.length > 0 && orig !== this.displayName() ? orig : '';
  }

  private avatarUrl(): string {
    const raw: string | null = this.localPerson?.avatar_url ?? this.discoveredPerson?.avatar_url ?? null;
    const resolved: string | null = ImageUrls.resolve(AppModel.origin(), raw, ImageVariant.photoTile);
    return resolved ?? '';
  }

  private summaryLine(): string {
    const parts: string[] = [];
    const localCount: number = this.localPerson?.credits.length ?? 0;
    const tmdbCount: number = this.discoveredPerson?.titles.length ?? 0;
    if (localCount > 0) {
      parts.push(`媒体库已收录 ${localCount} 部`);
    }
    if (tmdbCount > 0) {
      parts.push(`TMDB 完整履历 ${tmdbCount} 部`);
    }
    return parts.join(' · ');
  }

  private localCards(): TvShelfCard[] {
    const person: PersonView | null = this.localPerson;
    if (person === null) {
      return [];
    }
    const origin: string = AppModel.origin();
    const out: TvShelfCard[] = [];
    for (let i = 0; i < person.credits.length; i++) {
      const credit: PersonCreditView = person.credits[i];
      if (credit.library_id === null || credit.library_id === undefined) {
        continue;
      }
      const card: TvShelfCard = new TvShelfCard(`local_${i}_${credit.media_item_id}`, 'poster', credit.title);
      const resolved: string | null = ImageUrls.resolve(origin, credit.poster_url ?? null, null);
      card.imageUrl = resolved === null ? ''
        : `${resolved}${resolved.includes('?') ? '&' : '?'}w=${TvArt.pxWidth(TvMetrics.posterWidth)}`;
      const role: string = credit.department === 'director'
        ? '导演'
        : (credit.character !== null && credit.character !== undefined && credit.character.length > 0
          ? `饰 ${credit.character}` : '');
      const yearStr: string = credit.year !== null && credit.year !== undefined ? `${credit.year}` : '';
      card.subtitle = yearStr.length > 0 && role.length > 0 ? `${yearStr} · ${role}`
        : (yearStr.length > 0 ? yearStr : (role.length > 0 ? role : null));
      card.caption = TvCardCaption.always;
      card.defaultFocused = out.length === 0;
      out.push(card);
    }
    return out;
  }

  private openLocalCredit(card: TvShelfCard): void {
    const person: PersonView | null = this.localPerson;
    if (person === null) {
      return;
    }
    const parts: string[] = card.key.split('_');
    const idx: number = Number(parts[1]);
    const credit: PersonCreditView | undefined = person.credits[idx];
    if (credit !== undefined && credit.library_id !== null && credit.library_id !== undefined) {
      TvUiState.shared.pushRoute(new TvDetailRoute(credit.library_id, credit.media_item_id));
    }
  }

  private discoveredTitles(): DiscoveredTitleView[] {
    return this.discoveredPerson?.titles ?? [];
  }

  private badgeForDiscovered(item: DiscoveredTitleView): string | null {
    const libCount: number = item.library_status?.library_count ?? 0;
    if (libCount > 0) {
      return '已入库';
    }
    if (this.subscribedRefs.has(item.title_ref)) {
      return '已订阅';
    }
    if (this.busyRef === item.title_ref) {
      return '订阅中…';
    }
    return null;
  }

  private posterForDiscovered(item: DiscoveredTitleView): string {
    const resolved: string | null = ImageUrls.resolve(
      AppModel.origin(),
      item.poster_url.length > 0 ? item.poster_url : (item.backdrop_url ?? null),
      null
    );
    return resolved === null ? ''
      : `${resolved}${resolved.includes('?') ? '&' : '?'}w=${TvArt.pxWidth(TvMetrics.posterWidth)}`;
  }

  private libraryIdForMediaItem(mediaItemId: number, kind: string): number {
    if (this.localPerson !== null) {
      for (const c of this.localPerson.credits) {
        if (c.media_item_id === mediaItemId && c.library_id !== null && c.library_id !== undefined) {
          return c.library_id;
        }
      }
    }
    return this.defaultLibraryByKind.get(kind) ?? 0;
  }

  private async activateDiscovered(item: DiscoveredTitleView): Promise<void> {
    const status = item.library_status ?? null;
    if (status !== null && status.library_count > 0 && status.media_item_id > 0) {
      const libId: number = this.libraryIdForMediaItem(status.media_item_id, item.media_type ?? 'movie');
      if (libId > 0) {
        TvUiState.shared.pushRoute(new TvDetailRoute(libId, status.media_item_id));
        return;
      }
    }
    if (!Permissions.fromSession(AppModel.shared.session).canSubscribe) {
      this.toast('该作品尚未入库');
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
        this.toast(`《${item.title}》已订阅`);
        return;
      }
      const isTv: boolean = (item.media_type ?? 'movie') === 'tv';
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
    Stack() {
      Stack() {
        TvStageBackdrop({ imageUrl: this.backdropUrl })
      }
      .width('100%')
      .height('100%')
      .blur(26)

      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(6, 8, 12, 0.72)')

      if (this.loading) {
        Column({ space: 16 }) {
          LoadingProgress()
            .width(48)
            .height(48)
            .color(TvColors.textMuted)
          Text(`正在加载 ${this.personName} 的作品档案…`)
            .fontSize(TvType.footnote)
            .fontColor(TvColors.textMuted)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.failed) {
        TvStateView({
          symbol: $r('sys.symbol.person'),
          title: `未能加载 ${this.personName}`,
          message: '网络暂不可用或 TMDB 中没有这位影人的记录。',
          actionTitle: '返回',
          defaultFocusAction: true,
          onAction: (): void => {
            TvUiState.shared.popRoute();
          }
        })
      } else {
        Scroll() {
          Column({ space: TvMetrics.rowGap }) {
            this.HeaderSection()
            if (this.localCards().length > 0) {
              TvShelf({
                title: '媒体库已收录',
                detail: `${this.localCards().length} 部`,
                cards: this.localCards(),
                onActivate: (card: TvShelfCard): void => {
                  this.openLocalCredit(card);
                }
              })
            }
            if (this.discoveredTitles().length > 0) {
              this.FilmographyGrid()
            }
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
    .backgroundColor(TvColors.bg)
  }

  @Builder
  private HeaderSection() {
    Row({ space: 28 }) {
      Stack() {
        if (this.avatarUrl().length > 0) {
          RemoteImage({ url: this.avatarUrl(), placeholderText: this.displayName() })
        } else {
          Text(this.displayName().substring(0, 1))
            .fontSize(44)
            .fontWeight(FontWeight.Bold)
            .fontColor(TvColors.text)
        }
      }
      .width(128)
      .height(128)
      .borderRadius(64)
      .backgroundColor(TvColors.surfaceRaised)
      .border({ width: 2, color: 'rgba(255, 255, 255, 0.16)' })
      .clip(true)

      Column({ space: 8 }) {
        Text(this.displayName())
          .fontSize(TvType.heroTitle)
          .fontWeight(FontWeight.Bold)
          .fontColor(TvColors.text)
          .maxLines(1)
        if (this.originalName().length > 0) {
          Text(this.originalName())
            .fontSize(TvType.body)
            .fontColor(TvColors.textMuted)
            .maxLines(1)
        }
        if (this.summaryLine().length > 0) {
          Text(this.summaryLine())
            .fontSize(TvType.footnote)
            .fontColor(TvColors.textFaint)
            .maxLines(1)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      TvPillButton({
        label: '返回',
        prominent: false,
        defaultFocused: this.localCards().length === 0 && this.discoveredTitles().length === 0,
        onActivate: (): void => {
          TvUiState.shared.popRoute();
        }
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: TvMetrics.edge, right: TvMetrics.edge, top: 44, bottom: 8 })
  }

  @Builder
  private FilmographyGrid() {
    Column({ space: 20 }) {
      Row({ space: 12 }) {
        Text('完整影视履历')
          .fontSize(TvType.rowTitle)
          .fontWeight(600)
          .fontColor(TvColors.text)
        Text(Permissions.fromSession(AppModel.shared.session).canSubscribe
          ? '已入库直达详情 · 未入库按确认一键订阅'
          : `共 ${this.discoveredTitles().length} 部`)
          .fontSize(TvType.footnote)
          .fontColor(TvColors.textFaint)
      }
      .padding({ left: TvMetrics.edge, right: TvMetrics.edge })

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.discoveredTitles(), (item: DiscoveredTitleView, index: number) => {
          Column() {
            TvPosterCard({
              title: item.title,
              subtitle: item.release_year !== null && item.release_year !== undefined ? `${item.release_year}` : null,
              imageUrl: this.posterForDiscovered(item),
              cardWidth: TvMetrics.posterWidth,
              badge: this.badgeForDiscovered(item),
              caption: TvCardCaption.band,
              defaultFocused: this.localCards().length === 0 && index === 0,
              onActivate: (): void => {
                this.activateDiscovered(item);
              }
            })
          }
          .margin({ right: TvMetrics.cardGap, bottom: 26 })
        }, (item: DiscoveredTitleView) => item.title_ref)
      }
      .width('100%')
      .padding({ left: TvMetrics.edge, right: TvMetrics.edge - TvMetrics.cardGap })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
