import { image } from '@kit.ImageKit';
import { Theme } from '../theme/AppTheme';
import {
  AcquireHandle,
  RemoteImageCache,
  RemoteImagePrefetch,
  RemoteImageStats,
  clearImageCaches,
  remoteImageStats
} from './RemoteImageCache';

export { RemoteImagePrefetch, RemoteImageStats, clearImageCaches, remoteImageStats };

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
  @Prop fit: boolean = false;
  /** 解码单边上限（vp）；0 = 按组件实际布局尺寸自动收敛，>0 = 显式指定（Hero 背景等） */
  @Prop targetEdgeVp: number = 0;
  /** 失败或无图时的兜底图标 */
  @Prop placeholderSymbol: Resource = $r('sys.symbol.film');
  /** 失败或无图时改显示这句文字（如「暂无封面」）；null = 显示图标 */
  @Prop placeholderText: string | null = null;
  /** 加载结果回调（true = 图已就位）；给需要自己画失败兜底的调用方用 */
  onResult: ((ok: boolean) => void) | null = null;

  @State private pixelMap: image.PixelMap | null = null;
  @State private loadFailed: boolean = false;
  /** 组件布局尺寸的长边（px）；首帧布局后由 onAreaChange 记录 */
  private areaEdgePx: number = 0;
  private areaKnown: boolean = false;
  private loadToken: number = 0;
  private pendingAcquire: boolean = false;
  /** 只有真正发起了 in-flight acquire 时才记录，避免 L1 命中或未发起订阅时误 release 同伴下载 */
  private acquiredKey: string = '';
  private fallbackTimer: number = -1;

  aboutToAppear(): void {
    this.load();
  }

  aboutToDisappear(): void {
    this.loadToken++;
    this.pendingAcquire = false;
    this.clearFallbackTimer();
    this.releaseAcquired();
  }

  private onUrlChanged(): void {
    this.load();
  }

  private clearFallbackTimer(): void {
    if (this.fallbackTimer >= 0) {
      clearTimeout(this.fallbackTimer);
      this.fallbackTimer = -1;
    }
  }

  private scheduleFallbackAcquire(token: number): void {
    this.clearFallbackTimer();
    // 兜底：极端场景 onAreaChange 迟迟不来（零尺寸容器等），200ms 后按屏幕上限直接取数
    this.fallbackTimer = setTimeout((): void => {
      this.fallbackTimer = -1;
      if (this.pendingAcquire && token === this.loadToken) {
        this.acquireNow();
      }
    }, 200);
  }

  private releaseAcquired(): void {
    if (this.acquiredKey.length > 0) {
      const key: string = this.acquiredKey;
      this.acquiredKey = '';
      RemoteImageCache.shared.releaseByKey(key);
    }
  }

  private load(): void {
    this.loadToken++;
    const token: number = this.loadToken;
    this.clearFallbackTimer();
    // 换地址：撤销对旧地址的在途关注
    this.releaseAcquired();
    this.pendingAcquire = false;
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
    if (this.areaKnown) {
      this.acquireNow();
    } else {
      // 等首帧布局拿到真实尺寸再取数（onAreaChange 触发），解码就能按视图大小收敛
      this.pendingAcquire = true;
      this.scheduleFallbackAcquire(token);
    }
  }

  private acquireNow(): void {
    this.pendingAcquire = false;
    this.clearFallbackTimer();
    const token: number = this.loadToken;
    const url: string = this.url;
    if (url.length === 0) {
      return;
    }
    const edge: number = this.decodeEdgePx();
    const handle: AcquireHandle = RemoteImageCache.shared.acquire(url, edge);
    this.acquiredKey = handle.inflight ? handle.key : '';
    const finish = (pixelMap: image.PixelMap | null): void => {
      if (handle.inflight && this.acquiredKey === handle.key) {
        this.acquiredKey = '';
      }
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
    };
    handle.task.then(finish, (): void => {
      finish(null);
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
