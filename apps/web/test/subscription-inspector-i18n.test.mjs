import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import ts from "typescript";
import { appTranslator } from "../lib/i18n/translate.ts";
import { formatList, formatNumber } from "../lib/i18n/format.ts";
import { formatBytes, formatDuration } from "../lib/format.ts";
import { formatDateTime, formatRelativeTime } from "../lib/time.ts";
import { shouldShowResourceTiming } from "../lib/resource-timing.ts";
import { smartWantedPresentation } from "../lib/subscription-ui.ts";

function load(file, names) {
  const source = readFileSync(new URL(`../components/${file}.tsx`, import.meta.url), "utf8");
  const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX } }).outputText;
  const exports = {};
  vm.runInNewContext(compiled + names.map((name) => `\nexports.${name} = ${name};`).join(""), {
    exports, Date, require: (name) => {
      if (name === "@/lib/i18n/translate") return { appTranslator };
      if (name === "@/lib/i18n/format") return { formatList, formatNumber };
      if (name === "@/lib/format") return { formatBytes, formatDuration };
      if (name === "@/lib/time") return { formatDateTime, formatRelativeTime };
      if (name === "@/lib/resource-timing") return { shouldShowResourceTiming };
      if (name === "@/lib/subscription-ui") return { smartWantedPresentation };
      if (name === "react/jsx-runtime") return { jsx: (type, props) => ({ type, ...props }), jsxs: (type, props) => ({ type, ...props }) };
      return {};
    },
  });
  return exports;
}
const { wantedPresentation, milestonesOf, downloadNote, resourceTimingNote, MilestoneChain } = load("subscription-inspector-view", ["wantedPresentation", "milestonesOf", "downloadNote", "resourceTimingNote", "MilestoneChain"]);
const { hintReason } = load("subscription-episode-floor", ["hintReason"]);
const { seriesLabel } = load("smart-subscription-status", ["seriesLabel"]);
const past = "2020-01-02T03:04:00Z", future = "2099-01-02T03:04:00Z";
const row = (values = {}) => ({ status: "wanted", next_search_at: future, air_date: "2020-01-01", search_attempts: 0, ...values });

test("tracking states keep their meaning, colors and raw input across reader languages", () => {
  for (const [w, chinese, english, short] of [
    [row({ status: "imported", imported_at: past }), "已入库", "Imported"],
    [row({ status: "downloaded", downloaded_at: past }), "已下载", "Downloaded"],
    [row({ status: "grabbed", grabbed_at: past }), "已提交下载", "Submitted for download", "Submitted"],
    [row({ next_search_at: null }), "未定档", "No date set"],
    [row({ air_date: "2099-01-01" }), "待播出", "Awaiting airing"],
    [row({ next_search_at: past }), "排队搜索", "Queued for search", "Queued"],
    [row(), "待搜索", "Scheduled search"],
    [row({ last_search_at: past }), "冷却中", "Cooldown"],
    [row({ release_forecast: { version: 1, target_air_date: "2020-01-01", confidence: "stable", sites: [{ site_id: "First" }, { site_id: "Second" }], window_start: future, window_end: future } }), "预测窗口", "Forecast window", "Forecasting"],
    [row({ status: "imported", upgrade: { active: true, current_label: "1080p WEB-DL", target_label: "1080p Blu-ray" } }), "洗版中", "Upgrading"],
  ]) {
    const original = JSON.stringify(w);
    let color;
    for (const locale of ["en", "zh-Hans", "en"]) {
      const p = wantedPresentation(w, locale);
      assert.equal(p.label, locale === "en" ? english : chinese);
      if (short && locale === "en") assert.equal(p.shortLabel, short);
      if (locale === "en") assert.doesNotMatch(p.note, /[\u3400-\u9fff]/u);
      if (color) assert.equal(p.color, color);
      color = p.color;
    }
    assert.equal(JSON.stringify(w), original);
  }
});

