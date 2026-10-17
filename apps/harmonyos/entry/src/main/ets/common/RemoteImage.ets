import { http } from '@kit.NetworkKit';
import { image } from '@kit.ImageKit';
import { display } from '@kit.ArkUI';
import { Theme } from '../theme/AppTheme';
import { AppModel } from './AppModel';
import { ApiClient } from '../api/ApiClient';

/**
 * 图片内存缓存（对应 iOS 端 Nuke 的内存层 + AuthorizedDataLoader）：
 * - 同一账号下同一 URL 全局只解码一次，进行中的请求合并（列表里同图多格共用）；
 * - 后端图片接口需要登录：请求头带上当前账号的设备令牌（同 AuthorizedDataLoader）；
 * - **缓存按账号隔离**：键里带上 ownerKey。海报墙的图片 URL 与账号无关，只按 URL 做键时，
 *   换账号后同一 URL 会命中上一个账号解出来的 PixelMap——把别人库里的海报显示给新账号；
 * - 超过上限整体清空（简单 FIFO，海报都是小图，重建成本低；磁盘缓存后续按需再加）。
 */
class RemoteImageCache {
  static readonly shared: RemoteImageCache = new RemoteImageCache();
  private static readonly MAX_ENTRIES: number = 150;
  /** 解码单边上限（px）：屏幕长边，首次用时取一次 */
  private static decodeLimit: number = 0;

  private cache: Map<string, image.PixelMap> = new Map<string, image.PixelMap>();
  private inflight: Map<string, Promise<image.PixelMap | null>> =
    new Map<string, Promise<image.PixelMap | null>>();

  /**
   * 缓存归属键：服务器 + 账号，口径同 LibraryHomeStore.ownerKey。
   * 换账号或退出登录后键就变了，旧账号的条目再也读不到，等 FIFO 自然淘汰。
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

  get(url: string): image.PixelMap | null {
    return this.cache.get(this.keyOf(url)) ?? null;
  }

  load(url: string): Promise<image.PixelMap | null> {
    const key: string = this.keyOf(url);
    const cached: image.PixelMap | null = this.cache.get(key) ?? null;
    if (cached !== null) {
      return Promise.resolve(cached);
    }
    const pending: Promise<image.PixelMap | null> | undefined = this.inflight.get(key);
    if (pending !== undefined) {
      return pending;
    }
    // 归属键在这里定死：请求途中换了账号，结果也只会落回旧账号的键下
    const task: Promise<image.PixelMap | null> = this.fetch(url, key);
    this.inflight.set(key, task);
    return task;
  }

  private async fetch(url: string, key: string): Promise<image.PixelMap | null> {
    try {
      const pixelMap: image.PixelMap | null = await RemoteImageCache.download(url);
      if (pixelMap !== null) {
        if (this.cache.size >= RemoteImageCache.MAX_ENTRIES) {
          this.cache.clear();
        }
        this.cache.set(key, pixelMap);
      }
      return pixelMap;
    } finally {
      this.inflight.delete(key);
    }
  }

  /** 解码单边上限：屏幕长边（px）。取不到就退回一个够用的常数。 */
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

  /**
   * 按比例算解码尺寸（对应 iOS 端 Nuke 的降采样）。
   * 后端虽然按 variant 出过一档图，但背景图/剧照原片可能很大，不设上限
   * createPixelMap 会按原始分辨率解，一张 4K 图就是几十 MB 内存。
   * 尺寸按原图比例算，所以不会把图拉变形；本来就不超上限时返回 undefined（按原尺寸解）。
   */
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

  private static async download(url: string): Promise<image.PixelMap | null> {
    const httpRequest: http.HttpRequest = http.createHttp();
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
      const buffer: ArrayBuffer = resp.result as ArrayBuffer;
      const source: image.ImageSource = image.createImageSource(buffer);
      try {
        const target: image.Size | undefined = RemoteImageCache.desiredSize(source);
        return target === undefined
          ? await source.createPixelMap()
          : await source.createPixelMap({ desiredSize: target });
      } finally {
        await source.release();
      }
    } catch (error) {
      return null;
    } finally {
      httpRequest.destroy();
    }
  }
}

/**
 * 统一的远程图片视图（对应 iOS 端 RemoteImage）：带占位底色、失败兜底图标/文字。
 * 图片请求带设备令牌（后端图片接口需要登录），加载结果缓存在 RemoteImageCache。
 */
@Component
export struct RemoteImage {
  /** 图片 URL；空串 = 无图，直接显示兜底 */
  @Prop @Watch('onUrlChanged') url: string = '';
  /** true = 完整显示（Contain），false = 铺满裁切（Cover，默认） */
  fit: boolean = false;
  /** 失败或无图时的兜底图标 */
  placeholderSymbol: Resource = $r('sys.symbol.film');
  /** 失败或无图时改显示这句文字（如「暂无封面」）；null = 显示图标 */
  placeholderText: string | null = null;
  /** 加载结果回调（true = 图已就位）；给需要自己画失败兜底的调用方用 */
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
      this.reportResult(true);
      return;
    }
    this.pixelMap = null;
    this.loadFailed = false;
    const url: string = this.url;
    RemoteImageCache.shared.load(url).then((pixelMap: image.PixelMap | null): void => {
      // 加载期间地址已变：丢弃这批结果
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
  }
}
