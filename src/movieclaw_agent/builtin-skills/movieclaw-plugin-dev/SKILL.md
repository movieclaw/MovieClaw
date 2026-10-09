---
name: movieclaw-plugin-dev
description: 用户想让 MovieClaw 拥有它现在没有的能力或对接时使用，不管用户有没有说「插件」。典型说法：「做一个企业微信 / 钉钉 / Slack / Bark 通道」「接入某某平台」「能不能支持某某站点」「下载完 / 入库后 / 删片后自动做某事」「订阅只要某字幕组」「定时去拉某个片单」「给外部系统开个接口」。这类需求在 MovieClaw 里靠写插件（.mcplugin）实现，本技能覆盖从判断、开发、打包、安装、验证到卸载的全过程；也用于升级、回滚、排查已装的插件。
---

# MovieClaw 插件开发

你要帮用户写一个 MovieClaw 插件，并在这台服务器上把它装起来、验证、必要时卸载。
插件是一个目录：一份清单 `movieclaw-plugin.toml` + Python 代码，打包成 `.mcplugin`（zip）后安装。
装上后默认在**独立的低权限进程**里运行，崩溃只伤它自己；装、升级、回滚、卸载都**不用重启**。

本文件是判断、流程与规范，**读完再动手**；第 2 节告诉你动手前还必须读哪份参考（路径以本技能目录为锚）。

## 0. 先判断：要不要写插件、做不做得到

用户说「做一个 / 接入 / 支持 / 能不能自动……」时，先用 `mclaw` 确认系统里确实没有（如 `mclaw channels list`
看已有通道、`mclaw site --help` 看站点），没有就是要写插件，按本技能走；不要只回答「目前不支持」。

- 用户只是想「做一次某件事」（建订阅、删种子、扫媒体库）→ 直接用 `mclaw` 工具，不要写插件。
- 想要的效果已有设置项（订阅规则组、命名模板、推送开关）→ 用设置，不要写插件。
- 需要**持续自动**地响应系统里发生的事、改变系统的决策、给系统加一种新实现，或给外部系统开一个接口 → 写插件。

**能力地图**（逐项清单见 `references/extension-points.md`）：

| 插件能做 | 靠什么 |
|---|---|
| 某件事发生后自动做点什么：下载完成、入库完成、删片 / 删文件 / 回收站、订阅新建 / 删除 / 开始下载 / 收齐 / 状态变化 | 可靠事件 |
| 改变系统的判断：订阅搜索词、淘汰或重排候选种子、选下载器、否决删种 | 决策钩子 |
| 加一种新实现：IM 通道、站点类 / 站点数据包、定时任务（可整段替换内置的）、后台任务、入库流水线步骤 | 注册表 |
| 做事与存东西：调用系统操作（与 mclaw 同一份）、存状态、读写批准的目录、开接口（自动成为 mclaw 命令）、报告健康 | 服务 |

**做不到的**：给网页 / App 加界面或设置页、新的下载器类型、新的元数据来源、新的 Webhook 格式、新的站点认证方式、
替换播放 / 转码 / 媒体库扫描 / 刮削主流程 / AI 助手。**遇到要直说做不到**，并给替代办法
（`references/extension-points.md` 第 5 节），不要先答应再做到一半。

## 1. 原理速览

| 概念 | 一句话 |
|---|---|
| 插件 | 一个 `@plugin("<id>", ...)` 装饰的 `async def apply(ctx)`。`apply` 只做**登记**（监听事件、贡献注册表、挂路由、起后台任务），登记完就返回 |
| 条目 id | 全局唯一、小写带命名空间，如 `me.hello`。清单的 `id` 必须与 `@plugin` 的名字**完全一致** |
| 契约 | 插件只能用**开放契约**：服务（`ctx.use`）、注册表（`ctx.contribute`）、事件与决策钩子（`ctx.on`）。清单见 `python <本技能>/scripts/contracts.py` |
| 可撤销 | 经 `ctx` 登记的一切在卸载时自动撤销；自己开的资源用 `ctx.effect(释放函数)` 登记，后台协程一律用 `ctx.task(...)` |
| 宿主操作 | 插件「做事」= 调用和 `mclaw` 同一份操作目录（如 `subscriptions.create`），清单 `permissions.operations` 申请，用户批准后才有 |
| 运行位置 | `runtime = "process"`（默认、推荐）独立进程；`inline` 在主进程里运行，需用户单独批准，除非用户明确要求否则不用 |
| 热插拔 | 插件包安装 / 升级 / 回滚 / 卸载都在运行中完成；新版本起不来时服务器**自动回到上一版** |

