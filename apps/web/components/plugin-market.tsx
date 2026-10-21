"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useState, type ComponentType } from "react";

import { Banner, ErrorBanner, LINK_CLASS, StatusPill } from "@/components/cloud-push-ui";
import { useToast } from "@/components/feedback";
import {
  ChatIcon,
  CloudDriveIcon,
  DownloadIcon,
  FilmIcon,
  GlobeIcon,
  PuzzleIcon,
  RefreshIcon,
  SearchIcon,
  ShieldIcon,
} from "@/components/icons";
import { Markdown } from "@/components/markdown";
import { ReviewDrawer } from "@/components/plugin-packages-section";
import {
  SETTINGS_BUTTON_CLASS,
  SETTINGS_PRIMARY_BUTTON_CLASS,
  SettingsDrawer,
  SettingsList,
  SettingsRow,
  SettingsSection,
  SettingsTabs,
} from "@/components/settings-ui";
import {
  approvePackage,
  discardPackage,
  getMarketPlugin,
  installFromMarket,
  listMarket,
  refreshMarket,
  type MarketOverview,
  type MarketPlugin,
  type MarketPluginDetail,
  type MarketVersion,
  type PackageRequest,
  type WebConsent,
} from "@/lib/api/plugins";
import { formatBytes } from "@/lib/format";
import {
  canInstallVersion,
  categoryLabel,
  filterMarket,
  installedStatus,
  installVerb,
  marketAction,
  marketCategories,
  pendingUpdates,
  permissionLines,
  shownVersion,
  versionBadges,
  versionMeta,
} from "@/lib/plugin-market";
import { pluginHref, runtimeLabel } from "@/lib/plugins-display";
import { formatDateTime, formatRelativeTime } from "@/lib/time";

/**
 * 设置 → 插件 → 插件市场：官方插件仓库（movieclaw-plugins）的签名索引。
 *
 * 浏览、看详情（README、权限、各版本）、安装 / 升级 / 换回旧版。安装 = 服务器按索引下载并核对
 * sha256，放进待批准，然后打开与上传时同一个批准抽屉；市场从不跳过批准。停用、卸载在插件详情页
 * （已安装的插件点「管理」）。
 */
