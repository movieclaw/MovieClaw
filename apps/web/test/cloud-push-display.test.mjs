import assert from "node:assert/strict";
import test from "node:test";

import {
  attentionLine,
  authModeLabel,
  capabilityRows,
  channelDetails,
  channelDeviceCount,
  channelPill,
  cloudInstancesUrl,
  cloudReportsInfoUrl,
  cloudSiteOrigin,
  connectedAccountLine,
  devicePushNote,
  displayHost,
  displayUrl,
  formatCountdown,
  groupEvents,
  healthMessage,
  healthTone,
  libraryChecked,
  myDeviceTone,
  noticeTone,
  pairingFailureText,
  quotaLabel,
  quotaPercent,
  quotaTone,
  relayAddBlocker,
  relayNameFromUrl,
  secondsLeft,
  summarizePushTest,
  testTargetHint,
  toggleLibrary,
  uncoveredSummary,
} from "../lib/cloud-push-display.ts";

test("官网地址：云端 API 地址去掉开头的 api.，协议和端口保留", () => {
  assert.equal(cloudSiteOrigin("https://api.movieclaw.io"), "https://movieclaw.io");
  assert.equal(cloudSiteOrigin("https://api.movieclaw.io/"), "https://movieclaw.io");
  assert.equal(cloudSiteOrigin("https://api.staging.example.com/v1"), "https://staging.example.com");
  assert.equal(cloudSiteOrigin("http://api.localhost:8787"), "http://localhost:8787");
  // 不是 api. 开头的（开发者自己的云端）原样用
  assert.equal(cloudSiteOrigin("http://192.168.1.20:8080"), "http://192.168.1.20:8080");
  // 只去掉开头那一段，中间的 api 不动
  assert.equal(cloudSiteOrigin("https://myapi.example.com"), "https://myapi.example.com");
});

test("官网地址：解析不出来时回落到 movieclaw.io", () => {
  assert.equal(cloudSiteOrigin(""), "https://movieclaw.io");
  assert.equal(cloudSiteOrigin(null), "https://movieclaw.io");
  assert.equal(cloudSiteOrigin("不是地址"), "https://movieclaw.io");
  assert.equal(cloudSiteOrigin("javascript:alert(1)"), "https://movieclaw.io");
});

test("「在官网管理」指向官网的服务器列表", () => {
  assert.equal(cloudInstancesUrl("https://api.movieclaw.io"), "https://movieclaw.io/instances");
  assert.equal(
    cloudReportsInfoUrl("https://api.movieclaw.io"),
    "https://movieclaw.io/zh/privacy#server-reports",
  );
});

test("链接给人读的样子去掉协议头和末尾斜杠", () => {
  assert.equal(displayUrl("https://movieclaw.io/activate"), "movieclaw.io/activate");
  assert.equal(displayUrl("https://movieclaw.io/"), "movieclaw.io");
  assert.equal(displayHost("https://movieclaw.io/activate?code=WDJB-MJHT"), "movieclaw.io");
});

test("账号标识为空时不硬造账号名，也绝不说「登录」「绑定」", () => {
  assert.equal(
    connectedAccountLine("y•••@gmail.com"),
    "已连接到 y•••@gmail.com 的 MovieClaw 账号",
  );
  assert.equal(connectedAccountLine(""), "已连接到你的 MovieClaw 账号");
  assert.equal(connectedAccountLine(null), "已连接到你的 MovieClaw 账号");
  for (const line of [connectedAccountLine("a"), connectedAccountLine(null)]) {
    assert.ok(!line.includes("登录") && !line.includes("绑定"), line);
  }
});

test("配对码倒计时：向上取整到秒，过期为 0，读数是 分:秒", () => {
  const now = Date.parse("2026-10-03T08:00:00Z");
  assert.equal(secondsLeft("2026-10-03T08:09:41Z", now), 581);
  assert.equal(secondsLeft("2026-10-03T08:00:00.400Z", now), 1);
  assert.equal(secondsLeft("2026-10-03T07:59:00Z", now), 0);
  assert.equal(secondsLeft("坏时间", now), 0);
  assert.equal(formatCountdown(581), "9:41");
  assert.equal(formatCountdown(60), "1:00");
  assert.equal(formatCountdown(5), "0:05");
  assert.equal(formatCountdown(-3), "0:00");
});

test("配对失败：优先用服务端的话，没有再按状态补", () => {
  assert.equal(pairingFailureText("denied", "管理员拒绝了这次连接"), "管理员拒绝了这次连接");
  assert.equal(pairingFailureText("expired", null), "配对码已过期。");
  assert.ok(pairingFailureText("denied", "  ").includes("拒绝"));
  assert.ok(pairingFailureText("error", null).includes("重新获取配对码"));
});

