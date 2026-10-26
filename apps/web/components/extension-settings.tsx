"use client";

import { useLocale, useTranslations } from "next-intl";
import type { AppLocale } from "@/lib/i18n/negotiate";

import { useCallback, useEffect, useState } from "react";

import { ErrorBanner } from "@/components/cloud-push-ui";
import { useConfirm } from "@/components/feedback";
import { CheckIcon, CopyIcon, DownloadIcon, PuzzleIcon, ShieldIcon } from "@/components/icons";
import { Modal } from "@/components/modal";
import {
  SETTINGS_BUTTON_CLASS,
  SETTINGS_DANGER_BUTTON_CLASS,
  SETTINGS_PRIMARY_BUTTON_CLASS,
  SettingsList,
  SettingsRow,
  SettingsSection,
} from "@/components/settings-ui";
import {
  EXTENSION_FIREFOX_ZIP_URL,
  EXTENSION_ZIP_URL,
  useExtensionInstalled,
} from "@/lib/extension-install";
import {
  type SyncTokenView,
  generateSyncToken,
  getSyncToken,
  revokeSyncToken,
} from "@/lib/api/extension";
import { formatDateTime } from "@/lib/time";

/**
 * 浏览器扩展小节：嵌在「资源站点」分区底部（扩展是站点 Cookie 同步的配套工具，
 * 不单设分区）。两行：
 * - 扩展本身：安装状态 + 「安装扩展」——Chrome 政策不允许商店外扩展一键
 *   静默安装，必须手动加载，四步指引收在弹窗里讲清楚，不平铺占版面；
 * - 同步令牌：设完即用、极少回访的配置，收进弹窗里管理。
 * 各站点的同步与验证状态直接看上方站点列表，不在这里重复展示。
 */
export function ExtensionCard() {
  const locale = useLocale();
  const t = useTranslations();
  const { installed } = useExtensionInstalled();
  const [tokenOpen, setTokenOpen] = useState(false);
  const [installOpen, setInstallOpen] = useState(false);

  const badge =
    installed === null
      ? { label: t("settings.extension.detecting"), color: "#c0c4cc" }
      : installed
        ? { label: t("settings.extension.installed"), color: "var(--ok)" }
        : { label: t("settings.extension.notDetected"), color: "#c0c4cc" };

  return (
    <SettingsSection
      title={t("settings.extension.title")}
      description={t("settings.extension.intro")}
    >
      <SettingsList>
        <SettingsRow
          stackOnMobile={locale === "en"}
          leading={
            <span className="icon-chip size-9 shrink-0 !rounded-xl">
              <PuzzleIcon className="size-[18px]" />
            </span>
          }
          label={t("settings.extension.name")}
          description={
            installed
              ? t("settings.extension.installedHint")
              : t("settings.extension.browsers")
          }
        >
          <span className="flex items-center gap-1.5 text-sub text-[var(--text-muted)]">
            <span
              className={`size-2 rounded-full ${installed === null ? "animate-pulse" : ""}`}
              style={{ background: badge.color }}
            />
            {badge.label}
          </span>
          {!installed && (
            <button
              type="button"
              onClick={() => setInstallOpen(true)}
              className={`${SETTINGS_BUTTON_CLASS} flex items-center gap-1.5`}
            >
              <DownloadIcon className="size-4" />
              {t("settings.extension.install")}
            </button>
          )}
        </SettingsRow>
        <SettingsRow
          stackOnMobile={locale === "en"}
          label={t("settings.extension.token")}
          description={t("settings.extension.tokenHint")}
        >
          <button
            type="button"
            onClick={() => setTokenOpen(true)}
            className={`${SETTINGS_BUTTON_CLASS} flex items-center gap-1.5`}
          >
            <ShieldIcon className="size-4" />
            {t("settings.extension.manage")}
          </button>
        </SettingsRow>
      </SettingsList>

      <InstallModal
        open={installOpen}
        onClose={() => setInstallOpen(false)}
        onOpenToken={() => {
          setInstallOpen(false);
          setTokenOpen(true);
        }}
      />
      <TokenModal open={tokenOpen} onClose={() => setTokenOpen(false)} />
    </SettingsSection>
  );
}

/**
 * 安装指引弹窗：四步明确操作。Chrome 政策不允许商店外扩展静默安装，
 * 下载后须在 chrome://extensions 手动加载——步骤只在用户点「安装扩展」
 * 时才展开，不在卡面平铺。
 */
