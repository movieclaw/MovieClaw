"use client";

import { useLocale, useTranslations } from "next-intl";
import type { AppMessageKey } from "@/lib/i18n/translate";

import { useCallback, useEffect, useMemo, useState } from "react";

import {
  ClaimConfirmPanel,
  ClaimSearchPanel,
  type ClaimSeed,
  searchSeedFromLabel,
} from "@/components/claim-panels";
import { ErrorBanner } from "@/components/cloud-push-ui";
import { DirectoryPicker } from "@/components/directory-picker";
import { useConfirm } from "@/components/feedback";
import { FolderIcon, PlusIcon } from "@/components/icons";
import { Modal } from "@/components/modal";
import { FeatureOffNotice } from "@/components/feature-off-notice";
import {
  SETTINGS_BUTTON_CLASS,
  SETTINGS_PRIMARY_BUTTON_CLASS,
  SettingsEmpty,
  SettingsMoreMenu,
  SettingsSection,
} from "@/components/settings-ui";
import { type ConfiguredDownloader, listDownloaders } from "@/lib/api/downloaders";
import {
  type ImportWatchRule,
  type IngestEntriesData,
  type IngestEntryRow,
  type IngestEntryStatus,
  claimIngestEntry,
  createImportWatchRule,
  deleteImportWatchRule,
  ignoreIngestEntry,
  listImportWatchRules,
  listIngestEntries,
  restoreIngestEntry,
  updateImportWatchRule,
} from "@/lib/api/import-watch";
import { type MediaLibrary, listLibraries } from "@/lib/api/libraries";

/** 下载器目录候选：源目录大概率就是下载器的某个目录，供表单一键填入。 */
interface DownloaderDirOption {
  /** movieclaw 视角的目录（默认保存目录或路径映射左列） */
  path: string;
  /** 来源下载器名称（chip 的 title 提示用） */
  downloaderName: string;
}

/** 从下载器配置里收集 movieclaw 视角的目录候选（去重，保持配置顺序）。 */
function collectDownloaderDirs(downloaders: ConfiguredDownloader[]): DownloaderDirOption[] {
  const seen = new Set<string>();
  const options: DownloaderDirOption[] = [];
  for (const d of downloaders) {
    const paths = [d.save_path, ...(d.path_mappings ?? []).map((m) => m.local)];
    for (const path of paths) {
      if (!path || seen.has(path)) continue;
      seen.add(path);
      options.push({ path, downloaderName: d.name });
    }
  }
  return options;
}

/**
 * 自动入库配置（设置 → 自动入库，原名「监听导入」）：媒体库之上的独立功能。
 *
 * 每条规则 = 监听一个源目录，目录里下载完成的内容（下载器确认或指纹
 * 静默 + 探测通过）自动识别并按规范命名搬进目标库主根。媒体库本身
 * 只有一套目录体系、不承载下载语义——需要"下载区 → 库"搬运的用户
 * 在这里独立配置，不需要的用户永远不会看到这个概念。
 */
