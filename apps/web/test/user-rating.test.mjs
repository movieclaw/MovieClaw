import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import React from "react";
import * as jsx from "react/jsx-runtime";
import { renderToStaticMarkup } from "react-dom/server";
import ts from "typescript";

import { appTranslator } from "../lib/i18n/translate.ts";
import {
  buildHomeRows,
  moveRowTo,
  ratedSortPresets,
  rowMeta,
  rowTitle,
  rowsToPrefs,
} from "../lib/home-rows.ts";
import {
  filterCount,
  filterKey,
  filterQuery,
  filterToRules,
  isFilterEmpty,
  readLibraryFilter,
} from "../lib/library-filter.ts";
import * as badges from "../lib/poster-badges.ts";
import * as userRating from "../lib/user-rating.ts";
import * as wallBadges from "../lib/wall-badges.ts";

function compile(path, dependencies) {
  const exports = {};
  const source = readFileSync(new URL(path, import.meta.url), "utf8");
  const output = ts.transpileModule(source, {
    compilerOptions: {
      module: ts.ModuleKind.CommonJS,
      target: ts.ScriptTarget.ES2022,
      jsx: ts.JsxEmit.ReactJSX,
    },
  }).outputText;
  vm.runInNewContext(output, {
    exports,
    require: (key) => dependencies[key] ?? {},
    URLSearchParams,
  });
  return exports;
}

function loadStarRating(locale = "zh-Hans", hoverState = null) {
  let currentHover = hoverState;
  const setHoverCalls = [];
  const mod = compile("../components/star-rating.tsx", {
    "react/jsx-runtime": jsx,
    react: {
      ...React,
      useState: (initial) => [
        currentHover !== null ? currentHover : initial,
        (next) => {
          currentHover = next;
          setHoverCalls.push(next);
        },
      ],
    },
    "next-intl": { useTranslations: () => appTranslator(locale) },
    "@/components/icons": {
      StarIcon: (props) => React.createElement("svg", { "data-icon": "star", ...props }),
    },
    "@/lib/user-rating": userRating,
  });
  return { StarRating: mod.StarRating, setHoverCalls, getHover: () => currentHover };
}

function collectElements(node, predicate, out = []) {
  if (!node || typeof node !== "object") return out;
  if (Array.isArray(node)) {
    for (const item of node) collectElements(item, predicate, out);
    return out;
  }
  if (predicate(node)) out.push(node);
  collectElements(node.props?.children, predicate, out);
  return out;
}

// ---------------------------------------------------------------------------
// 1. 详情页 5 星半星控件：渲染、悬停预览、点击设置、清除、半星、季/集禁用
// ---------------------------------------------------------------------------

test("user-rating pure helpers: scale conversion, half-star fill, click toggle & target guard", () => {
  assert.equal(userRating.ratingToStars(null), null);
  assert.equal(userRating.ratingToStars(0), null);
  assert.equal(userRating.ratingToStars(1), 0.5);
  assert.equal(userRating.ratingToStars(9), 4.5);
  assert.equal(userRating.ratingToStars(10), 5);
  assert.equal(userRating.formatStarRating(9), "4.5");
  assert.equal(userRating.formatStarRating(8), "4.0");
  assert.equal(userRating.formatStarShort(8), "4");
  assert.equal(userRating.formatStarShort(9), "4.5");
  assert.equal(userRating.formatMyRatingThreshold(10), "5★");
  assert.equal(userRating.formatMyRatingThreshold(9), "≥ 4.5★");
  assert.equal(userRating.formatMyRatingThreshold(8), "≥ 4★");

  assert.equal(userRating.starValueFromRatio(1, 0.2), 1);
  assert.equal(userRating.starValueFromRatio(1, 0.8), 2);
  assert.equal(userRating.starValueFromRatio(5, 0.49), 9);
  assert.equal(userRating.starValueFromRatio(5, 0.5), 10);

  // 点击新分设置、再次点击当前分返回 0（清除）
  assert.equal(userRating.nextRatingOnClick(null, 9), 9);
  assert.equal(userRating.nextRatingOnClick(9, 7), 7);
  assert.equal(userRating.nextRatingOnClick(9, 9), 0);

  // 仅电影与整剧可评；季/集与非影视类型不可评
  assert.equal(userRating.canRateTarget({ kind: "movie" }), true);
  assert.equal(userRating.canRateTarget({ kind: "tv" }), true);
  assert.equal(userRating.canRateTarget({ kind: "tv", seasonNumber: 1 }), false);
  assert.equal(userRating.canRateTarget({ kind: "tv", seasonNumber: 1, episodeNumber: 2 }), false);
  assert.equal(userRating.canRateTarget({ kind: "video" }), false);
  assert.equal(userRating.canRateTarget({ kind: "photo" }), false);
});

