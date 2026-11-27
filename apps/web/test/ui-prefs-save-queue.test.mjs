import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import React from "react";
import * as jsx from "react/jsx-runtime";
import ts from "typescript";

import * as badges from "../lib/poster-badges.ts";

/**
 * UiPrefsProvider 的写入顺序（PR #1250 第二轮评审）：连点开关时会连着发几次整份 PUT，
 * 较旧的请求后完成不能把服务端、界面、缓存写回旧值；失败回滚也只认最新那次。
 *
 * 真实源码转译后在沙箱里跑（与 poster-badges.test.mjs 同一手法），React 换成一个极简的
 * 钩子模拟：按调用顺序存 state / ref / memo，普通 effect 不跑（不发首拉），layout effect
 * 记下来由用例手动执行。每次「渲染」就是把 Provider 当函数调一遍，取它给 Context 的 value。
 */

const { DEFAULT_POSTER_BADGES } = badges;
const BASE = {
  theme: "silver",
  language: "auto",
  scrim: { blur: 0, dark: 0 },
  poster_badges: DEFAULT_POSTER_BADGES,
};

const plain = (value) => JSON.parse(JSON.stringify(value));
const flush = () => new Promise((resolve) => setImmediate(resolve));

function createHooks() {
  const slots = [];
  let index = 0;
  const layoutEffects = [];
  const depsChanged = (prev, next) => !prev || !next || prev.length !== next.length || prev.some((d, i) => !Object.is(d, next[i]));
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

/** 假服务端：PUT 挂起，由用例决定完成顺序；完成那一刻才落库（模拟后到的请求覆盖先到的）。 */
function createServer(initial) {
  const server = { stored: plain(initial), pending: [], inFlight: 0, maxInFlight: 0 };
  server.put = (body) =>
    new Promise((resolve, reject) => {
      server.inFlight += 1;
      server.maxInFlight = Math.max(server.maxInFlight, server.inFlight);
      server.pending.push({
        body: plain(body),
        resolve() {
          server.inFlight -= 1;
          server.stored = plain(body);
          resolve(plain(body));
        },
        reject() {
          server.inFlight -= 1;
          reject(new Error("save failed"));
        },
      });
    });
  return server;
}

function mountProvider(initial) {
  const hooks = createHooks();
  const server = createServer(initial);
  const cacheWrites = [];
  const wallWrites = [];
  const deps = {
    "react/jsx-runtime": jsx,
    react: hooks.react,
    "next-intl": { useLocale: () => "en", useTranslations: () => (key) => key },
    "@/lib/i18n/provider": { useLanguage: () => ({ setLanguage() {} }) },
    "@/components/feedback": { useToast: () => ({ error() {} }) },
    "@/lib/api/ui": {
      fetchUiPreferences: () => new Promise(() => {}),
      normalizeUiPreferences: (raw) => ({ ...BASE, ...raw }),
      updateUiPreferences: (body) => server.put(body),
    },
    "@/lib/theme-catalog": {
      catalogTheme: () => undefined,
      subscribeThemeCatalog: () => () => {},
      themeCatalogFresh: () => true,
      themeCatalogVersion: () => 0,
    },
    "@/lib/theme-catalog-sync": { refreshThemeCatalog: () => Promise.resolve() },
    "@/lib/theme-runtime": {
      ensureThemeStylesheet() {},
      loadedDefinition: () => null,
      loadTheme() {},
      subscribeThemeRuntime: () => () => {},
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
      readUiPrefsCache: () => plain(initial),
      writeUiPrefsCache: (value) => cacheWrites.push(plain(value)),
    },
    "@/lib/wall-badges": { setWallBadgeRequest: (value) => wallWrites.push(value) },
  };
  const exports = {};
  const source = readFileSync(new URL("../lib/ui-prefs.tsx", import.meta.url), "utf8");
  const output = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.ReactJSX },
  }).outputText;
  vm.runInNewContext(output, { exports, require: (key) => deps[key] ?? {}, console });
  const render = () => {
    hooks.begin();
    return exports.UiPrefsProvider({ children: null }).props.value;
  };
  return { render, server, cacheWrites, wallWrites, runLayoutEffects: hooks.runLayoutEffects };
}

