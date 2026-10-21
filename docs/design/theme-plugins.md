# 主题插件：主题做成可安装、可卸载的插件包

> 状态：**P0～P6 已实施**（2026-10-21；§8 为用户确认的决定，§7 验收结果见文末「验收记录」）。范围：只做网页；原生端没有主题，不涉及。
> 关联：`theme-framework/`（现有的主题坑位注册表，本稿在它之上把「编进包里的主题」变成「运行时装上的主题」）、
> `web-themes.md`、`plugin-web-pages.md`（插件网页、授信与同意、静态托管）、`plugin-phase3.md`（插件包、批准）、
> `plugin-channels.md` §7（随带插件包）、`plugin-dependencies.md`（`requires` 契约版本）。

## 0. 结论先行

**目标（用户定）**：Netflix 主题成为一个独立插件包——装上、启用后观感与现在逐像素一致；卸载后站点功能正常、回到默认主题；
再装回来一切照旧。

**一句话分工：内核拥有「页面与版式」，主题拥有「外观与外框」。**

| 层 | 归谁 | 内容 | 例子 |
|---|---|---|---|
| 页面 | 内核 | 每个功能页的数据、行为、内容编排 | 媒体库、详情、发现、搜索、设置各分区 |
| 版式 | 内核提供有限几种，主题**声明**用哪种 | 页面在不同外框下的排布方式 | `panel`（侧栏 + 居中面板，银玻璃）/ `cinema`（顶栏 + 满出血大图，Netflix） |
| 外框 | 主题**可替换**（坑位） | 导航、标签栏、返回键、页顶 Hero、主题专属整页 | 顶栏、底栏、设置菜单、Billboard、「我的」页 |
| 外观 | 主题 | 设计变量、公开部件的样式、外框自己的样式 | 品牌红、纯黑底、圆角档、按钮形态 |

1. **主题包 = 普通插件包 + `theme/` 目录**。`theme.css` 必需（外观），`index.js` 可选（外框组件，标准 ES 模块，默认导出
   `ThemeDefinition`——就是今天 `themes/netflix/theme.tsx` 导出的那个东西）。只有 CSS 的主题就是 Obsidian 式的纯换肤主题。
2. **静态事实写在清单里，代码只放组件**：名称、预览色、状态栏色、版式、是否用液态玻璃写在 `movieclaw-plugin.toml` 的
   `[theme]` 段；外框组件在 `index.js`。内核不执行主题代码就能列出、校验、展示主题。
3. **主题代码与主程序共用一份 React**：用 **import maps**（HTML 标准）把 `react`、`react/jsx-runtime`、`next/link`、
   `next/navigation`、`@movieclaw/theme-sdk` 映射到主程序提供的垫片模块。主题作者照常写 React，构建时把这几个包标成外部依赖即可。
4. **`@movieclaw/theme-sdk` 是主题能碰到的全部内核能力**：一个门面文件、一份清单，按「外框真用到的」收（v1 = Netflix 实际
   用到的那些，80 个出口，其中图标 15、类型 8），带版本（`requires."ui.theme"`）和导出快照测试。
5. **主题坏了不能把站弄坏**：加载失败 / 版本不兼容 / 运行时报错 → 整体回落默认主题并提示；单个坑位报错 → 该坑位回落基础实现；
   安全模式下插件包主题不加载（随带主题照常，与随带插件包同口径）。设置 → 外观永远可达。
6. **卸载不动用户数据**：偏好里存的主题 id 原样保留，找不到对应主题时按默认主题渲染；重装后自动恢复。

## 1. 现状与差距（2026-10-21 盘点）

theme-framework 改造已经把主题收进 `apps/web/themes/netflix/`，业务组件只经 `themes/registry.tsx` 取坑位。但离「独立插件」
还差四块：

| 差距 | 规模 | 说明 |
|---|---|---|
| **内核里的 Netflix 分支** | 30 个文件、约 112 处 | `useTheme().structural`（局部名多叫 `isNf` / `isNetflix`）在页面里分叉排布：发现页 Hero 满出血、工具栏浮在 Hero 上、详情页桌面 Hero、设置页内边距、`NfSessionCard`……这些不是 Netflix 目录里的代码，卸载插件后它们还在 |
| **内核里的 Netflix 命名** | 若干 | `nf-hero-live` / `--nf-hero-recede`（详情页滚动退场）、`nf-nav-offset`、`nf-icon-btn`、`nf-kenburns`、`brand-loader--netflix`；`globals.css` 里 `html:not([data-theme="netflix"])` 三条规则；`lib/ui-prefs.tsx` 的 `netflix: "#000000"`；`lib/themes.ts` 的 Netflix 元信息 |
| **主题组件直接 import 内核** | 约 45 个符号、30 个模块 | `@/components/*`、`@/lib/api/*`、`@/lib/permissions`、`@/lib/session`……没有边界，内核随便改名主题就坏 |
| **样式编在主程序的构建里** | `tokens.css` 795 行 | 只有 48 个是变量；77 组规则直接改写内核类名（`.glass-panel`、`.btn-accent`、`.modal-panel`、`.lg-button__thumb`……）。另外主题组件大量用 Tailwind 工具类，这些类现在由主程序的 Tailwind 扫描生成——主题搬出去后主程序就不再生成它们 |

