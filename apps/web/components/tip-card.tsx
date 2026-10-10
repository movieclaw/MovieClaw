"use client";

import { SparklesIcon, XIcon } from "@/components/icons";
import type { TipDefinition } from "@/lib/tips/engine";
import { useTip } from "@/lib/tips/use-tip";

interface TipCardProps<P> {
  tip: TipDefinition<P>;
  /** 规则里读的界面状态，见 useTip */
  params?: P;
  /** 点了动作按钮：执行对应操作；之后这条提示按 action_performed 作废 */
  onAction?: (actionId: string) => void;
  className?: string;
}

/**
 * 内联提示卡（对标 TipKit 的 TipView）：条件不满足或已作废时不占位。
 * 关闭按钮按 closed 作废，动作按钮按 action_performed 作废。
 */
export function TipCard<P = undefined>({ tip, params, onAction, className = "" }: TipCardProps<P>) {
  const { visible, invalidate } = useTip(tip, params);
  if (!visible) return null;

  return (
    <div
      role="note"
      data-tip-id={tip.id}
      className={`flex items-start gap-3 rounded-xl border border-white/10 bg-white/[0.06] px-4 py-3 backdrop-blur-xl ${className}`}
    >
      <SparklesIcon className="mt-0.5 size-4 shrink-0 text-[var(--accent)]" />
      <div className="min-w-0 flex-1">
        <p className="text-sub font-semibold leading-6 text-white">{tip.title}</p>
        {tip.message && (
          <p className="text-sub leading-6 text-[var(--text-muted)]">{tip.message}</p>
        )}
        {tip.actions && tip.actions.length > 0 && (
          <div className="mt-2 flex flex-wrap gap-2">
            {tip.actions.map((action) => (
              <button
                key={action.id}
                type="button"
                onClick={() => {
                  onAction?.(action.id);
                  invalidate("action_performed");
                }}
                className="rounded-md bg-white/[0.1] px-2.5 py-1 text-caption font-medium text-white transition hover:bg-white/[0.18]"
              >
                {action.label}
              </button>
            ))}
          </div>
        )}
      </div>
      <button
        type="button"
        aria-label="关闭提示"
        onClick={() => invalidate("closed")}
        className="-mr-1 shrink-0 rounded-md p-1 text-white/50 transition hover:bg-white/[0.08] hover:text-white"
      >
        <XIcon className="size-4" />
      </button>
    </div>
  );
}
