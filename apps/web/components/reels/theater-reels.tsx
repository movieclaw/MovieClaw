"use client";

import type { Route } from "next";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useTranslations } from "next-intl";
import { useEffect, useRef, useState, type ReactNode } from "react";

import { MultiFilterMenu } from "@/components/filter-menu";
import { ArrowLeftIcon, ExpandIcon, FilmIcon, HeartIcon, PlayIcon, ShrinkIcon } from "@/components/icons";
import { reelFacetValues } from "@/components/reel-filter-sheet";
import type { ReelItem } from "@/lib/api/reels";
import { imageUrl } from "@/lib/image-proxy";
import {
  type ReelDimension,
  type ReelKeyAction,
  REEL_DIMENSIONS,
  WheelPager,
  loadReelsAutoplay,
  reelFilterValues,
  reelKeyAction,
  saveReelsAutoplay,
  toggleReelFilter,
  watchOnly,
} from "@/lib/reels";

import {
  PlayedGlyph,
  QualityMenu,
  ReelVideo,
  ReelsEmptyState,
  ReelsShareDialog,
  ShareGlyph,
  SpeakerGlyph,
  UnmuteHint,
} from "./reel-parts";
import type { Reels } from "./use-reels";

/** 放完后自动接下一条前倒数几秒 */
const AUTOPLAY_SECONDS = 3;
/** 鼠标停住多久收起控制条与光标 */
const IDLE_MS = 2500;

/**
 * 电脑上的片段「放映厅」（docs/design/reels.md §6.2）：片段都是 16:9 横片，手机上只占一条横带，电脑屏幕反而是
 * 最好的舞台，所以不照搬竖滑——左边一块大画面，右边是片子的信息、操作与「接下来」，筛选平铺在顶栏。
 *
 * - 换条：滚轮 / 触控板一次手势一条（`WheelPager`）、键盘 ↑↓（J / K）、画面右侧的上下圆钮、点「接下来」；
 * - 播放：点画面暂停 / 继续，空格同；M 静音、F 全屏、回车从当前位置看全片；鼠标停住 2.5 秒收起控制条与光标；
 * - 放完：倒数 3 秒自动接下一条（坐着看更像一个频道），可取消、可关（记在本机）；放不出的也这样跳过。
 */
