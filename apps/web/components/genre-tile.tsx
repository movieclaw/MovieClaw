import type { Route } from "next";
import Link from "next/link";

import {
  baseCss,
  blobCss,
  genreArt,
  genreCardBackground,
  genreCardColors,
  oklchCss,
} from "@/lib/genre-palette";
import { imageUrl, responsiveImage } from "@/lib/image-proxy";

/** 胶片颗粒：极轻的柔光噪点，只为消掉渐变色带、带一点印刷质感。 */
const GRAIN =
  "url(\"data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='160' height='160'><filter id='n'><feTurbulence type='fractalNoise' baseFrequency='1.1' numOctaves='3' stitchTiles='stitch'/><feColorMatrix values='0 0 0 0 1  0 0 0 0 1  0 0 0 0 1  0 0 0 1.4 0'/></filter><rect width='160' height='160' filter='url(%23n)'/></svg>\")";

/**
 * 一个类型的网格渐变（斜向底 + 三团羽化色团 + 颗粒）：类型色块里没有可用剧照时，贴在剧照的
 * 位置。只画底，不管尺寸与圆角——由外层容器决定（overflow-hidden）。
 */
export function GenreArtwork({ genreId }: { genreId: number }) {
  const art = genreArt(genreId);
  return (
    <span
      aria-hidden
      className="absolute inset-0 -z-10"
      style={{ background: baseCss(art) }}
    >
      {art.blobs.map((blob, index) => (
        <span
          key={index}
          className="absolute aspect-square rounded-full"
          style={{
            left: `${blob.left * 100}%`,
            top: `${blob.top * 100}%`,
            width: `${blob.size * 100}%`,
            background: blobCss(blob.color),
          }}
        />
      ))}
      <span
        className="absolute inset-0 opacity-[0.09] mix-blend-soft-light"
        style={{ backgroundImage: GRAIN }}
      />
    </span>
  );
}

/**
 * 首页「按类型找电影 / 剧集」的一格（设计稿 v10，学苹果音乐「视频播放列表」）：
 *
 *   - 方卡，类型固定的底色（配色依据见 genre-palette.ts：负面类型是深色卡，科幻 / 奇幻 /
 *     科幻奇幻是金属银、极光等特殊材质），左上角粗体类型名、右上角部数；
 *   - 下半部贴一张这个类型**最近入库**那部片的剧照（原色、自带圆角）；没有剧照时贴这个
 *     类型的网格渐变；
 *   - 卡片下方写那部片的片名 + 「最近入库」，和海报行「片名 + 年份」同一个格式。
 *
 * 外层链接是尺寸容器：字号、圆角、内边距都按卡片宽度等比缩放（cqw）。
 */
export function GenreTile({
  genreId,
  label,
  count,
  coverUrl,
  coverTitle,
  href,
  className = "",
}: {
  genreId: number;
  label: string;
  count: number;
  coverUrl: string | null;
  coverTitle: string | null;
  href: Route;
  className?: string;
}) {
  const colors = genreCardColors(genreId);
  const ink = oklchCss(colors.ink);
  return (
    <Link href={href} className={`group block outline-none ${className}`}>
      <span className="block [container-type:inline-size]">
        <span
          className="relative flex aspect-square flex-col overflow-hidden rounded-[4.5cqw] p-[4.5cqw] transition-transform duration-300 ease-out group-hover:scale-[1.02] group-focus-visible:ring-2 group-focus-visible:ring-white/80 motion-reduce:transition-none"
          style={{ background: genreCardBackground(colors) }}
        >
          <span
            className="block truncate pr-[18cqw] pt-[3.5cqw] font-bold leading-[1.1] tracking-[0.02em] [font-size:max(15px,11.8cqw)]"
            style={{ color: ink }}
          >
            {label}
          </span>
          <span
            className="absolute right-[5cqw] top-[4.5cqw] font-semibold tabular-nums opacity-75 [font-size:max(10px,5.2cqw)]"
            style={{ color: ink }}
          >
            {count} 部
          </span>
          <span className="relative mt-auto block aspect-video overflow-hidden rounded-[3cqw]">
            {coverUrl ? (
              // 卡片只有两三百像素宽：按显示宽度取图，不拉原图
              <img
                alt=""
                loading="lazy"
                decoding="async"
                className="absolute inset-0 size-full object-cover"
                {...responsiveImage(imageUrl(coverUrl), 210)}
              />
            ) : (
              <span className="absolute inset-0 isolate">
                <GenreArtwork genreId={genreId} />
              </span>
            )}
          </span>
        </span>
      </span>
      <span className="mt-2 block leading-tight">
        <span className="block truncate text-ui font-medium text-[var(--text)]">
          {coverTitle ?? label}
        </span>
        <span className="mt-0.5 block text-sub text-[var(--text-muted)]">
          {coverTitle ? "最近入库" : `${count} 部`}
        </span>
      </span>
    </Link>
  );
}
