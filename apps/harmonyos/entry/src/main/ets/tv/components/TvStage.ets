/**
 * TV 大图区（对应参考端 DesignSystem/TVStage.swift），首页首屏与详情页首屏共用：
 * - TvStageBackdrop：整区背景——剧照铺满 + 交叉淡入（0.36s）+ 无操作 Ken Burns 慢推（40s/1.06×，US9）
 *   + 底部渐变过渡到页面底色 + 左侧压暗托字 + 大图预告画面层（焦点停稳 2s 后原地播一段，US9）；
 *   换图时旧图垫底、新图加载完成后淡入，划过不闪黑；
 * - TvStagePreviewSurface：大图预告的播出面（XComponent SURFACE + 独立小 AVPlayer）：
 *   clip 模式放预切小文件、seek 模式放原片流从 segment 起播，声音 1.5s 从 0 渐入，
 *   放完 1.2s 淡回剧照；不写观看记录（参考端 TVStagePreview 口径）；
 * - TvStageBlock：左下文案块——片名 Logo（加载中/失败回落文字）、事实行、规格小标签、
 *   「第 X 季第 Y 集」一行、简介、操作按钮行（TvPillButton）；
 * - TvStageAction：操作按钮的数据与回调。
 *
 * 布局自由度交给调用方：首页把 Backdrop 铺整页、Block 叠在内容行上方，
 * 详情页把 Backdrop 铺首屏、Block 贴底——两页的剧照与文字节奏完全一致。
 */
import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { TvColors } from '../theme/TvTheme';
import { TvMetrics } from '../theme/TvTheme';
import { TvType } from '../theme/TvTheme';
import { TvMotion } from '../theme/TvTheme';
import { RemoteImage } from '../../common/RemoteImage';
import { TvPillButton } from './TvCards';

/** 大图区操作按钮（继续播放/从头播放/收藏/标为已看……） */
export class TvStageAction {
  readonly key: string;
  readonly label: string;
  /** true = 实心浅底黑字（主操作） */
  readonly prominent: boolean;
  readonly icon: Resource | null;
  readonly onActivate: (() => void) | null;

  constructor(key: string, label: string, prominent: boolean,
    icon: Resource | null, onActivate: (() => void) | null) {
    this.key = key;
    this.label = label;
    this.prominent = prominent;
    this.icon = icon;
    this.onActivate = onActivate;
  }
}

/**
 * 大图预告的播出面（US9，参考端 TVStagePreview + TVPreviewHost）：
 * 一个独立的小 AVPlayer 挂自己的 XComponent SURFACE——clip 模式从 0 放预切小文件、
 * seek 模式从 startMs 放原片流；画面出了淡入 0.9s 盖上剧照，声音 1.5s 从 0 渐入，
 * 放完 1.2s 淡回剧照再交回调；放不了/被拆就静默收掉，保持剧照不提示。
 * 不建会话、不上报进度（预告不写观看记录）。
 */
@ComponentV2
export struct TvStagePreviewSurface {
  /** 已解析好的完整播放地址（非空才由父层挂载本组件） */
  @Param url: string = '';
  /** 起播毫秒（seek 模式 = segment.start_ms；clip 模式恒 0） */
  @Param startMs: number = 0;
  /** 放完（已淡回剧照） */
  @Param onEnded: (() => void) | null = null;
  /** 放不了（创建/解码失败）：父层记下这一部不再反复取 */
  @Param onFailed: (() => void) | null = null;

  /** 画面出了才淡入盖住剧照（放完/收掉时淡回） */
  @Local frameReady: boolean = false;
  private surfaceController: XComponentController = new XComponentController();
  private player: media.AVPlayer | null = null;
  /** 代际：拆掉后迟到的异步回调全部作废 */
  private generation: number = 0;
  private volumeTimer: number = -1;
  private endTimer: number = -1;

  aboutToDisappear(): void {
    this.teardown();
  }

