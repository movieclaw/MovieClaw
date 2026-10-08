import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import ts from "typescript";

const component = readFileSync(new URL("../components/viewport-keyboard.tsx", import.meta.url), "utf8");
const compiled = ts.transpileModule(component, { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText;
const layout = readFileSync(new URL("../app/layout.tsx", import.meta.url), "utf8");
const initial = layout.match(/const SYNC_VIEWPORT_OVERSHOOT_SCRIPT = `([^`]+)`;/)[1];

function fixture({ standalone = true, ios = true, height = 912, screenHeight = 912, safeTop = 68 } = {}) {
  const props = new Map();
  const attrs = new Set();
  const events = new Map();
  let cleanup;
  let focused = false;
  const root = { clientHeight: 844, style: {
    setProperty: (key, value) => props.set(key, value), removeProperty: (key) => props.delete(key),
  }, setAttribute: (key) => attrs.add(key), removeAttribute: (key) => attrs.delete(key) };
  const target = (prefix) => ({
    addEventListener: (event, handler) => events.set(prefix + event, handler),
    removeEventListener: (event) => events.delete(prefix + event),
  });
  const vv = { height, scale: 1, ...target("vv:") };
  const window = { innerHeight: height, visualViewport: vv, CSS: {}, matchMedia: () => ({ matches: standalone }),
    scrollX: 0, scrollY: 0, setTimeout: (fn) => fn(), ...target("window:") };
  const context = vm.createContext({ window, navigator: {}, screen: { height: screenHeight },
    CSS: { supports: () => ios }, document: { documentElement: root, visibilityState: "visible", ...target("document:") },
    getComputedStyle: () => ({ getPropertyValue: () => `${safeTop}px` }), exports: {},
    require: (name) => name === "react" ? { useEffect: (effect) => { cleanup = effect(); } } : { softKeyboardPossible: () => focused },
  });
  vm.runInContext(compiled, context);
  return { props, attrs, events, window, vv, context, root,
    initial: () => vm.runInContext(initial, context), mount: () => context.exports.ViewportKeyboard(),
    sync: () => context.exports.syncViewportOvershoot(), focus: (value) => { focused = value; }, cleanup: () => cleanup() };
}

test("PWA canvas uses full viewport even when percentage containing block is shorter", () => {
  for (const height of [844, 912]) {
    const f = fixture({ height });
    f.initial();
    assert.equal(f.props.get("--pwa-height"), "912px");
    f.sync();
    assert.equal(f.props.get("--pwa-height"), "912px");
    assert.ok(f.attrs.has("data-ios-standalone"));
  }
});

test("browser tabs and Android are unchanged; iPad split windows are not stretched", () => {
  for (const options of [{ standalone: false }, { ios: false }]) {
    const f = fixture(options); f.initial(); f.sync();
    assert.equal(f.props.size, 0);
    assert.equal(f.attrs.size, 0);
  }
  const f = fixture({ height: 700, screenHeight: 1366, safeTop: 24 });
  f.initial(); f.sync();
  assert.equal(f.props.get("--pwa-height"), "700px");
});

test("foreground, bfcache and rotation recalibrate; keyboard never shrinks root canvas", () => {
  const f = fixture(); f.mount();
  assert.equal(f.props.get("--pwa-height"), "912px");
  f.focus(true); f.vv.height = 500;
  f.events.get("vv:resize")();
  assert.equal(f.props.get("--app-height"), "500px");
  assert.equal(f.props.get("--pwa-height"), "912px");
  f.focus(false); f.vv.height = 912;
  f.events.get("window:focusout")();
  assert.equal(f.props.has("--app-height"), false);
  for (const event of ["window:pageshow", "document:visibilitychange", "window:resize"]) {
    f.props.set("--pwa-height", "844px"); f.events.get(event)();
    assert.equal(f.props.get("--pwa-height"), "912px");
  }
  f.window.innerHeight = 420; f.vv.height = 420;
  f.events.get("window:resize")();
  assert.equal(f.props.get("--pwa-height"), "420px");
  f.vv.scale = 2; f.window.innerHeight = 210; f.sync();
  assert.equal(f.props.get("--pwa-height"), "420px");
  f.cleanup(); assert.equal(f.events.size, 0);
});