export function PluginMarket({ onChanged }: { onChanged: () => void }) {
  const toast = useToast();
  const [overview, setOverview] = useState<MarketOverview | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [checking, setChecking] = useState(false);
  const [category, setCategory] = useState("all");
  const [query, setQuery] = useState("");
  const [openId, setOpenId] = useState<string | null>(null);
  /** 正在下载的「id@版本」 */
  const [downloading, setDownloading] = useState<string | null>(null);
  const [reviewing, setReviewing] = useState<PackageRequest | null>(null);
  const [approving, setApproving] = useState(false);

  const reload = useCallback(() => {
    listMarket()
      .then((value) => {
        setOverview(value);
        setError(null);
      })
      .catch((err: unknown) => setError(err instanceof Error ? err.message : "加载失败"));
  }, []);
  useEffect(() => {
    reload();
  }, [reload]);

  const check = () => {
    setChecking(true);
    refreshMarket()
      .then((value) => {
        setOverview(value);
        setError(null);
        toast.success(value.updates ? `${value.updates} 个插件有更新` : "已是最新");
      })
      .catch((err: unknown) => toast.error(err instanceof Error ? err.message : "检查失败"))
      .finally(() => setChecking(false));
  };

  const install = async (plugin: MarketPlugin, version: string) => {
    setDownloading(`${plugin.id}@${version}`);
    try {
      const pending = await installFromMarket(plugin.id, version);
      setOpenId(null);
      setReviewing(pending);
    } catch (err: unknown) {
      toast.error(err instanceof Error ? err.message : "下载失败");
    } finally {
      setDownloading(null);
    }
  };

  const approve = async (
    item: PackageRequest,
    allowInline: boolean,
    allowMembers: boolean,
    web: WebConsent | null,
    allowTheme: boolean,
  ) => {
    setApproving(true);
    try {
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
    } catch (err: unknown) {
      toast.error(err instanceof Error ? err.message : "安装失败");
    } finally {
      setApproving(false);
      reload();
      onChanged();
    }
  };

  const discard = async (item: PackageRequest) => {
    setApproving(true);
    try {
      await discardPackage(item.id);
      setReviewing(null);
      toast.success("已放弃");
    } catch (err: unknown) {
      toast.error(err instanceof Error ? err.message : "操作失败");
    } finally {
      setApproving(false);
    }
  };

  const plugins = useMemo(() => overview?.plugins ?? [], [overview]);
  const categories = useMemo(() => marketCategories(plugins), [plugins]);
  const shown = filterMarket(plugins, { category, query });
  const updates = pendingUpdates(plugins);
  const open = plugins.find((p) => p.id === openId) ?? null;

  if (overview === null) {
    return error ? (
      <div className="space-y-3">
        <ErrorBanner>{error}</ErrorBanner>
        <button type="button" onClick={reload} className={SETTINGS_BUTTON_CLASS}>
          重试
        </button>
      </div>
    ) : (
      <p className="px-1 text-sub text-[var(--text-muted)]">正在读取插件仓库…</p>
    );
  }

  return (
    <div className="space-y-8">
      <SourceLine overview={overview} checking={checking} onCheck={check} />
      {overview.source.error && (
        <Banner tone="warn" title="没能连上插件仓库，显示的是上次取到的列表">
          {overview.source.error}
        </Banner>
      )}

      {updates.length > 0 && (
        <SettingsSection title="可更新" description={`${updates.length} 个已安装的插件有新版本`}>
          <SettingsList>
            {updates.map((plugin) => {
              const target = plugin.versions.find((v) => v.version === plugin.update);
              return (
                <SettingsRow
                  key={plugin.id}
                  leading={<MarketIcon plugin={plugin} size="sm" />}
                  label={
                    <button type="button" onClick={() => setOpenId(plugin.id)} className="text-left">
                      {plugin.name}
                      <span className="ml-2 text-sub font-normal text-[var(--text-muted)]">
                        v{plugin.installed?.version} → v{plugin.update}
                      </span>
                    </button>
                  }
                  description={firstLine(target?.notes ?? "")}
                >
                  <button
                    type="button"
                    disabled={downloading !== null}
                    onClick={() => plugin.update && void install(plugin, plugin.update)}
                    className={SETTINGS_PRIMARY_BUTTON_CLASS}
                  >
                    {downloading === `${plugin.id}@${plugin.update}` ? "正在下载…" : "更新"}
                  </button>
                </SettingsRow>
              );
            })}
          </SettingsList>
        </SettingsSection>
      )}

      <section className="space-y-4">
        <div className="flex flex-wrap items-center gap-3">
          <label className="field-shell flex h-9 min-w-0 flex-1 basis-60 items-center gap-2 rounded-lg border border-white/[0.08] bg-black/25 px-3">
            <SearchIcon className="size-4 shrink-0 text-[var(--text-faint)]" />
            <input
              id="plugin-market-search"
              type="search"
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              placeholder="搜索插件、作者"
              className="min-w-0 flex-1 bg-transparent text-ui text-[var(--text)] outline-none placeholder:text-[var(--text-faint)]"
            />
          </label>
          {categories.length > 0 && (
            <SettingsTabs tabs={categories} value={category} onChange={setCategory} />
          )}
        </div>
        {shown.length === 0 ? (
          <p className="css-glass !rounded-xl px-4 py-10 text-center text-sub text-[var(--text-faint)]">
            {plugins.length === 0 ? "插件仓库里还没有插件。" : "没有符合条件的插件。"}
          </p>
        ) : (
          <div className="grid grid-cols-[repeat(auto-fill,minmax(270px,1fr))] gap-3">
            {shown.map((plugin) => (
              <MarketCard
                key={plugin.id}
                plugin={plugin}
                downloading={downloading}
                onOpen={() => setOpenId(plugin.id)}
                onInstall={(version) => void install(plugin, version)}
              />
            ))}
          </div>
        )}
      </section>

      {open && (
        <PluginDrawer
          plugin={open}
          downloading={downloading}
          onClose={() => setOpenId(null)}
          onInstall={(version) => void install(open, version)}
        />
      )}
      <ReviewDrawer
        item={reviewing}
        currentWeb={null}
        busy={approving}
        onClose={() => setReviewing(null)}
        onApprove={(item, allowInline, allowMembers, web, allowTheme) =>
          void approve(item, allowInline, allowMembers, web, allowTheme)
        }
        onDiscard={(item) => void discard(item)}
      />
    </div>
  );
}

