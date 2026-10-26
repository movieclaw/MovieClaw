"use client";

import { useLocale } from "next-intl";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import type { DownloadTask } from "@/lib/api/downloaders";
import {
  listRecentSubscriptionArrivals,
  listTodaySubscriptionArrivals,
  type RecentSubscriptionArrival,
  type Subscription,
  type TodaySubscriptionArrival,
} from "@/lib/api/subscriptions";
import { useDownloadTasks } from "@/lib/download-tasks";
import { useSession } from "@/lib/session";
import { subscriptionsHomeState, type SubsHomeState } from "@/lib/subscriptions-home";
import { useVisiblePolling } from "@/lib/use-visible-polling";

/** 整周预告的轮询间隔（同 iOS SubscriptionsView 的 10 秒） */
const WEEK_POLL_MS = 10_000;
/** 刚刚入库的轮询间隔（入库频率低，20 秒足够） */
const RECENT_POLL_MS = 20_000;

/**
 * 模块级快照：订阅首页与「全部」海报墙共用（对应 iOS 的 SubscriptionsHomeFeed.shared）。
 *
 * 为什么不是各页各自的空白状态：从首页点「剧集订阅 ›」进海报墙，墙上必须立刻是
 * 和首页那一排同一份顺序与状态签——拿首页刚取到的数据先算一遍，墙再在后台补刷，
 * 不会先闪一屏「没有预告」的排序再跳回来。快照记着属于哪个账号（用户名），
 * 换账号即作废，不串到别的账号上。
 */
let sharedSnapshot: {
  owner: string;
  week: TodaySubscriptionArrival[] | null;
  recent: RecentSubscriptionArrival[];
  now: number;
} | null = null;

export interface SubscriptionsHomeFeed {
  /** 算好的整页结果（Hero、日程、两排海报） */
  state: SubsHomeState;
  /** 刚刚入库的卡片（服务端顺序，一部一张） */
  recent: RecentSubscriptionArrival[];
  /** 算「几点能看」「多久前入库」用的当前时刻（随预告一起刷新） */
  now: Date;
}

/**
 * 订阅首页的数据源：整周预告（10 秒）、刚刚入库（20 秒）、下载快照（管理员），
 * 按输入变化用纯函数 subscriptionsHomeState 一次算好整页（口径见 lib/subscriptions-home.ts）。
 *
 * - 订阅清单由调用方传入（全站唯一数据源 SubscribeEntryProvider），没有订阅时不打预告接口；
 * - 请求编号守卫：迟到的旧响应一律丢弃；已有快照时瞬时失败继续保留，不闪成空；
 * - 刚刚入库在老服务端上没有接口，客户端静默当空（见 listRecentSubscriptionArrivals）；
 * - 下载快照复用全站 DownloadTasksProvider（成员不轮询下载器），这里只在管理员时才用它
 *   修正「下载中」的进度与预计时间——成员看的是订阅进度推断出的状态。
 */
export function useSubscriptionsHome(
  subscriptions: Subscription[] | null,
  isAdmin: boolean,
): SubscriptionsHomeFeed {
  const locale = useLocale();
  const owner = useSession().session.username;
  const cached = sharedSnapshot?.owner === owner ? sharedSnapshot : null;
  const [week, setWeek] = useState<TodaySubscriptionArrival[] | null>(cached?.week ?? null);
  const [recent, setRecent] = useState<RecentSubscriptionArrival[]>(cached?.recent ?? []);
  const [now, setNow] = useState(() => cached?.now ?? Date.now());
  const { tasks: allTasks } = useDownloadTasks();
  const tasks: DownloadTask[] = isAdmin ? allTasks : EMPTY_TASKS;

  const enabled = subscriptions !== null && subscriptions.length > 0;
  const weekRequest = useRef(0);
  const recentRequest = useRef(0);
  const weekRef = useRef(week);
  weekRef.current = week;

  // 快照写回模块级缓存，供海报墙（或返回首页时）首帧直接用
  useEffect(() => {
    sharedSnapshot = { owner, week, recent, now };
  }, [owner, week, recent, now]);

  const refreshWeek = useCallback(() => {
    if (!enabled) return;
    const id = ++weekRequest.current;
    void listTodaySubscriptionArrivals(undefined, "week")
      .then((rows) => {
        if (id !== weekRequest.current) return;
        setWeek(rows);
        setNow(Date.now());
      })
      .catch(() => {
        // 已有快照时保留；从没取到过就当「一周都没有安排」，页面照样排版
        if (id === weekRequest.current && weekRef.current === null) setWeek([]);
      });
  }, [enabled]);

  const refreshRecent = useCallback(() => {
    if (!enabled) return;
    const id = ++recentRequest.current;
    void listRecentSubscriptionArrivals()
      .then((rows) => {
        if (id === recentRequest.current) setRecent(rows);
      })
      .catch(() => {
        // 瞬时失败保持原样：这一行不闪
      });
  }, [enabled]);

  // 订阅清单变化（订阅 / 取消后）立刻重取一次；没有订阅时作废在途请求
  useEffect(() => {
    if (!enabled) {
      weekRequest.current += 1;
      recentRequest.current += 1;
      return;
    }
    refreshWeek();
    refreshRecent();
  }, [enabled, refreshWeek, refreshRecent, subscriptions]);

  useVisiblePolling(refreshWeek, enabled ? WEEK_POLL_MS : null);
  useVisiblePolling(refreshRecent, enabled ? RECENT_POLL_MS : null);

  const state = useMemo(
    () => subscriptionsHomeState(subscriptions ?? [], week ?? [], recent, tasks, new Date(now), locale),
    [subscriptions, week, recent, tasks, now, locale],
  );
  const nowDate = useMemo(() => new Date(now), [now]);
  return { state, recent: enabled ? recent : EMPTY_RECENT, now: nowDate };
}

const EMPTY_TASKS: DownloadTask[] = [];
const EMPTY_RECENT: RecentSubscriptionArrival[] = [];
