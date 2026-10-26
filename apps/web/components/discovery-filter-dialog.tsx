"use client";

import { useLocale, useTranslations } from "next-intl";
import type { AppLocale } from "@/lib/i18n/negotiate";
import { appTranslator } from "@/lib/i18n/translate";
import { useEffect, useMemo, useRef, useState, type ComponentType } from "react";
import * as DropdownMenu from "@radix-ui/react-dropdown-menu";

import {
  CalendarIcon,
  CheckIcon,
  ChevronDownIcon,
  ChevronLeftIcon,
  ChevronRightIcon,
  ClockIcon,
  FilmIcon,
  FilterIcon,
  GlobeIcon,
  ListIcon,
  StarIcon,
  XIcon,
} from "@/components/icons";
import { Modal } from "@/components/modal";
import { PAGE_NAV_BUTTON_CLASS } from "@/components/page-nav";
import { fetchDiscoveryGenres, type DiscoveryGenre } from "@/lib/api/discover";
import {
  clearDiscoveryDimension,
  discoveryCountries,
  DISCOVERY_FILTER_DIMENSIONS,
  DISCOVERY_RATING_STEPS,
  DISCOVERY_RUNTIME_STEPS,
  discoverySorts,
  discoveryDimensionSummary,
  discoveryDimensionTitle,
  discoveryDimensionValue,
  discoveryFilterButtonTitle,
  discoveryFilterCount,
  EMPTY_DISCOVERY_FILTERS,
  withDiscoveryDimension,
  type DiscoveryFilterDimension,
  type DiscoveryFilters,
} from "@/lib/discovery-filters";
import type { MediaType } from "@/lib/media-types";

/*
 * 组合发现的筛选入口，两套形态：
 *   - 银玻璃（两端）：下拉菜单，对齐原生 App（apps/apple/.../Discover/DiscoverFilter.swift）——
 *     条件只是「从几个值里挑一个」（类型可多挑），正好是下拉菜单装得下的量，选中即生效、
 *     没有「查看结果」。右上角 DiscoveryFilterMenu 与结果页头部 DiscoveryFilterChips
 *     共用同一份取值清单（DimensionOptions）。
 *   - Netflix：维持原来的组合筛选弹窗 DiscoveryFilterControl（主题展示不动）。
 */

// —— 类型清单：电影与剧集是两套 TMDB 类型 ID，整个会话内不变 ——
// 模块级一份缓存，筛选键、结果页胶囊与 Netflix 弹窗共用；并发请求合并成一次。
const genreCache = new Map<MediaType, DiscoveryGenre[]>();
const genreRequests = new Map<MediaType, Promise<DiscoveryGenre[]>>();

function loadDiscoveryGenres(mediaType: MediaType): Promise<DiscoveryGenre[]> {
  const cached = genreCache.get(mediaType);
  if (cached) return Promise.resolve(cached);
  let request = genreRequests.get(mediaType);
  if (!request) {
    request = fetchDiscoveryGenres(mediaType)
      .then((items) => {
        genreCache.set(mediaType, items);
        return items;
      })
      .finally(() => genreRequests.delete(mediaType));
    genreRequests.set(mediaType, request);
  }
  return request;
}

/**
 * 读类型清单：undefined = 加载中，null = 拉取失败（其他维度照常可用）。
 * 失败不进缓存，下次挂载会重试。
 */
export function useDiscoveryGenres(
  mediaType: MediaType,
  enabled = true,
): DiscoveryGenre[] | null | undefined {
  const [result, setResult] = useState<{
    mediaType: MediaType;
    genres: DiscoveryGenre[] | null;
  } | null>(null);
  useEffect(() => {
    if (!enabled || genreCache.has(mediaType)) return;
    let cancelled = false;
    loadDiscoveryGenres(mediaType).then(
      (genres) => {
        if (!cancelled) setResult({ mediaType, genres });
      },
      () => {
        if (!cancelled) setResult({ mediaType, genres: null });
      },
    );
    return () => {
      cancelled = true;
    };
  }, [enabled, mediaType]);
  return genreCache.get(mediaType) ?? (result?.mediaType === mediaType ? result.genres : undefined);
}

