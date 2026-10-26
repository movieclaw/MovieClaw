import assert from "node:assert/strict";
import test from "node:test";
import { jobTypeLabel, jobStatusLabel, jobPhaseLabel, subtitleLanguageLabel, subtitleUsageSummary, formatInteger, formatModelDuration, originLabel, progressAmount, jobDetailItems } from "../lib/job-presentation.ts";

function job(type = "subtitle.generate", details = {}) {
  return {
    job_type: type, job_type_label: "原始插件名称", origin: "scheduler", actor_name: "原始发起人",
    input_data: { target_language: "jpn", secondary_language: "eng" },
    progress: { current: 1, total: 2, details },
    usage: { request_count: 1, failed_request_count: 1, prompt_tokens: 12345, completion_tokens: 2, total_tokens: 12347, cache_read_tokens: 4, total_duration_ms: 1550, max_duration_ms: 950 },
  };
}

test("known types, statuses and phases translate without freezing module state", () => {
  for (const locale of ["en", "zh-Hans", "en"]) {
    assert.equal(jobTypeLabel(job(), locale), locale === "en" ? "Generate AI subtitles" : "生成 AI 字幕");
    assert.equal(jobStatusLabel("retry_wait", locale), locale === "en" ? "Waiting to retry" : "等待重试");
    assert.equal(jobPhaseLabel("syncing", locale), locale === "en" ? "Aligning timestamps" : "校准时间轴");
  }
  assert.equal(jobTypeLabel(job("plugin.raw"), "en"), "原始插件名称");
  assert.equal(jobTypeLabel({ job_type: "__proto__" }, "en"), "__proto__");
  assert.equal(jobStatusLabel("constructor", "en"), "constructor");
  assert.equal(jobPhaseLabel("raw-stage", "en"), "raw-stage");
});

test("subtitle languages use confirmed details before input and preserve unknown language values", () => {
  const row = job("subtitle.generate", { target_language: "chs" });
  assert.equal(subtitleLanguageLabel(row, "en"), "Simplified Chinese + English (bilingual)");
  assert.equal(subtitleLanguageLabel(row, "zh-Hans"), "简体中文 + 英语（双语）");
  row.progress.details.secondary_language = "raw-language";
  assert.equal(subtitleLanguageLabel(row, "en"), "Simplified Chinese + raw-language (bilingual)");
  assert.equal(subtitleLanguageLabel(job("library.scan"), "en"), null);
});

test("progress units and number summaries follow an explicit locale", () => {
  for (const [type, unit] of [["subtitle.generate", "chunks"], ["library.scan", "files"], ["media.metadata.refresh", "images"], ["library.metadata.refresh", "items"], ["library.transfer", "paths"], ["raw.type", "items"]]) {
    assert.equal(progressAmount(job(type), "en"), `1 / 2 ${unit}`);
    const single = job(type); single.progress.total = 1;
    assert.equal(progressAmount(single, "en"), `1 / 1 ${unit.slice(0, -1)}`);
  }
  const row = job("library.ingest"); row.progress.current = 1024; row.progress.total = 2048;
  assert.equal(progressAmount(row, "en"), "1.00 KB / 2.00 KB");
  row.progress.total = null;
  assert.equal(progressAmount(row, "en"), null);
  assert.equal(formatInteger(12345, "en"), "12,345");
  assert.equal(formatModelDuration(950, "en"), "950 milliseconds");
  assert.equal(formatModelDuration(1, "en"), "1 millisecond");
  assert.equal(formatModelDuration(0, "en"), "—");
});

test("detail rows keep alert priority, four-row limit and original file names", () => {
  const row = job("library.metadata.refresh", { failed: 1, images: { failed: 1, downloaded: 2, bytes: 1024, reused: 1, adopted: 1, derived: 1, grabbed: 1 } });
  const original = JSON.stringify(row);
  assert.deepEqual(jobDetailItems(row, "en"), [
    { label: "1 unfinished item", alert: true },
    { label: "1 image not downloaded", alert: true },
    { label: "2 new images downloaded · 1.00 KB" },
    { label: "1 image reused" },
  ]);
  assert.equal(JSON.stringify(row), original);
  assert.deepEqual(jobDetailItems(job("library.ingest", { file_name: "原始文件.mkv" }), "en"), [{ label: "原始文件.mkv" }]);
  const subtitles = job("subtitle.generate", { target_language: "chs", done_events: 1, total_events: 2, parallelism: 2, rate_limit_count: 1 });
  assert.deepEqual(jobDetailItems(subtitles, "en"), [{ label: "Simplified Chinese + English (bilingual)" }, { label: "1 / 2 subtitles" }, { label: "2 concurrent" }, { label: "1 rate-limit retry", alert: true }]);
});

test("actor identity and usage facts remain original across reader languages", () => {
  const row = job(); const original = JSON.stringify(row);
  assert.equal(originLabel(row, "en"), "Automatic · 原始发起人");
  assert.equal(originLabel(row, "zh-Hans"), "系统自动 · 原始发起人");
  assert.deepEqual(subtitleUsageSummary(row), { requests: 1, failedRequests: 1, promptTokens: 12345, completionTokens: 2, totalTokens: 12347, cacheReadTokens: 4, totalDurationMs: 1550, maxDurationMs: 950 });
  assert.equal(subtitleUsageSummary(job("library.scan")), null);
  assert.equal(JSON.stringify(row), original);
});
