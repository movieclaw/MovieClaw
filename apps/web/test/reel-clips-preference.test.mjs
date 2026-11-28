import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import React from "react";
import * as jsx from "react/jsx-runtime";
import { renderToStaticMarkup } from "react-dom/server";
import ts from "typescript";

import { appTranslator } from "../lib/i18n/translate.ts";
import * as badges from "../lib/poster-badges.ts";

const noop = () => {};
const plain = (value) => JSON.parse(JSON.stringify(value));
const flush = () => new Promise((resolve) => setImmediate(resolve));

function loadTs(relativePath, deps = {}) {
  const source = readFileSync(new URL(relativePath, import.meta.url), "utf8");
  const exports = {};
  const output = ts.transpileModule(source, {
    compilerOptions: {
      module: ts.ModuleKind.CommonJS,
      target: ts.ScriptTarget.ES2022,
      jsx: ts.JsxEmit.ReactJSX,
    },
  }).outputText;
  vm.runInNewContext(output, { exports, require: (key) => deps[key] ?? {}, console, Error });
  return exports;
}

const uiApi = loadTs("../lib/api/ui.ts", {
  "@/lib/http": { request: () => Promise.reject(new Error("unexpected http call")) },
  "@/lib/poster-badges": badges,
  "@/lib/themes": {
    isValidThemeId: (v) => v === "silver" || v === "netflix",
    normalizeThemeId: (v) => (v === "netflix" ? "netflix" : "silver"),
  },
});

const { DEFAULT_UI_PREFS, normalizeUiPreferences } = uiApi;

function createHooks() {
  const slots = [];
  let index = 0;
  const layoutEffects = [];
  const depsChanged = (prev, next) =>
    !prev || !next || prev.length !== next.length || prev.some((d, i) => !Object.is(d, next[i]));
  const memo = (compute, deps) => {
    const k = index++;
    if (!slots[k] || depsChanged(slots[k].deps, deps)) slots[k] = { value: compute(), deps };
    return slots[k].value;
  };
  const react = {
    ...React,
    useState(initial) {
      const k = index++;
      if (!(k in slots)) slots[k] = { value: typeof initial === "function" ? initial() : initial };
      const slot = slots[k];
      return [slot.value, (v) => (slot.value = typeof v === "function" ? v(slot.value) : v)];
    },
    useRef(initial) {
      const k = index++;
      if (!(k in slots)) slots[k] = { current: initial };
      return slots[k];
    },
    useMemo: memo,
    useCallback: (fn, deps) => memo(() => fn, deps),
    useEffect() {},
    useLayoutEffect(fn, deps) {
      const k = index++;
      if (!slots[k] || depsChanged(slots[k].deps, deps)) layoutEffects.push(fn);
      slots[k] = { deps };
    },
    useSyncExternalStore: (_subscribe, getSnapshot) => getSnapshot(),
  };
  return {
    react,
    begin: () => (index = 0),
    runLayoutEffects: () => layoutEffects.splice(0).forEach((fn) => fn()),
  };
}

