# 示例插件

这里的插件是插件体系第二阶段的验收插件（`docs/design/plugin-phase2a.md` §7、`plugin-phase2b.md` §10），也是写本地插件的样板。
CI 里 `tests/api/test_example_plugins*.py` 会把它们装进临时数据目录，用真实应用跑完用户场景。

| 文件 | 场景 | 用到的能力 |
|---|---|---|
| `delete_cascade.py` | 删片联动：删了片子，顺手删订阅和下载器任务 | 可靠事件 `library.item.deleted` / `library.file.deleted`、宿主操作 `subscriptions.delete`、`dl.torrent.delete`（含演练） |
| `watchlist_feed.py` | 片单订阅：外部片单里新出现的片名自动订阅 | 后台任务、宿主操作 `search.titles`、`subscriptions.create` |
| `keyword_rules.py` | 关键字规则：给订阅加「必须包含 / 排除」关键字与额外搜索词 | 决策钩子 `subscription.candidates.filter` / `subscription.search.keywords`、插件数据（订阅扩展字段）、可靠事件 `subscription.deleted` |
| `cloud_strm.py` | 网盘上传：入库暂存后传到网盘，媒体库里放指向插件的签名 `.strm` | 流水线槽位 `ingest.staged`、任务处理器（断点续传、进度、重试 / 阻塞）、插件路由（验签公开区）与签名链接、宿主操作 `library.get`、`library.scan.start` |
| `site_pack/` | 站点数据包：把一组自己适配的站点 YAML 打成插件分发 | 站点数据包注册表 `site-data-packs`（包形式的本地插件） |
| `ntfy-channel/` | 第三方 IM 通道：在 ntfy App 里和 MovieClaw 对话、接收推送 | 通道注册表 `im-channels`（`movieclaw_sdk.channels`，见 `docs/design/plugin-channels.md`）；带清单，可直接 `mclaw plugin pack` 成插件包 |
| `wecom-channel/` | 回调式 IM 通道：企业微信自建应用，平台把加密消息推到回调地址 | 通道驱动的 `webhook`（`Capabilities(webhook=True)`）、清单 `callbacks = ["webhook"]`、企业微信验签与 AES 解密、应用消息接口发回复、配对码绑定；带清单，可直接打包 |

## 装到自己的 MovieClaw 上

1. 把插件文件（或 `site_pack/` 这样的整个目录）复制到数据目录的 `plugins/` 下（Docker 部署即数据卷里的 `plugins/`）。
2. 在数据目录的 `plugins.yaml` 里显式开启，并批准它要调用的操作：

   ```yaml
   - id: delete-cascade
     local: true
     config: { delete_files: true, dry_run: true }   # 先演练，看日志确认无误再关掉 dry_run
     grants: [subscriptions.delete, dl.torrent.delete]
   ```

3. 重启。设置 → 更新与维护 →「模块」里能看到它，标着「本地插件」。

插件读写文件一律经文件接口（`PLUGIN_FILES`），只能碰 `paths` 里批准过的目录（`docs/design/plugin-phase3.md` §6.2）：

```yaml
   paths:
     - { path: /mnt/cloud/movieclaw, mode: rw }   # 绝对路径
     - { path: staging, mode: rw }               # 导入规则的自定义目录
     - { path: library, mode: read }             # 全部媒体库根目录（library:<id> 只批一个库）
```

插件自己的目录（`files.path("plugin", ...)`）总是可读写；持久状态更推荐存插件数据（`PLUGIN_DATA`）。

本地插件默认在应用进程里运行，拥有与主程序相同的系统权限——只开启你信任的代码。
加上 `runtime: process` 改为在独立进程里运行（`docs/design/plugin-phase3.md` §4）：插件崩溃、卡死只伤它自己，
主进程按退避自动重启它；子进程拿不到主密钥、数据库地址等环境变量。进程外已支持事件与决策钩子、
可靠事件、宿主操作、插件数据、健康上报，以及往任务处理器、入库槽位、站点数据包贡献、插件路由与签名链接
——这里全部示例都能直接这样跑。
不在 `plugins.yaml` 里开启的文件不会被执行；要关掉，去掉 `local: true` 或加上 `disabled: true` 再重启。

## 自己写一个

