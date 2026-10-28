"use client";

import type { Route } from "next";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useTranslations } from "next-intl";
import { useCallback, useEffect, useRef, useState } from "react";

import { ArrowLeftIcon, ExpandIcon, InfoIcon, PlayIcon } from "@/components/icons";
import { resolveStreamUrl, pingPlaybackSession, stopPlaybackSession } from "@/lib/api/playback";
import {
  type ReelEvent,
  type ReelEventKind,
  type ReelFeed,
  type ReelItem,
  fetchReelFeed,
  reportReelEvents,
  startReelSession,
} from "@/lib/api/reels";
import { imageUrl } from "@/lib/image-proxy";
import { getCapabilitySnapshot } from "@/lib/player/capability";
import { createEngine, type PlaybackEngine } from "@/lib/player/engine";
import { playHref } from "@/lib/player/play-links";
import { resolvePlaybackMode } from "@/lib/player/playback-mode";
import { toSessionSeconds } from "@/lib/player/timeline";

type Status = "loading" | "playing" | "paused" | "ended" | "failed";

interface FeedState {
  seed: number;
  items: ReelItem[];
  nextOffset: number;
  hasMore: boolean;
  clips: ReelFeed["clips"];
}

/**
 * 片段（docs/design/reels.md）：上下整页滑动，每页是片库里一部片的 30～60 秒（同 iOS `ReelsView` 的版式，
 * 网页一期只做核心：翻页、点按暂停、声音、详情、看全片；筛选、收藏 / 已看 / 分享、画质下一轮再加）。
 *
 * 放法：预切小片（clip）`<video>` 直接放；没切的开一个播放会话从片段起点起播（同 iPhone 限画质时），
 * 由会话决定直出 / 转封装 / 转码，引擎复用正片播放器那一层（engine.ts）。会话不带设备标识与播放编号：
 * 刷片不进活动页、不写续播点。
 *
 * **只有一个 `<video>`**，盖在当前页横带的位置上，换页时换源：iOS 有声自动播放要用户手势，同一个元素被
 * 手势放过一次后换源接着放才不会被拦。一开始静音起播，点「开启声音」后整段刷片都有声。
 */