服务端已经就绪的：插件包格式与批准流程、纯网页插件包（`entry` 可空）、包内静态托管、`requires` 契约校验、随带插件包、
安全模式。偏好里的主题 id 本来就是自由字符串（`settings/schemas.py` 的 `theme` / `theme_desktop` / `theme_mobile`），不用迁移。

## 2. 参照

| 产品 | 做法 | 取了什么 |
|---|---|---|
| VS Code 颜色主题 | 扩展清单 `contributes.themes` 静态声明（含 `uiTheme` 基底），主题本身只是一份颜色变量表；工作台布局归内核 | 静态事实进清单；「版式」由内核提供、主题只选基底 |
| Obsidian 主题 | `manifest.json` + `theme.css`，官方公开一张 CSS 变量表作为契约 | 纯 CSS 主题就是最简形态；公开变量表 |
| Grafana 插件 | 运行时加载插件模块，`react`、`@grafana/ui`、`@grafana/runtime` 由宿主提供、插件构建时标外部 | 共享 React + 一个宿主 SDK 门面 |
| Tailwind 多份构建同页 | 官方 `prefix()` 选项，专为「一个页面里有多份 Tailwind 产物」设计 | 主题自己的工具类加前缀，不和主程序撞（§5.3） |

## 3. 插件该做什么（作者视角）

```
netflix/
  movieclaw-plugin.toml
  theme/
    theme.css          # 必需：外观。全部规则挂 html[data-theme="netflix"]
    index.js           # 可选：外框组件（ESM，default export ThemeDefinition）
    assets/            # 字体、图片：CSS 里用相对 url()，JS 里用 new URL("./x.png", import.meta.url)
```

```toml
[plugin]
id = "netflix"                 # 主题 id = 插件 id；沿用 "netflix"，老用户的偏好不用迁移
title = "Netflix 主题"
version = "1.0.0"
                               # entry 留空：纯主题包不启动后端进程（与纯网页插件同规则）
[requires]
"ui.theme" = "^1.0"

[theme]
label = "Netflix"
description = "纯黑影院风，顶栏导航、大图首屏"
preview = { bg = "#141414", accent = "#e50914" }   # 外观页的选择卡
theme_color = "#000000"        # 浏览器地址栏 / PWA 状态栏
layout = "cinema"              # 版式：panel | cinema（§4.2）
glass = false                  # 是否用液态玻璃（WebGL）
```

`index.js`（源码是 TSX，作者自己构建成 ESM）：

```tsx
import { useState } from "react";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { useAppNavItems, SearchCommand, NoticeCenter, type ThemeDefinition } from "@movieclaw/theme-sdk";

function TopNav(props) { /* 照常写 React */ }

export default {
  slots: { desktopTopNav: TopNav, mobileTabBar: TabBar, settingsNav: SettingsMenu, detailNav, pageActions, libraryHero: Billboard },
  pages: { my: MyPage, subscriptions: SubscriptionsPage },
} satisfies ThemeDefinition;
```

作者要遵守的只有四条：

1. **CSS 全部挂自己的作用域** `html[data-theme="<id>"]`（不在作用域里的规则会影响别的主题，打包工具会报错）。
2. **自己的类名带前缀**（Netflix 用 `nf-`）；引用内核类名只能引用**公开部件表**里的（§4.4）。Tailwind 工具类同样加前缀（§5.3）。
3. **JS 只能 import** `react`、`react-dom`、`react/jsx-runtime`、`next/link`、`next/navigation`、`@movieclaw/theme-sdk`，
   其余依赖自己打进包里。
4. **外壳几何写成 CSS 变量**（移动顶栏让位高度、底栏形态与高度、悬浮偏移，§4.5），不写 JS。

## 4. 内核该做什么

### 4.1 主题契约 `ui.theme`（一份版本号管五样东西）

