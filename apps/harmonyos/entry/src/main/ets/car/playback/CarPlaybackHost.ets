/**
 * 车机设备播放宿主（@ObservedV2 viewmodel）：统一内核（playback HAR + player_engine HAR）
 * 与车机播放页之间的粘合层。组装方式复刻手机 / TV 宿主：
 * PlaybackController（编排 + 25s 起播看门狗 + auto 降级）+ PlaybackSessionCoordinator
 * + TvCarPlaybackSession（TV/车机口径心跳上报）+ PhoneMedia（fd 租约）
 * + MovieClawPlaybackGateway（DeviceCapability 按引擎能力协商）。
 *
 * 暴露与旧 AvPlayerEngine 等价的 @Trace 状态与命令方法（页面只渲染状态、调命令，
 * 不感知内核）；静态 CarPlayback.begin/adopt/end 复刻旧 Playback 的跨页面协调语义
 * （按下播放先协商、播放页出现时接管、退出整体收尾；收起页面播放存活，mini 条承接）。
 *
 * 车机独有（FR-010）：videoSurfaceVisible 行车锁开关——行车模式只把视频面藏起来，
 * 音频链路不重建、进度不丢；恢复可见即回视频。
 *
 * 与旧引擎的差异（统一内核语义）：
 * - 状态归一：phase/positionMs/durationMs/轨道/剧集等仍按旧引擎口径暴露，
 *   但来源换成 PlaybackController 快照（positionMs 按 500ms 桶节流，同手机）；
 * - 失败降档沿用统一内核口径：失败档报回服务端重开，最多 4 次；
 * - 本机副本优先（FR-009）：有下完的离线副本就不建服务端会话，直接放本机
 *   （进度记 OfflineViewingRecorder 先落盘再补传）；本机放不了回退服务器流式；
 * - surface 由宿主持有：surfaceGeneration 重建机制——auto 模式 AVPlayer 降级 MPV
 *   换解码器时，页面按代数重建 XComponent 换新 surfaceId（Surface 无法跨解码器迁移）；
 * - AVSession/后台长时任务不在引擎内自建，由共享 PlaybackGuard 承接（T015）。
 */
import { preferences } from '@kit.ArkData';
import { Context, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PlaybackController, PlaybackIntent, PlaybackSnapshot, PlaybackSessionCoordinator,
  PlaybackOwnership, PlaybackGuard, SkipSegments, TrackPreference } from '@movieclaw/playback';
import { EngineEvent, EngineFailure } from '@movieclaw/player-engine';
import { AppModel } from '../../common/AppModel';
import { MovieClawApi } from '../../api/Endpoints';
import { ApiError } from '../../api/ApiClient';
import { PlayerPrefs } from '../../player/PlayerPrefs';
import {
  AudioPlanView,
  AudioTrackView,
  ClientCapabilityIn,
  EpisodeView,
  PlaybackChapterMarkView,
  PlaybackDecisionView,
  PlaybackPolicyView,
  PlaybackSegmentView,
  PlaybackSessionRequest,
  PlaybackSessionView,
  PlaybackStateView,
  SeasonEpisodesView,
  SubtitlePlanView,
  VideoPlanView
} from '../../api/Models';
import { PhoneMedia, playbackUrl } from '../../playback/PhoneMedia';
import { MovieClawPlaybackGateway } from '../../playback/MovieClawPlaybackGateway';
import { TvCarPlaybackSession } from '../../playback/TvCarPlaybackSession';
import { DeviceCapability, DeviceProfile } from '../../playback/DeviceCapability';
import { OfflineDisk } from '../../offline/OfflineDisk';
import { OfflineStore } from '../../offline/OfflineStore';
import { OfflineViewingRecorder } from '../../offline/OfflineViewings';
import { OfflinePlaybackSpec, OfflineProgress, OfflineUnit } from '../../offline/OfflineModels';
import { PlayRequest } from '../../shell/ShellUiState';

export { PlayRequest };

/** 播放阶段（页面按它切换骨架 / 转圈 / 画面 / 错误层 / 同意层） */
export class PlayPhase {
  static readonly idle: string = 'idle';
  static readonly negotiating: string = 'negotiating';
  static readonly playing: string = 'playing';
  static readonly paused: string = 'paused';
  static readonly ended: string = 'ended';
  static readonly consent: string = 'consent';
  static readonly error: string = 'error';
}

/** `PlaybackSessionRequest` 的 capability 必填，其余可选（同旧引擎的请求体口径） */
class CarSessionRequest implements PlaybackSessionRequest {
  file_id?: number | null;
  media_item_id?: number | null;
  season_number?: number | null;
  episode_number?: number | null;
  capability: ClientCapabilityIn = DeviceCapability.capability(DeviceCapability.tv(''), 'avplayer');
  failed_tiers?: number[] | null;
  audio_track?: string | null;
  subtitle_track?: string | null;
  max_height?: number | null;
  start_ms?: number | null;
  client?: string | null;
}

/**
 * TV 播放宿主：一个条目（一集）一个实例，换集在实例内完成。
 * 生命周期经静态 CarPlayback 协调（begin 预建 → 播放页 adopt 接管 → end 收尾）。
 */
@ObservedV2
export class CarPlaybackHost {
  /** 宿主 UIAbilityContext（设备标识 / 缓存目录用；CarUiState.init 注入） */
  static appContext: Context | null = null;
  /** 车机偏好存储（'movieclaw_car'，与 CarUiState 同库；只读安装标识） */
  private static deviceStore: preferences.Preferences | null = null;

  // MARK: 界面状态（@Trace，与旧引擎等价）

  @Trace phase: string = PlayPhase.idle;
  @Trace errorMessage: string = '';
  @Trace errorSuggestion: string = '';
  /** 错误归因：network / decode / session / admin（错误视图按它给行动建议） */
  @Trace errorKind: string = '';
  @Trace positionMs: number = 0;
  @Trace durationMs: number = 0;
  @Trace bufferedEndMs: number = 0;
  @Trace buffering: boolean = false;
  @Trace subtitleCue: string = '';
  @Trace videoAspect: number = 0;
  @Trace playbackSpeed: number = 1;
  @Trace session: PlaybackSessionView | null = null;
  @Trace episodes: EpisodeView[] = [];
  @Trace selectedSubtitleIndex: number = -1;
  @Trace selectedAudioRef: string = '';
  @Trace maxHeight: number = 0;
  @Trace consentSaving: boolean = false;
  @Trace currentSeason: number = 0;
  @Trace currentEpisode: number = 0;
  /** 当前引擎名（avplayer / mpv；空 = 未启动）——引擎选择菜单回显用 */
  @Trace engineName: string = '';
  /** 视频输出表面是否可见（行车锁视频 = false；音频链路不重建，恢复可见即回视频，FR-010） */
  @Trace videoSurfaceVisible: boolean = true;

