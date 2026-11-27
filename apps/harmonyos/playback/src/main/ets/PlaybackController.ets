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
  /** 用户显式选过这条轨。观看状态继承来的偏好无此标志：恢复失败降级为跳过，不再整引擎回退 */
  explicit?: boolean;
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
/** 在播字幕操作的记忆三态（P1-2）：冻结就地重开绕过 open()，重开后的字幕恢复
 * 语义由它决定——untouched 按意图原样恢复；detached 重放空源卸载（restoreTracks
 * 的 ordinal=-1 会选中轨表末尾的内封轨，把用户已卸的字幕复活）；attached 按记
 * 录的源补挂。 */
enum SubtitleMemory {
  /** open 后从未在播挂载/卸载过旁挂：恢复按意图原样。 */
  Untouched,
  /** 用户显式卸载（裸播等 PGS / fd 型旁挂）：重开重放空源卸载，绝不复活内封轨。 */
  Detached,
  /** path/URL 型旁挂源在挂：重开按记录的源补挂。 */
  Attached
}
/** 空源字面量（P1-2）：detached 态冻结重开时重放卸载——三个字幕源全空 = 只卸不加。 */
const BARE_SUBTITLE_SOURCE: EngineSource = { url: '', fd: -1, length: 0, subtitleUrl: '', subtitleFd: -1 };

