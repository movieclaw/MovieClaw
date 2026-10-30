import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { audio } from '@kit.AudioKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { createEngine, destroyEngine, initEngine, command as mpvCommand,
  setPropertyNumber as mpvSetNumber, setPropertyString as mpvSetString,
  setPropertyFlag as mpvSetFlag, getPropertyFlag as mpvGetFlag,
  getPropertyString as mpvGetString, getPropertyNumber as mpvGetNumber,
  observe as mpvObserve, unobserve as mpvUnobserve, MpvEvent } from 'libmovieclaw_mpv.so';

/**
 * libmpv 播放引擎（dex2oat/mpv 的 OHOS 移植，vo_gpu/EGL + OHCodec 硬解 + ohaudio）。
 *
 * **刻意做成 `media.AVPlayer` 的鸭子类型替身**：PlayerPage 里 `avPlayer` 的类型是
 * `media.AVPlayer | MpvPlayer`，两边方法/属性/事件签名一致时（on/prepare/play/seek/…），
 * 播放器页的业务逻辑一行都不用改。行为差异在类内消化：
 * - mpv 没有 initialized→prepared 的状态机：url/fdSrc 赋值 → 「initialized」；
 *   prepare() 才真正建引擎（wid=surfaceId 必须 mpv_initialize 前给）+ loadfile；
 *   file-loaded → 「prepared」，playback-restart → 「playing」，end-file(EOF) → 「completed」。
 * - 外挂字幕：AVPlayer 要求 prepare 前挂；mpv 的 `sub-add` 随时可挂——没初始化时先排队，
 *   file-loaded 后补挂，`deferPrepare` 协议照常成立。
 * - 字幕渲染：交给 libass 画进视频（质量与 ASS 特效都在），不再走自绘字幕层；
 *   SubStyle 映射成 mpv 的 --sub-* 选项。
 * - 音频焦点：AVPlayer 内部接管；mpv 走 ao_ohaudio 补丁的 interrupt 钩子 → audioInterrupt 事件。
 */
/**
 * 引擎侧实时读数（详情面板「引擎」一节，安卓 TV DiagnosticsReport 的 EngineReading 对位）。
 * 直出 / 本机副本没有服务端快照，引擎读数是唯一的性能证据——掉帧取证就靠它。
 */
export interface MpvEngineReading {
  /** 视频解码器（h264/hevc/…） */
  codec: string;
  /** hwdec-current：no/空=软件解码（掉帧第一嫌疑）；ohcodec-copy=硬解（buffer 模式，真机花屏暂弃用） */
  hwdec: string;
  width: number;
  height: number;
  /** 容器标称帧率 */
  containerFps: number;
  /** 实际出帧率（落后于标称 = 解码/渲染跟不上） */
  estimatedFps: number;
  /** vo 丢帧数 */
  voDropped: number;
  /** 解码器丢帧数 */
  decoderDropped: number;
  /** 合计丢帧数 */
  totalDropped: number;
  /** 已缓冲可播秒数（demuxer-cache-duration） */
  cacheSeconds: number;
  /** 缓冲总秒数（demuxer-cache-time） */
  cacheTotalSeconds: number;
  /** 缓冲进行度 0-100（cache-buffering-state） */
  bufferingPercent: number;
  /** 下载速度 B/s（cache-speed） */
  cacheSpeedBps: number;
  /** 视频码率 bps */
  videoBitrate: number;
  /** 音频码率 bps */
  audioBitrate: number;
  /** 播放头秒 */
  positionSeconds: number;
  paused: boolean;
  /** 播放速度 */
  speed: number;
  /** video-params/primaries（bt.709 / bt.2020…；HDR 判定参考） */
  primaries: string;
  /** video-params/gamma（pq / hlg = HDR，其余按 SDR 显示） */
  gamma: string;
}

export class MpvPlayer {
  private handle: number;
  private inited: boolean = false;
  private preparing: boolean = false;

  private stateValue: media.AVPlayerState = 'idle';
  private mediaUrl: string = '';
  private mediaFd: number = -1;
  private surfaceIdValue: string = '';

