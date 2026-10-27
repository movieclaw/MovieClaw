/**
 * TV 播放引擎（T019，US4）：AVPlayer + 服务端 HLS 会话。
 *
 * 节奏与手机端 PlayerPage / iOS PlaybackController 对齐：
 * - 协商：capability + failed_tiers → playbackSessionStart；consent 结果弹同意层；
 * - 起播：initialized 挂 surface + 看门狗 25s → prepared 跳续播点并 play；
 * - 节奏：首次 playing 报 start，之后每 10s 报 progress，15s 一次会话 ping
 *   （200+failed=true 降档重开 / 404 原位重开）；退出/换集前补 stop；
 * - 降档：播放失败把失败档报回服务端重开一次（只重试一次），再失败进错误态；
 * - 轨道：字幕走 subtitle_urls 外挂轨（addSubtitleFromUrl + selectTrack），
 *   烧录型（decision.video.burn_subtitle）开关都带 subtitle_track 重新协商；
 *   音轨选择一律带 audio_track 重新协商（可能把直出顶成重封装，由服务端重新决策）；
 * - 画质：max_height 上限语义，记忆存 PlayerPrefs（按条目+季+集）。
 *
 * 状态全部用 @ObservedV2/@Trace 暴露：页面只管渲染引擎状态，不做播放逻辑。
 * 起播是 playback-first：按下播放 TvPlayback.begin() 就先协商，
 * 播放器视图后到再拿 surfaceId 挂播放器（T022）。
 */
import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppModel } from '../../common/AppModel';
import { MovieClawApi } from '../../api/Endpoints';
import { ApiError } from '../../api/ApiClient';
import { JsonValue, jsonBoolValue } from '../../api/JsonValue';
import { PlayerPrefs } from '../../player/PlayerPrefs';
import {
  AudioSupportIn,
  ClientCapabilityIn,
  PlaybackSessionRequest,
  PlaybackSessionView,
  PlaybackStateView,
  PlaybackPolicyView,
  PlaybackProgressRequest,
  AudioTrackView,
  EpisodeView,
  SeasonEpisodesView,
  SubtitlePlanView,
  VideoSupportIn,
  VideoPlanView,
  AudioPlanView,
  PlaybackSegmentView
} from '../../api/Models';
import { TvPlayRequest } from '../model/TvUiState';

/** 播放阶段（页面按它切换骨架 / 转圈 / 画面 / 错误层 / 同意层） */
export class TvPlayPhase {
  static readonly idle: string = 'idle';
  static readonly negotiating: string = 'negotiating';
  static readonly playing: string = 'playing';
  static readonly paused: string = 'paused';
  static readonly ended: string = 'ended';
  static readonly consent: string = 'consent';
  static readonly error: string = 'error';
}

/**
 * 跳过区间 / 自动连播的用法（同手机端 SkipSegments，逻辑照 Web timeline.ts）：
 * 区间是服务端整季比对认出来、随会话下发的，这里只按位置用。
 * `outro && to_end`（放到结尾的片尾）不进「跳过」按钮，交给「即将播放」卡片。
 */
export class TvSkipSegments {
  /** 离区间尾不足这么多毫秒不再给「跳过」：按下去只省一两秒 */
  static readonly tailMs: number = 3000;
  /** 自动播下一集的倒计时 8 秒 */
  static readonly autoNextMs: number = 8000;
  /** 连续自动播了这么多集、期间没人碰过播放器，就不再自动播 */
  static readonly autoNextMaxStreak: number = 3;

  static active(segments: PlaybackSegmentView[] | null, positionMs: number): PlaybackSegmentView | null {
    if (segments === null) {
      return null;
    }
    for (const segment of segments) {
      if (segment.type === 'outro' && segment.to_end) {
        continue;
      }
      if (positionMs >= segment.start_ms && positionMs < segment.end_ms - TvSkipSegments.tailMs) {
        return segment;
      }
    }
    return null;
  }

  static isInOutro(segments: PlaybackSegmentView[] | null, positionMs: number): boolean {
    if (segments === null) {
      return false;
    }
    for (const segment of segments) {
      if (segment.type === 'outro' && segment.to_end && positionMs >= segment.start_ms) {
        return true;
      }
    }
    return false;
  }

  /** 卡片要不要倒计时自动播下一集：进了放到结尾的片尾就开始，或已播完 */
  static autoNextArmed(segments: PlaybackSegmentView[] | null, positionMs: number,
    streak: number, ended: boolean): boolean {
    return streak < TvSkipSegments.autoNextMaxStreak
      && (ended || TvSkipSegments.isInOutro(segments, positionMs));
  }

