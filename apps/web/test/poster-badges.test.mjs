import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import React from "react";
import * as jsx from "react/jsx-runtime";
import { renderToStaticMarkup } from "react-dom/server";
import ts from "typescript";

import { appTranslator } from "../lib/i18n/translate.ts";
import * as badges from "../lib/poster-badges.ts";
import * as wallBadges from "../lib/wall-badges.ts";

const {
  DEFAULT_POSTER_BADGES,
  POSTER_BADGE_TOGGLES,
  bestResolutionLabel,
  detailAirStatus,
  dynamicRangeLabel,
  hasAnyBadge,
  hasTopBadges,
  normalizePosterBadges,
  posterBadges,
} = badges;

const ALL_ON = {
  ...DEFAULT_POSTER_BADGES,
  ...Object.fromEntries(POSTER_BADGE_TOGGLES.map((key) => [key, true])),
};

const show = {
  kind: "tv",
  rating: 8.26,
  year: 2021,
  resolutions: ["1080p", "2160p", "720p"],
  air_status: "ended",
  dynamic_range: "Dolby Vision",
  has_atmos: true,
  has_chinese_subtitle: true,
  progress_percent: 42,
  unplayed_count: 3,
};
const movie = { ...show, kind: "movie", air_status: null, unplayed_count: null };

test("defaults are all off: a fresh user's poster looks exactly like before", () => {
  for (const key of [...POSTER_BADGE_TOGGLES, "hover_only"]) {
    assert.equal(DEFAULT_POSTER_BADGES[key], false, key);
  }
  assert.equal(DEFAULT_POSTER_BADGES.min_rating, 0);
  const set = posterBadges(show, DEFAULT_POSTER_BADGES);
  assert.equal(hasAnyBadge(set), false);
  assert.equal(detailAirStatus("tv", "ended", DEFAULT_POSTER_BADGES), null);
});

test("normalize fills missing groups and fields, drops wrong types, clamps the threshold", () => {
  assert.deepEqual(normalizePosterBadges(undefined), DEFAULT_POSTER_BADGES);
  assert.deepEqual(normalizePosterBadges(null), DEFAULT_POSTER_BADGES);
  assert.deepEqual(normalizePosterBadges({ rating: true, year: "yes", min_rating: 99 }), {
    ...DEFAULT_POSTER_BADGES,
    rating: true,
    min_rating: 10,
  });
  assert.equal(normalizePosterBadges({ min_rating: -3 }).min_rating, 0);
  assert.equal(normalizePosterBadges({ min_rating: Number.NaN }).min_rating, 0);
  assert.equal(normalizePosterBadges({ hover_only: true }).hover_only, true);
});

test("each toggle drives exactly its own badge", () => {
  const full = posterBadges(show, ALL_ON);
  assert.deepEqual(full, {
    rating: 8.26,
    year: 2021,
    status: "ended",
    resolution: "4K",
    formats: ["DV", "Atmos"],
    chineseSubtitle: true,
    progress: 42,
    unwatched: "3",
  });
  const off = (key) => posterBadges(show, { ...ALL_ON, [key]: false });
  assert.equal(off("rating").rating, null);
  assert.equal(off("year").year, null);
  assert.equal(off("ended").status, null);
  assert.equal(off("resolution").resolution, null);
  assert.deepEqual(off("format").formats, []);
  assert.equal(off("chinese_subtitle").chineseSubtitle, false);
  assert.equal(off("progress").progress, null);
  assert.equal(off("unwatched").unwatched, null);
  // 其余角标不受影响
  assert.equal(off("rating").resolution, "4K");
});

test("rating respects the minimum and hides missing / zero ratings", () => {
  assert.equal(posterBadges({ ...show, rating: 6.4 }, { ...ALL_ON, min_rating: 6.5 }).rating, null);
  assert.equal(posterBadges({ ...show, rating: 6.5 }, { ...ALL_ON, min_rating: 6.5 }).rating, 6.5);
  assert.equal(posterBadges({ ...show, rating: null }, ALL_ON).rating, null);
  assert.equal(posterBadges({ ...show, rating: 0 }, ALL_ON).rating, null);
});

