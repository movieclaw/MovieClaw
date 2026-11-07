import { PlaybackSessionPort, SessionProgress } from '@movieclaw/playback';
import { MovieClawApi } from '../api/Endpoints';
import { ApiError } from '../api/ApiClient';
import { PlaybackSessionView, PlaybackProgressRequest, PlaybackStateView } from '../api/Models';
import { JsonValue, jsonBoolValue } from '../api/JsonValue';

/**
 * TV / 车机的会话端口（PlaybackSessionPort 实现，配 PlaybackSessionCoordinator 的
 * start/progress/ping/stop 心跳协议）。上报字段沿用两端既有口径（旧引擎）：
 * - 音轨只报用户点选的 ref（报了会被当成用户选择记下）；
 * - 字幕只在用户碰过选择后报（关字幕报 'off'）——由 subtitle() 回调返回：
 *   '' = 没碰过（不上报）、'off' = 碰过且关、其余 = 选中的 track_ref；
 * - paused 只在 progress 事件上有意义；season/episode 为 0 时省略；
 * - device_id 带本机安装标识（tv.installation_id / car.installation_id；空 = 不报）。
 * TV/车机无分享访客播放，全部走站内接口。
 */
export class TvCarPlaybackSession implements PlaybackSessionPort {
  private api: MovieClawApi;
  private view: PlaybackSessionView;
  private itemId: number;
  private season: number;
  private episode: number;
  private deviceId: string;
  private audio: () => string;
  private subtitle: () => string;

  constructor(api: MovieClawApi,
    view: PlaybackSessionView,
    itemId: number,
    season: number,
    episode: number,
    deviceId: string,
    audio: () => string,
    subtitle: () => string) {
    this.api = api;
    this.view = view;
    this.itemId = itemId;
    this.season = season;
    this.episode = episode;
    this.deviceId = deviceId;
    this.audio = audio;
    this.subtitle = subtitle;
  }

  async report(event: string, progress: SessionProgress): Promise<boolean> {
    const audioRef: string = this.audio();
    const subtitleRef: string = this.subtitle();
    const body: PlaybackProgressRequest = {
      media_item_id: this.itemId,
      event: event,
      position_ms: event === 'start' ? null : progress.positionMs,
      audio_track: audioRef.length > 0 ? audioRef : null,
      subtitle_track: subtitleRef.length > 0 ? subtitleRef : null,
      file_id: this.view.decision.file_id ?? null,
      device_id: this.deviceId.length > 0 ? this.deviceId : null,
      paused: event === 'progress' ? !progress.playing : null
    };
    // season/episode 为 0 时省略字段（不能发 null：服务端这两列只收整数或缺省）
    if (this.season > 0) {
      body.season_number = this.season;
    }
    if (this.episode > 0) {
      body.episode_number = this.episode;
    }
    const state: PlaybackStateView = await this.api.playbackProgress(body);
    return state.ended_by_admin;
  }

  async ping(): Promise<string> {
    const id: string = this.view.session_id ?? '';
    if (id.length === 0) {
      return 'ok';
    }
    try {
      const response: Record<string, JsonValue> = await this.api.playbackSessionPing(id);
      return jsonBoolValue(response['failed']) === true ? 'failed' : 'ok';
    } catch (error) {
      if (error instanceof ApiError && error.status === 404) {
        return 'expired';
      }
      return 'ok';
    }
  }

  async close(): Promise<void> {
    const id: string = this.view.session_id ?? '';
    if (id.length === 0) {
      return;
    }
    await this.api.playbackSessionStop(id);
  }
}
