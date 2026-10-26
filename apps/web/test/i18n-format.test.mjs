import assert from "node:assert/strict";
import test from "node:test";
import dayjs from "dayjs";
import { formatDuration, formatRuntimeMinutes, formatCompact, formatNumber, formatList } from "../lib/format.ts";
import { formatTimelineDayLabel, formatRelativeTime, formatDateTime } from "../lib/time.ts";

test("Chinese formatting keeps the existing wording and precision", () => {
  assert.equal(formatDuration(15, "zh-Hans"), "15 秒");
  assert.equal(formatDuration(90, "zh-Hans"), "2 分钟");
  assert.equal(formatDuration(3601, "zh-Hans"), "1.0 小时");
  assert.equal(formatRuntimeMinutes(83, "zh-Hans"), "1 小时 23 分钟");
  assert.equal(formatCompact(12345, "zh-Hans"), "1.2万");
  assert.equal(formatList(["A", "B"], "zh-Hans"), "A、B");
});

test("English numbers, durations and lists use the active language", () => {
  assert.equal(formatDuration(1, "en"), "1 second");
  assert.equal(formatDuration(15, "en"), "15 seconds");
  assert.equal(formatDuration(3600, "en"), "1 hour");
  assert.equal(formatRuntimeMinutes(83, "en"), "1 hr 23 min");
  assert.equal(formatCompact(12345, "en"), "12.3K");
  assert.equal(formatNumber(12345, undefined, "en"), "12,345");
  assert.equal(formatList(["A", "B"], "en"), "A and B");
});

test("date instances do not mutate dayjs global language", () => {
  const original = dayjs.locale();
  const reference = "2026-08-15T20:00:00+08:00";
  assert.equal(formatTimelineDayLabel("2026-08-14T08:00:00+08:00", reference, "en"), "Yesterday");
  assert.equal(formatTimelineDayLabel("2026-08-12T08:00:00+08:00", reference, "en"), "Aug 12");
  assert.equal(formatRelativeTime(null, "en"), "Never");
  assert.match(formatDateTime("2026-08-12T08:00:00+08:00", "en"), /Aug 12, 2026/);
  assert.equal(formatTimelineDayLabel("2026-08-14T08:00:00+08:00", reference, "zh-Hans"), "昨天");
  assert.equal(dayjs.locale(), original);
});
