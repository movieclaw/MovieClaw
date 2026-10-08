"use client";

import { useCallback, useEffect, useState } from "react";

import { Banner, ErrorBanner, StatusPill } from "@/components/cloud-push-ui";
import { SettingsList, SettingsRow, SettingsSection } from "@/components/settings-ui";
import {
  exitSafeMode,
  listPlugins,
  type PluginInfo,
  type PluginSafeMode,
} from "@/lib/api/plugins";
import {
  formatMs,
  isLocalPlugin,
  needsAttention,
  pluginDetail,
  pluginStateLabel,
  pluginStateTone,
  pluginsSummary,
  slowestStarts,
  sortPlugins,
} from "@/lib/plugins-display";

/**
 * 设置 → 更新与维护 → 模块：后端各子系统（内置插件）的运行状态，只读。
 *
 * 用途是排查：某个功能怎么没起来（启动失败的原因、缺了哪个依赖）、启动为什么慢
 * （逐模块启动耗时）。第一阶段不放任何操作按钮——关闭某个模块走 data/plugins.yaml，
 * 重启生效（docs/design/plugin-kernel.md §10）。
 */
export function PluginsSection() {
  const [plugins, setPlugins] = useState<PluginInfo[] | null>(null);
  const [safeMode, setSafeMode] = useState<PluginSafeMode | null>(null);
  const [exiting, setExiting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const reload = useCallback(() => {
    listPlugins()
      .then((overview) => {
        setPlugins(overview.plugins);
        setSafeMode(overview.safe_mode ?? null);
        setError(null);
      })
      .catch((err: unknown) => setError(err instanceof Error ? err.message : "加载失败"));
  }, []);

  const leaveSafeMode = useCallback(() => {
    setExiting(true);
    exitSafeMode()
      .then(() => reload())
      .catch((err: unknown) => setError(err instanceof Error ? err.message : "退出失败"))
      .finally(() => setExiting(false));
  }, [reload]);
  useEffect(() => {
    reload();
  }, [reload]);

  const problems = plugins?.filter(needsAttention) ?? [];
  const locals = plugins?.filter(isLocalPlugin) ?? [];
  const slow = plugins ? slowestStarts(plugins) : [];

  return (
    <div className="space-y-10">
      <p className="px-1 text-sub leading-relaxed text-[var(--text-muted)]">
        后端的每个子系统都是一个独立模块：非关键模块启动失败只影响它自己，其余功能照常。
        这里看每个模块的状态与启动耗时。
      </p>
      <SettingsSection
        title="模块状态"
        description={plugins ? pluginsSummary(plugins) : undefined}
      >
        <div className="space-y-3">
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
          {problems.length > 0 && (
            <Banner tone="warn">
              有 {problems.length} 个模块没有正常运行，原因写在下面对应的行里；修复后重启应用即可恢复。
            </Banner>
          )}
          {locals.length > 0 && (
            <Banner tone="warn" title={`已开启 ${locals.length} 个本地插件`}>
              它们来自 data/plugins，在应用进程里运行，拥有与主程序相同的系统权限——只开启你信任的代码。
              要关掉某个本地插件：在 data/plugins.yaml 里去掉它的 local 或加上 disabled: true，重启生效。
            </Banner>
          )}
          {slow.length > 0 && (
            <p className="px-1 text-caption text-[var(--text-faint)]">
              启动最慢：{slow.map((p) => `${p.title} ${formatMs(p.apply_ms ?? 0)}`).join("、")}
            </p>
          )}
          {plugins === null ? (
            !error && <p className="px-1 text-sub text-[var(--text-muted)]">正在加载…</p>
          ) : (
            <SettingsList>
              {sortPlugins(plugins).map((p) => (
                <SettingsRow
                  key={p.id}
                  label={
                    <span className="flex flex-wrap items-baseline gap-x-2">
                      {p.title}
                      <span className="text-caption font-normal text-[var(--text-faint)]">
                        {p.id}
                      </span>
                      {isLocalPlugin(p) && (
                        <span className="text-caption font-medium text-[var(--warn)]">本地插件</span>
                      )}
                    </span>
                  }
                  description={pluginDetail(p)}
                >
                  <StatusPill tone={pluginStateTone(p.state)} label={pluginStateLabel(p.state)} />
                </SettingsRow>
              ))}
            </SettingsList>
          )}
        </div>
      </SettingsSection>
    </div>
  );
}
