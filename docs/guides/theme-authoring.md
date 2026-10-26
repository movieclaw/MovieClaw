# 网页主题开发指南

本文写给要给 MovieClaw 网页做主题的开发者。设计原理与取舍见 [docs/design/theme-plugins.md](../design/theme-plugins.md)。
AI 助手做主题走内置技能 `movieclaw-plugin-dev`，它的 `references/themes.md` 是本文的精简版。

## 1. 主题能做什么

分工只有一句话：**页面和版式归内核，外观和外框归主题。**

| 主题能做 | 主题不能做 |
|---|---|
| 换颜色、圆角、字号、字体、背景（CSS 变量） | 改页面里的内容：加按钮、卡片、入口 |
| 改公开部件的形状、阴影、按下态 | 改 App（iPhone / TV / 安卓）的外观 |
| 选用内核的版式：`panel` 或 `cinema` | 发明新的版式 |
| 换外框组件：顶栏、底栏、设置菜单、详情页返回键……（第 5 节的坑位） | 替换坑位以外的组件 |
| 换三张主题专属整页：`/my`、移动端 `/settings` 列表、`/subscriptions` | 新增路由 |

主题分两种：

- **纯 CSS 主题**：只有 `theme/theme.css`。改变量和部件，版式只能用 `panel`。不用编译，写完就能打包。
  示例是技能里的 `references/examples/ocean-theme/`（海蓝）。
- **带外框组件的主题**：再加一个 `theme/index.js`（ES 模块），替换坑位、提供整页。`cinema` 版式必须带，
  因为顶栏要由主题提供。源码用 TypeScript + React 写，用主题构建器编译。示例是随应用携带的 `plugins/netflix/`。

## 2. 插件包结构

```
movieclaw-plugin.toml
theme/
├── theme.css        必需：外观
├── index.js         可选：外框组件（构建产物）
└── assets/…         可选：图片、字体，theme.css 里用相对地址引用
```

服务器只托管这些类型：`.css .js .mjs .png .jpg .jpeg .webp .avif .gif .svg .woff .woff2 .ttf .otf`。
CSS 与图片、字体不登录也能取（登录页也要用主题）；`.js` 要登录。

### 清单

```toml
[plugin]
id = "ocean"                  # 也是主题 id：小写字母开头，只用小写字母、数字和连字符，3～40 位
title = "海蓝"
version = "1.0.0"
sdk = "^1.0"
description = "深海蓝底、青色强调的网页主题"
# 没有 entry：主题没有后端代码

[requires]
"ui.theme" = "^1.1"           # 主题契约（写当前版本），带 index.js 的必须写；纯 CSS 的也建议写

[theme]
label = "海蓝"                # 外观卡片上的名字，20 字以内
description = "深海蓝底，青色强调"   # 80 字以内
preview = { bg = "#03101c", accent = "#5fb3d9" }   # 外观卡片缩略：底色 + 强调色
theme_color = "#03101c"       # 浏览器地址栏 / 手机状态栏颜色
layout = "panel"              # panel = 侧栏 + 居中面板；cinema = 顶栏 + 满出血 + 大图首屏（须带 index.js）
glass = true                  # 液态玻璃；false 时内核改用实底面板、不起 WebGL
```

`[theme]` 段是主题的静态事实：内核不执行主题代码就能列出、校验、展示主题，首帧也只靠它。
服务器在上传时校验：有 `[theme]` 就必须有 `theme/theme.css`；有 `theme/index.js` 就必须声明 `ui.theme`；
`cinema` 必须带 `theme/index.js`。

## 3. 外观：theme.css

### 3.1 作用域

**全部规则挂在 `html[data-theme="<id>"]` 底下。** 所有已装主题的 CSS 对每个用户都会加载
（`/api/v1/ui/themes.css` 一行一个 `@import`），这样切换主题不用等下载。代价是没挂作用域的规则会改坏别的主题。

