# IM 通道插件化：开放「IM 通道」契约，微信变成真正的插件包

> 状态：设计定稿（2026-10-09），按 §9 分步实施。
> 前置：插件内核（plugin-kernel.md）、第三阶段插件包与进程外运行（plugin-phase3.md）。

## 1. 为什么做

插件体系第三阶段之后，「内置插件」只是一层生命周期外壳。以微信通道为例：

- 内核管它的启动顺序、关停、失败隔离、能否关闭——但它在 `plugins/delivery.py` 里只有 8 行；
- 真正的业务代码（约 1500 行）是主程序的普通代码：协议客户端在 `movieclaw_channel/weixin/`，
  粘合层在 `services/weixin_channel.py`，绑定接口在 `api/routes/channels.py`，主动推送在
  `services/channel_push.py` 里直接 `get_weixin_channel()`；
- 关掉 `channel.weixin` 后设置页的 `GET /channels/weixin/accounts` 直接 500（已实测）；
- Telegram / Discord / 飞书 又是另一套几乎重复的服务（`services/im_channel.py`）。

第三方想接一个新通道（企业微信、钉钉、ntfy……）无从下手：没有契约，主程序也不认识它。

用户要的「真正的插件系统」：

1. **内置插件就是插件**：微信通道的代码只依赖 SDK 与开放契约，能打成 `.mcplugin`，
   能被动态安装，装上之后功能完全正常；
2. **第三方能接入新通道**：按同一份契约写一个插件包，装上就出现在设置页，能绑定、能对话、能收推送。

## 2. 用户决策（2026-10-09）

| 问题 | 决定 |
|---|---|
| 随应用携带的通道插件默认怎么运行 | 主进程里运行（零额外开销）；进程外由 CI 与动态安装覆盖验证 |
| 企业微信这次做不做 | 不做，只保证能接；附一个最小示例通道插件证明第三方能接入 |
| Telegram / Discord / 飞书 | 一起迁到新契约，不留两套通道体系 |
| 授权 | 开发、验证、PR、合并全权；需要真实微信扫码等用户配合的步骤单独找用户 |

企业微信以后做时走「智能机器人」长连接模式（botId + secret 主动连 `wss://openws.work.weixin.qq.com`，
不需要公网回调地址），正好是本契约「表单绑定 + 收消息循环」的形态。

## 3. 概念

- **通道插件**：实现「IM 通道」契约的插件，只管一个平台怎么收发、怎么绑定。微信、Telegram、
  Discord、飞书都是随应用携带的通道插件（内置插件），第三方通道插件经插件包安装。
- **通道中枢**：主程序里所有通道共用的部分（§5），不知道任何具体平台。
- **通道账号**：一次绑定的结果（一个微信 bot、一个 Telegram bot、一个飞书群机器人），由中枢存储。

## 4. 边界：什么归中枢，什么归插件

| 能力 | 归属 | 说明 |
|---|---|---|
| 账号存储（凭据加密、插件私有状态、白名单、当前 AI 会话） | 中枢 | 插件拿不到主密钥；凭据由中枢解密后交给插件的账号句柄 |
| 收消息后的处理：去重、白名单、`/stop` `/reset`、同会话串行、跨会话限流、图片聚合 | 中枢 | 现 `ChannelDispatcher`，原样复用 |
| AI 助手对接：受限工具集、会话持久化、分步回复、「思考中💭」回执、图片附件 | 中枢 | 现在微信和 IM 各写一份，合成一份 |
| 发送：出站队列、长消息拆分、失败重试、图文退纯文本 | 中枢 | 现发送泵，原样复用；调用插件的 `send` / `send_photo` |
| 主动推送：按事件开关、配图、扇出到所有账号 | 中枢 | 遍历注册表里的通道，不再写死平台 |
| 配对码绑定（Telegram / Discord 这类「填 token，私聊 bot 发 6 位码」） | 中枢 | 通用流程，插件只需提供 `validate` |
| 设置页：通道列表、账号、绑定对话框、推送开关、测试推送 | 中枢 | 按插件声明的绑定方式通用渲染，插件不带界面 |
| 平台协议：收消息循环、发文字 / 图片、「正在输入」 | 插件 | |
| 绑定步骤：校验 token、扫码状态机（微信） | 插件 | |
| 平台私有状态：游标、微信 context_token、typing 票据 | 插件 | 经账号句柄的 `state` 存取，中枢只负责持久化、不解读 |

## 5. 契约「IM 通道」

### 5.1 注册表 `im-channels`（实验级）

插件往注册表贡献一个 `ChannelDriver`。贡献 id 即通道 id：内置的是 `weixin` / `telegram` / `discord` /
`feishu`，第三方自动带插件 id 前缀（如 `acme.wecom:wecom`），与现有注册表规则一致。