export function TheaterReels({ reels }: { reels: Reels }) {
  const t = useTranslations();
  const router = useRouter();
  const stage = useRef<HTMLDivElement>(null);
  const wheel = useRef(new WheelPager());
  const idleTimer = useRef(0);
  const [idle, setIdle] = useState(false);
  const [fullscreen, setFullscreen] = useState(false);
  const [autoplay, setAutoplay] = useState(() => loadReelsAutoplay());
  const [countdown, setCountdown] = useState<number | null>(null);
  /** 这一条放完后点了「取消」：不再自动接下一条 */
  const [stayOn, setStayOn] = useState<string | null>(null);
  const { item, status, feed, current } = reels;
  const count = feed?.items.length ?? 0;
  const hasNext = current < count - 1;

  // 计时器、键盘回调里要用最新的那一份（不为它们重挂监听）
  const latest = useRef({ reels, hasNext });
  latest.current = { reels, hasNext };

  // 放完（或放不出）自动接下一条：倒数几秒（取消了、关了、没有下一条就停在这里，点画面重播）
  useEffect(() => {
    if ((status !== "ended" && status !== "failed") || !autoplay || !hasNext || stayOn === item?.id) {
      setCountdown(null);
      return;
    }
    let left = AUTOPLAY_SECONDS;
    setCountdown(left);
    const timer = window.setInterval(() => {
      left -= 1;
      if (left > 0) return setCountdown(left);
      window.clearInterval(timer);
      setCountdown(null);
      latest.current.reels.go(current + 1);
    }, 1000);
    return () => window.clearInterval(timer);
  }, [status, autoplay, hasNext, stayOn, item?.id, current]);

  // 播放中鼠标停住：收起控制条与光标
  const wake = () => {
    setIdle(false);
    window.clearTimeout(idleTimer.current);
    idleTimer.current = window.setTimeout(() => setIdle(true), IDLE_MS);
  };
  useEffect(() => {
    if (status === "playing") {
      window.clearTimeout(idleTimer.current);
      idleTimer.current = window.setTimeout(() => setIdle(true), IDLE_MS);
    }
    return () => window.clearTimeout(idleTimer.current);
  }, [status, current]);
  const controlsShown = !idle || status !== "playing";

  useEffect(() => {
    const onChange = () => setFullscreen(document.fullscreenElement === stage.current);
    document.addEventListener("fullscreenchange", onChange);
    return () => document.removeEventListener("fullscreenchange", onChange);
  }, []);
  const toggleFullscreen = () => {
    if (document.fullscreenElement) void document.exitFullscreen().catch(() => undefined);
    else void stage.current?.requestFullscreen?.().catch(() => undefined);
  };

  // 键盘：焦点在输入框、展开的菜单、弹窗里时不抢；空格 / 回车落在按钮、链接上时让它们自己处理。
  // 在捕获阶段先接：用过顶栏的筛选下拉后焦点停在下拉按钮上，按 ↓ 应该换一条，而不是又把菜单打开
  const onKeyAction = useRef<(action: ReelKeyAction) => void>(() => {});
  onKeyAction.current = (action) => {
    const { reels: now } = latest.current;
    if (action === "next") now.go(now.current + 1);
    else if (action === "prev") now.go(now.current - 1);
    else if (action === "toggle") now.togglePlay();
    else if (action === "mute") now.toggleMute();
    else if (action === "fullscreen") toggleFullscreen();
    else if (action === "watch" && now.item) router.push(now.fullHref(now.item) as Route);
  };
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey) return;
      if (latest.current.reels.sharing) return;
      const target = event.target instanceof HTMLElement ? event.target : null;
      if (target?.closest("input, textarea, select, [contenteditable=true], [role=menu], [role=dialog], [role=listbox]")) return;
      const action = reelKeyAction(event.key);
      if (!action) return;
      if ((action === "toggle" || action === "watch") && target?.closest("button, a")) return;
      event.preventDefault();
      onKeyAction.current(action);
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, []);

  const onWheel = (event: React.WheelEvent) => {
    const step = wheel.current.push(event.deltaMode === 1 ? event.deltaY * 16 : event.deltaY, event.timeStamp);
    if (step) reels.go(current + step);
  };

  const cover = item ? (item.cover_url ?? item.title.backdrop_url) : null;
  const showVideo = status === "playing" || status === "paused" || status === "ended";
  const length = item ? item.segment.end_ms - item.segment.start_ms : 0;
  const elapsed = item ? Math.min(length, Math.max(0, reels.fileMs - item.segment.start_ms)) : 0;
  const quality = item ? reels.qualityFor(item) : null;
  const upNext = (feed?.items ?? []).slice(current + 1, current + 5);
  const roundButton =
    "grid size-11 place-items-center rounded-full bg-white/[0.08] text-white/85 transition hover:bg-white/[0.16] disabled:pointer-events-none disabled:opacity-30";

  return (
    <div className="relative flex h-dvh w-full flex-col overflow-hidden bg-[#050608] text-white" data-testid="reels-theater">
      <header className="relative z-30 flex shrink-0 items-center gap-4 px-6 pb-3 pt-4">
        <button
          type="button"
          aria-label={t("common.back")}
          onClick={() => (window.history.length > 1 ? router.back() : router.push("/library" as Route))}
          className="grid size-10 shrink-0 place-items-center rounded-full bg-white/[0.08] transition hover:bg-white/[0.16]"
        >
          <ArrowLeftIcon className="size-5" />
        </button>
        <h1 className="shrink-0 text-title-sm font-semibold">{t("library.reels.title")}</h1>
        <TheaterFilters reels={reels} />
      </header>

      <div className="flex min-h-0 flex-1 gap-6 px-6 pb-6 max-lg:flex-col">
        {/* 画面与右侧信息顶端对齐；上下圆钮对着画面的中线 */}
        <section className="flex min-h-0 min-w-0 flex-1 items-start justify-center max-lg:flex-none" onWheel={onWheel}>
          <div className="flex w-full items-center justify-center gap-4">
            <div
              ref={stage}
              onMouseMove={wake}
              onClick={reels.togglePlay}
              className={`relative aspect-video w-full max-w-[calc((100dvh-7.5rem)*16/9)] overflow-hidden rounded-2xl bg-black max-lg:max-w-[calc(56dvh*16/9)] ${
                controlsShown ? "" : "cursor-none"
              }`}
              data-testid="reels-stage"
            >
              {cover && <img key={item?.id} src={imageUrl(cover, { width: 1280 })} alt="" className="absolute inset-0 size-full object-cover" />}
              <ReelVideo
                reels={reels}
                className="pointer-events-none absolute inset-0 transition-opacity duration-200"
                style={{ opacity: showVideo ? 1 : 0 }}
                // 控制条展开时字幕让到它上面（控制条约 72px 高）
                avoidBottomPx={controlsShown && item ? 76 : 0}
              />
              {item && status === "loading" && (
                <div className="pointer-events-none absolute inset-0 grid place-items-center bg-black/25">
                  <span className="size-9 animate-spin rounded-full border-2 border-white/25 border-t-white/90" />
                </div>
              )}
              {item && status === "failed" && countdown === null && (
                <p className="pointer-events-none absolute inset-0 grid place-items-center bg-black/55 px-8 text-center text-body text-white/85">
                  {t("library.reels.clipFailedDesktop")}
                </p>
              )}
              {item && (status === "paused" || (status === "ended" && countdown === null)) && (
                <div className="pointer-events-none absolute inset-0 grid place-items-center">
                  <span className="grid size-16 place-items-center rounded-full bg-black/45 backdrop-blur">
                    {status === "ended" ? (
                      <span className="text-caption font-semibold">{t("library.reels.replay")}</span>
                    ) : (
                      <PlayIcon className="size-7" />
                    )}
                  </span>
                </div>
              )}
              {countdown !== null && (
                <div className="absolute inset-0 grid place-items-center bg-black/55" onClick={(event) => event.stopPropagation()} data-testid="reels-countdown">
                  <div className="grid justify-items-center gap-3">
                    {status === "failed" && <p className="text-body text-white/75">{t("library.reels.clipFailedShort")}</p>}
                    <p className="text-title-sm font-semibold">{t("library.reels.autoplayCountdown", { seconds: countdown })}</p>
                    <div className="flex gap-2">
                      <button type="button" className="btn-accent rounded-full px-4 py-1.5 text-ui font-semibold" onClick={() => reels.go(current + 1)}>
                        {t("library.reels.playNext")}
                      </button>
                      <button type="button" className="btn-glass rounded-full px-4 py-1.5 text-ui" onClick={() => setStayOn(item?.id ?? null)}>
                        {t("common.cancel")}
                      </button>
                    </div>
                  </div>
                </div>
              )}
              <UnmuteHint reels={reels} wording="click" className="absolute left-4 top-4 z-20" />
              {reels.notice && (
                <p className="pointer-events-none absolute inset-x-6 top-4 z-20 text-center" data-testid="reels-notice">
                  <span className="inline-block rounded-full bg-black/60 px-3 py-1.5 text-caption text-white/90 backdrop-blur">{reels.notice}</span>
                </p>
              )}
              {/* 控制条：鼠标停住时收起 */}
              {item && (
                <div
                  className={`absolute inset-x-0 bottom-0 z-20 bg-gradient-to-t from-black/75 to-transparent px-4 pb-3 pt-12 transition-opacity duration-300 ${
                    controlsShown ? "opacity-100" : "pointer-events-none opacity-0"
                  }`}
                  onClick={(event) => event.stopPropagation()}
                >
                  <div className="h-1 overflow-hidden rounded-full bg-white/20">
                    <div className="h-full bg-white" style={{ width: `${length ? (elapsed / length) * 100 : 0}%` }} />
                  </div>
                  <div className="mt-2 flex items-center gap-1">
                    <StageButton
                      label={status === "playing" ? t("player.controls.pause") : t("player.controls.play")}
                      onClick={reels.togglePlay}
                    >
                      {status === "playing" ? <PauseGlyph /> : <PlayIcon className="size-5" />}
                    </StageButton>
                    <StageButton
                      label={reels.muted ? t("library.reels.unmute") : t("library.reels.mute")}
                      onClick={reels.toggleMute}
                      testId="reels-mute"
                    >
                      <SpeakerGlyph muted={reels.muted} className="size-5" />
                    </StageButton>
                    <span className="ml-1 text-caption tabular-nums text-white/70">
                      {clock(elapsed)} / {clock(length)}
                    </span>
                    <span className="flex-1" />
                    {quality && (
                      <QualityMenu
                        quality={quality}
                        className="flex items-center gap-1 rounded-full px-3 py-1.5 text-caption font-semibold text-white/85 transition hover:bg-white/[0.12]"
                      />
                    )}
                    <StageButton
                      label={fullscreen ? t("player.controls.exitFullscreen") : t("player.controls.fullscreen")}
                      onClick={toggleFullscreen}
                    >
                      {fullscreen ? <ShrinkIcon className="size-5" /> : <ExpandIcon className="size-5" />}
                    </StageButton>
                  </div>
                </div>
              )}
            </div>
            {/* 上一条 / 下一条（同 YouTube Shorts 桌面版的上下圆钮） */}
            <div className="flex shrink-0 flex-col gap-3">
              <button type="button" className={roundButton} disabled={current <= 0} onClick={() => reels.go(current - 1)} aria-label={t("library.reels.prev")} data-testid="reels-prev">
                <Chevron up />
              </button>
              <button type="button" className={roundButton} disabled={!hasNext} onClick={() => reels.go(current + 1)} aria-label={t("library.reels.next")} data-testid="reels-next">
                <Chevron />
              </button>
            </div>
          </div>
        </section>

        <aside className="flex w-[340px] shrink-0 flex-col gap-5 overflow-y-auto pr-1 max-lg:min-h-0 max-lg:w-full max-lg:flex-1 [scrollbar-width:thin]">
          {item && <TheaterInfo reels={reels} item={item} />}
          <div className="border-t border-white/10 pt-4">
            <div className="flex items-center justify-between gap-3">
              <h2 className="text-ui font-semibold text-white/85">{t("library.reels.upNext")}</h2>
              <button
                type="button"
                role="switch"
                aria-checked={autoplay}
                onClick={() => {
                  saveReelsAutoplay(!autoplay);
                  setAutoplay(!autoplay);
                }}
                className="flex items-center gap-2 text-caption text-white/60"
                data-testid="reels-autoplay"
              >
                {t("library.reels.autoplay")}
                <span className={`relative h-5 w-9 rounded-full transition ${autoplay ? "bg-[var(--info)]" : "bg-white/20"}`}>
                  <span className={`absolute top-0.5 size-4 rounded-full bg-white shadow transition-all ${autoplay ? "left-[18px]" : "left-0.5"}`} />
                </span>
              </button>
            </div>
            <ul className="mt-3 grid gap-1.5">
              {upNext.map((reel, index) => (
                <li key={`${reel.id}-${index}`}>
                  <UpNextRow reel={reel} onClick={() => reels.go(current + 1 + index)} />
                </li>
              ))}
            </ul>
            {feed && !feed.hasMore && !hasNext && count > 0 && (
              <p className="mt-2 text-caption text-[var(--text-faint)]">{t("library.reels.noMore")}</p>
            )}
          </div>
          <p className="mt-auto text-caption leading-5 text-white/35">{t("library.reels.shortcuts")}</p>
        </aside>
      </div>

      {(feed === null || reels.empty || reels.loadFailed) && <ReelsEmptyState reels={reels} />}
      <ReelsShareDialog reels={reels} />
    </div>
  );
}

