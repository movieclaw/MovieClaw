# 插件网页：给用户做一个自己的页面

用户想要一个页面（看板、统计、片单、管理页），放在左侧栏里随时打开——写**插件网页**。
它就是一个普通网页：HTML / CSS / JS，用标准写法，没有 MovieClaw 专有的框架或格式。
设计见源码仓库 `docs/design/plugin-web-pages.md`。

## 1. 三条规则（全部契约）

1. 网页放在插件目录的 `web/` 里，入口是 `web/index.html`。
2. 侧边栏的名字和图标写一份标准的 W3C Web App Manifest：`web/manifest.webmanifest`（可选）。
3. 调接口就是 `fetch("/api/v1/...")`：与主程序同源，浏览器自动带登录，**以正在看页面的人的身份**运行。
   先用 `mclaw <域> --help` 找到命令，再查它的地址、参数和返回字段：

       python <本技能>/scripts/api.py library items list

   打印方法与地址、查询参数名（命令行的 `--res` 在地址里是 `res`：连字符换下划线）、返回的 `data` 里每个字段的
   类型与说明。数据为空、命令输出看不出字段时也能查。返回外面包一层 `{success, code, message, data}`，取 `data`。

## 2. 生成骨架

只带网页（不写 Python）：

    python <本技能>/scripts/new_plugin.py plugins/<id> --id <id> --title "<中文标题>" --web

生成 `movieclaw-plugin.toml`（没有 `entry`）和 `web/{index.html, manifest.webmanifest, icon.svg}`。
装好后主程序地址是 `/apps/<id>`。既要后端又要网页：照常生成 Python 骨架，再自己建 `web/`。

## 3. 侧边栏：manifest 的标准字段

```json
{
  "name": "本周看板",
  "short_name": "看板",
  "start_url": ".",
  "icons": [{ "src": "icon.svg", "type": "image/svg+xml", "purpose": "monochrome" }],
  "shortcuts": [{ "name": "下载统计", "url": "downloads" }]
}
```

| 字段 | 用途 |
|---|---|
| `short_name`（没有就用 `name`） | 侧边栏文字，8 个字以内 |
| `icons` 里 `purpose: "monochrome"` 的 | 侧边栏图标：只取形状，颜色跟主题走。画单色线条 SVG（黑色描边即可） |
| `start_url` | 主入口落点，相对 manifest，一般写 `.` |
| `shortcuts` | 侧边栏里的其他项，`url` 写相对地址（如 `downloads`），越出 `web/` 的会被丢掉 |

其余字段（`display`、`theme_color`……）不读。新装的排在主导航末尾，位置由用户拖（插件定不了）。
手机浏览器没有侧边栏，入口在「我的」页的「插件页面」一组。

## 4. 页面里怎么写

| 要做的事 | 写法 |
|---|---|
| 调主程序接口 | `fetch("/api/v1/subscriptions").then(r => r.json()).then(j => j.data)` |
| 写操作 | 同上，`method: "POST"` 等 + `headers: {"Content-Type": "application/json"}`；危险操作（帮助里带 ⚠ 的）在页面里先让用户确认 |
| 调插件自己的后端 | `fetch("/api/v1/plugins/<id>/<路由>")`（`recipes.md` 第 5 节） |
| 插件内部换页 | 相对链接 `<a href="downloads">`，或单页应用的 `history.pushState`；地址栏由主程序同步，返回键可用 |
| 跳到主程序页面 | `<a href="…" target="_top">`，常用地址见下表 |
| 跟主程序观感一致 | CSS 写 `var(--mc-text, #eee)`、`var(--mc-text-muted)`、`var(--mc-line)`、`var(--mc-accent)`、`var(--mc-ok)` / `--mc-warn` / `--mc-danger`、`var(--mc-font)`；主程序自动注入、切主题跟着变。**页面背景留透明**，透出主程序的玻璃背景 |
| 实时数据 | `new EventSource("/api/v1/jobs/stream")` 这类主程序已有的 SSE 流 |

主程序的常用页面地址（都要 `target="_top"`）：

| 页面 | 地址 |
|---|---|
| 媒体库 / 某个库 | `/library`、`/library/{library_id}` |
| 条目详情 | `/library/{library_id}/item/{media_item_id}` |
| 播放 | `/play/{media_item_id}` |
| 我的订阅 / 订阅详情 | `/subscriptions`、`/subscriptions/{subscription_id}` |
| 任务（下载与后台任务） | `/tasks` |
| 发现 | `/discover/movie`、`/discover/tv` |
| 设置 | `/settings`、`/settings/plugins` |

- 时间字段一律是带时区的 UTC ISO 字符串（如 `2026-10-19T02:00:00+00:00`）：`new Date(s)` 直接解析，按浏览器时区显示。
- 写原生 JS 最省事（不用打包）。要用 Vue / React，就在别处打包好，把产物放进 `web/`，资源地址用相对路径。
- 手机网页也能打开（入口在「我的」页）：写响应式布局（`<meta name="viewport">` 骨架里有）。
- 成员打开时，接口按成员权限拦截：`api.py` 打出的「权限」一行写明是不是仅管理员（下载器、任务、设置、插件这类都是）；
  其余的成员还要看能力开关（订阅要「允许订阅」、搜索要「允许搜索」）。页面要处理 403（提示「需要管理员」或「没有开通」），
  给成员看的页面在方案里跟用户说清哪块成员看不到。

## 5. 安装与验证

1. `check_plugin.py plugins/<id>`：会列出侧边栏项，检查 manifest、图标文件，提示没写 `target="_top"` 的主程序链接。
   页面里有判断逻辑（时间范围、过滤、状态分类）的，放进 `web/logic.js`（页面用 `<script src="logic.js">` 引入，
   文件末尾 `if (typeof module !== "undefined") module.exports = { … }`），再用
   `node -e 'const l = require("./plugins/<id>/web/logic.js"); …'` 跑几条正反例（服务器自带 node）；
   页面最终的样子以用户反馈为准。
2. **征得同意**：除了 SKILL.md 第 5 节的常规内容，还要明确告诉用户「这个网页会以打开它的人的身份运行，管理员打开时
   拥有管理员的全部权限」，以及装好后左侧栏会多出哪几项、成员默认看不到。
3. 同意后：`mclaw` 工具执行 `plugin dev plugins/<id> --once --allow-web`（不带 `--allow-web` 会被拒并说明原因）。
4. 验证：`mclaw app plugins pages list` 里有它、`approved` 为真、`entries` 是预期的几项；
   请用户刷新网页，左侧栏出现、点开能用。你看不到浏览器，**页面效果以用户反馈为准**。
5. 用户说页面报错：页面里没接住的报错会写进系统日志，用 bash 在日志目录当天的文件里
   `grep -n '插件 <id> 的页面报错' …` 看报错与出处，改好后重新 `plugin dev … --once --allow-web`，请用户刷新。
6. 想让成员也能看到、或从侧边栏撤下：网页「设置 → 插件 → 插件网页」里改（只能由人在网页里操作）。

## 6. 做不到的

- 在主程序**已有**页面里加按钮或卡片（播放器、详情页、首页）——插件网页是独立的一页。
- iPhone / Apple TV / Android 等 App 里显示——第一版只有网页（含手机浏览器）。
- 不登录访问——页面要求登录，要公开的东西用插件路由的公开区（`recipes.md` 第 5 节）。
