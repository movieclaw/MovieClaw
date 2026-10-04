"use client";

import { useCallback, useEffect, useRef, useState } from "react";

import * as DropdownMenu from "@radix-ui/react-dropdown-menu";
import type { Route } from "next";
import Link from "next/link";
import { useRouter } from "next/navigation";

import { ContentEmptyState } from "@/components/content-empty-state";
import { CompassIcon, ShieldIcon } from "@/components/icons";
import {
  DESKTOP_CARD_FRAME,
  DESKTOP_IMMERSIVE_FRAME,
  HeroAmbientBackdrop,
  HeroBleed,
  IMMERSIVE_INSET,
  useHeroScrollVar,
  useHeroWindowBackdrop,
} from "@/components/immersive-hero";
import { PAGE_NAV_BUTTON_CLASS } from "@/components/page-nav";
import { PosterCardVisual, type PosterVisualItem } from "@/components/poster-card";
import { useSubscribeEntry } from "@/components/subscribe-entry";
import {
  SUBS_HOME_HERO_HEIGHT,
  SubsHomeHero,
  heroImageOf,
} from "@/components/subscriptions-home-hero";
import { SUBS_HOME_INSET } from "@/components/subscriptions-home-kit";
import {
  SubsHomeRecentRow,
  SubsHomeSchedule,
  SubsHomeShelfRow,
} from "@/components/subscriptions-home-sections";
import {
  checkSubscriptionAutomationReadiness,
  type Subscription,
} from "@/lib/api/subscriptions";
import { useHeroAmbientColor } from "@/lib/hero-ambient-color";
import { imageUrl } from "@/lib/image-proxy";
import { usePageChrome } from "@/lib/page-chrome";
import { usePermissions } from "@/lib/permissions";
import type { SubscriptionFilter } from "@/lib/subscription-overview";
import {
  subscriptionCollectionMeta,
  subscriptionRibbon,
} from "@/lib/subscription-ui";
import { useTheme } from "@/lib/ui-prefs";
import { useIsMobile } from "@/lib/use-media-query";
import { useScrollRestoration } from "@/lib/use-scroll-restoration";
import { useSubscriptionsHome } from "@/lib/use-subscriptions-home";

/**
 * 订阅页的银玻璃布局「我的订阅」：流媒体式版式（2026-09-27 对齐原生 App 的
 * SubscriptionsView.swift；Netflix 主题走 themes/netflix/pages/subscriptions-page.tsx，
 * 入口分流见 components/subscriptions-page.tsx）。
 *
 * 页面按时间与意图拆，而不是按「全部 / 剧集 / 电影」拆：
 *
 *   沉浸 Hero「下一部到手的」（下载中 / 整理中 → 刚刚入库 → 今天 → 最近一次预告，8 秒轮播）
 *   → 刚刚入库（16:9 剧照横滑，点一下直接播放，看完即消失）
 *   → 日程（今天起一周的日期条 + 当天议程）
 *   → 剧集订阅 / 电影订阅（横滑海报，在追的在前，「›」进完整海报墙 /subscriptions/wall/[kind]）
 *
 * 页面底色跟着当前那张 Hero 剧照的主色走（HeroAmbientBackdrop，自带纯黑实底盖住全站
 * 半透明蒙版），剧照底部渐隐进去，整页像被这部作品的光照着。链路体检收成琥珀色 ⚠ 下拉
 * （管理员，体检 error 时才出现）：手机挂在顶栏右上角，桌面在卡片右上角。
 *
 * 形态：手机是沉浸式——页面用等量负外边距顶到屏幕物理顶边、Hero 从状态栏与顶栏雾层底下
 * 穿过，大字标题「我的订阅」挂在全局顶栏里；桌面是主区里的一张圆角卡片，Hero 在卡片顶部，
 * 页内保留 h2 标题。
 *
 * 数据：订阅清单直接消费 SubscribeEntryProvider 的全站订阅列表（弹层里订阅 / 取消后即时同步），
 * 进入本页时主动 refresh 一次；整周预告、刚刚入库、下载快照与整页排序在 useSubscriptionsHome，
 * 判定口径全在 lib/subscriptions-home.ts。老版本服务端没有刚刚入库 / 整周预告时，对应版块自动不出现。
 */
