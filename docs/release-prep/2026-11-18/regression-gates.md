# 十二项失败的发布门禁交接

本文件记录失败，不将失败或未执行项改写为通过。对应逐项结果和 Git blob 证据见 `failure-comparison.json`。

## 对照方法与结论

- 上一正式版：`v0.50.0` / `4afc18515964c89de8e38f71cdc77c40515710ed`。
- 实测候选代码：`c2c1d7d29ef67f323da9ac9eacbe1d7fac525760`；后续若只补本目录文档，运行时代码相同。
- 通过 `git archive v0.50.0` 将受版本管理的纯源码导出到独立临时目录；没有创建或重建 git worktree，没有切分支，没有复制 `.env` / 凭据。子进程导入路径已核对为导出目录，`movieclaw_api.__version__` 为 `0.50.0`。
- 两侧使用同一全新 Python 3.11.16 venv、仓库依赖、公开 NER 模型、相同 12 node IDs、`-n 4 --dist loadfile --timeout=180 --tb=short --show-capture=no`，各用独立临时数据目录。
- 两侧逐项结果完全一致：**9 failed / 3 passed**。这 12 项没有发现候选代码相对正式版新增的确定性失败。
- 原始全量使用共享 Python 3.14.6 环境，结果 **8823 passed / 12 failed / 20 skipped / 7 xfailed**。不能将新环境的十二项重验冒充全量重跑或全量通过。
- 这 12 项所属的 7 个测试文件在上一正式版与候选代码间 Git blob 全部相同。直接运行基线，比“文件未改”更强；但不代表候选的其他路径都没有回归。

## 逐项结果

下表“原全量”为 Python 3.14 环境；两侧对照为上述相同 Python 3.11 环境。表内路径均为精确 pytest node ID。