/** Transport-free orchestration shared by phone, Pad and future device hosts. */
export class PlaybackController {
  // On-demand HTTP segments can take 30 seconds to become available.
  // Release still cancels the pending native seek immediately.
  private static readonly seekTimeoutMs: number = 35000;
  private static readonly startupTimeoutMs: number = 25000;
  // prepared 态续播 seek 的兜底预算：健康网络下 seek 拉流一两秒内完成，挂起
  // 说明 histreamer 没接住该 seek——seek 阶段没有画面可等，不值得陪服务端
  // 中继的重连窗口耗满，比停滞看门狗更早放弃转 mpv。
  private static readonly preparedSeekTimeoutMs: number = 12000;
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
  // prepared 态续播 seek 之后首帧必须在同款预算内落地，否则视作 seek 假成功
  // （seekDone 谎报而画面从未渲染）按启动超时转 mpv。
  private startupDeadlineMs: number = PlaybackController.startupTimeoutMs;
  private startupSeekSuperseded: boolean = false;
  private deferredResumePending: boolean = false;
  private deferredSeekIssued: boolean = false;
  private firstFrameSignal: (() => void) | null = null;
  private firstFrameAbort: ((failure: EngineFailure) => void) | null = null;
  private frozenRecoveries: number = 0;
  private frozenSessionKey: string | null = null;
  // mpv 结构性不可用（x86_64 模拟器 libmpv 为 stub，init 必败；真机/ARM64 正常）。
  // 首次尝试以 unavailable 失败即记忆（进程期内不重试）：之后冻结救援/拖动一律
  // 不再浪费尝试，直接按记忆位置回退会话重开（avp 继续播，与 HLS 越界拖动同路）。
  private mpvUnavailable: boolean = false;
  // 字幕记忆三态（P1-2），见 SubtitleMemory。
  private subtitleMemory: SubtitleMemory = SubtitleMemory.Untouched;
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
    this.subtitleMemory = SubtitleMemory.Untouched;
    this.media = media; this.surface = surface; this.intent = intent; this.preference = preference;
    this.startupSeekSuperseded = false;
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
    this.deferredResumePending = false;
    this.deferredSeekIssued = false;
    this.startupDeadlineMs = PlaybackController.startupTimeoutMs;
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
      // A drag can arrive before create/acquire resolves, when seek() cannot yet
      // identify remote HLS. Once known, reopen at the latest target instead of
      // starting the old session: AVPlayer cannot apply that target in-stream.
      if (this.startupSeekSuperseded && this.remoteAvplayerSeek(engine)) {
        this.onSeekOutsideWindow(this.intent.positionMs);
        return;
      }
      engine.onEvent = (event: EngineEvent): void => {
        if (this.valid(generation, attempt)) { this.receive(event, generation); }
      };
      await this.deadline(engine.open(lease.source, this.surface), 25000);
      if (!this.valid(generation, attempt)) { return; }
      // AVPlayer 的续播 seek 不能等首帧：histreamer http 源的前读在起播后半秒内
      // 就把缓存塞满（CacheMediaBuffer full），之后做超出缓存范围的 seek，拉回
      // 的数据存不进满缓存（SaveBodyData failed），demuxer 永远要不到数据——
      // 时钟冻在 seek 点、状态机仍报 playing，只能靠停滞看门狗 30s 后转 mpv。
      // 所以远程直链的续播 seek 提前到 open() 刚返回的 prepared 态做掉（此刻
      // 缓存里只有 moov，seek 拉流有空间可进），起播直接落在续播点。fd 本地源
      // 没有该死锁，维持首帧后延迟 seek 的老路径；轨选择也统一延迟到首帧后的
      // restore（prepared 态选轨的老坑一并避开）。远程 HLS 的流内跳转在 seek 与
      // 延迟恢复两处全拒——打开本身不拒：timeline='file' 的落点由会话起播点
      // （EXT-X-START）保证，宿主负责把会话开在目标位置。
      // MPV has no such hazard and keeps seeking at open.
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
      // 远程直链（非 HLS）且需要续播跳转：prepared 态就地 seek。seek 挂起由本处
      // deadline 兜底；seekDone 假成功（首帧迟迟不来）由 playEngine 的首帧超时
      // 兜底——两者都按停滞看门狗同款预算转 mpv，失败面与旧行为等宽。
      if (deferUntilRunning && lease.source.fd < 0 && lease.source.url.length > 0
        && !(lease.source.isHls ?? true) && resumeTargetMs > media.originMs) {
        hilog.info(0x0000, 'MCSub', 'avplayer prepared 态续播 seek: position=%{public}d origin=%{public}d',
          resumeTargetMs, media.originMs);
        this.deferredSeekIssued = true;
        this.startupDeadlineMs = PlaybackController.preparedSeekTimeoutMs;
        await this.deadline(engine.seek(Math.max(0, resumeTargetMs - media.originMs)),
          PlaybackController.preparedSeekTimeoutMs);
        if (!this.valid(generation, attempt)) { return; }
      }
      // 冻结的就地重开绕过 open()：在播时的字幕操作 host 不会重走挂载流程
      // （media 是挂载前的旧快照，acquire 只会带回旧配方），这里按控制器三态
      // 记忆补做（P1-2）：attached 按源补挂；detached 重放空源卸载——restoreTracks
      // 的 ordinal=-1 会选中轨表末尾的内封轨，把用户已卸的字幕复活。失败只留痕
      // ——丢一格字幕不能废掉整次画面恢复。
      const sidecar = this.attachedSubtitle;
      if (id === 'mpv' && this.subtitleMemory !== SubtitleMemory.Untouched) {
        try {
          if (this.subtitleMemory === SubtitleMemory.Attached && sidecar !== null) {
            await engine.attachSubtitle(sidecar);
          } else {
            await engine.attachSubtitle(BARE_SUBTITLE_SOURCE);
          }
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
  // signal lies, so in-player seeks on remote HLS are refused outright — the
  // host reopens the session at the target instead (timeline='file' 的落点由
  // 会话起播点/EXT-X-START 保证), never freezing on a dead pipeline.
  // Plain remote URLs (/stream): 首帧后的续播死锁由 startAttempt 的 prepared 态
  // seek 绕开，in-session 拖动同样撞死在满缓存上（见 remoteDirectAvplayerSeek），
  // 由 seek() 直接按目标转 mpv。isHls absent = conservative HLS = refuse, so
  // old media implementations cannot regress into freezing.
  private remoteAvplayerSeek(engine: PlayerEngine): boolean {
    const lease = this.lease;
    return engine.id === 'avplayer' && lease !== null && lease.source.fd < 0
      && lease.source.url.length > 0 && (lease.source.isHls ?? true);
  }
  // 远程直链（非 HLS 的 URL 源）：起播后 histreamer 的前读把缓存塞满，任何出
  // 缓存的流内 seek 都是假 seekDone 真冻结——拉回的数据存不进满缓存
  // （SaveBodyData failed），时钟冻在 seek 点、状态机仍报 playing，只能等停滞
  // 看门狗 30s 后转 mpv（2026-11-20 Pura X 实测：拖到 7:42 冻 46s 才救回）。
  // prepared 态的续播 seek 不在此列（此刻缓存里只有 moov，见 startAttempt）。
  private remoteDirectAvplayerSeek(engine: PlayerEngine): boolean {
    const lease = this.lease;
    return engine.id === 'avplayer' && lease !== null && lease.source.fd < 0
      && lease.source.url.length > 0 && !(lease.source.isHls ?? true);
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
    // mpv 已判不可用（模拟器 stub）：avp 失败再撞 stub 只会白耗一次尝试，直接终态。
    if (id === 'avplayer' && this.preference === 'auto' && failure.canFallback() && !this.mpvUnavailable) {
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
    // mpv 结构性不可用（x86_64 模拟器 libmpv 为 stub，init 必败；真机/ARM64 不
    // 会走到）：冻结救援/拖动转换撞上它时重试无意义，也绝不升级成终态报错废掉
    // 整个会话——记住不可用，按当前记忆位置回退会话重开（宿主 renegotiate 后
    // avp 重开，与 HLS 越界拖动同一条路），avp 内核继续播。仅回退一次：之后
    // mpv 尝试全部短路，avp 自身失败直接终态，绝不无限 renegotiate。
    if (id === 'mpv' && failure.kind === 'unavailable' && !this.mpvUnavailable) {
      this.mpvUnavailable = true;
      this.switching = false;
      hilog.warn(0x0000, 'MCSub', 'mpv 不可用，回退 avp 会话重开: position=%{public}d', this.intent.positionMs);
      this.onSeekOutsideWindow(this.intent.positionMs);
      return;
    }
    this.switching = false; this.snapshot.phase = 'failed'; this.snapshot.playing = false; this.snapshot.buffering = false;
    this.snapshot.failure = failure; this.publish(); this.onFailure(failure);
  }

  /**
   * 视频画面冻结（mpv 看门狗 / AVP 停滞看门狗触发）：dispose 后一律转 mpv 就地
   * 重开恢复流连接。AVP 远程直连源不再做同引擎重开——2026-11-17 设备日志实测：
   * 直链冻结的根因是服务端中继的上游断流（上游停发约 60s），同引擎重开三次全
   * 部只播 59~87ms 就再冻（全新实例照样撞死在同一个断流窗口里，并非 histreamer
   * 就实例缓存死锁），白耗约 45 秒才轮到 mpv；mpv 缓冲有耐心，熬到上游恢复就
   * 能接着播，直转一步到位。重开位置取 intent 与看门狗实测的较大值——time 事
   * 件可能被事件洪峰（404 风暴）整段丢弃，intent 里是旧位置，直接用会把已看
   * 过的片段重放一遍，还得让服务端重新产段；看门狗上报的是冻结瞬间的引擎位置
   * （+originMs 换算到文件时间），绝不让重开位置回退。重开次数超上限说明源/
   * 服务端持续异常，转 decode 失败交给宿主收尾，绝不无限循环。
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
    hilog.error(0x0000, 'MCSub', '视频冻结，就地重开恢复: engine=mpv position=%{public}d 第 %{public}d 次',
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
    // mpv 已判结构性不可用（模拟器 stub）：不再浪费尝试，按冻结位置回退会话重
    // 开——宿主 renegotiate 后 open，引擎仍是 avp（暂停后点播放卡死的模拟器实
    // 测：停发卡住 avp 时转 mpv 只会变成「MPV 初始化失败」终态报错）。
    if (this.mpvUnavailable) {
      hilog.warn(0x0000, 'MCSub', '视频冻结，mpv 不可用，回退 avp 会话重开: position=%{public}d', positionMs);
      this.switching = false;
      this.onSeekOutsideWindow(positionMs);
      return;
    }
    try { await this.startAttempt('mpv', generation); }
    catch (error) {
      if (generation !== this.generation) { return; }
      await this.recover(error instanceof EngineFailure ? error
        : new EngineFailure('internal', 0, '无法重建播放画面'), generation, id);
    }
  }

  /**
   * 远程直链 avp 的 in-session seek（拖动/重播）：与 recoverFrozen 同路——dispose
   * 后转 mpv 就地重开。区别有二：重开位置就是拖动目标（用户可以故意回看，绝不
   * 按看门狗口径取较大值），也不占冻结恢复的三次预算（这是主动换引擎，不是源
   * 持续异常）。mpv 的 startAttempt 按 intent.positionMs 落到目标点，之后的拖动
   * 走 mpv 原生 seek，不再经过这里。
   */
  private async recoverDragToMpv(generation: number, id: EngineId): Promise<void> {
    hilog.info(0x0000, 'MCSub', 'avplayer 远程直链拖动，转 mpv 重开: position=%{public}d',
      this.intent.positionMs);
    const notice = new EngineEvent();
    notice.type = 'diagnostic';
    notice.text = '切换兼容引擎以支持拖动';
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
      }, this.startupDeadlineMs);
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
  // 首帧证明解码器在跑：fd 本地源的延迟续播 seek 与统一的轨恢复都在这里落地
  // （走与用户 seek 相同的路径）。远程直链的续播 seek 已在 startAttempt 的
  // prepared 态做完，这里只负责确认落地与轨恢复——此刻缓存已被前读塞满，
  // 没有拖动接管时绝不原地再 seek（正是要绕开的死锁）。
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
        // prepared 态已 seek 且窗口内无拖动：跳过重复 seek（缓存已满，原地重
        // seek 即死锁）。拖动过则按最新位置补一次。远程 HLS 不走流内恢复 seek：
        // timeline='file' 的落点由会话起播点（EXT-X-START）决定，histreamer 的
        // 流内 seek 是假 seekDone 真冻结的禁区，这里只确认落地与轨恢复。
        const alreadySought = this.deferredSeekIssued && !this.startupSeekSuperseded;
        if (!this.remoteAvplayerSeek(engine) && resumeMs > media.originMs && !alreadySought) {
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
    // 系统播放器不能在远程 HLS 里原地内跳（histreamer 一跳就假 seekDone 真冻结）。
    // 向前拖出起播窗口不再「拒绝换 MPV」，改交宿主按目标位置重开会话——服务端
    // 从新位置起转，播放器永远只从窗口头起播，系统播放器全程保得住。
    const liveEngine = this.engine;
    if (liveEngine !== null && fileMs >= originMs && this.remoteAvplayerSeek(liveEngine)) {
      hilog.info(0x0000, 'MCSub', 'avplayer 远程流拖动出窗，按目标重开会话: position=%{public}d origin=%{public}d',
        fileMs, originMs);
      this.onSeekOutsideWindow(fileMs);
      return;
    }
    // 远程直链的 in-session 拖动/重播：起播前读已把 histreamer 缓存塞满，流内
    // seek 拉回的数据存不进满缓存——假 seekDone 真冻结（见 remoteDirectAvplayerSeek）。
    // 不陪停滞看门狗等 30 秒，拖动直接按目标转 mpv 就地重开（2026-11-20 Pura X
    // 实测 mpv 接管 1.9s 即恢复），之后的拖动全是 mpv 原生 seek。
    if (!this.switching && this.available && liveEngine !== null && fileMs >= originMs
      && this.remoteDirectAvplayerSeek(liveEngine)) {
      // mpv 已判不可用（模拟器 stub）：与远程 HLS 拖动同路，按目标重开会话。
      if (this.mpvUnavailable) {
        this.onSeekOutsideWindow(fileMs);
        return;
      }
      await this.recoverDragToMpv(this.generation, liveEngine.id);
      return;
    }
    // Before the first frame a drag merges into the deferred resume target (the
    // restore task reads intent.positionMs when it runs).
    if (this.deferredResumePending && !this.deferredSeekIssued) { return; }
    await this.command((engine: PlayerEngine): Promise<void> => {
      return this.deadline(engine.seek(Math.max(0, fileMs - originMs)), PlaybackController.seekTimeoutMs);
    });
  }
  async setRate(rate: number): Promise<void> {
    this.intent.rate = rate; this.publish();
    await this.command((engine: PlayerEngine): Promise<void> => engine.setRate(rate));
  }
  async setGain(gain: number): Promise<void> {
    this.gain = Math.max(0, Math.min(2, gain));
    await this.command((engine: PlayerEngine): Promise<void> => engine.setGain(this.gain));
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
      // 三态记忆（P1-2）：可补挂的 path/URL 型记 attached（源随身）；fd 型与全空
      // 裸播记 detached——冻结重开重放空源卸载，绝不复活内封轨。
      const reattachable = this.reattachableSidecar(source);
      this.attachedSubtitle = reattachable;
      this.subtitleMemory = reattachable !== null ? SubtitleMemory.Attached : SubtitleMemory.Detached;
      if (reattachable !== null) {
        // 旁挂轨在 track-list 末尾，ordinal=-1 与 open 时 sidecar 的恢复语义同源
        this.intent.subtitle = { language: '', title: '', ordinal: -1 };
        this.intent.subtitlesOff = false;
      } else {
        // 显式卸载：恢复语义必须是「无字幕」。ordinal=-1 会选中轨表末尾的内封
        // 轨，subtitlesOff 才能让 restoreTracks 走 sid=no。
        this.intent.subtitle = null;
        this.intent.subtitlesOff = true;
      }
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
    // Before the first frame only record the intent: prepared 态不碰轨选择（远程
    // 直链的续播 seek 也在 prepared 态发生，轨操作必须避开同窗口），延迟恢复
    // 任务在首帧后统一应用最新偏好。
    if (this.deferredResumePending) { return; }
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
        if (preference.explicit === true) {
          throw new EngineFailure('unsupported', 0, '当前内核未完整识别原片音轨，无法可靠选择指定音轨');
        }
        hilog.warn(0x0000, 'MCSub', '%{public}s',
          `restore audio 跳过（继承偏好，内核音轨数不符）: candidates=${candidates.length} sourceCount=${preference.sourceCount}`);
        continue;
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
        if (kind === 'audio') {
          if (preference.explicit === true) {
            throw new EngineFailure('unsupported', 0, '当前内核无法选择指定音轨');
          }
          hilog.warn(0x0000, 'MCSub', '%{public}s',
            `restore audio 跳过（继承偏好，未定位到指定音轨）: candidates=${candidates.length} ordinal=${preference.ordinal}`);
        }
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
    // 冻结重启预算随会话 key 存活（P2-1）：跨档切换走 release→open（同 key），
    // release 清 key 会让三次上限在跨档场景形同虚设；只有 open 换会话（换
    // key/无 key）才重置。控制器随播放页实例创建，重进播放页天然是全新预算。
    // 字幕记忆随会话结束复位：release 后没有在播引擎，open 才是权威重置点。
    this.subtitleMemory = SubtitleMemory.Untouched; this.attachedSubtitle = null;
    try { await this.disposeEngine(); }
    catch (error) {
      const event = new EngineEvent(); event.type = 'diagnostic'; event.text = '播放器释放失败，保留媒体文件句柄'; this.onEvent(event);
    }
    this.snapshot.phase = 'idle'; this.snapshot.playing = false; this.snapshot.buffering = false; this.publish();
  }
}
