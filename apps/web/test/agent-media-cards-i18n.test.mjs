import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import React from "react";
import * as jsx from "react/jsx-runtime";
import { renderToStaticMarkup } from "react-dom/server";
import ts from "typescript";
import { appTranslator } from "../lib/i18n/translate.ts";
import * as subscriptionUi from "../lib/subscription-ui.ts";
import * as mediaCards from "../lib/agent-media-cards.ts";
import { formatBytes } from "../lib/format.ts";

const noop = () => {};
const icon = () => null;
function load(locale, hooks = {}) {
  const imports = {
    "react/jsx-runtime": jsx,
    "react": { ...React, ...hooks },
    "next-intl": { useLocale: () => locale, useTranslations: () => appTranslator(locale) },
    "next/link": { default: ({ children, scroll, ...props }) => React.createElement("a", props, children) },
    "next/navigation": { usePathname: () => "/sessions/raw-id" },
    "@/components/icons": { FilmIcon: icon, PhotoIcon: icon, PlayIcon: icon, TvIcon: icon, VideoIcon: icon },
    "@/components/h-scroller": { HScroller: ({ children }) => React.createElement("div", null, children) },
    "@/components/poster-card": { PosterCardVisual: ({ item, href }) => React.createElement("a", { href }, item.title, item.ribbon, JSON.stringify(item.posterFooter)) },
    "@/components/poster-image": { PosterImage: ({ fallback, zoom, ...props }) => React.createElement("img", props) },
    "@/components/subscribe-entry": { useSubscribeEntry: () => ({ subscriptionOf: () => true }) },
    "@/lib/subscription-ui": subscriptionUi,
    "@/lib/agent-media-cards": mediaCards,
    "@/lib/i18n/translate": { appTranslator },
    "@/lib/format": { formatBytes },
    "@/lib/api/libraries": { libraryCoverUrl: (id) => `/covers/${id}` },
    "@/lib/image-proxy": { imageUrl: (url) => url, responsiveImage: (src) => ({ src }) },
    "@/lib/player/play-links": { playHref: (id, unit) => `/play/${id}${unit ? `?season=${unit.season}&episode=${unit.episode}` : ""}`, rememberPlayerReturnPath: noop },
    "@/lib/use-tap-guard": { useTapGuard: () => ({}) },
  };
  const path = "../components/agent-media-cards.tsx";
  const source = readFileSync(new URL(path, import.meta.url), "utf8") + "\nexport { LibraryMiniCardBody, LibraryItemPlayCardBody, TitlePosterCardBody, SubscriptionPosterCardBody, PosterFill, CardPlaceholder, specLine, useCardData, toolFailed };";
  const exports = {};
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.ReactJSX } }).outputText, { exports, require: (key) => imports[key] ?? {} });
  return exports;
}
const render = (component, props) => renderToStaticMarkup(React.createElement(component, props));
const library = { id: 17, name: "作者媒体库", kind: "movie", stats: { item_count: 2, total_size_bytes: 1024 }, is_default: true };
const detail = { file_count: 2, total_size_bytes: 2048, files: [{ resolution: "2160p", hdr: "HDR10" }, { resolution: "2160p" }] };
const data = { info: { title: "作者电影", kind: "tv", year: 2024, library_id: 17, media_item_id: 29, poster_url: null }, detail, watch: { position_ms: 2500, duration_ms: 10000, played: true } };
const spec = { kind: "library_item", key: "raw-key", mediaItemId: 29, seasonNumber: 1, episodeNumber: 3 };

test("media cards translate display text while names, specs, links and playback decisions retain source facts", () => {
  const en = load("en");
  const before = JSON.stringify({ library, data, spec });
  const lib = render(en.LibraryMiniCardBody, { library });
  assert.match(lib, /Open library “作者媒体库”, Movie · 2 titles · 1.00 KB/);
  assert.match(lib, /href="\/library\/17"/);
  for (const [watch, verb] of [[data.watch, "Resume"], [{ position_ms: 0, played: true }, "Play again"], [null, "Play"]]) {
    const html = render(en.LibraryItemPlayCardBody, { data: { ...data, watch }, spec });
    assert.match(html, new RegExp(`${verb} “作者电影” S01E03`));
    assert.match(html, /href="\/play\/29\?season=1&amp;episode=3"/);
    assert.match(html, /2160p · HDR10 · 2 files · 2.00 KB/);
    assert.doesNotMatch(html.replaceAll("作者电影", "Author title"), /[\u3400-\u9fff]/);
  }
  assert.match(render(en.CardPlaceholder, { failed: true, className: "box" }), /Not found/);
  assert.equal(en.specLine(null, "en"), "");
  assert.equal(en.specLine(detail, "zh-Hans"), "2160p · HDR10 · 2 个文件 · 2.00 KB");
  assert.equal(JSON.stringify({ library, data, spec }), before);
});

test("locale is a card fetch dependency and stale responses cannot replace the latest reader data", async () => {
  const effects = [], states = [];
  const hooks = { useState: (initial) => [initial, (state) => states.push(state)], useEffect: (effect, deps) => effects.push({ effect, deps }) };
  let resolveOld;
  const old = load("en", hooks);
  old.useCardData("library:17", () => new Promise((resolve) => { resolveOld = resolve; }));
  assert.deepEqual([...effects[0].deps], ["library:17", "en"]);
  const cancel = effects[0].effect();
  cancel();
  load("zh-Hans", hooks).useCardData("library:17", async () => "当前读者数据");
  assert.deepEqual([...effects[1].deps], ["library:17", "zh-Hans"]);
  effects[1].effect();
  await new Promise((resolve) => setImmediate(resolve));
  resolveOld("stale data");
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(states.at(-1).data, "当前读者数据");
  assert.equal(states.filter((state) => state.status === "ready").length, 1);
  assert.equal(old.toolFailed({ isError: true, output: "external failure" }), true);
  assert.equal(old.toolFailed({ output: "工具执行失败：旧历史记录" }), true);
  assert.equal(old.toolFailed({ output: "工具回执原文" }), false);
});