export function ReelsView() {
  const t = useTranslations();
  const router = useRouter();
  const [feed, setFeed] = useState<FeedState | null>(null);
  const [loadFailed, setLoadFailed] = useState(false);
  const [current, setCurrent] = useState(0);
  const [scrolling, setScrolling] = useState(false);
  const [status, setStatus] = useState<Status>("loading");
  const [muted, setMuted] = useState(true);
  const [fileMs, setFileMs] = useState(0);
  const pager = useRef<HTMLDivElement>(null);
  const video = useRef<HTMLVideoElement>(null);
  const loadingMore = useRef(false);
  const events = useRef<ReelEvent[]>([]);
  const replay = useRef<() => void>(() => {});

  const load = useCallback(async (more: FeedState | null) => {
    try {
      const page = await fetchReelFeed(more ? { seed: more.seed, offset: more.nextOffset } : {});
      setLoadFailed(false);
      setFeed((prev) => ({
        seed: page.seed,
        items: more && prev ? [...prev.items, ...page.items] : page.items,
        nextOffset: page.next_offset,
        hasMore: page.has_more,
        clips: page.clips,
      }));
    } catch {
      if (!more) setLoadFailed(true);
    }
  }, []);

  useEffect(() => {
    void load(null);
  }, [load]);

  // 快刷到底时接着取下一页
  useEffect(() => {
    if (!feed || !feed.hasMore || loadingMore.current || current < feed.items.length - 3) return;
    loadingMore.current = true;
    void load(feed).finally(() => {
      loadingMore.current = false;
    });
  }, [current, feed, load]);

  // 离开页面时把没报的事件报掉
  useEffect(() => () => void reportReelEvents(events.current.splice(0)), []);

  const item = feed?.items[current] ?? null;

  // 换到哪一条就放哪一条：停稳了才换（拖动途中不换源），同 iOS `ReelsStore.settle`
  useEffect(() => {
    const el = video.current;
    if (!item || !el) return;
    let disposed = false;
    let engine: PlaybackEngine | null = null;
    let sessionId: string | null = null;
    let originMs = item.segment.start_ms;
    let ping = 0;
    let firstFrame = false;
    const shownAt = performance.now();
    const record = (kind: ReelEventKind, extra: Partial<ReelEvent> = {}) => {
      events.current.push({
        reel_id: item.id,
        kind,
        mode: item.play.mode,
        media_item_id: item.title.media_item_id,
        file_id: item.segment.file_id,
        ...extra,
      });
      if (events.current.length >= 10) void reportReelEvents(events.current.splice(0));
    };
    const fileTime = () => originMs + el.currentTime * 1000;
    const startSeconds = () => Math.max(0, toSessionSeconds(item.segment.start_ms, originMs));

    setStatus("loading");
    setFileMs(item.segment.start_ms);
    record("impression", { position_ms: item.segment.start_ms });
    const onTime = () => {
      const now = fileTime();
      setFileMs(now);
      // 放到片段终点停下，点一下重播
      if (now >= item.segment.end_ms - 50 && !el.paused) {
        el.pause();
        setStatus("ended");
        record("complete", { position_ms: now });
      }
    };
    const onPlaying = () => {
      setStatus("playing");
      if (!firstFrame) {
        firstFrame = true;
        record("first_frame", { position_ms: fileTime(), wait_ms: Math.round(performance.now() - shownAt) });
      }
    };
    const onPause = () => setStatus((s) => (s === "ended" || s === "failed" ? s : "paused"));
    el.addEventListener("timeupdate", onTime);
    el.addEventListener("playing", onPlaying);
    el.addEventListener("pause", onPause);
    replay.current = () => {
      el.currentTime = startSeconds();
      void el.play().catch(() => setStatus("paused"));
    };

    const fail = () => {
      if (disposed) return;
      setStatus("failed");
      record("fail");
    };
    void (async () => {
      try {
        const capability = await getCapabilitySnapshot();
        let streamUrl: string;
        let container = "mp4";
        let preferNativeHls = false;
        if (item.play.mode === "clip" && item.play.clip_url) {
          streamUrl = resolveStreamUrl(item.play.clip_url);
        } else {
          const session = await startReelSession(item, capability);
          sessionId = session.session_id;
          if (disposed) return;
          const mode = resolvePlaybackMode(session, capability);
          if (!mode) return fail();
          streamUrl = resolveStreamUrl(mode.streamUrl);
          container = session.decision.container ?? "mp4";
          preferNativeHls = mode.engine === "native-hls";
          originMs = mode.originMs;
          if (sessionId) {
            const id = sessionId;
            ping = window.setInterval(() => void pingPlaybackSession(id), 15_000);
          }
        }
        if (disposed) return;
        el.muted = muted;
        engine = createEngine({
          video: el,
          streamUrl,
          container,
          hasMse: capability.mse !== "none",
          mse: capability.mse,
          preferNativeHls,
          startPositionS: startSeconds(),
          telemetry: false,
          onFailed: fail,
        });
        await engine.attach();
        if (disposed) return;
        if (Math.abs(el.currentTime - startSeconds()) > 1) el.currentTime = startSeconds();
        await el.play().catch(() => setStatus("paused"));
      } catch {
        fail();
      }
    })();

    return () => {
      disposed = true;
      record("leave", { position_ms: fileTime(), watched_ms: Math.round(performance.now() - shownAt) });
      el.removeEventListener("timeupdate", onTime);
      el.removeEventListener("playing", onPlaying);
      el.removeEventListener("pause", onPause);
      window.clearInterval(ping);
      engine?.destroy();
      el.removeAttribute("src");
      el.load();
      if (sessionId) void stopPlaybackSession(sessionId).catch(() => undefined);
    };
    // muted 只在起播那一刻读；之后由按钮直接改元素
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [item]);

  const onScroll = useRef(0);
  const handleScroll = () => {
    const el = pager.current;
    if (!el) return;
    setScrolling(true);
    window.clearTimeout(onScroll.current);
    onScroll.current = window.setTimeout(() => {
      setScrolling(false);
      const index = Math.round(el.scrollTop / Math.max(1, el.clientHeight));
      setCurrent((prev) => (prev === index ? prev : index));
    }, 140);
  };

  /** 点页面空白处：暂停 / 继续；放完了就重播 */
  const togglePlay = () => {
    const el = video.current;
    if (!el || status === "loading" || status === "failed") return;
    if (status === "ended") return replay.current();
    if (el.paused) void el.play().catch(() => undefined);
    else el.pause();
  };

  const toggleSound = () => {
    const el = video.current;
    if (!el) return;
    el.muted = !el.muted;
    setMuted(el.muted);
    // 这一下是用户手势：iOS 从此放行这个元素的有声播放
    if (el.paused && status !== "ended") void el.play().catch(() => undefined);
  };

  const empty = feed !== null && feed.items.length === 0;
  const showVideo = !scrolling && (status === "playing" || status === "paused" || status === "ended");

  return (
    <div className="relative mx-auto h-dvh w-full max-w-[480px] overflow-hidden bg-black text-white [--reel-band:calc(min(100vw,480px)*9/16)]">
      <div
        ref={pager}
        onScroll={handleScroll}
        className="absolute inset-0 snap-y snap-mandatory overflow-y-scroll overscroll-contain [scrollbar-width:none]"
        data-testid="reels-pager"
      >
        {(feed?.items ?? []).map((reel, index) => (
          <ReelPage
            key={`${reel.id}-${index}`}
            item={reel}
            active={index === current}
            onTap={togglePlay}
            fullHref={playHref(reel.title.media_item_id, {
              season: reel.title.episode?.season,
              episode: reel.title.episode?.episode,
              tSeconds: (index === current ? fileMs : reel.segment.start_ms) / 1000,
              fileId: reel.segment.file_id,
            })}
          />
        ))}
        {feed && !feed.hasMore && feed.items.length > 0 && (
          <div className="flex h-dvh snap-start items-center justify-center text-sub text-[var(--text-muted)]">
            {t("library.reels.noMore")}
          </div>
        )}
      </div>

      {/* 唯一的视频元素：盖在当前页横带的位置（每页横带同一位置），拖动途中隐去，露出底下的封面 */}
      <video
        ref={video}
        playsInline
        muted
        className="pointer-events-none absolute inset-x-0 z-10 w-full bg-black object-contain transition-opacity duration-200"
        style={{ top: "calc(46% - var(--reel-band) / 2)", height: "var(--reel-band)", opacity: showVideo ? 1 : 0 }}
        data-testid="reels-video"
        data-status={status}
      />
      {item && status === "loading" && !scrolling && (
        <div
          className="pointer-events-none absolute inset-x-0 z-10 grid place-items-center"
          style={{ top: "calc(46% - 14px)" }}
        >
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

      {/* 顶栏：返回 · 片名 · 声音 */}
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
          aria-label={muted ? t("library.reels.unmute") : t("library.reels.mute")}
          onClick={toggleSound}
          data-testid="reels-sound"
          className="grid size-11 shrink-0 place-items-center rounded-full bg-white/[0.12] backdrop-blur-xl"
        >
          <SpeakerGlyph muted={muted} />
        </button>
      </div>

      {(feed === null || empty || loadFailed) && (
        <div className="absolute inset-0 z-20 grid place-items-center px-8 text-center">
          {loadFailed ? (
            <div className="grid gap-3">
              <p className="text-sub text-white/80">{t("library.reels.loadFailed")}</p>
              <button type="button" onClick={() => void load(null)} className="btn-glass mx-auto">
                {t("common.retry")}
              </button>
            </div>
          ) : feed === null ? (
            <p className="text-sub text-[var(--text-muted)]">{t("library.reels.picking")}</p>
          ) : (
            <div className="grid gap-2" data-testid="reels-empty">
              <p className="text-sub text-white/85">
                {feed.clips
                  ? t("library.reels.precutProgress", { ready: feed.clips.ready, total: feed.clips.total })
                  : t("library.reels.noneInLibrary")}
              </p>
              {feed.clips && <p className="text-caption text-[var(--text-muted)]">{t("library.reels.comeBackLater")}</p>}
            </div>
          )}
        </div>
      )}
    </div>
  );
}

/** 片段的一页：封面横带、左下导演与简介、右侧详情 / 看全片 */
function ReelPage({
  item,
  active,
  onTap,
  fullHref,
}: {
  item: ReelItem;
  active: boolean;
  onTap: () => void;
  fullHref: string;
}) {
  const t = useTranslations();
  const cover = item.cover_url ?? item.title.backdrop_url;
  const episode = item.title.episode;
  const overview = episode?.overview ?? item.title.overview;
  const person = item.title.directors[0];
  return (
    <section
      className="relative h-dvh w-full snap-start snap-always overflow-hidden"
      onClick={onTap}
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
          <div className="flex shrink-0 flex-col items-center gap-5 pb-1" onClick={(event) => event.stopPropagation()}>
            <Link
              href={`/library/${item.title.library_id}/item/${item.title.media_item_id}${episode ? `?season=${episode.season}&episode=${episode.episode}` : ""}` as Route}
              className="grid justify-items-center gap-1 text-caption"
            >
              <InfoIcon className="size-7" />
              {t("library.reels.detail")}
            </Link>
            <Link href={fullHref as Route} className="grid justify-items-center gap-1 text-caption" data-testid="reels-watch-full">
              <ExpandIcon className="size-7" />
              {t("library.reels.watchFull")}
            </Link>
          </div>
        </div>
      </div>
    </section>
  );
}

function SpeakerGlyph({ muted }: { muted: boolean }) {
  return (
    <svg viewBox="0 0 24 24" className="size-5" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <path d="M11 5 6 9H3v6h3l5 4V5Z" fill="currentColor" stroke="none" />
      {muted ? <path d="m16 9 5 6m0-6-5 6" /> : <path d="M15.5 8.5a5 5 0 0 1 0 7M18.5 5.5a9 9 0 0 1 0 13" />}
    </svg>
  );
}
