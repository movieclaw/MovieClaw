# 发布前验证记录

执行基线 `a4559c65d`，加本地版本/说明修改。开始于 2026-10-25，检查跨午夜到 10-26。结论：**准备材料可审阅，当前不放行正式发布**。

本机：macOS arm64，Python 3.14.6、Node 26.10.0、pnpm 10.32.1、Go 1.27.1、Xcode 27.1、Java 25.0.1。CI 使用 Python 3.11/3.12、Node 22、Java 21，存在环境差异。安装依赖时使用 frozen pnpm 锁文件，没有执行 audit fix 或刷新锁文件依赖版本。

完整命令输出保存在 `/tmp/movieclaw-release-prep/`；属于本机临时证据，不是正式构建附件。

## 本次本地检查

| 检查 | 结果 | 证据 / 限制 |
|---|---|---|
| git fetch、最新主线、stash | 通过 | main 的 `work/` 保留在 stash `1e25b8444c5524431d223568e87652914d42694f` |
| 版本文件/Windows 锁文件/spec 一致性 | 通过 | `version-notes-check.log`；7 份新 changelog 正确解析中英文；两份 OpenAPI 字节相同 |
| Release 说明解析测试 | 11 通过 | `release-info.log` |
| Release 状态脚本测试 | 4 通过 | `release-status-test.log` |
| Apple 构建脚本/依赖锁约束测试 | 8 通过 | `apple-scripts-direct.log`；不等于 App UI 或签名验证 |
| Ruff | 通过 | `ruff.log` |
| Web ESLint | 通过，45 warnings | `web-lint.log`；没有 errors，未顺手清理既有警告 |
| Web 语言/画面模式定向单测 | 32 通过 | `web-targeted.log` |
| Web 全量单测 | 1123 通过 | `web-test-final.log`，TZ=Asia/Shanghai |
| 真实语言浏览器 E2E | 主流程通过，另一项超时 | `i18n-e2e-retry.log`：1 passed / 1 failed；初始化→错误登录→中英文切换→账号保存→主题→多浏览器通过，开发伪语言页导航超时 |
| HEVC HTTP/ffmpeg E2E | setup error，未运行播放断言 | `hevc-api-final.log`；测试夹具引用已不存在的符号，详见下 |
| Web 生产构建（含类型检查） | 通过 | `web-build.log`；完整 `pnpm web:build` 返回 0，保留既有 JASSUB 循环 chunk 警告 |
| Netflix 主题构建 | 通过 | `web-build.log` 前段输出 `netflix v1.2.0` |
| Chrome / Firefox 扩展 ZIP | 通过 | `extension-chrome.log`、`extension-firefox.log`；版本仍 0.1.0 |
| Go vet | 通过 | `go-vet-final.log` |
| CLI 六平台交叉编译 | 通过 | linux/darwin/windows × amd64/arm64，`/tmp/movieclaw-release-prep/mclaw-*`；静态 CGO_ENABLED=0，注入 0.43.0 |
| Go 全部单测 | 未通过 | `go-test-final.log`，仅 UDP discover 两项失败，见下 |
| Windows 播放器 JS 单测 | 112 通过 | `desktop-test.log` |
| Windows 播放器完整浏览器套件 | 未完整通过 | 初跑 32 通过、3 超时、1 中断、87 未运行；本轮约 11 分钟后停止 |
| Windows 播放器重点浏览器复测 | 4 通过 | `desktop-focused.log`；新建订阅 + 上述 3 个超时场景，timeout 从 30 秒调为 120 秒，无业务断言改动 |
| Windows 转码器单测 | 242 通过，2 跳过 | `windows-transcoder-unit.log`；跳过的是 Windows 注册表自启测试，不能当 Windows 真机通过 |
| 服务端/语言/迁移等组合定向测试 | 未完整通过 | `targeted-pytest.log`：272 通过、1 失败、1 setup error、2 跳过后中断；失败详见下 |
| 全量 API/i18n/playback/scripts xdist | 未完成 | `pytest.log`：worker 启动/收集持续约 12 分钟，无用例完成，已中止；不能报告全量回归通过 |
| i18n 全量静态门禁 | 未完成 | `i18n-check.log`：首次约 21 分钟未结束；释放并发资源后重跑约 6 分钟仍未结束（`i18n-final.log`），均已中止；不记为通过 |
| Web 独立 typecheck | 未完成 | `web-types.log`：约 12 分钟仍未结束，已中止；后续生产构建内的类型检查已通过 |
| iOS Release 无签名构建 | 未完成 | `apple-ios.log`、`apps/apple/build-ci/MovieClaw.log`；21 分钟仍在依赖/引擎编译，已中止 |
| Android 手机单测/lint/debug APK | 未完成 | `android.log`；21 分钟后仍在 Gradle 任务，已中止，无 APK 放行结论 |
| Android TV 单测/lint/debug/release | 未完成 | `android-tv.log`；15 分钟仍在 Gradle 任务图阶段，已中止 |
| Mac / TV 本地候选版本 Release 构建 | 未执行 | 本次使用已有精确主线 CI 作为源代码基线证据，不等于候选版本已本地验证 |
| Docker / NAS 两架构最终镜像、更新三件套 | 未完整构建 | 不声称本地 Web/CLI 构建等同最终镜像验证；需 `build-release-artifacts.sh` 和镜像 PGS→SRT 冒烟 |
| Windows Rust、NSIS 安装、签名、公证、商店 | 未执行 | 本机没有 Windows 环境和 Rust 工具链；没有调用签名/上传命令 |

