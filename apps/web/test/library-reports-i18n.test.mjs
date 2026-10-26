import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import React from "react";
import * as jsx from "react/jsx-runtime";
import { renderToStaticMarkup } from "react-dom/server";
import ts from "typescript";
import { appTranslator } from "../lib/i18n/translate.ts";
import { formatNumber } from "../lib/i18n/format.ts";
import { formatDateTime } from "../lib/time.ts";
import { routingOverlapWarnings } from "../lib/library-routing-warnings.ts";

const noop = () => {};
const folder = { id: 1, backend_title: "Author provider", account_name: "作者账号", display_path: "原始目录", report: { finished_at: "2030-01-01T00:00:00Z", seconds: 61, cancelled: false, calls: 1, videos: 1234, identified: 1000, pending: 2, skipped: { disc: 1, iso: 2, extra: 3 } } };
function load(locale) {
  const imports = { "react/jsx-runtime": jsx, "next-intl": { useLocale: () => locale, useTranslations: () => appTranslator(locale) }, "@/lib/i18n/translate": { appTranslator }, "@/lib/i18n/format": { formatNumber }, "@/lib/time": { formatDateTime }, "@/components/modal": { Modal: ({ children, label }) => React.createElement("section", { "aria-label": label }, children) } };
  const source = readFileSync(new URL("../components/cloud-import-report.tsx", import.meta.url), "utf8");
  const exports = {};
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.ReactJSX } }).outputText + "\nObject.assign(exports, { FolderReport, seconds });", { exports, require: (key) => imports[key] ?? {} });
  return exports;
}
const render = (component, props) => renderToStaticMarkup(React.createElement(component, props));
const library = (id, name, rules, kind = "movie") => ({ id, name, kind, match_rules: rules });
const rule = (field, ...values) => ({ field, values, op: "any_of" });

test("cloud import facts render English counts, durations and outcomes while author values stay raw", () => {
  const { CloudImportReport, FolderReport, seconds } = load("en");
  const before = JSON.stringify(folder);
  const html = render(CloudImportReport, { library: { name: "作者库", cloud_folders: [folder] }, onClose: noop, onClaim: noop });
  assert.match(html, /1,234 video files/);
  assert.match(html, /Completed in 1 minute · 1 call to Author provider/);
  assert.match(html, /1 disc folder · Not supported yet/);
  assert.match(html, /2 disc images · Not supported yet/);
  assert.match(html, /Identify files/);
  assert.ok(html.includes("作者账号") && html.includes("原始目录") && html.includes("作者库"));
  assert.doesNotMatch(html.replaceAll("作者账号", "Account").replaceAll("原始目录", "Folder").replaceAll("作者库", "Library"), /[\u3400-\u9fff]/);
  assert.match(render(FolderReport, { folder: { ...folder, report: null }, onClaim: noop }), /Import is not finished yet/);
  assert.equal(seconds(0.2, "en"), "1 second");
  assert.equal(seconds(59.9, "en"), "60 seconds");
  assert.equal(seconds(60, "en"), "1 minute");
  assert.equal(JSON.stringify(folder), before);
});

test("overlap messages use source rules and stable numeric pair identities in both locales", () => {
  const a = library(1, "类型", [rule("genres", 16)]);
  const b = library(2, "区域", [rule("genres", 16)]);
  const before = JSON.stringify([a, b]);
  const en = routingOverlapWarnings([a, b], "en"), zh = routingOverlapWarnings([a, b], "zh-Hans");
  assert.equal(en[0].id, zh[0].id);
  assert.equal(en[0].id, routingOverlapWarnings([b, a], "en")[0].id);
  assert.match(en[0].message, /add a “Region” condition/);
  assert.ok(en[0].message.includes("类型") && en[0].message.includes("区域"));
  assert.equal(JSON.stringify([a, b]), before);
  assert.equal(routingOverlapWarnings([a, { ...b, kind: "tv" }], "en").length, 0);
  assert.equal(routingOverlapWarnings([a, { ...b, match_rules: [rule("genres", 99)] }], "en").length, 0);
  assert.equal(routingOverlapWarnings([a, { ...b, match_rules: [rule("genres", 16), rule("origin_countries", "JP")] }], "en").length, 0);
  const both = routingOverlapWarnings([{ ...a, match_rules: [rule("genres", 16), rule("origin_countries", "JP")] }, { ...b, match_rules: [rule("genres", 16), rule("origin_countries", "JP")] }], "en");
  assert.match(both[0].message, /Adjust their overlapping values/);
});
