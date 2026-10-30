import { Theme } from '../theme/AppTheme';
import { PlaybackTestProbe, PlaybackTestHost } from './PlaybackTestProbe';
import { BusinessError, settings } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { PiPWindow, window, UIContext } from '@kit.ArkUI';
import { audio } from '@kit.AudioKit';
import { image } from '@kit.ImageKit';
import { http } from '@kit.NetworkKit';
import { PlaybackGuard } from '@movieclaw/playback';
import { PlayerPrefs, SubStyle } from '../player/PlayerPrefs';
import { PlaybackController, PlaybackSnapshot, PlaybackIntent, PlaybackSessionCoordinator, PlaybackOwnership, SkipSegments } from '@movieclaw/playback';
import { EngineEvent, EngineFailure } from '@movieclaw/player-engine';
import { PhoneMedia, playbackUrl } from './PhoneMedia';
import { MovieClawPlaybackSession } from './MovieClawPlaybackSession';
import { MovieClawPlaybackGateway } from './MovieClawPlaybackGateway';

import { Formatters } from '../common/Formatters';
import { ShellChrome } from '../common/ShellChrome';
import { AppModel, ClipReturn } from '../common/AppModel';

import { ImageUrls } from '../common/ImageUrls';

import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { OfflineDisk } from '../offline/OfflineDisk';
import { OfflineStore } from '../offline/OfflineStore';
import { OfflineViewingRecorder } from '../offline/OfflineViewings';
import { OfflinePlaybackSpec, OfflineProgress, OfflineUnit } from '../offline/OfflineModels';
import { ClientCapabilityIn, PlaybackSessionRequest, PlaybackSessionView, PlaybackDecisionView, PlaybackStateView, AudioTrackView, EpisodeView, LibraryItemDetailView, PlaybackChapterMarkView, PlaybackItemView, SeasonEpisodesView, SubtitlePlanView, TrickplayView, PlaybackSegmentView, PlaybackDiagnosticsView, PlaybackPolicyView, PlaybackArtifactUploadView } from '../api/Models';

import { PlayerParams } from '../player/PlayerParams';

/** `PlaybackSessionRequest` 的 capability 是必填，其余可选 */
export class SessionRequest implements PlaybackSessionRequest {
  file_id?: number | null;
  media_item_id?: number | null;
  season_number?: number | null;
  episode_number?: number | null;
  capability: ClientCapabilityIn = MovieClawPlaybackGateway.capability('avplayer');
  /** 已失败的档位：服务端据此跳过它们（后端的「运行期降档回路」） */
  failed_tiers?: number[] | null;
  /** 选中的音轨 ref；给了服务端就认它、不再自动换轨（可能把直出顶成重封装） */
  audio_track?: string | null;
  subtitle_track?: string | null;
  /** 用户选的画质上限（语义是上限：源不超就直通，超了才转码降下去；null = 自动） */
  max_height?: number | null;
  start_ms?: number | null;
  client?: string | null;
}

/** 画质选项（iOS `QualityOption.all`：原画/1080p/720p/480p；maxHeight 是**上限**语义） */
export class QualityOption {
  readonly label: string;
  readonly maxHeight: number;

  constructor(label: string, maxHeight: number) {
    this.label = label;
    this.maxHeight = maxHeight;
  }
}

/** 播放状态机 */
export class PlayerPhase {
  static readonly negotiating: string = 'negotiating';
  static readonly ready: string = 'ready';
  /** 服务端说这片要开软件转码：等用户同意（iOS `PlayerConsentView`） */
  static readonly consent: string = 'consent';
  static readonly failed: string = 'failed';
}

/**
 * 跳过区间 / 自动连播的客户端用法（对应 iOS `SkipSegments`，逻辑照 Web `lib/player/timeline.ts`）：
 * 区间是服务端整季比对认出来的、随会话下发，这里只管按位置用，不做任何计算。
 * `outro && to_end`（一直放到结尾的片尾）不进「跳过」按钮，交给「即将播放」卡片。
 */

/**
 * 进度条缩略图（对应 iOS `TrickplayImages`）：按需下载雪碧图，按落点裁出目标格子。
 * 雪碧图 token 已在地址里（不需要登录头）；裁格子走 `DecodingOptions.desiredRegion`，
 * 裁过的格子按序号缓存（一次拖动里每个序号最多裁一次）。
 */
export class TrickplayTiles {
  private index: TrickplayView | null = null;
  private sheets: Map<string, ArrayBuffer> = new Map<string, ArrayBuffer>();
  private loading: Set<string> = new Set<string>();
  private tiles: Map<number, image.PixelMap> = new Map<number, image.PixelMap>();
  /** 雪碧图下载完成的回调（外面用它驱动界面刷新） */
  onSheetLoaded: (() => void) | null = null;

  setIndex(index: TrickplayView | null): void {
    this.index = index;
    this.sheets.clear();
    this.loading.clear();
    this.releaseTiles();
  }

  /** 原生位图必须显式 release：只丢引用会等 GC 终结器，几十张格子的原生内存峰值明显 */
  private releaseTiles(): void {
    this.tiles.forEach((tile: image.PixelMap): void => {
      tile.release().catch((): void => {
      });
    });
    this.tiles.clear();
  }

  /** 文件时间（毫秒）→ 该显示的格子；雪碧图还没下完返回 null（并开始下载） */
  tileAt(ms: number, origin: string): image.PixelMap | null {
    const index: TrickplayView | null = this.index;
    if (index === null || !index.ready || index.count <= 0 || index.interval_ms <= 0
      || index.columns <= 0 || index.sheets.length === 0) {
      return null;
    }
    const ordinal: number = Math.min(Math.max(0, Math.floor(ms / index.interval_ms)), index.count - 1);
    const cached: image.PixelMap | null = this.tiles.get(ordinal) ?? null;
    if (cached !== null) {
      return cached;
    }
    const perSheet: number = index.columns * index.rows;
    const sheetIndex: number = Math.min(Math.floor(ordinal / perSheet), index.sheets.length - 1);
    const within: number = ordinal - sheetIndex * perSheet;
    const path: string = index.sheets[sheetIndex];
    const buffer: ArrayBuffer | null = this.sheets.get(path) ?? null;
    if (buffer === null) {
      this.loadSheet(path, origin + path);
      return null;
    }
    // 裁格子：desiredRegion 是解码期裁剪，正好当 iOS 的 cgImage.cropping 用
    try {
      const source: image.ImageSource = image.createImageSource(buffer);
      const region: image.Region = {
        x: (within % index.columns) * index.tile_width,
        y: Math.floor(within / index.columns) * index.tile_height,
        size: { width: index.tile_width, height: index.tile_height }
      };
      source.createPixelMap({ desiredRegion: region }).then((tile: image.PixelMap): void => {
        source.release();
        if (this.tiles.size >= 60) {
          this.releaseTiles();
        }
        this.tiles.set(ordinal, tile);
        if (this.onSheetLoaded !== null) {
          this.onSheetLoaded();
        }
      }).catch((): void => {
        source.release();
      });
    } catch (error) {
      // 裁不出来：这一格就没有预览，不影响播放
    }
    return null;
  }

  private loadSheet(path: string, url: string): void {
    if (this.loading.has(path) || url.length === 0) {
      return;
    }
    this.loading.add(path);
    const request: http.HttpRequest = http.createHttp();
    request.request(url, {
      method: http.RequestMethod.GET,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: 15000,
      readTimeout: 60000
    }).then((resp: http.HttpResponse): void => {
      request.destroy();
      if (resp.responseCode >= 200 && resp.responseCode < 300) {
        this.sheets.set(path, resp.result as ArrayBuffer);
      }
    }).catch((): void => {
      request.destroy();
    });
  }
}

/**
 * 播放器（对应 iOS `PlaybackController` 的**最小可用切片**）。
 *
 * 按 §5.5 的设计：**服务端转码为主 + 本机 AVPlayer 兜底**——而不是 iOS 那套「本机换封装为主」。
 * 鸿蒙的 `AVPlayer` 官方承诺格式比 iOS 窄（mp4/mkv/ts + H264/H265 + AAC/MP3），
 * 所以客户端把自己的能力如实报给服务端（`playbackSessionStart`），由服务端判定档位，
 * 需要转码时直接回一个 HLS 地址——**判定逻辑全在服务端，客户端只负责说自己能放什么**。
 *
 * 本切片包含：能力上报 → 起会话拿 `stream_url` → `XComponent(SURFACE)` + `AVPlayer` 播放 →
 * 播放/暂停/进度条/时间 → 退出时上报进度。
 *
 * **必须用 `XComponent(type: SURFACE)`** 而不是 `Video` 组件或 AVPlayer 默认 surface——
 * 画中画（`@ohos.PiPWindow`）要求 surface 可迁移，换成别的形态以后就得推倒重来。
 *
 * 后台播放（AVSession + 长时任务）、画中画（`@ohos.PiPWindow`）、音频焦点（`on('audioInterrupt')`）、
 * 字幕轨与音轨切换、章节与跳过片头片尾都已接上。
 *
 * 本轮补齐**手势层与长按倍速**（对应 iOS `PlayerGestureLayer`，判定阈值原样照搬）：
 * - 单击 = 切换控制条（不为等双击延迟）；双击左右三分之一 = ∓10 秒；
 * - 横滑 = 拖进度，满屏一划 90 秒，松手才跳（鸿蒙走服务端转码 HLS，AVPlayer 的跳转要重新取分片，
 *   不像 iOS 能在缓冲里廉价跟随——iOS 的 `scrubFollow` 途中跟随在 HLS 上会打爆转码器，所以只做「落点读数 + 松手跳」）；
 * - 左半屏竖滑 = 亮度（`setWindowBrightness`，退出恢复跟随系统）；右半屏竖滑 = 音量——
 *   **鸿蒙三方应用改不了系统音量**，与 iOS 音量不可调时的降级一致：弹「音量由系统侧键控制」；
 * - 按住 500ms 不动 = 2 倍速（抬手恢复；暂停时不起）。
 */

@ObservedV2
export class PhonePlaybackHost implements PlaybackTestHost {

  navStack: NavPathStack = new NavPathStack();
  chrome: ShellChrome = ShellChrome.shared;
  started: boolean = false;
  controller: PlaybackController = new PlaybackController();
  sessionCoordinator: PlaybackSessionCoordinator = new PlaybackSessionCoordinator();
  sessionEpoch: number = 0;
  pausedIntent: boolean = false;
  reopening: boolean = false;
  disposed: boolean = false;
  detached: boolean = false;
  surfaceId: string = '';
  /** 拿 surface id 的正规途径：XComponentController（`XComponentContext` 不是公开类型） */
  surfaceController: XComponentController = new XComponentController();
  @Trace surfaceGeneration: number = 0;
  surfaceWaiter: ((surface: string) => void) | null = null;

  @Trace engineOpening: boolean = false;
  @Trace phase: string = PlayerPhase.negotiating;
  @Trace errorMessage: string = '';
  @Trace session: PlaybackSessionView | null = null;
  @Trace playing: boolean = false;
  @Trace durationMs: number = 0;
  @Trace positionMs: number = 0;
  /** timeUpdate 的 500ms 节流桶：播放全程约 100ms 一报，直写 @Local 会拖整层控制条高频重算 */
  timeBucket: number = -1;
  @Trace title: string = '';

  mediaItemId: number = 0;
  fileId: number = 0;
  seasonNumber: number = 0;
  episodeNumber: number = 0;
  startMs: number = 0;
  resumeExplicit: boolean = false;
  /** 分享访客播放的 slug；空 = 站内播放（进度只存本机） */
  shareSlug: string = '';
  /** 已失败的档位：重试时带给服务端，让它跳过这些档（后端的「运行期降档回路」） */
  failedTiers: number[] = [];
  /** 已经重试过几次，避免无限循环 */
  retryCount: number = 0;

  // —— 本机副本（离线下载的播放路径，对应 iOS startLocal 一节）——
  /** 正在放的本机单元（有它就不建服务端会话，进度记 OfflineViewingRecorder） */
  localUnit: OfflineUnit | null = null;
  /** 本机播放数据（playback.json：章节 / 音轨 / 外挂字幕清单） */
  localSpec: OfflinePlaybackSpec | null = null;
  /** 本机观看记录器（进度先落盘，能连上时补传） */
  viewingRecorder: OfflineViewingRecorder | null = null;
  localMediaPath: string = '';
  /** prepared 时要跳到的位置（重建播放器续位用；-1 = 从头） */
  pendingSeekMs: number = -1;
  /** 本机目录只等一次（冷启动直达播放器时先等目录读完再判「有没有副本」） */
  awaitedOfflineStore: boolean = false;
  /** 本机副本真放不了（文件坏 / 解码不动）：这一集不再试本机，直接走服务端 */
  localFailedOnce: boolean = false;
  /** 本机失败已在回退服务端（error 事件可能连发，防并发协商） */
  localFallingBack: boolean = false;
  /** 本机外挂字幕当前句文本（subtitleUpdate 只回调文本，渲染自己来） */
  @Trace subtitleCue: string = '';
  /** 起播看门狗：HLS 取不到分片时 AVPlayer **不报错、只是无限重试**（实测每 15 秒一次），
   *  所以「这一档放不了」只能靠自己计时判定，不能等 error 事件。 */
  /** 系统合规壳：后台播放 + 音频焦点 + 系统媒体控制 */
  guard: PlaybackGuard | null = null;
  /** 画中画控制器（懒建；只在系统支持时才建） */
  pip: PiPWindow.PiPController | null = null;
  @Trace pipActive: boolean = false;
  /** 浮层控制条显隐（iOS：点画面切换，播放中 4 秒后自动收起；暂停/弹层开着时钉住） */
  @Trace chromeVisible: boolean = true;
  chromeTimer: number = -1;
  /** 视频宽高比（用来把 surface 摆成视频的形状，不然画面会被拉伸） */
  @Trace videoAspect: number = 16 / 9;
  /** 字幕：候选轨、当前选中的下标（-1 = 关） */
  /** 弹层槽位（一个组件只能绑一个 bindSheet）：空串=关，subtitle=字幕，stats=播放详情 */
  @Trace sheetKind: string = '';
  @Trace showSheet: boolean = false;
  @Trace controlsLocked: boolean = false;
  @Trace menuTop: number = 0;
  @Trace menuAnchorTop: number = 0;
  @Trace playbackRate: number = 1;
  @Trace displayMode: string = 'fit';
  @Trace subtitleIndex: number = -1;
  subtitleRef: string = '';
  /** 音轨：当前选中的 ref（空 = 服务端自动挑） */
  @Trace audioRef: string = '';
  @Trace showAudio: boolean = false;

