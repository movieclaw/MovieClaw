/**
 * TV 播放器页（T020+T021，US4）：全屏画面 + 传输条 + 信息面板 + 情境元素 + 对话框。
 *
 * 结构（对齐参考端 MovieClawTV/Player/TVPlayerScreen.swift）：
 * - 画面：XComponent(SURFACE) 按视频宽高比 fit 摆放（引擎 start(surfaceId) 挂 AVPlayer）；
 * - 传输条（chrome）：片名行 + 缓冲/已播双层进度（含可跳段标记）+ 当前/剩余时间，
 *   4 秒无操作自动收起；暂停、面板打开、拖动中常显；
 * - 信息面板：字幕 / 音轨 / 画质三列同屏（音轨一条以上才有音轨列），选中即生效
 *   （字幕外挂轨即时切、烧录轨/音轨/画质走引擎重协商）；
 * - 情境元素（右下角，同一时刻只出一个）：跳过片头按钮、「即将播放」下一集卡
 *   （连播倒计时 + 观看片尾）；连播满上限播完弹「还在看《…》吗」；
 * - 对话框：错误（重试/返回，错误归因见引擎 errorKind）、软件转码同意、还在看吗；
 * - 返回键分级（playerBackHandler）：取消拖动 → 收面板 → 收下一集卡 → 退出。
 *
 * 焦点模型：平时焦点在根画面上（方向键 = 点按 ±10s / 长按连发快进快退 20×→40×→80×→160×
 * 松手跳落点 / 面板 / 呼出 chrome，OK = 播放暂停）；指针横滑 = 拖进度
 * （满屏一划 ≈ 片长 1/5 夹 1~15 分钟）；拖动/长按中浮出落点时间 + trickplay 缩略图；
 * 右下角按钮、对话框出现时 150ms 内显式抢焦点；面板打开焦点落字幕列当前行。
 * 引擎状态全部来自 TvAvPlayerEngine 的 @Trace（页面只渲染、不下播放决策）。
 */
import { KeyCode } from '@kit.InputKit';
import { image } from '@kit.ImageKit';
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppModel } from '../../common/AppModel';
import { Formatters } from '../../common/Formatters';
import { ImageUrls } from '../../common/ImageUrls';
import { RemoteImage } from '../../common/RemoteImage';
import { TvFocus } from '../components/TvFocus';
import { MovieClawApi } from '../../api/Endpoints';
import {
  AudioTrackView,
  EpisodeView,
  PlaybackSegmentView,
  PlaybackAutoSkipView, PlaybackSessionView,
  SubtitlePlanView,
  TrickplayView
} from '../../api/Models';
import { TvColors } from '../theme/TvTheme';
import { TvMetrics } from '../theme/TvTheme';
import { TvType } from '../theme/TvTheme';
import { TvPlayRequest, TvUiState } from '../model/TvUiState';
import { TvAvPlayerEngine, TvPlayback, TvPlayPhase, TvSkipSegments } from './TvAvPlayerEngine';

/** 画质选项（信息面板画质列；maxHeight 是上限语义：源不超就直通） */
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
      new TvQualityOption('自动（原画优先）', 0, '按源画质直通'),
      new TvQualityOption('2160p', 2160, '4K 超高清'),
      new TvQualityOption('1080p', 1080, '全高清'),
      new TvQualityOption('720p', 720, '高清'),
      new TvQualityOption('480p', 480, '标清')
    ];
  }
}

/**
 * 进度条缩略图（T028，同手机端 TrickplayTiles）：按需下载雪碧图，按落点裁出目标格子。
 * 雪碧图 token 已在地址里（不需要登录头）；裁格子走 `DecodingOptions.desiredRegion`，
 * 裁过的格子按序号缓存（一次拖动里每个序号最多裁一次）。
 */
class TrickplayTiles {
  private index: TrickplayView | null = null;
  private sheets: Map<string, ArrayBuffer> = new Map<string, ArrayBuffer>();
  private loading: Set<string> = new Set<string>();
  private tiles: Map<number, image.PixelMap> = new Map<number, image.PixelMap>();
  /** 雪碧图下载/裁格完成的回调（外面用它驱动界面刷新） */
  onSheetLoaded: (() => void) | null = null;

  setIndex(index: TrickplayView | null): void {
    this.index = index;
    this.sheets.clear();
    this.loading.clear();
    this.tiles.clear();
  }

  /** 文件时间（毫秒）→ 该显示的格子；雪碧图还没下完返回 null（并开始下载） */
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
    // 裁格子：desiredRegion 是解码期裁剪，正好当 iOS 的 cgImage.cropping 用
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
          this.tiles.clear();
        }
        this.tiles.set(ordinal, tile);
        if (this.onSheetLoaded !== null) {
          this.onSheetLoaded();
        }
      }).catch((): void => {
        source.release();
      });
    } catch (error) {
      // 裁不出来：这一格就没有预览，不影响播放
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

/**
 * 按住左右键连续快进 / 快退的节奏（T028，同参考端 TVHoldScrub）：
 * 按住 0.4 秒起步（短于这个算点按，跳 10 秒），
 * 速度每 2 秒翻一倍：20× → 40× → 80× → 160×（片内秒数 / 秒）。
 * 起步不快到对不准，两小时的片子按住十来秒能走完大半。
 */
class TvHoldScrub {
  /** 长按门槛：短于这个算点按 */
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

/** 信息面板的一行选项：焦点/悬浮高亮底、选中打勾、点选即生效 */
@ComponentV2
struct TvPanelOption {
  @Param label: string = '';
  @Param detail: string = '';
  /** 选中（打勾） */
  @Param active: boolean = false;
  /** FocusController.requestFocus 定位用 */
  @Param focusKey: string = '';
  @Param onPick: (() => void) | null = null;
  @Local glow: boolean = false;

  build() {
    Row({ space: 14 }) {
      Text('✓')
        .fontSize(24)
        .fontWeight(800)
        .fontColor('#ffd47a')
        .width(28)
        .opacity(this.active ? 1 : 0)
      Column({ space: 4 }) {
        Text(this.label)
          .fontSize(28)
          .fontWeight(600)
          .fontColor(this.glow ? TvColors.text : 'rgba(255, 255, 255, 0.78)')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.detail.length > 0) {
          Text(this.detail)
            .fontSize(17)
            .fontColor('rgba(255, 255, 255, 0.45)')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 22, right: 22, top: 13, bottom: 13 })
    .borderRadius(11)
    .backgroundColor(this.glow ? 'rgba(255, 255, 255, 0.14)' : Color.Transparent)
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
      // ClickEvent 没有 stopPropagation；子按钮的点击由根画面按 target.id 过滤
      const cb = this.onPick;
      if (cb !== null) {
        cb();
      }
    })
  }
}

