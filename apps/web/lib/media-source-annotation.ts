import { appTranslator } from "./i18n/translate.ts";
import { requestLocale, type AppLocale } from "./i18n/negotiate.ts";

/**
 * 片源人工标注的纯逻辑（docs/design/media-source-annotation.md）。
 *
 * 扫描入库文件的片源常无法从文件名解析（组名不含片源词），同分辨率下洗版
 * 比较不可比，单元停在「无法确认」。标注把用户的整季判断落库，选项与后端
 * 片源档阶梯同源；`user-lowest` 是「不确定，按最低档处理」的显式哨兵（T0），
 * 与系统未知（null，不可比、安静）严格分离。
 */

/** 「不确定，按最低档」哨兵（与后端 movieclaw_matcher.USER_LOWEST_SOURCE 同值） */
export const USER_LOWEST_SOURCE = "user-lowest";

/**
 * 原盘档（T6，与后端 movieclaw_matcher.DISC_SOURCE 同值）。由台账结构自动写入
 * （BDMV / VIDEO_TS / ISO），**不在标注选项里**——用户不需要、也无法把一个
 * 非原盘文件说成原盘。这里只为把它显示成人话。
 */
export const DISC_SOURCE = "Disc";

export type AnnotatableSource =
  | "Remux"
  | "Blu-ray"
  | "WEB-DL"
  | "WEBRip"
  | "HDTV"
  | typeof USER_LOWEST_SOURCE;

export interface MediaSourceOption {
  value: AnnotatableSource;
  label: string;
  /** 选项的后果说明——每个选择都必须是知情选择 */
  consequence: string;
  /** 会触发整季重下的选项，用警示色渲染 */
  destructive?: boolean;
}

export function mediaSourceOptions(locale: AppLocale = requestLocale() ?? "zh-Hans"): MediaSourceOption[] {
  const t = appTranslator(locale);
  return [
    {
      value: "Remux",
      label: "Remux",
      consequence: t("library.sourceAnnotation.remuxHint"),
    },
    {
      value: "Blu-ray",
      label: t("library.sourceAnnotation.blurayLabel"),
      consequence: t("library.sourceAnnotation.blurayHint"),
    },
    {
      value: "WEB-DL",
      label: "WEB-DL",
      consequence: t("library.sourceAnnotation.webDlHint"),
    },
    {
      value: "WEBRip",
      label: "WEBRip",
      consequence: t("library.sourceAnnotation.webRipHint"),
    },
    {
      value: "HDTV",
      label: t("library.sourceAnnotation.hdtvLabel"),
      consequence: t("library.sourceAnnotation.hdtvHint"),
    },
    {
      value: USER_LOWEST_SOURCE,
      label: t("library.sourceAnnotation.lowestLabel"),
      consequence: t("library.sourceAnnotation.lowestHint"),
      destructive: true,
    },
  ];
}

/** 片源值 → 展示名：哨兵值与内部档位值不能直接亮给用户。 */
export function mediaSourceDisplayLabel(value: string | null | undefined, locale: AppLocale = requestLocale() ?? "zh-Hans"): string | null {
  const t = appTranslator(locale);
  if (!value) return null;
  if (value === USER_LOWEST_SOURCE) return t("media.sources.lowestManual");
  if (value === DISC_SOURCE) return t("media.sources.disc");
  return value;
}

/** 洗版报告：存在「无法确认」单元的季号集合（标注入口的显示条件）。 */
export function seasonsNeedingAnnotation(
  units: { season_number: number; state: string }[],
): Set<number> {
  const seasons = new Set<number>();
  for (const u of units) {
    if (u.state === "not_comparable") seasons.add(u.season_number);
  }
  return seasons;
}

/** 追踪明细：存在「无法确认档位」行的季号集合（标注入口的显示条件）。 */
export function seasonsWithIndeterminate(
  wanted: { season_number: number; upgrade?: { indeterminate: boolean } | null }[],
): Set<number> {
  const seasons = new Set<number>();
  for (const w of wanted) {
    if (w.upgrade?.indeterminate) seasons.add(w.season_number);
  }
  return seasons;
}
