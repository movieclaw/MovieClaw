import { request } from "@/lib/http";
import { cachedImageUrl } from "@/lib/image-proxy";
import type { DiscoveryFilters } from "@/lib/discovery-filters";
import type {
  MediaLibraryLink,
  MediaLibraryStatus,
  MediaItem,
  MediaRowData,
  MediaSource,
  MediaType,
} from "@/lib/media-types";

/** 后端统一响应信封（见 movieclaw_api.schemas.response.ApiResponse）。 */
interface ApiEnvelope<T> {
  success: boolean;
  code: string;
  message: string;
  data: T;
}

async function unwrap<T>(promise: Promise<ApiEnvelope<T>>): Promise<T> {
  return (await promise).data;
}

// ---------------------------------------------------------------------------
// Discover 领域 DTO（snake_case）→ 前端渲染模型（camelCase）
// ---------------------------------------------------------------------------

interface MediaLibraryStatusDto {
  media_item_id: number;
  library_count: number;
  file_count: number;
}

interface MediaLibraryLinkDto {
  library_id: number;
  library_name: string;
  media_item_id: number;
}

export interface DiscoveredTitleDto {
  title_ref: string;
  provider: MediaSource;
  external_id: string;
  media_type: MediaType | null;
  title: string;
  original_title: string;
  release_year: number | null;
  provider_rating: number;
  genres: string[];
  extent_label: string;
  overview: string;
  poster_url: string;
  backdrop_url: string | null;
  library_status?: MediaLibraryStatusDto | null;
}

interface DiscoveryCollectionDto {
  collection_ref: string;
  provider: MediaSource;
  media_type: MediaType;
  name: string;
  description: string;
  is_ranked: boolean;
  default_limit: number;
  supports_full_listing: boolean;
}

interface DiscoveryCollectionTitlesDto {
  collection: DiscoveryCollectionDto;
  titles: DiscoveredTitleDto[];
  returned_count: number;
  truncated: boolean;
  page: number;
  total_pages: number;
  total_results: number;
  has_more: boolean;
}

interface DiscoveryFilterOptionsDto {
  media_type: MediaType;
  genres: Array<{ id: number; name: string }>;
}

interface DiscoveryTitlePageDto {
  media_type: MediaType;
  titles: DiscoveredTitleDto[];
  page: number;
  total_pages: number;
  total_results: number;
  has_more: boolean;
}

type DiscoveryPresentation = "hero" | "ranked-row" | "poster-row";

interface DiscoveryPageDto {
  provider: MediaSource;
  media_type: MediaType;
  sections: Array<{
    collection_ref: string;
    title: string;
    presentation: DiscoveryPresentation;
    preview_limit: number;
    supports_full_listing: boolean;
  }>;
}

interface TitleSearchProviderStatusDto {
  provider: MediaSource;
  success: boolean;
  result_count: number;
  message: string | null;
}

export interface TitleSearchDto {
  query: string;
  titles: DiscoveredTitleDto[];
  providers: TitleSearchProviderStatusDto[];
  history_id: number | null;
}

export interface MediaSearchItemDto {
  id: string;
  source: MediaSource;
  title: string;
  year?: number | null;
  type?: MediaType | null;
  rating: number;
  poster_url: string;
}

interface MediaCastMemberDto {
  name: string;
  role: string | null;
  avatar_url: string | null;
  tmdb_person_id: number | null;
}

interface DiscoveredTitleMetadataDto {
  directors: string[];
  director_credits: MediaCastMemberDto[];
  cast: MediaCastMemberDto[];
  country: string;
  language: string;
  released: string;
  network: string | null;
  aliases: string[];
  source_url: string | null;
  /** 国际英文名；豆瓣条目没有 */
  english_title?: string | null;
}

interface MediaImageDto {
  preview_url: string;
  full_url: string;
  width: number;
  height: number;
}

interface MediaVideoDto {
  key: string;
  name: string;
  kind: string;
  thumbnail_url: string;
  embed_url: string;
  watch_url: string;
}

interface DiscoveredTitleDetailsDto {
  title: DiscoveredTitleDto;
  metadata: DiscoveredTitleMetadataDto;
  backdrop_original_url: string | null;
  videos?: MediaVideoDto[];
  backdrops: MediaImageDto[];
  posters: MediaImageDto[];
  collection: {
    id: string;
    name: string;
    titles: DiscoveredTitleDto[];
  } | null;
  recommendations: DiscoveredTitleDto[];
  library_links?: MediaLibraryLinkDto[];
}