function loadPreferenceComponent(locale, { prefs, savePrefs = async () => {}, fetchedAllowed = null } = {}) {
  const hooks = createHooks();
  const capturedToggles = [];
  const node = ({ title, label, description, error, children }) =>
    React.createElement(
      "section",
      null,
      title && React.createElement("h3", null, title),
      label && React.createElement("span", { "data-label": true }, label),
      description && React.createElement("p", { "data-desc": true }, description),
      error && React.createElement("p", { role: "alert" }, error),
      children,
    );
  const exports = loadTs("../components/reel-clips-preference-row.tsx", {
    "react/jsx-runtime": jsx,
    react: hooks.react,
    "next-intl": { useLocale: () => locale, useTranslations: () => appTranslator(locale) },
    "@/components/cloud-push-ui": {
      Toggle: (props) => {
        capturedToggles.push(props);
        return React.createElement("button", {
          role: "switch",
          "aria-checked": String(props.checked),
          "aria-label": props.label,
          disabled: props.disabled,
        });
      },
    },
    "@/components/settings-ui": {
      SettingsSection: node,
      SettingsList: node,
      SettingsRow: node,
    },
    "@/lib/api/reels": {
      fetchReelClipPolicy: () =>
        Promise.resolve({ allowed: Boolean(fetchedAllowed), preferred: false, effective: false }),
    },
    "@/lib/ui-prefs": {
      useUiPrefs: () => ({
        prefs: prefs ?? DEFAULT_UI_PREFS,
        savePrefs,
      }),
    },
  });
  const render = (component, props = {}) => {
    capturedToggles.length = 0;
    hooks.begin();
    const element = component(props);
    return element ? renderToStaticMarkup(element) : "";
  };
  return { exports, render, capturedToggles };
}

test("reels preference defaults to false and normalizes safely from legacy or malformed payloads", () => {
  assert.deepEqual(plain(DEFAULT_UI_PREFS.reels), { use_clips: false });
  assert.deepEqual(plain(normalizeUiPreferences(undefined).reels), { use_clips: false });
  assert.deepEqual(plain(normalizeUiPreferences(null).reels), { use_clips: false });
  assert.deepEqual(plain(normalizeUiPreferences({}).reels), { use_clips: false });
  assert.deepEqual(plain(normalizeUiPreferences({ reels: { use_clips: true } }).reels), {
    use_clips: true,
  });
  // 非布尔脏值兜底为 false
  assert.deepEqual(plain(normalizeUiPreferences({ reels: { use_clips: "yes" } }).reels), {
    use_clips: false,
  });
});

test("member preference toggle visibility follows admin allowed state across zh-Hans, en, and de", () => {
  for (const locale of ["zh-Hans", "en", "de"]) {
    const offCtx = loadPreferenceComponent(locale, { prefs: DEFAULT_UI_PREFS });
    assert.equal(offCtx.render(offCtx.exports.ReelClipsPreferenceRow, { allowed: false }), "");
    assert.equal(offCtx.render(offCtx.exports.ReelClipsPreferenceRow, { allowed: null }), "");
    assert.equal(offCtx.render(offCtx.exports.ReelClipsPreferenceSection, { allowed: false }), "");

    const onCtx = loadPreferenceComponent(locale, {
      prefs: { ...DEFAULT_UI_PREFS, reels: { use_clips: true } },
    });
    const rowHtml = onCtx.render(onCtx.exports.ReelClipsPreferenceRow, { allowed: true });
    assert.match(rowHtml, /aria-checked="true"/);
    if (locale === "zh-Hans") {
      assert.match(rowHtml, /片段预切（我的使用偏好）/);
      assert.match(rowHtml, /不改变后台预切或删除已切好的片段/);
    } else {
      assert.doesNotMatch(rowHtml, /[\u3400-\u9fff]/);
    }
    const sectionHtml = onCtx.render(onCtx.exports.ReelClipsPreferenceSection, { allowed: true });
    assert.ok(sectionHtml.length > 0);
    if (locale !== "zh-Hans") {
      assert.doesNotMatch(sectionHtml, /[\u3400-\u9fff]/);
    }
  }
});