  build() {
    XComponent({
      id: 'tv_stage_preview_surface',
      type: XComponentType.SURFACE,
      controller: this.surfaceController
    })
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.None)
      .opacity(this.frameReady ? 1 : 0)
      .onLoad((): void => {
        this.boot(this.surfaceController.getXComponentSurfaceId());
      })
  }

  /** 建播放器 → 设画面 → 装载到起点；代际护住创建期间的拆除 */
  private async boot(surfaceId: string): Promise<void> {
    if (surfaceId.length === 0) {
      return;
    }
    const generation: number = ++this.generation;
    let player: media.AVPlayer;
    try {
      player = await media.createAVPlayer();
    } catch (error) {
      this.fail();
      return;
    }
    if (generation !== this.generation) {
      try {
        await player.release();
      } catch (error) {
      }
      return;
    }
    this.player = player;
    player.videoScaleType = media.VideoScaleType.VIDEO_SCALE_TYPE_FIT_CROP;
    player.on('stateChange', (state: media.AVPlayerState, reason: media.StateChangeReason): void => {
      if (generation !== this.generation) {
        return;
      }
      if (state === 'initialized') {
        player.surfaceId = surfaceId;
        player.prepare();
      } else if (state === 'prepared') {
        // 先静音再起播：声音 1.5s 渐入（原片中间常是一句对白）
        try {
          player.setVolume(0);
        } catch (error) {
        }
        if (this.startMs > 0) {
          player.seek(this.startMs, media.SeekMode.SEEK_CLOSEST);
        }
        player.play();
        this.rampVolume(player);
      } else if (state === 'playing') {
        if (!this.frameReady) {
          this.getUIContext().animateTo(
            { duration: 900, curve: Curve.EaseOut },
            (): void => {
              this.frameReady = true;
            });
        }
      } else if (state === 'completed') {
        this.finish();
      } else if (state === 'error') {
        this.fail();
      }
    });
    player.on('error', (error: BusinessError): void => {
      if (generation === this.generation) {
        this.fail();
      }
    });
    player.url = this.url;
  }

  /** 声音 1.5 秒内从 0 渐入到原音量（15 步 × 100ms） */
  private rampVolume(player: media.AVPlayer): void {
    if (this.volumeTimer >= 0) {
      clearInterval(this.volumeTimer);
    }
    let step: number = 0;
    this.volumeTimer = setInterval((): void => {
      step++;
      if (step > 15 || this.player !== player) {
        clearInterval(this.volumeTimer);
        this.volumeTimer = -1;
        return;
      }
      try {
        player.setVolume(step / 15);
      } catch (error) {
      }
    }, 100);
  }

  /** 放完：1.2s 淡回剧照，走完再交页面收尾（不硬切） */
  private finish(): void {
    this.getUIContext().animateTo(
      { duration: 1200, curve: Curve.EaseInOut },
      (): void => {
        this.frameReady = false;
      });
    if (this.endTimer >= 0) {
      clearTimeout(this.endTimer);
    }
    this.endTimer = setTimeout((): void => {
      this.endTimer = -1;
      const cb = this.onEnded;
      if (cb !== null) {
        cb();
      }
    }, 1250);
  }

  /** 放不了：静默收掉（保持剧照、不提示），交父层记「这一部不再取」 */
  private fail(): void {
    this.teardown();
    const cb = this.onFailed;
    if (cb !== null) {
      cb();
    }
  }

  /** 拆掉这一轮：迟到的回调全部作废、播放器停声释放 */
  private teardown(): void {
    this.generation++;
    if (this.volumeTimer >= 0) {
      clearInterval(this.volumeTimer);
      this.volumeTimer = -1;
    }
    if (this.endTimer >= 0) {
      clearTimeout(this.endTimer);
      this.endTimer = -1;
    }
    const player: media.AVPlayer | null = this.player;
    this.player = null;
    if (player !== null) {
      try {
        player.stop();
      } catch (error) {
      }
      player.release().catch((): void => {
      });
    }
    this.frameReady = false;
  }
}

/**
 * 大图区背景：剧照铺满（Cover）、交叉淡入、底部渐变到页面底色。
 * 占满父容器（父容器决定铺多大）。
 */
