import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import React from "react";
import * as jsx from "react/jsx-runtime";
import { renderToStaticMarkup } from "react-dom/server";
import ts from "typescript";
import { appTranslator } from "../lib/i18n/translate.ts";
import * as welcomeScenes from "../lib/welcome-scenes.ts";

const noop = () => {};
function load(path, locale, states = []) {
  let index = 0;
  const imports = {
    "react/jsx-runtime": jsx,
    "react": { ...React, useState: (initial) => [index < states.length ? states[index++] : initial, noop], useEffect: noop },
    "next-intl": { useTranslations: () => appTranslator(locale), useLocale: () => locale },
    "next-intl/server": { getTranslations: async () => appTranslator(locale) },
    "next/font/local": { default: () => ({ variable: "font" }) },
    "@/lib/image-width": { responsiveImage: (src) => ({ src }) },
    "@/lib/session": { initialsOf: (name) => name[0] },
    "@/components/icons": { XIcon: () => null },
    "@/lib/welcome-scenes": welcomeScenes,
  };
  const source = readFileSync(new URL(path, import.meta.url), "utf8") + (path.includes("welcome-screen") ? "\nexport { FilmSubtitles };" : "");
  const exports = {};
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.ReactJSX } }).outputText, { exports, require: (key) => imports[key] ?? {} });
  return exports;
}
const render = (component, props) => renderToStaticMarkup(React.createElement(component, props));
const pages = [
  ["../app/(app)/apps/[plugin]/layout.tsx", "插件页面"],
  ["../app/(app)/my/page.tsx", "我的"],
  ["../app/(app)/new/page.tsx", "新任务"],
  ["../app/(app)/people/[id]/page.tsx", "影人"],
  ["../app/(app)/subscriptions/[id]/page.tsx", "订阅详情"],
  ["../app/(app)/subscriptions/page.tsx", "我的订阅"],
  ["../app/play/[mediaItemId]/[[...unit]]/page.tsx", "播放"],
  ["../app/(app)/settings/[section]/[item]/page.tsx", "作者插件 · 插件 · 设置"],
];

test("server metadata keeps original Chinese titles and renders reader-local English with raw plugin names", async () => {
  for (const [path, title] of pages) {
    for (const locale of ["zh-Hans", "en"]) {
      const metadata = await load(path, locale).generateMetadata({ params: Promise.resolve({ item: encodeURIComponent("作者插件") }) });
      if (locale === "zh-Hans") assert.equal(metadata.title, title);
      else assert.doesNotMatch(metadata.title.replaceAll("作者插件", "Author plugin"), /[\u3400-\u9fff]/);
    }
  }
});

test("avatar and quote accessibility translate instructions while retaining source names and dialogue", () => {
  const quote = { line: "作者\n原句", original: null, film: "作者片名", filmEnglish: "Author Film", year: 2024, english: "Author\nline" };
  const before = JSON.stringify(quote);
  for (const locale of ["zh-Hans", "en"]) {
    const avatar = render(load("../components/avatar-badge.tsx", locale).AvatarBadge, { nickname: "原始昵称", avatarUrl: "/api/v1/auth/avatar?v=source" });
    assert.match(avatar, /src="\/api\/v1\/auth\/avatar\?v=source"/);
    assert.match(avatar, locale === "en" ? /alt="原始昵称’s avatar"/ : /alt="原始昵称 的头像"/);
    const html = render(load("../components/welcome-screen.tsx", locale, [[quote], 0, 0, null]).FilmSubtitles);
    assert.match(html, locale === "en" ? /aria-label="“Author line” — Author Film\. Tap for another quote\."/ : /aria-label="作者原句——《作者片名》。轻点换一句台词"/);
    // 英文界面里华语片仍附中文原句；中文界面不出英文
    if (locale === "en") assert.match(html, /作者\n原句/);
    else assert.doesNotMatch(html, /Author/);
    const empty = render(load("../components/welcome-screen.tsx", locale, [null, 0, 0, null]).FilmSubtitles);
    assert.match(empty, locale === "en" ? /aria-label="Quote"/ : /aria-label="台词"/);
  }
  assert.equal(JSON.stringify(quote), before);
});
