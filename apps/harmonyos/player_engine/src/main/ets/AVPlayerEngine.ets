import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { EngineEvent, EngineFailure, EngineSource, EngineTrack, PlayerEngine, SubtitleStyle } from './PlayerEngine';

/** No UI, server sessions or library IDs cross this adapter. */
export class AVPlayerEngine implements PlayerEngine {
  readonly id: 'avplayer' = 'avplayer';
  // histreamer fires 'seekDone' when the seek command is accepted, not when the
  // target is actually delivered: a starved demuxer still acknowledges the seek
  // and the surface keeps a stale frame with no audio. The landing check in
  // seek() turns that silent stall into a recoverable failure.
  static seekVerifyWindowMs: number = 12000;
  static seekVerifyToleranceMs: number = 3000;
  private static readonly seekVerifyPollMs: number = 250;
  onEvent: (event: EngineEvent) => void = (): void => {};
  private player: media.AVPlayer | null = null;
  private released: boolean = false;
  private lastFailure: EngineFailure | null = null;
  private completeFailure: ((failure: EngineFailure | null) => void) | null = null;
  private rejectSeek: ((failure: EngineFailure) => void) | null = null;
  private completeOpen: (() => void) | null = null;
  private rejectOpen: ((error: EngineFailure) => void) | null = null;
  private timeUpdates: number = 0;
  // ---- 首帧后停滞看门狗 ------------------------------------------------
  // histreamer 的 HTTP 下载器在 Range 中途取消后可整体楔死（复用连接上旧响应
  // 未排空、后续请求被压在后面，2026-11-17 NAS 现场取证）：解码器吐完首帧后
  // 时钟停走、状态机仍报 playing 且不再回调 error——表象是黑屏无声、进度条
  // 钉死、恢复无门。首帧后轮询 currentTime，状态 playing 而连续多拍静止即发
  // frozen 事件；宿主 recoverFrozen 会就此重开接管（mpv）。起播前黑屏由宿主
  // 的启动超时兜底，这里只在 startRenderFrame 后武装。
  // 2026-11-17 深夜实测：续播/暂停恢复的 Range 重取常被网盘 CDN 派成停顿/低速
  // （15~120KB/s）的坏连接；服务端中继已改为窗口测速+换连接续传（一条请求最
  // 多 3 条上游连接，最坏 ~25 秒才续上流）。触发线必须盖过服务端重连窗口，
  // 让 AVP 吃到救回来的流自己续播，而不是半路掐掉换 mpv。
  private static readonly stallSampleIntervalMs: number = 2000;
  private static readonly stallSamplesToFire: number = 15;
  private static readonly stallMinAdvanceMs: number = 50;
  private stallTimer: number = -1;
  private stallSamples: number = 0;
  private stallFired: boolean = false;
  private stallLastClockMs: number = -1;
  private stallSeekActive: boolean = false;

