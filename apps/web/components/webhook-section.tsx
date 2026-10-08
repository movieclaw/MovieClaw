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

import { useCallback, useEffect, useState } from "react";

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
  const confirm = useConfirm();
  const toast = useToast();
  const [config, setConfig] = useState<WebhookConfigView | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  /** 编辑卡中的草稿；null = 未打开 */
  const [draft, setDraft] = useState<WebhookEndpointPayload | null>(null);
  /** 一次性 secret：{endpoint 名, 明文}；关闭即永远消失 */
  const [revealed, setRevealed] = useState<{ name: string; secret: string } | null>(null);
  /** 展开投递记录的 endpoint id 及其记录 */
  const [expanded, setExpanded] = useState<string | null>(null);
  const [records, setRecords] = useState<WebhookDelivery[]>([]);

  const load = useCallback(async () => {
    try {
      setConfig(await getWebhookConfig());
    } catch (e) {
      setError((e as Error).message);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

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
        title: `删除「${ep.name || ep.url}」？`,
        description: "删除后该地址不再收到任何事件，签名密钥同时作废。",
        confirmLabel: "删除",
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
      setError("请填写目标地址");
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
        title: "轮换签名密钥？",
        description: "旧密钥立刻作废，下游需要更新为新密钥后才能继续验签。",
        confirmLabel: "轮换",
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
      if (result.ok) toast.success(`测试事件已送达（HTTP ${result.status_code}，${result.duration_ms}ms）`);
      else toast.error(result.error || "测试投递失败");
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
          播放、收藏等事件发生后，MovieClaw 会向下面配置的地址推送 JSON（自有协议带
          HMAC-SHA256 签名，头 <code className="rounded bg-white/[0.08] px-1 py-0.5 text-caption">X-MovieClaw-Signature</code>），
          供 Home Assistant、观影记录等外部服务实时订阅。
        </p>

        {error && <ErrorBanner>{error}</ErrorBanner>}

        {revealed && (
          <Banner tone="ok" title={`「${revealed.name}」的签名密钥（仅显示这一次，请立即保存）`}>
            <div className="mt-2 flex items-center gap-2">
              <code className="min-w-0 flex-1 break-all rounded-lg bg-black/30 px-3 py-2 font-mono text-caption text-[var(--text)]">
                {revealed.secret}
              </code>
              <CopyButton text={revealed.secret} label="复制" className={SETTINGS_BUTTON_CLASS} />
            </div>
            <button
              type="button"
              onClick={() => setRevealed(null)}
              className="mt-2 text-caption text-[var(--text-muted)] underline underline-offset-2 hover:text-[var(--text)]"
            >
              我已保存，关闭
            </button>
          </Banner>
        )}
      </div>

      {/* 总开关 */}
      <SettingsSection title="事件推送">
        <SettingsList>
          <SettingsRow label="启用事件推送" description="关闭后所有推送目标都不再收到事件">
            <Toggle
              checked={config.enabled}
              label="启用事件推送"
              onChange={(v) => void handleToggleGlobal(v)}
            />
          </SettingsRow>
        </SettingsList>
      </SettingsSection>

      {/* endpoint 列表 */}
      <SettingsSection
        title="推送目标"
        description={
          config.endpoints.length > 0 ? `已配置 ${config.endpoints.length} 个推送目标` : undefined
        }
        action={
          <button
            type="button"
            disabled={busy || draft != null}
            onClick={() => setDraft(emptyDraft(config.catalog))}
            className={`${SETTINGS_PRIMARY_BUTTON_CLASS} flex items-center gap-1 pl-3`}
          >
            <PlusIcon className="size-4" />
            新增 Endpoint
          </button>
        }
      >
        <div className="space-y-4">
          {config.endpoints.length === 0 && draft == null ? (
            <SettingsEmpty
              icon={<SendIcon className="size-5" />}
              title="还没有推送目标"
              description="点「新增 Endpoint」，把播放事件推给你的自动化服务。"
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
  const last = endpoint.last_delivery;
  const status = !endpoint.enabled
    ? { label: "已停用", color: "#c0c4cc" }
    : last == null
      ? { label: "未投递过", color: "#c0c4cc" }
      : last.ok
        ? { label: `投递成功 · ${formatRelativeTime(last.at)}`, color: "var(--ok)" }
        : { label: `投递失败 · ${formatRelativeTime(last.at)}`, color: "var(--danger)" };

  return (
    <div className="flex flex-wrap items-center gap-x-4 gap-y-2 px-4 py-3">
      <div className="min-w-0 flex-1 basis-52">
        <div className="flex items-center gap-2">
          <p className="truncate text-body font-semibold text-[var(--text)]">
            {endpoint.name || endpoint.url}
          </p>
          <span className="shrink-0 rounded-full bg-white/[0.08] px-2 py-0.5 text-caption text-[var(--text-muted)]">
            {endpoint.format === "movieclaw" ? "自有协议" : "Jellyfin 兼容"}
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
          编辑
        </button>
        <SettingsMoreMenu
          label={`${endpoint.name || endpoint.url} 的更多操作`}
          items={[
            { label: "发送测试", onSelect: onTest, disabled: busy },
            { label: expanded ? "收起发送记录" : "发送记录", onSelect: onRecords },
            { label: "删除", onSelect: onDelete, disabled: busy, danger: true },
          ]}
        />
        <Toggle
          checked={endpoint.enabled}
          label={`启用 ${endpoint.name || endpoint.url}`}
          onChange={onToggle}
        />
      </div>
    </div>
  );
}

/** 最近投递记录（内存环形缓冲，重启清空）。 */
function DeliveryList({ records }: { records: WebhookDelivery[] }) {
  if (records.length === 0) {
    return (
      <p className="border-t border-[var(--line)] px-4 py-3 text-caption text-[var(--text-faint)]">
        还没有投递记录（重启后记录会清空）。
      </p>
    );
  }
  return (
    <div className="border-t border-[var(--line)] py-1">
      {records.map((r) => (
        <div
          key={r.event_id + r.at}
          className="flex items-center gap-2.5 px-4 py-2 text-caption text-[var(--text-muted)]"
        >
          <span
            className="size-1.5 shrink-0 rounded-full"
            style={{ background: r.ok ? "var(--ok)" : "var(--danger)" }}
          />
          <span className="w-44 shrink-0 truncate font-mono">{r.event}</span>
          <span className="shrink-0">
            {r.status_code != null ? `HTTP ${r.status_code}` : "未送达"} · {r.duration_ms}ms · 尝试{" "}
            {r.attempts} 次
          </span>
          <span className="min-w-0 flex-1 truncate text-[var(--danger)]">{r.error}</span>
          <span className="shrink-0 text-[var(--text-faint)]">{formatRelativeTime(r.at)}</span>
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
      title={draft.id ? "编辑 Endpoint" : "新增 Endpoint"}
      action={
        <div className="flex items-center gap-2">
          <button type="button" onClick={onCancel} className={SETTINGS_BUTTON_CLASS}>
            取消
          </button>
          <button
            type="button"
            disabled={busy}
            onClick={onSubmit}
            className={SETTINGS_PRIMARY_BUTTON_CLASS}
          >
            保存
          </button>
        </div>
      }
    >
      <div className="space-y-4">
        <div className="grid gap-3 md:grid-cols-2">
          <label className="block">
            <span className="mb-1.5 block text-caption text-[var(--text-muted)]">显示名</span>
            <input
              type="text"
              value={draft.name}
              onChange={(e) => onChange({ ...draft, name: e.target.value })}
              placeholder="如 Home Assistant"
              className={INPUT_CLASS}
            />
          </label>
          <label className="block">
            <span className="mb-1.5 block text-caption text-[var(--text-muted)]">目标地址</span>
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
          <span className="mb-1.5 block text-caption text-[var(--text-muted)]">外发格式</span>
          <SettingsTabs
            tabs={[
              { id: "movieclaw", label: "自有协议（HMAC 签名）" },
              { id: "jellyfin", label: "Jellyfin 兼容（模板渲染）" },
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
              与 Jellyfin Webhook 插件同一套模板变量：下游文档里「贴进 Jellyfin
              插件」的模板可直接贴到下方，实现免适配接入。此格式不签名，鉴权用附加请求头。
            </p>
          )}
        </div>

        {draft.format === "jellyfin" && (
          <>
            <label className="block">
              <span className="mb-1.5 block text-caption text-[var(--text-muted)]">
                Handlebars 模板（支持 {"{{Var}}"} 与 if_equals / if_exist / link_to /
                url_encode / json_encode）
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
                附加请求头（每行一条，如 Authorization: Bearer xxx；可留空）
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
          <span className="mb-1.5 block text-caption text-[var(--text-muted)]">订阅事件</span>
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
                          title={enabled ? undefined : "该事件没有 Jellyfin 对应物，仅自有协议可订阅"}
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
          <span className="mb-1.5 block text-caption text-[var(--text-muted)]">网络出口</span>
          <SettingsTabs
            tabs={[
              { id: "lan", label: "内网直连（默认）" },
              { id: "wan", label: "跟随代理配置" },
            ]}
            value={draft.egress_scope}
            onChange={(scope) => onChange({ ...draft, egress_scope: scope })}
          />
        </div>

        {draft.id && draft.format === "movieclaw" && (
          <div className="flex items-center justify-between gap-3 rounded-xl bg-white/[0.04] px-3.5 py-2.5">
            <p className="min-w-0 text-caption text-[var(--text-muted)]">
              签名密钥 <code className="font-mono">{secretMasked || "（无）"}</code>
              ——明文仅在创建时展示过一次，丢失只能轮换
            </p>
            {onRotate && (
              <button
                type="button"
                disabled={busy}
                onClick={onRotate}
                className={SETTINGS_BUTTON_CLASS}
              >
                轮换密钥
              </button>
            )}
          </div>
        )}
      </div>
    </SettingsCard>
  );
}
