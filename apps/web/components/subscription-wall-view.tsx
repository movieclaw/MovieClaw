"use client";

import type { Route } from "next";
import { useEffect, useMemo, useState } from "react";

import { BrandLoader } from "@/components/brand-loader";
import { PageNav } from "@/components/page-nav";
import { useSubscribeEntry } from "@/components/subscribe-entry";
import { SubsHomePosterCard } from "@/components/subscriptions-home-kit";
import { listLibraries, type MediaLibrary } from "@/lib/api/libraries";
import { listRuleSets, type RuleSet, type Subscription } from "@/lib/api/subscriptions";
import { usePermissions } from "@/lib/permissions";
import { wallSummary, type SubsHomeShelfItem } from "@/lib/subscriptions-home";
import { useScrollRestoration } from "@/lib/use-scroll-restoration";
import { useSubscriptionsHome } from "@/lib/use-subscriptions-home";

/**
 * 订阅海报墙（/subscriptions/wall/[kind]）：订阅首页「剧集订阅 ›」「电影订阅 ›」
 * 或一排末尾的「查看全部」进来的二级页（对照 iOS SubscriptionWallView.swift）。
 *
 * 与首页那一排是**同一份排好的结果**（同一个纯函数 + 首页留下的数据快照，见
 * lib/use-subscriptions-home.ts）：顺序、状态签、计数口径两处一致。首页横滑只放前 20 张，
 * 这里放全部，按首页分隔线的两侧拆成三段——进行中 / 已暂停 / 已收齐（电影叫已入库）。
 * 墙上的海报比首页多一行「规则组 → 媒体库」流向（规则组名只有管理员可见）。
 */
export function SubscriptionWallView({ kind }: { kind: "movie" | "tv" }) {
  const { canManageSubscriptions, isAdmin } = usePermissions();
  const { subscriptions, refresh } = useSubscribeEntry();
  const { state } = useSubscriptionsHome(subscriptions, isAdmin);
  const shelf = kind === "movie" ? state.movie : state.tv;
  const title = kind === "movie" ? "电影订阅" : "剧集订阅";
  const restoreScrollRef = useScrollRestoration(`subscriptions-wall-${kind}`, {
    anchorAttribute: "data-subscription-id",
  });
  const [ruleSets, setRuleSets] = useState<RuleSet[]>([]);
  const [libraries, setLibraries] = useState<MediaLibrary[]>([]);

  // 从别处直达（或订阅清单还没取过）时补刷一次订阅清单
  useEffect(() => {
    if (subscriptions === null) void refresh();
  }, [subscriptions, refresh]);

  // 规则组名（管理员可见边界同详情页）与媒体库名：只为拼「规则组 → 库」流向
  useEffect(() => {
    let cancelled = false;
    void listLibraries()
      .then((rows) => !cancelled && setLibraries(rows))
      .catch(() => !cancelled && setLibraries([]));
    if (canManageSubscriptions) {
      void listRuleSets()
        .then((rows) => !cancelled && setRuleSets(rows))
        .catch(() => !cancelled && setRuleSets([]));
    }
    return () => {
      cancelled = true;
    };
  }, [canManageSubscriptions]);

  const flowOf = useMemo(() => {
    const ruleName = new Map(ruleSets.map((rule) => [rule.id, rule.name]));
    const libraryName = new Map(libraries.map((library) => [library.id, library.name]));
    const defaultLibrary = new Map(
      libraries.filter((library) => library.is_default).map((library) => [library.kind, library.name]),
    );
    // 订阅未指定库时显示该类型默认库
    return (sub: Subscription) => {
      const library =
        sub.library_id === null ? defaultLibrary.get(sub.media.kind) : libraryName.get(sub.library_id);
      const parts = [(sub.selection_mode === "smart" ? "智能选择" : sub.rule_set_id !== null ? ruleName.get(sub.rule_set_id) : null), library].filter(Boolean);
      return parts.length ? parts.join(" → ") : null;
    };
  }, [ruleSets, libraries]);

  return (
    <div ref={restoreScrollRef} className="scroll-thin scroll-safe flex-1 overflow-y-auto pb-12">
      <PageNav title={title} fallback={{ label: "我的订阅", href: "/subscriptions" as Route }} />
      <div className="px-6 max-md:px-4">
        <h2 className="text-on-image text-[26px] font-bold leading-tight tracking-[-0.02em] text-white max-md:text-[21px]">
          {title}
        </h2>
        {subscriptions !== null && (
          <p className="tnum text-on-image mt-1 text-ui text-[var(--text-muted)] max-md:text-sub">
            {wallSummary(shelf, kind)}
          </p>
        )}
      </div>
      {subscriptions === null ? (
        <div className="mt-16 flex items-center justify-center gap-2.5 text-ui text-[var(--text-muted)]">
          <BrandLoader className="size-5" />
          正在加载订阅…
        </div>
      ) : (
        <div className="mt-6 space-y-8 px-6 max-md:px-4">
          <WallSection name="进行中" items={shelf.active} flowOf={flowOf} />
          <WallSection name="已暂停" items={shelf.paused} flowOf={flowOf} />
          <WallSection name={kind === "movie" ? "已入库" : "已收齐"} items={shelf.done} flowOf={flowOf} />
        </div>
      )}
    </div>
  );
}

function WallSection({
  name,
  items,
  flowOf,
}: {
  name: string;
  items: SubsHomeShelfItem[];
  flowOf: (sub: Subscription) => string | null;
}) {
  if (items.length === 0) return null;
  return (
    <section aria-label={name}>
      <h3 className="flex items-baseline gap-2">
        <span className="text-[20px] font-bold text-[var(--text)]">{name}</span>
        <span className="tnum text-sub text-[var(--text-faint)]">{items.length}</span>
      </h3>
      <div className="mt-3 grid gap-x-3 gap-y-5 [grid-template-columns:repeat(auto-fill,minmax(104px,1fr))] md:gap-x-4 md:gap-y-6 md:[grid-template-columns:repeat(auto-fill,minmax(140px,1fr))]">
        {items.map((item) => (
          <SubsHomePosterCard key={item.sub.id} item={item} flow={flowOf(item.sub)} dimsResting={false} />
        ))}
      </div>
    </section>
  );
}
