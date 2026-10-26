import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import React from "react";
import * as jsx from "react/jsx-runtime";
import { renderToStaticMarkup } from "react-dom/server";
import ts from "typescript";
import { appTranslator } from "../lib/i18n/translate.ts";
import * as market from "../lib/plugin-market.ts";
import * as display from "../lib/plugins-display.ts";
import * as format from "../lib/format.ts";
import * as time from "../lib/time.ts";

function load(locale) {
  const exports = {};
  const node = ({ children }) => React.createElement("div", null, children);
  const dependencies = {
    "react/jsx-runtime": jsx,
    react: { ...React, useEffect: () => {}, useCallback: (fn) => fn, useMemo: (fn) => fn(),
      useState: (initial) => [initial, () => {}] },
    "next-intl": { useLocale: () => locale, useTranslations: () => appTranslator(locale) },
    "next/link": { __esModule: true, default: ({ children }) => React.createElement("a", null, children) },
    "@/components/feedback": { useToast: () => ({}) },
    "@/components/icons": new Proxy({}, { get: () => () => null }),
    "@/components/markdown": { Markdown: ({ text }) => React.createElement("p", null, text) },
    "@/components/cloud-push-ui": { Banner: node, ErrorBanner: node, StatusPill: ({ label }) => label },
    "@/components/settings-ui": { SettingsList: node, SettingsSection: node, SettingsTabs: node },
    "@/lib/plugin-market": market,
    "@/lib/plugins-display": display,
    "@/lib/format": format,
    "@/lib/time": time,
  };
  const source = readFileSync(new URL("../components/plugin-market.tsx", import.meta.url), "utf8");
  vm.runInNewContext(ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX },
  }).outputText + "\nObject.assign(exports, { SourceLine, MarketCard, PermissionsTab, VersionsTab, technicalLine });",
  { exports, require: (name) => dependencies[name] ?? {} });
  return exports;
}
const version = { version: "1.0.0", runtime: "process", released_at: "2026-10-20T00:00:00Z",
  compatible: true, prerelease: false, yanked: null, notes: "", size: 1024, dependencies: [],
  permissions: { operations: ["app.plugins.list"], paths: [], events: [], callbacks: [], network: false } };
const plugin = { id: "fixture", name: "Fixture", author: { name: "Fixture author" }, category: "tools",
  summary: "Fixture summary", versions: [version], recommended: "1.0.0", latest: "1.0.0", installed: null, update: null, downloads: 12800 };
const render = (component, props) => renderToStaticMarkup(React.createElement(component, props));

test("market cards, permissions, version dates and source summaries use English in SSR", () => {
  const code = load("en");
  const html = [
    render(code.SourceLine, { overview: { source: { signed: true, checked_at: new Date().toISOString() }, plugins: [plugin] }, checking: false }),
    render(code.MarketCard, { plugin, downloading: null }),
    render(code.PermissionsTab, { version, detail: null }),
    render(code.VersionsTab, { plugin, downloading: null }),
  ].join("");
  assert.doesNotMatch(html, /[\u3400-\u9fff]/);
  assert.match(html, /12.8K downloads/);
  assert.match(html, /Calls 1 host operation/);
  assert.match(html, /Signature verified/);
  assert.match(html, /No release notes for this version/);
  assert.doesNotMatch(code.technicalLine(plugin, version, "en"), /[\u3400-\u9fff]/);
});
