"use client";

import { useLocale, useTranslations } from "next-intl";
import { appTranslator } from "@/lib/i18n/translate";
import { formatList } from "@/lib/i18n/format";

import { useEffect, useRef, useState } from "react";

import type { Route } from "next";
import Link from "next/link";

import { DirectoryPicker } from "@/components/directory-picker";
import { DriveFolderPicker, type PickedDriveFolder } from "@/components/drive-folder-picker";
import {
  CheckIcon,
  ChevronDownIcon,
  CloudDriveIcon,
  FolderIcon,
  InfoIcon,
  PlusIcon,
  XIcon,
} from "@/components/icons";
import { LibraryScrapeSettings } from "@/components/library-scrape-settings";
import { libraryKindMeta } from "@/components/library-kind-meta";
import { Modal } from "@/components/modal";
import { Tooltip } from "@/components/tooltip";
import { fileToCompressedJpeg } from "@/lib/backdrop";
import {
  type DriveAccount,
  getDriveStatus,
  listDriveAccounts,
  listDriveBackends,
} from "@/lib/api/drives";
import {
  type CloudFolderPayload,
  type LibraryCloudFolder,
  type LibraryPayload,
  type MatchRule,
  type MediaLibrary,
  type RoutingOptions,
  createLibrary,
  deleteLibraryCover,
  libraryCoverUrl,
  listLibraryRoutingOptions,
  updateLibrary,
  uploadLibraryCover,
  type LibraryAccessMode,
} from "@/lib/api/libraries";
import { responsiveImage } from "@/lib/image-proxy";
import { listMembers, type MemberView } from "@/lib/api/members";
import type { LibraryKind } from "@/lib/media-types";

/**
 * 媒体库表单弹窗（新建向导 / 编辑分区），从 library-view.tsx 拆出：
 * 首页只做浏览入口，建库与编辑落在管理页（docs/design/library-manage.md），
 * 单库页头部的「编辑库」也用这里的 LibraryFormDialog。
 */
/** 收藏范围标签使用 API 的分语言缓存；切换语言时不展示旧语言的选项。 */
export function useRoutingOptions(): RoutingOptions | null {
  const locale = useLocale();
  const [loaded, setLoaded] = useState<{ locale: typeof locale; data: RoutingOptions } | null>(null);
  useEffect(() => {
    let cancelled = false;
    void listLibraryRoutingOptions(locale)
      .then((data) => {
        if (!cancelled) setLoaded({ locale, data });
      })
      .catch(() => {});
    return () => { cancelled = true; };
  }, [locale]);
  return loaded?.locale === locale ? loaded.data : null;
}

/** 收藏范围条件 → 表单状态（v1 两个维度：类型 ID / 区域国家码）。 */
function parseMatchRules(rules: MatchRule[]): { genres: number[]; regions: string[] } {
  const genres = rules.find((r) => r.field === "genres")?.values ?? [];
  const regions = rules.find((r) => r.field === "origin_countries")?.values ?? [];
  return {
    genres: genres.filter((v): v is number => typeof v === "number"),
    regions: regions.filter((v): v is string => typeof v === "string"),
  };
}

/** 表单状态 → 收藏范围条件（空维度不生成条件；两者都空 = 不声明）。 */
function buildMatchRules(genres: number[], regions: string[]): MatchRule[] {
  const rules: MatchRule[] = [];
  if (genres.length > 0) rules.push({ field: "genres", op: "any_of", values: genres });
  if (regions.length > 0)
    rules.push({ field: "origin_countries", op: "any_of", values: regions });
  return rules;
}

/** 把区域国家码折叠成展示名：整组命中的折叠成预设组名（如「日韩」），
 *  折不进组的逐个显示中文名。用于表单弹窗底栏的当前声明摘要。 */
export function regionLabels(regions: string[], options: RoutingOptions): string[] {
  const parts: string[] = [];
  let rest = [...regions];
  for (const preset of options.region_presets) {
    if (preset.countries.every((c) => rest.includes(c))) {
      parts.push(preset.label);
      rest = rest.filter((c) => !preset.countries.includes(c));
    }
  }
  parts.push(...rest.map((c) => options.country_names[c] ?? c));
  return parts;
}

/* —— 媒体库表单：新建极简（向导），编辑分层（分区折叠） ——
 *
 * 新建只问必答题——类型、名称与目录、（影视库）收藏范围；四个扫描开关全有
 * 安全默认值，刮削偏好覆盖是少数人的精调，都放到编辑里。编辑按用途分区折叠，
 * 折叠态的摘要行先回答"这个库配成了什么样"，改哪项点哪项。
 * 设计稿：docs/design/library-other-kind.md 4.3 的表单节。 */

const INPUT_CLASS =
  "w-full rounded-xl border border-white/[0.08] bg-white/[0.04] px-3 py-2 text-ui " +
  "text-[var(--text)] outline-none focus:border-[var(--accent)]/60";
const LABEL_CLASS = "mb-1.5 block text-sub font-medium text-[var(--text-muted)]";

/** 类型卡片的文案：讲清后果，不提识别用的是哪个数据源；「其他」放什么由用户定。 */
function kindCards(t: ReturnType<typeof appTranslator>): Record<
  LibraryKind,
  { blurb: string; traits: string; chosen: string; defaultName: string; defaults: string }
> {
  return {
    movie: {
      blurb: t("library.form.movie.blurb"),
      traits: t("library.form.movie.traits"),
      chosen: t("library.form.movie.chosen"),
      defaultName: t("library.form.movie.defaultName"),
      defaults:
        t("library.form.movie.defaults"),
    },
    tv: {
      blurb: t("library.form.tv.blurb"),
      traits: t("library.form.tv.traits"),
      chosen: t("library.form.tv.chosen"),
      defaultName: t("library.form.tv.defaultName"),
      defaults:
        t("library.form.tv.defaults"),
    },
    video: {
      blurb:
        t("library.form.video.blurb"),
      traits: t("library.form.video.traits"),
      chosen: t("library.form.video.chosen"),
      defaultName: t("library.form.video.defaultName"),
      defaults:
        t("library.form.video.defaults"),
    },
    photo: {
      blurb:
        t("library.form.photo.blurb"),
      traits: t("library.form.photo.traits"),
      chosen: t("library.form.photo.chosen"),
      defaultName: t("library.form.photo.defaultName"),
      defaults:
        t("library.form.photo.defaults"),
    },
  };
}

/** 新建时的类型是否带识别链（决定有没有收藏范围这一步）；已有库读服务端能力位。 */
function kindIsScraped(kind: LibraryKind): boolean {
  return kind !== "video" && kind !== "photo";
}

/** 新建时「在首页展示」的默认值：图片库默认不上首页——一次导入几百张会把
 *  「最近添加」刷满（docs/design/library-photo-kind.md 2.9）；建好后可在编辑里打开。 */
function kindExcludedFromHome(kind: LibraryKind): boolean {
  return kind === "photo";
}

/** 表单里的一个网盘根目录（已挂上的带着服务端给的文件数） */
interface CloudRootDraft extends CloudFolderPayload {
  account_name: string;
  backend_title: string;
  file_count?: number;
}

function cloudDraftsOf(folders: LibraryCloudFolder[] | null | undefined): CloudRootDraft[] {
  return (folders ?? []).map((f) => ({
    account_id: f.account_id,
    remote_dir_id: f.remote_dir_id,
    display_path: f.display_path,
    is_primary: f.is_primary,
    account_name: f.account_name,
    backend_title: f.backend_title,
    file_count: f.file_count,
  }));
}

function cloudPayload(drafts: CloudRootDraft[]): CloudFolderPayload[] {
  return drafts.map((d) => ({
    account_id: d.account_id,
    remote_dir_id: d.remote_dir_id,
    display_path: d.display_path,
    is_primary: d.is_primary ?? false,
  }));
}

function draftOf(picked: PickedDriveFolder): CloudRootDraft {
  return {
    account_id: picked.account.id,
    remote_dir_id: picked.id,
    display_path: picked.path,
    is_primary: false,
    account_name: picked.account.name,
    backend_title: picked.account.backend_title,
  };
}

/** 网盘账号与可用的网盘（决定「＋ 网盘目录」出不出现）；查不到按没有处理。
 *  网盘功能休眠（没装网盘插件）时只问一次状态就停（cloud-storage.md §11.8）。 */
