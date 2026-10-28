import assert from "node:assert/strict";
import test from "node:test";

import {
  EPISODE_CAP_BATCH,
  EPISODE_CAP_THRESHOLD,
  canCapSeason,
  capsPayload,
  currentWindows,
  defaultWindow,
  draftFromSeasons,
  effectiveWindow,
  formatEpisodes,
  isAiringSeason,
  isLongSeason,
  partWindow,
  rangeLabel,
  sameWindows,
  seasonTotal,
  windowCount,
  windowKind,
  windowKindOf,
  windowsAfter,
} from "../lib/subscription-episode-cap.ts";
import { subscriptionProgressNote } from "../lib/subscription-ui.ts";

function season(seasonNumber, episodeCount, airedCount = episodeCount ?? 0) {
  return { season_number: seasonNumber, episode_count: episodeCount, aired_count: airedCount };
}

test("只有单季集数达到阈值才提供「先订阅一部分」", () => {
  assert.equal(isLongSeason(season(1, EPISODE_CAP_THRESHOLD - 1)), false);
  assert.equal(isLongSeason(season(1, EPISODE_CAP_THRESHOLD)), true);
  // TMDB 宣称的集数缺失时看已播集数
  assert.equal(isLongSeason(season(1, null, 1043)), true);
  assert.equal(seasonTotal(season(1, 80, 120)), 120);
  // 特别季再长也不问
  assert.equal(isLongSeason(season(0, 500)), false);
});

test("在播的一季：剧还在播且它是最近一个开播的季", () => {
  const seasons = [season(1, 1043), season(2, 100, 0)];
  assert.equal(isAiringSeason("Returning Series", seasons, 1), true);
  // 还没开播的新一季不算在播（按完结季从第 1 集订起）
  assert.equal(isAiringSeason("Returning Series", seasons, 2), false);
  // 完结剧没有在播的季；TMDB 状态缺失同
  assert.equal(isAiringSeason("Ended", [season(1, 1043)], 1), false);
  assert.equal(isAiringSeason(null, [season(1, 1043)], 1), false);
  // 上一季已播、下一季开播：只有下一季算
  const both = [season(1, 500), season(2, 300, 10)];
  assert.equal(isAiringSeason("Returning Series", both, 1), false);
  assert.equal(isAiringSeason("Returning Series", both, 2), true);
});

test("超长的季不动草稿就按默认先订阅一批；选了「全部」才是整季", () => {
  const long = season(1, 1043);
  // 完结季：从第 1 集订一批
  assert.deepEqual(effectiveWindow(long, {}, false), { start: 1, end: EPISODE_CAP_BATCH });
  assert.equal(effectiveWindow(long, { 1: null }, false), null);
  assert.deepEqual(effectiveWindow(long, { 1: { start: 1, end: 50 } }, false), { start: 1, end: 50 });
  // 盖住整季 = 订阅整季，服务端同口径丢弃
  assert.equal(effectiveWindow(long, { 1: { start: 1, end: 1043 } }, false), null);
  assert.equal(effectiveWindow(long, { 1: { start: 1, end: 5000 } }, false), null);
  assert.deepEqual(effectiveWindow(long, { 1: { start: 0, end: 20 } }, false), { start: 1, end: 20 });
  // 不长的季没动过就是整季；调整订阅里设过的窗口照样生效（issue #950）
  assert.equal(effectiveWindow(season(2, 12), {}, false), null);
  assert.deepEqual(effectiveWindow(season(2, 12), { 2: { start: 1, end: 5 } }, false), { start: 1, end: 5 });
  assert.deepEqual(effectiveWindow(season(2, 12), { 2: { start: 6, end: null } }, false), { start: 6, end: null });
});

test("调整订阅里每一季都能先订阅一部分：特别季与只有一集的季除外", () => {
  assert.equal(canCapSeason(season(1, 24), false), true);
  assert.equal(canCapSeason(season(1, 2), false), true);
  assert.equal(canCapSeason(season(1, 1), false), false);
  assert.equal(canCapSeason(season(0, 300), false), false);
  // 在播季看已播集数：只播了一集没有「最新一部分」可言
  assert.equal(canCapSeason(season(1, 24, 1), true), false);
  assert.equal(canCapSeason(season(1, 24, 6), true), true);
});

test("点「先订阅一部分」总会真的截掉一段，短季不会点了没反应", () => {
  // 超长季与默认值一致
  assert.deepEqual(partWindow(season(1, 1043), false), { start: 1, end: EPISODE_CAP_BATCH });
  assert.deepEqual(partWindow(season(1, 1186, 1100), true), { start: 1081, end: null });
  // 不到一批：完结季截到倒数第二集，在播季至少从第 2 集起
  assert.deepEqual(partWindow(season(1, 12), false), { start: 1, end: 11 });
  assert.deepEqual(partWindow(season(1, 24, 6), true), { start: 2, end: null });
  // 都不等于整季（normalize 后不会变成 null）
  assert.notEqual(effectiveWindow(season(1, 12), { 1: partWindow(season(1, 12), false) }, false), null);
});

