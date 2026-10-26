import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import vm from "node:vm";
import ts from "typescript";

// Exercise the public hook across renders, with deferred HTTP responses arriving out of order.
function client() {
  let locale = "en", state, deps, cleanup;
  const requests = [];
  const exports = {};
  const dependencies = {
    react: {
      useState: (initial) => {
        if (state === undefined) state = initial();
        return [state, (next) => { state = next; }];
      },
      useEffect: (effect, next) => {
        if (!deps || next.some((value, index) => value !== deps[index])) {
          cleanup?.(); deps = next; cleanup = effect();
        }
      },
    },
    "next-intl": { useLocale: () => locale },
    "@/lib/i18n/negotiate": { requestLocale: () => locale },
    "@/lib/api/plugins": { listFeatures: (language) => new Promise((resolve, reject) => {
      requests.push({ language, resolve, reject });
    }) },
  };
  const source = fs.readFileSync(new URL("../lib/features.ts", import.meta.url), "utf8");
  vm.runInNewContext(ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS },
  }).outputText, { exports, require: (name) => dependencies[name] });
  return {
    requests,
    render: (language = locale) => { locale = language; return exports.useFeature("ingest-watch"); },
    refresh: () => exports.refreshFeatures(),
    settle: () => new Promise((resolve) => setImmediate(resolve)),
  };
}
const feature = (title, enabled = false) => [{ key: "ingest-watch", title, enabled }];

test("feature titles follow the reader's language and late responses cannot leak across locales", async () => {
  const view = client();
  assert.equal(view.render(), null);
  assert.equal(view.render("zh-Hans"), null);
  assert.deepEqual(view.requests.map((request) => request.language), ["en", "zh-Hans"]);
  view.requests[1].resolve(feature("自动入库"));
  await view.settle();
  assert.equal(view.render().title, "自动入库");
  view.requests[0].resolve(feature("Automatic import"));
  await view.settle();
  assert.equal(view.render().title, "自动入库");
  view.render("en");
  assert.equal(view.render().title, "Automatic import");
  assert.equal(view.requests.length, 2);
});

test("a response started before a toggle cannot overwrite the refreshed switch state", async () => {
  const view = client();
  view.render();
  view.requests[0].resolve(feature("Automatic import", true));
  await view.settle();
  assert.equal(view.render().enabled, true);
  const beforeToggle = view.refresh();
  const afterToggle = view.refresh();
  view.requests[2].resolve(feature("Automatic import", false));
  await afterToggle;
  assert.equal(view.render().enabled, false);
  view.requests[1].resolve(feature("Automatic import", true));
  await beforeToggle;
  assert.equal(view.render().enabled, false);
});

test("failed feature reads preserve the existing fail-open behavior", async () => {
  const view = client();
  view.render();
  view.requests[0].reject(new Error("unavailable"));
  await view.settle();
  assert.equal(view.render(), null);
});
