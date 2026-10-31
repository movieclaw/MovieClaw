import assert from "node:assert/strict";
import test from "node:test";
import {
  airCounts,
  airDays,
  arrivalState,
  breaksCadence,
  cadenceOf,
  episodeTone,
  gapBetween,
  nextAirDay,
  weekOffset,
} from "../lib/air-schedule.ts";

const ep = (n, air, owned = false) => ({
  episode_number: n, name: null, overview: null, air_date: air, still_url: null,
  owned, file_ids: [], position_ms: 0, played: false, progress_percent: null,
});
// 2026-10-28 是周三；周一至周四每天两集
const schedule = {
  today: "2026-10-28", region: null, weekdays: [0, 1, 2, 3], last_air_date: "2026-11-02",
  subscription_id: 9, missing_episodes: [3],
  arrivals: [{ episode_number: 5, stage: "waiting", expected_at: "2026-10-28T12:00:00+00:00" }],
};
const episodes = [
  ep(1, "2026-10-26", true), ep(2, "2026-10-26", true),
  ep(3, "2026-10-27"), ep(4, "2026-10-27", true),
  ep(5, "2026-10-28"), ep(6, "2026-10-28"),
  ep(7, "2026-10-29"), ep(8, "2026-11-02"), ep(9, null),
];

test("一集的状态：缺集只认服务端给的订阅缺口，今天按订阅与否分两种", () => {
  assert.deepEqual(episodes.map((e) => episodeTone(e, schedule)),
    ["owned", "owned", "missing", "owned", "today", "today", "upcoming", "upcoming", "upcoming"]);
  const free = { ...schedule, subscription_id: null, missing_episodes: [] };
  assert.equal(episodeTone(ep(3, "2026-10-27"), free), "absent");
  assert.equal(episodeTone(ep(5, "2026-10-28"), free), "todayFree");
});

test("日程按周分组：周一起算，本周 0、下周 1，已播为负", () => {
  // 2026-10-28 是周三，本周是 10-26（周一）到 11-01（周日）
  assert.deepEqual(["2026-10-26", "2026-10-28", "2026-11-01", "2026-11-02", "2026-11-09", "2026-10-25"]
    .map((day) => weekOffset("2026-10-28", day)), [0, 0, 0, 1, 2, -1]);
  // 今天是周日、周一时也落在同一周
  assert.equal(weekOffset("2026-11-01", "2026-10-26"), 0);
  assert.equal(weekOffset("2026-10-26", "2026-11-01"), 0);
});

test("汇总、按天分组与下次更新", () => {
  assert.deepEqual(airCounts(episodes, schedule), { owned: 3, missing: 1, upcoming: 3 });
  const days = airDays(episodes, schedule);
  assert.deepEqual(days.map((d) => [d.date, d.episodes.length, d.past, d.today, d.finale]), [
    ["2026-10-26", 2, true, false, false],
    ["2026-10-27", 2, true, false, false],
    ["2026-10-28", 2, false, true, false],
    ["2026-10-29", 1, false, false, false],
    ["2026-11-02", 1, false, false, true],
  ]);
  assert.equal(nextAirDay(days).date, "2026-10-28");
});

test("更新规律与停更间隙", () => {
  assert.deepEqual(cadenceOf([0, 1, 2, 3], "zh-Hans"), { kind: "range", from: "周一", to: "周四" });
  assert.deepEqual(cadenceOf([3], "zh-Hans"), { kind: "weekly", day: "周四" });
  assert.deepEqual(cadenceOf([0, 1, 2, 3, 4, 5, 6], "zh-Hans"), { kind: "daily" });
  assert.equal(cadenceOf([1, 4], "zh-Hans").kind, "list");
  assert.equal(cadenceOf([], "zh-Hans"), null);
  assert.deepEqual(gapBetween("2026-10-29", "2026-11-02", "zh-Hans"), { kind: "range", from: "周五", to: "周日" });
  assert.deepEqual(gapBetween("2026-10-29", "2026-10-31", "zh-Hans"), { kind: "day", day: "周五" });
  assert.equal(gapBetween("2026-10-28", "2026-10-29", "zh-Hans"), null);
  assert.deepEqual(gapBetween("2026-10-01", "2026-10-15", "zh-Hans"), { kind: "break", count: 13 });
});

test("停更分隔只标跳过了更新日的间隙，按节奏空着的日子不算", () => {
  // 周五、周六更新（4、5）：周六 → 下周五中间是周日到周四，正常节奏
  assert.equal(breaksCadence("2026-10-31", "2026-11-06", [4, 5]), false);
  // 周六 → 下下周五：跳过了 11-06、11-07 两个更新日
  assert.equal(breaksCadence("2026-10-31", "2026-11-13", [4, 5]), true);
  // 周四周更跳过一周
  assert.equal(breaksCadence("2026-10-29", "2026-11-12", [3]), true);
  assert.equal(breaksCadence("2026-10-29", "2026-11-05", [3]), false);
  assert.equal(breaksCadence("2026-10-28", "2026-10-29", [2, 3]), false);
});

test("同日几集的入库状态：在途优先，其次最早的预计时刻", () => {
  const today = episodes.filter((e) => e.air_date === "2026-10-28");
  assert.deepEqual(arrivalState(today, schedule), { kind: "expected", at: "2026-10-28T12:00:00+00:00" });
  assert.deepEqual(arrivalState(today, { ...schedule, arrivals: [
    { episode_number: 6, stage: "downloading", expected_at: null },
    { episode_number: 5, stage: "waiting", expected_at: "2026-10-28T12:00:00+00:00" },
  ] }), { kind: "downloading" });
  assert.deepEqual(arrivalState([ep(5, "2026-10-28", true)], schedule), { kind: "inLibrary" });
  assert.deepEqual(arrivalState(today, { ...schedule, subscription_id: null }), { kind: "notSubscribed" });
  assert.equal(arrivalState(today, { ...schedule, arrivals: [] }), null);
});
