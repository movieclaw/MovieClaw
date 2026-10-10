import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { Formatters } from '../common/Formatters';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { AppFooter } from '../common/AppFooter';
import {
  DeliveryView,
  EventCatalogEntry,
  WebhookConfigPayload,
  WebhookConfigView,
  WebhookEndpointPayload,
  WebhookEndpointView
} from '../api/Models';

/** 外发格式（对应后端 endpoint 的 format） */
class HookFormat {
  readonly value: string;
  readonly label: string;

  constructor(value: string, label: string) {
    this.value = value;
    this.label = label;
  }
}

const FORMATS: HookFormat[] = [
  new HookFormat('json', 'JSON（通用）'),
  new HookFormat('jellyfin', 'Jellyfin 模板')
];

/** `WebhookEndpointPayload` 基本全可选，用类绕开 `arkts-no-untyped-obj-literals` */
class EndpointPayload implements WebhookEndpointPayload {
  id?: string | null;
  name?: string | null;
  url?: string | null;
  format?: string | null;
  enabled?: boolean | null;
  events?: string[] | null;
  template?: string | null;
  headers?: Record<string, string> | null;
  egress_scope?: string | null;
}

/** `WebhookConfigPayload` 同样，用类 */
class ConfigPayload implements WebhookConfigPayload {
  enabled?: boolean | null;
  endpoints?: WebhookEndpointPayload[] | null;
}

/**
 * 设置 → Webhook（对应 iOS `WebhookSettingsView` / Web `webhook-section`，Stripe 式管理页）。
 *
 * 三层结构照抄：
 * - **总开关 + 推送目标列表**：一行一个 endpoint，状态点显示**最近一次投递结果**，
 *   行内给「发送测试 / 记录 / 编辑」与启用开关；
 * - **编辑弹层**（新建与编辑共用）：显示名、URL、外发格式、订阅事件（**按事件目录分组**，
 *   目录随 `webhookShow` 下发——后端新增领域事件时前端零改动）；
 * - **一次性密钥展示条**：新建 / 轮换后后端只在那一次响应里给明文，**必须立刻展示并提示保存**。
 *
 * **保存是全量的**：`PUT /webhook` 一次提交总开关与**全部 endpoint**，任何增删改都把其余 endpoint
 * 原样带上（只丢只读字段），响应即最新视图——与 Web 同一条路，避免两端各自拼出不同配置。
 *
 * **本轮先不做**：Jellyfin 模板与附加请求头的细调、网络出口（egress scope）、
 * 投递记录的全量列表（行内只显示最近一次）。
 */
@ComponentV2
export struct WebhookSection {
  @Local private config: WebhookConfigView | null = null;
  @Local private loading: boolean = true;
  @Local private errorMessage: string = '';
  @Local private busyId: string = '';

  // 编辑弹层
  @Local private sheetKind: string = '';
  @Local private showSheet: boolean = false;
  @Local private formId: string = '';
  @Local private formName: string = '';
  @Local private formUrl: string = '';
  @Local private formFormat: string = 'json';
  @Local private formEnabled: boolean = true;
  @Local private formEvents: string[] = [];
  @Local private formSaving: boolean = false;
  @Local private formError: string = '';

  /** 一次性明文密钥（关掉即丢） */
  @Local private secretValue: string = '';

  /** 最近一次投递记录（点「记录」看） */
  @Local private deliveryTitle: string = '';
  @Local private delivery: DeliveryView | null = null;

