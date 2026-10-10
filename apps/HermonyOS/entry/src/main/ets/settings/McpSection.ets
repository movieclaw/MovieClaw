import { Theme } from '../theme/AppTheme';
import { SettingsSegmentChip } from '../common/SettingsControls';
import { RemoteImage } from '../common/RemoteImage';
import { AppModel } from '../common/AppModel';
import { Formatters } from '../common/Formatters';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { AppFooter } from '../common/AppFooter';
import {
  EndpointCreateRequest,
  EndpointCreatedView,
  EndpointUpdateRequest,
  EndpointView,
  PreviewView,
  SelfCheckView,
  ServiceView,
  StatusView,
  ToggleRequest,
  ToolPreview
} from '../api/Models';

/** `EndpointUpdateRequest` 同样几乎全可选，用类填 */
class UpdateBody implements EndpointUpdateRequest {
  name: string = '';
  description: string | null = null;
  services: string[] = [];
  expand_tools: boolean = false;
  enabled: boolean = true;
}

/** `EndpointCreateRequest` 基本全可选，用类绕开 `arkts-no-untyped-obj-literals` */
class CreateBody implements EndpointCreateRequest {
  name: string = '';
  /** 路径片段；留空让后端按名字生成 */
  slug: string = '';
  services: string[] = [];
  description?: string | null;
  expand_tools?: boolean | null;
  timeout_seconds?: number | null;
}


/** `ToggleRequest` 只有 enabled 必填，但同样用类保持一致 */
class ToggleBody implements ToggleRequest {
  enabled: boolean = false;
}

/**
 * 设置 → MCP 服务（对应 iOS `MCPSettingsView` / Web `mcp-section`，设计见 docs/design/mcp-server.md）。
 *
 * Web 是 4xl 宽的开发者控制台，列表 → 详情（三栏）→ 新建都在同一块内容区原地切换；
 * **iOS 改成系统层级**：列表一屏、详情 push、新建弹层（成功后原地换成**令牌专屏**）。
 *
 * 本轮做**列表 + 新建 + 行内操作**：
 * - 列表：总开关（地址前缀）、「已配置 N 个端点」+ 新建、端点行
 *   （状态点 / 名称 / 路径 / 服务标签 / 工具数 · 形态 · 超时）；
 * - 行内：**自检**（`mcpEndpointsCheck`，返回协议版本 / 工具数 / 探针结果 / 警告）、
 *   **轮换令牌**、启用开关、删除；
 * - 新建弹层：名称、说明、服务多选、展开工具、超时；成功后**令牌只出现一次**。
 *
 * **没做**：详情页三栏（概览 / 工具 / 设置，即 iOS 的 `SettingsBMCPEndpointDetail`）、
 * 令牌专屏后的「自动推入新端点详情」、用量统计（`StatusView.usage`）。
 */
/** 服务标签组（对应 iOS `SettingsBMCPServiceChips`）：最多 maxCount 个，多的收成「+N」 */
@ComponentV2
struct McpServiceChips {
  @Param services: string[] = [];
  @Param maxCount: number = 3;

  build() {
    if (this.services.length === 0) {
      Text('未选服务')
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .width('100%')
        .textAlign(TextAlign.Start)
    } else {
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.services.slice(0, this.maxCount), (service: string) => {
          Text(service)
            .fontSize(11)
            .fontFamily('monospace')
            .fontColor(Theme.textMuted)
            .padding({ left: 6, right: 6, top: 1, bottom: 1 })
            .backgroundColor('rgba(255, 255, 255, 0.04)')
            .borderRadius(6)
            .border({ width: 1, color: 'rgba(255, 255, 255, 0.1)' })
            .margin({ right: 4, bottom: 4 })
        }, (service: string) => service)
        if (this.services.length > this.maxCount) {
          Text(`+${this.services.length - this.maxCount}`)
            .fontSize(11)
            .fontFamily('monospace')
            .fontColor(Theme.textFaint)
            .margin({ bottom: 4 })
        }
      }
      .width('100%')
    }
  }
}

