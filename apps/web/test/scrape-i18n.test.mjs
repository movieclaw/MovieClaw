import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import ts from "typescript";
import { appTranslator } from "../lib/i18n/translate.ts";
import { formatList } from "../lib/i18n/format.ts";

const source = readFileSync(new URL("../components/scrape-settings-section.tsx", import.meta.url), "utf8");
const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX } }).outputText;
const exports = {};
vm.runInNewContext(compiled, { exports, TextEncoder, require: (name) => {
  if (name === "@/lib/i18n/translate") return { appTranslator };
  if (name === "@/lib/format") return { formatList };
  return {};
} });
const { describeScrapeValues } = exports;

// Explicit locale must work in SSR, including nested summaries and language factories.
test("scraping summaries preserve Chinese and translate nested values without browser globals", () => {
  const setting = { language_priority: ["zh-CN", "ja-JP"], cert_country_priority: ["CN", "JP"],
    image_quality: "original", naming_entry_dir: "{title}", naming_movie_file: "", naming_season_dir: "", naming_episode_file: "",
    mirror_images: true, mirror_nfo: false, mirror_episode_thumbs: true, poster_min_width: 500,
    fanart_enabled: true, poster_source_order: ["tmdb", "fanart"], backdrop_source_order: ["tmdb", "fanart"],
    logo_source_order: ["fanart", "tmdb"], season_poster_source_order: ["fanart", "tmdb"] };
  const before = structuredClone(setting);
  const keys = ["language_priority", "cert_country_priority", "image_quality", "naming_entry_dir", "mirror_images", "poster_min_width", "fanart_enabled"];
  assert.equal(describeScrapeValues(keys, setting, "zh-Hans"), "中文（简体） → 日本語 · 中国 → 日本 · 原图 · 已改：条目目录 · 不写：NFO 元数据 · 海报 ≥500 · TMDB + Fanart.tv · 片名 Logo、季海报优先 Fanart");
  for (const locale of ["en", "zh-Hans", "en"]) {
    const summary = describeScrapeValues(keys, setting, locale);
    if (locale === "en") {
      assert.doesNotMatch(summary, /[\u3400-\u9fff]/u);
      assert.match(summary, /Chinese \(Simplified\) → Japanese/);
      assert.match(summary, /Fanart first for Title logo and Season poster/);
    }
    assert.deepEqual(setting, before);
  }
});