  async open(source: EngineSource, surfaceId: string): Promise<void> {
    const player = await media.createAVPlayer();
    if (this.released) {
      await player.release();
      throw new EngineFailure('internal', 0, '播放已取消');
    }
    this.player = player;
    const ready = new Promise<void>((resolve, reject): void => {
      this.completeOpen = resolve;
      this.rejectOpen = reject;
    });
    player.on('error', (error: BusinessError): void => {
      hilog.warn(0x0000, 'MCSub', 'avplayer error 回调: code=%{public}d msg=%{public}s', error.code, error.message);
      if (error.code === 5400107) {
        const event = new EngineEvent(); event.type = 'interrupt'; event.hint = 'pause';
        this.onEvent(event); return;
      }
      this.fail(this.failure(error));
    });
    player.on('stateChange', (state: string): void => {
      if (this.released) { return; }
      if (state === 'initialized') {
        player.surfaceId = surfaceId;
        this.prepare(source).catch((error: BusinessError): void => {
          // prepare() can reject with 5400102 before the error callback supplies the
          // actual decoder/format failure. Preserve that callback for fallback policy.
          if (player.state === 'error' || this.released) { return; }
          this.fail(new EngineFailure(error.code === 5400106 ? 'unsupported' : error.code === 5400103 ? 'source' : 'internal', error.code, '系统播放器无法打开媒体或字幕'));
        });
      } else if (state === 'prepared') {
        const event = new EngineEvent(); event.type = 'duration'; event.durationMs = player.duration; this.onEvent(event);
        const done = this.completeOpen;
        this.completeOpen = null;
        this.rejectOpen = null;
        if (done !== null) { done(); }
      } else if (state === 'playing' || state === 'paused' || state === 'completed') {
        const event = new EngineEvent();
        event.type = 'state';
        event.state = state === 'completed' ? 'ended' : state;
        this.onEvent(event);
      }
    });
    player.on('timeUpdate', (time: number): void => {
      this.timeUpdates++;
      const event = new EngineEvent();
      event.type = 'time'; event.positionMs = time; event.durationMs = player.duration;
      this.onEvent(event);
    });
    player.on('durationUpdate', (duration: number): void => {
      const event = new EngineEvent(); event.type = 'duration'; event.durationMs = duration;
      this.onEvent(event);
    });
    player.on('videoSizeChange', (width: number, height: number): void => {
      const event = new EngineEvent(); event.type = 'size'; event.width = width; event.height = height;
      this.onEvent(event);
    });
    player.on('bufferingUpdate', (type: media.BufferingInfoType, value: number): void => {
      if (type === media.BufferingInfoType.BUFFERING_START || type === media.BufferingInfoType.BUFFERING_END) {
        const event = new EngineEvent(); event.type = 'buffering';
        event.hint = type === media.BufferingInfoType.BUFFERING_START ? 'start' : 'end';
        this.onEvent(event);
      } else if (type === media.BufferingInfoType.CACHED_DURATION) {
        const event = new EngineEvent(); event.type = 'buffered'; event.bufferedMs = value;
        this.onEvent(event);
      }
    });
    player.on('startRenderFrame', (): void => {
      const event = new EngineEvent(); event.type = 'firstFrame'; this.onEvent(event);
      this.startStallWatchdog();
    });
    player.on('subtitleUpdate', (info: media.SubtitleInfo): void => {
      const event = new EngineEvent(); event.type = 'subtitle'; event.text = info.text ?? '';
      this.onEvent(event);
    });
    player.on('audioInterrupt', (interrupt: audio.InterruptEvent): void => {
      const event = new EngineEvent(); event.type = 'interrupt';
      switch (interrupt.hintType) {
        case audio.InterruptHint.INTERRUPT_HINT_RESUME: event.hint = 'resume'; break;
        case audio.InterruptHint.INTERRUPT_HINT_DUCK: event.hint = 'duck'; break;
        case audio.InterruptHint.INTERRUPT_HINT_UNDUCK: event.hint = 'unduck'; break;
        case audio.InterruptHint.INTERRUPT_HINT_STOP: event.hint = 'stop'; break;
        case audio.InterruptHint.INTERRUPT_HINT_PAUSE: event.hint = 'pause'; break;
        default:
          // Focus gain (INTERRUPT_HINT_NONE) and unknown hints are the audio session
          // churn of an engine swap. Mapping them to pause cancelled the startup
          // watchdog and froze playback; the audio server re-asserts real
          // interruptions against the new session, so they are safe to ignore.
          hilog.info(0x0000, 'MCSub', 'avplayer interrupt 忽略 NONE/未知: hint=%{public}d event=%{public}d',
            interrupt.hintType, interrupt.eventType);
          return;
      }
      hilog.info(0x0000, 'MCSub', 'avplayer interrupt: hint=%{public}s event=%{public}d',
        event.hint, interrupt.eventType);
      this.onEvent(event);
    });
    if (source.fd >= 0) {
      player.fdSrc = { fd: source.fd, offset: 0, length: source.length };
    } else {
      player.url = source.url;
    }
    await ready;
  }

  private async prepare(source: EngineSource): Promise<void> {
    const player = this.player;
    if (player === null || this.released) { return; }
    try {
      if (source.subtitleFd >= 0) { await player.addSubtitleFromFd(source.subtitleFd); }
      else if (source.subtitleUrl.length > 0) { await player.addSubtitleFromUrl(source.subtitleUrl); }
    } catch (error) {
      const event = new EngineEvent(); event.type = 'diagnostic'; event.text = '系统播放器外挂字幕加载失败，继续播放'; this.onEvent(event);
    }
    if (!this.released) { await player.prepare(); }
  }

  private failure(error: BusinessError): EngineFailure {
    // 5400103 covers audio/graphics/source IO. Explicit audio-output and demux
    // failures may switch engines; network failures must not.
    const kind = error.code === 5400106 ? 'unsupported'
      : error.code === 5400103 && error.message.includes('AUD_OUTPUT_ERR') ? 'unavailable'
      : error.code === 5400103 && error.message.includes('DEM_PARSE_ERR') ? 'decode'
      : error.code >= 5411001 && error.code <= 5411012 ? 'network'
      : error.code === 5400103 ? 'source'
      : error.code === 5400104 ? 'timeout'
      : error.code === 801 || error.code === 5400105 ? 'unavailable' : 'internal';
    return new EngineFailure(kind, error.code, `系统播放器错误（${error.code}）`);
  }

