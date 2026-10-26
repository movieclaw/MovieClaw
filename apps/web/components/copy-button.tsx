"use client";

import { useTranslations } from "next-intl";
import { appTranslator } from "@/lib/i18n/translate";

import { useEffect, useState } from "react";

import { CheckIcon, CopyIcon } from "@/components/icons";

/**
 * 统一写入剪贴板：HTTPS/localhost 优先使用 Clipboard API；局域网 HTTP 环境下
 * Clipboard API 通常不可用，因此回退到临时 textarea + execCommand。
 */
export async function copyText(text: string): Promise<void> {
  if (navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(text);
      return;
    } catch {
      // 权限策略或非安全上下文可能拒绝，继续走兼容路径。
    }
  }

  const textarea = document.createElement("textarea");
  textarea.value = text;
  textarea.readOnly = true;
  textarea.style.position = "fixed";
  textarea.style.left = "-9999px";
  textarea.style.opacity = "0";
  // 原生模态 dialog 外的元素不可交互，兼容复制用的文本框必须放在当前弹窗内。
  (document.activeElement?.closest("dialog[open]") ?? document.body).appendChild(textarea);
  textarea.select();
  textarea.setSelectionRange(0, text.length);
  let copied = false;
  try {
    copied = document.execCommand("copy");
  } finally {
    textarea.remove();
  }
  if (!copied) throw new Error(appTranslator()("common.clipboardDenied"));
}

/**
 * 复制按钮（全站统一）：点一下把 text 写进剪贴板，图标切成对勾并停留 1.6 秒
 * ——复制是「无声成功」的操作，没有这一下回执，用户不知道到底复制上没有。
 *
 * 外观不在这里写死：调用方用 className 决定位置、配色与浮现方式（见下方
 * REVEAL_CLASS）。带 label 时是「图标 + 文字」的行内按钮，不带就是纯图标。
 *
 * stopPropagation 是必需的：图标常常挂在「点一下才浮现」的容器里（气泡、
 * 代码块），不拦住冒泡的话，点复制会顺手把容器的浮现态又切回去，按钮当场消失。
 */
export function CopyButton({
  text,
  label,
  ariaLabel,
  className = "",
}: {
  text: string;
  /** 文字标签（如「复制」）。不传则纯图标，无障碍名由 aria-label 承担 */
  label?: string;
  /** 紧凑按钮可只显示「复制」，用独立读屏名说明复制的是哪个字段 */
  ariaLabel?: string;
  className?: string;
}) {
  const t = useTranslations();
  const [copied, setCopied] = useState(false);
  useEffect(() => {
    if (!copied) return;
    const timer = window.setTimeout(() => setCopied(false), 1600);
    return () => window.clearTimeout(timer);
  }, [copied]);

  return (
    <button
      type="button"
      aria-label={ariaLabel ? (copied ? t("common.copied") : ariaLabel) : label ? undefined : copied ? t("common.copied") : t("common.copy")}
      onClick={(event) => {
        event.stopPropagation();
        void copyText(text)
          .then(() => setCopied(true))
          .catch(() => {});
      }}
      className={`inline-flex items-center gap-1 rounded-md transition-colors ${className}`}
    >
      {copied ? <CheckIcon className="size-3.5" /> : <CopyIcon className="size-3.5" />}
      {label && <span>{copied ? t("common.copied") : label}</span>}
    </button>
  );
}

/**
 * 「浮现式」操作按钮的显隐类：默认透明，鼠标悬停在容器上（group/copy）
 * 或容器被点开（data-revealed）时浮现，键盘 Tab 聚焦时也浮现——否则纯键盘
 * 用户永远够不到它。
 *
 * 为什么触摸端要单独走 data-revealed：Tailwind 的 hover: 变体带
 * `@media (hover: hover)`，触摸设备上这条规则根本不存在，只靠 hover 等于没有。
 * 全站别处的做法是「触摸端常驻」（.touch-reveal），但消息流里每条都常驻一个
 * 图标太吵，所以这里改成点一下浮现（见 useTapReveal）。
 *
 * pointer-events 必须跟着 opacity 一起切：opacity: 0 的元素照样吃点击，
 * 隐身状态下它会闷声拦下气泡左缘、代码块右上角的触摸——用户什么都没看见，
 * 手一碰却复制了。隐身即穿透，浮现才接管。
 */
export const REVEAL_CLASS =
  "pointer-events-none opacity-0 transition-opacity group-hover/copy:pointer-events-auto group-hover/copy:opacity-100 group-data-[revealed=true]/copy:pointer-events-auto group-data-[revealed=true]/copy:opacity-100 focus-visible:pointer-events-auto focus-visible:opacity-100";

/**
 * 点击浮现的开关，配合 REVEAL_CLASS 使用：
 *   容器挂 `group/copy` + `data-revealed`，可点区域挂 `onClick={toggle}`。
 *
 * 5 秒后自动收起：不然滑过一屏消息、随手点几下，屏幕上就留一串常亮的图标；
 * 再点一下也能立刻收起（toggle 语义），不必等超时。
 */
export function useTapReveal() {
  const [revealed, setRevealed] = useState(false);
  useEffect(() => {
    if (!revealed) return;
    const timer = window.setTimeout(() => setRevealed(false), 5000);
    return () => window.clearTimeout(timer);
  }, [revealed]);
  return {
    /** 直接摊进容器的 props */
    revealProps: { "data-revealed": revealed ? ("true" as const) : undefined },
    toggle: () => setRevealed((v) => !v),
  };
}
