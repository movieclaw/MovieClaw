# 2026-11-18 服务器 v0.51.0 发版准备

## 基线与范围

- 已执行 `git fetch origin main --tags`，隔离 worktree 的起点与远端 main 均为 `9dd11c106ddb76f2e711deef26494c89167ec4f4`。
- 上一服务器正式 Release 为 `v0.50.0`，指向 `4afc18515964c89de8e38f71cdc77c40515710ed`，非 draft / prerelease。
- `release-status.py --ref origin/main --offline` 显示服务器有 147 个产品文件变化。按新增已看判定配置、德语 Web、同步隐藏续看与 MCP 工具排除能力递增 minor 为 `0.51.0`。
- 本轮只发布服务器。iOS 删除会话闪退、Android TV 分集焦点等已合入改动留待独立客户端发版；其余客户端不因生成模型字段变化搭车发布。HarmonyOS 现有 `harmony-v1.0.0` draft 不属于本次目标。
- 未合并的 #1293 外部播放器链接、#1289 鸿蒙折叠外屏、#1245 Apple 精确拖动、#1167 鸿蒙共享播放核心均不宣称已修复或已提供。

## 完整变更盘点

以 `git log --first-parent v0.50.0..HEAD`、最终 diff 与 `release-surface-diff.py v0.50.0 HEAD src apps/web docker cli` 交叉核对。逐提交记录见 `commits.txt`，机械界面盘点见 `surface.md`。

| 来源 | 用户变化 / 维度 | 写入或取舍 | 代码证据 |
|---|---|---|---|
| #1246，2cc398651 / 1c4a88c76 / 36ce44668 / 533579e8b | 同步 API 可按作品隐藏续看，不伪装已看；新的真实播放解除隐藏，旧上报不解除；并发与重新识别保持语义 | 其他新功能；不是网页新菜单 | `schemas/playback_sync.py`、`services/playback_sync.py`、`services/playback_up_next.py`、`movieclaw_playback/state.py`、`services/library/reanchor.py` |
| #1246 | 新增 `continue_dismissed` / `continue_dismissed_at` 数据库列，默认 false / null，原有历史保留 | 升级须知：应用内更新有数据库备份，镜像升级须先停容器备份；回退需恢复对应备份 | `alembic/versions/20261109_1000_a7d2e9c41b58_playback_state_continue_dismissed.py`、`services/app_update.py` |
| #1263，1d625c7f8 | VAAPI/QSV/NVENC seek 后 GPU 补片重启可能因软件 auto-scale 失败 | 修复；旧版 `_video_args` 只对 VT_GPU 带 `-noautoscale` | `services/playback/ffmpeg_args.py`；`tests/playback/test_ffmpeg_args.py` |
| #1269，55dc714c8 | MCP API 配置工具排除，发现与直调、紧凑命令同样生效；未知名称拒绝保存 | 其他新功能；明确网页编辑器暂不暴露 | `services/mcp_endpoints.py`、`movieclaw_mcp/tools.py`、`schemas/mcp.py` |
| #1268，4d3a0c2eb / 895913eff | 未看完筛选不再把已看但带续播点的作品算未完 | 修复；旧版同时要求 played=true 与 position_ms=0 | `services/library/items.py`；`tests/api/test_library_filter.py` |
| #1273，43eacf65d / 7c7361787 / 7b7aa3759 | 全设备在线上报与离线补传共用已看阈值，80–100%；剧集可优先有效直达结尾片尾；部分配置保存并发安全 | 主亮点；90% / 片尾关闭为默认，原短片规则保留；非追溯修改 | `components/playback-completion-section.tsx`、`settings/playback.py`、`services/playback/completion.py`、`movieclaw_playback/progress.py`、`settings/store.py`；`tests/api/test_playback_completion.py` |
| #1273 | 消失的显式片源使用自己的历史片长，无片长保留进度，避免借用另一版本已看判定 | 列为进度处理改进，不声称上一版已有新的配置功能 | `completion_runtime_ms`；`test_replaced_version_uses_its_own_duration` |
| #1284，926cc411c / f61b187e9 / c9e8adeec / a96c944a7 / da28fc14a / e43f070ae | Web 新增 de，浏览器协商、日期数字、德语元数据快捷选项；服务器消息回落英文 | 主亮点，明确 Web 与服务器语言范围；翻译校对和测试注释不单列修复 | `components/language-picker.tsx`、`lib/i18n/*`、`locales/de/*`、`components/scrape-settings-section.tsx`、`movieclaw_api/i18n/*` |
| #1286，e942e3545 | App 带 subtitle_track=off 请求时仍返回同剧记忆，关字幕后下一集不被默认字幕顶回 | 修复；旧版在显式给轨时屏蔽返回的同剧记忆 | `api/routes/playback.py:_with_series_memory`；`test_subtitle_turned_off_stays_off_across_episodes` |
| #1287，50fab91b4 | 交互绑定并行确认串行落库 | 修复；旧版 `_apply_flow` 无锁 | `services/channel_hub.py`；`tests/channel/test_channel_hub.py` |
| #1280，d14634580 / effbdb94d / 7b6ceb8c6 / d5a2a315c | 网络监听目录定时巡检、下载完成触发巡检、断挂载后继续恢复检查 | 修复；旧版已 watch 的网络目录依赖事件 / 长周期兜底 | `services/library/ingest.py`、`services/download_progress.py`；`tests/e2e/test_downloader_completed_sweep.py` |
| #1294，f088df0a8 / 8b5a11d15 | 取消或协议错误后的网络探测槽释放且核对所有权，服务恢复后继续请求 | 修复；旧版 `_probing=True` 仅成功或网络失败重置，取消时残留 | `movieclaw_net/breaker.py`、`movieclaw_net/egress.py`；`tests/net/test_breaker_recovery.py` |
| #1295，358b4a816 | SDK 接受已登记的其他插件自定义事件订阅，宿主仍校验提供者与权限 | 修复；旧版 RemoteContext.subscribe 只接受内置 known_events 对象 | `movieclaw_sdk/runner.py`；`tests/api/test_plugin_events.py` |
| #1271，a74efdc82 | node-forge 1.4.2 → 1.4.3，仅 HarmonyOS 工具链锁依赖 | 不写服务器产品变化，不改 runtime | `pnpm-lock.yaml` |
| #1247 / #1266 / #1267 / #1270 / #1272 / #1279 / #1290 / #1296 | 原生客户端能力、修复、测试和上轮发版准备 | 不随本次 server Release 分发，自动客户端节仍引用已正式发布版本 | 各 `apps/*`、上轮 prep 文档；没有客户端版本改动 |
| #1265 | 小艺技术设计及评审修订 | 文档，不是已实现能力 | `docs/design/` |

