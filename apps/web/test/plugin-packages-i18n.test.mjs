import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import React from "react";
import * as jsx from "react/jsx-runtime";
import { renderToStaticMarkup } from "react-dom/server";
import ts from "typescript";
import { appTranslator } from "../lib/i18n/translate.ts";
import { formatList } from "../lib/i18n/format.ts";
import * as display from "../lib/plugins-display.ts";

function load(locale, values = []) {
  const exports = {};
  let index = 0;
  const node = ({ children }) => React.createElement("div", null, children);
  const dependencies = {
    "react/jsx-runtime": jsx,
    react: { ...React, useEffect: () => {}, useCallback: (fn) => fn, useRef: () => ({ current: null }),
      useState: (initial) => [index < values.length ? values[index++] : initial, () => {}] },
    "next-intl": { useLocale: () => locale, useTranslations: () => appTranslator(locale) },
    "@/components/feedback": { useToast: () => ({}), useConfirm: () => () => {} },
    "@/components/plugin-app-icon": { PluginAppIcon: () => null },
    "@/components/plugin-web-pages-section": { WEB_PAGE_RISK: "settings.plugins.webRisk", PluginWebPagesSection: () => null },
    "@/components/cloud-push-ui": { Banner: node, ErrorBanner: node, StatusPill: ({ label }) => label },
    "@/components/settings-ui": { SettingsList: node, SettingsSection: node, SettingsRow: node,
      SettingsDrawer: ({ title, hint, actions, children }) => React.createElement("div", null, title, hint, children, actions) },
    "@/lib/plugins-display": display,
    "@/lib/i18n/format": { formatList },
    "@/lib/plugin-apps": { appHref: (id, path = "") => `/apps/${id}/${path}` },
    "@/lib/plugin-apps-context": { usePluginApps: () => ({ refresh: () => {} }) },
  };
  const source = readFileSync(new URL("../components/plugin-packages-section.tsx", import.meta.url), "utf8");
  vm.runInNewContext(ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX },
  }).outputText + "\nObject.assign(exports, { LocalRuntimeNote, DependenciesSection });",
  { exports, require: (name) => dependencies[name] ?? {} });
  return exports;
}
const item = { id: "fixture", title: "Fixture", version: "2.0.0", entry: "fixture", runtime: "process",
  description: "", installed_version: null, replaces_builtin: false, operations: [], new_operations: [],
  operation_details: [], paths: [], new_paths: [], callbacks: [], new_callbacks: [], events: [],
  notifications: [], sensitive_events: [], notifies_members: false, requires: {}, dependencies: null, web: null, theme: null };
const render = (component, props) => renderToStaticMarkup(React.createElement(component, props));

test("package review SSR translates runtime, risk sections and controls without mutating a request", () => {
  const value = { ...item, runtime: "inline", web: { entries: [{ path: "", label: "Board" }] },
    theme: { label: "Fixture theme", has_code: true, layout: "cinema", preview: { bg: "#000", accent: "#fff" } },
    operations: ["app.plugins.list"], operation_details: [{ id: "app.plugins.list", summary: "Read plugin catalog", dangerous: true }],
    paths: [{ path: "/mnt/原目录", mode: "rw" }], callbacks: ["notify"],
    notifications: [{ event: "fixture/update", title: "Fixture update", audience_label: "administrators" }],
    sensitive_events: ["playback.started"], notifies_members: true };
  const before = structuredClone(value);
  const html = render(load("en").ReviewDrawer, { item: value, currentWeb: null, busy: false });
  assert.match(html, /Install “Fixture” v2.0.0/);
  assert.match(html, /I trust this plugin and allow it to run in the application process/);
  assert.match(html, /I trust this theme’s code/);
  assert.match(html, /I trust this plugin’s web pages/);
  assert.match(html, /full administrator access/);
  assert.match(html, /Approve and install/);
  assert.match(html, /disabled=""/);
  assert.match(html, /app.plugins.list/);
  assert.match(html, /\/mnt\/原目录/);
  assert.doesNotMatch(html.replaceAll("原目录", "Original"), /[\u3400-\u9fff]/);
  assert.deepEqual(value, before);
});

test("package dependency deltas and local runtimes use complete messages in English", () => {
  const dependencies = { needs_consent: true, total_size: 2048, index_label: "Fixture PyPI", removed: ["old-one", "old-two"],
    packages: [{ name: "native", version: "2.0.0", native: true, size: 1024, available: false, change: "changed", previous_version: "1.0.0" }] };
  const code = load("en");
  const html = render(code.DependenciesSection, { dependencies, upgrade: true }) + render(code.LocalRuntimeNote, {
    locals: [{ source: "local", runtime: "inline" }, { source: "local", runtime: "process" }],
  });
  assert.doesNotMatch(html, /[\u3400-\u9fff]/);
  assert.match(html, /Download and install 1 third-party package/);
  assert.match(html, /Previously 1.0.0/);
  assert.match(html, /No longer needed: old-one and old-two/);
  assert.match(html, /1 plugin runs in the application process/);
});
