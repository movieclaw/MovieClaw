"use client";

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
      .catch((err: unknown) => setError(err instanceof Error ? err.message : "加载失败"));
  }, []);
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
        toast.error(err instanceof Error ? err.message : "操作失败");
      } finally {
        setBusy(false);
        refresh();
      }
    },
    [refresh, toast],
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
        toast.success(`「${item.title}」v${item.version} 已安装并运行`);
      } else {
        toast.error(
          `「${item.title}」v${item.version} 没能运行，已自动${
            result.version ? `回到 v${result.version}` : "撤销安装"
          }：${result.error ?? "未知原因"}`,
        );
      }
    });

  const rollback = async (item: InstalledPackage) => {
    const ok = await confirm({
      title: `「${item.title}」回到 v${item.previous_version}？`,
      description: "当前版本会保留为「上一版」，之后还能再切回来。",
      confirmLabel: "回到上一版",
    });
    if (!ok) return;
    await run(async () => {
      const result = await rollbackPackage(item.id);
      toast.success(`已回到 v${result.version}`);
    });
  };

  const retryDependencies = (item: InstalledPackage) =>
    run(async () => {
      const result = await retryPackageDependencies(item.id);
      if (result.state === "active") toast.success(`「${item.title}」的依赖已装好，已运行`);
      else toast.error(`依赖已装好，但插件没能运行：${result.error ?? result.state}`);
    });

  const uninstall = async (item: InstalledPackage) => {
    const result = await confirm({
      title: `卸载「${item.title}」？`,
      bullets: ["停止并移除插件进程", "撤销它的宿主操作与目录授权", "删除已安装的版本文件"],
      confirmLabel: "卸载",
      tone: "danger",
      checkbox: {
        label: "连同插件数据一起删除",
        description: "它保存的设置、状态与签名密钥；不勾则保留，重新安装后接着用。",
      },
    });
    if (!result.ok) return;
    await run(async () => {
      const purged = await uninstallPackage(item.id, result.checked);
      toast.success(purged ? `已卸载，删除了 ${purged} 条插件数据` : "已卸载");
    });
  };

  return (
    <div className="space-y-10">
      <p className="px-1 text-sub leading-relaxed text-[var(--text-muted)]">
        插件包（.mcplugin）由第三方开发者提供。上传后先核对它申请的权限，批准才会安装；
        默认在独立进程里以低权限用户运行，崩溃只影响它自己，新版本起不来会自动回到上一版。
      </p>
      {error && <ErrorBanner>{error}</ErrorBanner>}

      <SettingsSection
        title="第三方插件"
        description={installed ? `${installed.length} 个已安装` : undefined}
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
              上传插件包
            </button>
          </>
        }
      >
        <div className="space-y-3">
          {pending.length > 0 && (
            <Banner tone="warn" title={`${pending.length} 个插件包等待批准`}>
              批准前请核对它申请的权限；不需要的可以放弃。
            </Banner>
          )}
          {pending.length > 0 && (
            <SettingsList>
              {pending.map((item) => (
                <SettingsRow
                  key={`${item.id}@${item.version}`}
                  label={`${item.title} v${item.version}`}
                  description={
                    item.installed_version
                      ? `升级（当前 v${item.installed_version}）· ${runtimeLabel(item.runtime)}`
                      : `新安装 · ${runtimeLabel(item.runtime)}`
                  }
                >
                  <button
                    type="button"
                    onClick={() => setReviewing(item)}
                    className={SETTINGS_BUTTON_CLASS}
                  >
                    查看并批准
                  </button>
                </SettingsRow>
              ))}
            </SettingsList>
          )}
          {installed === null ? (
            !error && <p className="px-1 text-sub text-[var(--text-muted)]">正在加载…</p>
          ) : installed.length === 0 ? (
            <p className="px-1 text-sub text-[var(--text-muted)]">还没有安装第三方插件。</p>
          ) : (
            <SettingsList>
              {installed.map((item) => {
                const progress = item.dependencies?.progress ?? null;
                return (
                  <SettingsRow
                    key={item.id}
                    label={item.title}
                    description={packageDetail(item)}
                    error={
                      progress?.phase === "failed"
                        ? `依赖安装失败：${progress.error ?? "未知原因"}`
                        : item.state === "active"
                          ? null
                          : item.error
                    }
                    href={pluginHref(item.id)}
                  >
                    {progress ? (
                      <StatusPill
                        tone={progress.phase === "failed" ? "danger" : "neutral"}
                        label={progress.phase === "failed" ? "依赖没装上" : "正在安装依赖"}
                      />
                    ) : (
                      <StatusPill
                        tone={item.state === "unloaded" ? "neutral" : pluginStateTone(item.state)}
                        label={item.state === "unloaded" ? "未加载" : pluginStateLabel(item.state)}
                      />
                    )}
                    <SettingsMoreMenu
                      label={`「${item.title}」的更多操作`}
                      disabled={busy}
                      items={[
                        ...(progress?.phase === "failed"
                          ? [{ label: "重试安装依赖", onSelect: () => void retryDependencies(item) }]
                          : []),
                        ...(item.previous_version
                          ? [
                              {
                                label: `回到上一版 v${item.previous_version}`,
                                onSelect: () => void rollback(item),
                                warn: true,
                              },
                            ]
                          : []),
                        { label: "卸载", onSelect: () => void uninstall(item), danger: true },
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
          title="本地插件"
          description="你在 data/plugins.yaml 里开启的插件，在那里管理，改动重启后生效。"
        >
          <LocalRuntimeNote locals={locals} />
          <SettingsList>
            {locals.map((p) => (
              <SettingsRow
                key={p.id}
                label={p.title}
                description={`${p.id} · ${runtimeLabel(p.runtime)}`}
                error={p.state === "failed" ? p.error : null}
                href={pluginHref(p.id)}
              >
                <StatusPill tone={pluginStateTone(p.state)} label={pluginStateLabel(p.state)} />
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
            toast.success("已放弃");
          })
        }
      />
    </div>
  );
}

/** 本地插件是你自己的代码：提醒哪些在主进程里运行（与主程序同权限）、怎么关 */
function LocalRuntimeNote({ locals }: { locals: PluginInfo[] }) {
  const runtimes = localPluginRuntimes(locals);
  return (
    <div className="mb-3">
      <Banner tone="warn">
        {runtimes.inline > 0 &&
          `${runtimes.inline} 个在应用进程里运行，拥有与主程序相同的系统权限——只开启你信任的代码。`}
        {runtimes.process > 0 &&
          `${runtimes.process} 个在独立进程里运行：崩溃、卡死只影响它自己，拿不到主密钥等敏感配置。`}
        要关掉某个本地插件：在 data/plugins.yaml 里去掉它的 local 或加上 disabled: true，重启生效。
      </Banner>
    </div>
  );
}

/** 带外框组件的主题：后果说明（与网页插件的授信口径一致） */
const THEME_CODE_RISK =
  "这个主题带界面代码：会在每个页面里以正在使用它的人的身份运行，管理员打开时拥有管理员的全部权限。只同意你信任的主题。";

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
      新增
    </span>
  );

  return (
    <SettingsDrawer
      open
      onClose={onClose}
      title={`${upgrade ? "升级" : "安装"}「${item.title}」v${item.version}`}
      description={item.description || undefined}
      hint={
        upgrade
          ? `当前 v${item.installed_version}；起不来会自动回到它`
          : item.replaces_builtin
            ? "与内置插件同 id：安装后替换内置版本（已绑定的账号、数据照常沿用），卸载即恢复内置版本"
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
            放弃
          </button>
          <button type="button" onClick={onClose} className={SETTINGS_BUTTON_CLASS}>
            取消
          </button>
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
            {busy ? (item.dependencies ? "正在下载安装依赖…" : "正在安装…") : "批准并安装"}
          </button>
        </>
      }
    >
      <dl className="space-y-6 text-sub">
        <div>
          <dt className="mb-1.5 font-medium text-[var(--text)]">运行方式</dt>
          <dd className={inline ? "text-[var(--danger)]" : "text-[var(--text-muted)]"}>
            {inline
              ? "申请在主进程里运行：拥有与主程序相同的系统权限，崩溃会影响整个应用。"
              : noBackend
                ? "没有后端代码：只带网页或主题，不在服务器上运行任何程序。"
                : "独立进程、低权限用户：崩溃、卡死只影响它自己，拿不到主密钥与数据库。"}
          </dd>
          {inline && (
            <label className="mt-2 flex items-center gap-2 text-[var(--danger)]">
              <input
                type="checkbox"
                checked={allowInline}
                onChange={(event) => setAllowInline(event.target.checked)}
              />
              我信任这个插件，允许它在主进程里运行
            </label>
          )}
        </div>
        {theme && (
          <div>
            <dt className="mb-1.5 font-medium text-[var(--text)]">网页主题</dt>
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
                    {theme.layout === "cinema" ? "顶栏 + 大图首屏版式" : "侧栏版式"}
                    {theme.description ? ` · ${theme.description}` : ""}
                  </span>
                </span>
              </div>
              <p className="text-[var(--text-muted)]">装上后在「设置 → 外观」里选用；每个人可以各选各的。</p>
              {themeCode && (
                <>
                  <p className="text-[var(--danger)]">{THEME_CODE_RISK}</p>
                  <label className="flex items-center gap-2 text-[var(--danger)]">
                    <input
                      type="checkbox"
                      checked={allowTheme}
                      onChange={(event) => setAllowTheme(event.target.checked)}
                    />
                    我信任这个主题的代码
                  </label>
                </>
              )}
            </dd>
          </div>
        )}
        {web && (
          <div>
            <dt className="mb-1.5 font-medium text-[var(--text)]">自带网页</dt>
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
              <p className="text-[var(--danger)]">{WEB_PAGE_RISK}</p>
              <label className="flex items-center gap-2 text-[var(--danger)]">
                <input
                  type="checkbox"
                  checked={allowWeb}
                  onChange={(event) => setAllowWeb(event.target.checked)}
                />
                我信任这个插件的网页
              </label>
              <label className="flex items-center gap-2 text-[var(--text-muted)]">
                <input
                  type="checkbox"
                  checked={webNav}
                  onChange={(event) => setWebNav(event.target.checked)}
                />
                加到侧边栏
              </label>
              <label className="flex items-center gap-2 text-[var(--text-muted)]">
                <input
                  type="checkbox"
                  checked={webMembers}
                  onChange={(event) => setWebMembers(event.target.checked)}
                />
                成员也能看到
              </label>
            </dd>
          </div>
        )}
        <div>
          <dt className="mb-1.5 font-medium text-[var(--text)]">能调用的操作</dt>
          <dd>
            {item.operation_details.length === 0 ? (
              <span className="text-[var(--text-muted)]">不申请任何操作</span>
            ) : (
              <ul className="space-y-1.5">
                {item.operation_details.map((op) => (
                  <li key={op.id} className="flex flex-wrap items-baseline gap-x-2">
                    <span className={op.dangerous ? "text-[var(--danger)]" : "text-[var(--text)]"}>
                      {op.summary}
                      {op.dangerous && "（危险操作）"}
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
          <dt className="mb-1.5 font-medium text-[var(--text)]">能访问的目录</dt>
          <dd>
            {item.paths.length === 0 ? (
              <span className="text-[var(--text-muted)]">只用它自己的目录</span>
            ) : (
              <ul className="space-y-1.5">
                {item.paths.map((grant) => (
                  <li key={`${grant.path}:${grant.mode}`} className="text-[var(--text)]">
                    {pathGrantLabel(grant)}
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
            <dt className="mb-1.5 font-medium text-[var(--text)]">开放的回调地址</dt>
            <dd className="space-y-1.5">
              <p className="text-[var(--text-muted)]">
                外部平台（如企业微信、GitHub）不用登录就能往这些地址推消息；地址里带一串密钥，可随时换或作废，卸载即失效。
              </p>
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
            <dt className="mb-1.5 font-medium text-[var(--text)]">会发的通知</dt>
            <dd className="space-y-1.5">
              <p className="text-[var(--text-muted)]">
                推到手机和 IM，标明「来自 {item.title}」；每个人能在「账号 → 通知」里自己关掉。
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
                      发给{n.audience_label}
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
                  允许它给家里的成员发通知
                </label>
              )}
            </dd>
          </div>
        )}
        {(item.sensitive_events?.length ?? 0) > 0 && (
          <div>
            <dt className="mb-1.5 font-medium text-[var(--text)]">要知道的观看动态</dt>
            <dd className="space-y-1.5">
              <p className="text-[var(--warn)]">
                它会知道谁在什么时候看了什么、收藏了什么。
              </p>
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
            <dt className="mb-1.5 font-medium text-[var(--text)]">会发出的事件</dt>
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
            <dt className="mb-1.5 font-medium text-[var(--text)]">依赖的接口</dt>
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
  const changed = upgrade && dependencies.needs_consent;
  const count = dependencies.packages.length;
  const badge = "rounded-full bg-[var(--warn)]/15 px-1.5 text-caption text-[var(--warn)]";
  return (
    <div>
      <dt className="mb-1.5 font-medium text-[var(--text)]">
        {upgrade && !dependencies.needs_consent
          ? `第三方包（${count} 个，与当前版本相同）`
          : `需要下载并安装 ${count} 个第三方包（共 ${formatSize(dependencies.total_size)}，来自 ${dependencies.index_label}）`}
      </dt>
      <dd className="space-y-1.5">
        <p className="text-[var(--text-muted)]">
          这些包在插件自己的进程里运行，权限与插件相同。含本机代码的包更难审查，单独标出。
        </p>
        <ul className="space-y-1">
          {dependencies.packages.map((dep) => (
            <li key={dep.name} className="flex flex-wrap items-baseline gap-x-2 text-[var(--text)]">
              <span>
                {dep.name} <span className="text-[var(--text-muted)]">{dep.version}</span>
              </span>
              {dep.native && <span className="text-caption text-[var(--warn)]">含本机代码</span>}
              {dep.size !== null && (
                <span className="text-caption text-[var(--text-faint)]">{formatSize(dep.size)}</span>
              )}
              {!dep.available && (
                <span className="text-caption text-[var(--danger)]">
                  没有适用于这台服务器的版本，装不上
                </span>
              )}
              {changed && dep.change === "added" && <span className={badge}>新增</span>}
              {changed && dep.change === "changed" && (
                <span className={badge}>原 {dep.previous_version}</span>
              )}
            </li>
          ))}
        </ul>
        {changed && dependencies.removed.length > 0 && (
          <p className="text-caption text-[var(--text-muted)]">
            不再需要：{dependencies.removed.join("、")}
          </p>
        )}
      </dd>
    </div>
  );
}
