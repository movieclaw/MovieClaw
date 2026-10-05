import { request } from "@/lib/http";
import { imageUrl } from "@/lib/image-proxy";
import type { MediaType } from "@/lib/media-types";

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

interface PersonCreditDto {
  media_item_id: number;
  kind: MediaType;
  tmdb_id: number;
  title: string;
  year: number | null;
  poster_url: string | null;
  library_id: number | null;
  department: string;
  character: string | null;
}

interface PersonDto {
  tmdb_person_id: number;
  name: string;
  original_name: string | null;
  avatar_url: string | null;
  credits: PersonCreditDto[];
}

/** 人物页作品列表的一格：库内一部片 + 这个人在其中的身份。 */
export interface PersonCredit {
  mediaItemId: number;
  kind: MediaType;
  tmdbId: number;
  title: string;
  year?: number;
  posterUrl: string;
  /** 任一拥有该条目文件的库 id；文件已全删、只剩档案时为空，卡片渲染为不可点 */
  libraryId?: number;
  /** cast=演员 / director=导演（剧集为主创） */
  department: "cast" | "director";
  /** 饰演角色（仅 cast） */
  character?: string;
}

export interface PersonDetail {
  tmdbPersonId: number;
  name: string;
  originalName?: string;
  avatarUrl: string;
  credits: PersonCredit[];
}

/**
 * 拉取「我库里的这个影人」。
 *
 * 数据全部来自本地表，不联网。库内没有这个人（或存量库还没做过一次
 * 「刷新元数据」，见后端迁移 c4d7a9e2b581 的说明）时后端返回 404，
 * 调用方按 HttpError 处理成空状态。
 */
export async function fetchPerson(
  tmdbPersonId: number | string,
  init?: RequestInit,
): Promise<PersonDetail> {
  const dto = await unwrap(
    request<ApiEnvelope<PersonDto>>(`/people/${tmdbPersonId}`, init),
  );
  return {
    tmdbPersonId: dto.tmdb_person_id,
    name: dto.name,
    originalName: dto.original_name ?? undefined,
    // 头像可能是本地头像资产的相对路径（/images/people/...，断网可用），也可能是
    // TMDB 图床地址（走缓存代理）——统一经 imageUrl 解析
    avatarUrl: dto.avatar_url ? imageUrl(dto.avatar_url) : "",
    credits: dto.credits.map((c) => ({
      mediaItemId: c.media_item_id,
      kind: c.kind,
      tmdbId: c.tmdb_id,
      title: c.title,
      year: c.year ?? undefined,
      // 海报可能是本地刮削资产的相对路径（断网可用），也可能是 TMDB 图床地址
      posterUrl: imageUrl(c.poster_url),
      libraryId: c.library_id ?? undefined,
      department: c.department === "director" ? "director" : "cast",
      character: c.character ?? undefined,
    })),
  };
}
