import { DefaultEngineFactory, EngineEvent, EngineFactory, EngineFailure, EngineId,
  EngineSource, EngineTrack, PlayerEngine, SubtitleStyle } from '@movieclaw/player-engine';

/** Every attempt acquires its own file descriptors. Close only after engine.release. */
export interface MediaLease {
  source: EngineSource;
  close(): Promise<void>;
}
export interface PlaybackMedia {
  acquire(engine: EngineId): Promise<MediaLease>;
  originMs: number;
  durationMs: number;
}
export class PlaybackIntent {
  positionMs: number = 0;
  paused: boolean = false;
  rate: number = 1;
  audio: TrackPreference | null = null;
  subtitle: TrackPreference | null = null;
  subtitlesOff: boolean = false;
}
export interface TrackPreference {
  language: string;
  title: string;
  ordinal: number;
  sourceCount?: number;
}
export class PlaybackSnapshot {
  phase: string = 'idle';
  engine: string = '';
  positionMs: number = 0;
  durationMs: number = 0;
  playing: boolean = false;
  firstFrame: boolean = false;
  buffering: boolean = false;
  rate: number = 1;
  failure: EngineFailure | null = null;
}

/** Transport-free orchestration shared by phone, Pad and future device hosts. */
export class PlaybackController {
  // On-demand HTTP segments can take 30 seconds to become available.
  // Release still cancels the pending native seek immediately.
  private static readonly seekTimeoutMs: number = 35000;
  onSnapshot: (snapshot: PlaybackSnapshot) => void = (): void => {};
  onEvent: (event: EngineEvent) => void = (): void => {};
  onSeekOutsideWindow: (positionMs: number) => void = (): void => {};
  onFailure: (failure: EngineFailure) => void = (): void => {};
  // Some platforms cannot transfer a native producer's Surface to another decoder.
  onSurfaceReset: (() => Promise<string>) | null = null;
  private snapshot: PlaybackSnapshot = new PlaybackSnapshot();
  private intent: PlaybackIntent = new PlaybackIntent();
  private engine: PlayerEngine | null = null;
  private lease: MediaLease | null = null;
  private media: PlaybackMedia | null = null;
  private surface: string = '';
  private generation: number = 0;
  private attempt: number = 0;
  private openingFailure: EngineFailure | null = null;
  private switching: boolean = false;
  private available: boolean = false;
  private interrupted: boolean = false;
  private gain: number = 1;
  private commandTail: Promise<void> = Promise.resolve();
  private releaseTail: Promise<void> = Promise.resolve();
  private style: SubtitleStyle = { fontScale: 5.2, bottomPercent: 8, background: true };
  private preference: string = 'auto';

  private factory: EngineFactory;
  constructor(factory: EngineFactory = new DefaultEngineFactory()) {
    this.factory = factory;
  }

  current(): PlaybackSnapshot { return this.snapshot; }
  desired(): PlaybackIntent { return this.intent; }

  async open(media: PlaybackMedia, surface: string, intent: PlaybackIntent,
    preference: string = 'auto'): Promise<void> {
    const generation = ++this.generation;
    this.attempt++;
    this.media = media; this.surface = surface; this.intent = intent; this.preference = preference;
    this.switching = true; this.available = false; this.interrupted = false;
    this.snapshot = new PlaybackSnapshot();
    this.snapshot.phase = 'opening'; this.snapshot.positionMs = intent.positionMs;
    this.snapshot.durationMs = media.durationMs;
    this.publish();
    await this.disposeEngine();
    if (generation !== this.generation || surface.length === 0) { return; }
    await this.startAttempt(preference === 'mpv' ? 'mpv' : 'avplayer', generation);
  }

