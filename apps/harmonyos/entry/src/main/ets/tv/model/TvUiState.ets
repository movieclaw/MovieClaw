/**
 * TV 端状态模型（@ObservedV2 一代到底，不与 V1 混用）：
 * - TvRoute 及其子类：自管路由栈的页面目标（详情/海报墙/影人/合集/行墙）
 * - TvPlayRequest：起播请求（TvShell 播放器覆盖层的开关量）
 * - TvWallPrefs：每面墙的排序/筛选记忆（Preferences 持久化，tv_wall_ 前缀）
 * - TvHomeFocus：首页焦点防抖（0.16s）+ 大图预告计时（焦点停稳 2s）
 * - TvDiscoveryState：欢迎流程的局域网发现态
 * - TvPlayerUiState：播放器 UI 状态机（供外壳判断覆盖层去留）
 * - TvUiState：外壳单例——路由栈 / 页签 / 侧边栏 / 播放器槽位 / 返回分级
 */
import { preferences } from '@kit.ArkData';
import { Context } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TvMotion } from '../theme/TvTheme';
import { AvPlayerEngine, PlayRequest } from '../../common/AvPlayerEngine';

/** 路由基类：子类用 instanceof 分派（ArkTS 无带关联值的枚举） */
export class TvRoute {
  readonly routeName: string;

  constructor(routeName: string) {
    this.routeName = routeName;
  }
}

/** 条目详情页 */
export class TvDetailRoute extends TvRoute {
  readonly libraryId: number;
  readonly itemId: number;

  constructor(libraryId: number, itemId: number) {
    super('detail');
    this.libraryId = libraryId;
    this.itemId = itemId;
  }
}

/** 单库海报墙（含 kind 跨库墙：libraryId 传 0、kindSource 传类型） */
export class TvWallRoute extends TvRoute {
  /** 库 id；kind 墙时为 0 */
  readonly libraryId: number;
  /** 墙标题 */
  readonly title: string;
  /** kind 墙（「全部电影/全部剧集」）的媒体类型；单库墙为 null */
  readonly kindSource: string | null;

  constructor(libraryId: number, title: string, kindSource: string | null) {
    super('wall');
    this.libraryId = libraryId;
    this.title = title;
    this.kindSource = kindSource;
  }
}

/** 「查看全部」行墙：把首页一行的数据源铺成整面墙 */
export class TvRowWallRoute extends TvRoute {
  /**
   * 数据源形状（与首页那一行同一套取数参数，行墙按它取数）：
   * - lib:<id>:<sort>:<reversed>:<unwatched>（库行，同 LibraryHomeStore.fetchKey）
   * - col:<id>:<sort>:<reversed>（合集行，同 fetchKey）
   * - favorites:<sort>:<reversed>（收藏行）
   * - genre:<kind>:<value>（类型格子：按 TMDB 类型筛好的跨库墙，最近添加在前）
   */
  readonly sourceKey: string;
  readonly title: string;

  constructor(sourceKey: string, title: string) {
    super('rowWall');
    this.sourceKey = sourceKey;
    this.title = title;
  }
}

/** 影人页 */
export class TvPersonRoute extends TvRoute {
  readonly tmdbPersonId: number;
  readonly personName: string;

  constructor(tmdbPersonId: number, personName: string) {
    super('person');
    this.tmdbPersonId = tmdbPersonId;
    this.personName = personName;
  }
}

/** 合集详情（复用行墙铺成员） */
export class TvCollectionRoute extends TvRoute {
  readonly collectionId: number;
  readonly title: string;

  constructor(collectionId: number, title: string) {
    super('collection');
    this.collectionId = collectionId;
    this.title = title;
  }
}

/** 起播请求：谁、哪一集、从哪起 */
export class TvPlayRequest extends PlayRequest {
  constructor(libraryId: number, itemId: number, seasonNumber: number | null,
    episodeNumber: number | null, fileId: number | null, startMs: number | null,
    title: string, subtitle: string | null, autoAdvance: boolean) {
    super(libraryId, itemId, seasonNumber, episodeNumber, fileId, startMs,
      title, subtitle, '', autoAdvance);
  }
}

