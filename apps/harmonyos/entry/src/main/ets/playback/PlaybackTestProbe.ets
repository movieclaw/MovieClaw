import { hilog } from '@kit.PerformanceAnalysisKit';
import { Want } from '@kit.AbilityKit';
import { PlaybackSnapshot } from '@movieclaw/playback';
import { DevConfig } from '../common/DevConfig';
import { NavStacks } from '../common/ShareLinks';
import { PlayerParams } from '../player/PlayerParams';
import { PlayerPrefs } from '../player/PlayerPrefs';

export interface PlaybackTestHost {
  audioRef: string;
  subtitleRef: string;
  inspectTracks(): Promise<string>;
  play(): void;
  pause(): void;
  seekTo(positionMs: number): void;
  retryPlayback(): void;
  pickAudio(ref: string): Promise<void>;
  pickSubtitle(index: number): Promise<void>;
  pickQuality(height: number): Promise<void>;
}
interface PlaybackTestRequest {
  caseId: string;
  itemId: number;
  fileId: number;
  season: number;
  episode: number;
  startMs: number;
  engine: string;
  command?: string;
  positionMs?: number;
  value?: number;
  trackRef?: string;
  subtitleRef?: string;
  proxyOrigin?: string;
}
interface PlaybackTestRecord {
  caseId: string;
  at: number;
  event: string;
  engine: string;
  phase: string;
  positionMs: number;
  durationMs: number;
  playing: boolean;
  buffering: boolean;
  firstFrame: boolean;
  detail: string;
}

/** Debug-only device test entry and redacted timing evidence; contains no credentials or media URLs. */
export class PlaybackTestProbe {
  private static host: PlaybackTestHost | null = null;
  private static caseId: string = '';
  private static lastKey: string = '';
  private static proxyOrigin: string = '';
  private static audioRef: string = '';
  private static subtitleRef: string = '';
  static mediaUrl(url: string): string {
    if (!DevConfig.isDev || PlaybackTestProbe.proxyOrigin.length === 0) { return url; }
    return url.replace(/^https?:\/\/[^/]+/, PlaybackTestProbe.proxyOrigin);
  }
  private static snapshot: PlaybackSnapshot = new PlaybackSnapshot();
  static bind(host: PlaybackTestHost): void { if (DevConfig.isDev) { PlaybackTestProbe.host = host; host.audioRef = PlaybackTestProbe.audioRef; host.subtitleRef = PlaybackTestProbe.subtitleRef; } }
  static observe(snapshot: PlaybackSnapshot): void {
    if (!DevConfig.isDev || PlaybackTestProbe.caseId.length === 0) { return; }
    PlaybackTestProbe.snapshot = snapshot;
    const key = `${snapshot.engine}:${snapshot.phase}:${Math.floor(snapshot.positionMs / 1000)}:${snapshot.buffering}:${snapshot.firstFrame}`;
    if (key !== PlaybackTestProbe.lastKey) { PlaybackTestProbe.lastKey = key; PlaybackTestProbe.record('snapshot'); }
  }
  static record(event: string, detail: string = ''): void {
    if (!DevConfig.isDev || PlaybackTestProbe.caseId.length === 0) { return; }
    const state = PlaybackTestProbe.snapshot;
    const record: PlaybackTestRecord = { caseId: PlaybackTestProbe.caseId, at: Date.now(), event: event,
      engine: state.engine, phase: state.phase, positionMs: state.positionMs, durationMs: state.durationMs,
      playing: state.playing, buffering: state.buffering, firstFrame: state.firstFrame,
      detail: detail.replace(/https?:\/\/[^\s"<>]+/g, '[media URL]')
        .replace(/([?&]token=)[^&\s"<>]+/g, '$1[redacted]') };
    hilog.info(0x0000, 'MCPlaybackTest', '%{public}s', JSON.stringify(record));
  }
  static handle(want: Want): void {
    if (!DevConfig.isDev) { return; }
    const raw = want.parameters?.['mcPlaybackTest'];
    if (typeof raw !== 'string') { return; }
    let request: PlaybackTestRequest;
    try { request = JSON.parse(raw) as PlaybackTestRequest; } catch (error) { return; }
    const stack = NavStacks.of(NavStacks.currentKey);
    if (request.command) {
      PlaybackTestProbe.record('command', request.command);
      if (request.command === 'pause') { PlaybackTestProbe.host?.pause(); }
      else if (request.command === 'play') { PlaybackTestProbe.host?.play(); }
      else if (request.command === 'seek') { PlaybackTestProbe.host?.seekTo(request.positionMs ?? 0); }
      else if (request.command === 'tracks') {
        PlaybackTestProbe.host?.inspectTracks().then((tracks: string): void => { PlaybackTestProbe.record('tracks', tracks); })
          .catch((): void => { PlaybackTestProbe.record('commandFailure', 'tracks'); });
      }
      else if (request.command === 'retry') { PlaybackTestProbe.host?.retryPlayback(); }
      else if (request.command === 'audio') { PlaybackTestProbe.host?.pickAudio(request.trackRef ?? '').catch((): void => { PlaybackTestProbe.record('commandFailure', 'pickAudio'); }); }
      else if (request.command === 'subtitle') { PlaybackTestProbe.host?.pickSubtitle(request.value ?? -1).catch((): void => { PlaybackTestProbe.record('commandFailure', 'pickSubtitle'); }); }
      else if (request.command === 'quality') { PlaybackTestProbe.host?.pickQuality(request.value ?? 0).catch((): void => { PlaybackTestProbe.record('commandFailure', 'pickQuality'); }); }
      else if (request.command === 'stop') { stack?.pop(); }
      return;
    }
    if (stack === null || request.itemId <= 0 || request.fileId <= 0) { return; }
    PlaybackTestProbe.proxyOrigin = /^http:\/\/127\.0\.0\.1:[0-9]+$/.test(request.proxyOrigin ?? '')
      ? (request.proxyOrigin ?? '') : '';
    PlaybackTestProbe.audioRef = request.trackRef ?? '';
    PlaybackTestProbe.subtitleRef = request.subtitleRef ?? '';
    PlaybackTestProbe.caseId = request.caseId; PlaybackTestProbe.lastKey = '';
    PlaybackTestProbe.snapshot = new PlaybackSnapshot();
    PlayerPrefs.writeEngine(request.engine || 'auto');
    PlaybackTestProbe.record('request', `${request.fileId}`);
    stack.pushPathByName('player', new PlayerParams(request.itemId, request.fileId,
      request.season, request.episode, request.startMs));
  }
}
