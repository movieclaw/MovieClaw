import assert from "node:assert/strict";
import test from "node:test";

import {
  buildHomeRows,
  homeCollectionIds,
  moveRowTo,
  newCollectionRow,
  newLibraryRow,
  newMediaKindRow,
  newRowId,
  rowMeta,
  rowTitle,
  rowsToPrefs,
  sortPresetsFor,
} from "../lib/home-rows.ts";

const lib = (id, name, kind = "movie", extra = {}) => ({
  id,
  name,
  kind,
  viewer_access: true,
  exclude_from_home: false,
  ...extra,
});
const LIBS = [lib(1, "电影"), lib(2, "剧集", "tv"), lib(3, "动漫", "tv")];
const COLS = [
  { id: 7, name: "宫崎骏", library_id: 3, sort: "release_date_asc" },
  { id: 8, name: "诺兰", library_id: 1, sort: "title" },
];
// 类型行（kind:*）与类型色块行（genres:*）各有自己的一组用例；其余用例只看库行 /
// 合集行 / 内置行的合并规则
const withoutKinds = (rows) =>
  rows.filter((row) => row.kind !== "media-kind" && row.kind !== "genres");
const ids = (rows) => withoutKinds(rows).map((row) => row.id);
const allIds = (rows) => rows.map((row) => row.id);
const find = (rows, id) => rows.find((row) => row.id === id);

test("虚拟库卡片与合集行同步显示，沿用行顺序并按合集去重", () => {
  const prefs = { rows: [
    { id: "row:hidden", collection_id: 7, hidden: true },
    { id: "row:nolan", collection_id: 8, name: "今晚看点什么", sort: "random" },
    { id: "row:miyazaki", collection_id: 7 },
    { id: "row:duplicate", collection_id: 8, sort: "rating" },
    { id: "row:deleted", collection_id: 99 },
  ] };
  const rows = buildHomeRows(prefs, LIBS, COLS);
  assert.deepEqual(homeCollectionIds(rows), [8, 7]);
  assert.equal(rows.find((row) => row.id === "row:nolan").collection.name, "诺兰");
  assert.deepEqual(homeCollectionIds(buildHomeRows(prefs, LIBS, [COLS[0]])), [7]);
  assert.deepEqual(homeCollectionIds(buildHomeRows({ rows: [] }, LIBS, COLS)), []);
});

test("隐藏或移除合集行同步移除虚拟库卡片，恢复显示后保留入口", () => {
  const pref = { id: "row:nolan", collection_id: 8 };
  const cards = (rows) => homeCollectionIds(buildHomeRows({ rows }, LIBS, COLS));
  assert.deepEqual(cards([pref]), [8]);
  assert.deepEqual(cards([{ ...pref, hidden: true }]), []);
  assert.deepEqual(cards([]), []);
  assert.deepEqual(cards([{ ...pref, hidden: false }]), [8]);
});

test("空清单 = 出厂布局：三个内置行 + 每库一行最近添加", () => {
  const rows = buildHomeRows({ rows: [] }, LIBS, COLS);
  assert.deepEqual(ids(rows), ["up-next", "favorites", "libraries", "lib:1", "lib:2", "lib:3"]);
  assert.equal(rowTitle(find(rows, "lib:1")), "最近添加的电影");
  assert.equal(find(rows, "lib:1").sort, "added_at");
  assert.equal(find(rows, "lib:1").builtin, true);
});

test("存过的按存的顺序在前，没存过的内置行与默认库行补在后面", () => {
  const rows = buildHomeRows(
    { rows: [{ id: "lib:2" }, { id: "up-next" }] },
    LIBS,
    COLS,
  );
  // lib:1 / lib:3 是没存过的库行：插在最后一条库行（lib:2）之后；内置行追加在末尾
  assert.deepEqual(ids(rows), ["lib:2", "lib:1", "lib:3", "up-next", "favorites", "libraries"]);
});

test("新库的默认行插在最后一条库行之后，不落到合集行后面", () => {
  const rows = buildHomeRows(
    {
      rows: [
        { id: "up-next" },
        { id: "lib:1", sort: "release_date" },
        { id: "row:c", collection_id: 7 },
      ],
    },
    LIBS,
    COLS,
  );
  assert.deepEqual(ids(rows), ["up-next", "lib:1", "lib:2", "lib:3", "row:c", "favorites", "libraries"]);
});

