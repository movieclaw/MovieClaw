import assert from "node:assert/strict";
import test from "node:test";

import { scopeEquals, scopeOfMediaKind, scopeOfTab, SCOPE_ALL } from "../lib/categories.ts";

test("详情页搜资源：剧集/电影收窄到对应内置分类", () => {
  for (const kind of ["tv", "movie"]) {
    const scope = scopeOfMediaKind(kind);
    assert.deepEqual(scope.categories, [kind]);
    // 与点内置分类标签的范围一致，结果页对应胶囊才会高亮
    assert.ok(scopeEquals(scope, scopeOfTab({ type: "category", id: kind, visible: true })));
  }
  assert.equal(scopeOfMediaKind("tv").label, "剧集");
  assert.equal(scopeOfMediaKind("movie").label, "电影");
});

test("库里的「其他」/图片不收窄", () => {
  assert.equal(scopeOfMediaKind("video"), SCOPE_ALL);
  assert.equal(scopeOfMediaKind("photo"), SCOPE_ALL);
});

test("详情页搜资源：英文界面补上服务端给的中文名，老服务端没有该字段时照旧", async () => {
  const { titleSearchAlso } = await import("../lib/search-url.ts");
  assert.deepEqual(titleSearchAlso("Forrest Gump", "Forrest Gump", "阿甘正传"), [
    "Forrest Gump",
    "阿甘正传",
    "Forrest Gump",
  ]);
  assert.deepEqual(titleSearchAlso("Forrest Gump", "Forrest Gump"), ["Forrest Gump", "Forrest Gump"]);
  assert.deepEqual(titleSearchAlso(null, "악인전", null), ["악인전"]);
});
