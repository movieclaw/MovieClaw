import { http } from '@kit.NetworkKit';
import { image } from '@kit.ImageKit';
import { display } from '@kit.ArkUI';
import { taskpool } from '@kit.ArkTS';
import { AppModel } from './AppModel';
import { ApiClient } from '../api/ApiClient';
import { ImageDiskCache } from './ImageDiskCache';
import { ImageLruPolicy } from './ImageLruPolicy';
import { decodeImageBytes } from './ImageDecodeTask';

/**
 * 图片三级管线（纯非 UI 缓存与下载解码模块，供 RemoteImage 视图与 AppModel 会话清理共用）：
 * - 内存 L1：LRU 淘汰（上限 220 张，命中续命），同一账号下同一 URL 全局只解一份；
 * - 磁盘 L2：原始字节落盘（cacheDir，系统紧张可回收，LRU 256MB，按账号/服务器隔离），冷启动/换页秒出图；
 * - 网络 L3：请求合并（在途去重），带设备令牌 + 分享 cookie（同 AuthorizedDataLoader）。
 * - 解码在 taskpool 子线程做（异常安全捕获，磁盘损坏自愈清理，永不向上抛未捕获拒绝）；
 * - 组件销毁/换地址时撤销在途关注（waiters 归零即中断下载），滚动快翻不再白拉流量。
 */
export class RemoteImageCache {
  static readonly shared: RemoteImageCache = new RemoteImageCache();
  private static readonly MAX_MEMORY_ENTRIES: number = 220;
  private static readonly PREFETCH_CONCURRENCY: number = 2;
  /** 预取只服务海报格这一主流场景：按 480px 解码，落内存后小格直接命中 */
  private static readonly PREFETCH_DECODE_EDGE_PX: number = 480;
  private static readonly MIN_DECODE_EDGE_PX: number = 64;
  private static screenEdge: number = 0;
  private static density: number = 0;

  private readonly cache: Map<string, image.PixelMap> = new Map<string, image.PixelMap>();
  private readonly lru: ImageLruPolicy = new ImageLruPolicy();
  /** 在途请求：归属+URL 键 → 合并任务。等待方计数归零即中止下载。 */
  private readonly inflight: Map<string, InflightEntry> = new Map<string, InflightEntry>();
  private readonly prefetchQueue: PrefetchTask[] = [];
  private prefetchActive: number = 0;
  /** 命中计数（诊断展示）：内存命中 / 磁盘命中 / 网络拉取 / 子线程解码 */
  private memHits: number = 0;
  private diskHits: number = 0;
  private networkFetches: number = 0;
  private decodes: number = 0;

  /**
   * 缓存归属键：服务器 + 账号，口径同 LibraryHomeStore.ownerKey。
   * 换账号或退出登录后键就变了，旧账号的条目不会被新账号读到。
   */
  private ownerKey(): string {
    const model: AppModel = AppModel.shared;
    const origin: string = model.server !== null ? model.server.origin : '';
    const username: string = model.session !== null ? model.session.username : '';
    return `${origin}|${username}`;
  }

  private static buildKey(ownerKey: string, url: string, cookie: string): string {
    return `${ownerKey}\u0000${cookie}\u0000${url}`;
  }

  private keyOf(url: string): string {
    const cookie: string = ApiClient.cookieHeaderFor(url);
    return RemoteImageCache.buildKey(this.ownerKey(), url, cookie);
  }

  /** 屏幕长边（px）：解码上限的兜底值（Hero 背景这类不知道目标尺寸的场景）。 */
  static screenEdgePx(): number {
    if (RemoteImageCache.screenEdge === 0) {
      try {
        const screen: display.Display = display.getDefaultDisplaySync();
        RemoteImageCache.screenEdge = Math.max(screen.width, screen.height);
      } catch (error) {
        RemoteImageCache.screenEdge = 1440;
      }
    }
    return RemoteImageCache.screenEdge;
  }

  /** 内存层条目数（诊断展示）。 */
  snapshotSize(): number {
    return this.cache.size;
  }

  /** 计数快照（诊断页展示用）。 */
  statsSnapshot(): RemoteImageStats {
    return {
      memoryHits: this.memHits,
      diskHits: this.diskHits,
      networkFetches: this.networkFetches,
      decodes: this.decodes,
      memoryEntries: this.cache.size
    };
  }

