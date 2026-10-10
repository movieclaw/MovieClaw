import { common, Want } from '@kit.AbilityKit';
import { Theme } from '../theme/AppTheme';
import { PageTopBar } from '../common/PageTopBar';
import { AppModel } from '../common/AppModel';
import { Permissions } from '../common/Permissions';
import { RemoteImage } from '../common/RemoteImage';
import { ImageUrls, ImageVariant } from '../common/ImageUrls';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import {
  DiscoveredTitleDetailsView,
  DiscoveredTitleView,
  MediaCastMember,
  MediaImage,
  MediaLibraryLink,
  MediaVideo
} from '../api/Models';
import { ItemRouteParams } from '../library/LibraryItemDetailPage';
import { PersonParams } from './PersonDetailPage';
import { TorrentParams } from '../search/TorrentResultsPage';
import { SubscribeCenter } from '../subscriptions/SubscribeCenter';
import { AppFooter } from '../common/AppFooter';

/**
 * 发现详情页路由参数。
 * 同前两页：路由参数会被序列化，**不要用 `instanceof`**，按字段取值。
 */
export class DiscoverDetailParams {
  readonly titleRef: string;

  constructor(titleRef: string) {
    this.titleRef = titleRef;
  }

  static of(param: Object | undefined | null): DiscoverDetailParams | null {
    if (param === undefined || param === null) {
      return null;
    }
    const raw: DiscoverDetailParams = param as DiscoverDetailParams;
    const ref: string = raw.titleRef;
    if (ref === undefined || ref === null || ref.length === 0) {
      return null;
    }
    return new DiscoverDetailParams(ref);
  }
}

/** 路由表注册用（router_map.json 的 buildMethod） */
@Builder
export function DiscoverDetailBuilder() {
  DiscoverDetailPage()
}

/**
 * 发现详情页（对应 iOS 端 Features/Discover/MediaDetailView.swift）。
 *
 * 结构：沉浸大图（剧照，缺则海报兜底）→ 标题区（盖在大图下半部）→ 简介（可展开）
 * → 演职员 → 预告片 → 剧照墙 → 所属合集 → 相似推荐 → 外部链接。
 *
 * 取数同 iOS：`discoverGetTitleDetails(titleRef)` 一路；失败落兜底态（带重试）。
 *
 * 本轮先不做：预告片的内嵌播放（iOS 用 SafariView + YouTube 可达性探测）、
 * 订阅弹层、搜索资源跳转、大图底边取色（HeroEdgeColor）、下拉放大。
 * 已入库的条目可以直接跳进媒体库的条目详情页，这条链是通的。
 */
@Component
export struct DiscoverDetailPage {
  private navStack: NavPathStack = new NavPathStack();
  private titleRef: string = '';
  private started: boolean = false;

  @State private detail: DiscoveredTitleDetailsView | null = null;
  @State private failed: boolean = false;
  @State private failureMessage: string = '';
  @State private overviewExpanded: boolean = false;
  @State private refreshing: boolean = false;
  @State private heroHeight: number = 320;

  private permissions(): Permissions {
    return Permissions.fromSession(AppModel.shared.session);
  }

  private start(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    this.load();
  }

  private async load(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    try {
      this.detail = await api.discoverGetTitleDetails(this.titleRef);
      this.failed = false;
      this.failureMessage = '';
    } catch (error) {
      // 网络抖动：已显示的内容保留，首次加载才落兜底态（同 iOS）
      if (this.detail === null) {
        this.failed = true;
        this.failureMessage = this.messageOf(error);
      }
    }
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '网络请求失败';
  }

  // MARK: 派生

  private item(): DiscoveredTitleView | null {
    const detail: DiscoveredTitleDetailsView | null = this.detail;
    return detail === null ? null : detail.title;
  }

  private isMovie(): boolean {
    const item: DiscoveredTitleView | null = this.item();
    return item === null ? true : item.media_type !== 'tv';
  }

  private hasLibrary(): boolean {
    const detail: DiscoveredTitleDetailsView | null = this.detail;
    return detail !== null && detail.library_links.length > 0;
  }

