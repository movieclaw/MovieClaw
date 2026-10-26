"use client";

import { useLocale, useTranslations } from "next-intl";

import type { Route } from "next";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { type ComponentType, type ReactNode, useCallback, useEffect, useState } from "react";

import { Banner, ErrorBanner, LINK_CLASS, StatusPill } from "@/components/cloud-push-ui";
import { CopyButton } from "@/components/copy-button";
import { fieldType, parseValue, SchemaForm, unsupportedField } from "@/components/schema-form";
import { useConfirm, useToast } from "@/components/feedback";
import {
  ActivityIcon,
  BellIcon,
  BranchIcon,
  ChatBubblesIcon,
  ChevronRightIcon,
  ClockIcon,
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
  SETTINGS_PRIMARY_BUTTON_CLASS,
  SettingsCard,
  SettingsList,
  SettingsMoreMenu,
  SettingsRow,
  SettingsSection,
} from "@/components/settings-ui";
import {
  dismissDeadLetter,
  getPluginDetail,
  getPluginSettings,
  type PluginDetail,
  type PluginSettings,
  replayDeadLetter,
  revokeCallback,
  rollbackPackage,
  rotateCallback,
  savePluginSettings,
  setPluginEnabled,
  uninstallBundled,
  uninstallPackage,
} from "@/lib/api/plugins";
import type { AppMessageKey } from "@/lib/i18n/translate";
import { formatList } from "@/lib/i18n/format";
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

const KIND_LABEL: Record<PluginDetail["kind"], AppMessageKey> = {
  official: "settings.plugins.official",
  package: "settings.pluginPackages.thirdParty",
  local: "settings.plugins.localPlugin",
  system: "settings.pluginDetail.system",
};

