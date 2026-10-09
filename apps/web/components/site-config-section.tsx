"use client";

import { useCallback, useEffect, useMemo, useState, type ReactNode } from "react";

import * as DropdownMenu from "@radix-ui/react-dropdown-menu";

import { useConfirm, useToast } from "@/components/feedback";
import { Modal } from "@/components/modal";
import { CheckIcon, ChevronDownIcon, PlusIcon, ServerIcon, ShieldIcon } from "@/components/icons";
import { Banner, ErrorBanner } from "@/components/cloud-push-ui";
import { ExtensionCard } from "@/components/extension-settings";
import { SearchSection } from "@/components/search-settings";
import {
  SETTINGS_BUTTON_CLASS,
  SETTINGS_INPUT_CLASS,
  SETTINGS_PRIMARY_BUTTON_CLASS,
  SettingsDrawer,
  SettingsEmpty,
  SettingsMoreMenu,
  SettingsSection,
  SettingsTabs,
} from "@/components/settings-ui";
import { boostCleanupCheckbox, boostCleanupSummary } from "@/lib/boost-cleanup";
import { useTabParam } from "@/lib/use-tab-param";
import { type ConfiguredDownloader, listDownloaders } from "@/lib/api/downloaders";
import type { ConfiguredSite, SiteAuthType, SiteStatus } from "@/lib/api/extension";
import {
  type AuthTypeRequirement,
  type CatalogItem,
  type SiteBoostStats,
  type SiteConfigPayload,
  type SiteSyncStats,
  cleanupBoostPool,
  configureSite,
  deleteSite,
  getConfiguredSite,
  listConfiguredSites,
  listSiteBoostStats,
  listSiteCatalog,
  listSiteSyncStats,
  reverifySite,
  setSiteBoostPaused,
  setSiteEnabled,
  setSiteProtection,
  setSiteRatioBoost,
  updateSite,
} from "@/lib/api/sites";
import Link from "next/link";
import type { Route } from "next";

import { useDownloadTasks } from "@/lib/download-tasks";
import { formatBytes, formatCompact, formatDuration, formatRatio } from "@/lib/format";
import { cachedImageUrl } from "@/lib/image-proxy";
import { formatRelativeTime } from "@/lib/time";
import { useVisiblePolling } from "@/lib/use-visible-polling";

/*
 * 页面信息架构（docs/design/site-protection-ratio-boost.md 之外的 UI 决策）：
 * 每站默认一行，按优先级从左到右排——
 *   P0 常驻：名称 + 验证状态（异常原因直接吃掉徽章位）；
 *   P1 条件徽章：保护中 / 刷流用量与近 24h 产出——开了才出现，不开不占版面；
 *   P2 展开可见（只读）：账号统计 / 索引同步 / 刷流设置 / 授权信息；
 *   操作全收进 ⋯ 菜单（启停 / 保护 / 重验 / 删除），卡面只留信息；
 *   添加站点与编辑授权在右侧抽屉里填表，不在列表里展开。
 * 展开详情的排版：段标签在桌面抽成左侧固定列（各段内容左缘对齐、统计纵向成列），
 *   统计走等宽列（2 → 3 → 4 列）+ 等宽数字，段与段之间用发丝线分隔——
 *   替代原来的「标签在上 + 自然排布」，后者在宽屏上列宽参差、留白散。
 *   统计刻意不加底色小卡：层级靠对齐与字重撑住，加卡片会把这页的「轻」丢掉。
 * 列表容器与设置页行组同款（.css-glass，主题换皮自动生效），不用 WebGL 开关：
 * 配置页要的是轻和稳（移动端尤其）。移动端徽章行自动折到第二行，整行是
 * 展开热区。异常站点置顶 + 顶部健康摘要，把「是否正常」从逐卡看变成一行知。
 */

/** 站点验证状态 → 展示文案与颜色 */
const STATUS_META: Record<SiteStatus, { label: string; color: string }> = {
  active: { label: "已验证", color: "var(--ok)" },
  verifying: { label: "验证中", color: "var(--info)" },
  pending: { label: "待验证", color: "#c0c4cc" },
  failed: { label: "验证失败", color: "var(--danger)" },
};

/** 授权类型 → 中文名 */
const AUTH_TYPE_LABEL: Record<SiteAuthType, string> = {
  cookie: "Cookie",
  apikey: "API 密钥",
  credential: "用户名密码",
};

/** 表单字段名 → 中文标签 & 输入类型 */
const FIELD_META: Record<string, { label: string; kind: "text" | "password" | "textarea" }> = {
  cookie: { label: "Cookie 字符串", kind: "textarea" },
  api_key: { label: "API 密钥", kind: "password" },
  username: { label: "用户名", kind: "text" },
  password: { label: "密码", kind: "password" },
};

/** 需要轮询验证进度的中间态 */
const IN_PROGRESS: SiteStatus[] = ["pending", "verifying"];

/** 本分区的两档内容（见 SiteConfigSection 顶部的页签） */
const TABS = [
  { id: "sites", label: "站点接入" },
  { id: "search", label: "搜索分类" },
] as const;

type SiteTab = (typeof TABS)[number]["id"];

const GIB = 1024 ** 3;

/** 目录中缺失该站点时的兜底展示（例如站点已从系统下架但仍有历史配置） */
function fallbackItem(siteId: string): CatalogItem {
  return { site_id: siteId, display_name: siteId, base_url: "", supported_auth_types: [] };
}

/**
 * 「资源站点」分区的动态副标题（设置头部用）：有站点时显示健康统计——
 * 「已接入 X 个站点，全部正常 / Y 个异常需要关注」；还没接入任何站点时
 * 回落功能介绍文案（fallback），此时统计没有意义、介绍才有引导价值。
 */
export function SitesSectionSubtitle({ fallback }: { fallback: string }) {
  const [sites, setSites] = useState<ConfiguredSite[] | null>(null);
  useEffect(() => {
    let alive = true;
    listConfiguredSites()
      .then((rows) => {
        if (alive) setSites(rows);
      })
      .catch(() => {
        /* 拉取失败保持介绍文案，分区主体会展示具体错误 */
      });
    return () => {
      alive = false;
    };
  }, []);

  if (!sites || sites.length === 0) return <>{fallback}</>;
  const failed = sites.filter((s) => s.status === "failed").length;
  if (failed > 0) {
    return (
      <>
        已接入 {sites.length} 个站点，
        <span className="font-medium text-[var(--danger)]">{failed} 个异常需要关注</span>
      </>
    );
  }
  return <>已接入 {sites.length} 个站点，全部正常</>;
}