  private async startAttempt(id: EngineId, generation: number): Promise<void> {
    const attempt = ++this.attempt;
    const media = this.media;
    if (media === null || generation !== this.generation) { return; }
    this.openingFailure = null;
    this.snapshot.engine = id; this.snapshot.phase = 'opening'; this.snapshot.playing = false;
    this.snapshot.firstFrame = false; this.snapshot.buffering = false; this.snapshot.failure = null; this.publish();
    let engine: PlayerEngine | null = null;
    let lease: MediaLease | null = null;
    try {
      engine = await this.factory.create(id);
      if (!this.valid(generation, attempt)) { await engine.release(); return; }
      lease = await media.acquire(id);
      if (!this.valid(generation, attempt)) { await engine.release(); await lease.close(); return; }
      this.engine = engine; this.lease = lease;
      engine.onEvent = (event: EngineEvent): void => {
        if (this.valid(generation, attempt)) { this.receive(event, generation); }
      };
      await this.deadline(engine.open(lease.source, this.surface), 25000);
      if (!this.valid(generation, attempt)) { return; }
      let restoredPosition = -1;
      while (restoredPosition !== this.intent.positionMs && this.valid(generation, attempt)) {
        restoredPosition = this.intent.positionMs;
        if (restoredPosition > media.originMs) {
          await this.deadline(engine.seek(Math.max(0, restoredPosition - media.originMs)), PlaybackController.seekTimeoutMs);
        }
      }
      if (!this.valid(generation, attempt)) { return; }
      await engine.setRate(this.intent.rate);
      if (!this.valid(generation, attempt)) { return; }
      await engine.setGain(this.gain);
      if (!this.valid(generation, attempt)) { return; }
      await engine.setSubtitleStyle(this.style);
      if (!this.valid(generation, attempt)) { return; }
      await this.restoreTracks(engine);
      if (!this.valid(generation, attempt)) { return; }
      const openingFailure = this.openingFailure;
      if (openingFailure !== null) { throw openingFailure as EngineFailure; }
      this.available = true; this.switching = false;
      this.snapshot.phase = 'ready'; this.publish();
      if (!this.intent.paused && !this.interrupted) { await engine.play(); }
      else { await engine.pause(); this.snapshot.phase = 'paused'; this.publish(); }
    } catch (error) {
      if (!this.valid(generation, attempt)) { return; }
      // Acquisition may fail before the pair becomes the active engine/lease.
      if (engine !== null && this.engine !== engine) { await engine.release(); }
      const failure = this.openingFailure ?? (error instanceof EngineFailure ? error
        : new EngineFailure('internal', 0, '播放器操作失败'));
      await this.recover(failure, generation, id);
    }
  }

  private valid(generation: number, attempt: number): boolean {
    return generation === this.generation && attempt === this.attempt;
  }
  private async recover(failure: EngineFailure, generation: number, id: EngineId): Promise<void> {
    this.available = false; this.switching = true; this.attempt++;
    try { await this.disposeEngine(); }
    catch (error) {
      if (generation !== this.generation) { return; }
      const releaseFailure = new EngineFailure('internal', 0, '播放器释放失败，请退出播放页');
      this.snapshot.phase = 'failed'; this.snapshot.playing = false; this.snapshot.buffering = false; this.snapshot.failure = releaseFailure;
      this.publish(); this.onFailure(releaseFailure); return;
    }
    if (generation !== this.generation) { return; }
    if (id === 'avplayer' && this.preference === 'auto' && failure.canFallback()) {
      const event = new EngineEvent(); event.type = 'fallback'; event.failure = failure; this.onEvent(event);
      try {
        if (this.onSurfaceReset !== null) {
          let surface = '';
          await this.deadline(this.onSurfaceReset().then((value: string): void => { surface = value; }), 5000);
          if (generation !== this.generation) { return; }
          if (surface.length === 0) { throw new EngineFailure('internal', 0, '播放画面已关闭'); }
          this.surface = surface;
        }
        await this.startAttempt('mpv', generation);
      } catch (error) {
        if (generation !== this.generation) { return; }
        await this.recover(error instanceof EngineFailure ? error
          : new EngineFailure('internal', 0, '无法重建播放画面'), generation, 'mpv');
      }
      return;
    }
    this.switching = false; this.snapshot.phase = 'failed'; this.snapshot.playing = false; this.snapshot.buffering = false;
    this.snapshot.failure = failure; this.publish(); this.onFailure(failure);
  }

