/**
 * 车机 / TV 外壳的共享状态层（@ObservedV2 一代到底，不与 V1 混用）：
 * - ShellRoute 及其子类：自管路由栈的页面目标（详情/海报墙/行墙/影人/合集），
 *   两端经各自 model 文件按 Car 前缀 / Tv 前缀别名再导出，页签页无感复用
 * - PlayRequest：起播请求（Car/Tv 播放宿主共用同一份数据形状）
 * - ShellWallPrefs：每面墙的排序/筛选记忆（Preferences 持久化，前缀由子类给）
 * - ShellPlayerUiState：播放器 UI 状态机（外壳判断覆盖层去留）
 * - ShellDiscoveryState / ShellDiscoveredServer：欢迎流程的局域网发现态
 * - ShellUiState：外壳基类——路由栈 / 页签 / 播放器槽位 / 返回分级 / 墙偏好存取；
 *   CarUiState / TvUiState 继承后只补各自差异（车机驾驶锁与 mini 条 / TV 侧边栏）。
 */
import { preferences } from '@kit.ArkData';
import { Context } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** 路由基类：子类用 instanceof 分派（ArkTS 无带关联值的枚举） */
export class ShellRoute {
  readonly routeName: string;

  constructor(routeName: string) {
    this.routeName = routeName;
  }
}

/** 条目详情页 */
export class ShellDetailRoute extends ShellRoute {
  readonly libraryId: number;
  readonly itemId: number;

  constructor(libraryId: number, itemId: number) {
    super('detail');
    this.libraryId = libraryId;
    this.itemId = itemId;
  }
}

/** 单库海报墙（含 kind 跨库墙：libraryId 传 0、kindSource 传类型） */
export class ShellWallRoute extends ShellRoute {
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

/**
 * 「查看全部」行墙：把首页一行的数据源铺成整面墙。
 * 数据源形状（与取数处同一套约定）：
 * - lib:<id>:<sort>:<reversed>:<unwatched>（库行，同 LibraryHomeStore.fetchKey）
 * - col:<id>:<sort>:<reversed>（合集行，同 fetchKey）
 * - favorites:<sort>:<reversed>（收藏行）
 * - genre:<kind>:<value>（类型格子）
 * - person:<tmdbPersonId>（影人作品行墙；车机端使用）
 */
export class ShellRowWallRoute extends ShellRoute {
  readonly sourceKey: string;
  readonly title: string;

  constructor(sourceKey: string, title: string) {
    super('rowWall');
    this.sourceKey = sourceKey;
    this.title = title;
  }
}

/** 影人页（作品行墙） */
export class ShellPersonRoute extends ShellRoute {
  readonly tmdbPersonId: number;
  readonly personName: string;

  constructor(tmdbPersonId: number, personName: string) {
    super('person');
    this.tmdbPersonId = tmdbPersonId;
    this.personName = personName;
  }
}

/** 合集详情（复用行墙铺成员） */
export class ShellCollectionRoute extends ShellRoute {
  readonly collectionId: number;
  readonly title: string;

  constructor(collectionId: number, title: string) {
    super('collection');
    this.collectionId = collectionId;
    this.title = title;
  }
}

/** 起播请求：谁、哪一集、从哪起（Car/Tv 播放宿主共用） */
export class PlayRequest {
  readonly libraryId: number;
  readonly itemId: number;
  readonly seasonNumber: number | null;
  readonly episodeNumber: number | null;
  readonly fileId: number | null;
  readonly startMs: number | null;
  readonly title: string;
  readonly subtitle: string | null;
  readonly coverUrl: string;
  readonly autoAdvance: boolean;

  constructor(libraryId: number, itemId: number, seasonNumber: number | null,
    episodeNumber: number | null, fileId: number | null, startMs: number | null,
    title: string, subtitle: string | null, coverUrl: string, autoAdvance: boolean) {
    this.libraryId = libraryId;
    this.itemId = itemId;
    this.seasonNumber = seasonNumber;
    this.episodeNumber = episodeNumber;
    this.fileId = fileId;
    this.startMs = startMs;
    this.title = title;
    this.subtitle = subtitle;
    this.coverUrl = coverUrl;
    this.autoAdvance = autoAdvance;
  }
}

/** 每面墙的排序/筛选记忆（单库存于 <prefix><libraryId> 一个 JSON 串） */
export class ShellWallPrefs {
  sort: string = 'added_at';
  order: string = 'desc';
  unwatched: boolean = false;
  /** 筛选：类型/年代/分辨率/观看状态（对应 libraryItemsList 的 g/d/res/w 参数） */
  genre: string | null = null;
  decade: string | null = null;
  resolution: string | null = null;
  watch: string | null = null;

