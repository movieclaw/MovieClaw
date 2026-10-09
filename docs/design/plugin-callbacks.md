# 插件回调端点与插件 id 格式

> 状态：设计稿（2026-10-10），待评审。前置阅读：`plugin-kernel.md`、`plugin-phase2b.md` §8（插件路由与签名链接）、
> `plugin-channels.md`（IM 通道）、`plugin-phase3.md`（插件包）。

## 1. 背景

用户让内置 AI 助手做「企业微信自建应用」通道：企业微信服务器把消息 POST 到我们给的回调地址。
插件现在开不出这种地址：

- 插件路由的三个区里，只有公开区（`public`）不要登录，但它要求链接带**本插件签发的签名**，
  验签时把**全部查询参数**算进去（`services/plugin_routes.py` 的 `_canonical`）。企业微信回调会在地址后面
  追加 `msg_signature`、`timestamp`、`nonce`（URL 验证时还有 `echostr`），签名必然对不上，一律 404；
- 公开区是为「插件发出去、别人原样访问」的链接设计的（如网盘示例写进 strm 的播放地址），
  不是给「别人主动调进来」用的。GitHub、Jellyfin、Slack 这类往外推消息的平台都接不了。

消息进来以后交给通道中枢这一步，现有契约已经够用：驱动的 `run(account)` 拿到的 `Account.inbound()` 是开放的。
缺的只是一个外部平台调得进来的地址。

本稿同时定下插件 id 的新格式：回调地址里要放插件 id，而现在的 id 强制带点（`channel.weixin`），
放进地址、命令和文件名都不好看，也不是长期该有的样子。

## 2. 目标与非目标

目标：

1. 任何插件都能申请「回调端点」：一个不需要登录、外部平台能直接调用的地址，请求原样交给插件处理；
2. 地址可读、可单独更换和作废，泄露了不连累别的地址；
3. 宿主只管地址、路由、限流和凭据隔离，**不替插件验签**——各平台的验签方式交给插件自己处理；
4. IM 通道在绑定时自动拿到本账号的回调地址，解绑自动作废；
5. 插件 id 改成不含点的标准格式，随带插件包一并改名并迁移，已装的第三方插件包不受影响。

非目标：宿主侧的验签框架；宿主先回 200 再排队（需要异步的插件自己用 `job-handlers`）；插件自定义域名或端口。

## 3. 插件 id 格式

### 3.1 新规则

插件包（第三方与随带）的 id：`^[a-z][a-z0-9-]{1,38}[a-z0-9]$`，即小写字母开头、字母数字和连字符、3～40 位、
不以连字符结尾，**不允许点**。例：`wecom-channel`、`weixin-channel`、`me-weather`。

- 内核里的内置条目（`core.database`、`library.builtin-collections` 等）**保持带点**，不受此规则约束。
  从此「带点 = 内置条目，不带点 = 插件包」，两个命名空间永不相交，未来新增内置条目不会和已装的插件包撞名；
- 本地插件（`plugins.yaml`）同样按新规则校验新写的 id，已有的带点 id 照常加载并在诊断里提示改名；
- 不再有强制的命名空间。不同作者起了同名插件，由安装时的 id 冲突检测拦下（已有机制）。

### 3.2 已装的第三方插件包：带点 id 继续有效

插件代码里写死了 `@plugin("旧.id")`，宿主不能替它改名。所以：

- **新上传**的插件包必须用新格式；
- 已安装的带点 id 继续加载、继续升级（升级包沿用原 id 时放行），诊断里标「旧格式 id，下次大版本请改名」；
- 它们签发过的链接（如 strm 里的 `/api/v1/plugins/<旧 id>/…`）、存的数据都不动。

### 3.3 随带插件包改名与迁移

| 旧 id | 新 id |
|---|---|
| `channel.weixin` | `weixin-channel` |
| `channel.telegram` | `telegram-channel` |
| `channel.discord` | `discord-channel` |
| `channel.feishu` | `feishu-channel` |

中枢 `channels.hub` 是内置条目，不改。

不受影响的：已绑定的通道账号。`channel_account.channel_id` 存的是贡献 id（`weixin`），与插件 id 无关。

迁移（启动时在加载插件包之前做一次，幂等）：

| 位置 | 处理 |
|---|---|
| `data/plugins/packages/state.json` 与目录 `packages/<id>/` | 用户装过替换随带通道的包、且 id 是旧随带 id 的：**不改名**（代码里写死了旧 id），但登记别名，让宿主仍认它为替换包（见下） |
| `data/plugins.yaml` | 把旧随带 id 改写成新 id（如 `- id: channel.weixin / disabled: true`） |
| 表 `plugin_data.entry_id`、目录 `data/plugins/data/<id>/` | 旧随带 id 改成新 id（随带通道目前不用插件数据，一般为空） |
| 表 `event_consumer` / `event_dead_letter` 的 `consumer_id` 前缀 | 同上（随带通道目前不监听可靠事件，一般为空） |
| 表 `system_notice` 的 `dedupe_key`（`plugin:<id>`、`plugin:<id>:health:*`、`plugin-package:<id>`） | 改写前缀，未处理的通知能照常自动消退 |

