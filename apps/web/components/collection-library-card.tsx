"use client";

import type { Route } from "next";
import Link from "next/link";

import { LayersIcon } from "@/components/icons";
import { PosterImage } from "@/components/poster-image";
import type { Collection } from "@/lib/api/collections";
import { imageUrl } from "@/lib/image-proxy";

/** 首页合集的虚拟库卡片：封面复用真实媒体库的服务端货架渲染，不参与真实库统计。
 * 与库卡片保持同一宽高比，点击仍进入原合集；名字用合集原名，首页海报行改名不影响它。 */
export function CollectionLibraryCard({ collection }: { collection: Collection }) {
  const href = collection.library_id === null
    ? `/library/c/${collection.id}`
    : `/library/${collection.library_id}/c/${collection.id}`;
  const placeholder = (
    <div className="absolute inset-0 flex items-center justify-center bg-gradient-to-br from-[#1c2230] to-[#10131c]">
      <LayersIcon className="size-12 text-white/[0.13]" />
    </div>
  );
  return (
    <Link
      href={href as Route}
      scroll={false}
      aria-label={`打开合集「${collection.name}」，${collection.item_count} 部`}
      className="group/lib block rounded-2xl outline-none focus-visible:ring-2 focus-visible:ring-[var(--accent-ring)]"
      data-testid={`collection-library-card-${collection.id}`}
    >
      <div className="relative aspect-[21/10] overflow-hidden rounded-2xl bg-[#0a0c12] ring-1 ring-white/10 transition duration-300 group-hover/lib:ring-white/35">
        {collection.covers.length === 0 ? placeholder : (
          <>
            <PosterImage src={imageUrl(`/collections/${collection.id}/cover`)} width={268} zoom={1.02} alt="" className="absolute inset-0 size-full object-cover transition duration-300 group-hover/lib:scale-[1.02]" fallback={placeholder} />
            <div className="pointer-events-none absolute -left-[45%] bottom-0 h-[25%] w-[45%] -skew-x-12 bg-gradient-to-r from-transparent via-white/[0.14] to-transparent transition-transform duration-700 ease-out group-hover/lib:translate-x-[350%]" />
          </>
        )}
        {/* 合集标记放在封面左下的倒影暗区：与库卡「N 个新文件入库中」同位置、同一套玻璃胶囊
            （合集没有扫描状态，不会撞车），名称行因此只有名字，长合集名不被图标挤短 */}
        <span className="absolute bottom-2 left-2.5 flex items-center gap-1 rounded-full border border-white/[0.16] bg-black/50 px-2 py-0.5 text-micro font-semibold text-white/90 backdrop-blur-md">
          <LayersIcon className="size-3" />合集
        </span>
      </div>
      <ShelfCardCaption name={collection.name} />
    </Link>
  );
}

/** 「我的媒体库」行的卡片名：库卡与合集卡共用，封面下方居中、只占一行（Emby / Jellyfin「我的媒体」同款）。
 * 不写部数（页头已有总数，入口卡只负责认出是哪个）；「默认」是订阅 / 下载的落库设置，只在库管理页标注；
 * 合集的区分放在封面左下角标上，不占名称行。iPhone 端同名组件 ShelfCardCaption 与此一致。 */
export function ShelfCardCaption({ name }: { name: string }) {
  return <h3 className="mt-2.5 truncate px-2 text-center text-body-lg font-semibold text-white">{name}</h3>;
}