  aboutToAppear(): void {
    this.load();
  }

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private async load(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      this.config = await api.webhookShow();
      this.errorMessage = '';
    } catch (error) {
      this.errorMessage = this.messageOf(error);
    } finally {
      this.loading = false;
    }
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '操作失败';
  }

  // MARK: 全量保存

  /**
   * 提交总开关 + 全部 endpoint（同 iOS 的 `payload(_:)`：只丢只读字段，其余原样带上）。
   * 后端是整体覆盖，所以增删改任何一项都要把其余带上，否则会被清掉。
   */
  private async submit(endpoints: WebhookEndpointView[], enabled: boolean): Promise<WebhookConfigView | null> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return null;
    }
    const body: ConfigPayload = new ConfigPayload();
    body.enabled = enabled;
    const list: WebhookEndpointPayload[] = [];
    for (const endpoint of endpoints) {
      const item: EndpointPayload = new EndpointPayload();
      item.id = endpoint.id;
      item.name = endpoint.name;
      item.url = endpoint.url;
      item.format = endpoint.format;
      item.enabled = endpoint.enabled;
      item.events = endpoint.events;
      item.template = endpoint.template;
      item.headers = endpoint.headers;
      item.egress_scope = endpoint.egress_scope;
      list.push(item);
    }
    body.endpoints = list;
    const updated: WebhookConfigView = await api.webhookSet(body);
    this.config = updated;
    return updated;
  }

  // MARK: 动作

  private async toggleMaster(on: boolean): Promise<void> {
    const view: WebhookConfigView | null = this.config;
    if (view === null) {
      return;
    }
    try {
      await this.submit(view.endpoints, on);
      this.toast(on ? '已打开推送' : '已关闭推送');
    } catch (error) {
      this.toast(this.messageOf(error));
      await this.load();
    }
  }

  private async toggleEndpoint(endpoint: WebhookEndpointView, on: boolean): Promise<void> {
    const view: WebhookConfigView | null = this.config;
    if (view === null) {
      return;
    }
    const next: WebhookEndpointView[] = [];
    for (const item of view.endpoints) {
      if (item.id === endpoint.id) {
        const copy: WebhookEndpointView = item;
        copy.enabled = on;
        next.push(copy);
      } else {
        next.push(item);
      }
    }
    this.busyId = endpoint.id;
    try {
      await this.submit(next, view.enabled);
    } catch (error) {
      this.toast(this.messageOf(error));
      await this.load();
    } finally {
      this.busyId = '';
    }
  }

  private async test(endpoint: WebhookEndpointView): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.busyId = endpoint.id;
    try {
      const result: DeliveryView = await api.webhookTest(endpoint.id);
      this.deliveryTitle = `「${endpoint.name}」的测试结果`;
      this.delivery = result;
      this.sheetKind = 'delivery';
    this.showSheet = true;
      await this.load();
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.busyId = '';
    }
  }

  private showLastDelivery(endpoint: WebhookEndpointView): void {
    const last: DeliveryView | null = endpoint.last_delivery ?? null;
    if (last === null) {
      this.toast('这个目标还没有投递记录');
      return;
    }
    this.deliveryTitle = `「${endpoint.name}」最近一次投递`;
    this.delivery = last;
    this.sheetKind = 'delivery';
    this.showSheet = true;
  }

  private confirmRotate(endpoint: WebhookEndpointView): void {
    this.getUIContext().showAlertDialog({
      title: '轮换密钥',
      message: '换一个签名密钥？旧密钥立刻失效，对面还没换过来的话会验签失败。'
        + '新密钥只显示这一次。',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '轮换',
        action: (): void => {
          this.rotateSecret(endpoint);
        }
      }
    });
  }

  /** 方法名不能叫 `rotate`——会和 ArkUI 组件内置的 `rotate` 属性撞名 */
  private async rotateSecret(endpoint: WebhookEndpointView): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.busyId = endpoint.id;
    try {
      const updated: WebhookEndpointView = await api.webhookRotateSecret(endpoint.id);
      const secret: string | null = updated.secret ?? null;
      this.secretValue = secret !== null && secret.length > 0 ? secret : '';
      await this.load();
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.busyId = '';
    }
  }

  private confirmDelete(endpoint: WebhookEndpointView): void {
    const view: WebhookConfigView | null = this.config;
    if (view === null) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '删除目标',
      message: `删除「${endpoint.name}」？之后这些事件不会再推到它。`,
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: Theme.danger,
        action: (): void => {
          this.remove(endpoint, view);
        }
      }
    });
  }

  private async remove(endpoint: WebhookEndpointView, view: WebhookConfigView): Promise<void> {
    const next: WebhookEndpointView[] = [];
    for (const item of view.endpoints) {
      if (item.id !== endpoint.id) {
        next.push(item);
      }
    }
    this.busyId = endpoint.id;
    try {
      await this.submit(next, view.enabled);
      this.toast('已删除');
    } catch (error) {
      this.toast(this.messageOf(error));
      await this.load();
    } finally {
      this.busyId = '';
    }
  }

  // MARK: 表单

  private openCreate(): void {
    this.formId = '';
    this.formName = '';
    this.formUrl = '';
    this.formFormat = 'json';
    this.formEnabled = true;
    this.formEvents = [];
    this.formError = '';
    this.sheetKind = 'form';
    this.showSheet = true;
  }

  private openEdit(endpoint: WebhookEndpointView): void {
    this.formId = endpoint.id;
    this.formName = endpoint.name;
    this.formUrl = endpoint.url;
    this.formFormat = endpoint.format.length > 0 ? endpoint.format : 'json';
    this.formEnabled = endpoint.enabled;
    this.formEvents = endpoint.events.slice();
    this.formError = '';
    this.sheetKind = 'form';
    this.showSheet = true;
  }

  private async saveForm(): Promise<void> {
    const view: WebhookConfigView | null = this.config;
    if (view === null || this.formSaving) {
      return;
    }
    if (this.formName.trim().length === 0) {
      this.formError = '给它起个名字';
      return;
    }
    if (this.formUrl.trim().length === 0) {
      this.formError = '要填接收地址（URL）';
      return;
    }
    if (this.formEvents.length === 0) {
      this.formError = '至少要订阅一个事件';
      return;
    }
    this.formSaving = true;
    this.formError = '';
    try {
      const next: WebhookEndpointView[] = [];
      for (const item of view.endpoints) {
        if (item.id !== this.formId) {
          next.push(item);
        }
      }
      const edited: WebhookEndpointView = {
        id: this.formId,
        name: this.formName.trim(),
        url: this.formUrl.trim(),
        format: this.formFormat,
        enabled: this.formEnabled,
        events: this.formEvents,
        template: '',
        headers: {},
        egress_scope: '',
        secret_masked: '',
        secret: null,
        last_delivery: null
      };
      next.push(edited);
      const updated: WebhookConfigView | null = await this.submit(next, view.enabled);
      if (updated !== null && this.formId.length === 0) {
        // 新建：后端在那一次响应里给明文密钥，必须立刻展示
        for (const item of updated.endpoints) {
          const secret: string | null = item.secret ?? null;
          if (item.name === edited.name && secret !== null && secret.length > 0) {
            this.secretValue = secret;
            break;
          }
        }
      }
      this.showSheet = false;
      this.toast('已保存');
      await this.load();
    } catch (error) {
      this.formError = this.messageOf(error);
    } finally {
      this.formSaving = false;
    }
  }

  // MARK: 派生

  private catalogGroups(): string[] {
    const view: WebhookConfigView | null = this.config;
    if (view === null) {
      return [];
    }
    const out: string[] = [];
    for (const entry of view.catalog) {
      if (out.indexOf(entry.group) < 0) {
        out.push(entry.group);
      }
    }
    return out;
  }

  private eventsOfGroup(group: string): EventCatalogEntry[] {
    const view: WebhookConfigView | null = this.config;
    if (view === null) {
      return [];
    }
    const out: EventCatalogEntry[] = [];
    for (const entry of view.catalog) {
      if (entry.group === group) {
        out.push(entry);
      }
    }
    return out;
  }

  private isSubscribed(event: string): boolean {
    return this.formEvents.indexOf(event) >= 0;
  }

  private toggleEvent(event: string): void {
    const at: number = this.formEvents.indexOf(event);
    if (at >= 0) {
      this.formEvents.splice(at, 1);
    } else {
      this.formEvents.push(event);
    }
  }

  private statusLabel(endpoint: WebhookEndpointView): string {
    const last: DeliveryView | null = endpoint.last_delivery ?? null;
    if (last === null) {
      return '还没投递过';
    }
    return last.ok
      ? `最近投递成功  ${Formatters.relative(last.at)}`
      : `最近投递失败  ${Formatters.relative(last.at)}`;
  }

  private statusColor(endpoint: WebhookEndpointView): string {
    const last: DeliveryView | null = endpoint.last_delivery ?? null;
    if (last === null) {
      return Theme.textFaint;
    }
    return last.ok ? Theme.ok : Theme.danger;
  }

  // MARK: 视图

  build() {
    Column() {
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
          Text('Webhook 配置加载失败').fontSize(15).fontColor(Theme.text)
          Text(this.errorMessage).fontSize(13).fontColor(Theme.textMuted)
          Text('重试')
            .fontSize(14)
            .fontColor(Theme.accentStrong)
            .onClick(() => {
              this.load();
            })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column({ space: 14 }) {
            this.MasterCard(this.config as WebhookConfigView)
            if (this.secretValue.length > 0) {
              this.SecretBar()
            }
            ForEach((this.config as WebhookConfigView).endpoints, (endpoint: WebhookEndpointView) => {
              this.EndpointCard(endpoint)
            }, (endpoint: WebhookEndpointView) => endpoint.id)
            Text('保存是全量的：任何增删改都会把其余目标原样带上，避免两端各自拼出不同配置。')
              .fontSize(11)
              .fontColor(Theme.textFaint)
              .width('100%')
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
    /*
       * **一个组件只能绑一个 `bindSheet`**（后绑的覆盖前面的）。这里原本绑了两个，
       * 所以其中一个弹层一直打不开——合成单槽位 + 内容切换。
       */
      .bindSheet($$this.showSheet, this.SheetContent(), {
      height: SheetSize.LARGE,
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.bg
    })
  }

  @Builder
  MasterCard(view: WebhookConfigView) {
    Column({ space: 10 }) {
      Row({ space: 12 }) {
        Column({ space: 2 }) {
          Text('Webhook')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text)
          Text('向外部服务推送播放、收藏等事件')
            .fontSize(12)
            .fontColor(Theme.textFaint)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: view.enabled })
          .selectedColor(Theme.accent)
          .onChange((isOn: boolean): void => {
            this.toggleMaster(isOn);
          })
      }
      .width('100%')
      Text('添加目标')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor('#0b0d12')
        .textAlign(TextAlign.Center)
        .width('100%')
        .padding({ top: 9, bottom: 9 })
        .backgroundColor(Theme.accent)
        .borderRadius(16)
        .onClick(() => {
          this.openCreate();
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  /** 一次性密钥条：新建 / 轮换后只出现一次（同 iOS） */
  @Builder
  SecretBar() {
    Column({ space: 6 }) {
      Text('签名密钥（只显示这一次，请立刻复制保存）')
        .fontSize(12)
        .fontWeight(600)
        .fontColor(Theme.warn)
        .width('100%')
      Text(this.secretValue)
        .fontSize(13)
        .fontColor(Theme.text)
        .width('100%')
        .padding(10)
        .backgroundColor(Theme.surfaceRaised)
        .borderRadius(8)
      Text('关掉就不再显示了')
        .fontSize(11)
        .fontColor(Theme.textFaint)
      Text('我知道了')
        .fontSize(13)
        .fontColor(Theme.accentStrong)
        .onClick(() => {
          this.secretValue = '';
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .backgroundColor('rgba(251, 191, 36, 0.08)')
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: 'rgba(251, 191, 36, 0.35)' })
  }

  @Builder
  EndpointCard(endpoint: WebhookEndpointView) {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Circle()
          .width(8)
          .height(8)
          .fill(this.statusColor(endpoint))
        Column({ space: 3 }) {
          Text(endpoint.name)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(endpoint.url)
            .fontSize(12)
            .fontColor(Theme.textMuted)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: endpoint.enabled })
          .selectedColor(Theme.accent)
          .onChange((isOn: boolean): void => {
            this.toggleEndpoint(endpoint, isOn);
          })
      }
      .width('100%')

      Text(this.statusLabel(endpoint))
        .fontSize(12)
        .fontColor(this.statusColor(endpoint))
        .width('100%')
      Text(`订阅 ${endpoint.events.length} 个事件  ·  ${endpoint.format}`)
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .width('100%')

      Row({ space: 10 }) {
        Text(this.busyId === endpoint.id ? '…' : '发送测试')
          .fontSize(13)
          .fontColor(Theme.accentStrong)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(14)
          .onClick(() => {
            this.test(endpoint);
          })
        Text('记录')
          .fontSize(13)
          .fontColor(Theme.text)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(14)
          .onClick(() => {
            this.showLastDelivery(endpoint);
          })
        Text('编辑')
          .fontSize(13)
          .fontColor(Theme.text)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(14)
          .onClick(() => {
            this.openEdit(endpoint);
          })
        Blank()
        Text('删除')
          .fontSize(13)
          .fontColor(Theme.danger)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .onClick(() => {
            this.confirmDelete(endpoint);
          })
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  // MARK: 编辑弹层

  /** 唯一的弹层内容：按 sheetKind 切换 */
  @Builder
  SheetContent() {
    if (this.sheetKind === 'form') {
      this.FormSheet()
    } else {
      this.DeliverySheet()
    }
  }

  @Builder
  FormSheet() {
    Column() {
      Row() {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(18)
          .fontColor([Theme.textMuted])
          .width(40)
          .height(40)
          .onClick(() => {
            this.showSheet = false;
          })
        Blank()
        Text(this.formId.length === 0 ? '添加目标' : '编辑目标')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
        Blank()
        Text(this.formSaving ? '保存中…' : '保存')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.formSaving ? Theme.textFaint : Theme.accentStrong)
          .height(40)
          .padding({ left: 8, right: 8 })
          .onClick(() => {
            if (!this.formSaving) {
              this.saveForm();
            }
          })
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 6, bottom: 6 })

      Scroll() {
        Column({ space: 14 }) {
          if (this.formError.length > 0) {
            Text(this.formError).fontSize(13).fontColor(Theme.danger).width('100%')
          }
          Column({ space: 12 }) {
            this.Field('显示名', this.formName, '方便自己认出来', (v: string): void => {
              this.formName = v;
            })
            this.Field('URL', this.formUrl, 'https://…', (v: string): void => {
              this.formUrl = v;
            })
            Column({ space: 6 }) {
              Text('外发格式')
                .fontSize(13)
                .fontColor(Theme.textFaint)
                .width('100%')
              Row({ space: 8 }) {
                ForEach(FORMATS, (format: HookFormat) => {
                  Text(format.label)
                    .fontSize(13)
                    .fontColor(this.formFormat === format.value ? '#0b0d12' : Theme.textMuted)
                    .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                    .backgroundColor(this.formFormat === format.value ? Theme.accent : Theme.glassFill)
                    .borderRadius(15)
                    .onClick(() => {
                      this.formFormat = format.value;
                    })
                }, (format: HookFormat) => format.value)
              }
              .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .padding(14)
          .backgroundColor(Theme.surface)
          .borderRadius(Theme.cardRadius)
          .border({ width: 1, color: Theme.line })

          // 订阅事件：按目录分组（目录随 GET 下发，后端加事件前端零改动）
          Column({ space: 0 }) {
            Text(`订阅事件（已选 ${this.formEvents.length}）`)
              .fontSize(13)
              .fontColor(Theme.textFaint)
              .width('100%')
              .padding({ left: 4, bottom: 6 })
            ForEach(this.catalogGroups(), (group: string, gi: number) => {
              Column() {
                Text(group)
                  .fontSize(12)
                  .fontColor(Theme.textFaint)
                  .width('100%')
                  .padding({ left: 16, top: 10, bottom: 4 })
                ForEach(this.eventsOfGroup(group), (entry: EventCatalogEntry, ei: number) => {
                  Column() {
                    Row({ space: 12 }) {
                      SymbolGlyph(this.isSubscribed(entry.event)
                        ? $r('sys.symbol.checkmark_square_fill') : $r('sys.symbol.square'))
                        .fontSize(19)
                        .fontColor([this.isSubscribed(entry.event) ? Theme.accent : Theme.textFaint])
                      Text(entry.label)
                        .fontSize(14)
                        .fontColor(Theme.text)
                        .layoutWeight(1)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                    .width('100%')
                    .padding({ left: 16, right: 16, top: 9, bottom: 9 })
                    .onClick(() => {
                      this.toggleEvent(entry.event);
                    })
                    if (ei < this.eventsOfGroup(group).length - 1) {
                      Divider().color(Theme.line).margin({ left: 47, right: 16 })
                    }
                  }
                  .width('100%')
                }, (entry: EventCatalogEntry) => entry.event)
              }
              .width('100%')
            }, (group: string) => group)
          }
          .width('100%')
          .backgroundColor(Theme.surface)
          .borderRadius(Theme.cardRadius)
          .border({ width: 1, color: Theme.line })

          if (this.formId.length > 0) {
            Text('轮换密钥')
              .fontSize(14)
              .fontColor(Theme.warn)
              .textAlign(TextAlign.Center)
              .width('100%')
              .padding({ top: 12, bottom: 12 })
              .backgroundColor(Theme.surface)
              .borderRadius(Theme.cardRadius)
              .border({ width: 1, color: Theme.line })
              .onClick(() => {
                const view: WebhookConfigView | null = this.config;
                if (view === null) {
                  return;
                }
                for (const item of view.endpoints) {
                  if (item.id === this.formId) {
                    this.confirmRotate(item);
                    break;
                  }
                }
              })
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 28 })
      }
      .layoutWeight(1)
      .align(Alignment.TopStart)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  @Builder
  Field(label: string, value: string, hint: string, onChange: (v: string) => void) {
    Column({ space: 5 }) {
      Text(label)
        .fontSize(13)
        .fontColor(Theme.textFaint)
        .width('100%')
      TextInput({ text: value, placeholder: hint })
        .width('100%')
        .height(42)
        .fontSize(15)
        .fontColor(Theme.text)
        .backgroundColor(Theme.surfaceRaised)
        .borderRadius(10)
        .padding({ left: 12, right: 12 })
        .onChange((v: string): void => {
          onChange(v);
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 投递记录（行内只显示最近一次；iOS 有全量列表，这里先给最近一次） */
  @Builder
  DeliverySheet() {
    Column({ space: 14 }) {
      Row() {
        Blank()
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(18)
          .fontColor([Theme.textMuted])
          .width(40)
          .height(40)
          .onClick(() => {
            this.showSheet = false;
          })
      }
      .width('100%')

      Column({ space: 8 }) {
        Text(this.deliveryTitle)
          .fontSize(16)
          .fontWeight(600)
          .fontColor(Theme.text)
        if (this.delivery !== null) {
          Text((this.delivery as DeliveryView).ok ? '投递成功' : '投递失败')
            .fontSize(15)
            .fontColor((this.delivery as DeliveryView).ok ? Theme.ok : Theme.danger)
          Text(`${(this.delivery as DeliveryView).event}  ·  `
            + `${(this.delivery as DeliveryView).duration_ms}ms  ·  `
            + `第 ${(this.delivery as DeliveryView).attempts} 次尝试`)
            .fontSize(13)
            .fontColor(Theme.textMuted)
          Text(Formatters.relative((this.delivery as DeliveryView).at))
            .fontSize(12)
            .fontColor(Theme.textFaint)
          if ((this.delivery as DeliveryView).status_code !== null) {
            Text(`HTTP ${(this.delivery as DeliveryView).status_code}`)
              .fontSize(13)
              .fontColor(Theme.text)
          }
          if ((this.delivery as DeliveryView).error.length > 0) {
            Text((this.delivery as DeliveryView).error)
              .fontSize(12)
              .fontColor(Theme.danger)
              .width('100%')
          }
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(16)
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16 })
    .backgroundColor(Theme.bg)
  }
}
