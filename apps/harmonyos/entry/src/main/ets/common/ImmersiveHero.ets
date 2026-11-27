import { Theme } from '../theme/AppTheme';
import { RemoteImage } from './RemoteImage';
import { AmbientColorStore, AmbientPalette } from './AmbientColor';

/**
 * 沉浸大图共用组件（全面升级：实时主色极光光晕 + 底边融合色 + `.geometryTransition` 一镜到底支持）：
 *
 * - 自动从剧照采样电影主色调（`AmbientColorStore`），在底部与中段晕染出柔和色彩过渡，彻底告别死黑切边；
 * - 传入 `geometryId` 时自动挂载 `.geometryTransition(id, { follow: true })`，与海报墙卡片形成丝滑弹簧一镜到底转场。
 */
@ComponentV2
export struct ImmersiveAmbientHero {
  @Param url: string = '';
  @Param heroHeight: number = Theme.heroHeight;
  @Param geometryId: string = '';
  @Local private ambient: AmbientColorStore = AmbientColorStore.shared;

  private palette(): AmbientPalette {
    // 访问 revision 建立 V2 响应式订阅，图片取色完成后自动柔和刷出氛围光
    const rev: number = this.ambient.revision;
    return rev >= 0 ? this.ambient.orFallback(this.url) : AmbientPalette.fallback;
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 底层呼吸极光晕染（主色径向环境光）
      Column()
        .width('100%')
        .height('100%')
        .radialGradient({
          center: ['50%', '38%'],
          radius: '78%',
          colors: [[this.palette().halo(0.42), 0], [Theme.bg, 1]]
        })

      Stack({ alignContent: Alignment.Top }) {
        if (this.geometryId.length > 0) {
          RemoteImage({ url: this.url, ambient: true })
            .width('100%')
            .height('100%')
            .geometryTransition(this.geometryId, { follow: true })
        } else {
          RemoteImage({ url: this.url, ambient: true })
            .width('100%')
            .height('100%')
        }
        Column()
          .width('100%')
          .height(Theme.statusBarInset + 76)
          .linearGradient({ angle: 180, colors: [['rgba(0,0,0,0.54)', 0], ['rgba(0,0,0,0)', 1]] })
      }
      .width('100%')
      .height('100%')

      // 双段电影级底边融合：上段透出提取的剧照主色微光，下段平滑沉入页面底色
      Column()
        .width('100%')
        .height(this.heroHeight * 0.52)
        .linearGradient({
          angle: 180,
          colors: [
            ['rgba(0,0,0,0)', 0],
            [this.palette().edge(0.68), 0.58],
            [Theme.bg, 1]
          ]
        })
    }
    .width('100%')
    .height(this.heroHeight)
  }
}

@Builder
export function ImmersiveHeroBackdrop(url: string, heroHeight: number, geometryId: string = '') {
  ImmersiveAmbientHero({ url: url, heroHeight: heroHeight, geometryId: geometryId })
}
