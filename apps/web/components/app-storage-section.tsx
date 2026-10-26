"use client";

import { useLocale, useTranslations } from "next-intl";
import { type AppLocale } from "@/lib/i18n/negotiate";
import { useMessageState } from "@/lib/i18n/use-message-state";

import { useCallback, useEffect, useRef, useState } from "react";

import { Banner } from "@/components/cloud-push-ui";
import { useConfirm, useToast } from "@/components/feedback";
import { InfoIcon, RefreshIcon } from "@/components/icons";
import {
  SETTINGS_BUTTON_CLASS,
  SettingsList,
  SettingsMoreMenu,
  SettingsRow,
  SettingsSection,
} from "@/components/settings-ui";
import { Tooltip } from "@/components/tooltip";
import {
  cleanStorage,
  getStorageState,
  type CleanMode,
  type DirUsage,
  type StorageUsage,
} from "@/lib/api/storage";
import { formatBytes } from "@/lib/format";
import { formatRelativeTime } from "@/lib/time";

/**
 * 缓存管理（设置 → 更新与维护，「缓存管理」标签）。
 *
 * 这一页是后端登记表（services/storage/registry.py）的视图：每个 data/ 下的目录
 * 由后端给出名称、一句话用途、完整说明、占用、能否清理，前端只负责分组渲染与
 * 确认交互——业务新增一种缓存不需要改这里。
 *
 * 打开页面**不会**触发一次实时统计：遍历整个 data/ 在大库上要几十秒，所以后端
 * 给的是「上一次的快照 + 是否正在重算」，页面秒开并标出「统计于 N 分钟前」。
 * 要最新数字就点刷新：按钮转成「统计中」，旧数据继续留在页面上，后台算完
 * （轮询到 computing 变假）再整体替换，不会中途闪成空白或加载态。
 *
 * 清理的二次确认走全站统一的 useConfirm 弹窗（feedback.tsx），不用行内确认条：
 * 确认条会把下面的行整体推走，而且 ⋯ 菜单在列表靠下时它常常落在视口外——手机上
 * 尤其明显；弹窗还自带焦点陷阱、Esc 与点击外部关闭。
 *
 * 版式（手机优先）：一行三段「名称 + 一句话用途 | 占用 | ⋯」。清理动作全部收进
 * 行尾的 ⋯ 菜单——两个并排的文字按钮在 390px 宽的屏幕上会把名称挤成「图…」，
 * 而清理是低频动作，不值得常驻这么宽的位置；占用数字定宽右对齐，是每行的视觉
 * 锚点。「重建代价高」徽章挪到第二行与一句话用途同列，保证第一行永远是完整的
 * 目录名；完整说明与真实路径收进名称旁的信息图标（触屏点按也能展开）。三块内容：
 *   1. 磁盘概览：data/ 所在磁盘的分段条（应用数据 / 可回收缓存 / 其他 / 剩余）；
 *   2. 可清理的缓存：「清理孤儿条目」（媒体库里已不存在的条目，无损）与「全部清空」
 *      （重建代价高的目录在确认弹窗里标红警示）；
 *   3. 应用数据：只展示占用（用户资产或回退恢复源）。
 *   「未登记目录」块只在后端发现登记表之外的条目时出现。
 */

/** 后台统计期间的轮询间隔 */
const POLL_MS = 2000;