  // —— 下一集 / 自动连播（对应 iOS PlaybackController 的 autoNext 一节）——
  /** 本季分集（「即将播放」卡片与自动连播用） */
  @Trace episodes: EpisodeView[] = [];
  /** 播完了（AVPlayer completed）：卡片与自动连播的触发条件之一 */
  @Trace ended: boolean = false;
  /** 用户关掉了卡片（这一集里不再弹；换集时重置） */
  @Trace nextDismissed: boolean = false;
  /** 倒计时进度 0...1（卡片「立即播放」按钮上的白条就是它） */
  @Trace autoNextProgress: number = 0;
  autoNextCancelled: boolean = false;
  /** 连续自动播了几集（期间有任何操作就清零，满上限不再自动播） */
  autoNextStreak: number = 0;
  /** 倒计时的钟：10Hz（同 iOS 卡片上的 .task 循环），页面存活期间常驻、内部自查要不要走 */
  autoNextTimer: number = -1;

  // —— 进度条缩略图（对应 iOS TrickplayImages / loadTrickplay）——
  trickplay: TrickplayTiles = new TrickplayTiles();
  /** 轮询代数：换集 / 重协商后旧轮询作废 */
  trickplayGen: number = 0;
  /** 雪碧图异步就位后驱动预览刷新的版本号 */
  @Trace trickplayVersion: number = 0;

  // —— 手势层（对应 iOS PlayerGestureLayer 的 GestureView 状态机，阈值原样照搬）——
  /** 移动超过这个距离才算拖动（12pt） */
  static readonly activatePx: number = 12;
  /** 上下边缘 32vp 内起手交给系统（控制中心 / 主屏幕手势） */
  static readonly edgeGuard: number = 32;
  /** 双击窗口 300ms */
  static readonly doubleTapWindow: number = 300;
  /** 长按 500ms 起 2 倍速 */
  static readonly holdDelay: number = 500;
  /** 竖滑调节：满量程 = 可用高度 × 60% */
  static readonly fullSweepRatio: number = 0.6;
  /** 竖滑调节起手排除带：顶部 12%、底部 24%（进度条与控制区） */
  static readonly adjustTopExclude: number = 0.12;
  static readonly adjustBottomExclude: number = 0.24;
  /** 横滑拖进度：满屏一划 = 90 秒（同 Web FULL_SWEEP_SEEK_S） */
  static readonly fullSweepSeekMs: number = 90000;

  gestureTracking: boolean = false;
  gestureTouchId: number = -1;
  gestureStartX: number = 0;
  gestureStartY: number = 0;
  /** undecided = 未定 | scrub = 横滑拖进度 | adjust = 竖滑调节 | hold = 长按倍速 */
  gestureIntent: string = 'undecided';
  holdTimer: number = -1;
  lastTapAt: number = 0;
  /** 双击跳转后控制层要恢复成第一下点之前的样式（iOS lastTapChromeState） */
  lastTapChromeState: boolean = true;
  /** 手势层尺寸（判定排除带与满量程都要用） */
  @Trace layerWidth: number = 0;
  @Trace layerHeight: number = 0;
  /** 手势层在窗口里的原点：把控制条测出来的全局坐标换算回手势层坐标系 */
  layerOriginX: number = 0;
  layerOriginY: number = 0;
  // Top/bottom empty space is excluded from video gestures; buttons own their touch targets.
  @Trace chromeTopY: number[] = [0, 0];
  chromeBottomY: number[] = [0, 0];

  /** 长按 2 倍速生效中（HUD 显示「2× 快进中」） */
  @Trace holdSpeedActive: boolean = false;
  /** 竖滑调节：'' = 无，'brightness' / 'volume' */
  @Trace adjustSide: string = '';
  @Trace adjustValue: number = 0;
  adjustBase: number = 0;
  /** 调节胶囊松手 0.9 秒后收起 */
  adjustHideTimer: number = -1;
  /** 横滑定位的落点（-1 = 没在拖）；松手才跳 */
  @Trace scrubMs: number = -1;
  scrubBaseMs: number = 0;
  /** 亮度：窗口句柄 + 是否动过（退出时恢复跟随系统） */
  brightnessWindow: window.Window | null = null;
  brightnessTouched: boolean = false;

  // —— 错误页 / 同意弹窗 / 画质（iOS PlayerErrorView / PlayerConsentView / QualityOption）——
  /** 错误页的建议行（iOS errorSuggestion），与主文案分层显示 */
  @Trace errorSuggestion: string = '';
  /** 同意弹窗的「开启并播放」按钮在转圈 */
  @Trace consentSaving: boolean = false;
  /** 画质上限（0 = 自动/原画）。按条目记本机记忆，起播时回读（iOS QualityMemory） */
  @Trace maxHeight: number = 0;
  /** 横屏锁定（顶栏按钮切换；退出时恢复竖屏） */
  @Trace landscapeLocked: boolean = false;
  /** 屏幕常亮是否已设置（播放中开启，退出恢复） */
  keptScreenOn: boolean = false;

  // —— 片段播放（刷片页「全屏观看」，iOS PlaybackClip）——
  clipStartMs: number = 0;
  clipEndMs: number = 0;
  /** 片段播完（completed 状态不会来——片段只是文件里的一段，自己看位置） */
  @Trace clipEnded: boolean = false;

  // —— 底栏进度条可拖（iOS PlayerProgressBar；仍是「松手才跳」）——
  barDragging: boolean = false;
  progressBarWidth: number = 0;
  barLeftX: number = 0;
  barY: number[] = [0, 0];

  // —— 诊断面板（iOS PlayerDiagnosticsPanel：开着「详情」时 2 秒拉一次快照）——
  @Trace diag: PlaybackDiagnosticsView | null = null;
  diagTimer: number = -1;

  // —— 自绘字幕样式（本机外挂轨；流式轨由系统渲染改不了，iOS SubtitleStyle）——
  @Trace subFontScale: number = 5.2;
  @Trace subBottom: number = 8;
  @Trace subBackground: boolean = true;

  private ui: UIContext | null = null;
  bindUI(context: UIContext): void { this.ui = context; }
  getUIContext(): UIContext {
    if (this.ui === null) { throw new Error('Player UI is not attached'); }
    return this.ui;
  }
  aboutToAppear(): void {
    this.bindController();
    PlaybackTestProbe.bind(this);
    this.claimPlayback();
    // 雪碧图异步下载完 → 版本号 +1，驱动横滑预览重查一次
    this.trickplay.onSheetLoaded = (): void => {
      this.trickplayVersion++;
    };
    // 自绘字幕样式（本机外挂轨）：异步回读，慢一点也只是先按默认样式画
    PlayerPrefs.subtitleStyle().then((style: SubStyle): void => {
      this.subFontScale = style.fontScale;
      this.subBottom = style.bottomPercent;
      this.subBackground = style.background;
      this.controller.setSubtitleStyle(style);
    });
  }

  aboutToDisappear(): void {
    this.detached = true;
    if (this.pipActive) { this.chrome.pop('player'); this.restoreBrightness(); this.restoreOrientation(); return; }
    if (this.disposed) { return; }
    PlaybackTestProbe.record('dispose');
    this.disposed = true; ++this.sessionEpoch;
    this.surfaceWaiter?.(''); this.surfaceWaiter = null;
    PlaybackOwnership.release(this);
    if (this.chromeTimer >= 0) { clearTimeout(this.chromeTimer); }
    this.pip?.setAutoStartEnabled(false);
    this.chrome.pop('player');
    const guard: PlaybackGuard | null = this.guard;
    this.guard = null;
    if (guard !== null) {
      guard.stop().catch((): void => {
      });
    }
    this.endHoldSpeed();
    this.restoreBrightness();
    this.allowScreenOff();
    this.restoreOrientation();
    this.disarmHoldTimer();
    this.disarmAdjustHide();
    this.stopAutoNextClock();

    this.stopDiagnostics();
    this.trickplayGen++;
    // 离开播放器：补发一次 stop（服务端记下最后位置，续播点 / 「继续观看」靠它）

    // 缩略图缓存里的原生 PixelMap 显式释放（顺带清掉雪碧图缓冲）
    this.trickplay.setIndex(null);
    this.releasePlayer().then((): void => this.stopSession());
  }

  api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  // MARK: 能力与协商

  /**
   * 如实上报本机能力。
   * 只报官方承诺的那一档（mp4/mkv/ts + H264/H265 + AAC/MP3），**不虚报**——
   * 虚报会让服务端判定「能直出」，结果播不了，用户看到的是黑屏而不是「需要转码」。
   */
  capability(): ClientCapabilityIn {
    return MovieClawPlaybackGateway.capability('avplayer');
  }

  async negotiate(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (this.disposed) { return; }
    const epoch = ++this.sessionEpoch;
    await this.releasePlayer();
    if (epoch !== this.sessionEpoch || this.disposed) { return; }
    this.stopSession();
    this.phase = PlayerPhase.negotiating;
    // 换集 / 重开时清掉上一集的连播状态（同 iOS startUnit 的重置块）
    this.ended = false;
    this.nextDismissed = false;
    this.autoNextCancelled = false;
    this.autoNextProgress = 0;
    this.clipEnded = false;
    // 画质：片段固定 1080（iOS PlaybackClip.maxHeight），正片按条目回读本机记忆
    if (this.isClip()) {
      this.maxHeight = 1080;
    } else {
      this.maxHeight = await PlayerPrefs.quality(this.mediaItemId, this.seasonNumber, this.episodeNumber);
    }
    // 本机有下完的副本就直接放本机（对应 iOS startLocal：不建服务端会话，
    // 在线离线都优先本机，进度记 OfflineViewingRecorder 先落盘再补传）；
    // 片段播放不走本机（刷片是在线流，且时间轴只算这一段）
    if (epoch !== this.sessionEpoch || this.disposed) { return; }
    if (this.shareSlug.length === 0 && !this.isClip() && !this.localFailedOnce) {
      try { if (await this.tryStartLocal(epoch)) { return; } }
      catch (error) {
        if (epoch !== this.sessionEpoch || this.disposed) { return; }
        this.stopSession(); this.localFailedOnce = true;
      }
    }
    if (epoch !== this.sessionEpoch || this.disposed) { return; }
    if (api === null) { this.phase = PlayerPhase.failed; this.errorMessage = '没有可播放的本机副本，也未连接服务器'; return; }
    try {
      const body: SessionRequest = new SessionRequest();
      body.media_item_id = this.mediaItemId;
      body.file_id = this.fileId > 0 ? this.fileId : null;
      /*
       * 季集必须给**数字**：后端的 schema 是 `season_number: int = 0`（不可空），
       * 传 null 会 422。这里曾经传 null，被后端拒了之后只回一句笼统的
       * 「request validation failed」，查了两轮才从原始响应体里看出是这两项。
       */
      body.season_number = this.seasonNumber > 0 ? this.seasonNumber : 0;
      body.episode_number = this.episodeNumber > 0 ? this.episodeNumber : 0;
      body.capability = this.capability();
      body.start_ms = this.resumeExplicit || this.startMs > 0 ? this.startMs : null;
      body.client = 'harmony';
      // 选了非默认音轨要把 ref 带回去：后端会重新判定档位（选轨可能把直出顶成重封装）
      body.audio_track = this.audioRef.length > 0 ? this.audioRef : null;
      body.subtitle_track = this.subtitleRef.length > 0 ? this.subtitleRef : null;
      // 画质上限：语义是上限而非目标——源不超所选档就照常直通，超了才转码降下去
      body.max_height = this.maxHeight > 0 ? this.maxHeight : null;
      // 传**空数组**而不是 null：后端是 `failed_tiers: list[int] = []`（不可空）。
      // 这已经是同一类错误的第二次（上一次是 season_number 传 null）——
      // **后端的默认值不可空时，客户端一律不能送 null**。
      body.failed_tiers = this.failedTiers;
      const gateway = new MovieClawPlaybackGateway(api, this.shareSlug);
      await PlayerPrefs.loadEngine();
      const view = await gateway.open(body, PlayerPrefs.engine());
      if (epoch !== this.sessionEpoch || this.disposed) { await gateway.stop(view); return; }
      this.session = view;
      PlaybackTestProbe.record('session', `tier=${view.decision.tier};file=${view.decision.file_id}`);
      PlaybackTestProbe.record('delivery', JSON.stringify({ tier: view.decision.tier,
        audio: view.decision.audio, video: view.decision.video }));
      if (this.audioRef.length === 0) { this.audioRef = view.watch?.audio_track || view.decision.audio?.track_ref || ''; }
      if (this.subtitleRef.length === 0) { this.subtitleRef = view.watch?.subtitle_track ?? ''; }
      this.subtitleIndex = view.decision.subtitles.findIndex((track: SubtitlePlanView): boolean =>
        track.track_ref === this.subtitleRef);
      // 服务端说这片要开软件转码：给同意弹窗（iOS handleSession 的 consent 分支），
      // 用户开了开关再重新协商
      if (view.decision.outcome === 'consent') {
        this.phase = PlayerPhase.consent;
        return;
      }
      const url: string | null = view.stream_url ?? null;
      if (url === null || url.length === 0) {
        gateway.stop(view).catch((): void => {});
        this.phase = PlayerPhase.failed;
        // 服务端说不能放时，把它的理由原样给用户——比「播放失败」有用得多
        this.errorMessage = view.decision.reason.length > 0
          ? view.decision.reason
          : '服务端没有给出可播放的地址';
        this.errorSuggestion = view.decision.suggestion ?? '';
        return;
      }
      this.phase = PlayerPhase.ready;
      this.sessionCoordinator.bind(new MovieClawPlaybackSession(api, view,
        new PlayerParams(this.mediaItemId, view.decision.file_id ?? 0, this.seasonNumber,
          this.episodeNumber, view.start_ms, this.shareSlug, this.clipStartMs, this.clipEndMs),
        (): string => this.audioRef, (): string => this.subtitleRef));
      this.loadItemInfo();
      this.loadEpisodes();
      this.loadTrickplay();
      this.startAutoNextClock();
      await this.attachPlayer(url);
    } catch (error) {
      if (epoch !== this.sessionEpoch || this.disposed) { return; }
      this.phase = PlayerPhase.failed;
      this.errorMessage = this.messageOf(error);
      this.errorSuggestion = '';
    }
  }

  messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '播放失败';
  }

  // MARK: 本机副本（离线下载的播放路径，对应 iOS tryStartLocal / startLocal）

  /**
   * 有下完的本机副本就放本机（在线离线都优先本机，不建服务端会话）。
   * 副本 / playback.json / 媒体文件缺一样都算没有，回退流式。
   */
  async tryStartLocal(epoch: number): Promise<boolean> {
    const store: OfflineStore = OfflineStore.shared;
    if (!this.awaitedOfflineStore) {
      this.awaitedOfflineStore = true;
      await store.waitUntilLoaded();
    }
    if (epoch !== this.sessionEpoch || this.disposed) { return false; }
    const unit: OfflineUnit | null = store.playableUnit(this.mediaItemId,
      this.seasonNumber, this.episodeNumber);
    if (unit === null) {
      return false;
    }
    const media: string | null = store.mediaPath(unit);
    if (media === null || OfflineDisk.fileSize(media) <= 0) {
      return false;
    }
    const spec: OfflinePlaybackSpec | null = store.spec(unit);
    if (spec === null) {
      return false;
    }
    // 续播点：能连上服务端就以它为准（一家人共用一份观看记录），2 秒拿不到用本机的
    const resumeMs: number = await this.localResumeMs(store, unit);
    if (epoch !== this.sessionEpoch || this.disposed) { return false; }
    this.localMediaPath = media;
    this.localUnit = unit;
    this.localSpec = spec;
    this.session = this.localSessionView(spec, resumeMs);
    this.viewingRecorder = new OfflineViewingRecorder(unit, resumeMs,
      spec.durationMs ?? null, this.api());
    this.phase = PlayerPhase.ready;
    this.loadItemInfo();
    this.loadEpisodes();
    this.startAutoNextClock();
    this.pendingSeekMs = resumeMs > 0 ? resumeMs : -1;
    await this.attachLocalPlayer();
    return true;
  }

  /**
   * 本机续播点：详情页带进来的位置最准；否则问服务端（2 秒竞速，离线不干等），
   * 再退到本机 progress.json 里记的（对应 iOS resume 的服务端优先 + 超时回落）。
   */
  async localResumeMs(store: OfflineStore, unit: OfflineUnit): Promise<number> {
    if (this.startMs > 0) {
      return this.startMs;
    }
    const api: MovieClawApi | null = this.api();
    if (api !== null) {
      const state: PlaybackStateView | null = await this.raceResume(
        api.playbackResume(this.mediaItemId, unit.season > 0 ? unit.season : undefined,
          unit.episode > 0 ? unit.episode : undefined));
      if (state !== null) {
        return state.played ? 0 : (state.position_ms ?? 0);
      }
    }
    const progress: OfflineProgress | null = store.localProgress(this.mediaItemId,
      unit.season, unit.episode);
    if (progress !== null && !progress.played) {
      return progress.positionMs;
    }
    return 0;
  }

  /** 问服务端要 2 秒：到点没回来就当没有（离线时起播不能被网络拖住） */
  raceResume(promise: Promise<PlaybackStateView>): Promise<PlaybackStateView | null> {
    return new Promise<PlaybackStateView | null>(
      (resolve: (value: PlaybackStateView | null) => void) => {
        let settled: boolean = false;
        const timer: number = setTimeout((): void => {
          settled = true;
          resolve(null);
        }, 2000);
        promise.then((state: PlaybackStateView): void => {
          if (!settled) {
            settled = true;
            clearTimeout(timer);
            resolve(state);
          }
        }).catch((): void => {
          if (!settled) {
            settled = true;
            clearTimeout(timer);
            resolve(null);
          }
        });
      });
  }

  /**
   * 本机会话视图：结构与流式一致，界面（章节 / 音轨 / 字幕 / 档位）不用分叉。
   * 决策定成 plan + tier 0（同 iOS：本机副本不参与服务端档位体系）。
   */
  localSessionView(spec: OfflinePlaybackSpec, startMs: number): PlaybackSessionView {
    const subtitles: SubtitlePlanView[] = [];
    for (const sub of spec.subtitles) {
      const plan: SubtitlePlanView = {
        track_ref: sub.ref,
        kind: sub.kind,
        language: sub.language,
        is_default: sub.isDefault,
        is_ai: sub.isAi,
        title: sub.title,
        is_forced: sub.isForced
      };
      subtitles.push(plan);
    }
    const decision: PlaybackDecisionView = {
      outcome: 'plan',
      tier: 0,
      file_id: this.fileId,
      container: spec.container,
      audio_tracks: this.parseAudioTracks(spec.audioTracksJson),
      subtitles: subtitles,
      reason: '播放本机副本'
    };
    const view: PlaybackSessionView = {
      decision: decision,
      session_id: null,
      stream_url: null,
      progressive_segments: false,
      start_ms: startMs,
      timeline: 'file',
      subtitle_urls: [],
      chapters: this.parseChapters(spec.chaptersJson),
      segments: this.parseSegments(spec.segmentsJson)
    };
    return view;
  }

  parseAudioTracks(json: string): AudioTrackView[] {
    if (json.length === 0 || json === 'null') {
      return [];
    }
    const list: AudioTrackView[] = JSON.parse(json) as AudioTrackView[];
    return Array.isArray(list) ? list : [];
  }

  parseChapters(json: string): PlaybackChapterMarkView[] {
    if (json.length === 0 || json === 'null') {
      return [];
    }
    const list: PlaybackChapterMarkView[] = JSON.parse(json) as PlaybackChapterMarkView[];
    return Array.isArray(list) ? list : [];
  }

  parseSegments(json: string): PlaybackSegmentView[] | null {
    if (json.length === 0 || json === 'null') {
      return null;
    }
    const list: PlaybackSegmentView[] = JSON.parse(json) as PlaybackSegmentView[];
    return Array.isArray(list) ? list : null;
  }

  /** 关掉本机媒体 / 字幕句柄（换集、退出、回退服务端时；fdSrc 播放期间不能关） */

  // MARK: 播放器

  async inspectTracks(): Promise<string> { return JSON.stringify(await this.controller.tracks()); }

  engineLine(): string {
    const snapshot = this.controller.current();
    return snapshot.engine.length > 0 ? `播放引擎：${snapshot.engine} · ${snapshot.phase}` : '播放引擎：未启动';
  }

  surfaceReady(generation: number): void {
    if (generation !== this.surfaceGeneration || this.disposed) { return; }
    const surface = this.surfaceController.getXComponentSurfaceId();
    if (surface === this.surfaceId && this.controller.current().phase !== 'idle') { return; }
    this.surfaceId = surface;
    if (this.surfaceWaiter !== null) {
      const ready = this.surfaceWaiter; this.surfaceWaiter = null; ready(surface); return;
    }
    if (this.positionMs > 0) { this.pendingSeekMs = this.positionMs; }
    if (this.localSpec !== null) { this.attachLocalPlayer(); }
    else if (this.session?.stream_url) { this.attachPlayer(this.session.stream_url); }
  }
  surfaceDestroyed(generation: number): void {
    if (generation !== this.surfaceGeneration) { return; }
    if (this.pipActive) { return; }
    this.pendingSeekMs = this.positionMs;
    this.surfaceId = '';
    this.releasePlayer();
  }

  async attachPlayer(url: string): Promise<void> {
    if (this.surfaceId.length === 0 || this.disposed) { return; }
    const view = this.session;
    if (view === null) { return; }
    const origin = view.timeline === 'file' || view.decision.tier === 0 ? 0 : view.start_ms;
    const subtitleUrl = this.subtitleIndex >= 0 && this.subtitleIndex < view.subtitle_urls.length
      ? playbackUrl(AppModel.origin(), view.subtitle_urls[this.subtitleIndex]) : '';
    const intent = this.makeIntent();
    await this.controller.open(new PhoneMedia(origin, view.watch?.duration_ms ?? 0,
      PlaybackTestProbe.mediaUrl(playbackUrl(AppModel.origin(), url)), '', subtitleUrl, '',
      this.getUIContext().getHostContext()?.cacheDir ?? ''), this.surfaceId, intent, PlayerPrefs.engine());
  }

  async attachLocalPlayer(): Promise<void> {
    if (this.surfaceId.length === 0 || this.disposed || this.localSpec === null) { return; }
    let subtitlePath = '';
    if (this.subtitleIndex >= 0 && this.subtitleIndex < this.localSpec.subtitles.length) {
      const directory = this.localMediaPath.substring(0, this.localMediaPath.lastIndexOf('/'));
      subtitlePath = `${directory}/subs/${this.localSpec.subtitles[this.subtitleIndex].fileName}`;
    }
    await this.controller.open(new PhoneMedia(0, this.localSpec.durationMs ?? 0, '',
      this.localMediaPath, '', subtitlePath), this.surfaceId, this.makeIntent(), PlayerPrefs.engine());
  }

  makeIntent(): PlaybackIntent {
    const intent = new PlaybackIntent();
    intent.positionMs = this.pendingSeekMs >= 0 ? this.pendingSeekMs : (this.session?.start_ms ?? this.startMs);
    this.pendingSeekMs = -1;
    intent.paused = this.pausedIntent;
    intent.rate = this.holdSpeedActive ? 2 : this.playbackRate;
    intent.subtitlesOff = this.subtitleIndex < 0;
    if (this.subtitleIndex >= 0) { intent.subtitle = { language: '', title: '', ordinal: -1 }; }
    const tracks = this.session?.decision.audio_tracks ?? [];
    const index = tracks.findIndex((track: AudioTrackView): boolean => track.ref === this.audioRef);
    if (index >= 0 && (this.localSpec !== null || this.session?.decision.tier === 0)) {
      intent.audio = { language: tracks[index].language ?? '', title: '', ordinal: index, sourceCount: tracks.length };
    }
    return intent;
  }

  bindController(): void {
    this.controller.onSurfaceReset = async (): Promise<string> => {
      const pip = this.pip; this.pip = null;
      pip?.setAutoStartEnabled(false);
      if (this.pipActive && pip !== null) { await pip.stopPiP(); }
      if (this.disposed) { return ''; }
      this.surfaceId = '';
      this.surfaceController = new XComponentController();
      const ready = new Promise<string>((resolve): void => { this.surfaceWaiter = resolve; });
      this.surfaceGeneration++;
      return ready;
    };
    this.controller.onSeekOutsideWindow = (positionMs: number): void => {
      this.startMs = positionMs; this.resumeExplicit = true; this.negotiate();
    };
    this.sessionCoordinator.onHealth = (health: string): void => {
      if (this.disposed || this.reopening) { return; }
      if (health === 'endedByAdmin') {
        this.pause(); this.phase = PlayerPhase.failed; this.errorMessage = '管理员已结束本次播放';
        this.sessionCoordinator.close(); this.releasePlayer();
        return;
      }
      this.reopening = true;
      this.startMs = this.positionMs;
      if (health === 'failed' && this.failedTiers.length >= 5) {
        this.phase = PlayerPhase.failed; this.errorMessage = '服务器所有播放方案均失败';
        this.sessionCoordinator.close(); this.reopening = false; return;
      }
      if (health === 'failed') {
        const tier = this.session?.decision.tier ?? -1;
        if (tier >= 0 && !this.failedTiers.includes(tier)) { this.failedTiers.push(tier); }
      }
      this.releasePlayer().then(async (): Promise<void> => {
        this.stopSession(); await this.negotiate(); this.reopening = false;
      });
    };
    this.controller.onSnapshot = (snapshot: PlaybackSnapshot): void => {
      if (this.disposed) { return; }
      PlaybackTestProbe.observe(snapshot);
      this.engineOpening = snapshot.phase === 'opening';
      const previousPlaying = this.playing;
      this.playing = snapshot.playing;
      this.durationMs = snapshot.durationMs;
      if (Math.floor(snapshot.positionMs / 500) !== this.timeBucket) {
        this.positionMs = snapshot.positionMs;
        this.timeBucket = Math.floor(snapshot.positionMs / 500);
      }
      this.viewingRecorder?.tick(snapshot.positionMs, snapshot.playing, snapshot.durationMs);
      this.sessionCoordinator.update(snapshot.positionMs, snapshot.durationMs, snapshot.playing);
      if (snapshot.phase === 'ended') {
        this.ended = true;
        this.viewingRecorder?.finish(snapshot.positionMs, true);
      }
      if (snapshot.playing && !previousPlaying) {
        this.ended = false;

        this.keepScreenOn();

        this.armChromeTimer();
        this.ensureGuard().then((guard: PlaybackGuard): Promise<void> =>
          this.playing && !this.disposed ? guard.start(this.title || '播放') : Promise.resolve())
          .catch((): void => {});
        this.enableAutoPip();
      } else if (!snapshot.playing && previousPlaying) {
        this.armChromeTimer();
        if (!this.clipEnded) { this.chromeVisible = true; }
        this.guard?.pause().catch((): void => {});
        this.allowScreenOff();
      }
      this.guard?.updatePlayback(this.title, snapshot.durationMs, snapshot.positionMs, snapshot.playing, snapshot.rate);
      if (this.isClip() && !this.clipEnded && snapshot.positionMs >= this.clipEndMs) {
        this.clipEnded = true; this.chromeVisible = false;
        this.pause(); this.disarmHoldTimer();
      }
    };
    this.controller.onEvent = (event: EngineEvent): void => {
      if (event.type === 'fallback' && event.failure !== null) {
        PlaybackTestProbe.record('fallback', `${event.failure.kind}:${event.failure.code}`);
      }
      if (event.type === 'diagnostic') { PlaybackTestProbe.record('diagnostic', event.text); }
      if (event.type === 'buffered') { PlaybackTestProbe.record('buffered', `${event.bufferedMs}`); }
      if (event.type === 'firstFrame' || event.type === 'buffering') { PlaybackTestProbe.record(event.type, event.hint); }
      if (event.type === 'size' && event.width > 0 && event.height > 0) { this.videoAspect = event.width / event.height; }
      else if (event.type === 'subtitle') { this.subtitleCue = event.text; }
    };
    this.controller.onFailure = (failure: EngineFailure): void => {
      PlaybackTestProbe.record('failure', `${failure.kind}:${failure.code}`);
      if (failure.canFallback() || (this.localUnit !== null && failure.kind === 'source')) { this.onPlaybackFailed(failure.message); }
      else { this.phase = PlayerPhase.failed; this.errorMessage = failure.message; this.sessionCoordinator.close(); }
    };
  }

  play(): void { this.claimPlayback(); this.pausedIntent = false; this.controller.play(); }
  claimPlayback(): void {
    PlaybackOwnership.claim(this, (): void => { this.pause(); });
  }
  pause(): void { this.pausedIntent = true; this.controller.pause(); }

  onPlaybackFailed(reason: string): void {
    if (this.localFallingBack) {
      return;
    }
    if (this.localUnit !== null) {
      this.localFallingBack = true;
      this.localFailedOnce = true;
      this.startMs = this.positionMs;
      this.toast('本机副本播放失败，正在改用服务器…');
      this.releasePlayer().then((): void => {
        this.stopSession();
        this.localFallingBack = false;
        this.negotiate();
      });
      return;
    }
    const view: PlaybackSessionView | null = this.session;
    const tier: number = view !== null ? (view.decision.tier ?? -1) : -1;
    hilog.error(0x0000, 'PlayerPage', 'tier=%{public}d retryCount=%{public}d failedTiers=%{public}s',
      tier, this.retryCount, this.failedTiers.toString());
    if (!this.failedTiers.includes(tier)) { this.failedTiers.push(tier); }
    this.startMs = this.positionMs;
    if (tier < 0 || this.retryCount >= 4) {
      this.phase = PlayerPhase.failed;
      this.errorMessage = reason;
      this.sessionCoordinator.close();
      const suggestion: string | null = view !== null ? (view.decision.suggestion ?? null) : null;
      this.errorSuggestion = suggestion !== null && suggestion.length > 0
        ? suggestion : '可以点「重试」再试一次；反复出现请打开「详情」查看诊断';
      return;
    }
    this.retryCount++;
    this.toast(`第 ${tier} 档放不了，正在换一档…`);
    this.releasePlayer().then((): void => {
      this.stopSession();
      this.negotiate();
    });
  }

  async releasePlayer(): Promise<void> {
    await this.controller.release();
  }

  togglePlay(): void {
    PlaybackTestProbe.record('toggle', this.playing ? 'pause' : 'play');
    this.noteUserActivity();
    if (this.playing) { this.pause(); } else { this.play(); }
  }

  seekTo(ms: number): void {
    this.noteUserActivity();
    let target = Math.max(0, this.durationMs > 0 ? Math.min(this.durationMs, ms) : ms);
    if (this.isClip()) { target = Math.max(this.clipStartMs, Math.min(this.clipEndMs, target)); }
    this.controller.seek(target);
    this.positionMs = target; this.timeBucket = Math.floor(target / 500);
  }

  /** 片段播放（刷片页「全屏观看」）：时间轴只算这一段，不报观看进度、不给画中画与「即将播放」 */
  isClip(): boolean {
    return this.clipEndMs > this.clipStartMs;
  }

  // MARK: 下一集 / 自动连播（对应 iOS PlaybackController 的 upNext 一节）

  /** 片名（详情接口给的）：顶栏、锁屏与后台播控都用它 */
  loadItemInfo(): void {
    const epoch = this.sessionEpoch;
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    const request: Promise<PlaybackItemView> = this.shareSlug.length > 0
      ? api.sharePlaybackItem(this.mediaItemId, this.shareSlug)
      : api.playbackItemInfo(this.mediaItemId);
    request.then((view: PlaybackItemView): void => {
      if (epoch !== this.sessionEpoch || this.disposed) { return; }
      this.title = view.title;
    }).catch((): void => {
      // 拿不到（离线放本机副本时）用本机存的条目名顶上；再没有就保持「播放」
      const local: LibraryItemDetailView | null = OfflineStore.shared.detail(this.mediaItemId);
      if (local !== null) {
        this.title = local.title;
      }
    });
  }

  /** 本季分集（自动连播 / 下一集卡片用；电影没有季集就不拉；片段播放不需要） */
  loadEpisodes(): void {
    const epoch = this.sessionEpoch;
    if (this.isClip() || this.seasonNumber <= 0 || this.episodeNumber <= 0) {
      this.episodes = [];
      return;
    }
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    const request: Promise<SeasonEpisodesView> = this.shareSlug.length > 0
      ? api.sharePlaybackItemEpisodes(this.mediaItemId, this.shareSlug, this.seasonNumber)
      : api.playbackItemEpisodes(this.mediaItemId, this.seasonNumber);
    request.then((view: SeasonEpisodesView): void => {
      if (epoch !== this.sessionEpoch || this.disposed) { return; }
      this.episodes = view.episodes;
    }).catch((): void => {
      this.episodes = [];
    });
  }

  /** 下一集只在**本季且有在位文件**里找——缺集跳过（同 Web player-page） */
  nextEpisode(): EpisodeView | null {
    let best: EpisodeView | null = null;
    for (const episode of this.episodes) {
      if (episode.owned && episode.episode_number > this.episodeNumber
        && (best === null || episode.episode_number < best.episode_number)) {
        best = episode;
      }
    }
    return best;
  }

  segments(): PlaybackSegmentView[] | null {
    const view: PlaybackSessionView | null = this.session;
    return view !== null ? (view.segments ?? null) : null;
  }

  /** 「即将播放」卡片：服务端认出了一直放到结尾的片尾时进了片尾就给，没认出就等播完再给 */
  showsUpNext(): boolean {
    if (this.isClip()) {
      return false;
    }
    if (this.nextEpisode() === null || this.nextDismissed) {
      return false;
    }
    return SkipSegments.shouldShowUpNext(this.segments(), this.positionMs, this.ended);
  }

  /** 卡片要不要倒计时自动播下一集（连播满上限不倒计时，只提示） */
  autoNextArmed(): boolean {
    return this.showsUpNext() && !this.autoNextCancelled
      && SkipSegments.autoNextArmed(this.segments(), this.positionMs, this.autoNextStreak, this.ended);
  }

  /** 连播满上限后放完了：不自动接，问一句「还在看吗」 */
  asksStillWatching(): boolean {
    return this.ended && this.nextEpisode() !== null
      && this.autoNextStreak >= SkipSegments.autoNextMaxStreak;
  }

  /** 有人在操作：不算「没人管的连播」，连播计数清零 */
  noteUserActivity(): void {
    this.autoNextStreak = 0;
  }

  /** 倒计时的钟：10Hz；暂停时不走、播完照走（片尾短于倒计时时不能卡在最后一帧） */
  startAutoNextClock(): void {
    if (this.autoNextTimer >= 0) {
      return;
    }
    this.autoNextTimer = setInterval((): void => {
      if (!this.autoNextArmed()) {
        this.autoNextProgress = 0;
        return;
      }
      if (!this.playing && !this.ended) {
        return;
      }
      this.autoNextProgress = Math.min(1,
        this.autoNextProgress + 100 / SkipSegments.autoNextMs);
      if (this.autoNextProgress < 1) {
        return;
      }
      this.autoNextProgress = 0;
      this.autoNextStreak += 1;
      this.playNext();
    }, 100);
  }

  stopAutoNextClock(): void {
    if (this.autoNextTimer >= 0) {
      clearInterval(this.autoNextTimer);
      this.autoNextTimer = -1;
    }
  }

  /** 换到下一集：重开会话（续播点由服务端按观看记录给），连播状态在 negotiate 里重置 */
  playNext(): void {
    const next: EpisodeView | null = this.nextEpisode();
    if (next === null || this.reopening) {
      return;
    }
    this.reopening = true;
    this.autoNextCancelled = true;
    // 离开当前单元：给旧集补发 stop（位置还是旧集的，要先于换集发）
    this.releasePlayer().then(async (): Promise<void> => {
      this.stopSession();
      if (this.disposed) { return; }
      this.pausedIntent = false; this.subtitleIndex = -1; this.subtitleRef = ''; this.audioRef = '';
      this.positionMs = 0;
      this.episodeNumber = next.episode_number;
      this.resumeExplicit = false;
      // 换集不指定文件：让服务端自己挑这集的在位文件（同 iOS startUnit）
      this.fileId = 0;
      this.startMs = 0;
      this.failedTiers = [];
      this.retryCount = 0;
      // 新的一集重新允许试本机副本（上一集的失败不作数）
      this.localFailedOnce = false;
      this.localFallingBack = false;
      await this.negotiate();
      this.reopening = false;
    }).catch((): void => { this.reopening = false; });
  }

  /** 卡片眉标：倒计时剩余秒数 / 「还在看吗」 */
  upNextEyebrow(): string {
    if (this.asksStillWatching()) {
      return '还在看吗？';
    }
    if (!this.autoNextArmed()) {
      return '即将播放';
    }
    const left: number = SkipSegments.autoNextMs * (1 - this.autoNextProgress) / 1000;
    return `即将播放 · ${Math.max(1, Math.ceil(left))} 秒`;
  }

  /** 下一集剧照（本地缩略图或 TMDB 图床，相对路径 → 可请求的 URL） */
  upNextStillUrl(): string {
    const next: EpisodeView | null = this.nextEpisode();
    const raw: string | null = next !== null ? (next.still_url ?? null) : null;
    const resolved: string | null = raw !== null
      ? ImageUrls.resolve(AppModel.origin(), raw, null) : null;
    return resolved !== null ? resolved : '';
  }

  /** 卡片第二行：第几集 */
  upNextCode(): string {
    const next: EpisodeView | null = this.nextEpisode();
    return next !== null ? `第 ${next.episode_number} 集` : '';
  }

  /** 卡片第三行：集名（最多两行；没有就不占位） */
  upNextName(): string {
    const next: EpisodeView | null = this.nextEpisode();
    return next !== null ? (next.name ?? '') : '';
  }

  /** 横屏（高度紧）：卡片收窄、不放剧照（同 iOS compact） */
  isLandscape(): boolean {
    return this.layerWidth > this.layerHeight;
  }

  /** 「立即播放」按钮里倒计时白条的填充百分比 */
  upNextFillPercent(): number {
    if (!this.autoNextArmed()) {
      return 100;
    }
    return Math.round(this.autoNextProgress * 1000) / 10;
  }

  // MARK: 进度条缩略图（对应 iOS loadTrickplay）

  /** 从已签名的取流地址里取 token（缩略图索引 / 雪碧图复用同一份授权） */
  streamToken(): string {
    const view: PlaybackSessionView | null = this.session;
    const url: string = view !== null ? (view.stream_url ?? '') : '';
    const at: number = url.indexOf('?');
    if (at < 0) {
      return '';
    }
    const pairs: string[] = url.substring(at + 1).split('&');
    for (const pair of pairs) {
      if (pair.startsWith('token=')) {
        return decodeURIComponent(pair.substring('token='.length));
      }
    }
    return '';
  }

  /**
   * 缩略图索引：开会话时服务端才在后台生成，没就绪就隔一阵再问
   * （同 iOS loadTrickplay：最多 6 次、间隔 30 秒，失败无所谓）。
   */
  loadTrickplay(): void {
    const api: MovieClawApi | null = this.api();
    const view: PlaybackSessionView | null = this.session;
    const fileId: number = view !== null ? (view.decision.file_id ?? 0) : 0;
    const token: string = this.streamToken();
    this.trickplayGen++;
    const gen: number = this.trickplayGen;
    this.trickplay.setIndex(null);
    if (api === null || fileId <= 0 || token.length === 0) {
      return;
    }
    const poll: (attempt: number) => void = (attempt: number): void => {
      if (gen !== this.trickplayGen || attempt >= 6) {
        return;
      }
      api.playbackFileTrickplay(fileId, token).then((index: TrickplayView): void => {
        if (gen !== this.trickplayGen) {
          return;
        }
        if (index.ready) {
          this.trickplay.setIndex(index);
          this.trickplayVersion++;
        } else {
          setTimeout((): void => {
            poll(attempt + 1);
          }, 30000);
        }
      }).catch((): void => {
        setTimeout((): void => {
          poll(attempt + 1);
        }, 30000);
      });
    };
    poll(0);
  }

  /** 横滑落点该显示的缩略图格子（雪碧图还没下完返回 null） */
  scrubTile(): image.PixelMap | null {
    if (this.scrubMs < 0) {
      return null;
    }
    return this.trickplay.tileAt(this.scrubMs, AppModel.origin());
  }

  // MARK: 进度上报

  /** 每 10 秒报一次进度（对应 iOS 的进度上报；后端据此算「继续观看」） */
  /** 起播看门狗：25 秒还没出画就判这一档失败，走降档回路 */

  /** 懒建合规壳；播放/暂停命令回灌给播放器（锁屏与通知栏的按钮要能用） */
  async ensureGuard(): Promise<PlaybackGuard> {
    if (this.guard !== null) { return this.guard; }
    this.guard = new PlaybackGuard(this.getUIContext().getHostContext() as common.UIAbilityContext,
      (): void => { if (!this.clipEnded) { this.play(); } }, (): void => this.pause(),
      (position: number): void => this.seekTo(position));
    return this.guard;
  }

  /**
   * 画中画（§5.5 三个合规点的最后一个）。
   *
   * 视频面从一开始就按 `XComponent(type: SURFACE)` 做，就是为了这一步——
   * `PiPWindow` 要求 surface 可迁移，用 `Video` 组件或默认 surface 到这儿就得推倒重来。
   *
   * 两种进入方式都接上：
   * - **自动**：`setAutoStartEnabled(true)`，用户按 Home / 上滑回桌面时自动缩成小窗（同 iOS）；
   * - **手动**：控制条上的「画中画」按钮。
   */
  async enableAutoPip(): Promise<void> {
    // 片段播放不给画中画（iOS pictureInPictureAvailable 的 clip == nil）
    if (this.isClip()) {
      return;
    }
    const controller: PiPWindow.PiPController | null = await this.ensurePip();
    if (controller !== null) {
      controller.setAutoStartEnabled(true);
    }
  }

  async ensurePip(): Promise<PiPWindow.PiPController | null> {
    const existing: PiPWindow.PiPController | null = this.pip;
    if (existing !== null) {
      return existing;
    }
    if (!PiPWindow.isPiPEnabled()) {
      // 这台设备不支持（部分设备 / 未开启），别硬来
      return null;
    }
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const controller: PiPWindow.PiPController = await PiPWindow.create({
        context: context,
        componentController: this.surfaceController,
        templateType: PiPWindow.PiPTemplateType.VIDEO_PLAY
      });
      controller.on('stateChange', (state: PiPWindow.PiPState, reason: string): void => {
        this.pipActive = state === PiPWindow.PiPState.STARTED;
        if (state === PiPWindow.PiPState.STOPPED) {
          // 小窗关掉：如果还在播，把自动进小窗关掉，免得用户回桌面又被缩进去出不来
          controller.setAutoStartEnabled(false);
          if (this.detached) { this.aboutToDisappear(); }
        }
      });
      this.pip = controller;
      return controller;
    } catch (error) {
      const e = error as BusinessError;
      hilog.error(0x0000, 'PlayerPage', 'createPiP failed code=%{public}d msg=%{public}s',
        e.code ?? -1, e.message ?? '');
      return null;
    }
  }

  async togglePip(): Promise<void> {
    const controller: PiPWindow.PiPController | null = await this.ensurePip();
    if (controller === null) {
      this.toast('这台设备不支持画中画');
      return;
    }
    try {
      if (this.pipActive) {
        await controller.stopPiP();
      } else {
        await controller.startPiP();
      }
    } catch (error) {
      const e = error as BusinessError;
      this.toast(`画中画切换失败（${e.code ?? -1}）`);
    }
  }

  /**
   * 字幕轨切换。
   *
   * 后端把 `subtitle_urls` 与 `decision.subtitles` **按同一序**生成（`for s in view.subtitles`），
   * 所以两边用**同一个下标**就能对上，不需要再拿 track_ref 去匹配。
   *
   * 外挂字幕要走两步——`addSubtitleFromUrl` 只是**加载**，加载完还要用
   * `getTrackDescription()` 拿到它的 track index，再 `selectTrack` 才是**选中**。
   * 关字幕用 `deselectTrack`。
   */
  async pickSubtitle(index: number): Promise<void> {
    this.showSheet = false;
    const view = this.session;
    if (view === null) { return; }
    if (index >= view.decision.subtitles.length) { return; }
    this.subtitleIndex = index; this.subtitleRef = index < 0 ? 'off' : view.decision.subtitles[index].track_ref;
    this.subtitleCue = '';
    this.pendingSeekMs = this.positionMs;
    if (this.localSpec !== null) { await this.attachLocalPlayer(); }
    else if (view.stream_url) { await this.attachPlayer(view.stream_url); }
  }

  async pickAudio(ref: string): Promise<void> {
    this.showSheet = false;
    if (ref === this.audioRef) { return; }
    this.audioRef = ref;
    const view = this.session;
    const tracks = view?.decision.audio_tracks ?? [];
    const index = tracks.findIndex((track: AudioTrackView): boolean => track.ref === ref);
    if (index >= 0 && (this.localSpec !== null || view?.decision.tier === 0)) {
      await this.controller.selectTrack('audio', { language: tracks[index].language ?? '', title: '', ordinal: index, sourceCount: tracks.length });
      return;
    }
    this.startMs = this.positionMs;
    this.failedTiers = []; this.retryCount = 0;
    await this.releasePlayer(); this.stopSession(); await this.negotiate();
  }

  /** 音轨行的标题：语言 + 编码 + 声道 + 是否默认 */
  audioLabel(track: AudioTrackView, index: number): string {
    const lang: string | null = track.language ?? null;
    const head: string = lang !== null && lang.length > 0 ? lang : `音轨 ${index + 1}`;
    const tags: string[] = [];
    const codec: string | null = track.codec ?? null;
    if (codec !== null && codec.length > 0) {
      tags.push(codec);
    }
    const channels: number | null = track.channels ?? null;
    if (channels !== null && channels > 0) {
      tags.push(`${channels} 声道`);
    }
    if (track.is_default) {
      tags.push('默认');
    }
    return tags.length === 0 ? head : `${head}  ·  ${tags.join(' · ')}`;
  }

  currentAudioLabel(): string {
    const view: PlaybackSessionView | null = this.session;
    if (view === null) {
      return '音轨';
    }
    const tracks: AudioTrackView[] = view.decision.audio_tracks;
    for (const track of tracks) {
      if (track.ref === this.audioRef) {
        return this.audioLabel(track, tracks.indexOf(track));
      }
    }
    return '音轨';
  }

  /** 章节行的标题：标题 + 起止时间 */
  chapterLabel(mark: PlaybackChapterMarkView): string {
    const title: string | null = mark.title ?? null;
    return title !== null && title.length > 0 ? title : this.clockText(mark.start_ms);
  }

  /** 字幕行的标题：语言 + 类型 + 是否 AI/默认 */
  subtitleLabel(plan: SubtitlePlanView, index: number): string {
    const lang: string | null = plan.language ?? null;
    const head: string = lang !== null && lang.length > 0 ? lang : `字幕 ${index + 1}`;
    const tags: string[] = [];
    if (plan.kind.length > 0) {
      tags.push(plan.kind);
    }
    if (plan.is_ai) {
      tags.push('AI 翻译');
    }
    if (plan.is_default) {
      tags.push('默认');
    }
    return tags.length === 0 ? head : `${head}  ·  ${tags.join(' · ')}`;
  }

  /** 当前章节名（最后一个 start_ms <= 当前位置的） */
  currentChapter(): string | null {
    const view: PlaybackSessionView | null = this.session;
    if (view === null) {
      return null;
    }
    let title: string | null = null;
    for (const mark of view.chapters) {
      if (mark.start_ms <= this.positionMs) {
        const t: string | null = mark.title ?? null;
        if (t !== null && t.length > 0) {
          title = t;
        }
      }
    }
    return title;
  }

  /** 时间 + 当前章节（iOS 的 `clock · chapter`） */
  clockWithChapter(): string {
    const clock: string = this.clockText(this.displayPositionMs());
    const chapter: string | null = this.currentChapter();
    return chapter !== null ? `${clock} · ${chapter}` : clock;
  }

  /** 当前位置落在哪一段可跳过区间里（没有就是 null）。放到结尾的片尾不进这里（交给「即将播放」卡片） */
  currentSegment(): PlaybackSegmentView | null {
    return SkipSegments.active(this.segments(), this.positionMs);
  }

  /** 按钮文案照后端的语义：片头 / 片尾 / 其他重复段 */
  segmentLabel(segment: PlaybackSegmentView): string {
    if (segment.type === 'intro') {
      return '跳过片头';
    }
    if (segment.type === 'outro') {
      return '跳过片尾';
    }
    return '跳过';
  }

  /** 播放中 4 秒无操作自动收起控制条（同 iOS chrome 自动隐藏）；用户一动手就重置 */
  armChromeTimer(): void {
    if (this.chromeTimer >= 0) {
      clearTimeout(this.chromeTimer);
      this.chromeTimer = -1;
    }
    if (!this.playing || this.chromeMustStayVisible()) { return; }
    this.chromeTimer = setTimeout((): void => {
      this.chromeTimer = -1;
      if (!this.chromeMustStayVisible()) { this.chromeVisible = false; }
    }, 4000);
  }

  /** 控制条必须常显（同 Web chromeMustStayVisible）：用户暂停在找播放键、弹层开着在等选择 */
  chromeMustStayVisible(): boolean {
    return (!this.playing && this.phase === PlayerPhase.ready) || this.showSheet;
  }

  // MARK: 手势层（对应 iOS PlayerGestureLayer）

  /** 长按 2 倍速能不能起：暂停时不行（松手按轻点处理） */
  canHoldSpeed(): boolean {
    return this.playing && this.phase === PlayerPhase.ready;
  }

  beginHoldSpeed(): boolean {
    if (!this.canHoldSpeed()) { return false; }
    this.holdSpeedActive = true; this.controller.setRate(2); return true;
  }

  endHoldSpeed(): void {
    if (!this.holdSpeedActive) { return; }
    this.holdSpeedActive = false; this.controller.setRate(this.playbackRate);
  }

  disarmHoldTimer(): void {
    if (this.holdTimer >= 0) {
      clearTimeout(this.holdTimer);
      this.holdTimer = -1;
    }
  }

  disarmAdjustHide(): void {
    if (this.adjustHideTimer >= 0) {
      clearTimeout(this.adjustHideTimer);
      this.adjustHideTimer = -1;
    }
  }

  vpOf(len: Length): number {
    if (typeof len === 'number') {
      return len;
    }
    if (typeof len === 'string' && len.length > 0) {
      return Number(len);
    }
    return 0;
  }

  /**
   * 手势状态机（照 iOS `GestureView` 移植）：
   * 移动不到 12vp 抬起 = 轻点（含双击改判）；横向为主 = 拖进度；纵向为主 = 左亮右音；
   * 按住 500ms 不动 = 2 倍速。上下边缘 32vp 起手不算（留给系统手势）。
   */
  onGesture(event: TouchEvent): void {
    const touch: TouchObject | undefined = event.changedTouches[0];
    if (touch === undefined) {
      return;
    }
    /*
     * 片段播完卡在「这一段看完了」上：手势全锁，只留卡上的「重播 / 看全片」和
     * 系统返回。不锁的话双击还能把播放唤起来越过片段终点继续播、轻点还能把
     * 控制层叫出来。Up/Cancel 仍要放行收尾——正在拖动/长按的触摸正好碰上片段
     * 到点，跟踪态得正常复位（倍速收掉、进度条浮层收掉），否则 gestureTracking
     * 卡死，重播之后整个手势层全废。
     */
    if (this.controlsLocked || this.showSheet) { return; }
    if (this.clipEnded) {
      if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.disarmHoldTimer();
        if (this.gestureTracking) {
          this.gestureTracking = false;
          if (this.gestureIntent === 'hold') {
            this.endHoldSpeed();
          } else if (this.gestureIntent === 'barDrag') {
            this.barDragging = false;
            this.scrubMs = -1;
          } else if (this.gestureIntent === 'scrub') {
            this.scrubEnded(true);
          } else if (this.gestureIntent === 'adjust') {
            this.adjustEnded();
          }
          this.gestureIntent = 'undecided';
        }
      }
      return;
    }
    if (event.type === TouchType.Down) {
      // 已有一根手指在跟踪：第二根不认领（同 iOS isMultipleTouchEnabled = false）
      if (this.gestureTracking) {
        return;
      }
      /*
       * `layerHeight` 要等首次布局才有值；拿 0 当高度会让底缘守卫吞掉所有触摸。
       * 没量出来时只守上缘，量出来后照 iOS 的双侧 32vp 守卫。
       */
      if (touch.y <= PhonePlaybackHost.edgeGuard) {
        if (!this.chromeVisible) {
          return;
        }
      }
      if (this.layerHeight > 0 && touch.y >= this.layerHeight - PhonePlaybackHost.edgeGuard) {
        if (!this.chromeVisible) {
          return;
        }
      }
      const chromeHit: boolean = this.inChromeExclusion(touch.x, touch.y);
      if (this.chromeVisible && chromeHit) {
        this.gestureTracking = true;
        this.gestureTouchId = touch.id;
        this.gestureStartX = touch.x;
        this.gestureStartY = touch.y;
        if (this.inBand(touch.y, this.barY) && this.displayDurationMs() > 0) {
          this.gestureIntent = 'barDrag';
          this.noteUserActivity();
          this.barDragging = true;
          this.scrubBaseMs = this.positionMs;
          this.barScrubTo(touch.x);
        } else {
          this.gestureIntent = 'chromeTap';
        }
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
        }, PhonePlaybackHost.holdDelay);
      }
      return;
    }
    if (event.type === TouchType.Move) {
      if (!this.gestureTracking || touch.id !== this.gestureTouchId) {
        return;
      }
      const dx: number = touch.x - this.gestureStartX;
      const dy: number = touch.y - this.gestureStartY;
      if (this.gestureIntent === 'undecided') {
        if (Math.max(Math.abs(dx), Math.abs(dy)) <= PhonePlaybackHost.activatePx) {
          return;
        }
        this.disarmHoldTimer();
        if (Math.abs(dx) >= Math.abs(dy)) {
          this.gestureIntent = 'scrub';
          this.scrubBegan();
        } else if (this.adjustAllowedAt(this.gestureStartX, this.gestureStartY)) {
          this.gestureIntent = 'adjust';
          this.adjustBegan(this.gestureStartX < this.layerWidth / 2 ? 'brightness' : 'volume');
        } else {
          // 排除带里起手的竖滑多半是想去摸进度条：整次触摸都不当手势
          this.gestureTracking = false;
        }
        return;
      }
      if (this.gestureIntent === 'scrub') {
        this.scrubChanged(dx);
      } else if (this.gestureIntent === 'adjust') {
        this.adjustChanged(dy);
      } else if (this.gestureIntent === 'barDrag') {
        this.armChromeTimer();
        this.barScrubTo(touch.x);
      }
      return;
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.disarmHoldTimer();
      if (!this.gestureTracking) {
        return;
      }
      this.gestureTracking = false;
      const cancelled: boolean = event.type === TouchType.Cancel;
      PlaybackTestProbe.record('touch', `${this.gestureIntent};visible=${this.chromeVisible};x=${touch.x};y=${touch.y}`);
      // Transport buttons are independent actions, not the first half of a video double tap.
      if (!cancelled && this.gestureIntent === 'chromeTap') {
        this.lastTapAt = 0;
        this.handleChromeTap(touch.x, touch.y);
        this.gestureIntent = 'undecided';
        return;
      }
      if (!cancelled && this.gestureIntent === 'undecided') {
        const now: number = Date.now();
        const isDouble: boolean = now - this.lastTapAt <= PhonePlaybackHost.doubleTapWindow;
        const xRatio: number = touch.x / Math.max(1, this.layerWidth);
        if (isDouble && this.phase === PlayerPhase.ready) {
          this.lastTapAt = 0;
          if (xRatio < 1 / 3) {
            this.chromeVisible = this.lastTapChromeState;
            this.seekTo(this.positionMs - 10000);
          } else if (xRatio > 2 / 3) {
            this.chromeVisible = this.lastTapChromeState;
            this.seekTo(this.positionMs + 10000);
          } else {
            this.togglePlay();
            this.chromeVisible = true;
            this.armChromeTimer();
          }
          this.gestureIntent = 'undecided';
          return;
        }
        this.lastTapAt = now;
        this.lastTapChromeState = this.chromeVisible;
        this.handleTap(xRatio);
        this.gestureIntent = 'undecided';
        return;
      }
      if (this.gestureIntent === 'undecided') {
        if (!cancelled) {
          this.handleTap(touch.x / Math.max(1, this.layerWidth));
        }
      } else if (this.gestureIntent === 'chromeTap') {
        if (!cancelled) {
          this.handleChromeTap(touch.x, touch.y);
        }
      } else if (this.gestureIntent === 'barDrag') {
        this.barDragging = false;
        const target: number = this.scrubMs;
        this.scrubMs = -1;
        if (!cancelled && target >= 0) {
          this.seekTo(target);
        }
      } else if (this.gestureIntent === 'scrub') {
        this.scrubEnded(cancelled);
      } else if (this.gestureIntent === 'adjust') {
        this.adjustEnded();
      } else if (this.gestureIntent === 'hold') {
        this.endHoldSpeed();
      }
      this.gestureIntent = 'undecided';
    }
  }

  handleChromeTap(x: number, y: number): void { this.armChromeTimer(); }

  /** Single tap never resumes paused playback; menu dismissal consumes the tap. */
  handleTap(xRatio: number): void {
    if (this.controlsLocked) { return; }
    if (this.showSheet) { this.closeMenu(); return; }
    this.chromeVisible = this.chromeMustStayVisible() ? true : !this.chromeVisible;
    if (this.chromeVisible) { this.armChromeTimer(); }
  }

  toggleMenu(kind: string): void {
    const close = this.showSheet && (this.sheetKind === kind ||
      (kind === 'settings' && this.sheetKind !== 'audio' && this.sheetKind !== 'subtitle'));
    this.sheetKind = kind; this.showSheet = !close;
    this.chromeVisible = true; this.armChromeTimer();
  }
  closeMenu(): void { this.showSheet = false; this.chromeVisible = true; this.armChromeTimer(); }
  menuCoversCenter(): boolean { return this.showSheet && this.menuTop < this.layerHeight / 2 + 38; }
  menuTitle(): string {
    if (this.sheetKind === 'audio') { return '音轨'; }
    if (this.sheetKind === 'subtitle') { return '字幕'; }
    if (this.sheetKind === 'quality') { return '画质'; }
    if (this.sheetKind === 'speed') { return '倍速'; }
    if (this.sheetKind === 'display') { return '画面'; }
    if (this.sheetKind === 'stats') { return '播放诊断'; }
    return '设置';
  }
  menuHeight(): number {
    const top = this.chromeTopY[1] > this.chromeTopY[0] ? this.chromeTopY[1] - this.layerOriginY
      : (this.isLandscape() ? 16 : Theme.shellTopInset + 8) + 44;
    return Math.max(44, Math.min(460, this.menuAnchorY() - 10 - top - 10));
  }
  menuAnchorY(): number {
    return this.menuAnchorTop > 0 ? this.menuAnchorTop : Math.max(0, this.layerHeight - Theme.safeBottomInset - 100);
  }
  menuHeaderHeight(): number { return this.sheetKind === 'settings' || this.sheetKind === 'stats' ? 0 : 36; }
  selectRate(rate: number): void {
    this.playbackRate = rate; this.controller.setRate(rate); this.closeMenu();
  }
  selectDisplay(mode: string): void { this.displayMode = mode; this.closeMenu(); }
  displayLabel(): string {
    return this.displayMode === 'fill' ? '等比例铺满' : this.displayMode === 'stretch' ? '拉伸铺满' : '完整显示';
  }
  surfaceWidth(): number {
    if (this.displayMode === 'stretch') { return this.layerWidth; }
    return this.displayMode === 'fill' ? Math.max(this.layerWidth, this.layerHeight * this.videoAspect)
      : Math.min(this.layerWidth, this.layerHeight * this.videoAspect);
  }
  surfaceHeight(): number {
    return this.displayMode === 'stretch' ? this.layerHeight : this.surfaceWidth() / this.videoAspect;
  }
  toggleControlLock(): void {
    this.controlsLocked = !this.controlsLocked; this.showSheet = false;
    this.chromeVisible = !this.controlsLocked; this.lastTapAt = 0; this.armChromeTimer();
  }
  handleBack(): boolean {
    PlaybackTestProbe.record('back', `menu=${this.showSheet}:${this.sheetKind},locked=${this.controlsLocked},landscape=${this.isLandscape()},depth=${this.navStack.size()}`);
    if (this.showSheet) { this.closeMenu(); return true; }
    if (this.controlsLocked) { this.toggleControlLock(); return true; }
    if (this.isLandscape()) { this.restoreOrientation(); return true; }
    return false;
  }
  back(): void { if (!this.handleBack()) { this.navStack.pop(); } }

  /** 横滑定位：不唤出控制层、已开着的也收起（画面、落点读数才是在看的东西） */
  scrubBegan(): void {
    this.scrubBaseMs = this.positionMs;
    this.scrubMs = this.positionMs;
    this.chromeVisible = false;
  }

  scrubChanged(dx: number): void {
    if (this.durationMs <= 0) {
      return;
    }
    const delta: number = dx / Math.max(1, this.layerWidth) * PhonePlaybackHost.fullSweepSeekMs;
    const target: number = Math.max(0, Math.min(this.durationMs, this.scrubBaseMs + Math.floor(delta)));
    this.scrubMs = target;
  }

  scrubEnded(cancelled: boolean): void {
    const target: number = this.scrubMs;
    this.scrubMs = -1;
    if (!cancelled && target >= 0) {
      this.seekTo(target);
    }
  }

  /** 横滑落点读数的小字：相对起点的增量（+/-） */
  scrubDeltaText(): string {
    const delta: number = Math.round((this.scrubMs - this.scrubBaseMs) / 1000);
    const sign: string = delta >= 0 ? '+' : '-';
    return `${sign}${this.clockText(Math.abs(delta) * 1000)}`;
  }

  /** 竖滑调节的起手排除带（同 Web touch-adjust.ts）：顶部 12%、底部 24%、左右 32vp */
  adjustAllowedAt(x: number, y: number): boolean {
    return y >= this.layerHeight * PhonePlaybackHost.adjustTopExclude
      && y <= this.layerHeight * (1 - PhonePlaybackHost.adjustBottomExclude)
      && x >= PhonePlaybackHost.edgeGuard && x <= this.layerWidth - PhonePlaybackHost.edgeGuard;
  }

  bandOf(area: Area): number[] {
    const y: number = this.vpOf(area.globalPosition?.y ?? 0);
    return [y, y + this.vpOf(area.height)];
  }

  inBand(v: number, band: number[]): boolean {
    const gv: number = v + this.layerOriginY;
    return band[1] > band[0] && gv >= band[0] && gv <= band[1];
  }

  bandsReady(): boolean {
    return this.chromeTopY[1] > this.chromeTopY[0]
      && this.chromeBottomY[1] > this.chromeBottomY[0];
  }

  inTopBarFallback(y: number): boolean {
    const gy: number = y + this.layerOriginY;
    if (this.layerHeight <= 0) {
      return gy <= 90;
    }
    return gy <= (this.layerOriginY + this.layerHeight) * 0.07;
  }

  inBottomBarFallback(y: number): boolean {
    const gy: number = y + this.layerOriginY;
    if (this.layerHeight <= 0) {
      return gy >= 660;
    }
    return gy >= (this.layerOriginY + this.layerHeight) * 0.84;
  }

  inChromeExclusion(x: number, y: number): boolean {
    if (this.bandsReady()) { return this.inBand(y, this.chromeTopY) || this.inBand(y, this.chromeBottomY); }
    return this.inTopBarFallback(y) || this.inBottomBarFallback(y);
  }

  adjustBegan(side: string): void {
    this.disarmAdjustHide();
    this.adjustSide = side;
    if (side === 'brightness') {
      this.adjustBase = this.currentBrightness();
    } else {
      // 鸿蒙三方应用改不了系统音量：base 恒 0（HUD 走「音量由系统侧键控制」的降级分支）
      this.adjustBase = 0;
    }
    this.adjustValue = this.adjustBase;
  }

  adjustChanged(dy: number): void {
    if (this.adjustSide !== 'brightness') {
      return;
    }
    // 上滑为增：屏幕坐标 y 向下，取负
    const sweep: number = Math.max(1, this.layerHeight * PhonePlaybackHost.fullSweepRatio);
    const value: number = Math.max(0, Math.min(1, this.adjustBase + -dy / sweep));
    this.adjustValue = value;
    this.applyBrightness(value);
  }

  adjustEnded(): void {
    // 松手 0.9 秒后收起胶囊；期间再有动作就重新计时
    this.disarmAdjustHide();
    this.adjustHideTimer = setTimeout((): void => {
      this.adjustHideTimer = -1;
      this.adjustSide = '';
    }, 900);
  }

  /** 当前亮度（0-1）：窗口自己设过的值优先；没设过（-1 = 跟随系统）就读系统设置的 0-255 */
  currentBrightness(): number {
    const win: window.Window | null = this.brightnessWindow;
    if (win !== null) {
      try {
        const value: number = win.getWindowProperties().brightness;
        if (value >= 0) {
          return value;
        }
      } catch (error) {
        // 读不到就退到系统设置
      }
    }
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const raw: string = settings.getValueSync(context, settings.display.SCREEN_BRIGHTNESS_STATUS, '255');
      const level: number = Number(raw);
      if (Number.isFinite(level) && level >= 0) {
        return Math.min(1, level / 255);
      }
    } catch (error) {
      // 读不到（部分设备不给）：从满亮度起调
    }
    return 1;
  }

  applyBrightness(value: number): void {
    if (this.brightnessWindow !== null) {
      this.brightnessWindow.setWindowBrightness(value).then((): void => {
        this.brightnessTouched = true;
      }).catch((): void => {
      });
      return;
    }
    window.getLastWindow(getContext(this)).then((win: window.Window): Promise<void> => {
      this.brightnessWindow = win;
      return win.setWindowBrightness(value);
    }).then((): void => {
      this.brightnessTouched = true;
    }).catch((): void => {
    });
  }

  /** 退出播放器恢复跟随系统（iOS 退出时恢复进入前的系统亮度，这里传 -1 是等价动作） */
  restoreBrightness(): void {
    if (!this.brightnessTouched) {
      return;
    }
    this.brightnessTouched = false;
    const win: window.Window | null = this.brightnessWindow;
    if (win !== null) {
      win.setWindowBrightness(-1).catch((): void => {
      });
    }
  }

  /**
   * 上报观看进度（start / progress / stop 同一入口，对应 iOS `PlaybackAPI.progress`）。
   * 三种事件走 `/playback/progress`（访客走 /share 路径）：服务端据此维护续播点、
   * 「继续观看」与活动页「谁在播」；管理员在活动页结束播放时靠响应里的 ended_by_admin 退出。
   */

  /** 管理员在活动页结束了本次播放：原地停下并说明（同 iOS `handleProgressResponse`） */

  /** 分享访客的本机续播点：看过 90% 或到了片尾就记 0（下次从头放），同服务端 resolve_progress 的口径（iOS `localResume`） */

  stopSession(): void {
    this.sessionCoordinator.close();
    this.session = null;
    const recorder = this.viewingRecorder; this.viewingRecorder = null;
    recorder?.finish(this.positionMs, this.ended);
    this.localUnit = null; this.localSpec = null; this.localMediaPath = ''; this.subtitleCue = '';

  }

  // MARK: 屏幕常亮 / 方向（iOS PlayerSystemBridges）

  /** 播放期间保持屏幕常亮（iOS UIApplication.isIdleTimerDisabled） */
  async keepScreenOn(): Promise<void> {
    if (this.keptScreenOn) {
      return;
    }
    try {
      const win: window.Window = await window.getLastWindow(getContext(this));
      await win.setWindowKeepScreenOn(true);
      this.keptScreenOn = true;
    } catch (error) {
      // 保持不了常亮不影响播放
    }
  }

  /** 退出播放器恢复系统默认（锁屏计时照常） */
  async allowScreenOff(): Promise<void> {
    if (!this.keptScreenOn) {
      return;
    }
    this.keptScreenOn = false;
    try {
      const win: window.Window = await window.getLastWindow(getContext(this));
      await win.setWindowKeepScreenOn(false);
    } catch (error) {
    }
  }

  /** 横竖屏切换（iOS PlayerOrientation）：显式锁进目标方向，不锁会被系统转回去 */
  async toggleLandscape(): Promise<void> {
    this.armChromeTimer();
    try {
      const win: window.Window = await window.getLastWindow(getContext(this));
      if (this.landscapeLocked) {
        this.landscapeLocked = false;
        await win.setPreferredOrientation(window.Orientation.PORTRAIT);
      } else {
        this.landscapeLocked = true;
        await win.setPreferredOrientation(window.Orientation.AUTO_ROTATION_LANDSCAPE);
      }
    } catch (error) {
      this.toast('切换方向失败');
    }
  }

  /** 退出播放器恢复竖屏（只有锁过横屏才动） */
  async restoreOrientation(): Promise<void> {
    if (!this.landscapeLocked && !this.isLandscape()) {
      return;
    }
    this.landscapeLocked = false;
    try {
      const win: window.Window = await window.getLastWindow(getContext(this));
      await win.setPreferredOrientation(window.Orientation.PORTRAIT);
    } catch (error) {
    }
  }

  /**
   * 15 秒一次（同 iOS）。三态必须区分（同 Web pingPlaybackSession）：
   * - 200 = 还在（本机转码被判死时响应里另带 failed=true，据此直接降档）；
   * - 404 = 服务端明确说没了，要原位重开；
   * - 其他失败 = 这次请求本身失败，不能当成没了。
   */

  // MARK: 错误重试 / 软件转码同意 / 画质（iOS retry / grantConsent / selectQuality）

  /** 错误页「重试」（iOS retry()）：清降档台账从当前位重协商 */
  retryPlayback(): void {
    this.failedTiers = [];
    this.retryCount = 0;
    this.startMs = this.positionMs > 0 ? this.positionMs : this.startMs;
    this.resumeExplicit = true;
    this.errorMessage = '';
    this.errorSuggestion = '';
    this.negotiate();
  }

  /** 同意弹窗「开启并播放」（iOS grantConsent）：翻策略开关、校验回显、重新协商 */
  async grantConsent(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.consentSaving = true;
    try {
      const policy: PlaybackPolicyView = await api.playbackPolicySet({ software_transcode_enabled: true });
      // 开关可能没生效（远程配置延迟等）：回显不是 true 就不当成功（iOS 同款校验）
      if (policy.software_transcode_enabled !== true) {
        this.consentSaving = false;
        this.toast('开关没有生效，稍后再试或到网页端设置');
        return;
      }
      this.consentSaving = false;
      await this.negotiate();
    } catch (error) {
      this.consentSaving = false;
      this.toast('开启失败，稍后再试');
    }
  }

  /** 画质菜单当前选中项的标签（iOS QualityOption.label） */
  qualityLabel(maxHeight: number): string {
    if (maxHeight <= 0) {
      return '自动（原画优先）';
    }
    return `${maxHeight}p`;
  }

  qualityOptions(): QualityOption[] {
    return [
      new QualityOption('自动（原画优先）', 0),
      new QualityOption('1080p', 1080),
      new QualityOption('720p', 720),
      new QualityOption('480p', 480)
    ];
  }

  /** 换画质（iOS selectQuality + switchQuality）：记本机记忆，视频超上限时重开会话 */
  async pickQuality(maxHeight: number): Promise<void> {
    this.showSheet = false;
    if (maxHeight === this.maxHeight) {
      return;
    }
    const previous: number = this.maxHeight;
    this.maxHeight = maxHeight;
    await PlayerPrefs.writeQuality(this.mediaItemId, this.seasonNumber, this.episodeNumber, maxHeight);
    // 本机副本没有服务端档位，只记选择（下次流式起播生效）
    if (this.localUnit !== null) {
      return;
    }
    if (maxHeight <= 0 && previous <= 0) {
      return;
    }
    this.startMs = this.positionMs > 0 ? this.positionMs : this.startMs;
    this.resumeExplicit = true;
    this.failedTiers = [];
    this.retryCount = 0;
    this.toast('正在按新画质重开…');

    await this.releasePlayer();
    this.stopSession();
    await this.negotiate();
  }

  // MARK: 诊断面板（iOS PlayerDiagnosticsPanel，2 秒快照）

  startDiagnostics(): void {
    this.stopDiagnostics();
    this.pollDiagnostics();
    this.diagTimer = setInterval((): void => {
      this.pollDiagnostics();
    }, 2000);
  }

  stopDiagnostics(): void {
    if (this.diagTimer >= 0) {
      clearInterval(this.diagTimer);
      this.diagTimer = -1;
    }
  }

  pollDiagnostics(): void {
    const epoch = this.sessionEpoch;
    const api: MovieClawApi | null = this.api();
    const view: PlaybackSessionView | null = this.session;
    const sessionId: string | null = view !== null ? (view.session_id ?? null) : null;
    if (api === null || sessionId === null || sessionId.length === 0) {
      // 直出 / 本机副本没有会话：只显示本地信息，不拉快照
      this.diag = null;
      return;
    }
    const token: string = this.streamToken();
    const request: Promise<PlaybackDiagnosticsView> = this.shareSlug.length > 0
      ? api.sharePlaybackSessionDiagnostics(sessionId, this.shareSlug, token)
      : api.playbackSessionDiagnostics(sessionId, token);
    request.then((snapshot: PlaybackDiagnosticsView): void => {
      if (epoch !== this.sessionEpoch || this.disposed) { return; }
      this.diag = snapshot;
    }).catch((): void => {
      // 拉不到就停在上一张快照
    });
  }

  /** 弹层开关的监听：详情面板开着就轮询，关了就停（iOS 只在面板开着时拉快照） */
  @Monitor('showSheet', 'sheetKind')
  onSheetVisibility(): void {
    if (this.showSheet && this.sheetKind === 'stats') {
      this.startDiagnostics();
      return;
    }
    this.stopDiagnostics();
    if (!this.showSheet) {
      this.diag = null;
      this.armChromeTimer();
    }
  }

  // 以下一行行文本都按 iOS PlayerDiagnosticsPanel 的 Section/ActionLine 排：
  // 面板里禁止局部声明，每行抽一个方法，空串 = 这一行不显示

  /** 「seg00012」（iOS segment()，五位补零） */
  diagSegLabel(index: number | null | undefined): string {
    if (index === null || index === undefined || index < 0) {
      return '—';
    }
    const digits: string = `${index}`;
    return `seg${'0'.repeat(Math.max(0, 5 - digits.length))}${digits}`;
  }

  /** 处理方式标签（iOS processingLabels） */
  diagProcessingLabel(mode: string): string {
    const labels: Record<string, string> = {
      'direct': '原文件直出',
      'remux': '仅容器重封装',
      'audio-transcode': '仅音频转码',
      'transcode-pending': '硬件转码（执行端读取中）',
      'local-hardware': '本地硬件转码',
      'local-software': '本地软件转码',
      'remote-hardware': '远程硬件转码'
    };
    return labels[mode] ?? mode;
  }

  /** 执行位置标签（iOS locationLabels） */
  diagLocationLabel(location: string): string {
    const labels: Record<string, string> = {
      'client': '客户端',
      'nas': 'NAS',
      'remote_worker': '远程 Worker'
    };
    return labels[location] ?? location;
  }

  /** 转码任务状态标签（iOS jobStateLabels） */
  diagJobStateLabel(state: string): string {
    const labels: Record<string, string> = {
      'job.pending': '排队中',
      'job.accepted': '已接单',
      'job.progress': '转码中',
      'job.failed': '任务失败',
      'job.finished': '已完成'
    };
    return labels[state] ?? state;
  }

  diagExecutionMode(): string {
    const d: PlaybackDiagnosticsView | null = this.diag;
    return d === null ? '' : this.diagProcessingLabel(d.processing_mode);
  }

  diagLocation(): string {
    const d: PlaybackDiagnosticsView | null = this.diag;
    return d === null ? '' : `位置：${this.diagLocationLabel(d.execution_location)}`;
  }

  diagBackendLine(): string {
    const d: PlaybackDiagnosticsView | null = this.diag;
    if (d === null) {
      return '';
    }
    const backend: string = d.backend ?? '';
    if (backend.length === 0) {
      return '';
    }
    const encoder: string = d.encoder ?? '';
    return encoder.length > 0 ? `后端：${backend} · ${encoder}` : `后端：${backend}`;
  }

  diagWorkerLine(): string {
    const d: PlaybackDiagnosticsView | null = this.diag;
    if (d === null) {
      return '';
    }
    const workerId: string = d.worker_id ?? '';
    if (workerId.length === 0) {
      return '';
    }
    let state: string = '切换中';
    if (d.worker_online === true) {
      state = '在线';
    } else if (d.worker_online === false) {
      state = '离线';
    }
    return `Worker：${workerId} · ${state}`;
  }

  diagWorkerVersionLine(): string {
    const d: PlaybackDiagnosticsView | null = this.diag;
    if (d === null) {
      return '';
    }
    const parts: string[] = [];
    const workerVersion: string = d.worker_version ?? '';
    if (workerVersion.length > 0) {
      parts.push(`Worker ${workerVersion}`);
    }
    const ffmpeg: string = d.ffmpeg_version ?? '';
    if (ffmpeg.length > 0) {
      parts.push(`ffmpeg ${ffmpeg}`);
    }
    return parts.join(' · ');
  }

  diagWorkerPlatformLine(): string {
    const d: PlaybackDiagnosticsView | null = this.diag;
    if (d === null) {
      return '';
    }
    const parts: string[] = [];
    const platform: string = d.worker_platform ?? '';
    if (platform.length > 0) {
      parts.push(platform);
    }
    const arch: string = d.worker_arch ?? '';
    if (arch.length > 0) {
      parts.push(arch);
    }
    return parts.length === 0 ? '' : `平台：${parts.join(' · ')}`;
  }

  diagJobLine(): string {
    const d: PlaybackDiagnosticsView | null = this.diag;
    if (d === null) {
      return '';
    }
    const jobId: string = d.job_id ?? '';
    if (jobId.length === 0) {
      return '';
    }
    const parts: string[] = [`任务：${jobId}`];
    const state: string = d.job_state ?? '';
    if (state.length > 0) {
      parts.push(this.diagJobStateLabel(state));
    }
    const speed: string = d.job_speed ?? '';
    if (speed.length > 0) {
      parts.push(speed);
    }
    return parts.join(' · ');
  }

  diagExitCodeLine(): string {
    const d: PlaybackDiagnosticsView | null = this.diag;
    if (d === null || d.job_exit_code === null || d.job_exit_code === undefined) {
      return '';
    }
    return `ffmpeg 退出码：${d.job_exit_code}`;
  }

  diagJobErrorLine(): string {
    const d: PlaybackDiagnosticsView | null = this.diag;
    if (d === null) {
      return '';
    }
    const error: string = d.job_error ?? '';
    const sessionError: string = d.session_error ?? '';
    if (error.length === 0 || error === sessionError) {
      return '';
    }
    return `Worker：${error}`;
  }

  diagStderrLine(): string {
    const d: PlaybackDiagnosticsView | null = this.diag;
    if (d === null) {
      return '';
    }
    const tail: string = d.job_stderr_tail ?? '';
    return tail.length === 0 ? '' : `ffmpeg stderr：${tail}`;
  }

  diagSessionErrorLine(): string {
    const d: PlaybackDiagnosticsView | null = this.diag;
    return d === null ? '' : (d.session_error ?? '');
  }

  /** 供片区有没有内容（iOS：totalSegments 存在才出「供片」Section） */
  diagHasSegments(): boolean {
    const d: PlaybackDiagnosticsView | null = this.diag;
    return d !== null && d.total_segments !== null && d.total_segments !== undefined;
  }

  diagSupplyFirstLine(): string {
    const d: PlaybackDiagnosticsView | null = this.diag;
    if (d === null) {
      return '';
    }
    if (d.pending_segments.length > 0) {
      return `等待 ${this.diagSegLabel(d.pending_segments[0])}`;
    }
    if (d.requested_segment !== null && d.requested_segment !== undefined) {
      return `最近请求 ${this.diagSegLabel(d.requested_segment)}`;
    }
    return '当前无等待分片';
  }

  diagSupplyProducedLine(): string {
    const d: PlaybackDiagnosticsView | null = this.diag;
    if (d === null) {
      return '';
    }
    return `连续产出 ${this.diagSegLabel(d.highest_produced_segment)} · 头部 ${this.diagSegLabel(d.head_segment)} · 共 ${d.total_segments ?? 0} 段`;
  }

  diagSupplyLeadLine(): string {
    const d: PlaybackDiagnosticsView | null = this.diag;
    if (d === null || d.lead_seconds === null || d.lead_seconds === undefined) {
      return '';
    }
    let suffix: string = '';
    if (d.pause_reasons.indexOf('lead') >= 0) {
      suffix = ' · 已领先足够，转码暂停';
    } else if (d.pause_reasons.indexOf('disk') >= 0) {
      suffix = ' · 磁盘空间告急，转码暂停';
    }
    return `转码领先 ${Math.round(d.lead_seconds)} 秒${suffix}`;
  }

  diagSupplyCacheLine(): string {
    const d: PlaybackDiagnosticsView | null = this.diag;
    if (d === null) {
      return '';
    }
    let line: string = `NAS 会话缓存 ${Formatters.bytes(d.cache_bytes)}`;
    if (d.cache_hit) {
      line += ` · 命中上次转码产物（${d.cached_segments} 段免转）`;
    }
    return line;
  }

  diagSupplyGapLine(): string {
    const d: PlaybackDiagnosticsView | null = this.diag;
    if (d === null || d.failed_segments.length === 0) {
      return '';
    }
    let line: string = `当前缺口 ${this.diagSegLabel(d.failed_segments[0])}`;
    if (d.failed_segments.length > 1) {
      line += ` 等 ${d.failed_segments.length} 段`;
    } else {
      line += ' · 上传失败待重试';
    }
    return line;
  }

  diagSupplyHistoricalLine(): string {
    const d: PlaybackDiagnosticsView | null = this.diag;
    if (d === null || d.historical_failed_segments.length === 0) {
      return '';
    }
    let line: string = `历史失败 ${this.diagSegLabel(d.historical_failed_segments[0])}`;
    if (d.historical_failed_segments.length > 1) {
      line += ` 等 ${d.historical_failed_segments.length} 段`;
    } else {
      line += ' · 已落后当前播放位置';
    }
    return line;
  }

  diagSupplyUploadLine(): string {
    const d: PlaybackDiagnosticsView | null = this.diag;
    if (d === null || d.recent_uploads.length === 0) {
      return '';
    }
    const upload: PlaybackArtifactUploadView = d.recent_uploads[0];
    const status: string = upload.status === 201 ? '成功' : `HTTP ${upload.status}`;
    const parts: string[] = [upload.name, status, Formatters.bytes(upload.received_bytes)];
    if (upload.content_length !== null && upload.content_length !== undefined) {
      parts.push(`${Formatters.bytes(upload.content_length)} 期望`);
    } else {
      const encoding: string = upload.transfer_encoding ?? '';
      if (encoding.length > 0) {
        parts.push(encoding);
      }
    }
    return `最近上传 ${parts.join(' · ')}`;
  }

  diagSupplyUploadAlert(): boolean {
    const d: PlaybackDiagnosticsView | null = this.diag;
    return d !== null && d.recent_uploads.length > 0 && d.recent_uploads[0].status >= 400;
  }

  diagSupplyWaitLine(): string {
    const d: PlaybackDiagnosticsView | null = this.diag;
    if (d === null || d.segment_wait_ms === null || d.segment_wait_ms === undefined) {
      return '';
    }
    let line: string = `最近供片等待 ${(d.segment_wait_ms / 1000).toFixed(1)} 秒`;
    if (d.segment_status !== null && d.segment_status !== undefined) {
      line += ` · HTTP ${d.segment_status}`;
    }
    return line;
  }

  // MARK: 片段收尾（iOS PlayerClipEndCard / exitClip）

  /** 片段重播：回片段起点再放 */
  replayClip(): void {
    this.clipEnded = false; this.seekTo(this.clipStartMs); this.play();
  }

  /** 看全片（iOS exitClip）：清片段区间重开会话，从当前位放整部片 */
  exitClip(): void {
    this.clipStartMs = 0;
    this.clipEndMs = 0;
    this.clipEnded = false;
    this.ended = false;
    this.startMs = Math.max(0, this.positionMs);
    this.failedTiers = [];
    this.retryCount = 0;

    this.releasePlayer().then((): void => {
      this.stopSession();
      this.negotiate();
    });
  }

  /** 退出播放器前把片段进度写回共享状态（刷片页接着刚才看到的地方放） */
  publishClipReturn(): void {
    if (!this.isClip()) {
      return;
    }
    const view: PlaybackSessionView | null = this.session;
    const fileId: number = view !== null ? (view.decision.file_id ?? this.fileId) : this.fileId;
    AppModel.shared.clipReturn = new ClipReturn(fileId,
      Math.min(Math.max(this.clipStartMs, this.positionMs), this.clipEndMs));
  }

  // MARK: 自绘字幕样式（iOS SubtitleStyleEditor；只作用于本机外挂轨）

  /** 同意弹窗的代价行（服务端的 cost_hint） */
  consentCostHint(): string {
    const view: PlaybackSessionView | null = this.session;
    const hint: string | null = view !== null ? (view.decision.cost_hint ?? null) : null;
    return hint !== null ? hint : '';
  }

  /** 能不能自己开软件转码（服务端的 can_self_enable） */
  canSelfEnable(): boolean {
    const view: PlaybackSessionView | null = this.session;
    return view !== null && view.decision.can_self_enable === true;
  }

  adjustSubtitleStyle(fontScaleDelta: number, bottomDelta: number): void {
    this.subFontScale = Math.min(10, Math.max(2, Math.round((this.subFontScale + fontScaleDelta) * 10) / 10));
    this.subBottom = Math.min(40, Math.max(0, this.subBottom + bottomDelta));
    const style: SubStyle = new SubStyle();
    style.fontScale = this.subFontScale;
    style.bottomPercent = this.subBottom;
    style.background = this.subBackground;
    PlayerPrefs.writeSubtitleStyle(style);
    // mpv：样式直接交给 libass 渲染；AVPlayer 走上面的 @Local 变量自绘
    this.controller.setSubtitleStyle(style);
  }

  toggleSubtitleBackground(): void {
    this.subBackground = !this.subBackground;
    this.adjustSubtitleStyle(0, 0);
  }

  // MARK: 派生

  /** 档位标签（iOS PlayerDiagnosticsPanel.tierLabels，0-4 三端通用） */
  tierLabel(tier: number): string {
    const labels: string[] = ['原文件直出', '换壳直通', '换壳 + 转音轨', '硬件转码', '软件转码'];
    return tier >= 0 && tier < labels.length ? labels[tier] : `第 ${tier} 档`;
  }

  streamLabel(): string {
    // 本机副本：标「本机 + 画质档」（不参与服务端档位体系）
    const unit: OfflineUnit | null = this.localUnit;
    if (unit !== null) {
      const label: string = unit.profileLabel;
      return label.length > 0 ? `本机副本 · ${label}` : '本机副本';
    }
    const view: PlaybackSessionView | null = this.session;
    if (view === null) {
      return '';
    }
    const tier: number = view.decision.tier ?? 0;
    if (tier <= 0) {
      return '直出';
    }
    return this.tierLabel(tier);
  }

  clockText(ms: number): string {
    const total: number = Math.max(0, Math.floor(ms / 1000));
    const minutes: number = Math.floor(total / 60);
    const seconds: number = total % 60;
    const tail = `${minutes % 60 < 10 ? '0' : ''}${minutes % 60}:${seconds < 10 ? '0' : ''}${seconds}`;
    return minutes >= 60 ? `${Math.floor(minutes / 60)}:${tail}` : `${minutes}:${seconds < 10 ? '0' : ''}${seconds}`;
  }

  // MARK: 时间轴（片段播放时只算这一段：iOS timelineStartMs / timelineDurationMs）

  /** 时间轴上显示的位置（片段 = 原片位置减片段起点） */
  displayPositionMs(): number {
    return this.isClip() ? Math.max(0, this.positionMs - this.clipStartMs) : this.positionMs;
  }

  /** 时间轴总长（片段 = 片段跨度，不是整部片） */
  displayDurationMs(): number {
    return this.isClip() ? Math.max(0, this.clipEndMs - this.clipStartMs) : this.durationMs;
  }

  /** 横滑读数里的落点（同样换算到片段时间轴） */
  displayScrubMs(): number {
    return this.isClip() ? Math.max(0, this.scrubMs - this.clipStartMs) : this.scrubMs;
  }

  progressPercent(): number {
    const duration: number = this.displayDurationMs();
    if (duration <= 0) {
      return 0;
    }
    const ms: number = this.barDragging && this.scrubMs >= 0 ? this.displayScrubMs() : this.displayPositionMs();
    return Math.round(ms * 100 / duration);
  }

  // MARK: 底栏进度条（iOS PlayerProgressBar）：可拖，松手才跳；触摸分发统一在 NavDestination 手势层

  /** 拖动进度条：页面坐标触点 → 时间轴时间（片段换算回原片时间轴再夹区间） */
  barScrubTo(x: number): void {
    const duration: number = this.displayDurationMs();
    if (duration <= 0) {
      return;
    }
    const width: number = Math.max(1, this.progressBarWidth);
    const barLocalX: number = x + this.layerOriginX - this.barLeftX;
    const ratio: number = Math.max(0, Math.min(1, barLocalX / width));
    const timelineMs: number = Math.floor(ratio * duration);
    this.scrubMs = this.isClip() ? this.clipStartMs + timelineMs : timelineMs;
  }

  // MARK: 视图

}
