"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import type { Route } from "next";
import Link from "next/link";
import {
  BrandLoader,
  checkSubscriptionAutomationReadiness,
  ContentEmptyState,
  HScroller,
  imageUrl,
  MediaTypeSwitcher,
  PosterImage,
  type Subscription,
  SubscriptionCell,
  type SubscriptionFilter,
  subscriptionFullyCollected,
  type TodayArrivalGroup,
  useDownloadTasks,
  useIsMobile,
  usePageChrome,
  usePermissions,
  useScrollRestoration,
  useSubscribeEntry,
  useTodayArrivalGroups,
  useTodaySubscriptionArrivals,
} from "@movieclaw/theme-sdk";


/** 预告行的横版卡宽：与「继续观看」行同款（双端 16:9，触屏不回落竖版海报）。 */
const COMING_CARD_W = "nf:w-[224px] nf:max-md:w-[168px]";

/**
 * Netflix 主题的订阅页（/subscriptions，docs/design/web-themes.md §5.7 的
 * 2026-09-15 修订：从「token 换皮、信息架构不动」升级为结构级处理）。
 *
 * 构图 = Netflix「我的片单 × 新片热门」的合体，与发现 / 媒体库页同一语言：
 *
 *   页头（大标题 + 统计）→「即将入库」横版预告行（Coming Soon 卡）→
 *   按追踪状态分区的海报行（追更中的剧集 / 订阅的电影 / 已收齐 / 已暂停）
 *
 * - 预告行是本页的「为什么订阅」答案：日期徽标 + 16:9 画面 + 状态元信息，
 *   下载中的卡带 3px 红色进度条（进度红与全站进度条同一语言）。订阅数据
 *   没有横版剧照，画面走海报模糊铺底 + 中央完整显示的既有兜底（§5.4）。
 * - 海报行沿用 PosterCardVisual 的斜标 / 收录脚注（信息不降级），移动端
 *   吃 .m-row 宽度断点公式，桌面 fixed 工具栏与发现页同一安放方式。
 * - 状态分区取代银玻璃的「剧集 / 电影」两大分区：行式布局里「追更中 →
 *   已收齐」的排序天然回答「还差什么」，已收齐整行压暗（同银玻璃取舍）。
 * - 数据与银玻璃版同源：SubscribeEntryProvider 全站订阅列表 +
 *   today-arrivals 轮询（lib/use-today-arrivals），无新后端依赖。
 */
