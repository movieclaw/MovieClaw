"use client";

/**
 * 连接 MovieClaw 账号的配对弹窗（docs/design/cloud-push.md §2.2、§8）。
 *
 * 流程：填服务器名称 → 服务器向云端申请配对码 → 管理员在官网核对配对码并批准 →
 * 服务器自己在后台轮询拿到凭证。浏览器这边只是看着：每 2 秒读一次 GET /cloud
 * （轮询在分区组件里，弹窗开着时加快），批准后弹窗自己变成「已连接」并收起。
 *
 * 三条约定：
 * - 关掉弹窗不取消配对：在官网批准后服务器照样会连上，只有「取消」才作废配对码；
 * - 管理员多半已经在同一个浏览器里登录过官网，主按钮直接新标签页打开带码的
 *   批准页；用手机登录官网的人扫码；
 * - 拒绝、过期、出错各说一句原因，给「重新获取配对码」，不用从头填名字。
 */

import { useEffect, useState } from "react";

import { ErrorBanner, Spinner } from "@/components/cloud-push-ui";
import { CheckIcon, XIcon } from "@/components/icons";
import { Modal } from "@/components/modal";
import {
  SETTINGS_BUTTON_CLASS,
  SETTINGS_INPUT_CLASS,
  SETTINGS_PRIMARY_BUTTON_CLASS,
} from "@/components/settings-ui";
import {
  type CloudStatusView,
  cancelCloudPairing,
  startCloudPairing,
} from "@/lib/api/cloud";
import {
  TONE_COLOR,
  connectedAccountLine,
  displayHost,
  displayUrl,
  formatCountdown,
  pairingFailureText,
  secondsLeft,
} from "@/lib/cloud-push-display";

/** 服务器名称会显示在官网的批准页上，云端限 64 个字符 */
const NAME_MAX_LENGTH = 64;

/** 批准后「已连接」停留多久再自动收起 */
const SUCCESS_CLOSE_MS = 3000;