export function SubscriptionsView() {
  const { canManageSubscriptions, canSubscribe, isAdmin } = usePermissions();
  const { subscriptions, refresh } = useSubscribeEntry();
  const { state, recent, now } = useSubscriptionsHome(subscriptions, isAdmin);
  const [failed, setFailed] = useState(false);
  // 体检整体为 error 时的库错误数；null = 不亮警示钮（拉取失败也静默——它只是提示层）
  const [healthErrors, setHealthErrors] = useState<number | null>(null);
  const [heroIndex, setHeroIndex] = useState(0);

  const rootRef = useRef<HTMLDivElement | null>(null);
  const scrollRootRef = useRef<HTMLDivElement | null>(null);
  const restoreScrollRef = useScrollRestoration("subscriptions");
  const scrollRef = useCallback(
    (node: HTMLDivElement | null) => {
      scrollRootRef.current = node;
      restoreScrollRef(node);
    },
    [restoreScrollRef],
  );
  // 滚动距离写成根元素上的 --hero-scroll：Hero 视差 / 文字淡出、氛围底退淡都读它，滚动不重渲染
  useHeroScrollVar(scrollRootRef, rootRef);

  const reload = useCallback(() => {
    setFailed(false);
    void refresh().then((ok) => setFailed(!ok));
    if (canManageSubscriptions) {
      void checkSubscriptionAutomationReadiness()
        .then((health) => setHealthErrors(health.status === "error" ? health.error_count : null))
        .catch(() => setHealthErrors(null));
    } else {
      setHealthErrors(null);
    }
  }, [canManageSubscriptions, refresh]);

  useEffect(() => {
    reload();
  }, [reload]);

  // 手机银玻璃：大字标题挂进全局顶栏（iOS 标签根页的 .inlineLarge），⚠ 挂在右上角
  const chrome = usePageChrome();
  const setTopBarTitle = chrome?.setTopBarTitle;
  const setTopBarActions = chrome?.setTopBarActions;
  const isMobile = useIsMobile();
  const structural = useTheme().structural;
  const mobileChrome = isMobile && !structural;
  const showHealth = canManageSubscriptions && healthErrors !== null;
  useEffect(() => {
    if (!mobileChrome || !setTopBarTitle) return;
    return setTopBarTitle("我的订阅", { large: true });
  }, [mobileChrome, setTopBarTitle]);
  useEffect(() => {
    if (!mobileChrome || !setTopBarActions || !showHealth || healthErrors === null) return;
    return setTopBarActions(<HealthMenu errors={healthErrors} />);
  }, [mobileChrome, setTopBarActions, showHealth, healthErrors]);

  const subs = subscriptions ?? [];
  const showError = failed && subscriptions === null;
  const loading = subscriptions === null && !failed;
  const slides = state.slides;
  const hasHero = !showError && subs.length > 0 && slides.length > 0;
  // 沉浸态（Hero 顶到最上沿）：加载中先按沉浸态占位，数据到达原位替换不跳版
  const immersive = loading || hasHero;
  const currentSlide = hasHero ? slides[Math.min(heroIndex, slides.length - 1)] : null;
  const tint = useHeroAmbientColor(currentSlide ? heroImageOf(currentSlide) : null);
  // 桌面沉浸：窗口背景换成当前这张剧照，侧栏玻璃与四周缝隙都透出同一部片（手机不需要，本来就铺满）
  useHeroWindowBackdrop(!isMobile && !structural && currentSlide ? heroImageOf(currentSlide) : null);

  return (
    <div
      ref={rootRef}
      className={`relative isolate flex min-h-0 flex-1 flex-col max-md:-mt-[calc(var(--safe-top)+var(--mobile-topbar-h))] ${
        immersive ? DESKTOP_IMMERSIVE_FRAME : DESKTOP_CARD_FRAME
      }`}
    >
      <HeroAmbientBackdrop
        color={hasHero ? tint : null}
        windowed={immersive}
        className="-z-10 max-md:bottom-[calc(-1*var(--vp-overshoot,0px))]"
      />
      <div
        ref={scrollRef}
        data-scroll-root
        className={`scroll-thin scroll-safe relative flex-1 overflow-y-auto pb-12 ${IMMERSIVE_INSET} ${
          immersive ? "" : "max-md:pt-[calc(var(--safe-top)+var(--mobile-topbar-h))]"
        }`}
      >
        {/* 桌面（以及没有全局顶栏的形态）：页内标题 + ⚠。有 Hero 时叠在 Hero 顶部压暗上 */}
        {!mobileChrome && (
          <div
            className={`flex items-center justify-between gap-3 px-6 ${
              // 叠在大图上时是绝对定位（不吃滚动区的让位内边距），自己补上侧栏让位
              immersive
                ? "pointer-events-none absolute inset-x-0 top-0 z-10 pl-[calc(var(--immersive-inset,0px)+1.5rem)] pt-5"
                : "pt-7"
            }`}
          >
            <h2 className="text-on-image text-[26px] font-bold leading-tight tracking-[-0.02em] text-white">
              我的订阅
            </h2>
            {showHealth && healthErrors !== null && (
              <div className="pointer-events-auto">
                <HealthMenu errors={healthErrors} />
              </div>
            )}
          </div>
        )}

        {loading && <LoadingSkeleton />}

        {showError && (
          <div className="mt-16 flex flex-col items-center gap-3 text-center">
            <p className="text-ui text-[var(--text-muted)]">订阅列表加载失败</p>
            <button
              type="button"
              onClick={reload}
              className="btn-glass px-4 py-2 text-ui font-medium text-[var(--text)]"
            >
              重试
            </button>
          </div>
        )}

        {subscriptions !== null && subs.length === 0 && (
          <ContentEmptyState
            variant="subscription"
            title="从一部想看的作品开始"
            description={
              canSubscribe
                ? "去发现页挑选一部剧集或电影，打开详情并点击「订阅追踪」，有合适资源时会自动下载入库。"
                : "当前账号暂未开启订阅权限，请联系管理员为你开启。"
            }
            action={
              canSubscribe ? (
                <Link
                  href={"/discover/tv" as Route}
                  className="btn-accent flex items-center gap-1.5 rounded-full px-4 py-2 text-ui font-semibold"
                >
                  <CompassIcon className="size-4" />
                  去发现剧集
                </Link>
              ) : undefined
            }
          />
        )}

        {subs.length > 0 && (
          <>
            {hasHero && (
              <HeroBleed>
                <SubsHomeHero slides={slides} index={heroIndex} onIndexChange={setHeroIndex} />
              </HeroBleed>
            )}
            <div className={`space-y-9 ${hasHero ? "mt-[22px]" : "mt-3"}`}>
              {recent.length > 0 && <SubsHomeRecentRow cards={recent} now={now} />}
              {state.days.some((day) => day.entries.length > 0) && (
                <SubsHomeSchedule days={state.days} />
              )}
              {state.tv.active.length + state.tv.paused.length + state.tv.done.length > 0 && (
                <SubsHomeShelfRow title="剧集订阅" kind="tv" shelf={state.tv} />
              )}
              {state.movie.active.length + state.movie.paused.length + state.movie.done.length > 0 && (
                <SubsHomeShelfRow title="电影订阅" kind="movie" shelf={state.movie} />
              )}
            </div>
          </>
        )}
      </div>
    </div>
  );
}

