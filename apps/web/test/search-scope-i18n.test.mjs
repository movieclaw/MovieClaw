import assert from "node:assert/strict";
import test from "node:test";

import { presetSummary, scopeEquals, scopeOfTab, searchScopeLabel, tabLabel } from "../lib/categories.ts";
import { buildSearchPath, parseSearchQuery } from "../lib/search-url.ts";

test("built-in search identities survive language changes and URL replay", () => {
  const scope = scopeOfTab({ type: "category", id: "movie", visible: true });
  assert.equal(scope.label, "电影");
  assert.equal(searchScopeLabel(scope, "en"), "Movies");
  assert.equal(searchScopeLabel(scope, "zh-Hans"), "电影");
  const replay = parseSearchQuery(new URL(buildSearchPath({ keyword: "用户关键词", scope }), "http://test").searchParams);
  assert.equal(replay.keyword, "用户关键词");
  assert.equal(replay.scope.labelKey, "search.categories.movie");
  assert.ok(scopeEquals(scope, { ...replay.scope, label: "Movies" }));
});

test("user scopes named like a built-in category keep their original names", () => {
  const preset = { type: "preset", id: "user-name", name: "电影", visible: true,
    categories: ["movie"], site_ids: [], poster_mode: false, skip_history: false };
  const custom = scopeOfTab(preset);
  assert.equal(tabLabel(preset, "en"), "电影");
  assert.equal(searchScopeLabel(custom, "en"), "电影");
  assert.equal(scopeEquals(custom, scopeOfTab({ type: "category", id: "movie", visible: true })), false);
  assert.equal(presetSummary(preset, "en"), "Movies · All sites");
  assert.equal(presetSummary(preset, "zh-Hans"), "电影 · 全部站点");
});

test("unknown legacy scope names are not inferred or changed", () => {
  const query = parseSearchQuery(new URLSearchParams("q=keyword&cats=movie&label=电影&label_key=common.delete"));
  assert.equal(query.scope.labelKey, undefined);
  assert.equal(searchScopeLabel(query.scope, "en"), "电影");
});
