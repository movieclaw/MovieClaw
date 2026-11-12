# 2026-11-12 发版准备

检测基线为 `origin/main@40e3163ae`。已先执行 `git fetch --tags origin` 并确认 HEAD 与最新 `origin/main` 一致，
再运行 `scripts/release-status.py --ref HEAD --offline`，并用 `scripts/release-surface-diff.py` 分别对照各产品上一个正式 tag。

本 PR 只准备六个客户端的版本号、双语更新说明和发版记录；tag 只在 PR CI 全绿并 rebase-merge 后创建。
本会话不运行 Apple 打包，不上传 TestFlight，不提交 App Store 审核。

## 发布范围

| 组件 | 上一版 | 新版 | tag | 依据 |
|---|---|---|---|---|
| iPhone / iPad | 0.13.0 | 0.14.0 | `ios-v0.14.0` | 本地 / NFO 库的无影人页演员可直接打开同库按演员筛选的海报墙，是新能力。 |
| Mac | 0.13.0 | 0.14.0 | `macos-v0.14.0` | 同上；演员条件显示在库名下，可从媒体库菜单移除。 |
| Apple TV | 0.13.0 | 0.14.0 | `tvos-v0.14.0` | 同上；遥控器可从演员卡进入筛选墙，并从排序与筛选菜单移除。 |
| Android | 0.10.0 / 30000018 | 0.11.0 / 30000019 | `android-v0.11.0` | 新增同库演员墙；修复 0.10.0 关闭选集、返回或换集时必现的闪退。 |
| Android TV | 0.8.0 / 15 | 0.9.0 / 16 | `androidtv-v0.9.0` | 新增遥控器操作的同库演员墙。 |
| Windows | 0.1.4 | 0.2.0 | `windows-v0.2.0` | 本地 / NFO 演员卡支持鼠标和键盘进入同库筛选墙。 |

六个客户端的新能力都使用服务器从 0.48.0 起已有的 `actor` 查询参数；客户端最低登录版本不变，说明中单独写明
演员筛选墙需要服务器 0.48.0。Apple 三端共用 `MARKETING_VERSION`，三端都有同一项用户可见新能力，因此一起升到 0.14.0。

## 本轮不发布

- 服务器：`v0.50.0` 后有同步插件隐藏「接下来继续」的新能力和 VAAPI seek 修复，原则上值得发布；但
  `src/movieclaw_api/services/playback/ffmpeg_args.py` 修改了 VAAPI / QSV / NVENC 全 GPU 链，PR #1263 只记录了修复前的
  NAS 真机复现与单元测试，修复后的 NAS seek 复测仍列为待办。仓库发版规范要求播放 / 转码改动在发布前完成人工硬件验收，
  因此不 bump、不打 server tag，也不改 Docker 标签。
- Mac 转码器：0 个产品文件变化，握手协议仍为 1。
- HarmonyOS：代码有同库演员墙，但正式签名与工具链仍未就绪；不发布未签名 HAP。
- NER 模型：没有独立产物变化。

## 说明盘点

| 来源 | 维度 | 用户可感知变化 | 写入或取舍 | 证据 |
|---|---|---|---|---|
| #1247 | 新能力 | 本地 / NFO 演员没有在线影人页时，点演员进入同库按姓名筛选的海报墙 | 六份客户端亮点 | 各端详情页、演员路由与墙面筛选实现 |
| #1247 | 前提 | 演员筛选接口从服务器 0.48.0 起可用；客户端最低登录版本不变 | 六份提示框 | #1193 首次进入 `v0.48.0`；各端 minimum server 常量未改 |
| #1247 | 范围 | 有在线影人页的演员仍进影人页；无影人页导演不跳转；演员条件可移除且不写入墙面偏好 | 六份亮点 | `CastLink`、Android / TV / Desktop 对应分支与回归测试 |
| surface diff | 新文案 | Android 新增「在本库查看…」「演员：…」「移除演员条件」；Android TV 新增演员摘要与移除项 | 对应说明写真实入口 | surface diff 输出 |
| surface diff | 拿走 | 六个客户端均无消失的界面文字 | 无需写升级提醒 | surface diff 输出 |
| #1266 / #1264 | 修复 | Android 0.10.0 打开选集后，关闭、返回或换集会因动画越界闪退 | Android「修好了」 | 0.10.0 原代码、issue 真机堆栈、Robolectric Compose 回归 |
| #1247 周期内修正 | 不写 | Android 摘掉演员后切页签 / 进程恢复不会把条件带回来 | 新功能发布前修正，用户未在正式版遇到 | `TabRouteChainTest` |

## 验证与风险

- #1247 合入前：Apple iOS / tvOS / macOS Debug 均构建成功，Apple 新测试 10/10；Android 手机、Android TV、Windows
  的单元、E2E、lint / build 与 Windows 安装包 CI 均通过。
- #1266：Android `PlayerEpisodeDrawerTest` 覆盖同参数弹簧越界和实际 Compose 退出动画，Android stability CI 全绿。
- 本地 release scripts：项目 Python 3.14 下 51/51 通过；系统 Python 3.9 缺少 `hashlib.file_digest`，不作为项目失败。
- 本地 Android 手机演员墙 / 路由恢复 / 选集退出回归与 Android TV 演员墙回归：串行执行均通过。
- 本地 Windows 单元测试 118/118；浏览器 E2E 126/127。与本轮直接相关的「本地演员 → 同库筛选墙 → 清除」通过；
  唯一失败是未改动的「最近入库从首个未看单元播放」没有及时观察到 session 请求，单例重跑一次仍失败。
  同一测试在 #1247 Windows CI 通过；不修改无关测试，以发版 PR 的 Windows CI 为最终门槛。
- 发版 PR 将运行 release scripts、版本 / changelog 格式、Android / Android TV、Windows 单元与 E2E；GitHub 全量 CI
  全绿才合并。只对 `test_entrypoint_supervision` 或 Harmony HAP inspect 这类已知 flaky 作业重跑一次。
- 待真机复核：六端本地 / NFO 演员墙的实际触控 / 遥控器手感；Android 选集退出修复已有真实崩溃证据与渲染回归，
  但修复后尚未在同一真机复测。
- server 的硬件转码复测是本轮唯一阻塞项，已通过缩小发布范围规避，不会创建 server tag。

## 合并之后

见 `commands.md`。六个 App tag 必须指向本次 rebase-merge 提交。所有 App Release 都应公开、不是 prerelease、
且 `latest=false`；`releases/latest` 与 Docker 的 `v0.50.0`、`latest`、`runtime-25` 应保持不变。