export function ImportWatchSection() {
  const t = useTranslations();
  const locale = useLocale();
  const confirm = useConfirm();
  const [rules, setRules] = useState<ImportWatchRule[] | null>(null);
  const [libraries, setLibraries] = useState<MediaLibrary[]>([]);
  const [downloaderDirs, setDownloaderDirs] = useState<DownloaderDirOption[]>([]);
  const [failed, setFailed] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // 编辑态："new" = 新建 / 规则对象 = 编辑 / null = 关闭
  const [editing, setEditing] = useState<ImportWatchRule | "new" | null>(null);

  const reload = useCallback(() => {
    setFailed(false);
    Promise.all([listImportWatchRules(), listLibraries()])
      .then(([ruleRows, libs]) => {
        setRules(ruleRows);
        setLibraries(libs);
      })
      .catch(() => setFailed(true));
    // 下载器目录只是表单的快捷候选，拉取失败不影响主功能，静默降级为无候选
    void listDownloaders()
      .then((rows) => setDownloaderDirs(collectDownloaderDirs(rows)))
      .catch(() => setDownloaderDirs([]));
  }, []);

  useEffect(() => {
    reload();
  }, [reload, locale]);

  // 体检修复卡跳转（?suggest=auto&kinds=movie,tv）：自动打开新建规则弹窗并
  // 预选「自动路由」目标；多个类型排成队列，保存一条后接着预填下一条
  const [suggestKinds, setSuggestKinds] = useState<("movie" | "tv")[]>([]);
  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    if (params.get("suggest") !== "auto") return;
    const kinds = (params.get("kinds") ?? "")
      .split(",")
      .filter((k): k is "movie" | "tv" => k === "movie" || k === "tv");
    setSuggestKinds(kinds.length > 0 ? kinds : ["movie"]);
    setEditing("new");
  }, []);
  const suggestTarget = useMemo(
    () => (suggestKinds[0] ? ({ type: "auto", kind: suggestKinds[0] } as const) : null),
    [suggestKinds],
  );

  const remove = async (rule: ImportWatchRule) => {
    if (
      !(await confirm({
        title: t("settings.importWatch.removeTitle", { path: rule.source_path }),
        description: t("settings.importWatch.removeHint"),
        confirmLabel: t("settings.importWatch.delete"),
        tone: "danger",
      }))
    ) {
      return;
    }
    setError(null);
    void deleteImportWatchRule(rule.id)
      .then(reload)
      .catch((e) => setError((e as Error).message));
  };

  return (
    <div className="space-y-10">
      <FeatureOffNotice feature="ingest-watch">
        {t("settings.importWatch.disabledHint")}
      </FeatureOffNotice>
      <p className="px-1 text-ui leading-6 text-[var(--text-muted)]">
        {t.rich("settings.importWatch.intro", { strong: (chunks) => <strong className="font-medium text-white/80">{chunks}</strong> })}
      </p>

      <SettingsSection
        title={t("settings.importWatch.rules")}
        description={rules && rules.length > 0 ? t("settings.importWatch.ruleCount", { count: rules.length }) : undefined}
        action={
          rules !== null &&
          !failed && (
            <button
              type="button"
              onClick={() => setEditing("new")}
              className={`${SETTINGS_PRIMARY_BUTTON_CLASS} flex items-center gap-1 pl-3`}
            >
              <PlusIcon className="size-4" />
              {t("settings.importWatch.addRule")}
            </button>
          )
        }
      >
        <div className="space-y-3">
          {error && <ErrorBanner>{error}</ErrorBanner>}

          {failed && (
            <div className="flex items-center gap-3">
              <p className="text-ui text-[var(--text-muted)]">{t("settings.importWatch.loadFailed")}</p>
              <button type="button" onClick={reload} className={SETTINGS_BUTTON_CLASS}>
                {t("settings.importWatch.retry")}
              </button>
            </div>
          )}

          {rules !== null &&
            !failed &&
            (rules.length === 0 ? (
              <SettingsEmpty
                icon={<FolderIcon className="size-5" />}
                title={t("settings.importWatch.empty")}
                description={t("settings.importWatch.emptyHint")}
              />
            ) : (
              <div className="css-glass divide-y divide-[var(--line)] !rounded-xl">
                {rules.map((rule) => (
                  <RuleCard
                    key={rule.id}
                    rule={rule}
                    libraries={libraries}
                    onEdit={() => setEditing(rule)}
                    onRemove={() => void remove(rule)}
                    onStatsChanged={reload}
                  />
                ))}
              </div>
            ))}
        </div>
      </SettingsSection>

      <RuleFormDialog
        state={editing}
        libraries={libraries}
        downloaderDirs={downloaderDirs}
        initialTarget={suggestTarget}
        onClose={() => {
          setEditing(null);
          setSuggestKinds([]); // 用户中途关闭即放弃剩余预填队列
        }}
        onSaved={() => {
          reload();
          if (suggestKinds.length > 1) {
            // 还有下一个类型要建：弹窗保持打开，initialTarget 变化触发表单
            // 重置为下一类型的预填（如电影规则建完接着建剧集）
            setSuggestKinds((prev) => prev.slice(1));
          } else {
            setSuggestKinds([]);
            setEditing(null);
          }
        }}
      />
    </div>
  );
}

