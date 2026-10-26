import { appTranslator } from "./i18n/translate.ts";
import type { AppLocale } from "./i18n/negotiate.ts";
import type { MediaLibrary } from "./api/libraries";

/** 可补充的规则字段（v1 仅两个维度），缺失维度只用于展示建议。 */
const RULE_FIELDS = ["genres", "origin_countries"] as const;

/**
 * 同类型两库的收藏范围可能同时命中同一部作品、且特异性（条件条数）相同
 * ——命中顺序只能靠创建先后，给只读提示（不阻断：加一个条件即可消解）。
 * 「可能同时命中」= 两库共同声明的每个字段取值都有交集。
 * 提示不止陈述事实，还给出具体做法：点名给创建更晚（即将吃亏）的那个库
 * 补上它缺的维度——条件数多者优先命中，补完歧义即消。
 */
export function routingOverlapWarnings(libraries: MediaLibrary[], locale: AppLocale = "zh-Hans"): { id: string; message: string }[] {
  const t = appTranslator(locale);
  const declared = libraries.filter((l) => l.match_rules.length > 0);
  const warnings: { id: string; message: string }[] = [];
  for (let i = 0; i < declared.length; i++) {
    for (let j = i + 1; j < declared.length; j++) {
      const a = declared[i];
      const b = declared[j];
      if (a.kind !== b.kind || a.match_rules.length !== b.match_rules.length) continue;
      const compatible = a.match_rules.every((ra) => {
        const rb = b.match_rules.find((r) => r.field === ra.field);
        if (!rb) return true; // 字段只在一边：不妨碍同时命中
        return ra.values.some((v) => rb.values.includes(v));
      });
      if (compatible) {
        const [first, later] = (a.id ?? 0) < (b.id ?? 0) ? [a, b] : [b, a];
        const laterFields = new Set<string>(later.match_rules.map((r) => r.field));
        const missing = RULE_FIELDS.filter((field) => !laterFields.has(field));
        warnings.push({
          id: `${Math.min(a.id, b.id)}:${Math.max(a.id, b.id)}`,
          message: t("library.routingOverlap", {
            a: a.name, b: b.name, first: first.name, later: later.name,
            dimension: missing.length === 0 ? "none" : missing.length === 2 ? "both" : missing[0],
          }),
        });
      }
    }
  }
  return warnings;
}