/** 每面墙的排序/筛选记忆（单库存于 tv_wall_<libraryId> 一个 JSON 串） */
export class TvWallPrefs {
  sort: string = 'added_at';
  order: string = 'desc';
  unwatched: boolean = false;
  /** 筛选：类型/年代/分辨率/观看状态（对应 libraryItemsList 的 g/d/res/w 参数） */
  genre: string | null = null;
  decade: string | null = null;
  resolution: string | null = null;
  watch: string | null = null;

  static fromJson(raw: string): TvWallPrefs | null {
    if (raw.length === 0) {
      return null;
    }
    try {
      const parsed: TvWallPrefs = JSON.parse(raw) as TvWallPrefs;
      const prefs: TvWallPrefs = new TvWallPrefs();
      if (typeof parsed.sort === 'string') {
        prefs.sort = parsed.sort;
      }
      if (typeof parsed.order === 'string') {
        prefs.order = parsed.order;
      }
      if (typeof parsed.unwatched === 'boolean') {
        prefs.unwatched = parsed.unwatched;
      }
      prefs.genre = typeof parsed.genre === 'string' ? parsed.genre : null;
      prefs.decade = typeof parsed.decade === 'string' ? parsed.decade : null;
      prefs.resolution = typeof parsed.resolution === 'string' ? parsed.resolution : null;
      prefs.watch = typeof parsed.watch === 'string' ? parsed.watch : null;
      return prefs;
    } catch (error) {
      return null;
    }
  }

  toJson(): string {
    return JSON.stringify(this);
  }
}

/**
 * 首页焦点状态机：
 * - settledKey：焦点停稳（0.16s 防抖）后生效的卡片键——大图区切它
 * - previewKey：停稳 2 秒后的预告键——原地播片段
 * 计时器由本类持有，页面失焦/离场调 reset() 拆除。
 */
@ObservedV2
export class TvHomeFocus {
  @Trace settledKey: string | null = null;
  @Trace previewKey: string | null = null;
  private debounceId: number = -1;
  private previewId: number = -1;
  private readonly onPreviewStart: ((key: string) => void) | null;

  constructor(onPreviewStart: ((key: string) => void) | null) {
    this.onPreviewStart = onPreviewStart;
  }

  /** 焦点移到某卡：重置防抖计时，并立刻拆掉在播预告 */
  focusCard(key: string | null): void {
    this.clearPreview();
    if (this.debounceId >= 0) {
      clearTimeout(this.debounceId);
      this.debounceId = -1;
    }
    if (key === null) {
      this.settledKey = null;
      return;
    }
    this.debounceId = setTimeout(() => {
      this.debounceId = -1;
      this.settledKey = key;
      this.schedulePreview(key);
    }, TvMotion.stageDebounceMs);
  }

  private schedulePreview(key: string): void {
    this.previewId = setTimeout(() => {
      this.previewId = -1;
      this.previewKey = key;
      const cb = this.onPreviewStart;
      if (cb !== null) {
        cb(key);
      }
    }, TvMotion.previewDelayMs);
  }

  /** 拆掉在播预告（滚走/进详情/起播前） */
  clearPreview(): void {
    if (this.previewId >= 0) {
      clearTimeout(this.previewId);
      this.previewId = -1;
    }
    this.previewKey = null;
  }

  /** 离开首页整页时全量复位 */
  reset(): void {
    if (this.debounceId >= 0) {
      clearTimeout(this.debounceId);
      this.debounceId = -1;
    }
    this.clearPreview();
    this.settledKey = null;
  }
}

/** 欢迎流程的发现态 */
@ObservedV2
export class TvDiscoveryState {
  @Trace scanning: boolean = false;
  @Trace servers: TvDiscoveredServer[] = [];
  @Trace message: string | null = null;
}

/** 发现到的一台候选服务器 */
export class TvDiscoveredServer {
  readonly origin: string;
  readonly name: string;

  constructor(origin: string, name: string) {
    this.origin = origin;
    this.name = name;
  }
}

/** 播放器 UI 状态机（外壳只关心 phase 与 overlayVisible） */
@ObservedV2
export class TvPlayerUiState {
  /** idle=未挂载 preparing=建会话中 playing=播中 paused=暂停 error=错误 */
  @Trace phase: string = 'idle';
  @Trace errorMessage: string | null = null;
}

