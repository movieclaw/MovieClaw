"use client";

/**
 * 「Webhook」设置分区（docs/design/webhook.md §4.3，Stripe 式管理页）。
 *
 * 布局分三层：
 *   - 总开关 + endpoint 列表：一行一个推送目标，绿/红点显示最近一次投递结果，
 *     行尾只常驻开关与「编辑」，发送测试/投递记录/删除收进 ⋯ 菜单（密钥轮换在编辑卡）；
 *   - 编辑卡（新建与编辑共用）：URL、格式、订阅事件（按事件目录分组渲染，
 *     目录随 GET 下发，后端新增领域事件时前端零改动）、出口选择；
 *   - secret 一次性展示条：新建/轮换后端仅在那一次响应里给明文，前端必须
 *     立刻展示并提示复制保存——之后任何读取都只有打码值。
 */

import { useCallback, useEffect, useRef, useState } from "react";

import { Banner, ErrorBanner, Toggle } from "@/components/cloud-push-ui";
import { CopyButton } from "@/components/copy-button";
import { useConfirm, useToast } from "@/components/feedback";
import { PlusIcon, SendIcon } from "@/components/icons";
import {
  SETTINGS_BUTTON_CLASS,
  SETTINGS_INPUT_CLASS,
  SETTINGS_PRIMARY_BUTTON_CLASS,
  SettingsCard,
  SettingsEmpty,
  SettingsList,
  SettingsMoreMenu,
  SettingsRow,
  SettingsSection,
  SettingsTabs,
} from "@/components/settings-ui";
import {
  type WebhookCatalogEntry,
  type WebhookConfigView,
  type WebhookDelivery,
  type WebhookEndpointPayload,
  type WebhookEndpointView,
  getWebhookConfig,
  listWebhookDeliveries,
  rotateWebhookSecret,
  saveWebhookConfig,
  sendWebhookTest,
} from "@/lib/api/webhook";
import { useLocale, useTranslations } from "next-intl";
import { useMessageState } from "@/lib/i18n/use-message-state";
import type { AppLocale } from "@/lib/i18n/negotiate";
import { formatRelativeTime } from "@/lib/time";

const INPUT_CLASS = `${SETTINGS_INPUT_CLASS} w-full`;

/** 视图 → 保存载荷（丢掉 secret_masked / last_delivery 等只读字段）。 */
function toPayload(ep: WebhookEndpointView): WebhookEndpointPayload {
  return {
    id: ep.id,
    name: ep.name,
    url: ep.url,
    format: ep.format,
    enabled: ep.enabled,
    events: ep.events,
    template: ep.template,
    headers: ep.headers,
    egress_scope: ep.egress_scope,
  };
}

function emptyDraft(catalog: WebhookCatalogEntry[]): WebhookEndpointPayload {
  return {
    id: "",
    name: "",
    url: "",
    format: "movieclaw",
    enabled: true,
    // 默认勾选 default_on 的事件：progress 这类高频事件按目录约定默认关闭
    events: catalog.filter((c) => c.default_on).map((c) => c.event),
    template: "",
    headers: {},
    egress_scope: "lan",
  };
}

/** headers 编辑框的双向换行文本形态："Key: Value" 每行一条。 */
function headersToText(headers: Record<string, string>): string {
  return Object.entries(headers)
    .map(([k, v]) => `${k}: ${v}`)
    .join("\n");
}

function textToHeaders(text: string): Record<string, string> {
  const headers: Record<string, string> = {};
  for (const line of text.split("\n")) {
    const idx = line.indexOf(":");
    if (idx <= 0) continue;
    const key = line.slice(0, idx).trim();
    const value = line.slice(idx + 1).trim();
    if (key) headers[key] = value;
  }
  return headers;
}

