import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import ts from "typescript";
import { appTranslator } from "../lib/i18n/translate.ts";
import { formatRelativeTime } from "../lib/time.ts";

const source = readFileSync(new URL("../components/site-config-section.tsx", import.meta.url), "utf8");
const exports = {};
vm.runInNewContext(
  ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX },
  }).outputText + "\nexports.nextSyncLabel = nextSyncLabel;",
  { exports, require: () => ({ appTranslator, formatRelativeTime }), Date },
);

test("next site sync renders the explicit SSR locale without labeling a past deadline as future", () => {
  const future = new Date(Date.now() + 60 * 60 * 1000).toISOString();
  for (const locale of ["en", "zh-Hans", "en"]) {
    const soon = locale === "en" ? "Starting soon" : "即将开始";
    assert.equal(exports.nextSyncLabel(null, locale), soon);
    assert.equal(exports.nextSyncLabel("2000-01-01T00:00:00Z", locale), soon);
    assert.equal(exports.nextSyncLabel(future, locale), formatRelativeTime(future, locale));
  }
});

test("site counts, retention periods and retry choices use complete messages", () => {
  const en = appTranslator("en");
  const zh = appTranslator("zh-Hans");
  assert.equal(en("settings.sites.healthySummary", { count: 1 }), "1 site connected, working normally");
  assert.equal(en("settings.sites.healthySummary", { count: 2 }), "2 sites connected, all working normally");
  assert.equal(zh("settings.sites.healthySummary", { count: 1200 }), "已接入 1200 个站点，全部正常");
  assert.equal(en("settings.sites.days", { count: 1 }), "1 day");
  assert.equal(en("settings.sites.days", { count: 3 }), "3 days");
  assert.equal(zh("settings.sites.days", { count: 3 }), "3 天");
});

test("site detail formats all owned text in the explicit SSR locale without a browser document", async () => {
  const React = await import("react");
  const jsx = await import("react/jsx-runtime");
  const { renderToStaticMarkup } = await import("react-dom/server");
  const format = await import("../lib/format.ts");
  const time = await import("../lib/time.ts");
  const { formatNumber } = await import("../lib/i18n/format.ts");
  const exported = {};
  const dependencies = {
    "react/jsx-runtime": jsx,
    "next-intl": { useLocale: () => "en", useTranslations: () => appTranslator("en") },
    "@/lib/format": format,
    "@/lib/time": time,
    "@/lib/i18n/format": { formatNumber },
    "@/lib/i18n/translate": { appTranslator },
  };
  vm.runInNewContext(
    ts.transpileModule(source, {
      compilerOptions: { module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX },
    }).outputText + "\nexports.SiteDetail = SiteDetail;",
    { exports: exported, require: (name) => dependencies[name] ?? {}, Date },
  );
  const html = renderToStaticMarkup(React.createElement(exported.SiteDetail, {
    site: {
      auth_type: "apikey", boost_enabled: false, boost_downloader_id: null,
      last_checked_at: null,
      profile: {
        username: "Original user", user_class: "Original class", fetched_at: null,
        seeding_count: 2, bonus: 10000, uploaded_bytes: 2048, downloaded_bytes: 1024, ratio: 2,
      },
    },
    stats: { torrent_count: 1234, last_sync_at: null, next_sync_at: null, sync_interval_seconds: 1800 },
    downloaders: [],
  }));
  assert.doesNotMatch(html, /[\u3400-\u9fff]/);
  assert.match(html, /10K/);
  assert.match(html, /30 minutes/);
  assert.match(html, /Original user/);
});
