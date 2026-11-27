/**
 * TV 播放器页（US4 + 双 Vivid / 双内核影院增强）：
 * - 视频表面：按 surfaceGeneration 代际挂载 XComponent(SURFACE)，支持 AVPlayer → libmpv 无感换面，
 *   并按实时 HDR 流状态动态激活 `.hdrBrightness(1.0)` 高动态亮度余量；
 * - 传输条（chrome）：实时展示 HDR Vivid / 杜比视界 / Audio Vivid / 杜比全景声 / MPV 硬解 / PGS / ASS 特效徽标；
 * - 拖动预览浮层（Trickplay）：修复原生 PixelMap 显式释放，同时回显当前所处章节标题；
 * - 顶部宽屏选集抽屉（播放剧集时在传输条展开态再按「上键」呼出）；
 * - 四维影院控制面板（按「下键」或「菜单键」呼出）：
 *   1) 音轨与字幕（含中文语言识别、字幕字号缩放、±0.1s 同步偏移、ASS 原生特效开关）
 *   2) 画质、倍速（0.5×~3.0×）与播放内核（自动 / MPV / AVPlayer）
 *   3) 章节跳转与选集
 *   4) 音画链路实时诊断（Stats for Nerds：解码器、色彩像素格式、档位、服务端转码遥测）
 */
import { KeyCode } from '@kit.InputKit';
import { image } from '@kit.ImageKit';
import { http } from '@kit.NetworkKit';
import { AppModel } from '../../common/AppModel';
import { Formatters } from '../../common/Formatters';
import { ImageUrls } from '../../common/ImageUrls';
import { trackLanguageLabel } from '../../common/LanguageLabels';
import { RemoteImage } from '../../common/RemoteImage';
import { Chapters } from '../../player/Chapters';
import { MovieClawApi } from '../../api/Endpoints';
import {
  AudioTrackView,
  EpisodeView,
  PlaybackAutoSkipView,
  PlaybackChapterMarkView,
  PlaybackDiagnosticsView,
  PlaybackSegmentView,
  PlaybackSessionView,
  SubtitlePlanView,
  TrickplayView
} from '../../api/Models';
import { TvFocus } from '../components/TvFocus';
import { TvPlayRequest, TvUiState } from '../model/TvUiState';
import { TvPlayback, TvPlaybackHost, TvPlayPhase, TvSkipSegments } from '../playback/TvPlaybackHost';
import { TvColors, TvMetrics, TvType } from '../theme/TvTheme';

class TvQualityOption {
  readonly label: string;
  readonly maxHeight: number;
  readonly hint: string;

  constructor(label: string, maxHeight: number, hint: string) {
    this.label = label;
    this.maxHeight = maxHeight;
    this.hint = hint;
  }

  static all(): TvQualityOption[] {
    return [
      new TvQualityOption('自动（原画优先）', 0, '按源画质与 HDR 直通'),
      new TvQualityOption('2160p', 2160, '4K 超高清'),
      new TvQualityOption('1080p', 1080, '全高清'),
      new TvQualityOption('720p', 720, '高清'),
      new TvQualityOption('480p', 480, '标清')
    ];
  }
}

const TV_SPEEDS: number[] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];

class TrickplayTiles {
  private index: TrickplayView | null = null;
  private sheets: Map<string, ArrayBuffer> = new Map<string, ArrayBuffer>();
  private loading: Set<string> = new Set<string>();
  private tiles: Map<number, image.PixelMap> = new Map<number, image.PixelMap>();
  onSheetLoaded: (() => void) | null = null;

  setIndex(index: TrickplayView | null): void {
    this.index = index;
    this.sheets.clear();
    this.loading.clear();
    this.releaseTiles();
  }

  private releaseTiles(): void {
    this.tiles.forEach((tile: image.PixelMap): void => {
      tile.release().catch((): void => {
      });
    });
    this.tiles.clear();
  }

  tileAt(ms: number, origin: string): image.PixelMap | null {
    const index: TrickplayView | null = this.index;
    if (index === null || !index.ready || index.count <= 0 || index.interval_ms <= 0
      || index.columns <= 0 || index.sheets.length === 0) {
      return null;
    }
    const ordinal: number = Math.min(Math.max(0, Math.floor(ms / index.interval_ms)), index.count - 1);
    const cached: image.PixelMap | null = this.tiles.get(ordinal) ?? null;
    if (cached !== null) {
      return cached;
    }
    const perSheet: number = index.columns * index.rows;
    const sheetIndex: number = Math.min(Math.floor(ordinal / perSheet), index.sheets.length - 1);
    const within: number = ordinal - sheetIndex * perSheet;
    const path: string = index.sheets[sheetIndex];
    const buffer: ArrayBuffer | null = this.sheets.get(path) ?? null;
    if (buffer === null) {
      this.loadSheet(path, origin + path);
      return null;
    }
    try {
      const source: image.ImageSource = image.createImageSource(buffer);
      const region: image.Region = {
        x: (within % index.columns) * index.tile_width,
        y: Math.floor(within / index.columns) * index.tile_height,
        size: { width: index.tile_width, height: index.tile_height }
      };
      source.createPixelMap({ desiredRegion: region }).then((tile: image.PixelMap): void => {
        source.release();
        if (this.tiles.size >= 60) {
          this.releaseTiles();
        }
        this.tiles.set(ordinal, tile);
        if (this.onSheetLoaded !== null) {
          this.onSheetLoaded();
        }
      }).catch((): void => {
        source.release();
      });
    } catch (_error) {
    }
    return null;
  }

  private loadSheet(path: string, url: string): void {
    if (this.loading.has(path) || url.length === 0) {
      return;
    }
    this.loading.add(path);
    const request: http.HttpRequest = http.createHttp();
    request.request(url, {
      method: http.RequestMethod.GET,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: 15000,
      readTimeout: 60000
    }).then((resp: http.HttpResponse): void => {
      request.destroy();
      if (resp.responseCode >= 200 && resp.responseCode < 300) {
        this.sheets.set(path, resp.result as ArrayBuffer);
      }
    }).catch((): void => {
      request.destroy();
    });
  }
}

class TvHoldScrub {
  static readonly thresholdMs: number = 400;

  static rate(heldMs: number): number {
    if (heldMs < 2000) {
      return 20;
    }
    if (heldMs < 4000) {
      return 40;
    }
    if (heldMs < 6000) {
      return 80;
    }
    return 160;
  }
}

@ComponentV2
struct TvPanelTabPill {
  @Param label: string = '';
  @Param selected: boolean = false;
  @Param focusKey: string = '';
  @Param onPick: (() => void) | null = null;
  @Local glow: boolean = false;

  build() {
    Text(this.label)
      .fontSize(20)
      .fontWeight(700)
      .fontColor(this.glow ? '#0b0d12' : (this.selected ? '#ffffff' : 'rgba(255, 255, 255, 0.62)'))
      .padding({ left: 24, right: 24, top: 10, bottom: 10 })
      .borderRadius(999)
      .backgroundColor(this.glow ? '#ffffff'
        : (this.selected ? 'rgba(255, 255, 255, 0.18)' : 'rgba(255, 255, 255, 0.06)'))
      .focusable(true)
      .key(this.focusKey)
      .onFocus((): void => {
        this.glow = true;
      })
      .onBlur((): void => {
        this.glow = false;
      })
      .onHover((isHover: boolean): void => {
        this.glow = isHover;
      })
      .onClick((): void => {
        const cb = this.onPick;
        if (cb !== null) {
          cb();
        }
      })
  }
}

@ComponentV2
struct TvPanelOption {
  @Param label: string = '';
  @Param detail: string = '';
  @Param active: boolean = false;
  @Param focusKey: string = '';
  @Param onPick: (() => void) | null = null;
  @Local glow: boolean = false;

  build() {
    Row({ space: 12 }) {
      Text('✓')
        .fontSize(20)
        .fontWeight(800)
        .fontColor('#ffd47a')
        .width(24)
        .opacity(this.active ? 1 : 0)
      Column({ space: 3 }) {
        Text(this.label)
          .fontSize(22)
          .fontWeight(600)
          .fontColor(this.glow ? TvColors.text : 'rgba(255, 255, 255, 0.80)')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.detail.length > 0) {
          Text(this.detail)
            .fontSize(14)
            .fontColor('rgba(255, 255, 255, 0.48)')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 18, right: 18, top: 11, bottom: 11 })
    .borderRadius(11)
    .backgroundColor(this.glow ? 'rgba(255, 255, 255, 0.16)' : Color.Transparent)
    .focusable(true)
    .key(this.focusKey)
    .onFocus((): void => {
      this.glow = true;
    })
    .onBlur((): void => {
      this.glow = false;
    })
    .onHover((isHover: boolean): void => {
      this.glow = isHover;
    })
    .onClick((): void => {
      const cb = this.onPick;
      if (cb !== null) {
        cb();
      }
    })
  }
}

@ComponentV2
struct TvPanelEpisodeRow {
  @Param episodeNumber: number = 0;
  @Param name: string = '';
  @Param stillUrl: string = '';
  @Param active: boolean = false;
  @Param playable: boolean = true;
  @Param focusKey: string = '';
  @Param onPick: (() => void) | null = null;
  @Local glow: boolean = false;

