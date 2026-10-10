import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { Permissions } from '../common/Permissions';
import { RemoteImage } from '../common/RemoteImage';
import { ImageUrls, ImageVariant } from '../common/ImageUrls';
import { MovieClawApi } from '../api/Endpoints';
import {
  DiscoveredTitleView,
  DiscoveryPageView,
  DiscoverRegionView,
  MediaKind,
  MediaSource
} from '../api/Models';
import {
  DiscoverFailure,
  DiscoverFeed,
  DiscoverRow,
  DiscoverRowState,
  DiscoverStore,
  heroRefOf
} from './DiscoverStore';
import { DiscoverDetailParams } from './DiscoverDetailPage';
import { SubscribeCenter } from '../subscriptions/SubscribeCenter';
import { AppFooter } from '../common/AppFooter';

/**
 * 发现页「行」的数据源（LazyForEach 用）：一行 = 一个横滚片单。
 *
 * 用 List + LazyForEach 而不是 Scroll + Column + ForEach：后者会把所有区行一次性建树，
 * 每个区行里还各自挂一个横向 Scroll + 一排 RemoteImage，区一多首屏就卡。
 * （见 library/LibraryDetailPage 的 WallRowSource 同款做法。）
 *
 * feed.rows 只在「整体换视角/整体重建版面」时整批替换，那时调一次 setRows → onDataReloaded。
 * 单行的 state/items 是 DiscoverRow 自己的 @Trace 字段，原地改时由 DiscoverRowView
 * 按 V2 通知式重绘，不经过这里——所以**键只用 row.ref，不把状态编进键**
 * （老 V1 那套 renderKey 补丁在 V2 迁移后已删，见 docs §10，别加回来）。
 */
class DiscoverRowsSource implements IDataSource {
  private rows: DiscoverRow[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): DiscoverRow {
    return this.rows[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const at: number = this.listeners.indexOf(listener);
    if (at >= 0) {
      this.listeners.splice(at, 1);
    }
  }

  /** 整批换成这一批行（整体重建版面/切视角时调） */
  setRows(rows: DiscoverRow[]): void {
    this.rows = rows;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }
}

/**
 * 发现页（对应 iOS 端 Features/Discover/DiscoverView.swift）。
 *
 * 结构：沉浸 Hero 轮播（编辑推荐）→ 若干横滚片单行 → 院线地区脚注。
 * 标题与「切类型 × 数据源」都在**宿主的原生标题栏/工具栏**里（DiscoverNavHost），
 * 宿主改 `viewpointRequest`，这里用 `@Monitor` 接住调 `switchViewpoint`。
 *
 * 取数严格照 iOS：`uiDiscoveryGet` 拿到「版面声明」，再把版面里每一行**并发**去
 * `discoverBrowseCollection` 取片单；Hero 失败只收起自己，常规行失败整行收起，
 * **全行都失败才整页错误态**；刷新失败保留旧数据（已 LOADED 的行不降级）。
 *
 * **状态管理 V2**（见 docs/harmonyos-port.md §10）：本组件是 `@ComponentV2`，
 * 直接读 `DiscoverFeed` 上的 `@Trace` 字段，改了就自动重绘——
 * 不再需要「读出来拷进 `@State`」，也不需要把状态编进 `ForEach` 的 key。
 *
 * 本轮先不做：筛选（DiscoverFilter）、整行展开、本机快照（iOS 的 DiscoverSnapshots）。
 */
@ComponentV2
export struct DiscoverPage {
  /** 由 DiscoverNavHost 传入：点卡片进发现详情 */
  @Require @Param navStack: NavPathStack;
  /** 宿主工具栏「切视角」换一次值（'movie:tmdb' 这类）；用 @Monitor 接住执行 */
  @Param viewpointRequest: string = '';
  @Local mediaType: string = 'movie';
  @Local source: string = 'tmdb';
  /** 院线地区（仅电影 + TMDB 显示脚注） */
  @Local region: string = '';
  @Local regionEditable: boolean = false;