@ComponentV2
export struct TvStageBackdrop {
  /** 已解析的剧照 URL；空串 = 无图（只铺底色与渐变） */
  @Param imageUrl: string = '';
  /** 无操作 Ken Burns 慢推（首页开、详情页关） */
  @Param kenBurns: boolean = false;
  /** 大图预告：已解析好的完整播放地址；空串 = 不挂预告画面层 */
  @Param previewUrl: string = '';
  /** 大图预告起播毫秒（seek 模式；clip 恒 0） */
  @Param previewStartMs: number = 0;
  @Param onPreviewEnded: (() => void) | null = null;
  @Param onPreviewFailed: (() => void) | null = null;

  @Local currentUrl: string = '';
  @Local previousUrl: string = '';
  @Local currentOpacity: number = 0;
  /** Ken Burns：当前图的推近倍数（换图重开）、旧图冻结在淡出前的高度 */
  @Local currentZoom: number = 1;
  @Local previousZoom: number = 1;
  private cleanupId: number = -1;

  aboutToAppear(): void {
    this.currentUrl = this.imageUrl;
    this.currentOpacity = 0;
  }

  aboutToDisappear(): void {
    if (this.cleanupId >= 0) {
      clearTimeout(this.cleanupId);
      this.cleanupId = -1;
    }
  }

  /** 换图：旧图垫底（冻结在当前推近倍数），新图加载完成后淡入盖上来 */
  @Monitor('imageUrl')
  private onImageUrlChange(): void {
    if (this.cleanupId >= 0) {
      clearTimeout(this.cleanupId);
      this.cleanupId = -1;
    }
    if (this.imageUrl === this.currentUrl) {
      return;
    }
    this.previousUrl = this.currentUrl;
    this.previousZoom = this.currentZoom;
    this.currentUrl = this.imageUrl;
    this.currentZoom = 1;
    this.currentOpacity = 0;
  }

  private onImageResult(ok: boolean): void {
    if (this.currentUrl === '') {
      return;
    }
    if (!ok) {
      // 加载失败：新图层保持透明，继续露旧图或底色
      this.getUIContext().animateTo(
        { duration: TvMotion.crossfadeMs, curve: Curve.EaseOut },
        (): void => {
          this.currentOpacity = 0;
        });
      return;
    }
    this.getUIContext().animateTo(
      { duration: TvMotion.crossfadeMs, curve: Curve.EaseOut },
      (): void => {
        this.currentOpacity = 1;
      });
    if (this.kenBurns) {
      // 无操作慢推（Ken Burns）：新图从原尺寸起，40 秒匀速推到 1.06 倍
      this.getUIContext().animateTo(
        { duration: TvMotion.kenBurnsMs, curve: Curve.Linear },
        (): void => {
          this.currentZoom = TvMotion.kenBurnsScale;
        });
    }
    this.cleanupId = setTimeout(() => {
      this.cleanupId = -1;
      this.previousUrl = '';
    }, TvMotion.crossfadeMs + 60);
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.previousUrl !== '') {
        Stack() {
          RemoteImage({ url: this.previousUrl, placeholderText: '' })
        }
        .width('100%')
        .height('100%')
        .scale({ x: this.previousZoom, y: this.previousZoom })
      }
      if (this.currentUrl !== '') {
        Stack() {
          RemoteImage({
            url: this.currentUrl,
            placeholderText: '',
            onResult: (ok: boolean): void => {
              this.onImageResult(ok);
            }
          })
        }
        .width('100%')
        .height('100%')
        .opacity(this.currentOpacity)
        .scale({ x: this.currentZoom, y: this.currentZoom })
      }
      // 大图预告画面层（焦点停稳 2s 后父层挂上来）：在剧照之上、压暗与渐变之下
      if (this.previewUrl !== '') {
        TvStagePreviewSurface({
          url: this.previewUrl,
          startMs: this.previewStartMs,
          onEnded: (): void => {
            const cb = this.onPreviewEnded;
            if (cb !== null) {
              cb();
            }
          },
          onFailed: (): void => {
            const cb = this.onPreviewFailed;
            if (cb !== null) {
              cb();
            }
          }
        })
      }
      // 底部渐变：向页面底色过渡，内容行落上来
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [[TvColors.scrimTop, 0.38], [TvColors.scrimMid, 0.68], [TvColors.scrimBottom, 1]]
        })
      // 左侧压暗托字
      Column()
        .width('55%')
        .height('100%')
        .linearGradient({
          angle: 90,
          colors: [['rgba(0, 0, 0, 0.4)', 0], ['rgba(0, 0, 0, 0)', 1]]
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(TvColors.bg)
  }
}

