# 清单、打包、权限与版本

服务器的权威校验在 `$SRC/movieclaw_api/plugins/packages.py`（`Manifest`、`read_archive`、`check_compat`），
`scripts/check_plugin.py` 直接调用它们。

## 1. 目录结构

```
plugins/media-stats/
├── movieclaw-plugin.toml      ← 清单（必须在根部）
├── media_stats.py             ← 入口模块（或 media_stats/__init__.py 的包）
├── media_stats_helpers.py     ← 其他模块随意
└── vendor/                    ← 依赖（可选）：纯 Python 包原样放进来，运行时自动加进 sys.path
```

打包（`mclaw plugin pack`）跳过 `__pycache__`、`.git`、隐藏文件、`*.pyc`、旧的 `*.mcplugin`；**软链接直接拒绝**。
上限：压缩包 50 MB、解包 200 MB、5000 个文件。

## 2. 清单字段

```toml
[plugin]
id = "media-stats"          # 必填。小写字母开头，字母、数字、连字符，不含点；= @plugin 的名字
title = "媒体统计"              # 必填。1～60 字，管理页显示
version = "0.1.0"              # 必填。主.次.修订，可带 -后缀（开发循环自动加 -dev.<时间戳>）
entry = "media_stats"          # 必填。入口模块名（不是路径，不带 .py）
runtime = "process"            # process（默认）| inline（需单独批准）
sdk = "^1.0"                   # 要求的 movieclaw_sdk 版本区间
description = "一句话说明"       # 可选，500 字以内

[requires]                     # 用到的契约 = 版本区间；名字见 scripts/contracts.py
"library.ingest.imported" = "^1.0"
"subscription.candidates.filter" = "^1.0"

[permissions]
operations = ["library.list", "subscriptions.get"]       # 宿主操作 id
paths = [{ path = "staging", mode = "read" }]            # 路径授权，mode = read | rw
network = true                                           # 需要直连外网（仅声明）
callbacks = ["push"]                                     # 要开放的回调端点名（外部平台调进来的地址，见 recipes 第 14 节）
```

清单不允许出现未知字段（写错字段名会被拒）。

## 3. 版本区间写法

只有一种写法：`^主.次`（`^` 可省略）= 主版本相同、次版本不低于。`^1.0` 接受 1.0、1.3，不接受 2.0。
**不支持** `>=1.0,<2` 这类写法。契约主版本变了 = 不兼容，插件需要更新。

## 4. 宿主操作

- 操作 id 与 `mclaw` 命令一一对应：`mclaw subscriptions create` ↔ `subscriptions.create`，
  `mclaw library items delete` ↔ `library.items.delete`。用 `mclaw <域> --help` 找，`mclaw <域> <命令> --help` 看参数。
- 调用参数：`ops.call("<id>", {...})` 的字典 = 该操作的路径参数 + 查询参数 + 请求体字段；
  请求体可选的操作把整个请求体放在 `"body"` 键下（例：`ops.call("library.scan.start", {"library_id": 1, "body": {"paths": [...]}})`）。
  拿不准时先用 `mclaw <命令> --help` 对照，必要时让插件把 `OpsError.details` 记进日志。
- 危险操作必须逐个列出；支持演练的危险操作（参数里有 `dry_run`）开发时先演练。
- 批准时授予的是**清单**里的列表；`@plugin(permissions=...)` 保持与清单一致（诊断页显示它）。

## 5. 路径授权

| `path` 写法 | 含义 |
|---|---|
| `/mnt/cloud/movieclaw` | 绝对路径（及其子目录） |
| `staging` | 导入规则里配置的全部自定义（暂存）目录 |
| `library` | 全部媒体库根目录；`library:<id>` 只批一个库 |

插件自己的私有目录不用申请：`files.path("plugin", "子路径")`。

## 6. 安装、升级、回滚、卸载

| 动作 | 命令（mclaw 工具的参数） | 说明 |
|---|---|---|
| 开发安装 | `plugin dev <目录> --once` | 打包（版本加 `-dev.<时间戳>`）→ 上传 → 按清单批准 → 加载；失败时服务器回到上一版并说明原因 |
| 打包 | `plugin pack <目录>` | 生成 `<id>-<版本>.mcplugin` |
| 上传 | `app plugins packages upload --file <包>` | 校验后进入「待批准」，返回申请的权限 |
| 批准 | `app plugins packages approve <id> --version <版本> --operations-json '[...]' --paths-json '[...]' --yes` | 批准的列表须与申请**完全一致**；inline 还要 `--allow-inline` |
| 放弃待批准 | `app plugins packages discard <id> --yes` | |
| 查看 | `app plugins packages list`、`app plugins list` | 后者是诊断：每个条目的状态、失败原因、启动耗时 |
| 回滚 | `app plugins packages rollback <id> --yes` | 回到上一版 |
| 卸载 | `app plugins packages uninstall <id> --yes` | 默认保留插件数据；加 `--purge-data` 连同数据删除 |

同一版本不能重复安装：正式发布时每次改动都要升 `version`（开发循环自动处理）。
网页「设置 → 插件 → 已安装」也能看到并操作这些插件包。
