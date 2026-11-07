/**
 * 车机 / TV 条目详情页的共享纯逻辑（两端逐字相同的部分）：
 * - ShellCastPerson / castPeopleOf：演职员行模型与解析（结构化导演在前，演员跟着）
 * - resolutionHeightOf / clockOf：画质高度与「mm:ss」格式化
 * - anchorEpisodeOf / anchorEpisodeOfResult：本季接着看的那一集（客户端兜底规则）。
 *   注意：与 library/EpisodeRanges.ets 的 clientResumeEpisode 规则不同
 *   （那边优先有片源的），不要互相替换；选集分段用那边现成的 EpisodeRanges。
 */
import {
  EpisodeView,
  LibraryItemDetailView,
  LocalMetaView,
  SeasonEpisodesView
} from '../api/Models';
import { ImageUrls } from '../common/ImageUrls';

/** 详情首屏右下与演职员行共用的一位影人 */
export class ShellCastPerson {
  readonly name: string;
  readonly role: string | null;
  readonly avatarUrl: string;
  readonly personId: number | null;

  constructor(name: string, role: string | null, avatarUrl: string, personId: number | null) {
    this.name = name;
    this.role = role;
    this.avatarUrl = avatarUrl;
    this.personId = personId;
  }
}

/** 「2160p」「4K」「8K」→ 画面高度；解析不出返回 null */
export function resolutionHeightOf(raw: string | null | undefined): number | null {
  if (raw === null || raw === undefined) {
    return null;
  }
  const normalized: string = raw.trim().toLowerCase();
  if (normalized === '8k') {
    return 4320;
  }
  if (normalized === '4k' || normalized === 'uhd') {
    return 2160;
  }
  if (normalized === '2k') {
    return 1440;
  }
  const digits: string = normalized.replace(/[^0-9]/g, '');
  return digits.length === 0 ? null : Number(digits);
}

/** 毫秒 → 「mm:ss」 */
export function clockOf(ms: number): string {
  const total: number = Math.floor(ms / 1000);
  const minutes: number = Math.floor(total / 60);
  const seconds: number = total % 60;
  return `${minutes}:${seconds < 10 ? '0' : ''}${seconds}`;
}

/** 本季接着看的那一集（客户端兜底：看了一半的 → 第一个没看过有片源的 → 第一集） */
export function anchorEpisodeOf(episodes: EpisodeView[]): EpisodeView | null {
  if (episodes.length === 0) {
    return null;
  }
  for (const ep of episodes) {
    if (ep.position_ms > 0) {
      return ep;
    }
  }
  for (const ep of episodes) {
    if (!ep.played && ep.owned) {
      return ep;
    }
  }
  return episodes[0];
}

/** 服务端锚点优先（resume_episode），没有走客户端规则 */
export function anchorEpisodeOfResult(result: SeasonEpisodesView): EpisodeView | null {
  const resume: number | null = result.resume_episode ?? null;
  if (resume !== null) {
    for (const ep of result.episodes) {
      if (ep.episode_number === resume) {
        return ep;
      }
    }
  }
  return anchorEpisodeOf(result.episodes);
}

/** 详情的演职员：结构化导演在前（没有退回姓名），演员跟着 */
export function castPeopleOf(detail: LibraryItemDetailView, origin: string): ShellCastPerson[] {
  const meta: LocalMetaView | null = detail.local_meta ?? null;
  if (meta === null) {
    return [];
  }
  const out: ShellCastPerson[] = [];
  if (meta.director_credits.length > 0) {
    for (const dir of meta.director_credits) {
      out.push(new ShellCastPerson(dir.name, '导演',
        ImageUrls.resolve(origin, dir.thumb_url ?? null, null) ?? '', dir.tmdb_person_id));
    }
  } else {
    for (const name of meta.directors) {
      out.push(new ShellCastPerson(name, '导演', '', null));
    }
  }
  for (const actor of meta.actors) {
    const role: string | null = actor.role ?? null;
    out.push(new ShellCastPerson(actor.name,
      role === null ? null : `饰 ${role}`,
      ImageUrls.resolve(origin, actor.thumb_url ?? null, null) ?? '',
      actor.tmdb_person_id ?? null));
  }
  return out;
}
