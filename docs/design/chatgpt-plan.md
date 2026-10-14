# ChatGPT 订阅接入

使用 OpenAI 官方 Sign in with ChatGPT 的开源 / 自部署通路，将符合资格的 Plus / Pro 订阅接入 MovieClaw。API Key 接入继续保留，两种接入可以同时存在。

## 使用

在 iPhone「模型接入」点击「连接 ChatGPT 订阅」，再点击 **Continue with ChatGPT**。App 会打开系统 Safari 登录页面，并在手机上接收官方要求的 loopback 回调；完成后自动连接当前服务器，账号和模型目录随接入显示。用户关闭页面或取消时关闭监听器，可重新发起。

电脑也可使用包含此功能的 `mclaw`：先执行 `mclaw login` 配对自己的 MovieClaw 服务器，然后执行：

```sh
mclaw llm chatgpt login
```

浏览器打开 OpenAI 官方授权页，允许使用订阅后终端确认连接结果。网页的「ChatGPT 订阅」提供电脑助手步骤；iPhone 支持直接授权，也保留电脑助手选项。连接完成后在现有对话框或 AI 设定选择模型。

重新授权已有接入使用 `--provider <ID>`；新增账号省略该参数。每个账号是独立供应商实例，可以分别选择。授权页面显示的应用名称默认 MovieClaw；衍生应用应通过 `--app-name` 使用自己的真实名称。

模型能力优先读取账号目录中的 `supported_reasoning_levels`、`input_modalities` 与上下文窗口，不再只识别本地已知型号。公共 Responses 不支持的档位不进入菜单；例如 Codex 的 `ultra` 包含自动任务委派，不作为普通推理强度透传。旧接入缺少能力声明时，按已核实的官方预设恢复菜单；测试连接会刷新账号目录并保存能力，无需重新登录。

iPhone「我的」页的快捷入口未展开时仍是一行小输入框。点开后，输入框下方显示模型按钮，按钮菜单内可调思维链强度；选择沿用到新会话的第一条消息，换模型会清回默认强度。

删除这个供应商会尝试撤销可续期会话并清除本地凭据。远端撤销未确认时，返回消息会明确要求到 ChatGPT 设置中断开 App。用量在 https://chatgpt.com/settings/usage 管理，额度与账号现有订阅共享。

## 自部署授权

OpenAI 的开源通路要求 `http://127.0.0.1:<port>/auth/callback`，不能把 NAS 公网地址或手机自定义 scheme 当成回调。iOS 使用只绑定 `127.0.0.1` 的 Network 监听器，启动后再请求授权地址，并用系统 Safari 控制器显示官方页面；电脑使用 `mclaw` 监听。回调的 code / state / issued client ID 通过原有认证通路交回服务器。PKCE verifier、nonce 与 OAuth 令牌由服务器持有，浏览器和手机不保存令牌，也不需要复制密钥。

部署时使用可信连接访问自己的服务器，公网访问使用 HTTPS。服务器与电脑助手都需要此功能；仅更新手机不能新增服务端端点。

## 安全与协议边界

- 新端点沿用 `/llm` 管理员权限。尝试有 10 分钟时效、数量上限、随机 state / nonce / PKCE 和一次性消费；不接受非 loopback 回调。服务器重启会取消未完成尝试；此接入沿用默认的单进程服务部署，未完成授权需要由同一进程处理。
- 初次注册使用 `dynamic_agent_client`；之后保存并复用 issued client ID，重新授权必须匹配原账号。主机 ID 在设置表内稳定保存，不包含个人信息。
- ID token 校验 OpenAI JWKS 的 RS256 签名、issuer、audience、nonce、有效期和 subject；检查使用订阅的 granted scope。客户端只显示脱敏账号与模型目录。
- OAuth 凭据复用现有供应商 SecretBox 加密存储。请求前续期；同一实例串行刷新并原子回写新的 access / rotating refresh token，不允许把令牌发送到自定义模型端点。
- 使用公开 `/v1/models` 与 `/v1/responses`，不调用 ChatGPT 私有 backend-api。不硬编码模型型号；只接入账号模型清单中可展示的条目。未提供规格的型号暂用保守的上下文 / 输出预算，不能视为厂商公布的上限。
- 专用协议强制 `store=false`、`stream=true`，将系统消息转换为 developer，将本地函数放入 namespace，并移除订阅预览不支持的采样和输出上限字段。同步任务也消费流直到 `response.completed`；失败、截断或额度限制不能当作成功。
- 现有 API Key 协议、品牌、Bundle ID、签名、下载器和播放流程不随此功能更改；不包含个人凭据或发行配置。

## 官方契约

- https://developers.openai.com/siwc/token-sharing-open-source
- https://developers.openai.com/siwc/token-sharing-open-source/sign-in
- https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference
- https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions
- https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations

## 验证范围

自动化用隔离 SQLite 与模拟 OpenAI 响应验证授权码交换、PKCE、签名/账号边界、重放拒绝、目录过滤、加密/脱敏、令牌刷新和完成事件，以及现有 API Key 与管理员权限回归。真实账号授权和实际订阅推理必须由账号本人在 OpenAI 页面完成；离线测试和编译不能代替该证据。真实验证结果见下节。

iOS 测试还覆盖 HTTP 回调的 Host/state/重复参数检查、真实 loopback socket、回放拒绝和取消后端口关闭。Simulator 中已通过生产界面打开官方登录页，验证取消/重试，并用模拟授权码走完真实服务器的交换、保存与已连接界面。OpenAI 令牌与模型响应使用测试替身，这些 Simulator 替身结果不能代替下节的独立真实账号验证。

## 维护者反馈与真实账号验证（2026-10-13）

网络探测在默认接入为 ChatGPT 时明确跳过，在读取密钥或创建出口 transport 之前返回「请在模型接入测试连接」，不会把 OAuth 凭据包或 refresh token 当作 Bearer 发送。移除接入后的远端撤销提醒在 iOS 弹窗及网页中保留显示；损坏凭据可在列表中识别并删除。

再次授权保留账号/订阅权限的具体错误，带账号提示，拒收的新授权会尝试撤销。服务端令牌刷新统一按 provider ID 加锁并保存；模型发现也使用同一持久化通路。接入名称禁止斜杠。已连接邮箱、预览说明、网页授权等待与失败状态均进入界面。

真实账号本人已在 iPhone 完成授权并确认使用成功。随后验证已保存的令牌包含 `chatgpt.tokens.use.direct`，默认模型连接测试为 active；使用公开 Responses 和 `store=false` / `stream=true`，`gpt-6.1-sol` 在 `high` 档完成 `movieclaw` namespace 内 `qa_echo` 的强制调用，回传工具结果后返回 `QA OK`，两轮均收到完成事件。测试只调用独立 QA 回显函数。

本次真实请求接受 `include: reasoning.encrypted_content`，但回显用例没有返回推理条目，因此不把它作为加密推理条目回放的实测证据。指定工具使用「只提供所选函数 + required」；公共 API 不接受在 `tool_choice` 中添加 `namespace` 字段。

更新后的定向回归：198 项 Python LLM/API/网络测试通过，Go ChatGPT 用例、Web TypeScript/ESLint/生产构建通过；两项生产 iOS UI 测试确认折叠快捷框不展示控件、展开后展示，以及远端撤销未确认的提醒可见。隔离用例与真实账号证据分别记录，以上不等于所有模型、额度耗尽、真实撤销和媒体播放都已实测。