| 组成 | 内容 | 事实源 |
|---|---|---|
| 主题定义 | `ThemeDefinition = { slots, pages }`，坑位名与 props 类型 | `themes/types.ts`（去掉 `meta` / `capabilities`，它们进清单） |
| 清单 `[theme]` 段 | 字段与取值 | `plugins/packages.py` 的模型 |
| SDK 出口 | `@movieclaw/theme-sdk` 导出的组件、钩子、函数 | 门面文件 + 导出快照测试 |
| CSS 契约 | 公开变量表 + 公开部件表 + 外壳几何变量 | 一份表（§4.4），带守护测试 |
| 版式取值 | `panel` / `cinema` | 内核 |

- 内核在 `movieclaw_kernel.contracts` 登记 `ui.theme` 的当前版本；装包时走现有 `check_requires`，不兼容拒装并写明原因。
- **加东西 = 次版本**（新坑位、新 SDK 出口、新变量）；**删 / 改签名 = 主版本**。内核同一时间只支持一个主版本；主版本升级时，
  已装主题在插件页显示「需要更新」，不加载、回落默认主题。
- React 主版本跟着走：React 升主版本即 `ui.theme` 升主版本（垫片导出的是主程序的 React）。

### 4.2 版式：内核里留两套排布，不按主题名分叉

现在那 112 处 `structural` 分支，本质是「页面在两种外框下怎么排」。把它们搬进插件，等于让插件重写二十多个页面——SDK 会膨胀成
半个前端。所以版式归内核，主题只声明用哪种：

- `panel`：侧栏 + 居中内容面板（最大宽度 1500px）+ iOS 式移动端顶栏 / 悬浮底栏。银玻璃用。
- `cinema`：全局顶栏（由主题的 `desktopTopNav` 坑位提供，`cinema` 版式必须提供，否则回落 `panel`）+ 满出血内容 + 大图首屏 +
  实底移动顶栏 / 停靠底栏。Netflix 用；以后别的影院风主题也能选。

**改法**：`useTheme().structural` 全部换成 `useLayout() === "cinema"`，逐处过一遍，按下面的规则分流：

| 分支在干什么 | 处理 | 例子 |
|---|---|---|
| 结构（摆在哪、占不占一条、满不满出血、谁持有顶栏） | 留在内核，条件改为版式 | 发现页工具栏浮在 Hero 上、`collection-grid` 去掉最大宽度、`app-shell` 走顶栏骨架 |
| 纯观感（颜色、描边、按下态） | 删分支，改读变量或交给主题 CSS 的公开部件 | `settings-ui` 选中态 `bg-white text-black`、详情页链接色 `text-white/55` |
| 整块组件换形态 | 能用 CSS 表达的走部件；表达不了的立一个坑位 | `NfSessionCard`（先看能否用部件样式表达） |

**这是本稿最大的取舍**：卸载 Netflix 后，`cinema` 版式的代码仍在内核里（只是没人选）。换来的是插件只需要提供外框和外观，
SDK 有边界。

### 4.3 前端运行时

**首帧（防闪烁，沿用 next-themes 式脚本）**

- 根布局 `<head>` 固定一条 `<link rel="stylesheet" href="/api/v1/ui/themes.css">`。这个文件由服务端生成，内容只是每个已启用主题一行
  `@import url("/api/v1/ui/themes/<id>/theme.css?v=<版本>");`——各主题 CSS 的相对 `url()` 按自己的地址解析，不用改写；
  带版本号的文件可以长期缓存，聚合文件本身用 `ETag` + `no-cache`。所有主题 CSS 都挂在各自的 `html[data-theme]` 作用域下，
  一起加载互不影响（与现在 `tokens.css` 常驻 `globals.css` 等价）。
- 防闪烁脚本：不再用白名单（任何 `[a-z0-9-]` 的 id 都写到 `data-theme`，没装的主题不匹配任何 CSS，等于默认）；状态栏色读
  本地缓存的快照；外壳几何不再由脚本写，改由主题 CSS 直接声明变量（§4.5）。另外按缓存的主题 id 补一条
  `<link rel="modulepreload">`，让主题代码与登录态探测并行下载。
- 根布局放一份 import map：`{"imports": {"react": "/_theme-runtime/react.js", …, "@movieclaw/theme-sdk": "/_theme-runtime/sdk.js"}}`。
  垫片是构建时生成的静态文件，内容是 `const m = globalThis.__mcThemeRuntime.react; export const { useState, … } = m;`，
  导出名从真实模块枚举而来，有快照测试。

**加载与切换**

- `ThemeRuntime`（外壳根部的客户端组件）先把主程序的模块实例挂到 `globalThis.__mcThemeRuntime`，再
  `import(/* webpackIgnore: true */ url)` 主题模块。用原生动态导入而不是打包器的，所以与 webpack / Turbopack 都无关。
