import { media } from '@kit.MediaKit';
import { BusinessError, settings } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { PiPWindow, window } from '@kit.ArkUI';
import { audio } from '@kit.AudioKit';
import { image } from '@kit.ImageKit';
import { http } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { PlaybackGuard } from './PlaybackGuard';
import { PlayerPrefs, SubStyle } from './PlayerPrefs';
import { Theme } from '../theme/AppTheme';
import { Formatters } from '../common/Formatters';
import { ShellChrome } from '../common/ShellChrome';
import { AppModel, ClipReturn } from '../common/AppModel';
import { RemoteImage } from '../common/RemoteImage';
import { ImageUrls } from '../common/ImageUrls';
import { ShareLocalProgress } from '../share/ShareProgress';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { OfflineDisk } from '../offline/OfflineDisk';
import { OfflineStore } from '../offline/OfflineStore';
import { OfflineViewingRecorder } from '../offline/OfflineViewings';
import {
  OfflinePlaybackSpec,
  OfflineProgress,
  OfflineSubtitleSpec,
  OfflineUnit } from '../offline/OfflineModels';
import {
  AudioSupportIn,
  ClientCapabilityIn,
  PlaybackSessionRequest,
  PlaybackSessionView,
  PlaybackDecisionView,
  PlaybackStateView,
  AudioTrackView,
  EpisodeView,
  LibraryItemDetailView,
  PlaybackChapterMarkView,
  PlaybackItemView,
  SeasonEpisodesView,
  SubtitlePlanView,
  TrickplayView,
  VideoSupportIn, PlaybackSegmentView, PlaybackProgressRequest,
  PlaybackDiagnosticsView, PlaybackPolicyView, PlaybackArtifactUploadView } from '../api/Models';
import { JsonValue, jsonBoolValue } from '../api/JsonValue';

/** 路由表注册用（router_map.json 的 buildMethod） */
@Builder
export function PlayerBuilder() {
  PlayerPage()
}

/** 播放器页的路由参数（会序列化，不要用 instanceof） */
export class PlayerParams {
  readonly mediaItemId: number;
  readonly fileId: number;
  readonly seasonNumber: number;
  readonly episodeNumber: number;
  readonly startMs: number;
  /** 分享访客播放：走 /share/{slug}/playback 接口族，进度只存本机；空 = 站内播放 */
  readonly shareSlug: string;
  /** 片段播放（刷片页「全屏观看」，iOS `PlaybackClip`）：时间轴只算这段，不报观看进度 */
  readonly clipStartMs: number;
  readonly clipEndMs: number;

  constructor(mediaItemId: number, fileId: number = 0, seasonNumber: number = 0,
    episodeNumber: number = 0, startMs: number = 0, shareSlug: string = '',
    clipStartMs: number = 0, clipEndMs: number = 0) {
    this.mediaItemId = mediaItemId;
    this.fileId = fileId;
    this.seasonNumber = seasonNumber;
    this.episodeNumber = episodeNumber;
    this.startMs = startMs;
    this.shareSlug = shareSlug;
    this.clipStartMs = clipStartMs;
    this.clipEndMs = clipEndMs;
  }

  static of(param: Object | undefined | null): PlayerParams | null {
    if (param === undefined || param === null) {
      return null;
    }
    const raw: PlayerParams = param as PlayerParams;
    const id: number = raw.mediaItemId;
    if (!Number.isFinite(id) || id <= 0) {
      return null;
    }
    return new PlayerParams(Math.floor(id),
      Number.isFinite(raw.fileId) ? Math.floor(raw.fileId) : 0,
      Number.isFinite(raw.seasonNumber) ? Math.floor(raw.seasonNumber) : 0,
      Number.isFinite(raw.episodeNumber) ? Math.floor(raw.episodeNumber) : 0,
      Number.isFinite(raw.startMs) ? Math.floor(raw.startMs) : 0,
      raw.shareSlug !== undefined && raw.shareSlug !== null ? raw.shareSlug : '',
      Number.isFinite(raw.clipStartMs) ? Math.floor(raw.clipStartMs) : 0,
      Number.isFinite(raw.clipEndMs) ? Math.floor(raw.clipEndMs) : 0);
  }
}

/** `ClientCapabilityIn` 有必填字段但其余可选，仍用类构造以便阅读 */
class Capability implements ClientCapabilityIn {
  video?: VideoSupportIn[] | null;
  audio?: AudioSupportIn[] | null;
  containers?: string[] | null;
  hdr_passthrough?: boolean | null;
  mse?: string | null;
  is_mobile?: boolean | null;
  native_hls?: boolean | null;
  universal?: boolean | null;
}

/** `PlaybackSessionRequest` 的 capability 是必填，其余可选 */
class SessionRequest implements PlaybackSessionRequest {
  file_id?: number | null;
  media_item_id?: number | null;
  season_number?: number | null;
  episode_number?: number | null;
  capability: ClientCapabilityIn = new Capability();
  /** 已失败的档位：服务端据此跳过它们（后端的「运行期降档回路」） */
  failed_tiers?: number[] | null;
  /** 选中的音轨 ref；给了服务端就认它、不再自动换轨（可能把直出顶成重封装） */
  audio_track?: string | null;
  /** 用户选的画质上限（语义是上限：源不超就直通，超了才转码降下去；null = 自动） */
  max_height?: number | null;
  start_ms?: number | null;
  client?: string | null;
}

/** `VideoSupportIn` / `AudioSupportIn` 也按 ArkTS 的要求用类构造 */
class VideoSupport implements VideoSupportIn {
  codec: string = '';
  max_height?: number | null;
  active: boolean = true;
}

/** `PlaybackProgressRequest` 几乎全可选，同样用类构造 */
class ProgressRequest implements PlaybackProgressRequest {
  media_item_id: number = 0;
  season_number?: number | null;
  episode_number?: number | null;
  event?: string | null;
  position_ms?: number | null;
  audio_track?: string | null;
  subtitle_track?: string | null;
  file_id?: number | null;
  device_id?: string | null;
  paused?: boolean | null;
}

class AudioSupport implements AudioSupportIn {
  codec: string = '';
  max_channels?: number | null;
  active: boolean = true;
}

/** 画质选项（iOS `QualityOption.all`：原画/1080p/720p/480p；maxHeight 是**上限**语义） */
class QualityOption {
  readonly label: string;
  readonly maxHeight: number;

  constructor(label: string, maxHeight: number) {
    this.label = label;
    this.maxHeight = maxHeight;
  }
}

/** 播放状态机 */
class PlayerPhase {
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
class SkipSegments {
  /** 离区间尾不足这么多毫秒就不再给「跳过」：按下去只省一两秒 */
  static readonly tailMs: number = 3000;
  /** 自动播下一集的倒计时 8 秒（5 秒来不及反应，用户反馈 2026-10-01） */
  static readonly autoNextMs: number = 8000;
  /** 连续自动播了这么多集、期间没人碰过播放器，就不再自动播 */
  static readonly autoNextMaxStreak: number = 3;

  static active(segments: PlaybackSegmentView[] | null, positionMs: number): PlaybackSegmentView | null {
    if (segments === null) {
      return null;
    }
    for (const segment of segments) {
      if (segment.type === 'outro' && segment.to_end) {
        continue;
      }
      if (positionMs >= segment.start_ms && positionMs < segment.end_ms - SkipSegments.tailMs) {
        return segment;
      }
    }
    return null;
  }

  static isInOutro(segments: PlaybackSegmentView[] | null, positionMs: number): boolean {
    if (segments === null) {
      return false;
    }
    for (const segment of segments) {
      if (segment.type === 'outro' && segment.to_end && positionMs >= segment.start_ms) {
        return true;
      }
    }
    return false;
  }

  /** 卡片要不要倒计时自动播下一集：认出了放到结尾的片尾（进了就开始），或已播完 */
  static autoNextArmed(segments: PlaybackSegmentView[] | null, positionMs: number,
    streak: number, ended: boolean): boolean {
    return streak < SkipSegments.autoNextMaxStreak
      && (ended || SkipSegments.isInOutro(segments, positionMs));
  }

  /** 「即将播放」卡片的时机：认出了放到结尾的片尾就从片尾起点给，否则播完才给 */
  static shouldShowUpNext(segments: PlaybackSegmentView[] | null, positionMs: number,
    ended: boolean): boolean {
    if (ended) {
      return true;
    }
    if (SkipSegments.active(segments, positionMs) !== null) {
      return false;
    }
    return SkipSegments.isInOutro(segments, positionMs);
  }
}

/**
 * 进度条缩略图（对应 iOS `TrickplayImages`）：按需下载雪碧图，按落点裁出目标格子。
 * 雪碧图 token 已在地址里（不需要登录头）；裁格子走 `DecodingOptions.desiredRegion`，
 * 裁过的格子按序号缓存（一次拖动里每个序号最多裁一次）。
 */
class TrickplayTiles {
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
          this.tiles.clear();
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
@ComponentV2
export struct PlayerPage {
  private navStack: NavPathStack = new NavPathStack();
  private chrome: ShellChrome = ShellChrome.shared;
  private started: boolean = false;
  private avPlayer: media.AVPlayer | null = null;
  private surfaceId: string = '';
  /** 拿 surface id 的正规途径：XComponentController（`XComponentContext` 不是公开类型） */
  private surfaceController: XComponentController = new XComponentController();
  private reportTimer: number = -1;
  /** 本单元已上报过 start（iOS `reportedStart`）：换集 / 退出时补发 stop */
  private progressStarted: boolean = false;

  @Local private phase: string = PlayerPhase.negotiating;
  @Local private errorMessage: string = '';
  @Local private session: PlaybackSessionView | null = null;
  @Local private playing: boolean = false;
  @Local private durationMs: number = 0;
  @Local private positionMs: number = 0;
  @Local private title: string = '';

  private mediaItemId: number = 0;
  private fileId: number = 0;
  private seasonNumber: number = 0;
  private episodeNumber: number = 0;
  private startMs: number = 0;
  /** 分享访客播放的 slug；空 = 站内播放（进度只存本机） */
  private shareSlug: string = '';
  /** 已失败的档位：重试时带给服务端，让它跳过这些档（后端的「运行期降档回路」） */
  private failedTiers: number[] = [];
  /** 已经重试过几次，避免无限循环 */
  private retryCount: number = 0;

  // —— 本机副本（离线下载的播放路径，对应 iOS startLocal 一节）——
  /** 正在放的本机单元（有它就不建服务端会话，进度记 OfflineViewingRecorder） */
  private localUnit: OfflineUnit | null = null;
  /** 本机播放数据（playback.json：章节 / 音轨 / 外挂字幕清单） */
  private localSpec: OfflinePlaybackSpec | null = null;
  /** 本机观看记录器（进度先落盘，能连上时补传） */
  private viewingRecorder: OfflineViewingRecorder | null = null;
  /** 媒体文件路径 + 句柄：fdSrc 播放期间必须保持打开，换集 / 退出时关 */
  private localMediaPath: string = '';
  private localFile: fileIo.File | null = null;
  /** 外挂字幕文件句柄（prepare 前挂进播放器，之后保持打开） */
  private subtitleFile: fileIo.File | null = null;
  /** prepared 时要跳到的位置（重建播放器续位用；-1 = 从头） */
  private pendingSeekMs: number = -1;
  /** prepare 要不要缓一缓：外挂字幕必须在 prepare 前挂，挂完再放行 */
  private deferPrepare: boolean = false;
  /** 本机目录只等一次（冷启动直达播放器时先等目录读完再判「有没有副本」） */
  private awaitedOfflineStore: boolean = false;
  /** 本机副本真放不了（文件坏 / 解码不动）：这一集不再试本机，直接走服务端 */
  private localFailedOnce: boolean = false;
  /** 本机失败已在回退服务端（error 事件可能连发，防并发协商） */
  private localFallingBack: boolean = false;
  /** 本机外挂字幕当前句文本（subtitleUpdate 只回调文本，渲染自己来） */
  @Local private subtitleCue: string = '';
  /** 起播看门狗：HLS 取不到分片时 AVPlayer **不报错、只是无限重试**（实测每 15 秒一次），
   *  所以「这一档放不了」只能靠自己计时判定，不能等 error 事件。 */
  private watchdog: number = -1;
  /** 系统合规壳：后台播放 + 音频焦点 + 系统媒体控制 */
  private guard: PlaybackGuard | null = null;
  /** 画中画控制器（懒建；只在系统支持时才建） */
  private pip: PiPWindow.PiPController | null = null;
  @Local private pipActive: boolean = false;
  /** 浮层控制条显隐（iOS：点画面切换，播放中 4 秒后自动收起；暂停/弹层开着时钉住） */
  @Local private chromeVisible: boolean = true;
  private chromeTimer: number = -1;
  /** 视频宽高比（用来把 surface 摆成视频的形状，不然画面会被拉伸） */
  @Local private videoAspect: number = 16 / 9;
  /** 字幕：候选轨、当前选中的下标（-1 = 关） */
  /** 弹层槽位（一个组件只能绑一个 bindSheet）：空串=关，subtitle=字幕，stats=播放详情 */
  @Local private sheetKind: string = '';
  @Local private showSheet: boolean = false;
  @Local private subtitleIndex: number = -1;
  /** 音轨：当前选中的 ref（空 = 服务端自动挑） */
  @Local private audioRef: string = '';
  @Local private showAudio: boolean = false;
  /** 已加载到播放器里的外挂字幕轨的 track index（AVPlayer 用数字下标选轨） */
  private loadedSubtitleTrack: number = -1;

  // —— 下一集 / 自动连播（对应 iOS PlaybackController 的 autoNext 一节）——
  /** 本季分集（「即将播放」卡片与自动连播用） */
  @Local private episodes: EpisodeView[] = [];
  /** 播完了（AVPlayer completed）：卡片与自动连播的触发条件之一 */
  @Local private ended: boolean = false;
  /** 用户关掉了卡片（这一集里不再弹；换集时重置） */
  @Local private nextDismissed: boolean = false;
  /** 倒计时进度 0...1（卡片「立即播放」按钮上的白条就是它） */
  @Local private autoNextProgress: number = 0;
  private autoNextCancelled: boolean = false;
  /** 连续自动播了几集（期间有任何操作就清零，满上限不再自动播） */
  private autoNextStreak: number = 0;
  /** 倒计时的钟：10Hz（同 iOS 卡片上的 .task 循环），页面存活期间常驻、内部自查要不要走 */
  private autoNextTimer: number = -1;

  // —— 进度条缩略图（对应 iOS TrickplayImages / loadTrickplay）——
  private trickplay: TrickplayTiles = new TrickplayTiles();
  /** 轮询代数：换集 / 重协商后旧轮询作废 */
  private trickplayGen: number = 0;
  /** 雪碧图异步就位后驱动预览刷新的版本号 */
  @Local private trickplayVersion: number = 0;

  // —— 手势层（对应 iOS PlayerGestureLayer 的 GestureView 状态机，阈值原样照搬）——
  /** 移动超过这个距离才算拖动（12pt） */
  private static readonly activatePx: number = 12;
  /** 上下边缘 32vp 内起手交给系统（控制中心 / 主屏幕手势） */
  private static readonly edgeGuard: number = 32;
  /** 双击窗口 300ms */
  private static readonly doubleTapWindow: number = 300;
  /** 长按 500ms 起 2 倍速 */
  private static readonly holdDelay: number = 500;
  /** 竖滑调节：满量程 = 可用高度 × 60% */
  private static readonly fullSweepRatio: number = 0.6;
  /** 竖滑调节起手排除带：顶部 12%、底部 24%（进度条与控制区） */
  private static readonly adjustTopExclude: number = 0.12;
  private static readonly adjustBottomExclude: number = 0.24;
  /** 横滑拖进度：满屏一划 = 90 秒（同 Web FULL_SWEEP_SEEK_S） */
  private static readonly fullSweepSeekMs: number = 90000;

