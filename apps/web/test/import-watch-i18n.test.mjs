import assert from "node:assert/strict";
import test from "node:test";
import { appTranslator } from "../lib/i18n/translate.ts";

test("automatic import counters use complete plural messages and preserve Chinese counts", () => {
  const en = appTranslator("en"), zh = appTranslator("zh-Hans");
  assert.equal(en("settings.importWatch.ruleCount", { count: 1 }), "1 rule");
  assert.equal(en("settings.importWatch.ruleCount", { count: 2 }), "2 rules");
  assert.equal(en("settings.importWatch.importedWorks", { count: 1 }), "Imported 1 title");
  assert.equal(en("settings.importWatch.importedWorks", { count: 2 }), "Imported 2 titles");
  assert.equal(en("settings.importWatch.importedDetail", { entries: 1, files: 2 }), " (1 entry · 2 files)");
  assert.equal(zh("settings.importWatch.importedDetail", { entries: 2, files: 3 }), "（2 个条目 · 3 个文件）");
  assert.equal(zh("settings.importWatch.ruleCount", { count: 1200 }), "1200 条规则");
});
