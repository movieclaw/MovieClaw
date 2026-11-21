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
  /** 本地字幕文件路径（在播引擎动态挂旁挂用；mpv 自己打开，调用方只管删源文件）。 */
  subtitlePath?: string;
  subtitleOffsetMs?: number;
  /** Content-sniffed sidecar format: 'ass' | 'srt' | 'vtt' | 'sup' | 'sub' | '' (none/offline-unknown). */
  subtitleFormat?: string;
  /** 远程 URL 是否 HLS（index.m3u8）：histreamer 的 HLS 管线 seek 后可能假 seekDone
   * 真冻结，AVPlayer 对这类源拒绝跳转转 mpv；直连 URL（/stream、/disc）走 HTTP
   * Range，seek 安全。缺省按 HLS 保守处理（旧调用方未标注时宁可转 mpv）。 */
  isHls?: boolean;
  /** AVPlayer 冻结看门狗的触发拍数（1 拍 = 2 秒）；缺省 15 拍（30 秒）。
   * 缺省值留给网盘直出（on_drive，可能被 302 到网盘直链或由服务端中继）：
   * 服务端换连接续传最坏 ~25 秒才把流救回来，触发线必须盖过救援窗口。
   * 本地盘/NAS 直出与 HLS 没有等救援一说，调用方传 6（12 秒）——histreamer
   * 的解复用线程在 seek/暂停恢复后可能停止从满缓冲取数（状态 playing、时钟
   * 停走、零 error，2026-11-21 取证），楔死确定性复现，12 秒判死换引擎比
   * 30 秒少冻一半。 */
  stallSamples?: number;
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
  /** 在播引擎就地换旁挂字幕（不重开流）；三个字幕源全空表示只卸不加（裸播）。 */
  attachSubtitle(source: EngineSource): Promise<void>;
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
