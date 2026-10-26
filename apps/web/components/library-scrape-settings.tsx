"use client";

/**
 * 「编辑库 → 刮削设置」页签（docs/design/scrape-customization.md §14.5）。
 *
 * 与全局设置页**共用同一套控件**（`scrape-settings-section.tsx` 导出的卡片与
 * 字段组），差别在外层：全局页是 tab，这里是**手风琴**。
 *
 * 为什么这里不用 tab：
 * - 库设置里绝大多数卡片停在"跟随全局"，用户只想改一两项。手风琴把全部卡片的
 *   状态摊在一屏（「跟随全局：zh-CN → en-US」/「自定义：日本語 → …」），tab 得
 *   逐个点开才知道自己改过什么——"我这个库到底改了哪几项"是这个页面最该一眼
 *   回答的问题；
 * - 中文标签压不短（「命名与整理」「目录写入」），390px 的 tab 条必然换行、
 *   高度参差；竖排没有横向压力；
 * - 弹窗里 tab → 卡片是两层嵌套，压成一层后分组标题降级为不可点的分节标签，
 *   不再占点击预算。
 *
 * 三态怎么表达（设计文档 §14.5 的表）：
 * - 排序芯片与数字输入没有"空值"可表达跟随，用**卡片级**开关（由 Card 渲染）：
 *   切到自定义时拿全局当前值做种子。粒度卡在"卡片"是两头夹出来的——再粗（整个
 *   分组一个开关）会让只覆盖了语言的库把分级也显示成已自定义，状态是错的；
 *   再细（逐字段）对有序列表没有意义；
 * - 命名模板留空即跟随（沿用 P3 的 placeholder 机制）；
 * - 目录写入是「跟随全局 / 开 / 关」三档按钮（同样沿用 P3）。
 *
 * 覆盖对象的语义与后端一致：**只存显式覆盖的字段**，空对象 = 全跟全局。
 */

import { useLocale, useTranslations } from "next-intl";
import { formatList } from "@/lib/format";
import { appTranslator } from "@/lib/i18n/translate";
import { useCallback, useEffect, useMemo, useState } from "react";

import {
  Card,
  type CardShell,
  ImagesTab,
  MetaTab,
  ScrapeSection,
  describeScrapeValues,
  useScrapeChipOptions,
} from "@/components/scrape-settings-section";
import { type ScrapeConfigView, type ScrapeSetting, getScrapeConfig } from "@/lib/api/scrape";
import { BrandLoader } from "@/components/brand-loader";

function namingFields(t: ReturnType<typeof appTranslator>) {
  return [
    { key: "naming_entry_dir", label: t("settings.scrape.entryDirectory"), fallback: "{title} ({year})" },
    { key: "naming_movie_file", label: t("settings.scrape.movieFilename"), fallback: "{title} ({year})" },
    { key: "naming_season_dir", label: t("settings.scrape.seasonDirectory"), fallback: "Season {season:02d}" },
    {
      key: "naming_episode_file",
      label: t("settings.scrape.episodeFilename"),
      fallback: "{title} ({year}) - S{season:02d}E{episode:02d}",
    },
  ] as const;
}

function mirrorFields(t: ReturnType<typeof appTranslator>) {
  return [
    { key: "mirror_images", label: t("settings.scrape.mirrorImages") },
    { key: "mirror_nfo", label: t("settings.scrape.mirrorNfo") },
    { key: "mirror_episode_thumbs", label: t("settings.scrape.mirrorStills") },
  ] as const;
}

