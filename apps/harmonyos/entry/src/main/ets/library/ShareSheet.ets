import { pasteboard } from '@kit.BasicServicesKit';
import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { ApiError } from '../api/ApiClient';
import { ShareView } from '../api/Models';
import { shareAbsoluteUrl, shareCopyText } from '../common/ShareLinks';

/** 有效期档（对应 iOS 的 1 / 3 / 7 / 30 天；后端只收这四档，没有「永久」） */
export class ShareExpiry {
  readonly days: number;
  readonly label: string;

  constructor(days: number, label: string) {
    this.days = days;
    this.label = label;
  }
}

export const SHARE_EXPIRIES: ShareExpiry[] = [
  new ShareExpiry(1, '1 天'),
  new ShareExpiry(3, '3 天'),
  new ShareExpiry(7, '7 天'),
  new ShareExpiry(30, '30 天')
];

/** 把后端的话透出来，别自己编 */
export function shareMessage(error: Object): string {
  if (error instanceof ApiError) {
    return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
  }
  const text: string = `${error}`;
  return text.length > 0 ? text : '分享操作失败';
}

/** 复制到剪贴板；返回是否成功（失败要如实说，别假装复制了） */
export function copyToClipboard(text: string): boolean {
  try {
    const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setDataSync(data);
    return true;
  } catch (error) {
    return false;
  }
}

/**
 * 分享链接的内容区（主人侧）：没建过就建，建过就显示链接与访问情况。
 *
 * **本组件是 V1 `@Component`**：用 `@Prop` 接外部数据、用普通回调字段接动作
 * （`@Event` 是 V2 的东西，`@Prop` 是 V1 的，两者不能混用——混了会报
 * 「'@Prop' decorator can only be used in a 'struct' decorated with '@Component'」）。
 * 调用方 `LibraryItemDetailPage` 也是 V1，所以两边一致。
 */
@Component
export struct SharePanel {
  /** 已有链接（null = 还没建过） */
  @Prop share: ShareView | null = null;
  @Prop busy: boolean = false;
  /**
   * 内容区开头的一句话。默认针对单片；合集分享由调用方传整册的说法
   * （同 iOS `LibraryShareSheet` 的 `seasonSummary`，条目 / 合集共用同一弹层）。
   */
  intro: string = '生成一条公开链接，拿到链接的人不用登录就能看这部片的信息页。';
  /** 建链接：有效期天数 + 可选密码 */
  onCreate: (days: number, password: string) => void = (): void => {
  };
  /** 停止分享 */
  onRevoke: () => void = (): void => {
  };

  @State private days: number = 7;
  @State private password: string = '';
  /** 刚复制完的那一行（1.6 秒后自己收回，同 iOS copiedRow） */
  @State private copiedRow: string = '';

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  /** 绝对分享地址：后端没配外部访问时给的是相对路径 /s/{slug}，用当前服务器补全 */
  private absoluteUrl(view: ShareView): string {
    const origin: string = AppModel.shared.client !== null ? AppModel.shared.client.origin : '';
    return shareAbsoluteUrl(view.url, origin);
  }

  private copy(text: string, row: string, what: string): void {
    // **复制失败要如实说**——静默失败会让用户以为链接已经在剪贴板里了
    if (copyToClipboard(text)) {
      this.copiedRow = row;
      this.toast(`${what}已复制`);
      setTimeout((): void => {
        if (this.copiedRow === row) {
          this.copiedRow = '';
        }
      }, 1600);
    } else {
      this.toast('复制失败，请手动选中复制');
    }
  }

  private confirmRevoke(): void {
    this.getUIContext().showAlertDialog({
      title: '取消分享',
      message: '取消后这条链接立刻失效，已经拿到链接的人也打不开了。',
      primaryButton: {
        value: '再想想',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '取消分享',
        action: (): void => {
          this.onRevoke();
        }
      }
    });
  }

  build() {
    if (this.share === null) {
      this.CreateForm()
    } else {
      this.ExistingCard(this.share as ShareView)
    }
  }

