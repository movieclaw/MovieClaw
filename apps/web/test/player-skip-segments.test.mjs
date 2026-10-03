import assert from "node:assert/strict";
import test from "node:test";

import {
  AUTO_NEXT_MAX_STREAK,
  AUTO_NEXT_MS,
  SKIP_TAIL_MS,
  activeSkipSegment,
  autoNextArmed,
  isInOutro,
  skipLabel,
  shouldShowUpNext,
} from "../lib/player/timeline.ts";

const ad = { type: "ad", start_ms: 0, end_ms: 20_000, to_end: false };
const intro = { type: "intro", start_ms: 60_000, end_ms: 150_000, to_end: false };
const credits = { type: "outro", start_ms: 2_550_000, end_ms: 2_700_000, to_end: true };
const midOutro = { type: "outro", start_ms: 2_400_000, end_ms: 2_500_000, to_end: false };

test("片头区间里给「跳过片头」，区间外不给", () => {
  assert.equal(activeSkipSegment([intro], 59_999), null);
  assert.equal(activeSkipSegment([intro], 60_000), intro);
  assert.equal(skipLabel(activeSkipSegment([intro], 100_000)), "跳过片头");
  assert.equal(activeSkipSegment([intro], 150_000), null);
});

test("离段尾不足 3 秒就收起：只省一两秒，还会撞上画面切换", () => {
  assert.equal(activeSkipSegment([intro], 150_000 - SKIP_TAIL_MS - 1), intro);
  assert.equal(activeSkipSegment([intro], 150_000 - SKIP_TAIL_MS), null);
});

test("广告、预告和其他重复段各有准确提示", () => {
  assert.equal(skipLabel(activeSkipSegment([ad, intro], 5_000)), "跳过广告");
  assert.equal(skipLabel({ ...ad, type: "preview" }), "跳过预告");
  assert.equal(skipLabel({ ...ad, type: "other" }), "跳过此段");
  assert.equal(skipLabel({ ...ad, type: "future-type" }), "跳过此段");
  assert.equal(skipLabel(activeSkipSegment([midOutro], 2_450_000)), "跳过片尾");
});

test("放到结尾的片尾不给跳过按钮，改由「即将播放」接手", () => {
  assert.equal(activeSkipSegment([credits], 2_600_000), null);
  assert.equal(isInOutro([credits], 2_549_999), false);
  assert.equal(isInOutro([credits], 2_550_000), true);
  assert.equal(isInOutro([midOutro], 2_450_000), false);
});

test("没有片段（旧服务端、电影、还没识别）时什么都不给", () => {
  assert.equal(activeSkipSegment(undefined, 1000), null);
  assert.equal(isInOutro(undefined, 1000), false);
});

test("自动播下一集：只有认出了片尾才倒计时，连播 3 集后停", () => {
  assert.equal(AUTO_NEXT_MS, 8000);
  assert.equal(autoNextArmed([credits], 2_549_999, 0), false, "片尾之前不倒计时");
  assert.equal(autoNextArmed([credits], 2_560_000, 0), true);
  assert.equal(autoNextArmed([credits], 2_560_000, AUTO_NEXT_MAX_STREAK - 1), true);
  assert.equal(autoNextArmed([credits], 2_560_000, AUTO_NEXT_MAX_STREAK), false, "连播到上限就停");
  assert.equal(autoNextArmed([midOutro], 2_450_000, 0), false, "片尾后面还有内容的不算");
  assert.equal(autoNextArmed([], 2_690_000, 0), false, "没认出片尾（只按 40 秒兜底）不自动播");
  assert.equal(autoNextArmed(undefined, 2_690_000, 0), false);
});

test("广告与预告即使到结尾也保持手动跳过，不启动下一集倒计时", () => {
  for (const type of ["ad", "preview", "other"]) {
    const segment = { ...credits, type };
    assert.equal(activeSkipSegment([segment], 2_600_000), segment);
    assert.equal(autoNextArmed([segment], 2_600_000, 0), false);
  }
});

test("分开的广告与片头分别跳过，保留中间剧情", () => {
  assert.equal(activeSkipSegment([ad, intro], 5000)?.end_ms, 20_000);
  assert.equal(activeSkipSegment([ad, intro], 30_000), null);
  assert.equal(activeSkipSegment([ad, intro], 70_000)?.end_ms, 150_000);
});

test("最后 40 秒的下一集卡片不能盖住预告或独立片尾的跳过按钮", () => {
  for (const type of ["preview", "ad", "outro", "other"]) {
    const segment = { type, start_ms: 2_660_000, end_ms: 2_690_000, to_end: false };
    assert.equal(shouldShowUpNext([segment], 2_670_000, 2_700_000), false);
    assert.equal(shouldShowUpNext([segment], 2_690_000, 2_700_000), true);
    assert.equal(shouldShowUpNext([segment], 2_700_000, 2_700_000, true), true);
  }
  assert.equal(shouldShowUpNext([], 2_670_000, 2_700_000), true);
  assert.equal(shouldShowUpNext([credits], 2_600_000, 2_700_000), true);
});
