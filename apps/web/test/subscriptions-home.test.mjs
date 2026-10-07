import assert from "node:assert/strict";
import test from "node:test";

import {
  arrivalGroups,
  clockText,
  heroSlides,
  scheduleDays,
  shelf,
  shelfCountSummary,
  shortenCandidates,
  wallSummary,
  weekdayOf,
} from "../lib/subscriptions-home.ts";

// 订阅首页（流媒体式版式）的纯逻辑：Hero 选哪几张、日程怎么分天、海报行怎么排与计数。
// 用例逐条对照 iOS 的 MovieClawTests/SubscriptionsHomeModelTests.swift，两端口径一致。
// 时间全部相对固定的 now 生成，不依赖运行时区。

const now = new Date(1_790_000_000 * 1000);
const at = (offsetSeconds) => new Date(now.getTime() + offsetSeconds * 1000);

function media(id, kind, status) {
  return {
    media_item_id: id,
    kind,
    tmdb_id: 1000 + id,
    douban_id: null,
    title: `作品${id}`,
    original_title: `Title ${id}`,
    year: 2024,
    poster_url: `https://image.tmdb.org/t/p/w500/p${id}.jpg`,
    backdrop_url: `https://image.tmdb.org/t/p/w1280/b${id}.jpg`,
    logo_url: null,
    status: status ?? null,
  };
}

function sub(
  id,
  {
    kind = "tv",
    status = "active",
    mediaStatus = "Returning Series",
    progress = {},
    owned = 4,
    updatedAt = "2026-09-20T00:00:00Z",
  } = {},
) {
  return {
    id,
    media: media(id, kind, mediaStatus),
    status,
    selected_seasons: kind === "tv" ? [1] : [],
    follow_future: kind === "tv",
    rule_set_id: 1,
    library_id: null,
    progress: { total: 8, wanted: 1, grabbed: 0, downloaded: 0, imported: 0, upgrading: 0, ...progress },
    season_collection:
      kind === "tv"
        ? [
            {
              season_number: 1,
              name: "第 1 季",
              air_date: "2026-01-01",
              episode_count: 8,
              aired_count: 8,
              owned_count: owned,
            },
          ]
        : [],
    created_at: "2026-01-01T00:00:00Z",
    updated_at: updatedAt,
  };
}

function arrival(
  subId,
  {
    kind = "tv",
    episode = 1,
    status = "wanted",
    daysAhead = 0,
    day = "2026-09-26",
    predictedAt = null,
    downloadedAt = null,
  } = {},
) {
  return {
    subscription_id: subId,
    wanted_id: subId * 100 + episode,
    media_title: `作品${subId}`,
    media_kind: kind,
    season_number: kind === "tv" ? 1 : 0,
    episode_number: kind === "tv" ? episode : 0,
    status,
    air_date: day,
    expected_day: day,
    days_ahead: daysAhead,
    release_forecast: predictedAt
      ? { version: 3, predicted_at: predictedAt.toISOString(), confidence: "high", sites: [] }
      : null,
    next_probe_at: null,
    info_hash: status === "wanted" ? null : `hash${subId}`,
    grabbed_at: null,
    downloaded_at: downloadedAt ? downloadedAt.toISOString() : null,
    estimated_release_to_import_minutes: 60,
    estimated_download_to_import_minutes: 10,
  };
}

function recent(subId, { kind = "tv", episodes = [1], importedAt }) {
  return {
    subscription_id: subId,
    media: media(subId, kind, "Returning Series"),
    season_number: kind === "tv" ? 1 : 0,
    episode_number: kind === "tv" ? episodes[0] : 0,
    episode_name: kind === "tv" ? `第${episodes[0]}集` : null,
    still_url: null,
    units: episodes.map((episode) => ({
      season_number: kind === "tv" ? 1 : 0,
      episode_number: kind === "tv" ? episode : 0,
    })),
    progress_percent: null,
    imported_at: importedAt.toISOString(),
  };
}

// —— Hero ——

