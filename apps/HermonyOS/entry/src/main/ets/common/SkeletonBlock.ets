import { Theme } from '../theme/AppTheme';

/**
 * 闪烁占位块（对应 iOS `DiscoverSkeletonBlock`）：
 * 白 0.04 ↔ 0.08，0.9 秒 easeInOut 往复（`repeatForever(autoreverses: true)`）。
 */
@ComponentV2
export struct SkeletonBlock {
  @Param cornerRadius: number = 8;
  @Local private dim: boolean = false;

  aboutToAppear(): void {
    this.getUIContext().animateTo({
      duration: 900,
      curve: Curve.EaseInOut,
      iterations: -1,
      playMode: PlayMode.AlternateReverse
    }, (): void => {
      this.dim = true;
    });
  }

  build() {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor(this.dim ? 'rgba(255,255,255,0.04)' : 'rgba(255,255,255,0.08)')
      .borderRadius(this.cornerRadius)
  }
}

/**
 * 一行骨架（对应 iOS `DiscoverRowSkeleton`）：标题 + 4 张占位（126×189），末尾裁掉。
 */
@ComponentV2
export struct SkeletonRow {
  @Param title: string = '';
  @Param cardWidth: number = 126;

  build() {
    Column({ space: 8 }) {
      Text(this.title)
        .fontSize(20)
        .fontWeight(600)
        .fontColor(Theme.text)
        .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
      Row({ space: 12 }) {
        ForEach([0, 1, 2, 3], (index: number) => {
          // 占位块宽高写死（对应 iOS `frame(width: cardWidth, height: cardWidth * 1.5)`）
          Column() {
            SkeletonBlock({ cornerRadius: Theme.posterRadius })
          }
          .width(this.cardWidth)
          .height(this.cardWidth * 1.5)
        }, (index: number) => `sk-${index}`)
      }
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
      // 4 张占位宽过手机屏：多出的靠裁掉（同 iOS `.clipped()`）
      .clip(true)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

/**
 * Hero 骨架（对应 iOS `SubsHomeHeroSkeleton`）：`DiscoverSkeletonBlock(cornerRadius: 0)` 撑满 Hero 高。
 */
@ComponentV2
export struct HeroSkeleton {
  @Param blockHeight: number = 500;

  build() {
    Column() {
      SkeletonBlock({ cornerRadius: 0 })
    }
    .width('100%')
    .height(this.blockHeight)
  }
}
