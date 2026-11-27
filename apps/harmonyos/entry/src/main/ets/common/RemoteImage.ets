import { http } from '@kit.NetworkKit';
import { image } from '@kit.ImageKit';
import { display } from '@kit.ArkUI';
import { taskpool } from '@kit.ArkTS';
import { Theme } from '../theme/AppTheme';
import { AppModel } from './AppModel';
import { ApiClient } from '../api/ApiClient';
import { ImageDiskCache } from './ImageDiskCache';
import { ImageLruPolicy } from './ImageLruPolicy';
import { decodeImageBytes } from './ImageDecodeTask';

/**
 * 图片三级管线（对应 iOS 端 Nuke 的 内存层 + 磁盘层 + AuthorizedDataLoader）：
 * - 内存 L1：LRU 淘汰（上限 220 张，命中续命），同一账号下同一 URL 全局只解一份；
 * - 磁盘 L2：原始字节落盘（cacheDir，系统紧张可回收，LRU 256MB），冷启动/换页秒出图；
 * - 网络 L3：请求合并（在途去重），带设备令牌 + 分享 cookie（同 AuthorizedDataLoader）。
 * - 解码在 taskpool 子线程做（4K 原片降采样是 CPU 大户，不能卡主线程滚动）；
 * - 解码单边按**视图实际尺寸**收敛（200px 的格子不解 1080px 的图），内存占用大头由此而来；
 * - 组件销毁/换地址时撤销在途关注（waiters 归零即中断下载），滚动快翻不再白拉流量。
 *
 * 缓存按账号隔离：键里带 ownerKey。海报 URL 与账号无关时，若只按 URL 做键，
 * 换账号后同一 URL 会命中上一个账号解出来的图——把别人库里的海报显示给新账号。
 */
class RemoteImageCache {
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
  /** 在途请求：URL 键 → 合并任务。等待方计数归零即中止下载。 */
  private readonly inflight: Map<string, InflightEntry> = new Map<string, InflightEntry>();
  private readonly prefetchQueue: string[] = [];
  private prefetchActive: number = 0;
  /** 命中计数（诊断展示）：内存命中 / 磁盘命中 / 网络拉取 / 子线程解码 */
  private memHits: number = 0;
  private diskHits: number = 0;
  private networkFetches: number = 0;
  private decodes: number = 0;

  /**
   * 缓存归属键：服务器 + 账号，口径同 LibraryHomeStore.ownerKey。
   * 换账号或退出登录后键就变了，旧账号的条目再也读不到，等淘汰自然清理。
   */
  private ownerKey(): string {
    const model: AppModel = AppModel.shared;
    const origin: string = model.server !== null ? model.server.origin : '';
    const username: string = model.session !== null ? model.session.username : '';
    return `${origin}|${username}`;
  }

