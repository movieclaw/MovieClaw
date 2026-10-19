# 清单、打包、权限与版本

服务器的权威校验在 `$SRC/movieclaw_api/plugins/packages.py`（`Manifest`、`read_archive`、`check_compat`），
`scripts/check_plugin.py` 直接调用它们。

## 1. 目录结构

```
plugins/media-stats/
├── movieclaw-plugin.toml      ← 清单（必须在根部）
├── media_stats.py             ← 入口模块（或 media_stats/__init__.py 的包）
├── media_stats_helpers.py     ← 其他模块随意
├── web/                       ← 插件网页（可选）：index.html 是入口，manifest.webmanifest 定侧边栏，见 web-pages.md
├── vendor/                    ← 依赖（可选）：纯 Python 包原样放进来，运行时自动加进 sys.path
├── requirements.in            ← 第三方依赖（可选）：每行一个直接依赖，如 p115cipher[full]
└── requirements.lock          ← 由它生成的锁文件，清单 [dependencies] lock 指向它
```

打包（`mclaw plugin pack`）跳过 `__pycache__`、`.git`、`.venv`、`node_modules`、点开头的目录、`*.pyc`、旧的 `*.mcplugin`、`.DS_Store`；**软链接直接拒绝**。
上限：压缩包 50 MB、解包 200 MB、5000 个文件。

作者、主页、许可证、图标不要写进清单（未知字段会被拒）。这些写在插件目录的 `store.json` 里，只给
<https://github.com/movieclaw/movieclaw-plugins> 的索引用（见该仓库 `example/GUIDE.md`）。打进 `.mcplugin` 会被解出并忽略，服务器不读它。

## 2. 清单字段

```toml
[plugin]
id = "media-stats"          # 必填。小写字母开头，字母、数字、连字符，不含点；= @plugin 的名字
title = "媒体统计"              # 必填。1～60 字，管理页显示
version = "0.1.0"              # 必填。主.次.修订，可带 -后缀（开发循环自动加 -dev.<时间戳>）
entry = "media_stats"          # 必填（只带网页的插件不写）。入口模块名（不是路径，不带 .py）
runtime = "process"            # process（默认）| inline（需单独批准）| exec（非 Python 插件，见下）
sdk = "^1.0"                   # 要求的 movieclaw_sdk 版本区间
description = "一句话说明"       # 可选，500 字以内；展示在「设置 → 插件」详情页给用户看，写它能做什么，别写文档路径、开发备注

[requires]                     # 用到的契约 = 版本区间；名字见 scripts/contracts.py
"library.ingest.completed" = "^1.0"
"subscription.candidates.filter" = "^1.0"

[permissions]
operations = ["library.list", "subscriptions.get"]       # 宿主操作 id
paths = [{ path = "staging", mode = "read" }]            # 路径授权，mode = read | rw
network = true                                           # 需要直连外网（仅声明）
callbacks = ["push"]                                     # 要开放的回调端点名（外部平台调进来的地址，见 recipes 第 14 节）
events = ["playback.*"]                                  # 要订阅的敏感事件（谁在什么时候看了什么）：用户单独批准

[dependencies]                 # 可选：第三方依赖（只给 runtime = "process"），见下文「第三方依赖」
lock = "requirements.lock"

[[events]]                     # 插件自己会发的事件（recipes 第 17 节）：名字以插件 id 开头
name = "media-stats.weekly-report"
title = "周报生成了"

[[notifications]]              # 事件对应的通知：经用户批准后由宿主推到手机和 IM
event = "media-stats.weekly-report"
title = "本周看了 {hours} 小时"  # {字段} 换成事件载荷里的值（{media.title} 这样取嵌套字段）
body = "最常看的是《{top_title}》"
audience = "admins"            # admins | member:<字段> | media:<字段>；<字段> 是事件载荷里的字段名（嵌套用 a.b）：
                               #   member: 那个字段的值是成员 id（整数）；media: 那个字段的值是片 {id, kind, title}
                               #   （Python 插件用 MediaRef），推给订阅或关注了这部片的人
level = "active"               # active（响）| passive（安静送达）
default = true                 # 每个人的开关默认开不开
open = "plugin"                # 点开去哪：plugin（插件页）| media（载荷里那部片的条目页）
```

清单不允许出现未知字段（写错字段名会被拒）。会通知到普通成员的（`member:` / `media:`）批准时要单独勾选；
通知上会标「来自 插件名」。


**只带网页的插件**：不写 `entry`，包里有 `web/index.html` 即可（`new_plugin.py --web` 生成），没有后端进程。
批准时要单独同意网页授信运行（`plugin dev … --allow-web`），见 `web-pages.md`。

**非 Python 插件**（Go、Rust 等，`runtime = "exec"`）：不写 `entry`，改写包里的可执行文件和它支持的平台。
宿主先经可信启动器降权，再执行它；协议见 `$SRC/movieclaw_sdk/protocol/`（`gateway.json`、`control.json`），
完整示例是 `examples/go-a2a-bridge/`（用 Go 写的 A2A 桥，驱动 AI 助手）。

```toml
[plugin]
id = "go-a2a-bridge"
title = "A2A 桥（Go）"
version = "0.1.0"
runtime = "exec"
command = "bin/bridge"                        # 包内可执行文件（打包前编好，按服务器平台编译）
platforms = ["linux/amd64", "linux/arm64"]    # 必填；与服务器平台不符的包装不上
```

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
| 卸载 | `app plugins packages uninstall <id> --yes` | 默认保留插件数据；`--purge-data` 只删 `plugin_data` 里该 id 的行，不删设置文件和私有目录 |

同一版本不能重复安装：正式发布时每次改动都要升 `version`（开发循环自动处理）。
网页「设置 → 插件 → 已安装」也能看到并操作这些插件包。

## 第三方依赖（`[dependencies]`）

带本机代码的包（pycryptodome、lz4……）放不进 `vendor/`，在清单里声明锁文件，管理员批准安装时由服务器下载
（设计：`docs/design/plugin-dependencies.md`）。选依赖先看**轮子里的 LICENSE**：PyPI 页面写的许可证不一定准
（如 p115cipher 页面写 MIT，轮子里是 GPLv3），带 GPL 的要在插件 README 里讲清，并告诉用户。

1. 把直接依赖写进插件目录的 `requirements.in`（每行一个）；
2. `python scripts/check_plugin.py plugins/<目录> --lock`：按主程序的 `host-constraints.txt`（最新服务器版本的 Release 附件；
   也可 `python -m movieclaw_sdk.deps lock <目录> --constraints <文件或网址>`）解析出完整闭包，写成锁文件再检查；
3. 锁文件规则（服务器上传时同样校验，不合规直接拒）：全部 `==` 钉死、每个包带 `--hash=sha256:`、只接受轮子（没有轮子的包
   用户机器上不编译）、**不能与主程序已有的包重名**（`httpx`、`cryptography` 等直接用主程序的）、不写环境标记与附加依赖；
4. 检查结果里「没有 linux/arm64 的轮子」是告警：装到那个平台会失败，换个有两种平台轮子的版本最好。

只有 `runtime = "process"` 的插件能带依赖。依赖目录排在主程序与 `vendor/` 之后加进 `sys.path`，包里的 `.pth` 不会执行。
下载走「设置 → 网络」的包索引地址（默认 PyPI，可一键换清华镜像）与「插件依赖下载」代理开关；把轮子放进插件目录的
`wheels/`（受包体积上限约束）则安装时不联网。