test("milestones use stable stage IDs and render smart selection at the English search stage", () => {
  const w = row({ search_attempts: 2 });
  const en = milestonesOf(w, false, undefined, undefined, "en");
  const zh = milestonesOf(w, false, undefined, undefined, "zh-Hans");
  assert.equal(en.map((m) => m.id).join(), "release,search,dispatch,download,import");
  assert.equal(en.map((m) => m.state).join(), zh.map((m) => m.state).join());
  assert.equal(en[1].lab, "Search");
  assert.equal(zh[1].lab, "搜索");
  assert.equal(en[1].time, "2 searches");
  assert.equal(zh[1].time, "已搜 2 次");
  const tree = MilestoneChain({ chain: en, color: "red", selection: "SMART_SELECTION_MARKER" });
  assert.match(JSON.stringify(tree), /SMART_SELECTION_MARKER/);
  assert.doesNotMatch(JSON.stringify(en), /[\u3400-\u9fff]/u);
  const failed = milestonesOf(row({ status: "downloaded", grabbed_at: past, downloaded_at: past }), false, undefined, { type: "import_failed", message: "Mapping is missing" }, "en");
  assert.equal(failed[4].state, "fail");
  assert.equal(failed[4].why, "Mapping is missing");
  const complete = milestonesOf(row({ status: "imported", imported_at: past, grabbed_at: past }), true, undefined, undefined, "en");
  assert.ok(complete.every((m) => m.state === "done"));
});

test("download progress translates states and preserves administrator versus member guidance", () => {
  const base = { progress: 0.125, dlspeed_bytes: 2048, eta_seconds: 120, size_bytes: 1024, downloader_name: "qBittorrent" };
  const zh = (state, extra = {}) => downloadNote({ ...base, state, ...extra }, "zh-Hans");
  const en = (state, extra = {}) => downloadNote({ ...base, state, ...extra }, "en");
  assert.equal(zh("downloading"), "12% · 2.00 KB/s · 剩余约 2 分钟");
  assert.equal(en("downloading"), "12% · 2.00 KB/s · About 2 minutes remaining");
  assert.equal(zh("paused"), "12% · 已在下载器中暂停");
  assert.equal(en("paused"), "12% · Paused in downloader");
  assert.match(en("error", { downloader_name: null }), /administrator must fix/);
  assert.match(en("error", { error_message: "Raw downloader error" }), /Raw downloader error/);
  assert.equal(zh("error", { error_message: "Raw downloader error" }), "12% · Raw downloader error；换源判定已暂停，请在下载器中处理");
  for (const state of ["missing", "completed", "stalled", "unknown", "error"]) assert.doesNotMatch(en(state), /[\u3400-\u9fff]/u);
});

test("resource timing preserves measurements and Chinese punctuation while translating whole sentences", () => {
  const timing = { site_id: "Example", dry_run: true, publish_to_seen_seconds: 30, seen_to_submit_seconds: 120, publish_to_submit_seconds: 150 };
  const before = JSON.stringify(timing);
  assert.equal(resourceTimingNote(timing, true, "zh-Hans"), "上次 · 模拟 · Example：资源发布后 不到 1 分钟进入索引，2 分钟后提交下载器（总耗时 3 分钟）");
  assert.equal(resourceTimingNote(timing, true, "en"), "Previous · Simulation · Example: indexed under 1 minute after release, then submitted to downloader 2 minutes later (3 minutes total)");
  assert.equal(resourceTimingNote({ ...timing, publish_to_seen_seconds: null }, false, "zh-Hans"), "模拟 · Example：资源发布后 3 分钟提交下载器");
  assert.equal(resourceTimingNote({ ...timing, publish_to_submit_seconds: 700000 }, false, "en"), null);
  assert.equal(JSON.stringify(timing), before);
});

test("episode evidence and release series labels translate with raw group identity retained", () => {
  const hint = { tmdb_count: 3, site_episode: 5, douban_count: 4 };
  assert.equal(hintReason(hint, "zh-Hans"), "站点上已出现第 5 集的资源，TMDB 只录了 3 集");
  assert.equal(hintReason(hint, "en"), "Episode 5 is available on a site, while TMDB lists only 3 episodes");
  assert.equal(hintReason({ ...hint, site_episode: 1 }, "en"), "Douban lists 4 episodes, while TMDB lists only 3 episodes");
  assert.equal(seriesLabel("我的发布组|1080p|4", "en"), "我的发布组 · 1080p · Blu-ray");
  assert.equal(seriesLabel("我的发布组|1080p|4", "zh-Hans"), "我的发布组 · 1080p · 蓝光");
  assert.equal(appTranslator("en")("subscription.progress.count", { imported: 1, total: 1, kind: "tv" }), "1 / 1 episode");
});