export function NetflixSubscriptionsPage() {
  const { canManageSubscriptions, canSubscribe, isAdmin } = usePermissions();
  const restoreScrollRef = useScrollRestoration("subscriptions", {
    anchorAttribute: "data-subscription-id",
  });
  const scrollRootRef = useRef<HTMLDivElement | null>(null);
  const scrollRef = useCallback(
    (node: HTMLDivElement | null) => {
      scrollRootRef.current = node;
      restoreScrollRef(node);
    },
    [restoreScrollRef],
  );
  const [mediaType, setMediaType] = useState<SubscriptionFilter>("all");
  const { subscriptions, refresh } = useSubscribeEntry();
  const { tasks } = useDownloadTasks();
  const [failed, setFailed] = useState(false);
  // 链路体检整体为 error 时顶部亮警示横幅（全景与修复入口在 设置 → 概览）。
  // 拉取失败静默——横幅只是提示层
  const [healthIssue, setHealthIssue] = useState<{ libraryErrors: number } | null>(null);
  const { arrivals, failed: arrivalsFailed } = useTodaySubscriptionArrivals(subscriptions);

  const reload = useCallback(() => {
    setFailed(false);
    void refresh().then((ok) => setFailed(!ok));
    if (canManageSubscriptions) {
      void checkSubscriptionAutomationReadiness()
        .then((h) =>
          setHealthIssue(h.status === "error" ? { libraryErrors: h.error_count } : null),
        )
        .catch(() => setHealthIssue(null));
    } else {
      setHealthIssue(null);
    }
  }, [canManageSubscriptions, refresh]);

  useEffect(() => {
    reload();
  }, [reload]);

  // 全部/剧集/电影切换：移动端挂进全局顶栏右上角（字标与搜索之间那段空位），
  // 与发现页的数据源切换同一套安放方式（§5.2）；桌面端 fixed 悬浮视口右上。
  const chrome = usePageChrome();
  const isMobile = useIsMobile();
  const setTopBarActions = chrome?.setTopBarActions;
  const switchMediaType = useCallback(
    (next: SubscriptionFilter) => {
      if (next === mediaType) return;
      scrollRootRef.current?.scrollTo({ top: 0 });
      setMediaType(next);
    },
    [mediaType],
  );
  useEffect(() => {
    if (!isMobile || !setTopBarActions) return;
    return setTopBarActions(
      <MediaTypeSwitcher compact value={mediaType} onChange={switchMediaType} />,
    );
  }, [isMobile, mediaType, setTopBarActions, switchMediaType]);

  const groups = useTodayArrivalGroups(arrivals, mediaType, tasks);
  const subs = useMemo(() => subscriptions ?? [], [subscriptions]);

  // 预告卡的画面与进度：海报按订阅 id 就地取；下载进度取该订阅当前所有
  // 在传任务的最大值（0~1），只在「下载中」的卡上画红条。
  const posterBySubscription = useMemo(
    () => new Map(subs.map((sub) => [sub.id, sub.media.poster_url])),
    [subs],
  );
  const progressBySubscription = useMemo(() => {
    const taskByHash = new Map(
      tasks.map((task) => [task.info_hash.toLowerCase(), task]),
    );
    const map = new Map<number, number>();
    for (const arrival of arrivals ?? []) {
      const task = arrival.info_hash
        ? taskByHash.get(arrival.info_hash.toLowerCase())
        : undefined;
      if (task?.progress == null) continue;
      map.set(
        arrival.subscription_id,
        Math.max(map.get(arrival.subscription_id) ?? 0, task.progress),
      );
    }
    return map;
  }, [arrivals, tasks]);

  const tvCount = subs.filter((sub) => sub.media.kind === "tv").length;
  const movieCount = subs.length - tvCount;
  // 预告空态要交代「系统还在盯着」：按当前视角数仍在追踪的订阅数
  const trackingCount = subs.filter(
    (sub) => sub.status === "active" && (mediaType === "all" || sub.media.kind === mediaType),
  ).length;

  const sections = useMemo(() => {
    const inKind = (sub: Subscription) =>
      mediaType === "all" || sub.media.kind === mediaType;
    // 已收齐 = 后端判定的 completed，或当前已知季集已全部在库（追新季中的剧
    // 也算——它们的斜标会说明「自动续订」，压暗只排序视线，不藏内容）
    const settled = (sub: Subscription) =>
      sub.status === "completed" || subscriptionFullyCollected(sub);
    const byUpdated = (a: Subscription, b: Subscription) =>
      (b.updated_at ?? "").localeCompare(a.updated_at ?? "");
    return [
      {
        id: "tracking-tv",
        title: "追更中的剧集",
        items: subs
          .filter(
            (sub) =>
              inKind(sub) &&
              sub.media.kind === "tv" &&
              sub.status === "active" &&
              !settled(sub),
          )
          .sort(byUpdated),
        dim: false,
      },
      {
        id: "tracking-movie",
        title: "订阅的电影",
        items: subs
          .filter(
            (sub) =>
              inKind(sub) &&
              sub.media.kind === "movie" &&
              sub.status === "active" &&
              !settled(sub),
          )
          .sort(byUpdated),
        dim: false,
      },
      {
        id: "settled",
        title: "已收齐",
        items: subs.filter((sub) => inKind(sub) && settled(sub)).sort(byUpdated),
        dim: true,
      },
      {
        id: "paused",
        title: "已暂停",
        items: subs
          .filter((sub) => inKind(sub) && sub.status === "paused")
          .sort(byUpdated),
        dim: false,
      },
    ];
  }, [mediaType, subs]);

  const visibleCount =
    mediaType === "all" ? subs.length : (mediaType === "tv" ? tvCount : movieCount);
  const hasTvInView =
    mediaType === "all" ? tvCount > 0 : mediaType === "tv";

  return (
    <div
      ref={scrollRef}
      data-scroll-root
      className="scroll-thin scroll-safe nf:flex-1 nf:overflow-y-auto nf:pb-10"
    >
      {/* 页头：与媒体库首页同规格的大标题 + 统计行；行栅格对齐 4vw（与发现页
          的行内边距同一写法——--nf-inset 只在 .nf-row 作用域内定义，页级
          元素必须写字面量） */}
      <div className="nf:px-[4vw] nf:pt-7 nf:max-md:pt-4">
        <h2 className="text-on-image nf:text-[26px] nf:font-bold nf:leading-tight nf:tracking-[-0.02em] nf:text-white nf:max-md:text-[21px]">
          我的订阅
        </h2>
        <p className="text-on-image nf:mt-1.5 nf:text-ui nf:text-[var(--text-muted)] nf:max-md:mt-1 nf:max-md:text-sub">
          {mediaType === "all"
            ? `共 ${subs.length} 部 · ${tvCount} 部剧集 · ${movieCount} 部电影`
            : `共 ${visibleCount} 部${mediaType === "movie" ? "电影" : "剧集"}`}
        </p>
      </div>

      {/* 桌面类型胶囊：fixed 悬浮视口右上（顶栏下方），发现页同款安放方式，
          top 与页头标题带垂直对齐。calc 任意值 +/- 两侧必须空白（下划线转义）。 */}
      {!isMobile && (
        <div className="nf:fixed nf:right-[4vw] nf:top-[calc(var(--nf-nav-h)_+_26px)] nf:z-20">
          <MediaTypeSwitcher value={mediaType} onChange={switchMediaType} />
        </div>
      )}

      {/* 链路警示横幅：只在体检整体为 error 时出现——订阅不会丢（工单退避
          重试），但在修好之前无法自动下载入库。Netflix 弹层面板（#181818
          实底 + 方角），警示语义交给 --warn 描边与标题 */}
      {canManageSubscriptions && healthIssue && (
        <Link
          href={"/settings/overview" as Route}
          className="nf:mx-[4vw] nf:mt-4 nf:block nf:rounded-[4px] nf:border nf:border-[var(--warn)]/40 nf:bg-[#181818] nf:px-4 nf:py-3 nf:text-sub nf:leading-relaxed nf:text-white/80 nf:transition nf:hover:border-[var(--warn)]/70"
        >
          <span className="nf:font-semibold nf:text-[var(--warn)]">订阅链路有待修复：</span>
          {healthIssue.libraryErrors > 0
            ? `${healthIssue.libraryErrors} 个媒体库的入库链路有问题，相关订阅暂时无法自动下载入库（已下达的任务会自动重试）`
            : "订阅链路尚未就绪（缺少可用的资源站点或下载器），订阅暂时只能记录意愿"}
          ——点击查看体检详情与修复入口 →
        </Link>
      )}

      {subscriptions === null && !failed && (
        <div className="nf:mt-16 nf:flex nf:items-center nf:justify-center nf:gap-2.5 nf:text-ui nf:text-[var(--text-muted)]">
          <BrandLoader className="nf:size-5" />
          正在加载订阅…
        </div>
      )}

      {failed && (
        <div className="nf:mt-16 nf:flex nf:flex-col nf:items-center nf:gap-3 nf:text-center">
          <p className="nf:text-ui nf:text-[var(--text-muted)]">订阅列表加载失败</p>
          <button
            type="button"
            onClick={reload}
            className="btn-glass nf:px-4 nf:py-2 nf:text-ui nf:font-medium nf:text-[var(--text)]"
          >
            重试
          </button>
        </div>
      )}

      {/* 空态跟银玻璃版同一判定口径：完全无订阅给起步引导，筛选到空分类给
          「还没有剧集/电影订阅」——预告行只在当前视角有内容时出现，避免
          空态文案与预告空态注解叠在一起各说各话 */}
      {subscriptions !== null && !failed && visibleCount === 0 && (
        <ContentEmptyState
          variant="subscription"
          title={
            subscriptions.length === 0
              ? "从一部想看的作品开始"
              : `还没有${mediaType === "movie" ? "电影" : "剧集"}订阅`
          }
          description={
            canSubscribe
              ? `去发现页挑选一部${mediaType === "movie" ? "电影" : "剧集"}，打开详情并点击「订阅追踪」，有合适资源时会自动下载入库。`
              : "当前账号暂未开启订阅权限，请联系管理员为你开启。"
          }
          action={
            canSubscribe ? (
              <Link
                href={`/discover/${mediaType === "movie" ? "movie" : "tv"}` as Route}
                className="btn-accent nf:flex nf:items-center nf:gap-1.5 nf:rounded-full nf:px-4 nf:py-2 nf:text-ui nf:font-semibold"
              >
                去发现{mediaType === "movie" ? "电影" : "剧集"}
              </Link>
            ) : undefined
          }
        />
      )}

      {subscriptions !== null && !failed && visibleCount > 0 && (
        <>
          <ComingSoonSection
            groups={groups}
            loading={arrivals === null && !arrivalsFailed}
            failed={arrivalsFailed}
            posterBySubscription={posterBySubscription}
            progressBySubscription={progressBySubscription}
            trackingCount={trackingCount}
            hasTvInView={hasTvInView}
            canSubscribe={canSubscribe}
            canOpenTasks={isAdmin}
          />
          {sections.map((section) =>
            section.items.length > 0 ? (
              <SubscriptionPosterRow
                key={section.id}
                title={section.title}
                subscriptions={section.items}
                dim={section.dim}
              />
            ) : null,
          )}
        </>
      )}
    </div>
  );
}

