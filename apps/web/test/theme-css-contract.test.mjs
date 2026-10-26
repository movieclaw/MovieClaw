import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";

/**
 * CSS 契约（docs/design/theme-plugins.md §4.4）：主题可以覆盖的内核变量与可以依赖的内核类名
 * （src/movieclaw_sdk/theme_css.json，随服务端发布，插件开发技能的检查脚本也读它）。守护：
 * 1. 表里的变量、类在内核里都还在——内核改名 / 删除会在这里被拦下（那是契约主版本变更）；
 * 2. 第一方主题引用的内核类都在表里——主题新依赖一个内核类，要有意识地登记。
 */
const WEB = path.resolve(import.meta.dirname, "..");
const REPO = path.resolve(WEB, "../..");
const contract = JSON.parse(fs.readFileSync(path.join(REPO, "src/movieclaw_sdk/theme_css.json"), "utf8"));
const { parts } = contract;

function walk(dir, exts, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === "node_modules" || entry.name.startsWith(".next")) continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full, exts, out);
    else if (exts.some((e) => entry.name.endsWith(e))) out.push(full);
  }
  return out;
}

const kernelSource = ["app", "components", "lib", "vendor"]
  .flatMap((d) => walk(path.join(WEB, d), [".css", ".tsx", ".ts"]))
  .map((f) => fs.readFileSync(f, "utf8"))
  .join("\n");

test("公开部件在内核里都还在", () => {
  const missing = parts.filter((cls) => !new RegExp(`(?<![\\w-])${cls.replace(/[-]/g, "\\-")}(?![\\w-])`).test(kernelSource));
  assert.deepEqual(missing, []);
});

test("公开变量与只读变量在内核里都有定义", () => {
  // 圆角档来自 Tailwind 默认主题（rounded-* 工具类读它们），其余在 globals.css 的 :root / @theme
  const defined = new Set(
    [fs.readFileSync(path.join(WEB, "app/globals.css"), "utf8"), fs.readFileSync(path.join(WEB, "node_modules/tailwindcss/theme.css"), "utf8")]
      .flatMap((css) => [...css.matchAll(/(--[\w-]+)\s*:/g)].map((m) => m[1])),
  );
  const missing = [...Object.keys(contract.variables), ...Object.keys(contract.readonly)].filter((name) => !defined.has(name));
  assert.deepEqual(missing, []);
});

test("第一方主题引用的内核类都登记在公开部件里", () => {
  const themes = path.join(REPO, "plugins");
  const known = new Set(parts);
  const unknown = new Set();
  for (const id of fs.readdirSync(themes)) {
    const src = path.join(themes, id, "src");
    if (!fs.existsSync(path.join(src, "theme.css"))) continue;
    // 主题自有类名带自己的前缀（构建参数 --prefix，nf → nf-xxx）
    const pkg = fs.readFileSync(path.join(themes, id, "package.json"), "utf8");
    const own = `${/--prefix\s+(\w+)/.exec(pkg)?.[1] ?? id}-`;
    const css = fs.readFileSync(path.join(src, "theme.css"), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
    for (const sel of css.matchAll(/([^{}@;]+)\{/g)) {
      for (const m of sel[1].matchAll(/\.([A-Za-z_][\w-]*)/g)) {
        if (!m[1].startsWith(own) && !known.has(m[1])) unknown.add(`${id}/theme.css: .${m[1]}`);
      }
    }
  }
  assert.deepEqual([...unknown].sort(), []);
});
