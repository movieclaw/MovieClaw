"use client";

import type { Route } from "next";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useTranslations } from "next-intl";
import { useEffect, useRef, useState } from "react";

import { ArrowLeftIcon, ChevronDownIcon, ExpandIcon, FilmIcon, HeartIcon, PlayIcon } from "@/components/icons";
import { ReelFilterSheet } from "@/components/reel-filter-sheet";
import type { ReelItem } from "@/lib/api/reels";
import { imageUrl } from "@/lib/image-proxy";

import {
  PlayedGlyph,
  QualityMenu,
  ReelVideo,
  ReelsEmptyState,
  ReelsShareDialog,
  ShareGlyph,
  UnmuteHint,
} from "./reel-parts";
import type { Reels } from "./use-reels";

/**
 * 手机（docs/design/reels.md §6.1）：上下整页滑动，版式同 iOS `ReelsView`——顶栏返回 · 片名 · 筛选，
 * 横带下方画质与看全片（播放时调暗），左下导演与简介，右下收藏、详情、已看、分享。
 * 唯一的 `<video>` 盖在当前页横带的位置上（每页横带同一位置），拖动途中隐去，露出底下的封面。
 */
export function PhoneReels({ reels }: { reels: Reels }) {
  const t = useTranslations();
  const router = useRouter();
  const [scrolling, setScrolling] = useState(false);
  const [filterOpen, setFilterOpen] = useState(false);
  const pager = useRef<HTMLDivElement>(null);
  const settle = useRef(0);
  const { item, status, fileMs } = reels;

  // 换了筛选条件：信息流从头来，翻页回到顶
  useEffect(() => {
    pager.current?.scrollTo({ top: 0 });
  }, [reels.query]);

  const handleScroll = () => {
    const el = pager.current;
    if (!el) return;
    setScrolling(true);
    window.clearTimeout(settle.current);
    settle.current = window.setTimeout(() => {
      setScrolling(false);
      const index = Math.round(el.scrollTop / Math.max(1, el.clientHeight));
      reels.setCurrent((prev) => (prev === index ? prev : index));
    }, 140);
  };

  // 滑到最后的「没有更多了」那页时没有当前条目，状态还是上一条的：视频框（黑底）不能留着盖住那句话
  const showVideo = !scrolling && item !== null && (status === "playing" || status === "paused" || status === "ended");

  return (
    <div className="relative mx-auto h-dvh w-full max-w-[480px] overflow-hidden bg-black text-white [--reel-band:calc(min(100vw,480px)*9/16)]">
      <div
        ref={pager}
        onScroll={handleScroll}
        className="absolute inset-0 snap-y snap-mandatory overflow-y-scroll overscroll-contain [scrollbar-width:none]"
        data-testid="reels-pager"
      >
        {(reels.feed?.items ?? []).map((reel, index) => (
          <ReelPage
            key={`${reel.id}-${index}`}
            reels={reels}
            item={reel}
            active={index === reels.current}
            // 横带下方一行只有停下来（暂停、放完、放不出）时亮；起播、播放都暗，别抢看片的注意力（同 iOS）
            dimmed={index !== reels.current || status === "loading" || status === "playing"}
          />
        ))}
        {reels.feed && !reels.feed.hasMore && reels.feed.items.length > 0 && (
          <div className="flex h-dvh snap-start items-center justify-center text-sub text-[var(--text-muted)]">
            {t("library.reels.noMore")}
          </div>
        )}
      </div>

      <ReelVideo
        reels={reels}
        className="pointer-events-none absolute inset-x-0 z-10 transition-opacity duration-200"
        style={{ top: "calc(46% - var(--reel-band) / 2)", height: "var(--reel-band)", opacity: showVideo ? 1 : 0 }}
      />
      {!scrolling && item && (
        <div className="absolute left-3 z-20" style={{ top: "calc(46% - var(--reel-band) / 2 + 10px)" }}>
          <UnmuteHint reels={reels} />
        </div>
      )}
      {reels.notice && !scrolling && (
        <p
          className="pointer-events-none absolute inset-x-6 z-20 text-center"
          style={{ top: "calc(46% - var(--reel-band) / 2 - 44px)" }}
          data-testid="reels-notice"
        >
          <span className="inline-block rounded-full bg-black/60 px-3 py-1.5 text-caption text-white/90 backdrop-blur">{reels.notice}</span>
        </p>
      )}
      {item && status === "loading" && !scrolling && (
        <div className="pointer-events-none absolute inset-x-0 z-10 grid place-items-center" style={{ top: "calc(46% - 14px)" }}>
          <span className="size-7 animate-spin rounded-full border-2 border-white/25 border-t-white/90" />
        </div>
      )}
      {item && (status === "paused" || status === "ended") && !scrolling && (
        <div className="pointer-events-none absolute inset-x-0 z-10 grid place-items-center" style={{ top: "calc(46% - 28px)" }}>
          <span className="grid size-14 place-items-center rounded-full bg-black/45 backdrop-blur">
            {status === "ended" ? (
              <span className="text-caption font-semibold">{t("library.reels.replay")}</span>
            ) : (
              <PlayIcon className="size-6" />
            )}
          </span>
        </div>
      )}
      {item && status === "failed" && !scrolling && (
        <p className="pointer-events-none absolute inset-x-6 z-10 text-center text-sub text-white/80" style={{ top: "calc(46% - 10px)" }}>
          {t("library.reels.clipFailed")}
        </p>
      )}
      {/* 进度线：只在暂停时出现（同 iOS） */}
      {item && status === "paused" && (
        <div className="pointer-events-none absolute inset-x-0 bottom-0 z-20 h-0.5 bg-white/15 pb-[env(safe-area-inset-bottom)]">
          <div
            className="h-0.5 bg-white/80"
            style={{
              width: `${Math.min(100, Math.max(0, ((fileMs - item.segment.start_ms) / Math.max(1, item.segment.end_ms - item.segment.start_ms)) * 100))}%`,
            }}
          />
        </div>
      )}

      {/* 顶栏：返回 · 片名 · 筛选 */}
      <div className="absolute inset-x-0 top-0 z-30 flex items-center gap-3 px-4 pt-[max(12px,env(safe-area-inset-top))]">
        <button
          type="button"
          aria-label={t("common.back")}
          onClick={() => (window.history.length > 1 ? router.back() : router.push("/library" as Route))}
          className="grid size-11 shrink-0 place-items-center rounded-full bg-white/[0.12] backdrop-blur-xl"
        >
          <ArrowLeftIcon className="size-5" />
        </button>
        <div className="min-w-0 flex-1 rounded-full bg-white/[0.12] px-4 py-1.5 text-center backdrop-blur-xl">
          <p className="truncate text-sub font-semibold leading-5">{item?.title.name ?? t("library.reels.title")}</p>
          {item?.title.year && <p className="text-caption leading-4 text-white/60">{item.title.year}</p>}
        </div>
        <button
          type="button"
          aria-label={t("library.reels.filterLabel", { value: reels.filterTitle })}
          onClick={() => setFilterOpen(true)}
          data-testid="reels-filter"
          className="flex h-11 max-w-[8.5rem] shrink-0 items-center gap-1.5 rounded-full bg-white/[0.12] px-4 backdrop-blur-xl"
        >
          <span className="truncate text-sub font-semibold">{reels.filterTitle}</span>
          <ChevronDownIcon className="size-3.5 shrink-0 text-white/70" />
        </button>
      </div>

      {(reels.feed === null || reels.empty || reels.loadFailed) && <ReelsEmptyState reels={reels} />}

      <ReelFilterSheet
        open={filterOpen}
        onClose={() => setFilterOpen(false)}
        facets={reels.facets}
        query={reels.query}
        onApply={reels.applyFilter}
      />
      <ReelsShareDialog reels={reels} />
    </div>
  );
}