**别名**：宿主维护「旧随带 id → 新 id」表。判断「这个插件包是否替换随带插件」、中枢摘掉贡献 id 前缀时，都按别名归一。
这样用户之前装的 `channel.weixin` 替换包照常顶替新的 `weixin-channel`，不会出现两个微信通道。

### 3.4 依赖了点的代码

| 位置 | 现状 | 改为 |
|---|---|---|
| `services/plugin_runtime.py` 的 `net.proxy` | 只回答服务名 = 条目 id 最后一段 | 回答服务名 = 条目 id；带点的旧 id 继续按最后一段（兼容） |
| `plugins/manifest.py` 的 `BUILTIN_GROUPS` | 按 `channel.` 前缀分组 | 随带插件包按随带清单分组（`bundled_ids()`），不看前缀 |
| `plugins/packages.py` 的 `_ID` 及错误文案、技能的 `new_plugin.py` | 要求带点 | 新规则；技能骨架、示例、文档里的 id 全部换新格式 |
| mclaw 命令 | `plugins.me.hello.status` → `mclaw plugins me hello status` | `plugins.me-hello.status` → `mclaw plugins me-hello status`（CLI 不用改） |

示例插件 id 同步改：`examples.ntfy` → `ntfy-example` 等；测试里构造插件包用的 id 一并换新格式，
另留一条用例守住「已装的带点 id 仍能加载、升级」。

## 4. 回调端点

### 4.1 地址

```
<外部访问地址>/api/v1/hooks/<插件 id>/<端点名>/<密钥>[/<子路径>]
例：https://movie.example.com/api/v1/hooks/wecom-channel/callback/k7Q2xZp9MfT3aR8w
```

- **插件 id**：看得出是谁的地址，也让各插件的端点名互不冲突。不放在 `/api/v1/plugins/<id>/` 下，
  那是插件自己的接口空间，插件自定义一个 `/hooks/…` 接口就会撞上；
- **端点名**：插件在代码里定义，`^[a-z][a-z0-9-]{0,31}$`；
- **密钥**：宿主生成，16 位字母数字（约 95 位熵）。它既证明调用方拿到过这个地址，也标识这次调用属于谁：
  一个端点可以有多把密钥，每把登记归属（整个插件 / 某个通道账号 / 某个实体），转给插件时一并带上；
- 子路径原样交给插件（少数平台在地址后面拼路径）；
- nginx 前门已把 `/api/v1/` 整段转给后端，不用改。

### 4.2 宿主职责

宿主只做下面这些，**不验签、不解析请求体**：

| 职责 | 说明 |
|---|---|
| 登记 | 表 `plugin_callback`：插件 id、端点名、密钥（存哈希）、归属（`scope`：`plugin` / `account:<channel_id>:<account_id>` / `entity:<kind>:<id>`）、创建时间、最近调用时间、成功与失败次数、是否作废 |
| 路由 | 按（插件 id，端点名，密钥）查登记，查不到或已作废一律 404；插件未运行时 503 |
| 限制 | 请求体上限（默认 1 MB，插件可在登记时调小）、每把密钥每分钟请求数上限、只放行登记时声明的方法 |
| 凭据隔离 | 转发前剥掉 MovieClaw 自己的登录 Cookie 和令牌（管理员用浏览器打开这个地址时，浏览器会自动带上登录 Cookie，插件不该拿到）；外部平台自己的请求头（含它们放在 `Authorization` 里的）原样转发 |
| 日志 | 访问日志只给密钥打码，插件 id 与端点名照常记录 |
| 统计 | 插件回 401 / 403 记为一次验证失败；短时间内连续失败发待处理事项（可能配置错了，也可能有人在试探） |
| 生命周期 | 插件卸载时作废它的全部密钥；通道账号解绑、实体删除时作废对应密钥；可单独换密钥（旧地址立即失效） |

地址用「设置 → 应用设置」的外部访问地址拼。没配时，登记照常成功，但返回的地址只有路径，并附「先配外部访问地址」的提示。

### 4.3 插件接口

新契约 `plugin-callbacks`（服务，实验级 1.0）：

