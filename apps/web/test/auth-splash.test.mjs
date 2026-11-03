import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import ts from "typescript";
import * as jsx from "react/jsx-runtime";

const source = readFileSync(new URL("../components/auth-gate.tsx", import.meta.url), "utf8");
const compiled = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX },
}).outputText;

function fixture(cached = false) {
  const session = { id: 1 };
  const states = [];
  const effects = [];
  const timers = new Map();
  let stateIndex, effectIndex, nextTimer = 0;
  const exports = {};
  const imports = {
    "react/jsx-runtime": jsx,
    react: {
      useState(initial) {
        const index = stateIndex++;
        if (!(index in states)) states[index] = initial;
        return [states[index], (value) => { states[index] = value; }];
      },
      useCallback: (fn) => fn,
      useEffect(run, deps) {
        const index = effectIndex++;
        // Only commit the splash effects; authentication is supplied by the fixture.
        if (deps.includes("/library")) return;
        const previous = effects[index];
        if (previous && deps.every((value, i) => Object.is(value, previous.deps[i]))) return;
        previous?.cleanup?.();
        effects[index] = { deps, run };
      },
    },
    "next/navigation": { useRouter: () => null, usePathname: () => "/library" },
    "@/lib/permissions": { accessiblePathFor: () => "/library" },
    "@/lib/session": { SessionProvider: "session-provider" },
  };
  vm.runInNewContext(compiled + (cached ? "\ncachedSession = cached;" : ""), {
    exports, cached: session, require: (key) => imports[key] ?? {},
    setTimeout: (fn, ms) => { const id = ++nextTimer; timers.set(id, { fn, ms }); return id; },
    clearTimeout: (id) => timers.delete(id),
  });
  const render = () => {
    stateIndex = effectIndex = 0;
    const tree = exports.AuthGate({ children: "workspace" });
    for (const effect of effects) {
      if (!effect?.run) continue;
      const run = effect.run;
      delete effect.run;
      effect.cleanup = run();
    }
    return tree;
  };
  return { render, timers, connect: () => { states[0] = session; },
    unmount: () => effects.forEach((effect) => effect?.cleanup?.()) };
}

test("cold startup keeps the fade, then removes the splash after rerender", () => {
  const f = fixture();
  f.render();
  f.connect();
  f.render();
  let tree = f.render();
  assert.equal(tree.props.children[1].props.leaving, true);
  assert.equal(f.timers.size, 1, "the leaving rerender must retain an unmount timer");
  const timer = [...f.timers.values()][0];
  assert.equal(timer.ms, 520);
  timer.fn();
  tree = f.render();
  assert.equal(tree.props.children[1], false);
});

test("cached sessions skip the splash; unmount cancels its timer", () => {
  const cached = fixture(true);
  assert.equal(cached.render().props.children[1], false);
  assert.equal(cached.timers.size, 0);
  const cold = fixture();
  cold.render(); cold.connect(); cold.render(); cold.render();
  assert.equal(cold.timers.size, 1);
  cold.unmount();
  assert.equal(cold.timers.size, 0);
});