### 六条消失文字的逐项解释

1. MCP「修改端点的名称、服务、工具模式或启停状态」：OpenAPI 描述新增“排除清单”，端点编辑能力未移除。
2. MCP「试算：给定服务集合会暴露哪些工具、占多少上下文」：试算描述新增排除清单，原能力保留。
3. 「played、position_ms、is_favorite 至少要给一个」：校验提示新增可写 `dismiss_continue`，不是拿走字段。
4. 「外部请求巡检某源目录（人工恢复处理后的立即重看）。事件循环线程调用。」：内部 docstring 更新巡检原因，不是界面入口。
5. 「按单元写回已看 / 续播 / 收藏；compare-and-set，值没变不动版本，不发事件。」：内部 docstring 新增隐藏能力。
6. 「请求发出前调用；熔断打开且不在探测窗口时抛 CircuitOpenError。」：内部 docstring 描述探测 token，非界面文字。

15 条默认值 / 门槛信号中，7 条是德语文案而非新权限；3 条是新增已看配置字段（响应默认 90、patch 默认不改、持久化默认 90）；3 条是新增隐藏字段默认 false / null；剩余 2 条是短片阈值条件修改前后，只有显式修改完成规则后才改为新阈值。没有运行时依赖、客户端最低服务器版本或转码器握手变化。

## 验证与发布门禁

本地验证使用 Python 3.14.6、Node 26.10.0、Go 1.27.1。正式流水线以仓库锁定的 Python 3.11/3.12、Node 22 等环境再验；以下结果不替代 PR 的全量 CI。

