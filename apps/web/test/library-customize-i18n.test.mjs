import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import React from "react";
import * as jsx from "react/jsx-runtime";
import { renderToStaticMarkup } from "react-dom/server";
import ts from "typescript";
import { appTranslator } from "../lib/i18n/translate.ts";
import * as home from "../lib/home-rows.ts";

const libraries = [{ id: 1, name: "Author movies", kind: "movie", viewer_access: true, exclude_from_home: false }, { id: 2, name: "Author series", kind: "tv", viewer_access: true, exclude_from_home: false }];
const collections = [{ id: 3, name: "Author collection", kind: "user", library_id: null, sort: "added_at", item_count: 1 }];
const preferences = { language: "en", home: { rows: [] } };
function load(locale, values = []) {
  const exports = {};
  let index = 0;
  const dependencies = {
    "react/jsx-runtime": jsx,
    react: { ...React, useState: (initial) => [index < values.length ? values[index++] : initial, () => {}], useEffect: () => {}, useCallback: (fn) => fn, useMemo: (fn) => fn(), useRef: (value) => ({ current: value }) },
    "next-intl": { useLocale: () => locale, useTranslations: () => appTranslator(locale) },
    "@/components/page-nav": { PageNav: ({ title, fallback }) => React.createElement("div", null, title, fallback.label) },
    "@/components/library-filter-bar": { WallSortControl: ({ options }) => React.createElement("div", null, options.map(([key,label]) => React.createElement("span", { key }, label))) },
    "@/components/icons": new Proxy({}, { get: () => () => null }),
    "@/lib/api/libraries": {}, "@/lib/api/collections": {},
    "@/lib/home-rows": home,
    "@/lib/ui-prefs": { useUiPrefs: () => ({ prefs: preferences, savePrefs: () => {} }) },
  };
  const source = readFileSync(new URL("../components/library-customize-view.tsx", import.meta.url), "utf8");
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.ReactJSX } }).outputText
    + "\nObject.assign(exports, { RowItem, sortOptions });",
    { exports, require: (key) => dependencies[key] ?? {} });
  return exports;
}
const render = (component, props) => renderToStaticMarkup(React.createElement(component, props));
const state = (libs = libraries, failed = false, draft = null) => [libs, collections, failed, null, draft, null, null];
const rowProps = (row) => ({ row, expanded: true, dragging: false, onToggle: () => {}, onChange: () => {}, onRemove: () => {}, onGripPointerDown: () => {}, onMoveKey: () => {} });

test("home customization renders localized defaults, sort options and accessible controls", () => {
  const current = load("en", state());
  const html = render(current.LibraryCustomizeView);
  assert.doesNotMatch(html, /[\u3400-\u9fff]/);
  assert.match(html, /Customize home/);
  assert.match(html, /Reset layout/);
  assert.match(html, /All movies/);
  const rows = [home.newLibraryRow(libraries[0], "lib-new"), home.newCollectionRow(collections[0], "collection-new"), home.newMediaKindRow("movie", libraries.slice(0,1), "kind-new")];
  for (const row of rows) {
    const text = render(current.RowItem, rowProps(row));
    assert.doesNotMatch(text, /[\u3400-\u9fff]/);
    assert.match(text, /Name for/);
    assert.match(text, /Delete row/);
    assert.deepEqual(current.sortOptions(row, "en").map(([key]) => key), current.sortOptions(row, "zh-Hans").map(([key]) => key));
  }
});

test("rendering alternate languages does not save generated names or change row facts", () => {
  const rows = [...home.buildHomeRows({ rows: [] }, libraries, collections), home.newLibraryRow(libraries[0], "extra"), home.newCollectionRow(collections[0], "collection")];
  rows.find((row) => row.id === "extra").name = "作者自定名";
  const before = structuredClone(rows), stored = home.rowsToPrefs(rows);
  for (const locale of ["en", "zh-Hans", "en"]) {
    for (const row of rows) home.rowTitle(row, locale);
  }
  assert.equal(home.rowTitle(rows.find((row) => row.id === "extra"), "en"), "作者自定名");
  assert.deepEqual(rows, before);
  assert.deepEqual(home.rowsToPrefs(rows), stored);
  assert.equal(stored.find((row) => row.id === "collection").name, undefined);
});