  private started: boolean = false;
  /** 视角切换时作废在途请求（对应 iOS `.task(id: feedKey)` 取消上一个任务） */
  private token: number = 0;
  /** Hero 当前页；轮播由自己驱动（iOS 的指示器是「8 秒填满」而不是圆点跳变） */
  @Local heroIndex: number = 0;
  /** 当前指示器胶囊的填充进度 0..1 */
  @Local heroFill: number = 0;
  private heroController: SwiperController = new SwiperController();
  private heroTimer: number = -1;
  /** Hero 高度：iOS 固定 520，这里取略小（小屏不至于把内容全顶下去） */
  private heroHeight: number = 480;

  /**
   * 当前视角的数据。
   *
   * **不要用 `@Computed` 来算它**：`@Computed` 在**事件处理器里同步读**拿到的是缓存旧值
   * （`build` 里会重算，所以标题变了、这里还是旧 feed），于是 `load()` 会因为
   * 「这个视角已经加载过」直接 return，新视角的片单永远不拉——切视角后一直停在骨架。
   * 实测踩过。显式赋值最稳。
   */
  @Local feed: DiscoverFeed = DiscoverStore.shared.feed('movie', 'tmdb');

  /** 区行的懒加载数据源（List 里 LazyForEach 按可视区建行） */
  private rowsSource: DiscoverRowsSource = new DiscoverRowsSource();

  aboutToAppear(): void {
    this.load();
    this.startHeroRotation();
  }

  /** 宿主工具栏切了视角（类型 × 数据源）：接住并换视角重新取数 */
  @Monitor('viewpointRequest')
  onViewpointRequest(): void {
    const request: string = this.viewpointRequest;
    if (request.length === 0) {
      return;
    }
    const parts: string[] = request.split(':');
    if (parts.length === 2) {
      this.switchViewpoint(parts[0], parts[1]);
    }
  }

  aboutToDisappear(): void {
    this.stopHeroRotation();
  }

  /**
   * Hero 轮播：8 秒一页，指示器当前胶囊在这 8 秒里填满（对应 iOS 的
   * `immersiveHeroRotation` + `ImmersiveHeroIndicator`）。
   * 只有一页时不转，也不显示指示器。
   */
  private startHeroRotation(): void {
    if (this.heroTimer >= 0) {
      return;
    }
    this.heroTimer = setInterval((): void => {
      const count: number = (this.feed.hero ?? []).length;
      if (count <= 1) {
        return;
      }
      this.heroFill += 0.0125;
      if (this.heroFill >= 1) {
        this.heroFill = 0;
        this.heroIndex = (this.heroIndex + 1) % count;
        this.heroController.changeIndex(this.heroIndex);
      }
    }, 100);
  }

  private stopHeroRotation(): void {
    if (this.heroTimer >= 0) {
      clearInterval(this.heroTimer);
      this.heroTimer = -1;
    }
  }

  // MARK: 取数

  private async load(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    const feed: DiscoverFeed = this.feed;
    // 已拉过的视角直接恢复（对应 iOS `loadIfNeeded`）
    if (feed.loaded) {
      return;
    }
    feed.loaded = true;
    const token: number = ++this.token;
    feed.failure = null;

    let page: DiscoveryPageView;
    try {
      page = await api.uiDiscoveryGet(this.mediaType as MediaKind, this.source as MediaSource);
    } catch (error) {
      if (token !== this.token) {
        return;
      }
      feed.loaded = false;
      feed.failure = new DiscoverFailure(this.messageOf(error));
      return;
    }
    if (token !== this.token) {
      return;
    }
    feed.layout = page;
    const heroRef: string = heroRefOf(page);

    // 建行：除 Hero 外的每个区一行
    const built: DiscoverRow[] = [];
    for (const section of page.sections) {
      if (section.presentation !== 'hero') {
        built.push(new DiscoverRow(section.collection_ref, section.title, section.supports_full_listing));
      }
    }
    feed.rows = built;
    this.rowsSource.setRows(built);
    // 没声明 Hero 就直接收起，别一直挂着骨架（对应 iOS `if heroRef == nil { hero = [] }`）
    if (heroRef.length === 0) {
      feed.hero = [];
    }

    // 所有行并发取（对应 iOS 的 withTaskGroup）
    const tasks: Promise<void>[] = [];
    if (heroRef.length > 0) {
      tasks.push(this.fetchSection(api, feed, heroRef, this.limitOf(page, heroRef), true, token));
    }
    for (const section of page.sections) {
      if (section.presentation === 'hero') {
        continue;
      }
      tasks.push(this.fetchSection(api, feed, section.collection_ref, section.preview_limit, false, token));
    }
    await Promise.all(tasks);
    if (token !== this.token) {
      return;
    }
    // 常规行全挂 → 整页错误态（对应 iOS）
    if (feed.allRowsFailed()) {
      feed.loaded = false;
      if (feed.failure === null) {
        feed.failure = new DiscoverFailure('片单加载失败');
      }
    }
    this.loadRegion();
  }

