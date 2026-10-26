import assert from "node:assert/strict";
import test from "node:test";
import { activeJobStatus, downloadLifecycleSteps, downloadStateMeta, downloadTaskNote, groupHistoricalJobs, historicalJobTitle, ingestStateMeta, jobFeedIdentity, jobProgressAmount } from "../lib/task-presentation.ts";
import { contentMissingLabel, downloadTaskNeedsAttention } from "../lib/download-attention.ts";
import { summarizeEpisodeUnits } from "../lib/episode-units.ts";

function task(overrides = {}) {
  return { state: "downloading", progress: 0.5, downloader_name: "原始下载器", source: "subscription", size_bytes: 1024, subscriptions: [], plan: null, landing_error: null, error_message: null, rescue_message: null, ...overrides };
}
function job(status = "running", overrides = {}) {
  return { id: "job_raw", job_type: "library.scan", status, subject: "原始库", origin: "web", actor_name: "原始用户", error: null, dismissed_at: null, input_data: {}, progress: { message: "Original progress", phase: "walking", current: 1, total: 2, details: {} }, created_at: "2026-01-01T00:00:00Z", finished_at: null, ...overrides };
}
function subscription(purpose, done) {
  return [{ purpose, upgrade_keep_old: false, units: [1, 2].map((episode_number) => ({ season_number: 1, episode_number, status: purpose === "upgrade" || episode_number <= done ? "imported" : "wanted", replaced: purpose === "upgrade" && episode_number <= done, content_missing: false })) }];
}
const withoutRaw = (value) => JSON.stringify(value).replaceAll("原始下载器", "").replaceAll("原始库", "").replaceAll("原始用户", "");

test("task identities use structured title facts in both languages, retaining legacy histories", () => {
  const row = job("succeeded", { job_type: "media.metadata.refresh", subject: "Release.Name", progress: { message: "正在刷新《原始作品》", message_key: "library.metadata.example", message_params: { title: "原始作品" }, details: {} } });
  assert.equal(jobFeedIdentity(row, "zh-Hans"), "《原始作品》");
  row.progress.message = "Refreshing “原始作品”";
  assert.equal(jobFeedIdentity(row, "en"), "“原始作品”");
  assert.equal(historicalJobTitle(row, "en"), "“原始作品” · Metadata refresh completed");
  assert.equal(historicalJobTitle(row, "zh-Hans"), "《原始作品》元数据刷新完成");
  const legacy = job("failed", { progress: { message: "正在处理《旧记录原名》", details: {} } });
  assert.equal(jobFeedIdentity(legacy, "zh-Hans"), "「旧记录原名」");
  assert.equal(activeJobStatus(job("running", { job_type: "constructor" }), "en"), "Working");
  const index = job("succeeded", { job_type: "library.search-index.refresh", subject: "更新媒体库搜索索引" });
  assert.equal(jobFeedIdentity(index, "en"), "Update library search index");
  assert.equal(jobFeedIdentity(index, "zh-Hans"), index.subject);
  index.subject = "原始自定义任务名";
  assert.equal(jobFeedIdentity(index, "en"), index.subject);
});

test("download and import metadata follows the reader without changing colors or tones", () => {
  for (const state of ["downloading", "stalled", "paused", "queued", "checking", "completed", "error", "missing", "unknown"]) {
    const zh = downloadStateMeta(state, "zh-Hans"), en = downloadStateMeta(state, "en");
    assert.equal(en.dot, zh.dot); assert.equal(en.color, zh.color);
    assert.doesNotMatch(en.label, /[\u3400-\u9fff]/u);
  }
  for (const status of ["queued", "running", "retry_wait", "cancelling", "waiting", "blocked", "succeeded", "failed", "cancelled"]) {
    assert.doesNotMatch(ingestStateMeta(status, "en").label, /[\u3400-\u9fff]/u);
  }
  assert.equal(jobProgressAmount(job(), "en"), "Processed 1 / 2 files");
  assert.equal(jobProgressAmount(job("running", { job_type: "library.transfer" }), "zh-Hans"), "已处理 1 / 2 项");
});

test("future steps describe the same destination and strategy facts", () => {
  for (const strategy of ["hardlink", "copy", null]) for (const enters of [false, true]) {
    const row = task({ plan: { mode: "watch", strategy, enters_library: enters, library_name: "原始库", dest_path: "/raw-output" }, subscriptions: subscription("download", 0) });
    const original = JSON.stringify(row);
    const en = downloadLifecycleSteps(row, null, "en"), zh = downloadLifecycleSteps(row, null, "zh-Hans");
    assert.equal(en.length, zh.length);
    assert.deepEqual(en.map((step) => step.tone), zh.map((step) => step.tone));
    assert.doesNotMatch(withoutRaw(en), /[\u3400-\u9fff]/u);
    assert.ok(en.some((step) => step.detail.includes("/raw-output")));
    if (enters) assert.ok(en.some((step) => step.label === "Pending import"));
    assert.equal(JSON.stringify(row), original);
  }
});

test("partial delivery and replacement retain counts and never treat an upgrade as already done", () => {
  for (const purpose of ["download", "upgrade"]) for (const done of [0, 1, 2]) {
    const row = task({ state: "completed", subscriptions: subscription(purpose, done) });
    const steps = downloadLifecycleSteps(row, job("succeeded"), "en");
    assert.doesNotMatch(withoutRaw(steps), /[\u3400-\u9fff]/u);
    const note = downloadTaskNote(row, job("succeeded"), "en");
    if (done < 2) assert.match(note, new RegExp(`${done}/2 episodes`));
    else assert.match(note, /complete/);
    if (purpose === "upgrade" && done === 0) assert.equal(steps.at(-1).label, "Waiting for replacement");
  }
});

