import assert from "node:assert/strict";
import test from "node:test";

import {
  episodeRangeLabel,
  episodeRanges,
  rangeContaining,
  rangeEntry,
  seasonAnchor,
} from "../lib/episode-ranges.ts";

const numbers = (from, to) => Array.from({ length: to - from + 1 }, (_, i) => from + i);
const episode = (n, extra = {}) => ({
  episode_number: n,
  owned: true,
  played: false,
  position_ms: 0,
  ...extra,
});

test("50 集及以下不分段，界面保持改版前的样子", () => {
  assert.deepEqual(episodeRanges(numbers(1, 50)), []);
  assert.deepEqual(episodeRanges(numbers(1, 12)), []);
});

test("超过 50 集按集号每 50 集一段，段名用段内实际首末集号", () => {
  const ranges = episodeRanges(numbers(1, 1186));
  assert.equal(ranges.length, 24);
  assert.equal(episodeRangeLabel(ranges[0]), "1–50");
  assert.equal(episodeRangeLabel(ranges[20]), "1001–1050");
  assert.equal(episodeRangeLabel(ranges[23]), "1151–1186");
});

test("按集号而不是按位置切段，空段不出现", () => {
  const ranges = episodeRanges([...numbers(3, 40), ...numbers(151, 175)]);
  assert.deepEqual(
    ranges.map(episodeRangeLabel),
    ["3–40", "151–175"],
  );
  assert.deepEqual(
    ranges.map((r) => r.index),
    [0, 3],
  );
});

test("手动换段：段里有锚点选锚点，否则段首", () => {
  const ranges = episodeRanges(numbers(1, 1186));
  const anchorRange = rangeContaining(ranges, 1050);
  assert.equal(episodeRangeLabel(anchorRange), "1001–1050");
  assert.equal(rangeEntry(anchorRange, 1050), 1050);
  assert.equal(rangeEntry(rangeContaining(ranges, 1051), 1050), 1051);
  assert.equal(rangeEntry(ranges[0], 1050), 1);
  assert.equal(rangeEntry(ranges[0], null), 1);
  assert.equal(rangeContaining(ranges, 2000), undefined);
});

test("锚点以服务端 resume_episode 为准，不被客户端扫描覆盖", () => {
  const episodes = numbers(1, 1186).map((n) =>
    episode(n, { played: n < 1050 && n !== 3, position_ms: n === 120 ? 1 : 0 }),
  );
  assert.equal(seasonAnchor({ episodes, resume_episode: 1050 }), 1050);
});

test("没有锚点时退回原规则：看了一半 → 没看过 → 第一集，有片源的优先", () => {
  const halfway = [episode(1, { played: true }), episode(2, { position_ms: 5 }), episode(3)];
  assert.equal(seasonAnchor({ episodes: halfway, resume_episode: null }), 2);
  const unwatched = [episode(1, { played: true }), episode(2, { owned: false }), episode(3)];
  assert.equal(seasonAnchor({ episodes: unwatched }), 3);
  const allPlayed = [episode(1, { owned: false }), episode(2, { played: true })];
  assert.equal(seasonAnchor({ episodes: allPlayed }), 2);
  assert.equal(seasonAnchor({ episodes: [episode(1, { owned: false })] }), 1);
  assert.equal(seasonAnchor({ episodes: [] }), null);
  // 服务端给的集号不在清单里（数据不一致）也退回原规则
  assert.equal(seasonAnchor({ episodes: halfway, resume_episode: 99 }), 2);
});
