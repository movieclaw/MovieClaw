"use client";

import { Component, type ComponentType, type ReactNode } from "react";

import { reportSlotError } from "@/lib/theme-runtime";

/**
 * 主题坑位的错误边界（docs/design/theme-plugins.md §4.3「出错」）：主题的外框组件渲染时抛错，
 * 只让这一个坑位回落基础实现（没有基础实现的不渲染），不让整站白屏——设置 → 外观始终可达。
 */
class SlotBoundary extends Component<
  { themeId: string; slot: string; fallback: ReactNode; children: ReactNode },
  { failed: boolean }
> {
  state = { failed: false };

  static getDerivedStateFromError() {
    return { failed: true };
  }

  componentDidCatch(error: unknown) {
    reportSlotError(this.props.themeId, this.props.slot, error);
  }

  render() {
    return this.state.failed ? this.props.fallback : this.props.children;
  }
}

// 包好的组件按「原组件 + 坑位」缓存：解析每次渲染都会跑，现包新组件会让坑位整棵重新挂载
const guarded = new WeakMap<object, Map<string, ComponentType<object>>>();

/** 给主题的坑位 / 整页组件套上错误边界；fallback 是同一坑位的基础实现。 */
export function guardSlot<P extends object>(
  themeId: string,
  slot: string,
  Slot: ComponentType<P>,
  Fallback: ComponentType<P> | undefined,
): ComponentType<P> {
  const bySlot = guarded.get(Slot) ?? new Map<string, ComponentType<object>>();
  guarded.set(Slot, bySlot);
  const key = `${themeId}:${slot}`;
  const cached = bySlot.get(key);
  if (cached) return cached as ComponentType<P>;
  function Guarded(props: P) {
    return (
      <SlotBoundary themeId={themeId} slot={slot} fallback={Fallback ? <Fallback {...props} /> : null}>
        <Slot {...props} />
      </SlotBoundary>
    );
  }
  Guarded.displayName = `ThemeSlot(${themeId}.${slot})`;
  bySlot.set(key, Guarded as ComponentType<object>);
  return Guarded;
}