  /** 「即将播放」卡片的时机：片尾起点就给，否则播完才给 */
  static shouldShowUpNext(segments: PlaybackSegmentView[] | null, positionMs: number,
    ended: boolean): boolean {
    if (ended) {
      return true;
    }
    if (TvSkipSegments.active(segments, positionMs) !== null) {
      return false;
    }
    return TvSkipSegments.isInOutro(segments, positionMs);
  }
}

/** `ClientCapabilityIn` 有必填字段但其余可选，用类构造以便阅读（同手机端） */
class Capability implements ClientCapabilityIn {
  video?: VideoSupportIn[] | null;
  audio?: AudioSupportIn[] | null;
  containers?: string[] | null;
  hdr_passthrough?: boolean | null;
  mse?: string | null;
  is_mobile?: boolean | null;
  native_hls?: boolean | null;
  universal?: boolean | null;
}

class VideoSupport implements VideoSupportIn {
  codec: string = '';
  max_height?: number | null;
  active: boolean = true;
}

class AudioSupport implements AudioSupportIn {
  codec: string = '';
  max_channels?: number | null;
  active: boolean = true;
}

/** `PlaybackSessionRequest` 的 capability 必填，其余可选（TV 声明：非移动端、原生 HLS） */
class SessionRequest implements PlaybackSessionRequest {
  file_id?: number | null;
  media_item_id?: number | null;
  season_number?: number | null;
  episode_number?: number | null;
  capability: ClientCapabilityIn = new Capability();
  failed_tiers?: number[] | null;
  audio_track?: string | null;
  max_height?: number | null;
  start_ms?: number | null;
  client?: string | null;
}

class ProgressRequest implements PlaybackProgressRequest {
  media_item_id: number = 0;
  season_number?: number | null;
  episode_number?: number | null;
  event?: string | null;
  position_ms?: number | null;
  audio_track?: string | null;
  subtitle_track?: string | null;
  file_id?: number | null;
  device_id?: string | null;
  paused?: boolean | null;
}

/**
 * TV 播放引擎：一个条目（一集）一个实例，换集在实例内完成。
 * 页面只渲染 @Trace 状态、调命令方法；不感知 AVPlayer。
 */
@ObservedV2
export class TvAvPlayerEngine {
  // MARK: 界面状态（@Trace）

  /** 当前阶段，见 TvPlayPhase */
  @Trace phase: string = TvPlayPhase.idle;
  @Trace errorMessage: string = '';
  @Trace errorSuggestion: string = '';
  /** 错误归因：network / decode / session / admin（FR-013 错误弹窗按它给建议） */
  @Trace errorKind: string = '';
  /** 播放位置 / 时长 / 已缓冲到的位置（毫秒，0 = 未知） */
  @Trace positionMs: number = 0;
  @Trace durationMs: number = 0;
  @Trace bufferedEndMs: number = 0;
  /** 转圈（起播 / 卡顿补缓冲） */
  @Trace buffering: boolean = false;
  /** 系统字幕回调的当前文本（空 = 无） */
  @Trace subtitleCue: string = '';
  /** 画面宽高比（0 = 未知），surface 按它摆才不变形 */
  @Trace videoAspect: number = 0;
  /** 当前倍速（仅 UI 回显） */
  @Trace playbackSpeed: number = 1;
  /** 会话视图（决策 / 字幕地址 / 分段 / 会话号），换流时整体替换 */
  @Trace session: PlaybackSessionView | null = null;
  /** 本季分集（「即将播放」卡片 / 自动连播用） */
  @Trace episodes: EpisodeView[] = [];
  /** 当前选中的字幕下标（对应 session.decision.subtitles；-1 = 关） */
  @Trace selectedSubtitleIndex: number = -1;
  /** 用户点选的音轨 ref（'' = 服务端自动） */
  @Trace selectedAudioRef: string = '';
  /** 画质上限（0 = 自动 / 原画；上限语义：源不超就直通） */
  @Trace maxHeight: number = 0;
  /** 同意层「开启并播放」请求中 */
  @Trace consentSaving: boolean = false;
  /** 换集 / 重开都会推进的集号（页面标题行用） */
  @Trace currentSeason: number = 0;
  @Trace currentEpisode: number = 0;

  // MARK: 请求输入（构造后不变）

  readonly request: TvPlayRequest;

  // MARK: 播放器内部（非观察状态）

