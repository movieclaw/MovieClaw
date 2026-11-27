/**
 * 鸿蒙实况窗（Live View Kit）纯逻辑模型与节流器（无 Kit 依赖，可直接进主机单测）：
 * 负责离线缓存下载的锁屏卡片、灵动胶囊文案、网速/ETA 估算以及防高频 IPC 节流。
 */
export class DownloadLiveSnapshot {
  readonly title: string;
  readonly episodeLabel: string;
  readonly bytesDone: number;
  readonly bytesTotal: number;
  readonly speedBps: number;
  readonly remainingQueue: number;
  readonly done: boolean;

  constructor(title: string, episodeLabel: string, bytesDone: number, bytesTotal: number,
    speedBps: number, remainingQueue: number, done: boolean = false) {
    this.title = title;
    this.episodeLabel = episodeLabel;
    this.bytesDone = Math.max(0, bytesDone);
    this.bytesTotal = Math.max(0, bytesTotal);
    this.speedBps = Math.max(0, speedBps);
    this.remainingQueue = Math.max(0, remainingQueue);
    this.done = done;
  }

  progressPercent(): number {
    if (this.done) {
      return 100;
    }
    if (this.bytesTotal <= 0) {
      return 0;
    }
    return Math.max(0, Math.min(99, Math.round((this.bytesDone / this.bytesTotal) * 100)));
  }
}

export function formatLiveBytes(bytes: number): string {
  if (bytes < 1024) {
    return `${Math.max(0, Math.round(bytes))} B`;
  }
  const units: string[] = ['KB', 'MB', 'GB', 'TB'];
  let value: number = bytes;
  let unit: number = -1;
  do {
    value /= 1024;
    unit += 1;
  } while (value >= 1024 && unit < units.length - 1);
  return `${value >= 100 ? Math.round(value) : value.toFixed(1)} ${units[unit]}`;
}

export function formatLiveSpeed(speedBps: number): string {
  if (speedBps <= 0) {
    return '';
  }
  return `${formatLiveBytes(speedBps)}/s`;
}

export function formatLiveEta(remainingBytes: number, speedBps: number): string {
  if (remainingBytes <= 0 || speedBps <= 0) {
    return '';
  }
  const sec: number = Math.max(1, Math.round(remainingBytes / speedBps));
  if (sec < 60) {
    return `剩 ${sec} 秒`;
  }
  const min: number = Math.floor(sec / 60);
  if (min < 60) {
    return `剩 ${min} 分`;
  }
  const hr: number = Math.floor(min / 60);
  const remMin: number = min % 60;
  return remMin > 0 ? `剩 ${hr} 小时 ${remMin} 分` : `剩 ${hr} 小时`;
}

export function formatLiveCapsuleTitle(snap: DownloadLiveSnapshot): string {
  if (snap.done) {
    return '缓存完成';
  }
  const pct: number = snap.progressPercent();
  const speed: string = formatLiveSpeed(snap.speedBps);
  return speed.length > 0 ? `${pct}% · ${speed}` : `缓存 ${pct}%`;
}

export function formatLivePrimaryTitle(snap: DownloadLiveSnapshot): string {
  const base: string = snap.title.length > 0 ? snap.title : 'MovieClaw 离线缓存';
  const ep: string = snap.episodeLabel.length > 0 ? ` · ${snap.episodeLabel}` : '';
  return snap.done ? `已完成 · ${base}${ep}` : `正在缓存 · ${base}${ep}`;
}

export function formatLivePrimarySubtitle(snap: DownloadLiveSnapshot): string {
  if (snap.done) {
    return snap.bytesTotal > 0 ? `已保存 ${formatLiveBytes(snap.bytesTotal)}，离线可随时观看` : '离线副本已就绪，随时可看';
  }
  const parts: string[] = [];
  if (snap.bytesTotal > 0) {
    parts.push(`${formatLiveBytes(snap.bytesDone)} / ${formatLiveBytes(snap.bytesTotal)}`);
  } else if (snap.bytesDone > 0) {
    parts.push(`已下 ${formatLiveBytes(snap.bytesDone)}`);
  }
  const speed: string = formatLiveSpeed(snap.speedBps);
  if (speed.length > 0) {
    parts.push(speed);
  }
  const eta: string = formatLiveEta(snap.bytesTotal - snap.bytesDone, snap.speedBps);
  if (eta.length > 0) {
    parts.push(eta);
  }
  if (snap.remainingQueue > 0) {
    parts.push(`队列还有 ${snap.remainingQueue} 项`);
  }
  return parts.length > 0 ? parts.join(' · ') : '正在建立高速缓存通道…';
}

/** 实况窗 IPC 节流器：默认至少间隔 1200ms 或进度跃迁 ≥2%，起止与 100% 立即放行 */
export class LiveViewThrottle {
  private lastSentAtMs: number = 0;
  private lastSentPct: number = -1;
  private readonly minIntervalMs: number;
  private readonly minPctDelta: number;

  constructor(minIntervalMs: number = 1200, minPctDelta: number = 2) {
    this.minIntervalMs = minIntervalMs;
    this.minPctDelta = minPctDelta;
  }

  shouldEmit(nowMs: number, pct: number, active: boolean, force: boolean = false): boolean {
    if (force || !active || this.lastSentPct < 0) {
      this.lastSentAtMs = nowMs;
      this.lastSentPct = pct;
      return true;
    }
    if (nowMs - this.lastSentAtMs >= this.minIntervalMs || Math.abs(pct - this.lastSentPct) >= this.minPctDelta) {
      this.lastSentAtMs = nowMs;
      this.lastSentPct = pct;
      return true;
    }
    return false;
  }

  reset(): void {
    this.lastSentAtMs = 0;
    this.lastSentPct = -1;
  }
}
