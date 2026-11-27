/**
 * TV 大图区（首页首屏、发现首屏与详情页首屏共用）：
 * - TvStageBackdrop：剧照铺满 + 交叉淡入（0.36s）+ 无操作 Ken Burns 慢推（40s/1.06×）
 *   + AmbientColorStore 动态主色呼吸极光光晕 + 底部边缘色彩融合 + 大图预告画面层；
 * - TvStagePreviewSurface：大图预告的播出面（XComponent SURFACE + 独立小 AVPlayer）：
 *   clip 模式放预切小文件、seek 模式放原片流从 segment 起播，声音 1.5s 从 0 渐入，
 *   放完 1.2s 淡回剧照；不写观看记录；
 * - TvStageBlock：左下文案块——修复 ClearLogo 死锁（挂载透明加载、解码成功后交叉淡入替换文字标题、
 *   失败零占位回落文字）、事实行、规格小标签、分集标题、可聚焦展开完整剧情的简介、操作按钮行。
 */
import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AmbientColorStore } from '../../common/AmbientColor';
import { RemoteImage } from '../../common/RemoteImage';
import { TvColors, TvMetrics, TvMotion, TvType } from '../theme/TvTheme';
import { TvPillButton } from './TvCards';
import { TvFocusable } from './TvFocusable';

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
 * 大图预告的播出面（US9）：
 * 一个独立的小 AVPlayer 挂自己的 XComponent SURFACE——clip 模式从 0 放预切小文件、
 * seek 模式从 startMs 放原片流；画面出了淡入 0.9s 盖上剧照，声音 1.5s 从 0 渐入，
 * 放完或到 endMs 前 1.2s 淡回剧照再交回调。
 */
@ComponentV2
export struct TvStagePreviewSurface {
  @Param url: string = '';
  @Param startMs: number = 0;
  @Param endMs: number = 0;
  @Param onEnded: (() => void) | null = null;
  @Param onFailed: (() => void) | null = null;

  @Local frameReady: boolean = false;
  private surfaceController: XComponentController = new XComponentController();
  private player: media.AVPlayer | null = null;
  private generation: number = 0;
  private volumeTimer: number = -1;
  private endTimer: number = -1;
  private finishing: boolean = false;

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

  private async boot(surfaceId: string): Promise<void> {
    if (surfaceId.length === 0) {
      return;
    }
    const generation: number = ++this.generation;
    this.finishing = false;
    let player: media.AVPlayer;
    try {
      player = await media.createAVPlayer();
    } catch (_err) {
      this.fail();
      return;
    }
    if (generation !== this.generation) {
      try {
        await player.release();
      } catch (_err) {
      }
      return;
    }
    this.player = player;
    player.videoScaleType = media.VideoScaleType.VIDEO_SCALE_TYPE_FIT_CROP;
    player.on('timeUpdate', (timeMs: number): void => {
      if (generation !== this.generation || this.finishing) {
        return;
      }
      if (this.endMs > this.startMs && timeMs >= this.endMs) {
        this.finish();
      }
    });
    player.on('stateChange', (state: media.AVPlayerState, _reason: media.StateChangeReason): void => {
      if (generation !== this.generation) {
        return;
      }
      if (state === 'initialized') {
        player.surfaceId = surfaceId;
        player.prepare();
      } else if (state === 'prepared') {
        try {
          player.setVolume(0);
        } catch (_err) {
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
    player.on('error', (_error: BusinessError): void => {
      if (generation === this.generation) {
        this.fail();
      }
    });
    player.url = this.url;
  }

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
      } catch (_err) {
      }
    }, 100);
  }

  private finish(): void {
    if (this.finishing) {
      return;
    }
    this.finishing = true;
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

  private fail(): void {
    this.teardown();
    const cb = this.onFailed;
    if (cb !== null) {
      cb();
    }
  }

  private teardown(): void {
    this.generation++;
    this.finishing = false;
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
      } catch (_err) {
      }
      player.release().catch((): void => {
      });
    }
    this.frameReady = false;
  }
}

/**
 * 大图区背景：剧照铺满（Cover）、交叉淡入、动态氛围主色光晕与底部融合渐变。
 */
@ComponentV2
export struct TvStageBackdrop {
  @Param imageUrl: string = '';
  @Param kenBurns: boolean = false;
  @Param previewUrl: string = '';
  @Param previewStartMs: number = 0;
  @Param previewEndMs: number = 0;
  @Param onPreviewEnded: (() => void) | null = null;
  @Param onPreviewFailed: (() => void) | null = null;

  @Local private ambient: AmbientColorStore = AmbientColorStore.shared;
  @Local currentUrl: string = '';
  @Local previousUrl: string = '';
  @Local currentOpacity: number = 0;
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

  private haloColor(): string {
    const _rev: number = this.ambient.revision;
    return _rev >= 0 ? this.ambient.orFallback(this.currentUrl).halo(0.30) : 'rgba(38, 54, 86, 0.25)';
  }

