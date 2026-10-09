# 排查

先跑 `python <本技能>/scripts/check_plugin.py <插件目录>`，它能在安装前发现大部分问题。
安装后的问题按下面的顺序看：

1. `mclaw app plugins packages list`：包装上了没有、当前是哪个版本、有没有卡在「待批准」；
2. `mclaw app plugins list`：找到条目 id，看 `state`（`active` 才是在跑）和 `error`。输出很长会被截断，
   按 SKILL.md 第 3 节第 8 步的写法从完整输出文件里筛（第三方插件包 `source` 是 `package`）；
3. 日志：用 bash grep 运行日志目录（系统提示词里给了路径）的当天文件，找条目 id：
   `grep -n '<条目 id>' <日志目录>/movieclaw-$(date +%F).log | tail -50`；进程外插件的日志也汇总在这里。

- 顺便看 `app plugins list` 输出顶层的 `safe_mode`：`active` 为真说明进了安全模式，第三方插件都没加载（`skipped` 列出跳过的）。
- 用户没说是哪个插件、或代码不在工作区：先按上面三步查服务器上的状态（日志里没有 id 可搜时，搜「插件包」「没能正常运行」「已撤销安装」「安全模式」），
  再请用户贴报错原文或代码，或说出插件名。
- 包列表里没有、状态表里也没有：要么上传就被拒了（服务器不留记录，报错只在上传那一刻返回），要么第一次安装就没起来、
  已被撤销——日志里会有「插件包 <id>：v<版本> 没能正常运行（原因），已撤销安装」。

## 安装 / 上传阶段

| 现象 | 原因与处理 |
|---|---|
| `movieclaw-plugin.toml 的 plugin.id 不合规` | id 须小写带命名空间，如 `me.hello` |
| `… 的 xxx 不合规：Extra inputs are not permitted` | 清单里有未知字段（拼错了），对照 `references/manifest.md` |
| `插件包里找不到入口模块` | `entry` 写的是模块名，文件须是 `<entry>.py` 或 `<entry>/__init__.py`，在包根部 |
| `宿主操作 xxx 不存在` | 操作 id 写错；用 `mclaw <域> --help` 找对应命令，id 与命令一一对应 |
| `宿主操作领域 xxx.* 不存在` | 领域名写错 |
| `契约不兼容：未知契约 xxx` / `仅供内置插件使用` | `[requires]` 写了不存在或内部的契约；只能用 `scripts/contracts.py` 列出的 |
| `插件要求 SDK …` | `sdk` 写成了服务器不满足的版本，一般写 `^1.0` |
| `条目 id … 已被内置插件或本地插件占用` | 换一个 id |
| `… v<版本> 已经安装` | 同一版本不能重复安装：升 `version`；开发循环 `plugin dev --once` 会自动加后缀 |
| `批准的宿主操作须与插件申请的完全一致` / `批准的路径授权须与插件申请的完全一致` | `approve` 的 `--operations-json` / `--paths-json` 要和上传返回的申请完全一致 |
| `这个插件申请在主进程里运行…须单独确认` | `runtime = "inline"`：改回 `process`。只有用户自己明确要求进程内运行时才加 `--allow-inline` |
| `plugin dev` 一直不返回 | 没带 `--once`，它在监视文件；中断后带上 `--once` 重来 |
| `unknown command "plugin"` | 服务器上的 mclaw 太旧，没有开发者命令：改用 `plugin pack` 的等价做法——把目录打成 zip（清单在根部）后 `app plugins packages upload --file`；或请用户升级 MovieClaw |

## 加载阶段（批准后没有变成 active，服务器已回到上一版）

| 错误信息 | 原因与处理 |
|---|---|
| `模块 … 里没有名为 <id> 的插件` | `@plugin("<id>")` 的名字与清单 id 不一致，或 `@plugin` 不在入口模块顶层（不能只在子模块里定义而不导入） |
| `ModuleNotFoundError` | 依赖没放进 `vendor/`，或用了主程序没有的库；只能用标准库、主程序已有的库（如 `httpx`、`pydantic`、`fastapi`）和 `vendor/` |
| `没有在 inject 中声明服务 xxx` | `ctx.use(KEY)` 的服务要写进 `@plugin(inject=(KEY,))` |
| `inject 只能写服务键，xxx 不是服务` | 把注册表 / 事件写进了 inject：注册表用 `ctx.contribute`、事件用 `ctx.on`，从 inject 里删掉 |
| `进程外插件暂不能使用服务：xxx` | xxx 不是开放给第三方的服务，**或者是注册表被误写进了 inject**（如 `im-channels`）。改代码；**不要因此改成 inline**，开放的扩展点在独立进程里都能用 |
| `激活后状态为 pending` / `一直在等服务：xxx（没有插件提供）` | inject 里写了一个没人提供的「服务」，几乎都是把注册表写进了 inject；同上处理 |
| `PermissionError: … 仅供内置插件使用` | 用了内部服务 / 事件，换成开放契约 |
| `可靠事件 … 的监听器必须有稳定 id` | `ctx.on(EVENT, fn, id="…")` |
| 启动超时 | `apply` 里做了耗时工作；挪进 `ctx.task(...)` |
| 路由相关的类型解析错误 | 端点用到的类型要在模块顶层导入；去掉入口模块的 `from __future__ import annotations` 或把类型提到顶层 |
| 挂路由时报 operationId 前缀不对 | 路由的 `operation_id` 必须以 `plugins.<条目 id>.` 开头 |

## 运行阶段

| 现象 | 排查 |
|---|---|
| 事件监听没反应 | 事件真的发生了吗（入库、删除要真实走一遍）；清单 `[requires]`、`inject=(DURABLE_EVENTS,)` 写了吗；看死信 `mclaw app plugins dead-letters …` |
| 钩子没生效 | 钩子抛错 / 超时 / 返回类型不对会被当作不存在、连续失败会熔断，看日志里的熔断提示；返回值类型必须与契约一致 |
| 宿主操作报权限错误 | 清单 `permissions.operations` 没申请，或用了 `领域.*` 却调用了危险操作（须逐个列出） |
| 读写文件 `PermissionError` | 路径没在清单 `permissions.paths` 里申请；私有目录用 `files.path("plugin", …)` |
| 连不上外网 | 没走 `net.http_transport`；或用户的代理规则没覆盖到 |
| 插件反复崩溃后所有第三方插件都没加载 | 进入了安全模式：修好插件后 `mclaw app plugins safe-mode exit` |
| 改了代码重装，行为还是旧的 | 旧版本服务器上，进程内（inline）运行的包会沿用第一次导入的代码。用默认的独立进程运行就没有这个问题；**不要为此重启应用**，告诉用户 |
| `mclaw plugins …` 提示 unknown command | 命令目录还没刷新：先执行一条 mclaw 业务命令（如 `app plugins list`），看到「服务器接口目录已更新」再调；命令由 `operation_id` 按点拆分而来 |

## 回到干净状态

- 回滚到上一版：`app plugins packages rollback <id> --yes`
- 卸载：`app plugins packages uninstall <id> --yes`（插件数据默认保留，重装后还在）
- 放弃待批准的包：`app plugins packages discard <id> --yes`
