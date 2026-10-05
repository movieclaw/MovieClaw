import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
  CHROMA_SCALE,
  FEATHER_STOPS,
  GENRE_CARDS,
  GENRE_TONES,
  MATERIALS,
  genreCardColors,
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
  // 贴图卡配色表与特殊材质
  const cards = {};
  const cardLine = /^\s*(\d+): CardTone\(l: ([\d.]+), c: ([\d.]+), h: ([\d.]+), kind: \.(\w+)\),/gm;
  for (const m of swift.matchAll(cardLine)) cards[m[1]] = [Number(m[2]), Number(m[3]), Number(m[4]), m[5]];
  assert.deepEqual(cards, Object.fromEntries(Object.entries(GENRE_CARDS).map(([k, v]) => [k, [...v]])));
  for (const [name, stops] of Object.entries(MATERIALS)) {
    const swiftStops = stops.map(([at, l, c, h]) => `(${at}, ${l}, ${c}, ${h})`).join(", ");
    assert.ok(swift.includes(`.${name}: [${swiftStops}]`), `材质 ${name} 的色标不一致`);
  }
  const feather = FEATHER_STOPS.map(([at, alpha]) => `(${at}, ${alpha})`).join(", ");
  assert.ok(swift.includes(`featherStops: [(Double, Double)] = [${feather}]`), "羽化色标不一致");
});

// —— 贴图卡的两条硬指标（定稿 v14 的检查脚本搬进单测：谁改颜色都要过） ——

/** OKLCH → 线性 sRGB（出界钳回 0-1），用于算 WCAG 对比度 */
function linearRgb({ l, c, h }) {
  const hr = (h * Math.PI) / 180;
  const a = c * Math.cos(hr), b = c * Math.sin(hr);
  const l3 = (l + 0.3963377774 * a + 0.2158037573 * b) ** 3;
  const m3 = (l - 0.1055613458 * a - 0.0638541728 * b) ** 3;
  const s3 = (l - 0.0894841775 * a - 1.291485548 * b) ** 3;
  return [
    4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
    -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
    -0.0041960863 * l3 - 0.7034186147 * m3 + 1.707614701 * s3,
  ].map((v) => Math.min(1, Math.max(0, v)));
}
const luminance = (c) => { const [r, g, b] = linearRgb(c); return 0.2126 * r + 0.7152 * g + 0.0722 * b; };
const contrast = (x, y) => { const [p, q] = [luminance(x), luminance(y)].sort((m, n) => n - m); return (p + 0.05) / (q + 0.05); };
const oklab = ({ l, c, h }) => [l, c * Math.cos((h * Math.PI) / 180), c * Math.sin((h * Math.PI) / 180)];

test("贴图卡：后端两张类型表里的每个 id 都有卡片配色", () => {
  assert.deepEqual(
    [...backendGenreIds()].sort((a, b) => a - b),
    Object.keys(GENRE_CARDS).map(Number).sort((a, b) => a - b),
  );
});

test("贴图卡：文字对比度 ≥ 4.5:1（渐变卡的每个色标都要过）", () => {
  for (const id of Object.keys(GENRE_CARDS).map(Number)) {
    const card = genreCardColors(id);
    for (const { color } of card.stops) {
      const ratio = contrast(color, card.ink);
      assert.ok(ratio >= 4.5, `类型 ${id} 对比度只有 ${ratio.toFixed(2)}:1`);
    }
  }
});

test("贴图卡：同一行任意两色的 OKLab 色差 ≥ 0.06（一排里不会撞色）", () => {
  // 电影行 = 电影的类型表；剧集行 = 剧集的类型表（剧集库里偶有按电影类型刮削的，不在常规行里）
  const source = readFileSync(new URL("src/movieclaw_media/genres.py", repo), "utf8");
  const table = (name) =>
    [...source.split(`${name}: dict[int, str] = {`)[1].split("}")[0].matchAll(/^\s*(\d+):/gm)].map((m) => Number(m[1]));
  for (const ids of [table("MOVIE_GENRES"), table("TV_GENRES")]) {
    for (let i = 0; i < ids.length; i++) {
      for (let j = i + 1; j < ids.length; j++) {
        const [l1, c1, h1] = GENRE_CARDS[ids[i]], [l2, c2, h2] = GENRE_CARDS[ids[j]];
        const d = Math.hypot(...oklab({ l: l1, c: c1, h: h1 }).map((v, k) => v - oklab({ l: l2, c: c2, h: h2 })[k]));
        assert.ok(d >= 0.06, `${ids[i]} 与 ${ids[j]} 色差只有 ${d.toFixed(3)}`);
      }
    }
  }
});