/** 右侧信息：片名、年份 · 类型 · 评分，导演、简介，看全片 / 详情，收藏 / 已看 / 分享 */
function TheaterInfo({ reels, item }: { reels: Reels; item: ReelItem }) {
  const t = useTranslations();
  const { title } = item;
  const episode = title.episode;
  const overview = episode?.overview ?? title.overview;
  const person = title.directors[0];
  const favorite = reels.isFavorite(item);
  const played = reels.isPlayed(item);
  const progress = reels.progressOf(item);
  const meta = [title.year, title.genres.join(" / "), title.rating ? `★ ${title.rating.toFixed(1)}` : null].filter(Boolean);
  return (
    <div>
      <h2 className="text-title-lg font-semibold leading-tight" data-testid="reels-title">
        {title.name}
      </h2>
      {meta.length > 0 && <p className="mt-1.5 text-ui text-white/55">{meta.join(" · ")}</p>}
      {episode && (
        <p className="mt-3 text-ui font-semibold">
          {t("library.reels.episode", { season: episode.season, episode: episode.episode })}
          {episode.name ? `「${episode.name}」` : ""}
        </p>
      )}
      {person && (
        <p className="mt-2 text-ui">
          {title.directors.map((p) => p.name).join(" / ")}
          <span className="ml-2 text-white/50">{title.kind === "tv" ? t("library.reels.creator") : t("library.reels.director")}</span>
        </p>
      )}
      {overview && <p className="mt-3 line-clamp-6 text-ui leading-6 text-white/75">{overview}</p>}
      <div className="mt-5 flex gap-2">
        <Link
          href={reels.fullHref(item) as Route}
          className="btn-accent flex flex-1 items-center justify-center gap-1.5 rounded-full px-4 py-2 text-ui font-semibold"
          data-testid="reels-watch-full"
        >
          <PlayIcon className="size-4" />
          {t("library.reels.watchFull")}
        </Link>
        <Link
          href={reels.detailHref(item) as Route}
          className="btn-glass flex flex-1 items-center justify-center gap-1.5 rounded-full px-4 py-2 text-ui"
          data-testid="reels-detail"
        >
          <FilmIcon className="size-4" />
          {t("library.reels.detail")}
        </Link>
      </div>
      <div className="mt-2 grid grid-cols-3 gap-2">
        <PanelAction label={t("library.gallery.favorite")} pressed={favorite} onClick={() => void reels.toggleFavorite(item)} testId="reels-favorite">
          <HeartIcon className={favorite ? "size-5 text-[var(--danger)]" : "size-5"} fill={favorite ? "currentColor" : "none"} />
        </PanelAction>
        <PanelAction
          label={t("library.reels.played")}
          pressed={played}
          onClick={() => void reels.togglePlayed(item)}
          testId="reels-played"
          valueText={played ? t("library.reels.watched") : progress ? t("library.reels.watchedPercent", { percent: progress }) : t("library.reels.notWatched")}
        >
          <PlayedGlyph played={played} progress={progress} className="size-5" />
        </PanelAction>
        <PanelAction label={t("library.manage.shares")} onClick={() => reels.share(item)} testId="reels-share">
          <ShareGlyph className="size-5" />
        </PanelAction>
      </div>
    </div>
  );
}

