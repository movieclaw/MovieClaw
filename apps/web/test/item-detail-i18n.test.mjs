import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import ts from "typescript";
import { appTranslator } from "../lib/i18n/translate.ts";
import { requestLocale } from "../lib/i18n/negotiate.ts";
import { languageLabel } from "../lib/language-labels.ts";
import { mediaSourceDisplayLabel } from "../lib/media-source-annotation.ts";
import { refreshItemConfirm, rereadItemNfoConfirm } from "../lib/library-confirm.ts";

const file = readFileSync(new URL("../components/media-track-rows.tsx", import.meta.url), "utf8");
const compiled = ts.transpileModule(file, { compilerOptions: { module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX } }).outputText;
const exports = {};
vm.runInNewContext(compiled + "\nexports.audioEntries = audioEntries; exports.subtitleEntries = subtitleEntries; exports.groupByLanguage = groupByLanguage;", {
  exports, TextEncoder, require(name) {
    if (name === "@/lib/i18n/translate") return { appTranslator };
    if (name === "@/lib/i18n/negotiate") return { requestLocale };
    if (name === "@/lib/language-labels") return { languageLabel };
    return {};
  },
});
const { audioEntries, subtitleEntries, groupByLanguage } = exports;

test("track labels translate without changing references, preferred order, or original titles", () => {
  const audio = [
    { codec: "aac", channels: 2, language: "chi", default: true, title: "原始配音标题" },
    { codec: "aac", channels: 1, language: "eng", default: false },
  ];
  const subtitles = [
    { codec: "subrip", language: "eng", default: true, external: false },
    { codec: "ass", language: null, title: "ai-chs", external: true, file_name: "Clip.ai.chs.ass" },
    { codec: "subrip", language: null, external: false },
  ];
  const before = structuredClone({ audio, subtitles });
  let identifiers;
  for (const locale of ["en", "zh-Hans", "en"]) {
    const tracks = audioEntries(audio, null, locale);
    const subs = subtitleEntries(subtitles, "Clip", null, locale);
    assert.match(tracks[0].primary, /原始配音标题/);
    assert.equal(tracks[1].primary, locale === "en" ? "AAC · Mono" : "AAC · 单声道");
    assert.equal(tracks[0].language, locale === "en" ? "Chinese" : "中文");
    assert.equal(subs[1].language, locale === "en" ? "Simplified Chinese" : "简体中文");
    assert.equal(subs[2].language, locale === "en" ? "Unspecified language" : "未标语言");
    const ordered = [...groupByLanguage(tracks, locale), ...groupByLanguage(subs, locale)].map(g => g.entries.map(e => [e.key, e.rank, e.order, e.preview?.track]));
    identifiers ??= JSON.stringify(ordered);
    assert.equal(JSON.stringify(ordered), identifiers);
    assert.deepEqual({ audio, subtitles }, before);
  }
});
test("SSR confirmations and source labels use the explicitly requested language", () => {
  assert.equal(mediaSourceDisplayLabel("user-lowest", "en"), "Lowest tier (manually annotated)");
  assert.equal(mediaSourceDisplayLabel("Disc", "en"), "Disc");
  assert.equal(mediaSourceDisplayLabel("Disc", "zh-Hans"), "原盘");
  for (const confirm of [refreshItemConfirm, rereadItemNfoConfirm]) {
    const value = confirm("User title", "en");
    assert.doesNotMatch(JSON.stringify(value), /[\u3400-\u9fff]/u);
    assert.match(JSON.stringify(value), /User title/);
  }
});
test("deletion and inventory summaries use full messages and preserve Chinese copy", () => {
  const en = appTranslator("en"), zh = appTranslator("zh-Hans");
  assert.equal(en("library.item.playCount", { count: 1 }), "Watched 1 time");
  assert.equal(en("library.item.playCount", { count: 2 }), "Watched 2 times");
  assert.equal(en("library.item.episodeStatus", { episode: 2, owned: "no", played: "yes" }), "Episode 2 (missing) (watched)");
  assert.equal(zh("library.item.episodeStatus", { episode: 2, owned: "no", played: "yes" }), "第 2 集（缺集）（已看完）");
  assert.equal(zh("library.transfer.previewSummary", { paths: 1, size: "2 GB", missing: 3 }), "1 个路径 · 2 GB · 3 个缺失记录随迁");
  assert.equal(zh("library.item.deleteFileAcknowledge", { last: "no" }), "我已明白：该文件及其同名附属文件将被永久删除，无法恢复。");
});