  private player: media.AVPlayer | null = null;
  private surfaceId: string = '';
  /** prepared 之后再跳的落点（idle 态不能 seek）；-1 = 不跳 */
  private pendingSeekMs: number = -1;
  /** 换流时的续接位置（negotiate 时消费一次）；null = 按服务端 start_ms */
  private currentStartMs: number | null = null;
  private loadedSubtitleTrack: number = -1;
  /** 用户这一集碰过字幕选择没有（碰过才上报 subtitle_track） */
  private subtitleTouched: boolean = false;
  private failedTiers: number[] = [];
  private retryCount: number = 0;
  /** 降档窗口内连发的 error 只处理一次 */
  private failureInFlight: boolean = false;
  private reportedStart: boolean = false;
  /** request.startMs 的「从头/指定位置」只对第一集生效 */
  private startOverrideConsumed: boolean = false;
  private reportTimer: number = -1;
  private pingTimer: number = -1;
  private watchdog: number = -1;
  private attachGeneration: number = 0;
  private released: boolean = false;
  private prepared: boolean = false;
  private currentFileId: number | null = null;

  constructor(request: TvPlayRequest) {
    this.request = request;
    this.currentSeason = request.seasonNumber ?? 0;
    this.currentEpisode = request.episodeNumber ?? 0;
    this.currentFileId = request.fileId ?? null;
  }

  // MARK: 生命周期

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  /**
   * 预协商（playback-first，T022）：按下播放就建会话，不等播放器视图。
   * 可重入（begin + 页面兜底各调一次），只有第一次生效。
   */
  async prepare(): Promise<void> {
    if (this.released || this.prepared) {
      return;
    }
    this.prepared = true;
    await this.loadQualityMemory();
    if (this.released) {
      return;
    }
    await this.negotiate();
  }

  /** 播放器视图就绪：把 surface 交给引擎，会话已协商好就直接挂播放器 */
  start(surfaceId: string): void {
    if (this.released || surfaceId.length === 0) {
      return;
    }
    this.surfaceId = surfaceId;
    const view: PlaybackSessionView | null = this.session;
    if (view === null || this.player !== null) {
      // 会话还没回来：negotiate 收尾的 attachPlayer 会拿这份 surfaceId 挂
      return;
    }
    const url: string | null = view.stream_url ?? null;
    if (url === null || url.length === 0) {
      return;
    }
    this.attachPlayer(AppModel.origin() + url);
  }

  /** 整体退出：补 stop、收会话、放播放器。幂等。 */
  release(): void {
    if (this.released) {
      return;
    }
    this.released = true;
    this.disarmWatchdog();
    this.stopLoops();
    if (this.reportedStart) {
      this.reportProgressEvent('stop');
      this.reportedStart = false;
    }
    this.stopSession();
    this.releasePlayer();
    this.phase = TvPlayPhase.idle;
    this.buffering = false;
    this.subtitleCue = '';
  }

  // MARK: 传输命令（页面按键 / 面板调）

  pause(): void {
    const player: media.AVPlayer | null = this.player;
    if (player === null || player.state !== 'playing') {
      return;
    }
    try {
      player.pause();
    } catch (error) {
    }
  }

  resume(): void {
    const player: media.AVPlayer | null = this.player;
    if (player === null || player.state !== 'paused') {
      return;
    }
    try {
      player.play();
    } catch (error) {
    }
  }

  togglePlay(): void {
    if (this.phase === TvPlayPhase.playing) {
      this.pause();
    } else {
      this.resume();
    }
  }

  seekTo(ms: number): void {
    const player: media.AVPlayer | null = this.player;
    if (player === null) {
      return;
    }
    const bound: number = this.durationMs > 0 ? this.durationMs : ms;
    const target: number = Math.max(0, Math.min(bound, Math.floor(ms)));
    try {
      player.seek(target, media.SeekMode.SEEK_CLOSEST);
      this.positionMs = target;
    } catch (error) {
    }
  }

  /** 相对跳（遥控 ±10s） */
  seekBy(deltaMs: number): void {
    this.seekTo(this.positionMs + deltaMs);
  }

  /** 倍速（AVPlayer 只有离散档，就近映射） */
  setPlaybackSpeed(rate: number): void {
    const player: media.AVPlayer | null = this.player;
    if (player === null) {
      return;
    }
    let mapped: media.PlaybackSpeed;
    if (rate <= 0.875) {
      mapped = media.PlaybackSpeed.SPEED_FORWARD_0_75_X;
    } else if (rate <= 1.125) {
      mapped = media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
    } else if (rate <= 1.375) {
      mapped = media.PlaybackSpeed.SPEED_FORWARD_1_25_X;
    } else if (rate <= 1.625) {
      mapped = media.PlaybackSpeed.SPEED_FORWARD_1_50_X;
    } else if (rate <= 1.875) {
      mapped = media.PlaybackSpeed.SPEED_FORWARD_1_75_X;
    } else {
      mapped = media.PlaybackSpeed.SPEED_FORWARD_2_00_X;
    }
    try {
      player.setSpeed(mapped);
      this.playbackSpeed = rate;
    } catch (error) {
    }
  }