test("StarRating renders unrated, full-star, and half-star states and hides for season/episode", () => {
  const { StarRating } = loadStarRating("zh-Hans");

  // 未评分：5 颗空星、无清除按钮
  const unratedHtml = renderToStaticMarkup(
    React.createElement(StarRating, { value: null, onChange: () => {} }),
  );
  assert.match(unratedHtml, /data-testid="star-rating"/);
  assert.equal((unratedHtml.match(/data-star-fill="empty"/g) ?? []).length, 5);
  assert.doesNotMatch(unratedHtml, /data-testid="star-rating-clear"/);

  // 半星评分（9 = 4.5★）：4 颗实心 + 1 颗半星 + 数值 4.5 + 清除按钮
  const halfHtml = renderToStaticMarkup(
    React.createElement(StarRating, { value: 9, kind: "movie", onChange: () => {} }),
  );
  assert.equal((halfHtml.match(/data-star-fill="full"/g) ?? []).length, 4);
  assert.equal((halfHtml.match(/data-star-fill="half"/g) ?? []).length, 1);
  assert.equal((halfHtml.match(/data-star-fill="empty"/g) ?? []).length, 0);
  assert.match(halfHtml, /data-testid="star-rating-value"[^>]*>4\.5</);
  assert.match(halfHtml, /data-testid="star-rating-clear"/);

  // 整星评分（6 = 3.0★）：3 颗实心 + 2 颗空星
  const fullHtml = renderToStaticMarkup(
    React.createElement(StarRating, { value: 6, kind: "tv", onChange: () => {} }),
  );
  assert.equal((fullHtml.match(/data-star-fill="full"/g) ?? []).length, 3);
  assert.equal((fullHtml.match(/data-star-fill="empty"/g) ?? []).length, 2);
  assert.match(fullHtml, /data-testid="star-rating-value"[^>]*>3\.0</);

  // 季 / 集 / 本地视频：不渲染
  assert.equal(
    renderToStaticMarkup(
      React.createElement(StarRating, { value: 8, kind: "tv", seasonNumber: 1, onChange: () => {} }),
    ),
    "",
  );
  assert.equal(
    renderToStaticMarkup(
      React.createElement(StarRating, {
        value: 8,
        kind: "tv",
        seasonNumber: 1,
        episodeNumber: 3,
        onChange: () => {},
      }),
    ),
    "",
  );
  assert.equal(
    renderToStaticMarkup(
      React.createElement(StarRating, { value: null, kind: "video", onChange: () => {} }),
    ),
    "",
  );
});

test("StarRating interactions: hover preview, click to set half-star, click current to clear, clear button", () => {
  const changes = [];
  const { StarRating, setHoverCalls } = loadStarRating("zh-Hans");
  const tree = StarRating({
    value: 9,
    kind: "movie",
    onChange: (next) => changes.push(next),
  });

  // 10 个半星热区按钮（1..10）
  const ratingButtons = collectElements(
    tree,
    (el) => el.type === "button" && typeof el.props?.["data-rating-value"] === "number",
  );
  assert.equal(ratingButtons.length, 10);

  // 悬停第 4 颗星左半（7 = 3.5★）触发预览态
  const btn7 = ratingButtons.find((b) => b.props["data-rating-value"] === 7);
  btn7.props.onMouseEnter();
  assert.deepEqual(setHoverCalls, [7]);

  // 悬停态渲染预览（3 实 + 1 半 + 1 空，显示 3.5）
  const preview = loadStarRating("zh-Hans", 7);
  const previewHtml = renderToStaticMarkup(
    React.createElement(preview.StarRating, { value: 9, onChange: () => {} }),
  );
  assert.equal((previewHtml.match(/data-star-fill="full"/g) ?? []).length, 3);
  assert.equal((previewHtml.match(/data-star-fill="half"/g) ?? []).length, 1);
  assert.match(previewHtml, /data-testid="star-rating-value"[^>]*>3\.5</);

  // 点击 7（3.5★）提交 7
  btn7.props.onClick();
  // 点击当前值 9（4.5★）提交 0（清除）
  const btn9 = ratingButtons.find((b) => b.props["data-rating-value"] === 9);
  btn9.props.onClick();
  // 点击「清除」按钮提交 0
  const clearButton = collectElements(
    tree,
    (el) => el.type === "button" && el.props?.["data-testid"] === "star-rating-clear",
  )[0];
  assert.ok(clearButton);
  clearButton.props.onClick();

  assert.deepEqual(changes, [7, 0, 0]);
});

