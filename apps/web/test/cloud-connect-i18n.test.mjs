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
import { formatDateTime, formatRelativeTime } from "../lib/time.ts";

function load(name, locale, values = []) {
  const exports = {};
  let index = 0;
  const node = ({ children }) => React.createElement("div", null, children);
  const card = ({ title, description, hint, action, children }) => React.createElement("section", null,
    React.createElement("h2", null, title), description, hint, action, children);
  const dependencies = {
    "react/jsx-runtime": jsx,
    react: { ...React, useState: (initial) => [index < values.length ? values[index++] : typeof initial === "function" ? initial() : initial, () => {}],
      useEffect: () => {}, useCallback: (fn) => fn, useRef: (value) => ({ current: value }) },
    "next-intl": { useLocale: () => locale, useTranslations: () => appTranslator(locale) },
    "next/link": { __esModule: true, default: ({ children, ...props }) => React.createElement("a", props, children) },
    "@/components/cloud/pairing-dialog": { CloudPairingDialog: () => null },
    "@/components/cloud-push-ui": { Banner: card, ErrorBanner: node, StatusPill: ({ label }) => label, Toggle: ({ label }) => label, Spinner: () => null },
    "@/components/feedback": { useConfirm: () => () => {}, useToast: () => ({}) },
    "@/components/modal": { Modal: node },
    "@/components/icons": { CloudIcon: () => null, InfoIcon: () => null, CheckIcon: () => null, XIcon: () => null },
    "@/components/settings-ui": { SettingsCard: card, SettingsSection: card, SettingsList: node,
      SettingsRow: ({ label, description, children }) => React.createElement("div", null, label, description, children) },
    "@/lib/api/cloud": {}, "@/lib/use-visible-polling": { useVisiblePolling: () => {} },
    "@/lib/cloud-push-display": display, "@/lib/time": { formatDateTime, formatRelativeTime },
  };
  const source = readFileSync(new URL(`../components/${name}.tsx`, import.meta.url), "utf8");
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX } }).outputText
    + (name === "cloud-section" ? "\nObject.assign(exports, { DisconnectedView, PairingCard, ConnectedView, SummaryCard });" : ""),
  { exports, require: (name) => dependencies[name] ?? {} });
  return exports;
}
const render = (component, props) => renderToStaticMarkup(React.createElement(component, props));
const status = { state: "disconnected", server_name: "Fixture NAS", cloud_url: "https://api.movieclaw.io", custom_cloud_url: false,
  health: null, health_message: null, notices: [], pairing: null, connection: null, report_stats: true, last_disconnect: null };
const pairing = { status: "pending", message: null, instance_name: "Fixture NAS", user_code: "ABCD-EFGH", expires_at: "2099-01-01T00:00:00Z", verification_uri: "https://movieclaw.io/activate", verification_uri_complete: "https://movieclaw.io/activate?code=ABCD-EFGH" };
const connection = { instance_name: "Fixture NAS", account_display: "a•••@example.com", connected_at: "2026-10-01T08:00:00Z", scopes: ["push"], capabilities: ["push", "remote", "control"], limits: { day: 5000 } };

test("cloud helpers use the requested language and preserve unknown upstream messages and capability IDs", () => {
  const before = structuredClone(connection);
  assert.equal(display.cloudReportsInfoUrl(status.cloud_url, "en"), "https://movieclaw.io/en/privacy#server-reports");
  assert.equal(display.cloudReportsInfoUrl(status.cloud_url, "zh-Hans"), "https://movieclaw.io/zh/privacy#server-reports");
  assert.match(display.connectedAccountLine(" a•••@example.com ", "en"), /account a•••@example.com/);
  assert.equal(display.connectedAccountLine(null, "en"), "Connected to your MovieClaw account");
  assert.equal(display.pairingFailureText("denied", "上游原文", "en"), "上游原文");
  assert.equal(display.healthMessage("expired", "上游原文", "en"), "上游原文");
  for (const state of ["denied", "expired", "unknown"]) assert.doesNotMatch(display.pairingFailureText(state, "", "en"), /[\u3400-\u9fff]/);
  for (const health of ["unreachable", "expired", "unsupported"]) assert.doesNotMatch(display.healthMessage(health, "", "en"), /[\u3400-\u9fff]/);
  assert.equal(display.capabilityLabel("作者能力", "en"), "作者能力");
  assert.equal(display.capabilityLabel("constructor", "en"), "constructor");
  assert.deepEqual(display.capabilityRows(connection.scopes, connection.capabilities, "en").map((row) => row.label), ["Official push", "Remote access", "Remote control"]);
  assert.deepEqual(connection, before);
});

test("cloud pages and pairing states render English without changing server names or codes", () => {
  const code = load("cloud-section", "en");
  const outputs = [render(code.DisconnectedView, { status }),
    render(code.PairingCard, { pairing }),
    render(code.ConnectedView, { status: { ...status, state: "connected", connection } }),
    render(load("cloud/pairing-dialog", "en").CloudPairingDialog, { status }),
    render(load("cloud/pairing-dialog", "en").CloudPairingDialog, { status: { ...status, state: "pairing", pairing } }),
    render(load("cloud/pairing-dialog", "en").CloudPairingDialog, { status: { ...status, state: "connected", connection } }),
  ].join("");
  assert.doesNotMatch(outputs, /[\u3400-\u9fff]/);
  assert.match(outputs, /Connect to a MovieClaw account/);
  assert.match(outputs, /5,000 notifications per day/);
  assert.match(outputs, /ABCD-EFGH/);
  assert.match(outputs, /Code expires in/);
  assert.match(outputs, /Fixture NAS/);
});
