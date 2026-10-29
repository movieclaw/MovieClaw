import { Theme } from '../theme/AppTheme';

/**
 * 页面共用顶栏（返回 + 标题）。
 *
 * 为什么不用系统原生标题栏：**沉浸式布局下它不避让状态栏**——标题会和左上角的时钟叠在一起
 * （实测「关于」画在 y=17..32vp，而状态栏高约 38vp），而且返回键的上半截被状态栏吃掉、点不动。
 * 表现还随进入路径变化（同一页从不同宿主进来位置不一样），不可靠。
 * 所以统一自绘：高度把 `Theme.shellTopInset` 算进去（ArkUI 的 padding 算在 height 之内，
 * 写死 44 会把内容挤没）。
 *
 * **必须是 `@ComponentV2` 而不是 `@Builder` 函数**：`@Builder` 的**简单类型参数按值传递**，
 * 参数变了不会触发刷新——实测「数据加载完/切到另一条，顶栏标题仍是旧值」（订阅详情从
 * 「订阅详情」切「电影/剧集订阅」时最明显）。`@Param` 是响应式的，标题能跟着状态走。
 */
@ComponentV2
export struct PageTopBar {
  @Param title: string = '';
  @Event onBack: () => void = (): void => {
  };

  build() {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.chevron_left'))
        .fontSize(22)
        .fontColor([Theme.text])
        .width(38)
        .height(38)
        .onClick(() => {
          this.onBack();
        })
      Text(this.title)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        // 长串英文（微信 ID 那种）默认被当成一个整词，放不下就整段消失、只剩开头几个字；
        // BREAK_ALL = 先填满整行再在末尾省略（同「显示多少显示多少」的要求）
        .wordBreak(WordBreak.BREAK_ALL)
      Blank()
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: Theme.shellTopInset + 6, bottom: 6 })
    /*
     * 毛玻璃采样 + tint（同各页签自绘标题栏）：二级页内容不钻进顶栏区域，
     * 纯采样时顶栏是页面黑背景——tint 让它呈「深灰玻璃」而不是一条死黑。
     *
     * tint **必须直接做在本 Row 的 `backgroundColor` 上**，不能像之前那样套一层
     * `Stack + Column().height('100%')`：Stack 没有确定高度时，那个 100% 的子节点会把
     * 顶栏撑成整屏，页面内容区被挤没（设置页实测整页只剩标题、内容空白）。
     */
    .backgroundColor('rgba(90, 99, 115, 0.42)')
    .backgroundEffect({ radius: 5, saturation: 1.1, brightness: 0.95 })
  }
}
