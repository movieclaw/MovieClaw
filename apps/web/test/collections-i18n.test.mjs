import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import ts from "typescript";
import { appTranslator } from "../lib/i18n/translate.ts";
import { requestLocale } from "../lib/i18n/negotiate.ts";
import { PREF_TO_SORT, sortDirections, sortPrefLabels } from "../lib/wall-sort.ts";

function loadComponent(file, extra = "") {
  const source = readFileSync(new URL(`../components/${file}.tsx`, import.meta.url), "utf8");
  const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX } }).outputText;
  const exports = {};
  vm.runInNewContext(compiled + extra, { exports, TextEncoder, require: (name) => {
    if (name === "@/lib/i18n/translate") return { appTranslator };
    if (name === "@/lib/i18n/negotiate") return { requestLocale };
    if (name === "@/lib/wall-sort") return { PREF_TO_SORT, sortDirections, sortPrefLabels };
    if (name === "react") return { memo: (component) => component };
    return {};
  } });
  return exports;
}
const { formatPhotoMonth, photoMonthOf } = loadComponent("photo-wall");
const { sortOf } = loadComponent("library-collection-detail-view", "\nexports.sortOf = defaultSortOf;");

test("photo month labels follow the explicit locale without changing month bucket IDs", () => {
  assert.equal(photoMonthOf({ release_date: null }), "未知");
  assert.equal(photoMonthOf({ release_date: "2026-08-09" }), "2026-08");
  for (const locale of ["en", "zh-Hans", "en"]) {
    assert.equal(formatPhotoMonth("2026-08", locale), locale === "en" ? "August 2026" : "2026 年 8 月");
    assert.equal(formatPhotoMonth("未知", locale), locale === "en" ? "Date unknown" : "日期未知");
  }
});
test("collection default sorting translates labels while preserving ordering semantics", () => {
  for (const [collection, english, chinese, naturalAsc] of [
    [null, "Custom order", "自定顺序", true],
    [{ rule_driven: true, kind: "series" }, "Release order", "按上映顺序", true],
    [{ rule_driven: true, kind: "user", sort: "rating" }, "By rating", "按评分", false],
  ]) {
    for (const locale of ["en", "zh-Hans", "en"]) {
      const sort = sortOf(collection, locale);
      assert.equal(sort.label, locale === "en" ? english : chinese);
      assert.equal(sort.naturalAsc, naturalAsc);
      if (locale === "en") assert.doesNotMatch(JSON.stringify(sort), /[\u3400-\u9fff]/u);
    }
  }
});
test("complete collection summaries handle singulars and preserve Chinese punctuation", () => {
  const en = appTranslator("en"), zh = appTranslator("zh-Hans");
  assert.equal(en("library.collections.itemCount", { count: 1 }), "1 title");
  assert.equal(en("library.collections.itemCount", { count: 2 }), "2 titles");
  assert.equal(en("library.collections.matchCount", { count: 1 }), "1 title matches these conditions");
  assert.equal(en("library.gallery.imageCount", { count: 1 }), "1 image");
  assert.equal(en("library.gallery.imageCount", { count: 2 }), "2 images");
  assert.equal(zh("library.collections.shareSummary", { count: 2, automatic: "yes" }), "2 部 · 会自动收录新片");
  assert.equal(zh("library.collections.shareSummary", { count: 2, automatic: "no" }), "2 部");
  assert.equal(zh("library.gallery.view", { title: "影片名", label: "海报", favorite: "yes" }), "查看 影片名 · 海报（已收藏）");
});
