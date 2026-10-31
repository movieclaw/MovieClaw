import { describe, it, expect } from '@ohos/hypium';
import { EngineEvent, EngineFactory, EngineFailure, EngineId, EngineSource, EngineTrack,
  PlayerEngine, SubtitleStyle } from '@movieclaw/player-engine';
import { MediaLease, PlaybackController, PlaybackIntent, PlaybackMedia, shiftSubtitleTimeline } from '@movieclaw/playback';

class FakeEngine implements PlayerEngine {
  onEvent: (event: EngineEvent) => void = (): void => {};
  calls: string[] = [];
  source: EngineSource | null = null;
  fixtureTracks: EngineTrack[] | null = null;
  failure: EngineFailure | null = null;
  gate: Promise<void> = Promise.resolve();
  seekGate: Promise<void> = Promise.resolve();
  playGate: Promise<void> = Promise.resolve();
  releaseGate: Promise<void> = Promise.resolve();
  afterSeek: () => void = (): void => {};
  rejectRate: boolean = false;
  public id: EngineId;
  private order: string[];
  constructor(id: EngineId,
    order: string[]) {
    this.id = id;
    this.order = order;
  }
  async open(source: EngineSource, surface: string): Promise<void> {
    this.source = source; this.calls.push(`open:${surface}`);
    await this.gate;
    if (this.failure !== null) { throw this.failure; }
  }
  async play(): Promise<void> { this.calls.push('play'); await this.playGate; this.state('playing'); }
  async pause(): Promise<void> { this.calls.push('pause'); this.state('paused'); }
  async seek(ms: number): Promise<void> { this.calls.push(`seek:${ms}`); await this.seekGate; this.afterSeek(); }
  async setRate(rate: number): Promise<void> {
    if (this.rejectRate) { throw new Error('follow-up command rejected'); }
    this.calls.push(`rate:${rate}`);
  }
  async setGain(gain: number): Promise<void> { this.calls.push(`gain:${gain}`); }
  async setSubtitleStyle(style: SubtitleStyle): Promise<void> {}
  async tracks(): Promise<EngineTrack[]> {
    if (this.fixtureTracks !== null) { return this.fixtureTracks; }
    return [{ id: this.id === 'avplayer' ? 2 : 17, kind: 'audio', language: 'jpn', title: '', selected: false }];
  }
  async selectTrack(kind: string, id: number): Promise<void> { this.calls.push(`${kind}:${id}`); }
  async release(): Promise<void> {
    this.calls.push('release'); this.order.push(`${this.id}:release`); await this.releaseGate;
  }
  state(state: 'playing' | 'paused' | 'ended'): void {
    const event = new EngineEvent(); event.type = 'state'; event.state = state; this.onEvent(event);
  }
  time(ms: number): void {
    const event = new EngineEvent(); event.type = 'time'; event.positionMs = ms; event.durationMs = 100000; this.onEvent(event);
  }
  interrupt(hint: string): void {
    const event = new EngineEvent(); event.type = 'interrupt'; event.hint = hint; this.onEvent(event);
  }
}
class FakeFactory implements EngineFactory {
  order: string[] = [];
  created: string[] = [];
  avp: FakeEngine = new FakeEngine('avplayer', this.order);
  mpv: FakeEngine = new FakeEngine('mpv', this.order);
  creation: Promise<void> = Promise.resolve();
  async create(id: EngineId): Promise<PlayerEngine> {
    this.created.push(id); await this.creation;
    return id === 'avplayer' ? this.avp : this.mpv;
  }
}
class FakeLease implements MediaLease {
  public source: EngineSource;
  private order: string[];
  private number: number;
  constructor(source: EngineSource,
    order: string[],
    number: number) {
    this.source = source;
    this.order = order;
    this.number = number;
  }
  async close(): Promise<void> { this.order.push(`lease:${this.number}:close`); }
}
class FakeMedia implements PlaybackMedia {
  originMs: number = 0;
  durationMs: number = 100000;
  acquired: number = 0;
  private order: string[];
  constructor(order: string[]) {
    this.order = order;
  }
  async acquire(): Promise<MediaLease> {
    this.acquired++;
    return new FakeLease({ url: 'https://fixture.invalid/movie', fd: this.acquired,
      length: 100, subtitleFd: -1, subtitleUrl: '' }, this.order, this.acquired);
  }
}
class Gate {
  release: () => void = (): void => {};
  promise: Promise<void> = new Promise<void>((resolve): void => { this.release = resolve; });
}
async function microtasks(): Promise<void> {
  for (let i = 0; i < 30; i++) { await Promise.resolve(); }
}