/**
 * 「即将入库」预告行（Netflix「即将上线」Coming Soon 行的语言）：
 * 横版卡 + 日期徽标 + 状态元信息，下载中带 3px 红进度条。后端把候选收敛到
 * 最近的一天，行标题把这一天说清楚；空态与失败态各占一行轻文案，
 * 不让「没有安排」被读成「功能坏了」。
 */
function ComingSoonSection({
  groups,
  loading,
  failed,
  posterBySubscription,
  progressBySubscription,
  trackingCount,
  hasTvInView,
  canSubscribe,
  canOpenTasks,
}: {
  groups: TodayArrivalGroup[];
  loading: boolean;
  failed: boolean;
  posterBySubscription: ReadonlyMap<number, string | null>;
  progressBySubscription: ReadonlyMap<number, number>;
  /** 仍在追踪的订阅数，用于空态说明「系统还在盯着」。 */
  trackingCount: number;
  /** 当前视角里有没有剧集：没有就别用「定档」这种剧集语汇。 */
  hasTvInView: boolean;
  canSubscribe: boolean;
  canOpenTasks: boolean;
}) {
  const inset = "nf:px-[4vw]";
  const daysAhead = groups[0]?.daysAhead ?? 0;

  if (loading) {
    return (
      <p className={`${inset} nf:mt-7 nf:text-sub nf:text-[var(--text-faint)] nf:max-md:mt-6`}>
        正在计算预计入库时间…
      </p>
    );
  }
  if (failed) {
    return (
      <p className={`${inset} nf:mt-7 nf:text-sub nf:text-[var(--text-faint)] nf:max-md:mt-6`}>
        入库预告暂时不可用
      </p>
    );
  }
  if (groups.length === 0) {
    return (
      <p className={`${inset} nf:mt-7 nf:text-sub nf:text-[var(--text-faint)] nf:max-md:mt-6`}>
        {trackingCount === 0
          ? "订阅都已收齐或暂停了"
          : hasTvInView
            ? `接下来 7 天没有已定档的更新，${trackingCount} 部订阅仍在追踪`
            : `当前没有正在下载或整理的电影，${trackingCount} 部订阅仍在追踪`}
        {!canSubscribe && trackingCount === 0 && "，有新的追踪目标时，这里会提前预告"}
      </p>
    );
  }

  return (
    <section
      aria-label={daysAhead === 0 ? "今日可能入库" : "即将入库"}
      className="nf:mt-7 nf:[content-visibility:auto] nf:[contain-intrinsic-size:auto_260px] nf:max-md:mt-6"
    >
      <div className={`nf:mb-3 nf:flex nf:items-baseline nf:justify-between nf:gap-4 nf:max-md:mb-2 ${inset}`}>
        <h3 className="text-on-image nf:text-body-lg nf:font-semibold nf:tracking-[-0.01em] nf:text-[var(--text)]">
          {daysAhead === 0
            ? "今日可能入库"
            : `即将入库 · ${daysAhead === 1 ? "明天" : `${daysAhead} 天后`}`}
        </h3>
        <span className="tnum nf:shrink-0 nf:text-caption nf:text-[var(--text-faint)]">
          {groups.length} 部
        </span>
      </div>
      <HScroller className={`nf:gap-2 nf:pb-1 nf:pt-1 ${inset}`}>
        {groups.map((group) => (
          <ComingSoonCard
            key={group.subscriptionId}
            group={group}
            posterUrl={posterBySubscription.get(group.subscriptionId)}
            progress={progressBySubscription.get(group.subscriptionId)}
          />
        ))}
      </HScroller>
      {/* 「下载中」状态的任务中心入口：触屏上整卡已指向订阅详情，任务细节
          在详情页可见；桌面给一行深链，与银玻璃版「下载中 → 任务中心」一致 */}
      {canOpenTasks && groups.some((g) => g.presentation.statusLabel === "下载中") && (
        <Link
          href={"/activity?view=active" as Route}
          className={`nf:mt-1.5 nf:inline-flex nf:text-caption nf:text-[var(--text-faint)] nf:transition nf:hover:text-white ${inset}`}
        >
          查看下载中的任务 ›
        </Link>
      )}
    </section>
  );
}