function firstLine(markdown: string): string {
  const line = markdown.split("\n").find((l) => l.trim()) ?? "";
  return line.replace(/^\s*[-*]\s+/, "").trim();
}

function SourceLine({
  overview,
  checking,
  onCheck,
}: {
  overview: MarketOverview;
  checking: boolean;
  onCheck: () => void;
}) {
  const { source } = overview;
  return (
    <div className="css-glass flex flex-wrap items-center gap-x-3 gap-y-2 !rounded-xl px-4 py-2.5 text-sub text-[var(--text-muted)]">
      <GitHubMark className="size-4 shrink-0 text-[var(--text)]" />
      {source.repository ? (
        <a href={source.repository} target="_blank" rel="noopener noreferrer" className={LINK_CLASS}>
          官方插件仓库
        </a>
      ) : (
        <span className="text-[var(--text)]">插件仓库</span>
      )}
      {source.signed ? (
        <span className="inline-flex items-center gap-1 text-[var(--ok)]">
          <ShieldIcon className="size-3.5" />
          签名已验证
        </span>
      ) : (
        <StatusPill tone="warn" label="未签名的自建索引" />
      )}
      <span className="text-[var(--text-faint)]">
        {overview.plugins.length} 个插件 · 检查于 {formatRelativeTime(source.checked_at)}
      </span>
      <button
        type="button"
        onClick={onCheck}
        disabled={checking}
        className={`${SETTINGS_BUTTON_CLASS} ml-auto`}
      >
        <RefreshIcon className={`size-3.5 ${checking ? "animate-spin" : ""}`} />
        {checking ? "正在检查…" : "检查更新"}
      </button>
    </div>
  );
}

const CATEGORY_ICONS: Record<string, ComponentType<{ className?: string }>> = {
  storage: CloudDriveIcon,
  downloader: DownloadIcon,
  messaging: ChatIcon,
  sites: GlobeIcon,
  library: FilmIcon,
  tools: PuzzleIcon,
};

/** 插件图标：索引里有图标就用（经服务器核对），没有按分类给默认图形 */
function MarketIcon({ plugin, size }: { plugin: MarketPlugin; size: "sm" | "md" | "lg" }) {
  const [broken, setBroken] = useState(false);
  const box = { sm: "size-8 rounded-lg", md: "size-11 rounded-xl", lg: "size-16 rounded-2xl" }[size];
  const glyph = { sm: "size-4", md: "size-5", lg: "size-7" }[size];
  const Fallback = CATEGORY_ICONS[plugin.category] ?? PuzzleIcon;
  if (plugin.icon_url && !broken) {
    return (
      <img
        src={plugin.icon_url}
        alt=""
        decoding="sync"
        onError={() => setBroken(true)}
        className={`${box} shrink-0 object-cover`}
      />
    );
  }
  return (
    <span
      aria-hidden
      className={`${box} flex shrink-0 items-center justify-center bg-white/[0.08] text-[var(--text-muted)] shadow-[inset_0_0_0_1px_rgba(255,255,255,0.08)]`}
    >
      <Fallback className={glyph} />
    </span>
  );
}