  @Builder
  CreateForm() {
    Column({ space: 12 }) {
      Text(this.intro)
        .fontSize(13)
        .fontColor(Theme.textMuted)
        .width('100%')

      Text('有效期')
        .fontSize(13)
        .fontColor(Theme.textMuted)
        .width('100%')
      Row({ space: 8 }) {
        ForEach(SHARE_EXPIRIES, (option: ShareExpiry) => {
          Text(option.label)
            .fontSize(13)
            .fontColor(this.days === option.days ? '#0b0d12' : Theme.textMuted)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor(this.days === option.days ? Theme.accent : Theme.glassFill)
            .borderRadius(14)
            .onClick(() => {
              this.days = option.days;
            })
        }, (option: ShareExpiry) => `${option.days}`)
      }
      .width('100%')

      Text('密码（可选）')
        .fontSize(13)
        .fontColor(Theme.textMuted)
        .width('100%')
      TextInput({ text: this.password, placeholder: '留空就不需要密码' })
        .width('100%')
        .height(42)
        .fontSize(15)
        .fontColor(Theme.text)
        .backgroundColor(Theme.surfaceRaised)
        .borderRadius(10)
        .onChange((value: string): void => {
          this.password = value;
        })

      Text(this.busy ? '正在生成…' : '生成链接')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.busy ? Theme.textFaint : '#0b0d12')
        .textAlign(TextAlign.Center)
        .width('100%')
        .padding({ top: 13, bottom: 13 })
        .backgroundColor(this.busy ? Theme.glassFill : Theme.accent)
        .borderRadius(Theme.cardRadius)
        .onClick(() => {
          if (!this.busy) {
            this.onCreate(this.days, this.password);
          }
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
  }

  @Builder
  ExistingCard(view: ShareView) {
    Column({ space: 12 }) {
      // 链接 / 密码：各带一枚复制键（同 iOS copyRow）
      this.CopyRow('链接', this.absoluteUrl(view), 'link')
      if (view.password !== null && view.password !== undefined && view.password.length > 0) {
        this.CopyRow('密码', view.password, 'password')
      }

      Column({ space: 6 }) {
        this.InfoLine('访问次数', `${view.view_count} 次`)
        this.InfoLine('创建于', view.created_at)
        this.InfoLine('有效期至', view.expires_at)
        if (view.last_accessed_at !== null && view.last_accessed_at !== undefined
          && view.last_accessed_at.length > 0) {
          this.InfoLine('最近访问', view.last_accessed_at)
        }
      }
      .width('100%')
      .padding(12)
      .backgroundColor(Theme.surfaceRaised)
      .borderRadius(10)

      if (!view.url.startsWith('http://') && !view.url.startsWith('https://')) {
        Text('链接用的是当前连接的服务器地址。在「设置 → 网络 → 外部访问」填写外网地址后，链接会用该地址生成。')
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .width('100%')
      }

      // 一段可以直接粘进聊天框的话（同 iOS shareCopyText：《标题》 链接：… 密码：…）
      Text(this.hasPassword(view) ? '复制链接和密码' : '复制链接')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor('#0b0d12')
        .textAlign(TextAlign.Center)
        .width('100%')
        .padding({ top: 13, bottom: 13 })
        .backgroundColor(Theme.accent)
        .borderRadius(Theme.cardRadius)
        .onClick(() => {
          this.copy(shareCopyText(view.title, this.absoluteUrl(view), view.password ?? ''), 'combined',
            '链接和密码');
        })

      Text('取消分享')
        .fontSize(15)
        .fontColor(Theme.danger)
        .textAlign(TextAlign.Center)
        .width('100%')
        .padding({ top: 12, bottom: 12 })
        .backgroundColor(Theme.glassFill)
        .borderRadius(Theme.cardRadius)
        .onClick(() => {
          this.confirmRevoke();
        })

      Text('注意：拿到链接的人在有效期内不用登录就能打开，访客的播放会出现在「活动」页。改主意了就点「取消分享」。')
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
  }

  private hasPassword(view: ShareView): boolean {
    return view.password !== null && view.password !== undefined && view.password.length > 0;
  }

  /** 一行可复制的信息（同 iOS copyRow：标签 + 值 + 复制键） */
  @Builder
  CopyRow(label: string, value: string, row: string) {
    Row({ space: 10 }) {
      Text(label)
        .fontSize(15)
        .fontColor(Theme.textMuted)
        .width(34)
      if (row === 'password') {
        SymbolGlyph($r('sys.symbol.lock_fill'))
          .fontSize(12)
          .fontColor([Theme.textFaint])
      }
      Text(value)
        .fontSize(15)
        .fontColor(Theme.text)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .copyOption(CopyOptions.LocalDevice)
      Text(this.copiedRow === row ? '已复制' : '复制')
        .fontSize(14)
        .fontColor(this.copiedRow === row ? Theme.ok : Theme.accentStrong)
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .backgroundColor(Theme.glassFill)
        .borderRadius(12)
        .onClick(() => {
          this.copy(value, row, label);
        })
    }
    .width('100%')
  }

  @Builder
  InfoLine(label: string, value: string) {
    Row({ space: 10 }) {
      Text(label).fontSize(12).fontColor(Theme.textFaint)
      Blank()
      Text(value)
        .fontSize(12)
        .fontColor(Theme.textMuted)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
  }
}