- 外壳**等主题就绪再渲染**（与登录态探测并行；有 `modulepreload` 时几乎无感）；超过 8 秒按失败处理。没有 `index.js` 的纯 CSS 主题
  不用等。
- 校验模块形状：坑位名必须在已知清单里、值必须是组件；不合规按加载失败处理。
- **切换是原子的**：外观页点选后先加载新主题模块，就绪后再同时切 `data-theme` 和坑位，不会出现「新颜色 + 旧外框」的半截状态。

**出错**

| 情况 | 处理 |
|---|---|
| 主题模块 404 / 语法错 / 超时 / 形状不对 / 契约不兼容 | 本次会话整体回落默认主题（去掉 `data-theme`，否则会是「Netflix 配色 + 银玻璃外框」的混搭），顶部提示「主题「Netflix」加载失败，已临时使用默认主题」，附插件页链接 |
| 某个坑位渲染时抛错 | 错误边界接住，该坑位回落基础实现（没有基础实现的不渲染），提示一次 |
| 安全模式 | 服务端不提供插件包主题（随带主题照常）；表现同「主题不存在」 |
| 主题被卸载 / 停用 | 同上；偏好不改，重装后恢复 |

**内核自身的清理**

- `lib/themes.ts` 的静态 `THEMES` 改为：默认主题的内置元信息 + `GET /api/v1/ui/themes` 拉到的已装主题。外观页的选择卡据此渲染。
- 所有 `nf-*` 内核命名改成中性名（`hero-recede`、`nav-offset`、`icon-btn`、`backdrop-kenburns`……）；`globals.css` 里涉及
  Netflix 的规则搬进主题 CSS；`html:not([data-theme="netflix"])` 改成「内核写默认，主题覆盖」。
- **守护测试**：内核代码里不允许出现主题名（白名单：`lib/platforms.ts` 的流媒体平台数据、设备授权页的说明文字）；
  不允许出现 `structural`。

### 4.4 CSS 契约：公开变量 + 公开部件

- **公开变量表**：现有语义变量（`--bg`、`--text`、`--line`、`--accent`、`--surface-raised`、`--page-fog`、圆角档、字号档……）
  逐个登记成表，写清用途。主题优先只改变量。
- **公开部件表**：变量表达不了的（形状、阴影、按下态），内核把这些类名**承诺为稳定接口**：`.glass-panel`、`.btn-accent`、
  `.btn-glass`、`.menu-surface`、`.modal-panel`、`.toast-item`、`.tooltip-bubble`、`.lg-button__*`……以 Netflix 现在实际改写的
  77 组规则为准建表。改部件类名 = 契约主版本变更。
- 打包工具做静态检查：主题 CSS 里出现的类名，要么带主题前缀，要么在部件表里；否则报错。
- 迁移顺序：先**原样**把 77 组规则登记成部件（保证逐像素一致），以后有余力再把部件逐步收成变量——这一步不在本次范围。
- 落地：两张表在 `src/movieclaw_sdk/theme_css.json`（`variables` 可覆盖、`readonly` 只读、`parts` 部件），随服务端发布，
  `movieclaw_sdk.theme` 读出给插件开发技能的检查脚本用（主题 CSS 没挂作用域却改了表里的东西就报错）；
  内核侧由 `apps/web/test/theme-css-contract.test.mjs` 守着表里的名字都还在。作者指南见 `docs/guides/theme-authoring.md`。
- 契约 1.1（P6）：加 `--scrim-rgb`（全局蒙版颜色）与 `--backdrop-tint`（罩在背景大图上的色）。玻璃版式下页面大面积的颜色
  来自背景大图 + 蒙版，`--bg` 只在图没铺上时露出，原先纯 CSS 主题改不了整体色调；两个变量缺省值与原先的写死值相同，
  银玻璃与 Netflix 逐像素不变。`--surface-sidebar` / `--surface-main` 内核从不读取（面板是 WebGL 玻璃或 `.panel--*` 部件），
  不进公开表。

### 4.5 外壳几何改由 CSS 声明

现在 `ThemeChrome`（移动顶栏让位高度、底栏 `docked` / `floating` / `none`、底栏高度、悬浮偏移）写在 JS 里，由防闪烁脚本写到
`<html>` 上。改成主题 CSS 直接声明：

```css
html[data-theme="netflix"] {
  --mobile-topbar-h: 52px;
  --mobile-tabbar-h: 49px;
  --mobile-tabbar-mode: docked;   /* 内核让位规则按样式查询或等价写法消费，实施时逐处核对 */
}
```

