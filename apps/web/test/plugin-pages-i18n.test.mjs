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

function load(name, locale, values = []) {
  const exports = {};
  let stateIndex = 0;
  const node = ({ children }) => React.createElement("div", null, children);
  const section = ({ title, description, children }) => React.createElement("section", null,
    React.createElement("h2", null, title), description, children);
  const dependencies = {
    "react/jsx-runtime": jsx,
    react: { ...React, useState: (initial) => [stateIndex < values.length ? values[stateIndex++] : initial, () => {}],
      useEffect: () => {}, useCallback: (fn) => fn, useRef: () => ({ current: null }) },
    "next-intl": { useLocale: () => locale, useTranslations: () => appTranslator(locale) },
    "next/link": { __esModule: true, default: ({ children }) => React.createElement("a", null, children) },
    "next/navigation": { useRouter: () => ({}) },
    "@/components/feedback": { useConfirm: () => () => {}, useToast: () => ({}) },
    "@/components/plugin-app-icon": { PluginAppIcon: () => null },
    "@/components/plugin-market": { PluginMarket: () => null },
    "@/components/plugin-packages-section": { PluginPackagesSection: () => null },
    "@/components/cloud-push-ui": { Banner: ({ title, action, children }) => React.createElement("div", null, title, action, children), ErrorBanner: node, StatusPill: ({ label }) => label },
    "@/components/settings-ui": { SettingsSection: section, SettingsList: node,
      SettingsRow: ({ label, description, children }) => React.createElement("div", null, label, description, children),
      SettingsMoreMenu: ({ label, items }) => React.createElement("div", null, label, items.map((item) => item.label).join("|")),
      SettingsTabs: ({ tabs }) => tabs.map((tab) => React.createElement("span", { key: tab.id }, tab.label)) },
    "@/components/icons": { ChevronRightIcon: () => null },
    "@/lib/plugins-display": display,
    "@/lib/i18n/format": { formatList },
    "@/lib/cloud-push-display": { TONE_COLOR: {} },
    "@/lib/use-tab-param": { useTabParam: () => ["installed", () => {}] },
    "@/lib/plugin-apps-context": { usePluginApps: () => ({ refresh: () => {} }) },
    "@/lib/plugin-apps": { appHref: (id) => `/apps/${id}` },
  };
  const source = readFileSync(new URL(`../components/${name}.tsx`, import.meta.url), "utf8");
  vm.runInNewContext(ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX },
  }).outputText + (name === "plugins-section" ? "\nexports.SystemProblems = SystemProblems; exports.OfficialSection = OfficialSection; exports.SystemModules = SystemModules;" : ""),
  { exports, require: (name) => dependencies[name] ?? {} });
  return exports;
}
const render = (component, props) => renderToStaticMarkup(React.createElement(component, props));
const plugin = { id: "fixture", title: "Fixture", state: "failed", error: null, source: "builtin", stats: {}, apply_ms: 1200, blocked_by: [], tier: "system" };

test("plugin overview SSR translates counts, restoration and safe-mode copy with an explicit language", () => {
  const code = load("plugins-section", "en");
  const html = [
    render(code.SystemProblems, { plugins: [plugin] }),
    render(code.OfficialSection, { plugins: [], removed: [{ id: "restore", title: "Fixture", description: "" }] }),
    render(code.SystemModules, { plugins: [plugin], groups: [], open: true }),
    render(load("plugins-section", "en", [0, { plugins: [], safe_mode: { active: true, reason: "Fixture reason", skipped: ["fixture-a", "fixture-b"], forced: "env" } }, false, null, false]).PluginsPage),
  ].join("");
  assert.doesNotMatch(html, /[\u3400-\u9fff]/);
  assert.match(html, /1 system module is not running normally/);
  assert.match(html, /Restore/);
  assert.match(html, /Slowest to start: Fixture 1.2 s/);
  assert.match(html, /Skipped plugins: fixture-a and fixture-b/);
  assert.match(html, /MOVIECLAW_SAFE_MODE/);
});

test("plugin web consent menus are localized without changing grant state or plugin names", () => {
  const page = { id: "fixture", name: "作者原名", source: "package", approved: true, nav: false, members: false, entries: [] };
  const original = structuredClone(page);
  const html = render(load("plugin-web-pages-section", "en", [[page], false]).PluginWebPagesSection, { reloadKey: 0 });
  assert.match(html, /Plugin web pages/);
  assert.match(html, /作者原名/);
  assert.match(html, /Administrators only/);
  assert.match(html, /Add to sidebar/);
  assert.match(html, /Visible to members too/);
  assert.match(html, /Revoke approval/);
  assert.deepEqual(page, original);
  const pending = render(load("plugin-web-pages-section", "en", [[{ ...page, approved: false }], false]).PluginWebPagesSection, { reloadKey: 0 });
  assert.match(pending, /Awaiting approval/);
  assert.match(pending, /Approve/);
  assert.doesNotMatch(pending, /Revoke approval/);
});

test("localized group headings cannot merge distinct original group IDs", () => {
  const plugins = [{ ...plugin, id: "first", state: "active", group: "基础" },
    { ...plugin, id: "second", state: "active", group: "Other" }];
  const code = load("plugins-section", "en");
  const html = render(code.SystemModules, { plugins, groups: ["基础", "Other"], labels: { "基础": "Other" }, open: true });
  assert.equal((html.match(/<h2>Other<\/h2>/g) ?? []).length, 2);
  assert.match(html, /first/);
  assert.match(html, /second/);
  assert.deepEqual(display.groupBuiltins(plugins, ["基础", "Other"], "en").map((row) => row.label), ["基础", "Other"]);
});