  private gestureTracking: boolean = false;
  private gestureTouchId: number = -1;
  private gestureStartX: number = 0;
  private gestureStartY: number = 0;
  /** undecided = 未定 | scrub = 横滑拖进度 | adjust = 竖滑调节 | hold = 长按倍速 */
  private gestureIntent: string = 'undecided';
  private holdTimer: number = -1;
  private lastTapAt: number = 0;
  /** 双击跳转后控制层要恢复成第一下点之前的样式（iOS lastTapChromeState） */
  private lastTapChromeState: boolean = true;
  /** 手势层尺寸（判定排除带与满量程都要用） */
  private layerWidth: number = 0;
  private layerHeight: number = 0;
  /** 手势层在窗口里的原点：把控制条测出来的全局坐标换算回手势层坐标系 */
  private layerOriginX: number = 0;
  private layerOriginY: number = 0;
  /*
   * 控制条可见时的三个「禁区」纵向范围（对应 iOS `gestureExclusions` 的
   * topBarFrame / bottomBarFrame + ArkUI 特有的中央三键区）：
   * ArkUI 的 `HitTestMode.Transparent` 会把按钮上的触摸也送一份给下层手势层，
   * 而 UIKit 命中测试只给最上层的按钮——所以鸿蒙侧必须把按钮区显式排除，
   * 净行为才与 iOS 一致：按钮吃自己的点，空白处归手势层。
   */
  private chromeTopY: number[] = [0, 0];
  private chromeCenterY: number[] = [0, 0];
  private chromeCenterX: number[] = [0, 0];
  private chromeBottomY: number[] = [0, 0];

  /** 长按 2 倍速生效中（HUD 显示「2× 快进中」） */
  @Local private holdSpeedActive: boolean = false;
  /** 竖滑调节：'' = 无，'brightness' / 'volume' */
  @Local private adjustSide: string = '';
  @Local private adjustValue: number = 0;
  private adjustBase: number = 0;
  /** 调节胶囊松手 0.9 秒后收起 */
  private adjustHideTimer: number = -1;
  /** 横滑定位的落点（-1 = 没在拖）；松手才跳 */
  @Local private scrubMs: number = -1;
  private scrubBaseMs: number = 0;
  /** 亮度：窗口句柄 + 是否动过（退出时恢复跟随系统） */
  private brightnessWindow: window.Window | null = null;
  private brightnessTouched: boolean = false;

  // —— 错误页 / 同意弹窗 / 画质（iOS PlayerErrorView / PlayerConsentView / QualityOption）——
  /** 错误页的建议行（iOS errorSuggestion），与主文案分层显示 */
  @Local private errorSuggestion: string = '';
  /** 同意弹窗的「开启并播放」按钮在转圈 */
  @Local private consentSaving: boolean = false;
  /** 画质上限（0 = 自动/原画）。按条目记本机记忆，起播时回读（iOS QualityMemory） */
  @Local private maxHeight: number = 0;
  /** 横屏锁定（顶栏按钮切换；退出时恢复竖屏） */
  @Local private landscapeLocked: boolean = false;
  /** 屏幕常亮是否已设置（播放中开启，退出恢复） */
  private keptScreenOn: boolean = false;

  // —— 片段播放（刷片页「全屏观看」，iOS PlaybackClip）——
  private clipStartMs: number = 0;
  private clipEndMs: number = 0;
  /** 片段播完（completed 状态不会来——片段只是文件里的一段，自己看位置） */
  @Local private clipEnded: boolean = false;

  // —— 底栏进度条可拖（iOS PlayerProgressBar；仍是「松手才跳」）——
  private barDragging: boolean = false;
  private progressBarWidth: number = 0;

  // —— 会话心跳（iOS startPingLoop，15 秒一次）——
  private pingTimer: number = -1;

  // —— 诊断面板（iOS PlayerDiagnosticsPanel：开着「详情」时 2 秒拉一次快照）——
  @Local private diag: PlaybackDiagnosticsView | null = null;
  private diagTimer: number = -1;

  // —— 自绘字幕样式（本机外挂轨；流式轨由系统渲染改不了，iOS SubtitleStyle）——
  @Local private subFontScale: number = 5.2;
  @Local private subBottom: number = 8;
  @Local private subBackground: boolean = true;

  aboutToAppear(): void {
    // 雪碧图异步下载完 → 版本号 +1，驱动横滑预览重查一次
    this.trickplay.onSheetLoaded = (): void => {
      this.trickplayVersion++;
    };
    // 自绘字幕样式（本机外挂轨）：异步回读，慢一点也只是先按默认样式画
    PlayerPrefs.subtitleStyle().then((style: SubStyle): void => {
      this.subFontScale = style.fontScale;
      this.subBottom = style.bottomPercent;
      this.subBackground = style.background;
    });
  }

  aboutToDisappear(): void {
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
    this.disarmWatchdog();
    this.stopAutoNextClock();
    this.stopPingLoop();
    this.stopDiagnostics();
    this.trickplayGen++;
    // 离开播放器：补发一次 stop（服务端记下最后位置，续播点 / 「继续观看」靠它）
    if (this.progressStarted) {
      this.progressStarted = false;
      this.reportProgressEvent('stop');
    }
    this.stopReport();
    this.releasePlayer();
    this.stopSession();
  }

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  // MARK: 能力与协商

  /**
   * 如实上报本机能力。
   * 只报官方承诺的那一档（mp4/mkv/ts + H264/H265 + AAC/MP3），**不虚报**——
   * 虚报会让服务端判定「能直出」，结果播不了，用户看到的是黑屏而不是「需要转码」。
   */
  private capability(): ClientCapabilityIn {
    const cap: Capability = new Capability();
    const h264: VideoSupport = new VideoSupport();
    h264.codec = 'h264';
    h264.max_height = 2160;
    const h265: VideoSupport = new VideoSupport();
    h265.codec = 'hevc';
    h265.max_height = 2160;
    cap.video = [h264, h265];
    const aac: AudioSupport = new AudioSupport();
    aac.codec = 'aac';
    const mp3: AudioSupport = new AudioSupport();
    mp3.codec = 'mp3';
    cap.audio = [aac, mp3];
    cap.containers = ['mp4', 'mkv', 'ts'];
    // 杜比视界透传：AVCodec 未列 DV profile/RPU 处理，所以明确报 false，让服务端走转码
    cap.hdr_passthrough = false;
    cap.is_mobile = true;
    // 服务端回的转码地址是 HLS；AVPlayer 原生支持 HLS
    cap.native_hls = true;
    /*
     * `mse` 必须给**字符串**：后端的字段是 `mse: str = "full"`（非可空），
     * 传 null 会直接 422「request validation failed」。
     *
     * 值必须是 `"full"` 而不是 `"none"`（2026-10-06 实测踩坑）：
     * 后端把 `native_hls && is_mobile && mse == "none"` 组合识别成
     * **iOS Safari 老设备的原生 AVPlayer**（`uses_native_hls_player`），
     * 施加两条 AVFoundation 专属的保守策略——4K 一律降到 1080p、音轨强制
     * 重编码 AAC-LC 双声道——把本可直出的 4K HEVC 全部推进转码档。
     * 服务端 VAAPI 转码一坏（ffmpeg 起转即退），这些片子就一部都放不了。
     * 鸿蒙的能力申报来自 AVPlayer 官方文档，且客户端已实现 `failed_tiers`
     * 运行期降档回路（真实播放失败才降档），与后端注释里「现代客户端
     * 信任申报 + 真实失败回退」的 hls.js 路线一致，所以按现代客户端申报 `"full"`。
     * 副作用只有转码档失去「边转边收」的渐进分片优化（等整段，仅起播慢一点点）。
     */
    cap.mse = 'full';
    return cap;
  }

  private async negotiate(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      this.phase = PlayerPhase.failed;
      this.errorMessage = '还没有连上服务器';
      return;
    }
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
    if (this.shareSlug.length === 0 && !this.isClip() && !this.localFailedOnce && await this.tryStartLocal()) {
      return;
    }
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
      body.start_ms = this.startMs > 0 ? this.startMs : null;
      body.client = 'harmony';
      // 选了非默认音轨要把 ref 带回去：后端会重新判定档位（选轨可能把直出顶成重封装）
      body.audio_track = this.audioRef.length > 0 ? this.audioRef : null;
      // 画质上限：语义是上限而非目标——源不超所选档就照常直通，超了才转码降下去
      body.max_height = this.maxHeight > 0 ? this.maxHeight : null;
      // 传**空数组**而不是 null：后端是 `failed_tiers: list[int] = []`（不可空）。
      // 这已经是同一类错误的第二次（上一次是 season_number 传 null）——
      // **后端的默认值不可空时，客户端一律不能送 null**。
      body.failed_tiers = this.failedTiers;
      const view: PlaybackSessionView = this.shareSlug.length > 0
        ? await api.sharePlaybackSessionStart(this.shareSlug, body)
        : await api.playbackSessionStart(body);
      this.session = view;
      // 服务端说这片要开软件转码：给同意弹窗（iOS handleSession 的 consent 分支），
      // 用户开了开关再重新协商
      if (view.decision.outcome === 'consent') {
        this.phase = PlayerPhase.consent;
        return;
      }
      const url: string | null = view.stream_url ?? null;
      if (url === null || url.length === 0) {
        this.phase = PlayerPhase.failed;
        // 服务端说不能放时，把它的理由原样给用户——比「播放失败」有用得多
        this.errorMessage = view.decision.reason.length > 0
          ? view.decision.reason
          : '服务端没有给出可播放的地址';
        this.errorSuggestion = view.decision.suggestion ?? '';
        return;
      }
      this.phase = PlayerPhase.ready;
      this.loadItemInfo();
      this.loadEpisodes();
      this.loadTrickplay();
      this.startAutoNextClock();
      await this.attachPlayer(AppModel.origin() + url);
    } catch (error) {
      this.phase = PlayerPhase.failed;
      this.errorMessage = this.messageOf(error);
      this.errorSuggestion = '';
    }
  }

