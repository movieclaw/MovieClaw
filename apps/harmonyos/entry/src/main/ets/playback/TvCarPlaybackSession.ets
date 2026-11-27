import { PlaybackSessionPort, SessionProgress } from '@movieclaw/playback';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { jsonBoolValue } from '../api/JsonValue';
import { PlaybackProgressRequest, PlaybackSessionView } from '../api/Models';
import { MovieClawPlaybackGateway } from './MovieClawPlaybackGateway';

/**
 * TV / 车机与服务端会话心跳、进度上报端口（严格实现 `PlaybackSessionPort`，支持自定义 `client` 与 `deviceId`）。
 */
export class TvCarPlaybackSession implements PlaybackSessionPort {
  private readonly api: MovieClawApi;
  private readonly view: PlaybackSessionView;
  private readonly mediaItemId: number;
  private readonly fileId: number;
  private readonly seasonNumber: number;
  private readonly episodeNumber: number;
  private readonly clientName: string;
  private readonly deviceId: string;

  constructor(
    api: MovieClawApi,
    view: PlaybackSessionView,
    mediaItemId: number,
    fileId: number,
    seasonNumber: number,
    episodeNumber: number,
    clientName: string,
    deviceId: string = ''
  ) {
    this.api = api;
    this.view = view;
    this.mediaItemId = mediaItemId;
    this.fileId = view.decision.file_id ?? fileId;
    this.seasonNumber = seasonNumber;
    this.episodeNumber = episodeNumber;
    this.clientName = clientName;
    this.deviceId = deviceId;
  }

  async report(event: string, progress: SessionProgress): Promise<boolean> {
    const body: PlaybackProgressRequest = {
      media_item_id: this.mediaItemId,
      file_id: this.fileId > 0 ? this.fileId : null,
      season_number: this.seasonNumber > 0 ? this.seasonNumber : 0,
      episode_number: this.episodeNumber > 0 ? this.episodeNumber : 0,
      event: event,
      position_ms: event === 'start' ? null : progress.positionMs,
      duration_ms: progress.durationMs > 0 ? progress.durationMs : null,
      paused: !progress.playing,
      client: this.clientName,
      device_id: this.deviceId.length > 0 ? this.deviceId : null,
      audio_track: progress.audioTrack.length > 0 ? progress.audioTrack : null,
      subtitle_track: progress.subtitleTrack.length > 0 ? progress.subtitleTrack : null
    };
    const res = await this.api.playbackProgress(body);
    return res.ended_by_admin;
  }

  async ping(): Promise<string> {
    const id: string = this.view.session_id ?? '';
    if (id.length === 0) {
      return 'ok';
    }
    try {
      const response = await this.api.playbackSessionPing(id);
      if (jsonBoolValue(response['ended_by_admin']) === true) {
        return 'endedByAdmin';
      }
      return jsonBoolValue(response['failed']) === true ? 'failed' : 'ok';
    } catch (error) {
      if (error instanceof ApiError && error.status === 404) {
        return 'expired';
      }
      return 'ok';
    }
  }

  async close(): Promise<void> {
    await new MovieClawPlaybackGateway(this.api, '').stop(this.view);
  }
}
