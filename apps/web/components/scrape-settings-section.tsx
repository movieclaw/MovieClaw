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

import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import { BrandLoader } from "@/components/brand-loader";
import { FanartKeyForm, fanartUsable, useFanartStatus } from "@/components/fanart-key-form";
import { useToast } from "@/components/feedback";
import { ChevronDownIcon } from "@/components/icons";
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

const INPUT_CLASS =
  "rounded-xl border border-white/[0.08] bg-white/[0.04] px-3 py-2 text-sub " +
  "text-[var(--text)] outline-none transition-colors placeholder:text-[var(--text-faint)] " +
  "focus:border-[var(--accent)]/50";

/** 排序芯片的候选项。id 是落库值（语言标签 / 地区码 / meta·orig·null token）。 */
interface ChipOption {
  id: string;
  name: string;
  /** 悬停说明（特殊 token 必配，见设计文档 §3） */
  tip?: string;
}

/** 常用语种快捷芯片（元数据语言，值为带地区的语言标签）。 */
const COMMON_META_LANGS: ChipOption[] = [
  { id: "zh-CN", name: "中文（简体）" },
  { id: "zh-TW", name: "中文（繁體）" },
  { id: "en-US", name: "English" },
  { id: "ja-JP", name: "日本語" },
  { id: "ko-KR", name: "한국어" },
  { id: "fr-FR", name: "Français" },
];

/** 图片语言的特殊 token + 常用语种（值为 TMDB 图片语言码）。 */
const COMMON_IMAGE_LANGS: ChipOption[] = [
  {
    id: "meta",
    name: "跟随元数据主语言",
    tip: "引用「元数据」里语言优先级的第 1 位，改语言时选图自动跟随",
  },
  {
    id: "orig",
    name: "原始语言",
    tip: "作品的原声语言（随条目自动解析：《寄生虫》为韩语、日本动画为日语）",
  },
  { id: "en", name: "English" },
  { id: "null", name: "无文字", tip: "没有烧录任何文字的干净图（TMDB 语言标记为 null）" },
  { id: "ja", name: "日本語" },
];

const COMMON_CERT_COUNTRIES: ChipOption[] = [
  { id: "CN", name: "中国" },
  { id: "US", name: "美国" },
  { id: "JP", name: "日本" },
  { id: "GB", name: "英国" },
];

/** 可选的 TMDB 图床档位：后端 settings/metadata.py 合法集合里实用的那部分（过小的档位不提供）；
 *  空 = 跟随上一级（全局设置页是环境变量，库设置页是全局设置）。 */
const POSTER_SIZES = ["w342", "w500", "w780", "original"];
const BACKDROP_SIZES = ["w780", "w1280", "original"];
const STILL_SIZES = ["w185", "w300", "original"];
/** 演职员头像：w185 手机网页够用，h632 电视也清楚，original 是 TMDB 原图 */
const PROFILE_SIZES = ["w185", "h632", "original"];

/** 「本地图片画质」四档的名字与一句话说明（docs/design/image-sizing.md §8.1）。 */
const IMAGE_QUALITY_OPTIONS: { id: ImageQuality; title: string; desc: string }[] = [
  { id: "original", title: "原图（默认）", desc: "所有图存 TMDB 原图，各设备都最清楚" },
  { id: "standard", title: "标准", desc: "各设备都清楚，头像与海报不存原图，省约四成空间" },
  { id: "compact", title: "节省空间", desc: "手机和网页够用；电视上剧照、头像会发虚" },
  { id: "custom", title: "自定义", desc: "海报、背景、剧照、头像逐项指定 TMDB 档位" },
];

/** 自定义画质的四个档位下拉：字段、名字、可选档位 */
const IMAGE_SIZE_FIELDS = [
  { key: "poster_size", label: "海报", sizes: POSTER_SIZES },
  { key: "backdrop_size", label: "背景", sizes: BACKDROP_SIZES },
  { key: "still_size", label: "剧照", sizes: STILL_SIZES },
  { key: "profile_size", label: "头像", sizes: PROFILE_SIZES },
] as const;

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
const SOURCE_ROWS = [
  { key: "poster_source_order", label: "海报", first: "tmdb", why: "TMDB 在前" },
  { key: "backdrop_source_order", label: "背景", first: "tmdb", why: "TMDB 在前（常有 4K）" },
  { key: "logo_source_order", label: "片名 Logo", first: "fanart", why: "Fanart 在前（中文多）" },
  { key: "season_poster_source_order", label: "季海报", first: "fanart", why: "Fanart 在前" },
] as const;

/** 来源卡的人话摘要：「TMDB + Fanart.tv · 片名 Logo、季海报优先 Fanart」/「仅 TMDB」 */
function describeSources(setting: ScrapeSetting): string {
  if (!setting.fanart_enabled) return "仅 TMDB";
  const fanartFirst = SOURCE_ROWS.filter((row) => setting[row.key][0] === "fanart").map(
    (row) => row.label,
  );
  const lead = fanartFirst.length
    ? fanartFirst.length === SOURCE_ROWS.length
      ? "全部优先 Fanart"
      : `${fanartFirst.join("、")}优先 Fanart`
    : "全部优先 TMDB";
  return `TMDB + Fanart.tv · ${lead}`;
}

