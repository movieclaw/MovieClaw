import { PlaybackSessionPort, SessionProgress } from '@movieclaw/playback';
import { MovieClawApi } from '../api/Endpoints';
import { ApiError } from '../api/ApiClient';
import { PlaybackSessionView, PlaybackProgressRequest } from '../api/Models';
import { jsonBoolValue } from '../api/JsonValue';
import { PlayerParams } from '../player/PlayerParams';
import { ShareLocalProgress } from '../share/ShareProgress';
import { MovieClawPlaybackGateway } from './MovieClawPlaybackGateway';

/** Captures the server, member/item identity and session at acquisition time. */
export class MovieClawPlaybackSession implements PlaybackSessionPort {
  private api: MovieClawApi;
  private view: PlaybackSessionView;
  private params: PlayerParams;
  constructor(api: MovieClawApi,
    view: PlaybackSessionView,
    params: PlayerParams) {
    this.api = api;
    this.view = view;
    this.params = params;
  }
  async report(event: string, progress: SessionProgress): Promise<boolean> {
    if (this.params.clipEndMs > this.params.clipStartMs) { return false; }
    const body: PlaybackProgressRequest = {
      media_item_id: this.params.mediaItemId, season_number: this.params.seasonNumber,
      episode_number: this.params.episodeNumber, event: event,
      position_ms: event === 'start' ? null : progress.positionMs,
      file_id: this.view.decision.file_id ?? null, audio_track: progress.audioTrack || null,
      subtitle_track: progress.subtitleTrack || null, paused: !progress.playing
    };
    if (this.params.shareSlug.length > 0) {
      if (event !== 'start') {
        const done = progress.durationMs > 0 && progress.positionMs >= progress.durationMs * 0.9;
        ShareLocalProgress.write(this.params.shareSlug, this.params.mediaItemId,
          this.params.seasonNumber, this.params.episodeNumber, done ? 0 : progress.positionMs);
      }
      return (await this.api.sharePlaybackProgress(this.params.shareSlug, body)).ended_by_admin;
    }
    return (await this.api.playbackProgress(body)).ended_by_admin;
  }
  async ping(): Promise<string> {
    const id = this.view.session_id ?? '';
    if (id.length === 0) { return 'ok'; }
    try {
      const response = this.params.shareSlug.length > 0
        ? await this.api.sharePlaybackSessionPing(id, this.params.shareSlug) : await this.api.playbackSessionPing(id);
      return jsonBoolValue(response['failed']) === true ? 'failed' : 'ok';
    } catch (error) {
      if (error instanceof ApiError && error.status === 404) { return 'expired'; }
      return 'ok';
    }
  }
  async close(): Promise<void> { await new MovieClawPlaybackGateway(this.api, this.params.shareSlug).stop(this.view); }
}
