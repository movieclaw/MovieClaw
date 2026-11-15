import assert from "node:assert/strict";
import test from "node:test";

import {
  formatRelativeTime,
  formatTimelineDayLabel,
  formatTimelineTime,
  timelineDayKey,
} from "../lib/time.ts";

test("当天的 Feed 记录显示时分", () => {
  assert.equal(
    formatTimelineTime("2026-08-15T14:32:00+08:00", "2026-08-15T20:00:00+08:00"),
    "14:32",
  );
});

test("跨天的 Feed 记录显示月日，避免历史时间被误看成当天", () => {
  assert.equal(
    formatTimelineTime("2026-08-12T14:32:00+08:00", "2026-08-15T20:00:00+08:00"),
    "08/12",
  );
});

test("空时间沿用全局占位符", () => {
  assert.equal(formatTimelineTime(null), "—");
});

test("历史 Feed 按本地日期生成稳定分组键", () => {
  assert.equal(timelineDayKey("2026-08-14T23:30:00+08:00"), "2026-08-14");
});

test("历史 Feed 使用今天早些时候、昨天和具体日期标题", () => {
  const reference = "2026-08-15T20:00:00+08:00";
  assert.equal(formatTimelineDayLabel("2026-08-15T08:00:00+08:00", reference), "今天早些时候");
  assert.equal(formatTimelineDayLabel("2026-08-14T08:00:00+08:00", reference), "昨天");
  assert.equal(formatTimelineDayLabel("2026-08-12T08:00:00+08:00", reference), "8月12日");
  assert.equal(
    formatTimelineDayLabel("2025-08-12T08:00:00+08:00", reference),
    "2025年8月12日",
  );
});

test("relative times follow the UI language, including German", () => {
  const threeMinutesAgo = new Date(Date.now() - 3 * 60 * 1000).toISOString();
  assert.equal(formatRelativeTime(threeMinutesAgo, "de"), "vor 3 Minuten");
  assert.equal(formatRelativeTime(threeMinutesAgo, "en"), "3 minutes ago");
  assert.equal(formatRelativeTime(threeMinutesAgo, "zh-Hans"), "3 分钟前");
});
