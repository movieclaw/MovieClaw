import { Theme } from '../theme/AppTheme';
import { PageTopBar } from '../common/PageTopBar';
import { AppFooter } from '../common/AppFooter';
import { AppModel } from '../common/AppModel';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { AppConfigPayload, AppConfigView, WebPortPayload } from '../api/Models';

/**
 * 设置 → 网络 → 外部访问（对应 iOS `ExternalAccessSettingsView`）。
 *
 * 两件事：**外部访问地址**（可从外部访问本应用的完整 http(s) 地址，通知跳转、
 * AI 回复链接与对外回调用，保存立即生效）和**对外端口**（改了要全量重启服务器，
 * 所以要走二次确认；不可配置的部署形态置灰）。
 *
 * 端口改完后服务器在新端口重启，当前连接可能已断：这一页就地变成
 * 「对外端口已改为 X」的提示卡（同 iOS `newPort` 态）。
 */

/** 路由表注册用（router_map.json 的 buildMethod） */
@Builder
export function ExternalAccessBuilder() {
  ExternalAccessPage()
}

/** `AppConfigPayload` 全可选，用类绕开 `arkts-no-untyped-obj-literals` */
class ExternalUrlPayload implements AppConfigPayload {
  external_url?: string | null;
}

/** `WebPortPayload` 同理 */
class PortPayload implements WebPortPayload {
  port?: number | null;
}