export function LibraryScrapeSettings({
  overrides,
  onChange,
}: {
  overrides: Record<string, unknown>;
  onChange: (next: Record<string, unknown>) => void;
}) {
  const t = useTranslations();
  const locale = useLocale();
  // 展开的卡片标题（同时只开一张）；默认全收起——状态在折叠头上已经看得见
  const [open, setOpen] = useState<string | null>(null);
  const [config, setConfig] = useState<ScrapeConfigView | null>(null);
  const [error, setError] = useState<string | null>(null);
  const chipOptions = useScrapeChipOptions();

  useEffect(() => {
    getScrapeConfig()
      .then(setConfig)
      .catch((err: unknown) =>
        setError(err instanceof Error ? err.message : appTranslator()("settings.scrape.globalLoadFailed")),
      );
  }, []);

  /** 全局基线：与设置页同一套"编辑态用生效值起步"的口径。 */
  const base = useMemo<ScrapeSetting | null>(() => {
    if (!config) return null;
    return {
      ...config.setting,
      language_priority: config.setting.language_priority.length
        ? config.setting.language_priority
        : config.effective.language_priority,
      // 全局画质没选过（空串）时按生效值反推的那一档：「跟随全局：原图」才说得出来，
      // 切到自定义时也从这一档起步
      image_quality: config.setting.image_quality || config.effective.image_quality,
    };
  }, [config]);

  /** 交给共用控件渲染的完整设置 = 全局基线叠加本库覆盖。 */
  const merged = useMemo<ScrapeSetting | null>(
    () => (base ? { ...base, ...(overrides as Partial<ScrapeSetting>) } : null),
    [base, overrides],
  );

  const patch = useCallback(
    (changes: Partial<ScrapeSetting>) => onChange({ ...overrides, ...changes }),
    [overrides, onChange],
  );

  const setField = useCallback(
    (key: string, value: unknown) => {
      const next = { ...overrides };
      if (value === undefined) delete next[key];
      else next[key] = value;
      onChange(next);
    },
    [overrides, onChange],
  );

  const toggleOpen = useCallback(
    (title: string) => setOpen((current) => (current === title ? null : title)),
    [],
  );

  /** 卡片级三态那几张卡的壳：折叠 + 状态摘要 + 跟随/自定义开关。 */
  const shellFor = useCallback(
    (title: string, keys: (keyof ScrapeSetting)[]): CardShell => {
      const custom = keys.some((key) => key in overrides);
      return {
        open: open === title,
        onToggleOpen: () => toggleOpen(title),
        customized: custom,
        status:
          custom && merged
            ? t("settings.scrape.customStatus", { summary: describeScrapeValues(keys, merged, locale) })
            : base
              ? t("settings.scrape.followStatus", { summary: describeScrapeValues(keys, base, locale) })
              : t("settings.scrape.followGlobal"),
        follow: {
          custom,
          globalSummary: base ? describeScrapeValues(keys, base, locale) : "",
          onToggle: (next: boolean) => {
            if (!base) return;
            const patched = { ...overrides };
            for (const key of keys) {
              if (next) patched[key] = base[key];
              else delete patched[key];
            }
            onChange(patched);
          },
        },
      };
    },
    [base, merged, open, overrides, onChange, toggleOpen, locale, t],
  );

  /** 字段级三态那两张卡（命名/目录写入）的壳：没有卡片级开关，状态数覆盖项。 */
  const fieldShellFor = useCallback(
    (title: string, fields: readonly { key: string; label: string }[]): CardShell => {
      const hit = fields.filter((f) => f.key in overrides);
      return {
        open: open === title,
        onToggleOpen: () => toggleOpen(title),
        customized: hit.length > 0,
        status: hit.length > 0 ? t("settings.scrape.customStatus", { summary: formatList(hit.map((f) => f.label), locale) }) : t("settings.scrape.followGlobal"),
      };
    },
    [open, overrides, toggleOpen, locale, t],
  );

  if (error) {
    return <p className="text-sub text-[var(--text-muted)]">{error}</p>;
  }
  if (!merged || !base) {
    return (
      <p className="flex items-center gap-2.5 text-sub text-[var(--text-muted)]">
        <BrandLoader className="size-5" />
        {t("settings.scrape.globalLoading")}
      </p>
    );
  }

  const overrideCount = Object.keys(overrides).length;

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="min-w-0 flex-1 text-sub leading-relaxed text-[var(--text-muted)]">
          {t("settings.scrape.libraryIntro")}
          {overrideCount > 0 && (
            <span className="ml-1.5 whitespace-nowrap rounded-full bg-[var(--accent-soft)] px-2 py-px text-micro text-[var(--accent)]">
              {t("settings.scrape.overrideCount", { count: overrideCount })}
            </span>
          )}
        </p>
        {/* 一键回到全跟随：没有它，用户想撤掉本库的全部个性化得逐张卡切
            「跟随全局」+ 逐个模板清空，覆盖越多越难收场 */}
        {overrideCount > 0 && (
          <button
            type="button"
            onClick={() => onChange({})}
            className="shrink-0 rounded-full border border-white/[0.12] px-3 py-1 text-caption text-[var(--text-muted)] transition-colors hover:bg-white/[0.06] hover:text-[var(--text)]"
          >
            {t("settings.scrape.resetOverrides")}
          </button>
        )}
      </div>

      <ScrapeSection label={t("settings.scrape.metadataSection")}>
        <MetaTab
          setting={merged}
          patch={patch}
          extraMetaLangs={chipOptions.metaLangs}
          extraCountries={chipOptions.certCountries}
          shellFor={shellFor}
        />
      </ScrapeSection>

      <ScrapeSection label={t("settings.scrape.imagesSection")}>
        <ImagesTab
          setting={merged}
          patch={patch}
          extraImageLangs={chipOptions.imageLangs}
          effective={config?.effective ?? null}
          inheritsGlobal
          shellFor={shellFor}
        />
      </ScrapeSection>

      <ScrapeSection label={t("settings.scrape.namingSection")}>
        <Card
          title={t("settings.scrape.namingTemplates")}
          desc={t("settings.scrape.libraryNamingHint")}
          shell={fieldShellFor(t("settings.scrape.namingTemplates"), namingFields(t))}
        >
          {namingFields(t).map((field) => (
            <div key={field.key} className="mb-2.5 last:mb-0">
              <label className="mb-1 block text-caption text-[var(--text-muted)]">
                {field.label}
              </label>
              <input
                spellCheck={false}
                placeholder={t("settings.scrape.followValue", { value: base[field.key] || field.fallback })}
                value={(overrides[field.key] as string) ?? ""}
                onChange={(e) =>
                  setField(field.key, e.target.value.trim() ? e.target.value : undefined)
                }
                className="w-full rounded-lg border border-white/[0.08] bg-white/[0.04] px-2.5 py-1.5 font-mono text-sub text-[var(--text)] outline-none focus:border-[var(--accent)]/60"
              />
            </div>
          ))}
        </Card>
      </ScrapeSection>

      <ScrapeSection label={t("settings.scrape.mirrorSection")}>
        <Card
          title={t("settings.scrape.mediaDirectoryWrites")}
          desc={t("settings.scrape.libraryMirrorHint")}
          shell={fieldShellFor(t("settings.scrape.mediaDirectoryWrites"), mirrorFields(t))}
        >
          {mirrorFields(t).map((field) => {
            const value = overrides[field.key] as boolean | undefined;
            return (
              <div
                key={field.key}
                className="flex flex-wrap items-center justify-between gap-2 border-t border-white/[0.05] py-2.5 first:border-t-0 first:pt-0"
              >
                <span className="text-sub">{field.label}</span>
                <div className="flex gap-1">
                  {(
                    [
                      [undefined, t("settings.scrape.followValue", { value: base[field.key] ? t("settings.scrape.on") : t("settings.scrape.off") })],
                      [true, t("settings.scrape.on")],
                      [false, t("settings.scrape.off")],
                    ] as const
                  ).map(([option, label]) => (
                    <button
                      key={String(option)}
                      type="button"
                      onClick={() => setField(field.key, option)}
                      className={`rounded-lg px-2.5 py-1 text-caption transition-colors ${
                        value === option
                          ? "bg-[var(--accent-soft)] text-[var(--text)]"
                          : "text-[var(--text-faint)] hover:bg-white/[0.06]"
                      }`}
                    >
                      {label}
                    </button>
                  ))}
                </div>
              </div>
            );
          })}
        </Card>
      </ScrapeSection>

      <p className="text-caption leading-relaxed text-[var(--text-faint)]">
        {t.rich("settings.scrape.ownershipHint", { strong: (chunks) => <strong className="font-medium text-[var(--text-muted)]">{chunks}</strong> })}
      </p>
    </div>
  );
}
