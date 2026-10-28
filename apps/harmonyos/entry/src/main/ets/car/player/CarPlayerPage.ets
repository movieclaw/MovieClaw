/**
 * 车机播放器页（T017，US5）：驻车全屏视频 + 行车大控件播控卡。
 *
 * - 驻车视频模式（drive.playMode = video）：XComponent 画面 + 传输条
 *   （标题 / 缓冲+已播双层进度（含可跳段标记）/ 时间；传输条可拖可点）+ 
 *   信息面板三列（字幕/音轨/画质）+ 4 秒无操作自动收起（暂停/面板/拖动常显）
 *   + 右下角情境元素（跳过片头按钮 / 「即将播放」下一集卡 + 连播倒计时）
 *   + 对话框（错误重试/返回、软件转码同意、连播满上限「还在看吗」）；
 * - 行车模式（audioLocked）：「行车中视频已锁定」大控件播控卡——
 *   大播放暂停 / 上一集 / 下一集 / 收藏圆钮 + 进度条 + 驾驶模式开关入口；
 *   视频表面隐藏（引擎 setVideoSurfaceVisible，音频链路不重建）→ 切换无黑屏；
 * - 返回分级（playerBackHandler）：取消拖动 → 收面板 → 呼出传输条 → 收下一集卡 →
 *   交还外壳（收起播放器，引擎继续播——mini 播控条承接，T019）。
 *
 * 起播是 playback-first：按下播放 CarPlayback.begin() 已预建会话（T018 接线），
 * 页面 adopt() 接管；「停止」才整体收尾（CarPlayback.end()）。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppModel } from '../../common/AppModel';
import { Formatters } from '../../common/Formatters';
import { ImageUrls } from '../../common/ImageUrls';
import { RemoteImage } from '../../common/RemoteImage';
import { MovieClawApi } from '../../api/Endpoints';
import {
  AudioTrackView,
  EpisodeView,
  PlaybackMarksRequest,
  PlaybackMarksView,
  PlaybackSegmentView,
  PlaybackAutoSkipView,
  PlaybackSessionView,
  SubtitlePlanView
} from '../../api/Models';
import { CarColors } from '../theme/CarTheme';
import { CarMetrics } from '../theme/CarTheme';
import { CarType } from '../theme/CarTheme';
import { CarMotion } from '../theme/CarTheme';
import { CarPlayRequest, CarUiState } from '../model/CarUiState';
import { CarAvPlayerEngine, CarPlayback, CarPlayPhase, CarSkipSegments } from './CarAvPlayerEngine';
import { CarFormat, CarPillButton, CarPressable } from '../components/CarCards';

/** 画质选项（信息面板画质列；maxHeight 是上限语义：源不超就直通） */
class CarQualityOption {
  readonly label: string;
  readonly maxHeight: number;
  readonly hint: string;

  constructor(label: string, maxHeight: number, hint: string) {
    this.label = label;
    this.maxHeight = maxHeight;
    this.hint = hint;
  }

  static all(): CarQualityOption[] {
    return [
      new CarQualityOption('自动（原画优先）', 0, '按源画质直通'),
      new CarQualityOption('2160p', 2160, '4K 超高清'),
      new CarQualityOption('1080p', 1080, '全高清'),
      new CarQualityOption('720p', 720, '高清'),
      new CarQualityOption('480p', 480, '标清')
    ];
  }
}

/** 信息面板的一行选项：触控行 ≥48vp，选中打勾 + 亮底，点选即生效 */
@ComponentV2
struct CarPanelRow {
  @Param label: string = '';
  @Param detail: string = '';
  @Param active: boolean = false;
  @Param onPick: (() => void) | null = null;

  build() {
    CarPressable({
      onActivate: (): void => {
        const cb = this.onPick;
        if (cb !== null) {
          cb();
        }
      }
    }) {
      Row({ space: 14 }) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor([CarColors.text])
          .width(24)
          .opacity(this.active ? 1 : 0)
        Column({ space: 3 }) {
          Text(this.label)
            .fontSize(CarType.body)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.active ? CarColors.text : CarColors.textMuted)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.detail.length > 0) {
            Text(this.detail)
              .fontSize(CarType.footnote)
              .fontColor(CarColors.textFaint)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .constraintSize({ minHeight: CarMetrics.minTouch })
      .padding({ left: 18, right: 18, top: 10, bottom: 10 })
      .borderRadius(12)
      .backgroundColor(this.active ? CarColors.accentSoft : Color.Transparent)
      .border({ width: this.active ? 1 : 0, color: CarColors.activeRing })
    }
  }
}

/** 播控卡上的大圆钮（行车卡主控件）：直径 ≥72，filled = 亮底黑图标 */
@ComponentV2
struct CarRoundButton {
  @Param symbol: Resource | null = null;
  @Param filled: boolean = false;
  @Param disabled: boolean = false;
  @Param diameter: number = 88;
  @Param onActivate: (() => void) | null = null;

  build() {
    CarPressable({
      onActivate: (): void => {
        if (this.disabled) {
          return;
        }
        const cb = this.onActivate;
        if (cb !== null) {
          cb();
        }
      }
    }) {
      Stack() {
        if (this.symbol !== null) {
          SymbolGlyph(this.symbol)
            .fontSize(Math.floor(this.diameter * 0.42))
            .fontColor([this.filled ? CarColors.bg : CarColors.text])
        }
      }
      .width(this.diameter)
      .height(this.diameter)
      .borderRadius(this.diameter / 2)
      .backgroundColor(this.filled ? CarColors.text : CarColors.surfaceRaised)
      .border({ width: this.filled ? 0 : 1, color: CarColors.lineStrong })
      .opacity(this.disabled ? 0.35 : 1)
    }
  }
}

@ComponentV2
export struct CarPlayerPage {
  @Local ui: CarUiState = CarUiState.shared;
  @Local engine: CarAvPlayerEngine | null = null;
  /** 传输条可见性；CarMotion.chromeHideMs 无操作自动收起 */
  @Local chromeVisible: boolean = true;
  /** 信息面板（字幕/音轨/画质）打开 */
  @Local panelOpen: boolean = false;
  /** 自动连播倒计时 0~1（卡片眉标给秒数） */
  @Local autoNextProgress: number = 0;
  /** 无人值守的连续连播计数（满上限弹「还在看吗」） */
  @Local autoNextStreak: number = 0;
  /** 「观看片尾」按过：这集不再倒计时（播完卡片会再出来） */
  @Local autoNextCancelled: boolean = false;
  /** 下一集卡收起 */
  @Local nextDismissed: boolean = false;
  /** 传输条拖动落点（毫秒）；-1 = 没在拖。松手才真正跳（HLS 途中跟随会打爆转码器） */
  @Local scrubMs: number = -1;
  /** 当前单元（整部片或当前一集）的收藏态 */
  @Local favorite: boolean = false;
  @Local favoriteBusy: boolean = false;