  private fail(failure: EngineFailure): void {
    if (this.released) { return; }
    if (this.lastFailure === null) { this.lastFailure = failure; }
    this.rejectSeek?.(failure); this.rejectSeek = null;
    this.completeFailure?.(failure);
    const reject = this.rejectOpen;
    this.rejectOpen = null; this.completeOpen = null;
    if (reject !== null) { reject(failure); }
    else {
      const event = new EngineEvent(); event.type = 'error'; event.failure = failure;
      this.onEvent(event);
    }
  }

  /** histreamer 没有运行中换外挂字幕的可靠通道；宿主只在 mpv 在播时走动态挂载。 */
  async attachSubtitle(source: EngineSource): Promise<void> {
    throw new EngineFailure('unsupported', 0, '系统播放器不支持动态挂载字幕');
  }
  async play(): Promise<void> {
    try { await this.player?.play(); }
    catch (error) {
      // The command can reject before the error callback supplies the cause.
      // Keep the adapter alive briefly so the controller receives that cause.
      const failure = this.lastFailure ?? await new Promise<EngineFailure | null>((resolve): void => {
        const timer = setTimeout((): void => { this.completeFailure = null; resolve(null); }, 1000);
        this.completeFailure = (value: EngineFailure | null): void => {
          clearTimeout(timer); this.completeFailure = null; resolve(value);
        };
      });
      throw failure ?? this.failure(error as BusinessError);
    }
  }
  async pause(): Promise<void> {
    // Reopening while paused leaves AVPlayer prepared; pause() is only legal while playing.
    if (this.player?.state === 'playing') { await this.player.pause(); }
  }
  async seek(positionMs: number): Promise<void> {
    const player = this.player;
    if (player === null || this.released) { return; }
    // histreamer acknowledges seeks with seekDone while the position only reflects
    // the command afterwards, and remote HLS can jump currentTime without ever
    // rendering again. Direction decides the landing test (a backward seek must
    // come back down, a forward seek must climb past the target), and only a
    // timeUpdate that arrived after this command makes currentTime trustworthy —
    // a bare seekDone with stale pre-seek ticks proves nothing.
    // 在途 seek（含落地校验窗口）期间 currentTime 静止是常态，停滞计数一律
    // 暂停并在结束时重置；seek 超时由本方法自己的校验窗口负责上报。
    this.stallSeekActive = true;
    try {
      const seekWasBackward = positionMs < player.currentTime;
      const updatesBeforeSeek = this.timeUpdates;
      await new Promise<void>((resolve, reject): void => {
        this.rejectSeek = reject;
        const done = (): void => {
          player.off('seekDone', done); this.rejectSeek = null; resolve();
        };
        player.on('seekDone', done);
        try { player.seek(Math.round(positionMs), media.SeekMode.SEEK_CLOSEST); }
        catch (error) {
          player.off('seekDone', done); this.rejectSeek = null;
          reject(new EngineFailure('internal', 0, '系统播放器跳转失败'));
        }
      });
      if (this.released || player !== this.player || player.state !== 'playing') { return; }
      const tolerance = AVPlayerEngine.seekVerifyToleranceMs;
      const delivered = (): boolean => this.timeUpdates !== updatesBeforeSeek
        && (seekWasBackward ? player.currentTime <= positionMs + tolerance
          : player.currentTime >= positionMs - tolerance);
      if (delivered()) { return; }
      const deadline = Date.now() + AVPlayerEngine.seekVerifyWindowMs;
      while (Date.now() < deadline && !this.released && this.player === player) {
        await new Promise<void>((resolve): void => {
          setTimeout((): void => { resolve(); }, AVPlayerEngine.seekVerifyPollMs);
        });
        if (delivered()) { return; }
      }
      if (this.released || this.player !== player) { return; }
      hilog.warn(0x0000, 'MCSub', 'avplayer seek 未到位判停滞: target=%{public}d current=%{public}d',
        positionMs, player.currentTime);
      throw new EngineFailure('timeout', 0, '系统播放器跳转无响应');
    } finally {
      this.stallSeekActive = false;
      this.stallLastClockMs = -1;
      this.stallSamples = 0;
    }
  }
  /** 首帧后武装：只盯「状态机说 playing 而时钟停走」的楔死（mpv 的判据相反）。 */
  private startStallWatchdog(): void {
    if (this.stallTimer >= 0 || this.released) { return; }
    this.stallSamples = 0;
    this.stallFired = false;
    this.stallLastClockMs = -1;
    this.stallTimer = setInterval((): void => { this.sampleStall(); }, AVPlayerEngine.stallSampleIntervalMs);
    hilog.info(0x0000, 'MCSub', 'avplayer 停滞看门狗启动: interval=%{public}d ms 触发=%{public}d 拍',
      AVPlayerEngine.stallSampleIntervalMs, AVPlayerEngine.stallSamplesToFire);
  }

  private stopStallWatchdog(): void {
    if (this.stallTimer >= 0) {
      clearInterval(this.stallTimer);
      this.stallTimer = -1;
    }
  }