/** 信息面板「选集」列的一行：剧照缩略图 + 集号/集名；当前集打勾，缺集置灰不可点 */
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

/** 对话框按钮：玻璃胶囊，焦点/悬浮翻白底黑字（Apple TV 对话框样式） */
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
  @Local engine: TvAvPlayerEngine | null = null;
  /** 传输条（chrome）可见性；4 秒无操作自动收起 */
  @Local chromeVisible: boolean = true;
  /** 信息面板（选集/字幕/音轨/画质）打开 */
  @Local panelOpen: boolean = false;
  /** 自动连播倒计时 0~1（卡片上眉标给秒数） */
  @Local autoNextProgress: number = 0;
  /** 无人值守的连续连播计数（满上限弹「还在看吗」） */
  @Local autoNextStreak: number = 0;
  /** 「观看片尾」按过：这集不再倒计时（播完卡片会再出来） */
  @Local autoNextCancelled: boolean = false;
  /** 下一集卡收起（返回键/观看片尾） */
  @Local nextDismissed: boolean = false;
  /** 跳过按钮焦点/悬浮高亮 */
  @Local skipHovered: boolean = false;
  /** 下一集卡两颗胶囊当前高亮的是哪颗（key 空串 = 都不高亮） */
  @Local cornerPillGlow: string = '';

  // —— 拖动与连发快进（T028）——

  /** 拖动/长按快进的落点（毫秒）；-1 = 没在拖。松手才真正跳（HLS 上途中跟随会打爆转码器） */
  @Local scrubMs: number = -1;
  /** 长按连发速度（带方向，负 = 快退）；0 = 不是长按拖动 */
  @Local scrubRate: number = 0;
  /** 雪碧图就位驱动浮层刷新 */
  @Local trickplayVersion: number = 0;

  /** 焦点是否落在根画面（false = 在右下按钮/面板行/对话框上） */
  private surfaceFocused: boolean = false;
  /** 右下角情境元素 / 对话框当前占焦的 key（变化时显式转焦点） */
  private contextualFocus: string = '';
  /** 本轮拖动的出发点（长按中按返回 = 丢掉落点回这里） */
  private scrubBase: number = 0;
  /** 正按住的方向键（KEYCODE_DPAD_LEFT/RIGHT；0 = 没按） */
  private arrowHeld: number = 0;
  /** 长按门槛计时（0.4s 内松开 = 点按 ±10s） */
  private holdArmTimer: number = -1;
  /** 长按连发节拍（100ms 推进落点） */
  private holdTickTimer: number = -1;
  private holdStartAt: number = 0;
  private pageWidth: number = 0;
  private pageHeight: number = 0;
  private surfaceId: string = '';
  private surfaceController: XComponentController = new XComponentController();
  private chromeTimer: number = -1;
  private clockTimer: number = -1;
  /** 进度条缩略图（雪碧图按需下载、格子裁剪缓存） */
  private trickplay: TrickplayTiles = new TrickplayTiles();
  private trickplayGen: number = 0;
  /** 已加载缩略图对应的会话标识（换会话/换集时重新取） */
  private lastSessionId: string = '';
  /** 自动跳过总开关（随会话下发；旧服务端没有该字段时默认开） */
  private autoSkipEnabled: boolean = true;
  /** 本集已决定过的段起点：自然播进去自动跳一次，拖回去/跳回来只给按钮 */
  private skipHandled: number[] = [];
  /** skipHandled 属于哪一集（换集清空） */
  private skipHandledEpisode: number = 0;
  /** 选集列表滚动器（打开面板时定位到当前集） */
  private episodeScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    hilog.info(0x0000, 'DbgFlow', 'PLAYER_PAGE_APPEAR');
    const request: TvPlayRequest | null = this.ui.playerRequest;
    const adopted: TvAvPlayerEngine | null = TvPlayback.adopt();
    if (adopted !== null) {
      this.engine = adopted;
    } else if (request !== null) {
      // 兜底：视图比 begin 先挂（异常路径）——就地建引擎并预协商
      const engine: TvAvPlayerEngine = new TvAvPlayerEngine(request);
      this.engine = engine;
      engine.prepare();
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
    hilog.info(0x0000, 'DbgFlow', 'PLAYER_PAGE_DISAPPEAR');
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
    this.engine = null;
    TvPlayback.end();
  }

  /** 引擎非空断言：aboutToAppear 先于 build，页面挂起时引擎一定就位 */
  private eng(): TvAvPlayerEngine {
    return this.engine as TvAvPlayerEngine;
  }

  // MARK: - 遥控键

  private onKey(event: KeyEvent): boolean {
    const engine: TvAvPlayerEngine | null = this.engine;
    if (engine === null) {
      return false;
    }
    const code: number = event.keyCode;
    // 左右键松开：长按拖动跳到落点，点按跳 10 秒（T028）
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
    // 播放/暂停在焦点落在任何非模态元素上时都生效（同 tvOS onPlayPauseCommand）
    if (code === KeyCode.KEYCODE_MEDIA_PLAY_PAUSE) {
      this.noteUserActivity();
      engine.togglePlay();
      this.showChrome();
      return true;
    }
    if (this.isModal() || this.panelOpen) {
      // 对话框/面板的行自己走焦点导航；返回键走 ui.handleBack → playerBackHandler
      return false;
    }
    if (code === KeyCode.KEYCODE_DPAD_LEFT) {
      if (this.surfaceFocused) {
        this.noteUserActivity();
        this.pressArrow(code);
        return true;
      }
      return false;
    }
    if (code === KeyCode.KEYCODE_DPAD_RIGHT) {
      if (this.surfaceFocused) {
        this.noteUserActivity();
        this.pressArrow(code);
        return true;
      }
      return false;
    }
    if (code === KeyCode.KEYCODE_DPAD_UP) {
      this.showChrome();
      return true;
    }
    if (code === KeyCode.KEYCODE_DPAD_DOWN) {
      this.openPanel();
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

  // MARK: - 拖动与连发快进（T028：点按 ±10s；长按 0.4s 起步 20×→40×→80×→160× 松手跳落点）

  /** 按下左右键：先立门槛计时；期间一直按着才升级成长按拖动 */
  private pressArrow(code: number): void {
    if (this.arrowHeld !== 0) {
      // 已在按住另一方向（系统连发 Down 事件）：不重置节奏
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

  /** 松开左右键：长按拖动跳到落点；没到门槛 = 点按，跳 10 秒 */
  private releaseArrow(): void {
    const held: number = this.arrowHeld;
    this.arrowHeld = 0;
    if (this.holdArmTimer >= 0) {
      clearTimeout(this.holdArmTimer);
      this.holdArmTimer = -1;
    }
    if (this.scrubRate !== 0 || (this.scrubMs >= 0 && this.holdTickTimer >= 0)) {
      // 长按拖动结束：跳到落点继续播放
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

  /** 过了长按门槛：落点从当前位置起步，100ms 节拍按倍速推进 */
  private beginHoldScrub(): void {
    const engine: TvAvPlayerEngine | null = this.engine;
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
    const engine: TvAvPlayerEngine | null = this.engine;
    if (engine === null || this.scrubMs < 0) {
      this.stopHoldTick();
      return;
    }
    const heldMs: number = Date.now() - this.holdStartAt;
    const direction: number = this.arrowHeld === KeyCode.KEYCODE_DPAD_LEFT ? -1 : 1;
    const rate: number = TvHoldScrub.rate(heldMs) * direction;
    this.scrubRate = rate;
    // 每拍 100ms：落点按「片内秒数/秒」推进，夹在片长内
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

  /** 取消拖动：长按中按返回、离开页面——丢掉落点回原处（画面没动过） */
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

  // MARK: - 指针滑动拖动（T028：满屏一划 ≈ 片长 1/5，夹在 1~15 分钟，松手才跳）

  private beginSwipeScrub(): void {
    const engine: TvAvPlayerEngine | null = this.engine;
    if (engine === null || engine.durationMs <= 0 || this.isModal() || this.panelOpen
      || this.scrubMs >= 0) {
      return;
    }
    this.noteUserActivity();
    this.scrubBase = engine.positionMs;
    this.scrubMs = this.scrubBase;
    this.showChrome();
  }

  private updateSwipeScrub(offsetX: number): void {
    const engine: TvAvPlayerEngine | null = this.engine;
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
      // 长按拖动途中的滑动不算（按边缘时手指带出来的）
      return;
    }
    const target: number = this.scrubMs;
    this.scrubMs = -1;
    this.eng().seekTo(target);
    this.showChrome();
  }

  // MARK: - 进度条缩略图（T028 trickplay）

  /** 从已签名的取流地址里取 token（缩略图索引 / 雪碧图复用同一份授权） */
  private streamToken(): string {
    const engine: TvAvPlayerEngine | null = this.engine;
    const view: PlaybackSessionView | null = engine !== null ? engine.session : null;
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

  /**
   * 缩略图索引：开会话时服务端才在后台生成，没就绪就隔一阵再问
   * （最多 6 次、间隔 30 秒，失败无所谓）。换会话/换集重新来。
   */
  private loadTrickplay(): void {
    const api: MovieClawApi | null = AppModel.shared.api;
    const engine: TvAvPlayerEngine | null = this.engine;
    const view = engine !== null ? engine.session : null;
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

  private pollTrickplay(api: MovieClawApi, gen: number, fileId: number,
    token: string, attempt: number): void {
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

  /** 拖动落点该显示的缩略图格子（雪碧图还没下完返回 null，只显示时间） */
  private scrubTile(): image.PixelMap | null {
    if (this.scrubMs < 0) {
      return null;
    }
    return this.trickplay.tileAt(this.scrubMs, AppModel.origin());
  }

  /**
   * 换会话/换集/重协商：缩略图索引重新取（文件变了落点格子也变了）。
   *
   * 原来用 `@Monitor('engine.session')`，但 `engine` 初始为 null，V2 在组件初始化时
   * 找不到这条路径（日志：`@Monitor path 'engine.session' - initialize not found`），
   * 监视器永远不触发。改为 100ms 时钟里比对会话标识，简单可靠。
   */
  private syncSessionTrickplay(): void {
    const engine: TvAvPlayerEngine | null = this.engine;
    const view: PlaybackSessionView | null = engine !== null ? engine.session : null;
    const id: string = view !== null
      ? `${view.session_id ?? ''}@${view.decision.file_id ?? 0}`
      : '';
    if (id === this.lastSessionId) {
      return;
    }
    this.lastSessionId = id;
    // 自动跳过总开关随会话下发（旧服务端没有就按默认开）
    const auto: PlaybackAutoSkipView | null = view !== null ? view.auto_skip ?? null : null;
    this.autoSkipEnabled = auto !== null ? auto.enabled : true;
    // 换集后「本集处理过的段」重新开始算
    const episode: number = engine !== null ? engine.currentEpisode : 0;
    if (episode !== this.skipHandledEpisode) {
      this.skipHandledEpisode = episode;
      this.skipHandled = [];
    }
    this.loadTrickplay();
  }

  /**
   * 自动跳过片头/广告/预告：自然播进区间就跳到区间尾（同手机端 evaluateAutoSkip）。
   * 每段只自动跳一次——用户拖回去重看时只保留「跳过」按钮，不再硬拽。
   * 片尾（outro + to_end）不进这里：由「下一集」卡片倒计时自动连播处理。
   */
  private evaluateAutoSkip(): void {
    const engine: TvAvPlayerEngine | null = this.engine;
    if (engine === null || this.panelOpen || this.scrubMs >= 0 || this.isModal()) {
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
    hilog.info(0x0000, 'DbgSkip', 'AUTO_SKIP type=%{public}s start=%{public}d end=%{public}d',
      segment.type, segment.start_ms, segment.end_ms);
    engine.seekTo(segment.end_ms);
    this.showChrome();
  }

  // MARK: - chrome 显隐

  private chromeMustStay(): boolean {
    const engine: TvAvPlayerEngine | null = this.engine;
    if (engine === null) {
      return true;
    }
    // 暂停时用户在找进度；面板开着；拖动中
    return engine.phase === TvPlayPhase.paused || this.panelOpen || this.scrubMs >= 0;
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

  // MARK: - 信息面板

  /**
   * 安全请求焦点：requestFocus 对「祖先不可获焦 / 节点未挂树」会抛异常，
   * 而这里都在定时器回调里——不接住就直接进程崩溃（实测 150002）。
   * 焦点失败只是走焦不理想，不该让播放器退出。
   */
  private requestFocusSafe(key: string): void {
    TvFocus.request(this.getUIContext(), key);
  }

  private openPanel(): void {
    const engine: TvAvPlayerEngine | null = this.engine;
    if (engine === null || engine.session === null || this.isModal()) {
      return;
    }
    this.panelOpen = true;
    this.showChrome();
    // 焦点落字幕列当前选中行（面板行刚挂载，稍等再定位才可靠）
    setTimeout((): void => {
      if (this.panelOpen) {
        this.requestFocusSafe(this.subtitleRowKey());
      }
    }, 140);
    // 选集列直接定位到正在播的那一集（长剧集不用从头滚）
    if (this.hasEpisodePicker()) {
      setTimeout((): void => {
        if (!this.panelOpen) {
          return;
        }
        const current: number = this.eng().currentEpisode;
        const index: number = this.eng().episodes
          .findIndex((episode: EpisodeView): boolean => episode.episode_number === current);
        if (index >= 0) {
          this.episodeScroller.scrollToIndex(index, true, ScrollAlign.CENTER);
        }
      }, 180);
    }
  }

  private closePanel(): void {
    this.panelOpen = false;
    setTimeout((): void => {
      this.requestFocusSafe('tv_player_root');
    }, 60);
  }

  /** 字幕列的行 key：第 0 行「关闭」，选项 1..n（焦点落打开面板那一刻的选中行） */
  private subtitleRowKey(): string {
    const engine: TvAvPlayerEngine | null = this.engine;
    if (engine === null) {
      return 'tv_panel_subtitle_0';
    }
    const index: number = engine.selectedSubtitleIndex;
    return `tv_panel_subtitle_${index + 1}`;
  }

  // MARK: - 轨道 / 画质选择（选中即生效，面板保持打开）

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
    const engine: TvAvPlayerEngine | null = this.engine;
    if (engine === null) {
      return false;
    }
    return engine.phase === TvPlayPhase.error || engine.phase === TvPlayPhase.consent
      || this.asksStillWatching();
  }

  /** 连播满上限后放完：不自动接，问一句「还在看吗」 */
  private asksStillWatching(): boolean {
    const engine: TvAvPlayerEngine | null = this.engine;
    const request: TvPlayRequest | null = this.ui.playerRequest;
    if (engine === null || request === null || !request.autoAdvance) {
      return false;
    }
    return engine.phase === TvPlayPhase.ended && engine.nextEpisode() !== null
      && this.autoNextStreak >= TvSkipSegments.autoNextMaxStreak;
  }

  /** 「即将播放」卡片可不可见（对话框占着时不给；「观看片尾」按过收起） */
  private showsUpNext(): boolean {
    const engine: TvAvPlayerEngine | null = this.engine;
    if (engine === null || this.isModal() || this.nextDismissed) {
      return false;
    }
    if (engine.nextEpisode() === null) {
      return false;
    }
    return TvSkipSegments.shouldShowUpNext(engine.segments(), engine.positionMs,
      engine.phase === TvPlayPhase.ended);
  }

  /** 卡片要不要倒计时自动播下一集（连播关了不倒计时；满上限不倒计时） */
  private autoNextArmed(): boolean {
    const engine: TvAvPlayerEngine | null = this.engine;
    const request: TvPlayRequest | null = this.ui.playerRequest;
    if (engine === null || request === null || !request.autoAdvance) {
      return false;
    }
    if (!this.showsUpNext() || this.autoNextCancelled) {
      return false;
    }
    return TvSkipSegments.autoNextArmed(engine.segments(), engine.positionMs,
      this.autoNextStreak, engine.phase === TvPlayPhase.ended);
  }

  /** 右下角当前该显示的「跳过」段（无 = null） */
  private activeSkipSeg(): PlaybackSegmentView | null {
    const engine: TvAvPlayerEngine | null = this.engine;
    return engine !== null ? engine.activeSkipSegment() : null;
  }

  private pausedVisible(): boolean {
    const engine: TvAvPlayerEngine | null = this.engine;
    if (engine === null) {
      return false;
    }
    return engine.phase === TvPlayPhase.paused && engine.positionMs > 0 && !this.isModal();
  }

  private busyVisible(): boolean {
    const engine: TvAvPlayerEngine | null = this.engine;
    if (engine === null || this.isModal()) {
      return false;
    }
    return engine.phase === TvPlayPhase.negotiating
      || (engine.buffering && (engine.phase === TvPlayPhase.playing
        || engine.phase === TvPlayPhase.paused));
  }

  private busyLabel(): string {
    const engine: TvAvPlayerEngine | null = this.engine;
    if (engine !== null && engine.phase === TvPlayPhase.negotiating) {
      return '正在打开…';
    }
    return '正在缓冲…';
  }

  // MARK: - 自动连播节拍（100ms 钟：倒计时 + 情境焦点）

  private startClock(): void {
    if (this.clockTimer >= 0) {
      return;
    }
    this.clockTimer = setInterval((): void => {
      this.syncSessionTrickplay();
      this.evaluateAutoSkip();
      this.tickAutoNext();
      this.refreshContextualFocus();
    }, 100);
  }

  private tickAutoNext(): void {
    const engine: TvAvPlayerEngine | null = this.engine;
    if (engine === null) {
      return;
    }
    if (!this.autoNextArmed()) {
      this.autoNextProgress = 0;
      return;
    }
    // 暂停时不走；播完照走（片尾短于倒计时时不能卡在最后一帧）
    if (engine.phase !== TvPlayPhase.playing && engine.phase !== TvPlayPhase.ended) {
      return;
    }
    this.autoNextProgress = Math.min(1,
      this.autoNextProgress + 100 / TvSkipSegments.autoNextMs);
    if (this.autoNextProgress < 1) {
      return;
    }
    this.autoNextProgress = 0;
    this.autoNextStreak += 1;
    engine.playNext();
    this.resetUpNextState();
  }

  /** 右下角元素 / 对话框出现时显式抢焦点，消失时还给画面 */
  private refreshContextualFocus(): void {
    let target: string = '';
    const engine: TvAvPlayerEngine | null = this.engine;
    if (engine !== null && !this.panelOpen) {
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
    // 目标还没挂载稳，稍等再定位；收掉时焦点还给根画面
    const finalKey: string = target.length > 0 ? target
      : (previous.length > 0 ? 'tv_player_root' : '');
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

  /** 收起「下一集」卡片接着放片尾（播完卡片会再出来） */
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
    // 手动跳过片头 = 这部剧「学过」了：告诉服务端，以后自动跳过（同手机端）
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

  // MARK: - 返回键分级（TvUiState.handleBack 委托）

  private handleBack(): boolean {
    this.noteUserActivity();
    if (this.scrubMs >= 0) {
      // 拖动/长按快进中按返回：取消拖动回原处（画面没动过，丢掉落点即可）
      this.cancelScrub();
      return true;
    }
    if (this.panelOpen) {
      this.closePanel();
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
    const request: TvPlayRequest | null = this.ui.playerRequest;
    const base: string = request !== null ? request.title : '播放';
    const engine: TvAvPlayerEngine | null = this.engine;
    if (engine !== null && engine.currentSeason > 0 && engine.currentEpisode > 0) {
      return `${base} · 第 ${engine.currentSeason} 季第 ${engine.currentEpisode} 集`;
    }
    return base;
  }

  private panelHintLine(): string {
    const parts: string[] = [];
    if (this.hasEpisodePicker()) {
      parts.push('选集');
    }
    parts.push('字幕');
    if (this.audioTracksList().length > 1) {
      parts.push('音轨');
    }
    parts.push('画质');
    return parts.join(' · ');
  }

  private subtitlePlansList(): SubtitlePlanView[] {
    const engine: TvAvPlayerEngine | null = this.engine;
    return engine !== null ? engine.subtitlePlans() : [];
  }

  private audioTracksList(): AudioTrackView[] {
    const engine: TvAvPlayerEngine | null = this.engine;
    return engine !== null ? engine.audioTracks() : [];
  }

  /** 「关闭」行打勾条件：没选任何外挂轨且当前流没烧录字幕 */
  private subtitleOffActive(): boolean {
    const engine: TvAvPlayerEngine | null = this.engine;
    return engine !== null && engine.selectedSubtitleIndex < 0
      && engine.burnedSubtitleRef().length === 0;
  }

  private subtitleActiveAt(index: number): boolean {
    const engine: TvAvPlayerEngine | null = this.engine;
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
    const left: number = TvSkipSegments.autoNextMs * (1 - this.autoNextProgress) / 1000;
    return `即将播放 · ${Math.max(1, Math.ceil(left))} 秒`;
  }

  private upNextStillUrl(next: EpisodeView): string {
    const resolved: string | null = ImageUrls.resolve(AppModel.origin(),
      next.still_url ?? null, null);
    return resolved !== null ? resolved : '';
  }

  private consentMessage(): string {
    const engine: TvAvPlayerEngine | null = this.engine;
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
    const request: TvPlayRequest | null = this.ui.playerRequest;
    const title: string = request !== null ? request.title : '这部影片';
    return `还在看《${title}》吗？`;
  }

  // MARK: - 进度条取值（拖动中一律读落点，同参考端 TVTransportBar 的 scrubMs 口径）

  /** 时间轴上的「当前位置」：拖动中 = 落点，平时 = 播放位置 */
  private timelineMs(): number {
    const engine: TvAvPlayerEngine | null = this.engine;
    if (this.scrubMs >= 0) {
      return this.scrubMs;
    }
    return engine !== null ? engine.positionMs : 0;
  }

  private playedPct(): string {
    const engine: TvAvPlayerEngine | null = this.engine;
    if (engine === null || engine.durationMs <= 0) {
      return '0%';
    }
    const fraction: number = Math.max(0, Math.min(1, this.timelineMs() / engine.durationMs));
    return `${(fraction * 100).toFixed(2)}%`;
  }

  private bufferedPct(): string {
    const engine: TvAvPlayerEngine | null = this.engine;
    if (engine === null || engine.durationMs <= 0 || engine.bufferedEndMs <= 0) {
      return '0%';
    }
    const fraction: number = Math.max(0, Math.min(1, engine.bufferedEndMs / engine.durationMs));
    return `${(fraction * 100).toFixed(2)}%`;
  }

  /** 可跳段（片头/片尾）在进度条上的亮条（拖动时一眼看出哪截是片头） */
  private segmentPct(segment: PlaybackSegmentView): string {
    const engine: TvAvPlayerEngine | null = this.engine;
    if (engine === null || engine.durationMs <= 0) {
      return '0%';
    }
    const from: number = Math.max(0, Math.min(engine.durationMs, segment.start_ms));
    const to: number = Math.max(0, Math.min(engine.durationMs, segment.end_ms));
    const fraction: number = Math.max(0, (to - from) / engine.durationMs);
    return `${(fraction * 100).toFixed(2)}%`;
  }

  private segmentLeftPct(segment: PlaybackSegmentView): string {
    const engine: TvAvPlayerEngine | null = this.engine;
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
    const engine: TvAvPlayerEngine | null = this.engine;
    if (engine === null) {
      return '-0:00';
    }
    const left: number = Math.max(0, engine.durationMs - this.timelineMs());
    return `-${Formatters.clock(left / 1000)}`;
  }

  // MARK: - 画面尺寸（按视频宽高比 fit，双向夹紧）

  private fitWidth(): number {
    const engine: TvAvPlayerEngine | null = this.engine;
    const aspect: number = engine !== null ? engine.videoAspect : 0;
    if (aspect <= 0) {
      return this.pageWidth > 0 ? this.pageWidth : 1920;
    }
    if (this.pageWidth <= 0 || this.pageHeight <= 0) {
      return this.pageHeight > 0 ? this.pageHeight * aspect : 1920;
    }
    return Math.min(this.pageWidth, this.pageHeight * aspect);
  }

  private fitHeight(): number {
    const engine: TvAvPlayerEngine | null = this.engine;
    const aspect: number = engine !== null ? engine.videoAspect : 0;
    if (aspect <= 0) {
      return this.pageHeight > 0 ? this.pageHeight : 1080;
    }
    return this.fitWidth() / aspect;
  }

  // MARK: - 布局

  build() {
    Stack() {
      this.videoSurface()
      if (this.pausedVisible()) {
        this.pausedOverlay()
      }
      if (this.engine !== null && this.eng().subtitleCue.length > 0) {
        this.subtitleOverlay()
      }
      if (this.chromeVisible && !this.panelOpen) {
        this.chromeBar()
      }
      if (this.scrubMs >= 0) {
        this.scrubHud()
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
    .onAreaChange((oldArea: Area, newArea: Area): void => {
      this.pageWidth = Number(newArea.width);
      this.pageHeight = Number(newArea.height);
    })
    .onClick((event: ClickEvent): void => {
      // 指针遥控点画面 = 播放/暂停。点击会一路冒到根，ClickEvent 又没有
      // stopPropagation——用 target.id 判定：只有真正点在画面上（target 是根
      // 自己，各显示层都 hitTestBehavior(None) 穿透）才 toggle；
      // 面板行 / 对话框 / 右下角按钮的点击 target 不是根，走它们自己的 onClick。
      if (event.target.id !== 'tv_player_root') {
        return;
      }
      this.noteUserActivity();
      this.eng().togglePlay();
      this.showChrome();
    })
    // 触控板/指针横向滑动 = 拖进度（T028）：满屏一划 ≈ 片长 1/5（夹 1~15 分钟），松手才跳
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

  /** 视频面：XComponent(SURFACE)，按视频宽高比完整放入屏幕 */
  @Builder
  private videoSurface(): void {
    XComponent({
      id: 'tv_player_surface',
      type: XComponentType.SURFACE,
      controller: this.surfaceController
    })
      .width(this.fitWidth())
      .height(this.fitHeight())
      // SURFACE 型 XComponent 会消费触摸（真机实测），画面不需要触摸，交给根处理
      .hitTestBehavior(HitTestMode.None)
      .onLoad((): void => {
        this.surfaceId = this.surfaceController.getXComponentSurfaceId();
        const engine: TvAvPlayerEngine | null = this.engine;
        if (engine !== null) {
          engine.start(this.surfaceId);
        }
      })
  }

  /** 暂停遮罩：只跟「用户暂停」走，左上角大标题（同 tvOS PausedOverlay） */
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
      colors: [['rgba(0, 0, 0, 0.5)', 0.0], ['rgba(0, 0, 0, 0.18)', 0.4],
        ['rgba(0, 0, 0, 0.65)', 1.0]]
    })
    .hitTestBehavior(HitTestMode.None)
  }

  /** 系统字幕回调的文本层（引擎经 addSubtitleFromUrl 选轨后由 AVPlayer 吐出） */
  @Builder
  private subtitleOverlay(): void {
    Column() {
      Blank()
      Text(this.eng().subtitleCue)
        .fontSize(26)
        .fontColor('#ffffff')
        .textAlign(TextAlign.Center)
        .backgroundColor('rgba(0, 0, 0, 0.55)')
        .borderRadius(8)
        .padding({ left: 18, right: 18, top: 6, bottom: 6 })
        .constraintSize({ maxWidth: '70%' })
        .margin({ bottom: this.chromeVisible ? 170 : 110 })
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .hitTestBehavior(HitTestMode.None)
  }

  /** 传输条（chrome）：顶部面板提示 + 底部片名/双层进度/时间行 */
  @Builder
  private chromeBar(): void {
    Column() {
      if (this.eng().session !== null && this.eng().phase !== TvPlayPhase.paused) {
        Column({ space: 5 }) {
          Text('∨')
            .fontSize(20)
            .fontWeight(700)
            .fontColor('rgba(255, 255, 255, 0.7)')
          Text(this.panelHintLine())
            .fontSize(14)
            .fontColor('rgba(255, 255, 255, 0.6)')
        }
        .alignItems(HorizontalAlign.Center)
        .margin({ top: 40 })
      }
      Blank()
      Column({ space: 18 }) {
        Text(this.titleLine())
          .fontSize(TvType.playerTitle)
          .fontWeight(700)
          .fontColor('rgba(255, 255, 255, 0.92)')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
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
          // 拖动中的播放头圆点（贴着已播白条前沿，同参考端 TVTransportBar）
          if (this.scrubMs >= 0) {
            Column()
              .width(26)
              .height(26)
              .borderRadius(13)
              .backgroundColor('#ffffff')
              .markAnchor({ x: 13, y: 13 })
              .position({ x: this.playedPct(), y: 4 })
          }
        }
        .width('100%')
        .height(8)
        Row() {
          Text(this.currentClock())
            .fontSize(TvType.playerTime)
            .fontColor('rgba(255, 255, 255, 0.8)')
          Blank()
          Text(this.remainingClock())
            .fontSize(TvType.playerTime)
            .fontColor('rgba(255, 255, 255, 0.8)')
        }
        .width('100%')
      }
      .width('100%')
      .padding({
        left: TvMetrics.playerInset,
        right: TvMetrics.playerInset,
        bottom: 44
      })
      .linearGradient({
        angle: 180,
        colors: [['rgba(0, 0, 0, 0)', 0.0], ['rgba(0, 0, 0, 0.78)', 0.5],
          ['rgba(0, 0, 0, 0.9)', 1.0]]
      })
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .hitTestBehavior(HitTestMode.None)
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
        .fontSize(TvType.body)
        .fontColor('rgba(255, 255, 255, 0.85)')
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }

  /** 浮层左缘的横坐标：跟着播放头、贴两端夹紧（参考端同款钳制） */
  private scrubHudX(): number {
    const engine: TvAvPlayerEngine | null = this.engine;
    const pageWidth: number = this.pageWidth > 0 ? this.pageWidth : 1920;
    const duration: number = engine !== null ? engine.durationMs : 0;
    if (duration <= 0) {
      return TvMetrics.playerInset;
    }
    const fraction: number = Math.max(0, Math.min(1, this.timelineMs() / duration));
    const playheadX: number = TvMetrics.playerInset
      + fraction * (pageWidth - 2 * TvMetrics.playerInset);
    const min: number = TvMetrics.playerInset;
    const max: number = Math.max(min, pageWidth - TvMetrics.playerInset - 360);
    return Math.max(min, Math.min(max, playheadX - 160));
  }

  /**
   * 拖动/长按快进浮层（T028）：落点 trickplay 缩略图 + 目标时间
   * （长按时两侧带「◀◀ 40× / 40× ▶▶」倍速徽标），贴在传输条上方。
   */
  @Builder
  private scrubHud(): void {
    Column({ space: 10 }) {
      if (this.trickplayVersion >= 0 && this.scrubTile() !== null) {
        Image(this.scrubTile() as image.PixelMap)
          .autoResize(true)
          .width(320)
          .borderRadius(12)
          .clip(true)
      }
      Row({ space: 12 }) {
        if (this.scrubRate < 0) {
          Text('◀◀')
            .fontSize(20)
            .fontWeight(700)
            .fontColor('rgba(255, 255, 255, 0.85)')
          Text(`${Math.abs(this.scrubRate)}×`)
            .fontSize(22)
            .fontWeight(600)
            .fontColor('rgba(255, 255, 255, 0.85)')
        }
        Text(Formatters.clock(this.scrubMs / 1000))
          .fontSize(22)
          .fontWeight(600)
          .fontColor('#ffffff')
        if (this.scrubRate > 0) {
          Text(`${this.scrubRate}×`)
            .fontSize(22)
            .fontWeight(600)
            .fontColor('rgba(255, 255, 255, 0.85)')
          Text('▶▶')
            .fontSize(20)
            .fontWeight(700)
            .fontColor('rgba(255, 255, 255, 0.85)')
        }
      }
      .alignItems(VerticalAlign.Center)
    }
    .alignItems(HorizontalAlign.Center)
    .position({ x: this.scrubHudX(), y: '100%' })
    .markAnchor({ x: 0, y: '100%' })
    .offset({ y: -190 })
    .hitTestBehavior(HitTestMode.None)
  }

  /**
   * 右下角情境元素（同一时刻只出一个）：跳过按钮 / 下一集卡。
   * 统一放进一个「贴底右对齐」的层里定位——不再用 position+markAnchor+offset 的
   * 组合（实测在 720vp 画布上会算偏，按钮压到进度条/时间行上）。
   * 该层本身 hitTest 穿透，只有按钮吃点击；空白处的点击照样回到根画面（播放/暂停）。
   */
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
        // chrome 打开时抬到进度条上方，收起时贴近底部
        .padding({ right: TvMetrics.playerInset, bottom: this.chromeVisible ? 150 : 44 })
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.Transparent)
    }
  }

  /** 跳过片头/片尾按钮：出现时自动拿焦点，按一下跳到这段结束处 */
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
      this.skipGlow(true);
    })
    .onBlur((): void => {
      this.skipGlow(false);
    })
    .onHover((isHover: boolean): void => {
      this.skipGlow(isHover);
    })
    .onClick((): void => {
      this.doSkip(segment);
    })
  }

  private skipGlow(glow: boolean): void {
    this.getUIContext().animateTo({ duration: 120 }, (): void => {
      this.skipHovered = glow;
    });
  }

  /** 「即将播放」下一集卡：剧照 + 集号/集名 + 倒计时秒数 + 下一集/观看片尾 */
  @Builder
  private upNextCard(next: EpisodeView): void {
    Column({ space: 20 }) {
      Row({ space: 22 }) {
        Column() {
          RemoteImage({ url: this.upNextStillUrl(next), placeholderText: '暂无剧照' })
        }
        .width(256)
        .height(144)
        .borderRadius(12)
        .clip(true)
        Column({ space: 6 }) {
          Text(this.upNextEyebrow())
            .fontSize(15)
            .fontWeight(600)
            .fontColor('rgba(255, 255, 255, 0.6)')
          Text(`第 ${next.episode_number} 集`)
            .fontSize(24)
            .fontWeight(700)
            .fontColor('#ffffff')
          if (next.name !== null && next.name !== undefined && next.name.length > 0) {
            Text(next.name)
              .fontSize(17)
              .fontColor('rgba(255, 255, 255, 0.65)')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .constraintSize({ maxWidth: 300 })
      }
      Row({ space: 16 }) {
        this.cornerPill('tv_player_upnext', this.autoNextArmed() ? '立即播放' : '下一集',
          (): void => {
            this.runPlayNext();
          })
        this.cornerPill('tv_player_credits', '观看片尾', (): void => {
          this.dismissUpNext();
        })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width(600)
    .padding({ left: 26, right: 26, top: 22, bottom: 22 })
    .backgroundColor('rgba(12, 14, 20, 0.86)')
    .borderRadius(TvMetrics.cardCorner)
    .border({ width: 1, color: 'rgba(255, 255, 255, 0.1)' })
  }

  /** 卡片上的两颗胶囊按钮（焦点/悬浮翻白） */
  @Builder
  private cornerPill(key: string, label: string, action: () => void): void {
    Text(label)
      .fontSize(20)
      .fontWeight(600)
      .fontColor(this.cornerPillGlow === key ? '#111319' : TvColors.text)
      .padding({ left: 30, right: 30, top: 11, bottom: 11 })
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

  /** 信息面板：选集（剧集）/字幕/音轨/画质 同屏（音轨一条以上才有音轨列） */
  @Builder
  private panelOverlay(): void {
    Column() {
      Row({ space: this.hasEpisodePicker() ? 44 : 60 }) {
        if (this.hasEpisodePicker()) {
          this.panelEpisodeColumn()
        }
        this.panelSubtitleColumn()
        if (this.audioTracksList().length > 1) {
          this.panelAudioColumn()
        }
        this.panelQualityColumn()
      }
      .width('100%')
      .padding({ left: 90, right: 90, top: 70, bottom: 36 })
      Blank()
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0, 0, 0, 0.55)')
  }

  /** 有分集可换：本季分集表已加载 */
  private hasEpisodePicker(): boolean {
    const engine: TvAvPlayerEngine | null = this.engine;
    return engine !== null && engine.currentSeason > 0 && engine.episodes.length > 0;
  }

  /** 选集列：本季每一集一行（剧照缩略图 + 集号/集名），选中即换集 */
  @Builder
  private panelEpisodeColumn(): void {
    Column({ space: 14 }) {
      Row({ space: 10 }) {
        Text('选集')
          .fontSize(30)
          .fontWeight(700)
          .fontColor(TvColors.text)
        Text(`第 ${this.eng().currentSeason} 季`)
          .fontSize(20)
          .fontColor('rgba(255, 255, 255, 0.4)')
      }
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
      .fadingEdge(false)
    }
    .layoutWeight(1)
    .height('100%')
    .alignItems(HorizontalAlign.Start)
  }

  private episodeStillUrl(episode: EpisodeView): string {
    const resolved: string | null = ImageUrls.resolve(AppModel.origin(),
      episode.still_url ?? null, null);
    if (resolved === null) {
      return '';
    }
    return `${resolved}${resolved.includes('?') ? '&' : '?'}w=300`;
  }

  /** 换集：关面板、清掉本集的跳过记账、让引擎重协商到这一集 */
  private pickEpisode(episodeNumber: number): void {
    const engine: TvAvPlayerEngine | null = this.engine;
    if (engine === null) {
      return;
    }
    if (episodeNumber === engine.currentEpisode) {
      this.closePanel();
      return;
    }
    this.noteUserActivity();
    this.panelOpen = false;
    this.skipHandled = [];
    engine.switchToEpisode(episodeNumber);
    this.showChrome();
    this.requestFocusSafe('tv_player_root');
  }

  @Builder
  private panelSubtitleColumn(): void {
    Column({ space: 14 }) {
      Row({ space: 10 }) {
        Text('字幕')
          .fontSize(30)
          .fontWeight(700)
          .fontColor(TvColors.text)
        Text(`${this.subtitlePlansList().length + 1}`)
          .fontSize(20)
          .fontColor('rgba(255, 255, 255, 0.4)')
      }
      List({ space: 2 }) {
        ListItem() {
          TvPanelOption({
            label: '关闭',
            detail: '',
            focusKey: 'tv_panel_subtitle_0',
            active: this.subtitleOffActive(),
            onPick: (): void => {
              this.pickSubtitle(-1);
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
    Column({ space: 14 }) {
      Row({ space: 10 }) {
        Text('音轨')
          .fontSize(30)
          .fontWeight(700)
          .fontColor(TvColors.text)
        Text(`${this.audioTracksList().length}`)
          .fontSize(20)
          .fontColor('rgba(255, 255, 255, 0.4)')
      }
      List({ space: 2 }) {
        ForEach(this.audioTracksList(), (track: AudioTrackView, index: number) => {
          ListItem() {
            TvPanelOption({
              label: this.audioLabel(track),
              detail: this.audioDetail(track),
              focusKey: `tv_panel_audio_${index}`,
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
    Column({ space: 14 }) {
      Row({ space: 10 }) {
        Text('画质')
          .fontSize(30)
          .fontWeight(700)
          .fontColor(TvColors.text)
        Text(`${TvQualityOption.all().length}`)
          .fontSize(20)
          .fontColor('rgba(255, 255, 255, 0.4)')
      }
      List({ space: 2 }) {
        ForEach(TvQualityOption.all(), (option: TvQualityOption, index: number) => {
          ListItem() {
            TvPanelOption({
              label: option.label,
              detail: option.hint,
              focusKey: `tv_panel_quality_${index}`,
              active: this.eng().maxHeight === option.maxHeight,
              onPick: (): void => {
                this.pickQuality(option.maxHeight);
              }
            })
          }
        }, (option: TvQualityOption, index: number) => `${option.maxHeight}_${index}`)
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

  // MARK: - 对话框（错误 / 同意 / 还在看吗）

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