  /** MPV_END_FILE_REASON_EOF（mpv/client.h） */
  private static readonly END_FILE_EOF: number = 0;
  /** MPV_END_FILE_REASON_ERROR */
  private static readonly END_FILE_ERROR: number = 4;
  /** OH_AudioInterrupt_Hint → audio.InterruptHint */
  private static readonly HINT_RESUME: number = 1;
  private static readonly HINT_PAUSE: number = 2;
  private static readonly HINT_STOP: number = 3;

  private onState: ((state: media.AVPlayerState, reason: media.StateChangeReason) => void) | null = null;
  private onVideoSize: ((width: number, height: number, scale: number) => void) | null = null;
  private onTime: ((time: number) => void) | null = null;
  private onSubtitle: ((info: media.SubtitleInfo) => void) | null = null;
  private onInterrupt: ((event: audio.InterruptEvent) => void) | null = null;
  private onError: ((error: BusinessError) => void) | null = null;

  /** 观察器句柄（unobserve 用） */
  private observedIds: number[] = [];

  /** mpv 初始化前排队的字幕（url），file-loaded 后补挂 */
  private pendingSubUrls: string[] = [];
  private pendingSubFds: number[] = [];
  /** 已在播放器里挂上的字幕轨（mpv 的 track id） */
  private currentSubTrackId: number = -1;

  /** 秒级 timeUpdate 钟表（对齐 AVPlayer 的每秒一跳） */
  private tickTimer: number = -1;

  /** 字幕样式（prepare 前可能被设置，init 后补应用） */
  private subFontScale: number = 5.2;
  private subBottomPercent: number = 8;
  private subBackground: boolean = true;
  /** 本文件是否已发过 prepared（file-loaded 前抑制 playing，对齐 AVPlayer 的状态序） */
  private sawPrepared: boolean = false;

  private constructor(handle: number) {
    this.handle = handle;
  }

  static async create(): Promise<MpvPlayer> {
    return new MpvPlayer(createEngine());
  }

  // —— AVPlayer 形状：属性 ——

  get state(): media.AVPlayerState {
    return this.stateValue;
  }

  get duration(): number {
    const seconds: number = this.inited ? mpvGetNumber(this.handle, 'duration') : NaN;
    return Number.isNaN(seconds) ? 0 : Math.round(seconds * 1000);
  }

  get url(): string {
    return this.mediaUrl;
  }

  set url(v: string) {
    this.mediaUrl = v;
    this.mediaFd = -1;
    this.stateValue = 'initialized';
    this.emitState('initialized', 0);
  }

  set fdSrc(v: media.AVFileDescriptor) {
    this.mediaFd = v.fd;
    this.mediaUrl = '';
    this.stateValue = 'initialized';
    this.emitState('initialized', 0);
  }

  get surfaceId(): string {
    return this.surfaceIdValue;
  }

  set surfaceId(v: string) {
    this.surfaceIdValue = v;
  }

  // —— AVPlayer 形状：控制 ——

  async prepare(): Promise<void> {
    if (this.inited || this.preparing) {
      return;
    }
    if (this.mediaUrl.length === 0 && this.mediaFd < 0) {
      return;
    }
    this.preparing = true;
    try {
      const options: Record<string, string> = {
        'vo': 'gpu',
        'gpu-context': 'ohos',
        'ao': 'ohaudio',
        // 硬解（2026-10-30 Pura X 定位 + 修复）：HISI 对 10-bit 流忽略 NV12 请求输出 P010
        // 内存却仍上报 NV12 → 花屏。本机重编的 libmpv.so（ohdec 补丁）已按 buffer capacity
        // 自适应做 P010→NV12 降位拷贝 + 布局日志，恢复 buffer 硬解（copy 模式）。
        // 失败回退：改回 'no'（软解），或应急设置里切「系统播放器」。
        'hwdec': 'ohcodec-copy',
        // 帧节奏（2026-10-30）：0 丢帧/60fps 下仍偶有节奏感卡顿 —— 默认按音频
        // 时钟排帧，音频时钟微调会造成视觉抖动；改按屏幕 vsync 排帧（音频轻微
        // 重采样补偿，60fps 内容 + 60Hz 屏即 1:1）。无效或异常删掉本行即回退。
        'video-sync': 'display-resync',
        'wid': this.surfaceIdValue,
        // 系统字体目录交给 libass 扫描（无 fontconfig 时的字体来源）
        'sub-fonts-dir': '/system/fonts',
        // MovieClaw 连的是用户自己的服务器，自签证书常见；AVPlayer 时代也走系统信任
        'tls-verify': 'no'
      };
      initEngine(this.handle, options, (event: MpvEvent): void => {
        this.onMpvEvent(event);
      });
      this.inited = true;
      this.sawPrepared = false;
      this.observeAll();
      this.applySubStyle(this.subFontScale, this.subBottomPercent, this.subBackground);
      if (this.mediaFd >= 0) {
        mpvCommand(this.handle, ['loadfile', `fd://${this.mediaFd}`, 'replace']);
      } else {
        mpvCommand(this.handle, ['loadfile', this.mediaUrl, 'replace']);
      }
    } catch (error) {
      // 引擎起不来：按 AVPlayer 的 error 语义回灌，让 PlayerPage 走降档回路
      const err: BusinessError = error as BusinessError;
      hilog.error(0x0000, 'MpvPlayer', 'prepare failed code=%{public}d msg=%{public}s',
        err.code ?? -1, err.message ?? '');
      this.stateValue = 'error';
      const cb = this.onError;
      if (cb !== null) {
        cb(err);
      }
    } finally {
      this.preparing = false;
    }
  }