```python
from movieclaw_sdk.callbacks import PLUGIN_CALLBACKS, CallbackRequest, CallbackResponse

callbacks = ctx.use(PLUGIN_CALLBACKS)

async def on_wecom(req: CallbackRequest) -> CallbackResponse:
    # req.method / req.subpath / req.query（多值）/ req.headers / req.body（原始字节）/ req.scope（这把密钥的归属）
    if not verify(req):                       # 企业微信 msg_signature，插件自己验
        return CallbackResponse(status=403)
    ...
    return CallbackResponse(status=200, body=b"success", headers={"Content-Type": "text/plain"})

callbacks.endpoint(ctx, "callback", on_wecom, methods=("GET", "POST"))          # apply 里登记处理函数
url = await callbacks.issue(ctx, "callback", scope="plugin")                   # 发一把密钥，返回完整地址
await callbacks.revoke(ctx, url)                                                # 作废
```

- 处理函数同步返回响应，平台要求的特殊答复（企业微信回 `echostr`、Slack 回 challenge）都由插件决定；
- 需要异步处理的，处理函数验签后把工作交给 `job-handlers` 并立即返回；
- 处理函数有超时（默认 10 秒，平台大多要求几秒内答复），超时宿主回 504 并记一次失败；
- 进程外运行时请求经现有的路由代理转进插件进程，与插件路由同一条链路。

清单声明：`[permissions] callbacks = ["callback"]`。批准安装时单独列出「这个插件会开放以下外部回调地址」；
没声明的端点名登记时直接报错。`check_plugin.py` 核对代码里登记的端点名与清单一致。

### 4.4 管理与诊断

- mclaw（也就是 AI 助手可用）：`app plugins callbacks list [--plugin <id>]`、`rotate <端点>`、`revoke <端点>`；
  列表里的地址密钥打码，`rotate` 的结果里给出新地址全文；
- 插件页的插件详情里列出它的回调端点（地址打码、最近调用时间、失败次数），可复制、可换、可作废；
- 诊断信息带上端点的调用统计。

### 4.5 与 IM 通道集成

驱动在 `Capabilities` 里声明 `webhook=True`，实现：

```python
async def webhook(self, account: Account, req: CallbackRequest) -> CallbackResponse: ...
```

- 用户在「设置 → 消息通道」绑定成功时，中枢为这个账号发一把密钥（端点名固定为 `webhook`，归属 `account:…`），
  绑定结果与账号详情里显示回调地址和「把它填到平台后台」的说明；
- 请求进来时中枢按归属找到账号，调驱动的 `webhook(account, req)`；驱动验签、解密、回平台要的答复，
  消息照常经 `account.inbound()` 交给中枢——插件不用自己维护「哪个地址对应哪个账号」；
- 解绑即作废；换地址在账号详情里操作。

## 5. 安全小结

外部请求要过两道关：先是不可猜的地址（宿主），再是平台自己的签名（插件）。宿主保证三件事：

- 没签发过的地址打不进来；
- 插件拿不到 MovieClaw 的凭据；
- 请求体和频率有上限。

插件写错验签只影响它自己的端点，批准安装时用户已被告知它会开放外部地址。

## 6. 分步实施

| 步 | 内容 | 验收 |
|---|---|---|
| 1 | 插件 id 新格式：校验、已装带点 id 兼容、随带通道改名与迁移、别名、代理服务名与分组改造；示例、技能、测试换新 id | 已有数据与绑定账号在升级后照常工作（带旧数据的升级用例）；旧 id 替换包仍顶替随带通道；新上传带点 id 被拒 |
| 2 | 回调端点：表与迁移、`/api/v1/hooks` 路由、限制、凭据隔离、日志打码、统计与通知、`plugin-callbacks` 契约与 SDK、清单声明与批准提示、mclaw 管理、插件页展示 | 模拟平台（带自己的查询参数和请求头）调进插件拿到原样请求；未登记 / 作废 / 超限 / 超时各返回预期状态码；登录 Cookie 不进插件；卸载后地址失效 |
| 3 | 通道集成：`webhook` 能力、绑定时发地址、解绑作废；验收插件「企业微信自建应用」放进技能示例目录 | 模拟企业微信 URL 验证（回 `echostr`）与加密消息回调，消息进中枢、AI 回复经应用消息接口发出 |
| 4 | 插件开发技能：回调端点写法、各平台验签速查（企业微信、GitHub、Telegram、Slack）、回调式通道写法；评测补题 | 测试台复测：子代理能按技能写出回调式插件并端到端跑通 |

## 7. 待定

- 地址里是否允许子路径（目前设计允许）；
- 每个插件可登记的端点数、每个端点的密钥数上限；
- 企业微信新建自建应用对回调域名的要求（是否须为企业主体验证过的域名），以企业微信后台实际要求为准，影响的是用户能否用自己的域名，不影响本设计。