`release-status.py` 在本地提交后显示各拟发布组件“版本号已递增，可以发”，它只检查版本与路径差异，不代表本报告中的发布门禁已通过。i18n 复跑的中断栈位于 `unused_keys()` 提示扫描；按脚本控制流，词条与棘轮检查未报错，但完整命令没有正常返回 0，仍标为未完成。

## 已明确的阻塞项

### 依赖审计仍有 4 条公告

`pnpm audit --prod --json` 的结果：2 high、2 moderate、0 critical。都来自 **`apps__web > next > postcss@8.4.31`**，而非直接依赖中新版 postcss。

| 公告 | 严重度 | 审计给出的修复版本范围 |
|---|---|---|
| [GHSA-qx2v-qp2m-jg93](https://github.com/advisories/GHSA-qx2v-qp2m-jg93) | moderate | >=8.5.10 |
| [GHSA-6g55-p6wh-862q](https://github.com/advisories/GHSA-6g55-p6wh-862q) | high | >=8.5.12 |
| [GHSA-fxqj-rqcc-2cmp](https://github.com/advisories/GHSA-fxqj-rqcc-2cmp) | moderate | >=8.5.23 |
| [GHSA-r28c-9q8g-f849](https://github.com/advisories/GHSA-r28c-9q8g-f849) | high | >=8.5.18 |

证据 `pnpm-audit.json`。需要修复或完成明确的可达性评估后决定放行；审计严重度不等于已证实 MovieClaw 存在可利用的远程攻击路径。此项也不等于本次版本 bump 引入了漏洞。没有擅自加入 pnpm override。

### 测试失败与未完成项

- CLI `TestFindMergesBothRepliesFromOneServer` / `TestFindWorksWithOldServers`：本机网卡来源 192.168.1.127、192.168.64.1、10.211.55.2、10.37.129.2 导致同一个测试响应者被列为 4 台；预期 1 台。该目录相对 v0.42.0 无代码差异，但本次仍不能认定多网卡发现行为正确。需隔离网络复测并确认用户可见影响。
- 首次 CLI 测试还读到了旧 spec；完成本次 OpenAPI 导出后重新跑，命令树/spec 守卫通过，只剩上述两项。旧 spec 那轮不作为最终结果。
- Windows 转码器组合测试 `test_progress_is_reported_as_soon_as_ffmpeg_prints_it` 首条进度 2.62 秒，断言 <2.5 秒；停止并发的重构建后，独立 242 项复测通过。保留首次时限失败记录，不声称完成真机 NVENC。
- 组合 API 测试首次初始化在建立迁移模板数据库时超过 90 秒；独立迁移链已通过，不把这次 setup 超时直接判为迁移数据错误。标准 API 回归仍需在 CI 同款环境复跑。
- Windows 浏览器初跑三项超时：关闭已提交弹窗、下载完成快照、超过 200 条的媒体分页。单独将单项 timeout 调到 120 秒，三项及新增订阅场景均通过；完整 123 项套件仍需补跑。
- **HEVC E2E 的确定性阻塞**：独立重跑 `tests/api/test_playback_hevc_e2e.py`，第 66 行 monkeypatch `movieclaw_api.api.routes.playback.remote_worker_available` 抛 AttributeError，该符号已不存在。首个测试在 setup 就报错，尚未执行转码/分片断言。普通 CI 排除了 integration，绿色 CI 不覆盖此缺口。需修正夹具与当前路径、重新验证 HEVC/H.264 回退；本次只记录，没有掩盖错误或改生产代码。该测试即使通过也用软件编码替代 GPU，仍不能代替硬件矩阵。
- i18n 浏览器首次独立测试在后端 90 秒就绪期限内失败；api.log 显示后端随后迁移完成、67 个插件启动、数据库就绪，未进入浏览器业务断言。复测通过 `/tmp/movieclaw-release-prep/readiness_plugin.py` 仅将 API/Web 就绪等待下限放宽到 300 秒，业务断言不变：`test_language_end_to_end` 通过；`test_development_pseudo_and_localized_manifest` 在 `/login?add=1&locale=pseudo` 的 Page.goto 30 秒超时，未算通过。源码测试文件没有修改。

### 实机与渠道

- NAS：VAAPI、QSV、NVENC 的 HEVC/H.264、强制 IDR、seek、HDR→SDR、失败回退和并发；无显卡的软件兜底。Safari/iPhone 原生 HEVC、ASS/SRT、字幕与续播。
- Windows 转码器：真正 Windows/NVIDIA、设备配对/撤销/重连、首次 ffmpeg 下载、托盘、自启、安装/卸载、签名与 SmartScreen；打包脚本没有 Authenticode 步骤。尚缺独立发布工作流与下载清单识别。
- Apple：签名 archive、Developer ID、公证、Sparkle 更新签名；iPhone/iPad 两种布局、后台/旋转；Mac 英文与旧版升级；TV 完整英文页面和遥控器。商店版本/构建号没有独立核验。
- Android：沿用正式证书、APK 内完整 native FFmpeg；Wi-Fi/后台续传、账号隔离、平板；TV 桌面主页深链、焦点、屏保、开机晚联网；实机从上一正式版本覆盖升级。
- 新旧服务器/客户端的完整组合尚未覆盖；不能仅凭最低版本常量未改就声称兼容已验证。

## 数据库升级实测

独立库 `/tmp/movieclaw-release-prep/upgrade.db`，未读取或迁移现有业务库。

1. 从空库升级到 v0.42.0 的头 `d7a2e4f9c615`。
2. 写入 `release-prep-sentinel` 配置，含中文值与布尔值。
3. 升到新头 `c6f14d3a9b72`（17 个新增迁移）；`alembic heads` 仅一个头。
4. 检查配置值完整保留、`PRAGMA integrity_check=ok`、`foreign_key_check` 无错误。

结果通过，见 `migration.log`。这不是大规模生产库升级或完整备份恢复演练；发布前仍须以备份副本检查真实数据量、磁盘和耗时。没有执行生产降级，回退建议是旧镜像配套恢复备份。

## 已有精确主线 CI（只读核对）

以下 GitHub 检查在提交 `a4559c65d` 上成功；不是本地 release-prep 修改后的新 CI，也不是发布 workflow：

- [CI：Python / CLI / Web / i18n / Mac Worker](https://github.com/movieclaw/MovieClaw/actions/runs/40206753712)
- [Apple 三端](https://github.com/movieclaw/MovieClaw/actions/runs/40206753732)
- [Android 手机](https://github.com/movieclaw/MovieClaw/actions/runs/40208515514)
- [Android TV](https://github.com/movieclaw/MovieClaw/actions/runs/40208515519)
- [Runtime guard](https://github.com/movieclaw/MovieClaw/actions/runs/40206753689)
- [watch-presence 插件契约](https://github.com/movieclaw/MovieClaw/actions/runs/40208515520)

另有 Dependabot 自动更新工作失败，不能把它与已成功的产品 CI 混为一谈。发布准备分支合入前仍需新 CI 全绿；本次遵守不 push，未触发远端检查。