  async play(): Promise<void> {
    if (!this.inited) {
      return;
    }
    // AVPlayer 语义：completed 后按播放 = 从头重播。mpv 到 EOF 已 idle（keep-open=no），
    // 单纯 pause=0 没有效果 —— 重新 loadfile。
    if (this.stateValue === 'completed') {
      this.sawPrepared = false;
      this.stateValue = 'initialized';
      this.emitState('initialized', 0);
      if (this.mediaFd >= 0) {
        mpvCommand(this.handle, ['loadfile', `fd://${this.mediaFd}`, 'replace']);
      } else {
        mpvCommand(this.handle, ['loadfile', this.mediaUrl, 'replace']);
      }
      return;
    }
    // pause 是 flag 属性：libmpv 只认 MPV_FORMAT_FLAG，走 DOUBLE 会被静默拒绝（真机必现）
    mpvSetFlag(this.handle, 'pause', false);
  }

  async pause(): Promise<void> {
    if (!this.inited) {
      return;
    }
    mpvSetFlag(this.handle, 'pause', true);
  }

  async seek(timeMs: number, mode?: media.SeekMode): Promise<void> {
    if (!this.inited) {
      return;
    }
    // SEEK_CLOSEST ↔ mpv 的 exact seek；未指明时用 keyframes（HLS 更省）
    const exact: boolean = mode === media.SeekMode.SEEK_CLOSEST;
    mpvCommand(this.handle, ['seek', `${timeMs / 1000}`, exact ? 'absolute+exact' : 'absolute+keyframes']);
  }

  async setSpeed(speed: media.PlaybackSpeed): Promise<void> {
    if (!this.inited) {
      return;
    }
    mpvSetNumber(this.handle, 'speed', MpvPlayer.speedOf(speed));
  }

  /**
   * 画面比例三档（平铺/拉伸/裁切）。比例全交给 mpv，页面只管 surface 尺寸：
   * - fit：按视频比例信箱留黑（默认；撤销 override 与 panscan）
   * - stretch：video-aspect-override 钉成 surface 比例 → 整面铺满（画面变形）
   * - crop：panscan=1 → 放大铺满、裁掉超出（cover）
   * 拉伸档依赖 surface 宽高，旋转后需带新尺寸重设一次。
   */
  applyAspectMode(mode: string, layerWidth: number, layerHeight: number): void {
    if (!this.inited) {
      return;
    }
    const stretch: boolean = mode === 'stretch' && layerWidth > 0 && layerHeight > 0;
    // video-aspect-override 是 double 选项：-1 = 不覆盖（保持视频原比例）
    mpvSetNumber(this.handle, 'video-aspect-override', stretch ? layerWidth / layerHeight : -1);
    // panscan 是 float 选项：按本文件惯例（applySubStyle 注释）走字符串写
    mpvSetString(this.handle, 'panscan', mode === 'crop' ? '1' : '0');
  }

