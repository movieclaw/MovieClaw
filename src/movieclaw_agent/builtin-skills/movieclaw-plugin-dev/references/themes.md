# 网页主题

主题换的是网页的**外观**：颜色、圆角、字号、字体、部件的形状与阴影、背景。选用在「设置 → 外观」，每个人自己选，
手机和电脑可以各选一个。设计见源码仓库 `docs/design/theme-plugins.md`，面向开发者的完整指南（含带外框组件的主题）
是源码仓库 `docs/guides/theme-authoring.md`。

## 1. 能做什么、不能做什么

| 能 | 不能 |
|---|---|
| 整体换色调（底色、面板、文字、强调色、状态色） | 改页面结构、加按钮 / 卡片 / 入口（页面归内核） |
| 换圆角、字号档、字体（系统字体，或把字体文件放进包里） | 改 App（iPhone / TV / 安卓）的外观：主题只管网页 |
| 改公开部件的形状、阴影、按下态（第 4 节） | 依赖没登记的内核类名：内核改版时会失效 |
| 关掉液态玻璃改用实底面板（`glass = false`） | 新的版式。版式只有两种，由内核实现 |

**版式**由内核定，主题只声明用哪一种：`panel` 是侧栏加居中面板（默认主题）；`cinema` 是顶栏、满出血内容加大图首屏（Netflix）。
`cinema` 要主题自己提供顶栏组件（`theme/index.js`），而这需要在源码仓库里用主题构建器编译 TypeScript 和 React，**不在服务器上做**。
所以**你写的主题一律是纯 CSS + `panel` 版式**。用户想要 Netflix 那样换导航结构的，直说要在源码仓库里按开发者指南做。

## 2. 目录与清单

```
plugins/<id>/
├── movieclaw-plugin.toml
└── theme/
    ├── theme.css        # 必需：全部外观
    └── bg.webp          # 可选：图片、字体（.png .jpg .webp .avif .gif .svg .woff2 .woff .ttf .otf），theme.css 里用相对地址引用
```

`python <本技能>/scripts/new_plugin.py plugins/<id> --id <id> --title "<名字>" --theme` 生成骨架。清单除了 `[plugin]`（没有 `entry`），
还有一段 `[theme]`：

| 字段 | 含义 |
|---|---|
| `label` | 外观卡片上的名字，20 字以内 |
| `description` | 一句话说明，80 字以内 |
| `preview = { bg = "#rrggbb", accent = "#rrggbb" }` | 外观卡片缩略图的底色与强调色，取 theme.css 里的 `--bg` 与 `--accent` |
| `theme_color` | 浏览器地址栏 / 手机状态栏颜色，一般同 `--bg` |
| `layout` | `panel`（纯 CSS 主题只能用它） |
| `glass` | `true` 用液态玻璃（面板半透明、透出背景）；`false` 改用实底面板 |

`[requires]` 写契约当前版本 `"ui.theme" = "^1.1"`：内核的公开变量或部件改了主版本，装的时候会提示不兼容，而不是装上后悄悄错乱。

## 3. theme.css 的规则

1. **全部挂在 `html[data-theme="<id>"]` 底下**。所有已装主题的 CSS 对每个用户都会加载，不管他选的是哪个主题；
   不挂作用域就会改坏别人的界面。`check_plugin.py` 会拦下没挂作用域却改了内核变量、部件或全局元素的规则。
2. **优先只改变量**（第 4 节）。整套界面都读这些变量，改一处全站生效，内核改版也不受影响。
3. 变量表达不了的（形状、阴影、某个部件的特殊底色），才改**公开部件**；别的内核类名不要碰，它们随时会改名。
4. 自己新加的类名带主题前缀（如 `oc-`），别和内核撞名。
5. 手机和电脑分开调用 `@media (max-width: 767px)`，规则同样挂在作用域底下。
6. 只读变量（第 4 节末尾）由内核按设备实时算出，只能读，不能写。
7. 一般不用 `!important`：`html[data-theme="<id>"] .部件` 比内核的默认规则更具体。压不过时先查内核那条规则的选择器。

```css
html[data-theme="ocean"] {
  --bg: #04121f;
  --accent: #5fb3d9;
  --accent-ring: rgba(95, 179, 217, 0.55);
}
html[data-theme="ocean"] .btn-accent {
  color: #03111c;   /* 强调色变亮后，主按钮上的字改深色 */
}
@media (max-width: 767px) {
  html[data-theme="ocean"] { --page-inset: 1rem; }
}
```

## 4. CSS 契约

契约表的事实源是 `$SRC/movieclaw_sdk/theme_css.json`，这里是它的说明版。

**公开变量**（主题可以覆盖）：

