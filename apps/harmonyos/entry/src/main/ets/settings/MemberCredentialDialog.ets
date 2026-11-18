import { pasteboard } from '@kit.BasicServicesKit';
import { Theme } from '../theme/AppTheme';
import { DialogButtonRow } from '../common/NativeDialog';

/**
 * 一次性凭据弹窗（新成员密码 / 重置后的新密码），**与「批准设备登录」同一套弹窗样式**。
 *
 * 由宿主用 `NativeDialog.options` 拉起居中的系统式弹窗
 * （`UIContext.getPromptAction().openCustomDialog`）：
 * 系统负责遮罩、进出场动效、点遮罩关闭。密码明文只出现这一次（服务端也只回一次），
 * 所以按钮行把「复制全部」放在左侧（行内点按复制仍可用），「完成」在右侧收尾。
 *
 * V1 `@Component`（宿主是 V2，V1 子组件可嵌入），只往外回一个 `onClose`。
 */
@Component
export struct MemberCredentialDialog {
  /** 卡片标题，如「小王吧」的密码（重置时）或「添加成员」的密码 */
  @Prop title: string = '';
  @Prop username: string = '';
  @Prop password: string = '';
  onClose: () => void = (): void => {
  };

  private copy(text: string): void {
    const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setDataSync(data);
  }

  @Builder
  CredentialRow(label: string, value: string, mono: boolean) {
    Row({ space: 12 }) {
      Text(label)
        .fontSize(13)
        .fontColor(Theme.textMuted)
        .width(48)
      Text(value)
        .fontSize(17)
        .fontFamily(mono ? 'monospace' : '')
        .fontColor(Theme.text)
        .layoutWeight(1)
        .textAlign(TextAlign.Start)
      SymbolGlyph($r('sys.symbol.doc_filled_on_doc'))
        .fontSize(14)
        .fontColor([Theme.textFaint])
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .onClick((): void => {
      this.copy(value);
    })
  }

  build() {
    Column() {
      Column({ space: 16 }) {
        Text(this.title.length > 0 ? this.title : '登录信息')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.text)
          .width('100%')
          .textAlign(TextAlign.Center)

        Column() {
          this.CredentialRow('账号', this.username, false)
          Divider().color(Theme.line)
          this.CredentialRow('密码', this.password, true)
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 6, bottom: 6 })
        .backgroundColor(Theme.surface)
        .borderRadius(Theme.cardRadius)
        .border({ width: 1, color: Theme.line })

        Text('密码只在这里显示一次。点击账号或密码即可复制，关闭弹窗后无法再次查看。')
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 24, right: 24, top: 24, bottom: 16 })

      DialogButtonRow({
        leftLabel: '复制全部',
        rightLabel: '完成',
        onLeft: (): void => {
          this.copy(`账号：${this.username}\n密码：${this.password}`);
        },
        onRight: (): void => {
          this.onClose();
        }
      })
    }
    .width('100%')
  }
}