/**
 * 大图区左下文案块：片名（Logo/文字）→ 事实行 + 规格小标签 → 「第 X 季第 Y 集」→ 简介 → 按钮行。
 * 内容贴底排（justifyContent End），占满父容器；父容器决定整块的高度与位置。
 */
@ComponentV2
export struct TvStageBlock {
  @Param title: string = '';
  /** 已解析的片名 Logo URL；空串 = 直接画文字 */
  @Param logoUrl: string = '';
  /** 加粗小字一行（「第 2 季 第 6 集 · 集名」） */
  @Param headline: string | null = null;
  /** 事实行（年份 · 类型 · 片长 / 季数） */
  @Param metaLine: string | null = null;
  /** 规格小标签（4K、HDR、杜比全景声……） */
  @Param badgeTexts: string[] = [];
  @Param overview: string | null = null;
  /** 简介最多几行：首页 2 行，详情页 3 行 */
  @Param overviewLines: number = 2;
  @Param actions: TvStageAction[] = [];
  /** 是否把第一个按钮设为默认焦点（详情页 true；首页默认焦点在「继续观看」卡上） */
  @Param defaultFocusFirstAction: boolean = false;
  @Param bottomInset: number = 20;

  @Local logoLoaded: boolean = false;

  @Monitor('logoUrl')
  private onLogoChange(): void {
    this.logoLoaded = false;
  }

  build() {
    Column() {
      // 片名：有 Logo 画 Logo（等比装进 574×133）；加载中/失败回落文字
      if (this.logoUrl !== '' && this.logoLoaded) {
        Stack() {
          RemoteImage({
            url: this.logoUrl,
            fit: true,
            onResult: (ok: boolean): void => {
              this.logoLoaded = ok;
            }
          })
        }
        .width(574)
        .height(133)
        .margin({ bottom: 18 })
      } else {
        this.TitleText()
      }

      // 事实行 + 规格小标签
      Row({ space: 8 }) {
        if (this.metaLine !== null) {
          Text(this.metaLine)
            .fontSize(18)
            .fontWeight(600)
            .fontColor(TvColors.text)
            .maxLines(1)
        }
        ForEach(this.badgeTexts, (badge: string) => {
          Text(badge)
            .fontSize(11)
            .fontWeight(700)
            .fontColor('rgba(243, 245, 249, 0.92)')
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(3)
            .border({ width: 1, color: 'rgba(255, 255, 255, 0.8)' })
        }, (badge: string) => badge)
      }
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: this.headline !== null ? 9 : 13 })

      if (this.headline !== null) {
        Text(this.headline)
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor('rgba(243, 245, 249, 0.85)')
          .maxLines(1)
          .margin({ bottom: 13 })
      }

      if (this.overview !== null && this.overview.length > 0) {
        Text(this.overview)
          .fontSize(17)
          .fontColor('rgba(243, 245, 249, 0.82)')
          .maxLines(this.overviewLines)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(24)
          .constraintSize({ maxWidth: 480 })
          .alignSelf(ItemAlign.Start)
      }

      if (this.actions.length > 0) {
        Row({ space: 12 }) {
          ForEach(this.actions, (action: TvStageAction, index: number) => {
            TvPillButton({
              label: action.label,
              prominent: action.prominent,
              icon: action.icon,
              defaultFocused: this.defaultFocusFirstAction && index === 0,
              onActivate: (): void => {
                const cb = action.onActivate;
                if (cb !== null) {
                  cb();
                }
              }
            })
          }, (action: TvStageAction) => action.key)
        }
        .alignItems(VerticalAlign.Center)
        .margin({ top: 24 })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.End)
    .width('100%')
    .height('100%')
    .padding({ left: TvMetrics.edge, right: TvMetrics.edge, bottom: this.bottomInset })
  }

  /** 文字版片名（无 Logo / Logo 未加载出） */
  @Builder
  private TitleText() {
    Text(this.title)
      .fontSize(TvType.heroTitle)
      .fontWeight(FontWeight.Bold)
      .fontColor(TvColors.text)
      .maxLines(1)
      .margin({ bottom: 18 })
  }
}
