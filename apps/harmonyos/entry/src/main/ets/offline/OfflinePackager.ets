import { http } from '@kit.NetworkKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { ImageUrls, ImageVariant } from '../common/ImageUrls';
import { OfflineDisk } from './OfflineDisk';
import { OfflineStore } from './OfflineStore';
import {
  OfflinePlaybackSpec,
  OfflineSubtitleSpec,
  OfflineUnit } from './OfflineModels';
import {
  OfflineManifestView,
  OfflineSubtitleView } from '../api/Models';

/**
 * 打包一个单元视频之外的东西（对应 iOS `Shared/Offline/OfflinePackager.swift`，
 * 设计 docs/design/offline-download.md §5.4「准备中」）：展示数据（详情、库、这一季
 * 的分集）、播放数据（章节、片段、音轨）、字幕、字体、图片。
 *
 * 都在前台、普通接口会话里拉（体积小）；图片缺了不影响完成，其余失败整次准备失败、
 * 对账时重来。图片存进 `images/`（`index.json` 记「原始地址 → 文件名」，离线展示靠它）。
 */
export class OfflinePackager {
  /** 字幕抽取（内封轨要服务端通读整个容器）、字体抽取可能很慢 */
  private static readonly slowTimeoutMs: number = 600000;

  private readonly origin: string;
  private readonly token: string;
  private readonly ownerKey: string;
  private readonly manifest: OfflineManifestView;
  private readonly unit: OfflineUnit;

  constructor(origin: string, token: string, ownerKey: string,
    manifest: OfflineManifestView, unit: OfflineUnit) {
    this.origin = origin;
    this.token = token;
    this.ownerKey = ownerKey;
    this.manifest = manifest;
    this.unit = unit;
  }

  async run(): Promise<void> {
    const manifest: OfflineManifestView = this.manifest;
    const key: string = this.ownerKey;
    const itemId: number = manifest.media_item_id;
    const unitDir: string = OfflineDisk.unitDir(key, itemId, this.unit.fileId);

    // 展示数据原样存 JSON，离线时原样喂给页面
    OfflineDisk.writeJSON(OfflineDisk.detailFile(key, itemId), manifest.item as Object);
    OfflineDisk.writeJSON(OfflineDisk.libraryFile(key, itemId), manifest.library as Object);
    if (manifest.season !== null && manifest.season !== undefined) {
      OfflineDisk.writeJSON(OfflineDisk.seasonFile(key, itemId, manifest.season.season_number),
        manifest.season as Object);
    }
    OfflineDisk.ensureDir(unitDir);

    // 打包时服务器上的续播点：本机还没有进度时先用它（离线时从这里接着看）
    const resume: number | null = manifest.resume_position_ms ?? null;
    if (resume !== null && resume > 0
      && OfflineStore.shared.localProgress(itemId, this.unit.season, this.unit.episode) === null) {
      OfflineStore.shared.recordProgress(itemId, this.unit.season, this.unit.episode,
        resume, false, manifest.duration_ms ?? null, 0);
    }

    // 字幕：原画档的内封轨在文件里，引擎自己读；外挂轨、转码档的全部文字轨存成旁挂文件
    const subtitles: OfflineSubtitleSpec[] = [];
    const original: boolean = this.unit.profile === 'original';
    for (let index: number = 0; index < manifest.subtitles.length; index++) {
      const sub: OfflineSubtitleView = manifest.subtitles[index];
      if (original && sub.embedded) {
        continue;
      }
      const name: string = `${index}-${OfflinePackager.safeName(sub.language ?? 'und')}.${sub.format}`;
      const data: ArrayBuffer | null =
        await this.fetchBinary(OfflinePackager.resolve(this.origin, sub.url), OfflinePackager.slowTimeoutMs);
      if (data === null) {
        throw new Error(`字幕下载失败：${sub.language ?? sub.title ?? sub.track_ref}`);
      }
      OfflineDisk.writeBuffer(`${unitDir}/subs/${name}`, data);
      subtitles.push(new OfflineSubtitleSpec(`external:${name}`, name,
        sub.format === 'srt' || sub.format === 'vtt' ? 'vtt' : 'ass',
        sub.language ?? null, sub.title ?? null, sub.is_default, sub.is_forced, sub.is_ai,
        sub.track_ref));
    }

    // 字体：有 ASS 轨才要（番剧的特效字幕不配字体会走样）
    const fonts: string[] = [];
    const fontsUrl: string | null = manifest.fonts_url ?? null;
    if (fontsUrl !== null && OfflinePackager.hasAss(subtitles)) {
      const listText: string | null =
        await this.fetchText(OfflinePackager.resolve(this.origin, fontsUrl), OfflinePackager.slowTimeoutMs);
      if (listText !== null) {
        const raw: Object | null = OfflineDisk.readJSONText(listText);
        const record: Record<string, Object> = raw === null ? {} : raw as Record<string, Object>;
        const data: Object | undefined = record['data'];
        const inner: Record<string, Object> = data === undefined ? {} : data as Record<string, Object>;
        const list: Object | undefined = inner['fonts'];
        if (list !== undefined && Array.isArray(list)) {
          for (const item of list as Object[]) {
            const url: string = `${item}`;
            const rawName: string = url.substring(url.lastIndexOf('/') + 1);
            const name: string = `${OfflinePackager.safeName(rawName)}.ttf`;
            const fontData: ArrayBuffer | null =
              await this.fetchBinary(OfflinePackager.resolve(this.origin, url), OfflinePackager.slowTimeoutMs);
            if (fontData === null) {
              continue;
            }
            OfflineDisk.writeBuffer(`${unitDir}/fonts/${name}`, fontData);
            fonts.push(name);
          }
        }
      }
    }

    const spec: OfflinePlaybackSpec = new OfflinePlaybackSpec(
      manifest.duration_ms ?? null,
      JSON.stringify(manifest.chapters),
      JSON.stringify(manifest.segments),
      JSON.stringify(original ? manifest.audio_tracks
        : manifest.audio_tracks.filter((track): boolean => track.ref === manifest.default_audio)),
      manifest.default_audio ?? null,
      subtitles,
      fonts,
      original ? OfflinePackager.fileResolution(manifest, this.unit.fileId) : this.unit.profile,
      original ? OfflinePackager.fileVideoCodec(manifest, this.unit.fileId) : 'h264',
      original ? (manifest.container ?? null) : 'mp4');
    OfflineDisk.writeJSON(OfflineDisk.playbackFile(key, itemId, this.unit.fileId), spec as Object);

    await this.saveImages();
  }

