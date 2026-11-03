import { http } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
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

class DownloadedSubtitle {
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
  constructor(originMs: number,
    durationMs: number,
    url: string,
    path: string = '',
    subtitleUrl: string = '',
    subtitlePath: string = '',
    cacheDirectory: string = '') {
    this.originMs = originMs;
    this.durationMs = durationMs;
    this.url = url;
    this.path = path;
    this.subtitleUrl = subtitleUrl;
    this.subtitlePath = subtitlePath;
    this.cacheDirectory = cacheDirectory;
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
          hilog.warn(0x0000, 'MCSub', '字幕下载或加载失败，跳过字幕继续播放: %{public}s', `${error}`);
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
        subtitleFormat: subtitleFormat };
      return new PhoneMediaLease(source, media, subtitle, temporaryPath);
    } catch (error) {
      if (media !== null) { fileIo.closeSync(media); }
      if (subtitle !== null) { fileIo.closeSync(subtitle); }
      if (temporaryPath.length > 0) { fileIo.unlinkSync(temporaryPath); }
      if (error instanceof EngineFailure) { throw error; }
      throw new EngineFailure('source', 0, '本机媒体或字幕文件不可用');
    }
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

export function playbackUrl(origin: string, path: string): string {
  if (path.startsWith('https://') || path.startsWith('http://')) { return path; }
  if (path.startsWith('//')) { return `${origin.startsWith('https:') ? 'https:' : 'http:'}${path}`; }
  return `${origin.replace(/\/$/, '')}/${path.replace(/^\//, '')}`;
}