test("missing units translate their count but attention and unmarked external reasons stay original", () => {
  const row = task({ subscriptions: subscription("download", 0) });
  row.subscriptions[0].units.forEach((unit) => { unit.content_missing = true; });
  assert.equal(contentMissingLabel(row, "zh-Hans"), "S01E01 等 2 集");
  assert.equal(contentMissingLabel(row, "en"), "2 episodes including S01E01");
  assert.equal(downloadTaskNeedsAttention(row, null), true);
  assert.match(downloadTaskNote(row, null, "en"), /2 episodes including S01E01/);
  const external = task({ state: "error", source: "external", error_message: "原始第三方错误" });
  assert.equal(downloadTaskNote(external, null, "en"), "原始第三方错误 (not dispatched by MovieClaw; observation only)");
  assert.equal(downloadTaskNeedsAttention(external, null), false);
});

test("episode ranges and history group keys remain stable across display languages", () => {
  assert.equal(summarizeEpisodeUnits([{ season_number: 0, episode_number: 0 }], "en").label, "Feature");
  const units = [1, 3, 5, 7].map((episode_number) => ({ season_number: 1, episode_number }));
  const en = summarizeEpisodeUnits(units, "en"), zh = summarizeEpisodeUnits(units, "zh-Hans");
  assert.deepEqual(en.seasons, zh.seasons);
  assert.equal(en.label, "S01E01, E03 · 2 more episodes");
  assert.equal(zh.label, "S01E01、E03 · 另 2 集");
  const rows = [job("failed"), job("cancelled", { id: "job_second", created_at: "2025-12-31T00:00:00Z" })];
  assert.deepEqual(groupHistoricalJobs(rows, "en").map((g) => [g.key, g.jobs.map((j) => j.id)]), groupHistoricalJobs(rows, "zh-Hans").map((g) => [g.key, g.jobs.map((j) => j.id)]));
});

test("import history translates derived copy while preserving the exact file snapshots", async () => {
  const { buildIngestHistoryDetail } = await import("../lib/ingest-history.ts");
  const row = job("succeeded", { job_type: "library.ingest", input_data: { ready_files: ["Raw.Show.S01E01.mkv", "Raw.Show.S01E03.mkv"] }, progress: { message: "已识别为《作品》，入库到订阅指定的「原始库」，复制 1 个文件", details: { imported_files: ["Raw.Show.S01E01.mkv"], already_present_files: ["Raw.Show.S01E03.mkv"] } } });
  const zh = buildIngestHistoryDetail(row, "zh-Hans"), en = buildIngestHistoryDetail(row, "en");
  assert.deepEqual(en.fileGroups.map((group) => group.files), zh.fileGroups.map((group) => group.files));
  assert.match(en.summary, /S01E01/);
  assert.match(en.context, /原始库/);
  assert.doesNotMatch(en.summary, /[\u3400-\u9fff]/u);
  assert.equal(row.progress.message, "已识别为《作品》，入库到订阅指定的「原始库」，复制 1 个文件");
});

test("cleanup receipts and opt-in defaults follow the display language", async () => {
  const { boostCleanupSummary, boostCleanupCheckbox, formatCleanupDeadline } = await import("../lib/boost-cleanup.ts");
  const result = { deleted_count: 1, deleted_bytes: 1024, scheduled_count: 2, scheduled_until: "2026-10-29T06:00:00Z", failed_count: 1 };
  for (const locale of ["zh-Hans", "en"]) {
    const checkbox = boostCleanupCheckbox(2, 1024, locale);
    assert.equal(checkbox.defaultChecked, false);
    assert.match(checkbox.label, /2/);
    assert.match(boostCleanupSummary(result, locale), /1.*2.*1/);
  }
  assert.doesNotMatch(boostCleanupSummary(result, "en"), /[\u3400-\u9fff]/u);
  assert.equal(formatCleanupDeadline(null, "en"), null);
  assert.equal(formatCleanupDeadline("bad", "en"), "Invalid Date");
  assert.match(formatCleanupDeadline(result.scheduled_until, "en"), /Oct 29/);
});

test("activity summaries translate without changing alert, ratio, or boost mode facts", async () => {
  const { activitySummaryParts, weeklyDelta, weekdayLabel, boostSummary } = await import("../lib/activity-overview.ts");
  const counts = { attention: 2, watching: 1, downloading: 3, active: 4 };
  assert.deepEqual(activitySummaryParts(counts, "en").map((p) => p.alert), activitySummaryParts(counts, "zh-Hans").map((p) => p.alert));
  const stats = { previous_available: true, current: { watched_ms: 150 }, previous: { watched_ms: 100 } };
  assert.equal(weeklyDelta(stats, "en").tone, "up");
  assert.match(weeklyDelta(stats, "en").text, /50%/);
  assert.equal(weekdayLabel("2026-09-27", "en"), "Sun");
  const tasks = [{ site_id: "raw", site_name: "原始站点", info_hash: "HASH", uploaded_bytes: 2048, completed_bytes: 1024, upspeed_bytes: 512, dlspeed_bytes: 128 }];
  for (const mode of ["running", "paused", "off"]) {
    const pool = { sites: [{ site_id: "raw", boost_enabled: mode !== "off", boost_paused: mode === "paused" }], tasks: [{ info_hash: "HASH", cleanup_scheduled: true }] };
    const en = boostSummary(tasks, pool, "en"), zh = boostSummary(tasks, pool, "zh-Hans");
    assert.equal(en.mode, mode);
    assert.equal(en.mode, zh.mode);
    assert.doesNotMatch(JSON.stringify(en), /[\u3400-\u9fff]/u);
  }
});