test("不设上界的窗口：在播季读作最新 N 集，完结季读作从第 N 集起", () => {
  assert.equal(windowKind({ end: 20 }, false), "first");
  assert.equal(windowKind({ end: 20 }, true), "first");
  assert.equal(windowKind({ end: null }, true), "latest");
  assert.equal(windowKind({ end: null }, false), "from");
  // 服务端给的窗口按它标的 airing；旧服务端没标时沿用旧读法
  assert.equal(windowKindOf({ end: null, airing: false }), "from");
  assert.equal(windowKindOf({ end: null, airing: true }), "latest");
  assert.equal(windowKindOf({ end: null }), "latest");
  assert.equal(windowKindOf({ end: 20, airing: false }), "first");
});

test("在播的超长季默认订最新一批，之后播出的照常进来", () => {
  const airing = season(1, 1186, 1100);
  // 默认：第 aired-19 集起、不设上界
  assert.deepEqual(effectiveWindow(airing, {}, true), { start: 1081, end: null });
  // 已播不足一批时从第 1 集起
  assert.deepEqual(
    effectiveWindow(season(1, 1043, 12), {}, true),
    { start: 1, end: null },
  );
  // 用户改数：n 是「最新几集」，提交时换算回 start
  assert.deepEqual(
    effectiveWindow(airing, { 1: { start: 1061, end: null } }, true),
    { start: 1061, end: null },
  );
  assert.deepEqual(defaultWindow(airing, true), { start: 1081, end: null });
  assert.deepEqual(defaultWindow(airing, false), { start: 1, end: EPISODE_CAP_BATCH });
});

test("提交内容只含被勾选、且确实截断了本季的季", () => {
  const seasons = [season(1, 1043), season(2, 300), season(3, 12, 0)];
  assert.deepEqual(capsPayload(seasons, new Set([1, 2, 3]), {}, "Ended"), {
    1: { start: 1, end: EPISODE_CAP_BATCH },
    2: { start: 1, end: EPISODE_CAP_BATCH },
  });
  assert.deepEqual(capsPayload(seasons, new Set([2, 3]), { 2: null }, "Ended"), {});
  assert.deepEqual(
    capsPayload(seasons, new Set([1]), { 1: { start: 1, end: 60 } }, "Ended"),
    { 1: { start: 1, end: 60 } },
  );
  // 在播剧：只有最近开播的第 2 季按最新一批提交；更早的季已播完，仍从第 1 集订起
  assert.deepEqual(capsPayload(seasons, new Set([1, 2]), {}, "Returning Series"), {
    1: { start: 1, end: EPISODE_CAP_BATCH },
    2: { start: 281, end: null },
  });
});

test("存量订阅打开调整弹层不会被默认值悄悄改成先订阅一批", () => {
  const stored = [
    { season_number: 1, tmdb_count: 1043, floor: null, window: null },
    { season_number: 2, tmdb_count: 300, floor: null, window: { start: 1, end: 40 } },
    { season_number: 3, tmdb_count: 1186, floor: null, window: { start: 1081, end: null } },
  ];
  const seasons = [season(1, 1043), season(2, 300), season(3, 1186, 1100), season(4, 500)];
  const draft = draftFromSeasons(stored);
  assert.deepEqual(draft, {
    1: null,
    2: { start: 1, end: 40 },
    3: { start: 1081, end: null },
  });
  // 每一季都保持原状；弹层里新勾上的第 4 季才按默认
  assert.deepEqual(capsPayload(seasons, new Set([1, 2, 3, 4]), draft, "Ended"), {
    2: { start: 1, end: 40 },
    3: { start: 1081, end: null },
    4: { start: 1, end: EPISODE_CAP_BATCH },
  });
  assert.deepEqual(currentWindows(stored), {
    2: { start: 1, end: 40 },
    3: { start: 1081, end: null },
  });
  assert.deepEqual(currentWindows(null), {});
  // 经接口给短季设的「从第 N 集起」打开调整弹层再保存也原样保留，不会被悄悄清掉
  const short = [{ season_number: 1, tmdb_count: 24, floor: null, window: { start: 10, end: null } }];
  assert.deepEqual(capsPayload([season(1, 24)], new Set([1]), draftFromSeasons(short), "Ended"), {
    1: { start: 10, end: null },
  });
});

test("窗口表按内容比较，与键顺序无关", () => {
  assert.equal(
    sameWindows({ 1: { start: 1, end: 20 }, 2: { start: 5, end: null } }, { 2: { start: 5, end: null }, 1: { start: 1, end: 20 } }),
    true,
  );
  assert.equal(sameWindows({ 1: { start: 1, end: 20 } }, { 1: { start: 1, end: 40 } }), false);
  assert.equal(sameWindows({ 1: { start: 1, end: 20 } }, {}), false);
  assert.equal(sameWindows({}, {}), true);
});

