import assert from "node:assert/strict";
import test from "node:test";

import { favoriteLevelLabel } from "../lib/favorites.ts";

test("单集收藏写成 S01E02", () => {
  assert.equal(favoriteLevelLabel("tv", 1, 2), "收藏了 S01E02");
});

test("整季收藏写季号，特别篇单独命名", () => {
  assert.equal(favoriteLevelLabel("tv", 3, null), "收藏了第 3 季");
  assert.equal(favoriteLevelLabel("tv", 0, null), "收藏了特别篇");
});

test("整剧与电影不解释层级", () => {
  assert.equal(favoriteLevelLabel("tv", null, null), null);
  assert.equal(favoriteLevelLabel("movie", null, null), null);
  // 电影的 (0,0) 是播放单元哨兵，后端不外泄；即便传来也不能写成 S00E00
  assert.equal(favoriteLevelLabel("movie", 0, 0), null);
});

test("收藏页不展示接口不支持的随机排序", async () => {
  const [{ readFileSync }, vm, ts, wallSort, { appTranslator }] = await Promise.all([
    import("node:fs"), import("node:vm"), import("typescript"),
    import("../lib/wall-sort.ts"), import("../lib/i18n/translate.ts"),
  ]);
  const imports = {
    "@/lib/wall-sort": wallSort,
    "@/lib/i18n/translate": { appTranslator },
    "@/lib/library-wall-recall": { wallRecallScope: () => "favorites" },
  };
  const source = readFileSync(new URL("../components/favorites-view.tsx", import.meta.url), "utf8") + "\nexport { sortOptions };";
  const exports = {};
  vm.runInNewContext(ts.default.transpileModule(source, {
    compilerOptions: { module: ts.default.ModuleKind.CommonJS, target: ts.default.ScriptTarget.ES2022, jsx: ts.default.JsxEmit.ReactJSX },
  }).outputText, { exports, require: (key) => imports[key] ?? {} });
  for (const locale of ["en", "zh-Hans"]) {
    const keys = [...exports.sortOptions(locale)].map(([key]) => key);
    assert.ok(keys.includes("default"));
    assert.ok(keys.includes("title"));
    assert.ok(!keys.includes("random"));
  }
});