  // MARK: 轨道 / 画质 / 同意 / 重试

  /**
   * 选字幕（信息面板调）。后端把 subtitle_urls 与 decision.subtitles 按同一序生成，
   * 同一下标就能对上。外挂轨走 addSubtitleFromUrl + selectTrack（即时生效）；
   * 烧录型（流里已经烙进画面）开关都要带 subtitle_track 重新协商。
   */
  async selectSubtitle(index: number): Promise<void> {
    const view: PlaybackSessionView | null = this.session;
    if (view === null) {
      return;
    }
    this.subtitleTouched = true;
    const player: media.AVPlayer | null = this.player;
    if (index < 0) {
      this.selectedSubtitleIndex = -1;
      this.subtitleCue = '';
      if (this.burnedSubtitleRef().length > 0) {
        // 烧录在流里：关字幕要重新协商一条不带字幕的流
        this.renegotiate(this.positionMs > 0 ? this.positionMs : null);
        return;
      }
      if (player !== null && this.loadedSubtitleTrack >= 0) {
        const track: number = this.loadedSubtitleTrack;
        this.loadedSubtitleTrack = -1;
        try {
          await player.deselectTrack(track);
        } catch (error) {
        }
      }
      return;
    }
    const plans: SubtitlePlanView[] = view.decision.subtitles;
    if (index >= plans.length) {
      return;
    }
    if (plans[index].track_ref === this.burnedSubtitleRef()) {
      // 选中的就是烧录轨：画面里已经有了，摘掉外挂轨即可
      this.selectedSubtitleIndex = index;
      this.subtitleCue = '';
      if (player !== null && this.loadedSubtitleTrack >= 0) {
        const track: number = this.loadedSubtitleTrack;
        this.loadedSubtitleTrack = -1;
        try {
          await player.deselectTrack(track);
        } catch (error) {
        }
      }
      return;
    }
    const urls: string[] = view.subtitle_urls;
    const sidecar: boolean = this.burnedSubtitleRef().length === 0
      && index < urls.length && urls[index].length > 0;
    if (!sidecar) {
      // 烧录型 / 需要服务端重决策的字幕：带 track_ref 重新协商
      this.selectedSubtitleIndex = index;
      this.renegotiate(this.positionMs > 0 ? this.positionMs : null);
      return;
    }
    if (player === null) {
      return;
    }
    try {
      if (this.loadedSubtitleTrack >= 0) {
        const old: number = this.loadedSubtitleTrack;
        this.loadedSubtitleTrack = -1;
        await player.deselectTrack(old);
      }
      await player.addSubtitleFromUrl(AppModel.origin() + urls[index]);
      const found: number = await this.findSubtitleTrack(player);
      if (found >= 0) {
        await player.selectTrack(found);
        this.loadedSubtitleTrack = found;
        this.selectedSubtitleIndex = index;
        this.subtitleCue = '';
      }
    } catch (error) {
    }
  }

  /** 选音轨：一律带 audio_track 重新协商（选非默认轨可能把直出顶成重封装） */
  selectAudio(ref: string): void {
    const view: PlaybackSessionView | null = this.session;
    if (view === null || ref.length === 0 || ref === this.activeAudioRef()) {
      return;
    }
    this.selectedAudioRef = ref;
    this.failedTiers = [];
    this.retryCount = 0;
    this.renegotiate(this.positionMs > 0 ? this.positionMs : null);
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
    this.renegotiate(this.positionMs > 0 ? this.positionMs : null);
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
        // 开关没生效（远程配置延迟等）：不当成功（iOS 同款校验）
        this.consentSaving = false;
        return;
      }
      this.consentSaving = false;
      this.renegotiate(this.positionMs > 0 ? this.positionMs : null);
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
    this.renegotiate(this.positionMs > 0 ? this.positionMs : null);
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

