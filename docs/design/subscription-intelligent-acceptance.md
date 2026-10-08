# 智能订阅实现与验收记录

日期：2026-10-07。实现分支：`codex/subscription-rules`。

依据：[需求说明](subscription-intelligent-waiting.md)、已确认的交互原型，以及[技术方案](subscription-intelligent-implementation.md)。

## 1 交付结论

首版已实现独立智能模式。电影与剧集分别保存首次设置。新订阅冻结设置快照。旧订阅和未传模式的旧客户端继续使用规则模式。

首版执行确定性选择、有限观察、固定截止和版本跟随。洗版继续复用现有下载、入库核验与旧文件保护。分辨率和片源同时达标，并完成入库核验后，该单元停止自动洗版。后续新资源不会重新开启洗版。库存被确认缺失时可以补缺。

历史证据等待默认开启，并受独立样本、近期按时比例和用户预算约束。NAS 静态回归集已经验证旧资源不再新增等待；尚无完整纵向留出集，不能宣称长期品质收益、下载成功率或全局最优。

## 2 实现位置

| 职责 | 实现 |
|---|---|
| 纯决策、品质比较、预测窗口 | `src/movieclaw_matcher/smart.py` |
| 冻结输入的精确回放与同候选比较 | `src/movieclaw_matcher/smart_replay.py` |
| 按观测时间推进三套独立策略 | `src/movieclaw_matcher/smart_replay_events.py` |
| 类型设置、订阅快照 | `services/subscription/smart_profiles.py`、`core.py` |
| 候选缓存、版本跟随、等待状态、人工操作 | `services/subscription/smart_selection.py` |
| 原子认领、提交指纹、恢复对账 | `services/subscription/smart_submission.py`、`dispatch.py` |
| 到期与提交恢复调度 | `services/subscription/smart_scheduler.py` |
| 核验、达标停止、旧版保护 | 原有 `upgrade.py`、库存对账与入库流程 |
| 设置与状态页面 | `apps/web/components/smart-subscription-settings.tsx`、`smart-subscription-status.tsx` |
| 数据迁移 | `alembic/versions/20261007_1200_e7f4a1c9b203_smart_subscription.py` |

服务文件路径均位于 `src/movieclaw_api/` 下。智能模式不创建隐藏规则组，不调用模型决定下载、替换或删除。

## 3 需求追踪

下表的“通过”指可重复的工程场景测试。预测场景使用受控历史，不能用于真实收益结论。

| 需求 | 验证内容 | 测试位置 | 结果 |
|---|---|---|---|
| AT01–03 | 目标到达、预测窗口结束、硬截止优先 | `test_smart_acceptance.py::test_at01_03_forecast_window_and_hard_deadline` | 通过 |
| AT04 | 到期不突破严格分辨率要求 | `test_smart.py::test_strict_minimum_never_relaxes_and_no_new_window_after_deadline` | 通过 |
| AT05 | 排列、刷新和新候选不重置窗口 | `test_smart.py::test_permutations_refresh_and_deadline_are_stable` | 通过 |
| AT06、09、14 | 重启、索引清理、暂停恢复；无候选不续期；发现时间为起点 | `test_smart_subscription.py`、`test_smart_acceptance.py` | 通过 |
| AT07–08 | 同系列优先；单集替代不改变下一集跟随 | `test_smart_acceptance.py::test_at07_08_episode_fallback_keeps_season_follow` | 通过 |
| AT10 | 三路同时评估只建立一个在途意图 | `test_smart_acceptance.py::test_at10_concurrent_discovery_and_timer_only_one_intent` | 通过 |
| AT11 | 开启洗版才升级；同档不重复洗版 | `test_smart.py::test_upgrade_disabled_and_same_quality_stop`、入库与投递测试 | 通过 |
| AT12 | 整季包不能越过其他单元等待；仍可选择合格单集 | `test_smart_acceptance.py::test_at12_pack_cannot_bypass_waiting_or_strand_ready_single` | 通过 |
| AT13 | 独立集数去重；属性修正不倒写历史；站点故障不等于品质失败 | 预测去重、观测版本、系列切换、真实下载器离线恢复测试 | 通过 |
| AT15 | 延期需要版本；共享设置不覆盖已有快照 | `test_smart_subscription.py`、`test_smart_acceptance.py` | 通过 |
| AT16 | 认领后退出、响应丢失、恢复不重置截止 | `test_smart_acceptance.py`、`test_smart_downloader_lab.py` | 通过 |
| AT17–20 | 两类首次设置、复用、隔离；未保存不能订阅 | 真实 API 测试、浏览器完整流程 | 通过 |
| AT21–22 | 旧数据库、旧客户端、同批两种模式独立执行 | 迁移测试、API 测试、同批混合模式测试及旧模式回归 | 通过 |
| AT23–25 | 两轴均达标才停止；替换不退步；实测不符保留旧版 | 全组合品质测试、真实文件核验、真实下载器实验 | 通过 |
| AT26–29 | 电影独立设置、6 小时观察、目标到达即选、快照与入库停止 | 电影服务测试、API 测试、手机浏览器流程 | 通过 |

