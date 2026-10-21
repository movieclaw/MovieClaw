// 生成主题运行时垫片（public/_theme-runtime/*.js）：node scripts/gen-theme-runtime.mjs [--check]
//
// 每个垫片从 globalThis.__mcThemeRuntime.modules[<裸模块名>] 取主程序的模块实例，按名字逐个转出口。
// 出口名单：React 系与 next/* 取自真实模块，SDK 取自 theme-sdk/index.ts 的值出口（类型出口不算）。
// 升级 React / Next、改 SDK 出口后重跑；--check 只比对不写（测试与 CI 用）。
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

const check = process.argv.includes("--check");
const stale = [];
for (const [spec, file] of Object.entries(THEME_RUNTIME_MODULES)) {
  const target = path.join(OUT, file);
  const next = shimSource(spec);
  const current = fs.existsSync(target) ? fs.readFileSync(target, "utf8") : null;
  if (current === next) continue;
  stale.push(file);
  if (!check) {
    fs.mkdirSync(OUT, { recursive: true });
    fs.writeFileSync(target, next);
  }
}
if (check && stale.length) {
  console.error(`主题运行时垫片过期：${stale.join("、")}——运行 node scripts/gen-theme-runtime.mjs`);
  process.exit(1);
}
console.log(check ? "主题运行时垫片已是最新" : `已生成：${stale.join("、") || "（无变化）"}`);