function useGenreNames(genres: DiscoveryGenre[] | null | undefined): ReadonlyMap<number, string> {
  return useMemo(() => new Map((genres ?? []).map((genre): [number, string] => [genre.id, genre.name])), [genres]);
}

/** 发现页各下拉菜单的菜单项（与 filter-menu.tsx 同一套 glass-row + menu-surface 皮肤） */
export const DISCOVER_MENU_ITEM_CLASS =
  "glass-row nav-item flex cursor-pointer items-center gap-2.5 px-3 py-2 text-sub text-white/85 outline-none data-[highlighted]:!bg-[var(--glass-fill-hover)] data-[disabled]:pointer-events-none data-[disabled]:opacity-50";
const MENU_CONTENT_CLASS =
  // 年份有一百多项：面板限高、自己滚（不超过 Radix 算出的可用高度）
  "menu-surface scroll-thin z-50 w-[17rem] max-w-[calc(100vw-24px)] max-h-[min(26rem,var(--radix-dropdown-menu-content-available-height))] overflow-y-auto p-1";
const MENU_SEPARATOR_CLASS = "my-1 h-px bg-white/[0.07]";
const DANGER_ITEM_CLASS = `${DISCOVER_MENU_ITEM_CLASS} !text-[var(--danger)]`;

const DIMENSION_ICONS: Record<DiscoveryFilterDimension, ComponentType<{ className?: string }>> = {
  genres: FilmIcon,
  country: GlobeIcon,
  year: CalendarIcon,
  rating: StarIcon,
  runtime: ClockIcon,
  sort: ListIcon,
};

/** 单选项左侧的勾位：选中画勾，未选中留同宽空位，文字左缘对齐 */
function CheckSlot() {
  return (
    <span className="flex size-4 shrink-0 items-center justify-center">
      <DropdownMenu.ItemIndicator>
        <CheckIcon className="size-3.5 text-[var(--info)]" />
      </DropdownMenu.ItemIndicator>
    </span>
  );
}

/**
 * 一个维度的取值清单，放进下拉菜单里用（对应 iOS 的 DiscoverFilterOptions）：
 * 单选维度是单选组（带勾，选中即收起菜单）；类型是多选开关——点一下切一个、菜单不关，
 * 要连勾几个不必反复点开（与 iOS「选一项即收起」有意不同：网页二级是点进来的，
 * 收起后再勾一个要多点两下）。
 */
function DimensionOptions({
  dimension,
  currentYear,
  genres,
  filters,
  onChange,
}: {
  dimension: DiscoveryFilterDimension;
  currentYear: number;
  genres: DiscoveryGenre[] | null | undefined;
  filters: DiscoveryFilters;
  onChange: (filters: DiscoveryFilters) => void;
}) {
  const locale = useLocale();
  const t = useTranslations();
  if (dimension === "genres") {
    if (!genres || genres.length === 0) {
      return (
        <DropdownMenu.Item disabled className={DISCOVER_MENU_ITEM_CLASS}>
          {genres === null ? t("media.filters.genresFailed") : t("media.filters.genresLoading")}
        </DropdownMenu.Item>
      );
    }
    return (
      <>
        {genres.map((genre) => (
          <DropdownMenu.CheckboxItem
            key={genre.id}
            checked={filters.genreIds.includes(genre.id)}
            onSelect={(event) => event.preventDefault()}
            onCheckedChange={(on) => {
              const rest = filters.genreIds.filter((id) => id !== genre.id);
              onChange({ ...filters, genreIds: on ? [...rest, genre.id] : rest });
            }}
            className={DISCOVER_MENU_ITEM_CLASS}
          >
            <CheckSlot />
            {genre.name}
          </DropdownMenu.CheckboxItem>
        ))}
      </>
    );
  }
  const unlimited: Array<[string, string]> = [["", t("media.filters.unlimited")]];
  const options: Array<[string, string]> =
    dimension === "country"
      ? [...unlimited, ...discoveryCountries(locale).map(([code, label]): [string, string] => [code, label])]
      : dimension === "year"
        ? [
            ...unlimited,
            ...Array.from({ length: Math.max(1, currentYear - 1873) }, (_, index): [string, string] => {
              const year = currentYear - index;
              return [String(year), t("media.filters.yearValue", { year })];
            }),
          ]
        : dimension === "rating"
          ? [...unlimited, ...DISCOVERY_RATING_STEPS.map((v): [string, string] => [String(v), t("media.filters.ratingValue", { rating: v })])]
          : dimension === "runtime"
            ? [...unlimited, ...DISCOVERY_RUNTIME_STEPS.map((v): [string, string] => [String(v), t("media.filters.runtimeValue", { minutes: v })])]
            : discoverySorts(locale);
  const value = discoveryDimensionValue(filters, dimension);
  return (
    // Radix 点已选中的那一项也会回调 onValueChange：同值直接忽略
    <DropdownMenu.RadioGroup
      value={value}
      onValueChange={(next) => {
        if (next !== value) onChange(withDiscoveryDimension(filters, dimension, next));
      }}
    >
      {options.map(([optionValue, label]) => (
        <DropdownMenu.RadioItem key={optionValue} value={optionValue} className={DISCOVER_MENU_ITEM_CLASS}>
          <CheckSlot />
          {label}
        </DropdownMenu.RadioItem>
      ))}
    </DropdownMenu.RadioGroup>
  );
}

