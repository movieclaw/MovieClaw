import { request } from "@/lib/http";

/** 后端统一响应信封（见 movieclaw_api.schemas.response.ApiResponse） */
interface ApiEnvelope<T> {
  success: boolean;
  code: string;
  message: string;
  data: T;
}

async function unwrap<T>(promise: Promise<ApiEnvelope<T>>): Promise<T> {
  return (await promise).data;
}

/** 刮削与整理配置（镜像后端 MetadataScrapeSetting；空值/空列表 = 跟随环境变量）。 */
export interface ScrapeSetting {
  language_priority: string[];
  cert_country_priority: string[];
  poster_mode: "default" | "language";
  poster_language_priority: string[];
  backdrop_language_priority: string[];
  poster_min_width: number;
  backdrop_min_width: number;
  poster_size: string;
  backdrop_size: string;
  still_size: string;
  /** 演职员头像档位；空 = 跟随环境变量 */
  profile_size: string;
  /**
   * 本地图片画质（docs/design/image-sizing.md §8.1）。选了预设时上面四个档位字段被忽略；
   * custom 或空串（没选过）时逐项「设置值 > 环境变量」。
   */
  image_quality: ImageQuality | "";
  /** 片名 Logo 语言优先级（token 同海报/背景：meta / orig / null / 语言码） */
  logo_language_priority: string[];
  /**
   * 自动选图是否使用 Fanart.tv（docs/design/image-sources.md）。需先配置 Key——
   * Key 是凭据，不在这份配置里，走 getFanartStatus / saveFanartKey。
   */
  fanart_enabled: boolean;
  /** 各类图的来源顺序：只在同一档语言两个来源都有图时起作用（语言先于来源） */
  poster_source_order: ImageSource[];
  backdrop_source_order: ImageSource[];
  logo_source_order: ImageSource[];
  season_poster_source_order: ImageSource[];
  /** 命名模板；空串 = 用内置默认（即模板化之前的行为） */
  naming_entry_dir: string;
  naming_movie_file: string;
  naming_season_dir: string;
  naming_episode_file: string;
  /** 目录写入细项（库上的 write_media_assets 是总闸） */
  mirror_images: boolean;
  mirror_nfo: boolean;
  mirror_episode_thumbs: boolean;
}

/** 可按库覆盖的字段（与后端 scrape_config.LIBRARY_OVERRIDABLE 一致）。
 *
 * 解析路径分两类（docs/design/scrape-customization.md §14.4）：
 * - 条目态：产物挂全局条目（一份 media_metadata、按条目 id 存一份的图片），
 *   按条目的**刮削归属库**生效；
 * - 目录态：产物落在各库自己的目录树里，按**文件所在库**生效。
 * 界面上不区分这两类（用户只关心"这个库怎么刮"），但文案要说清楚生效范围。 */
export const ITEM_SCOPED_KEYS = [
  "language_priority",
  "cert_country_priority",
  "poster_mode",
  "poster_language_priority",
  "backdrop_language_priority",
  "poster_min_width",
  "backdrop_min_width",
  "poster_size",
  "backdrop_size",
  "still_size",
  "profile_size",
  "image_quality",
  "logo_language_priority",
  "fanart_enabled",
  "poster_source_order",
  "backdrop_source_order",
  "logo_source_order",
  "season_poster_source_order",
] as const;

export const DIR_SCOPED_KEYS = [
  "naming_entry_dir",
  "naming_movie_file",
  "naming_season_dir",
  "naming_episode_file",
  "mirror_images",
  "mirror_nfo",
  "mirror_episode_thumbs",
] as const;

export const LIBRARY_OVERRIDABLE_KEYS = [...ITEM_SCOPED_KEYS, ...DIR_SCOPED_KEYS] as const;

export type LibraryOverridableKey = (typeof LIBRARY_OVERRIDABLE_KEYS)[number];

/** "跟随环境变量"字段当前的生效值（用于展示"跟随中：xxx"）。 */
export interface ScrapeEffective {
  language_priority: string[];
  cert_country_priority: string[];
  poster_size: string;
  backdrop_size: string;
  still_size: string;
  profile_size: string;
  /** 界面该选中的画质档：显式选过就是它；没选过时按四个档位反推（等于某个预设就是它，否则 custom） */
  image_quality: ImageQuality;
}

/** 图片来源：TMDB 始终在，Fanart.tv 可选。 */
export type ImageSource = "tmdb" | "fanart";

/** 本地图片画质的四个选项；custom = 四个档位逐项指定。 */
export type ImageQuality = "original" | "standard" | "compact" | "custom";
export type ImageQualityPreset = Exclude<ImageQuality, "custom">;