用户选了默认主题时 `<html>` 上没有 `data-theme`。选了某个主题时，`<html>` 上会写 `data-theme="<id>"`，
`glass = false` 的主题还会多写一个 `data-glass="off"`。

只用主题自己类名的规则（`.oc-wave`、带前缀的 Tailwind 工具类）可以不挂，因为内核里没有这些类。
技能的检查脚本 `check_plugin.py` 会拦下三类规则：没挂作用域却改了内核变量、改了内核部件、或改了全局元素。

### 3.2 先改变量

整套界面都读 CSS 变量。改一处，全站生效；内核改版时变量名不变，主题也不受影响。可覆盖的变量登记在
**CSS 契约表** [src/movieclaw_sdk/theme_css.json](../../src/movieclaw_sdk/theme_css.json) 的 `variables` 里，每个都写了用途。大致分组：

- 整体色调与表面：`--scrim-rgb`（全局蒙版颜色）、`--backdrop-tint`（罩在背景大图上的色）、`--bg`、`--surface-raised`、`--surface-inset`、`--poster-placeholder`
- 文字与描边：`--text*`、`--line*`
- 强调色：`--accent*`。成组换，否则聚焦环、浅底还是旧颜色
- 可点击行：`--glass-fill*`
- 状态色与信息蓝系：`--ok`、`--info*`、`--warn`、`--danger*`
- 留白与几何：`--page-inset`、`--content-inset`、`--mobile-topbar-h`
- 渐变与材质：`--page-fog`、`--hero-blend`（遮罩，只控透明度）、`--glass-tint`、`--glass-backdrop`
- 字体、动效、圆角档、字号档：`--font-sans`、`--ease-spring*`、`--radius-*`、`--text-micro` 到 `--text-title-lg`

玻璃版式（`glass = true`）下，页面大面积的颜色来自背景大图、全局蒙版和透出它们的玻璃，`--bg` 只在图没铺上时露出，
所以整体换色调靠 `--scrim-rgb` 和 `--backdrop-tint`。侧栏、输入框这些玻璃面板由 WebGL 绘制，染色是内核定的中性深色，主题改不了。
想让面板本身也换色，就用 `glass = false`，再改公开部件 `.panel--sidebar`、`.panel--main`。

`readonly` 里的变量（安全区、键盘占高、视口补偿……）由内核按设备实时算出，主题只读不写。

手机端单独调用 `@media (max-width: 767px)`，规则同样挂在作用域底下。

### 3.3 再改公开部件

变量表达不了的（形状、阴影、某个部件的特殊配色），改**公开部件**：契约表 `parts` 里登记的内核类名，
如 `.glass-panel`、`.btn-accent`、`.menu-surface`、`.modal-panel`、`.nav-item`、`.settings-tab`、`.toast-item`。
这些类名是承诺稳定的接口：改名或删除等于契约 `ui.theme` 升主版本，已装的主题会被标成不兼容，而不是悄悄错乱。

**别碰没登记的内核类名**，它们随时会改名。确实需要的，先在契约表里登记（附带内核侧的守护测试
`apps/web/test/theme-css-contract.test.mjs`），这算契约次版本。

### 3.4 示例

```css
html[data-theme="ocean"] {
  --bg: #03101c;
  --text: #eaf4fa;
  --accent: #5fb3d9;
  --accent-strong: #a8dcf2;
  --accent-2: #3f8db5;
  --accent-soft: rgba(95, 179, 217, 0.16);
  --accent-ring: rgba(95, 179, 217, 0.6);
  --glass-tint: rgba(20, 60, 90, 0.42);
}

/* 主按钮默认是银色渐变，变量管不到，改公开部件 */
html[data-theme="ocean"] .btn-accent {
  background: linear-gradient(145deg, #a8dcf2 0%, #5fb3d9 100%);
  color: #03111c;
}
```

## 4. 纯 CSS 主题的开发流程

