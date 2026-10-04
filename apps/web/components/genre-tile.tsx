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
 * 一个类型的网格渐变底（色块与类型墙页头共用）：斜向底 + 三团羽化色团 + 颗粒。
 * 只画底，不管尺寸与圆角——由外层容器决定（overflow-hidden）。
 *
 * `scrim`：左下角压暗，给写在左下的字托底（类型墙页头）；色块的字居中，不要它。
 */
export function GenreArtwork({
  genreId,
  drift = false,
  scrim = true,
}: {
  genreId: number;
  drift?: boolean;
  scrim?: boolean;
}) {
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
          className={`absolute aspect-square rounded-full transition-transform duration-[1600ms] ease-[cubic-bezier(.2,.8,.2,1)] motion-reduce:transition-none ${
            drift
              ? "motion-safe:group-hover:[transform:var(--drift)] motion-safe:group-focus-visible:[transform:var(--drift)]"
              : ""
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
      {scrim && (
        <span
          className="absolute inset-0"
          style={{
            background: `radial-gradient(80% 70% at 0% 100%, ${oklchCss({ l: 0, c: 0, h: 0, alpha: art.scrim })}, transparent 70%)`,
          }}
        />
      )}
    </span>
  );
}

/** 内晕影：四周往里压暗一圈、中间透亮，卡片有了体积（像灯箱）。中心略偏上，字落在亮处 */
const VIGNETTE =
  "radial-gradient(120% 120% at 50% 42%, transparent 52%, rgba(0,0,0,0.3) 100%)";
/** 顶部镜面光带：上 1/3 一层很淡的白，像玻璃反光 */
const SHEEN =
  "linear-gradient(180deg, rgba(255,255,255,0.16) 0%, rgba(255,255,255,0.04) 30%, transparent 46%)";
/** 渐变描边：上沿亮、往下几乎消失（1px 环，靠遮罩挖空中间） */
const RIM: CSSProperties = {
  padding: 1,
  background:
    "linear-gradient(180deg, rgba(255,255,255,0.42), rgba(255,255,255,0.08) 45%, rgba(255,255,255,0.02))",
  WebkitMask:
    "linear-gradient(#000 0 0) content-box, linear-gradient(#000 0 0)",
  WebkitMaskComposite: "xor",
  maskComposite: "exclude",
};

/**
 * 首页「按类型找电影 / 剧集」的一格：网格渐变底，类型名居中；部数写在卡片下方（与海报片名、
 * 媒体库卡片名同一条线，整页各行的说明文字对齐）。点进去是按这个类型筛好的跨库墙。
 *
 * 边缘四层（设计稿 v7）：内晕影、顶部镜面光带、上亮下暗的渐变描边、同色系的外发光投影
 * （卡片像在发光，外加一层贴地的暗影）。外发光会溢出卡片，所在的横滚行要留出下边距。
 *
 * 外层链接是尺寸容器（cqw 以它的宽度为准）：字号、圆角、投影都随卡片宽度等比缩放。
 * 圆角与裁切放在内层——容器单位写在容器自己身上会按更外一层算。
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
  const glow = oklchCss(genreArt(genreId).glow);
  return (
    <Link
      href={href}
      className={`group block outline-none [container-type:inline-size] ${className}`}
    >
      <span className="relative block aspect-[16/10.5]">
        <span
          className="absolute inset-0 rounded-[10cqw] transition-transform duration-500 ease-[cubic-bezier(.2,.8,.2,1)] group-hover:-translate-y-0.5 group-hover:scale-[1.02] motion-reduce:transition-none"
          style={{
            boxShadow: `0 7cqw 16cqw -5cqw ${glow}, 0 2px 6px rgba(0,0,0,0.45)`,
          }}
        >
          <span className="absolute inset-0 isolate overflow-hidden rounded-[inherit]">
            <GenreArtwork genreId={genreId} drift scrim={false} />
            <span
              aria-hidden
              className="absolute inset-0"
              style={{ background: VIGNETTE }}
            />
            <span
              aria-hidden
              className="absolute inset-0"
              style={{ background: SHEEN }}
            />
            <span className="absolute inset-x-0 top-1/2 -translate-y-1/2 text-center font-semibold leading-[1.15] tracking-[0.12em] [text-indent:0.12em] text-white [font-size:clamp(15px,13cqw,28px)] [text-shadow:0_1px_6cqw_rgba(0,0,0,0.28)]">
              {label}
            </span>
          </span>
          <span
            aria-hidden
            className="pointer-events-none absolute inset-0 rounded-[inherit]"
            style={RIM}
          />
          <span className="pointer-events-none absolute inset-0 rounded-[inherit] group-focus-visible:shadow-[0_0_0_2px_rgba(255,255,255,0.85)]" />
        </span>
      </span>
      {count !== undefined && (
        <span className="mt-2.5 block text-center text-ui tabular-nums text-[var(--text-muted)]">
          {count} 部
        </span>
      )}
    </Link>
  );
}