  private limitOf(page: DiscoveryPageView, ref: string): number {
    for (const section of page.sections) {
      if (section.collection_ref === ref) {
        return section.preview_limit;
      }
    }
    return 0;
  }

  /** 取一行（Hero 单独处理：失败只收起自己，且刷新失败保留旧轮播） */
  private async fetchSection(api: MovieClawApi, feed: DiscoverFeed, ref: string, limit: number,
    isHero: boolean, token: number): Promise<void> {
    try {
      const view = await api.discoverBrowseCollection(ref, limit > 0 ? limit : undefined);
      if (token !== this.token) {
        return;
      }
      if (isHero) {
        feed.hero = view.titles;
      } else {
        const row: DiscoverRow | null = feed.findRow(ref);
        if (row !== null) {
          row.items = view.titles;
          row.state = DiscoverRowState.loaded;
        }
      }
    } catch (error) {
      if (token !== this.token) {
        return;
      }
      if (isHero) {
        // Hero 失败只收起自身；刷新失败保留旧轮播
        if (feed.hero === null) {
          feed.hero = [];
        }
      } else {
        const row: DiscoverRow | null = feed.findRow(ref);
        // 已经有数据就别降级（对应 iOS「刷新失败保留旧数据」）
        if (row !== null && row.state !== DiscoverRowState.loaded) {
          row.state = DiscoverRowState.failed;
          if (feed.failure === null) {
            feed.failure = new DiscoverFailure(this.messageOf(error));
          }
        }
      }
    }
  }

  /** 院线地区脚注（对应 iOS DiscoverRegionFooter） */
  private async loadRegion(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null || this.mediaType !== 'movie' || this.source !== 'tmdb') {
      return;
    }
    try {
      const view: DiscoverRegionView = await api.discoverRegionShow();
      this.region = view.region;
      this.regionEditable = view.can_edit;
    } catch (error) {
      this.region = '';
    }
  }

  private messageOf(error: Object): string {
    const text: string = `${error}`;
    return text.length > 0 ? text : '网络请求失败';
  }

  // MARK: 交互