  // MARK: surface（宿主持有；页面按 surfaceGeneration 重建 XComponent）

  surfaceController: XComponentController = new XComponentController();
  @Trace surfaceGeneration: number = 0;
  surfaceWaiter: ((surface: string) => void) | null = null;
  surfaceId: string = '';

  // MARK: 请求输入与内核组装（非观察状态）

  readonly request: PlayRequest;
  private controller: PlaybackController = new PlaybackController();
  private sessionCoordinator: PlaybackSessionCoordinator = new PlaybackSessionCoordinator();
  private sessionEpoch: number = 0;
  private deviceId: string = '';
  /** prepared 之后再跳的落点；-1 = 不跳 */
  private pendingSeekMs: number = -1;
  /** 换流时的续接位置（重协商时消费一次）；null = 按服务端 start_ms */
  private currentStartMs: number | null = null;
  /** 用户这一集碰过字幕选择没有（碰过才带 subtitle_track 重新协商 / 上报） */
  private subtitleTouched: boolean = false;
  private failedTiers: number[] = [];
  private retryCount: number = 0;
  private currentFileId: number | null = null;
  /** request.startMs 的「从头/指定位置」只对第一集生效 */
  private startOverrideConsumed: boolean = false;
  private prepared: boolean = false;
  private released: boolean = false;
  private reopening: boolean = false;
  /** positionMs 的 500ms 节流桶（播放全程高频快照，直写会拖整层界面重算，同手机宿主） */
  private timeBucket: number = -1;

  // MARK: 系统合规壳（AVSession + 后台长时任务，FR-011）

  private guard: PlaybackGuard | null = null;
  /** 上一帧是否在播（起播/暂停沿触发 guard.start/pause，同手机宿主） */
  private playing: boolean = false;

  // MARK: 本机副本（离线下载优先播放，FR-009；同手机宿主 tryStartLocal 路径）

  /** 正在放的本机单元（有它就不建服务端会话，进度记 OfflineViewingRecorder） */
  private localUnit: OfflineUnit | null = null;
  private localSpec: OfflinePlaybackSpec | null = null;
  private localMediaPath: string = '';
  private viewingRecorder: OfflineViewingRecorder | null = null;
  private awaitedOfflineStore: boolean = false;
  /** 本机副本起播失败过一次：这一集不再试本机，直接走服务器 */
  private localFailedOnce: boolean = false;
  /** 本机 → 服务器回退进行中（防重入） */
  private localFallingBack: boolean = false;

  constructor(request: PlayRequest) {
    this.request = request;
    this.currentSeason = request.seasonNumber ?? 0;
    this.currentEpisode = request.episodeNumber ?? 0;
    this.currentFileId = request.fileId ?? null;
    this.bindController();
  }

  // MARK: 生命周期

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  /**
   * 预协商（playback-first）：按下播放就建会话，不等播放器视图。
   * 可重入（begin + 页面兜底各调一次），只有第一次生效。
   */
  async prepare(): Promise<void> {
    if (this.released || this.prepared) {
      return;
    }
    this.prepared = true;
    PlaybackOwnership.claim(this, (): void => {
      this.pause();
    });
    await this.ensureDeviceId();
    await this.loadQualityMemory();
    if (this.released) {
      return;
    }
    await this.negotiate();
  }

  /** 整体退出：补 stop、收会话、放播放器、还播控所有权。幂等。 */
  release(): void {
    if (this.released) {
      return;
    }
    this.released = true;
    ++this.sessionEpoch;
    const waiter: ((surface: string) => void) | null = this.surfaceWaiter;
    this.surfaceWaiter = null;
    if (waiter !== null) {
      waiter('');
    }
    PlaybackOwnership.release(this);
    this.stopSession();
    const guard: PlaybackGuard | null = this.guard;
    this.guard = null;
    if (guard !== null) {
      guard.stop().catch((): void => {
      });
    }
    this.releasePlayer().catch((): void => {
    });
    this.phase = PlayPhase.idle;
    this.buffering = false;
    this.subtitleCue = '';
  }

  /**
   * 懒建系统合规壳：AVSession（锁屏/播控中心按钮接回宿主）+ 后台长时任务（暂停即收）。
   * 上一集/下一集指令必须在 start() 之前注册（会话监听只在建会话时挂）。
   */
  private ensureGuard(): PlaybackGuard | null {
    if (this.guard !== null) {
      return this.guard;
    }
    const context: Context | null = CarPlaybackHost.appContext;
    if (context === null) {
      return null;
    }
    const guard: PlaybackGuard = new PlaybackGuard(context as common.UIAbilityContext,
      (): void => {
        this.resume();
      },
      (): void => {
        this.pause();
      },
      (positionMs: number): void => {
        this.seekTo(positionMs);
      });
    guard.setEpisodeCommands((): void => {
      this.playPrevious();
    }, (): void => {
      this.playNext();
    });
    this.guard = guard;
    return guard;
  }

  // MARK: surface（页面 XComponent 接线：onLoad → surfaceReady、onDestroy → surfaceDestroyed）

  surfaceReady(generation: number): void {
    if (generation !== this.surfaceGeneration || this.released) {
      return;
    }
    const surface: string = this.surfaceController.getXComponentSurfaceId();
    if (surface === this.surfaceId && this.controller.current().phase !== 'idle') {
      return;
    }
    this.surfaceId = surface;
    if (this.surfaceWaiter !== null) {
      const ready: (surface: string) => void = this.surfaceWaiter;
      this.surfaceWaiter = null;
      ready(surface);
      return;
    }
    if (this.positionMs > 0) {
      this.pendingSeekMs = this.positionMs;
    }
    if (this.localSpec !== null) {
      this.attachLocalPlayer().catch((): void => {
      });
      return;
    }
    const view: PlaybackSessionView | null = this.session;
    const url: string | null = view !== null ? view.stream_url ?? null : null;
    if (url !== null && url.length > 0) {
      this.attachPlayer(url).catch((): void => {
      });
    }
  }