| # | 测试 | 原全量 | v0.50.0 / 候选对照 | 证据、原因与 Linux CI 要求 |
|---|---|---|---|---|
| 1 | `tests/jellyfin/test_http_flow.py::test_playback_info_direct_play_no_transcode` | fail | fail / fail | 635 行要求 `SupportsDirectPlay is True`；请求却携带 `DeviceProfile.MaxStreamingBitrate=1`，日志显示协商转码。测试注释称 profile 应被忽略，与两侧实际行为不一致。需要 Linux CI 核对该断言与产品当前契约，不能仅删断言放行。 |
| 2 | `tests/api/test_jobs.py::test_job_wait_timeout_and_cancellation_keep_parent_lock_and_release_capacity` | fail | pass / pass | 原环境取消一个等待后 `_waits` 从 2 变 0，断言期望 1，父任务随后 3 秒超时。Python 3.11 + pytest-asyncio 1.5.0 两侧均过；尚未单独隔离 Python 与 asyncio 插件版本两个变量，不声称是生产任务锁缺陷已修。Linux CI 必须实跑该用例。 |
| 3 | `tests/api/test_bundled_plugins.py::test_weixin_package_replaces_the_bundled_one_and_uninstall_restores_it` | fail | pass / pass | 原环境 268 行等待进程版插件回复超时；此前新 Python 3.11 的串行代表组合也失败，后来相同并行对照两侧均过。它仍是时序 / 顺序敏感项，不能仅凭最后一次绿认定已修。Linux CI / 独立审查要核插件替换后的回复、push 和卸载恢复，不扩大访问真实微信账号。 |
| 4 | `tests/api/test_media_server_plugin.py::test_probing_specs_reaches_the_server_with_the_token[inline]` | fail | fail / fail | 641 行期望 `probed`，实际 `failed`；真实 ffprobe 去访问 `127.0.0.1:8000/internal/ffmpeg-stream/...`，但 TestClient 没有该 TCP 监听，连接被拒。独立审查临时补 loopback 桥后，两版都通过真实探测、h264 和上游测试令牌检查，随后都在 654–655 行旧“直交上游 URL / 令牌”的断言失败；产品实际是安全的本机凭据隔离 relay。不能为了旧断言退回泄露凭据的直链。仍记 fail，不能将条件跳过或部分断言通过说成整例通过。 |
| 5 | `tests/tracker/unit/test_hdwing.py::test_factory_search_promotion_detail_download_profile_flow` | fail | pass / pass | 原 cssselect 1.5.0 对配置 `td.info_box i:has(b:contains('大小'))::text` 报 `SelectorSyntaxError`；新环境 cssselect 1.6.0 两侧均过。成功的 Linux CI 也安装 1.6.0。不得改站点配置掩盖旧解析器差异，需新 PR CI 真跑。 |
| 6 | `tests/api/test_media_server_plugin.py::test_probing_specs_reaches_the_server_with_the_token[process]` | fail | fail / fail | 与 #4 相同的真实 ffprobe / TestClient TCP 回源边界；进程型插件参数独立执行，失败同样在正式版存在。 |
| 7 | `tests/playback/test_lead_throttle.py::test_signal_constants_are_the_expected_ones` | fail | fail / fail | 294–295 行硬编码 Linux `SIGSTOP=19`、`SIGCONT=18`；Darwin 实际为 17、19。平台差异已确认，不能由此证明节流行为坏了。Linux CI 仍须验证目标平台信号值与对应节流行为测试。 |
| 8 | `tests/jellyfin/test_stream_activity.py::test_detail_prefetch_does_not_report_playing[Rex]` | fail | fail / fail | 103 行真实 TCP `PlaybackInfo` 请求超时；原夹具 strm 指向 `pan.example.com`，真 ffprobe 探该外部假地址，HTTP 客户端 5 秒先超时。独立审查仅将临时夹具改指本地合成媒体后，两版这组 5 项各 5/5 通过，保留真实 TCP / Range / 进程重启。原始场景仍记失败，不能表述成 Rex / Infuse 真机已验。 |
| 9 | `tests/jellyfin/test_stream_activity.py::test_detail_prefetch_does_not_report_playing[Infuse]` | fail | fail / fail | 与 #8 相同，但独立 UA 参数，不代表已经在 Infuse 真机验证。 |
| 10 | `tests/jellyfin/test_stream_activity.py::test_detail_prefetch_does_not_report_playing[OtherPlayer]` | fail | fail / fail | 与 #8 相同的旧版可重现 TCP 协商超时。 |
| 11 | `tests/jellyfin/test_stream_activity.py::test_stream_restores_confirmed_playback_after_process_restart[0]` | fail | fail / fail | 153 行 `PlaybackInfo` 超时，尚未进入重启恢复确认播放的核心断言。不能将本机结果计入重启恢复已验收。 |
| 12 | `tests/jellyfin/test_stream_activity.py::test_stream_restores_confirmed_playback_after_process_restart[301.0]` | fail | fail / fail | 与 #11 相同，另一个起播进度参数；两侧均失败。 |

## Linux CI 的放行建议

1. 新发布 PR 必须完整通过 `ci-ok` / `apple-ok` / `android-ok` 与其实际展开的作业；旧的成功 run 不替代本次提交的结果。
2. Python 三片必须用 CI 的 Python 3.11 与新装仓库依赖。成功基线 run `44006895889` 的依赖为 cssselect 1.6.0、pytest-asyncio 1.5.0；其三片总计 8789 passed，另有 skips / xfails。这只是环境对照证据。
3. 对照上述 12 项，尤其确认 #1、#3、#8–12 被收集并实际运行；核对 #4/#6 的 ffprobe 条件跳过理由。若日志不足，另用完全相同 Linux 环境运行这些 node IDs 并带 `-vv -ra` / JUnit，不能用汇总绿色推断某条测试执行过。
4. 若候选新 CI 红：先读具体 job 日志，将同环境、同命令对照正式版；确定性候选回归必须修复并补回归。已有问题也需维护者按真实影响作出明确 gate 决策，不能因“以前也坏”自动忽略。
5. 代码 review 特别关注这次唯一测试改动：`auxiliary-i18n.test.mjs` 只补 HTTP mock 的 `withUiLocale`，未降低 SSE 错误断言；两处生产源码变动仅是版本号。
6. CI 全绿仍不覆盖仓库 release 技能第七节的硬件矩阵。需要相应硬件 / 软件 / 真机项证据，或维护者对尚未执行项作出明确记录的处理；不得擅自标 pass。

## 原始证据位置

