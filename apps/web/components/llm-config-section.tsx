"use client";

import { useLocale, useTranslations } from "next-intl";
import { appTranslator, type AppMessageKey } from "@/lib/i18n/translate";
import type { AppLocale } from "@/lib/i18n/negotiate";
import { useMessageState, type Message } from "@/lib/i18n/use-message-state";

import { useCallback, useEffect, useState } from "react";

import { ErrorBanner } from "@/components/cloud-push-ui";
import { ChatGPTPlanConnect } from "@/components/chatgpt-plan-connect";
import { useConfirm } from "@/components/feedback";
import { PlusIcon, SparkIcon } from "@/components/icons";
import { useLlmCapability } from "@/components/llm-gate";
import {
  SETTINGS_BUTTON_CLASS,
  SETTINGS_INPUT_CLASS,
  SETTINGS_PRIMARY_BUTTON_CLASS,
  SettingsEmpty,
  SettingsList,
  SettingsMoreMenu,
  SettingsRow,
  SettingsSection,
} from "@/components/settings-ui";
import {
  type LlmApiProtocol,
  type LlmModelInfo,
  type LlmPreset,
  type LlmProviderConfig,
  type LlmProviderPayload,
  type LlmProviderStatus,
  type LlmProviderType,
  createLlmProvider,
  deleteLlmProvider,
  discoverLlmModels,
  listLlmPresets,
  listLlmProviders,
  reverifyLlmProvider,
  updateLlmProvider,
} from "@/lib/api/llm";
import { invalidateModelOptionsCache } from "@/lib/llm-thinking";
import { formatRelativeTime } from "@/lib/time";
import { useVisiblePolling } from "@/lib/use-visible-polling";

/** 连接状态 → 展示文案与颜色（与站点/下载器配置同语言） */
const STATUS_META: Record<LlmProviderStatus, { label: AppMessageKey; color: string }> = {
  active: { label: "settings.llm.ui.connected", color: "var(--ok)" },
  verifying: { label: "settings.llm.ui.testing", color: "var(--info)" },
  pending: { label: "settings.llm.ui.pending", color: "#c0c4cc" },
  failed: { label: "settings.llm.ui.failed", color: "var(--danger)" },
};

/** 需要轮询测试进度的中间态 */
const IN_PROGRESS: LlmProviderStatus[] = ["pending", "verifying"];

/** 表单的打开方式：null 关闭；"new" 新增；对象为编辑该实例 */
type Editing = null | "new" | LlmProviderConfig;

/**
 * 「模型接入」设置分区：只回答「怎么连上」。
 *
 * 与下载器分区同构：可接入多个供应商实例（官方 + 中转 + 自建可并存），
 * 每个实例一张状态卡片；接入后该实例目录里的全部模型都可在对话框与
 * 「AI 设定」里选用。哪个场景用哪个模型不在这里配——见 ai-settings-section。
 * 保存后后端用目录里第一个模型发一次最小对话验证，前端对中间态轮询刷新。
 */