function ActionButton({
  plugin,
  downloading,
  onInstall,
}: {
  plugin: MarketPlugin;
  downloading: string | null;
  onInstall: (version: string) => void;
}) {
  const action = marketAction(plugin);
  if (action.version) {
    const busy = downloading === `${plugin.id}@${action.version}`;
    return (
      <button
        type="button"
        disabled={downloading !== null}
        onClick={(event) => {
          event.stopPropagation();
          onInstall(action.version!);
        }}
        className={SETTINGS_PRIMARY_BUTTON_CLASS}
      >
        {busy ? "正在下载…" : action.label}
      </button>
    );
  }
  if (action.kind === "installed" || action.kind === "bundled") {
    const state = plugin.installed?.state ?? "active";
    return state === "active" ? (
      <span className="shrink-0 text-sub text-[var(--text-muted)]">{action.note}</span>
    ) : (
      <StatusPill {...installedStatus(state)} />
    );
  }
  return (
    <span className="shrink-0 text-sub text-[var(--warn)]" title={action.note ?? undefined}>
      {action.kind === "incompatible" ? "需要更新 MovieClaw" : "不能安装"}
    </span>
  );
}

function MarketCard({
  plugin,
  downloading,
  onOpen,
  onInstall,
}: {
  plugin: MarketPlugin;
  downloading: string | null;
  onOpen: () => void;
  onInstall: (version: string) => void;
}) {
  const version = shownVersion(plugin);
  return (
    <div
      role="button"
      tabIndex={0}
      onClick={onOpen}
      onKeyDown={(event) => {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          onOpen();
        }
      }}
      className="css-glass flex min-w-0 cursor-pointer flex-col gap-3 !rounded-xl p-4 text-left transition-colors hover:bg-white/[0.04] focus-visible:outline focus-visible:outline-2 focus-visible:outline-[var(--accent-ring)]"
    >
      <div className="flex items-start gap-3">
        <MarketIcon plugin={plugin} size="md" />
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-1.5 text-body font-semibold text-[var(--text)]">
            {plugin.name}
            {version?.prerelease && <StatusPill tone="warn" label="测试版" />}
            {plugin.deprecated && <StatusPill tone="neutral" label="已停止维护" />}
          </div>
          <div className="mt-0.5 truncate text-caption text-[var(--text-faint)]">
            {plugin.author.name} · {categoryLabel(plugin.category)}
          </div>
        </div>
      </div>
      <p className="line-clamp-2 min-h-[2.5rem] text-sub leading-5 text-[var(--text-muted)]">
        {plugin.summary}
      </p>
      <div className="mt-auto flex items-center justify-between gap-3">
        <span className="min-w-0 truncate text-caption tabular-nums text-[var(--text-faint)]">
          {versionMeta(version)}
        </span>
        <ActionButton plugin={plugin} downloading={downloading} onInstall={onInstall} />
      </div>
    </div>
  );
}

type DetailTab = "about" | "permissions" | "versions";

