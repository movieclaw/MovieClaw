import assert from "node:assert/strict";
import test from "node:test";

import {
  isPartialSegmentResponse,
  partialSegmentRequest,
} from "../lib/player/progressive-hls.ts";

test("渐进加载只选择媒体分片，保留鉴权、Range 和取消信号", () => {
  const controller = new AbortController();
  const request = partialSegmentRequest(
    { url: "http://nas/api/v1/playback/sessions/s/seg00001.m4s?token=signed" },
    { headers: { Range: "bytes=0-99" }, signal: controller.signal, credentials: "same-origin" },
  );
  assert.equal(new URL(request.url).searchParams.get("partial"), "1");
  assert.equal(new URL(request.url).searchParams.get("token"), "signed");
  assert.equal(request.headers.get("Range"), "bytes=0-99");
  assert.equal(request.credentials, "same-origin");
  controller.abort();
  assert.equal(request.signal.aborted, true);
  for (const name of ["index.m3u8", "init.mp4", "subtitles.vtt"]) {
    const url = `http://nas/api/v1/playback/sessions/s/${name}?token=signed`;
    assert.equal(partialSegmentRequest({ url }, {}).url, url);
  }
});

test("半成品不能用于估计线路带宽，完整缓存分片仍可采样", () => {
  assert.equal(isPartialSegmentResponse(new Response(null, {
    headers: { "X-MovieClaw-Partial-Segment": "1" },
  })), true);
  assert.equal(isPartialSegmentResponse(new Response(null)), false);
  assert.equal(isPartialSegmentResponse(undefined), false);
  assert.equal(isPartialSegmentResponse({}), false);
});

test("播放接口的根相对路径按网页所在的源解析", (t) => {
  const previous = Object.getOwnPropertyDescriptor(globalThis, "location");
  Object.defineProperty(globalThis, "location", {
    configurable: true, value: { href: "http://nas/watch/42" },
  });
  t.after(() => {
    if (previous) Object.defineProperty(globalThis, "location", previous);
    else delete globalThis.location;
  });
  assert.equal(partialSegmentRequest({
    url: "/api/v1/playback/sessions/s/seg00000.m4s?token=signed",
  }, {}).url, "http://nas/api/v1/playback/sessions/s/seg00000.m4s?token=signed&partial=1");
});