interface DiscoveredPersonDetailsDto {
  tmdb_person_id: number;
  name: string;
  avatar_url: string | null;
  titles: DiscoveredTitleDto[];
}

export interface DiscoveryPageSection {
  collectionRef: string;
  title: string;
  presentation: DiscoveryPresentation;
  previewLimit: number;
  supportsFullListing: boolean;
}

export interface DiscoveryPageData {
  provider: MediaSource;
  mediaType: MediaType;
  sections: DiscoveryPageSection[];
}

export interface DiscoveredCollectionData {
  collectionRef: string;
  provider: MediaSource;
  mediaType: MediaType;
  name: string;
  isRanked: boolean;
  supportsFullListing: boolean;
  items: MediaItem[];
  returnedCount: number;
  truncated: boolean;
  page: number;
  totalPages: number;
  totalResults: number;
  hasMore: boolean;
}

export interface DiscoveryGenre {
  id: number;
  name: string;
}

export interface FilteredDiscoveryData {
  mediaType: MediaType;
  items: MediaItem[];
  page: number;
  totalPages: number;
  totalResults: number;
  hasMore: boolean;
}

export interface MediaSearchItem {
  /** 下一步读取详情时原样传回的稳定引用。旧历史快照没有该字段。 */
  titleRef?: string;
  id: string;
  source: MediaSource;
  title: string;
  year?: number;
  type?: MediaType;
  rating: number;
  posterUrl: string;
}

export interface TitleSearchProviderStatus {
  provider: MediaSource;
  success: boolean;
  resultCount: number;
  message?: string;
}

export interface TitleSearchData {
  items: MediaSearchItem[];
  providers: TitleSearchProviderStatus[];
  historyId?: number;
}

function toLibraryStatus(dto: MediaLibraryStatusDto | null | undefined): MediaLibraryStatus | null {
  if (!dto) return null;
  return {
    mediaItemId: dto.media_item_id,
    libraryCount: dto.library_count,
    fileCount: dto.file_count,
  };
}

function toLibraryLink(dto: MediaLibraryLinkDto): MediaLibraryLink {
  return {
    libraryId: dto.library_id,
    libraryName: dto.library_name,
    mediaItemId: dto.media_item_id,
  };
}

/** 片单与详情中的条目字段完整；空值兜底只覆盖上游偶发缺失，不猜来源身份。 */
function toItem(dto: DiscoveredTitleDto): MediaItem {
  return {
    titleRef: dto.title_ref,
    id: dto.external_id,
    source: dto.provider,
    type: dto.media_type ?? "movie",
    title: dto.title,
    originalTitle: dto.original_title,
    year: dto.release_year ?? 0,
    rating: dto.provider_rating,
    genres: dto.genres,
    extent: dto.extent_label,
    badges: [],
    overview: dto.overview,
    posterUrl: cachedImageUrl(dto.poster_url),
    backdropUrl: dto.backdrop_url ? cachedImageUrl(dto.backdrop_url) : undefined,
    libraryStatus: toLibraryStatus(dto.library_status),
  };
}

export function toDiscoveredSearchItem(dto: DiscoveredTitleDto): MediaSearchItem {
  return {
    titleRef: dto.title_ref,
    id: dto.external_id,
    source: dto.provider,
    title: dto.title,
    year: dto.release_year ?? undefined,
    type: dto.media_type ?? undefined,
    rating: dto.provider_rating,
    posterUrl: cachedImageUrl(dto.poster_url),
  };
}

// ---------------------------------------------------------------------------
// 发现页、片单与统一搜索
// ---------------------------------------------------------------------------

/** 获取 Web 专用发现页编排；影视数据仍通过 collectionRef 从领域接口读取。 */
export async function fetchDiscoveryPage(
  mediaType: MediaType,
  provider: MediaSource = "tmdb",
  init?: RequestInit,
): Promise<DiscoveryPageData> {
  const dto = await unwrap(
    request<ApiEnvelope<DiscoveryPageDto>>(
      `/ui/discovery/${mediaType}?provider=${provider}`,
      init,
    ),
  );
  return {
    provider: dto.provider,
    mediaType: dto.media_type,
    sections: dto.sections.map((section) => ({
      collectionRef: section.collection_ref,
      title: section.title,
      presentation: section.presentation,
      previewLimit: section.preview_limit,
      supportsFullListing: section.supports_full_listing,
    })),
  };
}

