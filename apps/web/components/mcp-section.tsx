"use client";

import { useLocale, useTranslations } from "next-intl";

import { useCallback, useEffect, useMemo, useState } from "react";

import { Banner, ErrorBanner, Toggle } from "@/components/cloud-push-ui";
import { useConfirm } from "@/components/feedback";
import { PlusIcon } from "@/components/icons";
import { EndpointDetail } from "@/components/mcp/endpoint-detail";
import { EndpointForm } from "@/components/mcp/endpoint-form";
import { Badge, CodeBlock, CopyField, ServiceChips, StatusDot } from "@/components/mcp/ui";
import {
  type McpEndpoint,
  type McpStatus,
  createMcpEndpoint,
  deleteMcpEndpoint,
  getMcpStatus,
  rotateMcpToken,
  setMcpEnabled,
  updateMcpEndpoint,
} from "@/lib/api/mcp";
import { relativeTime } from "@/lib/devices-display";
import {
  SETTINGS_PRIMARY_BUTTON_CLASS,
  SettingsEmpty,
  SettingsList,
  SettingsRow,
  SettingsSection,
} from "@/components/settings-ui";

type Tab = "overview" | "tools" | "settings";
const TABS: Tab[] = ["overview", "tools", "settings"];

/**
 * 「MCP 服务」设置分区（docs/design/mcp-server.md §7）。
 *
 * 这一页的用户是要把端点接进 Claude Code / Cursor 的开发者，所以整页按开发者
 * 控制台而不是偏好设置来组织，三层结构：
 *
 *   列表（高密度表格，一眼扫完谁在跑）
 *     → 详情（?endpoint=slug，三栏：概览 / 工具 / 设置）
 *     → 新建（两栏：左配置右实时预览）
 *
 * 视图状态写进地址栏（?endpoint= / ?tab=）：刷新不丢、可收藏、可发给同事。
 * 手法与 lib/use-tab-param.ts 相同——原生 replaceState，不触发 Next 重渲染，
 * 也不往历史里塞「切标签」这种无意义的返回点。
 */
