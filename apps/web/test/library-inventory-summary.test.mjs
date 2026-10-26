import assert from "node:assert/strict";
import test from "node:test";

import {
  formatLibraryInventorySummary,
  libraryInventoryAction,
} from "../lib/library-inventory-summary.ts";

function summary(overrides = {}) {
  return {
    season_count: 8,
    episode_count: 64,
    season_number: null,
    total_episode_count: 80,
    all_seasons_owned: true,
    all_episodes_owned: false,
    ...overrides,
  };
}

test("多季分别表达季度与集数是否完整", () => {
  assert.equal(formatLibraryInventorySummary(summary()), "全 8 季 · 64 集");
  assert.equal(
    formatLibraryInventorySummary(summary({ episode_count: 80, all_episodes_owned: true })),
    "全 8 季 · 全 80 集",
  );
  assert.equal(
    formatLibraryInventorySummary(summary({ season_count: 3, all_seasons_owned: false })),
    "共 3 季 · 64 集",
  );
  assert.equal(
    formatLibraryInventorySummary(
      summary({
        season_count: 3,
        episode_count: 24,
        all_seasons_owned: false,
        all_episodes_owned: true,
      }),
    ),
    "共 3 季 · 全 24 集",
  );
});

test("单季收齐写全，未齐时展示实际与官方总集数", () => {
  assert.equal(
    formatLibraryInventorySummary(
      summary({
        season_count: 1,
        season_number: 2,
        episode_count: 8,
        total_episode_count: 8,
        all_episodes_owned: true,
      }),
    ),
    "第 2 季 · 全 8 集",
  );
  assert.equal(
    formatLibraryInventorySummary(
      summary({ season_count: 1, season_number: 2, episode_count: 5, total_episode_count: 8 }),
    ),
    "第 2 季 · 5/8 集",
  );
});

test("特别篇与未知官方集数保持明确但不冒充完整", () => {
  assert.equal(
    formatLibraryInventorySummary(
      summary({
        season_count: 0,
        season_number: 0,
        episode_count: 3,
        total_episode_count: 3,
        all_seasons_owned: false,
        all_episodes_owned: true,
      }),
    ),
    "特别篇 · 全 3 集",
  );
  assert.equal(
    formatLibraryInventorySummary(
      summary({ season_count: 1, season_number: 1, episode_count: 5, total_episode_count: null }),
    ),
    "第 1 季 · 5 集",
  );
});

test("库存操作与季集完整度文案使用同一判断", () => {
  assert.equal(libraryInventoryAction("movie", null), "none");
  assert.equal(libraryInventoryAction("tv", null), "none");
  assert.equal(libraryInventoryAction("tv", summary()), "backfill");
  assert.equal(
    libraryInventoryAction(
      "tv",
      summary({ episode_count: 80, all_seasons_owned: true, all_episodes_owned: true }),
    ),
    "follow",
  );
});

test("缺季或单季缺集均优先提示补齐", () => {
  assert.equal(
    libraryInventoryAction(
      "tv",
      summary({ all_seasons_owned: false, all_episodes_owned: true }),
    ),
    "backfill",
  );
  assert.equal(
    libraryInventoryAction(
      "tv",
      summary({
        season_count: 1,
        season_number: 2,
        episode_count: 5,
        total_episode_count: 8,
        all_seasons_owned: true,
        all_episodes_owned: false,
      }),
    ),
    "backfill",
  );
});

test("English inventory summaries keep single, partial, complete and special counts distinct", () => {
  const cases = [
    [{}, "All 8 seasons · 64 episodes"],
    [{ season_count: 1, all_seasons_owned: false, episode_count: 1 }, "1 season · 1 episode"],
    [{ season_number: 1, episode_count: 3, total_episode_count: 10 }, "Season 1 · 3/10 episodes"],
    [{ season_number: 0, episode_count: 1, all_episodes_owned: true }, "Specials · 1 episode (complete)"],
    [{ all_episodes_owned: true }, "All 8 seasons · All 64 episodes"],
  ];
  for (const [input, expected] of cases) {
    const value = summary(input);
    const before = structuredClone(value);
    assert.equal(formatLibraryInventorySummary(value, "en"), expected);
    assert.deepEqual(value, before);
  }
});
