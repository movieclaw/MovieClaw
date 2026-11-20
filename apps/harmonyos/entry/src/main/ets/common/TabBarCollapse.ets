/**
 * 主界面内容区的滚动状态：向下滑到一定距离后，底部页签栏收起；往回滑、滑回顶
 * 部或滑到内容最底都放回整条底栏。距内容最底不足 `NEAR_END` 时下滑不再收起：
 * 真底前面还有 `contentEndOffset` 的让位空白带和页脚，「看起来到底了」其实还能滑，
 * 在这段里收起（圆钮）马上又被到底放回整条，一来一回每滑一下闪一次。
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

  /** 距内容最底不足这个距离（vp）时，下滑不再收起底栏 */
  private static readonly NEAR_END: number = 480;

  @Trace collapsed: boolean = false;
  /** 上一次的滚动位置（离顶 vp）：`onDidScroll` 给的第二参不是位移增量，方向自己算 */
  private lastTop: number = -1;
  /** 最近一次到达内容最底时的离顶距离：与当前 top 的差判断「还在底部附近」 */
  private endTop: number = -1;
  private direction: number = 0;
  private distance: number = 0;

  static shared(): TabBarCollapse {
    if (TabBarCollapse.instance === null) {
      TabBarCollapse.instance = new TabBarCollapse();
    }
    return TabBarCollapse.instance;
  }

  /**
   * 根页内容滚动（传当前离顶距离 + 是否已到内容底部）：同方向累计下滑超过 6 且
   * 离顶超过 24 才收起；累计回滑超过 10、回到顶部（≤8）、滑到内容最底或点圆钮
   * 都展开。累计位移避免慢速滚动永远达不到阈值。
   *
   * **dy 自己算**：List/Scroll 的 `onDidScroll(xOffset, yOffset)` 第二参实测恒为 1，
   * 不是每帧位移；位置差才是可靠的滚动方向。
   */
  onScroll(top: number, atEnd: boolean): void {
    const dy: number = this.lastTop >= 0 ? top - this.lastTop : 0;
    this.lastTop = top;
    if (top <= 8) {
      this.collapsed = false;
      this.direction = 0;
      this.distance = 0;
      return;
    }
    /*
     * 滑到内容最底：底下已没有内容，下一步多半是换页签/离开本页——放回整条底栏；
     * 记下最底位置（endTop，取最小的，橡皮筋过冲不算），方向累计清零，离开底部后
     * 重新起算（下滑重新累计 6 才再收起）。
     */
    if (atEnd) {
      if (this.endTop < 0 || top < this.endTop) {
        this.endTop = top;
      }
      if (this.collapsed) {
        this.collapsed = false;
      }
      this.distance = 0;
      return;
    }
    if (dy === 0) { return; }
    /*
     * 底部附近（距最近到达的最底不足 NEAR_END）下滑不收起：这段里「下滑收起」和
     * 「到底放回」两个逻辑会打架——收起成圆钮的下一帧滑到真底又整条放回，每滑一
     * 下交替一次。上滑照常走累计放回。
     */
    if (this.endTop > 0 && this.endTop - top < TabBarCollapse.NEAR_END && dy > 0) {
      this.distance = 0;
      return;
    }
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
