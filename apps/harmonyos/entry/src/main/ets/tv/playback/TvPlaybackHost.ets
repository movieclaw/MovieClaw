/**
 * TV 设备播放宿主（@ObservedV2）：统一双内核（AVPlayer + libmpv）+ HDR Vivid / Audio Vivid 直通
 * + PGS 图形字幕 .sup 旁挂 + ASS 原生特效字幕 + 章节 / 倍速 / 字幕同步偏移 + 实时链路诊断。
 *
 * 暴露与原 TvAvPlayerEngine 完全超集兼容的 @Trace 状态与命令方法，并通过静态 TvPlayback
 * 协调跨页预协商（按下播放即协商，播放页挂载时 adopt 接管，退出时 end 幂等释放）。
 */
import { preferences } from '@kit.ArkData';
import { Context, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  PlaybackController,
  PlaybackGuard,
  PlaybackIntent,
  PlaybackOwnership,
  PlaybackSessionCoordinator,
  PlaybackSnapshot,
  SkipSegments,
  SubtitleCue,
  TrackPreference,
  assToSrt,
  parseSubtitleCues,
  subtitleCueTextAt
} from '@movieclaw/playback';
import { DefaultEngineFactory, EngineEvent, EngineFailure } from '@movieclaw/player-engine';
import { AppModel } from '../../common/AppModel';
import { ContinuationBridge } from '../../common/ContinuationBridge';
import { ImageUrls } from '../../common/ImageUrls';
import { PlayRequest } from '../../playback/PlayRequest';
import { ApiError } from '../../api/ApiClient';
import { MovieClawApi } from '../../api/Endpoints';
import {
  AudioTrackView,
  ClientCapabilityIn,
  EpisodeView,
  PlaybackChapterMarkView,
  PlaybackDecisionView,
  PlaybackDiagnosticsView,
  PlaybackItemView,
  PlaybackPolicyView,
  PlaybackSegmentView,
  PlaybackSessionRequest,
  PlaybackSessionView,
  PlaybackStateView,
  SeasonEpisodesView,
  SubtitlePlanView
} from '../../api/Models';
import { PlayerPrefs, SubStyle } from '../../player/PlayerPrefs';
import { DeviceCapability } from '../../playback/DeviceCapability';
import { MovieClawPlaybackGateway } from '../../playback/MovieClawPlaybackGateway';
import { MpvTrust } from '../../playback/MpvTrust';
import { PgsPrepareGuard, PgsPrepareTracker } from '../../playback/PgsPrepareGuard';
import {
  DownloadedSubtitle,
  PgsSidecarCache,
  PhoneMedia,
  downloadPgsSidecar,
  playbackUrl,
  readSubtitleTextFile,
  removePgsSidecar
} from '../../playback/PhoneMedia';
import { TvCarPlaybackSession } from '../../playback/TvCarPlaybackSession';
import { OfflineDisk } from '../../offline/OfflineDisk';
import { OfflinePlaybackSpec, OfflineProgress, OfflineUnit } from '../../offline/OfflineModels';
import { OfflineStore } from '../../offline/OfflineStore';
import { OfflineSubtitleSync } from '../../offline/OfflineSubtitleSync';
import { OfflineViewingRecorder } from '../../offline/OfflineViewings';

export { PlayRequest };
export { SkipSegments as TvSkipSegments };

/** 播放阶段 */
export class TvPlayPhase {
  static readonly idle: string = 'idle';
  static readonly negotiating: string = 'negotiating';
  static readonly playing: string = 'playing';
  static readonly paused: string = 'paused';
  static readonly ended: string = 'ended';
  static readonly consent: string = 'consent';
  static readonly error: string = 'error';
}

export { TvPlayPhase as PlayPhase };

class TvSessionRequest implements PlaybackSessionRequest {
  file_id?: number | null;
  media_item_id?: number | null;
  season_number?: number | null;
  episode_number?: number | null;
  capability: ClientCapabilityIn = DeviceCapability.forProfile(DeviceCapability.tv(''), 'avplayer');
  failed_tiers?: number[] | null;
  audio_track?: string | null;
  subtitle_track?: string | null;
  max_height?: number | null;
  start_ms?: number | null;
  client?: string | null;
}

const HLS_ALIGN_TOLERANCE_MS: number = 4000;
const HLS_REOPEN_BUDGET: number = 2;

@ObservedV2
export class TvPlaybackHost {
  static appContext: Context | null = null;
  private static deviceStore: preferences.Preferences | null = null;

  @Trace phase: string = TvPlayPhase.idle;
  @Trace errorMessage: string = '';
  @Trace errorSuggestion: string = '';
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
  @Trace engineName: string = '';

  // —— 字幕样式 / 同步偏移 / 原生 ASS 特效 ——
  @Trace subFontScale: number = 5.4;
  @Trace subBottom: number = 9;
  @Trace subBackground: boolean = true;
  @Trace subNativeAss: boolean = true;
  @Trace subDelayMs: number = 0;

  // —— HDR Vivid / Audio Vivid / 实时解码诊断 ——
  @Trace dynamicRange: string = '';
  @Trace posterUrl: string = '';
  @Trace engineHwdec: string = '';
  @Trace engineCodec: string = '';
  @Trace enginePixel: string = '';
  @Trace engineWidth: number = 0;
  @Trace engineHeight: number = 0;
  @Trace diag: PlaybackDiagnosticsView | null = null;

  // —— Surface 代际（AVPlayer 降级 MPV 时自动重建 XComponent 换新 Surface）——
  surfaceController: XComponentController = new XComponentController();
  @Trace surfaceGeneration: number = 0;
  /** 车机行车音频锁：false 时隐藏视频表面、保留音频链路不断音 */
  @Trace videoSurfaceVisible: boolean = true;
  surfaceWaiter: ((surface: string) => void) | null = null;
  surfaceId: string = '';

  readonly request: PlayRequest;
  readonly clientKind: string;
  private controller: PlaybackController = new PlaybackController(
    new DefaultEngineFactory(MpvTrust.caBundlePath())
  );
  private sessionCoordinator: PlaybackSessionCoordinator = new PlaybackSessionCoordinator();
  private sessionEpoch: number = 0;
  private deviceId: string = '';
  private pendingSeekMs: number = -1;
  private currentStartMs: number | null = null;
  private subtitleTouched: boolean = false;
  private audioPicked: boolean = false;
  private failedTiers: number[] = [];
  private retryCount: number = 0;
  private hlsReopenBudget: number = HLS_REOPEN_BUDGET;
  private currentFileId: number | null = null;
  private startOverrideConsumed: boolean = false;
  private prepared: boolean = false;
  private released: boolean = false;
  private reopening: boolean = false;
  private pausedIntent: boolean = false;
  private timeBucket: number = -1;

  private guard: PlaybackGuard | null = null;
  private playing: boolean = false;

  // —— PGS 图形字幕与 AVPlayer 自绘文本字幕 ——
  private pgsSidecarFile: PgsSidecarCache | null = null;
  private pgsPreparing: PgsPrepareTracker = new PgsPrepareTracker();
  private pgsPrepareSeq: number = 0;
  private avpSubtitleCues: SubtitleCue[] | null = null;
  private avpSubtitleOriginMs: number = 0;