export function CloudPairingDialog({
  status,
  run,
  onClose,
}: {
  status: CloudStatusView;
  /** 发起写操作并用响应刷新整页状态（见 cloud-section 的 run） */
  run: (action: () => Promise<CloudStatusView>) => Promise<CloudStatusView>;
  /** 必须是稳定引用：成功后的自动收起计时器依赖它 */
  onClose: () => void;
}) {
  // 打开时已经在配对中（从页面上的配对卡片重新打开）就直接看配对码，否则先填名字
  const [step, setStep] = useState<"form" | "pairing">(() =>
    status.state === "pairing" && status.pairing ? "pairing" : "form",
  );
  const [name, setName] = useState(() => status.pairing?.instance_name || status.server_name || "");
  const [busy, setBusy] = useState<"start" | "cancel" | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [now, setNow] = useState(() => Date.now());

  const connected = status.state === "connected";
  const pairing = step === "pairing" ? status.pairing : null;
  const remaining = pairing ? secondsLeft(pairing.expires_at, now) : 0;
  // 倒计时走完而服务端还没改状态时，按过期处理
  const waiting = pairing?.status === "pending" && remaining > 0;

  useEffect(() => {
    if (!waiting) return;
    const timer = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(timer);
  }, [waiting]);

  useEffect(() => {
    if (!connected) return;
    const timer = window.setTimeout(onClose, SUCCESS_CLOSE_MS);
    return () => window.clearTimeout(timer);
  }, [connected, onClose]);

  const start = async (instanceName: string) => {
    const trimmed = instanceName.trim();
    if (!trimmed) return;
    setBusy("start");
    setError(null);
    try {
      await run(() => startCloudPairing(trimmed));
      setNow(Date.now());
      setStep("pairing");
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(null);
    }
  };

  const cancel = async () => {
    setBusy("cancel");
    setError(null);
    try {
      await run(cancelCloudPairing);
      onClose();
    } catch (e) {
      setError((e as Error).message);
      setBusy(null);
    }
  };

  return (
    <Modal open onClose={onClose} label="连接到 MovieClaw 账号">
      {connected ? (
        <div className="flex flex-col items-center gap-3 px-6 py-10 text-center">
          <span
            className="flex size-12 items-center justify-center rounded-full"
            style={{
              background: `color-mix(in oklab, ${TONE_COLOR.ok} 14%, transparent)`,
              color: TONE_COLOR.ok,
            }}
          >
            <CheckIcon className="size-6" />
          </span>
          <p className="text-title font-bold text-white">已连接</p>
          <p className="text-sub leading-6 text-[var(--text-muted)]">
            {connectedAccountLine(status.connection?.account_display)}
          </p>
          <button
            type="button"
            onClick={onClose}
            className={`${SETTINGS_PRIMARY_BUTTON_CLASS} mt-2`}
          >
            完成
          </button>
        </div>
      ) : pairing == null ? (
        <form
          className="space-y-5 p-6 max-md:p-5"
          onSubmit={(e) => {
            e.preventDefault();
            void start(name);
          }}
        >
          <DialogHead
            title="连接到 MovieClaw 账号"
            description="接下来要在 MovieClaw 官网上批准这次连接。先给这台服务器起个名字，它会显示在官网上你的账号里。"
            onClose={onClose}
          />
          {error && <ErrorBanner>{error}</ErrorBanner>}
          <label className="block">
            <span className="mb-1.5 block text-caption text-[var(--text-muted)]">服务器名称</span>
            <input
              type="text"
              value={name}
              onChange={(e) => setName(e.target.value)}
              maxLength={NAME_MAX_LENGTH}
              autoFocus
              className={`${SETTINGS_INPUT_CLASS} w-full`}
            />
          </label>
          <p className="text-caption leading-5 text-[var(--text-faint)]">
            申请的权限：使用官方推送。只有你需要 MovieClaw 账号，家人不用。
          </p>
          <div className="flex justify-end gap-2">
            <button type="button" onClick={onClose} className={SETTINGS_BUTTON_CLASS}>
              取消
            </button>
            <button
              type="submit"
              disabled={busy != null || !name.trim()}
              className={SETTINGS_PRIMARY_BUTTON_CLASS}
            >
              {busy === "start" ? "正在获取配对码…" : "获取配对码"}
            </button>
          </div>
        </form>
      ) : waiting ? (
        <div className="space-y-4 p-6 max-md:p-5">
          <DialogHead
            title="在 MovieClaw 官网批准这次连接"
            description="打开下面的链接，登录后核对配对码，点「批准」。"
            onClose={onClose}
          />
          {error && <ErrorBanner>{error}</ErrorBanner>}
          <p className="select-all rounded-xl border border-white/[0.08] bg-white/[0.04] py-4 text-center font-mono text-[32px] font-bold leading-none tracking-[0.16em] text-[var(--text)]">
            {pairing.user_code}
          </p>
          <div className="flex items-center gap-4 max-sm:flex-col">
            {pairing.qrcode_image && (
              <div className="shrink-0 rounded-xl bg-white p-2">
                {/* 服务端渲染的 SVG data URL，用原生 img 展示 */}
                <img
                  src={pairing.qrcode_image}
                  alt="批准页二维码，用手机扫码打开"
                  className="size-24"
                />
              </div>
            )}
            <div className="min-w-0 flex-1 max-sm:w-full">
              <a
                href={pairing.verification_uri_complete}
                target="_blank"
                rel="noopener noreferrer"
                className="btn-accent flex w-full justify-center rounded-full px-4 py-2 text-ui font-semibold"
              >
                打开 {displayHost(pairing.verification_uri_complete)} 批准 ↗
              </a>
              <p className="mt-2 text-caption leading-5 text-[var(--text-faint)]">
                或用手机扫码。也可以手动打开{" "}
                <span className="font-mono text-[var(--text-muted)]">
                  {displayUrl(pairing.verification_uri)}
                </span>{" "}
                输入配对码。
              </p>
            </div>
          </div>
          <p className="flex items-center gap-2 text-sub text-[var(--text-muted)]">
            <Spinner />
            {/* 文字包成一个 span：外层是 flex，散开的文字节点会各自成项、被 gap 撑出空隙 */}
            <span>
              等待批准… 配对码 <span className="tabular-nums">{formatCountdown(remaining)}</span> 后失效
            </span>
          </p>
          <div className="flex items-center justify-between gap-3 border-t border-white/[0.06] pt-4">
            <p className="text-caption leading-5 text-[var(--text-faint)]">
              关掉窗口不会取消，批准后照样会连上
            </p>
            <button
              type="button"
              disabled={busy != null}
              onClick={() => void cancel()}
              className={SETTINGS_BUTTON_CLASS}
            >
              {busy === "cancel" ? "取消中…" : "取消"}
            </button>
          </div>
        </div>
      ) : (
        <div className="space-y-5 p-6 max-md:p-5">
          <DialogHead
            title="这次连接没有完成"
            description={pairingFailureText(
              pairing.status === "pending" ? "expired" : pairing.status,
              pairing.status === "pending" ? null : pairing.message,
            )}
            onClose={onClose}
          />
          {error && <ErrorBanner>{error}</ErrorBanner>}
          <div className="flex justify-end gap-2">
            <button
              type="button"
              disabled={busy != null}
              onClick={() => void cancel()}
              className={SETTINGS_BUTTON_CLASS}
            >
              取消
            </button>
            <button
              type="button"
              disabled={busy != null}
              onClick={() => void start(pairing.instance_name || name)}
              className={SETTINGS_PRIMARY_BUTTON_CLASS}
            >
              {busy === "start" ? "正在获取…" : "重新获取配对码"}
            </button>
          </div>
        </div>
      )}
    </Modal>
  );
}

/** 弹窗头：标题 + 说明 + 右上角关闭（关闭只收起弹窗，不取消配对）。 */
function DialogHead({
  title,
  description,
  onClose,
}: {
  title: string;
  description: string;
  onClose: () => void;
}) {
  return (
    <div className="flex items-start gap-3">
      <div className="min-w-0 flex-1">
        <h2 className="text-title font-bold text-white">{title}</h2>
        <p className="mt-1 text-sub leading-6 text-[var(--text-muted)]">{description}</p>
      </div>
      <button
        type="button"
        onClick={onClose}
        aria-label="关闭"
        title="关闭"
        className="-mr-2 -mt-1 shrink-0 rounded-full p-1.5 text-[var(--text-faint)] transition-colors hover:bg-white/[0.08] hover:text-[var(--text)]"
      >
        <XIcon className="size-4" />
      </button>
    </div>
  );
}
