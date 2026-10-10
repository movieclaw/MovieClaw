import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { Formatters } from '../common/Formatters';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { AppFooter } from '../common/AppFooter';
import {
  LlmDefaultsPayload,
  LlmDefaultsView,
  LlmModelOptionView,
  LlmPresetView,
  LlmProviderPayload,
  LlmProviderView,
  ModelInfo,
  ModelInfoInput
} from '../api/Models';

/** 供应商状态（对应 iOS `SettingsBLLMProviderCard` 的 status） */
class LlmStatus {
  static readonly pending: string = 'pending';
  static readonly verifying: string = 'verifying';

  /** 待测试 / 测试中：这两态要轮询，落定前列表每 2 秒刷一次（同 iOS） */
  static isSettling(status: string): boolean {
    return status === LlmStatus.pending || status === LlmStatus.verifying;
  }

  static label(status: string, usable: boolean): string {
    if (status === LlmStatus.pending) {
      return '待测试';
    }
    if (status === LlmStatus.verifying) {
      return '测试中';
    }
    return usable ? '可用' : '不可用';
  }

  /** 四态文案（同 iOS `SettingsBLLMStatus.label`） */
  static labelOf(status: string): string {
    if (status === 'active') {
      return '已连接';
    }
    if (status === 'verifying') {
      return '测试中';
    }
    if (status === 'pending') {
      return '待测试';
    }
    if (status === 'failed') {
      return '连接失败';
    }
    return status;
  }

  /** 四态语义色（active 绿 / verifying 蓝 / failed 红 / 其余中性灰） */
  static tone(status: string): string {
    if (status === 'active') {
      return Theme.ok;
    }
    if (status === 'verifying') {
      return Theme.info;
    }
    if (status === 'failed') {
      return Theme.danger;
    }
    return Theme.textMuted;
  }

  static color(status: string, usable: boolean): string {
    if (LlmStatus.isSettling(status)) {
      return Theme.warn;
    }
    return usable ? Theme.ok : Theme.danger;
  }
}

/** 供应商提示文案与模型能力短标（同 iOS `SettingsBLLMFormat.providerHint` / `hints`） */
class LlmPresetHint {
  static of(preset: LlmPresetView): string {
    if (preset.id === 'bailian') {
      return '聚合 Qwen / DeepSeek / Kimi / GLM';
    }
    if (preset.id === 'openai') {
      return '官方端点，可配代理';
    }
    if (preset.requires_base_url) {
      return '自建 vLLM / Ollama / 任意网关';
    }
    return preset.base_url !== null && preset.base_url !== undefined && preset.base_url.length > 0
      ? preset.base_url : '官方端点';
  }

  /** 能力短标：思考 / 档位可控 / 视觉 / 视频 */
  static modelHints(model: ModelInfo): string {
    const parts: string[] = [];
    if (model.supports_thinking) {
      parts.push('思考');
    }
    if (model.thinking_levels.length > 0) {
      parts.push('档位可控');
    }
    if (model.modalities.indexOf('image') >= 0) {
      parts.push('视觉');
    }
    if (model.modalities.indexOf('video') >= 0) {
      parts.push('视频');
    }
    return parts.join(' · ');
  }
}

/** `LlmProviderPayload` 允许可选字段，但 ArkTS 拒「含可选字段的字面量」，用类填 */
class ProviderPayload implements LlmProviderPayload {
  name: string = '';
  provider_type: string = '';
  base_url?: string | null;
  user_agent?: string | null;
  api_key: string = '';
  default_model?: string | null;
  extra_models?: ModelInfoInput[] | null;
}

/**
 * `LlmDefaultsPayload` 两个字段都可选，同样用类绕开 `arkts-no-untyped-obj-literals`。
 */
class DefaultsPayload implements LlmDefaultsPayload {
  agent_model?: string | null;
  subtitle_model?: string | null;
}

/**
 * 设置 → 模型接入（对应 iOS `LLMSettingsView` / Web `llm-config-section`）。
 *
 * 这一页**只回答「怎么连上」**：可接入多个供应商实例（官方 + 中转 + 自建并存），
 * 每个实例一张状态卡。「哪个场景用哪个模型」不在这里配，见「AI 设定」——这个分工是 iOS 定的。
 *
 * 保存后后端会**异步**用目录第一个模型做一次最小对话验证，所以任一实例处于
 * 待测试 / 测试中时**每 2 秒刷新列表直到落定**；空闲时轮询回调不发请求。
 */
