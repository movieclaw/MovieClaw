import { pasteboard } from '@kit.BasicServicesKit';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import {
  AddedView,
  CallbackIssuedView,
  CallbackKeyView,
  DetailConsumerView,
  DetailDeadLetterView,
  PluginDetailView,
  PluginPackageDetailView,
  PluginSettingsPayload,
  PluginSettingsView,
  PluginSourceView,
  PluginSwitchPayload,
  PluginView
} from '../api/Models';
import {
  JsonMap,
  JsonValue,
  jsonArrayValue,
  jsonBoolValue,
  jsonGet,
  jsonObjectValue,
  jsonStringValue
} from '../api/JsonValue';
import { AppModel } from '../common/AppModel';
import { GlassButtonModifier, GlassTone } from '../common/GlassControls';
import { Theme } from '../theme/AppTheme';
import { PluginDisplay } from './PluginsFormat';

/** 插件设置的界面字段（JSON Schema 子集，对应 Web `schema-form.tsx` 认得的类型） */
class PluginFormField {
  name: string = '';
  /** boolean | string | integer | number | array */
  kind: string = '';
  nullable: boolean = false;
  title: string = '';
  hint: string = '';
  options: string[] = [];
  secret: boolean = false;
  multiline: boolean = false;
  secretSet: boolean = false;
  required: boolean = false;
}

/** 编辑中的一项值：文本类用 text，布尔用 flag */
class PluginFormValue {
  readonly name: string;
  text: string;
  flag: boolean;

  constructor(name: string, text: string, flag: boolean) {
    this.name = name;
    this.text = text;
    this.flag = flag;
  }
}

/** 字段类型与可空性（兼容 `type: ["string", "null"]`） */
class PluginSchemaShape {
  static kindOf(field: JsonMap): string {
    const single: string | null = jsonStringValue(jsonGet(field, 'type'));
    if (single !== null) {
      return single;
    }
    const list = jsonArrayValue(jsonGet(field, 'type'));
    if (list === null) {
      return 'string';
    }
    for (const item of list) {
      const name: string | null = jsonStringValue(item);
      if (name !== null && name !== 'null') {
        return name;
      }
    }
    return 'string';
  }

  static nullable(field: JsonMap): boolean {
    const list = jsonArrayValue(jsonGet(field, 'type'));
    if (list === null) {
      return false;
    }
    for (const item of list) {
      if (jsonStringValue(item) === 'null') {
        return true;
      }
    }
    return false;
  }
}

/**
 * 插件详情（对应 Web `plugin-detail.tsx`）：状态、它给系统加了什么、可靠事件与死信、
 * 回调地址、存储，以及插件自己声明的通用设置表单。
 */
@ComponentV2
export struct PluginDetailSheet {
  @Param pluginId: string = '';
  /** 插件装卸 / 停用之后通知外面的列表刷新 */
  @Event onChanged: () => void = (): void => {
  };
  /** 插件已被卸载：请外层关掉详情弹层 */
  @Event onExit: () => void = (): void => {
  };

  @Local private detail: PluginDetailView | null = null;
  @Local private settings: PluginSettingsView | null = null;
  @Local private fields: PluginFormField[] = [];
  @Local private values: PluginFormValue[] = [];
  @Local private schemaTitle: string = '';
  @Local private loading: boolean = true;
  @Local private error: string = '';
  @Local private busy: boolean = false;
  @Local private formError: string = '';

