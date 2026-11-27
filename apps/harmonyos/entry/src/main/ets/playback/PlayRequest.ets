import { SubtitlePlanView } from '../api/Models';

/** 起播请求（智慧屏 TV 与鸿蒙座舱车机共用） */
export class PlayRequest {
  readonly libraryId: number;
  readonly itemId: number;
  readonly seasonNumber: number | null;
  readonly episodeNumber: number | null;
  readonly fileId: number | null;
  readonly startMs: number | null;
  readonly title: string;
  readonly subtitle: string | null;
  readonly coverUrl: string;
  readonly autoAdvance: boolean;

  constructor(libraryId: number, itemId: number, seasonNumber: number | null,
    episodeNumber: number | null, fileId: number | null, startMs: number | null,
    title: string, subtitle: string | null, coverUrl: string, autoAdvance: boolean) {
    this.libraryId = libraryId;
    this.itemId = itemId;
    this.seasonNumber = seasonNumber;
    this.episodeNumber = episodeNumber;
    this.fileId = fileId;
    this.startMs = startMs;
    this.title = title;
    this.subtitle = subtitle;
    this.coverUrl = coverUrl;
    this.autoAdvance = autoAdvance;
  }
}

export function selectedSubtitleTrack(touched: boolean, ref: string): string | null {
  return touched ? (ref.length > 0 ? ref : 'off') : null;
}

export function subtitleIndexForRef(plans: SubtitlePlanView[], ref: string): number {
  if (ref.length === 0 || ref === 'off') {
    return -1;
  }
  return plans.findIndex((plan: SubtitlePlanView): boolean => plan.track_ref === ref);
}

export function restorableSubtitleIndex(plans: SubtitlePlanView[], urls: string[], ref: string,
  burnedRef: string): number {
  if (burnedRef.length > 0) {
    return -1;
  }
  const index: number = subtitleIndexForRef(plans, ref);
  return index >= 0 && plans[index].kind !== 'pgs' && index < urls.length && urls[index].length > 0 ? index : -1;
}
