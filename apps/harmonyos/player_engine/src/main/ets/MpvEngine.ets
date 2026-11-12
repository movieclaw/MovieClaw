import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { createEngine, initEngine, destroyEngine, command, setProperty, getProperty, tracks, MpvEvent } from 'libmovieclaw_mpv.so';
import { EngineEvent, EngineFailure, EngineSource, EngineTrack, PlayerEngine, SubtitleStyle } from './PlayerEngine';

interface NativeTrack {
  id: number;
  type: string;
  lang?: string;
  title?: string;
  selected?: boolean;
  codec?: string;
}

/**
 * mpv track-list codec 里的位图字幕家族（PGS/DVB/DVD/XSUB/teletext）：
 * 原生渲染、sub-text 恒空；其余（ass/subrip/webvtt/mov_text 等）是文字轨，
 * 交给 ArkTS 覆盖层，mpv 原生上屏层关掉。
 */
const BITMAP_SUBTITLE_CODECS: string[] =
  ['hdmv_pgs_subtitle', 'pgssub', 'dvd_subtitle', 'dvb_subtitle', 'xsub', 'dvb_teletext'];

function isTextualSubtitleCodec(codec: string): boolean {
  return codec.length > 0 && !BITMAP_SUBTITLE_CODECS.includes(codec);
}

/** Loaded only when the factory selects MPV. No AVPlayer-shaped compatibility API. */
export class MpvEngine implements PlayerEngine {
  readonly id: 'mpv' = 'mpv';
  onEvent: (event: EngineEvent) => void = (): void => {};
  private handle: number = createEngine();
  private released: boolean = false;
  private tail: Promise<void> = Promise.resolve();
  private releaseTask: Promise<void> | null = null;
  private resolveOpen: (() => void) | null = null;
  private rejectOpen: ((failure: EngineFailure) => void) | null = null;
  private duration: number = 0;
  private width: number = 0;
  private height: number = 0;
  private hwdec: string = '';
  private videoFormat: string = '';
  private pixelFormat: string = '';
  private ready: boolean = false;
  private eof: boolean = false;
  private paused: boolean = true;
  /** 本引擎 sub-add 挂上的旁挂轨 id（open 与 attachSubtitle 都记），换轨时 sub-remove。 */
  private sidecarIds: number[] = [];
  // ---- 视频冻结看门狗 ---------------------------------------------------
  // 按需 HLS 流里服务端产不出的分片会 404，mpv 跳段后 per-segment-moov 的视频
  // 流 demux 死亡（video 0 包），音频却照常整集入队：time-pos 持续走、画面永久
  // 停帧，一切基于位置的检测全部失明。唯一能区分「在播」与「画面活着」的信
  // 号是 video-out-pts（最后上屏帧 PTS）。定时采样：时钟在走而上屏帧 PTS 连
  // 续多拍静止 = 画面冻结，发 frozen 事件交宿主就地重开恢复。
  private static readonly watchdogIntervalMs: number = 2000;
  private static readonly frozenSamplesToFire: number = 4;
  private watchdogTimer: number = -1;
  private lastTimePos: number = -1;
  private lastVoPts: number = -1;
  private frozenSamples: number = 0;
  private frozenFired: boolean = false;
  private cachePaused: boolean = false;
  private watchdogSampleLogged: boolean = false;
  // time-pos 属性事件水位（receive 记录）：暂停事件被洪峰丢弃 / 属性读取失败时的
  // 自愈依据——事件仍在推进 = 时钟在走 = 实际在播。
  private lastTimePosEventMs: number = 0;
  private lastTimePosEventValue: number = 0;
  private watchdogTickLogged: boolean = false;
  private watchdogHealLogged: boolean = false;
  private watchdogNumberFailLogged: boolean = false;
  private watchdogEventFallbackLogged: boolean = false;
  private watchdogDecodedLogged: boolean = false;

