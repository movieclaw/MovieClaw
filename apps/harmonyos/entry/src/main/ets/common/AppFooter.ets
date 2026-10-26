import { Theme } from '../theme/AppTheme';

/**
 * 全局页脚：品牌联合声明「MovieClaw × AI × HarmonyOS」（携手一起干）。
 *
 * 复用到各页面底部，作为滚动内容末尾的收尾小字：英文、冷银灰、居中。
 * 它只负责文字本身；上下的留距由所在容器控制——
 * 放在 List 时外层包 `ListItem()`，放在 Scroll/Column 时直接作为子组件，
 * 页面自身在 Scroll 的 bottom padding 里用 `Theme.tabBarInset` 给底部悬浮导航栏让位。
 */
@Component
export struct AppFooter {
  /** 距上方内容的间距（默认 24，避免页脚贴得太近） */
  @Prop topSpace: number = 24;

  build() {
    Text('MovieClaw · AI · HarmonyOS')
      .fontSize(12)
      .fontColor(Theme.textFaint)
      .width('100%')
      .textAlign(TextAlign.Center)
      .padding({ top: this.topSpace })
  }
}