**组合与拆分**：一个插件可以同时用多个钩子、事件、注册表、路由；一个插件包只加载一个插件（名字 = 清单 id），
同生同死。一个插件 = 一件用户能说清楚的事；互不相关、权限差得多、稳定性差得多的事拆成多个插件。
替换内置东西：同 id 的插件包替换随带通道；注册表里 `override=True` 加原 id 替换某一项。详见 `references/composition.md`。

## 2. 动手前必须先读

源码根目录（下文记作 `$SRC`）= 本技能目录往上三级；或运行
`python -c "import movieclaw_sdk, pathlib; print(pathlib.Path(movieclaw_sdk.__file__).parents[1])"`。

| 你要做的 | 先读（读完再写代码） |
|---|---|
| 任何插件 | `references/extension-points.md`（确认要用的契约存在、没落在「做不到」里）、`templates/starter/` |
| 事件 / 钩子类（删片联动、关键字规则、选下载器） | `references/recipes.md` 第 1～3 节，对应示例 `references/examples/{delete_cascade,keyword_rules}.py` |
| IM 通道 | `references/recipes.md` 第 11 节（**选接入方式**）、`references/examples/ntfy-channel/`、`$SRC/movieclaw_sdk/channels.py` 文件头 |
| 定时 / 后台任务、入库流水线 | `references/recipes.md` 第 6～7 节、`references/examples/{watchlist_feed,cloud_strm}.py` |
| 开接口、读写文件 | `references/recipes.md` 第 5、8 节、`references/examples/cloud_strm.py` |
| 站点 | `references/recipes.md` 第 12 节、`references/examples/site_pack/` |
| 一个插件里放好几件事、替换内置的东西 | `references/composition.md` |
| 写清单、申请权限 | `references/manifest.md` |
| 用户问「插件是什么、为什么要批准、会不会搞坏」 | `references/explaining-to-users.md` |
| 装不上、起不来、没反应 | `references/troubleshooting.md` |

## 3. 开发流程

工作目录就是 bash / mclaw 的当前目录。每个插件放在工作目录的 `plugins/<条目 id>/` 下。
**不要 `cd` 进技能目录或 `$SRC`**：脚本一律用绝对路径调用（`python <技能目录绝对路径>/scripts/xxx.py …`），
插件路径写相对工作目录的 `plugins/<id>`，否则插件会被生成进主程序源码里。
**mclaw 命令一律用 mclaw 工具执行**：bash 里没有登录令牌，在 bash 里跑 `mclaw …` 只会报未授权，
它的输出（包括配合 grep 得到的计数）不能当作验证结果。

1. **澄清需求**：触发时机（什么事发生时）、要做什么、影响哪些数据、要不要配置。说清楚你打算用哪种扩展形态
   （`references/extension-points.md`），做不到的直说并给替代办法；有歧义先问。
   **接外部平台（IM 通道、通知、外部服务）时**：MovieClaw 多半跑在家里的 NAS 上、没有公网地址，平台推不进来。
   首选服务器主动连出去的方式（长轮询、长连接——如企业微信「智能机器人」长连接模式，只要 botId + secret），
   其次是只推送的群机器人 Webhook，需要公网回调地址的方式放最后；给用户的方案里讲清「能不能对话、要不要公网地址、
   绑定要填什么」。细节见 `references/recipes.md` 第 11 节。**只做用户要求的**：觉得还该多做点什么
   （多加几个关键词、多记几个字段），作为建议提出来，用户同意再加。