export function AppStorageSection() {
  const t = useTranslations();
  const locale = useLocale() as AppLocale;

  const [usage, setUsage] = useState<StorageUsage | null>(null);
  const [computing, setComputing] = useState(false);
  const [error, setError] = useMessageState();
  const [busyKey, setBusyKey] = useState<string | null>(null);
  const confirm = useConfirm();
  const toast = useToast();

  /** 读一次状态：拿到新快照才替换页面数据，没算完就只更新「统计中」标记。 */
  const readGeneration = useRef(0);
  const load = useCallback(async (refresh: boolean) => {
    const id = ++readGeneration.current;
    try {
      const state = await getStorageState(refresh);
      if (id !== readGeneration.current) return;
      if (state.usage) setUsage(state.usage);
      setComputing(state.computing);
      setError(state.error);
    } catch (e) {
      if (id !== readGeneration.current) return;
      setComputing(false);
      setError(e instanceof Error ? e.message : { key: "settings.storage.ui.readFailed" });
    }
  }, [setError]);

  useEffect(() => {
    void load(false);
    return () => { readGeneration.current += 1; };
  }, [load, locale]);

  // 后台正在统计时轮询，等新数据落地后自动替换页面上的旧数据
  useEffect(() => {
    if (!computing) return;
    const timer = setInterval(() => void load(false), POLL_MS);
    return () => clearInterval(timer);
  }, [computing, load]);

  /** 先弹确认，用户点了确认才真的清理。文案按模式与重建代价分档。 */
  const askClean = async (dir: DirUsage, mode: CleanMode) => {
    const expensive = dir.rebuild_cost === "expensive";
    const ok = await confirm(
      mode === "orphans"
        ? {
            title: t("settings.storage.ui.orphansTitle", { title: dir.title }),
            description: t("settings.storage.ui.orphansHint"),
            confirmLabel: t("settings.storage.ui.orphans"),
          }
        : {
            title: t("settings.storage.ui.clearTitle", { title: dir.title }),
            // 登记表的完整说明本身就写清了用途与重建代价，直接当后果说明；
            // 重建代价高的那几个另外靠红色确认键（tone: danger）加重提醒
            description: dir.description,
            confirmLabel:
              dir.bytes > 0 ? t("settings.storage.ui.clearBytes", { bytes: formatBytes(dir.bytes) }) : t("settings.storage.ui.clear"),
            tone: expensive ? "danger" : "default",
          },
    );
    if (ok) await doClean(dir.key, mode);
  };

  const doClean = async (key: string, mode: CleanMode) => {
    setBusyKey(key);
    try {
      const result = await cleanStorage(key, mode);
      toast.success(t("settings.storage.ui.cleaned", {
        bytes: formatBytes(result.freed_bytes), removed: result.removed, skipped: result.skipped_busy,
      }));
      // 清理让后端快照标脏：这一次读取会拉起后台重算，占用数字随后被轮询替换
      await load(false);
    } catch (e) {
      toast.error(e instanceof Error ? e.message : t("settings.storage.ui.cleanFailed"));
    } finally {
      setBusyKey(null);
    }
  };

  const cacheDirs = usage?.dirs.filter((d) => d.group === "cache") ?? [];
  const dataDirs = usage?.dirs.filter((d) => d.group === "data") ?? [];

  // 数据是「上一次统计的结果」，因此时间与进行中状态必须始终摆在标题栏上；
  // 手机上这一行还要和刷新按钮挤在一起，文案保持短，超长时截断而不是挤走按钮。
  const computedAt = usage
    ? formatRelativeTime(new Date(usage.computed_at * 1000).toISOString(), locale)
    : null;
  const statusText = computedAt
    ? t("settings.storage.ui.computedAt", { when: computedAt, updating: computing ? "yes" : "no" })
    : computing
      ? t("settings.storage.ui.firstComputing")
      : t("settings.storage.ui.notComputed");

  return (
    <div className="space-y-10">
      <SettingsSection
        title={t("settings.storage.ui.overview")}
        description={statusText}
        action={
          <button
            type="button"
            onClick={() => void load(true)}
            disabled={computing}
            className={SETTINGS_BUTTON_CLASS}
          >
            <RefreshIcon className={`size-3.5 ${computing ? "animate-spin" : ""}`} />
            {computing ? t("settings.storage.ui.computing") : t("settings.storage.ui.refresh")}
          </button>
        }
      >
        <DiskOverview usage={usage} error={error} />
      </SettingsSection>

      {usage && usage.unregistered.length > 0 && (
        <SettingsSection title={t("settings.storage.ui.unregistered")}>
          <Banner tone="warn">
            {t("settings.storage.ui.unregisteredHint")}<ul className="mt-2 space-y-1">
              {usage.unregistered.map((u) => (
                <li key={u.path} className="flex items-center justify-between gap-4">
                  <span className="truncate font-mono" title={u.path}>
                    {relativeTo(u.path, usage.data_root)}
                  </span>
                  <span className="tnum shrink-0">{formatBytes(u.bytes)}</span>
                </li>
              ))}
            </ul>
          </Banner>
        </SettingsSection>
      )}

      <SettingsSection
        title={t("settings.storage.ui.caches")}
        description={usage ? t("settings.storage.ui.total", { bytes: formatBytes(usage.cache_bytes) }) : undefined}
      >
        <SettingsList>
          {!usage ? (
            <SkeletonRows count={4} />
          ) : (
            cacheDirs.map((d) => (
              <DirRow
                key={d.key}
                dir={d}
                busy={busyKey === d.key}
                onClean={(mode) => void askClean(d, mode)}
              />
            ))
          )}
        </SettingsList>
      </SettingsSection>

      <SettingsSection
        title={t("settings.storage.ui.data")}
        description={
          usage ? t("settings.storage.ui.dataTotal", { bytes: formatBytes(usage.data_bytes) }) : undefined
        }
      >
        <SettingsList>
          {!usage ? (
            <SkeletonRows count={6} />
          ) : (
            dataDirs.map((d) => <DirRow key={d.key} dir={d} busy={false} />)
          )}
        </SettingsList>
      </SettingsSection>
    </div>
  );
}