test("指向已删库 / 不可见合集 / 仅管理的库的行静默消失", () => {
  const rows = buildHomeRows(
    {
      rows: [
        { id: "lib:99" },
        { id: "row:a", library_id: 99 },
        { id: "row:b", collection_id: 404 },
        { id: "row:c", collection_id: 7 },
        { id: "lib:4" },
      ],
    },
    [...LIBS, lib(4, "仅管理", "movie", { viewer_access: false })],
    COLS,
  );
  assert.deepEqual(ids(rows), ["row:c", "up-next", "favorites", "libraries", "lib:1", "lib:2", "lib:3"]);
});

test("从首页排除的库不给默认行，用户自己加的行仍尊重", () => {
  const libs = [lib(1, "电影"), lib(2, "家庭录像", "video", { exclude_from_home: true })];
  assert.deepEqual(ids(buildHomeRows({ rows: [] }, libs, [])), [
    "up-next",
    "favorites",
    "libraries",
    "lib:1",
  ]);
  const rows = buildHomeRows({ rows: [{ id: "row:v", library_id: 2 }] }, libs, []);
  assert.equal(ids(rows)[0], "row:v");
  assert.equal(rowTitle(find(rows, "row:v")), "最近添加的家庭录像");
});

test("隐藏保留位置；名字为空跟随排序推荐，手输过就不动", () => {
  const rows = buildHomeRows(
    {
      rows: [
        { id: "up-next", hidden: true },
        { id: "lib:1", sort: "rating", unwatched: true },
        { id: "row:x", library_id: 3, sort: "rating", name: "周末补番" },
      ],
    },
    LIBS,
    COLS,
  );
  assert.equal(find(rows, "up-next").hidden, true);
  assert.equal(rowTitle(find(rows, "lib:1")), "评分最高的电影");
  assert.equal(rowMeta(find(rows, "lib:1")), "电影库 · 评分最高 · 只看没看过的");
  assert.equal(rowTitle(find(rows, "row:x")), "周末补番");
});

test("排序档不在库 kind 的预设里时回落到最近添加", () => {
  const libs = [lib(5, "照片", "photo")];
  const rows = buildHomeRows({ rows: [{ id: "lib:5", sort: "rating" }] }, libs, []);
  assert.equal(rows[0].sort, "added_at");
  assert.deepEqual(sortPresetsFor("photo"), ["added_at", "title", "random"]);
});

test("合集行的排序：存了用存的，没存用合集自己的，都不认识回落到最近添加", () => {
  const rows = buildHomeRows(
    {
      rows: [
        { id: "row:a", collection_id: 7 },
        { id: "row:b", collection_id: 8, sort: "random" },
      ],
    },
    LIBS,
    [...COLS, { id: 9, name: "怪", library_id: null, sort: "probing" }],
  );
  // 合集表里的 release_date_asc（方向烧在取值里的那个年代）归一成「上映时间 + 反转」
  assert.equal(rows[0].sort, "release_date");
  assert.equal(rows[0].reversed, true);
  assert.equal(rows[1].sort, "random");
  assert.equal(rows[1].reversed, false);
  assert.equal(rowTitle(rows[0]), "宫崎骏");
  assert.equal(newCollectionRow({ id: 9, name: "怪", library_id: null, sort: "probing" }, "row:z").sort, "added_at");
});

test("合集行也能自己起名字：空则跟合集名走，只有空白等于没起", () => {
  const rows = buildHomeRows(
    {
      rows: [
        { id: "row:a", collection_id: 7, name: "今晚看点轻松的" },
        { id: "row:b", collection_id: 8 },
        { id: "row:c", collection_id: 7, name: "   " },
      ],
    },
    LIBS,
    COLS,
  );
  assert.equal(rowTitle(rows[0]), "今晚看点轻松的");
  assert.equal(rowTitle(rows[1]), "诺兰");
  assert.equal(rows[2].name, "");
  assert.equal(rowTitle(rows[2]), "宫崎骏");
  // 新加的合集行不预填名字，先跟着合集走
  assert.equal(newCollectionRow(COLS[0], "row:z").name, "");
  // 写回只存非空的名字，"跟随合集名" 不占一个字段
  const picked = ["row:a", "row:b", "row:c"].map((id) =>
    rows.find((row) => row.id === id),
  );
  assert.deepEqual(rowsToPrefs(picked), [
    {
      id: "row:a",
      collection_id: 7,
      sort: "release_date",
      order: "asc",
      name: "今晚看点轻松的",
    },
    { id: "row:b", collection_id: 8, sort: "title" },
    { id: "row:c", collection_id: 7, sort: "release_date", order: "asc" },
  ]);
});