| 检查 | 结果 |
|---|---|
| 发布脚本 unittest | 51/51 通过 |
| Ruff / Go vet / Go 全部包测试 | 通过 |
| CLI 六平台交叉编译 | Linux / Darwin / Windows × amd64 / arm64 全通过 |
| Web lint / TypeScript / 主题 TypeScript | 通过，lint 有既有 warnings，无错误 |
| i18n 目录 / 中文保留 / ratchet | 通过，只有既有 possible-unused 提示 |
| Web 全量 Node 回归 | 1198/1198 通过 |
| 已看规则、续看隐藏及 SQLite 并发、迁移保留、字幕记忆、网络挂载导入、下载完成 E2E、绑定、MCP、网络恢复、跨插件事件、GPU 参数、i18n | 541 通过、4 跳过（未配置真实 Postgres 的对应并发用例）；真实 HTTP / DB / 子进程边界均覆盖 |
| Playwright 真实更新 / 下载校验错误 / 回退 / 双主题语言场景 | 1/1 通过，只运行隔离服务，无用户 App 安装或重启 |
| 真实 FFmpeg / ffprobe 集成 | 10/10 通过，含 HEVC hvc1、关键帧、seek、音频单转、软件缩放与分片；不代表 GPU 硬件验收 |
| 完整 `build-release-artifacts.sh` | 通过，Web / 后端 / manifest 三件套；版本 0.51.0、runtime 25 |
| 产物复核 | SHA256 / 大小与 manifest 一致；Web 无 `.node`，含两种扩展 ZIP 与启动入口；后端有迁移、版本正确的 spec、Linux 双架构 ELF CLI |
| 解包后端冷启动升级 | 从 v0.50.0 的 `d6a2e7c4f981` 临时库自动迁移到 `a7d2e9c41b58`；原观看位置 / 已看 / 次数 / 收藏 / 最近播放时间保持不变，新字段 false / null；真实 HTTP 返回 0.51.0、初始化 / 登录 / 策略从 90 改到 97 并回读成功 |

首轮 Python 失败的原因是网络挂载 fixture 直接把含空格的临时路径写入 `/proc/mounts` 样例，以及相对 `PYTHONPATH=src` 在插件子进程内失效。使用独立无空格临时根与绝对源码路径后代表测试 16/16、整批回归通过；没有修改生产代码规避问题。

Web 全量回归暴露德语 PR 新增 `withUiLocale` 导入而旧 mock 缺失，SSE 预期错误被重试分支的 `window is not defined` 覆盖。仅给 `auxiliary-i18n.test.mjs` 的 HTTP mock 补一项，原用例不改断言，修后全量通过。

macOS 默认 bsdtar 会把扩展属性打成 AppleDouble `._*.py`，初次本地包冷启动时 Alembic 扫描这些元数据报 null bytes。用 `COPYFILE_DISABLE=1` 重新执行完整构建后，归档无 AppleDouble、哈希检查与上述解包冷启动均通过。正式工作流在 Linux / GNU tar 构建，不上传本地初次生成的包；最终仍须下载正式附件验收。

### 额外全量回归的未通过项

在上述重点验证之后，本地完整执行 `pytest -m 'not integration' -n 4 --dist loadfile --timeout=180`，结果为 **8823 通过、12 失败、20 跳过、7 xfailed**，耗时 547.64 秒，不能记为全量通过。

- `test_signal_constants_are_the_expected_ones` 硬编码 Linux SIGSTOP=19 / SIGCONT=18，Darwin 分别为 17 / 19，属于已确认平台差异。
- 两个 `test_probing_specs_reaches_the_server_with_the_token` 参数用例在本地有 ffprobe 时执行，但回源 `127.0.0.1:8000` 没有真实监听，探测失败。
- 五个 `test_stream_activity` 用例在真实 TCP 的 PlaybackInfo 请求上超时。
- `test_playback_info_direct_play_no_transcode` 的旧断言要求忽略 DeviceProfile，但服务端按其低码率要求协商转码。
- `test_factory_search_promotion_detail_download_profile_flow` 的嵌套 CSS 选择器在本机旧 cssselect 1.5.0 下无法解析。
- `test_job_wait_timeout_and_cancellation_keep_parent_lock_and_release_capacity` 未在期望时间观察到等待登记；`test_weixin_package_replaces_the_bundled_one_and_uninstall_restores_it` 未观察到替换为进程插件后的回复。

这些测试文件与对应 jobs / tracker / Jellyfin 等模块在 `v0.50.0..HEAD` 未修改，不能据此断言本轮引入了缺陷，也不能据此忽略失败。已只读检查成功的 Linux CI run `44006895889`：三片 Python 全绿，使用 Python 3.11、cssselect 1.6.0、pytest-asyncio 1.5.0；本机共享环境为 Python 3.14、cssselect 1.5.0、pytest-asyncio 1.4.0。

