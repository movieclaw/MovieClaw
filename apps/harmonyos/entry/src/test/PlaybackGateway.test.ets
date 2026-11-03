import { describe, it, expect } from '@ohos/hypium';
import { ApiClient } from '../main/ets/api/ApiClient';
import { MovieClawApi } from '../main/ets/api/Endpoints';
import { PlaybackDecideRequest, PlaybackDecisionView, PlaybackSessionRequest, PlaybackSessionView } from '../main/ets/api/Models';
import { MovieClawPlaybackGateway } from '../main/ets/playback/MovieClawPlaybackGateway';

class GatewayApi extends MovieClawApi {
  calls: string[] = [];
  tier: number = 0;
  opened: PlaybackSessionRequest | null = null;
  constructor() { super(new ApiClient('https://fixture.invalid', null)); }
  async playbackDecide(body: PlaybackDecideRequest): Promise<PlaybackDecisionView> {
    this.calls.push((body.capability.audio ?? []).some((audio): boolean => audio.codec === 'flac') ? 'original' : 'native');
    return { outcome: 'plan', tier: this.tier, file_id: 42, audio_tracks: [], subtitles: [], reason: '' };
  }
  async playbackSessionStart(body: PlaybackSessionRequest): Promise<PlaybackSessionView> {
    this.calls.push('session'); this.opened = body;
    return { decision: { outcome: 'plan', tier: this.tier, audio_tracks: [], subtitles: [], reason: '' },
      progressive_segments: false, start_ms: 0, timeline: 'source', subtitle_urls: [], chapters: [] };
  }
}
function request(): PlaybackSessionRequest {
  return { media_item_id: 1, capability: MovieClawPlaybackGateway.capability('avplayer') };
}
export default function playbackGatewayTest() {
  describe('PlaybackGateway', () => {
    it('auto_requests_original_without_preparing_native_transcoding', 0, async () => {
      const api = new GatewayApi(); const body = request();
      await new MovieClawPlaybackGateway(api, '').open(body, 'auto');
      expect(api.calls.join(',')).assertEqual('original,session');
      expect(body.file_id).assertEqual(42);
      expect(body.capability.local_tracks).assertTrue();
      expect((body.capability.audio ?? []).some((audio): boolean => audio.codec === 'flac')).assertTrue();
    });
    it('unavailable_original_uses_native_server_adaptation', 0, async () => {
      const api = new GatewayApi(); api.tier = 2; const body = request();
      await new MovieClawPlaybackGateway(api, '').open(body, 'auto');
      expect(api.calls.join(',')).assertEqual('original,session');
      expect((body.capability.audio ?? []).some((audio): boolean => audio.codec === 'flac')).assertFalse();
    });
    it('failed_direct_tier_does_not_request_the_same_original_again', 0, async () => {
      const api = new GatewayApi(); const body = request(); body.failed_tiers = [0];
      await new MovieClawPlaybackGateway(api, '').open(body, 'auto');
      expect(api.calls.join(',')).assertEqual('session');
      expect((body.capability.audio ?? []).some((audio): boolean => audio.codec === 'flac')).assertFalse();
    });
    it('explicit_engine_preferences_skip_auto_negotiation', 0, async () => {
      for (const engine of ['avplayer', 'mpv']) {
        const api = new GatewayApi(); const body = request();
        await new MovieClawPlaybackGateway(api, '').open(body, engine);
        expect(api.calls.join(',')).assertEqual('session');
        expect((body.capability.audio ?? []).some((audio): boolean => audio.codec === 'flac')).assertEqual(engine === 'mpv');
      }
    });
  });
}