test("series-only badges never show on movies; airing needs its own toggle", () => {
  const set = posterBadges(movie, ALL_ON);
  assert.equal(set.status, null);
  assert.equal(set.unwatched, null);
  assert.equal(set.progress, 42, "movies still get a progress bar");
  const airing = { ...show, air_status: "airing" };
  assert.equal(posterBadges(airing, ALL_ON).status, "airing");
  assert.equal(posterBadges(airing, { ...ALL_ON, airing: false }).status, null);
  assert.equal(posterBadges(airing, { ...ALL_ON, ended: false }).status, "airing");
});

test("unwatched count: zero hides, large counts cap at 99+", () => {
  assert.equal(posterBadges({ ...show, unplayed_count: 0 }, ALL_ON).unwatched, null);
  assert.equal(posterBadges({ ...show, unplayed_count: 120 }, ALL_ON).unwatched, "99+");
  assert.equal(posterBadges({ ...show, unplayed_count: null }, ALL_ON).unwatched, null);
});

test("old servers without the new fields simply show nothing for them", () => {
  const legacy = { kind: "tv", rating: 7, year: 2020, resolutions: [], air_status: "ended" };
  const set = posterBadges(legacy, ALL_ON);
  assert.deepEqual(set.formats, []);
  assert.equal(set.chineseSubtitle, false);
  assert.equal(set.progress, null);
  assert.equal(set.unwatched, null);
  assert.equal(set.resolution, null);
  assert.equal(hasTopBadges(set), true);
});

test("labels: best resolution and short dynamic-range names", () => {
  assert.equal(bestResolutionLabel(["720p", "1080p"]), "1080p");
  assert.equal(bestResolutionLabel(["2160p", "1080p"]), "4K");
  assert.equal(bestResolutionLabel(["4320p"]), "8K");
  assert.equal(bestResolutionLabel([]), null);
  assert.equal(dynamicRangeLabel("Dolby Vision"), "DV");
  assert.equal(dynamicRangeLabel("HDR10+"), "HDR10+");
  assert.equal(dynamicRangeLabel("Weird"), "Weird");
  assert.equal(dynamicRangeLabel(null), null);
});

test("detail page status follows either status toggle", () => {
  assert.equal(detailAirStatus("tv", "airing", { ...DEFAULT_POSTER_BADGES, ended: true }), "airing");
  assert.equal(detailAirStatus("tv", "ended", { ...DEFAULT_POSTER_BADGES, airing: true }), "ended");
  assert.equal(detailAirStatus("movie", "ended", ALL_ON), null);
  assert.equal(detailAirStatus("tv", null, ALL_ON), null);
});

// —— 组件：真实源码转译后在沙箱里渲染（与其他 *-i18n 用例同一手法）——

function compile(path, dependencies) {
  const exports = {};
  const source = readFileSync(new URL(path, import.meta.url), "utf8");
  const output = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.ReactJSX },
  }).outputText;
  vm.runInNewContext(output, { exports, require: (key) => dependencies[key] ?? {} });
  return exports;
}

function loadComponents(locale, posterPrefs, onSave = () => Promise.resolve()) {
  const prefs = { poster_badges: posterPrefs };
  const common = {
    "react/jsx-runtime": jsx,
    react: { ...React, useState: (initial) => [initial, () => {}], useRef: (value) => ({ current: value }) },
    "next-intl": { useTranslations: () => appTranslator(locale) },
    "@/components/icons": new Proxy({}, { get: () => () => null }),
    "@/lib/poster-badges": badges,
    "@/lib/ui-prefs": { useUiPrefs: () => ({ prefs, savePrefs: onSave }) },
    // 与真实 SheetToggleRow 同一读屏契约：整行一个 role=switch 按钮
    "@/components/sheet-scaffold": {
      SheetToggleRow: ({ label, checked, onChange }) =>
        React.createElement("button", { role: "switch", "aria-checked": checked, onClick: () => onChange(!checked) }, label),
    },
  };
  return {
    settings: compile("../components/poster-badge-settings.tsx", common),
    overlay: compile("../components/poster-badges.tsx", common),
  };
}

