import { pasteboard } from '@kit.BasicServicesKit';
import { Theme } from '../theme/AppTheme';

/**
 * 一次性凭据弹窗（新成员密码 / 重置后的新密码），**与「批准设备登录」同一套弹窗样式**。
 *
 * 由宿主用 `UIContext.getPromptAction().openCustomDialog({ builder, alignment: Bottom, … })` 拉起：
 * 系统负责遮罩、进出场动效、点遮罩关闭。密码明文只出现这一次（服务端也只回一次），
 * 所以卡片里把「复制」做成主操作，并把「关掉就再也看不到」写在卡片上。
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
    Column({ space: 16 }) {
      Text(this.title.length > 0 ? this.title : '登录信息')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.text)
        .width('100%')
        .textAlign(TextAlign.Start)

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

      Column({ space: 10 }) {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.doc_filled_on_doc'))
            .fontSize(16)
            .fontColor([Theme.text])
          Text('复制全部登录信息')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text)
        }
        .width('100%')
        .height(50)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Theme.glassFill)
        .borderRadius(18)
        .onClick((): void => {
          this.copy(`账号：${this.username}\n密码：${this.password}`);
        })

        Text('完成')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#0b0d12')
          .textAlign(TextAlign.Center)
          .width('100%')
          .padding({ top: 15, bottom: 15 })
          .backgroundColor(Theme.accent)
          .borderRadius(18)
          .onClick((): void => {
            this.onClose();
          })
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(24)
  }
}
