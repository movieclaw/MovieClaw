import assert from "node:assert/strict";
import test from "node:test";

import { enableSoftwareTranscodeForBurn } from "../lib/player/burn-prompt.ts";

function abortError() {
  const error = new Error("aborted");
  error.name = "AbortError";
  return error;
}

test("保存回来时意图还在，并且开关真的开了，才继续压制", async () => {
  let sawSignal = false;
  const outcome = await enableSoftwareTranscodeForBurn(
    async (signal) => {
      sawSignal = signal.aborted === false;
      return { software_transcode_enabled: true };
    },
    { token: 1, current: () => 1, signal: new AbortController().signal },
  );
  assert.equal(outcome, "continue");
  assert.equal(sawSignal, true);
});

test("开关没写成 true 时不继续", async () => {
  const outcome = await enableSoftwareTranscodeForBurn(
    async () => ({ software_transcode_enabled: false }),
    { token: 1, current: () => 1, signal: new AbortController().signal },
  );
  assert.equal(outcome, "rejected");
});

test("保存还没返回就取消：中止请求，不再写开关，也不继续", async () => {
  const controller = new AbortController();
  let generation = 1;
  let wrote = false;
  const pending = enableSoftwareTranscodeForBurn(
    (signal) =>
      new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          wrote = true;
          resolve({ software_transcode_enabled: true });
        }, 50);
        signal.addEventListener("abort", () => {
          clearTimeout(timer);
          reject(abortError());
        });
      }),
    { token: 1, current: () => generation, signal: controller.signal },
  );
  generation += 1;
  controller.abort();
  assert.equal(await pending, "dropped");
  assert.equal(wrote, false);
});

test("保存已经在路上、回来时换了集：不再继续压制", async () => {
  let generation = 1;
  let release;
  const pending = enableSoftwareTranscodeForBurn(
    () =>
      new Promise((resolve) => {
        release = resolve;
      }),
    { token: 1, current: () => generation, signal: new AbortController().signal },
  );
  generation += 1;
  release({ software_transcode_enabled: true });
  assert.equal(await pending, "dropped");
});

test("保存失败、但播放器已经卸掉：不当成开启失败", async () => {
  const controller = new AbortController();
  controller.abort();
  const outcome = await enableSoftwareTranscodeForBurn(
    async () => {
      throw new Error("network down");
    },
    { token: 1, current: () => 2, signal: controller.signal },
  );
  assert.equal(outcome, "dropped");
});

test("保存失败、意图还在：错误照样抛出去", async () => {
  await assert.rejects(
    enableSoftwareTranscodeForBurn(
      async () => {
        throw new Error("network down");
      },
      { token: 1, current: () => 1, signal: new AbortController().signal },
    ),
    /network down/,
  );
});