function PluginDrawer({
  plugin,
  downloading,
  onClose,
  onInstall,
}: {
  plugin: MarketPlugin;
  downloading: string | null;
  onClose: () => void;
  onInstall: (version: string) => void;
}) {
  const [tab, setTab] = useState<DetailTab>("about");
  const [detail, setDetail] = useState<MarketPluginDetail | null>(null);
  const [detailError, setDetailError] = useState<string | null>(null);
  useEffect(() => {
    setDetail(null);
    setDetailError(null);
    getMarketPlugin(plugin.id)
      .then(setDetail)
      .catch((err: unknown) => setDetailError(err instanceof Error ? err.message : "加载失败"));
  }, [plugin.id]);

  const version = shownVersion(plugin);
  const action = marketAction(plugin);
  const installed = plugin.installed;
  return (
    <SettingsDrawer
      open
      onClose={onClose}
      title={plugin.name}
      description={plugin.summary}
      hint={
        installed
          ? `已安装 v${installed.version}${installed.source === "bundled" ? "（随应用提供）" : ""}`
          : action.note ?? undefined
      }
      actions={
        <>
          {installed && (
            <Link href={pluginHref(plugin.id) as never} className={SETTINGS_BUTTON_CLASS}>
              管理
            </Link>
          )}
          <ActionButton plugin={plugin} downloading={downloading} onInstall={onInstall} />
        </>
      }
    >
      <div className="space-y-6">
        <div className="flex items-start gap-4">
          <MarketIcon plugin={plugin} size="lg" />
          <div className="min-w-0 flex-1 space-y-1.5">
            <p className="text-sub text-[var(--text-muted)]">
              {plugin.author.url ? (
                <a href={plugin.author.url} target="_blank" rel="noopener noreferrer" className={LINK_CLASS}>
                  {plugin.author.name}
                </a>
              ) : (
                plugin.author.name
              )}
              <span className="text-[var(--text-faint)]"> · {plugin.id}</span>
            </p>
            {plugin.description && plugin.description !== plugin.summary && (
              <p className="text-sub leading-6 text-[var(--text-muted)]">{plugin.description}</p>
            )}
            <div className="flex flex-wrap gap-1.5">
              {version?.prerelease && <StatusPill tone="warn" label="测试版" />}
              {installed && (
                <StatusPill {...installedStatus(installed.state)} />
              )}
            </div>
          </div>
        </div>

        {plugin.deprecated && (
          <Banner tone="warn" title="作者已停止维护这个插件">
            {plugin.deprecated.reason}
            {plugin.deprecated.replaced_by && `建议改用 ${plugin.deprecated.replaced_by}。`}
          </Banner>
        )}
        {installed?.yanked && (
          <Banner tone="danger" title={`你装的 v${installed.version} 已被作者撤回`}>
            {installed.yanked}
            {plugin.recommended && plugin.recommended !== installed.version
              ? ` 建议换到 v${plugin.recommended}。`
              : ""}
          </Banner>
        )}
        {(action.kind === "incompatible" || action.kind === "blocked") && (
          <Banner tone="warn" title="这台服务器装不了">
            {action.note}
          </Banner>
        )}

        {version && (
          <dl className="css-glass grid grid-cols-2 !rounded-xl sm:grid-cols-3">
            <Fact label="版本" value={`v${version.version}`} />
            <Fact label="发布于" value={formatDateTime(version.released_at)} />
            <Fact label="大小" value={version.size ? formatBytes(version.size) : "—"} />
            <Fact label="运行方式" value={runtimeLabel(version.runtime)} />
            <Fact label="分类" value={categoryLabel(plugin.category)} />
            <Fact label="许可证" value={plugin.license} />
          </dl>
        )}

        <SettingsTabs
          tabs={[
            { id: "about", label: "介绍" },
            { id: "permissions", label: "权限" },
            { id: "versions", label: `版本 ${plugin.versions.length}` },
          ]}
          value={tab}
          onChange={setTab}
        />
        {tab === "about" && (
          <AboutTab plugin={plugin} detail={detail} error={detailError} />
        )}
        {tab === "permissions" && version && <PermissionsTab version={version} detail={detail} />}
        {tab === "versions" && (
          <VersionsTab plugin={plugin} downloading={downloading} onInstall={onInstall} />
        )}
      </div>
    </SettingsDrawer>
  );
}

function Fact({ label, value }: { label: string; value: string }) {
  return (
    <div className="min-w-0 border-[var(--line)] px-4 py-2.5 [&:nth-child(n+3)]:border-t sm:[&:nth-child(n+3)]:border-t-0 sm:[&:nth-child(n+4)]:border-t">
      <dt className="text-caption text-[var(--text-faint)]">{label}</dt>
      <dd className="mt-0.5 break-words text-sub font-medium text-[var(--text)]">{value}</dd>
    </div>
  );
}

function AboutTab({
  plugin,
  detail,
  error,
}: {
  plugin: MarketPlugin;
  detail: MarketPluginDetail | null;
  error: string | null;
}) {
  if (error) return <p className="text-sub text-[var(--danger)]">{error}</p>;
  if (!detail) return <p className="text-sub text-[var(--text-muted)]">正在读取说明…</p>;
  return (
    <div className="space-y-3">
      {detail.readme ? (
        <Markdown text={detail.readme} compact />
      ) : (
        <p className="text-sub leading-6 text-[var(--text-muted)]">
          {detail.readme_error ?? (plugin.description || "作者没有写说明。")}
        </p>
      )}
      {plugin.repository && (
        <a
          href={plugin.repository}
          target="_blank"
          rel="noopener noreferrer"
          className="inline-flex items-center gap-1.5 text-caption text-[var(--text-faint)] hover:text-[var(--text)]"
        >
          <GitHubMark className="size-3.5" />
          在 GitHub 上看源码
        </a>
      )}
    </div>
  );
}