test("方向单独一个开关：推荐名跟着翻，写回只在反转自然方向时才存 order，老取值归一", () => {
  const rows = buildHomeRows(
    {
      rows: [
        { id: "lib:1", sort: "added_at", order: "asc" },
        { id: "lib:2", sort: "title", order: "desc" },
        { id: "row:x", library_id: 1, sort: "rating", order: "desc" }, // 与自然方向相同 = 没反转
        { id: "row:y", library_id: 1, sort: "release_date_asc" }, // 老取值
        { id: "row:z", library_id: 1, sort: "random", order: "asc" }, // 随机没有方向
        { id: "favorites", sort: "favorited_at", order: "asc" },
      ],
    },
    LIBS,
    COLS,
  );
  const byId = (id) => rows.find((row) => row.id === id);
  assert.equal(rowTitle(byId("lib:1")), "最早添加的电影");
  assert.equal(rowTitle(byId("lib:2")), "剧集 Z–A");
  assert.equal(byId("row:x").reversed, false);
  assert.equal(rowTitle(byId("row:x")), "评分最高的电影");
  assert.equal(byId("row:y").sort, "release_date");
  assert.equal(byId("row:y").reversed, true);
  assert.equal(rowTitle(byId("row:y")), "最早上映的电影");
  assert.equal(byId("row:z").reversed, false);
  assert.equal(byId("favorites").reversed, true);
  assert.equal(rowMeta(byId("favorites")), "内置 · 最早收藏");
  const picked = ["lib:1", "lib:2", "row:x", "row:y", "row:z", "favorites"].map(byId);
  assert.deepEqual(rowsToPrefs(picked), [
    { id: "lib:1", sort: "added_at", order: "asc" },
    { id: "lib:2", sort: "title", order: "desc" },
    { id: "row:x", library_id: 1, sort: "rating" },
    { id: "row:y", library_id: 1, sort: "release_date", order: "asc" },
    { id: "row:z", library_id: 1, sort: "random" },
    { id: "favorites", sort: "favorited_at", order: "asc" },
  ]);
  // 下拉里不再有「最早上映」这一条：方向是开关，不是档位
  assert.ok(!sortPresetsFor("movie").includes("release_date_asc"));
});

test("收藏行只认自己的四档，其余回落到未看优先", () => {
  const rows = buildHomeRows({ rows: [{ id: "favorites", sort: "random" }] }, LIBS, COLS);
  assert.equal(rows[0].sort, "unwatched_first");
});

test("写回时只存与默认不同的字段，默认库行不带来源", () => {
  const rows = buildHomeRows(
    {
      rows: [
        { id: "favorites", sort: "rating" },
        { id: "lib:1", sort: "release_date", hidden: true },
        { id: "row:x", library_id: 3, sort: "rating", unwatched: true, name: "周末补番" },
        { id: "row:c", collection_id: 7 },
      ],
    },
    LIBS,
    COLS,
  );
  const picked = ["favorites", "lib:1", "row:x", "row:c"].map((id) => rows.find((row) => row.id === id));
  assert.deepEqual(rowsToPrefs(picked), [
    { id: "favorites", sort: "rating" },
    { id: "lib:1", hidden: true, sort: "release_date" },
    { id: "row:x", library_id: 3, sort: "rating", unwatched: true, name: "周末补番" },
    { id: "row:c", collection_id: 7, sort: "release_date", order: "asc" },
  ]);
});

test("新行 id 是 row: 加 6 位 base36；拖到某一位越界原样返回", () => {
  assert.match(newRowId(), /^row:[0-9a-z]{6}$/);
  assert.equal(newRowId(() => 0), "row:000000");
  const rows = withoutKinds(buildHomeRows({ rows: [] }, LIBS, COLS));
  assert.deepEqual(ids(moveRowTo(rows, 0, -1)), ids(rows));
  assert.deepEqual(ids(moveRowTo(rows, 5, 0)).slice(0, 3), ["lib:3", "up-next", "favorites"]);
  assert.deepEqual(ids(moveRowTo(rows, 3, 2)).slice(0, 4), ["up-next", "favorites", "lib:1", "libraries"]);
  assert.equal(newLibraryRow(LIBS[0], "row:abc").id, "row:abc");
});