test("连接健康：续签失败但令牌有效是黄，过期和版本不受支持是红，正常不出横幅", () => {
  assert.equal(healthTone("ok"), null);
  assert.equal(healthTone(null), null);
  assert.equal(healthTone("unreachable"), "warn");
  assert.equal(healthTone("expired"), "danger");
  assert.equal(healthTone("unsupported"), "danger");
  assert.equal(healthMessage("expired", "令牌已过期"), "令牌已过期");
  assert.ok(healthMessage("unsupported", null).includes("升级"));
  assert.equal(healthMessage("ok", null), "");
});

test("服务通知只有 info / warning 两档", () => {
  assert.equal(noticeTone("warning"), "warn");
  assert.equal(noticeTone("info"), "info");
  assert.equal(noticeTone("别的"), "info");
});

test("能力清单完全按数据渲染：官方推送打头，没授予的标即将推出，云端没有的不写", () => {
  assert.deepEqual(capabilityRows(["push"], ["push"]), [
    { id: "push", label: "官方推送", granted: true },
  ]);
  assert.deepEqual(capabilityRows(["push"], ["push", "remote"]), [
    { id: "push", label: "官方推送", granted: true },
    { id: "remote", label: "远程访问", granted: false },
  ]);
  // 官方推送没授予也要写明
  assert.deepEqual(capabilityRows([], []), [{ id: "push", label: "官方推送", granted: false }]);
  // 不认识的能力原样显示 id，不重复
  assert.deepEqual(
    capabilityRows(["push", "x"], ["x", "push", "y"]).map((r) => [r.id, r.granted]),
    [
      ["push", true],
      ["x", true],
      ["y", false],
    ],
  );
});

test("官方通道没连接云时显示「未激活」，其余用后端的状态文字和对应色调", () => {
  const official = { kind: "official", state: "inactive", status_text: "未连接 MovieClaw Cloud" };
  assert.deepEqual(channelPill(official, "disconnected"), { tone: "neutral", label: "未激活" });
  assert.deepEqual(channelPill(official, "pairing"), { tone: "neutral", label: "未激活" });
  // 已连接但停用：用后端的话
  assert.deepEqual(
    channelPill({ kind: "official", state: "inactive", status_text: "已停用" }, "connected"),
    { tone: "neutral", label: "已停用" },
  );
  assert.deepEqual(
    channelPill({ kind: "custom", state: "warning", status_text: "今天的 5000 条已用完" }, "connected"),
    { tone: "warn", label: "今天的 5000 条已用完" },
  );
  assert.deepEqual(channelPill({ kind: "custom", state: "error", status_text: "" }, "connected"), {
    tone: "danger",
    label: "出错了",
  });
  assert.deepEqual(channelPill({ kind: "custom", state: "ok", status_text: "正常" }, "connected"), {
    tone: "ok",
    label: "正常",
  });
});

test("通道细节：地址 · 鉴权方式 · Bundle ID，缺的段不写", () => {
  assert.equal(
    channelDetails({
      kind: "custom",
      url: "https://push.home.example",
      auth_mode: "static",
      topics: ["com.yi.movieclaw"],
    }),
    "https://push.home.example\u00a0· 令牌\u00a0· com.yi.movieclaw",
  );
  assert.equal(
    channelDetails({ kind: "custom", url: "http://192.168.1.2:8080", auth_mode: null, topics: [] }),
    "http://192.168.1.2:8080",
  );
  // 官方通道的地址、鉴权和 Bundle ID 都由云端决定，不展示
  assert.equal(
    channelDetails({
      kind: "official",
      url: "https://push.movieclaw.io",
      auth_mode: "issuer",
      topics: ["io.movieclaw.app"],
    }),
    "",
  );
  assert.equal(authModeLabel("issuer"), "签发方令牌");
  assert.equal(authModeLabel("none"), "无鉴权");
  assert.equal(authModeLabel(null), null);
});

test("额度条：按比例画，用过就至少 1%，最多 100%；剩不到 5% 转黄", () => {
  assert.equal(quotaPercent({ limit: 5000, used: 0 }), 0);
  assert.equal(quotaPercent({ limit: 5000, used: 3 }), 1);
  assert.equal(quotaPercent({ limit: 5000, used: 2500 }), 50);
  assert.equal(quotaPercent({ limit: 5000, used: 6000 }), 100);
  assert.equal(quotaLabel({ limit: 5000, used: 132 }), "今天已用 132 / 5000 条");
  assert.equal(quotaLabel({ limit: 5000, used: 5000 }), "今天的 5000 条已用完");
  assert.equal(quotaTone({ limit: 5000, used: 132 }), null);
  assert.equal(quotaTone({ limit: 5000, used: 4800 }), "warn");
});

