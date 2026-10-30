import { audio } from '@kit.AudioKit';

import { Theme } from '../theme/AppTheme';

import { RemoteImage } from '../common/RemoteImage';

import { PlaybackSessionView, AudioTrackView, SubtitlePlanView, PlaybackSegmentView } from '../api/Models';

import { PlayerParams } from '../player/PlayerParams';

import { PhonePlaybackHost, PlayerPhase, QualityOption } from '../playback/PhonePlaybackHost';

interface PlayerMenuRowOptions {
  title: string;
  selected: boolean;
  id: string;
  action: () => void;
  hint?: string;
  icon?: Resource;
}

@Builder
export function PlayerBuilder() { PlayerPage() }

@ComponentV2
export struct PlayerPage {
  @Local private host: PhonePlaybackHost = new PhonePlaybackHost();
  @Local private menuContentHeight: number = 1;
  aboutToAppear(): void { this.host.bindUI(this.getUIContext()); this.host.aboutToAppear(); }
  aboutToDisappear(): void { this.host.aboutToDisappear(); }
  build() {
    NavDestination() {
      /*
       * 版式照 iOS `PlayerScreen`：**全屏视频 + 浮层控制条**（不是「上面视频、下面控制条」）。
       * ZStack 层次：视频 → 点击层 → 控制条浮层（含上下渐变）。
       */
      Stack({ alignContent: Alignment.Center }) {
        this.VideoSurface()
        if (this.host.chromeVisible && !this.host.controlsLocked) {
          this.Controls()
          if (this.host.phase === PlayerPhase.ready && !this.host.engineOpening && !this.host.menuCoversCenter()) {
            Row({ space: 36 }) {
              this.TransportAction($r('sys.symbol.gobackward_10'), '后退 10 秒', 'player-rewind', 56,
                (): void => { this.host.seekTo(this.host.positionMs - 10000); })
              this.PlayPauseAction()
              this.TransportAction($r('sys.symbol.goforward_10'), '前进 10 秒', 'player-forward', 56,
                (): void => { this.host.seekTo(this.host.positionMs + 10000); })
            }
            .hitTestBehavior(HitTestMode.Transparent)
          }
        }
        if (this.host.isLandscape() && (this.host.chromeVisible || this.host.controlsLocked)) {
          Row() {
            this.IconAction(this.host.controlsLocked ? $r('app.media.player_unlock') : $r('app.media.player_lock'), this.host.controlsLocked ? '解锁控制' : '锁定控制', 'player-lock', (): void => { this.host.toggleControlLock(); })
          }
          .position({ x: 16, y: '50%' }).translate({ y: -22 })
        }
        // 本机外挂字幕：系统只回调文本不代画，自己画在底栏上方（控制条之下、常驻显示）。
        // 样式走本机偏好（iOS SubtitleStyle：字号 = 屏宽 × fontScale%、距底 bottomPercent%、背景开关）
        if (this.host.subtitleCue.length > 0) {
          Text(this.host.subtitleCue)
            .fontSize(Math.max(12, this.host.subFontScale / 100 * this.host.layerWidth))
            .fontColor('#ffffff')
            .textAlign(TextAlign.Center)
            .maxLines(2)
            .padding({ left: 14, right: 14, top: 5, bottom: 5 })
            .backgroundColor(this.host.subBackground ? 'rgba(0,0,0,0.55)' : Color.Transparent)
            .borderRadius(6)
            .constraintSize({ maxWidth: '80%' })
            .hitTestBehavior(HitTestMode.None)
            .position({ x: '10%', y: `${Math.max(30, 100 - this.host.subBottom)}%` })
        }
        // 横滑定位的落点读数：整屏正中（与中央三键同一个中心，拖动时控制条已收起）
        if (this.host.scrubMs >= 0) {
          Column({ space: 4 }) {
            // 落点缩略图（雪碧图没就绪就不占位；版本号变化时重查一次）
            if (this.host.trickplayVersion >= 0 && this.host.scrubTile() !== null) {
              Image(this.host.scrubTile())
                .width(128)
                .height(72)
                .objectFit(ImageFit.Cover)
                .borderRadius(10)
            }
            Text(this.host.clockText(this.host.displayScrubMs()))
              .fontSize(22)
              .fontWeight(600)
              .fontColor('#ffffff')
            Text(this.host.scrubDeltaText())
              .fontSize(12)
              .fontColor('rgba(255,255,255,0.7)')
          }
          .padding({ left: 24, right: 24, top: 14, bottom: 14 })
          .backgroundColor('rgba(20,20,22,0.72)')
          .borderRadius(20)
          .hitTestBehavior(HitTestMode.None)
        }
        // 软件转码同意弹窗（iOS PlayerConsentView）：服务端说这片要开软件转码才给放
        if (this.host.phase === PlayerPhase.consent) {
          this.ConsentOverlay()
        }
        // 片段播完（iOS PlayerClipEndCard）：重播这一段 / 接着看全片
        if (this.host.clipEnded) {
          this.ClipEndCard()
        }
        if (this.host.showSheet) { this.MenuOverlay() }
        this.TopHud()
        /*
         * 片尾「即将播放」卡片（iOS PlayerUpNextCard）：独立浮层，不随控制层收起；
         * 右下角、底栏上方。
         *
         * **必须用 hitTestBehavior(None) 的全屏容器做普通子节点，不能用 `.overlay()`**：
         * overlay 的挂载层始终铺满宿主、zIndex=INT_MAX、hit=Default，builder 条件
         * 不渲染时它也还在（dumpLayout 实证：全屏空 Stack 压在页面上）——整页的
         * onClick 全被它吃掉，片段播完卡「重播/看全片」怎么点都没反应就是它干的。
         * None 容器自身不吃触摸，触摸穿透给下层兄弟节点；卡片是它的子节点照常可点。
         */
        Stack({ alignContent: Alignment.BottomEnd }) {
          this.UpNextOverlay()
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#000000')
      .expandSafeArea([SafeAreaType.SYSTEM])

    }
    .id('player-page')
    .hideTitleBar(true)
    .onBackPressed((): boolean => { return this.host.handleBack(); })
    .onAreaChange((_old: Area, newArea: Area) => {
      this.host.layerWidth = this.host.vpOf(newArea.width);
      this.host.layerHeight = this.host.vpOf(newArea.height);
      this.host.layerOriginX = this.host.vpOf(newArea.globalPosition?.x ?? 0);
      this.host.layerOriginY = this.host.vpOf(newArea.globalPosition?.y ?? 0);
    })
    .onTouch((event: TouchEvent) => {
      this.host.onGesture(event);
    })
    .onReady((ctx: NavDestinationContext) => {
      this.host.navStack = ctx.pathStack;
      // 整屏页：收起底部标签栏（iOS 同款行为）
      this.host.chrome.push('player');
      const params: PlayerParams | null = PlayerParams.of(ctx.pathInfo.param as Object | undefined);
      if (params !== null && !this.host.started) {
        this.host.started = true;
        this.host.mediaItemId = params.mediaItemId;
        this.host.fileId = params.fileId;
        this.host.seasonNumber = params.seasonNumber;
        this.host.episodeNumber = params.episodeNumber;
        this.host.startMs = params.startMs;
        this.host.shareSlug = params.shareSlug;
        this.host.clipStartMs = params.clipStartMs;
        this.host.clipEndMs = params.clipEndMs;
        // 片段播放：起播位 = 片段起点（时间轴只算这一段）
        if (this.host.isClip()) {
          this.host.startMs = this.host.clipStartMs;
        }
        this.host.negotiate();
      }
    })
    .onShown((): void => { this.host.detached = false; this.host.claimPlayback(); })
    .onWillDisappear((): void => {
      // 退出前把片段进度写回（得赶在底下的刷片页重新显示之前）
      this.host.publishClipReturn();
    })
  }

  /**
   * 视频面：**必须是 `XComponent(type: SURFACE)`**。
   * 画中画要求 surface 可迁移；用 `Video` 组件或 AVPlayer 默认 surface 以后得推倒重来。
   */
  @Builder
  VideoSurface() {
    Stack({ alignContent: Alignment.Center }) {
      ForEach([this.host.surfaceGeneration], (generation: number) => {
        XComponent({
          type: XComponentType.SURFACE,
          controller: this.host.surfaceController
        })
          .hitTestBehavior(HitTestMode.Transparent)
          .id('player-surface')
          .hdrBrightness(0.0)
          /*
           * **按视频比例摆放**：surface 是个画布，播放器会把画面铺满它——
           * 给全屏尺寸就会把 16:9 的片子拉成竖屏（实测过：测试图的圆变成了竖椭圆）。
           */
          .width(this.host.surfaceWidth())
          .height(this.host.surfaceHeight())
          .onLoad((): void => { this.host.surfaceReady(generation); })
          .onDestroy((): void => { this.host.surfaceDestroyed(generation); })
      }, (generation: number): string => `${generation}`)

      if (this.host.phase === PlayerPhase.negotiating || this.host.engineOpening) {
        Column({ space: 10 }) {
          LoadingProgress().width(30).height(30).color('#ffffff')
          Text(this.host.engineOpening ? '正在打开播放器…' : '正在判定播放方式…')
            .fontSize(13)
            .fontColor('rgba(255,255,255,0.7)')
        }
      } else if (this.host.phase === PlayerPhase.failed) {
        Column({ space: 10 }) {
          SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
            .fontSize(28)
            .fontColor(['rgba(255,255,255,0.6)'])
          Text('放不了')
            .fontSize(16)
            .fontWeight(600)
            .fontColor('#ffffff')
          Text(this.host.errorMessage).id('player-error')
            .fontSize(13)
            .fontColor('rgba(255,255,255,0.7)')
            .textAlign(TextAlign.Center)
            .padding({ left: 32, right: 32 })
          if (this.host.errorSuggestion.length > 0) {
            Text(this.host.errorSuggestion)
              .fontSize(12)
              .fontColor('rgba(255,255,255,0.45)')
              .textAlign(TextAlign.Center)
              .padding({ left: 40, right: 40 })
          }
          // 返回 + 重试（iOS PlayerErrorView 的两颗等宽按钮）
          Row({ space: 10 }) {
            Text('返回')
              .fontSize(14)
              .fontColor('#ffffff')
              .height(40)
              .layoutWeight(1)
              .textAlign(TextAlign.Center)
              .backgroundColor('rgba(255,255,255,0.14)')
              .borderRadius(20)
              .onClick(() => {
                this.host.navStack.pop();
              })
            Text('重试')
              .fontSize(14)
              .fontWeight(600)
              .fontColor('#000000')
              .height(40)
              .layoutWeight(1)
              .textAlign(TextAlign.Center)
              .backgroundColor('#ffffff')
              .borderRadius(20)
              .onClick(() => {
                this.host.retryPlayback();
              })
          }
          .width('60%')
          .margin({ top: 8 })
        }
      }
    }
    .width('100%')
    .height('100%').clip(true)
  }

  @Builder
  IconAction(icon: Resource, label: string, id: string, action: () => void, active: boolean = false, glass: boolean = true) {
    Button({ type: ButtonType.Circle }) {
      Image(icon).width(22).height(22)
    }
    .id(id).accessibilityText(label).width(44).height(44)
    .backgroundColor(active ? 'rgba(255,255,255,0.24)' : (glass ? 'rgba(45,45,48,0.65)' : Color.Transparent))
    .backgroundBlurStyle(glass ? BlurStyle.Thin : BlurStyle.NONE, { colorMode: ThemeColorMode.DARK })
    .border({ width: glass ? 0.5 : 0, color: 'rgba(255,255,255,0.16)' })
    .onTouch((event: TouchEvent): void => { event.stopPropagation(); })
    .onClick((): void => { this.host.noteUserActivity(); action(); this.host.armChromeTimer(); })
  }

  @Builder
  MenuAction(icon: Resource, label: string, kind: string, id: string) {
    Button({ type: ButtonType.Circle }) {
      Stack() {
        if (this.host.showSheet && (this.host.sheetKind === kind ||
          (kind === 'settings' && this.host.sheetKind !== 'audio' && this.host.sheetKind !== 'subtitle'))) {
          Circle().width(36).height(36).fill('rgba(255,255,255,0.2)').id(id + '-active')
        }
        Image(icon).width(22).height(22)
      }.width(44).height(44)
    }
    .id(id).accessibilityText(label).width(44).height(44).padding(0).backgroundColor(Color.Transparent)
    .onTouch((event: TouchEvent): void => { event.stopPropagation(); })
    .onClick((): void => { this.host.noteUserActivity(); this.host.toggleMenu(kind); })
  }

  @Builder
  PlayPauseAction() {
    Button({ type: ButtonType.Circle }) {
      // Read traced state here: ordinary @Builder arguments are not reactive.
      if (this.host.playing) {
        SymbolGlyph($r('sys.symbol.pause_fill')).id('player-pause-glyph').fontSize(76 * 0.42).fontColor(['#ffffff'])
      } else {
        SymbolGlyph($r('sys.symbol.play_fill')).id('player-play-glyph').fontSize(76 * 0.42).fontColor(['#ffffff'])
      }
    }
    .id('player-toggle').accessibilityText(this.host.playing ? '暂停播放' : '继续播放').width(76).height(76)
    .backgroundColor('rgba(35,35,40,0.55)')
    .backgroundBlurStyle(BlurStyle.Thin, { colorMode: ThemeColorMode.DARK })
    .border({ width: 0.5, color: 'rgba(255,255,255,0.18)' })
    .onTouch((event: TouchEvent): void => { event.stopPropagation(); })
    .onClick((): void => { this.host.togglePlay(); this.host.armChromeTimer(); })
  }

  @Builder
  TransportAction(icon: Resource, label: string, id: string, size: number, action: () => void) {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph(icon).fontSize(size * 0.42).fontColor(['#ffffff'])
    }
    .id(id).accessibilityText(label).width(size).height(size)
    .backgroundColor('rgba(35,35,40,0.55)')
    .backgroundBlurStyle(BlurStyle.Thin, { colorMode: ThemeColorMode.DARK })
    .border({ width: 0.5, color: 'rgba(255,255,255,0.18)' })
    .onTouch((event: TouchEvent): void => { event.stopPropagation(); })
    .onClick((): void => { this.host.noteUserActivity(); action(); this.host.armChromeTimer(); })
  }

  @Builder
  Controls() {
    Column() {
      Row({ space: 12 }) {
        this.IconAction($r('app.media.player_back'), this.host.isLandscape() ? '退出横屏' : '退出播放', 'player-close', (): void => { this.host.back(); })
        Column({ space: 2 }) {
          Text(this.host.title.length > 0 ? this.host.title : '播放')
            .fontSize(17).fontWeight(600).fontColor('#ffffff').maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.host.episodeNumber > 0) {
            Text(`第 ${this.host.seasonNumber} 季 · 第 ${this.host.episodeNumber} 集`)
              .fontSize(12).fontColor('rgba(255,255,255,0.65)').maxLines(1)
          }
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        this.IconAction($r('app.media.player_pip'), this.host.pipActive ? '退出画中画' : '画中画', 'player-pip', (): void => { this.host.togglePip(); })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: this.host.isLandscape() ? 16 : Theme.shellTopInset + 8, bottom: 12 })
      .linearGradient({ angle: 180, colors: [['rgba(0,0,0,0.55)', 0], ['rgba(0,0,0,0)', 1]] })
      .onAreaChange((_old: Area, area: Area): void => { this.host.chromeTopY = this.host.bandOf(area); })
      Blank()
      Column({ space: 0 }) {
        if (this.host.currentSegment() !== null) {
          Row() {
            Blank()
            Button(this.host.segmentLabel(this.host.currentSegment() as PlaybackSegmentView))
              .fontColor('#ffffff').backgroundColor('rgba(35,35,40,0.65)').height(36)
              .onTouch((event: TouchEvent): void => { event.stopPropagation(); })
              .onClick((): void => {
                const segment = this.host.currentSegment();
                if (segment !== null) { this.host.seekTo(segment.end_ms); }
              })
          }.width('100%').margin({ bottom: 12 })
        }
        Row() {
          Row({ space: 0 }) {
            this.MenuAction($r('app.media.player_audio'), '音轨', 'audio', 'player-audio')
            this.MenuAction($r('app.media.player_subtitle'), '字幕', 'subtitle', 'player-subtitle')
            this.MenuAction($r('app.media.player_more'), '设置', 'settings', 'player-settings')
          }
          .backgroundColor('rgba(45,45,48,0.65)')
          .backgroundBlurStyle(BlurStyle.Thin, { colorMode: ThemeColorMode.DARK })
          .borderRadius(22).border({ width: 0.5, color: 'rgba(255,255,255,0.16)' })
          Blank()
          this.IconAction($r('app.media.player_rotate'), this.host.isLandscape() ? '退出横屏' : '横屏播放', 'player-rotate', (): void => { this.host.toggleLandscape(); })
        }.width('100%')
          .onAreaChange((_old: Area, area: Area): void => { this.host.menuAnchorTop = this.host.vpOf(area.globalPosition?.y ?? 0) - this.host.layerOriginY; })
        Column() {
          Stack({ alignContent: Alignment.Start }) {
            Column().width('100%').height(4).backgroundColor('rgba(255,255,255,0.25)').borderRadius(2)
            Column().width(`${this.host.progressPercent()}%`).height(4).backgroundColor('#ffffff').borderRadius(2)
            Column().width(12).height(12).borderRadius(6).backgroundColor('#ffffff')
              .position({ x: `${this.host.progressPercent()}%` }).translate({ x: -6, y: -4 })
          }.width('100%').height(4)
        }
        .id('player-progress').accessibilityText('播放进度').width('100%').height(44).justifyContent(FlexAlign.Center)
        .onAreaChange((_old: Area, area: Area): void => {
          this.host.progressBarWidth = this.host.vpOf(area.width);
          this.host.barLeftX = this.host.vpOf(area.globalPosition?.x ?? 0);
          this.host.barY = this.host.bandOf(area);
        })
        Row({ space: 8 }) {
          Text(this.host.clockWithChapter()).id('player-position').fontSize(12)
            .fontColor('rgba(255,255,255,0.85)').maxLines(1).layoutWeight(1)
          if (this.host.playbackRate !== 1) {
            Text(`${this.host.playbackRate}×`).id('player-rate-badge').fontSize(12).fontColor('#ffffff')
          }
          Text('-' + this.host.clockText(Math.max(0, this.host.displayDurationMs() - this.host.displayPositionMs())))
            .fontSize(12).fontColor('rgba(255,255,255,0.85)')
        }.width('100%').margin({ top: -8 })
      }
      .width('100%').padding({ left: 16, right: 16, top: 12, bottom: Theme.safeBottomInset + 8 })
      .linearGradient({ angle: 180, colors: [['rgba(0,0,0,0)', 0], ['rgba(0,0,0,0.7)', 1]] })
      .onAreaChange((_old: Area, area: Area): void => { this.host.chromeBottomY = this.host.bandOf(area); })
    }
    .width('100%').height('100%').hitTestBehavior(HitTestMode.Transparent)
  }

