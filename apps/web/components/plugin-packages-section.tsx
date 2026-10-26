"use client";

import { useLocale, useTranslations } from "next-intl";

import { useCallback, useEffect, useRef, useState } from "react";

import { Banner, ErrorBanner, StatusPill } from "@/components/cloud-push-ui";
import { useConfirm, useToast } from "@/components/feedback";
import { PluginAppIcon } from "@/components/plugin-app-icon";
import { PluginWebPagesSection, WEB_PAGE_RISK } from "@/components/plugin-web-pages-section";
import {
  SETTINGS_BUTTON_CLASS,
  SETTINGS_DANGER_BUTTON_CLASS,
  SETTINGS_PRIMARY_BUTTON_CLASS,
  SettingsDrawer,
  SettingsList,
  SettingsMoreMenu,
  SettingsRow,
  SettingsSection,
} from "@/components/settings-ui";
import {
  approvePackage,
  discardPackage,
  listPackages,
  retryPackageDependencies,
  rollbackPackage,
  uninstallPackage,
  uploadPackage,
  type InstalledPackage,
  type PackageDependencies,
  type PackageRequest,
  type PluginInfo,
  type WebConsent,
} from "@/lib/api/plugins";
import { appHref } from "@/lib/plugin-apps";
import { formatList } from "@/lib/i18n/format";
import { usePluginApps } from "@/lib/plugin-apps-context";
import {
  isNewGrant,
  localPluginRuntimes,
  packageDetail,
  pathGrantLabel,
  pluginHref,
  pluginStateLabel,
  pluginStateTone,
  runtimeLabel,
} from "@/lib/plugins-display";

/**
 * 设置 → 插件 → 已安装：第三方插件包的上传、批准、回滚、卸载（docs/design/plugin-phase3.md §3、C8）。
 *
 * 上传只校验并进「待批准」；批准前在抽屉里逐项看清它要什么（宿主操作、目录、运行方式），
 * 批准即安装并当场加载，起不来服务器会自动回到上一版。本地插件（plugins.yaml）只读列出，
 * 它们的状态来自页面共用的插件列表（PluginsPage），装卸之后经 onChanged 一起刷新。
 */
