import assert from "node:assert/strict";
import test from "node:test";

import {
  activeAppNavId,
  appHref,
  appNavItems,
  frameSrc,
  hostPathFromFrame,
  parseAppPath,
  pruneAppNavIds,
  withoutHidden,
} from "../lib/plugin-apps.ts";

const BOARD = {
  id: "stats-board",
  name: "统计看板",
  nav: true,
  base: "/api/v1/plugins/stats-board/web/",
  entries: [
    { label: "看板", path: "", icon: "/api/v1/plugins/stats-board/web/i.svg", monochrome: true },
    { label: "下载统计", path: "downloads", icon: null, monochrome: false },
    { label: "按周", path: "downloads/weekly?unit=w", icon: null, monochrome: false },
  ],
};

test("侧边栏项：每个入口一项，地址指到 /apps/<id>/<子路径>，没同意加侧栏的不出", () => {
  const items = appNavItems([BOARD, { ...BOARD, id: "quiet", nav: false }]);
  assert.deepEqual(
    items.map((i) => [i.id, i.label, i.href]),
    [
      ["app:stats-board:0", "看板", "/apps/stats-board"],
      ["app:stats-board:1", "下载统计", "/apps/stats-board/downloads"],
      ["app:stats-board:2", "按周", "/apps/stats-board/downloads/weekly?unit=w"],
    ],
  );
  assert.equal(items[0].monochrome, true);
});

test("移出侧边栏只对应用项生效，内置项不会被藏掉", () => {
  const items = [{ id: "library" }, { id: "app:stats-board:1" }, { id: "app:stats-board:0" }];
  assert.deepEqual(
    withoutHidden(items, ["library", "app:stats-board:1"]).map((i) => i.id),
    ["library", "app:stats-board:0"],
  );
  assert.equal(withoutHidden(items, null), items);
});

test("高亮取最长前缀匹配，按路径段对齐；匹配不到点亮主入口", () => {
  const apps = [BOARD];
  assert.equal(activeAppNavId("/apps/stats-board/", apps), "app:stats-board:0");
  assert.equal(activeAppNavId("/apps/stats-board/downloads", apps), "app:stats-board:1");
  assert.equal(activeAppNavId("/apps/stats-board/downloads/2026-10", apps), "app:stats-board:1");
  assert.equal(activeAppNavId("/apps/stats-board/downloads/weekly", apps), "app:stats-board:2");
  assert.equal(activeAppNavId("/apps/stats-board/downloads-old", apps), "app:stats-board:0");
  assert.equal(activeAppNavId("/apps/other/", apps), null);
  assert.equal(activeAppNavId("/library", apps), null);
});

test("地址换算：主程序地址 ↔ iframe 地址", () => {
  assert.deepEqual(parseAppPath("/apps/stats-board/downloads/x"), {
    appId: "stats-board",
    sub: "downloads/x",
  });
  assert.deepEqual(parseAppPath("/apps/acme.hello"), { appId: "acme.hello", sub: "" });
  assert.equal(parseAppPath("/apps/"), null);
  assert.equal(appHref("acme.hello", "/a"), "/apps/acme.hello/a");
  // 根目录就是 web/ 本身（单页应用的路由看到的是干净的根路径）；落在 index.html 上也认作主入口
  assert.equal(frameSrc(BOARD.base, "", "?x=1"), "/api/v1/plugins/stats-board/web/?x=1");
  assert.equal(
    hostPathFromFrame("stats-board", BOARD.base, {
      pathname: "/api/v1/plugins/stats-board/web/index.html",
      search: "",
      hash: "",
    }),
    "/apps/stats-board",
  );
  assert.equal(
    frameSrc(BOARD.base, "downloads", "?unit=w", "#top"),
    "/api/v1/plugins/stats-board/web/downloads?unit=w#top",
  );
  assert.equal(
    hostPathFromFrame("stats-board", BOARD.base, {
      pathname: "/api/v1/plugins/stats-board/web/downloads/2026",
      search: "?a=1",
      hash: "",
    }),
    "/apps/stats-board/downloads/2026?a=1",
  );
  // 跳出网页根目录（没写 target="_top" 的站内链接）
  assert.equal(
    hostPathFromFrame("stats-board", BOARD.base, { pathname: "/library", search: "", hash: "" }),
    null,
  );
  // 根地址没有结尾斜杠也认（服务端会 308 补上）
  assert.equal(
    hostPathFromFrame("stats-board", BOARD.base, {
      pathname: "/api/v1/plugins/stats-board/web",
      search: "",
      hash: "",
    }),
    "/apps/stats-board",
  );
});

test("保存导航偏好时清掉已卸载插件的项；插件列表还没拉到时一项不删", () => {
  const saved = ["library", "app:gone:0", "app:stats-board:1", "tasks"];
  const known = new Set(["app:stats-board:0", "app:stats-board:1"]);
  assert.deepEqual(pruneAppNavIds(saved, known), ["library", "app:stats-board:1", "tasks"]);
  assert.deepEqual(pruneAppNavIds(saved, null), saved);
});
