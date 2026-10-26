"use client";

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from "react";

import type { PosterVisualItem } from "@/components/poster-card";
import { SubscribeDialog, type SubscribeTarget } from "@/components/subscribe-dialog";
import { fetchDiscoveredTitleDetails, titleRef } from "@/lib/api/discover";
import { listSubscriptions, type Subscription } from "@/lib/api/subscriptions";
import type { MediaType } from "@/lib/media-types";
import { usePermissions } from "@/lib/permissions";

/**
 * 海报卡片「订阅影片」入口 + 全站订阅状态的唯一数据源。
 *
 * 海报卡片散落在搜索影视 / 发现电影 / 发现剧集 / Top250 / 订阅页等多层组件里，
 * 订阅弹层（SubscribeDialog）没必要每页各挂一份——这里在应用外壳挂唯一一份，
 * 卡片通过 useSubscribeEntry().open(item) 触发，与 useMediaDetail 的模式一致。
 *
 * 订阅状态同理收口在这里：应用启动拉取一次订阅列表，卡片与详情页都通过
 * subscriptionOf(item) 判断「该影片是否已订阅」，订阅页海报墙直接渲染
 * subscriptions 列表，避免每处各自维护一份快照；弹层里订阅/取消订阅成功后
 * （onChanged）自动刷新，所有消费方即时同步。
 *
 * kind（电影/剧集）是订阅预检的必填参数：发现页与 TMDB 搜索结果的卡片自带
 * type；豆瓣轻量搜索结果没有 type，点击时补拉一次豆瓣详情由后端识别类型
 * （详情有服务端缓存，代价很小），拉取失败按电影兜底——预检若因此收敛不到
 * 条目，弹层内会展示明确的错误信息，不会静默错订。
 */
interface SubscribeEntryValue {
  /** 当前身份能否创建、调整或取消订阅；页面据此直接隐藏操作入口。 */
  canSubscribe: boolean;
  /** 打开订阅弹层；豆瓣来源缺 type 时先补拉详情识别类型，故为异步。
   *  opts.upgradeIntent 打开洗版变体（库存季预填 + 建订阅后自动接一轮洗版）。 */
  open: (item: PosterVisualItem, opts?: { upgradeIntent?: boolean }) => Promise<void>;
  /** 查找该影片已存在的订阅；未订阅（或列表尚未加载完成）返回 undefined */
  subscriptionOf: (item: SubscriptionLookupKey) => Subscription | undefined;
  /** 全站订阅列表；null = 首次拉取尚未完成（订阅页据此渲染加载态） */
  subscriptions: Subscription[] | null;
  /** 重新拉取订阅列表（订阅/取消订阅后调用，卡片状态即时刷新）；resolve false 表示拉取失败 */
  refresh: () => Promise<boolean>;
}

/** 订阅状态查询的最小键：来源 + 外部 ID（TMDB 来源还需 type 消除电影/剧集撞号）。 */
export interface SubscriptionLookupKey {
  id: string;
  source?: "tmdb" | "douban";
  type?: MediaType;
}

const SubscribeEntryContext = createContext<SubscribeEntryValue | null>(null);

export function useSubscribeEntry(): SubscribeEntryValue {
  const value = useContext(SubscribeEntryContext);
  if (!value) {
    // i18n-ignore: developer-only provider invariant.
    throw new Error("useSubscribeEntry 必须在 SubscribeEntryProvider 内使用（见 app-shell.tsx）");
  }
  return value;
}

export function SubscribeEntryProvider({ children }: { children: ReactNode }) {
  const { canSubscribe } = usePermissions();
  const [target, setTarget] = useState<SubscribeTarget | null>(null);
  // 全站订阅列表：启动拉取一次；失败不覆盖已有数据——状态判断降级为「都未订阅」，
  // 不影响订阅入口本身（弹层预检有自己的错误提示）
  const [subs, setSubs] = useState<Subscription[] | null>(null);

  const refresh = useCallback(async () => {
    try {
      setSubs(await listSubscriptions());
      return true;
    } catch {
      return false;
    }
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  const open = useCallback(
    async (item: PosterVisualItem, opts?: { upgradeIntent?: boolean }) => {
      if (!canSubscribe) return;
      const source = item.source ?? "tmdb";
      const reference = item.titleRef ?? titleRef(source, item.type ?? "movie", item.id);
      let kind = item.type;
      if (!kind && source === "douban") {
        kind = await fetchDiscoveredTitleDetails(reference)
          .then((detail) => detail.item.type)
          .catch(() => undefined);
      }
      setTarget({
        titleRef: reference,
        kind: kind ?? "movie",
        title: item.title,
        year: item.year,
        upgradeIntent: opts?.upgradeIntent,
      });
    },
    [canSubscribe],
  );

  // 查表索引：subscriptionOf 在海报墙的每张卡片渲染时都会被调用，线性查找
  // 是 O(卡片数 × 订阅数)；列表变化时建一次索引，单次查询 O(1)，同键保留首条。
  // 匹配口径（详情页与海报卡片共用）：
  //   - 豆瓣来源：按 douban_id 匹配（订阅从 TMDB 入口建立且未关联豆瓣 ID 时
  //     匹配不到，属已知限制——两边没有可靠的对齐键，不按标题猜）；
  //   - TMDB 来源：按 tmdb_id 匹配；电影和剧集的 TMDB ID 是两个独立号段，
  //     卡片带 type 时用它消歧，缺失时（历史快照数据）仅按 ID 匹配。
  const subscriptionIndex = useMemo(() => {
    const byDouban = new Map<string, Subscription>();
    const byTmdbTyped = new Map<string, Subscription>();
    const byTmdb = new Map<string, Subscription>();
    for (const s of subs ?? []) {
      if (s.media.douban_id && !byDouban.has(s.media.douban_id)) {
        byDouban.set(s.media.douban_id, s);
      }
      const id = String(s.media.tmdb_id);
      const typed = `${id}:${s.media.kind}`;
      if (!byTmdbTyped.has(typed)) byTmdbTyped.set(typed, s);
      if (!byTmdb.has(id)) byTmdb.set(id, s);
    }
    return { byDouban, byTmdbTyped, byTmdb };
  }, [subs]);

  const subscriptionOf = useCallback(
    (key: SubscriptionLookupKey) => {
      if ((key.source ?? "tmdb") === "douban") return subscriptionIndex.byDouban.get(key.id);
      return key.type === undefined
        ? subscriptionIndex.byTmdb.get(key.id)
        : subscriptionIndex.byTmdbTyped.get(`${key.id}:${key.type}`);
    },
    [subscriptionIndex],
  );

  const value = useMemo(
    () => ({ canSubscribe, open, subscriptionOf, subscriptions: subs, refresh }),
    [canSubscribe, open, subscriptionOf, subs, refresh],
  );

  return (
    <SubscribeEntryContext.Provider value={value}>
      {children}
      <SubscribeDialog
        target={target}
        onClose={() => setTarget(null)}
        onChanged={refresh}
      />
    </SubscribeEntryContext.Provider>
  );
}
