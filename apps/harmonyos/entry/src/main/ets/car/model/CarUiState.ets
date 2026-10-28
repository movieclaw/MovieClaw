/**
 * 车机端状态模型（@ObservedV2 一代到底，不与 V1 混用）：
 * - CarRoute 及其子类：自管路由栈的页面目标（详情/海报墙/行墙/影人/合集）
 * - CarPlayRequest：起播请求（CarShell 播放器覆盖层的开关量）
 * - CarWallPrefs：每面墙的排序/筛选记忆（Preferences 持久化，car_wall_ 前缀）
 * - CarDriveState：手动驾驶模式开关（持久化 car_drive_mode）+ 播放模式（video/audioLocked）
 *   + DriveSignalProvider 接口位（真车行车信号可达时自动优先，默认空实现回退手动开关）
 * - CarMiniPlayerState：mini 播控条状态（当前条目摘要）
 * - CarPlayerUiState：播放器 UI 状态机（供外壳判断覆盖层去留）
 * - CarDiscoveryState：欢迎流程的局域网发现态
 * - CarUiState：外壳单例——路由栈 / 页签 / 播放器槽位 / 返回分级 / 墙偏好存取
 */
import { preferences } from '@kit.ArkData';
import { Context } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** 路由基类：子类用 instanceof 分派（ArkTS 无带关联值的枚举） */
export class CarRoute {
  readonly routeName: string;

  constructor(routeName: string) {
    this.routeName = routeName;
  }
}

/** 条目详情页 */
export class CarDetailRoute extends CarRoute {
  readonly libraryId: number;
  readonly itemId: number;

  constructor(libraryId: number, itemId: number) {
    super('detail');
    this.libraryId = libraryId;
    this.itemId = itemId;
  }
}

/** 单库海报墙（含 kind 跨库墙：libraryId 传 0、kindSource 传类型） */
export class CarWallRoute extends CarRoute {
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
 * - person:<tmdbPersonId>（影人作品行墙）
 */
export class CarRowWallRoute extends CarRoute {
  readonly sourceKey: string;
  readonly title: string;

  constructor(sourceKey: string, title: string) {
    super('rowWall');
    this.sourceKey = sourceKey;
    this.title = title;
  }
}

/** 影人页（作品行墙） */
export class CarPersonRoute extends CarRoute {
  readonly tmdbPersonId: number;
  readonly personName: string;

  constructor(tmdbPersonId: number, personName: string) {
    super('person');
    this.tmdbPersonId = tmdbPersonId;
    this.personName = personName;
  }
}

/** 合集详情（复用行墙铺成员） */
export class CarCollectionRoute extends CarRoute {
  readonly collectionId: number;
  readonly title: string;

  constructor(collectionId: number, title: string) {
    super('collection');
    this.collectionId = collectionId;
    this.title = title;
  }
}

/** 起播请求：谁、哪一集、从哪起 */
export class CarPlayRequest {
  readonly libraryId: number;
  readonly itemId: number;
  readonly seasonNumber: number | null;
  readonly episodeNumber: number | null;
  readonly fileId: number | null;
  /** null = 续播（服务端 playbackResume 决定）；0 = 从头 */
  readonly startMs: number | null;
  /** 界面标签（播放器标题行） */
  readonly title: string;
  readonly subtitle: string | null;
  /** 封面地址（mini 播控条用；海报/剧照取其一） */
  readonly coverUrl: string;
  /** 播完是否自动接下一集（剧集连播） */
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

/** 每面墙的排序/筛选记忆（单库存于 car_wall_<libraryId> 一个 JSON 串） */
export class CarWallPrefs {
  sort: string = 'added_at';
  order: string = 'desc';
  unwatched: boolean = false;
  /** 筛选：类型/年代/分辨率/观看状态（对应 libraryItemsList 的 g/d/res/w 参数） */
  genre: string | null = null;
  decade: string | null = null;
  resolution: string | null = null;
  watch: string | null = null;