/** 加载骨架：占住 Hero 与前两排的位置，数据到达原位替换不跳版 */
function LoadingSkeleton() {
  return (
    <div aria-label="订阅首页加载中" className="space-y-7">
      <HeroBleed>
        <div className={`${SUBS_HOME_HERO_HEIGHT} animate-pulse bg-white/[0.04]`} />
      </HeroBleed>
      {["刚刚入库", "剧集订阅"].map((title) => (
        <div key={title}>
          <p className={`text-[20px] font-bold text-[var(--text-faint)] ${SUBS_HOME_INSET}`}>{title}</p>
          <div className={`mt-3 flex gap-3.5 overflow-hidden ${SUBS_HOME_INSET}`}>
            {[0, 1, 2].map((slot) => (
              <div
                key={slot}
                className="aspect-video w-[264px] shrink-0 animate-pulse rounded-[14px] bg-white/[0.05] md:w-[300px]"
              />
            ))}
          </div>
        </div>
      ))}
    </div>
  );
}

function healthMessage(errors: number): string {
  return errors > 0
    ? `${errors} 个媒体库的入库链路有问题，相关订阅暂时无法自动下载入库（已下达的任务会自动重试）`
    : "订阅链路尚未就绪（缺少可用的资源站点或下载器），订阅暂时只能记录意愿";
}

/**
 * 链路体检警示钮：整体 error 时才出现的琥珀色 ⚠，点开先说清楚是什么问题，
 * 再给修复入口（设置 → 概览的体检全景）。订阅不会丢（工单退避重试），
 * 但修好之前无法自动下载入库——原来是首屏一整条横幅，收成这颗钮不再占版面。
 */
function HealthMenu({ errors }: { errors: number }) {
  const router = useRouter();
  const message = healthMessage(errors);
  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger asChild>
        <button
          type="button"
          aria-label={`订阅链路异常：${message}`}
          className={`${PAGE_NAV_BUTTON_CLASS} !text-[var(--warn)]`}
        >
          <WarningIcon className="size-[18px]" />
        </button>
      </DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content
          align="end"
          sideOffset={6}
          collisionPadding={12}
          className="menu-surface z-50 w-[min(18rem,calc(100vw-24px))] p-1"
        >
          <DropdownMenu.Label className="px-3 pb-2 pt-2 text-caption leading-relaxed text-[var(--text-muted)]">
            {message}
          </DropdownMenu.Label>
          <DropdownMenu.Item
            onSelect={() => router.push("/settings/overview" as Route)}
            className="glass-row nav-item flex cursor-pointer items-center gap-2 px-3 py-2 text-sub outline-none data-[highlighted]:!bg-[var(--glass-fill-hover)]"
          >
            <ShieldIcon className="size-4 shrink-0 text-[var(--text-muted)]" />
            查看体检详情与修复入口
          </DropdownMenu.Item>
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );
}