  private sampleStall(): void {
    const player = this.player;
    if (this.released || this.stallFired || player === null) { return; }
    if (this.stallSeekActive || player.state !== 'playing') {
      this.stallLastClockMs = -1;
      this.stallSamples = 0;
      return;
    }
    const clockMs = player.currentTime;
    if (this.stallLastClockMs < 0 || clockMs - this.stallLastClockMs > AVPlayerEngine.stallMinAdvanceMs) {
      this.stallLastClockMs = clockMs;
      this.stallSamples = 0;
      return;
    }
    this.stallSamples++;
    // 停滞过半（约 15 秒）先留痕：便于事后区分正常缓冲与逼近触发线的楔死。
    if (this.stallSamples === Math.floor(AVPlayerEngine.stallSamplesToFire / 2)) {
      hilog.warn(0x0000, 'MCSub', 'avplayer 时钟疑似停滞: current=%{public}d 已静止 %{public}d 拍',
        clockMs, this.stallSamples);
    }
    if (this.stallSamples < AVPlayerEngine.stallSamplesToFire) { return; }
    this.stallFired = true;
    this.stopStallWatchdog();
    hilog.error(0x0000, 'MCSub',
      'avplayer 时钟停滞: current=%{public}d 状态 playing 静止约 %{public}d 毫秒，通知宿主接管',
      clockMs, AVPlayerEngine.stallSamplesToFire * AVPlayerEngine.stallSampleIntervalMs);
    const event = new EngineEvent();
    event.type = 'frozen';
    event.positionMs = Math.round(clockMs);
    this.onEvent(event);
  }
  async setRate(rate: number): Promise<void> {
    const player = this.player;
    if (player === null) { return; }
    const speed: media.PlaybackSpeed = rate === 2 ? media.PlaybackSpeed.SPEED_FORWARD_2_00_X
      : rate === 1.5 ? media.PlaybackSpeed.SPEED_FORWARD_1_50_X
      : rate === 1.25 ? media.PlaybackSpeed.SPEED_FORWARD_1_25_X
      : rate === 0.75 ? media.PlaybackSpeed.SPEED_FORWARD_0_75_X
      : rate === 0.5 ? media.PlaybackSpeed.SPEED_FORWARD_0_50_X : media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
    player.setSpeed(speed);
  }
  async setGain(gain: number): Promise<void> { this.player?.setVolume(gain); }
  async tracks(): Promise<EngineTrack[]> {
    const descriptions = await this.player?.getTrackDescription();
    if (descriptions === undefined) { return []; }
    let audioId = -1; let subtitleId = -1;
    try { audioId = await this.player!.getCurrentTrack(media.MediaType.MEDIA_TYPE_AUD); } catch (error) {}
    try { subtitleId = await this.player!.getCurrentTrack(media.MediaType.MEDIA_TYPE_SUBTITLE); } catch (error) {}
    const tracks: EngineTrack[] = [];
    for (const description of descriptions) {
      tracks.push({ id: description['track_index'] as number,
        kind: description['track_type'] === 0 ? 'audio' : description['track_type'] === 2 ? 'subtitle' : 'video',
        language: description['language'] as string ?? '', title: '',
        selected: description['track_index'] === audioId || description['track_index'] === subtitleId });
    }
    return tracks;
  }
  async selectTrack(kind: string, id: number): Promise<void> {
    const player = this.player;
    if (player === null) { return; }
    if (id >= 0) { await player.selectTrack(id); }
    else if (kind === 'subtitle') {
      const descriptions = await this.tracks();
      if (!descriptions.some((track: EngineTrack): boolean => track.kind === 'subtitle')) { return; }
      let selected = -1;
      try { selected = await player.getCurrentTrack(media.MediaType.MEDIA_TYPE_SUBTITLE); }
      catch (error) { return; } // No active subtitle track is already the requested state.
      for (const track of descriptions) {
        if (track.kind === 'subtitle' && selected === track.id) { await player.deselectTrack(track.id); }
      }
    }
  }
  async setSubtitleStyle(style: SubtitleStyle): Promise<void> { /* Text is rendered by the host. */ }
  async release(): Promise<void> {
    if (this.released) { return; }
    this.released = true;
    this.stopStallWatchdog();
    this.completeFailure?.(null);
    this.rejectSeek?.(new EngineFailure('internal', 0, '播放已取消'));
    this.rejectSeek = null;
    const reject = this.rejectOpen;
    this.rejectOpen = null; this.completeOpen = null;
    if (reject !== null) { reject(new EngineFailure('internal', 0, '播放已取消')); }
    const player = this.player; this.player = null;
    this.onEvent = (): void => {};
    if (player !== null) { await player.release(); }
  }
}