纯算法测试位于 `tests/matcher/`，其余服务与接口测试位于 `tests/api/`。浏览器测试位于 `tests/e2e/test_smart_subscription_browser.py`。

## 4 可靠性证据

| 场景 | 结果 |
|---|---|
| 人工延期与自动认领，分别让两方先写入 | 只有当前版本成功；另一方冲突退出 |
| 认领竞争失败 | 保存点只撤回本次认领；同批其他订阅上下文仍可用 |
| SQLite 并发写入 | 保存点先执行条件写入，避免读快照升级写锁；并发专项在 12 个独立测试进程中通过 |
| 原有主源停滞，智能模式试用替代源 | 新建可恢复试用意图；不提前改写主源关联 |
| 取种后发现与已有任务 hash 相同 | 网络提交前结束重复意图；释放首次认领，排除该候选 |
| 延期数据库写入失败 | 回滚后截止和版本保持原值，不显示已经执行 |
| 用户暂停或移出范围 | 过时决定不能认领或新提交 |
| 候选变为无做种 | 立即下载接口返回冲突，不能绕过重新核验 |
| 智能执行关闭、影子模式、快照损坏 | 不回落为旧规则自动下载 |
| 原始索引清理 | 缓存仍保留合格候选、观测版本与原截止，可由定时器继续处理 |
| 宣称 4K，实测 1080p | 旧版本保留；不标记达标 |
| 片源未知或冲突 | 不虚构片源核验结果，不用它推进停止状态 |

真实协议实验使用独立 Docker qBittorrent、自生成的 2 秒视频、独立 HTTP 种子源和临时数据库。实验不访问用户站点或下载器。

实验先让真实下载器接收任务，再丢弃成功响应。随后关闭测试站点并暂停订阅，使用新数据库会话恢复。系统通过 hash 找回同一任务，下载器中只有一份任务。视频下载完成后，通过实际探测和库扫描入账。随后提交宣称 4K、实际 1080p 的第二份测试资源；核验后旧文件及原有工单关联仍保留，洗版目标未达成。

测试使用固定下载器镜像摘要。测试结束自动移除其独立容器。文件静默时间在测试中前移，不虚构下载完成状态。

## 5 页面与性能证据

浏览器测试使用真实 Chrome、Next 页面、FastAPI 和临时 SQLite。外部元数据使用固定夹具，浏览器流程中的下载为模拟投递；真实下载协议由上一节单独验证。

已验证桌面 1440 像素和手机 390 像素：首次设置、保存、修改后取消、复用、确认订阅、查看等待、延期、立即下载、电影与剧集隔离。没有页面脚本错误或横向溢出。截图等待启动遮罩完全透明后保存，并已人工查看。

| 参考开发机负载 | 结果 |
|---|---|
| 10,000 单元，100 条到期，无合格候选 | 约 0.56 秒 |
| 10,000 单元，100 条到期，100 个合格候选 | 约 8.06 秒，完成 100 个单元的选择和模拟投递 |
| 到期 SQL 查询计划 | 使用 `ix_wanted_smart_due` 索引 |

性能数值来自本机单次受控场景，不是生产 NAS 的百分位延迟。候选负载测试不包含网络取种和真实下载耗时。30 秒调度间隔加上述本地处理时间，符合此参考场景的 60 秒决策延迟门槛；下载完成时间不在该承诺内。

## 6 回放与效果验收

精确回放从去除下载地址的冻结输入重建决定。序列回放按 `observed_at` 推进时间，并在资源事件之间执行到期事件。旧规则、固定观察基线和统计预测分别维护自己的等待、在途与库存状态。之后出现或之后修正的资源属性不能提前参与选择。

序列回放的单位是同作品同季的一个单元；输入须先通过共同身份和覆盖范围检查。支持资源出现及属性更新、资源移除、暂停、恢复、显式延期、实际入库和时间推进。包覆盖约束由服务端到端测试验证，不在该单单元回放器里伪造。

报告区分标称达标、真实匹配入库、待观测结果、决策等待时间和有实测值的下载字节。某策略选择了历史上未下载的候选时，不能复用其他候选的入库结果；字节未知保留为 `null`。旧规则离线对照只比较首次选择，洗版的真实执行由现有回归和协议实验验证。

受控序列证明：在相同资源序列上，旧规则立即提交，固定基线在 30 分钟提交，预测策略可以按历史在 2 小时等到目标；结束时间之前不可见的资源不会泄漏。此结果只证明工具和算法工作，不证明真实等待值得。

