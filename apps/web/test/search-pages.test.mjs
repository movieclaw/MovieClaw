import assert from "node:assert/strict";
import test from "node:test";

import { noMorePages } from "../lib/search-pages.ts";

test("所有站点都明确说没有下一页时才算到底", () => {
  assert.equal(noMorePages([{ error: null, has_more: false }]), true);
  assert.equal(
    noMorePages([
      { error: null, has_more: false },
      { error: null, has_more: false },
    ]),
    true,
  );
});

test("有站点说不准、还有下一页或失败时继续显示加载更多", () => {
  assert.equal(noMorePages([{ error: null, has_more: false }, { error: null, has_more: null }]), false);
  assert.equal(noMorePages([{ error: null }]), false);
  assert.equal(noMorePages([{ error: null, has_more: true }]), false);
  assert.equal(noMorePages([{ error: null, has_more: false }, { error: "超时", has_more: null }]), false);
  assert.equal(noMorePages([]), false);
});
