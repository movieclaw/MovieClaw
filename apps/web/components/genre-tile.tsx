import type { Route } from "next";
import Link from "next/link";

import { FilmIcon } from "@/components/icons";
import { PosterImage } from "@/components/poster-image";
import { imageUrl } from "@/lib/image-proxy";

/** smoothstep 缓动的黑色渐变色标：从 0 处的 maxOpacity 平滑落到 span 处的全透明（与 GenreCardFace.swift 同曲线） */
function easedStops(maxOpacity: number, span: number) {
  return Array.from({ length: 9 }, (_, i) => {
    const t = i / 8;
    return `rgba(0,0,0,${(maxOpacity * (1 - t * t * (3 - 2 * t))).toFixed(3)}) ${(t * span * 100).toFixed(2)}%`;
  }).join(",");
}

const SCRIM = `radial-gradient(78% 72% at 12% 100%,${easedStops(0.5, 1)}),linear-gradient(0deg,${easedStops(0.28, 0.54)})`;

/** 全幅剧照：桌面约 240 × 153、手机 196 × 124.6，保持 236:150 比例。 */
export function GenreTile({
  label,
  count,
  mediaKind,
  coverUrl,
  href,
  className = "",
}: {
  label: string;
  count: number;
  mediaKind: "movie" | "tv";
  coverUrl: string | null;
  href: Route;
  className?: string;
}) {
  const countLabel = `${count} 部${mediaKind === "tv" ? "剧集" : "电影"}`;
  return (
    <Link
      href={href}
      aria-label={`浏览${label}，${countLabel}`}
      className={`group relative isolate block aspect-[236/150] overflow-hidden rounded-[calc(12px*var(--genre-scale))] [--genre-scale:calc(240/236)] max-md:[--genre-scale:calc(196/236)] bg-[#202023] text-white outline-none ring-inset transition-shadow duration-200 hover:ring-1 hover:ring-white/25 focus-visible:ring-2 focus-visible:ring-white/80 motion-reduce:transition-none ${className}`}
    >
      <PosterImage
        key={coverUrl}
        src={imageUrl(coverUrl)}
        alt=""
        width={240}
        zoom={1.045}
        className="absolute inset-0 -z-20 size-full !transition-[opacity,transform] group-hover:scale-[1.045] motion-reduce:transition-none"
        fallback={
          <span aria-hidden className="absolute inset-0 -z-20 bg-[radial-gradient(ellipse_at_80%_0%,#45454b,#1d1d20_65%)]">
            <FilmIcon className="absolute right-[calc(20px*var(--genre-scale))] top-[calc(20px*var(--genre-scale))] size-[calc(45px*var(--genre-scale))] text-white/[.13]" />
          </span>
        }
      />
      {/* 压暗区提饱和：黑色渐变压低的那一截颜色更浓，读起来是「暗」而不是「灰」 */}
      <span aria-hidden className="absolute inset-0 -z-10 backdrop-saturate-[1.2] [mask-image:linear-gradient(0deg,#000_25%,transparent_60%)]" />
      {/* 文字保护只压该压的地方：全宽一层很轻的底 + 文字所在左下的椭圆暗区，都走缓动曲线 */}
      <span aria-hidden className="absolute inset-0 -z-10" style={{ backgroundImage: SCRIM }} />
      {/* 顶边内高光往下淡出，卡片有厚度 */}
      <span aria-hidden className="pointer-events-none absolute inset-0 rounded-[inherit] shadow-[inset_0_.5px_0_#ffffff1f,inset_0_0_0_.5px_#ffffff06]" />
      <span className="absolute bottom-[calc(38px*var(--genre-scale))] left-[calc(18px*var(--genre-scale))] right-[calc(34px*var(--genre-scale))] truncate text-[length:calc(24px*var(--genre-scale))] font-semibold leading-[1.22] tracking-[.2px] [text-shadow:0_1px_4px_#00000052]">
        {label}
      </span>
      <span className="absolute bottom-[calc(17px*var(--genre-scale))] left-[calc(18px*var(--genre-scale))] text-[12px] max-md:text-[11px] tabular-nums leading-normal text-white/[.72]">
        {countLabel}
      </span>
    </Link>
  );
}