这样首帧需要的几何全在 CSS 里，脚本不用认识任何主题。

### 4.6 服务端

| 项 | 内容 |
|---|---|
| 包格式 | `packages.py`：`[theme]` 段模型（`extra="forbid"`，`layout` 枚举、`theme_color` 十六进制、`preview` 两色）；有 `theme/theme.css` 时 `entry` 可空；有 `[theme]` 段却没有 `theme.css`、或有 `index.js` 却没写 `requires."ui.theme"` → 拒装 |
| 静态托管 | `/api/v1/ui/themes/<id>/<路径>`：`theme.css` 与 `assets/` **免登录**（登录页、初始化页也要按主题渲染）；`index.js` 要求登录（只有外壳用）。ETag；拒绝 `..` 与越界符号链接（复用插件网页的托管实现） |
| 聚合样式 | `GET /api/v1/ui/themes.css`（免登录）：§4.3 的 `@import` 列表；安全模式下为空 |
| 主题目录 | `GET /api/v1/ui/themes`（登录）：已启用主题的 id、名称、说明、预览色、状态栏色、版式、玻璃、版本、资源地址、状态（正常 / 需要更新） |
| 批准页 | 带 `index.js` 的主题照插件网页的口径告知：「主题代码会在每个页面里以**正在使用它的人**的身份运行」；纯 CSS 主题只说「会改变全站外观」 |
| 本地插件 | `data/plugins/<id>/theme/` 首次出现时在网页上确认一次（复用插件网页的同意记录），之后改文件刷新即生效——Agent 开发闭环 |
| 谁能装、谁能选 | 装 / 卸 / 停用：管理员。选：每个人（各自偏好，桌面 / 移动端分开，沿用现有字段） |

### 4.7 作者工具

> 落地（P5，2026-10-21）：主题插件是 pnpm 工作区成员（`plugins/<id>/`：`movieclaw-plugin.toml`、`src/index.tsx`、
> `src/theme.css`、`package.json`、`tsconfig.json`），构建器 `apps/web/theme-sdk/build.mjs`：
> - esbuild 出单个 ES 模块，外部模块只认 import map 那几个，引了别的直接报错（边界在构建期拦住）；
> - Tailwind 按 `--prefix` 出带前缀的工具类，经 `theme-sdk/tailwind-preset.css`（`scripts/gen-theme-runtime.mjs` 生成）
>   映射到主程序变量；**源码里写了的带前缀类必须都生成出来**，否则构建失败（实测：类名紧贴模板字符串的 `${`
>   时 Tailwind 扫不到，漏了不报错、只在页面上表现为样式缺失）；
> - `pnpm theme:build` 编进随带目录 `src/movieclaw_plugins/netflix/`（不入库），`pnpm web:build` 先跑它；
>   `pnpm theme:pack` 出 `.mcplugin`；CI 跑插件的类型检查与构建。
>
> 设计时的设想（下文）里「独立的 `packages/theme-sdk` 包」暂不做：第一方主题与主程序同仓库，直接用相对路径
> 引用构建器与 SDK 类型；第三方作者要用时再发包。


- 类型声明（`ThemeDefinition`、坑位 props、SDK 出口）。
- 构建配置：esbuild 输出 ESM，外部依赖固定为 §3 那六个；Tailwind 预设（前缀 + 主程序设计变量映射，§5.3）；CSS 作用域与类名检查。
- `mclaw plugin pack` 打包；插件开发技能（`movieclaw-plugin-dev`）补一节主题。

## 5. 关键技术点

### 5.1 为什么这次要做 SDK（插件网页 §9 没做）

插件网页是独立文档，iframe 隔离就够，不需要碰主程序的组件树。主题不一样——**主题本身就是外框的一部分**，顶栏要用主程序的
搜索面板、通知中心、权限、路由，必须在同一棵 React 树里。SDK 的边界由坑位清单决定（只服务外框），不是「什么页面都能拼」的
通用组件库，所以规模可控。

信任面与插件网页相同：同源 iframe 本来就能读写父页面和带着 Cookie 调接口，主题代码直接跑在主文档里没有多出新的权限。

### 5.2 SDK v1 的范围（按 Netflix 实际用到的收，顺手合并重复逻辑）

