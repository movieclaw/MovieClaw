import assert from "node:assert/strict";
import { test } from "node:test";

import { setThemeCatalog } from "../lib/theme-catalog.ts";
import {
  availableThemes,
  DEFAULT_THEME_ID,
  isKnownTheme,
  normalizeThemeId,
  THEMES,
  themeMeta,
} from "../lib/themes.ts";

test("内置注册表只有默认主题：其余主题都是插件（docs/design/theme-plugins.md）", () => {
  assert.deepEqual(
    THEMES.map((theme) => theme.id),
    ["silver"],
  );
  assert.equal(THEMES[0].layout, "panel");
  assert.equal(THEMES[0].glass, true);
});

test("normalizeThemeId：只看写法——没装的主题 id 原样保留，写法不对才兜底为默认主题", () => {
  assert.equal(normalizeThemeId("netflix"), "netflix");
  assert.equal(normalizeThemeId("silver"), "silver");
  // 没装 / 卸载了 / 停用的主题：偏好原样保留，重装后自动回来（渲染时由 themeMeta 回落）
  assert.equal(normalizeThemeId("hacker-theme"), "hacker-theme");
  // 老后端不认识 theme 字段时返回 undefined
  assert.equal(normalizeThemeId(undefined), DEFAULT_THEME_ID);
  assert.equal(normalizeThemeId(null), DEFAULT_THEME_ID);
  assert.equal(normalizeThemeId(42), DEFAULT_THEME_ID);
  // 手改缓存的垃圾值：注入不了任意属性值
  assert.equal(normalizeThemeId(""), DEFAULT_THEME_ID);
  assert.equal(normalizeThemeId('x" onload="1'), DEFAULT_THEME_ID);
  assert.equal(normalizeThemeId("Netflix"), DEFAULT_THEME_ID);
});

test("themeMeta：没装的主题回落默认主题元数据", () => {
  assert.equal(themeMeta("netflix").id, DEFAULT_THEME_ID);
  assert.equal(themeMeta("nope").id, DEFAULT_THEME_ID);
});

test("已装主题进目录后可认、可列；契约不兼容的不算", () => {
  const theme = {
    id: "ocean",
    label: "海蓝",
    description: "",
    preview: { bg: "#001020", accent: "#36c" },
    theme_color: "#001020",
    layout: "panel",
    glass: true,
    version: "1.0.0",
    source: "package",
    status: "ok",
    css: "/api/v1/ui/themes/ocean/theme.css?v=1",
    script: null,
  };
  setThemeCatalog([theme, { ...theme, id: "future", status: "incompatible", css: null }]);
  assert.equal(isKnownTheme("ocean"), true);
  assert.equal(themeMeta("ocean").label, "海蓝");
  assert.equal(themeMeta("ocean").themeColor, "#001020");
  assert.equal(isKnownTheme("future"), false);
  assert.equal(themeMeta("future").id, DEFAULT_THEME_ID);
  assert.deepEqual(
    availableThemes().map((t) => t.id),
    [...THEMES.map((t) => t.id), "ocean"],
  );
  // 卸载后目录里没有了：回落默认主题，但偏好里的 id 不受影响（normalizeThemeId 只看写法）
  setThemeCatalog([]);
  assert.equal(isKnownTheme("ocean"), false);
  assert.equal(themeMeta("ocean").id, DEFAULT_THEME_ID);
  assert.equal(normalizeThemeId("ocean"), "ocean");
});
