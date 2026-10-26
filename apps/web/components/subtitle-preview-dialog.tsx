"use client";

import { useLocale, useTranslations } from "next-intl";
import { useCallback, useEffect, useState } from "react";

import { Modal } from "@/components/modal";
import {
  type LibraryItemFile,
  type SubtitlePreview,
  type SubtitleStream,
  getSubtitlePreview,
} from "@/lib/api/libraries";
import { calibrateSubtitleTiming } from "@/lib/api/subtitle-gen";
import { usePermissions } from "@/lib/permissions";

function formatTimestamp(milliseconds: number): string {
  const totalSeconds = Math.floor(milliseconds / 1000);
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  const clock = [hours, minutes, seconds]
    .map((part) => String(part).padStart(2, "0"))
    .join(":");
  return `${clock}.${String(milliseconds % 1000).padStart(3, "0")}`;
}

/**
 * 字幕标签的原地预览弹窗。
 *
 * 对白用“时间轴 + 纯文本”呈现，不暴露 SRT 序号或 ASS 样式声明：用户点
 * 标签的目标是快速核对语言、内容和同步位置，而不是编辑原始文件。长字幕
 * 由独立滚动区承载，每行开启 content-visibility，避免一次布局数千条对白。
 */
export function SubtitlePreviewDialog({
  open,
  file,
  stream,
  track,
  label,
  onClose,
  onChanged,
}: {
  open: boolean;
  file: LibraryItemFile;
  stream: SubtitleStream;
  track: string;
  label: string;
  onClose: () => void;
  onChanged?: () => void;
}) {
  const t = useTranslations();
  const locale = useLocale();
  const [data, setData] = useState<SubtitlePreview | null>(null);
  const [error, setError] = useState<string | null>(null);
  /** 非空 = 内封轨正在后台抽取，还没有内容可显示（不是出错）。 */
  const [pending, setPending] = useState<string | null>(null);
  const [retryKey, setRetryKey] = useState(0);
  const [calibrating, setCalibrating] = useState(false);
  const [calibrationNotice, setCalibrationNotice] = useState<string | null>(null);
  // 校准走 subtitle_gen（消耗 LLM / 改写库文件），整组仅超管可用，成员不给入口
  const { isAdmin } = usePermissions();

  const retry = useCallback(() => setRetryKey((value) => value + 1), []);

  /**
   * 内封轨首次预览要 ffmpeg 通读整个容器（大文件分钟级）。后端不把请求挂住
   * 等——它回一个 pending 并转后台抽取，这里按它给的间隔重拉（issue #432）。
   * 关掉弹窗只中断轮询，后台的抽取会继续做完落缓存，下次打开秒开。
   */
  useEffect(() => {
    if (!open) return;
    const controller = new AbortController();
    let timer: number | null = null;
    let cancelled = false;
    setData(null);
    setError(null);
    setPending(null);

    const load = () => {
      getSubtitlePreview(file.id, track, controller.signal)
        .then((result) => {
          if (cancelled) return;
          if (result.pending) {
            setPending(result.pending);
            timer = window.setTimeout(load, Math.max(1000, result.retry_after_ms));
            return;
          }
          setPending(null);
          setData(result);
        })
        .catch((reason: unknown) => {
          if (cancelled || controller.signal.aborted) return;
          setPending(null);
          setError(reason instanceof Error ? reason.message : t("library.subtitlePreview.loadFailed"));
        });
    };
    load();

    return () => {
      cancelled = true;
      if (timer !== null) window.clearTimeout(timer);
      controller.abort();
    };
  }, [file.id, open, retryKey, track, t]);

  const calibrate = useCallback(async () => {
    if (!stream.external || !stream.file_name) return;
    setCalibrating(true);
    setCalibrationNotice(null);
    try {
      const result = await calibrateSubtitleTiming(file.id, stream.file_name);
      setCalibrationNotice(result.message);
      if (result.ok) {
        retry();
        onChanged?.();
      }
    } catch (reason) {
      setCalibrationNotice(
        reason instanceof Error ? reason.message : t("library.subtitlePreview.calibrateFailed"),
      );
    } finally {
      setCalibrating(false);
    }
  }, [file.id, onChanged, retry, stream.external, stream.file_name, t]);

  return (
    <Modal
      open={open}
      onClose={onClose}
      label={t("library.subtitlePreview.dialogTitle", { label })}
      width="2xl"
      panelClassName="flex max-h-[82dvh] flex-col"
    >
      <div className="flex items-start justify-between gap-4 border-b border-white/[0.08] px-6 py-4 max-md:px-5 max-md:py-3.5">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <h3 className="text-title-sm font-semibold text-[var(--text)]">{t("library.subtitlePreview.title")}</h3>
            <span className="rounded bg-white/[0.08] px-1.5 py-0.5 text-micro text-white/65">
              {stream.external ? t("player.subtitles.external") : t("player.subtitles.embedded")}
            </span>
            {data?.format && (
              <span className="rounded bg-white/[0.08] px-1.5 py-0.5 text-micro uppercase text-white/65">
                {data.format}
              </span>
            )}
          </div>
          <p className="mt-1 truncate text-sub text-[var(--text-muted)]" title={file.file_name}>
            {label} · {stream.file_name ?? file.file_name}
          </p>
        </div>
        <button
          type="button"
          onClick={onClose}
          aria-label={t("library.subtitlePreview.close")}
          className="-mr-2 -mt-1 flex size-9 shrink-0 items-center justify-center rounded-full text-xl text-white/55 transition hover:bg-white/[0.08] hover:text-white"
        >
          ×
        </button>
      </div>

      <div className="scroll-thin min-h-0 flex-1 overflow-y-auto">
        {!data && !error && (
          <div
            className="flex min-h-64 flex-col items-center justify-center gap-3 px-6 text-center"
            role="status"
          >
            <span className="size-5 animate-spin rounded-full border-2 border-white/20 border-t-white/75" />
            <p className="text-ui text-[var(--text-muted)]">
              {pending ?? (stream.external ? t("library.subtitlePreview.reading") : t("library.subtitlePreview.extracting"))}
            </p>
            {pending && (
              <p className="max-w-md text-caption leading-5 text-[var(--text-faint)]">
                {t("library.subtitlePreview.firstReadHint")}
              </p>
            )}
          </div>
        )}

        {error && (
          <div className="flex min-h-64 flex-col items-center justify-center gap-3 px-6 text-center">
            <div>
              <p className="text-ui font-semibold text-[#ffb4b4]">{t("library.subtitlePreview.unavailable")}</p>
              <p className="mt-1.5 max-w-lg text-sub leading-5 text-[var(--text-muted)]">
                {error}
              </p>
            </div>
            <button type="button" onClick={retry} className="btn-glass px-4 py-2 text-ui font-medium">
              {t("library.subtitlePreview.reload")}
            </button>
          </div>
        )}

        {data && data.cues.length === 0 && (
          <p className="px-6 py-20 text-center text-ui text-[var(--text-muted)]">
            {t("library.subtitlePreview.empty")}
          </p>
        )}

        {data && data.cues.length > 0 && (
          <ol className="divide-y divide-white/[0.06] px-2 py-2 max-md:px-0">
            {data.cues.map((cue, index) => (
              <li
                key={`${cue.start_ms}-${cue.end_ms}-${index}`}
                className="grid grid-cols-[7rem_minmax(0,1fr)] gap-4 rounded-lg px-4 py-3 [content-visibility:auto] [contain-intrinsic-size:auto_64px] hover:bg-white/[0.035] max-md:grid-cols-[6.75rem_minmax(0,1fr)] max-md:gap-2.5 max-md:px-5"
              >
                <span className="tnum flex flex-col pt-0.5 text-caption text-[var(--text-faint)]">
                  <span>{formatTimestamp(cue.start_ms)}</span>
                  <span className="text-white/30">→ {formatTimestamp(cue.end_ms)}</span>
                </span>
                <span className="selectable whitespace-pre-wrap break-words text-ui leading-6 text-white/88">
                  {cue.text}
                </span>
              </li>
            ))}
          </ol>
        )}
      </div>

      {data && (
        <div className="border-t border-white/[0.08] px-6 py-3.5 max-md:px-5">
          {calibrationNotice && (
            <p className="mb-3 rounded-lg border border-white/[0.1] bg-white/[0.035] px-3 py-2 text-sub leading-5 text-[var(--text-muted)]">
              {calibrationNotice}
            </p>
          )}
          <div className={`flex items-center justify-between gap-4 ${locale === "en" ? "max-sm:flex-wrap" : ""}`}>
            <span className="text-sub text-[var(--text-muted)]">{t("library.subtitlePreview.cues", { count: data.event_count })}</span>
            <div className="flex items-center gap-2.5">
              {isAdmin && stream.external && stream.file_name && (
                <button
                  type="button"
                  onClick={() => void calibrate()}
                  disabled={calibrating}
                  title={t("library.subtitlePreview.calibrateHint")}
                  className="btn-glass px-4 py-2 text-ui font-medium disabled:opacity-50"
                >
                  {calibrating ? t("library.subtitlePreview.calibrating") : t("library.subtitlePreview.calibrate")}
                </button>
              )}
              <button type="button" onClick={onClose} className="btn-glass px-4 py-2 text-ui font-medium">
                {t("common.done")}
              </button>
            </div>
          </div>
        </div>
      )}
    </Modal>
  );
}