/** 像设置页那样：基于这一刻渲染出的最新偏好翻一个开关并保存，记下保存的结局。 */
function toggle(ctx, key) {
  const { prefs, savePrefs } = ctx.render();
  const next = { ...prefs, poster_badges: { ...prefs.poster_badges, [key]: true } };
  const outcome = { settled: false, error: null };
  savePrefs(next).then(
    () => Object.assign(outcome, { settled: true }),
    (error) => Object.assign(outcome, { settled: true, error }),
  );
  return outcome;
}

/** 每轮先完成「最后发出」的那个请求（逆序），直到没有挂起的请求。 */
async function resolveNewestFirst(server, action = "resolve") {
  await flush();
  while (server.pending.length) {
    server.pending.pop()[action]();
    await flush();
  }
}

const badgesOf = (prefs) => plain(prefs.poster_badges);
const BOTH_ON = { ...DEFAULT_POSTER_BADGES, rating: true, year: true };

test("requests resolved in reverse order never write an older setting back", async () => {
  const ctx = mountProvider(BASE);
  const first = toggle(ctx, "rating");
  const second = toggle(ctx, "year");
  await resolveNewestFirst(ctx.server);

  assert.deepEqual(badgesOf(ctx.server.stored), BOTH_ON, "server keeps the newest value");
  const { prefs, savedPrefs } = ctx.render();
  assert.deepEqual(badgesOf(prefs), BOTH_ON, "UI keeps the newest value");
  assert.deepEqual(badgesOf(savedPrefs), BOTH_ON);
  assert.deepEqual(badgesOf(ctx.cacheWrites.at(-1)), BOTH_ON, "cache keeps the newest value");
  assert.equal(ctx.server.maxInFlight, 1, "writes are serialised: one PUT in flight at a time");
  assert.ok(first.settled && !first.error);
  assert.ok(second.settled && !second.error);
});

test("a superseded request failing does not roll back the newer optimistic value", async () => {
  const ctx = mountProvider(BASE);
  const first = toggle(ctx, "rating");
  const second = toggle(ctx, "year");
  await flush();
  // 最早的那次失败，此时更新的保存还没落定
  ctx.server.pending.shift().reject();
  await flush();
  assert.deepEqual(badgesOf(ctx.render().prefs), BOTH_ON, "newer optimistic value stays on screen");
  assert.ok(first.settled && !first.error, "superseded failure is not reported: the newer save decides");

  await resolveNewestFirst(ctx.server);
  assert.deepEqual(badgesOf(ctx.server.stored), BOTH_ON);
  assert.deepEqual(badgesOf(ctx.render().prefs), BOTH_ON);
  assert.ok(second.settled && !second.error);
});

test("when the newest request fails, roll back to what the server last confirmed", async () => {
  const ctx = mountProvider(BASE);
  const first = toggle(ctx, "rating");
  const second = toggle(ctx, "year");
  await flush();
  ctx.server.pending.shift().resolve();
  await flush();
  // 较旧的成功不动界面：更新的乐观值还在
  assert.deepEqual(badgesOf(ctx.render().prefs), BOTH_ON);
  ctx.server.pending.shift().reject();
  await flush();

  const confirmed = { ...DEFAULT_POSTER_BADGES, rating: true };
  assert.deepEqual(badgesOf(ctx.server.stored), confirmed);
  assert.deepEqual(badgesOf(ctx.render().prefs), confirmed, "rolled back to the server's value, not an older snapshot");
  assert.ok(first.settled && !first.error);
  assert.equal(second.error?.message, "save failed", "the newest failure is reported to the caller");
});

test("wall badges request is published on commit (layout effect), not during render", () => {
  const ctx = mountProvider({ ...BASE, poster_badges: { ...DEFAULT_POSTER_BADGES, progress: true } });
  ctx.render();
  assert.deepEqual(ctx.wallWrites, [], "render alone leaves the module value untouched");
  ctx.runLayoutEffects();
  assert.deepEqual(ctx.wallWrites, ["progress"]);
  ctx.render();
  ctx.runLayoutEffects();
  assert.deepEqual(ctx.wallWrites, ["progress"], "unchanged value is not rewritten");
});