test("Hero 先讲正在发生的，再讲刚到的，再讲今天，最后更早到的", () => {
  const subs = [1, 2, 3, 4, 5, 6].map((id) => sub(id));
  const arrivals = [
    arrival(1, { status: "grabbed" }),
    arrival(2, { status: "downloaded", downloadedAt: at(-60) }),
    arrival(3, { predictedAt: at(2 * 3600) }),
    arrival(4, { daysAhead: 3, day: "2026-10-01" }),
  ];
  const recents = [
    recent(5, { episodes: [3, 4], importedAt: at(-2 * 3600) }),
    recent(6, { importedAt: at(-3 * 86400) }),
  ];
  const groups = arrivalGroups(arrivals, [], now);
  const slides = heroSlides(subs, groups, recents, now);

  // 整理中比下载中更快落地 → 48 小时内刚到的 → 今天的预告 → 更早到的；满 5 张为止，最远的预告挤不进来
  assert.deepEqual(slides.map((slide) => slide.subscriptionId), [2, 1, 5, 3, 6]);
  assert.deepEqual(
    slides.map((slide) => slide.stage),
    ["organizing", "downloading", "arrived", "today", "arrived"],
  );
  // 下载中给不出预计时间：信息行自己写出「正在下载」
  assert.equal(slides[1].detail, "S01E01 · 正在下载");
  // 整理中给出预计可看的时刻（下载完成 1 分钟前 + 历史耗时 10 分钟）
  assert.equal(slides[0].clock, clockText(at(9 * 60).getTime(), now));
  // 刚到的主按钮直接播放这一批里第一个没看完的单元，说明写「共 2 集新内容」
  assert.deepEqual(slides[2].play, { mediaItemId: 5, season: 1, episode: 3 });
  assert.equal(slides[2].eyebrow.text, "刚刚入库");
  assert.ok(slides[2].footnote?.includes("共 2 集新内容"));
  // 看过一半交给播放键（「继续播放」），说明行不再写「看到 N%」
  assert.equal(slides[2].resumePercent, null);
  assert.ok(!slides[2].footnote?.includes("看到"));
  assert.equal(slides[4].eyebrow.text, "新一集");
  // 今天的预告：预测出种 + 历史耗时 60 分钟 = 预计入库时刻
  assert.equal(slides[3].clockLabel, "S01E01 · 预计入库");
  assert.equal(slides[3].clock, clockText(at(3 * 3600).getTime(), now));
});

test("Hero 的预告用星期说话，什么都没发生时退回在追的几部", () => {
  const subs = [
    sub(1, { updatedAt: "2026-09-01T00:00:00Z" }),
    sub(2, { updatedAt: "2026-09-25T00:00:00Z" }),
    sub(3, { status: "completed" }),
  ];
  const upcoming = heroSlides(
    subs,
    arrivalGroups([arrival(1, { daysAhead: 5, day: "2026-10-01" })], [], now),
    [],
    now,
  );
  assert.equal(upcoming.length, 1);
  assert.equal(upcoming[0].stage, "upcoming");
  assert.equal(upcoming[0].clock, "周四");
  assert.equal(upcoming[0].clockLabel, "S01E01 · 10月1日");
  // 平常状态不放点：语气是 calm
  assert.equal(upcoming[0].eyebrow.tone, "calm");

  // 什么都没发生：退回在追的几部（最近动过的在前），不编时间
  const resting = heroSlides(subs, [], [], now);
  assert.deepEqual(resting.map((slide) => slide.subscriptionId), [2, 1, 3]);
  assert.ok(resting.every((slide) => slide.clock === null && slide.play === null));
  assert.equal(resting.at(-1).eyebrow.text, "已收齐");
});

test("Hero 下载中带实时进度：信息行圆点是蓝色呼吸，读屏文字带百分比", () => {
  const subs = [sub(1)];
  const tasks = [{ info_hash: "HASH1", progress: 0.62, state: "downloading", eta_seconds: null }];
  const slides = heroSlides(subs, arrivalGroups([arrival(1, { status: "grabbed" })], tasks, now), [], now);
  assert.deepEqual(slides[0].eyebrow, { text: "下载中 · 62%", tone: "live", pulse: true });
  assert.equal(slides[0].progress, 0.62);
});

// —— 日程 ——

