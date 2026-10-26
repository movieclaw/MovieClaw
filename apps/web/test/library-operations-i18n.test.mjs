import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import ts from "typescript";
import { appTranslator } from "../lib/i18n/translate.ts";

const file = readFileSync(new URL("../components/reidentify-dialog.tsx", import.meta.url), "utf8");
const compiled = ts.transpileModule(file, { compilerOptions: { module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX } }).outputText;
const exports = {};
vm.runInNewContext(compiled + "\nexports.sources = sourceLabels; exports.codes = codeLabels;", { exports, require: () => ({}) });

test("identification explanation tables follow each render without changing machine codes", () => {
  const original = Object.keys(exports.codes(appTranslator("zh-Hans")));
  for (const locale of ["en", "zh-Hans", "en"]) {
    const codes = exports.codes(appTranslator(locale));
    assert.deepEqual(Object.keys(codes), original);
    assert.equal(exports.sources(appTranslator(locale)).nfo, "NFO");
    assert.equal(codes.no_match, locale === "en" ? "No TMDB match" : "TMDB 里没找到匹配");
    if (locale === "en") assert.doesNotMatch(JSON.stringify(codes), /[\u3400-\u9fff]/u);
  }
});
test("assignment and organization use complete messages with correct singular and zero forms", () => {
  const en = appTranslator("en"), zh = appTranslator("zh-Hans");
  assert.equal(en("library.claim.assign", { all: "yes", count: 1 }), "Assign all 1 file");
  assert.equal(en("library.claim.assign", { all: "yes", count: 2 }), "Assign all 2 files");
  assert.equal(zh("library.claim.assign", { all: "no", count: 1 }), "认领");
  assert.equal(en("library.reidentify.noResult", { coded: "no", code: "", detailed: "no", detail: "" }), "Could not identify.");
  assert.equal(zh("library.reidentify.noResult", { coded: "yes", code: "候选之间分不出", detailed: "yes", detail: "佐证" }), "没能认出来（候选之间分不出）：佐证");
  const counts = { renamed: 1, sidecars: 0, assets: 0, removed: 0, skipped: 0 };
  assert.equal(en("library.organize.result", counts), "Renamed 1 file.");
  assert.equal(zh("library.organize.result", { ...counts, sidecars: 2, assets: 1, removed: 3, skipped: 4 }), "改名归位 1 个文件，附属文件 2 个随迁，海报/NFO 1 个随条目目录搬迁，清理搬空目录 3 个。跳过 4 个（原因见预览）。");
});
