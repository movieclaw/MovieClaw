"use client";

import { useLocale, useTranslations } from "next-intl";
import { appTranslator } from "@/lib/i18n/translate";
import type { AppLocale } from "@/lib/i18n/negotiate";
import { formatNumber } from "@/lib/i18n/format";

/**
 * 纳管报告：库挂的每个网盘目录最近一次纳管 / 复查的结果（docs/design/cloud-storage.md §4.1，
 * 样稿 mockups/cloud-storage-demo.html「纳管报告」）。从库行的「···」菜单打开。
 *
 * 只陈述事实：多少个视频、认出多少、多少要认领、跳过了什么（原盘与镜像一期不纳管）。
 */

import { Modal } from "@/components/modal";
import type { LibraryCloudFolder, MediaLibrary } from "@/lib/api/libraries";
import { formatDateTime } from "@/lib/time";

function seconds(value: number, locale: AppLocale = "zh-Hans"): string {
  const t = appTranslator(locale);
  return value < 60
    ? t("library.cloudReport.seconds", { count: Math.max(1, Math.round(value)) })
    : t("library.cloudReport.minutes", { count: Math.round(value / 60) });
}

function FolderReport({ folder, onClaim }: { folder: LibraryCloudFolder; onClaim: () => void }) {
  const t = useTranslations();
  const locale = useLocale();
  const report = folder.report;
  if (report === null) {
    return <p className="text-sub text-[var(--text-muted)]">{t("library.cloudReport.waiting")}</p>;
  }
  const skipped = [
    report.skipped.disc ? t("library.cloudReport.skipDisc", { count: report.skipped.disc }) : null,
    report.skipped.iso ? t("library.cloudReport.skipIso", { count: report.skipped.iso }) : null,
    report.skipped.extra ? t("library.cloudReport.skipExtra", { count: report.skipped.extra }) : null,
  ].filter((v): v is string => v !== null);
  const skippedTotal = (report.skipped.disc ?? 0) + (report.skipped.iso ?? 0) + (report.skipped.extra ?? 0);
  return (
    <div className="space-y-3">
      <p className="text-caption text-[var(--text-faint)]">
        {t("library.cloudReport.summary", { date: formatDateTime(report.finished_at, locale), cancelled: report.cancelled ? "yes" : "no", duration: seconds(report.seconds, locale), backend: folder.backend_title, calls: report.calls })}
      </p>
      <p className="text-title font-bold tabular-nums text-white">{t("library.cloudReport.videos", { count: report.videos })}</p>
      <div className="divide-y divide-white/[0.06] rounded-xl border border-white/[0.08] bg-white/[0.03]">
        <div className="flex items-center gap-3 px-4 py-2.5">
          <span className="text-ui text-[var(--text)]">{t("library.cloudReport.identified")}</span>
          <span className="ml-auto text-ui font-semibold tabular-nums text-white">
            {formatNumber(report.identified, undefined, locale)}
          </span>
        </div>
        <div className="flex items-center gap-3 px-4 py-2.5">
          <span className="text-ui text-[var(--text)]">{t("library.cloudReport.pending")}</span>
          {report.pending > 0 && (
            <button
              type="button"
              onClick={onClaim}
              className="text-caption text-[var(--accent)] underline-offset-4 hover:underline"
            >
              {t("library.cloudReport.claim")}
            </button>
          )}
          <span className="ml-auto text-ui font-semibold tabular-nums text-white">
            {formatNumber(report.pending, undefined, locale)}
          </span>
        </div>
        <div className="px-4 py-2.5">
          <div className="flex items-center gap-3">
            <span className="text-ui text-[var(--text)]">{t("library.cloudReport.skipped")}</span>
            <span className="ml-auto text-ui font-semibold tabular-nums text-white">{t("library.cloudReport.skippedTotal", { count: skippedTotal })}</span>
          </div>
          {skipped.length > 0 && (
            <p className="mt-1 text-caption text-[var(--text-faint)]">{skipped.join(" · ")}</p>
          )}
        </div>
      </div>
    </div>
  );
}

export function CloudImportReport({
  library,
  onClose,
  onClaim,
}: {
  library: MediaLibrary;
  onClose: () => void;
  /** 打开这个库的待处理（认领没认出来的文件） */
  onClaim: () => void;
}) {
  const t = useTranslations();
  const folders = library.cloud_folders ?? [];
  return (
    <Modal open onClose={onClose} label={t("library.cloudReport.modalLabel")} width="lg" panelClassName="flex max-h-[80dvh] flex-col">
      <div className="scroll-thin min-h-0 flex-1 space-y-6 overflow-y-auto p-6 max-md:p-5">
        <h2 className="text-title font-bold text-white">{t("library.cloudReport.title", { name: library.name })}</h2>
        {folders.map((folder) => (
          <section key={folder.id} className="space-y-2">
            <h3 className="text-body font-semibold text-white">
              <span className="text-[var(--text-muted)]">{folder.account_name} › </span>
              {folder.display_path}
            </h3>
            <FolderReport folder={folder} onClaim={onClaim} />
          </section>
        ))}
        <p className="rounded-xl border border-[var(--info)]/20 bg-[var(--info)]/[0.07] px-3.5 py-3 text-caption leading-relaxed text-[var(--text-muted)]">
          {t("library.cloudReport.hint")}
        </p>
      </div>
      <div className="flex justify-end border-t border-white/[0.06] px-6 py-4 max-md:px-5">
        <button type="button" onClick={onClose} className="btn-glass h-9 px-4 text-ui font-medium">
          {t("common.close")}
        </button>
      </div>
    </Modal>
  );
}