/** 维度未启用时的占位文字（排序停在默认档也写出来） */
function idleSummary(dimension: DiscoveryFilterDimension, locale?: AppLocale): string {
  const t = appTranslator(locale);
  return dimension === "sort" ? t("media.filters.popular") : t("media.filters.unlimited");
}

/**
 * 右上角筛选键（银玻璃；对应 iOS 的 DiscoverFilterMenu，照 App Store「App」页右上角
 * 的类别按钮）：玻璃胶囊只写当前类型——「全部 / 动作 / 动作等 2 个」，其他维度在结果页
 * 头部胶囊里写清楚。点开是六个维度，每项右侧是当前值，有条件时末尾红色「清空条件」。
 *
 * 二级取值做成**同一面板内点进 → 返回**，不用 Radix 的侧弹子菜单：390px 宽的手机上
 * 侧弹没地方放，会翻到另一侧盖住一级菜单；年份一百多项靠面板限高滚动。
 */
export function DiscoveryFilterMenu({
  mediaType,
  filters,
  currentYear,
  onChange,
  compact = false,
  disabled = false,
}: {
  mediaType: MediaType;
  filters: DiscoveryFilters;
  currentYear: number;
  onChange: (filters: DiscoveryFilters) => void;
  /** 手机顶栏档：高度与顶栏圆键同档、不带图标；桌面档前面加一枚筛选图标说明用途 */
  compact?: boolean;
  /** 豆瓣源不支持筛选：桌面工具栏里禁用置灰原地保留（避免工具栏跳动） */
  disabled?: boolean;
}) {
  const locale = useLocale();
  const t = useTranslations();
  const genres = useDiscoveryGenres(mediaType, !disabled);
  const genreNames = useGenreNames(genres);
  const [level, setLevel] = useState<DiscoveryFilterDimension | null>(null);
  const contentRef = useRef<HTMLDivElement>(null);
  const title = discoveryFilterButtonTitle(filters, genreNames, locale);

  /** 换一级：面板回到顶部，焦点落到新一级的第一项（键盘操作不断档） */
  const go = (next: DiscoveryFilterDimension | null) => {
    setLevel(next);
    requestAnimationFrame(() => {
      const content = contentRef.current;
      if (!content) return;
      content.scrollTop = 0;
      content.querySelector<HTMLElement>("[role^='menuitem']:not([data-disabled])")?.focus();
    });
  };

  return (
    <DropdownMenu.Root onOpenChange={(open) => !open && setLevel(null)}>
      <DropdownMenu.Trigger asChild>
        <button
          type="button"
          disabled={disabled}
          title={disabled ? t("media.filters.tmdbOnly") : undefined}
          aria-label={t("media.filters.buttonLabel", { title })}
          className={`page-nav-btn flex min-w-0 max-w-[10rem] shrink-0 items-center gap-1.5 rounded-full border border-white/[0.09] bg-black/30 text-sub font-semibold text-white/85 backdrop-blur-md transition hover:bg-black/50 hover:text-white active:scale-[0.97] disabled:pointer-events-none disabled:opacity-40 data-[state=open]:bg-black/50 ${
            compact ? "h-9 px-3.5 pointer-coarse:h-11 pointer-coarse:px-4" : "h-10 px-4"
          }`}
        >
          {!compact && <FilterIcon className="size-4 shrink-0" />}
          <span className="truncate">{title}</span>
        </button>
      </DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content
          ref={contentRef}
          align="end"
          sideOffset={8}
          collisionPadding={12}
          className={MENU_CONTENT_CLASS}
        >
          {level ? (
            <>
              <DropdownMenu.Item
                onSelect={(event) => {
                  event.preventDefault();
                  go(null);
                }}
                className={`${DISCOVER_MENU_ITEM_CLASS} font-semibold`}
              >
                <ChevronLeftIcon className="size-4 shrink-0 text-white/55" />
                {discoveryDimensionTitle(level, mediaType, locale)}
              </DropdownMenu.Item>
              <DropdownMenu.Separator className={MENU_SEPARATOR_CLASS} />
              <DimensionOptions
                dimension={level}
                currentYear={currentYear}
                genres={genres}
                filters={filters}
                onChange={onChange}
              />
            </>
          ) : (
            <>
              {DISCOVERY_FILTER_DIMENSIONS.map((dimension) => {
                const Icon = DIMENSION_ICONS[dimension];
                return (
                  <DropdownMenu.Item
                    key={dimension}
                    onSelect={(event) => {
                      event.preventDefault();
                      go(dimension);
                    }}
                    className={DISCOVER_MENU_ITEM_CLASS}
                  >
                    <Icon className="size-4 shrink-0 text-white/55" />
                    <span className="shrink-0">{discoveryDimensionTitle(dimension, mediaType, locale)}</span>
                    <span className="ml-auto min-w-0 truncate text-caption text-[var(--text-muted)]">
                      {discoveryDimensionSummary(dimension, filters, genreNames, locale) ?? idleSummary(dimension, locale)}
                    </span>
                    <ChevronRightIcon className="size-3.5 shrink-0 text-white/40" />
                  </DropdownMenu.Item>
                );
              })}
              {discoveryFilterCount(filters) > 0 && (
                <>
                  <DropdownMenu.Separator className={MENU_SEPARATOR_CLASS} />
                  <DropdownMenu.Item
                    onSelect={() => onChange(EMPTY_DISCOVERY_FILTERS)}
                    className={DANGER_ITEM_CLASS}
                  >
                    <XIcon className="size-4 shrink-0" />
                    {t("media.discovery.clearFilters")}
                  </DropdownMenu.Item>
                </>
              )}
            </>
          )}
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );
}