  async release(): Promise<void> {
    this.stopTick();
    this.stateValue = 'released';
    if (this.inited) {
      for (const id of this.observedIds) {
        mpvUnobserve(this.handle, id);
      }
      this.observedIds = [];
      this.inited = false;
    }
    destroyEngine(this.handle);
    this.onState = null;
    this.onVideoSize = null;
    this.onTime = null;
    this.onSubtitle = null;
    this.onInterrupt = null;
    this.onError = null;
  }

  // —— AVPlayer 形状：字幕与轨道 ——

  async addSubtitleFromUrl(url: string): Promise<void> {
    if (!this.inited) {
      this.pendingSubUrls.push(url);
      return;
    }
    mpvCommand(this.handle, ['sub-add', url]);
  }

  async addSubtitleFromFd(fd: number): Promise<void> {
    if (!this.inited) {
      this.pendingSubFds.push(fd);
      return;
    }
    mpvCommand(this.handle, ['sub-add', `fd://${fd}`]);
  }

  async getTrackDescription(): Promise<Array<media.MediaDescription>> {
    const out: Array<media.MediaDescription> = [];
    if (!this.inited) {
      return out;
    }
    const raw: string | null = mpvGetString(this.handle, 'track-list');
    if (raw === null || raw.length === 0) {
      return out;
    }
    const tracks: MpvTrackRaw[] = JSON.parse(raw) as MpvTrackRaw[];
    for (const t of tracks) {
      const desc: media.MediaDescription = {} as media.MediaDescription;
      desc['track_type'] = MpvPlayer.ohosMediaType(t.type);
      desc['track_index'] = t.id;
      if (t.title !== undefined) {
        desc['track_title'] = t.title;
      }
      if (t.lang !== undefined) {
        desc['track_language'] = t.lang;
      }
      out.push(desc);
    }
    return out;
  }

  async selectTrack(index: number): Promise<void> {
    if (!this.inited) {
      return;
    }
    // sid 是 choice 属性：只认 STRING/INT64，DOUBLE 会被拒——走字符串（deselectTrack 同款）
    mpvSetString(this.handle, 'sid', `${index}`);
    this.currentSubTrackId = index;
  }

  async deselectTrack(index: number): Promise<void> {
    if (!this.inited) {
      return;
    }
    // mpv 关字幕：sid=no（index 仅用于和调用侧对账，不参与 mpv 语义）
    mpvSetString(this.handle, 'sid', 'no');
    this.currentSubTrackId = -1;
  }

  // —— 扩展：字幕样式（SubStyle → mpv --sub-*） ——

  /**
   * 应用字幕样式。引擎还没初始化（attach 前）先记住，prepare 后自动补一次。
   * @param fontScalePercent 字号 = 屏宽 × N%（同自绘字幕 SubStyle 语义）
   * @param bottomPercent 距屏幕底部百分比
   * @param background 黑底胶囊
   */
  applySubStyle(fontScalePercent: number, bottomPercent: number, background: boolean): void {
    this.subFontScale = fontScalePercent;
    this.subBottomPercent = bottomPercent;
    this.subBackground = background;
    if (!this.inited) {
      return;
    }
    // 字号锚在视频像素上：mpv 渲染进视频面，fit 模式下视频宽 ≈ 屏宽
    // （video-params 的键是缩写 w/h——写成 width 会查不到而落到 1080 兜底）
    let widthPx: number = mpvGetNumber(this.handle, 'video-params/w');
    if (Number.isNaN(widthPx) || widthPx <= 0) {
      widthPx = 1080;
    }
    const fontSize: number = Math.max(16, Math.round(widthPx * fontScalePercent / 100));
    // sub-font-size/sub-pos/sub-border-style/sub-shadow-offset 是 int/float/choice 属性：
    // 一律走字符串写（mpv 对所有选项类型都收字符串解析），DOUBLE 只对 double 属性成立
    mpvSetString(this.handle, 'sub-font-size', `${fontSize}`);
    // sub-pos：0=顶 100=底；bottomPercent 是「距底部百分比」，直接对偶换算
    mpvSetString(this.handle, 'sub-pos', `${Math.min(100, Math.max(0, 100 - bottomPercent))}`);
    // border-style 是 choice：只收命名值（sub/osd.c：outline-and-shadow=1 / opaque-box=3 /
    // background-box=4），传数字会被拒（曾报 Invalid value for option sub-border-style: 4）
    mpvSetString(this.handle, 'sub-border-style', background ? 'background-box' : 'outline-and-shadow');
    mpvSetString(this.handle, 'sub-shadow-offset', '0');
  }

