"use client";

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
import { EXTENSION_ZIP_URL, useExtensionInstalled } from "@/lib/extension-install";
import {
  type SyncTokenView,
  generateSyncToken,
  getSyncToken,
  revokeSyncToken,
} from "@/lib/api/extension";
import { formatDateTime } from "@/lib/time";

/**
 * 浏览器插件小节：嵌在「资源站点」分区底部（插件是站点 Cookie 同步的配套工具，
 * 不单设分区）。两行：
 * - 插件本身：安装状态 + 「安装插件」——Chrome 政策不允许商店外插件一键
 *   静默安装，必须手动加载，四步指引收在弹窗里讲清楚，不平铺占版面；
 * - 同步令牌：设完即用、极少回访的配置，收进弹窗里管理。
 * 各站点的同步与验证状态直接看上方站点列表，不在这里重复展示。
 */
export function ExtensionCard() {
  const { installed } = useExtensionInstalled();
  const [tokenOpen, setTokenOpen] = useState(false);
  const [installOpen, setInstallOpen] = useState(false);

  const badge =
    installed === null
      ? { label: "检测中…", color: "#c0c4cc" }
      : installed
        ? { label: "已安装", color: "var(--ok)" }
        : { label: "未检测到", color: "#c0c4cc" };

  return (
    <SettingsSection
      title="浏览器插件"
      description="在站点页面一键读取登录 Cookie（含 httpOnly）并同步到本服务，免去手动复制粘贴，还能随 Cookie 变化自动保持最新。"
    >
      <SettingsList>
        <SettingsRow
          leading={
            <span className="icon-chip size-9 shrink-0 !rounded-xl">
              <PuzzleIcon className="size-[18px]" />
            </span>
          }
          label="MovieClaw 浏览器插件"
          description={
            installed
              ? "打开站点页面，点浏览器工具栏的 MovieClaw 图标即可同步；首次使用先生成同步令牌填入插件。"
              : "支持 Chrome / Edge 等 Chromium 内核浏览器。"
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
              安装插件
            </button>
          )}
        </SettingsRow>
        <SettingsRow
          label="同步令牌"
          description="在插件的设置里填入此令牌，即可把站点 Cookie 同步到本服务。"
        >
          <button
            type="button"
            onClick={() => setTokenOpen(true)}
            className={`${SETTINGS_BUTTON_CLASS} flex items-center gap-1.5`}
          >
            <ShieldIcon className="size-4" />
            管理
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
 * 安装指引弹窗：四步明确操作。Chrome 政策不允许商店外插件静默安装，
 * 下载后须在 chrome://extensions 手动加载——步骤只在用户点「安装插件」
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
  const steps: { text: React.ReactNode; action?: React.ReactNode }[] = [
    {
      text: (
        <>
          下载插件包并解压，得到{" "}
          <code className="rounded bg-white/[0.06] px-1 font-mono text-sub">chrome-mv3</code>{" "}
          文件夹。
        </>
      ),
      action: (
        <a
          href={EXTENSION_ZIP_URL}
          download
          className={`${SETTINGS_PRIMARY_BUTTON_CLASS} flex w-fit items-center gap-1.5`}
        >
          <DownloadIcon className="size-4" />
          下载插件包
        </a>
      ),
    },
    {
      text: (
        <>
          浏览器地址栏打开{" "}
          <code className="rounded bg-white/[0.06] px-1 font-mono text-sub">
            chrome://extensions
          </code>
          ，右上角开启「开发者模式」。
        </>
      ),
    },
    {
      text: <>点「加载已解压的扩展程序」，选择第 1 步解压出的文件夹。</>,
    },
    {
      text: <>生成同步令牌并填入插件设置，之后切回本页会自动识别为「已安装」。</>,
      action: (
        <button
          type="button"
          onClick={onOpenToken}
          className={`${SETTINGS_BUTTON_CLASS} flex w-fit items-center gap-1.5`}
        >
          <ShieldIcon className="size-4" />
          去生成令牌
        </button>
      ),
    },
  ];

  return (
    <Modal open={open} onClose={onClose} label="安装浏览器插件" width="lg">
      <div className="space-y-4 p-6">
        <div>
          <h2 className="text-title font-bold text-[var(--text)]">安装浏览器插件</h2>
          <p className="mt-1 text-sub leading-5 text-[var(--text-muted)]">
            按下面四步操作，全程约一分钟。Chrome 应用商店政策不允许商店外插件一键安装，
            所以需要手动加载一次，之后升级会自动提示。
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

        <div className="flex items-center justify-between gap-3 pt-1">
          <p className="text-caption text-[var(--text-faint)]">
            支持 Chrome / Edge 等 Chromium 内核浏览器；安装检测同样仅对 Chromium 生效。
          </p>
          <button type="button" onClick={onClose} className={SETTINGS_BUTTON_CLASS}>
            完成
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
        title: "重新生成同步令牌？",
        description: "重新生成将使旧令牌立即失效，已配置的插件需要更新令牌。",
        confirmLabel: "重新生成",
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
        title: "关闭 Cookie 同步？",
        description: "关闭同步将撤销令牌，所有插件都将无法再同步。",
        confirmLabel: "关闭同步",
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
    <Modal open={open} onClose={onClose} label="同步令牌" width="lg">
      <div className="space-y-4 p-6">
        <div className="flex items-start justify-between gap-4">
          <div>
            <h2 className="text-title font-bold text-[var(--text)]">同步令牌</h2>
            <p className="mt-1 text-sub leading-5 text-[var(--text-muted)]">
              在浏览器插件的设置里填入此令牌，即可把站点 Cookie 同步到本服务。令牌长期有效，除非你重新生成。
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
            尚未启用同步。点击下方「生成令牌」创建一个。
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
              关闭同步
            </button>
          )}
          <button type="button" onClick={onClose} className={`${SETTINGS_BUTTON_CLASS} ml-auto`}>
            完成
          </button>
          <button
            type="button"
            onClick={onGenerate}
            disabled={busy || loading}
            className={SETTINGS_PRIMARY_BUTTON_CLASS}
          >
            {token?.enabled ? "重新生成" : "生成令牌"}
          </button>
        </div>
      </div>
    </Modal>
  );
}

function StatusDot({ on }: { on: boolean }) {
  return (
    <span className="flex shrink-0 items-center gap-1.5 text-sub text-[var(--text-muted)]">
      <span
        className="size-2 rounded-full"
        style={{ background: on ? "var(--ok)" : "#c0c4cc" }}
      />
      {on ? "已启用" : "未启用"}
    </span>
  );
}

function TokenRow({ token, createdAt }: { token: string; createdAt: string | null }) {
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
          {revealed ? "隐藏" : "显示"}
        </button>
        <button
          type="button"
          onClick={copy}
          aria-label="复制令牌"
          className="btn-glass shrink-0 px-2 py-1 text-sub font-medium"
        >
          {copied ? <CheckIcon className="size-4 text-[var(--ok)]" /> : <CopyIcon className="size-4" />}
        </button>
      </div>
      {createdAt && (
        <p className="mt-1.5 text-caption text-[var(--text-faint)]">
          生成于 {formatDateTime(createdAt)}
        </p>
      )}
    </div>
  );
}
