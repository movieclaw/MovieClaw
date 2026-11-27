import { describe, expect, it } from '@ohos/hypium';
import { formatUserStars } from '../main/ets/common/StarRating';
import {
  ContinuationBridge,
  ContinuationTarget,
  decodeContinueParams,
  encodeContinueParams,
  parseMovieClawUri
} from '../main/ets/common/ContinuationBridge';
import { buildWidgetSnapshotFromUpNext, snapshotToFormPayload } from '../main/ets/common/WidgetSync';
import { intentToContinuationTarget } from '../main/ets/insight/XiaoyiIntentModel';
import { Chapters } from '../main/ets/player/Chapters';
import { DeviceVitals } from '../main/ets/player/DeviceVitals';
import { NetBench } from '../main/ets/player/NetBench';
import { ReelsFloorState } from '../main/ets/library/ReelsFloorModel';
import { MovieClawPlaybackGateway } from '../main/ets/playback/MovieClawPlaybackGateway';
import { DeviceCapability } from '../main/ets/playback/DeviceCapability';
import { TvCarPlaybackSession } from '../main/ets/playback/TvCarPlaybackSession';
import { MovieClawApi } from '../main/ets/api/Endpoints';
import { PlaybackChapterMarkView, PlaybackProgressRequest, PlaybackSessionView, UpNextItemView } from '../main/ets/api/Models';

