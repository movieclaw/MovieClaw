# 插件网页：插件自带页面、进主导航

> 状态：**设计定稿，待实施**（2026-10-19 与用户逐条讨论后定稿）。取代 `plugin-phase4.md` §6「暂不做：插件自带网页界面」。
> 关联：`plugin-phase3.md`（插件包、上传与批准）、`plugin-phase2b.md` §8（插件路由）、`cli.md` §2（`/api/v1/spec`）、
> `apps/web/lib/sidebar-nav.ts`（主导航排序规则）。范围：**只做网页**，iPhone / Mac / TV / Android 第一版不考虑。

## 0. 结论先行

**原则（用户定）：能用业界标准就用标准，不自己造轮子。** 标准意味着模型在预训练阶段见过，Agent 生成的质量更高；
Agent 写网页已经很强，不该再让它学一套 MovieClaw 自创的规则。

1. **插件页面就是一个普通网页**：插件包里放一个 `web/` 目录，有这个目录就表示插件带网页。主程序在
   `/apps/<插件 id>/` 用**同源 iframe** 把它嵌进主程序外框，侧边栏照常显示。
2. **授信模式**：页面与主程序同源，用 `fetch` 调现有接口，浏览器自动带登录 Cookie，以**当前查看者**的身份运行，
   成员权限照常由服务端拦截。开源、用户自托管，插件是用户自己选的，安装时用户同意即可（§5）。
3. **侧边栏入口用 W3C Web App Manifest 描述**：`short_name` / `icons`（`purpose: "monochrome"`）/ `start_url` /
   `shortcuts` 一一映射到侧边栏项。**没有一个 MovieClaw 自己的新字段。**
4. **插件作者（包括 Agent）需要知道的全部契约只有三句话**：
   - 网页放在 `web/`，入口是 `index.html`；
   - 想定制侧边栏的名字和图标，写一份标准的 `web/manifest.webmanifest`；
   - 接口文档在 `/api/v1/spec`（标准 OpenAPI，登录后可取），也可以先用 `mclaw` 试调看真实返回。
5. **不做**：中间格式（页面描述 JSON）、前端 SDK / 组件门面、导入映射共享 React、沙箱模式、原生端。理由见 §9。

## 1. 参照

| 产品 / 标准 | 做法 | 取了什么 |
|---|---|---|
| W3C Web App Manifest | 应用名、图标、启动地址、关键入口（`shortcuts`）；`monochrome` 图标只取轮廓、颜色由宿主决定 | 侧边栏入口的全部描述 |
| Home Assistant `panel_iframe` / `panel_custom` | 插件 / 配置项往侧边栏加一项，正文是 iframe 或自定义元素 | 「插件页面 = 侧边栏一项 + 主程序外框里的正文」 |
| Obsidian 社区插件 | 插件与主程序同权限运行，开启前明确告知风险 | 授信模式与「用户同意即可」 |
| OpenAI Codex | 用户让 Agent 写源码、打包，做出来的东西直接可用 | Agent 写普通网页、改完即生效的闭环 |

## 2. 插件作者看到的样子

```
my-plugin/
  movieclaw-plugin.toml        # 原有清单，不新增任何字段
  web/
    index.html                 # 任意写法：原生 JS、Vue、React 打包产物都行
    app.js
    style.css
    manifest.webmanifest       # 可选
    icon.svg
```

```json
{
  "name": "本周看板",
  "short_name": "看板",
  "start_url": ".",
  "icons": [{ "src": "icon.svg", "type": "image/svg+xml", "purpose": "monochrome" }],
  "shortcuts": [
    { "name": "下载统计", "url": "downloads", "icons": [{ "src": "dl.svg", "purpose": "monochrome" }] }
  ]
}
```

页面里全是标准写法：