export function PluginPackagesSection({
  locals,
  onChanged,
}: {
  locals: PluginInfo[];
  onChanged: () => void;
}) {
  const t = useTranslations();
  const locale = useLocale();
  const [installed, setInstalled] = useState<InstalledPackage[] | null>(null);
  const [pending, setPending] = useState<PackageRequest[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [reviewing, setReviewing] = useState<PackageRequest | null>(null);
  // 装卸之后「插件网页」小节与侧边栏都要跟着刷新
  const [webVersion, setWebVersion] = useState(0);
  const { refresh: refreshApps } = usePluginApps();
  const fileInput = useRef<HTMLInputElement>(null);
  const confirm = useConfirm();
  const toast = useToast();

  const reload = useCallback(() => {
    listPackages()
      .then((packages) => {
        setInstalled(packages.installed);
        setPending(packages.pending);
        setError(null);
      })
      .catch((err: unknown) => setError(err instanceof Error ? err.message : t("settings.plugins.loadFailed")));
  }, [t]);
  // 装卸、回滚之后插件状态变了：插件包列表与页面共用的插件列表一起刷新
  const refresh = useCallback(() => {
    reload();
    onChanged();
    setWebVersion((v) => v + 1);
    refreshApps();
  }, [reload, onChanged, refreshApps]);
  useEffect(() => {
    reload();
  }, [reload]);

  // 刚装好的插件还在宽限期观察中：期间崩溃会被自动回滚，状态要跟着刷新
  const watching = installed?.some((item) => item.watching) ?? false;
  useEffect(() => {
    if (!watching) return;
    const timer = window.setInterval(refresh, 5000);
    return () => window.clearInterval(timer);
  }, [watching, refresh]);
  // 后台在装依赖（主程序换了 Python 版本等）：进度与装好后的状态要跟着刷新
  const installing =
    installed?.some((item) => item.dependencies?.progress?.phase === "installing") ?? false;
  useEffect(() => {
    if (!installing) return;
    const timer = window.setInterval(refresh, 2000);
    return () => window.clearInterval(timer);
  }, [installing, refresh]);

  const run = useCallback(
    async (action: () => Promise<void>) => {
      setBusy(true);
      try {
        await action();
      } catch (err: unknown) {
        toast.error(err instanceof Error ? err.message : t("settings.plugins.actionFailed"));
      } finally {
        setBusy(false);
        refresh();
      }
    },
    [refresh, toast, t],
  );

  const onFile = (file: File | undefined) => {
    if (!file) return;
    void run(async () => {
      const uploaded = await uploadPackage(file);
      setReviewing(uploaded);
    });
  };

  const approve = (
    item: PackageRequest,
    allowInline: boolean,
    allowMembers: boolean,
    web: WebConsent | null,
    allowTheme: boolean,
  ) =>
    run(async () => {
      const result = await approvePackage(item, allowInline, allowMembers, web, allowTheme);
      setReviewing(null);
      if (result.status === "active") {
        toast.success(t("settings.pluginMarket.installedRunning", { name: item.title, version: item.version }));
      } else {
        toast.error(
          result.version
            ? t("settings.pluginMarket.failedRollback", { name: item.title, version: item.version, previous: result.version, reason: result.error ?? t("settings.pluginMarket.unknownReason") })
            : t("settings.pluginMarket.failedUninstall", { name: item.title, version: item.version, reason: result.error ?? t("settings.pluginMarket.unknownReason") }),
        );
      }
    });

  const rollback = async (item: InstalledPackage) => {
    const ok = await confirm({
      title: t("settings.pluginPackages.rollbackTitle", { name: item.title, version: item.previous_version ?? "" }),
      description: t("settings.pluginPackages.rollbackHint"),
      confirmLabel: t("settings.pluginPackages.rollback"),
    });
    if (!ok) return;
    await run(async () => {
      const result = await rollbackPackage(item.id);
      toast.success(t("settings.pluginPackages.rolledBack", { version: result.version ?? "" }));
    });
  };

  const retryDependencies = (item: InstalledPackage) =>
    run(async () => {
      const result = await retryPackageDependencies(item.id);
      if (result.state === "active") toast.success(t("settings.pluginPackages.dependenciesReady", { name: item.title }));
      else toast.error(t("settings.pluginPackages.dependenciesNotRunning", { reason: result.error ?? result.state }));
    });

  const uninstall = async (item: InstalledPackage) => {
    const result = await confirm({
      title: t("settings.pluginPackages.uninstallTitle", { name: item.title }),
      bullets: [t("settings.pluginPackages.uninstallProcess"), t("settings.pluginPackages.revokeGrants"), t("settings.pluginPackages.deleteVersions")],
      confirmLabel: t("settings.pluginPackages.uninstall"),
      tone: "danger",
      checkbox: {
        label: t("settings.pluginPackages.deleteData"),
        description: t("settings.pluginPackages.deleteDataHint"),
      },
    });
    if (!result.ok) return;
    await run(async () => {
      const purged = await uninstallPackage(item.id, result.checked);
      toast.success(purged ? t("settings.pluginPackages.purged", { count: purged }) : t("settings.plugins.removed"));
    });
  };

  return (
    <div className="space-y-10">
      <p className="px-1 text-sub leading-relaxed text-[var(--text-muted)]">
        {t("settings.pluginPackages.intro")}</p>
      {error && <ErrorBanner>{error}</ErrorBanner>}

      <SettingsSection
        title={t("settings.pluginPackages.thirdParty")}
        description={installed ? t("settings.pluginPackages.installedCount", { count: installed.length }) : undefined}
        action={
          <>
            {/* 不设 accept：手机浏览器不认 .mcplugin，会置灰选不了；格式由服务端校验 */}
            <input
              ref={fileInput}
              type="file"
              className="hidden"
              onChange={(event) => {
                onFile(event.target.files?.[0]);
                event.target.value = "";
              }}
            />
            <button
              type="button"
              disabled={busy}
              onClick={() => fileInput.current?.click()}
              className={SETTINGS_PRIMARY_BUTTON_CLASS}
            >
              {t("settings.pluginPackages.upload")}</button>
          </>
        }
      >
        <div className="space-y-3">
          {pending.length > 0 && (
            <Banner tone="warn" title={t("settings.pluginPackages.pendingCount", { count: pending.length })}>
              {t("settings.pluginPackages.pendingHint")}</Banner>
          )}
          {pending.length > 0 && (
            <SettingsList>
              {pending.map((item) => (
                <SettingsRow
                  key={`${item.id}@${item.version}`}
                  label={`${item.title} v${item.version}`}
                  description={
                    item.installed_version
                      ? t("settings.pluginPackages.upgradeSummary", { version: item.installed_version ?? "", runtime: runtimeLabel(item.runtime, locale) })
                      : t("settings.pluginPackages.installSummary", { runtime: runtimeLabel(item.runtime, locale) })
                  }
                >
                  <button
                    type="button"
                    onClick={() => setReviewing(item)}
                    className={SETTINGS_BUTTON_CLASS}
                  >
                    {t("settings.pluginPackages.review")}</button>
                </SettingsRow>
              ))}
            </SettingsList>
          )}
          {installed === null ? (
            !error && <p className="px-1 text-sub text-[var(--text-muted)]">{t("settings.plugins.loading")}</p>
          ) : installed.length === 0 ? (
            <p className="px-1 text-sub text-[var(--text-muted)]">{t("settings.pluginPackages.empty")}</p>
          ) : (
            <SettingsList>
              {installed.map((item) => {
                const progress = item.dependencies?.progress ?? null;
                return (
                  <SettingsRow
                    key={item.id}
                    label={item.title}
                    description={packageDetail(item, locale)}
                    error={
                      progress?.phase === "failed"
                        ? t("settings.pluginPackages.dependencyFailed", { reason: progress.error ?? t("settings.pluginMarket.unknownReason") })
                        : item.state === "active"
                          ? null
                          : item.error
                    }
                    href={pluginHref(item.id)}
                  >
                    {progress ? (
                      <StatusPill
                        tone={progress.phase === "failed" ? "danger" : "neutral"}
                        label={progress.phase === "failed" ? t("settings.pluginPackages.dependencyFailure") : t("settings.pluginPackages.installingDependencies")}
                      />
                    ) : (
                      <StatusPill
                        tone={item.state === "unloaded" ? "neutral" : pluginStateTone(item.state)}
                        label={item.state === "unloaded" ? t("settings.pluginMarket.unloaded") : pluginStateLabel(item.state, locale)}
                      />
                    )}
                    <SettingsMoreMenu
                      label={t("settings.plugins.more", { name: item.title })}
                      disabled={busy}
                      items={[
                        ...(progress?.phase === "failed"
                          ? [{ label: t("settings.pluginPackages.retryDependencies"), onSelect: () => void retryDependencies(item) }]
                          : []),
                        ...(item.previous_version
                          ? [
                              {
                                label: t("settings.pluginPackages.previousVersion", { version: item.previous_version ?? "" }),
                                onSelect: () => void rollback(item),
                                warn: true,
                              },
                            ]
                          : []),
                        { label: t("settings.pluginPackages.uninstall"), onSelect: () => void uninstall(item), danger: true },
                      ]}
                    />
                  </SettingsRow>
                );
              })}
            </SettingsList>
          )}
        </div>
      </SettingsSection>

      <PluginWebPagesSection reloadKey={webVersion} />

      {locals.length > 0 && (
        <SettingsSection
          title={t("settings.plugins.localPlugin")}
          description={t("settings.pluginPackages.localHint")}
        >
          <LocalRuntimeNote locals={locals} />
          <SettingsList>
            {locals.map((p) => (
              <SettingsRow
                key={p.id}
                label={p.title}
                description={`${p.id} · ${runtimeLabel(p.runtime, locale)}`}
                error={p.state === "failed" ? p.error : null}
                href={pluginHref(p.id)}
              >
                <StatusPill tone={pluginStateTone(p.state)} label={pluginStateLabel(p.state, locale)} />
              </SettingsRow>
            ))}
          </SettingsList>
        </SettingsSection>
      )}

      <ReviewDrawer
        item={reviewing}
        currentWeb={installed?.find((p) => p.id === reviewing?.id)?.web ?? null}
        busy={busy}
        onClose={() => setReviewing(null)}
        onApprove={(item, allowInline, allowMembers, web, allowTheme) =>
          void approve(item, allowInline, allowMembers, web, allowTheme)
        }
        onDiscard={(item) =>
          void run(async () => {
            await discardPackage(item.id);
            setReviewing(null);
            toast.success(t("settings.pluginMarket.discarded"));
          })
        }
      />
    </div>
  );
}

/** 本地插件是你自己的代码：提醒哪些在主进程里运行（与主程序同权限）、怎么关 */
function LocalRuntimeNote({ locals }: { locals: PluginInfo[] }) {
  const t = useTranslations();
  const runtimes = localPluginRuntimes(locals);
  return (
    <div className="mb-3">
      <Banner tone="warn">
        {runtimes.inline > 0 &&
          t("settings.pluginPackages.inlineCount", { count: runtimes.inline })}
        {runtimes.process > 0 &&
          t("settings.pluginPackages.processCount", { count: runtimes.process })}
        {t("settings.pluginPackages.disableLocal")}</Banner>
    </div>
  );
}

/** 带外框组件的主题：后果说明（与网页插件的授信口径一致） */
const THEME_CODE_RISK = "settings.pluginPackages.themeRisk" as const;

/** 批准抽屉：逐项列出它要什么，升级时新增的申请高亮；申请主进程运行须单独勾选。
 * 上传与插件市场共用（市场下载核对后也进待批准）。 */
export function ReviewDrawer({
  item,
  currentWeb,
  busy,
  onClose,
  onApprove,
  onDiscard,
}: {
  item: PackageRequest | null;
  /** 升级时当前版本对网页的同意：两个勾选沿用它 */
  currentWeb: WebConsent | null;
  busy: boolean;
  onClose: () => void;
  onApprove: (
    item: PackageRequest,
    allowInline: boolean,
    allowMembers: boolean,
    web: WebConsent | null,
    allowTheme: boolean,
  ) => void;
  onDiscard: (item: PackageRequest) => void;
}) {
  const t = useTranslations();
  const locale = useLocale();
  const [allowInline, setAllowInline] = useState(false);
  const [allowMembers, setAllowMembers] = useState(false);
  // 带网页：须单独同意授信运行；加不加侧边栏、成员能不能看到由用户定（docs/design/plugin-web-pages.md §5）
  const [allowWeb, setAllowWeb] = useState(false);
  const [webNav, setWebNav] = useState(true);
  const [webMembers, setWebMembers] = useState(false);
  // 带外框组件的主题：代码在每个页面里以使用者的身份运行，须单独同意（docs/design/theme-plugins.md §4.6）
  const [allowTheme, setAllowTheme] = useState(false);
  useEffect(() => {
    setAllowInline(false);
    setAllowMembers(false);
    setAllowTheme(false);
    // 授信每个版本都重新问；加不加侧边栏、成员能不能看到沿用当前版本的选择
    setAllowWeb(false);
    setWebNav(currentWeb?.nav ?? true);
    setWebMembers(currentWeb?.members ?? false);
    // eslint-disable-next-line react-hooks/exhaustive-deps -- 只在换了一个待批准的包时重置
  }, [item]);
  if (!item) return null;
  const inline = item.runtime === "inline";
  const web = item.web ?? null;
  const theme = item.theme ?? null;
  const themeCode = theme?.has_code === true;
  // 旧服务端没有 entry 字段：按有后端代码处理（沿用原来的说明）
  const noBackend = item.entry === "" && item.runtime !== "exec";
  const notifiesMembers = item.notifies_members === true;
  const upgrade = item.installed_version !== null;
  const newBadge = (
    <span className="ml-2 rounded-full bg-[var(--warn)]/15 px-1.5 text-caption text-[var(--warn)]">
      {t("settings.pluginPackages.added")}</span>
  );

  return (
    <SettingsDrawer
      open
      onClose={onClose}
      title={upgrade ? t("settings.pluginPackages.upgradeTitle", { name: item.title, version: item.version }) : t("settings.pluginPackages.installTitle", { name: item.title, version: item.version })}
      description={item.description || undefined}
      hint={
        upgrade
          ? t("settings.pluginPackages.currentFallback", { version: item.installed_version ?? "" })
          : item.replaces_builtin
            ? t("settings.pluginPackages.replacesBuiltin")
            : undefined
      }
      actions={
        <>
          <button
            type="button"
            disabled={busy}
            onClick={() => onDiscard(item)}
            className={SETTINGS_DANGER_BUTTON_CLASS}
          >
            {t("settings.pluginPackages.discard")}</button>
          <button type="button" onClick={onClose} className={SETTINGS_BUTTON_CLASS}>
            {t("settings.pluginPackages.cancel")}</button>
          <button
            type="button"
            disabled={
              busy ||
              (inline && !allowInline) ||
              (notifiesMembers && !allowMembers) ||
              (web !== null && !allowWeb) ||
              (themeCode && !allowTheme)
            }
            onClick={() =>
              onApprove(
                item,
                allowInline,
                allowMembers,
                web ? { nav: webNav, members: webMembers } : null,
                themeCode && allowTheme,
              )
            }
            className={SETTINGS_PRIMARY_BUTTON_CLASS}
          >
            {busy ? (item.dependencies ? t("settings.pluginPackages.downloadingDependencies") : t("settings.pluginPackages.installing")) : t("settings.pluginPackages.approveInstall")}
          </button>
        </>
      }
    >
      <dl className="space-y-6 text-sub">
        <div>
          <dt className="mb-1.5 font-medium text-[var(--text)]">{t("settings.pluginPackages.runtime")}</dt>
          <dd className={inline ? "text-[var(--danger)]" : "text-[var(--text-muted)]"}>
            {inline
              ? t("settings.pluginPackages.inlineRisk")
              : noBackend
                ? t("settings.pluginPackages.noBackend")
                : t("settings.pluginPackages.processHint")}
          </dd>
          {inline && (
            <label className="mt-2 flex items-center gap-2 text-[var(--danger)]">
              <input
                type="checkbox"
                checked={allowInline}
                onChange={(event) => setAllowInline(event.target.checked)}
              />
              {t("settings.pluginPackages.trustInline")}</label>
          )}
        </div>
        {theme && (
          <div>
            <dt className="mb-1.5 font-medium text-[var(--text)]">{t("settings.pluginPackages.theme")}</dt>
            <dd className="space-y-2">
              <div className="flex items-center gap-3">
                <span
                  aria-hidden="true"
                  className="relative h-9 w-14 shrink-0 overflow-hidden rounded-md border border-white/10"
                  style={{ background: theme.preview.bg }}
                >
                  <span
                    className="absolute bottom-1.5 left-1.5 h-1.5 w-6 rounded-full"
                    style={{ background: theme.preview.accent }}
                  />
                </span>
                <span className="min-w-0">
                  <span className="block text-[var(--text)]">{theme.label}</span>
                  <span className="block text-caption text-[var(--text-faint)]">
                    {theme.layout === "cinema" ? t("settings.pluginPackages.heroLayout") : t("settings.pluginPackages.sidebarLayout")}
                    {theme.description ? ` · ${theme.description}` : ""}
                  </span>
                </span>
              </div>
              <p className="text-[var(--text-muted)]">{t("settings.pluginPackages.themeHint")}</p>
              {themeCode && (
                <>
                  <p className="text-[var(--danger)]">{t(THEME_CODE_RISK)}</p>
                  <label className="flex items-center gap-2 text-[var(--danger)]">
                    <input
                      type="checkbox"
                      checked={allowTheme}
                      onChange={(event) => setAllowTheme(event.target.checked)}
                    />
                    {t("settings.pluginPackages.trustTheme")}</label>
                </>
              )}
            </dd>
          </div>
        )}
        {web && (
          <div>
            <dt className="mb-1.5 font-medium text-[var(--text)]">{t("settings.pluginPackages.web")}</dt>
            <dd className="space-y-2">
              <ul className="space-y-1.5">
                {web.entries.map((entry) => (
                  <li key={entry.path} className="flex items-center gap-2 text-[var(--text)]">
                    <PluginAppIcon
                      src={entry.icon}
                      monochrome={entry.monochrome}
                      className="size-[18px] text-[var(--text-muted)]"
                    />
                    {entry.label}
                    <code className="text-caption text-[var(--text-faint)]">
                      {appHref(item.id, entry.path)}
                    </code>
                  </li>
                ))}
              </ul>
              <p className="text-[var(--danger)]">{t(WEB_PAGE_RISK)}</p>
              <label className="flex items-center gap-2 text-[var(--danger)]">
                <input
                  type="checkbox"
                  checked={allowWeb}
                  onChange={(event) => setAllowWeb(event.target.checked)}
                />
                {t("settings.pluginPackages.trustWeb")}</label>
              <label className="flex items-center gap-2 text-[var(--text-muted)]">
                <input
                  type="checkbox"
                  checked={webNav}
                  onChange={(event) => setWebNav(event.target.checked)}
                />
                {t("settings.plugins.addSidebar")}</label>
              <label className="flex items-center gap-2 text-[var(--text-muted)]">
                <input
                  type="checkbox"
                  checked={webMembers}
                  onChange={(event) => setWebMembers(event.target.checked)}
                />
                {t("settings.plugins.membersAlso")}</label>
            </dd>
          </div>
        )}
        <div>
          <dt className="mb-1.5 font-medium text-[var(--text)]">{t("settings.pluginPackages.operations")}</dt>
          <dd>
            {item.operation_details.length === 0 ? (
              <span className="text-[var(--text-muted)]">{t("settings.pluginPackages.noOperations")}</span>
            ) : (
              <ul className="space-y-1.5">
                {item.operation_details.map((op) => (
                  <li key={op.id} className="flex flex-wrap items-baseline gap-x-2">
                    <span className={op.dangerous ? "text-[var(--danger)]" : "text-[var(--text)]"}>
                      {op.summary}
                      {op.dangerous && t("settings.pluginPackages.dangerous")}
                    </span>
                    <code className="text-caption text-[var(--text-faint)]">{op.id}</code>
                    {upgrade && item.new_operations.includes(op.id) && newBadge}
                  </li>
                ))}
              </ul>
            )}
          </dd>
        </div>
        <div>
          <dt className="mb-1.5 font-medium text-[var(--text)]">{t("settings.pluginPackages.paths")}</dt>
          <dd>
            {item.paths.length === 0 ? (
              <span className="text-[var(--text-muted)]">{t("settings.pluginPackages.ownFolder")}</span>
            ) : (
              <ul className="space-y-1.5">
                {item.paths.map((grant) => (
                  <li key={`${grant.path}:${grant.mode}`} className="text-[var(--text)]">
                    {pathGrantLabel(grant, locale)}
                    {upgrade && isNewGrant(grant, item.new_paths) && newBadge}
                  </li>
                ))}
              </ul>
            )}
          </dd>
        </div>
        {item.dependencies && (
          <DependenciesSection dependencies={item.dependencies} upgrade={upgrade} />
        )}
        {(item.callbacks?.length ?? 0) > 0 && (
          <div>
            <dt className="mb-1.5 font-medium text-[var(--text)]">{t("settings.pluginPackages.callbacks")}</dt>
            <dd className="space-y-1.5">
              <p className="text-[var(--text-muted)]">
                {t("settings.pluginPackages.callbacksHint")}</p>
              <ul className="space-y-1.5">
                {item.callbacks?.map((name) => (
                  <li key={name} className="text-[var(--text)]">
                    <code>{name}</code>
                    {upgrade && item.new_callbacks?.includes(name) && newBadge}
                  </li>
                ))}
              </ul>
            </dd>
          </div>
        )}
        {(item.notifications?.length ?? 0) > 0 && (
          <div>
            <dt className="mb-1.5 font-medium text-[var(--text)]">{t("settings.pluginPackages.notifications")}</dt>
            <dd className="space-y-1.5">
              <p className="text-[var(--text-muted)]">
                {t("settings.pluginPackages.notificationsHint", { name: item.title })}
              </p>
              <ul className="space-y-1.5">
                {item.notifications?.map((n) => (
                  <li key={n.event} className="text-[var(--text)]">
                    {n.title}
                    <span
                      className={
                        n.reaches_members
                          ? "ml-2 text-[var(--warn)]"
                          : "ml-2 text-[var(--text-muted)]"
                      }
                    >
                      {t("settings.pluginPackages.audience", { audience: n.audience_label })}
                    </span>
                  </li>
                ))}
              </ul>
              {notifiesMembers && (
                <label className="mt-2 flex items-center gap-2 text-[var(--warn)]">
                  <input
                    type="checkbox"
                    checked={allowMembers}
                    onChange={(event) => setAllowMembers(event.target.checked)}
                  />
                  {t("settings.pluginPackages.allowMembers")}</label>
              )}
            </dd>
          </div>
        )}
        {(item.sensitive_events?.length ?? 0) > 0 && (
          <div>
            <dt className="mb-1.5 font-medium text-[var(--text)]">{t("settings.pluginPackages.watching")}</dt>
            <dd className="space-y-1.5">
              <p className="text-[var(--warn)]">
                {t("settings.pluginPackages.watchingHint")}</p>
              <ul className="space-y-1 text-caption text-[var(--text-faint)]">
                {item.sensitive_events?.map((name) => (
                  <li key={name}>
                    <code>{name}</code>
                  </li>
                ))}
              </ul>
            </dd>
          </div>
        )}
        {(item.events?.length ?? 0) > 0 && (
          <div>
            <dt className="mb-1.5 font-medium text-[var(--text)]">{t("settings.pluginPackages.events")}</dt>
            <dd className="space-y-1 text-[var(--text)]">
              {item.events?.map((e) => (
                <div key={e.name}>
                  {e.title} <code className="text-caption text-[var(--text-faint)]">{e.name}</code>
                </div>
              ))}
            </dd>
          </div>
        )}
        {Object.keys(item.requires).length > 0 && (
          <div>
            <dt className="mb-1.5 font-medium text-[var(--text)]">{t("settings.pluginPackages.requires")}</dt>
            <dd className="space-y-1 text-caption text-[var(--text-faint)]">
              {Object.entries(item.requires).map(([name, version]) => (
                <div key={name}>
                  <code>{name}</code> {version}
                </div>
              ))}
            </dd>
          </div>
        )}
      </dl>
    </SettingsDrawer>
  );
}

function formatSize(bytes: number): string {
  if (bytes >= 1024 * 1024) return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
  return `${Math.max(1, Math.round(bytes / 1024))} KB`;
}

function DependenciesSection({
  dependencies,
  upgrade,
}: {
  dependencies: PackageDependencies;
  upgrade: boolean;
}) {
  const t = useTranslations();
  const locale = useLocale();
  const changed = upgrade && dependencies.needs_consent;
  const count = dependencies.packages.length;
  const badge = "rounded-full bg-[var(--warn)]/15 px-1.5 text-caption text-[var(--warn)]";
  return (
    <div>
      <dt className="mb-1.5 font-medium text-[var(--text)]">
        {upgrade && !dependencies.needs_consent
          ? t("settings.pluginPackages.sameDependencies", { count })
          : t("settings.pluginPackages.downloadDependencies", { count, size: formatSize(dependencies.total_size), index: dependencies.index_label })}
      </dt>
      <dd className="space-y-1.5">
        <p className="text-[var(--text-muted)]">
          {t("settings.pluginPackages.dependenciesHint")}</p>
        <ul className="space-y-1">
          {dependencies.packages.map((dep) => (
            <li key={dep.name} className="flex flex-wrap items-baseline gap-x-2 text-[var(--text)]">
              <span>
                {dep.name} <span className="text-[var(--text-muted)]">{dep.version}</span>
              </span>
              {dep.native && <span className="text-caption text-[var(--warn)]">{t("settings.pluginPackages.nativeCode")}</span>}
              {dep.size !== null && (
                <span className="text-caption text-[var(--text-faint)]">{formatSize(dep.size)}</span>
              )}
              {!dep.available && (
                <span className="text-caption text-[var(--danger)]">
                  {t("settings.pluginPackages.dependencyUnavailable")}</span>
              )}
              {changed && dep.change === "added" && <span className={badge}>{t("settings.pluginPackages.added")}</span>}
              {changed && dep.change === "changed" && (
                <span className={badge}>{t("settings.pluginPackages.previousDependency", { version: dep.previous_version ?? "" })}</span>
              )}
            </li>
          ))}
        </ul>
        {changed && dependencies.removed.length > 0 && (
          <p className="text-caption text-[var(--text-muted)]">
            {t("settings.pluginPackages.removedDependencies", { packages: formatList(dependencies.removed, locale) })}
          </p>
        )}
      </dd>
    </div>
  );
}
