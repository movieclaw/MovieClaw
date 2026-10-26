import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import React from "react";
import * as jsx from "react/jsx-runtime";
import { renderToStaticMarkup } from "react-dom/server";
import ts from "typescript";
import { appTranslator } from "../lib/i18n/translate.ts";
import * as duplicates from "../lib/library-duplicates.ts";
import { formatBytes } from "../lib/format.ts";

function load(locale, values = []) {
  const exports = {};
  let index = 0;
  const dependencies = {
    "react/jsx-runtime": jsx,
    react: { ...React, useState: (initial) => [index < values.length ? values[index++] : initial, () => {}], useEffect: () => {}, useCallback: (fn) => fn, useMemo: (fn) => fn(), useRef: (value) => ({ current: value }) },
    "next-intl": { useLocale: () => locale, useTranslations: () => appTranslator(locale) },
    "next/link": { __esModule: true, default: ({ children, ...props }) => React.createElement("a", props, children) },
    "@/components/content-empty-state": { ContentEmptyState: ({ title, description, action }) => React.createElement("div", null, title, description, action) },
    "@/components/feedback": { useToast: () => ({}), useConfirm: () => () => {} },
    "@/components/icons": new Proxy({}, { get: () => () => null }),
    "@/components/poster-image": { PosterImage: () => null },
    "@/components/tooltip": { Tooltip: ({ content, children }) => React.createElement("div", null, content, children) },
    "@/lib/api/libraries": {}, "@/lib/format": { formatBytes }, "@/lib/library-duplicates": duplicates,
    "@/lib/image-proxy": { imageUrl: (url) => url },
    "@/lib/use-visible-polling": { useVisiblePolling: () => {} },
  };
  const source = readFileSync(new URL("../components/library-duplicate-files.tsx", import.meta.url), "utf8");
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX } }).outputText
    + "\nObject.assign(exports, { ScanBar, TierSummary, SeasonBlock, FileRow });",
    { exports, require: (key) => dependencies[key] ?? {} });
  return exports;
}
const render = (component, props) => renderToStaticMarkup(React.createElement(component, props));
const file = { id: 1, file_name: "Fixture.S01E01.mkv", file_path: "/fixture/Fixture.S01E01.mkv", size_bytes: 1024, resolution: "1080p", media_source: "WEB-DL", hdr: null, video_codec: "h264", audio_label: "AAC 2.0", bit_rate: 1000000, quality_label: "1080p WEB-DL", origin: { kind: "scan", label: "Author origin", detail: "Author detail" }, version_key: "1080p WEB-DL|raw-origin", suggested: true, suggest_reason: "Higher quality tier", kept_at: null };
const other = { ...file, id: 2, file_name: "Fixture.S01E01.other.mkv", quality_label: "720p HDTV", version_key: "720p HDTV|raw-origin", suggested: false, suggest_reason: null };
const version = { key: file.version_key, quality_label: file.quality_label, origin_label: file.origin.label, episodes: [1,2], bytes: 2048, suggested: true };
const season = { season_number: 1, bucket: "versions", uniform: true, versions: [version, { ...version, key: other.version_key, quality_label: other.quality_label, suggested: false }], units: [{ season_number: 1, episode_number: 1, bucket: "versions", files: [file,other] }] };
const item = { library: { id: 1, name: "Author library" }, media_item: { id: 10, title: "Fixture show", kind: "tv", year: 2024, poster_url: null }, seasons: [season] };
const group = (key) => ({ key, label: key, hint: "Fixture explanation", units: 1, files: 1, bytes: 1024 });
const scan = { status: "succeeded", job_id: "fixture", message: null, percent: 100, scanned_at: "2030-01-01T00:00:00Z", upgrading_units: 1, keep_old_items: 1 };
const data = { scan, tiers: ["safe","suggested","review"].map(group), review_groups: [group("unknown")], total_units: 3, total_files: 3, total_bytes: 3072, total_items: 1, items: [item] };
const libraries = [{ id: 1, name: "Author library" }];
const state = (view, focus = { tier: null, reviewKind: null }, expanded = new Set(), failed = false) => [{ q: "", libraryId: null, itemId: null }, focus, "", 0, view, failed, expanded, false];

test("duplicate summary, details and scan states render English controls", () => {
  for (const focus of [{ tier: null, reviewKind: null }, { tier: "suggested", reviewKind: null }, { tier: "review", reviewKind: "unknown" }]) {
    for (const expanded of [new Set(), new Set(["10:1:versions"])]) {
      const html = render(load("en", state(data, focus, expanded)).LibraryDuplicateFiles, { libraries });
      assert.doesNotMatch(html, /[\u3400-\u9fff]/);
      assert.match(html, /Search duplicate files/);
      assert.match(html, /Scan again/);
      if (focus.tier) assert.match(html, /Keep/);
      else assert.match(html, /Work from top to bottom/);
    }
  }
  assert.match(render(load("en", state({ ...data, scan: { ...scan, status: null } })).LibraryDuplicateFiles, { libraries }), /No duplicate scan yet/);
  assert.match(render(load("en", state({ ...data, total_units: 0 })).LibraryDuplicateFiles, { libraries }), /No duplicate files/);
  assert.equal(duplicates.scanNote({ ...scan, status: "failed", message: "Author reason" }, new Date(scan.scanned_at), "en"), "The last scan failed: Author reason; results from just now are shown below");
});

test("raw comparison keys survive equal display labels and determine differences", () => {
  const a = { ...file, quality_key: "1080p WEB-DL", origin_key: "source-A", origin: { ...file.origin, label: "Same label" } };
  const b = { ...a, id: 2, origin_key: "source-B" };
  assert.equal(duplicates.sharedFacts([a,b], "en").origin, null);
  assert.equal(duplicates.sharedVersionOrigin([{ ...version, origin_key: "a", origin_label: "Same" }, { ...version, key: "b", origin_key: "b", origin_label: "Same" }]), null);
  const unknown = { ...file, quality_label: "Unknown specifications", quality_key: "未知规格" };
  assert.deepEqual(duplicates.specSegments(unknown, { ...file, quality_key: "1080p WEB-DL" }, "en").slice(0,1), [{ text: "Unknown specifications", diff: true }]);
  assert.deepEqual(duplicates.versionSpecSegments({ ...version, quality_key: "未知规格", quality_label: "Unknown specifications" }, { ...version, quality_key: "1080p WEB-DL" }, "en"), [{ text: "Unknown specifications", diff: true }]);
  assert.equal(duplicates.keepVersionFacts({ ...season, versions: [{ ...version, quality_label: "Same" }] }, { ...version, quality_label: "Same" }).gone[0].id, other.id);
});