/** MCP 展示口径（对应 iOS `SettingsBMCPFormat`） */
class McpFormat {
  /** 最近调用：分钟 / 小时 / 天三档，1 分钟内算「刚刚活跃」 */
  static lastUsed(raw: string | null): string {
    if (raw === null || raw.length === 0) {
      return '从未调用';
    }
    const at: number | null = Formatters.date(raw);
    if (at === null) {
      return '未知';
    }
    const minutes: number = Math.floor((Date.now() - at) / 60000);
    if (minutes < 1) {
      return '刚刚活跃';
    }
    if (minutes < 60) {
      return `${minutes} 分钟前`;
    }
    const hours: number = Math.floor(minutes / 60);
    if (hours < 24) {
      return `${hours} 小时前`;
    }
    return `${Math.floor(hours / 24)} 天前`;
  }
}

@ComponentV2
export struct McpSection {
  @Local private status: StatusView | null = null;
  @Local private loading: boolean = true;
  @Local private errorMessage: string = '';
  @Local private busyId: string = '';

  // 自检结果
  @Local private check: SelfCheckView | null = null;
  @Local private checkTitle: string = '';

  // 新建弹层
  @Local private sheetKind: string = '';
  @Local private showSheet: boolean = false;
  /** 正在编辑的端点 id（空 = 新建） */
  @Local private formId: string = '';
  @Local private formName: string = '';
  @Local private formDesc: string = '';
  @Local private formServices: string[] = [];
  @Local private formExpand: boolean = false;
  @Local private formEnabled: boolean = true;
  @Local private formSaving: boolean = false;
  @Local private formError: string = '';

  /** 一次性令牌（关掉即丢） */
  /** 下拉刷新（同 iOS `.refreshable`） */
  @Local private refreshing: boolean = false;
  /** 端点详情弹层（概览 / 工具 / 设置）——iOS 那边是 push 出来的详情页，这里用同内容的弹层承载 */
  @Local private showDetail: boolean = false;
  @Local private detailId: string = '';
  @Local private detailTab: string = 'overview';
  @Local private preview: PreviewView | null = null;
  @Local private createdToken: string = '';
  @Local private createdName: string = '';

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
      this.status = await api.mcpStatus();
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

  // MARK: 动作