function useDriveRootOptions(enabled: boolean): { accounts: DriveAccount[]; hasBackends: boolean } {
  const [state, setState] = useState<{ accounts: DriveAccount[]; hasBackends: boolean }>({
    accounts: [],
    hasBackends: false,
  });
  useEffect(() => {
    if (!enabled) return;
    let cancelled = false;
    void getDriveStatus()
      .then(async (status) => {
        if (!status.active) return;
        const [accounts, backends] = await Promise.all([listDriveAccounts(), listDriveBackends()]);
        if (!cancelled) setState({ accounts, hasBackends: backends.length > 0 });
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, [enabled]);
  return state;
}

/** 网盘根目录行：挂上即纳管（按文件名识别、不下载、不改动网盘上的文件），拿掉只删台账。 */
function CloudRootRows({
  drafts,
  onChange,
  onAdd,
  options,
  needsLocal,
}: {
  drafts: CloudRootDraft[];
  onChange: (next: CloudRootDraft[]) => void;
  onAdd: () => void;
  options: { accounts: DriveAccount[]; hasBackends: boolean };
  /** 还没有服务器目录：主根得是一个服务器目录 */
  needsLocal: boolean;
}) {
  const t = useTranslations();
  const setPrimary = (target: CloudRootDraft) =>
    onChange(
      drafts.map((x) => ({
        ...x,
        is_primary: x.account_id === target.account_id && x.remote_dir_id === target.remote_dir_id,
      })),
    );
  const titles = new Set(options.accounts.map((a) => a.backend_title));
  const addLabel = titles.size === 1 ? t("library.form.cloudNamedRoot", { title: [...titles][0] }) : t("library.form.cloudRoots");
  if (drafts.length === 0 && options.accounts.length === 0 && !options.hasBackends) return null;
  return (
    <>
      {drafts.map((d) => (
        <div
          key={`${d.account_id}:${d.remote_dir_id}`}
          className="group flex items-center gap-2 rounded-xl border border-white/[0.08] bg-white/[0.04] px-3 py-2"
        >
          <CloudDriveIcon className="size-4 shrink-0 text-[var(--accent)]/80" />
          <span className="min-w-0 flex-1 truncate text-ui text-[var(--text)]">
            <span className="text-[var(--text-muted)]">{d.account_name} › </span>
            {d.display_path}
          </span>
          {d.file_count != null && (
            <span className="shrink-0 text-caption tabular-nums text-[var(--text-faint)]">
              {t("library.form.videoCount", { count: d.file_count })}
            </span>
          )}
          <span className="shrink-0 rounded-full bg-white/[0.08] px-2 py-0.5 text-micro font-medium text-[var(--text-muted)]">
            {d.backend_title}
          </span>
          {d.is_primary ? (
            <Tooltip
              content={
                <>
                  <strong>{t("library.form.primaryCloud")}</strong>{t("library.form.cloudNewFiles")}
                </>
              }
            >
              <span className="shrink-0 cursor-default rounded-full bg-[var(--accent)]/15 px-2 py-0.5 text-micro font-semibold text-[var(--accent)]">
                {t("library.form.primaryRoot")}
              </span>
            </Tooltip>
          ) : (
            <Tooltip content={t("library.form.makeCloudPrimaryHint")}>
              <button
                type="button"
                onClick={() => setPrimary(d)}
                className="touch-reveal shrink-0 rounded-full px-2 py-0.5 text-micro font-medium text-[var(--text-faint)] opacity-0 transition-opacity hover:bg-white/10 hover:text-white group-hover:opacity-100"
              >
                {t("library.form.makePrimary")}
              </button>
            </Tooltip>
          )}
          <button
            type="button"
            aria-label={t("library.form.removeEntry", { entry: d.display_path })}
            onClick={() =>
              onChange(
                drafts.filter(
                  (x) => !(x.account_id === d.account_id && x.remote_dir_id === d.remote_dir_id),
                ),
              )
            }
            className="shrink-0 rounded-md p-1 text-[var(--text-faint)] transition-colors hover:bg-white/10 hover:text-white"
          >
            <XIcon className="size-3.5" />
          </button>
        </div>
      ))}
      {options.accounts.length > 0 ? (
        <button
          type="button"
          onClick={onAdd}
          className="flex w-full items-center justify-center gap-2 rounded-xl border border-dashed border-white/15 px-3 py-2.5 text-ui font-medium text-[var(--text-muted)] transition-colors hover:border-[var(--accent)]/50 hover:text-white"
        >
          <PlusIcon className="size-4" />
          {addLabel}
        </button>
      ) : (
        options.hasBackends && (
          <p className="px-1 text-caption text-[var(--text-faint)]">
            {t.rich("library.form.connectCloud", { link: (chunks) => (
              <Link href={"/settings/drives" as Route} className="mx-1 underline underline-offset-4 hover:text-white">{chunks}</Link>
            ) })}
          </p>
        )
      )}
      {drafts.length > 0 && needsLocal && (
        <p className="px-1 text-caption leading-5 text-[var(--warn)]">
          {drafts.some((d) => d.is_primary)
            ? t("library.form.needStaging")
            : t("library.form.needPrimary")}
        </p>
      )}
      {drafts.some((d) => d.is_primary) && (
        <p className="flex items-start gap-2 rounded-xl border border-[var(--info)]/20 bg-[var(--info)]/[0.07] px-3 py-2.5 text-caption leading-5 text-[var(--text-muted)]">
          <CloudDriveIcon className="mt-0.5 size-3.5 shrink-0 text-[var(--info)]" />
          <span>
            <strong className="font-medium text-[var(--text)]">{t("library.form.primaryCloud")}</strong>
            {t("library.form.cloudExistingUpload")}
          </span>
        </p>
      )}
      {drafts.length > 0 && (
        <p className="px-1 text-caption leading-5 text-[var(--text-faint)]">
          {t("library.form.cloudExistingHint")}
        </p>
      )}
    </>
  );
}

/** 根目录列表：第一项为主根；行内可原位更改、设为主根、移除。 */
function RootsEditor({
  roots,
  onChange,
  onPick,
  cloud,
  cloudPrimary = false,
  onLocalPrimary,
}: {
  roots: string[];
  onChange: (next: string[]) => void;
  /** 打开目录选择器："add"=追加，数字=原位更改该下标 */
  onPick: (target: "add" | number) => void;
  /** 网盘根目录（没有网盘能力的库类型不传） */
  cloud?: React.ReactNode;
  /** 主根在网盘：第一个服务器目录只是本地暂存目录 */
  cloudPrimary?: boolean;
  /** 把某个服务器目录设为主根时，顺带取消网盘目录的主根 */
  onLocalPrimary?: () => void;
}) {
  const t = useTranslations();
  return (
    <div className="space-y-1.5">
      {roots.map((root, i) => (
        <div
          key={root}
          className="group flex items-center gap-2 rounded-xl border border-white/[0.08] bg-white/[0.04] px-3 py-2"
        >
          <FolderIcon className="size-4 shrink-0 text-[var(--accent)]/80" />
          {/* 保尾截断（dir=rtl）：路径的区分信息在尾部，省略号出现在头部；
              LRM 标记防止首尾的 "/" 在 RTL 下跳位。点击可原位更改目录 */}
          <Tooltip
            content={
              <>
                <p className="mb-1 break-all font-mono text-caption text-[var(--text-muted)]">{root}</p>
                {t("library.form.changeFolderHint")}
              </>
            }
          >
            <button
              type="button"
              dir="rtl"
              onClick={() => onPick(i)}
              className="min-w-0 flex-1 truncate rounded text-left font-mono text-ui text-[var(--text)] transition-colors hover:text-[var(--accent)]"
            >
              {"‎" + root + "‎"}
            </button>
          </Tooltip>
          {i === 0 && cloudPrimary && (
            <Tooltip content={t("library.form.stagingHint")}>
              <span className="shrink-0 cursor-default rounded-full bg-white/[0.08] px-2 py-0.5 text-micro font-semibold text-[var(--text-muted)]">
                {t("library.form.staging")}
              </span>
            </Tooltip>
          )}
          {i === 0 && !cloudPrimary ? (
            <Tooltip
              content={
                <>
                  <strong>{t("library.form.primaryMeaning")}</strong>
                  {t("library.form.primaryHint")}
                </>
              }
            >
              <span className="shrink-0 cursor-default rounded-full bg-[var(--accent)]/15 px-2 py-0.5 text-micro font-semibold text-[var(--accent)]">
                {t("library.form.primaryRoot")}
              </span>
            </Tooltip>
          ) : (
            <Tooltip content={t("library.form.makeLocalPrimaryHint")}>
              <button
                type="button"
                onClick={() => {
                  onChange([root, ...roots.filter((r) => r !== root)]);
                  onLocalPrimary?.();
                }}
                className="touch-reveal shrink-0 rounded-full px-2 py-0.5 text-micro font-medium text-[var(--text-faint)] opacity-0 transition-opacity hover:bg-white/10 hover:text-white group-hover:opacity-100"
              >
                {t("library.form.makePrimary")}
              </button>
            </Tooltip>
          )}
          <button
            type="button"
            aria-label={t("library.form.removeEntry", { entry: root })}
            onClick={() => onChange(roots.filter((r) => r !== root))}
            className="shrink-0 rounded-md p-1 text-[var(--text-faint)] transition-colors hover:bg-white/10 hover:text-white"
          >
            <XIcon className="size-3.5" />
          </button>
        </div>
      ))}
      <button
        type="button"
        onClick={() => onPick("add")}
        className="flex w-full items-center justify-center gap-2 rounded-xl border border-dashed border-white/15 px-3 py-2.5 text-ui font-medium text-[var(--text-muted)] transition-colors hover:border-[var(--accent)]/50 hover:text-white"
      >
        <PlusIcon className="size-4" />
        {roots.length === 0 ? t("library.form.browseServer") : t("library.form.addFolder")}
      </button>
      {cloud}
    </div>
  );
}

/** 服务端目录选择器的接线：追加时从最近添加的根起步，更改时从被改的根起步；
 *  追加去重，更改为原位替换（改主根仍是主根），撞上已有路径时合并去重。 */
function RootsPicker({
  target,
  roots,
  onChange,
  onClose,
}: {
  target: "add" | number | null;
  roots: string[];
  onChange: (next: string[]) => void;
  onClose: () => void;
}) {
  return (
    <DirectoryPicker
      open={target !== null}
      initialPath={
        target === "add" || target === null
          ? roots.length > 0
            ? roots[roots.length - 1]
            : undefined
          : roots[target]
      }
      onClose={onClose}
      onSelect={(path) => {
        if (target === "add" || target === null) {
          onChange(roots.includes(path) ? roots : [...roots, path]);
        } else {
          const next = roots.map((r, idx) => (idx === target ? path : r));
          onChange(next.filter((r, idx) => r !== path || idx === target));
        }
        onClose();
      }}
    />
  );
}

/** 类型可选项：按作品类型取对应的 TMDB 类型表；kind 为 null（规则组适用范围
 *  不限电影/剧集）时取两表并集，同 ID 只保留一个。 */
export function genreOptionsFor(
  kind: LibraryKind | null,
  options: RoutingOptions,
): { id: number; label: string }[] {
  if (kind === "movie") return options.movie_genres;
  if (kind !== null) return options.tv_genres;
  const seen = new Set<number>();
  return [...options.movie_genres, ...options.tv_genres].filter((g) => {
    if (seen.has(g.id)) return false;
    seen.add(g.id);
    return true;
  });
}

/** 收藏范围：区域逐国勾选（预设组是一键整组的快捷键）+ 类型多选，两个维度间是"且"。
 *  规则组的适用范围也用它（kind 为 null = 不限电影/剧集）。 */
export function ScopeEditor({
  kind,
  regions,
  genres,
  onRegions,
  onGenres,
  options,
}: {
  kind: LibraryKind | null;
  regions: string[];
  genres: number[];
  onRegions: (next: string[]) => void;
  onGenres: (next: number[]) => void;
  options: RoutingOptions | null;
}) {
  const t = useTranslations();
  if (options === null) {
    return (
      <p className="rounded-xl border border-white/[0.08] bg-white/[0.03] px-3 py-2.5 text-sub text-[var(--text-faint)]">
        {t("library.form.loadingOptions")}
      </p>
    );
  }
  const genreOptions = genreOptionsFor(kind, options);
  const allCountries = Object.keys(options.country_names);
  return (
    <>
      <div>
        <label className={LABEL_CLASS}>{t("library.form.matchRegions")}</label>
        {/* 已选中但不在内置映射里的码补进列表，保证选了就能看见、能取消 */}
        <div className="flex flex-wrap gap-1.5">
          {[
            ...Object.entries(options.country_names),
            ...regions
              .filter((c) => !(c in options.country_names))
              .map((c): [string, string] => [c, c]),
          ].map(([code, label]) => (
            <button
              key={code}
              type="button"
              data-active={regions.includes(code)}
              onClick={() =>
                onRegions(
                  regions.includes(code) ? regions.filter((c) => c !== code) : [...regions, code],
                )
              }
              className="glass-row nav-item !w-auto px-3 py-1.5 text-sub font-medium"
            >
              {label}
            </button>
          ))}
        </div>
        <div className="mt-2 flex flex-wrap items-center gap-1.5">
          <span className="text-caption text-[var(--text-faint)]">{t("library.form.regionPresets")}</span>
          <button
            type="button"
            onClick={() =>
              onRegions(
                allCountries.every((c) => regions.includes(c))
                  ? []
                  : [...new Set([...regions, ...allCountries])],
              )
            }
            className="glass-row nav-item !w-auto px-2.5 py-1 text-caption font-medium"
          >
            {allCountries.every((c) => regions.includes(c)) ? t("common.clear") : t("common.selectAll")}
          </button>
          {options.region_presets.map((preset) => {
            const active = preset.countries.every((c) => regions.includes(c));
            return (
              <button
                key={preset.key}
                type="button"
                data-active={active}
                title={preset.countries.map((c) => options.country_names[c] ?? c).join(" / ")}
                onClick={() =>
                  onRegions(
                    active
                      ? regions.filter((c) => !preset.countries.includes(c))
                      : [...new Set([...regions, ...preset.countries])],
                  )
                }
                className="glass-row nav-item !w-auto px-2.5 py-1 text-caption font-medium"
              >
                {preset.label}
              </button>
            );
          })}
        </div>
      </div>
      <div>
        <label className={LABEL_CLASS}>{t("library.form.matchGenres")}</label>
        <div className="flex flex-wrap items-center gap-1.5">
          <button
            type="button"
            onClick={() =>
              onGenres(
                genreOptions.every((g) => genres.includes(g.id))
                  ? []
                  : [...new Set([...genres, ...genreOptions.map((g) => g.id)])],
              )
            }
            className="glass-row nav-item !w-auto px-2.5 py-1 text-caption font-medium"
          >
            {genreOptions.every((g) => genres.includes(g.id)) ? t("common.clear") : t("common.selectAll")}
          </button>
          {genreOptions.map((g) => (
            <button
              key={g.id}
              type="button"
              data-active={genres.includes(g.id)}
              onClick={() =>
                onGenres(
                  genres.includes(g.id) ? genres.filter((id) => id !== g.id) : [...genres, g.id],
                )
              }
              className="glass-row nav-item !w-auto px-3 py-1.5 text-sub font-medium"
            >
              {g.label}
            </button>
          ))}
        </div>
      </div>
      {regions.length > 0 && genres.length > 0 && (
        <p className="text-caption leading-relaxed text-[var(--text-faint)]">
          {t.rich("library.form.scopeBoth", { strong: (chunks) => <strong className="font-medium text-[var(--text-muted)]">{chunks}</strong> })}
        </p>
      )}
    </>
  );
}

/** 收藏范围的一句话摘要（新建第 3 步底部与编辑分区的折叠行共用）。 */
function scopeSummary(
  kind: LibraryKind,
  regions: string[],
  genres: number[],
  options: RoutingOptions | null,
): { declared: boolean; text: string } {
  const t = appTranslator();
  if (options === null) {
    const declared = regions.length > 0 || genres.length > 0;
    return { declared, text: declared ? t("library.form.scopeSet") : t("library.form.scopeUnset") };
  }
  const genreOptions = kind === "movie" ? options.movie_genres : options.tv_genres;
  const parts = [
    regionLabels(regions, options).join(" / "),
    genreOptions
      .filter((g) => genres.includes(g.id))
      .map((g) => g.label)
      .join(" / "),
  ].filter(Boolean);
  return parts.length > 0
    ? { declared: true, text: parts.length === 2 ? t("library.form.scopeDescription", { regions: parts[0], genres: parts[1] }) : parts[0] }
    : { declared: false, text: t("library.form.scopeUnset") };
}

/** 类型 ID 只保留当前库类型下有效的（切换过类型时另一类型独有的 ID 不带进声明）。 */
function validGenres(kind: LibraryKind, genres: number[], options: RoutingOptions | null): number[] {
  if (options === null) return genres;
  const valid = new Set((kind === "movie" ? options.movie_genres : options.tv_genres).map((g) => g.id));
  return genres.filter((id) => valid.has(id));
}

/** 表单入口：新建走向导，编辑走分区面板；调用方只关心 state 三态。 */
export function LibraryFormDialog({
  state,
  onClose,
  onSaved,
}: {
  /** "new"=新增；库对象=编辑；null=关闭 */
  state: MediaLibrary | "new" | null;
  onClose: () => void;
  /** 保存成功回调，带上服务端返回的库（新建时调用方据此把新卡片滚进视野） */
  onSaved: (saved: MediaLibrary) => void;
}) {
  if (state === null) return null;
  if (state === "new") return <CreateLibraryDialog onClose={onClose} onSaved={onSaved} />;
  return <EditLibraryDialog key={state.id} library={state} onClose={onClose} onSaved={onSaved} />;
}

/* —— 新建：选类型 → 名称与目录 → （影视库）收藏范围 —— */

function CreateLibraryDialog({
  onClose,
  onSaved,
}: {
  onClose: () => void;
  onSaved: (saved: MediaLibrary) => void;
}) {
  const t = useTranslations();
  const locale = useLocale();
  const [step, setStep] = useState<1 | 2 | 3>(1);
  const [kind, setKind] = useState<LibraryKind | null>(null);
  const [name, setName] = useState("");
  const [roots, setRoots] = useState<string[]>([]);
  const [pickerTarget, setPickerTarget] = useState<"add" | number | null>(null);
  const [cloud, setCloud] = useState<CloudRootDraft[]>([]);
  const [drivePicker, setDrivePicker] = useState(false);
  const [regions, setRegions] = useState<string[]>([]);
  const [genres, setGenres] = useState<number[]>([]);
  const [accessMode, setAccessMode] = useState<LibraryAccessMode>("everyone");
  const [adminVisible, setAdminVisible] = useState(true);
  const [memberIds, setMemberIds] = useState<number[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const routingOptions = useRoutingOptions();

  const hasScope = kind !== null && kindIsScraped(kind);
  // 网盘目录只给能播放的库（相册没有取流这回事）
  const cloudCapable = kind !== null && kind !== "photo";
  const driveOptions = useDriveRootOptions(true);
  const totalSteps = hasScope ? 3 : 2;
  const ready = name.trim().length > 0 && roots.length > 0;
  const scope = kind ? scopeSummary(kind, regions, genres, routingOptions) : null;

  const chooseKind = (next: LibraryKind) => {
    // 名称按类型预填；用户已经改过的名字不动
    const untouched = name.trim() === "" || (kind !== null && name === kindCards(t)[kind].defaultName);
    setKind(next);
    if (untouched) setName(kindCards(t)[next].defaultName);
    if (!kindIsScraped(next)) {
      setRegions([]);
      setGenres([]);
    }
    setStep(2);
  };

  const submit = () => {
    if (kind === null || !ready || busy) return;
    setBusy(true);
    setError(null);
    const payload: LibraryPayload = {
      name: name.trim(),
      kind,
      root_paths: roots,
      match_rules: hasScope ? buildMatchRules(validGenres(kind, genres, routingOptions), regions) : [],
      // 开关全按推荐值：监控开、自动清理关、封面开、章节关（抓帧成本高，按需在
      // 编辑里打开）、片头片尾识别开（只对剧集库起作用）、首页展示；建好后在编辑里调
      auto_clear_missing: false,
      realtime_watch: true,
      generate_thumbnails: true,
      extract_chapter_images: false,
      detect_media_segments: true,
      exclude_from_home: kindExcludedFromHome(kind),
      scrape_overrides: {},
      access_mode: accessMode,
      admin_visible: adminVisible,
      member_ids: accessMode === "selected" ? memberIds : [],
      ...(cloudCapable && cloud.length > 0 ? { cloud_folders: cloudPayload(cloud) } : {}),
    };
    void createLibrary(payload)
      .then(onSaved)
      .catch((e) => setError((e as Error).message))
      .finally(() => setBusy(false));
  };

  // 主按钮随步骤变化：第 2 步对影视库是「下一步」，最后一步保存即扫描
  const primary =
    step === 1
      ? { label: t("library.form.createAndScan"), disabled: true, action: () => {} }
      : step === 2 && hasScope
        ? { label: t("library.form.nextScope"), disabled: !ready, action: () => setStep(3) }
        : {
            label: busy
              ? t("library.form.creating")
              : step === 3 && scope !== null && !scope.declared
                ? t("library.form.skipAndCreate")
                : t("library.form.createAndScan"),
            disabled: !ready || busy,
            action: submit,
          };
  const footNote =
    t("library.form.stepProgress", { step, total: totalSteps }) + (step === totalSteps ? t("library.form.scanOnSaveSuffix") : "");

  return (
    <>
      <Modal open onClose={onClose} label={t("library.form.addTitle")} width="2xl" panelClassName="flex max-h-[86dvh] flex-col">
        <div className="shrink-0 border-b border-white/[0.06] px-6 pt-5 max-md:px-5">
          <h2 className="text-title font-bold text-white">{t("library.form.addTitle")}</h2>
          <ol className="mt-3.5 flex gap-5 text-caption font-semibold uppercase tracking-[0.06em]">
            {(
              [
                [1, t("library.form.stepType")],
                [2, t("library.form.stepFolders")],
                [3, t("library.form.stepScope")],
              ] as const
            )
              .filter(([n]) => n !== 3 || hasScope)
              .map(([n, label]) => (
                <li
                  key={n}
                  aria-current={step === n ? "step" : undefined}
                  className={`relative pb-2.5 ${step === n ? "text-white" : "text-[var(--text-faint)]"}`}
                >
                  {label}
                  {step === n && (
                    <span className="absolute inset-x-0 bottom-0 h-0.5 rounded-full bg-[var(--accent)]" />
                  )}
                </li>
              ))}
          </ol>
        </div>

        <div className="scroll-thin min-h-0 flex-1 space-y-4 overflow-y-auto p-6 max-md:p-5">
          {step === 1 && (
            <>
              <div className="grid grid-cols-2 gap-2.5 max-md:grid-cols-1">
                {(Object.keys(libraryKindMeta(locale)) as LibraryKind[]).map((k) => {
                  const { label, Icon } = libraryKindMeta(locale)[k];
                  const card = kindCards(t)[k];
                  return (
                    <button
                      key={k}
                      type="button"
                      onClick={() => chooseKind(k)}
                      data-active={kind === k}
                      className="flex min-h-[148px] flex-col gap-2.5 rounded-2xl border border-white/[0.08] bg-white/[0.04] p-4 text-left transition-colors hover:border-white/20 hover:bg-white/[0.075] data-[active=true]:border-[var(--accent-2)] data-[active=true]:bg-white/[0.12]"
                    >
                      <Icon className="size-[22px] text-[var(--accent)]" />
                      <span className="text-body font-semibold text-white">{label}</span>
                      <span className="text-caption leading-relaxed text-[var(--text-muted)]">{card.blurb}</span>
                      <span className="mt-auto text-micro text-[var(--text-faint)]">{card.traits}</span>
                    </button>
                  );
                })}
              </div>
              <p className="text-caption leading-relaxed text-[var(--text-faint)]">
                {t("library.form.typeHint")}
              </p>
            </>
          )}

          {step === 2 && kind !== null && (
            <>
              {(() => {
                const { label, Icon } = libraryKindMeta(locale)[kind];
                return (
                  <div className="flex items-center gap-2.5 rounded-xl border border-white/[0.08] bg-white/[0.04] px-3 py-2.5">
                    <Icon className="size-[18px] shrink-0 text-[var(--accent)]" />
                    <span className="font-semibold text-white">{label}</span>
                    <span className="min-w-0 truncate text-caption text-[var(--text-muted)]">
                      {kindCards(t)[kind].chosen}
                    </span>
                    <button
                      type="button"
                      onClick={() => setStep(1)}
                      className="ml-auto shrink-0 text-caption text-[var(--text-faint)] underline underline-offset-4 hover:text-white"
                    >
                      {t("library.form.changeType")}
                    </button>
                  </div>
                );
              })()}
              <div>
                <label className={LABEL_CLASS}>{t("library.form.name")}</label>
                <input
                  type="text"
                  value={name}
                  onChange={(e) => setName(e.target.value)}
                  onKeyDown={(e) => {
                    // isComposing：中文输入法选词的回车不当提交
                    if (e.key === "Enter" && !e.nativeEvent.isComposing && !primary.disabled) primary.action();
                  }}
                  placeholder={t("library.form.namePlaceholder")}
                  autoComplete="off"
                  className={INPUT_CLASS}
                />
              </div>
              <div>
                <label className={LABEL_CLASS}>
                  {t("library.form.roots")}
                  <span className="font-normal text-[var(--text-faint)]">{t("library.form.primaryNote")}</span>
                </label>
                <RootsEditor
                  roots={roots}
                  onChange={setRoots}
                  onPick={setPickerTarget}
                  cloudPrimary={cloudCapable && cloud.some((c) => c.is_primary)}
                  onLocalPrimary={() => setCloud(cloud.map((c) => ({ ...c, is_primary: false })))}
                  cloud={
                    cloudCapable && (
                      <CloudRootRows
                        drafts={cloud}
                        onChange={setCloud}
                        onAdd={() => setDrivePicker(true)}
                        options={driveOptions}
                        needsLocal={roots.length === 0}
                      />
                    )
                  }
                />
              </div>
              <div>
                <label className={LABEL_CLASS}>{t("library.form.accessScope")}</label>
                <AccessScopeEditor
                  mode={accessMode}
                  adminVisible={adminVisible}
                  memberIds={memberIds}
                  onMode={setAccessMode}
                  onAdminVisible={setAdminVisible}
                  onMemberIds={setMemberIds}
                />
              </div>
              <div className="flex items-start gap-2.5 rounded-xl border border-[var(--info)]/20 bg-[var(--info)]/[0.07] px-3.5 py-3 text-caption leading-relaxed text-[var(--text-muted)]">
                <InfoIcon className="mt-0.5 size-4 shrink-0 text-[var(--info)]" />
                <p>
                  <strong className="font-medium text-[var(--text)]">{t("library.form.defaultsIntro")}</strong>
                  {kindCards(t)[kind].defaults}
                </p>
              </div>
            </>
          )}

          {step === 3 && kind !== null && (
            <>
              <p className="text-sub leading-relaxed text-[var(--text-muted)]">
                {t.rich("library.form.scopeIntroduction", { strong: (chunks) => <strong className="font-medium text-[var(--text)]">{chunks}</strong> })}
              </p>
              <ScopeEditor
                kind={kind}
                regions={regions}
                genres={genres}
                onRegions={setRegions}
                onGenres={setGenres}
                options={routingOptions}
              />
              <p className="text-caption leading-relaxed text-[var(--text-faint)]">
                {scope?.declared
                  ? t("library.form.scopeCurrent", { scope: scope.text })
                  : t("library.form.scopeFallback")}
              </p>
            </>
          )}
        </div>

        <div className="shrink-0 border-t border-white/[0.06] px-6 py-4 max-md:px-5">
          {error && (
            <p className="mb-3 rounded-lg border border-red-400/25 bg-red-500/10 px-3.5 py-2.5 text-ui leading-6 text-red-200">
              {error}
            </p>
          )}
          <div className="flex items-center justify-between gap-3">
            <p className="min-w-0 truncate text-caption text-[var(--text-faint)]">{footNote}</p>
            <div className="flex shrink-0 items-center gap-3">
              <button
                type="button"
                onClick={step === 1 ? onClose : () => setStep(step === 3 ? 2 : 1)}
                className="btn-glass h-9 px-4 text-ui font-medium"
              >
                {step === 1 ? t("common.cancel") : t("library.form.previousStep")}
              </button>
              <button
                type="button"
                onClick={primary.action}
                disabled={primary.disabled}
                className="btn-accent h-9 rounded-full px-5 text-ui font-semibold disabled:opacity-40"
              >
                {primary.label}
              </button>
            </div>
          </div>
        </div>
      </Modal>
      <RootsPicker target={pickerTarget} roots={roots} onChange={setRoots} onClose={() => setPickerTarget(null)} />
      {drivePicker && (
        <DriveFolderPicker
          accounts={driveOptions.accounts}
          libraryId={null}
          taken={cloud.map((c) => ({ account_id: c.account_id, path: c.display_path }))}
          onClose={() => setDrivePicker(false)}
          onSelect={(picked) => {
            setCloud([...cloud, draftOf(picked)]);
            setDrivePicker(false);
          }}
        />
      )}
    </>
  );
}

/* —— 编辑：分区折叠，每区一行摘要 —— */

type EditSectionId = "basic" | "cover" | "scan" | "access" | "scope" | "scrape";

/**
 * 封面编辑器：上传一张自己的图顶掉服务端自动拼贴的「氛围光货架」（issue #427）。
 *
 * 与这个弹窗里其它字段不同，封面**上传即生效**、不等「保存」——它是一次文件
 * 传输而不是表单字段，攒到保存再传只会让失败反馈来得更晚。文案里把这点说明白。
 *
 * 上传前先在浏览器压一道（长边 1600 的 JPEG）：省上传体积、也避开 10MB 的
 * 上限；服务端还会再归一化一次，那才是真正的保证（CLI 等客户端绕得过浏览器）。
 */
function CoverEditor({
  libraryId,
  custom,
  onChange,
}: {
  libraryId: number;
  custom: boolean;
  onChange: (next: boolean) => void;
}) {
  const t = useTranslations();
  const fileInput = useRef<HTMLInputElement | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // 换图后要让 <img> 真的重取：libraryCoverUrl 里的时间戳变了，src 才会变
  const [stamp, setStamp] = useState(0);
  const [failed, setFailed] = useState(false);

  const pick = (file: File | null | undefined) => {
    if (!file || busy) return;
    setBusy(true);
    setError(null);
    void fileToCompressedJpeg(file, 1600)
      .then((blob) => uploadLibraryCover(libraryId, blob))
      .then(() => {
        setFailed(false);
        setStamp((n) => n + 1);
        onChange(true);
      })
      .catch((e) => setError((e as Error).message))
      .finally(() => setBusy(false));
  };

  const restore = () => {
    if (busy) return;
    setBusy(true);
    setError(null);
    void deleteLibraryCover(libraryId)
      .then(() => {
        setFailed(false);
        setStamp((n) => n + 1);
        onChange(false);
      })
      .catch((e) => setError((e as Error).message))
      .finally(() => setBusy(false));
  };

  return (
    <>
      <div className="flex items-start gap-4 max-md:flex-col">
        <div className="relative aspect-[21/10] w-52 shrink-0 overflow-hidden rounded-xl border border-white/[0.08] bg-gradient-to-br from-[#1c2230] to-[#10131c] max-md:w-full">
          {failed ? (
            <div className="grid size-full place-items-center text-caption text-[var(--text-faint)]">
              {t("library.form.noCover")}
            </div>
          ) : (
            <img
              key={stamp}
              // 预览框 w-52（208），手机通栏约 360
              {...responsiveImage(libraryCoverUrl(libraryId), 360)}
              alt=""
              className="size-full object-cover"
              onError={() => setFailed(true)}
            />
          )}
        </div>
        <div className="min-w-0 flex-1 space-y-2.5">
          <p className="text-sub leading-6 text-[var(--text-muted)]">
            {custom
              ? t("library.form.customCoverHint")
              : t("library.form.autoCoverHint")}
          </p>
          <p className="text-caption leading-5 text-[var(--text-faint)]">
            {t("library.form.coverUploadHint")}
          </p>
          <div className="flex flex-wrap items-center gap-2.5">
            <button
              type="button"
              onClick={() => fileInput.current?.click()}
              disabled={busy}
              className="btn-glass h-8 px-3.5 text-ui font-medium disabled:opacity-40"
            >
              {busy ? t("library.form.processingCover") : custom ? t("library.form.replaceCover") : t("library.form.uploadCover")}
            </button>
            {custom && (
              <button
                type="button"
                onClick={restore}
                disabled={busy}
                className="btn-glass h-8 px-3.5 text-ui font-medium text-[var(--text-muted)] disabled:opacity-40"
              >
                {t("library.form.restoreAutoCover")}
              </button>
            )}
          </div>
          {error && <p className="text-caption leading-5 text-red-300">{error}</p>}
        </div>
      </div>
      <input
        ref={fileInput}
        type="file"
        accept="image/*"
        className="hidden"
        onChange={(e) => {
          pick(e.target.files?.[0]);
          // 同一个文件再选一次也要触发 change
          e.target.value = "";
        }}
      />
    </>
  );
}

/**
 * 可见范围编辑器（docs/design/library-access.md 2.1）：
 * 「所有成员」= 对全部成员自动开放（含以后新建的）；「指定成员」= 只对勾选的
 * 成员开放，名单第一项固定是「超管（我自己）」——超管不是成员，进不了白名单，
 * 单独一位存在 admin_visible 上，但对用户就是同一份名单。
 * 管理权与浏览权分离：超管把自己摘掉后仍能管理这个库，只是看不到内容。
 */
function AccessScopeEditor({
  mode,
  adminVisible,
  memberIds,
  onMode,
  onAdminVisible,
  onMemberIds,
}: {
  mode: LibraryAccessMode;
  adminVisible: boolean;
  memberIds: number[];
  onMode: (next: LibraryAccessMode) => void;
  onAdminVisible: (next: boolean) => void;
  onMemberIds: (next: number[]) => void;
}) {
  const t = useTranslations();
  const [members, setMembers] = useState<MemberView[] | null>(null);
  useEffect(() => {
    let cancelled = false;
    listMembers()
      .then((rows) => {
        if (!cancelled) setMembers(rows.filter((m) => m.status === "active"));
      })
      .catch(() => {
        if (!cancelled) setMembers([]);
      });
    return () => {
      cancelled = true;
    };
  }, []);
  const modeButton = (value: LibraryAccessMode, label: string) => (
    <button
      type="button"
      onClick={() => onMode(value)}
      className={`rounded-md px-3 py-1.5 text-sub font-medium transition-colors ${
        mode === value ? "bg-white/[0.11] text-white" : "text-[var(--text-faint)] hover:text-[var(--text)]"
      }`}
    >
      {label}
    </button>
  );
  const nobody = mode === "selected" && !adminVisible && memberIds.length === 0;
  // 超管与成员同列一份名单：超管用固定 id "admin"，成员用数字 id
  const options: ViewerOption[] = [
    { id: ADMIN_OPTION_ID, label: t("library.form.adminSelf"), hint: t("library.form.yourself") },
    ...(members ?? []).map((m) => ({
      id: m.id,
      label: m.nickname || m.username,
      hint: `@${m.username}`,
    })),
  ];
  const selected: ViewerOptionId[] = [
    ...(adminVisible ? [ADMIN_OPTION_ID as ViewerOptionId] : []),
    ...memberIds,
  ];
  const setSelected = (next: ViewerOptionId[]) => {
    onAdminVisible(next.includes(ADMIN_OPTION_ID));
    onMemberIds(next.filter((v): v is number => typeof v === "number"));
  };
  return (
    <div>
      <div className="inline-flex rounded-lg border border-white/[0.08] bg-white/[0.035] p-1">
        {modeButton("everyone", t("library.form.allMembers"))}
        {modeButton("selected", t("library.form.selectedMembers"))}
      </div>
      <p className="mt-2 text-caption leading-relaxed text-[var(--text-faint)]">
        {mode === "everyone"
          ? t("library.form.everyoneHint")
          : t("library.form.selectedHint")}
      </p>
      {mode === "selected" && (
        <div className="mt-3">
          <ViewerCombobox
            options={options}
            selected={selected}
            onChange={setSelected}
            loading={members === null}
          />
        </div>
      )}
      {nobody && (
        <p className="mt-2.5 text-caption leading-relaxed text-[var(--warn)]">
          {t("library.form.noViewersWarning")}
        </p>
      )}
    </div>
  );
}

const ADMIN_OPTION_ID = "admin" as const;
type ViewerOptionId = number | typeof ADMIN_OPTION_ID;
interface ViewerOption {
  id: ViewerOptionId;
  label: string;
  hint: string;
}

/**
 * 可见成员的多选下拉：输入关键字过滤（昵称 / 用户名都匹配），列表里点选或
 * 回车切换，已选的人显示为可移除的标签。与成员管理页的选择方式一致，
 * 成员一多也不会铺成一大片按钮。
 */
function ViewerCombobox({
  options,
  selected,
  onChange,
  loading,
}: {
  options: ViewerOption[];
  selected: ViewerOptionId[];
  onChange: (next: ViewerOptionId[]) => void;
  loading: boolean;
}) {
  const t = useTranslations();
  const [query, setQuery] = useState("");
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(0);
  const rootRef = useRef<HTMLDivElement>(null);
  const keyword = query.trim().toLowerCase();
  const matches = options.filter(
    (o) => keyword === "" || o.label.toLowerCase().includes(keyword) || o.hint.toLowerCase().includes(keyword),
  );
  const toggle = (id: ViewerOptionId) =>
    onChange(selected.includes(id) ? selected.filter((v) => v !== id) : [...selected, id]);
  // 点到组件外面就收起
  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => {
      if (!rootRef.current?.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener("mousedown", onDown);
    return () => document.removeEventListener("mousedown", onDown);
  }, [open]);
  useEffect(() => setActive(0), [keyword]);
  const chosen = selected
    .map((id) => options.find((o) => o.id === id))
    .filter((o): o is ViewerOption => o !== undefined);

  return (
    <div ref={rootRef} className="relative">
      <div
        className={`${INPUT_CLASS} flex min-h-[42px] flex-wrap items-center gap-1.5 !py-1.5`}
        onClick={() => rootRef.current?.querySelector("input")?.focus()}
      >
        {chosen.map((o) => (
          <span
            key={String(o.id)}
            className="flex items-center gap-1 rounded-md border border-[var(--accent)]/40 bg-[var(--accent-soft)] py-0.5 pl-2 pr-1 text-sub font-medium text-[var(--accent)]"
          >
            {o.label}
            <button
              type="button"
              aria-label={t("library.form.removeEntry", { entry: o.label })}
              onClick={(e) => {
                e.stopPropagation();
                toggle(o.id);
              }}
              className="grid size-4 place-items-center rounded hover:bg-white/15"
            >
              <XIcon className="size-3" />
            </button>
          </span>
        ))}
        <input
          type="text"
          role="combobox"
          aria-expanded={open}
          aria-controls="viewer-combobox-list"
          value={query}
          placeholder={chosen.length === 0 ? t("library.form.viewerPlaceholder") : t("library.form.addMoreViewers")}
          onChange={(e) => {
            setQuery(e.target.value);
            setOpen(true);
          }}
          onFocus={() => setOpen(true)}
          onKeyDown={(e) => {
            if (e.nativeEvent.isComposing) return;
            if (e.key === "ArrowDown") {
              e.preventDefault();
              setOpen(true);
              setActive((i) => Math.min(i + 1, Math.max(matches.length - 1, 0)));
            } else if (e.key === "ArrowUp") {
              e.preventDefault();
              setActive((i) => Math.max(i - 1, 0));
            } else if (e.key === "Enter") {
              e.preventDefault();
              if (open && matches[active]) toggle(matches[active].id);
            } else if (e.key === "Escape") {
              setOpen(false);
            } else if (e.key === "Backspace" && query === "" && chosen.length > 0) {
              toggle(chosen[chosen.length - 1].id);
            }
          }}
          className="min-w-[8rem] flex-1 bg-transparent text-ui text-[var(--text)] outline-none placeholder:text-[var(--text-faint)]"
        />
      </div>
      {open && (
        <div
          id="viewer-combobox-list"
          role="listbox"
          aria-multiselectable
          // 就地展开而不是浮层：编辑对话框的分区容器带 overflow-hidden，浮层会被裁掉
          className="mt-1.5 max-h-56 overflow-y-auto rounded-xl border border-white/[0.08] bg-white/[0.04] p-1"
        >
          {loading ? (
            <p className="px-3 py-2 text-caption text-[var(--text-faint)]">{t("library.form.loadingMembers")}</p>
          ) : matches.length === 0 ? (
            <p className="px-3 py-2 text-caption text-[var(--text-faint)]">{t("library.form.noMembersMatch")}</p>
          ) : (
            matches.map((o, index) => {
              const on = selected.includes(o.id);
              return (
                <button
                  key={String(o.id)}
                  type="button"
                  role="option"
                  aria-selected={on}
                  onMouseEnter={() => setActive(index)}
                  onClick={() => toggle(o.id)}
                  className={`glass-row nav-item flex w-full items-center gap-2.5 px-3 py-2 text-left text-ui ${
                    index === active ? "!bg-[var(--glass-fill-hover)] !text-[var(--text)]" : ""
                  }`}
                >
                  <span
                    className={`grid size-4 shrink-0 place-items-center rounded border ${
                      on ? "border-[var(--accent)] bg-[var(--accent)] text-white" : "border-white/25"
                    }`}
                  >
                    {on && <CheckIcon className="size-3" />}
                  </span>
                  <span className="min-w-0 flex-1 truncate font-medium">{o.label}</span>
                  <span className="shrink-0 text-caption text-[var(--text-faint)]">{o.hint}</span>
                </button>
              );
            })
          )}
        </div>
      )}
    </div>
  );
}

/** 可见范围的一句话摘要（编辑对话框的分区摘要行）。 */
function accessScopeSummary(
  mode: LibraryAccessMode,
  adminVisible: boolean,
  memberCount: number,
): string {
  const t = appTranslator();
  if (mode === "everyone") return t("library.form.allMembers");
  const parts = [adminVisible ? t("library.form.myself") : null, memberCount > 0 ? t("library.form.memberCount", { count: memberCount }) : null].filter(
    (v): v is string => v !== null,
  );
  return parts.length > 0 ? t("library.form.selectedViewers", { viewers: parts.join(" + ") }) : t("library.form.noSelectedViewers");
}

/** 开关行：一句话标题 + ⓘ 长说明 + 开关；长篇解释不再常驻表单里。 */
function SwitchRow({
  title,
  detail,
  checked,
  onChange,
}: {
  title: string;
  detail: React.ReactNode;
  checked: boolean;
  onChange: (next: boolean) => void;
}) {
  const t = useTranslations();
  return (
    <div className="flex items-center justify-between gap-3 border-t border-white/[0.06] py-2.5 first:border-t-0">
      <div className="flex items-center gap-1.5 text-ui font-medium text-[var(--text)]">
        {title}
        <Tooltip content={detail} openOnClick>
          <button
            type="button"
            aria-label={t("library.form.aboutSetting", { title })}
            className="grid size-4 place-items-center rounded-full border border-white/[0.14] text-[10px] font-semibold text-[var(--text-faint)] hover:border-[var(--accent-2)] hover:text-white"
          >
            i
          </button>
        </Tooltip>
      </div>
      <button
        type="button"
        role="switch"
        aria-checked={checked}
        aria-label={title}
        onClick={() => onChange(!checked)}
        className="relative h-[22px] w-[38px] shrink-0 rounded-full bg-white/20 transition-colors aria-checked:bg-[var(--ok,#5fd39b)]"
      >
        <span
          className={`absolute left-[3px] top-[3px] size-4 rounded-full bg-white transition-transform ${
            checked ? "translate-x-4" : ""
          }`}
        />
      </button>
    </div>
  );
}

/** 刮削覆盖的摘要："已覆盖 3 项 · 元数据 · 命名与整理"；键按前缀归到设置页的四个分区。 */
function scrapeOverrideSummary(overrides: Record<string, unknown>): string | null {
  const t = appTranslator();
  const keys = Object.keys(overrides);
  if (keys.length === 0) return null;
  const groups = new Set<string>();
  for (const key of keys) {
    if (key.startsWith("naming_")) groups.add(t("library.form.naming"));
    else if (key.startsWith("mirror_")) groups.add(t("library.form.folderWrites"));
    else if (/^(poster|backdrop|still)_/.test(key)) groups.add(t("library.form.images"));
    else groups.add(t("library.form.metadata"));
  }
  return t("library.form.overrideSummary", { count: keys.length, groups: [...groups].join(" · ") });
}

function EditLibraryDialog({
  library,
  onClose,
  onSaved,
}: {
  library: MediaLibrary;
  onClose: () => void;
  onSaved: (saved: MediaLibrary) => void;
}) {
  const t = useTranslations();
  const locale = useLocale();
  const scraped = library.capabilities.scraped;
  // 图片库：条目只看不播，缩略图从原图缩放而来（不是抓帧），开关文案随之换
  const playable = library.capabilities.playable;
  const parsed = parseMatchRules(library.match_rules);
  const [name, setName] = useState(library.name);
  const [roots, setRoots] = useState<string[]>(library.root_paths);
  const [pickerTarget, setPickerTarget] = useState<"add" | number | null>(null);
  // 老服务器没有 cloud_folders：不显示、也不提交（不传 = 不改动）
  const cloudKnown = Array.isArray(library.cloud_folders);
  const [cloud, setCloud] = useState<CloudRootDraft[]>(cloudDraftsOf(library.cloud_folders));
  const [drivePicker, setDrivePicker] = useState(false);
  const driveOptions = useDriveRootOptions(cloudKnown && playable);
  const [keepLocal, setKeepLocal] = useState(library.keep_local ?? false);
  const removedCloudFiles = (library.cloud_folders ?? [])
    .filter((f) => !cloud.some((c) => c.account_id === f.account_id && c.remote_dir_id === f.remote_dir_id))
    .reduce((sum, f) => sum + f.file_count, 0);
  const [realtimeWatch, setRealtimeWatch] = useState(library.realtime_watch);
  const [autoClearMissing, setAutoClearMissing] = useState(library.auto_clear_missing);
  const [generateThumbnails, setGenerateThumbnails] = useState(library.generate_thumbnails);
  const [extractChapterImages, setExtractChapterImages] = useState(
    library.extract_chapter_images,
  );
  const [detectMediaSegments, setDetectMediaSegments] = useState(library.detect_media_segments);
  const [excludeFromHome, setExcludeFromHome] = useState(library.exclude_from_home);
  const [autoSeriesCollections, setAutoSeriesCollections] = useState(
    library.auto_series_collections,
  );
  const [accessMode, setAccessMode] = useState<LibraryAccessMode>(library.access_mode);
  const [adminVisible, setAdminVisible] = useState(library.admin_visible);
  const [memberIds, setMemberIds] = useState<number[]>(library.member_ids);
  const [regions, setRegions] = useState<string[]>(parsed.regions);
  const [genres, setGenres] = useState<number[]>(parsed.genres);
  const [scrapeOverrides, setScrapeOverrides] = useState<Record<string, unknown>>({
    ...(library.scrape_overrides ?? {}),
  });
  // 封面上传即生效，不进 payload；这里只跟着摘要行走
  const [customCover, setCustomCover] = useState(library.custom_cover);
  // 展开的分区（同时只开一个）；默认全收起——摘要行已经把现状说清
  const [open, setOpen] = useState<EditSectionId | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const routingOptions = useRoutingOptions();

  const ready = name.trim().length > 0 && roots.length > 0;
  const missing = [name.trim() ? null : t("library.form.name"), roots.length > 0 ? null : t("library.form.roots")].filter(
    (v): v is string => v !== null,
  );
  const scope = scopeSummary(library.kind, regions, genres, routingOptions);
  const scrapeText = scrapeOverrideSummary(scrapeOverrides);
  const { label: kindLabel, Icon: KindIcon } = libraryKindMeta(locale)[library.kind];

  const submit = () => {
    if (!ready || busy) return;
    setBusy(true);
    setError(null);
    const payload: LibraryPayload = {
      name: name.trim(),
      kind: library.kind,
      root_paths: roots,
      match_rules: scraped ? buildMatchRules(validGenres(library.kind, genres, routingOptions), regions) : [],
      auto_clear_missing: autoClearMissing,
      realtime_watch: realtimeWatch,
      generate_thumbnails: generateThumbnails,
      extract_chapter_images: extractChapterImages,
      detect_media_segments: detectMediaSegments,
      exclude_from_home: excludeFromHome,
      auto_series_collections: autoSeriesCollections,
      scrape_overrides: scraped ? scrapeOverrides : {},
      access_mode: accessMode,
      admin_visible: adminVisible,
      member_ids: memberIds,
      ...(cloudKnown && playable ? { cloud_folders: cloudPayload(cloud) } : {}),
      ...(library.keep_local !== undefined ? { keep_local: keepLocal } : {}),
    };
    void updateLibrary(library.id, payload)
      .then(onSaved)
      .catch((e) => setError((e as Error).message))
      .finally(() => setBusy(false));
  };

  const dot = (on: boolean, text: string) => (
    <span key={text} className="inline-flex items-center gap-1.5">
      <span className={`size-1.5 rounded-full ${on ? "bg-[var(--ok,#5fd39b)]" : "bg-white/25"}`} />
      {text}
    </span>
  );

  const sections: { id: EditSectionId; title: string; summary: React.ReactNode; body: React.ReactNode }[] = [
    {
      id: "basic",
      title: t("library.form.basic"),
      summary: (
        <>
          <span className="text-[var(--text)]">{name.trim() || t("library.form.unnamed")}</span>
          <span dir="rtl" className="min-w-0 truncate font-mono text-[var(--text-faint)]">
            {roots[0] ? "‎" + roots[0] + "‎" : t("library.form.noRoot")}
          </span>
          {roots.length > 1 && <span className="text-[var(--text-faint)]">{t("library.form.rootCount", { count: roots.length })}</span>}
          {cloud.length > 0 && <span className="text-[var(--text-faint)]">{t("library.form.cloudRootCount", { count: cloud.length })}</span>}
        </>
      ),
      body: (
        <>
          <div>
            <label className={LABEL_CLASS}>{t("library.form.name")}</label>
            <input
              type="text"
              value={name}
              onChange={(e) => setName(e.target.value)}
              autoComplete="off"
              className={INPUT_CLASS}
            />
          </div>
          <div>
            <label className={LABEL_CLASS}>
              {t("library.form.roots")}<span className="font-normal text-[var(--text-faint)]">{t("library.form.primaryNote")}</span>
            </label>
            <RootsEditor
              roots={roots}
              onChange={setRoots}
              onPick={setPickerTarget}
              cloudPrimary={cloudKnown && playable && cloud.some((c) => c.is_primary)}
              onLocalPrimary={() => setCloud(cloud.map((c) => ({ ...c, is_primary: false })))}
              cloud={
                cloudKnown &&
                playable && (
                  <CloudRootRows
                    drafts={cloud}
                    onChange={setCloud}
                    onAdd={() => setDrivePicker(true)}
                    options={driveOptions}
                    needsLocal={roots.length === 0}
                  />
                )
              }
            />
            {cloudKnown && playable && cloud.some((c) => c.is_primary) && library.keep_local !== undefined && (
              <div className="mt-2">
                <SwitchRow
                  title={t("library.form.keepLocal")}
                  checked={keepLocal}
                  onChange={setKeepLocal}
                  detail={t("library.form.keepLocalHint")}
                />
              </div>
            )}
            {removedCloudFiles > 0 && (
              <p className="mt-2 rounded-lg border border-[var(--warn)]/30 bg-[var(--warn)]/[0.07] px-3 py-2 text-caption leading-5 text-[var(--text-muted)]">
                {t("library.form.removedCloudFiles", { count: removedCloudFiles })}
              </p>
            )}
          </div>
        </>
      ),
    },
    {
      id: "cover",
      title: t("library.form.cover"),
      summary: (
        <span className="text-[var(--text-muted)]">
          {customCover ? t("library.form.customCover") : t("library.form.autoCover")}
        </span>
      ),
      body: <CoverEditor libraryId={library.id} custom={customCover} onChange={setCustomCover} />,
    },
    {
      id: "scan",
      title: t("library.form.scanning"),
      summary: (
        <>
          {dot(realtimeWatch, t("library.form.monitoring"))}
          {dot(autoClearMissing, t("library.form.autoClearMissing"))}
          {dot(
            generateThumbnails,
            scraped ? t("library.form.fillMissingImages") : playable ? t("library.form.frameCovers") : t("library.form.thumbnails"),
          )}
          {playable && dot(extractChapterImages, t("library.form.chapters"))}
          {library.kind === "tv" && dot(detectMediaSegments, t("library.form.introCredits"))}
          {dot(!excludeFromHome, t("library.form.homeDisplay"))}
          {library.kind !== "photo" && dot(autoSeriesCollections, t("library.form.seriesCollections"))}
        </>
      ),
      body: (
        <div>
          <SwitchRow
            title={t("library.form.watchChanges")}
            checked={realtimeWatch}
            onChange={setRealtimeWatch}
            detail={
              library.network_mount
                ? t("library.form.networkWatchHint")
                : t("library.form.watchHint")
            }
          />
          <SwitchRow
            title={t("library.form.clearMissingAfterScan")}
            checked={autoClearMissing}
            onChange={setAutoClearMissing}
            detail={t("library.form.clearMissingHint")}
          />
          <SwitchRow
            title={
              scraped
                ? t("library.form.frameFallback")
                : playable
                  ? t("library.form.generateCovers")
                  : t("library.form.generateThumbs")
            }
            checked={generateThumbnails}
            onChange={setGenerateThumbnails}
            detail={
              scraped
                ? t("library.form.scrapedFrameHint")
                : playable
                  ? t("library.form.localFrameHint")
                  : t("library.form.thumbnailHint")
            }
          />
          {/* 章节是视频的事：图片库（不可播）没有这一项 */}
          {playable && (
            <SwitchRow
              title={t("library.status.generateChapters")}
              checked={extractChapterImages}
              onChange={setExtractChapterImages}
              detail={t("library.form.chaptersHint")}
            />
          )}
          {/* 片头片尾靠同一季多集互相比对认出来：只有剧集库有这一项 */}
          {library.kind === "tv" && (
            <SwitchRow
              title={t("library.form.detectIntros")}
              checked={detectMediaSegments}
              onChange={setDetectMediaSegments}
              detail={t("library.form.introsHint")}
            />
          )}
          <SwitchRow
            title={t("library.actions.showHome")}
            checked={!excludeFromHome}
            onChange={(next) => setExcludeFromHome(!next)}
            detail={t("library.form.homeDisplayHint")}
          />
          {/* 系列是"作品的属性"：影视库来自 TMDB，其他库来自视频旁 NFO 的 <set>；照片没有系列 */}
          {library.kind !== "photo" && (
            <SwitchRow
              title={t("library.form.autoCollections")}
              checked={autoSeriesCollections}
              onChange={setAutoSeriesCollections}
              detail={
                scraped
                  ? t("library.form.tmdbCollectionsHint")
                  : t("library.form.localCollectionsHint", { tag: "<set>" })
              }
            />
          )}
        </div>
      ),
    },
  ];
  if (scraped) {
    sections.push(
      {
        id: "scope",
        title: t("library.form.scope"),
        summary: scope.declared ? (
          <span className="text-[var(--text)]">{scope.text}</span>
        ) : (
          <span className="text-[var(--text-faint)]">{t("library.form.unsetScopeHint")}</span>
        ),
        body: (
          <>
            <p className="text-caption leading-relaxed text-[var(--text-faint)]">
              {t("library.form.scopeEditHint")}
            </p>
            <ScopeEditor
              kind={library.kind}
              regions={regions}
              genres={genres}
              onRegions={setRegions}
              onGenres={setGenres}
              options={routingOptions}
            />
          </>
        ),
      },
      {
        id: "scrape",
        title: t("library.form.metadataSettings"),
        summary: scrapeText ? (
          <span className="text-[var(--text)]">{scrapeText}</span>
        ) : (
          <span className="text-[var(--text-faint)]">{t("library.form.followGlobal")}</span>
        ),
        body: <LibraryScrapeSettings overrides={scrapeOverrides} onChange={setScrapeOverrides} />,
      },
    );
  }
  // 可见范围放最后：它决定的是「谁能看」，与库怎么扫、收什么无关，排在配置项之后
  sections.push({
    id: "access",
    title: t("library.form.accessScope"),
    summary: (
      <span className={accessMode === "everyone" ? "text-[var(--text)]" : "text-[var(--warn)]"}>
        {accessScopeSummary(accessMode, adminVisible, memberIds.length)}
      </span>
    ),
    body: (
      <AccessScopeEditor
        mode={accessMode}
        adminVisible={adminVisible}
        memberIds={memberIds}
        onMode={setAccessMode}
        onAdminVisible={setAdminVisible}
        onMemberIds={setMemberIds}
      />
    ),
  });

  return (
    <>
      <Modal open onClose={onClose} label={t("library.form.editTitle", { name: library.name })} width="2xl" panelClassName="flex max-h-[86dvh] flex-col">
        <div className="shrink-0 border-b border-white/[0.06] px-6 pb-4 pt-5 max-md:px-5">
          <div className="flex flex-wrap items-center gap-2.5">
            <h2 className="text-title font-bold text-white">{t("library.form.editTitle", { name: library.name })}</h2>
            {/* 类型创建后不可改：只读展示，不再摆一排灰按钮 */}
            <span className="inline-flex items-center gap-1.5 rounded-full border border-white/[0.08] bg-white/[0.04] py-0.5 pl-1.5 pr-2.5 text-caption text-[var(--text-muted)]">
              <KindIcon className="size-3.5 text-[var(--accent)]" />
              {kindLabel}
            </span>
          </div>
        </div>

        <div className="scroll-thin min-h-0 flex-1 space-y-2 overflow-y-auto p-6 max-md:p-5">
          {sections.map((s) => {
            const expanded = open === s.id;
            return (
              <section
                key={s.id}
                data-section={s.id}
                className="overflow-hidden rounded-[14px] border border-white/[0.08] bg-white/[0.04]"
              >
                <button
                  type="button"
                  aria-expanded={expanded}
                  onClick={() => setOpen(expanded ? null : s.id)}
                  className="grid w-full grid-cols-[6.5rem_1fr_auto] items-center gap-3.5 px-3.5 py-3 text-left transition-colors hover:bg-white/[0.075] max-md:grid-cols-[5.5rem_1fr_auto]"
                >
                  <span className="font-semibold text-white">{s.title}</span>
                  <span className="flex min-w-0 flex-wrap items-center gap-x-2.5 gap-y-1 text-caption text-[var(--text-muted)]">
                    {s.summary}
                  </span>
                  <ChevronDownIcon
                    className={`size-3.5 text-[var(--text-faint)] transition-transform ${expanded ? "rotate-180" : ""}`}
                  />
                </button>
                {expanded && (
                  <div className="space-y-4 border-t border-white/[0.06] px-3.5 pb-4 pt-3">{s.body}</div>
                )}
              </section>
            );
          })}
        </div>

        <div className="shrink-0 border-t border-white/[0.06] px-6 py-4 max-md:px-5">
          {error && (
            <p className="mb-3 rounded-lg border border-red-400/25 bg-red-500/10 px-3.5 py-2.5 text-ui leading-6 text-red-200">
              {error}
            </p>
          )}
          <div className="flex items-center justify-between gap-3">
            <p className="min-w-0 truncate text-caption text-[var(--text-faint)]">
              {missing.length > 0 ? t("library.form.missingFields", { fields: formatList(missing) }) : t("library.form.typeFixed")}
            </p>
            <div className="flex shrink-0 items-center gap-3">
              <button type="button" onClick={onClose} className="btn-glass h-9 px-4 text-ui font-medium">
                {t("common.cancel")}
              </button>
              <button
                type="button"
                onClick={submit}
                disabled={!ready || busy}
                className="btn-accent h-9 rounded-full px-5 text-ui font-semibold disabled:opacity-40"
              >
                {busy ? t("library.form.saving") : t("common.save")}
              </button>
            </div>
          </div>
        </div>
      </Modal>
      <RootsPicker target={pickerTarget} roots={roots} onChange={setRoots} onClose={() => setPickerTarget(null)} />
      {drivePicker && (
        <DriveFolderPicker
          accounts={driveOptions.accounts}
          libraryId={library.id}
          taken={cloud.map((c) => ({ account_id: c.account_id, path: c.display_path }))}
          onClose={() => setDrivePicker(false)}
          onSelect={(picked) => {
            setCloud([...cloud, draftOf(picked)]);
            setDrivePicker(false);
          }}
        />
      )}
    </>
  );
}
