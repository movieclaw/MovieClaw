"use client";

import { useLocale, useTranslations } from "next-intl";
import Link from "next/link";
import { useEffect, useState } from "react";

import {
  type DeleteFollowUp,
  type DeleteOption,
  getDeletePreview,
  type ItemDeletePreview,
} from "@/lib/api/libraries";
import { getJob, type JobView } from "@/lib/api/jobs";
import { formatBytes } from "@/lib/format";

/**
 * 删除影片 / 文件弹窗里的附加选项（docs/design/library-boundary.md §3）。
 *
 * 选项来自别的模块登记的删除参与方（如下载模块的「同时删除下载任务和源文件」），媒体库不认识它们：
 * 打开弹窗时取一次删除预览，按预览渲染勾选项、说明和不能勾的原因；默认一律不勾。
 * 预览取不到时不挡删除——只是这次没有附加选项。
 */

export function useDeletePreview(
  active: boolean,
  libraryId: number,
  mediaItemId: number,
  fileId?: number,
) {
  const t = useTranslations();
  const locale = useLocale();
  const [preview, setPreview] = useState<ItemDeletePreview | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    if (!active) return;
    let cancelled = false;
    setPreview(null);
    setError(null);
    getDeletePreview(libraryId, mediaItemId, fileId)
      .then((value) => {
        if (!cancelled) setPreview(value);
      })
      .catch((err: unknown) => {
        if (!cancelled) setError(err instanceof Error ? err.message : t("library.deletion.loadFailed"));
      });
    return () => {
      cancelled = true;
    };
  }, [active, libraryId, mediaItemId, fileId, locale, t]);
  return { preview, error };
}

const TONE_CLASS = {
  info: "text-white/70",
  warn: "text-[var(--warn)]",
  danger: "text-[#ff9f9f]",
} as const;

export function DeleteOptions({
  preview,
  error,
  selected,
  onToggle,
  disabled,
}: {
  preview: ItemDeletePreview | null;
  error: string | null;
  selected: ReadonlySet<string>;
  onToggle: (key: string) => void;
  disabled?: boolean;
}) {
  const t = useTranslations();
  if (error) {
    return (
      <p className="mt-3 text-caption leading-5 text-[var(--text-faint)]">
        {t("library.deletion.optionsFailed", { error })}
      </p>
    );
  }
  if (!preview) {
    return <p className="mt-3 text-caption text-[var(--text-faint)]">{t("library.deletion.checking")}</p>;
  }
  return (
    <>
      {preview.cloud && (
        <p className="mt-3 text-sub leading-6 text-white/70">
          {t.rich("library.deletion.cloudWarning", {
            backend: preview.cloud.backend_title, files: preview.cloud.files,
            size: formatBytes(preview.cloud.bytes), recycle: preview.cloud.recycle_bin ? "yes" : "no",
            count: (chunks) => <span className="tnum font-semibold">{chunks}</span>,
            bytes: (chunks) => <span className="tnum">{chunks}</span>,
          })}
        </p>
      )}
      {preview.linked_bytes > 0 && (
        <p className="mt-3 text-sub leading-6 text-white/70">
          {t.rich("library.deletion.hardlinks", { size: formatBytes(preview.linked_bytes), bytes: (chunks) => <span className="tnum font-semibold">{chunks}</span> })}
        </p>
      )}
      {preview.options.map((option) => (
        <OptionRow
          key={option.key}
          option={option}
          checked={selected.has(option.key)}
          onToggle={() => onToggle(option.key)}
          disabled={disabled}
        />
      ))}
    </>
  );
}

function OptionRow({
  option,
  checked,
  onToggle,
  disabled,
}: {
  option: DeleteOption;
  checked: boolean;
  onToggle: () => void;
  disabled?: boolean;
}) {
  const t = useTranslations();
  const usable = option.available && !disabled;
  return (
    <div className="mt-3 rounded-xl border border-white/[0.08] bg-white/[0.03] px-3.5 py-3">
      <label
        className={`flex items-start gap-2.5 text-sub leading-6 ${
          option.available ? "cursor-pointer text-[var(--text)]" : "cursor-not-allowed text-white/45"
        }`}
      >
        <input
          type="checkbox"
          checked={checked && option.available}
          disabled={!usable}
          onChange={onToggle}
          className="mt-1 size-4 accent-[#ff6b6b] disabled:opacity-40"
        />
        <span className="min-w-0">
          <span className="font-medium">{option.label}</span>
          {option.help && (
            <span className="block text-caption leading-5 text-[var(--text-faint)]">{option.help}</span>
          )}
        </span>
      </label>
      <div className="mt-1.5 space-y-0.5 pl-[26px]">
        {option.available ? (
          option.lines.map((line) => (
            <p key={line.text} className={`text-caption leading-5 ${TONE_CLASS[line.tone]}`}>
              {line.text}
            </p>
          ))
        ) : (
          <p className="text-caption leading-5 text-[var(--text-muted)]">
            {t("library.deletion.disabledReason", { reason: option.reason ?? t("library.deletion.unavailable") })}
          </p>
        )}
      </div>
    </div>
  );
}

const TERMINAL = new Set(["succeeded", "failed", "cancelled"]);

/** 结果页：勾选的选项在后台跑，当场跟进到结束 */
export function DeleteFollowUps({ items }: { items: DeleteFollowUp[] }) {
  if (items.length === 0) return null;
  return (
    <div className="mt-3 space-y-2">
      {items.map((item) => (
        <FollowUpRow key={item.job_id} item={item} />
      ))}
    </div>
  );
}

function FollowUpRow({ item }: { item: DeleteFollowUp }) {
  const t = useTranslations();
  const locale = useLocale();
  const [job, setJob] = useState<JobView | null>(null);
  useEffect(() => {
    let cancelled = false;
    let timer: number | undefined;
    const poll = () => {
      getJob(item.job_id)
        .then((value) => {
          if (cancelled) return;
          setJob(value);
          if (!TERMINAL.has(value.status)) timer = window.setTimeout(poll, 1500);
        })
        .catch(() => {
          if (!cancelled) timer = window.setTimeout(poll, 3000);
        });
    };
    poll();
    return () => {
      cancelled = true;
      window.clearTimeout(timer);
    };
  }, [item.job_id, locale]);

  const status = job?.status;
  const message =
    status === "succeeded"
      ? String(job?.result?.message ?? t("library.deletion.completed"))
      : status === "failed"
        ? t("library.deletion.failed", { reason: job?.error?.message ?? t("library.deletion.unknownReason") })
        : status === "cancelled"
          ? t("library.deletion.cancelled")
          : t("library.deletion.processing");
  const tone =
    status === "failed" ? "text-[#ff9f9f]" : status === "succeeded" ? "text-white/75" : "text-[var(--text-muted)]";
  return (
    <div className="rounded-xl border border-white/[0.08] bg-white/[0.03] px-3.5 py-2.5">
      <p className="text-sub font-medium text-[var(--text)]">{item.label}</p>
      <p className={`mt-0.5 text-caption leading-5 ${tone}`}>{message}</p>
      {status === "failed" && (
        <Link href="/activity" className="mt-1 inline-block text-caption text-[var(--accent)] hover:opacity-80">
          {t("library.deletion.retryTasks")}
        </Link>
      )}
    </div>
  );
}
