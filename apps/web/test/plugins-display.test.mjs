import assert from "node:assert/strict";
import test from "node:test";

import {
  degradedHealth,
  formatMs,
  isLocalPlugin,
  isNewGrant,
  localPluginRuntimes,
  needsAttention,
  packageDetail,
  pathGrantLabel,
  pluginDetail,
  pluginStateLabel,
  pluginStateTone,
  pluginsSummary,
  runtimeLabel,
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

test("本地插件单独计数并可识别", () => {
  const list = [
    plugin({ id: "db" }),
    plugin({ id: "acme.cascade", source: "local" }),
    plugin({ id: "acme.watch", source: "local", state: "failed", error: "导入失败" }),
  ];
  assert.equal(isLocalPlugin(list[1]), true);
  assert.equal(isLocalPlugin(list[0]), false);
  assert.equal(pluginsSummary(list), "3 个模块 · 2 个运行中 · 1 个需要留意 · 其中 2 个是本地插件");
});

test("本地插件区分进程内与独立进程（旧服务端没有 runtime 按进程内算）", () => {
  const list = [
    plugin({ id: "db" }),
    plugin({ id: "acme.inline", source: "local" }),
    plugin({ id: "acme.proc", source: "local", runtime: "process" }),
    plugin({ id: "acme.proc2", source: "local", runtime: "process" }),
  ];
  assert.deepEqual(localPluginRuntimes(list), { inline: 1, process: 2 });
  assert.deepEqual(localPluginRuntimes([]), { inline: 0, process: 0 });
});

test("插件报告的降级算需要留意，并写进行内说明", () => {
  const healthy = plugin({ health: [{ key: "a", ok: true, message: "", action_href: null, since: "" }] });
  const degraded = plugin({
    health: [{ key: "trakt", ok: false, message: "Trakt 令牌已过期", action_href: null, since: "" }],
  });
  assert.equal(needsAttention(healthy), false);
  assert.equal(needsAttention(degraded), true);
  assert.deepEqual(degradedHealth(degraded), ["Trakt 令牌已过期"]);
  assert.equal(pluginDetail(degraded), "运行异常：Trakt 令牌已过期");
  // 旧服务端没有 health 字段
  assert.equal(needsAttention(plugin()), false);
});


test("路径授权与运行方式说清楚给人看", () => {
  assert.equal(pathGrantLabel({ path: "library", mode: "read" }), "全部媒体库（只读）");
  assert.equal(pathGrantLabel({ path: "library:3", mode: "rw" }), "媒体库 #3（读写）");
  assert.equal(pathGrantLabel({ path: "staging", mode: "rw" }), "导入规则的自定义目录（读写）");
  assert.equal(pathGrantLabel({ path: "/mnt/cloud", mode: "read" }), "/mnt/cloud（只读）");
  assert.equal(runtimeLabel("process"), "独立进程");
  assert.equal(runtimeLabel(undefined), "独立进程");
  assert.equal(runtimeLabel("inline"), "主进程（与主程序同权限）");
  assert.equal(isNewGrant({ path: "staging", mode: "rw" }, [{ path: "staging", mode: "rw" }]), true);
  assert.equal(isNewGrant({ path: "staging", mode: "read" }, [{ path: "staging", mode: "rw" }]), false);
});

test("已安装插件包的行内说明", () => {
  const item = {
    id: "acme.x",
    title: "X",
    version: "1.2.0",
    runtime: "process",
    operations: ["a.b"],
    operation_details: [],
    paths: [],
    previous_version: "1.0.0",
    bad_versions: ["1.1.0"],
    state: "active",
    error: null,
    watching: true,
  };
  assert.equal(
    packageDetail(item),
    "v1.2.0 · 独立进程 · 1 个宿主操作 · 刚安装，观察中 · 已拦下的坏版本：1.1.0",
  );
});