  private pageWidth: number = 0;
  private pageHeight: number = 0;
  /** 传输条轨道宽（拖动/点击换算用） */
  private trackWidth: number = 0;
  private surfaceId: string = '';
  private surfaceController: XComponentController = new XComponentController();
  private chromeTimer: number = -1;
  private clockTimer: number = -1;
  private scrubBase: number = 0;
  /** 自动跳过总开关（随会话下发；旧服务端没有该字段时默认开） */
  private autoSkipEnabled: boolean = true;
  /** 本集已决定过的段起点：自然播进去自动跳一次，拖回去只给按钮 */
  private skipHandled: number[] = [];
  private skipHandledEpisode: number = 0;
  /** 已同步过的会话标识（换会话/换集时重取随会话下发的开关） */
  private lastSessionId: string = '';
  /** 收藏态属于哪一集（-1 = 整部片）；换集重拉 */
  private favoriteEpisode: number = -1;

  aboutToAppear(): void {
    hilog.info(0x0000, 'CarFlow', 'PLAYER_PAGE_APPEAR');
    const request: CarPlayRequest | null = this.ui.playerRequest;
    const adopted: CarAvPlayerEngine | null = CarPlayback.adopt();
    if (adopted !== null) {
      this.engine = adopted;
    } else if (request !== null) {
      // 兜底：视图比 begin 先挂（异常路径）——就地建引擎并预协商
      this.engine = CarPlayback.begin(request);
    }
    this.ui.playerBackHandler = (): boolean => this.handleBack();
    this.startClock();
    this.showChrome();
    this.syncDriveSurface();
  }

  aboutToDisappear(): void {
    hilog.info(0x0000, 'CarFlow', 'PLAYER_PAGE_DISAPPEAR');
    this.ui.playerBackHandler = null;
    this.scrubMs = -1;
    if (this.chromeTimer >= 0) {
      clearTimeout(this.chromeTimer);
      this.chromeTimer = -1;
    }
    if (this.clockTimer >= 0) {
      clearInterval(this.clockTimer);
      this.clockTimer = -1;
    }
    // 引擎不收尾：收起播放器后音频继续（mini 播控条承接，T019）；「停止」才 end()
    this.engine = null;
  }

  /** 引擎非空断言：aboutToAppear 先于 build，页面挂起时引擎一定就位 */
  private eng(): CarAvPlayerEngine {
    return this.engine as CarAvPlayerEngine;
  }

  // MARK: - 驾驶模式联动（无黑屏切换）

  /** 播放模式变化 → 引擎视频表面显隐（音频链路不重建） */
  @Monitor('ui.drive.playMode')
  onDriveModeChange(): void {
    this.syncDriveSurface();
  }

  private syncDriveSurface(): void {
    const engine: CarAvPlayerEngine | null = this.engine;
    if (engine !== null) {
      engine.setVideoSurfaceVisible(!this.ui.drive.isAudioLocked());
    }
  }

  /** 行车锁（大控件播控卡）视图 */
  private audioLocked(): boolean {
    return this.ui.drive.isAudioLocked();
  }

  // MARK: - chrome 显隐

  private chromeMustStay(): boolean {
    const engine: CarAvPlayerEngine | null = this.engine;
    if (engine === null) {
      return true;
    }
    // 暂停时用户在找进度；面板开着；拖动中
    return engine.phase === CarPlayPhase.paused || this.panelOpen || this.scrubMs >= 0;
  }

  private showChrome(): void {
    this.chromeVisible = true;
    if (this.chromeTimer >= 0) {
      clearTimeout(this.chromeTimer);
    }
    this.chromeTimer = setTimeout((): void => {
      this.chromeTimer = -1;
      if (!this.chromeMustStay()) {
        this.chromeVisible = false;
      }
    }, CarMotion.chromeHideMs);
  }

  // MARK: - 传输命令

  private togglePlay(): void {
    this.noteUserActivity();
    this.eng().togglePlay();
    this.showChrome();
  }

  private runPlayNext(): void {
    this.noteUserActivity();
    this.eng().playNext();
    this.resetUpNextState();
    this.showChrome();
  }

  /** 换到上一集（本季有在位文件的最近一集；没有不动） */
  private runPlayPrev(): void {
    const prev: EpisodeView | null = this.prevEpisode();
    if (prev === null) {
      return;
    }
    this.noteUserActivity();
    this.skipHandled = [];
    this.eng().switchToEpisode(prev.episode_number);
    this.resetUpNextState();
    this.showChrome();
  }

  /** 本季上一集（有在位文件的最近一集，缺集跳过）；没有返回 null */
  private prevEpisode(): EpisodeView | null {
    const engine: CarAvPlayerEngine | null = this.engine;
    if (engine === null || engine.currentSeason <= 0 || engine.currentEpisode <= 0) {
      return null;
    }
    let best: EpisodeView | null = null;
    for (const episode of engine.episodes) {
      if (episode.owned && episode.episode_number < engine.currentEpisode
        && (best === null || episode.episode_number > best.episode_number)) {
        best = episode;
      }
    }
    return best;
  }

  /** 收起下一集卡接着放片尾（播完卡片会再出来） */
  private dismissUpNext(): void {
    this.noteUserActivity();
    this.nextDismissed = true;
    this.autoNextCancelled = true;
  }

  private doSkip(segment: PlaybackSegmentView): void {
    this.noteUserActivity();
    this.eng().seekTo(segment.end_ms);
    this.showChrome();
    // 手动跳过片头 = 这部剧「学过」了：告诉服务端，以后自动跳过
    if (segment.type === 'intro') {
      const api: MovieClawApi | null = AppModel.shared.api;
      const request: CarPlayRequest | null = this.ui.playerRequest;
      if (api !== null && request !== null) {
        api.playbackAutoSkipIntroSet(request.itemId, true).catch((): void => {
        });
      }
    }
  }

  /** 收起播放器（引擎继续播，mini 条承接） */
  private minimizePlayer(): void {
    this.ui.closePlayer();
  }

  /** 停止播放并退出：引擎整体收尾 */
  private exitPlayer(): void {
    CarPlayback.end();
    this.resetMini();
    this.ui.closePlayer();
  }

  private resetMini(): void {
    this.ui.mini.playing = false;
    this.ui.mini.hasNext = false;
  }

  // MARK: - 收藏（行车播控卡）

  private isMovieUnit(): boolean {
    const engine: CarAvPlayerEngine | null = this.engine;
    return engine === null || engine.currentSeason <= 0 || engine.currentEpisode <= 0;
  }

  private async loadFavorite(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    const engine: CarAvPlayerEngine | null = this.engine;
    const request: CarPlayRequest | null = this.ui.playerRequest;
    if (api === null || engine === null || request === null) {
      return;
    }
    const movie: boolean = this.isMovieUnit();
    try {
      const marks: PlaybackMarksView = movie
        ? await api.playbackMarksGet(request.itemId)
        : await api.playbackMarksGet(request.itemId, engine.currentSeason, engine.currentEpisode);
      this.favorite = marks.is_favorite === true;
      this.favoriteEpisode = movie ? -1 : engine.currentEpisode;
    } catch (error) {
      this.favorite = false;
    }
  }

