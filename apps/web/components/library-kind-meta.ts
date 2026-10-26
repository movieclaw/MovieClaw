import type { AppLocale } from "@/lib/i18n/negotiate";
import { FilmIcon, PhotoIcon, TvIcon, VideoIcon } from "@/components/icons";
import { LIBRARY_KIND_LABELS, libraryKindLabels, type LibraryKind } from "@/lib/media-types";

/**
 * 库类型 → 展示名与图标。首页卡片、管理页行、建库向导、单库页头部共用；
 * 单独成模块是为了让管理页与表单弹窗不必为这一张表把首页整个模块图拖进来。
 */
export const LIBRARY_KIND_META: Record<LibraryKind, { label: string; Icon: typeof FilmIcon }> = {
  movie: { label: LIBRARY_KIND_LABELS.movie, Icon: FilmIcon },
  tv: { label: LIBRARY_KIND_LABELS.tv, Icon: TvIcon },
  video: { label: LIBRARY_KIND_LABELS.video, Icon: VideoIcon },
  photo: { label: LIBRARY_KIND_LABELS.photo, Icon: PhotoIcon },
};

export function libraryKindMeta(locale?: AppLocale) {
  const labels = libraryKindLabels(locale);
  return {
    movie: { ...LIBRARY_KIND_META.movie, label: labels.movie },
    tv: { ...LIBRARY_KIND_META.tv, label: labels.tv },
    video: { ...LIBRARY_KIND_META.video, label: labels.video },
    photo: { ...LIBRARY_KIND_META.photo, label: labels.photo },
  };
}