/** 预告行的状态色：与银玻璃时间轨道同一语义（中性 → 警示 → 下载 → 收尾）。 */
const comingStatusColor: Record<TodayArrivalGroup["presentation"]["statusLabel"], string> = {
  预计入库: "nf:text-[var(--text-muted)]",
  等待资源: "nf:text-[var(--warn)]",
  下载中: "nf:text-[var(--info)]",
  整理中: "nf:text-[var(--ok)]",
};

/**
 * Coming Soon 横版卡：16:9 画面（海报模糊铺底 + 中央完整显示）+ 左上日期
 * 徽标 + 底部标题与「季集 · 状态 · 预计时间」元信息行。下载中在画面底边
 * 画 3px 红色进度条。整卡点击进订阅详情（追踪明细 + 活动时间线）。
 */
function ComingSoonCard({
  group,
  posterUrl,
  progress,
}: {
  group: TodayArrivalGroup;
  posterUrl: string | null | undefined;
  progress: number | undefined;
}) {
  const dayLabel =
    group.daysAhead === 0 ? "今天" : group.daysAhead === 1 ? "明天" : `${group.daysAhead} 天后`;
  const downloading = group.presentation.statusLabel === "下载中";
  const percent =
    downloading && progress != null ? Math.round(Math.max(0, Math.min(1, progress)) * 100) : null;

  return (
    <Link
      href={`/subscriptions/${group.subscriptionId}` as Route}
      className={`nf:group nf:block nf:shrink-0 nf:cursor-pointer nf:outline-none ${COMING_CARD_W}`}
      aria-label={`查看《${group.mediaTitle}》的订阅详情，${dayLabel}${group.episodeLabel ? ` ${group.episodeLabel}` : ""}`}
    >
      {/* 6px 与全站卡片同一档（rounded-* 换档后的卡角；4px 是控件档） */}
      <div className="nf:relative nf:aspect-video nf:overflow-hidden nf:rounded-[6px] nf:bg-[#181818] nf:ring-1 nf:ring-white/[0.06] nf:transition-all nf:duration-150 nf:group-hover:ring-white/30">
        {posterUrl ? (
          <>
            {/* 模糊铺底与中央海报同一宽度（海报约 72 宽 = 卡高 126 × 86% × 2/3），
                地址一致只取一次；imageUrl 兼容已入库订阅的本地资产相对路径 */}
            <PosterImage
              src={imageUrl(posterUrl)}
              width={72}
              alt=""
              className="nf:absolute nf:inset-0 nf:size-full nf:scale-125 nf:object-cover nf:opacity-45 nf:blur-xl"
            />
            <div className="nf:absolute nf:inset-0 nf:bg-black/30" />
            <div className="nf:absolute nf:inset-0 nf:flex nf:items-center nf:justify-center nf:px-6">
              <div className="nf:aspect-[2/3] nf:h-[86%] nf:overflow-hidden nf:rounded-[2px] nf:shadow-[0_0_24px_rgba(0,0,0,0.6)]">
                <PosterImage
                  src={imageUrl(posterUrl)}
                  width={72}
                  alt={`${group.mediaTitle} 海报`}
                  className="nf:size-full"
                />
              </div>
            </div>
          </>
        ) : (
          <span className="nf:flex nf:size-full nf:items-center nf:justify-center nf:px-4 nf:text-center nf:text-ui nf:font-semibold nf:text-white/25">
            {group.mediaTitle}
          </span>
        )}
        {/* 日期徽标：黑底白字的实底小签，不与状态色争语义 */}
        <span className="tnum nf:absolute nf:left-2 nf:top-2 nf:rounded-[2px] nf:bg-black/75 nf:px-1.5 nf:py-0.5 nf:text-caption nf:font-bold nf:text-white nf:backdrop-blur-sm">
          {dayLabel}
        </span>
        {percent != null && (
          <span className="nf:absolute nf:inset-x-0 nf:bottom-0 nf:h-[3px] nf:bg-white/25">
            <span className="nf:block nf:h-full nf:bg-[var(--accent)]" style={{ width: `${percent}%` }} />
          </span>
        )}
      </div>
      <p className="nf:mt-1.5 nf:truncate nf:text-sub nf:font-medium nf:text-white/90 nf:transition-colors nf:group-hover:text-white">
        {group.mediaTitle}
      </p>
      <p className="tnum nf:mt-0.5 nf:flex nf:min-w-0 nf:items-center nf:gap-x-1.5 nf:truncate nf:text-caption">
        {group.episodeLabel && (
          <span className="nf:shrink-0 nf:text-[var(--text-muted)]">{group.episodeLabel}</span>
        )}
        <span className={`nf:shrink-0 nf:font-medium ${comingStatusColor[group.presentation.statusLabel]}`}>
          {group.presentation.statusLabel}
        </span>
        <span className="nf:min-w-0 nf:truncate nf:text-[var(--text-faint)]">
          {group.presentation.timeLabel}
        </span>
      </p>
    </Link>
  );
}

