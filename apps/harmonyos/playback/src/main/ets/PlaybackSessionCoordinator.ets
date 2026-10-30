export interface SessionProgress {
  positionMs: number;
  durationMs: number;
  playing: boolean;
}
export interface PlaybackSessionPort {
  report(event: string, progress: SessionProgress): Promise<boolean>;
  ping(): Promise<string>;
  close(): Promise<void>;
}

/** One reporting/heartbeat owner per logical item. Late responses cannot affect its successor. */
export class PlaybackSessionCoordinator {
  private reportTail: Promise<void> = Promise.resolve();
  private port: PlaybackSessionPort | null = null;
  private generation: number = 0;
  private timer: number = -1;
  private elapsed: number = 0;
  private reporting: boolean = false;
  private pinging: boolean = false;
  private started: boolean = false;
  private stopped: boolean = false;
  private progress: SessionProgress = { positionMs: 0, durationMs: 0, playing: false };
  onHealth: (health: string) => void = (): void => {};
  bind(port: PlaybackSessionPort): void {
    this.close();
    this.reportTail = Promise.resolve();
    this.port = port; this.started = false; this.stopped = false; this.elapsed = 0;
    this.reporting = false; this.pinging = false;
    this.progress = { positionMs: 0, durationMs: 0, playing: false };
    this.timer = setInterval((): void => this.tick(), 1000);
  }
  update(positionMs: number, durationMs: number, playing: boolean): void {
    this.progress = { positionMs: positionMs, durationMs: durationMs, playing: playing };
    if (playing && !this.started) { this.started = true; this.report('start'); }
  }
  report(event: string): void {
    const port = this.port;
    if (port === null || this.stopped || (this.reporting && event === 'progress')) { return; }
    if (event === 'stop') { this.stopped = true; }
    const generation = this.generation;
    const progress = this.progress;
    this.reporting = true;
    this.reportTail = this.reportTail.then((): Promise<boolean> => port.report(event, progress)).then((ended: boolean): void => {
      if (generation === this.generation && ended) { this.onHealth('endedByAdmin'); }
    }).catch((): void => {}).finally((): void => {
      if (generation === this.generation) { this.reporting = false; }
    });
  }
  private tick(): void {
    this.elapsed++;
    if (this.elapsed % 10 === 0 && this.started) { this.report('progress'); }
    const port = this.port;
    if (port === null || this.elapsed % 15 !== 0 || this.pinging) { return; }
    const generation = this.generation;
    this.pinging = true;
    port.ping().then((health: string): void => {
      if (generation === this.generation && health !== 'ok') { this.onHealth(health); }
    }).catch((): void => {}).finally((): void => {
      if (generation === this.generation) { this.pinging = false; }
    });
  }
  close(): void {
    const port = this.port;
    if (port !== null && this.started && !this.stopped) { this.report('stop'); }
    ++this.generation;
    this.port = null;
    if (this.timer >= 0) { clearInterval(this.timer); this.timer = -1; }
    if (port !== null) {
      this.reportTail.then((): Promise<void> => port.close()).catch((): void => {});
    }
  }
}
