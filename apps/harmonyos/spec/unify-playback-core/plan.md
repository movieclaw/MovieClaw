# Implementation Plan: 统一多端播放器内核（unify-playback-core）

**Input**: Feature specification from `spec/unify-playback-core/spec.md`

## Summary

将 TV 端与车机端播放器从旧自研引擎（`entry/src/main/ets/common/AvPlayerEngine.ets`，TV/Car 共用，仅 AVPlayer）迁移到与手机/平板相同的统一播放内核：`playback` HAR（编排控制器 + 会话协调 + 播控合规层）+ `player_engine` HAR（AVPlayer/MPV 双引擎接口与实现）。手机端播放器刚修复完成，本计划**对手机端播放链路做零结构性改动**（仅共享库小幅增强），TV/车机各新建一个轻量"设备播放宿主"（viewmodel）粘合统一内核与各自 UI，并补齐倍速菜单与引擎选择入口。平板随手机链路自动达成统一。

## Technical Context

**Language/Version**: ArkTS（HarmonyOS SDK 6.1.1(24)，兼容 API 24）
**Primary Dependencies**: `@movieclaw/playback`（HAR，编排）、`@movieclaw/player-engine`（HAR，引擎边界 + C++ libmpv NAPI）、`media.AVPlayer`、AVSession/后台长时任务
**State Management**: 项目现有 State Management V2（`@ObservedV2`/`@Trace`/`@Monitor`），增量工作完全保留 V2，不引入 V1
**Storage**: 用户偏好 `player.engine.v2`（引擎选择，全端共享同一键）、画质/字幕样式记忆（现有）
**Testing**: `devecocli build` + `arkts_check` 编译验证；真机（Pura X View）手机回归；TV/车机模拟器（x86，MPV 为 stub）流程验证；既有 ohosTest E2E 探针（`PlaybackTestProbe`）可在真机复用
**Target Platform**: HarmonyOS phone / tablet / tv / car（共享库 module.json5 已声明全设备类型，无需改模块配置）
**Project Type**: 既有 HarmonyOS 多模块工程（entry HAP + playback HAR + player_engine HAR）
**Performance Goals**: 起播≤25s 看门狗内完成（统一内核既有 deadline）；换集/降级不黑屏超过 1s；车机行车锁切换 0 音频中断
**Constraints**: 手机端播放链路（PhonePlaybackHost 及其下游）不得结构性重构；各端 UI 交互形态不变
**Scale/Scope**: 改造 2 个端（TV/Car）约 6 个既有文件接缝 + 新增 5-6 个文件；删除 3 个旧引擎文件 + 1 个死代码文件

## Project Structure

### Documentation (this feature)

```text
spec/unify-playback-core/
├── spec.md              # 需求规格
├── plan.md              # 本文件
└── tasks.md             # 任务拆解（Phase 3 生成）
```

### Source Code (repository root)

```text
apps/harmonyos/
├── playback/src/main/ets/
│   ├── PlaybackController.ets        # [增强] 无改动或极小改动
│   ├── SystemPlaybackBridge.ets      # [增强] PlaybackGuard 补 playPrevious/playNext 播控指令回调
│   └── （其余不动）
├── player_engine/                     # [不动] 引擎接口/双引擎/工厂/NAPI
├── entry/src/main/ets/
│   ├── playback/                      # 手机端宿主目录（PhonePlaybackHost 等不动，新增共享件）
│   │   ├── DeviceCapability.ets       # [新增] 按端+按引擎的能力口径与客户端标识（TV/Car 非移动端 profile）
│   │   └── TvCarPlaybackSession.ets   # [新增] TV/车机 PlaybackSessionPort 实现（上报/ping/stop，带 device_id 口径）
│   ├── tv/
│   │   ├── playback/TvPlaybackHost.ets     # [新增] TV 设备播放宿主（@ObservedV2 viewmodel）
│   │   │                                    #   静态 begin/adopt/end 协调 + PlaybackController/Guard/SessionCoordinator 粘合
│   │   │                                    #   暴露与旧引擎等价的 @Trace 状态（phase/positionMs/buffering/轨道/剧集）
│   │   ├── player/TvPlayerPage.ets         # [改造] engine→host 接缝；新增倍速菜单、引擎选择菜单项
│   │   ├── home/TvHomePage.ets              # [改造] Playback.begin 调用点 → TvPlaybackHost.begin
│   │   ├── detail/TvItemDetail.ets          # [改造] 同上
│   │   └── model/TvUiState.ets              # [改造] 移除旧引擎 appContext 注入
│   ├── car/
│   │   ├── playback/CarPlaybackHost.ets     # [新增] 车机宿主（同 TV）+ 行车锁 videoSurfaceVisible + mini 条承接
│   │   ├── player/CarPlayerPage.ets         # [改造] engine→host 接缝；新增倍速菜单、引擎选择菜单项
│   │   ├── components/CarMiniPlayer.ets     # [改造] 引用切到 CarPlaybackHost
│   │   ├── home/CarHomePage.ets             # [改造] begin 调用点
│   │   ├── detail/CarItemDetail.ets         # [改造] begin 调用点
│   │   └── model/CarUiState.ets             # [改造] 移除旧引擎 appContext 注入
│   ├── common/AvPlayerEngine.ets            # [删除] 旧 TV/Car 引擎（1499 行）
│   ├── tv/player/TvAvPlayerEngine.ets       # [删除] 旧别名层
│   ├── car/player/CarAvPlayerEngine.ets     # [删除] 旧别名层
│   └── player/PlaybackGuard.ets             # [删除] 无引用死代码
```

