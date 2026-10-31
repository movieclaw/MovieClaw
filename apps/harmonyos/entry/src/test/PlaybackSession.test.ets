import { describe, it, expect } from '@ohos/hypium';
import { PlaybackSessionCoordinator, PlaybackSessionPort, SessionProgress } from '@movieclaw/playback';

class SessionPort implements PlaybackSessionPort {
  events: string[] = [];
  tracks: string[] = [];
  ended: boolean = false;
  gate: Promise<void> = Promise.resolve();
  async report(event: string, progress: SessionProgress): Promise<boolean> {
    await this.gate;
    this.events.push(`${event}:${progress.positionMs}`);
    this.tracks.push(`${event}:${progress.audioTrack ?? ''}:${progress.subtitleTrack ?? ''}`);
    return this.ended;
  }
  async ping(): Promise<string> { return 'ok'; }
  async close(): Promise<void> { this.events.push('close'); }
}
async function drain(): Promise<void> {
  for (let index = 0; index < 30; index++) { await Promise.resolve(); }
}
export default function playbackSessionTest() {
  describe('PlaybackSessionCoordinator', () => {
    it('queued_reports_keep_each_episodes_track_snapshot', 0, async () => {
      const coordinator = new PlaybackSessionCoordinator(); const first = new SessionPort(); const second = new SessionPort();
      let finish: () => void = (): void => {};
      first.gate = new Promise<void>((resolve): void => { finish = resolve; });
      coordinator.bind(first); coordinator.update(45000, 100000, true, 'audio-old', 'sub-old');
      coordinator.update(46000, 100000, true, 'audio-selected', 'off');
      coordinator.bind(second); coordinator.update(2000, 100000, true, 'audio-new', 'sub-new');
      finish(); await drain();
      expect(first.tracks.join(',')).assertEqual('start:audio-old:sub-old,stop:audio-selected:off');
      expect(second.tracks.join(',')).assertEqual('start:audio-new:sub-new');
      coordinator.close(); await drain();
    });
    it('reports_old_position_then_closes_old_session_before_releasing_identity', 0, async () => {
      const coordinator = new PlaybackSessionCoordinator(); const first = new SessionPort(); const second = new SessionPort();
      coordinator.bind(first); coordinator.update(45000, 100000, true);
      coordinator.bind(second); coordinator.update(2000, 100000, true); await drain();
      expect(first.events.join(',')).assertEqual('start:45000,stop:45000,close');
      expect(second.events.join(',')).assertEqual('start:2000'); coordinator.close(); await drain();
    });
    it('late_admin_end_from_previous_item_does_not_end_current_item', 0, async () => {
      const coordinator = new PlaybackSessionCoordinator(); const first = new SessionPort(); first.ended = true;
      let finish: () => void = (): void => {};
      first.gate = new Promise<void>((resolve): void => { finish = resolve; });
      let endings = 0; coordinator.onHealth = (): void => { endings++; };
      coordinator.bind(first); coordinator.update(1000, 100000, true);
      coordinator.bind(new SessionPort()); finish(); await drain();
      expect(endings).assertEqual(0); coordinator.close(); await drain();
    });
    it('repeated_close_does_not_duplicate_stop_or_server_close', 0, async () => {
      const coordinator = new PlaybackSessionCoordinator(); const port = new SessionPort();
      coordinator.bind(port); coordinator.update(7000, 100000, true);
      coordinator.close(); coordinator.close(); await drain();
      expect(port.events.join(',')).assertEqual('start:7000,stop:7000,close');
    });
  });
}