/** 页签 */
export class TvTab {
  static readonly home: string = 'home';
  static readonly search: string = 'search';
  static readonly accounts: string = 'accounts';
}

/**
 * TV 外壳单例：路由栈、页签、侧边栏、播放器覆盖层槽位、返回分级、墙偏好存取。
 */
@ObservedV2
export class TvUiState {
  private static instance: TvUiState | null = null;

  /**
   * 惰性单例（同 AppModel）：`static readonly shared = new TvUiState()` 会在类定义阶段
   * 构造实例，早于 @ObservedV2 装上观察钩子——那样 @Trace 字段变化不会通知任何组件
   * （实测：点了胶囊 railExpanded 已是 true，界面毫无反应）。
   */
  static get shared(): TvUiState {
    if (TvUiState.instance === null) {
      TvUiState.instance = new TvUiState();
    }
    return TvUiState.instance;
  }

  /** 二级页路由栈（后进先出，整屏覆盖） */
  @Trace routes: TvRoute[] = [];
  /** 当前页签 */
  @Trace tab: string = TvTab.home;
  /** 侧边栏展开态 */
  @Trace railExpanded: boolean = false;
  /** 播放器覆盖层开关量；非 null 即挂载 TvPlayerPage */
  @Trace playerRequest: TvPlayRequest | null = null;
  /** 播放器 UI 状态（页面更新，外壳读取） */
  readonly playerUi: TvPlayerUiState = new TvPlayerUiState();

  /** 播放器页注册的返回处理器（面板→卡片→退出的分级在页内实现）；返回 true = 已消费 */
  playerBackHandler: (() => boolean) | null = null;

  /** 页签页注册的返回处理器（如账号页「关于」浮层开着先收浮层）；返回 true = 已消费 */
  pageBackHandler: (() => boolean) | null = null;

  /** 各二级页注册的页面级返回处理器（如墙的面板开着先收面板再退页）；返回 true = 已消费 */
  private readonly routeBackHandlers: Map<TvRoute, () => boolean> = new Map<TvRoute, () => boolean>();

  private store: preferences.Preferences | null = null;

  private constructor() {
  }

  /** 偏好存储初始化（TvIndex aboutToAppear 调一次） */
  init(context: Context): void {
    AvPlayerEngine.appContext = context;
    if (this.store !== null) {
      return;
    }
    preferences.getPreferences(context, 'movieclaw_tv')
      .then((store: preferences.Preferences): void => {
        this.store = store;
      })
      .catch((): void => {
      });
  }

  /** 压入二级页（同名同参去重：反复点同一张卡不叠层）；二级页整屏覆盖，顺手收起侧边栏 */
  pushRoute(route: TvRoute): void {
    const last: TvRoute | undefined = this.routes[this.routes.length - 1];
    if (last !== undefined && last.routeName === route.routeName && TvUiState.sameRoute(last, route)) {
      return;
    }
    this.routes.push(route);
    this.railExpanded = false;
  }

  private static sameRoute(a: TvRoute, b: TvRoute): boolean {
    if (a instanceof TvDetailRoute && b instanceof TvDetailRoute) {
      return a.libraryId === b.libraryId && a.itemId === b.itemId;
    }
    if (a instanceof TvWallRoute && b instanceof TvWallRoute) {
      return a.libraryId === b.libraryId && a.kindSource === b.kindSource;
    }
    if (a instanceof TvRowWallRoute && b instanceof TvRowWallRoute) {
      return a.sourceKey === b.sourceKey;
    }
    if (a instanceof TvPersonRoute && b instanceof TvPersonRoute) {
      return a.tmdbPersonId === b.tmdbPersonId;
    }
    if (a instanceof TvCollectionRoute && b instanceof TvCollectionRoute) {
      return a.collectionId === b.collectionId;
    }
    return false;
  }

  /** 二级页注册页面级返回处理（aboutToAppear 注册 / aboutToDisappear 注销） */
  registerRouteBack(route: TvRoute, handler: () => boolean): void {
    this.routeBackHandlers.set(route, handler);
  }

  /** 注销页面级返回处理（页面离场） */
  unregisterRouteBack(route: TvRoute): void {
    this.routeBackHandlers.delete(route);
  }