/** 磁盘概览：剩余空间 + 分段条 + 图例。 */
function DiskOverview({
  usage,
  error,
}: {
  usage: StorageUsage | null;
  error: string | null;
}) {
  const t = useTranslations();

  const total = usage?.disk_total ?? 0;
  const cache = usage?.cache_bytes ?? 0;
  const data = usage?.data_bytes ?? 0;
  const free = usage?.disk_free ?? 0;
  // data/ 之外的其它占用（系统、其它应用）= 已用 − 本应用数据 − 缓存，负数按 0
  const other = Math.max(0, (usage?.disk_used ?? 0) - cache - data);
  const pct = (n: number) => (total > 0 ? `${(n / total) * 100}%` : "0%");
  const segments = [
    { label: t("settings.storage.ui.data"), value: data, color: "bg-sky-400/85" },
    { label: t("settings.storage.ui.reclaimable"), value: cache, color: "bg-amber-400/85" },
    { label: t("settings.storage.ui.other"), value: other, color: "bg-white/20" },
    { label: t("settings.storage.ui.free"), value: free, color: "bg-white/[0.07]" },
  ];

  return (
    <div className="css-glass !rounded-xl px-4 py-4">
      <div className="flex items-end justify-between gap-4">
        <div className="min-w-0">
          <p className="text-ui font-medium text-[var(--text)]">
            {t("settings.storage.ui.disk")}</p>
          <p
            className="mt-0.5 truncate font-mono text-caption text-[var(--text-faint)]"
            title={usage?.data_root}
          >
            {usage?.data_root ?? "…"}
          </p>
        </div>
        <div className="shrink-0 text-right">
          <p className="tnum text-title font-semibold leading-none text-[var(--text)]">
            {usage ? formatBytes(free) : "—"}
          </p>
          <p className="mt-1 tnum text-caption text-[var(--text-faint)]">
            {t("settings.storage.ui.freeTotal", { bytes: usage ? formatBytes(total) : "—" })}
          </p>
        </div>
      </div>

      <div className="mt-4 flex h-2 w-full gap-px overflow-hidden rounded-full bg-white/[0.07]">
        {segments.slice(0, 3).map((s) => (
          <div
            key={s.label}
            className={`${s.color} transition-[width]`}
            style={{ width: pct(s.value) }}
          />
        ))}
      </div>
      <div className="mt-3 flex flex-wrap gap-x-6 gap-y-1.5">
        {segments.map((s) => (
          <div
            key={s.label}
            className="flex items-center gap-2 whitespace-nowrap"
          >
            <span className={`size-2 shrink-0 rounded-full ${s.color}`} />
            <span className="text-caption text-[var(--text-muted)]">
              {s.label}
            </span>
            <span className="tnum text-sub font-medium text-[var(--text)]">
              {usage ? formatBytes(s.value) : "—"}
            </span>
          </div>
        ))}
      </div>
      {error && <p className="mt-3 text-sub text-[var(--danger)]">{error}</p>}
    </div>
  );
}

