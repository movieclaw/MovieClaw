// 主题插件构建器（docs/design/theme-plugins.md §4.7）。在主题插件目录里运行：
//
//   node <repo>/apps/web/theme-sdk/build.mjs --prefix nf --out <目录>      产物：<目录>/movieclaw-plugin.toml + theme/
//   node <repo>/apps/web/theme-sdk/build.mjs --prefix nf --pack <目录>     另出 <目录>/<id>-<版本>.mcplugin
//
// 主题目录约定：movieclaw-plugin.toml、src/index.tsx（外框组件，可没有）、src/theme.css（外观）、
// src/assets/（可选，原样拷到 theme/assets/）。
//
// - JS：esbuild 打成一个 ES 模块，react / react-dom / react/jsx-runtime / next/link / next/navigation /
//   @movieclaw/theme-sdk 是外部模块（运行时由 import map 指到主程序的垫片）；除此之外只能 import 主题
//   目录里的相对路径，引了别的直接报错——内核其余模块对主题不可见；
// - CSS：Tailwind 工具类带前缀（--prefix），设计变量经 SDK 预设映射到主程序的运行时变量；
//   主题自己的 src/theme.css 接在后面（全部规则挂 html[data-theme="<id>"]）。
import fs from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { execFileSync } from "node:child_process";

const SDK_DIR = import.meta.dirname;
const EXTERNAL = [
  "react",
  "react-dom",
  "react/jsx-runtime",
  "next",
  "next/link",
  "next/navigation",
  "@movieclaw/theme-sdk",
];

function arg(name) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

const dir = process.cwd();
const prefix = arg("prefix");
const out = arg("out");
const packDir = arg("pack");
if (!prefix || !/^[a-z]{2,8}$/.test(prefix)) throw new Error("--prefix 必填：2～8 个小写字母（Tailwind 工具类前缀）");
if (!out && !packDir) throw new Error("--out 或 --pack 至少给一个");

const require = createRequire(path.join(dir, "package.json"));
const esbuild = require("esbuild");
const postcss = require("postcss");
const tailwind = require("@tailwindcss/postcss");

const manifestText = fs.readFileSync(path.join(dir, "movieclaw-plugin.toml"), "utf8");
const id = /^id\s*=\s*"([^"]+)"/m.exec(manifestText)?.[1];
const version = /^version\s*=\s*"([^"]+)"/m.exec(manifestText)?.[1];
if (!id || !version) throw new Error("movieclaw-plugin.toml 缺 [plugin] id / version");

async function buildJs(target) {
  const entry = path.join(dir, "src/index.tsx");
  if (!fs.existsSync(entry)) return false;
  const boundary = {
    name: "theme-boundary",
    setup(build) {
      build.onResolve({ filter: /.*/ }, (args) => {
        if (args.kind === "entry-point" || args.path.startsWith(".")) return undefined;
        if (EXTERNAL.includes(args.path)) return { path: args.path, external: true };
        return {
          errors: [
            {
              text: `主题只能 import ${EXTERNAL.join(" / ")} 与主题目录内的相对路径（引用了 ${args.path}）`,
            },
          ],
        };
      });
    },
  };
  await esbuild.build({
    entryPoints: [entry],
    bundle: true,
    format: "esm",
    platform: "browser",
    target: "es2022",
    jsx: "automatic",
    minify: true,
    legalComments: "none",
    plugins: [boundary],
    outfile: path.join(target, "index.js"),
    logLevel: "warning",
  });
  return true;
}

async function buildCss(target) {
  const own = fs.readFileSync(path.join(dir, "src/theme.css"), "utf8");
  const preset = path.join(SDK_DIR, "tailwind-preset.css");
  const input = [
    `@import "tailwindcss/theme.css" layer(theme) prefix(${prefix});`,
    `@import "${preset}";`,
    `@import "tailwindcss/utilities.css" layer(utilities);`,
    `@source "${path.join(dir, "src")}";`,
  ].join("\n");
  const from = path.join(dir, "src/__tailwind__.css");
  const result = await postcss([tailwind({ base: path.join(dir, "src"), optimize: { minify: false } })]).process(input, {
    from,
  });
  const css = `${result.css}\n/* —— ${id} 主题外观（src/theme.css）—— */\n${own}`;
  checkGenerated(result.css);
  fs.writeFileSync(path.join(target, "theme.css"), css);
}

/**
 * 源码里写了的带前缀工具类必须都生成出来。Tailwind 按词扫描源码，有些写法扫不到（实测：
 * 类名紧贴模板字符串的 ${ 时漏掉），漏了不报错、只在页面上表现为样式缺失——这里在构建期拦住。
 */
function checkGenerated(css) {
  const used = new Set();
  const pattern = new RegExp(`(?<![\\w:-])${prefix}:[^\\s"'\`$]+`, "g");
  for (const file of fs.readdirSync(path.join(dir, "src"), { recursive: true })) {
    if (!/\.(tsx?|jsx?)$/.test(file)) continue;
    for (const m of fs.readFileSync(path.join(dir, "src", file), "utf8").matchAll(pattern)) used.add(m[0]);
  }
  const escape = (cls) => cls.replace(/[^A-Za-z0-9_-]/g, (c) => `\\${c}`);
  const missing = [...used].filter((cls) => !css.includes(`.${escape(cls)}`)).sort();
  if (missing.length) {
    throw new Error(
      `这些工具类写在源码里却没有生成（检查写法：类名后面要有空格或引号，别紧贴 \${）：\n  ${missing.join("\n  ")}`,
    );
  }
}

function copyAssets(target) {
  const assets = path.join(dir, "src/assets");
  if (fs.existsSync(assets)) fs.cpSync(assets, path.join(target, "assets"), { recursive: true });
}

async function buildInto(root) {
  fs.rmSync(path.join(root, "theme"), { recursive: true, force: true });
  const target = path.join(root, "theme");
  fs.mkdirSync(target, { recursive: true });
  fs.copyFileSync(path.join(dir, "movieclaw-plugin.toml"), path.join(root, "movieclaw-plugin.toml"));
  const hasJs = await buildJs(target);
  await buildCss(target);
  copyAssets(target);
  return hasJs;
}

if (out) {
  const root = path.resolve(dir, out);
  const hasJs = await buildInto(root);
  console.log(`主题 ${id} v${version} → ${path.relative(process.cwd(), root)}${hasJs ? "（含外框组件）" : "（纯样式）"}`);
}
if (packDir) {
  const stage = fs.mkdtempSync(path.join(fs.realpathSync(require("node:os").tmpdir()), `theme-${id}-`));
  await buildInto(stage);
  const target = path.resolve(dir, packDir);
  fs.mkdirSync(target, { recursive: true });
  const file = path.join(target, `${id}-${version}.mcplugin`);
  fs.rmSync(file, { force: true });
  execFileSync("zip", ["-qr", "-X", file, "movieclaw-plugin.toml", "theme"], { cwd: stage });
  fs.rmSync(stage, { recursive: true, force: true });
  console.log(`已打包：${path.relative(process.cwd(), file)}`);
}