| 组 | 变量与用途 |
|---|---|
| 表面 | `--bg` 页面最底层底色<br>`--scrim-rgb` 全局蒙版的颜色（三个通道，空格分隔，如 3 16 28）：玻璃版式下非首页的整体色调<br>`--backdrop-tint` 罩在背景大图上的一层色（含首页，默认透明）<br>`--surface-raised` 浮层底色：菜单、卡片、弹窗<br>`--surface-inset` 内嵌底色：输入框<br>`--poster-placeholder` 海报 / 剧照加载前的占位底 |
| 文字与描边 | `--text` 主文字<br>`--text-muted` 次要文字<br>`--text-faint` 最弱文字：占位、提示<br>`--line` 描边 / 分隔线<br>`--line-strong` 强调描边 |
| 强调色 | `--accent` 强调色<br>`--accent-strong` 强调色高光<br>`--accent-2` 强调色暗侧<br>`--accent-soft` 强调色浅底<br>`--accent-ring` 聚焦环 |
| 可点击行 | `--glass-fill` 可点击行的底色<br>`--glass-fill-hover` 可点击行悬停底色<br>`--glass-fill-active` 可点击行按下 / 选中底色 |
| 状态色 | `--ok` 状态色：成了（在库、已连接）<br>`--info` 状态色：进行中 / 提示<br>`--warn` 状态色：要注意<br>`--danger` 状态色：要你处理<br>`--danger-solid` 危险操作实心底（压白字）<br>`--danger-solid-hover` 危险操作实心底悬停 |
| 信息蓝系 | `--info-soft` 信息蓝基色：软底 / 描边 / 实底<br>`--info-text` 软底上的信息文字<br>`--info-text-2` 次级信息文字（小角标）<br>`--info-grad-a` 全集徽章渐变起点<br>`--info-grad-b` 全集徽章渐变终点<br>`--info-on-solid` 信息实底上的文字<br>`--info-legend` 订阅进度条「下载中」图例点 |
| 图片来源标识 | `--src-tmdb` 图片来源标识：TMDB<br>`--src-fanart` 图片来源标识：Fanart.tv<br>`--fanart-soft` Fanart 浅底<br>`--fanart-line` Fanart 描边 |
| 留白与几何 | `--page-inset` 页面级左右留白<br>`--content-inset` 详情正文级左右留白<br>`--mobile-topbar-h` 移动端顶栏高度（吸顶元素按它让位） |
| 渐变与材质 | `--page-fog` 页面顶部吸顶雾渐变<br>`--hero-blend` 大图首屏左侧压暗渐变<br>`--glass-tint` 玻璃材质染色（CSS 玻璃回落）<br>`--glass-backdrop` 玻璃材质 backdrop-filter |
| 字体与动效 | `--font-sans` 全站字体栈<br>`--ease-spring` 弹簧缓动<br>`--ease-spring-soft` 柔和弹簧缓动 |
| 圆角档 | `--radius-xs` 圆角档 rounded-xs<br>`--radius-sm` 圆角档 rounded-sm<br>`--radius-md` 圆角档 rounded-md<br>`--radius-lg` 圆角档 rounded-lg<br>`--radius-xl` 圆角档 rounded-xl<br>`--radius-2xl` 圆角档 rounded-2xl<br>`--radius-3xl` 圆角档 rounded-3xl<br>`--radius-4xl` 圆角档 rounded-4xl |
| 字号档 | `--text-micro` 字号档 text-micro：徽标、角标<br>`--text-caption` 字号档 text-caption：说明、时间戳<br>`--text-sub` 字号档 text-sub：辅助正文<br>`--text-ui` 字号档 text-ui：导航、菜单、按钮<br>`--text-body` 字号档 text-body：正文基准<br>`--text-body-lg` 字号档 text-body-lg：阅读正文<br>`--text-title-sm` 字号档 text-title-sm：小标题<br>`--text-title` 字号档 text-title：区块 / 弹窗标题<br>`--text-title-lg` 字号档 text-title-lg：页面大标题 |

**玻璃版式（`glass = true`）下哪些颜色归主题**：页面大面积的颜色来自背景大图、全局蒙版和透出它们的玻璃，
`--bg` 只在图没铺上时露出，所以整体换色调要改 `--scrim-rgb` 和 `--backdrop-tint`。侧栏、输入框这些玻璃面板由 WebGL 绘制，
染色是内核定的中性深色，主题改不了，它们会透出底下已经换了色调的背景。想让面板本身也换色，就用 `glass = false`，
再改公开部件 `.panel--sidebar`、`.panel--main` 的 `background`。