export function PluginDetailView({ id }: { id: string }) {
  const t = useTranslations();
  const locale = useLocale();
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

  if (detail == null) {
    return (
      <div className="space-y-6">
        {error ? <ErrorBanner>{error}</ErrorBanner> : <p className="text-sub text-[var(--text-muted)]">{t("settings.plugins.loading")}</p>}
      </div>
    );
  }

  const p = detail.plugin;
  const state = displayState(p);
  const pkg = detail.package;
  const meta = [
    t(KIND_LABEL[detail.kind]),
    detail.version ? `v${detail.version}` : null,
    detail.kind === "package" || detail.kind === "local"
      ? detail.plugin.runtime === "inline"
        ? t("settings.pluginDetail.inline")
        : t("settings.pluginDisplay.processRuntime")
      : null,
    pkg?.installed_at ? t("settings.pluginDetail.installedAt", { time: formatDateTime(new Date(pkg.installed_at * 1000).toISOString(), locale) }) : null,
    pkg?.replaces_builtin ? t("settings.pluginDisplay.replacesBuiltin") : null,
  ].filter(Boolean);
  const degraded = degradedHealth(p);

  const rollback = async () => {
    if (!pkg?.previous_version) return;
    const ok = await confirm({
      title: t("settings.pluginDetail.rollbackTitle", { version: pkg.previous_version }),
      bullets: [
        t("settings.pluginDetail.rollbackCode", { version: pkg.previous_version }),
        t("settings.pluginDetail.rollbackPermissions"),
        t("settings.pluginDetail.rollbackData"),
      ],
      confirmLabel: t("settings.pluginPackages.rollback"),
    });
    if (!ok) return;
    await run(async () => {
      await rollbackPackage(p.id);
      toast.success(t("settings.pluginPackages.rolledBack", { version: String(pkg.previous_version) }));
    });
  };

  const switchOff = async () => {
    const ok = await confirm({
      title: t("settings.pluginDetail.disableTitle", { name: p.title }),
      bullets: [t("settings.pluginDetail.stopNow"), t("settings.pluginDetail.cancelJobs"), t("settings.pluginDetail.keepData")],
      confirmLabel: t("settings.pluginDetail.disable"),
    });
    if (!ok) return;
    await run(async () => {
      await setPluginEnabled(p.id, false);
      toast.success(t("settings.pluginDetail.disabled"));
    });
  };

  const switchOn = () =>
    run(async () => {
      await setPluginEnabled(p.id, true);
      toast.success(t("settings.pluginDetail.enabled"));
    });

  const uninstall = async () => {
    const official = pkg == null;
    const result = await confirm({
      title: t("settings.pluginPackages.uninstallTitle", { name: p.title }),
      bullets: official
        ? [t("settings.pluginDetail.stopAndRemove"), t("settings.pluginDetail.restoreBundled")]
        : [t("settings.pluginDetail.stopAndRemove"), t("settings.pluginDetail.revokePermissions"), t("settings.pluginPackages.deleteVersions")],
      confirmLabel: t("settings.pluginPackages.uninstall"),
      tone: "danger",
      checkbox: {
        label: t("settings.pluginPackages.deleteData"),
        description: official
          ? t("settings.pluginDetail.retainBundledData")
          : t("settings.pluginDetail.retainPackageData"),
      },
    });
    if (!result.ok) return;
    setBusy(true);
    try {
      if (official) await uninstallBundled(p.id, result.checked);
      else await uninstallPackage(p.id, result.checked);
      toast.success(t("settings.plugins.removed"));
      router.push("/settings/plugins" as Route);
    } catch (e) {
      toast.error((e as Error).message);
      setBusy(false);
    }
  };

  return (
    <div className="space-y-10">
      <div className="space-y-4">
        <div className="space-y-2">
          <div className="flex flex-wrap items-center gap-3">
            <h2 className="text-title font-semibold text-[var(--text)]">{p.title}</h2>
            <StatusPill tone={pluginStateTone(state)} label={pluginStateLabel(state, locale)} />
          </div>
          {detail.description && (
            <p className="text-body leading-relaxed text-[var(--text-muted)]">{detail.description}</p>
          )}
          {state !== "active" && !needsAttention(p) && (
            <p className="text-sub text-[var(--text-muted)]">{pluginDetail(p, locale)}</p>
          )}
          <p className="text-caption text-[var(--text-faint)]">{meta.join(" · ")}</p>
        </div>
      </div>

      {(needsAttention(p) || degraded.length > 0) && (
        <Banner tone="warn" title={state === "active" ? t("settings.pluginDetail.degraded") : t("settings.pluginDetail.notRunning")}>
          <p className="text-sub leading-5 text-[var(--text-muted)]">{pluginDetail(p, locale)}</p>
          <p className="mt-2 text-sub">
            <Link href={pluginLogsHref(p) as Route} className={LINK_CLASS}>
              {t("settings.pluginDetail.viewLogs")}</Link>
            {pkg?.previous_version && t("settings.pluginDetail.orRollback")}
          </p>
        </Banner>
      )}

      <SettingsSection title={t("settings.pluginDetail.capabilities")}>
        {detail.adds.length === 0 ? (
          <p className="px-1 text-sub text-[var(--text-muted)]">
            {state !== "active"
              ? t("settings.pluginDetail.inactiveCapabilities")
              : detail.kind === "system"
                ? t("settings.pluginDetail.internalCapabilities")
                : t("settings.pluginDetail.noCapabilities")}
          </p>
        ) : (
          <SettingsList>
            {detail.adds.map((a) => {
              const Icon = ADD_ICON[a.kind] ?? GearIcon;
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
                  {a.href && <GoLink href={a.href} />}
                </SettingsRow>
              );
            })}
          </SettingsList>
        )}
      </SettingsSection>

      <PluginSettingsSection id={detail.plugin.id} />

      <Permissions detail={detail} />

      {detail.callbacks.length > 0 && (
        <SettingsSection
          title={t("settings.pluginDetail.callbacks")}
          description={t("settings.pluginDetail.callbacksHint")}
        >
          {freshUrl && (
            <div className="mb-3 space-y-2 rounded-xl border border-white/[0.08] bg-black/[0.28] px-4 py-3">
              <div className="flex items-center justify-between gap-3">
                <span className="text-sub font-medium text-[var(--text)]">{t("settings.pluginDetail.freshCallback")}</span>
                <CopyButton text={freshUrl} label={t("common.copy")} className={SETTINGS_BUTTON_CLASS} />
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
                  c.running ? null : t("settings.pluginDetail.callbackStopped"),
                  t("settings.pluginDetail.callbackCalls", { count: c.calls }),
                  c.failures > 0 ? t("settings.pluginDetail.callbackFailures", { count: c.failures }) : null,
                  c.last_called_at ? t("settings.pluginDetail.lastCalled", { time: formatRelativeTime(c.last_called_at, locale) }) : t("settings.pluginDetail.neverCalled"),
                ]
                  .filter(Boolean)
                  .join(" · ")}
              >
                <SettingsMoreMenu
                  label={t("settings.pluginDetail.callbackActions")}
                  disabled={busy}
                  items={[
                    {
                      label: t("settings.pluginDetail.rotateCallback"),
                      warn: true,
                      onSelect: async () => {
                        const ok = await confirm({
                          title: t("settings.pluginDetail.rotateTitle"),
                          bullets: [t("settings.pluginDetail.oldUrlInvalid"), t("settings.pluginDetail.newUrlRequired")],
                          confirmLabel: t("settings.pluginDetail.rotate"),
                        });
                        if (!ok) return;
                        await run(async () => {
                          setFreshUrl((await rotateCallback(c.id)).url);
                        });
                      },
                    },
                    {
                      label: t("settings.pluginDetail.revoke"),
                      danger: true,
                      onSelect: async () => {
                        const ok = await confirm({
                          title: t("settings.pluginDetail.revokeTitle"),
                          bullets: [t("settings.pluginDetail.revokeHint")],
                          confirmLabel: t("settings.pluginDetail.revoke"),
                          tone: "danger",
                        });
                        if (!ok) return;
                        await run(async () => {
                          await revokeCallback(c.id);
                          toast.success(t("settings.pluginDetail.revoked"));
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
          title={t("settings.pluginDetail.recentProcessing")}
          description={t("settings.pluginDetail.processingHint")}
        >
          <SettingsList>
            {detail.consumers.map((c) => (
              <SettingsRow
                key={c.consumer_id}
                label={t("settings.pluginDetail.consumerTitle", { name: c.title })}
                description={[
                  c.backlog > 0 ? t("settings.pluginDetail.backlog", { count: c.backlog }) : t("settings.pluginDetail.caughtUp"),
                  c.attempts > 0 ? t("settings.pluginDetail.attemptFailed", { count: c.attempts, reason: c.last_error ?? "" }) : null,
                  c.active ? null : t("settings.pluginDetail.consumerStopped"),
                ]
                  .filter(Boolean)
                  .join(" · ")}
              />
            ))}
            {detail.dead_letters.map((d) => (
              <SettingsRow
                key={d.id}
                label={t("settings.pluginDetail.deadLetter", { name: d.title })}
                description={t("settings.pluginDetail.deadDetail", { time: formatRelativeTime(d.created_at, locale), count: d.attempts, reason: d.error })}
              >
                <button
                  type="button"
                  disabled={busy}
                  className={SETTINGS_BUTTON_CLASS}
                  onClick={() =>
                    void run(async () => {
                      await replayDeadLetter(d.id);
                      toast.success(t("settings.pluginDetail.retried"));
                    })
                  }
                >
                  {t("settings.pluginDetail.retry")}</button>
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
                  {t("settings.pluginDetail.ignore")}</button>
              </SettingsRow>
            ))}
          </SettingsList>
        </SettingsSection>
      )}

      <SettingsSection title={t("settings.pluginDetail.storage")}>
        <div className="space-y-1.5 px-1">
          <p className="text-sub text-[var(--text-muted)]">
            {t.rich("settings.pluginDetail.dataSummary", { count: detail.data_rows, size: formatBytes(detail.disk_bytes), records: (chunks) => <span className="tnum text-[var(--text)]">{chunks}</span>, bytes: (chunks) => <span className="tnum text-[var(--text)]">{chunks}</span> })}
          </p>
          {detail.data_path && (
            <p className="flex items-center gap-2 font-mono text-caption text-[var(--text-faint)]">
              <FolderIcon className="size-3.5 shrink-0" />
              <span className="min-w-0 break-all">{detail.data_path}</span>
            </p>
          )}
          {(detail.kind === "package" || p.removable) && (
            <p className="text-caption leading-5 text-[var(--text-faint)]">
              {p.removable ? t("settings.pluginDetail.retainDataRestore") : t("settings.pluginDetail.retainDataReinstall")}
            </p>
          )}
        </div>
      </SettingsSection>

      {(pkg || p.switchable) && (
        <SettingsSection title={t("settings.pluginDetail.actions")}>
          <div className="flex flex-wrap gap-3">
            {p.switchable &&
              (p.state === "disabled" ? (
                <button
                  type="button"
                  disabled={busy || p.locked_by != null}
                  className={SETTINGS_PRIMARY_BUTTON_CLASS}
                  onClick={() => void switchOn()}
                >
                  {t("settings.pluginDetail.enable")}</button>
              ) : (
                <button
                  type="button"
                  disabled={busy || p.locked_by != null}
                  className={SETTINGS_BUTTON_CLASS}
                  onClick={() => void switchOff()}
                >
                  {t("settings.pluginDetail.disable")}</button>
              ))}
            {pkg?.previous_version && (
              <button type="button" disabled={busy} className={SETTINGS_BUTTON_CLASS} onClick={() => void rollback()}>
                {t("settings.pluginPackages.previousVersion", { version: pkg.previous_version })}
              </button>
            )}
            {(pkg || p.removable) && (
              <button
                type="button"
                disabled={busy || p.locked_by != null}
                className={SETTINGS_DANGER_BUTTON_CLASS}
                onClick={() => void uninstall()}
              >
                {t("settings.pluginPackages.uninstall")}</button>
            )}
          </div>
          {p.locked_by && (
            <p className="mt-3 px-1 text-caption text-[var(--text-faint)]">
              {t("settings.pluginDetail.lockedHint", { reason: p.locked_by })}
            </p>
          )}
          {pkg && pkg.bad_versions.length > 0 && (
            <p className="mt-3 px-1 text-caption text-[var(--text-faint)]">
              {t("settings.pluginDetail.badVersions", { versions: formatList(pkg.bad_versions.map((v) => `v${v}`), locale) })}
            </p>
          )}
        </SettingsSection>
      )}

      <Diagnostics detail={detail} />
    </div>
  );
}

/**
 * 诊断信息（排查问题时用，默认收起）：源码位置、运行情况、依赖与授权。
 * 源码位置只在这里出现一次；值用等宽字，列表用小标签，空的写「—」。
 */
function Diagnostics({ detail }: { detail: PluginDetail }) {
  const t = useTranslations();
  const locale = useLocale();
  const p = detail.plugin;
  const source = detail.source;
  return (
    <details className="group css-glass overflow-hidden !rounded-xl">
      <summary className="flex cursor-pointer list-none items-center gap-2 px-4 py-3 text-sub text-[var(--text-muted)] hover:text-[var(--text)] [&::-webkit-details-marker]:hidden">
        <span className="flex-1 font-medium">{t("settings.pluginDetail.diagnostics")}</span>
        <span className="text-caption text-[var(--text-faint)]">{t("settings.pluginDetail.diagnosticsHint")}</span>
        <ChevronRightIcon className="size-4 text-[var(--text-faint)] transition-transform group-open:rotate-90" />
      </summary>
      <div className="divide-y divide-[var(--line)] border-t border-[var(--line)]">
        {source && (
          <DiagGroup title={t("settings.pluginDetail.code")}>
            <DiagRow label={t("settings.pluginDetail.location")} mono>
              <span className="flex items-start gap-1.5">
                <span className="min-w-0 break-all">{source.path}</span>
                <CopyButton text={source.path} className="-my-0.5 shrink-0" />
              </span>
            </DiagRow>
            {source.entry && (
              <DiagRow label={t("settings.pluginDetail.entry")} mono>
                {source.entry}
              </DiagRow>
            )}
          </DiagGroup>
        )}
        <DiagGroup title={t("settings.pluginDetail.execution")}>
          <DiagRow label={t("settings.pluginDetail.entryId")} mono>
            {p.id}
          </DiagRow>
          <DiagRow label={t("settings.pluginDetail.source")}>{SOURCE_LABEL[p.source] ? t(SOURCE_LABEL[p.source]) : p.source}</DiagRow>
          <DiagRow label={t("settings.pluginPackages.runtime")}>{runtimeLabel(p.runtime, locale)}</DiagRow>
          <DiagRow label={t("settings.pluginDetail.startupTime")}>{p.apply_ms != null ? formatMs(p.apply_ms, locale) : "—"}</DiagRow>
          <DiagRow label={t("settings.pluginDetail.processing")}>
            {t("settings.pluginDetail.processingSummary", { time: formatMs(p.stats.handler_avg_ms, locale), failures: p.stats.failures, timeouts: p.stats.timeouts, breaker: BREAKER_LABEL[p.stats.breaker] ? t(BREAKER_LABEL[p.stats.breaker]) : p.stats.breaker })}
          </DiagRow>
        </DiagGroup>
        <DiagGroup title={t("settings.pluginDetail.dependenciesPermissions")}>
          <DiagRow label={t("settings.pluginDetail.usedServices")} mono>
            <Chips items={p.inject} />
          </DiagRow>
          <DiagRow label={t("settings.pluginDetail.providedServices")} mono>
            <Chips items={p.provides} />
          </DiagRow>
          <DiagRow label={t("settings.pluginDetail.hostOperations")} mono>
            <Chips items={p.permissions ?? []} />
          </DiagRow>
          {detail.children.length > 0 && (
            <DiagRow label={t("settings.pluginDetail.children")} mono>
              <Chips items={detail.children} />
            </DiagRow>
          )}
        </DiagGroup>
      </div>
    </details>
  );
}

function DiagGroup({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="px-4 py-3">
      <h3 className="mb-1.5 text-caption font-medium text-[var(--text-faint)]">{title}</h3>
      <dl className="space-y-1.5">{children}</dl>
    </section>
  );
}

function DiagRow({
  label,
  mono = false,
  children,
}: {
  label: string;
  /** 代码类的值（路径、id、服务名）用等宽字；中文说明不用，免得字距发散 */
  mono?: boolean;
  children: ReactNode;
}) {
  const locale = useLocale();
  return (
    <div className="grid grid-cols-[5.5rem_1fr] gap-x-3 text-caption leading-5">
      <dt className="text-[var(--text-faint)]">{label}</dt>
      <dd className={`min-w-0 ${locale === "en" && !mono ? "break-words" : "break-all"} text-[var(--text-muted)] ${mono ? "font-mono" : ""}`}>
        {children}
      </dd>
    </div>
  );
}

const SOURCE_LABEL: Record<string, AppMessageKey> = { builtin: "settings.pluginDetail.builtin", local: "settings.plugins.localPlugin" };
const BREAKER_LABEL: Record<string, AppMessageKey> = {
  closed: "settings.pluginDetail.breakerClosed",
  open: "settings.pluginDetail.breakerOpen",
  "half-open": "settings.pluginDetail.breakerHalfOpen",
};

function Chips({ items }: { items: readonly string[] }) {
  if (items.length === 0) return <>—</>;
  return (
    <span className="flex flex-wrap gap-1">
      {items.map((item) => (
        <span key={item} className="rounded-md bg-white/[0.05] px-1.5 py-px">
          {item}
        </span>
      ))}
    </span>
  );
}

/** 「插件能力」每类登记的图标（按类别，不按插件） */
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
  service: ServerIcon,
  background: ActivityIcon,
};

/** 行尾的「查看 ›」：说明性的行不做成整行可点，跳转只占这几个字 */
function GoLink({ href }: { href: string }) {
  const t = useTranslations();
  return (
    <Link
      href={href as Route}
      className="inline-flex items-center text-sub text-[var(--accent)] hover:opacity-80"
    >
      {t("settings.plugins.view")}<ChevronRightIcon className="size-3.5" />
    </Link>
  );
}

/**
 * 权限：第三方插件最要紧的信任信息。只列清单里真实申请、安装时批准的项，没申请的不列
 * 「无」；每项按风险分级（LEVELS）标色，高的排前面。官方与系统模块是随应用提供的受信代码。
 */
function Permissions({ detail }: { detail: PluginDetail }) {
  const t = useTranslations();
  const locale = useLocale();
  const pkg = detail.package;
  if (!pkg) {
    if (detail.kind === "system") return null;
    return (
      <SettingsSection title={t("settings.pluginMarket.permissions")}>
        <p className="px-1 text-sub leading-relaxed text-[var(--text-muted)]">
          {detail.kind === "official"
            ? t("settings.pluginDetail.trustedCode")
            : t("settings.pluginDetail.localPermissions", { runtime: runtimeLabel(detail.plugin.runtime, locale) })}
        </p>
      </SettingsSection>
    );
  }
  const grants: Grant[] = [];
  if (detail.plugin.runtime === "inline") {
    grants.push({ level: "high", title: t("settings.pluginDetail.inApplication"), detail: t("settings.pluginDetail.samePermissions") });
  }
  for (const op of pkg.operations) {
    grants.push({ level: op.dangerous ? "high" : "low", title: op.summary });
  }
  for (const grant of pkg.paths) {
    grants.push({ level: grant.mode === "rw" ? "medium" : "low", title: t("settings.pluginDetail.pathGrant", { grant: pathGrantLabel(grant, locale) }) });
  }
  if (pkg.callbacks.length > 0) {
    grants.push({
      level: "medium",
      title: t("settings.pluginDetail.callbackGrants", { callbacks: formatList(pkg.callbacks, locale) }),
      detail: detail.callbacks.length > 0 ? t("settings.pluginDetail.callbackAccessBelow") : t("settings.pluginDetail.callbackAccess"),
    });
  }
  if (detail.network) grants.push({ level: "low", title: t("settings.pluginDetail.externalNetwork"), detail: t("settings.pluginDetail.proxyHint") });
  grants.sort((a, b) => LEVELS[a.level].order - LEVELS[b.level].order);
  return (
    <SettingsSection title={t("settings.pluginMarket.permissions")} description={t("settings.pluginDetail.approvedPermissions")}>
      <SettingsList>
        {grants.length === 0 ? (
          <GrantRow
            grant={{ level: "none", title: t("settings.pluginDetail.noExtraPermissions"), detail: t("settings.pluginDetail.ownFolderOnly") }}
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
  high: { order: 0, label: "settings.pluginDetail.highRisk", color: "var(--danger)" },
  medium: { order: 1, label: "settings.pluginDetail.mediumRisk", color: "var(--warn)" },
  low: { order: 2, label: "settings.pluginDetail.lowRisk", color: "var(--ok)" },
  none: { order: 3, label: "settings.pluginDetail.noRisk", color: "var(--ok)" },
} as const;

type Grant = { level: keyof typeof LEVELS; title: string; detail?: string };

function GrantRow({ grant }: { grant: Grant }) {
  const t = useTranslations();
  const level = LEVELS[grant.level];
  return (
    <SettingsRow
      leading={<span className="size-2 shrink-0 rounded-full" style={{ background: level.color }} />}
      label={grant.title}
      description={
        <>
          <span style={{ color: level.color }}>{t(level.label)}</span>
          {grant.detail && ` · ${grant.detail}`}
        </>
      }
    />
  );
}

/**
 * 插件通用设置（docs/design/plugin-phase4.md §3）：插件的配置模型画成表单，保存后插件按新设置重启。
 * 没有配置的插件不出这一节；配置里有界面不支持的类型时说明原因（去 plugins.yaml 改）。
 */
function PluginSettingsSection({ id }: { id: string }) {
  const t = useTranslations();
  const toast = useToast();
  const [settings, setSettings] = useState<PluginSettings | null>(null);
  const [draft, setDraft] = useState<Record<string, unknown>>({});
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const adopt = useCallback((next: PluginSettings) => {
    setSettings(next);
    const initial: Record<string, unknown> = {};
    for (const [name, field] of Object.entries(next.schema?.properties ?? {})) {
      if (field.writeOnly) {
        initial[name] = "";
        continue;
      }
      const value = next.values[name];
      initial[name] =
        fieldType(field).kind === "array" && Array.isArray(value)
          ? value.join("\n")
          : value;
    }
    setDraft(initial);
  }, []);

  useEffect(() => {
    getPluginSettings(id)
      .then(adopt)
      .catch(() => setSettings(null));
  }, [id, adopt]);

  if (!settings || (!settings.editable && !settings.reason)) return null;
  if (!settings.editable || !settings.schema) {
    return (
      <SettingsSection title={t("settings.pluginDetail.settings")}>
        <p className="px-1 text-sub leading-6 text-[var(--text-muted)]">
          {t("settings.pluginDetail.readOnlySettings", { reason: settings.reason ?? "" })}
        </p>
      </SettingsSection>
    );
  }
  const schema = settings.schema;
  const stale = unsupportedField(schema);
  if (stale) {
    return (
      <SettingsSection title={t("settings.pluginDetail.settings")}>
        <ErrorBanner>
          {t("settings.pluginDetail.staleSettings")}</ErrorBanner>
      </SettingsSection>
    );
  }

  const save = async () => {
    const values: Record<string, unknown> = {};
    for (const [name, field] of Object.entries(schema.properties)) {
      const value = draft[name];
      if (field.writeOnly) {
        if (typeof value === "string" && value !== "") values[name] = value;
        continue;
      }
      values[name] =
        typeof value === "string" ? parseValue(field, value) : value;
    }
    setSaving(true);
    setError(null);
    try {
      adopt(await savePluginSettings(id, values));
      toast.success(t("settings.pluginDetail.settingsSaved"));
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setSaving(false);
    }
  };

  return (
    <SettingsSection title={t("settings.pluginDetail.settings")}>
      <SettingsCard
        title={
          schema.title && schema.title !== "Config" ? schema.title : t("settings.pluginDetail.pluginSettings")
        }
        hint={
          error ? (
            <span className="text-[var(--danger)]">{error}</span>
          ) : (
            t("settings.pluginDetail.restartAfterSave")
          )
        }
        action={
          <button
            type="button"
            className={SETTINGS_PRIMARY_BUTTON_CLASS}
            disabled={saving}
            onClick={() => void save()}
          >
            {saving ? t("settings.pluginDetail.saving") : t("settings.pluginDetail.save")}
          </button>
        }
      >
        <SchemaForm
          schema={schema}
          values={draft}
          secretsSet={settings.secrets_set}
          disabled={saving}
          onChange={(name, value) =>
            setDraft((prev) => ({ ...prev, [name]: value }))
          }
        />
      </SettingsCard>
    </SettingsSection>
  );
}