/** 片段的一页：封面横带、横带下方画质与看全片、左下导演与简介、右侧一列按钮 */
function ReelPage({ reels, item, active, dimmed }: { reels: Reels; item: ReelItem; active: boolean; dimmed: boolean }) {
  const t = useTranslations();
  const cover = item.cover_url ?? item.title.backdrop_url;
  const episode = item.title.episode;
  const overview = episode?.overview ?? item.title.overview;
  const person = item.title.directors[0];
  const quality = reels.qualityFor(item);
  const favorite = reels.isFavorite(item);
  const played = reels.isPlayed(item);
  const progress = reels.progressOf(item);
  // 横带下方的描边小胶囊：暗时只降颜色不隐藏，按钮始终在原位、暗着也能点
  const capsule = `flex items-center gap-1.5 rounded-full border px-3.5 py-1.5 text-caption font-semibold transition-colors duration-300 ${
    dimmed ? "border-white/10 text-white/30" : "border-white/35 text-white/90"
  }`;
  return (
    <section
      className="relative h-dvh w-full snap-start snap-always overflow-hidden"
      onClick={reels.togglePlay}
      data-testid="reels-page"
      data-active={active ? "" : undefined}
    >
      {cover && (
        // 封面：出画前横带里先放它；身后铺一层模糊放大的同一张，不留死黑
        <>
          <img src={imageUrl(cover, { width: 160 })} alt="" aria-hidden className="absolute inset-0 size-full scale-110 object-cover opacity-35 blur-2xl" />
          <img
            src={imageUrl(cover, { width: 960 })}
            alt=""
            className="absolute inset-x-0 w-full object-cover"
            style={{ top: "calc(46% - var(--reel-band) / 2)", height: "var(--reel-band)" }}
          />
        </>
      )}
      {/* 横带下方一行：画质在左、看全片在右（同 iOS 的画质 · 全屏观看） */}
      <div
        className="absolute inset-x-0 z-20 flex justify-center gap-2.5"
        style={{ top: "calc(46% + var(--reel-band) / 2 + 14px)" }}
        onClick={(event) => event.stopPropagation()}
      >
        {quality && <QualityMenu quality={quality} className={capsule} />}
        <Link href={reels.fullHref(item) as Route} className={capsule} data-testid="reels-watch-full">
          <ExpandIcon className="size-3.5" />
          {t("library.reels.watchFull")}
        </Link>
      </div>
      <div className="absolute inset-x-0 bottom-0 bg-gradient-to-t from-black/80 via-black/40 to-transparent px-4 pb-[max(24px,env(safe-area-inset-bottom))] pt-24">
        <div className="flex items-end gap-4">
          <div className="min-w-0 flex-1">
            {person && (
              <p className="mb-1.5 text-sub font-semibold">
                {person.name}
                <span className="ml-2 font-normal text-white/60">
                  {item.title.kind === "tv" ? t("library.reels.creator") : t("library.reels.director")}
                </span>
              </p>
            )}
            {overview && (
              <p className="line-clamp-3 text-sub leading-6 text-white/85">
                {episode && (
                  <span className="mr-1 font-semibold">
                    {t("library.reels.episode", { season: episode.season, episode: episode.episode })}
                    {episode.name ? `「${episode.name}」` : ""}
                  </span>
                )}
                {overview}
              </p>
            )}
          </div>
          {/* 右下角一列无底色的白色按钮（同 iOS：带投影，亮画面上也看得清；声音同 App 用音量键，不占一个按钮） */}
          <div
            className="flex shrink-0 flex-col items-center gap-4 pb-1 [filter:drop-shadow(0_1px_3px_rgba(0,0,0,0.55))]"
            onClick={(event) => event.stopPropagation()}
          >
            <ActionButton
              label={t("library.gallery.favorite")}
              onClick={() => void reels.toggleFavorite(item)}
              pressed={favorite}
              testId="reels-favorite"
            >
              <HeartIcon className={favorite ? "size-7 text-[var(--danger)]" : "size-7"} fill={favorite ? "currentColor" : "none"} />
            </ActionButton>
            <Link href={reels.detailHref(item) as Route} className="grid justify-items-center gap-1 text-caption" data-testid="reels-detail">
              <FilmIcon className="size-7" />
              {t("library.reels.detail")}
            </Link>
            <ActionButton
              label={t("library.reels.played")}
              onClick={() => void reels.togglePlayed(item)}
              pressed={played}
              testId="reels-played"
              valueText={played ? t("library.reels.watched") : progress ? t("library.reels.watchedPercent", { percent: progress }) : t("library.reels.notWatched")}
            >
              <PlayedGlyph played={played} progress={progress} />
            </ActionButton>
            <ActionButton label={t("library.manage.shares")} onClick={() => reels.share(item)} testId="reels-share">
              <ShareGlyph />
            </ActionButton>
          </div>
        </div>
      </div>
    </section>
  );
}

function ActionButton({
  label,
  onClick,
  pressed,
  testId,
  valueText,
  children,
}: {
  label: string;
  onClick: () => void;
  pressed?: boolean;
  testId: string;
  /** 读屏补一句当前状态（已看的进度） */
  valueText?: string;
  children: React.ReactNode;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={pressed}
      aria-label={valueText ? `${label} · ${valueText}` : undefined}
      data-testid={testId}
      className="grid justify-items-center gap-1 text-caption"
    >
      {children}
      <span>{label}</span>
    </button>
  );
}