@ComponentV2
export struct ExternalAccessPage {
  private navStack: NavPathStack = new NavPathStack();
  private started: boolean = false;
  @Local private config: AppConfigView | null = null;
  @Local private loading: boolean = true;
  @Local private errorMessage: string = '';
  /** 改完端口后服务器在新端口重启：这页改提示新地址（当前连接可能已断） */
  @Local private newPort: number = -1;
  /** 编辑弹层：'url' = 外部访问地址 / 'port' = 对外端口（一个组件一个 bindSheet） */
  @Local private showSheet: boolean = false;
  @Local private sheetKind: string = '';
  @Local private draftUrl: string = '';
  @Local private draftPort: string = '';
  @Local private busy: boolean = false;
  @Local private editorError: string = '';

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '加载失败';
  }

  private async load(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.loading = true;
    try {
      this.config = await api.appShow();
      this.errorMessage = '';
    } catch (error) {
      this.errorMessage = this.messageOf(error);
    } finally {
      this.loading = false;
    }
  }

  // MARK: 校验（同 iOS `NetworkSettingsValidation`）

  /** http(s) 完整地址；空串算有效（留空 = 清除 / 未设置） */
  private validUrl(value: string): boolean {
    const text: string = value.trim();
    if (text.length === 0) {
      return true;
    }
    if (/\s/.test(text)) {
      return false;
    }
    const hit: RegExpMatchArray | null = text.match(/^(https?):\/\/([^/:]+)/);
    return hit !== null && hit[2].length > 0;
  }

  /** 1–65535 的整数端口；无效返回 -1 */
  private validPort(value: string): number {
    const text: string = value.trim();
    if (text.length === 0 || !/^\d+$/.test(text)) {
      return -1;
    }
    const port: number = Number(text);
    if (!Number.isInteger(port) || port < 1 || port > 65535) {
      return -1;
    }
    return port;
  }

  /** 当前服务器地址（编辑地址时的占位与「使用当前服务器地址」） */
  private origin(): string {
    const client = AppModel.shared.client;
    return client !== null ? client.origin : '';
  }

  /** 当前访问用的端口（App 连的 origin 里的端口；https 默认 443、http 默认 80） */
  private seenPort(): number {
    const origin: string = this.origin();
    const withPort: RegExpMatchArray | null = origin.match(/^https?:\/\/[^/:]+:(\d+)/);
    if (withPort !== null) {
      return Number(withPort[1]);
    }
    return origin.startsWith('https') ? 443 : 80;
  }

  /** 新端口下应当访问的地址（origin 换端口） */
  private portUrl(port: number): string {
    const origin: string = this.origin();
    const hit: RegExpMatchArray | null = origin.match(/^(https?:\/\/[^/:]+)(:\d+)?(\/.*)?$/);
    if (hit === null) {
      return `端口 ${port}`;
    }
    return `${hit[1]}:${port}${hit[3] !== undefined ? hit[3] : ''}`;
  }

  private portSourceLabel(source: string): string {
    if (source === 'setting') {
      return '应用内设置';
    }
    if (source === 'env') {
      return '环境变量';
    }
    return '默认';
  }

  // MARK: 动作

  private openUrlEditor(): void {
    const config: AppConfigView | null = this.config;
    if (config === null) {
      return;
    }
    this.sheetKind = 'url';
    this.draftUrl = config.external_url;
    this.editorError = '';
    this.showSheet = true;
  }

  private openPortEditor(): void {
    const config: AppConfigView | null = this.config;
    if (config === null || !config.web_port_configurable) {
      return;
    }
    this.sheetKind = 'port';
    this.draftPort = `${config.web_port}`;
    this.editorError = '';
    this.showSheet = true;
  }

  /** 保存外部访问地址（保存即生效） */
  private async saveUrl(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.busy) {
      return;
    }
    this.busy = true;
    this.editorError = '';
    try {
      const body: ExternalUrlPayload = new ExternalUrlPayload();
      body.external_url = this.draftUrl.trim();
      this.config = await api.appSet(body);
      this.showSheet = false;
    } catch (error) {
      this.editorError = this.messageOf(error);
    } finally {
      this.busy = false;
    }
  }

  /** 端口改完要重启：先过确认（同 iOS 的 alert），再保存。
   *  `target` 是弹窗里展示的端口；`wirePort` 是实际提交值（恢复默认提交 0 = 清除设置，同 iOS） */
  private askPortConfirm(target: number, wirePort: number): void {
    let mapping: string = '';
    if (this.seenPort() !== (this.config as AppConfigView).web_port) {
      mapping = `当前通过端口 ${this.seenPort()} 访问，服务器监听 `
        + `${(this.config as AppConfigView).web_port}，中间存在端口映射或反向代理。`;
    }
    this.getUIContext().showAlertDialog({
      title: '确认修改端口并重启？',
      message: `服务器将重启并监听端口 ${target}，当前地址可能失效。${mapping}`
        + 'Docker bridge 部署必须同步修改 compose 中 ports 的容器侧端口并重建容器；'
        + '反向代理必须调整目标端口。只想改变访问端口时，可直接调整映射或反向代理。',
      primaryButton: {
        value: '修改并重启',
        action: (): void => {
          this.savePort(wirePort);
        }
      },
      secondaryButton: {
        value: '取消',
        action: (): void => {
        }
      }
    });
  }

  /** 保存端口（0 = 清除设置、恢复默认）；改完提示新端口（同 iOS `onSaved`） */
  private async savePort(target: number): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const config: AppConfigView | null = this.config;
    if (api === null || config === null || this.busy) {
      return;
    }
    this.busy = true;
    this.editorError = '';
    try {
      const body: PortPayload = new PortPayload();
      body.port = target;
      const saved: AppConfigView = await api.appPortSet(body);
      this.config = saved;
      this.newPort = saved.web_port !== config.web_port ? saved.web_port : -1;
      this.showSheet = false;
    } catch (error) {
      this.editorError = this.messageOf(error);
    } finally {
      this.busy = false;
    }
  }

  // MARK: 视图

  build() {
    NavDestination() {
      Column() {
        PageTopBar({ title: '外部访问', onBack: (): void => {
          this.navStack.pop();
        }})
        if (this.loading) {
          Column({ space: 10 }) {
            LoadingProgress().width(24).height(24).color(Theme.textMuted)
            Text('正在加载…').fontSize(13).fontColor(Theme.textFaint)
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.config === null) {
          Column({ space: 10 }) {
            Text('外部访问配置加载失败').fontSize(15).fontColor(Theme.text)
            Text(this.errorMessage).fontSize(13).fontColor(Theme.textMuted)
            Text('重试').fontSize(14).fontColor(Theme.accentStrong).onClick(() => {
              this.load();
            })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          Scroll() {
            Column({ space: 14 }) {
              if (this.newPort >= 0) {
                this.PortChangedCard()
              } else {
                this.UrlCard()
                this.PortCard()
                this.RejectedCard()
              }
              AppFooter()
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 8, bottom: Theme.tabBarInset })
          }
          .layoutWeight(1)
          .align(Alignment.TopStart)
          .scrollBar(BarState.Off)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg)
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
      if (!this.started) {
        this.started = true;
        this.load();
      }
    })
    .bindSheet($$this.showSheet, this.EditorSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.bg
    })
  }

  /** 外部访问地址：值 + chevron，点开编辑（同 iOS `network-external-url-settings`） */
  @Builder
  UrlCard() {
    Column({ space: 8 }) {
      Row({ space: 12 }) {
        Column({ space: 3 }) {
          Text('外部访问地址')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text)
            .width('100%')
          Text((this.config as AppConfigView).external_url.length > 0
            ? (this.config as AppConfigView).external_url : '未设置')
            .fontSize(12)
            .fontColor(Theme.textMuted)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(14)
          .fontColor([Theme.textFaint])
      }
      .width('100%')
      .onClick((): void => {
        this.openUrlEditor();
      })

      Text('用于通知跳转、AI 回复链接与对外回调。保存后立即生效。')
        .fontSize(11)
        .fontColor(Theme.textFaint)
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  /** 对外端口：可配置才可点（同 iOS `webPortConfigurable` 置灰） */
  @Builder
  PortCard() {
    Column({ space: 8 }) {
      Row({ space: 12 }) {
        Column({ space: 3 }) {
          Text('对外端口')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text)
            .width('100%')
          Text(`${(this.config as AppConfigView).web_port} · ${
            this.portSourceLabel((this.config as AppConfigView).web_port_source)}`)
            .fontSize(12)
            .fontColor(Theme.textMuted)
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(14)
          .fontColor([Theme.textFaint])
      }
      .width('100%')
      .opacity((this.config as AppConfigView).web_port_configurable ? 1 : 0.5)
      .onClick((): void => {
        this.openPortEditor();
      })

      Text((this.config as AppConfigView).web_port_configurable
        ? '修改监听端口会重启服务器。反向代理和 Docker 端口映射也需要同步调整。'
        : '当前部署由外部进程提供入口，请在启动命令或反向代理中修改端口。')
        .fontSize(11)
        .fontColor(Theme.textFaint)
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  /** 上次启动绑不上的端口：提醒已回落（同 iOS `webPortRejected`） */
  @Builder
  RejectedCard() {
    if ((this.config as AppConfigView).web_port_rejected !== null
      && (this.config as AppConfigView).web_port_rejected !== undefined) {
      Text(`端口 ${(this.config as AppConfigView).web_port_rejected} 无法绑定，`
        + `已回落到 ${(this.config as AppConfigView).web_port}。`)
        .fontSize(12)
        .fontColor(Theme.warning)
        .width('100%')
        .padding(12)
        .backgroundColor(Theme.surface)
        .borderRadius(Theme.cardRadius)
        .border({ width: 1, color: Theme.line })
    }
  }

  /** 端口已改、服务器正在新端口重启：提示新地址（同 iOS `newPort` 态） */
  @Builder
  PortChangedCard() {
    Column({ space: 10 }) {
      Text(`对外端口已改为 ${this.newPort}`)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .width('100%')
      Text(this.portUrl(this.newPort))
        .fontSize(13)
        .fontFamily('monospace')
        .fontColor(Theme.text)
        .copyOption(CopyOptions.InApp)
        .width('100%')
        .padding(10)
        .backgroundColor('rgba(0, 0, 0, 0.28)')
        .borderRadius(10)
        .border({ width: 1, color: Theme.line })
      Text(`当前连接地址可能已失效。Docker bridge 部署需将端口映射的容器侧端口改为 ${this.newPort} `
        + '并重建容器。重启后请在登录页的「更换服务器」中填写新地址。')
        .fontSize(12)
        .fontColor(Theme.textMuted)
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  /** 弹层内容：地址编辑 / 端口编辑（一个 sheet 两个形态） */
  @Builder
  EditorSheet() {
    if (this.sheetKind === 'url') {
      this.UrlSheet()
    } else {
      this.PortSheet()
    }
  }

  /** 外部访问地址编辑（同 iOS `ExternalAccessEditor` 的 url 形态） */
  @Builder
  UrlSheet() {
    Column({ space: 14 }) {
      Text('外部访问地址')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .padding({ top: 16 })
      Text('填写可从外部访问的完整 http(s) 地址；经反向代理访问时填写代理后的地址。留空可清除设置。')
        .fontSize(13)
        .fontColor(Theme.textMuted)
        .width('100%')
      TextInput({ text: this.draftUrl, placeholder: this.origin() })
        .width('100%')
        .height(42)
        .fontSize(15)
        .fontColor(Theme.text)
        .backgroundColor(Theme.surfaceRaised)
        .borderRadius(10)
        .padding({ left: 12, right: 12 })
        .onChange((value: string): void => {
          this.draftUrl = value;
        })
      Text('使用当前服务器地址')
        .fontSize(13)
        .fontColor(Theme.accentStrong)
        .onClick((): void => {
          let origin: string = this.origin();
          while (origin.endsWith('/')) {
            origin = origin.substring(0, origin.length - 1);
          }
          this.draftUrl = origin;
        })
      if (!this.validUrl(this.draftUrl)) {
        Text('请输入完整的 http(s) 地址。').fontSize(12).fontColor(Theme.warning).width('100%')
      }
      if (this.editorError.length > 0) {
        Text(this.editorError).fontSize(12).fontColor(Theme.danger).width('100%')
      }
      Row({ space: 10 }) {
        Text('取消')
          .fontSize(15)
          .fontColor(Theme.text)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .padding({ top: 13, bottom: 13 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(Theme.cardRadius)
          .onClick((): void => {
            this.showSheet = false;
          })
        Text(this.busy ? '保存中…' : '保存')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.urlSavable() ? '#0b0d12' : Theme.textFaint)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .padding({ top: 13, bottom: 13 })
          .backgroundColor(this.urlSavable() ? Theme.accent : Theme.glassFill)
          .borderRadius(Theme.cardRadius)
          .onClick((): void => {
            if (this.urlSavable()) {
              this.saveUrl();
            }
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 24 })
    .backgroundColor(Theme.bg)
  }

  /** 地址能不能存：值变了且合法 */
  private urlSavable(): boolean {
    const config: AppConfigView | null = this.config;
    if (config === null || this.busy) {
      return false;
    }
    return this.draftUrl.trim() !== config.external_url && this.validUrl(this.draftUrl);
  }

  /** 对外端口编辑（同 iOS `ExternalAccessEditor` 的 port 形态：继续 → 确认 → 重启） */
  @Builder
  PortSheet() {
    Column({ space: 14 }) {
      Text('对外端口')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .padding({ top: 16 })
      TextInput({ text: this.draftPort, placeholder: '端口' })
        .width('100%')
        .height(42)
        .fontSize(15)
        .fontColor(Theme.text)
        .backgroundColor(Theme.surfaceRaised)
        .borderRadius(10)
        .padding({ left: 12, right: 12 })
        .type(InputType.Number)
        .onChange((value: string): void => {
          this.draftPort = value;
        })
      Row() {
        Text('当前端口').fontSize(13).fontColor(Theme.textMuted).layoutWeight(1)
        Text(`${(this.config as AppConfigView).web_port}`)
          .fontSize(13).fontColor(Theme.text)
      }
      .width('100%')
      Row() {
        Text('来源').fontSize(13).fontColor(Theme.textMuted).layoutWeight(1)
        Text(this.portSourceLabel((this.config as AppConfigView).web_port_source))
          .fontSize(13).fontColor(Theme.text)
      }
      .width('100%')
      if ((this.config as AppConfigView).web_port_source === 'setting') {
        Text(`恢复默认端口（${(this.config as AppConfigView).web_port_default}）`)
          .fontSize(13)
          .fontColor(Theme.accentStrong)
          .width('100%')
          .onClick((): void => {
            this.askPortConfirm((this.config as AppConfigView).web_port_default, 0);
          })
      }
      Text('有效范围 1–65535。修改后服务器将全量重启；如果使用 Docker bridge，通常只需调整宿主侧端口映射。')
        .fontSize(11)
        .fontColor(Theme.textFaint)
        .width('100%')
      if (this.validPort(this.draftPort) < 0 && this.draftPort.trim().length > 0) {
        Text('请输入 1–65535 的整数。').fontSize(12).fontColor(Theme.warning).width('100%')
      }
      if (this.editorError.length > 0) {
        Text(this.editorError).fontSize(12).fontColor(Theme.danger).width('100%')
      }
      Row({ space: 10 }) {
        Text('取消')
          .fontSize(15)
          .fontColor(Theme.text)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .padding({ top: 13, bottom: 13 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(Theme.cardRadius)
          .onClick((): void => {
            this.showSheet = false;
          })
        Text(this.busy ? '重启中…' : '继续')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.portSavable() ? Theme.danger : Theme.textFaint)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .padding({ top: 13, bottom: 13 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(Theme.cardRadius)
          .onClick((): void => {
            if (this.portSavable()) {
              const port: number = this.validPort(this.draftPort);
              this.askPortConfirm(port, port);
            }
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 24 })
    .backgroundColor(Theme.bg)
  }

  /** 端口能不能继续：值变了且是合法端口 */
  private portSavable(): boolean {
    const config: AppConfigView | null = this.config;
    if (config === null || this.busy) {
      return false;
    }
    return this.draftPort.trim() !== `${config.web_port}` && this.validPort(this.draftPort) > 0;
  }
}
