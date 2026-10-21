import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";

import { isThemeModuleUrl, THEME_RUNTIME_BASE, THEME_RUNTIME_MODULES, themeImportMap } from "../lib/theme-runtime-map.ts";

const ROOT = path.resolve(import.meta.dirname, "..");

test("主题运行时垫片与真实模块、SDK 出口同步（升级 React / Next、改 SDK 后要重新生成）", () => {
  // 过期时脚本以非零退出码结束，execFileSync 抛错
  execFileSync(process.execPath, [path.join(ROOT, "scripts/gen-theme-runtime.mjs"), "--check"], {
    cwd: ROOT,
    stdio: "pipe",
  });
});

test("import map 覆盖每个垫片，垫片文件都在 public 下", () => {
  const map = themeImportMap().imports;
  assert.deepEqual(Object.keys(map).sort(), Object.keys(THEME_RUNTIME_MODULES).sort());
  for (const [name, file] of Object.entries(THEME_RUNTIME_MODULES)) {
    assert.equal(map[name], `${THEME_RUNTIME_BASE}/${file}`);
    assert.ok(fs.existsSync(path.join(ROOT, "public", THEME_RUNTIME_BASE, file)), file);
  }
});

test("主题模块只认主程序托管的地址（同源、/ui/themes/<id>/ 下的 .js）", () => {
  const origin = "https://nas.example";
  assert.equal(isThemeModuleUrl("/api/v1/ui/themes/netflix/index.js?v=1.0.0-abc", origin), true);
  assert.equal(isThemeModuleUrl("https://nas.example/api/v1/ui/themes/netflix/index.js", origin), true);
  assert.equal(isThemeModuleUrl("https://evil.example/api/v1/ui/themes/netflix/index.js", origin), false);
  assert.equal(isThemeModuleUrl("//evil.example/api/v1/ui/themes/netflix/index.js", origin), false);
  assert.equal(isThemeModuleUrl("/api/v1/ui/themes/netflix/theme.css", origin), false);
  assert.equal(isThemeModuleUrl("/api/v1/plugins/acme/web/app.js", origin), false);
  assert.equal(isThemeModuleUrl("javascript:alert(1)", origin), false);
});
