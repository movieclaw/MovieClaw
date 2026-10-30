import { http } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
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
      if (engine === 'avplayer' && this.originMs > 0 && this.subtitleUrl.length > 0) {
        temporaryPath = await this.shiftedSubtitle();
        subtitle = fileIo.openSync(temporaryPath, fileIo.OpenMode.READ_ONLY);
      }
      if (this.path.length > 0) { media = fileIo.openSync(this.path, fileIo.OpenMode.READ_ONLY); }
      if (this.subtitlePath.length > 0) { subtitle = fileIo.openSync(this.subtitlePath, fileIo.OpenMode.READ_ONLY); }
      const source: EngineSource = { url: this.url, fd: media?.fd ?? -1,
        length: media === null ? 0 : OfflineDisk.fileSize(this.path),
        subtitleUrl: temporaryPath.length > 0 ? '' : this.subtitleUrl, subtitleFd: subtitle?.fd ?? -1,
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
  private async shiftedSubtitle(): Promise<string> {
    const request = http.createHttp();
    try {
      const response = await request.request(this.subtitleUrl, { method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING, connectTimeout: 10000, readTimeout: 15000 });
      if (response.responseCode !== 200) { throw new EngineFailure('network', response.responseCode, '字幕下载失败'); }
      const text = response.result as string;
      const extension = text.includes('[Script Info]') ? 'ass' : text.includes('WEBVTT') ? 'vtt' : 'srt';
      if (!text.includes('-->') && !text.includes('Dialogue:')) {
        throw new EngineFailure('unsupported', 0, '系统播放器不支持此字幕格式');
      }
      const path = `${this.cacheDirectory}/playback-sub-${Date.now()}-${PhoneMedia.sequence++}.${extension}`;
      const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try { fileIo.writeSync(file.fd, shiftSubtitleTimeline(text, this.originMs)); }
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
