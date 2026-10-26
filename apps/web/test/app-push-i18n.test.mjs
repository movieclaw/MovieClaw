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

function load(name, locale, values = []) {
  const exports = {};
  let index = 0;
  const node = ({ children }) => React.createElement("div", null, children);
  const section = ({ title, description, footnote, action, children }) => React.createElement("section", null,
    React.createElement("h2", null, title), description, footnote, action, children);
  const dependencies = {
    "react/jsx-runtime": jsx,
    react: { ...React, useId: () => "fixture-id", useState: (initial) => [index < values.length ? values[index++] : typeof initial === "function" ? initial() : initial, () => {}], useEffect: () => {}, useCallback: (fn) => fn },
    "next-intl": { useLocale: () => locale, useTranslations: () => appTranslator(locale) },
    "next/link": { __esModule: true, default: ({ children, ...props }) => React.createElement("a", props, children) },
    "next/navigation": { useRouter: () => ({}) },
    "@/components/app-push/relay-dialogs": { AddRelayDialog: () => null, EditRelayDialog: () => null, RELAY_DEPLOY_URL: "https://example.com" },
    "@/components/cloud-push-ui": { Banner: section, ErrorBanner: node, StatusPill: ({ label }) => label, Toggle: ({ label }) => label },
    "@/components/feedback": { useConfirm: () => () => {}, useToast: () => ({}) },
    "@/components/modal": { Modal: node },
    "@/components/icons": { CloudIcon: () => null, ServerIcon: () => null, PlusIcon: () => null, CheckIcon: () => null },
    "@/components/settings-ui": { SettingsSection: section, SettingsList: node,
      SettingsMoreMenu: ({ label, items }) => React.createElement("div", null, label, items.map((item) => item.label).join("|")) },
    "@/lib/api/push": {}, "@/lib/cloud-push-display": display,
  };
  const source = readFileSync(new URL(`../components/${name}.tsx`, import.meta.url), "utf8");
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX } }).outputText
    + (name === "app-push-section" ? "\nObject.assign(exports, { ChannelList, ChannelRow, QuotaMeter });" : "\nexports.ProbeResult = ProbeResult;"),
  { exports, require: (name) => dependencies[name] ?? {} });
  return exports;
}
const render = (component, props) => renderToStaticMarkup(React.createElement(component, props));
const channel = { id: "fixture-relay", kind: "custom", name: "Fixture relay", state: "ok", status_text: "", enabled: true, url: "http://relay.lan", auth_mode: "static", topics: ["io.fixture.app"], device_count: 1, last_error: null, quota: { limit: 5000, used: 7 } };
const probe = { reachable: true, error: null, software: "fixture-relay/1", protocol: 1, auth_mode: "static", topics: ["io.fixture.app"], matched_devices: 1, warnings: [] };

test("push channel helpers use explicit languages, plural counts and unchanged upstream values", () => {
  const before = structuredClone(channel);
  assert.equal(display.channelPill(channel, "disconnected", "en").label, "Working");
  assert.equal(display.channelPill({ ...channel, status_text: "上游原文" }, "connected", "en").label, "上游原文");
  assert.equal(display.channelPill({ ...channel, kind: "official", state: "inactive" }, "disconnected", "en").label, "Inactive");
  assert.equal(display.authModeLabel("constructor", "en"), "constructor");
  assert.equal(display.authModeLabel("none", "en"), "No authentication");
  assert.match(display.channelDetails(channel, "en"), /Token/);
  assert.equal(display.channelDeviceCount(1, "en"), "1 device");
  assert.equal(display.channelDeviceCount(2, "en"), "2 devices");
  assert.equal(display.quotaLabel({ limit: null, used: 1 }, "en"), "1 notification used today");
  assert.equal(display.quotaLabel({ limit: 5000, used: 7 }, "en"), "Used 7 / 5,000 notifications today");
  const args = { probe: null, url: "http://relay.lan", probedUrl: "", token: "", name: "" };
  assert.equal(display.relayAddBlocker(args, "en"), "Check the relay address first");
  assert.equal(display.relayAddBlocker({ ...args, probe: { ...probe, error: "作者原文" }, probedUrl: args.url }, "en"), "作者原文");
  assert.match(display.uncoveredSummary([{ topic: "io.fixture.app", device_count: 1 }], "en"), /^1 device uses/);
  assert.deepEqual(channel, before);
});

test("push management and relay dialogs render English while preserving IDs, URLs and names", () => {
  const code = load("app-push-section", "en");
  const outputs = [render(code.ChannelList, { view: { channels: [channel], cloud_state: "disconnected", uncovered: [] } }),
    render(code.QuotaMeter, { quota: channel.quota }),
    render(load("app-push/relay-dialogs", "en").AddRelayDialog),
    render(load("app-push/relay-dialogs", "en", [channel.url, probe, channel.url, "fixture-token", "Fixture relay", null, null]).AddRelayDialog),
    render(load("app-push/relay-dialogs", "en").EditRelayDialog, { channel }),
  ].join("");
  assert.doesNotMatch(outputs, /[\u3400-\u9fff]/);
  assert.match(outputs, /Add your own relay/);
  assert.match(outputs, /Protocol v1/);
  assert.match(outputs, /1 device/);
  assert.match(outputs, /Fixture relay/);
  assert.match(outputs, /io.fixture.app/);
  assert.match(outputs, /http:\/\/relay.lan/);
});
