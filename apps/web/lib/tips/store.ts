"use client";

/**
 * 使用提示的全站状态：这个人的提示状态快照 + 同屏只出一条的展示位。
 *
 * 模块级 store（useSyncExternalStore 订阅），不挂 Provider：任何地方——组件、
 * 事件处理函数、非 React 代码——都能直接 `donateTipEvent("x")`。账号切换走整页
 * 刷新（lib/account-reload.ts），模块级状态不会串到下一个账号。
 *
 * 快照在第一次有人用到提示时拉一次；之后的上报都先改本地（界面立刻反应），再以
 * 服务端返回的那一行为准覆盖。提示不是关键功能，网络失败一律静默——最坏情况是
 * 某条提示多出现一次或晚出现一次。
 */

import {
  donateTipEvent as apiDonate,
  fetchTipState,
  invalidateTip as apiInvalidate,
  recordTipDisplay,
  resetTipState,
  type TipRecordState,
} from "@/lib/api/tips";

import { EMPTY_SNAPSHOT, type TipsConfig, type TipsSnapshot } from "./engine";

/** 全站提示配置；同屏只出一条已由展示位保证，新提示暂不额外节流 */
export const TIPS_CONFIG: TipsConfig = { displayFrequencyMs: 0 };

export interface TipsStoreState {
  /** 快照拉到之前不出任何提示：免得已作废的提示先闪一下 */
  loaded: boolean;
  snapshot: TipsSnapshot;
  /** 当前占着展示位的提示；同屏最多一条 */
  activeTipId: string | null;
}

let state: TipsStoreState = { loaded: false, snapshot: EMPTY_SNAPSHOT, activeTipId: null };
const listeners = new Set<() => void>();
let loading: Promise<void> | null = null;

function setState(next: Partial<TipsStoreState>): void {
  state = { ...state, ...next };
  for (const listener of listeners) listener();
}

export function subscribeTips(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function getTipsState(): TipsStoreState {
  return state;
}

function nowIso(): string {
  return new Date().toISOString();
}

function putRecord(tipId: string, record: Omit<TipRecordState, "tip_id">): void {
  setState({ snapshot: { ...state.snapshot, tips: { ...state.snapshot.tips, [tipId]: record } } });
}

function emptyRecord(): Omit<TipRecordState, "tip_id"> {
  return {
    display_count: 0,
    first_displayed_at: null,
    last_displayed_at: null,
    invalidated_at: null,
    invalidated_reason: null,
  };
}

/** 拉一次快照（重复调用复用同一次请求；失败后下次再用到时重试） */
export function loadTips(): Promise<void> {
  if (state.loaded) return Promise.resolve();
  loading ??= fetchTipState()
    .then((res) => {
      const snapshot: TipsSnapshot = { events: {}, tips: {} };
      for (const { event_id, ...rest } of res.events) snapshot.events[event_id] = rest;
      for (const { tip_id, ...rest } of res.tips) snapshot.tips[tip_id] = rest;
      setState({ loaded: true, snapshot });
    })
    .catch(() => {})
    .finally(() => {
      loading = null;
    });
  return loading;
}

/**
 * 记一次用户行为（对应 TipKit 的 `Event.donate()`）：在用户做完那件事的地方调用。
 * 放在事件处理函数里，别放 useEffect——开发模式 StrictMode 会把副作用跑两遍、记两次。
 */
export function donateTipEvent(eventId: string): void {
  const prev = state.snapshot.events[eventId];
  const now = nowIso();
  setState({
    snapshot: {
      ...state.snapshot,
      events: {
        ...state.snapshot.events,
        [eventId]: { count: (prev?.count ?? 0) + 1, first_at: prev?.first_at ?? now, last_at: now },
      },
    },
  });
  apiDonate(eventId)
    .then(({ event_id, ...rest }) =>
      setState({
        snapshot: { ...state.snapshot, events: { ...state.snapshot.events, [event_id]: rest } },
      }),
    )
    .catch(() => {});
}

/** 记一次提示出现（use-tip 在提示真正上屏时调用，每次挂载一次） */
export function markTipDisplayed(tipId: string): void {
  const prev = state.snapshot.tips[tipId] ?? emptyRecord();
  const now = nowIso();
  putRecord(tipId, {
    ...prev,
    display_count: prev.display_count + 1,
    first_displayed_at: prev.first_displayed_at ?? now,
    last_displayed_at: now,
  });
  recordTipDisplay(tipId)
    .then(({ tip_id, ...rest }) => putRecord(tip_id, rest))
    .catch(() => {});
}

/**
 * 作废一条提示，以后不再出现（对应 TipKit 的 `tip.invalidate(reason:)`）。
 * 用户自己用到了提示说的功能时，在那个功能的入口里调用——提示没出现过也可以作废。
 */
export function invalidateTip(tipId: string, reason = "action_performed"): void {
  const prev = state.snapshot.tips[tipId] ?? emptyRecord();
  if (prev.invalidated_at) return;
  putRecord(tipId, { ...prev, invalidated_at: nowIso(), invalidated_reason: reason });
  apiInvalidate(tipId, reason)
    .then(({ tip_id, ...rest }) => putRecord(tip_id, rest))
    .catch(() => {});
}

/** 重置这个人的全部提示状态：所有提示重新按条件出现 */
export async function resetTips(): Promise<void> {
  await resetTipState();
  setState({ snapshot: EMPTY_SNAPSHOT });
}

/** 占展示位：空着或本来就是自己时成功 */
export function claimTipSlot(tipId: string): boolean {
  if (state.activeTipId !== null && state.activeTipId !== tipId) return false;
  if (state.activeTipId !== tipId) setState({ activeTipId: tipId });
  return true;
}

export function releaseTipSlot(tipId: string): void {
  if (state.activeTipId === tipId) setState({ activeTipId: null });
}
