import { Theme } from '../theme/AppTheme';
import { RemoteImage } from './RemoteImage';

/**
 * 沉浸大图的**共用实现**：整幅图 + 顶部压暗 + 底部渐变。
 *
 * 为什么要有这个文件：条目详情页的 hero 与订阅轮播的 hero 是**同一张版式**
 * （对应 iOS 的 `hero(_:)` 与 `ImmersiveHeroBackdrop`，两者都是「整幅图 + 上压暗 + 下渐隐」），
 * 但之前是两页各写一遍——于是「高度不同、渐变不同、取图带不带派生变体不同」，
 * 同一部剧在两个页面里取景就不一样。**统一写，两边调用**。
 *
 * 高度缺省用 `Theme.heroHeight`（`min(屏宽 × 1.15, 屏高 × 0.62)`，逐值照搬 iOS）。
 * 页面自己的叠加内容（片名、时刻、指示器）由调用方**在 Builder 之后再叠**，
 * 这样两个页面共享底图、各自叠各的。
 */
@Builder
export function ImmersiveHeroBackdrop(url: string, heroHeight: number) {
  Stack({ alignContent: Alignment.Bottom }) {
    // 底图 + 顶部压暗（沉浸式下状态栏时钟与顶栏按钮压在图上，亮底图会吃掉白字）
    Stack({ alignContent: Alignment.Top }) {
      RemoteImage({ url: url })
        .width('100%')
        .height('100%')
      Column()
        .width('100%')
        .height(Theme.statusBarInset + 72)
        .linearGradient({ angle: 180, colors: [['rgba(0,0,0,0.5)', 0], ['rgba(0,0,0,0)', 1]] })
    }
    .width('100%')
    .height('100%')

    // 底部渐隐：融进页面底色（iOS 用 mask 在 0.56~1 之间渐隐，这里等价成一条渐变）
    Column()
      .width('100%')
      .height(heroHeight * 0.45)
      .linearGradient({ angle: 180, colors: [['rgba(0,0,0,0)', 0], [Theme.bg, 1]] })
  }
  .width('100%')
  .height(heroHeight)
}
