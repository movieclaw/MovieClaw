import type { CSSProperties } from "react";

import type { Route } from "next";
import Link from "next/link";

import { baseCss, blobCss, genreArt, oklchCss } from "@/lib/genre-palette";

/** 胶片颗粒：极轻的柔光噪点，只为消掉渐变色带、带一点印刷质感。 */
const GRAIN =
  "url(\"data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='160' height='160'><filter id='n'><feTurbulence type='fractalNoise' baseFrequency='1.1' numOctaves='3' stitchTiles='stitch'/><feColorMatrix values='0 0 0 0 1  0 0 0 0 1  0 0 0 0 1  0 0 0 1.4 0'/></filter><rect width='160' height='160' filter='url(%23n)'/></svg>\")";

/** 悬停时三团色团各自缓慢漂一点（tvOS 获得焦点同一个动作）。 */
const BLOB_DRIFT = [
  "translate(8%, 6%) scale(1.08)",
  "translate(-10%, -4%) scale(1.1)",
  "translate(6%, -8%)",
];

/**
 * 一个类型的网格渐变底（色块与类型墙页头共用）：斜向底 + 三团羽化色团 + 颗粒 +
 * 左下压暗。只画底，不管尺寸与圆角——由外层容器决定（overflow-hidden）。
 */
export function GenreArtwork({ genreId, drift = false }: { genreId: number; drift?: boolean }) {
  const art = genreArt(genreId);
  return (
    <span aria-hidden className="absolute inset-0 -z-10" style={{ background: baseCss(art) }}>
      {art.blobs.map((blob, index) => (
        <span
          key={index}
          className={`absolute aspect-square rounded-full transition-transform duration-[1600ms] ease-[cubic-bezier(.2,.8,.2,1)] motion-reduce:transition-none ${
            drift ? "motion-safe:group-hover:[transform:var(--drift)] motion-safe:group-focus-visible:[transform:var(--drift)]" : ""
          }`}
          style={
            {
              left: `${blob.left * 100}%`,
              top: `${blob.top * 100}%`,
              width: `${blob.size * 100}%`,
              background: blobCss(blob.color),
              "--drift": BLOB_DRIFT[index],
            } as CSSProperties
          }
        />
      ))}
      <span
        className="absolute inset-0 opacity-[0.09] mix-blend-soft-light"
        style={{ backgroundImage: GRAIN }}
      />
      <span
        className="absolute inset-0"
        style={{
          background: `radial-gradient(80% 70% at 0% 100%, ${oklchCss({ l: 0, c: 0, h: 0, alpha: art.scrim })}, transparent 70%)`,
        }}
      />
    </span>
  );
}

/**
 * 首页「按类型找电影 / 剧集」的一格：网格渐变底 + 中文类型名 + 部数，点进去是
 * 按这个类型筛好的跨库墙。
 *
 * 外层链接是尺寸容器（cqw 以它的宽度为准）：字号、圆角、内边距都随卡片宽度
 * 等比缩放，手机窄卡与桌面宽卡同一比例。圆角与裁切放在内层——容器单位写在
 * 容器自己身上会按更外一层算。上沿 1px 镜面高光 + 四周极淡描边是一层盖在
 * 最上面的描边（inset 阴影画在底色层，会被渐变底盖住）。
 */
export function GenreTile({
  genreId,
  label,
  count,
  href,
  className = "",
}: {
  genreId: number;
  label: string;
  count?: number;
  href: Route;
  className?: string;
}) {
  return (
    <Link
      href={href}
      className={`group relative block aspect-[16/10.5] outline-none [container-type:inline-size] ${className}`}
    >
      <span className="absolute inset-0 isolate overflow-hidden rounded-[10cqw] transition-transform duration-500 ease-[cubic-bezier(.2,.8,.2,1)] group-hover:scale-[1.025] motion-reduce:transition-none">
        <GenreArtwork genreId={genreId} drift />
        <span className="absolute bottom-[7.5cqw] left-[8.5cqw] font-semibold leading-[1.1] tracking-[0.04em] text-white [font-size:clamp(13px,11.8cqw,24px)]">
          {label}
          {count !== undefined && (
            <span className="mt-[0.35em] block text-[0.6em] font-medium tracking-[0.02em] tabular-nums opacity-70">
              {count} 部
            </span>
          )}
        </span>
        <span className="pointer-events-none absolute inset-0 rounded-[inherit] shadow-[inset_0_1px_0_rgba(255,255,255,0.22),inset_0_0_0_0.5px_rgba(255,255,255,0.1)] group-focus-visible:shadow-[inset_0_0_0_2px_rgba(255,255,255,0.85)]" />
      </span>
    </Link>
  );
}