export function McpSection() {
  const t = useTranslations();
  const locale = useLocale();
  const confirm = useConfirm();
  const [status, setStatus] = useState<McpStatus | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [view, setView] = useState<{ slug: string | null; tab: Tab; creating: boolean }>({
    slug: null,
    tab: "overview",
    creating: false,
  });
  /** 刚签发的令牌：唯一一次能看到明文，占满整屏直到用户确认保存 */
  const [issued, setIssued] = useState<{ endpoint: McpEndpoint; token: string } | null>(null);

  const load = useCallback(async () => {
    try {
      setStatus(await getMcpStatus());
    } catch (e) {
      setError((e as Error).message);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  // 挂载时读地址栏，把人直接送到某个端点的某一栏
  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    const slug = params.get("endpoint");
    const tab = params.get("tab");
    if (slug) {
      setView({
        slug,
        tab: TABS.includes(tab as Tab) ? (tab as Tab) : "overview",
        creating: false,
      });
    }
  }, []);

  const navigate = useCallback((next: { slug: string | null; tab?: Tab; creating?: boolean }) => {
    setView((prev) => {
      const merged = { slug: next.slug, tab: next.tab ?? prev.tab, creating: next.creating ?? false };
      const url = new URL(window.location.href);
      if (merged.slug) url.searchParams.set("endpoint", merged.slug);
      else url.searchParams.delete("endpoint");
      if (merged.slug && merged.tab !== "overview") url.searchParams.set("tab", merged.tab);
      else url.searchParams.delete("tab");
      window.history.replaceState(window.history.state, "", url);
      return merged;
    });
  }, []);

  async function run<T>(action: () => Promise<T>): Promise<T | null> {
    setBusy(true);
    setError(null);
    try {
      const result = await action();
      await load();
      return result;
    } catch (e) {
      setError((e as Error).message);
      return null;
    } finally {
      setBusy(false);
    }
  }

  const current = useMemo(
    () => status?.endpoints.find((e) => e.slug === view.slug) ?? null,
    [status, view.slug],
  );

  if (!status) {
    // 骨架而不是「加载中…」：布局先占位，数据到了不跳版
    return error ? (
      <ErrorBanner>{error}</ErrorBanner>
    ) : (
      <div className="space-y-3">
        <div className="h-[68px] animate-pulse rounded-xl bg-white/[0.04]" />
        <div className="h-[180px] animate-pulse rounded-xl bg-white/[0.03]" />
      </div>
    );
  }

  // ── 令牌专屏：签发后必须先看这一屏，其他内容一概让位 ──────────────
  if (issued) {
    const url = issued.endpoint.url.startsWith("http")
      ? issued.endpoint.url
      : `${status.base_url || t("settings.mcp.controls.addressPlaceholder")}${issued.endpoint.url}`;
    return (
      <TokenIssued
        name={issued.endpoint.name}
        url={url}
        token={issued.token}
        onDone={() => {
          const slug = issued.endpoint.slug;
          setIssued(null);
          navigate({ slug, tab: "overview" });
        }}
      />
    );
  }

  /** 错误横幅。三个视图共用同一处渲染——旧版只在列表里渲染，创建失败时
   *  用户点了按钮却什么都看不到，这是最糟的一类反馈缺失。 */
  const banner = error ? <ErrorBanner>{error}</ErrorBanner> : null;

  if (view.creating) {
    return (
      <div className="space-y-4">
        {banner}
        <EndpointForm
          initial={{ name: "", slug: "", services: [], expand_tools: true, timeout_seconds: 300 }}
          services={status.services}
          baseUrl={status.base_url}
          busy={busy}
          slugEditable
          takenSlugs={status.endpoints.map((e) => e.slug)}
          submitLabel={t("settings.mcp.controls.create")}
          onCancel={() => navigate({ slug: null })}
          onSubmit={async (payload) => {
            const created = await run(() => createMcpEndpoint(payload));
            if (created) setIssued({ endpoint: created.endpoint, token: created.token });
          }}
        />
      </div>
    );
  }

  if (current) {
    return (
      <div className="space-y-4">
        {banner}
        <EndpointDetail
          key={current.id}
          endpoint={current}
          services={status.services}
          baseUrl={status.base_url}
          busy={busy}
          tab={view.tab}
          onTab={(tab) => navigate({ slug: current.slug, tab })}
          onBack={() => navigate({ slug: null })}
          onToggleEnabled={(enabled) => void run(() => updateMcpEndpoint(current.id, { enabled }))}
          onSave={(payload) =>
            void run(() =>
              updateMcpEndpoint(current.id, {
                name: payload.name,
                services: payload.services,
                expand_tools: payload.expand_tools,
                timeout_seconds: payload.timeout_seconds,
              }),
            )
          }
          onRotate={async () => {
            const ok = await confirm({
              title: t("settings.mcp.controls.rotateTitle"),
              description:
                t("settings.mcp.controls.rotateDescription"),
              confirmLabel: t("settings.mcp.controls.generateToken"),
            });
            if (!ok) return;
            const rotated = await run(() => rotateMcpToken(current.id));
            if (rotated) setIssued({ endpoint: rotated.endpoint, token: rotated.token });
          }}
          onDelete={async () => {
            const deleted = await run(() => deleteMcpEndpoint(current.id));
            if (deleted !== null) navigate({ slug: null });
          }}
        />
      </div>
    );
  }

  // ── 列表 ────────────────────────────────────────────────────────
  return (
    <div className="space-y-10">
      {banner}

      {/* 总开关：行组里一行，左边写清地址形态、右边全站统一的开关 */}
      <SettingsSection title={t("settings.mcp.controls.services")}>
        <SettingsList>
          <SettingsRow
            label={t("settings.mcp.controls.enableService")}
            description={
              <span className="block truncate font-mono">
                {status.base_url || t("settings.mcp.controls.noExternal")}{t("settings.mcp.controls.endpointPath")}
              </span>
            }
          >
            <Toggle
              checked={status.enabled}
              label={t("settings.mcp.controls.enableService")}
              onChange={(enabled) => void run(() => setMcpEnabled(enabled))}
            />
          </SettingsRow>
        </SettingsList>
      </SettingsSection>

      <SettingsSection
        title={t("settings.mcp.controls.endpoints")}
        description={
          status.endpoints.length === 0
            ? t("settings.mcp.controls.endpointHint")
            : t("settings.mcp.controls.configuredCount", { count: status.endpoints.length })
        }
        action={
          <button
            type="button"
            disabled={busy}
            onClick={() => navigate({ slug: null, creating: true })}
            className={`${SETTINGS_PRIMARY_BUTTON_CLASS} flex items-center gap-1`}
          >
            <PlusIcon className="size-4" />
            {t("settings.mcp.controls.new")}
          </button>
        }
      >
        {!status.enabled && status.endpoints.length > 0 && (
          <div className="mb-3">
            <Banner tone="warn">
              {t("settings.mcp.controls.disabledHint")}</Banner>
          </div>
        )}

        {status.endpoints.length === 0 ? (
          <SettingsEmpty
            title={t("settings.mcp.controls.emptyTitle")}
            description={t("settings.mcp.controls.emptyHint")}
          />
        ) : (
          /* 宽屏用表格而不是卡片墙：端点是一组同构对象，纵向对齐才扫得快。
             窄屏反过来——五列塞进 390px 会把端点名按字符竖着掰成一列，所以另render
             一份卡片。数据同源，只是排版不同。 */
          <div className="css-glass overflow-hidden !rounded-xl">
            <ul className="divide-y divide-[var(--line)] md:hidden">
              {status.endpoints.map((endpoint) => (
                <li key={endpoint.id}>
                  <button
                    type="button"
                    onClick={() => navigate({ slug: endpoint.slug, tab: "overview" })}
                    className={`flex w-full items-start gap-3 px-4 py-3 text-left transition-colors hover:bg-white/[0.04] ${
                      endpoint.enabled ? "" : "opacity-55"
                    }`}
                  >
                    <div className="min-w-0 flex-1 space-y-1.5">
                      <div className="flex items-center gap-2">
                        <StatusDot
                          on={endpoint.enabled}
                          title={endpoint.enabled ? t("settings.mcp.controls.running") : t("settings.mcp.controls.disabled")}
                        />
                        <span className="min-w-0 truncate font-medium">{endpoint.name}</span>
                      </div>
                      <p className="font-mono text-caption text-[var(--text-muted)]">
                        /mcp/{endpoint.slug}
                      </p>
                      <ServiceChips services={endpoint.services} max={3} />
                      <p className="text-caption text-[var(--text-faint)]">
                        {t("settings.mcp.controls.toolsCount", { count: endpoint.tool_count })} ·{" "}
                        {endpoint.expand_tools ? t("settings.mcp.controls.commandMode") : t("settings.mcp.controls.serviceMode")} ·{" "}
                        {endpoint.last_used_at ? relativeTime(endpoint.last_used_at, undefined, locale) : t("settings.mcp.controls.neverCalled")}
                      </p>
                    </div>
                    <span className="shrink-0 pt-0.5 text-[var(--text-faint)]">›</span>
                  </button>
                </li>
              ))}
            </ul>

            <table className="hidden w-full text-left text-sub md:table">
              <thead className="bg-white/[0.03] text-caption text-[var(--text-faint)]">
                <tr>
                  <th className="px-4 py-2 font-normal">{t("settings.mcp.controls.endpoints")}</th>
                  <th className="px-3 py-2 font-normal">{t("settings.mcp.controls.exposedServices")}</th>
                  {/* 数字列右对齐 + tabular-nums：一列数字上下对得齐才扫得快 */}
                  <th className="px-3 py-2 text-right font-normal">{t("settings.mcp.controls.tools")}</th>
                  <th className="px-3 py-2 font-normal">{t("settings.mcp.controls.lastCalled")}</th>
                  <th className="w-8 px-3 py-2 font-normal"></th>
                </tr>
              </thead>
              <tbody className="divide-y divide-white/[0.05]">
                {status.endpoints.map((endpoint) => (
                  <tr
                    key={endpoint.id}
                    // 整行可点，且键盘能走到：表格行本身不可聚焦，不补这两样，
                    // 只用鼠标的人能进详情、用键盘的人进不去
                    tabIndex={0}
                    role="link"
                    aria-label={t("settings.mcp.controls.openNamed", { name: endpoint.name })}
                    onClick={() => navigate({ slug: endpoint.slug, tab: "overview" })}
                    onKeyDown={(e) => {
                      if (e.key === "Enter" || e.key === " ") {
                        e.preventDefault();
                        navigate({ slug: endpoint.slug, tab: "overview" });
                      }
                    }}
                    className={`group cursor-pointer outline-none transition-colors hover:bg-white/[0.04] focus-visible:bg-white/[0.06] ${
                      endpoint.enabled ? "" : "opacity-55"
                    }`}
                  >
                    <td className="px-4 py-2.5 align-top">
                      <div className="flex items-center gap-2">
                        <StatusDot on={endpoint.enabled} title={endpoint.enabled ? t("settings.mcp.controls.running") : t("settings.mcp.controls.disabled")} />
                        <span className="font-medium">{endpoint.name}</span>
                        <Badge>{endpoint.expand_tools ? t("settings.mcp.controls.commandMode") : t("settings.mcp.controls.serviceMode")}</Badge>
                      </div>
                      <p className="mt-0.5 pl-3.5 font-mono text-caption text-[var(--text-muted)]">
                        /mcp/{endpoint.slug}
                      </p>
                    </td>
                    <td className="max-w-[300px] px-3 py-2.5 align-top">
                      <ServiceChips services={endpoint.services} />
                    </td>
                    <td className="px-3 py-2.5 text-right align-top tabular-nums">
                      {endpoint.tool_count}
                    </td>
                    <td className="px-3 py-2.5 align-top text-caption text-[var(--text-muted)]">
                      {endpoint.last_used_at ? relativeTime(endpoint.last_used_at, undefined, locale) : t("settings.mcp.controls.never")}
                    </td>
                    {/* 箭头静默待命，hover/聚焦时才亮起并右移——「这行可以点」的暗示，
                        不用一个常驻的「详情」文字去抢注意力 */}
                    <td className="px-3 py-2.5 text-right align-top text-[var(--text-faint)]">
                      <span className="inline-block transition-transform group-hover:translate-x-0.5 group-hover:text-[var(--text)] group-focus-visible:text-[var(--text)]">
                        ›
                      </span>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </SettingsSection>
    </div>
  );
}

/**
 * 令牌专屏：签发后必须先过这一关。
 *
 * 旧版把它做成插在列表上方的卡片——一滚就走，用户很容易在没保存的情况下离开。
 * 现在它占满整个内容区，只有一个出口（「我已保存」），出去直接落到端点概览。
 */
function TokenIssued({
  name,
  url,
  token,
  onDone,
}: {
  name: string;
  url: string;
  token: string;
  onDone: () => void;
}) {
  const t = useTranslations();
  return (
    <div className="mx-auto max-w-xl space-y-5 py-4">
      <div>
        <h2 className="text-xl font-medium tracking-tight">{t("settings.mcp.controls.saveTokenTitle", { name })}</h2>
        <p className="mt-1.5 text-sub leading-relaxed text-[var(--danger)]">
          {t("settings.mcp.controls.saveTokenHint")}
        </p>
      </div>

      <div className="space-y-2">
        <p className="text-caption text-[var(--text-muted)]">{t("settings.mcp.controls.address")}</p>
        <CopyField value={url} label={t("settings.mcp.controls.copyAddress")} />
        <p className="pt-1 text-caption text-[var(--text-muted)]">{t("settings.mcp.controls.accessToken")}</p>
        <CopyField value={token} label={t("settings.mcp.controls.copyToken")} />
      </div>

      <div>
        <p className="mb-2 text-caption text-[var(--text-muted)]">{t("settings.mcp.controls.addToClient")}</p>
        <CodeBlock
          lang="bash"
          code={`claude mcp add --transport http movieclaw \\\n  ${url} \\\n  --header "Authorization: Bearer ${token}"`}
        />
      </div>

      <div className="flex justify-end">
        <button type="button" onClick={onDone} className={SETTINGS_PRIMARY_BUTTON_CLASS}>
          {t("settings.mcp.controls.tokenSaved")}
        </button>
      </div>
    </div>
  );
}
