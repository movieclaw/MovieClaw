import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Theme } from '../theme/AppTheme';
import { ImageUrls, ImageVariant } from '../common/ImageUrls';
import { RemoteImage } from '../common/RemoteImage';
import { ShellChrome } from '../common/ShellChrome';
import { AppModel, ClipReturn } from '../common/AppModel';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import {
  FacetValueView,
  PlaybackMarksRequest,
  PlaybackMarksView,
  ReelClipProgressView,
  ReelFacetsView,
  ReelFeedView,
  ReelItemView,
  ReelTitleView,
  ShareCreateRequest,
  ShareView
} from '../api/Models';
import { SharePanel, shareMessage } from '../library/ShareSheet';
import { PlayerParams } from '../player/PlayerParams';
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
 * 片段（对应 iOS `ReelsView`，912 行）。
 *
 * 产品形态照 iOS：**上下整页滑动**，每页是某部片里挑出的 30～60 秒。
 * 版式也照它：纯黑底、影片居中成 16:9 横带、左上是片名 + 年份（点了去详情页）、
 * 左下是简介、右边一列图标按钮、最底下一条细进度线（**按片段算，不按整部片**；
 * 平时不显示，只在暂停时淡入——同抖音）、点页面任意空白处暂停 / 继续。
 * 没出第一帧前：横带里垫横版剧照（没有剧照垫起点帧）+ 转圈，剧照模糊铺满整页垫底；
 * 放不出来时横带正中说明并让用户往下滑换一条。
 *
 * 播放用 `XComponent(SURFACE)` + `AVPlayer`，从 `segment.start_ms` 起播、
 * 到 `segment.end_ms` 停下（再点重播）——**一个时刻只存在一个播放器**，
 * 翻页时把上一个收掉，否则滑十几页会开十几个解码器。
 *
 * **还没做**（iOS 有）：画质胶囊、片尾自动翻页、等画面时的实时加载速度
 * （客户端没有测速件，先只转圈）、简介「展开 / 收起」与分集简介、已看按钮的观看进度弧。
 *
 * 手势层与播放器页同一套状态机（iOS `PlayerGestureLayer`，Reels 场景砍掉竖滑调节与横滑拖进度）：
 * 轻点立即暂停 / 继续（不为等双击延迟）；双击左右三分之一 = ∓10 秒（第一下切过的暂停先恢复）；
 * 长按 500ms = 2 倍速（抬手恢复，暂停时不起）；上下边缘 32vp 起手留给系统。
 * 竖滑整次交给外层翻页、横滑不认领：一旦滑动超过 12vp 整次触摸作废，也不当轻点。
 */
@ComponentV2
export struct ReelsPage {
  private navStack: NavPathStack = new NavPathStack();
  private chrome: ShellChrome = ShellChrome.shared;
  private started: boolean = false;
  private player: media.AVPlayer | null = null;
  private surfaceController: XComponentController = new XComponentController();
  private surfaceId: string = '';
  /** 播放器已到 initialized、XComponent surface 还没就绪：等 onLoad 回调补挂 */
  private waitSurface: boolean = false;
  private tick: number = -1;

  // —— 手势层（与播放器页 onGesture 同一状态机，阈值照搬 iOS PlayerGestureLayer）——
  /** 移动超过这个距离才算拖动（12pt） */
  private static readonly activatePx: number = 12;
  /** 上下边缘 32vp 内起手交给系统（通知中心 / 主屏幕手势） */
  private static readonly edgeGuard: number = 32;
  /** 双击窗口 300ms */
  private static readonly doubleTapWindow: number = 300;
  /** 长按 500ms 起 2 倍速 */
  private static readonly holdDelay: number = 500;

  private gestureTracking: boolean = false;
  private gestureTouchId: number = -1;
  private gestureStartX: number = 0;
  private gestureStartY: number = 0;
  /** undecided = 未定 | hold = 长按倍速（滑动直接整次作废，不进第二种意图） */
  private gestureIntent: string = 'undecided';
  private holdTimer: number = -1;
  private lastTapAt: number = 0;
  /** 手势层尺寸（边缘守卫与轻点位置比例都要用） */
  private layerWidth: number = 0;
  private layerHeight: number = 0;
  /** 长按 2 倍速生效中（HUD 显示「2× 快进中」） */
  @Local private holdActive: boolean = false;

