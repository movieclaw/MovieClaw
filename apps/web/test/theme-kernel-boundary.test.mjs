import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";

/**
 * 内核不认识具体主题（docs/design/theme-plugins.md §4.3「内核自身的清理」）。
 *
 * 内核 = apps/web 下除主题目录（themes/<id>/）以外的源码。内核代码里不允许出现：
 * - 主题名 netflix（白名单：流媒体平台数据、设备授权页说明——那里的 Netflix 是外部产品，不是主题）；
 * - `structural` 判断（已由版式 useLayout() 取代）；
 * - `nf-` 前缀的类名 / 变量（主题自有前缀，内核写给主题的信号一律用中性名）。
 * 注释不查：注释里提 Netflix 多是「参照 Netflix 的做法」这类设计依据。
 */
const ROOT = path.resolve(import.meta.dirname, "..");
const SCAN = ["app", "components", "lib", "vendor", "themes/registry.tsx", "themes/types.ts", "middleware.ts"];
const ALLOW_NETFLIX = new Set(["lib/platforms.ts", "components/device-approval.tsx"]);

function files(rel) {
  const abs = path.join(ROOT, rel);
  if (!fs.existsSync(abs)) return [];
  if (fs.statSync(abs).isFile()) return [rel];
  return fs.readdirSync(abs, { withFileTypes: true }).flatMap((d) =>
    d.isDirectory() ? files(path.join(rel, d.name)) : /\.(tsx?|css|mjs)$/.test(d.name) ? [path.join(rel, d.name)] : [],
  );
}

/** 去掉注释（块注释、JSX 注释、行注释），保留字符串。够用即可：只服务这条守护。 */
function stripComments(src) {
  return src
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/(^|[^:"'`\\])\/\/.*$/gm, "$1");
}

test("内核代码不出现主题名、structural 与 nf- 前缀", () => {
  const hits = [];
  for (const rel of SCAN.flatMap(files)) {
    const code = stripComments(fs.readFileSync(path.join(ROOT, rel), "utf8"));
    code.split("\n").forEach((line, i) => {
      if (/netflix/i.test(line) && !ALLOW_NETFLIX.has(rel)) hits.push(`${rel}:${i + 1} netflix: ${line.trim()}`);
      if (/\bstructural\b/.test(line)) hits.push(`${rel}:${i + 1} structural: ${line.trim()}`);
      if (/(^|[^\w-])-{0,2}nf-[a-z]/.test(line)) hits.push(`${rel}:${i + 1} nf-: ${line.trim()}`);
    });
  }
  assert.deepEqual(hits, []);
});
