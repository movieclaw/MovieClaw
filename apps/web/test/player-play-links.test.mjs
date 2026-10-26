import assert from "node:assert/strict";
import test from "node:test";

import {
  lockedFileForUnit,
  parseUnitSegment,
  pickedVersionFileId,
  playHref,
} from "../lib/player/play-links.ts";

test("电影地址只有条目 id", () => {
  assert.equal(playHref(127), "/play/127");
});

test("剧集地址带补零的 sXXeYY 段", () => {
  assert.equal(playHref(127, { season: 1, episode: 3 }), "/play/127/s01e03");
  assert.equal(playHref(127, { season: 12, episode: 345 }), "/play/127/s12e345");
});

test("季集必须成对：缺一个就按电影出——半个单元没有意义", () => {
  assert.equal(playHref(127, { season: 1 }), "/play/127");
  assert.equal(playHref(127, { episode: 3 }), "/play/127");
});

test("t 参数（秒）拼进查询串，0 与负数不拼——从头播不需要说明", () => {
  assert.equal(playHref(127, { season: 1, episode: 3, tSeconds: 1520 }), "/play/127/s01e03?t=1520");
  assert.equal(playHref(127, { tSeconds: 95.7 }), "/play/127?t=95");
  assert.equal(playHref(127, { tSeconds: 0 }), "/play/127");
});

test("解析 sXXeYY：大小写不敏感，前导零可省", () => {
  assert.deepEqual(parseUnitSegment("s01e03"), { season: 1, episode: 3 });
  assert.deepEqual(parseUnitSegment("S1E3"), { season: 1, episode: 3 });
  assert.deepEqual(parseUnitSegment("s12e345"), { season: 12, episode: 345 });
});

test("解析不动就当电影播——地址是人手打的，别苛刻", () => {
  assert.equal(parseUnitSegment("season1"), null);
  assert.equal(parseUnitSegment("s1"), null);
  assert.equal(parseUnitSegment("e3"), null);
  assert.equal(parseUnitSegment(""), null);
  assert.equal(parseUnitSegment(undefined), null);
});

test("详情页点播放：没碰过版本选择器（默认高亮第一个）不锁文件——锁了服务端就不择优", () => {
  assert.equal(pickedVersionFileId(null, [743, 4260]), undefined);
  // 不锁 = 地址里不带 file
  assert.equal(playHref(288, { fileId: pickedVersionFileId(null, [743, 4260]) }), "/play/288");
});

test("详情页点播放：用户亲手选过的版本才锁（含选的恰好是第一个）", () => {
  assert.equal(pickedVersionFileId(4260, [743, 4260]), 4260);
  assert.equal(pickedVersionFileId(743, [743, 4260]), 743);
  assert.equal(playHref(288, { fileId: pickedVersionFileId(4260, [743, 4260]) }), "/play/288?file=4260");
});

test("详情页点播放：选过的版本不属于当前播放单元（剧集切集后）不锁", () => {
  assert.equal(pickedVersionFileId(1795, [1796]), undefined);
  assert.equal(pickedVersionFileId(1795, []), undefined);
});

test("播放页锁定文件只对进入播放页的那一集生效：连播 / 点下一集换了 unit，回到自动择优", () => {
  // 进入时是第 1 集，锁定 4260
  assert.equal(lockedFileForUnit("288/1/1", "288/1/1", 4260), 4260);
  // 自动连播到第 2 集：不能再带第 1 集的文件，否则服务端 file_id 优先，又播了一遍第 1 集
  assert.equal(lockedFileForUnit("288/1/2", "288/1/1", 4260), undefined);
  // 点上一集切回进入时的那一集：照旧锁定
  assert.equal(lockedFileForUnit("288/1/1", "288/1/1", 4260), 4260);
});

test("播放页锁定文件：没锁（?file= 没带）在任何一集都是 undefined", () => {
  assert.equal(lockedFileForUnit("288/0/0", "288/0/0", undefined), undefined);
  assert.equal(lockedFileForUnit("288/1/2", "288/1/1", undefined), undefined);
});
