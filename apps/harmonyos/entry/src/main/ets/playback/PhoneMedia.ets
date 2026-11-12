import { http } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { EngineSource, EngineFailure, EngineId } from '@movieclaw/player-engine';
import { assToSrt, MediaLease, PlaybackMedia, shiftSubtitleTimeline } from '@movieclaw/playback';
import { OfflineDisk } from '../offline/OfflineDisk';

class PhoneMediaLease implements MediaLease {
  private closed: boolean = false;
  public source: EngineSource;
  private media: fileIo.File | null;
  private subtitle: fileIo.File | null;
  private temporaryPath: string;
  constructor(source: EngineSource,
    media: fileIo.File | null,
    subtitle: fileIo.File | null,
    temporaryPath: string = '') {
    this.source = source;
    this.media = media;
    this.subtitle = subtitle;
    this.temporaryPath = temporaryPath;
  }
  async close(): Promise<void> {
    if (this.closed) { return; }
    this.closed = true;
    if (this.media !== null) { fileIo.closeSync(this.media); }
    if (this.subtitle !== null) { fileIo.closeSync(this.subtitle); }
    if (this.temporaryPath.length > 0) { fileIo.unlinkSync(this.temporaryPath); }
  }
}

export class DownloadedSubtitle {
  public path: string;
  public format: string;
  constructor(path: string, format: string) {
    this.path = path;
    this.format = format;
  }
}
/** Immutable source recipe; AVPlayer and MPV never share an open fd or seek offset. */
export class PhoneMedia implements PlaybackMedia {
  public originMs: number;
  public durationMs: number;
  private url: string;
  private path: string;
  private subtitleUrl: string;
  private subtitlePath: string;
  private cacheDirectory: string;
  private isHls: boolean;
  constructor(originMs: number,
    durationMs: number,
    url: string,
    path: string = '',
    subtitleUrl: string = '',
    subtitlePath: string = '',
    cacheDirectory: string = '',
    isHls: boolean = false) {
    this.originMs = originMs;
    this.durationMs = durationMs;
    this.url = url;
    this.path = path;
    this.subtitleUrl = subtitleUrl;
    this.subtitlePath = subtitlePath;
    this.cacheDirectory = cacheDirectory;
    this.isHls = isHls;
  }
  private static sequence: number = 0;
  async acquire(engine: EngineId): Promise<MediaLease> {
    let media: fileIo.File | null = null;
    let subtitle: fileIo.File | null = null;
    let temporaryPath = '';
    let subtitleFormat = '';
    try {
      // Fetch optional subtitles outside the native command queue, with HTTP deadlines.
      // A missing subtitle must never prevent acquisition of the video source.
      if (this.subtitleUrl.length > 0 && this.subtitlePath.length === 0) {
        try {
          const downloaded = await this.downloadSubtitle(engine);
          temporaryPath = downloaded.path;
          subtitleFormat = downloaded.format;
          subtitle = fileIo.openSync(temporaryPath, fileIo.OpenMode.READ_ONLY);
        } catch (error) {
          if (temporaryPath.length > 0) { fileIo.unlinkSync(temporaryPath); temporaryPath = ''; }
          // 异常 message 可能整段带签名 URL（token 在查询串里），原样落日志会泄签名，只记分类与码。
          const reason = error instanceof EngineFailure ? `${error.kind}(${error.code})` : '网络异常';
          hilog.warn(0x0000, 'MCSub', '字幕下载失败(%{public}s)，跳过字幕继续播放', reason);
        }
      }
      if (this.path.length > 0) { media = fileIo.openSync(this.path, fileIo.OpenMode.READ_ONLY); }
      if (this.subtitlePath.length > 0) {
        subtitle = fileIo.openSync(this.subtitlePath, fileIo.OpenMode.READ_ONLY);
        // 离线外挂按文件扩展名给格式（mpv 用它判定原生上屏层开关）。
        subtitleFormat = this.subtitlePath.split('.').pop()?.toLowerCase() ?? '';
      }
      const source: EngineSource = { url: this.url, fd: media?.fd ?? -1,
        length: media === null ? 0 : OfflineDisk.fileSize(this.path),
        subtitleUrl: '', subtitleFd: subtitle?.fd ?? -1,
        subtitleOffsetMs: engine === 'mpv' ? this.originMs : 0,
        subtitleFormat: subtitleFormat, isHls: this.isHls };
      return new PhoneMediaLease(source, media, subtitle, temporaryPath);
    } catch (error) {
      if (media !== null) { fileIo.closeSync(media); }
      if (subtitle !== null) { fileIo.closeSync(subtitle); }
      if (temporaryPath.length > 0) { fileIo.unlinkSync(temporaryPath); }
      if (error instanceof EngineFailure) { throw error; }
      throw new EngineFailure('source', 0, '本机媒体或字幕文件不可用');
    }
  }
  /** mpv 在播时就地换旁挂只下字幕文件，不走 acquire 整租约（媒体 fd/流不动）。 */
  async downloadSidecar(engine: EngineId): Promise<DownloadedSubtitle> {
    return this.downloadSubtitle(engine);
  }
  private async downloadSubtitle(engine: EngineId): Promise<DownloadedSubtitle> {
    const request = http.createHttp();
    try {
      // 内封轨首抽要通读整个容器（PT 片源几十 GB 常见），服务端抽完才开始回包；
      // readTimeout 给太短，客户端断开会反过来取消服务端抽取，缓存永远建不起来。
      const response = await request.request(this.subtitleUrl, { method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER, connectTimeout: 10000, readTimeout: 60000 });
      if (response.responseCode !== 200) { throw new EngineFailure('network', response.responseCode, '字幕下载失败'); }
      const shift = engine === 'avplayer' && this.originMs > 0;
      const raw = response.result as ArrayBuffer;
      const bytes = new Uint8Array(raw);
      // 扩展名按内容定（mpv 按扩展名选解复用器）：文字轨给真实后缀，
      // PGS（'PG' 魔数）保字节存 .sup，其余维持 .sub 原样写。
      let extension = 'sub';
      let content: string | ArrayBuffer = raw;
      if (bytes.length >= 2 && bytes[0] === 0x50 && bytes[1] === 0x47) {
        extension = 'sup';
        if (shift) { throw new EngineFailure('unsupported', 0, '系统播放器不支持此字幕格式'); }
      } else {
        const text = util.TextDecoder.create('utf-8').decodeToString(bytes);
        if (text.includes('-->') || text.includes('Dialogue:') || text.includes('WEBVTT')) {
          extension = text.includes('[Script Info]') ? 'ass' : text.includes('WEBVTT') ? 'vtt' : 'srt';
          if (extension === 'ass' && engine === 'avplayer') {
            // 系统播放器外挂只认 SRT/VTT：ASS 就地转纯文本 SRT（Android SubtitleCues 同口径，样式丢弃）。
            extension = 'srt';
            content = shift ? shiftSubtitleTimeline(assToSrt(text), this.originMs) : assToSrt(text);
          } else if (shift) {
            content = shiftSubtitleTimeline(text, this.originMs);
          }
        } else if (shift) {
          throw new EngineFailure('unsupported', 0, '系统播放器不支持此字幕格式');
        }
      }
      const path = `${this.cacheDirectory}/playback-sub-${Date.now()}-${PhoneMedia.sequence++}.${extension}`;
      hilog.info(0x0000, 'MCSub', '%{public}s', `字幕下载完成: ${bytes.length} 字节 → .${extension} engine=${engine}`);
      const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try { fileIo.writeSync(file.fd, content); }
      catch (error) { fileIo.closeSync(file); fileIo.unlinkSync(path); throw new EngineFailure('source', 0, '字幕临时文件写入失败'); }
      fileIo.closeSync(file);
      return new DownloadedSubtitle(path, extension);
    } finally { request.destroy(); }
  }

}

