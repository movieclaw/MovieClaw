# 组合与拆分：一个插件里放多少东西

## 1. 一个插件可以同时用很多扩展点

`apply` 里想登记多少就登记多少：钩子、可靠事件、多个注册表、路由、后台任务都可以混用。

```python
@plugin("all-in-one", title="…", inject=(DURABLE_EVENTS, HOST_OPS, PLUGIN_ROUTES, PLUGIN_DATA))
async def apply(ctx):
    ctx.on(CANDIDATES_FILTER, my_filter)                         # 钩子
    ctx.on(LIBRARY_INGEST_IMPORTED, on_imported, id="imported")  # 可靠事件
    ctx.contribute(IM_CHANNELS, "wecom", WecomDriver())          # 注册表
    ctx.contribute(SCHEDULED_TASKS, "sync", TaskDefinition(…))   # 另一个注册表
    routes.mount(ctx, router)                                    # 接口
    ctx.task(poll(), name="poll")                                # 后台循环
```

现成的组合：

| 示例 | 组合了什么 |
|---|---|
| `examples/keyword_rules.py` | 2 个钩子（淘汰候选 + 追加搜索词）+ 1 个可靠事件（订阅删除时清理）+ 插件数据（规则挂在订阅上） |
| `examples/cloud_strm.py` | 后台任务处理器 + 入库流水线步骤 + 公开区路由与签名链接 + 文件接口 + 宿主操作 |
| `examples/delete_cascade.py` | 2 个可靠事件 + 宿主操作（含危险操作与演练） |

**规则**

- 清单要写全：用到的每个事件 / 钩子 / 注册表进 `[requires]`，要调的每个操作进 `permissions.operations`；
  用户批准时看到的是这些的合集。
- 一个插件包只加载一个插件：入口模块里名字等于清单 id 的那个 `@plugin`。要做很多事就都写在它的 `apply` 里，
  代码可以拆成多个模块。
- 同生同死：`apply` 任何一处抛错，整个插件启动失败、已登记的全部撤销；升级、回滚、卸载也是整体的。

## 2. 什么时候拆成多个插件

一个插件 = 一件用户能说清楚的事。这件事要用到多少扩展点就用多少；不相干的事分开。

| 放在一起 | 拆开 |
|---|---|
| 为同一个目的配合工作（关键字规则的钩子与清理事件，拆开就不完整） | 互不相关（「企业微信通道」和「删片联动」，用户可能只要其一） |
| 共用同一份数据或配置 | 要的权限差得多（一个只读，一个要删种子）：合在一起，用户为了只读的部分也得授权删种子 |
| | 稳定性差得多：常改的实验功能不该拖着稳定功能一起回滚 |

拿不准时问用户：「这两件事你会不会只想要其中一个？」

## 3. 替换内置的东西

| 想替换 | 做法 | 卸载后 |
|---|---|---|
| 整个随带插件包（微信、Telegram、Discord、飞书通道） | 做一个**同 id** 的插件包（如 `weixin-channel`）装上：内置版本被卸下，已绑定的账号直接由新包接管 | 内置版本自动回来 |
| 注册表里的某一项（如内置的订阅缺口搜索 `search_wanted`、某个站点类） | `ctx.contribute(KEY, "<原 id>", 新实现, override=True)` | 内置实现自动恢复 |
| 内置站点的配置 | 站点数据包里放同 site_id 的 YAML | 恢复内置配置 |

内置插件（`$SRC/movieclaw_api/plugins/` 里的）不能被同 id 的插件包替换，id 是保留的。
怎么分：`mclaw app plugins list` 里随带插件包（能替换）的 `tier` 是 `official`（`weixin-channel` 等通道和 `channels.hub`），
内置插件是 `system`；两者的 `source` 都显示 `builtin`，别按 `source` 判断。
替换随带通道时把 `$SRC/movieclaw_plugins/<名>/` 整个复制到 `plugins/channel.<名>/` 再改：随带包是受信代码，
写法不一定合第三方规范，复制后补上清单的 `network = true`、连外网改走 `net.http_transport`，再跑 `check_plugin.py`。

## 4. 多个插件之间怎么配合

- 插件之间不直接 import 对方，也不直接调用对方。需要协作时经系统：一个插件通过宿主操作改了数据，
  另一个插件经可靠事件收到。
- 插件 A 开的接口，插件 B 目前不能经宿主操作调用（插件路由不进宿主操作目录）。
- 可靠事件的载荷里有「谁触发的」：`ctx.delivery.origin.is_plugin(ctx.entry_id)` 为真说明是自己引起的，按需跳过，避免死循环。