  private async toggleFavorite(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    const engine: CarAvPlayerEngine | null = this.engine;
    const request: CarPlayRequest | null = this.ui.playerRequest;
    if (api === null || engine === null || request === null || this.favoriteBusy) {
      return;
    }
    this.favoriteBusy = true;
    const movie: boolean = this.isMovieUnit();
    const body: PlaybackMarksRequest = {
      media_item_id: request.itemId,
      season_number: movie ? null : engine.currentSeason,
      episode_number: movie ? null : engine.currentEpisode,
      favorite: !this.favorite
    };
    try {
      await api.playbackMarksSet(body);
      this.favorite = !this.favorite;
    } catch (error) {
    } finally {
      this.favoriteBusy = false;
    }
  }

  // MARK: - 信息面板

  private openPanel(): void {
    const engine: CarAvPlayerEngine | null = this.engine;
    if (engine === null || engine.session === null || this.isModal()) {
      return;
    }
    this.panelOpen = true;
    this.showChrome();
  }

  private closePanel(): void {
    this.panelOpen = false;
    this.showChrome();
  }

  private pickSubtitle(index: number): void {
    this.eng().selectSubtitle(index);
    this.showChrome();
  }

  private pickAudio(ref: string): void {
    this.eng().selectAudio(ref);
    this.showChrome();
  }

  private pickQuality(maxHeight: number): void {
    this.eng().switchQuality(maxHeight);
    this.showChrome();
  }

  // MARK: - 情境状态判定

  private isModal(): boolean {
    const engine: CarAvPlayerEngine | null = this.engine;
    if (engine === null) {
      return false;
    }
    return engine.phase === CarPlayPhase.error || engine.phase === CarPlayPhase.consent
      || this.asksStillWatching();
  }

  /** 连播满上限后放完：不自动接，问一句「还在看吗」 */
  private asksStillWatching(): boolean {
    const engine: CarAvPlayerEngine | null = this.engine;
    const request: CarPlayRequest | null = this.ui.playerRequest;
    if (engine === null || request === null || !request.autoAdvance) {
      return false;
    }
    return engine.phase === CarPlayPhase.ended && engine.nextEpisode() !== null
      && this.autoNextStreak >= CarSkipSegments.autoNextMaxStreak;
  }

  /** 「即将播放」卡片可不可见（对话框占着时不给；「观看片尾」按过收起） */
  private showsUpNext(): boolean {
    const engine: CarAvPlayerEngine | null = this.engine;
    if (engine === null || this.isModal() || this.nextDismissed) {
      return false;
    }
    if (engine.nextEpisode() === null) {
      return false;
    }
    return CarSkipSegments.shouldShowUpNext(engine.segments(), engine.positionMs,
      engine.phase === CarPlayPhase.ended);
  }

  /** 卡片要不要倒计时自动播下一集（连播关了不倒计时；满上限不倒计时） */
  private autoNextArmed(): boolean {
    const engine: CarAvPlayerEngine | null = this.engine;
    const request: CarPlayRequest | null = this.ui.playerRequest;
    if (engine === null || request === null || !request.autoAdvance) {
      return false;
    }
    if (!this.showsUpNext() || this.autoNextCancelled) {
      return false;
    }
    return CarSkipSegments.autoNextArmed(engine.segments(), engine.positionMs,
      this.autoNextStreak, engine.phase === CarPlayPhase.ended);
  }

  /** 右下角当前该显示的「跳过」段（无 = null） */
  private activeSkipSeg(): PlaybackSegmentView | null {
    const engine: CarAvPlayerEngine | null = this.engine;
    return engine !== null ? engine.activeSkipSegment() : null;
  }

  private busyVisible(): boolean {
    const engine: CarAvPlayerEngine | null = this.engine;
    if (engine === null || this.isModal()) {
      return false;
    }
    return engine.phase === CarPlayPhase.negotiating
      || (engine.buffering && (engine.phase === CarPlayPhase.playing
        || engine.phase === CarPlayPhase.paused));
  }

  private busyLabel(): string {
    const engine: CarAvPlayerEngine | null = this.engine;
    if (engine !== null && engine.phase === CarPlayPhase.negotiating) {
      return '正在打开…';
    }
    return '正在缓冲…';
  }

  // MARK: - 自动连播 / 自动跳过节拍（100ms 钟）

  private startClock(): void {
    if (this.clockTimer >= 0) {
      return;
    }
    this.clockTimer = setInterval((): void => {
      this.syncSessionFlags();
      this.evaluateAutoSkip();
      this.tickAutoNext();
      this.syncMini();
    }, 100);
  }

  /** 换会话/换集：随会话下发的自动跳过开关、本集跳过记账、收藏态重拉 */
  private syncSessionFlags(): void {
    const engine: CarAvPlayerEngine | null = this.engine;
    const view: PlaybackSessionView | null = engine !== null ? engine.session : null;
    const id: string = view !== null
      ? `${view.session_id ?? ''}@${view.decision.file_id ?? 0}`
      : '';
    if (id !== this.lastSessionId) {
      this.lastSessionId = id;
      const auto: PlaybackAutoSkipView | null = view !== null ? view.auto_skip ?? null : null;
      this.autoSkipEnabled = auto !== null ? auto.enabled : true;
    }
    if (engine === null) {
      return;
    }
    if (engine.currentEpisode !== this.skipHandledEpisode) {
      this.skipHandledEpisode = engine.currentEpisode;
      this.skipHandled = [];
    }
    const movie: boolean = this.isMovieUnit();
    const unitKey: number = movie ? -1 : engine.currentEpisode;
    if (unitKey !== this.favoriteEpisode) {
      this.loadFavorite();
    }
  }

  /**
   * 自动跳过片头/广告/预告：自然播进区间就跳到区间尾。
   * 每段只自动跳一次——用户拖回去重看时只保留「跳过」按钮，不再硬拽。
   */
  private evaluateAutoSkip(): void {
    const engine: CarAvPlayerEngine | null = this.engine;
    if (engine === null || this.panelOpen || this.scrubMs >= 0 || this.isModal()) {
      return;
    }
    if (engine.phase !== CarPlayPhase.playing) {
      return;
    }
    const segment: PlaybackSegmentView | null = this.activeSkipSeg();
    if (segment === null || this.skipHandled.includes(segment.start_ms)) {
      return;
    }
    this.skipHandled.push(segment.start_ms);
    if (!this.autoSkipEnabled) {
      return;
    }
    hilog.info(0x0000, 'CarFlow', 'AUTO_SKIP type=%{public}s start=%{public}d',
      segment.type, segment.start_ms);
    engine.seekTo(segment.end_ms);
    this.showChrome();
  }

  private tickAutoNext(): void {
    const engine: CarAvPlayerEngine | null = this.engine;
    if (engine === null) {
      return;
    }
    if (!this.autoNextArmed()) {
      this.autoNextProgress = 0;
      return;
    }
    // 暂停时不走；播完照走（片尾短于倒计时时不能卡在最后一帧）
    if (engine.phase !== CarPlayPhase.playing && engine.phase !== CarPlayPhase.ended) {
      return;
    }
    this.autoNextProgress = Math.min(1,
      this.autoNextProgress + 100 / CarSkipSegments.autoNextMs);
    if (this.autoNextProgress < 1) {
      return;
    }
    this.autoNextProgress = 0;
    this.autoNextStreak += 1;
    engine.playNext();
    this.resetUpNextState();
  }