export function WebhookSection() {
  const t = useTranslations();
  const locale = useLocale();
  const loadGeneration = useRef(0);
  const confirm = useConfirm();
  const toast = useToast();
  const [config, setConfig] = useState<WebhookConfigView | null>(null);
  const [error, setError] = useMessageState();
  const [busy, setBusy] = useState(false);
  /** 编辑卡中的草稿；null = 未打开 */
  const [draft, setDraft] = useState<WebhookEndpointPayload | null>(null);
  /** 一次性 secret：{endpoint 名, 明文}；关闭即永远消失 */
  const [revealed, setRevealed] = useState<{ name: string; secret: string } | null>(null);
  /** 展开投递记录的 endpoint id 及其记录 */
  const [expanded, setExpanded] = useState<string | null>(null);
  const [records, setRecords] = useState<WebhookDelivery[]>([]);

  const load = useCallback(async () => {
    const generation = ++loadGeneration.current;
    try {
      const view = await getWebhookConfig();
      if (generation === loadGeneration.current) setConfig(view);
    } catch (e) {
      if (generation === loadGeneration.current) setError((e as Error).message);
    }
  }, [setError]);

  useEffect(() => {
    void load();
  }, [load, locale]);

  /** 全量保存：任何变更（开关/增删改）都走这一条路，响应即最新视图。 */
  async function save(next: {
    enabled: boolean;
    endpoints: WebhookEndpointPayload[];
  }): Promise<WebhookConfigView | null> {
    setBusy(true);
    setError(null);
    try {
      const view = await saveWebhookConfig(next);
      setConfig(view);
      return view;
    } catch (e) {
      setError((e as Error).message);
      return null;
    } finally {
      setBusy(false);
    }
  }

  function currentPayloads(): WebhookEndpointPayload[] {
    return (config?.endpoints ?? []).map(toPayload);
  }

  async function handleToggleGlobal(enabled: boolean) {
    if (config == null) return;
    const previous = config;
    setConfig({ ...config, enabled }); // 乐观更新
    const view = await save({ enabled, endpoints: currentPayloads() });
    if (view == null) setConfig(previous); // 保存失败回滚，避免开关停在与后端不一致的状态
  }

  async function handleToggleEndpoint(id: string, enabled: boolean) {
    if (config == null) return;
    await save({
      enabled: config.enabled,
      endpoints: currentPayloads().map((ep) => (ep.id === id ? { ...ep, enabled } : ep)),
    });
  }

  async function handleDelete(ep: WebhookEndpointView) {
    if (config == null) return;
    if (
      !(await confirm({
        title: t("settings.webhook.ui.deleteTitle", {name: ep.name || ep.url}),
        description: t("settings.webhook.ui.deleteHint"),
        confirmLabel: t("common.delete"),
        tone: "danger",
      }))
    )
      return;
    // 正在编辑的就是这一条：一并关掉编辑卡，免得再点保存把它加回来
    setDraft((d) => (d?.id === ep.id ? null : d));
    await save({
      enabled: config.enabled,
      endpoints: currentPayloads().filter((p) => p.id !== ep.id),
    });
  }

  async function handleSubmitDraft() {
    if (config == null || draft == null) return;
    if (!draft.url.trim()) {
      setError({key: "settings.webhook.ui.urlRequired"});
      return;
    }
    const rest = currentPayloads().filter((p) => p.id !== draft.id);
    const view = await save({
      enabled: config.enabled,
      endpoints: [...rest, { ...draft, url: draft.url.trim(), name: draft.name.trim() }],
    });
    if (view == null) return;
    setDraft(null);
    // 响应里带明文 secret 的两种来路都要展示：新建 movieclaw endpoint，
    // 以及既有 endpoint 从 jellyfin 切换到 movieclaw（后端补发密钥）
    const revealedEp = view.endpoints.find((ep) => ep.secret);
    if (revealedEp?.secret) {
      setRevealed({ name: revealedEp.name || revealedEp.url, secret: revealedEp.secret });
    }
  }

  async function handleRotate(ep: WebhookEndpointView) {
    if (
      !(await confirm({
        title: t("settings.webhook.ui.rotateTitle"),
        description: t("settings.webhook.ui.rotateHint"),
        confirmLabel: t("settings.webhook.ui.rotateConfirm"),
        tone: "danger",
      }))
    )
      return;
    setBusy(true);
    try {
      const rotated = await rotateWebhookSecret(ep.id);
      if (rotated.secret) setRevealed({ name: rotated.name || rotated.url, secret: rotated.secret });
      await load();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  async function handleTest(ep: WebhookEndpointView) {
    setBusy(true);
    try {
      const result = await sendWebhookTest(ep.id);
      if (result.ok) toast.success(t("settings.webhook.ui.testDelivered", {status: result.status_code ?? "", duration: result.duration_ms}));
      else toast.error(result.error || t("settings.webhook.ui.testFailed"));
      await load();
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  async function handleToggleRecords(id: string) {
    if (expanded === id) {
      setExpanded(null);
      return;
    }
    try {
      setRecords(await listWebhookDeliveries(id));
      setExpanded(id);
    } catch (e) {
      setError((e as Error).message);
    }
  }

  if (config == null) {
    return (
      <div className="space-y-2.5">
        <div className="h-[72px] animate-pulse rounded-xl bg-white/[0.04]" />
        <div className="h-[72px] animate-pulse rounded-xl bg-white/[0.04]" />
        {error && <ErrorBanner>{error}</ErrorBanner>}
      </div>
    );
  }

  return (
    <div className="space-y-10">
      <div className="space-y-4">
        <p className="text-sub leading-6 text-[var(--text-muted)]">
          {t.rich("settings.webhook.ui.intro", {code: chunks => <code className="rounded bg-white/[0.08] px-1 py-0.5 text-caption">{chunks}</code>})}
        </p>

        {error && <ErrorBanner>{error}</ErrorBanner>}

        {revealed && (
          <Banner tone="ok" title={t("settings.webhook.ui.revealedTitle", {name: revealed.name})}>
            <div className="mt-2 flex items-center gap-2">
              <code className="min-w-0 flex-1 break-all rounded-lg bg-black/30 px-3 py-2 font-mono text-caption text-[var(--text)]">
                {revealed.secret}
              </code>
              <CopyButton text={revealed.secret} label={t("common.copy")} className={SETTINGS_BUTTON_CLASS} />
            </div>
            <button
              type="button"
              onClick={() => setRevealed(null)}
              className="mt-2 text-caption text-[var(--text-muted)] underline underline-offset-2 hover:text-[var(--text)]"
            >
              {t("settings.webhook.ui.savedClose")}
            </button>
          </Banner>
        )}
      </div>

      {/* 总开关 */}
      <SettingsSection title={t("settings.webhook.ui.eventsTitle")}>
        <SettingsList>
          <SettingsRow label={t("settings.webhook.ui.enable")} description={t("settings.webhook.ui.enableHint")}>
            <Toggle
              checked={config.enabled}
              label={t("settings.webhook.ui.enable")}
              onChange={(v) => void handleToggleGlobal(v)}
            />
          </SettingsRow>
        </SettingsList>
      </SettingsSection>

      {/* endpoint 列表 */}
      <SettingsSection
        title={t("settings.webhook.ui.endpoints")}
        description={
          config.endpoints.length > 0 ? t("settings.webhook.ui.endpointCount", {count: config.endpoints.length}) : undefined
        }
        action={
          <button
            type="button"
            disabled={busy || draft != null}
            onClick={() => setDraft(emptyDraft(config.catalog))}
            className={`${SETTINGS_PRIMARY_BUTTON_CLASS} flex items-center gap-1 pl-3`}
          >
            <PlusIcon className="size-4" />
            {t("settings.webhook.ui.add")}
          </button>
        }
      >
        <div className="space-y-4">
          {config.endpoints.length === 0 && draft == null ? (
            <SettingsEmpty
              icon={<SendIcon className="size-5" />}
              title={t("settings.webhook.ui.empty")}
              description={t("settings.webhook.ui.emptyHint")}
            />
          ) : (
            config.endpoints.length > 0 && (
              <SettingsList>
                {config.endpoints.map((ep) => (
                  <div key={ep.id}>
                    <EndpointRow
                      endpoint={ep}
                      busy={busy}
                      expanded={expanded === ep.id}
                      onTest={() => void handleTest(ep)}
                      onEdit={() => setDraft(toPayload(ep))}
                      onToggle={(v) => void handleToggleEndpoint(ep.id, v)}
                      onRecords={() => void handleToggleRecords(ep.id)}
                      onDelete={() => void handleDelete(ep)}
                    />
                    {expanded === ep.id && <DeliveryList records={records} />}
                  </div>
                ))}
              </SettingsList>
            )
          )}

          {draft != null && (
            <EndpointEditor
              // key 保证切换编辑对象时整卡重挂载：headers 输入框是非受控的
              // （defaultValue，避免"输到一半被解析结果覆盖"），不重挂载会残留上一个
              // endpoint 的文本，用户一触碰就把 A 的请求头写进 B
              key={draft.id || "__new__"}
              draft={draft}
              catalog={config.catalog}
              busy={busy}
              onChange={setDraft}
              onCancel={() => setDraft(null)}
              onSubmit={() => void handleSubmitDraft()}
              onRotate={
                draft.id
                  ? () => {
                      const ep = config.endpoints.find((e) => e.id === draft.id);
                      if (ep) void handleRotate(ep);
                    }
                  : undefined
              }
              secretMasked={config.endpoints.find((e) => e.id === draft.id)?.secret_masked ?? ""}
            />
          )}
        </div>
      </SettingsSection>
    </div>
  );
}

/** 一行推送目标：名称 + 地址 + 最近投递状态点；行尾编辑 + ⋯（测试/记录/删除）+ 开关。 */
function EndpointRow({
  endpoint,
  busy,
  expanded,
  onTest,
  onEdit,
  onToggle,
  onRecords,
  onDelete,
}: {
  endpoint: WebhookEndpointView;
  busy: boolean;
  expanded: boolean;
  onTest: () => void;
  onEdit: () => void;
  onToggle: (v: boolean) => void;
  onRecords: () => void;
  onDelete: () => void;
}) {
  const t = useTranslations();
  const locale = useLocale() as AppLocale;
  const last = endpoint.last_delivery;
  const status = !endpoint.enabled
    ? { label: t("settings.webhook.ui.disabled"), color: "#c0c4cc" }
    : last == null
      ? { label: t("settings.webhook.ui.neverDelivered"), color: "#c0c4cc" }
      : last.ok
        ? { label: t("settings.webhook.ui.deliveredAt", {time: formatRelativeTime(last.at, locale)}), color: "var(--ok)" }
        : { label: t("settings.webhook.ui.failedAt", {time: formatRelativeTime(last.at, locale)}), color: "var(--danger)" };

  return (
    <div className="flex flex-wrap items-center gap-x-4 gap-y-2 px-4 py-3">
      <div className="min-w-0 flex-1 basis-52">
        <div className="flex items-center gap-2">
          <p className="truncate text-body font-semibold text-[var(--text)]">
            {endpoint.name || endpoint.url}
          </p>
          <span className="shrink-0 rounded-full bg-white/[0.08] px-2 py-0.5 text-caption text-[var(--text-muted)]">
            {endpoint.format === "movieclaw" ? t("settings.webhook.ui.nativeFormat") : t("settings.webhook.ui.jellyfinFormat")}
          </span>
        </div>
        <p className="mt-0.5 flex items-center gap-1.5 truncate text-caption text-[var(--text-faint)]">
          <span className="size-1.5 shrink-0 rounded-full" style={{ background: status.color }} />
          {status.label}
          <span className="truncate"> · {endpoint.url}</span>
        </p>
      </div>
      <div className="flex shrink-0 items-center gap-2">
        <button type="button" onClick={onEdit} className={SETTINGS_BUTTON_CLASS}>
          {t("settings.webhook.ui.editAction")}
        </button>
        <SettingsMoreMenu
          label={t("settings.webhook.ui.more", {name: endpoint.name || endpoint.url})}
          items={[
            { label: t("settings.webhook.ui.sendTest"), onSelect: onTest, disabled: busy },
            { label: expanded ? t("settings.webhook.ui.hideDeliveries") : t("settings.webhook.ui.deliveries"), onSelect: onRecords },
            { label: t("common.delete"), onSelect: onDelete, disabled: busy, danger: true },
          ]}
        />
        <Toggle
          checked={endpoint.enabled}
          label={t("settings.webhook.ui.enableEndpoint", {name: endpoint.name || endpoint.url})}
          onChange={onToggle}
        />
      </div>
    </div>
  );
}

/** 最近投递记录（内存环形缓冲，重启清空）。 */
function DeliveryList({ records }: { records: WebhookDelivery[] }) {
  const t = useTranslations();
  const locale = useLocale() as AppLocale;
  if (records.length === 0) {
    return (
      <p className="border-t border-[var(--line)] px-4 py-3 text-caption text-[var(--text-faint)]">
        {t("settings.webhook.ui.noRecords")}
      </p>
    );
  }
  return (
    <div className="border-t border-[var(--line)] py-1">
      {records.map((r) => (
        <div
          key={r.event_id + r.at}
          className={`${locale === "en" ? "flex-wrap " : ""}flex items-center gap-2.5 px-4 py-2 text-caption text-[var(--text-muted)]`}
        >
          <span
            className="size-1.5 shrink-0 rounded-full"
            style={{ background: r.ok ? "var(--ok)" : "var(--danger)" }}
          />
          <span className="w-44 shrink-0 truncate font-mono">{r.event}</span>
          <span className="shrink-0">
            {t("settings.webhook.ui.deliverySummary", {status: r.status_code != null ? `HTTP ${r.status_code}` : t("settings.webhook.ui.notDelivered"), duration: r.duration_ms, attempts: r.attempts})}
          </span>
          <span className={locale === "en" && r.error ? "min-w-0 basis-full break-words text-[var(--danger)]" : "min-w-0 flex-1 truncate text-[var(--danger)]"}>{r.error}</span>
          <span className="shrink-0 text-[var(--text-faint)]">{formatRelativeTime(r.at, locale)}</span>
        </div>
      ))}
    </div>
  );
}

/** 编辑卡：新建与编辑共用；编辑态附带密钥轮换入口（删除在列表行的 ⋯ 菜单）。 */
function EndpointEditor({
  draft,
  catalog,
  busy,
  secretMasked,
  onChange,
  onCancel,
  onSubmit,
  onRotate,
}: {
  draft: WebhookEndpointPayload;
  catalog: WebhookCatalogEntry[];
  busy: boolean;
  secretMasked: string;
  onChange: (d: WebhookEndpointPayload) => void;
  onCancel: () => void;
  onSubmit: () => void;
  onRotate?: () => void;
}) {
  const t = useTranslations();
  // 事件目录按 group 分组渲染，组内顺序即目录顺序
  const groups = catalog.reduce<Map<string, WebhookCatalogEntry[]>>((acc, entry) => {
    acc.set(entry.group, [...(acc.get(entry.group) ?? []), entry]);
    return acc;
  }, new Map());

  function toggleEvent(event: string, checked: boolean) {
    const events = checked
      ? [...draft.events, event]
      : draft.events.filter((e) => e !== event);
    onChange({ ...draft, events });
  }

  function selectable(entry: WebhookCatalogEntry): boolean {
    return draft.format !== "jellyfin" || entry.jellyfin_supported;
  }

  function toggleGroup(entries: WebhookCatalogEntry[], checked: boolean) {
    const ids = entries.filter(selectable).map((e) => e.event);
    const events = checked
      ? [...new Set([...draft.events, ...ids])]
      : draft.events.filter((e) => !ids.includes(e));
    onChange({ ...draft, events });
  }

  return (
    <SettingsCard
      title={draft.id ? t("settings.webhook.ui.edit") : t("settings.webhook.ui.add")}
      action={
        <div className="flex items-center gap-2">
          <button type="button" onClick={onCancel} className={SETTINGS_BUTTON_CLASS}>
            {t("common.cancel")}
          </button>
          <button
            type="button"
            disabled={busy}
            onClick={onSubmit}
            className={SETTINGS_PRIMARY_BUTTON_CLASS}
          >
            {t("common.save")}
          </button>
        </div>
      }
    >
      <div className="space-y-4">
        <div className="grid gap-3 md:grid-cols-2">
          <label className="block">
            <span className="mb-1.5 block text-caption text-[var(--text-muted)]">{t("settings.webhook.ui.name")}</span>
            <input
              type="text"
              value={draft.name}
              onChange={(e) => onChange({ ...draft, name: e.target.value })}
              placeholder={t("settings.webhook.ui.namePlaceholder")}
              className={INPUT_CLASS}
            />
          </label>
          <label className="block">
            <span className="mb-1.5 block text-caption text-[var(--text-muted)]">{t("settings.webhook.ui.url")}</span>
            <input
              type="text"
              value={draft.url}
              onChange={(e) => onChange({ ...draft, url: e.target.value })}
              placeholder="http://192.168.1.10:8123/api/webhook/xxx"
              className={`${INPUT_CLASS} font-mono`}
            />
          </label>
        </div>

        <div>
          <span className="mb-1.5 block text-caption text-[var(--text-muted)]">{t("settings.webhook.ui.format")}</span>
          <SettingsTabs
            tabs={[
              { id: "movieclaw", label: t("settings.webhook.ui.nativeTab") },
              { id: "jellyfin", label: t("settings.webhook.ui.jellyfinTab") },
            ]}
            value={draft.format}
            onChange={(format) => {
              if (format === draft.format) return;
              // 切到 jellyfin 时剔除没有 Jellyfin 对应物的已选事件
              const events =
                format === "jellyfin"
                  ? draft.events.filter((e) => catalog.find((c) => c.event === e)?.jellyfin_supported)
                  : draft.events;
              onChange({ ...draft, format, events });
            }}
          />
          {draft.format === "jellyfin" && (
            <p className="mt-1.5 text-caption text-[var(--text-faint)]">
              {t("settings.webhook.ui.jellyfinHint")}
            </p>
          )}
        </div>

        {draft.format === "jellyfin" && (
          <>
            <label className="block">
              <span className="mb-1.5 block text-caption text-[var(--text-muted)]">
                {t("settings.webhook.ui.templateLabel", {variable: "{{Var}}"})}
              </span>
              <textarea
                value={draft.template}
                onChange={(e) => onChange({ ...draft, template: e.target.value })}
                rows={6}
                placeholder={'{\n  "event": "{{NotificationType}}",\n  "title": {{json_encode Name}}\n}'}
                className={`${INPUT_CLASS} resize-y font-mono`}
              />
            </label>
            <label className="block">
              <span className="mb-1.5 block text-caption text-[var(--text-muted)]">
                {t("settings.webhook.ui.headersLabel")}
              </span>
              <textarea
                defaultValue={headersToText(draft.headers)}
                onChange={(e) => onChange({ ...draft, headers: textToHeaders(e.target.value) })}
                rows={2}
                className={`${INPUT_CLASS} resize-y font-mono`}
              />
            </label>
          </>
        )}

        <div>
          <span className="mb-1.5 block text-caption text-[var(--text-muted)]">{t("settings.webhook.ui.subscribedEvents")}</span>
          <div className="space-y-3">
            {[...groups.entries()].map(([group, entries]) => {
              const usable = entries.filter(selectable);
              const allOn =
                usable.length > 0 && usable.every((e) => draft.events.includes(e.event));
              return (
                <div key={group}>
                  <label className="flex cursor-pointer items-center gap-2 text-sub font-medium text-[var(--text)]">
                    <input
                      type="checkbox"
                      checked={allOn}
                      disabled={usable.length === 0}
                      onChange={(e) => toggleGroup(entries, e.target.checked)}
                      className="size-4 accent-[var(--accent)]"
                    />
                    {group}
                  </label>
                  <div className="mt-1.5 flex flex-wrap gap-x-5 gap-y-1.5 pl-6">
                    {entries.map((entry) => {
                      const enabled = selectable(entry);
                      return (
                        <label
                          key={entry.event}
                          title={enabled ? undefined : t("settings.webhook.ui.unsupported")}
                          className={`flex items-center gap-1.5 text-sub ${
                            enabled
                              ? "cursor-pointer text-[var(--text-muted)]"
                              : "cursor-not-allowed text-[var(--text-faint)] opacity-60"
                          }`}
                        >
                          <input
                            type="checkbox"
                            checked={enabled && draft.events.includes(entry.event)}
                            disabled={!enabled}
                            onChange={(e) => toggleEvent(entry.event, e.target.checked)}
                            className="size-4 accent-[var(--accent)]"
                          />
                          {entry.label}
                          <code className="text-caption text-[var(--text-faint)]">{entry.event}</code>
                        </label>
                      );
                    })}
                  </div>
                </div>
              );
            })}
          </div>
        </div>

        <div>
          <span className="mb-1.5 block text-caption text-[var(--text-muted)]">{t("settings.webhook.ui.egress")}</span>
          <SettingsTabs
            tabs={[
              { id: "lan", label: t("settings.webhook.ui.lan") },
              { id: "wan", label: t("settings.webhook.ui.wan") },
            ]}
            value={draft.egress_scope}
            onChange={(scope) => onChange({ ...draft, egress_scope: scope })}
          />
        </div>

        {draft.id && draft.format === "movieclaw" && (
          <div className="flex items-center justify-between gap-3 rounded-xl bg-white/[0.04] px-3.5 py-2.5">
            <p className="min-w-0 text-caption text-[var(--text-muted)]">
              {t.rich("settings.webhook.ui.secretHint", {secret: secretMasked || t("settings.webhook.ui.none"), code: chunks => <code className="font-mono">{chunks}</code>})}
            </p>
            {onRotate && (
              <button
                type="button"
                disabled={busy}
                onClick={onRotate}
                className={SETTINGS_BUTTON_CLASS}
              >
                {t("settings.webhook.ui.rotate")}
              </button>
            )}
          </div>
        )}
      </div>
    </SettingsCard>
  );
}