| 要做的事 | 写法 |
|---|---|
| 调主程序接口 | `fetch("/api/v1/subscriptions")`（同源，自动带 Cookie；响应是现有的 `{success, code, message, data}` 信封） |
| 调插件自己的后端 | `fetch("/api/v1/plugins/<插件 id>/rules")`（`plugin-phase2b.md` §8 的插件路由） |
| 插件内部换页 | 相对链接 `<a href="downloads">`，或单页应用的 `history.pushState` |
| 跳到主程序页面 | `<a href="/library/..." target="_top">` |
| 实时数据 | `EventSource`（主程序已有的 SSE 流，如 `/api/v1/jobs/stream`） |
| 跟主程序观感一致（可选） | 写 `var(--mc-text)`、`var(--mc-line)` 这类 CSS 变量：外框自动注入，跟着主题变（§6.3）；不写也照常能用 |

## 3. 地址

- **主程序地址**：`/apps/<插件 id>/<子路径>`。插件 id 在系统里本来就唯一（小写、连字符、不含点，见
  `plugins/packages.py` 的 `_ID`），不存在撞名，不需要改名界面和保留字表。地址装好后不能改，好不好看取决于作者起的 id。
- **iframe 实际加载的地址**：`/api/v1/plugins/<插件 id>/web/<子路径>`，挂在插件路由前缀下、要求登录。插件注册自己的
  路由时，`web/` 这一段保留给静态页面（`routes.mount` 拒绝以 `/web` 开头的路径）。这个地址只在 iframe 里用，地址栏看不到。
- **子路径**：`/apps/stats/` 后面的部分原样转进 iframe。静态托管的规则：
  - 有对应文件就返回文件；目录返回其中的 `index.html`；
  - 都没有、且是页面导航请求（`Sec-Fetch-Dest: iframe` 或 `Accept` 含 `text/html`）时回退到 `web/index.html`，
    单页应用的前端路由直接可用；其余请求（脚本、图片）照常 404，免得把 HTML 当脚本吐回去。
- **缓存**：标准 HTTP 校验——`ETag` + `Cache-Control: no-cache`。插件升级后文件内容变了，浏览器自然拿到新的。

## 4. 侧边栏入口

### 4.1 Manifest → 侧边栏

| 标准字段 | 用途 | 缺省 |
|---|---|---|
| `short_name`，没有就用 `name` | 侧边栏文字（收起时作悬停提示）；建议不超过 8 个汉字，超出省略号 | 插件清单里的 `title` |
| `icons` 中 `purpose` 含 `monochrome` 的那个 | 侧边栏图标：当作遮罩（CSS `mask`），用当前文字颜色填充，选中 / 悬停 / 明暗主题与内置项一致 | 见下一行 |
| `icons` 中其余的（`any`） | 按原图显示，尺寸由主程序统一（桌面 18px、手机网页 22px） | 默认拼图图标 |
| `start_url` | 主入口的落点（相对 manifest 解析，标准规则） | `.`，即 `web/index.html` |
| `shortcuts[]`（`name` / `short_name`、`url`、`icons`） | 侧边栏里的其他项，指向同一个网页根目录下的子路径 | 无 |

- 只读这几个字段，其余字段（`display`、`theme_color`……）忽略；URL 解析出 `web/` 范围之外的项丢弃并写诊断日志。
- 一个插件**只有一个网页根目录、一个 iframe**。侧边栏的多项只是指向不同落点，插件内部换页不重新加载外框。
- 不写 manifest 也能用：一项入口，文字用插件名，图标用默认拼图图标。

### 4.2 进主导航、排序、隐藏

- 应用项与内置项平起平坐，id 是 `app:<插件 id>:<序号>`（主入口序号 0，`shortcuts` 依次 1、2……），交给现有的
  `applyNavOrder`：新装的出现在主导航末尾，用户拖到哪里就记在 `nav.order` 里；卸载或收回权限后自然消失，重装回到原位。
  插件**不能指定位置**，顺序始终由用户决定。
- 用户可以把某一项**移出侧边栏**：`ui.preferences.nav` 新增 `hidden: string[]`（只加字段，老客户端不受影响）。
  只有应用项能隐藏，内置项保持现状。移出后仍能从插件详情页打开。
- **高亮**：取当前子路径**最长前缀匹配**的那一项（在 `/apps/stats/downloads/2026-10` 时点亮「下载统计」）。
- **手机网页**：手机用底部标签栏、没有侧边栏，插件网页的项放在「我的」页的「插件页面」一组里，顺序与移出同侧边栏。
- **Netflix 主题**：桌面顶栏的固定链接后面追加插件网页的项（顶栏本来不跟个人排序，这里同样只尊重移出）。