  build() {
    Row({ space: 12 }) {
      Stack() {
        if (this.stillUrl.length > 0) {
          RemoteImage({ url: this.stillUrl, placeholderText: '' })
        } else {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('rgba(255, 255, 255, 0.08)')
        }
      }
      .width(96)
      .height(54)
      .borderRadius(8)
      .clip(true)

      Column({ space: 3 }) {
        Text(`第 ${this.episodeNumber} 集`)
          .fontSize(19)
          .fontWeight(600)
          .fontColor(this.playable ? TvColors.text : 'rgba(255, 255, 255, 0.32)')
          .maxLines(1)
        if (this.name.length > 0) {
          Text(this.name)
            .fontSize(14)
            .fontColor('rgba(255, 255, 255, 0.45)')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('✓')
        .fontSize(20)
        .fontWeight(800)
        .fontColor('#ffd47a')
        .opacity(this.active ? 1 : 0)
    }
    .width('100%')
    .padding({ left: 10, right: 12, top: 8, bottom: 8 })
    .borderRadius(10)
    .backgroundColor(this.glow ? 'rgba(255, 255, 255, 0.14)' : Color.Transparent)
    .opacity(this.playable ? 1 : 0.55)
    .focusable(this.playable)
    .key(this.focusKey)
    .onFocus((): void => {
      this.glow = true;
    })
    .onBlur((): void => {
      this.glow = false;
    })
    .onHover((isHover: boolean): void => {
      this.glow = isHover;
    })
    .onClick((): void => {
      if (!this.playable) {
        return;
      }
      const cb = this.onPick;
      if (cb !== null) {
        cb();
      }
    })
  }
}

@ComponentV2
struct TvDialogButton {
  @Param label: string = '';
  @Param focusKey: string = '';
  @Param primary: boolean = false;
  @Param onPick: (() => void) | null = null;
  @Local glow: boolean = false;

  build() {
    Text(this.label)
      .fontSize(22)
      .fontWeight(600)
      .fontColor(this.glow ? '#111319' : TvColors.text)
      .padding({ left: 42, right: 42, top: 14, bottom: 14 })
      .borderRadius(999)
      .backgroundColor(this.glow ? '#ffffff'
        : (this.primary ? 'rgba(255, 255, 255, 0.16)' : 'rgba(255, 255, 255, 0.06)'))
      .focusable(true)
      .key(this.focusKey)
      .onFocus((): void => {
        this.glow = true;
      })
      .onBlur((): void => {
        this.glow = false;
      })
      .onHover((isHover: boolean): void => {
        this.glow = isHover;
      })
      .onClick((): void => {
        const cb = this.onPick;
        if (cb !== null) {
          cb();
        }
      })
  }
}

@ComponentV2
export struct TvPlayerPage {
  @Local ui: TvUiState = TvUiState.shared;
  @Local engine: TvPlaybackHost | null = null;
  @Local chromeVisible: boolean = true;
  @Local panelOpen: boolean = false;
  /** 面板页签：tracks | tuning | chapters | stats */
  @Local panelTab: string = 'tracks';
  /** 顶部宽屏选集抽屉（剧集播放中按上键呼出） */
  @Local episodeDrawerOpen: boolean = false;
  @Local autoNextProgress: number = 0;
  @Local autoNextStreak: number = 0;
  @Local autoNextCancelled: boolean = false;
  @Local nextDismissed: boolean = false;
  @Local skipHovered: boolean = false;
  @Local cornerPillGlow: string = '';

  @Local scrubMs: number = -1;
  @Local scrubRate: number = 0;
  @Local trickplayVersion: number = 0;

  private surfaceFocused: boolean = false;
  private contextualFocus: string = '';
  private scrubBase: number = 0;
  private arrowHeld: number = 0;
  private holdArmTimer: number = -1;
  private holdTickTimer: number = -1;
  private holdStartAt: number = 0;
  private pageWidth: number = 0;
  private pageHeight: number = 0;
  private chromeTimer: number = -1;
  private clockTimer: number = -1;
  private autoExitScheduled: boolean = false;
  private trickplay: TrickplayTiles = new TrickplayTiles();
  private trickplayGen: number = 0;
  private lastSessionId: string = '';
  private autoSkipEnabled: boolean = true;
  private skipHandled: number[] = [];
  private skipHandledEpisode: number = 0;
  private episodeScroller: Scroller = new Scroller();
  private drawerScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    const request: TvPlayRequest | null = this.ui.playerRequest;
    const adopted: TvPlaybackHost | null = TvPlayback.adopt();
    if (adopted !== null) {
      this.engine = adopted;
    } else if (request !== null) {
      const host: TvPlaybackHost = new TvPlaybackHost(request);
      this.engine = host;
      host.prepare().catch((): void => {
      });
    }
    this.ui.playerBackHandler = (): boolean => this.handleBack();
    this.trickplay.onSheetLoaded = (): void => {
      this.trickplayVersion++;
    };
    this.loadTrickplay();
    this.startClock();
    this.showChrome();
  }

  aboutToDisappear(): void {
    this.ui.playerBackHandler = null;
    this.cancelScrub();
    this.trickplayGen++;
    this.trickplay.setIndex(null);
    if (this.chromeTimer >= 0) {
      clearTimeout(this.chromeTimer);
      this.chromeTimer = -1;
    }
    if (this.clockTimer >= 0) {
      clearInterval(this.clockTimer);
      this.clockTimer = -1;
    }
    this.engine?.stopDiagnostics();
    this.engine = null;
    TvPlayback.end();
  }

  private eng(): TvPlaybackHost {
    return this.engine as TvPlaybackHost;
  }

  private surfaceGenerations(): number[] {
    const e: TvPlaybackHost | null = this.engine;
    return [e !== null ? e.surfaceGeneration : 0];
  }

  // MARK: - 遥控器与媒体按键

  private onKey(event: KeyEvent): boolean {
    const engine: TvPlaybackHost | null = this.engine;
    if (engine === null) {
      return false;
    }
    const code: number = event.keyCode;
    if (event.type === KeyType.Up
      && (code === KeyCode.KEYCODE_DPAD_LEFT || code === KeyCode.KEYCODE_DPAD_RIGHT)) {
      if (this.arrowHeld === code) {
        this.releaseArrow();
        return true;
      }
      return false;
    }
    if (event.type !== KeyType.Down) {
      return false;
    }
    if (code === KeyCode.KEYCODE_MEDIA_PLAY_PAUSE) {
      this.noteUserActivity();
      engine.togglePlay();
      this.showChrome();
      return true;
    }
    if (code === KeyCode.KEYCODE_MEDIA_NEXT) {
      this.noteUserActivity();
      engine.playNext();
      this.showChrome();
      return true;
    }
    if (code === KeyCode.KEYCODE_MEDIA_PREVIOUS) {
      this.noteUserActivity();
      engine.playPrevious();
      this.showChrome();
      return true;
    }
    if (code === KeyCode.KEYCODE_MEDIA_FAST_FORWARD) {
      this.noteUserActivity();
      engine.seekBy(30000);
      this.showChrome();
      return true;
    }
    if (code === KeyCode.KEYCODE_MEDIA_REWIND) {
      this.noteUserActivity();
      engine.seekBy(-15000);
      this.showChrome();
      return true;
    }
    if (code === KeyCode.KEYCODE_MENU) {
      if (this.panelOpen) {
        this.closePanel();
      } else if (!this.isModal()) {
        this.openPanel('tracks');
      }
      return true;
    }
    if (this.isModal() || this.panelOpen || this.episodeDrawerOpen) {
      return false;
    }
    if (code === KeyCode.KEYCODE_DPAD_LEFT && this.surfaceFocused) {
      this.noteUserActivity();
      this.pressArrow(code);
      return true;
    }
    if (code === KeyCode.KEYCODE_DPAD_RIGHT && this.surfaceFocused) {
      this.noteUserActivity();
      this.pressArrow(code);
      return true;
    }
    if (code === KeyCode.KEYCODE_DPAD_UP) {
      if (this.chromeVisible && this.hasEpisodePicker()) {
        this.openEpisodeDrawer();
      } else {
        this.showChrome();
      }
      return true;
    }
    if (code === KeyCode.KEYCODE_DPAD_DOWN) {
      this.openPanel('tracks');
      return true;
    }
    if ((code === KeyCode.KEYCODE_DPAD_CENTER || code === KeyCode.KEYCODE_ENTER)
      && this.surfaceFocused) {
      this.noteUserActivity();
      engine.togglePlay();
      this.showChrome();
      return true;
    }
    return false;
  }

  private pressArrow(code: number): void {
    if (this.arrowHeld !== 0) {
      if (this.scrubMs >= 0) {
        this.showChrome();
      }
      return;
    }
    this.arrowHeld = code;
    if (this.holdArmTimer >= 0) {
      clearTimeout(this.holdArmTimer);
    }
    this.holdArmTimer = setTimeout((): void => {
      this.holdArmTimer = -1;
      this.beginHoldScrub();
    }, TvHoldScrub.thresholdMs);
  }

  private releaseArrow(): void {
    const held: number = this.arrowHeld;
    this.arrowHeld = 0;
    if (this.holdArmTimer >= 0) {
      clearTimeout(this.holdArmTimer);
      this.holdArmTimer = -1;
    }
    if (this.scrubRate !== 0 || (this.scrubMs >= 0 && this.holdTickTimer >= 0)) {
      const target: number = this.scrubMs;
      this.stopHoldTick();
      this.scrubMs = -1;
      this.scrubRate = 0;
      this.eng().seekTo(target);
      this.showChrome();
      return;
    }
    this.eng().seekBy(held === KeyCode.KEYCODE_DPAD_LEFT ? -10000 : 10000);
    this.showChrome();
  }

  private beginHoldScrub(): void {
    const engine: TvPlaybackHost | null = this.engine;
    if (engine === null || engine.durationMs <= 0 || this.scrubMs >= 0) {
      return;
    }
    this.scrubBase = engine.positionMs;
    this.scrubMs = this.scrubBase;
    this.holdStartAt = Date.now();
    this.stopHoldTick();
    this.holdTickTimer = setInterval((): void => {
      this.tickHoldScrub();
    }, 100);
    this.showChrome();
  }

  private tickHoldScrub(): void {
    const engine: TvPlaybackHost | null = this.engine;
    if (engine === null || this.scrubMs < 0) {
      this.stopHoldTick();
      return;
    }
    const heldMs: number = Date.now() - this.holdStartAt;
    const direction: number = this.arrowHeld === KeyCode.KEYCODE_DPAD_LEFT ? -1 : 1;
    const rate: number = TvHoldScrub.rate(heldMs) * direction;
    this.scrubRate = rate;
    let target: number = this.scrubMs + rate * 100;
    const duration: number = engine.durationMs;
    if (duration > 0) {
      target = Math.max(0, Math.min(duration, target));
    }
    this.scrubMs = Math.floor(target);
    this.showChrome();
  }

  private stopHoldTick(): void {
    if (this.holdTickTimer >= 0) {
      clearInterval(this.holdTickTimer);
      this.holdTickTimer = -1;
    }
  }

  private cancelScrub(): void {
    this.arrowHeld = 0;
    if (this.holdArmTimer >= 0) {
      clearTimeout(this.holdArmTimer);
      this.holdArmTimer = -1;
    }
    this.stopHoldTick();
    this.scrubMs = -1;
    this.scrubRate = 0;
  }

  private beginSwipeScrub(): void {
    const engine: TvPlaybackHost | null = this.engine;
    if (engine === null || engine.durationMs <= 0 || this.isModal() || this.panelOpen
      || this.episodeDrawerOpen || this.scrubMs >= 0) {
      return;
    }
    this.noteUserActivity();
    this.scrubBase = engine.positionMs;
    this.scrubMs = this.scrubBase;
    this.showChrome();
  }

  private updateSwipeScrub(offsetX: number): void {
    const engine: TvPlaybackHost | null = this.engine;
    if (engine === null || this.scrubMs < 0 || this.pageWidth <= 0 || this.scrubRate !== 0) {
      return;
    }
    const duration: number = engine.durationMs;
    const sweepMs: number = Math.min(15 * 60000, Math.max(60000, Math.floor(duration / 5)));
    let target: number = this.scrubBase + offsetX / this.pageWidth * sweepMs;
    target = Math.max(0, Math.min(duration, target));
    this.scrubMs = Math.floor(target);
  }

  private endSwipeScrub(): void {
    if (this.scrubMs < 0 || this.scrubRate !== 0) {
      return;
    }
    const target: number = this.scrubMs;
    this.scrubMs = -1;
    this.eng().seekTo(target);
    this.showChrome();
  }

  // MARK: - Trickplay 缩略图

  private streamToken(): string {
    const view: PlaybackSessionView | null = this.engine?.session ?? null;
    const url: string = view !== null ? (view.stream_url ?? '') : '';
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

  private loadTrickplay(): void {
    const api: MovieClawApi | null = AppModel.shared.api;
    const view = this.engine?.session ?? null;
    const fileId: number = view !== null ? (view.decision.file_id ?? 0) : 0;
    const token: string = this.streamToken();
    this.trickplayGen++;
    const gen: number = this.trickplayGen;
    this.trickplay.setIndex(null);
    if (api === null || fileId <= 0 || token.length === 0) {
      return;
    }
    this.pollTrickplay(api, gen, fileId, token, 0);
  }

  private pollTrickplay(api: MovieClawApi, gen: number, fileId: number, token: string, attempt: number): void {
    if (gen !== this.trickplayGen || attempt >= 6) {
      return;
    }
    api.playbackFileTrickplay(fileId, token).then((index: TrickplayView): void => {
      if (gen !== this.trickplayGen) {
        return;
      }
      if (index.ready) {
        this.trickplay.setIndex(index);
        this.trickplayVersion++;
      } else {
        setTimeout((): void => {
          this.pollTrickplay(api, gen, fileId, token, attempt + 1);
        }, 30000);
      }
    }).catch((): void => {
      setTimeout((): void => {
        this.pollTrickplay(api, gen, fileId, token, attempt + 1);
      }, 30000);
    });
  }

  private scrubTile(): image.PixelMap | null {
    if (this.scrubMs < 0) {
      return null;
    }
    return this.trickplay.tileAt(this.scrubMs, AppModel.origin());
  }

  private scrubChapterTitle(): string {
    if (this.scrubMs < 0) {
      return '';
    }
    const chs: PlaybackChapterMarkView[] = this.engine?.chapters() ?? [];
    return Chapters.currentTitle(chs, this.scrubMs);
  }

  private syncSessionTrickplay(): void {
    const engine: TvPlaybackHost | null = this.engine;
    const view: PlaybackSessionView | null = engine !== null ? engine.session : null;
    const id: string = view !== null ? `${view.session_id ?? ''}@${view.decision.file_id ?? 0}` : '';
    if (id === this.lastSessionId) {
      return;
    }
    this.lastSessionId = id;
    const auto: PlaybackAutoSkipView | null = view !== null ? (view.auto_skip ?? null) : null;
    this.autoSkipEnabled = auto !== null ? auto.enabled : true;
    this.autoExitScheduled = false;
    const episode: number = engine !== null ? engine.currentEpisode : 0;
    if (episode !== this.skipHandledEpisode) {
      this.skipHandledEpisode = episode;
      this.skipHandled = [];
    }
    this.loadTrickplay();
  }

  private evaluateAutoSkip(): void {
    const engine: TvPlaybackHost | null = this.engine;
    if (engine === null || this.panelOpen || this.episodeDrawerOpen || this.scrubMs >= 0 || this.isModal()) {
      return;
    }
    if (engine.phase !== TvPlayPhase.playing) {
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
    engine.seekTo(segment.end_ms);
    this.showChrome();
  }

  // MARK: - Chrome / 面板 / 抽屉

  private chromeMustStay(): boolean {
    const engine: TvPlaybackHost | null = this.engine;
    if (engine === null) {
      return true;
    }
    return engine.phase === TvPlayPhase.paused || this.panelOpen || this.episodeDrawerOpen || this.scrubMs >= 0;
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
    }, 4000);
  }

  private requestFocusSafe(key: string): void {
    TvFocus.request(this.getUIContext(), key);
  }

  private openEpisodeDrawer(): void {
    if (!this.hasEpisodePicker() || this.isModal()) {
      return;
    }
    this.episodeDrawerOpen = true;
    this.showChrome();
    setTimeout((): void => {
      if (!this.episodeDrawerOpen) {
        return;
      }
      const cur: number = this.eng().currentEpisode;
      const idx: number = this.eng().episodes.findIndex((e: EpisodeView): boolean => e.episode_number === cur);
      if (idx >= 0) {
        try {
          this.drawerScroller.scrollToIndex(idx, false, ScrollAlign.CENTER);
        } catch (_err) {
        }
        this.requestFocusSafe(`tv_drawer_ep_${cur}`);
      }
    }, 120);
  }

  private closeEpisodeDrawer(): void {
    this.episodeDrawerOpen = false;
    setTimeout((): void => {
      this.requestFocusSafe('tv_player_root');
    }, 60);
  }

  private openPanel(tab: string = 'tracks'): void {
    const engine: TvPlaybackHost | null = this.engine;
    if (engine === null || engine.session === null || this.isModal()) {
      return;
    }
    this.episodeDrawerOpen = false;
    this.panelTab = tab;
    this.panelOpen = true;
    if (tab === 'stats') {
      engine.startDiagnostics();
    } else {
      engine.stopDiagnostics();
    }
    this.showChrome();
    setTimeout((): void => {
      if (this.panelOpen) {
        this.requestFocusSafe(`tv_panel_tab_${tab}`);
      }
    }, 120);
  }

  private switchPanelTab(tab: string): void {
    this.panelTab = tab;
    if (tab === 'stats') {
      this.eng().startDiagnostics();
    } else {
      this.eng().stopDiagnostics();
    }
    if (tab === 'chapters' && this.hasEpisodePicker()) {
      setTimeout((): void => {
        const cur: number = this.eng().currentEpisode;
        const idx: number = this.eng().episodes.findIndex((e: EpisodeView): boolean => e.episode_number === cur);
        if (idx >= 0) {
          try {
            this.episodeScroller.scrollToIndex(idx, true, ScrollAlign.CENTER);
          } catch (_err) {
          }
        }
      }, 100);
    }
  }

  private closePanel(): void {
    this.panelOpen = false;
    this.engine?.stopDiagnostics();
    setTimeout((): void => {
      this.requestFocusSafe('tv_player_root');
    }, 60);
  }

  // MARK: - 情境与自动连播

  private isModal(): boolean {
    const engine: TvPlaybackHost | null = this.engine;
    if (engine === null) {
      return false;
    }
    return engine.phase === TvPlayPhase.error || engine.phase === TvPlayPhase.consent || this.asksStillWatching();
  }

  private asksStillWatching(): boolean {
    const engine: TvPlaybackHost | null = this.engine;
    const request: TvPlayRequest | null = this.ui.playerRequest;
    if (engine === null || request === null || !request.autoAdvance) {
      return false;
    }
    return engine.phase === TvPlayPhase.ended && engine.nextEpisode() !== null
      && this.autoNextStreak >= TvSkipSegments.autoNextMaxStreak;
  }

  private showsUpNext(): boolean {
    const engine: TvPlaybackHost | null = this.engine;
    if (engine === null || this.isModal() || this.nextDismissed) {
      return false;
    }
    if (engine.nextEpisode() === null) {
      return false;
    }
    return TvSkipSegments.shouldShowUpNext(engine.segments(), engine.positionMs, engine.phase === TvPlayPhase.ended);
  }

  private autoNextArmed(): boolean {
    const engine: TvPlaybackHost | null = this.engine;
    const request: TvPlayRequest | null = this.ui.playerRequest;
    if (engine === null || request === null || !request.autoAdvance) {
      return false;
    }
    if (!this.showsUpNext() || this.autoNextCancelled) {
      return false;
    }
    return TvSkipSegments.autoNextArmed(
      engine.segments(),
      engine.positionMs,
      this.autoNextStreak,
      engine.phase === TvPlayPhase.ended
    );
  }

  private activeSkipSeg(): PlaybackSegmentView | null {
    return this.engine !== null ? this.engine.activeSkipSegment() : null;
  }

  private pausedVisible(): boolean {
    const engine: TvPlaybackHost | null = this.engine;
    return engine !== null && engine.phase === TvPlayPhase.paused && engine.positionMs > 0 && !this.isModal();
  }

  private busyVisible(): boolean {
    const engine: TvPlaybackHost | null = this.engine;
    if (engine === null || this.isModal()) {
      return false;
    }
    return engine.phase === TvPlayPhase.negotiating
      || (engine.buffering && (engine.phase === TvPlayPhase.playing || engine.phase === TvPlayPhase.paused));
  }

  private busyLabel(): string {
    const engine: TvPlaybackHost | null = this.engine;
    return engine !== null && engine.phase === TvPlayPhase.negotiating ? '正在打开…' : '正在缓冲…';
  }

  private startClock(): void {
    if (this.clockTimer >= 0) {
      return;
    }
    this.clockTimer = setInterval((): void => {
      this.syncSessionTrickplay();
      this.evaluateAutoSkip();
      this.tickAutoNext();
      this.checkMovieEndedExit();
      this.refreshContextualFocus();
    }, 100);
  }

  private checkMovieEndedExit(): void {
    const engine: TvPlaybackHost | null = this.engine;
    if (engine === null || this.autoExitScheduled || engine.phase !== TvPlayPhase.ended) {
      return;
    }
    if (engine.nextEpisode() === null) {
      this.autoExitScheduled = true;
      setTimeout((): void => {
        if (this.engine !== null && this.engine.phase === TvPlayPhase.ended && this.engine.nextEpisode() === null) {
          this.exitPlayer();
        }
      }, 1200);
    }
  }

  private tickAutoNext(): void {
    const engine: TvPlaybackHost | null = this.engine;
    if (engine === null) {
      return;
    }
    if (!this.autoNextArmed()) {
      this.autoNextProgress = 0;
      return;
    }
    if (engine.phase !== TvPlayPhase.playing && engine.phase !== TvPlayPhase.ended) {
      return;
    }
    this.autoNextProgress = Math.min(1, this.autoNextProgress + 100 / TvSkipSegments.autoNextMs);
    if (this.autoNextProgress < 1) {
      return;
    }
    this.autoNextProgress = 0;
    this.autoNextStreak += 1;
    engine.playNext();
    this.resetUpNextState();
  }

  private refreshContextualFocus(): void {
    let target: string = '';
    const engine: TvPlaybackHost | null = this.engine;
    if (engine !== null && !this.panelOpen && !this.episodeDrawerOpen) {
      if (this.isModal()) {
        if (engine.phase === TvPlayPhase.error) {
          target = 'tv_player_retry';
        } else if (engine.phase === TvPlayPhase.consent) {
          target = 'tv_player_consent_ok';
        } else {
          target = 'tv_player_still_ok';
        }
      } else if (this.activeSkipSeg() !== null) {
        target = 'tv_player_skip';
      } else if (this.showsUpNext()) {
        target = 'tv_player_upnext';
      }
    }
    if (target === this.contextualFocus) {
      return;
    }
    const previous: string = this.contextualFocus;
    this.contextualFocus = target;
    const finalKey: string = target.length > 0 ? target : (previous.length > 0 ? 'tv_player_root' : '');
    if (finalKey.length === 0) {
      return;
    }
    setTimeout((): void => {
      this.requestFocusSafe(finalKey);
    }, 160);
  }

  private noteUserActivity(): void {
    this.autoNextStreak = 0;
  }

  private resetUpNextState(): void {
    this.autoNextProgress = 0;
    this.autoNextCancelled = false;
    this.nextDismissed = false;
  }

  private runPlayNext(): void {
    this.noteUserActivity();
    this.eng().playNext();
    this.resetUpNextState();
    this.showChrome();
  }

  private dismissUpNext(): void {
    this.noteUserActivity();
    this.nextDismissed = true;
    this.autoNextCancelled = true;
    setTimeout((): void => {
      this.requestFocusSafe('tv_player_root');
    }, 60);
  }

  private doSkip(segment: PlaybackSegmentView): void {
    this.noteUserActivity();
    this.eng().seekTo(segment.end_ms);
    this.showChrome();
    if (segment.type === 'intro') {
      const api: MovieClawApi | null = AppModel.shared.api;
      const request: TvPlayRequest | null = this.ui.playerRequest;
      if (api !== null && request !== null) {
        api.playbackAutoSkipIntroSet(request.itemId, true).catch((): void => {
        });
      }
    }
  }

  private exitPlayer(): void {
    this.ui.closePlayer();
  }

  private handleBack(): boolean {
    this.noteUserActivity();
    if (this.scrubMs >= 0) {
      this.cancelScrub();
      return true;
    }
    if (this.episodeDrawerOpen) {
      this.closeEpisodeDrawer();
      return true;
    }
    if (this.panelOpen) {
      this.closePanel();
      return true;
    }
    if (this.showsUpNext()) {
      this.dismissUpNext();
      return true;
    }
    return false;
  }

  // MARK: - 文案与派生

  private titleLine(): string {
    const request: TvPlayRequest | null = this.ui.playerRequest;
    const base: string = request !== null ? request.title : '播放';
    const engine: TvPlaybackHost | null = this.engine;
    if (engine !== null && engine.currentSeason > 0 && engine.currentEpisode > 0) {
      return `${base} · 第 ${engine.currentSeason} 季第 ${engine.currentEpisode} 集`;
    }
    return base;
  }

  private panelHintLine(): string {
    const parts: string[] = [];
    if (this.hasEpisodePicker()) {
      parts.push('▲ 选集抽屉');
    }
    parts.push('▼ 音轨 · 字幕 · 倍速 · 章节 · 诊断');
    return parts.join('    ');
  }

  private subtitlePlansList(): SubtitlePlanView[] {
    return this.engine !== null ? this.engine.subtitlePlans() : [];
  }

  private audioTracksList(): AudioTrackView[] {
    return this.engine !== null ? this.engine.audioTracks() : [];
  }

  private subtitleOffActive(): boolean {
    const engine: TvPlaybackHost | null = this.engine;
    return engine !== null && engine.selectedSubtitleIndex < 0 && engine.burnedSubtitleRef().length === 0;
  }

  private subtitleActiveAt(index: number): boolean {
    const engine: TvPlaybackHost | null = this.engine;
    if (engine === null) {
      return false;
    }
    if (engine.selectedSubtitleIndex === index) {
      return true;
    }
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
    const lang: string = trackLanguageLabel(plan.language ?? null);
    if (lang.length > 0) {
      return lang;
    }
    return plan.track_ref;
  }

  private subtitleDetail(plan: SubtitlePlanView): string {
    const parts: string[] = [];
    const lang: string = trackLanguageLabel(plan.language ?? null);
    if (plan.title !== null && plan.title !== undefined && plan.title.length > 0 && lang.length > 0) {
      parts.push(lang);
    }
    parts.push(plan.kind.toUpperCase());
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
    const lang: string = trackLanguageLabel(track.language ?? null);
    if (lang.length > 0) {
      return lang;
    }
    if (track.title !== null && track.title !== undefined && track.title.length > 0) {
      return track.title;
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
    const left: number = TvSkipSegments.autoNextMs * (1 - this.autoNextProgress) / 1000;
    return `即将播放 · ${Math.max(1, Math.ceil(left))} 秒`;
  }

  private upNextStillUrl(next: EpisodeView): string {
    const resolved: string | null = ImageUrls.resolve(AppModel.origin(), next.still_url ?? null, null);
    return resolved !== null ? resolved : '';
  }

  private consentMessage(): string {
    const view = this.engine?.session ?? null;
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
    const request: TvPlayRequest | null = this.ui.playerRequest;
    const title: string = request !== null ? request.title : '这部影片';
    return `还在看《${title}》吗？`;
  }

  private timelineMs(): number {
    if (this.scrubMs >= 0) {
      return this.scrubMs;
    }
    return this.engine !== null ? this.engine.positionMs : 0;
  }

  private playedPct(): string {
    const engine: TvPlaybackHost | null = this.engine;
    if (engine === null || engine.durationMs <= 0) {
      return '0%';
    }
    const fraction: number = Math.max(0, Math.min(1, this.timelineMs() / engine.durationMs));
    return `${(fraction * 100).toFixed(2)}%`;
  }

  private bufferedPct(): string {
    const engine: TvPlaybackHost | null = this.engine;
    if (engine === null || engine.durationMs <= 0 || engine.bufferedEndMs <= 0) {
      return '0%';
    }
    const fraction: number = Math.max(0, Math.min(1, engine.bufferedEndMs / engine.durationMs));
    return `${(fraction * 100).toFixed(2)}%`;
  }

  private segmentPct(segment: PlaybackSegmentView): string {
    const engine: TvPlaybackHost | null = this.engine;
    if (engine === null || engine.durationMs <= 0) {
      return '0%';
    }
    const from: number = Math.max(0, Math.min(engine.durationMs, segment.start_ms));
    const to: number = Math.max(0, Math.min(engine.durationMs, segment.end_ms));
    const fraction: number = Math.max(0, (to - from) / engine.durationMs);
    return `${(fraction * 100).toFixed(2)}%`;
  }

  private segmentLeftPct(segment: PlaybackSegmentView): string {
    const engine: TvPlaybackHost | null = this.engine;
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
    const engine: TvPlaybackHost | null = this.engine;
    if (engine === null) {
      return '-0:00';
    }
    const left: number = Math.max(0, engine.durationMs - this.timelineMs());
    return `-${Formatters.clock(left / 1000)}`;
  }

  private fitWidth(): number {
    const aspect: number = this.engine !== null ? this.engine.videoAspect : 0;
    if (aspect <= 0) {
      return this.pageWidth > 0 ? this.pageWidth : 1280;
    }
    if (this.pageWidth <= 0 || this.pageHeight <= 0) {
      return this.pageHeight > 0 ? this.pageHeight * aspect : 1280;
    }
    return Math.min(this.pageWidth, this.pageHeight * aspect);
  }

  private fitHeight(): number {
    const aspect: number = this.engine !== null ? this.engine.videoAspect : 0;
    if (aspect <= 0) {
      return this.pageHeight > 0 ? this.pageHeight : 720;
    }
    return this.fitWidth() / aspect;
  }

  private hasEpisodePicker(): boolean {
    const engine: TvPlaybackHost | null = this.engine;
    return engine !== null && engine.currentSeason > 0 && engine.episodes.length > 0;
  }

  private episodeStillUrl(episode: EpisodeView): string {
    const resolved: string | null = ImageUrls.resolve(AppModel.origin(), episode.still_url ?? null, null);
    return resolved === null ? '' : `${resolved}${resolved.includes('?') ? '&' : '?'}w=360`;
  }

  private pickEpisode(episodeNumber: number): void {
    const engine: TvPlaybackHost | null = this.engine;
    if (engine === null) {
      return;
    }
    if (episodeNumber === engine.currentEpisode) {
      this.panelOpen = false;
      this.episodeDrawerOpen = false;
      this.requestFocusSafe('tv_player_root');
      return;
    }
    this.noteUserActivity();
    this.panelOpen = false;
    this.episodeDrawerOpen = false;
    this.skipHandled = [];
    engine.switchToEpisode(episodeNumber);
    this.showChrome();
    this.requestFocusSafe('tv_player_root');
  }

  // MARK: - 视图树

  build() {
    Stack() {
      this.videoSurface()
      if (this.pausedVisible()) {
        this.pausedOverlay()
      }
      if (this.engine !== null && this.eng().subtitleCue.length > 0) {
        this.subtitleOverlay()
      }
      if (this.chromeVisible && !this.panelOpen && !this.episodeDrawerOpen) {
        this.chromeBar()
      }
      if (this.scrubMs >= 0) {
        this.scrubHud()
      }
      if (this.busyVisible()) {
        this.busyOverlay()
      }
      this.contextualCorner()
      if (this.episodeDrawerOpen) {
        this.episodeDrawerOverlay()
      }
      if (this.panelOpen) {
        this.panelOverlay()
      }
      this.dialogs()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(TvColors.bg)
    .focusable(true)
    .key('tv_player_root')
    .id('tv_player_root')
    .defaultFocus(true)
    .onFocus((): void => {
      this.surfaceFocused = true;
    })
    .onBlur((): void => {
      this.surfaceFocused = false;
    })
    .onKeyEvent((event: KeyEvent): boolean => this.onKey(event))
    .onAreaChange((_oldArea: Area, newArea: Area): void => {
      this.pageWidth = Number(newArea.width);
      this.pageHeight = Number(newArea.height);
    })
    .onClick((event: ClickEvent): void => {
      if (event.target.id !== 'tv_player_root') {
        return;
      }
      this.noteUserActivity();
      this.eng().togglePlay();
      this.showChrome();
    })
    .gesture(PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 24 })
      .onActionStart((): void => {
        this.beginSwipeScrub();
      })
      .onActionUpdate((event: GestureEvent): void => {
        this.updateSwipeScrub(event.offsetX);
      })
      .onActionEnd((): void => {
        this.endSwipeScrub();
      }))
  }

  @Builder
  private videoSurface(): void {
    if (this.engine !== null) {
      ForEach(this.surfaceGenerations(), (gen: number) => {
        XComponent({
          id: `tv_player_surface_${gen}`,
          type: XComponentType.SURFACE,
          controller: this.eng().surfaceController
        })
          .width(this.fitWidth())
          .height(this.fitHeight())
          .hdrBrightness(this.eng().isHdrActive() ? 1.0 : 0.0)
          .hitTestBehavior(HitTestMode.None)
          .onLoad((): void => {
            this.eng().surfaceReady(gen);
          })
          .onDestroy((): void => {
            if (this.engine !== null) {
              this.eng().surfaceDestroyed(gen);
            }
          })
      }, (gen: number) => `surf_${gen}`)
    }
  }

  @Builder
  private pausedOverlay(): void {
    Column() {
      Column({ space: 10 }) {
        Text('已暂停')
          .fontSize(15)
          .fontWeight(600)
          .fontColor('rgba(255, 255, 255, 0.6)')
          .letterSpacing(4)
        Text(this.ui.playerRequest !== null ? this.ui.playerRequest.title : '')
          .fontSize(40)
          .fontWeight(700)
          .fontColor('#ffffff')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.titleLine())
          .fontSize(20)
          .fontColor('rgba(255, 255, 255, 0.75)')
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding({ top: 64, left: 80 })
      Blank()
    }
    .width('100%')
    .height('100%')
    .linearGradient({
      angle: 180,
      colors: [['rgba(0, 0, 0, 0.5)', 0.0], ['rgba(0, 0, 0, 0.18)', 0.4], ['rgba(0, 0, 0, 0.65)', 1.0]]
    })
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  private subtitleOverlay(): void {
    Column() {
      Blank()
      Text(this.eng().subtitleCue)
        .fontSize(Math.round(this.eng().subFontScale * 5.0))
        .fontColor('#ffffff')
        .textAlign(TextAlign.Center)
        .backgroundColor(this.eng().subBackground ? 'rgba(0, 0, 0, 0.58)' : Color.Transparent)
        .shadow({ radius: 6, color: 'rgba(0, 0, 0, 0.85)', offsetY: 2 })
        .borderRadius(8)
        .padding({ left: 18, right: 18, top: 6, bottom: 6 })
        .constraintSize({ maxWidth: '74%' })
        .margin({ bottom: this.chromeVisible ? 165 : Math.max(48, this.eng().subBottom * 7) })
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  private chromeBar(): void {
    Column() {
      if (this.eng().session !== null && this.eng().phase !== TvPlayPhase.paused) {
        Text(this.panelHintLine())
          .fontSize(14)
          .fontColor('rgba(255, 255, 255, 0.65)')
          .padding({ left: 18, right: 18, top: 6, bottom: 6 })
          .backgroundColor('rgba(14, 16, 22, 0.55)')
          .borderRadius(999)
          .margin({ top: 34 })
      }
      Blank()
      Column({ space: 16 }) {
        Row({ space: 10 }) {
          Text(this.titleLine())
            .fontSize(TvType.playerTitle)
            .fontWeight(700)
            .fontColor('rgba(255, 255, 255, 0.94)')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (this.eng().playbackSpeed !== 1) {
            Text(`${this.eng().playbackSpeed}×`)
              .fontSize(13)
              .fontWeight(700)
              .fontColor('#0b0d12')
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .backgroundColor('#f5c451')
              .borderRadius(6)
          }
          ForEach(this.eng().vividBadges(), (badge: string) => {
            Text(badge)
              .fontSize(12)
              .fontWeight(700)
              .fontColor(badge.includes('Vivid') || badge.includes('杜比') ? '#ffd47a' : '#f3f5f9')
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .borderRadius(5)
              .backgroundColor('rgba(255, 255, 255, 0.10)')
              .border({
                width: 1,
                color: badge.includes('Vivid') || badge.includes('杜比')
                  ? 'rgba(255, 212, 122, 0.75)' : 'rgba(255, 255, 255, 0.32)'
              })
          }, (badge: string) => badge)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Stack({ alignContent: Alignment.Start }) {
          Row()
            .width('100%')
            .height(8)
            .borderRadius(4)
            .backgroundColor('rgba(255, 255, 255, 0.22)')
          Row()
            .width(this.bufferedPct())
            .height(8)
            .borderRadius(4)
            .backgroundColor('rgba(255, 255, 255, 0.35)')
          ForEach(this.eng().segments() ?? [], (segment: PlaybackSegmentView) => {
            Row()
              .width(this.segmentPct(segment))
              .height(8)
              .borderRadius(3)
              .backgroundColor('rgba(245, 196, 81, 0.7)')
              .margin({ left: this.segmentLeftPct(segment) })
          }, (segment: PlaybackSegmentView) => `${segment.type}_${segment.start_ms}`)
          Row()
            .width(this.playedPct())
            .height(8)
            .borderRadius(4)
            .backgroundColor('#ffffff')
          if (this.scrubMs >= 0) {
            Column()
              .width(24)
              .height(24)
              .borderRadius(12)
              .backgroundColor('#ffffff')
              .markAnchor({ x: 12, y: 12 })
              .position({ x: this.playedPct(), y: 4 })
          }
        }
        .width('100%')
        .height(8)

        Row() {
          Text(this.currentClock())
            .fontSize(TvType.playerTime)
            .fontColor('rgba(255, 255, 255, 0.82)')
          Blank()
          Text(this.remainingClock())
            .fontSize(TvType.playerTime)
            .fontColor('rgba(255, 255, 255, 0.82)')
        }
        .width('100%')
      }
      .width('100%')
      .padding({
        left: TvMetrics.playerInset,
        right: TvMetrics.playerInset,
        bottom: 40
      })
      .linearGradient({
        angle: 180,
        colors: [['rgba(0, 0, 0, 0)', 0.0], ['rgba(0, 0, 0, 0.78)', 0.5], ['rgba(0, 0, 0, 0.92)', 1.0]]
      })
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  private busyOverlay(): void {
    Column({ space: 24 }) {
      LoadingProgress()
        .width(60)
        .height(60)
        .color('#ffffff')
      Text(this.busyLabel())
        .fontSize(TvType.body)
        .fontColor('rgba(255, 255, 255, 0.85)')
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }

  private scrubHudX(): number {
    const engine: TvPlaybackHost | null = this.engine;
    const pageWidth: number = this.pageWidth > 0 ? this.pageWidth : 1280;
    const duration: number = engine !== null ? engine.durationMs : 0;
    if (duration <= 0) {
      return TvMetrics.playerInset;
    }
    const fraction: number = Math.max(0, Math.min(1, this.timelineMs() / duration));
    const playheadX: number = TvMetrics.playerInset + fraction * (pageWidth - 2 * TvMetrics.playerInset);
    const min: number = TvMetrics.playerInset;
    const max: number = Math.max(min, pageWidth - TvMetrics.playerInset - 320);
    return Math.max(min, Math.min(max, playheadX - 150));
  }

  @Builder
  private scrubHud(): void {
    Column({ space: 8 }) {
      if (this.trickplayVersion >= 0 && this.scrubTile() !== null) {
        Image(this.scrubTile() as image.PixelMap)
          .autoResize(true)
          .width(296)
          .borderRadius(12)
          .clip(true)
      }
      if (this.scrubChapterTitle().length > 0) {
        Text(this.scrubChapterTitle())
          .fontSize(15)
          .fontWeight(600)
          .fontColor('#ffd47a')
          .maxLines(1)
      }
      Row({ space: 10 }) {
        if (this.scrubRate < 0) {
          Text(`◀◀ ${Math.abs(this.scrubRate)}×`)
            .fontSize(19)
            .fontWeight(700)
            .fontColor('rgba(255, 255, 255, 0.86)')
        }
        Text(Formatters.clock(this.scrubMs / 1000))
          .fontSize(21)
          .fontWeight(600)
          .fontColor('#ffffff')
        if (this.scrubRate > 0) {
          Text(`${this.scrubRate}× ▶▶`)
            .fontSize(19)
            .fontWeight(700)
            .fontColor('rgba(255, 255, 255, 0.86)')
        }
      }
      .alignItems(VerticalAlign.Center)
    }
    .alignItems(HorizontalAlign.Center)
    .position({ x: this.scrubHudX(), y: '100%' })
    .markAnchor({ x: 0, y: '100%' })
    .offset({ y: -185 })
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  private contextualCorner(): void {
    if (this.activeSkipSeg() !== null || this.showsUpNext()) {
      Column() {
        Blank()
        Row() {
          Blank()
          if (this.activeSkipSeg() !== null) {
            this.skipButton(this.activeSkipSeg() as PlaybackSegmentView)
          } else {
            this.upNextCard(this.eng().nextEpisode() as EpisodeView)
          }
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
        .padding({ right: TvMetrics.playerInset, bottom: this.chromeVisible ? 150 : 44 })
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.Transparent)
    }
  }

  @Builder
  private skipButton(segment: PlaybackSegmentView): void {
    Row({ space: 10 }) {
      Text('»')
        .fontSize(20)
        .fontWeight(800)
        .fontColor(TvColors.text)
      Text(this.skipLabel(segment))
        .fontSize(21)
        .fontWeight(600)
        .fontColor(TvColors.text)
    }
    .padding({ left: 28, right: 28, top: 12, bottom: 12 })
    .borderRadius(999)
    .backgroundColor(this.skipHovered ? 'rgba(38, 42, 56, 0.95)' : 'rgba(20, 22, 29, 0.85)')
    .border({
      width: 1,
      color: this.skipHovered ? 'rgba(255, 255, 255, 0.5)' : 'rgba(255, 255, 255, 0.18)'
    })
    .focusable(true)
    .key('tv_player_skip')
    .onKeyEvent((event: KeyEvent): boolean => {
      if (event.type === KeyType.Down && event.keyCode === KeyCode.KEYCODE_DPAD_CENTER) {
        this.doSkip(segment);
        return true;
      }
      return false;
    })
    .onFocus((): void => {
      this.skipHovered = true;
    })
    .onBlur((): void => {
      this.skipHovered = false;
    })
    .onHover((isHover: boolean): void => {
      this.skipHovered = isHover;
    })
    .onClick((): void => {
      this.doSkip(segment);
    })
  }

  @Builder
  private upNextCard(next: EpisodeView): void {
    Column({ space: 18 }) {
      Row({ space: 20 }) {
        Column() {
          RemoteImage({ url: this.upNextStillUrl(next), placeholderText: '暂无剧照' })
        }
        .width(232)
        .height(130)
        .borderRadius(12)
        .clip(true)
        Column({ space: 6 }) {
          Text(this.upNextEyebrow())
            .fontSize(15)
            .fontWeight(600)
            .fontColor('rgba(255, 255, 255, 0.6)')
          Text(`第 ${next.episode_number} 集`)
            .fontSize(22)
            .fontWeight(700)
            .fontColor('#ffffff')
          if (next.name !== null && next.name !== undefined && next.name.length > 0) {
            Text(next.name)
              .fontSize(16)
              .fontColor('rgba(255, 255, 255, 0.65)')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .constraintSize({ maxWidth: 280 })
      }
      Row({ space: 14 }) {
        this.cornerPill('tv_player_upnext', this.autoNextArmed() ? '立即播放' : '下一集', (): void => {
          this.runPlayNext();
        })
        this.cornerPill('tv_player_credits', '观看片尾', (): void => {
          this.dismissUpNext();
        })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width(560)
    .padding({ left: 24, right: 24, top: 20, bottom: 20 })
    .backgroundColor('rgba(12, 14, 20, 0.88)')
    .borderRadius(TvMetrics.cardCorner)
    .border({ width: 1, color: 'rgba(255, 255, 255, 0.12)' })
  }

  @Builder
  private cornerPill(key: string, label: string, action: () => void): void {
    Text(label)
      .fontSize(19)
      .fontWeight(600)
      .fontColor(this.cornerPillGlow === key ? '#111319' : TvColors.text)
      .padding({ left: 28, right: 28, top: 10, bottom: 10 })
      .borderRadius(999)
      .backgroundColor(this.cornerPillGlow === key ? '#ffffff' : 'rgba(255, 255, 255, 0.12)')
      .focusable(true)
      .key(key)
      .onFocus((): void => {
        this.cornerPillGlow = key;
      })
      .onBlur((): void => {
        if (this.cornerPillGlow === key) {
          this.cornerPillGlow = '';
        }
      })
      .onHover((isHover: boolean): void => {
        this.cornerPillGlow = isHover ? key : '';
      })
      .onClick((): void => {
        action();
      })
  }

  // MARK: - 顶部宽屏选集抽屉（剧集按「上键」呼出）

  @Builder
  private episodeDrawerOverlay(): void {
    Column() {
      Column({ space: 16 }) {
        Row({ space: 12 }) {
          Text(`第 ${this.eng().currentSeason} 季 · 快速选集`)
            .fontSize(22)
            .fontWeight(700)
            .fontColor(TvColors.text)
          Text('按返回键收起')
            .fontSize(14)
            .fontColor(TvColors.textMuted)
        }
        .width('100%')
        .padding({ left: TvMetrics.playerInset, right: TvMetrics.playerInset })

        List({ space: 18, scroller: this.drawerScroller }) {
          ForEach(this.eng().episodes, (ep: EpisodeView) => {
            ListItem() {
              Column() {
                TvPanelEpisodeRow({
                  episodeNumber: ep.episode_number,
                  name: ep.name ?? '',
                  stillUrl: this.episodeStillUrl(ep),
                  active: ep.episode_number === this.eng().currentEpisode,
                  playable: ep.owned,
                  focusKey: `tv_drawer_ep_${ep.episode_number}`,
                  onPick: (): void => {
                    this.pickEpisode(ep.episode_number);
                  }
                })
              }
              .width(300)
              .backgroundColor('rgba(20, 22, 30, 0.85)')
              .borderRadius(14)
              .border({
                width: ep.episode_number === this.eng().currentEpisode ? 2 : 1,
                color: ep.episode_number === this.eng().currentEpisode
                  ? 'rgba(255, 212, 122, 0.85)' : 'rgba(255, 255, 255, 0.12)'
              })
            }
          }, (ep: EpisodeView) => `drawer_${ep.episode_number}`)
        }
        .listDirection(Axis.Horizontal)
        .width('100%')
        .height(84)
        .scrollBar(BarState.Off)
        .padding({ left: TvMetrics.playerInset, right: TvMetrics.playerInset })
      }
      .width('100%')
      .padding({ top: 38, bottom: 28 })
      .backgroundColor('rgba(10, 12, 18, 0.88)')
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, { colorMode: ThemeColorMode.DARK })

      Blank()
    }
    .width('100%')
    .height('100%')
  }

  // MARK: - 四维影院控制面板

  @Builder
  private panelOverlay(): void {
    Column({ space: 22 }) {
      // 页签头
      Row({ space: 12 }) {
        TvPanelTabPill({
          label: '音轨与字幕',
          selected: this.panelTab === 'tracks',
          focusKey: 'tv_panel_tab_tracks',
          onPick: (): void => {
            this.switchPanelTab('tracks');
          }
        })
        TvPanelTabPill({
          label: '画质 · 倍速 · 内核',
          selected: this.panelTab === 'tuning',
          focusKey: 'tv_panel_tab_tuning',
          onPick: (): void => {
            this.switchPanelTab('tuning');
          }
        })
        if (this.hasEpisodePicker() || this.eng().chapters().length > 0) {
          TvPanelTabPill({
            label: this.hasEpisodePicker() ? '选集与章节' : '章节跳转',
            selected: this.panelTab === 'chapters',
            focusKey: 'tv_panel_tab_chapters',
            onPick: (): void => {
              this.switchPanelTab('chapters');
            }
          })
        }
        TvPanelTabPill({
          label: '音画链路诊断',
          selected: this.panelTab === 'stats',
          focusKey: 'tv_panel_tab_stats',
          onPick: (): void => {
            this.switchPanelTab('stats');
          }
        })
      }
      .width('100%')
      .padding({ left: 72, right: 72, top: 48 })

      if (this.panelTab === 'tracks') {
        Row({ space: 36 }) {
          this.panelSubtitleColumn()
          this.panelSubtitleTuningColumn()
          if (this.audioTracksList().length > 0) {
            this.panelAudioColumn()
          }
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 72, right: 72, bottom: 40 })
      } else if (this.panelTab === 'tuning') {
        Row({ space: 36 }) {
          this.panelQualityColumn()
          this.panelSpeedColumn()
          this.panelEngineColumn()
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 72, right: 72, bottom: 40 })
      } else if (this.panelTab === 'chapters') {
        Row({ space: 36 }) {
          if (this.hasEpisodePicker()) {
            this.panelEpisodeColumn()
          }
          if (this.eng().chapters().length > 0) {
            this.panelChaptersColumn()
          }
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 72, right: 72, bottom: 40 })
      } else {
        this.panelStatsView()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(6, 8, 14, 0.80)')
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, { colorMode: ThemeColorMode.DARK })
  }

  @Builder
  private panelSubtitleColumn(): void {
    Column({ space: 12 }) {
      Text(`字幕轨（${this.subtitlePlansList().length + 1}）`)
        .fontSize(24)
        .fontWeight(700)
        .fontColor(TvColors.text)
      List({ space: 2 }) {
        ListItem() {
          TvPanelOption({
            label: '关闭字幕',
            detail: '',
            focusKey: 'tv_panel_subtitle_0',
            active: this.subtitleOffActive(),
            onPick: (): void => {
              this.eng().selectSubtitle(-1);
              this.showChrome();
            }
          })
        }
        ForEach(this.subtitlePlansList(), (plan: SubtitlePlanView, index: number) => {
          ListItem() {
            TvPanelOption({
              label: this.subtitleLabel(plan),
              detail: this.subtitleDetail(plan),
              focusKey: `tv_panel_subtitle_${index + 1}`,
              active: this.subtitleActiveAt(index),
              onPick: (): void => {
                this.eng().selectSubtitle(index);
                this.showChrome();
              }
            })
          }
        }, (plan: SubtitlePlanView, index: number) => `${plan.track_ref}_${index}`)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .layoutWeight(1)
    .height('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private panelSubtitleTuningColumn(): void {
    Column({ space: 12 }) {
      Text('字幕排版与同步')
        .fontSize(24)
        .fontWeight(700)
        .fontColor(TvColors.text)
      List({ space: 2 }) {
        ListItem() {
          TvPanelOption({
            label: 'ASS 原生特效渲染',
            detail: this.eng().subNativeAss ? '开启（libass GPU 原样排版）' : '关闭（纯文本白字渲染）',
            active: this.eng().subNativeAss,
            onPick: (): void => {
              this.eng().toggleNativeAss();
            }
          })
        }
        ListItem() {
          TvPanelOption({
            label: `增大字号（当前 ${this.eng().subFontScale.toFixed(1)}）`,
            detail: '适合客厅远距离观看',
            onPick: (): void => {
              this.eng().adjustSubtitleFont(0.4);
            }
          })
        }
        ListItem() {
          TvPanelOption({
            label: '减小字号',
            detail: '收紧大屏字幕占比',
            onPick: (): void => {
              this.eng().adjustSubtitleFont(-0.4);
            }
          })
        }
        ListItem() {
          TvPanelOption({
            label: `字幕延后 +0.1s（当前 ${this.eng().subDelayLabel()}）`,
            detail: '字幕比人声快时点此',
            onPick: (): void => {
              this.eng().adjustSubtitleDelay(100);
            }
          })
        }
        ListItem() {
          TvPanelOption({
            label: `字幕提前 -0.1s（当前 ${this.eng().subDelayLabel()}）`,
            detail: '字幕比人声慢时点此',
            onPick: (): void => {
              this.eng().adjustSubtitleDelay(-100);
            }
          })
        }
        if (this.eng().subDelayMs !== 0) {
          ListItem() {
            TvPanelOption({
              label: '重置字幕时间同步（0.0s）',
              detail: '恢复原片时间轴',
              onPick: (): void => {
                this.eng().resetSubtitleDelay();
              }
            })
          }
        }
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .layoutWeight(1)
    .height('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private panelAudioColumn(): void {
    Column({ space: 12 }) {
      Text(`音轨（${this.audioTracksList().length}）`)
        .fontSize(24)
        .fontWeight(700)
        .fontColor(TvColors.text)
      List({ space: 2 }) {
        ForEach(this.audioTracksList(), (track: AudioTrackView, index: number) => {
          ListItem() {
            TvPanelOption({
              label: this.audioLabel(track),
              detail: this.audioDetail(track),
              focusKey: `tv_panel_audio_${index}`,
              active: this.eng().activeAudioRef() === track.ref,
              onPick: (): void => {
                this.eng().selectAudio(track.ref);
                this.showChrome();
              }
            })
          }
        }, (track: AudioTrackView, index: number) => `${track.ref}_${index}`)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .layoutWeight(1)
    .height('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private panelQualityColumn(): void {
    Column({ space: 12 }) {
      Text('画质上限')
        .fontSize(24)
        .fontWeight(700)
        .fontColor(TvColors.text)
      List({ space: 2 }) {
        ForEach(TvQualityOption.all(), (option: TvQualityOption, index: number) => {
          ListItem() {
            TvPanelOption({
              label: option.label,
              detail: option.hint,
              focusKey: `tv_panel_quality_${index}`,
              active: this.eng().maxHeight === option.maxHeight,
              onPick: (): void => {
                this.eng().switchQuality(option.maxHeight);
                this.showChrome();
              }
            })
          }
        }, (option: TvQualityOption, index: number) => `${option.maxHeight}_${index}`)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .layoutWeight(1)
    .height('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private panelSpeedColumn(): void {
    Column({ space: 12 }) {
      Text('播放倍速')
        .fontSize(24)
        .fontWeight(700)
        .fontColor(TvColors.text)
      List({ space: 2 }) {
        ForEach(TV_SPEEDS, (spd: number) => {
          ListItem() {
            TvPanelOption({
              label: spd === 1.0 ? '1.0×（正常速度）' : `${spd}×`,
              detail: '',
              active: Math.abs(this.eng().playbackSpeed - spd) < 0.01,
              onPick: (): void => {
                this.eng().setPlaybackSpeed(spd);
                this.showChrome();
              }
            })
          }
        }, (spd: number) => `spd_${spd}`)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .layoutWeight(1)
    .height('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private panelEngineColumn(): void {
    Column({ space: 12 }) {
      Text('播放内核')
        .fontSize(24)
        .fontWeight(700)
        .fontColor(TvColors.text)
      List({ space: 2 }) {
        ListItem() {
          TvPanelOption({
            label: '自动调度（推荐）',
            detail: 'AVPlayer 硬解优先，PGS/ASS/高阶封装无感接力 libmpv',
            active: this.eng().enginePreference() === 'auto',
            onPick: (): void => {
              this.eng().switchEngine('auto');
            }
          })
        }
        ListItem() {
          TvPanelOption({
            label: '固定 libmpv 内核',
            detail: '支持多声道直通、PGS 蓝光图形字幕与 ASS 原生特效',
            active: this.eng().enginePreference() === 'mpv',
            onPick: (): void => {
              this.eng().switchEngine('mpv');
            }
          })
        }
        ListItem() {
          TvPanelOption({
            label: '固定 AVPlayer 系统内核',
            detail: '鸿蒙系统媒体管线与最低功耗硬解',
            active: this.eng().enginePreference() === 'avplayer',
            onPick: (): void => {
              this.eng().switchEngine('avplayer');
            }
          })
        }
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .layoutWeight(1)
    .height('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private panelEpisodeColumn(): void {
    Column({ space: 12 }) {
      Text(`第 ${this.eng().currentSeason} 季选集`)
        .fontSize(24)
        .fontWeight(700)
        .fontColor(TvColors.text)
      List({ space: 2, scroller: this.episodeScroller }) {
        ForEach(this.eng().episodes, (episode: EpisodeView) => {
          ListItem() {
            TvPanelEpisodeRow({
              episodeNumber: episode.episode_number,
              name: episode.name ?? '',
              stillUrl: this.episodeStillUrl(episode),
              active: episode.episode_number === this.eng().currentEpisode,
              playable: episode.owned,
              focusKey: `tv_panel_episode_${episode.episode_number}`,
              onPick: (): void => {
                this.pickEpisode(episode.episode_number);
              }
            })
          }
        }, (episode: EpisodeView) => `${episode.episode_number}`)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .layoutWeight(1)
    .height('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private panelChaptersColumn(): void {
    Column({ space: 12 }) {
      Text(`影片章节（${this.eng().chapters().length}）`)
        .fontSize(24)
        .fontWeight(700)
        .fontColor(TvColors.text)
      List({ space: 2 }) {
        ForEach(this.eng().chapters(), (ch: PlaybackChapterMarkView, idx: number) => {
          ListItem() {
            TvPanelOption({
              label: Chapters.label(ch, `章节 ${idx + 1}`),
              detail: Formatters.clock(ch.start_ms / 1000),
              active: Chapters.activeIndex(this.eng().chapters(), this.eng().positionMs) === idx,
              onPick: (): void => {
                this.eng().seekTo(ch.start_ms);
                this.closePanel();
                this.showChrome();
              }
            })
          }
        }, (ch: PlaybackChapterMarkView, idx: number) => `ch_${idx}_${ch.start_ms}`)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .layoutWeight(1)
    .height('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private panelStatsView(): void {
    Column({ space: 16 }) {
      Row({ space: 24 }) {
        this.statCard('交付档位', this.eng().streamTierLabel(),
          this.eng().session?.decision.reason ?? '')
        this.statCard('解码管线', this.eng().decodeModeLine(),
          this.eng().decodeSpecLine())
        this.statCard('高动态与音效',
          this.eng().vividBadges().length > 0 ? this.eng().vividBadges().join(' · ') : 'SDR 标准动态范围',
          this.eng().isHdrActive() ? 'HDR 峰值亮度余量已激活（hdrBrightness 1.0）' : '标准色域映射')
      }
      .width('100%')

      if (this.eng().diag !== null) {
        Column({ space: 8 }) {
          Text('服务端实时供片遥测')
            .fontSize(18)
            .fontWeight(700)
            .fontColor(TvColors.text)
          Text(this.diagSummary(this.eng().diag as PlaybackDiagnosticsView))
            .fontSize(15)
            .fontColor(TvColors.textMuted)
            .lineHeight(24)
        }
        .width('100%')
        .padding(22)
        .borderRadius(16)
        .backgroundColor('rgba(255, 255, 255, 0.06)')
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 72, right: 72, bottom: 40 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private statCard(title: string, primary: string, secondary: string): void {
    Column({ space: 8 }) {
      Text(title)
        .fontSize(14)
        .fontColor(TvColors.textMuted)
      Text(primary.length > 0 ? primary : '—')
        .fontSize(20)
        .fontWeight(700)
        .fontColor(TvColors.text)
        .maxLines(2)
      if (secondary.length > 0) {
        Text(secondary)
          .fontSize(14)
          .fontColor(TvColors.textFaint)
          .maxLines(2)
      }
    }
    .layoutWeight(1)
    .padding(22)
    .borderRadius(16)
    .backgroundColor('rgba(255, 255, 255, 0.07)')
    .border({ width: 1, color: 'rgba(255, 255, 255, 0.10)' })
    .alignItems(HorizontalAlign.Start)
  }

  private diagSummary(d: PlaybackDiagnosticsView): string {
    const parts: string[] = [];
    parts.push(`处理模式：${d.processing_mode}`);
    parts.push(`执行位置：${d.execution_location}`);
    if ((d.encoder ?? '').length > 0) {
      parts.push(`编码器：${d.encoder}`);
    }
    if ((d.job_speed ?? '').length > 0) {
      parts.push(`转码速率：${d.job_speed}`);
    }
    if (d.lead_seconds !== null && d.lead_seconds !== undefined) {
      parts.push(`缓冲领先：${Math.round(d.lead_seconds)} 秒`);
    }
    parts.push(`会话缓存：${Formatters.bytes(d.cache_bytes)}`);
    return parts.join('  ·  ');
  }

  // MARK: - 对话框

  @Builder
  private dialogs(): void {
    if (this.engine !== null && this.eng().phase === TvPlayPhase.error) {
      this.errorDialog()
    } else if (this.engine !== null && this.eng().phase === TvPlayPhase.consent) {
      this.consentDialog()
    } else if (this.asksStillWatching()) {
      this.stillWatchingDialog()
    }
  }

  @Builder
  private errorDialog(): void {
    Stack() {
      Column({ space: 24 }) {
        Stack() {
          Text('!')
            .fontSize(34)
            .fontWeight(800)
            .fontColor('#1a1408')
        }
        .width(60)
        .height(60)
        .borderRadius(30)
        .backgroundColor(TvColors.warn)
        Text(this.eng().errorMessage)
          .fontSize(28)
          .fontWeight(600)
          .fontColor('#ffffff')
          .textAlign(TextAlign.Center)
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.eng().errorSuggestion.length > 0) {
          Text(this.eng().errorSuggestion)
            .fontSize(19)
            .fontColor('rgba(255, 255, 255, 0.6)')
            .textAlign(TextAlign.Center)
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        Row({ space: 20 }) {
          TvDialogButton({
            label: '重试',
            focusKey: 'tv_player_retry',
            primary: true,
            onPick: (): void => {
              this.eng().retry();
            }
          })
          TvDialogButton({
            label: '返回',
            focusKey: 'tv_player_exit',
            onPick: (): void => {
              this.exitPlayer();
            }
          })
        }
        .margin({ top: 6 })
      }
      .constraintSize({ maxWidth: 880 })
      .padding({ left: 48, right: 48, top: 44, bottom: 44 })
      .backgroundColor('rgba(16, 18, 26, 0.96)')
      .borderRadius(TvMetrics.cardCorner + 8)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0, 0, 0, 0.82)')
    .alignContent(Alignment.Center)
  }

  @Builder
  private consentDialog(): void {
    Stack() {
      Column({ space: 24 }) {
        Stack() {
          Text('↗')
            .fontSize(30)
            .fontWeight(800)
            .fontColor('#101623')
        }
        .width(60)
        .height(60)
        .borderRadius(30)
        .backgroundColor(TvColors.info)
        Text('需要开启软件转码')
          .fontSize(28)
          .fontWeight(600)
          .fontColor('#ffffff')
        Text(this.consentMessage())
          .fontSize(19)
          .fontColor('rgba(255, 255, 255, 0.6)')
          .textAlign(TextAlign.Center)
          .maxLines(4)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 20 }) {
          TvDialogButton({
            label: this.eng().consentSaving ? '正在开启…' : '开启并播放',
            focusKey: 'tv_player_consent_ok',
            primary: true,
            onPick: (): void => {
              this.eng().grantConsent();
            }
          })
          TvDialogButton({
            label: '返回',
            focusKey: 'tv_player_consent_no',
            onPick: (): void => {
              this.exitPlayer();
            }
          })
        }
        .margin({ top: 6 })
      }
      .constraintSize({ maxWidth: 880 })
      .padding({ left: 48, right: 48, top: 44, bottom: 44 })
      .backgroundColor('rgba(16, 18, 26, 0.96)')
      .borderRadius(TvMetrics.cardCorner + 8)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0, 0, 0, 0.82)')
    .alignContent(Alignment.Center)
  }

  @Builder
  private stillWatchingDialog(): void {
    Stack() {
      Column({ space: 24 }) {
        Text(this.stillWatchingTitle())
          .fontSize(28)
          .fontWeight(600)
          .fontColor('#ffffff')
          .textAlign(TextAlign.Center)
        Text(`已经连续自动播放 ${TvSkipSegments.autoNextMaxStreak} 集。下一集等你确认后再播。`)
          .fontSize(19)
          .fontColor('rgba(255, 255, 255, 0.6)')
          .textAlign(TextAlign.Center)
        Row({ space: 20 }) {
          TvDialogButton({
            label: `继续看第 ${(this.eng().nextEpisode() as EpisodeView).episode_number} 集`,
            focusKey: 'tv_player_still_ok',
            primary: true,
            onPick: (): void => {
              this.runPlayNext();
            }
          })
          TvDialogButton({
            label: '不看了',
            focusKey: 'tv_player_still_no',
            onPick: (): void => {
              this.exitPlayer();
            }
          })
        }
        .margin({ top: 6 })
      }
      .constraintSize({ maxWidth: 900 })
      .padding({ left: 48, right: 48, top: 44, bottom: 44 })
      .backgroundColor('rgba(16, 18, 26, 0.96)')
      .borderRadius(TvMetrics.cardCorner + 8)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0, 0, 0, 0.82)')
    .alignContent(Alignment.Center)
  }
}
