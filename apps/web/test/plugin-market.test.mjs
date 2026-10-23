import assert from "node:assert/strict";
import test from "node:test";

import {
  canInstallVersion,
  filterMarket,
  installVerb,
  marketAction,
  marketCategories,
  pendingUpdates,
  permissionLines,
  shownVersion,
  feedbackLink,
  formatDownloadCount,
  versionBadges,
  versionMeta,
} from "../lib/plugin-market.ts";

function version(overrides = {}) {
  return {
    version: "1.0.0",
    prerelease: false,
    released_at: "2026-10-20T00:00:00Z",
    yanked: null,
    notes: "",
    changelog_url: null,
    source_url: null,
    runtime: "process",
    requires: {},
    permissions: { operations: [], paths: [], network: false, callbacks: [], events: [] },
    web: false,
    dependencies: [],
    size: 46375,
    compatible: true,
    incompatible_reason: null,
    ...overrides,
  };
}

function plugin(overrides = {}) {
  return {
    id: "cloud-115",
    name: "115 网盘",
    summary: "把 115 网盘接进媒体库",
    description: "",
    category: "storage",
    author: { name: "MovieClaw", url: null },
    homepage: null,
    repository: null,
    license: "MIT",
    icon_url: null,
    deprecated: null,
    latest: "1.0.0",
    recommended: "1.0.0",
    installed: null,
    update: null,
    blocked: null,
    versions: [version()],
    ...overrides,
  };
}

test("主操作：安装、更新、已安装、随应用提供、被占用、装不了", () => {
  assert.deepEqual(marketAction(plugin()), {
    kind: "install",
    label: "安装",
    version: "1.0.0",
    note: null,
  });
  const installed = { version: "1.0.0", source: "package", state: "active", previous_version: null, yanked: null };
  assert.equal(marketAction(plugin({ installed })).kind, "installed");
  assert.deepEqual(marketAction(plugin({ installed, update: "1.1.0" })), {
    kind: "update",
    label: "更新",
    version: "1.1.0",
    note: null,
  });
  assert.equal(marketAction(plugin({ installed: { ...installed, source: "bundled" } })).note, "随应用提供");
  assert.equal(marketAction(plugin({ blocked: "被占用" })).note, "被占用");
  const broken = plugin({
    recommended: null,
    versions: [version({ compatible: false, incompatible_reason: "需要更新 MovieClaw：未知契约 x" })],
  });
  assert.deepEqual(marketAction(broken), {
    kind: "incompatible",
    label: "",
    version: null,
    note: "需要更新 MovieClaw：未知契约 x",
  });
  assert.equal(marketAction(plugin({ recommended: null, versions: [version({ yanked: "坏了" })] })).kind, "unavailable");
});

test("分类筛选条只列有插件的分类，单一分类不出筛选条", () => {
  assert.deepEqual(marketCategories([plugin()]), []);
  const list = [plugin(), plugin({ id: "tg", category: "messaging" }), plugin({ id: "x", category: "games" })];
  assert.deepEqual(
    marketCategories(list).map((c) => c.label),
    ["全部", "网盘", "消息通道", "其他"],
  );
});

test("搜索看名称、id、简介、作者", () => {
  const list = [plugin(), plugin({ id: "tg", name: "Telegram 通道", summary: "bot", author: { name: "Alice", url: null } })];
  assert.equal(filterMarket(list, { category: "all", query: "alice" }).length, 1);
  assert.equal(filterMarket(list, { category: "all", query: "115" })[0].id, "cloud-115");
  assert.equal(filterMarket(list, { category: "messaging", query: "" }).length, 0);
  assert.equal(filterMarket(list, { category: "storage", query: " " }).length, 2);
});

test("版本标记与能不能装这一版", () => {
  const p = plugin({
    installed: { version: "1.0.0", source: "package", state: "active", previous_version: null, yanked: null },
  });
  assert.deepEqual(versionBadges(version(), p).map((b) => b.label), ["当前安装"]);
  assert.deepEqual(
    versionBadges(version({ version: "2.0.0-beta.1", prerelease: true, yanked: "坏", compatible: false }), p).map((b) => b.label),
    ["测试版", "已撤回", "装不了"],
  );
  assert.equal(canInstallVersion(version(), p), false);
  assert.equal(canInstallVersion(version({ version: "0.9.0" }), p), true);
  assert.equal(canInstallVersion(version({ version: "0.9.0", yanked: "x" }), p), false);
});

test("升级还是换回", () => {
  const p = plugin({
    versions: [version({ version: "2.0.0" }), version({ version: "1.0.0" }), version({ version: "0.9.0" })],
    installed: { version: "1.0.0", source: "package", state: "active", previous_version: null, yanked: null },
  });
  assert.equal(installVerb("2.0.0", p), "升级到这一版");
  assert.equal(installVerb("0.9.0", p), "换回这一版");
  assert.equal(installVerb("2.0.0", plugin()), "安装");
});

