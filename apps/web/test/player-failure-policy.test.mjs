// 播放失败之后下一步做什么：每条规则一行（与 iOS 的 PlaybackRoutingTests 同一张表）
import assert from "node:assert/strict";
import test from "node:test";

import {
  NETWORK_RESTART_LIMIT,
  NetworkRestartBudget,
  RECONNECT_DELAYS_S,
  RETRY_WINDOW_MS,
  ReconnectBackoff,
  RetryBudget,
  decideFailure,
  isTransientStatus,
  sourceProbeVerdict,
} from "../lib/player/failure-policy.ts";

const base = { playsOriginalFile: false, copyVideo: true, restartAllowed: true, retryAllowed: true };

const table = [
  // 网络问题：同档原地重开，不降档、不降码率
  [{ ...base, cause: "network" }, "reconnect", "断线：同档原地重开"],
  [{ ...base, cause: "network", playsOriginalFile: true }, "reconnect", "直出断线：等片源取得到再重开"],
  [{ ...base, cause: "network", restartAllowed: false, playsOriginalFile: true }, "fail-network", "直出一直连不上：错误页"],
  [
    { ...base, cause: "network", restartAllowed: false, playsOriginalFile: true, remoteSource: true },
    "step-down",
    "网盘直链连不上：降档由服务端读直链",
  ],
  [{ ...base, cause: "network", restartAllowed: false }, "step-down", "服务端流反复重开都没出画：这一档的问题"],
  // 片源不在了：降档也读不了同一个文件
  [{ ...base, cause: "source-missing" }, "fail-source-missing", "404：错误页说明"],
  // 一时的解码问题：直通档先原位重开一次（降档就丢原画），转码档直接降
  [{ ...base, cause: "decode" }, "retry", "直通档解码楞住：原位重开一次"],
  [{ ...base, cause: "decode", retryAllowed: false }, "step-down", "3 分钟内又出问题：降档"],
  [{ ...base, cause: "decode", copyVideo: false }, "step-down", "转码档解不动：降档"],
  // 确定解不了
  [{ ...base, cause: "decode-final" }, "step-down", "浏览器不支持：降档"],
];

for (const [input, expected, name] of table) {
  test(name, () => {
    assert.equal(decideFailure(input), expected);
  });
}

test("网络重开额度：连续两次没放起来就用完，放起来清零", () => {
  const budget = new NetworkRestartBudget();
  for (let i = 0; i < NETWORK_RESTART_LIMIT; i += 1) assert.equal(budget.allowRestart(), true);
  assert.equal(budget.allowRestart(), false);
  budget.reachedPlaying();
  assert.equal(budget.allowRestart(), true);
  assert.equal(budget.consecutive, 1);
});

test("原位重开额度：同一集 3 分钟内一次", () => {
  const budget = new RetryBudget();
  assert.equal(budget.allowRetry(0), true);
  assert.equal(budget.allowRetry(RETRY_WINDOW_MS - 1), false);
  assert.equal(budget.allowRetry(RETRY_WINDOW_MS + 1), true);
  budget.reset();
  assert.equal(budget.allowRetry(RETRY_WINDOW_MS + 2), true);
});

test("重连退避：2、4、8、15、15、15 秒（约 1 分钟）后用完", () => {
  const backoff = new ReconnectBackoff();
  const delays = [];
  for (let d = backoff.nextDelay(); d !== null; d = backoff.nextDelay()) delays.push(d);
  assert.deepEqual(delays, [...RECONNECT_DELAYS_S]);
  assert.ok(delays.reduce((a, b) => a + b, 0) >= 55);
  backoff.reset();
  assert.equal(backoff.nextDelay(), 2);
});

test("探片源：2xx / 令牌过期算取得到，404 是文件不在，其余与断网都是取不到", () => {
  assert.equal(sourceProbeVerdict(206), "reachable");
  assert.equal(sourceProbeVerdict(200), "reachable");
  assert.equal(sourceProbeVerdict(401), "reachable");
  assert.equal(sourceProbeVerdict(403), "reachable");
  assert.equal(sourceProbeVerdict(404), "missing");
  assert.equal(sourceProbeVerdict(503), "unreachable");
  assert.equal(sourceProbeVerdict(null), "unreachable");
  assert.equal(sourceProbeVerdict("redirect"), "reachable");
});

test("重开会话请求失败：断网、超时、限流、5xx 值得退避再试，4xx 是明确拒绝", () => {
  for (const status of [0, 408, 429, 500, 502, 503]) assert.equal(isTransientStatus(status), true, String(status));
  for (const status of [400, 401, 403, 404, 409]) assert.equal(isTransientStatus(status), false, String(status));
});