  private onImageResult(ok: boolean): void {
    if (this.currentUrl === '') {
      return;
    }
    if (!ok) {
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
            ambient: true,
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
      if (this.previewUrl !== '') {
        TvStagePreviewSurface({
          url: this.previewUrl,
          startMs: this.previewStartMs,
          endMs: this.previewEndMs,
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
      // 影院主光呼吸光晕（随海报/剧照主色平滑过渡）
      Column()
        .width('100%')
        .height('100%')
        .radialGradient({
          center: ['28%', '72%'],
          radius: '68%',
          colors: [[this.haloColor(), 0], ['rgba(0, 0, 0, 0)', 1]]
        })
        .animation({ duration: 520, curve: Curve.EaseOut })
        .hitTestBehavior(HitTestMode.None)
      // 底部渐变：向页面底色过渡，内容行落上来
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [[TvColors.scrimTop, 0.36], [TvColors.scrimMid, 0.68], [TvColors.scrimBottom, 1]]
        })
        .hitTestBehavior(HitTestMode.None)
      // 左侧压暗托字
      Column()
        .width('58%')
        .height('100%')
        .linearGradient({
          angle: 90,
          colors: [['rgba(0, 0, 0, 0.46)', 0], ['rgba(0, 0, 0, 0)', 1]]
        })
        .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(TvColors.bg)
  }
}

/**
 * 大图区左下文案块：片名（ClearLogo 优先，加载中/失败无缝回落文字）→ 事实行 + 规格小标签
 * → 「第 X 季第 Y 集」→ 简介（支持获焦按确认展开全文）→ 操作按钮行。
 */
@ComponentV2
export struct TvStageBlock {
  @Param title: string = '';
  @Param logoUrl: string = '';
  @Param headline: string | null = null;
  @Param metaLine: string | null = null;
  @Param badgeTexts: string[] = [];
  @Param overview: string | null = null;
  @Param overviewLines: number = 2;
  @Param onOverviewActivate: (() => void) | null = null;
  @Param actions: TvStageAction[] = [];
  @Param defaultFocusFirstAction: boolean = false;
  @Param bottomInset: number = 20;

  @Local logoLoaded: boolean = false;
  @Local logoFailed: boolean = false;

  @Monitor('logoUrl')
  private onLogoChange(): void {
    this.logoLoaded = false;
    this.logoFailed = false;
  }

  build() {
    Column() {
      // 片名：挂载透明 RemoteImage 解码 ClearLogo，出图后交叉淡入替换文字；无 Logo 或失败时保持文字零跳动
      if (this.logoUrl !== '' && !this.logoFailed) {
        Stack({ alignContent: Alignment.BottomStart }) {
          if (!this.logoLoaded) {
            this.TitleText()
          }
          Stack() {
            RemoteImage({
              url: this.logoUrl,
              fit: true,
              placeholderText: '',
              onResult: (ok: boolean): void => {
                if (ok) {
                  this.getUIContext().animateTo(
                    { duration: TvMotion.crossfadeMs, curve: Curve.EaseOut },
                    (): void => {
                      this.logoLoaded = true;
                    });
                } else {
                  this.logoFailed = true;
                }
              }
            })
          }
          .width(this.logoLoaded ? 574 : 4)
          .height(this.logoLoaded ? 133 : 4)
          .margin({ bottom: this.logoLoaded ? 18 : 0 })
          .opacity(this.logoLoaded ? 1 : 0)
        }
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
            .fontColor('rgba(243, 245, 249, 0.94)')
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(4)
            .backgroundColor(badge.includes('VIVID') || badge.includes('VISION') || badge.includes('ATMOS')
              ? 'rgba(245, 196, 81, 0.18)' : 'rgba(255, 255, 255, 0.06)')
            .border({
              width: 1,
              color: badge.includes('VIVID') || badge.includes('VISION') || badge.includes('ATMOS')
                ? 'rgba(245, 196, 81, 0.85)' : 'rgba(255, 255, 255, 0.78)'
            })
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
        if (this.onOverviewActivate !== null) {
          TvFocusable({
            focusScale: 1.02,
            cornerRadius: 10,
            onActivate: (): void => {
              const cb = this.onOverviewActivate;
              if (cb !== null) {
                cb();
              }
            }
          }) {
            Text(this.overview ?? '')
              .fontSize(17)
              .fontColor('rgba(243, 245, 249, 0.85)')
              .maxLines(this.overviewLines)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .lineHeight(24)
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .constraintSize({ maxWidth: 496 })
          }
        } else {
          Text(this.overview)
            .fontSize(17)
            .fontColor('rgba(243, 245, 249, 0.82)')
            .maxLines(this.overviewLines)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .lineHeight(24)
            .constraintSize({ maxWidth: 480 })
            .alignSelf(ItemAlign.Start)
        }
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
