/**
 * 使用提示的判定内核（对标 Apple TipKit 的规则引擎，docs/design/tips.md）。
 *
 * 纯函数、不依赖 React 和网络：给定一条提示的声明、这个人的提示状态快照、当前时间，
 * 算出它现在该不该出现。状态的拉取与上报在 store.ts，界面挂接在 use-tip.ts。
 *
 * 判定顺序（与 TipKit 一致）：
 * 1. 已作废（用户关掉 / 用过了功能）→ 永不出现；
 * 2. 展示次数到了 maxDisplayCount → 永不出现（只算出来，不写回服务端）；
 * 3. 有一条规则不满足 → 暂不出现，条件满足后自动出现；
 * 4. 从没展示过的「新提示」受全局频率节流：上一条新提示出现后的
 *    displayFrequencyMs 内不再冒新的（ignoresDisplayFrequency 可豁免）。
 */

/** 服务端快照里的一种事件（字段同接口 TipEventView） */
export interface TipEventSnapshot {
  count: number;
  first_at: string;
  last_at: string;
}

/** 服务端快照里的一条提示记录（字段同接口 TipRecordView） */
export interface TipRecordSnapshot {
  display_count: number;
  first_displayed_at: string | null;
  last_displayed_at: string | null;
  invalidated_at: string | null;
  invalidated_reason: string | null;
}

export interface TipsSnapshot {
  events: Record<string, TipEventSnapshot>;
  tips: Record<string, TipRecordSnapshot>;
}

/** 规则里读到的一种事件；从没发生过时 count=0、时间为 null */
export interface TipEventFacts {
  count: number;
  firstAt: Date | null;
  lastAt: Date | null;
}

export interface TipRuleContext<P> {
  /** 读某种事件的累计情况 */
  event(id: string): TipEventFacts;
  /** 调用方传进来的界面状态（如「列表里有没有条目」） */
  params: P;
  now: Date;
}

/** 提示上的动作按钮；点了之后这条提示按 action_performed 作废 */
export interface TipAction {
  id: string;
  label: string;
}

export interface TipDefinition<P = undefined> {
  /** 全局唯一标识，形如 `library.filter`（小写字母数字、`.` `_` `-`，≤64 字符） */
  id: string;
  title: string;
  message?: string;
  actions?: TipAction[];
  /** 出现条件：全部返回 true 才出现；不写 = 随时可出现 */
  rules?: ((ctx: TipRuleContext<P>) => boolean)[];
  /** 最多出现几次（每次挂载出现算一次）；不写 = 不限，直到作废 */
  maxDisplayCount?: number;
  /** 不受全局「新提示」频率节流 */
  ignoresDisplayFrequency?: boolean;
}

export type TipStatus = "available" | "pending" | "invalidated";

export interface TipsConfig {
  /** 两条「新提示」之间至少隔多久（毫秒）；0 = 不节流 */
  displayFrequencyMs: number;
}

export const EMPTY_SNAPSHOT: TipsSnapshot = { events: {}, tips: {} };

/** 标识规则与服务端一致：不合规的标识上报会被 422 */
export const TIP_ID_PATTERN = /^[a-z0-9][a-z0-9._-]{0,63}$/;

export function defineTip<P = undefined>(tip: TipDefinition<P>): TipDefinition<P> {
  if (!TIP_ID_PATTERN.test(tip.id)) throw new Error(`提示标识不合规：${tip.id}`);
  return tip;
}

function parse(value: string | null | undefined): Date | null {
  return value ? new Date(value) : null;
}

export function eventFacts(snapshot: TipsSnapshot, id: string): TipEventFacts {
  const e = snapshot.events[id];
  if (!e) return { count: 0, firstAt: null, lastAt: null };
  return { count: e.count, firstAt: parse(e.first_at), lastAt: parse(e.last_at) };
}

/** 最近一条「新提示」第一次出现的时间：全局频率节流的起点 */
export function lastNewTipShownAt(snapshot: TipsSnapshot): Date | null {
  let latest: Date | null = null;
  for (const record of Object.values(snapshot.tips)) {
    const at = parse(record.first_displayed_at);
    if (at && (!latest || at > latest)) latest = at;
  }
  return latest;
}

/**
 * 一条提示现在的状态。
 *
 * 只用于「要不要开始出现」：已经在屏幕上的提示由 use-tip.ts 锁住，不会因为
 * 这次出现把展示次数加到上限而当场消失。
 */
export function tipStatus<P>(
  tip: TipDefinition<P>,
  snapshot: TipsSnapshot,
  params: P,
  config: TipsConfig,
  now: Date = new Date(),
): TipStatus {
  const record = snapshot.tips[tip.id];
  if (record?.invalidated_at) return "invalidated";
  const shown = record?.display_count ?? 0;
  if (tip.maxDisplayCount !== undefined && shown >= tip.maxDisplayCount) return "invalidated";

  const ctx: TipRuleContext<P> = { event: (id) => eventFacts(snapshot, id), params, now };
  if (tip.rules && !tip.rules.every((rule) => rule(ctx))) return "pending";

  if (shown === 0 && !tip.ignoresDisplayFrequency && config.displayFrequencyMs > 0) {
    const last = lastNewTipShownAt(snapshot);
    if (last && now.getTime() - last.getTime() < config.displayFrequencyMs) return "pending";
  }
  return "available";
}