/* —— 规则卡片：头行（路径/策略/目标）+ 台账摘要行 + 可展开的条目清单 ——
   摘要行是分档结论的承载面：待处理不是错误、不进全局告警，用户在这里
   看到数字、点开清单认领或忽略。 —— */

const ENTRY_TABS: { status: IngestEntryStatus; label: AppMessageKey; tone: string }[] = [
  { status: "pending", label: "settings.importWatch.pending", tone: "text-[var(--warn)]" },
  { status: "failed", label: "settings.importWatch.failed", tone: "text-red-300" },
  { status: "imported", label: "settings.importWatch.imported", tone: "text-[var(--text-muted)]" },
  { status: "ignored", label: "settings.importWatch.ignoredStatus", tone: "text-[var(--text-muted)]" },
];

function RuleCard({
  rule,
  libraries,
  onEdit,
  onRemove,
  onStatsChanged,
}: {
  rule: ImportWatchRule;
  libraries: MediaLibrary[];
  onEdit: () => void;
  onRemove: () => void;
  /** 条目动作会改变计数（认领入库/忽略等），让父级刷新规则列表的 stats */
  onStatsChanged: () => void;
}) {
  const t = useTranslations();
  const [openTab, setOpenTab] = useState<IngestEntryStatus | null>(null);
  // 条目是电影还是剧集：指定库看库类型，auto/自定义目录看规则声明
  const kind =
    rule.library_id != null
      ? (libraries.find((l) => l.id === rule.library_id)?.kind ?? "movie")
      : (rule.kind ?? "movie");
  const stats = rule.stats ?? {};
  const total = ENTRY_TABS.reduce((sum, entryTab) => sum + (stats[entryTab.status] ?? 0), 0);

  return (
    <div className="px-4 py-3">
      <div className="flex items-center gap-3">
        <FolderIcon className="size-4 shrink-0 text-[var(--accent)]/80" />
        <div className="min-w-0 flex-1">
          <p className="truncate font-mono text-sub text-[var(--text)]" title={rule.source_path}>
            {rule.source_path}
          </p>
          <p className="mt-0.5 text-caption text-[var(--text-muted)]">
            {rule.strategy === "hardlink" ? t("settings.importWatch.hardlink") : t("settings.importWatch.copy")} → {rule.target_label}
            {!rule.process_existing && t("settings.importWatch.skipExistingBadge")}
          </p>
        </div>
        <SettingsMoreMenu
          label={t("settings.importWatch.moreActions", { path: rule.source_path })}
          items={[
            { label: t("settings.importWatch.edit"), onSelect: onEdit },
            { label: t("settings.importWatch.delete"), onSelect: onRemove, danger: true },
          ]}
        />
      </div>

      {/* 台账摘要：非零状态成为可点开的过滤标签 */}
      {total > 0 && (
        <div className="mt-2 flex flex-wrap items-center gap-1.5 border-t border-[var(--line)] pt-2">
          {ENTRY_TABS.filter((entryTab) => (stats[entryTab.status] ?? 0) > 0).map((entryTab) => (
            <button
              key={entryTab.status}
              type="button"
              onClick={() => setOpenTab((v) => (v === entryTab.status ? null : entryTab.status))}
              data-active={openTab === entryTab.status}
              className="glass-row nav-item !w-auto px-2.5 py-1 text-caption font-medium"
            >
              <span className={entryTab.tone}>
                {entryTab.status === "imported" && rule.imported_works > 0
                  ? // 「已入库」报作品数：同剧多季/多版本是一个作品，用户认知里
                    // "入库了几部剧"就是这个数；条目数与作品数不同说明有重复
                    // 版本/多季，补注条目与文件数说清实际规模
                    t("settings.importWatch.importedWorks", { count: rule.imported_works })
                    : t("settings.importWatch.statusCount", { status: t(entryTab.label), count: stats[entryTab.status] })}
                {entryTab.status === "imported" &&
                  rule.imported_files > 0 &&
                  stats.imported > rule.imported_works &&
                  t("settings.importWatch.importedDetail", { entries: stats.imported, files: rule.imported_files })}
              </span>
            </button>
          ))}
        </div>
      )}

      {openTab !== null && (
        <RuleEntriesPanel
          rule={rule}
          status={openTab}
          movie={kind === "movie"}
          onStatsChanged={onStatsChanged}
        />
      )}
    </div>
  );
}

