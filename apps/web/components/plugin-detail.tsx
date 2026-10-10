"use client";

import type { Route } from "next";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useCallback, useEffect, useState } from "react";

import { Banner, ErrorBanner, LINK_CLASS, StatusPill } from "@/components/cloud-push-ui";
import { CopyButton } from "@/components/copy-button";
import { useConfirm, useToast } from "@/components/feedback";
import { ChevronLeftIcon } from "@/components/icons";
import {
  SETTINGS_BUTTON_CLASS,
  SETTINGS_DANGER_BUTTON_CLASS,
  SettingsList,
  SettingsMoreMenu,
  SettingsRow,
  SettingsSection,
} from "@/components/settings-ui";
import {
  dismissDeadLetter,
  getPluginDetail,
  type PluginDetail,
  replayDeadLetter,
  revokeCallback,
  rollbackPackage,
  rotateCallback,
  uninstallPackage,
} from "@/lib/api/plugins";
import { formatBytes } from "@/lib/format";
import {
  degradedHealth,
  displayState,
  formatMs,
  needsAttention,
  pathGrantLabel,
  pluginDetail,
  pluginLogsHref,
  pluginStateLabel,
  pluginStateTone,
  runtimeLabel,
} from "@/lib/plugins-display";
import { formatDateTime, formatRelativeTime } from "@/lib/time";

/**
 * 插件详情（设置 → 插件 → 点一个插件）：按用户关心的问题组织，而不是把内核记的都摊开。
 *
 *   1. 它是什么、谁提供的；2. 现在好不好、不好怎么办；3. 给了它什么权限；
 *   4. 装了它系统多了什么；5. 最近的处理（积压、搁置的事件、回调地址）；6. 存了什么；
 *   7. 能做的操作。内核细节（服务、契约、耗时）收进最底下的「技术信息」。
 */

const KIND_LABEL: Record<PluginDetail["kind"], string> = {
  official: "官方插件",
  package: "第三方插件",
  local: "本地插件",
  system: "系统模块",
};