  /** 评分 · 年份 · 时长 */
  private metaLine(): string {
    const item: DiscoveredTitleView | null = this.item();
    if (item === null) {
      return '';
    }
    const parts: string[] = [];
    if ((item.provider_rating ?? 0) > 0) {
      parts.push(`★ ${item.provider_rating.toFixed(1)}`);
    }
    const year: number | null = item.release_year ?? null;
    if (year !== null && year > 0) {
      parts.push(`${year}`);
    }
    const extent: string = item.extent_label ?? '';
    if (extent.length > 0) {
      parts.push(extent);
    }
    return parts.join('  ·  ');
  }

  /** 国家 · 语言 ｜ 类型 */
  private placeAndGenres(): string {
    const detail: DiscoveredTitleDetailsView | null = this.detail;
    if (detail === null) {
      return '';
    }
    const meta = detail.metadata;
    const place: string[] = [];
    if (meta.country.length > 0) {
      place.push(meta.country);
    }
    if (meta.language.length > 0) {
      place.push(meta.language);
    }
    const left: string = place.join(' · ');
    const right: string = this.item() === null ? '' : this.item()!.genres.join(' · ');
    if (left.length > 0 && right.length > 0) {
      return `${left} ｜ ${right}`;
    }
    return left.length > 0 ? left : right;
  }

  /** 上映/首播日期 */
  private releasedLine(): string {
    const detail: DiscoveredTitleDetailsView | null = this.detail;
    if (detail === null || detail.metadata.released.length === 0) {
      return '';
    }
    return `${this.isMovie() ? '上映日期' : '首播日期'} · ${detail.metadata.released}`;
  }

  /** 演职员：导演在前（同 iOS castPeople） */
  private people(): MediaCastMember[] {
    const detail: DiscoveredTitleDetailsView | null = this.detail;
    if (detail === null) {
      return [];
    }
    const out: MediaCastMember[] = [];
    for (const person of detail.metadata.director_credits) {
      out.push(person);
    }
    if (out.length === 0) {
      for (const name of detail.metadata.directors) {
        out.push({ name: name, role: '导演' });
      }
    }
    for (const person of detail.metadata.cast) {
      out.push(person);
    }
    return out;
  }

  /** 沉浸大图：剧照优先，缺则海报兜底（豆瓣条目没有横版剧照，同 iOS） */
  private heroUrl(): string {
    const detail: DiscoveredTitleDetailsView | null = this.detail;
    if (detail === null) {
      return '';
    }
    const raw: string | null =
      detail.title.backdrop_url ?? (detail.title.poster_url.length > 0 ? detail.title.poster_url : null);
    return ImageUrls.resolve(AppModel.origin(), raw, ImageVariant.landscapeCard) ?? '';
  }

