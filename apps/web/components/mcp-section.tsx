"use client";

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
      : `${status.base_url || "http://<你的地址>"}${issued.endpoint.url}`;
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
          submitLabel="创建端点"
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
              title: "轮换令牌？",
              description:
                "会生成一枚新令牌，旧令牌立即失效。已接入的客户端都要更新配置，否则会开始报 401。",
              confirmLabel: "生成新令牌",
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
      <SettingsSection title="服务">
        <SettingsList>
          <SettingsRow
            label="启用 MCP 服务"
            description={
              <span className="block truncate font-mono">
                {status.base_url || "（未配置外部地址）"}/mcp/&lt;端点&gt;
              </span>
            }
          >
            <Toggle
              checked={status.enabled}
              label="启用 MCP 服务"
              onChange={(enabled) => void run(() => setMcpEnabled(enabled))}
            />
          </SettingsRow>
        </SettingsList>
      </SettingsSection>

      <SettingsSection
        title="端点"
        description={
          status.endpoints.length === 0
            ? "端点是给 AI 客户端用的入口，每个端点的工具目录相互独立。"
            : `已配置 ${status.endpoints.length} 个端点`
        }
        action={
          <button
            type="button"
            disabled={busy}
            onClick={() => navigate({ slug: null, creating: true })}
            className={`${SETTINGS_PRIMARY_BUTTON_CLASS} flex items-center gap-1`}
          >
            <PlusIcon className="size-4" />
            新建端点
          </button>
        }
      >
        {!status.enabled && status.endpoints.length > 0 && (
          <div className="mb-3">
            <Banner tone="warn">
              服务已关闭，下面所有端点一律返回 404。配置与令牌都保留着，打开开关即恢复。
            </Banner>
          </div>
        )}

        {status.endpoints.length === 0 ? (
          <SettingsEmpty
            title="还没有 MCP 端点"
            description="建一个、勾选要开放的服务，Claude Code 或 Cursor 填上地址和令牌，就能直接查库存、搜资源、管订阅。"
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
                          title={endpoint.enabled ? "运行中" : "已停用"}
                        />
                        <span className="min-w-0 truncate font-medium">{endpoint.name}</span>
                      </div>
                      <p className="font-mono text-caption text-[var(--text-muted)]">
                        /mcp/{endpoint.slug}
                      </p>
                      <ServiceChips services={endpoint.services} max={3} />
                      <p className="text-caption text-[var(--text-faint)]">
                        {endpoint.tool_count} 个工具 ·{" "}
                        {endpoint.expand_tools ? "一命令一工具" : "一服务一工具"} ·{" "}
                        {endpoint.last_used_at ? relativeTime(endpoint.last_used_at) : "从未调用"}
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
                  <th className="px-4 py-2 font-normal">端点</th>
                  <th className="px-3 py-2 font-normal">开放的服务</th>
                  {/* 数字列右对齐 + tabular-nums：一列数字上下对得齐才扫得快 */}
                  <th className="px-3 py-2 text-right font-normal">工具</th>
                  <th className="px-3 py-2 font-normal">最近调用</th>
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
                    aria-label={`打开端点 ${endpoint.name}`}
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
                        <StatusDot on={endpoint.enabled} title={endpoint.enabled ? "运行中" : "已停用"} />
                        <span className="font-medium">{endpoint.name}</span>
                        <Badge>{endpoint.expand_tools ? "一命令一工具" : "一服务一工具"}</Badge>
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
                      {endpoint.last_used_at ? relativeTime(endpoint.last_used_at) : "从未"}
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
  return (
    <div className="mx-auto max-w-xl space-y-5 py-4">
      <div>
        <h2 className="text-xl font-medium tracking-tight">保存「{name}」的令牌</h2>
        <p className="mt-1.5 text-sub leading-relaxed text-[var(--danger)]">
          令牌只显示这一次。离开这一屏就再也看不到明文——服务端只保存哈希。
          丢了不要紧，随时可以轮换出一枚新的（旧的立即失效）。
        </p>
      </div>

      <div className="space-y-2">
        <p className="text-caption text-[var(--text-muted)]">端点地址</p>
        <CopyField value={url} label="复制地址" />
        <p className="pt-1 text-caption text-[var(--text-muted)]">访问令牌</p>
        <CopyField value={token} label="复制令牌" />
      </div>

      <div>
        <p className="mb-2 text-caption text-[var(--text-muted)]">在客户端加上它</p>
        <CodeBlock
          lang="bash"
          code={`claude mcp add --transport http movieclaw \\\n  ${url} \\\n  --header "Authorization: Bearer ${token}"`}
        />
      </div>

      <div className="flex justify-end">
        <button type="button" onClick={onDone} className={SETTINGS_PRIMARY_BUTTON_CLASS}>
          我已保存，去看端点
        </button>
      </div>
    </div>
  );
}