2. **查契约**：`python <本技能>/scripts/contracts.py` 列出全部开放契约；`python <本技能>/scripts/contracts.py <名字>`
   看某个事件 / 钩子的载荷与返回结构。只能用列出来的契约。要调用的宿主操作用 `mclaw <域> --help` 找，
   操作 id 与命令一一对应（`mclaw subscriptions create` ↔ `subscriptions.create`）。
3. **生成骨架**：
   `python <本技能>/scripts/new_plugin.py plugins/<id> --id <id> --title "<中文标题>"`
   生成清单与入口模块，再按需求改。
4. **写代码**：遵守第 4 节规范。
5. **本地检查**：`python <本技能>/scripts/check_plugin.py plugins/<id>`。它用服务器同一套逻辑校验清单、契约、
   宿主操作，并真的导入入口模块找 `@plugin`。**有 ✗ 必须先修好**；⚠ 要逐条判断。
   **再自测判断逻辑**：把「该不该处理 / 怎么处理」写成模块顶层的纯函数（如 `verdict(title) -> 原因 | None`），
   在 bash 里 `cd plugins/<id> && python -c "from <模块> import verdict; assert …"` 跑几条**正例和反例**
   （反例 = 看着像但不该命中的，如片名里恰好含这几个字母）。钩子在热路径上、误判会直接影响下载，这步不能省。
6. **征得用户同意再安装**（第 5 节）。
7. **安装并加载**：`mclaw` 工具执行 `plugin dev plugins/<id> --once`。它会打包（版本自动加 `-dev.<时间戳>`）、
   上传、按清单申请批准、当场加载，成功打印 `✓ … 已加载`。**必须带 `--once`**，否则它会一直监视文件、卡到超时。
8. **验证**（不验证不算完成）：
   - `mclaw app plugins packages list`：插件在 `installed` 里，版本对；
   - `mclaw app plugins list`：找到条目 id（`id` 字段），`state` 应为 `active`，失败时看 `error`；
   - 调插件自己的接口：插件路由会进入 mclaw 的命令目录。装好后先随便执行一条 mclaw 业务命令（如上面的
     `app plugins list`），看到「服务器接口目录已更新」后，下一次调用起就能用了：路由的 `operation_id`
     按点拆成命令，`plugins.me.import-log.recent` → `mclaw plugins me import-log recent`（参数见 `--help`）；
   - 触发它监听的事件并观察效果。事件不能安全地人为制造时（入库、删片这类会动真实数据的），
     **不要为了验证去改动用户的数据**：确认 `app plugins list` 里它的监听器已挂上（可靠事件会显示消费者），
     并告诉用户「下次真实发生时会怎样、去哪里看结果」；
   - 日志：`mclaw logs tail --lines 300`，在输出里找插件 id 或它打的日志。**不要加 `-f`**（会一直跟随到超时）。
9. **迭代**：改代码后重复 5 → 7，每次自动是新的开发版本。
10. **正式安装**（用户要长期使用时）：清单里定好正式 `version`，然后
    `plugin pack plugins/<id>` → `app plugins packages upload --file <生成的 .mcplugin>` →
    `app plugins packages approve <id> --version <版本> --operations-json '<与清单一致>' --paths-json '<与清单一致>' --yes`。
11. **卸载**：`app plugins packages uninstall <id> --yes`（默认保留插件数据；用户要求清干净才加 `--purge-data`）。卸载后再查一次 `app plugins list`，确认条目已消失；替换内置插件的包卸载后内置版本自动回来。
    回到上一版：`app plugins packages rollback <id> --yes`。

命令参数以 `mclaw <命令> --help` 为准，报错时先看 `--help` 再重试。排查：`references/troubleshooting.md`。

## 4. 硬性规范

**必须**
- 清单 `id` = `@plugin` 名字；`entry` 是模块名（`hello.py` 或 `hello/__init__.py` 的 `hello`）。
- 用到的服务写进 `inject=(...)`，用到的事件 / 钩子 / 注册表写进清单 `[requires]`（如 `"library.ingest.imported" = "^1.0"`）。
- 要调用的宿主操作同时写进 `@plugin(permissions=...)` 和清单 `permissions.operations`；
  危险操作（`mclaw` 帮助里带 ⚠ 的）必须逐个列出，不能靠 `领域.*` 覆盖。
