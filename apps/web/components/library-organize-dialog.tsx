"use client";

import { useLocale, useTranslations } from "next-intl";
import { useEffect, useMemo, useRef, useState } from "react";

import { CheckIcon, ChevronRightIcon, XIcon } from "@/components/icons";
import { Modal } from "@/components/modal";
import {
  type LastOrganize,
  type MediaLibrary,
  type OrganizePreview,
  type OrganizeRename,
  getLibrary,
  previewLibraryOrganize,
  startLibraryOrganize,
} from "@/lib/api/libraries";
import { formatBytes } from "@/lib/format";
import { useVisiblePolling } from "@/lib/use-visible-polling";

/**
 * 整理文件名对话框：预览 → 确认 → 执行 → 结果，四段式流程。
 *
 * 设计要点（批量改名是半不可逆操作，交互按"手术确认单"打造）：
 * - **先看后动**：打开即拉取完整预览——每个文件改成什么名、哪些跳过及
 *   原因逐条可查，绝不让用户在信息不全时按下执行；
 * - **风险前置**：做种断种 / 播放器重识别 / 无法一键撤销三条风险用醒目
 *   告知卡展示，勾选"我已了解"后执行按钮才亮起；
 * - **执行可离场**：确认后任务在后端跑，对话框轮询画进度；关掉窗口不影响
 *   整理，库卡片上的进度环继续可见；
 * - **结果可追溯**：完成页给出改名/附属/清理目录的完整账目，逐条错误
 *   （若有）原文展示——用户知道发生了什么，也知道哪些没动、为什么。
 */
