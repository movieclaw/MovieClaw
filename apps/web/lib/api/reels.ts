import { request } from "@/lib/http";
import type { ClientCapability, PlaybackSession } from "@/lib/api/playback";

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
  backdrop_url: string | null;
  episode: { season: number; episode: number; name: string | null; overview: string | null } | null;
}

export interface ReelSegment {
  file_id: number;
  start_ms: number;
  end_ms: number;
}

export interface ReelPlay {
  mode: string;
  /** clip：预切片段（带令牌的相对路径，第 0 秒对应原片 segment.start_ms） */
  clip_url: string | null;
  audio_ordinal: number | null;
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

/** 取一页片段：第一页不带 seed，翻页时原样带回 */
export async function fetchReelFeed(page: { seed?: number; offset?: number; limit?: number } = {}): Promise<ReelFeed> {
  const query = new URLSearchParams({ modes: "seek,clip", limit: String(page.limit ?? 8) });
  if (page.seed !== undefined) query.set("seed", String(page.seed));
  if (page.offset) query.set("offset", String(page.offset));
  const response = await request<ApiEnvelope<ReelFeed>>(`/reels?${query}`);
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
 * 刷片不登记到活动页，也不写续播点与播放次数。字幕一期不开。
 */
export async function startReelSession(item: ReelItem, capability: ClientCapability): Promise<PlaybackSession> {
  const response = await request<ApiEnvelope<PlaybackSession>>("/playback/sessions", {
    method: "POST",
    body: JSON.stringify({
      file_id: item.segment.file_id,
      media_item_id: item.title.media_item_id,
      season_number: item.title.episode?.season ?? 0,
      episode_number: item.title.episode?.episode ?? 0,
      capability,
      start_ms: item.segment.start_ms,
      audio_track: item.play.audio_ordinal !== null ? `embedded:${item.play.audio_ordinal}` : undefined,
      subtitle_track: "off",
    }),
  });
  return response.data;
}
