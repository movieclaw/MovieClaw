import assert from "node:assert/strict";
import test from "node:test";

import {
  buildSeriesUpdateCalendar,
  latestSeasonProgress,
  ownedUnitsFromFiles,
  seriesStillAiring,
  siteCalendarToday,
} from "../lib/series-update-calendar.ts";

/** 固定「现在」：2026-10-13 12:00 UTC = 东八区 20:00，站点今天 = 2026-10-13 */
const now = new Date("2026-10-13T12:00:00.000Z");

function wanted(episode, extras = {}) {
  return {
    id: episode,
    season_number: extras.season ?? 1,
    episode_number: episode,
    status: extras.status ?? "wanted",
    air_date: extras.air_date ?? null,
    priority: 0,
    next_search_at: null,
    search_attempts: 0,
    last_search_at: null,
    release_forecast: extras.forecast ?? null,
    resource_timing: null,
    grabbed_at: null,
    downloaded_at: null,
    imported_at: null,
    info_hash: null,
    last_reject_reason: null,
    grab_title: null,
    upgrade: null,
  };
}

function forecast(airDate, predictedAt, confidence = "stable") {
  return {
    version: 1,
    generated_at: predictedAt,
    target_air_date: airDate,
    predicted_at: predictedAt,
    window_start: predictedAt,
    window_end: predictedAt,
    confidence,
    sample_count: 3,
    cadence_days: 1,
    basis_units: [],
    basis_torrent_row_ids: [],
    sites: [],
    first: {
      generated_at: predictedAt,
      predicted_at: predictedAt,
      window_start: predictedAt,
      window_end: predictedAt,
      confidence,
      sample_count: 3,
    },
  };
}

test("siteCalendarToday 按 Asia/Shanghai 取日历日", () => {
  // 2026-10-12 20:00 UTC = 东八区 10-13 04:00
  assert.equal(siteCalendarToday(new Date("2026-10-12T20:00:00.000Z")), "2026-10-13");
  // 2026-10-12 15:00 UTC = 东八区 10-12 23:00，仍是 12 号
  assert.equal(siteCalendarToday(new Date("2026-10-12T15:00:00.000Z")), "2026-10-12");
});

test("seriesStillAiring：完结/取消隐藏，在播与未知保留", () => {
  assert.equal(seriesStillAiring("Returning Series"), true);
  assert.equal(seriesStillAiring("In Production"), true);
  assert.equal(seriesStillAiring(null), true);
  assert.equal(seriesStillAiring("Ended"), false);
  assert.equal(seriesStillAiring("Canceled"), false);
});

test("一周内无排期 → null（整块隐藏）", () => {
  const calendar = buildSeriesUpdateCalendar(
    [wanted(1, { air_date: "2026-09-01" }), wanted(2, { air_date: "2026-11-01" })],
    [],
    { now, mediaStatus: "Returning Series" },
  );
  assert.equal(calendar, null);
});

test("完结剧即使有排期也隐藏", () => {
  const calendar = buildSeriesUpdateCalendar(
    [wanted(10, { air_date: "2026-10-14" })],
    [],
    { now, mediaStatus: "Ended" },
  );
  assert.equal(calendar, null);
});

test("按播出日分组：每天几集、已入库与预测时刻", () => {
  const rows = [
    wanted(5, { air_date: "2026-10-13", status: "imported" }),
    wanted(6, { air_date: "2026-10-13", status: "wanted" }),
    wanted(7, {
      air_date: "2026-10-14",
      forecast: forecast("2026-10-14", "2026-10-14T14:40:00.000Z"),
    }),
    wanted(8, { air_date: "2026-10-15", status: "grabbed" }),
  ];
  const calendar = buildSeriesUpdateCalendar(
    rows,
    [{ seasonNumber: 1, episodeNumber: 5 }],
    {
      now,
      mediaStatus: "Returning Series",
      seasonProgress: { owned: 5, total: 17, seasonNumber: 1 },
    },
  );
  assert.ok(calendar);
  assert.equal(calendar.days.length, 7);
  assert.match(calendar.caption, /10月13日/);
  assert.match(calendar.caption, /第 5 \/ 17 集/);
  assert.equal(calendar.progressNote, "已入库至第 5 集");

  const today = calendar.days[0];
  assert.equal(today.weekday, "今天");
  assert.equal(today.episodes.length, 2);
  assert.equal(today.episodes[0].label, "E05");
  assert.equal(today.episodes[0].owned, true);
  assert.equal(today.episodes[0].statusLabel, "已入库");
  assert.equal(today.episodes[1].label, "E06");
  assert.equal(today.episodes[1].owned, false);

  const tomorrow = calendar.days[1];
  assert.equal(tomorrow.episodes.length, 1);
  assert.equal(tomorrow.episodes[0].statusLabel, "预计入库");
  assert.ok(tomorrow.episodes[0].time); // 有预测时刻

  const dayAfter = calendar.days[2];
  assert.equal(dayAfter.episodes[0].statusLabel, "下载中");
  assert.equal(dayAfter.episodes[0].tone, "live");
});

test("跨季同天更新用 SxxExx 标签", () => {
  const calendar = buildSeriesUpdateCalendar(
    [
      wanted(10, { season: 1, air_date: "2026-10-13" }),
      wanted(1, { season: 2, air_date: "2026-10-13" }),
    ],
    [],
    { now, mediaStatus: "Returning Series" },
  );
  assert.ok(calendar);
  const labels = calendar.days[0].episodes.map((episode) => episode.label);
  assert.deepEqual(labels, ["S01E10", "S02E01"]);
});

test("ownedUnitsFromFiles 只收在位正季", () => {
  const units = ownedUnitsFromFiles([
    { season_number: 1, episode_number: 1, state: "in_place" },
    { season_number: 1, episode_number: 1, state: "in_place" }, // 去重
    { season_number: 1, episode_number: 2, state: "missing" },
    { season_number: 0, episode_number: 1, state: "in_place" },
    { season_number: 1, episode_number: 3 }, // 无 state 视为在位
  ]);
  assert.deepEqual(units, [
    { seasonNumber: 1, episodeNumber: 1 },
    { seasonNumber: 1, episodeNumber: 3 },
  ]);
});

test("latestSeasonProgress 取最新正季", () => {
  assert.deepEqual(
    latestSeasonProgress([
      { season_number: 0, owned_count: 2, episode_count: 5 },
      { season_number: 1, owned_count: 8, episode_count: 10 },
      { season_number: 2, owned_count: 3, episode_count: 12 },
    ]),
    { seasonNumber: 2, owned: 3, total: 12 },
  );
  assert.equal(latestSeasonProgress([]), null);
});