> 落地（P3，2026-10-21）：门面在 `apps/web/theme-sdk/index.ts`，tsconfig 别名 `@movieclaw/theme-sdk`；主题只能
> import react / react-dom / next / next/link / next/navigation / SDK / 相对路径（P3 时用 ESLint 守，P5 主题搬出
> `apps/web` 后改由构建器守）；出口快照
> `test/theme-sdk-surface.test.mjs`。实际合并了两处：`signOut()`（内核「更多」页、侧栏菜单与 Netflix 顶栏、「我的」页
> 四处同一流程，Netflix 两份副本此前漏了切账号时的首帧缓存预热）、`useAppNavLinks()`（顶栏用的插件网页项，不跟个人
> 排序）。下表是设计时的分组，实际出口以门面文件为准。

| 组 | 出口 |
|---|---|
| 导航 | `useAppNavItems()`（内置项 + 插件网页项 + 隐藏过滤 + 当前高亮，合并现在 `appNavItems` / `activeAppNavId` / `withoutHidden` / `usePluginApps` / `usePluginNavItems` 五处）、`accessiblePathFor` |
| 账户 | `useSession`、`useSignOut()`（合并 `logout` + 清背景缓存 + 清偏好缓存三步）、`AccountSwitcherDialog`、`AvatarBadge` |
| 权限 | `usePermissions` |
| 搜索 | `SearchCommand`、`useSearchAccess` |
| 通知与任务 | `NoticeCenter`、`useTaskActivity` + `taskActivityBadge`、`AppUpdateEntry` / `AppUpdateDot` / `usePendingUpdate`、`useAgentConversations` |
| 外壳 | `PageNav`、`usePageChrome`、`useIsMobile`、`useScrollRestoration`、`useUiPrefs` / `useThemeState`、`useSettingsSections()`（取代直接引 `lib/mock-data`） |
| 媒体 | `PosterImage`、`imageUrl`、`useElementCoverWidth`、媒体库与续播数据（`listLibraries` / `listLibraryItems` / `listUpNext`）、订阅页用到的数据钩子与 `SubscriptionCell` / `MediaTypeSwitcher` / `useSubscribeEntry`、`useDownloadTasks` |
| 原件 | 图标、`MovieclawWordmark` / `MovieclawMark`、`BrandLoader`、`ContentEmptyState`、`HScroller`、`formatRelativeTime` |

银玻璃的侧栏、「更多」页与 Netflix 的顶栏、「我的」页用的是同一份数据，合并后两边都只做展示——这也是内核这边的正收益。

### 5.3 Tailwind：主题工具类必须加前缀

主题组件搬出去后，主程序的 Tailwind 扫不到它们，主题得自己生成工具类。**不能直接再生成一份同名工具类**：

> 主程序的 `utilities` 层里先有 `.md\:flex`，主题 CSS 后加载又带了一份 `.hidden`。两份落进同一个层、同样的优先级，后者赢——
> 内核里写着 `hidden md:flex` 的元素在桌面上会被藏掉。

用 Tailwind 官方的 `prefix(nf)`：主题里写 `nf:flex`、`nf:md:hidden`，与主程序的类名不相交。主程序的设计变量用
`@theme inline` 映射过去，主题工具类直接引用主程序的运行时变量（主题覆盖的圆角档、移动端字号换档等照旧生效）。
SDK 的 Tailwind 预设由脚本从 `tailwindcss/theme.css` 与主程序的 `@theme` 生成，规则：

- 默认主题变量：`--X: var(--X, <默认值>)`——主程序生成过就用主程序的（含主题覆盖），没生成过用默认值；
- 主程序自定义变量（`--text-ui` 等）：`--X: var(--X)`；
- **断点与容器尺寸（`--breakpoint-*`、`--container-*`）保持字面值**：它们会进 `@media` / `@container` 条件，
  `var()` 在条件里不合法，写成变量会让 `nf:md:*` 全部失效（P0 实测踩到）。
这一步需要对 Netflix 约 1900 行 TSX 做一次类名改写（脚本 + 截图比对兜底）。

### 5.4 import maps 与 Next

- Next 15 的 chunk 用自己的加载器，不走原生 ESM 裸模块名，与 import map 不冲突；主题用 `webpackIgnore` / `turbopackIgnore`
  标注的原生 `import()` 加载。
- 浏览器支持：import maps 在 Safari 16.4+、Chrome 89+、Firefox 108+ 可用，覆盖 iOS PWA。
- 这两点和 §5.3 的前缀方案先做一个技术验证（P0），不通过就停下来重新讨论。

**P0 结论（2026-10-21，通过）**：开发模式与生产构建（`next build` + `next start`）下，import map + 垫片 + 原生 `import()` 加载的
外部主题模块渲染在 `(app)` 外壳里：`useState` 正常、`next/link` 客户端跳转不整页刷新、SDK 钩子拿到主程序的上下文
（`useSession`）；主题的 `nf:hidden` 不影响主程序的 `hidden md:flex`，主题自己的 `nf:md:block` 在 1280 / 600 两档正确。

