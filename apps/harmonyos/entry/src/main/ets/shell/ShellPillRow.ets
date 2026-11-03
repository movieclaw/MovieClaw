/**
 * 车机 / TV 详情页共用的「胶囊行」：横向滚的一排小胶囊（选季 / 长剧集分段页签）。
 * 数据（ShellPillSpec 列表）由各端拼好传入；胶囊长什么样由各端注入
 * （车机 CarDetailPill 触控态、TV DetailPill 获焦态），行壳（Scroll/Row/ForEach）共用。
 */

/** 一颗胶囊的数据（key 供 ForEach 复用；label/selected/onActivate 直通各端胶囊组件） */
export class ShellPillSpec {
  readonly key: string;
  readonly label: string;
  readonly selected: boolean;
  readonly onActivate: () => void;

  constructor(key: string, label: string, selected: boolean, onActivate: () => void) {
    this.key = key;
    this.label = label;
    this.selected = selected;
    this.onActivate = onActivate;
  }
}

@ComponentV2
export struct ShellPillRow {
  /** 这一行要渲染的胶囊 */
  @Param pills: ShellPillSpec[] = [];
  /** 胶囊间距（选季 10、分段 8，各端按原样式传） */
  @Param spacing: number = 10;
  /** 行两端留白（各端 Metrics.edge） */
  @Param edgePadding: number = 0;
  /** 单颗胶囊的渲染（各端注入自己的胶囊组件） */
  @BuilderParam pillRenderer: (pill: ShellPillSpec) => void;

  build() {
    Scroll() {
      Row({ space: this.spacing }) {
        ForEach(this.pills, (pill: ShellPillSpec) => {
          this.pillRenderer(pill)
        }, (pill: ShellPillSpec) => pill.key)
      }
      .padding({ left: this.edgePadding, right: this.edgePadding })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .fadingEdge(false)
    .width('100%')
  }
}
