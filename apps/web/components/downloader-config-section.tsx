"use client";

import { useLocale, useTranslations } from "next-intl";
import { appTranslator, type AppMessageKey } from "@/lib/i18n/translate";
import type { AppLocale } from "@/lib/i18n/negotiate";

import { useCallback, useEffect, useRef, useState } from "react";

import { ErrorBanner, Toggle } from "@/components/cloud-push-ui";
import { DirectoryPicker } from "@/components/directory-picker";
import { useConfirm } from "@/components/feedback";
import { ChevronDownIcon, DownloadIcon, FolderIcon, PlusIcon, XIcon } from "@/components/icons";
import { Modal } from "@/components/modal";
import {
  SETTINGS_BUTTON_CLASS,
  SETTINGS_INPUT_CLASS,
  SETTINGS_PRIMARY_BUTTON_CLASS,
  SettingsDrawer,
  SettingsEmpty,
  SettingsMoreMenu,
  SettingsSection,
} from "@/components/settings-ui";
import {
  type ConfiguredDownloader,
  builtinDownloaderTypes,
  type DownloaderClientType,
  type DownloaderTypeInfo,
  listDownloaderTypes,
  type DownloaderLimits,
  type DownloaderPayload,
  type DownloaderStatus,
  type PathMapping,
  createDownloader,
  deleteDownloader,
  getDownloaderLimits,
  listDownloaders,
  reverifyDownloader,
  setDefaultDownloader,
  setDownloaderEnabled,
  setDownloaderLimits,
  updateDownloader,
} from "@/lib/api/downloaders";
import type { PathProbe } from "@/lib/api/downloaders";
import { listConfiguredSites, listSiteCatalog } from "@/lib/api/sites";
import { formatRelativeTime } from "@/lib/time";
import { useVisiblePolling } from "@/lib/use-visible-polling";

/** 连接状态 → 展示文案与颜色（与站点配置同语言） */
const STATUS_META: Record<DownloaderStatus, { label: AppMessageKey; color: string }> = {
  active: { label: "download.config.connected", color: "var(--ok)" },
  verifying: { label: "download.config.testing", color: "var(--info)" },
  pending: { label: "download.config.pending", color: "#c0c4cc" },
  failed: { label: "download.config.failed", color: "var(--danger)" },
};

/**
 * 选这台下载器刷流、且刷流开着的站点名称（删除确认用）。删除是低频操作，
 * 现取即可；取不到就不提示（后端照样会关闭这些站点的刷流）。
 */
async function boostSitesOn(downloaderId: number): Promise<string[]> {
  try {
    const [sites, catalog] = await Promise.all([listConfiguredSites(), listSiteCatalog()]);
    const names = new Map(catalog.map((c) => [c.site_id, c.display_name]));
    return sites
      .filter((s) => s.boost_enabled && s.boost_downloader_id === downloaderId)
      .map((s) => names.get(s.site_id) ?? s.site_id);
  } catch {
    return [];
  }
}

/**
 * 可接入的下载器类型：由下载器插件登记（官方的 qBittorrent / Transmission，或第三方插件），
 * 服务端给出名字、地址叫法与示例。整页共用一份，取一次。
 */
const typesCache = new Map<AppLocale, Promise<DownloaderTypeInfo[]>>();

function useDownloaderTypes(): DownloaderTypeInfo[] {
  const locale = useLocale() as AppLocale;
  const [types, setTypes] = useState<DownloaderTypeInfo[]>(() => builtinDownloaderTypes(locale));
  useEffect(() => {
    let alive = true;
    if (!typesCache.has(locale)) typesCache.set(locale, listDownloaderTypes(locale));
    void typesCache.get(locale)!.then((value) => {
      if (alive) setTypes(value);
    });
    return () => {
      alive = false;
    };
  }, [locale]);
  return types;
}

interface ConnectionField {
  label: string;
  placeholder?: string;
  help?: string;
}

/**
 * 表单里地址 / 用户名 / 密码三栏怎么画：以下载器插件声明的连接参数（connection）为准，
 * 没声明（旧服务端）时退回 url_label / needs_username。不要的栏为 null。
 */
function connectionFields(info: DownloaderTypeInfo, locale: AppLocale): {
  url: ConnectionField;
  username: ConnectionField | null;
  password: ConnectionField | null;
} {
  const t = appTranslator(locale);
  const props = info.connection?.properties;
  const required = new Set(info.connection?.required ?? ["url"]);
  const label = (name: string, fallback: string) => {
    const title = props?.[name]?.title || fallback;
    return required.has(name) ? title : t("download.config.optional", { title });
  };
  if (!props) {
    return {
      url: { label: info.url_label, placeholder: info.url_placeholder, help: info.help },
      username: info.needs_username ? { label: t("download.config.optionalUsername") } : null,
      password: { label: t("download.config.optionalPassword") },
    };
  }
  return {
    url: {
      label: props.url?.title || info.url_label,
      placeholder: props.url?.examples?.[0] ?? info.url_placeholder,
      help: info.help || props.url?.description,
    },
    username: props.username ? { label: label("username", t("download.config.username")) } : null,
    password: props.password ? { label: label("password", t("download.config.password")) } : null,
  };
}

function typeInfo(
  types: DownloaderTypeInfo[],
  type: DownloaderClientType,
  locale: AppLocale,
): DownloaderTypeInfo {
  const t = appTranslator(locale);
  return (
    types.find((t) => t.type === type) ?? {
      type,
      title: type,
      url_label: t("download.config.url"),
      url_placeholder: "",
      needs_username: true,
      help: t("download.config.pluginUnavailable"),
    }
  );
}

/** 需要轮询测试进度的中间态 */
const IN_PROGRESS: DownloaderStatus[] = ["pending", "verifying"];

/**
 * 「下载器」设置分区。
 *
 * 与站点配置同构：列表展示已接入的下载器，新增与编辑都在右侧抽屉里填表；
 * 保存后后端异步测试连接，前端对中间态（pending/verifying）轮询刷新，
 * 直到 active / failed。搜索结果里的"提交下载"以这里配置的实例为目标。
 */