/**
 * 画质预设 → (海报, 背景, 剧照, 头像) 档位，与后端 services/scrape_config.py 的
 * IMAGE_QUALITY_PRESETS 一致。前端用它在「切到自定义」时把当前预设的档位填进下拉，
 * 自定义从用户刚才看到的那一档起步，而不是一排空值。
 */
export const IMAGE_QUALITY_PRESETS: Record<
  ImageQualityPreset,
  { poster_size: string; backdrop_size: string; still_size: string; profile_size: string }
> = {
  original: {
    poster_size: "original",
    backdrop_size: "original",
    still_size: "original",
    profile_size: "original",
  },
  standard: {
    poster_size: "w780",
    backdrop_size: "original",
    still_size: "original",
    profile_size: "h632",
  },
  compact: {
    poster_size: "w500",
    backdrop_size: "w1280",
    still_size: "w300",
    profile_size: "w185",
  },
};

/** 本地图片画质的磁盘估算（按当前媒体库的图片张数 × 各档位单张均值，只是量级参考）。 */
export interface ImageStorageEstimate {
  counts: { posters: number; backdrops: number; logos: number; stills: number; people: number };
  /** 各预设档的估算字节数 */
  presets: Record<ImageQualityPreset, number>;
  /** 已保存配置的生效画质档 */
  current_quality: ImageQuality;
  /** 按已保存配置生效档位的估算字节数（自定义也算得出来） */
  current_bytes: number;
}

export interface ScrapeConfigView {
  setting: ScrapeSetting;
  effective: ScrapeEffective;
}

export interface LanguageOption {
  code: string;
  name: string;
  english_name: string;
}

export interface CountryOption {
  code: string;
  name: string;
}

export function getScrapeConfig(): Promise<ScrapeConfigView> {
  return unwrap(request<ApiEnvelope<ScrapeConfigView>>("/scrape/config"));
}

export function saveScrapeConfig(payload: ScrapeSetting): Promise<ScrapeConfigView> {
  return unwrap(
    request<ApiEnvelope<ScrapeConfigView>>("/scrape/config", {
      method: "PUT",
      body: JSON.stringify(payload),
    }),
  );
}

/** 本地图片画质估算（管理员）；设置页每一档旁的「约 X GB」。 */
export function getImageStorageEstimate(): Promise<ImageStorageEstimate> {
  return unwrap(request<ApiEnvelope<ImageStorageEstimate>>("/scrape/storage-estimate"));
}

export function listLanguageOptions(): Promise<LanguageOption[]> {
  return unwrap(request<ApiEnvelope<LanguageOption[]>>("/scrape/language-options"));
}

export function listCountryOptions(): Promise<CountryOption[]> {
  return unwrap(request<ApiEnvelope<CountryOption[]>>("/scrape/country-options"));
}

/**
 * Fanart.tv 的 Key 状态（不含明文）。Key 全站一份：用户在第一次用 Fanart 的地方
 * 就地填一次（设置开关、库设置、换图弹层），之后到处可用。
 */
export interface FanartStatus {
  configured: boolean;
  /** 刮削时被 Fanart.tv 拒绝过（401）：已暂停使用，需要重新填写 */
  key_invalid: boolean;
  /** 末四位，展示「••••abcd」用 */
  key_hint: string;
}

export function getFanartStatus(): Promise<FanartStatus> {
  return unwrap(request<ApiEnvelope<FanartStatus>>("/scrape/fanart"));
}

/** 验证并保存 Key：后端先向 Fanart.tv 真发一次请求，通过才保存；不通过抛 HttpError（中文原因）。 */
export function saveFanartKey(apiKey: string): Promise<FanartStatus> {
  return unwrap(
    request<ApiEnvelope<FanartStatus>>("/scrape/fanart", {
      method: "PUT",
      body: JSON.stringify({ api_key: apiKey }),
    }),
  );
}

/** 发现页院线地区（页脚就地设置）。 */
export interface DiscoverRegionView {
  region: string;
  can_edit: boolean;
}

export function getDiscoverRegion(): Promise<DiscoverRegionView> {
  return unwrap(request<ApiEnvelope<DiscoverRegionView>>("/discover/region"));
}

export function setDiscoverRegion(region: string): Promise<DiscoverRegionView> {
  return unwrap(
    request<ApiEnvelope<DiscoverRegionView>>("/discover/region", {
      method: "PUT",
      body: JSON.stringify({ region }),
    }),
  );
}