/** 估算字节数 → 「约 2.6 GB」；不足 1 GB 用 MB（取整），量级参考不需要更多精度 */
function formatEstimate(bytes: number): string {
  const gb = bytes / 1024 ** 3;
  if (gb >= 10) return `约 ${Math.round(gb)} GB`;
  if (gb >= 1) return `约 ${gb.toFixed(1)} GB`;
  return `约 ${Math.max(1, Math.round(bytes / 1024 ** 2))} MB`;
}

/** 画质档的人话摘要（折叠头用）：预设只说名字，自定义把四个档位列出来 */
function describeImageQuality(setting: ScrapeSetting): string {
  const option = IMAGE_QUALITY_OPTIONS.find((o) => o.id === setting.image_quality);
  if (!option) return "按档位逐项跟随";
  if (option.id !== "custom") return option.title.replace("（默认）", "");
  const sizes = IMAGE_SIZE_FIELDS.map(
    (field) => `${field.label} ${setting[field.key] || "跟随"}`,
  ).join(" / ");
  return `自定义（${sizes}）`;
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
): string {
  const parts: string[] = [];
  for (const key of keys) {
    switch (key) {
      case "language_priority":
        parts.push(joinPriority(COMMON_META_LANGS, setting.language_priority));
        break;
      case "cert_country_priority":
        parts.push(joinPriority(COMMON_CERT_COUNTRIES, setting.cert_country_priority));
        break;
      case "poster_mode":
        // 海报卡把「模式 + 语言优先级」并成一句：默认模式下语言优先级不生效，
        // 摘要里再列它只会误导——启用 Fanart 时例外：TMDB 默认的那张要和 Fanart
        // 的海报按语言优先级比，这时语言优先级是生效的
        parts.push(
          setting.poster_mode === "default"
            ? setting.fanart_enabled
              ? `TMDB 默认 · 与 Fanart 按 ${joinPriority(COMMON_IMAGE_LANGS, setting.poster_language_priority)} 比较`
              : "TMDB 默认"
            : `按语言：${joinPriority(COMMON_IMAGE_LANGS, setting.poster_language_priority)}`,
        );
        break;
      case "fanart_enabled":
        parts.push(describeSources(setting));
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
        parts.push(joinPriority(COMMON_IMAGE_LANGS, setting.logo_language_priority));
        break;
      case "poster_language_priority":
        if (!keys.includes("poster_mode")) {
          parts.push(joinPriority(COMMON_IMAGE_LANGS, setting.poster_language_priority));
        }
        break;
      case "backdrop_language_priority":
        parts.push(joinPriority(COMMON_IMAGE_LANGS, setting.backdrop_language_priority));
        break;
      case "poster_min_width":
        parts.push(
          setting.poster_min_width > 0 ? `海报 ≥${setting.poster_min_width}` : "海报不限宽",
        );
        break;
      case "backdrop_min_width":
        parts.push(
          setting.backdrop_min_width > 0 ? `背景 ≥${setting.backdrop_min_width}` : "背景不限宽",
        );
        break;
      case "image_quality":
        parts.push(describeImageQuality(setting));
        break;
      case "poster_size":
      case "backdrop_size":
      case "still_size":
      case "profile_size": {
        // 和画质一起出现时由画质那一句表达（自定义会列出四个档位）；单独出现时
        // 三个档位并成一句「档位 …」，空串统一说成"跟随环境"
        if (key !== "poster_size" || keys.includes("image_quality")) break;
        const sizes = [setting.poster_size, setting.backdrop_size, setting.still_size];
        parts.push(sizes.every((v) => !v) ? "档位跟随环境" : `档位 ${sizes.map((v) => v || "环境").join("/")}`);
        break;
      }
      case "naming_entry_dir": {
        // 四个模板并成一句：逐个列模板串太长，只说"哪几项不是默认"
        const changed = NAMING_FIELDS.filter((f) => setting[f.key].trim());
        parts.push(
          changed.length === 0
            ? "全部默认模板"
            : `已改：${changed.map((f) => f.label).join("、")}`,
        );
        break;
      }
      case "naming_movie_file":
      case "naming_season_dir":
      case "naming_episode_file":
        break; // 已在 naming_entry_dir 一并表达
      case "mirror_images": {
        const off = MIRROR_ROWS.filter((r) => !setting[r.key]);
        parts.push(off.length === 0 ? "三项全写" : `不写：${off.map((r) => r.label).join("、")}`);
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
            更多{moreLabel}
          </button>
        )}
      </div>
      {moreOpen && (
        <div className="mt-2.5 rounded-xl border border-white/[0.12] bg-white/[0.04] p-3">
          <input
            className={`${INPUT_CLASS} mb-2.5 w-full`}
            placeholder={`搜索${moreLabel}（名称或代码）…`}
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
          <div className="flex max-h-44 flex-wrap content-start gap-1.5 overflow-y-auto">
            {filteredExtra.length === 0 ? (
              <span className="px-1 text-caption text-[var(--text-faint)]">
                没有匹配的{moreLabel}
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
                  aria-label={`把「${name}」上移一位`}
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
                  aria-label={`移除「${name}」`}
                  onClick={() => onChange(value.filter((v) => v !== id))}
                  className="flex size-5 items-center justify-center rounded-full text-caption text-[var(--text-muted)] transition-colors hover:bg-white/10 hover:text-[var(--text)] disabled:pointer-events-none disabled:opacity-25"
                >
                  ✕
                </button>
              </span>
            );
          })}
          <span className="text-caption text-[var(--text-faint)]">
            按此顺序回落（最多 {max} 项）
          </span>
        </div>
      ) : (
        <p className="mt-2 text-caption text-[var(--text-faint)]">
          点击上方候选加入，加入后可在这里排序
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
  return (
    <div className="mb-4 flex flex-wrap items-center justify-between gap-3 rounded-xl border border-white/[0.08] bg-white/[0.03] px-3.5 py-2.5">
      <span className="min-w-0 text-caption text-[var(--text-faint)]">
        全局：{follow.globalSummary}
      </span>
      <div className="flex shrink-0 gap-1">
        {(
          [
            [false, "跟随全局"],
            [true, "自定义"],
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
  const effectiveFollow = shell?.follow ?? follow;
  const body = (
    <>
      <p className="mb-4 mt-1 max-w-[62ch] text-sub text-[var(--text-muted)]">{desc}</p>
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
            title={`${overriddenBy.join("、")}不跟随此处的设置`}
            className="rounded-full bg-[var(--accent-soft)] px-2 py-px text-micro text-[var(--accent)]"
          >
            {overriddenBy.length} 个库已覆盖
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
    <section
      ref={ref}
      className="overflow-hidden rounded-2xl border border-white/[0.08] bg-white/[0.04]"
    >
        <button
          type="button"
          aria-expanded={shell.open}
          onClick={shell.onToggleOpen}
          className="flex w-full items-center gap-3 px-4 py-3 text-left transition-colors hover:bg-white/[0.03]"
        >
          <span className="min-w-0 flex-1">
            <span className="flex flex-wrap items-center gap-x-2 gap-y-1 text-ui font-semibold">
              {title}
              {shell.customized && (
                <span className="size-1.5 shrink-0 rounded-full bg-[var(--accent)]" aria-hidden />
              )}
              {/* 收起时也要看得见"这项被几个库改了"——它正是"在全局改了不生效"
                  的答案，藏在展开态里等于没有 */}
              {overriddenBy && overriddenBy.length > 0 && (
                <span
                  title={`${overriddenBy.join("、")}不跟随此处的设置`}
                  className="rounded-full bg-[var(--accent-soft)] px-2 py-px text-micro font-normal text-[var(--accent)]"
                >
                  {overriddenBy.length} 个库已覆盖
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
            <div className="border-t border-white/[0.06] px-4 pb-4">{children}</div>
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
const TOKEN_GROUPS: { label: string; tokens: Record<string, string> }[] = [
  {
    label: "片名与编号",
    tokens: {
      title: "片名",
      original_title: "原名",
      english_title: "英文名",
      year: "年份",
      tmdb_id: "TMDB ID",
      imdb_id: "IMDb ID",
      douban_id: "豆瓣 ID",
    },
  },
  {
    label: "季集",
    tokens: { season: "季号", season_name: "季名", episode: "集号", episode_title: "集名" },
  },
  {
    label: "文件规格",
    tokens: {
      resolution: "分辨率",
      video_codec: "视频编码",
      hdr: "HDR",
      bit_depth: "位深",
      audio: "音轨",
    },
  },
  {
    label: "来源",
    tokens: {
      media_source: "片源",
      release_group: "发布组",
      site: "站点",
      release_name: "原始文件名",
    },
  },
];

const NAMING_FIELDS = [
  {
    key: "naming_entry_dir" as const,
    label: "条目目录",
    note: "电影与剧集共用",
    fallback: "{title} ({year})",
    tokens: COMMON_TOKENS,
  },
  {
    key: "naming_movie_file" as const,
    label: "电影文件名",
    note: "",
    fallback: "{title} ({year})",
    tokens: [...COMMON_TOKENS, ...FILE_ATTR_TOKENS],
  },
  {
    key: "naming_season_dir" as const,
    label: "季目录",
    note: "",
    fallback: "Season {season:02d}",
    tokens: [...COMMON_TOKENS, "season", "season_name"],
  },
  {
    key: "naming_episode_file" as const,
    label: "剧集文件名",
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

/** 预览样例：一部电影 + 一集剧集，字段齐全便于看清每个占位符的效果。 */
const SAMPLE_MOVIE = {
  title: "沙丘：第二部",
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
const SAMPLE_EPISODE = {
  title: "风筝",
  original_title: "风筝",
  english_title: "Kite",
  year: 2017,
  tmdb_id: 68035,
  imdb_id: "tt6952510",
  douban_id: "26340419",
  season: 1,
  season_name: "第 1 季",
  episode: 3,
  episode_title: "延安来的姑娘",
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

/** 前端侧轻校验：与后端同口径，只为即时反馈；能否保存以后端返回为准。 */
function templateError(template: string, allowed: string[]): string | null {
  if (!template.trim()) return null; // 空 = 用默认模板
  if (/[\\/]/.test(template)) return "不能包含路径分隔符（目录层级是固定的）";
  const used = [...template.matchAll(TOKEN_RE)].map((m) => m[1]);
  const unknown = used.filter((t) => !allowed.includes(t));
  if (unknown.length) return `不可用的占位符：${unknown.map((t) => `{${t}}`).join("、")}`;
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
  const [focused, setFocused] = useState<string>("naming_episode_file");
  const refs = useRef<Record<string, HTMLInputElement | null>>({});

  const errors = NAMING_FIELDS.map((f) => templateError(setting[f.key], f.tokens));
  const valid = errors.every((e) => e === null);

  const tpl = (key: (typeof NAMING_FIELDS)[number]["key"]) =>
    setting[key].trim() || NAMING_FIELDS.find((f) => f.key === key)!.fallback;

  const moviePath = valid
    ? `${renderTemplate(tpl("naming_entry_dir"), SAMPLE_MOVIE)}/${renderTemplate(
        tpl("naming_movie_file"),
        SAMPLE_MOVIE,
      )}.mkv`
    : "";
  const episodePath = valid
    ? `${renderTemplate(tpl("naming_entry_dir"), SAMPLE_EPISODE)}/${renderTemplate(
        tpl("naming_season_dir"),
        SAMPLE_EPISODE,
      )}/${renderTemplate(tpl("naming_episode_file"), SAMPLE_EPISODE)}.mkv`
    : "";

  const insertToken = (token: string) => {
    const key = focused;
    const field = NAMING_FIELDS.find((f) => f.key === key);
    if (!field) return;
    const input = refs.current[key];
    const current = setting[field.key] || field.fallback;
    const start = input?.selectionStart ?? current.length;
    const end = input?.selectionEnd ?? start;
    const next = `${current.slice(0, start)}{${token}}${current.slice(end)}`;
    patch({ [field.key]: next } as Partial<ScrapeSetting>);
    window.requestAnimationFrame(() => {
      const el = refs.current[key];
      if (!el) return;
      el.focus();
      const caret = start + token.length + 2;
      el.setSelectionRange(caret, caret);
    });
  };

  const focusedField = NAMING_FIELDS.find((f) => f.key === focused) ?? NAMING_FIELDS[3];

  return (
    <Card
      title="命名模板"
      overriddenBy={overriddenBy?.(NAMING_FIELDS.map((f) => f.key))}
      shell={shellFor?.(
        "命名模板",
        NAMING_FIELDS.map((f) => f.key),
      )}
      desc="整理与入库的目录/文件命名。留空即使用默认模板；字段缺失时会连同相邻括号自动收缩。目录层级固定为「条目目录 / 季目录 / 文件」，不可自定义。"
    >
      {NAMING_FIELDS.map((field, i) => (
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
            value={setting[field.key]}
            onFocus={() => setFocused(field.key)}
            onChange={(e) => patch({ [field.key]: e.target.value } as Partial<ScrapeSetting>)}
            className={`${INPUT_CLASS} w-full font-mono ${
              errors[i] ? "border-[var(--danger)]/55" : ""
            }`}
          />
          {errors[i] && <p className="mt-1.5 text-caption text-[var(--danger)]">{errors[i]}</p>}
        </div>
      ))}

      <div className="mt-4">
        <p className="mb-1.5 text-micro uppercase tracking-widest text-[var(--text-faint)]">
          可用占位符（点击插入到「{focusedField.label}」）
        </p>
        <div className="flex flex-col gap-2">
          {TOKEN_GROUPS.map((group) => {
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
            站点与原始文件名只有经本系统入库的文件才有；存量扫描发现的文件这两项为空，会自动收缩。
          </p>
        )}
      </div>

      <div className="mt-4 overflow-hidden rounded-xl border border-white/[0.08]">
        <div className="flex items-center justify-between bg-white/[0.04] px-3.5 py-2">
          <span className="text-micro uppercase tracking-widest text-[var(--text-faint)]">
            实时预览
          </span>
          <span className={`text-caption ${valid ? "text-[var(--ok)]" : "text-[var(--danger)]"}`}>
            {valid ? "✓ 模板有效" : "✕ 模板有误"}
          </span>
        </div>
        {valid && (
          <div className="flex flex-col gap-3 overflow-x-auto px-3.5 py-3">
            <div>
              <p className="mb-1 text-caption text-[var(--text-faint)]">
                电影 · 沙丘：第二部（2024）· 2160p DV TrueHD Atmos · BluRay FRDS
              </p>
              <p className="whitespace-nowrap font-mono text-sub leading-relaxed">
                <span className="text-[var(--text-faint)]">/media/电影/</span>
                <span className="text-[var(--accent)]">{moviePath}</span>
              </p>
            </div>
            <div>
              <p className="mb-1 text-caption text-[var(--text-faint)]">
                剧集 · 风筝（2017）第 1 季第 3 集 · 1080p SDR AAC · WEB-DL CHDWEB
              </p>
              <p className="whitespace-nowrap font-mono text-sub leading-relaxed">
                <span className="text-[var(--text-faint)]">/media/剧集/</span>
                <span className="text-[var(--accent)]">{episodePath}</span>
              </p>
            </div>
          </div>
        )}
      </div>

      <div className="mt-3 flex flex-wrap items-center gap-2.5">
        <button
          type="button"
          onClick={() =>
            patch({
              naming_entry_dir: "",
              naming_movie_file: "",
              naming_season_dir: "",
              naming_episode_file: "",
            })
          }
          className="btn-glass rounded-lg px-3 py-1.5 text-sub"
        >
          恢复默认模板
        </button>
        <span className="text-caption text-[var(--text-faint)]">
          同条目多版本会自动追加「 - 版本标签」后缀，无需写进模板
        </span>
      </div>
    </Card>
  );
}

/* ------------------------------------------------------------------ */
/* 目录写入                                                            */
/* ------------------------------------------------------------------ */

function Toggle({
  checked,
  onChange,
  disabled,
}: {
  checked: boolean;
  onChange: (next: boolean) => void;
  disabled?: boolean;
}) {
  return (
    <label className="relative inline-block h-[22px] w-[38px] shrink-0">
      <input
        type="checkbox"
        className="peer absolute inset-0 z-10 m-0 cursor-pointer opacity-0 disabled:cursor-default"
        checked={checked}
        disabled={disabled}
        onChange={(e) => onChange(e.target.checked)}
      />
      <span
        className={`absolute inset-0 rounded-full transition-colors peer-disabled:opacity-35 ${
          checked ? "bg-[var(--accent-2)]" : "bg-white/[0.12]"
        }`}
      />
      <span
        className={`pointer-events-none absolute top-0.5 size-[18px] rounded-full bg-[#e8ecf4] transition-transform ${
          checked ? "translate-x-[18px]" : "translate-x-0.5"
        }`}
      />
    </label>
  );
}

const MIRROR_ROWS = [
  {
    key: "mirror_images" as const,
    label: "条目图片",
    hint: "poster.jpg / fanart.jpg / clearlogo.png / 季海报",
  },
  {
    key: "mirror_nfo" as const,
    label: "NFO 元数据",
    hint: "tvshow.nfo / movie.nfo / 分集 NFO，含 tmdbid 精确身份",
  },
  {
    key: "mirror_episode_thumbs" as const,
    label: "分集剧照",
    hint: "每集一张 -thumb.jpg，长剧集写入量最大，可单独关闭",
  },
];

function MirrorTab({
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
  return (
    <Card
      title="媒体目录写入"
      overriddenBy={overriddenBy?.(MIRROR_ROWS.map((r) => r.key))}
      shell={shellFor?.(
        "媒体目录写入",
        MIRROR_ROWS.map((r) => r.key),
      )}
      desc="把刮削成果写入媒体目录，反哺 Emby / Jellyfin / Kodi（文件名遵循播放器规范）。只增不删除；已存在的 NFO 绝不覆盖。每个媒体库还有一个总开关，关掉则该库三项都不写。"
    >
      <div className="divide-y divide-white/[0.06]">
        {MIRROR_ROWS.map((row) => (
          <div key={row.key} className="flex items-center justify-between gap-4 py-2.5">
            <div>
              <span className="text-ui font-medium">{row.label}</span>
              <span className="mt-0.5 block max-w-[46ch] text-caption text-[var(--text-faint)]">
                {row.hint}
              </span>
            </div>
            <Toggle
              checked={setting[row.key]}
              onChange={(next) => patch({ [row.key]: next } as Partial<ScrapeSetting>)}
            />
          </div>
        ))}
      </div>
    </Card>
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
/** 分节标签 + 该节的卡片。标签不可点，只做视觉分组；全局页与库设置页共用。 */
export function ScrapeSection({
  label,
  children,
}: {
  label: string;
  children: React.ReactNode;
}) {
  return (
    <div className="space-y-2">
      <p className="text-micro uppercase tracking-widest text-[var(--text-faint)]">{label}</p>
      {children}
    </div>
  );
}

export function useScrapeChipOptions() {
  const [languages, setLanguages] = useState<LanguageOption[]>([]);
  const [countries, setCountries] = useState<CountryOption[]>([]);

  useEffect(() => {
    // 全量表拉不到不阻断（面板回落只显示常用项）
    listLanguageOptions()
      .then(setLanguages)
      .catch(() => {});
    listCountryOptions()
      .then(setCountries)
      .catch(() => {});
  }, []);

  const metaLangs = useMemo<ChipOption[]>(
    () =>
      languages
        .filter((l) => !COMMON_META_LANGS.some((c) => c.id.startsWith(`${l.code}-`)))
        .map((l) => ({ id: l.code, name: l.name || l.english_name || l.code })),
    [languages],
  );
  const imageLangs = useMemo<ChipOption[]>(
    () =>
      languages
        .filter((l) => !COMMON_IMAGE_LANGS.some((c) => c.id === l.code))
        .map((l) => ({ id: l.code, name: l.name || l.english_name || l.code })),
    [languages],
  );
  const certCountries = useMemo<ChipOption[]>(
    () =>
      countries
        .filter((c) => !COMMON_CERT_COUNTRIES.some((k) => k.id === c.code))
        .map((c) => ({ id: c.code, name: c.name })),
    [countries],
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
  return (
    <>
      <Card
        title="元数据语言"
        overriddenBy={overriddenBy?.(["language_priority"])}
        shell={shellFor?.("元数据语言", ["language_priority"])}
        desc="标题、简介、类型名等文本的语言。点选语言即加入优先级，第 1 位是主语言（决定向 TMDB 请求的语言），缺失的字段按顺序回落——回落基于已拉取的翻译数据，不产生额外请求。"
      >
        <OrderChips
          options={COMMON_META_LANGS}
          extraOptions={extraMetaLangs}
          moreLabel="语言"
          value={setting.language_priority}
          max={3}
          primaryTag="主语言"
          onChange={(next) => patch({ language_priority: next })}
        />
      </Card>
      <Card
        title="内容分级"
        overriddenBy={overriddenBy?.(["cert_country_priority"])}
        shell={shellFor?.("内容分级", ["cert_country_priority"])}
        desc="条目分级（如 PG-13、TV-MA）按顺序取第一个有数据的地区。"
      >
        <OrderChips
          options={COMMON_CERT_COUNTRIES}
          extraOptions={extraCountries}
          moreLabel="地区"
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
      需要 API Key
    </span>
  ) : status.key_invalid ? (
    <span className="rounded-full border border-[var(--danger)]/35 px-2 py-px text-micro font-normal text-[var(--danger)]">
      Key 已失效
    </span>
  ) : (
    <span className="rounded-full border border-[var(--ok)]/30 px-2 py-px text-micro font-normal text-[var(--ok)]">
      Key 已配置
    </span>
  );

  return (
    <Card
      title="图片来源"
      overriddenBy={overriddenBy?.(SOURCE_KEYS)}
      shell={shellFor?.("图片来源", SOURCE_KEYS)}
      desc="海报、背景、片名 Logo、季海报可以从多个图库挑选。TMDB 是元数据的主来源，始终开启；Fanart.tv 是社区维护的高清图库，中文片名 Logo、季海报往往比 TMDB 全。你在条目详情页手动选定的图始终优先，不受这里影响。"
    >
      {justEnabled && enabled && (
        <div className="mb-2.5 flex items-start gap-2.5 rounded-xl border border-[var(--info)]/30 bg-[var(--info)]/[0.07] px-3 py-2.5 text-caption leading-relaxed text-[var(--text-muted)]">
          <span className="text-[var(--info)]">ℹ︎</span>
          <span className="min-w-0 flex-1">
            <strong className="font-semibold text-[var(--text)]">Fanart.tv 已启用。</strong>
            保存后，之后新入库的条目会自动用上；
            <strong className="font-semibold text-[var(--text)]">
              已入库的条目需要你在媒体库执行「刷新元数据」
            </strong>
            后才会按新来源重选图片，不刷新就保持原样。
          </span>
          <button
            type="button"
            aria-label="关闭提示"
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
          <span className="block text-caption text-[var(--text-faint)]">元数据与图片的主来源</span>
        </span>
        <span className="shrink-0 rounded-full border border-white/[0.08] px-2 py-px text-micro text-[var(--text-faint)]">
          始终开启
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
                  ? "Key 全站共用，在「设置 → 刮削与整理」里可以更换"
                  : "社区高清图库 · 电影按 TMDB 编号、剧集按 TVDB 编号取图（TVDB 编号从 TMDB 自动获取）"
                : "社区高清图库 · 打开开关时填一次你自己的 API Key 即可"}
            </span>
          </span>
          <button
            type="button"
            role="switch"
            aria-checked={enabled}
            aria-label="启用 Fanart.tv"
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
                Fanart.tv 拒绝了这个 Key（可能已撤销或填错），已暂停使用 Fanart 选图
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
                {status.key_invalid ? "重新填写" : "更换"}
              </button>
            )}
          </div>
        )}
      </div>

      <p className="mb-1.5 mt-4 flex flex-wrap items-baseline gap-2 text-sub font-semibold">
        来源顺序
        <span className="text-caption font-normal text-[var(--text-faint)]">
          每种图单独排，点 ⇄ 交换先后
        </span>
      </p>
      <div
        className={`overflow-hidden rounded-xl border border-white/[0.08] ${enabled ? "" : "opacity-40"}`}
      >
        {SOURCE_ROWS.map((row) => {
          const order = setting[row.key];
          const isDefault = order[0] === row.first;
          const note =
            row.key === "poster_source_order" && setting.poster_mode === "default"
              ? "海报卡是「TMDB 默认」：TMDB 只出它指定的那一张，和 Fanart 的海报按语言比"
              : row.key === "season_poster_source_order"
                ? "只对剧集生效；语言跟随海报卡"
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
                  {isDefault ? `默认 · ${row.why}` : "已调整"}
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
                aria-label={`交换${row.label}的来源先后`}
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
        <strong className="font-semibold text-[var(--text)]">先看语言，再看来源。</strong>
        每种图按自己的语言优先级（海报、背景、片名 Logo 卡里配置）逐档找；同一档语言两个来源都有图时，才按上面的来源顺序挑。所以把中文排第一，就不会因为来源顺序拿到英文图。
      </p>
    </Card>
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
  // 界面选中的画质档：显式选过就是它，没选过按已保存配置反推（后端 effective 给）
  const quality: ImageQuality = setting.image_quality || effective?.image_quality || "original";
  // 档位下拉留空的含义：全局页是环境变量，库页是全局设置。留空的实际档位只有在
  // 已保存配置本身就是「自定义」时才等于 effective 里的值（选了预设时 effective
  // 是预设的档位，不是留空会落到的值），其它时候不写数字，免得说错
  const fallbackKnown = effective?.image_quality === "custom";
  const inheritLabel = (fallback: string) => {
    const base = inheritsGlobal ? "跟随全局" : "跟随环境变量";
    return fallbackKnown && fallback ? `${base}（${fallback}）` : base;
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
    IMAGE_SIZE_FIELDS.every(
      (field) => (setting[field.key] || effective[field.key]) === effective[field.key],
    );
  const estimateText = (id: ImageQuality): string | null => {
    if (!estimate) return null;
    if (id !== "custom") return `按当前媒体库估算${formatEstimate(estimate.presets[id])}`;
    if (quality !== "custom") return null;
    return customEstimateFresh
      ? `按当前媒体库估算${formatEstimate(estimate.current_bytes)}`
      : "保存后按所选档位估算";
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
        title="海报"
        overriddenBy={overriddenBy?.(["poster_mode", "poster_language_priority"])}
        shell={shellFor?.("海报", ["poster_mode", "poster_language_priority"])}
        desc="海报和文本一样有语言：中文版、原版、无文字干净版是不同的候选图。你在条目详情页手动选定的图始终优先，不受这里影响。"
      >
        <div className="grid gap-2 md:grid-cols-2">
          {(
            [
              {
                id: "default",
                title: "TMDB 默认",
                desc: "与发现页看到的一致，订阅前后海报不跳变（默认）",
              },
              {
                id: "language",
                title: "按语言优先级挑选",
                desc: "逐级取第一档有候选图的语言，档内按分辨率与票数排序",
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
            options={COMMON_IMAGE_LANGS}
            extraOptions={extraImageLangs}
            moreLabel="语言"
            value={setting.poster_language_priority}
            max={4}
            primaryTag="首选"
            onChange={(next) => patch({ poster_language_priority: next })}
          />
          {setting.poster_mode === "default" && setting.fanart_enabled && (
            <p className="mt-2 text-caption leading-relaxed text-[var(--text-faint)]">
              已启用 Fanart.tv：TMDB 默认的那张海报会和 Fanart 的海报按上面的语言优先级比较，Fanart
              有更靠前语言的海报时才会换掉它。季海报同样按这个语言优先级挑。
            </p>
          )}
        </div>
      </Card>
      <Card
        title="背景图（fanart）"
        overriddenBy={overriddenBy?.(["backdrop_language_priority"])}
        shell={shellFor?.("背景图（fanart）", ["backdrop_language_priority"])}
        desc="铺在详情页全屏的沉浸底图。「无文字」是没有烧录任何片名文字的干净图——排第 1 位即无文字优先；想要带片名 logo 的横图，把语言排到前面。"
      >
        <OrderChips
          options={COMMON_IMAGE_LANGS}
          extraOptions={extraImageLangs}
          moreLabel="语言"
          value={setting.backdrop_language_priority}
          max={4}
          primaryTag="首选"
          onChange={(next) => patch({ backdrop_language_priority: next })}
        />
      </Card>
      <Card
        title="片名 Logo"
        overriddenBy={overriddenBy?.(["logo_language_priority"])}
        shell={shellFor?.("片名 Logo", ["logo_language_priority"])}
        desc="详情页、首页大图上叠在背景图上的片名字标（透明底）。按顺序逐档找第一张有图的语言；全部落空就不显示 Logo，改为显示文字标题。"
      >
        <OrderChips
          options={COMMON_IMAGE_LANGS}
          extraOptions={extraImageLangs}
          moreLabel="语言"
          value={setting.logo_language_priority}
          max={4}
          primaryTag="首选"
          onChange={(next) => patch({ logo_language_priority: next })}
        />
      </Card>
      <Card
        title="最低分辨率门槛"
        overriddenBy={overriddenBy?.(["poster_min_width", "backdrop_min_width"])}
        shell={shellFor?.("最低分辨率门槛", ["poster_min_width", "backdrop_min_width"])}
        desc="管的是「选哪张图」：低于门槛的候选图不选，候选全部不达标时自动放宽。图片存多大由下面的「本地图片画质」决定。"
      >
        <div className="flex flex-wrap items-center gap-x-4 gap-y-2.5 text-sub text-[var(--text-muted)]">
          {(
            [
              ["poster_min_width", "海报"],
              ["backdrop_min_width", "背景"],
            ] as const
          ).map(([key, label]) => (
            <span key={key} className="flex items-center gap-1.5">
              {label} ≥
              <input
                type="number"
                min={0}
                step={100}
                className={`${INPUT_CLASS} w-24 tabular-nums`}
                value={setting[key]}
                onChange={(e) => patch({ [key]: Number(e.target.value) || 0 })}
              />
              {/* 0 在输入框里看不出是"不限制"还是"没填"，补一句 */}
              {setting[key] === 0 && (
                <span className="text-caption text-[var(--text-faint)]">不限制</span>
              )}
            </span>
          ))}
        </div>
      </Card>
      <Card
        title="本地图片画质"
        overriddenBy={overriddenBy?.(IMAGE_QUALITY_KEYS)}
        shell={shellFor?.("本地图片画质", IMAGE_QUALITY_KEYS)}
        desc="刮削时存到本地的图片有多大。各设备看图时由服务端从这份本地图按需缩小，所以这里只决定「最清楚能到多清楚」。改了画质，存量图片在媒体库「刷新元数据」后按新画质更新。"
      >
        <div className="grid gap-2 md:grid-cols-2">
          {IMAGE_QUALITY_OPTIONS.map((option) => {
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
            {IMAGE_SIZE_FIELDS.map((field) => (
              <label key={field.key} className="flex flex-col gap-1">
                <span className="text-caption text-[var(--text-muted)]">{field.label}</span>
                <select
                  className={INPUT_CLASS}
                  value={setting[field.key]}
                  onChange={(e) => patch({ [field.key]: e.target.value } as Partial<ScrapeSetting>)}
                >
                  <option value="">{inheritLabel(effective?.[field.key] ?? "")}</option>
                  {field.sizes.map((size) => (
                    <option key={size} value={size}>
                      {size === "original" ? "original（原图）" : size}
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
  const toast = useToast();
  const [view, setView] = useState<ScrapeConfigView | null>(null);
  const [setting, setSetting] = useState<ScrapeSetting | null>(null);
  const chipOptions = useScrapeChipOptions();
  // 各库的覆盖情况：卡片上标「N 个库已覆盖」，避免"在全局改了不生效"的困惑
  const [libraryOverrides, setLibraryOverrides] = useState<
    { name: string; keys: string[] }[]
  >([]);
  // 展开的卡片标题（同时只开一张）；默认全收起——折叠头已经把当前值摊出来了，
  // 一屏能扫完全站配置（用户决策 2026-08-30：与库设置页形态完全一致）
  const [open, setOpen] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [dirty, setDirty] = useState(false);
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
      setSetting({
        ...config.setting,
        language_priority: config.setting.language_priority.length
          ? config.setting.language_priority
          : config.effective.language_priority,
      });
      setDirty(false);
    } catch (err) {
      setError(err instanceof Error ? err.message : "加载失败，请重试");
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
      // 全局页没有"跟随/覆盖"这个静默态（它就是被跟随的那一层），折叠头只报
      // 当前值；点亮与否交给「N 个库已覆盖」徽标表达
      customized: false,
      // 画质没选过（空串）时按已保存配置反推的那一档来说，与卡片里选中的一致
      status: setting
        ? describeScrapeValues(keys, {
            ...setting,
            image_quality: setting.image_quality || view?.effective.image_quality || "",
          })
        : "",
    }),
    [open, setting, view],
  );

  const overriddenBy = useCallback(
    (keys: (keyof ScrapeSetting)[]) =>
      libraryOverrides
        .filter((entry) => keys.some((key) => entry.keys.includes(key)))
        .map((entry) => entry.name),
    [libraryOverrides],
  );

  const patch = useCallback((changes: Partial<ScrapeSetting>) => {
    setSetting((current) => (current ? { ...current, ...changes } : current));
    setDirty(true);
  }, []);

  const save = useCallback(async () => {
    if (!setting) return;
    setSaving(true);
    try {
      const config = await saveScrapeConfig(setting);
      setView(config);
      setSetting(config.setting);
      setDirty(false);
      // 估算里「自定义」那一档按已保存配置算，保存后重取
      loadEstimate();
      toast.success("已保存。语言与图片对存量条目生效需在媒体库执行整库刷新");
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "保存失败，请重试");
    } finally {
      setSaving(false);
    }
  }, [setting, toast, loadEstimate]);

  if (error) {
    return (
      <div className="rounded-xl bg-white/[0.03] px-4 py-6 text-center text-ui text-[var(--text-muted)]">
        {error}
        <button type="button" className="btn-glass ml-3 px-3 py-1.5 text-sub" onClick={load}>
          重试
        </button>
      </div>
    );
  }
  if (!setting) {
    return (
      <p className="flex items-center gap-2.5 rounded-xl bg-white/[0.03] px-4 py-5 text-ui text-[var(--text-muted)]">
        <BrandLoader className="size-5" />
        正在加载刮削配置…
      </p>
    );
  }

  return (
    <div className="space-y-5">
      {/* 「可按库覆盖」这件事在分区顶部统一说一句：P4 之后所有字段都能按库
          覆盖，逐卡贴徽标不区分任何东西，只是噪音（设计文档 §14.5） */}
      <p className="text-sub leading-relaxed text-[var(--text-muted)]">
        全站默认的刮削口味。
        <strong className="font-medium text-[var(--text)]">任意一项</strong>
        都可以在媒体库的「编辑库 → 刮削设置」里单独覆盖，没被覆盖的库跟随这里。
      </p>

      {/* 分节 + 手风琴卡片：与「编辑库 → 刮削设置」同一套结构与控件。
          分节顺序沿用刮削管线的先后，只为读起来顺——四组之间没有依赖，
          所以不编号（编号会把并列分组伪装成必须按序完成的向导）。 */}
      <ScrapeSection label="元数据">
        <MetaTab
          setting={setting}
          patch={patch}
          extraMetaLangs={chipOptions.metaLangs}
          extraCountries={chipOptions.certCountries}
          overriddenBy={overriddenBy}
          shellFor={shellFor}
        />
      </ScrapeSection>

      <ScrapeSection label="图片">
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

      <ScrapeSection label="命名与整理">
        <NamingTab setting={setting} patch={patch} overriddenBy={overriddenBy} shellFor={shellFor} />
      </ScrapeSection>

      <ScrapeSection label="目录写入">
        <MirrorTab setting={setting} patch={patch} overriddenBy={overriddenBy} shellFor={shellFor} />
      </ScrapeSection>

      <div className="flex items-center justify-between gap-3">
        <p className="text-caption text-[var(--text-faint)]">
          保存后对新刮削立即生效；存量条目在媒体库页执行「刷新元数据」后按新配置更新。
        </p>
        <button
          type="button"
          disabled={!dirty || saving}
          onClick={save}
          className="btn-accent shrink-0 rounded-full px-5 py-2 text-ui font-semibold disabled:opacity-50"
        >
          {saving ? "保存中…" : "保存"}
        </button>
      </div>
    </div>
  );
}