命令行入口：

```sh
python -m movieclaw_matcher.smart_replay_events events.json --output report.json
```

输入包含 `policy`、`rules`、`events`、`end_at`，可选 `episode`、`following`。事件结构和可复现样例见模块说明及 `tests/matcher/test_smart.py` 中的序列回放测试。

尚未完成的真实效果验收：按电影、周播、日播、新剧、旧剧、整季、稀缺资源和站点异常收集观测；按作品划分留出集；报告品质、连续性、等待、重复下载、预测覆盖与宽度、请求量及运行成本。没有这批数据，不能判断收益、给出提升比例或开启预测。当前继续使用无需预测的基线，符合技术方案的退路，但不把效果门槛标成已通过。

## 7 测试结果与复现

| 检查 | 最终结果 |
|---|---|
| 后端、算法、迁移与相关旧功能回归 | 490 通过；1 项真实下载器实验在独立命令运行 |
| 隔离真实下载器实验 | 1 通过，包含响应丢失恢复、探测入库与旧文件保护 |
| 桌面与手机完整浏览器流程 | 1 通过，覆盖两种屏幕与两类订阅 |
| 前端现有测试 | 854 通过 |
| 改动文件 Ruff、ESLint、TypeScript | 通过 |
| Next 生产构建 | 通过 |
| Git 补丁空白检查 | 通过 |

后端回归有 6 条 aiosqlite 测试线程在事件循环结束后返回的警告。测试断言没有失败，但不能把本轮称为零警告。真实下载器和浏览器专项分别通过。生产构建仍提示现有非本次改动组件的 lint 警告。

本机证据保存在 `/tmp/movieclaw-smart-final-regression.log`、`/tmp/movieclaw-smart-real-final.log`、`/tmp/movieclaw-smart-browser-final.log`、`/tmp/movieclaw-smart-build-final.log`、`/tmp/movieclaw-smart-web-tests-final.log`。四张稳定页面截图位于 `/tmp/movieclaw-smart-evidence/`。这些是本地运行证据，长期复现以仓库中的测试为准。

```sh
python -m pytest tests/matcher tests/api/test_smart*.py \
  tests/api/test_subscription_pipeline.py tests/api/test_subscription_service.py \
  tests/api/test_subscription_routes.py tests/api/test_upgrade*.py \
  tests/api/test_manual_upgrade.py tests/api/test_subscription_replacement.py \
  tests/api/test_rule_set_scope.py tests/api/test_subscription_release_forecast.py \
  tests/api/test_release_forecast_prefilter.py tests/api/test_library_duplicates_e2e.py \
  tests/api/test_subscription_scope_migration.py -m 'not integration' -o addopts='' -q
MOVIECLAW_SMART_LAB=1 python -m pytest tests/api/test_smart_downloader_lab.py -m integration
python -m pytest tests/e2e/test_smart_subscription_browser.py -m integration
pnpm --filter web test
pnpm --filter web exec tsc --noEmit
pnpm --filter web build
```

真实下载器实验需要 Docker 与 FFmpeg。浏览器实验需要 Playwright 与 Chromium 或本机 Chrome。测试只使用自行启动的临时服务。

## 8 上线和回退边界

本轮没有修改用户运行中的数据库，没有部署，没有提交或合并 Git 变更。

`subscription.smart` 的 `enabled` 控制新自动选择，`shadow_only` 控制仅记录决定，`prediction_enabled` 默认关闭。关闭自动选择后，已有下载的对账和入库继续完成。恢复时仍使用原有快照和截止。

迁移测试覆盖旧数据库升级、规则关系及触发器保留、无智能数据时降级、旧迁移目录拒绝新版本，以及备份恢复后旧版本启动。有智能订阅或智能设置时禁止直接降级，应恢复完整备份；不能只退前端或让旧程序消费空规则组。

## 9 预览功能撤回（2026-10-07）

按产品决定，移除智能订阅试订阅入口、页面、临时预览、报告和反馈接口，以及专用测试与演示代码。正式订阅的选择、等待、跟随、洗版及自动化回归继续保留。

已部署的迁移 `f8316ab24d90` 保留历史。后续迁移 `c9a72e4d6b10` 删除报告与反馈表；不修改正式订阅、策略、工单、决策或下载记录。降级仅恢复空表，历史报告只可从部署前备份恢复。

## 10 完结包与同品质多组修订（2026-10-07）

本节记录完结包修复验收。先前的未部署说明属于当时阶段。

