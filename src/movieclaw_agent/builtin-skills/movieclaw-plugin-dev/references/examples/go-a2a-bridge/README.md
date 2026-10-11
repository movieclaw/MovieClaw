# A2A 桥（Go）

用 Go 写的 MovieClaw 插件示例：把 A2A（Agent-to-Agent）协议的 JSON-RPC 请求转成 MovieClaw AI 助手的一轮对话。
演示非 Python 插件（`runtime = "exec"`）怎么接入，以及插件怎么驱动 AI 助手（同步与流式）。

| 地址（宿主反代，管理员区） | 说明 |
|---|---|
| `POST /api/v1/plugins/go-a2a-bridge/a2a` | JSON-RPC：`message/send` 同步返回回复；`message/stream` 以 SSE 推送 `status-update` / `artifact-update` |
| `GET /api/v1/plugins/go-a2a-bridge/card` | Agent Card |

`contextId` 就是 MovieClaw 的会话编号，带上它就续写同一个会话。对端用 MovieClaw 的个人令牌
（`Authorization: Bearer …`）认证，由宿主验证。

## 编译与安装

```bash
# 按服务器平台编译（NAS 一般是 linux/amd64）
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o bin/bridge .
mclaw plugin pack .            # 打成 go-a2a-bridge-0.1.0.mcplugin，在「设置 → 插件」上传并批准 agent:mclaw
```

本地调试也可以不打包：把可执行文件放进数据目录的 `plugins/go_a2a/bridge`，在 `plugins.yaml` 里写

```yaml
- id: go-a2a-bridge
  local: true
  runtime: exec
  command: go_a2a/bridge
  grants: ['agent:mclaw']
```

## 调用示例

```bash
curl -s "$SERVER/api/v1/plugins/go-a2a-bridge/a2a" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d '{
    "jsonrpc": "2.0", "id": 1, "method": "message/send",
    "params": {"message": {"role": "user", "messageId": "m1",
                           "parts": [{"kind": "text", "text": "最近有什么订阅更新？"}]}}}'
```

## 与宿主的约定

- `--describe`：输出声明（标题、要用的服务 `agent` / `plugin-routes`、权限 `agent:mclaw`）后退出；
- 运行时 stdin 第一行是引导信息（网关地址、令牌、条目 id）；
- 插件调宿主：HTTP over Unix 套接字连网关，`POST /api/v1/plugin-runtime/{服务}/{方法}`，
  处理宿主转来的请求时原样带上 `X-MovieClaw-Call`（宿主据此对上入口区与因果链，护栏才生效）；
- 在 `--listen-fd` 交来的套接字上起 HTTP 服务；跑起来后调 `session.ready` 一次报全部声明；
- 收到 `SIGTERM` 收尾退出。