// ---------------------------------------------------------------------------
// 2. 媒体库排序与筛选参数传递（sort=my_rating / w=rated / my_rating_gte）
// ---------------------------------------------------------------------------

test("library sort includes my_rating with desc natural direction and localized labels", () => {
  const wallSort = compile("../lib/wall-sort.ts", {
    react: React,
    "./i18n/translate.ts": { appTranslator },
  });
  assert.equal(wallSort.PREF_TO_SORT.my_rating, "my_rating");
  assert.equal(wallSort.sortPrefLabels("zh-Hans").my_rating, "我的评分");
  assert.equal(wallSort.sortPrefLabels("en").my_rating, "My rating");
  assert.equal(wallSort.sortPrefLabels("de").my_rating, "Meine Bewertung");
  assert.equal(wallSort.sortDirections("zh-Hans").my_rating.naturalAsc, false);
});

test("library filter passes w=rated and my_rating_gte and round-trips through URL query", () => {
  const filter = { watch: "rated", myRatingGte: 8 };
  const query = new URLSearchParams();
  filterQuery(filter, query);
  assert.equal(query.get("w"), "rated");
  assert.equal(query.get("my_rating_gte"), "8");
  assert.equal(isFilterEmpty(filter), false);
  assert.equal(isFilterEmpty({ myRatingGte: 9 }), false);
  assert.equal(filterCount(filter), 2);
  assert.notEqual(filterKey({ myRatingGte: 8 }), filterKey({ myRatingGte: 9 }));

  const parsed = readLibraryFilter(query);
  assert.equal(parsed.watch, "rated");
  assert.equal(parsed.myRatingGte, 8);

  // 合集规则不含个人评分门槛，不写进 rules
  const rules = filterToRules(filter);
  assert.equal(rules.some((r) => r.field === "my_rating_gte"), false);
});

// ---------------------------------------------------------------------------
// 3. 首页内置行 rated：默认布局、排序预设、隐藏/调序持久化、无数据时整行隐藏
// ---------------------------------------------------------------------------

test("home rated row: defaults, sort presets, hide & reorder persistence", () => {
  const libs = [{ id: 1, name: "电影", kind: "movie", viewer_access: true, exclude_from_home: false }];
  const defaults = buildHomeRows({ rows: [] }, libs, []);
  const rated = defaults.find((r) => r.id === "rated");
  assert.ok(rated);
  assert.equal(rated.kind, "rated");
  assert.equal(rated.hidden, false);
  assert.equal(rated.sort, "my_rating");
  assert.equal(rated.reversed, false);
  assert.equal(rowTitle(rated, "zh-Hans"), "我的高分作品");
  assert.equal(rowTitle(rated, "en"), "My top rated");
  assert.equal(rowTitle(rated, "de"), "Meine Bestbewerteten");
  assert.equal(rowMeta(rated), "内置 · 我的评分");
  assert.deepEqual(Object.keys(ratedSortPresets("zh-Hans")), ["my_rating", "rated_at"]);

  // 隐藏 + 切换排序到「最近评分」并反转 + 调序到首位，完整往返持久化
  const reordered = moveRowTo(
    defaults.map((r) =>
      r.id === "rated" ? { ...r, hidden: true, sort: "rated_at", reversed: true } : r,
    ),
    defaults.findIndex((r) => r.id === "rated"),
    0,
  );
  const prefs = rowsToPrefs(reordered);
  assert.deepEqual(prefs[0], { id: "rated", hidden: true, sort: "rated_at", order: "asc" });

  const restored = buildHomeRows({ rows: prefs }, libs, []);
  assert.equal(restored[0].id, "rated");
  assert.equal(restored[0].hidden, true);
  assert.equal(restored[0].sort, "rated_at");
  assert.equal(restored[0].reversed, true);
  assert.equal(rowMeta(restored[0]), "内置 · 最早评分");

  // 非法排序档回落到 my_rating
  const fallback = buildHomeRows({ rows: [{ id: "rated", sort: "random" }] }, libs, []);
  assert.equal(fallback[0].sort, "my_rating");
});

