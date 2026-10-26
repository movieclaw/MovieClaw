import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import React from "react";
import * as jsx from "react/jsx-runtime";
import { renderToStaticMarkup } from "react-dom/server";
import ts from "typescript";
import { appTranslator } from "../lib/i18n/translate.ts";

const noop = () => {};
function load(path, locale, options = {}) {
  const calls = options.calls ?? [];
  class HttpError extends Error { constructor(message, status) { super(message); this.status = status; } }
  const imports = {
    "react/jsx-runtime": jsx,
    "react": { ...React, useState: (initial) => [options.busy ?? initial, noop], useEffect: noop },
    "next-intl": { useTranslations: () => appTranslator(locale) },
    "next/navigation": { useRouter: () => ({ push: (path) => calls.push(["route", path]) }) },
    "next/link": { default: ({ children, ...props }) => React.createElement("a", props, children) },
    "@/components/feedback": { useToast: () => ({ error: (message) => calls.push(["error", message]) }) },
    "@/components/llm-gate": { useLlmCapability: () => ({ state: options.capability ?? "configured" }) },
    "@/lib/agent-conversations": { useAgentConversations: () => ({ start: async (prompt) => { if (options.fail) throw new Error(""); calls.push(["prompt", prompt]); return "raw-session-id"; } }) },
    "@/lib/api/handoff": { fetchHandoffPrompt: async (kind, ref) => { calls.push(["handoff", kind, ref]); return { prompt: "作者现场" }; } },
    "@/lib/i18n/translate": { appTranslator: () => appTranslator(locale) },
    "@/lib/env": { publicEnv: { apiBaseUrl: "http://127.0.0.1/api/v1" } },
    "@/lib/permissions": { usePermissions: () => ({ isAdmin: options.admin ?? true }) },
    "@/components/settings-ui": { SETTINGS_INPUT_CLASS: "input" },
    "@/components/cloud-push-ui": { Toggle: () => null },
    "@/lib/http": { HttpError, resolveRequestUrl: (path) => "http://127.0.0.1/api/v1" + path, redirectToLoginOn401: noop },
  };
  const text = readFileSync(new URL(path, import.meta.url), "utf8");
  const source = text + (path.includes("plugin-app-frame") ? "\nexport {Missing};" : "");
  const exports = {};
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.ReactJSX } }).outputText, { exports, require: (key) => imports[key] ?? {}, URL, URLSearchParams, Headers, Response, fetch: async () => new Response(null, { status: 204 }) });
  return exports;
}
const render = (component, props) => renderToStaticMarkup(React.createElement(component, props));
function nodes(node, found = []) {
  if (!node || typeof node !== "object") return found;
  if (Array.isArray(node)) { node.forEach((child) => nodes(child, found)); return found; }
  found.push(node); nodes(node.props?.children, found); return found;
}
const schema = { properties: { channel: { type: ["string", "null"], enum: ["原始选项", "other"], title: "Channel" }, recipients: { type: "array", items: { type: "string" }, title: "Recipients" }, token: { type: "string", writeOnly: true, title: "Token" }, spare: { type: "string", writeOnly: true, title: "Spare" } } };

test("schema placeholders translate without changing field names, option tokens or text conversion", () => {
  const changes = [], props = { schema, values: {}, secretsSet: ["token"], onChange: (...args) => changes.push(args) };
  const before = JSON.stringify(schema);
  const loaded = load("../components/schema-form.tsx", "en");
  const html = render(loaded.SchemaForm, props);
  for (const value of ["(Not set)", "One per line", "Set (leave blank to keep)", "Not set"]) assert.ok(html.includes(value), value);
  assert.match(html, /value="原始选项"/);
  const fields = nodes(loaded.SchemaForm(props));
  fields.find((node) => node.type === "select").props.onChange({ target: { value: "原始选项" } });
  fields.find((node) => node.type === "textarea").props.onChange({ target: { value: "用户频道\nsecond" } });
  assert.deepEqual(changes, [["channel", "原始选项"], ["recipients", "用户频道\nsecond"]]);
  assert.deepEqual([...loaded.parseValue(schema.properties.recipients, "用户频道\nsecond")], ["用户频道", "second"]);
  assert.equal(JSON.stringify(schema), before);
});