  // MARK: 图片

  /** 详情页、海报格、分集卡、演职员要的图，每张存一份（`index.json` 记原始地址 → 文件名） */
  private async saveImages(): Promise<void> {
    const manifest: OfflineManifestView = this.manifest;
    const item = manifest.item;
    const wanted: WantedImage[] = [];
    if (item.poster_url !== null && item.poster_url !== undefined) {
      wanted.push(new WantedImage(item.poster_url, ImageVariant.posterCard));
    }
    if (item.backdrop_url !== null && item.backdrop_url !== undefined) {
      wanted.push(new WantedImage(item.backdrop_url, ImageVariant.landscapeCard));
    }
    if (item.logo_url !== null && item.logo_url !== undefined) {
      wanted.push(new WantedImage(item.logo_url, ImageVariant.landscapeCard));
    }
    const meta = item.local_meta ?? null;
    if (meta !== null) {
      const actors: number = Math.min(20, meta.actors.length);
      for (let i: number = 0; i < actors; i++) {
        const thumb: string | null | undefined = meta.actors[i].thumb_url;
        if (thumb !== null && thumb !== undefined) {
          wanted.push(new WantedImage(thumb, ImageVariant.photoTile));
        }
      }
      const directors: number = Math.min(5, meta.director_credits.length);
      for (let i: number = 0; i < directors; i++) {
        const thumb: string | null | undefined = meta.director_credits[i].thumb_url;
        if (thumb !== null && thumb !== undefined) {
          wanted.push(new WantedImage(thumb, ImageVariant.photoTile));
        }
      }
    }
    const season = manifest.season ?? null;
    if (season !== null) {
      const episodes: number = Math.min(80, season.episodes.length);
      for (let i: number = 0; i < episodes; i++) {
        const still: string | null | undefined = season.episodes[i].still_url;
        if (still !== null && still !== undefined) {
          wanted.push(new WantedImage(still, ImageVariant.landscapeCard));
        }
      }
    }

    const dir: string = OfflineDisk.imagesDir(this.ownerKey, manifest.media_item_id);
    const indexFile: string = `${dir}/index.json`;
    const index: Record<string, string> = OfflineDisk.readStringMap(indexFile);
    for (const image of wanted) {
      if (index[image.raw] !== undefined) {
        continue;
      }
      const url: string | null = ImageUrls.resolve(this.origin, image.raw, image.variant);
      if (url === null) {
        continue;
      }
      const fetched: FetchBinaryResult | null = await this.fetchBinaryWithInfo(url, 30000);
      if (fetched === null || fetched.data.byteLength === 0) {
        continue;
      }
      const ext: string = fetched.contentType.includes('png') ? 'png'
        : fetched.contentType.includes('webp') ? 'webp' : 'jpg';
      const name: string = `${OfflinePackager.imageKey(url)}.${ext}`;
      OfflineDisk.writeBuffer(`${dir}/${name}`, fetched.data);
      index[image.raw] = name;
    }
    OfflineDisk.writeJSON(indexFile, index as Object);
  }