/** PGS 旁挂 .sup 的会话内缓存：一次下载，重挂/切引擎复用；换文件/换轨作废。 */
export interface PgsSidecarCache {
  fileId: number;
  ref: string;
  path: string;
}

let pgsSidecarSequence: number = 0;

/** 回收 PGS 旁挂临时文件（尽力而为；文件仍被引擎持有 fd 时 unlink 也安全）。 */
export function removePgsSidecar(path: string): void {
  if (path.length === 0) { return; }
  try { fileIo.unlinkSync(path); }
  catch (error) { hilog.warn(0x0000, 'MCSub', 'PGS 旁挂回收失败: %{public}s', `${error}`); }
}

/**
 * 后台下载 PGS 旁挂 .sup（网页 libbitsub + fetchSupBytes 的客户端同款路径）。
 * `requestInStream` 分块落盘，绕开 NETSTACK 内存响应的大小上限（PGS 整轨可达
 * 几十 MB，12:33 那次 ARRAY_BUFFER 下载正是死在上限上）。服务端首次要通读容器
 * 抽取、抽完才回包，空窗可能几分钟：readTimeout 给足 10 分钟，对齐网页「一次
 * 连通等到抽完」的语义（浏览器 fetch 没有首字节超时，nginx 的 proxy_read_timeout
 * 才是真实上限；客户端断开会反过来取消服务端抽取，读超时绝不能给短）。
 */
