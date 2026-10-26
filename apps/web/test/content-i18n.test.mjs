import assert from "node:assert/strict";
import test from "node:test";

import { discoveryCountries, discoveryDimensionSummary, discoveryFilterButtonTitle, discoveryFilterLabels } from "../lib/discovery-filters.ts";
import { homeSortPresets, rowTitle } from "../lib/home-rows.ts";

// A language change updates display helpers without rebuilding stored preferences.
test("content labels follow the active language and preserve custom row names", () => {
  const previous = globalThis.document;
  const filters = { genreIds: [18, 28], originCountry: "JP", year: 2024, ratingGte: 8, runtimeLte: 90, sort: "rating" };
  const names = new Map([[18, "Drama"], [28, "Action"]]);
  const row = { kind: "library", name: "", sort: "added_at", reversed: false, library: { name: "我的电影" } };
  try {
    for (const locale of ["en", "zh-Hans", "en"]) {
      globalThis.document = { documentElement: { lang: locale } };
      assert.equal(discoveryCountries().find(([code]) => code === "JP")[1], locale === "en" ? "Japan" : "日本");
      assert.equal(discoveryDimensionSummary("runtime", filters), locale === "en" ? "Up to 90 min" : "90 分钟以内");
      assert.equal(discoveryFilterLabels(filters, names).at(-1), locale === "en" ? "Highest rated" : "评分优先");
      assert.equal(discoveryFilterButtonTitle(filters, names), locale === "en" ? "Drama and more (2 genres)" : "Drama等 2 个");
      assert.equal(rowTitle(row), locale === "en" ? "Recently added to 我的电影" : "最近添加的我的电影");
      assert.equal(rowTitle({ ...row, name: "我的自定义行" }), "我的自定义行");
      assert.equal(homeSortPresets().added_at.direction.naturalAsc, false);
    }
  } finally {
    if (previous === undefined) delete globalThis.document;
    else globalThis.document = previous;
  }
});

test("server rendering can select a language without a browser document", () => {
  const previous = globalThis.document;
  delete globalThis.document;
  try {
    const filters = { genreIds: [], originCountry: "JP", runtimeLte: 90, sort: "popular" };
    assert.equal(discoveryCountries("en").find(([code]) => code === "JP")[1], "Japan");
    assert.equal(discoveryDimensionSummary("runtime", filters, new Map(), "en"), "Up to 90 min");
    assert.equal(discoveryFilterButtonTitle(filters, new Map(), "en"), "All");
    assert.equal(discoveryFilterLabels(filters, new Map(), "en")[0], "Japan");
  } finally {
    if (previous !== undefined) globalThis.document = previous;
  }
});