test("额度缺一半时只写读数不画条，都没有就整块不显示", () => {
  // 官方通道还没推送过：只有云端给的每日上限
  assert.equal(quotaPercent({ limit: 5000, used: null }), null);
  assert.equal(quotaLabel({ limit: 5000, used: null }), "每天最多 5000 条");
  assert.equal(quotaTone({ limit: 5000, used: null }), null);
  // 不限额的中继
  assert.equal(quotaPercent({ limit: null, used: 12 }), null);
  assert.equal(quotaLabel({ limit: null, used: 12 }), "今天已用 12 条");
  assert.equal(quotaPercent({ limit: 0, used: 10 }), null);
  assert.equal(quotaLabel({ limit: null, used: null }), null);
});

test("添加中继：检测结果决定能不能保存", () => {
  const base = { probedUrl: "https://push.home.example", url: "https://push.home.example", token: "", name: "书房" };
  assert.equal(relayAddBlocker({ ...base, probe: null }), "先检测中继地址");
  // 检测后又改了地址：结果作废
  assert.equal(
    relayAddBlocker({ ...base, url: "https://other.example", probe: { reachable: true, auth_mode: "none" } }),
    "先检测中继地址",
  );
  assert.ok(
    relayAddBlocker({ ...base, probe: { reachable: false, auth_mode: null, error: "超时" } }).includes(
      "连不上",
    ),
  );
  // 连上了但加不了：用服务端给的原因
  assert.equal(
    relayAddBlocker({
      ...base,
      probe: { reachable: true, auth_mode: "static", error: "中继的协议版本是 2，这个版本只支持 1" },
    }),
    "中继的协议版本是 2，这个版本只支持 1",
  );
  assert.equal(
    relayAddBlocker({ ...base, probe: { reachable: true, auth_mode: "issuer" } }),
    "这个中继需要签发方的令牌，暂不支持在这里添加",
  );
  assert.equal(
    relayAddBlocker({ ...base, probe: { reachable: true, auth_mode: "static" } }),
    "填写中继的令牌",
  );
  assert.equal(
    relayAddBlocker({ ...base, token: "mcpush_x", probe: { reachable: true, auth_mode: "static" } }),
    null,
  );
  // 不认识的鉴权方式也要令牌（中继协议第 3 节：照样带上配置的令牌）
  assert.equal(
    relayAddBlocker({ ...base, probe: { reachable: true, auth_mode: "oauth" } }),
    "填写中继的令牌",
  );
  // none 不用令牌
  assert.equal(relayAddBlocker({ ...base, probe: { reachable: true, auth_mode: "none" } }), null);
  assert.equal(
    relayAddBlocker({ ...base, name: " ", probe: { reachable: true, auth_mode: "none" } }),
    "给中继起个名字",
  );
  // 地址两端的空白不算改过
  assert.equal(
    relayAddBlocker({ ...base, url: " https://push.home.example ", probe: { reachable: true, auth_mode: "none" } }),
    null,
  );
  assert.equal(relayNameFromUrl("https://push.home.example:8443/"), "push.home.example");
  assert.equal(relayNameFromUrl("坏地址"), "");
});

test("事件按 group 分组，组与组内顺序照后端给的", () => {
  const events = [
    { key: "imported", group: "我的订阅" },
    { key: "new_device", group: "账号安全" },
    { key: "download_started", group: "我的订阅" },
  ];
  assert.deepEqual(
    groupEvents(events).map((g) => [g.group, g.items.map((e) => e.key)]),
    [
      ["我的订阅", ["imported", "download_started"]],
      ["账号安全", ["new_device"]],
    ],
  );
});

test("App 推送：通道上的设备数，0 台不写", () => {
  assert.equal(channelDeviceCount(3), "3 台设备");
  assert.equal(channelDeviceCount(0), null);
});

test("App 推送：没有缺口什么都不提示，有缺口说清几台、哪个 App", () => {
  assert.equal(uncoveredSummary([]), null);
  assert.equal(
    uncoveredSummary([{ topic: "com.friend.mc", device_count: 1 }]),
    "有 1 台设备用的是自己打包的 App（com.friend.mc），没有能推送它的通道",
  );
  assert.equal(
    uncoveredSummary([
      { topic: "com.a", device_count: 2 },
      { topic: "com.b", device_count: 1 },
    ]),
    "有 3 台设备用的是自己打包的 App（com.a、com.b），没有能推送它的通道",
  );
});