  // —— 扩展：引擎侧实时读数（详情面板 2 秒一拉） ——

  engineReading(): MpvEngineReading | null {
    if (!this.inited) {
      return null;
    }
    const reading: MpvEngineReading = {
      codec: MpvPlayer.cleanString(mpvGetString(this.handle, 'video-codec')),
      hwdec: MpvPlayer.cleanString(mpvGetString(this.handle, 'hwdec-current')),
      width: MpvPlayer.cleanNumber(mpvGetNumber(this.handle, 'video-params/w')),
      height: MpvPlayer.cleanNumber(mpvGetNumber(this.handle, 'video-params/h')),
      containerFps: MpvPlayer.cleanNumber(mpvGetNumber(this.handle, 'container-fps')),
      estimatedFps: MpvPlayer.cleanNumber(mpvGetNumber(this.handle, 'estimated-vf-fps')),
      voDropped: MpvPlayer.cleanNumber(mpvGetNumber(this.handle, 'vo-drop-frame-count')),
      decoderDropped: MpvPlayer.cleanNumber(mpvGetNumber(this.handle, 'decoder-frame-drop-count')),
      totalDropped: MpvPlayer.cleanNumber(mpvGetNumber(this.handle, 'frame-drop-count')),
      cacheSeconds: MpvPlayer.cleanNumber(mpvGetNumber(this.handle, 'demuxer-cache-duration')),
      cacheTotalSeconds: MpvPlayer.cleanNumber(mpvGetNumber(this.handle, 'demuxer-cache-time')),
      bufferingPercent: MpvPlayer.cleanNumber(mpvGetNumber(this.handle, 'cache-buffering-state')),
      cacheSpeedBps: MpvPlayer.cleanNumber(mpvGetNumber(this.handle, 'cache-speed')),
      videoBitrate: MpvPlayer.cleanNumber(mpvGetNumber(this.handle, 'video-bitrate')),
      audioBitrate: MpvPlayer.cleanNumber(mpvGetNumber(this.handle, 'audio-bitrate')),
      positionSeconds: MpvPlayer.cleanNumber(mpvGetNumber(this.handle, 'time-pos')),
      paused: mpvGetFlag(this.handle, 'pause'),
      speed: MpvPlayer.cleanNumber(mpvGetNumber(this.handle, 'speed')),
      primaries: MpvPlayer.cleanString(mpvGetString(this.handle, 'video-params/primaries')),
      gamma: MpvPlayer.cleanString(mpvGetString(this.handle, 'video-params/gamma'))
    };
    return reading;
  }

  private static cleanNumber(v: number): number {
    return Number.isFinite(v) ? v : 0;
  }

  private static cleanString(v: string | null): string {
    return v !== null && v.length > 0 ? v : '';
  }

  // —— 事件注册（签名对齐 media.AVPlayer） ——

  on(type: 'stateChange', callback: (state: media.AVPlayerState, reason: media.StateChangeReason) => void): void;
  on(type: 'videoSizeChange', callback: (width: number, height: number, scale: number) => void): void;
  on(type: 'timeUpdate', callback: (time: number) => void): void;
  on(type: 'subtitleUpdate', callback: (info: media.SubtitleInfo) => void): void;
  on(type: 'audioInterrupt', callback: (event: audio.InterruptEvent) => void): void;
  on(type: 'error', callback: (error: BusinessError) => void): void;
  on(type: string, callback: object): void {
    if (type === 'stateChange') {
      this.onState = callback as (state: media.AVPlayerState, reason: media.StateChangeReason) => void;
    } else if (type === 'videoSizeChange') {
      this.onVideoSize = callback as (width: number, height: number, scale: number) => void;
    } else if (type === 'timeUpdate') {
      this.onTime = callback as (time: number) => void;
    } else if (type === 'subtitleUpdate') {
      this.onSubtitle = callback as (info: media.SubtitleInfo) => void;
    } else if (type === 'audioInterrupt') {
      this.onInterrupt = callback as (event: audio.InterruptEvent) => void;
    } else if (type === 'error') {
      this.onError = callback as (error: BusinessError) => void;
    }
  }

