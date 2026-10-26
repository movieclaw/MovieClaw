"use client";

import { useLocale, useTranslations } from "next-intl";

import { useCallback, useEffect, useState } from "react";

import { ChevronLeftIcon } from "@/components/icons";
import { EndpointForm } from "@/components/mcp/endpoint-form";
import { ToolCatalog } from "@/components/mcp/tool-catalog";
import {
  CodeBlock,
  CopyField,
  formatBytes,
  INPUT_CLASS,
  MetaRow,
  ServiceChips,
  StatusDot,
} from "@/components/mcp/ui";
import {
  type McpEndpoint,
  type McpEndpointPayload,
  type McpPreview,
  type McpSelfCheck,
  type McpService,
  checkMcpEndpoint,
  previewMcpTools,
} from "@/lib/api/mcp";
import { relativeTime } from "@/lib/devices-display";
import { Toggle } from "@/components/cloud-push-ui";
import {
  SETTINGS_BUTTON_CLASS,
  SETTINGS_DANGER_BUTTON_CLASS,
  SettingsCard,
  SettingsList,
  SettingsRow,
  SettingsSection,
  SettingsTabs,
} from "@/components/settings-ui";

type Tab = "overview" | "tools" | "settings";



/**
 * 端点详情：一个端点的全部真相都在这一屏，按「读 → 用 → 改 → 删」分三栏。
 *
 * 为什么是详情页而不是列表里的展开区：接一个端点要同时看地址、认证头、令牌提示
 * 和工具面，这些东西挤在列表行里谁也看不清；而且详情有自己的地址（?endpoint=slug），
 * 刷新、收藏、发给同事都能落到同一处。
 */