- 可靠事件监听器必须有稳定 `id`（`ctx.on(EVENT, fn, id="xxx")`），并按 `ctx.delivery.event_id` 幂等（至少投递一次）。
- 后台循环用 `ctx.task(coro, name=...)`，循环里捕获异常并记日志后继续，`CancelledError` 要原样抛出。
- 持久状态存插件数据（`PLUGIN_DATA`），读写文件走文件接口（`PLUGIN_FILES`）并在清单 `paths` 里申请。
- 连外网走用户的代理设置：`httpx.AsyncClient(transport=movieclaw_sdk.net.http_transport("<服务名>"))`，清单写 `network = true`。
- 依赖只能随包放进插件目录的 `vendor/`（纯 Python）；安装时不联网、不跑 pip。
- 日志用 `ctx.logger`，中文，带上关键 id。
- 按关键词匹配种子 / 发布名时：英文短词（TC、TS、CAM 这类）必须按**词边界**匹配，
  如 `re.compile(r"(?<![A-Za-z0-9])TC(?![A-Za-z0-9])", re.I)`，否则 `ts` 会命中 Hits、`cam` 会命中 Cameron；
  中文词用子串匹配即可。规则列表用元组 / 列表（保持顺序），不要用集合。

**禁止**
- 在决策钩子里产生副作用（发请求、写数据、调宿主操作）——钩子只做判断；副作用放到可靠事件或宿主操作里。
- 用内部服务（`DB`、`SECRETS`、`SETTING_STORE` 等未出现在契约清单里的）或直接 import 主程序的仓储层改数据库——
  第三方插件会被拒绝，进程外也拿不到。
- 在 `apply` 里做耗时工作（网络请求、全量扫描）：`apply` 有 30 秒上限，耗时工作放进 `ctx.task`。
- 修改 `$SRC` 下任何文件、修改本技能目录。插件只写在工作目录的 `plugins/` 下。
- 使用 `plugin dev` 时不带 `--once`；对不是开发用的服务器反复安装开发版本。

## 5. 安全与确认

批准安装 = 把清单里申请的宿主操作和路径授予这段代码，并在服务器上运行它。所以：

- 安装前向用户列出：条目 id、要做什么、申请的宿主操作（标出危险操作）、路径、是否联网、运行方式。
  **用户明确同意后才执行第 3 节第 7、10 步**。用户在本次对话里已经明确说过「直接装」的，视为同意。
- 申请最小权限：只列真正会调用的操作；能用演练（`dry_run`）验证的危险操作先演练。
- 卸载、回滚、清除数据：用户已经明确要求的，直接执行并在结果里说明影响，不要再问一遍；
  是你自己提议的，先说明影响、等用户同意。
- 不要把用户的凭据写进插件代码或清单；需要凭据时用插件数据的 `secret=True` 存。
- **绝不设法获取或截获登录凭据**：不读 mclaw 的配置 / 环境变量里的令牌，不用 strace、抓包、本地代理截请求头，
  不绕过鉴权直接 curl 需要登录的接口。mclaw 调不到的接口，就换上面的正规验证方式，或请用户在网页里打开确认。

## 6. 参考资料

| 文件 | 内容 |
|---|---|
| `references/extension-points.md` | 全部开放契约（用途、导入、示例）与「还没开放的 + 替代办法」 |
| `references/composition.md` | 一个插件组合多个扩展点、何时拆分、替换内置、插件之间配合 |
| `references/recipes.md` | 每种扩展点的写法片段（第 11 节含 IM 通道的接入方式选择） |
| `references/manifest.md` | 清单字段、权限、版本区间、安装 / 升级 / 回滚 / 卸载命令 |
| `references/architecture.md` | 原理：生命周期、进程外运行、权限模型、源码位置 |
| `references/explaining-to-users.md` | 给用户解释插件、权限、安全、卸载的标准说法 |
| `references/troubleshooting.md` | 按报错查原因 |
| `references/examples/` | 6 个经过测试的真实插件（先读 README） |
| `templates/starter/`、`scripts/` | 骨架；生成骨架、查契约、安装前检查的脚本 |