### 4.3 接口

`GET /api/v1/ui/apps`（登录）：当前用户可见的应用项列表——插件 id、每项的文字、图标地址、是否 `monochrome`、落点子路径。
侧边栏据此与内置项合并。

## 5. 授信与同意

- **插件包**：沿用 `plugin-phase3.md` 的「上传 → 待批准 → 批准」流程。批准页新增一段：
  - 照着侧边栏样式**预览入口**（图标 + 文字）和地址 `/apps/<插件 id>/`；
  - 明确告知后果：「这个插件的网页会以**正在使用它的人**的身份运行；管理员打开时，它拥有管理员的全部权限」；
  - 两个勾选：**加到侧边栏**（默认勾上）、**成员也能看到**（默认不勾）。这两项是用户的决定，不写进插件清单。
- **每个版本单独批准**：插件包每个版本本来就要重新批准（`data/plugins/packages/<id>/<version>/`），代码变了自然要再同意一次。
- **本地插件**（`data/plugins/` 下的目录，Agent 开发时用）：首次出现 `web/` 时同样要在网页上确认一次，之后文件改动**即时生效**，
  刷新页面就能看到——这是 Agent 开发闭环的关键。确认结果按插件 id 记在 `data/plugins/web-pages.json`，不按文件哈希。
- **同意只能由人在网页里点**：`PUT /app/plugins/{id}/web` 挂 `require_admin_session`（管理员 + 第一方客户端），
  Agent、命令行、MCP 的凭证一律 403——本地插件常由 Agent 写出来，不能让它替用户点同意。撤销（`DELETE`）只要管理员。
- **安全模式**：所有插件页面一律不渲染，对应侧边栏项显示为已停用。写坏的页面最多让用户进安全模式卸载，不会让整站打不开。

## 6. 主程序要做的

### 6.1 服务端

| 项 | 内容 |
|---|---|
| 纯网页插件包 | 清单 `entry` 在包里有 `web/` 时可以为空（现在除 `exec` 外必填，见 `packages.py` 的 `_runtime_fields`）：只有 `toml` + `web/` 的包能装、能批准，不启动任何后端进程 |
| 静态托管 | `/api/v1/plugins/<id>/web/*`：要求登录；ETag；单页回退（§3）；只读插件安装目录下的 `web/`，拒绝 `..` 与符号链接越界 |
| manifest 解析 | 安装 / 本地插件加载时解析并校验，结果进插件诊断；坏 manifest 不影响页面本身，退回缺省入口 |
| `/ui/apps` | §4.3 |
| 管理接口 | `GET /app/plugins/pages`（全部带网页的插件与是否已同意）、`PUT` / `DELETE /app/plugins/{id}/web`（同意或改「加到侧边栏 / 成员可见」、撤销）；批准插件包的接口加 `allow_web`、`web_nav`、`web_members` |
| `nav.hidden` | `UiPreferencesSetting.nav` 新增可空字段；`order` 上限 32 → 64。**兼容**：已发布的 iPhone App 用生成模型整体回写偏好，旧模型没有这个字段——请求里没带 `hidden` 时服务端沿用已存的值，显式给 `null` 才清空 |
| nginx | `/api/v1` 本来就转给后端，`/apps/*` 走 Next，都不用改路由表（改了要同步 Next rewrites） |

### 6.2 网页