function InstallModal({
  open,
  onClose,
  onOpenToken,
}: {
  open: boolean;
  onClose: () => void;
  onOpenToken: () => void;
}) {
  const t = useTranslations();
  const steps: { text: React.ReactNode; action?: React.ReactNode }[] = [
    {
      text: (
        <>
          {t.rich("settings.extension.downloadStep", { folder: (chunks) => <code className="rounded bg-white/[0.06] px-1 font-mono text-sub">{chunks}</code> })}
        </>
      ),
      action: (
        <a
          href={EXTENSION_ZIP_URL}
          download
          className={`${SETTINGS_PRIMARY_BUTTON_CLASS} flex w-fit items-center gap-1.5`}
        >
          <DownloadIcon className="size-4" />
          {t("settings.extension.download")}
        </a>
      ),
    },
    {
      text: (
        <>
          {t.rich("settings.extension.extensionsStep", { address: (chunks) => <code className="rounded bg-white/[0.06] px-1 font-mono text-sub">{chunks}</code> })}
        </>
      ),
    },
    {
      text: <>{t("settings.extension.loadStep")}</>,
    },
    {
      text: <>{t("settings.extension.tokenStep")}</>,
      action: (
        <button
          type="button"
          onClick={onOpenToken}
          className={`${SETTINGS_BUTTON_CLASS} flex w-fit items-center gap-1.5`}
        >
          <ShieldIcon className="size-4" />
          {t("settings.extension.generateAction")}
        </button>
      ),
    },
  ];

  return (
    <Modal open={open} onClose={onClose} label={t("settings.extension.installTitle")} width="lg">
      <div className="space-y-4 p-6">
        <div>
          <h2 className="text-title font-bold text-[var(--text)]">{t("settings.extension.installTitle")}</h2>
          <p className="mt-1 text-sub leading-5 text-[var(--text-muted)]">
            {t("settings.extension.installHint")}
          </p>
        </div>

        <ol className="space-y-3">
          {steps.map((step, i) => (
            <li key={i} className="flex gap-3 rounded-xl bg-white/[0.03] px-4 py-3">
              <span className="flex size-6 shrink-0 items-center justify-center rounded-full bg-white/[0.08] text-sub font-semibold text-[var(--text)]">
                {i + 1}
              </span>
              <div className="min-w-0 space-y-2 pt-0.5 text-ui leading-6 text-[var(--text-muted)]">
                <p>{step.text}</p>
                {step.action}
              </div>
            </li>
          ))}
        </ol>

        <p className="text-sub leading-5 text-[var(--text-muted)]">
          {t.rich("settings.extension.firefoxHint", {
            download: (chunks) => <a href={EXTENSION_FIREFOX_ZIP_URL} download className="text-[var(--text)] underline">{chunks}</a>,
            debug: (chunks) => <code className="rounded bg-white/[0.06] px-1 font-mono text-sub">{chunks}</code>,
            setting: (chunks) => <code className="rounded bg-white/[0.06] px-1 font-mono text-sub">{chunks}</code>,
          })}
        </p>

        <div className="flex items-center justify-between gap-3 pt-1">
          <p className="text-caption text-[var(--text-faint)]">
            {t("settings.extension.detectionHint")}
          </p>
          <button type="button" onClick={onClose} className={SETTINGS_BUTTON_CLASS}>
            {t("settings.extension.done")}
          </button>
        </div>
      </div>
    </Modal>
  );
}

/* —— 子组件 —— */

/**
 * 同步令牌管理弹窗：打开时才拉取令牌（低频配置不随页面加载）。
 * 生成 / 查看 / 复制 / 重新生成 / 关闭同步都收在这里。
 */