export function EndpointDetail({
  endpoint,
  services,
  baseUrl,
  busy,
  tab,
  onTab,
  onBack,
  onToggleEnabled,
  onSave,
  onRotate,
  onDelete,
}: {
  endpoint: McpEndpoint;
  services: McpService[];
  baseUrl: string;
  busy: boolean;
  tab: Tab;
  onTab: (next: Tab) => void;
  onBack: () => void;
  onToggleEnabled: (next: boolean) => void;
  onSave: (payload: McpEndpointPayload) => void;
  onRotate: () => void;
  onDelete: () => void;
}) {
  const t = useTranslations();
  const locale = useLocale();
  const TABS: { id: Tab; label: string }[] = [
  { id: "overview", label: t("settings.mcp.controls.overview") },
  { id: "tools", label: t("settings.mcp.controls.tools") },
  { id: "settings", label: t("settings.mcp.controls.settings") },
];
  const [preview, setPreview] = useState<McpPreview | null>(null);
  const [confirmText, setConfirmText] = useState("");
  const [check, setCheck] = useState<McpSelfCheck | null>(null);
  const [checking, setChecking] = useState(false);

  /** 自检：跑一次真实的协议往返 + 一次只读调用，回答「现在能不能用」。 */
  const runCheck = async () => {
    setChecking(true);
    try {
      setCheck(await checkMcpEndpoint(endpoint.id));
    } catch (e) {
      // 请求本身失败（网络断、接口不存在）也要显示成一次「未通过」，而不是把异常
      // 抛给 React——自检的全部意义就是给出结论，静默失败是最坏的结果
      setCheck({
        ok: false,
        message: t("settings.mcp.controls.checkRequestFailed", { detail: (e as Error).message }),
        protocol_version: "",
        tool_count: 0,
        elapsed_ms: 0,
        probe_tool: "",
        probe_ok: false,
        probe_message: "",
        warnings: [],
      });
    } finally {
      setChecking(false);
    }
  };

  const loadPreview = useCallback(async () => {
    setPreview(await previewMcpTools(endpoint.services, endpoint.expand_tools));
  }, [endpoint.services, endpoint.expand_tools]);

  useEffect(() => {
    setPreview(null);
    void loadPreview();
  }, [loadPreview]);

  const fullUrl = endpoint.url.startsWith("http")
    ? endpoint.url
    : `${baseUrl || t("settings.mcp.controls.addressPlaceholder")}${endpoint.url}`;

  return (
    <div className="space-y-5">
      {/* 头部：标题只放名字，其余降一级。
          此前是「状态点 + 名字 + 形态徽章 + 工具数」全挤在标题行上——一个徽章
          紧贴 20px 的标题，读起来既不像标题也不像标签。现在分三层：
          返回 → 标题 + 启停 → 一行淡色元信息（状态 / 地址 / 形态）。
          工具数挪到「工具」页签上，数字就长在它对应的入口旁边。 */}
      <div>
        {/* 「全部端点」是钻取层（端点详情 → 端点列表）的返回出口，语义属「返回」
            而非「前进/进入」（父级接线是 onBack = 退出详情回列表，见上方头部
            注释的分层说明）——图标因此随全站返回语言统一为 ChevronLeft */}
        <button
          type="button"
          onClick={onBack}
          className="btn-glass mb-3 px-2.5 py-1 text-caption font-medium text-[var(--text-muted)]"
        >
          <ChevronLeftIcon className="size-3.5" />
          {t("settings.mcp.controls.allEndpoints")}
        </button>

        <div className="flex items-start justify-between gap-4">
          <h2 className="min-w-0 truncate text-xl font-medium tracking-tight">{endpoint.name}</h2>
          <div className="flex shrink-0 items-center gap-2.5">
            <span className="text-caption text-[var(--text-muted)]">
              {endpoint.enabled ? t("settings.mcp.controls.enabled") : t("settings.mcp.controls.disabled")}
            </span>
            <Toggle
              checked={endpoint.enabled}
              label={t("settings.mcp.controls.enableNamed", { name: endpoint.name })}
              onChange={(next) => {
                if (!busy) onToggleEnabled(next);
              }}
            />
          </div>
        </div>

        <div className="mt-1.5 flex flex-wrap items-center gap-x-2 gap-y-1 text-caption text-[var(--text-muted)]">
          <span className="flex items-center gap-1.5">
            <StatusDot on={endpoint.enabled} title={endpoint.enabled ? t("settings.mcp.controls.running") : t("settings.mcp.controls.disabled")} />
            {endpoint.enabled ? t("settings.mcp.controls.running") : t("settings.mcp.controls.disabled")}
          </span>
          <span className="text-[var(--text-faint)]">·</span>
          <span className="font-mono">/mcp/{endpoint.slug}</span>
          <span className="text-[var(--text-faint)]">·</span>
          <span>{endpoint.expand_tools ? t("settings.mcp.controls.commandMode") : t("settings.mcp.controls.serviceMode")}</span>
        </div>
      </div>

      <SettingsTabs
        tabs={TABS.map((item) => ({
          id: item.id,
          label:
            item.id === "tools" ? (
              <>
                {item.label}
                <span className="tabular-nums text-caption opacity-60">{endpoint.tool_count}</span>
              </>
            ) : (
              item.label
            ),
        }))}
        value={tab}
        onChange={onTab}
      />

      {tab === "overview" && (
        <div className="space-y-5">
          {/* 接进一个客户端要填的全部东西，就这两行。原先它们独占一个「接入」页签，
              而那个页签在去掉各端示例后只剩这两样，还和概览重复了一遍端点地址——
              一个页签换一次点击、看到的是别处已经有的内容，不如并进来。 */}
          <div>
            <p className="mb-1.5 text-caption text-[var(--text-muted)]">{t("settings.mcp.controls.address")}</p>
            <CopyField value={fullUrl} label={t("settings.mcp.controls.copyAddress")} />
            {!endpoint.url.startsWith("http") && (
              <p className="mt-1.5 text-caption text-[var(--warn,#f5c451)]">
                {t("settings.mcp.controls.externalHint")}
              </p>
            )}
          </div>

          <div>
            <p className="mb-1.5 text-caption text-[var(--text-muted)]">{t("settings.mcp.controls.authHeader")}</p>
            <CodeBlock code={t("settings.mcp.controls.authPlaceholder")} lang="http" />
            <p className="mt-1.5 text-caption leading-relaxed text-[var(--text-muted)]">
              {t("settings.mcp.controls.transportHint")}
            </p>
          </div>

          {/* 自检：配完之后最想问的那句「它现在能用吗」，就地给答案 */}
          <SettingsList>
            <SettingsRow
              label={t("settings.mcp.controls.checkTitle")}
              description={t("settings.mcp.controls.checkHint")}
            >
              <button
                type="button"
                onClick={() => void runCheck()}
                disabled={checking}
                className={SETTINGS_BUTTON_CLASS}
              >
                {checking ? t("settings.mcp.controls.checking") : check ? t("settings.mcp.controls.checkAgain") : t("settings.mcp.controls.runCheck")}
              </button>
            </SettingsRow>

            {check && (
              <div className="space-y-2 px-4 py-3">
                <p className="flex items-center gap-2 text-sub">
                  <StatusDot on={check.ok} title={check.ok ? t("settings.mcp.controls.passed") : t("settings.mcp.controls.notPassed")} />
                  <span className={check.ok ? "" : "text-[var(--danger)]"}>{check.message}</span>
                  <span className="text-caption tabular-nums text-[var(--text-faint)]">
                    {check.elapsed_ms} ms
                  </span>
                </p>
                <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-caption">
                  <dt className="text-[var(--text-faint)]">{t("settings.mcp.controls.protocol")}</dt>
                  <dd className="font-mono">{check.protocol_version || "—"}</dd>
                  <dt className="text-[var(--text-faint)]">{t("settings.mcp.controls.tools")}</dt>
                  <dd className="tabular-nums">{t("settings.mcp.controls.countUnit", { count: check.tool_count })}</dd>
                  {check.probe_tool && (
                    <>
                      <dt className="text-[var(--text-faint)]">{t("settings.mcp.controls.probe")}</dt>
                      <dd className="min-w-0">
                        <span className="font-mono text-[var(--accent)]">{check.probe_tool}</span>
                        <span className={check.probe_ok ? "ml-2" : "ml-2 text-[var(--danger)]"}>
                          {check.probe_ok ? t("settings.mcp.controls.succeeded") : t("settings.mcp.controls.failed")}
                        </span>
                        {check.probe_message && (
                          <span className="ml-2 text-[var(--text-faint)]">
                            {check.probe_message.slice(0, 60)}
                          </span>
                        )}
                      </dd>
                    </>
                  )}
                </dl>
                {check.warnings.map((warning) => (
                  <p
                    key={warning}
                    className="rounded-lg border border-[var(--warn,#f5c451)]/30 bg-[var(--warn,#f5c451)]/10 px-2.5 py-1.5 text-caption"
                  >
                    {warning}
                  </p>
                ))}
              </div>
            )}
          </SettingsList>

          <div className="css-glass !rounded-xl px-4 py-2">
            <MetaRow label={t("settings.mcp.controls.services")}>
              {/* 详情页不设上限：这一屏就是要看全「到底开放了什么」 */}
              <ServiceChips services={endpoint.services} max={endpoint.services.length} />
            </MetaRow>
            {/* 只留这几行：工具体积、令牌、最近调用。
                工具数在页签上、工具形态在标题下的元信息行里、超时在「设置」页签里可改，
                创建时间答不了任何问题——重复一遍只是把真正要看的三行冲淡。 */}
            <MetaRow label={t("settings.mcp.controls.tools")}>
              {preview ? t("settings.mcp.controls.definitionSize", { bytes: formatBytes(preview.approx_bytes) }) : t("settings.mcp.controls.calculating")}
            </MetaRow>
            <MetaRow label={t("settings.mcp.controls.token")}>
              <span className="font-mono">{endpoint.token_hint}</span>
              <button
                type="button"
                onClick={onRotate}
                disabled={busy}
                className="btn-glass ml-2 px-2.5 py-0.5 text-caption"
              >
                {t("settings.mcp.controls.rotate")}
              </button>
            </MetaRow>
            <MetaRow label={t("settings.mcp.controls.lastCalled")}>
              {endpoint.last_used_at ? relativeTime(endpoint.last_used_at, undefined, locale) : t("settings.mcp.controls.neverCalled")}
            </MetaRow>
          </div>

          {endpoint.missing_services.length > 0 && (
            <p className="rounded-lg border border-[var(--warn,#f5c451)]/35 bg-[var(--warn,#f5c451)]/10 px-3 py-2 text-caption">
              {t("settings.mcp.controls.missingServices", { count: endpoint.missing_services.length })}
              <span className="font-mono">{endpoint.missing_services.join(t("settings.mcp.controls.listSeparator"))}</span>
            </p>
          )}
        </div>
      )}

      {tab === "tools" &&
        (preview ? (
          <ToolCatalog tools={preview.tools} />
        ) : (
          <p className="text-sub text-[var(--text-muted)]">{t("settings.mcp.controls.loadingCatalog")}</p>
        ))}

      {tab === "settings" && (
        <div className="space-y-8">
          <EndpointForm
            initial={{
              name: endpoint.name,
              slug: endpoint.slug,
              services: endpoint.services,
              description: endpoint.description,
              expand_tools: endpoint.expand_tools,
              timeout_seconds: endpoint.timeout_seconds,
            }}
            services={services}
            baseUrl={baseUrl}
            busy={busy}
            slugEditable={false}
            submitLabel={t("settings.mcp.controls.saveChanges")}
            onSubmit={onSave}
            onCancel={onBack}
          />

          {/* 危险区：沉到最底，删除要打字确认——和 Stripe/GitHub 的处理一致，
              因为端点一删，接入它的客户端立刻全断，而且不可恢复 */}
          <SettingsSection title={t("settings.mcp.controls.danger")}>
            <SettingsCard
              tone="danger"
              title={t("settings.mcp.controls.deleteEndpoint")}
              description={
                <>
                  {t("settings.mcp.controls.deleteHint")}{" "}
                  <span className="font-mono text-[var(--text)]">{endpoint.slug}</span>{t("settings.mcp.controls.period")}
                </>
              }
              action={
                <button
                  type="button"
                  disabled={busy || confirmText !== endpoint.slug}
                  onClick={onDelete}
                  className={SETTINGS_DANGER_BUTTON_CLASS}
                >
                  {t("settings.mcp.controls.deleteEndpoint")}
                </button>
              }
            >
              <input
                type="text"
                value={confirmText}
                onChange={(e) => setConfirmText(e.target.value)}
                placeholder={endpoint.slug}
                aria-label={t("settings.mcp.controls.deleteConfirmPlaceholder")}
                className={`${INPUT_CLASS} max-w-[220px] font-mono`}
              />
            </SettingsCard>
          </SettingsSection>
        </div>
      )}
    </div>
  );
}