test("日程是一周的日期条，第 8 天有安排才补上", () => {
  const subs = [sub(1), sub(2), sub(3)];
  const arrivals = [
    arrival(1, { daysAhead: 0, day: "2026-09-26", predictedAt: at(3600) }),
    arrival(2, { status: "grabbed", daysAhead: 0, day: "2026-09-26" }),
    arrival(3, { episode: 7, daysAhead: 7, day: "2026-10-03" }),
    arrival(3, { episode: 8, daysAhead: 7, day: "2026-10-03" }),
  ];
  const days = scheduleDays(arrivalGroups(arrivals, [], now), subs, now);
  assert.deepEqual(days.map((day) => day.daysAhead), [0, 1, 2, 3, 4, 5, 6, 7]);
  assert.deepEqual(
    days.map((day) => day.weekday),
    ["今天", "周日", "周一", "周二", "周三", "周四", "周五", "周六"],
  );
  assert.deepEqual(days.map((day) => day.dayNumber), ["26", "27", "28", "29", "30", "1", "2", "3"]);
  assert.ok(days.slice(1, 7).every((day) => day.entries.length === 0));
  // 当天正在发生的排前面；给不出 ETA 的下载说「稍后」
  assert.deepEqual(days[0].entries.map((entry) => entry.subscriptionId), [2, 1]);
  assert.equal(days[0].entries[0].time, "稍后");
  assert.equal(days[0].entries[0].status, "下载中");
  // 同一部剧同一天的两集合成一行
  assert.equal(days[7].entries.length, 1);
  assert.equal(days[7].entries[0].episodeLabel, "S01E07–E08");

  const withoutEighth = scheduleDays(arrivalGroups(arrivals.slice(0, 2), [], now), subs, now);
  assert.equal(withoutEighth.length, 7);
  assert.deepEqual(scheduleDays([], subs, now), []);
});

// —— 海报行 ——

test("剧集一排：进行中在前，已暂停 / 已收齐在分隔线后", () => {
  const completed = { imported: 8, wanted: 0 };
  const subs = [
    sub(1, { owned: 8 }),
    sub(2),
    sub(3),
    sub(4, { progress: { upgrading: 2 } }),
    sub(5),
    sub(6, { status: "paused" }),
    sub(7, { status: "completed", progress: completed, owned: 8, updatedAt: "2026-09-01T00:00:00Z" }),
    sub(8, { status: "completed", progress: completed, owned: 8 }),
    sub(9, { owned: 8 }),
    sub(10, { owned: 8 }),
    sub(11, { status: "completed", progress: { ...completed, upgrading: 1 }, owned: 8 }),
  ];
  const arrivals = [
    arrival(1, { daysAhead: 2, day: "2026-09-28" }),
    arrival(2, { status: "grabbed" }),
    arrival(3, { predictedAt: at(3600) }),
  ];
  const recents = [
    recent(8, { importedAt: at(-3600) }),
    recent(9, { episodes: [5, 6], importedAt: at(-7200) }),
  ];
  const row = shelf("tv", subs, arrivalGroups(arrivals, [], now), recents);
  // 进行中：缺集（即使同时在洗旧集）仍先于纯洗版；同名次保持原有顺序。
  assert.deepEqual(row.active.map((item) => item.sub.id), [2, 9, 3, 1, 4, 5, 10, 11]);
  assert.deepEqual(
    row.active.map((item) => item.chip?.text ?? null),
    ["下载中", "新 2 集", "今天更新", "周一更新", "缺 4 集", "缺 4 集", null, "洗版中"],
  );
  // 已完成的不因「刚到了、还没看」被拉回前排；最近完成的在前
  assert.deepEqual(row.paused.map((item) => item.sub.id), [6]);
  assert.deepEqual(row.done.map((item) => item.sub.id), [8, 7]);
  assert.ok(row.done.every((item) => item.chip === null && item.resting));
  assert.equal(row.restingLabel, "暂停·收齐");
  // 计数 = 分隔线前的数量
  assert.equal(shelfCountSummary(row), "8 部进行中 · 共 11 部");
  assert.equal(wallSummary(row, "tv"), "共 11 部剧集 · 8 部进行中");
  assert.equal(row.active.find((item) => item.sub.id === 5)?.meta, "第 1 季 · 4 / 8");

  assert.equal(row.done[0].meta, "已收齐 · 第 1 季");
});

test("电影一排同一套顺序，刚入库没看的也不会被拉回前排", () => {
  const imported = { imported: 1, wanted: 0 };
  const subs = [
    sub(1, { kind: "movie", mediaStatus: "Released" }),
    sub(2, { kind: "movie", mediaStatus: "Post Production" }),
    sub(3, { kind: "movie", status: "completed", mediaStatus: "Released", progress: imported }),
    sub(4, { kind: "movie", mediaStatus: "Released", progress: { grabbed: 1, wanted: 0 } }),
    sub(5, {
      kind: "movie",
      status: "completed",
      mediaStatus: "Released",
      progress: imported,
      updatedAt: "2026-09-25T00:00:00Z",
    }),
  ];
  const recents = [recent(5, { kind: "movie", importedAt: at(-3600) })];
  const row = shelf("movie", subs, [], recents);
  // 没有预告时按订阅进度判断下载中；没上映的也算进行中，排在最后
  assert.deepEqual(row.active.map((item) => item.sub.id), [4, 1, 2]);
  assert.deepEqual(row.active.map((item) => item.chip?.text), ["下载中", "找资源中", "未上映"]);
  assert.deepEqual(row.done.map((item) => item.sub.id), [5, 3]);
  assert.deepEqual(row.done.map((item) => item.meta), ["2024 · 已入库", "2024 · 已入库"]);
  assert.equal(row.restingLabel, "已入库");
  assert.equal(shelfCountSummary(row), "3 部进行中 · 共 5 部");
});