/**
 * 顶栏的筛选：电影 / 剧集一组分段，其余维度用媒体库筛选条同一种下拉（带剩余部数、为 0 置灰），
 * 规则同手机的抽屉与 iOS `ReelFilterMenu`；点一下立刻生效。
 */
function TheaterFilters({ reels }: { reels: Reels }) {
  const t = useTranslations();
  const { facets, query } = reels;
  const { filter, kind } = query;
  const kinds = reelFacetValues(facets, "kinds");
  const filterable = kind !== "video" && (facets?.filterable ?? true);
  const unwatched = reelFacetValues(facets, "watch")[0];
  const titles: Record<ReelDimension, string> = {
    genres: t("library.filters.genres"),
    decades: t("library.filters.decades"),
    countries: t("library.filters.regions"),
    rating_gte: t("library.filters.rating"),
    runtimes: t("library.filters.runtime"),
  };
  const pill = (on: boolean) =>
    `flex h-8 shrink-0 items-center gap-1.5 rounded-full px-3 text-caption transition disabled:pointer-events-none disabled:opacity-30 ${
      on ? "bg-white/[0.16] font-semibold text-white" : "text-white/65 hover:bg-white/[0.08] hover:text-white"
    }`;
  return (
    <div className="flex min-w-0 flex-1 items-center gap-2 overflow-x-auto py-1 [scrollbar-width:none]" data-testid="reels-filters">
      {kinds.length > 0 && (
        <div className="flex shrink-0 items-center gap-0.5 rounded-full bg-white/[0.05] p-0.5">
          <button type="button" className={pill(kind === null)} onClick={() => reels.applyFilter({ filter, kind: null })}>
            {t("media.filters.all")}
          </button>
          {kinds.map((value) => (
            <button
              key={value.value}
              type="button"
              className={pill(kind === value.value)}
              disabled={value.count === 0 && kind !== value.value}
              // 切到「其他」时清掉不适用的条件，只留观看状态
              onClick={() => reels.applyFilter({ filter: value.value === "video" ? watchOnly(filter) : filter, kind: value.value })}
            >
              {value.label}
            </button>
          ))}
        </div>
      )}
      {filterable &&
        REEL_DIMENSIONS.map((key) => (
          <MultiFilterMenu
            key={key}
            label={titles[key]}
            selected={reelFilterValues(filter, key)}
            options={reelFacetValues(facets, key)}
            onToggle={(value) => reels.applyFilter({ filter: toggleReelFilter(filter, key, value), kind })}
          />
        ))}
      <button
        type="button"
        className={`${pill(filter.watch === "unwatched")} border border-white/10`}
        disabled={unwatched?.count === 0 && filter.watch !== "unwatched"}
        onClick={() => reels.applyFilter({ filter: toggleReelFilter(filter, "watch", "unwatched"), kind })}
        data-testid="reels-filter-unwatched"
      >
        {t("library.rows.onlyUnwatched")}
        {unwatched && <span className="tabular-nums text-white/45">{unwatched.count}</span>}
      </button>
      {reels.filtered && (
        <button
          type="button"
          className="shrink-0 px-2 text-caption font-semibold text-[var(--danger)]"
          onClick={() => reels.applyFilter({ filter: {}, kind: null })}
          data-testid="reels-filter-clear"
        >
          {t("media.discovery.clearFilters")}
        </button>
      )}
      {facets && (
        <span className="ml-auto shrink-0 pl-2 text-caption text-white/45" data-testid="reels-filter-total">
          {t("library.reels.filterTotal", { count: facets.total })}
        </span>
      )}
    </div>
  );
}