  @Local private loading: boolean = true;
  @Local private failed: boolean = false;
  @Local private errorMessage: string = '';
  @Local private items: ReelItemView[] = [];
  /** feed 的懒加载数据源（Swiper 里 LazyForEach 用），与 this.items 保持同序 */
  private itemsSource: ReelItemsSource = new ReelItemsSource();
  @Local private index: number = 0;
  @Local private playing: boolean = false;
  /** 视频真实宽高比：surface 是画布、播放器会把画面铺满它，
   * 横带固定 16:9 时非 16:9 的片源会被拉变形——按真实比例在带内 letterbox/pillarbox */
  @Local private videoAspect: number = 16 / 9;
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
  /** 因路由压栈被自动暂停的（回来要接着放）；用户自己按停的不算 */
  private routePaused: boolean = false;
  @Local private positionMs: number = 0;
  /** timeUpdate 的 500ms 节流桶：直写 @Local 会拖整页进度线高频重渲染 */
  private timeBucket: number = -1;
  /** 播放代数：快速连滑时旧代 await 之后的结果全部作废，防止两个 AVPlayer 并发出声、解码器泄漏 */
  private playGen: number = 0;
  /** 服务端开了「片段预切」时的进度（nil = 没开预切，刷的是原片）：空态与刷到底的提示读它 */
  @Local private clips: ReelClipProgressView | null = null;
  /** 刷到底了（这一页 has_more=false）：末尾追加「没有更多了」页 */
  @Local private exhausted: boolean = false;