  async open(source: EngineSource, surfaceId: string): Promise<void> {
    const loaded = new Promise<void>((resolve, reject): void => {
      this.resolveOpen = resolve; this.rejectOpen = reject;
    });
    // Install a rejection observer immediately: initialization can fail before loadfile.
    loaded.catch((): void => {});
    try {
      await initEngine(this.handle, {
        'vo': 'gpu', 'gpu-api': 'vulkan', 'gpu-context': 'ohosvk', 'ao': 'ohaudio',
        // Buffer-mode hardware decode. The dex2oat fork (vd_lavc.c select_and_set_hwdec)
        // only accepts ohcodec surface entries for vo=ohcodec* VOs; under vo=gpu the
        // surface entry "ohcodec" is skipped and playback silently falls back to
        // software decoding. "ohcodec-copy" is the contract for GL VOs (fork comment:
        // "vo=gpu-next + hwdec=ohcodec-copy"): the OHCodec decoder outputs NV12
        // system-memory frames which the ra_hwdec_ohcodec interop uploads to the GPU.
        'hwdec': 'ohcodec-copy',
        // The host sizes the surface for fit/fill/stretch, just as for AVPlayer.
        'wid': surfaceId, 'pause': 'yes', 'keep-open': 'yes', 'keepaspect': 'no',
        'sub-fonts-dir': '/system/fonts', 'tls-verify': 'yes',
        // mpv 内部日志按模块放开（其余压到 warn）：字幕加载/选择/渲染走
        // MpvLog 进 hilog，用于排查「sid 选中但不渲染」类问题。
        'msg-level': 'all=warn,sub=v,dec_sub=v,ass=v,osd=v,cplayer=info'
      }, (event: MpvEvent): void => this.receive(event));
      if (this.released) { return; }
      await this.send(['loadfile', source.fd >= 0 ? `fd://${source.fd}` : source.url, 'replace']);
      await loaded;
      // 外挂文字字幕（ass/srt/vtt）关掉 mpv 原生上屏层：sub-visibility=no 仍选择并解码，
      // sub-text 事件照常触发（mpv 手册：The current subtitle text regardless of sub
      // visibility），ArkTS 覆盖层成为唯一渲染层——与 avp/iOS/Android 同构。
      // 位图（PGS）与未知 .sub 保持原生渲染（sub-text 恒空，覆盖层无事可做）。
      // 每次打开都显式重设，避免上一次播放的设置残留到本次默认轨。
      const format = source.subtitleFormat ?? '';
      const textSub = format === 'ass' || format === 'srt' || format === 'vtt';
      await this.set('sub-visibility', textSub ? 'no' : 'yes');
      const baseIds = await this.subTrackIds();
      try {
        if (source.subtitleFd >= 0) {
          await this.send(['sub-add', `fd://${source.subtitleFd}`, 'select']);
          hilog.info(0x0000, 'MCSub', '%{public}s', 'mpv sub-add fd 成功');
        } else if (source.subtitleUrl.length > 0) {
          await this.send(['sub-add', source.subtitleUrl, 'select']);
          hilog.info(0x0000, 'MCSub', '%{public}s', 'mpv sub-add url 成功');
        }
        this.sidecarIds = await this.newSubIds(baseIds);
      } catch (error) {
        hilog.error(0x0000, 'MCSub', 'mpv sub-add 失败: %{public}s', `${error}`);
        const event = new EngineEvent(); event.type = 'diagnostic'; event.text = 'MPV 外挂字幕加载失败，继续播放'; this.onEvent(event);
      }
      await this.set('sub-delay', -(source.subtitleOffsetMs ?? 0) / 1000);
      this.startWatchdog();
    } catch (error) {
      if (error instanceof EngineFailure) { throw error; }
      const native = error as BusinessError;
      throw new EngineFailure('unavailable', native.code ?? -1, 'MPV 初始化失败');
    }
  }
  private send(args: string[]): Promise<void> {
    const task = this.tail.then(async (): Promise<void> => {
      if (this.released) { return; }
      await command(this.handle, args);
    });
    this.tail = task.catch((): void => {});
    return task;
  }
  private set(name: string, value: string | number | boolean): Promise<void> {
    const task = this.tail.then(async (): Promise<void> => {
      if (this.released) { return; }
      await setProperty(this.handle, name, value);
    });
    this.tail = task.catch((): void => {});
    return task;
  }
  async play(): Promise<void> { await this.set('pause', false); }
  async pause(): Promise<void> { await this.set('pause', true); }
  async seek(positionMs: number): Promise<void> { await this.send(['seek', `${positionMs / 1000}`, 'absolute+exact']); }
  async setRate(rate: number): Promise<void> { await this.set('speed', rate); }
  async setGain(gain: number): Promise<void> { await this.set('volume', gain * 100); }
  async tracks(): Promise<EngineTrack[]> {
    const list: NativeTrack[] = JSON.parse(await tracks(this.handle)) as NativeTrack[];
    return list.map((track: NativeTrack): EngineTrack => {
      return { id: track.id, kind: track.type === 'sub' ? 'subtitle' : track.type,
        language: track.lang ?? '', title: track.title ?? '', selected: track.selected === true };
    });
  }
  async selectTrack(kind: string, id: number): Promise<void> {
    await this.set(kind === 'audio' ? 'aid' : 'sid', id < 0 ? 'no' : `${id}`);
    if (kind !== 'subtitle') { return; }
    // 内封字幕轨经 sid 直选/关闭后，按新轨的 codec 重判上屏层：文字轨继续交给覆盖层
    // （sub-text 与 sub-visibility 无关，事件照常），位图轨恢复原生渲染；关闭字幕时复位。
    try {
      const list: NativeTrack[] = JSON.parse(await tracks(this.handle)) as NativeTrack[];
      const chosen = list.find((track: NativeTrack): boolean => track.type === 'sub' && track.selected === true);
      await this.set('sub-visibility',
        chosen !== undefined && isTextualSubtitleCodec(chosen.codec ?? '') ? 'no' : 'yes');
    } catch (error) {
      hilog.warn(0x0000, 'MCSub', '内封字幕轨 sub-visibility 重判失败: %{public}s', `${error}`);
    }
  }
  async setSubtitleStyle(style: SubtitleStyle): Promise<void> {
    // sub-font-size 的量纲是 720 高的画布：ass_mp.c 的换算是
    // libass_font_size = FontSize × window_height / PlayResY（scale 以 720 折算），
    // 即 N 渲染为 N/720 的视频高、与分辨率无关。这里取 fontScale% 视频高，
    // 与自绘字幕锚视频高同一语义。
    const fontSize = Math.max(16, Math.round(720 * style.fontScale / 100));
    await this.set('sub-font-size', fontSize).catch((): void => {});
    await this.set('sub-pos', 100 - style.bottomPercent).catch((): void => {});
    await this.set('sub-border-style', style.background ? 'background-box' : 'outline-and-shadow').catch((): void => {});
  }
  /**
   * 在播时就地换旁挂字幕，不重开流。mpv 的 track-list 会随每次 sub-add 一直涨，
   * 换轨前先把本引擎挂过的旁挂轨 sub-remove 掉；三个字幕源全空 = 只卸不加（裸播，
   * 等 PGS 后台下载完再挂）。文字轨照旧关原生上屏交给覆盖层，位图（.sup）原生渲染；
   * sub-delay 对齐时间轴（与 open 同一口径）。id 用 sub-add 前后的 track-list 差集
   * 认定——不依赖 mpv 是否复用被释放的轨号。
   */
  async attachSubtitle(source: EngineSource): Promise<void> {
    for (const id of this.sidecarIds) {
      await this.send(['sub-remove', `${id}`]).catch((): void => {});
    }
    this.sidecarIds = [];
    const target = source.subtitlePath ?? (source.subtitleFd >= 0 ? `fd://${source.subtitleFd}` : source.subtitleUrl);
    if (target.length === 0) {
      await this.set('sid', 'no');
      hilog.info(0x0000, 'MCSub', '%{public}s', 'mpv 旁挂已卸载（裸播）');
      return;
    }
    const format = source.subtitleFormat ?? '';
    const textSub = format === 'ass' || format === 'srt' || format === 'vtt';
    await this.set('sub-visibility', textSub ? 'no' : 'yes');
    const baseIds = await this.subTrackIds();
    await this.send(['sub-add', target, 'select']);
    await this.set('sub-delay', -(source.subtitleOffsetMs ?? 0) / 1000);
    this.sidecarIds = await this.newSubIds(baseIds);
    hilog.info(0x0000, 'MCSub', 'mpv live sub-add 成功: format=%{public}s sid=%{public}s',
      format, this.sidecarIds.join(','));
  }
  private async subTrackIds(): Promise<number[]> {
    try {
      const list: NativeTrack[] = JSON.parse(await tracks(this.handle)) as NativeTrack[];
      return list.filter((track: NativeTrack): boolean => track.type === 'sub')
        .map((track: NativeTrack): number => track.id);
    } catch (error) {
      return [];
    }
  }
  private async newSubIds(base: number[]): Promise<number[]> {
    const current = await this.subTrackIds();
    return current.filter((id: number): boolean => !base.includes(id));
  }
  private startWatchdog(): void {
    this.stopWatchdog();
    this.lastTimePos = -1; this.lastVoPts = -1;
    this.frozenSamples = 0; this.frozenFired = false;
    this.watchdogSampleLogged = false;
    this.watchdogTickLogged = false; this.watchdogHealLogged = false;
    this.watchdogNumberFailLogged = false; this.watchdogEventFallbackLogged = false;
    this.watchdogDecodedLogged = false;
    this.watchdogTimer = setInterval((): void => { this.sampleWatchdog(); }, MpvEngine.watchdogIntervalMs);
    hilog.info(0x0000, 'MCSub', 'mpv 看门狗启动: interval=%{public}s ms', `${MpvEngine.watchdogIntervalMs}`);
  }
  private stopWatchdog(): void {
    if (this.watchdogTimer >= 0) { clearInterval(this.watchdogTimer); this.watchdogTimer = -1; }
  }
  private async sampleWatchdog(): Promise<void> {
    if (this.released || this.frozenFired || !this.ready) { return; }
    if (!this.watchdogTickLogged) {
      this.watchdogTickLogged = true;
      hilog.info(0x0000, 'MCSub', 'mpv 看门狗首拍: paused=%{public}s eof=%{public}s cachePaused=%{public}s',
        `${this.paused}`, `${this.eof}`, `${this.cachePaused}`);
    }
    // 暂停、缓冲、停在片尾时画面本就静止：重置基线，恢复播放后从新基线起判。
    // 例外：unpause 属性事件可能在事件洪峰（404 风暴/日志刷屏）里被线程安全队
    // 列满载丢弃，paused 卡在 true；time-pos 事件两拍内仍在推进说明时钟在走，
    // 按播放中自愈，避免看门狗在最需要它的卡死场景失明。
    const eventFreshMs = Date.now() - this.lastTimePosEventMs;
    const timeEventFresh = this.lastTimePosEventMs > 0 &&
      eventFreshMs < MpvEngine.watchdogIntervalMs * 2;
    const pausedStale = this.paused && timeEventFresh;
    if (pausedStale && !this.watchdogHealLogged) {
      this.watchdogHealLogged = true;
      hilog.warn(0x0000, 'MCSub', '%{public}s', 'mpv 看门狗暂停态与时间事件矛盾，按播放中处理');
    }
    if ((this.paused && !pausedStale) || this.eof || this.cachePaused) {
      this.lastTimePos = -1; this.lastVoPts = -1; this.frozenSamples = 0; return;
    }
    let timePos = await this.readPos('time-pos');
    if (this.released || this.frozenFired) { return; }
    if (!Number.isFinite(timePos) && timeEventFresh) {
      // getProperty 两条格式都拿不到 time-pos：退用仍在推进的属性事件值。
      timePos = this.lastTimePosEventValue;
      if (!this.watchdogEventFallbackLogged) {
        this.watchdogEventFallbackLogged = true;
        hilog.warn(0x0000, 'MCSub', 'mpv 看门狗 time-pos 读取失败，改用属性事件值: %{public}s',
          `${this.lastTimePosEventValue}`);
      }
    }
    let voPts = await this.readPos('video-out-pts');
    if (this.released || this.frozenFired) { return; }
    if (!Number.isFinite(voPts)) {
      // video-out-pts 在个别移植/渲染器上可能不可用：退而求其次用解码帧计数做
      // 活性信号——解码器断粮时计数静止，与上屏 PTS 停滞同效（判据 |Δ|<0.05
      // 对整数计数同样成立）。
      const decoded = await this.readPos('decoded-video-frames');
      if (this.released || this.frozenFired) { return; }
      if (Number.isFinite(decoded)) {
        voPts = decoded;
        if (!this.watchdogDecodedLogged) {
          this.watchdogDecodedLogged = true;
          hilog.warn(0x0000, 'MCSub',
            'mpv 看门狗 video-out-pts 不可用，改用 decoded-video-frames: %{public}s', `${decoded}`);
        }
      }
    }
    // 任一属性拿不到（未起播、纯音频没有视频帧）都静默等下一拍，不误报。
    if (!Number.isFinite(timePos) || !Number.isFinite(voPts)) {
      this.lastTimePos = -1; this.lastVoPts = -1; this.frozenSamples = 0; return;
    }
    // 首次拿到有效采样：证明定时器与属性读取在真机上确实工作（无此日志=看门狗失效）。
    if (!this.watchdogSampleLogged) {
      this.watchdogSampleLogged = true;
      hilog.info(0x0000, 'MCSub', 'mpv 看门狗采样: time-pos=%{public}s vo-pts=%{public}s',
        timePos.toFixed(1), voPts.toFixed(1));
    }
    if (this.lastTimePos < 0 || this.lastVoPts < 0) {
      this.lastTimePos = timePos; this.lastVoPts = voPts; this.frozenSamples = 0; return;
    }
    const clockDelta = timePos - this.lastTimePos;
    const videoDelta = voPts - this.lastVoPts;
    this.lastTimePos = timePos; this.lastVoPts = voPts;
    if (clockDelta >= 1 && Math.abs(videoDelta) < 0.05) {
      this.frozenSamples++;
      // 停滞过半（约 4 秒）先留痕：便于事后判断跳段缺口停顿是否逼近触发线。
      if (this.frozenSamples === 2) {
        hilog.info(0x0000, 'MCSub', 'mpv 画面疑似停滞: time-pos=%{public}s vo-pts=%{public}s 时钟仍在走',
          timePos.toFixed(1), voPts.toFixed(1));
      }
    } else { this.frozenSamples = 0; }
    if (this.frozenSamples < MpvEngine.frozenSamplesToFire) { return; }
    this.frozenFired = true; this.stopWatchdog();
    hilog.error(0x0000, 'MCSub',
      'mpv 视频冻结: time-pos=%{public}s vo-pts=%{public}s 静止约 %{public}s 秒，通知宿主重开',
      timePos.toFixed(1), voPts.toFixed(1),
      `${Math.round(MpvEngine.frozenSamplesToFire * MpvEngine.watchdogIntervalMs / 1000)}`);
    const event = new EngineEvent();
    event.type = 'frozen';
    event.positionMs = Math.round(timePos * 1000);
    this.onEvent(event);
  }
  /**
   * 读 mpv 数值属性。number 格式（MPV_FORMAT_DOUBLE）若在真机上抛错/返回非数，
   * 先留痕再退 string 格式重读解析（mpv_get_property_string 另一条原生路径）；
   * 两条路都失败才放弃（返回 NaN，调用方静默等下一拍）。
   */
  private async readPos(name: string): Promise<number> {
    try {
      const value = await getProperty(this.handle, name, 'number');
      if (typeof value === 'number' && Number.isFinite(value)) { return value; }
      if (!this.watchdogNumberFailLogged) {
        this.watchdogNumberFailLogged = true;
        hilog.warn(0x0000, 'MCSub', 'mpv 看门狗 number 读取异常: %{public}s=%{public}s', name, `${value}`);
      }
    } catch (error) {
      if (!this.watchdogNumberFailLogged) {
        this.watchdogNumberFailLogged = true;
        hilog.warn(0x0000, 'MCSub', 'mpv 看门狗 number 读取失败: %{public}s err=%{public}s', name, `${error}`);
      }
    }
    try {
      const text = await getProperty(this.handle, name, 'string');
      const parsed = typeof text === 'string' ? Number(text) : NaN;
      if (Number.isFinite(parsed)) { return parsed; }
    } catch (error) {
      // string 路径也失败：NaN 交还调用方静默等下一拍。
    }
    return NaN;
  }
  /** Push the accumulated local decode state so the diagnostics panel can show it. */
  private emitDecode(): void {
    const event = new EngineEvent();
    event.type = 'decode';
    event.hwdec = this.hwdec;
    event.codec = this.videoFormat;
    event.pixelFormat = this.pixelFormat;
    event.width = this.width;
    event.height = this.height;
    this.onEvent(event);
  }
  private receive(native: MpvEvent): void {
    if (this.released) { return; }
    const event = new EngineEvent();
    if (native.type === 'diagnostic') {
      hilog.info(0x0000, 'MpvLog', '%{public}s', native.text);
      event.type = 'diagnostic';
      event.text = native.text.replace(/https?:\/\/[^\s"'<>]+/g, '[media URL]');
      this.onEvent(event); return;
    }
    if (native.type === 'ready') {
      this.ready = true;
      const resolve = this.resolveOpen;
      this.resolveOpen = null; this.rejectOpen = null;
      if (resolve !== null) { resolve(); }
      return;
    }
    if (native.type === 'end') {
      if (native.reason === 0) { event.type = 'state'; event.state = 'ended'; }
      else if (native.reason === 4) {
        // MPV_ERROR_* codes: -16 loading failed, -17 AO init, -18 VO init,
        // -19 nothing to play, -20 unknown format, -21 unsupported, -22 not implemented.
        const kind = native.code >= -22 && native.code <= -16 ? 'unsupported'
          : native.code === -14 || native.code === -15 ? 'unavailable'
          : native.code === -13 ? 'source' : 'internal';
        const failure = new EngineFailure(kind, native.code, `MPV 播放失败（${native.code}）`);
        const reject = this.rejectOpen; this.rejectOpen = null; this.resolveOpen = null;
        if (reject !== null) { reject(failure); return; }
        event.type = 'error'; event.failure = failure;
      } else { return; }
    } else if (native.type === 'interrupt') {
      event.type = 'interrupt';
      event.hint = native.code === 1 ? 'resume' : native.code === 3 ? 'stop'
        : native.code === 4 ? 'duck' : native.code === 5 ? 'unduck' : 'pause';
    } else if (native.type === 'property') {
      if (native.name === 'time-pos') {
        this.lastTimePosEventMs = Date.now();
        this.lastTimePosEventValue = native.value;
        event.type = 'time'; event.positionMs = Math.round(native.value * 1000); event.durationMs = this.duration;
      } else if (native.name === 'demuxer-cache-duration') {
        event.type = 'buffered'; event.bufferedMs = Math.round(native.value * 1000);
      } else if (native.name === 'duration') {
        this.duration = Math.round(native.value * 1000); event.type = 'duration'; event.durationMs = this.duration;
      } else if (native.name === 'width' || native.name === 'height') {
        if (native.name === 'width') { this.width = native.value; } else { this.height = native.value; }
        event.type = 'size'; event.width = this.width; event.height = this.height;
        this.emitDecode();
      } else if (native.name === 'video-format') {
        this.videoFormat = native.text;
        this.emitDecode();
        return;
      } else if (native.name === 'video-params/pixelformat') {
        this.pixelFormat = native.text;
        this.emitDecode();
        return;
      } else if (native.name === 'eof-reached') {
        const wasEnded = this.eof;
        this.eof = native.value === 1;
        if (!this.ready || (!this.eof && !wasEnded)) { return; }
        event.type = 'state'; event.state = this.eof ? 'ended' : this.paused ? 'paused' : 'playing';
      } else if (native.name === 'pause' && this.ready) {
        // keep-open pauses at EOF; a later pause notification must not erase ended.
        this.paused = native.value === 1;
        if (this.eof) { return; }
        event.type = 'state'; event.state = this.paused ? 'paused' : 'playing';
      } else if (native.name === 'paused-for-cache') {
        this.cachePaused = native.value === 1;
        event.type = 'buffering'; event.hint = native.value === 1 ? 'start' : 'end';
      } else if (native.name === 'hwdec-current') {
        // Observed as MPV_FORMAT_STRING: runtime decoder id ("h264_ohcodec" etc.),
        // empty means software decoding. Surfaced as diagnostics so hardware
        // decoding can be confirmed from logs and the diagnostics panel.
        this.hwdec = native.text;
        event.type = 'diagnostic';
        event.text = native.text.length > 0 ? `MPV 硬解已启用: ${native.text}` : 'MPV 软件解码中';
        this.emitDecode();
      } else if (native.name === 'sub-text') {
        // sub-text 与 sub-visibility 无关（mpv 手册：current subtitle text regardless
        // of sub visibility, formatting stripped）。文字轨由 open()/selectTrack 设
        // sub-visibility=no 关掉原生上屏后，本事件是覆盖层的唯一数据源；位图轨
        // （PGS）sub-text 恒空，走 mpv 原生渲染。
        event.type = 'subtitle'; event.text = native.text;
      } else { return; }
    } else {
      // playback-restart confirms resumption, not a displayed first frame.
      return;
    }
    this.onEvent(event);
  }
  release(): Promise<void> {
    if (this.releaseTask !== null) { return this.releaseTask; }
    this.released = true; this.onEvent = (): void => {};
    this.sidecarIds = [];
    this.stopWatchdog();
    const reject = this.rejectOpen; this.rejectOpen = null; this.resolveOpen = null;
    if (reject !== null) { reject(new EngineFailure('internal', 0, '播放已取消')); }
    // Invalidate the native handle immediately, even if a command is still blocked.
    // Native workers retain ownership until their operations and teardown finish.
    this.releaseTask = destroyEngine(this.handle);
    return this.releaseTask;
  }
}