  off(type: 'stateChange'): void;
  off(type: 'videoSizeChange'): void;
  off(type: 'timeUpdate'): void;
  off(type: 'subtitleUpdate'): void;
  off(type: 'audioInterrupt'): void;
  off(type: 'error'): void;
  off(type: string): void {
    if (type === 'stateChange') {
      this.onState = null;
    } else if (type === 'videoSizeChange') {
      this.onVideoSize = null;
    } else if (type === 'timeUpdate') {
      this.onTime = null;
    } else if (type === 'subtitleUpdate') {
      this.onSubtitle = null;
    } else if (type === 'audioInterrupt') {
      this.onInterrupt = null;
    } else if (type === 'error') {
      this.onError = null;
    }
  }

  // —— 内部 ——

  private observeAll(): void {
    this.observedIds.push(mpvObserve(this.handle, 'pause', 'flag'));
    this.observedIds.push(mpvObserve(this.handle, 'video-params/w', 'double'));
  }

  private emitState(state: media.AVPlayerState, reason: number): void {
    setTimeout((): void => {
      const cb = this.onState;
      if (cb !== null) {
        cb(state, reason as media.StateChangeReason);
      }
    }, 0);
  }

  private startTick(): void {
    this.stopTick();
    this.tickTimer = setInterval((): void => {
      this.tickOnce();
    }, 1000);
    this.tickOnce();
  }

  private stopTick(): void {
    if (this.tickTimer >= 0) {
      clearInterval(this.tickTimer);
      this.tickTimer = -1;
    }
  }

  private tickOnce(): void {
    if (!this.inited) {
      return;
    }
    const seconds: number = mpvGetNumber(this.handle, 'time-pos');
    if (Number.isNaN(seconds)) {
      return;
    }
    const cb = this.onTime;
    if (cb !== null) {
      cb(Math.round(seconds * 1000));
    }
  }

  private onMpvEvent(event: MpvEvent): void {
    if (event.event === 'file-loaded') {
      // 先补挂初始化前排队的字幕，再进 prepared
      const urls: string[] = this.pendingSubUrls;
      this.pendingSubUrls = [];
      for (const u of urls) {
        mpvCommand(this.handle, ['sub-add', u]);
      }
      const fds: number[] = this.pendingSubFds;
      this.pendingSubFds = [];
      for (const fd of fds) {
        mpvCommand(this.handle, ['sub-add', `fd://${fd}`]);
      }
      this.stateValue = 'prepared';
      this.emitState('prepared', 0);
    } else if (event.event === 'playback-restart') {
      // 播放中 seek 也会触发 playback-restart；只在没在播时升级成 playing
      if (this.stateValue !== 'playing') {
        this.stateValue = 'playing';
        this.startTick();
        this.emitState('playing', 0);
      }
    } else if (event.event === 'property-change') {
      if (event.name === 'pause' && typeof event.value === 'boolean') {
        if (event.value && this.stateValue === 'playing') {
          this.stateValue = 'paused';
          this.stopTick();
          this.emitState('paused', 0);
        } else if (!event.value && this.stateValue === 'paused') {
          this.stateValue = 'playing';
          this.startTick();
          this.emitState('playing', 0);
        }
      } else if (event.name === 'video-params/w' && typeof event.value === 'number') {
        this.pushVideoSize(event.value);
      }
    } else if (event.event === 'video-reconfig') {
      // 尺寸经 video-params/w 观察；这里作为兜底再读一次
      const w: number = mpvGetNumber(this.handle, 'video-params/w');
      const h: number = mpvGetNumber(this.handle, 'video-params/h');
      if (!Number.isNaN(w) && !Number.isNaN(h) && w > 0 && h > 0) {
        const cb = this.onVideoSize;
        if (cb !== null) {
          cb(w, h, 0);
        }
        // 字号锚在视频宽上（applySubStyle 里 prepare 时拿不到宽度，走的是 1080 回退），
        // 真实尺寸就位后必须重算一次，否则 4K 片字幕偏小
        this.applySubStyle(this.subFontScale, this.subBottomPercent, this.subBackground);
      }
    } else if (event.event === 'end-file') {
      const reason: number = event.reason ?? -1;
      if (reason === MpvPlayer.END_FILE_EOF) {
        this.stopTick();
        this.stateValue = 'completed';
        this.emitState('completed', 0);
      } else if (reason === MpvPlayer.END_FILE_ERROR) {
        this.stopTick();
        this.stateValue = 'error';
        const cb = this.onError;
        if (cb !== null) {
          const err: BusinessError = { code: 0, message: 'mpv end-file(ERROR)' } as BusinessError;
          cb(err);
        }
      }
      // STOP/QUIT 是自己发的 release，不产生事件
    } else if (event.event === 'audio-interrupt') {
      const cb = this.onInterrupt;
      if (cb !== null) {
        cb(MpvPlayer.interruptEvent(event.hint ?? 0));
      }
    } else if (event.event === 'log') {
      hilog.error(0x0000, 'MpvPlayer', 'mpv %{public}s: %{public}s',
        event.prefix ?? '', event.text ?? '');
    }
  }