function RuleEntriesPanel({
  rule,
  status,
  movie,
  onStatsChanged,
}: {
  rule: ImportWatchRule;
  status: IngestEntryStatus;
  movie: boolean;
  onStatsChanged: () => void;
}) {
  const t = useTranslations();
  const locale = useLocale();
  const [data, setData] = useState<IngestEntriesData | null>(null);
  const [failed, setFailed] = useState(false);

  const reload = useCallback(() => {
    setFailed(false);
    listIngestEntries(rule.id, status)
      .then(setData)
      .catch(() => setFailed(true));
  }, [rule.id, status]);
  useEffect(() => {
    reload();
  }, [reload, locale]);

  if (failed) {
    return <p className="mt-2 text-caption text-[var(--text-muted)]">{t("settings.importWatch.entriesFailed")}</p>;
  }
  if (data === null) {
    return <p className="mt-2 text-caption text-[var(--text-faint)]">{t("settings.importWatch.loading")}</p>;
  }
  if (data.entries.length === 0) {
    return <p className="mt-2 text-caption text-[var(--text-faint)]">{t("settings.importWatch.noEntries")}</p>;
  }
  return (
    <div className="mt-2 space-y-1.5">
      {status === "pending" && (
        <p className="text-caption leading-relaxed text-[var(--text-faint)]">
          {t("settings.importWatch.pendingHint")}
      </p>
      )}
      {data.entries.map((entry) => (
        <EntryRow
          key={entry.id}
          entry={entry}
          movie={movie}
          onChanged={() => {
            reload();
            onStatsChanged();
          }}
        />
      ))}
    </div>
  );
}

