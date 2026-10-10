import { media } from '@kit.MediaKit';
import { BusinessError, settings } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { PiPWindow, window } from '@kit.ArkUI';
import { audio } from '@kit.AudioKit';
import { PlaybackGuard } from './PlaybackGuard';
import { Theme } from '../theme/AppTheme';
import { ShellChrome } from '../common/ShellChrome';
import { AppModel } from '../common/AppModel';
import { ShareLocalProgress } from '../share/ShareProgress';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import {
  AudioSupportIn,
  ClientCapabilityIn,
  PlaybackSessionRequest,
  PlaybackSessionView,
  AudioTrackView,
  PlaybackChapterMarkView,
  SubtitlePlanView,
  VideoSupportIn, PlaybackSegmentView } from '../api/Models';

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

  constructor(mediaItemId: number, fileId: number = 0, seasonNumber: number = 0,
    episodeNumber: number = 0, startMs: number = 0, shareSlug: string = '') {
    this.mediaItemId = mediaItemId;
    this.fileId = fileId;
    this.seasonNumber = seasonNumber;
    this.episodeNumber = episodeNumber;
    this.startMs = startMs;
    this.shareSlug = shareSlug;
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
      raw.shareSlug !== undefined && raw.shareSlug !== null ? raw.shareSlug : '');
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
  start_ms?: number | null;
  client?: string | null;
}

/** `VideoSupportIn` / `AudioSupportIn` 也按 ArkTS 的要求用类构造 */
class VideoSupport implements VideoSupportIn {
  codec: string = '';
  max_height?: number | null;
  active: boolean = true;
}

class AudioSupport implements AudioSupportIn {
  codec: string = '';
  max_channels?: number | null;
  active: boolean = true;
}

