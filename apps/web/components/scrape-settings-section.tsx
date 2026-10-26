"use client";

/**
 * 「刮削与整理」设置分区（docs/design/scrape-customization.md §3）。
 *
 * 按"配置的是什么"分四个**并列** tab：元数据（语言优先级、分级地区）、
 * 图片（海报/背景语言优先级、门槛、本地图片画质）、命名与整理（模板 + 实时
 * 预览）、目录写入（图片/NFO/分集剧照三项细分开关）。排列顺序沿用刮削
 * 管线的先后，只为读起来顺；**四组之间没有依赖，可任意顺序配置**——
 * 所以不编号：编号会把并列关系伪装成"必须按序完成"的向导。
 *
 * 有序优先级统一用「排序芯片」交互：点击加入优先级并按点击顺序编号
 * （首位标「主」/「首选」），再点移除；常用项直接摆在行内，长尾语种/地区
 * 经「更多」搜索面板加入（全量表来自后端代理的 TMDB configuration 接口）。
 */

import { useLocale, useTranslations } from "next-intl";
import { type AppLocale } from "@/lib/i18n/negotiate";
import { formatList } from "@/lib/format";
import { appTranslator } from "@/lib/i18n/translate";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import { BrandLoader } from "@/components/brand-loader";
import { Toggle } from "@/components/cloud-push-ui";
import { FanartKeyForm, fanartUsable, useFanartStatus } from "@/components/fanart-key-form";
import { useToast } from "@/components/feedback";
import { ChevronDownIcon } from "@/components/icons";
import {
  SETTINGS_BUTTON_CLASS,
  SETTINGS_INPUT_CLASS,
  SETTINGS_PRIMARY_BUTTON_CLASS,
  SettingsList,
  SettingsRow,
  SettingsSection,
} from "@/components/settings-ui";
import {
  type CountryOption,
  IMAGE_QUALITY_PRESETS,
  type ImageQuality,
  type ImageSource,
  type ImageStorageEstimate,
  type LanguageOption,
  type ScrapeConfigView,
  type ScrapeEffective,
  type ScrapeSetting,
  getImageStorageEstimate,
  getScrapeConfig,
  listCountryOptions,
  listLanguageOptions,
  saveScrapeConfig,
} from "@/lib/api/scrape";
import { listLibraries } from "@/lib/api/libraries";

/** 排序芯片的候选项。id 是落库值（语言标签 / 地区码 / meta·orig·null token）。 */
interface ChipOption {
  id: string;
  name: string;
  /** 悬停说明（特殊 token 必配，见设计文档 §3） */
  tip?: string;
}

/** 常用语种快捷芯片（元数据语言，值为带地区的语言标签）。 */
function commonMetaLangs(t: ReturnType<typeof appTranslator>): ChipOption[] {
  return [
    { id: "zh-CN", name: t("settings.scrape.simplifiedChinese") },
    { id: "zh-TW", name: t("settings.scrape.traditionalChinese") },
    { id: "en-US", name: "English" },
    { id: "ja-JP", name: t("settings.scrape.japaneseLanguage") },
    { id: "ko-KR", name: t("settings.scrape.koreanLanguage") },
    { id: "fr-FR", name: t("settings.scrape.frenchLanguage") },
  ];
}

/** 图片语言的特殊 token + 常用语种（值为 TMDB 图片语言码）。 */
function commonImageLangs(t: ReturnType<typeof appTranslator>): ChipOption[] {
  return [
    {
      id: "meta",
      name: t("settings.scrape.metadataPrimary"),
      tip: t("settings.scrape.metadataPrimaryHint"),
    },
    {
      id: "orig",
      name: t("settings.scrape.originalLanguage"),
      tip: t("settings.scrape.originalLanguageHint"),
    },
    { id: "en", name: "English" },
    { id: "null", name: t("settings.scrape.textless"), tip: t("settings.scrape.textlessHint") },
    { id: "ja", name: t("settings.scrape.japaneseLanguage") },
  ];
}

function commonCertCountries(t: ReturnType<typeof appTranslator>): ChipOption[] {
  return [
    { id: "CN", name: t("settings.scrape.china") },
    { id: "US", name: t("settings.scrape.unitedStates") },
    { id: "JP", name: t("settings.scrape.japan") },
    { id: "GB", name: t("settings.scrape.unitedKingdom") },
  ];
}

/** 可选的 TMDB 图床档位：后端 settings/metadata.py 合法集合里实用的那部分（过小的档位不提供）；
 *  空 = 跟随上一级（全局设置页是环境变量，库设置页是全局设置）。 */
const POSTER_SIZES = ["w342", "w500", "w780", "original"];
const BACKDROP_SIZES = ["w780", "w1280", "original"];
const STILL_SIZES = ["w185", "w300", "original"];
/** 演职员头像：w185 手机网页够用，h632 电视也清楚，original 是 TMDB 原图 */
const PROFILE_SIZES = ["w185", "h632", "original"];

/** 「本地图片画质」四档的名字与一句话说明（docs/design/image-sizing.md §8.1）。 */
function imageQualityOptions(t: ReturnType<typeof appTranslator>): { id: ImageQuality; title: string; desc: string }[] {
  return [
    { id: "original", title: t("settings.scrape.originalDefault"), desc: t("settings.scrape.originalHint") },
    { id: "standard", title: t("settings.scrape.standard"), desc: t("settings.scrape.standardHint") },
    { id: "compact", title: t("settings.scrape.compact"), desc: t("settings.scrape.compactHint") },
    { id: "custom", title: t("settings.scrape.custom"), desc: t("settings.scrape.customHint") },
  ];
}

/** 自定义画质的四个档位下拉：字段、名字、可选档位 */
function imageSizeFields(t: ReturnType<typeof appTranslator>) {
  return [
    { key: "poster_size", label: t("settings.scrape.poster"), sizes: POSTER_SIZES },
    { key: "backdrop_size", label: t("settings.scrape.backdrop"), sizes: BACKDROP_SIZES },
    { key: "still_size", label: t("settings.scrape.still"), sizes: STILL_SIZES },
    { key: "profile_size", label: t("settings.scrape.portrait"), sizes: PROFILE_SIZES },
  ] as const;
}

/** 画质卡管的字段：选档本身 + 自定义时的四个档位（库设置页按这一组整体跟随 / 覆盖） */
const IMAGE_QUALITY_KEYS: (keyof ScrapeSetting)[] = [
  "image_quality",
  "poster_size",
  "backdrop_size",
  "still_size",
  "profile_size",
];

/* ------------------------------------------------------------------ */
/* 图片来源（docs/design/image-sources.md）                              */
/* ------------------------------------------------------------------ */

const SOURCE_LABEL: Record<ImageSource, string> = { tmdb: "TMDB", fanart: "Fanart.tv" };

/** 「图片来源」卡管的字段：Fanart 开关 + 四类图的来源顺序（库设置页按这一组整体跟随/覆盖） */
const SOURCE_KEYS: (keyof ScrapeSetting)[] = [
  "fanart_enabled",
  "poster_source_order",
  "backdrop_source_order",
  "logo_source_order",
  "season_poster_source_order",
];

/** 来源顺序的四行：字段、名字、默认谁在前、默认值的理由（行下小字） */
function sourceRows(t: ReturnType<typeof appTranslator>) {
  return [
    { key: "poster_source_order", label: t("settings.scrape.poster"), first: "tmdb", why: t("settings.scrape.tmdbFirst") },
    { key: "backdrop_source_order", label: t("settings.scrape.backdrop"), first: "tmdb", why: t("settings.scrape.tmdb4kFirst") },
    { key: "logo_source_order", label: t("settings.scrape.titleLogo"), first: "fanart", why: t("settings.scrape.fanartChineseFirst") },
    { key: "season_poster_source_order", label: t("settings.scrape.seasonPoster"), first: "fanart", why: t("settings.scrape.fanartFirst") },
  ] as const;
}

/** 来源卡的人话摘要：「TMDB + Fanart.tv · 片名 Logo、季海报优先 Fanart」/「仅 TMDB」 */
function describeSources(setting: ScrapeSetting, locale?: AppLocale): string {
  const t = appTranslator(locale);
  if (!setting.fanart_enabled) return t("settings.scrape.tmdbOnly");
  const fanartFirst = sourceRows(t).filter((row) => setting[row.key][0] === "fanart").map(
    (row) => row.label,
  );
  const lead = fanartFirst.length
    ? fanartFirst.length === sourceRows(t).length
      ? t("settings.scrape.allFanartFirst")
      : t("settings.scrape.fanartPreferred", { images: formatList(fanartFirst, locale) })
    : t("settings.scrape.allTmdbFirst");
  return `TMDB + Fanart.tv · ${lead}`;
}

/** 估算字节数 → 「约 2.6 GB」；不足 1 GB 用 MB（取整），量级参考不需要更多精度 */
function formatEstimate(bytes: number): string {
  const t = appTranslator();
  const gb = bytes / 1024 ** 3;
  if (gb >= 10) return t("settings.scrape.estimateGb", { amount: Math.round(gb) });
  if (gb >= 1) return t("settings.scrape.estimateDecimalGb", { amount: gb });
  return t("settings.scrape.estimateMb", { amount: Math.max(1, Math.round(bytes / 1024 ** 2)) });
}

/** 画质档的人话摘要（折叠头用）：预设只说名字，自定义把四个档位列出来 */
function describeImageQuality(setting: ScrapeSetting, locale?: AppLocale): string {
  const t = appTranslator(locale);
  const option = imageQualityOptions(t).find((o) => o.id === setting.image_quality);
  if (!option) return t("settings.scrape.inheritSizes");
  if (option.id !== "custom") return option.id === "original" ? t("settings.scrape.originalSummary") : option.title;
  const sizes = imageSizeFields(t).map(
    (field) => `${field.label} ${setting[field.key] || t("settings.scrape.inherit")}`,
  ).join(" / ");
  return t("settings.scrape.customSummary", { sizes });
}

/* ------------------------------------------------------------------ */
/* 值的人话摘要（库设置页的折叠头与对照行用）                            */
/* ------------------------------------------------------------------ */

function labelOf(options: ChipOption[], id: string): string {
  return options.find((o) => o.id === id)?.name ?? id;
}

function joinPriority(options: ChipOption[], values: string[]): string {
  return values.map((v) => labelOf(options, v)).join(" → ");
}

/**
 * 一组字段的可读摘要。**不给原始值**：`ja-JP → zh-CN`、`language；ja → orig`
 * 这种是给开发者看的，折叠头上要露的是「日本語 → 中文（简体）」这类人话
 * ——这是个开源软件，非开发者也在用（见 CLAUDE.md 注释与日志约定）。
 *
 * 未知语种/地区（用户从「更多」面板选的长尾项）回落显示代码本身，不编造名字。
 */