  /** mini 播控条状态同步（条体渲染以引擎实时态为准，这里给静态摘要） */
  private syncMini(): void {
    const engine: CarAvPlayerEngine | null = this.engine;
    const request: CarPlayRequest | null = this.ui.playerRequest;
    if (engine === null || request === null) {
      return;
    }
    this.ui.mini.title = request.title;
    this.ui.mini.subtitle = this.episodeLine() ?? '';
    this.ui.mini.coverUrl = request.coverUrl;
    this.ui.mini.playing = engine.phase === CarPlayPhase.playing;
    this.ui.mini.hasNext = engine.nextEpisode() !== null;
  }

  private noteUserActivity(): void {
    this.autoNextStreak = 0;
  }

  private resetUpNextState(): void {
    this.autoNextProgress = 0;
    this.autoNextCancelled = false;
    this.nextDismissed = false;
  }

  // MARK: - 返回分级（CarUiState.handleBack 委托）

  private handleBack(): boolean {
    this.noteUserActivity();
    if (this.scrubMs >= 0) {
      // 拖动中按返回：丢掉落点回原处（画面没动过）
      this.scrubMs = -1;
      return true;
    }
    if (this.panelOpen) {
      this.closePanel();
      return true;
    }
    if (!this.chromeVisible) {
      // 传输条收着：先呼出（再按才收起播放器）
      this.showChrome();
      return true;
    }
    if (this.showsUpNext()) {
      // 卡片在时返回 = 「观看片尾」，免得一按就退出播放
      this.dismissUpNext();
      return true;
    }
    return false;
  }

  // MARK: - 文案与数据助手

  private titleLine(): string {
    const request: CarPlayRequest | null = this.ui.playerRequest;
    const base: string = request !== null ? request.title : '播放';
    const engine: CarAvPlayerEngine | null = this.engine;
    if (engine !== null && engine.currentSeason > 0 && engine.currentEpisode > 0) {
      return `${base} · 第 ${engine.currentSeason} 季第 ${engine.currentEpisode} 集`;
    }
    return base;
  }

  /** 当前集的集数行（mini 条副标题/播控卡副标题共用） */
  private episodeLine(): string | null {
    const engine: CarAvPlayerEngine | null = this.engine;
    if (engine === null || engine.currentSeason <= 0 || engine.currentEpisode <= 0) {
      return null;
    }
    let name: string | null = null;
    for (const episode of engine.episodes) {
      if (episode.episode_number === engine.currentEpisode) {
        name = episode.name ?? null;
        break;
      }
    }
    return CarFormat.episodeLine(engine.currentSeason, engine.currentEpisode, name);
  }

  private subtitlePlansList(): SubtitlePlanView[] {
    const engine: CarAvPlayerEngine | null = this.engine;
    return engine !== null ? engine.subtitlePlans() : [];
  }

  private audioTracksList(): AudioTrackView[] {
    const engine: CarAvPlayerEngine | null = this.engine;
    return engine !== null ? engine.audioTracks() : [];
  }

  /** 「关闭」行打勾条件：没选任何外挂轨且当前流没烧录字幕 */
  private subtitleOffActive(): boolean {
    const engine: CarAvPlayerEngine | null = this.engine;
    return engine !== null && engine.selectedSubtitleIndex < 0
      && engine.burnedSubtitleRef().length === 0;
  }

  private subtitleActiveAt(index: number): boolean {
    const engine: CarAvPlayerEngine | null = this.engine;
    if (engine === null) {
      return false;
    }
    if (engine.selectedSubtitleIndex === index) {
      return true;
    }
    // 没碰过字幕时：流里烧录的那条算选中（画面对勾与实际一致）
    if (engine.selectedSubtitleIndex < 0) {
      const plans: SubtitlePlanView[] = engine.subtitlePlans();
      const burned: string = engine.burnedSubtitleRef();
      return index < plans.length && burned.length > 0 && plans[index].track_ref === burned;
    }
    return false;
  }

  private subtitleLabel(plan: SubtitlePlanView): string {
    if (plan.title !== null && plan.title !== undefined && plan.title.length > 0) {
      return plan.title;
    }
    if (plan.language !== null && plan.language !== undefined && plan.language.length > 0) {
      return plan.language;
    }
    return plan.track_ref;
  }

  private subtitleDetail(plan: SubtitlePlanView): string {
    const parts: string[] = [];
    const hasTitle: boolean = plan.title !== null && plan.title !== undefined
      && plan.title.length > 0;
    if (hasTitle && plan.language !== null && plan.language !== undefined
      && plan.language.length > 0) {
      parts.push(plan.language);
    }
    if (plan.is_default) {
      parts.push('默认');
    }
    if (plan.is_ai) {
      parts.push('AI');
    }
    if (plan.is_forced) {
      parts.push('强制');
    }
    return parts.join(' · ');
  }

  private audioLabel(track: AudioTrackView): string {
    if (track.language !== null && track.language !== undefined && track.language.length > 0) {
      return track.language;
    }
    if (track.codec !== null && track.codec !== undefined && track.codec.length > 0) {
      return track.codec.toUpperCase();
    }
    return track.ref;
  }

  private audioDetail(track: AudioTrackView): string {
    const parts: string[] = [];
    if (track.codec !== null && track.codec !== undefined && track.codec.length > 0) {
      parts.push(track.codec.toUpperCase());
    }
    if (track.channels !== null && track.channels !== undefined && track.channels > 0) {
      parts.push(`${track.channels} 声道`);
    }
    if (track.is_default) {
      parts.push('默认');
    }
    return parts.join(' · ');
  }

  private skipLabel(segment: PlaybackSegmentView): string {
    if (segment.type === 'intro') {
      return '跳过片头';
    }
    if (segment.type === 'outro') {
      return '跳过片尾';
    }
    if (segment.type === 'ad') {
      return '跳过广告';
    }
    if (segment.type === 'preview') {
      return '跳过预告';
    }
    return '跳过';
  }

  private upNextEyebrow(): string {
    if (!this.autoNextArmed()) {
      return '下一集';
    }
    const left: number = CarSkipSegments.autoNextMs * (1 - this.autoNextProgress) / 1000;
    return `即将播放 · ${Math.max(1, Math.ceil(left))} 秒`;
  }

  private upNextStillUrl(next: EpisodeView): string {
    const resolved: string | null = ImageUrls.resolve(AppModel.origin(),
      next.still_url ?? null, null);
    return resolved !== null ? resolved : '';
  }

  private consentMessage(): string {
    const engine: CarAvPlayerEngine | null = this.engine;
    if (engine === null) {
      return '';
    }
    const view = engine.session;
    if (view !== null) {
      const suggestion: string | null = view.decision.suggestion ?? null;
      if (suggestion !== null && suggestion.length > 0) {
        return suggestion;
      }
      if (view.decision.reason.length > 0) {
        return view.decision.reason;
      }
    }
    return '服务器没有可用的硬件转码，需要开启软件转码后才能播放这一档。';
  }