// —— 格式 ——

test("信息行按「 · 」分段逐段收短", () => {
  // 说明行去尾：先舍集名，再舍后半句
  assert.deepEqual(shortenCandidates("S01E01 · 凶 · 好端端坏了起来", "tail"), [
    "S01E01 · 凶 · 好端端坏了起来",
    "S01E01 · 凶",
    "S01E01",
  ]);
  // 时刻上方的小字留尾：「预计可看」是大号时刻的注解
  assert.deepEqual(shortenCandidates("S03E05 · 预计可看", "head"), ["S03E05 · 预计可看", "预计可看"]);
  assert.deepEqual(shortenCandidates("马上就好", "tail"), ["马上就好"]);
});

test("大号时刻只在不是今天时才写日子", () => {
  const noon = new Date(now);
  noon.setHours(12, 0, 0, 0);
  assert.equal(clockText(noon.getTime() + 3600 * 1000, noon), "13:00");
  assert.equal(clockText(noon.getTime() + 20 * 3600 * 1000, noon), "明天 08:00");
  const later = new Date(noon);
  later.setDate(later.getDate() + 3);
  later.setHours(8, 10, 0, 0);
  assert.equal(clockText(later.getTime(), noon), `${later.getMonth() + 1}/${later.getDate()} 08:10`);
  assert.equal(weekdayOf("2026-09-26"), "周六");
});

// —— 氛围底色（lib/hero-ambient-color.ts，对照 iOS ImmersiveHeroAmbientColor.dominant） ——

test("氛围底色取饱和度加权的主色并压到深色档，灰调画面回落冷银灰", async () => {
  const { AMBIENT_FALLBACK, dominantAmbient } = await import("../lib/hero-ambient-color.ts");
  const pixels = (r, g, b, count = 24 * 24) =>
    Array.from({ length: count }, () => [r, g, b, 255]).flat();

  // 纯灰（黑白片 / 夜景）没有可用色相
  assert.deepEqual(dominantAmbient(pixels(128, 128, 128)), AMBIENT_FALLBACK);
  // 大红画面：色相仍是红，亮度压到 0.44（最大分量 ≈ 112），饱和度封顶 0.72
  const red = dominantAmbient(pixels(230, 30, 30));
  assert.equal(red.r, Math.round(0.44 * 255));
  assert.ok(red.g === red.b && red.g < red.r);
  assert.equal(red.g, Math.round(0.44 * (1 - 0.72) * 255));
});


test("纯洗版最近有活动或下载预告，也排在首次获取资源之后", () => {
  for (const kind of ["movie", "tv"]) {
    const upgrade = sub(1, { kind, owned: 8, progress: { wanted: 0, imported: 8, upgrading: 1 }, updatedAt: "2026-10-07T00:00:00Z" });
    const waiting = sub(2, { kind });
    const pipeline = arrivalGroups([arrival(1, { kind, status: "grabbed" })], [], now);
    const row = shelf(kind, [upgrade, waiting], pipeline, []);
    assert.deepEqual(row.active.map((item) => item.sub.id), [2, 1]);
    assert.equal(row.active[1].chip.text, "洗版中");
  }
});

test("未订阅的旧季缺集不抬高纯洗版；缺少库存但没有工单仍按缺集排", () => {
  const upgrade = sub(1, { owned: 8, progress: { wanted: 0, imported: 8, upgrading: 1 } });
  upgrade.season_collection.push({ ...upgrade.season_collection[0], season_number: 2, owned_count: 0 });
  const missing = sub(2, { progress: { wanted: 0, imported: 4, upgrading: 1 } });
  const row = shelf("tv", [upgrade, missing], [], []);
  assert.deepEqual(row.active.map((item) => item.sub.id), [2, 1]);
  assert.deepEqual(row.active.map((item) => item.chip.text), ["缺 4 集", "洗版中"]);
});