  surfaceDestroyed(generation: number): void {
    if (generation !== this.surfaceGeneration) {
      return;
    }
    this.pendingSeekMs = this.positionMs;
    this.surfaceId = '';
    this.releasePlayer().catch((): void => {
    });
  }

  // MARK: 传输命令（页面按键 / 面板调）

  /**
   * 行车锁视频开关（驾驶模式变化 → CarDriveState 播放模式 → 这里）：
   * audioLocked 只把 videoSurfaceVisible 翻 false——播放器页面据此把画面视图藏起来，
   * 音频链路不重建、进度不丢；恢复可见即回视频。不触碰播放器本身。
   */
  setVideoSurfaceVisible(visible: boolean): void {
    if (this.videoSurfaceVisible === visible) {
      return;
    }
    this.videoSurfaceVisible = visible;
    hilog.info(0x0000, 'CarFlow', 'VIDEO_SURFACE_VISIBLE %{public}s', `${visible}`);
  }

  pause(): void {
    this.controller.pause();
  }

  resume(): void {
    if (this.phase !== PlayPhase.paused) {
      return;
    }
    PlaybackOwnership.claim(this, (): void => {
      this.pause();
    });
    this.controller.play();
  }

  togglePlay(): void {
    if (this.phase === PlayPhase.playing) {
      this.pause();
    } else {
      this.resume();
    }
  }

  seekTo(ms: number): void {
    const bound: number = this.durationMs > 0 ? this.durationMs : ms;
    const target: number = Math.max(0, Math.min(bound, Math.floor(ms)));
    this.controller.seek(target);
    this.positionMs = target;
    this.timeBucket = Math.floor(target / 500);
  }

  /** 相对跳（传输条 ±10s） */
  seekBy(deltaMs: number): void {
    this.seekTo(this.positionMs + deltaMs);
  }

  /** 倍速（内核双引擎原生支持连续档位） */
  setPlaybackSpeed(rate: number): void {
    if (rate <= 0) {
      return;
    }
    this.playbackSpeed = rate;
    this.controller.setRate(rate);
  }

  // MARK: 轨道 / 画质 / 同意 / 重试

  /**
   * 选字幕（信息面板调）。后端把 subtitle_urls 与 decision.subtitles 按同一序生成，
   * 同一下标就能对上。外挂轨走重开挂载（换字幕 fd）；烧录型（流里已经烙进画面 /
   * 需要服务端重决策）开关都带 subtitle_track 重新协商。
   */
  async selectSubtitle(index: number): Promise<void> {
    const view: PlaybackSessionView | null = this.session;
    if (view === null) {
      return;
    }
    this.subtitleTouched = true;
    if (this.localSpec !== null) {
      // 本机副本：外挂字幕文件按选中下标换挂（subs/<存盘文件名>），无需重协商
      this.selectedSubtitleIndex = index;
      this.subtitleCue = '';
      this.pendingSeekMs = this.positionMs;
      await this.attachLocalPlayer();
      return;
    }
    if (index < 0) {
      this.selectedSubtitleIndex = -1;
      this.subtitleCue = '';
      if (this.burnedSubtitleRef().length > 0) {
        // 烧录在流里：关字幕要重新协商一条不带字幕的流
        this.reopenAt(this.positionMs > 0 ? this.positionMs : null);
        return;
      }
      // 外挂轨：内核摘轨即可（subtitlesOff）
      await this.controller.selectTrack('subtitle', null);
      return;
    }
    const plans: SubtitlePlanView[] = view.decision.subtitles;
    if (index >= plans.length) {
      return;
    }
    if (plans[index].track_ref === this.burnedSubtitleRef()) {
      // 选中的就是烧录轨：画面里已经有了，把外挂轨摘掉即可
      this.selectedSubtitleIndex = index;
      this.subtitleCue = '';
      await this.controller.selectTrack('subtitle', null);
      return;
    }
    const sidecar: boolean = this.burnedSubtitleRef().length === 0
      && index < view.subtitle_urls.length && view.subtitle_urls[index].length > 0;
    if (!sidecar) {
      // 烧录型 / 需要服务端重决策的字幕：带 track_ref 重新协商
      this.selectedSubtitleIndex = index;
      this.reopenAt(this.positionMs > 0 ? this.positionMs : null);
      return;
    }
    this.selectedSubtitleIndex = index;
    this.subtitleCue = '';
    this.pendingSeekMs = this.positionMs;
    await this.attachPlayer(view.stream_url ?? '');
  }

  /** 选音轨：直出档片内音轨原地切换；转码档一律带 audio_track 重新协商（可能顶成重封装） */
  selectAudio(ref: string): void {
    const view: PlaybackSessionView | null = this.session;
    if (view === null || ref.length === 0 || ref === this.activeAudioRef()) {
      return;
    }
    this.selectedAudioRef = ref;
    const tracks: AudioTrackView[] = view.decision.audio_tracks;
    const index: number = tracks.findIndex((track: AudioTrackView): boolean => track.ref === ref);
    if (index >= 0 && view.decision.tier === 0) {
      this.controller.selectTrack('audio',
        { language: tracks[index].language ?? '', title: '', ordinal: index, sourceCount: tracks.length });
      return;
    }
    this.failedTiers = [];
    this.retryCount = 0;
    this.reopenAt(this.positionMs > 0 ? this.positionMs : null);
  }

  /** 画质上限（信息面板调）：写记忆 + 重新协商，语义是上限（源不超就直通） */
  switchQuality(maxHeight: number): void {
    if (this.session === null) {
      return;
    }
    const target: number = maxHeight > 0 ? Math.floor(maxHeight) : 0;
    if (target === this.maxHeight) {
      return;
    }
    this.maxHeight = target;
    PlayerPrefs.writeQuality(this.request.itemId, this.currentSeason, this.currentEpisode, target);
    this.failedTiers = [];
    this.retryCount = 0;
    this.reopenAt(this.positionMs > 0 ? this.positionMs : null);
  }

