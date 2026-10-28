/**
 * 车机 mini 播控条（T019，US6）：非播放器页面底部常驻播控条。
 *
 * - 内容：封面 + 标题/集数行 + 大播放暂停按钮 + 下一集按钮；
 *   点条体（封面与文案区）回播放器——行车锁时 CarPlayerPage 自动渲染播控卡；
 * - 显隐：引擎在播（adopt() 到引擎且非终态）&& 播放器覆盖层关闭；
 * - 布局：占内容区底部一行（不悬浮遮挡列表），显隐由 if 收放，列表无需让位；
 * - 看护（janitor）：播放器收起后页面钟停了，这里 250ms 心跳接管——
 *   后台播完自动接下一集（播客式连播）、播完没下一集/后台出错整体收尾并隐藏，
 *   引擎终态无人释放的问题由此兜底；
 * - 状态：文案摘要走 ui.mini（页面开着时由页面 100ms 钟同步，收起后由本条心跳同步），
 *   播放态/下一集直读引擎实时值（@Trace 细粒度响应）。
 */
import { AppModel } from '../../common/AppModel';
import { ImageUrls } from '../../common/ImageUrls';
import { RemoteImage } from '../../common/RemoteImage';
import { CarColors } from '../theme/CarTheme';
import { CarMetrics } from '../theme/CarTheme';
import { CarType } from '../theme/CarTheme';
import { CarPlayRequest, CarUiState } from '../model/CarUiState';
import { CarAvPlayerEngine, CarPlayback, CarPlayPhase } from '../player/CarAvPlayerEngine';
import { CarFormat, CarPressable } from './CarCards';

@ComponentV2
export struct CarMiniPlayer {
  @Local ui: CarUiState = CarUiState.shared;
  @Local engine: CarAvPlayerEngine | null = null;
  private clockTimer: number = -1;
  /** 文案摘要已同步到的集号（-2 = 尚未同步/需强制刷新） */
  private summaryEpisode: number = -2;

  aboutToAppear(): void {
    this.engine = CarPlayback.adopt();
    this.summaryEpisode = -2;
    this.clockTimer = setInterval((): void => {
      this.tick();
    }, 250);
  }

  aboutToDisappear(): void {
    if (this.clockTimer >= 0) {
      clearInterval(this.clockTimer);
      this.clockTimer = -1;
    }
  }

  build() {
    if (this.visible()) {
      Row({ space: 24 }) {
        this.summaryBlock()
        this.playButton()
        this.nextButton()
      }
      .width('100%')
      .height(100)
      .padding({ left: CarMetrics.edge, right: CarMetrics.edge })
      .backgroundColor(CarColors.surface)
      .border({ width: { top: 1 }, color: CarColors.line })
      .alignItems(VerticalAlign.Center)
    }
  }