test("权限翻成人话：高风险在前", () => {
  const lines = permissionLines(
    version({
      runtime: "inline",
      web: true,
      permissions: {
        operations: ["library.strm.probe"],
        paths: [{ path: "/downloads", mode: "read" }],
        network: true,
        callbacks: [],
        events: ["playback.started"],
      },
      dependencies: [{ name: "lz4", version: "4.4.5", native: true }],
    }),
  );
  assert.deepEqual(
    lines.map((l) => l.title),
    ["在主进程里运行", "知道谁在什么时候看了什么", "带网页", "调用 1 项宿主操作", "只读目录", "访问互联网", "安装时下载 1 个第三方包"],
  );
  assert.equal(lines[0].tone, "danger");
  assert.match(lines.at(-1).detail, /含本机代码：lz4/);
  assert.deepEqual(
    permissionLines(version()).map((l) => l.title),
    ["在独立进程里运行", "不申请其他权限"],
  );
});

test("卡片版本与可更新列表", () => {
  const p = plugin({
    versions: [version({ version: "1.1.0", size: 2048 }), version()],
    installed: { version: "1.0.0", source: "package", state: "active", previous_version: null, yanked: null },
    update: "1.1.0",
  });
  assert.equal(shownVersion(p).version, "1.1.0");
  assert.equal(versionMeta(shownVersion(p)), "v1.1.0 · 2.00 KB");
  assert.equal(versionMeta(shownVersion(p), 12800), "v1.1.0 · 2.00 KB · 1.3万 次下载");
  assert.deepEqual(pendingUpdates([p, plugin()]).map((x) => x.id), ["cloud-115"]);
});

test("下载次数：没有就不显示，万以下分组，再往上紧凑", () => {
  assert.equal(formatDownloadCount(null), null);
  assert.equal(formatDownloadCount(undefined), null);
  assert.equal(formatDownloadCount(-1), null);
  assert.equal(formatDownloadCount(0), "0 次下载");
  assert.equal(formatDownloadCount(1200), "1,200 次下载");
  assert.equal(formatDownloadCount(12800), "1.3万 次下载");
});

test("反馈链接：官方表单补版本，作者仓库原样打开，没有地址就藏起来", () => {
  const form =
    "https://github.com/movieclaw/movieclaw-plugins/issues/new?template=plugin.yml&plugin=cloud-115";
  const installed = { version: "1.2.3", source: "package", state: "active", previous_version: null, yanked: null };
  const href = feedbackLink(
    plugin({ feedback_url: form, latest: "9.9.9", installed }),
    "0.42.0",
  );
  const url = new URL(href);
  assert.equal(url.searchParams.get("template"), "plugin.yml");
  assert.equal(url.searchParams.get("plugin"), "cloud-115");
  assert.equal(url.searchParams.get("plugin_version"), "1.2.3");
  assert.equal(url.searchParams.get("movieclaw_version"), "0.42.0");

  const latest = feedbackLink(plugin({ feedback_url: form, latest: "2.0.0", installed: null }), null);
  const latestUrl = new URL(latest);
  assert.equal(latestUrl.searchParams.get("plugin_version"), "2.0.0");
  assert.equal(latestUrl.searchParams.get("movieclaw_version"), null);

  assert.equal(
    feedbackLink(plugin({ feedback_url: "https://github.com/acme/cloud-115/issues", homepage: null }), "0.42.0"),
    "https://github.com/acme/cloud-115/issues",
  );
  assert.equal(
    feedbackLink(
      plugin({ feedback_url: null, homepage: "https://github.com/acme/cloud-115" }),
      "0.42.0",
    ),
    "https://github.com/acme/cloud-115/issues/new",
  );
  assert.equal(
    feedbackLink(
      plugin({
        feedback_url: null,
        homepage: "https://github.com/movieclaw/movieclaw-plugins",
        latest: "1.0.0",
      }),
      "0.42.0",
    ),
    "https://github.com/movieclaw/movieclaw-plugins/issues/new?plugin_version=1.0.0&movieclaw_version=0.42.0",
  );
  assert.equal(
    feedbackLink(
      plugin({ feedback_url: null, homepage: "https://github.com/acme/cloud-115/tree/main" }),
      "0.42.0",
    ),
    null,
  );
  assert.equal(feedbackLink(plugin({ feedback_url: "javascript:alert(1)", homepage: null }), "0.42.0"), null);
  assert.equal(feedbackLink(plugin({ feedback_url: null, homepage: null }), "0.42.0"), null);
});
