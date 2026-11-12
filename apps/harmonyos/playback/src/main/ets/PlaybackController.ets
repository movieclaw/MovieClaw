import { DefaultEngineFactory, EngineEvent, EngineFactory, EngineFailure, EngineId,
  EngineSource, EngineTrack, PlayerEngine, SubtitleStyle } from '@movieclaw/player-engine';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** Every attempt acquires its own file descriptors. Close only after engine.release. */
export interface MediaLease {
  source: EngineSource;
  close(): Promise<void>;
}
export interface PlaybackMedia {
  acquire(engine: EngineId): Promise<MediaLease>;
  originMs: number;
  durationMs: number;
  /** 播放会话标识（如文件 id）：冻结重开上限按它跨 open 累计——同一会话内
   * 换引擎/换档不重置次数；缺省沿用每次 open 重置的旧口径。 */
  sessionKey?: string;
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
  private static readonly startupTimeoutMs: number = 25000;
  private static readonly releaseTimeoutMs: number = 3000;
  // mpv 看门狗触发一次画面冻结就地重开一次；超过上限说明源/服务端持续异常，
  // 转 decode 失败收尾，绝不无限循环。
  private static readonly maxFrozenRecoveries: number = 3;
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
  private engineSurface: string = '';
  // The close deadline does not mean the native producer has released its Surface.
  private releasingSurfaces: Set<string> = new Set<string>();
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
  private cancelStartup: (() => void) | null = null;
  private startupConfirmed: boolean = false;
  private startupPositionMs: number = 0;
  private startupSeekSuperseded: boolean = false;
  private deferredResumePending: boolean = false;
  private deferredSeekIssued: boolean = false;
  private firstFrameSignal: (() => void) | null = null;
  private firstFrameAbort: ((failure: EngineFailure) => void) | null = null;
  private frozenRecoveries: number = 0;
  private frozenSessionKey: string | null = null;
  // 在播挂上的旁挂源（mpv）：冻结就地重开绕过 open()，host 不会重走挂载流程
  // （media 是挂载前的旧快照），由控制器在重开后补挂。只记可复挂的 path/URL
  // 型——fd 型的文件生命周期不在控制器手里，重开后多半已失效。
  private attachedSubtitle: EngineSource | null = null;

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
    // 冻结重开上限按会话累计：同一 sessionKey（同一条媒体）内换引擎/换档不
    // 重置，真正换会话（换集/重进）才清零；缺省 key 沿用每次 open 清零的旧口径。
    const sessionKey = media.sessionKey ?? null;
    if (sessionKey === null || sessionKey !== this.frozenSessionKey) {
      this.frozenRecoveries = 0;
      this.frozenSessionKey = sessionKey;
    }
    this.attachedSubtitle = null;
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
    this.startupConfirmed = false;
    this.startupSeekSuperseded = false;
    this.deferredResumePending = false;
    this.deferredSeekIssued = false;
    this.snapshot.engine = id; this.snapshot.phase = 'opening'; this.snapshot.playing = false;
    this.snapshot.firstFrame = false; this.snapshot.buffering = false; this.snapshot.failure = null; this.publish();
    let engine: PlayerEngine | null = null;
    let lease: MediaLease | null = null;
    try {
      if (this.releasingSurfaces.has(this.surface)) { await this.resetSurface(generation); }
      if (!this.valid(generation, attempt)) { return; }
      engine = await this.factory.create(id);
      if (!this.valid(generation, attempt)) { await engine.release(); return; }
      lease = await media.acquire(id);
      if (!this.valid(generation, attempt)) { await engine.release(); await lease.close(); return; }
      this.engine = engine; this.lease = lease; this.engineSurface = this.surface;
      if (this.intent.positionMs > media.originMs && this.remoteAvplayerSeek(engine)) {
        hilog.info(0x0000, 'MCSub', 'avplayer 远程流需跳转，拒绝打开: position=%{public}d origin=%{public}d',
          this.intent.positionMs, media.originMs);
        throw new EngineFailure('unsupported', 0, '系统播放器不支持流媒体内跳转');
      }
      engine.onEvent = (event: EngineEvent): void => {
        if (this.valid(generation, attempt)) { this.receive(event, generation); }
      };
      await this.deadline(engine.open(lease.source, this.surface), 25000);
      if (!this.valid(generation, attempt)) { return; }
      // AVPlayer's prepared-state resume-seek strands the decoder in FLUSHED: the
      // pipeline freezes while the state machine still reports playing — paused and
      // interrupted opens included. Playback always starts first (a paused open
      // simply stays prepared) and seek/track selection defer until the first frame
      // proves the decoder is running. MPV has no such hazard and keeps seeking at open.
      const resumeTargetMs = this.intent.positionMs;
      const deferUntilRunning = id === 'avplayer';
      if (!deferUntilRunning) {
        let restoredPosition = -1;
        while (restoredPosition !== this.intent.positionMs && this.valid(generation, attempt)) {
          restoredPosition = this.intent.positionMs;
          if (restoredPosition > media.originMs) {
            await this.deadline(engine.seek(Math.max(0, restoredPosition - media.originMs)), PlaybackController.seekTimeoutMs);
          }
        }
        if (!this.valid(generation, attempt)) { return; }
      }
      // 冻结的就地重开绕过 open()：在播时挂上的旁挂字幕 host 不会重走挂载流程
      // （media 是挂载前的旧快照，acquire 只会带回旧配方），这里按控制器记录补挂。
      // 失败只留痕——丢一格字幕不能废掉整次画面恢复。
      const sidecar = this.attachedSubtitle;
      if (id === 'mpv' && sidecar !== null) {
        try {
          await engine.attachSubtitle(sidecar);
        } catch (error) {
          hilog.warn(0x0000, 'MCSub', '冻结重开补挂旁挂字幕失败: %{public}s', `${error}`);
          const notice = new EngineEvent();
          notice.type = 'diagnostic';
          notice.text = '旁挂字幕恢复失败，继续播放';
          this.onEvent(notice);
        }
        if (!this.valid(generation, attempt)) { return; }
      }
      await engine.setRate(this.intent.rate);
      if (!this.valid(generation, attempt)) { return; }
      await engine.setGain(this.gain);
      if (!this.valid(generation, attempt)) { return; }
      await engine.setSubtitleStyle(this.style);
      if (!this.valid(generation, attempt)) { return; }
      if (!deferUntilRunning) {
        await this.restoreTracks(engine);
        if (!this.valid(generation, attempt)) { return; }
      }
      const openingFailure = this.openingFailure;
      if (openingFailure !== null) { throw openingFailure as EngineFailure; }
      this.available = true; this.switching = false;
      this.snapshot.phase = 'ready'; this.publish();
      const pausedStart = this.intent.paused || this.interrupted;
      if (!pausedStart) { await this.playEngine(engine); }
      else { await engine.pause(); }
      // A play()/pause() can acknowledge long after release()/recover() already
      // invalidated this attempt. Revalidate before publishing or arming the
      // deferred waiter: the stale continuation must not paint 'paused' over a
      // successor session, nor install a first-frame waiter that hijacks its own.
      if (!this.valid(generation, attempt) || engine !== this.engine) { return; }
      if (pausedStart) { this.snapshot.phase = 'paused'; this.publish(); }
      if (deferUntilRunning) {
        this.deferredResumePending = true;
        this.deferStartupResume(engine, media, resumeTargetMs, generation, attempt);
      }
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
  // histreamer acknowledges seeks inside remote HLS streams with seekDone and
  // a jumped currentTime while the decoder never renders again: every observable
  // signal lies, so AVPlayer refuses required seeks on remote HLS sources outright
  // and recover() hands the session to MPV instead of freezing on a dead pipeline.
  // Plain remote URLs (/stream, /disc directory listings) range-request fine and
  // stay seekable; EngineSource.isHls distinguishes the two (absent = conservative
  // HLS = refuse, so old media implementations cannot regress into freezing).
  private remoteAvplayerSeek(engine: PlayerEngine): boolean {
    const lease = this.lease;
    return engine.id === 'avplayer' && lease !== null && lease.source.fd < 0
      && lease.source.url.length > 0 && (lease.source.isHls ?? true);
  }
  private async recover(failure: EngineFailure, generation: number, id: EngineId): Promise<void> {
    hilog.error(0x0000, 'MCSub', 'engine 失败: id=%{public}s kind=%{public}s code=%{public}d msg=%{public}s',
      id, failure.kind, failure.code, failure.message);
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
          await this.resetSurface(generation);
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

  /**
   * 视频画面冻结（mpv 看门狗触发）：dispose 后就地重开 mpv 恢复流连续。重开
   * 位置取 intent 与看门狗实测的较大值——time 事件可能被事件洪峰（404 风暴）
   * 整段丢弃，intent 里是旧位置，直接用会把已看过的片段重放一遍，还得让服务
   * 端重新产段；看门狗上报的是冻结瞬间的引擎位置（+originMs 换算到文件时间），
   * 绝不让重开位置回退。重开次数超上限说明源/服务端持续异常，转 decode 失败
   * 交给宿主收尾，绝不无限循环。
   */
  private async recoverFrozen(generation: number, id: EngineId, watchdogPositionMs: number): Promise<void> {
    const originMs = this.media?.originMs ?? 0;
    const positionMs = Math.max(this.intent.positionMs, originMs + watchdogPositionMs);
    if (positionMs !== this.intent.positionMs) {
      hilog.info(0x0000, 'MCSub', '冻结位置以看门狗实测为准: intent=%{public}d → %{public}d',
        this.intent.positionMs, positionMs);
      this.intent.positionMs = positionMs;
      this.snapshot.positionMs = positionMs;
    }
    this.frozenRecoveries++;
    if (this.frozenRecoveries > PlaybackController.maxFrozenRecoveries) {
      hilog.error(0x0000, 'MCSub', '视频冻结自动恢复已达上限 %{public}d 次，转失败: position=%{public}d',
        PlaybackController.maxFrozenRecoveries, positionMs);
      await this.recover(new EngineFailure('decode', 0, '视频画面反复卡死，已停止自动恢复'), generation, id);
      return;
    }
    hilog.error(0x0000, 'MCSub', '视频冻结，就地重开恢复: position=%{public}d 第 %{public}d 次',
      positionMs, this.frozenRecoveries);
    const notice = new EngineEvent();
    notice.type = 'diagnostic';
    notice.text = `视频流卡死，自动恢复中（${this.frozenRecoveries}/${PlaybackController.maxFrozenRecoveries}）`;
    this.onEvent(notice);
    this.available = false; this.switching = true; this.attempt++;
    try { await this.disposeEngine(); }
    catch (error) {
      if (generation !== this.generation) { return; }
      const failure = new EngineFailure('internal', 0, '播放器释放失败，请退出播放页');
      this.snapshot.phase = 'failed'; this.snapshot.playing = false; this.snapshot.buffering = false; this.snapshot.failure = failure;
      this.publish(); this.onFailure(failure); return;
    }
    if (generation !== this.generation) { return; }
    try { await this.startAttempt('mpv', generation); }
    catch (error) {
      if (generation !== this.generation) { return; }
      await this.recover(error instanceof EngineFailure ? error
        : new EngineFailure('internal', 0, '无法重建播放画面'), generation, id);
    }
  }

  private async resetSurface(generation: number): Promise<void> {
    if (this.onSurfaceReset === null) { throw new EngineFailure('internal', 0, '播放画面仍在释放，请退出后重试'); }
    let surface = '';
    await this.deadline(this.onSurfaceReset().then((value: string): void => { surface = value; }), 5000);
    if (generation !== this.generation) { return; }
    if (surface.length === 0 || this.releasingSurfaces.has(surface)) {
      throw new EngineFailure('internal', 0, '无法重建播放画面');
    }
    this.surface = surface;
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
    if (event.type === 'frozen') {
      // mpv 看门狗：画面停帧而时钟在走（服务端 404 跳段打死了视频 demux）。
      // 切换中/不可用时丢弃（重开由对应路径自己负责），正常在播才就地重开。
      // 事件带冻结瞬间的实测位置（time 事件可能已被事件洪峰丢弃）。
      if (!this.switching && this.available && this.engine !== null) {
        this.recoverFrozen(generation, this.engine.id, event.positionMs);
      }
      return;
    }
    if (event.type === 'time') {
      // Initial zero ticks must not erase the resume target during prepare/seek.
      // The same holds for play-first ticks while a deferred resume is pending:
      // they would also poison the fallback target handed to MPV.
      if (this.available && !this.deferredResumePending) {
        this.intent.positionMs = (this.media?.originMs ?? 0) + event.positionMs;
        this.snapshot.positionMs = this.intent.positionMs;
      }
      this.updateDuration(event.durationMs);
    } else if (event.type === 'duration') { this.updateDuration(event.durationMs); }
    else if (event.type === 'firstFrame') {
      this.snapshot.firstFrame = true; this.confirmStartup();
      const signal = this.firstFrameSignal;
      this.firstFrameSignal = null;
      this.firstFrameAbort = null;
      if (signal !== null) { signal(); }
    }
    else if (event.type === 'buffering') { this.snapshot.buffering = event.hint === 'start'; }
    else if (event.type === 'state' && this.available) {
      this.snapshot.playing = event.state === 'playing'; this.snapshot.phase = event.state;
      if (event.state === 'ended') { this.intent.paused = true; }
    }
    // MPV has no displayed-frame callback. Only an advancing clock confirms startup.
    if (event.type === 'time' && this.engine?.id === 'mpv' && this.cancelStartup !== null &&
      this.snapshot.positionMs > this.startupPositionMs) { this.confirmStartup(); }
    this.publish(); this.onEvent(event);
  }
  private confirmStartup(): void {
    if (this.startupConfirmed) { return; }
    this.startupConfirmed = true; this.cancelStartup?.();
  }
  private async playEngine(engine: PlayerEngine): Promise<void> {
    if (this.intent.paused || this.interrupted || engine !== this.engine) { return; }
    this.cancelStartup?.();
    const generation = this.generation; const attempt = this.attempt;
    const confirmed = this.startupConfirmed;
    this.startupPositionMs = this.snapshot.positionMs;
    let cancel: () => void = (): void => {};
    const cancelled = new Promise<void>((resolve): void => {
      const timer = setTimeout((): void => {
        cancel();
        if (this.valid(generation, attempt) && !this.intent.paused && !this.interrupted) {
          this.recover(new EngineFailure('timeout', 0, '播放启动超时，请重试'), generation, engine.id);
        }
      }, PlaybackController.startupTimeoutMs);
      cancel = (): void => {
        clearTimeout(timer);
        if (this.cancelStartup === cancel) { this.cancelStartup = null; }
        resolve();
      };
      this.cancelStartup = cancel;
    });
    // Release/pause can cancel even a play() call which never acknowledges.
    try { await Promise.race([engine.play(), cancelled]); }
    finally { if (confirmed) { cancel(); } }
  }
  // Cancellable: disposeEngine aborts a pending wait, so a release/recover during
  // the deferred window can never strand the waiter (or surface its rejection).
  private waitFirstFrame(): Promise<void> {
    if (this.snapshot.firstFrame) { return Promise.resolve(); }
    return new Promise<void>((resolve, reject): void => {
      this.firstFrameSignal = resolve;
      this.firstFrameAbort = (failure: EngineFailure): void => {
        this.firstFrameSignal = null;
        this.firstFrameAbort = null;
        reject(failure);
      };
    });
  }
  // The first frame proves the decoder is RUNNING: the deferred seek then takes the
  // same path as a user seek, and selectTrack stops touching the prepared-state
  // sidecar subtitle source (whose sub-seek histreamer rejects at prepared).
  private deferStartupResume(engine: PlayerEngine, media: PlaybackMedia, targetMs: number,
    generation: number, attempt: number): void {
    this.waitFirstFrame().then((): void => {
      if (!this.valid(generation, attempt)) { return; }
      // The restore rides the command queue: a user seek/track change issued after
      // the frame lands queues behind it instead of racing the deferred seek, and
      // AVPlayer's single rejectSeek slot stays serialized.
      const task = this.commandTail.then(async (): Promise<void> => {
        if (!this.valid(generation, attempt) || engine !== this.engine) { return; }
        // Read the target inside the task: a drag during the deferred window (seek()
        // merges it into intent.positionMs) must land at the latest position, not
        // the one captured at open.
        const resumeMs = this.startupSeekSuperseded ? this.intent.positionMs : targetMs;
        hilog.info(0x0000, 'MCSub', 'avplayer 延迟恢复: seek=%{public}d 取代=%{public}s',
          resumeMs, `${this.startupSeekSuperseded}`);
        if (resumeMs > media.originMs) {
          if (this.remoteAvplayerSeek(engine)) {
            hilog.info(0x0000, 'MCSub', 'avplayer 远程流延迟恢复需跳转，拒绝: position=%{public}d origin=%{public}d',
              resumeMs, media.originMs);
            throw new EngineFailure('unsupported', 0, '系统播放器不支持流媒体内跳转');
          }
          this.deferredSeekIssued = true;
          await this.deadline(engine.seek(Math.max(0, resumeMs - media.originMs)), PlaybackController.seekTimeoutMs);
        }
        if (!this.valid(generation, attempt)) { return; }
        // The landing is confirmed (or no seek was needed): progress reporting
        // resumes immediately. Track selection can legitimately take tens of
        // seconds (track description extraction); the clock must keep moving
        // meanwhile, and a track-timeout reopen must not rewind to a stale target.
        this.deferredResumePending = false;
        await this.deadline(this.restoreTracks(engine), PlaybackController.seekTimeoutMs);
      });
      this.commandTail = task.catch((): void => {});
      task.catch((error: Error): Promise<void> => {
        if (!this.valid(generation, attempt)) { return Promise.resolve(); }
        const failure = error instanceof EngineFailure ? error : new EngineFailure('internal', 0, '播放器操作失败');
        return this.recover(failure, generation, engine.id);
      }).catch((): void => {});
    }).catch((): void => {
      // disposeEngine aborted the first-frame wait (release/recover): quiet exit.
    });
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
    await this.command((engine: PlayerEngine): Promise<void> => this.playEngine(engine));
  }
  async pause(): Promise<void> {
    this.intent.paused = true; this.interrupted = false;
    this.cancelStartup?.();
    await this.command((engine: PlayerEngine): Promise<void> => engine.pause());
  }
  async seek(fileMs: number): Promise<void> {
    this.startupSeekSuperseded = true;
    this.intent.positionMs = Math.max(0, fileMs); this.snapshot.positionMs = this.intent.positionMs; this.publish();
    const originMs = this.media?.originMs ?? 0;
    if (fileMs < originMs) { this.onSeekOutsideWindow(fileMs); return; }
    // Before the first frame a drag merges into the deferred resume target (the
    // restore task reads intent.positionMs when it runs). Remote HLS is the
    // exception: the drag must refuse straight away and hand the session to MPV
    // instead of waiting for a frame that may never come.
    const engine = this.engine;
    if (this.deferredResumePending && !this.deferredSeekIssued
      && !(engine !== null && fileMs > originMs && this.remoteAvplayerSeek(engine))) { return; }
    await this.command((engine: PlayerEngine): Promise<void> => {
      if (fileMs > originMs && this.remoteAvplayerSeek(engine)) {
        hilog.info(0x0000, 'MCSub', 'avplayer 远程流拖动跳转，拒绝: position=%{public}d origin=%{public}d',
          fileMs, originMs);
        throw new EngineFailure('unsupported', 0, '系统播放器不支持流媒体内跳转');
      }
      return this.deadline(engine.seek(Math.max(0, fileMs - originMs)), PlaybackController.seekTimeoutMs);
    });
  }
  async setRate(rate: number): Promise<void> {
    this.intent.rate = rate; this.publish();
    await this.command((engine: PlayerEngine): Promise<void> => engine.setRate(rate));
  }
  async setSubtitleStyle(style: SubtitleStyle): Promise<void> {
    this.style = style;
    await this.command((engine: PlayerEngine): Promise<void> => engine.setSubtitleStyle(style));
  }
  /**
   * mpv 在播时就地换旁挂字幕：不 dispose、不重开流，命令进 commandTail 与 seek
   * 等排队。挂载失败原样抛回调用方——画面还在播，绝不为一条字幕 recover 掉整个
   * 引擎（远程重开的 seek-after-open 正是把 mpv demuxer 打进 EOF 死区的诱因）。
   */
  async attachSubtitle(source: EngineSource): Promise<void> {
    const engine = this.engine;
    const generation = this.generation;
    if (engine === null || engine.id !== 'mpv' || !this.available) {
      throw new EngineFailure('internal', 0, '播放器未就绪，无法挂载字幕');
    }
    const task = this.commandTail.then(async (): Promise<void> => {
      if (generation !== this.generation || engine !== this.engine || !this.available) { return; }
      await engine.attachSubtitle(source);
      // 记住可补挂的旁挂源（path/URL 型；全空裸播与 fd 型不记）：冻结就地重开
      // 绕过 open()，host 不会重走挂载流程，由 startAttempt 重开后补挂。
      this.attachedSubtitle = this.reattachableSidecar(source);
      // 旁挂轨在 track-list 末尾，ordinal=-1 与 open 时 sidecar 的恢复语义同源
      this.intent.subtitle = { language: '', title: '', ordinal: -1 };
      this.intent.subtitlesOff = false;
    });
    this.commandTail = task.catch((): void => {});
    return task;
  }
  private reattachableSidecar(source: EngineSource): EngineSource | null {
    if ((source.subtitlePath ?? '').length > 0 || source.subtitleUrl.length > 0) { return source; }
    return null;
  }
  async selectTrack(kind: string, preference: TrackPreference | null): Promise<void> {
    if (kind === 'audio') { this.intent.audio = preference; }
    else { this.intent.subtitle = preference; this.intent.subtitlesOff = preference === null; }
    // Before the first frame only record the intent: selectTrack at prepared state
    // touches the sidecar subtitle source whose sub-seek histreamer rejects, and
    // the deferred restore applies the latest preference once the decoder runs.
    if (this.deferredResumePending && !this.deferredSeekIssued) { return; }
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
      if (selected !== undefined) {
        if (kind === 'subtitle') {
          hilog.info(0x0000, 'MCSub', '%{public}s',
            `restore sub: candidates=${candidates.length} ordinal=${preference.ordinal} sid=${selected.id}`);
        }
        await engine.selectTrack(kind, selected.id);
      } else {
        if (kind === 'subtitle') {
          hilog.warn(0x0000, 'MCSub', '%{public}s',
            `restore sub 跳过: candidates=${candidates.length} ordinal=${preference.ordinal} 越界`);
        }
        if (kind === 'audio') { throw new EngineFailure('unsupported', 0, '当前内核无法选择指定音轨'); }
      }
    }
  }
  private interrupt(hint: string): void {
    if (hint === 'duck' || hint === 'unduck') {
      this.gain = hint === 'duck' ? 0.2 : 1;
      this.command((engine: PlayerEngine): Promise<void> => engine.setGain(this.gain));
    } else if (hint === 'resume') {
      if (this.interrupted && !this.intent.paused) {
        this.interrupted = false;
        this.command((engine: PlayerEngine): Promise<void> => this.playEngine(engine));
      }
    } else if (hint === 'stop' || hint === 'pause') {
      // Engine swaps rebuild the audio session and generate self-inflicted focus
      // churn, but only NONE/unknown hints are engine-filtered: a PAUSE/STOP that
      // reaches the controller during a switch is a real interruption (a call
      // landing mid-recover). Latch it — the open completes paused instead of
      // autoplaying over the caller, and the system's RESUME restores playback.
      if (this.switching) {
        if (!this.intent.paused && !this.interrupted) {
          this.interrupted = true;
          hilog.info(0x0000, 'MCSub', 'interrupt 切换中锁存（RESUME 恢复）: hint=%{public}s', hint);
        }
        return;
      }
      if (hint === 'stop') { this.pause(); return; }
      if (!this.intent.paused) {
        this.interrupted = true;
        this.cancelStartup?.();
        this.command((engine: PlayerEngine): Promise<void> => engine.pause());
      }
    }
  }
  private disposeEngine(): Promise<void> {
    const engine = this.engine; const lease = this.lease;
    const surface = this.engineSurface; this.engineSurface = '';
    this.engine = null; this.lease = null; this.available = false;
    this.cancelStartup?.();
    // Abort a deferred-resume waiter before resetting the queue: release, recover
    // and reopen all arrive here, and none may strand the first-frame wait.
    const abortFirstFrame = this.firstFrameAbort;
    this.firstFrameSignal = null;
    this.firstFrameAbort = null;
    if (abortFirstFrame !== null) {
      abortFirstFrame(new EngineFailure('internal', 0, '播放已取消'));
    }
    this.commandTail = Promise.resolve();
    if (engine !== null) {
      engine.onEvent = (): void => {};
      this.releasingSurfaces.add(surface);
    }
    const cleanup = async (): Promise<void> => {
      // If release fails, retain the lease: closing a descriptor still in use is unsafe.
      if (engine !== null) {
        await engine.release();
        this.releasingSurfaces.delete(surface);
      }
      if (lease !== null) { await lease.close(); }
    };
    this.releaseTail = this.releaseTail.catch((): void => {}).then((): Promise<void> =>
      new Promise<void>((resolve, reject): void => {
        const timer = setTimeout((): void => {
          const event = new EngineEvent(); event.type = 'diagnostic'; event.text = '播放器后台释放中'; this.onEvent(event);
          resolve();
        }, PlaybackController.releaseTimeoutMs);
        // Keep the lease alive until native teardown really completes. The UI/session
        // may close after the deadline without closing descriptors still in use.
        cleanup().then((): void => { clearTimeout(timer); resolve(); })
          .catch((error: Error): void => { clearTimeout(timer); reject(error); });
      }));
    return this.releaseTail;
  }
  async release(): Promise<void> {
    ++this.generation; ++this.attempt; this.media = null; this.switching = false;
    // 会话随 release 结束：同一 key 的下一次 open 是新会话，计数与旁挂记忆清零。
    this.frozenSessionKey = null; this.attachedSubtitle = null;
    try { await this.disposeEngine(); }
    catch (error) {
      const event = new EngineEvent(); event.type = 'diagnostic'; event.text = '播放器释放失败，保留媒体文件句柄'; this.onEvent(event);
    }
    this.snapshot.phase = 'idle'; this.snapshot.playing = false; this.snapshot.buffering = false; this.publish();
  }
}
