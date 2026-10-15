# 插件调用 AI 助手（Agent）

> 状态：**已实施**（2026-10-11）。前置阅读：`plugin-ipc-http.md`（进程间通信）、`plugin-phase2a.md` §3（插件主体与授权）、
> `agent-cli-integration.md` §4（递归硬闸）、`agent-runtime-resilience.md`。

## 1. 目标

插件经用户授权后，可以驱动产品内的 AI 助手跑一轮对话，结果既能同步拿，也能逐事件流式拿。典型场景是协议适配：
插件实现某个厂商的 A2A 协议，自己开一个接口，收到请求后做协议转换、转发到 Agent 会话，再把回复（含 SSE）转回对端格式。
其他场景：Webhook 触发 Agent 处理、插件的定时任务让 Agent 写周报。

- 进程内、进程外插件写法完全一样；
- 用户显式授权，授权写清工具档位；
- 插件发起的运行与网页走同一条启动路径、同一个运行注册表：网页上看得到、能跟随、能停止；
- 堵住递归（Agent → 插件 → Agent）和越权（成员或外部调用方借插件用上管理员级 Agent）。

非目标：成员身份的 Agent（`member-permissions-v2.md` 已推迟）；图片附件；插件拿到工具的参数与输出。

## 2. 写法

```python
from movieclaw_api.plugins.keys import AGENT
from movieclaw_sdk import plugin

@plugin("acme-a2a", inject=(AGENT,), permissions=("agent:mclaw",))
async def apply(ctx):
    agent = ctx.use(AGENT).scoped(ctx)
    reply = await agent.ask("沙丘 2 的订阅到哪了？")            # 同步：等这一轮跑完
    turn = await agent.start("继续", session_id=reply.session_id)  # 流式
    async for event in turn.events():                             # text / tool / compacted / done / error / cancelled
        ...
```

契约在 `movieclaw_sdk/agent.py`（只依赖 pydantic）：

| 方法 | 说明 |
|---|---|
| `start(content, *, session_id, tools, instructions, model, thinking_level) -> AgentTurn` | 新建或续写会话并开始一轮，立即返回。`tools` 缺省取授权档位，只能往下调；`instructions` 追加在系统提示词后面 |
| `ask(content, *, timeout=300, cancel_on_timeout=True, …) -> AgentReply` | `start` + 等结束；超时返回 `status="timeout"`（默认顺带取消） |
| `AgentTurn.events(*, after=0, include_thinking=False)` | 逐事件产出到终态；`after` 是上次的 `seq`（续传）；迭代器关闭不取消运行 |
| `AgentTurn.result(timeout)` / `cancel()` | 等结果 / 取消 |
| `attach(session_id) -> AgentTurn \| None` | 拿回会话最近一轮的句柄（对端断线重连） |
| `sessions(limit)` / `delete(session_id)` | 只看得到、删得了自己建的会话 |

事件与内部 `AgentEvent` 解耦：`text`、`thinking`（可选）、`tool`（开始 / 结束、名字、是否出错、耗时）、`compacted`、
终态 `done` / `error` / `cancelled`（带 `reply`）。工具的参数与输出不给插件：Agent 以管理员身份运行，输出可能含路径、站点信息，
插件很可能原样转给外部。**终态事件交出前，这一轮的持久化收尾已完成**——插件拿到结果就能紧接着续写同一个会话。

错误：`AgentNotGranted`（未授权、档位超出、代表成员、由 Agent 引起）、`AgentBusy`（会话正在跑、并发已满）、
`AgentUnavailable`（没配模型供应商、服务正在关闭）、`AgentSessionNotFound`（不存在或不归本插件，两种不区分）。
跨进程时经 `rpc.register_error` 还原成同一类型。

## 3. 实现

- **一条启动路径**：`routes/agent._accept_user_message` 增加 `owner`、`tool_profile`、`instructions`、`max_steps` 参数，
  网页调用全取默认；宿主实现 `services/plugin_agent.PluginAgent` 调它，运行进同一个注册表。
- **进程内**：内核条目 `agent.invoke` 提供 `AGENT`，`scoped(ctx)` 给 `AgentClient` 门面，底下直接是 `PluginAgent`。
- **进程外**：宿主网关导出服务 `agent`（`plugin-ipc-http.md` 的通用调用），`events` 是流式方法（ndjson），
  SDK 侧同一个 `AgentClient` 门面套在生成的代理上。没有长轮询，也没有专门的协议。
- **工具档位**（`tool_profile`）：`none` 不带工具；`mclaw` 只有服务操作（工作目录按插件隔开）；
  `full` 是 bash / 文件 / mclaw（不含网页才有的卡片绘制）。技能清单依赖 read 工具，所以只有 `full` 用网页的提示词，
  其余用基础提示词。步数上限：none / mclaw 40，full 200。

## 4. 授权

权限串 `agent:none` / `agent:mclaw` / `agent:full`，走插件已有的授权链路：

| 插件来源 | 声明 | 批准 |
|---|---|---|
| 内置 | `@plugin(permissions=(...))` | 声明即批准 |
| 本地受信（`plugins.yaml`） | 同上 | 条目的 `grants` 里列出 |
| 插件包 | 清单 `[permissions] operations` | 安装时用户批准；**最高 `agent:mclaw`**，申请 `agent:full` 直接拒收 |

批准界面按危险项展示（以管理员身份运行、按模型用量计费、插件可以把回复转给它自己的调用方）。
代表成员运行（`act_as`）的插件一律不能用：Agent 令牌不带成员身份。

## 5. 护栏

- **入口区封顶**：插件路由的守卫依赖与回调端点在上下文里标记入口区（`plugin_routes.current_zone`）。
  只有管理员区按授权档位；成员区、公开区路由和回调端点进来的调用一律降为 `none`。进程外插件经调用号恢复上下文，同样生效。
- **防递归**：Agent 的请求在因果链链首打 `@agent` 标记（`movieclaw_kernel.AGENT_MARK`），经事件、插件、宿主操作一路带着
  （可靠事件随行持久化，无需新列），`Origin.via_agent` 为真时拒绝发起 Agent。覆盖两条路：Agent 调操作引起事件、
  插件监听后再调 Agent；Agent 经 mclaw 直接调插件的接口。
- **成本**：每个插件同时最多 2 轮，满了立即报忙（不排队）；插件卸下时取消它还在跑的轮次；每轮记一行日志（插件、会话、档位）。
- **归属**：会话头行与索引表记 `owner = plugin:<条目 id>`（迁移 `b4e8d2a61c7f`，索引重建从头行回填）。插件只能续写、读、
  删自己的；网页会话列表返回 `owner`，管理员看得到插件让 Agent 干了什么，也能直接停止。

## 6. 验证

`tests/api/test_plugin_agent.py`，进程内 / 进程外各一遍（真实应用生命周期 + 确定性假大模型）：
同步问答与 SSE 续写、事件序号有序、会话归属与网页列表的 `owner`；未批准被拒、档位超出被拒、档位下调、成员区封顶为 `none`；
续写网页会话当作不存在；用 Agent 令牌调插件接口被递归闸拒绝；并发上限、同一会话不能并发、显式取消、插件卸下取消在跑的轮次。

## 7. 后续

- A2A 适配示例插件放进插件开发技能（Go 版本见 `plugin-ipc-http.md` §9 的 `exec` 运行时）。
- 网页侧栏给插件会话加来源标记与筛选（接口已返回 `owner`）。
