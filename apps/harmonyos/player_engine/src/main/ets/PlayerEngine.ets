/** Engine boundary. Times are milliseconds on the supplied source timeline. */
export type EngineId = 'avplayer' | 'mpv';
export type EngineFailureKind = 'unsupported' | 'decode' | 'network' | 'source' | 'unavailable' | 'timeout' | 'internal';
export type EngineState = 'idle' | 'opening' | 'ready' | 'playing' | 'paused' | 'ended' | 'released';

export class EngineFailure extends Error {
  public kind: EngineFailureKind;
  public code: number;
  constructor(kind: EngineFailureKind,
    code: number,
    message: string) {
    super(message);
    this.kind = kind;
    this.code = code;
  }
  canFallback(): boolean {
    return this.kind === 'unsupported' || this.kind === 'decode' || this.kind === 'unavailable';
  }
}

export interface EngineSource {
  url: string;
  fd: number;
  length: number;
  subtitleUrl: string;
  subtitleFd: number;
  subtitleOffsetMs?: number;
  /** Content-sniffed sidecar format: 'ass' | 'srt' | 'vtt' | 'sup' | 'sub' | '' (none/offline-unknown). */
  subtitleFormat?: string;
  /** 远程 URL 是否 HLS（index.m3u8）：histreamer 的 HLS 管线 seek 后可能假 seekDone
   * 真冻结，AVPlayer 对这类源拒绝跳转转 mpv；直连 URL（/stream、/disc）走 HTTP
   * Range，seek 安全。缺省按 HLS 保守处理（旧调用方未标注时宁可转 mpv）。 */
  isHls?: boolean;
}

export interface EngineTrack {
  id: number;
  kind: string;
  language: string;
  title: string;
  selected: boolean;
}

export interface SubtitleStyle {
  fontScale: number;
  bottomPercent: number;
  background: boolean;
}

export class EngineEvent {
  type: string = '';
  state: EngineState = 'idle';
  positionMs: number = 0;
  durationMs: number = 0;
  bufferedMs: number = 0;
  width: number = 0;
  height: number = 0;
  hwdec: string = '';
  codec: string = '';
  pixelFormat: string = '';
  text: string = '';
  hint: string = '';
  failure: EngineFailure | null = null;
}

export interface PlayerEngine {
  readonly id: EngineId;
  onEvent: (event: EngineEvent) => void;
  open(source: EngineSource, surfaceId: string): Promise<void>;
  play(): Promise<void>;
  pause(): Promise<void>;
  seek(positionMs: number): Promise<void>;
  setRate(rate: number): Promise<void>;
  setGain(gain: number): Promise<void>;
  tracks(): Promise<EngineTrack[]>;
  selectTrack(kind: string, id: number): Promise<void>;
  setSubtitleStyle(style: SubtitleStyle): Promise<void>;
  release(): Promise<void>;
}

export interface EngineFactory {
  create(id: EngineId): Promise<PlayerEngine>;
}