export function describeScrapeValues(
  keys: (keyof ScrapeSetting)[],
  setting: ScrapeSetting,
  locale?: AppLocale,
): string {
  const t = appTranslator(locale);
  const parts: string[] = [];
  for (const key of keys) {
    switch (key) {
      case "language_priority":
        parts.push(joinPriority(commonMetaLangs(t), setting.language_priority));
        break;
      case "cert_country_priority":
        parts.push(joinPriority(commonCertCountries(t), setting.cert_country_priority));
        break;
      case "poster_mode":
        // 海报卡把「模式 + 语言优先级」并成一句：默认模式下语言优先级不生效，
        // 摘要里再列它只会误导——启用 Fanart 时例外：TMDB 默认的那张要和 Fanart
        // 的海报按语言优先级比，这时语言优先级是生效的
        parts.push(
          setting.poster_mode === "default"
            ? setting.fanart_enabled
              ? t("settings.scrape.defaultFanartComparison", { languages: joinPriority(commonImageLangs(t), setting.poster_language_priority) })
              : t("settings.scrape.tmdbDefault")
            : t("settings.scrape.languageSummary", { languages: joinPriority(commonImageLangs(t), setting.poster_language_priority) }),
        );
        break;
      case "fanart_enabled":
        parts.push(describeSources(setting, locale));
        break;
      case "poster_source_order":
      case "backdrop_source_order":
      case "logo_source_order":
      case "season_poster_source_order":
        // 并进 fanart_enabled 那一句（来源卡的四行顺序不逐条列）
        if (!keys.includes("fanart_enabled")) {
          parts.push(setting[key].map((source) => SOURCE_LABEL[source]).join(" → "));
        }
        break;
      case "logo_language_priority":
        parts.push(joinPriority(commonImageLangs(t), setting.logo_language_priority));
        break;
      case "poster_language_priority":
        if (!keys.includes("poster_mode")) {
          parts.push(joinPriority(commonImageLangs(t), setting.poster_language_priority));
        }
        break;
      case "backdrop_language_priority":
        parts.push(joinPriority(commonImageLangs(t), setting.backdrop_language_priority));
        break;
      case "poster_min_width":
        parts.push(
          setting.poster_min_width > 0 ? t("settings.scrape.posterWidth", { width: setting.poster_min_width }) : t("settings.scrape.posterUnlimited"),
        );
        break;
      case "backdrop_min_width":
        parts.push(
          setting.backdrop_min_width > 0 ? t("settings.scrape.backdropWidth", { width: setting.backdrop_min_width }) : t("settings.scrape.backdropUnlimited"),
        );
        break;
      case "image_quality":
        parts.push(describeImageQuality(setting, locale));
        break;
      case "poster_size":
      case "backdrop_size":
      case "still_size":
      case "profile_size": {
        // 和画质一起出现时由画质那一句表达（自定义会列出四个档位）；单独出现时
        // 三个档位并成一句「档位 …」，空串统一说成"跟随环境"
        if (key !== "poster_size" || keys.includes("image_quality")) break;
        const sizes = [setting.poster_size, setting.backdrop_size, setting.still_size];
        parts.push(sizes.every((v) => !v) ? t("settings.scrape.environmentSizes") : t("settings.scrape.sizesSummary", { sizes: sizes.map((v) => v || t("settings.scrape.environment")).join("/") }));
        break;
      }
      case "naming_entry_dir": {
        // 四个模板并成一句：逐个列模板串太长，只说"哪几项不是默认"
        const changed = namingFields(t).filter((f) => setting[f.key].trim());
        parts.push(
          changed.length === 0
            ? t("settings.scrape.allDefaultTemplates")
            : t("settings.scrape.changedTemplates", { fields: formatList(changed.map((f) => f.label), locale) }),
        );
        break;
      }
      case "naming_movie_file":
      case "naming_season_dir":
      case "naming_episode_file":
        break; // 已在 naming_entry_dir 一并表达
      case "mirror_images": {
        const off = mirrorRows(t).filter((r) => !setting[r.key]);
        parts.push(off.length === 0 ? t("settings.scrape.allMirrorsEnabled") : t("settings.scrape.disabledMirrors", { fields: formatList(off.map((r) => r.label), locale) }));
        break;
      }
      case "mirror_nfo":
      case "mirror_episode_thumbs":
        break; // 已在 mirror_images 一并表达
      default:
        break;
    }
  }
  return parts.filter(Boolean).join(" · ");
}

/* ------------------------------------------------------------------ */
/* 排序芯片                                                            */
/* ------------------------------------------------------------------ */

function OrderChips({
  options,
  extraOptions,
  moreLabel,
  value,
  max,
  primaryTag,
  onChange,
}: {
  /** 行内常用项（顺序即展示顺序）。 */
  options: ChipOption[];
  /** 「更多」搜索面板里的完整候选（可为空 = 无更多面板）。 */
  extraOptions: ChipOption[];
  moreLabel: string;
  value: string[];
  max: number;
  /** 首位角色标签（"主语言" / "首选"），空串则只显示编号。 */
  primaryTag: string;
  onChange: (next: string[]) => void;
}) {
  const t = useTranslations();
  const [moreOpen, setMoreOpen] = useState(false);
  const [query, setQuery] = useState("");

  // 已选中的非常用项也要出现在行内（否则保存过的长尾语种打开页面就"消失"了）
  const inline = useMemo(() => {
    const known = new Set(options.map((o) => o.id));
    const extras = value
      .filter((id) => !known.has(id))
      .map((id) => extraOptions.find((o) => o.id === id) ?? { id, name: id });
    return [...options, ...extras];
  }, [options, extraOptions, value]);

  const toggle = useCallback(
    (id: string) => {
      const index = value.indexOf(id);
      if (index >= 0) {
        if (value.length <= 1) return; // 至少保留一项
        onChange(value.filter((v) => v !== id));
      } else {
        if (value.length >= max) return;
        onChange([...value, id]);
      }
    },
    [value, max, onChange],
  );

  const filteredExtra = useMemo(() => {
    const inlineIds = new Set(inline.map((o) => o.id));
    const q = query.trim().toLowerCase();
    return extraOptions
      .filter((o) => !inlineIds.has(o.id))
      .filter((o) => !q || o.name.toLowerCase().includes(q) || o.id.toLowerCase().includes(q))
      .slice(0, 60);
  }, [extraOptions, inline, query]);

  return (
    <div>
      <div className="flex flex-wrap gap-2">
        {inline.map((option) => {
          const index = value.indexOf(option.id);
          const selected = index >= 0;
          const disabled = !selected && value.length >= max;
          return (
            <button
              key={option.id}
              type="button"
              title={option.tip}
              aria-pressed={selected}
              disabled={disabled}
              onClick={() => toggle(option.id)}
              className={`flex items-center gap-1.5 rounded-full border py-1.5 pl-1.5 pr-3 text-sub font-medium transition-colors ${
                selected
                  ? "border-[var(--accent-2)] bg-[var(--accent-soft)] text-[var(--text)]"
                  : "border-white/[0.08] bg-white/[0.04] text-[var(--text-muted)] hover:bg-white/[0.07]"
              } ${disabled ? "pointer-events-none opacity-35" : ""}`}
            >
              <span
                className={`flex size-4.5 items-center justify-center rounded-full text-micro font-bold ${
                  selected
                    ? "bg-[var(--accent)] text-[#12141c]"
                    : "bg-white/10 text-[var(--text-faint)]"
                }`}
              >
                {selected ? "✓" : "+"}
              </span>
              {option.name}
            </button>
          );
        })}
        {extraOptions.length > 0 && (
          <button
            type="button"
            onClick={() => setMoreOpen((open) => !open)}
            className="flex items-center gap-1.5 rounded-full border border-dashed border-white/[0.15] bg-white/[0.02] py-1.5 pl-1.5 pr-3 text-sub text-[var(--text-faint)] transition-colors hover:text-[var(--text)]"
          >
            <span className="flex size-4.5 items-center justify-center rounded-full bg-white/10 text-micro">
              …
            </span>
            {t("settings.scrape.moreOptions", { label: moreLabel })}
          </button>
        )}
      </div>
      {moreOpen && (
        <div className="mt-2.5 rounded-xl border border-white/[0.12] bg-white/[0.04] p-3">
          <input
            className={`${SETTINGS_INPUT_CLASS} mb-2.5 w-full`}
            placeholder={t("settings.scrape.searchOptions", { label: moreLabel })}
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
          <div className="flex max-h-44 flex-wrap content-start gap-1.5 overflow-y-auto">
            {filteredExtra.length === 0 ? (
              <span className="px-1 text-caption text-[var(--text-faint)]">
                {t("settings.scrape.noMatchingOptions", { label: moreLabel })}
              </span>
            ) : (
              filteredExtra.map((option) => (
                <button
                  key={option.id}
                  type="button"
                  onClick={() => {
                    toggle(option.id);
                    setMoreOpen(false);
                    setQuery("");
                  }}
                  className="rounded-full border border-white/[0.08] bg-white/[0.04] px-3 py-1 text-sub text-[var(--text-muted)] transition-colors hover:bg-white/[0.07] hover:text-[var(--text)]"
                >
                  {option.name}
                  <span className="ml-1.5 font-mono text-micro text-[var(--text-faint)]">
                    {option.id}
                  </span>
                </button>
              ))
            )}
          </div>
        </div>
      )}
      {/* 已选序列条：候选区只管"加"，顺序与删除都在这里。
          没有它的话，想把第 2 位提到第 1 位得"先移除再重加"——两步且不直观，
          是这套芯片交互里唯一真正笨拙的地方。 */}
      {value.length > 0 ? (
        <div className="mt-2.5 flex flex-wrap items-center gap-1.5">
          {value.map((id, i) => {
            const name = inline.find((o) => o.id === id)?.name ?? id;
            return (
              <span
                key={id}
                className="flex items-center gap-1 rounded-full border border-[var(--accent-2)]/40 bg-[var(--accent-soft)] py-1 pl-2.5 pr-1 text-sub"
              >
                {i === 0 && primaryTag && (
                  <span className="text-micro text-[var(--accent)]">{primaryTag}</span>
                )}
                <span className="text-[var(--text)]">{name}</span>
                <button
                  type="button"
                  disabled={i === 0}
                  aria-label={t("settings.scrape.moveUp", { name })}
                  onClick={() => {
                    const next = [...value];
                    [next[i - 1], next[i]] = [next[i], next[i - 1]];
                    onChange(next);
                  }}
                  className="flex size-5 items-center justify-center rounded-full text-caption text-[var(--text-muted)] transition-colors hover:bg-white/10 hover:text-[var(--text)] disabled:pointer-events-none disabled:opacity-25"
                >
                  ↑
                </button>
                <button
                  type="button"
                  disabled={value.length <= 1}
                  aria-label={t("settings.scrape.removeOption", { name })}
                  onClick={() => onChange(value.filter((v) => v !== id))}
                  className="flex size-5 items-center justify-center rounded-full text-caption text-[var(--text-muted)] transition-colors hover:bg-white/10 hover:text-[var(--text)] disabled:pointer-events-none disabled:opacity-25"
                >
                  ✕
                </button>
              </span>
            );
          })}
          <span className="text-caption text-[var(--text-faint)]">
            {t("settings.scrape.priorityHint", { max })}
          </span>
        </div>
      ) : (
        <p className="mt-2 text-caption text-[var(--text-faint)]">
          {t("settings.scrape.addAndReorder")}
        </p>
      )}
    </div>
  );
}