/**
 * 结果页头部的条件胶囊（银玻璃；对应 iOS 的 DiscoverFilterChips，地图搜索结果那排胶囊的形态）：
 * 六个维度固定顺序各一颗、可横滑，已启用的高亮写当前值，未启用只写维度名。点开是同一份
 * 取值清单，已启用的末尾多一项「移除此条件」（排序写「恢复热门优先」）。
 */
export function DiscoveryFilterChips({
  mediaType,
  currentYear,
  genres,
  filters,
  onChange,
}: {
  mediaType: MediaType;
  currentYear: number;
  genres: DiscoveryGenre[] | null | undefined;
  filters: DiscoveryFilters;
  onChange: (filters: DiscoveryFilters) => void;
}) {
  const locale = useLocale();
  const t = useTranslations();
  const genreNames = useGenreNames(genres);
  return (
    // 横滑出页边距：胶囊滑到屏幕边缘才消失，而不是在页边距处被一刀切掉
    <div
      className="page-inset-bleed page-inset scroll-none flex gap-2 overflow-x-auto py-1"
      role="group"
      aria-label={t("media.discovery.activeFilters")}
    >
      {DISCOVERY_FILTER_DIMENSIONS.map((dimension) => {
        const summary = discoveryDimensionSummary(dimension, filters, genreNames, locale);
        const name = discoveryDimensionTitle(dimension, mediaType, locale);
        return (
          <DropdownMenu.Root key={dimension}>
            <DropdownMenu.Trigger asChild>
              <button
                type="button"
                aria-label={summary ? t("media.filters.dimensionLabel", { name, summary }) : name}
                className={`flex h-[34px] shrink-0 items-center gap-1 rounded-full border px-3 text-sub backdrop-blur-md transition active:scale-[0.97] ${
                  summary
                    ? "border-white/20 bg-white/[0.16] font-semibold text-[var(--text)]"
                    : "border-white/[0.09] bg-black/30 text-[var(--text-muted)] hover:text-white"
                }`}
              >
                <span className="max-w-[12rem] truncate">{summary ?? name}</span>
                <ChevronDownIcon className="size-3 shrink-0 opacity-60" />
              </button>
            </DropdownMenu.Trigger>
            <DropdownMenu.Portal>
              <DropdownMenu.Content
                align="start"
                sideOffset={6}
                collisionPadding={12}
                className={MENU_CONTENT_CLASS}
              >
                <DimensionOptions
                  dimension={dimension}
                  currentYear={currentYear}
                  genres={genres}
                  filters={filters}
                  onChange={onChange}
                />
                {summary && (
                  <>
                    <DropdownMenu.Separator className={MENU_SEPARATOR_CLASS} />
                    <DropdownMenu.Item
                      onSelect={() => onChange(clearDiscoveryDimension(filters, dimension))}
                      className={DANGER_ITEM_CLASS}
                    >
                      <XIcon className="size-4 shrink-0" />
                      {dimension === "sort" ? t("media.filters.resetSort") : t("media.filters.remove")}
                    </DropdownMenu.Item>
                  </>
                )}
              </DropdownMenu.Content>
            </DropdownMenu.Portal>
          </DropdownMenu.Root>
        );
      })}
    </div>
  );
}

