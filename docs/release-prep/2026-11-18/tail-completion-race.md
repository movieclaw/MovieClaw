# Linux CI 尾流完成竞态：原因与回归

## 失败是发布门禁，不是 annotation

候选 `0e2e72ff2c999ae3b4973b429521e1a78e80cde7` 的 [CI run 44140348464](https://github.com/movieclaw/MovieClaw/actions/runs/44140348464) 中，Python 3/3 job `134241215696` 的 Test 步骤 exit 1：

```text
FAILED tests/api/test_offline_download.py::test_export_tail_streams_while_transcoding
ExportStreamAborted: 离线导出 tailtest 产物不完整
1 failed, 2586 passed, 32 skipped, 11 warnings in 260.93s
```

`ci-ok` 因此失败。它与此前子进程析构的 `PytestUnraisableExceptionWarning` 不同，不可以忽略，也未盲目重跑。工作流在 Ubuntu / Python 3.11 执行 `pytest -m "not integration" -n auto --dist loadfile --durations=30 --timeout=180`；同一测试文件在同一 worker 串行执行，但该用例的写线程与流式响应的 `asyncio.to_thread(handle.read)` 本来就并发。

## 精确交错与基线

1. 消费者读完已有字节，又在工作线程读到旧 EOF。
2. 生产者写完最后一段，关闭写句柄并设置最终字节数 / DONE。
3. 消费者恢复执行，读取新的 DONE 状态；旧代码直接比较已发送数与最终数，把尚未再次读取的尾段误判为截断。

原用例的两次 0.5 秒 sleep 并不能禁止这个交错；增加 sleep 或把测试判为 flaky 都不修复真实行为。

`src/movieclaw_api/services/offline/exports.py` 在 `v0.50.0..0e2e72f` 无差异，最后一次修改均为 `a2dca09d5f01d353783516c22b9129cf974e5303`。原 tailtest 在本轮未修改。此竞态在正式版也存在，与 P2 合成 GPU 校验脚本无调用关系。

新增 HTTP 回归 `test_export_tail_completion_between_eof_and_state_check` 使用真实临时文件、数据库、认证与下载路由。只在文件读取边界插入确定性交错：先从真实句柄读出空字节，再追加尾段并标 DONE，然后返回这次旧 EOF；不靠调度概率或 sleep。完整尾段预期返回精确 3000 字节与原 ETag；缺失 / 少一段的负例仍要求原 `ExportStreamAborted`，并限制读取次数，防止忙等。

- 修复前候选：**1 failed / 2 passed**，完整尾段失败。
- 将同一新回归复制到 `v0.50.0` 临时源码归档，生产代码不改、同一 Python 3.11 venv：**1 failed / 2 passed**，相同完整尾段失败。
- 修复后：离线下载测试文件 **44 passed / 0 skipped**，包括新三例、原边转边下、换代掐断、真实 FFmpeg 导出等。出现一条已记录的 `Event loop is closed` 析构 warning，不记为无警告。
- 重新运行完整发布构建后，manifest 的 SHA256 / 大小逐项一致，归档无 AppleDouble、Web 无 `.node`，后端归档中的修复模块与源码逐字节一致。解包代码再次运行上述离线测试文件：**44 passed / 0 skipped / 2 warnings**；另通过从 v0.50.0 SQLite 冷启动迁移、观看状态保持、真实 HTTP 版本 / 登录 / 策略持久化验证。没有安装、重启用户 App 或部署。

## 最小修复与限制

流式读取只增加一个局部状态：若这次 EOF 时刚观测到 DONE、且未发满最终字节数，立即再读一次。若确有尾段则按原方式排空；在完成状态之后再次读到 EOF 仍少字节，照旧抛出不完整异常。最多补一次完成后的 EOF 确认；不改变 sleep、终止字节数、generation / failed 检查、HTTP 接口或 runtime。

本地 Ruff / diff-check 通过；这不替代最终提交的 Linux 全量与 Apple 必需检查。正式版基线能复现也不使本次红 CI 自动放行；最终 head 必须重新通过 CI 与独立复审。Linux GPU / 真机硬件 P1 仍未关闭，详见 `hardware-gate.md`。

原始证据：`/private/tmp/movieclaw-release-20261118-a8LBTT/ci-0e-python3.log`、`tail-race-red.log`、`tail-race-v050-red.log`、`tail-green.log`、`tail-green.xml`、`tail-packaged.log`、`tail-packaged.xml`、`build-tail-fix.log`、`artifacts-tail-fix/`、`packaged-tail-fix-smoke.log`。临时基线只复制新测试，不改正式版生产模块。