  private async toggleMaster(on: boolean): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const view: StatusView | null = this.status;
    if (api === null || view === null) {
      return;
    }
    view.enabled = on;
    try {
      const body: ToggleBody = new ToggleBody();
      body.enabled = on;
      this.status = await api.mcpToggle(body);
      this.toast(on ? '已打开 MCP 服务' : '已关闭 MCP 服务');
    } catch (error) {
      this.toast(this.messageOf(error));
      await this.load();
    }
  }

  private async toggleEndpoint(endpoint: EndpointView, on: boolean): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.busyId = endpoint.id;
    try {
      const body: UpdateBody = new UpdateBody();
      body.enabled = on;
      await api.mcpEndpointsUpdate(endpoint.id, body);
      await this.load();
    } catch (error) {
      this.toast(this.messageOf(error));
      await this.load();
    } finally {
      this.busyId = '';
    }
  }

  private async selfCheck(endpoint: EndpointView): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.busyId = endpoint.id;
    try {
      const result: SelfCheckView = await api.mcpEndpointsCheck(endpoint.id);
      this.check = result;
      this.checkTitle = `「${endpoint.name}」自检`;
      this.sheetKind = 'check';
    this.showSheet = true;
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.busyId = '';
    }
  }

  private confirmRotate(endpoint: EndpointView): void {
    this.getUIContext().showAlertDialog({
      title: '轮换令牌',
      message: `换一个访问令牌？已经配了这个端点的 AI 客户端要改成新的才能连上。`
        + '新令牌只显示这一次。',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '轮换',
        action: (): void => {
          this.rotateToken(endpoint);
        }
      }
    });
  }

  /** 方法名不能叫 `rotate`——和 ArkUI 组件内置的 `rotate` 属性撞名（Webhook 那轮踩过一次） */
  private async rotateToken(endpoint: EndpointView): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.busyId = endpoint.id;
    try {
      const created: EndpointCreatedView = await api.mcpEndpointsRotateToken(endpoint.id);
      this.createdToken = created.token;
      this.createdName = created.endpoint.name;
      await this.load();
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.busyId = '';
    }
  }

  private confirmDelete(endpoint: EndpointView): void {
    this.getUIContext().showAlertDialog({
      title: '删除端点',
      message: `删除「${endpoint.name}」？用它的 AI 客户端会连不上，要重新配。`,
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: Theme.danger,
        action: (): void => {
          this.remove(endpoint);
        }
      }
    });
  }

  private async remove(endpoint: EndpointView): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.busyId = endpoint.id;
    try {
      await api.mcpEndpointsDelete(endpoint.id);
      this.toast('已删除');
      await this.load();
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.busyId = '';
    }
  }

  // MARK: 新建

  private openCreate(): void {
    this.formId = '';
    this.formName = '';
    this.formDesc = '';
    this.formServices = [];
    this.formExpand = false;
    this.formEnabled = true;
    this.formError = '';
    this.sheetKind = 'form';
    this.showSheet = true;
  }

  private toggleService(id: string): void {
    const at: number = this.formServices.indexOf(id);
    if (at >= 0) {
      this.formServices.splice(at, 1);
    } else {
      this.formServices.push(id);
    }
  }

  private async saveForm(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.formSaving) {
      return;
    }
    if (this.formName.trim().length === 0) {
      this.formError = '给它起个名字';
      return;
    }
    if (this.formServices.length === 0) {
      this.formError = '至少要开放一项能力，否则客户端连上也没得用';
      return;
    }
    this.formSaving = true;
    this.formError = '';
    try {
      if (this.formId.length > 0) {
        // 编辑：走 update（令牌不动，改的是名字 / 服务 / 形态 / 启停）
        const update: UpdateBody = new UpdateBody();
        update.name = this.formName.trim();
        update.description = this.formDesc.trim().length > 0 ? this.formDesc.trim() : null;
        update.services = this.formServices;
        update.expand_tools = this.formExpand;
        update.enabled = this.formEnabled;
        await api.mcpEndpointsUpdate(this.formId, update);
        this.showSheet = false;
        this.toast('已保存');
        await this.load();
      } else {
        const body: CreateBody = new CreateBody();
        body.name = this.formName.trim();
        body.slug = '';
        body.description = this.formDesc.trim().length > 0 ? this.formDesc.trim() : null;
        body.services = this.formServices;
        body.expand_tools = this.formExpand;
        const created: EndpointCreatedView = await api.mcpEndpointsCreate(body);
        this.showSheet = false;
        this.createdToken = created.token;
        this.createdName = created.endpoint.name;
        await this.load();
      }
    } catch (error) {
      this.formError = this.messageOf(error);
    } finally {
      this.formSaving = false;
    }
  }

  // MARK: 视图

  build() {
    Column() {
      if (this.loading) {
        Column({ space: 10 }) {
          LoadingProgress().width(24).height(24).color(Theme.textMuted)
          Text('正在加载 MCP 状态…').fontSize(13).fontColor(Theme.textFaint)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.status === null) {
        Column({ space: 10 }) {
          Text('MCP 状态加载失败').fontSize(15).fontColor(Theme.text)
          Text(this.errorMessage).fontSize(13).fontColor(Theme.textMuted)
          Text('重试').fontSize(14).fontColor(Theme.accentStrong).onClick(() => {
            this.load();
          })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Refresh({ refreshing: $$this.refreshing }) {
          Scroll() {
            Column({ space: 12 }) {
              if (this.errorMessage.length > 0) {
                Text(this.errorMessage)
                  .fontSize(13)
                  .fontColor(Theme.danger)
                  .width('100%')
                  .padding(14)
                  .backgroundColor(Theme.surface)
                  .borderRadius(Theme.cardRadius)
                  .border({ width: 1, color: 'rgba(255, 107, 107, 0.3)' })
              }

              this.MasterCard(this.status as StatusView)

              // 头行：「已配置 N 个端点。」+「＋ 新建端点」（同 iOS 的 section header）
              Row() {
                Text((this.status as StatusView).endpoints.length === 0
                  ? '还没有 MCP 端点。' : `已配置 ${(this.status as StatusView).endpoints.length} 个端点。`)
                  .fontSize(13)
                  .fontColor(Theme.textFaint)
                  .layoutWeight(1)
                Text('＋ 新建端点')
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Theme.text)
                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                  .backgroundColor(Theme.glassFill)
                  .borderRadius(12)
                  .onClick((): void => {
                    this.openCreate();
                  })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)

              // 服务关了但还留着端点：说清楚现状（同 iOS 的警告条）
              if (!(this.status as StatusView).enabled
                && (this.status as StatusView).endpoints.length > 0) {
                Text('服务已关闭，下面所有端点一律返回 404。配置与令牌都保留着，打开开关即恢复。')
                  .fontSize(12)
                  .fontColor(Theme.warn)
                  .width('100%')
                  .padding(14)
                  .backgroundColor(Theme.surface)
                  .borderRadius(Theme.cardRadius)
                  .border({ width: 1, color: 'rgba(245, 196, 81, 0.3)' })
              }

              if (this.createdToken.length > 0) {
                this.TokenBar()
              }

              if ((this.status as StatusView).endpoints.length === 0) {
                this.EmptyState()
              } else {
                Column() {
                  ForEach((this.status as StatusView).endpoints,
                    (endpoint: EndpointView, index: number) => {
                      this.EndpointRow(endpoint,
                        index < (this.status as StatusView).endpoints.length - 1)
                    }, (endpoint: EndpointView) => endpoint.id)
                }
                .width('100%')
                .backgroundColor(Theme.surface)
                .borderRadius(Theme.cardRadius)
                .border({ width: 1, color: Theme.line })
              }

              Text('把端点地址与令牌填进 Claude Code、Cursor 这类客户端的 MCP 设置里即可。')
                .fontSize(12)
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
        .width('100%')
        .layoutWeight(1)
        .onRefreshing((): void => {
          this.load().then((): void => {
            this.refreshing = false;
          }).catch((): void => {
            this.refreshing = false;
          });
        })
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

  /** 总开关 + 地址前缀 + 新建 */
  /** 总开关卡（对应 iOS：左边写清地址前缀，右边一个开关） */
  @Builder
  MasterCard(view: StatusView) {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text('启用 MCP 服务')
          .fontSize(15)
          .fontColor(Theme.text)
          .width('100%')
          .textAlign(TextAlign.Start)
        Text(view.base_url.length > 0 ? `${view.base_url}/mcp/<端点>` : '（未配置外部地址）/mcp/<端点>')
          .fontSize(12)
          .fontFamily('monospace')
          .fontColor(Theme.textFaint)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: view.enabled })
        .selectedColor(Theme.accent)
        .onChange((on: boolean): void => {
          this.toggleMaster(on);
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding(14)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  /** 端点行（对应 iOS `row`）：状态点 + 名称 / 路径 / 服务标签（最多 3 + 「+N」）/ 工具数 · 形态 · 最近调用；点行进详情 */
  @Builder
  EndpointRow(endpoint: EndpointView, separator: boolean) {
    Column() {
      Row({ space: 10 }) {
        Column({ space: 6 }) {
          Row({ space: 8 }) {
            Circle()
              .width(6)
              .height(6)
              .fill(endpoint.enabled ? Theme.ok : 'rgba(255, 255, 255, 0.25)')
            Text(endpoint.name)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.text)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .width('100%')

          Text(`/mcp/${endpoint.slug}`)
            .fontSize(12)
            .fontFamily('monospace')
            .fontColor(Theme.textMuted)
            .width('100%')
            .textAlign(TextAlign.Start)

          McpServiceChips({ services: endpoint.services, maxCount: 3 })

          Text(`${endpoint.tool_count} 个工具 · ${endpoint.expand_tools ? '一命令一工具' : '一服务一工具'}`
            + ` · ${McpFormat.lastUsed(endpoint.last_used_at ?? null)}`)
            .fontSize(12)
            .fontColor(Theme.textFaint)
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(12)
          .fontColor([Theme.textFaint])
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .padding({ left: 14, right: 12, top: 12, bottom: 12 })
      .opacity(endpoint.enabled ? 1 : 0.55)
      .onClick((): void => {
        this.openDetail(endpoint);
      })

      if (separator) {
        Divider().color(Theme.line).margin({ left: 14, right: 14 })
      }
    }
    .width('100%')
  }

  /** 一次性令牌条（新建 / 轮换后只出现一次） */
  @Builder
  TokenBar() {
    Column({ space: 6 }) {
      Text(`「${this.createdName}」的访问令牌（只显示这一次，请立刻复制）`)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.warn)
        .width('100%')
      Text(this.createdToken)
        .fontSize(12)
        .fontFamily('monospace')
        .fontColor(Theme.text)
        .copyOption(CopyOptions.InApp)
        .width('100%')
        .padding(10)
        .backgroundColor(Theme.surfaceRaised)
        .borderRadius(8)
      Text('关掉就不再显示了；忘了只能再轮换一次。')
        .fontSize(11)
        .fontColor(Theme.textFaint)
      Text('我知道了')
        .fontSize(13)
        .fontColor(Theme.accentStrong)
        .onClick(() => {
          this.createdToken = '';
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .backgroundColor('rgba(251, 191, 36, 0.08)')
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: 'rgba(251, 191, 36, 0.35)' })
  }

  /** 空态（对应 iOS `mcp-empty`） */
  @Builder
  EmptyState() {
    Column({ space: 8 }) {
      Text('还没有 MCP 端点')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
      Text('端点是给 AI 客户端用的入口：建一个、勾选要开放的服务，Claude Code 或 Cursor 填上地址和令牌，'
        + '就能直接查库存、搜资源、管订阅。每个端点的工具目录相互独立。')
        .fontSize(12)
        .fontColor(Theme.textMuted)
        .textAlign(TextAlign.Center)
      Text('点上面的「＋ 新建端点」开始。')
        .fontSize(12)
        .fontColor(Theme.textFaint)
    }
    .width('100%')
    .padding({ top: 20, bottom: 20 })
    .alignItems(HorizontalAlign.Center)
  }

  /** 编辑端点：把现有配置填进同一个表单（iOS 里详情页「设置」栏点编辑进的就是这份表单） */
  private openEdit(endpoint: EndpointView): void {
    this.formId = endpoint.id;
    this.formName = endpoint.name;
    this.formDesc = endpoint.description;
    this.formServices = endpoint.services.slice();
    this.formExpand = endpoint.expand_tools;
    this.formEnabled = endpoint.enabled;
    this.formError = '';
    this.sheetKind = 'form';
    this.showSheet = true;
  }

  // MARK: 端点详情（对齐 iOS `SettingsBMCPEndpointDetail` 的三栏：概览 / 工具 / 设置）

  private openDetail(endpoint: EndpointView): void {
    this.detailId = endpoint.id;
    this.detailTab = 'overview';
    this.preview = null;
    this.check = null;
    this.sheetKind = 'detail';
    this.showSheet = true;
  }

  private detailEndpoint(): EndpointView | null {
    const status: StatusView | null = this.status;
    if (status === null) {
      return null;
    }
    for (const endpoint of status.endpoints) {
      if (endpoint.id === this.detailId) {
        return endpoint;
      }
    }
    return null;
  }

  private async loadPreview(endpoint: EndpointView): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      this.preview = await api.mcpEndpointsPreview({ services: endpoint.services });
    } catch (error) {
      this.toast(this.messageOf(error));
    }
  }

  @Builder
  DetailSheet() {
    Column() {
      Row() {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(18)
          .fontColor([Theme.textMuted])
          .width(40)
          .height(40)
          .onClick((): void => {
            this.showSheet = false;
          })
        Blank()
        Text(this.detailEndpoint() !== null
          ? (this.detailEndpoint() as EndpointView).name : '端点')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Blank()
        Blank().width(40)
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 6, bottom: 6 })

      Row() {
        SettingsSegmentChip({
          label: '概览', selected: this.detailTab === 'overview',
          onPick: (): void => {
            this.detailTab = 'overview';
          }
        })
        SettingsSegmentChip({
          label: '工具', selected: this.detailTab === 'tools',
          onPick: (): void => {
            this.detailTab = 'tools';
            const endpoint: EndpointView | null = this.detailEndpoint();
            if (endpoint !== null && this.preview === null) {
              this.loadPreview(endpoint);
            }
          }
        })
        SettingsSegmentChip({
          label: '设置', selected: this.detailTab === 'settings',
          onPick: (): void => {
            this.detailTab = 'settings';
          }
        })
      }
      .width('100%')
      .padding(3)
      .margin({ left: 16, right: 16, bottom: 8 })
      .backgroundColor(Theme.glassFill)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })

      Scroll() {
        Column({ space: 12 }) {
          if (this.detailTab === 'overview') {
            this.DetailOverview()
          } else if (this.detailTab === 'tools') {
            this.DetailTools()
          } else {
            this.DetailSettings()
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 24 })
      }
      .layoutWeight(1)
      .align(Alignment.TopStart)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  /** 概览：地址 / 令牌 / 服务 / 最近调用 / 自检 */
  @Builder
  DetailOverview() {
    if (this.detailEndpoint() !== null) {
      Column({ space: 10 }) {
        this.ValueRow('端点地址', (this.detailEndpoint() as EndpointView).url)
        this.ValueRow('令牌前缀', (this.detailEndpoint() as EndpointView).token_hint)
        this.ValueRow('工具数', `${(this.detailEndpoint() as EndpointView).tool_count} 个`)
        this.ValueRow('调用形态', (this.detailEndpoint() as EndpointView).expand_tools
          ? '一命令一工具' : '一服务一工具')
        this.ValueRow('最近调用', McpFormat.lastUsed((this.detailEndpoint() as EndpointView).last_used_at ?? null))
        this.ValueRow('服务', (this.detailEndpoint() as EndpointView).services.length === 0
          ? '未选服务' : (this.detailEndpoint() as EndpointView).services.join('、'))
      }
      .width('100%')
      .padding(14)
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })

      if ((this.detailEndpoint() as EndpointView).missing_services.length > 0) {
        Text(`缺服务：${(this.detailEndpoint() as EndpointView).missing_services.join('、')}`)
          .fontSize(12)
          .fontColor(Theme.warn)
          .width('100%')
      }

      // 自检（对应 iOS 的自检卡）：真的带令牌跑一次握手
      Row({ space: 12 }) {
        Column({ space: 2 }) {
          Text('连接自检')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text)
          Text('用端点令牌跑一次 MCP 握手，确认客户端能连上')
            .fontSize(12)
            .fontColor(Theme.textFaint)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text(this.busyId === (this.detailEndpoint() as EndpointView).id ? '…' : '运行自检')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(14)
          .onClick((): void => {
            this.selfCheck(this.detailEndpoint() as EndpointView);
          })
      }
      .width('100%')
      .padding(14)
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })

      if (this.check !== null) {
        Column({ space: 6 }) {
          Text((this.check as SelfCheckView).ok ? '自检通过' : '自检失败')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor((this.check as SelfCheckView).ok ? Theme.ok : Theme.danger)
            .width('100%')
          Text((this.check as SelfCheckView).message)
            .fontSize(12)
            .fontColor(Theme.textMuted)
            .width('100%')
          Text(`协议 ${(this.check as SelfCheckView).protocol_version} · ${(this.check as SelfCheckView).tool_count} 个工具 · `
            + `${(this.check as SelfCheckView).elapsed_ms}ms`)
            .fontSize(12)
            .fontColor(Theme.textFaint)
            .width('100%')
          ForEach((this.check as SelfCheckView).warnings, (warning: string) => {
            Text(`· ${warning}`)
              .fontSize(12)
              .fontColor(Theme.warn)
              .width('100%')
          }, (warning: string) => warning)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(14)
        .backgroundColor(Theme.surface)
        .borderRadius(Theme.cardRadius)
        .border({ width: 1, color: Theme.line })
      }
    }
  }

  /** 工具：这一端点实际会开放出去的工具目录（`mcpEndpointsPreview`） */
  @Builder
  DetailTools() {
    if (this.preview === null) {
      Column({ space: 10 }) {
        LoadingProgress().width(22).height(22).color(Theme.textMuted)
        Text('正在算工具目录…').fontSize(13).fontColor(Theme.textFaint)
      }
      .width('100%')
      .padding({ top: 30 })
      .justifyContent(FlexAlign.Center)
    } else {
      Column({ space: 6 }) {
        Text(`${(this.preview as PreviewView).tool_count} 个工具 · ${(this.preview as PreviewView).command_count} 条命令`)
          .fontSize(13)
          .fontColor(Theme.textMuted)
          .width('100%')
        ForEach((this.preview as PreviewView).tools, (tool: ToolPreview) => {
          Column({ space: 2 }) {
            Text(tool.name)
              .fontSize(13)
              .fontFamily('monospace')
              .fontColor(Theme.text)
              .width('100%')
            if (tool.description.length > 0) {
              Text(tool.description)
                .fontSize(12)
                .fontColor(Theme.textFaint)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ top: 8, bottom: 8 })
        }, (tool: ToolPreview) => tool.name)
      }
      .width('100%')
      .padding(14)
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })
    }
  }

  /** 设置：启停 / 编辑（复用新建表单的字段与保存）/ 危险操作 */
  @Builder
  DetailSettings() {
    if (this.detailEndpoint() !== null) {
      Row({ space: 12 }) {
        Column({ space: 2 }) {
          Text('启用这个端点')
            .fontSize(15)
            .fontColor(Theme.text)
          Text('关掉后该地址一律返回 404，令牌与配置保留')
            .fontSize(12)
            .fontColor(Theme.textFaint)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: (this.detailEndpoint() as EndpointView).enabled })
          .selectedColor(Theme.accent)
          .onChange((on: boolean): void => {
            this.toggleEndpoint(this.detailEndpoint() as EndpointView, on);
          })
      }
      .width('100%')
      .padding(14)
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })

      Text('编辑配置')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor('#0b0d12')
        .textAlign(TextAlign.Center)
        .width('100%')
        .padding({ top: 13, bottom: 13 })
        .backgroundColor(Theme.accent)
        .borderRadius(Theme.cardRadius)
        .onClick((): void => {
          this.openEdit(this.detailEndpoint() as EndpointView);
        })

      Text(this.busyId === (this.detailEndpoint() as EndpointView).id ? '…' : '轮换访问令牌')
        .fontSize(15)
        .fontColor(Theme.text)
        .textAlign(TextAlign.Center)
        .width('100%')
        .padding({ top: 13, bottom: 13 })
        .backgroundColor(Theme.glassFill)
        .borderRadius(Theme.cardRadius)
        .onClick((): void => {
          this.confirmRotate(this.detailEndpoint() as EndpointView);
        })

      Text('删除端点')
        .fontSize(15)
        .fontColor(Theme.danger)
        .textAlign(TextAlign.Center)
        .width('100%')
        .padding({ top: 13, bottom: 13 })
        .backgroundColor(Theme.glassFill)
        .borderRadius(Theme.cardRadius)
        .onClick((): void => {
          this.confirmDelete(this.detailEndpoint() as EndpointView);
        })
    }
  }

  /** 详情里的一行「标签 + 值」（值等宽、右对齐） */
  @Builder
  ValueRow(label: string, value: string) {
    Row({ space: 10 }) {
      Text(label)
        .fontSize(13)
        .fontColor(Theme.textFaint)
        .width(72)
      Text(value)
        .fontSize(13)
        .fontFamily('monospace')
        .fontColor(Theme.text)
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.End)
    }
    .width('100%')
  }

  // MARK: 新建弹层

  // MARK: 新建弹层

  /** 唯一的弹层内容：按 sheetKind 切换 */
  @Builder
  SheetContent() {
    if (this.sheetKind === 'form') {
      this.FormSheet()
    } else if (this.sheetKind === 'detail') {
      this.DetailSheet()
    } else {
      this.CheckSheet()
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
        Text(this.formId.length > 0 ? '编辑端点' : '新建端点')
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
            this.Field('名称', this.formName, '例如「Claude Code」', (v: string): void => {
              this.formName = v;
            })
            Column({ space: 5 }) {
              Text('说明（可选）')
                .fontSize(13)
                .fontColor(Theme.textFaint)
                .width('100%')
              TextArea({ text: this.formDesc, placeholder: '给谁用的、用来做什么' })
                .width('100%')
                .height(70)
                .fontSize(14)
                .fontColor(Theme.text)
                .backgroundColor(Theme.surfaceRaised)
                .borderRadius(10)
                .padding(12)
                .onChange((v: string): void => {
                  this.formDesc = v;
                })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .padding(14)
          .backgroundColor(Theme.surface)
          .borderRadius(Theme.cardRadius)
          .border({ width: 1, color: Theme.line })

          // 开放哪些能力：只管能调用什么，不放大段说明（iOS 也是这个取舍）
          Column({ space: 0 }) {
            Text(`开放能力（已选 ${this.formServices.length}）`)
              .fontSize(13)
              .fontColor(Theme.textFaint)
              .width('100%')
              .padding({ left: 4, bottom: 6 })
            ForEach((this.status as StatusView).services, (service: ServiceView, index: number) => {
              Column() {
                Row({ space: 12 }) {
                  SymbolGlyph(this.formServices.indexOf(service.domain) >= 0
                    ? $r('sys.symbol.checkmark_square_fill') : $r('sys.symbol.square'))
                    .fontSize(19)
                    .fontColor([this.formServices.indexOf(service.domain) >= 0
                      ? Theme.accent : Theme.textFaint])
                  Column({ space: 2 }) {
                    Text(service.domain)
                      .fontSize(14)
                      .fontColor(Theme.text)
                    Text(`${service.description}  ·  ${service.command_count} 个命令`)
                      .fontSize(11)
                      .fontColor(Theme.textFaint)
                      .maxLines(2)
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                }
                .width('100%')
                .alignItems(VerticalAlign.Top)
                .padding({ left: 16, right: 16, top: 9, bottom: 9 })
                .onClick(() => {
                  this.toggleService(service.domain);
                })
                if (index < (this.status as StatusView).services.length - 1) {
                  Divider().color(Theme.line).margin({ left: 47, right: 16 })
                }
              }
              .width('100%')
            }, (service: ServiceView) => service.domain)
          }
          .width('100%')
          .backgroundColor(Theme.surface)
          .borderRadius(Theme.cardRadius)
          .border({ width: 1, color: Theme.line })

          Column({ space: 0 }) {
            Row({ space: 12 }) {
              Column({ space: 2 }) {
                Text('展开工具')
                  .fontSize(15)
                  .fontColor(Theme.text)
                Text('每个命令单独列成一个工具；关掉则按域合并，客户端看到的工具更少')
                  .fontSize(11)
                  .fontColor(Theme.textFaint)
                  .maxLines(2)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              Toggle({ type: ToggleType.Switch, isOn: this.formExpand })
                .selectedColor(Theme.accent)
                .onChange((on: boolean): void => {
                  this.formExpand = on;
                })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 11, bottom: 11 })
            Divider().color(Theme.line).margin({ left: 16, right: 16 })
            Row({ space: 12 }) {
              Column({ space: 2 }) {
                Text('创建后立即可用')
                  .fontSize(15)
                  .fontColor(Theme.text)
                Text('关掉则先建好但不启用')
                  .fontSize(11)
                  .fontColor(Theme.textFaint)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              Toggle({ type: ToggleType.Switch, isOn: this.formEnabled })
                .selectedColor(Theme.accent)
                .onChange((on: boolean): void => {
                  this.formEnabled = on;
                })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 11, bottom: 11 })
          }
          .width('100%')
          .backgroundColor(Theme.surface)
          .borderRadius(Theme.cardRadius)
          .border({ width: 1, color: Theme.line })
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

  /** 自检结果：协议版本 / 工具数 / 探针 / 警告 */
  @Builder
  CheckSheet() {
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

      if (this.check !== null) {
        Column({ space: 10 }) {
          Text(this.checkTitle)
            .fontSize(16)
            .fontWeight(600)
            .fontColor(Theme.text)
          Row({ space: 8 }) {
            Circle()
              .width(8)
              .height(8)
              .fill((this.check as SelfCheckView).ok ? Theme.ok : Theme.danger)
            Text((this.check as SelfCheckView).message)
              .fontSize(14)
              .fontColor(Theme.text)
              .layoutWeight(1)
          }
          .width('100%')
          Text(`协议 ${(this.check as SelfCheckView).protocol_version}  ·  `
            + `${(this.check as SelfCheckView).tool_count} 个工具  ·  `
            + `${(this.check as SelfCheckView).elapsed_ms}ms`)
            .fontSize(12)
            .fontColor(Theme.textMuted)
            .width('100%')
          Text(`探针 ${(this.check as SelfCheckView).probe_tool}：`
            + `${(this.check as SelfCheckView).probe_ok ? '通' : '不通'}`
            + ((this.check as SelfCheckView).probe_message.length > 0
              ? `（${(this.check as SelfCheckView).probe_message}）` : ''))
            .fontSize(12)
            .fontColor((this.check as SelfCheckView).probe_ok ? Theme.textMuted : Theme.danger)
            .width('100%')
          if ((this.check as SelfCheckView).warnings.length > 0) {
            Divider().color(Theme.line)
            Text(`有 ${(this.check as SelfCheckView).warnings.length} 条提醒`)
              .fontSize(13)
              .fontWeight(600)
              .fontColor(Theme.warn)
              .width('100%')
            ForEach((this.check as SelfCheckView).warnings, (warning: string) => {
              Text(warning)
                .fontSize(12)
                .fontColor(Theme.warn)
                .width('100%')
            }, (warning: string, index: number) => `${index}-${warning}`)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(16)
        .backgroundColor(Theme.surface)
        .borderRadius(Theme.cardRadius)
        .border({ width: 1, color: Theme.line })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16 })
    .backgroundColor(Theme.bg)
  }
}
