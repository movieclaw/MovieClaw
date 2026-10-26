import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import React from "react";
import * as jsx from "react/jsx-runtime";
import { renderToStaticMarkup } from "react-dom/server";
import ts from "typescript";
import { appTranslator } from "../lib/i18n/translate.ts";
import * as display from "../lib/cloud-push-display.ts";

function load(locale, values = []) {
  const exports = {};
  let index = 0;
  const node = ({ children }) => React.createElement("div", null, children);
  const section = ({ title, description, footnote, children }) => React.createElement("section", null,
    React.createElement("h2", null, title), description, footnote, children);
  const dependencies = {
    "react/jsx-runtime": jsx,
    react: { ...React, useState: (initial) => [index < values.length ? values[index++] : initial, () => {}], useEffect: () => {}, useCallback: (fn) => fn, useRef: (value) => ({ current: value }) },
    "next-intl": { useLocale: () => locale, useTranslations: () => appTranslator(locale) },
    "next/link": { __esModule: true, default: ({ children, ...props }) => React.createElement("a", props, children) },
    "@/components/cloud-push-ui": { Banner: ({ title, action, children }) => React.createElement("div", null, title, action, children), ErrorBanner: node, Toggle: ({ label }) => label },
    "@/components/feedback": { useToast: () => ({}) },
    "@/components/feature-off-notice": { FeatureOffNotice: node },
    "@/components/settings-ui": { SettingsSection: section, SettingsList: node,
      SettingsRow: ({ label, description, children }) => React.createElement("div", null, label, description, children) },
    "@/lib/api/push": {}, "@/lib/cloud-push-display": display,
    "@/lib/row-anchor": { ROW_ANCHOR_CLASS: "", useRowAnchor: () => {} },
  };
  const source = readFileSync(new URL("../components/notifications-section.tsx", import.meta.url), "utf8");
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX } }).outputText
    + "\nObject.assign(exports, { LibraryPicker, MutedItems });",
  { exports, require: (name) => dependencies[name] ?? {} });
  return exports;
}
const render = (component, props) => renderToStaticMarkup(React.createElement(component, props));
const event = { key: "library.items.arrived", group: "Library", group_id: "notify.groups.library", title: "Library arrivals", description: "Fixture description", enabled: true };
const view = { instance_ready: false, is_admin: true, attention: [], events: [event], libraries: [{ id: 1, name: "Fixture movies" }, { id: 2, name: "Fixture shows" }], library_ids: null, muted_items: [{ id: 10, title: "Fixture title", year: 2024 }], ready_devices: 1, im_accounts: 0 };

test("notification settings render English controls, counts and muted titles", () => {
  const html = render(load("en", [view]).NotificationsSection);
  assert.doesNotMatch(html, /[\u3400-\u9fff]/);
  assert.match(html, /Send a test notification/);
  assert.match(html, /Send to 1 device/);
  assert.match(html, /1 title/);
  assert.match(html, /Fixture title/);
  assert.match(html, / \(2024\)/);
  assert.match(html, /Selecting all includes libraries added in the future/);
});

test("distinct source notification groups stay separate after their titles translate equally", () => {
  const same = { ...view, events: [{ ...event, group: "Same", group_id: "first" }, { ...event, key: "other.event", group: "Same", group_id: "second" }] };
  const html = render(load("en", [same]).NotificationsSection);
  assert.equal((html.match(/<h2>Same<\/h2>/g) ?? []).length, 2);
  assert.equal(same.events[0].group_id, "first");
});
