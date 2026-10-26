import assert from "node:assert/strict";
import test from "node:test";
import { arrivalStageOf, arrivalStatusText, todayArrivalPresentation } from "../lib/subscription-ui.ts";
import { clockText, fromNow, scheduleDays, shelfCountSummary, subscriptionsHomeState, weekdayOf, wallSummary } from "../lib/subscriptions-home.ts";

const now = new Date("2026-10-24T04:00:00Z");
function sub(id, kind, status = "active", progress = {}) {
  return {
    id, status, selected_seasons: kind === "tv" ? [1] : [], follow_future: kind === "tv", rule_set_id: 1,
    media: { media_item_id: id, tmdb_id: id, kind, title: "原始片名", original_title: "Raw title", year: 2026, status: kind === "movie" ? "Released" : "Returning Series" },
    progress: { total: 8, wanted: 1, grabbed: 0, downloaded: 0, imported: 0, ...progress },
    season_collection: kind === "tv" ? [{ season_number: 1, episode_count: 8, aired_count: 8, owned_count: status === "completed" ? 8 : 4 }] : [],
    created_at: "2026-01-01T00:00:00Z", updated_at: "2026-10-01T00:00:00Z",
  };
}
function arrival(id, status, daysAhead = 0) {
  return { subscription_id: id, wanted_id: id, media_kind: "tv", media_title: "原始片名", season_number: 1, episode_number: 1, status, days_ahead: daysAhead, expected_day: daysAhead ? "2026-10-26" : "2026-10-24", air_date: "2026-10-24", info_hash: `hash${id}`, estimated_download_to_import_minutes: 5, release_forecast: null };
}
const subscriptions = [sub(1, "tv", "active", { grabbed: 1 }), sub(2, "tv"), sub(3, "tv", "paused"), sub(4, "tv", "completed", { wanted: 0, imported: 8 }), sub(5, "movie"), sub(6, "movie", "completed", { wanted: 0, imported: 1 })];
const arrivals = [arrival(1, "grabbed"), arrival(2, "wanted", 2)];
const recent = [{ subscription_id: 2, media: subscriptions[1].media, imported_at: "2026-10-24T03:55:00Z", season_number: 1, episode_number: 2, episode_name: "原始集名", units: [{ season_number: 1, episode_number: 2 }, { season_number: 1, episode_number: 3 }], progress_percent: 25 }];
const tasks = [{ info_hash: "hash1", state: "downloading", progress: 0.65, eta_seconds: 120 }];
function renderedCopy(state) {
  return [
    ...state.slides.flatMap((s) => [s.eyebrow.text, s.clockLabel, s.clock, s.detail, s.footnote]),
    ...state.days.flatMap((d) => [d.weekday, d.dateLabel, ...d.entries.flatMap((e) => [e.status, e.episodeLabel, e.time])]),
    ...[state.tv, state.movie].flatMap((s) => [s.restingLabel, ...[...s.active, ...s.paused, ...s.done].flatMap((i) => [i.chip?.text, i.meta])]),
  ].filter(Boolean).join("\n").replaceAll("原始集名", "");
}

test("home presentation follows explicit reader locale while preserving shelf and hero identity", () => {
  const original = JSON.stringify([subscriptions, arrivals, recent, tasks]);
  let identity;
  for (const locale of ["en", "zh-Hans", "en"]) {
    const state = subscriptionsHomeState(subscriptions, arrivals, recent, tasks, now, locale);
    const ids = JSON.stringify({ hero: state.slides.map((s) => s.subscriptionId), active: state.tv.active.map((i) => i.sub.id), paused: state.tv.paused.map((i) => i.sub.id), done: state.tv.done.map((i) => i.sub.id) });
    if (identity) assert.equal(ids, identity);
    identity = ids;
    assert.equal(state.slides.find((s) => s.stage === "arrived").play.mediaItemId, 2);
    if (locale === "en") assert.doesNotMatch(renderedCopy(state), /[\u3400-\u9fff]/u);
    else assert.match(renderedCopy(state), /暂停·收齐/);
  }
  assert.equal(JSON.stringify([subscriptions, arrivals, recent, tasks]), original);
});

test("legacy theme status discriminator remains stable and display text is localized separately", () => {
  const p = todayArrivalPresentation(arrival(1, "downloaded"), undefined, now, "en");
  assert.equal(p.statusLabel, "整理中");
  assert.equal(arrivalStageOf(p), "organizing");
  assert.equal(arrivalStatusText(p, "en"), "Organizing");
  assert.equal(arrivalStatusText(p, "zh-Hans"), "整理中");
});

test("relative times preserve thresholds and express English past, future and singular units", () => {
  for (const [seconds, chinese, english] of [[0, "几秒前", "a few seconds ago"], [45, "1 分钟前", "1 minute ago"], [120, "2 分钟前", "2 minutes ago"], [3600, "1 小时前", "1 hour ago"], [86400, "1 天前", "1 day ago"], [2592000, "1 个月前", "1 month ago"]]) {
    assert.equal(fromNow(now.getTime() - seconds * 1000, now, "zh-Hans"), chinese);
    assert.equal(fromNow(now.getTime() - seconds * 1000, now, "en"), english);
  }
  assert.equal(fromNow(now.getTime() + 120000, now, "en"), "in 2 minutes");
  assert.equal(fromNow(now.getTime() + 120000, now, "zh-Hans"), "2 分钟内");
});

test("calendar days retain site dates and localized weekdays while clock labels remain 24-hour", () => {
  const state = subscriptionsHomeState(subscriptions, arrivals, [], tasks, now, "en");
  assert.equal(state.days[0].weekday, "Today");
  assert.equal(state.days[0].dateLabel, "Oct 24");
  assert.equal(weekdayOf("2026-10-25", "en"), "Sun");
  assert.equal(weekdayOf("2026-10-25", "zh-Hans"), "周日");
  assert.equal(clockText(new Date(2026, 9, 25, 8, 10).getTime(), new Date(2026, 9, 24, 12), "en"), "Tomorrow 08:10");
  assert.equal(scheduleDays([], subscriptions, now, "en").length, 0);
});

test("shelf and wall counts use whole summaries with singular and plural titles", () => {
  const empty = { active: [], paused: [], done: [] };
  assert.equal(shelfCountSummary({ ...empty, active: [1] }, "en"), "1 title total");
  assert.equal(shelfCountSummary({ ...empty, active: [1], done: [2] }, "en"), "1 active · 2 total");
  assert.equal(wallSummary({ ...empty, active: [1] }, "movie", "en"), "1 movie total");
  assert.equal(wallSummary({ ...empty, active: [1], done: [2] }, "tv", "en"), "2 series total · 1 active");
  assert.equal(wallSummary({ ...empty, active: [1], done: [2] }, "tv", "zh-Hans"), "共 2 部剧集 · 1 部进行中");
});