test("管理员「从首页排除」的库：存过的默认行也不出现，用户自加的行仍尊重", () => {
  const libs = [lib(1, "电影"), lib(2, "家庭录像", "video", { exclude_from_home: true })];
  const rows = buildHomeRows(
    { rows: [{ id: "lib:2", sort: "title" }, { id: "row:v", library_id: 2 }, { id: "lib:1" }] },
    libs,
    [],
  );
  assert.deepEqual(ids(rows), ["row:v", "lib:1", "up-next", "favorites", "libraries"]);
});

test("「最近观看」与「只看没看过的」互斥：以排序为准，开关作废", () => {
  const rows = buildHomeRows(
    { rows: [{ id: "lib:1", sort: "last_played", unwatched: true }] },
    LIBS,
    COLS,
  );
  assert.equal(find(rows, "lib:1").unwatched, false);
  assert.deepEqual(rowsToPrefs([find(rows, "lib:1")]), [{ id: "lib:1", sort: "last_played" }]);
});

test("一条库行都没有时，新库的默认行插在「我的媒体库」之后，不落到合集行后面", () => {
  const rows = buildHomeRows(
    { rows: [{ id: "up-next" }, { id: "libraries" }, { id: "row:c", collection_id: 7 }] },
    LIBS,
    COLS,
  );
  assert.deepEqual(ids(rows), ["up-next", "libraries", "lib:1", "lib:2", "lib:3", "row:c", "favorites"]);
});

// ---------------------------------------------------------------------------
// 按类型的跨库行（设计文档 §8）
// ---------------------------------------------------------------------------

test("出厂布局不带类型行：「全部电影」要主动添加才出现", () => {
  const rows = buildHomeRows({ rows: [] }, LIBS, COLS);
  // 类型色块行（genres:*）是另一回事，有自己的用例
  assert.deepEqual(ids(rows), ["up-next", "favorites", "libraries", "lib:1", "lib:2", "lib:3"]);
  assert.equal(rows.some((row) => row.kind === "media-kind"), false);
  // 升级前存的清单也不补类型行
  const saved = buildHomeRows({ rows: [{ id: "up-next" }, { id: "lib:2" }] }, LIBS, COLS);
  assert.equal(saved.some((row) => row.kind === "media-kind"), false);
});

test("类型行只聚合可见、没被排除首页的库；一个都不剩的类型不出现", () => {
  const libs = [
    lib(1, "电影"),
    lib(2, "4K 电影"),
    lib(3, "少儿", "movie", { exclude_from_home: true }),
    lib(4, "仅管理", "movie", { viewer_access: false }),
    lib(5, "录像", "video", { exclude_from_home: true }),
  ];
  const rows = buildHomeRows(
    { rows: [{ id: "row:m", media_kind: "movie" }, { id: "row:v", media_kind: "video" }] },
    libs,
    [],
  );
  assert.deepEqual(
    rows.filter((row) => row.kind === "media-kind").map((row) => row.id),
    ["row:m"],
  );
  assert.deepEqual(
    find(rows, "row:m").libraries.map((library) => library.id),
    [1, 2],
  );
  assert.equal(rowTitle(find(rows, "row:m")), "全部电影 · 最近添加");
  assert.equal(rowMeta(find(rows, "row:m")), "全部电影（2 个库） · 最近添加");
});

test("v0.30.0 存下的 kind: 行：隐藏的丢掉，显示中的保留且能删；自加类型行带 media_kind", () => {
  const rows = buildHomeRows(
    {
      rows: [
        { id: "kind:movie", sort: "rating", unwatched: true },
        { id: "kind:tv", hidden: true }, // 当年默认塞进来的隐藏行
        { id: "row:k", media_kind: "tv", sort: "random", name: "今晚追哪部" },
        { id: "row:gone", media_kind: "video" }, // 没有其他视频库：静默消失
      ],
    },
    LIBS,
    COLS,
  );
  assert.equal(find(rows, "kind:movie").hidden, false);
  assert.equal(find(rows, "kind:movie").builtin, false);
  assert.equal(rowTitle(find(rows, "kind:movie")), "全部电影 · 评分最高");
  assert.equal(find(rows, "kind:tv"), undefined);
  assert.equal(rowTitle(find(rows, "row:k")), "今晚追哪部");
  assert.equal(find(rows, "row:gone"), undefined);
  // 写回：老的 kind: 行不带来源字段（类型在 id 里），自加行带 media_kind
  assert.deepEqual(
    rowsToPrefs(["kind:movie", "row:k"].map((id) => find(rows, id))),
    [
      { id: "kind:movie", sort: "rating", unwatched: true },
      { id: "row:k", media_kind: "tv", sort: "random", name: "今晚追哪部" },
    ],
  );
});