  /** 切换播放引擎（auto/mpv/avplayer；全端共享偏好 player.engine.v2）：写偏好后从当前位置重开 */
  switchEngine(name: string): void {
    const normalized: string = name === 'avplayer' || name === 'mpv' ? name : 'auto';
    if (normalized === PlayerPrefs.engine()) {
      return;
    }
    PlayerPrefs.writeEngine(normalized);
    this.failedTiers = [];
    this.retryCount = 0;
    this.reopenAt(this.positionMs > 0 ? this.positionMs : null);
  }

  /** 同意层「开启并播放」：翻软件转码开关、校验回显、重新协商 */
  async grantConsent(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.released) {
      return;
    }
    this.consentSaving = true;
    try {
      const policy: PlaybackPolicyView = await api.playbackPolicySet({ software_transcode_enabled: true });
      if (policy.software_transcode_enabled !== true) {
        // 开关没生效（远程配置延迟等）：不当成功
        this.consentSaving = false;
        return;
      }
      this.consentSaving = false;
      this.reopenAt(this.positionMs > 0 ? this.positionMs : null);
    } catch (error) {
      this.consentSaving = false;
    }
  }

  /** 错误层「重试」：清降档台账从当前位置重协商 */
  retry(): void {
    if (this.released) {
      return;
    }
    this.failedTiers = [];
    this.retryCount = 0;
    this.errorMessage = '';
    this.errorSuggestion = '';
    this.errorKind = '';
    this.reopenAt(this.positionMs > 0 ? this.positionMs : null);
  }

  // MARK: 换集 / 自动连播

  /** 换到本季下一集（有在位文件的最近一集，缺集跳过）；没有返回 null */
  nextEpisode(): EpisodeView | null {
    if (this.currentSeason <= 0 || this.currentEpisode <= 0) {
      return null;
    }
    let best: EpisodeView | null = null;
    for (const episode of this.episodes) {
      if (episode.owned && episode.episode_number > this.currentEpisode
        && (best === null || episode.episode_number < best.episode_number)) {
        best = episode;
      }
    }
    return best;
  }

  /** 自动连播执行体：换到下一集，返回换到的集（没有返回 null） */
  playNext(): EpisodeView | null {
    const next: EpisodeView | null = this.nextEpisode();
    if (next === null) {
      return null;
    }
    this.switchToEpisode(next.episode_number);
    return next;
  }

  /** 上一集（有在位文件的最近一集；没有返回 null）——播控 playPrevious 用 */
  previousEpisode(): EpisodeView | null {
    if (this.currentSeason <= 0 || this.currentEpisode <= 0) {
      return null;
    }
    let best: EpisodeView | null = null;
    for (const episode of this.episodes) {
      if (episode.owned && episode.episode_number < this.currentEpisode
        && (best === null || episode.episode_number > best.episode_number)) {
        best = episode;
      }
    }
    return best;
  }

  /** 换到上一集；没有返回 null */
  playPrevious(): EpisodeView | null {
    const previous: EpisodeView | null = this.previousEpisode();
    if (previous === null) {
      return null;
    }
    this.switchToEpisode(previous.episode_number);
    return previous;
  }

  /** 换到本季任意一集：给旧集补发 stop，重置换集状态，让服务端自己挑文件 */
  switchToEpisode(episodeNumber: number): void {
    if (this.released) {
      return;
    }
    this.sessionCoordinator.close();
    this.currentEpisode = episodeNumber;
    this.currentFileId = null;
    this.failedTiers = [];
    this.retryCount = 0;
    // 新的一集重新允许试本机副本（上一集的失败不作数，同手机宿主）
    this.localFailedOnce = false;
    this.localFallingBack = false;
    this.selectedSubtitleIndex = -1;
    this.subtitleTouched = false;
    this.positionMs = 0;
    this.timeBucket = -1;
    this.durationMs = 0;
    this.bufferedEndMs = 0;
    this.subtitleCue = '';
    this.pendingSeekMs = -1;
    this.currentStartMs = null;
    this.loadQualityMemory().then((): void => {
      if (!this.released) {
        this.reopenAt(null);
      }
    });
  }

  // MARK: 只读助手（页面渲染用）

  subtitlePlans(): SubtitlePlanView[] {
    const view: PlaybackSessionView | null = this.session;
    return view !== null ? view.decision.subtitles : [];
  }

  audioTracks(): AudioTrackView[] {
    const view: PlaybackSessionView | null = this.session;
    return view !== null ? view.decision.audio_tracks : [];
  }

  /** 当前生效的音轨 ref：用户点选 > 服务端决策 > 默认轨 > 第一条 */
  activeAudioRef(): string {
    if (this.selectedAudioRef.length > 0) {
      return this.selectedAudioRef;
    }
    const view: PlaybackSessionView | null = this.session;
    if (view === null) {
      return '';
    }
    const plan: AudioPlanView | null = view.decision.audio ?? null;
    if (plan !== null && plan.track_ref !== null && plan.track_ref !== undefined
      && plan.track_ref.length > 0) {
      return plan.track_ref;
    }
    const tracks: AudioTrackView[] = view.decision.audio_tracks;
    for (const track of tracks) {
      if (track.is_default) {
        return track.ref;
      }
    }
    if (tracks.length > 0) {
      return tracks[0].ref;
    }
    return '';
  }

  segments(): PlaybackSegmentView[] | null {
    const view: PlaybackSessionView | null = this.session;
    return view !== null ? view.segments ?? null : null;
  }

  /** 烧进画面的字幕轨 ref（空 = 没有烧录） */
  burnedSubtitleRef(): string {
    const view: PlaybackSessionView | null = this.session;
    if (view === null) {
      return '';
    }
    const video: VideoPlanView | null = view.decision.video ?? null;
    if (video === null) {
      return '';
    }
    const ref: string | null = video.burn_subtitle ?? null;
    return ref !== null ? ref : '';
  }

  /** 当前落在的「跳过」区间（跳过片头按钮；离区间尾不足 3 秒不再给） */
  activeSkipSegment(): PlaybackSegmentView | null {
    return SkipSegments.active(this.segments(), this.positionMs);
  }

  // MARK: 内核接线（快照 / 事件 / 失败 / surface 重建 / 会话心跳）

  private bindController(): void {
    // auto 模式 AVPlayer 降级 MPV：Surface 无法跨解码器迁移，页面按代数重建 XComponent
    this.controller.onSurfaceReset = async (): Promise<string> => {
      if (this.released) {
        return '';
      }
      this.surfaceId = '';
      this.surfaceController = new XComponentController();
      const ready = new Promise<string>((resolve: (surface: string) => void): void => {
        this.surfaceWaiter = resolve;
      });
      this.surfaceGeneration++;
      return ready;
    };
    // 拖到转码窗口之前：带落点重开会话（服务端按 start_ms 开新窗口）
    this.controller.onSeekOutsideWindow = (positionMs: number): void => {
      this.reopenAt(positionMs);
    };
    this.sessionCoordinator.onHealth = (health: string): void => {
      if (this.released || this.reopening) {
        return;
      }
      if (health === 'endedByAdmin') {
        // 管理员在活动页结束了本次播放：原地停下并说明
        this.pause();
        this.fail('管理员已结束本次播放', '可以回到详情页重新开始播放', 'admin');
        this.sessionCoordinator.close();
        this.releasePlayer().catch((): void => {
        });
        return;
      }
      if (health === 'failed') {
        // 这档放不了（ping 起步即退）：把失败档报回服务端，不走重试预算
        const view: PlaybackSessionView | null = this.session;
        const tier: number = view !== null ? view.decision.tier ?? -1 : -1;
        if (tier >= 0 && !this.failedTiers.includes(tier)) {
          this.failedTiers.push(tier);
        }
        this.retryCount = 0;
      }
      // failed（降档重开）与 expired（会话被回收，原位重开）都从当前位置重开
      this.reopenAt(this.positionMs > 0 ? this.positionMs : null);
    };
    this.controller.onSnapshot = (snapshot: PlaybackSnapshot): void => {
      if (this.released) {
        return;
      }
      this.engineName = snapshot.engine;
      this.buffering = snapshot.buffering;
      this.durationMs = snapshot.durationMs;
      if (Math.floor(snapshot.positionMs / 500) !== this.timeBucket) {
        this.positionMs = snapshot.positionMs;
        this.timeBucket = Math.floor(snapshot.positionMs / 500);
      }
      this.viewingRecorder?.tick(snapshot.positionMs, snapshot.playing, snapshot.durationMs);
      this.sessionCoordinator.update(snapshot.positionMs, snapshot.durationMs, snapshot.playing);
      // 系统合规壳沿：起播建 AVSession + 长时任务，暂停收长时任务；快照喂播控元数据
      const previousPlaying: boolean = this.playing;
      this.playing = snapshot.playing;
      if (snapshot.playing && !previousPlaying) {
        const guard: PlaybackGuard | null = this.ensureGuard();
        if (guard !== null) {
          guard.start(this.request.title).catch((): void => {
          });
        }
      } else if (!snapshot.playing && previousPlaying) {
        this.guard?.pause().catch((): void => {
        });
      }
      this.guard?.updatePlayback(this.request.title, snapshot.durationMs, snapshot.positionMs,
        snapshot.playing, snapshot.rate);
      if (snapshot.playing) {
        this.phase = PlayPhase.playing;
      } else if (snapshot.phase === 'paused') {
        this.phase = PlayPhase.paused;
      } else if (snapshot.phase === 'ended') {
        this.phase = PlayPhase.ended;
      } else if (snapshot.phase !== 'idle' && snapshot.phase !== 'failed'
        && this.phase !== PlayPhase.consent && this.phase !== PlayPhase.error) {
        this.phase = PlayPhase.negotiating;
      }
    };
    this.controller.onEvent = (event: EngineEvent): void => {
      if (event.type === 'buffered') {
        // 已缓冲可播的毫秒数：换算成时间轴上的落点
        this.bufferedEndMs = this.positionMs + event.bufferedMs;
      } else if (event.type === 'size' && event.width > 0 && event.height > 0) {
        this.videoAspect = event.width / event.height;
      } else if (event.type === 'subtitle') {
        this.subtitleCue = event.text;
      }
    };
    this.controller.onFailure = (failure: EngineFailure): void => {
      hilog.error(0x0000, 'CarPlayback', 'engine failure kind=%{public}s code=%{public}d',
        failure.kind, failure.code);
      // 本机副本源打不开也走降级（回退服务器），不只是 canFallback 的流式失败
      if (failure.canFallback() || (this.localUnit !== null && failure.kind === 'source')) {
        this.onPlaybackFailed(failure.message);
        return;
      }
      const view: PlaybackSessionView | null = this.session;
      const suggestion: string = view !== null ? view.decision.suggestion ?? '' : '';
      this.fail(failure.message,
        suggestion.length > 0 ? suggestion : '可以点「重试」再试一次；反复出现请稍后再看',
        failure.kind === 'network' ? 'network' : 'decode');
      this.sessionCoordinator.close();
    };
  }

  // MARK: 协商

  private profile(): DeviceProfile {
    return DeviceCapability.car(this.deviceId);
  }

  private async negotiate(): Promise<void> {
    if (this.released) {
      return;
    }
    const epoch: number = ++this.sessionEpoch;
    await this.releasePlayer();
    if (epoch !== this.sessionEpoch || this.released) {
      return;
    }
    this.stopSession();
    this.phase = PlayPhase.negotiating;
    this.buffering = false;
    this.subtitleCue = '';
    this.bufferedEndMs = 0;
    // 本机有下完的副本就优先放本机（在线离线都优先；不建服务端会话，离线也能放）
    if (!this.localFailedOnce) {
      try {
        if (await this.tryStartLocal(epoch)) {
          return;
        }
      } catch (error) {
        if (epoch !== this.sessionEpoch || this.released) {
          return;
        }
        this.stopSession();
        this.localFailedOnce = true;
      }
    }
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      this.fail('没有可播放的本机副本，也未连接服务器', '请先连上服务器，或先把这一集下载到本机', 'session');
      return;
    }
    try {
      const body: CarSessionRequest = new CarSessionRequest();
      body.media_item_id = this.request.itemId;
      body.file_id = this.currentFileId !== null && this.currentFileId > 0 ? this.currentFileId : null;
      // 季集必须给数字（后端 schema 不可空），没有给 0
      body.season_number = this.currentSeason > 0 ? this.currentSeason : 0;
      body.episode_number = this.currentEpisode > 0 ? this.currentEpisode : 0;
      body.capability = DeviceCapability.capability(this.profile(), 'avplayer');
      body.failed_tiers = this.failedTiers;
      body.audio_track = this.selectedAudioRef.length > 0 ? this.selectedAudioRef : null;
      body.subtitle_track = this.subtitleTouched
        ? (this.selectedSubtitleIndex < 0 ? 'off' : this.subtitleRefOf(this.selectedSubtitleIndex))
        : null;
      body.max_height = this.maxHeight > 0 ? this.maxHeight : null;
      body.start_ms = this.resolveBodyStartMs();
      body.client = DeviceCapability.carClient;
      await PlayerPrefs.loadEngine();
      const gateway: MovieClawPlaybackGateway = new MovieClawPlaybackGateway(api, '',
        DeviceCapability.capabilityOf(this.profile()));
      const view: PlaybackSessionView = await gateway.open(body, PlayerPrefs.engine());
      if (epoch !== this.sessionEpoch || this.released) {
        gateway.stop(view).catch((): void => {
        });
        return;
      }
      this.session = view;
      if (view.decision.outcome === 'consent') {
        this.phase = PlayPhase.consent;
        return;
      }
      const url: string | null = view.stream_url ?? null;
      if (url === null || url.length === 0) {
        // 服务端说不能放：把它的理由原样给用户
        gateway.stop(view).catch((): void => {
        });
        const reason: string = view.decision.reason.length > 0
          ? view.decision.reason : '服务端没有给出可播放的地址';
        this.fail(reason, view.decision.suggestion ?? '', 'session');
        return;
      }
      this.loadEpisodes();
      this.applyStartPosition(view);
      this.sessionCoordinator.bind(new TvCarPlaybackSession(api, view,
        this.request.itemId, this.currentSeason, this.currentEpisode, this.deviceId,
        (): string => this.selectedAudioRef,
        (): string => this.subtitleTouched
          ? (this.selectedSubtitleIndex < 0 ? 'off' : this.subtitleRefOf(this.selectedSubtitleIndex))
          : ''));
      await this.attachPlayer(url);
    } catch (error) {
      if (epoch !== this.sessionEpoch || this.released) {
        return;
      }
      this.failFromError(error, '播放失败');
    }
  }

  /** 带续接位置的重开（重试 / 降档 / 换轨 / 换画质 / 心跳降档共用入口） */
  private reopenAt(positionMs: number | null): void {
    if (this.released || this.reopening) {
      return;
    }
    this.currentStartMs = positionMs;
    this.reopening = true;
    this.negotiate().then((): void => {
      this.reopening = false;
    }).catch((): void => {
      this.reopening = false;
    });
  }

  /** 请求体里的 start_ms：续接换流优先，其次「从头/指定位置」的首集覆盖 */
  private resolveBodyStartMs(): number | null {
    if (this.currentStartMs !== null && this.currentStartMs > 0) {
      return this.currentStartMs;
    }
    if (!this.startOverrideConsumed && this.request.startMs !== null && this.request.startMs > 0) {
      return this.request.startMs;
    }
    return null;
  }

  /** 起播落点（pendingSeekMs，内核 open 时消费）；优先级同 resolveBodyStartMs */
  private applyStartPosition(view: PlaybackSessionView): void {
    if (this.currentStartMs !== null) {
      this.pendingSeekMs = this.currentStartMs > 0 ? this.currentStartMs : -1;
      this.currentStartMs = null;
      return;
    }
    if (!this.startOverrideConsumed && this.request.startMs !== null) {
      this.startOverrideConsumed = true;
      // 0 = 从头播放：不跳（服务器可能按观看记录回续播点，忽略它）
      this.pendingSeekMs = this.request.startMs > 0 ? this.request.startMs : -1;
      return;
    }
    this.pendingSeekMs = view.start_ms > 0 ? view.start_ms : -1;
  }

  private async attachPlayer(url: string): Promise<void> {
    if (this.surfaceId.length === 0 || this.released) {
      // surface 还没就绪（视图后到）：surfaceReady 会拿着地址再挂一次
      return;
    }
    const view: PlaybackSessionView | null = this.session;
    if (view === null) {
      return;
    }
    const origin: number = view.timeline === 'file' || view.decision.tier === 0 ? 0 : view.start_ms;
    const subtitleUrl: string = this.selectedSubtitleIndex >= 0
      && this.selectedSubtitleIndex < view.subtitle_urls.length
      ? playbackUrl(AppModel.origin(), view.subtitle_urls[this.selectedSubtitleIndex]) : '';
    await this.controller.open(new PhoneMedia(origin, view.watch?.duration_ms ?? 0,
      playbackUrl(AppModel.origin(), url), '', subtitleUrl, '', this.cacheDirectory()),
      this.surfaceId, this.makeIntent(), PlayerPrefs.engine());
  }

  private makeIntent(): PlaybackIntent {
    const intent: PlaybackIntent = new PlaybackIntent();
    intent.positionMs = this.pendingSeekMs >= 0 ? this.pendingSeekMs : this.session?.start_ms ?? 0;
    this.pendingSeekMs = -1;
    intent.paused = false;
    intent.rate = this.playbackSpeed;
    intent.subtitlesOff = this.selectedSubtitleIndex < 0;
    if (this.selectedSubtitleIndex >= 0) {
      intent.subtitle = { language: '', title: '', ordinal: -1 };
    }
    const view: PlaybackSessionView | null = this.session;
    const tracks: AudioTrackView[] = view !== null ? view.decision.audio_tracks : [];
    const index: number = tracks.findIndex((track: AudioTrackView): boolean =>
      track.ref === this.selectedAudioRef);
    if (index >= 0 && view !== null && view.decision.tier === 0) {
      const preference: TrackPreference = {
        language: tracks[index].language ?? '',
        title: '',
        ordinal: index,
        sourceCount: tracks.length
      };
      intent.audio = preference;
    }
    return intent;
  }

  private async releasePlayer(): Promise<void> {
    await this.controller.release();
  }

  // MARK: 本机副本（离线下载的播放路径，同手机宿主 tryStartLocal / startLocal）

  /**
   * 有下完的本机副本就放本机（在线离线都优先本机，不建服务端会话）。
   * 副本 / playback.json / 媒体文件缺一样都算没有，回退流式。
   */
  private async tryStartLocal(epoch: number): Promise<boolean> {
    const store: OfflineStore = OfflineStore.shared;
    if (!this.awaitedOfflineStore) {
      this.awaitedOfflineStore = true;
      await store.waitUntilLoaded();
    }
    if (epoch !== this.sessionEpoch || this.released) {
      return false;
    }
    const unit: OfflineUnit | null = store.playableUnit(this.request.itemId,
      this.currentSeason, this.currentEpisode);
    if (unit === null) {
      return false;
    }
    const media: string | null = store.mediaPath(unit);
    if (media === null || OfflineDisk.fileSize(media) <= 0) {
      return false;
    }
    const spec: OfflinePlaybackSpec | null = store.spec(unit);
    if (spec === null) {
      return false;
    }
    // 续播点：重开续接 > 首集指定 > 服务端（2 秒竞速，离线不干等）> 本机 progress.json
    const resumeMs: number = await this.localResumeMs(store, unit);
    if (epoch !== this.sessionEpoch || this.released) {
      return false;
    }
    this.localMediaPath = media;
    this.localUnit = unit;
    this.localSpec = spec;
    this.session = this.localSessionView(spec, resumeMs);
    this.viewingRecorder = new OfflineViewingRecorder(unit, resumeMs,
      spec.durationMs ?? null, this.api());
    this.pendingSeekMs = resumeMs > 0 ? resumeMs : -1;
    this.loadEpisodes();
    await this.attachLocalPlayer();
    return true;
  }

  /**
   * 本机续播点：重开（换字幕/换轨/降档）续在当前位置；首集的「从头/指定位置」只生效一次；
   * 能连上服务端就以它为准（一家人共用一份观看记录），2 秒拿不到用本机 progress.json 记的。
   */
  private async localResumeMs(store: OfflineStore, unit: OfflineUnit): Promise<number> {
    if (this.currentStartMs !== null) {
      return this.currentStartMs > 0 ? this.currentStartMs : 0;
    }
    if (!this.startOverrideConsumed && this.request.startMs !== null) {
      this.startOverrideConsumed = true;
      return this.request.startMs > 0 ? this.request.startMs : 0;
    }
    const api: MovieClawApi | null = this.api();
    if (api !== null) {
      const state: PlaybackStateView | null = await this.raceResume(
        api.playbackResume(this.request.itemId, unit.season > 0 ? unit.season : undefined,
          unit.episode > 0 ? unit.episode : undefined));
      if (state !== null) {
        return state.played ? 0 : (state.position_ms ?? 0);
      }
    }
    const progress: OfflineProgress | null = store.localProgress(this.request.itemId,
      unit.season, unit.episode);
    if (progress !== null && !progress.played) {
      return progress.positionMs;
    }
    return 0;
  }

  /** 问服务端要 2 秒：到点没回来就当没有（离线时起播不能被网络拖住） */
  private raceResume(promise: Promise<PlaybackStateView>): Promise<PlaybackStateView | null> {
    return new Promise<PlaybackStateView | null>(
      (resolve: (value: PlaybackStateView | null) => void) => {
        let settled: boolean = false;
        const timer: number = setTimeout((): void => {
          settled = true;
          resolve(null);
        }, 2000);
        promise.then((state: PlaybackStateView): void => {
          if (!settled) {
            settled = true;
            clearTimeout(timer);
            resolve(state);
          }
        }).catch((): void => {
          if (!settled) {
            settled = true;
            clearTimeout(timer);
            resolve(null);
          }
        });
      });
  }

  /**
   * 本机会话视图：结构与流式一致，界面（章节 / 音轨 / 字幕 / 档位）不用分叉。
   * 决策定成 plan + tier 0（本机副本不参与服务端档位体系）。
   */
  private localSessionView(spec: OfflinePlaybackSpec, startMs: number): PlaybackSessionView {
    const subtitles: SubtitlePlanView[] = [];
    for (const sub of spec.subtitles) {
      const plan: SubtitlePlanView = {
        track_ref: sub.ref,
        kind: sub.kind,
        language: sub.language,
        is_default: sub.isDefault,
        is_ai: sub.isAi,
        title: sub.title,
        is_forced: sub.isForced
      };
      subtitles.push(plan);
    }
    const decision: PlaybackDecisionView = {
      outcome: 'plan',
      tier: 0,
      file_id: this.currentFileId,
      container: spec.container,
      audio_tracks: this.parseAudioTracks(spec.audioTracksJson),
      subtitles: subtitles,
      reason: '播放本机副本'
    };
    const view: PlaybackSessionView = {
      decision: decision,
      session_id: null,
      stream_url: null,
      progressive_segments: false,
      start_ms: startMs,
      timeline: 'file',
      subtitle_urls: [],
      chapters: this.parseChapters(spec.chaptersJson),
      segments: this.parseSegments(spec.segmentsJson)
    };
    return view;
  }

  /** 挂本机播放器：媒体与字幕都是本机文件 fd（subtitlePath 空串 = 关字幕） */
  private async attachLocalPlayer(): Promise<void> {
    const spec: OfflinePlaybackSpec | null = this.localSpec;
    if (this.surfaceId.length === 0 || this.released || spec === null) {
      // surface 还没就绪（视图后到）：surfaceReady 会拿着本机路径再挂一次
      return;
    }
    let subtitlePath: string = '';
    if (this.selectedSubtitleIndex >= 0 && this.selectedSubtitleIndex < spec.subtitles.length) {
      const directory: string = this.localMediaPath.substring(0, this.localMediaPath.lastIndexOf('/'));
      subtitlePath = `${directory}/subs/${spec.subtitles[this.selectedSubtitleIndex].fileName}`;
    }
    await this.controller.open(new PhoneMedia(0, spec.durationMs ?? 0, '',
      this.localMediaPath, '', subtitlePath), this.surfaceId, this.makeIntent(), PlayerPrefs.engine());
  }

  private parseAudioTracks(json: string): AudioTrackView[] {
    if (json.length === 0 || json === 'null') {
      return [];
    }
    const list: AudioTrackView[] = JSON.parse(json) as AudioTrackView[];
    return Array.isArray(list) ? list : [];
  }

  private parseChapters(json: string): PlaybackChapterMarkView[] {
    if (json.length === 0 || json === 'null') {
      return [];
    }
    const list: PlaybackChapterMarkView[] = JSON.parse(json) as PlaybackChapterMarkView[];
    return Array.isArray(list) ? list : [];
  }

  private parseSegments(json: string): PlaybackSegmentView[] | null {
    if (json.length === 0 || json === 'null') {
      return null;
    }
    const list: PlaybackSegmentView[] = JSON.parse(json) as PlaybackSegmentView[];
    return Array.isArray(list) ? list : null;
  }

  /** 显式收掉会话（补发 stop + playbackSessionStop；重开 / 换集 / 退出都要，不然服务端会一直转）。
   * 本机播放走这里收尾：观看记录 finish 落盘补传、清本机副本状态。 */
  private stopSession(): void {
    this.sessionCoordinator.close();
    this.session = null;
    const recorder: OfflineViewingRecorder | null = this.viewingRecorder;
    this.viewingRecorder = null;
    recorder?.finish(this.positionMs, this.phase === PlayPhase.ended);
    this.localUnit = null;
    this.localSpec = null;
    this.localMediaPath = '';
  }

  private loadEpisodes(): void {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.currentSeason <= 0 || this.currentEpisode <= 0) {
      return;
    }
    api.playbackItemEpisodes(this.request.itemId, this.currentSeason)
      .then((view: SeasonEpisodesView): void => {
        if (!this.released) {
          this.episodes = view.episodes;
        }
      })
      .catch((): void => {
        this.episodes = [];
      });
  }

  private async loadQualityMemory(): Promise<void> {
    try {
      this.maxHeight = await PlayerPrefs.quality(this.request.itemId,
        this.currentSeason, this.currentEpisode);
    } catch (error) {
      this.maxHeight = 0;
    }
  }

  /** 设备标识（car.installation_id；会话上报 device_id 用）。空 = 不报。 */
  private async ensureDeviceId(): Promise<void> {
    if (this.deviceId.length > 0) {
      return;
    }
    const raw: Context | null = CarPlaybackHost.appContext;
    if (raw === null) {
      return;
    }
    try {
      if (CarPlaybackHost.deviceStore === null) {
        CarPlaybackHost.deviceStore = await preferences.getPreferences(raw, 'movieclaw_car');
      }
      this.deviceId = await CarPlaybackHost.deviceStore.get('car.installation_id', '') as string;
    } catch (error) {
      this.deviceId = '';
    }
  }

  private cacheDirectory(): string {
    const raw: Context | null = CarPlaybackHost.appContext;
    return raw !== null ? raw.cacheDir : '';
  }

  private subtitleRefOf(index: number): string {
    const plans: SubtitlePlanView[] = this.subtitlePlans();
    if (index < 0 || index >= plans.length) {
      return '';
    }
    return plans[index].track_ref;
  }

  // MARK: 失败降档 / 错误态

  /**
   * 这一档放不了：把失败档位报回服务端再要一次（运行期降档回路），
   * 统一内核口径最多重试 4 次；再失败进错误态（归因给到页面的错误弹窗）。
   */
  private onPlaybackFailed(reason: string): void {
    if (this.reopening || this.localFallingBack) {
      return;
    }
    if (this.localUnit !== null) {
      // 本机副本放不了：记一次失败，就地改走服务器（从当前位置续）
      this.localFallingBack = true;
      this.localFailedOnce = true;
      this.currentStartMs = this.positionMs;
      this.releasePlayer().then((): void => {
        this.stopSession();
        this.localFallingBack = false;
        this.negotiate().catch((): void => {
        });
      }).catch((): void => {
        this.localFallingBack = false;
      });
      return;
    }
    const view: PlaybackSessionView | null = this.session;
    const tier: number = view !== null ? view.decision.tier ?? -1 : -1;
    if (!this.failedTiers.includes(tier)) {
      this.failedTiers.push(tier);
    }
    if (tier < 0 || this.retryCount >= 4) {
      const suggestion: string = view !== null ? view.decision.suggestion ?? '' : '';
      this.fail(reason,
        suggestion.length > 0 ? suggestion : '可以点「重试」再试一次；反复出现请稍后再看',
        'decode');
      this.sessionCoordinator.close();
      return;
    }
    this.retryCount++;
    this.reopenAt(this.positionMs > 0 ? this.positionMs : null);
  }

  private fail(message: string, suggestion: string, kind: string): void {
    this.phase = PlayPhase.error;
    this.errorMessage = message;
    this.errorSuggestion = suggestion;
    this.errorKind = kind;
    this.buffering = false;
  }

  /** 把请求失败归到 network / session（错误视图按它给行动建议） */
  private failFromError(error: Object, fallback: string): void {
    if (error instanceof ApiError) {
      if (error.status === 0 || error.status === -1) {
        this.fail('连不上服务器', '请检查网络后重试', 'network');
        return;
      }
      const message: string = error.message.length > 0 ? error.message : `${fallback}（${error.status}）`;
      this.fail(message, '', 'session');
      return;
    }
    const text: string = `${error}`;
    this.fail(text.length > 0 ? text : fallback, '', 'session');
  }
}

/**
 * 起播协调（playback-first）：按下播放先建宿主并预协商（不等播放器视图），
 * 播放器页面出现时 adopt() 接管正在协商的宿主；退出时 end() 整体收尾。
 */
export class CarPlayback {
  private static host: CarPlaybackHost | null = null;

  static begin(request: PlayRequest): CarPlaybackHost {
    hilog.info(0x0000, 'DbgFlow', 'PLAYBACK_BEGIN item=%{public}d', request.itemId);
    CarPlayback.end();
    const host: CarPlaybackHost = new CarPlaybackHost(request);
    CarPlayback.host = host;
    host.prepare();
    return host;
  }

  static adopt(): CarPlaybackHost | null {
    hilog.info(0x0000, 'DbgFlow', 'PLAYBACK_ADOPT host=%{public}s', `${CarPlayback.host !== null}`);
    return CarPlayback.host;
  }

  static end(): void {
    hilog.info(0x0000, 'DbgFlow', 'PLAYBACK_END');
    const host: CarPlaybackHost | null = CarPlayback.host;
    CarPlayback.host = null;
    if (host !== null) {
      host.release();
    }
  }
}