  aboutToAppear(): void {
    this.load();
  }

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '操作失败';
  }

  private async load(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.pluginId.length === 0) {
      this.loading = false;
      return;
    }
    this.loading = true;
    try {
      this.detail = await api.appPluginsShow(this.pluginId);
      this.error = '';
    } catch (error) {
      this.error = this.messageOf(error);
      this.loading = false;
      return;
    }
    try {
      this.settings = await api.appPluginsSettingsShow(this.pluginId);
      this.adoptSettings(this.settings);
    } catch (error) {
      // 没有配置的插件（或旧服务端）没有设置接口：不展示设置表单
      this.settings = null;
    }
    this.loading = false;
  }

  /** 服务端设置 → 表单字段与编辑态值 */
  private adoptSettings(view: PluginSettingsView): void {
    const schema: JsonValue | null = view.schema ?? null;
    const fields: PluginFormField[] = [];
    const values: PluginFormValue[] = [];
    this.schemaTitle = jsonStringValue(jsonGet(schema, 'title')) ?? '';
    const requiredNames: string[] = [];
    const requiredList = jsonArrayValue(jsonGet(schema, 'required'));
    if (requiredList !== null) {
      for (const item of requiredList) {
        const name: string | null = jsonStringValue(item);
        if (name !== null) {
          requiredNames.push(name);
        }
      }
    }
    const properties: JsonMap | null = jsonObjectValue(jsonGet(schema, 'properties'));
    if (properties !== null) {
      const names: string[] = Object.keys(properties);
      for (const name of names) {
        const raw: JsonValue = properties[name];
        const field: JsonMap | null = jsonObjectValue(raw);
        if (field === null) {
          continue;
        }
        const item: PluginFormField = new PluginFormField();
        item.name = name;
        item.kind = PluginSchemaShape.kindOf(field);
        item.nullable = PluginSchemaShape.nullable(field);
        item.title = jsonStringValue(jsonGet(field, 'title')) ?? name;
        item.hint = jsonStringValue(jsonGet(field, 'description')) ?? '';
        item.secret = jsonBoolValue(jsonGet(field, 'writeOnly')) ?? false;
        item.multiline = jsonBoolValue(jsonGet(field, 'x-multiline')) ?? false;
        item.secretSet = view.secrets_set.indexOf(name) >= 0;
        item.required = requiredNames.indexOf(name) >= 0;
        const options = jsonArrayValue(jsonGet(field, 'enum'));
        if (options !== null) {
          const optionList: string[] = [];
          for (const option of options) {
            const text: string | null = jsonStringValue(option);
            if (text !== null) {
              optionList.push(text);
            }
          }
          item.options = optionList;
        }
        fields.push(item);
        values.push(PluginDetailSheet.initialValue(name, item, view.values[name]));
      }
    }
    this.fields = fields;
    this.values = values;
  }

  private static initialValue(name: string, field: PluginFormField, raw: JsonValue | undefined): PluginFormValue {
    if (field.secret) {
      return new PluginFormValue(name, '', false);
    }
    if (field.kind === 'boolean') {
      return new PluginFormValue(name, '', raw === true);
    }
    if (field.kind === 'array') {
      const list = jsonArrayValue(raw ?? null);
      const parts: string[] = [];
      if (list !== null) {
        for (const item of list) {
          parts.push(jsonStringValue(item) ?? '');
        }
      }
      return new PluginFormValue(name, parts.join('\n'), false);
    }
    const text: string | null = jsonStringValue(raw ?? null);
    return new PluginFormValue(name, text ?? '', false);
  }

  /** 编辑态值（找不到时给空值） */
  private draftOf(name: string): PluginFormValue {
    for (const item of this.values) {
      if (item.name === name) {
        return item;
      }
    }
    return new PluginFormValue(name, '', false);
  }

  private setText(name: string, text: string): void {
    const next: PluginFormValue[] = [];
    for (const item of this.values) {
      next.push(item.name === name ? new PluginFormValue(name, text, item.flag) : item);
    }
    this.values = next;
  }

  private setFlag(name: string, flag: boolean): void {
    const next: PluginFormValue[] = [];
    for (const item of this.values) {
      next.push(item.name === name ? new PluginFormValue(name, item.text, flag) : item);
    }
    this.values = next;
  }

  private canManage(): boolean {
    const detail: PluginDetailView | null = this.detail;
    if (detail === null) {
      return false;
    }
    return !this.busy;
  }

  private async toggleEnabled(enabled: boolean): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.detail === null) {
      return;
    }
    this.busy = true;
    try {
      const payload: PluginSwitchPayload = { enabled: enabled };
      await api.appPluginsSwitch(this.detail.plugin.id, payload);
      this.toast(enabled ? '已启用' : '已停用');
      this.onChanged();
      await this.load();
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.busy = false;
    }
  }

  private confirm(title: string, message: string, confirmTitle: string): Promise<boolean> {
    return new Promise<boolean>((resolve: (value: boolean) => void): void => {
      this.getUIContext().showAlertDialog({
        title: title,
        message: message,
        primaryButton: {
          value: confirmTitle,
          fontColor: Theme.danger,
          action: (): void => {
            resolve(true);
          }
        },
        secondaryButton: {
          value: '取消',
          action: (): void => {
            resolve(false);
          }
        },
        cancel: (): void => {
          resolve(false);
        }
      });
    });
  }

  /** 卸载：官方插件能恢复；插件包卸载后数据默认保留 */
  private async uninstall(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const detail: PluginDetailView | null = this.detail;
    if (api === null || detail === null) {
      return;
    }
    const official: boolean = detail.kind === 'official';
    const ok: boolean = await this.confirm(
      official ? '卸载官方插件？' : '卸载插件包？',
      official
        ? '卸载后随时可以在插件页恢复，插件数据默认保留。'
        : '卸载后插件立即停止运行，插件数据默认保留。',
      '卸载');
    if (!ok) {
      return;
    }
    this.busy = true;
    try {
      if (official) {
        await api.appPluginsBundledUninstall(detail.plugin.id, false);
      } else {
        await api.appPluginsPackagesUninstall(detail.plugin.id, false);
      }
      this.toast('已卸载');
      this.onChanged();
      this.onExit();
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.busy = false;
    }
  }

  private async rollback(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const detail: PluginDetailView | null = this.detail;
    if (api === null || detail === null) {
      return;
    }
    const previous: string = detail.package?.previous_version ?? '上一版';
    const ok: boolean = await this.confirm('回滚到上一版？', `将回到 ${previous}，当前版本会被它替换。`, '回滚');
    if (!ok) {
      return;
    }
    this.busy = true;
    try {
      const result = await api.appPluginsPackagesRollback(detail.plugin.id);
      this.toast(result.error !== null && result.error !== undefined && result.error.length > 0
        ? result.error : '已回滚');
      this.onChanged();
      await this.load();
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.busy = false;
    }
  }

  private async replayDeadLetter(item: DetailDeadLetterView): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      await api.appPluginsDeadLettersReplay(item.id);
      this.toast('已重新投递');
      await this.load();
    } catch (error) {
      this.toast(this.messageOf(error));
    }
  }

  private async dismissDeadLetter(item: DetailDeadLetterView): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      await api.appPluginsDeadLettersDismiss(item.id);
      this.toast('已忽略');
      await this.load();
    } catch (error) {
      this.toast(this.messageOf(error));
    }
  }

  private async rotateCallback(item: CallbackKeyView): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      const issued: CallbackIssuedView = await api.appPluginsCallbacksRotate(item.id);
      this.showIssued(issued);
      await this.load();
    } catch (error) {
      this.toast(this.messageOf(error));
    }
  }

  private async revokeCallback(item: CallbackKeyView): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    const ok: boolean = await this.confirm('作废这个回调地址？', '外部平台再调进来会一律 404，需要重新换发并填到平台后台。', '作废');
    if (!ok) {
      return;
    }
    try {
      await api.appPluginsCallbacksRevoke(item.id);
      this.toast('已作废');
      await this.load();
    } catch (error) {
      this.toast(this.messageOf(error));
    }
  }

  /** 换发后的完整地址只在这一次出现：弹层里给复制按钮 */
  private showIssued(issued: CallbackIssuedView): void {
    this.getUIContext().showAlertDialog({
      title: '新的回调地址',
      message: `${issued.url}\n\n只在这里出现一次，请立即填到平台后台。`,
      primaryButton: {
        value: '复制',
        action: (): void => {
          const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, issued.url);
          pasteboard.getSystemPasteboard().setDataSync(data);
          this.toast('已复制');
        }
      },
      secondaryButton: {
        value: '关闭',
        action: (): void => {
        }
      }
    });
  }

  private copy(text: string): void {
    const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setDataSync(data);
    this.toast('已复制');
  }

  private async saveSettings(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    const values: Record<string, JsonValue> = {};
    for (const field of this.fields) {
      const entry: PluginFormValue = this.draftOf(field.name);
      if (field.secret) {
        // 敏感字段留空表示不改
        if (entry.text.length > 0) {
          values[field.name] = entry.text;
        }
        continue;
      }
      if (field.kind === 'boolean') {
        values[field.name] = entry.flag;
        continue;
      }
      if (field.kind === 'array') {
        const parts: string[] = [];
        const pieces: string[] = entry.text.split(/[\n,，]/);
        for (const piece of pieces) {
          const trimmed: string = piece.trim();
          if (trimmed.length > 0) {
            parts.push(trimmed);
          }
        }
        values[field.name] = parts;
        continue;
      }
      if ((field.kind === 'integer' || field.kind === 'number') && entry.text.trim().length > 0) {
        const parsed: number = Number(entry.text);
        values[field.name] = Number.isNaN(parsed) ? entry.text : parsed;
        continue;
      }
      if (field.nullable && entry.text.length === 0) {
        values[field.name] = null;
        continue;
      }
      values[field.name] = entry.text;
    }
    this.busy = true;
    this.formError = '';
    try {
      const payload: PluginSettingsPayload = { values: values };
      const next: PluginSettingsView = await api.appPluginsSettingsUpdate(this.pluginId, payload);
      this.settings = next;
      this.adoptSettings(next);
      this.toast('设置已保存');
      this.onChanged();
    } catch (error) {
      this.formError = this.messageOf(error);
    } finally {
      this.busy = false;
    }
  }

  private plugin(): PluginView | null {
    return this.detail === null ? null : this.detail.plugin;
  }

  private stateLabel(): string {
    const plugin: PluginView | null = this.plugin();
    return plugin === null ? '' : PluginDisplay.stateLabel(PluginDisplay.displayState(plugin));
  }

  private stateTone(): string {
    const plugin: PluginView | null = this.plugin();
    return plugin === null ? Theme.textMuted : PluginDisplay.stateTone(PluginDisplay.displayState(plugin));
  }

  private headerTitle(): string {
    const plugin: PluginView | null = this.plugin();
    return plugin === null ? '插件' : plugin.title;
  }

  private headerSubtitle(): string {
    const detail: PluginDetailView | null = this.detail;
    if (detail === null) {
      return '';
    }
    const parts: string[] = [PluginDisplay.kindLabel(detail.kind)];
    const version: string = detail.version ?? '';
    if (version.length > 0) {
      parts.push(`v${version}`);
    }
    parts.push(PluginDisplay.runtimeLabel(detail.plugin.runtime));
    return parts.join(' · ');
  }

  build() {
    Column() {
      if (this.loading) {
        Column({ space: 10 }) {
          LoadingProgress().width(24).height(24).color(Theme.textMuted)
          Text('正在加载插件…').fontSize(13).fontColor(Theme.textFaint)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.error.length > 0) {
        Column({ space: 10 }) {
          Text('无法加载插件').fontSize(16).fontColor(Theme.text)
          Text(this.error).fontSize(13).fontColor(Theme.textMuted).textAlign(TextAlign.Center)
          Button() {
            Text('重试').fontSize(14).fontColor(Theme.text)
          }
          .attributeModifier(new GlassButtonModifier(GlassTone.Secondary))
          .padding({ left: 18, right: 18, top: 8, bottom: 8 })
          .borderRadius(14)
          .onClick((): void => {
            this.load();
          })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .padding(24)
      } else {
        Scroll() {
          Column({ space: 14 }) {
            this.Header()
            this.Actions()
            this.InfoCard()
            if ((this.detail as PluginDetailView).adds.length > 0) {
              this.AddsCard()
            }
            if ((this.detail as PluginDetailView).consumers.length > 0) {
              this.ConsumersCard()
            }
            if ((this.detail as PluginDetailView).dead_letters.length > 0) {
              this.DeadLettersCard()
            }
            if ((this.detail as PluginDetailView).callbacks.length > 0) {
              this.CallbacksCard()
            }
            this.SettingsCard()
            Blank().height(16)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 24 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.TopStart)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  @Builder
  Header() {
    Column({ space: 6 }) {
      Row({ space: 10 }) {
        Text(this.headerTitle())
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.text)
          .layoutWeight(1)
        Text(this.stateLabel())
          .fontSize(11)
          .fontColor(this.stateTone())
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor('rgba(255, 255, 255, 0.06)')
          .borderRadius(10)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      Text(this.headerSubtitle())
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .width('100%')
      if ((this.detail as PluginDetailView).description.length > 0) {
        Text((this.detail as PluginDetailView).description)
          .fontSize(13)
          .fontColor(Theme.textMuted)
          .width('100%')
          .margin({ top: 4 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  Actions() {
    Column({ space: 0 }) {
      if ((this.detail as PluginDetailView).plugin.switchable) {
        Row({ space: 12 }) {
          Column({ space: 2 }) {
            Text('启用')
              .fontSize(15)
              .fontColor(Theme.text)
            Text((this.detail as PluginDetailView).plugin.locked_by !== null
              && (this.detail as PluginDetailView).plugin.locked_by !== undefined
              ? `被 ${(this.detail as PluginDetailView).plugin.locked_by} 锁住，要在服务端配置里改回来`
              : '停用会取消它的后台任务；重启后保持')
              .fontSize(12)
              .fontColor(Theme.textFaint)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Toggle({ type: ToggleType.Switch, isOn: (this.detail as PluginDetailView).plugin.state !== 'disabled' })
            .enabled(this.canManage()
              && ((this.detail as PluginDetailView).plugin.locked_by === null
                || (this.detail as PluginDetailView).plugin.locked_by === undefined))
            .onChange((on: boolean): void => {
              this.toggleEnabled(on);
            })
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 11, bottom: 11 })
      }
      if ((this.detail as PluginDetailView).kind === 'package'
        && (this.detail as PluginDetailView).package !== null
        && (this.detail as PluginDetailView).package !== undefined
        && ((this.detail as PluginDetailView).package as PluginPackageDetailView).previous_version !== null
        && ((this.detail as PluginDetailView).package as PluginPackageDetailView).previous_version !== undefined) {
        this.ActionRow('回滚到上一版',
          `当前 v${(this.detail as PluginDetailView).version ?? ''}，可回到 `
            + `v${((this.detail as PluginDetailView).package as PluginPackageDetailView).previous_version ?? ''}`,
          (): void => {
            this.rollback();
          })
      }
      if ((this.detail as PluginDetailView).plugin.removable || (this.detail as PluginDetailView).kind === 'package') {
        this.ActionRow('卸载插件',
          (this.detail as PluginDetailView).kind === 'official'
            ? '卸载后随时可以恢复；插件数据默认保留'
            : '卸载后立即停止运行；插件数据默认保留',
          (): void => {
            this.uninstall();
          })
      }
    }
    .width('100%')
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  @Builder
  ActionRow(title: string, hint: string, onTap: () => void) {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        Text(title)
          .fontSize(15)
          .fontColor(Theme.text)
          .width('100%')
          .textAlign(TextAlign.Start)
        Text(hint)
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(13)
        .fontColor([Theme.textFaint])
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 14, right: 14, top: 11, bottom: 11 })
    .onClick((): void => {
      if (this.canManage()) {
        onTap();
      }
    })
  }

  @Builder
  InfoCard() {
    Column({ space: 8 }) {
      this.InfoRow('来源', (this.detail as PluginDetailView).source !== null
        && (this.detail as PluginDetailView).source !== undefined
        ? ((this.detail as PluginDetailView).source as PluginSourceView).path
        : PluginDisplay.kindLabel((this.detail as PluginDetailView).kind))
      this.InfoRow('存储', PluginDisplay.storageLine((this.detail as PluginDetailView).data_rows,
        (this.detail as PluginDetailView).disk_bytes))
      if ((this.detail as PluginDetailView).data_path !== null
        && (this.detail as PluginDetailView).data_path !== undefined
        && ((this.detail as PluginDetailView).data_path as string).length > 0) {
        this.InfoRow('数据目录', (this.detail as PluginDetailView).data_path as string)
      }
      if ((this.detail as PluginDetailView).plugin.stats.events > 0) {
        this.InfoRow('事件', `${(this.detail as PluginDetailView).plugin.stats.events} 次 · `
          + `失败 ${(this.detail as PluginDetailView).plugin.stats.failures} · `
          + `超时 ${(this.detail as PluginDetailView).plugin.stats.timeouts}`)
      }
      if ((this.detail as PluginDetailView).children.length > 0) {
        this.InfoRow('子条目', (this.detail as PluginDetailView).children.join('、'))
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  @Builder
  InfoRow(label: string, text: string) {
    Row({ space: 12 }) {
      Text(label)
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .width(64)
      Text(text)
        .fontSize(12)
        .fontColor(Theme.textMuted)
        .layoutWeight(1)
        .textAlign(TextAlign.End)
        .copyOption(CopyOptions.LocalDevice)
    }
    .width('100%')
  }

  @Builder
  CardTitle(title: string) {
    Text(title)
      .fontSize(13)
      .fontColor(Theme.textMuted)
      .width('100%')
      .textAlign(TextAlign.Start)
  }

  @Builder
  AddsCard() {
    Column({ space: 8 }) {
      this.CardTitle('它给系统加了什么')
      ForEach((this.detail as PluginDetailView).adds, (item: AddedView) => {
        Column({ space: 2 }) {
          Text(item.title)
            .fontSize(13)
            .fontColor(Theme.text)
            .width('100%')
          Text(item.detail)
            .fontSize(12)
            .fontColor(Theme.textFaint)
            .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }, (item: AddedView, index: number) => `add-${index}-${item.kind}`)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  @Builder
  ConsumersCard() {
    Column({ space: 8 }) {
      this.CardTitle('订阅的可靠事件')
      ForEach((this.detail as PluginDetailView).consumers, (item: DetailConsumerView) => {
        Column({ space: 3 }) {
          Row({ space: 6 }) {
            Text(item.title.length > 0 ? item.title : item.consumer_id)
              .fontSize(13)
              .fontColor(Theme.text)
              .layoutWeight(1)
            Text(item.active ? '运行中' : '未运行')
              .fontSize(11)
              .fontColor(item.active ? Theme.ok : Theme.textMuted)
          }
          .width('100%')
          Text(`${item.events.join('、')} · 积压 ${item.backlog} 条`
            + (item.attempts > 0 ? ` · 当前事件失败 ${item.attempts} 次` : ''))
            .fontSize(12)
            .fontColor(Theme.textFaint)
            .width('100%')
          if (item.last_error !== null && item.last_error !== undefined && item.last_error.length > 0) {
            Text(item.last_error)
              .fontSize(12)
              .fontColor(Theme.danger)
              .width('100%')
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ top: 4, bottom: 4 })
      }, (item: DetailConsumerView) => item.consumer_id)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  @Builder
  DeadLettersCard() {
    Column({ space: 8 }) {
      this.CardTitle(`搁置的事件（${(this.detail as PluginDetailView).dead_letters.length}）`)
      ForEach((this.detail as PluginDetailView).dead_letters, (item: DetailDeadLetterView) => {
        Column({ space: 4 }) {
          Text(item.title.length > 0 ? item.title : item.event)
            .fontSize(13)
            .fontColor(Theme.text)
            .width('100%')
          Text(`失败 ${item.attempts} 次 · ${item.error}`)
            .fontSize(12)
            .fontColor(Theme.danger)
            .width('100%')
          Row({ space: 8 }) {
            Button() {
              Text('重放').fontSize(12).fontColor(Theme.text)
            }
            .attributeModifier(new GlassButtonModifier(GlassTone.Secondary))
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(12)
            .onClick((): void => {
              this.replayDeadLetter(item);
            })
            Button() {
              Text('忽略').fontSize(12).fontColor(Theme.textMuted)
            }
            .attributeModifier(new GlassButtonModifier(GlassTone.Secondary))
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(12)
            .onClick((): void => {
              this.dismissDeadLetter(item);
            })
          }
          .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ top: 4, bottom: 4 })
      }, (item: DetailDeadLetterView) => `letter-${item.id}`)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  @Builder
  CallbacksCard() {
    Column({ space: 8 }) {
      this.CardTitle('回调地址（外部平台免登录调进来）')
      ForEach((this.detail as PluginDetailView).callbacks, (item: CallbackKeyView) => {
        Column({ space: 4 }) {
          Text(item.endpoint)
            .fontSize(13)
            .fontColor(Theme.text)
            .width('100%')
          Text(item.url)
            .fontSize(11)
            .fontFamily('monospace')
            .fontColor(Theme.textFaint)
            .width('100%')
            .copyOption(CopyOptions.LocalDevice)
          Text(`调用 ${item.calls} 次 · 验证失败 ${item.failures} 次`
            + (item.last_status !== null && item.last_status !== undefined ? ` · 最近 ${item.last_status}` : ''))
            .fontSize(12)
            .fontColor(Theme.textFaint)
            .width('100%')
          Row({ space: 8 }) {
            Button() {
              Text('复制').fontSize(12).fontColor(Theme.text)
            }
            .attributeModifier(new GlassButtonModifier(GlassTone.Secondary))
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(12)
            .onClick((): void => {
              this.copy(item.url);
            })
            Button() {
              Text('换发').fontSize(12).fontColor(Theme.text)
            }
            .attributeModifier(new GlassButtonModifier(GlassTone.Secondary))
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(12)
            .onClick((): void => {
              this.rotateCallback(item);
            })
            Button() {
              Text('作废').fontSize(12).fontColor(Theme.danger)
            }
            .attributeModifier(new GlassButtonModifier(GlassTone.Secondary))
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(12)
            .onClick((): void => {
              this.revokeCallback(item);
            })
          }
          .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ top: 4, bottom: 4 })
      }, (item: CallbackKeyView) => `callback-${item.id}`)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  @Builder
  SettingsCard() {
    if (this.settings !== null) {
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          Text(this.schemaTitle.length > 0 && this.schemaTitle !== 'Config' ? this.schemaTitle : '插件设置')
            .fontSize(13)
            .fontColor(Theme.textMuted)
            .layoutWeight(1)
          if ((this.settings as PluginSettingsView).editable && this.fields.length > 0) {
            Button() {
              Text(this.busy ? '保存中…' : '保存')
                .fontSize(13)
                .fontColor(Theme.bg)
            }
            .attributeModifier(new GlassButtonModifier(GlassTone.Primary))
            .padding({ left: 14, right: 14, top: 7, bottom: 7 })
            .borderRadius(13)
            .enabled(!this.busy)
            .onClick((): void => {
              this.saveSettings();
            })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        if (!(this.settings as PluginSettingsView).editable) {
          Text(`设置只能去服务端配置里改${(this.settings as PluginSettingsView).reason !== null
            && (this.settings as PluginSettingsView).reason !== undefined
            ? `：${(this.settings as PluginSettingsView).reason}` : ''}`)
            .fontSize(12)
            .fontColor(Theme.textFaint)
            .width('100%')
        } else if (this.fields.length === 0) {
          Text('这个插件没有可调设置').fontSize(12).fontColor(Theme.textFaint).width('100%')
        } else {
          Text('保存后插件会按新设置重启')
            .fontSize(12)
            .fontColor(Theme.textFaint)
            .width('100%')
          ForEach(this.fields, (field: PluginFormField) => {
            this.FieldControl(field)
          }, (field: PluginFormField) => `field-${field.name}`)
          if (this.formError.length > 0) {
            Text(this.formError)
              .fontSize(12)
              .fontColor(Theme.danger)
              .width('100%')
          }
        }
      }
      .width('100%')
      .padding(14)
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })
    }
  }

  @Builder
  FieldControl(field: PluginFormField) {
    Column({ space: 5 }) {
      if (field.kind === 'boolean') {
        Row({ space: 10 }) {
          Column({ space: 2 }) {
            Text(field.required ? `${field.title} *` : field.title)
              .fontSize(14)
              .fontColor(Theme.text)
              .width('100%')
            if (field.hint.length > 0) {
              Text(field.hint)
                .fontSize(12)
                .fontColor(Theme.textFaint)
                .width('100%')
            }
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Toggle({ type: ToggleType.Switch, isOn: this.draftOf(field.name).flag })
            .enabled(!this.busy)
            .onChange((on: boolean): void => {
              this.setFlag(field.name, on);
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      } else {
        Text(field.required ? `${field.title} *` : field.title)
          .fontSize(13)
          .fontColor(Theme.textMuted)
          .width('100%')
        if (field.hint.length > 0) {
          Text(field.hint)
            .fontSize(12)
            .fontColor(Theme.textFaint)
            .width('100%')
        }
        if (field.options.length > 0) {
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(field.options, (option: string) => {
              Text(option)
                .fontSize(12)
                .fontColor(this.draftOf(field.name).text === option ? Theme.bg : Theme.textMuted)
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .backgroundColor(this.draftOf(field.name).text === option ? Theme.accentStrong : 'rgba(255,255,255,0.06)')
                .borderRadius(10)
                .margin({ right: 6, bottom: 6 })
                .onClick((): void => {
                  this.setText(field.name, option);
                })
            }, (option: string) => `opt-${field.name}-${option}`)
          }
          .width('100%')
        } else if (field.kind === 'array' || field.multiline) {
          TextArea({
            text: this.draftOf(field.name).text,
            placeholder: field.kind === 'array' ? '一行一项' : ''
          })
            .width('100%')
            .fontSize(14)
            .fontColor(Theme.text)
            .backgroundColor(Theme.surfaceRaised)
            .borderRadius(10)
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .constraintSize({ minHeight: field.kind === 'array' ? 70 : 90 })
            .enabled(!this.busy)
            .onChange((text: string): void => {
              this.setText(field.name, text);
            })
        } else {
          TextInput({
            text: this.draftOf(field.name).text,
            placeholder: field.secret ? (field.secretSet ? '已设置，留空不改' : '尚未设置') : ''
          })
            .type(field.secret ? InputType.Password : InputType.Normal)
            .width('100%')
            .height(42)
            .fontSize(14)
            .fontColor(Theme.text)
            .backgroundColor(Theme.surfaceRaised)
            .borderRadius(10)
            .padding({ left: 12, right: 12 })
            .enabled(!this.busy)
            .onChange((text: string): void => {
              this.setText(field.name, text);
            })
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
