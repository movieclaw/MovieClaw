import assert from "node:assert/strict";
import { test } from "node:test";

import {
  mediaSourceOptions,
  USER_LOWEST_SOURCE,
  mediaSourceDisplayLabel,
  seasonsNeedingAnnotation,
  seasonsWithIndeterminate,
} from "../lib/media-source-annotation.ts";

const MEDIA_SOURCE_OPTIONS = mediaSourceOptions("zh-Hans");

test("选项表：五个真实档位 + 唯一的警示性最低档兜底", () => {
  assert.equal(MEDIA_SOURCE_OPTIONS.length, 6);
  const destructive = MEDIA_SOURCE_OPTIONS.filter((o) => o.destructive);
  assert.equal(destructive.length, 1);
  assert.equal(destructive[0].value, USER_LOWEST_SOURCE);
  // 每个选项都必须写明后果（标注是知情选择）
  for (const o of MEDIA_SOURCE_OPTIONS) {
    assert.ok(o.consequence.length > 0, `${o.value} 缺少后果说明`);
  }
});

test("展示名：哨兵值映射为人话，真实档位原样，空值返回 null", () => {
  assert.equal(mediaSourceDisplayLabel(USER_LOWEST_SOURCE), "最低档（人工标注）");
  assert.equal(mediaSourceDisplayLabel("WEB-DL"), "WEB-DL");
  assert.equal(mediaSourceDisplayLabel(null), null);
  assert.equal(mediaSourceDisplayLabel(undefined), null);
});

test("洗版报告：只有含「无法确认」单元的季给标注入口", () => {
  const seasons = seasonsNeedingAnnotation([
    { season_number: 7, state: "not_comparable" },
    { season_number: 7, state: "at_cutoff" },
    { season_number: 8, state: "upgradable" },
    { season_number: 0, state: "not_comparable" },
  ]);
  assert.deepEqual([...seasons].sort(), [0, 7]);
});

test("追踪明细：按 upgrade.indeterminate 聚合季号，缺 upgrade 的行忽略", () => {
  const seasons = seasonsWithIndeterminate([
    { season_number: 7, upgrade: { indeterminate: true } },
    { season_number: 7, upgrade: { indeterminate: false } },
    { season_number: 8, upgrade: null },
    { season_number: 9 },
  ]);
  assert.deepEqual([...seasons], [7]);
});
