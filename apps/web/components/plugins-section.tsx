"use client";

import { useCallback, useEffect, useState } from "react";

import { Banner, ErrorBanner, StatusPill } from "@/components/cloud-push-ui";
import { PluginPackagesSection } from "@/components/plugin-packages-section";
import { SettingsList, SettingsRow, SettingsSection, SettingsTabs } from "@/components/settings-ui";
import {
  exitSafeMode,
  listPlugins,
  type PluginInfo,
  type PluginsOverview,
} from "@/lib/api/plugins";
import {
  builtinBadge,
  formatMs,
  groupBuiltins,
  isBuiltinPlugin,
  isLocalPlugin,
  needsAttention,
  pluginDetail,
  pluginStateLabel,
  pluginStateTone,
  pluginsSummary,
  slowestStarts,
} from "@/lib/plugins-display";
import { useTabParam } from "@/lib/use-tab-param";

/**
 * 设置 → 插件（系统组）：「插件」是总称，分两个页签（概念见 lib/plugins-display.ts 文件头）。
 *
 *   - 已安装：第三方插件（插件包的上传、批准、回滚、卸载）与本地插件（只读）；
 *   - 内置：MovieClaw 自带功能的运行状态，按功能分组，只读——排查「某个功能怎么没起来」
 *     「启动为什么慢」时看这里。关闭可关闭的内置插件走 data/plugins.yaml，重启生效
 *     （docs/design/plugin-kernel.md §10）。
 *
 * 安全模式影响整页（本地 / 第三方插件都被跳过），横幅放在页签之上。两个页签共用一份
 * 插件列表：已安装页签的操作（批准、卸载）做完顺手刷新它。
 */
export function PluginsPage() {
  const [tab, setTab] = useTabParam(["installed", "builtin"] as const, "installed");
  const [overview, setOverview] = useState<PluginsOverview | null>(null);
  const [exiting, setExiting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const reload = useCallback(() => {
    listPlugins()
      .then((value) => {
        setOverview(value);
        setError(null);
      })
      .catch((err: unknown) => setError(err instanceof Error ? err.message : "加载失败"));
  }, []);
  useEffect(() => {
    reload();
  }, [reload]);

  const leaveSafeMode = useCallback(() => {
    setExiting(true);
    exitSafeMode()
      .then(() => reload())
      .catch((err: unknown) => setError(err instanceof Error ? err.message : "退出失败"))
      .finally(() => setExiting(false));
  }, [reload]);

  const plugins = overview?.plugins ?? null;
  const safeMode = overview?.safe_mode;
  const builtinProblems = plugins?.filter((p) => isBuiltinPlugin(p) && needsAttention(p)).length ?? 0;
  const tabs = [
    { id: "installed" as const, label: "已安装" },
    {
      id: "builtin" as const,
      label: builtinProblems > 0 ? `内置 · ${builtinProblems} 个需要留意` : "内置",
    },
  ];

  return (
    <div className="space-y-8">
      {error && <ErrorBanner>{error}</ErrorBanner>}
      {safeMode?.active && (
        <Banner
          tone="warn"
          title="插件安全模式：本次没有加载本地 / 第三方插件"
          action={
            safeMode.forced === "env" ? undefined : (
              <button
                type="button"
                disabled={exiting}
                onClick={leaveSafeMode}
                className="btn-accent inline-flex rounded-full px-4 py-1.5 text-sub font-semibold disabled:opacity-60"
              >
                {exiting ? "正在加载…" : "退出安全模式"}
              </button>
            )
          }
        >
          {safeMode.reason}。跳过的插件：{safeMode.skipped.join("、") || "无"}。
          {safeMode.forced === "env"
            ? "去掉环境变量 MOVIECLAW_SAFE_MODE 并重启即可退出。"
            : "排查后退出，被跳过的插件会当场重新加载；它若再把应用拖垮，下次启动会自动回到安全模式。"}
        </Banner>
      )}
      <SettingsTabs tabs={tabs} value={tab} onChange={setTab} />
      {tab === "installed" && (
        <PluginPackagesSection locals={plugins?.filter(isLocalPlugin) ?? []} onChanged={reload} />
      )}
      {tab === "builtin" &&
        (plugins === null ? (
          !error && <p className="px-1 text-sub text-[var(--text-muted)]">正在加载…</p>
        ) : (
          <BuiltinPlugins plugins={plugins} groups={overview?.groups ?? []} />
        ))}
    </div>
  );
}

function BuiltinPlugins({ plugins, groups }: { plugins: PluginInfo[]; groups: string[] }) {
  const builtins = plugins.filter(isBuiltinPlugin);
  const problems = builtins.filter(needsAttention);
  const slow = slowestStarts(builtins);

  return (
    <div className="space-y-10">
      <div className="space-y-3">
        <p className="px-1 text-sub leading-relaxed text-[var(--text-muted)]">
          MovieClaw 自带的功能都以内置插件的形式运行，一个出问题只影响它自己，其余功能照常。
          标「核心」的是应用运行的根基，不能关闭；标「可关闭」的不需要时可以在 data/plugins.yaml
          里关掉，重启生效。
        </p>
        <p className="px-1 text-caption text-[var(--text-faint)]">
          {pluginsSummary(builtins)}
          {slow.length > 0 &&
            ` · 启动最慢：${slow.map((p) => `${p.title} ${formatMs(p.apply_ms ?? 0)}`).join("、")}`}
        </p>
        {problems.length > 0 && (
          <Banner tone="warn">
            有 {problems.length} 个内置插件没有正常运行，原因写在对应分组的行里；修复后重启应用即可恢复。
          </Banner>
        )}
      </div>
      {groupBuiltins(builtins, groups).map((group) => (
        <SettingsSection
          key={group.label}
          title={group.label}
          description={groupSummary(group.plugins)}
        >
          <SettingsList>
            {group.plugins.map((p) => (
              <BuiltinRow key={p.id} plugin={p} />
            ))}
          </SettingsList>
        </SettingsSection>
      ))}
    </div>
  );
}

function groupSummary(plugins: PluginInfo[]): string {
  const problems = plugins.filter(needsAttention).length;
  return problems > 0 ? `${plugins.length} 个 · ${problems} 个需要留意` : `${plugins.length} 个`;
}

function BuiltinRow({ plugin }: { plugin: PluginInfo }) {
  const badge = builtinBadge(plugin);
  return (
    <SettingsRow
      label={
        <span className="flex flex-wrap items-baseline gap-x-2">
          {plugin.title}
          {badge && (
            <span
              className={`text-caption font-medium ${
                badge === "核心" ? "text-[var(--accent)]" : "text-[var(--text-faint)]"
              }`}
            >
              {badge}
            </span>
          )}
          <span className="text-caption font-normal text-[var(--text-faint)]">{plugin.id}</span>
        </span>
      }
      description={pluginDetail(plugin)}
    >
      <StatusPill tone={pluginStateTone(plugin.state)} label={pluginStateLabel(plugin.state)} />
    </SettingsRow>
  );
}
