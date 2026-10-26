"use client";

import { useCallback, useEffect, useRef, useState, useSyncExternalStore } from "react";

import { tipStatus, type TipDefinition } from "./engine";
import {
  TIPS_CONFIG,
  claimTipSlot,
  getTipsState,
  invalidateTip,
  loadTips,
  markTipDisplayed,
  releaseTipSlot,
  subscribeTips,
  type TipsStoreState,
} from "./store";

const SERVER_STATE: TipsStoreState = {
  loaded: false,
  snapshot: { events: {}, tips: {} },
  activeTipId: null,
};

export interface UseTipResult {
  /** 现在该不该把提示画出来 */
  visible: boolean;
  /** 作废这条提示（用户关掉传 "closed"，用过功能传 "action_performed"） */
  invalidate: (reason?: string) => void;
}

/**
 * 把一条提示挂到界面上：条件满足、展示位空着时出现，每次上屏记一次展示。
 *
 * 上屏后就锁住，直到作废或组件卸载——不会因为这次出现把展示次数加到
 * maxDisplayCount 而当场消失（TipKit 同样只在下次出现时才算超限）。
 *
 * @param params 规则里读的界面状态（`ctx.params`），每次渲染都会重新判定
 */
export function useTip<P = undefined>(tip: TipDefinition<P>, params?: P): UseTipResult {
  const store = useSyncExternalStore(subscribeTips, getTipsState, () => SERVER_STATE);
  const [presenting, setPresenting] = useState(false);
  // 每次挂载只记一次展示：开发模式 StrictMode 会把副作用跑两遍，ref 跨两遍保留
  const displayedRef = useRef(false);

  const invalidated = Boolean(store.snapshot.tips[tip.id]?.invalidated_at);
  const status = store.loaded
    ? tipStatus(tip, store.snapshot, params as P, TIPS_CONFIG)
    : "pending";
  const slotFree = store.activeTipId === null || store.activeTipId === tip.id;

  useEffect(() => {
    void loadTips();
  }, []);

  useEffect(() => {
    if (presenting || status !== "available" || !slotFree) return;
    if (!claimTipSlot(tip.id)) return;
    setPresenting(true);
    if (!displayedRef.current) {
      displayedRef.current = true;
      markTipDisplayed(tip.id);
    }
  }, [presenting, status, slotFree, tip.id]);

  useEffect(() => {
    if (presenting && invalidated) {
      setPresenting(false);
      releaseTipSlot(tip.id);
    }
  }, [presenting, invalidated, tip.id]);

  // 卸载时让出展示位，排队的下一条提示接着出现
  useEffect(() => () => releaseTipSlot(tip.id), [tip.id]);

  const invalidate = useCallback(
    (reason?: string) => invalidateTip(tip.id, reason),
    [tip.id],
  );
  return { visible: presenting && !invalidated, invalidate };
}