/** 实心警示三角（图标库里没有，只这一处用，内联） */
function WarningIcon({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true" className={className} fill="currentColor">
      <path d="M10.29 3.86a2 2 0 0 1 3.42 0l8.1 13.6A2 2 0 0 1 20.1 20.5H3.9a2 2 0 0 1-1.71-3.04l8.1-13.6ZM12 8.5a1.1 1.1 0 0 0-1.1 1.16l.3 4.7a.8.8 0 0 0 1.6 0l.3-4.7A1.1 1.1 0 0 0 12 8.5Zm0 8.9a1.15 1.15 0 1 0 0-2.3 1.15 1.15 0 0 0 0 2.3Z" />
    </svg>
  );
}

/** 订阅类型切换：沿用发现页的数据源切换样式，让同类操作保持一致。
 *  （Netflix 布局与移动端顶栏共用同一颗胶囊。） */
export function MediaTypeSwitcher({
  value,
  onChange,
  compact = false,
}: {
  value: SubscriptionFilter;
  onChange: (type: SubscriptionFilter) => void;
  compact?: boolean;
}) {
  const labels: Record<SubscriptionFilter, string> = {
    all: "全部",
    tv: "剧集",
    movie: "电影",
  };
  return (
    <div
      className="flex shrink-0 rounded-full border border-white/10 bg-black/35 p-1 backdrop-blur-xl"
      aria-label="订阅类型"
    >
      {(["all", "tv", "movie"] as const).map((type) => (
        <button
          key={type}
          type="button"
          aria-pressed={value === type}
          onClick={() => onChange(type)}
          className={`rounded-full py-1.5 text-sub font-semibold transition ${compact ? "px-2.5" : "px-4"} ${
            value === type
              ? "bg-white/15 text-white shadow-sm"
              : "text-[var(--text-muted)] hover:text-white"
          }`}
        >
          {labels[type]}
        </button>
      ))}
    </div>
  );
}

/** 连续季压成 S1–S3，离散季保留为 S1 · S3，避免悬浮层变成长句。 */
function compactSeasonRange(seasons: number[]): string | undefined {
  const values = [...new Set(seasons)].sort((a, b) => a - b);
  if (values.length === 0) return undefined;
  const ranges: string[] = [];
  let start = values[0];
  let end = values[0];
  for (const value of values.slice(1)) {
    if (value === end + 1) {
      end = value;
      continue;
    }
    ranges.push(start === end ? `S${start}` : `S${start}–S${end}`);
    start = value;
    end = value;
  }
  ranges.push(start === end ? `S${start}` : `S${start}–S${end}`);
  return ranges.join(" · ");
}

/** 把订阅配置压成海报卡片需要的短信息，不再混入运行状态与任务进度。 */
function toVisualItem(
  sub: Subscription,
  ruleSetName?: string,
  libraryName?: string,
): PosterVisualItem {
  const scope = sub.media.kind === "tv" ? compactSeasonRange(sub.selected_seasons) : undefined;
  const configFlow = [ruleSetName, libraryName].filter(Boolean).join("  →  ");
  const ribbon = subscriptionRibbon(sub);
  return {
    id: String(sub.media.tmdb_id),
    source: "tmdb",
    type: sub.media.kind,
    title: sub.media.title,
    year: sub.media.year ?? undefined,
    rating: 0,
    // imageUrl 而非 cachedImageUrl：订阅对象已入库时海报是本地资产的相对路径；
    // 宽度由 PosterCard 按卡宽生成 srcset
    posterUrl: sub.media.poster_url ? imageUrl(sub.media.poster_url) : "",
    genres: scope ? [scope] : undefined,
    overlayMeta: configFlow || undefined,
    ribbon: ribbon?.label,
    ribbonTone: ribbon?.tone,
    // 角标一律用紧凑左上斜标：右上角让给「洗 N」洗版徽标（常驻状态数量比
    // 能力开关更值得占主视觉位）
    ribbonVariant: "compact-left",
    posterFooter: subscriptionCollectionMeta(sub),
  };
}

/** 海报墙单元格：点击进订阅详情分析页（追踪明细 + 活动时间线），而非影片详情。
 *  （Netflix 布局的海报行复用同一张卡：斜标与收录脚注的信息不降级。） */
export function SubscriptionCell({
  sub,
  ruleSetName,
  libraryName,
}: {
  sub: Subscription;
  ruleSetName?: string;
  libraryName?: string;
}) {
  return (
    <PosterCardVisual
      item={toVisualItem(sub, ruleSetName, libraryName)}
      href={`/subscriptions/${sub.id}` as Route}
      action="none"
      revealInfoOnTouch
    />
  );
}