**Structure Decision**: 遵循既有项目架构（分层：各端 UI 目录 + `playback`/`player_engine` 共享 HAR + 各端 viewmodel 宿主），不引入 MVVM 迁移、不新建分层目录。TV/车机宿主沿用项目已有的"页面 + @ObservedV2 viewmodel"模式（对齐 PhonePlaybackHost 的既有模式），新增文件数控制在 3 个共享/宿主文件 + 页面内菜单改造，符合最小改动原则。倍速菜单与引擎选择入口落在各端既有播放页菜单层内，不新建页面。

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| TV/Car 各建一个 Host 而非共用 PhonePlaybackHost | 手机端刚修复，零结构改动约束 | 直接复用/拆分 PhonePlaybackHost 需重构手机链路，回归风险不可控 |
| 共享库 `SystemPlaybackBridge` 小幅增强 | TV/Car 播控需要 playPrevious/playNext 指令 | 各端自建 AVSession 壳会重新制造双实现，违背统一目标 |

## Research & Decisions

- **Decision**: 统一"内核"定义为 `playback` HAR + `player_engine` HAR + 统一偏好键；TV/车机各建轻量设备宿主（`TvPlaybackHost`/`CarPlaybackHost`）作为内核与 UI 的粘合层，复刻手机宿主的组装方式（Controller + Guard + SessionCoordinator + Media + Gateway）。
  **Rationale**: 手机播放器刚修复，不能为统一而重构手机链路；宿主层是"UI 配方"的一部分（各端交互不同），本就应各端一份；内核一致性由共享 HAR 保证。
  **Alternatives considered**: ① 抽取 PhonePlaybackHost 的"共享宿主核心"供三端继承——改动手机端，回归风险大，放弃；② 直接让 TV/Car 页面持有 PlaybackController——页面直接耦合内核，违背项目既有 viewmodel 分层，放弃。

- **Decision**: 新建 `DeviceCapability` 提供 TV/车机能力口径（非移动端标识、`client` 标识、device_id），与手机版 `MovieClawPlaybackGateway` 的按引擎动态申报机制合并使用：auto 模式下先按 MPV 能力探测 tier-0 直出，再按 AVPlayer 能力开会话。
  **Rationale**: FR-006 要求保留各端客户端标识但按引擎动态申报；现有 Gateway 的按引擎申报逻辑（`capability(engine)`）可直接参数化端口径。
  **Alternatives considered**: 沿用旧引擎写死的 AVPlayer 口径——无引擎维度，无法支撑降级协商，放弃。

- **Decision**: `PlaybackGuard`（`SystemPlaybackBridge.ets`）增加可选的 playPrevious/playNext 指令回调注册；手机宿主不注册（行为不变），TV/车机宿主注册后接入换集。
  **Rationale**: 旧引擎内建 AVSession 含上一集/下一集播控；统一后该能力必须保留（User Story 2/5）。回调式可选注入保证手机端零行为变化。
  **Alternatives considered**: TV/Car 各自直接操作 AVSession——双实现回归，放弃。

- **Decision**: 旧引擎的 `Playback.begin/adopt/end` 静态协调语义在 `TvPlaybackHost`/`CarPlaybackHost` 上以同名静态方法复刻（详情页预建 → 播放页接管 → 结束释放），车机"页面收起后引擎存活、mini 条承接"由宿主单例槽位 + surface 重协商承接。
  **Rationale**: TV/Car 的跨页面生命周期（详情页起播预建、Car mini）是既有 UI 形态，FR-003 要求保留；A 套 Controller 本身支持 surface 变化时原位重开。
  **Alternatives considered**: 改成手机式页面级宿主——Car mini 播放会中断，违背既有交互，放弃。

- **Decision**: 换集/连播在宿主内实现：结束当前会话（stop 上报）→ 经协商开新会话 → 恢复各集进度；TV 自动连播、Car 上下集播控走同一方法。
  **Rationale**: FR-007；旧引擎 `nextEpisode/switchToEpisode` 的语义与手机协商流程一致，宿主层组合即可，无需内核改动。
  **Alternatives considered**: 在 `playback` HAR 里加"剧集状态机"——三端连播策略差异（TV 自动连播 vs Car mini 播控）更适合留在宿主，避免共享库膨胀，放弃。