  static fromJson(raw: string): ShellWallPrefs | null {
    if (raw.length === 0) {
      return null;
    }
    try {
      const parsed: ShellWallPrefs = JSON.parse(raw) as ShellWallPrefs;
      const prefs: ShellWallPrefs = new ShellWallPrefs();
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

/** 播放器 UI 状态机（外壳只关心 phase 与 overlayVisible） */
@ObservedV2
export class ShellPlayerUiState {
  /** idle=未挂载 preparing=建会话中 playing=播中 paused=暂停 error=错误 */
  @Trace phase: string = 'idle';
  @Trace errorMessage: string | null = null;
}

/** 欢迎流程的发现态 */
@ObservedV2
export class ShellDiscoveryState {
  @Trace scanning: boolean = false;
  @Trace servers: ShellDiscoveredServer[] = [];
  @Trace message: string | null = null;
}

/** 发现到的一台候选服务器 */
export class ShellDiscoveredServer {
  readonly origin: string;
  readonly name: string;

  constructor(origin: string, name: string) {
    this.origin = origin;
    this.name = name;
  }
}

/**
 * 车机 / TV 外壳共享基类：路由栈、页签、播放器覆盖层槽位、返回分级、墙偏好存取。
 * 子类（CarUiState / TvUiState）用 protected 构造器定墙偏好前缀与日志标签，
 * 重写 onRoutePushed / handleBack / selectTab / resetShell 补各自交互差异。
 */
@ObservedV2
export class ShellUiState {
  /** 墙偏好持久化键前缀（car_wall_ / tv_wall_） */
  protected readonly wallPrefix: string;
  /** 起播/关播日志标签 */
  protected readonly flowTag: string;

  /** 二级页路由栈（后进先出，整屏覆盖） */
  @Trace routes: ShellRoute[] = [];
  /** 当前页签 */
  @Trace tab: string = 'home';
  /** 播放器覆盖层开关量；非 null 即挂载播放器页 */
  @Trace playerRequest: PlayRequest | null = null;
  /** 播放器 UI 状态（页面更新，外壳读取） */
  readonly playerUi: ShellPlayerUiState = new ShellPlayerUiState();

  /** 播放器页注册的返回处理器（面板→退出确认的分级在页内实现）；返回 true = 已消费 */
  playerBackHandler: (() => boolean) | null = null;

  /** 页签页注册的返回处理器（如账号页「关于」浮层开着先收浮层）；返回 true = 已消费 */
  pageBackHandler: (() => boolean) | null = null;

  /** 各二级页注册的页面级返回处理器（如墙的抽屉开着先收抽屉再退页）；返回 true = 已消费 */
  private readonly routeBackHandlers: Map<ShellRoute, () => boolean> = new Map<ShellRoute, () => boolean>();

  private store: preferences.Preferences | null = null;

  protected constructor(wallPrefix: string, flowTag: string) {
    this.wallPrefix = wallPrefix;
    this.flowTag = flowTag;
  }

  /** 打开偏好存储（子类 init 调；就绪后回调子类续接，如车机 drive.init） */
  protected initStore(context: Context, storeName: string,
    onReady: (store: preferences.Preferences) => void): void {
    if (this.store !== null) {
      return;
    }
    preferences.getPreferences(context, storeName)
      .then((store: preferences.Preferences): void => {
        this.store = store;
        onReady(store);
      })
      .catch((): void => {
      });
  }

  /** 压入二级页（同名同参去重：反复点同一张卡不叠层）；实际压入后回调子类（TV 收侧边栏） */
  pushRoute(route: ShellRoute): void {
    const last: ShellRoute | undefined = this.routes[this.routes.length - 1];
    if (last !== undefined && last.routeName === route.routeName && ShellUiState.sameRoute(last, route)) {
      return;
    }
    this.routes.push(route);
    this.onRoutePushed(route);
  }

  /** 实际压入二级页后的钩子（默认空） */
  protected onRoutePushed(route: ShellRoute): void {
  }

  private static sameRoute(a: ShellRoute, b: ShellRoute): boolean {
    if (a instanceof ShellDetailRoute && b instanceof ShellDetailRoute) {
      return a.libraryId === b.libraryId && a.itemId === b.itemId;
    }
    if (a instanceof ShellWallRoute && b instanceof ShellWallRoute) {
      return a.libraryId === b.libraryId && a.kindSource === b.kindSource;
    }
    if (a instanceof ShellRowWallRoute && b instanceof ShellRowWallRoute) {
      return a.sourceKey === b.sourceKey;
    }
    if (a instanceof ShellPersonRoute && b instanceof ShellPersonRoute) {
      return a.tmdbPersonId === b.tmdbPersonId;
    }
    if (a instanceof ShellCollectionRoute && b instanceof ShellCollectionRoute) {
      return a.collectionId === b.collectionId;
    }
    return false;
  }

  /** 二级页注册页面级返回处理（aboutToAppear 注册 / aboutToDisappear 注销） */
  registerRouteBack(route: ShellRoute, handler: () => boolean): void {
    this.routeBackHandlers.set(route, handler);
  }

  /** 注销页面级返回处理（页面离场） */
  unregisterRouteBack(route: ShellRoute): void {
    this.routeBackHandlers.delete(route);
  }

  /** 弹出一层；返回是否还有剩余层 */
  popRoute(): boolean {
    if (this.routes.length === 0) {
      return false;
    }
    const popped: ShellRoute | undefined = this.routes.pop();
    if (popped !== undefined) {
      this.routeBackHandlers.delete(popped);
    }
    return this.routes.length > 0;
  }

  /** 打开播放器覆盖层 */
  openPlayer(request: PlayRequest): void {
    hilog.info(0x0000, this.flowTag, 'OPEN_PLAYER item=%{public}d title=%{public}s',
      request.itemId, request.title);
    this.playerRequest = request;
  }

  /** 关闭播放器覆盖层 */
  closePlayer(): void {
    hilog.info(0x0000, this.flowTag, 'CLOSE_PLAYER');
    this.playerRequest = null;
    this.playerUi.phase = 'idle';
    this.playerUi.errorMessage = null;
    this.playerBackHandler = null;
  }

  /**
   * 返回键分级（外壳 onBackPress 委托到这里）：
   * 播放器内分级 → 页签页浮层 → 弹路由。
   * 返回 false = 分级已到底，交还外壳出「退出确认」（TV 重写补侧边栏分级）。
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
      // 顶层页先给它自己注册的返回处理一次机会（抽屉开着先收抽屉），没消费才退页
      const top: ShellRoute = this.routes[this.routes.length - 1];
      const handler: (() => boolean) | undefined = this.routeBackHandlers.get(top);
      if (handler !== undefined && handler()) {
        return true;
      }
      this.popRoute();
      return true;
    }
    return false;
  }

  /** 换页签（TV 重写补：顺带收起侧边栏） */
  selectTab(tab: string): void {
    this.tab = tab;
  }

  /**
   * 登录完成/重新进入主界面：落到首页，清掉上一次会话遗留的二级页、播放器。
   * （外壳是进程单例，不重置的话「退出登录 → 再登录」会回到上次停留的页签。）
   */
  resetShell(): void {
    this.tab = 'home';
    this.routes = [];
    this.playerRequest = null;
    this.playerUi.phase = 'idle';
    this.playerUi.errorMessage = null;
    this.playerBackHandler = null;
    this.pageBackHandler = null;
  }

  /** 读取某面墙的记忆偏好；没有则给默认 */
  async wallPrefs(wallKey: string): Promise<ShellWallPrefs> {
    const store: preferences.Preferences | null = this.store;
    if (store === null) {
      return new ShellWallPrefs();
    }
    const raw: string = await store.get(`${this.wallPrefix}${wallKey}`, '') as string;
    const parsed: ShellWallPrefs | null = ShellWallPrefs.fromJson(raw);
    return parsed === null ? new ShellWallPrefs() : parsed;
  }

  /** 保存墙偏好（尽力而为，失败静默） */
  saveWallPrefs(wallKey: string, prefs: ShellWallPrefs): void {
    const store: preferences.Preferences | null = this.store;
    if (store === null) {
      return;
    }
    store.put(`${this.wallPrefix}${wallKey}`, prefs.toJson()).then((): void => {
      store.flush();
    }).catch((): void => {
    });
  }

  /** 读一个外壳侧字符串偏好（如配对用的安装标识）；没有给 fallback */
  async cachedString(key: string, fallback: string): Promise<string> {
    const store: preferences.Preferences | null = this.store;
    if (store === null) {
      return fallback;
    }
    return await store.get(key, fallback) as string;
  }

  /** 写一个外壳侧字符串偏好（尽力而为） */
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
