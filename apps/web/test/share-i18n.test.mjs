import assert from "node:assert/strict";
import test from "node:test";
import { appTranslator } from "../lib/i18n/translate.ts";
import { expiryHint, shareCopyText, validateSharePassword } from "../lib/share.ts";

test("share copy and password validation use the explicit SSR locale and retain user data", () => {
  assert.equal(shareCopyText("用户标题", "https://nas/s/abc", "k7pw2m", "en"), "“用户标题” Link: https://nas/s/abc Password: k7pw2m");
  assert.equal(shareCopyText("用户标题", "https://nas/s/abc", null, "en"), "“用户标题” Link: https://nas/s/abc");
  assert.equal(validateSharePassword("abc", "en"), "Password must be 4–32 characters long");
  assert.equal(validateSharePassword("abc", "zh-Hans"), "密码长度须在 4–32 位之间");
});
test("expiry hints use singular and plural forms without changing their thresholds", () => {
  const now = Date.parse("2026-10-24T12:00:00Z");
  for (const [minutes, english, chinese] of [[0, "Expired", "已失效"], [1, "Expires in 1 minute", "1 分钟后失效"], [2, "Expires in 2 minutes", "2 分钟后失效"], [60, "Expires in 1 hour", "1 小时后失效"], [45 * 60, "Expires in 45 hours", "45 小时后失效"], [48 * 60, "Expires in 2 days", "2 天后失效"]]) {
    const end = new Date(now + minutes * 60_000).toISOString();
    assert.equal(expiryHint(end, now, "en"), english);
    assert.equal(expiryHint(end, now, "zh-Hans"), chinese);
  }
});
test("share and artwork summaries preserve Chinese copy with complete messages", () => {
  const en = appTranslator("en"), zh = appTranslator("zh-Hans");
  assert.equal(en("library.share.views", { count: 1 }), "Viewed 1 time");
  assert.equal(en("library.share.views", { count: 2 }), "Viewed 2 times");
  assert.equal(zh("library.artwork.manualSelection", { kind: "backdrop" }), "当前背景由你手动选定，刷新元数据不会覆盖");
  assert.equal(zh("library.artwork.empty", { mixed: "yes", kind: "logo" }), "TMDB 和 Fanart.tv 上都没有这个条目的徽标");
  assert.equal(en("library.artwork.moreFanartForKind", { kind: "poster" }), "＋ Find more posters on Fanart.tv");
  assert.equal(zh("library.share.copySuccess", { what: "both" }), "已复制链接和密码");
});