test("settings panel lists one labelled switch per badge in both languages", () => {
  for (const [locale, title, hanAllowed] of [["en", "Poster badges", false], ["zh-Hans", "海报角标", true]]) {
    const { settings } = loadComponents(locale, { ...DEFAULT_POSTER_BADGES, rating: true });
    const html = renderToStaticMarkup(React.createElement(settings.PosterBadgeSettings));
    assert.match(html, new RegExp(title));
    if (!hanAllowed) assert.doesNotMatch(html, /[㐀-鿿]/);
    assert.equal((html.match(/role="switch"/g) ?? []).length, POSTER_BADGE_TOGGLES.length);
    assert.equal((html.match(/aria-checked="true"/g) ?? []).length, 2, "rating switch + 'always' radio");
    assert.match(html, /role="radiogroup"/);
    assert.equal((html.match(/role="radio"/g) ?? []).length, 2);
    assert.match(html, /<select/);
  }
  const en = renderToStaticMarkup(
    React.createElement(loadComponents("en", DEFAULT_POSTER_BADGES).settings.PosterBadgeSettings),
  );
  assert.match(en, /<select[^>]*disabled/, "threshold is disabled while the rating badge is off");
});

test("toggling a switch saves the whole preferences object with only that badge flipped", async () => {
  const saved = [];
  const { settings } = loadComponents("en", DEFAULT_POSTER_BADGES, (next) => {
    saved.push(next);
    return Promise.resolve();
  });
  const tree = settings.PosterBadgeSettings();
  const switches = [];
  const walk = (node) => {
    if (!node || typeof node !== "object") return;
    if (Array.isArray(node)) return node.forEach(walk);
    if (typeof node.type === "function" && node.props?.onChange && "checked" in node.props) switches.push(node.props);
    walk(node.props?.children);
  };
  walk(tree);
  assert.equal(switches.length, POSTER_BADGE_TOGGLES.length);
  switches[POSTER_BADGE_TOGGLES.indexOf("unwatched")].onChange(true);
  assert.equal(saved.length, 1);
  // 沙箱里造的对象原型不同，按值比
  assert.deepEqual(JSON.parse(JSON.stringify(saved[0].poster_badges)), { ...DEFAULT_POSTER_BADGES, unwatched: true });
});

test("overlay renders the enabled badges with localized marks and keeps the heart", () => {
  for (const [locale, ended, mark] of [["en", "Ended", "ZH"], ["zh-Hans", "完结", "中"]]) {
    const { overlay } = loadComponents(locale, ALL_ON);
    const set = posterBadges(show, ALL_ON);
    const html = renderToStaticMarkup(
      React.createElement(overlay.PosterBadgeOverlay, { set, favorite: true, yieldBottom: true }),
    );
    for (const badge of ["rating", "year", "status", "resolution", "format", "chinese-subtitle", "unwatched", "progress"]) {
      assert.match(html, new RegExp(`data-badge="${badge}"`), badge);
    }
    assert.match(html, new RegExp(`>${ended}<`));
    assert.match(html, new RegExp(`>${mark}<`));
    assert.match(html, />8\.3</);
    assert.match(html, /width:42%/);
    assert.match(html, /aria-hidden="true"/);
    // 底部标记在 hover 信息层升起时让位
    assert.match(html, /data-badge="unwatched"[^>]*group-hover\/card:opacity-0/);
  }
});

test("hover-only mode hides only the top badges until hover / focus", () => {
  const { overlay } = loadComponents("en", { ...ALL_ON, hover_only: true });
  const html = renderToStaticMarkup(
    React.createElement(overlay.PosterBadgeOverlay, {
      set: posterBadges(show, ALL_ON),
      favorite: false,
      yieldBottom: false,
    }),
  );
  assert.match(html, /data-badge="rating"[^>]*opacity-0[^>]*group-hover\/card:opacity-100/);
  assert.match(html, /data-badge="resolution"[^>]*group-focus-visible\/card:opacity-100/);
  assert.doesNotMatch(html, /data-badge="unwatched"[^>]*opacity-0/);
});