/** 一行目录：名称 + 一句话用途 | 占用 | ⋯ 菜单。 */
function DirRow({
  dir,
  busy,
  onClean,
}: {
  dir: DirUsage;
  busy: boolean;
  /** 只有可清理的目录传；点菜单项即发起确认（弹窗在上层） */
  onClean?: (mode: CleanMode) => void;
}) {
  const t = useTranslations();
  const locale = useLocale();

  const expensive = dir.rebuild_cost === "expensive";
  const actionable = dir.group === "cache" && !!onClean;
  return (
    <SettingsRow
      label={
        <span className={`flex items-center gap-1.5 ${locale === "en" ? "min-w-0" : ""}`}>
          <span className={locale === "en" ? "min-w-0 break-words" : "truncate"}>{dir.title}</span>
          <Tooltip
            content={
              <>
                <p>{dir.description}</p>
                <p className="mt-1.5 break-all font-mono text-caption text-[var(--text-muted)]">
                  {dir.path}
                </p>
              </>
            }
            placement="top"
            maxWidth={360}
            openOnClick
          >
            <button
              type="button"
              aria-label={t("settings.storage.ui.about", { title: dir.title })}
              className="flex shrink-0 text-[var(--text-faint)] transition-colors hover:text-[var(--text-muted)] focus-visible:text-[var(--text-muted)]"
            >
              <InfoIcon className="size-[14px]" />
            </button>
          </Tooltip>
        </span>
      }
      description={
        <span className={`flex items-center gap-1.5 ${locale === "en" ? "max-sm:flex-col max-sm:items-start" : ""}`}>
          {expensive && (
            <span className="shrink-0 rounded-full bg-amber-400/10 px-1.5 py-px text-micro font-medium text-amber-300/90">
              {t("settings.storage.ui.expensive")}
            </span>
          )}
          <span className={locale === "en" ? "min-w-0 break-words" : "truncate"}>{dir.summary}</span>
        </span>
      }
    >
      <span
        className={`tnum text-right text-ui font-semibold ${
          dir.exists && dir.bytes > 0 ? "text-[var(--text)]" : "text-[var(--text-faint)]"
        }`}
      >
        {dir.exists ? formatBytes(dir.bytes) : "—"}
      </span>
      {/* 两个清理动作收在 ⋯ 里；清理进行中换成转圈占位，行内不再需要「清理中…」长文案 */}
      {actionable &&
        (busy ? (
          <span className="grid size-8 shrink-0 place-items-center text-[var(--text-muted)]">
            <RefreshIcon className="size-4 animate-spin" />
          </span>
        ) : (
          <SettingsMoreMenu
            label={t("settings.storage.ui.actions", { title: dir.title })}
            disabled={!dir.exists}
            items={[
              ...(dir.orphan_aware
                ? [{ label: t("settings.storage.ui.orphans"), onSelect: () => onClean("orphans") }]
                : []),
              ...(dir.clearable
                ? [{ label: t("settings.storage.ui.clear"), onSelect: () => onClean("all"), danger: expensive }]
                : []),
            ]}
          />
        ))}
    </SettingsRow>
  );
}

function SkeletonRows({ count }: { count: number }) {
  return (
    <>
      {Array.from({ length: count }, (_, i) => (
        <div key={i} className="flex min-h-[56px] items-center gap-3 px-4 py-3">
          <div className="flex-1 space-y-1.5">
            <div className="h-3 w-28 animate-pulse rounded bg-white/[0.08]" />
            <div className="h-2.5 w-48 animate-pulse rounded bg-white/[0.05]" />
          </div>
          <div className="h-3 w-14 animate-pulse rounded bg-white/[0.08]" />
        </div>
      ))}
    </>
  );
}

/** 未登记条目只显示相对 data/ 的短路径，完整路径放 title。 */
function relativeTo(path: string, root: string): string {
  const prefix = root.endsWith("/") ? root : `${root}/`;
  return path.startsWith(prefix) ? path.slice(prefix.length) : path;
}
