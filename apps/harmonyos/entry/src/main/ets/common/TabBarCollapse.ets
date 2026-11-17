/**
 * 主界面内容区的滚动状态：向下滑到一定距离后，底部页签栏收起；往回滑（或滑回
 * 顶部）立刻放回整条底栏。
 *
 * 与官方栏的分工（2026-11 起按官方「上下布局」实现）：这里只汇总滚动方向出
 * 「收起/放回」信号，`MainTabsPage` 拿它驱动官方状态机——收起且有「接着看」=
 * 官方 `applyMiniBarStyle(EXPAND)`（滑动后：minibar 展开成一行、页签收成圆
 * 钮，官方组件自己摆）；收起且没有「接着看」= 官方栏走官方显隐动效整条隐藏
 * （`applyHideAnimation`），往回滑累计 10 放回，不再出自绘圆钮。
 *
 * `@ObservedV2` + `@Trace`：各页签根页在 `onDidScroll` 里上报，`MainTabsPage` 直接读。
 */
@ObservedV2
export class TabBarCollapse {
  private static instance: TabBarCollapse | null = null;

  @Trace collapsed: boolean = false;
  /** 上一次的滚动位置（离顶 vp）：`onDidScroll` 给的第二参不是位移增量，方向自己算 */
  private lastTop: number = -1;
  private direction: number = 0;
  private distance: number = 0;

  static shared(): TabBarCollapse {
    if (TabBarCollapse.instance === null) {
      TabBarCollapse.instance = new TabBarCollapse();
    }
    return TabBarCollapse.instance;
  }

  /**
   * 根页内容滚动（传当前离顶距离）：同方向累计下滑超过 6 且离顶超过 24 才收起；
   * 累计回滑超过 10、回到顶部（≤8）或点圆钮都展开。累计位移避免慢速滚动永远达不到阈值。
   *
   * **dy 自己算**：List/Scroll 的 `onDidScroll(xOffset, yOffset)` 第二参实测恒为 1，
   * 不是每帧位移；位置差才是可靠的滚动方向。
   */
  onScroll(top: number): void {
    const dy: number = this.lastTop >= 0 ? top - this.lastTop : 0;
    this.lastTop = top;
    if (top <= 8) {
      this.collapsed = false;
      this.direction = 0;
      this.distance = 0;
      return;
    }
    if (dy === 0) { return; }
    const direction: number = dy > 0 ? 1 : -1;
    this.distance = direction === this.direction ? this.distance + Math.abs(dy) : Math.abs(dy);
    this.direction = direction;
    if (direction > 0 && this.distance > 6 && top > 24) {
      this.collapsed = true;
      return;
    }
    if (direction < 0 && this.distance > 10) {
      this.collapsed = false;
    }
  }

  /** 放回整条底栏（换页签、点圆形按钮） */
  expand(): void {
    this.collapsed = false;
    this.lastTop = -1;
    this.direction = 0;
    this.distance = 0;
  }
}
