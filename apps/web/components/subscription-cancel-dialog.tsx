"use client";

/**
 * 取消订阅确认弹窗（管理员）。
 *
 * 取消订阅的本义只是"不再追了"，默认什么都不删——这是产品一直以来的承诺，
 * 两个开关都保持关闭。但"这部片我不要了"往往还想让它从机器上消失，此前要
 * 分头去下载器删任务、去媒体库删文件，用户根本找不到。于是把两件事收成这里
 * 的两个显式勾选，并在勾之前就把后果与数量讲清楚：
 *
 * - 种子：连同下载目录里的数据文件一起删，**不可恢复**；有 H&R 考核风险时
 *   额外给一行警示（PT 站点的考核不该由我们替用户静默牺牲）；
 * - 媒体库文件：进回收站，保留期内可在「媒体库 → 回收站」恢复。
 *
 * 数量由后端 removal-preview 给出；预览还没回来时两个开关先禁用——没数字的
 * 勾选框等于让用户盲签。
 */

import { useEffect, useState } from "react";
import { useTranslations } from "next-intl";

import { Modal } from "@/components/modal";
import {
  SheetRow,
  SheetScaffold,
  SheetSection,
  SheetToggleRow,
  useSheetForm,
} from "@/components/sheet-scaffold";
import { formatBytes } from "@/lib/format";
import {
  getSubscriptionRemovalPreview,
  type SubscriptionRemovalOptions,
  type SubscriptionRemovalPreview,
} from "@/lib/api/subscriptions";

const CANCEL_BTN_CLS =
  "rounded-lg border border-white/10 bg-white/[0.06] px-4 py-2 text-ui text-white/80 transition hover:bg-white/[0.1]";
const DANGER_BTN_CLS =
  "rounded-lg bg-red-500/85 px-4 py-2 text-ui font-medium text-white transition hover:bg-red-500 disabled:opacity-50";

