import assert from "node:assert/strict";
import test from "node:test";

import {
  activitySummaryParts,
  boostSites,
  boostSummary,
  deliveryColor,
  deliveryDetail,
  deviceLabel,
  sortBoostTasks,
  weekdayLabel,
  weeklyDelta,
} from "../lib/activity-overview.ts";

const text = (parts) => parts.map((part) => part.text).join(" · ");

test("摘要：需要处理标红，没人在看时末尾补一句", () => {
  const parts = activitySummaryParts({ attention: 2, watching: 0, downloading: 0, active: 5 });
  assert.equal(text(parts), "2 项需要处理 · 5 个任务进行中 · 现在没有人在看");
  assert.equal(parts[0].alert, true);
  assert.equal(
    text(activitySummaryParts({ attention: 0, watching: 1, downloading: 0, active: 0 })),
    "1 台设备在播放",
  );
});

test("摘要：什么都没有时一切正常", () => {
  assert.equal(
    text(activitySummaryParts({ attention: 0, watching: 0, downloading: 0, active: 0 })),
    "一切正常 · 现在没有人在看",
  );
});

test("播放方式按对服务器的负担配色", () => {
  const d = (mode, label) => ({ mode, label, target: null, executor: null, reason: null });
  assert.equal(deliveryColor(d("direct", "直连")), "var(--ok)");
  assert.equal(deliveryColor(d("remux", "重封装")), "var(--info)");
  assert.equal(deliveryColor(d("audio", "音频转码")), "var(--info)");
  assert.equal(deliveryColor(d("transcode", "硬件转码")), "var(--warn)");
  assert.equal(deliveryColor(d("transcode", "软件转码")), "var(--danger)");
  assert.equal(deliveryColor(d("transcode", "远程转码")), "#c084fc");
});

test("转码细节只在转码时出现", () => {
  assert.equal(
    deliveryDetail({ mode: "transcode", label: "硬件转码", target: "1080p · H.264", executor: "NAS · QSV", reason: null }),
    "1080p · H.264 · NAS · QSV",
  );
  assert.equal(
    deliveryDetail({ mode: "direct", label: "直连", target: "x", executor: "y", reason: null }),
    null,
  );
  assert.equal(
    deliveryDetail({ mode: "remux", label: "重封装", target: null, executor: null, reason: null }),
    null,
  );
});

test("设备名：去掉自家品牌前缀、不重复客户端名", () => {
  assert.equal(deviceLabel("MovieClaw Web", "Safari · iPhone"), "Web · Safari · iPhone");
  assert.equal(deviceLabel("Infuse", "Apple TV"), "Infuse · Apple TV");
  // 设备名以客户端名打头时不重复
  assert.equal(deviceLabel("MovieClaw Apple TV", "Apple TV · tvOS 27.0"), "Apple TV · tvOS 27.0");
  assert.equal(deviceLabel("MovieClaw Mac", "Mac · macOS 26.0"), "Mac · macOS 26.0");
  assert.equal(deviceLabel("MovieClaw Android", "Android 16"), "Android 16");
  assert.equal(
    deviceLabel("MovieClaw Android TV", "BRAVIA 4K VH2 · Android 12"),
    "Android TV · BRAVIA 4K VH2 · Android 12",
  );
  // 只是字面前缀相同不算重复
  assert.equal(deviceLabel("MovieClaw Android", "AndroidTV"), "Android · AndroidTV");
  assert.equal(deviceLabel("", ""), "未知设备");
  assert.equal(deviceLabel("Infuse", ""), "Infuse");
});

test("7 天涨跌：上一周期不可比时不显示，为 0 时报新增", () => {
  const stats = (current, previous, available = true) => ({
    previous_available: available,
    current: { watched_ms: current },
    previous: { watched_ms: previous },
  });
  assert.equal(weeklyDelta(stats(100, 100, false)), null);
  assert.deepEqual(weeklyDelta(stats(100, 0)), { text: "比前 7 天新增", tone: "up" });
  assert.deepEqual(weeklyDelta(stats(150, 100)), { text: "比前 7 天 ↑ 50%", tone: "up" });
  assert.deepEqual(weeklyDelta(stats(50, 100)), { text: "比前 7 天 ↓ 50%", tone: "down" });
  assert.deepEqual(weeklyDelta(stats(100, 100)), { text: "与前 7 天持平", tone: "flat" });
});

test("日期换成星期几", () => {
  assert.equal(weekdayLabel("2026-09-27"), "日");
  assert.equal(weekdayLabel("2026-09-26"), "六");
  assert.equal(weekdayLabel("bad"), "bad");
});

function boostTask(siteId, up = 0, uploaded = 0) {
  return {
    id: `${siteId}-${up}-${uploaded}`,
    info_hash: `${siteId}${up}${uploaded}`,
    site_id: siteId,
    site_name: siteId.toUpperCase(),
    upspeed_bytes: up,
    dlspeed_bytes: 0,
    uploaded_bytes: uploaded,
    completed_bytes: 0,
  };
}

function poolSite(siteId, enabled, paused = false) {
  return { site_id: siteId, site_name: siteId, boost_enabled: enabled, boost_paused: paused, scheduled_count: 0 };
}

test("刷流：概况没取到时一律当运行中，不替用户下「已关闭」的结论", () => {
  const summary = boostSummary([boostTask("a", 1024, 2048)], null);
  assert.equal(summary.title, "刷流做种");
  assert.equal(summary.detail, "1 个种子 · ↑ 1.00 KB/s · 已上传 2.00 KB");
});

test("刷流：全关了说清楚种子仍在做种", () => {
  const pool = { sites: [poolSite("a", false)], tasks: [] };
  const summary = boostSummary([boostTask("a"), boostTask("a", 0, 1)], pool);
  assert.equal(summary.mode, "off");
  assert.equal(summary.title, "刷流已关闭");
  assert.equal(summary.detail, "2 个种子仍在做种 · ↑ 0 B/s");
});

test("刷流：部分站点关闭 / 暂停与待删除逐项写出，不再报已上传", () => {
  const pool = {
    sites: [poolSite("a", true), poolSite("b", false), poolSite("c", true, true)],
    tasks: [{ info_hash: "a00", site_id: "a", protected_until: null, cleanup_scheduled: true }],
  };
  const summary = boostSummary([boostTask("a"), boostTask("b"), boostTask("c")], pool);
  assert.equal(summary.title, "刷流做种");
  assert.equal(
    summary.detail,
    "3 个种子 · ↑ 0 B/s · 1 个来自已关闭刷流的站点 · 1 个已暂停 · 1 个等待到期删除",
  );
  const sites = boostSites([boostTask("a"), boostTask("b"), boostTask("c")], pool);
  assert.deepEqual(
    sites.sites.map((site) => [site.id, site.mode]).sort(),
    [["a", "running"], ["b", "off"], ["c", "paused"]],
  );
});

test("刷流种子按上行速度倒序，同速按累计上传", () => {
  const sorted = sortBoostTasks([boostTask("a", 0, 5), boostTask("b", 10, 0), boostTask("c", 0, 9)]);
  assert.deepEqual(sorted.map((task) => task.site_id), ["b", "c", "a"]);
});
