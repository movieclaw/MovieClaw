import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import React from "react";
import * as jsx from "react/jsx-runtime";
import { renderToStaticMarkup } from "react-dom/server";
import ts from "typescript";
import * as categories from "../lib/categories.ts";
import { appTranslator } from "../lib/i18n/translate.ts";

const noop = () => {};
const custom = { type: "preset", id: "source-id", name: "电影", visible: true, categories: ["movie", "tv"], site_ids: ["mteam", "ttg"], poster_mode: true, skip_history: true };
const tabs = [{ type: "category", id: "movie", visible: true }, { type: "category", id: "other", visible: false }, custom];
const draft = { editingId: custom.id, name: custom.name, categories: custom.categories, siteIds: custom.site_ids, posterMode: false, skipHistory: false };
const sites = [{ siteId: "mteam", displayName: "M-Team", usable: true }, { siteId: "ttg", displayName: "Author site", usable: false }];
function load(locale, values = []) {
  let index = 0;
  const node = ({ title, label, footnote, action, children }) => React.createElement("section", null, title, label, action, children, footnote);
  const imports = {
    "react/jsx-runtime": jsx,
    "react": { ...React, useState: (initial) => [index < values.length ? values[index++] : initial, noop], useEffect: noop, useRef: (value) => ({ current: value }) },
    "next-intl": { useLocale: () => locale, useTranslations: () => appTranslator(locale) },
    "@/components/cloud-push-ui": { ErrorBanner: node, Toggle: ({ label, checked }) => React.createElement("span", { "aria-label": label, "data-on": checked }, label) },
    "@/components/settings-ui": { SettingsCard: node, SettingsSection: node, SettingsMoreMenu: ({ label, items }) => React.createElement("span", { "aria-label": label }, items.map((item) => React.createElement("span", { key: item.label }, item.label))), SETTINGS_BUTTON_CLASS: "button", SETTINGS_PRIMARY_BUTTON_CLASS: "primary", SETTINGS_INPUT_CLASS: "input" },
    "@/components/feedback": { useConfirm: () => noop },
    "@/components/icons": { GripIcon: () => null, PlusIcon: () => null },
    "@/lib/api/sites": {}, "@/lib/http": { HttpError: Error },
    "@/lib/categories": categories, "@/lib/search-prefs": { useSearchPrefs: () => ({ tabs, loading: false, saveTabs: noop }) },
    "nanoid": { nanoid: () => "source-new-id" },
  };
  const source = readFileSync(new URL("../components/search-settings.tsx", import.meta.url), "utf8");
  const exports = {};
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.ReactJSX } }).outputText + "\nObject.assign(exports, { PresetEditor });", { exports, require: (key) => imports[key] ?? {} });
  return exports;
}
const render = (component, props = {}) => renderToStaticMarkup(React.createElement(component, props));
const editorProps = { draft, busy: false, onChange: noop, onSave: noop, onCancel: noop };
function elements(node, output = []) {
  if (!node || typeof node !== "object") return output;
  if (Array.isArray(node)) { node.forEach((item) => elements(item, output)); return output; }
  output.push(node);
  elements(node.props?.children, output);
  elements(node.props?.action, output);
  return output;
}

test("search categories localize built-in labels and controls while preserving user names and facts", () => {
  const before = JSON.stringify(tabs);
  const root = render(load("en", [null, false, null, null]).SearchSection);
  assert.match(root, /Movies/);
  assert.match(root, /Other/);
  assert.match(root, /电影/);
  assert.match(root, /Movies and TV shows · 2 sites · Posters · Private/);
  assert.doesNotMatch(root.replaceAll(custom.name, "Author name"), /[\u3400-\u9fff]/);
  for (const siteOptions of [null, [], sites]) {
    const body = render(load("en", [siteOptions]).PresetEditor, editorProps);
    assert.doesNotMatch(body.replaceAll(custom.name, "Author name"), /[\u3400-\u9fff]/);
    assert.match(body, /Edit custom category/);
    assert.match(body, /Resource categories/);
  }
  assert.equal(JSON.stringify(tabs), before);
  assert.equal(categories.scopeOfTab(custom).label, "电影");
  assert.equal(categories.scopeOfTab(custom).labelKey, undefined);
});

test("translated editor labels submit category tokens and boolean flags unchanged", () => {
  for (const locale of ["en", "zh-Hans"]) {
    const changes = [];
    const tree = load(locale, [sites]).PresetEditor({ ...editorProps, onChange: (next) => changes.push(next) });
    const nodes = elements(tree);
    const movie = nodes.find((node) => node.type === "button" && node.props.children === categories.categoryLabel("movie", locale));
    movie.props.onClick();
    assert.deepEqual([...changes.at(-1).categories], ["tv"]);
    assert.equal(changes.at(-1).name, custom.name);
    assert.deepEqual([...changes.at(-1).siteIds], custom.site_ids);
    for (const [key, field] of [["posterToggle", "posterMode"], ["privateToggle", "skipHistory"]]) {
      const label = appTranslator(locale)(`search.preferences.${key}`, { enabled: "no" });
      nodes.find((node) => node.props?.label === label).props.onChange(true);
      assert.equal(changes.at(-1)[field], true);
      assert.equal(changes.at(-1).editingId, custom.id);
    }
  }
});
