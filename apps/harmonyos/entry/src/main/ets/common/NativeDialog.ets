import { promptAction } from '@kit.ArkUI';
import { Theme } from '../theme/AppTheme';

/**
 * 系统式自定义弹窗的统一规格（对齐系统 AlertDialog 的观感：居中、定宽、大圆角、
 * 底部一排文字按钮）。
 *
 * 之前设置域的 8 个 `openCustomDialog` 站点各自写一份「贴底 + 屏宽 - 32」的参数，
 * 看起来像自定义底卡而不是系统弹窗。现在全部改走这里：容器居中、宽屏封顶 336vp、
 * 圆角 24，内容组件只管画标题/正文/输入区和 `DialogButtonRow`。
 */
export class NativeDialog {
  /** 弹窗宽度（vp）：宽屏封顶 336（系统对话框的标准宽），窄屏左右各留 32 */
  static widthOf(screenWidthVp: number): number {
    return Math.min(336, Math.round(screenWidthVp - 64));
  }

  /** 居中弹窗的容器参数：遮罩、进出场、输入法避让、点遮罩可关全交给系统 */
  static options(builder: () => void, screenWidthVp: number): promptAction.CustomDialogOptions {
    return {
      builder: builder,
      width: NativeDialog.widthOf(screenWidthVp),
      alignment: DialogAlignment.Center,
      keyboardAvoidMode: KeyboardAvoidMode.DEFAULT,
      autoCancel: true,
      maskColor: 'rgba(0,0,0,0.6)',
      backgroundColor: Theme.surfaceRaised,
      cornerRadius: 24
    };
  }
}

/**
 * 系统式弹窗的按钮行：底部一排文字按钮平分宽度，中间细缝隔开，上沿一条发丝线
 * （对齐系统 AlertDialog 的按钮排布；取消在左灰显、确认在右用强调色）。
 *
 * `leftLabel` 留空 = 只渲染右侧一个通栏按钮（「完成」这类单动作结果页用）。
 * 按钮**没有禁用态**：进行中/不可点由调用方改 label 和文字色表达，动作里自己加守卫。
 *
 * V1 `@Component`：宿主弹窗内容既有 V1 也有 V2，V1 两边都能嵌。
 */
@Component
export struct DialogButtonRow {
  /** 左侧按钮文字；空 = 不渲染左侧（右侧通栏） */
  @Prop leftLabel: string = '';
  @Prop rightLabel: string = '';
  /** 文字色覆盖（默认：左 textMuted / 右 accentStrong）；危险操作传 Theme.danger */
  @Prop leftColor: string = '';
  @Prop rightColor: string = '';
  onLeft: () => void = (): void => {
  };
  onRight: () => void = (): void => {
  };

  build() {
    Row() {
      if (this.leftLabel.length > 0) {
        Column() {
          Text(this.leftLabel)
            .fontSize(16)
            .fontColor(this.leftColor.length > 0 ? this.leftColor : Theme.textMuted)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .height(48)
        .justifyContent(FlexAlign.Center)
        .onClick((): void => {
          this.onLeft();
        })

        Divider()
          .vertical(true)
          .height(24)
          .color(Theme.lineStrong)
      }

      Column() {
        Text(this.rightLabel)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.rightColor.length > 0 ? this.rightColor : Theme.accentStrong)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .height(48)
      .justifyContent(FlexAlign.Center)
      .onClick((): void => {
        this.onRight();
      })
    }
    .width('100%')
    .border({ width: { top: 1 }, color: { top: Theme.line } })
  }
}