function EntryRow({
  entry,
  movie,
  onChanged,
}: {
  entry: IngestEntryRow;
  movie: boolean;
  onChanged: () => void;
}) {
  const t = useTranslations();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // file：电影合集里正在认领的那个视频；普通条目整条认领时为 undefined
  const [panel, setPanel] = useState<
    { view: "search"; file?: string } | { view: "confirm"; seed: ClaimSeed; file?: string } | null
  >(null);

  const act = (fn: () => Promise<unknown>) => {
    setBusy(true);
    setError(null);
    void fn()
      .then(() => {
        setPanel(null);
        onChanged();
      })
      .catch((e) => setError((e as Error).message))
      .finally(() => setBusy(false));
  };
  const searchOpen = panel?.view === "search" && panel.file === undefined;
  const actionable = entry.status === "pending" || entry.status === "failed";
  // 电影合集（issue #438）：已认出的几部已入库，剩下识别不出的视频逐个认领；
  // 整条认领会把整个合集钉成同一部片，所以此时不给条目级「认领」按钮
  const unresolved = actionable ? (entry.unresolved_files ?? []) : [];
  const toggleSearch = (file?: string) =>
    setPanel((p) => (p?.view === "search" && p.file === file ? null : { view: "search", file }));

  return (
    <div className="rounded-lg bg-white/[0.03] px-3 py-2">
      <div className="flex items-center gap-2">
        <span
          className="min-w-0 flex-1 truncate font-mono text-sub text-white/85"
          title={`${entry.name}\n${entry.message ?? ""}`}
        >
          {entry.name}
        </span>
        {actionable && unresolved.length === 0 && (
          <button
            type="button"
            disabled={busy}
            onClick={() => toggleSearch()}
            className={`shrink-0 rounded-full px-2.5 py-1 text-sub font-medium transition disabled:opacity-40 ${
              searchOpen ? "bg-white/[0.14] text-white" : "btn-glass"
            }`}
          >
            {t("settings.importWatch.claim")}
          </button>
        )}
        {/* 待处理清单是逐条过的队列：认领与忽略都是高频动作，两个都常驻 */}
        {actionable && (
          <button
            type="button"
            disabled={busy}
            onClick={() => act(() => ignoreIngestEntry(entry.id))}
            className="btn-glass shrink-0 px-2.5 py-1 text-sub font-medium disabled:opacity-40"
          >
            {t("settings.importWatch.ignore")}
          </button>
        )}
        {entry.status === "ignored" && (
          <button
            type="button"
            disabled={busy}
            onClick={() => act(() => restoreIngestEntry(entry.id))}
            className="btn-glass shrink-0 px-2.5 py-1 text-sub font-medium disabled:opacity-40"
          >
            {t("settings.importWatch.restore")}
          </button>
        )}
      </div>
      {entry.message && (
        <p className="mt-0.5 line-clamp-2 text-caption leading-relaxed text-[var(--text-faint)]">
          {entry.message}
        </p>
      )}
      {unresolved.length > 0 && (
        <ul className="mt-1.5 space-y-1">
          {unresolved.map((file) => {
            const open = panel !== null && panel.file === file;
            return (
              <li key={file} className="flex items-center gap-2">
                <span
                  className="min-w-0 flex-1 truncate font-mono text-caption text-white/70"
                  title={file}
                >
                  {file}
                </span>
                <button
                  type="button"
                  disabled={busy}
                  onClick={() => toggleSearch(file)}
                  className={`shrink-0 rounded-full px-2.5 py-0.5 text-caption font-medium transition disabled:opacity-40 ${
                    open ? "bg-white/[0.14] text-white" : "btn-glass"
                  }`}
                >
                  {t("settings.importWatch.claim")}
                </button>
              </li>
            );
          })}
        </ul>
      )}
      {error && <p className="mt-1 text-caption text-red-300">{error}</p>}

      {panel?.view === "search" && (
        <ClaimSearchPanel
          key={panel.file ?? ""}
          movie={movie}
          initialQuery={searchSeedFromLabel(
            panel.file ? (panel.file.split("/").pop() ?? panel.file).replace(/\.[^.]+$/, "") : entry.name,
          )}
          onPick={(seed) => setPanel({ view: "confirm", seed, file: panel.file })}
        />
      )}
      {panel?.view === "confirm" && (
        <ClaimConfirmPanel
          key={panel.seed.tmdbId}
          seed={panel.seed}
          movie={movie}
          fileCount={1}
          busy={busy}
          onConfirm={() => act(() => claimIngestEntry(entry.id, panel.seed.tmdbId, panel.file))}
          onCancel={() => setPanel(null)}
        />
      )}
    </div>
  );
}

/* —— 新建 / 编辑规则的弹窗（库表单同款视觉） —— */

