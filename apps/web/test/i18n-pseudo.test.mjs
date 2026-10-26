import assert from "node:assert/strict";
import test from "node:test";
import { createTranslator } from "next-intl";
import { pseudoMessage, pseudoEnabled } from "../lib/i18n/pseudo.ts";

test("pseudo transforms literal text while keeping ICU arguments, plurals and rich tags", () => {
  const message = pseudoMessage("{count, plural, one {# movie for <link>{name}</link>} other {# movies for <link>{name}</link>}} It's '{literal}'");
  const t = createTranslator({ locale: "en", messages: { sample: message } });
  const result = t.rich("sample", { count: 2, name: "Sam", link: (chunks) => String(chunks) });
  assert.match(result, /Sam/);
  assert.match(result, /2/);
  assert.match(result, /\[.*·/);
  assert.doesNotMatch(result, /movies/);
  assert.doesNotThrow(() => pseudoMessage("{gender, select, female {Her files} other {Their files}}"));
});

test("the pseudo query is ignored outside development and never becomes an Intl locale", () => {
  assert.equal(pseudoEnabled("development", "?locale=pseudo"), true);
  assert.equal(pseudoEnabled("production", "?locale=pseudo"), false);
  assert.equal(pseudoEnabled("test", "?locale=pseudo"), false);
});
