// 生成主题运行时的两类产物：node scripts/gen-theme-runtime.mjs [--check]
//
// 1. 垫片（public/_theme-runtime/*.js）：每个从 globalThis.__mcThemeRuntime.modules[<裸模块名>] 取主程序的
//    模块实例，按名字逐个转出口。出口名单：React 系与 next/* 取自真实模块，SDK 取自 theme-sdk/index.ts 的值出口；
// 2. 主题构建用的 Tailwind 预设（theme-sdk/tailwind-preset.css）：见 presetSource。
// 升级 React / Next / Tailwind、改 SDK 出口或主程序 @theme 后重跑；--check 只比对不写（测试与 CI 用）。
import fs from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";

import { THEME_RUNTIME_MODULES } from "../lib/theme-runtime-map.ts";

const ROOT = path.resolve(import.meta.dirname, "..");
const OUT = path.join(ROOT, "public/_theme-runtime");
const require = createRequire(path.join(ROOT, "package.json"));

/** next/link 的模块对象是组件本身（带 render / $$typeof），这里只认它真正的命名出口 */
const EXPLICIT = { "next/link": ["useLinkStatus"] };

function namedExports(spec) {
  if (EXPLICIT[spec]) return EXPLICIT[spec];
  if (spec === "@movieclaw/theme-sdk") return sdkValueExports();
  const mod = require(spec);
  return Object.keys(mod).filter((k) => /^[A-Za-z_$][\w$]*$/.test(k) && k !== "default" && !k.startsWith("__"));
}

export function sdkValueExports() {
  const src = fs.readFileSync(path.join(ROOT, "theme-sdk/index.ts"), "utf8");
  const code = src.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "");
  const names = [];
  for (const m of code.matchAll(/export\s+(type\s+)?\{([^}]*)\}/g)) {
    if (m[1]) continue; // export type { ... }
    for (const raw of m[2].split(",")) {
      const name = raw.trim();
      if (name && !name.startsWith("type ")) names.push(name);
    }
  }
  return [...new Set(names)].sort();
}

export function shimSource(spec) {
  const names = [...new Set(namedExports(spec))].sort();
  const lines = [
    `// 主题运行时垫片：${spec}（scripts/gen-theme-runtime.mjs 生成，勿手改）`,
    `const m = globalThis.__mcThemeRuntime?.modules?.[${JSON.stringify(spec)}];`,
    `if (!m) throw new Error("主题运行时未就绪：${spec}");`,
    "export default m.default ?? m;",
  ];
  if (names.length) lines.push(`export const { ${names.join(", ")} } = m;`);
  return lines.join("\n") + "\n";
}

// —— Tailwind 预设（theme-sdk/tailwind-preset.css）——
// 主题的工具类带前缀，Tailwind 会给它生成一套带前缀的设计变量（--nf-color-…）。预设把它们映射回
// 主程序的运行时变量：主题覆盖的圆角档、移动端字号换档等照常生效（docs/design/theme-plugins.md §5.3）。
// - 默认主题变量：var(--X, 默认值)——主程序生成过就用主程序的，没生成过用默认值；
// - 主程序 @theme 里的自定义变量（--text-ui 等）：var(--X)；
// - 断点、容器尺寸保持字面值：会进 @media / @container 条件，var() 在条件里不合法；
// - 动画（--animate-*）不映射：关键帧随默认主题一起生成，映射了反而丢关键帧。
function presetSource() {
  const defaults = fs.readFileSync(require.resolve("tailwindcss/theme.css"), "utf8");
  const body = defaults.slice(defaults.indexOf("@theme default {") + "@theme default {".length);
  const globals = fs.readFileSync(path.join(ROOT, "app/globals.css"), "utf8");
  const hostStart = globals.indexOf("@theme {");
  const host = globals.slice(hostStart, globals.indexOf("}", hostStart));
  const lines = [];
  const seen = new Set();
  const literal = /^--(breakpoint|container)-/;
  for (const m of body.matchAll(/(--[\w-]+(?:\\\.[\w-]+)?)\s*:\s*([^;]+);/g)) {
    const [, name, raw] = m;
    if (seen.has(name) || name.startsWith("--animate-")) continue;
    seen.add(name);
    const value = raw.replace(/\s+/g, " ").trim();
    lines.push(literal.test(name) ? `  ${name}: ${value};` : `  ${name}: var(${name}, ${value});`);
  }
  for (const m of host.matchAll(/(--[\w-]+)\s*:/g)) {
    if (!seen.has(m[1])) lines.push(`  ${m[1]}: var(${m[1]});`);
  }
  return [
    "/* 主题 Tailwind 预设（scripts/gen-theme-runtime.mjs 生成，勿手改；docs/design/theme-plugins.md §5.3） */",
    "@theme inline {",
    ...lines,
    "}",
    "",
  ].join("\n");
}

const check = process.argv.includes("--check");
const stale = [];
const outputs = [
  ...Object.entries(THEME_RUNTIME_MODULES).map(([spec, file]) => [path.join(OUT, file), () => shimSource(spec)]),
  [path.join(ROOT, "theme-sdk/tailwind-preset.css"), presetSource],
];
for (const [target, build] of outputs) {
  const file = path.relative(ROOT, target);
  const next = build();
  const current = fs.existsSync(target) ? fs.readFileSync(target, "utf8") : null;
  if (current === next) continue;
  stale.push(file);
  if (!check) {
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, next);
  }
}
if (check && stale.length) {
  console.error(`主题运行时产物过期：${stale.join("、")}——运行 node scripts/gen-theme-runtime.mjs`);
  process.exit(1);
}
console.log(check ? "主题运行时产物已是最新" : `已生成：${stale.join("、") || "（无变化）"}`);
