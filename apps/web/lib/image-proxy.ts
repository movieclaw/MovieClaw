import { resolveRequestUrl } from "@/lib/http";
import { withImageWidth } from "@/lib/image-width";

export {
  IMAGE_ASPECT,
  WIDTH_LADDER,
  coverWidth,
  fullScreenImageWidth,
  imageSizes,
  imageSrcSet,
  responsiveImage,
  screenImageWidth,
  snapWidth,
  withImageWidth,
} from "@/lib/image-width";

/**
 * 旧的固定派生预设（``variant=``）。服务端仍兼容，但新代码一律按宽度取图
 * （``{ width }``，见 lib/image-width.ts），这里只为兼容保留类型与参数。
 */
export type ImageVariant =
  | "landscape-card"
  | "poster-card"
  | "photo-tile"
  | "gallery-tile"
  | "photo-screen";

/**
 * 取图选项：``width`` 是需要的**物理像素宽**（已乘屏幕倍率与放大系数），会先取到阶梯档
 * 再拼 ``w``；传旧预设名等价于 ``{ variant }``（兼容旧调用，不要再新增）。
 */
export type ImageUrlOptions = ImageVariant | { width?: number };

function appendVariant(url: string, variant: ImageVariant): string {
  return `${url}${url.includes("?") ? "&" : "?"}variant=${variant}`;
}

/** 把选项拆成「宽度」与「旧预设」两种形态。 */
function splitOptions(opts: ImageUrlOptions | undefined): { width?: number; variant?: ImageVariant } {
  if (!opts) return {};
  return typeof opts === "string" ? { variant: opts } : { width: opts.width };
}

/**
 * 远程静态图片的统一收口入口。
 *
 * 所有 http(s) 绝对地址（TMDB 海报、豆瓣剧照、PT 站图床截图等）一律改走
 * 后端 /images/proxy：后端首次回源抓取后缓存到 data/cache/images，之后同一
 * URL 直接读本地磁盘，不再依赖外网图床的可达性与速度。代理同样认 ``w``：
 * 服务端从缓存的原图派生，所以远程图也按宽度取。
 * 非 http(s) 的相对路径（本地上传的背景图等）原样返回，不经代理。
 *
 * 新增图片展示位时请一律经过本函数（或 imageUrl），不要直接引用远程 URL。
 */
export function cachedImageUrl(url: string, opts?: ImageUrlOptions): string {
  if (!/^https?:\/\//i.test(url)) return url;
  const { width, variant } = splitOptions(opts);
  const path = `images/proxy?url=${encodeURIComponent(url)}`;
  const resolved = resolveRequestUrl(variant ? appendVariant(path, variant) : path);
  return width ? withImageWidth(resolved, width) : resolved;
}

/**
 * 后端给出的图片地址的通用解析：http(s) 绝对地址走缓存代理；
 * API 相对路径（本地刮削资产 /images/assets/...、条目美术图 /libraries/...、
 * 库 / 合集封面、账号头像、分享页图片……）补上 API base 直连后端。
 *
 * ``{ width }``：服务端**所有**出图地址都认 ``w``（docs/design/image-sizing.md §5.2），
 * 所以不分路由一律追加。展示图片都应带宽度——原图默认是 TMDB original，海报可能
 * 2000×3000、背景 3840 宽，不带 w 取的就是它；只有下载原图、灯箱 1:1 放大这类
 * 明确要原图的地方才不带。卡片类请优先用 srcset（PosterImage 的 width 属性）。
 */
export function imageUrl(url: string | null, opts?: ImageUrlOptions): string {
  if (!url) return "";
  if (/^https?:\/\//i.test(url)) return cachedImageUrl(url, opts);
  const { width, variant } = splitOptions(opts);
  // Windows 刮削器写库的资产路径带反斜杠（/images/assets/5\backdrop.jpg）。
  // img src 里浏览器会把 \ 归一成 /，但同一字符串进 CSS url("...") 时 \b 是
  // 十六进制转义（\bac → U+0BAC）、\p 等未知转义会吞掉反斜杠——沉浸背景层
  // 因此 404 变纯黑（视觉验收实测）。统一在入口归一成 /，所有消费位都安全。
  const normalized = url.replace(/\\/g, "/");
  // 旧预设只有 metadata 资产路由认；宽度则所有出图路由都认（见上）
  const withVariant =
    variant && /^\/?images\/assets\//.test(normalized)
      ? appendVariant(normalized, variant)
      : normalized;
  const resolved = resolveRequestUrl(withVariant);
  return width ? withImageWidth(resolved, width) : resolved;
}

/** 经代理的地址里拆出远端原地址；不是代理地址返回 null。 */
function proxiedRemoteOf(proxiedUrl: string): string | null {
  const match = proxiedUrl.match(/[?&]url=([^&]+)/);
  if (!match) return null;
  try {
    return decodeURIComponent(match[1]);
  } catch {
    return null;
  }
}

/**
 * 远程 TMDB 图按需要的宽度取：TMDB 列表接口给的是固定尺寸段（/t/p/w1280/…），
 * 需要的像素宽超过这一段时换成同一张图的 original，交给服务端从原图派生到 ``w``
 * 那一档；没超过就在原地址上带 ``w``。非 TMDB 图（豆瓣等没有尺寸段）也只带 ``w``。
 *
 * 只给发现页这类**未入库**的远程图用（大屏 Hero、详情页沉浸背景）。库内图片
 * 都来自本地母版，直接 imageUrl(url, { width }) 即可。
 */
export function tmdbImageForWidth(proxiedUrl: string, width: number): string {
  const remote = proxiedRemoteOf(proxiedUrl);
  const tier = remote?.match(/\/t\/p\/w(\d+)\//);
  if (!remote || !tier || Number(tier[1]) >= width) return withImageWidth(proxiedUrl, width);
  return cachedImageUrl(remote.replace(/\/t\/p\/w\d+\//, "/t/p/original/"), { width });
}

/**
 * 地址里 TMDB 尺寸段的宽度（/t/p/w1280/ → 1280）；original 或非 TMDB 图返回 null。
 * 用来判断「列表给的这一档够不够」，够就不必再去拉原图。
 */
export function tmdbTierWidth(proxiedUrl: string): number | null {
  const remote = proxiedRemoteOf(proxiedUrl) ?? proxiedUrl;
  const tier = remote.match(/\/t\/p\/w(\d+)\//);
  return tier ? Number(tier[1]) : null;
}
