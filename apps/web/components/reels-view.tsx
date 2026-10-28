"use client";

import * as DropdownMenu from "@radix-ui/react-dropdown-menu";
import type { Route } from "next";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useLocale, useTranslations } from "next-intl";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import { copyText } from "@/components/copy-button";
import { useToast } from "@/components/feedback";
import { ArrowLeftIcon, CheckIcon, ChevronDownIcon, ExpandIcon, FilmIcon, HeartIcon, PlayIcon } from "@/components/icons";
import { SubtitleLayer } from "@/components/player/subtitle-layer";
import { ReelFilterSheet, reelFacetValues } from "@/components/reel-filter-sheet";
import { ShareDialog } from "@/components/share-dialog";
import {
  type ClientCapability,
  type PlaybackSession,
  pingPlaybackSession,
  resolveStreamUrl,
  setPlaybackMarks,
  stopPlaybackSession,
} from "@/lib/api/playback";
import {
  type ReelEvent,
  type ReelEventKind,
  type ReelFacets,
  type ReelFeed,
  type ReelItem,
  type ReelQuery,
  fetchReelFacets,
  fetchReelFeed,
  reportReelEvents,
  startReelSession,
} from "@/lib/api/reels";
import { type ShareView, getItemShare } from "@/lib/api/shares";
import { HttpError } from "@/lib/http";
import { imageUrl } from "@/lib/image-proxy";
import { filterKey, isFilterEmpty } from "@/lib/library-filter";
import { usePermissions } from "@/lib/permissions";
import { getCapabilitySnapshot } from "@/lib/player/capability";
import { createEngine, type PlaybackEngine } from "@/lib/player/engine";
import { playHref } from "@/lib/player/play-links";
import { resolvePlaybackMode } from "@/lib/player/playback-mode";
import { qualityOptions } from "@/lib/player/quality";
import { loadSubtitleStyle, type SubtitleOption } from "@/lib/player/subtitles";
import { toSessionSeconds } from "@/lib/player/timeline";
import { loadReelsQuality, reelBurnTrack, reelFilterSummary, reelSubtitleTrack, saveReelsQuality } from "@/lib/reels";

type Status = "loading" | "playing" | "paused" | "ended" | "failed";

interface FeedState {
  seed: number;
  items: ReelItem[];
  nextOffset: number;
  hasMore: boolean;
  clips: ReelFeed["clips"];
}

/** 限了画质开不成时为什么退回原画（文案见 library.reels.*） */
type Fallback = "transcodeFull" | "transcodeFailed" | "softwareTranscodeOff" | "cannotTranscode";

/**
 * 给 seek 那一条开会话（同 iOS `ReelPlayer.startTranscode` 的退路）：压字幕撞上「要开启软件转码」就不压字幕再要一次；
 * 限了画质却开不成（转码路数满、请求失败、要开启软件转码、服务端拒绝）这一条先按原画开，不让它放不出来。
 */
async function openSeekSession(
  item: ReelItem,
  capability: ClientCapability,
  startMs: number,
  maxHeight: number | null,
): Promise<{ session: PlaybackSession; fallback: Fallback | null }> {
  let limit = maxHeight;
  let burn = reelBurnTrack(item.play.subtitle, limit);
  let fallback: Fallback | null = null;
  for (;;) {
    let session: PlaybackSession;
    try {
      session = await startReelSession(item, capability, { startMs, maxHeight: limit, subtitleTrack: burn });
    } catch (error) {
      if (limit === null) throw error;
      fallback = error instanceof HttpError && error.status === 503 ? "transcodeFull" : "transcodeFailed";
      limit = null;
      burn = "off";
      continue;
    }
    const outcome = session.decision.outcome;
    if (outcome === "consent" && burn !== "off") {
      burn = "off";
      continue;
    }
    if (outcome !== "plan" && limit !== null) {
      fallback = outcome === "consent" ? "softwareTranscodeOff" : "cannotTranscode";
      limit = null;
      burn = "off";
      continue;
    }
    return { session, fallback };
  }
}