test("设备页：能收到或不是 App 什么都不写，收不到写原因并按状态上色", () => {
  assert.equal(devicePushNote(null), null);
  assert.equal(devicePushNote({ status: "ok", status_text: "能收到" }), null);
  assert.deepEqual(devicePushNote({ status: "permission_denied", status_text: "系统通知已关闭" }), {
    tone: "warn",
    text: "系统通知已关闭",
  });
  assert.equal(devicePushNote({ status: "bad_token", status_text: "" }).tone, "danger");
  assert.ok(devicePushNote({ status: "bad_token", status_text: "" }).text.includes("重新登记"));
  assert.equal(devicePushNote({ status: "not_registered", status_text: "" }).tone, "neutral");
  assert.equal(devicePushNote({ status: "no_channel", status_text: "x" }).tone, "warn");
  assert.equal(myDeviceTone("ok"), "ok");
});

test("通知页：收不到的设备逐台一句，测试按钮说清发给几台", () => {
  assert.equal(
    attentionLine({ device_name: "iPad", status: "permission_denied", status_text: "系统通知已关闭，在这台设备的设置里打开" }),
    "iPad：系统通知已关闭，在这台设备的设置里打开",
  );
  assert.ok(attentionLine({ device_name: "iPad", status: "no_channel", status_text: "" }).startsWith("iPad："));
  assert.equal(testTargetHint(2), "发给你的 2 台设备");
  assert.equal(testTargetHint(0), "还没有能收到通知的设备：用 MovieClaw App 登录后会出现");
});

test("测试通知回执：发出去几台，没发出去的逐台说原因", () => {
  assert.deepEqual(
    summarizePushTest({
      sent: 2,
      results: [
        { device_id: "ld-1", device_name: "iPhone", result: "ok", message: null },
        { device_id: "ld-2", device_name: "iPad", result: "ok", message: null },
      ],
    }),
    { tone: "success", message: "测试通知已发给 2 台设备，看看手机吧" },
  );
  const partial = summarizePushTest({
    sent: 1,
    results: [
      { device_id: "ld-1", device_name: "iPhone", result: "ok", message: null },
      { device_id: "ld-2", device_name: "iPad", result: "permission_denied", message: "系统通知已关闭" },
    ],
  });
  assert.equal(partial.tone, "success");
  assert.ok(partial.message.includes("1 台") && partial.message.includes("iPad：系统通知已关闭"));
  // 已排队（通道暂时不可用、稍后自动重试）算发出去了，但要把服务端的说明带上
  const queued = summarizePushTest({
    sent: 2,
    results: [
      { device_id: "ld-1", device_name: "iPhone", result: "ok", message: "已送达苹果推送服务" },
      { device_id: "ld-3", device_name: "iPad", result: "queued", message: "通道暂时不可用，稍后自动重试" },
    ],
  });
  assert.equal(queued.tone, "success");
  assert.equal(
    queued.message,
    "测试通知已发给 2 台设备。iPad：通道暂时不可用，稍后自动重试",
  );
  const none = summarizePushTest({
    sent: 0,
    results: [{ device_id: "ld-2", device_name: "iPad", result: "no_channel", message: "" }],
  });
  assert.equal(none.tone, "error");
  assert.ok(none.message.includes("iPad：没有发出去"));
  assert.deepEqual(summarizePushTest({ sent: 0, results: [] }), {
    tone: "error",
    message: "没有能收通知的设备",
  });
});

test("媒体库有新片：null 是全部（含以后新建的），取消一个就换成明确的列表", () => {
  const visible = [1, 2, 3];
  assert.equal(libraryChecked(null, 2), true);
  assert.equal(libraryChecked([1, 3], 2), false);
  assert.deepEqual(toggleLibrary(null, visible, 2, false), { libraryIds: [1, 3], turnOff: false });
  // 勾满了就是「全部」，包括以后新建的库
  assert.deepEqual(toggleLibrary([1, 3], visible, 2, true), { libraryIds: null, turnOff: false });
  // 一个都不剩 = 关掉开关，库选择回到全部
  assert.deepEqual(toggleLibrary([3], visible, 3, false), { libraryIds: null, turnOff: true });
  // 看不见的库不算进列表
  assert.deepEqual(toggleLibrary([1, 9], visible, 2, true), { libraryIds: [1, 2], turnOff: false });
});