export function DownloaderConfigSection() {
  const t = useTranslations();
  const types = useDownloaderTypes();
  const [downloaders, setDownloaders] = useState<ConfiguredDownloader[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  // 编辑抽屉：「add」= 添加下载器，数字 = 编辑该 id 的下载器
  const [drawer, setDrawer] = useState<"add" | number | null>(null);
  // 当前展开详情的下载器（单开手风琴，与站点列表同款交互）
  const [expanded, setExpanded] = useState<number | null>(null);

  const load = useCallback(async () => {
    setError(null);
    try {
      setDownloaders(await listDownloaders());
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  // 体检修复卡跳转带来的映射建议（?suggest_mapping=/xx）：自动打开默认
  // 下载器的编辑抽屉并预填一条映射的本机侧，用户只需补下载器视角的路径
  const [suggestMapping, setSuggestMapping] = useState<string | null>(null);
  useEffect(() => {
    const suggested = new URLSearchParams(window.location.search).get("suggest_mapping");
    if (suggested) setSuggestMapping(suggested);
  }, []);
  const suggestConsumed = useRef(false);
  useEffect(() => {
    if (!suggestMapping || loading || suggestConsumed.current || downloaders.length === 0) return;
    suggestConsumed.current = true;
    const target = downloaders.find((d) => d.is_default) ?? downloaders[0];
    setDrawer(target.id);
  }, [suggestMapping, loading, downloaders]);

  // 拥堵提示跳转（?limits=<id>，与 suggest_mapping 同款参数惯例）：自动打开
  // 对应下载器的「限速与队列」弹窗，用户落地即在要调的设置上
  const [autoLimitsId, setAutoLimitsId] = useState<number | null>(null);
  useEffect(() => {
    const raw = new URLSearchParams(window.location.search).get("limits");
    const id = raw == null ? Number.NaN : Number(raw);
    if (Number.isFinite(id)) setAutoLimitsId(id);
  }, []);

  // 有下载器处于 pending/verifying 时轮询刷新，直到全部落定（页面隐藏时暂停）
  const hasInProgress = downloaders.some((d) => IN_PROGRESS.includes(d.status));
  useVisiblePolling(
    () => {
      void listDownloaders()
        .then(setDownloaders)
        .catch(() => {
          /* 轮询失败静默重试，不打断页面 */
        });
    },
    hasInProgress ? 2000 : null,
  );

  // 原地替换已有条目、新条目追加到末尾（保持列表顺序稳定，避免操作后跳位）
  const upsert = useCallback((next: ConfiguredDownloader) => {
    setDownloaders((prev) => {
      const idx = prev.findIndex((d) => d.id === next.id);
      if (idx === -1) return [...prev, next];
      const copy = [...prev];
      copy[idx] = next;
      return copy;
    });
  }, []);

  const usableCount = downloaders.filter((d) => d.usable).length;
  const editingTarget =
    typeof drawer === "number" ? downloaders.find((d) => d.id === drawer) ?? null : null;

  return (
    <SettingsSection
      title={t("download.config.title")}
      description={
        loading
          ? t("download.config.loading")
          : downloaders.length === 0
            ? t("download.config.intro")
            : t("download.config.summary", { count: downloaders.length, usable: usableCount })
      }
      action={
        <div className="flex shrink-0 items-center gap-2">
          <button
            type="button"
            onClick={() => void load()}
            disabled={loading}
            className={SETTINGS_BUTTON_CLASS}
          >
            {t("download.config.refresh")}
          </button>
          <button
            type="button"
            onClick={() => setDrawer("add")}
            disabled={loading}
            className={`${SETTINGS_PRIMARY_BUTTON_CLASS} flex items-center gap-1 pl-3`}
          >
            <PlusIcon className="size-4" />
            {t("download.config.addDownloader")}
          </button>
        </div>
      }
    >
      <div className="space-y-3">
        {error && <ErrorBanner>{error}</ErrorBanner>}

        {/* 已配置下载器列表：行式布局，与设置页行组同款容器 */}
        {loading ? (
          <div className="space-y-px overflow-hidden rounded-xl border border-white/[0.08]">
            <div className="h-14 animate-pulse bg-white/[0.04]" />
            <div className="h-14 animate-pulse bg-white/[0.04]" />
          </div>
        ) : downloaders.length === 0 ? (
          <SettingsEmpty
            icon={<DownloadIcon className="size-5" />}
            title={t("download.config.empty")}
            description={t("download.config.emptyHint", {
              types: types.map((item) => item.title).join(t("download.config.listSeparator")),
            })}
          />
        ) : (
          <div className="css-glass divide-y divide-[var(--line)] overflow-hidden !rounded-xl">
            {downloaders.map((downloader) => (
              <DownloaderRow
                key={downloader.id}
                downloader={downloader}
                autoOpenLimits={autoLimitsId === downloader.id}
                expanded={expanded === downloader.id}
                onToggle={() =>
                  setExpanded((cur) => (cur === downloader.id ? null : downloader.id))
                }
                onEdit={() => setDrawer(downloader.id)}
                onChanged={upsert}
                onDeleted={(id) => {
                  setDownloaders((prev) => prev.filter((d) => d.id !== id));
                  setExpanded((cur) => (cur === id ? null : cur));
                  setDrawer((cur) => (cur === id ? null : cur));
                  // 删除默认时后端会把默认让给另一台，整体刷新拿到新归属
                  void load();
                }}
                onRefresh={() => void load()}
                onError={setError}
              />
            ))}
          </div>
        )}
      </div>

      {/* 新增 / 编辑抽屉：按目标换 key，每次打开都从该下载器的当前值起表 */}
      {(drawer === "add" || editingTarget) && (
        <DownloaderForm
          key={editingTarget?.id ?? "add"}
          downloader={editingTarget}
          suggestMapping={editingTarget ? suggestMapping : null}
          onSubmit={async (payload) => {
            upsert(
              editingTarget
                ? await updateDownloader(editingTarget.id, payload)
                : await createDownloader(payload),
            );
            setDrawer(null);
          }}
          onClose={() => setDrawer(null)}
        />
      )}
    </SettingsSection>
  );
}

/* —— 下载器行：一行一台，P0 常驻（名称 / 默认 / 状态）；点击整行展开只读详情 ——
   行尾只常驻「编辑」（打开抽屉），其余操作收进 ⋯ 菜单（启停 / 限速 / 默认 /
   重测 / 删除），不用 WebGL 开关，配置页要的是轻和稳。 */

interface DownloaderRowProps {
  downloader: ConfiguredDownloader;
  /** 拥堵提示跳转（?limits=<id>）：挂载后自动打开「限速与队列」弹窗 */
  autoOpenLimits?: boolean;
  expanded: boolean;
  onToggle: () => void;
  /** 打开编辑抽屉 */
  onEdit: () => void;
  onChanged: (downloader: ConfiguredDownloader) => void;
  onDeleted: (id: number) => void;
  /** 需要整体刷新列表的操作（如设默认会同时改动其他条目）之后调用 */
  onRefresh: () => void;
  onError: (message: string) => void;
}

function DownloaderRow({
  downloader,
  autoOpenLimits = false,
  expanded,
  onToggle,
  onEdit,
  onChanged,
  onDeleted,
  onRefresh,
  onError,
}: DownloaderRowProps) {
  const t = useTranslations();
  const locale = useLocale() as AppLocale;
  const types = useDownloaderTypes();
  const confirm = useConfirm();
  const [busy, setBusy] = useState(false);
  const [limitsOpen, setLimitsOpen] = useState(false);
  // 拥堵提示跳转落地：打开一次即完成使命，之后开合归用户（关了不复弹）
  useEffect(() => {
    if (autoOpenLimits) setLimitsOpen(true);
  }, [autoOpenLimits]);
  // 「API 通、路径瞎」是独立于连接状态的故障面：连接测试通过但映射的本地侧
  // 不可达时，绿灯是假的——下载全部无法入库。胶囊直接改口，不让用户从绿灯
  // 推断"下载器没问题"，再去别处找原因
  const pathsBroken = downloader.status === "active" && !downloader.paths_healthy;
  const meta = pathsBroken
    ? { label: "download.config.pathsBroken", color: "var(--danger)" }
    : STATUS_META[downloader.status];
  const failed = downloader.status === "failed" && !!downloader.last_error;
  const worstPath = pathsBroken
    ? downloader.path_health?.find((p) => p.state !== "ok")
    : undefined;

  async function guard(fn: () => Promise<void>) {
    setBusy(true);
    try {
      await fn();
    } catch (e) {
      onError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  // 副标题：类型 + 版本 + 上次检查时间（失败原因另起一行红字，不挤在这里）
  const subtitle = [
    typeInfo(types, downloader.client_type, locale).title,
    downloader.version,
    downloader.last_checked_at ? t("download.config.lastChecked", { time: formatRelativeTime(downloader.last_checked_at, locale) }) : null,
  ]
    .filter(Boolean)
    .join(" · ");

  return (
    <div className={downloader.enabled ? "" : "opacity-60"}>
      {/* 行主体：整行是展开热区。桌面单行；移动端错误原因折到第二行 */}
      <div
        role="button"
        tabIndex={0}
        aria-expanded={expanded}
        onClick={onToggle}
        onKeyDown={(e) => {
          if (e.key === "Enter" || e.key === " ") {
            e.preventDefault();
            onToggle();
          }
        }}
        className={`group flex min-h-[56px] cursor-pointer flex-wrap items-center gap-x-3 gap-y-1.5 px-4 py-2.5 transition-colors hover:bg-white/[0.04] focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-inset focus-visible:ring-white/25 sm:px-5 sm:py-3 ${
          expanded ? "bg-white/[0.045]" : ""
        }`}
      >
        {/* P0：图标 + 名称（可点开 WebUI）+ 默认 + 状态 */}
        <div className="flex min-w-0 flex-1 items-center gap-3">
          <span className="icon-chip size-9 shrink-0 !rounded-xl">
            <DownloadIcon className="size-[18px]" />
          </span>
          <div className="min-w-0">
            {/* 窄屏徽章允许折到名称下一行，别把名称挤成两个字 */}
            <div className="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1">
              <a
                href={downloader.url}
                target="_blank"
                rel="noreferrer"
                title={t("download.config.openWebui")}
                onClick={(e) => e.stopPropagation()}
                className="truncate text-ui font-semibold text-[var(--text)] underline decoration-transparent underline-offset-4 transition-colors hover:text-white/80 hover:decoration-white/50"
              >
                {downloader.name}
              </a>
              {downloader.is_default && (
                <span className="shrink-0 rounded-full border border-white/[0.12] bg-[var(--accent-soft)] px-2 py-0.5 text-caption font-semibold text-[var(--accent)]">
                  {t("download.config.default")}
                </span>
              )}
              <span
                className="flex shrink-0 items-center gap-1.5 rounded-full px-2 py-0.5 text-caption font-medium"
                style={{
                  background: `color-mix(in oklab, ${meta.color} 12%, transparent)`,
                  color: meta.color,
                }}
              >
                <span className="size-1.5 rounded-full" style={{ background: meta.color }} />
                {t(meta.label as AppMessageKey)}
              </span>
              {!downloader.enabled && (
                <span className="shrink-0 rounded-full bg-white/[0.08] px-2 py-0.5 text-caption font-medium text-[var(--text-muted)]">
                  {t("download.config.disabled")}
                </span>
              )}
            </div>
            <p className="mt-0.5 truncate text-caption text-[var(--text-faint)]">{subtitle}</p>
          </div>
        </div>

        {/* P1：连接失败或路径异常时把原因亮出来——那一刻没有比它更重要的信息 */}
        {(failed || worstPath) && (
          <p
            className="order-3 basis-full truncate text-caption text-[var(--danger)] sm:order-none sm:max-w-[40%] sm:basis-auto"
            title={failed ? downloader.last_error ?? undefined : worstPath?.detail}
          >
            {failed ? downloader.last_error : worstPath?.detail}
          </p>
        )}

        {/* 控制区：展开箭头 + 编辑 + 操作菜单 */}
        <div className="flex shrink-0 items-center gap-1">
          <span className="flex size-7 items-center justify-center rounded-full text-[var(--text-faint)] transition-colors group-hover:bg-white/[0.08] group-hover:text-[var(--text-muted)]">
            <ChevronDownIcon
              className={`size-4 transition-transform ${expanded ? "rotate-180" : ""}`}
            />
          </span>
          {/* 拦住冒泡：菜单经 portal 渲染，点菜单项、在按钮上按回车都不该顺带开合整行 */}
          <div
            className="flex items-center gap-1"
            onClick={(e) => e.stopPropagation()}
            onKeyDown={(e) => e.stopPropagation()}
          >
            <button type="button" onClick={onEdit} className={SETTINGS_BUTTON_CLASS}>
              {t("download.config.edit")}
            </button>
            <SettingsMoreMenu
              label={t("download.config.moreActions", { name: downloader.name })}
              items={[
                {
                  label: downloader.enabled ? t("download.config.disable") : t("download.config.enable"),
                  disabled: busy,
                  onSelect: () =>
                    void guard(async () =>
                      onChanged(await setDownloaderEnabled(downloader.id, !downloader.enabled)),
                    ),
                },
                { label: t("download.config.limitsAction"), disabled: busy, onSelect: () => setLimitsOpen(true) },
                {
                  label: t("download.config.makeDefault"),
                  disabled: busy || downloader.is_default,
                  onSelect: () =>
                    void guard(async () => {
                      await setDefaultDownloader(downloader.id);
                      // 原默认的标记同时被清掉，整体刷新一次拿到全量新状态
                      onRefresh();
                    }),
                },
                {
                  label: t("download.config.retest"),
                  disabled: busy || IN_PROGRESS.includes(downloader.status),
                  onSelect: () =>
                    void guard(async () => onChanged(await reverifyDownloader(downloader.id))),
                },
                {
                  label: t("download.config.deleteConfig"),
                  danger: true,
                  disabled: busy,
                  onSelect: () =>
                    void guard(async () => {
                      // 选它做刷流下载器的站点会被一并关闭刷流（后端执行，见
                      // DownloaderConfigService.delete），确认前讲清楚影响哪些站点
                      const boostSites = await boostSitesOn(downloader.id);
                      if (
                        !(await confirm({
                          title: t("download.config.deleteTitle", { name: downloader.name }),
                          description: t("download.config.deleteHint"),
                          bullets:
                            boostSites.length > 0
                              ? [
                                  t("download.config.deleteBoostWarning", { sites: boostSites.join(t("download.config.listSeparator")) }),
                                  t("download.config.deleteBoostHint"),
                                ]
                              : undefined,
                          confirmLabel: t("download.config.delete"),
                          tone: "danger",
                        }))
                      ) {
                        return;
                      }
                      await deleteDownloader(downloader.id);
                      onDeleted(downloader.id);
                    }),
                },
              ]}
            />
          </div>
        </div>
      </div>

      {/* 展开详情（只读）：连接 / 保存目录 / 路径映射；编辑在抽屉里 */}
      {expanded && (
        <div className="divide-y divide-white/[0.05] border-t border-white/[0.06] bg-white/[0.02] px-4 py-3 sm:px-5">
          <DetailSection label={t("download.config.connection")}>
            <StatGrid>
              <DetailStat
                label={t("download.config.url")}
                value={downloader.url}
                href={downloader.url}
                title={t("download.config.openWebui")}
                wide
              />
              <DetailStat label={t("download.config.username")} value={downloader.username ?? t("download.config.notSet")} />
              <DetailStat label={t("download.config.version")} value={downloader.version ?? "—"} />
            </StatGrid>
          </DetailSection>
          <DetailSection label={t("download.config.storage")}>
            <StatGrid>
              <DetailStat
                label={t("download.config.savePath")}
                value={downloader.save_path ?? t("download.config.downloaderDefault")}
                wide
              />
            </StatGrid>
          </DetailSection>
          <DetailSection label={t("download.config.mapping")}>
            <PathMappingTable
              mappings={downloader.path_mappings ?? []}
              health={downloader.path_health ?? []}
            />
          </DetailSection>
        </div>
      )}

      <DownloaderLimitsModal
        open={limitsOpen}
        downloader={downloader}
        onClose={() => setLimitsOpen(false)}
      />
    </div>
  );
}

/* —— 详情排版原语（与站点页同款）：段标签在桌面抽成左侧固定列，内容左缘对齐 —— */

function DetailSection({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <section className="grid gap-1.5 py-3 first:pt-1 last:pb-1 sm:grid-cols-[46px_minmax(0,1fr)] sm:gap-x-4 sm:gap-y-0">
      <p className="text-micro font-medium tracking-wide text-[var(--text-faint)] sm:pt-2">
        {label}
      </p>
      <div className="min-w-0 space-y-2">{children}</div>
    </section>
  );
}

/** 统计区容器：等宽列，不给底色和描边，层级靠对齐与字重撑住 */
function StatGrid({ children }: { children: React.ReactNode }) {
  return <div className="grid grid-cols-2 gap-x-5 gap-y-3 sm:grid-cols-4">{children}</div>;
}

/**
 * 单个信息项：淡色小标签在上、值在下。带 href 时值是可点的外链（新窗口打开）；
 * wide 让长值（地址、目录）横跨两列，不与短值抢宽度。
 */
function DetailStat({
  label,
  value,
  href,
  title,
  wide = false,
}: {
  label: string;
  value: string;
  href?: string;
  title?: string;
  wide?: boolean;
}) {
  const valueClass = "mt-0.5 block truncate text-ui font-semibold text-[var(--text)] max-sm:text-sub";
  return (
    <div className={`min-w-0 ${wide ? "col-span-2" : ""}`}>
      <p className="truncate text-micro text-[var(--text-faint)]">{label}</p>
      {href ? (
        <a
          href={href}
          target="_blank"
          rel="noreferrer"
          title={ title }
          onClick={(e) => e.stopPropagation()}
          className={`${valueClass} underline decoration-transparent underline-offset-4 transition-colors hover:text-white/80 hover:decoration-white/50`}
        >
          {value}
        </a>
      ) : (
        <p className={valueClass} title={value}>
          {value}
        </p>
      )}
    </div>
  );
}

/**
 * 路径映射对照表：一条映射一行，左列是 MovieClaw 看到的路径，右列是下载器看到的
 * 同一个位置，中间箭头表达"翻译"方向。跨容器部署时两边对同一块盘叫不同名字，
 * 这张表就是核对"投递时路径会被翻成什么"的地方——比一行分号串好读得多。
 */
/** 路径体检状态 → 展示。ok 不额外标注（正常不该抢注意力），异常各给一个短词 */
const PATH_STATE_LABEL: Record<Exclude<PathProbe["state"], "ok">, AppMessageKey> = {
  empty: "download.config.emptyDirectory",
  not_dir: "download.config.notDirectory",
  missing: "download.config.missing",
  unmapped: "download.config.unmapped",
};

/**
 * 映射表。每行右侧挂本地侧的体检结论：配置"看起来对"而运行时挂载失效时，
 * 这里是唯一能让用户不靠命令行就看出"目录是空的"的地方——那正是文案
 * "请检查路径映射"把人引过来之后，必须能给出答案的位置。
 */
function PathMappingTable({
  mappings,
  health,
}: {
  mappings: PathMapping[];
  health: PathProbe[];
}) {
  const t = useTranslations();
  if (mappings.length === 0) {
    return (
      <p className="pt-1.5 text-sub text-[var(--text-muted)]">
        {t("download.config.noMappings")}
      </p>
    );
  }
  const probeOf = (local: string) => health.find((p) => p.local === local);
  return (
    <div className="overflow-hidden rounded-lg border border-white/[0.07]">
      <div className="grid grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)] items-center gap-x-3 bg-white/[0.03] px-3 py-1.5 text-micro font-medium tracking-wide text-[var(--text-faint)]">
        <span>{t("download.config.localView")}</span>
        <span aria-hidden="true" className="w-4" />
        <span>{t("download.config.remoteView")}</span>
      </div>
      <ul className="divide-y divide-white/[0.05]">
        {mappings.map((m, i) => {
          const probe = probeOf(m.local);
          const broken = probe && probe.state !== "ok";
          return (
            <li key={`${m.local}→${m.remote}:${i}`} className="px-3 py-2">
              <div className="grid grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)] items-center gap-x-3">
                <span className="flex min-w-0 items-center gap-2">
                  <code
                    className={`truncate font-mono text-sub ${broken ? "text-[var(--danger)]" : "text-[var(--text)]"}`}
                    title={m.local}
                  >
                    {m.local}
                  </code>
                  {broken && (
                    <span className="shrink-0 rounded-full bg-[color-mix(in_oklab,var(--danger)_14%,transparent)] px-1.5 py-px text-micro font-medium text-[var(--danger)]">
                      {t(PATH_STATE_LABEL[probe.state as keyof typeof PATH_STATE_LABEL])}
                    </span>
                  )}
                </span>
                <span aria-hidden="true" className="w-4 text-center text-[var(--text-faint)]">
                  →
                </span>
                <code className="truncate font-mono text-sub text-[var(--text)]" title={m.remote}>
                  {m.remote}
                </code>
              </div>
              {broken && (
                <p className="mt-1 text-caption leading-snug text-[var(--text-muted)]">
                  {probe.detail}
                </p>
              )}
            </li>
          );
        })}
      </ul>
    </div>
  );
}

/* —— 限速与队列弹窗：实时读写下载器的全局限速与任务队列上限 ——
   队列上限（qB 最大活动种子数 / Tr 下载与做种队列）决定同时活动的任务数，
   刷流做种多时最容易撞上：任务进 queued 排队、免费窗口内可能下不完。 */

const KIB = 1024;

function DownloaderLimitsModal({
  open,
  downloader,
  onClose,
}: {
  open: boolean;
  downloader: ConfiguredDownloader;
  onClose: () => void;
}) {
  const t = useTranslations();
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // 表单态：限速以 KiB/s 字符串承载（空 = 不限速）；队列数值空 = 保持现状
  const [dlKib, setDlKib] = useState("");
  const [upKib, setUpKib] = useState("");
  const [altSpeed, setAltSpeed] = useState(false);
  const [queueEnabled, setQueueEnabled] = useState(false);
  const [maxDown, setMaxDown] = useState("");
  const [maxUp, setMaxUp] = useState("");
  const [maxTotal, setMaxTotal] = useState("");
  // Transmission 没有「最大活动种子数」概念（读回 null 时隐藏该输入）
  const [supportsMaxTotal, setSupportsMaxTotal] = useState(true);

  const applyLimits = useCallback((limits: DownloaderLimits) => {
    setDlKib(
      limits.download_limit_bytes != null
        ? String(Math.round(limits.download_limit_bytes / KIB))
        : "",
    );
    setUpKib(
      limits.upload_limit_bytes != null
        ? String(Math.round(limits.upload_limit_bytes / KIB))
        : "",
    );
    setAltSpeed(Boolean(limits.alt_speed_enabled));
    setQueueEnabled(Boolean(limits.queue_enabled));
    setMaxDown(limits.max_active_downloads != null ? String(limits.max_active_downloads) : "");
    setMaxUp(limits.max_active_uploads != null ? String(limits.max_active_uploads) : "");
    setMaxTotal(
      limits.max_active_torrents != null ? String(limits.max_active_torrents) : "",
    );
    setSupportsMaxTotal(limits.max_active_torrents != null);
  }, []);

  useEffect(() => {
    if (!open) return;
    setLoading(true);
    setError(null);
    getDownloaderLimits(downloader.id)
      .then((limits) => applyLimits(limits))
      .catch((e) => setError((e as Error).message))
      .finally(() => setLoading(false));
  }, [open, downloader.id, applyLimits]);

  function parseSpeed(raw: string): number | null {
    if (!raw.trim()) return null; // 空 = 不限速
    const kib = Math.round(Number(raw.trim()));
    return Number.isFinite(kib) && kib > 0 ? kib * KIB : null;
  }

  function parseCount(raw: string): number | null {
    if (!raw.trim()) return null; // 空 = 保持现状
    const value = Math.round(Number(raw.trim()));
    return Number.isFinite(value) && value >= 0 ? value : null;
  }

  async function save() {
    setBusy(true);
    setError(null);
    try {
      const applied = await setDownloaderLimits(downloader.id, {
        download_limit_bytes: parseSpeed(dlKib),
        upload_limit_bytes: parseSpeed(upKib),
        alt_speed_enabled: altSpeed,
        queue_enabled: queueEnabled,
        max_active_downloads: parseCount(maxDown),
        max_active_uploads: parseCount(maxUp),
        max_active_torrents: supportsMaxTotal ? parseCount(maxTotal) : null,
      });
      applyLimits(applied); // 回读生效值（下载器可能钳制），表单即时对齐
      onClose();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal open={open} onClose={onClose} label={t("download.config.limits")} width="lg">
      {/* 头部常驻 */}
      <div className="border-b border-white/[0.07] px-6 pb-4 pt-6">
        <h2 className="text-title font-bold text-[var(--text)]">
          {t("download.config.limitsTitle", { name: downloader.name })}
        </h2>
        <p className="mt-1 text-sub leading-5 text-[var(--text-muted)]">
          {t("download.config.limitsHint")}
        </p>
      </div>

      <div className="scroll-thin min-h-0 flex-1 space-y-4 overflow-y-auto px-6 py-4">
        {error && <ErrorBanner>{error}</ErrorBanner>}

        {loading ? (
          <div className="space-y-2">
            <div className="h-11 animate-pulse rounded-xl bg-white/[0.04]" />
            <div className="h-11 animate-pulse rounded-xl bg-white/[0.04]" />
          </div>
        ) : (
          <div className="space-y-4">
            <div className="grid grid-cols-2 gap-3 max-md:grid-cols-1">
              <LimitInput
                label={t("download.config.downloadLimit")}
                value={dlKib}
                unit="KiB/s"
                placeholder={t("download.config.unlimited")}
                disabled={busy}
                onChange={setDlKib}
              />
              <LimitInput
                label={t("download.config.uploadLimit")}
                value={upKib}
                unit="KiB/s"
                placeholder={t("download.config.unlimited")}
                disabled={busy}
                onChange={setUpKib}
              />
            </div>

            <label className="flex items-center justify-between gap-3">
              <span className="text-sub text-[var(--text-muted)]">
                {t("download.config.alternativeHint")}
              </span>
              <Toggle checked={altSpeed} disabled={busy} label={t("download.config.alternative")} onChange={setAltSpeed} />
            </label>

            <label className="flex items-center justify-between gap-3">
              <span className="text-sub text-[var(--text-muted)]">
                {t("download.config.queueHint")}
              </span>
              <Toggle
                checked={queueEnabled}
                disabled={busy}
                label={t("download.config.queue")}
                onChange={setQueueEnabled}
              />
            </label>

            {queueEnabled && (
              <div className="grid grid-cols-3 gap-3 max-md:grid-cols-1">
                <LimitInput
                  label={t("download.config.maxDownloads")}
                  value={maxDown}
                  disabled={busy}
                  onChange={setMaxDown}
                />
                <LimitInput
                  label={t("download.config.maxUploads")}
                  value={maxUp}
                  disabled={busy}
                  onChange={setMaxUp}
                />
                {supportsMaxTotal && (
                  <LimitInput
                    label={t("download.config.maxTorrents")}
                    value={maxTotal}
                    disabled={busy}
                    onChange={setMaxTotal}
                  />
                )}
              </div>
            )}
          </div>
        )}
      </div>

      {/* 底栏常驻 */}
      <div className="flex justify-end gap-2 border-t border-white/[0.07] px-6 py-4">
        <button type="button" onClick={onClose} disabled={busy} className={SETTINGS_BUTTON_CLASS}>
          {t("download.config.cancel")}
        </button>
        <button
          type="button"
          onClick={() => void save()}
          disabled={busy || loading}
          className={SETTINGS_PRIMARY_BUTTON_CLASS}
        >
          {busy ? t("download.config.saving") : t("download.config.save")}
        </button>
      </div>
    </Modal>
  );
}

/** 带单位后缀的数字输入（与 feedback 层 prompt 的单位内嵌设计同款）。 */
function LimitInput({
  label,
  value,
  unit,
  placeholder,
  disabled,
  onChange,
}: {
  label: string;
  value: string;
  unit?: string;
  placeholder?: string;
  disabled?: boolean;
  onChange: (value: string) => void;
}) {
  return (
    <div>
      <label className="mb-1.5 block text-caption font-medium text-[var(--text-muted)]">
        {label}
      </label>
      <div className="relative">
        <input
          type="number"
          min={0}
          value={value}
          placeholder={placeholder}
          disabled={disabled}
          onChange={(e) => onChange(e.target.value)}
          className={`${SETTINGS_INPUT_CLASS} w-full [appearance:textfield] [&::-webkit-inner-spin-button]:appearance-none [&::-webkit-outer-spin-button]:appearance-none ${
            unit ? "pr-14" : ""
          }`}
        />
        {unit && (
          <span className="pointer-events-none absolute inset-y-0 right-3 flex items-center text-caption font-medium text-[var(--text-faint)]">
            {unit}
          </span>
        )}
      </div>
    </div>
  );
}

/* —— 连接表单抽屉：类型 + 名称 + 地址 + 可选凭证/保存目录，新增与编辑共用 —— */

interface DownloaderFormProps {
  /** 编辑对象；null 表示新增 */
  downloader: ConfiguredDownloader | null;
  /** 体检跳转建议预填的映射本机侧路径（无建议时不传） */
  suggestMapping?: string | null;
  onSubmit: (payload: DownloaderPayload) => Promise<void>;
  onClose: () => void;
}

/** 已有映射按前缀已覆盖建议路径时不再追加，避免预填出冗余行。 */
function withSuggestedMapping(existing: PathMapping[], suggest: string | null): PathMapping[] {
  if (!suggest) return existing;
  const norm = (p: string) => p.trim().replace(/\/+$/, "") || "/";
  const target = norm(suggest);
  const covered = existing.some((m) => {
    const local = norm(m.local);
    return local !== "/" && (target === local || target.startsWith(local + "/"));
  });
  return covered ? existing : [...existing, { local: suggest, remote: "" }];
}

function DownloaderForm({
  downloader,
  suggestMapping = null,
  onSubmit,
  onClose,
}: DownloaderFormProps) {
  const t = useTranslations();
  const locale = useLocale() as AppLocale;
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const types = useDownloaderTypes();
  const [clientType, setClientType] = useState<DownloaderClientType>(
    downloader?.client_type ?? "qbittorrent",
  );
  const info = typeInfo(types, clientType, locale);
  // 地址 / 用户名 / 密码三栏按下载器插件声明的连接参数画（叫法、示例、要不要、可不可选）
  const fields = connectionFields(info, locale);
  const [name, setName] = useState(downloader?.name ?? "");
  const [url, setUrl] = useState(downloader?.url ?? "");
  const [username, setUsername] = useState(downloader?.username ?? "");
  // 出于安全后端不回传密码，编辑时留空需重新填写（未开鉴权则保持留空）
  const [password, setPassword] = useState("");
  const [savePath, setSavePath] = useState(downloader?.save_path ?? "");
  // 路径映射：跨容器部署时 movieclaw 与下载器看同一块盘的两个名字。
  // 体检跳转带建议时预填一行本机侧（右侧留给用户按下载器视角补齐）
  const [mappings, setMappings] = useState<PathMapping[]>(
    withSuggestedMapping(downloader?.path_mappings ?? [], suggestMapping),
  );
  // 已有映射的编辑态或带预填建议时默认展开，否则折叠（绝大多数部署用不到）
  const [mappingsOpen, setMappingsOpen] = useState(
    (downloader?.path_mappings?.length ?? 0) > 0 || suggestMapping !== null,
  );
  // 目录弹窗当前服务的字段："save" = 默认保存目录，数字 = 第 N 条映射的左列
  const [pickerTarget, setPickerTarget] = useState<"save" | number | null>(null);
  // 体检跳转落地：抽屉打开即滚到路径映射，用户直接补下载器视角那一列
  const mappingsRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (suggestMapping) mappingsRef.current?.scrollIntoView({ block: "start" });
  }, [suggestMapping]);

  // 映射行要么删掉要么填完整：下载器侧必须是绝对路径
  const mappingsComplete = mappings.every(
    (m) => m.local.trim().length > 0 && m.remote.trim().startsWith("/"),
  );
  // 两端各自查重（尾部斜杠归一后比较）：同一 movieclaw 路径两条映射翻译结果
  // 看遍历顺序，两条映射指向同一下载器路径同样是错配
  const normPath = (p: string) => p.trim().replace(/\/+$/, "") || "/";
  const localPaths = mappings.map((m) => normPath(m.local)).filter((p) => p !== "/");
  const remotePaths = mappings.map((m) => normPath(m.remote)).filter((p) => p !== "/");
  const mappingsUnique =
    new Set(localPaths).size === localPaths.length &&
    new Set(remotePaths).size === remotePaths.length;
  const canSubmit =
    name.trim().length > 0 &&
    /^https?:\/\/.+/.test(url.trim()) &&
    mappingsComplete &&
    mappingsUnique;

  function submit() {
    setBusy(true);
    setError(null);
    void onSubmit({
      name: name.trim(),
      client_type: clientType,
      url: url.trim(),
      // 这种下载器不要的栏不提交（切换类型后残留的值不带过去）
      username: fields.username ? username.trim() || null : null,
      password: fields.password ? password || null : null,
      save_path: savePath.trim() || null,
      path_mappings: mappings.length
        ? mappings.map((m) => ({ local: m.local.trim(), remote: m.remote.trim() }))
        : null,
      enabled: downloader?.enabled ?? true,
    })
      .catch((e) => setError((e as Error).message))
      .finally(() => setBusy(false));
  }

  function setMapping(index: number, patch: Partial<PathMapping>) {
    setMappings((prev) => prev.map((m, i) => (i === index ? { ...m, ...patch } : m)));
  }

  const inputClass = `${SETTINGS_INPUT_CLASS} w-full`;
  const labelClass = "mb-1.5 block text-sub font-medium text-[var(--text-muted)]";

  return (
    <SettingsDrawer
      open
      // 目录选择器叠在抽屉上时，同一下 Esc 只该关掉选择器
      onClose={() => {
        if (pickerTarget === null) onClose();
      }}
      title={downloader ? t("download.config.editTitle", { name: downloader.name }) : t("download.config.addDownloader")}
      actions={
        <>
          <button type="button" onClick={onClose} className={SETTINGS_BUTTON_CLASS}>
            {t("download.config.cancel")}
          </button>
          <button
            type="button"
            onClick={submit}
            disabled={busy || !canSubmit}
            className={SETTINGS_PRIMARY_BUTTON_CLASS}
          >
            {busy ? t("download.config.saving") : downloader ? t("download.config.save") : t("download.config.add")}
          </button>
        </>
      }
    >
      <div className="space-y-4">
        {error && <ErrorBanner>{error}</ErrorBanner>}

        {/* 下载器类型 */}
        <div>
          <label className={labelClass}>{t("download.config.type")}</label>
          <div className="flex flex-wrap gap-2">
            {types.map((t) => (
              <button
                key={t.type}
                type="button"
                onClick={() => setClientType(t.type)}
                data-active={clientType === t.type}
                className="glass-row nav-item !w-auto px-3 py-1.5 text-sub font-medium"
              >
                {t.title}
              </button>
            ))}
          </div>
        </div>

        <div>
          <label className={labelClass}>{t("download.config.name")}</label>
          <input
            type="text"
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder={t("download.config.namePlaceholder")}
            autoComplete="off"
            className={inputClass}
          />
        </div>

        <div>
          <label className={labelClass}>{fields.url.label}</label>
          <input
            type="text"
            value={url}
            onChange={(e) => setUrl(e.target.value)}
            placeholder={fields.url.placeholder}
            autoComplete="off"
            className={inputClass}
          />
          {fields.url.help && (
            <p className="mt-1 text-caption text-[var(--text-faint)]">{fields.url.help}</p>
          )}
        </div>

        {/* 凭证：只画这种下载器要的栏；未开鉴权的可留空 */}
        {(fields.username || fields.password) && (
          <div className={`grid gap-3 ${fields.username && fields.password
            ? locale === "en" ? "grid-cols-2 max-sm:grid-cols-1" : "grid-cols-2"
            : ""}`}>
            {fields.username && (
              <div>
                <label className={labelClass}>{fields.username.label}</label>
                <input
                  type="text"
                  value={username}
                  onChange={(e) => setUsername(e.target.value)}
                  autoComplete="off"
                  className={inputClass}
                />
              </div>
            )}
            {fields.password && (
              <div>
                <label className={labelClass}>{fields.password.label}</label>
                <input
                  type="password"
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  placeholder={downloader ? t("download.config.passwordPlaceholder") : ""}
                  autoComplete="new-password"
                  className={inputClass}
                />
              </div>
            )}
          </div>
        )}

        <div>
          <label className={labelClass}>{t("download.config.optionalSavePath")}</label>
          <div className="flex items-center gap-2">
            <button
              type="button"
              onClick={() => setPickerTarget("save")}
              className="flex min-w-0 flex-1 items-center gap-2 rounded-lg border border-white/[0.08] bg-black/25 px-3 py-1.5 text-left transition-colors hover:border-[var(--accent)]/50"
            >
              <FolderIcon className="size-4 shrink-0 text-[var(--accent)]/80" />
              {savePath ? (
                <span dir="rtl" className="min-w-0 flex-1 truncate font-mono text-ui text-[var(--text)]">
                  {"‎" + savePath + "‎"}
                </span>
              ) : (
                <span className="text-ui text-[var(--text-faint)]">{t("download.config.browseDirectory")}</span>
              )}
            </button>
            {savePath && (
              <button
                type="button"
                onClick={() => setSavePath("")}
                aria-label={t("download.config.clearSavePath")}
                className="glass-row !w-auto shrink-0 p-2"
              >
                <XIcon className="size-4" />
              </button>
            )}
          </div>
          <p className="mt-1.5 text-caption leading-relaxed text-[var(--text-faint)]">
            {t("download.config.savePathHint")}
          </p>
        </div>

        {/* 路径映射：默认折叠，仅跨容器/跨主机部署需要展开配置 */}
        <div ref={mappingsRef} className="scroll-mt-2">
          <button
            type="button"
            onClick={() => setMappingsOpen((v) => !v)}
            className="flex items-center gap-1.5 text-sub font-medium text-[var(--text-muted)] transition-colors hover:text-[var(--text)]"
          >
            <span
              className="inline-block transition-transform"
              style={{ transform: mappingsOpen ? "rotate(90deg)" : undefined }}
            >
              ›
            </span>
            {t("download.config.optionalMappings")}
            {!mappingsOpen && mappings.length > 0 && (
              <span className="text-[var(--text-faint)]">{t("download.config.mappingCount", { count: mappings.length })}</span>
            )}
          </button>
          {mappingsOpen && (
            <div className="mt-2.5 space-y-2.5">
              <p className="text-caption leading-relaxed text-[var(--text-faint)]">
                {t.rich("download.config.mappingHint", {
                  local: (chunks) => <code className="mx-0.5 font-mono">{chunks}</code>,
                  remote: (chunks) => <code className="mx-0.5 font-mono">{chunks}</code>,
                })}
              </p>
              {suggestMapping && (
                <p className="rounded-lg bg-[var(--accent-soft)] px-3 py-2 text-caption leading-relaxed text-[var(--accent)]">
                  {t("download.config.suggestedMapping", { path: suggestMapping })}
                </p>
              )}
              {mappings.map((mapping, index) => (
                <div key={index} className="flex items-center gap-2">
                  <button
                    type="button"
                    onClick={() => setPickerTarget(index)}
                    title={t("download.config.browseLocalPath")}
                    className="flex min-w-0 flex-1 items-center gap-2 rounded-lg border border-white/[0.08] bg-black/25 px-3 py-1.5 text-left transition-colors hover:border-[var(--accent)]/50"
                  >
                    <FolderIcon className="size-4 shrink-0 text-[var(--accent)]/80" />
                    {mapping.local ? (
                      <span dir="rtl" className="min-w-0 flex-1 truncate font-mono text-ui text-[var(--text)]">
                        {"‎" + mapping.local + "‎"}
                      </span>
                    ) : (
                      <span className="truncate text-ui text-[var(--text-faint)]">{t("download.config.localPathPlaceholder")}</span>
                    )}
                  </button>
                  {/* 箭头即按钮：两边路径一致时点一下把左侧复制到右侧，省去手动输入 */}
                  <button
                    type="button"
                    onClick={() => setMapping(index, { remote: mapping.local })}
                    disabled={!mapping.local}
                    title={t("download.config.copyPathHint")}
                    aria-label={t("download.config.copyPath")}
                    className="shrink-0 rounded-lg px-1.5 py-1 text-[var(--text-faint)] transition-colors enabled:hover:bg-white/[0.06] enabled:hover:text-[var(--accent)] disabled:cursor-default"
                  >
                    →
                  </button>
                  <input
                    type="text"
                    value={mapping.remote}
                    onChange={(e) => setMapping(index, { remote: e.target.value })}
                    placeholder={t("download.config.remotePathPlaceholder")}
                    autoComplete="off"
                    className={`${inputClass} flex-1 font-mono`}
                  />
                  <button
                    type="button"
                    onClick={() => setMappings((prev) => prev.filter((_, i) => i !== index))}
                    aria-label={t("download.config.removeMapping")}
                    className="glass-row !w-auto shrink-0 p-2"
                  >
                    <XIcon className="size-4" />
                  </button>
                </div>
              ))}
              <button
                type="button"
                onClick={() => setMappings((prev) => [...prev, { local: "", remote: "" }])}
                className="btn-glass flex items-center gap-1 px-3 py-1.5 text-sub font-medium"
              >
                <PlusIcon className="size-3.5" />
                {t("download.config.addMapping")}
              </button>
              {!mappingsComplete ? (
                <p className="text-caption text-[#ffb46b]">
                  {t("download.config.incompleteMappings")}
                </p>
              ) : !mappingsUnique ? (
                <p className="text-caption text-[#ffb46b]">
                  {t("download.config.duplicateMappings")}
                </p>
              ) : null}
            </div>
          )}
        </div>

        <DirectoryPicker
          open={pickerTarget !== null}
          initialPath={
            pickerTarget === "save"
              ? savePath || undefined
              : typeof pickerTarget === "number"
                ? mappings[pickerTarget]?.local || undefined
                : undefined
          }
          onClose={() => setPickerTarget(null)}
          onSelect={(path) => {
            if (pickerTarget === "save") setSavePath(path);
            else if (typeof pickerTarget === "number") setMapping(pickerTarget, { local: path });
            setPickerTarget(null);
          }}
        />
      </div>
    </SettingsDrawer>
  );
}
