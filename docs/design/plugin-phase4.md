# 插件体系第四阶段：客户端界面扩展

> 状态：**设计稿，待评审**（2026-10-09）。总体模型见 `plugin-extension-model.md`（§1 第 8 项「插件自有数据与界面」、
> §5 分阶段落位），内核见 `plugin-kernel.md` §3.2，进程外运行见 `plugin-phase3.md`，IM 通道绑定见
> `plugin-channels.md` §5.2。本文修订 `plugin-kernel.md` §3.2 里第四阶段的「Web 端 slot」：**不做插件前端代码
> 注入**，改为声明式的贡献点，各端原生渲染。

## 0. 结论先行

1. **插件不带前端代码，只给界面描述（数据），各端主程序原生渲染。** 网页、iPhone、Mac、Apple TV、Android TV
   用同一份描述。插件前端代码和主程序同源运行会绕开第三阶段的进程隔离，见 §1。
2. **全体系只有一套界面词汇：「分步流程」。** 一次交互由若干步组成，每步是表单、二维码、码、外部授权、进度或结束之一。
   插件配置页、IM 通道绑定、插件操作都走同一个步骤引擎和同一个渲染器。
3. **贡献点由主程序预先定义，插件只能往固定位置填。** 第一批是插件配置页、插件操作、删除对话框选项、订阅详情区块。
4. **插件自带网页界面（沙箱 iframe）不在本阶段。** 前提条件记在 §7，等真出现原生控件画不出来的需求再做。
5. **客户端声明自己认识的词汇版本，服务端不下发它画不了的东西。** 旧版 App 看到的是「请在网页端设置」，
   而不是报错（此前新增设备类型枚举值曾让旧 App 登录全部 422）。

## 1. 调研：别人怎么做（2026-10-09）

| | DeepSeek Harness（DSH） | OpenAI 插件（ChatGPT / Codex，MCP Apps） |
|---|---|---|
| 插件界面怎么进页面 | 插件打包好的 React 代码用 `<script>` 同源加载，共享宿主的 React；往类型化 slot 树注册组件（侧边栏、设置页、工具结果卡、输入框周边、浮层），还能改写首页 HTML | 两档：**设置页、富表单、@提及**由宿主按 JSON Schema 用原生控件画；**复杂界面**是插件自带 HTML，放进沙箱 iframe，只能挂在全局侧栏、会话面板、文件查看器三类入口 |
| 通信 | 前端拿宿主 `ctx` 直接调类型化 RPC；插件常在宿主 HTTP 服务上自挂路由（默认不带认证） | postMessage 上的 JSON-RPC：收工具结果、调工具（宿主转发，可拦截 / 要求批准）、发消息、切显示模式、取主题变量 |
| 隔离 | 无。插件后端与宿主同进程，前端同源；无权限声明、签名、审核。官方 SAFETY 文档承认不可信插件可能泄露数据或凭据 | 双层 iframe，外层与宿主**不同源**（默认 `web-sandbox.oaiusercontent.com`，上架要求每插件一个源）；CSP 默认全禁、按声明白名单放行；iframe 拿不到凭据，文件查看器连真实路径都拿不到 |
| 声明式部分有多保守 | 宿主不渲染 JSON 界面；社区 genui 是插件自带白名单渲染器 | 设置只支持布尔 / 字符串（可带枚举）/ 数字 / 整数；表单含不认识的类型时**整张拒绝显示** |
| 兼容 | 只按依赖版本范围拒绝加载；0.x，无稳定承诺 | 握手时宿主声明支持的扩展，插件据此降级；资源地址兼作缓存键，破坏性改动换地址 |
| 前提 | 单用户、只听本机、插件全可信 | 多用户云服务、公开目录要审核 |

对我们的启示：

- 我们是多用户、跑在 NAS、第三方插件在独立低权限进程里。**DSH 式同源加载不能用**：插件前端可以带着登录态调所有接口。
- 现有「插件给数据、主程序渲染」就是 OpenAI 的第一档，方向不变；OpenAI 在这一档比我们还保守，值得照搬
  「类型少、不认识就整张拒绝」。
- 我们多端原生（Apple TV 没有 WebView），声明式比 iframe 更合适；iframe 档即使做也只能网页端有。