成组改，别只改一个：比如换强调色时，`--accent`、`--accent-strong`、`--accent-2`、`--accent-soft`、`--accent-ring` 要一起换，
否则聚焦环和浅底还是原来的颜色。`--text` 与 `--bg` 的对比度要够：正文至少 4.5:1。

**只读变量**：`--safe-top`（顶部安全区（刘海））、`--safe-bottom`（底部安全区（Home 指示条））、`--safe-left`（左侧安全区）、`--safe-right`（右侧安全区）、`--tabbar-bottom`（悬浮底栏距视口底边的偏移）、`--vp-overshoot`（iOS 独立 App 视口补偿量）、`--keyboard-inset`（软键盘占高）。

**公开部件**（可以依赖的内核类名）：`.ai-chip` `.ambient-fallback` `.backdrop-override` `.brand-badge` `.brand-loader--mark` `.brand-loader--silver` `.btn-accent` `.btn-glass` `.css-glass` `.detail-ambient` `.detail-ambient--hero` `.detail-content` `.detail-lead` `.detail-more-toggle` `.detail-slideshow` `.genre-tile` `.genre-tile-sheen` `.glass-panel` `.glass-panel--flat` `.glass-panel__content` `.glass-row` `.group-label` `.hero-live` `.icon-chip` `.is-checked` `.lg-button` `.lg-button__glass` `.lg-button__switch` `.lg-button__thumb` `.lg-button__track` `.lg-icon-button` `.lg-icon-button__active-surface` `.lg-icon-button__glass` `.m-row` `.m-row-skel` `.markdown` `.media-cta` `.menu-surface` `.mobile-topbar` `.modal-panel` `.modal-scrim` `.nav-item` `.notice-surface` `.page-nav-btn` `.page-solid` `.panel--main` `.panel--sidebar` `.panel--sidebar-flat` `.person-hero` `.range-glass` `.ribbon-owned` `.scroll-safe` `.scroll-thin` `.search-palette-overlay` `.search-palette-panel` `.settings-panel-head` `.settings-tab` `.skill-token-chip` `.solid-card` `.solid-popover` `.sub-hero-card` `.sub-hero-tint` `.surface-raised` `.text-on-image` `.text-sheen` `.tnum` `.toast-item` `.tooltip-bubble` `.topnav-offset`

常用的几个：`.glass-panel` 是玻璃面板（`glass = false` 时是实底），`.panel--sidebar` 和 `.panel--main` 是侧栏与内容面板，
`.btn-accent` 和 `.btn-glass` 是主按钮与次按钮，`.menu-surface` 是下拉菜单，`.modal-panel` 是弹窗，
`.nav-item` 是侧栏导航项，`.settings-tab` 是设置页签，`.toast-item` 是提示条，`.tooltip-bubble` 是悬停说明，
`.genre-tile` 是首页「按类型找」的卡片。

## 5. 安装、选用、卸载

- 检查：`python <本技能>/scripts/check_plugin.py plugins/<id>`，有 ✗ 先修。清单的 `description`、`[theme]` 段的
  `description` 与 `preview` 别留骨架的默认值（`preview` 与 theme.css 的 `--bg` / `--accent` 对不上时检查脚本会提示）。
- 安装前告诉用户：主题只改网页外观（App 不受影响），装上不会改任何人当前的外观，每个人在「设置 → 外观」里自己选用；
  纯 CSS 主题不运行代码，不需要额外授权。
- 安装：`mclaw` 工具执行 `plugin dev plugins/<id> --once`。纯 CSS 主题不加任何授信参数（`--allow-theme` 只给带外框组件
  `theme/index.js` 的主题，你写的主题不会有）。
- 验证：`app plugins packages list` 里它在 `installed`、`state` 为 `active`；`app plugins list` 里也有它这一项
  （`source: package`）。主题不起进程，这两处的 `runtime` 字段对主题没有意义。没有列主题目录的命令，
  外观要请用户打开「设置 → 外观」选用后确认。装上后不用刷新，选项就会出现。**不要替用户改外观偏好**。
- 改了再装一次，用户刷新页面就能看到新样式。
- 卸载：`app plugins packages uninstall <id> --yes`。正在用它的人自动回到默认主题；以后再装回来，选过它的人会自动用回它。

## 6. 出错时

- 主题的 CSS 写错，坏的只是这个主题的样子。用户在「设置 → 外观」换回默认即可。
- 用户选的主题被卸载或停用：界面自动用默认主题，偏好里仍记着它，装回来就恢复。
- 改了不生效：先查选择器挂没挂对作用域（id 拼写），再查是不是改了不在公开表里的内核类。
- 完整示例：`references/examples/ocean-theme/`（深海蓝，纯 CSS）。