/** 播放状态机 */
class PlayerPhase {
  static readonly negotiating: string = 'negotiating';
  static readonly ready: string = 'ready';
  static readonly failed: string = 'failed';
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
    this.disarmHoldTimer();
    this.disarmAdjustHide();
    this.disarmWatchdog();
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
      // 传**空数组**而不是 null：后端是 `failed_tiers: list[int] = []`（不可空）。
      // 这已经是同一类错误的第二次（上一次是 season_number 传 null）——
      // **后端的默认值不可空时，客户端一律不能送 null**。
      body.failed_tiers = this.failedTiers;
      const view: PlaybackSessionView = this.shareSlug.length > 0
        ? await api.sharePlaybackSessionStart(this.shareSlug, body)
        : await api.playbackSessionStart(body);
      this.session = view;
      const url: string | null = view.stream_url ?? null;
      if (url === null || url.length === 0) {
        this.phase = PlayerPhase.failed;
        // 服务端说不能放时，把它的理由原样给用户——比「播放失败」有用得多
        this.errorMessage = view.decision.reason.length > 0
          ? view.decision.reason
          : '服务端没有给出可播放的地址';
        return;
      }
      this.phase = PlayerPhase.ready;
      await this.attachPlayer(AppModel.origin() + url);
    } catch (error) {
      this.phase = PlayerPhase.failed;
      this.errorMessage = this.messageOf(error);
    }
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '播放失败';
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

  private bindPlayerEvents(player: media.AVPlayer): void {
    player.on('stateChange', (state: string): void => {
      if (state === 'initialized') {
        this.armWatchdog();
        player.surfaceId = this.surfaceId;
        player.prepare();
      } else if (state === 'prepared') {
        this.durationMs = player.duration;
        player.play();
      } else if (state === 'playing') {
        this.disarmWatchdog();
        this.playing = true;
        this.startReport();
        this.armChromeTimer();
        // 后台播放：AVSession + 长时任务（缺一个退后台就会被系统停掉）
        this.ensureGuard().then((guard: PlaybackGuard): Promise<void> => {
          return guard.start(this.title.length > 0 ? this.title : '播放');
        }).catch((): void => {
        });
        this.enableAutoPip();
      } else if (state === 'paused') {
        this.playing = false;
        // 暂停时挂着的长按倍速要收掉（iOS：pause 会 endHoldSpeed）
        this.endHoldSpeed();
        // 暂停要**释放长时任务**（一直挂着会被系统判为滥用），恢复时重新申请
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
    const view: PlaybackSessionView | null = this.session;
    const tier: number = view !== null ? (view.decision.tier ?? -1) : -1;
    if (tier < 0 || this.retryCount >= 1) {
      this.phase = PlayerPhase.failed;
      this.errorMessage = reason;
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
    const target: number = Math.max(0, Math.min(this.durationMs, ms));
    player.seek(target, media.SeekMode.SEEK_CLOSEST);
    this.positionMs = target;
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
        this.toast('已关闭字幕');
        return;
      }
      const urls: string[] = view.subtitle_urls;
      if (index >= urls.length) {
        this.toast('这条字幕没有可用的地址');
        return;
      }
      await player.addSubtitleFromUrl(AppModel.origin() + urls[index]);
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
    } catch (error) {
      const e = error as BusinessError;
      this.toast(`字幕切换失败（${e.code ?? -1}）`);
    }
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
    const clock: string = this.clockText(this.positionMs);
    const chapter: string | null = this.currentChapter();
    return chapter !== null ? `${clock} · ${chapter}` : clock;
  }

  /** 当前位置落在哪一段可跳过区间里（没有就是 null） */
  private currentSegment(): PlaybackSegmentView | null {
    const view: PlaybackSessionView | null = this.session;
    const segments: PlaybackSegmentView[] | null = view !== null ? (view.segments ?? null) : null;
    if (segments === null) {
      return null;
    }
    for (const segment of segments) {
      if (this.positionMs >= segment.start_ms && this.positionMs < segment.end_ms) {
        return segment;
      }
    }
    return null;
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
    const api: MovieClawApi | null = this.api();
    const view: PlaybackSessionView | null = this.session;
    if (api === null || view === null || this.positionMs <= 0) {
      return;
    }
    if (this.shareSlug.length > 0) {
      // 访客播放没有站内播放指标接口，进度只记本机（续播点用）
      ShareLocalProgress.write(this.shareSlug, this.mediaItemId, this.seasonNumber,
        this.episodeNumber, this.positionMs);
      return;
    }
    // 上报失败不影响播放（离线一会儿也要能看完）
    api.playbackMetricReport({
      tier: view.decision.tier ?? 0,
      seek_count: 0
    }).catch((): void => {
    });
  }

  private stopSession(): void {
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

  // MARK: 派生

  private streamLabel(): string {
    const view: PlaybackSessionView | null = this.session;
    if (view === null) {
      return '';
    }
    const tier: number = view.decision.tier ?? 0;
    if (tier <= 0) {
      return '直出';
    }
    return `转码（第 ${tier} 档）`;
  }

  private clockText(ms: number): string {
    const total: number = Math.max(0, Math.floor(ms / 1000));
    const minutes: number = Math.floor(total / 60);
    const seconds: number = total % 60;
    return `${minutes}:${seconds < 10 ? '0' : ''}${seconds}`;
  }

  private progressPercent(): number {
    return this.durationMs > 0 ? Math.round(this.positionMs * 100 / this.durationMs) : 0;
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
        // 横滑定位的落点读数：整屏正中（与中央三键同一个中心，拖动时控制条已收起）
        if (this.scrubMs >= 0) {
          Column({ space: 4 }) {
            Text(this.clockText(this.scrubMs))
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
        this.TopHud()
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#000000')
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
        this.negotiate();
      }
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
          }
          .width('100%')
          .height(4)
          Row({ space: 8 }) {
            // iOS 把**当前章节名接在时间后面**（`12:34 · Part 01`），不是拉一条章节带
            Text(this.clockWithChapter())
              .fontSize(12)
              .fontColor('rgba(255,255,255,0.85)')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            Blank()
            Text('-' + this.clockText(Math.max(0, this.durationMs - this.positionMs)))
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
    } else {
      this.StatsSheet()
    }
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
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  /** 播放详情：这一档是怎么判出来的（对应 iOS 的「为什么转码」） */
  @Builder
  StatsSheet() {
    Column({ space: 14 }) {
      Row() {
        Blank()
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

      if (this.session !== null) {
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
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16 })
    .backgroundColor(Theme.bg)
  }
}