## 6. 实施分期（每期单独合并，每期都有可验证的产出）

| 期 | 内容 | 验证 |
|---|---|---|
| P0 验证 | 生产构建 + 开发模式下：import map + 垫片 + 原生导入一个用了 hooks / `next/link` / SDK 的最小主题；Tailwind 前缀 + `@theme inline` 映射 | 最小主题渲染正常、路由与上下文可用；前缀工具类与主程序同名类共存不冲突 |
| P1 基线 | 改动前录基线截图：固定测试数据，Netflix 与银玻璃各一套，桌面 1440 / 手机 390，约 15 个页面 + 关键交互状态（顶栏滚动渐黑、「浏览」下拉、头像菜单、Billboard 首帧、详情页滚动退场） | 基线可重复（同一版本连跑两次零差异） |
| P2 内核去 Netflix | `structural` → 版式（§4.2 逐处分流）；`nf-*` 改中性名；`globals.css` 的 Netflix 规则搬进 `tokens.css`；几何改 CSS 变量 | 两套主题截图零差异；守护测试上线 |
| P3 SDK 门面 | 建 `theme-sdk` 门面；Netflix 目录**仍在主仓库里**，但只允许 import react / next / SDK（lint 规则） | 截图零差异；导出快照测试 |
| P4 运行时与服务端 | 包格式、托管、聚合样式、主题目录、加载器、就绪闸门、原子切换、出错回落；外观页改读目录 | 用一个测试主题包跑通装、选、卸、坏包回落 |
| P5 拆出 Netflix | 搬成独立包（Tailwind 前缀改写、`tokens.css` → `theme.css`、元信息 → 清单），从内核删除；按 §8 随应用携带 | §7 全部验收项 |
| P6 文档与工具 | 作者指南、模板、插件开发技能补主题一节 | 让 Agent 照指南从零写一个纯 CSS 主题并装上 |

P2、P3 即使后面停掉也有独立价值（内核更干净、外框数据去重）。

## 7. 验收（完成标准）

1. **内核干净**：内核代码里没有 `netflix`（白名单外）、没有 `structural`；`apps/web/themes/netflix/` 不存在。
2. **没装 Netflix**：外观页只有默认主题；现有单测、端到端测试全过；银玻璃截图与基线零差异。
3. **装上**：上传 `netflix.mcplugin` → 批准 → 外观页出现 Netflix → 选中：基线截图逐页一致（关闭动画、像素差阈值 0.1%），
   关键交互状态一致；桌面与手机都测。
4. **强刷不闪**：已选 Netflix 时强刷，首帧不出现银玻璃。
5. **卸载**：正在用 Netflix 的用户刷新后回落默认主题，控制台无报错，设置各页可达；偏好里仍是 `netflix`。
6. **重装**：不做任何操作，该用户自动回到 Netflix，截图与基线一致。
7. **停用 / 安全模式**：表现同卸载。
8. **坏主题**：把 `index.js` 换成抛错的版本、删掉 `index.js`、把 `requires` 改成不兼容版本，三种情况站点都可用、回落默认并提示。
9. **成员**：成员账号能选已装主题，不能装 / 卸。

## 8. 决定（2026-10-21 用户确认）

1. **Netflix 随应用携带**（`plugin-channels.md` §7 的随带插件包）。
   - 理由：`ui.theme` 契约头几个版本会频繁调整，随带保证主题与服务器永远同版本，不会出现「服务器升级 → 主题版本不兼容 →
     用户莫名回到默认主题」；老用户零迁移；不选的主题不渲染任何东西，不能真卸载的代价很小。
   - 可被同 id 插件包替换（热修通道）；随带插件包机制扩展到纯主题包（没有 Python 入口）。
   - 源码在主仓库，构建时编译进随带目录，产物不入库。
   - 「真卸载」照样验收：用不带 Netflix 的构建走上传 → 批准 → 选用 → 卸载 → 重装全流程（§7）。
   - 契约稳定后（连续几个版本无破坏性改动）可再挪到 movieclaw-plugins 单独发版。
2. **`cinema` 版式留在内核**，附纪律：
   - `cinema` 分支只允许**结构**（摆在哪、占不占一条、满不满出血、谁持有顶栏）；
   - **纯观感**（颜色、描边、按下态）一律删分支，改读变量或交给主题 CSS 覆盖公开部件；
   - 检验：只开 `cinema` 版式、不加载 Netflix 的 CSS 时，页面应是「默认配色的影院排布」，不出现写死的 Netflix 观感。