- 全季缺失时，同品质完整包先于热门单集；交换候选顺序不改变结果。
- 同品质多组按既有跟随、版本覆盖、成功核验、单资源覆盖、做种数、固定标识决胜。镜像不累加独立集数。
- 已有在途集时，整包只认领缺失集；已有目标品质时不洗版。单集等待仍有效。
- 严格文件规划拒绝未知、缺集、重复或不可拆分的视频；不把模型推测用于文件选择。
- 真实 qBittorrent 实验使用自制 18 文件种子，只启用 E16–E18；选文件后中断再恢复，任务 hash 与数量保持一致，E01–E15 的完成字节为零。通用 BT 分片边界可能带来少量附带数据。
- 超时、暂停订阅、设置失败和回读不一致均不触发全量恢复。重试相同意图。

本次后端相关回归 419 项通过、1 项需显式启用的 Docker 实验跳过；该真实下载器实验单独启用后通过。浏览器完整流程通过。证据日志：`/tmp/smart-pack-regression.log`、`/tmp/smart-pack-docker.log`、`/tmp/smart-pack-browser.log`。NAS 发布版本和现场复核结果另存 `output/smart-subscription-lab/nas-deployment/`。

## 11 智能选择状态文案

详情页以当前收录范围内的工单为基数，显示实际入库核验进度。只有 `imported` 且 `target_reached=true` 才计入“已达标，已停止洗版”；已选中 4K 种子不等于已完成核验。未入库、未达目标、品质未知及暂不自动洗版分别显示，电影使用“正片”。全部达标时不再显示继续查找升级版本。关闭洗版仍显示“不自动洗版”。

前端单元测试覆盖 9/18、18/18、文件丢失、未知品质、暂停洗版、电影和空范围。浏览器通过真实 API 和临时数据库验证部分完成、全部完成及手机布局。

## 2026-10-07 等待证据与真实资源回归

本次固定 10 次搜索、9 部作品、6 个站点的 1,484 条结果，以及 20 份原订阅决策输入。数据位于 `tests/fixtures/smart_waiting`。仅保存脱敏字段。各站第一页结果不等于完整历史。

- 10 个代表单元经过共同身份检查，保留 474 个匹配候选，其中 460 个满足当前智能最低要求。品质档位与人工验收值一致，打乱候选顺序不改变结果。
- NAS 34 的 E01/E02 在原始发现时刻回放，均直接选择 `mteam/1266198`。原实现额外观察 30 分钟，本修订为 0；4K WEB-DL 目标不变。
- 受控时间序列：固定观察策略在 30 分钟选择 1080p；有三集以上历史支持的策略在 60 分钟选到新到达的 4K。45 分钟截断回放时，未来 4K 不可见。
- 回归测试：163 项后端通过，1 项需独立下载器环境的集成测试跳过；39 项相关前端测试通过；订阅与试验室两条浏览器端到端流程通过。构建完成类型检查与生产打包。
- 正式链路使用隔离数据库与干跑投递。正式链路为真实 NAS 两集数据生成预期选择，只生成一个合包任务；重复触发不增加任务。

证据目录：`output/smart-subscription-lab/waiting-evidence/`。其中 `replay-results.json` 记录各作品的候选数、选择及时间来源；`browser/nas-old-release.png` 记录旧资源立即选择后的页面。

边界：这些结果不证明真实下载速度、入库成功率、长期洗版字节收益或全局最优。新预测使用保守历史门槛；实际效果仍需连续、按时间留出的线上记录验证。人工延期、严格分辨率、已入库和在途保护均保持有效。

本次新增状态字段与发布时间来源不被旧版严格状态解析器识别。回退开发版时，应同时处理这些 JSON 状态的兼容性；不能仅凭 SQL 迁移版本相同，就假定旧版可以继续智能选择。部署前在线备份保留，恢复前必须确认期间新增数据的处理方式。

线上复核：开发版 `0.32.1-dev.20261007.124535` 在 NAS 健康运行，spec `cb467c0a6458bcf6`，启动错误为 0。线上试验室报告 4 重新搜索后，E01/E02 立即拟选 `mteam/1266198`，E03–E05 暂无选择且未启动品质计时。原订阅 34 在部署前已不存在，未重建实际订阅。完整部署与业务记录见 `output/smart-subscription-lab/waiting-evidence/deployment-receipt.json`。

## 2026-10-07 分集交互归并验收

独立智能分集卡片和重复进度汇总已移除。目标和后续洗版设置进入原页头配置区。普通待播、待搜索、下载和洗版继续由原列表表达；仅有智能候选或提交核对时，在该集原「搜索」节点显示依据、候选、时间和操作。独立区域仅保留智能执行全局异常。

验收使用真实页面、接口和隔离数据库。覆盖原季折叠、展开原集行后延期与立即下载、逐集核验达标、五集混合状态（洗版、在途、缺资源、待播），以及桌面与手机布局。断言每集只有一行，无智能重复区域；没有候选的集不增加智能说明。相关前端单测 38 项通过。浏览器和构建记录保存于 `output/smart-subscription-lab/unified-status`。