export function LlmConfigSection() {
  const t = useTranslations();
  const locale = useLocale() as AppLocale;
  const confirm = useConfirm();
  const { refresh: refreshLlmCapability } = useLlmCapability();
  const [providers, setProviders] = useState<LlmProviderConfig[]>([]);
  const [presets, setPresets] = useState<LlmPreset[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useMessageState();
  const [editing, setEditing] = useState<Editing>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    setError(null);
    try {
      setProviders(await listLlmProviders());
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setLoading(false);
    }
  }, [setError]);

  useEffect(() => {
    void load();
    // 预设目录是静态数据，进分区拉一次即可
    listLlmPresets()
      .then(setPresets)
      .catch((e) => setError((e as Error).message));
  }, [load, locale, setError]);

  // 任一实例处于 pending/verifying 时轮询刷新，直到落定（页面隐藏时暂停）
  const inProgress = providers.some((p) => IN_PROGRESS.includes(p.status));
  useVisiblePolling(
    () => {
      void listLlmProviders()
        .then(setProviders)
        .catch(() => {
          /* 轮询失败静默重试，不打断页面 */
        });
    },
    inProgress ? 2000 : null,
  );

  async function guard(fn: () => Promise<void>) {
    setBusy(true);
    setError(null);
    try {
      await fn();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  /** 增删改之后统一走这里：刷新列表、作废对话框的模型清单缓存、通知门禁 */
  async function afterChange() {
    await load();
    invalidateModelOptionsCache();
    refreshLlmCapability();
  }

  return (
    <div className="space-y-10">
      {error && <ErrorBanner>{error}</ErrorBanner>}

      {editing !== null ? (
        /* 编辑态只保留表单，避免状态卡在小屏重复占据首屏 */
        <SettingsSection
          title={editing === "new" ? t("settings.llm.ui.addTitle") : t("settings.llm.ui.editTitle", {name: editing.name})}
          description={t("settings.llm.ui.autoTest")}
        >
          <div className="css-glass !rounded-xl p-5 max-sm:p-4">
            <LlmProviderForm
              config={editing === "new" ? null : editing}
              presets={presets}
              // 其它实例已占用的名字：留空按供应商名保存时据此加序号，避免撞唯一名
              takenNames={providers
                .filter((p) => editing === "new" || p.id !== editing.id)
                .map((p) => p.name)}
              onSubmit={async (payload) => {
                if (editing === "new") await createLlmProvider(payload);
                else await updateLlmProvider(editing.id, payload);
                setEditing(null);
                await afterChange();
              }}
              onCancel={() => { setEditing(null); void afterChange(); }}
              onError={setError}
            />
          </div>
        </SettingsSection>
      ) : (
        <SettingsSection
          title={t("settings.llm.ui.provider")}
          description={
            loading
              ? t("settings.llm.ui.loading")
              : providers.length === 0
                ? t("settings.llm.ui.emptyIntro")
                : t("settings.llm.ui.connectedIntro")
          }
          action={
            !loading && (
              <button
                type="button"
                onClick={() => setEditing("new")}
                className={`${SETTINGS_PRIMARY_BUTTON_CLASS} flex items-center gap-1`}
              >
                <PlusIcon className="size-4" />
                {t("settings.llm.ui.add")}</button>
            )
          }
        >
          {loading ? (
            <div className="h-[104px] animate-pulse rounded-xl bg-white/[0.04]" />
          ) : providers.length === 0 ? (
            /* 空态：一个都没接入；入口在小节标题行右侧 */
            <SettingsEmpty
              icon={<SparkIcon className="size-5" />}
              title={t("settings.llm.ui.empty")}
              description={t("settings.llm.ui.supported")}
            />
          ) : (
            <SettingsList>
              {providers.map((config) => (
                <ProviderRow
                  key={config.id}
                  config={config}
                  preset={presets.find((p) => p.id === config.provider_type)}
                  busy={busy}
                  onEdit={() => setEditing(config)}
                  onReverify={() =>
                    void guard(async () => {
                      await reverifyLlmProvider(config.id);
                      await load();
                    })
                  }
                  onDelete={() =>
                    void guard(async () => {
                      if (
                        !(await confirm({
                          title: t("settings.llm.ui.deleteTitle", {name: config.name}),
                          description:
                            t("settings.llm.ui.deleteHint"),
                          confirmLabel: t("settings.llm.ui.delete"),
                          tone: "danger",
                        }))
                      ) {
                        return;
                      }
                      const result = await deleteLlmProvider(config.id);
                      await afterChange();
                      if (config.provider_type === "chatgpt" && result.remoteRevoked !== true) {
                        await confirm({ title: t("settings.llm.ui.chatgptRemoved"), description: result.message, confirmLabel: t("settings.llm.ui.understood") });
                      }
                    })
                  }
                />
              ))}
            </SettingsList>
          )}
        </SettingsSection>
      )}
    </div>
  );
}

/* —— 实例行：名称 + 状态 + 连接信息，行尾编辑 + ⋯ 菜单 —— */

function ProviderRow({
  config,
  preset,
  busy,
  onEdit,
  onReverify,
  onDelete,
}: {
  config: LlmProviderConfig;
  preset: LlmPreset | undefined;
  busy: boolean;
  onEdit: () => void;
  onReverify: () => void;
  onDelete: () => void;
}) {
  const t = useTranslations();
  const locale = useLocale() as AppLocale;
  const summary = [
    preset?.display_name ?? config.provider_type,
    config.chatgpt_account,
    // 自定义端点的目录是用户补录的，条数比测试模型更有信息量
    config.extra_models.length > 0 ? t("settings.llm.ui.customCount", {count: config.extra_models.length}) : null,
    t("settings.llm.ui.lastChecked", {time: formatRelativeTime(config.last_checked_at, locale)}),
  ]
    .filter(Boolean)
    .join(" · ");
  // 端点与连接测试模型一眼可核对；UA 仅在用户覆盖过时展示——没配的用户不需要知道有这回事
  const connection = [
    config.base_url ?? preset?.base_url ?? t("settings.llm.ui.officialDefault"),
    t("settings.llm.ui.testModelSummary", {model: config.default_model}),
    config.user_agent ? `UA ${config.user_agent}` : null,
    config.api_protocol ? t(PROTOCOL_LABELS[config.api_protocol]) : null,
  ]
    .filter(Boolean)
    .join(" · ");

  return (
    <SettingsRow
      stackOnMobile={locale === "en"}
      leading={
        <span className="icon-chip size-9 !rounded-xl">
          <SparkIcon className="size-[18px]" />
        </span>
      }
      label={
        <span className="flex flex-wrap items-center gap-2">
          <span className="min-w-0 truncate">{config.name}</span>
          <StatusPill status={config.status} />
        </span>
      }
      description={
        <>
          <span className="block break-all">{connection}</span>
          {/* 连接失败的原因可能是整段上游报错：最多三行，完整内容悬停可见 */}
          <span
            title={config.status === "failed" ? (config.last_error ?? undefined) : undefined}
            className={`block ${
              config.status === "failed" && config.last_error
                ? "line-clamp-3 break-words text-[var(--danger)]"
                : ""
            }`}
          >
            {config.status === "failed" && config.last_error ? config.last_error : summary}
          </span>
        </>
      }
    >
      <button type="button" disabled={busy} onClick={onEdit} className={SETTINGS_BUTTON_CLASS}>
        {t("settings.llm.ui.edit")}</button>
      <SettingsMoreMenu
        label={t("settings.llm.ui.more", {name: config.name})}
        disabled={busy}
        items={[
          {
            label: t("settings.llm.ui.retest"),
            onSelect: onReverify,
            disabled: IN_PROGRESS.includes(config.status),
          },
          { label: t("settings.llm.ui.deleteMore"), onSelect: onDelete, danger: true },
        ]}
      />
    </SettingsRow>
  );
}

function StatusPill({ status }: { status: LlmProviderStatus }) {
  const t = useTranslations();
  const meta = STATUS_META[status];
  return (
    <span
      className="flex shrink-0 items-center gap-1.5 rounded-full px-2 py-0.5 text-caption font-medium"
      style={{ background: `color-mix(in oklab, ${meta.color} 12%, transparent)`, color: meta.color }}
    >
      <span className="size-1.5 rounded-full" style={{ background: meta.color }} />
      {t(meta.label)}
    </span>
  );
}

/* —— 配置表单：实例名 + 类型 + 端点 + Key（+ 自定义端点的模型目录），新增与编辑共用 —— */

interface LlmProviderFormProps {
  /** 被编辑的实例；null 表示新增 */
  config: LlmProviderConfig | null;
  presets: LlmPreset[];
  /** 其它实例已占用的实例名（实例名全局唯一） */
  takenNames: string[];
  onSubmit: (payload: LlmProviderPayload) => Promise<void>;
  onCancel: () => void;
  onError: (message: Message) => void;
}

/** 「添加模型」下拉框里「自定义模型」选项的哨兵值（不会与真实模型 id 冲突）。 */
const NEW_MODEL = "__new__";

/** 禁用浏览器自动填充/纠错的属性组，本分区所有输入框统一挂上。

    data-* 是各家密码管理器（1Password / LastPass / Bitwarden）的忽略标记；
    API Key 框另有专门处理：用 text + CSS 圆点遮罩代替 type=password，
    从根上避免浏览器把它识别成登录密码框（保存/填充弹窗的来源）。 */
const NO_AUTOFILL = {
  autoComplete: "off",
  autoCorrect: "off",
  autoCapitalize: "off",
  spellCheck: false,
  "data-1p-ignore": "true",
  "data-lpignore": "true",
  "data-bwignore": "true",
  "data-form-type": "other",
} as const;

/** 新增模型参数子表单的输入状态（数字字段以字符串暂存，提交时转换）。 */
interface NewModelDraft {
  id: string;
  contextWindow: string;
  maxInput: string;
  maxOutput: string;
  thinkingBudget: string;
  supportsTools: boolean;
  parallel: boolean;
  thinking: boolean;
  vision: boolean;
  video: boolean;
  /** 思考控制方言：none = 不声明 thinking_control，与输出思考内容独立 */
  thinkingKind: "none" | "effort" | "budget" | "toggle";
  /** effort 制的原生档位子集（多选） */
  thinkingLevels: string[];
  /** 是否有真关闭协议（菜单出现「关」）；toggle 制隐含为真 */
  supportsOff: boolean;
}

const EMPTY_DRAFT: NewModelDraft = {
  id: "",
  contextWindow: "",
  maxInput: "",
  maxOutput: "",
  thinkingBudget: "",
  supportsTools: true,
  parallel: false,
  thinking: false,
  vision: false,
  video: false,
  thinkingKind: "none",
  thinkingLevels: [],
  supportsOff: false,
};

/** effort 制可声明的档位（词汇表排除 off——关闭走「支持关闭」勾选）。 */
const DECLARABLE_THINKING_LEVELS = ["minimal", "low", "medium", "high", "xhigh", "max"] as const;

const THINKING_LEVEL_LABEL: Record<string, AppMessageKey> = {
  minimal: "settings.llm.ui.minimal",
  low: "settings.llm.ui.low",
  medium: "settings.llm.ui.medium",
  high: "settings.llm.ui.high",
  xhigh: "settings.llm.ui.xhigh",
  max: "settings.llm.ui.max",
};

function LlmProviderForm({
  config,
  presets,
  takenNames,
  onSubmit,
  onCancel,
  onError,
}: LlmProviderFormProps) {
  const t = useTranslations();
  const locale = useLocale() as AppLocale;
  const [busy, setBusy] = useState(false);
  const [discovering, setDiscovering] = useState(false);
  const [discoveredModels, setDiscoveredModels] = useState<string[] | null>(null);
  const [defaultModel, setDefaultModel] = useState(config?.default_model ?? "");
  // 实例名：留空时按所选供应商的显示名保存（多数人只接一家，不必额外起名）
  const [name, setName] = useState(config?.name ?? "");
  const [providerType, setProviderType] = useState<LlmProviderType>(
    config?.provider_type ?? "bailian",
  );
  const [baseUrl, setBaseUrl] = useState(config?.base_url ?? "");
  const [userAgent, setUserAgent] = useState(config?.user_agent ?? "");
  // 空串 = 跟随预设默认协议（不落库，预设升级默认协议时自动跟上）
  const [apiProtocol, setApiProtocol] = useState<LlmApiProtocol | "">(
    config?.api_protocol ?? "",
  );
  const [advancedOpen, setAdvancedOpen] = useState(
    Boolean(config?.user_agent || config?.api_protocol),
  );
  // 出于安全后端不回传 Key；编辑时留空沿用原 Key
  const [apiKey, setApiKey] = useState("");
  const [showApiKey, setShowApiKey] = useState(false);
  // 自定义模型目录：兼容端点定义可用模型，OpenAI 可补录预设外模型
  const [extraModels, setExtraModels] = useState<LlmModelInfo[]>(config?.extra_models ?? []);
  // 「自定义模型」参数子表单：只在用户选择添加自定义模型时展开
  const [addingCustom, setAddingCustom] = useState(false);
  const [draft, setDraft] = useState<NewModelDraft>(EMPTY_DRAFT);

  const preset = presets.find((p) => p.id === providerType);
  const effectiveProtocol = apiProtocol || preset?.protocol;
  const supportsProtocol = (m: LlmModelInfo) =>
    effectiveProtocol !== "openai_chat" || !m.requires_responses_for_tools;
  const catalog = (preset?.models ?? []).filter(supportsProtocol);
  const isCustomEndpoint = (preset?.models.length ?? 0) === 0;
  const canAddModels = isCustomEndpoint || providerType === "openai";
  const extras = canAddModels ? extraModels : [];
  const testModels = [
    ...new Map([...catalog, ...extras.filter(supportsProtocol)].map((m) => [m.id, m])).values(),
  ];
  const testModel = testModels.some((m) => m.id === defaultModel)
    ? defaultModel
    : testModels[0]?.id ?? "";
  // 无内置目录的端点（openai_compat）：把其它预设目录的模型也纳入可添加——
  // 换端点（代理/自建网关）时模型名与参数往往一致，没必要让用户重填一遍。
  // 借用即把参数复制进本配置的自定义目录。
  const borrowedGroups = isCustomEndpoint
    ? presets
        .filter((p) => p.id !== providerType && p.models.length > 0)
        .map((p) => ({
          id: p.id,
          label: p.display_name,
          models: p.models.filter((m) => supportsProtocol(m) && !extras.some((e) => e.id === m.id)),
        }))
        .filter((g) => g.models.length > 0)
    : [];
  const borrowedModels = borrowedGroups.flatMap((g) => g.models.map((model) => ({
    value: JSON.stringify([g.id, model.id]),
    model,
  })));

  const needBaseUrl = preset?.requires_base_url ?? false;
  // 编辑时 Key 可留空沿用；但类型或端点变了必须重填（与后端同一判据），
  // 免得旧 Key 被发往新地址
  const apiKeyRequired =
    !config ||
    providerType !== config.provider_type ||
    (baseUrl.trim().replace(/\/+$/, "") || null) !== (config.base_url ?? null);
  // OpenAI 可配中转地址；兼容端点自填地址；其它官方固定渠道不展示输入
  const canCustomizeEndpoint = providerType === "openai" || !preset?.base_url;
  // 协议可切换的预设（OpenAI / 通用兼容端点）才展示协议选择
  const protocolOptions = preset?.selectable_protocols ?? [];
  const canChooseProtocol = protocolOptions.length > 1;
  // 新增模型的必填校验：id / 上下文 / 最大输出；预算分段须声明预算上限；
  // 档位直传制至少声明一档（空声明 = 没有菜单，等于没声明）
  const draftValid =
    draft.id.trim().length > 0 &&
    Number(draft.contextWindow) > 0 &&
    Number(draft.maxOutput) > 0 &&
    (draft.thinkingKind !== "budget" || Number(draft.thinkingBudget) > 0) &&
    (draft.thinkingKind !== "effort" || draft.thinkingLevels.length > 0);
  const baseUrlValid =
    baseUrl.trim() === "" ? !needBaseUrl : /^https?:\/\/.+/.test(baseUrl.trim());
  // 请求头值只能是可打印 ASCII（与后端校验同一判据），空即用 SDK 默认
  const userAgentValid = userAgent.trim() === "" || /^[\x20-\x7e]+$/.test(userAgent.trim());
  const draftHint: AppMessageKey =
    draft.thinkingKind === "effort" && draft.thinkingLevels.length === 0
      ? "settings.llm.ui.effortRequired"
      : "settings.llm.ui.draftRequired";
  const submitHint: AppMessageKey | null =
    name.includes("/")
      ? "settings.llm.ui.nameInvalid"
      : apiKeyRequired && apiKey.trim().length === 0
      ? config
        ? "settings.llm.ui.keyChanged"
        : "settings.llm.ui.keyRequired"
      : !baseUrlValid
        ? "settings.llm.ui.endpointInvalid"
        : !testModel
          ? "settings.llm.ui.modelRequired"
          : !userAgentValid
            ? "settings.llm.ui.uaInvalid"
            : null;
  const canSubmit = submitHint == null;

  async function discoverModels() {
    onError("");
    setDiscovering(true);
    setDiscoveredModels(null);
    try {
      const models = await discoverLlmModels({
        name: name.trim() || fallbackName(),
        provider_id: config?.id,
        provider_type: providerType,
        base_url: baseUrl.trim() || null,
        api_key: apiKey.trim() || null,
        user_agent: (canCustomizeEndpoint && userAgent.trim()) || null,
      });
      setDiscoveredModels(models);
    } catch (error) {
      onError((error as Error).message);
    } finally {
      setDiscovering(false);
    }
  }

  function addDiscoveredModel(id: string) {
    const configured = testModels.find((m) => m.id === id);
    if (configured) {
      setDefaultModel(id);
      return;
    }
    const candidates = presets.flatMap((p) => p.models.filter((m) => m.id === id));
    if (candidates.length > 1 && isCustomEndpoint) {
      onError({key: "settings.llm.ui.ambiguousModel", values: {model: id}});
      return;
    }
    const known = candidates[0];
    if (known) {
      if (!supportsProtocol(known)) {
        onError({key: "settings.llm.ui.responsesRequired"});
        return;
      }
      if (canAddModels) {
        setExtraModels([...extraModels.filter((m) => m.id !== id), known]);
        setDefaultModel(id);
      }
    } else if (canAddModels) {
      setDraft({ ...EMPTY_DRAFT, id });
      setAddingCustom(true);
    }
  }

  /** 「添加模型」下拉框：借用其它目录的模型直接入列；自定义则展开参数子表单。 */
  function addFromPicker(value: string) {
    if (!value) return;
    if (value === NEW_MODEL) {
      setAddingCustom(true);
      return;
    }
    const borrowed = borrowedModels.find((m) => m.value === value)?.model;
    if (borrowed && !extraModels.some((m) => m.id === borrowed.id)) {
      setExtraModels([...extraModels, borrowed]);
    }
  }

  /** 把参数子表单里的自定义模型加进目录（同 id 覆盖旧条目：改参数重存是常见操作）。 */
  function addCustomModel() {
      const custom: LlmModelInfo = {
        id: draft.id.trim(),
        context_window: Number(draft.contextWindow),
        max_input_tokens: draft.maxInput ? Number(draft.maxInput) : null,
        max_output_tokens: Number(draft.maxOutput),
        supports_tools: draft.supportsTools,
        supports_parallel_tool_calls: draft.parallel,
        supports_thinking: draft.thinking,
        max_thinking_tokens: draft.thinkingBudget ? Number(draft.thinkingBudget) : null,
        thinking_control:
          draft.thinkingKind === "none"
            ? null
            : {
                kind: draft.thinkingKind,
                levels: draft.thinkingKind === "effort" ? draft.thinkingLevels : [],
                // toggle 的意义就是可关，隐含 supports_off；其余按勾选
                supports_off: draft.thinkingKind === "toggle" ? true : draft.supportsOff,
              },
        modalities: [
          "text",
          ...(draft.vision ? ["image"] : []),
          ...(draft.video ? ["video"] : []),
        ],
      };
      setExtraModels([...extraModels.filter((m) => m.id !== custom.id), custom]);
      setDraft(EMPTY_DRAFT);
      setAddingCustom(false);
  }

  /** 留空时按供应商显示名保存；同类型第二家会撞唯一实例名，自动加序号（「OpenAI 2」）。 */
  function fallbackName(): string {
    const base = preset?.display_name || providerType;
    let candidate = base;
    for (let i = 2; takenNames.includes(candidate); i += 1) candidate = `${base} ${i}`;
    return candidate;
  }

  function submit() {
    setBusy(true);
    void onSubmit({
      name: name.trim() || fallbackName(),
      provider_type: providerType,
      base_url: baseUrl.trim() || null,
      // 端点固定的官方渠道不开放 UA 配置，一律回传 null，避免切换供应商后
      // 残留上一个自定义端点的 UA
      user_agent: (canCustomizeEndpoint && userAgent.trim()) || null,
      api_protocol: (canChooseProtocol && apiProtocol) || null,
      api_key: apiKey.trim() || null,
      default_model: testModel || null,
      extra_models: extras,
    })
      .catch((e) => onError((e as Error).message))
      .finally(() => setBusy(false));
  }

  // 移动端 16px 字号：iOS 小于 16px 的输入框聚焦会整页放大
  const inputClass = `${SETTINGS_INPUT_CLASS} w-full max-sm:text-[16px]`;
  const labelClass = "mb-1.5 block text-sub font-medium text-[var(--text-muted)]";

  if (providerType === "chatgpt") {
    return <ChatGPTPlanConnect config={config?.provider_type === "chatgpt" ? config : null}
      presets={presets} onSelect={setProviderType} onDone={onCancel} />;
  }

  return (
    <fieldset disabled={busy || discovering} className="min-w-0 space-y-6">
      {/* 供应商会持续增加，使用原生下拉框控制首屏长度；移动端同时获得系统选择器。 */}
      <div className="min-w-0 space-y-3">
        <label htmlFor="llm-provider" className={labelClass}>
          {t("settings.llm.ui.provider")}</label>
        <select
          id="llm-provider"
          value={providerType}
          disabled={presets.length === 0}
          aria-describedby={preset ? "llm-provider-hint" : undefined}
          aria-busy={presets.length === 0}
          onChange={(event) => {
            const nextProvider = event.target.value as LlmProviderType;
            if (providerType === nextProvider) return;
            setProviderType(nextProvider);
            setBaseUrl("");
            setUserAgent("");
            setApiProtocol("");
            setAdvancedOpen(false);
            setAddingCustom(false);
            setDiscoveredModels(null);
            setDefaultModel("");
          }}
          className={`${inputClass} cursor-pointer disabled:cursor-wait disabled:opacity-50`}
        >
          {presets.length === 0 && <option value={providerType}>{t("settings.llm.ui.loadingProviders")}</option>}
          {presets.map((item) => (
            <option key={item.id} value={item.id}>
              {item.display_name}
            </option>
          ))}
        </select>
        {preset && (
          <div
            id="llm-provider-hint"
            className="rounded-xl border border-white/[0.06] bg-white/[0.025] px-3.5 py-3"
          >
            <p className="text-ui font-semibold text-[var(--text)]">{preset.display_name}</p>
            <p className="mt-0.5 text-caption leading-relaxed text-[var(--text-faint)]">
              {providerHint(preset, locale)}
            </p>
          </div>
        )}
      </div>

      <div className="min-w-0 space-y-4 border-t border-white/[0.07] pt-6">
        <div>
          <label className={labelClass}>{t("settings.llm.ui.name")}</label>
          <input
            type="text"
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder={preset?.display_name ?? t("settings.llm.ui.namePlaceholder")}
            className={inputClass}
            {...NO_AUTOFILL}
          />
          <p className="mt-1.5 text-caption leading-relaxed text-[var(--text-faint)]">
            {t("settings.llm.ui.nameHint")}</p>
        </div>

        {/* 端点固定的官方渠道（百炼/DeepSeek/Kimi/GLM）不展示端点输入；
            OpenAI 保留可选输入（代理/镜像场景），通用兼容端点必填。 */}
        {canCustomizeEndpoint && (
          <div>
            <label className={labelClass}>
              {t("settings.llm.ui.endpoint")}{needBaseUrl ? " *" : t("settings.llm.ui.optional")}
            </label>
            <input
              type="text"
              value={baseUrl}
              onChange={(e) => {
                setBaseUrl(e.target.value);
                setDiscoveredModels(null);
              }}
              placeholder={needBaseUrl ? "http://192.168.1.5:8000/v1" : "https://api.openai.com/v1"}
              className={inputClass}
              {...NO_AUTOFILL}
            />
            {!needBaseUrl && (
              <p className="mt-1.5 text-caption leading-relaxed text-[var(--text-faint)]">
                {t("settings.llm.ui.endpointHint")}</p>
            )}
          </div>
        )}

        <div>
          <label className={labelClass}>API Key{apiKeyRequired ? " *" : ""}</label>
          {/* text + CSS 圆点遮罩：视觉等同密码框，但浏览器不识别为密码，
              不会触发「保存密码 / 自动填充」弹窗。 */}
          <div className="relative">
            <input
              type="text"
              value={apiKey}
              onChange={(e) => {
                setApiKey(e.target.value);
                setDiscoveredModels(null);
              }}
              placeholder={apiKeyRequired ? "sk-…" : t("settings.llm.ui.keepKey")}
              className={`${inputClass} pr-16 ${
                showApiKey ? "" : "[-webkit-text-security:disc]"
              }`}
              {...NO_AUTOFILL}
            />
            <button
              type="button"
              onClick={() => setShowApiKey((value) => !value)}
              className="absolute inset-y-1 right-1 rounded-lg px-3 text-sub font-medium text-[var(--text-muted)] transition-colors hover:bg-white/[0.06] hover:text-[var(--text)]"
              aria-label={showApiKey ? t("settings.llm.ui.hideKey") : t("settings.llm.ui.showKey")}
            >
              {showApiKey ? t("settings.llm.ui.hide") : t("settings.llm.ui.show")}
            </button>
          </div>
          {config && (
            <p className="mt-1.5 text-caption leading-relaxed text-[var(--text-faint)]">
              {apiKeyRequired
                ? t("settings.llm.ui.keyChangedHint")
                : t("settings.llm.ui.keyPrivacy")}
            </p>
          )}
        </div>

        {/* API 协议与 User-Agent 都是低频字段，默认折叠以缩短主流程。 */}
        {canCustomizeEndpoint && (
          <details
            className="group rounded-xl border border-white/[0.07] bg-white/[0.025]"
            open={advancedOpen}
            onToggle={(event) => setAdvancedOpen(event.currentTarget.open)}
          >
            <summary className="flex min-h-11 cursor-pointer list-none items-center justify-between gap-3 px-3.5 py-2 text-sub font-medium text-[var(--text-muted)] [&::-webkit-details-marker]:hidden">
              {t("settings.llm.ui.advanced")}<span className="text-caption font-normal text-[var(--text-faint)] group-open:hidden">
                {canChooseProtocol ? t("settings.llm.ui.advancedSummary") : "User-Agent"}
              </span>
              <span className="hidden text-caption font-normal text-[var(--text-faint)] group-open:inline">
                {t("settings.llm.ui.collapse")}</span>
            </summary>
            <div className="space-y-4 border-t border-white/[0.06] px-3.5 pb-3.5 pt-3">
              {canChooseProtocol && (
                <div>
                  <label htmlFor="llm-api-protocol" className={labelClass}>
                    {t("settings.llm.ui.protocol")}</label>
                  <select
                    id="llm-api-protocol"
                    value={apiProtocol || preset?.protocol || protocolOptions[0]}
                    onChange={(e) => setApiProtocol(e.target.value as LlmApiProtocol)}
                    className={`${inputClass} cursor-pointer`}
                  >
                    {protocolOptions.map((id) => (
                      <option key={id} value={id}>
                        {t(PROTOCOL_LABELS[id])}
                        {id === preset?.protocol ? t("settings.llm.ui.defaultSuffix") : ""}
                      </option>
                    ))}
                  </select>
                  <p className="mt-1.5 text-caption leading-relaxed text-[var(--text-faint)]">
                    {t("settings.llm.ui.protocolHint")}</p>
                </div>
              )}
              <div>
                <label className={labelClass}>{t("settings.llm.ui.userAgent")}</label>
                <input
                  type="text"
                  value={userAgent}
                  onChange={(e) => setUserAgent(e.target.value)}
                  // 占位符直接展示留空时实际发送的 SDK 自带 UA（后端按 SDK 版本现算）。
                  placeholder={preset?.default_user_agent ?? t("settings.llm.ui.uaPlaceholder")}
                  className={inputClass}
                  {...NO_AUTOFILL}
                />
                <p
                  className={`mt-1.5 text-caption leading-relaxed ${
                    userAgentValid ? "text-[var(--text-faint)]" : "text-[#ff6b6b]"
                  }`}
                >
                  {userAgentValid
                    ? t("settings.llm.ui.uaHint")
                    : t("settings.llm.ui.uaAscii")}
                </p>
              </div>
            </div>
          </details>
        )}
      </div>

      <div className="min-w-0 space-y-4 border-t border-white/[0.07] pt-6">
        <div>
          <button
            type="button"
            onClick={() => void discoverModels()}
            disabled={discovering || !baseUrlValid || !userAgentValid || (apiKeyRequired && !apiKey.trim())}
            className={SETTINGS_BUTTON_CLASS}
          >
            {discovering ? t("settings.llm.ui.discovering") : t("settings.llm.ui.discover")}
          </button>
          <p className="mt-1.5 text-caption leading-relaxed text-[var(--text-faint)]">
            {t("settings.llm.ui.discoverHint")}</p>
          {discoveredModels !== null && (
            <>
              <p role="status" className="mt-2 text-caption text-[var(--text-muted)]">
                {t("settings.llm.ui.discovered", {count: discoveredModels.length})}
              </p>
              {discoveredModels.length > 0 && (
                <select
                  aria-label={t("settings.llm.ui.discoveredLabel")}
                  value=""
                  onChange={(e) => addDiscoveredModel(e.target.value)}
                  className={`${inputClass} mt-2`}
                >
                  <option value="">{t("settings.llm.ui.discoveredPlaceholder")}</option>
                  {discoveredModels.map((id) => (
                    <option
                      key={id}
                      value={id}
                      disabled={!canAddModels && !testModels.some((m) => m.id === id)}
                    >
                      {id}
                    </option>
                  ))}
                </select>
              )}
            </>
          )}
        </div>
        {catalog.length > 0 && (
          <p className="text-caption leading-relaxed text-[var(--text-faint)]">
            {t("settings.llm.ui.catalog", {provider: preset?.display_name ?? "", count: catalog.length})}
          </p>
        )}
        {canAddModels && (
          <div>
            <label className={labelClass}>{t("settings.llm.ui.extraModels")}{isCustomEndpoint ? " *" : t("settings.llm.ui.optional")}</label>
            <p className="mb-2 text-caption leading-relaxed text-[var(--text-faint)]">
              {isCustomEndpoint ? t("settings.llm.ui.customHint") : t("settings.llm.ui.extraHint")}
              {t("settings.llm.ui.extraUsage")}</p>
            {extras.length > 0 && (
              <ul className="mb-2 divide-y divide-white/[0.06] rounded-xl border border-white/[0.08] bg-white/[0.03]">
                {extras.map((m) => (
                  <li key={m.id} className="flex items-center gap-3 px-3.5 py-2.5">
                    <div className="min-w-0 flex-1">
                      <p className="truncate text-ui font-medium text-[var(--text)]">{m.id}</p>
                      <p className="truncate text-caption text-[var(--text-faint)]">
                        {[modelSpecs(m, locale), modelHints(m, locale)].filter(Boolean).join(" · ") ||
                          t("settings.llm.ui.specsFallback")}
                      </p>
                    </div>
                    <button
                      type="button"
                      onClick={() => setExtraModels(extraModels.filter((x) => x.id !== m.id))}
                      className="rounded-lg px-2 py-1 text-caption text-[var(--text-muted)] transition-colors hover:bg-white/[0.06] hover:text-[#ff7d7d]"
                    >
                      {t("settings.llm.ui.remove")}</button>
                  </li>
                ))}
              </ul>
            )}
            <select
              aria-label={t("settings.llm.ui.addModel")}
              value=""
              onChange={(e) => addFromPicker(e.target.value)}
              className={`${inputClass} appearance-none`}
            >
              <option value="">{t("settings.llm.ui.addModelOption")}</option>
              {/* 其它预设目录的模型：选中即入列，参数复用 */}
              {borrowedGroups.map((g) => (
                <optgroup key={g.label} label={t("settings.llm.ui.borrowedCatalog", {provider: g.label})}>
                  {g.models.map((m) => (
                    <option key={m.id} value={JSON.stringify([g.id, m.id])}>
                      {m.id}
                      {modelHints(m, locale) ? t("settings.llm.ui.hintsSuffix", {hints: modelHints(m, locale)}) : ""}
                    </option>
                  ))}
                </optgroup>
              ))}
              <option value={NEW_MODEL}>{t("settings.llm.ui.customModelOption")}</option>
            </select>
          </div>
        )}

        {testModels.length > 0 && (
          <div>
            <label htmlFor="llm-test-model" className={labelClass}>
              {t("settings.llm.ui.testModel")}</label>
            <select
              id="llm-test-model"
              value={testModel}
              onChange={(e) => setDefaultModel(e.target.value)}
              className={inputClass}
            >
              {testModels.map((m) => (
                <option key={m.id} value={m.id}>
                  {m.id} · {modelSpecs(m, locale)}{modelHints(m, locale) ? ` · ${modelHints(m, locale)}` : ""}
                </option>
              ))}
            </select>
            <p className="mt-1.5 text-caption leading-relaxed text-[var(--text-faint)]">
              {t("settings.llm.ui.testModelHint")}</p>
          </div>
        )}

        {/* 自定义模型的参数子表单：这些参数是 agent 做上下文/思考预算决策的依据，必填 */}
        {canAddModels && addingCustom && (
          <div className="space-y-3.5 rounded-xl border border-white/[0.08] bg-white/[0.03] p-3.5 max-sm:p-3">
            <p className="text-sub font-medium text-[var(--text-muted)]">
              {t("settings.llm.ui.customParameters")}<span className="mt-1 block font-normal leading-relaxed text-[var(--text-faint)]">
                {t("settings.llm.ui.customParametersHint")}</span>
            </p>
            <div>
              <label className={labelClass}>{t("settings.llm.ui.modelId")}</label>
              <input
                type="text"
                value={draft.id}
                onChange={(e) => setDraft({ ...draft, id: e.target.value })}
                placeholder={t("settings.llm.ui.modelPlaceholder")}
                className={inputClass}
                {...NO_AUTOFILL}
              />
            </div>
            <div className="grid grid-cols-3 gap-3 max-md:grid-cols-1">
              <div>
                <label className={labelClass}>{t("settings.llm.ui.contextWindow")}</label>
                <input
                  type="number"
                  min={1}
                  value={draft.contextWindow}
                  onChange={(e) => setDraft({ ...draft, contextWindow: e.target.value })}
                  placeholder="131072"
                  className={inputClass}
                  {...NO_AUTOFILL}
                />
              </div>
              <div>
                <label className={labelClass}>{t("settings.llm.ui.maxOutput")}</label>
                <input
                  type="number"
                  min={1}
                  value={draft.maxOutput}
                  onChange={(e) => setDraft({ ...draft, maxOutput: e.target.value })}
                  placeholder="8192"
                  className={inputClass}
                  {...NO_AUTOFILL}
                />
              </div>
              <div>
                <label className={labelClass}>{t("settings.llm.ui.maxInput")}</label>
                <input
                  type="number"
                  min={1}
                  value={draft.maxInput}
                  onChange={(e) => setDraft({ ...draft, maxInput: e.target.value })}
                  placeholder={t("settings.llm.ui.inputPlaceholder")}
                  className={inputClass}
                  {...NO_AUTOFILL}
                />
              </div>
            </div>
            <div className="flex flex-wrap gap-x-5 gap-y-2">
              <CheckField
                label={t("settings.llm.ui.tools")}
                checked={draft.supportsTools}
                onChange={(v) =>
                  setDraft({ ...draft, supportsTools: v, parallel: v && draft.parallel })
                }
              />
              <CheckField
                label={t("settings.llm.ui.parallelTools")}
                checked={draft.parallel}
                disabled={!draft.supportsTools}
                onChange={(v) => setDraft({ ...draft, parallel: v })}
              />
              <CheckField
                label={t("settings.llm.ui.thinkingOutput")}
                checked={draft.thinking}
                onChange={(v) => setDraft({ ...draft, thinking: v })}
              />
              <CheckField
                label={t("settings.llm.ui.imageInput")}
                checked={draft.vision}
                onChange={(v) => setDraft({ ...draft, vision: v })}
              />
              <CheckField
                label={t("settings.llm.ui.videoInput")}
                checked={draft.video}
                onChange={(v) => setDraft({ ...draft, video: v })}
              />
            </div>
            {(draft.thinking || draft.thinkingKind === "budget") && (
              <div>
                <label className={labelClass}>{t("settings.llm.ui.thinkingBudget")}{draft.thinkingKind === "budget" ? " *" : t("settings.llm.ui.optional")}</label>
                <input
                  type="number"
                  min={1}
                  value={draft.thinkingBudget}
                  onChange={(e) => setDraft({ ...draft, thinkingBudget: e.target.value })}
                  placeholder={t("settings.llm.ui.budgetPlaceholder")}
                  className={inputClass}
                  {...NO_AUTOFILL}
                />
                <p className="mt-1.5 text-caption leading-relaxed text-[var(--text-faint)]">
                  {t("settings.llm.ui.budgetHint")}</p>
              </div>
            )}
            <div>
              <label className={labelClass}>{t("settings.llm.ui.thinkingControl")}</label>
              <select
                value={draft.thinkingKind}
                onChange={(e) =>
                  setDraft({
                    ...draft,
                    thinkingKind: e.target.value as NewModelDraft["thinkingKind"],
                  })
                }
                className={inputClass}
              >
                <option value="none">{t("settings.llm.ui.noControl")}</option>
                <option value="effort">{t("settings.llm.ui.effortControl")}</option>
                <option value="budget">{t("settings.llm.ui.budgetControl")}</option>
                <option value="toggle">{t("settings.llm.ui.toggleControl")}</option>
              </select>
              <p className="mt-1.5 text-caption leading-relaxed text-[var(--text-faint)]">
                {t("settings.llm.ui.controlHint")}</p>
              {draft.thinkingKind === "effort" && (
                <div className="mt-3 flex flex-wrap gap-x-5 gap-y-2">
                  {DECLARABLE_THINKING_LEVELS.map((level) => (
                    <CheckField
                      key={level}
                      label={t(THINKING_LEVEL_LABEL[level])}
                      checked={draft.thinkingLevels.includes(level)}
                      onChange={(v) =>
                        setDraft({
                          ...draft,
                          // 固定词汇表顺序归一，声明不是有序集合
                          thinkingLevels: DECLARABLE_THINKING_LEVELS.filter(
                            (l) => (l === level ? v : draft.thinkingLevels.includes(l)),
                          ),
                        })
                      }
                    />
                  ))}
                </div>
              )}
              {(draft.thinkingKind === "effort" || draft.thinkingKind === "budget") && (
                <div className="mt-3">
                  <CheckField
                    label={t("settings.llm.ui.supportsOff")}
                    checked={draft.supportsOff}
                    onChange={(v) => setDraft({ ...draft, supportsOff: v })}
                  />
                  <p className="mt-1 text-caption leading-relaxed text-[var(--text-faint)]">
                    {t("settings.llm.ui.offHint")}</p>
                </div>
              )}
            </div>
            {!draftValid && (
              <p className="text-caption leading-relaxed text-[var(--text-faint)]">{t(draftHint)}</p>
            )}
            <div className="flex items-center gap-2">
              <button
                type="button"
                onClick={addCustomModel}
                disabled={!draftValid}
                className={SETTINGS_BUTTON_CLASS}
              >
                {t("settings.llm.ui.addToCatalog")}</button>
              <button
                type="button"
                onClick={() => {
                  setDraft(EMPTY_DRAFT);
                  setAddingCustom(false);
                }}
                className={SETTINGS_BUTTON_CLASS}
              >
                {t("settings.llm.ui.cancel")}</button>
            </div>
          </div>
        )}
      </div>

      {submitHint && (
        <p role="status" className="text-caption leading-relaxed text-[var(--text-faint)]">
          {t(submitHint)}
        </p>
      )}

      {/* solid-card：移动端 sticky 保存条挂卡片材质钩子（描边/实底/关 blur，
          银玻璃零变化）；sm: 起回透明档的工具类原样保留 */}
      <div className="solid-card sticky bottom-0 z-10 -mx-4 -mb-4 flex items-center gap-3 border-t border-white/[0.08] bg-[rgba(17,20,27,0.94)] px-4 py-3 backdrop-blur-xl sm:static sm:mx-0 sm:mb-0 sm:justify-end sm:border-0 sm:bg-transparent sm:p-0 sm:pt-1 sm:backdrop-blur-none">
        <button
          type="button"
          onClick={onCancel}
          className={`${SETTINGS_BUTTON_CLASS} max-sm:flex-1`}
        >
          {t("settings.llm.ui.cancel")}</button>
        <button
          type="button"
          onClick={submit}
          disabled={busy || !canSubmit}
          className={`${SETTINGS_PRIMARY_BUTTON_CLASS} max-sm:flex-[1.6]`}
        >
          {busy ? t("settings.llm.ui.saving") : t("settings.llm.ui.save")}
        </button>
      </div>
    </fieldset>
  );
}

/** 供应商卡片的副标题：固定端点显示域名，其余说明接入方式。 */
const PROTOCOL_LABELS: Record<LlmApiProtocol, AppMessageKey> = {
  openai_chatgpt: "settings.llm.ui.chatgptSubscription",
  openai_chat: "settings.llm.ui.chatCompletions",
  openai_responses: "settings.llm.ui.responsesApi",
};

function providerHint(preset: LlmPreset, locale: AppLocale): string {
  const t = appTranslator(locale);
  if (preset.id === "bailian") return t("settings.llm.ui.bailianHint");
  if (preset.id === "openai") return t("settings.llm.ui.openaiHint");
  if (preset.requires_base_url) return t("settings.llm.ui.compatHint");
  if (preset.base_url) {
    try {
      return new URL(preset.base_url).host;
    } catch {
      return preset.base_url;
    }
  }
  return t("settings.llm.ui.officialEndpoint");
}

/** 参数子表单里的复选项：文字标签 + 原生 checkbox。 */
function CheckField({
  label,
  checked,
  onChange,
  disabled,
}: {
  label: string;
  checked: boolean;
  onChange: (v: boolean) => void;
  disabled?: boolean;
}) {
  return (
    <label
      className={`flex cursor-pointer items-center gap-1.5 text-sub text-[var(--text-muted)] ${
        disabled ? "cursor-not-allowed opacity-40" : ""
      }`}
    >
      <input
        type="checkbox"
        checked={checked}
        disabled={disabled}
        onChange={(e) => onChange(e.target.checked)}
        className="size-3.5 accent-[var(--accent)]"
      />
      {label}
    </label>
  );
}

/** token 数 → 简短可读。2 的幂按 1024 进制（65536 → 64K，262144 → 256K），
 * 其余按十进制（1050000 → 1.05M）。 */
function formatTokens(n: number): string {
  if (n % 1024 === 0 && n < 1_000_000) return `${n / 1024}K`;
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(n % 1_000_000 === 0 ? 0 : 2)}M`;
  return `${Math.round(n / 1000)}K`;
}

/** 下拉选项后缀的能力短标（思考 / 视觉 / 视频 / 档位可控）。 */
function modelHints(model: LlmModelInfo, locale: AppLocale): string {
  const t = appTranslator(locale);
  return [
    model.supports_thinking ? t("settings.llm.ui.thinking") : null,
    (model.thinking_levels?.length ?? 0) > 0 ? t("settings.llm.ui.adjustable") : null,
    model.modalities.includes("image") ? t("settings.llm.ui.vision") : null,
    model.modalities.includes("video") ? t("settings.llm.ui.video") : null,
    model.modalities.includes("audio") ? t("settings.llm.ui.audio") : null,
  ]
    .filter(Boolean)
    .join(" · ");
}

/** 选中模型的规格说明：上下文 / 输出上限 / 思考预算 / 并发工具，未公布的字段不显示。 */
function modelSpecs(model: LlmModelInfo, locale: AppLocale): string {
  const t = appTranslator(locale);
  return [
    model.context_window ? t("settings.llm.ui.contextSpec", {tokens: formatTokens(model.context_window)}) : null,
    model.max_input_tokens ? t("settings.llm.ui.inputSpec", {tokens: formatTokens(model.max_input_tokens)}) : null,
    model.max_input_tokens_thinking
      ? t("settings.llm.ui.thinkingInputSpec", {tokens: formatTokens(model.max_input_tokens_thinking)}) : null,
    model.max_output_tokens
      ? t("settings.llm.ui.outputSpec", {tokens: formatTokens(model.max_output_tokens)})
      : model.default_output_tokens
        ? t("settings.llm.ui.defaultOutputSpec", {tokens: formatTokens(model.default_output_tokens)})
        : t("settings.llm.ui.outputUnknown"),
    model.max_thinking_tokens ? t("settings.llm.ui.budgetSpec", {tokens: formatTokens(model.max_thinking_tokens)}) : null,
    model.supports_parallel_tool_calls ? t("settings.llm.ui.parallelTools") : null,
  ]
    .filter(Boolean)
    .join(" · ");
}