test("改窗口时整体替换：其它季原样带回，盖住整季等于去掉这一季的窗口", () => {
  assert.deepEqual(
    windowsAfter({ 1: { start: 1, end: 20 }, 2: { start: 5, end: null } }, { start: 1, end: 40 }, 1, 1043),
    { 1: { start: 1, end: 40 }, 2: { start: 5, end: null } },
  );
  assert.deepEqual(
    windowsAfter({ 1: { start: 1, end: 20 }, 2: { start: 5, end: null } }, { start: 1, end: 1043 }, 1, 1043),
    { 2: { start: 5, end: null } },
  );
  // 往前订到第 1 集 = 整季 = 去掉窗口
  assert.deepEqual(
    windowsAfter({ 1: { start: 5, end: null } }, { start: 1, end: null }, 1, 100),
    {},
  );
});

test("在播窗口订阅的集数随本季已录集数生长", () => {
  assert.equal(windowCount({ season_number: 1, start: 1081, end: null, total: 1100 }), 20);
  assert.equal(windowCount({ season_number: 1, start: 1081, end: null, total: 1110 }), 30);
});

test("详情页收录范围标出被截断的季", () => {
  assert.equal(
    rangeLabel([1], [{ season_number: 1, start: 1, end: 20, total: 1043 }]),
    "第 1 季（前 20 集）",
  );
  assert.equal(
    rangeLabel([1], [{ season_number: 1, start: 1081, end: null, total: 1100 }]),
    "第 1 季（最新 20 集）",
  );
  assert.equal(
    rangeLabel([1, 2], [{ season_number: 2, start: 1, end: 1020, total: 1043 }]),
    "第 1 季、第 2 季（前 1,020 集）",
  );
  assert.equal(rangeLabel([0, 1], null), "特别篇、第 1 季");
  assert.equal(
    rangeLabel([1, 2], [{ season_number: 2, start: 1, end: 1020, total: 1043 }], undefined, "en"),
    "Season 1, Season 2 (first 1,020 episodes)",
  );
  assert.equal(
    rangeLabel([1], [{ season_number: 1, start: 1100, end: null, total: 1100 }], undefined, "en"),
    "Season 1 (latest 1 episode)",
  );
  // 服务端标了完结（airing=false）的不设上界窗口：从第 N 集起（issue #950）
  const ended = [{ season_number: 1, start: 120, end: null, total: 200, airing: false }];
  assert.equal(rangeLabel([1], ended), "第 1 季（第 120 集起）");
  assert.equal(rangeLabel([1], ended, undefined, "en"), "Season 1 (from episode 120)");
  assert.equal(
    rangeLabel([1], [{ ...ended[0], airing: true }], { 1: 200 }),
    "第 1 季（最新 81 集）",
  );
  assert.equal(formatEpisodes(1043), "1,043");
});

// --- 订阅墙：被截断的订阅下完这一批后不能说「等待新集播出」 ---

function subscription({ status = "active", wanted = 0, grabbed = 0, imported = 20, windows } = {}) {
  return {
    media: { kind: "tv", status: "Ended" },
    status,
    selected_seasons: [1],
    follow_future: false,
    season_collection: [],
    episode_windows: windows,
    progress: { total: wanted + grabbed + imported, wanted, grabbed, downloaded: 0, imported },
  };
}

test("下完这一批：完结季说订阅到第几集、可继续；在播季说最新几集、可往前补", () => {
  const tail = [{ season_number: 1, start: 1, end: 20, total: 1043 }];
  assert.equal(subscriptionProgressNote(subscription({ windows: tail })), "已订阅到第 20 集 · 可继续");
  // 旧服务端不标 airing：不设上界的窗口沿用旧读法
  const head = [{ season_number: 1, start: 1081, end: null, total: 1100 }];
  assert.equal(
    subscriptionProgressNote(subscription({ windows: head })),
    "已订阅最新 20 集 · 可以往前补",
  );
  assert.equal(
    subscriptionProgressNote(subscription({ windows: [{ ...head[0], airing: true }] })),
    "已订阅最新 20 集 · 可以往前补",
  );
  // 完结季不设上界：从第 N 集起，同样可以往前补（issue #950）
  const from = [{ season_number: 1, start: 120, end: null, total: 200, airing: false }];
  assert.equal(subscriptionProgressNote(subscription({ windows: from })), "已从第 120 集起订阅 · 可以往前补");
  // 没有窗口的订阅保持原样
  assert.equal(subscriptionProgressNote(subscription({})), "等待新集播出");
  // 还在下载时照旧报下载进度
  assert.equal(
    subscriptionProgressNote(subscription({ grabbed: 3, windows: tail })),
    "3 集下载中 · 已入库 20",
  );
});
