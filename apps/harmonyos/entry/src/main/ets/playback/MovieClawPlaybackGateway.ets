import { MovieClawApi } from '../api/Endpoints';
import { ClientCapabilityIn, PlaybackSessionRequest, PlaybackSessionView, PlaybackDecisionView, PlaybackDecideRequest,
  VideoSupportIn, AudioSupportIn } from '../api/Models';

/** Existing-server adapter. Each candidate is evaluated independently, never unioned. */
export class MovieClawPlaybackGateway {
  static capability(engine: string, pgsOverlay: boolean = false): ClientCapabilityIn {
    const video: VideoSupportIn[] = [];
    const audio: AudioSupportIn[] = [];
    const videos = engine === 'mpv' ? ['h264', 'hevc', 'vp8', 'vp9', 'mpeg2video', 'mpeg4', 'vc1'] : ['h264', 'hevc'];
    const audios = engine === 'mpv' ? ['aac', 'mp3', 'ac3', 'eac3', 'dts', 'flac', 'opus', 'vorbis', 'alac', 'truehd', 'mp2',
      'pcm_s16le', 'pcm_s24le', 'pcm_bluray', 'pcm_dvd'] : ['aac', 'mp3'];
    for (const codec of videos) { video.push({ codec: codec, max_height: 2160 }); }
    for (const codec of audios) { audio.push({ codec: codec }); }
    return { video: video, audio: audio, containers: engine === 'mpv'
      ? ['mp4', 'mkv', 'ts', 'avi', 'mov', 'webm', 'flv'] : ['mp4', 'mkv', 'ts'],
      local_tracks: true, hdr_passthrough: false, mse: 'full', native_hls: true, is_mobile: true, universal: false,
      // B 方案：未烧录 PGS 由本端渲染——tier-0 直连走 mpv 原生内封 sid，其余档
      // 下载 .sup 旁挂后按次强制 mpv 渲染（对齐 0.49 网页/Android 的本地渲染
      // 路线）。申报是 app 级能力，与本次协商的投递引擎无关。
      pgs_overlay: pgsOverlay };
  }
  private api: MovieClawApi;
  private slug: string;
  constructor(api: MovieClawApi,
    slug: string) {
    this.api = api;
    this.slug = slug;
  }
  private decide(body: PlaybackSessionRequest): Promise<PlaybackDecisionView> {
    const request: PlaybackDecideRequest = { file_id: body.file_id, media_item_id: body.media_item_id,
      season_number: body.season_number, episode_number: body.episode_number, capability: body.capability,
      failed_tiers: body.failed_tiers, audio_track: body.audio_track, subtitle_track: body.subtitle_track,
      max_height: body.max_height };
    return this.slug.length > 0 ? this.api.sharePlaybackDecide(this.slug, request) : this.api.playbackDecide(request);
  }
  async open(body: PlaybackSessionRequest, preference: string, pgsOverlay: boolean = false): Promise<PlaybackSessionView> {
    body.capability = MovieClawPlaybackGateway.capability(preference === 'mpv' ? 'mpv' : 'avplayer', pgsOverlay);
    if (preference === 'auto' && !(body.failed_tiers ?? []).includes(0)) {
      // Ask for a playable original before preparing any server conversion.
      // The local controller still tries AVPlayer first, regardless of this delivery capability.
      body.capability = MovieClawPlaybackGateway.capability('mpv', pgsOverlay);
      // Do not let a remembered embedded PGS force the preflight into a
      // transcode before the direct tier is known; the real request below
      // gets the native-PGS capability once tier 0 is established.
      const rememberedTrack: string | null = body.subtitle_track ?? null;
      const probeStripped: boolean = rememberedTrack !== null && rememberedTrack.startsWith('embedded:');
      if (probeStripped) { body.subtitle_track = null; }
      const original = await this.decide(body);
      if (probeStripped) { body.subtitle_track = rememberedTrack; }
      if (original.outcome === 'plan' && original.tier === 0) {
        // The preflight established a tier-0 direct file, so mpv may claim
        // native embedded PGS for the real session.
        body.capability = MovieClawPlaybackGateway.capability('mpv', true);
        if (original.file_id !== undefined && original.file_id !== null) { body.file_id = original.file_id; }
      } else {
        body.capability = MovieClawPlaybackGateway.capability('avplayer', pgsOverlay);
      }
    }
    return this.slug.length > 0 ? this.api.sharePlaybackSessionStart(this.slug, body) : this.api.playbackSessionStart(body);
  }
  async stop(view: PlaybackSessionView): Promise<void> {
    const id = view.session_id ?? '';
    if (id.length === 0) { return; }
    if (this.slug.length > 0) { await this.api.sharePlaybackSessionStop(id, this.slug); }
    else { await this.api.playbackSessionStop(id); }
  }
}