  private messageOf(error: Object): string {
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
  private async tryStartLocal(): Promise<boolean> {
    const store: OfflineStore = OfflineStore.shared;
    if (!this.awaitedOfflineStore) {
      this.awaitedOfflineStore = true;
      await store.waitUntilLoaded();
    }
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
    this.closeLocalFile();
    const file: fileIo.File | null = this.openLocalFile(media);
    if (file === null) {
      return false;
    }
    this.localFile = file;
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
    await this.attachLocalPlayer(file.fd, -1);
    return true;
  }

  /**
   * 本机续播点：详情页带进来的位置最准；否则问服务端（2 秒竞速，离线不干等），
   * 再退到本机 progress.json 里记的（对应 iOS resume 的服务端优先 + 超时回落）。
   */
  private async localResumeMs(store: OfflineStore, unit: OfflineUnit): Promise<number> {
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
  private raceResume(promise: Promise<PlaybackStateView>): Promise<PlaybackStateView | null> {
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
  private localSessionView(spec: OfflinePlaybackSpec, startMs: number): PlaybackSessionView {
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
      timeline: '',
      subtitle_urls: [],
      chapters: this.parseChapters(spec.chaptersJson),
      segments: this.parseSegments(spec.segmentsJson)
    };
    return view;
  }

  private parseAudioTracks(json: string): AudioTrackView[] {
    if (json.length === 0 || json === 'null') {
      return [];
    }
    const list: AudioTrackView[] = JSON.parse(json) as AudioTrackView[];
    return Array.isArray(list) ? list : [];
  }

  private parseChapters(json: string): PlaybackChapterMarkView[] {
    if (json.length === 0 || json === 'null') {
      return [];
    }
    const list: PlaybackChapterMarkView[] = JSON.parse(json) as PlaybackChapterMarkView[];
    return Array.isArray(list) ? list : [];
  }

  private parseSegments(json: string): PlaybackSegmentView[] | null {
    if (json.length === 0 || json === 'null') {
      return null;
    }
    const list: PlaybackSegmentView[] = JSON.parse(json) as PlaybackSegmentView[];
    return Array.isArray(list) ? list : null;
  }

  private openLocalFile(path: string): fileIo.File | null {
    try {
      return fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    } catch (error) {
      return null;
    }
  }

  /** 关掉本机媒体 / 字幕句柄（换集、退出、回退服务端时；fdSrc 播放期间不能关） */
  private closeLocalFile(): void {
    const media: fileIo.File | null = this.localFile;
    this.localFile = null;
    if (media !== null) {
      try {
        fileIo.closeSync(media);
      } catch (error) {
      }
    }
    const subtitle: fileIo.File | null = this.subtitleFile;
    this.subtitleFile = null;
    if (subtitle !== null) {
      try {
        fileIo.closeSync(subtitle);
      } catch (error) {
      }
    }
  }

  // MARK: 播放器

  /** 把 AVPlayer 挂到 XComponent 的 surface 上并起播 */
  private async attachPlayer(url: string): Promise<void> {
    if (this.surfaceId.length === 0) {
      // surface 还没就绪（onLoad 还没回调），等它回调时再挂
      return;
    }
    await this.releasePlayer();
    const player: media.AVPlayer = await media.createAVPlayer();
    this.avPlayer = player;
    this.bindPlayerEvents(player);
    player.url = url;
    // 起播位置由服务端算好（直出没有会话时间轴，续播位置也得前端自己 seek）
    const resume: number = (this.session !== null ? this.session.start_ms : 0);
    if (resume > 0) {
      player.seek(resume, media.SeekMode.SEEK_CLOSEST);
    }
  }

  /**
   * 本机文件起播（fdSrc）。外挂字幕只支持**播放前**设置：挂了字幕时先拦住
   * prepare（deferPrepare），等 addSubtitleFromFd 完成再放行，顺序才可靠。
   */
  private async attachLocalPlayer(fd: number, subtitleFd: number): Promise<void> {
    if (this.surfaceId.length === 0) {
      // surface 还没就绪：VideoSurface.onLoad 会拿着句柄再挂一次
      return;
    }
    await this.releasePlayer();
    const player: media.AVPlayer = await media.createAVPlayer();
    this.avPlayer = player;
    this.deferPrepare = subtitleFd >= 0;
    this.bindPlayerEvents(player);
    player.fdSrc = { fd: fd, offset: 0, length: OfflineDisk.fileSize(this.localMediaPath) };
    if (subtitleFd >= 0) {
      try {
        await player.addSubtitleFromFd(subtitleFd);
      } catch (error) {
        this.toast('字幕加载失败');
      }
      this.deferPrepare = false;
      // initialized 已回调过（prepare 被拦住了）：这里补上；
      // 还没回调也不用管，stateChange 里 deferPrepare 已放行
      if (player.state === 'initialized') {
        player.prepare();
      }
    }
  }

  private bindPlayerEvents(player: media.AVPlayer): void {
    player.on('stateChange', (state: string): void => {
      if (state === 'initialized') {
        this.armWatchdog();
        player.surfaceId = this.surfaceId;
        // 外挂字幕要抢在 prepare 前挂（挂完由 attachLocalPlayer 放行）
        if (!this.deferPrepare) {
          player.prepare();
        }
      } else if (state === 'prepared') {
        this.durationMs = player.duration;
        // 本机重建播放器的续位点（流式的续播在 attachPlayer 里跳过了）
        if (this.pendingSeekMs > 0) {
          player.seek(this.pendingSeekMs, media.SeekMode.SEEK_CLOSEST);
          this.pendingSeekMs = -1;
        }
        player.play();
      } else if (state === 'playing') {
        this.disarmWatchdog();
        this.ended = false;
        this.playing = true;
        this.startReport();
        // 播放期间屏幕常亮（iOS isIdleTimerDisabled），退出时恢复
        this.keepScreenOn();
        // 流式播放首次起播：报一次 start（服务端由此记「在播」，续播点 / 活动页都靠后续 progress）；
        // 片段播放不报——刷一段不该动正片的观看记录
        if (!this.progressStarted && this.viewingRecorder === null && !this.isClip()) {
          this.progressStarted = true;
          this.reportProgressEvent('start');
        }
        // 会话心跳：15 秒一次，会话被回收时原位重开（iOS startPingLoop）
        this.startPingLoop();
        this.armChromeTimer();
        // 后台播放：AVSession + 长时任务（缺一个退后台就会被系统停掉）
        this.ensureGuard().then((guard: PlaybackGuard): Promise<void> => {
          return guard.start(this.title.length > 0 ? this.title : '播放');
        }).catch((): void => {
        });
        this.enableAutoPip();
      } else if (state === 'paused') {
        this.playing = false;
        // 本机播放：暂停立即结一次计时段（下一次 timeUpdate 要等恢复播放才有）
        const recorder: OfflineViewingRecorder | null = this.viewingRecorder;
        if (recorder !== null) {
          recorder.tick(this.positionMs, false, this.durationMs);
        }
        // 暂停时挂着的长按倍速要收掉（iOS：pause 会 endHoldSpeed）
        this.endHoldSpeed();
        // 暂停要**释放长时任务**（一直挂着会被系统判为滥用），恢复时重新申请
        const guard: PlaybackGuard | null = this.guard;
        if (guard !== null) {
          guard.pause().catch((): void => {
          });
        }
      } else if (state === 'completed') {
        // 播完了：「即将播放」卡片 / 自动连播的触发条件之一（iOS phase == .ended）
        this.ended = true;
        this.playing = false;
        // 本机播放：播完先落一次完整记录（退出前被系统回收也不丢「看完」）
        const recorder: OfflineViewingRecorder | null = this.viewingRecorder;
        if (recorder !== null) {
          recorder.finish(this.positionMs, true);
        }
        const guard: PlaybackGuard | null = this.guard;
        if (guard !== null) {
          guard.pause().catch((): void => {
          });
        }
      } else if (state === 'error') {
        this.onPlaybackFailed('播放器无法解码这一档');
      }
    });
    // 视频尺寸：拿到真实的宽高比，surface 才不会把画面拉变形
    player.on('videoSizeChange', (width: number, height: number): void => {
      if (width > 0 && height > 0) {
        this.videoAspect = width / height;
      }
    });
    player.on('timeUpdate', (time: number): void => {
      this.positionMs = time;
      // 本机播放的秒级计时（观看时长只在播放中的墙钟时间里累计）
      const recorder: OfflineViewingRecorder | null = this.viewingRecorder;
      if (recorder !== null) {
        recorder.tick(time, this.playing, this.durationMs);
      }
      // 片段播放：到片段终点就停（completed 状态不会来），出「重播 / 看全片」卡
      if (this.isClip() && !this.clipEnded && time >= this.clipEndMs) {
        this.clipEnded = true;
        player.pause();
      }
    });
    // 本机外挂字幕：系统只回调文本不代画，界面自己渲染（见 build 里的字幕条）
    player.on('subtitleUpdate', (info: media.SubtitleInfo): void => {
      this.subtitleCue = info !== undefined && info !== null
        && info.text !== undefined ? info.text : '';
    });
    // 音频焦点：来电 / 别的应用抢焦点时暂停，中断结束再恢复（不处理的话行为不可控）
    player.on('audioInterrupt', (event: audio.InterruptEvent): void => {
      const guard: PlaybackGuard | null = this.guard;
      if (guard !== null) {
        guard.handleInterrupt(event);
      }
    });
    player.on('error', (error: BusinessError): void => {
      this.onPlaybackFailed(error.message);
    });
  }

  /**
   * 这一档放不了：**把失败档位报回服务端再要一次**（后端的「运行期降档回路」）。
   *
   * 这条回路是契约的一部分，上一版漏了——于是服务端判的档一旦失败，
   * 客户端只会把原始错误摊给用户，而**不会去要一个它能放的档**。
   * 只重试一次，避免在「每一档都放不了」时来回打转。
   */
  private onPlaybackFailed(reason: string): void {
    this.disarmWatchdog();
    // 本机失败已在回退服务端的路上：后续连发的 error 一律吞掉（防并发协商）
    if (this.localFallingBack) {
      return;
    }
    // 本机副本放不了（文件坏 / 解码不动）：这一集不再试本机，直接回服务端流式
    if (this.localUnit !== null) {
      this.localFallingBack = true;
      this.localFailedOnce = true;
      this.toast('本机副本播放失败，正在改用服务器…');
      this.stopSession();
      this.releasePlayer().then((): void => {
        this.localFallingBack = false;
        this.negotiate();
      });
      return;
    }
    const view: PlaybackSessionView | null = this.session;
    const tier: number = view !== null ? (view.decision.tier ?? -1) : -1;
    if (tier < 0 || this.retryCount >= 1) {
      this.phase = PlayerPhase.failed;
      this.errorMessage = reason;
      // 建议行（iOS PlayerErrorView 的 suggestion）：服务端给了用它，没给用通用提示
      const suggestion: string | null = view !== null ? (view.decision.suggestion ?? null) : null;
      this.errorSuggestion = suggestion !== null && suggestion.length > 0
        ? suggestion : '可以点「重试」再试一次；反复出现请打开「详情」查看诊断';
      return;
    }
    this.retryCount++;
    this.failedTiers.push(tier);
    this.toast(`第 ${tier} 档放不了，正在换一档…`);
    this.stopSession();
    this.releasePlayer().then((): void => {
      this.negotiate();
    });
  }

  private async releasePlayer(): Promise<void> {
    const player: media.AVPlayer | null = this.avPlayer;
    if (player === null) {
      return;
    }
    this.avPlayer = null;
    try {
      await player.release();
    } catch (error) {
      // 释放失败无所谓，退出时会一起回收
    }
  }

  private togglePlay(): void {
    const player: media.AVPlayer | null = this.avPlayer;
    if (player === null) {
      return;
    }
    this.noteUserActivity();
    if (this.playing) {
      player.pause();
    } else {
      player.play();
    }
  }

  private seekTo(ms: number): void {
    const player: media.AVPlayer | null = this.avPlayer;
    if (player === null) {
      return;
    }
    this.noteUserActivity();
    let target: number = Math.max(0, Math.min(this.durationMs, ms));
    // 片段播放：跳转夹进片段区间（iOS PlaybackController.seek 的 clamp）
    if (this.isClip()) {
      target = Math.max(this.clipStartMs, Math.min(this.clipEndMs, target));
    }
    player.seek(target, media.SeekMode.SEEK_CLOSEST);
    this.positionMs = target;
  }

  /** 片段播放（刷片页「全屏观看」）：时间轴只算这一段，不报观看进度、不给画中画与「即将播放」 */
  private isClip(): boolean {
    return this.clipEndMs > this.clipStartMs;
  }

  // MARK: 下一集 / 自动连播（对应 iOS PlaybackController 的 upNext 一节）

  /** 片名（详情接口给的）：顶栏、锁屏与后台播控都用它 */
  private loadItemInfo(): void {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    const request: Promise<PlaybackItemView> = this.shareSlug.length > 0
      ? api.sharePlaybackItem(this.mediaItemId, this.shareSlug)
      : api.playbackItemInfo(this.mediaItemId);
    request.then((view: PlaybackItemView): void => {
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
  private loadEpisodes(): void {
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
      this.episodes = view.episodes;
    }).catch((): void => {
      this.episodes = [];
    });
  }

  /** 下一集只在**本季且有在位文件**里找——缺集跳过（同 Web player-page） */
  private nextEpisode(): EpisodeView | null {
    let best: EpisodeView | null = null;
    for (const episode of this.episodes) {
      if (episode.owned && episode.episode_number > this.episodeNumber
        && (best === null || episode.episode_number < best.episode_number)) {
        best = episode;
      }
    }
    return best;
  }

  private segments(): PlaybackSegmentView[] | null {
    const view: PlaybackSessionView | null = this.session;
    return view !== null ? (view.segments ?? null) : null;
  }

  /** 「即将播放」卡片：服务端认出了一直放到结尾的片尾时进了片尾就给，没认出就等播完再给 */
  private showsUpNext(): boolean {
    if (this.isClip()) {
      return false;
    }
    if (this.nextEpisode() === null || this.nextDismissed) {
      return false;
    }
    return SkipSegments.shouldShowUpNext(this.segments(), this.positionMs, this.ended);
  }

  /** 卡片要不要倒计时自动播下一集（连播满上限不倒计时，只提示） */
  private autoNextArmed(): boolean {
    return this.showsUpNext() && !this.autoNextCancelled
      && SkipSegments.autoNextArmed(this.segments(), this.positionMs, this.autoNextStreak, this.ended);
  }

  /** 连播满上限后放完了：不自动接，问一句「还在看吗」 */
  private asksStillWatching(): boolean {
    return this.ended && this.nextEpisode() !== null
      && this.autoNextStreak >= SkipSegments.autoNextMaxStreak;
  }

  /** 有人在操作：不算「没人管的连播」，连播计数清零 */
  private noteUserActivity(): void {
    this.autoNextStreak = 0;
  }

  /** 倒计时的钟：10Hz；暂停时不走、播完照走（片尾短于倒计时时不能卡在最后一帧） */
  private startAutoNextClock(): void {
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

  private stopAutoNextClock(): void {
    if (this.autoNextTimer >= 0) {
      clearInterval(this.autoNextTimer);
      this.autoNextTimer = -1;
    }
  }

  /** 换到下一集：重开会话（续播点由服务端按观看记录给），连播状态在 negotiate 里重置 */
  private playNext(): void {
    const next: EpisodeView | null = this.nextEpisode();
    if (next === null) {
      return;
    }
    // 离开当前单元：给旧集补发 stop（位置还是旧集的，要先于换集发）
    if (this.progressStarted) {
      this.progressStarted = false;
      this.reportProgressEvent('stop');
    }
    this.episodeNumber = next.episode_number;
    // 换集不指定文件：让服务端自己挑这集的在位文件（同 iOS startUnit）
    this.fileId = 0;
    this.startMs = 0;
    this.failedTiers = [];
    this.retryCount = 0;
    // 新的一集重新允许试本机副本（上一集的失败不作数）
    this.localFailedOnce = false;
    this.localFallingBack = false;
    this.stopSession();
    this.releasePlayer().then((): void => {
      this.negotiate();
    });
  }

  /** 卡片眉标：倒计时剩余秒数 / 「还在看吗」 */
  private upNextEyebrow(): string {
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
  private upNextStillUrl(): string {
    const next: EpisodeView | null = this.nextEpisode();
    const raw: string | null = next !== null ? (next.still_url ?? null) : null;
    const resolved: string | null = raw !== null
      ? ImageUrls.resolve(AppModel.origin(), raw, null) : null;
    return resolved !== null ? resolved : '';
  }

  /** 卡片第二行：第几集 */
  private upNextCode(): string {
    const next: EpisodeView | null = this.nextEpisode();
    return next !== null ? `第 ${next.episode_number} 集` : '';
  }

  /** 卡片第三行：集名（最多两行；没有就不占位） */
  private upNextName(): string {
    const next: EpisodeView | null = this.nextEpisode();
    return next !== null ? (next.name ?? '') : '';
  }

  /** 横屏（高度紧）：卡片收窄、不放剧照（同 iOS compact） */
  private isLandscape(): boolean {
    return this.layerWidth > this.layerHeight;
  }

  /** 「立即播放」按钮里倒计时白条的填充百分比 */
  private upNextFillPercent(): number {
    if (!this.autoNextArmed()) {
      return 100;
    }
    return Math.round(this.autoNextProgress * 1000) / 10;
  }

  // MARK: 进度条缩略图（对应 iOS loadTrickplay）

  /** 从已签名的取流地址里取 token（缩略图索引 / 雪碧图复用同一份授权） */
  private streamToken(): string {
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
  private loadTrickplay(): void {
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
  private scrubTile(): image.PixelMap | null {
    if (this.scrubMs < 0) {
      return null;
    }
    return this.trickplay.tileAt(this.scrubMs, AppModel.origin());
  }

  // MARK: 进度上报

  /** 每 10 秒报一次进度（对应 iOS 的进度上报；后端据此算「继续观看」） */
  /** 起播看门狗：25 秒还没出画就判这一档失败，走降档回路 */
  private armWatchdog(): void {
    this.disarmWatchdog();
    this.watchdog = setInterval((): void => {
      this.disarmWatchdog();
      this.onPlaybackFailed('这一档等了 25 秒还没出画（服务端可能没产出分片）');
    }, 25000);
  }

  private disarmWatchdog(): void {
    if (this.watchdog >= 0) {
      clearInterval(this.watchdog);
      this.watchdog = -1;
    }
  }

  /** 懒建合规壳；播放/暂停命令回灌给播放器（锁屏与通知栏的按钮要能用） */
  private async ensureGuard(): Promise<PlaybackGuard> {
    const existing: PlaybackGuard | null = this.guard;
    if (existing !== null) {
      return existing;
    }
    const context = getContext() as common.UIAbilityContext;
    const guard: PlaybackGuard = new PlaybackGuard(context,
      (): void => {
        const player: media.AVPlayer | null = this.avPlayer;
        if (player !== null) {
          player.play();
        }
      },
      (): void => {
        const player: media.AVPlayer | null = this.avPlayer;
        if (player !== null) {
          player.pause();
        }
      });
    this.guard = guard;
    return guard;
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
  private async enableAutoPip(): Promise<void> {
    // 片段播放不给画中画（iOS pictureInPictureAvailable 的 clip == nil）
    if (this.isClip()) {
      return;
    }
    const controller: PiPWindow.PiPController | null = await this.ensurePip();
    if (controller !== null) {
      controller.setAutoStartEnabled(true);
    }
  }

  private async ensurePip(): Promise<PiPWindow.PiPController | null> {
    const existing: PiPWindow.PiPController | null = this.pip;
    if (existing !== null) {
      return existing;
    }
    if (!PiPWindow.isPiPEnabled()) {
      // 这台设备不支持（部分设备 / 未开启），别硬来
      return null;
    }
    try {
      const context = getContext() as common.UIAbilityContext;
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

  private async togglePip(): Promise<void> {
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
  private async pickSubtitle(index: number): Promise<void> {
    const player: media.AVPlayer | null = this.avPlayer;
    const view: PlaybackSessionView | null = this.session;
    if (player === null || view === null) {
      this.showSheet = false;
      return;
    }
    this.showSheet = false;
    try {
      // 先关掉当前这条
      if (this.loadedSubtitleTrack >= 0) {
        await player.deselectTrack(this.loadedSubtitleTrack);
        this.loadedSubtitleTrack = -1;
      }
      if (index < 0) {
        this.subtitleIndex = -1;
        this.subtitleCue = '';
        // 本机外挂字幕：关掉要把播放器重建一遍（不带字幕轨），流式的 deselectTrack 就够
        if (this.localSpec !== null) {
          await this.rebuildLocalPlayer();
        } else {
          this.toast('已关闭字幕');
        }
        return;
      }
      // 本机副本：字幕文件就在包目录里，外挂字幕只支持播放前设置 → 重建播放器
      if (this.localSpec !== null) {
        await this.pickLocalSubtitle(index);
        return;
      }
      const urls: string[] = view.subtitle_urls;
      if (index >= urls.length) {
        this.toast('这条字幕没有可用的地址');
        return;
      }
      await player.addSubtitleFromUrl(AppModel.origin() + urls[index]);
      await this.activateSubtitleTrack(player, index);
    } catch (error) {
      const e = error as BusinessError;
      this.toast(`字幕切换失败（${e.code ?? -1}）`);
    }
  }

  /**
   * 本机副本的外挂字幕：字幕必须在 prepare 前挂（系统限制），播放中切字幕
   * 只能重建播放器并续位。句柄保持打开（重建后还要用），换集 / 退出时统一关。
   */
  private async pickLocalSubtitle(index: number): Promise<void> {
    const spec: OfflinePlaybackSpec | null = this.localSpec;
    const unit: OfflineUnit | null = this.localUnit;
    const mediaFile: fileIo.File | null = this.localFile;
    if (spec === null || unit === null || mediaFile === null) {
      return;
    }
    if (index >= spec.subtitles.length) {
      this.toast('这条字幕没有可用的地址');
      return;
    }
    const media: string | null = OfflineStore.shared.mediaPath(unit);
    if (media === null) {
      return;
    }
    const unitDir: string = media.substring(0, media.lastIndexOf('/'));
    const sub: OfflineSubtitleSpec = spec.subtitles[index];
    const path: string = `${unitDir}/subs/${sub.fileName}`;
    if (OfflineDisk.fileSize(path) <= 0) {
      this.toast('字幕文件丢了，重新下载这一集可以修复');
      return;
    }
    this.closeSubtitleFile();
    const file: fileIo.File | null = this.openLocalFile(path);
    if (file === null) {
      this.toast('字幕文件丢了，重新下载这一集可以修复');
      return;
    }
    this.subtitleFile = file;
    this.subtitleIndex = index;
    this.subtitleCue = '';
    this.toast('正在加载字幕…');
    await this.rebuildLocalPlayer();
  }

  /** 本机播放器重建（切 / 关外挂字幕用）：续位续到当前进度 */
  private async rebuildLocalPlayer(): Promise<void> {
    const mediaFile: fileIo.File | null = this.localFile;
    if (mediaFile === null) {
      return;
    }
    const subtitle: fileIo.File | null = this.subtitleFile;
    this.pendingSeekMs = this.positionMs > 0 ? this.positionMs : -1;
    this.loadedSubtitleTrack = -1;
    await this.attachLocalPlayer(mediaFile.fd, subtitle !== null ? subtitle.fd : -1);
  }

  private closeSubtitleFile(): void {
    const file: fileIo.File | null = this.subtitleFile;
    this.subtitleFile = null;
    if (file !== null) {
      try {
        fileIo.closeSync(file);
      } catch (error) {
      }
    }
  }

  /** 字幕加载完找轨号并选中（url / fd 两种加载方式共用） */
  private async activateSubtitleTrack(player: media.AVPlayer, index: number): Promise<void> {
    // 加载完再找出它的轨号
    const tracks: media.MediaDescription[] = await player.getTrackDescription();
    let found: number = -1;
    // 这两个键是**字符串字面量**（'track_type' / 'track_index'），不是 media 上的常量
    for (const track of tracks) {
      const kind: Object = track['track_type'];
      if (kind !== undefined && kind !== null
        && Number(kind) === media.MediaType.MEDIA_TYPE_SUBTITLE) {
        found = Number(track['track_index']);
      }
    }
    if (found < 0) {
      this.toast('字幕加载了但没找到轨，可能格式不支持');
      return;
    }
    await player.selectTrack(found);
    this.loadedSubtitleTrack = found;
    this.subtitleIndex = index;
    this.toast('字幕已切换');
  }

  /**
   * 切换音轨：**要重新协商一次**，不是本机切轨。
   *
   * 后端把 `audio_track` 当成决策输入——选了非默认轨可能把「直出」顶成「重封装」
   * （直出时浏览器只放默认轨，必须重封装才能把选中的那条带上），所以不能在前端硬切。
   * 记住档位失败台账，让重开时跳过已经失败过的档。
   */
  private async pickAudio(ref: string): Promise<void> {
    if (ref === this.audioRef) {
      this.showSheet = false;
      return;
    }
    this.audioRef = ref;
    this.showSheet = false;
    this.failedTiers = [];
    this.retryCount = 0;
    this.toast('正在按新音轨重开…');
    this.stopSession();
    await this.releasePlayer();
    await this.negotiate();
  }

  /** 音轨行的标题：语言 + 编码 + 声道 + 是否默认 */
  private audioLabel(track: AudioTrackView, index: number): string {
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

  private currentAudioLabel(): string {
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
  private chapterLabel(mark: PlaybackChapterMarkView): string {
    const title: string | null = mark.title ?? null;
    return title !== null && title.length > 0 ? title : this.clockText(mark.start_ms);
  }

  /** 字幕行的标题：语言 + 类型 + 是否 AI/默认 */
  private subtitleLabel(plan: SubtitlePlanView, index: number): string {
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
  private currentChapter(): string | null {
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
  private clockWithChapter(): string {
    const clock: string = this.clockText(this.displayPositionMs());
    const chapter: string | null = this.currentChapter();
    return chapter !== null ? `${clock} · ${chapter}` : clock;
  }

  /** 当前位置落在哪一段可跳过区间里（没有就是 null）。放到结尾的片尾不进这里（交给「即将播放」卡片） */
  private currentSegment(): PlaybackSegmentView | null {
    return SkipSegments.active(this.segments(), this.positionMs);
  }

  /** 按钮文案照后端的语义：片头 / 片尾 / 其他重复段 */
  private segmentLabel(segment: PlaybackSegmentView): string {
    if (segment.type === 'intro') {
      return '跳过片头';
    }
    if (segment.type === 'outro') {
      return '跳过片尾';
    }
    return '跳过';
  }

  /** 播放中 4 秒无操作自动收起控制条（同 iOS chrome 自动隐藏）；用户一动手就重置 */
  private armChromeTimer(): void {
    if (this.chromeTimer >= 0) {
      clearTimeout(this.chromeTimer);
      this.chromeTimer = -1;
    }
    if (!this.playing) {
      return;
    }
    this.chromeTimer = setTimeout((): void => {
      this.chromeTimer = -1;
      this.chromeVisible = false;
    }, 4000);
  }

  /** 控制条必须常显（同 Web chromeMustStayVisible）：用户暂停在找播放键、弹层开着在等选择 */
  private chromeMustStayVisible(): boolean {
    return (!this.playing && this.phase === PlayerPhase.ready) || this.showSheet;
  }

  // MARK: 手势层（对应 iOS PlayerGestureLayer）

  /** 长按 2 倍速能不能起：暂停时不行（松手按轻点处理） */
  private canHoldSpeed(): boolean {
    return this.playing && this.phase === PlayerPhase.ready && this.avPlayer !== null;
  }

  private beginHoldSpeed(): boolean {
    const player: media.AVPlayer | null = this.avPlayer;
    if (player === null || !this.playing || this.phase !== PlayerPhase.ready) {
      return false;
    }
    this.holdSpeedActive = true;
    player.setSpeed(media.PlaybackSpeed.SPEED_FORWARD_2_00_X);
    return true;
  }

  private endHoldSpeed(): void {
    if (!this.holdSpeedActive) {
      return;
    }
    this.holdSpeedActive = false;
    const player: media.AVPlayer | null = this.avPlayer;
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

  private disarmAdjustHide(): void {
    if (this.adjustHideTimer >= 0) {
      clearTimeout(this.adjustHideTimer);
      this.adjustHideTimer = -1;
    }
  }

  private vpOf(len: Length): number {
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
  private onGesture(event: TouchEvent): void {
    const touch: TouchObject | undefined = event.changedTouches[0];
    if (touch === undefined) {
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
      if (touch.y <= PlayerPage.edgeGuard
        || (this.layerHeight > 0 && touch.y >= this.layerHeight - PlayerPage.edgeGuard)) {
        return;
      }
      // 控制条可见时的禁区（iOS `point(inside:)` 的等价物）：整次触摸不归手势层
      if (this.chromeVisible && this.inChromeExclusion(touch.x, touch.y)) {
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
        }, PlayerPage.holdDelay);
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
        if (Math.max(Math.abs(dx), Math.abs(dy)) <= PlayerPage.activatePx) {
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
      if (this.gestureIntent === 'undecided') {
        if (!cancelled) {
          this.handleTap(touch.x / Math.max(1, this.layerWidth));
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

  /** 轻点：第一下永远是控制层开关（不为等双击延迟）；双击左右三分之一 = ∓10 秒 */
  private handleTap(xRatio: number): void {
    const now: number = Date.now();
    const isDouble: boolean = now - this.lastTapAt <= PlayerPage.doubleTapWindow;
    this.lastTapAt = isDouble ? 0 : now;
    if (isDouble && this.phase === PlayerPhase.ready) {
      if (xRatio < 1 / 3) {
        // 第一下切过的控制层恢复原状，净效果只剩跳转
        this.chromeVisible = this.lastTapChromeState;
        this.seekTo(this.positionMs - 10000);
      } else if (xRatio > 2 / 3) {
        this.chromeVisible = this.lastTapChromeState;
        this.seekTo(this.positionMs + 10000);
      } else if (!this.chromeMustStayVisible()) {
        this.chromeVisible = !this.chromeVisible;
      }
      if (this.chromeVisible) {
        this.armChromeTimer();
      }
      return;
    }
    this.lastTapChromeState = this.chromeVisible;
    if (this.chromeMustStayVisible()) {
      // 必须常显时只能唤出、收不起来
      this.chromeVisible = true;
    } else {
      this.chromeVisible = !this.chromeVisible;
    }
    if (this.chromeVisible) {
      this.armChromeTimer();
    }
  }

  /** 横滑定位：不唤出控制层、已开着的也收起（画面、落点读数才是在看的东西） */
  private scrubBegan(): void {
    this.scrubBaseMs = this.positionMs;
    this.scrubMs = this.positionMs;
    this.chromeVisible = false;
  }

  private scrubChanged(dx: number): void {
    if (this.durationMs <= 0) {
      return;
    }
    const delta: number = dx / Math.max(1, this.layerWidth) * PlayerPage.fullSweepSeekMs;
    const target: number = Math.max(0, Math.min(this.durationMs, this.scrubBaseMs + Math.floor(delta)));
    this.scrubMs = target;
  }

  private scrubEnded(cancelled: boolean): void {
    const target: number = this.scrubMs;
    this.scrubMs = -1;
    if (!cancelled && target >= 0) {
      this.seekTo(target);
    }
  }

  /** 横滑落点读数的小字：相对起点的增量（+/-） */
  private scrubDeltaText(): string {
    const delta: number = Math.round((this.scrubMs - this.scrubBaseMs) / 1000);
    const sign: string = delta >= 0 ? '+' : '-';
    return `${sign}${this.clockText(Math.abs(delta) * 1000)}`;
  }

  /** 竖滑调节的起手排除带（同 Web touch-adjust.ts）：顶部 12%、底部 24%、左右 32vp */
  private adjustAllowedAt(x: number, y: number): boolean {
    return y >= this.layerHeight * PlayerPage.adjustTopExclude
      && y <= this.layerHeight * (1 - PlayerPage.adjustBottomExclude)
      && x >= PlayerPage.edgeGuard && x <= this.layerWidth - PlayerPage.edgeGuard;
  }

  /** 控制条的 `onAreaChange` 换算：全局坐标 → 手势层坐标的纵向范围 */
  private bandOf(area: Area): number[] {
    const y: number = this.vpOf(area.globalPosition?.y ?? 0) - this.layerOriginY;
    return [y, y + this.vpOf(area.height)];
  }

  private inBand(v: number, band: number[]): boolean {
    return band[1] > band[0] && v >= band[0] && v <= band[1];
  }

  /** 控制条可见时的禁区：顶栏 / 底栏整条（全宽），中央三键只排按钮自己的横向范围 */
  private inChromeExclusion(x: number, y: number): boolean {
    return this.inBand(y, this.chromeTopY) || this.inBand(y, this.chromeBottomY)
      || (this.inBand(y, this.chromeCenterY) && x >= this.chromeCenterX[0] && x <= this.chromeCenterX[1]);
  }

  private adjustBegan(side: string): void {
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

  private adjustChanged(dy: number): void {
    if (this.adjustSide !== 'brightness') {
      return;
    }
    // 上滑为增：屏幕坐标 y 向下，取负
    const sweep: number = Math.max(1, this.layerHeight * PlayerPage.fullSweepRatio);
    const value: number = Math.max(0, Math.min(1, this.adjustBase + -dy / sweep));
    this.adjustValue = value;
    this.applyBrightness(value);
  }

  private adjustEnded(): void {
    // 松手 0.9 秒后收起胶囊；期间再有动作就重新计时
    this.disarmAdjustHide();
    this.adjustHideTimer = setTimeout((): void => {
      this.adjustHideTimer = -1;
      this.adjustSide = '';
    }, 900);
  }

  /** 当前亮度（0-1）：窗口自己设过的值优先；没设过（-1 = 跟随系统）就读系统设置的 0-255 */
  private currentBrightness(): number {
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

  private applyBrightness(value: number): void {
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
  private restoreBrightness(): void {
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

  private startReport(): void {
    if (this.reportTimer >= 0) {
      return;
    }
    this.reportTimer = setInterval((): void => {
      this.reportProgress();
    }, 10000);
  }

  private stopReport(): void {
    if (this.reportTimer >= 0) {
      clearInterval(this.reportTimer);
      this.reportTimer = -1;
    }
  }

  private reportProgress(): void {
    // 本机播放：进度由 OfflineViewingRecorder 记（timeUpdate 秒级 tick，先落盘再补传）
    if (this.viewingRecorder !== null) {
      return;
    }
    // 观看进度上报（同 iOS 10 秒 progress 循环）：续播点、「继续观看」、活动页「谁在播」心跳
    if (this.progressStarted && this.positionMs > 0) {
      this.reportProgressEvent('progress');
    }
    const api: MovieClawApi | null = this.api();
    const view: PlaybackSessionView | null = this.session;
    if (api === null || view === null || this.positionMs <= 0) {
      return;
    }
    if (this.shareSlug.length > 0) {
      // 访客播放没有站内播放指标接口；本机续播点已在 reportProgressEvent 里写过
      return;
    }
    // 上报失败不影响播放（离线一会儿也要能看完）
    api.playbackMetricReport({
      tier: view.decision.tier ?? 0,
      seek_count: 0
    }).catch((): void => {
    });
  }

  /**
   * 上报观看进度（start / progress / stop 同一入口，对应 iOS `PlaybackAPI.progress`）。
   * 三种事件走 `/playback/progress`（访客走 /share 路径）：服务端据此维护续播点、
   * 「继续观看」与活动页「谁在播」；管理员在活动页结束播放时靠响应里的 ended_by_admin 退出。
   */
  private reportProgressEvent(event: string): void {
    // 本机播放：进度由 OfflineViewingRecorder 记，不走实时上报
    if (this.viewingRecorder !== null) {
      return;
    }
    // 片段播放：不动观看记录（刷一段不该污染正片的续播点 / 已看状态）
    if (this.isClip()) {
      return;
    }
    const api: MovieClawApi | null = this.api();
    const view: PlaybackSessionView | null = this.session;
    if (api === null || view === null) {
      return;
    }
    const body: ProgressRequest = new ProgressRequest();
    body.media_item_id = this.mediaItemId;
    body.season_number = this.seasonNumber > 0 ? this.seasonNumber : null;
    body.episode_number = this.episodeNumber > 0 ? this.episodeNumber : null;
    body.event = event;
    body.position_ms = event === 'start' ? null : this.positionMs;
    // 音轨只报用户点选的（服务端默认挑的不报，报了会被当成用户选择记下——docs jellyfin-subtitle.md §3.3）
    body.audio_track = this.audioRef.length > 0 ? this.audioRef : null;
    body.file_id = view.decision.file_id ?? null;
    body.paused = event === 'progress' ? !this.playing : null;
    if (this.shareSlug.length > 0) {
      // 分享访客：位置记本机（续播点用，看完 90% 记 0 下次从头放）；服务端只收「谁在播」的心跳给活动页
      if (event !== 'start') {
        ShareLocalProgress.write(this.shareSlug, this.mediaItemId, this.seasonNumber,
          this.episodeNumber, this.shareLocalResume(this.positionMs, this.durationMs));
      }
      api.sharePlaybackProgress(this.shareSlug, body).then((state: PlaybackStateView): void => {
        this.handleProgressState(state);
      }).catch((): void => {
      });
    } else {
      api.playbackProgress(body).then((state: PlaybackStateView): void => {
        this.handleProgressState(state);
      }).catch((): void => {
      });
    }
  }

  /** 管理员在活动页结束了本次播放：原地停下并说明（同 iOS `handleProgressResponse`） */
  private handleProgressState(state: PlaybackStateView): void {
    if (!state.ended_by_admin || this.phase === PlayerPhase.failed) {
      return;
    }
    const player: media.AVPlayer | null = this.avPlayer;
    if (player !== null) {
      player.pause();
    }
    this.progressStarted = false;
    this.stopReport();
    this.phase = PlayerPhase.failed;
    this.errorMessage = '管理员已结束本次播放';
  }

  /** 分享访客的本机续播点：看过 90% 或到了片尾就记 0（下次从头放），同服务端 resolve_progress 的口径（iOS `localResume`） */
  private shareLocalResume(positionMs: number, durationMs: number): number {
    if (durationMs <= 0) {
      return positionMs;
    }
    return positionMs * 10 >= durationMs * 9 || positionMs >= durationMs - 1000 ? 0 : positionMs;
  }

  private stopSession(): void {
    // 本机播放收尾：观看记录落盘 + 关文件句柄（对应 iOS stopUnit 的本机分支）
    const recorder: OfflineViewingRecorder | null = this.viewingRecorder;
    if (recorder !== null) {
      this.viewingRecorder = null;
      recorder.finish(this.positionMs, this.ended);
    }
    this.closeLocalFile();
    this.closeSubtitleFile();
    this.localUnit = null;
    this.localSpec = null;
    this.localMediaPath = '';
    this.subtitleCue = '';
    const api: MovieClawApi | null = this.api();
    const view: PlaybackSessionView | null = this.session;
    const sessionId: string | null = view !== null ? (view.session_id ?? null) : null;
    if (this.shareSlug.length > 0) {
      // 访客收尾：位置记到本机（直出没有会话号也要记），转码会话再显式收掉
      ShareLocalProgress.write(this.shareSlug, this.mediaItemId, this.seasonNumber,
        this.episodeNumber, this.positionMs);
      if (api !== null && sessionId !== null && sessionId.length > 0) {
        api.sharePlaybackSessionStop(sessionId, this.shareSlug).catch((): void => {
        });
      }
      return;
    }
    if (api === null || sessionId === null || sessionId.length === 0) {
      return;
    }
    // 转码会话要显式收掉，不然服务端会一直转
    api.playbackSessionStop(sessionId).catch((): void => {
    });
  }

  // MARK: 屏幕常亮 / 方向（iOS PlayerSystemBridges）

  /** 播放期间保持屏幕常亮（iOS UIApplication.isIdleTimerDisabled） */
  private async keepScreenOn(): Promise<void> {
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
  private async allowScreenOff(): Promise<void> {
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
  private async toggleLandscape(): Promise<void> {
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
  private async restoreOrientation(): Promise<void> {
    if (!this.landscapeLocked) {
      return;
    }
    this.landscapeLocked = false;
    try {
      const win: window.Window = await window.getLastWindow(getContext(this));
      await win.setPreferredOrientation(window.Orientation.PORTRAIT);
    } catch (error) {
    }
  }

  // MARK: 会话心跳（iOS startPingLoop / ping）

  /**
   * 15 秒一次（同 iOS）。三态必须区分（同 Web pingPlaybackSession）：
   * - 200 = 还在（本机转码被判死时响应里另带 failed=true，据此直接降档）；
   * - 404 = 服务端明确说没了，要原位重开；
   * - 其他失败 = 这次请求本身失败，不能当成没了。
   */
  private startPingLoop(): void {
    this.stopPingLoop();
    const view: PlaybackSessionView | null = this.session;
    const sessionId: string | null = view !== null ? (view.session_id ?? null) : null;
    if (sessionId === null || sessionId.length === 0) {
      return;
    }
    this.pingTimer = setInterval((): void => {
      const api: MovieClawApi | null = this.api();
      const current: PlaybackSessionView | null = this.session;
      const id: string | null = current !== null ? (current.session_id ?? null) : null;
      if (api === null || id === null || id.length === 0 || id !== sessionId) {
        this.stopPingLoop();
        return;
      }
      const request: Promise<Record<string, JsonValue>> = this.shareSlug.length > 0
        ? api.sharePlaybackSessionPing(id, this.shareSlug)
        : api.playbackSessionPing(id);
      request.then((resp: Record<string, JsonValue>): void => {
        // 本机转码起步即退（issue #763）：这一档在这台机器上放不了，直接降档，
        // 不用等 25 秒看门狗
        if (jsonBoolValue(resp['failed']) === true) {
          const tier: number | null = current !== null ? (current.decision.tier ?? null) : null;
          if (tier !== null && this.failedTiers.indexOf(tier) < 0) {
            this.failedTiers.push(tier);
          }
          this.retryCount = 0;
          this.startMs = this.positionMs;
          this.toast('这一档转码失败了，正在换一档…');
          this.stopPingLoop();
          this.stopSession();
          this.releasePlayer().then((): void => {
            this.negotiate();
          });
        }
      }).catch((error: Object): void => {
        // 404 = 会话已被服务端回收（关页不发信号、超时回收是唯一可靠兜底）：原位重开；
        // 其他错误（断网/5xx）不能据此判定会话没了，等下一次心跳再看
        if (!(error instanceof ApiError) || error.status !== 404) {
          return;
        }
        this.stopPingLoop();
        this.startMs = this.positionMs;
        this.toast('会话过期了，正在重新打开…');
        this.stopSession();
        this.releasePlayer().then((): void => {
          this.negotiate();
        });
      });
    }, 15000);
  }

  private stopPingLoop(): void {
    if (this.pingTimer >= 0) {
      clearInterval(this.pingTimer);
      this.pingTimer = -1;
    }
  }

  // MARK: 错误重试 / 软件转码同意 / 画质（iOS retry / grantConsent / selectQuality）

  /** 错误页「重试」（iOS retry()）：清降档台账从当前位重协商 */
  private retryPlayback(): void {
    this.failedTiers = [];
    this.retryCount = 0;
    this.startMs = this.positionMs > 0 ? this.positionMs : this.startMs;
    this.errorMessage = '';
    this.errorSuggestion = '';
    this.negotiate();
  }

  /** 同意弹窗「开启并播放」（iOS grantConsent）：翻策略开关、校验回显、重新协商 */
  private async grantConsent(): Promise<void> {
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
  private qualityLabel(maxHeight: number): string {
    if (maxHeight <= 0) {
      return '自动（原画优先）';
    }
    return `${maxHeight}p`;
  }

  private qualityOptions(): QualityOption[] {
    return [
      new QualityOption('自动（原画优先）', 0),
      new QualityOption('1080p', 1080),
      new QualityOption('720p', 720),
      new QualityOption('480p', 480)
    ];
  }

  /** 换画质（iOS selectQuality + switchQuality）：记本机记忆，视频超上限时重开会话 */
  private async pickQuality(maxHeight: number): Promise<void> {
    this.showSheet = false;
    if (maxHeight === this.maxHeight) {
      return;
    }
    const previous: number = this.maxHeight;
    this.maxHeight = maxHeight;
    PlayerPrefs.writeQuality(this.mediaItemId, this.seasonNumber, this.episodeNumber, maxHeight);
    // 本机副本没有服务端档位，只记选择（下次流式起播生效）
    if (this.localUnit !== null) {
      return;
    }
    if (maxHeight <= 0 && previous <= 0) {
      return;
    }
    this.startMs = this.positionMs > 0 ? this.positionMs : this.startMs;
    this.failedTiers = [];
    this.retryCount = 0;
    this.toast('正在按新画质重开…');
    this.stopPingLoop();
    this.stopSession();
    await this.releasePlayer();
    await this.negotiate();
  }

  // MARK: 诊断面板（iOS PlayerDiagnosticsPanel，2 秒快照）

  private startDiagnostics(): void {
    this.stopDiagnostics();
    this.pollDiagnostics();
    this.diagTimer = setInterval((): void => {
      this.pollDiagnostics();
    }, 2000);
  }

  private stopDiagnostics(): void {
    if (this.diagTimer >= 0) {
      clearInterval(this.diagTimer);
      this.diagTimer = -1;
    }
  }

  private pollDiagnostics(): void {
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
      this.diag = snapshot;
    }).catch((): void => {
      // 拉不到就停在上一张快照
    });
  }

  /** 弹层开关的监听：详情面板开着就轮询，关了就停（iOS 只在面板开着时拉快照） */
  @Monitor('showSheet')
  onSheetVisibility(): void {
    if (this.showSheet && this.sheetKind === 'stats') {
      this.startDiagnostics();
      return;
    }
    this.stopDiagnostics();
    if (!this.showSheet) {
      this.diag = null;
    }
  }

  // 以下一行行文本都按 iOS PlayerDiagnosticsPanel 的 Section/ActionLine 排：
  // 面板里禁止局部声明，每行抽一个方法，空串 = 这一行不显示

  /** 「seg00012」（iOS segment()，五位补零） */
  private diagSegLabel(index: number | null | undefined): string {
    if (index === null || index === undefined || index < 0) {
      return '—';
    }
    const digits: string = `${index}`;
    return `seg${'0'.repeat(Math.max(0, 5 - digits.length))}${digits}`;
  }

  /** 处理方式标签（iOS processingLabels） */
  private diagProcessingLabel(mode: string): string {
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
  private diagLocationLabel(location: string): string {
    const labels: Record<string, string> = {
      'client': '客户端',
      'nas': 'NAS',
      'remote_worker': '远程 Worker'
    };
    return labels[location] ?? location;
  }

  /** 转码任务状态标签（iOS jobStateLabels） */
  private diagJobStateLabel(state: string): string {
    const labels: Record<string, string> = {
      'job.pending': '排队中',
      'job.accepted': '已接单',
      'job.progress': '转码中',
      'job.failed': '任务失败',
      'job.finished': '已完成'
    };
    return labels[state] ?? state;
  }

  private diagExecutionMode(): string {
    const d: PlaybackDiagnosticsView | null = this.diag;
    return d === null ? '' : this.diagProcessingLabel(d.processing_mode);
  }

  private diagLocation(): string {
    const d: PlaybackDiagnosticsView | null = this.diag;
    return d === null ? '' : `位置：${this.diagLocationLabel(d.execution_location)}`;
  }

  private diagBackendLine(): string {
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

  private diagWorkerLine(): string {
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

  private diagWorkerVersionLine(): string {
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

  private diagWorkerPlatformLine(): string {
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

  private diagJobLine(): string {
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

  private diagExitCodeLine(): string {
    const d: PlaybackDiagnosticsView | null = this.diag;
    if (d === null || d.job_exit_code === null || d.job_exit_code === undefined) {
      return '';
    }
    return `ffmpeg 退出码：${d.job_exit_code}`;
  }

  private diagJobErrorLine(): string {
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

  private diagStderrLine(): string {
    const d: PlaybackDiagnosticsView | null = this.diag;
    if (d === null) {
      return '';
    }
    const tail: string = d.job_stderr_tail ?? '';
    return tail.length === 0 ? '' : `ffmpeg stderr：${tail}`;
  }

  private diagSessionErrorLine(): string {
    const d: PlaybackDiagnosticsView | null = this.diag;
    return d === null ? '' : (d.session_error ?? '');
  }

  /** 供片区有没有内容（iOS：totalSegments 存在才出「供片」Section） */
  private diagHasSegments(): boolean {
    const d: PlaybackDiagnosticsView | null = this.diag;
    return d !== null && d.total_segments !== null && d.total_segments !== undefined;
  }

  private diagSupplyFirstLine(): string {
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

  private diagSupplyProducedLine(): string {
    const d: PlaybackDiagnosticsView | null = this.diag;
    if (d === null) {
      return '';
    }
    return `连续产出 ${this.diagSegLabel(d.highest_produced_segment)} · 头部 ${this.diagSegLabel(d.head_segment)} · 共 ${d.total_segments ?? 0} 段`;
  }

  private diagSupplyLeadLine(): string {
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

  private diagSupplyCacheLine(): string {
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

  private diagSupplyGapLine(): string {
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

  private diagSupplyHistoricalLine(): string {
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

  private diagSupplyUploadLine(): string {
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

  private diagSupplyUploadAlert(): boolean {
    const d: PlaybackDiagnosticsView | null = this.diag;
    return d !== null && d.recent_uploads.length > 0 && d.recent_uploads[0].status >= 400;
  }

  private diagSupplyWaitLine(): string {
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
  private replayClip(): void {
    const player: media.AVPlayer | null = this.avPlayer;
    if (player === null) {
      return;
    }
    this.clipEnded = false;
    this.seekTo(this.clipStartMs);
    player.play();
  }

  /** 看全片（iOS exitClip）：清片段区间重开会话，从当前位放整部片 */
  private exitClip(): void {
    this.clipStartMs = 0;
    this.clipEndMs = 0;
    this.clipEnded = false;
    this.ended = false;
    this.startMs = Math.max(0, this.positionMs);
    this.failedTiers = [];
    this.retryCount = 0;
    this.stopPingLoop();
    this.stopSession();
    this.releasePlayer().then((): void => {
      this.negotiate();
    });
  }

  /** 退出播放器前把片段进度写回共享状态（刷片页接着刚才看到的地方放） */
  private publishClipReturn(): void {
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
  private consentCostHint(): string {
    const view: PlaybackSessionView | null = this.session;
    const hint: string | null = view !== null ? (view.decision.cost_hint ?? null) : null;
    return hint !== null ? hint : '';
  }

  /** 能不能自己开软件转码（服务端的 can_self_enable） */
  private canSelfEnable(): boolean {
    const view: PlaybackSessionView | null = this.session;
    return view !== null && view.decision.can_self_enable === true;
  }

  private adjustSubtitleStyle(fontScaleDelta: number, bottomDelta: number): void {
    this.subFontScale = Math.min(10, Math.max(2, Math.round((this.subFontScale + fontScaleDelta) * 10) / 10));
    this.subBottom = Math.min(40, Math.max(0, this.subBottom + bottomDelta));
    const style: SubStyle = new SubStyle();
    style.fontScale = this.subFontScale;
    style.bottomPercent = this.subBottom;
    style.background = this.subBackground;
    PlayerPrefs.writeSubtitleStyle(style);
  }

  private toggleSubtitleBackground(): void {
    this.subBackground = !this.subBackground;
    this.adjustSubtitleStyle(0, 0);
  }

  // MARK: 派生

  /** 档位标签（iOS PlayerDiagnosticsPanel.tierLabels，0-4 三端通用） */
  private tierLabel(tier: number): string {
    const labels: string[] = ['原文件直出', '换壳直通', '换壳 + 转音轨', '硬件转码', '软件转码'];
    return tier >= 0 && tier < labels.length ? labels[tier] : `第 ${tier} 档`;
  }

  private streamLabel(): string {
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

  private clockText(ms: number): string {
    const total: number = Math.max(0, Math.floor(ms / 1000));
    const minutes: number = Math.floor(total / 60);
    const seconds: number = total % 60;
    return `${minutes}:${seconds < 10 ? '0' : ''}${seconds}`;
  }

  // MARK: 时间轴（片段播放时只算这一段：iOS timelineStartMs / timelineDurationMs）

  /** 时间轴上显示的位置（片段 = 原片位置减片段起点） */
  private displayPositionMs(): number {
    return this.isClip() ? Math.max(0, this.positionMs - this.clipStartMs) : this.positionMs;
  }

  /** 时间轴总长（片段 = 片段跨度，不是整部片） */
  private displayDurationMs(): number {
    return this.isClip() ? Math.max(0, this.clipEndMs - this.clipStartMs) : this.durationMs;
  }

  /** 横滑读数里的落点（同样换算到片段时间轴） */
  private displayScrubMs(): number {
    return this.isClip() ? Math.max(0, this.scrubMs - this.clipStartMs) : this.scrubMs;
  }

  private progressPercent(): number {
    const duration: number = this.displayDurationMs();
    return duration > 0 ? Math.round(this.displayPositionMs() * 100 / duration) : 0;
  }

  // MARK: 底栏进度条（iOS PlayerProgressBar：可拖，松手才跳）

  private onBarTouch(event: TouchEvent): void {
    const touch: TouchObject | undefined = event.changedTouches[0];
    if (touch === undefined) {
      return;
    }
    if (event.type === TouchType.Down) {
      if (this.displayDurationMs() <= 0) {
        return;
      }
      this.noteUserActivity();
      this.barDragging = true;
      this.scrubBaseMs = this.positionMs;
      this.barScrubTo(touch.x);
      return;
    }
    if (!this.barDragging) {
      return;
    }
    if (event.type === TouchType.Move) {
      this.armChromeTimer();
      this.barScrubTo(touch.x);
      return;
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.barDragging = false;
      const target: number = this.scrubMs;
      this.scrubMs = -1;
      if (event.type === TouchType.Up && target >= 0) {
        this.seekTo(target);
      }
    }
  }

  /** 拖动进度条：触点位置 → 时间轴时间（片段换算回原片时间轴再夹区间） */
  private barScrubTo(x: number): void {
    const duration: number = this.displayDurationMs();
    if (duration <= 0) {
      return;
    }
    const width: number = Math.max(1, this.progressBarWidth);
    const ratio: number = Math.max(0, Math.min(1, x / width));
    const timelineMs: number = Math.floor(ratio * duration);
    this.scrubMs = this.isClip() ? this.clipStartMs + timelineMs : timelineMs;
  }

  // MARK: 视图

  build() {
    NavDestination() {
      /*
       * 版式照 iOS `PlayerScreen`：**全屏视频 + 浮层控制条**（不是「上面视频、下面控制条」）。
       * ZStack 层次：视频 → 点击层 → 控制条浮层（含上下渐变）。
       */
      Stack({ alignContent: Alignment.Center }) {
        this.VideoSurface()
        // 手势层（iOS PlayerGestureLayer）：控制条上的按钮自己会吃掉触摸，落不到这一层，
        // 天然等价于 iOS 的「禁区」机制
        Column()
          .width('100%')
          .height('100%')
          .onAreaChange((_old: Area, newArea: Area) => {
            this.layerWidth = this.vpOf(newArea.width);
            this.layerHeight = this.vpOf(newArea.height);
            this.layerOriginX = this.vpOf(newArea.globalPosition?.x ?? 0);
            this.layerOriginY = this.vpOf(newArea.globalPosition?.y ?? 0);
          })
          .onTouch((event: TouchEvent) => {
            this.onGesture(event);
          })
        if (this.chromeVisible) {
          this.Controls()
        }
        // 本机外挂字幕：系统只回调文本不代画，自己画在底栏上方（控制条之下、常驻显示）。
        // 样式走本机偏好（iOS SubtitleStyle：字号 = 屏宽 × fontScale%、距底 bottomPercent%、背景开关）
        if (this.subtitleCue.length > 0 && this.localSpec !== null) {
          Text(this.subtitleCue)
            .fontSize(Math.max(12, this.subFontScale / 100 * this.layerWidth))
            .fontColor('#ffffff')
            .textAlign(TextAlign.Center)
            .maxLines(2)
            .padding({ left: 14, right: 14, top: 5, bottom: 5 })
            .backgroundColor(this.subBackground ? 'rgba(0,0,0,0.55)' : Color.Transparent)
            .borderRadius(6)
            .constraintSize({ maxWidth: '80%' })
            .hitTestBehavior(HitTestMode.None)
            .position({ x: '10%', y: `${Math.max(30, 100 - this.subBottom)}%` })
        }
        // 横滑定位的落点读数：整屏正中（与中央三键同一个中心，拖动时控制条已收起）
        if (this.scrubMs >= 0) {
          Column({ space: 4 }) {
            // 落点缩略图（雪碧图没就绪就不占位；版本号变化时重查一次）
            if (this.trickplayVersion >= 0 && this.scrubTile() !== null) {
              Image(this.scrubTile())
                .width(128)
                .height(72)
                .objectFit(ImageFit.Cover)
                .borderRadius(10)
            }
            Text(this.clockText(this.displayScrubMs()))
              .fontSize(22)
              .fontWeight(600)
              .fontColor('#ffffff')
            Text(this.scrubDeltaText())
              .fontSize(12)
              .fontColor('rgba(255,255,255,0.7)')
          }
          .padding({ left: 24, right: 24, top: 14, bottom: 14 })
          .backgroundColor('rgba(20,20,22,0.72)')
          .borderRadius(20)
          .hitTestBehavior(HitTestMode.None)
        }
        // 软件转码同意弹窗（iOS PlayerConsentView）：服务端说这片要开软件转码才给放
        if (this.phase === PlayerPhase.consent) {
          this.ConsentOverlay()
        }
        // 片段播完（iOS PlayerClipEndCard）：重播这一段 / 接着看全片
        if (this.clipEnded) {
          this.ClipEndCard()
        }
        this.TopHud()
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#000000')
      /*
       * 片尾「即将播放」卡片（iOS PlayerUpNextCard）：独立浮层，不随控制层收起；
       * 右下角、底栏上方。overlay 只包卡片本身——卡片外的触摸落不到 overlay 上，
       * 天然穿透到手势层。
       */
      .overlay(this.UpNextOverlay(), { align: Alignment.BottomEnd })
      /*
       * **一个组件只能绑一个 `bindSheet`**（后绑的覆盖前面的，第 23 轮在媒体库页踩过）。
       * 这里本来就绑了两个（字幕 / 详情），所以字幕面板一直打不开——合成单槽位 + 内容切换。
       */
      .bindSheet($$this.showSheet, this.SheetContent(), {
        height: SheetSize.MEDIUM,
        dragBar: true,
        showClose: false,
        backgroundColor: Theme.bg
      })
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
      // 整屏页：收起底部标签栏（iOS 同款行为）
      this.chrome.push('player');
      const params: PlayerParams | null = PlayerParams.of(ctx.pathInfo.param as Object | undefined);
      if (params !== null && !this.started) {
        this.started = true;
        this.mediaItemId = params.mediaItemId;
        this.fileId = params.fileId;
        this.seasonNumber = params.seasonNumber;
        this.episodeNumber = params.episodeNumber;
        this.startMs = params.startMs;
        this.shareSlug = params.shareSlug;
        this.clipStartMs = params.clipStartMs;
        this.clipEndMs = params.clipEndMs;
        // 片段播放：起播位 = 片段起点（时间轴只算这一段）
        if (this.isClip()) {
          this.startMs = this.clipStartMs;
        }
        this.negotiate();
      }
    })
    .onWillDisappear((): void => {
      // 退出前把片段进度写回（得赶在底下的刷片页重新显示之前）
      this.publishClipReturn();
    })
  }

  /**
   * 视频面：**必须是 `XComponent(type: SURFACE)`**。
   * 画中画要求 surface 可迁移；用 `Video` 组件或 AVPlayer 默认 surface 以后得推倒重来。
   */
  @Builder
  VideoSurface() {
    Stack({ alignContent: Alignment.Center }) {
      XComponent({
        id: 'movieclaw_player_surface',
        type: XComponentType.SURFACE,
        libraryname: '',
        controller: this.surfaceController
      })
        /*
         * **按视频比例摆放**：surface 是个画布，播放器会把画面铺满它——
         * 给全屏尺寸就会把 16:9 的片子拉成竖屏（实测过：测试图的圆变成了竖椭圆）。
         */
        .aspectRatio(this.videoAspect)
        .width('100%')
        .onLoad((): void => {
          // surface 就绪：记下 id，若协商已完成则立刻挂上播放器
          this.surfaceId = this.surfaceController.getXComponentSurfaceId();
          const view: PlaybackSessionView | null = this.session;
          const url: string | null = view !== null ? (view.stream_url ?? null) : null;
          if (url !== null && url.length > 0) {
            this.attachPlayer(AppModel.origin() + url);
            return;
          }
          // 本机副本的会话没有 stream_url：fdSrc 的播放器也要等 surface 就绪才挂
          const media: fileIo.File | null = this.localFile;
          if (media !== null) {
            const subtitle: fileIo.File | null = this.subtitleFile;
            this.attachLocalPlayer(media.fd, subtitle !== null ? subtitle.fd : -1);
          }
        })

      if (this.phase === PlayerPhase.negotiating) {
        Column({ space: 10 }) {
          LoadingProgress().width(30).height(30).color('#ffffff')
          Text('正在判定播放方式…')
            .fontSize(13)
            .fontColor('rgba(255,255,255,0.7)')
        }
      } else if (this.phase === PlayerPhase.failed) {
        Column({ space: 10 }) {
          SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
            .fontSize(28)
            .fontColor(['rgba(255,255,255,0.6)'])
          Text('放不了')
            .fontSize(16)
            .fontWeight(600)
            .fontColor('#ffffff')
          Text(this.errorMessage)
            .fontSize(13)
            .fontColor('rgba(255,255,255,0.7)')
            .textAlign(TextAlign.Center)
            .padding({ left: 32, right: 32 })
          if (this.errorSuggestion.length > 0) {
            Text(this.errorSuggestion)
              .fontSize(12)
              .fontColor('rgba(255,255,255,0.45)')
              .textAlign(TextAlign.Center)
              .padding({ left: 40, right: 40 })
          }
          // 返回 + 重试（iOS PlayerErrorView 的两颗等宽按钮）
          Row({ space: 10 }) {
            Text('返回')
              .fontSize(14)
              .fontColor('#ffffff')
              .height(40)
              .layoutWeight(1)
              .textAlign(TextAlign.Center)
              .backgroundColor('rgba(255,255,255,0.14)')
              .borderRadius(20)
              .onClick(() => {
                this.navStack.pop();
              })
            Text('重试')
              .fontSize(14)
              .fontWeight(600)
              .fontColor('#000000')
              .height(40)
              .layoutWeight(1)
              .textAlign(TextAlign.Center)
              .backgroundColor('#ffffff')
              .borderRadius(20)
              .onClick(() => {
                this.retryPlayback();
              })
          }
          .width('60%')
          .margin({ top: 8 })
        }
      }
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 控制条：版式照 iOS `PlayerControls` 分三块（播放行为与手势一律不动，只重排控件）：
   * 顶栏 = 返回玻璃圆钮 + 片名/档位（左）……画中画（右）；
   * 中部 = 后退 / 播放暂停 / 前进 三颗居中；
   * 底部 = 进度条（已播/剩余贴两端）+ 一枚玻璃胶囊装 音轨/字幕/详情。
   */
  @Builder
  Controls() {
    /*
     * 浮层控制条（iOS `chrome`）：上下各一层渐变垫在文字下面，中间三个传输键，
     * 底下一根进度条 + 音轨/字幕/详情。**不再是「视频下面接一坨控制区」**——
     * 视频是全屏的，控制条浮在上面（点了画面就收起来）。
     */
    Stack({ alignContent: Alignment.Top }) {
      // 顶部渐变
      Column()
        .width('100%')
        .height(160)
        .linearGradient({ angle: 180, colors: [['rgba(0,0,0,0.75)', 0], ['rgba(0,0,0,0)', 1]] })
      // 底部渐变
      Column()
        .width('100%')
        .height(200)
        .linearGradient({ angle: 0, colors: [['rgba(0,0,0,0)', 0], ['rgba(0,0,0,0.7)', 1]] })
        .position({ x: 0, y: '100%' })
        .translate({ y: -200 })

      Column() {
        // —— 顶栏（iOS PlayerTopBar）：返回 + 片名/档位 …… 画中画 ——
        Row({ space: 12 }) {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(20)
            .fontColor(['#ffffff'])
            .width(40)
            .height(40)
            .backgroundColor('rgba(255,255,255,0.12)')
            .borderRadius(20)
            .onClick(() => {
              this.navStack.pop();
            })
          Column({ space: 2 }) {
            Text(this.title.length > 0 ? this.title : '播放')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor('#ffffff')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.streamLabel())
              .fontSize(11)
              .fontColor('rgba(255,255,255,0.65)')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          // 横竖屏切换（iOS 底栏的旋转圆钮）：显式锁进目标方向
          Text(this.landscapeLocked ? '竖屏' : '横屏')
            .fontSize(13)
            .fontColor('#ffffff')
            .height(40)
            .textAlign(TextAlign.Center)
            .padding({ left: 14, right: 14 })
            .backgroundColor('rgba(255,255,255,0.12)')
            .borderRadius(20)
            .onClick(() => {
              this.toggleLandscape();
            })
          // 华为符号表里没有画中画图标（`pip` 不存在），用同规格的玻璃文字钮
          Text(this.pipActive ? '退出小窗' : '画中画')
            .fontSize(13)
            .fontColor('#ffffff')
            .height(40)
            .textAlign(TextAlign.Center)
            .padding({ left: 14, right: 14 })
            .backgroundColor('rgba(255,255,255,0.12)')
            .borderRadius(20)
            .onClick(() => {
              this.armChromeTimer();
              this.togglePip();
            })
        }
        .width('100%')
        .onAreaChange((_old: Area, newArea: Area) => {
          this.chromeTopY = this.bandOf(newArea);
        })


        Blank()

        // —— 中部传输（iOS PlayerCenterControls：三颗居中，播放键更大）——
        Row({ space: 36 }) {
          SymbolGlyph($r('sys.symbol.gobackward_10'))
            .fontSize(26)
            .fontColor(['#ffffff'])
            .width(56)
            .height(56)
            .backgroundColor('rgba(255,255,255,0.12)')
            .borderRadius(28)
            .onClick(() => {
              this.armChromeTimer();
              this.seekTo(this.positionMs - 10000);
            })
          SymbolGlyph(this.playing ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
            .fontSize(34)
            .fontColor(['#ffffff'])
            .width(76)
            .height(76)
            .backgroundColor('rgba(255,255,255,0.16)')
            .borderRadius(38)
            .onClick(() => {
              this.armChromeTimer();
              this.togglePlay();
            })
          SymbolGlyph($r('sys.symbol.goforward_10'))
            .fontSize(26)
            .fontColor(['#ffffff'])
            .width(56)
            .height(56)
            .backgroundColor('rgba(255,255,255,0.12)')
            .borderRadius(28)
            .onClick(() => {
              this.armChromeTimer();
              this.seekTo(this.positionMs + 10000);
            })
        }
        .justifyContent(FlexAlign.Center)
        .onAreaChange((_old: Area, newArea: Area) => {
          this.chromeCenterY = this.bandOf(newArea);
          const x: number = this.vpOf(newArea.globalPosition?.x ?? 0) - this.layerOriginX;
          this.chromeCenterX = [x, x + this.vpOf(newArea.width)];
        })

        Blank()

        // —— 底栏（iOS PlayerBottomBar）：进度 + 时间 + 音轨/字幕/详情 ——
        Column({ space: 8 }) {
          // 跳过片头 / 片尾（区间是服务端整季比对认出来的，客户端只管用）
          if (this.currentSegment() !== null) {
            Row() {
              Blank()
              Text(this.segmentLabel(this.currentSegment() as PlaybackSegmentView))
                .fontSize(13)
                .fontColor('#ffffff')
                .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                .backgroundColor('rgba(255,255,255,0.18)')
                .borderRadius(18)
                .border({ width: 1, color: 'rgba(255,255,255,0.35)' })
                .onClick(() => {
                  this.armChromeTimer();
                  const segment: PlaybackSegmentView | null = this.currentSegment();
                  if (segment !== null) {
                    this.seekTo(segment.end_ms);
                  }
                })
            }
            .width('100%')
          }
          // 进度条（iOS PlayerProgressBar）：可拖，松手才跳（服务端 HLS 上拖动跟随会打爆转码器）。
          // 触摸带加高到 28vp（4vp 细条 + 圆点），不然手指按不准
          Column() {
            Stack({ alignContent: Alignment.Start }) {
              Column()
                .width('100%')
                .height(4)
                .backgroundColor('rgba(255,255,255,0.22)')
                .borderRadius(2)
              Column()
                .width(`${this.progressPercent()}%`)
                .height(4)
                .backgroundColor(Theme.accentStrong)
                .borderRadius(2)
              // 拖动圆点（iOS 12pt）：拖动中跟着落点走
              Column()
                .width(12)
                .height(12)
                .borderRadius(6)
                .backgroundColor('#ffffff')
                .position({ x: `${this.progressPercent()}%` })
                .translate({ x: -6, y: -4 })
            }
            .width('100%')
            .height(4)
          }
          .width('100%')
          .height(28)
          .justifyContent(FlexAlign.Center)
          .onAreaChange((_old: Area, newArea: Area) => {
            this.progressBarWidth = this.vpOf(newArea.width);
          })
          .onTouch((event: TouchEvent) => {
            this.onBarTouch(event);
          })
          Row({ space: 8 }) {
            // iOS 把**当前章节名接在时间后面**（`12:34 · Part 01`），不是拉一条章节带
            Text(this.clockWithChapter())
              .fontSize(12)
              .fontColor('rgba(255,255,255,0.85)')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            Blank()
            Text('-' + this.clockText(Math.max(0, this.displayDurationMs() - this.displayPositionMs())))
              .fontSize(12)
              .fontColor('rgba(255,255,255,0.85)')
          }
          .width('100%')
          Row({ space: 0 }) {
            this.CapsuleAction('音轨', this.audioRef.length > 0, (): void => {
              this.armChromeTimer();
              this.sheetKind = 'audio';
              this.showSheet = true;
            })
            this.CapsuleAction(this.subtitleIndex >= 0 ? '字幕 ✓' : '字幕', this.subtitleIndex >= 0,
              (): void => {
                this.armChromeTimer();
                this.sheetKind = 'subtitle';
                this.showSheet = true;
              })
            this.CapsuleAction(this.maxHeight > 0 ? `画质 ${this.maxHeight}p ✓` : '画质', this.maxHeight > 0,
              (): void => {
                this.armChromeTimer();
                this.sheetKind = 'quality';
                this.showSheet = true;
              })
            this.CapsuleAction('详情', false, (): void => {
              this.armChromeTimer();
              this.sheetKind = 'stats';
              this.showSheet = true;
            })
          }
          .backgroundColor('rgba(255,255,255,0.12)')
          .borderRadius(22)
        }
        .width('100%')
        .onAreaChange((_old: Area, newArea: Area) => {
          this.chromeBottomY = this.bandOf(newArea);
        })
      }
      .width('100%')
      .height('100%')
      .padding({ left: 16, right: 16, top: Theme.statusBarInset + 8, bottom: 16 })
    }
    .width('100%')
    .height('100%')
    /*
     * 穿透（iOS 的 SwiftUI 容器天然如此）：按钮自己吃触摸，渐变垫与空白处
     * 放行给下层手势层——不穿透的话这个全屏 Stack 会吞掉所有轻点，
     * 「点画面收控制条」永远不触发（模拟器实测踩过）。
     */
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /**
   * 片尾「即将播放」卡片（iOS PlayerUpNextCard，Netflix 同款）：
   * 左剧照 / 三行「即将播放 · N 秒 · 第 N 集 · 集名」/ 右上 ✕ = 不看下一集；
   * 底下「立即播放」——认出了片尾时这颗按钮就是倒计时进度条（白条从左往右填满自动换集），
   * 连播满上限后播完了不自动接，眉标改问「还在看吗？」。
   * 横屏（高度紧）不放剧照、卡片收窄。overlay 挂根 Stack 右下角，只包卡片本身。
   */
  @Builder
  UpNextOverlay() {
    if (this.showsUpNext()) {
      Column({ space: 12 }) {
        Row({ space: 12 }) {
          if (!this.isLandscape() && this.upNextStillUrl().length > 0) {
            RemoteImage({ url: this.upNextStillUrl() })
              .width(112)
              .height(63)
              .borderRadius(10)
              .clip(true)
          }
          Column({ space: 2 }) {
            Text(this.upNextEyebrow())
              .fontSize(11)
              .fontColor('rgba(255,255,255,0.5)')
            Text(this.upNextCode())
              .fontSize(13)
              .fontColor('rgba(255,255,255,0.7)')
            if (this.upNextName().length > 0) {
              Text(this.upNextName())
                .fontSize(15)
                .fontWeight(600)
                .fontColor('#ffffff')
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          // ✕ = 不看下一集，继续看片尾
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(13)
            .fontWeight(700)
            .fontColor(['rgba(255,255,255,0.8)'])
            .width(28)
            .height(28)
            .backgroundColor('rgba(255,255,255,0.14)')
            .borderRadius(14)
            .onClick(() => {
              this.noteUserActivity();
              this.nextDismissed = true;
              this.autoNextCancelled = true;
              this.autoNextProgress = 0;
            })
        }
        .alignItems(VerticalAlign.Top)

        // 「立即播放」：白底胶囊；倒计时中浅底 + 白条从左往右填（GeometryReader 那套 → 层叠）
        Stack({ alignContent: Alignment.Center }) {
          Row() {
            Column()
              .height(34)
              .width(this.upNextFillPercent() + '%')
              .backgroundColor('#ffffff')
          }
          .width('100%')
          .height(34)
          .backgroundColor('rgba(255,255,255,0.35)')
          .borderRadius(17)
          .clip(true)

          Row({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.play_fill'))
              .fontSize(12)
              .fontColor(['#000000'])
            Text('立即播放')
              .fontSize(13)
              .fontWeight(600)
              .fontColor('#000000')
          }
        }
        .width('100%')
        .onClick(() => {
          this.noteUserActivity();
          this.playNext();
        })
      }
      .alignItems(HorizontalAlign.End)
      .padding(14)
      .width(this.isLandscape() ? 252 : 300)
      .backgroundColor('rgba(20,20,22,0.78)')
      .borderRadius(26)
      .margin({ right: 16, bottom: 16 })
    }
  }

  /**
   * 顶部胶囊 HUD（iOS PlayerHUD）：长按倍速 / 竖滑调节。
   * 顶栏下方再隔一个间距，控制条开着也不压住顶栏。
   */
  @Builder
  TopHud() {
    Column() {
      if (this.holdSpeedActive) {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.fast_forward'))
            .fontSize(15)
            .fontColor(['#ffffff'])
          Text('2× 快进中')
            .fontSize(14)
            .fontColor('#ffffff')
        }
        .height(40)
        .padding({ left: 18, right: 18 })
        .backgroundColor('rgba(20,20,22,0.72)')
        .borderRadius(20)
      } else if (this.adjustSide.length > 0) {
        Row({ space: 10 }) {
          SymbolGlyph(this.adjustSide === 'brightness'
            ? $r('sys.symbol.sun_max_fill') : $r('sys.symbol.speaker_slash_fill'))
            .fontSize(16)
            .fontColor(['#ffffff'])
          if (this.adjustSide === 'brightness') {
            Row() {
              Column()
                .width(`${Math.round(this.adjustValue * 100)}%`)
                .height(4)
                .backgroundColor('#ffffff')
                .borderRadius(2)
            }
            .width(96)
            .height(4)
            .backgroundColor('rgba(255,255,255,0.28)')
            .borderRadius(2)
          } else {
            // 鸿蒙改不了系统音量：与 iOS 音量不可调时同款降级文案
            Text('音量由系统侧键控制')
              .fontSize(13)
              .fontColor('#ffffff')
          }
        }
        .height(40)
        .padding({ left: 18, right: 18 })
        .backgroundColor('rgba(20,20,22,0.72)')
        .borderRadius(20)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ top: Theme.statusBarInset + 56 })
    .hitTestBehavior(HitTestMode.None)
  }

  /**
   * 软件转码同意弹窗（iOS PlayerConsentView）：
   * 标题 + 服务端给的原因与代价；能自己开就给「开启并播放」（开启后校验回显再重协商），
   * 不能就只有「知道了」。
   */
  @Builder
  ConsentOverlay() {
    Column({ space: 14 }) {
      Text('这部片需要软件转码才能播放')
        .fontSize(18)
        .fontWeight(600)
        .fontColor('#ffffff')
        .textAlign(TextAlign.Center)
      if (this.session !== null) {
        if ((this.session as PlaybackSessionView).decision.reason.length > 0) {
          Text((this.session as PlaybackSessionView).decision.reason)
            .fontSize(13)
            .fontColor('rgba(255,255,255,0.7)')
            .textAlign(TextAlign.Center)
            .width('100%')
        }
        if (this.consentCostHint().length > 0) {
          Text(this.consentCostHint())
            .fontSize(12)
            .fontColor(Theme.warn)
            .textAlign(TextAlign.Center)
            .width('100%')
        }
      }
      if (this.canSelfEnable()) {
        Row({ space: 10 }) {
          Text('取消')
            .fontSize(14)
            .fontColor('#ffffff')
            .height(42)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .backgroundColor('rgba(255,255,255,0.14)')
            .borderRadius(21)
            .onClick(() => {
              this.navStack.pop();
            })
          Text(this.consentSaving ? '正在开启…' : '开启并播放')
            .fontSize(14)
            .fontWeight(600)
            .fontColor('#000000')
            .height(42)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .backgroundColor('#ffffff')
            .borderRadius(21)
            .onClick(() => {
              if (!this.consentSaving) {
                this.grantConsent();
              }
            })
        }
        .width('100%')
        .margin({ top: 4 })
        Text('开启后所有需要软件转码的影片都会直接播放')
          .fontSize(11)
          .fontColor('rgba(255,255,255,0.4)')
          .textAlign(TextAlign.Center)
          .width('100%')
      } else {
        Text('管理员没有开启软件转码，先看别的或联系管理员')
          .fontSize(12)
          .fontColor('rgba(255,255,255,0.55)')
          .textAlign(TextAlign.Center)
          .width('100%')
        Text('知道了')
          .fontSize(14)
          .fontWeight(600)
          .fontColor('#000000')
          .height(42)
          .padding({ left: 28, right: 28 })
          .textAlign(TextAlign.Center)
          .backgroundColor('#ffffff')
          .borderRadius(21)
          .margin({ top: 4 })
          .onClick(() => {
            this.navStack.pop();
          })
      }
    }
    .width('82%')
    .padding(22)
    .backgroundColor('rgba(20,20,22,0.92)')
    .borderRadius(24)
    .border({ width: 1, color: 'rgba(255,255,255,0.08)' })
  }

  /** 片段播完卡（iOS PlayerClipEndCard）：重播这一段 / 看全片 */
  @Builder
  ClipEndCard() {
    Column({ space: 12 }) {
      Text('这一段看完了')
        .fontSize(17)
        .fontWeight(600)
        .fontColor('#ffffff')
      Row({ space: 10 }) {
        Text('重播')
          .fontSize(14)
          .fontColor('#ffffff')
          .height(42)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .backgroundColor('rgba(255,255,255,0.14)')
          .borderRadius(21)
          .onClick(() => {
            this.replayClip();
          })
        Text('看全片')
          .fontSize(14)
          .fontWeight(600)
          .fontColor('#000000')
          .height(42)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .backgroundColor('#ffffff')
          .borderRadius(21)
          .onClick(() => {
            this.exitClip();
          })
      }
      .width('100%')
    }
    .width('70%')
    .padding(20)
    .backgroundColor('rgba(20,20,22,0.92)')
    .borderRadius(24)
    .border({ width: 1, color: 'rgba(255,255,255,0.08)' })
  }

  /** 底部胶囊里的一颗动作键（等分胶囊宽度，两端与胶囊端头同心） */
  @Builder
  CapsuleAction(label: string, active: boolean, onTap: () => void) {
    Text(label)
      .fontSize(13)
      .fontColor(active ? Theme.accentStrong : 'rgba(255,255,255,0.85)')
      .layoutWeight(1)
      .height(40)
      .textAlign(TextAlign.Center)
      .onClick(() => {
        onTap();
      })
  }

  /** 音轨选择：第一行是「跟随默认」，其余按后端给的序列出；insetGrouped 卡片 */
  @Builder
  AudioSheet() {
    Column({ space: 0 }) {
      Text('音轨')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .width('100%')
        .padding({ left: 20, top: 16, bottom: 8 })
      Text('换音轨会按新轨重开一次会话（可能要重新转码），播放位置会尽量保留')
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .width('100%')
        .padding({ left: 20, right: 20, bottom: 12 })
      List() {
        ListItemGroup({ style: ListItemGroupStyle.NONE }) {
          ListItem() {
            Row({ space: 10 }) {
              Text('跟随默认')
                .fontSize(16)
                .fontColor(Theme.text)
                .layoutWeight(1)
              if (this.audioRef.length === 0) {
                SymbolGlyph($r('sys.symbol.checkmark'))
                  .fontSize(16)
                  .fontColor([Theme.accent])
              }
            }
            .width('100%')
            .padding({ left: 20, right: 20, top: 13, bottom: 13 })
            .onClick(() => {
              this.pickAudio('');
            })
          }
          ForEach(this.session !== null
            ? (this.session as PlaybackSessionView).decision.audio_tracks
            : [], (track: AudioTrackView, index: number) => {
            ListItem() {
              Row({ space: 10 }) {
                Text(this.audioLabel(track, index))
                  .fontSize(15)
                  .fontColor(Theme.text)
                  .layoutWeight(1)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                if (this.audioRef === track.ref) {
                  SymbolGlyph($r('sys.symbol.checkmark'))
                    .fontSize(16)
                    .fontColor([Theme.accent])
                }
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
              .padding({ left: 20, right: 20, top: 13, bottom: 13 })
              .onClick(() => {
                this.pickAudio(track.ref);
              })
            }
          }, (track: AudioTrackView) => track.ref)
        }
        .divider({ strokeWidth: 0.5, color: Theme.line, startMargin: 20, endMargin: 20 })
        .borderRadius(Theme.cardRadius)
        .backgroundColor(Theme.surface)
        .border({ width: 1, color: Theme.line })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .padding({ left: 16, right: 16 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  /** 字幕选择：先「关闭」，再按后端给的序列出候选轨 */
  /** 唯一的弹层内容：按 sheetKind 切换 */
  @Builder
  SheetContent() {
    if (this.sheetKind === 'audio') {
      this.AudioSheet()
    } else if (this.sheetKind === 'subtitle') {
      this.SubtitleSheet()
    } else if (this.sheetKind === 'quality') {
      this.QualitySheet()
    } else {
      this.StatsSheet()
    }
  }

  /** 画质选择（iOS SettingsMenu 的「画质」面板）：语义是上限——源不超所选档就照常直通 */
  @Builder
  QualitySheet() {
    Column({ space: 0 }) {
      Text('画质')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .width('100%')
        .padding({ left: 20, top: 16, bottom: 8 })
      Text('选的是上限：源不超这一档就照常直出，超了才转码降下去；换画质会重开一次会话，位置会保留')
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .width('100%')
        .padding({ left: 20, right: 20, bottom: 12 })
      List() {
        ListItemGroup({ style: ListItemGroupStyle.NONE }) {
          ForEach(this.qualityOptions(), (option: QualityOption, index: number) => {
            ListItem() {
              Row({ space: 10 }) {
                Text(option.label)
                  .fontSize(16)
                  .fontColor(Theme.text)
                  .layoutWeight(1)
                if (this.maxHeight === option.maxHeight) {
                  SymbolGlyph($r('sys.symbol.checkmark'))
                    .fontSize(16)
                    .fontColor([Theme.accent])
                }
              }
              .width('100%')
              .padding({ left: 20, right: 20, top: 13, bottom: 13 })
              .onClick(() => {
                this.pickQuality(option.maxHeight);
              })
            }
          }, (option: QualityOption) => `${option.maxHeight}`)
        }
        .divider({ strokeWidth: 0.5, color: Theme.line, startMargin: 20, endMargin: 20 })
        .borderRadius(Theme.cardRadius)
        .backgroundColor(Theme.surface)
        .border({ width: 1, color: Theme.line })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .padding({ left: 16, right: 16 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  @Builder
  SubtitleSheet() {
    Column({ space: 0 }) {
      Text('字幕')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .width('100%')
        .padding({ left: 20, top: 16, bottom: 8 })
      Text('列的是这一档能配的字幕；选中的会加载进播放器')
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .width('100%')
        .padding({ left: 20, right: 20, bottom: 12 })
      List() {
        ListItemGroup({ style: ListItemGroupStyle.NONE }) {
          ListItem() {
            Row({ space: 10 }) {
              Text('关闭字幕')
                .fontSize(16)
                .fontColor(Theme.text)
                .layoutWeight(1)
              if (this.subtitleIndex < 0) {
                SymbolGlyph($r('sys.symbol.checkmark'))
                  .fontSize(16)
                  .fontColor([Theme.accent])
              }
            }
            .width('100%')
            .padding({ left: 20, right: 20, top: 13, bottom: 13 })
            .onClick(() => {
              this.pickSubtitle(-1);
            })
          }
          ForEach(this.session !== null
            ? (this.session as PlaybackSessionView).decision.subtitles
            : [], (plan: SubtitlePlanView, index: number) => {
            ListItem() {
              Row({ space: 10 }) {
                Text(this.subtitleLabel(plan, index))
                  .fontSize(15)
                  .fontColor(Theme.text)
                  .layoutWeight(1)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                if (this.subtitleIndex === index) {
                  SymbolGlyph($r('sys.symbol.checkmark'))
                    .fontSize(16)
                    .fontColor([Theme.accent])
                }
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
              .padding({ left: 20, right: 20, top: 13, bottom: 13 })
              .onClick(() => {
                this.pickSubtitle(index);
              })
            }
          }, (plan: SubtitlePlanView) => plan.track_ref)
        }
        .divider({ strokeWidth: 0.5, color: Theme.line, startMargin: 20, endMargin: 20 })
        .borderRadius(Theme.cardRadius)
        .backgroundColor(Theme.surface)
        .border({ width: 1, color: Theme.line })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .padding({ left: 16, right: 16 })
      // 自绘字幕样式（iOS SubtitleStyleEditor）：只对**本机外挂轨**有效——
      // 流式轨由系统渲染，客户端改不了样式，这里不显示
      if (this.localSpec !== null) {
        List() {
          ListItemGroup({ style: ListItemGroupStyle.NONE }) {
            ListItem() {
              Row() {
                Text('字号')
                  .fontSize(15)
                  .fontColor(Theme.text)
                  .layoutWeight(1)
                this.StyleStepButton('−', (): void => {
                  this.adjustSubtitleStyle(-0.4, 0);
                })
                Text(`${Math.round(this.subFontScale * 10) / 10}`)
                  .fontSize(13)
                  .fontColor(Theme.textMuted)
                  .width(52)
                  .textAlign(TextAlign.Center)
                this.StyleStepButton('+', (): void => {
                  this.adjustSubtitleStyle(0.4, 0);
                })
              }
              .width('100%')
              .padding({ left: 20, right: 20, top: 10, bottom: 10 })
            }
            ListItem() {
              Row() {
                Text('位置（距底部）')
                  .fontSize(15)
                  .fontColor(Theme.text)
                  .layoutWeight(1)
                this.StyleStepButton('−', (): void => {
                  this.adjustSubtitleStyle(0, -2);
                })
                Text(`${this.subBottom}%`)
                  .fontSize(13)
                  .fontColor(Theme.textMuted)
                  .width(52)
                  .textAlign(TextAlign.Center)
                this.StyleStepButton('+', (): void => {
                  this.adjustSubtitleStyle(0, 2);
                })
              }
              .width('100%')
              .padding({ left: 20, right: 20, top: 10, bottom: 10 })
            }
            ListItem() {
              Row() {
                Text('黑底')
                  .fontSize(15)
                  .fontColor(Theme.text)
                  .layoutWeight(1)
                Text(this.subBackground ? '开' : '关')
                  .fontSize(13)
                  .fontColor(this.subBackground ? Theme.accentStrong : Theme.textFaint)
                  .padding({ left: 14, right: 14, top: 6, bottom: 6 })
                  .backgroundColor(Theme.surface)
                  .borderRadius(16)
                  .border({ width: 1, color: Theme.line })
                  .onClick(() => {
                    this.toggleSubtitleBackground();
                  })
              }
              .width('100%')
              .padding({ left: 20, right: 20, top: 10, bottom: 10 })
            }
          }
          .borderRadius(Theme.cardRadius)
          .backgroundColor(Theme.surface)
          .border({ width: 1, color: Theme.line })
        }
        .scrollBar(BarState.Off)
        .padding({ left: 16, right: 16, bottom: 12 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  /** 样式行里的圆步进钮（iOS StepButton） */
  @Builder
  StyleStepButton(label: string, onTap: () => void) {
    Text(label)
      .fontSize(16)
      .fontColor(Theme.text)
      .width(34)
      .height(34)
      .textAlign(TextAlign.Center)
      .backgroundColor(Theme.glassFill)
      .borderRadius(17)
      .onClick(() => {
        onTap();
      })
  }

  /** 播放诊断（iOS PlayerDiagnosticsPanel）：静态判定 + 2 秒一次的服务端执行快照 */
  @Builder
  StatsSheet() {
    Column({ space: 14 }) {
      Row() {
        Text('播放诊断')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
          .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(18)
          .fontColor([Theme.textMuted])
          .width(40)
          .height(40)
          .onClick(() => {
            this.showSheet = false;
          })
      }
      .width('100%')

      Scroll() {
        Column({ space: 12 }) {
          if (this.session !== null) {
            // 判定：这一档是怎么判出来的
            Column({ space: 8 }) {
              Text(this.streamLabel())
                .fontSize(16)
                .fontWeight(600)
                .fontColor(Theme.text)
              Text(`容器 ${(this.session as PlaybackSessionView).decision.container ?? '—'}  ·  `
                + `档位 ${(this.session as PlaybackSessionView).decision.tier ?? 0}`)
                .fontSize(13)
                .fontColor(Theme.textMuted)
              if ((this.session as PlaybackSessionView).decision.reason.length > 0) {
                Text((this.session as PlaybackSessionView).decision.reason)
                  .fontSize(13)
                  .fontColor(Theme.text)
                  .width('100%')
              }
              if ((this.session as PlaybackSessionView).decision.suggestion !== null
                && (this.session as PlaybackSessionView).decision.suggestion !== undefined
                && ((this.session as PlaybackSessionView).decision.suggestion ?? '').length > 0) {
                Text((this.session as PlaybackSessionView).decision.suggestion ?? '')
                  .fontSize(12)
                  .fontColor(Theme.warn)
                  .width('100%')
              }
              if ((this.session as PlaybackSessionView).hw_backend !== null
                && (this.session as PlaybackSessionView).hw_backend !== undefined) {
                Text(`硬件后端：${(this.session as PlaybackSessionView).hw_backend}`)
                  .fontSize(12)
                  .fontColor(Theme.textMuted)
              }
              if ((this.session as PlaybackSessionView).decision.degraded_from !== null
                && (this.session as PlaybackSessionView).decision.degraded_from !== undefined) {
                Text(`从第 ${(this.session as PlaybackSessionView).decision.degraded_from} 档降级下来`)
                  .fontSize(12)
                  .fontColor(Theme.warn)
              }
              Text(`本机上报的能力：mp4/mkv/ts · H264/H265 · AAC/MP3 · 不支持杜比视界透传`)
                .fontSize(11)
                .fontColor(Theme.textFaint)
                .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(16)
            .backgroundColor(Theme.surface)
            .borderRadius(Theme.cardRadius)
            .border({ width: 1, color: Theme.line })
          } else {
            // 直出 / 本机副本：没有服务端会话，只有本地信息
            Column({ space: 8 }) {
              Text(this.streamLabel())
                .fontSize(16)
                .fontWeight(600)
                .fontColor(Theme.text)
              Text('没有服务端播放会话：原文件直出或本机副本，不产生转码')
                .fontSize(12)
                .fontColor(Theme.textMuted)
                .width('100%')
              Text(`本机上报的能力：mp4/mkv/ts · H264/H265 · AAC/MP3 · 不支持杜比视界透传`)
                .fontSize(11)
                .fontColor(Theme.textFaint)
                .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(16)
            .backgroundColor(Theme.surface)
            .borderRadius(Theme.cardRadius)
            .border({ width: 1, color: Theme.line })
          }
          if (this.diag !== null) {
            // 执行：此刻转码跑在哪、用什么后端
            Column({ space: 7 }) {
              Text('执行')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.textMuted)
              if (this.diagExecutionMode().length > 0) {
                Text(this.diagExecutionMode())
                  .fontSize(13)
                  .fontColor(Theme.text)
                  .width('100%')
              }
              if (this.diagLocation().length > 0) {
                Text(this.diagLocation())
                  .fontSize(13)
                  .fontColor(Theme.text)
                  .width('100%')
              }
              if (this.diagBackendLine().length > 0) {
                Text(this.diagBackendLine())
                  .fontSize(13)
                  .fontColor(Theme.text)
                  .width('100%')
              }
              if (this.diagWorkerLine().length > 0) {
                Text(this.diagWorkerLine())
                  .fontSize(13)
                  .fontColor(Theme.text)
                  .width('100%')
              }
              if (this.diagWorkerVersionLine().length > 0) {
                Text(this.diagWorkerVersionLine())
                  .fontSize(13)
                  .fontColor(Theme.text)
                  .width('100%')
              }
              if (this.diagWorkerPlatformLine().length > 0) {
                Text(this.diagWorkerPlatformLine())
                  .fontSize(13)
                  .fontColor(Theme.text)
                  .width('100%')
              }
              if (this.diagJobLine().length > 0) {
                Text(this.diagJobLine())
                  .fontSize(13)
                  .fontColor(Theme.text)
                  .width('100%')
              }
              if (this.diagExitCodeLine().length > 0) {
                Text(this.diagExitCodeLine())
                  .fontSize(13)
                  .fontColor(Theme.danger)
                  .width('100%')
              }
              if (this.diagJobErrorLine().length > 0) {
                Text(this.diagJobErrorLine())
                  .fontSize(13)
                  .fontColor(Theme.danger)
                  .width('100%')
              }
              if (this.diagStderrLine().length > 0) {
                Text(this.diagStderrLine())
                  .fontSize(13)
                  .fontColor(Theme.danger)
                  .width('100%')
              }
              if (this.diagSessionErrorLine().length > 0) {
                Text(this.diagSessionErrorLine())
                  .fontSize(13)
                  .fontColor(Theme.danger)
                  .width('100%')
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(16)
            .backgroundColor(Theme.surface)
            .borderRadius(Theme.cardRadius)
            .border({ width: 1, color: Theme.line })
          }
          if (this.diagHasSegments()) {
            // 供片：分片产出/缺口/缓存
            Column({ space: 7 }) {
              Text('供片')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.textMuted)
              Text(this.diagSupplyFirstLine())
                .fontSize(13)
                .fontColor(Theme.text)
                .width('100%')
              Text(this.diagSupplyProducedLine())
                .fontSize(13)
                .fontColor(Theme.text)
                .width('100%')
              if (this.diagSupplyLeadLine().length > 0) {
                Text(this.diagSupplyLeadLine())
                  .fontSize(13)
                  .fontColor(Theme.text)
                  .width('100%')
              }
              Text(this.diagSupplyCacheLine())
                .fontSize(13)
                .fontColor(Theme.text)
                .width('100%')
              if (this.diagSupplyGapLine().length > 0) {
                Text(this.diagSupplyGapLine())
                  .fontSize(13)
                  .fontColor(Theme.danger)
                  .width('100%')
              }
              if (this.diagSupplyHistoricalLine().length > 0) {
                Text(this.diagSupplyHistoricalLine())
                  .fontSize(13)
                  .fontColor(Theme.warn)
                  .width('100%')
              }
              if (this.diagSupplyUploadLine().length > 0) {
                Text(this.diagSupplyUploadLine())
                  .fontSize(13)
                  .fontColor(this.diagSupplyUploadAlert() ? Theme.danger : Theme.text)
                  .width('100%')
              }
              if (this.diagSupplyWaitLine().length > 0) {
                Text(this.diagSupplyWaitLine())
                  .fontSize(13)
                  .fontColor(Theme.text)
                  .width('100%')
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(16)
            .backgroundColor(Theme.surface)
            .borderRadius(Theme.cardRadius)
            .border({ width: 1, color: Theme.line })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .width('100%')
      .align(Alignment.TopStart)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16 })
    .backgroundColor(Theme.bg)
  }
}