test("类型行的排序预设按类型裁剪；新加的类型行从最近添加起步", () => {
  const libs = [lib(1, "录像 A", "video"), lib(2, "录像 B", "video")];
  const rows = buildHomeRows({ rows: [{ id: "kind:video", sort: "rating" }] }, libs, []);
  // 其他视频没有评分：回落到最近添加
  assert.equal(find(rows, "kind:video").sort, "added_at");
  const added = newMediaKindRow("video", libs, "row:new");
  assert.equal(added.builtin, false);
  assert.equal(rowTitle(added), "全部其他视频 · 最近添加");
  assert.deepEqual(rowsToPrefs([added]), [{ id: "row:new", media_kind: "video", sort: "added_at" }]);
});

test("类型色块行：出厂布局紧跟「我的媒体库」，只给有库的类型", () => {
  const rows = buildHomeRows({ rows: [] }, LIBS, COLS);
  assert.deepEqual(allIds(rows).slice(0, 5), [
    "up-next",
    "favorites",
    "libraries",
    "genres:movie",
    "genres:tv",
  ]);
  assert.equal(rowTitle(find(rows, "genres:movie")), "电影类型");
  assert.equal(rowTitle(find(rows, "genres:tv")), "剧集类型");
  assert.equal(rowMeta(find(rows, "genres:tv")), "内置 · 按类型浏览全部剧集（2 个库）");
  // 只有其他视频库：两条都不出现；剧集库全被排除出首页：剧集那条不出现
  const onlyVideo = buildHomeRows({ rows: [] }, [lib(9, "录像", "video")], []);
  assert.equal(onlyVideo.some((row) => row.kind === "genres"), false);
  const tvExcluded = buildHomeRows(
    { rows: [] },
    [lib(1, "电影"), lib(2, "剧集", "tv", { exclude_from_home: true })],
    [],
  );
  assert.deepEqual(
    tvExcluded.filter((row) => row.kind === "genres").map((row) => row.id),
    ["genres:movie"],
  );
});

test("类型色块行：老用户存过的清单里没有它们，升级后插在「我的媒体库」之后", () => {
  const prefs = {
    rows: [
      { id: "libraries" },
      { id: "lib:2" },
      { id: "row:nolan", collection_id: 8 },
      { id: "up-next" },
    ],
  };
  const rows = buildHomeRows(prefs, LIBS, COLS);
  assert.deepEqual(allIds(rows).slice(0, 4), ["libraries", "genres:movie", "genres:tv", "lib:2"]);
  // 一条库行都没存过时，新库的默认行排在类型色块行之后（与出厂布局同序）
  const bare = buildHomeRows({ rows: [{ id: "libraries" }, { id: "up-next" }] }, LIBS, COLS);
  assert.deepEqual(allIds(bare).slice(0, 6), [
    "libraries",
    "genres:movie",
    "genres:tv",
    "lib:1",
    "lib:2",
    "lib:3",
  ]);
});

test("类型色块行：存了就按存的位置与显隐，写回只带 id 与 hidden", () => {
  const prefs = {
    rows: [
      { id: "genres:tv", hidden: true },
      { id: "up-next" },
      { id: "genres:movie" },
    ],
  };
  const rows = buildHomeRows(prefs, LIBS, COLS);
  assert.deepEqual(allIds(rows).slice(0, 3), ["genres:tv", "up-next", "genres:movie"]);
  assert.equal(find(rows, "genres:tv").hidden, true);
  const saved = rowsToPrefs(rows);
  assert.deepEqual(saved.slice(0, 3), [
    { id: "genres:tv", hidden: true },
    { id: "up-next" },
    { id: "genres:movie" },
  ]);
  // 这一类型的库都没了：存过的行静默消失
  const noTv = buildHomeRows(prefs, [lib(1, "电影")], []);
  assert.equal(noTv.some((row) => row.id === "genres:tv"), false);
});