  // MARK: 交互

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  /** 打开外部链接（预告片 / 来源页）：交给系统浏览器 */
  private openExternal(url: string): void {
    if (url.length === 0) {
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const want: Want = {
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browsable'],
      uri: url
    };
    context.startAbility(want).catch((): void => {
      this.toast('没有可打开该链接的应用');
    });
  }

  /** 已入库：跳进媒体库的条目详情页（这条链是通的） */
  private openInLibrary(link: MediaLibraryLink): void {
    this.navStack.pushPathByName('libraryItem',
      new ItemRouteParams(link.library_id, link.media_item_id));
  }

  private openDiscoverTitle(item: DiscoveredTitleView): void {
    this.navStack.pushPathByName('discoverDetail', new DiscoverDetailParams(item.title_ref));
  }

  // MARK: 视图

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
        // 自绘顶栏：原生标题栏在沉浸式布局下不避让状态栏（会压住时钟、返回键上半截点不动）
        PageTopBar({ title: this.detail !== null ? this.detail.title.title : '', onBack: (): void => {
          this.navStack.pop();
        }})
        if (this.failed) {
          this.FailedState()
        } else if (this.detail === null) {
          this.LoadingState()
        } else {
          this.Content(this.detail as DiscoveredTitleDetailsView)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg)
    }
    // iOS `.navigationTitle(title)` inline：原生标题栏（系统自带返回键），去掉自绘悬浮 TopBar
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
      const params: DiscoverDetailParams | null =
        DiscoverDetailParams.of(ctx.pathInfo.param as Object | undefined);
      if (params !== null) {
        this.titleRef = params.titleRef;
        this.start();
      }
    })
  }

  @Builder
  LoadingState() {
    Column({ space: 10 }) {
      LoadingProgress()
        .width(26)
        .height(26)
        .color(Theme.textMuted)
      Text('正在加载详情…')
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
      Text('未能加载该影片详情')
        .fontSize(17)
        .fontWeight(600)
        .fontColor(Theme.text)
      Text('资源可能已下线，或网络暂时不可达。请返回后重试。')
        .fontSize(15)
        .fontColor(Theme.textMuted)
        .textAlign(TextAlign.Center)
      if (this.failureMessage.length > 0) {
        Text(this.failureMessage)
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .textAlign(TextAlign.Center)
      }
      Row({ space: 12 }) {
        Text('重试')
          .fontSize(15)
          .fontWeight(600)
          .fontColor('#0b0d12')
          .padding({ left: 22, right: 22, top: 10, bottom: 10 })
          .backgroundColor(Theme.accent)
          .borderRadius(20)
          .onClick(() => {
            this.load();
          })
        Text('返回')
          .fontSize(15)
          .fontWeight(600)
          .fontColor(Theme.text)
          .padding({ left: 22, right: 22, top: 10, bottom: 10 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(20)
          .border({ width: 1, color: Theme.lineStrong })
          .onClick(() => {
            this.navStack.pop();
          })
      }
      .margin({ top: 4 })
    }
    .width('100%')
    .height('100%')
    .padding(24)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  Content(detail: DiscoveredTitleDetailsView) {
    Refresh({ refreshing: $$this.refreshing }) {
      Scroll() {
        Column({ space: 0 }) {
          this.Hero()
          this.Header(detail)
          Column({ space: 26 }) {
            if (detail.title.overview.length > 0) {
              this.Overview(detail.title.overview)
            }
            if (this.people().length > 0) {
              this.CastRow()
            }
            if (detail.videos.length > 0) {
              this.TrailerRow(detail.videos)
            }
            if (detail.backdrops.length > 0 || detail.posters.length > 0) {
              this.PhotoWall(detail)
            }
            if (detail.collection !== null && detail.collection !== undefined
              && detail.collection.titles.length > 1) {
              this.TitleRow(detail.collection.name, detail.collection.titles)
            }
            if (detail.recommendations.length > 0) {
              this.TitleRow('相似推荐', detail.recommendations)
            }
            this.ExternalLinks(detail)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ top: 20, bottom: 24 })
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
      this.load().then((): void => {
        this.refreshing = false;
      });
    })
    .width('100%')
    .height('100%')
  }

  /** 沉浸大图：高 = min(屏宽 × 1.15, 屏高 × 0.55)，顶部一抹暗托住返回键，底部渐变进底色 */
  @Builder
  Hero() {
    Stack({ alignContent: Alignment.Bottom }) {
      RemoteImage({ url: this.heroUrl() })
        .width('100%')
        .height('100%')
      Column()
        .width('100%')
        .height('50%')
        .linearGradient({ angle: 180, colors: [['rgba(0,0,0,0)', 0], [Theme.bg, 1]] })
    }
    .width('100%')
    .height(this.heroHeight)
  }

  @Builder
  Header(detail: DiscoveredTitleDetailsView) {
    Column({ space: 10 }) {
      Text(detail.title.title)
        .fontFamily('serif')
        .fontSize(28)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.metaLine().length > 0) {
        Text(this.metaLine())
          .fontSize(15)
          .fontColor(Theme.text)
      }
      if (this.placeAndGenres().length > 0) {
        Text(this.placeAndGenres())
          .fontSize(14)
          .fontColor(Theme.textMuted)
      }
      if (this.releasedLine().length > 0) {
        Text(this.releasedLine())
          .fontSize(13)
          .fontColor(Theme.textFaint)
      }
      if (detail.library_links.length > 0) {
        this.LibraryBar(detail.library_links)
      }
      this.ActionRow()
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: -(this.heroHeight * 0.32) })
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
  }

  /** 已入库：库名 + 媒体库里的位置，点了直接进条目详情页 */
  @Builder
  LibraryBar(links: MediaLibraryLink[]) {
    Column({ space: 6 }) {
      ForEach(links, (link: MediaLibraryLink) => {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
            .fontSize(15)
            .fontColor([Theme.ok])
          Text(`已在「${link.library_name}」`)
            .fontSize(13)
            .fontColor(Theme.text)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(14)
            .fontColor([Theme.textFaint])
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 9, bottom: 9 })
        .backgroundColor(Theme.glassFill)
        .borderRadius(10)
        .onClick(() => {
          this.openInLibrary(link);
        })
      }, (link: MediaLibraryLink) => `${link.library_id}-${link.media_item_id}`)
    }
    .width('100%')
    .margin({ top: 4 })
  }

  /** 订阅追踪 / 搜索资源（权限位同 iOS） */
  @Builder
  ActionRow() {
    if (this.permissions().canSubscribe || this.permissions().canSearch) {
      Row({ space: 10 }) {
        if (this.permissions().canSubscribe) {
          Button('订阅追踪')
            .height(42)
            .fontSize(15)
            .fontColor('#0b0d12')
            .backgroundColor(Theme.accent)
            .borderRadius(12)
            .onClick(() => {
              SubscribeCenter.present(this.titleRef, this.displayTitle());
            })
        }
        if (this.permissions().canSearch) {
          Button('搜索资源')
            .height(42)
            .fontSize(15)
            .fontColor(Theme.text)
            .backgroundColor(Theme.surfaceRaised)
            .borderRadius(12)
            .border({ width: 1, color: Theme.line })
            .onClick(() => {
              // 资源搜索第 53 轮就做好了，这里却还挂着「建设中」——接上
              this.navStack.pushPathByName('torrents', new TorrentParams(this.displayTitle()));
            })
        }
      }
      .margin({ top: 6 })
    }
  }

  /** 简介：4 行折叠（同 iOS `overview(_:)`） */
  @Builder
  Overview(text: string) {
    Column({ space: 6 }) {
      Text(text)
        .fontSize(15)
        .fontColor(Theme.textMuted)
        .lineHeight(24)
        .maxLines(this.overviewExpanded ? 200 : 4)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.overviewExpanded ? '收起' : '展开')
        .fontSize(13)
        .fontColor(Theme.textFaint)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
    .onClick(() => {
      this.overviewExpanded = !this.overviewExpanded;
    })
  }

  /** 演职员：横向头像/名字卡 */
  @Builder
  CastRow() {
    Column({ space: 10 }) {
      Text('演职员')
        .fontSize(19)
        .fontWeight(600)
        .fontColor(Theme.text)
        .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
      Scroll() {
        Row({ space: 12 }) {
          ForEach(this.people(), (person: MediaCastMember) => {
            Column({ space: 6 }) {
              if (person.avatar_url !== null && person.avatar_url !== undefined
                && person.avatar_url.length > 0) {
                RemoteImage({
                  url: ImageUrls.resolve(AppModel.origin(), person.avatar_url, ImageVariant.photoTile) ?? ''
                })
                  .width(64)
                  .height(64)
                  .borderRadius(32)
              } else {
                Text(person.name.length > 0 ? person.name.substring(0, 1) : '?')
                  .fontSize(22)
                  .fontColor(Theme.textMuted)
                  .width(64)
                  .height(64)
                  .textAlign(TextAlign.Center)
                  .backgroundColor(Theme.surface)
                  .borderRadius(32)
              }
              Text(person.name)
                .fontSize(13)
                .fontColor(Theme.text)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width(72)
                .textAlign(TextAlign.Center)
              if (person.role !== null && person.role !== undefined && person.role.length > 0) {
                Text(person.role)
                  .fontSize(11)
                  .fontColor(Theme.textFaint)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width(72)
                  .textAlign(TextAlign.Center)
              }
            }
            .width(72)
            .onClick(() => {
              // 有 TMDB 影人 ID 才可点，进 TMDB 影人页（同 iOS router.push(.discoveredPerson)）
              const id: number = person.tmdb_person_id ?? 0;
              if (id > 0) {
                this.navStack.pushPathByName('discoveredPerson', new PersonParams(id));
              }
            })
          }, (person: MediaCastMember) => `${person.name}-${person.role ?? ''}`)
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

  /** 预告片：点了交给系统浏览器（本轮不做内嵌播放） */
  @Builder
  TrailerRow(videos: MediaVideo[]) {
    Column({ space: 10 }) {
      Text('预告片')
        .fontSize(19)
        .fontWeight(600)
        .fontColor(Theme.text)
        .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
      Scroll() {
        Row({ space: 12 }) {
          ForEach(videos, (video: MediaVideo) => {
            Stack({ alignContent: Alignment.Center }) {
              RemoteImage({ url: this.thumbUrl(video.thumbnail_url) })
                .width('100%')
                .height('100%')
              SymbolGlyph($r('sys.symbol.play_fill'))
                .fontSize(26)
                .fontColor(['rgba(255,255,255,0.9)'])
            }
            .width(200)
            .aspectRatio(16 / 9)
            .backgroundColor(Theme.surface)
            .borderRadius(Theme.cardRadius)
            .clip(true)
            .onClick(() => {
              this.openExternal(video.watch_url);
            })
          }, (video: MediaVideo) => video.key)
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

  private thumbUrl(raw: string): string {
    return ImageUrls.resolve(AppModel.origin(), raw, ImageVariant.landscapeCard) ?? '';
  }

  /** 剧照墙：剧照在前、海报在后（同 iOS DetailPhotoWall 的拼法） */
  @Builder
  PhotoWall(detail: DiscoveredTitleDetailsView) {
    Column({ space: 10 }) {
      Text('剧照')
        .fontSize(19)
        .fontWeight(600)
        .fontColor(Theme.text)
        .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
      Scroll() {
        Row({ space: 10 }) {
          ForEach(detail.backdrops, (image: MediaImage) => {
            this.WallImage(image.preview_url, 200, 16 / 9)
          }, (image: MediaImage) => `b-${image.full_url}`)
          ForEach(detail.posters, (image: MediaImage) => {
            this.WallImage(image.preview_url, 124, Theme.posterAspect)
          }, (image: MediaImage) => `p-${image.full_url}`)
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
  WallImage(raw: string, width: number, aspect: number) {
    RemoteImage({ url: this.thumbUrl(raw) })
      .width(width)
      .aspectRatio(aspect)
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .clip(true)
  }

  /** 横滚片单行（所属合集 / 相似推荐；与发现页同一形态） */
  @Builder
  TitleRow(title: string, items: DiscoveredTitleView[]) {
    Column({ space: 12 }) {
      Text(title)
        .fontSize(19)
        .fontWeight(600)
        .fontColor(Theme.text)
        .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
      Scroll() {
        Row({ space: 12 }) {
          ForEach(items, (item: DiscoveredTitleView) => {
            this.TitleCard(item)
          }, (item: DiscoveredTitleView) => item.title_ref)
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
  TitleCard(item: DiscoveredTitleView) {
    Column({ space: 6 }) {
      RemoteImage({
        url: ImageUrls.resolve(AppModel.origin(), item.poster_url, ImageVariant.posterCard) ?? ''
      })
        .width('100%')
        .aspectRatio(Theme.posterAspect)
        .backgroundColor(Theme.surface)
        .borderRadius(Theme.cardRadius)
        .clip(true)
      Text(item.title)
        .fontSize(14)
        .fontWeight(600)
        .fontColor(Theme.text)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.cardSubtitle(item))
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width(124)
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.openDiscoverTitle(item);
    })
  }

  private cardSubtitle(item: DiscoveredTitleView): string {
    const parts: string[] = [];
    const year: number | null = item.release_year ?? null;
    if (year !== null && year > 0) {
      parts.push(`${year}`);
    }
    if ((item.provider_rating ?? 0) > 0) {
      parts.push(`★ ${item.provider_rating.toFixed(1)}`);
    }
    return parts.join('  ·  ');
  }

  /** 外部链接：数据来源页（同 iOS externalLinks） */
  @Builder
  ExternalLinks(detail: DiscoveredTitleDetailsView) {
    if (this.sourceUrl(detail).length > 0) {
      Row({ space: 6 }) {
        Text('数据来源')
          .fontSize(13)
          .fontColor(Theme.textFaint)
        Text(this.sourceLabel(detail))
          .fontSize(13)
          .fontColor(Theme.accentStrong)
      }
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
      .onClick(() => {
        this.openExternal(this.sourceUrl(detail));
      })
    }
  }

  /** 当前条目名（投给订阅弹层做兜底标题） */
  private displayTitle(): string {
    const detail: DiscoveredTitleDetailsView | null = this.detail;
    return detail === null ? '' : detail.title.title;
  }

  private sourceUrl(detail: DiscoveredTitleDetailsView): string {
    const url: string | null = detail.metadata.source_url ?? null;
    return url ?? '';
  }

  private sourceLabel(detail: DiscoveredTitleDetailsView): string {
    const provider: string = detail.title.provider;
    return provider === 'douban' ? '豆瓣 ↗' : 'TMDB ↗';
  }
}