SDK 类型放在 `movieclaw_sdk.channels`（插件只 import 这里）：

```python
class ChannelDriver:
    title: str                          # 「微信」
    description: str = ""
    capabilities: Capabilities          # receive / photo / typing / max_text_len
    binding: Binding                    # 见 5.2

    # 绑定
    async def validate(self, fields: dict[str, str]) -> BindResult: ...        # 表单绑定
    async def begin_flow(self) -> FlowState: ...                              # 交互式绑定
    async def flow_state(self, flow_id: str) -> FlowState: ...
    async def flow_input(self, flow_id: str, value: str) -> FlowState: ...
    async def cancel_flow(self, flow_id: str) -> None: ...

    # 运行
    async def run(self, account: Account) -> None: ...        # 收消息循环，直到被取消
    async def send(self, account: Account, reply: Reply, text: str) -> None: ...
    async def send_photo(self, account: Account, reply: Reply, photo: bytes, caption: str) -> None: ...
    async def typing(self, account: Account, reply: Reply, on: bool) -> None: ...
    def push_target(self, account: Account) -> Reply | None: ...  # 主动推送发给谁，默认绑定人
```

`Account`（账号句柄，中枢构造）：

| 成员 | 说明 |
|---|---|
| `id` / `display_name` / `bound_user` | 平台账号 id、展示名、白名单用户 |
| `credentials: dict[str, str]` | 绑定时插件返回的凭据（中枢加密存储，交给插件时已解密） |
| `state: dict` + `await save_state(patch)` | 插件私有状态（微信游标、context_token），中枢持久化、不解读 |
| `await inbound(msg)` | 交给中枢一条归一化消息（文字、图片字节、平台消息 id、回复定位） |
| `ChannelAuthError` | `run` 抛出即表示凭据失效：中枢停账号、标记「需重新绑定」 |

`Reply` 即现在的 `ReplyContext`：`user_id` + 插件私有的 `token` 字典，中枢原样带回、不解读。

### 5.2 两种绑定方式

| 方式 | 适用 | 中枢做什么 | 插件做什么 |
|---|---|---|---|
| **表单**（`Binding.form(fields, pairing=…)`） | Telegram / Discord（token + 配对码）、飞书（Webhook 地址，无配对）、企业微信智能机器人（botId + secret） | 按字段渲染表单；`pairing="code"` 时生成 6 位码，临时起账号只比对配对码，命中即落库、把发码人设为白名单 | `validate(fields)` 校验并返回账号 id、展示名、凭据 |
| **交互式**（`Binding.flow()`） | 微信扫码（二维码 → 扫码 → 可能要输入配对数字 → 确认） | 渲染 `FlowState`：状态文案、二维码（插件给内容，中枢渲染成图）、需要时的输入框；前端轮询 | 维护状态机，确认时在 `FlowState.result` 里给出 `BindResult` |

`BindResult`：`account_id`、`display_name`、`credentials`、`bound_user`（可空，配对码流程由中枢补）、
初始 `state`。

### 5.3 进程内与进程外同一份代码

- 进程内：注册表里就是插件的驱动对象，中枢直接调用。
- 进程外：插件进程里保留驱动对象，宿主拿到一个桩；中枢调用桩 → 经 stdio 协议调插件；
  账号句柄在插件侧也是桩，`inbound` / `save_state` 回调宿主。图片字节随消息传（中枢已有 10MB 上限）。
- 需要给运行器协议补一条「取消调用」消息：停账号时宿主取消插件侧的 `run`（现在调用只能等返回）。

## 6. 通道中枢（主程序）

- `movieclaw_api/channels/`：`hub.py`（账号启停、绑定流程、推送扇出）、`agent.py`（AI 助手对接，
  合并 `weixin_channel.py` 与 `im_channel.py` 的重复部分）；复用 `movieclaw_channel` 的
  dispatcher / manager / pusher，并把它们挪进中枢包（它们本来就与平台无关）。
- 通道列表 = 注册表现取：插件关掉、卸载、装上，中枢跟着增减，不需要重启。
  通道插件不在了，它的账号保留在库里，设置页显示「通道插件未启用」，不再 500。
- 账号表 `channel_account` 泛化：
  - 新增 `credentials`（加密 JSON）、`state`（JSON）、`display_name`；
  - 唯一约束改为 `(channel_id, account_id)`；
  - 迁移：微信 `token + base_url → credentials`、`cursor + context_token → state`；
    Telegram / Discord `token → credentials`；飞书照现有存法映射。**已绑定的账号迁移后无须重新绑定。**
- 推送开关 `channels.push` 不变，事件开关对所有通道生效。
- 接口（新）：

