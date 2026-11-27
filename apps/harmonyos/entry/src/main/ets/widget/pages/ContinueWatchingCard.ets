const widgetStorage: LocalStorage = new LocalStorage();

/**
 * 鸿蒙桌面万能卡片 UI（2×2 紧凑态 + 2×4 宽幅影院态）：
 * 遵循鸿蒙 ArkTS 卡片规范（@Entry + @Component V1 + LocalStorageProp），
 * 点击经 `postCardAction` 携带 `mcContinueKind` 参数直拉 `EntryAbility` 毫秒级续播或搜片。
 */
@Entry(widgetStorage)
@Component
struct ContinueWatchingCard {
  @LocalStorageProp('dimension') dimension: number = 3;
  @LocalStorageProp('hasItem') hasItem: boolean = false;
  @LocalStorageProp('title') title: string = '暂无在看影片';
  @LocalStorageProp('subtitle') subtitle: string = '轻触打开媒体库开始观影';
  @LocalStorageProp('progressPercent') progressPercent: number = 0;
  @LocalStorageProp('remainingText') remainingText: string = '';
  @LocalStorageProp('libraryId') libraryId: number = 0;
  @LocalStorageProp('mediaItemId') mediaItemId: number = 0;
  @LocalStorageProp('season') season: number = 0;
  @LocalStorageProp('episode') episode: number = 0;
  @LocalStorageProp('positionMs') positionMs: number = 0;

  private launchContinue(): void {
    postCardAction(this, {
      action: 'router',
      abilityName: 'EntryAbility',
      params: {
        mcContinueKind: this.hasItem && this.mediaItemId > 0 ? 'play' : 'continue_latest',
        mcLibraryId: this.libraryId,
        mcMediaItemId: this.mediaItemId,
        mcSeason: this.season,
        mcEpisode: this.episode,
        mcPositionMs: this.positionMs,
        mcTitle: this.title
      }
    });
  }

  private launchSearch(): void {
    postCardAction(this, {
      action: 'router',
      abilityName: 'EntryAbility',
      params: {
        mcContinueKind: 'search'
      }
    });
  }

  private clampedPct(): number {
    return Math.max(0, Math.min(100, this.progressPercent));
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 影院暗夜极光底
      Column()
        .width('100%')
        .height('100%')
        .radialGradient({
          center: ['85%', '15%'],
          radius: '95%',
          colors: [['rgba(88, 114, 188, 0.34)', 0], ['rgba(12, 14, 22, 0.98)', 1]]
        })

      Column() {
        // 顶栏眉标
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.play_circle_fill'))
            .fontSize(14)
            .fontColor(['#f5c451'])
          Text(this.hasItem ? '继续观看' : 'MovieClaw')
            .fontSize(11)
            .fontWeight(FontWeight.Bold)
            .fontColor('rgba(243, 245, 249, 0.72)')
          Blank()
          if (this.dimension >= 3 && this.remainingText.length > 0) {
            Text(this.remainingText)
              .fontSize(11)
              .fontColor('rgba(243, 245, 249, 0.56)')
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Blank()

        // 中部片名与剧集说明
        Column({ space: 4 }) {
          Text(this.title)
            .fontSize(this.dimension >= 3 ? 17 : 14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#f3f5f9')
            .maxLines(this.dimension >= 3 ? 1 : 2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.dimension >= 3 || !this.hasItem) {
            Text(this.subtitle)
              .fontSize(12)
              .fontColor('rgba(243, 245, 249, 0.66)')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .margin({ bottom: 10 })

        // 进度条 + 操作排
        if (this.hasItem && this.clampedPct() > 0) {
          Stack({ alignContent: Alignment.Start }) {
            Row()
              .width('100%')
              .height(4)
              .borderRadius(2)
              .backgroundColor('rgba(255, 255, 255, 0.16)')
            Row()
              .width(`${this.clampedPct()}%`)
              .height(4)
              .borderRadius(2)
              .backgroundColor('#f5c451')
          }
          .width('100%')
          .height(4)
          .margin({ bottom: 10 })
        }

        Row({ space: 8 }) {
          Row({ space: 5 }) {
            SymbolGlyph($r('sys.symbol.play_fill'))
              .fontSize(12)
              .fontColor(['#0b0d12'])
            Text(this.hasItem ? '立即续播' : '进入媒体库')
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .fontColor('#0b0d12')
          }
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(999)
          .backgroundColor('#f3f5f9')
          .onClick((): void => {
            this.launchContinue();
          })

          if (this.dimension >= 3) {
            Row({ space: 4 }) {
              SymbolGlyph($r('sys.symbol.magnifyingglass'))
                .fontSize(12)
                .fontColor(['#f3f5f9'])
              Text('搜片')
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor('#f3f5f9')
            }
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(999)
            .backgroundColor('rgba(255, 255, 255, 0.14)')
            .onClick((): void => {
              this.launchSearch();
            })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .height('100%')
      .padding(14)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0b0d14')
    .onClick((): void => {
      this.launchContinue();
    })
  }
}