  // MARK: 工具

  /** 清单里的地址是 `/api/v1/...` 的绝对路径（字幕、字体带了签名 token） */
  static resolve(origin: string, path: string): string {
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return path;
    }
    return `${origin}${path.startsWith('/') ? '' : '/'}${path}`;
  }

  private static hasAss(subtitles: OfflineSubtitleSpec[]): boolean {
    for (const sub of subtitles) {
      if (sub.kind === 'ass') {
        return true;
      }
    }
    return false;
  }

  private static fileResolution(manifest: OfflineManifestView, fileId: number): string | null {
    for (const file of manifest.item.files) {
      if (file.id === fileId) {
        return file.resolution ?? null;
      }
    }
    return null;
  }

  private static fileVideoCodec(manifest: OfflineManifestView, fileId: number): string | null {
    for (const file of manifest.item.files) {
      if (file.id === fileId) {
        return file.video_codec ?? null;
      }
    }
    return null;
  }

  /** 图片内容的稳定短键（同一张图跨启动文件名一致：不重下） */
  static imageKey(url: string): string {
    const encoder: util.TextEncoder = new util.TextEncoder();
    const md: cryptoFramework.Md = cryptoFramework.createMd('MD5');
    md.updateSync({ data: encoder.encodeInto(url) });
    const bytes: Uint8Array = md.digestSync().data;
    let hex: string = '';
    for (let i: number = 0; i < 8 && i < bytes.length; i++) {
      hex += (bytes[i] < 16 ? '0' : '') + bytes[i].toString(16);
    }
    return hex;
  }

  private async fetchBinary(url: string, timeoutMs: number): Promise<ArrayBuffer | null> {
    const result: FetchBinaryResult | null = await this.fetchBinaryWithInfo(url, timeoutMs);
    return result !== null ? result.data : null;
  }

  private async fetchBinaryWithInfo(url: string, timeoutMs: number): Promise<FetchBinaryResult | null> {
    const session: http.HttpRequest = http.createHttp();
    try {
      const header: Record<string, string> = {
        'Accept': '*/*',
        'Authorization': `Bearer ${this.token}`
      };
      const resp: http.HttpResponse = await session.request(url, {
        method: http.RequestMethod.GET,
        header: header,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 15000,
        readTimeout: timeoutMs
      });
      if (resp.responseCode < 200 || resp.responseCode >= 300) {
        return null;
      }
      const buffer: ArrayBuffer = resp.result as ArrayBuffer;
      const headers: Record<string, Object> = resp.header as Record<string, Object>;
      const contentType: string = `${headers['content-type'] ?? ''}`.toLowerCase();
      return new FetchBinaryResult(buffer, contentType);
    } catch (error) {
      return null;
    } finally {
      session.destroy();
    }
  }

  private async fetchText(url: string, timeoutMs: number): Promise<string | null> {
    const session: http.HttpRequest = http.createHttp();
    try {
      const header: Record<string, string> = {
        'Accept': 'application/json',
        'Authorization': `Bearer ${this.token}`
      };
      const resp: http.HttpResponse = await session.request(url, {
        method: http.RequestMethod.GET,
        header: header,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: timeoutMs
      });
      if (resp.responseCode < 200 || resp.responseCode >= 300) {
        return null;
      }
      return resp.result as string;
    } catch (error) {
      return null;
    } finally {
      session.destroy();
    }
  }

  static safeName(raw: string): string {
    let cleaned: string = '';
    for (let i: number = 0; i < raw.length; i++) {
      const code: number = raw.charCodeAt(i);
      const ok: boolean = (code >= 48 && code <= 57) || (code >= 65 && code <= 90)
        || (code >= 97 && code <= 122) || code === 46 || code === 95 || code === 45;
      cleaned += ok ? raw.charAt(i) : '_';
    }
    return cleaned.length === 0 ? 'file' : cleaned.substring(0, 80);
  }
}

/** 要预取的一张图（原始地址 + 显示预设） */
class WantedImage {
  raw: string;
  variant: string | null;

  constructor(raw: string, variant: string | null) {
    this.raw = raw;
    this.variant = variant;
  }
}

class FetchBinaryResult {
  data: ArrayBuffer;
  contentType: string;

  constructor(data: ArrayBuffer, contentType: string) {
    this.data = data;
    this.contentType = contentType;
  }
}
