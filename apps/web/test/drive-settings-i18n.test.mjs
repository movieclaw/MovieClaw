import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import React from "react";
import * as jsx from "react/jsx-runtime";
import { renderToStaticMarkup } from "react-dom/server";
import ts from "typescript";
import { appTranslator } from "../lib/i18n/translate.ts";
import { formatNumber } from "../lib/i18n/format.ts";
import { formatBytes } from "../lib/format.ts";
import { formatRelativeTime } from "../lib/time.ts";

const source = readFileSync(new URL("../components/drives-section.tsx", import.meta.url), "utf8");
function load(locale) {
  const exports = {};
  const t = appTranslator(locale);
  const control = ({ label, children }) => React.createElement("span", null, label, children);
  const dependencies = {
    "react/jsx-runtime": jsx,
    "react": { ...React, useState: (initial) => [initial, () => {}] },
    "next-intl": { useLocale: () => locale, useTranslations: () => t },
    "@/components/feedback": { usePrompt: () => () => {}, useToast: () => ({}) },
    "@/components/cloud-push-ui": { StatusPill: control },
    "@/components/settings-ui": { SettingsMoreMenu: control },
    "@/lib/i18n/translate": { appTranslator },
    "@/lib/i18n/format": { formatNumber },
    "@/lib/format": { formatBytes },
    "@/lib/time": { formatRelativeTime },
  };
  vm.runInNewContext(
    ts.transpileModule(source, {
      compilerOptions: { module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX },
    }).outputText + "\nexports.statusPill = statusPill; exports.AccountCard = AccountCard;",
    { exports, require: (name) => dependencies[name] ?? {}, Date },
  );
  return exports;
}

test("drive status uses machine values and the explicit locale, without mutating accounts", () => {
  const statuses = {
    ok: ["Working normally", "正常"], auth_expired: ["Sign in again", "要重新登录"],
    rate_limited: ["Rate limited", "限流中"], api_broken: ["API unavailable", "接口异常"],
    disabled: ["Disabled", "已停用"],
  };
  for (const [status, [en, zh]] of Object.entries(statuses)) {
    const account = Object.freeze({ status, backend_available: true });
    for (const [locale, expected] of [["en", en], ["zh-Hans", zh], ["en", en]]) {
      assert.equal(load(locale).statusPill(account, locale).label, expected);
    }
  }
  assert.equal(load("en").statusPill({ status: "ok", backend_available: false }, "en").label, "Plugin required");
});

test("cloud drive counts and emphasized stream counts are complete messages", () => {
  const en = appTranslator("en"), zh = appTranslator("zh-Hans");
  assert.equal(en("settings.drives.accountCount", { count: 1 }), "1 account signed in");
  assert.equal(en("settings.drives.accountCount", { count: 2 }), "2 accounts signed in");
  assert.equal(zh("settings.drives.accountCount", { count: 2 }), "已登录 2 个账号");
  assert.equal(renderToStaticMarkup(en.rich("settings.drives.readSlotsValue", {
    value: 2, count: (chunks) => React.createElement("b", null, chunks),
  })), "Concurrent streams: <b>2</b>");
});

test("drive SSR formats request usage and retry time in English while preserving upstream reasons", () => {
  const account = {
    id: 1, backend_available: true, status: "rate_limited", status_until: new Date(Date.now() + 3600000).toISOString(),
    backend_title: "Fixture Drive", name: "Original account", accent_color: "#123456", login_method: "form",
    login_detail: null, status_message: null, quota_total: 0, read_slots: 2, used_today: 1234, daily_budget: 5000,
  };
  const render = (row) => renderToStaticMarkup(React.createElement(load("en").AccountCard, { account: row }));
  const html = render(account);
  assert.doesNotMatch(html, /[\u3400-\u9fff]/);
  assert.match(html, /Requests today: 1,234 \/ 5,000/);
  assert.match(html, /in an hour/);
  assert.match(render({ ...account, status_message: "未知上游原因" }), /未知上游原因/);
});
