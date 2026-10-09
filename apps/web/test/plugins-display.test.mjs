import assert from "node:assert/strict";
import test from "node:test";

import {
  degradedHealth,
  displayState,
  offWithDependency,
  featureStatus,
  officialPlugins,
  officialSourceText,
  pluginLogsHref,
  pluginTier,
  systemModules,
  systemModulesLine,
  formatMs,
  groupBuiltins,
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
    title: "某插件",
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
  assert.equal(pluginsSummary(list), "4 个系统模块 · 1 个运行中 · 2 个需要留意 · 1 个已关闭");
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
});

test("等待依赖又说不出缺什么时，写等待所依赖的插件", () => {
  assert.equal(pluginDetail(plugin({ state: "pending" })), "等待所依赖的插件就绪");
});

test("分层：服务器给的为准；旧服务端没给时内置插件当系统模块，第三方不分层", () => {
  assert.equal(pluginTier(plugin({ tier: "feature" })), "feature");
  assert.equal(pluginTier(plugin()), "system");
  assert.equal(pluginTier(plugin({ source: "package" })), null);
  const list = [
    plugin({ id: "core.database", tier: "system" }),
    plugin({ id: "subtitle.gen", tier: "feature" }),
    plugin({ id: "old" }),
    plugin({ id: "acme.pkg", source: "package" }),
  ];
  assert.deepEqual(
    systemModules(list).map((p) => p.id),
    ["core.database", "old"],
  );
});

test("官方插件：随带通道与替换它的插件包都在；提供服务的中枢只在出问题时露面", () => {
  const hub = plugin({ id: "channels.hub", tier: "official", provides: ["channel-hub"] });
  const weixin = plugin({ id: "channel.weixin", tier: "official", title: "微信通道" });
  const replaced = plugin({ id: "channel.telegram", tier: "official", source: "package" });
  assert.deepEqual(
    officialPlugins([hub, weixin, replaced]).map((p) => p.id),
    ["channel.weixin", "channel.telegram"],
  );
  const brokenHub = { ...hub, state: "failed", error: "数据库不可用" };
  assert.deepEqual(
    officialPlugins([brokenHub, weixin]).map((p) => p.id),
    ["channels.hub", "channel.weixin"],
  );
  assert.equal(officialSourceText(weixin), "内置版本，可用插件包替换");
  assert.equal(officialSourceText(replaced), "已被插件包替换，在「第三方插件」里管理");
});

test("功能状态由组成插件汇总：任一出问题即异常并写明是谁，全部关闭才算关闭", () => {
  const feature = {
    key: "agent",
    title: "AI 助手",
    description: "",
    entries: ["agent.runs", "agent.attachments"],
    settings_href: "/settings/ai",
  };
  const runs = plugin({ id: "agent.runs", title: "Agent 运行注册表" });
  const attachments = plugin({ id: "agent.attachments", title: "Agent 附件暂存清理" });
  assert.deepEqual(featureStatus(feature, [runs, attachments, plugin({ id: "other" })]), {
    label: "运行中",
    tone: "ok",
    detail: null,
  });
  const failed = { ...attachments, state: "failed", error: "磁盘只读" };
  assert.deepEqual(featureStatus(feature, [runs, failed]), {
    label: "启动失败",
    tone: "danger",
    detail: "Agent 附件暂存清理：磁盘只读",
  });
  const degraded = {
    ...runs,
    health: [{ key: "k", ok: false, message: "模型不可用", action_href: null, since: "" }],
  };
  assert.equal(featureStatus(feature, [degraded, attachments]).label, "运行异常");
  const off = (p) => ({ ...p, state: "disabled", disabled_by: "patch" });
  assert.equal(featureStatus(feature, [off(runs), off(attachments)]).label, "已关闭");
  assert.deepEqual(featureStatus(feature, [off(runs), attachments]), {
    label: "部分关闭",
    tone: "neutral",
    detail: "Agent 运行注册表：已在插件补丁（data/plugins.yaml）中关闭",
  });
  assert.equal(featureStatus(feature, []).label, "未加载");
  // 子插件跟着父插件算
  const child = plugin({ id: "agent.runs.child", parent: "agent.runs", state: "failed" });
  assert.equal(featureStatus(feature, [runs, attachments, child]).tone, "danger");
});

test("依赖被有意关掉时跟着关闭：不算需要留意，显示为已关闭并写明依赖谁", () => {
  const sentinel = plugin({
    id: "boost.sentinel",
    state: "pending",
    blocked_by: [
      {
        key: "scheduler",
        reason: "提供方 scheduler 状态为 disabled",
        provider: "scheduler",
        provider_state: "disabled",
      },
    ],
  });
  assert.equal(offWithDependency(sentinel), true);
  assert.equal(needsAttention(sentinel), false);
  assert.equal(displayState(sentinel), "disabled");
  assert.equal(pluginDetail(sentinel), "依赖的 scheduler 已关闭，跟着停用");
  // 依赖坏了（失败）、旧服务端没给结构化字段：仍是等待依赖、需要留意
  const broken = plugin({
    state: "pending",
    blocked_by: [{ key: "db", reason: "提供方 core.database 状态为 failed", provider: "core.database", provider_state: "failed" }],
  });
  const legacy = plugin({ state: "pending", blocked_by: [{ key: "scheduler", reason: "提供方 scheduler 状态为 disabled" }] });
  assert.equal(needsAttention(broken), true);
  assert.equal(needsAttention(legacy), true);
  assert.equal(displayState(broken), "pending");
});

test("系统模块入口一行：正常 / 有几个需要留意；日志深链按条目 id 筛", () => {
  const list = [plugin({ id: "a" }), plugin({ id: "b" })];
  assert.deepEqual(systemModulesLine(list), { text: "另有 2 个系统模块，运行正常", tone: "ok" });
  const broken = [plugin({ id: "a" }), plugin({ id: "b", state: "failed" })];
  assert.deepEqual(systemModulesLine(broken), {
    text: "另有 2 个系统模块，其中 1 个需要留意",
    tone: "warn",
  });
  assert.equal(pluginLogsHref(plugin({ id: "core.database" })), "/settings/logs?q=core.database");
});

test("内置插件按服务器给的组序分组，组内需要留意的在前；没归属的进「其他」，非内置的不进", () => {
  const list = [
    plugin({ id: "core.database", group: "基础" }),
    plugin({ id: "downloads", group: "资源站点与下载" }),
    plugin({ id: "jobs", group: "基础", state: "failed" }),
    plugin({ id: "mystery" }),
    plugin({ id: "acme.watch", source: "local" }),
    plugin({ id: "acme.pkg", source: "package" }),
  ];
  const groups = groupBuiltins(list, ["基础", "订阅", "资源站点与下载"]);
  assert.deepEqual(
    groups.map((g) => [g.label, g.plugins.map((p) => p.id)]),
    [
      ["基础", ["jobs", "core.database"]],
      ["资源站点与下载", ["downloads"]],
      ["其他", ["mystery"]],
    ],
  );
  // 旧服务端没有分组：全部收进「其他」
  assert.deepEqual(
    groupBuiltins(list).map((g) => g.label),
    ["其他"],
  );
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
  // 替换随带内置插件的包：说清卸载即恢复
  assert.equal(
    packageDetail({ ...item, operations: [], watching: false, bad_versions: [], replaces_builtin: true }),
    "v1.2.0 · 独立进程 · 替换了内置版本，卸载即恢复",
  );
});