const selectClass =
  "h-10 w-full rounded-xl border border-white/10 bg-black/30 px-3 text-body text-[var(--text)] outline-none focus:border-white/25";

/** Netflix 主题的组合筛选弹窗（展示维持原样；银玻璃改用上面的下拉菜单） */
export function DiscoveryFilterControl({
  mediaType,
  filters,
  currentYear,
  onApply,
  compact = false,
  disabled = false,
}: {
  mediaType: MediaType;
  filters: DiscoveryFilters;
  currentYear: number;
  onApply: (filters: DiscoveryFilters) => void;
  /** 移动端顶栏的图标形态（40px 圆钮 + 角标），与文字形态同开一个弹窗 */
  compact?: boolean;
  /** 豆瓣源不支持筛选：禁用置灰原地保留（不整体隐藏，避免顶栏跳动重排） */
  disabled?: boolean;
}) {
  const locale = useLocale();
  const t = useTranslations();
  const [open, setOpen] = useState(false);
  const [draft, setDraft] = useState(filters);
  const loadedGenres = useDiscoveryGenres(mediaType, open);
  const genres = loadedGenres ?? [];
  const genreError = loadedGenres === null;
  const activeCount = discoveryFilterCount(filters);

  useEffect(() => {
    if (open) setDraft(filters);
  }, [filters, open]);

  const toggleGenre = (id: number) => {
    setDraft((current) => ({
      ...current,
      genreIds: current.genreIds.includes(id)
        ? current.genreIds.filter((value) => value !== id)
        : [...current.genreIds, id],
    }));
  };

  const apply = () => {
    onApply(draft);
    setOpen(false);
  };

  return (
    <>
      {compact ? (
        /* 移动端顶栏的紧凑档：去掉「筛选」文字换成图标 + 角标计数——顶栏要
           同时装下电影/剧集切换、筛选、数据源切换与搜索键，文字按钮放不下。
           圆钮规格直接复用全站 PAGE_NAV_BUTTON_CLASS，与顶栏搜索键完全同款
           （鼠标 36px / 触屏 44px），保证同一行圆键永远一样大、一套玻璃配方。
           豆瓣源下禁用置灰。 */
        <button
          type="button"
          onClick={() => setOpen(true)}
          disabled={disabled}
          title={disabled ? t("media.filters.tmdbOnly") : undefined}
          className={`relative shrink-0 ${PAGE_NAV_BUTTON_CLASS} ${
            disabled ? "pointer-events-none opacity-40" : ""
          }`}
          aria-label={activeCount > 0 ? t("media.filters.activeLabel", { count: activeCount }) : t("media.filters.open")}
        >
          <FilterIcon className="size-[18px]" />
          {activeCount > 0 && (
            <span className="tnum absolute -right-1 -top-1 flex size-[18px] items-center justify-center rounded-full bg-[var(--accent)] text-micro font-bold text-black">
              {activeCount}
            </span>
          )}
        </button>
      ) : (
        <button
          type="button"
          onClick={() => setOpen(true)}
          disabled={disabled}
          title={disabled ? t("media.filters.tmdbOnly") : undefined}
          className={`relative flex h-10 shrink-0 items-center rounded-full border border-white/10 bg-black/35 px-4 text-sub font-semibold text-[var(--text-muted)] backdrop-blur-xl transition ${
            disabled ? "cursor-not-allowed opacity-40" : "hover:border-white/20 hover:text-white"
          }`}
          aria-label={activeCount > 0 ? t("media.filters.activeLabel", { count: activeCount }) : t("media.filters.open")}
        >
          {t("media.filters.filter")}
          {activeCount > 0 && (
            <span className="tnum ml-2 flex size-5 items-center justify-center rounded-full bg-[var(--accent)] text-micro font-bold text-black">
              {activeCount}
            </span>
          )}
        </button>
      )}
      <Modal
        open={open}
        onClose={() => setOpen(false)}
        label={t("media.filters.combine")}
        width="2xl"
        panelClassName="flex max-h-[82vh] flex-col"
      >
        <div className="flex items-center justify-between border-b border-white/[0.07] px-6 py-5 max-md:px-4">
          <div>
            <h2 className="text-body-lg font-semibold text-[var(--text)]">{t("media.filters.combinedTitle")}</h2>
            <p className="mt-1 text-sub text-[var(--text-muted)]">{t("media.filters.shareHint")}</p>
          </div>
          <button
            type="button"
            onClick={() => setOpen(false)}
            className="icon-chip flex size-9"
            aria-label={t("media.filters.close")}
          >
            <XIcon className="size-4" />
          </button>
        </div>

        {/* 手机（底部抽屉）：内容区限高约半屏、自己滚，头（标题/关闭）与底（重置/应用）
            常驻可见——Modal 在手机上为了软键盘把面板高度放开到整屏，不在这里夹一下，
            类型筹码 + 六个下拉一路长到快满屏（2026-09-24 用户反馈）。内容少时仍按内容高。 */}
        <div className="scroll-thin flex-1 space-y-6 overflow-y-auto px-6 py-5 max-md:max-h-[52svh] max-md:px-4">
          <fieldset>
            <legend className="mb-3 text-sub font-semibold text-[var(--text-muted)]">{t("media.filters.multipleGenres")}</legend>
            {genreError ? (
              <p className="text-sub text-red-300">{t("media.filters.genresControlFailed")}</p>
            ) : genres.length === 0 ? (
              <div className="h-16 animate-pulse rounded-xl bg-white/[0.05]" />
            ) : (
              <div className="flex flex-wrap gap-2">
                {genres.map((genre) => {
                  const selected = draft.genreIds.includes(genre.id);
                  return (
                    <button
                      key={genre.id}
                      type="button"
                      aria-pressed={selected}
                      onClick={() => toggleGenre(genre.id)}
                      className={`rounded-full border px-3 py-1.5 text-sub font-semibold transition ${
                        selected
                          ? "border-white/25 bg-white/15 text-white"
                          : "border-white/[0.07] bg-black/20 text-[var(--text-muted)] hover:text-white"
                      }`}
                    >
                      {genre.name}
                    </button>
                  );
                })}
              </div>
            )}
          </fieldset>

          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
            <FilterSelect
              label={t("media.filters.country")}
              value={draft.originCountry ?? ""}
              onChange={(value) => setDraft((current) => ({ ...current, originCountry: value || undefined }))}
              options={discoveryCountries(locale).map(([value, label]) => ({ value, label }))}
            />
            <FilterSelect
              label={mediaType === "movie" ? t("media.filters.movieYear") : t("media.filters.tvYear")}
              value={draft.year ? String(draft.year) : ""}
              onChange={(value) => setDraft((current) => ({ ...current, year: value ? Number(value) : undefined }))}
              options={Array.from({ length: Math.max(1, currentYear - 1873) }, (_, index) => {
                const year = currentYear - index;
                return { value: String(year), label: t("media.filters.yearValue", { year }) };
              })}
            />
            <FilterSelect
              label={t("media.filters.rating")}
              value={draft.ratingGte === undefined ? "" : String(draft.ratingGte)}
              onChange={(value) => setDraft((current) => ({ ...current, ratingGte: value ? Number(value) : undefined }))}
              options={[6, 7, 8, 9].map((value) => ({ value: String(value), label: t("media.filters.ratingValue", { rating: value }) }))}
            />
            <FilterSelect
              label={mediaType === "movie" ? t("media.filters.movieRuntime") : t("media.filters.tvRuntime")}
              value={draft.runtimeLte ? String(draft.runtimeLte) : ""}
              onChange={(value) => setDraft((current) => ({ ...current, runtimeLte: value ? Number(value) : undefined }))}
              options={[60, 90, 120, 150].map((value) => ({ value: String(value), label: t("media.filters.runtimeValue", { minutes: value }) }))}
            />
            <FilterSelect
              label={t("media.filters.sort")}
              value={draft.sort}
              onChange={(value) => setDraft((current) => ({ ...current, sort: value as DiscoveryFilters["sort"] }))}
              options={[
                { value: "popular", label: t("media.filters.popular") },
                { value: "rating", label: t("media.filters.rated") },
                { value: "newest", label: t("media.filters.newest") },
                { value: "most-rated", label: t("media.filters.mostRated") },
              ]}
              allowEmpty={false}
            />
          </div>
        </div>

        <div className="flex items-center justify-between border-t border-white/[0.07] px-6 py-4 max-md:px-4">
          <button
            type="button"
            onClick={() => setDraft(EMPTY_DISCOVERY_FILTERS)}
            className="text-ui font-semibold text-[var(--text-muted)] transition hover:text-white"
          >
            {t("media.filters.clear")}
          </button>
          <button type="button" onClick={apply} className="btn-accent h-10 rounded-full px-6 text-ui font-semibold">
            {t("media.filters.viewResults")}
          </button>
        </div>
      </Modal>
    </>
  );
}

function FilterSelect({
  label,
  value,
  onChange,
  options,
  allowEmpty = true,
}: {
  label: string;
  value: string;
  onChange: (value: string) => void;
  options: Array<{ value: string; label: string }>;
  allowEmpty?: boolean;
}) {
  const t = useTranslations();
  return (
    <label className="block">
      <span className="mb-2 block text-sub font-semibold text-[var(--text-muted)]">{label}</span>
      <select value={value} onChange={(event) => onChange(event.target.value)} className={selectClass}>
        {allowEmpty && <option value="">{t("media.filters.unlimited")}</option>}
        {options.map((option) => (
          <option key={option.value} value={option.value}>
            {option.label}
          </option>
        ))}
      </select>
    </label>
  );
}
