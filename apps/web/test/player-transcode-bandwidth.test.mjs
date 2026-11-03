import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import ts from "typescript";

import { QualitySuggestion, transcodeBitrateBps } from "../lib/player/quality-suggestion.ts";

// 执行组件实际使用的回调，覆盖统计 → 建议 → 重开，避免只测纯算法而漏掉接线错误。
const source = readFileSync(new URL("../components/player/video-player.tsx", import.meta.url), "utf8");
const ast = ts.createSourceFile("video-player.tsx", source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
let callback;
function visit(node) {
  if (ts.isVariableDeclaration(node) && node.name.getText(ast) === "feedQualitySuggestion") {
    callback = node.initializer.arguments[0].getText(ast);
  }
  ts.forEachChild(node, visit);
}
visit(ast);
assert.ok(callback);
const js = ts.transpile(`const feed = ${callback};`, { target: ts.ScriptTarget.ES2022 });

function harness({ action = "transcode", downlinkBps = null, loadingBps = 540, cap = null } = {}) {
  const ref = (current) => ({ current });
  const events = [];
  const context = {
    activeSessionRef: ref({ decision: { video: { action, height: 2160 } }, source: { resolution: "2160p" } }),
    phaseRef: ref("buffering"),
    video: { pause() {} },
    wantsPlayRef: ref(true),
    document: { visibilityState: "visible" },
    recordRef: ref(null),
    suggestionRef: ref(new QualitySuggestion()),
    sourceBitrateRef: ref(16_000_000),
    qualityOfferRef: ref(null),
    qualityRef: ref(cap),
    bandwidthRestartedRef: ref(false),
    lastDownlinkRef: ref(downlinkBps),
    apiRef: ref({}),
    positionRef: ref(120_000),
    pendingFileMsRef: ref(null),
    qualityOfferTimerRef: ref(null),
    sourceHeight: () => 2160,
    reportPlaybackClientLog() {},
    freezeFrame() {},
    dispatch: (event) => events.push(event),
    setQualityOffer: (offer) => events.push(offer),
    window: { setTimeout() {}, clearTimeout() {} },
    QualitySuggestion,
    transcodeBitrateBps,
  };
  vm.createContext(context);
  const feed = vm.runInContext(`${js}\nfeed`, context);
  const stats = { engine: "hls.js", bitrate: 16_000_000, loadingBps, downlinkBps };
  return {
    context,
    events,
    tick: (count = 12) => { for (let i = 0; i < count; i++) feed({}, stats); },
  };
}

for (const downlinkBps of [null, 100_000_000]) {
  test(`转码产出仅 540 bps，可信带宽 ${downlinkBps}：不自动重开、不提示降档、不污染后续会话`, () => {
    const h = harness({ downlinkBps });
    h.tick();
    assert.equal(h.events.length, 0);
    assert.equal(h.context.lastDownlinkRef.current, downlinkBps);
    assert.equal(h.context.bandwidthRestartedRef.current, false);
  });
}

test("真正慢线路仍自动重开，使用线路带宽而不是产出速度", () => {
  const h = harness({ downlinkBps: 2_000_000 });
  h.tick(8);
  assert.equal(h.events.length, 1);
  assert.equal(h.events[0].type, "restart");
  assert.equal(h.events[0].startMs, 120_000);
  assert.equal(h.context.lastDownlinkRef.current, 2_000_000);
});

test("手选画质时只建议；建议中的实测值来自线路带宽", () => {
  const h = harness({ downlinkBps: 4_000_000, cap: 2160 });
  h.tick(8);
  assert.equal(h.events.length, 1);
  assert.equal(h.events[0].measuredBps, 4_000_000);
  assert.equal(h.events[0].maxHeight, 720);
});

test("视频直通仍按原有加载速度给出建议", () => {
  const h = harness({ action: "copy", downlinkBps: null, loadingBps: 4_000_000 });
  h.tick(8);
  assert.equal(h.events[0].measuredBps, 4_000_000);
  assert.equal(h.events[0].maxHeight, 720);
});
