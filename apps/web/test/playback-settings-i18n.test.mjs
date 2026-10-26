import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import React from "react";
import * as jsx from "react/jsx-runtime";
import { renderToStaticMarkup } from "react-dom/server";
import ts from "typescript";
import { appTranslator } from "../lib/i18n/translate.ts";
import { relativeTime } from "../lib/devices-display.ts";
import { formatBytes } from "../lib/format.ts";

const noop = () => {};
const config = { enabled: true, ready: true, base_url: "http://author-host", base_url_override: "", base_url_source: "worker_connection", issues: [] };
const worker = { worker_id: "Author worker", online: true, draining: false, device_id: 1, server_config: true, platform: "macOS", arch: "arm64", hardware: { chip: "M4", cpu_cores: 10, memory_bytes: 17179869184 }, ffmpeg_version: "8.0", backends: ["videotoolbox"], active_jobs: 1, max_jobs: 2, last_seen_seconds: 3, load: { cpu: 0.3, memory_pressure: 1, thermal_state: 2 } };
const status = { workers: [worker], device_limits: { "ld-1": 2 } };
const remoteState = (c = config, state = status, extras = []) => [c, c?.enabled, c?.base_url_override, false, null, false, null, false, null, state, null, extras];
function load(locale, file, values = []) {
  let index = 0;
  const node = ({ title, label, description, error, footnote, action, children }) => React.createElement("section", null, title, label, description, error, action, children, footnote);
  const imports = {
    "react/jsx-runtime": jsx,
    "react": { ...React, useState: (initial) => [index < values.length ? values[index++] : initial, noop], useEffect: noop, useMemo: (f) => f(), useCallback: (f) => f, useRef: (value) => ({ current: value }) },
    "next-intl": { useLocale: () => locale, useTranslations: () => appTranslator(locale) },
    "next/navigation": { useRouter: () => ({ push: noop }) },
    "@/components/cloud-push-ui": { Banner: node, ErrorBanner: node, Toggle: ({ label }) => React.createElement("span", null, label) },
    "@/components/settings-ui": { SettingsSection: node, SettingsEmpty: node, SettingsList: node, SettingsRow: node, SETTINGS_BUTTON_CLASS: "button", SETTINGS_INPUT_CLASS: "input" },
    "@/components/feedback": { useToast: () => ({ success: noop }), useConfirm: () => noop },
    "@/components/icons": { SparklesIcon: () => null, XIcon: () => null },
    "@/components/tip-card": { TipCard: ({ tip }) => React.createElement("div", null, tip.title, tip.message, tip.actions.map((action) => React.createElement("span", { key: action.id }, action.label))) },
    "@/lib/tips/engine": { defineTip: (tip) => tip },
    "@/lib/tips/use-tip": { useTip: () => ({ visible: true, invalidate: noop }) },
    "@/lib/permissions": { usePermissions: () => ({ isAdmin: true }) },
    "@/lib/devices-display": { relativeTime }, "@/lib/format": { formatBytes },
    "@/lib/i18n/translate": { appTranslator },
    "@/lib/api/playback": {}, "@/lib/api/devices": {}, "@/lib/api/transcode-worker": {}, "@/lib/api/drives": {},
  };
  const source = readFileSync(new URL(`../components/${file}.tsx`, import.meta.url), "utf8");
  const exports = {};
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.ReactJSX } }).outputText, { exports, require: (key) => imports[key] ?? {} });
  return exports;
}
const render = (component, props = {}) => renderToStaticMarkup(React.createElement(component, props));

test("playback settings render English from facts while preserving worker identities", () => {
  const html = render(load("en", "remote-transcode-section", remoteState()).RemoteTranscodeSection, { onOpenDevices: noop });
  assert.doesNotMatch(html, /[\u3400-\u9fff]/);
  assert.match(html, /Ready · 1 worker online/);
  assert.match(html, /Author worker/);
  assert.match(html, /Memory pressure: elevated · Cooling down/);
  assert.match(html, /Maximum concurrent jobs for Author worker/);
  for (const [file, component] of [["trickplay-toggle-section", "TrickplayToggleRow"], ["transcode-cache-toggle-section", "TranscodeCacheToggleRow"], ["reel-clips-toggle-section", "ReelClipsToggleRow"]]) {
    for (const on of [false, true]) {
      const values = file === "reel-clips-toggle-section" ? [on, { ready: 1, total: 3, state: "paused" }, false, null] : [on, false, null];
      const body = render(load("en", file, values)[component]);
      assert.doesNotMatch(body, /[\u3400-\u9fff]/);
    }
  }
  const radios = render(load("en", "cloud-stream-mode-section", [true, "relay", false, null]).CloudStreamModeSection);
  assert.doesNotMatch(radios, /[\u3400-\u9fff]/);
  assert.match(radios, /Always relay through home/);
  assert.equal((radios.match(/aria-checked="true"/g) ?? []).length, 1);
  const tip = render(load("en", "reel-clips-tip").ReelClipsTip);
  assert.doesNotMatch(tip, /[\u3400-\u9fff]/);
  assert.match(tip, /Prepare clips for smoother trailers/);
});

test("clip progress handles counts, paused processing and source facts in both locales", () => {
  const en = load("en", "reel-clips-toggle-section").progressText;
  const cases = [null, { ready: 1, total: 1, state: "done" }, { ready: 2, total: 3, state: "done" }, { ready: 1, total: 3, state: "paused" }, { ready: 0, total: 2, state: "running" }];
  for (const progress of cases) {
    const before = JSON.stringify(progress);
    assert.doesNotMatch(en(progress, "en"), /[\u3400-\u9fff]/);
    assert.equal(JSON.stringify(progress), before);
  }
  assert.equal(en(cases[1], "en"), "1 title is ready. New titles are processed automatically.");
  assert.equal(en(cases[2], "zh-Hans"), "已切好 2 部，其余 1 部无法预切（网盘文件或片子太短）；新入库的会自动补切");
  assert.match(en(cases[3], "en"), /Paused while someone is watching/);
});