  /** 弹出一层；返回是否还有剩余层 */
  popRoute(): boolean {
    if (this.routes.length === 0) {
      return false;
    }
    const popped: TvRoute | undefined = this.routes.pop();
    if (popped !== undefined) {
      this.routeBackHandlers.delete(popped);
    }
    return this.routes.length > 0;
  }

  /** 打开播放器覆盖层 */
  openPlayer(request: TvPlayRequest): void {
    hilog.info(0x0000, 'DbgFlow', 'OPEN_PLAYER item=%{public}d title=%{public}s', request.itemId, request.title);
    this.playerRequest = request;
  }

  /** 关闭播放器覆盖层 */
  closePlayer(): void {
    hilog.info(0x0000, 'DbgFlow', 'CLOSE_PLAYER');
    this.playerRequest = null;
    this.playerUi.phase = 'idle';
    this.playerUi.errorMessage = null;
    this.playerBackHandler = null;
  }

  /**
   * 返回键分级（TvIndex.onBackPress 委托到这里）：
   * 播放器内分级（取消拖动→收面板→收卡片）→ 弹路由 → 首页收起态展开侧边栏。
   * 返回 false = 分级已到底（侧边栏已展开），交还 TvIndex 出「退出确认」。
   */
  handleBack(): boolean {
    if (this.playerRequest !== null) {
      const handler = this.playerBackHandler;
      if (handler !== null && handler()) {
        return true;
      }
      this.closePlayer();
      return true;
    }
    // 页签页先给它注册的返回处理一次机会（浮层开着先收浮层），没消费才往下分级
    if (this.pageBackHandler !== null && this.pageBackHandler()) {
      return true;
    }
    if (this.routes.length > 0) {
      // 顶层页先给它自己注册的返回处理一次机会（面板开着先收面板），没消费才退页
      const top: TvRoute = this.routes[this.routes.length - 1];
      const handler: (() => boolean) | undefined = this.routeBackHandlers.get(top);
      if (handler !== undefined && handler()) {
        return true;
      }
      this.popRoute();
      return true;
    }
    if (!this.railExpanded) {
      this.railExpanded = true;
      return true;
    }
    return false;
  }

  /** 换页签（页签切换本身不收侧边栏，焦点自然回落） */
  selectTab(tab: string): void {
    this.tab = tab;
    this.railExpanded = false;
  }

  /**
   * 登录完成/重新进入主界面：落到首页，清掉上一次会话遗留的二级页、播放器与侧边栏。
   * （TvUiState 是进程单例，不重置的话「退出登录 → 再登录」会回到上次停留的页签。）
   */
  resetShell(): void {
    this.tab = TvTab.home;
    this.routes = [];
    this.railExpanded = false;
    this.playerRequest = null;
    this.playerUi.phase = 'idle';
    this.playerUi.errorMessage = null;
    this.playerBackHandler = null;
    this.pageBackHandler = null;
  }

  /** 读取某面墙的记忆偏好；没有则给默认 */
  async wallPrefs(wallKey: string): Promise<TvWallPrefs> {
    const store: preferences.Preferences | null = this.store;
    if (store === null) {
      return new TvWallPrefs();
    }
    const raw: string = await store.get(`tv_wall_${wallKey}`, '') as string;
    const parsed: TvWallPrefs | null = TvWallPrefs.fromJson(raw);
    return parsed === null ? new TvWallPrefs() : parsed;
  }

  /** 保存墙偏好（尽力而为，失败静默） */
  saveWallPrefs(wallKey: string, prefs: TvWallPrefs): void {
    const store: preferences.Preferences | null = this.store;
    if (store === null) {
      return;
    }
    store.put(`tv_wall_${wallKey}`, prefs.toJson()).then((): void => {
      store.flush();
    }).catch((): void => {
    });
  }

  /** 读一个 TV 侧字符串偏好（如配对用的安装标识）；没有给 fallback */
  async cachedString(key: string, fallback: string): Promise<string> {
    const store: preferences.Preferences | null = this.store;
    if (store === null) {
      return fallback;
    }
    return await store.get(key, fallback) as string;
  }

  /** 写一个 TV 侧字符串偏好（尽力而为） */
  saveString(key: string, value: string): void {
    const store: preferences.Preferences | null = this.store;
    if (store === null) {
      return;
    }
    store.put(key, value).then((): void => {
      store.flush();
    }).catch((): void => {
    });
  }
}