1. 生成骨架：`python src/movieclaw_agent/builtin-skills/movieclaw-plugin-dev/scripts/new_plugin.py plugins/ocean --id ocean --title "海蓝" --theme`。
   也可以手写清单和 `theme/theme.css`。
2. 检查：`python …/scripts/check_plugin.py plugins/ocean`（需要主程序的 Python 环境）。
3. 装到开发服务器边改边看：`mclaw plugin dev plugins/ocean`，每次改动都会重新打包、上传、批准、加载，刷新页面就能看到。
   只装一次用 `--once`。
4. 打包分发：`mclaw plugin pack plugins/ocean` 得到 `ocean-1.0.0.mcplugin`，在「设置 → 插件」上传，批准后在「设置 → 外观」选用。

## 5. 带外框组件的主题

### 5.1 目录与构建

主题源码目录（参照 `plugins/netflix/`）：

```
movieclaw-plugin.toml
package.json        构建脚本与开发依赖（esbuild、tailwindcss、@tailwindcss/postcss、postcss、react 与类型、typescript）
tsconfig.json       类型检查：@movieclaw/theme-sdk 指向 apps/web/theme-sdk/index.ts
src/index.tsx       default export 主题定义
src/theme.css       外观（第 3 节）
src/assets/         可选，原样拷到 theme/assets/
```

构建器是 `apps/web/theme-sdk/build.mjs`，在主题目录里运行：

```bash
node <仓库>/apps/web/theme-sdk/build.mjs --prefix oc --out <输出目录>
```

```bash
node <仓库>/apps/web/theme-sdk/build.mjs --prefix oc --pack <输出目录>
```

前一条把清单和 `theme/` 写进输出目录，可以接着 `mclaw plugin dev <输出目录> --allow-theme`。后一条直接出 `<id>-<版本>.mcplugin`。

构建器做了这些事：

- **JS**：esbuild 把 `src/index.tsx` 打成一个 ES 模块。`react`、`react-dom`、`react/jsx-runtime`、`next/link`、
  `next/navigation`、`@movieclaw/theme-sdk` 是外部模块，运行时由页面的 import map 指到主程序自己的实例
  （共用一份 React，hooks、Context 都通）。除此之外**只能 import 主题目录里的相对路径**，引了别的直接构建失败。
- **CSS**：Tailwind 只生成带前缀的工具类（`--prefix oc` → `oc:flex`、`oc:md:hidden`）。设计变量经 SDK 预设映射到主程序的运行时变量，
  `oc:bg-[var(--bg)]` 这类写法也照常可用。随后接上 `src/theme.css`。
- **漏生成检查**：源码里写了、却没生成出来的带前缀工具类会让构建失败。

### 5.2 Tailwind 的两条规矩

1. **工具类必须带前缀**：`oc:flex`，不要写 `flex`。不带前缀的类在主题的样式表里不会生成，
   碰巧和主程序同名的那些也只是凑巧能用，主程序哪天不用了就会失效。
2. **类名别紧贴模板字符串的 `${`**：`` `oc:w-10${x}` `` 这种写法 Tailwind 扫不到，类名后面要留空格或引号：
   `` `oc:w-10 ${x}` ``。构建器的漏生成检查会拦下来。

### 5.3 主题定义

```tsx
import { type ThemeDefinition, PageNav, useIsMobile } from "@movieclaw/theme-sdk";
import { OceanTopNav } from "./chrome/top-nav";

const theme: ThemeDefinition = {
  slots: { desktopTopNav: OceanTopNav },
  pages: {},
};
export default theme;
```

坑位全部可选，没给的用内核的基础实现。类型定义在 [apps/web/themes/types.ts](../../apps/web/themes/types.ts)：