- 新路由 `app/(app)/apps/[plugin]/layout.tsx` + `[[...path]]/page.tsx`（空）：外框挂在 layout 上，插件内部换页只改子路径，
  iframe 不会被重建。iframe 加载 `web/` 本身而不是 `web/index.html`，单页应用的路由看到的是干净的根路径。
  - 同源、**不加 `sandbox`**（授信模式）；背景透明，主程序的玻璃背景能透出来；
  - 地址同步：iframe 每次 `load`、`popstate`、`hashchange` 以及 `history.pushState` / `replaceState` 之后（同源可直接包一层），
    把 iframe 的子路径用 `replaceState` 写回地址栏——浏览器历史里只留 iframe 自己那一条，返回键按一次退一页；
  - 跳出网页根目录（没写 `target="_top"` 的站内链接）：外框把整页带过去，不套娃；
  - 错误收集：同源可直接监听 iframe 窗口的 `error` / `unhandledrejection`，经 `POST /ui/apps/{id}/errors` 写进系统日志
    （带插件 id 与打开它的人，`/settings/logs?q=<插件 id>` 可查；每个插件每分钟最多 20 条），页面本身不用写任何代码。
    页面脚本在 iframe `load` 之前抛的错收不到；
  - 标签页标题用插件名：地址同步会让 Next 重新套用路由的兜底标题，每次地址变化后写回；
  - 插件未批准、已卸载、安全模式：显示对应的空状态，不加载 iframe。
- 侧边栏：`useVisibleNavItems()` 合并 `/ui/apps` 的项；图标渲染支持遮罩与原图两种；`nav.hidden` 过滤；导航设置页能拖、能移出应用项。
- 现有安全头不用改：`X-Frame-Options: SAMEORIGIN`、`frame-ancestors 'self'` 都允许同源嵌入。
- **开发代理的结尾斜杠**：Docker 部署里 nginx 把 `/api/v1` 直接转给后端；不经 nginx 时由 Next 反代，而 Next 默认会把
  `web/` 的结尾斜杠 308 掉、后端再补回来，转成死循环。所以 `next.config.ts` 关掉内置的结尾斜杠规范化
  （`skipTrailingSlashRedirect`），改由 `middleware.ts` 对页面地址做同样的去斜杠，接口原样转；`web/` 另配一条带斜杠的 rewrite。

### 6.3 主题样式（可选）

不另出 `theme.css`（会和前端的主题变量两处维护）：外框在 iframe 每次 `load` 后，把主程序当前的设计变量以 `--mc-` 前缀写到
页面的 `<html>` 上，并对齐 `color-scheme`、设上 `data-mc-theme`；切换主题时同步更新。前缀是为了不和页面自己的变量撞名。

| 变量 | 含义 |
|---|---|
| `--mc-text` / `--mc-text-muted` / `--mc-text-faint` | 文字三档 |
| `--mc-line` / `--mc-line-strong` | 描边 |
| `--mc-accent` / `--mc-accent-strong` / `--mc-accent-soft` | 强调色 |
| `--mc-surface-raised` / `--mc-surface-inset` / `--mc-glass-fill` / `--mc-glass-fill-hover` | 浮层、输入框、可点行的底色 |
| `--mc-ok` / `--mc-info` / `--mc-warn` / `--mc-danger` / `--mc-danger-solid` | 状态色 |
| `--mc-font` | 字体 |

页面背景保持透明就能透出主程序的玻璃背景；写 `var(--mc-text, #eee)` 带上兜底值，单独打开也能看。

## 7. Agent

内置技能 `movieclaw-plugin-dev` 补一节「插件网页」，内容就是 §0 第 4 条的三句话，加上：

1. 先用 `mclaw` 试调要用的接口，看真实返回的字段，再写进页面；
2. 本地插件目录里写好 `web/`，让用户在网页上确认一次，之后改文件刷新即生效；
3. 用户反馈页面报错时，到系统日志按插件 id 查错误，改完让用户刷新。

不教任何 MovieClaw 专有的前端规则。调技能照惯例用 `/tmp/mc-skill-lab` 测试台，不用 NAS 上的 Agent。

## 8. 分步实施