  private keyOf(url: string): string {
    return `${this.ownerKey()}\u0000${url}`;
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
   * 订阅一张图：在途即并入（waiters+1），否则新开管线（磁盘→网络→子线程解码→内存）。
   * 同一 URL 多个视图共用一次下载；先到者的解码尺寸定调（海报格尺寸基本一致，不做二次解码）。
   */
  acquire(url: string, edge: number): Promise<image.PixelMap | null> {
    const key: string = this.keyOf(url);
    const existing: InflightEntry | undefined = this.inflight.get(key);
    if (existing !== undefined) {
      existing.waiters++;
      return existing.task;
    }
    const entry: InflightEntry = {
      task: Promise.resolve<image.PixelMap | null>(null),
      waiters: 1,
      httpReq: null
    };
    this.inflight.set(key, entry);
    entry.task = this.pipeline(key, url, edge, entry);
    return entry.task;
  }

  /** 撤销关注：waiters 归零即中止在途下载。已完成/未订阅都是安全空转。 */
  release(url: string): void {
    const key: string = this.keyOf(url);
    const entry: InflightEntry | undefined = this.inflight.get(key);
    if (entry === undefined) {
      return;
    }
    entry.waiters--;
    if (entry.waiters <= 0) {
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
   * 预取到磁盘（滚动预测即将进入视区的海报）：只补 L2，已在途/已有则跳过。
   * 解码按海报格档（480px）——真正上屏的视图尺寸不同时走自己的 acquire，磁盘字节是原始的。
   */
  prefetchToDisk(urls: string[]): void {
    for (let index = 0; index < urls.length; index++) {
      const url: string = urls[index];
      if (url.length === 0) {
        continue;
      }
      if (ImageDiskCache.contains(url)) {
        continue;
      }
      if (this.inflight.has(this.keyOf(url))) {
        continue;
      }
      if (this.prefetchQueue.indexOf(url) >= 0) {
        continue;
      }
      this.prefetchQueue.push(url);
    }
    this.pumpPrefetch();
  }

  private pumpPrefetch(): void {
    while (this.prefetchActive < RemoteImageCache.PREFETCH_CONCURRENCY && this.prefetchQueue.length > 0) {
      const next: string | undefined = this.prefetchQueue.shift();
      if (next === undefined) {
        break;
      }
      this.prefetchActive++;
      const url: string = next;
      this.acquire(url, RemoteImageCache.PREFETCH_DECODE_EDGE_PX).then((): void => {
        this.prefetchActive--;
        this.pumpPrefetch();
      }).catch((): void => {
        this.prefetchActive--;
        this.pumpPrefetch();
      });
    }
  }

  private async pipeline(key: string, url: string, edge: number,
    entry: InflightEntry): Promise<image.PixelMap | null> {
    try {
      // L2：磁盘原始字节（同步读，快）
      let bytes: ArrayBuffer | null = ImageDiskCache.getBytes(url);
      // L3：下载 + 落盘
      if (bytes === null) {
        this.networkFetches++;
        bytes = await this.download(url, entry);
        if (bytes !== null) {
          ImageDiskCache.putBytes(url, bytes);
        }
      } else {
        this.diskHits++;
      }
      if (bytes === null) {
        return null;
      }
      // 子线程解码（ArrayBuffer 随任务转移，之后不再使用）
      this.decodes++;
      const decoded: image.PixelMap | null =
        await taskpool.execute<[ArrayBuffer, number], image.PixelMap | null>(
          decodeImageBytes, bytes, edge);
      if (decoded === null) {
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
    } finally {
      // 管线完成即摘在途标记。若期间 waiters 归零已被 release 摘过、又来了新订阅，
      // map 里是新 entry——只摘自己的，不动别人的
      const current: InflightEntry | undefined = this.inflight.get(key);
      if (current === entry) {
        this.inflight.delete(key);
      }
    }
  }

  private async download(url: string, entry: InflightEntry): Promise<ArrayBuffer | null> {
    const httpRequest: http.HttpRequest = http.createHttp();
    entry.httpReq = httpRequest;
    try {
      const header: Record<string, string> = {};
      const client: ApiClient | null = AppModel.shared.client;
      const token: string | null = client !== null ? client.getToken() : null;
      if (token !== null && token.length > 0) {
        header['Authorization'] = `Bearer ${token}`;
      }
      // 密码解锁后的分享图片（/share/...）也要带 movieclaw_share cookie，否则 401
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
}

/** 图片管线计数快照（诊断页展示用）。 */
export interface RemoteImageStats {
  memoryHits: number;
  diskHits: number;
  networkFetches: number;
  decodes: number;
  memoryEntries: number;
}

/** 图片管线计数快照（内存条目数含未淘汰的全部账号归属键）。 */
export function remoteImageStats(): RemoteImageStats {
  return RemoteImageCache.shared.statsSnapshot();
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

/**
 * 统一的远程图片视图（对应 iOS 端 RemoteImage）：带占位底色、失败兜底图标/文字。
 * 图片走 RemoteImageCache 三级管线；解码尺寸默认按组件实际布局尺寸收敛
 * （首帧布局后取数），需要全分辨率时传 targetEdgeVp。
 */
/*
 * 不加 @Reusable：@Reusable 不支持与 @ComponentV2 搭配（子组件不创建），而本组件
 * 被 HeroBanner/TvCards/CarCards/SubscribeSheet 等 V2 父组件直接使用；组件本身
 * 很轻，取数/解码/缓存都在 RemoteImageCache 三级管线里完成，复用收益可忽略。
 */
@Component
export struct RemoteImage {
  /** 图片 URL；空串 = 无图，直接显示兜底 */
  @Prop @Watch('onUrlChanged') url: string = '';
  /** true = 完整显示（Contain），false = 铺满裁切（Cover，默认） */
  fit: boolean = false;
  /** 解码单边上限（vp）；0 = 按组件实际布局尺寸自动收敛，>0 = 显式指定（Hero 背景等） */
  targetEdgeVp: number = 0;
  /** 失败或无图时的兜底图标 */
  placeholderSymbol: Resource = $r('sys.symbol.film');
  /** 失败或无图时改显示这句文字（如「暂无封面」）；null = 显示图标 */
  placeholderText: string | null = null;
  /** 加载结果回调（true = 图已就位）；给需要自己画失败兜底的调用方用 */
  onResult: ((ok: boolean) => void) | null = null;

  @State private pixelMap: image.PixelMap | null = null;
  @State private loadFailed: boolean = false;
  /** 组件布局尺寸的长边（px）；首帧布局后由 onAreaChange 记录 */
  private areaEdgePx: number = 0;
  private areaKnown: boolean = false;
  private loadToken: number = 0;
  private pendingAcquire: boolean = false;
  private activeUrl: string = '';

  aboutToAppear(): void {
    this.load();
    // 兜底：极端场景 onAreaChange 迟迟不来（零尺寸容器等），200ms 后按屏幕上限直接取数
    setTimeout((): void => {
      if (this.pendingAcquire) {
        this.acquireNow();
      }
    }, 200);
  }

  aboutToDisappear(): void {
    this.loadToken++;
    this.pendingAcquire = false;
    if (this.activeUrl.length > 0) {
      RemoteImageCache.shared.release(this.activeUrl);
      this.activeUrl = '';
    }
  }

  private onUrlChanged(): void {
    this.load();
  }

  private load(): void {
    this.loadToken++;
    // 换地址：先撤销对旧地址的在途关注
    if (this.activeUrl.length > 0 && this.activeUrl !== this.url) {
      RemoteImageCache.shared.release(this.activeUrl);
      this.activeUrl = '';
    }
    this.pendingAcquire = false;
    if (this.url.length === 0) {
      this.pixelMap = null;
      this.loadFailed = true;
      this.reportResult(false);
      return;
    }
    this.activeUrl = this.url;
    const cached: image.PixelMap | null = RemoteImageCache.shared.get(this.url);
    if (cached !== null) {
      this.pixelMap = cached;
      this.loadFailed = false;
      this.reportResult(true);
      return;
    }
    this.pixelMap = null;
    this.loadFailed = false;
    if (this.areaKnown) {
      this.acquireNow();
    } else {
      // 等首帧布局拿到真实尺寸再取数（onAreaChange 触发），解码就能按视图大小收敛
      this.pendingAcquire = true;
    }
  }

  private acquireNow(): void {
    this.pendingAcquire = false;
    const token: number = this.loadToken;
    const url: string = this.url;
    if (url.length === 0) {
      return;
    }
    const edge: number = this.decodeEdgePx();
    RemoteImageCache.shared.acquire(url, edge).then((pixelMap: image.PixelMap | null): void => {
      // 加载期间地址已变 / 组件已销毁：丢弃这批结果
      if (token !== this.loadToken || url !== this.url) {
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

  private decodeEdgePx(): number {
    if (this.targetEdgeVp > 0) {
      return RemoteImageCache.clampEdge(Math.ceil(this.targetEdgeVp * RemoteImageCache.densityPx()));
    }
    if (this.areaEdgePx > 0) {
      return RemoteImageCache.clampEdge(this.areaEdgePx);
    }
    return RemoteImageCache.screenEdgePx();
  }

  private onAreaChanged(newArea: Area): void {
    const width: Length = newArea.width;
    const height: Length = newArea.height;
    const widthVp: number = typeof width === 'number' ? width : 0;
    const heightVp: number = typeof height === 'number' ? height : 0;
    const edgeVp: number = Math.max(widthVp, heightVp);
    if (edgeVp <= 0) {
      return;
    }
    this.areaEdgePx = Math.ceil(edgeVp * RemoteImageCache.densityPx());
    this.areaKnown = true;
    if (this.pendingAcquire) {
      this.acquireNow();
    }
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
    /*
     * **有图时底色必须透明**：片名 Logo 这类 PNG 靠透明通道叠在剧照上，
     * 底色不透明就会在字后面衬出一块深色板（实测：订阅页 Hero 的片名 Logo 变成了方块）。
     * 只有还没加载出来 / 加载失败、要显示占位图标时才需要底色。
     */
    .backgroundColor(this.pixelMap !== null ? Color.Transparent : Theme.surfaceRaised)
    .onAreaChange((_oldArea: Area, newArea: Area): void => {
      this.onAreaChanged(newArea);
    })
  }
}