export default function harmonyUpgradesTest(): void {
  describe('HarmonyUpgradesTest', () => {
    it('formats_user_stars_from_10_point_scale', 0, () => {
      expect(formatUserStars(0)).assertEqual('');
      expect(formatUserStars(null)).assertEqual('');
      expect(formatUserStars(10)).assertEqual('5.0');
      expect(formatUserStars(9)).assertEqual('4.5');
      expect(formatUserStars(2)).assertEqual('1.0');
    });

    it('parses_movieclaw_deep_links_and_roundtrips_continuation_params', 0, () => {
      const playTarget: ContinuationTarget | null = parseMovieClawUri(
        'movieclaw://play/42?library=3&file=9&season=2&episode=5&pos=185000&title=%E7%B9%81%E8%8A%B1'
      );
      expect(playTarget !== null).assertTrue();
      if (playTarget !== null) {
        expect(playTarget.kind).assertEqual('play');
        expect(playTarget.libraryId).assertEqual(3);
        expect(playTarget.mediaItemId).assertEqual(42);
        expect(playTarget.fileId).assertEqual(9);
        expect(playTarget.season).assertEqual(2);
        expect(playTarget.episode).assertEqual(5);
        expect(playTarget.positionMs).assertEqual(185000);
        expect(playTarget.title).assertEqual('繁花');

        const bag: Record<string, Object> = {};
        encodeContinueParams(playTarget, bag);
        const decoded: ContinuationTarget | null = decodeContinueParams(bag);
        expect(decoded !== null).assertTrue();
        if (decoded !== null) {
          expect(decoded.kind).assertEqual('play');
          expect(decoded.mediaItemId).assertEqual(42);
          expect(decoded.positionMs).assertEqual(185000);
        }
      }

      const contTarget: ContinuationTarget | null = parseMovieClawUri('movieclaw://continue');
      expect(contTarget !== null && contTarget.kind === 'continue_latest').assertTrue();

      const searchTarget: ContinuationTarget | null = parseMovieClawUri('movieclaw://search?q=%E6%B5%81%E6%B5%AA%E5%9C%B0%E7%90%83');
      expect(searchTarget !== null && searchTarget.query === '流浪地球').assertTrue();

      const bridge: ContinuationBridge = ContinuationBridge.shared();
      bridge.publishPlayback('http://nas:8000', 77, 11, 1, 3, (): number => 93400, '三体', 2);
      const wantParam: Record<string, Object> = {};
      expect(bridge.fillContinueWant(wantParam)).assertTrue();
      const restored: ContinuationTarget | null = decodeContinueParams(wantParam);
      expect(restored !== null && restored.positionMs === 93400 && restored.libraryId === 2).assertTrue();
      bridge.clearActive();
    });

    it('resolves_chapters_vitals_and_netbench_math', 0, () => {
      const chapters: PlaybackChapterMarkView[] = [
        { title: '序幕', start_ms: 0 },
        { title: '启航', start_ms: 60000 },
        { title: '高潮', start_ms: 180000 }
      ];
      expect(Chapters.activeIndex(chapters, 0)).assertEqual(0);
      expect(Chapters.activeIndex(chapters, 120000)).assertEqual(1);
      expect(Chapters.currentTitle(chapters, 200000)).assertEqual('高潮');

      expect(DeviceVitals.labelFromFlags(true, false, false)).assertEqual('Wi-Fi');
      expect(DeviceVitals.labelFromFlags(false, true, false)).assertEqual('有线');
      expect(DeviceVitals.labelFromFlags(false, false, true)).assertEqual('蜂窝');
      expect(NetBench.mbpsOf(5000000, 1000)).assertEqual(40);
    });

    it('drives_reels_floor_pull_threshold', 0, () => {
      const floor: ReelsFloorState = new ReelsFloorState();
      floor.begin();
      floor.drag(190);
      expect(floor.armed).assertFalse();
      floor.drag(225);
      expect(floor.armed).assertTrue();
      expect(floor.release()).assertTrue();
      floor.reset();
      expect(floor.armed).assertFalse();
    });

    it('declares_hdr_vivid_av3a_av1_and_tv_multichannel_capabilities', 0, () => {
      const phoneAvp = MovieClawPlaybackGateway.capability('avplayer', true, true);
      expect(phoneAvp.hdr_passthrough).assertTrue();
      expect(phoneAvp.video.some((v): boolean => v.codec === 'av1')).assertTrue();
      expect(phoneAvp.audio.some((a): boolean => a.codec === 'av3a')).assertTrue();

      const tvProfile = DeviceCapability.tv('tv-01');
      const tvAvp = DeviceCapability.forProfile(tvProfile, 'avplayer', true);
      expect(tvAvp.is_mobile).assertFalse();
      expect(tvAvp.device_id).assertEqual('tv-01');
      expect(tvAvp.audio.some((a): boolean => a.codec === 'eac3_joc' && a.max_channels === 8)).assertTrue();
    });

    it('builds_widget_snapshot_and_maps_xiaoyi_intents', 0, () => {
      const emptySnap = buildWidgetSnapshotFromUpNext(null);
      expect(emptySnap.hasItem).assertFalse();

      const sample: UpNextItemView = {
        media_item_id: 88,
        library_id: 4,
        kind: 'tv',
        title: '漫长的季节',
        season_number: 1,
        episode_number: 6,
        episode_title: '碎片的回响',
        position_ms: 1200000,
        duration_ms: 3600000,
        progress_percent: 33,
        advanced: false
      };
      const snap = buildWidgetSnapshotFromUpNext([sample]);
      expect(snap.hasItem).assertTrue();
      expect(snap.mediaItemId).assertEqual(88);
      expect(snap.progressPercent).assertEqual(33);
      expect(snap.remainingText).assertContain('40');
      const formPayload = snapshotToFormPayload(snap, 3);
      expect(formPayload['mcTitle'] === undefined && formPayload['title'] === '漫长的季节').assertTrue();

      const t1 = intentToContinuationTarget('ContinuePlay', {});
      expect(t1.kind).assertEqual('continue_latest');
      const t2 = intentToContinuationTarget('PlayItem', { 'title': '流浪地球2' });
      expect(t2.kind).assertEqual('play_by_title');
      expect(t2.query).assertEqual('流浪地球2');
      const t3 = intentToContinuationTarget('SubscribeVoice', { 'title': '沙丘2' });
      expect(t3.kind).assertEqual('subscribe_voice');
      const t4 = intentToContinuationTarget('OpenSubscriptions', {});
      expect(t4.kind).assertEqual('open_subscriptions');
      const t5 = intentToContinuationTarget('SearchInApp', { 'keyword': '诺兰' });
      expect(t5.kind).assertEqual('search');
      expect(t5.query).assertEqual('诺兰');
    });

    it('reports_tv_playback_session_with_harmony_tv_client_and_device_id', 0, async () => {
      let capturedClient: string = '';
      let capturedDevice: string = '';
      let stoppedId: string = '';
      const fakeApi = {
        playbackProgress: async (body: PlaybackProgressRequest) => {
          capturedClient = body.client ?? '';
          capturedDevice = body.device_id ?? '';
          return { ended_by_admin: false };
        },
        playbackSessionPing: async (_id: string) => {
          return { failed: false };
        },
        playbackSessionStop: async (id: string) => {
          stoppedId = id;
        }
      } as Object as MovieClawApi;

      const view: PlaybackSessionView = {
        decision: { outcome: 'plan', tier: 0, file_id: 55, audio_tracks: [], subtitles: [], reason: 'direct' },
        session_id: 'sess-tv-99',
        stream_url: '/files/55/stream?token=abc',
        progressive_segments: false,
        start_ms: 0,
        timeline: 'file',
        subtitle_urls: [],
        chapters: []
      };
      const port = new TvCarPlaybackSession(fakeApi, view, 101, 55, 1, 2, 'harmony_tv', 'livingroom-tv');
      const ended = await port.report('timeupdate', {
        positionMs: 45000,
        durationMs: 120000,
        playing: true,
        audioTrack: 'a0',
        subtitleTrack: 's0'
      });
      expect(ended).assertFalse();
      expect(capturedClient).assertEqual('harmony_tv');
      expect(capturedDevice).assertEqual('livingroom-tv');
      expect(await port.ping()).assertEqual('ok');
      await port.close();
      expect(stoppedId).assertEqual('sess-tv-99');
    });
  });
}