  static densityPx(): number {
    if (RemoteImageCache.density === 0) {
      try {
        const screen: display.Display = display.getDefaultDisplaySync();
        RemoteImageCache.density = screen.densityPixels > 0 ? screen.densityPixels : 3;
      } catch (error) {
        RemoteImageCache.density = 3;
      }
    }
    return RemoteImageCache.density;
  }

  /** 解码上限收敛：下限防 0/毛边格，上限防超清屏无意义解码。 */
  static clampEdge(edge: number): number {
    const capped: number = Math.min(edge, RemoteImageCache.screenEdgePx());
    return Math.max(RemoteImageCache.MIN_DECODE_EDGE_PX, capped);
  }

  /** 内存命中（顺带续命）。 */
  get(url: string): image.PixelMap | null {
    const key: string = this.keyOf(url);
    const cached: image.PixelMap | undefined = this.cache.get(key);
    if (cached !== undefined) {
      this.memHits++;
      this.lru.touch(key);
      return cached;
    }
    return null;
  }

  /**
   * 订阅一张图：先查内存 L1（避免首帧等布局期间已被预取/同伴落内存却白走一次磁盘解码），
   * 再并在途（waiters+1），否则新开管线（磁盘→网络→子线程解码→内存）。
   * 返回句柄包含精确的 inflight key，releaseByKey 时不会受切号后 ownerKey 变化影响。
   */
  acquire(url: string, edge: number): AcquireHandle {
    const ownerKey: string = this.ownerKey();
    const cookie: string = ApiClient.cookieHeaderFor(url);
    const key: string = RemoteImageCache.buildKey(ownerKey, url, cookie);
    const cached: image.PixelMap | undefined = this.cache.get(key);
    if (cached !== undefined) {
      this.memHits++;
      this.lru.touch(key);
      return { key: '', task: Promise.resolve(cached), inflight: false };
    }
    const existing: InflightEntry | undefined = this.inflight.get(key);
    if (existing !== undefined) {
      existing.waiters++;
      return { key: key, task: existing.task, inflight: true };
    }
    const client: ApiClient | null = AppModel.shared.client;
    const token: string | null = client !== null ? client.getToken() : null;
    const entry: InflightEntry = {
      task: Promise.resolve<image.PixelMap | null>(null),
      waiters: 1,
      httpReq: null,
      cancelled: false
    };
    this.inflight.set(key, entry);
    entry.task = this.pipeline(key, ownerKey, url, edge, token, cookie, entry);
    return { key: key, task: entry.task, inflight: true };
  }

  /** 按订阅时的精确键撤销关注：waiters 归零即中止在途下载。已完成/未订阅都是安全空转。 */
  releaseByKey(key: string): void {
    if (key.length === 0) {
      return;
    }
    const entry: InflightEntry | undefined = this.inflight.get(key);
    if (entry === undefined) {
      return;
    }
    entry.waiters--;
    if (entry.waiters <= 0) {
      entry.cancelled = true;
      this.inflight.delete(key);
      const req: http.HttpRequest | null = entry.httpReq;
      if (req !== null) {
        try {
          req.destroy();
        } catch (error) {
          // 请求已结束，销毁报错忽略
        }
      }
    }
  }

  /**
   * 账号/服务器切换或注销时的缓存隔离清理：
   * - 立即清空预取队列，防止旧账号待预取 URL 落进新会话；
   * - 中止并清空全部在途下载；
   * - 清空内存 L1（不让旧账号的 PixelMap 留驻内存）；
   * - 注销/会话失效时按归属清理 L2 磁盘缓存，全部注销时全清 L2。
   */
  clearForSessionChange(evictDiskOwner: string | null, clearAllDisk: boolean): void {
    this.prefetchQueue.splice(0, this.prefetchQueue.length);
    this.inflight.forEach((entry: InflightEntry): void => {
      entry.cancelled = true;
      const req: http.HttpRequest | null = entry.httpReq;
      if (req !== null) {
        try {
          req.destroy();
        } catch (error) {
          // 忽略已结束请求
        }
      }
    });
    this.inflight.clear();
    this.cache.clear();
    this.lru.clearAll();
    if (clearAllDisk) {
      ImageDiskCache.clearAll();
    } else if (evictDiskOwner !== null && evictDiskOwner.length > 0) {
      ImageDiskCache.clearOwner(evictDiskOwner);
    }
  }