/** 浏览一个片单；collectionRef 必须直接来自页面编排或 list-collections。 */
export async function browseDiscoveryCollection(
  collectionRef: string,
  limit: number,
  init?: RequestInit,
  page = 1,
): Promise<DiscoveredCollectionData> {
  const dto = await unwrap(
    request<ApiEnvelope<DiscoveryCollectionTitlesDto>>(
      `/discover/collections/${encodeURIComponent(collectionRef)}/titles?limit=${limit}&page=${page}`,
      init,
    ),
  );
  return {
    collectionRef: dto.collection.collection_ref,
    provider: dto.collection.provider,
    mediaType: dto.collection.media_type,
    name: dto.collection.name,
    isRanked: dto.collection.is_ranked,
    supportsFullListing: dto.collection.supports_full_listing,
    items: dto.titles.map(toItem),
    returnedCount: dto.returned_count,
    truncated: dto.truncated,
    page: dto.page,
    totalPages: dto.total_pages,
    totalResults: dto.total_results,
    hasMore: dto.has_more,
  };
}

export async function fetchDiscoveryGenres(
  mediaType: MediaType,
  init?: RequestInit,
): Promise<DiscoveryGenre[]> {
  const dto = await unwrap(
    request<ApiEnvelope<DiscoveryFilterOptionsDto>>(
      `/discover/filters?media_type=${mediaType}`,
      init,
    ),
  );
  return dto.genres;
}

/** 六维筛选使用 TMDB discover 原生分页，URL 参数和 API 参数保持一一对应。 */
export async function fetchFilteredDiscovery(
  mediaType: MediaType,
  filters: DiscoveryFilters,
  page: number,
  init?: RequestInit,
): Promise<FilteredDiscoveryData> {
  const params = new URLSearchParams({ media_type: mediaType, page: String(page) });
  for (const genreId of filters.genreIds) params.append("genre_ids", String(genreId));
  if (filters.originCountry) params.set("origin_country", filters.originCountry);
  if (filters.year) params.set("year", String(filters.year));
  if (filters.ratingGte !== undefined) params.set("rating_gte", String(filters.ratingGte));
  if (filters.runtimeLte) params.set("runtime_lte", String(filters.runtimeLte));
  params.set("sort", filters.sort);
  const dto = await unwrap(
    request<ApiEnvelope<DiscoveryTitlePageDto>>(`/discover/titles?${params}`, init),
  );
  return {
    mediaType: dto.media_type,
    items: dto.titles.map(toItem),
    page: dto.page,
    totalPages: dto.total_pages,
    totalResults: dto.total_results,
    hasMore: dto.has_more,
  };
}

/** 旧媒体搜索快照 DTO → 前端视图；快照在迁移前已落库，因此继续兼容。 */
export function toSearchItem(item: MediaSearchItemDto): MediaSearchItem {
  return {
    id: item.id,
    source: item.source,
    title: item.title,
    year: item.year ?? undefined,
    type: item.type ?? undefined,
    rating: item.rating,
    posterUrl: cachedImageUrl(item.poster_url),
  };
}

/** 从旧页面路由参数构造稳定引用；新的接口调用只消费此引用。 */
export function titleRef(source: MediaSource, type: MediaType, id: string): string {
  return source === "douban" ? `douban:${id}` : `tmdb:${type}:${id}`;
}

/** 把稳定片单引用转换为通用「看全部」页面地址。 */
export function collectionHref(collectionRef: string): string | undefined {
  const [provider, mediaType, ...idParts] = collectionRef.split(":");
  const collectionId = idParts.join(":");
  if (
    (provider !== "tmdb" && provider !== "douban") ||
    (mediaType !== "movie" && mediaType !== "tv") ||
    !collectionId
  ) {
    return undefined;
  }
  return `/discover/${mediaType}/collections/${provider}/${encodeURIComponent(collectionId)}`;
}

// ---------------------------------------------------------------------------
// 影视详情
// ---------------------------------------------------------------------------

export interface MediaCastMember {
  name: string;
  role?: string;
  avatarUrl?: string;
  tmdbPersonId?: number;
}

export interface MediaDetailInfo {
  directors: string[];
  directorCredits: MediaCastMember[];
  cast: MediaCastMember[];
  country: string;
  language: string;
  released: string;
  network?: string;
  aliases: string[];
  sourceUrl?: string;
  /** 国际英文名（TMDB 译名）：「搜索资源」与中文名、原名一起搜；豆瓣条目没有 */
  englishTitle?: string;
}

export interface MediaImage {
  previewUrl: string;
  fullUrl: string;
  width: number;
  height: number;
}

/** 一段预告片；播放地址由后端拼好，前端只负责内嵌与外链两种打开方式。 */
export interface MediaVideo {
  key: string;
  name: string;
  kind: string;
  thumbnailUrl: string;
  embedUrl: string;
  watchUrl: string;
}