export function SiteConfigSection() {
  // ?tab=search 深链直达搜索分类，切换写回地址栏（useTabParam，全设置页同一套）
  const [tab, setTab] = useTabParam<SiteTab>(
    TABS.map((t) => t.id),
    "sites",
  );
  const [catalog, setCatalog] = useState<CatalogItem[]>([]);
  const [configured, setConfigured] = useState<ConfiguredSite[]>([]);
  // 各站点的种子缓存统计（定时同步任务维护），key 为 site_id；从未同步过的站点没有条目
  const [syncStats, setSyncStats] = useState<Record<string, SiteSyncStats>>({});
  // 各站点的刷流运行统计；从未刷流且未开启刷流的站点没有条目
  const [boostStats, setBoostStats] = useState<Record<string, SiteBoostStats>>({});
  // 已接入的下载器：开启刷流时选投递目标、详情里显示刷流下载器名称与可用性
  const [downloaders, setDownloaders] = useState<ConfiguredDownloader[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  // 是否打开「添加站点」抽屉
  const [adding, setAdding] = useState(false);
  // 当前展开详情的站点（单开手风琴）
  const [expandedSite, setExpandedSite] = useState<string | null>(null);

  const catalogMap = useMemo(() => new Map(catalog.map((c) => [c.site_id, c])), [catalog]);

  // 已配置集合，供"添加"面板过滤掉已接入的站点
  const configuredIds = useMemo(
    () => new Set(configured.map((s) => s.site_id)),
    [configured],
  );
  const availableItems = useMemo(
    () => catalog.filter((c) => !configuredIds.has(c.site_id)),
    [catalog, configuredIds],
  );

  const load = useCallback(async () => {
    setError(null);
    try {
      const [cat, cfg, stats, boost, dls] = await Promise.all([
        listSiteCatalog(),
        listConfiguredSites(),
        listSiteSyncStats(),
        listSiteBoostStats(),
        // 下载器列表只服务刷流下载器的选择与展示，拉取失败不拖垮站点页
        listDownloaders().catch(() => [] as ConfiguredDownloader[]),
      ]);
      setCatalog(cat);
      setConfigured(cfg);
      setSyncStats(stats);
      setBoostStats(boost);
      setDownloaders(dls);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  // 有站点处于 pending/verifying 时轮询刷新，直到全部落定（页面隐藏时暂停）
  const hasInProgress = configured.some((s) => IN_PROGRESS.includes(s.status));
  useVisiblePolling(
    () => {
      void listConfiguredSites()
        .then(setConfigured)
        .catch(() => {
          /* 轮询失败静默重试，不打断页面 */
        });
    },
    hasInProgress ? 2500 : null,
  );

  // 有站点开着刷流时轻轮询关键数据（引擎 5 分钟一个 tick、同步最快 5 分钟一轮，
  // 30 秒刷新足够跟上）：刷流统计（行级产出读数、详情用量）与索引同步节奏
  // （详情里的上次/下次同步）在页面停留期间自己长，不需要用户手动刷新。
  // 两个请求都是本地聚合查询，不触达任何站点。
  const anyBoosting = configured.some((s) => s.boost_enabled);
  // 开启刷流时预选的下载器：多数用户只有一台专门刷流的机器，沿用其他站点
  // 已在用的那台，第二个站点起一步确认即可（没有则由弹窗预选默认下载器）
  const boostPeerDownloaderId =
    configured.find((s) => s.boost_enabled && s.boost_downloader_id !== null)
      ?.boost_downloader_id ?? null;
  useVisiblePolling(
    () => {
      void listSiteBoostStats()
        .then(setBoostStats)
        .catch(() => {
          /* 轮询失败静默重试，不打断页面 */
        });
      void listSiteSyncStats()
        .then(setSyncStats)
        .catch(() => {
          /* 同上 */
        });
    },
    anyBoosting ? 30000 : null,
  );

  // 原地替换已有站点、新站点追加到末尾。
  // 注意：菜单里的启停/保护等操作也走这里，保持列表基础顺序稳定，避免被操作的站点跳位。
  const upsertConfigured = useCallback((next: ConfiguredSite) => {
    setConfigured((prev) => {
      const idx = prev.findIndex((s) => s.site_id === next.site_id);
      if (idx === -1) return [...prev, next];
      const copy = [...prev];
      copy[idx] = next;
      return copy;
    });
  }, []);

  // 异常站点置顶（稳定排序：failed 之间与正常站之间保持后端顺序）
  const ordered = useMemo(
    () =>
      [...configured].sort(
        (a, b) => (a.status === "failed" ? 0 : 1) - (b.status === "failed" ? 0 : 1),
      ),
    [configured],
  );

  return (
    <div className="space-y-6">
      {/* 页签在最上方；各页签的主操作放进自己小节的标题行。接入统计在分区副标题，
          这里不再重复；刷新按钮省去（验证轮询 + 操作后回写已覆盖刷新诉求）。 */}
      <SettingsTabs tabs={TABS} value={tab} onChange={setTab} />

      {tab === "search" ? (
        <SearchSection />
      ) : (
        <div className="space-y-10">
          <SettingsSection
            title="已接入站点"
            action={
              <button
                type="button"
                onClick={() => setAdding(true)}
                disabled={loading}
                className={`${SETTINGS_PRIMARY_BUTTON_CLASS} flex items-center gap-1 pl-3`}
              >
                <PlusIcon className="size-4" />
                添加站点
              </button>
            }
          >
            <div className="space-y-3">
              {error && <ErrorBanner>{error}</ErrorBanner>}

              {/* 下载器拥堵提示：有任务在排队说明活动位满了——新种提交受限、
                  刷流已自动暂停投放，引导用户去调大队列上限（一键直达弹窗） */}
              <QueueCongestionTip />

              {/* 「添加站点」抽屉：从目录里挑选未配置的站点 */}
              {adding && (
                <AddSiteDrawer
                  available={availableItems}
                  onCreated={(site) => {
                    upsertConfigured(site);
                    setAdding(false);
                  }}
                  onClose={() => setAdding(false)}
                />
              )}

              {/* 站点列表：行式布局，与设置页行组同款容器 */}
              {loading ? (
                <div className="space-y-px overflow-hidden rounded-xl border border-white/[0.08]">
                  <div className="h-14 animate-pulse bg-white/[0.04]" />
                  <div className="h-14 animate-pulse bg-white/[0.04]" />
                </div>
              ) : configured.length === 0 ? (
                <SettingsEmpty
                  icon={<ServerIcon className="size-5" />}
                  title="还没有配置任何站点"
                  description="点「添加站点」开始接入。"
                />
              ) : (
                <div className="css-glass divide-y divide-[var(--line)] overflow-hidden !rounded-xl">
                  {ordered.map((site) => (
                    <SiteRow
                      key={site.site_id}
                      item={catalogMap.get(site.site_id) ?? fallbackItem(site.site_id)}
                      site={site}
                      stats={syncStats[site.site_id]}
                      boost={boostStats[site.site_id]}
                      downloaders={downloaders}
                      boostPeerDownloaderId={boostPeerDownloaderId}
                      expanded={expandedSite === site.site_id}
                      onToggle={() =>
                        setExpandedSite((cur) => (cur === site.site_id ? null : site.site_id))
                      }
                      onChanged={upsertConfigured}
                      onDeleted={(siteId) => {
                        setConfigured((prev) => prev.filter((s) => s.site_id !== siteId));
                        setExpandedSite((cur) => (cur === siteId ? null : cur));
                      }}
                      onError={setError}
                    />
                  ))}
                </div>
              )}
            </div>
          </SettingsSection>

          {/* 浏览器扩展：站点 Cookie 同步的配套工具 */}
          <ExtensionCard />
        </div>
      )}
    </div>
  );
}

/* —— 添加站点抽屉：先选站点（带搜索），再填授权表单 —— */

interface AddSiteDrawerProps {
  available: CatalogItem[];
  onCreated: (site: ConfiguredSite) => void;
  onClose: () => void;
}

function AddSiteDrawer({ available, onCreated, onClose }: AddSiteDrawerProps) {
  const [query, setQuery] = useState("");
  const [selected, setSelected] = useState<CatalogItem | null>(null);

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return available;
    return available.filter(
      (c) =>
        c.display_name.toLowerCase().includes(q) ||
        c.site_id.toLowerCase().includes(q) ||
        c.base_url.toLowerCase().includes(q),
    );
  }, [available, query]);

  // 已选定站点 → 展示授权表单
  if (selected) {
    return (
      <SiteForm
        title="添加站点"
        item={selected}
        site={null}
        onClose={onClose}
        onSubmit={async (payload) => onCreated(await configureSite(selected.site_id, payload))}
        header={(busy) => (
          <div className="flex items-center justify-between gap-3">
            <div className="min-w-0">
              <p className="truncate text-body font-semibold text-[var(--text)]">
                {selected.display_name}
              </p>
              <p className="truncate text-caption text-[var(--text-faint)]">
                {selected.base_url}
              </p>
            </div>
            <button
              type="button"
              onClick={() => setSelected(null)}
              disabled={busy}
              className={SETTINGS_BUTTON_CLASS}
            >
              重新选择
            </button>
          </div>
        )}
      />
    );
  }

  // 未选定 → 搜索 + 站点列表（提交按钮置灰，选好站点才能填表）
  return (
    <SettingsDrawer
      open
      onClose={onClose}
      title="添加站点"
      actions={
        <>
          <button type="button" onClick={onClose} className={SETTINGS_BUTTON_CLASS}>
            取消
          </button>
          <button type="button" disabled className={SETTINGS_PRIMARY_BUTTON_CLASS}>
            保存并验证
          </button>
        </>
      }
    >
      <input
        value={query}
        onChange={(e) => setQuery(e.target.value)}
        placeholder="搜索站点名称 / 地址"
        autoFocus
        className={`${SETTINGS_INPUT_CLASS} mb-3 w-full`}
      />

      <div className="space-y-1">
        {available.length === 0 ? (
          <p className="px-2 py-6 text-center text-body text-[var(--text-muted)]">
            所有支持的站点都已配置。
          </p>
        ) : filtered.length === 0 ? (
          <p className="px-2 py-6 text-center text-body text-[var(--text-muted)]">
            没有匹配「{query}」的站点。
          </p>
        ) : (
          filtered.map((item) => (
            <button
              key={item.site_id}
              type="button"
              onClick={() => setSelected(item)}
              className="glass-row nav-item w-full items-center justify-between gap-3 px-3 py-2.5 text-left"
            >
              <span className="min-w-0">
                <span className="block truncate text-ui font-medium text-[var(--text)]">
                  {item.display_name}
                </span>
                <span className="block truncate text-caption text-[var(--text-faint)]">
                  {item.base_url}
                </span>
              </span>
              <span className="shrink-0 text-caption text-[var(--text-muted)]">
                {item.supported_auth_types.map((a) => AUTH_TYPE_LABEL[a.auth_type]).join(" / ")}
              </span>
            </button>
          ))
        )}
      </div>
    </SettingsDrawer>
  );
}

/* —— 站点行：一行一站，P0 常驻 + P1 条件徽章；点击展开详情 —— */

interface SiteRowProps {
  item: CatalogItem;
  site: ConfiguredSite;
  stats?: SiteSyncStats;
  boost?: SiteBoostStats;
  downloaders: ConfiguredDownloader[];
  boostPeerDownloaderId: number | null;
  expanded: boolean;
  onToggle: () => void;
  onChanged: (site: ConfiguredSite) => void;
  onDeleted: (siteId: string) => void;
  onError: (message: string) => void;
}

function SiteRow({
  item,
  site,
  stats,
  boost,
  downloaders,
  boostPeerDownloaderId,
  expanded,
  onToggle,
  onChanged,
  onDeleted,
  onError,
}: SiteRowProps) {
  const confirm = useConfirm();
  const toast = useToast();
  const [busy, setBusy] = useState(false);
  // 「编辑授权」抽屉
  const [editingAuth, setEditingAuth] = useState(false);
  // 刷流设置弹窗（预算 + 保留期同窗）：enable=开启前确认，adjust=运行中调整
  const [boostModal, setBoostModal] = useState<"enable" | "adjust" | null>(null);
  const meta = STATUS_META[site.status];
  const failed = site.status === "failed" && !!site.last_error;

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

  /** 在池刷流种子数（关闭刷流 / 删除站点时决定要不要给「同时清理」勾选项） */
  const inPool = boost?.active_count ?? 0;

  /**
   * 关闭刷流。关掉刷流不会删种：残留种子会继续满速做种、引擎也不再汰换，一直占着磁盘——
   * 该站还有在池种子时，确认框带一个「同时清理」勾选项（关的那一刻顺手清掉）；不勾也能事后在
   * 任务中心的刷流分组里清理（docs/design/site-protection-ratio-boost.md §2.9）。
   */
  async function disableBoost() {
    const bullets = [
      "停止抢该站新发布的免费种子",
      "站点索引同步回到正常自适应节奏",
      "重新开启时会再次确认预算与保留期",
    ];
    const title = `关闭「${item.display_name}」的自动刷分享率？`;
    if (inPool === 0) {
      if (!(await confirm({ title, bullets, confirmLabel: "关闭刷流" }))) return;
      await guard(async () => onChanged(await setSiteRatioBoost(site.site_id, false)));
      return;
    }
    const result = await confirm({
      title,
      bullets,
      confirmLabel: "关闭刷流",
      checkbox: boostCleanupCheckbox(inPool, boost?.used_bytes ?? 0),
    });
    if (!result.ok) return;
    await guard(async () => {
      if (result.checked) {
        // 后端先关刷流再删种（保留期内的记下到期时刻，到点自动删）
        const cleanup = await cleanupBoostPool({ siteIds: [site.site_id] });
        onChanged(await getConfiguredSite(site.site_id));
        toast.success(`已关闭刷流。${boostCleanupSummary(cleanup)}`);
      } else {
        onChanged(await setSiteRatioBoost(site.site_id, false));
      }
    });
  }

  /** 删除站点配置：还有在池刷流种子时同样带「同时清理」勾选项；不清理的种子转出管理继续做种 */
  async function removeSite() {
    const title = `删除「${item.display_name}」的配置？`;
    const description = "该站点将不再参与搜索与订阅投递，可随时重新接入。";
    if (inPool === 0) {
      if (!(await confirm({ title, description, confirmLabel: "删除", tone: "danger" }))) return;
      await deleteSite(item.site_id);
      onDeleted(item.site_id);
      return;
    }
    const result = await confirm({
      title,
      description: `${description}不清理的刷流种子会转出管理并继续做种，之后只能在下载器里按 movieclaw-boost 分类手动清理。`,
      confirmLabel: "删除",
      tone: "danger",
      checkbox: boostCleanupCheckbox(inPool, boost?.used_bytes ?? 0),
    });
    if (!result.ok) return;
    // 先清理再删配置：已请求清理（保留期内）的种子留在台账里，由引擎到点删除，不会随删站点被放生
    const cleanup = result.checked ? await cleanupBoostPool({ siteIds: [site.site_id] }) : null;
    await deleteSite(item.site_id);
    onDeleted(item.site_id);
    if (cleanup) toast.success(`已删除站点配置。${boostCleanupSummary(cleanup)}`);
  }

  return (
    <div className={site.enabled ? "" : "opacity-60"}>
      {/* 行主体：整行是展开热区。桌面单行；移动端徽章折到第二行（basis-full） */}
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
        className={`group flex min-h-[52px] cursor-pointer flex-wrap items-center gap-x-3 gap-y-1.5 px-4 py-2.5 transition-colors hover:bg-white/[0.04] focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-inset focus-visible:ring-white/25 sm:px-5 sm:py-3 ${
          expanded ? "bg-white/[0.045]" : ""
        }`}
      >
        {/* P0：徽标 + 名称 + 状态 */}
        <div className="flex min-w-0 flex-1 items-center gap-2.5">
          <SiteBadge item={item} />
          {site.protected && (
            <span
              className="flex shrink-0 items-center"
              title="站点保护中：订阅不会自动从该站拉种（下载量归零），手动搜索和下载不受影响"
              aria-label="站点保护中"
            >
              <ShieldIcon className="size-4 text-[var(--info)]" />
            </span>
          )}
          {item.base_url ? (
            <a
              href={item.base_url}
              target="_blank"
              rel="noreferrer"
              title="在新窗口打开站点"
              onClick={(e) => e.stopPropagation()}
              className="truncate text-ui font-semibold text-[var(--text)] underline decoration-transparent underline-offset-4 transition-colors hover:text-white/80 hover:decoration-white/50"
            >
              {item.display_name}
            </a>
          ) : (
            <span className="truncate text-ui font-semibold text-[var(--text)]">
              {item.display_name}
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
            {meta.label}
          </span>
          {!site.enabled && (
            <span className="shrink-0 rounded-full bg-white/[0.08] px-2 py-0.5 text-caption font-medium text-[var(--text-muted)]">
              已停用
            </span>
          )}
        </div>

        {/* P1：条件徽章（异常时错误原因吃掉徽章位——那一刻没有比它更重要的信息）。
            保护状态不占徽章位——站点名前的护盾图标已承担（更紧凑，移动端友好） */}
        {failed ? (
          <p className="order-3 basis-full truncate text-caption text-[var(--danger)] sm:order-none sm:basis-auto sm:max-w-[45%]">
            {site.last_error}
          </p>
        ) : (
          site.boost_enabled && (
            <div className="order-3 basis-full sm:order-none sm:basis-auto">
              <BoostReadout boost={boost} paused={site.boost_paused} />
            </div>
          )
        )}

        {/* 控制区：展开箭头 + 操作菜单 */}
        <div className="flex shrink-0 items-center gap-0.5">
          <span className="flex size-7 items-center justify-center rounded-full text-[var(--text-faint)] transition-colors group-hover:bg-white/[0.08] group-hover:text-[var(--text-muted)]">
            <ChevronDownIcon
              className={`size-4 transition-transform ${expanded ? "rotate-180" : ""}`}
            />
          </span>
          {/* 拦住冒泡：菜单经 portal 渲染，点菜单项、在按钮上按回车都不该顺带开合整行 */}
          <div onClick={(e) => e.stopPropagation()} onKeyDown={(e) => e.stopPropagation()}>
            <SettingsMoreMenu
              label={`「${item.display_name}」的更多操作`}
              items={[
                {
                  label: site.enabled ? "停用站点" : "启用站点",
                  disabled: busy,
                  onSelect: () =>
                    void guard(async () =>
                      onChanged(await setSiteEnabled(site.site_id, !site.enabled)),
                    ),
                },
                {
                  label: site.protected ? "取消保护" : "开启保护",
                  disabled: busy,
                  onSelect: () =>
                    void guard(async () =>
                      onChanged(await setSiteProtection(site.site_id, !site.protected)),
                    ),
                },
                // 刷流启停都带二次确认（开启含预算设置）——选中后弹的是对话框，菜单自身正常关闭
                {
                  label: site.boost_enabled ? "关闭刷流…" : "开启刷流…",
                  disabled: busy,
                  onSelect: site.boost_enabled
                    ? () => void disableBoost()
                    : () => setBoostModal("enable"),
                },
                // 暂停/恢复：临时给前台流量（看视频等）让出上行——做种限速 +
                // 停止汰换拉新，任务保留，随时无损恢复，故不设二次确认
                ...(site.boost_enabled
                  ? [
                      {
                        label: site.boost_paused ? "恢复刷流" : "暂停刷流",
                        disabled: busy,
                        onSelect: () =>
                          void guard(async () =>
                            onChanged(await setSiteBoostPaused(site.site_id, !site.boost_paused)),
                          ),
                      },
                      {
                        label: "刷流设置…",
                        disabled: busy,
                        onSelect: () => setBoostModal("adjust"),
                      },
                    ]
                  : []),
                { label: "编辑授权", disabled: busy, onSelect: () => setEditingAuth(true) },
                {
                  label: "重新验证",
                  disabled: busy || IN_PROGRESS.includes(site.status),
                  onSelect: () =>
                    void guard(async () => onChanged(await reverifySite(site.site_id))),
                },
                {
                  label: "删除配置",
                  danger: true,
                  disabled: busy,
                  onSelect: () => void guard(removeSite),
                },
              ]}
            />
          </div>
        </div>
      </div>

      {/* 编辑授权抽屉：出于安全后端不回传敏感值，字段一律留空重填 */}
      {editingAuth && (
        <SiteForm
          title={`编辑「${item.display_name}」的授权`}
          item={item}
          site={site}
          onClose={() => setEditingAuth(false)}
          onSubmit={async (payload) => {
            onChanged(await updateSite(item.site_id, payload));
            setEditingAuth(false);
          }}
        />
      )}

      {/* 刷流设置弹窗：开启确认与运行中调整共用（预算 + 保留期同窗） */}
      <BoostSettingsModal
        open={boostModal !== null}
        mode={boostModal ?? "adjust"}
        siteName={item.display_name}
        site={site}
        downloaders={downloaders}
        peerDownloaderId={boostPeerDownloaderId}
        onClose={() => setBoostModal(null)}
        onChanged={onChanged}
      />

      {/* 展开详情：刷流 / 账号 / 索引 / 授权 四段 */}
      {expanded && (
        <SiteDetail
          site={site}
          stats={stats}
          boost={boost}
          downloaders={downloaders}
        />
      )}
    </div>
  );
}

/* —— 展开详情：P2 信息与刷流设置，移动端统计自动折成两列 —— */

interface SiteDetailProps {
  site: ConfiguredSite;
  stats?: SiteSyncStats;
  boost?: SiteBoostStats;
  downloaders: ConfiguredDownloader[];
}

function SiteDetail({ site, stats, boost, downloaders }: SiteDetailProps) {
  const boostDownloader = resolveBoostDownloader(site, downloaders);
  return (
    <div className="divide-y divide-white/[0.05] border-t border-white/[0.06] bg-white/[0.02] px-4 py-3 sm:px-5">
      {/* ─ 刷流 ─ 只读运行统计；启停与预算在 ⋯ 菜单（带二次确认与预算弹窗） */}
      {site.boost_enabled && (
        <DetailSection label="刷流">
          {site.boost_paused && (
            <p className="text-caption leading-5 text-[var(--warn)]">
              已暂停：在池做种压到极低上传限速，停止汰换与拉新种（任务与数据保留）。
              可在 ⋯ 菜单里「恢复刷流」。
            </p>
          )}
          {boostDownloader && !boostDownloader.downloader.usable && (
            <p className="text-caption leading-5 text-[var(--warn)]">
              刷流下载器「{boostDownloader.downloader.name}」当前不可用（已停用或连接失败），
              该站暂停抢新种，下载器恢复后自动继续。
            </p>
          )}
          <StatGrid>
            <DetailStat
              label="已用 / 预算"
              value={`${formatBytes(boost?.used_bytes ?? 0)} / ${formatBytes(site.boost_budget_bytes)}`}
            />
            <DetailStat label="在池做种" value={String(boost?.active_count ?? 0)} />
            <DetailStat
              label="累计上传"
              value={formatBytes(boost?.uploaded_bytes_total ?? 0)}
            />
            <DetailStat
              label="汰换保留期"
              value={site.boost_hold_days > 0 ? `${site.boost_hold_days} 天` : "不保护"}
            />
            {/* 只接了一台下载器时不出现「刷流下载器」这个概念 */}
            {boostDownloader && (downloaders.length > 1 || site.boost_downloader_id !== null) && (
              <DetailStat
                label="刷流下载器"
                value={
                  boostDownloader.followsDefault
                    ? `${boostDownloader.downloader.name}（默认）`
                    : boostDownloader.downloader.name
                }
              />
            )}
            {boost && boost.evicted_count > 0 && (
              <DetailStat label="已汰换" value={String(boost.evicted_count)} />
            )}
          </StatGrid>
          {boost && boost.avg_used_bytes_24h > 0 && (
            <p className="text-caption leading-5 text-[var(--text-muted)]">
              近 24 小时：{formatBytes(boost.avg_used_bytes_24h)} 在池种子贡献了{" "}
              {formatBytes(boost.uploaded_bytes_24h)} 上传
              {boost.avg_used_bytes_7d > 0 &&
                ` · 近 7 天：${formatBytes(boost.avg_used_bytes_7d)} 贡献 ${formatBytes(boost.uploaded_bytes_7d)}`}
            </p>
          )}
        </DetailSection>
      )}

      {/* ─ 账号 ─ 两行分组：身份与持有（用户名/等级/做种/魔力）、流量指标（上传/下载/分享率） */}
      {site.profile && (
        <DetailSection label="账号">
          <div
            className="space-y-2.5"
            title={`资料更新于 ${formatRelativeTime(site.profile.fetched_at)}`}
          >
            <StatGrid>
              <DetailStat label="用户名" value={site.profile.username} />
              {site.profile.user_class && (
                <DetailStat label="等级" value={site.profile.user_class} />
              )}
              <DetailStat label="做种" value={String(site.profile.seeding_count)} />
              {site.profile.bonus != null && (
                <DetailStat label="魔力" value={formatCompact(site.profile.bonus)} />
              )}
            </StatGrid>
            <StatGrid>
              <DetailStat label="上传量" value={formatBytes(site.profile.uploaded_bytes)} />
              <DetailStat label="下载量" value={formatBytes(site.profile.downloaded_bytes)} />
              <DetailStat label="分享率" value={formatRatio(site.profile.ratio)} />
            </StatGrid>
          </div>
        </DetailSection>
      )}

      {/* ─ 索引 ─ */}
      {stats && (
        <DetailSection label="索引">
          <StatGrid>
            <DetailStat
              label="已缓存种子"
              value={stats.torrent_count.toLocaleString("zh-CN")}
            />
            <DetailStat label="上次同步" value={formatRelativeTime(stats.last_sync_at)} />
            <DetailStat label="下次同步" value={nextSyncLabel(stats.next_sync_at)} />
            {stats.sync_interval_seconds != null && (
              <DetailStat label="同步间隔" value={formatDuration(stats.sync_interval_seconds)} />
            )}
          </StatGrid>
          {stats.last_error && (
            <p className="text-caption leading-5 text-[var(--danger)]">上次同步失败：{stats.last_error}</p>
          )}
        </DetailSection>
      )}

      {/* ─ 授权 ─ 只读展示；编辑入口在 ⋯ 菜单（编辑授权，打开抽屉） */}
      <DetailSection label="授权">
        <p className="text-sub leading-6 text-[var(--text-muted)]">
          {AUTH_TYPE_LABEL[site.auth_type]} · 上次检查 {formatRelativeTime(site.last_checked_at)}
        </p>
      </DetailSection>
    </div>
  );
}

/* —— 刷流设置弹窗：预算 + 汰换保留期同窗设置，开启确认与运行中调整共用 —— */

function BoostSettingsModal({
  open,
  mode,
  siteName,
  site,
  downloaders,
  peerDownloaderId,
  onClose,
  onChanged,
}: {
  open: boolean;
  /** enable=开启前的二次确认（讲清将发生什么），adjust=运行中调整 */
  mode: "enable" | "adjust";
  siteName: string;
  site: ConfiguredSite;
  /** 已接入的下载器；多于一台时弹窗里出现「刷流下载器」选择 */
  downloaders: ConfiguredDownloader[];
  /** 其他站点已在用的刷流下载器，开启时优先预选 */
  peerDownloaderId: number | null;
  onClose: () => void;
  onChanged: (site: ConfiguredSite) => void;
}) {
  const confirm = useConfirm();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [budgetGib, setBudgetGib] = useState("");
  const [holdDays, setHoldDays] = useState("");
  const [downloaderId, setDownloaderId] = useState<number | null>(null);
  // 只有一台下载器时没有可选的，不出现这个概念（刷流跟随默认下载器）
  const pickDownloader = downloaders.length > 1;
  // 每次打开按当前生效值重置表单（上次输入不残留）。下载器预选顺序：该站已选的 →
  // 其他站点在用的 → 默认下载器；预选值须仍在列表里且未停用
  useEffect(() => {
    if (!open) return;
    setError(null);
    setBudgetGib(String(Math.round(site.boost_budget_bytes / GIB)));
    setHoldDays(String(site.boost_hold_days));
    const selectable = (id: number | null) =>
      id !== null && downloaders.some((d) => d.id === id && d.enabled);
    const preset = [
      site.boost_downloader_id,
      peerDownloaderId,
      downloaders.find((d) => d.is_default)?.id ?? null,
    ].find(selectable);
    setDownloaderId(preset ?? null);
  }, [
    open,
    site.boost_budget_bytes,
    site.boost_hold_days,
    site.boost_downloader_id,
    peerDownloaderId,
    downloaders,
  ]);

  async function save() {
    const gib = Math.round(Number(budgetGib.trim()));
    if (!Number.isFinite(gib) || gib < 1) {
      setError("刷流预算必须是不小于 1 的整数（单位 GiB）");
      return;
    }
    const days = Math.round(Number(holdDays.trim()));
    if (!Number.isFinite(days) || days < 0 || days > 30) {
      setError("汰换保留期须是 0～30 之间的整数（天）");
      return;
    }
    // 调小预算的后果不可逆（超出部分连数据删除），保存前二次确认讲清楚
    const currentGib = Math.round(site.boost_budget_bytes / GIB);
    if (mode === "adjust" && gib < currentGib) {
      const ok = await confirm({
        title: `将「${siteName}」的刷流预算从 ${currentGib} GiB 调小到 ${gib} GiB？`,
        bullets: [
          "在池占用超出新预算的部分将被汰换：连同已下载的数据一起删除，且同一种子不会再抢回",
          "按上传效率从低到高删——死种和低效的先走，高效种子最后才会被动",
          "汰换保留期内的任务不受影响，到期后才继续收敛",
          "收敛期间暂停接新的免费种",
        ],
        confirmLabel: "确认调小",
        tone: "danger",
      });
      if (!ok) return;
    }
    setBusy(true);
    setError(null);
    try {
      onChanged(
        await setSiteRatioBoost(
          site.site_id,
          true,
          gib * GIB,
          days,
          pickDownloader ? (downloaderId ?? undefined) : undefined,
        ),
      );
      onClose();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal
      open={open}
      onClose={onClose}
      label={mode === "enable" ? "开启自动刷分享率" : "刷流设置"}
      width="lg"
      topmost
    >
      <div className="space-y-4 p-6">
        <div>
          <h2 className="text-title font-bold text-[var(--text)]">
            {mode === "enable" ? `开启「${siteName}」的自动刷分享率？` : `刷流设置 · ${siteName}`}
          </h2>
          <p className="mt-1 text-sub leading-6 text-[var(--text-muted)]">
            {mode === "enable"
              ? "开启后将自动抢该站新发布的免费种子做种以提升分享率，占用空间在预算内自动汰换" +
                "（下载完成、入池满保留期且上传效率过低的任务才会被连数据删除），" +
                "该站的索引同步会提速到约 5 分钟一次。"
              : "调小预算会按上传效率从低到高汰换在池任务（连数据删除），直到占用回到新预算内；" +
                "保留期内的任务绝不会被提前删除。"}
          </p>
        </div>

        {error && (
          <ErrorBanner>{error}</ErrorBanner>
        )}

        <div className="grid grid-cols-2 gap-3 max-md:grid-cols-1">
          <BoostField
            label="存储预算"
            value={budgetGib}
            unit="GiB"
            min={1}
            disabled={busy}
            onChange={setBudgetGib}
            hint="刷流任务占用磁盘的上限，预算内自动汰换"
          />
          <BoostField
            label="汰换保留期"
            value={holdDays}
            unit="天"
            min={0}
            disabled={busy}
            onChange={setHoldDays}
            hint="H&R 安全垫：有考核的站不小于考核时长；无考核可调 0 自由汰换"
          />
        </div>

        {pickDownloader && (
          <BoostDownloaderPicker
            value={downloaderId}
            options={downloaders}
            disabled={busy}
            onChange={setDownloaderId}
            hint={
              mode === "adjust" &&
              downloaderId !==
                (site.boost_downloader_id ?? downloaders.find((d) => d.is_default)?.id ?? null)
                ? "改选只影响之后新抢的种子；已在做种的任务留在原下载器，直到汰换"
                : "刷流种子投给这台；可与订阅用的默认下载器分开，免得互相挤占队列"
            }
          />
        )}

        <div className="flex justify-end gap-2 pt-1">
          <button type="button" onClick={onClose} disabled={busy} className={SETTINGS_BUTTON_CLASS}>
            取消
          </button>
          <button
            type="button"
            onClick={() => void save()}
            disabled={busy}
            className={SETTINGS_PRIMARY_BUTTON_CLASS}
          >
            {busy ? "保存中…" : mode === "enable" ? "开启刷流" : "保存"}
          </button>
        </div>
      </div>
    </Modal>
  );
}

/** 刷流下载器菜单项样式（与 library-filter-bar 的排序 RadioItem 同款） */
const PICKER_ITEM_CLASS =
  "glass-row nav-item flex cursor-pointer items-center justify-between gap-3 px-3 py-2 " +
  "text-sub outline-none data-[highlighted]:!bg-[var(--glass-fill-hover)] " +
  "data-[highlighted]:!text-[var(--text)] data-[disabled]:cursor-default data-[disabled]:opacity-45";

/**
 * 刷流下载器选择（刷流设置弹窗内）。用 Radix DropdownMenu 而不是原生 select：
 * 原生下拉由系统绘制，跟不了液态玻璃这套皮。停用的下载器列出但不可选；
 * 连接失败的仍可选（可能只是临时掉线），选后站点详情会提示暂停准入。
 */
function BoostDownloaderPicker({
  value,
  options,
  disabled,
  onChange,
  hint,
}: {
  value: number | null;
  options: ConfiguredDownloader[];
  disabled: boolean;
  onChange: (id: number) => void;
  hint: string;
}) {
  const current = options.find((d) => d.id === value);
  return (
    <div>
      <label className="mb-1.5 block text-caption font-medium text-[var(--text-muted)]">
        刷流下载器
      </label>
      <DropdownMenu.Root>
        <DropdownMenu.Trigger asChild>
          <button
            type="button"
            disabled={disabled}
            className="flex w-full items-center justify-between gap-2 rounded-lg border border-white/10 bg-white/[0.06] px-3 py-2 text-left text-ui outline-none transition hover:bg-white/[0.09] focus-visible:border-white/25 disabled:opacity-60 data-[state=open]:border-white/25"
          >
            <span className={`truncate ${current ? "text-white" : "text-[var(--text-faint)]"}`}>
              {current ? current.name : "选择下载器"}
              {current?.is_default && (
                <span className="ml-1.5 text-caption text-[var(--text-faint)]">默认</span>
              )}
            </span>
            <ChevronDownIcon className="size-3.5 shrink-0 text-[var(--text-faint)]" />
          </button>
        </DropdownMenu.Trigger>
        <DropdownMenu.Portal>
          {/* z-[100]：刷流设置弹窗是 topmost（z-90），菜单 portal 到 body 须压过它 */}
          <DropdownMenu.Content
            align="start"
            sideOffset={6}
            collisionPadding={12}
            className="menu-surface z-[100] min-w-[var(--radix-dropdown-menu-trigger-width)] p-1"
          >
            <DropdownMenu.RadioGroup
              value={value === null ? "" : String(value)}
              onValueChange={(next) => onChange(Number(next))}
            >
              {options.map((d) => (
                <DropdownMenu.RadioItem
                  key={d.id}
                  value={String(d.id)}
                  disabled={!d.enabled}
                  className={PICKER_ITEM_CLASS}
                >
                  <span className="min-w-0 truncate">
                    {d.name}
                    <span className="ml-1.5 text-caption text-[var(--text-faint)]">
                      {[
                        d.is_default && "默认",
                        !d.enabled ? "已停用" : !d.usable && "连接异常",
                      ]
                        .filter(Boolean)
                        .join(" · ")}
                    </span>
                  </span>
                  <DropdownMenu.ItemIndicator>
                    <CheckIcon className="size-3.5 text-[var(--info)]" />
                  </DropdownMenu.ItemIndicator>
                </DropdownMenu.RadioItem>
              ))}
            </DropdownMenu.RadioGroup>
          </DropdownMenu.Content>
        </DropdownMenu.Portal>
      </DropdownMenu.Root>
      <p className="mt-1 text-caption leading-4 text-[var(--text-faint)]">{hint}</p>
    </div>
  );
}

/** 带单位后缀与说明的数字输入（弹窗内两枚字段共用）。 */
function BoostField({
  label,
  value,
  unit,
  min,
  disabled,
  onChange,
  hint,
}: {
  label: string;
  value: string;
  unit: string;
  min: number;
  disabled?: boolean;
  onChange: (value: string) => void;
  hint: string;
}) {
  return (
    <div>
      <label className="mb-1.5 block text-caption font-medium text-[var(--text-muted)]">
        {label}
      </label>
      <div className="relative">
        <input
          type="number"
          min={min}
          value={value}
          disabled={disabled}
          onChange={(e) => onChange(e.target.value)}
          className={`${SETTINGS_INPUT_CLASS} w-full pr-12 [appearance:textfield] [&::-webkit-inner-spin-button]:appearance-none [&::-webkit-outer-spin-button]:appearance-none`}
        />
        <span className="pointer-events-none absolute inset-y-0 right-3 flex items-center text-caption font-medium text-[var(--text-faint)]">
          {unit}
        </span>
      </div>
      <p className="mt-1 text-caption leading-4 text-[var(--text-faint)]">{hint}</p>
    </div>
  );
}

/* —— 下载器拥堵提示条：任务排队 = 活动位满 = 新种提交受限 ——
   数据来自全站共享的下载任务快照（10 秒可见轮询），零额外请求。点击
   直达下载器分区并自动打开对应的「限速与队列」弹窗（?limits=<id>）。
   用 --warn 色：要注意但系统在自己处理（刷流已自动暂停投放）。 */

function QueueCongestionTip() {
  const { tasks } = useDownloadTasks();
  const queued = useMemo(() => tasks.filter((t) => t.state === "queued"), [tasks]);
  if (queued.length === 0) return null;
  // 拥堵的下载器（取排队任务最多的那台作为跳转目标）
  const counts = new Map<number, { name: string; count: number }>();
  for (const task of queued) {
    if (task.downloader_id == null) continue;
    const entry = counts.get(task.downloader_id) ?? {
      name: task.downloader_name ?? `#${task.downloader_id}`,
      count: 0,
    };
    entry.count += 1;
    counts.set(task.downloader_id, entry);
  }
  const worst = [...counts.entries()].sort((a, b) => b[1].count - a[1].count)[0];
  if (!worst) return null;
  const [downloaderId, { name }] = worst;

  return (
    <Banner
      tone="warn"
      action={
        <Link
          href={`/settings/downloaders?limits=${downloaderId}` as Route}
          className={`${SETTINGS_BUTTON_CLASS} inline-flex items-center`}
        >
          去调整
        </Link>
      }
    >
      下载器「{name}」有 {queued.length} 个任务在排队——活动任务位已满，新种子提交受限，
      刷流已自动暂停投放。建议调大「最大活动种子数」等队列上限。
    </Banner>
  );
}

/* —— 刷流行级读数：只回答「刷流在产出吗」——近 24h 上传量一个数字 ——
   预算用量不上行：池子的稳态就是被填满后汰换周转，「有多满」既非好消息也
   非坏消息，没有行级信号价值（详情展开区仍有完整的已用/预算）。刚开启还
   没有产出数据时退回显示已用量，让用户看到引擎确实在动。数字穿文本色，
   「刷流」小字标签用 accent 特性色标识身份，不与状态徽章的绿色混淆。 */

function BoostReadout({ boost, paused }: { boost?: SiteBoostStats; paused?: boolean }) {
  const up24 = boost?.uploaded_bytes_24h ?? 0;
  const used = boost?.used_bytes ?? 0;
  // 暂停态吃掉产出读数：那一刻「为什么没产出」比「产出多少」更重要
  if (paused) {
    return (
      <div
        className="flex min-w-0 items-center gap-1.5"
        title="刷流已暂停：做种压到极低上传限速、停止汰换与拉新种，任务与数据保留；在 ⋯ 菜单里可随时恢复"
      >
        <span className="shrink-0 text-caption font-medium text-[var(--accent)]">刷流</span>
        <span className="truncate text-caption font-medium text-[var(--warn)]">
          已暂停 · 做种限速让出上行
        </span>
      </div>
    );
  }
  return (
    <div
      className="flex min-w-0 items-center gap-1.5"
      title="自动刷分享率运行中：近 24 小时的上传贡献（完整统计见展开详情）"
    >
      <span className="shrink-0 text-caption font-medium text-[var(--accent)]">刷流</span>
      <span className="truncate text-caption text-[var(--text-muted)]">
        {up24 > 0
          ? `24h ↑${formatBytes(up24)}`
          : used > 0
            ? `已用 ${formatBytes(used)}`
            : "等待首个免费种"}
      </span>
    </div>
  );
}

/* —— 站点徽标：优先取站点真实 favicon（域名 + /favicon.ico），失败回落首字母 ——
   经后端 /images/proxy 统一图片代理回源（cachedImageUrl 收口）：favicon 也是
   站点流量，必须走 movieclaw_net 统一出口受代理路由与网络策略管控，且服务端
   落盘缓存后浏览器不再反复触达站点。刻意不走 Google/DuckDuckGo 的 favicon
   聚合服务：目标用户网络环境里那些域名普遍不可达。 */

/** favicon 失败负缓存的 TTL：站点 favicon 挂了不该每次进页面都重试一发。
 *  成功端有浏览器一年 immutable 缓存，失败端靠 localStorage 记一天，
 *  一天后自动重试（站点修好后最多一天恢复图标）。 */
const _FAVICON_FAIL_TTL_MS = 24 * 60 * 60 * 1000;

function faviconFailKey(origin: string): string {
  return `mc:favicon-fail:${origin}`;
}

function faviconRecentlyFailed(origin: string): boolean {
  try {
    const at = Number(localStorage.getItem(faviconFailKey(origin)));
    return Number.isFinite(at) && Date.now() - at < _FAVICON_FAIL_TTL_MS;
  } catch {
    return false; // 隐私模式等 localStorage 不可用：退化为每次尝试
  }
}

function rememberFaviconFailure(origin: string): void {
  try {
    localStorage.setItem(faviconFailKey(origin), String(Date.now()));
  } catch {
    /* 记不住就算了，只损失负缓存 */
  }
}

function SiteBadge({ item }: { item: CatalogItem }) {
  const origin = useMemo(() => {
    if (!item.base_url) return null;
    try {
      return new URL(item.base_url).origin;
    } catch {
      return null;
    }
  }, [item.base_url]);
  // 初始态就吃负缓存：一天内失败过的站直接出字母徽标，连请求都不发
  const [failed, setFailed] = useState(() => (origin ? faviconRecentlyFailed(origin) : false));

  if (!origin || failed) {
    return (
      <span className="icon-chip size-8 shrink-0 !rounded-lg text-sub font-semibold">
        {item.display_name.charAt(0).toUpperCase()}
      </span>
    );
  }
  return (
    <span className="flex size-8 shrink-0 items-center justify-center overflow-hidden rounded-lg border border-white/[0.08] bg-white/[0.04]">
      {/* 经统一图片代理的外站 favicon，不经 next/image 优化管道 */}
      <img
        // 20 CSS px 的小图标也带宽度（落在最小档）：个别站点的 .ico 里塞着 256px 大图
        src={cachedImageUrl(`${origin}/favicon.ico`, { width: 40 })}
        alt=""
        loading="lazy"
        className="size-5"
        onError={() => {
          rememberFaviconFailure(origin);
          setFailed(true);
        }}
      />
    </span>
  );
}

/**
 * 详情分段：桌面把段标签抽成左侧固定列（内容区左缘因此对齐，
 * 各段的统计格子在纵向也成列），窄屏回落成「标签在上、内容在下」。
 */
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

/**
 * 统计区容器：等宽列（2 → 3 → 4 列）。
 * 刻意不给底色和描边——层级全靠列对齐与字重/明暗分层撑住，
 * 配置页要的是克制，加一圈卡片底色反而把「轻」丢了。
 */
function StatGrid({ children }: { children: React.ReactNode }) {
  return (
    <div className="grid grid-cols-2 gap-x-5 gap-y-3 sm:grid-cols-3 lg:grid-cols-4">
      {children}
    </div>
  );
}

/** 单个统计：淡色小标签在上、数值在下；数值走等宽数字，纵向列里数位对齐 */
function DetailStat({ label, value }: { label: string; value: string }) {
  return (
    <div className="min-w-0">
      <p className="truncate text-micro text-[var(--text-faint)]">{label}</p>
      {/* 移动端降一档字号：窄屏两列下「998 GB / 1000 GB」这类长值按 text-ui 会被截断 */}
      <p className="mt-0.5 truncate text-ui font-semibold tabular-nums text-[var(--text)] max-sm:text-sub">
        {value}
      </p>
    </div>
  );
}

/**
 * 该站刷流实际投给哪台下载器：选定了就是那台，未选定（null）跟随默认下载器——
 * 与后端 ratio_boost._boost_downloader 同一判据。列表里找不到时返回 null。
 */
function resolveBoostDownloader(
  site: ConfiguredSite,
  downloaders: ConfiguredDownloader[],
): { downloader: ConfiguredDownloader; followsDefault: boolean } | null {
  const followsDefault = site.boost_downloader_id === null;
  const downloader = followsDefault
    ? downloaders.find((d) => d.is_default)
    : downloaders.find((d) => d.id === site.boost_downloader_id);
  return downloader ? { downloader, followsDefault } : null;
}

/** 「下次同步」文案：null（立即到期）或时刻已过（等待 tick 扫描）都显示「即将开始」，
 *  避免出现"下次同步：3 分钟前"这种矛盾表述。 */
function nextSyncLabel(iso: string | null): string {
  if (!iso || new Date(iso).getTime() <= Date.now()) return "即将开始";
  return formatRelativeTime(iso);
}

/* —— 授权表单抽屉：根据所选授权类型渲染必填字段，添加站点与编辑授权共用 —— */

interface SiteFormProps {
  title: string;
  item: CatalogItem;
  site: ConfiguredSite | null;
  /** 表单上方的附加内容（添加时的「已选站点 + 重新选择」），参数为提交中 */
  header?: (busy: boolean) => ReactNode;
  onSubmit: (payload: SiteConfigPayload) => Promise<void>;
  onClose: () => void;
}

function SiteForm({ title, item, site, header, onSubmit, onClose }: SiteFormProps) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const options = item.supported_auth_types;
  // 默认选中：已配置的沿用其类型，否则取第一个支持项
  const [authType, setAuthType] = useState<SiteAuthType>(
    site?.auth_type ?? options[0]?.auth_type ?? "cookie",
  );
  // 各字段值。编辑时出于安全后端不回传敏感值，故一律留空，需用户重新填写。
  const [values, setValues] = useState<Record<string, string>>({});

  const current = options.find((o) => o.auth_type === authType) ?? options[0];
  const fields = current?.required_fields ?? [];

  const canSubmit = fields.length > 0 && fields.every((f) => values[f]?.trim());

  function submit() {
    const payload: SiteConfigPayload = { auth_type: authType, enabled: site?.enabled ?? true };
    for (const f of fields) {
      (payload as unknown as Record<string, unknown>)[f] = values[f]?.trim() ?? "";
    }
    setBusy(true);
    setError(null);
    void onSubmit(payload)
      .catch((e) => setError((e as Error).message))
      .finally(() => setBusy(false));
  }

  return (
    <SettingsDrawer
      open
      onClose={onClose}
      title={title}
      actions={
        <>
          <button type="button" onClick={onClose} className={SETTINGS_BUTTON_CLASS}>
            取消
          </button>
          <button
            type="button"
            onClick={submit}
            disabled={busy || !canSubmit}
            className={SETTINGS_PRIMARY_BUTTON_CLASS}
          >
            {busy ? "保存中…" : site ? "保存并重新验证" : "保存并验证"}
          </button>
        </>
      }
    >
      <div className="space-y-4">
        {error && <ErrorBanner>{error}</ErrorBanner>}
        {header?.(busy)}

        {/* 授权类型选择（多于一种时才展示） */}
        {options.length > 1 && (
          <div>
            <label className="mb-1.5 block text-sub font-medium text-[var(--text-muted)]">
              授权方式
            </label>
            <div className="flex flex-wrap gap-2">
              {options.map((opt: AuthTypeRequirement) => (
                <button
                  key={opt.auth_type}
                  type="button"
                  onClick={() => setAuthType(opt.auth_type)}
                  data-active={authType === opt.auth_type}
                  className="glass-row nav-item !w-auto px-3 py-1.5 text-sub font-medium"
                >
                  {AUTH_TYPE_LABEL[opt.auth_type]}
                </button>
              ))}
            </div>
          </div>
        )}

        {/* 必填字段 */}
        {fields.map((field) => {
          const fm = FIELD_META[field] ?? { label: field, kind: "text" as const };
          return (
            <div key={field}>
              <label className="mb-1.5 block text-sub font-medium text-[var(--text-muted)]">
                {fm.label}
              </label>
              {/* Cookie 恰是扩展的用武之地：就地提一句，不打断手动粘贴的用户 */}
              {field === "cookie" && (
                <p className="mb-1.5 text-caption text-[var(--text-faint)]">
                  手动粘贴的 Cookie 过期后需重填；推荐用本页下方的 MovieClaw 浏览器扩展自动同步。
                </p>
              )}
              {fm.kind === "textarea" ? (
                <textarea
                  value={values[field] ?? ""}
                  onChange={(e) => setValues((v) => ({ ...v, [field]: e.target.value }))}
                  rows={3}
                  autoComplete="off"
                  placeholder={site ? "出于安全，请重新填写" : ""}
                  className={`${SETTINGS_INPUT_CLASS} scroll-thin w-full resize-none`}
                />
              ) : (
                <input
                  type={fm.kind}
                  value={values[field] ?? ""}
                  onChange={(e) => setValues((v) => ({ ...v, [field]: e.target.value }))}
                  placeholder={site ? "出于安全，请重新填写" : ""}
                  // Chrome 对 password 字段会无视 "off" 仍弹出已存密码，须用 "new-password" 抑制
                  autoComplete={fm.kind === "password" ? "new-password" : "off"}
                  className={`${SETTINGS_INPUT_CLASS} w-full`}
                />
              )}
            </div>
          );
        })}
      </div>
    </SettingsDrawer>
  );
}