  /**
   * 预取到磁盘（滚动预测即将进入视区的海报）：只补当前账号的 L2/L1，已在途/已有则跳过。
   * 队列条目绑定入队时的 ownerKey，切号或注销后自动作废。
   */
  prefetchToDisk(urls: string[]): void {
    const ownerKey: string = this.ownerKey();
    for (let index = 0; index < urls.length; index++) {
      const url: string = urls[index];
      if (url.length === 0) {
        continue;
      }
      const cookie: string = ApiClient.cookieHeaderFor(url);
      const key: string = RemoteImageCache.buildKey(ownerKey, url, cookie);
      if (this.cache.has(key)) {
        continue;
      }
      if (cookie.length === 0 && ImageDiskCache.contains(ownerKey, url)) {
        continue;
      }
      if (this.inflight.has(key)) {
        continue;
      }
      if (this.hasQueuedPrefetch(ownerKey, url)) {
        continue;
      }
      this.prefetchQueue.push({ ownerKey: ownerKey, url: url });
    }
    this.pumpPrefetch();
  }

  private hasQueuedPrefetch(ownerKey: string, url: string): boolean {
    for (let index = 0; index < this.prefetchQueue.length; index++) {
      const item: PrefetchTask = this.prefetchQueue[index];
      if (item.ownerKey === ownerKey && item.url === url) {
        return true;
      }
    }
    return false;
  }

  private pumpPrefetch(): void {
    while (this.prefetchActive < RemoteImageCache.PREFETCH_CONCURRENCY && this.prefetchQueue.length > 0) {
      const next: PrefetchTask | undefined = this.prefetchQueue.shift();
      if (next === undefined) {
        break;
      }
      if (next.ownerKey !== this.ownerKey()) {
        continue;
      }
      const cookie: string = ApiClient.cookieHeaderFor(next.url);
      const key: string = RemoteImageCache.buildKey(next.ownerKey, next.url, cookie);
      if (this.cache.has(key) || (cookie.length === 0 && ImageDiskCache.contains(next.ownerKey, next.url))) {
        continue;
      }
      this.prefetchActive++;
      const handle: AcquireHandle = this.acquire(next.url, RemoteImageCache.PREFETCH_DECODE_EDGE_PX);
      handle.task.then((): void => {
        this.prefetchActive--;
        this.pumpPrefetch();
      }).catch((): void => {
        this.prefetchActive--;
        this.pumpPrefetch();
      });
    }
  }