/**
 * 片段（docs/design/reels.md）：上下整页滑动，每页是片库里一部片的 30～60 秒，版式同 iOS `ReelsView`：
 * 顶栏返回 · 片名 · 筛选，横带下方画质与看全片（播放时调暗），右下角声音、收藏、详情、已看、分享。
 *
 * 放法：预切小片（clip）`<video>` 直接放；没切的开一个播放会话从片段起点起播，由会话决定直出 / 转封装 /
 * 转码，引擎复用正片播放器那一层（engine.ts）；限了画质时会话带上限（只对没切的条目，预切片段本身就是 1080p）。
 * 会话不带设备标识与播放编号：刷片不进活动页、不写续播点。
 *
 * 字幕：服务端给的片段字幕文件（文字轨，文件时间）交正片播放器的字幕层画；图形字幕只在限了画质时由转码压进画面。
 *
 * **只有一个 `<video>`**，盖在当前页横带的位置上，换页时换源：iOS 有声自动播放要用户手势，同一个元素被
 * 手势放过一次后换源接着放才不会被拦。一开始静音起播，点「开启声音」后整段刷片都有声。
 */
export function ReelsView() {
  const t = useTranslations();
  const locale = useLocale();
  const router = useRouter();
  const toast = useToast();
  const { isAdmin } = usePermissions();
  const [feed, setFeed] = useState<FeedState | null>(null);
  const [loadFailed, setLoadFailed] = useState(false);
  const [current, setCurrent] = useState(0);
  const [scrolling, setScrolling] = useState(false);
  const [status, setStatus] = useState<Status>("loading");
  const [muted, setMuted] = useState(true);
  const [fileMs, setFileMs] = useState(0);
  const [query, setQuery] = useState<ReelQuery>({ filter: {}, kind: null });
  const [facets, setFacets] = useState<ReelFacets | null>(null);
  const [filterOpen, setFilterOpen] = useState(false);
  const [quality, setQuality] = useState<number | null>(() => loadReelsQuality());
  const [notice, setNotice] = useState<string | null>(null);
  const [subtitle, setSubtitle] = useState<{ track: SubtitleOption; originS: number } | null>(null);
  // 点过收藏 / 已看后的最新状态（接口给的是进页面那一刻的）
  const [favorites, setFavorites] = useState<Record<number, boolean>>({});
  const [playedMarks, setPlayedMarks] = useState<Record<string, boolean>>({});
  const [sharing, setSharing] = useState<{ item: ReelItem; share: ShareView | null } | null>(null);
  const [videoEl, setVideoEl] = useState<HTMLVideoElement | null>(null);
  const subtitleStyle = useMemo(() => ({ ...loadSubtitleStyle(), offsetSeconds: 0 }), []);
  const pager = useRef<HTMLDivElement>(null);
  const loadingMore = useRef(false);
  const events = useRef<ReelEvent[]>([]);
  const replay = useRef<() => void>(() => {});
  /** 换了筛选条件就加一：旧条件的那一页回来时丢掉 */
  const generation = useRef(0);
  /** 换画质时这一条从哪里接着放（条目 id、文件时间）；下一次为它开源时用掉 */
  const resumeAt = useRef<{ id: string; ms: number } | null>(null);
  /** 当前这条是换画质重开：拆掉时不算「滑走」 */
  const reopening = useRef(false);
  /**
   * 上一条的会话正在结束：下一条等它结束了再开（同 iOS `ReelsStore.releasing`）。服务端直通、转码都有并发上限
   * （直通 4 路，纯软件转码按核数算），旧会话没收掉就开新的会被拒
   */
  const releasing = useRef<Promise<unknown>>(Promise.resolve());
  const noticeTimer = useRef(0);

  const load = useCallback(async (more: FeedState | null, where: ReelQuery) => {
    const run = generation.current;
    try {
      const page = await fetchReelFeed(more ? { seed: more.seed, offset: more.nextOffset } : {}, where);
      if (run !== generation.current) return;
      setLoadFailed(false);
      setFeed((prev) => ({
        seed: page.seed,
        items: more && prev ? [...prev.items, ...page.items] : page.items,
        nextOffset: page.next_offset,
        hasMore: page.has_more,
        clips: page.clips,
      }));
    } catch {
      if (!more && run === generation.current) setLoadFailed(true);
    }
  }, []);

  // 进页面、换了筛选条件：从第一页重来；菜单计数与第一页并行拉，旧的在新的回来前照常显示
  useEffect(() => {
    let stale = false;
    void load(null, query);
    fetchReelFacets(query)
      .then((next) => {
        if (!stale) setFacets(next);
      })
      .catch(() => undefined);
    return () => {
      stale = true;
    };
  }, [load, query]);

  // 快刷到底时接着取下一页
  useEffect(() => {
    if (!feed || !feed.hasMore || loadingMore.current || current < feed.items.length - 3) return;
    loadingMore.current = true;
    void load(feed, query).finally(() => {
      loadingMore.current = false;
    });
  }, [current, feed, load, query]);

  // 离开页面时把没报的事件报掉
  useEffect(() => () => void reportReelEvents(events.current.splice(0)), []);
  useEffect(() => () => window.clearTimeout(noticeTimer.current), []);

  const item = feed?.items[current] ?? null;
  // 画质只管没切的条目（预切片段本身就是 1080p 小文件）：换画质时只有它们要重开
  const seekQuality = item && item.play.mode !== "clip" ? quality : null;

  // 换到哪一条就放哪一条：停稳了才换（拖动途中不换源），同 iOS `ReelsStore.settle`
  useEffect(() => {
    const el = videoEl;
    if (!item || !el) return;
    let disposed = false;
    let engine: PlaybackEngine | null = null;
    let sessionId: string | null = null;
    let originMs = item.segment.start_ms;
    let ping = 0;
    let firstFrame = false;
    const shownAt = performance.now();
    const resume = resumeAt.current?.id === item.id ? resumeAt.current.ms : null;
    resumeAt.current = null;
    const fromMs = resume ?? item.segment.start_ms;
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
    // 取整：事件接口与开会话的起点都只收整数毫秒（带小数整批 422，事件就丢了）
    const fileTime = () => Math.round(originMs + el.currentTime * 1000);
    const secondsAt = (ms: number) => Math.max(0, toSessionSeconds(ms, originMs));
    const flash = (message: string) => {
      setNotice(message);
      window.clearTimeout(noticeTimer.current);
      noticeTimer.current = window.setTimeout(() => setNotice(null), 4000);
    };

    setStatus("loading");
    setFileMs(fromMs);
    // 换画质重开的是同一次露出，不再记一次
    if (resume === null) record("impression", { position_ms: item.segment.start_ms });
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
      el.currentTime = secondsAt(item.segment.start_ms);
      void el.play().catch(() => setStatus("paused"));
    };

    const fail = () => {
      if (disposed) return;
      setStatus("failed");
      record("fail");
    };
    const fallbackReasons: Record<Fallback, string> = {
      transcodeFull: t("library.reels.transcodeFull"),
      transcodeFailed: t("library.reels.transcodeFailed"),
      softwareTranscodeOff: t("library.reels.softwareTranscodeOff"),
      cannotTranscode: t("library.reels.cannotTranscode"),
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
          await releasing.current;
          if (disposed) return;
          const opened = await openSeekSession(item, capability, fromMs, seekQuality);
          const session = opened.session;
          if (disposed) {
            // 会话回来时已经滑走了：当场结束，别让它占着服务端的路数（同 iOS `ReelPlayer.startTranscode`）
            if (session.session_id) releasing.current = stopPlaybackSession(session.session_id).catch(() => undefined);
            return;
          }
          sessionId = session.session_id;
          const mode = resolvePlaybackMode(session, capability);
          if (!mode) return fail();
          if (opened.fallback) flash(t("library.reels.fallbackOriginal", { reason: fallbackReasons[opened.fallback] }));
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
        // 片段字幕（文字轨）：字幕文件是文件时间，字幕层按时间轴零点换算
        const track = reelSubtitleTrack(item.play.subtitle);
        if (track) setSubtitle({ track, originS: originMs / 1000 });
        el.muted = muted;
        engine = createEngine({
          video: el,
          streamUrl,
          container,
          hasMse: capability.mse !== "none",
          mse: capability.mse,
          preferNativeHls,
          startPositionS: secondsAt(fromMs),
          telemetry: false,
          onFailed: fail,
        });
        await engine.attach();
        if (disposed) return;
        if (Math.abs(el.currentTime - secondsAt(fromMs)) > 1) el.currentTime = secondsAt(fromMs);
        await el.play().catch(() => setStatus("paused"));
      } catch {
        fail();
      }
    })();

    return () => {
      disposed = true;
      if (!reopening.current) {
        record("leave", { position_ms: fileTime(), watched_ms: Math.round(performance.now() - shownAt) });
      }
      reopening.current = false;
      setSubtitle(null);
      el.removeEventListener("timeupdate", onTime);
      el.removeEventListener("playing", onPlaying);
      el.removeEventListener("pause", onPause);
      window.clearInterval(ping);
      engine?.destroy();
      el.removeAttribute("src");
      el.load();
      if (sessionId) releasing.current = stopPlaybackSession(sessionId).catch(() => undefined);
    };
    // muted 只在起播那一刻读；之后由按钮直接改元素
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [item, seekQuality, videoEl]);

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
    const el = videoEl;
    if (!el || status === "loading" || status === "failed") return;
    if (status === "ended") return replay.current();
    if (el.paused) void el.play().catch(() => undefined);
    else el.pause();
  };

  const toggleSound = () => {
    const el = videoEl;
    if (!el) return;
    el.muted = !el.muted;
    setMuted(el.muted);
    // 这一下是用户手势：iOS 从此放行这个元素的有声播放
    if (el.paused && status !== "ended") void el.play().catch(() => undefined);
  };

  /** 换筛选条件：整个信息流按新条件重来（同 iOS `ReelsStore.applyFilter`） */
  const applyFilter = (next: ReelQuery) => {
    if (filterKey(next.filter) === filterKey(query.filter) && next.kind === query.kind) return;
    generation.current += 1;
    loadingMore.current = false;
    setFeed(null);
    setLoadFailed(false);
    setCurrent(0);
    pager.current?.scrollTo({ top: 0 });
    setQuery(next);
  };

  /** 选画质：记下来（之后刷到的每一条都按它），当前这条从刚才的位置按新画质重开 */
  const selectQuality = (maxHeight: number | null) => {
    saveReelsQuality(maxHeight);
    if (maxHeight === quality) return;
    if (item && item.play.mode !== "clip") {
      if (status !== "ended" && fileMs < item.segment.end_ms - 1000) resumeAt.current = { id: item.id, ms: fileMs };
      reopening.current = true;
    }
    setQuality(maxHeight);
  };

  const isFavorite = (reel: ReelItem) => favorites[reel.title.media_item_id] ?? reel.title.favorite;
  const isPlayed = (reel: ReelItem) => playedMarks[reel.id] ?? reel.title.played;

  /** 收藏：落在整部（电影 / 整剧）上 */
  const toggleFavorite = async (reel: ReelItem) => {
    const id = reel.title.media_item_id;
    const target = !isFavorite(reel);
    setFavorites((marks) => ({ ...marks, [id]: target }));
    try {
      const state = await setPlaybackMarks({ media_item_id: id }, { favorite: target });
      setFavorites((marks) => ({ ...marks, [id]: state.is_favorite }));
    } catch (error) {
      setFavorites((marks) => ({ ...marks, [id]: !target }));
      toast.error((error as Error).message);
    }
  };

  /** 已看：电影标整部，剧集标这一集 */
  const togglePlayed = async (reel: ReelItem) => {
    const target = !isPlayed(reel);
    setPlayedMarks((marks) => ({ ...marks, [reel.id]: target }));
    try {
      const state = await setPlaybackMarks(
        {
          media_item_id: reel.title.media_item_id,
          season_number: reel.title.episode?.season,
          episode_number: reel.title.episode?.episode,
        },
        { played: target },
      );
      setPlayedMarks((marks) => ({ ...marks, [reel.id]: state.played }));
    } catch (error) {
      setPlayedMarks((marks) => ({ ...marks, [reel.id]: !target }));
      toast.error((error as Error).message);
    }
  };

  /** 分享：超管生成分享链接（同详情页）；成员把片名分享出去（系统分享面板，没有就复制） */
  const share = (reel: ReelItem) => {
    if (isAdmin) {
      getItemShare(reel.title.library_id, reel.title.media_item_id)
        .then((existing) => {
          videoEl?.pause();
          setSharing({ item: reel, share: existing });
        })
        .catch((error) => toast.error((error as Error).message));
      return;
    }
    const { name, year, episode } = reel.title;
    const text = [
      year ? t("library.reels.shareTitleYear", { name, year: String(year) }) : t("library.reels.shareTitle", { name }),
      episode ? t("library.reels.episode", { season: episode.season, episode: episode.episode }) : null,
    ]
      .filter(Boolean)
      .join(" ");
    if (navigator.share) {
      videoEl?.pause();
      void navigator.share({ text }).catch(() => undefined);
      return;
    }
    void copyText(text).then(() => toast.success(t("common.copied")));
  };

  const empty = feed !== null && feed.items.length === 0;
  const filtered = !isFilterEmpty(query.filter) || query.kind !== null;
  const showVideo = !scrolling && (status === "playing" || status === "paused" || status === "ended");
  const filterTitle = (() => {
    const summary = reelFilterSummary(query.filter, query.kind);
    const label = (key: Parameters<typeof reelFacetValues>[1], value: string) =>
      reelFacetValues(facets, key).find((v) => v.value === value)?.label;
    switch (summary.type) {
      case "all":
        return t("media.filters.all");
      case "count":
        return t("library.reels.filterCount", { count: summary.count });
      case "unwatched":
        return t("library.reels.notWatched");
      case "kind":
        return (
          label("kinds", summary.value) ??
          (summary.value === "tv" ? t("media.kind.tv") : summary.value === "video" ? t("library.kind.other") : t("media.kind.movie"))
        );
      case "value":
        return label(summary.key, summary.value) ?? summary.value;
    }
  })();
  const qualities = qualityOptions(locale).map((option) =>
    option.maxHeight === null
      ? { ...option, label: t("library.reels.original"), hint: t("library.reels.originalHint") }
      : option,
  );
  const qualityLabel = qualities.find((option) => option.maxHeight === quality)?.label ?? `${quality}p`;

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
            // 横带下方一行只有停下来（暂停、放完、放不出）时亮；起播、播放都暗，别抢看片的注意力（同 iOS）
            dimmed={index !== current || status === "loading" || status === "playing"}
            onTap={togglePlay}
            fullHref={playHref(reel.title.media_item_id, {
              season: reel.title.episode?.season,
              episode: reel.title.episode?.episode,
              tSeconds: (index === current ? fileMs : reel.segment.start_ms) / 1000,
              fileId: reel.segment.file_id,
            })}
            quality={
              reel.play.mode === "clip"
                ? null
                : { label: qualityLabel, value: quality, options: qualities, onSelect: selectQuality }
            }
            muted={muted}
            onToggleSound={toggleSound}
            favorite={isFavorite(reel)}
            onToggleFavorite={() => void toggleFavorite(reel)}
            played={isPlayed(reel)}
            // 标记已看 / 取消已看都会清掉续播点：点过就不再画进度
            progress={reel.id in playedMarks ? null : reel.title.progress_percent}
            onTogglePlayed={() => void togglePlayed(reel)}
            onShare={() => share(reel)}
          />
        ))}
        {feed && !feed.hasMore && feed.items.length > 0 && (
          <div className="flex h-dvh snap-start items-center justify-center text-sub text-[var(--text-muted)]">
            {t("library.reels.noMore")}
          </div>
        )}
      </div>

      {/* 唯一的视频元素：盖在当前页横带的位置（每页横带同一位置），拖动途中隐去，露出底下的封面。
          字幕层（与 JASSUB 的画布）跟着它放在同一个框里：按视频框定位、一起淡出 */}
      <div
        className="pointer-events-none absolute inset-x-0 z-10 transition-opacity duration-200"
        style={{ top: "calc(46% - var(--reel-band) / 2)", height: "var(--reel-band)", opacity: showVideo ? 1 : 0 }}
      >
        <video
          ref={setVideoEl}
          playsInline
          muted
          className="absolute inset-0 size-full bg-black object-contain"
          data-testid="reels-video"
          data-status={status}
        />
        {subtitle && (
          <SubtitleLayer
            video={videoEl}
            track={subtitle.track}
            style={subtitleStyle}
            baseOffsetSeconds={subtitle.originS}
            avoidBottomPx={0}
          />
        )}
      </div>
      {notice && !scrolling && (
        <p
          className="pointer-events-none absolute inset-x-6 z-20 text-center"
          style={{ top: "calc(46% - var(--reel-band) / 2 - 44px)" }}
          data-testid="reels-notice"
        >
          <span className="inline-block rounded-full bg-black/60 px-3 py-1.5 text-caption text-white/90 backdrop-blur">{notice}</span>
        </p>
      )}
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
          aria-label={t("library.reels.filterLabel", { value: filterTitle })}
          onClick={() => setFilterOpen(true)}
          data-testid="reels-filter"
          className="flex h-11 max-w-[8.5rem] shrink-0 items-center gap-1.5 rounded-full bg-white/[0.12] px-4 backdrop-blur-xl"
        >
          <span className="truncate text-sub font-semibold">{filterTitle}</span>
          <ChevronDownIcon className="size-3.5 shrink-0 text-white/70" />
        </button>
      </div>

      {(feed === null || empty || loadFailed) && (
        <div className="absolute inset-0 z-20 grid place-items-center px-8 text-center">
          {loadFailed ? (
            <div className="grid gap-3">
              <p className="text-sub text-white/80">{t("library.reels.loadFailed")}</p>
              <button type="button" onClick={() => void load(null, query)} className="btn-glass mx-auto">
                {t("common.retry")}
              </button>
            </div>
          ) : feed === null ? (
            <p className="text-sub text-[var(--text-muted)]">{t("library.reels.picking")}</p>
          ) : filtered && !feed.clips ? (
            <div className="grid gap-3" data-testid="reels-empty">
              <p className="text-sub text-white/85">{t("library.reels.noneForFilters")}</p>
              <button type="button" onClick={() => applyFilter({ filter: {}, kind: null })} className="btn-glass mx-auto">
                {t("media.discovery.clearFilters")}
              </button>
            </div>
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

      <ReelFilterSheet open={filterOpen} onClose={() => setFilterOpen(false)} facets={facets} query={query} onApply={applyFilter} />
      {sharing && (
        <ShareDialog
          open
          onClose={() => setSharing(null)}
          libraryId={sharing.item.title.library_id}
          mediaItemId={sharing.item.title.media_item_id}
          title={sharing.item.title.name}
          kind={sharing.item.title.kind}
          year={sharing.item.title.year}
          posterUrl={sharing.item.title.poster_url}
          initialShare={sharing.share}
        />
      )}
    </div>
  );
}

interface QualityControl {
  label: string;
  value: number | null;
  options: { maxHeight: number | null; label: string; hint: string | null }[];
  onSelect: (maxHeight: number | null) => void;
}

/** 片段的一页：封面横带、横带下方画质与看全片、左下导演与简介、右侧一列按钮 */
function ReelPage({
  item,
  active,
  dimmed,
  onTap,
  fullHref,
  quality,
  muted,
  onToggleSound,
  favorite,
  onToggleFavorite,
  played,
  progress,
  onTogglePlayed,
  onShare,
}: {
  item: ReelItem;
  active: boolean;
  dimmed: boolean;
  onTap: () => void;
  fullHref: string;
  /** 画质菜单；预切片段没有（选了也不起作用） */
  quality: QualityControl | null;
  muted: boolean;
  onToggleSound: () => void;
  favorite: boolean;
  onToggleFavorite: () => void;
  played: boolean;
  progress: number | null;
  onTogglePlayed: () => void;
  onShare: () => void;
}) {
  const t = useTranslations();
  const cover = item.cover_url ?? item.title.backdrop_url;
  const episode = item.title.episode;
  const overview = episode?.overview ?? item.title.overview;
  const person = item.title.directors[0];
  // 横带下方的描边小胶囊：暗时只降颜色不隐藏，按钮始终在原位、暗着也能点
  const capsule = `flex items-center gap-1.5 rounded-full border px-3.5 py-1.5 text-caption font-semibold transition-colors duration-300 ${
    dimmed ? "border-white/10 text-white/30" : "border-white/35 text-white/90"
  }`;
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
      {/* 横带下方一行：画质在左、看全片在右（同 iOS 的画质 · 全屏观看） */}
      <div
        className="absolute inset-x-0 z-20 flex justify-center gap-2.5"
        style={{ top: "calc(46% + var(--reel-band) / 2 + 14px)" }}
        onClick={(event) => event.stopPropagation()}
      >
        {quality && (
          <DropdownMenu.Root>
            <DropdownMenu.Trigger asChild>
              <button
                type="button"
                className={capsule}
                aria-label={t("library.reels.qualityValue", { value: quality.label })}
                data-testid="reels-quality"
              >
                {quality.label}
                <ChevronDownIcon className="size-3" />
              </button>
            </DropdownMenu.Trigger>
            <DropdownMenu.Portal>
              <DropdownMenu.Content
                side="top"
                align="center"
                sideOffset={8}
                collisionPadding={12}
                className="menu-surface z-50 min-w-[12rem] p-1"
              >
                <DropdownMenu.Label className="px-3 pb-1 pt-1.5 text-caption text-[var(--text-faint)]">
                  {t("library.filters.quality")}
                </DropdownMenu.Label>
                {quality.options.map((option) => (
                  <DropdownMenu.Item
                    key={String(option.maxHeight)}
                    onSelect={() => quality.onSelect(option.maxHeight)}
                    className="glass-row nav-item flex cursor-pointer items-start gap-2 px-3 py-2 text-sub outline-none data-[highlighted]:!bg-[var(--glass-fill-hover)]"
                    data-testid={`reels-quality-${option.maxHeight ?? "original"}`}
                  >
                    <span className="flex size-4 shrink-0 items-center justify-center pt-0.5">
                      {option.maxHeight === quality.value && <CheckIcon className="size-3.5 text-[var(--info)]" />}
                    </span>
                    <span className="min-w-0">
                      <span className={`block font-medium ${option.maxHeight === quality.value ? "text-white" : "text-white/75"}`}>
                        {option.label}
                      </span>
                      {option.hint && <span className="block text-caption leading-4 text-white/40">{option.hint}</span>}
                    </span>
                  </DropdownMenu.Item>
                ))}
              </DropdownMenu.Content>
            </DropdownMenu.Portal>
          </DropdownMenu.Root>
        )}
        <Link href={fullHref as Route} className={capsule} data-testid="reels-watch-full">
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
          {/* 右下角一列无底色的白色按钮（同 iOS：带投影，亮画面上也看得清） */}
          <div
            className="flex shrink-0 flex-col items-center gap-4 pb-1 [filter:drop-shadow(0_1px_3px_rgba(0,0,0,0.55))]"
            onClick={(event) => event.stopPropagation()}
          >
            <ActionButton label={muted ? t("library.reels.unmute") : t("library.reels.mute")} onClick={onToggleSound} testId="reels-sound">
              <SpeakerGlyph muted={muted} />
            </ActionButton>
            <ActionButton
              label={t("library.gallery.favorite")}
              onClick={onToggleFavorite}
              pressed={favorite}
              testId="reels-favorite"
            >
              <HeartIcon className={favorite ? "size-7 text-[var(--danger)]" : "size-7"} fill={favorite ? "currentColor" : "none"} />
            </ActionButton>
            <Link
              href={`/library/${item.title.library_id}/item/${item.title.media_item_id}${episode ? `?season=${episode.season}&episode=${episode.episode}` : ""}` as Route}
              className="grid justify-items-center gap-1 text-caption"
              data-testid="reels-detail"
            >
              <FilmIcon className="size-7" />
              {t("library.reels.detail")}
            </Link>
            <ActionButton
              label={t("library.reels.played")}
              onClick={onTogglePlayed}
              pressed={played}
              testId="reels-played"
              valueText={played ? t("library.reels.watched") : progress ? t("library.reels.watchedPercent", { percent: progress }) : t("library.reels.notWatched")}
            >
              <PlayedGlyph played={played} progress={progress} />
            </ActionButton>
            <ActionButton label={t("library.manage.shares")} onClick={onShare} testId="reels-share">
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

/**
 * 已看：跟着真实观看进度画（同 iOS）——没看完时是暗圈，看了多少白色弧就描多少（没看过 = 一圈暗的）；
 * 看完是绿色实心。没看过不用亮白整圈：那样和「快看完」分不开。
 */
function PlayedGlyph({ played, progress }: { played: boolean; progress: number | null }) {
  const radius = 10.25;
  const circumference = 2 * Math.PI * radius;
  return (
    <svg viewBox="0 0 24 24" className="size-7" fill="none" aria-hidden>
      {played ? (
        <circle cx="12" cy="12" r="11" fill="var(--ok)" />
      ) : (
        <>
          <circle cx="12" cy="12" r={radius} stroke="rgba(255,255,255,0.32)" strokeWidth="1.8" />
          {progress ? (
            <circle
              cx="12"
              cy="12"
              r={radius}
              stroke="white"
              strokeWidth="1.8"
              strokeLinecap="round"
              strokeDasharray={`${(circumference * progress) / 100} ${circumference}`}
              transform="rotate(-90 12 12)"
            />
          ) : null}
        </>
      )}
      <path d="m7.6 12.3 3 3 5.8-6.3" stroke={played ? "black" : "white"} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

function ShareGlyph() {
  return (
    <svg viewBox="0 0 24 24" className="size-7" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <path d="M13.5 5.5 20 11.5l-6.5 6v-3.6c-4.4 0-7.4 1.3-9.5 4.6.6-4.9 3.3-8.6 9.5-9.4V5.5Z" />
    </svg>
  );
}

function SpeakerGlyph({ muted }: { muted: boolean }) {
  return (
    <svg viewBox="0 0 24 24" className="size-7" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <path d="M11 5 6 9H3v6h3l5 4V5Z" fill="currentColor" stroke="none" />
      {muted ? <path d="m16 9 5 6m0-6-5 6" /> : <path d="M15.5 8.5a5 5 0 0 1 0 7M18.5 5.5a9 9 0 0 1 0 13" />}
    </svg>
  );
}
