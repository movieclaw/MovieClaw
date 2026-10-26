import assert from "node:assert/strict";
import test from "node:test";
import { homeSortPresets } from "../lib/home-rows.ts";
import { sortDirections, sortPrefLabels, SORT_DIRECTIONS, SORT_PREF_LABELS } from "../lib/wall-sort.ts";

test("wall sorting localizes display labels while preserving natural order and legacy Chinese", () => {
  assert.deepEqual(sortDirections("zh-Hans"), SORT_DIRECTIONS);
  assert.deepEqual(sortPrefLabels("zh-Hans"), SORT_PREF_LABELS);
  const before = structuredClone(SORT_DIRECTIONS);
  for (const locale of ["en", "zh-Hans", "en"]) {
    const values = sortDirections(locale);
    for (const key of Object.keys(values)) assert.equal(values[key].naturalAsc, before[key].naturalAsc);
    for (const key of ["added_at", "release_date", "last_played", "rating"]) {
      assert.equal(values[key].asc, homeSortPresets(locale)[key].direction.asc);
      assert.equal(values[key].desc, homeSortPresets(locale)[key].direction.desc);
    }
    if (locale === "en") {
      assert.equal(values.runtime.asc, "Short → long");
      assert.equal(values.rating.desc, "High → low");
      assert.equal(sortPrefLabels(locale).title, "By title");
      assert.doesNotMatch(JSON.stringify(values), /[\u3400-\u9fff]/u);
    }
  }
  assert.deepEqual(SORT_DIRECTIONS, before);
});
