import assert from "node:assert/strict";
import test from "node:test";

import {
  formatMs,
  needsAttention,
  pluginDetail,
  pluginStateLabel,
  pluginStateTone,
  pluginsSummary,
  slowestStarts,
  sortPlugins,
} from "../lib/plugins-display.ts";

function plugin(overrides = {}) {
  return {
    id: "x",
    plugin: "x",
    title: "某模块",
    state: "active",
    critical: false,
    disableable: false,
    reloadable: false,
    source: "builtin",
    parent: null,
    provides: [],
    inject: [],
    blocked_by: [],
    incompatible: null,
    disabled_by: null,
    error: null,
    apply_ms: 12.3,
    dispose_ms: null,
    unsettled: false,
    stats: {
      events: 0,
      failures: 0,
      timeouts: 0,
      dropped: 0,
      handler_max_ms: 0,
      handler_avg_ms: 0,
      last_error: null,
      tasks: 0,
      listeners: 0,
      breaker: "closed",
    },
    ...overrides,
  };
}

test("状态文案与颜色：失败红、等待黄、关闭灰、运行绿", () => {
  assert.equal(pluginStateLabel("failed"), "启动失败");
  assert.equal(pluginStateTone("failed"), "danger");
  assert.equal(pluginStateTone("pending"), "warn");
  assert.equal(pluginStateTone("disabled"), "neutral");
  assert.equal(pluginStateTone("active"), "ok");
});

test("失败写原因、等待写缺什么、关闭写谁关的", () => {
  assert.equal(
    pluginDetail(plugin({ state: "failed", error: "ConnectionError: 网关不可达" })),
    "ConnectionError: 网关不可达",
  );
  assert.equal(
    pluginDetail(
      plugin({
        state: "pending",
        blocked_by: [{ key: "scheduler", reason: "提供方 scheduler 状态为 disabled" }],
      }),
    ),
    "缺少 scheduler：提供方 scheduler 状态为 disabled",
  );
  assert.equal(
    pluginDetail(plugin({ state: "disabled", disabled_by: "env:SCHEDULER_ENABLED" })),
    "已按环境变量 SCHEDULER_ENABLED 关闭",
  );
  assert.equal(
    pluginDetail(plugin({ state: "disabled", disabled_by: "patch" })),
    "已在插件补丁（data/plugins.yaml）中关闭",
  );
});

test("运行中写启动耗时，有后台任务、运行中出错也写上", () => {
  assert.equal(pluginDetail(plugin()), "启动 12 毫秒");
  const busy = plugin({ apply_ms: 1880, stats: { ...plugin().stats, tasks: 2, failures: 1 } });
  assert.equal(pluginDetail(busy), "启动 1.9 秒 · 2 个后台任务 · 运行中出错 1 次");
});

test("耗时格式：毫秒取整，秒保留一位，十秒以上取整", () => {
  assert.equal(formatMs(0.4), "0 毫秒");
  assert.equal(formatMs(999.6), "1000 毫秒");
  assert.equal(formatMs(1234), "1.2 秒");
  assert.equal(formatMs(12_345), "12 秒");
});

test("需要留意的排在前面，其余保持启动顺序；关闭不算需要留意", () => {
  const list = [
    plugin({ id: "a" }),
    plugin({ id: "b", state: "disabled" }),
    plugin({ id: "c", state: "failed" }),
    plugin({ id: "d", state: "pending" }),
  ];
  assert.deepEqual(
    sortPlugins(list).map((p) => p.id),
    ["c", "d", "a", "b"],
  );
  assert.equal(needsAttention(list[1]), false);
  assert.equal(pluginsSummary(list), "4 个模块 · 1 个运行中 · 2 个需要留意 · 1 个已关闭");
});

test("启动最慢只列 100 毫秒以上的前几名", () => {
  const list = [
    plugin({ id: "db", title: "数据库", apply_ms: 1880 }),
    plugin({ id: "fast", apply_ms: 5 }),
    plugin({ id: "eg", title: "网络出口", apply_ms: 292 }),
    plugin({ id: "none", apply_ms: null }),
  ];
  assert.deepEqual(
    slowestStarts(list).map((p) => p.id),
    ["db", "eg"],
  );
});
