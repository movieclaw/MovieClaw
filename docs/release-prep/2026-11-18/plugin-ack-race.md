# PR #1295 双插件回归的确认时序

## 真正失败的位置

`e77dcbba2b2eed16d210fb15e1413eb16d127410` 的 [CI 44143371496](https://github.com/movieclaw/MovieClaw/actions/runs/44143371496) 中，Python 1/3 job `134251878709` 实际 exit 1：

```text
FAILED tests/api/test_plugin_events.py::test_process_plugin_subscribes_to_another_running_plugin[True-True]
AssertionError: 等待超时
1 failed, 3547 passed, 39 skipped, 6 xfailed in 426.44s
```

完整堆栈指向原测试第 315 行、重挂监听插件并再次发出事件后的第二个 `wait_for`。第一次接收、卸载清理、重新启动均已通过；不是首次订阅就绪失败，也不是此前析构 warning 的 annotation。日志没有记录响应 JSON，因此不能声称已经从 CI 日志直接读取到“三条”或排除一切其他时序；下述受控复现证明了测试的确定性缺陷，并产生相同末尾失败。

## 契约与基线

`Context.on`、`DurableEvents` 以及 `docs/design/plugin-phase2a.md` 都明确可靠订阅是**至少一次**：消费方按 `ctx.delivery.event_id` 去重。插件处理成功、数据写入可见之后，宿主还须在另一事务里提交 `EventConsumer.cursor`。若这时卸载，消费者任务被取消，未确认的事件重挂后以相同 id 再投是正确行为。

PR #1295 / `358b4a816a83f97115b24f2431f5cd88cf72471d` 新增的测试直接在插件数据可见后卸载，却要求重挂后恰好两条。它既可能因 `[A, A, B]` 超过两条而一直等待，也可能在 `[A, A]` 的暂态提前通过，尚未验到第二次发出的独立事件 B。

- 最新 main `9dd11c106ddb76f2e711deef26494c89167ec4f4` 与 e77 的该测试、SDK 订阅实现、宿主代理及可靠投递模块均无差异。
- 通过 `git archive origin/main` 导出临时纯源码基线，不切分支 / 不建 worktree / 不复制凭据；同一 Python 3.11 venv 与隔离数据库直接复现失败。
- 宿主代理和可靠投递模块自 v0.50.0 未变；但 v0.50.0 的 SDK 尚不接受这个自定义订阅，也没有此测试。不能将这次回归说成“上一正式版相同用例已通过 / 也失败”。

## 确定性失败前 / 通过后

临时 pytest 探针只拦截 `event-listener:quota` 第一次 `_deliver`：真实双进程处理返回成功后，阻挡宿主提交 cursor。查询确认状态时释放屏障，不添加 sleep，不改变重试 / 超时或处理结果；卸载导致的 `CancelledError` 原样向上传播。

旧测试在确认前就卸载，重挂产生同一 id 的 A 重投；探针在最终确认状态清空后再执行原来的“两条”断言，稳定失败：**1 failed**，实际为三条，投递 id **[A, A, B]**。最新 main 的纯源码基线结果相同。

修复后在“确认后重挂”场景等待真实的 `backlog == 0`，同时严格要求零 attempts / 无 last_error，再卸载。相同屏障下 **1 passed**，投递 id **[A, B]**，不是放宽成“至少两条”。

## 提交内的双进程 E2E

原实时 / 可靠 × 发布方先后安装四场景保留，并增加两个可靠未确认中断场景，共六场景：

- 实时：收到两条后排空总线，严格核对载荷与两个不同的非空事件 id。
- 可靠已确认：等宿主 cursor 提交才卸载；重挂后再次发出，消费进度清空后严格核对两条 / 两个 id。
- 可靠未确认：真实处理完成后由事件屏障固定 ACK 窗口，卸载取消等待，断言确实经过取消；重挂后必须恰好三条 / 两个 id，前两条 id 相同、第三条不同。
- 缺发布方回滚、重新安装、payload 类型校验、卸载后的路由 / consumer / listener 清理断言保留。模拟插件把载荷和事件 id 放在同一次 `store.set`，不因两次写入引入新的测试竞态。
- 不改生产代码、可靠语义、工作流、全局等待函数、超时、重试或 release runtime；不吞处理错误。此次没有新增应写为产品修复的行为，不改 changelog。

`test_plugin_events.py`、`test_remote_plugin_events.py`、`test_durable_events.py` 串行合计 **39 passed**；加上事件发布 / domain / 内核事件测试，以 `-n 4 --dist loadfile --timeout=180` 并行执行六文件，共 **126 passed**，Ruff 全仓与 diff-check 通过。本地为 Darwin / Python 3.11.16，最终提交仍须通过 Linux 全量 CI 和独立复审；硬件 P1 不变，不能据本地绿色发布。

原始证据在 `/private/tmp/movieclaw-release-20261118-a8LBTT/`：`ci-e77-python1.log`、`plugin-ack-stable2-red.log`、`plugin-main-red.log`、`plugin-barrier-main-red.log` / `.json`、`plugin-barrier-fixed-green.log` / `.json`、`plugin-events-green.log` / `.xml`、`plugin-events-parallel.log` / `.xml`；可重放探针为 `plugin-ack-race/ack_probe.py`，旧屏障版本也保留。它们随本批证据持久保存，不提交临时数据或密钥。
