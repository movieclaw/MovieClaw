import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";

import { resolveCompanionState } from "../lib/agent-companion.ts";

test("真实轮次的开始、完成、主动停止和中断映射到相应表情", () => {
  assert.equal(resolveCompanionState(undefined, false), "idle");
  assert.equal(resolveCompanionState({ status: "running" }, true), "working");
  assert.equal(resolveCompanionState({ status: "done" }, false), "complete");
  assert.equal(resolveCompanionState({ status: "done", stopped: true }, false), "idle");
  assert.equal(resolveCompanionState({ status: "done", interrupted: true }, false), "failed");
  assert.equal(resolveCompanionState({ status: "error" }, false), "failed");
});

test("工具出错但整轮还在运行时继续工作，模型不可用时安静待机", () => {
  assert.equal(resolveCompanionState({ status: "error" }, true), "working");
  assert.equal(resolveCompanionState({ status: "error" }, false, true), "idle");
  assert.equal(resolveCompanionState({ status: "running" }, true, true), "idle");
});

test("网页与 iPhone 的小鱼图集保持相同，避免同步时换回旧道具", () => {
  const web = readFileSync(new URL("../public/companions/moonlight.png", import.meta.url));
  const phone = readFileSync(new URL("../../apple/MovieClaw/Assets.xcassets/AgentMoonCompanion.imageset/moonlight.png", import.meta.url));
  assert.equal(web.equals(phone), true);
});
