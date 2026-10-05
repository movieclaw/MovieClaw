"use client";

/**
 * Fanart.tv API Key 的就地填写表单（docs/design/image-sources.md §3）。
 *
 * 产品口径：**不内置 Key、不单开配置页**。用户在第一次用 Fanart 的地方填一次——
 * 全局设置的开关、某个库的刮削设置、换图弹层的「从 Fanart.tv 找更多」——三处
 * 共用这一个表单，文案按入口微调。Key 保存在服务器上、全站共用，之后哪里都
 * 不用再填。
 *
 * 「验证并启用」= 后端先拿这把 Key 向 Fanart.tv 真发一次请求，通过才保存；
 * 不通过就把后端给的中文原因摆在表单下面（Key 无效 / 网络不通各有引导），
 * 已保存的旧 Key 不受影响。
 */

import { useCallback, useEffect, useState } from "react";

import { HttpError } from "@/lib/http";
import { type FanartStatus, getFanartStatus, saveFanartKey } from "@/lib/api/scrape";

/** 申请 Key 的官方页面 */
export const FANART_KEY_URL = "https://fanart.tv/get-an-api-key/";

type Variant = "global" | "library" | "modal";

const COPY: Record<Variant, { title: string; body: string; action: string }> = {
  global: {
    title: "先填一次 Fanart.tv API Key",
    body: "Fanart.tv 需要你自己的 API Key（免费注册即可获得）。只需填这一次，全站共用：之后在这里、媒体库设置、换图弹层都能直接用。",
    action: "验证并启用",
  },
  library: {
    title: "这个库要用 Fanart.tv，先填一次 API Key",
    body: "Key 保存到全站，不只属于这个库：之后全局设置和其他库都能直接用，不用再填。",
    action: "验证并启用",
  },
  modal: {
    title: "从 Fanart.tv 找更多候选",
    body: "需要先填一次你自己的 Fanart.tv API Key（免费注册即可获得）。填好后马上能在这里挑图，自动选图要不要用 Fanart 仍由设置里的开关决定。",
    action: "验证并使用",
  },
};

export function FanartKeyForm({
  variant,
  onVerified,
  onCancel,
  className = "",
}: {
  variant: Variant;
  /** 验证通过、已保存：调用方据此打开开关 / 重拉候选 */
  onVerified: (status: FanartStatus) => void;
  onCancel: () => void;
  className?: string;
}) {
  const copy = COPY[variant];
  const [value, setValue] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async () => {
    const key = value.trim();
    if (!key) {
      setError("请先粘贴 API Key");
      return;
    }
    setBusy(true);
    setError(null);
    try {
      onVerified(await saveFanartKey(key));
    } catch (err) {
      setError(
        err instanceof HttpError || err instanceof Error ? err.message : "验证失败，请稍后重试",
      );
    } finally {
      setBusy(false);
    }
  };

  return (
    <div
      className={`rounded-xl border border-[var(--fanart-line)] bg-[var(--fanart-soft)] p-3.5 ${className}`}
    >
      <p className="text-ui font-semibold text-[var(--text)]">{copy.title}</p>
      <p className="mb-2.5 mt-0.5 max-w-[62ch] text-caption leading-relaxed text-[var(--text-muted)]">
        {copy.body}
      </p>
      <div className="flex flex-wrap items-center gap-2">
        <input
          autoFocus
          spellCheck={false}
          autoComplete="off"
          placeholder="粘贴 API Key"
          value={value}
          onChange={(e) => setValue(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") void submit();
          }}
          className="min-w-0 flex-[1_1_220px] rounded-xl border border-white/[0.08] bg-white/[0.04] px-3 py-2 font-mono text-sub text-[var(--text)] outline-none placeholder:text-[var(--text-faint)] focus:border-[var(--accent)]/50"
        />
        <button
          type="button"
          disabled={busy}
          onClick={() => void submit()}
          className="btn-accent shrink-0 rounded-full px-4 py-1.5 text-sub font-semibold disabled:opacity-50"
        >
          {busy ? "验证中…" : copy.action}
        </button>
        <button
          type="button"
          disabled={busy}
          onClick={onCancel}
          className="shrink-0 rounded-full px-3 py-1.5 text-sub text-[var(--text-faint)] transition-colors hover:text-[var(--text)] disabled:opacity-50"
        >
          取消
        </button>
      </div>
      {error && <p className="mt-2 text-caption leading-relaxed text-[#ff9f9f]">{error}</p>}
      <p className="mt-2 text-micro text-[var(--text-faint)]">
        还没有 Key？
        <a
          href={FANART_KEY_URL}
          target="_blank"
          rel="noreferrer"
          className="text-[var(--accent)] underline underline-offset-2"
        >
          去 fanart.tv 免费申请 ↗
        </a>
        <span className="mx-1.5">·</span>
        VIP 会员的 Key 能更快拿到刚上传的新图
      </p>
    </div>
  );
}

/**
 * Fanart Key 状态（设置卡、库设置、换图弹层各自取一次）。拿不到（非管理员、
 * 网络）时为 null，调用方按「没配置」展示——只是少了个入口，不阻断别的设置。
 */
export function useFanartStatus() {
  const [status, setStatus] = useState<FanartStatus | null>(null);
  const reload = useCallback(() => {
    getFanartStatus()
      .then(setStatus)
      .catch(() => setStatus(null));
  }, []);
  useEffect(() => {
    reload();
  }, [reload]);
  return { status, setStatus, reload };
}

/** Key 能不能用（配过且没被 Fanart 拒绝）。 */
export function fanartUsable(status: FanartStatus | null): boolean {
  return Boolean(status?.configured && !status.key_invalid);
}
