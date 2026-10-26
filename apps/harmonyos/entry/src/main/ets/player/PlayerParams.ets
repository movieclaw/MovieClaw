/**
 * 播放器页的路由参数。
 *
 * 独立小文件：PlayerPage.ets 体积很大，入口页只需要参数类就能压路由，
 * 不应为了它把整个播放器页拉进启动模块图。
 */

/** 播放器页的路由参数（会序列化，不要用 instanceof） */
export class PlayerParams {
  readonly mediaItemId: number;
  readonly fileId: number;
  readonly seasonNumber: number;
  readonly episodeNumber: number;
  readonly startMs: number;
  /** 分享访客播放：走 /share/{slug}/playback 接口族，进度只存本机；空 = 站内播放 */
  readonly shareSlug: string;
  /** 片段播放（刷片页「全屏观看」，iOS `PlaybackClip`）：时间轴只算这段，不报观看进度 */
  readonly clipStartMs: number;
  readonly clipEndMs: number;

  constructor(mediaItemId: number, fileId: number = 0, seasonNumber: number = 0,
    episodeNumber: number = 0, startMs: number = 0, shareSlug: string = '',
    clipStartMs: number = 0, clipEndMs: number = 0) {
    this.mediaItemId = mediaItemId;
    this.fileId = fileId;
    this.seasonNumber = seasonNumber;
    this.episodeNumber = episodeNumber;
    this.startMs = startMs;
    this.shareSlug = shareSlug;
    this.clipStartMs = clipStartMs;
    this.clipEndMs = clipEndMs;
  }

  static of(param: Object | undefined | null): PlayerParams | null {
    if (param === undefined || param === null) {
      return null;
    }
    const raw: PlayerParams = param as PlayerParams;
    const id: number = raw.mediaItemId;
    if (!Number.isFinite(id) || id <= 0) {
      return null;
    }
    return new PlayerParams(Math.floor(id),
      Number.isFinite(raw.fileId) ? Math.floor(raw.fileId) : 0,
      Number.isFinite(raw.seasonNumber) ? Math.floor(raw.seasonNumber) : 0,
      Number.isFinite(raw.episodeNumber) ? Math.floor(raw.episodeNumber) : 0,
      Number.isFinite(raw.startMs) ? Math.floor(raw.startMs) : 0,
      raw.shareSlug !== undefined && raw.shareSlug !== null ? raw.shareSlug : '',
      Number.isFinite(raw.clipStartMs) ? Math.floor(raw.clipStartMs) : 0,
      Number.isFinite(raw.clipEndMs) ? Math.floor(raw.clipEndMs) : 0);
  }
}
