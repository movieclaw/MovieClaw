import assert from "node:assert/strict";
import test from "node:test";
import { libraryStatus, inventoryLabel } from "../lib/library-manage.ts";
import { scanLibraryConfirm, refreshLibraryConfirm, refreshItemConfirm, rereadLibraryNfoConfirm, rereadItemNfoConfirm, chapterImagesConfirm } from "../lib/library-confirm.ts";

const library = { scanning: false, organizing: false, metadata_refresh: null, chapter_job: null, cloud_upload: null, last_scan: null, kind: "movie", stats: { item_count: 1, file_count: 2, missing_count: 0, unidentified_count: 0 } };
const context = { phaseLabels: { ingesting: "Scanning" }, relativeTime: () => "just now" };

test("library status and counts update in each language without changing library data", () => {
  const previous = globalThis.document;
  try {
    for (const locale of ["en", "zh-Hans", "en"]) {
      globalThis.document = { documentElement: { lang: locale } };
      const status = libraryStatus(library, context);
      assert.equal(status.title, locale === "en" ? "Idle" : "空闲");
      assert.equal(status.detail, locale === "en" ? "Not scanned yet" : "尚未扫描");
      assert.equal(inventoryLabel(library).primary, locale === "en" ? "1 title" : "1 部");
      assert.equal(inventoryLabel({ ...library, kind: "photo" }).primary, locale === "en" ? "1 photo" : "1 张");
      assert.equal(inventoryLabel(library).secondary, locale === "en" ? "2 files" : "2 个文件");
      const missing = libraryStatus({ ...library, stats: { ...library.stats, missing_count: 1, unidentified_count: 2 } }, context);
      assert.equal(missing.title, locale === "en" ? "2 unidentified · 1 missing" : "2 个待识别 · 1 个缺失");
    }
  } finally {
    if (previous === undefined) delete globalThis.document;
    else globalThis.document = previous;
  }
});

test("library confirmations retain file safety details, literal NFO tags and names", () => {
  const previous = globalThis.document;
  try {
    globalThis.document = { documentElement: { lang: "en" } };
    const options = [scanLibraryConfirm, refreshLibraryConfirm, refreshItemConfirm, rereadLibraryNfoConfirm, rereadItemNfoConfirm, chapterImagesConfirm].map((make) => make("我的媒体"));
    for (const option of options) {
      assert.ok(option.title.includes("我的媒体"));
      const content = JSON.stringify(option).replaceAll("我的媒体", "");
      assert.doesNotMatch(content, /[\u3400-\u9fff]/u);
    }
    assert.ok(rereadLibraryNfoConfirm("NFO").bullets.some((line) => line.includes("<set>")));
    assert.ok(scanLibraryConfirm("Movies", ["Drive A", "Drive B", "Drive A"]).bullets.some((line) => line.includes("Drive A and Drive B")));
    globalThis.document.documentElement.lang = "zh-Hans";
    assert.equal(scanLibraryConfirm("电影").title, "扫描「电影」？");
    assert.equal(rereadLibraryNfoConfirm("录像").bullets[1], "NFO 里写了系列（<set>）的，按库设置自动归进系列合集");
  } finally {
    if (previous === undefined) delete globalThis.document;
    else globalThis.document = previous;
  }
});