  private pushVideoSize(width: number): void {
    const height: number = mpvGetNumber(this.handle, 'video-params/h');
    if (Number.isNaN(height) || height <= 0) {
      return;
    }
    const cb = this.onVideoSize;
    if (cb !== null) {
      cb(width, height, 0 as number);
    }
  }

  private static interruptEvent(hint: number): audio.InterruptEvent {
    let mapped: audio.InterruptHint = audio.InterruptHint.INTERRUPT_HINT_NONE;
    let ended: boolean = false;
    if (hint === MpvPlayer.HINT_RESUME) {
      mapped = audio.InterruptHint.INTERRUPT_HINT_RESUME;
      ended = true;
    } else if (hint === MpvPlayer.HINT_PAUSE) {
      mapped = audio.InterruptHint.INTERRUPT_HINT_PAUSE;
    } else if (hint === MpvPlayer.HINT_STOP) {
      mapped = audio.InterruptHint.INTERRUPT_HINT_STOP;
    }
    const ev: audio.InterruptEvent = {
      eventType: ended ? audio.InterruptType.INTERRUPT_TYPE_END
        : audio.InterruptType.INTERRUPT_TYPE_BEGIN,
      // 中断来自系统（来电/抢占），都是强制型
      forceType: audio.InterruptForceType.INTERRUPT_FORCE,
      hintType: mapped
    };
    return ev;
  }

  private static speedOf(speed: media.PlaybackSpeed): number {
    // 与系统 PlaybackSpeed 枚举逐档对齐（倍速弹层 0.5–3.0 全档可选）
    if (speed === media.PlaybackSpeed.SPEED_FORWARD_3_00_X) {
      return 3.0;
    }
    if (speed === media.PlaybackSpeed.SPEED_FORWARD_2_00_X) {
      return 2.0;
    }
    if (speed === media.PlaybackSpeed.SPEED_FORWARD_1_75_X) {
      return 1.75;
    }
    if (speed === media.PlaybackSpeed.SPEED_FORWARD_1_50_X) {
      return 1.5;
    }
    if (speed === media.PlaybackSpeed.SPEED_FORWARD_1_25_X) {
      return 1.25;
    }
    if (speed === media.PlaybackSpeed.SPEED_FORWARD_0_75_X) {
      return 0.75;
    }
    if (speed === media.PlaybackSpeed.SPEED_FORWARD_0_50_X) {
      return 0.5;
    }
    return 1.0;
  }

  private static ohosMediaType(mpvType: string | undefined): number {
    if (mpvType === 'video') {
      return media.MediaType.MEDIA_TYPE_VID;
    }
    if (mpvType === 'sub') {
      return media.MediaType.MEDIA_TYPE_SUBTITLE;
    }
    return media.MediaType.MEDIA_TYPE_AUD;
  }
}

/** PlayerPage 的引擎槽位：系统 AVPlayer 或 mpv（两边接口面刻意逐签名对齐，页面逻辑不用分支） */
export type PlayerEngine = media.AVPlayer | MpvPlayer;

/** mpv track-list JSON 里我们关心的字段 */
interface MpvTrackRaw {
  id: number;
  type: string;
  title?: string;
  lang?: string;
  default?: boolean;
  selected?: boolean;
}