  /**
   * 片尾「即将播放」卡片（iOS PlayerUpNextCard，Netflix 同款）：
   * 左剧照 / 三行「即将播放 · N 秒 · 第 N 集 · 集名」/ 右上 ✕ = 不看下一集；
   * 底下「立即播放」——认出了片尾时这颗按钮就是倒计时进度条（白条从左往右填满自动换集），
   * 连播满上限后播完了不自动接，眉标改问「还在看吗？」。
   * 横屏（高度紧）不放剧照、卡片收窄。overlay 挂根 Stack 右下角，只包卡片本身。
   */
  @Builder
  UpNextOverlay() {
    if (this.host.showsUpNext()) {
      Column({ space: 12 }) {
        Row({ space: 12 }) {
          if (!this.host.isLandscape() && this.host.upNextStillUrl().length > 0) {
            RemoteImage({ url: this.host.upNextStillUrl() })
              .width(112)
              .height(63)
              .borderRadius(10)
              .clip(true)
          }
          Column({ space: 2 }) {
            Text(this.host.upNextEyebrow())
              .fontSize(11)
              .fontColor('rgba(255,255,255,0.5)')
            Text(this.host.upNextCode())
              .fontSize(13)
              .fontColor('rgba(255,255,255,0.7)')
            if (this.host.upNextName().length > 0) {
              Text(this.host.upNextName())
                .fontSize(15)
                .fontWeight(600)
                .fontColor('#ffffff')
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          // ✕ = 不看下一集，继续看片尾
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(13)
            .fontWeight(700)
            .fontColor(['rgba(255,255,255,0.8)'])
            .width(28)
            .height(28)
            .backgroundColor('rgba(255,255,255,0.14)')
            .borderRadius(14)
            .onClick(() => {
              this.host.noteUserActivity();
              this.host.nextDismissed = true;
              this.host.autoNextCancelled = true;
              this.host.autoNextProgress = 0;
            })
        }
        .alignItems(VerticalAlign.Top)

        // 「立即播放」：白底胶囊；倒计时中浅底 + 白条从左往右填（GeometryReader 那套 → 层叠）
        Stack({ alignContent: Alignment.Center }) {
          Row() {
            Column()
              .height(34)
              .width(this.host.upNextFillPercent() + '%')
              .backgroundColor('#ffffff')
          }
          .width('100%')
          .height(34)
          .backgroundColor('rgba(255,255,255,0.35)')
          .borderRadius(17)
          .clip(true)

          Row({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.play_fill'))
              .fontSize(12)
              .fontColor(['#000000'])
            Text('立即播放')
              .fontSize(13)
              .fontWeight(600)
              .fontColor('#000000')
          }
        }
        .width('100%')
        .onClick(() => {
          this.host.noteUserActivity();
          this.host.playNext();
        })
      }
      .alignItems(HorizontalAlign.End)
      .padding(14)
      .width(this.host.isLandscape() ? 252 : 300)
      .backgroundColor('rgba(20,20,22,0.78)')
      .borderRadius(26)
      .margin({ right: 16, bottom: 16 })
    }
  }

  /**
   * 顶部胶囊 HUD（iOS PlayerHUD）：长按倍速 / 竖滑调节。
   * 顶栏下方再隔一个间距，控制条开着也不压住顶栏。
   */
  @Builder
  TopHud() {
    Column() {
      if (this.host.holdSpeedActive) {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.fast_forward'))
            .fontSize(15)
            .fontColor(['#ffffff'])
          Text('2× 快进中')
            .fontSize(14)
            .fontColor('#ffffff')
        }
        .height(40)
        .padding({ left: 18, right: 18 })
        .backgroundColor('rgba(20,20,22,0.72)')
        .borderRadius(20)
      } else if (this.host.adjustSide.length > 0) {
        Row({ space: 10 }) {
          SymbolGlyph(this.host.adjustSide === 'brightness'
            ? $r('sys.symbol.sun_max_fill') : $r('sys.symbol.speaker_slash_fill'))
            .fontSize(16)
            .fontColor(['#ffffff'])
          if (this.host.adjustSide === 'brightness') {
            Row() {
              Column()
                .width(`${Math.round(this.host.adjustValue * 100)}%`)
                .height(4)
                .backgroundColor('#ffffff')
                .borderRadius(2)
            }
            .width(96)
            .height(4)
            .backgroundColor('rgba(255,255,255,0.28)')
            .borderRadius(2)
          } else {
            // 鸿蒙改不了系统音量：与 iOS 音量不可调时同款降级文案
            Text('音量由系统侧键控制')
              .fontSize(13)
              .fontColor('#ffffff')
          }
        }
        .height(40)
        .padding({ left: 18, right: 18 })
        .backgroundColor('rgba(20,20,22,0.72)')
        .borderRadius(20)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ top: Theme.shellTopInset + 56 })
    .hitTestBehavior(HitTestMode.None)
  }

  /**
   * 软件转码同意弹窗（iOS PlayerConsentView）：
   * 标题 + 服务端给的原因与代价；能自己开就给「开启并播放」（开启后校验回显再重协商），
   * 不能就只有「知道了」。
   */
  @Builder
  ConsentOverlay() {
    Column({ space: 14 }) {
      Text('这部片需要软件转码才能播放')
        .fontSize(18)
        .fontWeight(600)
        .fontColor('#ffffff')
        .textAlign(TextAlign.Center)
      if (this.host.session !== null) {
        if ((this.host.session as PlaybackSessionView).decision.reason.length > 0) {
          Text((this.host.session as PlaybackSessionView).decision.reason)
            .fontSize(13)
            .fontColor('rgba(255,255,255,0.7)')
            .textAlign(TextAlign.Center)
            .width('100%')
        }
        if (this.host.consentCostHint().length > 0) {
          Text(this.host.consentCostHint())
            .fontSize(12)
            .fontColor(Theme.warn)
            .textAlign(TextAlign.Center)
            .width('100%')
        }
      }
      if (this.host.canSelfEnable()) {
        Row({ space: 10 }) {
          Text('取消')
            .fontSize(14)
            .fontColor('#ffffff')
            .height(42)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .backgroundColor('rgba(255,255,255,0.14)')
            .borderRadius(21)
            .onClick(() => {
              this.host.navStack.pop();
            })
          Text(this.host.consentSaving ? '正在开启…' : '开启并播放')
            .fontSize(14)
            .fontWeight(600)
            .fontColor('#000000')
            .height(42)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .backgroundColor('#ffffff')
            .borderRadius(21)
            .onClick(() => {
              if (!this.host.consentSaving) {
                this.host.grantConsent();
              }
            })
        }
        .width('100%')
        .margin({ top: 4 })
        Text('开启后所有需要软件转码的影片都会直接播放')
          .fontSize(11)
          .fontColor('rgba(255,255,255,0.4)')
          .textAlign(TextAlign.Center)
          .width('100%')
      } else {
        Text('管理员没有开启软件转码，先看别的或联系管理员')
          .fontSize(12)
          .fontColor('rgba(255,255,255,0.55)')
          .textAlign(TextAlign.Center)
          .width('100%')
        Text('知道了')
          .fontSize(14)
          .fontWeight(600)
          .fontColor('#000000')
          .height(42)
          .padding({ left: 28, right: 28 })
          .textAlign(TextAlign.Center)
          .backgroundColor('#ffffff')
          .borderRadius(21)
          .margin({ top: 4 })
          .onClick(() => {
            this.host.navStack.pop();
          })
      }
    }
    .width('82%')
    .padding(22)
    .backgroundColor('rgba(20,20,22,0.92)')
    .borderRadius(24)
    .border({ width: 1, color: 'rgba(255,255,255,0.08)' })
  }

  /** 片段播完卡（iOS PlayerClipEndCard）：重播这一段 / 看全片 / 返回 */
  @Builder
  ClipEndCard() {
    Column({ space: 12 }) {
      Text('这一段看完了')
        .fontSize(17)
        .fontWeight(600)
        .fontColor('#ffffff')
      Row({ space: 10 }) {
        Text('重播')
          .fontSize(14)
          .fontColor('#ffffff')
          .height(42)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .backgroundColor('rgba(255,255,255,0.14)')
          .borderRadius(21)
          .onClick(() => {
            this.host.replayClip();
          })
        Text('看全片')
          .fontSize(14)
          .fontWeight(600)
          .fontColor('#000000')
          .height(42)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .backgroundColor('#ffffff')
          .borderRadius(21)
          .onClick(() => {
            this.host.exitClip();
          })
      }
      .width('100%')
      /*
       * 卡片期间手势层整体锁死（onGesture 的 clipEnded 守卫），顶栏返回键跟着控制层
       * 一起唤不出来——iOS 靠系统左滑返回兜底，这里给个显式出口：低调的「返回」
       * 文字键（次级动作，不与重播/看全片抢主次），点了退回刷片页。
       */
      Text('返回')
        .fontSize(13)
        .fontColor('rgba(255,255,255,0.55)')
        .height(34)
        .padding({ left: 20, right: 20 })
        .onClick(() => {
          this.host.navStack.pop();
        })
    }
    .width('70%')
    .padding(20)
    .backgroundColor('rgba(20,20,22,0.92)')
    .borderRadius(24)
    .border({ width: 1, color: 'rgba(255,255,255,0.08)' })
  }

  @Builder
  MenuRow($$: PlayerMenuRowOptions) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 8 }) {
        if ($$.icon === undefined) {
          SymbolGlyph($r('sys.symbol.checkmark')).fontSize(14).fontColor(['#ffffff'])
            .width(16).opacity($$.selected ? 1 : 0).id($$.id + '-check')
        }
        Column({ space: 1 }) {
          Text($$.title).fontSize(15).fontColor('#ffffff').width('100%')
          if (($$.hint ?? '').length > 0) {
            Text($$.hint ?? '').fontSize(12).fontColor('rgba(255,255,255,0.45)').width('100%').maxLines(2)
          }
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        if ($$.icon !== undefined) { Image($$.icon).width(20).height(20) }
      }.width('100%').padding({ left: 10, right: 10, top: 10, bottom: 10 }).constraintSize({ minHeight: 44 })
    }
    .id($$.id).accessibilityText($$.title + ($$.selected ? '，已选中' : '')).width('100%').padding(0)
    .backgroundColor(Color.Transparent).borderRadius(20)
    .onClick((): void => { this.host.noteUserActivity(); $$.action(); })
  }

  @Builder
  MenuOverlay() {
    Stack({ alignContent: Alignment.BottomStart }) {
      // Keep dismissal above the measured button row so switching menus stays tappable.
      Column().width('100%').height(this.host.menuAnchorY())
        .position({ x: 0, y: 0 }).backgroundColor(Color.Transparent)
        .onTouch((event: TouchEvent): void => { event.stopPropagation(); })
        .id('player-menu-dismiss').onClick((): void => { this.host.closeMenu(); })
      Column({ space: 0 }) {
        if (this.host.sheetKind !== 'settings' && this.host.sheetKind !== 'stats') {
          Row({ space: 4 }) {
            if (this.host.sheetKind !== 'audio' && this.host.sheetKind !== 'subtitle') {
              Button('‹').padding(0).width(28).height(36).fontSize(24).fontColor('#ffffff').backgroundColor(Color.Transparent)
                .id('player-menu-back').accessibilityText('返回设置').onClick((): void => { this.host.sheetKind = 'settings'; })
            }
            Text(this.host.menuTitle()).id('player-menu-title').fontSize(12).fontWeight(600)
              .fontColor('rgba(255,255,255,0.55)').layoutWeight(1)
          }.padding({ left: 16, right: 16 }).height(36).width('100%')
        }
        if (this.host.sheetKind === 'stats') {
          this.StatsSheet()
        } else {
          // A new menu starts at its first row, independent of the previous menu's scroll offset.
          ForEach([this.host.sheetKind], (kind: string) => {
            Scroll() {
              Column({ space: 0 }) { this.MenuContents() }.width('100%').padding({ left: 6, right: 6, bottom: 8, top: kind === 'settings' ? 8 : 0 })
                .onAreaChange((_old: Area, area: Area): void => { this.menuContentHeight = this.host.vpOf(area.height); })
            }.id(`player-menu-scroll-${kind}`).width('100%')
              .height(Math.min(this.menuContentHeight, this.host.menuHeight() - this.host.menuHeaderHeight()))
              .scrollBar(this.menuContentHeight > this.host.menuHeight() - this.host.menuHeaderHeight() ? BarState.On : BarState.Off)
          }, (kind: string): string => kind)
        }
      }
      .id('player-menu').width(Math.min(290, this.host.layerWidth - 32))
      .constraintSize({ maxHeight: this.host.menuHeight() }).borderRadius(26).clip(true)
      .backgroundColor('rgba(35,35,38,0.72)')
      .backgroundBlurStyle(BlurStyle.Thick, { colorMode: ThemeColorMode.DARK })
      .border({ width: 0.5, color: 'rgba(255,255,255,0.15)' })
      .margin({ left: 16, bottom: this.host.layerHeight - this.host.menuAnchorY() + 10 })
      .onAreaChange((_old: Area, area: Area): void => { this.host.menuTop = this.host.vpOf(area.globalPosition?.y ?? 0) - this.host.layerOriginY; })
      .onTouch((event: TouchEvent): void => { event.stopPropagation(); })
      .onClick((): void => {})
    }.width('100%').height('100%').hitTestBehavior(HitTestMode.None)
  }

  @Builder
  MenuContents() {
    if (this.host.sheetKind === 'audio') {
      this.MenuRow({ title: '跟随默认', selected: this.host.audioRef.length === 0, id: 'player-audio-default', action: (): void => { this.host.pickAudio(''); } })
      ForEach(this.host.session?.decision.audio_tracks ?? [], (track: AudioTrackView, index: number) => {
        this.MenuRow({ title: this.host.audioLabel(track, index), selected: this.host.audioRef === track.ref, id: `player-audio-${index}`, action: (): void => { this.host.pickAudio(track.ref); } })
      }, (track: AudioTrackView): string => track.ref)
    } else if (this.host.sheetKind === 'subtitle') {
      this.MenuRow({ title: '关闭字幕', selected: (this.host.subtitleIndex < 0), id: 'player-subtitle-off', action: (): void => { this.host.pickSubtitle(-1); } })
      ForEach(this.host.session?.decision.subtitles ?? [], (plan: SubtitlePlanView, index: number) => {
        this.MenuRow({ title: this.host.subtitleLabel(plan, index), selected: this.host.subtitleIndex === index, id: `player-subtitle-${index}`, action: (): void => { this.host.pickSubtitle(index); } })
      }, (plan: SubtitlePlanView): string => plan.track_ref)
      if (this.host.localSpec !== null) {
        Row() {
          Text('字号').fontColor('#ffffff').layoutWeight(1)
          this.StyleStepButton('−', (): void => { this.host.adjustSubtitleStyle(-0.4, 0); })
          Text(`${Math.round(this.host.subFontScale * 10) / 10}`).fontColor('#ffffff').width(40).textAlign(TextAlign.Center)
          this.StyleStepButton('+', (): void => { this.host.adjustSubtitleStyle(0.4, 0); })
        }.padding(16)
        Row() {
          Text('距底部').fontColor('#ffffff').layoutWeight(1)
          this.StyleStepButton('−', (): void => { this.host.adjustSubtitleStyle(0, -2); })
          Text(`${this.host.subBottom}%`).fontColor('#ffffff').width(40).textAlign(TextAlign.Center)
          this.StyleStepButton('+', (): void => { this.host.adjustSubtitleStyle(0, 2); })
        }.padding(16)
        this.MenuRow({ title: '字幕背景', selected: this.host.subBackground, id: 'player-subtitle-background', action: (): void => { this.host.toggleSubtitleBackground(); } })
      }
    } else if (this.host.sheetKind === 'settings') {
      if (this.host.shareSlug.length === 0) {
        this.MenuRow({ title: '画质', selected: false, id: 'player-quality', icon: $r('app.media.player_quality'), action: (): void => { this.host.sheetKind = 'quality'; }, hint: this.host.maxHeight > 0 ? `${this.host.maxHeight}p` : '原画' })
      }
      this.MenuRow({ title: '画面', selected: false, id: 'player-display', icon: $r('app.media.player_display'), action: (): void => { this.host.sheetKind = 'display'; }, hint: this.host.displayLabel() })
      this.MenuRow({ title: '倍速', selected: false, id: 'player-speed', icon: $r('app.media.player_speed'), action: (): void => { this.host.sheetKind = 'speed'; }, hint: `${this.host.playbackRate}×` })
      Divider().color('rgba(0,0,0,0.3)').strokeWidth(6).margin({ top: 4, bottom: 4 })
      this.MenuRow({ title: '播放诊断', selected: false, id: 'player-diagnostics', icon: $r('app.media.player_diagnostics'), action: (): void => { this.host.sheetKind = 'stats'; } })
    } else if (this.host.sheetKind === 'quality') {
      ForEach(this.host.qualityOptions(), (option: QualityOption) => {
        this.MenuRow({ title: option.label, selected: this.host.maxHeight === option.maxHeight, id: `player-quality-${option.maxHeight}`, action: (): void => { this.host.pickQuality(option.maxHeight); } })
      }, (option: QualityOption): string => `${option.maxHeight}`)
    } else if (this.host.sheetKind === 'speed') {
      ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], (rate: number) => {
        this.MenuRow({ title: rate === 1 ? '正常' : `${rate}×`, selected: this.host.playbackRate === rate, id: `player-speed-${rate}`, action: (): void => { this.host.selectRate(rate); } })
      }, (rate: number): string => `${rate}`)
    } else if (this.host.sheetKind === 'display') {
      this.MenuRow({ title: '完整显示', selected: this.host.displayMode === 'fit', id: 'player-display-fit', action: (): void => { this.host.selectDisplay('fit'); }, hint: '保持比例，显示完整画面' })
      this.MenuRow({ title: '等比例铺满', selected: this.host.displayMode === 'fill', id: 'player-display-fill', action: (): void => { this.host.selectDisplay('fill'); }, hint: '保持比例，裁去超出屏幕的部分' })
      this.MenuRow({ title: '拉伸铺满', selected: this.host.displayMode === 'stretch', id: 'player-display-stretch', action: (): void => { this.host.selectDisplay('stretch'); }, hint: '填满屏幕，改变画面比例' })
    }
  }

  /** 样式行里的圆步进钮（iOS StepButton） */
  @Builder
  StyleStepButton(label: string, onTap: () => void) {
    Text(label)
      .fontSize(16)
      .fontColor(Theme.text)
      .width(34)
      .height(34)
      .textAlign(TextAlign.Center)
      .backgroundColor(Theme.glassFill)
      .borderRadius(17)
      .onClick(() => {
        onTap();
      })
  }

  /** 播放诊断（iOS PlayerDiagnosticsPanel）：静态判定 + 2 秒一次的服务端执行快照 */
  @Builder
  StatsSheet() {
    Column({ space: 14 }) {
      Row() {
        Text('播放诊断')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
          .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(18)
          .fontColor([Theme.textMuted])
          .width(40)
          .height(40)
          .onClick(() => {
            this.host.showSheet = false;
          })
      }
      .width('100%')

      Scroll() {
        Column({ space: 12 }) {
          if (this.host.session !== null) {
            // 判定：这一档是怎么判出来的
            Column({ space: 8 }) {
              Text(this.host.streamLabel())
                .fontSize(16)
                .fontWeight(600)
                .fontColor(Theme.text)
              Text(this.host.engineLine()).id('player-engine')
                .fontSize(12)
                .fontColor(Theme.textMuted)
              Text(`容器 ${(this.host.session as PlaybackSessionView).decision.container ?? '—'}  ·  `
                + `档位 ${(this.host.session as PlaybackSessionView).decision.tier ?? 0}`)
                .fontSize(13)
                .fontColor(Theme.textMuted)
              if ((this.host.session as PlaybackSessionView).decision.reason.length > 0) {
                Text((this.host.session as PlaybackSessionView).decision.reason)
                  .fontSize(13)
                  .fontColor(Theme.text)
                  .width('100%')
              }
              if ((this.host.session as PlaybackSessionView).decision.suggestion !== null
                && (this.host.session as PlaybackSessionView).decision.suggestion !== undefined
                && ((this.host.session as PlaybackSessionView).decision.suggestion ?? '').length > 0) {
                Text((this.host.session as PlaybackSessionView).decision.suggestion ?? '')
                  .fontSize(12)
                  .fontColor(Theme.warn)
                  .width('100%')
              }
              if ((this.host.session as PlaybackSessionView).hw_backend !== null
                && (this.host.session as PlaybackSessionView).hw_backend !== undefined) {
                Text(`硬件后端：${(this.host.session as PlaybackSessionView).hw_backend}`)
                  .fontSize(12)
                  .fontColor(Theme.textMuted)
              }
              if ((this.host.session as PlaybackSessionView).decision.degraded_from !== null
                && (this.host.session as PlaybackSessionView).decision.degraded_from !== undefined) {
                Text(`从第 ${(this.host.session as PlaybackSessionView).decision.degraded_from} 档降级下来`)
                  .fontSize(12)
                  .fontColor(Theme.warn)
              }
              Text('自动模式按 AVPlayer、MPV 各自能力分别协商')
                .fontSize(11)
                .fontColor(Theme.textFaint)
                .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(16)
            .backgroundColor(Theme.surface)
            .borderRadius(Theme.cardRadius)
            .border({ width: 1, color: Theme.line })
          } else {
            // 直出 / 本机副本：没有服务端会话，只有本地信息
            Column({ space: 8 }) {
              Text(this.host.streamLabel())
                .fontSize(16)
                .fontWeight(600)
                .fontColor(Theme.text)
              Text(this.host.engineLine()).id('player-engine')
                .fontSize(12)
                .fontColor(Theme.textMuted)
              Text('没有服务端播放会话：原文件直出或本机副本，不产生转码')
                .fontSize(12)
                .fontColor(Theme.textMuted)
                .width('100%')
              Text('自动模式按 AVPlayer、MPV 各自能力分别协商')
                .fontSize(11)
                .fontColor(Theme.textFaint)
                .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(16)
            .backgroundColor(Theme.surface)
            .borderRadius(Theme.cardRadius)
            .border({ width: 1, color: Theme.line })
          }
          if (this.host.diag !== null) {
            // 执行：此刻转码跑在哪、用什么后端
            Column({ space: 7 }) {
              Text('执行')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.textMuted)
              if (this.host.diagExecutionMode().length > 0) {
                Text(this.host.diagExecutionMode())
                  .fontSize(13)
                  .fontColor(Theme.text)
                  .width('100%')
              }
              if (this.host.diagLocation().length > 0) {
                Text(this.host.diagLocation())
                  .fontSize(13)
                  .fontColor(Theme.text)
                  .width('100%')
              }
              if (this.host.diagBackendLine().length > 0) {
                Text(this.host.diagBackendLine())
                  .fontSize(13)
                  .fontColor(Theme.text)
                  .width('100%')
              }
              if (this.host.diagWorkerLine().length > 0) {
                Text(this.host.diagWorkerLine())
                  .fontSize(13)
                  .fontColor(Theme.text)
                  .width('100%')
              }
              if (this.host.diagWorkerVersionLine().length > 0) {
                Text(this.host.diagWorkerVersionLine())
                  .fontSize(13)
                  .fontColor(Theme.text)
                  .width('100%')
              }
              if (this.host.diagWorkerPlatformLine().length > 0) {
                Text(this.host.diagWorkerPlatformLine())
                  .fontSize(13)
                  .fontColor(Theme.text)
                  .width('100%')
              }
              if (this.host.diagJobLine().length > 0) {
                Text(this.host.diagJobLine())
                  .fontSize(13)
                  .fontColor(Theme.text)
                  .width('100%')
              }
              if (this.host.diagExitCodeLine().length > 0) {
                Text(this.host.diagExitCodeLine())
                  .fontSize(13)
                  .fontColor(Theme.danger)
                  .width('100%')
              }
              if (this.host.diagJobErrorLine().length > 0) {
                Text(this.host.diagJobErrorLine())
                  .fontSize(13)
                  .fontColor(Theme.danger)
                  .width('100%')
              }
              if (this.host.diagStderrLine().length > 0) {
                Text(this.host.diagStderrLine())
                  .fontSize(13)
                  .fontColor(Theme.danger)
                  .width('100%')
              }
              if (this.host.diagSessionErrorLine().length > 0) {
                Text(this.host.diagSessionErrorLine())
                  .fontSize(13)
                  .fontColor(Theme.danger)
                  .width('100%')
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(16)
            .backgroundColor(Theme.surface)
            .borderRadius(Theme.cardRadius)
            .border({ width: 1, color: Theme.line })
          }
          if (this.host.diagHasSegments()) {
            // 供片：分片产出/缺口/缓存
            Column({ space: 7 }) {
              Text('供片')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.textMuted)
              Text(this.host.diagSupplyFirstLine())
                .fontSize(13)
                .fontColor(Theme.text)
                .width('100%')
              Text(this.host.diagSupplyProducedLine())
                .fontSize(13)
                .fontColor(Theme.text)
                .width('100%')
              if (this.host.diagSupplyLeadLine().length > 0) {
                Text(this.host.diagSupplyLeadLine())
                  .fontSize(13)
                  .fontColor(Theme.text)
                  .width('100%')
              }
              Text(this.host.diagSupplyCacheLine())
                .fontSize(13)
                .fontColor(Theme.text)
                .width('100%')
              if (this.host.diagSupplyGapLine().length > 0) {
                Text(this.host.diagSupplyGapLine())
                  .fontSize(13)
                  .fontColor(Theme.danger)
                  .width('100%')
              }
              if (this.host.diagSupplyHistoricalLine().length > 0) {
                Text(this.host.diagSupplyHistoricalLine())
                  .fontSize(13)
                  .fontColor(Theme.warn)
                  .width('100%')
              }
              if (this.host.diagSupplyUploadLine().length > 0) {
                Text(this.host.diagSupplyUploadLine())
                  .fontSize(13)
                  .fontColor(this.host.diagSupplyUploadAlert() ? Theme.danger : Theme.text)
                  .width('100%')
              }
              if (this.host.diagSupplyWaitLine().length > 0) {
                Text(this.host.diagSupplyWaitLine())
                  .fontSize(13)
                  .fontColor(Theme.text)
                  .width('100%')
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(16)
            .backgroundColor(Theme.surface)
            .borderRadius(Theme.cardRadius)
            .border({ width: 1, color: Theme.line })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .width('100%')
      .align(Alignment.TopStart)
    }
    .width('100%')
    .height(this.host.menuHeight())
    .padding({ left: 12, right: 12 })
    .backgroundColor(Color.Transparent)
  }
}
