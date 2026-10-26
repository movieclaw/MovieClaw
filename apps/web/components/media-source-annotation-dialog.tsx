"use client";

import { useLocale, useTranslations } from "next-intl";

import { useEffect, useState } from "react";

import { Modal } from "@/components/modal";
import {
  annotateMediaSource,
  listMediaSourceAnnotationCandidates,
  type MediaSourceAnnotationCandidate,
} from "@/lib/api/libraries";
import { formatBytes } from "@/lib/format";
import {
  mediaSourceOptions,
  mediaSourceDisplayLabel,
  type AnnotatableSource,
} from "@/lib/media-source-annotation";

/**
 * 整季片源标注弹窗（docs/design/media-source-annotation.md §5.2）。
 *
 * 挂在「失败反馈的原地」：洗版报告的「无法确认」季与追踪明细的
 * 「无法确认档位」季。三段式：待标注文件名列表（用户扫一眼确认来源）→
 * 档位单选（每项写明后果，标注必须是知情选择）→ 确认。只动片源未知与
 * 既有人工标注的文件，名称解析出的已知值不被批量覆盖。
 */
export function MediaSourceAnnotationDialog({
  mediaItemId,
  seasonNumber,
  isMovie,
  raised = false,
  onClose,
  onApplied,
}: {
  mediaItemId: number;
  /** 电影传 0（后端的电影单元哨兵） */
  seasonNumber: number;
  isMovie: boolean;
  /** 嵌套在其它弹层之上时传 true（如洗版报告弹层） */
  raised?: boolean;
  onClose: () => void;
  /** 标注成功后回调（父组件负责重跑体检/刷新与 toast），message 为结果句 */
  onApplied: (message: string) => void | Promise<void>;
}) {
  const t = useTranslations();
  const locale = useLocale();
  const options = mediaSourceOptions(locale);
  const [candidates, setCandidates] = useState<MediaSourceAnnotationCandidate[] | null>(
    null,
  );
  const [picked, setPicked] = useState<AnnotatableSource | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | { key: "library.sourceAnnotation.loadFailed" | "library.sourceAnnotation.applyFailed" } | null>(null);

  useEffect(() => {
    let cancelled = false;
    listMediaSourceAnnotationCandidates(mediaItemId, seasonNumber)
      .then((rows) => {
        if (!cancelled) setCandidates(rows);
      })
      .catch(() => {
        if (!cancelled) setError({ key: "library.sourceAnnotation.loadFailed" });
      });
    return () => {
      cancelled = true;
    };
  }, [mediaItemId, seasonNumber]);

  const scopeLabel = isMovie ? t("library.sourceAnnotation.movie") : seasonNumber === 0 ? t("library.sourceAnnotation.specials") : t("library.sourceAnnotation.season", { season: seasonNumber });
  const option = options.find((o) => o.value === picked) ?? null;

  const apply = async () => {
    if (!option || !candidates?.length) return;
    setBusy(true);
    setError(null);
    try {
      const result = await annotateMediaSource(mediaItemId, seasonNumber, option.value);
      await onApplied(
        t("library.sourceAnnotation.applied", { scope: scopeLabel, count: result.files, source: option.label }),
      );
    } catch (e) {
      setError(e instanceof Error ? e.message : { key: "library.sourceAnnotation.applyFailed" });
      setBusy(false);
    }
  };

  return (
    <Modal
      open
      onClose={onClose}
      label={t("library.sourceAnnotation.modalLabel")}
      width="lg"
      raised={raised}
      panelClassName="max-h-[80dvh]"
    >
      {/* 头部常驻 */}
      <div className="border-b border-white/[0.07] px-6 pb-4 pt-6 max-md:px-5">
        <h2 className="text-title font-bold text-white">{t("library.sourceAnnotation.title", { scope: scopeLabel })}</h2>
        <p className="mt-1 text-sub leading-6 text-[var(--text-muted)]">
          {t("library.sourceAnnotation.hint")}
        </p>
      </div>

      <div className="scroll-thin min-h-0 flex-1 overflow-y-auto p-6 max-md:p-5">
        {error && (
          <p className="mt-3 rounded-lg border border-red-400/25 bg-red-500/10 px-3.5 py-2.5 text-sub leading-6 text-red-200">
            {typeof error === "string" ? error : t(error.key)}
          </p>
        )}

        {/* —— 待标注文件（扫一眼确认来源；已解析出片源的文件不在范围内）—— */}
        {candidates === null ? (
          <p className="mt-4 text-sub text-[var(--text-muted)]">{t("library.sourceAnnotation.loading")}</p>
        ) : candidates.length === 0 ? (
          <p className="mt-4 rounded-xl border border-white/[0.08] bg-white/[0.03] px-4 py-3 text-sub leading-6 text-[var(--text-muted)]">
            {t("library.sourceAnnotation.empty", { scope: scopeLabel })}
          </p>
        ) : (
          <div className="mt-4 overflow-hidden rounded-xl border border-white/[0.07] bg-white/[0.02]">
            <ul className="scroll-thin max-h-48 divide-y divide-white/[0.05] overflow-y-auto">
              {candidates.map((c) => (
                <li key={c.file_id} className={`flex items-center gap-3 px-4 py-2${locale === "en" ? " max-md:flex-wrap" : ""}`}>
                  <span className={`min-w-0 flex-1 truncate text-sub text-white/80${locale === "en" ? " max-md:basis-full" : ""}`}>
                    {c.file_name}
                  </span>
                  {c.media_source_manual && (
                    <span className="shrink-0 rounded-md bg-white/[0.07] px-1.5 py-0.5 text-caption text-[var(--text-muted)]">
                      {t("library.sourceAnnotation.current", { source: mediaSourceDisplayLabel(c.media_source, locale) ?? "" })}
                    </span>
                  )}
                  <span className="tnum shrink-0 text-caption text-[var(--text-faint)]">
                    {formatBytes(c.size_bytes)}
                  </span>
                </li>
              ))}
            </ul>
            <p className="border-t border-white/[0.06] px-4 py-2 text-caption text-[var(--text-faint)]">
              {t("library.sourceAnnotation.count", { count: candidates.length })}
            </p>
          </div>
        )}

        {/* —— 档位单选（每项写明后果）—— */}
        <div className="mt-4 space-y-1.5">
          {options.map((o) => {
            const active = o.value === picked;
            return (
              <button
                key={o.value}
                type="button"
                disabled={busy || !candidates?.length}
                aria-pressed={active}
                onClick={() => setPicked(o.value)}
                className={`flex w-full items-baseline gap-2.5 rounded-xl border px-4 py-2.5 text-left transition disabled:opacity-50 ${
                  active
                    ? o.destructive
                      ? "border-amber-300/40 bg-amber-400/[0.08]"
                      : "border-[#2dd4bf]/40 bg-[#2dd4bf]/[0.08]"
                    : "border-white/[0.08] bg-white/[0.03] hover:bg-white/[0.07]"
                }${locale === "en" ? " max-md:flex-col max-md:items-start" : ""}`}
              >
                <span
                  className={`shrink-0 text-ui font-medium ${
                    o.destructive ? "text-amber-100/90" : "text-white/90"
                  }`}
                >
                  {o.label}
                </span>
                <span className="min-w-0 flex-1 text-sub leading-5 text-[var(--text-muted)]">
                  {o.consequence}
                </span>
              </button>
            );
          })}
        </div>
      </div>

      {/* 底栏常驻：文件一多就要滚，确认按钮不能被滚出屏幕 */}
      <div className="flex justify-end gap-2 border-t border-white/[0.07] px-6 py-4 max-md:px-5">
        <button type="button" onClick={onClose} className="btn-glass h-10 px-4 text-ui font-medium">
          {t("common.cancel")}
        </button>
        <button
          type="button"
          disabled={busy || !option || !candidates?.length}
          onClick={() => void apply()}
          className="btn-accent inline-flex h-10 items-center gap-2 rounded-full px-5 text-ui font-semibold disabled:opacity-40"
        >
          {busy && (
            <span className="size-3.5 animate-spin rounded-full border-2 border-white/30 border-t-white/90" />
          )}
          {t("library.sourceAnnotation.confirm")}
        </button>
      </div>
    </Modal>
  );
}
