/**
 * 车机端状态模型（@ObservedV2 一代到底，不与 V1 混用）：
 * - 路由 / 起播请求 / 墙偏好 / 播放器 UI 状态机 / 发现态：与 TV 端逐字相同，
 *   由 shell/ShellUiState.ets 定义，这里按 Car* 别名再导出，页签页无感复用
 * - CarDriveState：手动驾驶模式开关（持久化 car_drive_mode）+ 播放模式（video/audioLocked）
 *   + DriveSignalProvider 接口位（真车行车信号可达时自动优先，默认空实现回退手动开关）
 * - CarMiniPlayerState：mini 播控条状态（当前条目摘要）
 * - CarUiState：外壳单例——继承 ShellUiState（路由栈/页签/播放器槽位/返回分级/墙偏好存取），
 *   补车机差异（上下文注入、驾驶模式态、mini 播控条）
 */
import { preferences } from '@kit.ArkData';
import { Context } from '@kit.AbilityKit';
import { CarPlaybackHost } from '../playback/CarPlaybackHost';
import { ShellUiState } from '../../shell/ShellUiState';

export {
  ShellRoute as CarRoute,
  ShellDetailRoute as CarDetailRoute,
  ShellWallRoute as CarWallRoute,
  ShellRowWallRoute as CarRowWallRoute,
  ShellPersonRoute as CarPersonRoute,
  ShellCollectionRoute as CarCollectionRoute,
  PlayRequest as CarPlayRequest,
  ShellWallPrefs as CarWallPrefs,
  ShellPlayerUiState as CarPlayerUiState,
  ShellDiscoveryState as CarDiscoveryState,
  ShellDiscoveredServer as CarDiscoveredServer
} from '../../shell/ShellUiState';

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
 * 行车锁态：手动开关（持久化）+ 播放模式（video/audioLocked）。
 * **默认开启**：系统没有开放行车信号，视频默认锁定、只出音频；停车时由用户手动解锁。
 * 播放模式优先级：注入的行车信号 > 手动开关。
 */
@ObservedV2
export class CarDriveState {
  /** 手动「行车锁」开关（默认开；关 = 停车时手动解锁视频） */
  @Trace manualEnabled: boolean = true;
  /** 生效播放模式（video / audioLocked） */
  @Trace playMode: string = CarPlayMode.audioLocked;
  /** 行车信号接口位（默认空——模拟器/无真车信号时走手动开关） */
  signalProvider: DriveSignalProvider | null = null;

  private store: preferences.Preferences | null = null;

  /** 从偏好恢复手动开关（欢迎初始化时调一次） */
  init(store: preferences.Preferences | null): void {
    this.store = store;
    if (store === null) {
      return;
    }
    store.get('car_drive_mode', true).then((value: preferences.ValueType): void => {
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

/** 页签：首页 / 媒体库 / 搜索 / 账号 */
export class CarTab {
  static readonly home: string = 'home';
  static readonly library: string = 'library';
  static readonly search: string = 'search';
  static readonly accounts: string = 'accounts';
}

/**
 * 车机外壳单例：路由栈、四页签、播放器覆盖层槽位、返回分级、墙偏好存取、驾驶模式态。
 * 共享分级与存取见 ShellUiState；这里只有车机差异。
 */
@ObservedV2
export class CarUiState extends ShellUiState {
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

  /** 驾驶模式态（手动开关 + 播放模式） */
  readonly drive: CarDriveState = new CarDriveState();
  /** mini 播控条状态（引擎/播放器页更新，mini 条读取） */
  readonly mini: CarMiniPlayerState = new CarMiniPlayerState();

  /** UIAbility 上下文（CarIndex init 注入；播放引擎建 AVSession / 长时任务用） */
  context: Context | null = null;

  private constructor() {
    super('car_wall_', 'CarFlow');
  }

  /** 偏好存储初始化（CarIndex aboutToAppear 调一次） */
  init(context: Context): void {
    this.context = context;
    CarPlaybackHost.appContext = context;
    this.initStore(context, 'movieclaw_car', (store: preferences.Preferences): void => {
      this.drive.init(store);
    });
  }
}