function PermissionsTab({
  version,
  detail,
}: {
  version: MarketVersion;
  detail: MarketPluginDetail | null;
}) {
  const deps = detail?.selected === version.version ? detail.dependencies : null;
  const tone = { neutral: "text-[var(--text)]", warn: "text-[var(--warn)]", danger: "text-[var(--danger)]" };
  return (
    <div className="space-y-4">
      <p className="text-caption text-[var(--text-faint)]">v{version.version} 申请的权限。安装时会再逐项确认。</p>
      <SettingsList>
        {permissionLines(version).map((line) => (
          <div key={line.title} className="px-4 py-3">
            <div className={`text-ui font-medium ${tone[line.tone]}`}>{line.title}</div>
            <div className="mt-0.5 break-words text-caption leading-5 text-[var(--text-faint)]">
              {line.detail}
            </div>
          </div>
        ))}
      </SettingsList>
      {deps && deps.packages.length > 0 && (
        <div className="space-y-2">
          <p className="text-caption text-[var(--text-faint)]">
            这台服务器要下载约 {formatBytes(deps.total_size)}（来自 {deps.index_label}）
          </p>
          <SettingsList>
            {deps.packages.map((dep) => (
              <div key={dep.name} className="flex items-center gap-3 px-4 py-2 text-sub">
                <span className="min-w-0 flex-1 truncate text-[var(--text)]">
                  {dep.name} <span className="text-[var(--text-faint)]">{dep.version}</span>
                </span>
                {dep.native && <StatusPill tone="warn" label="本机代码" />}
                <span className="shrink-0 tabular-nums text-[var(--text-faint)]">
                  {dep.size != null ? formatBytes(dep.size) : dep.available ? "—" : "没有适用的轮子"}
                </span>
              </div>
            ))}
          </SettingsList>
        </div>
      )}
    </div>
  );
}

function VersionsTab({
  plugin,
  downloading,
  onInstall,
}: {
  plugin: MarketPlugin;
  downloading: string | null;
  onInstall: (version: string) => void;
}) {
  return (
    <SettingsList>
      {plugin.versions.map((version) => {
        const busy = downloading === `${plugin.id}@${version.version}`;
        return (
          <div key={version.version} className="space-y-2 px-4 py-3">
            <div className="flex flex-wrap items-center gap-2">
              <span className="text-ui font-semibold tabular-nums text-[var(--text)]">
                v{version.version}
              </span>
              {versionBadges(version, plugin).map((badge) => (
                <StatusPill key={badge.label} tone={badge.tone} label={badge.label} />
              ))}
              <span className="text-caption tabular-nums text-[var(--text-faint)]">
                {formatDateTime(version.released_at)}
              </span>
              {canInstallVersion(version, plugin) && (
                <button
                  type="button"
                  disabled={downloading !== null}
                  onClick={() => onInstall(version.version)}
                  className={`${SETTINGS_BUTTON_CLASS} ml-auto`}
                >
                  {busy ? "正在下载…" : installVerb(version.version, plugin)}
                </button>
              )}
            </div>
            {version.yanked && (
              <p className="text-caption text-[var(--danger)]">撤回原因：{version.yanked}</p>
            )}
            {!version.compatible && version.incompatible_reason && (
              <p className="text-caption text-[var(--warn)]">{version.incompatible_reason}</p>
            )}
            {version.notes ? (
              <Markdown text={version.notes} compact />
            ) : (
              <p className="text-caption text-[var(--text-faint)]">这一版没有写更新说明。</p>
            )}
            {version.changelog_url && (
              <a
                href={version.changelog_url}
                target="_blank"
                rel="noopener noreferrer"
                className="inline-block text-caption text-[var(--text-faint)] hover:text-[var(--text)]"
              >
                GitHub Release ↗
              </a>
            )}
          </div>
        );
      })}
    </SettingsList>
  );
}

function GitHubMark({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 16 16" fill="currentColor" aria-hidden className={className}>
      <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z" />
    </svg>
  );
}
