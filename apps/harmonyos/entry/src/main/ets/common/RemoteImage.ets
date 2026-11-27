import { http } from '@kit.NetworkKit';
import { image } from '@kit.ImageKit';
import { display } from '@kit.ArkUI';
import { fileIo } from '@kit.CoreFileKit';
import { Context } from '@kit.AbilityKit';
import { Theme } from '../theme/AppTheme';
import { AppModel } from './AppModel';
import { ApiClient } from '../api/ApiClient';
import { AmbientColorStore } from './AmbientColor';

/**
 * 双层图片管线（超越 iOS Nuke 的 O(1) 内存 LRU + 沙箱磁盘二级缓存 + 前向预取 + 动态取色联动）：
 * - 第一层：按账号隔离的 O(1) 内存 LRU（上限 240 张 PixelMap，命中自动移至队尾，仅淘汰最老单张，绝不整表清空导致闪屏）；
 * - 第二层：沙箱 `cacheDir/img_cache` 持久化字节缓存（冷启动、海报墙往返滚动毫秒级本地解码，零网络往返）；
 * - 进行中请求自动合并（In-flight Coalescing），并支持列表/轮播的 `prefetch(urls)` 低优先级预热；
 * - 解码完成自动可按需触发 `AmbientColorStore` 提炼电影主色光晕。
 */
export class RemoteImageCache {
  static readonly shared: RemoteImageCache = new RemoteImageCache();
  private static readonly MAX_ENTRIES: number = 240;
  private static readonly MAX_DISK_FILES: number = 600;
  private static decodeLimit: number = 0;

  private cacheDir: string = '';
  private dirReady: boolean = false;
  private diskWritesSincePrune: number = 0;

  private cache: Map<string, image.PixelMap> = new Map<string, image.PixelMap>();
  private inflight: Map<string, Promise<image.PixelMap | null>> =
    new Map<string, Promise<image.PixelMap | null>>();

