/**
 * TV 端状态模型（@ObservedV2 一代到底，不与 V1 混用）：
 * - 路由 / 墙偏好 / 播放器 UI 状态机 / 发现态：与车机端逐字相同，
 *   由 shell/ShellUiState.ets 定义，这里按 Tv* 别名再导出，页签页无感复用
 * - TvPlayRequest：起播请求（比共享 PlayRequest 少一个 coverUrl 入参，构造时补空串）
 * - TvHomeFocus：首页焦点防抖（0.16s）+ 大图预告计时（焦点停稳 2s）
 * - TvUiState：外壳单例——继承 ShellUiState（路由栈/页签/播放器槽位/返回分级/墙偏好存取），
 *   补 TV 差异（侧边栏展开态与返回分级末位、页签切换收侧边栏）
 */
import { preferences } from '@kit.ArkData';
import { Context } from '@kit.AbilityKit';
import { TvMotion } from '../theme/TvTheme';
import { TvPlaybackHost } from '../playback/TvPlaybackHost';
import { PlayRequest, ShellRoute, ShellUiState } from '../../shell/ShellUiState';

export {
  ShellRoute as TvRoute,
  ShellDetailRoute as TvDetailRoute,
  ShellWallRoute as TvWallRoute,
  ShellRowWallRoute as TvRowWallRoute,
  ShellPersonRoute as TvPersonRoute,
  ShellCollectionRoute as TvCollectionRoute,
  PlayRequest,
  ShellWallPrefs as TvWallPrefs,
  ShellPlayerUiState as TvPlayerUiState,
  ShellDiscoveryState as TvDiscoveryState,
  ShellDiscoveredServer as TvDiscoveredServer
} from '../../shell/ShellUiState';

/** 起播请求：谁、哪一集、从哪起（TV 调用点不传封面，构造时补空串） */
export class TvPlayRequest extends PlayRequest {
  constructor(libraryId: number, itemId: number, seasonNumber: number | null,
    episodeNumber: number | null, fileId: number | null, startMs: number | null,
    title: string, subtitle: string | null, autoAdvance: boolean) {
    super(libraryId, itemId, seasonNumber, episodeNumber, fileId, startMs,
      title, subtitle, '', autoAdvance);
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

/** 页签 */
export class TvTab {
  static readonly home: string = 'home';
  static readonly search: string = 'search';
  static readonly accounts: string = 'accounts';
}

/**
 * TV 外壳单例：路由栈、页签、侧边栏、播放器覆盖层槽位、返回分级、墙偏好存取。
 * 共享分级与存取见 ShellUiState；这里只有 TV 差异（侧边栏）。
 */
@ObservedV2
export class TvUiState extends ShellUiState {
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

  /** 侧边栏展开态 */
  @Trace railExpanded: boolean = false;

  private constructor() {
    super('tv_wall_', 'DbgFlow');
  }

  /** 偏好存储初始化（TvIndex aboutToAppear 调一次） */
  init(context: Context): void {
    TvPlaybackHost.appContext = context;
    this.initStore(context, 'movieclaw_tv', (store: preferences.Preferences): void => {
    });
  }

  /** 实际压入二级页后收起侧边栏（二级页整屏覆盖） */
  protected onRoutePushed(route: ShellRoute): void {
    this.railExpanded = false;
  }

  /**
   * 返回键分级（TvIndex.onBackPress 委托到这里）：
   * 共享分级（播放器→页签页浮层→弹路由）走 super，没消费再收侧边栏。
   * 返回 false = 分级已到底（侧边栏已展开），交还 TvIndex 出「退出确认」。
   */
  handleBack(): boolean {
    if (super.handleBack()) {
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
    super.selectTab(tab);
    this.railExpanded = false;
  }

  /**
   * 登录完成/重新进入主界面：落到首页，清掉上一次会话遗留的二级页、播放器与侧边栏。
   * （TvUiState 是进程单例，不重置的话「退出登录 → 再登录」会回到上次停留的页签。）
   */
  resetShell(): void {
    super.resetShell();
    this.railExpanded = false;
  }
}