export default function playbackControllerTest() {
  describe('PlaybackController', () => {
    it('release_completes_while_play_is_unacknowledged', 0, async () => {
      const factory = new FakeFactory(); const gate = new Gate(); factory.avp.playGate = gate.promise;
      const controller = new PlaybackController(factory);
      const opening = controller.open(new FakeMedia(factory.order), 'surface', new PlaybackIntent());
      await microtasks(); await controller.release(); await opening;
      expect(controller.current().phase).assertEqual('idle');
      gate.release(); await microtasks();
      expect(controller.current().phase).assertEqual('idle');
    });
    it('release_deadline_keeps_the_lease_until_native_teardown_finishes', 0, async () => {
      const factory = new FakeFactory(); const gate = new Gate(); factory.mpv.releaseGate = gate.promise;
      const controller = new PlaybackController(factory);
      await controller.open(new FakeMedia(factory.order), 'surface', new PlaybackIntent(), 'mpv');
      await controller.release();
      expect(controller.current().phase).assertEqual('idle');
      expect(factory.order.join(',')).assertEqual('mpv:release');
      gate.release(); await microtasks();
      expect(factory.order.join(',')).assertEqual('mpv:release,lease:1:close');
    });
    it('defaults_to_AVPlayer_without_creating_MPV', 0, async () => {
      const factory = new FakeFactory(); const controller = new PlaybackController(factory);
      await controller.open(new FakeMedia(factory.order), 'surface', new PlaybackIntent());
      expect(factory.created.join(',')).assertEqual('avplayer');
      expect(controller.current().playing).assertTrue();
      expect(controller.current().firstFrame).assertFalse();
      await controller.release();
    });
    it('fallback_does_not_keep_the_failed_engines_buffering_state', 0, async () => {
      const factory = new FakeFactory(); const gate = new Gate(); factory.avp.gate = gate.promise;
      factory.avp.failure = new EngineFailure('unsupported', 5400106, 'fixture');
      const controller = new PlaybackController(factory);
      const opening = controller.open(new FakeMedia(factory.order), 'surface', new PlaybackIntent());
      await microtasks();
      const buffering = new EngineEvent(); buffering.type = 'buffering'; buffering.hint = 'start';
      factory.avp.onEvent(buffering);
      expect(controller.current().buffering).assertTrue();
      gate.release(); await opening;
      expect(controller.current().engine).assertEqual('mpv');
      expect(controller.current().buffering).assertFalse();
      await controller.release();
    });
    it('fallback_waits_for_a_fresh_surface_after_releasing_the_native_producer', 0, async () => {
      const factory = new FakeFactory(); const gate = new Gate();
      factory.avp.failure = new EngineFailure('unsupported', 5400106, 'fixture');
      const controller = new PlaybackController(factory);
      controller.onSurfaceReset = async (): Promise<string> => {
        expect(factory.order.join(',')).assertEqual('avplayer:release,lease:1:close');
        await gate.promise; return 'replacement';
      };
      const opening = controller.open(new FakeMedia(factory.order), 'original', new PlaybackIntent());
      await microtasks(); expect(factory.created.join(',')).assertEqual('avplayer');
      gate.release(); await opening;
      expect(factory.mpv.calls.includes('open:replacement')).assertTrue();
      await controller.release();
    });
    it('exiting_while_surface_is_recreated_does_not_start_a_stale_fallback', 0, async () => {
      const factory = new FakeFactory(); const gate = new Gate();
      factory.avp.failure = new EngineFailure('unsupported', 5400106, 'fixture');
      const controller = new PlaybackController(factory);
      controller.onSurfaceReset = async (): Promise<string> => { await gate.promise; return 'stale'; };
      const opening = controller.open(new FakeMedia(factory.order), 'original', new PlaybackIntent());
      await microtasks(); await controller.release(); gate.release(); await opening;
      expect(factory.created.join(',')).assertEqual('avplayer');
      expect(controller.current().phase).assertEqual('idle');
    });
    it('unsupported_reopens_same_media_with_independent_lease_and_preserves_intent', 0, async () => {
      const factory = new FakeFactory(); const media = new FakeMedia(factory.order);
      factory.avp.failure = new EngineFailure('unsupported', 5400106, 'fixture');
      const intent = new PlaybackIntent(); intent.positionMs = 42000; intent.paused = true; intent.rate = 1.5;
      const controller = new PlaybackController(factory);
      await controller.open(media, 'surface', intent);
      expect(factory.created.join(',')).assertEqual('avplayer,mpv');
      expect(factory.order.join(',')).assertEqual('avplayer:release,lease:1:close');
      expect(factory.mpv.source?.fd).assertEqual(2);
      expect(factory.mpv.calls.includes('seek:42000')).assertTrue();
      expect(factory.mpv.calls.includes('rate:1.5')).assertTrue();
      expect(factory.mpv.calls.includes('play')).assertFalse();
      await controller.release();
      expect(factory.order.join(',')).assertEqual('avplayer:release,lease:1:close,mpv:release,lease:2:close');
    });
    it('first_opening_failure_survives_secondary_state_errors_and_rejection', 0, async () => {
      const factory = new FakeFactory(); const controller = new PlaybackController(factory);
      factory.avp.rejectRate = true;
      factory.avp.afterSeek = (): void => {
        const first = new EngineEvent(); first.type = 'error';
        first.failure = new EngineFailure('decode', 5400103, 'demux failure');
        factory.avp.onEvent(first);
        const secondary = new EngineEvent(); secondary.type = 'error';
        secondary.failure = new EngineFailure('internal', 5400102, 'state error');
        factory.avp.onEvent(secondary);
      };
      let code = 0;
      controller.onEvent = (event: EngineEvent): void => {
        if (event.type === 'fallback') { code = event.failure?.code ?? 0; }
      };
      const intent = new PlaybackIntent(); intent.positionMs = 42000;
      await controller.open(new FakeMedia(factory.order), 'surface', intent);
      expect(factory.created.join(',')).assertEqual('avplayer,mpv');
      expect(code).assertEqual(5400103);
      expect(controller.current().playing).assertTrue();
      await controller.release();
    });
    it('runtime_service_death_reopens_MPV_at_current_position', 0, async () => {
      const factory = new FakeFactory(); const controller = new PlaybackController(factory);
      await controller.open(new FakeMedia(factory.order), 'surface', new PlaybackIntent());
      factory.avp.time(42000);
      const failure = new EngineEvent(); failure.type = 'error';
      failure.failure = new EngineFailure('unavailable', 5400105, 'service died fixture');
      factory.avp.onEvent(failure);
      await microtasks(); await microtasks();
      expect(factory.created.join(',')).assertEqual('avplayer,mpv');
      expect(factory.order.join(',')).assertEqual('avplayer:release,lease:1:close');
      expect(factory.mpv.calls.includes('seek:42000')).assertTrue();
      expect(controller.current().playing).assertTrue();
      await controller.release();
    });
    it('network_failure_does_not_trigger_codec_fallback', 0, async () => {
      const factory = new FakeFactory(); const controller = new PlaybackController(factory);
      factory.avp.failure = new EngineFailure('network', 5411010, 'certificate fixture');
      await controller.open(new FakeMedia(factory.order), 'surface', new PlaybackIntent());
      expect(factory.created.join(',')).assertEqual('avplayer');
      expect(controller.current().failure?.kind).assertEqual('network');
      await controller.release();
    });
    it('both_engines_failing_emits_one_terminal_failure', 0, async () => {
      const factory = new FakeFactory(); const controller = new PlaybackController(factory);
      factory.avp.failure = new EngineFailure('unsupported', 1, 'fixture');
      factory.mpv.failure = new EngineFailure('unsupported', 2, 'fixture');
      let failures = 0; controller.onFailure = (): void => { failures++; };
      await controller.open(new FakeMedia(factory.order), 'surface', new PlaybackIntent());
      expect(failures).assertEqual(1); expect(factory.created.length).assertEqual(2);
      await controller.release();
    });
    it('explicit_engine_selection_is_respected', 0, async () => {
      const factory = new FakeFactory(); const controller = new PlaybackController(factory);
      await controller.open(new FakeMedia(factory.order), 'surface', new PlaybackIntent(), 'mpv');
      expect(factory.created.join(',')).assertEqual('mpv'); await controller.release();
    });
    it('text_subtitles_follow_nonzero_session_origin', 0, () => {
      expect(shiftSubtitleTimeline('00:00:32,500 --> 00:00:34,000\nHello', 30000))
        .assertEqual('00:00:02,500 --> 00:00:04,000\nHello');
      expect(shiftSubtitleTimeline('Dialogue: 0,0:00:32.50,0:00:34.00,Default,,0,0,0,,Hello', 30000))
        .assertContain('00:00:02.50,00:00:04.00');
    });
    it('seek_before_server_window_requests_a_new_source', 0, async () => {
      const factory = new FakeFactory(); const media = new FakeMedia(factory.order); media.originMs = 30000;
      const controller = new PlaybackController(factory); let requested = -1;
      controller.onSeekOutsideWindow = (ms: number): void => { requested = ms; };
      const intent = new PlaybackIntent(); intent.positionMs = 30000;
      await controller.open(media, 'surface', intent); await controller.seek(10000);
      expect(requested).assertEqual(10000);
      expect(factory.avp.calls.includes('seek:0')).assertFalse(); await controller.release();
    });
    it('file_and_stream_time_are_converted_once', 0, async () => {
      const factory = new FakeFactory(); const media = new FakeMedia(factory.order); media.originMs = 30000;
      const intent = new PlaybackIntent(); intent.positionMs = 42000;
      const controller = new PlaybackController(factory); await controller.open(media, 'surface', intent);
      expect(factory.avp.calls.includes('seek:12000')).assertTrue();
      factory.avp.time(15000); expect(controller.current().positionMs).assertEqual(45000);
      expect(controller.current().durationMs).assertEqual(100000);
      await controller.seek(50000); expect(factory.avp.calls.includes('seek:20000')).assertTrue();
      await controller.release();
    });
    it('released_while_factory_pending_disposes_orphan_without_acquiring_file', 0, async () => {
      const factory = new FakeFactory(); const gate = new Gate(); factory.creation = gate.promise;
      const media = new FakeMedia(factory.order); const controller = new PlaybackController(factory);
      const opening = controller.open(media, 'old-surface', new PlaybackIntent());
      await microtasks(); await controller.release(); gate.release(); await opening;
      expect(factory.avp.calls.includes('release')).assertTrue(); expect(media.acquired).assertEqual(0);
    });
    it('released_while_open_pending_does_not_play_after_late_ready', 0, async () => {
      const factory = new FakeFactory(); const gate = new Gate(); factory.avp.gate = gate.promise;
      const controller = new PlaybackController(factory);
      const opening = controller.open(new FakeMedia(factory.order), 'surface', new PlaybackIntent());
      await microtasks(); await controller.release(); gate.release(); await opening;
      expect(factory.avp.calls.includes('play')).assertFalse();
      expect(factory.order.join(',')).assertEqual('avplayer:release,lease:1:close');
    });
    it('pause_during_open_is_applied_before_play', 0, async () => {
      const factory = new FakeFactory(); const gate = new Gate(); factory.avp.gate = gate.promise;
      const controller = new PlaybackController(factory);
      const opening = controller.open(new FakeMedia(factory.order), 'surface', new PlaybackIntent());
      await microtasks(); await controller.pause(); gate.release(); await opening;
      expect(factory.avp.calls.includes('play')).assertFalse(); await controller.release();
    });
    it('user_pause_cancels_interruption_resume', 0, async () => {
      const factory = new FakeFactory(); const controller = new PlaybackController(factory);
      await controller.open(new FakeMedia(factory.order), 'surface', new PlaybackIntent());
      factory.avp.interrupt('pause'); await microtasks(); await controller.pause();
      const plays = factory.avp.calls.filter((call: string): boolean => call === 'play').length;
      factory.avp.interrupt('resume'); await microtasks();
      expect(factory.avp.calls.filter((call: string): boolean => call === 'play').length).assertEqual(plays);
      await controller.release();
    });
    it('same_language_audio_tracks_keep_the_chosen_ordinal_after_fallback', 0, async () => {
      const factory = new FakeFactory(); const controller = new PlaybackController(factory);
      factory.avp.failure = new EngineFailure('unsupported', 5400106, 'fixture');
      factory.mpv.fixtureTracks = [
        { id: 17, kind: 'audio', language: 'eng', title: '', selected: false },
        { id: 18, kind: 'audio', language: 'eng', title: '', selected: false }
      ];
      const intent = new PlaybackIntent(); intent.audio = { language: 'eng', title: '', ordinal: 1 };
      await controller.open(new FakeMedia(factory.order), 'surface', intent);
      expect(factory.mpv.calls.includes('audio:18')).assertTrue();
      await controller.release();
    });
    it('incomplete_native_audio_list_falls_back_instead_of_playing_the_wrong_track', 0, async () => {
      const factory = new FakeFactory(); const controller = new PlaybackController(factory);
      factory.avp.fixtureTracks = [{ id: 1, kind: 'audio', language: 'eng', title: '', selected: true }];
      factory.mpv.fixtureTracks = [
        { id: 1, kind: 'audio', language: 'eng', title: '', selected: false },
        { id: 2, kind: 'audio', language: 'eng', title: '', selected: false }
      ];
      const intent = new PlaybackIntent(); intent.audio = { language: 'eng', title: '', ordinal: 1, sourceCount: 2 };
      await controller.open(new FakeMedia(factory.order), 'surface', intent);
      expect(factory.created.join(',')).assertEqual('avplayer,mpv');
      expect(factory.mpv.calls.includes('audio:2')).assertTrue();
      await controller.release();
    });
    it('track_preferences_are_mapped_to_each_engines_ids', 0, async () => {
      const factory = new FakeFactory(); const controller = new PlaybackController(factory);
      const intent = new PlaybackIntent(); intent.audio = { language: 'jpn', title: '', ordinal: 0 };
      factory.avp.failure = new EngineFailure('unsupported', 1, 'fixture');
      await controller.open(new FakeMedia(factory.order), 'surface', intent);
      expect(factory.mpv.calls.includes('audio:17')).assertTrue(); await controller.release();
    });
    it('replay_seeks_to_the_beginning_before_playing', 0, async () => {
      const factory = new FakeFactory(); const controller = new PlaybackController(factory);
      await controller.open(new FakeMedia(factory.order), 'surface', new PlaybackIntent());
      factory.avp.time(100000); factory.avp.state('ended');
      await controller.play();
      expect(factory.avp.calls.slice(-2).join(',')).assertEqual('seek:0,play');
      await controller.release();
    });
    it('on_demand_segment_seek_can_take_more_than_five_seconds', 0, async () => {
      const factory = new FakeFactory(); const controller = new PlaybackController(factory);
      await controller.open(new FakeMedia(factory.order), 'surface', new PlaybackIntent());
      factory.avp.seekGate = new Promise<void>((resolve): void => { setTimeout(resolve, 6000); });
      await controller.seek(30000);
      expect(controller.current().phase === 'failed').assertFalse();
      expect(controller.current().positionMs).assertEqual(30000);
      await controller.release();
    });
    it('duck_restores_stream_gain_without_changing_system_volume', 0, async () => {
      const factory = new FakeFactory(); const controller = new PlaybackController(factory);
      await controller.open(new FakeMedia(factory.order), 'surface', new PlaybackIntent());
      factory.avp.interrupt('duck'); await microtasks(); factory.avp.interrupt('unduck'); await microtasks();
      expect(factory.avp.calls.includes('gain:0.2')).assertTrue();
      expect(factory.avp.calls[factory.avp.calls.length - 1]).assertEqual('gain:1'); await controller.release();
    });
  });
}
