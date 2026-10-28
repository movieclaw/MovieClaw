import assert from "node:assert/strict";
import test from "node:test";
import {
  WheelPager,
  loadReelsAutoplay,
  loadReelsQuality,
  reelBurnTrack,
  reelKeyAction,
  reelFilterQuery,
  reelFilterSummary,
  reelFilterValues,
  reelSubtitleTrack,
  saveReelsAutoplay,
  saveReelsQuality,
  toggleReelFilter,
  watchOnly,
} from "../lib/reels.ts";

// 片段页的筛选、画质记忆与片段字幕（同 iOS ReelFilterMenu / ReelsQuality / ReelPlayer.clipSubtitles）

test("类型、年代、地区、片长维内多选，再点一次取消", () => {
  let filter = toggleReelFilter({}, "genres", "16");
  filter = toggleReelFilter(filter, "genres", "18");
  assert.deepEqual(filter.genres, [16, 18], "类型存成 TMDB 数字 id");
  assert.deepEqual(reelFilterValues(filter, "genres"), ["16", "18"], "读回来与计数接口的取值同形");
  filter = toggleReelFilter(filter, "genres", "16");
  assert.deepEqual(filter.genres, [18]);
  filter = toggleReelFilter(toggleReelFilter(filter, "decades", "2010s"), "runtimes", "90to120");
  assert.deepEqual(filter.decades, ["2010s"]);
  assert.deepEqual(filter.runtimes, ["90to120"]);
});

test("评分下限与「只看没看过的」是单选：换一档替换，点同一档取消", () => {
  let filter = toggleReelFilter({}, "rating_gte", "8");
  assert.equal(filter.ratingGte, 8);
  filter = toggleReelFilter(filter, "rating_gte", "7");
  assert.equal(filter.ratingGte, 7);
  filter = toggleReelFilter(filter, "rating_gte", "7");
  assert.equal(filter.ratingGte, null);
  filter = toggleReelFilter(filter, "watch", "unwatched");
  assert.equal(filter.watch, "unwatched");
  assert.equal(toggleReelFilter(filter, "watch", "unwatched").watch, null);
});

test("切到「其他」只留观看状态", () => {
  assert.deepEqual(watchOnly({ genres: [16], ratingGte: 8, watch: "unwatched" }), { watch: "unwatched" });
  assert.deepEqual(watchOnly({ genres: [16] }), {});
});

test("查询串与媒体库筛选同一套参数，另带 kind", () => {
  const query = new URLSearchParams();
  reelFilterQuery({ genres: [16, 18], countries: ["JP"], ratingGte: 8, watch: "unwatched" }, "tv", query);
  assert.equal(query.get("g"), "16,18");
  assert.equal(query.get("c"), "JP");
  assert.equal(query.get("rating_gte"), "8");
  assert.equal(query.get("w"), "unwatched");
  assert.equal(query.get("kind"), "tv");
  const empty = new URLSearchParams();
  reelFilterQuery({}, null, empty);
  assert.equal(empty.toString(), "", "没条件不带任何参数");
});

test("顶栏按钮：没条件写全部，一个条件写它的值，多个写条数", () => {
  assert.deepEqual(reelFilterSummary({}, null), { type: "all" });
  assert.deepEqual(reelFilterSummary({}, "tv"), { type: "kind", value: "tv" });
  assert.deepEqual(reelFilterSummary({ watch: "unwatched" }, null), { type: "unwatched" });
  assert.deepEqual(reelFilterSummary({ ratingGte: 8 }, null), { type: "value", key: "rating_gte", value: "8" });
  assert.deepEqual(reelFilterSummary({ genres: [16] }, "movie"), { type: "count", count: 2 });
  assert.deepEqual(reelFilterSummary({ genres: [16, 18] }, null), { type: "count", count: 2 });
});

function withStorage(run) {
  const store = new Map();
  globalThis.window = {
    localStorage: {
      getItem: (key) => (store.has(key) ? store.get(key) : null),
      setItem: (key, value) => store.set(key, String(value)),
      removeItem: (key) => store.delete(key),
    },
  };
  try {
    run(store);
  } finally {
    delete globalThis.window;
  }
}

