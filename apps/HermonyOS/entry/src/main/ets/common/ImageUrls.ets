/**
 * 图片尺寸预设与地址解析（逐条对齐 iOS 端 DesignSystem/RemoteImage.swift，
 * 口径即 Web lib/image-proxy.ts 的 ImageVariant 与 imageUrl()）：
 * - http(s) 远程图（TMDB、豆瓣、PT 站截图）一律走后端缓存代理 /images/proxy；
 * - 相对路径（/images/assets/...、/libraries/...）补上 /api/v1 直连；
 * - Windows 刮削器写入的反斜杠统一换成 /；
 * - 只有刮削资产路由（/images/assets/）支持派生预设。
 */
export class ImageVariant {
  static readonly landscapeCard: string = 'landscape-card';
  static readonly posterCard: string = 'poster-card';
  static readonly photoTile: string = 'photo-tile';
  static readonly galleryTile: string = 'gallery-tile';
  static readonly photoScreen: string = 'photo-screen';
  /** 刷片等画面时垫在横带里的剧照：720p（横带占满屏宽，横卡的 480 放大发虚） */
  static readonly reelStill: string = 'reel-still';

  /** 海报墙按主图比例挑预设：横图取横卡，竖图取海报卡 */
  static card(aspect: number | null): string {
    return (aspect ?? 0.66) >= 1 ? ImageVariant.landscapeCard : ImageVariant.posterCard;
  }
}

/** 后端给出的图片地址 → 可请求的 URL；空返回 null */
export class ImageUrls {
  static resolve(origin: string, raw: string | null | undefined, variant: string | null): string | null {
    if (raw === null || raw === undefined || raw.length === 0) {
      return null;
    }
    if (raw.startsWith('http://') || raw.startsWith('https://')) {
      const base: string = `${origin}/api/v1/images/proxy?url=${encodeURIComponent(raw)}`;
      return variant === null ? base : `${base}&variant=${variant}`;
    }
    let path: string = raw.replace(/\\/g, '/');
    if (path.startsWith('/api/v1/')) {
      path = path.substring('/api/v1'.length);
    }
    if (!path.startsWith('/')) {
      path = `/${path}`;
    }
    let fullUrl: string = `${origin}/api/v1${path}`;
    if (variant !== null && path.startsWith('/images/assets/')) {
      /*
       * **路径里可能已经有查询串**：后端给的刮削资产地址自带版本号（`/images/assets/287/s01e01.jpg?v=1790735083`），
       * 这时必须用 `&` 接，不能无脑拼 `?`——拼成 `…jpg?v=…?variant=…`（两个问号）后端直接 **422**，
       * 表现是图片静默加载失败、界面退回占位图（媒体库首页「接下来继续」的剧照就是这么丢的）。
       */
      fullUrl += path.includes('?') ? `&variant=${variant}` : `?variant=${variant}`;
    }
    return fullUrl;
  }
}