test("listRated passes sort / order / min_rating / badges query params", async () => {
  const requested = [];
  const playback = compile("../lib/api/playback.ts", {
    "@/lib/i18n/translate": { appTranslator },
    "@/lib/env": { publicEnv: { apiBaseUrl: "/api/v1" } },
    "@/lib/player/device": { getPlayerDeviceId: () => "dev-1" },
    "@/lib/http": {
      HttpError: class HttpError extends Error {},
      resolveRequestUrl: (p) => p,
      request: async (url) => {
        requested.push(url);
        return { success: true, code: "OK", message: "", data: { items: [], total: 0 } };
      },
    },
    "@/lib/wall-badges": wallBadges,
    "@/lib/player/local-progress": {},
  });

  try {
    wallBadges.setWallBadgeRequest("my_rating");
    await playback.listRated(20, 0);
    await playback.listRated(12, 4, { minRating: 6, sort: "rated_at", order: "asc" });
    assert.equal(requested[0], "/playback/rated?limit=20&offset=0&badges=my_rating");
    assert.equal(
      requested[1],
      "/playback/rated?limit=12&offset=4&min_rating=6&sort=rated_at&order=asc&badges=my_rating",
    );
  } finally {
    wallBadges.setWallBadgeRequest("");
  }
});

test("LibraryView hides rated row completely when rated items are empty and shows it when present", () => {
  const renderHomeWithRated = (ratedItems) => {
    const stateValues = [
      null, // floorHost
      [{ id: 1, name: "电影", kind: "movie", viewer_access: true, exclude_from_home: false, stats: { item_count: 1, file_count: 1, total_size_bytes: 0, unidentified_count: 0, missing_count: 0, ignored_count: 0 }, root_paths: [], match_rules: [], scanning: false, scan_progress: null, last_scan: null, organizing: false, organize_progress: null, last_organize: null, metadata_refresh: null, chapter_job: null }], // libraries
      [], // collections
      new Map(), // itemsByKey
      new Map(), // genresByKind
      [], // upNext
      { items: [], total: 0 }, // favorites
      { items: ratedItems, total: ratedItems.length }, // rated
      false, // failed
      false, // recentlyBusy
    ];
    let stateIdx = 0;
    const mod = compile("../components/library-view.tsx", {
      "react/jsx-runtime": jsx,
      react: {
        ...React,
        useState: (initial) => {
          const val = stateIdx < stateValues.length ? stateValues[stateIdx++] : (typeof initial === "function" ? initial() : initial);
          return [val, () => {}];
        },
        useEffect: () => {},
        useCallback: (fn) => fn,
        useMemo: (fn) => fn(),
        useRef: (v) => ({ current: v }),
      },
      "next-intl": { useLocale: () => "zh-Hans", useTranslations: () => appTranslator("zh-Hans") },
      "next/link": { default: ({ href, children, ...rest }) => React.createElement("a", { href, ...rest }, children) },
      "next/navigation": { useRouter: () => ({ push: () => {} }) },
      "@/lib/i18n/translate": { appTranslator },
      "@/components/brand-loader": { BrandLoader: () => null },
      "@/components/content-empty-state": { ContentEmptyState: () => null },
      "@/components/collection-library-card": { CollectionLibraryCard: () => null, ShelfCardCaption: () => null },
      "@/components/genre-tile": { GenreTile: () => null },
      "@/components/h-scroller": { HScroller: ({ children }) => React.createElement("div", null, children) },
      "@/components/library-kind-meta": { libraryKindMeta: () => ({ movie: { label: "电影", Icon: () => null } }) },
      "@/components/icons": new Proxy({}, { get: () => () => null }),
      "@/components/media-row": {
        MediaRow: ({ row }) => React.createElement("section", { "data-media-row": row.id }, row.title),
      },
      "@/components/reel-clips-tip": { ReelClipsTip: () => null },
      "@/components/reels-floor": { ReelsFloor: () => null },
      "@/components/reels/reels-shelf-card": { ReelsShelfCard: () => null },
      "@/components/tip-card": { TipCard: () => null },
      "@/lib/tips/engine": { defineTip: (x) => x },
      "@/lib/tips/store": { invalidateTip: () => {} },
      "@/components/top-bar-menu": { TopBarMenu: () => null },
      "@/components/poster-badges": { useWallBadgesRefetch: () => {} },
      "@/components/up-next-row": { UpNextRow: () => null },
      "@/lib/api/libraries": { SCAN_PHASE_LABELS: {}, libraryCoverUrl: () => "" },
      "@/lib/api/collections": {},
      "@/lib/first-paint-deadline": {},
      "@/lib/api/playback": {},
      "@/lib/favorites": { favoriteLevelLabel: () => null },
      "@/lib/home-rows": {
        buildHomeRows,
        homeRowWatch: () => undefined,
        homeRowHref: () => "/library/1",
        homeCollectionIds: () => [],
        FAVORITES_SORT_PRESETS: {},
        RATED_SORT_PRESETS: ratedSortPresets("zh-Hans"),
        orderParamFor: () => undefined,
        rowTitle,
        SORT_PRESETS: {},
      },
      "@/lib/genre-labels": { genreLabels: () => ({}) },
      "@/lib/format": { formatBytes: () => "0 B" },
      "@/lib/image-proxy": { imageUrl: (u) => u ?? "", responsiveImage: () => ({}) },
      "@/lib/library-inventory-summary": { libraryInventoryAction: () => "none" },
      "@/lib/page-chrome": { usePageChrome: () => null },
      "@/lib/permissions": { usePermissions: () => ({ canManageLibraries: false }) },
      "@/lib/recent-addition": { buildRecentAdditionOverlay: () => undefined },
      "@/lib/time": { formatRelativeTime: () => "" },
      "@/lib/ui-prefs": {
        useLayout: () => "silver",
        useUiPrefs: () => ({ prefs: { home: { rows: [] } } }),
      },
      "@/lib/wall-badges": wallBadges,
      "@/lib/use-media-query": { useIsMobile: () => false, useMediaQuery: () => false },
      "@/lib/use-visible-polling": { useVisiblePolling: () => {} },
      "@/lib/use-scroll-restoration": { useScrollRestoration: () => ({ current: null }) },
    });
    return renderToStaticMarkup(React.createElement(mod.LibraryView));
  };

  // 空数据：整行不渲染（老用户升级后首页零变化）
  const emptyHtml = renderHomeWithRated([]);
  assert.doesNotMatch(emptyHtml, /data-testid="rated-row"/);

  // 有高分作品：渲染「我的高分作品」行
  const populatedHtml = renderHomeWithRated([
    {
      media_item_id: 42,
      library_id: 1,
      kind: "movie",
      source: "tmdb",
      tmdb_id: 100,
      title: "千与千寻",
      year: 2001,
      poster_url: null,
      backdrop_url: null,
      primary_aspect: 0.67,
      release_date: "2001-07-20",
      rating: 8.5,
      user_rating: 9,
      rated_at: "2026-11-25T10:00:00Z",
      poster_blur: null,
      primary_file_id: 1,
      file_count: 1,
      total_size_bytes: 1024,
      seasons: [],
      episode_count: 0,
      resolutions: ["1080p"],
      missing_count: 0,
      air_status: null,
      missing_episode_count: 0,
      added_at: null,
      is_favorite: false,
      recent_addition: null,
      inventory_summary: null,
      probe_pending_count: 0,
    },
  ]);
  assert.match(populatedHtml, /data-testid="rated-row"/);
  assert.match(populatedHtml, /我的高分作品/);
});