  aboutToDisappear(): void {
    this.chrome.pop('reels');
    this.disarmHoldTimer();
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
      // 会放预切片段：服务端开了「片段预切」就只出切好的，没开照旧出原片（同 iOS modes="seek,clip"）
      const view: ReelFeedView = await api.reelsFeed(undefined, this.index, 8, 'seek,clip',
        this.kind.length > 0 ? this.kind : undefined);
      this.items = view.items;
      this.itemsSource.setItems(view.items);
      this.clips = view.clips ?? null;
      this.exhausted = !view.has_more;
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

  /** 这一页是不是在播的这条 */
  private isCurrentItem(item: ReelItemView): boolean {
    const cur: ReelItemView | null = this.current();
    return cur !== null && cur.id === item.id;
  }

  /** 有没有横版剧照可垫（iOS：backdropUrl != nil 才铺模糊底、横带里才用铺满裁切） */
  private hasBackdrop(item: ReelItemView): boolean {
    return (item.title.backdrop_url ?? '').length > 0;
  }

  /** 模糊铺底该不该出：没出第一帧的页都铺；当前条出画了、放不出了就收掉（露出黑底，同 iOS waitingForFrame） */
  private backdropVisible(item: ReelItemView): boolean {
    if (!this.hasBackdrop(item)) {
      return false;
    }
    if (this.isCurrentItem(item)) {
      return !this.playing && !this.failed;
    }
    return true;
  }

  /** 横带下方「全屏观看」这行该不该暗：只有停下来（暂停、放完、放不出）时亮，起播、加载、播放都暗（同 iOS controlsDimmed） */
  private controlsDimmed(item: ReelItemView): boolean {
    if (!this.isCurrentItem(item)) {
      return true;
    }
    return !this.failed && !this.paused;
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
    // 代数守卫：翻页期间本函数有 3 个 await，快滑时两次调用会重叠——
    // 旧代落定后要么放弃手里的新播放器（孤儿，立刻释放），要么整体让位
    const gen: number = ++this.playGen;
    // 新一代起播：上一页的 surface 一律作废，等 XComponent onLoad 给新的；
    // 否则可能把播放器绑到已销毁的旧 surface 上（401 SurfaceUtils）
    this.surfaceId = '';
    this.waitSurface = false;
    // 翻页就换播放器：**一个时刻只留一个**，否则滑十几页会开十几个解码器
    this.disarmHoldTimer();
    this.endHoldSpeed();
    await this.releasePlayer();
    if (gen !== this.playGen) {
      return;
    }
    this.stopTick();
    this.paused = false;
    this.positionMs = 0;
    this.timeBucket = -1;

    // 预切片段（play.mode == "clip"）：服务端切好的 1080p 小文件，第 0 秒就是原片的片段起点
    const isClip: boolean = item.play.mode === 'clip';
    const url: string | null = isClip ? (item.play.clip_url ?? null) : (item.play.stream_url ?? null);
    if (url === null || url.length === 0) {
      // 这一条服务端没给出流（片段还在准备 / 直出不可用）：停在这一页并说明
      this.playing = false;
      this.failed = true;
      this.errorMessage = isClip ? '这一条缺少片段地址' : '这一段还没准备好，往下一段看看';
      return;
    }
    this.failed = false;
    try {
      const player: media.AVPlayer = await media.createAVPlayer();
      if (gen !== this.playGen) {
        // 创建期间又翻了页：这就是孤儿播放器，别接上，直接收掉
        this.discardPlayer(player);
        return;
      }
      this.player = player;
      this.bind(player, gen, item.segment.start_ms, item.segment.end_ms, isClip);
      // 设 url 后要等 stateChange 到 initialized 才能挂 surface、调 prepare：
      // 抢跑调 prepare 会报 5400102——正是线上「放不了这一段（5400102）」的根因
      player.url = AppModel.origin() + url;
    } catch (error) {
      if (gen !== this.playGen) {
        // 已被更新的翻页接管：错误面板由新页负责
        return;
      }
      const e = error as BusinessError;
      this.playing = false;
      this.failed = true;
      this.errorMessage = `放不了这一段（${e.code ?? -1}）`;
    }
  }

  /** 放弃一个没接上班的播放器：异步释放，已释放过的失败忽略 */
  private discardPlayer(player: media.AVPlayer): void {
    player.release().catch((): void => {
    });
  }

  /**
   * 事件绑定。prepare 必须等 stateChange 到 initialized 才能调（设 url 后不会立刻进该状态，
   * 抢跑报 5400102）；视频还要先挂上 XComponent 的 surface 才有渲染面。
   * clip 模式：clip 文件的时间原点就是片段起点（第 0 秒 = 原片 start_ms），
   * 直接从 0 播、到片段时长就停；seek 模式照旧按原片时间轴。
   */
  private bind(player: media.AVPlayer, gen: number, startMs: number, endMs: number, isClip: boolean): void {
    player.on('stateChange', (state: string): void => {
      if (gen !== this.playGen) {
        // 旧代播放器的事件一律不认
        return;
      }
      if (state === 'initialized') {
        if (this.surfaceId.length > 0) {
          this.attachSurfaceAndPrepare(player);
        } else {
          // surface 还没就绪：等 XComponent onLoad 回调补挂
          this.waitSurface = true;
        }
      } else if (state === 'prepared') {
        this.playing = true;
        player.play();
        this.startTick();
      }
    });
    // 视频尺寸：拿到真实的宽高比，surface 才不会把画面拉变形（同 PlayerPage）
    player.on('videoSizeChange', (width: number, height: number): void => {
      if (gen !== this.playGen) {
        return;
      }
      if (width > 0 && height > 0) {
        this.videoAspect = width / height;
      }
    });
    player.on('error', (error: BusinessError): void => {
      if (gen !== this.playGen) {
        // 旧代播放器的错误由它自己负责，别覆盖新页面板
        return;
      }
      this.playing = false;
      this.failed = true;
      this.errorMessage = `放不了这一段：${error.message}`;
    });
    player.on('timeUpdate', (time: number): void => {
      // 高频回调：按 500ms 桶节流写 @Local，进度线 2Hz 足够顺（0.5s 一跳肉眼无感）
      const bucket: number = Math.floor(time / 500);
      if (bucket !== this.timeBucket) {
        this.timeBucket = bucket;
        this.positionMs = isClip ? time : time - startMs;
      }
      // **到片段终点就停**——片段是「从整片里切出来的一段」，不是整片
      // （clip 的 time 本身就是片段内位置，与「片段时长」同轴；seek 的 time 是原片位置，与 endMs 同轴）
      const endAt: number = isClip ? endMs - startMs : endMs;
      if (endAt > 0 && time >= endAt) {
        player.pause();
        this.paused = true;
      }
    });
  }

  /** 挂渲染面并 prepare（surfaceId 就绪后调）；prepare 走事件流，失败也落到失败面板 */
  private attachSurfaceAndPrepare(player: media.AVPlayer): void {
    player.surfaceId = this.surfaceId;
    player.prepare().catch((error: BusinessError): void => {
      if (this.player !== player) {
        // 已被翻页接管：失败面板由新页负责
        return;
      }
      this.playing = false;
      this.failed = true;
      this.errorMessage = `放不了这一段（${error.code ?? -1}）`;
    });
  }

  /** surface 宽（横带宽的百分比）：宽于等于 16:9 铺满带宽，窄于按带高反推 */
  private surfaceWidthPct(): string {
    return this.videoAspect >= 16 / 9 ? '100%' : `${(this.videoAspect * 9 / 16) * 100}%`;
  }

  /** surface 高（横带高的百分比）：宽于 16:9 按带宽反推（上下留空），否则铺满带高 */
  private surfaceHeightPct(): string {
    return this.videoAspect >= 16 / 9 ? `${(16 / (9 * this.videoAspect)) * 100}%` : '100%';
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
      // 放到终点了再点 = 重播这一段（clip 从 0，seek 回片段起点）
      if (this.positionMs >= this.clipDuration() - 300) {
        const item: ReelItemView | null = this.current();
        if (item !== null) {
          const isClip: boolean = item.play.mode === 'clip';
          player.seek(isClip ? 0 : item.segment.start_ms, media.SeekMode.SEEK_CLOSEST);
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

  // MARK: 全屏播放器的位置回传（iOS PlaybackController 的 clip return）

  /**
   * 从全屏播放器回来：把退出时的位置带回内联播放器。
   * clip 模式的内联文件第 0 秒 = 片段起点，seek 模式是原片时间轴；
   * 不在当前这条（翻页了 / 不是这页推出去的）就丢掉。
   */
  private consumeClipReturn(): void {
    const ret: ClipReturn | null = AppModel.shared.clipReturn;
    if (ret === null) {
      return;
    }
    AppModel.shared.clipReturn = null;
    const item: ReelItemView | null = this.current();
    const player: media.AVPlayer | null = this.player;
    if (item === null || player === null || item.segment.file_id !== ret.fileId) {
      return;
    }
    const target: number = ret.positionMs - item.segment.start_ms;
    if (!Number.isFinite(target) || target < 0) {
      return;
    }
    // seek 目标：clip 模式按片段内位置，seek 模式按原片绝对位置
    player.seek(Math.floor(item.play.mode === 'clip' ? target : ret.positionMs),
      media.SeekMode.SEEK_CLOSEST);
    this.positionMs = Math.min(target, this.clipDuration());
  }

  // MARK: 手势层

  private vpOf(len: Length): number {
    if (typeof len === 'number') {
      return len;
    }
    if (typeof len === 'string' && len.length > 0) {
      return Number(len);
    }
    return 0;
  }

  /** 长按 2 倍速能不能起：暂停时不行（松手按轻点处理） */
  private canHoldSpeed(): boolean {
    return this.playing && !this.paused && this.player !== null;
  }

  private beginHoldSpeed(): void {
    const player: media.AVPlayer | null = this.player;
    if (player === null || !this.playing || this.paused) {
      return;
    }
    this.holdActive = true;
    player.setSpeed(media.PlaybackSpeed.SPEED_FORWARD_2_00_X);
  }

  private endHoldSpeed(): void {
    if (!this.holdActive) {
      return;
    }
    this.holdActive = false;
    const player: media.AVPlayer | null = this.player;
    if (player !== null) {
      player.setSpeed(media.PlaybackSpeed.SPEED_FORWARD_1_00_X);
    }
  }

  private disarmHoldTimer(): void {
    if (this.holdTimer >= 0) {
      clearTimeout(this.holdTimer);
      this.holdTimer = -1;
    }
  }

  /** 轻点：第一下立即暂停 / 继续（不为等双击延迟）；双击左右三分之一 = ∓10 秒，第一下切过的暂停先恢复（同 iOS ReelsStore.handleTap） */
  private handleTap(xRatio: number): void {
    const now: number = Date.now();
    const isDouble: boolean = now - this.lastTapAt <= ReelsPage.doubleTapWindow;
    this.lastTapAt = isDouble ? 0 : now;
    if (isDouble && (xRatio < 1 / 3 || xRatio > 2 / 3)) {
      this.togglePause();
      this.seekByRelative(xRatio < 1 / 3 ? -10000 : 10000);
      return;
    }
    this.togglePause();
  }

  /** 在这一段里相对跳（clip 的时间原点就是片段起点，seek 的是原片时间轴） */
  private seekByRelative(deltaMs: number): void {
    const player: media.AVPlayer | null = this.player;
    const item: ReelItemView | null = this.current();
    if (player === null || item === null) {
      return;
    }
    const duration: number = this.clipDuration();
    const target: number = Math.max(0, Math.min(duration, this.positionMs + deltaMs));
    const isClip: boolean = item.play.mode === 'clip';
    player.seek(isClip ? target : item.segment.start_ms + target, media.SeekMode.SEEK_CLOSEST);
    this.positionMs = target;
  }

  /**
   * 手势状态机（播放器页 onGesture 的 Reels 砍版：竖滑整次交给外层翻页、横滑不拖进度）。
   * 竖滑 / 横滑一旦超过 12vp：整次触摸作废（不当轻点也不认领），翻页由外层 Swiper 接管。
   */
  private onGesture(event: TouchEvent, item: ReelItemView): void {
    const current: ReelItemView | null = this.current();
    if (current === null || item.id !== current.id) {
      return;
    }
    const touch: TouchObject | undefined = event.changedTouches[0];
    if (touch === undefined) {
      return;
    }
    if (event.type === TouchType.Down) {
      // 已有一根手指在跟踪：第二根不认领（同 iOS isMultipleTouchEnabled = false）
      if (this.gestureTracking) {
        return;
      }
      if (touch.y <= ReelsPage.edgeGuard
        || (this.layerHeight > 0 && touch.y >= this.layerHeight - ReelsPage.edgeGuard)) {
        return;
      }
      this.gestureTracking = true;
      this.gestureTouchId = touch.id;
      this.gestureStartX = touch.x;
      this.gestureStartY = touch.y;
      this.gestureIntent = 'undecided';
      this.disarmHoldTimer();
      if (this.canHoldSpeed()) {
        this.holdTimer = setTimeout((): void => {
          if (this.gestureTracking && this.gestureIntent === 'undecided') {
            this.gestureIntent = 'hold';
            this.beginHoldSpeed();
          }
        }, ReelsPage.holdDelay);
      }
      return;
    }
    if (event.type === TouchType.Move) {
      if (!this.gestureTracking || touch.id !== this.gestureTouchId) {
        return;
      }
      if (this.gestureIntent !== 'undecided') {
        return;
      }
      const dx: number = touch.x - this.gestureStartX;
      const dy: number = touch.y - this.gestureStartY;
      if (Math.max(Math.abs(dx), Math.abs(dy)) <= ReelsPage.activatePx) {
        return;
      }
      this.disarmHoldTimer();
      this.gestureTracking = false;
      return;
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.disarmHoldTimer();
      if (!this.gestureTracking) {
        return;
      }
      this.gestureTracking = false;
      if (this.gestureIntent === 'hold') {
        this.endHoldSpeed();
      } else if (event.type === TouchType.Up) {
        this.handleTap(touch.x / Math.max(1, this.layerWidth));
      }
      this.gestureIntent = 'undecided';
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
    // file_id 在 `segment` 上（`play` 里没有），季集号同样没有就不传；
    // 带上片段起止（iOS PlaybackClip）：全屏只放这一段，退出时把位置带回来
    this.navStack.pushPathByName('player',
      new PlayerParams(item.title.media_item_id, item.segment.file_id, 0, 0,
        item.segment.start_ms, '', item.segment.start_ms, item.segment.end_ms));
  }

  // MARK: 视图

  build() {
    NavDestination() {
      Column() {
        if (this.failed && this.items.length === 0) {
          this.ErrorState()
        } else if (this.loading && this.items.length === 0) {
          this.LoadingState()
        } else if (this.items.length === 0) {
          this.EmptyState()
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
    .onHidden(() => {
      // 被上面的页盖住（全屏播放器 / 详情页）：内联播放器静下来，别两层一起出声
      const player: media.AVPlayer | null = this.player;
      if (player !== null && !this.paused) {
        player.pause();
        this.paused = true;
        this.routePaused = true;
      }
    })
    .onShown(() => {
      // 回到这页：先接住全屏播放器带回的位置，再接着放
      this.consumeClipReturn();
      if (this.routePaused) {
        this.routePaused = false;
        const player: media.AVPlayer | null = this.player;
        if (player !== null) {
          player.play();
          this.paused = false;
        }
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

  /** 空态：开了片段预切、一部都还没切好时说清楚在预切（同 iOS），否则就是这些条件下没有能刷的 */
  @Builder
  EmptyState() {
    Column({ space: 10 }) {
      if (this.clips !== null && this.clips.state !== 'done' && this.clips.ready < this.clips.total) {
        Text(`片段正在预切，已完成 ${this.clips.ready} / ${this.clips.total}`)
          .fontSize(15)
          .fontColor(Theme.text)
        Text(this.clips.state === 'paused' ? '有人在观看，预切暂停中，稍后再来' : '稍后再来就能刷了')
          .fontSize(13)
          .fontColor(Theme.textFaint)
      } else {
        Text('这些条件下还没有能刷的片子').fontSize(15).fontColor(Theme.text)
        Text('重试').fontSize(14).fontColor(Theme.accentStrong).onClick(() => {
          this.load();
        })
      }
    }
    .width('100%')
    .layoutWeight(1)
    .padding(24)
    .justifyContent(FlexAlign.Center)
  }

  /** 刷到底的末页：没有更多了；开了片段预切、还没切完时补一句其余的还在切（同 iOS endPage） */
  @Builder
  EndPage() {
    Column({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.checkmark_circle'))
        .fontSize(36)
        .fontColor(['rgba(255,255,255,0.7)'])
      Text('没有更多了')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor('#ffffff')
      if (this.clips !== null && this.clips.state !== 'done' && this.clips.ready < this.clips.total) {
        Text(`其余 ${this.clips.total - this.clips.ready} 部的片段还在预切，晚点再来`)
          .fontSize(13)
          .fontColor(Theme.textMuted)
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#000000')
  }

  /** 整页上下滑（iOS 用的就是整页翻，不是列表） */
  @Builder
  Feed() {
    Swiper() {
      LazyForEach(this.itemsSource, (item: ReelItemView) => {
        Stack() {
          // 没出第一帧前：横版剧照模糊铺满整页垫底（同 iOS stillBackdrop）
          if (this.backdropVisible(item)) {
            this.Backdrop(item)
          }
          // 画面：一条 16:9 的横带居中
          Column() {
            if (this.isCurrentItem(item)) {
              Stack() {
                XComponent({
                  id: 'reel-surface',
                  type: XComponentType.SURFACE,
                  controller: this.surfaceController
                })
                  // 按视频真实比例在 16:9 横带内自适应（宽于 16:9 上下留空、窄于则左右留空）
                  .width(this.surfaceWidthPct())
                  .height(this.surfaceHeightPct())
                  .onLoad((): void => {
                    this.surfaceId = this.surfaceController.getXComponentSurfaceId();
                    // 播放器先到 initialized、surface 后就绪：补挂起播
                    const player: media.AVPlayer | null = this.player;
                    if (this.waitSurface && player !== null && player.state === 'initialized') {
                      this.waitSurface = false;
                      this.attachSurfaceAndPrepare(player);
                    }
                  })
                /*
                 * **没出第一帧前用横版剧照顶着**（iOS：`没出第一帧前横带里放横版剧照`）。
                 * 不这么做的话，转码还没出片时横带就是一块纯黑——用户以为坏了。
                 * 放不出来时收掉（同 iOS），露出黑底上的失败说明。
                 */
                if (!this.playing && !this.failed) {
                  this.Cover(item, !this.hasBackdrop(item))
                  // 当前条等画面时压暗一档，转圈读得清（同 iOS still 上盖 black 0.3）
                  Column()
                    .width('100%')
                    .height('100%')
                    .backgroundColor('rgba(0,0,0,0.3)')
                }
                // 横带正中的状态层（同 iOS overlay）：放不出来说明 / 等画面转圈 / 暂停、放完的标记
                if (this.failed) {
                  this.BandFailure()
                } else if (!this.playing) {
                  LoadingProgress()
                    .width(26)
                    .height(26)
                    .color('#ffffff')
                    .shadow({ radius: 6, color: 'rgba(0,0,0,0.5)' })
                } else if (this.paused) {
                  this.PauseMarker()
                }
              }
              .width('100%')
              .aspectRatio(16 / 9)
              // 长按 2 倍速读数：横带上方玻璃胶囊（同 iOS gestureHUD 的 PlayerHUD）
              .overlay(this.HoldHud(), { align: Alignment.Top })
            } else {
              // 非当前页不挂 surface（省解码器），用封面顶着
              this.Cover(item, !this.hasBackdrop(item))
            }
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)

          // 手势层（同播放器页，轻点 / 双击 ∓10 秒 / 长按 2 倍速；竖滑交给翻页、横滑作废）
          Column()
            .width('100%')
            .height('100%')
            .onTouch((event: TouchEvent): void => {
              this.onGesture(event, item);
            })
            .onAreaChange((_old: Area, newArea: Area) => {
              this.layerWidth = this.vpOf(newArea.width);
              this.layerHeight = this.vpOf(newArea.height);
            })

          this.Overlay(item)
        }
        .width('100%')
        .height('100%')
      }, (item: ReelItemView) => item.id)
      // 刷到底的末页（同 iOS endPage）：滑到它就像滑走了一条，收掉当前的播放器
      if (this.exhausted) {
        this.EndPage()
      }
    }
    .vertical(true)
    .loop(false)
    .indicator(false)
    .index(this.index)
    .onChange((index: number): void => {
      this.index = index;
      // 末页：收掉播放器（不再补量、不再起播）
      if (index >= this.items.length) {
        this.disarmHoldTimer();
        this.endHoldSpeed();
        this.stopTick();
        this.releasePlayer();
        this.playing = false;
        return;
      }
      this.syncMarks();
      // 翻页就换片段；滑到接近末尾时补一批
      this.playCurrent();
      if (index >= this.items.length - 2 && !this.exhausted) {
        this.loadMore();
      }
    })
    .width('100%')
    .layoutWeight(1)
  }

  /** 长按 2 倍速读数（玻璃胶囊，同播放器页 TopHud 的「2× 快进中」）；不挡手势 */
  @Builder
  HoldHud() {
    if (this.holdActive) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.fast_forward'))
          .fontSize(15)
          .fontColor(['#ffffff'])
        Text('2× 快进中')
          .fontSize(14)
          .fontColor('#ffffff')
      }
      .height(36)
      .padding({ left: 16, right: 16 })
      .backgroundColor('rgba(20,20,22,0.72)')
      .borderRadius(18)
      .margin({ top: 10 })
      .hitTestBehavior(HitTestMode.None)
    }
  }

  /**
   * 横带里的剧照。
   *
   * **必须走 `ImageUrls` 解析 + `RemoteImage`**：后端给的是相对路径
   * （`/images/assets/103/reels/3641/…jpg?v=…`），直接 `Image(url)` 既没有服务器地址、
   * 也没有登录头，只会得到一块黑（实测就是黑的）。装图用 `RemoteImage`——
   * 它带账号令牌，也正是 `ImageVariant.reelStill`（「刷片等画面时垫在横带里的剧照」）的用途。
   */
  @Builder
  Cover(item: ReelItemView, fit: boolean) {
    Column() {
      RemoteImage({
        url: this.stillUrl(item),
        fit: fit,
        placeholderSymbol: $r('sys.symbol.film')
      })
        .width('100%')
        .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#111111')
  }

  /** 剧照地址（优先横版剧照、起点帧兜底——同 iOS stillURL；相对路径 → 可请求的 URL） */
  private stillUrl(item: ReelItemView): string {
    const raw: string | null = item.title.backdrop_url ?? item.cover_url ?? null;
    const resolved: string | null =
      ImageUrls.resolve(AppModel.origin(), raw, ImageVariant.reelStill);
    return resolved !== null ? resolved : '';
  }

  /**
   * 模糊铺底：剧照放大一成多再 blur 40，边缘淡出的部分被页面裁掉（不会透出一圈透明，同 iOS 的 opaque 模糊），
   * 上压黑 50%；垫在最底层、不挡任何触摸。
   */
  @Builder
  Backdrop(item: ReelItemView) {
    Stack({ alignContent: Alignment.Center }) {
      RemoteImage({
        url: this.stillUrl(item),
        placeholderSymbol: $r('sys.symbol.film')
      })
        .width('118%')
        .height('118%')
        .blur(40)
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.5)')
        .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .height('100%')
    .clip(true)
    .hitTestBehavior(HitTestMode.None)
  }

  /** 放不出来：横带正中说清楚、往下滑换一条（同 iOS failed overlay） */
  @Builder
  BandFailure() {
    Column({ space: 6 }) {
      SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
        .fontSize(26)
        .fontColor(['rgba(255,255,255,0.85)'])
      Text('这一段放不出来，往下滑换一条')
        .fontSize(13)
        .fontColor('rgba(255,255,255,0.85)')
      Text(this.errorMessage)
        .fontSize(11)
        .fontColor('rgba(255,255,255,0.55)')
        .maxLines(2)
        .textAlign(TextAlign.Center)
    }
    .padding({ left: 24, right: 24 })
  }

  /** 暂停时横带正中出播放标记；放到头了换重播标记（同 iOS ReelCenterGlyph：play.fill / arrow.counterclockwise） */
  @Builder
  PauseMarker() {
    if (this.positionMs >= this.clipDuration() - 300) {
      SymbolGlyph($r('sys.symbol.arrow_counterclockwise'))
        .fontSize(36)
        .fontColor(['rgba(255,255,255,0.92)'])
        .shadow({ radius: 8, color: 'rgba(0,0,0,0.5)' })
    } else {
      SymbolGlyph($r('sys.symbol.play_fill'))
        .fontSize(40)
        .fontColor(['rgba(255,255,255,0.9)'])
        .shadow({ radius: 10, color: 'rgba(0,0,0,0.7)', offsetX: 0, offsetY: 2 })
    }
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
      .opacity(this.controlsDimmed(item) ? 0.3 : 1)
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

      // 最底下一条细进度线（按片段算，不按整部片）；平时不显示，只在暂停时淡入（同抖音）
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
      .opacity(this.isCurrentItem(item) && this.paused ? 1 : 0)
      .animation({ duration: 200, curve: Curve.EaseOut })
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
      const view: ReelFeedView = await api.reelsFeed(undefined, this.items.length, 8, 'seek,clip');
      this.clips = view.clips ?? null;
      this.exhausted = !view.has_more;
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