export function LibraryOrganizeDialog({
  library,
  onClose,
  onChanged,
}: {
  /** 目标库；null = 关闭 */
  library: MediaLibrary | null;
  onClose: () => void;
  /** 整理结束（或启动）后通知父组件刷新库列表 */
  onChanged: () => void;
}) {
  const t = useTranslations();
  const locale = useLocale();
  type Phase = "loading" | "preview" | "running" | "done" | "failed";
  const [phase, setPhase] = useState<Phase>("loading");
  const [preview, setPreview] = useState<OrganizePreview | null>(null);
  const [result, setResult] = useState<LastOrganize | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [agreed, setAgreed] = useState(false);
  const [showSkips, setShowSkips] = useState(false);
  const [progress, setProgress] = useState<{ processed: number; total: number } | null>(null);

  const libraryId = library?.id ?? null;

  // 完成判定的两个凭据：见过 organizing=true，或 last_organize 换了新结论。
  // 只看 organizing=false 不行——POST 受理后台任务才起跑，首轮轮询可能落在
  // 起跑前的空档里，此时 last_organize 还是上一次的旧结论，直接当"完成"
  // 会拿旧结果糊弄用户
  const sawRunning = useRef(false);
  const baselineFinished = useRef<string | null>(null);

  // 打开时重置并拉取预览；库已在整理中（比如中途关过窗口）直接进执行页
  useEffect(() => {
    if (libraryId === null) return;
    setPreview(null);
    setResult(null);
    setError(null);
    setAgreed(false);
    setShowSkips(false);
    setProgress(null);
    sawRunning.current = false;
    baselineFinished.current = library?.last_organize?.finished_at ?? null;
    if (library?.organizing) {
      setPhase("running");
      return;
    }
    setPhase("loading");
    let cancelled = false;
    previewLibraryOrganize(libraryId)
      .then((p) => {
        if (cancelled) return;
        setPreview(p);
        setPhase("preview");
      })
      .catch((e) => {
        if (cancelled) return;
        setError((e as Error).message);
        setPhase("failed");
      });
    return () => {
      cancelled = true;
    };
    // library 对象随轮询变化，仅在"打开了哪个库"变化时重新初始化
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [libraryId]);

  // 执行中轮询单库详情：画进度，结束后取整理结论进结果页（页面隐藏时暂停）
  useVisiblePolling(
    () => {
      if (libraryId === null) return;
      void getLibrary(libraryId)
        .then((lib) => {
          if (lib.organizing) {
            sawRunning.current = true;
            setProgress(lib.organize_progress);
            return;
          }
          const finished = lib.last_organize?.finished_at ?? null;
          if (sawRunning.current || finished !== baselineFinished.current) {
            setProgress(lib.organize_progress);
            setResult(lib.last_organize);
            setPhase("done");
            onChanged();
          }
          // 两个凭据都没有：任务还没起跑，继续等下一轮
        })
        .catch(() => {});
    },
    phase === "running" && libraryId !== null ? 1500 : null,
  );

  // 预览按条目分组：同一部作品的文件放在一起看，比平铺清单好核对得多
  const groups = useMemo(() => {
    if (!preview) return [];
    const byItem = new Map<number, { title: string; year: number | null; actions: OrganizeRename[] }>();
    for (const action of preview.renames) {
      const group = byItem.get(action.media_item_id) ?? {
        title: action.title,
        year: action.year,
        actions: [],
      };
      group.actions.push(action);
      byItem.set(action.media_item_id, group);
    }
    return Array.from(byItem.values()).sort((a, b) => a.title.localeCompare(b.title, locale));
  }, [preview, locale]);

  if (library === null) return null;

  const start = () => {
    setError(null);
    sawRunning.current = false;
    baselineFinished.current = library.last_organize?.finished_at ?? null;
    setPhase("running");
    void startLibraryOrganize(library.id)
      .then(onChanged)
      .catch((e) => {
        setError((e as Error).message);
        setPhase("preview");
      });
  };

  const renameCount = preview?.renames.length ?? 0;
  const sidecarCount = preview?.renames.reduce((n, r) => n + r.sidecars.length, 0) ?? 0;
  // 条目目录改名时跟着搬的海报/NFO：不搬走旧目录就永远非空、清不掉
  const entryAssetCount = preview?.entry_assets.length ?? 0;
  const pct =
    progress && progress.total > 0
      ? Math.min(100, Math.round((progress.processed / progress.total) * 100))
      : null;

  return (
    <Modal
      open
      onClose={onClose}
      label={t("library.organize.dialogTitle", { name: library.name })}
      width="2xl"
      panelClassName="flex max-h-[84dvh] flex-col"
    >
        {/* —— 头部 —— */}
        <div className="flex items-start justify-between gap-3 border-b border-white/[0.08] px-6 pb-4 pt-5">
          <div className="min-w-0">
            <h2 className="text-title font-bold text-white">
              {t("library.organize.title")}
              <span className="ml-2 text-ui font-normal text-[var(--text-muted)]">
                {library.name}
              </span>
            </h2>
            <p className="mt-1 text-sub leading-5 text-[var(--text-muted)]">
              {t("library.organize.intro", { series: library.kind === "tv" ? "yes" : "no" })}
            </p>
          </div>
          <button
            type="button"
            onClick={onClose}
            aria-label={t("library.organize.closeDialog")}
            className="btn-glass flex size-8 shrink-0 items-center justify-center !rounded-full"
          >
            <XIcon className="size-4" />
          </button>
        </div>

        {/* —— 加载 / 失败 —— */}
        {phase === "loading" && (
          <div className="flex flex-col items-center gap-3 px-6 py-16">
            <span className="size-5 animate-spin rounded-full border-2 border-white/20 border-t-white/70" />
            <p className="text-ui text-[var(--text-muted)]">
              {t("library.organize.loading")}
            </p>
          </div>
        )}
        {phase === "failed" && (
          <div className="flex flex-col items-center gap-4 px-6 py-14">
            <p className="max-w-md text-center text-ui leading-6 text-red-200">{error}</p>
            <button type="button" onClick={onClose} className="btn-glass px-4 py-2 text-ui font-medium">
              {t("common.close")}
            </button>
          </div>
        )}

        {/* —— 预览 —— */}
        {phase === "preview" && preview && (
          <>
            <div className="scroll-thin min-h-0 flex-1 space-y-4 overflow-y-auto px-6 py-4">
              {/* 统计条：一眼看清这次整理的规模 */}
              <div className="flex flex-wrap gap-2">
                <StatChip
                  tone={renameCount > 0 ? "accent" : "muted"}
                  label={t("library.organize.renameCount", { count: renameCount })}
                />
                {sidecarCount > 0 && (
                  <StatChip tone="muted" label={t("library.organize.sidecarCount", { count: sidecarCount })} />
                )}
                {entryAssetCount > 0 && (
                  <StatChip tone="muted" label={t("library.organize.assetCount", { count: entryAssetCount })} />
                )}
                <StatChip tone="ok" label={t("library.organize.alreadyCount", { count: preview.already_ok })} />
                {preview.skips.length > 0 && (
                  <StatChip tone="warn" label={t("library.organize.skipCount", { count: preview.skips.length })} />
                )}
              </div>

              {renameCount === 0 ? (
                <p className="rounded-xl bg-white/[0.03] px-4 py-8 text-center text-ui leading-7 text-[var(--text-muted)]">
                  {t("library.organize.alreadyNeat")}
                  {preview.skips.length > 0 && (
                    <span className="block text-sub text-[var(--text-faint)]">
                      {t("library.organize.skippedHint", { count: preview.skips.length })}
                    </span>
                  )}
                </p>
              ) : (
                <>
                  {/* 风险告知：批量改名是半不可逆操作，三条风险必须看到 */}
                  <div className="rounded-xl border border-[var(--warn)]/30 bg-[var(--warn)]/[0.08] px-4 py-3">
                    <p className="text-sub font-semibold text-[var(--warn)]">{t("library.organize.beforeStart")}</p>
                    <ul className="mt-1.5 list-disc space-y-1 pl-4 text-sub leading-5 text-[var(--warn)]/85">
                      <li>
                        {t.rich("library.organize.noUndo", { em: (chunks) => <strong>{chunks}</strong> })}
                      </li>
                      <li>
                        {t.rich("library.organize.seedingHint", { em: (chunks) => <strong>{chunks}</strong> })}
                      </li>
                      <li>
                        {t("library.organize.playerHint")}
                      </li>
                    </ul>
                  </div>

                  {/* 改名清单：按作品分组，旧名 → 新名逐条可核对 */}
                  <div className="space-y-3">
                    {groups.map((group) => (
                      <div key={`${group.title}-${group.year}`} className="rounded-xl bg-white/[0.03]">
                        <p className="border-b border-white/[0.06] px-3.5 py-2 text-sub font-semibold text-white/85">
                          {group.title}
                          {group.year ? ` (${group.year})` : ""}
                          <span className="ml-2 font-normal text-[var(--text-faint)]">
                            {t("library.organize.fileCount", { count: group.actions.length })}
                          </span>
                        </p>
                        <div className="divide-y divide-white/[0.04] px-3.5">
                          {group.actions.map((action) => (
                            <div key={action.file_id} className="py-2">
                              <p
                                className="truncate font-mono text-caption text-[var(--text-faint)] line-through decoration-white/25"
                                title={action.source_path}
                              >
                                {action.source_rel}
                              </p>
                              <p
                                className="mt-0.5 flex items-center gap-1 font-mono text-caption text-white/90"
                                title={action.target_path}
                              >
                                <ChevronRightIcon className="size-3 shrink-0 text-[var(--accent)]" />
                                <span className="truncate">{action.target_rel}</span>
                                <span className="ml-auto shrink-0 pl-2 font-sans text-micro text-[var(--text-faint)]">
                                  {formatBytes(action.size_bytes)}
                                </span>
                              </p>
                              {action.sidecars.length > 0 && (
                                <p className="mt-0.5 pl-4 text-micro text-[var(--text-faint)]">
                                  +{t("library.organize.sidecarDetails", { count: action.sidecars.length })}
                                </p>
                              )}
                            </div>
                          ))}
                        </div>
                      </div>
                    ))}
                  </div>
                </>
              )}

              {/* 跳过清单：默认收起，展开逐条看原因——用户对"没动的"也心里有数 */}
              {preview.skips.length > 0 && (
                <div className="rounded-xl bg-white/[0.03]">
                  <button
                    type="button"
                    onClick={() => setShowSkips((v) => !v)}
                    className="flex w-full items-center gap-1.5 px-3.5 py-2.5 text-left text-sub font-medium text-[var(--text-muted)] transition hover:text-white"
                  >
                    <ChevronRightIcon
                      className={`size-3.5 transition-transform ${showSkips ? "rotate-90" : ""}`}
                    />
                    {t("library.organize.showSkips", { count: preview.skips.length })}
                  </button>
                  {showSkips && (
                    <div className="divide-y divide-white/[0.04] border-t border-white/[0.06] px-3.5">
                      {preview.skips.map((skip) => (
                        <div key={skip.file_path} className="py-2">
                          <p
                            className="truncate font-mono text-caption text-[var(--text-faint)]"
                            title={skip.file_path}
                          >
                            {skip.file_path}
                          </p>
                          <p className="mt-0.5 text-caption text-[var(--warn)]/80">{skip.reason}</p>
                        </div>
                      ))}
                    </div>
                  )}
                </div>
              )}
            </div>

            {/* —— 确认区 —— */}
            <div className="border-t border-white/[0.08] px-6 py-4">
              {error && (
                <p className="mb-3 rounded-lg border border-red-400/25 bg-red-500/10 px-3.5 py-2 text-sub text-red-200">
                  {error}
                </p>
              )}
              {renameCount > 0 ? (
                <div className="flex flex-wrap items-center justify-between gap-3">
                  <label className="flex cursor-pointer select-none items-center gap-2 text-sub text-[var(--text-muted)]">
                    <input
                      type="checkbox"
                      checked={agreed}
                      onChange={(e) => setAgreed(e.target.checked)}
                      className="size-4 accent-[var(--accent)]"
                    />
                    {t("library.organize.acknowledge")}
                  </label>
                  <div className="flex items-center gap-3">
                    <button type="button" onClick={onClose} className="btn-glass h-9 px-4 text-ui font-medium">
                      {t("common.cancel")}
                    </button>
                    <button
                      type="button"
                      disabled={!agreed}
                      onClick={start}
                      className="btn-accent h-9 rounded-full px-5 text-ui font-semibold disabled:opacity-40"
                    >
                      {t("library.organize.start", { count: renameCount })}
                    </button>
                  </div>
                </div>
              ) : (
                <div className="flex justify-end">
                  <button type="button" onClick={onClose} className="btn-glass h-9 px-4 text-ui font-medium">
                    {t("common.close")}
                  </button>
                </div>
              )}
            </div>
          </>
        )}

        {/* —— 执行中 —— */}
        {phase === "running" && (
          <div className="flex flex-col items-center gap-4 px-8 py-14">
            <div className="h-2 w-full max-w-sm overflow-hidden rounded-full bg-white/[0.08]">
              <div
                className="h-full rounded-full bg-white/85 transition-[width] duration-500 ease-out"
                style={{ width: `${pct ?? 8}%` }}
              />
            </div>
            <p className="text-ui font-medium text-white">
              {t("library.organize.progress", { known: progress && progress.total > 0 ? "yes" : "no", processed: progress?.processed ?? 0, total: progress?.total ?? 0 })}
            </p>
            <p className="text-center text-sub leading-5 text-[var(--text-muted)]">
              {t("library.organize.runningSafe")}
              <br />
              {t("library.organize.runningBackground")}
            </p>
          </div>
        )}

        {/* —— 结果 —— */}
        {phase === "done" && (
          <div className="scroll-thin min-h-0 flex-1 overflow-y-auto px-6 py-8">
            <div className="flex flex-col items-center gap-3">
              <span className="flex size-11 items-center justify-center rounded-full bg-[var(--ok)]/15">
                <CheckIcon className="size-5 text-[var(--ok)]" />
              </span>
              <p className="text-body-lg font-semibold text-white">{t("library.organize.done")}</p>
              <p className="text-center text-ui leading-6 text-[var(--text-muted)]">
                {t("library.organize.result", { renamed: result?.renamed ?? 0, sidecars: result?.sidecars_renamed ?? 0, assets: result?.entry_assets_moved ?? 0, removed: result?.removed_dirs ?? 0, skipped: result?.skipped ?? 0 })}
              </p>
              {result && result.errors.length > 0 && (
                <div className="w-full rounded-xl border border-[var(--warn)]/30 bg-[var(--warn)]/[0.08] px-4 py-3">
                  <p className="text-sub font-semibold text-[var(--warn)]">
                    {t("library.organize.errors", { count: result.errors.length })}
                  </p>
                  <ul className="mt-1.5 space-y-1 text-caption leading-5 text-[var(--warn)]/85">
                    {result.errors.map((message) => (
                      <li key={message} className="break-all">
                        {message}
                      </li>
                    ))}
                  </ul>
                </div>
              )}
              <button
                type="button"
                onClick={onClose}
                className="btn-accent mt-2 h-9 rounded-full px-6 text-ui font-semibold"
              >
                {t("common.done")}
              </button>
            </div>
          </div>
        )}
    </Modal>
  );
}

/** 统计小胶囊：预览页顶部的规模速览。 */
function StatChip({ tone, label }: { tone: "accent" | "ok" | "warn" | "muted"; label: string }) {
  const toneClass = {
    accent: "border-white/[0.18] bg-white/[0.12] text-white",
    ok: "border-[var(--ok)]/30 bg-[var(--ok)]/10 text-[var(--ok)]",
    warn: "border-[var(--warn)]/35 bg-[var(--warn)]/[0.12] text-[var(--warn)]",
    muted: "border-white/[0.1] bg-white/[0.05] text-[var(--text-muted)]",
  }[tone];
  return (
    <span className={`rounded-full border px-3 py-1 text-sub font-semibold ${toneClass}`}>
      {label}
    </span>
  );
}