  private stillWatchingTitle(): string {
    const request: CarPlayRequest | null = this.ui.playerRequest;
    const title: string = request !== null ? request.title : '这部影片';
    return `还在看《${title}》吗？`;
  }

  // MARK: - 进度条取值（拖动中一律读落点）

  /** 时间轴上的「当前位置」：拖动中 = 落点，平时 = 播放位置 */
  private timelineMs(): number {
    const engine: CarAvPlayerEngine | null = this.engine;
    if (this.scrubMs >= 0) {
      return this.scrubMs;
    }
    return engine !== null ? engine.positionMs : 0;
  }

  private playedPct(): string {
    const engine: CarAvPlayerEngine | null = this.engine;
    if (engine === null || engine.durationMs <= 0) {
      return '0%';
    }
    const fraction: number = Math.max(0, Math.min(1, this.timelineMs() / engine.durationMs));
    return `${(fraction * 100).toFixed(2)}%`;
  }

  private bufferedPct(): string {
    const engine: CarAvPlayerEngine | null = this.engine;
    if (engine === null || engine.durationMs <= 0 || engine.bufferedEndMs <= 0) {
      return '0%';
    }
    const fraction: number = Math.max(0, Math.min(1, engine.bufferedEndMs / engine.durationMs));
    return `${(fraction * 100).toFixed(2)}%`;
  }

  /** 可跳段（片头/片尾）在进度条上的亮条（拖动时一眼看出哪截是片头） */
  private segmentPct(segment: PlaybackSegmentView): string {
    const engine: CarAvPlayerEngine | null = this.engine;
    if (engine === null || engine.durationMs <= 0) {
      return '0%';
    }
    const from: number = Math.max(0, Math.min(engine.durationMs, segment.start_ms));
    const to: number = Math.max(0, Math.min(engine.durationMs, segment.end_ms));
    const fraction: number = Math.max(0, (to - from) / engine.durationMs);
    return `${(fraction * 100).toFixed(2)}%`;
  }

  private segmentLeftPct(segment: PlaybackSegmentView): string {
    const engine: CarAvPlayerEngine | null = this.engine;
    if (engine === null || engine.durationMs <= 0) {
      return '0%';
    }
    const fraction: number = Math.max(0, Math.min(1, segment.start_ms / engine.durationMs));
    return `${(fraction * 100).toFixed(2)}%`;
  }

  private currentClock(): string {
    return Formatters.clock(this.timelineMs() / 1000);
  }

  private remainingClock(): string {
    const engine: CarAvPlayerEngine | null = this.engine;
    if (engine === null) {
      return '-0:00';
    }
    const left: number = Math.max(0, engine.durationMs - this.timelineMs());
    return `-${Formatters.clock(left / 1000)}`;
  }

  // MARK: - 画面尺寸（按视频宽高比 fit，双向夹紧）

  private fitWidth(): number {
    const engine: CarAvPlayerEngine | null = this.engine;
    const aspect: number = engine !== null ? engine.videoAspect : 0;
    if (aspect <= 0) {
      return this.pageWidth > 0 ? this.pageWidth : CarMetrics.screenWidth;
    }
    if (this.pageWidth <= 0 || this.pageHeight <= 0) {
      return this.pageHeight > 0 ? this.pageHeight * aspect : CarMetrics.screenWidth;
    }
    return Math.min(this.pageWidth, this.pageHeight * aspect);
  }

  private fitHeight(): number {
    const engine: CarAvPlayerEngine | null = this.engine;
    const aspect: number = engine !== null ? engine.videoAspect : 0;
    if (aspect <= 0) {
      return this.pageHeight > 0 ? this.pageHeight : CarMetrics.screenHeight;
    }
    return this.fitWidth() / aspect;
  }

  // MARK: - 传输条拖动 / 点按（松手才跳）

  private beginTrackScrub(): void {
    const engine: CarAvPlayerEngine | null = this.engine;
    if (engine === null || engine.durationMs <= 0 || this.isModal() || this.panelOpen
      || this.scrubMs >= 0) {
      return;
    }
    this.noteUserActivity();
    this.scrubBase = engine.positionMs;
    this.scrubMs = this.scrubBase;
    this.showChrome();
  }

  private updateTrackScrub(offsetX: number): void {
    const engine: CarAvPlayerEngine | null = this.engine;
    if (engine === null || this.scrubMs < 0 || this.trackWidth <= 0) {
      return;
    }
    const duration: number = engine.durationMs;
    let target: number = this.scrubBase + offsetX / this.trackWidth * duration;
    target = Math.max(0, Math.min(duration, target));
    this.scrubMs = Math.floor(target);
  }

  private endTrackScrub(): void {
    if (this.scrubMs < 0) {
      return;
    }
    const target: number = this.scrubMs;
    this.scrubMs = -1;
    this.eng().seekTo(target);
    this.showChrome();
  }

  /** 点轨道任意处直接跳（点哪跳哪） */
  private seekAtX(x: number): void {
    const engine: CarAvPlayerEngine | null = this.engine;
    if (engine === null || engine.durationMs <= 0 || this.trackWidth <= 0 || this.isModal()
      || this.panelOpen) {
      return;
    }
    this.noteUserActivity();
    const fraction: number = Math.max(0, Math.min(1, x / this.trackWidth));
    engine.seekTo(Math.floor(fraction * engine.durationMs));
    this.showChrome();
  }

  // MARK: - 布局