export async function downloadPgsSidecar(url: string, cacheDirectory: string): Promise<string> {
  const session = http.createHttp();
  let file: fileIo.File | null = null;
  let path: string = '';
  let received: number = 0;
  let magicValid: boolean = false;
  // 'PG' 魔数可能跨 chunk 到达（分块传输下首块 0/1 字节并不奇怪）：攒满两个
  // 字节再判，判过才开文件——此前只看首块，首块太短就把整份合法 PGS 当无效丢了
  let magicPending: number[] = [];
  try {
    session.on('dataReceive', (chunk: ArrayBuffer): void => {
      let payload: ArrayBuffer = chunk;
      if (!magicValid) {
        if (magicPending.length >= 2) { return; }
        const bytes = new Uint8Array(chunk);
        const take: number = Math.min(bytes.length, 2 - magicPending.length);
        for (let i = 0; i < take; i++) { magicPending.push(bytes[i]); }
        if (magicPending.length < 2) { return; }
        magicValid = magicPending[0] === 0x50 && magicPending[1] === 0x47;
        if (!magicValid) { return; }
        payload = chunk.slice(take);
      }
      if (file === null) {
        path = `${cacheDirectory}/playback-pgs-${Date.now()}-${pgsSidecarSequence++}.sup`;
        file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      }
      if (magicPending.length > 0) {
        const head: ArrayBuffer = new ArrayBuffer(2);
        const headView: Uint8Array = new Uint8Array(head);
        headView[0] = magicPending[0]; headView[1] = magicPending[1];
        fileIo.writeSync(file.fd, head);
        magicPending = [];
      }
      if (payload.byteLength > 0) { fileIo.writeSync(file.fd, payload); }
      received += chunk.byteLength;
    });
    const code: number = await new Promise<number>(
      (resolve: (value: number) => void,
        reject: (reason: BusinessError) => void): void => {
        session.requestInStream(url, { method: http.RequestMethod.GET,
          connectTimeout: 10000, readTimeout: 600000 }, (error: BusinessError, data: number): void => {
          if (error !== null && error !== undefined) { reject(error); } else { resolve(data); }
        });
      });
    if (code !== 200 || !magicValid || received <= 0) {
      throw new EngineFailure('network', code, `图形字幕下载失败（${code}）`);
    }
    hilog.info(0x0000, 'MCSub', '%{public}s', `PGS 旁挂下载完成: ${received} 字节`);
    return path;
  } catch (error) {
    const failure: EngineFailure = error instanceof EngineFailure ? error
      : new EngineFailure('network', 0, '图形字幕下载失败');
    if (file !== null) { fileIo.closeSync(file); file = null; }
    removePgsSidecar(path);
    throw failure;
  } finally {
    session.off('dataReceive');
    session.destroy();
    if (file !== null) { fileIo.closeSync(file); }
  }
}

export function playbackUrl(origin: string, path: string): string {
  if (path.startsWith('https://') || path.startsWith('http://')) { return path; }
  if (path.startsWith('//')) { return `${origin.startsWith('https:') ? 'https:' : 'http:'}${path}`; }
  return `${origin.replace(/\/$/, '')}/${path.replace(/^\//, '')}`;
}
