import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import React from "react";
import * as jsx from "react/jsx-runtime";
import { renderToStaticMarkup } from "react-dom/server";
import ts from "typescript";
import { appTranslator } from "../lib/i18n/translate.ts";
import * as genreLabels from "../lib/genre-labels.ts";
import * as homeRows from "../lib/home-rows.ts";
import * as wallSort from "../lib/wall-sort.ts";
import { formatRecentAddition, buildRecentAdditionOverlay } from "../lib/recent-addition.ts";
import { favoriteLevelLabel } from "../lib/favorites.ts";

const noop = () => {};
function load(locale, values = [[], 0, 0, false], pref = "default") {
  let index = 0;
  const imports = {
    "react/jsx-runtime": jsx,
    "react": { ...React, useState: (initial) => [index < values.length ? values[index++] : initial, noop], useEffect: noop, useLayoutEffect: noop },
    "next-intl": { useLocale: () => locale, useTranslations: () => appTranslator(locale) },
    "@/lib/i18n/translate": { appTranslator },
    "@/lib/genre-labels": genreLabels,
    "@/lib/home-rows": homeRows,
    "@/lib/wall-sort": { ...wallSort, useWallSortPref: () => [{ pref, reversed: false }, noop, noop, true] },
    "@/lib/use-page-title": { usePageTitle: noop },
    "@/lib/use-scroll-restoration": { useScrollRestoration: noop },
    "@/components/page-nav": { PageNav: ({ title, fallback }) => React.createElement("nav", null, title, JSON.stringify(fallback)) },
    "@/components/library-filter-bar": { WallSortControl: ({ options, direction }) => React.createElement("span", null, JSON.stringify(options), direction.label) },
    "@/components/poster-wall": { PosterWall: ({ items, libraryIdOf }) => React.createElement("div", null, JSON.stringify(items.map((item) => [item.media_item_id, libraryIdOf(item)]))) },
    "@/components/wall-chrome": { WallLoadMore: () => null },
  };
  const source = readFileSync(new URL("../components/kind-wall-view.tsx", import.meta.url), "utf8") + "\nexport {sortOptions};";
  const exports = {};
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.ReactJSX } }).outputText, { exports, require: (key) => imports[key] ?? {} });
  return exports;
}
const render = (component, props) => renderToStaticMarkup(React.createElement(component, props));
const addition = { season_count: 1, episode_count: 3, season_number: 2, first_episode_number: 1, last_episode_number: 3, complete_season: true };

test("kind-wall labels change while sorting options and library ownership keep their raw identities", () => {
  const items = [{ media_item_id: 41, library_id: 17 }];
  const before = JSON.stringify(items);
  for (const kind of ["movie", "tv", "video"]) {
    const en = load("en", [items, 1, 2, false]);
    const zh = load("zh-Hans", [items, 1, 2, false]);
    assert.deepEqual([...en.sortOptions(kind, "en")].map(([id]) => id), [...zh.sortOptions(kind, "zh-Hans")].map(([id]) => id));
    const html = render(en.KindWallView, { kind });
    assert.doesNotMatch(html, /[\u3400-\u9fff]/);
    assert.match(html, /1 title · 2 libraries, with each title counted once/);
    assert.match(html, /\[\[41,17\]\]/);
    assert.doesNotMatch(render(load("en").KindWallView, { kind }), /[\u3400-\u9fff]/);
  }
  assert.match(render(load("en", [items, 1, 2, false]).KindWallView, { kind: "movie", genre: 878 }), /Science Fiction/);
  assert.match(render(load("en").KindWallView, { kind: "movie", genre: 999999 }), /Genre 999999/);
  assert.equal(JSON.stringify(items), before);
  assert.deepEqual(Object.keys(genreLabels.genreLabels("en")), Object.keys(genreLabels.GENRE_LABELS));
  assert.equal(Object.keys(genreLabels.genreLabels("en")).length, 27);
  assert.doesNotMatch(Object.values(genreLabels.genreLabels("en")).join(" "), /[\u3400-\u9fff]/);
});

test("recent additions and favorites translate summaries while exact episode ranges stay neutral", () => {
  const before = JSON.stringify(addition);
  assert.equal(formatRecentAddition(addition, "en"), "Season 2 · All 3 episodes");
  assert.equal(formatRecentAddition({ ...addition, season_number: 0 }, "en"), "Specials · All 3 episodes");
  assert.equal(formatRecentAddition({ ...addition, complete_season: false }, "en"), "S02E01–03");
  assert.equal(formatRecentAddition({ ...addition, season_count: 2 }, "en"), "Added 2 seasons · 3 episodes");
  assert.equal(formatRecentAddition({ ...addition, complete_season: false, first_episode_number: null, last_episode_number: null }, "en"), "S02 · 3 new episodes");
  assert.deepEqual(buildRecentAdditionOverlay("tv", addition, "Added just now", "en"), { primary: "Season 2 · All 3 episodes", secondary: "Added just now" });
  assert.equal(favoriteLevelLabel("tv", 2, 3, "en"), "Favorited S02E03");
  assert.equal(favoriteLevelLabel("tv", 2, null, "en"), "Favorited Season 2");
  assert.equal(favoriteLevelLabel("tv", 0, null, "en"), "Favorited specials");
  assert.equal(favoriteLevelLabel("movie", 0, 0, "en"), null);
  assert.equal(JSON.stringify(addition), before);
});

test("genre counts use raw kind tokens and correct English singular forms", () => {
  const t=appTranslator("en");
  assert.equal(t("library.genreTile.count",{kind:"movie",count:1}),"1 movie");
  assert.equal(t("library.genreTile.count",{kind:"tv",count:2}),"2 series");
  assert.equal(t("library.kindWall.genreSummary",{kind:"video",count:1,libraries:2}),"1 other video · 2 libraries");
});
