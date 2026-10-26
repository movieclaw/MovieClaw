import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import React from "react";
import * as jsx from "react/jsx-runtime";
import { renderToStaticMarkup } from "react-dom/server";
import ts from "typescript";
import { appTranslator } from "../lib/i18n/translate.ts";
import { featureOff, featureOffText } from "../lib/plugins-display.ts";

function render(locale, feature, isAdmin) {
  const exports = {};
  const deps = {
    "react/jsx-runtime": jsx,
    react: { useState: (initial) => [initial, () => {}] },
    "next-intl": { useLocale: () => locale, useTranslations: () => appTranslator(locale) },
    "@/components/cloud-push-ui": { Banner: ({ title, action, children }) => React.createElement("div", null, title, action, children) },
    "@/components/feedback": { useToast: () => ({}) },
    "@/lib/features": { useFeature: () => feature },
    "@/lib/permissions": { usePermissions: () => ({ isAdmin }) },
    "@/lib/plugins-display": { featureOff, featureOffText },
  };
  const source = readFileSync(new URL("../components/feature-off-notice.tsx", import.meta.url), "utf8");
  vm.runInNewContext(ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX },
  }).outputText, { exports, require: (name) => deps[name] ?? {} });
  return renderToStaticMarkup(React.createElement(exports.FeatureOffNotice, { feature: "ingest-watch" }));
}

test("feature notice preserves Chinese copy and action permissions while rendering English metadata", () => {
  const value = { key: "ingest-watch", title: "自动入库", enabled: false, changed_by: "tester", switchable: true };
  assert.equal(render("zh-Hans", value, true), '<div>「自动入库」已停用<button type="button">重新开启</button><span class="text-[var(--text-faint)]">（由 tester 停用）</span></div>');
  assert.doesNotMatch(render("zh-Hans", value, false), /button/);
  assert.doesNotMatch(render("zh-Hans", { ...value, locked_by: "原始管理员原因" }, true), /button/);
  assert.equal(render("en", { ...value, enabled: true }, true), "");
  const english = render("en", { ...value, title: "Automatic import" }, true);
  assert.match(english, /“Automatic import” is disabled/);
  assert.match(english, /Re-enable/);
  assert.match(english, /\(Disabled by tester\)/);
  assert.doesNotMatch(english, /[\u3400-\u9fff]/);
});