test("accessible descriptions read every visible badge in the reader's language", () => {
  const { overlay } = loadComponents("en", ALL_ON);
  // 钩子里只用 useTranslations：直接当函数调
  const text = overlay.usePosterBadgeDescriptions(posterBadges(show, ALL_ON)).join(" | ");
  assert.equal(
    text,
    "Rating 8.3 | Ended | 4K | DV | Atmos | Chinese subtitles available | 3 unwatched episodes | 42% watched",
  );
  assert.equal(overlay.usePosterBadgeDescriptions(null).length, 0);
});

// —— 按需请求：开着哪些角标 → 墙请求点名哪些分组（服务端只跑这几份查询）——

test("badge request names only the server-computed groups of enabled badges", () => {
  const { posterBadgeRequest } = badges;
  // 全关（默认）：不点名任何分组，墙请求与没有角标时一模一样
  assert.equal(posterBadgeRequest(DEFAULT_POSTER_BADGES), "");
  // 评分 / 年份 / 分辨率 / 播出状态 / 仅悬停：墙本来就带，不需要服务端多算
  assert.equal(
    posterBadgeRequest({
      ...DEFAULT_POSTER_BADGES,
      rating: true,
      year: true,
      resolution: true,
      ended: true,
      airing: true,
      hover_only: true,
      min_rating: 7,
    }),
    "",
  );
  assert.equal(posterBadgeRequest({ ...DEFAULT_POSTER_BADGES, format: true }), "atmos,hdr");
  assert.equal(posterBadgeRequest({ ...DEFAULT_POSTER_BADGES, chinese_subtitle: true }), "zh");
  assert.equal(posterBadgeRequest({ ...DEFAULT_POSTER_BADGES, progress: true }), "progress");
  assert.equal(posterBadgeRequest({ ...DEFAULT_POSTER_BADGES, unwatched: true }), "unwatched");
  // 全开：五个分组，排好序（同一组开关永远是同一个串，缓存键稳定）
  assert.equal(posterBadgeRequest(ALL_ON), "atmos,hdr,progress,unwatched,zh");
});

test("walls refetch only when a badge group is added, not when one is removed", () => {
  const { addsBadgeGroups } = badges;
  assert.equal(addsBadgeGroups("", ""), false);
  assert.equal(addsBadgeGroups("", "zh"), true);
  assert.equal(addsBadgeGroups("progress", "progress,zh"), true);
  assert.equal(addsBadgeGroups("atmos,hdr,zh", "zh"), false);
  assert.equal(addsBadgeGroups("zh", ""), false);
  assert.equal(addsBadgeGroups("atmos,hdr", "atmos,hdr"), false);
});

test("wall requests carry badges only when some group is requested", () => {
  const { setWallBadgeRequest, wallBadgeRequest, appendWallBadges } = wallBadges;
  try {
    setWallBadgeRequest("");
    assert.equal(appendWallBadges(new URLSearchParams("limit=60")).toString(), "limit=60");
    setWallBadgeRequest("progress,zh");
    assert.equal(wallBadgeRequest(), "progress,zh");
    assert.equal(
      appendWallBadges(new URLSearchParams("limit=60")).toString(),
      "limit=60&badges=progress%2Czh",
    );
  } finally {
    setWallBadgeRequest("");
  }
});

test("null badge data (not requested / older server) draws nothing", () => {
  const unknown = { ...show, has_atmos: null, has_chinese_subtitle: null, progress_percent: null, unplayed_count: null, dynamic_range: null };
  const set = posterBadges(unknown, { ...DEFAULT_POSTER_BADGES, format: true, chinese_subtitle: true, progress: true, unwatched: true });
  assert.deepEqual(set.formats, []);
  assert.equal(set.chineseSubtitle, false);
  assert.equal(set.progress, null);
  assert.equal(set.unwatched, null);
  assert.equal(hasAnyBadge(set), false);
});
