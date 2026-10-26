import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import React from "react";
import * as jsx from "react/jsx-runtime";
import { renderToStaticMarkup } from "react-dom/server";
import ts from "typescript";
import * as sourceAnnotation from "../lib/media-source-annotation.ts";
import { appTranslator } from "../lib/i18n/translate.ts";
import { formatBytes } from "../lib/format.ts";

const noop = () => {};
const candidates = [{ file_id: 1, file_name: "作者.mkv", size_bytes: 800000000, media_source: null, media_source_manual: false }, { file_id: 2, file_name: "manual.mkv", size_bytes: 1000, media_source: "user-lowest", media_source_manual: true }];
const props = { mediaItemId: 1, seasonNumber: 7, isMovie: false, onClose: noop, onApplied: noop };
function load(locale, values = [], calls = []) {
  let index = 0;
  const imports = {
    "react/jsx-runtime": jsx,
    "react": { ...React, useState: (initial) => [index < values.length ? values[index++] : initial, noop], useEffect: noop },
    "next-intl": { useLocale: () => locale, useTranslations: () => appTranslator(locale) },
    "@/components/modal": { Modal: ({ children, label }) => React.createElement("section", { "aria-label": label }, children) },
    "@/lib/api/libraries": { annotateMediaSource: async (...args) => { calls.push(args); return { files: candidates.length }; } },
    "@/lib/media-source-annotation": sourceAnnotation,
    "@/lib/format": { formatBytes },
  };
  const source = readFileSync(new URL("../components/media-source-annotation-dialog.tsx", import.meta.url), "utf8");
  const exports = {};
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.ReactJSX } }).outputText, { exports, require: (key) => imports[key] ?? {} });
  return exports.MediaSourceAnnotationDialog;
}
const render = (component, ownProps = props) => renderToStaticMarkup(React.createElement(component, ownProps));
function elements(node, output = []) {
  if (!node || typeof node !== "object") return output;
  if (Array.isArray(node)) { node.forEach((child) => elements(child, output)); return output; }
  output.push(node); elements(node.props?.children, output); return output;
}

test("source annotation labels and consequences vary by locale while tier tokens and warnings stay intact", () => {
  const zh = sourceAnnotation.mediaSourceOptions("zh-Hans");
  const en = sourceAnnotation.mediaSourceOptions("en");
  assert.deepEqual(en.map(({ value, destructive }) => [value, destructive]), zh.map(({ value, destructive }) => [value, destructive]));
  assert.doesNotMatch(en.map(({ label, consequence }) => label + consequence).join(" "), /[\u3400-\u9fff]/);
  assert.equal(en.filter((option) => option.destructive).length, 1);
  assert.equal(en.find((option) => option.destructive).value, "user-lowest");
  const before = JSON.stringify(candidates);
  for (const ownProps of [props, { ...props, seasonNumber: 0 }, { ...props, seasonNumber: 0, isMovie: true }]) {
    const html = render(load("en", [candidates, "user-lowest", false, null]), ownProps);
    assert.match(html, /Currently Lowest tier/);
    assert.match(html, /2 files will be updated together/);
    assert.doesNotMatch(html.replaceAll("作者.mkv", "Author.mkv"), /[\u3400-\u9fff]/);
  }
  const failed = render(load("en", [null, null, false, { key: "library.sourceAnnotation.loadFailed" }]));
  assert.match(failed, /Could not load the files/);
  assert.equal(JSON.stringify(candidates), before);
});

test("confirming an English choice submits the raw source and reports a localized count", async () => {
  const calls = [], messages = [];
  const component = load("en", [candidates, "Remux", false, null], calls);
  const tree = component({ ...props, onApplied: (message) => messages.push(message) });
  const button = elements(tree).find((node) => node.type === "button" && React.Children.toArray(node.props.children).includes("Confirm source"));
  button.props.onClick();
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual([...calls[0]], [1, 7, "Remux"]);
  assert.equal(messages[0], "Set the source of 2 files in Season 7 to “Remux”.");
});
