"use client";

import { useTranslations } from "next-intl";

import { XIcon } from "@/components/icons";
import { Modal } from "@/components/modal";
import type { FacetValue } from "@/lib/api/libraries";
import type { ReelFacets, ReelQuery } from "@/lib/api/reels";
import { isFilterEmpty } from "@/lib/library-filter";
import { type ReelDimension, REEL_DIMENSIONS, reelFilterValues, toggleReelFilter, watchOnly } from "@/lib/reels";

/** 维度 → 计数接口里的那一列 */
const FACET_COLUMN: Record<ReelDimension, keyof Pick<ReelFacets, "genres" | "decades" | "countries" | "ratings" | "runtimes">> = {
  genres: "genres",
  decades: "decades",
  countries: "countries",
  rating_gte: "ratings",
  runtimes: "runtimes",
};

/** 某一维的候选值（计数没回来时为空） */
export function reelFacetValues(facets: ReelFacets | null, key: ReelDimension | "kinds" | "watch"): FacetValue[] {
  if (!facets) return [];
  if (key === "kinds") return facets.kinds;
  if (key === "watch") return facets.watch;
  return facets[FACET_COLUMN[key]];
}

/**
 * 片段页的筛选抽屉（同 iOS `ReelFilterMenu` 的维度与规则，手机上是底部抽屉）：电影 / 剧集、类型、年代、地区、
 * 评分、片长，末尾「只看没看过的」。每个取值后面写着当前条件下还剩几部（`/reels/facets` 按「排除本维自身条件」算），
 * 为 0 的置灰不可点——不让人点出一个空的信息流。点一下立刻生效（整个信息流按新条件重来），抽屉不关，可以接着勾。
 */
export function ReelFilterSheet({
  open,
  onClose,
  facets,
  query,
  onApply,
}: {
  open: boolean;
  onClose: () => void;
  facets: ReelFacets | null;
  query: ReelQuery;
  onApply: (next: ReelQuery) => void;
}) {
  const t = useTranslations();
  const { filter, kind } = query;
  const titles: Record<ReelDimension, string> = {
    genres: t("library.filters.genres"),
    decades: t("library.filters.decades"),
    countries: t("library.filters.regions"),
    rating_gte: t("library.filters.rating"),
    runtimes: t("library.filters.runtime"),
  };
  const kinds = reelFacetValues(facets, "kinds");
  // 库里只有「其他」视频时服务端不给类型列表：没有可切换的，整行不画（计数还没回来时先画着）
  const showKinds = facets === null || kinds.length > 0;
  // 「其他」没有 TMDB 档案：类型 / 年代 / 地区 / 评分 / 片长对它无意义，只剩观看状态
  const filterable = kind !== "video" && (facets?.filterable ?? true);
  const unwatched = reelFacetValues(facets, "watch")[0];
  const active = !isFilterEmpty(filter) || kind !== null;

  return (
    <Modal open={open} onClose={onClose} label={t("library.filters.title")} width="md" panelClassName="flex max-h-[82vh] flex-col">
      <div className="flex items-center justify-between gap-3 border-b border-white/[0.07] px-5 py-4">
        <div className="min-w-0">
          <h2 className="text-body-lg font-semibold text-[var(--text)]">{t("library.filters.title")}</h2>
          {facets && (
            <p className="mt-0.5 text-caption text-[var(--text-muted)]" data-testid="reels-filter-total">
              {t("library.reels.filterTotal", { count: facets.total })}
            </p>
          )}
        </div>
        <div className="flex shrink-0 items-center gap-2">
          {active && (
            <button
              type="button"
              onClick={() => onApply({ filter: {}, kind: null })}
              className="rounded-full px-3 py-1.5 text-sub font-semibold text-[var(--danger)]"
              data-testid="reels-filter-clear"
            >
              {t("media.discovery.clearFilters")}
            </button>
          )}
          <button type="button" onClick={onClose} className="icon-chip flex size-9" aria-label={t("common.close")}>
            <XIcon className="size-4" />
          </button>
        </div>
      </div>

      <div className="scroll-thin flex-1 space-y-5 overflow-y-auto px-5 py-4 max-md:max-h-[60svh]">
        {showKinds && (
          <Section title={kinds.length ? kinds.map((k) => k.label).join(" / ") : t("library.reels.filterKinds")}>
            <Chip label={t("media.filters.all")} selected={kind === null} onClick={() => onApply({ filter, kind: null })} />
            {kinds.map((value) => (
              <Chip
                key={value.value}
                label={value.label}
                count={value.count}
                selected={kind === value.value}
                onClick={() => {
                  const next = kind === value.value ? null : value.value;
                  // 切到「其他」时清掉不适用的条件，只留观看状态
                  onApply({ filter: next === "video" ? watchOnly(filter) : filter, kind: next });
                }}
              />
            ))}
          </Section>
        )}
        {filterable &&
          REEL_DIMENSIONS.map((key) => {
            const values = reelFacetValues(facets, key);
            const selected = reelFilterValues(filter, key);
            return (
              <Section key={key} title={titles[key]}>
                {values.length === 0 && (
                  <p className="text-caption text-[var(--text-faint)]">
                    {facets === null ? t("common.loading") : t("library.reels.filterNothing")}
                  </p>
                )}
                {values.map((value) => (
                  <Chip
                    key={value.value}
                    label={value.label}
                    count={value.count}
                    selected={selected.includes(value.value)}
                    onClick={() => onApply({ filter: toggleReelFilter(filter, key, value.value), kind })}
                  />
                ))}
              </Section>
            );
          })}
        <div className="border-t border-white/[0.07] pt-4">
          <Chip
            label={t("library.rows.onlyUnwatched")}
            count={unwatched?.count}
            selected={filter.watch === "unwatched"}
            onClick={() => onApply({ filter: toggleReelFilter(filter, "watch", "unwatched"), kind })}
            testId="reels-filter-unwatched"
          />
        </div>
      </div>
    </Modal>
  );
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <fieldset>
      <legend className="mb-2.5 text-sub font-semibold text-[var(--text-muted)]">{title}</legend>
      <div className="flex flex-wrap gap-2">{children}</div>
    </fieldset>
  );
}

/** 一个可勾选的取值：后面带剩余部数；为 0 且没勾着的置灰不可点（勾着的得能取消） */
function Chip({
  label,
  count,
  selected,
  onClick,
  testId,
}: {
  label: string;
  count?: number;
  selected: boolean;
  onClick: () => void;
  testId?: string;
}) {
  const dead = count === 0 && !selected;
  return (
    <button
      type="button"
      aria-pressed={selected}
      disabled={dead}
      onClick={onClick}
      data-testid={testId}
      className={`flex items-center gap-1.5 rounded-full border px-3 py-1.5 text-sub font-semibold transition ${
        selected
          ? "border-white/25 bg-white/15 text-white"
          : "border-white/[0.07] bg-black/20 text-[var(--text-muted)]"
      } ${dead ? "opacity-30" : ""}`}
    >
      {label}
      {count !== undefined && <span className="font-mono text-caption font-normal tabular-nums text-white/45">{count}</span>}
    </button>
  );
}
