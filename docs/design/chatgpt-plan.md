# ChatGPT 订阅接入

使用 OpenAI 官方 Sign in with ChatGPT 的开源 / 自部署通路，将符合资格的 Plus / Pro 订阅接入 MovieClaw。API Key 接入继续保留，两种接入可以同时存在。

## 使用

在运行浏览器的电脑上安装包含此功能的 `mclaw`，先执行 `mclaw login` 配对自己的 MovieClaw 服务器，然后执行：

```sh
mclaw llm chatgpt login
```

浏览器打开 OpenAI 官方授权页。选择 **Continue with ChatGPT**，允许使用订阅；完成后终端确认连接结果。网页或 iPhone 在「模型接入」选择「ChatGPT 订阅」，可查看步骤与刷新接入；连接完成后在现有对话框或 AI 设定选择模型。

重新授权已有接入使用 `--provider <ID>`；新增账号省略该参数。每个账号是独立供应商实例，可以分别选择。授权页面显示的应用名称默认 MovieClaw；衍生应用应通过 `--app-name` 使用自己的真实名称。

删除这个供应商会尝试撤销可续期会话并清除本地凭据。远端撤销未确认时，返回消息会明确要求到 ChatGPT 设置中断开 App。用量在 https://chatgpt.com/settings/usage 管理，额度与账号现有订阅共享。

## 自部署授权

OpenAI 的开源通路要求 `http://127.0.0.1:<port>/auth/callback`，不能把 NAS 公网地址或手机自定义 scheme 当成回调。`mclaw` 在电脑绑定 loopback 监听器，再向已配对的服务器请求授权地址；回调的 code / state / issued client ID 通过同一认证通路交回服务器。PKCE verifier、nonce 与 OAuth 令牌由服务器持有，浏览器和手机不保存令牌，也不需要复制密钥。

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

自动化用隔离 SQLite 与模拟 OpenAI 响应验证授权码交换、PKCE、签名/账号边界、重放拒绝、目录过滤、加密/脱敏、令牌刷新和完成事件，以及现有 API Key 与管理员权限回归。真实账号授权和实际订阅推理需要账号本人在 OpenAI 页面完成；离线测试和编译不能代替该证据。
