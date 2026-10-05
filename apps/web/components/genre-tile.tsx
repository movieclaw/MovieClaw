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

const SCRIM = `radial-gradient(95% 75% at 12% 100%,${easedStops(0.55, 1)}),linear-gradient(0deg,${easedStops(0.42, 0.58)})`;

/** 设计稿 A：236 × 150 全幅剧照，类型与部数在卡内；点击进入类型海报墙。 */
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
      className={`group relative isolate block h-[150px] overflow-hidden rounded-xl bg-[#202023] text-white outline-none ring-inset transition-shadow duration-200 hover:ring-1 hover:ring-white/25 focus-visible:ring-2 focus-visible:ring-white/80 motion-reduce:transition-none ${className}`}
    >
      <PosterImage
        key={coverUrl}
        src={imageUrl(coverUrl)}
        alt=""
        width={236}
        zoom={1.045}
        className="absolute inset-0 -z-20 size-full !transition-[opacity,transform] group-hover:scale-[1.045] motion-reduce:transition-none"
        fallback={
          <span aria-hidden className="absolute inset-0 -z-20 bg-[radial-gradient(ellipse_at_80%_0%,#45454b,#1d1d20_65%)]">
            <FilmIcon className="absolute right-5 top-5 size-[45px] text-white/[.13]" />
          </span>
        }
      />
      {/* 压暗区提饱和：黑色渐变压低的那一截颜色更浓，读起来是「暗」而不是「灰」 */}
      <span aria-hidden className="absolute inset-0 -z-10 backdrop-saturate-[1.45] backdrop-brightness-[.94] [mask-image:linear-gradient(0deg,#000_25%,transparent_60%)]" />
      {/* 文字保护只压该压的地方：全宽一层很轻的底 + 文字所在左下的椭圆暗区，都走缓动曲线 */}
      <span aria-hidden className="absolute inset-0 -z-10" style={{ backgroundImage: SCRIM }} />
      {/* 顶边内高光往下淡出，卡片有厚度 */}
      <span aria-hidden className="pointer-events-none absolute inset-0 rounded-xl shadow-[inset_0_1px_0_#ffffff29,inset_0_0_0_1px_#ffffff0d]" />
      <span className="absolute bottom-[38px] left-[18px] right-[34px] truncate text-[24px] font-[650] leading-[1.22] tracking-[.6px] [text-shadow:0_1px_3px_#0006,0_1px_16px_#0007]">
        {label}
      </span>
      <span className="absolute bottom-[17px] left-[19px] text-[11px] tabular-nums leading-normal text-white/[.72]">
        {countLabel}
      </span>
    </Link>
  );
}
