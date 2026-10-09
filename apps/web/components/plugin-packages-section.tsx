"use client";

import { useCallback, useEffect, useRef, useState } from "react";

import { Banner, ErrorBanner, StatusPill } from "@/components/cloud-push-ui";
import { useConfirm, useToast } from "@/components/feedback";
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
  rollbackPackage,
  uninstallPackage,
  uploadPackage,
  type InstalledPackage,
  type PackageRequest,
  type PluginInfo,
} from "@/lib/api/plugins";
import {
  isNewGrant,
  localPluginRuntimes,
  packageDetail,
  pathGrantLabel,
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
  }, [reload, onChanged]);
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

  const approve = (item: PackageRequest, allowInline: boolean) =>
    run(async () => {
      const result = await approvePackage(item, allowInline);
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
            <input
              ref={fileInput}
              type="file"
              accept=".mcplugin,.zip"
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
              {installed.map((item) => (
                <SettingsRow
                  key={item.id}
                  label={item.title}
                  description={packageDetail(item)}
                  error={item.state === "active" ? null : item.error}
                >
                  <StatusPill
                    tone={item.state === "unloaded" ? "neutral" : pluginStateTone(item.state)}
                    label={item.state === "unloaded" ? "未加载" : pluginStateLabel(item.state)}
                  />
                  <SettingsMoreMenu
                    label={`「${item.title}」的更多操作`}
                    disabled={busy}
                    items={[
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
              ))}
            </SettingsList>
          )}
        </div>
      </SettingsSection>

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
              >
                <StatusPill tone={pluginStateTone(p.state)} label={pluginStateLabel(p.state)} />
              </SettingsRow>
            ))}
          </SettingsList>
        </SettingsSection>
      )}

      <ReviewDrawer
        item={reviewing}
        busy={busy}
        onClose={() => setReviewing(null)}
        onApprove={(item, allowInline) => void approve(item, allowInline)}
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

/** 批准抽屉：逐项列出它要什么，升级时新增的申请高亮；申请主进程运行须单独勾选。 */
function ReviewDrawer({
  item,
  busy,
  onClose,
  onApprove,
  onDiscard,
}: {
  item: PackageRequest | null;
  busy: boolean;
  onClose: () => void;
  onApprove: (item: PackageRequest, allowInline: boolean) => void;
  onDiscard: (item: PackageRequest) => void;
}) {
  const [allowInline, setAllowInline] = useState(false);
  useEffect(() => setAllowInline(false), [item]);
  if (!item) return null;
  const inline = item.runtime === "inline";
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
      hint={upgrade ? `当前 v${item.installed_version}；起不来会自动回到它` : undefined}
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
            disabled={busy || (inline && !allowInline)}
            onClick={() => onApprove(item, allowInline)}
            className={SETTINGS_PRIMARY_BUTTON_CLASS}
          >
            {busy ? "正在安装…" : "批准并安装"}
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
