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
  ModelInfoInput,
  ThinkingControl,
  ThinkingControlInput
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

/** token 数 → 简短可读（同 iOS `SettingsBLLMFormat.tokens`）：2 的幂按 1024 进制（65536 → 64K），其余十进制（1050000 → 1.05M） */
class LlmTokens {
  static format(n: number): string {
    if (n % 1024 === 0 && n < 1000000) {
      return `${n / 1024}K`;
    }
    if (n >= 1000000) {
      if (n % 1000000 === 0) {
        return `${n / 1000000}M`;
      }
      return `${(n / 1000000).toFixed(2)}M`;
    }
    return `${Math.round(n / 1000)}K`;
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

  /** 规格说明：上下文 / 最大输出 / 思考预算 / 并发工具，未公布的字段不显示（同 iOS `specs`） */
  static modelSpecs(model: ModelInfo): string {
    const parts: string[] = [];
    const contextWindow: number | null = model.context_window ?? null;
    if (contextWindow !== null) {
      parts.push(`上下文 ${LlmTokens.format(contextWindow)}`);
    }
    const maxOutput: number | null = model.max_output_tokens ?? null;
    if (maxOutput !== null) {
      parts.push(`最大输出 ${LlmTokens.format(maxOutput)}`);
    }
    const maxThinking: number | null = model.max_thinking_tokens ?? null;
    if (maxThinking !== null) {
      parts.push(`思考预算 ${LlmTokens.format(maxThinking)}`);
    }
    if (model.supports_parallel_tool_calls) {
      parts.push('支持并发工具调用');
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
  api_protocol?: string | null;
  api_key?: string | null;
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

/** 借用分组：其它预设目录里尚未补录的模型（label = 预设显示名） */
class PresetGroup {
  label: string = '';
  models: ModelInfo[] = [];
}

/** 思考控制声明：同时满足 View / Input 两种契约（同 iOS `ThinkingControl` / `ThinkingControlInput`） */
class ControlInfo implements ThinkingControl, ThinkingControlInput {
  kind: string = '';
  levels: string[] = [];
  supports_off: boolean = false;

  constructor(kind: string, levels: string[], supportsOff: boolean) {
    this.kind = kind;
    this.levels = levels;
    this.supports_off = supportsOff;
  }
}

/** 自定义模型草稿 build 出的目录条目（View 形态；thinking_levels 是服务端推导字段，恒为空） */
class DraftModelInfo implements ModelInfo {
  id: string = '';
  context_window?: number | null = null;
  max_input_tokens?: number | null = null;
  max_output_tokens?: number | null = null;
  supports_tools: boolean = true;
  supports_parallel_tool_calls: boolean = false;
  supports_thinking: boolean = false;
  max_thinking_tokens?: number | null = null;
  thinking_control?: ThinkingControl | null = null;
  modalities: string[] = [];
  thinking_levels: string[] = [];
}

/** 读到的目录条目（View）→ 提交用的 Input：编辑时原样回传已有的自定义目录（同 iOS `settingsBLLMInput`） */
class ModelInputOf implements ModelInfoInput {
  id: string = '';
  context_window?: number | null = null;
  max_input_tokens?: number | null = null;
  max_input_tokens_thinking?: number | null = null;
  max_output_tokens?: number | null = null;
  default_output_tokens?: number | null = null;
  supports_tools?: boolean | null = null;
  requires_responses_for_tools?: boolean | null = null;
  chat_tools_require_no_reasoning?: boolean | null = null;
  max_tokens_parameter?: string | null = null;
  sampling_requires_no_reasoning?: boolean | null = null;
  fixed_sampling?: boolean | null = null;
  supports_parallel_tool_calls?: boolean | null = null;
  supports_thinking?: boolean | null = null;
  max_thinking_tokens?: number | null = null;
  thinking_control?: ThinkingControlInput | null = null;
  modalities?: string[] | null = null;

  constructor(model: ModelInfo) {
    this.id = model.id;
    this.context_window = model.context_window ?? null;
    this.max_input_tokens = model.max_input_tokens ?? null;
    this.max_input_tokens_thinking = model.max_input_tokens_thinking ?? null;
    this.max_output_tokens = model.max_output_tokens ?? null;
    this.default_output_tokens = model.default_output_tokens ?? null;
    this.supports_tools = model.supports_tools;
    this.requires_responses_for_tools = model.requires_responses_for_tools ?? null;
    this.chat_tools_require_no_reasoning = model.chat_tools_require_no_reasoning ?? null;
    this.max_tokens_parameter = model.max_tokens_parameter ?? null;
    this.sampling_requires_no_reasoning = model.sampling_requires_no_reasoning ?? null;
    this.fixed_sampling = model.fixed_sampling ?? null;
    this.supports_parallel_tool_calls = model.supports_parallel_tool_calls;
    this.supports_thinking = model.supports_thinking;
    this.max_thinking_tokens = model.max_thinking_tokens ?? null;
    const control: ThinkingControl | null = model.thinking_control ?? null;
    this.thinking_control = control !== null
      ? new ControlInfo(control.kind, control.levels, control.supports_off) : null;
    this.modalities = model.modalities;
  }
}

/**
 * 「自定义模型参数」子表单的输入状态（数字以字符串暂存，提交时转换；同 iOS `SettingsBLLMModelDraft`）。
 * 这些参数是 agent 做上下文 / 思考预算决策的依据。
 */
@ObservedV2
class LlmModelDraft {
  @Trace id: string = '';
  @Trace contextWindow: string = '';
  @Trace maxInput: string = '';
  @Trace maxOutput: string = '';
  @Trace thinkingBudget: string = '';
  @Trace supportsTools: boolean = true;
  @Trace parallel: boolean = false;
  @Trace thinking: boolean = false;
  @Trace vision: boolean = false;
  @Trace video: boolean = false;
  /** 思考控制方言：none = 不可控（只展示思考内容，即不声明 thinking_control） */
  @Trace thinkingKind: string = 'none';
  @Trace thinkingLevels: string[] = [];
  @Trace supportsOff: boolean = false;

  /** effort 制可声明的档位（词汇表排除 off——关闭走「支持关闭思考」开关） */
  static readonly declarableLevels: string[] = ['minimal', 'low', 'medium', 'high', 'xhigh', 'max'];
  private static readonly levelLabels: Record<string, string> = {
    'minimal': '最少',
    'low': '低',
    'medium': '中',
    'high': '高',
    'xhigh': '超高',
    'max': '最高'
  };

  static levelLabel(level: string): string {
    return LlmModelDraft.levelLabels[level] ?? level;
  }

  static thinkingKindOptions(): string[] {
    return ['none', 'effort', 'budget', 'toggle'];
  }

  static thinkingKindLabel(kind: string): string {
    if (kind === 'none') {
      return '不可控（只展示思考内容）';
    }
    if (kind === 'effort') {
      return '档位直传（reasoning_effort）';
    }
    if (kind === 'budget') {
      return '预算分段（enable_thinking + thinking_budget）';
    }
    if (kind === 'toggle') {
      return '仅开关（thinking.type）';
    }
    return kind;
  }

  static positiveInt(s: string): number | null {
    const text: string = s.trim();
    if (text.length === 0) {
      return null;
    }
    const n: number = Number(text);
    if (!Number.isInteger(n) || n <= 0) {
      return null;
    }
    return n;
  }

  /** 必填校验：id / 上下文 / 最大输出；开思考则预算也必填；档位直传制至少声明一档 */
  static isValid(d: LlmModelDraft): boolean {
    return d.id.trim().length > 0
      && LlmModelDraft.positiveInt(d.contextWindow) !== null
      && LlmModelDraft.positiveInt(d.maxOutput) !== null
      && (!d.thinking || LlmModelDraft.positiveInt(d.thinkingBudget) !== null)
      && (d.thinkingKind !== 'effort' || d.thinkingLevels.length > 0);
  }

  static hintOf(d: LlmModelDraft): string {
    if (d.thinkingKind === 'effort' && d.thinkingLevels.length === 0) {
      return '档位直传模式至少要勾选一个可选档位。';
    }
    return '请补全新模型参数中标有 * 的项目。';
  }

  /** 切换一个档位（按固定词汇表顺序归一，声明不是有序集合）；整组重赋值保证 @Trace 可观察 */
  static toggleLevel(d: LlmModelDraft, level: string): void {
    const next: string[] = d.thinkingLevels.slice();
    const index: number = next.indexOf(level);
    if (index >= 0) {
      next.splice(index, 1);
    } else {
      next.push(level);
    }
    d.thinkingLevels = next;
  }

  /** 草稿 → 目录条目（同 iOS `build`） */
  static build(d: LlmModelDraft): ModelInfo {
    const info: DraftModelInfo = new DraftModelInfo();
    info.id = d.id.trim();
    info.context_window = LlmModelDraft.positiveInt(d.contextWindow);
    info.max_input_tokens = LlmModelDraft.positiveInt(d.maxInput);
    info.max_output_tokens = LlmModelDraft.positiveInt(d.maxOutput);
    info.supports_tools = d.supportsTools;
    info.supports_parallel_tool_calls = d.parallel;
    info.supports_thinking = d.thinking;
    info.max_thinking_tokens = d.thinking ? LlmModelDraft.positiveInt(d.thinkingBudget) : null;
    if (d.thinking && d.thinkingKind !== 'none') {
      // toggle 的意义就是可关，隐含 supports_off；其余按勾选（同 iOS）
      info.thinking_control = new ControlInfo(d.thinkingKind,
        d.thinkingKind === 'effort' ? d.thinkingLevels.slice() : [],
        d.thinkingKind === 'toggle' ? true : d.supportsOff);
    }
    const modalities: string[] = ['text'];
    if (d.vision) {
      modalities.push('image');
    }
    if (d.video) {
      modalities.push('video');
    }
    info.modalities = modalities;
    return info;
  }
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
  /** 高级设置（API 协议 / User-Agent）展开态 */
  @Local private formAdvancedOpen: boolean = false;
  @Local private formUserAgent: string = '';
  /** API 协议：空串 = 跟随预设默认（不编码，后端沿用原值或用默认） */
  @Local private formApiProtocol: string = '';
  /** 编辑时记录原供应商类型与端点：变了才要求重填 API Key（与后端同一判据） */
  private formOriginalType: string = '';
  private formOriginalBaseUrl: string = '';
  /** 自定义模型目录草稿（随配置持久化）：无内置目录的兼容端点靠它定义可用模型（同 iOS extraModels） */
  @Local private formExtraModels: ModelInfo[] = [];
  /** 「自定义模型」参数子表单展开态 */
  @Local private formAddingCustom: boolean = false;
  @Local private draft: LlmModelDraft = new LlmModelDraft();

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

  /**
   * 可手动接入的预设（同 iOS `editablePresets`）：chatgpt 由服务器托管，
   * 手机端不做订阅配置，不出现在接入表单里。
   */
  private editablePresets(): LlmPresetView[] {
    const out: LlmPresetView[] = [];
    for (const preset of this.presets) {
      if (preset.id !== 'chatgpt') {
        out.push(preset);
      }
    }
    return out;
  }

  /** 服务器托管的接入（chatgpt）：手机端只读，不给编辑/重测/删除（同 iOS `serverManaged`） */
  private serverManaged(provider: LlmProviderView): boolean {
    return provider.provider_type === 'chatgpt';
  }

  // MARK: 表单

  private openCreate(): void {
    // 表单只给可手动接入的预设（chatgpt 由服务器托管，不出现）
    const presets: LlmPresetView[] = this.editablePresets();
    this.formId = 0;
    this.formName = '';
    this.formType = presets.length > 0 ? presets[0].id : '';
    this.formBaseUrl = '';
    this.formApiKey = '';
    this.formModel = presets.length > 0 && presets[0].models.length > 0
      ? presets[0].models[0].id : '';
    this.formExtraModels = [];
    this.formAddingCustom = false;
    this.draft = new LlmModelDraft();
    this.formError = '';
    this.formAdvancedOpen = false;
    this.formUserAgent = '';
    this.formApiProtocol = '';
    this.formOriginalType = '';
    this.formOriginalBaseUrl = '';
    this.showForm = true;
  }

  private openEdit(provider: LlmProviderView): void {
    this.formId = provider.id;
    this.formName = provider.name;
    this.formType = provider.provider_type;
    this.formBaseUrl = provider.base_url ?? '';
    this.formApiKey = '';
    this.formModel = provider.default_model;
    this.formExtraModels = provider.extra_models.slice();
    this.formAddingCustom = false;
    this.draft = new LlmModelDraft();
    this.formError = '';
    this.formUserAgent = provider.user_agent ?? '';
    this.formApiProtocol = provider.api_protocol ?? '';
    this.formOriginalType = provider.provider_type;
    this.formOriginalBaseUrl = provider.base_url ?? '';
    // 改过 UA 或协议的实例默认展开高级区，让已有配置一眼可见
    this.formAdvancedOpen = (provider.user_agent ?? '').length > 0
      || (provider.api_protocol ?? '').length > 0;
    this.showForm = true;
  }

  private pickPreset(id: string): void {
    if (this.formType === id) {
      return;
    }
    // 换供应商：端点 / UA / 协议 / 高级区 / 参数子表单都与上一家无关，一并清掉（同 iOS onChange）；
    // 已补录的自定义目录不删——切回来即恢复
    this.formType = id;
    this.formBaseUrl = '';
    this.formUserAgent = '';
    this.formApiProtocol = '';
    this.formAdvancedOpen = false;
    this.formAddingCustom = false;
    this.draft = new LlmModelDraft();
    this.formModel = '';
    const preset: LlmPresetView | null = this.presetOf(id);
    if (preset === null) {
      return;
    }
    if (this.formName.trim().length === 0) {
      this.formName = preset.display_name;
    }
    if (preset.models.length > 0) {
      this.formModel = preset.models[0].id;
    }
  }

  /** 协议可切换的预设（OpenAI / 通用兼容端点）才展示协议选择 */
  private protocolOptionsOf(typeId: string): string[] {
    const preset: LlmPresetView | null = this.presetOf(typeId);
    return preset === null ? [] : (preset.selectable_protocols ?? []);
  }

  /** 预设的默认协议（chips 上标「（默认）」用） */
  private presetProtocolOf(typeId: string): string {
    const preset: LlmPresetView | null = this.presetOf(typeId);
    return preset === null ? '' : (preset.protocol ?? '');
  }

  private canChooseProtocol(): boolean {
    return this.protocolOptionsOf(this.formType).length > 1;
  }

  /** 当前生效的协议：没选过跟随预设默认 */
  private effectiveProtocol(): string {
    if (this.formApiProtocol.length > 0) {
      return this.formApiProtocol;
    }
    const preset: LlmPresetView | null = this.presetOf(this.formType);
    const fallback: string = preset === null ? '' : (preset.protocol ?? '');
    return fallback.length > 0 ? fallback : '';
  }

  /** API 协议展示名（与 Web PROTOCOL_LABELS 一致） */
  private protocolLabel(id: string): string {
    if (id === 'openai_chat') {
      return 'Chat Completions';
    }
    if (id === 'openai_responses') {
      return 'Responses API';
    }
    return id;
  }

  /** 编辑时 Key 可留空沿用；但类型或端点变了必须重填（与后端同一判据），免得旧 Key 被发往新地址 */
  private apiKeyRequired(): boolean {
    if (this.formId === 0) {
      return true;
    }
    let url: string = this.formBaseUrl.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return this.formType !== this.formOriginalType || url !== this.formOriginalBaseUrl;
  }

  private async saveForm(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.formSaving) {
      return;
    }
    if (this.formName.trim().length === 0) {
      this.formError = '给它起个名字，方便在「AI 设定」里认出来';
      return;
    }
    if (this.formName.indexOf('/') >= 0) {
      this.formError = '实例名不能包含斜杠 /。';
      return;
    }
    if (this.apiKeyRequired() && this.formApiKey.trim().length === 0) {
      this.formError = this.formId === 0 ? '要填 API Key' : '更换了供应商或 API 端点，请重新填写 API Key';
      return;
    }
    const baseUrl: string = this.formBaseUrl.trim();
    if (this.needBaseUrl() && baseUrl.length === 0) {
      this.formError = '这个供应商要填 Base URL（自建或中转地址）';
      return;
    }
    if (baseUrl.length > 0 && !/^https?:\/\/.+/.test(baseUrl)) {
      this.formError = '请填写以 http:// 或 https:// 开头的完整 API 端点。';
      return;
    }
    // 兼容端点没有内置目录，接入后要有模型可用就必须至少补录一个
    if (this.isCustomEndpoint() && this.formExtraModels.length === 0) {
      this.formError = '请至少添加一个模型（接入后才有模型可用）。';
      return;
    }
    if (!this.uaValid()) {
      this.formError = 'User-Agent 包含不支持的字符，请检查高级设置。';
      return;
    }
    this.formSaving = true;
    this.formError = '';
    this.formAdvancedOpen = false;
    try {
      const body: ProviderPayload = new ProviderPayload();
      body.name = this.formName.trim();
      body.provider_type = this.formType;
      body.base_url = baseUrl.length > 0 ? baseUrl : null;
      // 留空不编码：编辑时沿用原 Key
      body.api_key = this.formApiKey.trim().length > 0 ? this.formApiKey.trim() : null;
      // 没选过就不编码：新增跟随预设默认，编辑沿用原值
      body.api_protocol = this.canChooseProtocol() && this.formApiProtocol.length > 0
        ? this.formApiProtocol : null;
      // 连接测试模型：官方渠道可从目录里指定；自定义端点留给后端取目录第一个（同 iOS defaultModel: nil）
      body.default_model = this.isCustomEndpoint() || this.formModel.trim().length === 0
        ? null : this.formModel.trim();
      // 端点固定的官方渠道不开放 UA 配置，一律回传 null；留空 = 沿用 SDK 默认（同 iOS）
      body.user_agent = this.canCustomizeEndpoint() && this.formUserAgent.trim().length > 0
        ? this.formUserAgent.trim() : null;
      // 官方渠道不回传自定义目录；兼容端点把补录目录全量提交（同 iOS）
      body.extra_models = this.isCustomEndpoint()
        ? this.formExtraModels.map((model: ModelInfo): ModelInfoInput => new ModelInputOf(model))
        : [];
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
        if (!this.serverManaged(provider)) {
          this.ValueRow('API 端点', provider.base_url ?? this.presetBaseUrl(provider) ?? '官方默认')
        }
        this.ValueRow('连接测试模型', provider.default_model)
        if (!this.serverManaged(provider)) {
          if ((provider.api_protocol ?? '').length > 0) {
            this.ValueRow('API 协议', this.protocolLabel(provider.api_protocol ?? ''))
          }
          // 只有用户覆盖过 UA 才显示（没配的用户不需要知道有这回事）
          if (provider.user_agent !== null && provider.user_agent !== undefined
            && provider.user_agent.length > 0) {
            this.ValueRow('User-Agent', provider.user_agent)
          }
        }
      }
      .width('100%')

      if (this.serverManaged(provider)) {
        // 服务器托管（chatgpt）：不给编辑/重测/删除，模型在对话里直接选用（同 iOS serverManaged）
        Text('此接入由服务器管理。已配置的模型可在对话中选用。')
          .fontSize(12)
          .fontColor(Theme.textMuted)
          .width('100%')
          .maxLines(2)
      } else {
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
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  /** 副标题：失败时直接写原因；否则「供应商（托管时是服务器模型） · N 个模型 · 上次检查 X」 */
  private providerSubtitle(provider: LlmProviderView): string {
    const managed: boolean = this.serverManaged(provider);
    const reason: string | null = provider.last_error ?? null;
    if (provider.status === 'failed' && reason !== null && reason.length > 0) {
      return reason;
    }
    const parts: string[] = [managed ? '服务器模型' : this.presetDisplayName(provider)];
    if (provider.extra_models.length > 0) {
      parts.push(`${provider.extra_models.length} 个${managed ? '可用' : '自定义'}模型`);
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
              ForEach(this.editablePresets(), (preset: LlmPresetView) => {
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
            // API Key：新建必填；编辑留空沿用原 Key（改了类型/端点除外），密码态输入框
            Column({ space: 5 }) {
              Text(this.apiKeyRequired() ? 'API Key *' : 'API Key')
                .fontSize(13)
                .fontColor(Theme.textFaint)
                .width('100%')
              TextInput({
                text: this.formApiKey,
                placeholder: this.apiKeyRequired() ? 'sk-…' : '留空保持原密钥不变'
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
              if (this.formId !== 0) {
                Text(this.apiKeyRequired()
                  ? '更换了供应商或 API 端点，需要重新填写密钥。'
                  : '已保存的密钥不会回显；留空则继续使用原密钥。')
                  .fontSize(12)
                  .fontColor(Theme.textFaint)
                  .width('100%')
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)

            // 高级设置：API 协议与 User-Agent（低频字段，默认折叠）
            if (this.canCustomizeEndpoint()) {
              Column({ space: 8 }) {
                Row() {
                  Text('高级设置')
                    .fontSize(13)
                    .fontColor(Theme.textMuted)
                    .layoutWeight(1)
                  Text(this.canChooseProtocol() ? 'API 协议 · User-Agent' : 'User-Agent')
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
                  // API 协议（可切换的预设才展示）：chips 单选
                  if (this.canChooseProtocol()) {
                    Column({ space: 6 }) {
                      Text('API 协议')
                        .fontSize(13)
                        .fontColor(Theme.textFaint)
                        .width('100%')
                      Flex({ wrap: FlexWrap.Wrap }) {
                        ForEach(this.protocolOptionsOf(this.formType), (option: string) => {
                          Text(this.protocolLabel(option)
                            + (option === this.presetProtocolOf(this.formType) ? '（默认）' : ''))
                            .fontSize(13)
                            .fontColor(this.effectiveProtocol() === option ? '#0b0d12' : Theme.textMuted)
                            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                            .backgroundColor(this.effectiveProtocol() === option
                              ? Theme.accent : Theme.glassFill)
                            .borderRadius(15)
                            .margin({ right: 8, bottom: 8 })
                            .onClick(() => {
                              this.formApiProtocol = option;
                            })
                        }, (option: string) => option)
                      }
                      .width('100%')
                      Text('GPT-5.6 等推理模型要在调用工具时调节思维链强度，需选 Responses API；端点不支持 /v1/responses 时选 Chat Completions。')
                        .fontSize(12)
                        .fontColor(Theme.textFaint)
                        .width('100%')
                    }
                    .width('100%')
                    .alignItems(HorizontalAlign.Start)
                  }
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

          // ③ 模型目录：官方渠道以预设为准；兼容端点必须补录（可借用其它预设目录，或展开参数子表单）
          this.FormCatalogSection()

          if (this.isCustomEndpoint() && this.formAddingCustom) {
            this.FormCustomModelSection()
          }

          // ④ 连接测试模型：官方渠道从预设目录里挑（自定义端点测试用补录目录第一个，不用挑）
          if (!this.isCustomEndpoint()) {
            Column({ space: 8 }) {
              Text('连接测试模型')
                .fontSize(13)
                .fontColor(Theme.textFaint)
                .width('100%')
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
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(14)
            .backgroundColor(Theme.surface)
            .borderRadius(Theme.cardRadius)
            .border({ width: 1, color: Theme.line })
          }
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

  /** 无内置目录的兼容端点：模型目录必须自己补录（同 iOS `isCustomEndpoint`） */
  private isCustomEndpoint(): boolean {
    return this.formCatalog().length === 0;
  }

  private hasExtra(id: string): boolean {
    for (const model of this.formExtraModels) {
      if (model.id === id) {
        return true;
      }
    }
    return false;
  }

  /** 无内置目录的端点：把其它预设目录的模型也纳入可添加（换端点时模型名与参数往往一致） */
  private borrowedGroups(): PresetGroup[] {
    if (!this.isCustomEndpoint()) {
      return [];
    }
    const out: PresetGroup[] = [];
    for (const preset of this.presets) {
      if (preset.id === this.formType || preset.models.length === 0) {
        continue;
      }
      const models: ModelInfo[] = [];
      for (const model of preset.models) {
        if (!this.hasExtra(model.id)) {
          models.push(model);
        }
      }
      if (models.length > 0) {
        const group: PresetGroup = new PresetGroup();
        group.label = preset.display_name;
        group.models = models;
        out.push(group);
      }
    }
    return out;
  }

  /** 借用其它预设目录里的同名模型：选中即入列，参数原样复制 */
  private borrow(model: ModelInfo): void {
    if (this.hasExtra(model.id)) {
      return;
    }
    const next: ModelInfo[] = this.formExtraModels.slice();
    next.push(model);
    this.formExtraModels = next;
  }

  private removeExtra(id: string): void {
    this.formExtraModels = this.formExtraModels.filter((model: ModelInfo): boolean => model.id !== id);
  }

  /** 把参数子表单里的自定义模型加进目录（同 id 覆盖旧条目：改参数重存是常见操作） */
  private addCustomModel(): void {
    const custom: ModelInfo = LlmModelDraft.build(this.draft);
    const next: ModelInfo[] = this.formExtraModels.filter((model: ModelInfo): boolean => model.id !== custom.id);
    next.push(custom);
    this.formExtraModels = next;
    this.draft = new LlmModelDraft();
    this.formAddingCustom = false;
  }

  private cancelCustomModel(): void {
    this.draft = new LlmModelDraft();
    this.formAddingCustom = false;
  }

  /** 请求头值只能是可打印 ASCII（与后端校验同一判据），空即用 SDK 默认 */
  private uaValid(): boolean {
    const ua: string = this.formUserAgent.trim();
    if (ua.length === 0) {
      return true;
    }
    for (let i = 0; i < ua.length; i++) {
      const code: number = ua.charCodeAt(i);
      if (code < 0x20 || code > 0x7E) {
        return false;
      }
    }
    return true;
  }

  /** 目录条目详情行：规格 · 能力短标（都没公布就写「参数以官方文档为准」） */
  private modelDetail(model: ModelInfo): string {
    const parts: string[] = [];
    const specs: string = LlmPresetHint.modelSpecs(model);
    if (specs.length > 0) {
      parts.push(specs);
    }
    const hints: string = LlmPresetHint.modelHints(model);
    if (hints.length > 0) {
      parts.push(hints);
    }
    return parts.length > 0 ? parts.join(' · ') : '参数以官方文档为准';
  }

  /** 模型目录卡（对齐 iOS `catalogSection`）：兼容端点列已补录模型 + 借用分组 + 自定义入口；官方渠道只写预设说明 */
  @Builder
  FormCatalogSection() {
    if (this.isCustomEndpoint()) {
      Column({ space: 10 }) {
        Text('模型目录 *')
          .fontSize(13)
          .fontColor(Theme.textFaint)
          .width('100%')
        ForEach(this.formExtraModels, (model: ModelInfo) => {
          this.ExtraModelRow(model)
        }, (model: ModelInfo) => `e-${model.id}`)
        ForEach(this.borrowedGroups(), (group: PresetGroup) => {
          this.BorrowGroup(group)
        }, (group: PresetGroup) => group.label)
        if (!this.formAddingCustom) {
          Text('＋ 自定义模型（填写参数）')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text)
            .textAlign(TextAlign.Center)
            .maxLines(1)
            .width('100%')
            .padding({ top: 10, bottom: 10 })
            .backgroundColor(Theme.glassFill)
            .borderRadius(12)
            .onClick(() => {
              this.formAddingCustom = true;
            })
        }
        Text('兼容端点没有内置目录，请把端点上部署的模型添加进来（含参数）。接入后这些模型可在 AI 设定与对话框里选用；连接测试用第一个。')
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
    } else if (this.presetOf(this.formType) !== null) {
      Column() {
        Text(`模型目录以「${this.presetNameOf(this.formType)}」预设为准，共 ${this.formCatalog().length} 个模型，接入后可在 AI 设定与对话框里选用；连接测试用目录里第一个。`)
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
    }
  }

  /** 已补录的模型行：id + 规格/能力详情 + 移除 */
  @Builder
  ExtraModelRow(model: ModelInfo) {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        Text(model.id)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.modelDetail(model))
          .fontSize(11)
          .fontColor(Theme.textFaint)
          .maxLines(2)
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Text('移除')
        .fontSize(12)
        .fontColor(Theme.textMuted)
        .padding({ left: 10, right: 10, top: 5, bottom: 5 })
        .backgroundColor(Theme.glassFill)
        .borderRadius(12)
        .onClick(() => {
          this.removeExtra(model.id);
        })
    }
    .width('100%')
  }

  /** 其它预设目录的借用分组：点模型即入列，参数复用 */
  @Builder
  BorrowGroup(group: PresetGroup) {
    Column({ space: 6 }) {
      Text(`${group.label} 目录（同名模型参数复用）`)
        .fontSize(12)
        .fontColor(Theme.textMuted)
        .width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(group.models, (model: ModelInfo) => {
          Text(model.id + (LlmPresetHint.modelHints(model).length > 0
            ? `（${LlmPresetHint.modelHints(model)}）` : ''))
            .fontSize(12)
            .fontColor(Theme.textMuted)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .backgroundColor(Theme.glassFill)
            .borderRadius(13)
            .margin({ right: 8, bottom: 8 })
            .onClick(() => {
              this.borrow(model);
            })
        }, (model: ModelInfo) => `b-${model.id}`)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 自定义模型参数子表单（对齐 iOS `customModelSection`）：必填项带 *，参数是 agent 决策的依据 */
  @Builder
  FormCustomModelSection() {
    Column({ space: 12 }) {
      Text('自定义模型参数')
        .fontSize(13)
        .fontColor(Theme.textFaint)
        .width('100%')
      this.Field('模型 id *', this.draft.id, '如：my-vllm-model', (v: string): void => {
        this.draft.id = v;
      })
      this.Field('上下文长度 *', this.draft.contextWindow, '131072', (v: string): void => {
        this.draft.contextWindow = v;
      })
      this.Field('最大输出 *', this.draft.maxOutput, '8192', (v: string): void => {
        this.draft.maxOutput = v;
      })
      this.Field('最大输入（可选）', this.draft.maxInput, '不单独限制可留空', (v: string): void => {
        this.draft.maxInput = v;
      })
      this.DraftSwitch('支持工具调用', this.draft.supportsTools, true, (on: boolean): void => {
        this.draft.supportsTools = on;
        if (!on) {
          this.draft.parallel = false;
        }
      })
      this.DraftSwitch('支持并发工具调用', this.draft.parallel, this.draft.supportsTools, (on: boolean): void => {
        this.draft.parallel = on;
      })
      this.DraftSwitch('输出思考内容', this.draft.thinking, true, (on: boolean): void => {
        this.draft.thinking = on;
        if (!on) {
          this.draft.thinkingKind = 'none';
        }
      })
      this.DraftSwitch('支持图片输入', this.draft.vision, true, (on: boolean): void => {
        this.draft.vision = on;
      })
      this.DraftSwitch('支持视频输入', this.draft.video, true, (on: boolean): void => {
        this.draft.video = on;
      })
      if (this.draft.thinking) {
        this.Field('思考预算上限 *', this.draft.thinkingBudget, '如：81920', (v: string): void => {
          this.draft.thinkingBudget = v;
        })
        Column({ space: 6 }) {
          Text('思考强度控制')
            .fontSize(13)
            .fontColor(Theme.textFaint)
            .width('100%')
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(LlmModelDraft.thinkingKindOptions(), (kind: string) => {
              Text(LlmModelDraft.thinkingKindLabel(kind))
                .fontSize(12)
                .fontColor(this.draft.thinkingKind === kind ? '#0b0d12' : Theme.textMuted)
                .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                .backgroundColor(this.draft.thinkingKind === kind ? Theme.accent : Theme.glassFill)
                .borderRadius(13)
                .margin({ right: 8, bottom: 8 })
                .onClick(() => {
                  this.draft.thinkingKind = kind;
                })
            }, (kind: string) => kind)
          }
          .width('100%')
          Text('按端点方言选择；声明后会话输入框出现思考档位选择器，档位只从声明的菜单里选（不做就近换算）。')
            .fontSize(12)
            .fontColor(Theme.textFaint)
            .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        if (this.draft.thinkingKind === 'effort') {
          Column({ space: 6 }) {
            Text('可声明档位')
              .fontSize(13)
              .fontColor(Theme.textFaint)
              .width('100%')
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(LlmModelDraft.declarableLevels, (level: string) => {
                Text(LlmModelDraft.levelLabel(level))
                  .fontSize(12)
                  .fontColor(this.draft.thinkingLevels.indexOf(level) >= 0 ? '#0b0d12' : Theme.textMuted)
                  .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                  .backgroundColor(this.draft.thinkingLevels.indexOf(level) >= 0
                    ? Theme.accent : Theme.glassFill)
                  .borderRadius(13)
                  .margin({ right: 8, bottom: 8 })
                  .onClick(() => {
                    LlmModelDraft.toggleLevel(this.draft, level);
                  })
              }, (level: string) => level)
            }
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        if (this.draft.thinkingKind === 'effort' || this.draft.thinkingKind === 'budget') {
          Column({ space: 4 }) {
            this.DraftSwitch('支持关闭思考', this.draft.supportsOff, true, (on: boolean): void => {
              this.draft.supportsOff = on;
            })
            Text('仅当端点有真正的关闭参数时勾选（如 enable_thinking=false）；勾选后档位菜单多出「关」。')
              .fontSize(12)
              .fontColor(Theme.textFaint)
              .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
      }
      if (!LlmModelDraft.isValid(this.draft)) {
        Text(LlmModelDraft.hintOf(this.draft))
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .width('100%')
      }
      Row({ space: 10 }) {
        Text('添加到目录')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(LlmModelDraft.isValid(this.draft) ? '#0b0d12' : Theme.textFaint)
          .textAlign(TextAlign.Center)
          .maxLines(1)
          .layoutWeight(1)
          .padding({ top: 11, bottom: 11 })
          .backgroundColor(LlmModelDraft.isValid(this.draft) ? Theme.accent : Theme.glassFill)
          .borderRadius(12)
          .onClick(() => {
            if (LlmModelDraft.isValid(this.draft)) {
              this.addCustomModel();
            }
          })
        Text('取消')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
          .textAlign(TextAlign.Center)
          .maxLines(1)
          .layoutWeight(1)
          .padding({ top: 11, bottom: 11 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(12)
          .onClick(() => {
            this.cancelCustomModel();
          })
      }
      .width('100%')
      Text('按端点实际部署的模型规格填写，添加后计入本实例的模型目录。')
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
  }

  /** 子表单开关行（样式同 ScrapeSection 的 Switch，紧凑一点） */
  @Builder
  DraftSwitch(label: string, isOn: boolean, enabled: boolean, onChange: (on: boolean) => void) {
    Row({ space: 12 }) {
      Text(label)
        .fontSize(14)
        .fontColor(enabled ? Theme.text : Theme.textFaint)
        .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .selectedColor(Theme.accent)
        .enabled(enabled)
        .onChange((on: boolean): void => {
          onChange(on);
        })
    }
    .width('100%')
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
