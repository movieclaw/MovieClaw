"use client";

import { useCallback, useEffect, useState } from "react";

import { Banner, ErrorBanner, StatusPill } from "@/components/cloud-push-ui";
import { SettingsList, SettingsRow, SettingsSection } from "@/components/settings-ui";
import { listPlugins, type PluginInfo } from "@/lib/api/plugins";
import {
  formatMs,
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
  const [error, setError] = useState<string | null>(null);

  const reload = useCallback(() => {
    listPlugins()
      .then((overview) => {
        setPlugins(overview.plugins);
        setError(null);
      })
      .catch((err: unknown) => setError(err instanceof Error ? err.message : "加载失败"));
  }, []);
  useEffect(() => {
    reload();
  }, [reload]);

  const problems = plugins?.filter(needsAttention) ?? [];
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
          {problems.length > 0 && (
            <Banner tone="warn">
              有 {problems.length} 个模块没有正常运行，原因写在下面对应的行里；修复后重启应用即可恢复。
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