function UpNextRow({ reel, onClick }: { reel: ReelItem; onClick: () => void }) {
  const t = useTranslations();
  const cover = reel.cover_url ?? reel.title.backdrop_url;
  const episode = reel.title.episode;
  return (
    <button
      type="button"
      onClick={onClick}
      className="flex w-full items-center gap-3 rounded-xl p-1.5 text-left transition hover:bg-white/[0.06]"
      data-testid="reels-upnext"
    >
      <span className="relative aspect-video w-28 shrink-0 overflow-hidden rounded-lg bg-white/[0.06]">
        {cover && <img src={imageUrl(cover, { width: 240 })} alt="" className="size-full object-cover" />}
      </span>
      <span className="min-w-0">
        <span className="block truncate text-ui font-semibold">{reel.title.name}</span>
        <span className="block truncate text-caption text-white/50">
          {episode ? t("library.reels.episode", { season: episode.season, episode: episode.episode }) : reel.title.year}
        </span>
      </span>
    </button>
  );
}

function PanelAction({
  label,
  pressed,
  onClick,
  testId,
  valueText,
  children,
}: {
  label: string;
  pressed?: boolean;
  onClick: () => void;
  testId: string;
  /** 读屏补一句当前状态（已看的进度） */
  valueText?: string;
  children: ReactNode;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={pressed}
      aria-label={valueText ? `${label} · ${valueText}` : undefined}
      className="flex items-center justify-center gap-1.5 rounded-full bg-white/[0.06] px-3 py-2 text-ui transition hover:bg-white/[0.12]"
      data-testid={testId}
    >
      {children}
      <span>{label}</span>
    </button>
  );
}

function StageButton({
  label,
  onClick,
  testId,
  children,
}: {
  label: string;
  onClick: () => void;
  testId?: string;
  children: ReactNode;
}) {
  return (
    <button
      type="button"
      aria-label={label}
      title={label}
      onClick={onClick}
      className="grid size-9 place-items-center rounded-full text-white/90 transition hover:bg-white/[0.12]"
      data-testid={testId}
    >
      {children}
    </button>
  );
}

function PauseGlyph() {
  return (
    <svg viewBox="0 0 24 24" className="size-5" fill="currentColor" aria-hidden>
      <rect x="6" y="5" width="4" height="14" rx="1" />
      <rect x="14" y="5" width="4" height="14" rx="1" />
    </svg>
  );
}

function Chevron({ up = false }: { up?: boolean }) {
  return (
    <svg viewBox="0 0 24 24" className="size-5" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <path d={up ? "m6 15 6-6 6 6" : "m6 9 6 6 6-6"} />
    </svg>
  );
}

/** 片段内的时间：0:12 */
function clock(ms: number): string {
  const seconds = Math.floor(ms / 1000);
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}
