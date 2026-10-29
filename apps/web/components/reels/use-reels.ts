"use client";

import { useLocale, useTranslations } from "next-intl";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import { copyText } from "@/components/copy-button";
import { useToast } from "@/components/feedback";
import { reelFacetValues } from "@/components/reel-filter-sheet";
import {
  type ClientCapability,
  type PlaybackSession,
  pingPlaybackSession,
  resolveStreamUrl,
  setPlaybackMarks,
  stopPlaybackSession,
  stopPlaybackSessionOnUnload,
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

export type ReelStatus = "loading" | "playing" | "paused" | "ended" | "failed";

interface FeedState {
  seed: number;
  items: ReelItem[];
  nextOffset: number;
  hasMore: boolean;
  clips: ReelFeed["clips"];
}

export interface QualityControl {
  label: string;
  value: number | null;
  options: { maxHeight: number | null; label: string; hint: string | null }[];
  onSelect: (maxHeight: number | null) => void;
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
 * 片段页（docs/design/reels.md §6.1 / §6.2）的数据与播放：手机竖滑和电脑放映厅共用，版式各自排。
 *
 * 放法：预切小片（clip）`<video>` 直接放；没切的开一个播放会话从片段起点起播，由会话决定直出 / 转封装 /
 * 转码，引擎复用正片播放器那一层（engine.ts）；限了画质时会话带上限（只对没切的条目，预切片段本身就是 1080p）。
 * 会话不带设备标识与播放编号：刷片不进活动页、不写续播点。
 *
 * 字幕：服务端给的片段字幕文件（文字轨，文件时间）交正片播放器的字幕层画；图形字幕只在限了画质时由转码压进画面。
 *
 * **只有一个 `<video>`**，换条时换源：iOS 有声自动播放要用户手势，同一个元素被手势放过一次后换源接着放才不会被拦。
 * 声音同 App：**先带声音放**，浏览器不让（iPhone Safari 没点过页面；电脑上直接打开链接）才静音放着，等用户点一下
 * （`soundBlocked`，版式上给「点按开启声音」，点页面任何地方都是开声音）。
 */
export function useReels() {
  const t = useTranslations();
  const locale = useLocale();
  const toast = useToast();
  const { isAdmin } = usePermissions();
  const [feed, setFeed] = useState<FeedState | null>(null);
  const [loadFailed, setLoadFailed] = useState(false);
  const [current, setCurrent] = useState(0);
  const [status, setStatus] = useState<ReelStatus>("loading");
  const [fileMs, setFileMs] = useState(0);
  const [query, setQuery] = useState<ReelQuery>({ filter: {}, kind: null });
  const [facets, setFacets] = useState<ReelFacets | null>(null);
  const [quality, setQuality] = useState<number | null>(() => loadReelsQuality());
  const [notice, setNotice] = useState<string | null>(null);
  const [subtitle, setSubtitle] = useState<{ track: SubtitleOption; originS: number } | null>(null);
  /** 浏览器不让有声自动播放：静音放着，等一次点按 */
  const [soundBlocked, setSoundBlocked] = useState(false);
  /** 用户自己静音（电脑上按 M / 控制条的喇叭）；手机上没有这个开关，同 App 用音量键 */
  const [userMuted, setUserMuted] = useState(false);
  // 点过收藏 / 已看后的最新状态（接口给的是进页面那一刻的）
  const [favorites, setFavorites] = useState<Record<number, boolean>>({});
  const [playedMarks, setPlayedMarks] = useState<Record<string, boolean>>({});
  const [sharing, setSharing] = useState<{ item: ReelItem; share: ShareView | null } | null>(null);
  const [videoEl, setVideoEl] = useState<HTMLVideoElement | null>(null);
  const subtitleStyle = useMemo(() => ({ ...loadSubtitleStyle(), offsetSeconds: 0 }), []);
  const loadingMore = useRef(false);
  const events = useRef<ReelEvent[]>([]);
  const replay = useRef<() => void>(() => {});
  /** 起播时读的声音状态（换条时不重建播放器，读最新的） */
  const sound = useRef({ blocked: false, muted: false });
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
  /** 正在放的这一条的会话（关页面时结束它） */
  const liveSession = useRef<string | null>(null);
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

  // 关页面 / 刷新：effect 的收尾不会跑，事件与结束会话用 keepalive 发出去（同正片播放器）。进往返缓存的不结束
  // （iOS 切后台也是）：回来还要接着放，真不回来服务端三分钟没心跳也会回收
  useEffect(() => {
    const onPageHide = (event: PageTransitionEvent) => {
      void reportReelEvents(events.current.splice(0));
      if (!event.persisted && liveSession.current) stopPlaybackSessionOnUnload(liveSession.current);
    };
    window.addEventListener("pagehide", onPageHide);
    return () => window.removeEventListener("pagehide", onPageHide);
  }, []);
  useEffect(() => () => window.clearTimeout(noticeTimer.current), []);

  const item = feed?.items[current] ?? null;
  // 画质只管没切的条目（预切片段本身就是 1080p 小文件）：换画质时只有它们要重开
  const seekQuality = item && item.play.mode !== "clip" ? quality : null;

  // 换到哪一条就放哪一条（手机上停稳了才换，拖动途中不换源，同 iOS `ReelsStore.settle`）
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
    /** 先带声音放；浏览器不让就静音接着放，等用户点一下（只试一次：之后的每条都直接静音起播） */
    const start = async () => {
      el.muted = sound.current.muted || sound.current.blocked;
      try {
        await el.play();
      } catch (error) {
        if (disposed) return;
        if (!el.muted && error instanceof DOMException && error.name === "NotAllowedError") {
          el.muted = true;
          sound.current.blocked = true;
          setSoundBlocked(true);
          await el.play().catch(() => setStatus("paused"));
          return;
        }
        setStatus("paused");
      }
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
          liveSession.current = sessionId;
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
        await start();
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
      if (liveSession.current === sessionId) liveSession.current = null;
    };
    // 文案函数 t 每次渲染都换，不该让播放器重建
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [item, seekQuality, videoEl]);

  // 离开页面（看全片、详情、返回）时把没报的事件报掉。要声明在上面的播放 effect 之后：卸载时清理按声明顺序跑，
  // 排在前面的话最后一条的「离开」还没记就先报了，那条就丢了
  useEffect(() => () => void reportReelEvents(events.current.splice(0)), []);

  /** 开声音：这一下是用户手势，iOS 从此放行这个元素的有声播放（换源接着放也有声） */
  const unmute = () => {
    const el = videoEl;
    if (!el) return;
    el.muted = false;
    sound.current = { blocked: false, muted: false };
    setSoundBlocked(false);
    setUserMuted(false);
    if (el.paused && status !== "ended" && status !== "failed") void el.play().catch(() => undefined);
  };

  /** 电脑上的静音开关（M / 控制条的喇叭） */
  const toggleMute = () => {
    const el = videoEl;
    if (!el) return;
    if (el.muted) return unmute();
    el.muted = true;
    sound.current.muted = true;
    setUserMuted(true);
  };

  /** 点画面：被静音着就是开声音（不暂停，同 YouTube Shorts）；否则暂停 / 继续，放完了就重播 */
  const togglePlay = () => {
    const el = videoEl;
    if (!el) return;
    if (soundBlocked) return unmute();
    if (status === "loading" || status === "failed") return;
    if (status === "ended") return replay.current();
    if (el.paused) void el.play().catch(() => undefined);
    else el.pause();
  };

  /** 换到第几条（电脑上的上一条 / 下一条、接下来；手机上由翻页位置决定） */
  const go = (index: number) => {
    const count = feed?.items.length ?? 0;
    if (count === 0) return;
    setCurrent(Math.max(0, Math.min(count - 1, index)));
  };

  /** 换筛选条件：整个信息流按新条件重来（同 iOS `ReelsStore.applyFilter`） */
  const applyFilter = (next: ReelQuery) => {
    if (filterKey(next.filter) === filterKey(query.filter) && next.kind === query.kind) return;
    generation.current += 1;
    loadingMore.current = false;
    setFeed(null);
    setLoadFailed(false);
    setCurrent(0);
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
  /** 看了一半时的进度；标记已看 / 取消已看都会清掉续播点，点过就不再画 */
  const progressOf = (reel: ReelItem) => (reel.id in playedMarks ? null : reel.title.progress_percent);

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

  /** 从当前位置进正片播放器（不是当前这条就从片段起点） */
  const fullHref = (reel: ReelItem) =>
    playHref(reel.title.media_item_id, {
      season: reel.title.episode?.season,
      episode: reel.title.episode?.episode,
      tSeconds: (reel === item ? fileMs : reel.segment.start_ms) / 1000,
      fileId: reel.segment.file_id,
    });

  /** 这部片的详情页（剧集定位到这一集） */
  const detailHref = (reel: ReelItem) => {
    const episode = reel.title.episode;
    return `/library/${reel.title.library_id}/item/${reel.title.media_item_id}${episode ? `?season=${episode.season}&episode=${episode.episode}` : ""}`;
  };

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
  const qualityControl: QualityControl = {
    label: qualities.find((option) => option.maxHeight === quality)?.label ?? `${quality}p`,
    value: quality,
    options: qualities,
    onSelect: selectQuality,
  };

  return {
    feed,
    loadFailed,
    retry: () => void load(null, query),
    empty: feed !== null && feed.items.length === 0,
    filtered: !isFilterEmpty(query.filter) || query.kind !== null,
    current,
    setCurrent,
    go,
    item,
    status,
    fileMs,
    query,
    facets,
    applyFilter,
    filterTitle,
    /** 画质菜单；预切片段没有（选了也不起作用） */
    qualityFor: (reel: ReelItem) => (reel.play.mode === "clip" ? null : qualityControl),
    soundBlocked,
    muted: soundBlocked || userMuted,
    unmute,
    toggleMute,
    togglePlay,
    notice,
    subtitle,
    subtitleStyle,
    videoEl,
    setVideoEl,
    isFavorite,
    toggleFavorite,
    isPlayed,
    progressOf,
    togglePlayed,
    share,
    sharing,
    closeShare: () => setSharing(null),
    fullHref,
    detailHref,
  };
}

export type Reels = ReturnType<typeof useReels>;
