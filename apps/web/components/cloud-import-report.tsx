"use client";

/**
 * 纳管报告：库挂的每个网盘目录最近一次纳管 / 复查的结果（docs/design/cloud-storage.md §4.1，
 * 样稿 mockups/cloud-storage-demo.html「纳管报告」）。从库行的「···」菜单打开。
 *
 * 只陈述事实：多少个视频、认出多少、多少要认领、跳过了什么（原盘与镜像一期不纳管）。
 */

import { Modal } from "@/components/modal";
import type { LibraryCloudFolder, MediaLibrary } from "@/lib/api/libraries";
import { formatDateTime } from "@/lib/time";

function seconds(value: number): string {
  if (value < 60) return `${Math.max(1, Math.round(value))} 秒`;
  return `${Math.round(value / 60)} 分钟`;
}

function FolderReport({ folder, onClaim }: { folder: LibraryCloudFolder; onClaim: () => void }) {
  const report = folder.report;
  if (report === null) {
    return <p className="text-sub text-[var(--text-muted)]">还没纳管完，扫描结束后这里会有结果。</p>;
  }
  const skipped = [
    report.skipped.disc ? `原盘目录 ${report.skipped.disc} · 暂不支持` : null,
    report.skipped.iso ? `光盘镜像 ${report.skipped.iso} · 暂不支持` : null,
    report.skipped.extra ? `样片、花絮 ${report.skipped.extra}` : null,
  ].filter((v): v is string => v !== null);
  const skippedTotal = (report.skipped.disc ?? 0) + (report.skipped.iso ?? 0) + (report.skipped.extra ?? 0);
  return (
    <div className="space-y-3">
      <p className="text-caption text-[var(--text-faint)]">
        {formatDateTime(report.finished_at)} {report.cancelled ? "中途停止" : "完成"}，用时 {seconds(report.seconds)} ·
        调用 {folder.backend_title} 接口 {report.calls} 次
      </p>
      <p className="text-title font-bold tabular-nums text-white">{report.videos.toLocaleString()} 个视频文件</p>
      <div className="divide-y divide-white/[0.06] rounded-xl border border-white/[0.08] bg-white/[0.03]">
        <div className="flex items-center gap-3 px-4 py-2.5">
          <span className="text-ui text-[var(--text)]">已识别</span>
          <span className="ml-auto text-ui font-semibold tabular-nums text-white">
            {report.identified.toLocaleString()}
          </span>
        </div>
        <div className="flex items-center gap-3 px-4 py-2.5">
          <span className="text-ui text-[var(--text)]">待认领</span>
          {report.pending > 0 && (
            <button
              type="button"
              onClick={onClaim}
              className="text-caption text-[var(--accent)] underline-offset-4 hover:underline"
            >
              去认领
            </button>
          )}
          <span className="ml-auto text-ui font-semibold tabular-nums text-white">
            {report.pending.toLocaleString()}
          </span>
        </div>
        <div className="px-4 py-2.5">
          <div className="flex items-center gap-3">
            <span className="text-ui text-[var(--text)]">跳过</span>
            <span className="ml-auto text-ui font-semibold tabular-nums text-white">{skippedTotal}</span>
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
  const folders = library.cloud_folders ?? [];
  return (
    <Modal open onClose={onClose} label="纳管报告" width="lg" panelClassName="flex max-h-[80dvh] flex-col">
      <div className="scroll-thin min-h-0 flex-1 space-y-6 overflow-y-auto p-6 max-md:p-5">
        <h2 className="text-title font-bold text-white">纳管报告 · {library.name}</h2>
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
          规格（分辨率、HDR、音轨）在后台慢慢补齐，不影响现在播放；没补到的在起播时当场读取。之后在网盘里新增、移动、删除的片子会自动跟上，每周还会整体复查一次；想马上同步就点「扫描库」。
        </p>
      </div>
      <div className="flex justify-end border-t border-white/[0.06] px-6 py-4 max-md:px-5">
        <button type="button" onClick={onClose} className="btn-glass h-9 px-4 text-ui font-medium">
          关闭
        </button>
      </div>
    </Modal>
  );
}