| PR | 内容 | 端到端验证 |
|---|---|---|
| 1 | 服务端：纯网页插件包、静态托管、manifest 解析、`/ui/apps`、管理接口、`nav.hidden`、批准页需要的字段 | 上传一个只有 `index.html` + manifest 的包：批准前访问 403，批准后能取到；单页回退只对页面请求生效；`..` 越界被拒；升级版本要求重新批准 |
| 2 | 网页：`/apps/...` 路由与 iframe、地址同步、错误收集、空状态与安全模式；侧边栏合并 / 图标 / 高亮 / 拖动 / 移出；批准页的入口预览与两个勾选、本地插件的确认入口；主题变量注入；手机「我的」页与 Netflix 顶栏的入口；页面报错上报接口 | 真实场景：装一个两项入口的插件，左侧出现两项、能拖、能移出；插件内部换页外框不刷新、地址栏同步、返回键按一次退一页；切主题后页面跟着变；页面抛异常能在系统日志里按插件 id 查到；成员默认看不到，勾选后能看到但调管理员接口被拒 |
| 3 | Agent 技能补「插件网页」一节 + 测试台调优 | 用真实提示词「做个页面放左边，看本周新入库的 4K 片」，Agent 在本地插件目录里一次写出能用的页面 |

每步独立 PR、可单独回滚。老客户端只是看不到新字段，不受影响。

## 9. 考虑过、没采用的

| 方案 | 为什么不用 |
|---|---|
| 页面描述 JSON（主程序用自己的组件画） | 自创中间格式，Agent 要先学规则；表达力受限于组件清单 |
| 前端 SDK + 导入映射共享 React、直接挂进主程序组件树 | 要维护 SDK 门面、表面快照、多版本转接；Agent 要学 SDK；样式与 React 版本互相牵制 |
| 自定义 `[[pages]]` 清单段、自定义短名路由 | Web App Manifest 已经有对应字段；自定义短名带来撞名、改名、保留字三套规则 |
| 沙箱 iframe（不透明源 + 消息桥） | 授信模式够用；等出现第三方页面大规模分发时再做，前提条件仍按 `plugin-phase4.md` §6 原文 |
| 原生端（WebView） | 原生 App 用令牌鉴权、不用 Cookie，第一版不考虑 |

## 10. 风险

| 风险 | 应对 |
|---|---|
| REST 接口就是契约，接口改了页面会坏 | operationId 已被 CLI 当公开 API 守着（`cli.md` §2.2）；页面源码在插件目录里，Agent 能直接修。真有第三方页面大量分发时再加兼容保护 |
| 授信页面拿查看者的全部权限 | 批准页明确写后果；成员默认不可见；每个版本单独批准；安全模式全停 |
| 页面伪造登录框钓鱼 | 主程序从不在页面里要密码；插件页面始终在主程序外框里，地址栏是 `/apps/<插件 id>/` |
| 包一层 `history.pushState` 与插件自己的路由库冲突 | 只在调用后读一次地址，不改参数、不拦截；端到端用 React Router / Vue Router 各验一次 |
| `shortcuts` 本义是桌面图标的右键菜单 | 「应用的几个关键入口」语义对得上；只是借用，不改标准含义 |

## 11. 插件体系其他部分的标准化盘点

按同一原则过了一遍整个插件体系。已经是标准的照旧，不是的列为候选，**不在本稿范围**，各自评估：

| 部分 | 现状 | 标准程度 |
|---|---|---|
| 插件参数界面 | JSON Schema 子集（`plugin-phase4.md`） | ✅ 标准 |
| 宿主操作 | OpenAPI 操作目录（CLI / MCP / Agent / 插件共用） | ✅ 标准 |
| 插件进程间通信 | HTTP（`plugin-ipc-http.md`） | ✅ 标准 |
| 插件调 Agent / Go 桥 | A2A | ✅ 标准 |
| 插件第三方依赖 | wheel + pip 离线安装 | ✅ 标准 |
| Webhook 签名 | 自定义 `X-MovieClaw-Signature: sha256=…`（GitHub 式，`webhook.md` §2.3） | 候选：Standard Webhooks（`webhook-id` / `webhook-timestamp` / `webhook-signature`），需兼顾已有订阅方 |
| 事件信封 | 自有格式 | 候选：CloudEvents |
| 错误响应 | `{success, code, message, data}` 信封 | 候选：RFC 9457 Problem Details；全站接口与七端客户端都依赖，改动面极大，先只记下 |
| 插件清单 | `movieclaw-plugin.toml` 自定义字段 | 候选：对齐 `pyproject.toml` 的 `[project]` 与入口点（entry points）；需评估对 `exec` / 纯网页插件的覆盖 |
