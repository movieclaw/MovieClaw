import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { createEngine, initEngine, destroyEngine, command, setProperty, tracks, MpvEvent } from 'libmovieclaw_mpv.so';
import { EngineEvent, EngineFailure, EngineSource, EngineTrack, PlayerEngine, SubtitleStyle } from './PlayerEngine';

interface NativeTrack {
  id: number;
  type: string;
  lang?: string;
  title?: string;
  selected?: boolean;
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
      try {
        if (source.subtitleFd >= 0) {
          await this.send(['sub-add', `fd://${source.subtitleFd}`, 'select']);
          hilog.info(0x0000, 'MCSub', '%{public}s', 'mpv sub-add fd 成功');
        } else if (source.subtitleUrl.length > 0) {
          await this.send(['sub-add', source.subtitleUrl, 'select']);
          hilog.info(0x0000, 'MCSub', '%{public}s', 'mpv sub-add url 成功');
        }
      } catch (error) {
        hilog.error(0x0000, 'MCSub', 'mpv sub-add 失败: %{public}s', `${error}`);
        const event = new EngineEvent(); event.type = 'diagnostic'; event.text = 'MPV 外挂字幕加载失败，继续播放'; this.onEvent(event);
      }
      await this.set('sub-delay', -(source.subtitleOffsetMs ?? 0) / 1000);
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
        // vo_gpu 的 OSD 合成层在本平台不绘制（libass 字幕与 show-text 自检均不可见）：
        // 解码出的字幕文本走事件交给应用层覆盖层渲染，与 avp 引擎共用同一条 subtitle 事件链。
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
    const reject = this.rejectOpen; this.rejectOpen = null; this.resolveOpen = null;
    if (reject !== null) { reject(new EngineFailure('internal', 0, '播放已取消')); }
    // Invalidate the native handle immediately, even if a command is still blocked.
    // Native workers retain ownership until their operations and teardown finish.
    this.releaseTask = destroyEngine(this.handle);
    return this.releaseTask;
  }
}
