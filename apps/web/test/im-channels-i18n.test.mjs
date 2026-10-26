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
import { formatRelativeTime } from "../lib/time.ts";

function load(name, locale, values = []) {
  const exports = {};
  let index = 0;
  const node = ({ children }) => React.createElement("div", null, children);
  const dependencies = {
    "react/jsx-runtime": jsx,
    react: { ...React, useState: (initial) => [index < values.length ? values[index++] : initial, () => {}], useEffect: () => {}, useCallback: (fn) => fn, useRef: (value) => ({ current: value }) },
    "next-intl": { useLocale: () => locale, useTranslations: () => appTranslator(locale) },
    "next/link": { __esModule: true, default: ({ children, ...props }) => React.createElement("a", props, children) },
    "@radix-ui/react-dropdown-menu": Object.fromEntries(["Root", "Trigger", "Portal", "Content", "Item"].map((key) => [key, node])),
    "@/components/channel-bind-dialog": { ChannelBindDialog: node },
    "@/components/cloud-push-ui": { ErrorBanner: node, StatusPill: ({ label }) => label },
    "@/components/feedback": { useToast: () => ({}), useConfirm: () => () => {} },
    "@/components/icons": { ChatIcon: () => null, PlusIcon: () => null },
    "@/components/llm-gate": { useLlmConfigured: () => true },
    "@/components/copy-button": { CopyButton: ({ label }) => React.createElement("button", null, label) },
    "@/components/modal": { Modal: node },
    "@/components/settings-ui": { SettingsSection: ({ title, description, children, action }) => React.createElement("section", null, React.createElement("h2", null, title), description, action, children), SettingsList: node,
      SettingsRow: ({ label, description, children }) => React.createElement("div", null, label, description, children), SettingsEmpty: ({ title, description }) => React.createElement("div", null, title, description) },
    "@/lib/api/channels": {}, "@/lib/time": { formatRelativeTime }, "@/lib/i18n/format": { formatList },
    "@/lib/use-visible-polling": { useVisiblePolling: () => {} },
  };
  const source = readFileSync(new URL(`../components/${name}.tsx`, import.meta.url), "utf8");
  const extra = name === "im-push-section" ? "ChannelAccountRowView, AddChannelMenu" : "FlowBindBody, FormBindBody, CallbackAddress";
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX } }).outputText
    + `\nObject.assign(exports, { ${extra} });`, { exports, require: (key) => dependencies[key] ?? {} });
  return exports;
}
const render = (component, props) => renderToStaticMarkup(React.createElement(component, props));
const channel = { id: "fixture", title: "Fixture channel", description: "Fixture description", entry_id: "fixture-plugin", receive: false, binding: { kind: "form", pairing: "code", hint: "Fixture hint", fields: [{ key: "token", label: "Bot token", required: false, secret: true, placeholder: "Enter token", help: "Fixture help" }] } };
const account = { channel_id: "fixture", account_id: "fixture-account", display_name: "User name", bound_user_id: "user-id", status: "active", running: true, channel_available: true, bound_at: "2026-01-01T00:00:00Z" };
const binding = { binding_id: "fixture-binding", channel_id: "fixture", kind: "flow", status: "need_input", message: "Fixture message", pair_code: "123456", qr_image: "data:image/svg+xml;base64,fixture", input_label: "Phone code", callback_url: "https://callback.invalid/path", callback_note: "Fixture callback note" };

test("IM settings render English account states, menus and plural counts", () => {
  const html = render(load("im-push-section", "en", [[channel], [account]]).ImPushSection);
  assert.doesNotMatch(html, /[\u3400-\u9fff]/);
  assert.match(html, /1 linked account/);
  assert.match(html, /Add Fixture channel channel/);
  for (const row of [account, { ...account, channel_available: false }, { ...account, status: "stale" }, { ...account, running: false }]) {
    const rowHtml = render(load("im-push-section", "en").ChannelAccountRowView, { row, channel });
    assert.doesNotMatch(rowHtml, /[\u3400-\u9fff]/);
    assert.match(rowHtml, /Unlink/);
  }
  const t = appTranslator("en");
  assert.equal(t("settings.imChannels.testSent", { count: 1 }), "Sent to 1 account. Check your client");
  assert.equal(t("settings.imChannels.testSent", { count: 2 }), "Sent to 2 accounts. Check your clients");
});

test("generic IM binding renders declared fields and English QR, input and retry controls", () => {
  assert.doesNotMatch(render(load("channel-bind-dialog", "en").ChannelBindDialog, { channel }), /[\u3400-\u9fff]/);
  const form = render(load("channel-bind-dialog", "en").FormBindBody, { channel });
  assert.match(form, /Get pairing code/);
  assert.match(form, /\(optional\)/);
  assert.match(form, /Fixture help/);
  for (const status of ["pending", "scanned", "need_input", "expired", "failed"]) {
    const html = render(load("channel-bind-dialog", "en", [{ ...binding, status }]).FlowBindBody, { channel });
    assert.doesNotMatch(html, /[\u3400-\u9fff]/);
    if (status === "need_input") { assert.match(html, /Phone code/); assert.match(html, /Confirm/); }
    if (status === "pending") assert.match(html, /QR code to link Fixture channel/);
  }
  const paired = render(load("channel-bind-dialog", "en", [{}, { ...binding, kind: "pairing", status: "pending" }]).FormBindBody, { channel });
  assert.match(paired, /123456/);
  assert.match(paired, /Valid for 10 minutes/);
  assert.match(paired, /https:\/\/callback.invalid\/path/);
  assert.doesNotMatch(paired, /[\u3400-\u9fff]/);
});