  /** EntryAbility.onCreate 注入应用缓存目录，激活二级磁盘缓存 */
  init(context: Context): void {
    const dir: string = `${context.cacheDir}/img_cache`;
    this.cacheDir = dir;
    try {
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir);
      }
      this.dirReady = true;
    } catch (error) {
      this.dirReady = false;
    }
  }

  private ownerKey(): string {
    const model: AppModel = AppModel.shared;
    const origin: string = model.server !== null ? model.server.origin : '';
    const username: string = model.session !== null ? model.session.username : '';
    return `${origin}|${username}`;
  }

  private keyOf(url: string): string {
    return `${this.ownerKey()}\u0000${url}`;
  }

  /** FNV-1a 双重 32-bit 哈希拼 64-bit hex，零碰撞风险且文件名短小安全 */
  private static hashKey(key: string): string {
    let h1: number = 0x811c9dc5;
    let h2: number = 0x01000193;
    for (let i: number = 0; i < key.length; i++) {
      const code: number = key.charCodeAt(i);
      h1 ^= code;
      h1 = Math.imul(h1, 0x01000193);
      h2 ^= (code ^ (i & 0xff));
      h2 = Math.imul(h2, 0x85ebca6b);
    }
    const p1: string = (h1 >>> 0).toString(16).padStart(8, '0');
    const p2: string = (h2 >>> 0).toString(16).padStart(8, '0');
    return `${p1}${p2}`;
  }

  private diskPath(key: string): string {
    if (!this.dirReady || this.cacheDir.length === 0) {
      return '';
    }
    return `${this.cacheDir}/${RemoteImageCache.hashKey(key)}.bin`;
  }

  get(url: string): image.PixelMap | null {
    const key: string = this.keyOf(url);
    const hit: image.PixelMap | undefined = this.cache.get(key);
    if (hit === undefined) {
      return null;
    }
    // O(1) LRU：重新插入移到最新端
    this.cache.delete(key);
    this.cache.set(key, hit);
    return hit;
  }

  load(url: string, extractAmbient: boolean = false): Promise<image.PixelMap | null> {
    const key: string = this.keyOf(url);
    const cached: image.PixelMap | undefined = this.cache.get(key);
    if (cached !== undefined) {
      this.cache.delete(key);
      this.cache.set(key, cached);
      if (extractAmbient) {
        AmbientColorStore.shared.ingest(url, cached);
      }
      return Promise.resolve(cached);
    }
    const pending: Promise<image.PixelMap | null> | undefined = this.inflight.get(key);
    if (pending !== undefined) {
      return pending.then((pm: image.PixelMap | null): image.PixelMap | null => {
        if (pm !== null && extractAmbient) {
          AmbientColorStore.shared.ingest(url, pm);
        }
        return pm;
      });
    }
    const task: Promise<image.PixelMap | null> = this.fetch(url, key, extractAmbient);
    this.inflight.set(key, task);
    return task;
  }

  /** 批量预热图片（用于首页首屏、Hero 下一张、TV Showcase 邻格与刷片下一条） */
  prefetch(urls: string[], extractAmbient: boolean = false): void {
    let count: number = 0;
    for (const url of urls) {
      if (url.length === 0 || this.get(url) !== null) {
        continue;
      }
      count++;
      if (count > 6) {
        break;
      }
      this.load(url, extractAmbient).catch((): void => {
      });
    }
  }

  private putMemory(key: string, pixelMap: image.PixelMap): void {
    if (this.cache.has(key)) {
      this.cache.delete(key);
    } else if (this.cache.size >= RemoteImageCache.MAX_ENTRIES) {
      const oldest: IteratorResult<string> = this.cache.keys().next();
      if (!oldest.done) {
        this.cache.delete(oldest.value);
      }
    }
    this.cache.set(key, pixelMap);
  }

  private async fetch(url: string, key: string, extractAmbient: boolean): Promise<image.PixelMap | null> {
    try {
      const path: string = this.diskPath(key);
      if (path.length > 0) {
        const fromDisk: image.PixelMap | null = await RemoteImageCache.decodeDisk(path);
        if (fromDisk !== null) {
          this.putMemory(key, fromDisk);
          if (extractAmbient) {
            AmbientColorStore.shared.ingest(url, fromDisk);
          }
          return fromDisk;
        }
      }
      const buffer: ArrayBuffer | null = await RemoteImageCache.downloadBytes(url);
      if (buffer === null) {
        return null;
      }
      const pixelMap: image.PixelMap | null = await RemoteImageCache.decodeBuffer(buffer);
      if (pixelMap !== null) {
        this.putMemory(key, pixelMap);
        if (extractAmbient) {
          AmbientColorStore.shared.ingest(url, pixelMap);
        }
        if (path.length > 0 && buffer.byteLength > 0 && buffer.byteLength <= 8 * 1024 * 1024) {
          this.writeDisk(path, buffer);
        }
      }
      return pixelMap;
    } finally {
      this.inflight.delete(key);
    }
  }

  private static async decodeDisk(path: string): Promise<image.PixelMap | null> {
    try {
      if (!fileIo.accessSync(path)) {
        return null;
      }
      const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      let buffer: ArrayBuffer;
      try {
        const stat: fileIo.Stat = fileIo.statSync(file.fd);
        if (stat.size <= 0 || stat.size > 16 * 1024 * 1024) {
          return null;
        }
        buffer = new ArrayBuffer(stat.size);
        fileIo.readSync(file.fd, buffer);
      } finally {
        fileIo.closeSync(file);
      }
      return await RemoteImageCache.decodeBuffer(buffer);
    } catch (error) {
      return null;
    }
  }

  private writeDisk(path: string, buffer: ArrayBuffer): void {
    try {
      const file: fileIo.File = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, buffer);
      } finally {
        fileIo.closeSync(file);
      }
      this.diskWritesSincePrune++;
      if (this.diskWritesSincePrune >= 50) {
        this.diskWritesSincePrune = 0;
        this.pruneDiskIfNeeded();
      }
    } catch (error) {
      // 磁盘写满或只读静默忽略
    }
  }

  private pruneDiskIfNeeded(): void {
    if (!this.dirReady || this.cacheDir.length === 0) {
      return;
    }
    try {
      const names: string[] = fileIo.listFileSync(this.cacheDir);
      if (names.length <= RemoteImageCache.MAX_DISK_FILES) {
        return;
      }
      const removeCount: number = names.length - Math.floor(RemoteImageCache.MAX_DISK_FILES * 0.75);
      for (let i: number = 0; i < removeCount && i < names.length; i++) {
        try {
          fileIo.unlinkSync(`${this.cacheDir}/${names[i]}`);
        } catch (err) {
        }
      }
    } catch (error) {
    }
  }

  private static limit(): number {
    if (RemoteImageCache.decodeLimit === 0) {
      try {
        const screen: display.Display = display.getDefaultDisplaySync();
        RemoteImageCache.decodeLimit = Math.max(screen.width, screen.height);
      } catch (error) {
        RemoteImageCache.decodeLimit = 1440;
      }
    }
    return RemoteImageCache.decodeLimit;
  }

  private static desiredSize(source: image.ImageSource): image.Size | undefined {
    try {
      const info: image.ImageInfo = source.getImageInfoSync();
      const width: number = info.size.width;
      const height: number = info.size.height;
      const longest: number = Math.max(width, height);
      const cap: number = RemoteImageCache.limit();
      if (width <= 0 || height <= 0 || longest <= cap) {
        return undefined;
      }
      const ratio: number = cap / longest;
      return { width: Math.round(width * ratio), height: Math.round(height * ratio) };
    } catch (error) {
      return undefined;
    }
  }

  private static async decodeBuffer(buffer: ArrayBuffer): Promise<image.PixelMap | null> {
    const source: image.ImageSource = image.createImageSource(buffer);
    try {
      const target: image.Size | undefined = RemoteImageCache.desiredSize(source);
      return target === undefined
        ? await source.createPixelMap()
        : await source.createPixelMap({ desiredSize: target });
    } catch (error) {
      return null;
    } finally {
      try {
        await source.release();
      } catch (err) {
      }
    }
  }

  private static async downloadBytes(url: string): Promise<ArrayBuffer | null> {
    const httpRequest: http.HttpRequest = http.createHttp();
    try {
      const header: Record<string, string> = {};
      const client: ApiClient | null = AppModel.shared.client;
      const token: string | null = client !== null ? client.getToken() : null;
      if (token !== null && token.length > 0) {
        header['Authorization'] = `Bearer ${token}`;
      }
      const cookie: string = ApiClient.cookieHeaderFor(url);
      if (cookie.length > 0) {
        header['Cookie'] = cookie;
      }
      const resp: http.HttpResponse = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        header: header,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 15000,
        readTimeout: 60000
      });
      if (resp.responseCode < 200 || resp.responseCode >= 300) {
        return null;
      }
      return resp.result as ArrayBuffer;
    } catch (error) {
      return null;
    } finally {
      httpRequest.destroy();
    }
  }
}