// ---------------------------------------------------------------------------
// 4. 海报角标：我的评分优先于 TMDB、min_rating 不过滤我的评分、默认开不改变未评分海报
// ---------------------------------------------------------------------------

test("poster badge my_rating precedence, min_rating isolation, and default-on unrated invariance", () => {
  const { DEFAULT_POSTER_BADGES, hasAnyBadge, normalizePosterBadges, posterBadgeRequest, posterBadges } =
    badges;

  const baseItem = {
    kind: "movie",
    rating: 8.4,
    year: 2022,
    resolutions: ["2160p"],
    air_status: null,
    user_rating: null,
  };

  // 默认 my_rating=true，但未评分海报不亮任何角标（外观与改版前一致）
  assert.equal(DEFAULT_POSTER_BADGES.my_rating, true);
  assert.equal(normalizePosterBadges(undefined).my_rating, true);
  assert.equal(posterBadgeRequest(DEFAULT_POSTER_BADGES), "my_rating");
  assert.equal(hasAnyBadge(posterBadges(baseItem, DEFAULT_POSTER_BADGES)), false);

  // 已评分（默认偏好）：显示我的评分（5 星刻度 4.5），不出 TMDB 分
  const ratedDefault = posterBadges({ ...baseItem, user_rating: 9 }, DEFAULT_POSTER_BADGES);
  assert.equal(ratedDefault.myRating, 4.5);
  assert.equal(ratedDefault.rating, null);

  // my_rating 与 rating 同时打开：同一位置只出我的评分，不出 TMDB 分
  const bothOn = { ...DEFAULT_POSTER_BADGES, my_rating: true, rating: true, min_rating: 9.0 };
  const ratedBoth = posterBadges({ ...baseItem, user_rating: 3 }, bothOn);
  assert.equal(ratedBoth.myRating, 1.5, "min_rating must NEVER filter my_rating");
  assert.equal(ratedBoth.rating, null, "TMDB rating suppressed when my_rating is shown");

  // 未评分 + my_rating 与 rating 同时打开：回落到 TMDB 评分且受 min_rating 过滤
  assert.equal(posterBadges(baseItem, bothOn).rating, null, "TMDB 8.4 filtered by min_rating 9.0");
  assert.equal(
    posterBadges(baseItem, { ...bothOn, min_rating: 8.0 }).rating,
    8.4,
    "unrated item falls back to TMDB rating",
  );

  // 显式关闭 my_rating：已评分条目也回落到 TMDB 评分
  const myOff = { ...DEFAULT_POSTER_BADGES, my_rating: false, rating: true };
  assert.equal(posterBadgeRequest(myOff), "");
  const fallbackToTmdb = posterBadges({ ...baseItem, user_rating: 10 }, myOff);
  assert.equal(fallbackToTmdb.myRating, null);
  assert.equal(fallbackToTmdb.rating, 8.4);

  // Overlay 渲染：仅出 data-badge="my-rating"（4.5），不同时出 data-badge="rating"
  const overlay = compile("../components/poster-badges.tsx", {
    "react/jsx-runtime": jsx,
    react: { ...React, useRef: (v) => ({ current: v }), useEffect: () => {} },
    "next-intl": { useTranslations: () => appTranslator("zh-Hans") },
    "@/components/icons": {
      StarIcon: (p) => React.createElement("svg", { "data-icon": "star", ...p }),
      HeartIcon: (p) => React.createElement("svg", { "data-icon": "heart", ...p }),
    },
    "@/lib/poster-badges": badges,
    "@/lib/ui-prefs": { useUiPrefs: () => ({ prefs: { poster_badges: bothOn } }) },
  });
  const html = renderToStaticMarkup(
    React.createElement(overlay.PosterBadgeOverlay, {
      set: posterBadges({ ...baseItem, user_rating: 9 }, bothOn),
      favorite: false,
      yieldBottom: false,
    }),
  );
  assert.match(html, /data-badge="my-rating"/);
  assert.match(html, />4\.5</);
  assert.doesNotMatch(html, /data-badge="rating"/);
  assert.equal(
    overlay.usePosterBadgeDescriptions(posterBadges({ ...baseItem, user_rating: 9 }, bothOn)).join(" | "),
    "我的评分 4.5",
  );
});