- **Decision**: 离线副本优先：TV/车机宿主复用与 `PhoneMedia` 相同的 fd 租约模式（离线命中 → 本机 fd 起播 → 失败回退服务器会话）。
  **Rationale**: FR-009；`PhoneMedia` 的 fd 租约 + 字幕时间轴平移逻辑与端无关，宿主层直接组装。
  **Alternatives considered**: TV/Car 不做离线优先——功能集不对齐，违背"内核功能都一样"，放弃。

- **Decision**: 引擎选择入口读写全端共享的 `player.engine.v2` 偏好键；TV/车机菜单提供与手机设置页相同的 auto/MPV/AVPlayer 三选一。
  **Rationale**: FR-005 + 用户"UI 也补齐功能入口"的要求；共享键保证四端偏好一致（Key Entities 约定）。
  **Alternatives considered**: TV/Car 用独立偏好键——跨端偏好不一致，且 Cellphone 端已有读写实现无法复用，放弃。

- **Decision**: MPV 降级的 Surface 重建沿用手机端模式：宿主暴露 surfaceGeneration，页面以 key 重建 XComponent 换新 surfaceId 后重开。
  **Rationale**: Surface 无法在解码器间迁移（手机端已验证的方案）；TV/Car 页面已有 XComponent，仅需接入重建机制。
  **Alternatives considered**: 降级时复用同一 Surface——系统限制不可行，放弃。

- **Decision**: x86 模拟器 MPV 为 stub 的验证口径：模拟器上只验证"降级尝试 → 不可用 → 保持既有引擎/提示"的容错路径与手机端一致；MPV 完整降级在 arm64 真机验证。
  **Rationale**: 模拟器 stub 是既定工程事实；容错路径本身就是 Edge Case 验收项。

## Data Model

（均为既有模型或对既有模型的对齐，无新存储结构）

- **EngineId / EngineState / EngineFailure / EngineSource / EngineTrack / EngineEvent**（`player_engine`，不动）：引擎边界既有类型。
- **PlaybackController 编排状态**（`playback`，不动）：attempt/generation/seek 队列/轨道恢复/中断处理。
- **设备宿主状态（新增视图状态，@ObservedV2 + @Trace）**：`TvPlaybackHost`/`CarPlaybackHost` 暴露给页面的字段与旧引擎对齐以最小化页面改造——`phase`（对齐旧 PlayPhase 枚举值）、`positionMs/durationMs/buffering`、`videoSize/aspect`、`subtitleCue`、`audioTracks/subtitleTracks/qualities/episodes` 列表与选中项、`speed`、`engine`（当前引擎）、`videoSurfaceVisible`（车机行车锁）。
- **PlayRequest**（既有，TV/Car 路由/预建请求）：itemId/fileId/季集/startMs/字幕偏好，宿主 begin 入参。
- **能力口径（DeviceCapability，新增）**：按端（client 标识、isMobile、device_id 口径）× 按引擎（编解码/容器表）二维能力申报参数。
- **引擎偏好**：`player.engine.v2`（auto/mpv/avplayer），全端共享。
- **会话上报**：复用 `PlaybackSessionCoordinator` 的 start/progress/ping/stop 协议；`TvCarPlaybackSession` 补 TV/Car 既有字段口径（device_id 等）。

## Contracts & Interfaces

- **宿主 → 页面（UI 契约）**：页面只持有宿主实例，不 import 内核模块；状态经 @Trace 字段读取；操作方法：`open/start/pause/resume/seekTo/seekBy/setSpeed/selectAudio/selectSubtitle/switchQuality/playNext/playPrevious/switchToEpisode/setVideoSurfaceVisible(车机)/release`。
- **宿主 ↔ 内核（组装契约）**：宿主组装 `PlaybackController` + `PlaybackGuard` + `PlaybackSessionCoordinator` + Media 实现（fd 租约）+ Gateway（按引擎能力协商），方法签名全部来自 `playback`/`player_engine` 既有导出，不修改其公共 API（除下一条）。
- **PlaybackGuard 扩展（共享库唯一公共 API 变更）**：新增可选播控指令回调注册（playPrevious/playNext），不注册时行为与现状完全一致——手机端零影响。
- **跨页面生命周期契约**：`TvPlaybackHost.begin(request)/adopt()/end()`、`CarPlaybackHost.begin/adopt/end()` 与旧 `Playback` 协调器同名同语义；详情页/首页/mini 条调用点签名保持不变（实现内部切换）。
- **偏好契约**：引擎选择三态（auto/MPV/AVPlayer）读写 `player.engine.v2`，四端共享；倍速档位集合与手机端一致（0.5/0.75/1.0/1.25/1.5/2.0/3.0）。
- **验收契约（对 spec）**：User Story 1-5 的 Acceptance Scenarios 即四端回归清单；SC-001 以"旧引擎文件删除 + TV/Car 链路 import 检查"验证。
