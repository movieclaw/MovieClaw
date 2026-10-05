import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { GENRE_LABELS } from "../lib/genre-labels.ts";

const repo = new URL("../../../", import.meta.url);
test("类型墙名称保留后端电影与剧集的全部 27 个类型，Apple 与 Web 一致", () => {
  const source = readFileSync(new URL("src/movieclaw_media/genres.py", repo), "utf8");
  const expected = {};
  for (const table of ["MOVIE_GENRES", "TV_GENRES"]) {
    const body = source.split(`${table}: dict[int, str] = {`)[1].split("}")[0];
    for (const [, id, label] of body.matchAll(/\s*(\d+): "([^"]+)"/g)) expected[id] = label;
  }
  assert.equal(Object.keys(expected).length, 27);
  assert.deepEqual(GENRE_LABELS, expected);
  const swift = readFileSync(new URL("apps/apple/Shared/DesignSystem/GenreCardFace.swift", repo), "utf8");
  const apple = Object.fromEntries([...swift.matchAll(/^\s*(\d+): "([^"]+)",/gm)].map(([, id, label]) => [id, label]));
  assert.deepEqual(apple, expected);
});
