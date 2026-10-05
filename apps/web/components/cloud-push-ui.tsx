"use client";

/**
 * 「MovieClaw Cloud」「App 推送」「通知」三个分区共用的小件：状态胶囊、提示横幅、
 * 开关、错误条、输入框与行内链接的样式。
 *
 * 外观全部照搬设置页既有语言（IM 推送、Webhook 分区的胶囊与错误条），两个主题
 * 靠全站的类与 token 换皮。行内链接刻意不用 --accent：Netflix 主题下它是品牌红，
 * 那套语言里红只留给激活指示和进度条。
 */

import type { ReactNode } from "react";

import { InfoIcon, XIcon } from "@/components/icons";
import { LiquidGlassButton } from "@/components/liquid-glass";
import { useBackdrop } from "@/lib/backdrop";
import { TONE_COLOR, type Tone } from "@/lib/cloud-push-display";

export const INPUT_CLASS =
  "w-full rounded-xl border border-white/[0.08] bg-white/[0.04] px-3 py-2 text-sub " +
  "text-[var(--text)] outline-none transition-colors placeholder:text-[var(--text-faint)] " +
  "focus:border-[var(--accent)]/50";

/** 行内文字链接：白字 + 淡下划线，悬停时下划线加深。 */
export const LINK_CLASS =
  "font-medium text-[var(--text)] underline decoration-white/30 underline-offset-[3px] " +
  "transition-colors hover:decoration-white/70";

/** 状态胶囊：色点 + 文字，浅底取状态色的 12%（与 IM 推送、资源站点同款）。 */
export function StatusPill({ tone, label }: { tone: Tone; label: string }) {
  const color = TONE_COLOR[tone];
  return (
    <span
      className="inline-flex shrink-0 items-center gap-1.5 rounded-full px-2 py-0.5 text-caption font-medium"
      style={{ background: `color-mix(in oklab, ${color} 12%, transparent)`, color }}
    >
      <span className="size-1.5 rounded-full" style={{ background: color }} />
      {label}
    </span>
  );
}

const BANNER_TONE_CLASS: Record<Tone, string> = {
  ok: "border-[var(--ok)]/25 bg-[var(--ok)]/[0.07]",
  info: "border-[var(--info)]/25 bg-[var(--info)]/[0.07]",
  warn: "border-[var(--warn)]/30 bg-[var(--warn)]/[0.08]",
  danger: "border-[var(--danger)]/30 bg-[var(--danger)]/[0.08]",
  neutral: "border-white/[0.08] bg-white/[0.03]",
};

/**
 * 提示横幅：图标取状态色，正文用常规文字色——整段话染成黄/红读起来刺眼，
 * 信号交给图标和底色就够了。action 放在右侧（如「立即同步」），onDismiss
 * 给一个关闭键（云端的服务通知）。
 */
export function Banner({
  tone,
  title,
  children,
  action,
  onDismiss,
  dismissLabel = "关闭",
}: {
  tone: Tone;
  title?: string;
  children?: ReactNode;
  action?: ReactNode;
  onDismiss?: () => void;
  dismissLabel?: string;
}) {
  return (
    <div
      role="status"
      className={`flex flex-wrap items-start gap-x-3 gap-y-2 rounded-xl border px-4 py-3 ${BANNER_TONE_CLASS[tone]}`}
    >
      <InfoIcon className="mt-[3px] size-4 shrink-0" style={{ color: TONE_COLOR[tone] }} />
      {/* 窄屏上正文占满一行，把右侧按钮挤到下一行：basis 扣掉图标与间距（1.75rem）再留一点
          余量防止亚像素误差把正文自己挤下去，多出的宽度由 flex-1 补回 */}
      <div className={`min-w-0 flex-1 ${action ? "max-sm:basis-[calc(100%-2rem)]" : ""}`}>
        {title && <p className="text-body font-medium text-[var(--text)]">{title}</p>}
        {children != null && (
          <div className={`text-sub leading-6 text-[var(--text-muted)] ${title ? "mt-0.5" : ""}`}>
            {children}
          </div>
        )}
      </div>
      {action && <div className="shrink-0 self-center max-sm:ml-7">{action}</div>}
      {onDismiss && (
        <button
          type="button"
          onClick={onDismiss}
          aria-label={dismissLabel}
          title={dismissLabel}
          className="-mr-1 shrink-0 rounded-full p-1 text-[var(--text-faint)] transition-colors hover:bg-white/[0.08] hover:text-[var(--text)]"
        >
          <XIcon className="size-4" />
        </button>
      )}
    </div>
  );
}

/** 加载 / 写入失败的错误条（与 IM 推送、Webhook 分区同一形态）。 */
export function ErrorBanner({ children }: { children: ReactNode }) {
  return (
    <div className="rounded-xl border border-[var(--danger)]/30 bg-[var(--danger)]/10 px-4 py-3 text-body text-[var(--danger)]">
      {children}
    </div>
  );
}

/** 受控的液态玻璃开关（全站统一的开关形态），读屏名由 label 给。 */
export function Toggle({
  checked,
  label,
  disabled = false,
  onChange,
}: {
  checked: boolean;
  label: string;
  disabled?: boolean;
  onChange: (next: boolean) => void;
}) {
  const { backdrop } = useBackdrop();
  return (
    <LiquidGlassButton
      backgroundImage={backdrop}
      variant="dark"
      checked={checked}
      disabled={disabled}
      aria-label={label}
      onCheckedChange={onChange}
      className="!min-h-0 !w-auto !gap-0 !bg-transparent !p-0"
    >
      <span className="sr-only">{checked ? "已开启" : "已关闭"}</span>
    </LiquidGlassButton>
  );
}

/** 按钮里的微型转圈（等待批准、检测中）。 */
export function Spinner({ className = "size-3.5" }: { className?: string }) {
  return (
    <span
      aria-hidden
      className={`inline-block shrink-0 animate-spin rounded-full border-2 border-white/20 border-t-[var(--text-muted)] ${className}`}
    />
  );
}
