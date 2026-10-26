import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import React from "react";
import * as jsx from "react/jsx-runtime";
import { renderToStaticMarkup } from "react-dom/server";
import ts from "typescript";
import { appTranslator } from "../lib/i18n/translate.ts";
import * as recycle from "../lib/library-recycle.ts";
import * as time from "../lib/time.ts";
import { formatBytes } from "../lib/format.ts";

function load(locale, values = [], mobile = false) {
  const exports = {};
  let index = 0;
  const node = ({ children }) => React.createElement("div", null, children);
  const dependencies = {
    "react/jsx-runtime": jsx,
    react: { ...React, useState: (initial) => [index < values.length ? values[index++] : initial, () => {}], useEffect: () => {}, useCallback: (fn) => fn, useMemo: (fn) => fn(), useRef: (value) => ({ current: value }) },
    "next-intl": { useLocale: () => locale, useTranslations: () => appTranslator(locale) },
    "next/link": { __esModule: true, default: ({ children, ...props }) => React.createElement("a", props, children) },
    "@/lib/i18n/translate": { appTranslator }, "@/lib/i18n/negotiate": { requestLocale: () => locale },
    "@/components/brand-loader": { BrandLoader: () => null },
    "@/components/content-empty-state": { ContentEmptyState: ({ title, description }) => React.createElement("div", null, title, description) },
    "@/components/feedback": { useToast: () => ({}), useConfirm: () => () => {} },
    "@/components/icons": new Proxy({}, { get: () => () => null }),
    "@/components/poster-image": { PosterImage: () => null },
    "@/components/tooltip": { Tooltip: ({ content, children }) => React.createElement("div", null, content, children) },
    "@/lib/api/libraries": {}, "@/lib/format": { formatBytes }, "@/lib/library-recycle": recycle,
    "@/lib/time": time, "@/lib/image-proxy": { imageUrl: (url) => url },
    "@/lib/use-visible-polling": { useVisiblePolling: () => {} }, "@/lib/use-media-query": { useIsMobile: () => mobile },
  };
  const source = readFileSync(new URL("../components/library-recycle-bin.tsx", import.meta.url), "utf8");
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX } }).outputText
    + "\nObject.assign(exports, { ItemRow, ItemCard, FileRow, FileName, OpsCell, QualityText, DueText });",
    { exports, require: (key) => dependencies[key] ?? {} });
  return exports;
}
const render = (component, props) => renderToStaticMarkup(React.createElement(component, props));
const file = { id: 1, file_name: "Fixture.S01E01.mkv", file_path: "/fixture/.movieclaw-trash/Fixture.S01E01.mkv", trash_original_path: "/fixture/Fixture.S01E01.mkv", kept_in_place: false, size_bytes: 1024, resolution: "1080p", media_source: "WEB-DL", hdr: null, video_codec: "h264", bit_depth: 8, audio_label: "AAC 2.0", release_group: "Fixture", season_number: 1, episode_number: 1, episode_title: "Fixture episode", trashed_at: "2026-01-01T00:00:00Z", purge_after: "2030-01-01T00:00:00Z", reason: "duplicate_cleanup", note: null, last_error: null };
const item = { key: "fixture", library: { id: 1, name: "Fixture library" }, media_item: { id: 10, title: "Fixture title", year: 2024, kind: "tv", poster_url: null }, seasons: [1], file_count: 2, total_bytes: 2048, earliest_purge_after: file.purge_after, latest_purge_after: file.purge_after, reasons: { duplicate_cleanup: 2 }, note: null, trigger_label: "Fixture author", latest_trashed_at: file.trashed_at, quality: { tiers: { "1080p WEB-DL": 2 }, tier_labels: { "1080p WEB-DL": "1080p WEB-DL" }, hdr: [], video_codecs: ["h264"], audio_labels: ["AAC 2.0"], release_groups: ["Fixture"] }, files: [file, { ...file, id: 2, file_name: "Fixture.S01E02.mkv", episode_number: 2 }] };
const data = { total_files: 2, total_items: 1, total_bytes: 2048, due_within_24h: 1, kept_in_place: 1, by_library: [{ library_id: 1, name: "Fixture library", count: 2 }], by_reason: [{ reason: "duplicate_cleanup", count: 2 }], items: [item] };
const state = (view, selected = new Set(), failed = false) => [{ q: "", libraryId: null, reason: null }, "", 0, view, failed, new Set(["fixture"]), selected, false];

test("Trash renders English controls, selection counts, paths and mobile actions", () => {
  for (const mobile of [false, true]) {
    const html = render(load("en", state(data, new Set([1])), mobile).LibraryRecycleBin);
    assert.doesNotMatch(html, /[\u3400-\u9fff]/);
    assert.match(html, /Selected <b class="font-semibold">1<\/b> file/);
    assert.match(html, /Delete all now · 2/);
    assert.match(html, /Original path \(restore destination\)/);
    assert.match(html, /Duplicate cleanup/);
  }
  const empty = { ...data, total_files: 0, total_items: 0, items: [] };
  assert.match(render(load("en", state(empty)).LibraryRecycleBin), /Recycle bin is empty/);
});

test("compact countdowns come from time facts and keep threshold tones", () => {
  const now = Date.parse("2030-01-01T00:00:00Z"), iso = (hours) => new Date(now + hours * 3600000).toISOString();
  assert.deepEqual(recycle.countdown(iso(76), now, "en", true), { text: "3d 4h", tone: "normal" });
  assert.deepEqual(recycle.countdown(iso(24), now, "en", true), { text: "1d", tone: "soon" });
  assert.deepEqual(recycle.countdown(iso(6), now, "zh-Hans", true), { text: "6 小时", tone: "soon" });
  assert.equal(recycle.countdown(iso(6), now, "zh-Hans").text, "6 小时后");
  assert.equal(recycle.countdown(iso(6), now, "en").text, "In 6 hours");
  assert.equal(recycle.countdown(iso(1), now, "en").text, "In 1 hour");
});

test("quality labels can coincide without replacing raw tier identities or author notes", () => {
  const source = { ...item, note: "作者原文", quality: { ...item.quality, tiers: { a: 1, b: 2 }, tier_labels: { a: "Same", b: "Same" } } };
  const before = structuredClone(source);
  const line = recycle.itemQualityLine(source, "en");
  assert.deepEqual(line.tiers, [{ key: "b", label: "Same", count: 2 }, { key: "a", label: "Same", count: 1 }]);
  assert.equal(recycle.itemReasonText(source, "en"), "作者原文");
  assert.equal(recycle.reasonLabel("author-custom", "en"), "author-custom");
  assert.deepEqual(source, before);
});