  // —— 本机离线副本 ——
  private localUnit: OfflineUnit | null = null;
  private localSpec: OfflinePlaybackSpec | null = null;
  private localMediaPath: string = '';
  private viewingRecorder: OfflineViewingRecorder | null = null;
  private awaitedOfflineStore: boolean = false;
  private localFailedOnce: boolean = false;
  private localFallingBack: boolean = false;

  private diagTimer: number = -1;

  constructor(request: PlayRequest, clientKind: string = DeviceCapability.tvClient) {
    this.request = request;
    this.clientKind = clientKind;
    this.currentSeason = request.seasonNumber ?? 0;
    this.currentEpisode = request.episodeNumber ?? 0;
    this.currentFileId = request.fileId ?? null;
    this.bindController();
    PlayerPrefs.subtitleStyle().then((style: SubStyle): void => {
      if (this.released) {
        return;
      }
      this.subFontScale = style.fontScale;
      this.subBottom = style.bottomPercent;
      this.subBackground = style.background;
      this.subNativeAss = style.nativeAss;
      style.delayMs = this.subDelayMs;
      this.controller.setSubtitleStyle(style);
    }).catch((): void => {
    });
  }

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

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

  /** 兼容旧视图直接传 surfaceId 启动 */
  start(surfaceId: string): void {
    if (surfaceId.length === 0 || this.released) {
      return;
    }
    if (surfaceId === this.surfaceId && this.controller.current().phase !== 'idle') {
      return;
    }
    this.surfaceId = surfaceId;
    if (this.surfaceWaiter !== null) {
      const ready: (surface: string) => void = this.surfaceWaiter;
      this.surfaceWaiter = null;
      ready(surfaceId);
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
    const url: string | null = view !== null ? (view.stream_url ?? null) : null;
    if (url !== null && url.length > 0) {
      this.attachPlayer(url).catch((): void => {
      });
    }
  }

  surfaceReady(generation: number): void {
    if (generation !== this.surfaceGeneration || this.released) {
      return;
    }
    const surface: string = this.surfaceController.getXComponentSurfaceId();
    this.start(surface);
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

  release(): void {
    if (this.released) {
      return;
    }
    this.released = true;
    ++this.sessionEpoch;
    this.stopDiagnostics();
    ContinuationBridge.shared().clearActive();
    if (this.pgsSidecarFile !== null) {
      removePgsSidecar(this.pgsSidecarFile.path);
      this.pgsSidecarFile = null;
    }
    this.pgsPreparing.reset();
    const waiter: ((surface: string) => void) | null = this.surfaceWaiter;
    this.surfaceWaiter = null;
    if (waiter !== null) {
      waiter('');
    }
    PlaybackOwnership.release(this);
    const guard: PlaybackGuard | null = this.guard;
    this.guard = null;
    if (guard !== null) {
      guard.stop().catch((): void => {
      });
    }
    this.releasePlayer().then((): void => {
      this.stopSession();
    }).catch((): void => {
      this.stopSession();
    });
    this.phase = TvPlayPhase.idle;
    this.buffering = false;
    this.subtitleCue = '';
  }

  private ensureGuard(): PlaybackGuard | null {
    if (this.guard !== null) {
      return this.guard;
    }
    const context: Context | null = TvPlaybackHost.appContext;
    if (context === null) {
      return null;
    }
    const guard: PlaybackGuard = new PlaybackGuard(
      context as common.UIAbilityContext,
      (): void => {
        this.resume();
      },
      (): void => {
        this.pause();
      },
      (posMs: number): void => {
        this.seekTo(posMs);
      }
    );
    guard.setEpisodeCommands(
      (): void => {
        this.playPrevious();
      },
      (): void => {
        this.playNext();
      }
    );
    this.guard = guard;
    return guard;
  }

  private bindController(): void {
    this.controller.onSurfaceReset = async (): Promise<string> => {
      if (this.released) {
        return '';
      }
      this.surfaceId = '';
      this.surfaceController = new XComponentController();
      const ready: Promise<string> = new Promise<string>((resolve: (s: string) => void): void => {
        this.surfaceWaiter = resolve;
      });
      this.surfaceGeneration++;
      return ready;
    };

    this.controller.onSeekOutsideWindow = (posMs: number): void => {
      this.reopenAt(posMs);
    };

    this.sessionCoordinator.onHealth = (health: string): void => {
      if (this.released || this.reopening) {
        return;
      }
      if (health === 'endedByAdmin') {
        this.pause();
        this.fail('管理员已结束本次播放', '如有疑问请联系家庭服务器管理员', 'admin');
        this.sessionCoordinator.close();
        this.releasePlayer().catch((): void => {
        });
        return;
      }
      if (health === 'failed') {
        const tier: number = this.session?.decision.tier ?? -1;
        if (tier >= 0 && !this.failedTiers.includes(tier)) {
          this.failedTiers.push(tier);
        }
        if (this.failedTiers.length >= 5) {
          this.fail('服务器所有播放方案均失败', '请稍后重试或检查服务器转码设置', 'session');
          this.sessionCoordinator.close();
          return;
        }
      }
      this.reopenAt(this.positionMs > 0 ? this.positionMs : null);
    };

    this.controller.onSnapshot = (snapshot: PlaybackSnapshot): void => {
      if (this.released) {
        return;
      }
      this.engineName = snapshot.engine;
      this.tickAvpSubtitle(snapshot);

      const previousPlaying: boolean = this.playing;
      this.playing = snapshot.playing;
      if (snapshot.durationMs > 0) {
        this.durationMs = snapshot.durationMs;
      }

      if (snapshot.phase === 'opening') {
        if (this.phase !== TvPlayPhase.consent && this.phase !== TvPlayPhase.error) {
          this.phase = TvPlayPhase.negotiating;
        }
      } else if (snapshot.phase === 'ended') {
        this.phase = TvPlayPhase.ended;
        this.buffering = false;
        this.viewingRecorder?.finish(snapshot.positionMs, true);
      } else if (snapshot.playing) {
        this.phase = TvPlayPhase.playing;
      } else if (snapshot.phase === 'ready' || snapshot.phase === 'paused') {
        if (this.phase !== TvPlayPhase.consent && this.phase !== TvPlayPhase.error) {
          this.phase = TvPlayPhase.paused;
        }
      }

      if (Math.floor(snapshot.positionMs / 500) !== this.timeBucket) {
        this.positionMs = snapshot.positionMs;
        this.timeBucket = Math.floor(snapshot.positionMs / 500);
        if (this.request.itemId > 0) {
          ContinuationBridge.shared().publishPlayback(
            AppModel.origin(),
            this.request.itemId,
            this.session?.decision.file_id ?? (this.currentFileId ?? 0),
            this.currentSeason,
            this.currentEpisode,
            (): number => this.positionMs,
            this.request.title,
            this.request.libraryId
          );
        }
      }

      this.viewingRecorder?.tick(snapshot.positionMs, snapshot.playing, snapshot.durationMs);
      this.sessionCoordinator.update(
        snapshot.positionMs,
        snapshot.durationMs,
        snapshot.playing,
        this.activeAudioRef(),
        this.subtitleRefOf(this.selectedSubtitleIndex)
      );

      if (snapshot.playing && !previousPlaying) {
        const g: PlaybackGuard | null = this.ensureGuard();
        if (g !== null) {
          g.start(this.request.title || '播放').catch((): void => {
          });
        }
      } else if (!snapshot.playing && previousPlaying) {
        this.guard?.pause().catch((): void => {
        });
      }
      this.guard?.updatePlayback(
        this.request.title,
        snapshot.durationMs,
        snapshot.positionMs,
        snapshot.playing,
        snapshot.rate
      );
    };

    this.controller.onEvent = (event: EngineEvent): void => {
      if (this.released) {
        return;
      }
      if (event.type === 'buffered') {
        this.bufferedEndMs = event.bufferedMs;
      } else if (event.type === 'buffering') {
        this.buffering = event.active;
      } else if (event.type === 'firstFrame') {
        this.buffering = false;
      } else if (event.type === 'size' && event.width > 0 && event.height > 0) {
        this.videoAspect = event.width / event.height;
        this.engineWidth = event.width;
        this.engineHeight = event.height;
      } else if (event.type === 'decode') {
        this.engineHwdec = event.hwdec;
        this.engineCodec = event.codec;
        this.enginePixel = event.pixelFormat;
        this.engineWidth = event.width;
        this.engineHeight = event.height;
      } else if (event.type === 'subtitle') {
        this.subtitleCue = event.text;
      }
    };

    this.controller.onFailure = (failure: EngineFailure): void => {
      if (this.released) {
        return;
      }
      if (this.localUnit !== null) {
        if (failure.canFallback() || failure.kind === 'source') {
          this.onPlaybackFailed(failure.message);
        } else {
          this.fail(failure.message, '', 'decode');
          this.sessionCoordinator.close();
        }
        return;
      }
      if (failure.kind === 'unavailable' || failure.kind === 'internal') {
        this.fail(failure.message.length > 0 ? failure.message : '播放内核初始化失败', '', 'decode');
        this.sessionCoordinator.close();
        return;
      }
      this.onPlaybackFailed(failure.message);
    };
  }

  // MARK: 协商与起播

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
    this.phase = TvPlayPhase.negotiating;
    this.buffering = true;
    this.errorMessage = '';
    this.errorSuggestion = '';
    this.errorKind = '';

    if (!this.localFailedOnce) {
      try {
        if (await this.tryStartLocal(epoch)) {
          return;
        }
      } catch (_err) {
        if (epoch !== this.sessionEpoch || this.released) {
          return;
        }
        this.stopSession();
        this.localFailedOnce = true;
      }
    }

    const api: MovieClawApi | null = this.api();
    if (api === null) {
      this.fail('未连接服务器', '请检查智慧屏网络连接后重试', 'network');
      return;
    }

    let startOverride: number | null = null;
    if (this.currentStartMs !== null) {
      startOverride = this.currentStartMs;
      this.currentStartMs = null;
    } else if (!this.startOverrideConsumed && this.request.startMs !== null) {
      this.startOverrideConsumed = true;
      startOverride = this.request.startMs;
    }

    try {
      const body: TvSessionRequest = new TvSessionRequest();
      body.media_item_id = this.request.itemId;
      body.file_id = this.currentFileId !== null && this.currentFileId > 0 ? this.currentFileId : null;
      body.season_number = this.currentSeason > 0 ? this.currentSeason : 0;
      body.episode_number = this.currentEpisode > 0 ? this.currentEpisode : 0;
      body.start_ms = startOverride;
      body.client = this.clientKind;
      body.audio_track = this.selectedAudioRef.length > 0 ? this.selectedAudioRef : null;
      if (this.subtitleTouched) {
        body.subtitle_track = this.selectedSubtitleIndex < 0
          ? 'off'
          : this.subtitleRefOf(this.selectedSubtitleIndex);
      } else {
        body.subtitle_track = null;
      }
      body.max_height = this.maxHeight > 0 ? this.maxHeight : null;
      body.failed_tiers = this.failedTiers;

      await PlayerPrefs.loadEngine();
      const profile = this.clientKind === DeviceCapability.carClient
        ? DeviceCapability.car(this.deviceId)
        : DeviceCapability.tv(this.deviceId);
      const gateway: MovieClawPlaybackGateway = new MovieClawPlaybackGateway(
        api,
        '',
        (eng: string, pgs: boolean): ClientCapabilityIn => DeviceCapability.forProfile(profile, eng, pgs)
      );
      const view: PlaybackSessionView = await gateway.open(body, PlayerPrefs.engine(), true);
      if (epoch !== this.sessionEpoch || this.released) {
        await gateway.stop(view);
        return;
      }

      this.session = view;
      this.dynamicRange = view.decision.video?.dynamic_range ?? '';
      this.reclaimPgsSidecarIfFileChanged(view);

      if (this.selectedAudioRef.length === 0) {
        this.selectedAudioRef = view.watch?.audio_track || view.decision.audio?.track_ref || '';
        this.audioPicked = false;
      }
      if (!this.subtitleTouched) {
        const rememberedSub: string = view.watch?.subtitle_track ?? '';
        let subIdx: number = rememberedSub.length > 0 && rememberedSub !== 'off'
          ? view.decision.subtitles.findIndex((t: SubtitlePlanView): boolean => t.track_ref === rememberedSub)
          : -1;
        const pinnedAvp: boolean = PlayerPrefs.engine() === 'avplayer';
        if (subIdx >= 0 && pinnedAvp && view.decision.subtitles[subIdx].kind === 'pgs') {
          subIdx = -1;
        }
        if (subIdx < 0 && rememberedSub !== 'off') {
          subIdx = view.decision.subtitles.findIndex((t: SubtitlePlanView): boolean =>
            t.is_default && !(pinnedAvp && t.kind === 'pgs'));
        }
        this.selectedSubtitleIndex = subIdx;
      }

      if (view.decision.outcome === 'consent') {
        this.phase = TvPlayPhase.consent;
        this.buffering = false;
        return;
      }

      const url: string | null = view.stream_url ?? null;
      if (url === null || url.length === 0) {
        gateway.stop(view).catch((): void => {
        });
        this.fail(
          view.decision.reason.length > 0 ? view.decision.reason : '服务端没有给出可播放的地址',
          view.decision.suggestion ?? '',
          'session'
        );
        return;
      }

      this.sessionCoordinator.bind(
        new TvCarPlaybackSession(
          api,
          view,
          this.request.itemId,
          view.decision.file_id ?? (this.currentFileId ?? 0),
          this.currentSeason,
          this.currentEpisode,
          this.clientKind,
          this.deviceId
        )
      );
      this.pendingSeekMs = startOverride !== null && startOverride > 0
        ? startOverride
        : (view.start_ms > 0 ? view.start_ms : -1);
      this.loadArtwork();
      this.loadEpisodes();
      await this.attachPlayer(url);
    } catch (error) {
      if (epoch !== this.sessionEpoch || this.released) {
        return;
      }
      this.failFromError(error as Object, '起播协商失败');
    }
  }

  private reopenAt(posMs: number | null): void {
    if (this.released || this.reopening) {
      return;
    }
    this.reopening = true;
    this.currentStartMs = posMs;
    this.releasePlayer().then(async (): Promise<void> => {
      this.stopSession();
      await this.negotiate();
      this.reopening = false;
    }).catch((): void => {
      this.reopening = false;
    });
  }

  private nativeEmbeddedOrdinalFor(enginePref: string): number | null {
    const view: PlaybackSessionView | null = this.session;
    if (enginePref !== 'mpv' || view === null || (view.decision.tier ?? 0) !== 0) {
      return null;
    }
    const plans: SubtitlePlanView[] = view.decision.subtitles;
    if (this.selectedSubtitleIndex < 0 || this.selectedSubtitleIndex >= plans.length) {
      return null;
    }
    const target: SubtitlePlanView = plans[this.selectedSubtitleIndex];
    if (!target.track_ref.startsWith('embedded:')) {
      return null;
    }
    let ordinal: number = 0;
    for (let i: number = 0; i < this.selectedSubtitleIndex; i++) {
      if (plans[i].track_ref.startsWith('embedded:')) {
        ordinal++;
      }
    }
    return ordinal;
  }

  private async attachPlayer(url: string): Promise<void> {
    if (this.surfaceId.length === 0 || this.released) {
      return;
    }
    const view: PlaybackSessionView | null = this.session;
    if (view === null) {
      return;
    }
    const plans: SubtitlePlanView[] = view.decision.subtitles;
    const burnedRef: string = this.burnedSubtitleRef();
    const currentRef: string = this.selectedSubtitleIndex >= 0 && this.selectedSubtitleIndex < plans.length
      ? plans[this.selectedSubtitleIndex].track_ref : '';
    const currentKind: string = this.selectedSubtitleIndex >= 0 && this.selectedSubtitleIndex < plans.length
      ? plans[this.selectedSubtitleIndex].kind : '';
    const pgsRender: boolean = currentKind === 'pgs' && currentRef !== burnedRef;
    const assNativeRender: boolean = currentKind === 'ass' && this.subNativeAss && currentRef !== burnedRef;
    const enginePref: string = (pgsRender || assNativeRender) ? 'mpv' : PlayerPrefs.engine();
    const nativeOrdinal: number | null = this.nativeEmbeddedOrdinalFor(enginePref);
    const subtitleUrl: string = nativeOrdinal === null && this.selectedSubtitleIndex >= 0
      && this.selectedSubtitleIndex < view.subtitle_urls.length
      && currentRef !== burnedRef && currentKind !== 'pgs'
      ? playbackUrl(AppModel.origin(), view.subtitle_urls[this.selectedSubtitleIndex])
      : '';

    let pgsPath: string = '';
    if (pgsRender && nativeOrdinal === null && this.pgsSidecarFile !== null
      && this.pgsSidecarFile.fileId === (view.decision.file_id ?? 0)
      && this.pgsSidecarFile.ref === currentRef) {
      pgsPath = this.pgsSidecarFile.path;
    }

    const isHls: boolean = (view.decision.tier ?? 0) > 0;
    const stallSamples: number = !isHls && (view.source?.on_drive ?? false) ? 0 : 6;
    const origin: number = view.timeline === 'file' || !isHls ? 0 : view.start_ms;
    const desiredMs: number = this.pendingSeekMs > 0 ? this.pendingSeekMs : view.start_ms;

    if (enginePref !== 'mpv' && isHls && Math.abs(desiredMs - view.start_ms) > HLS_ALIGN_TOLERANCE_MS
      && this.hlsReopenBudget > 0) {
      this.hlsReopenBudget--;
      this.reopenAt(desiredMs);
      return;
    }

    const intent: PlaybackIntent = this.makeIntent(enginePref);
    this.resetAvpSubtitleCues();
    if (enginePref !== 'mpv' && subtitleUrl.length > 0) {
      this.prepareAvpSidecarCues(subtitleUrl, origin).catch((): void => {
      });
    }

    const openUrl: string = enginePref !== 'mpv' && isHls
      ? (url.indexOf('?') >= 0 ? `${url}&from=start` : `${url}?from=start`)
      : url;

    await this.controller.open(
      new PhoneMedia(
        origin,
        view.watch?.duration_ms ?? 0,
        playbackUrl(AppModel.origin(), openUrl),
        '',
        subtitleUrl,
        pgsPath,
        this.cacheDirectory(),
        isHls,
        `file:${view.decision.file_id ?? 0}`,
        stallSamples
      ),
      this.surfaceId,
      intent,
      enginePref
    );

    if (pgsRender && nativeOrdinal === null && pgsPath.length === 0
      && this.selectedSubtitleIndex >= 0 && this.selectedSubtitleIndex < view.subtitle_urls.length) {
      this.preparePgsSidecar(
        playbackUrl(AppModel.origin(), view.subtitle_urls[this.selectedSubtitleIndex]),
        view.decision.file_id ?? 0,
        currentRef
      ).catch((): void => {
      });
    }
  }

  private makeIntent(engine: string = PlayerPrefs.engine()): PlaybackIntent {
    const intent: PlaybackIntent = new PlaybackIntent();
    intent.positionMs = this.pendingSeekMs >= 0 ? this.pendingSeekMs : (this.session?.start_ms ?? 0);
    this.pendingSeekMs = -1;
    const alignView: PlaybackSessionView | null = this.session;
    if (engine !== 'mpv' && alignView !== null && (alignView.decision.tier ?? 0) > 0
      && Math.abs(intent.positionMs - alignView.start_ms) <= HLS_ALIGN_TOLERANCE_MS) {
      intent.positionMs = alignView.start_ms;
      this.hlsReopenBudget = HLS_REOPEN_BUDGET;
    }
    intent.paused = this.pausedIntent;
    intent.rate = this.playbackSpeed;
    intent.subtitlesOff = this.selectedSubtitleIndex < 0;
    const subtitleOrdinal: number | null = this.nativeEmbeddedOrdinalFor(engine);
    if (subtitleOrdinal !== null) {
      intent.subtitle = { language: '', title: '', ordinal: subtitleOrdinal };
    }
    const tracks: AudioTrackView[] = this.session?.decision.audio_tracks ?? [];
    const index: number = tracks.findIndex((t: AudioTrackView): boolean => t.ref === this.selectedAudioRef);
    if (index >= 0 && (this.localSpec !== null || this.session?.decision.tier === 0)) {
      const pref: TrackPreference = {
        language: tracks[index].language ?? '',
        title: '',
        ordinal: index,
        sourceCount: tracks.length,
        explicit: this.audioPicked
      };
      intent.audio = pref;
    }
    return intent;
  }

  private async preparePgsSidecar(url: string, fileId: number, ref: string): Promise<void> {
    const key: string = `${fileId}:${ref}`;
    const sessionView: PlaybackSessionView | null = this.session;
    if (sessionView === null || !this.pgsPreparing.canStart(key, this.sessionEpoch, sessionView)) {
      return;
    }
    const seq: number = ++this.pgsPrepareSeq;
    const guard: PgsPrepareGuard = new PgsPrepareGuard(seq, this.sessionEpoch, sessionView, ref);
    this.pgsPreparing.begin(key, guard);
    try {
      const path: string = await downloadPgsSidecar(url, this.cacheDirectory());
      const outcome: string = guard.outcome(
        this.pgsPrepareSeq,
        this.sessionEpoch,
        this.released,
        this.session,
        this.selectedSubtitleIndex
      );
      if (outcome === PgsPrepareGuard.outcomeDiscard) {
        removePgsSidecar(path);
        return;
      }
      const previous: PgsSidecarCache | null = this.pgsSidecarFile;
      if (previous !== null && previous.path !== path) {
        removePgsSidecar(previous.path);
      }
      this.pgsSidecarFile = { fileId: fileId, ref: ref, path: path };
      if (outcome === PgsPrepareGuard.outcomeRemount && this.localSpec === null
        && (sessionView.stream_url ?? '').length > 0) {
        if (this.controller.current().engine === 'mpv' && this.controller.current().phase !== 'idle') {
          const origin: number = sessionView.timeline === 'file' || sessionView.decision.tier === 0
            ? 0 : sessionView.start_ms;
          await this.controller.attachSubtitle({
            url: '',
            fd: -1,
            length: 0,
            subtitleUrl: '',
            subtitleFd: -1,
            subtitlePath: path,
            subtitleFormat: 'sup',
            subtitleOffsetMs: origin
          });
        } else {
          this.pendingSeekMs = this.positionMs;
          await this.attachPlayer(sessionView.stream_url ?? '');
        }
      }
    } catch (_err) {
    } finally {
      this.pgsPreparing.end(guard);
    }
  }

  private reclaimPgsSidecarIfFileChanged(view: PlaybackSessionView): void {
    const sidecar: PgsSidecarCache | null = this.pgsSidecarFile;
    if (sidecar !== null && sidecar.fileId !== (view.decision.file_id ?? 0)) {
      this.pgsSidecarFile = null;
      removePgsSidecar(sidecar.path);
    }
  }

  private resetAvpSubtitleCues(): void {
    if (this.avpSubtitleCues !== null) {
      this.subtitleCue = '';
    }
    this.avpSubtitleCues = null;
    this.avpSubtitleOriginMs = 0;
  }

  private async prepareAvpSidecarCues(url: string, originMs: number): Promise<void> {
    const epoch: number = this.sessionEpoch;
    try {
      const mediaObj: PhoneMedia = new PhoneMedia(originMs, 0, '', '', url, '', this.cacheDirectory());
      const sidecar: DownloadedSubtitle = await mediaObj.downloadSidecar('avplayer');
      const text: string = readSubtitleTextFile(sidecar.path);
      removePgsSidecar(sidecar.path);
      if (epoch !== this.sessionEpoch || this.released) {
        return;
      }
      const cues: SubtitleCue[] = parseSubtitleCues(text);
      if (cues.length > 0) {
        this.avpSubtitleCues = cues;
        this.avpSubtitleOriginMs = originMs;
      }
    } catch (_err) {
    }
  }

  private parseLocalSubtitleCues(path: string): void {
    const text: string = readSubtitleTextFile(path);
    if (text.length === 0) {
      return;
    }
    const lower: string = path.toLowerCase();
    const normalized: string = lower.endsWith('.ass') || lower.endsWith('.ssa') ? assToSrt(text) : text;
    const cues: SubtitleCue[] = parseSubtitleCues(normalized);
    if (cues.length > 0) {
      this.avpSubtitleCues = cues;
      this.avpSubtitleOriginMs = 0;
    }
  }

  private tickAvpSubtitle(snapshot: PlaybackSnapshot): void {
    const cues: SubtitleCue[] | null = this.avpSubtitleCues;
    if (cues === null || snapshot.engine !== 'avplayer') {
      return;
    }
    const text: string = subtitleCueTextAt(cues, snapshot.positionMs - this.avpSubtitleOriginMs - this.subDelayMs);
    if (text !== this.subtitleCue) {
      this.subtitleCue = text;
    }
  }

  private async releasePlayer(): Promise<void> {
    this.resetAvpSubtitleCues();
    await this.controller.release();
    this.engineHwdec = '';
    this.engineCodec = '';
    this.enginePixel = '';
    this.engineWidth = 0;
    this.engineHeight = 0;
  }

  // MARK: 传输控制与音画调校

  pause(): void {
    this.pausedIntent = true;
    this.controller.pause();
  }

  resume(): void {
    PlaybackOwnership.claim(this, (): void => {
      this.pause();
    });
    this.pausedIntent = false;
    this.controller.play();
  }

  togglePlay(): void {
    if (this.phase === TvPlayPhase.playing) {
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

  seekBy(deltaMs: number): void {
    this.seekTo(this.positionMs + deltaMs);
  }

  setPlaybackSpeed(rate: number): void {
    if (rate <= 0) {
      return;
    }
    this.playbackSpeed = rate;
    this.controller.setRate(rate);
  }

  adjustSubtitleFont(delta: number): void {
    this.subFontScale = Math.min(9.0, Math.max(3.2, Math.round((this.subFontScale + delta) * 10) / 10));
    this.syncSubtitleStyle(true);
  }

  adjustSubtitleDelay(deltaMs: number): void {
    this.subDelayMs = Math.max(-30000, Math.min(30000, this.subDelayMs + deltaMs));
    this.syncSubtitleStyle(false);
    this.tickAvpSubtitle(this.controller.current());
  }

  resetSubtitleDelay(): void {
    if (this.subDelayMs === 0) {
      return;
    }
    this.subDelayMs = 0;
    this.syncSubtitleStyle(false);
    this.tickAvpSubtitle(this.controller.current());
  }

  subDelayLabel(): string {
    if (this.subDelayMs === 0) {
      return '0.0s';
    }
    const sec: string = (Math.abs(this.subDelayMs) / 1000).toFixed(1);
    return this.subDelayMs > 0 ? `+${sec}s` : `-${sec}s`;
  }

  toggleNativeAss(): void {
    this.subNativeAss = !this.subNativeAss;
    this.syncSubtitleStyle(true);
    const view: PlaybackSessionView | null = this.session;
    const plans: SubtitlePlanView[] = view?.decision.subtitles ?? [];
    if (this.subNativeAss && this.selectedSubtitleIndex >= 0 && this.selectedSubtitleIndex < plans.length
      && plans[this.selectedSubtitleIndex].kind === 'ass' && this.controller.current().engine !== 'mpv'
      && view !== null && (view.stream_url ?? '').length > 0) {
      this.pendingSeekMs = this.positionMs;
      this.attachPlayer(view.stream_url ?? '').catch((): void => {
      });
    }
  }

  private syncSubtitleStyle(persist: boolean): void {
    const style: SubStyle = new SubStyle();
    style.fontScale = this.subFontScale;
    style.bottomPercent = this.subBottom;
    style.background = this.subBackground;
    style.nativeAss = this.subNativeAss;
    style.delayMs = this.subDelayMs;
    if (persist) {
      PlayerPrefs.writeSubtitleStyle(style);
    }
    this.controller.setSubtitleStyle(style);
  }

  async selectSubtitle(index: number): Promise<void> {
    const view: PlaybackSessionView | null = this.session;
    if (view === null) {
      return;
    }
    this.subtitleTouched = true;
    if (this.localSpec !== null) {
      this.selectedSubtitleIndex = index;
      this.subtitleCue = '';
      this.pendingSeekMs = this.positionMs;
      await this.attachLocalPlayer();
      return;
    }
    if (index < 0) {
      this.selectedSubtitleIndex = -1;
      this.subtitleCue = '';
      this.resetAvpSubtitleCues();
      if (this.burnedSubtitleRef().length > 0) {
        this.reopenAt(this.positionMs > 0 ? this.positionMs : null);
        return;
      }
      await this.controller.selectTrack('subtitle', null);
      return;
    }
    const plans: SubtitlePlanView[] = view.decision.subtitles;
    if (index >= plans.length) {
      return;
    }
    if (plans[index].track_ref === this.burnedSubtitleRef()) {
      this.selectedSubtitleIndex = index;
      this.subtitleCue = '';
      this.resetAvpSubtitleCues();
      await this.controller.selectTrack('subtitle', null);
      return;
    }
    const sidecar: boolean = this.burnedSubtitleRef().length === 0
      && ((index < view.subtitle_urls.length && view.subtitle_urls[index].length > 0)
        || (view.decision.tier === 0 && plans[index].track_ref.startsWith('embedded:')));
    this.selectedSubtitleIndex = index;
    this.subtitleCue = '';
    if (!sidecar) {
      this.reopenAt(this.positionMs > 0 ? this.positionMs : null);
      return;
    }
    this.pendingSeekMs = this.positionMs;
    await this.attachPlayer(view.stream_url ?? '');
  }

  selectAudio(ref: string): void {
    const view: PlaybackSessionView | null = this.session;
    if (view === null || ref.length === 0 || ref === this.activeAudioRef()) {
      return;
    }
    this.selectedAudioRef = ref;
    this.audioPicked = true;
    const tracks: AudioTrackView[] = view.decision.audio_tracks;
    const index: number = tracks.findIndex((t: AudioTrackView): boolean => t.ref === ref);
    if (index >= 0 && (this.localSpec !== null || view.decision.tier === 0)) {
      this.controller.selectTrack('audio', {
        language: tracks[index].language ?? '',
        title: '',
        ordinal: index,
        sourceCount: tracks.length,
        explicit: true
      });
      return;
    }
    this.failedTiers = [];
    this.retryCount = 0;
    this.reopenAt(this.positionMs > 0 ? this.positionMs : null);
  }

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
    if (this.localUnit !== null) {
      return;
    }
    this.failedTiers = [];
    this.retryCount = 0;
    this.reopenAt(this.positionMs > 0 ? this.positionMs : null);
  }

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

  enginePreference(): string {
    return PlayerPrefs.engine();
  }

  retry(): void {
    this.failedTiers = [];
    this.retryCount = 0;
    this.reopenAt(this.positionMs > 0 ? this.positionMs : null);
  }

  async grantConsent(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.consentSaving) {
      return;
    }
    this.consentSaving = true;
    try {
      const policy: PlaybackPolicyView = await api.playbackPolicySet({ software_transcode_enabled: true });
      this.consentSaving = false;
      if (policy.software_transcode_enabled === true) {
        await this.negotiate();
      }
    } catch (_err) {
      this.consentSaving = false;
    }
  }

  // MARK: 选集与连播

  switchToEpisode(episodeNumber: number): void {
    if (episodeNumber <= 0 || episodeNumber === this.currentEpisode || this.reopening) {
      return;
    }
    let found: EpisodeView | null = null;
    for (const ep of this.episodes) {
      if (ep.episode_number === episodeNumber) {
        found = ep;
        break;
      }
    }
    if (found !== null && !found.owned) {
      return;
    }
    this.reopening = true;
    this.releasePlayer().then(async (): Promise<void> => {
      this.stopSession();
      if (this.released) {
        return;
      }
      this.pausedIntent = false;
      this.subtitleTouched = false;
      this.selectedSubtitleIndex = -1;
      this.selectedAudioRef = '';
      this.audioPicked = false;
      this.positionMs = 0;
      this.currentEpisode = episodeNumber;
      this.currentFileId = null;
      this.currentStartMs = null;
      this.failedTiers = [];
      this.retryCount = 0;
      this.localFailedOnce = false;
      this.localFallingBack = false;
      await this.negotiate();
      this.reopening = false;
    }).catch((): void => {
      this.reopening = false;
    });
  }

  nextEpisode(): EpisodeView | null {
    let best: EpisodeView | null = null;
    for (const ep of this.episodes) {
      if (ep.owned && ep.episode_number > this.currentEpisode
        && (best === null || ep.episode_number < best.episode_number)) {
        best = ep;
      }
    }
    return best;
  }

  previousEpisode(): EpisodeView | null {
    let best: EpisodeView | null = null;
    for (const ep of this.episodes) {
      if (ep.owned && ep.episode_number < this.currentEpisode
        && (best === null || ep.episode_number > best.episode_number)) {
        best = ep;
      }
    }
    return best;
  }

  playNext(): void {
    const next: EpisodeView | null = this.nextEpisode();
    if (next !== null) {
      this.switchToEpisode(next.episode_number);
    }
  }

  playPrevious(): void {
    const prev: EpisodeView | null = this.previousEpisode();
    if (prev !== null) {
      this.switchToEpisode(prev.episode_number);
    }
  }

  // MARK: 派生查询与 HDR/Audio Vivid 徽标

  subtitlePlans(): SubtitlePlanView[] {
    return this.session?.decision.subtitles ?? [];
  }

  audioTracks(): AudioTrackView[] {
    return this.session?.decision.audio_tracks ?? [];
  }

  chapters(): PlaybackChapterMarkView[] {
    return this.session?.chapters ?? [];
  }

  segments(): PlaybackSegmentView[] | null {
    return this.session?.segments ?? null;
  }

  activeSkipSegment(): PlaybackSegmentView | null {
    return SkipSegments.activeSkip(this.segments(), this.positionMs);
  }

  burnedSubtitleRef(): string {
    return this.session?.decision.video?.burn_subtitle ?? '';
  }

  activeAudioRef(): string {
    if (this.selectedAudioRef.length > 0) {
      return this.selectedAudioRef;
    }
    return this.session?.decision.audio?.track_ref ?? '';
  }

  isHdrActive(): boolean {
    const dr: string = this.dynamicRange.toLowerCase();
    if (dr.includes('vivid') || dr.includes('dolby') || dr.includes('dv')
      || dr.includes('hdr') || dr.includes('hlg')) {
      return true;
    }
    const pix: string = this.enginePixel.toLowerCase();
    return pix.includes('p010') || pix.includes('10le') || pix.includes('12le');
  }

  vividBadges(): string[] {
    const out: string[] = [];
    const dr: string = this.dynamicRange.toLowerCase();
    if (dr.includes('vivid')) {
      out.push('HDR Vivid');
    } else if (dr.includes('dolby') || dr.includes('dv')) {
      out.push('杜比视界');
    } else if (dr.includes('hdr10+')) {
      out.push('HDR10+');
    } else if (dr.includes('hlg')) {
      out.push('HLG');
    } else if (dr.includes('hdr') || this.isHdrActive()) {
      out.push('HDR10');
    }

    const activeRef: string = this.activeAudioRef();
    const tracks: AudioTrackView[] = this.audioTracks();
    for (const t of tracks) {
      if (t.ref === activeRef || tracks.length === 1) {
        const desc: string = `${t.codec ?? ''} ${t.title ?? ''}`.toLowerCase();
        if (desc.includes('av3a') || desc.includes('vivid')) {
          out.push('Audio Vivid');
        } else if (desc.includes('atmos') || desc.includes('joc')) {
          out.push('杜比全景声');
        } else if (desc.includes('dts:x') || desc.includes('dts-x')) {
          out.push('DTS:X');
        } else if ((t.channels ?? 0) >= 8) {
          out.push('7.1 环绕');
        } else if ((t.channels ?? 0) >= 6) {
          out.push('5.1 环绕');
        }
        break;
      }
    }

    if (this.engineName === 'mpv') {
      out.push(this.engineHwdec.length > 0 ? 'MPV 硬解' : 'MPV');
    }
    const plans: SubtitlePlanView[] = this.subtitlePlans();
    if (this.selectedSubtitleIndex >= 0 && this.selectedSubtitleIndex < plans.length) {
      const kind: string = plans[this.selectedSubtitleIndex].kind;
      if (kind === 'pgs' && this.engineName === 'mpv') {
        out.push('PGS 原盘图形字幕');
      } else if (kind === 'ass' && this.subNativeAss && this.engineName === 'mpv') {
        out.push('ASS 原生特效');
      }
    }
    return out;
  }

  streamTierLabel(): string {
    if (this.localUnit !== null) {
      return '本机离线直放';
    }
    const tier: number = this.session?.decision.tier ?? 0;
    const labels: string[] = ['原文件直出', '无损重封装', '容器重封装 + 音轨转换', '硬件转码', '软件转码'];
    return tier >= 0 && tier < labels.length ? labels[tier] : `第 ${tier} 档`;
  }

  decodeModeLine(): string {
    if (this.engineName.length === 0) {
      return '播放内核：待就绪';
    }
    if (this.engineName === 'mpv') {
      return this.engineHwdec.length > 0
        ? `内核：libmpv · 硬解（${this.engineHwdec}）`
        : '内核：libmpv · 软件解码';
    }
    return '内核：AVPlayer 系统硬解直通';
  }

  decodeSpecLine(): string {
    const parts: string[] = [];
    if (this.engineWidth > 0 && this.engineHeight > 0) {
      parts.push(`${this.engineWidth} × ${this.engineHeight}`);
    }
    if (this.engineCodec.length > 0) {
      parts.push(this.engineCodec.toUpperCase());
    }
    if (this.enginePixel.length > 0) {
      parts.push(this.enginePixel);
    }
    if (this.dynamicRange.length > 0) {
      parts.push(this.dynamicRange);
    }
    return parts.join(' · ');
  }

  // MARK: 实时服务端诊断轮询

  startDiagnostics(): void {
    this.stopDiagnostics();
    this.pollDiagnostics();
    this.diagTimer = setInterval((): void => {
      this.pollDiagnostics();
    }, 2000);
  }

  stopDiagnostics(): void {
    if (this.diagTimer >= 0) {
      clearInterval(this.diagTimer);
      this.diagTimer = -1;
    }
  }

  private pollDiagnostics(): void {
    const api: MovieClawApi | null = this.api();
    const sessionId: string = this.session?.session_id ?? '';
    if (api === null || sessionId.length === 0) {
      this.diag = null;
      return;
    }
    const epoch: number = this.sessionEpoch;
    api.playbackSessionDiagnostics(sessionId, this.streamToken())
      .then((snap: PlaybackDiagnosticsView): void => {
        if (epoch === this.sessionEpoch && !this.released) {
          this.diag = snap;
        }
      })
      .catch((): void => {
      });
  }

  private streamToken(): string {
    const url: string = this.session?.stream_url ?? '';
    const at: number = url.indexOf('?');
    if (at < 0) {
      return '';
    }
    const pairs: string[] = url.substring(at + 1).split('&');
    for (const pair of pairs) {
      if (pair.startsWith('token=')) {
        return decodeURIComponent(pair.substring('token='.length));
      }
    }
    return '';
  }

  // MARK: 本机离线副本与辅助

  private async tryStartLocal(epoch: number): Promise<boolean> {
    const store: OfflineStore = OfflineStore.shared;
    if (!this.awaitedOfflineStore) {
      this.awaitedOfflineStore = true;
      await store.waitUntilLoaded();
    }
    if (epoch !== this.sessionEpoch || this.released) {
      return false;
    }
    const unit: OfflineUnit | null = store.playableUnit(
      this.request.itemId,
      this.currentSeason,
      this.currentEpisode
    );
    if (unit === null) {
      return false;
    }
    const mediaPath: string | null = store.mediaPath(unit);
    if (mediaPath === null || OfflineDisk.fileSize(mediaPath) <= 0) {
      return false;
    }
    const ownerKey: string | null = store.key();
    const syncJob: Promise<void> = ownerKey !== null
      ? OfflineSubtitleSync.shared.syncWaiting(unit, ownerKey, this.api(), 2000)
      : Promise.resolve();
    const resumeJob: Promise<number> = this.localResumeMs(store, unit);
    await syncJob;
    const resumeMs: number = await resumeJob;
    if (epoch !== this.sessionEpoch || this.released) {
      return false;
    }
    const spec: OfflinePlaybackSpec | null = store.spec(unit);
    if (spec === null) {
      return false;
    }
    this.localMediaPath = mediaPath;
    this.localUnit = unit;
    this.localSpec = spec;
    this.session = this.localSessionView(spec, resumeMs);
    this.viewingRecorder = new OfflineViewingRecorder(unit, resumeMs, spec.durationMs ?? null, this.api());
    this.pendingSeekMs = resumeMs > 0 ? resumeMs : -1;
    this.loadArtwork();
    this.loadEpisodes();
    await this.attachLocalPlayer();
    return true;
  }

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
        api.playbackResume(
          this.request.itemId,
          unit.season > 0 ? unit.season : undefined,
          unit.episode > 0 ? unit.episode : undefined
        )
      );
      if (state !== null) {
        return state.played ? 0 : (state.position_ms ?? 0);
      }
    }
    const progress: OfflineProgress | null = store.localProgress(this.request.itemId, unit.season, unit.episode);
    if (progress !== null && !progress.played) {
      return progress.positionMs;
    }
    return 0;
  }

  private raceResume(promise: Promise<PlaybackStateView>): Promise<PlaybackStateView | null> {
    return new Promise<PlaybackStateView | null>((resolve: (v: PlaybackStateView | null) => void) => {
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

  private async attachLocalPlayer(): Promise<void> {
    const spec: OfflinePlaybackSpec | null = this.localSpec;
    if (this.surfaceId.length === 0 || this.released || spec === null) {
      return;
    }
    let subtitlePath: string = '';
    if (this.selectedSubtitleIndex >= 0 && this.selectedSubtitleIndex < spec.subtitles.length) {
      const directory: string = this.localMediaPath.substring(0, this.localMediaPath.lastIndexOf('/'));
      subtitlePath = `${directory}/subs/${spec.subtitles[this.selectedSubtitleIndex].fileName}`;
    }
    const enginePref: string = PlayerPrefs.engine();
    this.resetAvpSubtitleCues();
    if (enginePref !== 'mpv' && subtitlePath.length > 0) {
      this.parseLocalSubtitleCues(subtitlePath);
    }
    await this.controller.open(
      new PhoneMedia(0, spec.durationMs ?? 0, '', this.localMediaPath, '', subtitlePath, '', false,
        `local:${this.localMediaPath}`),
      this.surfaceId,
      this.makeIntent(enginePref),
      enginePref
    );
  }

  private parseAudioTracks(json: string): AudioTrackView[] {
    if (json.length === 0 || json === 'null') {
      return [];
    }
    try {
      const list: AudioTrackView[] = JSON.parse(json) as AudioTrackView[];
      return Array.isArray(list) ? list : [];
    } catch (_err) {
      return [];
    }
  }

  private parseChapters(json: string): PlaybackChapterMarkView[] {
    if (json.length === 0 || json === 'null') {
      return [];
    }
    try {
      const list: PlaybackChapterMarkView[] = JSON.parse(json) as PlaybackChapterMarkView[];
      return Array.isArray(list) ? list : [];
    } catch (_err) {
      return [];
    }
  }

  private parseSegments(json: string): PlaybackSegmentView[] | null {
    if (json.length === 0 || json === 'null') {
      return null;
    }
    try {
      const list: PlaybackSegmentView[] = JSON.parse(json) as PlaybackSegmentView[];
      return Array.isArray(list) ? list : null;
    } catch (_err) {
      return null;
    }
  }

  private stopSession(): void {
    this.sessionCoordinator.close();
    this.session = null;
    const recorder: OfflineViewingRecorder | null = this.viewingRecorder;
    this.viewingRecorder = null;
    recorder?.finish(this.positionMs, this.phase === TvPlayPhase.ended);
    this.localUnit = null;
    this.localSpec = null;
    this.localMediaPath = '';
  }

  private loadArtwork(): void {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    const epoch: number = this.sessionEpoch;
    api.playbackItemInfo(this.request.itemId)
      .then((view: PlaybackItemView): void => {
        if (epoch !== this.sessionEpoch || this.released) {
          return;
        }
        const resolved: string | null = ImageUrls.resolve(AppModel.origin(), view.poster_url ?? null, 'w500');
        this.posterUrl = resolved ?? '';
        const epSub: string = this.currentEpisode > 0
          ? `第 ${this.currentSeason} 季 · 第 ${this.currentEpisode} 集`
          : '';
        this.guard?.setArtwork(this.posterUrl.length > 0 ? this.posterUrl : null, epSub);
      })
      .catch((): void => {
      });
  }

  private loadEpisodes(): void {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.currentSeason <= 0 || this.currentEpisode <= 0) {
      this.episodes = [];
      return;
    }
    const epoch: number = this.sessionEpoch;
    api.playbackItemEpisodes(this.request.itemId, this.currentSeason)
      .then((view: SeasonEpisodesView): void => {
        if (epoch === this.sessionEpoch && !this.released) {
          this.episodes = view.episodes;
        }
      })
      .catch((): void => {
        this.episodes = [];
      });
  }

  private async loadQualityMemory(): Promise<void> {
    try {
      this.maxHeight = await PlayerPrefs.quality(
        this.request.itemId,
        this.currentSeason,
        this.currentEpisode
      );
    } catch (_err) {
      this.maxHeight = 0;
    }
  }

  private async ensureDeviceId(): Promise<void> {
    if (this.deviceId.length > 0) {
      return;
    }
    const raw: Context | null = TvPlaybackHost.appContext;
    if (raw === null) {
      return;
    }
    try {
      if (TvPlaybackHost.deviceStore === null) {
        TvPlaybackHost.deviceStore = await preferences.getPreferences(raw, 'movieclaw_tv');
      }
      this.deviceId = await TvPlaybackHost.deviceStore.get('tv.installation_id', '') as string;
    } catch (_err) {
      this.deviceId = '';
    }
  }

  private cacheDirectory(): string {
    const raw: Context | null = TvPlaybackHost.appContext;
    return raw !== null ? raw.cacheDir : '';
  }

  private subtitleRefOf(index: number): string {
    const plans: SubtitlePlanView[] = this.subtitlePlans();
    if (index < 0 || index >= plans.length) {
      return '';
    }
    return plans[index].track_ref;
  }

  private onPlaybackFailed(reason: string): void {
    if (this.reopening || this.localFallingBack) {
      return;
    }
    if (this.localUnit !== null) {
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
    const tier: number = view !== null ? (view.decision.tier ?? -1) : -1;
    if (tier >= 0 && !this.failedTiers.includes(tier)) {
      this.failedTiers.push(tier);
    }
    if (tier < 0 || this.retryCount >= 4) {
      const suggestion: string = view !== null ? (view.decision.suggestion ?? '') : '';
      this.fail(
        reason.length > 0 ? reason : '当前档位无法播放',
        suggestion.length > 0 ? suggestion : '可尝试在信息面板切换播放内核（MPV / AVPlayer）或降低画质上限',
        'decode'
      );
      this.sessionCoordinator.close();
      return;
    }
    this.retryCount++;
    this.reopenAt(this.positionMs > 0 ? this.positionMs : null);
  }

  /** 行车音频锁：隐藏/恢复视频表面，音频链路不重建、播放不中断 */
  setVideoSurfaceVisible(visible: boolean): void {
    this.videoSurfaceVisible = visible;
  }

  private fail(message: string, suggestion: string, kind: string): void {
    this.phase = TvPlayPhase.error;
    this.errorMessage = message;
    this.errorSuggestion = suggestion;
    this.errorKind = kind;
    this.buffering = false;
  }

  private failFromError(error: Object, fallback: string): void {
    if (error instanceof ApiError) {
      if (error.status === 0 || error.status === -1) {
        this.fail('连不上服务器', '请检查智慧屏网络连接后重试', 'network');
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

export { TvPlaybackHost as TvAvPlayerEngine };

/**
 * 跨页起播协调（playback-first）：按下播放立即预建宿主协商，播放器视图挂载时 adopt 接管。
 */
export class TvPlayback {
  private static host: TvPlaybackHost | null = null;

  static begin(request: PlayRequest): TvPlaybackHost {
    hilog.info(0x0000, 'MovieClawTV', 'PLAYBACK_BEGIN item=%{public}d', request.itemId);
    TvPlayback.end();
    const host: TvPlaybackHost = new TvPlaybackHost(request);
    TvPlayback.host = host;
    host.prepare().catch((): void => {
    });
    return host;
  }

  static adopt(): TvPlaybackHost | null {
    return TvPlayback.host;
  }

  static end(): void {
    const host: TvPlaybackHost | null = TvPlayback.host;
    TvPlayback.host = null;
    if (host !== null) {
      host.release();
    }
  }
}
