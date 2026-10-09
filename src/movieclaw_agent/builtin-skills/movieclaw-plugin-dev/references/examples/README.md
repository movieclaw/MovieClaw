# 示例插件（经过 CI 端到端测试的真实代码）

这些是插件体系的验收插件，原件在仓库 `examples/plugins/`，这里原样复制一份供参考。

| 文件 | 场景 | 学什么 |
|---|---|---|
| `delete_cascade.py` | 删了片子，顺手删订阅和下载器任务 | 可靠事件、宿主操作（含危险操作与演练）、忽略自己引起的事件 |
| `watchlist_feed.py` | 外部片单里新出现的片名自动订阅 | 后台循环、宿主操作、`OpsError` 处理、插件数据去重 |
| `keyword_rules.py` | 给订阅加「必须包含 / 排除」关键字与额外搜索词 | waterfall 钩子、实体作用域的插件数据、订阅删除时清理 |
| `cloud_strm.py` | 入库暂存后传到网盘，媒体库里放签名 `.strm` | 持久化任务、入库流水线槽位、插件路由公开区与签名链接、文件接口 |
| `ntfy-channel/` | 第三方 IM 通道 | 完整插件包（带清单）、`movieclaw_sdk.channels` |
| `site_pack/` | 一组站点 YAML 打成插件 | 站点数据包注册表 |

**注意它们和你要写的插件包的差别**：除 `ntfy-channel/` 外，这些示例是按「本地插件」写的——

- 没有 `movieclaw-plugin.toml`，配置写在用户的 `data/plugins.yaml`（`config:` 一节），所以有必填的 `Config` 字段；
- `from movieclaw_kernel import plugin`（与 `movieclaw_sdk.plugin` 是同一个东西，插件包里统一用后者）。

照着写插件包时：补一份清单（`id` = `@plugin` 名字，`permissions.operations` = `@plugin(permissions=...)`，
用到的事件 / 钩子写进 `[requires]`），并且**配置模型的每个字段都要有默认值**（插件包目前没有用户可改的配置）。