test("画质只记一个值，默认原画；记坏了、读不到存储都回原画", () => {
  withStorage((store) => {
    assert.equal(loadReelsQuality(), null);
    saveReelsQuality(720);
    assert.equal(loadReelsQuality(), 720);
    saveReelsQuality(null);
    assert.equal(loadReelsQuality(), null);
    assert.equal(store.size, 0, "选回原画就删掉这条");
    store.set("movieclaw.reels.quality", "999");
    assert.equal(loadReelsQuality(), null);
  });
  assert.equal(loadReelsQuality(), null, "没有 window（SSR）也不抛");
});

test("片段字幕：srt 要服务端转 VTT，ass 原样给 JASSUB；没有文件、认不出的格式不画", () => {
  const url = "/api/v1/playback/files/7/subtitles?track=embedded:1&start_ms=50000&end_ms=105000&token=x";
  const srt = reelSubtitleTrack({ ordinal: 1, language: "chi", title: "简体", codec: "subrip", url, format: "srt" });
  assert.equal(srt.kind, "vtt");
  assert.equal(srt.url, `${url}&format=vtt`);
  assert.equal(srt.ref, "embedded:1");
  const ass = reelSubtitleTrack({ ordinal: 2, language: "chi", title: null, codec: "ass", url, format: "ass" });
  assert.equal(ass.kind, "ass");
  assert.equal(ass.url, url);
  assert.equal(reelSubtitleTrack({ ordinal: 0, language: "chi", title: null, codec: "hdmv_pgs_subtitle", url: null, format: null }), null);
  assert.equal(reelSubtitleTrack({ ordinal: 0, language: null, title: null, codec: "mov_text", url, format: "tx3g" }), null);
  assert.equal(reelSubtitleTrack(null), null);
});

test("只有图形字幕、且限了画质时才请服务端压进画面", () => {
  const pgs = { ordinal: 3, language: "chi", title: null, codec: "hdmv_pgs_subtitle", url: null, format: null };
  const srt = { ordinal: 1, language: "chi", title: null, codec: "subrip", url: "/x?token=t", format: "srt" };
  assert.equal(reelBurnTrack(pgs, 720), "embedded:3");
  assert.equal(reelBurnTrack(pgs, null), "off", "原画不为压字幕转码");
  assert.equal(reelBurnTrack(srt, 720), "off", "文字字幕由页面自己画");
  assert.equal(reelBurnTrack(null, 720), "off");
});

test("滚轮翻条：一次手势只翻一条，停一下才认下一次", () => {
  const pager = new WheelPager(40, 220);
  // 触控板轻扫：一串小增量连着来（带惯性）
  const steps = [12, 18, 25, 30, 22, 15, 9, 5].map((delta, i) => pager.push(delta, 1000 + i * 16));
  assert.deepEqual(steps.filter(Boolean), [1], "整串只翻一条");
  assert.equal(pager.push(30, 1200), 0, "惯性没停（间隔不够）还锁着");
  assert.equal(pager.push(-60, 1500), -1, "停过之后往上拨，翻回上一条");
  // 鼠标滚轮一格一个事件：慢慢拨就是一格一条
  assert.equal(pager.push(100, 2000), 1);
  assert.equal(pager.push(100, 2400), 1);
  assert.equal(pager.push(20, 3000), 0, "不够阈值不动");
});

test("放映厅的键盘：↑↓ / J K 换条、空格暂停、M 静音、F 全屏、回车看全片", () => {
  assert.equal(reelKeyAction("ArrowDown"), "next");
  assert.equal(reelKeyAction("j"), "next");
  assert.equal(reelKeyAction("ArrowUp"), "prev");
  assert.equal(reelKeyAction("K"), "prev");
  assert.equal(reelKeyAction(" "), "toggle");
  assert.equal(reelKeyAction("m"), "mute");
  assert.equal(reelKeyAction("F"), "fullscreen");
  assert.equal(reelKeyAction("Enter"), "watch");
  assert.equal(reelKeyAction("a"), null);
});

test("自动连播默认开，关了记在本机", () => {
  withStorage((store) => {
    assert.equal(loadReelsAutoplay(), true);
    saveReelsAutoplay(false);
    assert.equal(loadReelsAutoplay(), false);
    saveReelsAutoplay(true);
    assert.equal(loadReelsAutoplay(), true);
    assert.equal(store.size, 0, "打开就是默认，不留记录");
  });
  assert.equal(loadReelsAutoplay(), true, "没有 window（SSR）也不抛");
});
