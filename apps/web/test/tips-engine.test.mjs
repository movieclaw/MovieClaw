import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import { TIP_ID_PATTERN, defineTip, tipStatus } from "../lib/tips/engine.ts";

const NOW = new Date("2026-10-10T12:00:00Z");
const NO_THROTTLE = { displayFrequencyMs: 0 };
const empty = () => ({ events: {}, tips: {} });

function record(overrides = {}) {
  return {
    display_count: 0,
    first_displayed_at: null,
    last_displayed_at: null,
    invalidated_at: null,
    invalidated_reason: null,
    ...overrides,
  };
}

test("没有规则的提示随时可出现", () => {
  const tip = defineTip({ id: "a", title: "A" });
  assert.equal(tipStatus(tip, empty(), undefined, NO_THROTTLE, NOW), "available");
});

test("事件次数规则：不够时等待，够了出现", () => {
  const tip = defineTip({
    id: "a",
    title: "A",
    rules: [({ event }) => event("player.opened").count >= 3],
  });
  const snap = empty();
  assert.equal(tipStatus(tip, snap, undefined, NO_THROTTLE, NOW), "pending");
  snap.events["player.opened"] = { count: 3, first_at: NOW.toISOString(), last_at: NOW.toISOString() };
  assert.equal(tipStatus(tip, snap, undefined, NO_THROTTLE, NOW), "available");
});

test("规则能读事件时间与调用方参数", () => {
  const tip = defineTip({
    id: "a",
    title: "A",
    rules: [
      ({ params }) => params.hasItems,
      ({ event, now }) => {
        const last = event("search").lastAt;
        return last !== null && now.getTime() - last.getTime() < 7 * 86400_000;
      },
    ],
  });
  const snap = empty();
  snap.events.search = { count: 1, first_at: "2026-10-09T00:00:00+00:00", last_at: "2026-10-09T00:00:00+00:00" };
  assert.equal(tipStatus(tip, snap, { hasItems: false }, NO_THROTTLE, NOW), "pending");
  assert.equal(tipStatus(tip, snap, { hasItems: true }, NO_THROTTLE, NOW), "available");
  snap.events.search.last_at = "2026-09-01T00:00:00+00:00";
  assert.equal(tipStatus(tip, snap, { hasItems: true }, NO_THROTTLE, NOW), "pending");
});

test("作废后永不出现，即使规则满足", () => {
  const tip = defineTip({ id: "a", title: "A" });
  const snap = empty();
  snap.tips.a = record({ invalidated_at: NOW.toISOString(), invalidated_reason: "closed" });
  assert.equal(tipStatus(tip, snap, undefined, NO_THROTTLE, NOW), "invalidated");
});

test("展示次数到上限算作废", () => {
  const tip = defineTip({ id: "a", title: "A", maxDisplayCount: 2 });
  const snap = empty();
  snap.tips.a = record({ display_count: 1, first_displayed_at: NOW.toISOString() });
  assert.equal(tipStatus(tip, snap, undefined, NO_THROTTLE, NOW), "available");
  snap.tips.a.display_count = 2;
  assert.equal(tipStatus(tip, snap, undefined, NO_THROTTLE, NOW), "invalidated");
});

test("频率节流只拦新提示：出现过的提示照常出现，豁免的提示不受限", () => {
  const hour = 3600_000;
  const config = { displayFrequencyMs: 24 * hour };
  const snap = empty();
  // 一小时前有一条新提示第一次出现
  snap.tips.old = record({
    display_count: 1,
    first_displayed_at: new Date(NOW.getTime() - hour).toISOString(),
  });
  const fresh = defineTip({ id: "fresh", title: "F" });
  const old = defineTip({ id: "old", title: "O" });
  const urgent = defineTip({ id: "urgent", title: "U", ignoresDisplayFrequency: true });
  assert.equal(tipStatus(fresh, snap, undefined, config, NOW), "pending");
  assert.equal(tipStatus(old, snap, undefined, config, NOW), "available");
  assert.equal(tipStatus(urgent, snap, undefined, config, NOW), "available");
  // 过了窗口，新提示可以出现
  const later = new Date(NOW.getTime() + 24 * hour);
  assert.equal(tipStatus(fresh, snap, undefined, config, later), "available");
});

test("标识规则与服务端一致，不合规的定义直接报错", () => {
  const route = readFileSync(
    new URL("../../../src/movieclaw_api/api/routes/tips.py", import.meta.url),
    "utf8",
  );
  const serverPattern = route.match(/_ID_PATTERN = r"([^"]+)"/)[1];
  assert.equal(TIP_ID_PATTERN.source, serverPattern);
  assert.throws(() => defineTip({ id: "Library.Filter", title: "x" }));
  assert.doesNotThrow(() => defineTip({ id: "library.filter-v2", title: "x" }));
});