/* ------------------------------------------------------------------ */
/* 分区主体                                                            */
/* ------------------------------------------------------------------ */

/**
 * 卡片级的「跟随全局 ⇄ 自定义」三态壳（只在库设置页出现，全局设置页不传）。
 *
 * 为什么是**卡片级**而不是整组一个开关：一个 tab 里的几张卡片管的是互相独立的
 * 设置（元数据 tab 里语言与分级各管各的），整组一个开关会让"只覆盖了语言"的库
 * 把分级也显示成已自定义——用户看到的状态是错的。而卡片内部则相反：排序芯片是
 * 有序列表，逐项三态没有意义，只能整张卡一起跟随或一起自定义。
 */
export interface CardFollowState {
  custom: boolean;
  /** 全局当前值的可读摘要，做对照 */
  globalSummary: string;
  onToggle: (custom: boolean) => void;
}

function CardFollowSwitch({ follow }: { follow: CardFollowState }) {
  const t = useTranslations();
  return (
    <div className="mb-4 flex flex-wrap items-center justify-between gap-3 rounded-xl border border-white/[0.08] bg-white/[0.03] px-3.5 py-2.5">
      <span className="min-w-0 text-caption text-[var(--text-faint)]">
        {t("settings.scrape.globalSummary", { summary: follow.globalSummary })}
      </span>
      <div className="flex shrink-0 gap-1">
        {(
          [
            [false, t("settings.scrape.followGlobal")],
            [true, t("settings.scrape.custom")],
          ] as const
        ).map(([option, label]) => (
          <button
            key={label}
            type="button"
            onClick={() => follow.onToggle(option)}
            className={`rounded-lg px-2.5 py-1 text-caption transition-colors ${
              follow.custom === option
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
}

/**
 * 库设置页给每张卡片套的壳：折叠 + 三态（设计文档 §14.5）。
 *
 * 为什么库设置页是**手风琴**而这里（全局设置页）是 tab：库设置里绝大多数卡片
 * 停在"跟随全局"，用户只想改一两项——手风琴把全部卡片的状态摊在一屏（tab 得
 * 逐个点开才知道自己改过什么），且没有横向空间压力（中文标签「命名与整理」
 * 「目录写入」在 390px 的 tab 条里必然换行）。全局设置页正相反：宽度充足、
 * 每张卡都要编辑，没有可省的静默态，折叠只是白多一次点击。
 * 两处共用的是卡片**内部**的控件，外层容器各按各的空间与动线选。
 */
export interface CardShell {
  open: boolean;
  onToggleOpen: () => void;
  /** 折叠头右侧的一行状态：「跟随全局：zh-CN → en-US」/「自定义：日本語 → …」 */
  status: string;
  /** 状态是否为"已改过"（点亮折叠头的小圆点与文字颜色） */
  customized: boolean;
  /** 卡片级三态开关；命名/目录写入走字段级三态，不传 */
  follow?: CardFollowState;
  /** 折叠头右侧的一句即时反馈（全局页自动保存的「保存中… / 已保存」） */
  note?: string;
}

export function Card({
  title,
  overriddenBy,
  follow,
  shell,
  desc,
  children,
}: {
  title: string;
  /** 覆盖了本卡片字段的媒体库名。分层配置最经典的坑是"在全局改了半天不生效"，
   *  不把这个标出来用户无从自查（设计文档 §14.5）。
   *  注意这里**没有**「可按库覆盖」徽标：P4 之后所有字段都可按库覆盖，
   *  逐卡再标一遍就不区分任何东西了，改到分区顶部统一说一句。 */
  overriddenBy?: string[];
  /** 库设置页的卡片级三态；与 shell 二选一（shell 里带着它） */
  follow?: CardFollowState;
  /** 库设置页的折叠壳；全局设置页不传 */
  shell?: CardShell;
  desc: string;
  children: React.ReactNode;
}) {
  const t = useTranslations();
  const effectiveFollow = shell?.follow ?? follow;
  const body = (
    <>
      <p className="mb-4 max-w-[62ch] text-sub leading-5 text-[var(--text-muted)]">{desc}</p>
      {effectiveFollow && <CardFollowSwitch follow={effectiveFollow} />}
      {/* 跟随全局时控件只读：看得见全局值长什么样，但改不动。
          用 `inert` 而不是 `pointer-events-none`——后者只挡鼠标，键盘照样能
          Tab 进去把值改掉（改动会静默写进库覆盖），那是功能缺陷不是观感问题。 */}
      <div
        inert={effectiveFollow ? !effectiveFollow.custom : undefined}
        className={effectiveFollow && !effectiveFollow.custom ? "opacity-45" : ""}
      >
        {children}
      </div>
    </>
  );

  if (shell) {
    return (
      <CollapsibleCard shell={shell} title={title} overriddenBy={overriddenBy}>
        {body}
      </CollapsibleCard>
    );
  }

  return (
    <section className="rounded-2xl border border-white/[0.08] bg-white/[0.04] p-5">
      <div className="flex flex-wrap items-center gap-2.5">
        <h3 className="text-title-sm font-semibold">{title}</h3>
        {overriddenBy && overriddenBy.length > 0 && (
          <span
            title={t("settings.scrape.overrideLibrariesHint", { libraries: formatList(overriddenBy) })}
            className="rounded-full bg-[var(--accent-soft)] px-2 py-px text-micro text-[var(--accent)]"
          >
            {t("settings.scrape.overrideLibrariesCount", { count: overriddenBy.length })}
          </span>
        )}
      </div>
      {body}
    </section>
  );
}

/**
 * 折叠卡片。两处细节值得说明：
 *
 * - **高度过渡用 grid `0fr → 1fr`**，不是 max-height 猜一个够大的值——猜小了
 *   长卡片（命名模板带实时预览）会被截断，猜大了短卡片的动画速度不对；
 * - 内容**常驻挂载**（动画需要），所以收起时必须 `inert`，否则键盘能 Tab
 *   进看不见的表单里。
 *
 * 展开后把卡片滚进视口：手风琴的经典毛病是点开靠底部的卡片，内容展开在视口
 * 下方看不见。等过渡结束再滚（`block: nearest` 只做最小移动，不抢镜）。
 */
function CollapsibleCard({
  shell,
  title,
  overriddenBy,
  children,
}: {
  shell: CardShell;
  title: string;
  overriddenBy?: string[];
  children: React.ReactNode;
}) {
  const t = useTranslations();
  const ref = useRef<HTMLElement | null>(null);
  const wasOpen = useRef(shell.open);

  useEffect(() => {
    if (shell.open && !wasOpen.current) {
      const timer = window.setTimeout(
        () => ref.current?.scrollIntoView({ block: "nearest", behavior: "smooth" }),
        220,
      );
      wasOpen.current = true;
      return () => window.clearTimeout(timer);
    }
    wasOpen.current = shell.open;
  }, [shell.open]);

  return (
    <section ref={ref}>
      <button
        type="button"
        aria-expanded={shell.open}
        onClick={shell.onToggleOpen}
        className="flex min-h-[56px] w-full items-center gap-4 px-4 py-3 text-left transition-colors hover:bg-white/[0.03]"
      >
        <span className="min-w-0 flex-1">
          <span className="flex flex-wrap items-center gap-x-2 gap-y-1 text-body font-medium text-[var(--text)]">
            {title}
            {shell.customized && (
              <span className="size-1.5 shrink-0 rounded-full bg-[var(--accent)]" aria-hidden />
            )}
            {/* 收起时也要看得见"这项被几个库改了"——它正是"在全局改了不生效"
                的答案，藏在展开态里等于没有 */}
            {overriddenBy && overriddenBy.length > 0 && (
              <span
                title={t("settings.scrape.overrideLibrariesHint", { libraries: formatList(overriddenBy) })}
                className="rounded-full bg-[var(--accent-soft)] px-2 py-px text-micro font-normal text-[var(--accent)]"
              >
                {t("settings.scrape.overrideLibrariesCount", { count: overriddenBy.length })}
              </span>
            )}
          </span>
          {/* 状态常显：不点开也知道这张卡是跟着全局还是本库自己配过 */}
          <span
            className={`mt-0.5 block truncate text-caption ${
              shell.customized ? "text-[var(--accent)]" : "text-[var(--text-faint)]"
            }`}
          >
            {shell.status}
          </span>
        </span>
        {shell.note && (
          <span className="shrink-0 text-caption text-[var(--text-faint)]">{shell.note}</span>
        )}
        <ChevronDownIcon
          className={`size-4 shrink-0 text-[var(--text-faint)] transition-transform ${
            shell.open ? "rotate-180" : ""
          }`}
        />
      </button>
      <div
        className={`grid transition-[grid-template-rows] duration-200 ease-out ${
          shell.open ? "grid-rows-[1fr]" : "grid-rows-[0fr]"
        }`}
      >
        <div className="overflow-hidden" inert={!shell.open}>
          <div className="px-4 pb-4">{children}</div>
        </div>
      </div>
    </section>
  );
}

/* ------------------------------------------------------------------ */
/* 命名模板：实时预览                                                   */
/* ------------------------------------------------------------------ */

/**
 * 预览用的模板渲染器——**规则镜像自后端 services/library/naming.py**。
 * 权威实现在后端：保存时的校验与真实落盘的名字都由它决定，这里只为让用户
 * 边打字边看到结果。三步与后端一一对应：整组丢弃占位符全空的括号组 →
 * 替换占位符 → 收缩并清洗。改后端规则时**必须同步改这里**。
 */
const TOKEN_RE = /\{(\w+)(?::0(\d)d)?\}/g;
const BRACKET_GROUP_RE = /[([【][^()[\]【】]*[)\]】]/g;
const FORBIDDEN_RE = /[\\/:*?"<>|]/g;

function sanitizeSegment(value: string): string {
  return value
    .replace(FORBIDDEN_RE, " ")
    .replace(/\s+/g, " ")
    .replace(/^[\s.]+|[\s.]+$/g, "");
}

function tokenValue(ctx: Record<string, unknown>, name: string, pad?: string): string {
  const raw = ctx[name];
  if (raw === undefined || raw === null || raw === "") return "";
  let text = sanitizeSegment(String(raw));
  if (pad && /^\d+$/.test(text)) text = text.padStart(Number(pad), "0");
  return text;
}

/** 片名类占位符：同一模板里值相同的只保留第一次出现（「风筝 (风筝)」→「风筝」）。 */
const TITLE_TOKENS = ["title", "original_title", "english_title"];
/** 超长时可截短的自由文本占位符；编号、年份、规格不截。 */
const SHRINKABLE_TOKENS = [...TITLE_TOKENS, "episode_title", "season_name", "release_name"];
/** 单段名字字节上限与截短保底，与后端 MAX_SEGMENT_BYTES / _SHRINK_FLOOR_BYTES 一致。 */
const MAX_SEGMENT_BYTES = 200;
const SHRINK_FLOOR_BYTES = 30;
const utf8Length = (text: string) => new TextEncoder().encode(text).length;

/** 按 UTF-8 字节截断，不切坏多字节字符。 */
function cutBytes(text: string, limit: number): string {
  let out = "";
  let used = 0;
  for (const char of text) {
    used += utf8Length(char);
    if (used > limit) break;
    out += char;
  }
  return out;
}

function dedupeTitles(template: string, ctx: Record<string, unknown>): Record<string, unknown> {
  const next = { ...ctx };
  const seen = new Set<string>();
  for (const m of template.matchAll(TOKEN_RE)) {
    if (!TITLE_TOKENS.includes(m[1])) continue;
    const value = tokenValue(next, m[1], m[2]).toLowerCase();
    if (!value) continue;
    if (seen.has(value)) next[m[1]] = null;
    seen.add(value);
  }
  return next;
}

function renderTemplate(template: string, ctx: Record<string, unknown>): string {
  // 片名去重 → 渲染 → 超长时逐个截短最长的自由文本（与后端 render 同序）
  const context = dedupeTitles(template, ctx);
  let text = renderOnce(template, context);
  for (let i = 0; i < SHRINKABLE_TOKENS.length * 2; i++) {
    const over = utf8Length(text) - MAX_SEGMENT_BYTES;
    if (over <= 0) return text;
    const sizes = SHRINKABLE_TOKENS.map((n) => [n, utf8Length(tokenValue(context, n))] as const);
    const [name, size] = sizes.reduce((a, b) => (b[1] > a[1] ? b : a));
    if (size <= SHRINK_FLOOR_BYTES) break;
    const keep = Math.max(size - over, SHRINK_FLOOR_BYTES);
    context[name] = cutBytes(tokenValue(context, name), keep).replace(/^[ .-]+|[ .-]+$/g, "");
    text = renderOnce(template, context);
  }
  return sanitizeSegment(cutBytes(text, MAX_SEGMENT_BYTES)) || "未命名";
}

function renderOnce(template: string, ctx: Record<string, unknown>): string {
  // ① 占位符全空的括号组连同组内字面文本一起丢弃（收掉 "[tmdbid-]" 这种残留）
  const dropped = template.replace(BRACKET_GROUP_RE, (group) => {
    const tokens = [...group.matchAll(TOKEN_RE)];
    if (tokens.length === 0) return group;
    return tokens.every((m) => !tokenValue(ctx, m[1], m[2])) ? "" : group;
  });
  // ② 替换占位符
  const filled = dropped.replace(TOKEN_RE, (_m, name: string, pad?: string) =>
    tokenValue(ctx, name, pad),
  );
  // ③ 收缩：括号内侧 → 重复分隔符 → 多余空白 → 首尾分隔符
  const collapsed = filled
    .replace(/([([【])[\s\-–]+/g, "$1")
    .replace(/[\s\-–]+([)\]】])/g, "$1")
    .replace(/(?:\s*-\s*){2,}/g, " - ")
    .replace(/\s{2,}/g, " ")
    .replace(/^[\s\-–.]+|[\s\-–.]+$/g, "");
  return sanitizeSegment(collapsed) || "未命名";
}

/** 模板字段定义：可用占位符与后端 naming.ALLOWED_TOKENS 一一对应。 */
const COMMON_TOKENS = [
  "title",
  "original_title",
  "english_title",
  "year",
  "tmdb_id",
  "imdb_id",
  "douban_id",
];
const FILE_ATTR_TOKENS = [
  "resolution",
  "video_codec",
  "hdr",
  "bit_depth",
  "audio",
  "media_source",
  "release_group",
  "site",
  "release_name",
];

/** 占位符按类别分组展示，按钮上写中文名（悬停看占位符原文）。 */
function tokenGroups(t: ReturnType<typeof appTranslator>): { label: string; tokens: Record<string, string> }[] {

  return [
    {
      label: t("settings.scrape.titleTokens"),
      tokens: {
        title: t("settings.scrape.titleToken"),
        original_title: t("settings.scrape.originalTitle"),
        english_title: t("settings.scrape.englishTitle"),
        year: t("settings.scrape.year"),
        tmdb_id: "TMDB ID",
        imdb_id: "IMDb ID",
        douban_id: t("settings.scrape.doubanId"),
      },
    },
    {
      label: t("settings.scrape.episodeTokens"),
      tokens: { season: t("settings.scrape.seasonNumber"), season_name: t("settings.scrape.seasonName"), episode: t("settings.scrape.episodeNumber"), episode_title: t("settings.scrape.episodeTitle") },
    },
    {
      label: t("settings.scrape.fileTokens"),
      tokens: {
        resolution: t("settings.scrape.resolution"),
        video_codec: t("settings.scrape.videoCodec"),
        hdr: "HDR",
        bit_depth: t("settings.scrape.bitDepth"),
        audio: t("settings.scrape.audio"),
      },
    },
    {
      label: t("settings.scrape.source"),
      tokens: {
        media_source: t("settings.scrape.mediaSource"),
        release_group: t("settings.scrape.releaseGroup"),
        site: t("settings.scrape.site"),
        release_name: t("settings.scrape.releaseName"),
      },
    },
  ];
}

function namingFields(t: ReturnType<typeof appTranslator>) {
  return [
    {
      key: "naming_entry_dir" as const,
      label: t("settings.scrape.entryDirectory"),
      note: t("settings.scrape.sharedNamingHint"),
      fallback: "{title} ({year})",
      tokens: COMMON_TOKENS,
    },
    {
      key: "naming_movie_file" as const,
      label: t("settings.scrape.movieFilename"),
      note: "",
      fallback: "{title} ({year})",
      tokens: [...COMMON_TOKENS, ...FILE_ATTR_TOKENS],
    },
    {
      key: "naming_season_dir" as const,
      label: t("settings.scrape.seasonDirectory"),
      note: "",
      fallback: "Season {season:02d}",
      tokens: [...COMMON_TOKENS, "season", "season_name"],
    },
    {
      key: "naming_episode_file" as const,
      label: t("settings.scrape.episodeFilename"),
      note: "",
      fallback: "{title} ({year}) - S{season:02d}E{episode:02d}",
      tokens: [
        ...COMMON_TOKENS,
        ...FILE_ATTR_TOKENS,
        "season",
        "season_name",
        "episode",
        "episode_title",
      ],
    },
  ];
}

/** 预览样例：一部电影 + 一集剧集，字段齐全便于看清每个占位符的效果。 */
function sampleMovie(t: ReturnType<typeof appTranslator>) {
  return {
    title: t("settings.scrape.sampleMovieTitle"),
    original_title: "Dune: Part Two",
    english_title: "Dune: Part Two",
    year: 2024,
    tmdb_id: 693134,
    imdb_id: "tt15239678",
    douban_id: "35575567",
    resolution: "2160p",
    video_codec: "HEVC",
    hdr: "DV",
    bit_depth: "10bit",
    audio: "TrueHD Atmos 7.1",
    media_source: "BluRay",
    release_group: "FRDS",
    site: "hdsky",
    release_name: "Dune.Part.Two.2024.2160p.BluRay.DV.HEVC.TrueHD.7.1.Atmos-FRDS",
    };
}
function sampleEpisode(t: ReturnType<typeof appTranslator>) {
  return {
    title: t("settings.scrape.sampleTvTitle"),
    original_title: t("settings.scrape.sampleTvTitle"),
    english_title: "Kite",
    year: 2017,
    tmdb_id: 68035,
    imdb_id: "tt6952510",
    douban_id: "26340419",
    season: 1,
    season_name: t("settings.scrape.sampleSeason"),
    episode: 3,
    episode_title: t("settings.scrape.sampleEpisodeTitle"),
    resolution: "1080p",
    video_codec: "H.264",
    hdr: null, // SDR：{hdr} 渲染为空，演示收缩
    bit_depth: "8bit",
    audio: "AAC 2.0",
    media_source: "WEB-DL",
    release_group: "CHDWEB",
    site: "chdbits",
    release_name: "Kite.2017.S01E03.1080p.WEB-DL.H264.AAC-CHDWEB",
    };
}

type NamingValues = Pick<ScrapeSetting, ReturnType<typeof namingFields>[number]["key"]>;

/** 前端侧轻校验：与后端同口径，只为即时反馈；能否保存以后端返回为准。 */
function templateError(template: string, allowed: string[]): string | null {
  const t = appTranslator();
  if (!template.trim()) return null; // 空 = 用默认模板
  if (/[\\/]/.test(template)) return t("settings.scrape.noPathSeparators");
  const used = [...template.matchAll(TOKEN_RE)].map((m) => m[1]);
  const unknown = used.filter((t) => !allowed.includes(t));
  if (unknown.length) return t("settings.scrape.unknownTokens", { tokens: formatList(unknown.map((token) => `{${token}}`)) });
  return null;
}

function NamingTab({
  setting,
  patch,
  overriddenBy,
  shellFor,
}: {
  setting: ScrapeSetting;
  patch: (changes: Partial<ScrapeSetting>) => void;
  overriddenBy?: (keys: (keyof ScrapeSetting)[]) => string[];
  shellFor?: (title: string, keys: (keyof ScrapeSetting)[]) => CardShell;
}) {
  const t = useTranslations();
  const [focused, setFocused] = useState<string>("naming_episode_file");
  const refs = useRef<Record<string, HTMLInputElement | null>>({});
  // 模板是文本：边打字边存会把写到一半的模板落库，所以四个字段攒成草稿，
  // 页脚「保存」一起提交（其余卡片是离散控件，改完即存）
  // 只认这四个字段：别的卡片自动保存时 setting 会换新对象，不能因此冲掉草稿
  const { naming_entry_dir, naming_movie_file, naming_season_dir, naming_episode_file } = setting;
  const saved = useMemo<NamingValues>(
    () => ({ naming_entry_dir, naming_movie_file, naming_season_dir, naming_episode_file }),
    [naming_entry_dir, naming_movie_file, naming_season_dir, naming_episode_file],
  );
  const [draft, setDraft] = useState(saved);
  useEffect(() => setDraft(saved), [saved]);
  const dirty = namingFields(t).some((f) => draft[f.key] !== saved[f.key]);
  const edit = (changes: Partial<NamingValues>) => setDraft((current) => ({ ...current, ...changes }));

  const errors = namingFields(t).map((f) => templateError(draft[f.key], f.tokens));
  const valid = errors.every((e) => e === null);

  const tpl = (key: ReturnType<typeof namingFields>[number]["key"]) =>
    draft[key].trim() || namingFields(t).find((f) => f.key === key)!.fallback;

  const moviePath = valid
    ? `${renderTemplate(tpl("naming_entry_dir"), sampleMovie(t))}/${renderTemplate(
        tpl("naming_movie_file"),
        sampleMovie(t),
      )}.mkv`
    : "";
  const episodePath = valid
    ? `${renderTemplate(tpl("naming_entry_dir"), sampleEpisode(t))}/${renderTemplate(
        tpl("naming_season_dir"),
        sampleEpisode(t),
      )}/${renderTemplate(tpl("naming_episode_file"), sampleEpisode(t))}.mkv`
    : "";

  const insertToken = (token: string) => {
    const key = focused;
    const field = namingFields(t).find((f) => f.key === key);
    if (!field) return;
    const input = refs.current[key];
    const current = draft[field.key] || field.fallback;
    const start = input?.selectionStart ?? current.length;
    const end = input?.selectionEnd ?? start;
    const next = `${current.slice(0, start)}{${token}}${current.slice(end)}`;
    edit({ [field.key]: next });
    window.requestAnimationFrame(() => {
      const el = refs.current[key];
      if (!el) return;
      el.focus();
      const caret = start + token.length + 2;
      el.setSelectionRange(caret, caret);
    });
  };

  const focusedField = namingFields(t).find((f) => f.key === focused) ?? namingFields(t)[3];

  return (
    <Card
      title={t("settings.scrape.namingTemplates")}
      overriddenBy={overriddenBy?.(namingFields(t).map((f) => f.key))}
      shell={shellFor?.(
        t("settings.scrape.namingTemplates"),
        namingFields(t).map((f) => f.key),
      )}
      desc={t("settings.scrape.namingHint")}
    >
      {namingFields(t).map((field, i) => (
        <div key={field.key} className="mt-3.5 first:mt-0">
          <label
            htmlFor={field.key}
            className="mb-1.5 flex items-baseline gap-2 text-sub font-semibold"
          >
            {field.label}
            {field.note && (
              <small className="text-caption font-normal text-[var(--text-faint)]">
                {field.note}
              </small>
            )}
          </label>
          <input
            id={field.key}
            ref={(el) => {
              refs.current[field.key] = el;
            }}
            spellCheck={false}
            placeholder={field.fallback}
            value={draft[field.key]}
            onFocus={() => setFocused(field.key)}
            onChange={(e) => edit({ [field.key]: e.target.value })}
            className={`${SETTINGS_INPUT_CLASS} w-full font-mono ${
              errors[i] ? "border-[var(--danger)]/55" : ""
            }`}
          />
          {errors[i] && <p className="mt-1.5 text-caption text-[var(--danger)]">{errors[i]}</p>}
        </div>
      ))}

      <div className="mt-4">
        <p className="mb-1.5 text-micro uppercase tracking-widest text-[var(--text-faint)]">
          {t("settings.scrape.insertTokenHint", { field: focusedField.label })}
        </p>
        <div className="flex flex-col gap-2">
          {tokenGroups(t).map((group) => {
            const tokens = Object.keys(group.tokens).filter((t) => focusedField.tokens.includes(t));
            if (tokens.length === 0) return null;
            return (
              <div key={group.label} className="flex flex-wrap items-center gap-1.5">
                <span className="w-16 shrink-0 text-caption text-[var(--text-faint)]">
                  {group.label}
                </span>
                {tokens.map((token) => (
                  <button
                    key={token}
                    type="button"
                    title={`{${token}}`}
                    onMouseDown={(e) => e.preventDefault()}
                    onClick={() => insertToken(token)}
                    className="rounded-lg border border-white/[0.08] bg-white/[0.04] px-2 py-1 text-caption text-[var(--accent-2)] transition-colors hover:bg-white/[0.07] hover:text-[var(--accent)]"
                  >
                    {group.tokens[token]}
                  </button>
                ))}
              </div>
            );
          })}
        </div>
        {focusedField.tokens.includes("site") && (
          <p className="mt-2 text-caption text-[var(--text-faint)]">
            {t("settings.scrape.importTokensHint")}
          </p>
        )}
      </div>

      <div className="mt-4 overflow-hidden rounded-xl border border-white/[0.08]">
        <div className="flex items-center justify-between bg-white/[0.04] px-3.5 py-2">
          <span className="text-micro uppercase tracking-widest text-[var(--text-faint)]">
            {t("settings.scrape.livePreview")}
          </span>
          <span className={`text-caption ${valid ? "text-[var(--ok)]" : "text-[var(--danger)]"}`}>
            {valid ? t("settings.scrape.templateValid") : t("settings.scrape.templateInvalid")}
          </span>
        </div>
        {valid && (
          <div className="flex flex-col gap-3 overflow-x-auto px-3.5 py-3">
            <div>
              <p className="mb-1 text-caption text-[var(--text-faint)]">
                {t("settings.scrape.movieExample")}
              </p>
              <p className="whitespace-nowrap font-mono text-sub leading-relaxed">
                <span className="text-[var(--text-faint)]">{t("settings.scrape.movieExampleRoot")}</span>
                <span className="text-[var(--accent)]">{moviePath}</span>
              </p>
            </div>
            <div>
              <p className="mb-1 text-caption text-[var(--text-faint)]">
                {t("settings.scrape.episodeExample")}
              </p>
              <p className="whitespace-nowrap font-mono text-sub leading-relaxed">
                <span className="text-[var(--text-faint)]">{t("settings.scrape.episodeExampleRoot")}</span>
                <span className="text-[var(--accent)]">{episodePath}</span>
              </p>
            </div>
          </div>
        )}
      </div>

      <p className="mt-3 text-caption text-[var(--text-faint)]">
        {t("settings.scrape.versionSuffixHint")}
      </p>

      {/* 卡片页脚：左边恢复默认（只改草稿），右边唯一的提交按钮 */}
      <div className="-mx-4 -mb-4 mt-5 flex min-h-[52px] items-center justify-between gap-3 border-t border-[var(--line)] bg-black/20 px-4 py-2.5">
        <button
          type="button"
          onClick={() =>
            edit({
              naming_entry_dir: "",
              naming_movie_file: "",
              naming_season_dir: "",
              naming_episode_file: "",
            })
          }
          className={SETTINGS_BUTTON_CLASS}
        >
          {t("settings.scrape.resetTemplates")}
        </button>
        <div className="flex items-center gap-2">
          {dirty && (
            <button type="button" onClick={() => setDraft(saved)} className={SETTINGS_BUTTON_CLASS}>
              {t("settings.scrape.discardChanges")}
            </button>
          )}
          <button
            type="button"
            disabled={!dirty || !valid}
            onClick={() => patch(draft)}
            className={SETTINGS_PRIMARY_BUTTON_CLASS}
          >
            {t("settings.scrape.save")}
          </button>
        </div>
      </div>
    </Card>
  );
}

/* ------------------------------------------------------------------ */
/* 目录写入                                                            */
/* ------------------------------------------------------------------ */

function mirrorRows(t: ReturnType<typeof appTranslator>) {
  return [
    {
      key: "mirror_images" as const,
      label: t("settings.scrape.entryImages"),
      hint: t("settings.scrape.entryImagesHint"),
    },
    {
      key: "mirror_nfo" as const,
      label: t("settings.scrape.nfoMetadata"),
      hint: t("settings.scrape.nfoHint"),
    },
    {
      key: "mirror_episode_thumbs" as const,
      label: t("settings.scrape.episodeStills"),
      hint: t("settings.scrape.episodeStillsHint"),
    },
  ];
}

/** 三个开关直接是行组里的三行：开关不需要折叠，改完即存 */
function MirrorTab({
  setting,
  patch,
}: {
  setting: ScrapeSetting;
  patch: (changes: Partial<ScrapeSetting>) => void;
}) {
  const t = useTranslations();
  return (
    <>
      {mirrorRows(t).map((row) => (
        <SettingsRow key={row.key} label={row.label} description={row.hint}>
          <Toggle
            checked={setting[row.key]}
            label={row.label}
            onChange={(next) => patch({ [row.key]: next } as Partial<ScrapeSetting>)}
          />
        </SettingsRow>
      ))}
    </>
  );
}

/* ------------------------------------------------------------------ */
/* 可复用字段组：全局设置页与「编辑库 → 刮削设置」共用同一套控件          */
/* ------------------------------------------------------------------ */

/**
 * 拉取语种/地区全量表并派生「更多」面板的候选。
 *
 * 全局页与库页各自调用一次即可——两处渲染的是同一批芯片，控件不同源
 * 会随时间漂移成两套交互（设计文档 §14.5：用户学一次就够）。
 */
/** 小节标题 + 一个行组：每张折叠卡是组里的一行。全局页与库设置页共用。 */
export function ScrapeSection({
  label,
  description,
  children,
}: {
  label: string;
  description?: React.ReactNode;
  children: React.ReactNode;
}) {
  return (
    <SettingsSection title={label} description={description}>
      <div className="overflow-hidden rounded-xl">
        <SettingsList>{children}</SettingsList>
      </div>
    </SettingsSection>
  );
}

export function useScrapeChipOptions() {
  const t = useTranslations();
  const locale = useLocale();
  const [languages, setLanguages] = useState<LanguageOption[]>([]);
  const [countries, setCountries] = useState<CountryOption[]>([]);

  useEffect(() => {
    // 全量表拉不到不阻断（面板回落只显示常用项）
    listLanguageOptions()
      .then(setLanguages)
      .catch(() => {});
  }, []);

  useEffect(() => {
    let cancelled = false;
    setCountries([]);
    listCountryOptions(locale)
      .then((options) => { if (!cancelled) setCountries(options); })
      .catch(() => {});
    return () => { cancelled = true; };
  }, [locale]);

  const metaLangs = useMemo<ChipOption[]>(
    () =>
      languages
        .filter((l) => !commonMetaLangs(t).some((c) => c.id.startsWith(`${l.code}-`)))
        .map((l) => ({ id: l.code, name: (locale === "en" ? l.english_name : l.name) || l.english_name || l.code })),
    [languages, locale, t],
  );
  const imageLangs = useMemo<ChipOption[]>(
    () =>
      languages
        .filter((l) => !commonImageLangs(t).some((c) => c.id === l.code))
        .map((l) => ({ id: l.code, name: (locale === "en" ? l.english_name : l.name) || l.english_name || l.code })),
    [languages, locale, t],
  );
  const certCountries = useMemo<ChipOption[]>(
    () =>
      countries
        .filter((c) => !commonCertCountries(t).some((k) => k.id === c.code))
        .map((c) => ({ id: c.code, name: c.name })),
    [countries, t],
  );

  return { metaLangs, imageLangs, certCountries };
}

export function MetaTab({
  setting,
  patch,
  extraMetaLangs,
  extraCountries,
  overriddenBy,
  shellFor,
}: {
  setting: ScrapeSetting;
  patch: (changes: Partial<ScrapeSetting>) => void;
  extraMetaLangs: ChipOption[];
  extraCountries: ChipOption[];
  /** 查"哪些库覆盖了这些字段"；库设置页不传（那里本来就在配某一个库） */
  overriddenBy?: (keys: (keyof ScrapeSetting)[]) => string[];
  /** 库设置页的卡片壳（折叠 + 三态）工厂；全局设置页不传 */
  shellFor?: (title: string, keys: (keyof ScrapeSetting)[]) => CardShell;
}) {
  const t = useTranslations();
  return (
    <>
      <Card
        title={t("settings.scrape.metadataLanguage")}
        overriddenBy={overriddenBy?.(["language_priority"])}
        shell={shellFor?.(t("settings.scrape.metadataLanguage"), ["language_priority"])}
        desc={t("settings.scrape.metadataLanguageHint")}
      >
        <OrderChips
          options={commonMetaLangs(t)}
          extraOptions={extraMetaLangs}
          moreLabel={t("settings.scrape.languageOptions")}
          value={setting.language_priority}
          max={3}
          primaryTag={t("settings.scrape.primaryLanguage")}
          onChange={(next) => patch({ language_priority: next })}
        />
      </Card>
      <Card
        title={t("settings.scrape.contentRating")}
        overriddenBy={overriddenBy?.(["cert_country_priority"])}
        shell={shellFor?.(t("settings.scrape.contentRating"), ["cert_country_priority"])}
        desc={t("settings.scrape.contentRatingHint")}
      >
        <OrderChips
          options={commonCertCountries(t)}
          extraOptions={extraCountries}
          moreLabel={t("settings.scrape.regionOptions")}
          value={setting.cert_country_priority}
          max={6}
          primaryTag=""
          onChange={(next) => patch({ cert_country_priority: next })}
        />
      </Card>
    </>
  );
}

/**
 * 「图片来源」卡（docs/design/image-sources.md）：TMDB 始终开启，Fanart.tv 可选。
 *
 * - **Fanart 开关**：Key 没配过时，点开关不会直接打开，而是就地展开 Key 表单
 *   （FanartKeyForm），验证通过才打开——不内置 Key、不单开配置页；
 * - **来源顺序**按图片类型分开排（⇄ 交换先后），只在同一档语言两边都有图时
 *   起作用：规则写死成「先看语言，再看来源」，不给用户选；
 * - 打开后在卡片里提示「已入库的条目需要手动刷新元数据」，不自动重刮。
 *
 * 全局页与库设置页共用；库设置页里 Key 一行改成「全站共用」的说明（凭据不跟库走）。
 */
function ImageSourcesCard({
  setting,
  patch,
  library,
  overriddenBy,
  shellFor,
}: {
  setting: ScrapeSetting;
  patch: (changes: Partial<ScrapeSetting>) => void;
  library: boolean;
  overriddenBy?: (keys: (keyof ScrapeSetting)[]) => string[];
  shellFor?: (title: string, keys: (keyof ScrapeSetting)[]) => CardShell;
}) {
  const t = useTranslations();
  const { status, setStatus } = useFanartStatus();
  const [keyForm, setKeyForm] = useState(false);
  // 刚打开 Fanart：卡片里提示存量条目要手动刷新（关掉、或关闭提示即消失）
  const [justEnabled, setJustEnabled] = useState(false);
  const enabled = setting.fanart_enabled;
  const usable = fanartUsable(status);

  const toggle = () => {
    if (enabled) {
      patch({ fanart_enabled: false });
      setJustEnabled(false);
    } else if (usable) {
      patch({ fanart_enabled: true });
      setJustEnabled(true);
    } else {
      // 没有可用的 Key：开关保持关，先就地填一次
      setKeyForm((current) => !current);
    }
  };

  const pill = !status?.configured ? (
    <span className="rounded-full border border-[var(--warn)]/30 px-2 py-px text-micro font-normal text-[var(--warn)]">
      {t("settings.scrape.keyRequired")}
    </span>
  ) : status.key_invalid ? (
    <span className="rounded-full border border-[var(--danger)]/35 px-2 py-px text-micro font-normal text-[var(--danger)]">
      {t("settings.scrape.keyInvalid")}
    </span>
  ) : (
    <span className="rounded-full border border-[var(--ok)]/30 px-2 py-px text-micro font-normal text-[var(--ok)]">
      {t("settings.scrape.keyConfigured")}
    </span>
  );

  return (
    <Card
      title={t("settings.scrape.imageSources")}
      overriddenBy={overriddenBy?.(SOURCE_KEYS)}
      shell={shellFor?.(t("settings.scrape.imageSources"), SOURCE_KEYS)}
      desc={t("settings.scrape.imageSourcesHint")}
    >
      {justEnabled && enabled && (
        <div className="mb-2.5 flex items-start gap-2.5 rounded-xl border border-[var(--info)]/30 bg-[var(--info)]/[0.07] px-3 py-2.5 text-caption leading-relaxed text-[var(--text-muted)]">
          <span className="text-[var(--info)]">ℹ︎</span>
          <span className="min-w-0 flex-1">
            {t.rich("settings.scrape.fanartEnabledHint", { strong: (chunks) => <strong className="font-semibold text-[var(--text)]">{chunks}</strong> })}
          </span>
          <button
            type="button"
            aria-label={t("settings.scrape.dismissHint")}
            onClick={() => setJustEnabled(false)}
            className="shrink-0 text-[var(--text-faint)] hover:text-[var(--text)]"
          >
            ✕
          </button>
        </div>
      )}

      <div className="mb-2 flex items-center gap-3 rounded-xl border border-white/[0.08] bg-white/[0.025] px-3 py-2.5">
        <span className="grid size-8 shrink-0 place-items-center rounded-lg bg-[var(--src-tmdb)]/[0.14] text-micro font-extrabold tracking-tight text-[var(--src-tmdb)]">
          TMDB
        </span>
        <span className="min-w-0 flex-1">
          <span className="block text-ui font-semibold">TMDB</span>
          <span className="block text-caption text-[var(--text-faint)]">{t("settings.scrape.primarySource")}</span>
        </span>
        <span className="shrink-0 rounded-full border border-white/[0.08] px-2 py-px text-micro text-[var(--text-faint)]">
          {t("settings.scrape.alwaysEnabled")}
        </span>
      </div>

      <div className="overflow-hidden rounded-xl border border-white/[0.08] bg-white/[0.025]">
        <div className="flex items-center gap-3 px-3 py-2.5">
          <span className="grid size-8 shrink-0 place-items-center rounded-lg bg-[var(--src-fanart)]/[0.14] text-micro font-extrabold text-[var(--src-fanart)]">
            FA
          </span>
          <span className="min-w-0 flex-1">
            <span className="flex flex-wrap items-center gap-2 text-ui font-semibold">
              Fanart.tv {pill}
            </span>
            <span className="block text-caption text-[var(--text-faint)]">
              {status?.configured
                ? library
                  ? t("settings.scrape.sharedKeyHint")
                  : t("settings.scrape.fanartConfiguredHint")
                : t("settings.scrape.fanartUnconfiguredHint")}
            </span>
          </span>
          <button
            type="button"
            role="switch"
            aria-checked={enabled}
            aria-label={t("settings.scrape.enableFanart")}
            onClick={toggle}
            className={`relative h-[21px] w-9 shrink-0 rounded-full transition-colors ${
              enabled ? "bg-[var(--accent-2)]" : "bg-white/[0.14]"
            }`}
          >
            <span
              className={`absolute left-[2.5px] top-[2.5px] size-4 rounded-full bg-white transition-transform ${
                enabled ? "translate-x-[15px]" : ""
              }`}
            />
          </button>
        </div>
        {keyForm && (
          <FanartKeyForm
            variant={library ? "library" : "global"}
            className="mx-3 mb-3"
            onVerified={(next) => {
              setStatus(next);
              setKeyForm(false);
              patch({ fanart_enabled: true });
              setJustEnabled(true);
            }}
            onCancel={() => setKeyForm(false)}
          />
        )}
        {!keyForm && status?.configured && (
          <div className="flex flex-wrap items-center gap-2.5 border-t border-white/[0.06] px-3 py-2 pl-14 text-caption text-[var(--text-faint)] max-sm:pl-3">
            {status.key_invalid ? (
              <span className="text-[var(--danger)]">
                {t("settings.scrape.fanartRejected")}
              </span>
            ) : (
              <span>
                API Key <code className="font-mono text-[var(--text-muted)]">••••{status.key_hint}</code>
              </span>
            )}
            {(!library || status.key_invalid) && (
              <button
                type="button"
                onClick={() => setKeyForm(true)}
                className="text-[var(--accent)] underline underline-offset-2"
              >
                {status.key_invalid ? t("settings.scrape.reenterKey") : t("settings.scrape.replaceKey")}
              </button>
            )}
          </div>
        )}
      </div>

      <p className="mb-1.5 mt-4 flex flex-wrap items-baseline gap-2 text-sub font-semibold">
        {t("settings.scrape.sourceOrder")}
        <span className="text-caption font-normal text-[var(--text-faint)]">
          {t("settings.scrape.sourceOrderHint")}
        </span>
      </p>
      <div
        className={`overflow-hidden rounded-xl border border-white/[0.08] ${enabled ? "" : "opacity-40"}`}
      >
        {sourceRows(t).map((row) => {
          const order = setting[row.key];
          const isDefault = order[0] === row.first;
          const note =
            row.key === "poster_source_order" && setting.poster_mode === "default"
              ? t("settings.scrape.defaultPosterHint")
              : row.key === "season_poster_source_order"
                ? t("settings.scrape.seasonPosterHint")
                : null;
          return (
            <div
              key={row.key}
              className="grid grid-cols-[86px_1fr_auto] items-center gap-x-2.5 gap-y-1 border-t border-white/[0.06] px-3 py-2 first:border-t-0"
            >
              <span className="text-sub text-[var(--text)]">
                {row.label}
                <span
                  className={`block text-micro ${isDefault ? "text-[var(--src-fanart)]" : "text-[var(--text-faint)]"}`}
                >
                  {isDefault ? t("settings.scrape.defaultSource", { reason: row.why }) : t("settings.scrape.adjusted")}
                </span>
              </span>
              <span className="flex flex-wrap items-center gap-1.5">
                {order.map((source, index) => (
                  <span key={source} className="flex items-center gap-1.5">
                    {index > 0 && <span className="text-caption text-[var(--text-faint)]">→</span>}
                    <span
                      className={`flex items-center gap-1.5 rounded-full border border-[var(--accent-2)]/40 bg-[var(--accent-soft)] py-0.5 pl-1 pr-2.5 text-sub ${
                        source === "fanart" && !enabled ? "line-through opacity-50" : ""
                      }`}
                    >
                      <span
                        className={`grid size-4 place-items-center rounded-full text-[9.5px] font-extrabold text-[#0a0b10] ${
                          source === "tmdb" ? "bg-[var(--src-tmdb)]" : "bg-[var(--src-fanart)]"
                        }`}
                      >
                        {index + 1}
                      </span>
                      {SOURCE_LABEL[source]}
                    </span>
                  </span>
                ))}
              </span>
              <button
                type="button"
                disabled={!enabled}
                aria-label={t("settings.scrape.swapSources", { image: row.label })}
                onClick={() => patch({ [row.key]: [...order].reverse() } as Partial<ScrapeSetting>)}
                className="rounded-lg bg-white/[0.06] px-2.5 py-1 text-sub text-[var(--text-muted)] transition-colors hover:bg-white/[0.12] hover:text-[var(--text)] disabled:pointer-events-none disabled:opacity-30"
              >
                ⇄
              </button>
              {note && (
                <span className="col-start-2 col-end-4 text-micro text-[var(--text-faint)]">{note}</span>
              )}
            </div>
          );
        })}
      </div>
      <p className="mt-2.5 rounded-xl border border-white/[0.08] bg-white/[0.03] px-3 py-2.5 text-caption leading-relaxed text-[var(--text-muted)]">
        {t.rich("settings.scrape.languageBeforeSource", { strong: (chunks) => <strong className="font-semibold text-[var(--text)]">{chunks}</strong> })}
      </p>
    </Card>
  );
}

/** 像素门槛输入：打字时只改本地草稿，失焦或回车才提交（不把「1」「10」这些中间值存下来） */
function WidthInput({ value, onCommit }: { value: number; onCommit: (next: number) => void }) {
  const [draft, setDraft] = useState(String(value));
  useEffect(() => setDraft(String(value)), [value]);
  const commit = () => {
    const next = Math.max(0, Math.round(Number(draft) || 0));
    setDraft(String(next));
    if (next !== value) onCommit(next);
  };
  return (
    <input
      type="number"
      min={0}
      step={100}
      className={`${SETTINGS_INPUT_CLASS} w-24 tabular-nums`}
      value={draft}
      onChange={(e) => setDraft(e.target.value)}
      onBlur={commit}
      onKeyDown={(e) => e.key === "Enter" && e.currentTarget.blur()}
    />
  );
}

export function ImagesTab({
  setting,
  patch,
  extraImageLangs,
  effective,
  estimate = null,
  inheritsGlobal = false,
  overriddenBy,
  shellFor,
}: {
  setting: ScrapeSetting;
  patch: (changes: Partial<ScrapeSetting>) => void;
  extraImageLangs: ChipOption[];
  /** 已保存配置的生效值（画质档、四个档位）；库设置页传全局生效值 */
  effective: ScrapeEffective | null;
  /**
   * 各画质档的磁盘估算（全局设置页传）。库设置页不传：估算按全站的图片张数算，
   * 放在单个库的覆盖里会让人以为是这个库的量
   */
  estimate?: ImageStorageEstimate | null;
  /** 库设置页：留空跟随的是全局设置（后端把库覆盖里的空值当「没覆盖」） */
  inheritsGlobal?: boolean;
  overriddenBy?: (keys: (keyof ScrapeSetting)[]) => string[];
  shellFor?: (title: string, keys: (keyof ScrapeSetting)[]) => CardShell;
}) {
  const t = useTranslations();
  // 界面选中的画质档：显式选过就是它，没选过按已保存配置反推（后端 effective 给）
  const quality: ImageQuality = setting.image_quality || effective?.image_quality || "original";
  // 档位下拉留空的含义：全局页是环境变量，库页是全局设置。留空的实际档位只有在
  // 已保存配置本身就是「自定义」时才等于 effective 里的值（选了预设时 effective
  // 是预设的档位，不是留空会落到的值），其它时候不写数字，免得说错
  const fallbackKnown = effective?.image_quality === "custom";
  const inheritLabel = (fallback: string) => {
    const base = inheritsGlobal ? t("settings.scrape.followGlobal") : t("settings.scrape.followEnvironment");
    return fallbackKnown && fallback ? t("settings.scrape.inheritValue", { base, value: fallback }) : base;
  };
  const chooseQuality = (next: ImageQuality) => {
    if (next !== "custom") {
      patch({ image_quality: next });
      return;
    }
    // 切到自定义：把刚才那一档的四个档位填进下拉，从用户看到的效果起步微调
    patch(
      quality === "custom"
        ? { image_quality: "custom" }
        : { image_quality: "custom", ...IMAGE_QUALITY_PRESETS[quality] },
    );
  };
  // 自定义档的估算只有在「已保存的就是自定义、且四个档位没改过」时才准
  // （估算按已保存配置算）；改了下拉就提示保存后再看
  const customEstimateFresh =
    estimate?.current_quality === "custom" &&
    effective?.image_quality === "custom" &&
    imageSizeFields(t).every(
      (field) => (setting[field.key] || effective[field.key]) === effective[field.key],
    );
  const estimateText = (id: ImageQuality): string | null => {
    if (!estimate) return null;
    if (id !== "custom") return t("settings.scrape.storageEstimate", { estimate: formatEstimate(estimate.presets[id]) });
    if (quality !== "custom") return null;
    return customEstimateFresh
      ? t("settings.scrape.storageEstimate", { estimate: formatEstimate(estimate.current_bytes) })
      : t("settings.scrape.estimateAfterSave");
  };

  return (
    <>
      <ImageSourcesCard
        setting={setting}
        patch={patch}
        library={inheritsGlobal}
        overriddenBy={overriddenBy}
        shellFor={shellFor}
      />
      <Card
        title={t("settings.scrape.poster")}
        overriddenBy={overriddenBy?.(["poster_mode", "poster_language_priority"])}
        shell={shellFor?.(t("settings.scrape.poster"), ["poster_mode", "poster_language_priority"])}
        desc={t("settings.scrape.posterHint")}
      >
        <div className="grid gap-2 md:grid-cols-2">
          {(
            [
              {
                id: "default",
                title: t("settings.scrape.tmdbDefault"),
                desc: t("settings.scrape.defaultPosterDescription"),
              },
              {
                id: "language",
                title: t("settings.scrape.languagePoster"),
                desc: t("settings.scrape.languagePosterDescription"),
              },
            ] as const
          ).map((mode) => (
            <label
              key={mode.id}
              className={`cursor-pointer rounded-xl border p-3 transition-colors ${
                setting.poster_mode === mode.id
                  ? "border-[var(--accent-2)] bg-[var(--accent-soft)]"
                  : "border-white/[0.08] bg-white/[0.04] hover:bg-white/[0.07]"
              }`}
            >
              <input
                type="radio"
                name="poster-mode"
                className="sr-only"
                checked={setting.poster_mode === mode.id}
                onChange={() => patch({ poster_mode: mode.id })}
              />
              <span className="block text-ui font-semibold">{mode.title}</span>
              <span className="mt-0.5 block text-caption text-[var(--text-faint)]">
                {mode.desc}
              </span>
            </label>
          ))}
        </div>
        {/* 默认模式下语言优先级本不生效（置灰）；启用 Fanart 时 TMDB 默认的那张要和
            Fanart 的海报按它比较，所以要能编辑 */}
        <div
          className={`mt-4 ${
            setting.poster_mode === "language" || setting.fanart_enabled
              ? ""
              : "pointer-events-none opacity-40"
          }`}
        >
          <OrderChips
            options={commonImageLangs(t)}
            extraOptions={extraImageLangs}
            moreLabel={t("settings.scrape.languageOptions")}
            value={setting.poster_language_priority}
            max={4}
            primaryTag={t("settings.scrape.preferred")}
            onChange={(next) => patch({ poster_language_priority: next })}
          />
          {setting.poster_mode === "default" && setting.fanart_enabled && (
            <p className="mt-2 text-caption leading-relaxed text-[var(--text-faint)]">
              {t("settings.scrape.fanartPosterHint")}
            </p>
          )}
        </div>
      </Card>
      <Card
        title={t("settings.scrape.fanartBackdrop")}
        overriddenBy={overriddenBy?.(["backdrop_language_priority"])}
        shell={shellFor?.(t("settings.scrape.fanartBackdrop"), ["backdrop_language_priority"])}
        desc={t("settings.scrape.backdropHint")}
      >
        <OrderChips
          options={commonImageLangs(t)}
          extraOptions={extraImageLangs}
          moreLabel={t("settings.scrape.languageOptions")}
          value={setting.backdrop_language_priority}
          max={4}
          primaryTag={t("settings.scrape.preferred")}
          onChange={(next) => patch({ backdrop_language_priority: next })}
        />
      </Card>
      <Card
        title={t("settings.scrape.titleLogo")}
        overriddenBy={overriddenBy?.(["logo_language_priority"])}
        shell={shellFor?.(t("settings.scrape.titleLogo"), ["logo_language_priority"])}
        desc={t("settings.scrape.logoHint")}
      >
        <OrderChips
          options={commonImageLangs(t)}
          extraOptions={extraImageLangs}
          moreLabel={t("settings.scrape.languageOptions")}
          value={setting.logo_language_priority}
          max={4}
          primaryTag={t("settings.scrape.preferred")}
          onChange={(next) => patch({ logo_language_priority: next })}
        />
      </Card>
      <Card
        title={t("settings.scrape.minResolution")}
        overriddenBy={overriddenBy?.(["poster_min_width", "backdrop_min_width"])}
        shell={shellFor?.(t("settings.scrape.minResolution"), ["poster_min_width", "backdrop_min_width"])}
        desc={t("settings.scrape.minResolutionHint")}
      >
        <div className="flex flex-wrap items-center gap-x-4 gap-y-2.5 text-sub text-[var(--text-muted)]">
          {(
            [
              ["poster_min_width", t("settings.scrape.poster")],
              ["backdrop_min_width", t("settings.scrape.backdrop")],
            ] as const
          ).map(([key, label]) => (
            <span key={key} className="flex items-center gap-1.5">
              {label} ≥
              <WidthInput value={setting[key]} onCommit={(next) => patch({ [key]: next })} />
              {/* 0 在输入框里看不出是"不限制"还是"没填"，补一句 */}
              {setting[key] === 0 && (
                <span className="text-caption text-[var(--text-faint)]">{t("settings.scrape.unlimited")}</span>
              )}
            </span>
          ))}
        </div>
      </Card>
      <Card
        title={t("settings.scrape.localQuality")}
        overriddenBy={overriddenBy?.(IMAGE_QUALITY_KEYS)}
        shell={shellFor?.(t("settings.scrape.localQuality"), IMAGE_QUALITY_KEYS)}
        desc={t("settings.scrape.localQualityHint")}
      >
        <div className="grid gap-2 md:grid-cols-2">
          {imageQualityOptions(t).map((option) => {
            const hint = estimateText(option.id);
            return (
              <label
                key={option.id}
                className={`cursor-pointer rounded-xl border p-3 transition-colors ${
                  quality === option.id
                    ? "border-[var(--accent-2)] bg-[var(--accent-soft)]"
                    : "border-white/[0.08] bg-white/[0.04] hover:bg-white/[0.07]"
                }`}
              >
                <input
                  type="radio"
                  // 库设置页与全局页不会同屏，但同页多实例时 name 也不该串组
                  name={inheritsGlobal ? "image-quality-library" : "image-quality"}
                  className="sr-only"
                  checked={quality === option.id}
                  onChange={() => chooseQuality(option.id)}
                />
                <span className="flex flex-wrap items-baseline justify-between gap-x-2">
                  <span className="text-ui font-semibold">{option.title}</span>
                  {hint && (
                    <span className="tnum text-caption text-[var(--text-muted)]">{hint}</span>
                  )}
                </span>
                <span className="mt-0.5 block text-caption text-[var(--text-faint)]">
                  {option.desc}
                </span>
              </label>
            );
          })}
        </div>
        {/* 自定义才展开四个档位；预设下档位字段被后端忽略，摆出来只会让人以为还能改 */}
        {quality === "custom" && (
          <div className="mt-3 grid gap-2 sm:grid-cols-2 lg:grid-cols-4">
            {imageSizeFields(t).map((field) => (
              <label key={field.key} className="flex flex-col gap-1">
                <span className="text-caption text-[var(--text-muted)]">{field.label}</span>
                <select
                  className={SETTINGS_INPUT_CLASS}
                  value={setting[field.key]}
                  onChange={(e) => patch({ [field.key]: e.target.value } as Partial<ScrapeSetting>)}
                >
                  <option value="">{inheritLabel(effective?.[field.key] ?? "")}</option>
                  {field.sizes.map((size) => (
                    <option key={size} value={size}>
                      {size === "original" ? t("settings.scrape.originalSize") : size}
                    </option>
                  ))}
                </select>
              </label>
            ))}
          </div>
        )}
      </Card>
    </>
  );
}

export function ScrapeSettingsSection() {
  const t = useTranslations();
  const toast = useToast();
  const [view, setView] = useState<ScrapeConfigView | null>(null);
  const [setting, setSetting] = useState<ScrapeSetting | null>(null);
  const locale = useLocale();
  const chipOptions = useScrapeChipOptions();
  // 各库的覆盖情况：卡片上标「N 个库已覆盖」，避免"在全局改了不生效"的困惑
  const [libraryOverrides, setLibraryOverrides] = useState<
    { name: string; keys: string[] }[]
  >([]);
  // 展开的卡片标题（同时只开一张）；默认全收起——折叠头已经把当前值摊出来了，
  // 一屏能扫完全站配置（用户决策 2026-08-30：与库设置页形态完全一致）
  const [open, setOpen] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  // 自动保存的状态：显示在展开的那一行右侧（「保存中… / 已保存」）
  const [saveState, setSaveState] = useState<"idle" | "saving" | "saved">("idle");
  // 最新的编辑值与待发的保存：连续点芯片时合并成一次请求，只采纳最后一次的响应
  const latest = useRef<ScrapeSetting | null>(null);
  const timer = useRef<number | null>(null);
  const seq = useRef(0);
  // 「本地图片画质」各档的磁盘估算；拉不到（非管理员、网络）就不显示数字，设置照常可用
  const [estimate, setEstimate] = useState<ImageStorageEstimate | null>(null);
  const loadEstimate = useCallback(() => {
    getImageStorageEstimate()
      .then(setEstimate)
      .catch(() => setEstimate(null));
  }, []);
  useEffect(() => {
    loadEstimate();
  }, [loadEstimate]);

  const load = useCallback(async () => {
    setError(null);
    try {
      const config = await getScrapeConfig();
      setView(config);
      // 编辑态用"生效值"起步：跟随 env 的空列表在界面上就是当前生效的语言，
      // 用户看到的即所得；未改动不保存则语义不变
      latest.current = {
        ...config.setting,
        language_priority: config.setting.language_priority.length
          ? config.setting.language_priority
          : config.effective.language_priority,
      };
      setSetting(latest.current);
    } catch (err) {
      setError(err instanceof Error ? err.message : appTranslator()("settings.scrape.loadFailed"));
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  useEffect(() => {
    // 拉不到不阻断：标注只是可诊断性提示，没有它设置页照常可用
    listLibraries()
      .then((libraries) =>
        setLibraryOverrides(
          libraries
            .map((library) => ({
              name: library.name,
              keys: Object.keys(library.scrape_overrides ?? {}),
            }))
            .filter((entry) => entry.keys.length > 0),
        ),
      )
      .catch(() => {});
  }, []);

  const shellFor = useCallback(
    (title: string, keys: (keyof ScrapeSetting)[]): CardShell => ({
      open: open === title,
      onToggleOpen: () => setOpen((current) => (current === title ? null : title)),
      note:
        open === title && saveState !== "idle"
          ? saveState === "saving"
            ? t("settings.scrape.saving")
            : t("settings.scrape.saved")
          : undefined,
      // 全局页没有"跟随/覆盖"这个静默态（它就是被跟随的那一层），折叠头只报
      // 当前值；点亮与否交给「N 个库已覆盖」徽标表达
      customized: false,
      // 画质没选过（空串）时按已保存配置反推的那一档来说，与卡片里选中的一致
      status: setting
        ? describeScrapeValues(keys, {
            ...setting,
            image_quality: setting.image_quality || view?.effective.image_quality || "",
          }, locale)
        : "",
    }),
    [open, setting, view, saveState, locale, t],
  );

  const overriddenBy = useCallback(
    (keys: (keyof ScrapeSetting)[]) =>
      libraryOverrides
        .filter((entry) => keys.some((key) => entry.keys.includes(key)))
        .map((entry) => entry.name),
    [libraryOverrides],
  );

  const persist = useCallback(async () => {
    timer.current = null;
    const current = latest.current;
    if (!current) return;
    const mine = ++seq.current;
    setSaveState("saving");
    try {
      const config = await saveScrapeConfig(current);
      if (mine !== seq.current) return;
      // 不拿响应覆盖编辑值：请求在路上时用户可能又改了别的
      setView(config);
      setSaveState("saved");
      // 估算里「自定义」那一档按已保存配置算，保存后重取
      loadEstimate();
    } catch (err) {
      if (mine !== seq.current) return;
      setSaveState("idle");
      toast.error(err instanceof Error ? err.message : appTranslator()("settings.scrape.saveFailed"));
      // 失败不猜怎么回滚，重读服务端的真实值
      void load();
    }
  }, [toast, loadEstimate, load]);

  // 「已保存」停留两秒后收起
  useEffect(() => {
    if (saveState !== "saved") return;
    const id = window.setTimeout(() => setSaveState("idle"), 2000);
    return () => window.clearTimeout(id);
  }, [saveState]);

  // 离开页面时还没发出去的改动立刻发掉
  const persistRef = useRef(persist);
  persistRef.current = persist;
  useEffect(
    () => () => {
      if (timer.current !== null) {
        window.clearTimeout(timer.current);
        void persistRef.current();
      }
    },
    [],
  );

  /** 改完即存：控件都是离散的（芯片、单选、开关、下拉），没有写到一半的中间态 */
  const patch = useCallback(
    (changes: Partial<ScrapeSetting>) => {
      if (!latest.current) return;
      latest.current = { ...latest.current, ...changes };
      setSetting(latest.current);
      if (timer.current !== null) window.clearTimeout(timer.current);
      timer.current = window.setTimeout(() => void persist(), 400);
    },
    [persist],
  );

  if (error) {
    return (
      <div className="rounded-xl bg-white/[0.03] px-4 py-6 text-center text-ui text-[var(--text-muted)]">
        {error}
        <button type="button" className="btn-glass ml-3 px-3 py-1.5 text-sub" onClick={load}>
          {t("settings.scrape.retry")}
        </button>
      </div>
    );
  }
  if (!setting) {
    return (
      <p className="flex items-center gap-2.5 rounded-xl bg-white/[0.03] px-4 py-5 text-ui text-[var(--text-muted)]">
        <BrandLoader className="size-5" />
        {t("settings.scrape.loading")}
      </p>
    );
  }

  const mirrorOverrides = overriddenBy(mirrorRows(t).map((row) => row.key));

  return (
    <div className="space-y-10">
      {/* 「可按库覆盖」这件事在分区顶部统一说一句：P4 之后所有字段都能按库
          覆盖，逐卡贴徽标不区分任何东西，只是噪音（设计文档 §14.5） */}
      <p className="px-1 text-sub leading-relaxed text-[var(--text-muted)]">
        {t.rich("settings.scrape.globalIntro", { strong: (chunks) => <strong className="font-medium text-[var(--text)]">{chunks}</strong> })}
      </p>

      {/* 分节 + 行组：与「编辑库 → 刮削设置」同一套结构与控件。
          分节顺序沿用刮削管线的先后，只为读起来顺——四组之间没有依赖，
          所以不编号（编号会把并列分组伪装成必须按序完成的向导）。 */}
      <ScrapeSection label={t("settings.scrape.metadataSection")} description={t("settings.scrape.metadataSectionHint")}>
        <MetaTab
          setting={setting}
          patch={patch}
          extraMetaLangs={chipOptions.metaLangs}
          extraCountries={chipOptions.certCountries}
          overriddenBy={overriddenBy}
          shellFor={shellFor}
        />
      </ScrapeSection>

      <ScrapeSection label={t("settings.scrape.imagesSection")} description={t("settings.scrape.imagesSectionHint")}>
        <ImagesTab
          setting={setting}
          patch={patch}
          extraImageLangs={chipOptions.imageLangs}
          effective={view?.effective ?? null}
          estimate={estimate}
          overriddenBy={overriddenBy}
          shellFor={shellFor}
        />
      </ScrapeSection>

      <ScrapeSection label={t("settings.scrape.namingSection")} description={t("settings.scrape.namingSectionHint")}>
        <NamingTab setting={setting} patch={patch} overriddenBy={overriddenBy} shellFor={shellFor} />
      </ScrapeSection>

      <ScrapeSection
        label={t("settings.scrape.mirrorSection")}
        description={
          <>
            {t("settings.scrape.mirrorSectionHint")}
            {mirrorOverrides.length > 0 && (
              <span className="text-[var(--accent)]">
                {" "}
                {t("settings.scrape.mirrorOverrides", { libraries: formatList(mirrorOverrides) })}
              </span>
            )}
          </>
        }
      >
        <MirrorTab setting={setting} patch={patch} />
      </ScrapeSection>
    </div>
  );
}