| 坑位 | props | 基础实现 |
|---|---|---|
| `desktopTopNav` | `onSearch(keyword, scope, options?)`、`onOpenSettings()` | 无（`panel` 版式用侧栏；`cinema` 必须提供） |
| `mobileTabBar` | 无 | 液态玻璃悬浮底栏 |
| `mobileSettingsNav` | `title`、`backHref`、`historyBack?` | 移动端设置返回条 |
| `settingsNav` | `SettingsSidebarProps` | 设置分区菜单 |
| `detailNav` | `title`、`fallback`、`onBack`、`onPhoto?`、`actions?`、`className?` | `PageNav` 工具条 |
| `pageActions` | `children` | 页面内建的吸顶工具条 |
| `libraryHero` | 无 | 无（媒体库页内建页头） |

| 整页 | 路由 | 基础实现 |
|---|---|---|
| `my` | `/my` | 「更多」页 |
| `settingsIndex` | 移动端 `/settings` | 设置分区列表 |
| `subscriptions` | `/subscriptions` | 内核订阅页 |

### 5.4 主题 SDK

主题能用的内核能力全部在 `@movieclaw/theme-sdk`（[apps/web/theme-sdk/index.ts](../../apps/web/theme-sdk/index.ts)）：
外壳（`PageNav`、`usePageChrome`、`useIsMobile`、`useUiPrefs`）、导航（`useAppNavLinks`、`usePluginNavItems`）、
账户与权限（`useSession`、`usePermissions`、`signOut`）、搜索、通知与任务、海报与图片地址、媒体库与续播、订阅与下载，
以及图标、品牌标、空状态、横滑容器这些原件。内核其余模块对主题不可见。

SDK 出口由快照测试守着。加出口算契约次版本，删或改签名算主版本。主题要用的能力不在 SDK 里，就在内核里加出口，
同时更新快照和运行时垫片（`node apps/web/scripts/gen-theme-runtime.mjs`）。

### 5.5 授信

`index.js` 在主程序页面里运行，拥有使用者的全部权限。所以批准时要单独勾选「我信任这个主题的代码」，
命令行对应 `--allow-theme`。纯 CSS 主题不用。

## 6. 运行时行为

- **选用**：每个人在「设置 → 外观」里自己选，手机和电脑可以各选一个。主题装上后不用刷新页面，外观页就有它；
  安装不会改任何人当前的外观。
- **首帧**：防闪烁脚本按本地缓存的主题目录先写 `data-theme`，CSS 已随 `themes.css` 加载，首帧就是主题色。
  带外框组件的主题，模块加载完成之前显示启动画面，不会先闪一下默认外框。
- **出错回落**：模块加载失败时界面回到默认主题，并提示「主题加载失败，已临时使用默认主题」。
  契约版本不兼容的主题包上传时就被拒绝。
  某个坑位渲染出错时，只有这个坑位回到基础实现，提示「部分界面出错」，其余照常。
- **卸载与停用**：正在用它的人回到默认主题。偏好里仍记着它，装回来就恢复。
- **随应用携带**：Netflix 随应用携带。上传同 id 的包会替换随带版本，卸掉包后随带版本自动回来；
  随带版本本身也能卸载和恢复。安全模式下只保留随带主题。

## 7. 发布前自查

- [ ] 所有改内核的规则都挂在 `html[data-theme="<id>"]` 底下（`check_plugin.py` 通过）
- [ ] 只依赖契约表里的变量和部件
- [ ] `--text` 对页面底色（蒙版压过的背景）和 `--surface-raised` 的对比度至少 4.5:1；强调色上的文字同样要够
- [ ] 桌面（≥768px）和手机（<768px）都看过：首页、媒体库、详情页、设置、弹窗、菜单、提示条
- [ ] `glass = true` 时看过有背景图的首页，面板透出的颜色协调
- [ ] `preview` 两个颜色取自 `--bg` 和 `--accent`，外观卡片缩略图和实际一致
- [ ] 带外框组件的：`tsc --noEmit` 通过，构建无漏生成；坑位在两种屏宽下都没有重复渲染（Netflix 的 `detailNav` /
      `pageActions` 就按 `useIsMobile()` 分叉过）
