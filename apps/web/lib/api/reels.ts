import { request } from "@/lib/http";
import type { ClientCapability, PlaybackSession } from "@/lib/api/playback";
import type { FacetValue } from "@/lib/api/libraries";
import type { LibraryFilter } from "@/lib/library-filter";
import { reelFilterQuery } from "@/lib/reels";

/**
 * 刷片（docs/design/reels.md）：网页版的片段接口。
 *
 * 网页放不了任意原片（MKV、HEVC、DTS……），所以两种放法都要：
 * - clip：服务端预切好的 1080p H.264 + AAC 小 MP4，`<video>` 直接放（要服务端开「片段预切」）；
 * - seek：开一个播放会话，从片段起点起播（同 iPhone 限画质时的做法），由会话决定直出 / 转封装 / 转码。
 */

interface ApiEnvelope<T> {
  success: boolean;
  data: T;
}

export interface ReelPerson {
  name: string;
  tmdb_person_id: number | null;
  avatar_url: string | null;
}

export interface ReelTitle {
  media_item_id: number;
  library_id: number;
  kind: "movie" | "tv" | "video";
  name: string;
  year: number | null;
  overview: string | null;
  directors: ReelPerson[];
  poster_url: string | null;
  backdrop_url: string | null;
  episode: { season: number; episode: number; name: string | null; overview: string | null } | null;
  /** 收藏落在整部（电影 / 整剧）上 */
  favorite: boolean;
  /** 已看：电影看整部，剧集看这一集 */
  played: boolean;
  /** 看了一半时的进度（1～99）；没看过、看完了为 null */
  progress_percent: number | null;
}

export interface ReelSegment {
  file_id: number;
  start_ms: number;
  end_ms: number;
}

/** 这一段配的字幕（服务端挑的中文内封轨） */
export interface ReelSubtitle {
  /** 同类型序号：`embedded:<ordinal>` */
  ordinal: number;
  language: string | null;
  title: string | null;
  codec: string | null;
  /** 只抽片段前后一小段的字幕文件（文件时间）；图形字幕没有（由转码压进画面） */
  url: string | null;
  /** srt / ass */
  format: string | null;
}

export interface ReelPlay {
  mode: string;
  /** clip：预切片段（带令牌的相对路径，第 0 秒对应原片 segment.start_ms） */
  clip_url: string | null;
  audio_ordinal: number | null;
  subtitle: ReelSubtitle | null;
}

export interface ReelItem {
  id: string;
  title: ReelTitle;
  cover_url: string | null;
  segment: ReelSegment;
  play: ReelPlay;
}

export interface ReelFeed {
  seed: number;
  next_offset: number;
  has_more: boolean;
  items: ReelItem[];
  /** 服务端开了「片段预切」时：当前条件下切好了几部（刷片只出这些） */
  clips: { ready: number; total: number; state: string } | null;
}

/** 筛选条件：与媒体库筛选同一个模型、同一套参数，另加只刷电影 / 剧集 / 其他（kind） */
export interface ReelQuery {
  filter: LibraryFilter;
  kind: string | null;
}

/** 取一页片段：第一页不带 seed，翻页时原样带回 */
export async function fetchReelFeed(
  page: { seed?: number; offset?: number; limit?: number },
  where: ReelQuery,
): Promise<ReelFeed> {
  const query = new URLSearchParams({ modes: "seek,clip", limit: String(page.limit ?? 8) });
  if (page.seed !== undefined) query.set("seed", String(page.seed));
  if (page.offset) query.set("offset", String(page.offset));
  reelFilterQuery(where.filter, where.kind, query);
  const response = await request<ApiEnvelope<ReelFeed>>(`/reels?${query}`);
  return response.data;
}

/** 筛选菜单的候选值与计数（每一维都排除本维自身的条件；为 0 的照常返回，置灰不可点） */
export interface ReelFacets {
  total: number;
  /** false = 当前池子是「其他」：没有 TMDB 档案，只剩观看状态可筛 */
  filterable: boolean;
  /** 空 = 没有可切换的类型（只有「其他」库），不显示这一行 */
  kinds: FacetValue[];
  genres: FacetValue[];
  countries: FacetValue[];
  decades: FacetValue[];
  ratings: FacetValue[];
  runtimes: FacetValue[];
  /** 只有「没看过」（unwatched）一项 */
  watch: FacetValue[];
}

export async function fetchReelFacets(where: ReelQuery): Promise<ReelFacets> {
  const query = new URLSearchParams();
  reelFilterQuery(where.filter, where.kind, query);
  const response = await request<ApiEnvelope<ReelFacets>>(`/reels/facets?${query}`);
  return response.data;
}

export type ReelEventKind = "impression" | "first_frame" | "leave" | "complete" | "open" | "detail" | "fail";

export interface ReelEvent {
  reel_id: string;
  kind: ReelEventKind;
  mode: string;
  media_item_id: number;
  file_id: number;
  position_ms?: number;
  watched_ms?: number;
  wait_ms?: number;
}

/** 刷片事件批量上报（只落 reel_event 表，不写观看记录；失败即丢） */
export async function reportReelEvents(events: ReelEvent[]): Promise<void> {
  if (events.length === 0) return;
  await request<ApiEnvelope<unknown>>("/reels/events", {
    method: "POST",
    body: JSON.stringify({ events }),
    keepalive: true,
  }).catch(() => undefined);
}

/**
 * 给 seek 那一条开播放会话（同 iPhone `ReelPlayer.startTranscode`）：不带设备标识与播放编号——
 * 刷片不登记到活动页，也不写续播点与播放次数。
 *
 * - `maxHeight`：片段的画质上限（null = 原画，交服务端按浏览器能力决定直出 / 转封装 / 转码）；
 * - `subtitleTrack`：要服务端压进画面的字幕。文字字幕由页面自己画（片段字幕文件），这里一律 off；
 *   只有图形字幕、且限了画质（反正要转码）时才请服务端压制（同 iPhone）。
 */
export async function startReelSession(
  item: ReelItem,
  capability: ClientCapability,
  options: { startMs: number; maxHeight: number | null; subtitleTrack: string },
): Promise<PlaybackSession> {
  const response = await request<ApiEnvelope<PlaybackSession>>("/playback/sessions", {
    method: "POST",
    body: JSON.stringify({
      file_id: item.segment.file_id,
      media_item_id: item.title.media_item_id,
      season_number: item.title.episode?.season ?? 0,
      episode_number: item.title.episode?.episode ?? 0,
      capability,
      start_ms: options.startMs,
      max_height: options.maxHeight ?? undefined,
      audio_track: item.play.audio_ordinal !== null ? `embedded:${item.play.audio_ordinal}` : undefined,
      subtitle_track: options.subtitleTrack,
    }),
  });
  return response.data;
}
