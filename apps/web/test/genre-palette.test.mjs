import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
  CHROMA_SCALE,
  FEATHER_STOPS,
  GENRE_TONES,
  blobCss,
  compositionIndex,
  genreArt,
  genreTone,
  midHue,
} from "../lib/genre-palette.ts";

const repo = new URL("../../../", import.meta.url);

/** 后端类型表（movieclaw_media/genres.py）里的全部 genre id。 */
function backendGenreIds() {
  const source = readFileSync(new URL("src/movieclaw_media/genres.py", repo), "utf8");
  const ids = new Set();
  for (const table of ["MOVIE_GENRES", "TV_GENRES"]) {
    const body = source.split(`${table}: dict[int, str] = {`)[1].split("}")[0];
    for (const match of body.matchAll(/^\s*(\d+):/gm)) ids.add(Number(match[1]));
  }
  return ids;
}

test("后端两张类型表里的每个 id 都有手调的配色，表里没有多余的 id", () => {
  const backend = backendGenreIds();
  assert.equal(backend.size, 27);
  assert.deepEqual(
    [...backend].sort((a, b) => a - b),
    Object.keys(GENRE_TONES)
      .map(Number)
      .sort((a, b) => a - b),
  );
});

test("色相中点沿短弧走：跨 0° 的一对不会算到色环对面", () => {
  assert.equal(midHue(345, 12), 358.5);
  assert.equal(midHue(12, 345), 358.5);
  assert.equal(midHue(30, 90), 60);
  assert.equal(midHue(350, 10), 0);
});

test("构图按 id 各位之和轮换，同一类型永远同一种", () => {
  assert.equal(compositionIndex(878), (8 + 7 + 8) % 3);
  assert.equal(compositionIndex(10765), (1 + 0 + 7 + 6 + 5) % 3);
  assert.equal(new Set(Object.keys(GENRE_TONES).map((id) => compositionIndex(Number(id)))).size, 3);
});

test("每块的颜色都在合法范围：彩度统一乘 80%，明度不出 0-1", () => {
  for (const id of Object.keys(GENRE_TONES).map(Number)) {
    const art = genreArt(id);
    const tone = genreTone(id);
    assert.ok(Math.abs(art.from.c - tone.k * CHROMA_SCALE) < 1e-9, `${tone.name} 底色彩度`);
    for (const color of [art.from, art.to, ...art.blobs.map((b) => b.color)]) {
      assert.ok(color.l >= 0 && color.l <= 1, `${tone.name} 明度越界`);
      assert.ok(color.h >= 0 && color.h < 360, `${tone.name} 色相越界`);
    }
    assert.equal(art.blobs.length, 3);
    assert.ok(art.scrim >= 0.06 && art.scrim < 0.3);
  }
  // 「音乐」的小亮斑：主色 345° 与高光 12° 的中点，是玫红而不是青色
  assert.equal(genreArt(10402).blobs.find((b) => b.color.alpha < 0.9).color.h, 358.5);
});

test("表外的 id 回落到中性色，不报错", () => {
  const art = genreArt(999999);
  assert.equal(art.blobs.length, 3);
  assert.ok(art.from.c < 0.06);
});

test("羽化色团从圆心到边缘逐级透明，最外一圈完全透明", () => {
  const css = blobCss({ l: 0.6, c: 0.1, h: 250, alpha: 0.9 });
  assert.match(css, /^radial-gradient\(closest-side, /);
  assert.match(css, /\/ 0\.000\) 100%\)$/);
});

test("iOS / tvOS 的 GenrePalette.swift 与本表逐项一致（色相、明度、彩度、倍率、羽化）", () => {
  const swift = readFileSync(new URL("apps/apple/Shared/DesignSystem/GenrePalette.swift", repo), "utf8");
  const tones = {};
  const line =
    /^\s*(\d+): Tone\(name: "([^"]+)", a: ([\d.]+), b: ([\d.]+), c: ([\d.]+), l: ([\d.]+), k: ([\d.]+)\),$/gm;
  for (const m of swift.matchAll(line)) {
    tones[Number(m[1])] = {
      name: m[2],
      a: Number(m[3]),
      b: Number(m[4]),
      c: Number(m[5]),
      l: Number(m[6]),
      k: Number(m[7]),
    };
  }
  assert.deepEqual(tones, GENRE_TONES);
  assert.match(swift, new RegExp(`static let chromaScale = ${CHROMA_SCALE}\\b`));
  const feather = FEATHER_STOPS.map(([at, alpha]) => `(${at}, ${alpha})`).join(", ");
  assert.ok(swift.includes(`featherStops: [(Double, Double)] = [${feather}]`), "羽化色标不一致");
});