  /** 换到本季任意一集：给旧集补发 stop，重置换集状态，让服务端自己挑文件 */
  switchToEpisode(episodeNumber: number): void {
    if (this.released) {
      return;
    }
    if (this.reportedStart) {
      this.reportedStart = false;
      this.reportProgressEvent('stop');
    }
    this.currentEpisode = episodeNumber;
    this.currentFileId = null;
    this.failedTiers = [];
    this.retryCount = 0;
    this.selectedSubtitleIndex = -1;
    this.subtitleTouched = false;
    this.loadedSubtitleTrack = -1;
    this.positionMs = 0;
    this.durationMs = 0;
    this.bufferedEndMs = 0;
    this.subtitleCue = '';
    this.pendingSeekMs = -1;
    this.loadQualityMemory().then((): void => {
      if (!this.released) {
        this.renegotiate(null);
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

  /** 当前落在的「跳过」区间（跳过片头按钮） */
  activeSkipSegment(): PlaybackSegmentView | null {
    return TvSkipSegments.active(this.segments(), this.positionMs);
  }

  // MARK: 协商

  private async negotiate(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      this.fail('还没有连上服务器', '请先到设置里连上服务器', 'session');
      return;
    }
    if (this.released) {
      return;
    }
    this.phase = TvPlayPhase.negotiating;
    this.failureInFlight = false;
    this.buffering = false;
    this.subtitleCue = '';
    this.bufferedEndMs = 0;
    try {
      const body: SessionRequest = new SessionRequest();
      body.media_item_id = this.request.itemId;
      body.file_id = this.currentFileId !== null && this.currentFileId > 0 ? this.currentFileId : null;
      // 季集必须给数字（后端 schema 不可空），没有给 0
      body.season_number = this.currentSeason > 0 ? this.currentSeason : 0;
      body.episode_number = this.currentEpisode > 0 ? this.currentEpisode : 0;
      body.capability = this.capability();
      body.failed_tiers = this.failedTiers;
      body.audio_track = this.selectedAudioRef.length > 0 ? this.selectedAudioRef : null;
      body.max_height = this.maxHeight > 0 ? this.maxHeight : null;
      body.start_ms = this.resolveBodyStartMs();
      body.client = 'harmony_tv';
      const view: PlaybackSessionView = await api.playbackSessionStart(body);
      if (this.released) {
        return;
      }
      this.session = view;
      if (view.decision.outcome === 'consent') {
        this.phase = TvPlayPhase.consent;
        return;
      }
      const url: string | null = view.stream_url ?? null;
      if (url === null || url.length === 0) {
        // 服务端说不能放：把它的理由原样给用户
        const reason: string = view.decision.reason.length > 0
          ? view.decision.reason : '服务端没有给出可播放的地址';
        this.fail(reason, view.decision.suggestion ?? '', 'session');
        return;
      }
      this.loadEpisodes(api);
      this.applyStartPosition(view);
      await this.attachPlayer(AppModel.origin() + url);
    } catch (error) {
      if (this.released) {
        return;
      }
      this.failFromError(error, '播放失败');
    }
  }

  /** 带续接位置的重协商：先拆干净（收心跳/收会话/放播放器）再重新协商 */
  private renegotiate(startMs: number | null): void {
    if (this.released) {
      return;
    }
    this.currentStartMs = startMs;
    this.disarmWatchdog();
    this.stopLoops();
    this.stopSession();
    this.releasePlayer();
    this.negotiate();
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

  /** 起播落点（pendingSeekMs，prepared 后消费）：优先级同 resolveBodyStartMs */
  private applyStartPosition(view: PlaybackSessionView): void {
    if (this.currentStartMs !== null) {
      this.pendingSeekMs = this.currentStartMs > 0 ? this.currentStartMs : -1;
      this.currentStartMs = null;
      return;
    }
    if (!this.startOverrideConsumed && this.request.startMs !== null) {
      this.startOverrideConsumed = true;
      // 0 = 从头播放：不 seek（服务器可能按观看记录回续播点，忽略它）
      this.pendingSeekMs = this.request.startMs > 0 ? this.request.startMs : -1;
      return;
    }
    this.pendingSeekMs = view.start_ms > 0 ? view.start_ms : -1;
  }

  /** TV 的能力申报：AVPlayer 官方口径（h264/hevc 2160、aac/mp3、mp4/mkv/ts、原生 HLS、非移动端） */
  private capability(): Capability {
    const cap: Capability = new Capability();
    const h264: VideoSupport = new VideoSupport();
    h264.codec = 'h264';
    h264.max_height = 2160;
    const h265: VideoSupport = new VideoSupport();
    h265.codec = 'hevc';
    h265.max_height = 2160;
    cap.video = [h264, h265];
    const aac: AudioSupport = new AudioSupport();
    aac.codec = 'aac';
    const mp3: AudioSupport = new AudioSupport();
    mp3.codec = 'mp3';
    cap.audio = [aac, mp3];
    cap.containers = ['mp4', 'mkv', 'ts'];
    // 杜比视界透传：AVCodec 未列 DV profile/RPU，明确报 false 让服务端走转码
    cap.hdr_passthrough = false;
    cap.is_mobile = false;
    cap.native_hls = true;
    // 同手机端：mse 必须是字符串 "full"，传 null 会 422
    cap.mse = 'full';
    return cap;
  }

  private async loadQualityMemory(): Promise<void> {
    try {
      this.maxHeight = await PlayerPrefs.quality(this.request.itemId,
        this.currentSeason, this.currentEpisode);
    } catch (error) {
      this.maxHeight = 0;
    }
  }

  private loadEpisodes(api: MovieClawApi): void {
    if (this.currentSeason <= 0 || this.currentEpisode <= 0) {
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

  // MARK: 播放器装配

  private async attachPlayer(url: string): Promise<void> {
    if (this.surfaceId.length === 0 || this.released) {
      // surface 还没就绪（视图后到）：start() 会拿着 url 再挂一次
      return;
    }
    const generation: number = ++this.attachGeneration;
    await this.releasePlayer();
    if (generation !== this.attachGeneration || this.released) {
      return;
    }
    let player: media.AVPlayer;
    try {
      player = await media.createAVPlayer();
    } catch (error) {
      if (generation !== this.attachGeneration) {
        return;
      }
      const err: BusinessError = error as BusinessError;
      this.onPlaybackFailed(`播放器引擎创建失败：${err.message ?? '未知错误'}`);
      return;
    }
    if (generation !== this.attachGeneration || this.released) {
      // 创建期间被更新的 attach 抢先：释放孤儿播放器，避免泄漏
      try {
        await player.release();
      } catch (error) {
      }
      return;
    }
    this.player = player;
    this.loadedSubtitleTrack = -1;
    this.bindPlayerEvents(player);
    player.url = url;
  }

  private bindPlayerEvents(player: media.AVPlayer): void {
    player.on('stateChange', (state: media.AVPlayerState, reason: media.StateChangeReason): void => {
      if (state === 'initialized') {
        this.armWatchdog();
        player.surfaceId = this.surfaceId;
        player.prepare();
      } else if (state === 'prepared') {
        if (player.duration > 0) {
          this.durationMs = player.duration;
        }
        // 起播位置不能在 idle 态 seek：这里才是跳续播点的地方
        if (this.pendingSeekMs > 0) {
          player.seek(this.pendingSeekMs, media.SeekMode.SEEK_CLOSEST);
          this.pendingSeekMs = -1;
        }
        player.play();
      } else if (state === 'playing') {
        this.disarmWatchdog();
        this.phase = TvPlayPhase.playing;
        this.startLoops();
        if (!this.reportedStart) {
          this.reportedStart = true;
          this.reportProgressEvent('start');
        }
      } else if (state === 'paused') {
        this.phase = TvPlayPhase.paused;
      } else if (state === 'completed') {
        this.phase = TvPlayPhase.ended;
      } else if (state === 'error') {
        this.onPlaybackFailed('播放器无法解码这一档');
      }
    });
    player.on('videoSizeChange', (width: number, height: number): void => {
      if (width > 0 && height > 0) {
        this.videoAspect = width / height;
      }
    });
    player.on('timeUpdate', (time: number): void => {
      this.positionMs = time;
    });
    player.on('subtitleUpdate', (info: media.SubtitleInfo): void => {
      this.subtitleCue = info !== undefined && info !== null
        && info.text !== undefined ? info.text : '';
    });
    player.on('bufferingUpdate', (infoType: media.BufferingInfoType, value: number): void => {
      if (infoType === media.BufferingInfoType.BUFFERING_START) {
        this.buffering = true;
      } else if (infoType === media.BufferingInfoType.BUFFERING_END) {
        this.buffering = false;
      } else if (infoType === media.BufferingInfoType.CACHED_DURATION) {
        // 已缓冲可播的毫秒数（>500ms 变化才回调）：换算成时间轴上的落点
        this.bufferedEndMs = this.positionMs + value;
      }
    });
    player.on('error', (error: BusinessError): void => {
      this.onPlaybackFailed(error.message ?? '播放器出错');
    });
  }

  private async releasePlayer(): Promise<void> {
    const player: media.AVPlayer | null = this.player;
    if (player === null) {
      return;
    }
    this.player = null;
    try {
      player.stop();
    } catch (error) {
    }
    try {
      await player.release();
    } catch (error) {
    }
  }

  // MARK: 外挂字幕轨

  /** 加载完找出字幕轨号并选中（url / fd 两种加载方式共用，同手机端 activateSubtitleTrack） */
  private async findSubtitleTrack(player: media.AVPlayer): Promise<number> {
    const tracks: media.MediaDescription[] = await player.getTrackDescription();
    let found: number = -1;
    // 这两个键是字符串字面量（'track_type' / 'track_index'），不是 media 上的常量
    for (const track of tracks) {
      const kind: Object = track['track_type'];
      if (kind !== undefined && kind !== null
        && Number(kind) === media.MediaType.MEDIA_TYPE_SUBTITLE) {
        found = Number(track['track_index']);
      }
    }
    return found;
  }

  // MARK: 进度上报 / 会话心跳

  private startLoops(): void {
    this.startReportLoop();
    this.startPingLoop();
  }

  private stopLoops(): void {
    if (this.reportTimer >= 0) {
      clearInterval(this.reportTimer);
      this.reportTimer = -1;
    }
    this.stopPingLoop();
  }

  /** 每 10 秒报一次进度（服务端据此维护续播点 / 「继续观看」） */
  private startReportLoop(): void {
    if (this.reportTimer >= 0) {
      return;
    }
    this.reportTimer = setInterval((): void => {
      if (this.reportedStart && this.positionMs > 0 && this.session !== null) {
        this.reportProgressEvent('progress');
      }
    }, 10000);
  }

  /** 15 秒一次会话心跳：200+failed=true 直接降档重开；404 = 会话被回收，原位重开 */
  private startPingLoop(): void {
    this.stopPingLoop();
    const view: PlaybackSessionView | null = this.session;
    const sessionId: string | null = view !== null ? view.session_id ?? null : null;
    if (sessionId === null || sessionId.length === 0) {
      return;
    }
    this.pingTimer = setInterval((): void => {
      const api: MovieClawApi | null = this.api();
      const current: PlaybackSessionView | null = this.session;
      const id: string | null = current !== null ? current.session_id ?? null : null;
      if (api === null || id === null || id !== sessionId) {
        this.stopPingLoop();
        return;
      }
      api.playbackSessionPing(id).then((resp: Record<string, JsonValue>): void => {
        const now: PlaybackSessionView | null = this.session;
        const nowId: string | null = now !== null ? now.session_id ?? null : null;
        if (nowId !== sessionId) {
          return;
        }
        // 本机转码起步即退：这一档放不了，直接降档，不用等 25 秒看门狗
        if (jsonBoolValue(resp['failed']) === true) {
          const tier: number | null = now !== null ? now.decision.tier ?? null : null;
          if (tier !== null && this.failedTiers.indexOf(tier) < 0) {
            this.failedTiers.push(tier);
          }
          this.retryCount = 0;
          this.stopPingLoop();
          this.renegotiate(this.positionMs > 0 ? this.positionMs : null);
        }
      }).catch((error: Object): void => {
        // 404 = 会话没了（超时回收）：原位重开；断网 / 5xx 不能据此判定
        if (!(error instanceof ApiError) || error.status !== 404) {
          return;
        }
        const currentView: PlaybackSessionView | null = this.session;
        const currentId: string | null = currentView !== null ? currentView.session_id ?? null : null;
        if (currentId !== sessionId) {
          return;
        }
        this.stopPingLoop();
        this.renegotiate(this.positionMs > 0 ? this.positionMs : null);
      });
    }, 15000);
  }

  private stopPingLoop(): void {
    if (this.pingTimer >= 0) {
      clearInterval(this.pingTimer);
      this.pingTimer = -1;
    }
  }

  /** 上报观看进度（start / progress / stop 同一入口）；响应 ended_by_admin 原地停下 */
  private reportProgressEvent(event: string): void {
    const api: MovieClawApi | null = this.api();
    const view: PlaybackSessionView | null = this.session;
    if (api === null || view === null) {
      return;
    }
    const body: ProgressRequest = new ProgressRequest();
    body.media_item_id = this.request.itemId;
    body.season_number = this.currentSeason > 0 ? this.currentSeason : null;
    body.episode_number = this.currentEpisode > 0 ? this.currentEpisode : null;
    body.event = event;
    body.position_ms = event === 'start' ? null : this.positionMs;
    // 音轨只报用户点选的（报了会被当成用户选择记下）
    body.audio_track = this.selectedAudioRef.length > 0 ? this.selectedAudioRef : null;
    body.subtitle_track = this.subtitleTouched
      ? (this.selectedSubtitleIndex < 0 ? 'off' : this.subtitleRefOf(this.selectedSubtitleIndex)) : null;
    body.file_id = view.decision.file_id ?? null;
    body.paused = event === 'progress' ? this.phase !== TvPlayPhase.playing : null;
    api.playbackProgress(body).then((state: PlaybackStateView): void => {
      // 管理员在活动页结束了本次播放：原地停下并说明
      if (!state.ended_by_admin || this.phase === TvPlayPhase.error || this.released) {
        return;
      }
      this.pause();
      this.stopLoops();
      this.fail('管理员已结束本次播放', '可以回到详情页重新开始播放', 'admin');
    }).catch((): void => {
    });
  }

  private subtitleRefOf(index: number): string {
    const plans: SubtitlePlanView[] = this.subtitlePlans();
    if (index < 0 || index >= plans.length) {
      return '';
    }
    return plans[index].track_ref;
  }

  /** 显式收掉转码会话（换流 / 换集 / 退出都要，不然服务端会一直转） */
  private stopSession(): void {
    const view: PlaybackSessionView | null = this.session;
    this.session = null;
    if (view === null) {
      return;
    }
    const api: MovieClawApi | null = this.api();
    const sessionId: string | null = view.session_id ?? null;
    if (api === null || sessionId === null || sessionId.length === 0) {
      return;
    }
    api.playbackSessionStop(sessionId).catch((): void => {
    });
  }

  // MARK: 看门狗 / 失败降档

  /** 起播看门狗：25 秒还没出画就判这一档失败，走降档回路 */
  private armWatchdog(): void {
    this.disarmWatchdog();
    this.watchdog = setInterval((): void => {
      this.disarmWatchdog();
      this.onPlaybackFailed('这一档等了 25 秒还没出画（服务端可能没产出分片）');
    }, 25000);
  }

  private disarmWatchdog(): void {
    if (this.watchdog >= 0) {
      clearInterval(this.watchdog);
      this.watchdog = -1;
    }
  }

  /**
   * 这一档放不了：把失败档位报回服务端再要一次（运行期降档回路），
   * 只重试一次；再失败进错误态（归因给到页面的错误弹窗）。
   */
  private onPlaybackFailed(reason: string): void {
    this.disarmWatchdog();
    if (this.released) {
      return;
    }
    // 降档窗口内连发的 error 只处理一次（stateChange('error') 与 on('error') 会连发）
    if (this.failureInFlight) {
      return;
    }
    const view: PlaybackSessionView | null = this.session;
    const tier: number = view !== null ? view.decision.tier ?? -1 : -1;
    if (tier >= 0 && this.retryCount < 1) {
      this.failureInFlight = true;
      this.retryCount += 1;
      this.failedTiers.push(tier);
      this.buffering = false;
      this.subtitleCue = '';
      this.renegotiate(this.positionMs > 0 ? this.positionMs : null);
      return;
    }
    const suggestion: string = view !== null ? view.decision.suggestion ?? '' : '';
    this.fail(reason, suggestion.length > 0 ? suggestion : '可以点「重试」再试一次；反复出现请稍后再看',
      'decode');
  }

  private fail(message: string, suggestion: string, kind: string): void {
    this.disarmWatchdog();
    this.stopLoops();
    this.phase = TvPlayPhase.error;
    this.errorMessage = message;
    this.errorSuggestion = suggestion;
    this.errorKind = kind;
    this.buffering = false;
  }

  /** 把请求失败归到 network / session（页面的错误弹窗按它给行动建议） */
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
 * 起播协调（playback-first）：按下播放先建引擎并预协商（不等播放器视图），
 * 播放器页面出现时 adopt() 接管正在协商的引擎；退出时 end() 整体收尾。
 */
export class TvPlayback {
  private static engine: TvAvPlayerEngine | null = null;

  static begin(request: TvPlayRequest): TvAvPlayerEngine {
    hilog.info(0x0000, 'DbgFlow', 'PLAYBACK_BEGIN item=%{public}d', request.itemId);
    TvPlayback.end();
    const engine: TvAvPlayerEngine = new TvAvPlayerEngine(request);
    TvPlayback.engine = engine;
    engine.prepare();
    return engine;
  }

  static adopt(): TvAvPlayerEngine | null {
    hilog.info(0x0000, 'DbgFlow', 'PLAYBACK_ADOPT engine=%{public}s', `${TvPlayback.engine !== null}`);
    return TvPlayback.engine;
  }

  static end(): void {
    hilog.info(0x0000, 'DbgFlow', 'PLAYBACK_END');
    const engine: TvAvPlayerEngine | null = TvPlayback.engine;
    TvPlayback.engine = null;
    if (engine !== null) {
      engine.release();
    }
  }
}