随后用机器已有 Python 3.11 创建独立临时 venv，重新安装仓库依赖（未修改用户共享 venv），串行核查五个代表用例：jobs 与 HDWing 通过；微信插件替换、Jellyfin direct-play 旧断言、Rex 预缓存的 PlaybackInfo 超时仍失败。后面三类仍需本发布 PR 的 Linux CI 复核；没有修改无关生产模块、删除用例或降低门禁来掩盖它们。新发布 PR 的必需检查与全量 CI 尚未运行时，不能把旧 run 当作本次发布的放行证据。

- 发布必须经过 PR 与分支规则集，`ci-ok` / `apple-ok` / `android-ok` 为必需检查，全量 CI 通过后合入；不直推 main，不强推、不删 tag。传统 branch protection API 返回 404，但分支 rules API 已确认上述规则，不能因此视为无保护。
- 两处版本为 0.51.0，`scripts/export-spec.sh` 同时导出服务器 / CLI 基线；spec 是忽略的构建产物。
- release workflow 的既有副作用是发布应用三件套、CLI 六平台、host constraints / release info，更新 Docker 双架构 `v0.51.0` / `runtime-25` / `latest`，并通知官网；无 App Store / TestFlight / 生产库连接 / 无关部署。
- 仓库 release 技能第七节要求播放 / 转码改动的硬件矩阵人工验收；上轮 prep 明确 #1263 缺修后 NAS seek 证据。正在协调核实，不用软件单测代替硬件验收。

## 合入后的协调动作

只有 GitHub 协调方触发一次 `release.yml`，`workflow_dispatch` 参数为 `tag=v0.51.0`，ref 为 `main`。触发前须重新核对合入后的 main SHA、版本与 changelog、CI 与人工门禁、无同版本 tag / 活跃 run。技术会话不同时 push tag。

验收必须检查：正式 Release 非 draft / prerelease 且为服务器 latest；tag 指向已验收 main SHA；12 个必需附件完整（配置签名时另需 manifest.json.sig），清单哈希 / 文件大小正确；Docker amd64 / arm64 digest 及标签完整；发布工作流成功。失败先取日志定位，不盲目重试。

## 后续补充的门禁证据

- `plugin-ack-race.md`：e77 的新 CI 真实超时、main 基线确定性复现、至少一次 ACK 窗口、正确同步与未确认重投的六场景双进程验收；未改生产投递逻辑。
- `tail-completion-race.md`：`0e2e72f` 新 CI 的真实失败、EOF / DONE 交错、v0.50.0 同样确定性失败、最小修复及完整离线 HTTP / FFmpeg 回归；最终 head 仍须通过新 CI，不能拿旧绿色检查放行。
- `regression-gates.md` / `failure-comparison.json`：原始 12 fail 的精确 node IDs；同 Python 3.11 环境下正式版与候选均 9 fail / 3 pass，逐项一致；独立受控媒体 / loopback 对照；PR #1297 的 Linux 三片 8803 passed / 99 skipped / 6 xfailed / 1 xpassed；四条 error annotations 的完整析构警告解释与 v0.50.0 正式基线证据。原本全量失败不会被重写为通过。
- `hardware-gate.md` / `hardware-evidence.json`：已授权入口的只读库存结果、M2 Max 合成验证五项 pass、全 GPU / HDR tone-map 实际限制、仍未关闭的 Linux GPU / 真机 P1、最小补测任务与排除 #1263 的策略边界。
- `synthetic-gpu-check.py`：可交已有授权 NAS 会话的只读库存与合成校验脚本；不部署、不读私有媒体、不使用账号；固定版本 / ffmpeg_args 源码哈希，缺设备或原生 HDR 链时拒绝记 pass。它只补充硬件命令证据，不自动放行 GPU 活动 / 视觉 HDR / 真机矩阵。
- `apple-followup.md`：用户追加授权的依赖阶段。只有服务器 GitHub 正式发布并验收成功后，主助手才另起 Codex 核 Apple 各平台真实 TF 基线与变化、只打有变化的平台并上传 TF / 验 processing；当前不上传、不改凭据、不提 App Store / 外测审核、不扩 tester。

上述补充不代表发布已完成。PR #1297 的既有绿色检查绑定旧 head；补充文档 / 脚本提交后仍需最终 head 的必需检查与独立审查。硬件 P1 未有相应设备证据或明确维护者处理前，不合并点火、不打 tag、不触发 release。