  /** 封面 + 标题/集数（点击回播放器；行车锁时回播控卡由页面按播放模式自渲染） */
  @Builder
  private summaryBlock(): void {
    Column() {
      CarPressable({
        onActivate: (): void => {
          this.reopenPlayer();
        }
      }) {
        Row({ space: 20 }) {
          Stack() {
            RemoteImage({ url: this.ui.mini.coverUrl, placeholderText: this.ui.mini.title })
          }
          .width(124)
          .height(70)
          .borderRadius(8)
          .clip(true)
          Column({ space: 4 }) {
            Text(this.ui.mini.title)
              .fontSize(CarType.body)
              .fontWeight(FontWeight.Medium)
              .fontColor(CarColors.text)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (this.ui.mini.subtitle.length > 0) {
              Text(this.ui.mini.subtitle)
                .fontSize(CarType.footnote)
                .fontColor(CarColors.textMuted)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
        .height(CarMetrics.minTouch)
        .alignItems(VerticalAlign.Center)
      }
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  /** 大播放暂停（≥48vp 圆钮，亮底黑图标） */
  @Builder
  private playButton(): void {
    CarPressable({
      onActivate: (): void => {
        this.togglePlay();
      }
    }) {
      Stack() {
        SymbolGlyph(this.playing() ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
          .fontSize(26)
          .fontColor([CarColors.bg])
      }
      .width(64)
      .height(64)
      .borderRadius(32)
      .backgroundColor(CarColors.text)
    }
  }

  /** 下一集（没有下一集置灰） */
  @Builder
  private nextButton(): void {
    CarPressable({
      onActivate: (): void => {
        this.playNext();
      }
    }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(26)
          .fontWeight(FontWeight.Medium)
          .fontColor([CarColors.text])
      }
      .width(64)
      .height(64)
      .borderRadius(32)
      .backgroundColor(CarColors.surfaceRaised)
      .border({ width: 1, color: CarColors.lineStrong })
      .opacity(this.hasNext() ? 1 : 0.35)
    }
  }

  // MARK: - 显隐与实时态（引擎 @Trace 直读，细粒度响应）

  private visible(): boolean {
    const engine: CarAvPlayerEngine | null = this.engine;
    return engine !== null && this.ui.playerRequest === null
      && engine.phase !== CarPlayPhase.idle;
  }

  private playing(): boolean {
    const engine: CarAvPlayerEngine | null = this.engine;
    return engine !== null && engine.phase === CarPlayPhase.playing;
  }

  private hasNext(): boolean {
    const engine: CarAvPlayerEngine | null = this.engine;
    return engine !== null && engine.nextEpisode() !== null;
  }

  // MARK: - 250ms 心跳：接引擎 + 摘要同步 + 终态看护

  private tick(): void {
    const engine: CarAvPlayerEngine | null = CarPlayback.adopt();
    if (engine !== this.engine) {
      this.engine = engine;
      this.summaryEpisode = -2;
    }
    if (engine === null) {
      if (this.ui.mini.title.length > 0) {
        this.clearSummary();
      }
      return;
    }
    if (this.ui.playerRequest !== null) {
      // 播放器开着：页面 100ms 钟在同步 mini 摘要，这里不掺和
      return;
    }
    if (engine.phase === CarPlayPhase.error) {
      // 后台出错无人展示错误视图：整体收尾，mini 条随之隐藏
      this.endPlayback();
      return;
    }
    if (engine.phase === CarPlayPhase.ended) {
      // 播完：有下一集后台连播（播客式），没有整体收尾
      if (engine.nextEpisode() !== null) {
        engine.playNext();
      } else {
        this.endPlayback();
      }
      return;
    }
    this.syncSummary(engine);
  }

  /** 文案摘要：换集才重取（标题/集数/封面随引擎当前集走） */
  private syncSummary(engine: CarAvPlayerEngine): void {
    if (engine.currentEpisode !== this.summaryEpisode) {
      this.summaryEpisode = engine.currentEpisode;
      this.ui.mini.title = engine.request.title;
      this.ui.mini.subtitle = CarMiniPlayer.subtitleOf(engine);
      this.ui.mini.coverUrl = CarMiniPlayer.coverOf(engine);
    }
    this.ui.mini.playing = engine.phase === CarPlayPhase.playing;
    this.ui.mini.hasNext = engine.nextEpisode() !== null;
  }

  private endPlayback(): void {
    CarPlayback.end();
    this.clearSummary();
    this.engine = null;
    this.summaryEpisode = -2;
  }

  private clearSummary(): void {
    this.ui.mini.title = '';
    this.ui.mini.subtitle = '';
    this.ui.mini.coverUrl = '';
    this.ui.mini.playing = false;
    this.ui.mini.hasNext = false;
  }

  // MARK: - 传输命令

  private togglePlay(): void {
    const engine: CarAvPlayerEngine | null = this.engine;
    if (engine !== null) {
      engine.togglePlay();
    }
  }

  private playNext(): void {
    const engine: CarAvPlayerEngine | null = this.engine;
    if (engine !== null && engine.nextEpisode() !== null) {
      engine.playNext();
    }
  }

  /** 点条体回播放器：页面 adopt 现存引擎原位续接（Surface 变了原位重协商） */
  private reopenPlayer(): void {
    const engine: CarAvPlayerEngine | null = this.engine;
    if (engine === null) {
      return;
    }
    this.ui.openPlayer(engine.request as CarPlayRequest);
  }

  // MARK: - 摘要派生

  /** 集数行：有集名带上集名（引擎 episodes 实时取） */
  private static subtitleOf(engine: CarAvPlayerEngine): string {
    if (engine.currentSeason <= 0 || engine.currentEpisode <= 0) {
      return '';
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

  /** 封面：剧集取当前集剧照，电影/取不到回落起播请求封面 */
  private static coverOf(engine: CarAvPlayerEngine): string {
    if (engine.currentSeason > 0 && engine.currentEpisode > 0) {
      for (const episode of engine.episodes) {
        if (episode.episode_number === engine.currentEpisode) {
          const still: string | null = episode.still_url ?? null;
          if (still !== null && still.length > 0) {
            const resolved: string | null = ImageUrls.resolve(AppModel.origin(), still, null);
            if (resolved !== null) {
              return resolved;
            }
          }
          break;
        }
      }
    }
    return engine.request.coverUrl;
  }
}