  /** 切类型/数据源：换视角并重新取数（对应 iOS 标题菜单） */
  private switchViewpoint(mediaType: string, source: string): void {
    if (mediaType === this.mediaType && source === this.source) {
      return;
    }
    this.mediaType = mediaType;
    this.source = source;
    this.feed = DiscoverStore.shared.feed(mediaType, source);
    // 切到已缓存视角时 load() 会因 loaded=true 直接 return，rows 要在这里同步给懒加载源
    this.rowsSource.setRows(this.feed.rows);
    this.token++;
    this.region = '';
    this.load();
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  /** 点卡片：进发现详情（对应 iOS 的 MediaDetailView） */
  private openTitle(item: DiscoveredTitleView): void {
    this.navStack.pushPathByName('discoverDetail', new DiscoverDetailParams(item.title_ref));
  }

  // MARK: 视图

  build() {
    Column() {
      if (this.feed.failure !== null && (this.feed.layout === null || this.feed.allRowsFailed())) {
        this.ErrorState()
      } else {
        this.Content()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  @Builder
  ErrorState() {
    Column({ space: 12 }) {
      Text('发现页加载失败')
        .fontSize(17)
        .fontWeight(600)
        .fontColor(Theme.text)
      if (this.feed.failure !== null) {
        Text((this.feed.failure as DiscoverFailure).message)
          .fontSize(14)
          .fontColor(Theme.textMuted)
          .textAlign(TextAlign.Center)
      }
      Text('重试')
        .fontSize(15)
        .fontWeight(600)
        .fontColor(Theme.accentStrong)
        .padding({ left: 22, right: 22, top: 10, bottom: 10 })
        .backgroundColor(Theme.glassFill)
        .borderRadius(20)
        .border({ width: 1, color: Theme.lineStrong })
        .onClick(() => {
          this.feed.loaded = false;
          this.load();
        })
    }
    .width('100%')
    .layoutWeight(1)
    .padding(24)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  Content() {
    // 用 List 而不是 Scroll + Column：只有 List/Grid/Swiper/WaterFlow 才让 LazyForEach
    // 按可视区建组件。Hero 仍是普通 ListItem（不进 LazyForEach，同 iOS：大图别放进懒加载里）。
    List() {
      // Hero 块：加载中出骨架，有 Hero 出轮播；都没有就不占 ListItem（避免顶部凭空多 24）
      if (this.feed.layout === null) {
        ListItem() {
          this.HeroSkeleton()
        }
        .padding({ bottom: 24 })
      } else if (this.feed.hero !== null && (this.feed.hero as DiscoveredTitleView[]).length > 0) {
        ListItem() {
          this.Hero()
        }
        .padding({ bottom: 24 })
      }

      if (this.feed.layout === null) {
        ListItem() {
          this.RowSkeleton()
        }
        .padding({ bottom: 24 })
        ListItem() {
          this.RowSkeleton()
        }
        .padding({ bottom: 24 })
      } else {
        LazyForEach(this.rowsSource, (row: DiscoverRow) => {
          ListItem() {
            DiscoverRowView({
              row: row,
              origin: AppModel.origin(),
              onOpenTitle: (item: DiscoveredTitleView): void => {
                this.openTitle(item);
              },
              onOpenAll: (): void => {
                this.toast('「全部列表」建设中');
              }
            })
          }
          .padding({ bottom: 24 })
        }, (row: DiscoverRow) => row.ref)
        if (this.mediaType === 'movie' && this.source === 'tmdb') {
          ListItem() {
            this.RegionFooter()
          }
          .padding({ bottom: 24 })
        }
      }
      ListItem() {
        AppFooter()
      }
    }
    .scrollBar(BarState.Off)
    .width('100%')
    .layoutWeight(1)
    .edgeEffect(EdgeEffect.Spring)
    // 可视区上下各多缓存两行，快速滑动少建少销毁
    .cachedCount(2)
    .padding({ bottom: Theme.tabBarInset })
  }

  /**
   * 沉浸 Hero 轮播（对应 iOS `DiscoverHero` + `DiscoverHeroSlide`）。
   *
   * 版式照 iOS：右下角是「8 秒填满」式指示器（不是圆点跳变），
   * 文字区左对齐、左右各 16、底部 28、**右侧留 60 给指示器**，
   * 自上而下是「今日精选 · 电影/剧集」眉行 → 片名（30 粗体）→ 原名 → 元信息行 → 简介（2 行）→ 订阅键。
   */
  @Builder
  Hero() {
    Stack({ alignContent: Alignment.BottomStart }) {
      Swiper(this.heroController) {
        ForEach(this.feed.hero ?? [], (item: DiscoveredTitleView) => {
          Stack({ alignContent: Alignment.BottomStart }) {
            RemoteImage({ url: this.backdropUrl(item) })
              .width('100%')
              .height('100%')
            Column()
              .width('100%')
              .height('55%')
              .linearGradient({ angle: 180, colors: [['rgba(0,0,0,0)', 0], [Theme.bg, 1]] })
            this.HeroSlideText(item)
          }
          .width('100%')
          .height('100%')
          .onClick(() => {
            this.openTitle(item);
          })
        }, (item: DiscoveredTitleView) => item.title_ref)
      }
      .autoPlay(false)
      .loop(true)
      .indicator(false)
      .width('100%')
      .height('100%')
      .onChange((index: number): void => {
        // 手动滑动也把进度归零重来（同 iOS 的 rotation）
        this.heroIndex = index;
        this.heroFill = 0;
      })

      if ((this.feed.hero ?? []).length > 1) {
        this.HeroIndicator()
      }
    }
    .width('100%')
    .height(this.heroHeight)
  }

  /** Hero 文字区（对应 iOS `DiscoverHeroSlide` 的 VStack） */
  @Builder
  HeroSlideText(item: DiscoveredTitleView) {
    Column({ space: 6 }) {
      Text(`今日精选 · ${item.media_type === 'tv' ? '剧集' : '电影'}`)
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .letterSpacing(2.5)
        .fontColor(Theme.accent2)
      Text(item.title)
        .fontSize(30)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.text)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (item.original_title.length > 0 && item.original_title !== item.title) {
        Text(item.original_title)
          .fontSize(12)
          .fontColor(Theme.textMuted)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      this.HeroMeta(item)
      if (item.overview.length > 0) {
        Text(item.overview)
          .fontSize(15)
          .fontColor(Theme.textMuted)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      if (this.canSubscribe()) {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.plus'))
            .fontSize(15)
            .fontColor(['#0b0d12'])
          Text('订阅影片')
            .fontSize(15)
            .fontWeight(600)
            .fontColor('#0b0d12')
        }
        .padding({ left: 16, right: 16, top: 9, bottom: 9 })
        .backgroundColor(Theme.accent)
        .borderRadius(18)
        .margin({ top: 6 })
        .onClick(() => {
          SubscribeCenter.present(item.title_ref, item.title);
        })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 60, bottom: 28 })
  }

  /**
   * Hero 元信息行（对应 iOS 的 `meta`）：**用 HStack 的间距分隔，不是「 · 」拼字符串**，
   * 顺序是 ★评分 → 年份 → 类型（用 ` / ` 连接）→ 时长 → 在库。
   */
  @Builder
  HeroMeta(item: DiscoveredTitleView) {
    Row({ space: 10 }) {
      if ((item.provider_rating ?? 0) > 0) {
        Row({ space: 3 }) {
          SymbolGlyph($r('sys.symbol.star_fill'))
            .fontSize(13)
            .fontColor([Theme.warn])
          Text(item.provider_rating.toFixed(1))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text)
        }
      }
      if (item.release_year !== null && item.release_year !== undefined) {
        Text(`${item.release_year}`)
          .fontSize(15)
          .fontColor(Theme.textMuted)
      }
      if (item.genres.length > 0) {
        Text(item.genres.join(' / '))
          .fontSize(15)
          .fontColor(Theme.textMuted)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      if (item.extent_label.length > 0) {
        Text(item.extent_label)
          .fontSize(15)
          .fontColor(Theme.textMuted)
      }
      if (this.inLibrary(item)) {
        Row({ space: 4 }) {
          Circle()
            .width(6)
            .height(6)
            .fill(Theme.ok)
          Text('在库')
            .fontSize(15)
            .fontColor(Theme.ok)
        }
      }
    }
    .width('100%')
  }

  /** 右下角指示器：当前格按 8 秒填满（对应 iOS `ImmersiveHeroIndicator`） */
  @Builder
  HeroIndicator() {
    Row({ space: 6 }) {
      ForEach(this.feed.hero ?? [], (item: DiscoveredTitleView, index: number) => {
        Stack({ alignContent: Alignment.Start }) {
          Row()
            .width('100%')
            .height('100%')
            .backgroundColor('rgba(255,255,255,0.3)')
            .borderRadius(2)
          if (index === this.heroIndex) {
            Row()
              .width(`${Math.round(this.heroFill * 100)}%`)
              .height('100%')
              .backgroundColor(Theme.text)
              .borderRadius(2)
          } else if (index < this.heroIndex) {
            Row()
              .width('100%')
              .height('100%')
              .backgroundColor('rgba(255,255,255,0.55)')
              .borderRadius(2)
          }
        }
        .width(index === this.heroIndex ? 24 : 12)
        .height(4)
      }, (item: DiscoveredTitleView) => item.title_ref)
    }
    // iOS 是指示器在**右下角**（`.overlay(alignment: .bottomTrailing)` + trailing 20 / bottom 16）
    .width('100%')
    .justifyContent(FlexAlign.End)
    .padding({ right: 20, bottom: 16 })
  }

  /** 条目是否已入库（Hero 元信息行末尾的绿点「在库」） */
  private inLibrary(item: DiscoveredTitleView): boolean {
    const status = item.library_status;
    return status !== null && status !== undefined && (status.library_count ?? 0) > 0;
  }

  private canSubscribe(): boolean {
    return Permissions.fromSession(AppModel.shared.session).canSubscribe;
  }

  @Builder
  HeroSkeleton() {
    Column()
      .width('100%')
      .height(340)
      .backgroundColor(Theme.surface)
  }

  @Builder
  RowSkeleton() {
    Column({ space: 12 }) {
      Text(' ')
        .fontSize(19)
        .height(24)
      Row({ space: 12 }) {
        ForEach([0, 1, 2], (index: number) => {
          Column()
            .width(124)
            .aspectRatio(Theme.posterAspect)
            .backgroundColor(Theme.surface)
            .borderRadius(Theme.cardRadius)
        }, (index: number) => `${index}`)
      }
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 院线地区脚注（对应 iOS DiscoverRegionFooter） */
  @Builder
  RegionFooter() {
    if (this.region.length > 0) {
      Row({ space: 6 }) {
        Text('院线地区')
          .fontSize(12)
          .fontColor(Theme.textFaint)
        Text(this.region)
          .fontSize(12)
          .fontColor(Theme.textMuted)
        if (this.regionEditable) {
          Text('更改')
            .fontSize(12)
            .fontColor(Theme.accentStrong)
            .onClick(() => {
              this.toast('「更改院线地区」建设中');
            })
        }
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ top: 4, bottom: 8 })
    }
  }

  private backdropUrl(item: DiscoveredTitleView): string {
    const raw: string | null = item.backdrop_url ?? item.poster_url ?? null;
    return ImageUrls.resolve(AppModel.origin(), raw, ImageVariant.landscapeCard) ?? '';
  }
}

/**
 * 一行片单（对应 iOS `row(section:feed:)`）。
 *
 * 独立成 `@ComponentV2` 是关键：它读 `row.state` / `row.items` 这两个 `@Trace` 字段，
 * 字段一变**这一行自己重绘**，与 `ForEach` 的 key 无关。
 * V1 写法做不到，只能把状态编进 key 把整行重建（见 docs/harmonyos-port.md §10）。
 */
@ComponentV2
struct DiscoverRowView {
  @Require @Param row: DiscoverRow;
  @Require @Param origin: string;
  @Require @Param onOpenTitle: (item: DiscoveredTitleView) => void;
  @Require @Param onOpenAll: () => void;

  build() {
    // 失败的行整行收起（同 iOS）；加载中出骨架
    if (this.row.state === DiscoverRowState.loaded && this.row.items.length > 0) {
      Column({ space: 12 }) {
        Row() {
          Text(this.row.title)
            .fontSize(19)
            .fontWeight(600)
            .fontColor(Theme.text)
          Blank()
          if (this.row.supportsFullListing) {
            Text('全部')
              .fontSize(13)
              .fontColor(Theme.textFaint)
              .onClick(() => {
                this.onOpenAll();
              })
          }
        }
        .width('100%')
        .padding({ left: Theme.pagePadding, right: Theme.pagePadding })

        Scroll() {
          Row({ space: 12 }) {
            ForEach(this.row.items, (item: DiscoveredTitleView) => {
              this.PosterCard(item)
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
    } else if (this.row.state === DiscoverRowState.loading) {
      Column({ space: 12 }) {
        Text(' ')
          .fontSize(19)
          .height(24)
        Row({ space: 12 }) {
          ForEach([0, 1, 2], (index: number) => {
            Column()
              .width(124)
              .aspectRatio(Theme.posterAspect)
              .backgroundColor(Theme.surface)
              .borderRadius(Theme.cardRadius)
          }, (index: number) => `${index}`)
        }
        .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** 海报卡：图 + 片名 + 年份/评分 + 已入库角标 */
  @Builder
  PosterCard(item: DiscoveredTitleView) {
    Column({ space: 6 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        RemoteImage({
          url: ImageUrls.resolve(this.origin, item.poster_url, ImageVariant.posterCard) ?? ''
        })
          .width('100%')
          .height('100%')
        if (this.inLibrary(item)) {
          Text('已入库')
            .fontSize(11)
            .fontColor('#0b0d12')
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .backgroundColor(Theme.accent)
            .borderRadius(6)
            .margin({ top: 6, right: 6 })
        }
      }
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
      this.onOpenTitle(item);
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

  private inLibrary(item: DiscoveredTitleView): boolean {
    const status = item.library_status;
    return status !== null && status !== undefined && (status.library_count ?? 0) > 0;
  }
}