## 9. 考虑过、没采用的

| 方案 | 为什么不用 |
|---|---|
| 纯声明式主题（只 CSS + 选版式，外框组件留内核） | Netflix 的顶栏、Billboard、「我的」页、订阅页约 1900 行留在内核，不算独立插件 |
| 主题替换整页（每个功能页一个坑位） | 插件要重写二十多个页面，SDK 失控，功能改动要在每个主题里各改一遍 |
| 主题放 iframe | 改不了主程序的外观 |
| 装主题时重新构建前端 | standalone 镜像里没有构建工具链；NAS 上构建慢且容易失败 |
| Module Federation | 绑定 webpack 与 Next 内部实现，Turbopack 下不可用；import maps 是浏览器标准 |
| 主题自带一份 React | 两份 React 不共享上下文，登录态、路由、权限这些钩子全部失效 |
| 主题工具类不加前缀、靠层顺序或去重 | §5.3 的 `hidden` / `md:flex` 冲突；去重依赖主程序当前生成了哪些类，换个版本就漂 |
| 一个插件包带多个主题 | 没有需求；以后要做再把 `[theme]` 改成数组 |

## 10. 风险

| 风险 | 应对 |
|---|---|
| import map / 原生导入在 Next 开发与生产模式下的行为差异 | P0 先验证，不通过不开工 |
| 类名前缀改写漏掉动态拼接的类名 | 截图比对兜底；改写脚本对拼接字符串报警，人工过 |
| SDK v1 实际上只有 Netflix 一个使用方，容易按 Netflix 的形状设计 | 出口优先做成银玻璃外框也在用的合并钩子（§5.2），不收 Netflix 专属工具函数 |
| 主题代码多一次请求，拖慢首屏 | `modulepreload` 与登录态探测并行；P4 在 NAS 上实测首屏耗时，与改动前对比 |
| 内核改了公开部件的类名却没升契约版本 | 部件表守护测试：表里的类名必须在内核样式里存在 |

## 11. 验收记录（2026-10-21）

环境：NAS 数据库只读副本 + 页面用到的图片，本机后端（关掉会连外部的子系统）+ `next dev`；接口录制回放保证前后数据一致；
Chrome 无头，桌面 1440 × 900 / 手机 390 × 844。

| §7 条目 | 结果 |
|---|---|
| 1 内核干净 | `test/theme-kernel-boundary.test.mjs`：内核无 `netflix`（白名单外）、无 `structural`、无 `nf-`；`apps/web/themes/netflix/` 已删除，源码在 `plugins/netflix/` |
| 2 没装 Netflix | 插件页卸载随带版本后：外观页只有默认主题，设置各页可达、无报错 |
| 3 装上 | 上传 `netflix-1.0.0.mcplugin` → 不勾授信被拒 → 同意后装上；四个代表页与基线像素差 ≤ 0.004%（订阅页的「预计入库时间」按当前时间推算，基线自身就有同量级抖动）；**Netflix 作为随带插件时 96 张全量截图与改动前逐像素一致** |
| 4 强刷不闪 | DOM 就绪时已是 `data-theme="netflix"`、`data-glass="off"`，外框组件已挂 `modulepreload` |
| 5 卸载 | 正在用 Netflix 的用户刷新后回落默认主题；偏好里仍是 `netflix` |
| 6 重装 | 恢复随带版本后不做任何操作即回到 Netflix，截图与基线一致 |
| 7 停用 | 回落默认主题；重新启用即恢复（安全模式见 `tests/api/test_theme_packages.py`） |
| 8 坏主题 | 模块加载即抛错、引用缺失文件：回落默认并提示「加载失败」；契约 `^2.0`：上传即拒；坑位渲染抛错：只那一处回落、提示「部分界面出错」 |
| 9 成员 | 成员能列出、选用已装主题，不能装卸（`tests/api/test_theme_packages.py`） |

另测：顶栏头像菜单、窄桌面「浏览」下拉的定位；设置页点 Netflix 卡先加载后切换并保存；`pnpm web:build` 生产构建。

实施中踩到、已在流程里拦住的坑：
- 类名紧贴模板字符串的 `${` 时 Tailwind 扫描不到 → 构建器检查「写了的带前缀类必须都生成」；
- 批量加前缀误改了样式对象里的 `position: "absolute"` → 插件类型检查进 CI；
- 运行时静态引入 SDK 与 `ui-prefs` 形成循环依赖（整站白屏）→ SDK 改为加载主题时才动态引入；
- 偏好归一化会把没装的主题 id 改写成默认主题（重装回不来）→ 存储只校验写法、渲染才判断认不认得。