test("handoff labels, failure fallback and missing-plugin guidance preserve routes and source evidence", async () => {
  const calls = [];
  const loaded = load("../components/handoff-button.tsx", "en", { calls });
  const props = { kind: "notice", refId: "17" };
  assert.match(render(loaded.HandoffButton, props), />Ask AI</);
  await loaded.HandoffButton(props).props.onClick();
  assert.deepEqual(calls, [["handoff", "notice", "17"], ["prompt", "作者现场"], ["route", "/sessions/raw-session-id"]]);
  const errors = [];
  await load("../components/handoff-button.tsx", "en", { calls: errors, fail: true }).HandoffButton(props).props.onClick();
  assert.deepEqual(errors.at(-1), ["error", "Could not start AI analysis"]);
  assert.match(render(load("../components/handoff-button.tsx", "en", { busy: true }).HandoffButton, props), /disabled="".*Preparing context…/);
  assert.equal(render(load("../components/handoff-button.tsx", "en", { capability: "unconfigured" }).HandoffButton, props), "");
  for (const admin of [true, false]) {
    const html = render(load("../components/plugin-app-frame.tsx", "en", { admin }).Missing);
    assert.match(html, /This page is unavailable/);
    assert.equal(html.includes('href="/settings/plugins"'), admin);
    assert.doesNotMatch(html, /[\u3400-\u9fff]/);
  }
});

function compression(locale, mode) {
  const text = readFileSync(new URL("../lib/backdrop.tsx", import.meta.url), "utf8");
  const source = ts.createSourceFile("backdrop.tsx", text, ts.ScriptTarget.Latest, true);
  const node = source.statements.find((node) => ts.isFunctionDeclaration(node) && node.name?.text === "fileToCompressedJpeg");
  class Reader { readAsDataURL() { if (mode === "read") this.onerror(); else { this.result = "raw-data-url"; this.onload(); } } }
  class Image { width = 4000; height = 2000; set src(value) { if (mode === "decode") this.onerror(); else this.onload(); } }
  const canvas = { getContext: () => mode === "unsupported" ? null : { drawImage: noop }, toBlob: (callback) => callback(mode === "encode" ? null : new Blob(["fixture"], { type: "image/jpeg" })) };
  const exports = {};
  vm.runInNewContext(ts.transpileModule(node.getText(source), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText, { exports, appTranslator: () => appTranslator(locale), FileReader: Reader, Image, document: { createElement: () => canvas } });
  return { compress: exports.fileToCompressedJpeg, canvas };
}

test("image processing reports all owned failures in the reader language without touching file names", async () => {
  const file = { name: "作者.png", type: "image/png" };
  for (const locale of ["en", "zh-Hans"]) {
    for (const [mode, english, chinese] of [["select", "Choose an image file", "请选择图片文件"], ["read", "Could not read the image", "读取图片失败"], ["decode", "Could not decode the image. Try another file.", "图片解码失败，请换一张试试"], ["unsupported", "This browser does not support image processing", "当前浏览器不支持图片处理"], ["encode", "Could not encode the image. Try again.", "图片编码失败，请重试"]]) {
      await assert.rejects(compression(locale, mode).compress(mode === "select" ? { ...file, type: "text/plain" } : file), (error) => error.message === (locale === "en" ? english : chinese));
    }
  }
  const { compress, canvas } = compression("en", "success");
  assert.equal((await compress(file)).type, "image/jpeg");
  assert.equal(canvas.width, 2560); assert.equal(canvas.height, 1280);
  assert.equal(file.name, "作者.png");
  await assert.rejects(load("../lib/agent-attachments.ts", "en").prepareImageAttachment({ name: "作者.txt", type: "text/plain" }), /Unsupported image format/);
});

test("empty SSE bodies and missing diagnostics credentials fail with localized errors before requests continue", async () => {
  for (const locale of ["en", "zh-Hans"]) {
    const expected = appTranslator(locale)("common.streamUnsupported");
    await assert.rejects(load("../lib/api/agent.ts", locale).streamSession("raw-id", noop), (error) => error.message === expected && error.status === 204);
    await assert.rejects(load("../lib/api/search.ts", locale).streamSearchTorrents({ keyword: "作者" }, noop), (error) => error.message === expected && error.status === 204);
    await assert.rejects(load("../lib/api/playback.ts", locale).fetchPlaybackDiagnostics("raw-id", "/stream.m3u8"), (error) => error.message === appTranslator(locale)("player.diagnostics.missingCredentials"));
  }
});