function TokenModal({ open, onClose }: { open: boolean; onClose: () => void }) {
  const t = useTranslations();
  const confirm = useConfirm();
  const [token, setToken] = useState<SyncTokenView | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      setToken(await getSyncToken());
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    if (open) void load();
  }, [open, load]);

  async function onGenerate() {
    if (
      token?.enabled &&
      !(await confirm({
        title: t("settings.extension.regenerateTitle"),
        description: t("settings.extension.regenerateHint"),
        confirmLabel: t("settings.extension.regenerate"),
        tone: "danger",
      }))
    ) {
      return;
    }
    setBusy(true);
    setError(null);
    try {
      setToken(await generateSyncToken());
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  async function onRevoke() {
    if (
      !(await confirm({
        title: t("settings.extension.revokeTitle"),
        description: t("settings.extension.revokeHint"),
        confirmLabel: t("settings.extension.revoke"),
        tone: "danger",
      }))
    ) {
      return;
    }
    setBusy(true);
    setError(null);
    try {
      setToken(await revokeSyncToken());
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal open={open} onClose={onClose} label={t("settings.extension.token")} width="lg">
      <div className="space-y-4 p-6">
        <div className="flex items-start justify-between gap-4">
          <div>
            <h2 className="text-title font-bold text-[var(--text)]">{t("settings.extension.token")}</h2>
            <p className="mt-1 text-sub leading-5 text-[var(--text-muted)]">
              {t("settings.extension.tokenLongHint")}
            </p>
          </div>
          <StatusDot on={Boolean(token?.enabled)} />
        </div>

        {error && (
          <ErrorBanner>{error}</ErrorBanner>
        )}

        {loading ? (
          <div className="h-11 animate-pulse rounded-xl bg-white/[0.04]" />
        ) : token?.enabled ? (
          <TokenRow token={token.token ?? ""} createdAt={token.created_at} />
        ) : (
          <p className="rounded-xl bg-white/[0.03] px-4 py-3 text-body text-[var(--text-muted)]">
            {t("settings.extension.noToken")}
          </p>
        )}

        {/* 危险动作靠左；完成在左、提交在右 */}
        <div className="flex flex-wrap items-center gap-2 pt-1">
          {token?.enabled && (
            <button
              type="button"
              onClick={onRevoke}
              disabled={busy || loading}
              className={SETTINGS_DANGER_BUTTON_CLASS}
            >
              {t("settings.extension.revoke")}
            </button>
          )}
          <button type="button" onClick={onClose} className={`${SETTINGS_BUTTON_CLASS} ml-auto`}>
            {t("settings.extension.done")}
          </button>
          <button
            type="button"
            onClick={onGenerate}
            disabled={busy || loading}
            className={SETTINGS_PRIMARY_BUTTON_CLASS}
          >
            {token?.enabled ? t("settings.extension.regenerate") : t("settings.extension.generate")}
          </button>
        </div>
      </div>
    </Modal>
  );
}

function StatusDot({ on }: { on: boolean }) {
  const t = useTranslations();
  return (
    <span className="flex shrink-0 items-center gap-1.5 text-sub text-[var(--text-muted)]">
      <span
        className="size-2 rounded-full"
        style={{ background: on ? "var(--ok)" : "#c0c4cc" }}
      />
      {on ? t("settings.extension.enabled") : t("settings.extension.notEnabled")}
    </span>
  );
}

function TokenRow({ token, createdAt }: { token: string; createdAt: string | null }) {
  const t = useTranslations();
  const locale = useLocale() as AppLocale;
  const [revealed, setRevealed] = useState(false);
  const [copied, setCopied] = useState(false);

  async function copy() {
    try {
      await navigator.clipboard.writeText(token);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      /* 忽略：某些环境无剪贴板权限，用户可手动选择复制 */
    }
  }

  const display = revealed ? token : "•".repeat(Math.min(token.length, 28));

  return (
    <div>
      <div className="flex items-center gap-2 rounded-xl bg-white/[0.04] px-3 py-2.5">
        <code className="min-w-0 flex-1 truncate font-mono text-ui text-[var(--text)]">
          {display}
        </code>
        <button
          type="button"
          onClick={() => setRevealed((v) => !v)}
          className="btn-glass shrink-0 px-2.5 py-1 text-sub font-medium"
        >
          {revealed ? t("settings.extension.hide") : t("settings.extension.show")}
        </button>
        <button
          type="button"
          onClick={copy}
          aria-label={t("settings.extension.copy")}
          className="btn-glass shrink-0 px-2 py-1 text-sub font-medium"
        >
          {copied ? <CheckIcon className="size-4 text-[var(--ok)]" /> : <CopyIcon className="size-4" />}
        </button>
      </div>
      {createdAt && (
        <p className="mt-1.5 text-caption text-[var(--text-faint)]">
          {t("settings.extension.created", { time: formatDateTime(createdAt, locale) })}
        </p>
      )}
    </div>
  );
}