  static fromJson(raw: string): CarWallPrefs | null {
    if (raw.length === 0) {
      return null;
    }
    try {
      const parsed: CarWallPrefs = JSON.parse(raw) as CarWallPrefs;
      const prefs: CarWallPrefs = new CarWallPrefs();
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

/** 播放模式：驻车视频 / 行车音频锁（视频表面隐藏，音频链路不重建） */
export class CarPlayMode {
  static readonly video: string = 'video';
  static readonly audioLocked: string = 'audioLocked';
}

/**
 * 行车信号接口位：真车行车状态 API 可达时由宿主注入（返回 true = 行车中），
 * 车机 UI 侧默认空实现——播放模式回退手动「驾驶模式」开关（FR-010）。
 */
export interface DriveSignalProvider {
  isDriving(): boolean;
}

/**
 * 驾驶模式态：手动开关（持久化）+ 播放模式（video/audioLocked）。
 * 播放模式优先级：注入的行车信号 > 手动开关；两者都不可用时恒为 video。
 */
@ObservedV2
export class CarDriveState {
  /** 手动「驾驶模式」开关 */
  @Trace manualEnabled: boolean = false;
  /** 生效播放模式（video / audioLocked） */
  @Trace playMode: string = CarPlayMode.video;
  /** 行车信号接口位（默认空——模拟器/无真车信号时走手动开关） */
  signalProvider: DriveSignalProvider | null = null;

  private store: preferences.Preferences | null = null;

  /** 从偏好恢复手动开关（欢迎初始化时调一次） */
  init(store: preferences.Preferences | null): void {
    this.store = store;
    if (store === null) {
      return;
    }
    store.get('car_drive_mode', false).then((value: preferences.ValueType): void => {
      this.manualEnabled = value === true;
      this.refreshPlayMode();
    }).catch((): void => {
    });
  }

  /** 手动开关切换：持久化并重算播放模式 */
  setManual(enabled: boolean): void {
    this.manualEnabled = enabled;
    const store: preferences.Preferences | null = this.store;
    if (store !== null) {
      store.put('car_drive_mode', enabled).then((): void => {
        store.flush();
      }).catch((): void => {
      });
    }
    this.refreshPlayMode();
  }

  /** 重算生效播放模式：行车信号优先，手动开关兜底 */
  refreshPlayMode(): void {
    let driving: boolean = this.manualEnabled;
    const provider: DriveSignalProvider | null = this.signalProvider;
    if (provider !== null && provider.isDriving()) {
      driving = true;
    }
    this.playMode = driving ? CarPlayMode.audioLocked : CarPlayMode.video;
  }

  /** 当前是否处于行车锁（视频锁定、音频继续） */
  isAudioLocked(): boolean {
    return this.playMode === CarPlayMode.audioLocked;
  }
}

/** mini 播控条状态（当前条目摘要；显隐由「引擎在播 && 播放器覆盖层关闭」驱动） */
@ObservedV2
export class CarMiniPlayerState {
  /** 条目标题（播放器标题行同款） */
  @Trace title: string = '';
  /** 副标题（集名等） */
  @Trace subtitle: string = '';
  /** 封面地址 */
  @Trace coverUrl: string = '';
  /** 播放中（false = 暂停） */
  @Trace playing: boolean = false;
  /** 有可播的下一集 */
  @Trace hasNext: boolean = false;
}

/** 播放器 UI 状态机（外壳只关心 phase 与 overlayVisible） */
@ObservedV2
export class CarPlayerUiState {
  /** idle=未挂载 preparing=建会话中 playing=播中 paused=暂停 error=错误 */
  @Trace phase: string = 'idle';
  @Trace errorMessage: string | null = null;
}

/** 欢迎流程的发现态 */
@ObservedV2
export class CarDiscoveryState {
  @Trace scanning: boolean = false;
  @Trace servers: CarDiscoveredServer[] = [];
  @Trace message: string | null = null;
}

/** 发现到的一台候选服务器 */
export class CarDiscoveredServer {
  readonly origin: string;
  readonly name: string;

  constructor(origin: string, name: string) {
    this.origin = origin;
    this.name = name;
  }
}

/** 页签：首页 / 媒体库 / 搜索 / 账号 */
export class CarTab {
  static readonly home: string = 'home';
  static readonly library: string = 'library';
  static readonly search: string = 'search';
  static readonly accounts: string = 'accounts';
}

/**
 * 车机外壳单例：路由栈、四页签、播放器覆盖层槽位、返回分级、墙偏好存取、驾驶模式态。
 */
@ObservedV2
export class CarUiState {
  private static instance: CarUiState | null = null;

  /**
   * 惰性单例（同 AppModel）：`static readonly shared = new CarUiState()` 会在类定义阶段
   * 构造实例，早于 @ObservedV2 装上观察钩子——那样 @Trace 字段变化不会通知任何组件。
   */
  static get shared(): CarUiState {
    if (CarUiState.instance === null) {
      CarUiState.instance = new CarUiState();
    }
    return CarUiState.instance;
  }

  /** 二级页路由栈（后进先出，整屏覆盖） */
  @Trace routes: CarRoute[] = [];
  /** 当前页签 */
  @Trace tab: string = CarTab.home;
  /** 播放器覆盖层开关量；非 null 即挂载 CarPlayerPage */
  @Trace playerRequest: CarPlayRequest | null = null;
  /** 播放器 UI 状态（页面更新，外壳读取） */
  readonly playerUi: CarPlayerUiState = new CarPlayerUiState();
  /** 驾驶模式态（手动开关 + 播放模式） */
  readonly drive: CarDriveState = new CarDriveState();
  /** mini 播控条状态（引擎/播放器页更新，mini 条读取） */
  readonly mini: CarMiniPlayerState = new CarMiniPlayerState();

  /** 播放器页注册的返回处理器（面板→退出确认的分级在页内实现）；返回 true = 已消费 */
  playerBackHandler: (() => boolean) | null = null;

  /** 页签页注册的返回处理器（如账号页「关于」浮层开着先收浮层）；返回 true = 已消费 */
  pageBackHandler: (() => boolean) | null = null;

  /** UIAbility 上下文（CarIndex init 注入；播放引擎建 AVSession / 长时任务用） */
  context: Context | null = null;

  /** 各二级页注册的页面级返回处理器（如墙的抽屉开着先收抽屉再退页）；返回 true = 已消费 */
  private readonly routeBackHandlers: Map<CarRoute, () => boolean> = new Map<CarRoute, () => boolean>();

  private store: preferences.Preferences | null = null;

  private constructor() {
  }

  /** 偏好存储初始化（CarIndex aboutToAppear 调一次） */
  init(context: Context): void {
    this.context = context;
    if (this.store !== null) {
      return;
    }
    preferences.getPreferences(context, 'movieclaw_car')
      .then((store: preferences.Preferences): void => {
        this.store = store;
        this.drive.init(store);
      })
      .catch((): void => {
      });
  }

  /** 压入二级页（同名同参去重：反复点同一张卡不叠层） */
  pushRoute(route: CarRoute): void {
    const last: CarRoute | undefined = this.routes[this.routes.length - 1];
    if (last !== undefined && last.routeName === route.routeName && CarUiState.sameRoute(last, route)) {
      return;
    }
    this.routes.push(route);
  }

  private static sameRoute(a: CarRoute, b: CarRoute): boolean {
    if (a instanceof CarDetailRoute && b instanceof CarDetailRoute) {
      return a.libraryId === b.libraryId && a.itemId === b.itemId;
    }
    if (a instanceof CarWallRoute && b instanceof CarWallRoute) {
      return a.libraryId === b.libraryId && a.kindSource === b.kindSource;
    }
    if (a instanceof CarRowWallRoute && b instanceof CarRowWallRoute) {
      return a.sourceKey === b.sourceKey;
    }
    if (a instanceof CarPersonRoute && b instanceof CarPersonRoute) {
      return a.tmdbPersonId === b.tmdbPersonId;
    }
    if (a instanceof CarCollectionRoute && b instanceof CarCollectionRoute) {
      return a.collectionId === b.collectionId;
    }
    return false;
  }

  /** 二级页注册页面级返回处理（aboutToAppear 注册 / aboutToDisappear 注销） */
  registerRouteBack(route: CarRoute, handler: () => boolean): void {
    this.routeBackHandlers.set(route, handler);
  }

  /** 注销页面级返回处理（页面离场） */
  unregisterRouteBack(route: CarRoute): void {
    this.routeBackHandlers.delete(route);
  }

  /** 弹出一层；返回是否还有剩余层 */
  popRoute(): boolean {
    if (this.routes.length === 0) {
      return false;
    }
    const popped: CarRoute | undefined = this.routes.pop();
    if (popped !== undefined) {
      this.routeBackHandlers.delete(popped);
    }
    return this.routes.length > 0;
  }

  /** 打开播放器覆盖层 */
  openPlayer(request: CarPlayRequest): void {
    hilog.info(0x0000, 'CarFlow', 'OPEN_PLAYER item=%{public}d title=%{public}s', request.itemId, request.title);
    this.playerRequest = request;
  }

  /** 关闭播放器覆盖层 */
  closePlayer(): void {
    hilog.info(0x0000, 'CarFlow', 'CLOSE_PLAYER');
    this.playerRequest = null;
    this.playerUi.phase = 'idle';
    this.playerUi.errorMessage = null;
    this.playerBackHandler = null;
  }

  /**
   * 返回键分级（CarIndex.onBackPress 委托到这里）：
   * 播放器内分级（面板→退出确认）→ 页签页浮层 → 弹路由。
   * 返回 false = 分级已到底，交还 CarIndex 出「退出确认」。
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
      const top: CarRoute = this.routes[this.routes.length - 1];
      const handler: (() => boolean) | undefined = this.routeBackHandlers.get(top);
      if (handler !== undefined && handler()) {
        return true;
      }
      this.popRoute();
      return true;
    }
    return false;
  }

  /** 换页签 */
  selectTab(tab: string): void {
    this.tab = tab;
  }

  /**
   * 登录完成/重新进入主界面：落到首页，清掉上一次会话遗留的二级页、播放器。
   * （CarUiState 是进程单例，不重置的话「退出登录 → 再登录」会回到上次停留的页签。）
   */
  resetShell(): void {
    this.tab = CarTab.home;
    this.routes = [];
    this.playerRequest = null;
    this.playerUi.phase = 'idle';
    this.playerUi.errorMessage = null;
    this.playerBackHandler = null;
    this.pageBackHandler = null;
  }

  /** 读取某面墙的记忆偏好；没有则给默认 */
  async wallPrefs(wallKey: string): Promise<CarWallPrefs> {
    const store: preferences.Preferences | null = this.store;
    if (store === null) {
      return new CarWallPrefs();
    }
    const raw: string = await store.get(`car_wall_${wallKey}`, '') as string;
    const parsed: CarWallPrefs | null = CarWallPrefs.fromJson(raw);
    return parsed === null ? new CarWallPrefs() : parsed;
  }

  /** 保存墙偏好（尽力而为，失败静默） */
  saveWallPrefs(wallKey: string, prefs: CarWallPrefs): void {
    const store: preferences.Preferences | null = this.store;
    if (store === null) {
      return;
    }
    store.put(`car_wall_${wallKey}`, prefs.toJson()).then((): void => {
      store.flush();
    }).catch((): void => {
    });
  }

  /** 读一个车机侧字符串偏好（如配对用的安装标识）；没有给 fallback */
  async cachedString(key: string, fallback: string): Promise<string> {
    const store: preferences.Preferences | null = this.store;
    if (store === null) {
      return fallback;
    }
    return await store.get(key, fallback) as string;
  }

  /** 写一个车机侧字符串偏好（尽力而为） */
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