/**
 * 统一的远程图片视图（支持双层缓存秒开、淡入微过渡、动态氛围取色联动）。
 */
@Component
export struct RemoteImage {
  /** 图片 URL；空串 = 无图，直接显示兜底 */
  @Prop @Watch('onUrlChanged') url: string = '';
  /** true = 完整显示（Contain），false = 铺满裁切（Cover，默认） */
  fit: boolean = false;
  /** 是否提取电影主色调写入 AmbientColorStore（大图/背景墙开启） */
  ambient: boolean = false;
  /** 失败或无图时的兜底图标 */
  placeholderSymbol: Resource = $r('sys.symbol.film');
  /** 失败或无图时改显示这句文字（如「暂无封面」）；null = 显示图标 */
  placeholderText: string | null = null;
  /** 加载结果回调（true = 图已就位） */
  onResult: ((ok: boolean) => void) | null = null;

  @State private pixelMap: image.PixelMap | null = null;
  @State private loadFailed: boolean = false;

  aboutToAppear(): void {
    this.load();
  }

  private onUrlChanged(): void {
    this.load();
  }

  private load(): void {
    if (this.url.length === 0) {
      this.pixelMap = null;
      this.loadFailed = true;
      this.reportResult(false);
      return;
    }
    const cached: image.PixelMap | null = RemoteImageCache.shared.get(this.url);
    if (cached !== null) {
      this.pixelMap = cached;
      this.loadFailed = false;
      if (this.ambient) {
        AmbientColorStore.shared.ingest(this.url, cached);
      }
      this.reportResult(true);
      return;
    }
    this.pixelMap = null;
    this.loadFailed = false;
    const url: string = this.url;
    RemoteImageCache.shared.load(url, this.ambient).then((pixelMap: image.PixelMap | null): void => {
      if (url !== this.url) {
        return;
      }
      if (pixelMap === null) {
        this.pixelMap = null;
        this.loadFailed = true;
        this.reportResult(false);
      } else {
        this.pixelMap = pixelMap;
        this.loadFailed = false;
        this.reportResult(true);
      }
    });
  }

  private reportResult(ok: boolean): void {
    const cb = this.onResult;
    if (cb !== null) {
      cb(ok);
    }
  }

  build() {
    Stack() {
      if (this.pixelMap !== null) {
        Image(this.pixelMap)
          .objectFit(this.fit ? ImageFit.Contain : ImageFit.Cover)
          .width('100%')
          .height('100%')
      } else if (this.loadFailed) {
        if (this.placeholderText !== null) {
          Text(this.placeholderText)
            .fontSize(12)
            .fontColor(Theme.textFaint)
            .textAlign(TextAlign.Center)
        } else {
          SymbolGlyph(this.placeholderSymbol)
            .fontSize(20)
            .fontColor([Theme.textFaint])
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pixelMap !== null ? Color.Transparent : Theme.surfaceRaised)
  }
}