export interface MediaDetailData {
  item: MediaItem;
  info: MediaDetailInfo;
  videos: MediaVideo[];
  backdrops: MediaImage[];
  posters: MediaImage[];
  /** 主横幅剧照的 original 原图；详情页沉浸背景的高清升级源 */
  backdropOriginalUrl?: string;
  collection?: { id: string; name: string; items: MediaItem[] };
  related: MediaItem[];
  libraryLinks: MediaLibraryLink[];
}

export interface DiscoveredPersonDetailsData {
  tmdbPersonId: number;
  name: string;
  avatarUrl: string;
  items: MediaItem[];
}

function toImage(dto: MediaImageDto): MediaImage {
  return {
    previewUrl: cachedImageUrl(dto.preview_url),
    fullUrl: cachedImageUrl(dto.full_url),
    width: dto.width,
    height: dto.height,
  };
}

/**
 * 预告片转换：封面走图片缓存（服务端回源，浏览器连不上 YouTube 也能看到卡片），
 * 播放与外链地址保持原样——它们必须由浏览器直连 YouTube。
 */
function toVideo(dto: MediaVideoDto): MediaVideo {
  return {
    key: dto.key,
    name: dto.name,
    kind: dto.kind,
    thumbnailUrl: cachedImageUrl(dto.thumbnail_url),
    embedUrl: dto.embed_url,
    watchUrl: dto.watch_url,
  };
}

/** 统一转换演员与导演人物；头像都走同一份图片缓存，人物 ID 保持可选。 */
function toCastMember(member: MediaCastMemberDto): MediaCastMember {
  return {
    name: member.name,
    role: member.role ?? undefined,
    avatarUrl: member.avatar_url ? cachedImageUrl(member.avatar_url) : undefined,
    tmdbPersonId: member.tmdb_person_id ?? undefined,
  };
}

/** 读取一个稳定影视引用的详情；调用方无需再分别选择 TMDB/豆瓣端点。 */
export async function fetchDiscoveredTitleDetails(
  reference: string,
  init?: RequestInit,
): Promise<MediaDetailData> {
  const dto = await unwrap(
    request<ApiEnvelope<DiscoveredTitleDetailsDto>>(
      `/discover/titles/${encodeURIComponent(reference)}`,
      init,
    ),
  );
  return {
    item: toItem(dto.title),
    info: {
      directors: dto.metadata.directors,
      // 豆瓣头像需要代理 Referer，TMDB 头像也统一复用图片缓存。
      directorCredits: dto.metadata.director_credits.map(toCastMember),
      cast: dto.metadata.cast.map(toCastMember),
      country: dto.metadata.country,
      language: dto.metadata.language,
      released: dto.metadata.released,
      network: dto.metadata.network ?? undefined,
      aliases: dto.metadata.aliases,
      sourceUrl: dto.metadata.source_url ?? undefined,
      englishTitle: dto.metadata.english_title ?? undefined,
    },
    videos: (dto.videos ?? []).map(toVideo),
    backdropOriginalUrl: dto.backdrop_original_url
      ? cachedImageUrl(dto.backdrop_original_url)
      : undefined,
    backdrops: dto.backdrops.map(toImage),
    posters: dto.posters.map(toImage),
    collection: dto.collection
      ? {
          id: dto.collection.id,
          name: dto.collection.name,
          items: dto.collection.titles.map(toItem),
        }
      : undefined,
    related: dto.recommendations.map(toItem),
    libraryLinks: (dto.library_links ?? []).map(toLibraryLink),
  };
}

/** 读取发现页影人的完整 TMDB 影视履历；条目已包含当前账号可见的库存状态。 */
export async function fetchDiscoveredPersonDetails(
  tmdbPersonId: number | string,
  init?: RequestInit,
): Promise<DiscoveredPersonDetailsData> {
  const dto = await unwrap(
    request<ApiEnvelope<DiscoveredPersonDetailsDto>>(
      `/discover/people/${tmdbPersonId}`,
      init,
    ),
  );
  return {
    tmdbPersonId: dto.tmdb_person_id,
    name: dto.name,
    avatarUrl: dto.avatar_url ? cachedImageUrl(dto.avatar_url) : "",
    items: dto.titles.map(toItem),
  };
}

/** 横滚行组件仍消费 MediaRowData，此转换只属于前端展示层。 */
export function collectionToRow(collection: DiscoveredCollectionData): MediaRowData {
  return {
    id: collection.collectionRef,
    title: collection.name,
    items: collection.items,
  };
}
