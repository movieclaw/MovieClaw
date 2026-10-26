"use client";

import { useLocale, useTranslations } from "next-intl";
import type { AppLocale } from "@/lib/i18n/negotiate";

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
import { getHealth } from "@/lib/api/health";
import { formatBytes } from "@/lib/format";
import {
  canInstallVersion,
  categoryLabel,
  feedbackLink,
  filterMarket,
  formatDownloadCount,
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
  const t = useTranslations();
  const locale = useLocale();
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
  const [appVersion, setAppVersion] = useState<string | null>(null);

  const reload = useCallback(() => {
    listMarket()
      .then((value) => {
        setOverview(value);
        setError(null);
      })
      .catch((err: unknown) => setError(err instanceof Error ? err.message : t("settings.pluginMarket.loadFailed")));
  }, [t]);
  useEffect(() => {
    reload();
  }, [reload]);
  useEffect(() => {
    getHealth()
      .then((health) => setAppVersion(health.version?.trim() || null))
      .catch(() => setAppVersion(null));
  }, []);

  const check = () => {
    setChecking(true);
    refreshMarket()
      .then((value) => {
        setOverview(value);
        setError(null);
        toast.success(value.updates ? t("settings.pluginMarket.updatesFound", { count: value.updates }) : t("settings.pluginMarket.upToDate"));
      })
      .catch((err: unknown) => toast.error(err instanceof Error ? err.message : t("settings.pluginMarket.checkFailed")))
      .finally(() => setChecking(false));
  };

  const install = async (plugin: MarketPlugin, version: string) => {
    setDownloading(`${plugin.id}@${version}`);
    try {
      const pending = await installFromMarket(plugin.id, version);
      setOpenId(null);
      setReviewing(pending);
    } catch (err: unknown) {
      toast.error(err instanceof Error ? err.message : t("settings.pluginMarket.downloadFailed"));
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
        toast.success(t("settings.pluginMarket.installedRunning", { name: item.title, version: item.version }));
      } else {
        toast.error(
          result.version
            ? t("settings.pluginMarket.failedRollback", { name: item.title, version: item.version, previous: result.version, reason: result.error ?? t("settings.pluginMarket.unknownReason") })
            : t("settings.pluginMarket.failedUninstall", { name: item.title, version: item.version, reason: result.error ?? t("settings.pluginMarket.unknownReason") }),
        );
      }
    } catch (err: unknown) {
      toast.error(err instanceof Error ? err.message : t("settings.pluginMarket.installFailed"));
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
      toast.success(t("settings.pluginMarket.discarded"));
    } catch (err: unknown) {
      toast.error(err instanceof Error ? err.message : t("settings.pluginMarket.actionFailed"));
    } finally {
      setApproving(false);
    }
  };

  const plugins = useMemo(() => overview?.plugins ?? [], [overview]);
  const categories = useMemo(() => marketCategories(plugins, locale), [plugins, locale]);
  const shown = filterMarket(plugins, { category, query });
  const updates = pendingUpdates(plugins);
  const open = plugins.find((p) => p.id === openId) ?? null;

  if (overview === null) {
    return error ? (
      <div className="space-y-3">
        <ErrorBanner>{error}</ErrorBanner>
        <button type="button" onClick={reload} className={SETTINGS_BUTTON_CLASS}>
          {t("settings.pluginMarket.retry")}</button>
      </div>
    ) : (
      <p className="px-1 text-sub text-[var(--text-muted)]">{t("settings.pluginMarket.reading")}</p>
    );
  }

  return (
    <div className="space-y-8">
      <SourceLine overview={overview} checking={checking} onCheck={check} />
      {overview.source.error && (
        <Banner tone="warn" title={t("settings.pluginMarket.stale")}>
          {overview.source.error}
        </Banner>
      )}

      {updates.length > 0 && (
        <SettingsSection title={t("settings.pluginMarket.updates")} description={t("settings.pluginMarket.updatesHint", { count: updates.length })}>
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
                    {downloading === `${plugin.id}@${plugin.update}` ? t("settings.pluginMarket.downloading") : t("settings.pluginMarket.update")}
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
              placeholder={t("settings.pluginMarket.search")}
              className="min-w-0 flex-1 bg-transparent text-ui text-[var(--text)] outline-none placeholder:text-[var(--text-faint)]"
            />
          </label>
          {categories.length > 0 && (
            <SettingsTabs tabs={categories} value={category} onChange={setCategory} />
          )}
        </div>
        {shown.length === 0 ? (
          <p className="css-glass !rounded-xl px-4 py-10 text-center text-sub text-[var(--text-faint)]">
            {plugins.length === 0 ? t("settings.pluginMarket.empty") : t("settings.pluginMarket.noMatch")}
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
          appVersion={appVersion}
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
  const t = useTranslations();
  const locale = useLocale();
  const { source } = overview;
  return (
    <div className="css-glass flex flex-wrap items-center gap-x-3 gap-y-2 !rounded-xl px-4 py-2.5 text-sub text-[var(--text-muted)]">
      <GitHubMark className="size-4 shrink-0 text-[var(--text)]" />
      {source.repository ? (
        <a href={source.repository} target="_blank" rel="noopener noreferrer" className={LINK_CLASS}>
          {t("settings.pluginMarket.officialCatalog")}</a>
      ) : (
        <span className="text-[var(--text)]">{t("settings.pluginMarket.catalog")}</span>
      )}
      {source.signed ? (
        <span className="inline-flex items-center gap-1 text-[var(--ok)]">
          <ShieldIcon className="size-3.5" />
          {t("settings.pluginMarket.verified")}</span>
      ) : (
        <StatusPill tone="warn" label={t("settings.pluginMarket.unsigned")} />
      )}
      <span className="text-[var(--text-faint)]">
        {t("settings.pluginMarket.sourceSummary", { count: overview.plugins.length, time: formatRelativeTime(source.checked_at, locale) })}
      </span>
      <button
        type="button"
        onClick={onCheck}
        disabled={checking}
        className={`${SETTINGS_BUTTON_CLASS} ml-auto`}
      >
        <RefreshIcon className={`size-3.5 ${checking ? "animate-spin" : ""}`} />
        {checking ? t("settings.pluginMarket.checking") : t("settings.pluginMarket.check")}
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
  const t = useTranslations();
  const locale = useLocale();
  const action = marketAction(plugin, locale);
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
        {busy ? t("settings.pluginMarket.downloading") : action.label}
      </button>
    );
  }
  if (action.kind === "installed" || action.kind === "bundled") {
    const state = plugin.installed?.state ?? "active";
    return state === "active" ? (
      <span className="shrink-0 text-sub text-[var(--text-muted)]">{action.note}</span>
    ) : (
      <StatusPill {...installedStatus(state, locale)} />
    );
  }
  return (
    <span className="shrink-0 text-sub text-[var(--warn)]" title={action.note ?? undefined}>
      {action.kind === "incompatible" ? t("settings.pluginMarket.updateApp") : t("settings.pluginMarket.installBlocked")}
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
  const t = useTranslations();
  const locale = useLocale();
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
            {version?.prerelease && <StatusPill tone="warn" label={t("settings.pluginMarket.prerelease")} />}
            {plugin.deprecated && <StatusPill tone="neutral" label={t("settings.pluginMarket.deprecated")} />}
          </div>
          <div className="mt-0.5 truncate text-caption text-[var(--text-faint)]">
            {plugin.author.name} · {categoryLabel(plugin.category, locale)}
          </div>
        </div>
      </div>
      <p className="line-clamp-2 min-h-[2.5rem] text-sub leading-5 text-[var(--text-muted)]">
        {plugin.summary}
      </p>
      <div className="mt-auto flex items-center justify-between gap-3">
        <span className="min-w-0 truncate text-caption tabular-nums text-[var(--text-faint)]">
          {versionMeta(version, plugin.downloads, locale)}
        </span>
        <ActionButton plugin={plugin} downloading={downloading} onInstall={onInstall} />
      </div>
    </div>
  );
}

type DetailTab = "about" | "permissions" | "versions";

function PluginDrawer({
  plugin,
  appVersion,
  downloading,
  onClose,
  onInstall,
}: {
  plugin: MarketPlugin;
  appVersion: string | null;
  downloading: string | null;
  onClose: () => void;
  onInstall: (version: string) => void;
}) {
  const t = useTranslations();
  const locale = useLocale();
  const [tab, setTab] = useState<DetailTab>("about");
  const [detail, setDetail] = useState<MarketPluginDetail | null>(null);
  const [detailError, setDetailError] = useState<string | null>(null);
  useEffect(() => {
    setDetail(null);
    setDetailError(null);
    getMarketPlugin(plugin.id)
      .then(setDetail)
      .catch((err: unknown) => setDetailError(err instanceof Error ? err.message : t("settings.pluginMarket.loadFailed")));
  }, [plugin.id, t]);

  const version = shownVersion(plugin);
  const action = marketAction(plugin, locale);
  const installed = plugin.installed;
  const downloads = formatDownloadCount(plugin.downloads, locale);
  const feedback = feedbackLink(plugin, appVersion);
  const shots = plugin.screenshots ?? [];
  return (
    <SettingsDrawer
      open
      onClose={onClose}
      title={plugin.name}
      description={plugin.summary}
      hint={
        installed
          ? installed.source === "bundled" ? t("settings.pluginMarket.installedBundledVersion", { version: installed.version }) : t("settings.pluginMarket.installedVersion", { version: installed.version })
          : action.note ?? undefined
      }
      actions={
        <>
          {installed && (
            <Link href={pluginHref(plugin.id) as never} className={SETTINGS_BUTTON_CLASS}>
              {t("settings.pluginMarket.manage")}</Link>
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
              {downloads && (
                <span className="tabular-nums text-[var(--text-faint)]">
                  {plugin.author.name ? " · " : ""}
                  {downloads}
                </span>
              )}
            </p>
            <div className="flex flex-wrap gap-1.5">
              {version?.prerelease && <StatusPill tone="warn" label={t("settings.pluginMarket.prerelease")} />}
              {installed && (
                <StatusPill {...installedStatus(installed.state, locale)} />
              )}
            </div>
          </div>
        </div>

        {plugin.deprecated && (
          <Banner tone="warn" title={t("settings.pluginMarket.deprecatedTitle")}>
            {plugin.deprecated.reason}
            {plugin.deprecated.replaced_by && t("settings.pluginMarket.replacement", { name: plugin.deprecated.replaced_by })}
          </Banner>
        )}
        {installed?.yanked && (
          <Banner tone="danger" title={t("settings.pluginMarket.yankedTitle", { version: installed.version })}>
            {installed.yanked}
            {plugin.recommended && plugin.recommended !== installed.version
              ? t("settings.pluginMarket.recommended", { version: plugin.recommended })
              : ""}
          </Banner>
        )}
        {(action.kind === "incompatible" || action.kind === "blocked") && (
          <Banner tone="warn" title={t("settings.pluginMarket.serverIncompatible")}>
            {action.note}
          </Banner>
        )}

        {shots.length > 0 && <ScreenshotStrip urls={shots} name={plugin.name} />}

        {version?.notes.trim() && (
          <section className="space-y-2">
            <h3 className="text-caption text-[var(--text-faint)]">v{version.version} {t("settings.pluginMarket.changelog")}</h3>
            <Markdown text={version.notes} compact />
          </section>
        )}

        {feedback && (
          <a
            href={feedback}
            target="_blank"
            rel="noopener noreferrer"
            data-plugin-feedback
            className="css-glass flex min-h-[56px] items-center justify-between gap-4 !rounded-xl px-4 py-3 text-body font-medium text-[var(--text)] transition-colors hover:bg-white/[0.04]"
          >
            {t("settings.pluginMarket.feedback")}<span aria-hidden className="text-caption text-[var(--text-faint)]">
              ↗
            </span>
          </a>
        )}

        {version && (
          <p className="text-caption leading-5 text-[var(--text-faint)]">{technicalLine(plugin, version, locale)}</p>
        )}

        <SettingsTabs
          tabs={[
            { id: "about", label: t("settings.pluginMarket.about") },
            { id: "permissions", label: t("settings.pluginMarket.permissions") },
            { id: "versions", label: t("settings.pluginMarket.versions", { count: plugin.versions.length }) },
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

function technicalLine(plugin: MarketPlugin, version: MarketVersion, locale: AppLocale): string {
  const released = version.released_at ? formatDateTime(version.released_at, locale) : "";
  return [
    `v${version.version}`,
    released === "—" ? "" : released,
    version.size ? formatBytes(version.size) : "",
    runtimeLabel(version.runtime, locale),
    categoryLabel(plugin.category, locale),
    plugin.license,
    plugin.id,
  ]
    .filter(Boolean)
    .join(" · ");
}

function ScreenshotStrip({ urls, name }: { urls: string[]; name: string }) {
  const t = useTranslations();
  const [broken, setBroken] = useState<Record<number, boolean>>({});
  const visible = urls.some((_, index) => !broken[index]);
  if (!visible) return null;
  return (
    <div className="flex gap-2 overflow-x-auto scroll-thin">
      {urls.map((url, index) =>
        broken[index] ? null : (
          <img
            key={url}
            src={url}
            alt={t("settings.pluginMarket.screenshot", { name, index: index + 1 })}
            decoding="async"
            onError={() => setBroken((current) => ({ ...current, [index]: true }))}
            className="h-40 w-auto max-w-[85%] shrink-0 rounded-xl bg-white/[0.04] object-cover shadow-[inset_0_0_0_1px_rgba(255,255,255,0.08)]"
          />
        ),
      )}
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
  const t = useTranslations();
  if (error) return <p className="text-sub text-[var(--danger)]">{error}</p>;
  if (!detail) return <p className="text-sub text-[var(--text-muted)]">{t("settings.pluginMarket.readingReadme")}</p>;
  const blurb =
    plugin.description && plugin.description !== plugin.summary ? plugin.description : "";
  return (
    <div className="space-y-3">
      {blurb && <p className="text-sub leading-6 text-[var(--text-muted)]">{blurb}</p>}
      {detail.readme ? (
        <Markdown text={detail.readme} compact />
      ) : detail.readme_error ? (
        <p className="text-sub leading-6 text-[var(--danger)]">{detail.readme_error}</p>
      ) : (
        !blurb && <p className="text-sub leading-6 text-[var(--text-muted)]">{t("settings.pluginMarket.noReadme")}</p>
      )}
      {plugin.repository && (
        <a
          href={plugin.repository}
          target="_blank"
          rel="noopener noreferrer"
          className="inline-flex items-center gap-1.5 text-caption text-[var(--text-faint)] hover:text-[var(--text)]"
        >
          <GitHubMark className="size-3.5" />
          {t("settings.pluginMarket.sourceCode")}</a>
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
  const t = useTranslations();
  const locale = useLocale();
  const deps = detail?.selected === version.version ? detail.dependencies : null;
  const tone = { neutral: "text-[var(--text)]", warn: "text-[var(--warn)]", danger: "text-[var(--danger)]" };
  return (
    <div className="space-y-4">
      <p className="text-caption text-[var(--text-faint)]">{t("settings.pluginMarket.permissionsHint", { version: version.version })}</p>
      <SettingsList>
        {permissionLines(version, locale).map((line) => (
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
            {t("settings.pluginMarket.dependencySize", { size: formatBytes(deps.total_size), index: deps.index_label })}
          </p>
          <SettingsList>
            {deps.packages.map((dep) => (
              <div key={dep.name} className="flex items-center gap-3 px-4 py-2 text-sub">
                <span className="min-w-0 flex-1 truncate text-[var(--text)]">
                  {dep.name} <span className="text-[var(--text-faint)]">{dep.version}</span>
                </span>
                {dep.native && <StatusPill tone="warn" label={t("settings.pluginMarket.nativeCode")} />}
                <span className="shrink-0 tabular-nums text-[var(--text-faint)]">
                  {dep.size != null ? formatBytes(dep.size) : dep.available ? "—" : t("settings.pluginMarket.noWheel")}
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
  const t = useTranslations();
  const locale = useLocale();
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
              {versionBadges(version, plugin, locale).map((badge) => (
                <StatusPill key={badge.label} tone={badge.tone} label={badge.label} />
              ))}
              <span className="text-caption tabular-nums text-[var(--text-faint)]">
                {formatDateTime(version.released_at, locale)}
              </span>
              {canInstallVersion(version, plugin) && (
                <button
                  type="button"
                  disabled={downloading !== null}
                  onClick={() => onInstall(version.version)}
                  className={`${SETTINGS_BUTTON_CLASS} ml-auto`}
                >
                  {busy ? t("settings.pluginMarket.downloading") : installVerb(version.version, plugin, locale)}
                </button>
              )}
            </div>
            {version.yanked && (
              <p className="text-caption text-[var(--danger)]">{t("settings.pluginMarket.withdrawalReason", { reason: version.yanked })}</p>
            )}
            {!version.compatible && version.incompatible_reason && (
              <p className="text-caption text-[var(--warn)]">{version.incompatible_reason}</p>
            )}
            {version.notes ? (
              <Markdown text={version.notes} compact />
            ) : (
              <p className="text-caption text-[var(--text-faint)]">{t("settings.pluginMarket.noReleaseNotes")}</p>
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