test("toggling saves through UiPrefsProvider with optimistic update, read-back, and rollback on failure", async () => {
  const hooks = createHooks();
  const pending = [];
  let serverStored = plain(DEFAULT_UI_PREFS);
  const cacheWrites = [];
  const providerExports = loadTs("../lib/ui-prefs.tsx", {
    "react/jsx-runtime": jsx,
    react: hooks.react,
    "next-intl": { useLocale: () => "zh-Hans", useTranslations: () => appTranslator("zh-Hans") },
    "@/lib/i18n/provider": { useLanguage: () => ({ setLanguage: noop }) },
    "@/components/feedback": { useToast: () => ({ error: noop }) },
    "@/lib/api/ui": {
      fetchUiPreferences: () => new Promise(() => {}),
      normalizeUiPreferences,
      updateUiPreferences: (body) =>
        new Promise((resolve, reject) => {
          pending.push({
            body: plain(body),
            resolve() {
              serverStored = plain(body);
              resolve(plain(body));
            },
            reject() {
              reject(new Error("network down"));
            },
          });
        }),
    },
    "@/lib/theme-catalog": {
      catalogTheme: () => undefined,
      subscribeThemeCatalog: () => noop,
      themeCatalogFresh: () => true,
      themeCatalogVersion: () => 0,
    },
    "@/lib/theme-catalog-sync": { refreshThemeCatalog: () => Promise.resolve() },
    "@/lib/theme-runtime": {
      ensureThemeStylesheet: noop,
      loadedDefinition: () => null,
      loadTheme: noop,
      subscribeThemeRuntime: () => noop,
      themeLoadStatus: () => "idle",
      themeRuntimeVersion: () => 0,
      themeSlotErrors: () => [],
    },
    "@/lib/themes": {
      DEFAULT_THEME_ID: "silver",
      PHONE_THEME_QUERY: "",
      isKnownTheme: () => true,
      normalizeThemeId: (id) => id ?? "silver",
      themeMeta: (id) => ({ id, label: id, glass: true, themeColor: "#000", layout: {} }),
    },
    "@/lib/use-media-query": { useMediaQuery: () => false },
    "@/lib/poster-badges": badges,
    "@/lib/ui-prefs-cache": {
      readUiPrefsCache: () => plain(DEFAULT_UI_PREFS),
      writeUiPrefsCache: (value) => cacheWrites.push(plain(value)),
    },
    "@/lib/wall-badges": { setWallBadgeRequest: noop },
  });
  const readContext = () => {
    hooks.begin();
    return providerExports.UiPrefsProvider({ children: null }).props.value;
  };

  // 1. 乐观更新并成功保存 + 写入本地缓存
  const ctx1 = readContext();
  assert.equal(ctx1.prefs.reels.use_clips, false);
  const comp = loadPreferenceComponent("zh-Hans", {
    prefs: ctx1.prefs,
    savePrefs: ctx1.savePrefs,
  });
  comp.render(comp.exports.ReelClipsPreferenceRow, { allowed: true });
  comp.capturedToggles[0].onChange(true);
  await flush();
  assert.equal(readContext().prefs.reels.use_clips, true, "optimistic update takes effect immediately");
  assert.equal(pending.length, 1);
  assert.equal(pending[0].body.reels.use_clips, true);
  pending.shift().resolve();
  await flush();
  await flush();
  assert.equal(serverStored.reels.use_clips, true);
  assert.equal(readContext().savedPrefs.reels.use_clips, true);
  assert.equal(cacheWrites.at(-1).reels.use_clips, true);

  // 2. 再次切换关闭但服务端失败 → 乐观值回滚回服务端确认值 true，界面显示报错
  const ctx2 = readContext();
  const failComp = loadPreferenceComponent("zh-Hans", {
    prefs: ctx2.prefs,
    savePrefs: ctx2.savePrefs,
  });
  failComp.render(failComp.exports.ReelClipsPreferenceRow, { allowed: true });
  failComp.capturedToggles[0].onChange(false);
  await flush();
  assert.equal(readContext().prefs.reels.use_clips, false, "optimistic off before server response");
  pending.shift().reject();
  await flush();
  await flush();
  assert.equal(readContext().prefs.reels.use_clips, true, "rolled back to server-confirmed true");
  assert.equal(serverStored.reels.use_clips, true);
  const afterFailHtml = failComp.render(failComp.exports.ReelClipsPreferenceRow, { allowed: true });
  assert.match(afterFailHtml, /network down/);
});