/**
 * 订阅海报行：标题 + 横滚竖版海报（PosterCardVisual 保留斜标与收录脚注，
 * 点击进订阅详情）。结构复刻 MediaRow（含 .m-row 钩子类，Netflix 移动端
 * 行卡宽断点公式据此生效）。dim 行整体压暗一档——亮着的就是还没到手的。
 */
function SubscriptionPosterRow({
  title,
  subscriptions,
  dim,
}: {
  title: string;
  subscriptions: Subscription[];
  dim: boolean;
}) {
  return (
    <section
      aria-label={title}
      className="nf:mt-8 nf:[content-visibility:auto] nf:[contain-intrinsic-size:auto_330px] nf:max-md:mt-6"
    >
      <div className="nf:mb-3 nf:flex nf:items-baseline nf:justify-between nf:gap-4 nf:px-[4vw] nf:max-md:mb-2">
        <h3 className="text-on-image nf:text-body-lg nf:font-semibold nf:tracking-[-0.01em] nf:text-[var(--text)]">
          {title}
        </h3>
        <span className="tnum nf:shrink-0 nf:text-caption nf:text-[var(--text-faint)]">
          {subscriptions.length} 部
        </span>
      </div>
      {/* pt-2：海报卡悬停上浮 6px 的头部余量（media-row 同一规矩），缺了会削顶角 */}
      <HScroller className="m-row nf:gap-4 nf:px-[4vw] nf:pb-1 nf:pt-2 nf:max-md:gap-3">
        {subscriptions.map((sub) => (
          <div
            key={sub.id}
            data-subscription-id={sub.id}
            // 插值前留空格：类名紧贴 ${ 时 Tailwind 扫描不到（实测漏生成了 xl 档宽度）
            className={`nf:w-[152px] nf:shrink-0 nf:max-md:w-[126px] nf:xl:w-[164px] ${
              dim
                ? "nf:opacity-[0.72] nf:transition-opacity nf:duration-200 nf:focus-within:opacity-100 nf:hover:opacity-100"
                : ""
            }`}
          >
            <SubscriptionCell sub={sub} />
          </div>
        ))}
      </HScroller>
    </section>
  );
}
