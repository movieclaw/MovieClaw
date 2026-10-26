import { appTranslator, type AppMessageKey } from "./i18n/translate.ts";
import type { AppLocale } from "./i18n/negotiate.ts";

/** TMDB 类型编号跨语言稳定，文案只用于展示。 */
const GENRE_KEYS: Record<number, AppMessageKey> = {
  28: "media.genres.action",
  12: "media.genres.adventure",
  16: "media.genres.animation",
  35: "media.genres.comedy",
  80: "media.genres.crime",
  99: "media.genres.documentary",
  18: "media.genres.drama",
  10751: "media.genres.family",
  14: "media.genres.fantasy",
  36: "media.genres.history",
  27: "media.genres.horror",
  10402: "media.genres.music",
  9648: "media.genres.mystery",
  10749: "media.genres.romance",
  878: "media.genres.scienceFiction",
  10770: "media.genres.tvMovie",
  53: "media.genres.thriller",
  10752: "media.genres.war",
  37: "media.genres.western",
  10759: "media.genres.actionAdventure",
  10762: "media.genres.kids",
  10763: "media.genres.news",
  10764: "media.genres.reality",
  10765: "media.genres.scienceFictionFantasy",
  10766: "media.genres.soap",
  10767: "media.genres.talk",
  10768: "media.genres.warPolitics",
};

export function genreLabels(locale?: AppLocale): Record<number, string> {
  const t = appTranslator(locale);
  return Object.fromEntries(Object.entries(GENRE_KEYS).map(([id, key]) => [id, t(key)]));
}

export const GENRE_LABELS = genreLabels("zh-Hans");
