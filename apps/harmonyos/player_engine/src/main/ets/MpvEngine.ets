import { BusinessError } from '@kit.BasicServicesKit';
import { createEngine, initEngine, destroyEngine, command, tracks, MpvEvent } from 'libmovieclaw_mpv.so';
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
        'vo': 'gpu', 'gpu-context': 'ohos', 'ao': 'ohaudio', 'hwdec': 'ohcodec',
        // The host sizes the surface for fit/fill/stretch, just as for AVPlayer.
        'wid': surfaceId, 'pause': 'yes', 'keep-open': 'yes', 'keepaspect': 'no',
        'sub-fonts-dir': '/system/fonts', 'tls-verify': 'yes'
      }, (event: MpvEvent): void => this.receive(event));
      if (this.released) { return; }
      await this.send(['loadfile', source.fd >= 0 ? `fd://${source.fd}` : source.url, 'replace']);
      await loaded;
      if (source.subtitleFd >= 0) { await this.send(['sub-add', `fd://${source.subtitleFd}`, 'select']); }
      else if (source.subtitleUrl.length > 0) { await this.send(['sub-add', source.subtitleUrl, 'select']); }
      await this.send(['set', 'sub-delay', `${-(source.subtitleOffsetMs ?? 0) / 1000}`]);
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
  async play(): Promise<void> { await this.send(['set', 'pause', 'no']); }
  async pause(): Promise<void> { await this.send(['set', 'pause', 'yes']); }
  async seek(positionMs: number): Promise<void> { await this.send(['seek', `${positionMs / 1000}`, 'absolute+exact']); }
  async setRate(rate: number): Promise<void> { await this.send(['set', 'speed', `${rate}`]); }
  async setGain(gain: number): Promise<void> { await this.send(['set', 'volume', `${gain * 100}`]); }
  async tracks(): Promise<EngineTrack[]> {
    const list: NativeTrack[] = JSON.parse(await tracks(this.handle)) as NativeTrack[];
    return list.map((track: NativeTrack): EngineTrack => {
      return { id: track.id, kind: track.type === 'sub' ? 'subtitle' : track.type,
        language: track.lang ?? '', title: track.title ?? '', selected: track.selected === true };
    });
  }
  async selectTrack(kind: string, id: number): Promise<void> {
    await this.send(['set', kind === 'audio' ? 'aid' : 'sid', id < 0 ? 'no' : `${id}`]);
  }
  async setSubtitleStyle(style: SubtitleStyle): Promise<void> {
    // libass's default PlayResY is 720. Font size is expressed relative to that canvas.
    await this.send(['set', 'sub-font-size', `${720 * style.fontScale / 100}`]).catch((): void => {});
    await this.send(['set', 'sub-pos', `${100 - style.bottomPercent}`]).catch((): void => {});
    await this.send(['set', 'sub-border-style', style.background ? 'background-box' : 'outline-and-shadow']).catch((): void => {});
  }
  private receive(native: MpvEvent): void {
    if (this.released) { return; }
    const event = new EngineEvent();
    if (native.type === 'diagnostic') {
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
        const kind = native.code === -17 || native.code === -18 || native.code === -16 ? 'unsupported'
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
    this.releaseTask = this.tail.then((): Promise<void> => destroyEngine(this.handle));
    return this.releaseTask;
  }
}
