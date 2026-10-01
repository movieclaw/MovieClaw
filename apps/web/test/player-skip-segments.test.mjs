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
} from "../lib/player/timeline.ts";

const ad = { type: "other", start_ms: 0, end_ms: 20_000, to_end: false };
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

test("片头前的冠名广告也叫「跳过片头」，片尾后面还有预告叫「跳过片尾」", () => {
  assert.equal(skipLabel(activeSkipSegment([ad, intro], 5_000)), "跳过片头");
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
  assert.equal(AUTO_NEXT_MS, 5000);
  assert.equal(autoNextArmed([credits], 2_549_999, 0), false, "片尾之前不倒计时");
  assert.equal(autoNextArmed([credits], 2_560_000, 0), true);
  assert.equal(autoNextArmed([credits], 2_560_000, AUTO_NEXT_MAX_STREAK - 1), true);
  assert.equal(autoNextArmed([credits], 2_560_000, AUTO_NEXT_MAX_STREAK), false, "连播到上限就停");
  assert.equal(autoNextArmed([midOutro], 2_450_000, 0), false, "片尾后面还有内容的不算");
  assert.equal(autoNextArmed([], 2_690_000, 0), false, "没认出片尾（只按 40 秒兜底）不自动播");
  assert.equal(autoNextArmed(undefined, 2_690_000, 0), false);
});
