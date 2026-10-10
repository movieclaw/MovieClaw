import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Theme } from '../theme/AppTheme';
import { ImageUrls, ImageVariant } from '../common/ImageUrls';
import { RemoteImage } from '../common/RemoteImage';
import { ShellChrome } from '../common/ShellChrome';
import { AppModel } from '../common/AppModel';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import {
  FacetValueView,
  PlaybackMarksRequest,
  PlaybackMarksView,
  ReelFacetsView,
  ReelFeedView,
  ReelItemView,
  ReelTitleView,
  ShareCreateRequest,
  ShareView
} from '../api/Models';
import { SharePanel, shareMessage } from '../library/ShareSheet';
import { PlayerParams } from '../player/PlayerPage';
import { ItemRouteParams } from '../library/LibraryItemDetailPage';
import { PersonParams } from '../discover/PersonDetailPage';

/** 片段页的路由参数（会序列化，不要用 instanceof） */
export class ReelsParams {
  readonly libraryId: number;
  /** 可选的类型筛选（对应 iOS 顶部「全部 ⌄」） */
  readonly kind: string;

  constructor(libraryId: number = 0, kind: string = '') {
    this.libraryId = libraryId;
    this.kind = kind;
  }

  static of(param: Object | undefined | null): ReelsParams {
    if (param === undefined || param === null) {
      return new ReelsParams();
    }
    const raw: ReelsParams = param as ReelsParams;
    const id: number = raw.libraryId;
    const kind: string = raw.kind;
    return new ReelsParams(Number.isFinite(id) ? Math.floor(id) : 0,
      kind === undefined || kind === null ? '' : kind);
  }
}

/** 路由表注册用（router_map.json 的 buildMethod） */
@Builder
export function ReelsBuilder() {
  ReelsPage()
}

/**
 * 片段 feed 的数据源（Swiper 里 LazyForEach 用）。
 *
 * 整屏上下翻的 feed 是分页累加的（首屏 8 条、翻到接近末尾再补 8 条）。
 * 用 LazyForEach 后只建当前页附近的全屏 Stack（每个都挂着封面 RemoteImage + Overlay），
 * 不必一次把几十页全建出来——非当前页本来也不挂 XComponent 解码器，但封面和信息层仍是开销。
 *
 * 首屏/换类型筛选 = 整批换（setItems → onDataReloaded）；翻页补量 = 尾部追加（onDataAdd）。
 */
class ReelItemsSource implements IDataSource {
  private items: ReelItemView[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): ReelItemView {
    return this.items[index];
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

  setItems(items: ReelItemView[]): void {
    this.items = items;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }

  appendItems(items: ReelItemView[]): void {
    if (items.length === 0) {
      return;
    }
    for (const item of items) {
      this.items.push(item);
    }
    // 本 SDK 的 onDataAdd(index) 只收 1 个参数，且翻页补量频率低、整体重载开销可忽略，
    // 直接 onDataReloaded（与仓库「整体换数据 → onDataReloaded」范式一致）。
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }
}

/**
 * 片段（对应 iOS `ReelsView`，878 行——**本轮是 v1**）。
 *
 * 产品形态照 iOS：**上下整页滑动**，每页是某部片里挑出的 30～60 秒。
 * 版式也照它：纯黑底、影片居中、左上是片名 + 年份（点了去详情页）、
 * 左下是简介、右边一列图标按钮、最底下一条细进度线（**按片段算，不按整部片**）、
 * 点页面任意空白处暂停 / 继续。
 *
 * 播放用 `XComponent(SURFACE)` + `AVPlayer`，从 `segment.start_ms` 起播、
 * 到 `segment.end_ms` 停下（再点重播）——**一个时刻只存在一个播放器**，
 * 翻页时把上一个收掉，否则滑十几页会开十几个解码器。
 *
 * **v1 没做**（iOS 有）：手势层（双击 ∓10 秒 / 长按 2 倍速）、横滑不拖进度（这条本来就该「不做」）、
 * 暂停时的播放标记与实时加载速度、剧照模糊铺满整页、`全屏观看` 的**片段模式**
 * （现在只能从片段起点开始放整片，时间轴不是那一段）、画质胶囊、片尾自动翻页、
 * 「全部 ⌄」类型筛选（参数留了但没接界面）、收藏 / 已看 / 分享三个按钮
 * （**客户端根本没有切换收藏的端点**，所以不做死按钮）、导演行（人物页还没做）。
 */
@ComponentV2
export struct ReelsPage {
  private navStack: NavPathStack = new NavPathStack();
  private chrome: ShellChrome = ShellChrome.shared;
  private started: boolean = false;
  private player: media.AVPlayer | null = null;
  private surfaceController: XComponentController = new XComponentController();
  private tick: number = -1;

