import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { EngineEvent, EngineFailure, EngineSource, EngineTrack, PlayerEngine, SubtitleStyle } from './PlayerEngine';

/** No UI, server sessions or library IDs cross this adapter. */
export class AVPlayerEngine implements PlayerEngine {
  readonly id: 'avplayer' = 'avplayer';
  onEvent: (event: EngineEvent) => void = (): void => {};
  private player: media.AVPlayer | null = null;
  private released: boolean = false;
  private lastFailure: EngineFailure | null = null;
  private completeFailure: ((failure: EngineFailure | null) => void) | null = null;
  private rejectSeek: ((failure: EngineFailure) => void) | null = null;
  private completeOpen: (() => void) | null = null;
  private rejectOpen: ((error: EngineFailure) => void) | null = null;

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
        default: event.hint = 'pause'; break;
      }
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
