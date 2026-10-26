import { appTranslator, type AppMessageKey } from "./i18n/translate.ts";
import { requestLocale, type AppLocale } from "./i18n/negotiate.ts";

/**
 * 语言标签（ISO 639-2/B 与常见私有码）→ 中文名。
 *
 * 详情页的字幕/音轨徽章与播放器的轨选择菜单共用同一份：同一条轨在两处显示
 * 成不同的名字（一处「简体中文」一处 chs），用户会以为是两条不同的轨。
 */
const LANGUAGE_LABELS: Record<string, AppMessageKey> = {
  chs: "media.languages.simplifiedChinese",
  cht: "media.languages.traditionalChinese",
  chi: "media.languages.chinese",
  zho: "media.languages.chinese",
  cmn: "media.languages.chinese",
  yue: "media.languages.cantonese",
  eng: "media.languages.english",
  jpn: "media.languages.japanese",
  kor: "media.languages.korean",
  fre: "media.languages.french",
  fra: "media.languages.french",
  ger: "media.languages.german",
  deu: "media.languages.german",
  spa: "media.languages.spanish",
  rus: "media.languages.russian",
  ita: "media.languages.italian",
  por: "media.languages.portuguese",
  tha: "media.languages.thai",
  hin: "media.languages.hindi",
};

/** 未知语言（und）与空值返回 null，由调用方决定占位文案。 */
export function languageLabel(code: string | null, locale: AppLocale = requestLocale() ?? "zh-Hans"): string | null {
  if (!code || code === "und") return null;
  const key = LANGUAGE_LABELS[code.toLowerCase()];
  return key ? appTranslator(locale)(key) : code;
}
