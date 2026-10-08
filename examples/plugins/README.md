# 示例插件

这里的插件是插件体系第二阶段 A 的验收插件（`docs/design/plugin-phase2a.md` §7），也是写本地插件的样板。
CI 里 `tests/api/test_example_plugins.py` 会把它们装进临时数据目录，用真实应用跑完用户场景。

| 文件 | 场景 | 用到的能力 |
|---|---|---|
| `delete_cascade.py` | 删片联动：删了片子，顺手删订阅和下载器任务 | 可靠事件 `library.item.deleted` / `library.file.deleted`、宿主操作 `subscriptions.delete`、`dl.torrent.delete`（含演练） |
| `watchlist_feed.py` | 片单订阅：外部片单里新出现的片名自动订阅 | 后台任务、宿主操作 `search.titles`、`subscriptions.create` |

## 装到自己的 MovieClaw 上

1. 把插件文件复制到数据目录的 `plugins/` 下（Docker 部署即数据卷里的 `plugins/`）。
2. 在数据目录的 `plugins.yaml` 里显式开启，并批准它要调用的操作：

   ```yaml
   - id: examples.delete-cascade
     local: true
     config: { delete_files: true, dry_run: true }   # 先演练，看日志确认无误再关掉 dry_run
     grants: [subscriptions.delete, dl.torrent.delete]
   ```

3. 重启。设置 → 更新与维护 →「模块」里能看到它，标着「本地插件」。

本地插件在应用进程里运行，拥有与主程序相同的系统权限——只开启你信任的代码。
不在 `plugins.yaml` 里开启的文件不会被执行；要关掉，去掉 `local: true` 或加上 `disabled: true` 再重启。

## 自己写一个

```python
from movieclaw_api.domain_events import LIBRARY_INGEST_IMPORTED, IngestImported
from movieclaw_api.plugins.keys import HOST_OPS
from movieclaw_kernel import DURABLE_EVENTS, plugin


@plugin(
    "me.after-import",                      # 条目 id，与 plugins.yaml 里的 id 一致
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
