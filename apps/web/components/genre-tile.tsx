import type { Route } from "next";
import Link from "next/link";

import { ChevronRightIcon, FilmIcon } from "@/components/icons";
import { PosterImage } from "@/components/poster-image";
import { imageUrl } from "@/lib/image-proxy";

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
        className="absolute inset-0 -z-20 size-full saturate-[.76] !transition-[opacity,transform,filter] group-hover:scale-[1.045] group-hover:saturate-100 motion-reduce:transition-none"
        fallback={
          <span aria-hidden className="absolute inset-0 -z-20 bg-[radial-gradient(ellipse_at_80%_0%,#45454b,#1d1d20_65%)]">
            <FilmIcon className="absolute right-5 top-5 size-[45px] text-white/[.13]" />
          </span>
        }
      />
      <span aria-hidden className="absolute inset-0 -z-10 bg-[linear-gradient(0deg,#07090def_0%,#080a0c77_44%,#090b1010_100%)]" />
      <span className="absolute bottom-[38px] left-[18px] right-[34px] truncate text-[24px] font-[650] leading-[1.22] tracking-[.6px] [text-shadow:0_1px_15px_#0008]">
        {label}
      </span>
      <span className="absolute bottom-[17px] left-[19px] text-[11px] leading-normal text-white/[.72]">
        {countLabel}
      </span>
      <ChevronRightIcon aria-hidden className="absolute bottom-[19px] right-[17px] size-[16px] text-white/90" />
    </Link>
  );
}