  build() {
    Stack() {
      this.videoSurface()
      if (this.audioLocked()) {
        this.driveModeView()
      } else {
        this.videoModeView()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(CarColors.bg)
    .onAreaChange((oldArea: Area, newArea: Area): void => {
      this.pageWidth = Number(newArea.width);
      this.pageHeight = Number(newArea.height);
    })
    .onClick((event: ClickEvent): void => {
      if (this.audioLocked() || this.isModal() || this.panelOpen) {
        return;
      }
      // 点画面 = 播放/暂停（空白层的点击 target 不是根，走各自 onClick）
      if (event.target.id !== 'car_player_root') {
        return;
      }
      this.togglePlay();
    })
  }

  /** 视频面：XComponent(SURFACE)，按视频宽高比完整放入屏幕；行车锁只隐藏不拆（无黑屏） */
  @Builder
  private videoSurface(): void {
    XComponent({
      id: 'car_player_surface',
      type: XComponentType.SURFACE,
      controller: this.surfaceController
    })
      .width(this.fitWidth())
      .height(this.fitHeight())
      // SURFACE 型 XComponent 会消费触摸（真机实测），画面不需要触摸，交给根处理
      .hitTestBehavior(HitTestMode.None)
      .visibility(this.engine !== null && this.eng().videoSurfaceVisible
        ? Visibility.Visible : Visibility.Hidden)
      .onLoad((): void => {
        this.surfaceId = this.surfaceController.getXComponentSurfaceId();
        const engine: CarAvPlayerEngine | null = this.engine;
        if (engine !== null) {
          engine.start(this.surfaceId);
        }
      })
  }

  // MARK: - 驻车视频模式

  @Builder
  private videoModeView(): void {
    Stack() {
      if (this.engine !== null && this.eng().subtitleCue.length > 0) {
        this.subtitleOverlay()
      }
      if (this.chromeVisible && !this.panelOpen) {
        this.chromeBar()
      }
      if (this.busyVisible()) {
        this.busyOverlay()
      }
      this.contextualCorner()
      if (this.panelOpen) {
        this.panelOverlay()
      }
      this.dialogs()
    }
    .width('100%')
    .height('100%')
    .id('car_player_root')
  }

  /** 系统字幕回调的文本层 */
  @Builder
  private subtitleOverlay(): void {
    Column() {
      Blank()
      Text(this.eng().subtitleCue)
        .fontSize(CarType.rowTitle)
        .fontColor('#ffffff')
        .textAlign(TextAlign.Center)
        .backgroundColor('rgba(0, 0, 0, 0.55)')
        .borderRadius(8)
        .padding({ left: 18, right: 18, top: 6, bottom: 6 })
        .constraintSize({ maxWidth: '70%' })
        .margin({ bottom: this.chromeVisible ? 150 : 96 })
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .hitTestBehavior(HitTestMode.None)
  }

  /** 传输条（chrome）：顶部操作行 + 底部片名/双层进度/时间/控制按钮行 */
  @Builder
  private chromeBar(): void {
    Column() {
      // 顶部操作行：收起 / 停止 …… 驾驶模式开关
      Row({ space: 12 }) {
        CarPillButton({
          label: '收起',
          symbol: $r('sys.symbol.chevron_left'),
          onActivate: (): void => {
            this.minimizePlayer();
          }
        })
        CarPillButton({
          label: '停止',
          symbol: $r('sys.symbol.xmark'),
          onActivate: (): void => {
            this.exitPlayer();
          }
        })
        Blank()
        CarPillButton({
          label: '驾驶模式',
          filled: this.ui.drive.manualEnabled,
          onActivate: (): void => {
            this.ui.drive.setManual(!this.ui.drive.manualEnabled);
          }
        })
      }
      .width('100%')
      .padding({ left: CarMetrics.playerInset, right: CarMetrics.playerInset, top: 20 })
      Blank()
      Column({ space: 14 }) {
        Text(this.titleLine())
          .fontSize(CarType.playerTitle)
          .fontWeight(FontWeight.Bold)
          .fontColor(CarColors.text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        this.progressTrack()
        Row() {
          Text(this.currentClock())
            .fontSize(CarType.playerTime)
            .fontColor(CarColors.textMuted)
          Blank()
          Text(this.remainingClock())
            .fontSize(CarType.playerTime)
            .fontColor(CarColors.textMuted)
        }
        .width('100%')
        Row({ space: 14 }) {
          CarPillButton({
            label: this.engine !== null && this.eng().phase === CarPlayPhase.playing
              ? '暂停' : '播放',
            symbol: this.engine !== null && this.eng().phase === CarPlayPhase.playing
              ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'),
            filled: true,
            onActivate: (): void => {
              this.togglePlay();
            }
          })
          CarPillButton({
            label: '上一集',
            symbol: $r('sys.symbol.backward_end_fill'),
            disabled: this.prevEpisode() === null,
            onActivate: (): void => {
              this.runPlayPrev();
            }
          })
          CarPillButton({
            label: '下一集',
            symbol: $r('sys.symbol.chevron_right'),
            disabled: this.engine === null || this.eng().nextEpisode() === null,
            onActivate: (): void => {
              this.runPlayNext();
            }
          })
          CarPillButton({
            label: '字幕·画质',
            symbol: $r('sys.symbol.info_circle'),
            disabled: this.engine === null || this.eng().session === null,
            onActivate: (): void => {
              this.openPanel();
            }
          })
        }
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .padding({
        left: CarMetrics.playerInset,
        right: CarMetrics.playerInset,
        bottom: 28
      })
      .linearGradient({
        angle: 180,
        colors: [[CarColors.scrimTop, 0.0], ['rgba(0, 0, 0, 0.78)', 0.5],
          [CarColors.scrimBottom, 1.0]]
      })
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }

  /**
   * 传输条轨道：缓冲/已播双层进度（含可跳段标记 + 拖动播放头）。
   * 触摸区高 48（可拖），点轨道任意处直接跳，横拖松手才跳。
   */
  @Builder
  private progressTrack(): void {
    Column() {
      Stack({ alignContent: Alignment.Start }) {
        Row()
          .width('100%')
          .height(10)
          .borderRadius(5)
          .backgroundColor('rgba(255, 255, 255, 0.2)')
        Row()
          .width(this.bufferedPct())
          .height(10)
          .borderRadius(5)
          .backgroundColor('rgba(255, 255, 255, 0.34)')
        if (this.engine !== null) {
          ForEach(this.eng().segments() ?? [], (segment: PlaybackSegmentView) => {
            Row()
              .width(this.segmentPct(segment))
              .height(10)
              .borderRadius(4)
              .backgroundColor('rgba(245, 196, 81, 0.7)')
              .margin({ left: this.segmentLeftPct(segment) })
          }, (segment: PlaybackSegmentView) => `${segment.type}_${segment.start_ms}`)
        }
        Row()
          .width(this.playedPct())
          .height(10)
          .borderRadius(5)
          .backgroundColor('#ffffff')
        // 拖动中的播放头圆点（贴着已播白条前沿）
        if (this.scrubMs >= 0) {
          Column()
            .width(26)
            .height(26)
            .borderRadius(13)
            .backgroundColor('#ffffff')
            .markAnchor({ x: 13, y: 13 })
            .position({ x: this.playedPct(), y: 5 })
        }
      }
      .width('100%')
      .height(10)
    }
    .width('100%')
    .height(CarMetrics.minTouch)
    .justifyContent(FlexAlign.Center)
    .hitTestBehavior(HitTestMode.Transparent)
    .onAreaChange((oldArea: Area, newArea: Area): void => {
      this.trackWidth = Number(newArea.width);
    })
    .onClick((event: ClickEvent): void => {
      this.seekAtX(event.x);
    })
    .gesture(PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 12 })
      .onActionStart((): void => {
        this.beginTrackScrub();
      })
      .onActionUpdate((event: GestureEvent): void => {
        this.updateTrackScrub(event.offsetX);
      })
      .onActionEnd((): void => {
        this.endTrackScrub();
      })
      .onActionCancel((): void => {
        this.scrubMs = -1;
      }))
  }

  /** 起播/换流/卡缓冲转圈 */
  @Builder
  private busyOverlay(): void {
    Column({ space: 24 }) {
      LoadingProgress()
        .width(64)
        .height(64)
        .color('#ffffff')
      Text(this.busyLabel())
        .fontSize(CarType.body)
        .fontColor(CarColors.textMuted)
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }

  /**
   * 右下角情境元素（同一时刻只出一个）：跳过按钮 / 下一集卡。
   * 该层本身 hitTest 穿透，只有按钮吃点击；空白处的点击照样回到根画面（播放/暂停）。
   */
  @Builder
  private contextualCorner(): void {
    if (!this.isModal() && (this.activeSkipSeg() !== null || this.showsUpNext())) {
      Column() {
        Blank()
        Row() {
          Blank()
          if (this.activeSkipSeg() !== null) {
            CarPillButton({
              label: this.skipLabel(this.activeSkipSeg() as PlaybackSegmentView),
              filled: true,
              onActivate: (): void => {
                this.doSkip(this.activeSkipSeg() as PlaybackSegmentView);
              }
            })
          } else if (this.showsUpNext()) {
            this.upNextCard(this.eng().nextEpisode() as EpisodeView)
          }
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
        // chrome 打开时抬到控制按钮上方，收起时贴近底部
        .padding({ right: CarMetrics.playerInset, bottom: this.chromeVisible ? 150 : 36 })
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.Transparent)
    }
  }

  /** 「即将播放」下一集卡：剧照 + 集号/集名 + 倒计时秒数 + 下一集/观看片尾 */
  @Builder
  private upNextCard(next: EpisodeView): void {
    Column({ space: 16 }) {
      Row({ space: 18 }) {
        Column() {
          RemoteImage({ url: this.upNextStillUrl(next), placeholderText: '暂无剧照' })
        }
        .width(240)
        .height(135)
        .borderRadius(12)
        .clip(true)
        Column({ space: 6 }) {
          Text(this.upNextEyebrow())
            .fontSize(CarType.footnote)
            .fontWeight(FontWeight.Medium)
            .fontColor(CarColors.textMuted)
          Text(`第 ${next.episode_number} 集`)
            .fontSize(CarType.playerTitle)
            .fontWeight(FontWeight.Bold)
            .fontColor(CarColors.text)
          if (next.name !== null && next.name !== undefined && next.name.length > 0) {
            Text(next.name)
              .fontSize(CarType.cardCaption)
              .fontColor(CarColors.textMuted)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .constraintSize({ maxWidth: 300 })
      }
      .alignItems(VerticalAlign.Center)
      Row({ space: 12 }) {
        CarPillButton({
          label: this.autoNextArmed() ? '立即播放' : '下一集',
          filled: true,
          onActivate: (): void => {
            this.runPlayNext();
          }
        })
        CarPillButton({
          label: '观看片尾',
          onActivate: (): void => {
            this.dismissUpNext();
          }
        })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width(600)
    // 宽屏不锁死：窄画布上收到父容器的 80%，避免左边出屏
    .constraintSize({ maxWidth: '80%' })
    .padding(24)
    .backgroundColor(CarColors.glassFill)
    .borderRadius(CarMetrics.cardCorner)
    .border({ width: 1, color: CarColors.lineStrong })
  }

  /** 信息面板：字幕 / 音轨 / 画质 三列同屏（音轨一条以上才有音轨列），选中即生效 */
  @Builder
  private panelOverlay(): void {
    Column() {
      Row({ space: 12 }) {
        Text('字幕 · 音轨 · 画质')
          .fontSize(CarType.rowTitle)
          .fontWeight(FontWeight.Bold)
          .fontColor(CarColors.text)
        Blank()
        CarPillButton({
          label: '关闭',
          symbol: $r('sys.symbol.xmark'),
          onActivate: (): void => {
            this.closePanel();
          }
        })
      }
      .width('100%')
      .padding({ left: CarMetrics.edge, right: CarMetrics.edge, top: 20, bottom: 8 })
      Row({ space: 36 }) {
        this.panelSubtitleColumn()
        if (this.audioTracksList().length > 1) {
          this.panelAudioColumn()
        }
        this.panelQualityColumn()
      }
      .width('100%')
      .padding({ left: CarMetrics.edge, right: CarMetrics.edge, bottom: 28 })
      .layoutWeight(1)
      .alignItems(VerticalAlign.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0, 0, 0, 0.66)')
  }

  @Builder
  private panelSubtitleColumn(): void {
    Column({ space: 10 }) {
      Text('字幕')
        .fontSize(CarType.body)
        .fontWeight(FontWeight.Bold)
        .fontColor(CarColors.textMuted)
      List({ space: 2 }) {
        ListItem() {
          CarPanelRow({
            label: '关闭',
            detail: '',
            active: this.subtitleOffActive(),
            onPick: (): void => {
              this.pickSubtitle(-1);
            }
          })
        }
        ForEach(this.subtitlePlansList(), (plan: SubtitlePlanView, index: number) => {
          ListItem() {
            CarPanelRow({
              label: this.subtitleLabel(plan),
              detail: this.subtitleDetail(plan),
              active: this.subtitleActiveAt(index),
              onPick: (): void => {
                this.pickSubtitle(index);
              }
            })
          }
        }, (plan: SubtitlePlanView, index: number) => `${plan.track_ref}_${index}`)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .fadingEdge(false)
    }
    .layoutWeight(1)
    .height('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private panelAudioColumn(): void {
    Column({ space: 10 }) {
      Text('音轨')
        .fontSize(CarType.body)
        .fontWeight(FontWeight.Bold)
        .fontColor(CarColors.textMuted)
      List({ space: 2 }) {
        ForEach(this.audioTracksList(), (track: AudioTrackView, index: number) => {
          ListItem() {
            CarPanelRow({
              label: this.audioLabel(track),
              detail: this.audioDetail(track),
              active: this.eng().activeAudioRef() === track.ref,
              onPick: (): void => {
                this.pickAudio(track.ref);
              }
            })
          }
        }, (track: AudioTrackView, index: number) => `${track.ref}_${index}`)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .fadingEdge(false)
    }
    .layoutWeight(1)
    .height('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private panelQualityColumn(): void {
    Column({ space: 10 }) {
      Text('画质')
        .fontSize(CarType.body)
        .fontWeight(FontWeight.Bold)
        .fontColor(CarColors.textMuted)
      List({ space: 2 }) {
        ForEach(CarQualityOption.all(), (option: CarQualityOption, index: number) => {
          ListItem() {
            CarPanelRow({
              label: option.label,
              detail: option.hint,
              active: this.eng().maxHeight === option.maxHeight,
              onPick: (): void => {
                this.pickQuality(option.maxHeight);
              }
            })
          }
        }, (option: CarQualityOption, index: number) => `${option.maxHeight}_${index}`)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .fadingEdge(false)
    }
    .layoutWeight(1)
    .height('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // MARK: - 行车模式（大控件播控卡）

  @Builder
  private driveModeView(): void {
    Stack() {
      // 顶部操作行：收起 / 停止
      Row({ space: 12 }) {
        CarPillButton({
          label: '收起',
          symbol: $r('sys.symbol.chevron_left'),
          onActivate: (): void => {
            this.minimizePlayer();
          }
        })
        CarPillButton({
          label: '停止',
          symbol: $r('sys.symbol.xmark'),
          onActivate: (): void => {
            this.exitPlayer();
          }
        })
        Blank()
      }
      .width('100%')
      .padding({ left: CarMetrics.playerInset, right: CarMetrics.playerInset, top: 20 })
      .alignItems(VerticalAlign.Center)
      // 大控件播控卡
      Column({ space: 22 }) {
        Row({ space: 12 }) {
          SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
            .fontSize(30)
            .fontColor([CarColors.warn])
          Column({ space: 4 }) {
            Text('行车中视频已锁定')
              .fontSize(CarType.playerTitle)
              .fontWeight(FontWeight.Bold)
              .fontColor(CarColors.text)
            Text('音频继续播放，驻车或关闭驾驶模式后恢复视频')
              .fontSize(CarType.cardCaption)
              .fontColor(CarColors.textMuted)
          }
          .alignItems(HorizontalAlign.Start)
        }
        .alignItems(VerticalAlign.Center)
        Column({ space: 8 }) {
          Text(this.titleLine())
            .fontSize(CarType.rowTitle)
            .fontWeight(FontWeight.Medium)
            .fontColor(CarColors.text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.episodeLine() !== null) {
            Text(this.episodeLine() as string)
              .fontSize(CarType.cardCaption)
              .fontColor(CarColors.textMuted)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        this.progressTrack()
        Row() {
          Text(this.currentClock())
            .fontSize(CarType.playerTime)
            .fontColor(CarColors.textMuted)
          Blank()
          Text(this.remainingClock())
            .fontSize(CarType.playerTime)
            .fontColor(CarColors.textMuted)
        }
        .width('100%')
        Row({ space: 20 }) {
          CarRoundButton({
            symbol: $r('sys.symbol.backward_end_fill'),
            diameter: 72,
            disabled: this.prevEpisode() === null,
            onActivate: (): void => {
              this.runPlayPrev();
            }
          })
          CarRoundButton({
            symbol: this.engine !== null && this.eng().phase === CarPlayPhase.playing
              ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'),
            filled: true,
            diameter: 96,
            onActivate: (): void => {
              this.togglePlay();
            }
          })
          CarRoundButton({
            symbol: $r('sys.symbol.chevron_right'),
            diameter: 72,
            disabled: this.engine === null || this.eng().nextEpisode() === null,
            onActivate: (): void => {
              this.runPlayNext();
            }
          })
          CarRoundButton({
            symbol: this.favorite ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'),
            diameter: 72,
            disabled: this.favoriteBusy,
            onActivate: (): void => {
              this.toggleFavorite();
            }
          })
        }
        .alignItems(VerticalAlign.Center)
        CarPillButton({
          label: '关闭驾驶模式',
          onActivate: (): void => {
            this.ui.drive.setManual(false);
          }
        })
      }
      .width(720)
      .padding(32)
      .backgroundColor(CarColors.glassFill)
      .borderRadius(CarMetrics.cardCorner)
      .border({ width: 1, color: CarColors.lineStrong })
      if (this.busyVisible()) {
        this.busyOverlay()
      }
      this.dialogs()
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
    .id('car_player_root')
  }

  // MARK: - 对话框（错误 / 同意 / 还在看吗）

  @Builder
  private dialogs(): void {
    if (this.engine !== null && this.eng().phase === CarPlayPhase.error) {
      this.errorDialog()
    } else if (this.engine !== null && this.eng().phase === CarPlayPhase.consent) {
      this.consentDialog()
    } else if (this.asksStillWatching()) {
      this.stillWatchingDialog()
    }
  }

  @Builder
  private errorDialog(): void {
    Stack() {
      Column({ space: 20 }) {
        Stack() {
          Text('!')
            .fontSize(30)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1a1408')
        }
        .width(56)
        .height(56)
        .borderRadius(28)
        .backgroundColor(CarColors.warn)
        Text(this.eng().errorMessage)
          .fontSize(CarType.rowTitle)
          .fontWeight(FontWeight.Medium)
          .fontColor(CarColors.text)
          .textAlign(TextAlign.Center)
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.eng().errorSuggestion.length > 0) {
          Text(this.eng().errorSuggestion)
            .fontSize(CarType.cardCaption)
            .fontColor(CarColors.textMuted)
            .textAlign(TextAlign.Center)
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        Row({ space: 14 }) {
          CarPillButton({
            label: '重试',
            filled: true,
            onActivate: (): void => {
              this.eng().retry();
            }
          })
          CarPillButton({
            label: '返回',
            onActivate: (): void => {
              this.exitPlayer();
            }
          })
        }
        .margin({ top: 4 })
      }
      .constraintSize({ maxWidth: 720 })
      .padding({ left: 40, right: 40, top: 36, bottom: 36 })
      .backgroundColor('rgba(16, 18, 26, 0.96)')
      .borderRadius(CarMetrics.cardCorner + 4)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0, 0, 0, 0.82)')
    .alignContent(Alignment.Center)
  }

  @Builder
  private consentDialog(): void {
    Stack() {
      Column({ space: 20 }) {
        Stack() {
          Text('↗')
            .fontSize(26)
            .fontWeight(FontWeight.Bold)
            .fontColor('#101623')
        }
        .width(56)
        .height(56)
        .borderRadius(28)
        .backgroundColor(CarColors.info)
        Text('需要开启软件转码')
          .fontSize(CarType.rowTitle)
          .fontWeight(FontWeight.Medium)
          .fontColor(CarColors.text)
        Text(this.consentMessage())
          .fontSize(CarType.cardCaption)
          .fontColor(CarColors.textMuted)
          .textAlign(TextAlign.Center)
          .maxLines(4)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 14 }) {
          CarPillButton({
            label: this.eng().consentSaving ? '正在开启…' : '开启并播放',
            filled: true,
            onActivate: (): void => {
              this.eng().grantConsent();
            }
          })
          CarPillButton({
            label: '返回',
            onActivate: (): void => {
              this.exitPlayer();
            }
          })
        }
        .margin({ top: 4 })
      }
      .constraintSize({ maxWidth: 720 })
      .padding({ left: 40, right: 40, top: 36, bottom: 36 })
      .backgroundColor('rgba(16, 18, 26, 0.96)')
      .borderRadius(CarMetrics.cardCorner + 4)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0, 0, 0, 0.82)')
    .alignContent(Alignment.Center)
  }

  @Builder
  private stillWatchingDialog(): void {
    Stack() {
      Column({ space: 20 }) {
        Text(this.stillWatchingTitle())
          .fontSize(CarType.rowTitle)
          .fontWeight(FontWeight.Medium)
          .fontColor(CarColors.text)
          .textAlign(TextAlign.Center)
        Text(`已经连续自动播放 ${CarSkipSegments.autoNextMaxStreak} 集。下一集等你确认后再播。`)
          .fontSize(CarType.cardCaption)
          .fontColor(CarColors.textMuted)
          .textAlign(TextAlign.Center)
        Row({ space: 14 }) {
          CarPillButton({
            label: `继续看第 ${(this.eng().nextEpisode() as EpisodeView).episode_number} 集`,
            filled: true,
            onActivate: (): void => {
              this.runPlayNext();
            }
          })
          CarPillButton({
            label: '不看了',
            onActivate: (): void => {
              this.exitPlayer();
            }
          })
        }
        .margin({ top: 4 })
      }
      .constraintSize({ maxWidth: 760 })
      .padding({ left: 40, right: 40, top: 36, bottom: 36 })
      .backgroundColor('rgba(16, 18, 26, 0.96)')
      .borderRadius(CarMetrics.cardCorner + 4)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0, 0, 0, 0.82)')
    .alignContent(Alignment.Center)
  }
}