function RuleFormDialog({
  state,
  libraries,
  downloaderDirs,
  initialTarget,
  onClose,
  onSaved,
}: {
  state: ImportWatchRule | "new" | null;
  libraries: MediaLibrary[];
  /** 下载器的本地目录候选：源目录大概率就是其中之一（或其子目录） */
  downloaderDirs: DownloaderDirOption[];
  /** 新建时的目标预选（体检修复卡跳转预填「自动路由 + 类型」；变化会重置表单） */
  initialTarget?: { type: "auto"; kind: "movie" | "tv" | "video" } | null;
  onClose: () => void;
  onSaved: () => void;
}) {
  const t = useTranslations();
  const rule = state === "new" ? null : state;
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [sourcePath, setSourcePath] = useState("");
  const [strategy, setStrategy] = useState<"hardlink" | "copy">("hardlink");
  const [processExisting, setProcessExisting] = useState(true);
  // 目标三态：指定库 /「自动路由（电影/剧集）」/ 自定义目录——最后一种
  // 识别改名后落所选目录、不进任何库（整理结果需外部流转再进库的场景）
  const [target, setTarget] = useState<
    | { type: "library"; id: number }
    | { type: "auto"; kind: "movie" | "tv" | "video" }
    | { type: "path"; path: string; kind: "movie" | "tv" | "video" }
    | null
  >(null);
  // 目录浏览弹窗当前服务的字段：源目录 / 自定义目录
  const [pickerFor, setPickerFor] = useState<"source" | "target" | null>(null);

  useEffect(() => {
    if (state === null) return;
    setError(null);
    setSourcePath(rule?.source_path ?? "");
    setStrategy(rule?.strategy ?? "hardlink");
    setProcessExisting(rule?.process_existing ?? true);
    if (rule?.library_id != null) {
      setTarget({ type: "library", id: rule.library_id });
    } else if (rule?.target_path) {
      setTarget({
        type: "path",
        path: rule.target_path,
        kind: rule.kind ?? "movie",
      });
    } else if (rule?.kind) {
      setTarget({ type: "auto", kind: rule.kind });
    } else if (initialTarget) {
      setTarget(initialTarget);
    } else {
      setTarget(libraries[0] ? { type: "library", id: libraries[0].id } : null);
    }
    setPickerFor(null);
  }, [state, rule, libraries, initialTarget]);

  if (state === null) return null;

  const canSubmit =
    !busy &&
    sourcePath.length > 0 &&
    target !== null &&
    (target.type !== "path" || target.path.length > 0);

  const submit = () => {
    if (target === null) return;
    setBusy(true);
    setError(null);
    const payload = {
      source_path: sourcePath,
      strategy,
      library_id: target.type === "library" ? target.id : null,
      kind: target.type === "library" ? null : target.kind,
      target_path: target.type === "path" ? target.path : null,
      process_existing: processExisting,
    };
    void (rule ? updateImportWatchRule(rule.id, payload) : createImportWatchRule(payload))
      .then(onSaved)
      .catch((e) => setError((e as Error).message))
      .finally(() => setBusy(false));
  };

  const labelClass = "mb-1.5 block text-sub font-medium text-[var(--text-muted)]";

  return (
    <>
      <Modal open onClose={onClose} label={rule ? t("settings.importWatch.editTitle") : t("settings.importWatch.addTitle")}>
        {/* 头部常驻 */}
        <div className="border-b border-white/[0.07] px-6 pb-4 pt-6">
          <h2 className="text-title font-bold text-white">
            {rule ? t("settings.importWatch.editTitle") : t("settings.importWatch.addTitle")}
          </h2>
        </div>

        <div className="scroll-thin min-h-0 flex-1 space-y-4 overflow-y-auto px-6 py-4">
          {error && (
            <ErrorBanner>{error}</ErrorBanner>
          )}

          <div>
            <label className={labelClass}>{t("settings.importWatch.sourceFolder")}</label>
            <button
              type="button"
              onClick={() => setPickerFor("source")}
              className="flex w-full items-center gap-2 rounded-xl border border-white/[0.08] bg-white/[0.04] px-3 py-2 text-left transition-colors hover:border-[var(--accent)]/50"
            >
              <FolderIcon className="size-4 shrink-0 text-[var(--accent)]/80" />
              {sourcePath ? (
                <span dir="rtl" className="min-w-0 flex-1 truncate font-mono text-ui text-[var(--text)]">
                  {"‎" + sourcePath + "‎"}
                </span>
              ) : (
                <span className="text-ui text-[var(--text-faint)]">{t("settings.importWatch.browseSource")}</span>
              )}
            </button>
            {/* 下载器目录快捷候选：源目录大概率就是下载器目录，点选直填；
                想用其子目录（如 watch/）点选后再「浏览」，弹窗会从该目录起步 */}
            {downloaderDirs.length > 0 && (
              <div className="mt-2">
                <p className="mb-1.5 text-caption text-[var(--text-faint)]">
                  {t("settings.importWatch.downloaderFolders")}
                </p>
                <div className="flex flex-wrap gap-1.5">
                  {downloaderDirs.map((option) => (
                    <button
                      key={option.path}
                      type="button"
                      onClick={() => setSourcePath(option.path)}
                      data-active={sourcePath === option.path}
                      title={t("settings.importWatch.downloaderFolderTitle", { path: option.path, name: option.downloaderName })}
                      className="glass-row nav-item !w-auto max-w-full gap-1.5 px-2.5 py-1.5 text-sub font-medium"
                    >
                      <FolderIcon className="size-3.5 shrink-0 text-[var(--accent)]/80" />
                      <span dir="rtl" className="min-w-0 truncate font-mono">
                        {"‎" + option.path + "‎"}
                      </span>
                    </button>
                  ))}
                </div>
              </div>
            )}
            <p className="mt-1.5 text-caption leading-relaxed text-[var(--text-faint)]">
              {t("settings.importWatch.sourceHint")}
      </p>
          </div>

          <div>
            <label className={labelClass}>{t("settings.importWatch.strategy")}</label>
            <div className="flex gap-2">
              {(
                [
                  ["hardlink", t("settings.importWatch.hardlink"), t("settings.importWatch.hardlinkHint")],
                  ["copy", t("settings.importWatch.copy"), t("settings.importWatch.copyHint")],
                ] as const
              ).map(([value, label, hint]) => (
                <button
                  key={value}
                  type="button"
                  onClick={() => setStrategy(value)}
                  data-active={strategy === value}
                  className="glass-row nav-item !w-auto px-3 py-1.5 text-sub font-medium"
                  title={hint}
                >
                  {label}
                </button>
              ))}
            </div>
            <p className="mt-1.5 text-caption leading-relaxed text-[var(--text-faint)]">
              {strategy === "hardlink"
                ? t("settings.importWatch.hardlinkCheckHint")
                : t("settings.importWatch.copyCheckHint")}
            </p>
          </div>

          <div>
            <label className={labelClass}>{t("settings.importWatch.destination")}</label>
            <div className="flex flex-wrap gap-2">
              {libraries.map((lib) => (
                <button
                  key={lib.id}
                  type="button"
                  onClick={() => setTarget({ type: "library", id: lib.id })}
                  data-active={target?.type === "library" && target.id === lib.id}
                  className="glass-row nav-item !w-auto px-3 py-1.5 text-sub font-medium"
                  title={lib.primary_root ?? undefined}
                >
                  {lib.name}
                </button>
              ))}
              {(
                [
                  ["movie", t("settings.importWatch.autoMovie"), t("settings.importWatch.autoHint")],
                  ["tv", t("settings.importWatch.autoTv"), t("settings.importWatch.autoHint")],
                  ["video", t("settings.importWatch.otherLibrary"), t("settings.importWatch.otherLibraryHint")],
                ] as const
              ).map(([k, label, hint]) => (
                <button
                  key={k}
                  type="button"
                  onClick={() => setTarget({ type: "auto", kind: k })}
                  data-active={target?.type === "auto" && target.kind === k}
                  className="glass-row nav-item !w-auto px-3 py-1.5 text-sub font-medium"
                  title={hint}
                >
                  {label}
                </button>
              ))}
              <button
                type="button"
                onClick={() =>
                  setTarget((prev) =>
                    prev?.type === "path" ? prev : { type: "path", path: "", kind: "movie" },
                  )
                }
                data-active={target?.type === "path"}
                className="glass-row nav-item !w-auto px-3 py-1.5 text-sub font-medium"
                title={t("settings.importWatch.customFolderHint")}
              >
                {t("settings.importWatch.customFolder")}
              </button>
              {libraries.length === 0 && (
                <p className="text-sub text-[var(--text-faint)]">
                  {t("settings.importWatch.noLibraries")}
                </p>
              )}
            </div>
            {target?.type === "path" && (
              <div className="mt-2 space-y-2">
                <button
                  type="button"
                  onClick={() => setPickerFor("target")}
                  className="flex w-full items-center gap-2 rounded-xl border border-white/[0.08] bg-white/[0.04] px-3 py-2 text-left transition-colors hover:border-[var(--accent)]/50"
                >
                  <FolderIcon className="size-4 shrink-0 text-[var(--accent)]/80" />
                  {target.path ? (
                    <span dir="rtl" className="min-w-0 flex-1 truncate font-mono text-ui text-[var(--text)]">
                      {"‎" + target.path + "‎"}
                    </span>
                  ) : (
                    <span className="text-ui text-[var(--text-faint)]">{t("settings.importWatch.browseDestination")}</span>
                  )}
                </button>
                <div className="flex gap-2">
                  {(
                    [
                      ["movie", t("settings.importWatch.movie"), t("settings.importWatch.kindHint")],
                      ["tv", t("settings.importWatch.tv"), t("settings.importWatch.kindHint")],
                      ["video", t("settings.importWatch.other"), t("settings.importWatch.otherKindHint")],
                    ] as const
                  ).map(([k, label, hint]) => (
                    <button
                      key={k}
                      type="button"
                      onClick={() => setTarget({ type: "path", path: target.path, kind: k })}
                      data-active={target.kind === k}
                      className="glass-row nav-item !w-auto px-3 py-1.5 text-sub font-medium"
                      title={hint}
                    >
                      {label}
                    </button>
                  ))}
                </div>
              </div>
            )}
            <p className="mt-1.5 text-caption leading-relaxed text-[var(--text-faint)]">
              {target?.type === "auto"
                ? t("settings.importWatch.autoDestinationHint")
                : target?.type === "path"
                  ? target.kind === "video"
                    ? t("settings.importWatch.customOtherHint")
                    : t("settings.importWatch.customDestinationHint")
                  : t("settings.importWatch.fixedDestinationHint")}
            </p>
          </div>

          <div>
            <label className={labelClass}>{t("settings.importWatch.existingFiles")}</label>
            <div className="flex gap-2">
              {(
                [
                  [true, t("settings.importWatch.processExisting"), t("settings.importWatch.processExistingHint")],
                  [false, t("settings.importWatch.skipExisting"), t("settings.importWatch.skipExistingHint")],
                ] as const
              ).map(([value, label, hint]) => (
                <button
                  key={String(value)}
                  type="button"
                  onClick={() => setProcessExisting(value)}
                  data-active={processExisting === value}
                  className="glass-row nav-item !w-auto px-3 py-1.5 text-sub font-medium"
                  title={hint}
                >
                  {label}
                </button>
              ))}
            </div>
            <p className="mt-1.5 text-caption leading-relaxed text-[var(--text-faint)]">
              {processExisting
                ? t("settings.importWatch.existingProcessingHint")
                : t("settings.importWatch.existingSkippingHint")}
            </p>
          </div>
        </div>

        {/* 底栏常驻：表单比屏幕长，保存按钮不能跟着内容滚出视野 */}
        <div className="flex items-center justify-end gap-3 border-t border-white/[0.07] px-6 py-4">
          <button type="button" onClick={onClose} className={SETTINGS_BUTTON_CLASS}>
            {t("settings.importWatch.cancel")}
          </button>
          <button
            type="button"
            onClick={submit}
            disabled={!canSubmit}
            className={SETTINGS_PRIMARY_BUTTON_CLASS}
          >
            {busy ? t("settings.importWatch.saving") : t("settings.importWatch.save")}
          </button>
        </div>
      </Modal>

      <DirectoryPicker
        open={pickerFor !== null}
        initialPath={
          (pickerFor === "target"
            ? target?.type === "path"
              ? target.path
              : undefined
            : sourcePath) || undefined
        }
        onClose={() => setPickerFor(null)}
        onSelect={(path) => {
          if (pickerFor === "target") {
            setTarget((prev) =>
              prev?.type === "path" ? { ...prev, path } : { type: "path", path, kind: "movie" },
            );
          } else {
            setSourcePath(path);
          }
          setPickerFor(null);
        }}
      />
    </>
  );
}
