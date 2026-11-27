import { AVCastPicker, AVCastPickerStyle } from '@kit.AVSessionKit';
import { EpisodeView } from '../api/Models';
import { AmbientColorStore } from '../common/AmbientColor';
import { Haptics } from '../common/Haptics';
import { PhonePlaybackHost } from '../playback/PhonePlaybackHost';
import { Theme } from '../theme/AppTheme';

/**
 * 折叠屏悬停操控台（Mate X5 / Mate X6 / Pura X / Pocket 2 半折悬停态专属，iPhone 物理形态无法实现）：
 * 上半屏纯净无遮挡影院画面，下半屏铰链折痕下方化身空间毛玻璃 Bento 播控台。
 */
@ComponentV2
export struct PlayerTabletopDeck {
  @Require @Param host: PhonePlaybackHost;
  @Param topVp: number = 0;
  @Param heightVp: number = 320;
  @Local private ambient: AmbientColorStore = AmbientColorStore.shared();

  private haloColor(): string {
    return this.ambient.haloOf(this.host.posterUrl);
  }

  private cycleDisplayMode(): void {
    const order: string[] = ['fit', 'fill', 'cinema219', 'stretch'];
    const idx: number = order.indexOf(this.host.displayMode);
    const next: string = order[(idx + 1) % order.length];
    Haptics.tick();
    this.host.selectDisplay(next);
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 动态环境光晕背板（从海报提取影院氛围色）
      Column()
        .width('100%')
        .height('100%')
        .radialGradient({
          center: ['50%', '0%'],
          radius: '95%',
          colors: [[this.haloColor(), 0], ['rgba(12,14,20,0.92)', 0.72], ['#06070a', 1]]
        })

      Scroll() {
        Column({ space: 12 }) {
          // 顶部信息条：标题 + Vivid 金标 + 投播/画中画/退出悬停
          Row({ space: 10 }) {
            Column({ space: 3 }) {
              Row({ space: 6 }) {
                Text(this.host.title.length > 0 ? this.host.title : '正在播放')
                  .fontSize(16)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Theme.text)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .constraintSize({ maxWidth: '62%' })
                ForEach(this.host.vividBadges(), (badge: string) => {
                  Text(badge)
                    .fontSize(10)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#1A1405')
                    .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                    .backgroundColor('#F5C451')
                    .borderRadius(6)
                }, (badge: string) => badge)
              }
              Text(this.host.episodeNumber > 0
                ? `第 ${this.host.seasonNumber} 季 · 第 ${this.host.episodeNumber} 集 · ${this.host.clockWithChapter()}`
                : this.host.clockWithChapter())
                .fontSize(12)
                .fontColor(Theme.textMuted)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            AVCastPicker({ normalColor: '#eef2f8', pickerStyle: AVCastPickerStyle.STYLE_PANEL })
              .width(34)
              .height(34)

            this.RoundBtn($r('sys.symbol.rectangle_on_rectangle'), '画中画', (): void => {
              Haptics.tick();
              this.host.togglePip();
            })

            this.RoundBtn($r('sys.symbol.arrow_down_right_and_arrow_up_left'), '全屏展开', (): void => {
              Haptics.tick();
              this.host.tabletopForce = -1;
            })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          // 精密时间轴进度卡 + 核心播控四键
          Column({ space: 10 }) {
            Slider({
              value: this.host.progressPercent(),
              min: 0,
              max: 100,
              step: 1,
              style: SliderStyle.OutSet
            })
              .width('100%')
              .height(22)
              .trackColor('rgba(255,255,255,0.18)')
              .selectedColor('#eef2f8')
              .blockColor('#ffffff')
              .onChange((val: number, mode: SliderChangeMode): void => {
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  const duration: number = this.host.displayDurationMs();
                  if (duration > 0) {
                    const target: number = Math.floor(val / 100 * duration) + (this.host.isClip() ? this.host.clipStartMs : 0);
                    Haptics.tick();
                    this.host.seekTo(target);
                  }
                }
              })

            Row({ space: 18 }) {
              Text(this.host.clockText(this.host.displayPositionMs()))
                .fontSize(11)
                .fontColor(Theme.textMuted)
                .width(56)
              Blank()
              this.RoundBtn($r('sys.symbol.gobackward_10'), '后退 10 秒', (): void => {
                Haptics.tick();
                this.host.seekTo(this.host.positionMs - 10000);
              })
              Button({ type: ButtonType.Circle }) {
                SymbolGlyph(this.host.playing ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
                  .fontSize(22)
                  .fontColor(['#0b0d12'])
              }
              .width(50)
              .height(50)
              .backgroundColor('#eef2f8')
              .onClick((): void => {
                Haptics.click();
                this.host.togglePlay();
              })
              this.RoundBtn($r('sys.symbol.goforward_10'), '前进 10 秒', (): void => {
                Haptics.tick();
                this.host.seekTo(this.host.positionMs + 10000);
              })
              if (this.host.nextEpisode() !== null) {
                this.RoundBtn($r('sys.symbol.forward_end_fill'), '下一集', (): void => {
                  Haptics.click();
                  this.host.playNext();
                })
              }
              Blank()
              Text('-' + this.host.clockText(Math.max(0, this.host.displayDurationMs() - this.host.displayPositionMs())))
                .fontSize(11)
                .fontColor(Theme.textMuted)
                .textAlign(TextAlign.End)
                .width(56)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
          }
          .width('100%')
          .padding({ left: 14, right: 14, top: 10, bottom: 12 })
          .backgroundColor('rgba(255,255,255,0.06)')
          .borderRadius(18)
          .border({ width: 0.5, color: 'rgba(255,255,255,0.12)' })

          // 2×2 Bento 音画快切瓷砖
          Row({ space: 10 }) {
            this.BentoTile('音轨', this.host.currentAudioLabel(), (): void => {
              Haptics.tick();
              this.host.toggleMenu('audio');
            })
            this.BentoTile('字幕', this.host.currentSubtitleSummary(), (): void => {
              Haptics.tick();
              this.host.toggleMenu('subtitle');
            })
          }
          .width('100%')

          Row({ space: 10 }) {
            this.BentoTile('画质 / 内核', `${this.host.maxHeight > 0 ? `${this.host.maxHeight}p` : '原画'} · ${this.host.streamLabel()}`, (): void => {
              Haptics.tick();
              this.host.toggleMenu('quality');
            })
            this.BentoTile('画幅裁切', this.host.displayLabel(), (): void => {
              this.cycleDisplayMode();
            })
          }
          .width('100%')

          // 倍速滑切 + 字幕时间轴同步快捷微调
          Row({ space: 8 }) {
            Scroll() {
              Row({ space: 6 }) {
                ForEach([0.75, 1, 1.25, 1.5, 2, 3], (rate: number) => {
                  Text(`${rate}×`)
                    .fontSize(12)
                    .fontWeight(this.host.playbackRate === rate ? FontWeight.Bold : FontWeight.Normal)
                    .fontColor(this.host.playbackRate === rate ? '#0b0d12' : Theme.text)
                    .padding({ left: 11, right: 11, top: 6, bottom: 6 })
                    .backgroundColor(this.host.playbackRate === rate ? '#eef2f8' : 'rgba(255,255,255,0.08)')
                    .borderRadius(14)
                    .onClick((): void => {
                      Haptics.tick();
                      this.host.selectRate(rate);
                    })
                }, (rate: number) => `deck-rate-${rate}`)
              }
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .layoutWeight(1)

            Row({ space: 4 }) {
              Text('字幕 -0.1s')
                .fontSize(11)
                .fontColor(Theme.textMuted)
                .padding({ left: 8, right: 8, top: 6, bottom: 6 })
                .backgroundColor('rgba(255,255,255,0.08)')
                .borderRadius(12)
                .onClick((): void => {
                  Haptics.tick();
                  this.host.adjustSubtitleDelay(-100);
                })
              if (this.host.subDelayMs !== 0) {
                Text(this.host.subDelayLabel())
                  .fontSize(11)
                  .fontColor('#F5C451')
                  .padding({ left: 6, right: 6, top: 6, bottom: 6 })
                  .onClick((): void => {
                    Haptics.tick();
                    this.host.resetSubtitleDelay();
                  })
              }
              Text('+0.1s')
                .fontSize(11)
                .fontColor(Theme.textMuted)
                .padding({ left: 8, right: 8, top: 6, bottom: 6 })
                .backgroundColor('rgba(255,255,255,0.08)')
                .borderRadius(12)
                .onClick((): void => {
                  Haptics.tick();
                  this.host.adjustSubtitleDelay(100);
                })
            }
          }
          .width('100%')

          // 剧集快捷选集胶片带
          if (this.host.episodes.length > 0) {
            Scroll() {
              Row({ space: 8 }) {
                ForEach(this.host.episodes, (ep: EpisodeView) => {
                  Text(`第 ${ep.episode_number} 集`)
                    .fontSize(12)
                    .fontWeight(ep.episode_number === this.host.episodeNumber ? FontWeight.Bold : FontWeight.Normal)
                    .fontColor(ep.episode_number === this.host.episodeNumber ? '#0b0d12' : Theme.text)
                    .opacity(ep.owned ? 1 : 0.38)
                    .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                    .backgroundColor(ep.episode_number === this.host.episodeNumber ? '#eef2f8' : 'rgba(255,255,255,0.07)')
                    .borderRadius(14)
                    .onClick((): void => {
                      if (ep.owned && ep.episode_number !== this.host.episodeNumber) {
                        Haptics.click();
                        this.host.playEpisode(ep);
                      }
                    })
                }, (ep: EpisodeView) => `deck-ep-${ep.episode_number}`)
              }
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .width('100%')
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: Theme.safeBottomInset + 12 })
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
    }
    .id('player-tabletop-deck')
    .position({ x: 0, y: this.topVp })
    .width('100%')
    .height(this.heightVp)
    .borderRadius({ topLeft: 26, topRight: 26 })
    .clip(true)
    .backgroundBlurStyle(BlurStyle.Thick, { colorMode: ThemeColorMode.DARK })
    .border({ width: { top: 0.5 }, color: 'rgba(255,255,255,0.18)' })
    .onTouch((event: TouchEvent): void => { event.stopPropagation(); })
  }

  @Builder
  RoundBtn(icon: Resource, label: string, action: () => void) {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph(icon).fontSize(17).fontColor([Theme.text])
    }
    .accessibilityText(label)
    .width(36)
    .height(36)
    .backgroundColor('rgba(255,255,255,0.10)')
    .border({ width: 0.5, color: 'rgba(255,255,255,0.16)' })
    .onClick(action)
  }

  @Builder
  BentoTile(kicker: string, value: string, action: () => void) {
    Column({ space: 3 }) {
      Text(kicker)
        .fontSize(11)
        .fontColor(Theme.textFaint)
        .width('100%')
      Text(value)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor('rgba(255,255,255,0.06)')
    .borderRadius(16)
    .border({ width: 0.5, color: 'rgba(255,255,255,0.12)' })
    .onClick(action)
  }
}
