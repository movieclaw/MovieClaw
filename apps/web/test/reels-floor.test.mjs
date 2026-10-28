import assert from "node:assert/strict";
import test from "node:test";
import { ARM_BEYOND, REFRESH_AT, ReelsFloorModel, rubber } from "../lib/reels-floor.ts";

// 首页「下拉二楼」的判定（同 iOS ReelsFloorTests / Android ReelsFloorStateTest）：
// 刷新先触发、线在刷新之后；只认拖着拉过线后松手；推回线内只刷新；上次的过线不带到下一次

/** 下拉量拉到 pull 需要的手指距离（反解橡皮筋） */
function fingerFor(pull) {
  let lo = 0;
  let hi = 5000;
  for (let i = 0; i < 60; i += 1) {
    const mid = (lo + hi) / 2;
    if (rubber(mid) < pull) lo = mid;
    else hi = mid;
  }
  return hi;
}

test("刷新在过线之前触发，触发那一下报一次", () => {
  const floor = new ReelsFloorModel();
  floor.begin();
  assert.equal(floor.dragTo(fingerFor(REFRESH_AT - 1)), false);
  assert.equal(floor.refreshedAt, null);
  assert.equal(floor.dragTo(fingerFor(REFRESH_AT + 1)), true);
  assert.equal(floor.dragTo(fingerFor(REFRESH_AT + 5)), false, "同一次拖动只触发一次");
  assert.equal(floor.armed, false);
});

test("拉过线松手进片段", () => {
  const floor = new ReelsFloorModel();
  floor.begin();
  floor.dragTo(fingerFor(REFRESH_AT + ARM_BEYOND + 10));
  assert.equal(floor.armed, true);
  assert.equal(floor.reveal, 1);
  assert.equal(floor.release(), true);
});

test("只拉到刷新的距离：胶片出来了，但松手不进", () => {
  const floor = new ReelsFloorModel();
  floor.begin();
  floor.dragTo(fingerFor(REFRESH_AT + 15));
  assert.ok(floor.reveal > 0);
  assert.equal(floor.release(), false);
});

test("推回线内再松手只是刷新", () => {
  const floor = new ReelsFloorModel();
  floor.begin();
  floor.dragTo(fingerFor(REFRESH_AT + ARM_BEYOND + 20));
  floor.dragTo(fingerFor(REFRESH_AT + ARM_BEYOND - 20));
  assert.equal(floor.armed, false);
  assert.equal(floor.release(), false);
});

test("下一次按下从头判断", () => {
  const floor = new ReelsFloorModel();
  floor.begin();
  floor.dragTo(fingerFor(REFRESH_AT + ARM_BEYOND + 10));
  assert.equal(floor.release(), true);
  floor.settle(0);
  floor.begin();
  assert.equal(floor.armed, false);
  assert.equal(floor.refreshedAt, null);
  assert.equal(floor.release(), false);
});

test("橡皮筋：先跟手，越拉越沉", () => {
  assert.equal(rubber(30), 30);
  assert.ok(rubber(450) - rubber(400) < rubber(200) - rubber(150));
});
