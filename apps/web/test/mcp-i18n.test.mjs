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

const documents = ["开发者工具说明", "开发者参数说明", "开发者命令说明"];
const service = { domain: "jobs", description: documents[0], command_count: 2, expanded_bytes: 2048, collapsed_bytes: 1024 };
const endpoint = { id: "source-id", slug: "source-slug", name: "Author endpoint", description: "Author description", services: ["jobs"], missing_services: [], expand_tools: true, enabled: true, token_hint: "mclaw_test…", timeout_seconds: 300, tool_count: 2, url: "http://fixture/mcp/source-slug", created_at: "2030-01-01T00:00:00Z", last_used_at: null };
const tool = { name: "jobs_list", summary: documents[0], description: documents[0], service: "jobs", read_only: true, destructive: false, parameters: [{ name: "limit", type: "integer", required: true, description: documents[1], location: "query", options: ["pending", "done"] }], commands: [] };
const commandTool = { ...tool, name: "jobs", parameters: [], commands: [{ name: "list", summary: documents[2], params: ["limit*"], dangerous: "", is_job: true }] };
const status = { enabled: true, base_url: "http://fixture", external_url_configured: true, endpoints: [endpoint], services: [service] };
const preview = { tool_count: 1, command_count: 2, approx_bytes: 1024, tools: [tool, commandTool] };
const check = { ok: true, message: "Author result", protocol_version: "2026-07-28", tool_count: 2, elapsed_ms: 10, probe_tool: "jobs_list", probe_ok: true, probe_message: "Author response", warnings: ["Author warning"] };
const initial = { name: "Author endpoint", slug: "source-slug", services: ["jobs"], expand_tools: true, timeout_seconds: 300 };
const noop = () => {};
const formProps = { initial, services: [service], baseUrl: "http://fixture", busy: false, slugEditable: true, submitLabel: "Author submit", onSubmit: noop, onCancel: noop };
const detailProps = { endpoint, services: [service], baseUrl: "http://fixture", busy: false, tab: "overview", onTab: noop, onBack: noop, onToggleEnabled: noop, onSave: noop, onRotate: noop, onDelete: noop };
function load(locale, states = {}, updates = []) {
  const cache = {};
  const node = ({ children, title, description, action, label }) => React.createElement("div", null, title, description, action, label, children);
  const shared = {
    "react/jsx-runtime": jsx,
    "next-intl": { useLocale: () => locale, useTranslations: () => appTranslator(locale) },
    "@/components/icons": new Proxy({}, { get: () => () => null }),
    "@/components/copy-button": { CopyButton: ({ text, label }) => React.createElement("button", { "data-copy": text }, label) },
    "@/components/cloud-push-ui": { Banner: node, ErrorBanner: node, Toggle: ({ label }) => React.createElement("span", null, label) },
    "@/components/settings-ui": { SettingsCard: node, SettingsSection: node, SettingsRow: node, SettingsList: node, SettingsEmpty: node, SettingsTabs: ({ tabs }) => React.createElement("div", null, tabs.map((tab) => React.createElement("span", { key: tab.key ?? tab.id }, tab.label))), SETTINGS_DANGER_BUTTON_CLASS: "danger", SETTINGS_PRIMARY_BUTTON_CLASS: "primary", SETTINGS_BUTTON_CLASS: "button", SETTINGS_INPUT_CLASS: "input" },
    "@/components/feedback": { useConfirm: () => noop },
    "@/lib/api/mcp": {}, "@/lib/devices-display": { relativeTime },
  };
  function file(name) {
    if (cache[name]) return cache[name];
    const exports = {}, values = states[name] ?? [];
    let index = 0;
    const react = { ...React, useState: (initial) => [index < values.length ? values[index++] : initial, (next) => updates.push(next)], useEffect: noop, useCallback: (fn) => fn, useMemo: (fn) => fn(), useRef: (value) => ({ current: value }) };
    const path = name === "mcp-section.tsx" ? "../components/mcp-section.tsx" : `../components/mcp/${name}`;
    const source = readFileSync(new URL(path, import.meta.url), "utf8");
    vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.ReactJSX } }).outputText + (name === "mcp-section.tsx" ? "\nObject.assign(exports, { TokenIssued });" : name === "tool-catalog.tsx" ? "\nObject.assign(exports, { ParameterTable, CommandTable });" : ""), { exports, require: (key) => key === "react" ? react : key.startsWith("@/components/mcp/") ? file(key.split("/").at(-1)+".tsx") : shared[key] ?? {} });
    cache[name] = exports;
    return exports;
  }
  return file;
}
const render = (component, props) => renderToStaticMarkup(React.createElement(component, props));
const rootState = (view = { slug: null, tab: "overview", creating: false }, issued = null) => [status, null, false, view, issued];
const cleanDocuments = (html) => documents.reduce((text, document) => text.replaceAll(document, "Developer document"), html);

test("MCP management controls render English while developer documents and machine values stay intact", () => {
  for (const view of [{ slug: null, tab: "overview", creating: false }, { slug: null, tab: "overview", creating: true }, { slug: endpoint.slug, tab: "overview", creating: false }, { slug: endpoint.slug, tab: "tools", creating: false }, { slug: endpoint.slug, tab: "settings", creating: false }]) {
    const modules = load("en", { "mcp-section.tsx": rootState(view), "endpoint-detail.tsx": [preview, "", check, false] });
    const html = render(modules("mcp-section.tsx").McpSection);
    assert.doesNotMatch(cleanDocuments(html), /[\u3400-\u9fff]/);
    assert.match(html, /Author endpoint|Endpoint name/);
  }
  const token = "mclaw_own_test_token";
  const html = render(load("en")("mcp-section.tsx").TokenIssued, { name: endpoint.name, url: endpoint.url, token, onDone: noop });
  assert.match(html, /Save the token/);
  assert.match(html, /Copy token/);
  assert.ok(html.includes(token) && html.includes(endpoint.url));
  const body = render(load("en", { "tool-catalog.tsx": ["", "all", tool.name, new Set()] })("tool-catalog.tsx").ToolCatalog, { tools: [tool, commandTool] });
  assert.ok(body.includes(documents[1]));
  assert.doesNotMatch(cleanDocuments(body), /[\u3400-\u9fff]/);
});

function buttons(node, output = []) {
  if (!node || typeof node !== "object") return output;
  if (Array.isArray(node)) { for (const item of node) buttons(item, output); return output; }
  if (node.type === "button") output.push(node);
  buttons(node.props?.children, output);
  return output;
}
test("translated Expanded and Collapsed cards always submit their boolean modes", () => {
  for (const locale of ["en", "zh-Hans"]) {
    const updates = [];
    const form = load(locale, {}, updates)("endpoint-form.tsx").EndpointForm(formProps);
    const choices = buttons(form);
    for (const [key, expected] of [["expanded", true], ["collapsed", false]]) {
      const card = choices.find((button) => button.key === key);
      assert.ok(card);
      card.props.onClick();
      assert.equal(updates.at(-1).expand_tools, expected);
      assert.equal(updates.at(-1).slug, initial.slug);
      assert.deepEqual(updates.at(-1).services, initial.services);
    }
  }
});
