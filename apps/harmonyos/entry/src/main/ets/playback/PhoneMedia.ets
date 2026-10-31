import { http } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { EngineSource, EngineFailure, EngineId } from '@movieclaw/player-engine';
import { MediaLease, PlaybackMedia, shiftSubtitleTimeline } from '@movieclaw/playback';
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
    try {
      // Fetch optional subtitles outside the native command queue, with HTTP deadlines.
      // A missing subtitle must never prevent acquisition of the video source.
      if (this.subtitleUrl.length > 0 && this.subtitlePath.length === 0) {
        try {
          temporaryPath = await this.downloadSubtitle(engine);
          subtitle = fileIo.openSync(temporaryPath, fileIo.OpenMode.READ_ONLY);
        } catch (error) {
          if (temporaryPath.length > 0) { fileIo.unlinkSync(temporaryPath); temporaryPath = ''; }
          hilog.warn(0x0000, 'PhoneMedia', '外挂字幕下载或加载失败，跳过字幕继续播放');
        }
      }
      if (this.path.length > 0) { media = fileIo.openSync(this.path, fileIo.OpenMode.READ_ONLY); }
      if (this.subtitlePath.length > 0) { subtitle = fileIo.openSync(this.subtitlePath, fileIo.OpenMode.READ_ONLY); }
      const source: EngineSource = { url: this.url, fd: media?.fd ?? -1,
        length: media === null ? 0 : OfflineDisk.fileSize(this.path),
        subtitleUrl: '', subtitleFd: subtitle?.fd ?? -1,
        subtitleOffsetMs: engine === 'mpv' ? this.originMs : 0 };
      return new PhoneMediaLease(source, media, subtitle, temporaryPath);
    } catch (error) {
      if (media !== null) { fileIo.closeSync(media); }
      if (subtitle !== null) { fileIo.closeSync(subtitle); }
      if (temporaryPath.length > 0) { fileIo.unlinkSync(temporaryPath); }
      if (error instanceof EngineFailure) { throw error; }
      throw new EngineFailure('source', 0, '本机媒体或字幕文件不可用');
    }
  }
  private async downloadSubtitle(engine: EngineId): Promise<string> {
    const request = http.createHttp();
    try {
      const response = await request.request(this.subtitleUrl, { method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER, connectTimeout: 10000, readTimeout: 15000 });
      if (response.responseCode !== 200) { throw new EngineFailure('network', response.responseCode, '字幕下载失败'); }
      const shift = engine === 'avplayer' && this.originMs > 0;
      // Preserve original bytes (including MPV bitmap subtitles) unless a text shift is needed.
      let content: string | ArrayBuffer = response.result as ArrayBuffer;
      let extension = 'sub';
      if (shift) {
        const text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(content));
        extension = text.includes('[Script Info]') ? 'ass' : text.includes('WEBVTT') ? 'vtt' : 'srt';
        if (!text.includes('-->') && !text.includes('Dialogue:')) {
          throw new EngineFailure('unsupported', 0, '系统播放器不支持此字幕格式');
        }
        content = shiftSubtitleTimeline(text, this.originMs);
      }
      const path = `${this.cacheDirectory}/playback-sub-${Date.now()}-${PhoneMedia.sequence++}.${extension}`;
      const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try { fileIo.writeSync(file.fd, content); }
      catch (error) { fileIo.closeSync(file); fileIo.unlinkSync(path); throw new EngineFailure('source', 0, '字幕临时文件写入失败'); }
      fileIo.closeSync(file);
      return path;
    } finally { request.destroy(); }
  }

}

export function playbackUrl(origin: string, path: string): string {
  if (path.startsWith('https://') || path.startsWith('http://')) { return path; }
  if (path.startsWith('//')) { return `${origin.startsWith('https:') ? 'https:' : 'http:'}${path}`; }
  return `${origin.replace(/\/$/, '')}/${path.replace(/^\//, '')}`;
}