export function PluginDetailView({ id }: { id: string }) {
  const router = useRouter();
  const toast = useToast();
  const confirm = useConfirm();
  const [detail, setDetail] = useState<PluginDetail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  /** 刚换出来的回调地址：完整地址只在这一刻拿得到 */
  const [freshUrl, setFreshUrl] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      setDetail(await getPluginDetail(id));
      setError(null);
    } catch (e) {
      setError((e as Error).message);
    }
  }, [id]);

  useEffect(() => {
    void load();
  }, [load]);

  const run = async (action: () => Promise<void>) => {
    setBusy(true);
    try {
      await action();
      await load();
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  const back = (
    <Link
      href={"/settings/plugins" as Route}
      className="inline-flex items-center gap-1 text-sub text-[var(--text-muted)] hover:text-[var(--text)]"
    >
      <ChevronLeftIcon className="size-4" />
      插件
    </Link>
  );

  if (detail == null) {
    return (
      <div className="space-y-6">
        {back}
        {error ? <ErrorBanner>{error}</ErrorBanner> : <p className="text-sub text-[var(--text-muted)]">正在加载…</p>}
      </div>
    );
  }

  const p = detail.plugin;
  const state = displayState(p);
  const pkg = detail.package;
  const meta = [
    KIND_LABEL[detail.kind],
    detail.version ? `v${detail.version}` : null,
    pkg?.installed_at ? `安装于 ${formatDateTime(new Date(pkg.installed_at * 1000).toISOString())}` : null,
    pkg?.replaces_builtin ? "替换了内置版本，卸载即恢复" : null,
  ].filter(Boolean);
  const degraded = degradedHealth(p);

  const rollback = async () => {
    if (!pkg?.previous_version) return;
    const ok = await confirm({
      title: `回到上一版 v${pkg.previous_version}？`,
      confirmLabel: "回到上一版",
    });
    if (!ok) return;
    await run(async () => {
      await rollbackPackage(p.id);
      toast.success(`已回到 v${pkg.previous_version}`);
    });
  };

  const uninstall = async () => {
    const result = await confirm({
      title: `卸载「${p.title}」？`,
      bullets: ["停止并移除插件", "撤销它的权限，回调地址一起作废", "删除已安装的版本文件"],
      confirmLabel: "卸载",
      tone: "danger",
      checkbox: {
        label: "连同插件数据一起删除",
        description: "它保存的设置与状态；不勾则保留，重新安装后接着用。",
      },
    });
    if (!result.ok) return;
    setBusy(true);
    try {
      await uninstallPackage(p.id, result.checked);
      toast.success("已卸载");
      router.push("/settings/plugins" as Route);
    } catch (e) {
      toast.error((e as Error).message);
      setBusy(false);
    }
  };

  return (
    <div className="space-y-10">
      <div className="space-y-4">
        {back}
        <div className="space-y-2">
          <div className="flex flex-wrap items-center gap-3">
            <h2 className="text-title font-semibold text-[var(--text)]">{p.title}</h2>
            <StatusPill tone={pluginStateTone(state)} label={pluginStateLabel(state)} />
          </div>
          <p className="text-caption text-[var(--text-faint)]">{meta.join(" · ")}</p>
          {state !== "active" && !needsAttention(p) && (
            <p className="text-sub text-[var(--text-muted)]">{pluginDetail(p)}</p>
          )}
          {detail.description && (
            <p className="text-sub leading-relaxed text-[var(--text-muted)]">{detail.description}</p>
          )}
        </div>
      </div>

      {(needsAttention(p) || degraded.length > 0) && (
        <Banner tone="warn" title={state === "active" ? "运行异常" : "没有正常运行"}>
          <p className="text-sub leading-5 text-[var(--text-muted)]">{pluginDetail(p)}</p>
          <p className="mt-2 text-sub">
            <Link href={pluginLogsHref(p) as Route} className={LINK_CLASS}>
              查看它的日志
            </Link>
            {pkg?.previous_version && "，或回到上一版"}
          </p>
        </Banner>
      )}

      <SettingsSection title="它给系统加了什么" description="装了它之后多出来的功能、它在什么时候被触发、会影响哪些判断。">
        {detail.adds.length === 0 ? (
          <p className="px-1 text-sub text-[var(--text-muted)]">
            {detail.kind === "system" ? "这是应用内部的基础能力，没有直接对外的功能。" : "目前没有对外的功能。"}
          </p>
        ) : (
          <SettingsList>
            {detail.adds.map((a) => (
              <SettingsRow
                key={`${a.kind}:${a.title}`}
                label={a.kind === "command" ? <code className="font-mono text-sub">{a.title}</code> : a.title}
                description={a.detail || undefined}
                href={a.href ?? undefined}
              />
            ))}
          </SettingsList>
        )}
      </SettingsSection>

      <Permissions detail={detail} />

      {detail.callbacks.length > 0 && (
        <SettingsSection
          title="回调地址"
          description="外部平台（如企业微信）往这些地址推消息。地址里带密钥，可以随时换或作废；卸载插件即失效。"
        >
          {freshUrl && (
            <div className="mb-3 space-y-2 rounded-xl border border-white/[0.08] bg-black/[0.28] px-4 py-3">
              <div className="flex items-center justify-between gap-3">
                <span className="text-sub font-medium text-[var(--text)]">新地址（只显示这一次，记得填到平台后台）</span>
                <CopyButton text={freshUrl} label="复制" className={SETTINGS_BUTTON_CLASS} />
              </div>
              <p className="select-all break-all font-mono text-caption text-[var(--text)]">{freshUrl}</p>
            </div>
          )}
          <SettingsList>
            {detail.callbacks.map((c) => (
              <SettingsRow
                key={c.id}
                label={<code className="break-all font-mono text-sub">{c.url}</code>}
                description={[
                  c.running ? null : "插件没在运行，调进来会回 503",
                  `调用 ${c.calls} 次`,
                  c.failures > 0 ? `验证失败 ${c.failures} 次` : null,
                  c.last_called_at ? `最近 ${formatRelativeTime(c.last_called_at)}` : "还没被调用过",
                ]
                  .filter(Boolean)
                  .join(" · ")}
              >
                <SettingsMoreMenu
                  label="回调地址的操作"
                  disabled={busy}
                  items={[
                    {
                      label: "换一个地址",
                      warn: true,
                      onSelect: async () => {
                        const ok = await confirm({
                          title: "换一个回调地址？",
                          bullets: ["旧地址立即失效", "新地址要重新填到平台后台"],
                          confirmLabel: "换地址",
                        });
                        if (!ok) return;
                        await run(async () => {
                          setFreshUrl((await rotateCallback(c.id)).url);
                        });
                      },
                    },
                    {
                      label: "作废",
                      danger: true,
                      onSelect: async () => {
                        const ok = await confirm({
                          title: "作废这个回调地址？",
                          bullets: ["平台再调进来一律失败"],
                          confirmLabel: "作废",
                          tone: "danger",
                        });
                        if (!ok) return;
                        await run(async () => {
                          await revokeCallback(c.id);
                          toast.success("已作废");
                        });
                      },
                    },
                  ]}
                />
              </SettingsRow>
            ))}
          </SettingsList>
        </SettingsSection>
      )}

      {(detail.consumers.length > 0 || detail.dead_letters.length > 0) && (
        <SettingsSection
          title="最近的处理"
          description="它订阅的事件处理到哪了；失败多次、被搁置下来的事件可以重新处理或忽略。"
        >
          <SettingsList>
            {detail.consumers.map((c) => (
              <SettingsRow
                key={c.consumer_id}
                label={`「${c.title}」`}
                description={[
                  c.backlog > 0 ? `还有 ${c.backlog} 件待处理` : "都处理完了",
                  c.attempts > 0 ? `当前这件已失败 ${c.attempts} 次：${c.last_error ?? ""}` : null,
                  c.active ? null : "插件没在运行，恢复后接着处理",
                ]
                  .filter(Boolean)
                  .join(" · ")}
              />
            ))}
            {detail.dead_letters.map((d) => (
              <SettingsRow
                key={d.id}
                label={`搁置的事件：「${d.title}」`}
                description={`${formatRelativeTime(d.created_at)} · 失败 ${d.attempts} 次 · ${d.error}`}
              >
                <button
                  type="button"
                  disabled={busy}
                  className={SETTINGS_BUTTON_CLASS}
                  onClick={() =>
                    void run(async () => {
                      await replayDeadLetter(d.id);
                      toast.success("已重新交给插件处理");
                    })
                  }
                >
                  重新处理
                </button>
                <button
                  type="button"
                  disabled={busy}
                  className={SETTINGS_BUTTON_CLASS}
                  onClick={() =>
                    void run(async () => {
                      await dismissDeadLetter(d.id);
                    })
                  }
                >
                  忽略
                </button>
              </SettingsRow>
            ))}
          </SettingsList>
        </SettingsSection>
      )}

      <SettingsSection title="存储">
        <SettingsList>
          <SettingsRow
            label="插件数据"
            description={
              detail.kind === "package"
                ? "卸载时默认保留，重新安装后接着用；它改过的系统数据（比如建过的订阅）不会被撤销"
                : undefined
            }
          >
            <span className="text-sub text-[var(--text-muted)]">
              {detail.data_rows} 条 · {formatBytes(detail.disk_bytes)}
            </span>
          </SettingsRow>
        </SettingsList>
      </SettingsSection>

      {pkg && (
        <SettingsSection title="操作">
          <div className="flex flex-wrap gap-3">
            {pkg.previous_version && (
              <button type="button" disabled={busy} className={SETTINGS_BUTTON_CLASS} onClick={() => void rollback()}>
                回到上一版 v{pkg.previous_version}
              </button>
            )}
            <button type="button" disabled={busy} className={SETTINGS_DANGER_BUTTON_CLASS} onClick={() => void uninstall()}>
              卸载
            </button>
          </div>
          {pkg.bad_versions.length > 0 && (
            <p className="mt-3 px-1 text-caption text-[var(--text-faint)]">
              起不来、已自动回退过的版本：{pkg.bad_versions.map((v) => `v${v}`).join("、")}
            </p>
          )}
        </SettingsSection>
      )}

      <details className="group rounded-xl border border-[var(--line)] px-4 py-3">
        <summary className="cursor-pointer text-sub text-[var(--text-muted)] hover:text-[var(--text)]">
          技术信息（排查问题时用）
        </summary>
        <dl className="mt-3 grid grid-cols-[auto_1fr] gap-x-4 gap-y-1.5 text-caption">
          <TechRow label="条目 id" value={p.id} />
          <TechRow label="来源" value={p.source} />
          <TechRow label="运行方式" value={runtimeLabel(p.runtime)} />
          <TechRow label="启动耗时" value={p.apply_ms != null ? formatMs(p.apply_ms) : "—"} />
          <TechRow label="用到的服务" value={p.inject.join("、") || "—"} />
          <TechRow label="提供的服务" value={p.provides.join("、") || "—"} />
          <TechRow label="宿主操作" value={(p.permissions ?? []).join("、") || "—"} />
          <TechRow
            label="处理统计"
            value={`平均 ${formatMs(p.stats.handler_avg_ms)} · 失败 ${p.stats.failures} · 超时 ${p.stats.timeouts} · 熔断 ${p.stats.breaker}`}
          />
          {detail.children.length > 0 && <TechRow label="子条目" value={detail.children.join("、")} />}
        </dl>
      </details>
    </div>
  );
}

function TechRow({ label, value }: { label: string; value: string }) {
  return (
    <>
      <dt className="text-[var(--text-faint)]">{label}</dt>
      <dd className="break-all font-mono text-[var(--text-muted)]">{value}</dd>
    </>
  );
}

/** 权限：第三方插件最要紧的信任信息；官方与系统模块是随应用提供的受信代码 */
function Permissions({ detail }: { detail: PluginDetail }) {
  const pkg = detail.package;
  if (!pkg) {
    if (detail.kind === "system") return null;
    return (
      <SettingsSection title="权限">
        <p className="px-1 text-sub leading-relaxed text-[var(--text-muted)]">
          {detail.kind === "official"
            ? "随 MovieClaw 提供的受信代码，在主程序里运行。"
            : `你在 data/plugins.yaml 里开启的本地插件（${runtimeLabel(detail.plugin.runtime)}），权限也在那里配置。`}
        </p>
      </SettingsSection>
    );
  }
  return (
    <SettingsSection title="权限" description="安装时你批准给它的；它只能做这些事。">
      <SettingsList>
        <SettingsRow
          label="能调用的操作"
          description={
            pkg.operations.length === 0 ? (
              "不调用任何系统操作"
            ) : (
              <span className="flex flex-col gap-1">
                {pkg.operations.map((op) => (
                  <span key={op.id} className={op.dangerous ? "text-[var(--danger)]" : undefined}>
                    {op.summary}
                    {op.dangerous && "（危险操作）"}
                  </span>
                ))}
              </span>
            )
          }
        />
        <SettingsRow
          label="能读写的目录"
          description={pkg.paths.length === 0 ? "只用它自己的目录" : pkg.paths.map(pathGrantLabel).join("；")}
        />
        <SettingsRow
          label="联网"
          description={detail.network ? "会访问外部网络（按你的代理设置走）" : "不联网"}
        />
        <SettingsRow label="运行方式" description={runtimeLabel(detail.plugin.runtime)} />
        {pkg.callbacks.length > 0 && (
          <SettingsRow
            label="开放的回调端点"
            description={`${pkg.callbacks.join("、")}：外部平台不用登录就能调进来的地址`}
          />
        )}
      </SettingsList>
    </SettingsSection>
  );
}