  private receive(event: EngineEvent, generation: number): void {
    if (event.type === 'error' && event.failure !== null) {
      if (this.switching) {
        if (this.openingFailure === null) { this.openingFailure = event.failure; }
        return;
      }
      if (!this.switching && this.engine !== null) {
        this.recover(event.failure, generation, this.engine.id);
      }
      return;
    }
    if (event.type === 'interrupt') { this.interrupt(event.hint); return; }
    if (event.type === 'time') {
      // Initial zero ticks must not erase the resume target during prepare/seek.
      if (this.available) {
        this.intent.positionMs = (this.media?.originMs ?? 0) + event.positionMs;
        this.snapshot.positionMs = this.intent.positionMs;
      }
      this.updateDuration(event.durationMs);
    } else if (event.type === 'duration') { this.updateDuration(event.durationMs); }
    else if (event.type === 'firstFrame') { this.snapshot.firstFrame = true; }
    else if (event.type === 'buffering') { this.snapshot.buffering = event.hint === 'start'; }
    else if (event.type === 'state' && this.available) {
      this.snapshot.playing = event.state === 'playing'; this.snapshot.phase = event.state;
      if (event.state === 'ended') { this.intent.paused = true; }
    }
    this.publish(); this.onEvent(event);
  }
  private updateDuration(duration: number): void {
    if ((this.media?.durationMs ?? 0) > 0) { this.snapshot.durationMs = this.media!.durationMs; }
    else if (duration > 0) { this.snapshot.durationMs = duration + (this.media?.originMs ?? 0); }
  }
  private publish(): void {
    const next = new PlaybackSnapshot();
    next.phase = this.snapshot.phase; next.engine = this.snapshot.engine;
    next.positionMs = this.snapshot.positionMs; next.durationMs = this.snapshot.durationMs;
    next.playing = this.snapshot.playing; next.firstFrame = this.snapshot.firstFrame;
    next.buffering = this.snapshot.buffering; next.failure = this.snapshot.failure; next.rate = this.intent.rate;
    this.snapshot = next; this.onSnapshot(next);
  }
  private deadline(task: Promise<void>, milliseconds: number): Promise<void> {
    return new Promise<void>((resolve, reject): void => {
      const timer = setTimeout((): void => reject(new EngineFailure('timeout', 0, '等待播放器响应超时')), milliseconds);
      task.then((): void => { clearTimeout(timer); resolve(); })
        .catch((error: Error): void => { clearTimeout(timer); reject(error); });
    });
  }
  private command(action: (engine: PlayerEngine) => Promise<void>): Promise<void> {
    const engine = this.engine;
    const generation = this.generation;
    if (engine === null || !this.available) { return Promise.resolve(); }
    const task = this.commandTail.then(async (): Promise<void> => {
      if (generation !== this.generation || engine !== this.engine || !this.available) { return; }
      try { await action(engine); }
      catch (error) {
        if (generation !== this.generation || engine !== this.engine || this.switching) { return; }
        const failure = error instanceof EngineFailure ? error : new EngineFailure('internal', 0, '播放命令执行失败');
        await this.recover(failure, generation, engine.id);
      }
    });
    this.commandTail = task.catch((): void => {});
    return task;
  }
  async play(): Promise<void> {
    this.intent.paused = false; this.interrupted = false;
    if (this.snapshot.phase === 'ended') { await this.seek(0); }
    await this.command((engine: PlayerEngine): Promise<void> => engine.play());
  }
  async pause(): Promise<void> {
    this.intent.paused = true; this.interrupted = false;
    await this.command((engine: PlayerEngine): Promise<void> => engine.pause());
  }
  async seek(fileMs: number): Promise<void> {
    this.intent.positionMs = Math.max(0, fileMs); this.snapshot.positionMs = this.intent.positionMs; this.publish();
    if (fileMs < (this.media?.originMs ?? 0)) { this.onSeekOutsideWindow(fileMs); return; }
    await this.command((engine: PlayerEngine): Promise<void> =>
      this.deadline(engine.seek(Math.max(0, fileMs - (this.media?.originMs ?? 0))), PlaybackController.seekTimeoutMs));
  }
  async setRate(rate: number): Promise<void> {
    this.intent.rate = rate; this.publish();
    await this.command((engine: PlayerEngine): Promise<void> => engine.setRate(rate));
  }
  async setSubtitleStyle(style: SubtitleStyle): Promise<void> {
    this.style = style;
    await this.command((engine: PlayerEngine): Promise<void> => engine.setSubtitleStyle(style));
  }
  async selectTrack(kind: string, preference: TrackPreference | null): Promise<void> {
    if (kind === 'audio') { this.intent.audio = preference; }
    else { this.intent.subtitle = preference; this.intent.subtitlesOff = preference === null; }
    await this.command((engine: PlayerEngine): Promise<void> => this.restoreTracks(engine));
  }
  async tracks(): Promise<EngineTrack[]> {
    const engine = this.engine;
    if (engine === null || !this.available) { return []; }
    const tracks = await engine.tracks();
    return engine === this.engine ? tracks : [];
  }
  private async restoreTracks(engine: PlayerEngine): Promise<void> {
    if (this.intent.audio === null && this.intent.subtitle === null && !this.intent.subtitlesOff) { return; }
    const tracks = await engine.tracks();
    for (const kind of ['audio', 'subtitle']) {
      const preference = kind === 'audio' ? this.intent.audio : this.intent.subtitle;
      if (kind === 'subtitle' && this.intent.subtitlesOff) { await engine.selectTrack(kind, -1); continue; }
      if (preference === null) { continue; }
      const candidates = tracks.filter((track: EngineTrack): boolean => track.kind === kind);
      if (kind === 'audio' && preference.sourceCount !== undefined && candidates.length !== preference.sourceCount) {
        throw new EngineFailure('unsupported', 0, '当前内核未完整识别原片音轨，无法可靠选择指定音轨');
      }
      const matches = candidates.filter((track: EngineTrack): boolean =>
        preference.language.length > 0 && track.language === preference.language && track.title === preference.title);
      // Language/title can repeat (commentary, lossless and surround tracks).
      // Only a unique identity may override the user's selected source ordinal.
      let selected = matches.length === 1 ? matches[0] : undefined;
      if (selected === undefined) { selected = preference.ordinal < 0 ? candidates[candidates.length - 1] : candidates[preference.ordinal]; }
      if (selected !== undefined) { await engine.selectTrack(kind, selected.id); }
      else if (kind === 'audio') { throw new EngineFailure('unsupported', 0, '当前内核无法选择指定音轨'); }
    }
  }
  private interrupt(hint: string): void {
    if (hint === 'duck' || hint === 'unduck') {
      this.gain = hint === 'duck' ? 0.2 : 1;
      this.command((engine: PlayerEngine): Promise<void> => engine.setGain(this.gain));
    } else if (hint === 'resume') {
      if (this.interrupted && !this.intent.paused) {
        this.interrupted = false;
        this.command((engine: PlayerEngine): Promise<void> => engine.play());
      }
    } else if (hint === 'stop') { this.pause(); }
    else if (!this.intent.paused) {
      this.interrupted = true;
      this.command((engine: PlayerEngine): Promise<void> => engine.pause());
    }
  }
  private disposeEngine(): Promise<void> {
    const engine = this.engine; const lease = this.lease;
    this.engine = null; this.lease = null; this.available = false;
    if (engine !== null) { engine.onEvent = (): void => {}; }
    const cleanup = async (): Promise<void> => {
      // If release fails, retain the lease: closing a descriptor still in use is unsafe.
      if (engine !== null) { await engine.release(); }
      if (lease !== null) { await lease.close(); }
    };
    this.releaseTail = this.releaseTail.then(cleanup);
    return this.releaseTail;
  }
  async release(): Promise<void> {
    ++this.generation; ++this.attempt; this.media = null; this.switching = false;
    await this.disposeEngine();
    this.snapshot.phase = 'idle'; this.snapshot.playing = false; this.snapshot.buffering = false; this.publish();
  }
}
