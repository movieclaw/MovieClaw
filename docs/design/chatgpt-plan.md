# ChatGPT 订阅接入

使用 OpenAI 官方 Sign in with ChatGPT 的开源 / 自部署通路，将符合资格的 Plus / Pro 订阅接入 MovieClaw。API Key 接入继续保留，两种接入可以同时存在。

## 使用

在 Web 的「模型接入」选择 ChatGPT 订阅（预览），按页面提示使用电脑助手完成官方授权。订阅的添加、重新授权、连接测试和删除均在 Web / 电脑助手管理；iOS 只读取服务器已配置的模型，不包含订阅添加、登录、重新授权或用量管理入口。

使用包含此功能的 `mclaw`：先执行 `mclaw login` 配对自己的 MovieClaw 服务器，然后执行：

```sh
mclaw llm chatgpt login
```

浏览器打开 OpenAI 官方授权页，允许使用订阅后终端确认连接结果。网页显示等待、连接验证及失败状态。连接完成后，Web 和 iOS 的现有对话框、AI 设定均可选择服务器返回的模型。

重新授权已有接入使用 `--provider <ID>`；新增账号省略该参数。每个账号是独立供应商实例，可以分别选择。授权页面显示的应用名称默认 MovieClaw；衍生应用应通过 `--app-name` 使用自己的真实名称。

模型能力优先读取账号目录中的 `supported_reasoning_levels`、`input_modalities` 与上下文窗口，不再只识别本地已知型号。公共 Responses 不支持的档位不进入菜单；例如 Codex 的 `ultra` 包含自动任务委派，不作为普通推理强度透传。旧接入缺少能力声明时，按已核实的官方预设恢复菜单；测试连接会刷新账号目录并保存能力，无需重新登录。

iPhone「我的」页的快捷入口未展开时仍是一行小输入框。点开后，输入框下方显示模型按钮，按钮菜单内可调思维链强度；选择沿用到新会话的第一条消息，换模型会清回默认强度。

在 Web 删除这个供应商会尝试撤销可续期会话并清除本地凭据。远端撤销未确认时，网页明确提示到 ChatGPT 设置中断开 App。用量在 https://chatgpt.com/settings/usage 管理，额度与账号现有订阅共享。iOS 的对应接入详情只显示服务器连接状态和模型信息，没有编辑、删除、测试连接或外部订阅链接。

## 自部署授权

OpenAI 的开源通路要求 `http://127.0.0.1:<port>/auth/callback`，不能把 NAS 公网地址或手机自定义 scheme 当成回调。电脑助手 `mclaw` 监听本机回调，并将 code / state / issued client ID 通过原有认证通路交回服务器。PKCE verifier、nonce 与 OAuth 令牌由服务器持有，浏览器和手机不保存令牌，也不需要复制密钥。iOS 授权代码与回调监听器已经移除，原生 SDK 不生成授权端点；服务器端点保留给电脑助手。

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

iOS 生产界面测试使用隔离服务器创建接入，验证其详情只读、供应商添加菜单不包含订阅，以及快捷输入框展开后仍可选择服务器模型和思考强度。测试不在用户服务器创建或删除供应商，也不发送真实模型请求。

本分支已合入 MovieClaw v0.38.0 / iOS 0.8.0，并重新生成原生 SDK。ModelInfo 的新增协议能力字段保持旧服务器缺字段时可解码；编辑自定义模型时完整保留这些字段。

## 维护者反馈与真实账号验证（2026-10-13）

网络探测在默认接入为 ChatGPT 时明确跳过，在读取密钥或创建出口 transport 之前返回「请在模型接入测试连接」，不会把 OAuth 凭据包或 refresh token 当作 Bearer 发送。移除接入后的远端撤销提醒在 Web 保留显示；iOS 已移除该供应商的删除入口。损坏凭据可在 Web 列表中识别并删除。

再次授权保留账号/订阅权限的具体错误，带账号提示，拒收的新授权会尝试撤销。服务端令牌刷新统一按 provider ID 加锁并保存；模型发现也使用同一持久化通路。接入名称禁止斜杠。已连接邮箱、预览说明、授权等待与失败状态均在 Web 显示。

账号本人曾在先前测试版本完成官方授权并确认使用成功；当前版本已移除 iOS 内授权入口，沿用服务器保存的接入。升级至 0.38.0 后再次验证：已保存令牌包含 `chatgpt.tokens.use.direct`，默认模型连接测试为 active；使用公开 Responses 和 `store=false` / `stream=true`，`gpt-6.1-sol` 在 `high` 档完成 `movieclaw` namespace 内 `qa_echo` 的强制调用，回传工具结果后返回 `QA OK`，两轮均收到完成事件。测试只调用独立 QA 回显函数。

本次真实请求接受 `include: reasoning.encrypted_content`，但回显用例没有返回推理条目，因此不把它作为加密推理条目回放的实测证据。指定工具使用「只提供所选函数 + required」；公共 API 不接受在 `tool_choice` 中添加 `namespace` 字段。

验证包括 Python LLM/API/网络回归、Go 测试、Web 生产构建、原生模型兼容测试和生产 iOS UI 测试，具体最新结果记录在 PR 说明。隔离用例与真实账号证据分别记录，以上不等于所有模型、额度耗尽、真实撤销和加密推理条目回放都已实测。