技术会话的原始文件位于独立临时目录 `/private/tmp/movieclaw-release-20261118-a8LBTT/`：`python-full.log`、`baseline-failures.xml` / `.log`、`current-failures.xml` / `.log`、`python311-isolation.log`、`pr-ci-baseline.log`。原始服务日志含测试用签名 URL，不直接贴聊天或提交；公开交接只保留结果、测试名、Git blob 与必要错误类别。

独立审查证据为 `/private/tmp/movieclaw-independent-audit-ueni545m/REPORT.md` 及其 `candidate-synthetic-jellyfin.log` / `baseline-synthetic-jellyfin.log`、`*-relay-listener-2.log`。审查未改发布工作树或生产代码；其额外受控输入诊断不能重写原始 12 项结果。

## 本 PR Linux CI 的实际结果与四条 error annotations

快照绑定 PR #1297 的 `c2c1d7d29ef67f323da9ac9eacbe1d7fac525760`、CI run **44129813801**：

| Python 作业 | job / check-run ID | pytest 结果 |
|---|---|---|
| 1/3 | 134203548850 | 2623 passed、33 skipped、5 xfailed、21 warnings |
| 2/3 | 134203548686 | 2602 passed、32 skipped、1 xpassed、154 warnings |
| 3/3 | 134203548532 | 3578 passed、34 skipped、1 xfailed、13 warnings |

合计 **8803 passed、99 skipped、6 xfailed、1 xpassed**。命令为 `python -m pytest -m "not integration" -n auto --dist loadfile --durations=30 --timeout=180`，`PYTEST_SHARD` 分别为 1/3、2/3、3/3。每个文件依历史耗时只分配到一片，不是只测 PR 修改的测试。环境是 Linux x64 / Python 3.11.18，三片均安装 cssselect 1.6.0、pytest-asyncio 1.5.0、pytest 8.4.2、uvicorn 0.54.0。

上表 12 项所在文件没有 integration / xfail / 模块 skip 条件；只有媒体服务器真探测的两个参数有“没有 ffprobe”条件跳过。因此按仓库现有收集 / 分片规则，另 10 项应被实际执行；这是结合源码与完整作业成功得出的推断，安静模式日志未逐项列出 pass / skip，不能把两个 ffprobe 条件用例或 99 个 skips 说成真探测 / 硬件测试通过。独立受控媒体 / loopback 的补充诊断见上文。

Python 1/3 的 annotations API 显示四条 `annotation_level=failure`，文本全是 **Event loop is closed**，映射为 `.github:520`。完整日志表明四条都来自 pytest warnings summary 中的 `PytestUnraisableExceptionWarning`：

```text
BaseSubprocessTransport.__del__ → close → proto.pipe.close
→ _loop.call_soon → _check_closed → RuntimeError('Event loop is closed')
```

这是子进程传输对象在事件循环关闭后由 GC 析构时产生的真实清理警告，被 Python problem matcher 提升成 GitHub error annotation；不是四个 pytest 功能断言失败，`.github:520` 也不是应当修改的仓库源码位置。warning 报告上下文涉及 process 型 drive-library 测试、SDK / provenance、member / facets、cloud-replica migration；GC 发生时间会延后，不能仅据报告上下文给每个资源的创建点定因。

三片此类标注分别 4 / 5 / 5，共 14 条；它们与原本 12 个失败的堆栈不同。正式基线 `v0.50.0` 的发版 PR #1261、成功 CI **43040797631** 已有 **12 条同类 BaseSubprocessTransport 析构警告及 error annotations**；最近成功 run 44006895889 为 14 条。故同类问题在上次正式发布前已存在，不能把它当成本次首次出现，也不能因 check 绿色宣称零错误。数量差异受用例和 GC 时序影响，不能据此证明多出的两条一定无新增泄漏。

技术 gate 建议：保留这些真实警告，作为已存在的测试 / 子进程生命周期债交独立审查；不禁 warning、不改 problem matcher、不放宽 pytest。若最终 head 的功能检查全绿且审查未发现新增资源泄漏证据，可将此项作为明确记录的非 P1 遗留项；它不能抵消硬件 P1。若出现断言失败、作业失败或新增确定性泄漏，必须停止合入并修复。