  @Local private loading: boolean = true;
  @Local private failed: boolean = false;
  @Local private errorMessage: string = '';
  @Local private items: ReelItemView[] = [];
  /** feed 的懒加载数据源（Swiper 里 LazyForEach 用），与 this.items 保持同序 */
  private itemsSource: ReelItemsSource = new ReelItemsSource();
  @Local private index: number = 0;
  @Local private playing: boolean = false;
  /** 当前这一条收藏 / 已看（点了就把状态推到服务端） */
  @Local private favorite: boolean = false;
  @Local private played: boolean = false;
  /** 类型筛选（对应 iOS 右上的「全部 ⌄」） */
  @Local private kinds: FacetValueView[] = [];
  @Local private kind: string = '';
  /** 分享面板（本页 sheet 槽位是空的） */
  @Local private showShare: boolean = false;
  @Local private shareBusy: boolean = false;
  @Local private share: ShareView | null = null;
  @Local private paused: boolean = false;
  @Local private positionMs: number = 0;

  aboutToDisappear(): void {
    this.chrome.pop('reels');
    this.stopTick();
    this.releasePlayer();
  }

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  /** 类型筛选的候选（后端给的分面） */
  private async loadKinds(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      const facets: ReelFacetsView = await api.reelsFacets();
      this.kinds = facets.kinds;
    } catch (error) {
      this.kinds = [];
    }
  }

  @Builder
  KindMenu() {
    Menu() {
      MenuItem({ content: '全部' })
        .onClick(() => {
          this.kind = '';
          this.load();
        })
      ForEach(this.kinds, (entry: FacetValueView) => {
        MenuItem({ content: `${entry.label} ${entry.count}` })
          .onClick(() => {
            this.kind = entry.value;
            this.load();
          })
      }, (entry: FacetValueView) => `k-${entry.value}`)
    }
  }

  /** 当前这一条的收藏 / 已看状态（从条目详情那一路拿，不对就先按 false 显示） */
  private syncMarks(): void {
    const item: ReelItemView | null = this.current();
    this.favorite = item !== null ? item.title.favorite : false;
    // 片段模型里没有 seen 字段，先按 false；点过之后由服务端返回的真值接管
    this.played = false;
  }

