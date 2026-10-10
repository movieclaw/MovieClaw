"use client";

import type { Route } from "next";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { type ComponentType, useCallback, useEffect, useState } from "react";

import { Banner, ErrorBanner, LINK_CLASS, StatusPill } from "@/components/cloud-push-ui";
import { CopyButton } from "@/components/copy-button";
import { useConfirm, useToast } from "@/components/feedback";
import {
  ActivityIcon,
  BellIcon,
  BranchIcon,
  ChatBubblesIcon,
  ChevronLeftIcon,
  ChevronRightIcon,
  ClockIcon,
  CodeIcon,
  FolderGearIcon,
  FolderIcon,
  GearIcon,
  ServerIcon,
  TerminalIcon,
  TrashIcon,
} from "@/components/icons";
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

  // 桌面端回列表的入口；手机端页顶的返回键已回到插件列表，不再重复
  const back = (
    <Link
      href={"/settings/plugins" as Route}
      className="inline-flex items-center gap-1 text-sub max-md:hidden text-[var(--text-muted)] hover:text-[var(--text)]"
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
    detail.kind === "package" || detail.kind === "local"
      ? detail.plugin.runtime === "inline"
        ? "主进程"
        : "独立进程"
      : null,
    pkg?.installed_at ? `安装于 ${formatDateTime(new Date(pkg.installed_at * 1000).toISOString())}` : null,
    pkg?.replaces_builtin ? "替换了内置版本，卸载即恢复" : null,
  ].filter(Boolean);
  const degraded = degradedHealth(p);

  const rollback = async () => {
    if (!pkg?.previous_version) return;
    const ok = await confirm({
      title: `回到上一版 v${pkg.previous_version}？`,
      bullets: [
        `代码换回 v${pkg.previous_version}，当场重新加载`,
        "权限也回到当时批准的那套",
        "插件数据不变；想再换回来，再点一次即可",
      ],
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
            {/* 内核给独立进程的条目标题加了「（独立进程）」后缀；运行方式已在下面的元信息里 */}
            <h2 className="text-title font-semibold text-[var(--text)]">{p.title.replace(/（独立进程）$/, "")}</h2>
            <StatusPill tone={pluginStateTone(state)} label={pluginStateLabel(state)} />
          </div>
          {detail.description && (
            <p className="text-body leading-relaxed text-[var(--text-muted)]">{detail.description}</p>
          )}
          {state !== "active" && !needsAttention(p) && (
            <p className="text-sub text-[var(--text-muted)]">{pluginDetail(p)}</p>
          )}
          <p className="text-caption text-[var(--text-faint)]">{meta.join(" · ")}</p>
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

      <SettingsSection title="它做什么">
        {detail.adds.length === 0 ? (
          <p className="px-1 text-sub text-[var(--text-muted)]">
            {state !== "active"
              ? "插件没在运行，看不到它登记的功能；运行起来后这里会列出来。"
              : detail.kind === "system"
                ? "这是应用内部的基础能力，没有直接对外的功能。"
                : "目前没有对外的功能。"}
          </p>
        ) : (
          <SettingsList>
            {detail.adds.map((a, index) => {
              const Icon = ADD_ICON[a.kind] ?? GearIcon;
              // 同一个去处（几个定时任务都去「定时任务」）只在第一条给链接
              const href = detail.adds.findIndex((b) => b.href === a.href) === index ? a.href : null;
              return (
                <SettingsRow
                  key={`${a.kind}:${a.title}`}
                  leading={
                    <span className="flex size-8 shrink-0 items-center justify-center rounded-lg bg-white/[0.06] text-[var(--text-muted)]">
                      <Icon className="size-[18px]" />
                    </span>
                  }
                  label={a.kind === "command" ? <code className="font-mono text-sub">{a.title}</code> : a.title}
                  description={a.detail || undefined}
                >
                  {href && <GoLink href={href} />}
                </SettingsRow>
              );
            })}
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
        <div className="space-y-1.5 px-1">
          <p className="text-sub text-[var(--text-muted)]">
            已存 <span className="tnum text-[var(--text)]">{detail.data_rows}</span> 条数据，私有目录占用{" "}
            <span className="tnum text-[var(--text)]">{formatBytes(detail.disk_bytes)}</span>
          </p>
          {detail.data_path && (
            <p className="flex items-center gap-2 font-mono text-caption text-[var(--text-faint)]">
              <FolderIcon className="size-3.5 shrink-0" />
              <span className="min-w-0 break-all">{detail.data_path}</span>
            </p>
          )}
          {detail.kind === "package" && (
            <p className="text-caption leading-5 text-[var(--text-faint)]">
              卸载时默认保留，重新安装后接着用；它改过的系统数据（比如建过的订阅）不会被撤销
            </p>
          )}
        </div>
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

      {detail.source && <SourceFooter source={detail.source} />}
    </div>
  );
}

/** 页脚：源码在哪（入口名称 + 所在路径），淡色小字，不抢正文 */
function SourceFooter({ source }: { source: NonNullable<PluginDetail["source"]> }) {
  return (
    <footer className="space-y-1.5 px-1 font-mono text-caption text-[var(--text-faint)]">
      {source.entry && (
        <p className="flex items-center gap-2">
          <CodeIcon className="size-3.5 shrink-0" />
          <span className="min-w-0 break-all">{source.entry}</span>
        </p>
      )}
      <p className="flex items-center gap-2">
        <FolderIcon className="size-3.5 shrink-0" />
        <span className="min-w-0 break-all">{source.path}</span>
        <CopyButton text={source.path} className="shrink-0" />
      </p>
    </footer>
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

/** 「它做什么」每类登记的图标（按类别，不按插件） */
const ADD_ICON: Record<string, ComponentType<{ className?: string }>> = {
  channel: ChatBubblesIcon,
  task: ClockIcon,
  ingest: FolderGearIcon,
  job: ActivityIcon,
  site: ServerIcon,
  command: TerminalIcon,
  trigger: BellIcon,
  decision: BranchIcon,
  delete: TrashIcon,
};

/** 行尾的「查看 ›」：说明性的行不做成整行可点，跳转只占这几个字 */
function GoLink({ href }: { href: string }) {
  return (
    <Link
      href={href as Route}
      className="inline-flex items-center text-sub text-[var(--accent)] hover:opacity-80"
    >
      查看
      <ChevronRightIcon className="size-3.5" />
    </Link>
  );
}

/**
 * 权限：第三方插件最要紧的信任信息。只列清单里真实申请、安装时批准的项，没申请的不列
 * 「无」；每项按风险分级（LEVELS）标色，高的排前面。官方与系统模块是随应用提供的受信代码。
 */
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
  const grants: Grant[] = [];
  if (detail.plugin.runtime === "inline") {
    grants.push({ level: "high", title: "在主程序里运行", detail: "与主程序同权限，不受下面这些限制" });
  }
  for (const op of pkg.operations) {
    grants.push({ level: op.dangerous ? "high" : "low", title: op.summary });
  }
  for (const grant of pkg.paths) {
    grants.push({ level: grant.mode === "rw" ? "medium" : "low", title: `访问${pathGrantLabel(grant)}` });
  }
  if (pkg.callbacks.length > 0) {
    grants.push({
      level: "medium",
      title: `开放回调地址：${pkg.callbacks.join("、")}`,
      detail: `外部平台不用登录就能调进来${detail.callbacks.length > 0 ? "，地址见下方" : ""}`,
    });
  }
  if (detail.network) grants.push({ level: "low", title: "访问外部网络", detail: "走你的代理设置" });
  grants.sort((a, b) => LEVELS[a.level].order - LEVELS[b.level].order);
  return (
    <SettingsSection title="权限" description="安装时你批准的，它只能做这些。">
      <SettingsList>
        {grants.length === 0 ? (
          <GrantRow
            grant={{ level: "none", title: "不需要额外权限", detail: "不调用系统操作、不联网，只读写它自己的目录" }}
          />
        ) : (
          grants.map((g) => <GrantRow key={g.title} grant={g} />)
        )}
      </SettingsList>
    </SettingsSection>
  );
}

/** 权限的风险等级：按权限的种类与模式定，不按插件 */
const LEVELS = {
  high: { order: 0, label: "高风险", color: "var(--danger)" },
  medium: { order: 1, label: "需留意", color: "var(--warn)" },
  low: { order: 2, label: "低风险", color: "var(--ok)" },
  none: { order: 3, label: "无风险", color: "var(--ok)" },
} as const;

type Grant = { level: keyof typeof LEVELS; title: string; detail?: string };

function GrantRow({ grant }: { grant: Grant }) {
  const level = LEVELS[grant.level];
  return (
    <SettingsRow
      leading={<span className="size-2 shrink-0 rounded-full" style={{ background: level.color }} />}
      label={grant.title}
      description={
        <>
          <span style={{ color: level.color }}>{level.label}</span>
          {grant.detail && ` · ${grant.detail}`}
        </>
      }
    />
  );
}
