import assert from "node:assert/strict";
import { test } from "node:test";

import { DEFAULT_THEME_ID, normalizeThemeId, THEMES, themeMeta } from "../lib/themes.ts";

test("注册表内置银玻璃与 Netflix 两个主题", () => {
  const ids = THEMES.map((theme) => theme.id);
  assert.deepEqual(ids, ["silver", "netflix"]);
  // 版式：银玻璃 = 侧栏面板，Netflix = 顶栏影院；Netflix 停用液态玻璃
  assert.equal(THEMES.find((t) => t.id === "silver")?.layout, "panel");
  assert.equal(THEMES.find((t) => t.id === "netflix")?.layout, "cinema");
  assert.equal(THEMES.find((t) => t.id === "silver")?.glass, true);
  assert.equal(THEMES.find((t) => t.id === "netflix")?.glass, false);
});

test("normalizeThemeId：未知值 / 非字符串 / undefined 一律兜底为默认主题", () => {
  assert.equal(normalizeThemeId("netflix"), "netflix");
  assert.equal(normalizeThemeId("silver"), "silver");
  // 老后端不认识 theme 字段时返回 undefined
  assert.equal(normalizeThemeId(undefined), DEFAULT_THEME_ID);
  assert.equal(normalizeThemeId(null), DEFAULT_THEME_ID);
  assert.equal(normalizeThemeId(42), DEFAULT_THEME_ID);
  // 手改缓存 / 未来被下线的主题 id
  assert.equal(normalizeThemeId("hacker-theme"), DEFAULT_THEME_ID);
  assert.equal(normalizeThemeId(""), DEFAULT_THEME_ID);
});

test("themeMeta：未知 id 回落默认主题元数据", () => {
  assert.equal(themeMeta("netflix").label, "Netflix");
  assert.equal(themeMeta("nope").id, DEFAULT_THEME_ID);
});