| 接口 | 作用 |
|---|---|
| `GET /channels` | 通道列表（标题、能力、绑定方式、是否可用）+ 各自账号 |
| `POST /channels/{channel}/bindings` | 表单绑定（字段）或开始交互式绑定 |
| `GET /channels/bindings/{id}` | 绑定状态（前端轮询） |
| `POST /channels/bindings/{id}/input` | 交互式绑定里提交输入（微信配对数字） |
| `DELETE /channels/{channel}/accounts/{account_id}` | 解绑（`x-cli-dangerous`） |

旧接口：`/channels/im/push-config`、`/channels/im/push-test` 保留（已发布的 iOS 在用）；
`/channels/weixin/*`、`/channels/im/{accounts,bindings,feishu}` 在网页切到新接口后删除。

## 7. 随应用携带的插件包

- 目录 `src/movieclaw_plugins/<名字>/`，每个都是完整的插件包（带 `movieclaw-plugin.toml`），
  与第三方插件包同一套清单、同一个加载器；来源记为 builtin，出现在「设置 → 插件 → 内置」。
- 随应用携带的包受信任：不走批准，按决定在主进程里运行；清单里的 `runtime` 只对动态安装生效。
- **同 id 动态安装即替换**：装一个与随带包同 id 的插件包（例如新版微信通道），它替换随带版本
  （中枢里的账号照常、不用重新绑定）；卸载后随带版本自动回来。插件页标「已替换内置版本」。
- 代码约束（测试守）：随带插件包只能 import `movieclaw_sdk` 与 SDK 承诺提供的第三方库
  （`httpx`、`cryptography`、`pydantic` 等，清单写在 SDK 里），不能 import `movieclaw_api` 等主程序内部。

## 8. 示例第三方通道

`examples/plugins/ntfy_channel/`：ntfy 双向通道（订阅一个 topic 收消息、往另一个 topic 发回复），
表单绑定（服务器地址、收 / 发 topic、可选令牌），不需要任何平台账号。用途：

- 证明第三方只靠 SDK 就能接一个可对话、能收推送的新通道；
- CI 里用假 ntfy 服务器端到端测试；NAS 上用自建或公共 ntfy 实测。

## 9. 实施步骤

| 步 | 内容 | 验证 |
|---|---|---|
| H1 | SDK 通道类型 + `im-channels` 注册表 + 通道中枢 + 账号表迁移 + 新接口；四个通道先以进程内驱动形式接上（代码暂留原处） | 现有通道测试全部改走中枢仍通过；迁移测试（旧行 → 新列，绑定照常）；关掉通道插件接口不 500 |
| H2 | 网页通用通道设置页（列表、表单 / 配对码 / 扫码三种绑定对话框、推送开关）切到新接口，删旧接口 | 网页单测 + 浏览器走查 |
| H3 | 运行器支持 `im-channels`（桩、账号句柄回调、取消调用）+ ntfy 示例插件 | 进程内 / 进程外各跑一遍：绑定、对话（假 LLM）、推送、停账号 |
| H4 | 随带插件包机制 + 同 id 替换；微信迁成 `movieclaw_plugins/weixin`（只依赖 SDK） | import 约束测试；CI 打包微信 → 动态安装替换随带版本 → 假 iLink 服务器跑通扫码绑定、对话、推送；卸载恢复 |
| H5 | Telegram / Discord / 飞书 迁成随带插件包 | 同上，各自的假服务器测试 |
| H6 | NAS 验收 | 已绑定账号迁移后照常收发；ntfy 示例真实对话；微信包动态安装后真实微信对话（需要用户配合扫码 / 发消息） |

每步一个 PR，按惯例测试 + NAS 验证后合并。

## 10. 验收标准

1. `movieclaw_plugins/weixin` 不 import 任何主程序内部模块；
2. 把它打成 `.mcplugin` 动态安装（替换随带版本），扫码绑定、AI 对话、图片、正在输入、主动推送全部正常；
3. ntfy 示例插件以第三方身份安装（进程外），能绑定、对话、收推送；
4. 关掉 / 卸载任何通道插件，设置页与推送都不报错，账号保留，重新装上后自动恢复；
5. NAS 上已有的微信 / Telegram 等绑定迁移后无须重新绑定。

## 11. 风险

- **迁移**：账号表改结构，NAS 有真实绑定。迁移前后都要备份（部署脚本已做），迁移测试覆盖每种通道的旧行。
- **进程外长连接**：收消息循环在插件进程里常驻，宿主重启 / 插件崩溃要能恢复；沿用中枢的退避重启，
  插件进程崩溃由第三阶段的自动重启兜底。
- **体积**：图片随协议以 base64 传输，入站 10MB 上限下可接受；以后需要再走描述符传递。