@ComponentV2
export struct LlmProvidersSection {
  @Local private providers: LlmProviderView[] = [];
  @Local private presets: LlmPresetView[] = [];
  @Local private loading: boolean = true;
  @Local private errorMessage: string = '';
  @Local private busyId: number = 0;

  // 新建 / 编辑表单
  @Local private showForm: boolean = false;
  @Local private formId: number = 0;
  @Local private formName: string = '';
  @Local private formType: string = '';
  @Local private formBaseUrl: string = '';
  @Local private formApiKey: string = '';
  @Local private formModel: string = '';
  @Local private formSaving: boolean = false;
  @Local private formError: string = '';
  /** 高级设置（User-Agent）展开态 */
  @Local private formAdvancedOpen: boolean = false;
  @Local private formUserAgent: string = '';

  private timer: number = -1;

  aboutToAppear(): void {
    this.load();
  }

  aboutToDisappear(): void {
    this.stopPoll();
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
      this.providers = await api.llmProvidersList();
      if (this.presets.length === 0) {
        this.presets = await api.llmPresets();
      }
      this.errorMessage = '';
    } catch (error) {
      this.errorMessage = this.messageOf(error);
    } finally {
      this.loading = false;
      this.schedulePoll();
    }
  }

  /** 有实例在待测试 / 测试中就 2 秒一轮，全都落定就停（同 iOS） */
  private schedulePoll(): void {
    let settling: boolean = false;
    for (const provider of this.providers) {
      if (LlmStatus.isSettling(provider.status)) {
        settling = true;
        break;
      }
    }
    this.stopPoll();
    if (!settling) {
      return;
    }
    this.timer = setInterval((): void => {
      this.load();
    }, 2000);
  }

  private stopPoll(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '操作失败';
  }

  private presetOf(id: string): LlmPresetView | null {
    for (const preset of this.presets) {
      if (preset.id === id) {
        return preset;
      }
    }
    return null;
  }

  // MARK: 表单

  private openCreate(): void {
    this.formId = 0;
    this.formName = '';
    this.formType = this.presets.length > 0 ? this.presets[0].id : '';
    this.formBaseUrl = this.presets.length > 0 ? (this.presets[0].base_url ?? '') : '';
    this.formApiKey = '';
    this.formModel = this.presets.length > 0 && this.presets[0].models.length > 0
      ? this.presets[0].models[0].id : '';
    this.formError = '';
    this.formAdvancedOpen = false;
    this.formUserAgent = '';
    this.showForm = true;
  }

  private openEdit(provider: LlmProviderView): void {
    this.formId = provider.id;
    this.formName = provider.name;
    this.formType = provider.provider_type;
    this.formBaseUrl = provider.base_url ?? '';
    this.formApiKey = '';
    this.formModel = provider.default_model;
    this.formError = '';
    this.formAdvancedOpen = false;
    this.formUserAgent = '';
    this.showForm = true;
  }

  private pickPreset(id: string): void {
    this.formType = id;
    const preset: LlmPresetView | null = this.presetOf(id);
    if (preset === null) {
      return;
    }
    if (this.formName.trim().length === 0) {
      this.formName = preset.display_name;
    }
    if (preset.requires_base_url && this.formBaseUrl.trim().length === 0) {
      this.formBaseUrl = preset.base_url ?? '';
    }
    if (this.formModel.length === 0 && preset.models.length > 0) {
      this.formModel = preset.models[0].id;
    }
  }

  private async saveForm(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.formSaving) {
      return;
    }
    const preset: LlmPresetView | null = this.presetOf(this.formType);
    if (this.formName.trim().length === 0) {
      this.formError = '给它起个名字，方便在「AI 设定」里认出来';
      return;
    }
    if (this.formId === 0 && this.formApiKey.trim().length === 0) {
      this.formError = '要填 API Key';
      return;
    }
    if (preset !== null && preset.requires_base_url && this.formBaseUrl.trim().length === 0) {
      this.formError = '这个供应商要填 Base URL（自建或中转地址）';
      return;
    }
    this.formSaving = true;
    this.formError = '';
    this.formAdvancedOpen = false;
    this.formUserAgent = '';
    try {
      const body: ProviderPayload = new ProviderPayload();
      body.name = this.formName.trim();
      body.provider_type = this.formType;
      body.base_url = this.formBaseUrl.trim().length > 0 ? this.formBaseUrl.trim() : null;
      body.api_key = this.formApiKey;
      body.default_model = this.formModel.trim().length > 0 ? this.formModel.trim() : null;
      body.user_agent = preset !== null && preset.default_user_agent.length > 0
        ? preset.default_user_agent : null;
      if (this.formId === 0) {
        await api.llmProvidersCreate(body);
      } else {
        await api.llmProvidersUpdate(this.formId, body);
      }
      this.showForm = false;
      this.toast('已保存，正在测试连通性…');
      await this.load();
    } catch (error) {
      this.formError = this.messageOf(error);
    } finally {
      this.formSaving = false;
    }
  }

  private async verify(provider: LlmProviderView): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.busyId = provider.id;
    try {
      await api.llmProvidersVerify(provider.id);
      await this.load();
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.busyId = 0;
    }
  }

  private confirmDelete(provider: LlmProviderView): void {
    this.getUIContext().showAlertDialog({
      title: '删除接入',
      message: `删除「${provider.name}」？用它跑的场景会退回默认模型。`,
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: Theme.danger,
        action: (): void => {
          this.remove(provider);
        }
      }
    });
  }

  private async remove(provider: LlmProviderView): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.busyId = provider.id;
    try {
      await api.llmProvidersDelete(provider.id);
      this.toast('已删除');
      await this.load();
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.busyId = 0;
    }
  }

  // MARK: 视图

  build() {
    Column() {
      if (this.loading) {
        Column({ space: 10 }) {
          LoadingProgress().width(24).height(24).color(Theme.textMuted)
          Text('正在加载接入…').fontSize(13).fontColor(Theme.textFaint)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column({ space: 12 }) {
            if (this.errorMessage.length > 0) {
              Row() {
                Text(this.errorMessage)
                  .fontSize(13)
                  .fontColor(Theme.danger)
                  .layoutWeight(1)
              }
              .width('100%')
              .padding(14)
              .backgroundColor(Theme.surface)
              .borderRadius(Theme.cardRadius)
              .border({ width: 1, color: 'rgba(255, 107, 107, 0.3)' })
            }

            // 简介：空态与非空态的措辞不同（同 iOS `introText`）
            Text(this.providers.length === 0
              ? '接入一个或多个大语言模型供应商，AI 能力（对话助手、字幕处理、智能识别等）将由它们驱动。'
              : '接入后该供应商目录里的全部模型都可在对话框里选用；各场景默认用哪个模型，在「AI 设定」里配置。')
              .fontSize(13)
              .fontColor(Theme.textMuted)
              .width('100%')
              .padding(14)
              .backgroundColor(Theme.surface)
              .borderRadius(Theme.cardRadius)
              .border({ width: 1, color: Theme.line })

            if (this.providers.length === 0) {
              this.EmptyState()
            } else {
              ForEach(this.providers, (provider: LlmProviderView) => {
                this.ProviderCard(provider)
              }, (provider: LlmProviderView) => `${provider.id}-${provider.status}`)

              // 「＋ 接入另一家供应商」（同 iOS：新增入口在列表末尾，不在顶栏）
              Text('＋ 接入另一家供应商')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.text)
                .textAlign(TextAlign.Center)
                .width('100%')
                .padding({ top: 14, bottom: 14 })
                .backgroundColor(Theme.glassFill)
                .borderRadius(Theme.cardRadius)
                .border({ width: 1, color: Theme.line })
                .onClick(() => {
                  this.openCreate();
                })
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
    .bindSheet($$this.showForm, this.FormSheet(), {
      height: SheetSize.LARGE,
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.bg
    })
  }

  /** 空态（对应 iOS `emptySection`）：图标方块 + 标题 + 支持范围 + 主按钮 */
  @Builder
  EmptyState() {
    Column({ space: 14 }) {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($r('sys.symbol.wand_and_stars'))
          .fontSize(24)
          .fontColor([Theme.text])
      }
      .width(48)
      .height(48)
      .backgroundColor('rgba(255, 255, 255, 0.07)')
      .borderRadius(14)

      Text('还没有接入模型供应商')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
      Text('支持 OpenAI、阿里云百炼，以及任何 OpenAI 兼容端点（如自建 vLLM / Ollama）。')
        .fontSize(12)
        .fontColor(Theme.textMuted)
        .textAlign(TextAlign.Center)

      Text('接入模型供应商')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor('#0b0d12')
        .textAlign(TextAlign.Center)
        .width('100%')
        .padding({ top: 14, bottom: 14 })
        .backgroundColor(Theme.accent)
        .borderRadius(Theme.cardRadius)
        .onClick(() => {
          this.openCreate();
        })
    }
    .width('100%')
    .padding(20)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  /** 状态胶囊：圆点 + 文案（已连接 / 测试中 / 待测试 / 连接失败，同 iOS `SettingsBLLMStatusPill`） */
  @Builder
  StatusPill(status: string) {
    Row({ space: 5 }) {
      Circle()
        .width(6)
        .height(6)
        .fill(LlmStatus.tone(status))
      Text(LlmStatus.labelOf(status))
        .fontSize(11)
        .fontWeight(FontWeight.Medium)
        .fontColor(LlmStatus.tone(status) === Theme.textMuted ? Theme.textMuted : LlmStatus.tone(status))
    }
    .padding({ left: 8, right: 8, top: 2, bottom: 2 })
    .backgroundColor(LlmStatus.tone(status) === Theme.textMuted
      ? Theme.glassFill : 'rgba(255, 255, 255, 0.12)')
    .borderRadius(12)
  }

  /** 值行：左标签 + 右值（等宽，未知显示「官方默认」） */
  @Builder
  ValueRow(label: string, value: string) {
    Row({ space: 10 }) {
      Text(label)
        .fontSize(13)
        .fontColor(Theme.textFaint)
        .width(88)
      Text(value)
        .fontSize(13)
        .fontFamily('monospace')
        .fontColor(Theme.text)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.End)
    }
    .width('100%')
  }

  /** 一个供应商实例（对应 iOS `SettingsBLLMProviderCard`）：名称 + 状态、副标题、连接信息、三等分操作行 */
  @Builder
  ProviderCard(provider: LlmProviderView) {
    Column({ space: 10 }) {
      Column({ space: 4 }) {
        Row({ space: 8 }) {
          Text(provider.name)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          this.StatusPill(provider.status)
        }
        .width('100%')

        Text(this.providerSubtitle(provider))
          .fontSize(12)
          .fontColor(provider.status === 'failed'
            ? Theme.danger : Theme.textFaint)
          .width('100%')
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Column({ space: 8 }) {
        this.ValueRow('API 端点', provider.base_url ?? this.presetBaseUrl(provider) ?? '官方默认')
        this.ValueRow('连接测试模型', provider.default_model)
        // 只有用户覆盖过 UA 才显示（没配的用户不需要知道有这回事）
        if (provider.user_agent !== null && provider.user_agent !== undefined
          && provider.user_agent.length > 0) {
          this.ValueRow('User-Agent', provider.user_agent)
        }
      }
      .width('100%')

      // 三等分操作行：编辑配置 / 重新测试 / 删除
      Row({ space: 8 }) {
        Text('编辑配置')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
          .textAlign(TextAlign.Center)
          .maxLines(1)
          .layoutWeight(1)
          .padding({ top: 9, bottom: 9 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(12)
          .onClick(() => {
            this.openEdit(provider);
          })
        Text(this.busyId === provider.id ? '…' : '重新测试')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(LlmStatus.isSettling(provider.status) ? Theme.textFaint : Theme.text)
          .textAlign(TextAlign.Center)
          .maxLines(1)
          .layoutWeight(1)
          .padding({ top: 9, bottom: 9 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(12)
          .onClick(() => {
            if (!LlmStatus.isSettling(provider.status)) {
              this.verify(provider);
            }
          })
        Text('删除')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.danger)
          .textAlign(TextAlign.Center)
          .maxLines(1)
          .layoutWeight(1)
          .padding({ top: 9, bottom: 9 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(12)
          .onClick(() => {
            this.confirmDelete(provider);
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

  /** 副标题：失败时直接写原因；否则「供应商 · N 个自定义模型 · 上次检查 X」 */
  private providerSubtitle(provider: LlmProviderView): string {
    const reason: string | null = provider.last_error ?? null;
    if (provider.status === 'failed' && reason !== null && reason.length > 0) {
      return reason;
    }
    const parts: string[] = [this.presetDisplayName(provider)];
    if (provider.extra_models.length > 0) {
      parts.push(`${provider.extra_models.length} 个自定义模型`);
    }
    const checked: string | null = provider.last_checked_at ?? null;
    const relative: string = checked === null || checked.length === 0
      ? '从未' : Formatters.relative(checked);
    parts.push(`上次检查 ${relative}`);
    return parts.join(' · ');
  }

  private presetFor(provider: LlmProviderView): LlmPresetView | null {
    return this.presetOf(provider.provider_type);
  }

  private presetDisplayName(provider: LlmProviderView): string {
    const preset: LlmPresetView | null = this.presetFor(provider);
    return preset !== null ? preset.display_name : provider.provider_type;
  }

  private presetBaseUrl(provider: LlmProviderView): string | null {
    const preset: LlmPresetView | null = this.presetFor(provider);
    return preset !== null ? (preset.base_url ?? null) : null;
  }

  // MARK: 表单弹层

  /** 连接表单（对齐 iOS `SettingsBLLMProviderForm`）：供应商 → 连接信息（含高级里的 UA）→ 连接测试模型 */
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
            this.showForm = false;
          })
        Blank()
        Text(this.formId === 0 ? '接入模型供应商' : `编辑「${this.formName}」`)
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

      Scroll() {
        Column({ space: 14 }) {
          if (this.formError.length > 0) {
            Text(this.formError).fontSize(13).fontColor(Theme.danger).width('100%')
          }

          // ① 供应商（预设 chips + 该供应商的提示）
          Column({ space: 8 }) {
            Text('供应商')
              .fontSize(13)
              .fontColor(Theme.textFaint)
              .width('100%')
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.presets, (preset: LlmPresetView) => {
                Text(preset.display_name)
                  .fontSize(13)
                  .fontColor(this.formType === preset.id ? '#0b0d12' : Theme.textMuted)
                  .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                  .backgroundColor(this.formType === preset.id ? Theme.accent : Theme.glassFill)
                  .borderRadius(15)
                  .margin({ right: 8, bottom: 8 })
                  .onClick(() => {
                    this.pickPreset(preset.id);
                  })
              }, (preset: LlmPresetView) => preset.id)
            }
            .width('100%')
            if (this.presetOf(this.formType) !== null) {
              Column({ space: 2 }) {
                Text(this.presetNameOf(this.formType))
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Theme.text)
                  .width('100%')
                Text(this.presetHintOf(this.formType))
                  .fontSize(12)
                  .fontColor(Theme.textFaint)
                  .width('100%')
              }
              .width('100%')
            }
            Text('保存后系统会自动测试连接。')
              .fontSize(12)
              .fontColor(Theme.textFaint)
              .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(14)
          .backgroundColor(Theme.surface)
          .borderRadius(Theme.cardRadius)
          .border({ width: 1, color: Theme.line })

          // ② 连接信息
          Column({ space: 12 }) {
            this.Field('实例名（可选）', this.formName,
              this.formId === 0 ? this.presetNameOr(this.formType, '如：官方 OpenAI / 家里的 vLLM')
                : this.presetNameOr(this.formType, '实例名'),
              (v: string): void => {
                this.formName = v;
              })
            if (this.canCustomizeEndpoint()) {
              this.Field(this.needBaseUrl() ? 'API 端点 *' : 'API 端点（可选）', this.formBaseUrl,
                this.needBaseUrl() ? 'http://192.168.1.5:8000/v1' : '官方默认端点',
                (v: string): void => {
                  this.formBaseUrl = v;
                })
            }
            // API Key：编辑时留空不改，用密码态输入框（右测自带的显示 / 隐藏）
            Column({ space: 5 }) {
              Text(this.formId === 0 ? 'API Key' : 'API Key（留空不改）')
                .fontSize(13)
                .fontColor(Theme.textFaint)
                .width('100%')
              TextInput({
                text: this.formApiKey,
                placeholder: this.formId === 0 ? 'sk-…' : '出于安全，请重新填写'
              })
                .type(InputType.Password)
                .showPasswordIcon(true)
                .width('100%')
                .height(42)
                .fontSize(15)
                .fontColor(Theme.text)
                .backgroundColor(Theme.surfaceRaised)
                .borderRadius(10)
                .padding({ left: 12, right: 12 })
                .onChange((v: string): void => {
                  this.formApiKey = v;
                })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)

            // 高级设置：User-Agent（低频排障字段，默认折叠）
            if (this.canCustomizeEndpoint()) {
              Column({ space: 8 }) {
                Row() {
                  Text('高级设置')
                    .fontSize(13)
                    .fontColor(Theme.textMuted)
                    .layoutWeight(1)
                  Text(this.formAdvancedOpen ? '收起' : 'User-Agent')
                    .fontSize(12)
                    .fontColor(Theme.textFaint)
                  SymbolGlyph(this.formAdvancedOpen
                    ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
                    .fontSize(11)
                    .fontColor([Theme.textFaint])
                    .margin({ left: 4 })
                }
                .width('100%')
                .onClick((): void => {
                  this.formAdvancedOpen = !this.formAdvancedOpen;
                })
                if (this.formAdvancedOpen) {
                  TextInput({
                    text: this.formUserAgent,
                    placeholder: this.presetDefaultUaOf(this.formType)
                  })
                    .width('100%')
                    .height(42)
                    .fontSize(13)
                    .fontFamily('monospace')
                    .fontColor(Theme.text)
                    .backgroundColor(Theme.surfaceRaised)
                    .borderRadius(10)
                    .padding({ left: 12, right: 12 })
                    .onChange((v: string): void => {
                      this.formUserAgent = v;
                    })
                  Text('仅当网关或 WAF 对请求标识有要求时填写，留空使用上方显示的 SDK 默认值。')
                    .fontSize(12)
                    .fontColor(Theme.textFaint)
                    .width('100%')
                }
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(14)
          .backgroundColor(Theme.surface)
          .borderRadius(Theme.cardRadius)
          .border({ width: 1, color: Theme.line })

          // ③ 连接测试模型：预设带目录就从目录里挑，自定义端点手填
          Column({ space: 8 }) {
            Text('连接测试模型')
              .fontSize(13)
              .fontColor(Theme.textFaint)
              .width('100%')
            if (this.formCatalog().length === 0) {
              TextInput({ text: this.formModel, placeholder: '留空用目录里第一个模型' })
                .width('100%')
                .height(42)
                .fontSize(15)
                .fontColor(Theme.text)
                .backgroundColor(Theme.surfaceRaised)
                .borderRadius(10)
                .padding({ left: 12, right: 12 })
                .onChange((v: string): void => {
                  this.formModel = v;
                })
            } else {
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(this.formCatalog(), (model: ModelInfo) => {
                  Text(model.id + (LlmPresetHint.modelHints(model).length > 0
                    ? `（${LlmPresetHint.modelHints(model)}）` : ''))
                    .fontSize(13)
                    .fontColor(this.formModel === model.id ? '#0b0d12' : Theme.textMuted)
                    .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                    .backgroundColor(this.formModel === model.id ? Theme.accent : Theme.glassFill)
                    .borderRadius(15)
                    .margin({ right: 8, bottom: 8 })
                    .onClick((): void => {
                      this.formModel = model.id;
                    })
                }, (model: ModelInfo) => `m-${model.id}`)
              }
              .width('100%')
              Text('后端用这个模型做一次最小对话验证；保存后稍等几秒看状态。')
                .fontSize(12)
                .fontColor(Theme.textFaint)
                .width('100%')
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(14)
          .backgroundColor(Theme.surface)
          .borderRadius(Theme.cardRadius)
          .border({ width: 1, color: Theme.line })
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 20 })
      }
      .layoutWeight(1)
      .align(Alignment.TopStart)
      .scrollBar(BarState.Off)

      // 保存键放底部（同 iOS 的 `SubsPrimaryButton("保存并测试连接")`）
      Text(this.formSaving ? '保存中…' : '保存并测试连接')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.formSaving ? Theme.textFaint : '#0b0d12')
        .textAlign(TextAlign.Center)
        .width('100%')
        .padding({ top: 15, bottom: 15 })
        .margin({ left: 16, right: 16, top: 8, bottom: 8 + Theme.safeBottomInset })
        .backgroundColor(this.formSaving ? Theme.glassFill : Theme.accent)
        .borderRadius(18)
        .onClick(() => {
          if (!this.formSaving) {
            this.saveForm();
          }
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  private presetNameOf(typeId: string): string {
    const preset: LlmPresetView | null = this.presetOf(typeId);
    return preset !== null ? preset.display_name : typeId;
  }

  private presetNameOr(typeId: string, fallback: string): string {
    const preset: LlmPresetView | null = this.presetOf(typeId);
    return preset !== null ? preset.display_name : fallback;
  }

  private presetHintOf(typeId: string): string {
    const preset: LlmPresetView | null = this.presetOf(typeId);
    return preset !== null ? LlmPresetHint.of(preset) : '';
  }

  private presetDefaultUaOf(typeId: string): string {
    const preset: LlmPresetView | null = this.presetOf(typeId);
    return preset !== null ? preset.default_user_agent : '留空使用 SDK 默认标识';
  }

  /** 预设是否带目录：带目录就不用填端点（官方固定端点），自定义端点要手填 */
  private formCatalog(): ModelInfo[] {
    const preset: LlmPresetView | null = this.presetOf(this.formType);
    return preset !== null ? preset.models : [];
  }

  private needBaseUrl(): boolean {
    const preset: LlmPresetView | null = this.presetOf(this.formType);
    return preset !== null ? preset.requires_base_url : true;
  }

  /** 固定端点的官方渠道不展示端点输入；OpenAI 保留可选输入（代理/镜像），通用兼容端点必填 */
  private canCustomizeEndpoint(): boolean {
    const preset: LlmPresetView | null = this.presetOf(this.formType);
    return preset === null || preset.base_url === null || preset.base_url === undefined;
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
}

/**
 * 设置 → AI 设定（对应 iOS `AIDefaultsSettingsView` / Web `ai-settings-section`）：
 * **什么场景用哪个模型**。
 *
 * 与「模型接入」分开是 iOS 定的分工——接入回答「怎么连上」，这里回答「智能体 / 字幕处理默认用哪个」。
 *
 * 选项是所有已接入实例的模型清单（`llmModels`）。**选择即保存**，乐观更新、失败回滚；
 * 服务端保证接入过供应商就一定有默认值，所以显示的是真实存的值；一个都没接入时给空态，
 * 引导去「模型接入」。
 */
@ComponentV2
export struct AiDefaultsSection {
  @Local private defaults: LlmDefaultsView | null = null;
  @Local private options: LlmModelOptionView[] = [];
  @Local private loading: boolean = true;
  @Local private errorMessage: string = '';
  @Local private saving: string = '';
  @Local private picking: string = '';

  aboutToAppear(): void {
    this.load();
  }

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  private async load(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      this.defaults = await api.llmDefaultsShow();
      this.options = await api.llmModels();
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
    return text.length > 0 ? text : '保存失败';
  }

  /** 当前生效的值：优先用户选的，没有就用服务端的推荐值 */
  private agentModel(): string {
    const view: LlmDefaultsView | null = this.defaults;
    if (view === null) {
      return '';
    }
    const chosen: string | null = view.agent_model ?? null;
    if (chosen !== null && chosen.length > 0) {
      return chosen;
    }
    return view.effective_agent_model ?? '';
  }

  private subtitleModel(): string {
    const view: LlmDefaultsView | null = this.defaults;
    if (view === null) {
      return '';
    }
    const chosen: string | null = view.subtitle_model ?? null;
    if (chosen !== null && chosen.length > 0) {
      return chosen;
    }
    return view.effective_subtitle_model ?? '';
  }

  private labelOf(ref: string): string {
    for (const option of this.options) {
      if (option.ref === ref) {
        return `${option.label}  ·  ${option.provider_name}`;
      }
    }
    return ref.length > 0 ? ref : '还没选';
  }

  /**
   * 选择即保存（乐观更新、失败回滚）。
   * 另一项若已失效（不在清单里）不能原样回传——传空让服务端按推荐补齐（同 iOS）。
   */
  private async choose(purpose: string, ref: string): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const view: LlmDefaultsView | null = this.defaults;
    if (api === null || view === null || this.saving.length > 0) {
      return;
    }
    const previous: LlmDefaultsView = view;
    const optimistic: LlmDefaultsView = {
      agent_model: purpose === 'agent' ? ref : view.agent_model,
      subtitle_model: purpose === 'subtitle' ? ref : view.subtitle_model,
      effective_agent_model: purpose === 'agent' ? ref : view.effective_agent_model,
      effective_subtitle_model: purpose === 'subtitle' ? ref : view.effective_subtitle_model
    };
    this.defaults = optimistic;
    this.picking = '';
    this.saving = purpose;
    try {
      const body: DefaultsPayload = new DefaultsPayload();
      body.agent_model = this.validOrNull(optimistic.agent_model);
      body.subtitle_model = this.validOrNull(optimistic.subtitle_model);
      this.defaults = await api.llmDefaultsUpdate(body);
    } catch (error) {
      this.defaults = previous;
      this.getUIContext().getPromptAction().showToast({ message: this.messageOf(error) });
    } finally {
      this.saving = '';
    }
  }

  /** 不在候选清单里的值不能原样回传（后端会拒绝），传 null 让它按推荐补齐 */
  private validOrNull(ref: string | null | undefined): string | null {
    const value: string = ref ?? '';
    if (value.length === 0) {
      return null;
    }
    for (const option of this.options) {
      if (option.ref === value) {
        return value;
      }
    }
    return null;
  }

  build() {
    Column() {
      if (this.loading) {
        Column({ space: 10 }) {
          LoadingProgress().width(24).height(24).color(Theme.textMuted)
          Text('正在加载设定…').fontSize(13).fontColor(Theme.textFaint)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.options.length === 0) {
        Column({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.star_fill'))
            .fontSize(30)
            .fontColor([Theme.textFaint])
          Text('还没接入模型')
            .fontSize(16)
            .fontWeight(600)
            .fontColor(Theme.text)
          Text('先去「设置 → 模型接入」接一个，回来才能选默认模型。')
            .fontSize(13)
            .fontColor(Theme.textMuted)
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .layoutWeight(1)
        .padding(24)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column({ space: 14 }) {
            if (this.errorMessage.length > 0) {
              Text(this.errorMessage).fontSize(13).fontColor(Theme.danger).width('100%')
            }
            this.PurposeCard('agent', '智能体', 'AI 对话、分析与自动处理用这个模型', this.agentModel())
            this.PurposeCard('subtitle', '字幕处理', '翻译与生成字幕用这个模型', this.subtitleModel())
            Text('选择即保存。服务端保证接入过供应商就一定有默认值，所以这里显示的永远是真实生效的那个。')
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
    .bindSheet($$this.showPicker, this.PickerSheet(), {
      height: SheetSize.MEDIUM,
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.bg
    })
  }

  @Local private showPicker: boolean = false;

  @Builder
  PurposeCard(purpose: string, title: string, hint: string, current: string) {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        Column({ space: 3 }) {
          Text(title)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text)
          Text(hint)
            .fontSize(12)
            .fontColor(Theme.textFaint)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        if (this.saving === purpose) {
          LoadingProgress().width(16).height(16).color(Theme.textMuted)
        }
      }
      .width('100%')
      Row({ space: 8 }) {
        Text(this.labelOf(current))
          .fontSize(14)
          .fontColor(current.length > 0 ? Theme.accentStrong : Theme.textMuted)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('换一个')
          .fontSize(13)
          .fontColor(Theme.text)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(14)
          .onClick(() => {
            this.picking = purpose;
            this.showPicker = true;
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

  @Builder
  PickerSheet() {
    Column() {
      Text('选择模型')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .padding({ top: 16, bottom: 10 })
      List() {
        ForEach(this.options, (option: LlmModelOptionView) => {
          ListItem() {
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text(option.label)
                  .fontSize(15)
                  .fontColor(Theme.text)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(option.provider_name)
                  .fontSize(12)
                  .fontColor(Theme.textFaint)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              if (option.ref === (this.picking === 'agent' ? this.agentModel() : this.subtitleModel())) {
                SymbolGlyph($r('sys.symbol.checkmark'))
                  .fontSize(16)
                  .fontColor([Theme.accent])
              }
            }
            .width('100%')
            .padding({ left: 20, right: 20, top: 12, bottom: 12 })
            .onClick(() => {
              this.choose(this.picking, option.ref);
            })
          }
        }, (option: LlmModelOptionView) => option.ref)
      }
      .layoutWeight(1)
      .align(Alignment.TopStart)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }
}