```python
from movieclaw_api.domain_events import LIBRARY_INGEST_IMPORTED, IngestImported
from movieclaw_api.plugins.keys import HOST_OPS
from movieclaw_kernel import DURABLE_EVENTS, plugin


@plugin(
    "after-import",                      # 条目 id，与 plugins.yaml 里的 id 一致
    title="入库后做点什么",
    inject=(DURABLE_EVENTS, HOST_OPS),      # 只能用实验级以上的契约
    permissions=("library.scan.start",),    # 需要的宿主操作；危险操作必须逐个列出
)
async def after_import(ctx):
    ops = await ctx.use(HOST_OPS).client(ctx)

    async def on_imported(event: IngestImported) -> None:
        # 可靠事件至少投递一次：用 ctx.delivery.event_id 去重
        ctx.logger.info("《%s》入库了 %d 个文件", event.media.title, len(event.files))

    ctx.on(LIBRARY_INGEST_IMPORTED, on_imported, id="after-import")  # 稳定 id 决定跨重启的进度
```

可订阅的事件见 `src/movieclaw_api/domain_events.py`；可调用的操作就是 `mclaw` 命令行能用的那些（同一份 OpenAPI 目录），
操作 id 与命令一一对应，例如 `mclaw subscriptions create` ↔ `subscriptions.create`。

## 打包与开发循环（第三方插件包）

插件包是一个目录加一份清单 `movieclaw-plugin.toml`（格式见 `docs/design/plugin-phase3.md` §2）：

```toml
[plugin]
id = "group-blocklist"
title = "发布组黑名单"
version = "0.1.0"
entry = "group_blocklist"      # group_blocklist.py 或 group_blocklist/__init__.py
runtime = "process"            # 默认：独立进程、非特权用户
sdk = "^1.0"

[requires]
"subscription.candidates.filter" = "^1.0"

[permissions]
operations = ["search.titles"]
paths = [{ path = "staging", mode = "read" }]
```

依赖放进 `vendor/`（安装时不联网）。然后：

```bash
mclaw plugin pack ./group-blocklist          # 打成 group-blocklist-0.1.0.mcplugin
mclaw plugin dev  ./group-blocklist          # 连到服务器：一改就重新打包、上传、批准、加载
mclaw app plugins packages upload --file group-blocklist-0.1.0.mcplugin   # 正式安装
mclaw app plugins packages approve group-blocklist --version 0.1.0 \
    --operations-json '["search.titles"]' \
    --paths-json '[{"path": "staging", "mode": "read"}]' --yes   # 批准须与申请完全一致
```

能用哪些契约、它们的载荷长什么样：`python -m movieclaw_sdk.surface`（与 `src/movieclaw_sdk/surface.json` 相同）。

## 写一个 IM 通道插件

通道插件只管一个平台「怎么收、怎么发、怎么绑定」，往注册表 `im-channels` 贡献一个 `ChannelDriver`（`movieclaw_sdk.channels`）；
白名单、会话、AI 助手、长消息拆分、推送、账号存储、设置页都由 MovieClaw 的通道中枢负责。最小骨架见 `ntfy-channel/ntfy_channel.py`：

- `binding`：`Binding.form(字段…)` 表单绑定（`pairing="code"` 时由中枢生成 6 位配对码，适合 Telegram 这类 bot），
  或 `Binding.flow()` 交互式绑定（自己实现 `begin_flow` / `flow_state` / `flow_input`，比如扫码）；
- `validate(fields)` 校验表单、返回账号 id、展示名与凭据（凭据由中枢加密保存，启动账号时交还给你）；
- `run(account)` 收消息循环：归一化后 `await account.inbound(InboundMessage(...))`，游标等私有状态用
  `await account.save_state({...})` 存，`account.stopping` 置位就退出；凭据失效抛 `ChannelAuthError`；
- `send(account, reply, text)` 发一条文本（中枢已按 `capabilities.max_text_len` 拆好）。

- 连外网要按用户的代理设置走：`httpx.AsyncClient(transport=net.http_transport("<服务名>"))`（`movieclaw_sdk.net`；服务名 = 条目 id，如 `ntfy-channel`）；
  已有「客户端 + 适配器」代码的，可以直接继承 SDK 的 `AdapterDriver`。

同一份代码当本地插件（主进程里运行）或插件包（独立进程里运行）都能用，绑定后出现在「设置 → IM 推送」。
内置的微信 / Telegram / Discord / 飞书也是这样写的插件包，见 `src/movieclaw_plugins/`。

