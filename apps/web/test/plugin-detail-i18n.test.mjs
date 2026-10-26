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
import * as format from "../lib/format.ts";
import * as time from "../lib/time.ts";

function load(locale, values = []) {
  const exports = {};
  let index = 0;
  const node = ({ children }) => React.createElement("div", null, children);
  const section = ({ title, description, children }) => React.createElement("section", null, React.createElement("h2", null, title), description, children);
  const dependencies = {
    "react/jsx-runtime": jsx,
    react: { ...React, useEffect: () => {}, useCallback: (fn) => fn,
      useState: (initial) => [index < values.length ? values[index++] : initial, () => {}] },
    "next-intl": { useLocale: () => locale, useTranslations: () => appTranslator(locale) },
    "next/link": { __esModule: true, default: ({ children }) => React.createElement("a", null, children) },
    "next/navigation": { useRouter: () => ({}) },
    "@/components/feedback": { useToast: () => ({}), useConfirm: () => () => {} },
    "@/components/icons": new Proxy({}, { get: () => () => null }),
    "@/components/copy-button": { CopyButton: () => null },
    "@/components/schema-form": { unsupportedField: () => null, SchemaForm: () => null },
    "@/components/cloud-push-ui": { Banner: section, ErrorBanner: node, StatusPill: ({ label }) => label },
    "@/components/settings-ui": { SettingsList: node, SettingsSection: section,
      SettingsCard: ({ title, hint, action, children }) => React.createElement("div", null, title, hint, action, children),
      SettingsRow: ({ label, description, children }) => React.createElement("div", null, label, description, children),
      SettingsMoreMenu: () => null },
    "@/lib/plugins-display": display,
    "@/lib/i18n/format": { formatList },
    "@/lib/format": format,
    "@/lib/time": time,
  };
  const source = readFileSync(new URL("../components/plugin-detail.tsx", import.meta.url), "utf8");
  vm.runInNewContext(ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX },
  }).outputText + "\nObject.assign(exports, { Permissions, Diagnostics, PluginSettingsSection });",
  { exports, require: (name) => dependencies[name] ?? {} });
  return exports;
}
const detail = {
  plugin: { id: "fixture", title: "Fixture", state: "active", source: "package", runtime: "process",
    blocked_by: [], apply_ms: 1234, inject: [], provides: [], permissions: [], switchable: true, removable: false,
    stats: { handler_avg_ms: 10, failures: 1, timeouts: 2, breaker: "closed" } },
  kind: "package", version: "1.0.0", description: "Fixture description", network: true,
  package: { installed_at: 1792400000, operations: [], paths: [{ path: "/mnt/Original", mode: "rw" }], callbacks: [], bad_versions: [] },
  adds: [], consumers: [], callbacks: [], dead_letters: [], data_rows: 1234, disk_bytes: 2048, data_path: "/data/fixture", children: [], source: null,
};
const render = (component, props) => renderToStaticMarkup(React.createElement(component, props));

test("plugin detail SSR localizes dates, storage plurals, permissions and diagnostic counts", () => {
  const html = render(load("en", [detail, null, false, null]).PluginDetailView, { id: "fixture" });
  assert.doesNotMatch(html, /[\u3400-\u9fff]/);
  assert.match(html, /1,234<\/span> stored records/);
  assert.match(html, /private folder uses/);
  assert.match(html, /Access to \/mnt\/Original \(Read and write\)/);
  assert.match(html, /2 timeouts/);
  assert.match(html, /Circuit closed/);
  assert.match(html, /Disable/);
});

test("authors' names, including a Chinese process-like suffix, are retained in both languages", () => {
  const title = "作者原名（独立进程）";
  for (const locale of ["en", "zh-Hans", "en"]) {
    const value = { ...detail, plugin: { ...detail.plugin, title } };
    const html = render(load(locale, [value, null, false, null]).PluginDetailView, { id: "fixture" });
    assert.ok(html.includes(title));
    assert.equal(value.plugin.title, title);
  }
});

test("read-only and editable plugin settings render their own copy in English", () => {
  const readOnly = render(load("en", [{ editable: false, reason: "Fixture reason" }, {}, false, null]).PluginSettingsSection, { id: "fixture" });
  assert.match(readOnly, /This plugin’s settings cannot be edited here: Fixture reason/);
  const editable = render(load("en", [{ editable: true, schema: { properties: {} } }, {}, false, null]).PluginSettingsSection, { id: "fixture" });
  assert.match(editable, /Saving restarts the plugin with the new settings/);
  assert.match(editable, /Save/);
  assert.doesNotMatch(readOnly + editable, /[\u3400-\u9fff]/);
});