  private async pipeline(key: string, ownerKey: string, url: string, edge: number,
    token: string | null, cookie: string, entry: InflightEntry): Promise<image.PixelMap | null> {
    try {
      // 带分享访客 cookie 的受保护图片不落通用磁盘缓存，避免解锁凭证跨会话残留
      const allowDisk: boolean = cookie.length === 0;
      let fromDisk: boolean = false;
      // L2：磁盘原始字节（同步读，按 ownerKey 隔离）
      let bytes: ArrayBuffer | null = allowDisk ? ImageDiskCache.getBytes(ownerKey, url) : null;
      if (bytes !== null) {
        fromDisk = true;
      } else {
        // L3：下载 + 落盘（只有成功拿到字节且会话未切换才记网络命中并落盘）
        bytes = await this.download(url, token, cookie, entry);
        if (entry.cancelled || bytes === null || this.ownerKey() !== ownerKey) {
          return null;
        }
        this.networkFetches++;
        if (allowDisk) {
          ImageDiskCache.putBytes(ownerKey, url, bytes);
        }
      }
      if (entry.cancelled || bytes === null || this.ownerKey() !== ownerKey) {
        return null;
      }
      // 子线程解码（ArrayBuffer 随任务转移，之后不再使用）；taskpool 抛错时安全降级并清理坏盘
      this.decodes++;
      let decoded: image.PixelMap | null = null;
      try {
        decoded = await taskpool.execute<[ArrayBuffer, number], image.PixelMap | null>(
          decodeImageBytes, bytes, edge);
      } catch (decodeError) {
        decoded = null;
      }
      if (decoded === null) {
        if (fromDisk && allowDisk) {
          // 磁盘字节损坏或解码异常：自愈摘掉，下次重新拉网
          ImageDiskCache.remove(ownerKey, url);
        }
        return null;
      }
      if (fromDisk) {
        this.diskHits++;
      }
      // 解码途中切号/注销或被取消：不写进新会话的内存缓存
      if (entry.cancelled || this.ownerKey() !== ownerKey) {
        return null;
      }
      // L1：内存 + LRU 淘汰（被淘汰的 PixelMap 不主动 release——可能还在屏上，
      // 由 GC 收敛；与旧 FIFO 实现口径一致，避免屏上图被释放的崩溃面）
      this.cache.set(key, decoded);
      this.lru.insert(key, 1);
      const evicted: string[] = this.lru.evictOverBudget(RemoteImageCache.MAX_MEMORY_ENTRIES);
      for (let index = 0; index < evicted.length; index++) {
        this.cache.delete(evicted[index]);
      }
      return decoded;
    } catch (error) {
      return null;
    } finally {
      // 管线完成即摘在途标记。若期间 waiters 归零已被 release 摘过、又来了新订阅，
      // map 里是新 entry——只摘自己的，不动别人的
      const current: InflightEntry | undefined = this.inflight.get(key);
      if (current === entry) {
        this.inflight.delete(key);
      }
    }
  }

  private async download(url: string, token: string | null, cookie: string,
    entry: InflightEntry): Promise<ArrayBuffer | null> {
    if (entry.cancelled) {
      return null;
    }
    const httpRequest: http.HttpRequest = http.createHttp();
    entry.httpReq = httpRequest;
    try {
      const header: Record<string, string> = {};
      if (token !== null && token.length > 0) {
        header['Authorization'] = `Bearer ${token}`;
      }
      // 密码解锁后的分享图片（/share/...）也要带 movieclaw_share cookie，否则 401
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
      if (entry.httpReq === httpRequest) {
        entry.httpReq = null;
      }
      try {
        httpRequest.destroy();
      } catch (cleanupError) {
        // destroy 幂等，重复销毁的报错忽略
      }
    }
  }
}

interface InflightEntry {
  task: Promise<image.PixelMap | null>;
  waiters: number;
  httpReq: http.HttpRequest | null;
  cancelled: boolean;
}

export interface AcquireHandle {
  key: string;
  task: Promise<image.PixelMap | null>;
  inflight: boolean;
}

interface PrefetchTask {
  ownerKey: string;
  url: string;
}

/** 图片管线计数快照（诊断页展示用）。 */
export interface RemoteImageStats {
  memoryHits: number;
  diskHits: number;
  networkFetches: number;
  decodes: number;
  memoryEntries: number;
}

/** 图片管线计数快照（当前会话内存条目数 + 累计命中计数）。 */
export function remoteImageStats(): RemoteImageStats {
  return RemoteImageCache.shared.statsSnapshot();
}

/** 切号/切服/注销时由 AppModel 调用，保证图片内存、在途、预取与磁盘缓存彻底隔离。 */
export function clearImageCaches(evictDiskOwner: string | null = null, clearAllDisk: boolean = false): void {
  RemoteImageCache.shared.clearForSessionChange(evictDiskOwner, clearAllDisk);
}

/**
 * 海报滚动预取门面：墙/首页滚动时把即将进入视区的海报 URL 提前灌进磁盘缓存，
 * 真正滚到时只剩内存/磁盘命中 + 子线程解码，滚动零网络等待。
 * null/空串自动滤掉；在途/已缓存的 URL 在管线内部幂等跳过，调用方只管把候选丢进来。
 */
export class RemoteImagePrefetch {
  static posterUrls(urls: (string | null)[]): void {
    const valid: string[] = [];
    for (let index = 0; index < urls.length; index++) {
      const url: string | null = urls[index];
      if (url !== null && url.length > 0) {
        valid.push(url);
      }
    }
    if (valid.length > 0) {
      RemoteImageCache.shared.prefetchToDisk(valid);
    }
  }
}
