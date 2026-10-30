import { avSession } from '@kit.AVSessionKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common, wantAgent } from '@kit.AbilityKit';

/** Serialized system lifecycle prevents a late start from resurrecting a stopped session. */
export class PlaybackGuard {
  private session: avSession.AVSession | null = null;
  private background: boolean = false;
  private wanted: boolean = false;
  private disposed: boolean = false;
  private tail: Promise<void> = Promise.resolve();
  private lastBucket: number = -1;
  private lastPlaying: boolean = false;
  private context: common.UIAbilityContext;
  private onPlay: () => void;
  private onPause: () => void;
  private onSeek: (positionMs: number) => void;
  constructor(context: common.UIAbilityContext,
    onPlay: () => void,
    onPause: () => void,
    onSeek: (positionMs: number) => void) {
    this.context = context;
    this.onPlay = onPlay;
    this.onPause = onPause;
    this.onSeek = onSeek;
  }

  private enqueue(action: () => Promise<void>): Promise<void> {
    const next = this.tail.then(action);
    this.tail = next.catch((): void => {});
    return next;
  }
  start(title: string): Promise<void> {
    this.wanted = true;
    return this.enqueue(async (): Promise<void> => {
      if (this.disposed) { return; }
      if (this.session === null) {
        const session = await avSession.createAVSession(this.context, 'movieclaw-player', 'video');
        this.session = session;
        session.on('play', this.onPlay);
        session.on('pause', this.onPause);
        session.on('stop', this.onPause);
        session.on('seek', this.onSeek);
        await session.setAVMetadata({ assetId: 'movieclaw', title: title });
        await session.activate();
      }
      if (!this.background && !this.disposed && this.wanted) {
        const agent = await wantAgent.getWantAgent({
          wants: [{ bundleName: this.context.abilityInfo.bundleName, abilityName: this.context.abilityInfo.name }],
          actionType: wantAgent.OperationType.START_ABILITY, requestCode: 0,
          wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
        });
        if (this.disposed || !this.wanted) { return; }
        await backgroundTaskManager.startBackgroundRunning(this.context,
          backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, agent);
        this.background = true;
      }
    });
  }
  pause(): Promise<void> {
    this.wanted = false;
    return this.enqueue(async (): Promise<void> => this.releaseBackground());
  }
  updatePlayback(title: string, durationMs: number, positionMs: number, playing: boolean, rate: number): void {
    const bucket = Math.floor(positionMs / 1000);
    if (bucket === this.lastBucket && playing === this.lastPlaying) { return; }
    this.lastBucket = bucket; this.lastPlaying = playing;
    this.enqueue(async (): Promise<void> => {
      const session = this.session;
      if (session === null || this.disposed) { return; }
      await session.setAVMetadata({ assetId: 'movieclaw', title: title, duration: durationMs });
      await session.setAVPlaybackState({
        state: playing ? avSession.PlaybackState.PLAYBACK_STATE_PLAY : avSession.PlaybackState.PLAYBACK_STATE_PAUSE,
        speed: rate, position: { elapsedTime: positionMs, updateTime: Date.now() }
      });
    }).catch((): void => {});
  }
  stop(): Promise<void> {
    this.disposed = true; this.wanted = false;
    return this.enqueue(async (): Promise<void> => {
      await this.releaseBackground();
      const session = this.session; this.session = null;
      if (session !== null) {
        try { await session.deactivate(); } finally { await session.destroy(); }
      }
    });
  }
  private async releaseBackground(): Promise<void> {
    if (!this.background) { return; }
    await backgroundTaskManager.stopBackgroundRunning(this.context);
    this.background = false;
  }
}