export function SubscriptionCancelDialog({
  open,
  subscriptionId,
  title,
  raised = false,
  onClose,
  onConfirm,
}: {
  open: boolean;
  subscriptionId: number;
  /** 作品名（弹窗标题与文案里出现） */
  title: string;
  /** 叠在另一个弹窗之上时置 true（订阅管理弹层里的取消订阅） */
  raised?: boolean;
  onClose: () => void;
  /** 用户确认：带上两个清理开关的最终取值 */
  onConfirm: (options: SubscriptionRemovalOptions) => Promise<void> | void;
}) {
  const t = useTranslations();
  const [preview, setPreview] = useState<SubscriptionRemovalPreview | null>(null);
  const [deleteTorrents, setDeleteTorrents] = useState(false);
  const [deleteLibraryFiles, setDeleteLibraryFiles] = useState(false);
  const [busy, setBusy] = useState(false);
  const sheetForm = useSheetForm();

  // 每次打开都重新拉预览并复位开关：上次勾过的"连媒体库一起删"绝不能
  // 在下一次取消订阅时被默认带上
  useEffect(() => {
    if (!open) return;
    setPreview(null);
    setDeleteTorrents(false);
    setDeleteLibraryFiles(false);
    let alive = true;
    getSubscriptionRemovalPreview(subscriptionId)
      .then((data) => {
        if (alive) setPreview(data);
      })
      .catch(() => {
        // 预览失败不挡住取消订阅本身：开关保持禁用，用户仍可只取消订阅
        if (alive) setPreview(null);
      });
    return () => {
      alive = false;
    };
  }, [open, subscriptionId]);

  const submit = async () => {
    setBusy(true);
    try {
      await onConfirm({ deleteTorrents, deleteLibraryFiles });
    } finally {
      setBusy(false);
    }
  };

  const torrentCount = preview?.torrent_count ?? 0;
  const fileCount = preview?.library_file_count ?? 0;
  const retention = preview?.recycle_retention_days ?? 7;
  // 两个清理开关的文案与可用性（桌面勾选框与手机开关行共用）
  const torrentToggle = {
    disabled: preview === null || torrentCount === 0,
    label:
      preview === null
        ? t("subscription.cancel.tasks")
        : torrentCount === 0
          ? t("subscription.cancel.noTasks")
          : t("subscription.cancel.taskCount", { count: torrentCount }),
    description:
      torrentCount === 0 ? undefined : t("subscription.cancel.taskWarning"),
    warning:
      deleteTorrents && (preview?.hit_and_run_count ?? 0) > 0
        ? t("subscription.cancel.hitAndRun", { count: preview?.hit_and_run_count ?? 0 })
        : undefined,
  };
  const fileToggle = {
    disabled: preview === null || fileCount === 0,
    label:
      preview === null
        ? t("subscription.cancel.files")
        : fileCount === 0
          ? t("subscription.cancel.noFiles")
          : t("subscription.cancel.fileCount", { count: fileCount, size: formatBytes(preview.library_bytes) }),
    description: fileCount === 0 ? undefined : t("subscription.cancel.retention", { count: retention }),
  };

  // 银玻璃手机端：表单弹层（对齐 iOS SubscriptionCancelSheet）——两个清理项是开关行，
  // 破坏性确认不放右上 ✓，而是末尾单独一组红色「取消订阅」行；左上 ✕ 即「先不」
  if (sheetForm) {
    return (
      <SheetScaffold
        open={open}
        onClose={busy ? () => {} : onClose}
        title={t("subscription.cancel.title")}
        label={t("subscription.cancel.label", { title })}
        closeLabel={t("subscription.cancel.notNow")}
        raised={raised}
        subtitle={t("subscription.cancel.subtitle", { title })}
      >
        <SheetSection
          footer={
            (deleteTorrents || deleteLibraryFiles) &&
            t("subscription.cancel.background")
          }
        >
          <SheetToggleRow
            danger
            checked={deleteTorrents}
            onChange={setDeleteTorrents}
            {...torrentToggle}
          />
          <SheetToggleRow
            danger
            checked={deleteLibraryFiles}
            onChange={setDeleteLibraryFiles}
            {...fileToggle}
          />
        </SheetSection>
        <SheetSection>
          <SheetRow
            destructive
            label={busy ? t("subscription.cancel.processing") : t("subscription.cancel.title")}
            disabled={busy}
            onClick={() => void submit()}
          />
        </SheetSection>
      </SheetScaffold>
    );
  }

  return (
    <Modal
      open={open}
      onClose={busy ? () => {} : onClose}
      label={t("subscription.cancel.label", { title })}
      raised={raised}
    >
      <div className="p-6 max-md:p-5">
        <h2 className="text-title-sm font-bold text-white">{t("subscription.cancel.question", { title })}</h2>
        <p className="mt-2 text-sub leading-6 text-[var(--text-muted)]">
          {t("subscription.cancel.description")}
        </p>

        <div className="mt-4 space-y-3">
          <CleanupToggle
            checked={deleteTorrents}
            disabled={torrentToggle.disabled}
            onChange={setDeleteTorrents}
            label={torrentToggle.label}
            description={torrentToggle.description}
            warning={torrentToggle.warning}
          />
          <CleanupToggle
            checked={deleteLibraryFiles}
            disabled={fileToggle.disabled}
            onChange={setDeleteLibraryFiles}
            label={fileToggle.label}
            description={fileToggle.description}
          />
        </div>

        {(deleteTorrents || deleteLibraryFiles) && (
          <p className="mt-4 rounded-lg bg-white/[0.04] px-3 py-2.5 text-xs leading-5 text-[var(--text-muted)]">
            {t("subscription.cancel.background")}
          </p>
        )}

        <div className="mt-5 flex justify-end gap-2.5">
          <button type="button" onClick={onClose} disabled={busy} className={CANCEL_BTN_CLS}>
            {t("subscription.cancel.notNow")}
          </button>
          <button type="button" onClick={submit} disabled={busy} className={DANGER_BTN_CLS}>
            {busy ? t("subscription.cancel.processing") : t("subscription.cancel.title")}
          </button>
        </div>
      </div>
    </Modal>
  );
}

/** 一个清理开关：标题 + 后果说明 +（勾上后才出现的）风险警示。 */
function CleanupToggle({
  checked,
  disabled,
  onChange,
  label,
  description,
  warning,
}: {
  checked: boolean;
  disabled: boolean;
  onChange: (value: boolean) => void;
  label: string;
  description?: string;
  warning?: string;
}) {
  return (
    <label
      className={`flex items-start gap-2.5 ${disabled ? "cursor-not-allowed opacity-45" : "cursor-pointer"}`}
    >
      <input
        type="checkbox"
        checked={checked}
        disabled={disabled}
        onChange={(e) => onChange(e.target.checked)}
        className="mt-1 size-4 shrink-0 accent-[var(--accent-2)]"
      />
      <span className="min-w-0">
        <span className="block text-sub leading-6 text-white/90">{label}</span>
        {description && (
          <span className="block text-xs leading-5 text-[var(--text-muted)]">{description}</span>
        )}
        {warning && (
          <span className="mt-1 block text-xs leading-5 text-[var(--danger)]">{warning}</span>
        )}
      </span>
    </label>
  );
}
