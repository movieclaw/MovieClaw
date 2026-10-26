import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import test from "node:test";
import { formatList } from "../lib/i18n/format.ts";

test("list formatting keeps Chinese separators and uses English lists otherwise", () => {
  assert.equal(formatList(["动作", "剧情"], "zh-Hans", { type: "unit", style: "short" }), "动作、剧情");
  assert.equal(formatList(["Action", "Drama", "Crime"], "en", { type: "unit", style: "short" }), "Action, Drama, Crime");
  assert.equal(formatList(["Season 1: 2 missing", "Season 3: 1 missing"], "en"), "Season 1: 2 missing and Season 3: 1 missing");
});

test("components do not join visible lists with hard-coded Chinese separators", () => {
  const dir = new URL("../components/", import.meta.url);
  const offenders = readdirSync(dir, { recursive: true })
    .filter((name) => /\.tsx?$/.test(name))
    .flatMap((name) =>
      readFileSync(new URL(name, dir), "utf8")
        .split("\n")
        .map((line, index) => ({ name, line, index }))
        .filter(({ line }) => /\.join\("[、；，]"\)/.test(line))
        .map(({ name, index }) => `${name}:${index + 1}`),
    );
  assert.deepEqual(offenders, []);
});