  /** 收藏（`playbackMarksSet`，同条目详情页） */
  private async toggleFavorite(item: ReelItemView): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    const next: boolean = !this.favorite;
    this.favorite = next;
    try {
      const body: PlaybackMarksRequest = {
        media_item_id: item.title.media_item_id,
        favorite: next
      };
      const marks: PlaybackMarksView = await api.playbackMarksSet(body);
      this.favorite = marks.is_favorite;
    } catch (error) {
      this.favorite = !next;
      this.toast('操作失败，请重试');
    }
  }

  /** 标为已看 / 没看过 */
  private async togglePlayed(item: ReelItemView): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    const next: boolean = !this.played;
    this.played = next;
    try {
      const body: PlaybackMarksRequest = {
        media_item_id: item.title.media_item_id,
        played: next
      };
      const marks: PlaybackMarksView = await api.playbackMarksSet(body);
      this.played = marks.played;
    } catch (error) {
      this.played = !next;
      this.toast('操作失败，请重试');
    }
  }

  /** 分享这一条（复用条目分享面板） */
  private async openShare(item: ReelItemView): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.showShare = true;
    this.shareBusy = true;
    try {
      this.share = await api.libraryItemsShareGet(item.title.library_id, item.title.media_item_id);
    } catch (error) {
      this.share = null;
    } finally {
      this.shareBusy = false;
    }
  }

  private async createShare(days: number, password: string): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const item: ReelItemView | null = this.current();
    if (api === null || item === null) {
      return;
    }
    this.shareBusy = true;
    try {
      const payload: ShareCreateRequest = {
        expires_in_days: days > 0 ? days : null,
        password: password.length > 0 ? password : null
      };
      this.share = await api.libraryItemsShareCreate(item.title.library_id,
        item.title.media_item_id, payload);
      this.toast('链接已生成');
    } catch (error) {
      this.toast(shareMessage(error));
    } finally {
      this.shareBusy = false;
    }
  }

  private async revokeShare(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const item: ReelItemView | null = this.current();
    if (api === null || item === null) {
      return;
    }
    this.shareBusy = true;
    try {
      await api.libraryItemsShareRevoke(item.title.library_id, item.title.media_item_id);
      this.share = null;
      this.toast('已停止分享');
    } catch (error) {
      this.toast(shareMessage(error));
    } finally {
      this.shareBusy = false;
    }
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private stopTick(): void {
    if (this.tick >= 0) {
      clearInterval(this.tick);
      this.tick = -1;
    }
  }

  private async releasePlayer(): Promise<void> {
    const player: media.AVPlayer | null = this.player;
    this.player = null;
    if (player !== null) {
      try {
        await player.release();
      } catch (error) {
        // 已经释放过就忽略
      }
    }
  }

  private async load(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.loading = true;
    try {
      const view: ReelFeedView = await api.reelsFeed(undefined, this.index, 8,
        undefined, this.kind.length > 0 ? this.kind : undefined);
      this.items = view.items;
      this.itemsSource.setItems(view.items);
      this.failed = false;
      this.errorMessage = '';
      this.syncMarks();
      if (this.kinds.length === 0) {
        this.loadKinds();
      }
      if (this.items.length > 0) {
        this.playCurrent();
      }
    } catch (error) {
      this.failed = true;
      this.errorMessage = this.messageOf(error);
    } finally {
      this.loading = false;
    }
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '加载失败';
  }

  private current(): ReelItemView | null {
    if (this.index < 0 || this.index >= this.items.length) {
      return null;
    }
    return this.items[this.index];
  }

  /** 这一段的时长（片段自己的，不是整部片的） */
  private clipDuration(): number {
    const item: ReelItemView | null = this.current();
    if (item === null) {
      return 1;
    }
    const span: number = item.segment.end_ms - item.segment.start_ms;
    return span > 0 ? span : 1;
  }

  // MARK: 播放

  /** 翻页时调：先把上一个收掉，再起这一个 */
  private async playCurrent(): Promise<void> {
    const item: ReelItemView | null = this.current();
    if (item === null) {
      return;
    }
    // 翻页就换播放器：**一个时刻只留一个**，否则滑十几页会开十几个解码器
    await this.releasePlayer();
    this.stopTick();
    this.paused = false;
    this.positionMs = 0;

    const url: string | null = item.play.stream_url ?? null;
    if (url === null || url.length === 0) {
      // 这一条服务端没给出流（片段还在准备 / 直出不可用）：停在这一页并说明
      this.playing = false;
      this.failed = true;
      this.errorMessage = '这一段还没准备好，往下一段看看';
      return;
    }
    this.failed = false;
    try {
      const player: media.AVPlayer = await media.createAVPlayer();
      this.player = player;
      this.bind(player, item.segment.start_ms, item.segment.end_ms);
      player.url = AppModel.origin() + url;
      await player.prepare();
      this.playing = true;
      player.play();
      this.startTick();
    } catch (error) {
      const e = error as BusinessError;
      this.playing = false;
      this.failed = true;
      this.errorMessage = `放不了这一段（${e.code ?? -1}）`;
    }
  }

  /** 服务端给的流地址是相对路径，要拼上当前服务地址 */
  private bind(player: media.AVPlayer, startMs: number, endMs: number): void {
    player.on('stateChange', (state: string): void => {
      if (state === 'initialized') {
        player.prepare();
      }
    });
    player.on('error', (error: BusinessError): void => {
      this.playing = false;
      this.failed = true;
      this.errorMessage = `放不了这一段：${error.message}`;
    });
    player.on('timeUpdate', (time: number): void => {
      this.positionMs = time - startMs;
      // **到片段终点就停**——片段是「从整片里切出来的一段」，不是整片
      if (endMs > startMs && time >= endMs) {
        player.pause();
        this.paused = true;
      }
    });
  }

  /** 进度线按片段算（同 iOS：最底下那条细线不按整部片） */
  private startTick(): void {
    this.stopTick();
    this.tick = setInterval((): void => {
      const duration: number = this.clipDuration();
      if (this.positionMs >= duration) {
        this.stopTick();
      }
    }, 500);
  }

  private togglePause(): void {
    const player: media.AVPlayer | null = this.player;
    if (player === null) {
      return;
    }
    if (this.paused) {
      // 放到终点了再点 = 重播这一段
      if (this.positionMs >= this.clipDuration() - 300) {
        const item: ReelItemView | null = this.current();
        if (item !== null) {
          player.seek(item.segment.start_ms, media.SeekMode.SEEK_CLOSEST);
          this.positionMs = 0;
        }
      }
      player.play();
      this.paused = false;
    } else {
      player.pause();
      this.paused = true;
    }
  }

  // MARK: 导航

  private openDetail(): void {
    const item: ReelItemView | null = this.current();
    if (item === null) {
      return;
    }
    const title: ReelTitleView = item.title;
    /*
     * 只带库与条目 id：**`ReelItemView` 里没有季集号字段**
     * （`ReelSegmentView` 上只有 file_id / start_ms / end_ms / method，
     * 我之前把 `ReelSubtitleView.ordinal` 误当成了集号），所以定位不到具体某一集。
     * 传 null 让详情页自己决定落在哪一季，而不是瞎传一个 0。
     */
    this.navStack.pushPathByName('libraryItem',
      new ItemRouteParams(title.library_id, title.media_item_id, null, null));
  }

  private openFullScreen(): void {
    const item: ReelItemView | null = this.current();
    if (item === null) {
      return;
    }
    // file_id 在 `segment` 上（`play` 里没有），季集号同样没有就不传
    this.navStack.pushPathByName('player',
      new PlayerParams(item.title.media_item_id, item.segment.file_id, 0, 0,
        item.segment.start_ms));
  }

  // MARK: 视图

  build() {
    NavDestination() {
      Column() {
        if (this.failed && this.items.length === 0) {
          this.ErrorState()
        } else if (this.loading && this.items.length === 0) {
          this.LoadingState()
        } else {
          this.Feed()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#000000')
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
      // 整屏页：收起底部标签栏（iOS 同款行为）
      this.chrome.push('reels');
      if (!this.started) {
        this.started = true;
        this.load();
      }
    })
  }

  @Builder
  LoadingState() {
    Column({ space: 10 }) {
      LoadingProgress().width(24).height(24).color(Theme.textMuted)
      Text('正在挑片段…').fontSize(13).fontColor(Theme.textFaint)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  ErrorState() {
    Column({ space: 10 }) {
      Text('片段加载失败').fontSize(15).fontColor(Theme.text)
      Text(this.errorMessage).fontSize(13).fontColor(Theme.textMuted).textAlign(TextAlign.Center)
      Text('重试').fontSize(14).fontColor(Theme.accentStrong).onClick(() => {
        this.load();
      })
    }
    .width('100%')
    .layoutWeight(1)
    .padding(24)
    .justifyContent(FlexAlign.Center)
  }

  /** 整页上下滑（iOS 用的就是整页翻，不是列表） */
  @Builder
  TopLeftBack() {
    // iOS：片段页左上有返回键（不带返回键时有人不知道怎么回去）
    SymbolGlyph($r('sys.symbol.chevron_left'))
      .fontSize(20)
      .fontColor(['#ffffff'])
      .width(38)
      .height(38)
      .backgroundColor('rgba(0,0,0,0.45)')
      .borderRadius(19)
      .onClick(() => {
        this.navStack.pop();
      })
  }

  @Builder
  Feed() {
    Swiper() {
      LazyForEach(this.itemsSource, (item: ReelItemView) => {
        Stack() {
          // 画面：一条 16:9 的横带居中
          Column() {
            if (item.id === (this.current() !== null ? (this.current() as ReelItemView).id : '')) {
              Stack() {
                XComponent({
                  id: 'reel-surface',
                  type: XComponentType.SURFACE,
                  controller: this.surfaceController
                })
                  .width('100%')
                  .height('100%')
                /*
                 * **没出第一帧前用横版剧照顶着**（iOS：`没出第一帧前横带里放横版剧照`）。
                 * 不这么做的话，转码还没出片时横带就是一块纯黑——用户以为坏了。
                 */
                if (!this.playing) {
                  this.Cover(item)
                }
              }
              .width('100%')
              .aspectRatio(16 / 9)
            } else {
              // 非当前页不挂 surface（省解码器），用封面顶着
              this.Cover(item)
            }
            // 暂停时横带正中出播放标记（iOS：`暂停时横带正中出播放标记`）
            if (this.paused && item.id === (this.current() !== null
              ? (this.current() as ReelItemView).id : '')) {
              SymbolGlyph($r('sys.symbol.play_fill'))
                .fontSize(40)
                .fontColor(['rgba(255,255,255,0.9)'])
                .shadow({ radius: 10, color: 'rgba(0,0,0,0.7)', offsetX: 0, offsetY: 2 })
            }
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)

          // 点空白处暂停 / 继续（同抖音）
          Column()
            .width('100%')
            .height('100%')
            .onClick(() => {
              if (item.id === (this.current() !== null ? (this.current() as ReelItemView).id : '')) {
                this.togglePause();
              }
            })

          Column() {
            Row() {
              this.TopLeftBack()
              Blank()
            }
            .width('100%')
            .padding({ left: 16, top: Theme.statusBarInset + 8 })
            Blank()
          }
          .width('100%')
          .height('100%')

          this.Overlay(item)
        }
        .width('100%')
        .height('100%')
      }, (item: ReelItemView) => item.id)
    }
    .vertical(true)
    .loop(false)
    .indicator(false)
    .index(this.index)
    .onChange((index: number): void => {
      this.index = index;
      this.syncMarks();
      // 翻页就换片段；滑到接近末尾时补一批
      this.playCurrent();
      if (index >= this.items.length - 2) {
        this.loadMore();
      }
    })
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  /**
   * 横带里的剧照。
   *
   * **必须走 `ImageUrls` 解析 + `RemoteImage`**：后端给的是相对路径
   * （`/images/assets/103/reels/3641/…jpg?v=…`），直接 `Image(url)` 既没有服务器地址、
   * 也没有登录头，只会得到一块黑（实测就是黑的）。装图用 `RemoteImage`——
   * 它带账号令牌，也正是 `ImageVariant.reelStill`（「刷片等画面时垫在横带里的剧照」）的用途。
   */
  @Builder
  Cover(item: ReelItemView) {
    Column() {
      RemoteImage({
        url: this.stillUrl(item),
        placeholderSymbol: $r('sys.symbol.film')
      })
        .width('100%')
        .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#111111')
  }

  /** 剧照地址（相对路径 → 可请求的 URL） */
  private stillUrl(item: ReelItemView): string {
    const resolved: string | null =
      ImageUrls.resolve(AppModel.origin(), item.cover_url ?? null, ImageVariant.reelStill);
    return resolved !== null ? resolved : '';
  }

  /** 信息层：左上片名 + 年份（可点去详情）、左下简介、右侧按钮、底部细进度线 */
  /**
   * 信息层（逐条对齐 iOS `ReelsView` 的版式说明）：
   * 左上返回玻璃键；**正中片名 + 年份的玻璃胶囊**（点了去详情页）；右上「全部 ⌄」；
   * 横带下方「全屏观看」描边胶囊；右下**一列无底色的白色图标**（收藏 / 详情 / 已看 / 分享）；
   * 左下导演与简介；最底一条细进度线。
   */
  @Builder
  Overlay(item: ReelItemView) {
    Column() {
      // —— 顶部一行：返回 …… 片名胶囊 …… 全部 ——
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(20)
          .fontColor(['#ffffff'])
          .width(38)
          .height(38)
          .backgroundColor('rgba(0,0,0,0.45)')
          .borderRadius(19)
          .onClick(() => {
            this.navStack.pop();
          })
        Blank()
        // 右上一个玻璃胶囊「全部 ⌄」（类型筛选；没接后端筛选时也保留入口位置）
        Text('全部')
          .fontSize(13)
          .fontColor('#ffffff')
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .backgroundColor('rgba(0,0,0,0.45)')
          .borderRadius(18)
          .border({ width: 1, color: 'rgba(255,255,255,0.28)' })
          .bindMenu(this.KindMenu())
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: Theme.statusBarInset + 8 })

      // 正中片名胶囊：片名 + 第二行年份/类型，点了去这部片的详情页（同「照片」App 顶部的地点胶囊）
      Row() {
        Column({ space: 1 }) {
          Text(item.title.name)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor('#ffffff')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.subtitleOf(item))
            .fontSize(11)
            .fontColor('rgba(255,255,255,0.75)')
            .maxLines(1)
        }
        .alignItems(HorizontalAlign.Center)
      }
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .backgroundColor('rgba(0,0,0,0.45)')
      .borderRadius(18)
      .margin({ top: 8 })
      .onClick(() => {
        this.openDetail();
      })

      Blank()

      // —— 横带下方一行：「全屏观看」描边胶囊（画质胶囊在它左边）——
      Row({ space: 8 }) {
        Text('全屏观看')
          .fontSize(12)
          .fontColor('#ffffff')
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .backgroundColor('rgba(0,0,0,0.35)')
          .borderRadius(16)
          .border({ width: 1, color: 'rgba(255,255,255,0.5)' })
          .onClick(() => {
            this.openFullScreen();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .opacity(this.playing && !this.paused ? 0.45 : 1)
      .margin({ bottom: 10 })

      // —— 底部：左边导演+简介，右边一列图标 ——
      Row() {
        Column({ space: 8 }) {
          // 导演行（剧集是主创）：头像 + 名字 + 身份，点了进库内影人页（对应 Instagram「头像 · 作者名」那一行）
          if (item.title.directors.length > 0) {
            this.DirectorRow(item)
          }
          Text(item.title.overview ?? '')
            .fontSize(12)
            .fontColor('rgba(255,255,255,0.82)')
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // 右下角一列**无底色**的白色图标（不用毛玻璃，和画面融在一起；带投影保证亮画面上也看得清）
        Column({ space: 16 }) {
          this.GlyphAction(this.favorite ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'),
            this.favorite ? '已收藏' : '收藏', this.favorite, (): void => {
              this.toggleFavorite(item);
            })
          this.GlyphAction($r('sys.symbol.film'), '详情', false, (): void => {
            this.openDetail();
          })
          this.GlyphAction($r('sys.symbol.checkmark_circle'), this.played ? '已看过' : '没看过',
            this.played, (): void => {
              this.togglePlayed(item);
            })
          this.GlyphAction($r('sys.symbol.paperplane'), '分享', false, (): void => {
            this.openShare(item);
          })
        }
        .padding({ left: 12 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
      .padding({ left: 16, right: 16 })

      // 最底下一条细进度线（按片段算，不按整部片）
      Stack({ alignContent: Alignment.Start }) {
        Column()
          .width('100%')
          .height(2)
          .backgroundColor('rgba(255,255,255,0.25)')
        Column()
          .width(`${Math.min(100, Math.max(0, this.positionMs / this.clipDuration() * 100))}%`)
          .height(2)
          .backgroundColor('#ffffff')
      }
      .width('100%')
      .height(2)
      .margin({ top: 12, bottom: 10 })
    }
    .width('100%')
    .height('100%')
  }

  /** 分享面板的壳 */
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

  /** 右下角一颗无底色图标（带投影，亮画面上也看得清）；选中态用强调色 */
  @Builder
  GlyphAction(icon: Resource, label: string, active: boolean, onTap: () => void) {
    Column({ space: 3 }) {
      SymbolGlyph(icon)
        .fontSize(26)
        .fontColor([active ? Theme.accent : '#ffffff'])
        .shadow({ radius: 6, color: 'rgba(0,0,0,0.6)', offsetX: 0, offsetY: 1 })
      Text(label)
        .fontSize(10)
        .fontColor('rgba(255,255,255,0.9)')
        .shadow({ radius: 6, color: 'rgba(0,0,0,0.6)', offsetX: 0, offsetY: 1 })
    }
    .onClick(() => {
      onTap();
    })
  }

  /** 导演行（剧集是主创）：头像 + 名字 + 身份，点了进库内影人页（同 iOS directorRow） */
  @Builder
  DirectorRow(item: ReelItemView) {
    Row({ space: 8 }) {
      Stack() {
        Text(item.title.directors.length > 0
          ? item.title.directors[0].name.substring(0, 1) : '?')
          .fontSize(14)
          .fontColor('rgba(255,255,255,0.55)')
        if (item.title.directors[0].avatar_url !== null
          && item.title.directors[0].avatar_url !== undefined
          && (item.title.directors[0].avatar_url as string).length > 0) {
          RemoteImage({
            url: ImageUrls.resolve(AppModel.origin(),
              item.title.directors[0].avatar_url ?? null, ImageVariant.photoTile) ?? '',
            placeholderSymbol: $r('sys.symbol.person')
          })
            .width('100%')
            .height('100%')
        }
      }
      .width(32)
      .height(32)
      .backgroundColor('rgba(255,255,255,0.18)')
      .borderRadius(16)
      .clip(true)
      .border({ width: 0.5, color: 'rgba(255,255,255,0.25)' })
      Text(this.directorNames(item))
        .fontSize(14)
        .fontWeight(600)
        .fontColor('#ffffff')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(item.title.kind === 'tv' ? '主创' : '导演')
        .fontSize(14)
        .fontColor('rgba(255,255,255,0.65)')
        .maxLines(1)
    }
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      // 只有姓名（没有 TMDB 影人 id）时不可点（同 iOS disabled）
      const id: number = item.title.directors[0].tmdb_person_id ?? 0;
      if (id > 0) {
        this.navStack.pushPathByName('person', new PersonParams(id));
      }
    })
  }

  private directorNames(item: ReelItemView): string {
    const names: string[] = [];
    for (const person of item.title.directors) {
      names.push(person.name);
    }
    return names.join(' / ');
  }

  private subtitleOf(item: ReelItemView): string {
    const parts: string[] = [];
    const year: number | null = item.title.year ?? null;
    if (year !== null && year > 0) {
      parts.push(`${year}`);
    }
    if (item.title.genres.length > 0) {
      parts.push(item.title.genres.slice(0, 2).join(' / '));
    }
    if (this.paused) {
      parts.push('已暂停');
    }
    return parts.join('  ·  ');
  }

  private async loadMore(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      const view: ReelFeedView = await api.reelsFeed(undefined, this.items.length, 8);
      // 追加时去重（后端可能因为排名变化给出重复项）
      const seen: Set<string> = new Set<string>();
      for (const item of this.items) {
        seen.add(item.id);
      }
      const fresh: ReelItemView[] = [];
      for (const item of view.items) {
        if (!seen.has(item.id)) {
          seen.add(item.id);
          this.items.push(item);
          fresh.push(item);
        }
      }
      this.itemsSource.appendItems(fresh);
    } catch (error) {
      // 补量失败不打扰：已经有的还能看
    }
  }
}