来源：[mcp-extensions 规范](https://github.com/openai/mcp-extensions/blob/main/docs/spec.md)、
[MCP Apps 规范](https://github.com/modelcontextprotocol/ext-apps/blob/main/specification/2026-01-26/apps.mdx)、
[ChatGPT UI 文档](https://developers.openai.com/plugins/build/chatgpt-ui.md)、
[安全与隐私](https://developers.openai.com/plugins/guides/security-privacy.md)、
[DSH 主仓库](https://github.com/deepseek-ai/deepseek-harness)（`docs/subsystems/slots.zh.md`、`client-modules.zh.md`、
`web-server.zh.md`、`SAFETY.zh.md`）、[dsh-genui](https://github.com/omdsh-dev/dsh-genui)。

## 2. 现状要点

| 事实 | 位置 | 影响 |
|---|---|---|
| 插件已能用 pydantic 模型声明配置（`@plugin(config=Config)`），本地插件的值写在 `data/plugins.yaml` | `movieclaw_kernel/plugin.py`、`examples/plugins/keyword_rules.py` | 配置页的字段定义可以直接从模型生成，插件不用另写一份 |
| 插件包没有用户可改的配置 | `plugin-phase3.md` §10 后续 | 配置页是插件包第一次有可改配置，需要落库与改后重载 |
| 插件数据支持挂在实体上（作用域 `subscription:<id>`） | `services/plugin_data.py`、`keyword_rules.py` | 订阅详情区块编辑的就是这份数据 |
| IM 通道绑定已有两种界面：表单（可带配对码）和交互流程（微信扫码），网页与 iPhone / Mac 都已按接口渲染 | `movieclaw_sdk/channels.py`、`api/routes/channels.py`、`channel-bind-dialog.tsx` | 是「分步流程」的雏形，§3 把它推广成通用引擎 |
| 宿主操作走 OpenAPI 操作目录，插件路由挂在 `/api/v1/plugins/<id>/` | `plugin-phase2a.md`、`plugin-phase2b.md` §8 | 步骤引擎的回调走插件契约，不新开通道 |
| 网页设置页有统一组件 `settings-ui` | `apps/web/components/settings-ui.tsx` | 网页渲染器复用它，插件界面自然和设置页一致 |

## 3. 界面词汇：分步流程

### 3.1 步骤类型（词汇版本 1）

| 类型 | 用途 | 各端怎么画 |
|---|---|---|
| `form` | 填写字段 | 表单；字段类型见 §3.2 |
| `qr` | 让用户扫码（微信绑定） | 二维码图片 + 状态文案，后台轮询 |
| `code` | 给用户一串码，让其去别处输入或发送（Telegram 配对码） | 大字号码 + 说明 + 复制按钮 |
| `external` | 跳到第三方页面授权（OAuth 类） | 网页开新窗口；App 用系统浏览器 / ASWebAuthenticationSession；TV 显示「请在手机或网页上完成」 |
| `progress` | 等待外部确认 | 转圈 + 文案，后台轮询 |
| `done` / `abort` | 成功 / 失败 | 结果文案；`done` 可带一个「去看看」的站内链接 |

每一步都带 `title`、`hint`。插件推进流程只需返回下一步，**不知道也不关心**对面是哪个客户端。

### 3.2 表单字段类型（词汇版本 1）

`bool`、`string`（可带 `enum`、`multiline`、`secret`）、`int`、`number`、`string_list`（标签输入，关键字规则要用），
外加 `readonly` 文本说明。不做嵌套对象、不做任意数组、不做自定义组件。

- **不认识就整张拒绝**：客户端遇到不认识的步骤或字段类型，整步显示「此设置需要在网页端或新版 App 上完成」，
  不做部分渲染（部分渲染会漏掉必填项）。
- **从 pydantic 生成**：插件配置模型转成字段定义（`Field(description=…)` 作标签说明）；模型里出现词汇外的类型时，
  **插件加载期就报错**并在诊断页提示，而不是等用户打开设置页才发现。
- 校验两层：客户端只做必填和基本类型；真正的校验在插件侧（pydantic），错误按字段回显。

### 3.3 步骤引擎（主程序）

- 接口：`POST /api/v1/ui/flows`（发起，带贡献点与目标）→ `GET /api/v1/ui/flows/{id}`（轮询）→
  `POST /api/v1/ui/flows/{id}/submit`（提交当前步）→ `DELETE`（取消）。与现在 `/channels/bindings` 同形。
- 引擎负责：流程 id 与过期、轮询、把二维码内容渲染成图、错误转中文、权限检查（谁能发起哪个贡献点）。
- 插件侧只实现 `begin / state / submit / cancel` 四个方法；进程外经现有协议代理（同 `RemoteChannelDriver`）。
- 只有一步的表单（多数配置页）就是长度为 1 的流程，客户端不用区分。

### 3.4 版本协商

- 客户端请求头带 `X-MC-UI-Vocab: 1`（不带视为 0，即旧 App）。
- 服务端按版本过滤：贡献点里用到更高版本词汇的条目，对低版本客户端换成一条「请在网页端设置」的占位，而不是原样下发。
- 词汇只增不改；新增步骤或字段类型时版本号加一，并在本节登记。

## 4. 贡献点（第一批）

| 贡献点 | 出现位置 | 插件给什么 | 验收用例 |
|---|---|---|---|
| `plugin.settings` | 「设置 → 插件」插件详情 | 由 `config` 模型自动生成，插件无需额外代码；保存后主程序落库并按 `reloadable` 重载插件 | 关键字规则示例改为用配置页编辑；插件包首次有可改配置 |
| `plugin.actions` | 插件详情里的操作按钮 | 按钮标题 + 一个流程（如「立即同步」「重新授权」） | 片单订阅示例加「立即拉取」 |
| `library.delete.options` | 删除影片对话框 | 若干勾选项（标题、默认值、说明）；用户的选择随删除的可靠事件载荷交给插件 | 扩展模型 §2.1 删片联动：「同时删除种子和订阅」 |
| `subscription.detail.section` | 订阅详情页 | 一个表单，读写该订阅作用域下的插件数据 | 扩展模型 §2.3 A：在订阅详情里编辑关键字规则 |

IM 通道绑定迁到步骤引擎，但**通道契约不变**：中枢把 `Binding.form` / `Binding.flow` 内部翻译成步骤
（表单 → `form`，配对码 → `code`，扫码 → `qr`），第三方通道插件不用改。`/channels/bindings` 接口保留
`kind` 等旧字段给已发布的 App，新版客户端改走步骤渲染。

各端范围：

| 端 | 第一批覆盖 |
|---|---|
| 网页 | 全部 |
| iPhone / iPad / Mac | 全部 |
| Android 手机 | 全部 |
| Apple TV / Android TV | 只读展示 + 「请在手机或网页上设置」（TV 上不做表单输入） |

## 5. 插件侧写法（示意）

```python
@plugin("acme.cascade", title="删片联动", config=Config)
async def apply(ctx: Context[Config]) -> None:
    # 配置页：有 config 模型就自动出现，不用写任何界面代码

    # 删除对话框里的勾选项；用户的选择出现在可靠事件载荷的 options["acme.cascade"]
    ctx.contribute(LIBRARY_DELETE_OPTIONS, "cascade", DeleteOption(
        label="同时删除种子和订阅", default=False, help="H&R 未达标的种子不会被删"))

    # 订阅详情区块：读写 subscription:<id> 作用域下的插件数据
    ctx.contribute(SUBSCRIPTION_SECTION, "rules", EntityForm(model=Rules, key="rules"))
```

具体类型名在 4.1 实施时定，原则是：**插件写数据模型，不写界面**。

## 6. 实施拆分

| 步骤 | 内容 | 验证 |
|---|---|---|
| 4.1 词汇与引擎 | SDK 界面类型；pydantic → 字段定义（含加载期校验）；步骤引擎与接口；版本协商；进程外代理 | 单测覆盖每种步骤 / 字段；进程内外参数化跑同一流程 |
| 4.2 网页渲染器 + 插件配置页 | 基于 `settings-ui` 的通用渲染器；「设置 → 插件」详情加配置与操作；插件配置落库 + 改后重载 | 端到端：网页改关键字规则示例的配置，插件重载后订阅搜索生效 |
| 4.3 IM 绑定迁移（网页） | 中枢翻译绑定为步骤；网页绑定对话框改用通用渲染器；旧字段保留 | NAS 上微信扫码、Telegram 配对码、ntfy 表单各走一遍 |
| 4.4 实体贡献点 | 删除对话框选项（载荷进可靠事件）；订阅详情区块 | 删片联动示例：勾选后种子与订阅被删，不勾不删；订阅详情里改规则后生效 |
| 4.5 原生渲染器 | iPhone / Mac（SwiftUI）、Android 手机；TV 两端占位 | 模拟器连 NAS 跑界面测试；旧版 App（不带版本头）看到占位而非报错 |

每步独立 PR、可单独回滚；4.1～4.4 只动服务端和网页，4.5 再动原生端。

## 7. 暂不做：插件自带网页界面

只有当出现原生控件确实画不出来的需求（例如插件要一个可视化面板）时再做，届时必须满足：

1. **不同源**：插件界面放在独立源（另开端口，或不带 `allow-same-origin` 的无源沙箱 iframe），
   并核实登录 cookie 不会随 iframe 的请求带出。
2. **CSP 按声明生成**：默认全禁，按插件清单里声明的域放行，未声明一律拦截。
3. **只开一座消息桥**：iframe 只能经宿主转发调用插件自己的路由，拿不到用户凭据和真实路径；危险操作要用户确认。
4. **只在网页端**：App 和 TV 显示「请在网页端打开」。

## 8. 风险

| 风险 | 应对 |
|---|---|
| 词汇太少，插件作者绕路（如塞 JSON 到 `multiline` 字符串） | 先看 4.4 两个验收用例够不够；不够就加词汇（版本号 +1），不开自定义组件 |
| 配置改后重载失败 | 参照第三阶段的升级回滚：重载失败恢复旧配置并通知 |
| 删除对话框选项多了显得乱 | 每个插件最多一个选项；超过三个时折叠成「插件选项」 |
| 旧版 App 长期存在 | 版本协商 + 占位；`/channels/bindings` 旧字段至少保留到旧版 App 退出 |

## 9. 待决策

1. **TV 端范围**：TV 上只展示、不做表单输入（建议），还是也要能改？
2. **删除对话框选项默认值**：由插件决定默认勾不勾（建议），还是一律默认不勾？
3. **插件自带网页界面**：确认本阶段不做（建议）。
4. **授权**：第四阶段的开发、验证、开 PR、合并，是否像二 A～三一样由我自主推进，还是每步找你确认？
