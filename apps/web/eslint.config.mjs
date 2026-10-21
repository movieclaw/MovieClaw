import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

import { FlatCompat } from "@eslint/eslintrc";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const compat = new FlatCompat({
  baseDirectory: __dirname,
});

const eslintConfig = [
  {
    // vendor/ 是从 liquidglass-oss 内联的第三方源码，按原样保留，不参与本项目 lint。
    ignores: [".next*/**", "next-env.d.ts", "vendor/**"],
  },
  ...compat.extends("next/core-web-vitals", "next/typescript"),
  {
    rules: {
      // 发现页海报直接引用 TMDB 图床（由浏览器经用户网络环境访问），
      // 不走 next/image 的服务端优化代理（服务端出网不一定可达该图床），故放行原生 <img>。
      "@next/next/no-img-element": "off",
    },
  },
  {
    // 主题目录只经主题 SDK 用内核能力（docs/design/theme-plugins.md §3 第 3 条）：
    // 拆成插件包后，能解析到的外部模块只有这几个（import map 垫片），其余一律打进主题包
    files: ["themes/*/**"],
    rules: {
      "no-restricted-imports": [
        "error",
        {
          patterns: [
            {
              regex: "^(?!react$|react-dom$|react/jsx-runtime$|next$|next/link$|next/navigation$|@movieclaw/theme-sdk$|\\.{1,2}/)",
              message: "主题只能 import react / react-dom / next/link / next/navigation / @movieclaw/theme-sdk 与主题目录内的相对路径",
            },
          ],
        },
      ],
    },
  },
];

export default eslintConfig;
