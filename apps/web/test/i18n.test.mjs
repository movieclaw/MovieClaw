import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import { negotiate, resolveLocale } from "../lib/i18n/negotiate.ts";

const cases = JSON.parse(fs.readFileSync(new URL("../../../tests/i18n/negotiation.json", import.meta.url)));
for (const { header, locale } of cases) {
  test(`language negotiation: ${header}`, () => assert.equal(negotiate(header), locale));
}
test("web UI negotiates German; the server keeps English for it until it has a German catalog", () => {
  assert.equal(negotiate("de"), "de");
  assert.equal(negotiate("de-AT,en;q=0.8"), "de");
  assert.equal(negotiate("fr,de;q=0.5"), "de");
  assert.equal(resolveLocale("de", "en-US"), "de");
});
test("valid cookie takes precedence; auto and invalid values use browser", () => {
  assert.equal(resolveLocale("en", "zh-CN"), "en");
  assert.equal(resolveLocale("zh-Hans", "en-US"), "zh-Hans");
  assert.equal(resolveLocale("auto", "zh-CN"), "zh-Hans");
  assert.equal(resolveLocale("invalid", "en-US"), "en");
});
