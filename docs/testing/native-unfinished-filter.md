# 原生客户端「未看完」筛选

原生端使用已有 `w=unfinished` API，不在客户端重新计算观看完成度。与 Web 一致：包括从未开始的电影、看到一半的电影，以及当前库存里仍有未看完分集的剧。保留含义不同的 `unwatched`。

首页库行偏好新增 `unfinished`：与旧 `unwatched` 同时为真时优先采用 `unfinished`；`last_played` 排序仍使用 `w=seen`，清除两种不兼容偏好。首页、缓存键和展开后的列表使用相同条件；列表内清除筛选不修改首页偏好。

## 各端接入

- iPhone/iPad：重新生成偏好模型，首页自定义可选全部、未看、未看完；单库筛选沿用服务端 facet；单库/类型行展开继承观看条件、排序与方向，类型墙可切换或取消观看条件。
- Mac/Apple TV：共用首页偏好和取数逻辑；单库菜单增加未看完，首页展开页可清除继承的观看条件。
- Android 手机：补齐实际使用的偏好模型、自定义页、首页请求和单库展开路由；单库观看条件使用单选；类型墙增加未看完。尚未展示的类型首页行原样保留其偏好。
- Android TV：共用生成模型已经有字段，补齐实际首页模型、缓存、取数、展开来源、过滤菜单及空结果清除操作。
- 鸿蒙手机/TV/车机：补齐偏好、首页取数、展开条件、菜单和本地偏好；手机编辑首页或固定合集时保留未看完字段及未展示的首页行。

## 自动化验证

Apple `HomeRowsTests` 验证偏好往返、旧值兼容、互斥和类型行。`LibraryUITests/testUnfinishedHomeExpansionAndNativePreferenceRoundTrip` 连接隔离后端，验证首页展开、半看剧保留、已看完剧排除、清除恢复、原生保存排序以及切换回旧的未看筛选。

启动独立夹具，输出必须放在可再生构建目录；Mac Studio 使用已校验的 StudioSSD：

```sh
.venv/bin/python apps/apple/tests/native_unfinished_fixture.py \
  --directory /Volumes/StudioSSD/Developer/BuildScratch/MovieClaw-native-watch-fixture/<run>
```

夹具输出 `connection.json`，其中只有本地测试服务器和测试账号。按该文件为 `xcodebuild test` 设置 `TEST_RUNNER_MC_TEST_SERVER`、`TEST_RUNNER_MC_TEST_USERNAME`、`TEST_RUNNER_MC_TEST_PASSWORD`，并设置 `TEST_RUNNER_MC_TEST_UNFINISHED_FIXTURE=1`。不设置后者时，此特定用例会跳过；不要用个人服务器替代夹具。按 Ctrl-C 关闭夹具及其子服务。

竞态回归 `LibraryUITests/testDelayedKindSummaryCannotRestoreClearedWatchFilter` 使用夹具参数 `--delay-kind-summary 6`，同时设置 `TEST_RUNNER_MC_TEST_UNFINISHED_DELAY_FIXTURE=1`。本地代理把第一条“未看完”类型墙统计请求延后，状态探针确认旧请求仍未返回时清除筛选，再检查晚到的旧响应不会覆盖完整列表。

Android 手机与 TV 共用 `apps/android-core` 的构建产物，须**顺序运行**，避免两个 Gradle 工程同时改写同一输出目录：

```sh
(cd apps/android && bash gradlew :app:testDebugUnitTest :app:assembleDebug :app:lintDebug)
(cd apps/android-tv && bash gradlew :app:testDebugUnitTest :app:assembleDebug :app:lintDebug)
```

手机的 `LibraryCustomizeProtocolTest` 运行真实 ViewModel、序列化和 HTTP 请求，验证从另一客户端读入、原生修改和保存、切换回未看，以及未展示类型行的字段保留。TV 的 `BigLibraryWallTest` 运行 Compose 遥控交互，核对作品与 facet 请求一致、开关持久化及取消；另有首页合并和查询参数测试。

筛空态：`LibraryUITests/testUnfinishedEmptyKindWallExplainsAndClearsFilter` 需要夹具参数 `--all-tv-watched`（夹具内剧集全部标为看完，「未看完」真实筛空）并设置 `TEST_RUNNER_MC_TEST_UNFINISHED_EMPTY_FIXTURE=1`，验证类型墙说明是观看筛选造成的空结果、一键清除后恢复全部。

Android 手机 `LibraryDetailStaleResponseTest` 用真实 HTTP 卡住旧请求：清除「未看完」后迟到的旧第一页与旧 A–Z 索引、旧筛选的下一页，以及切换筛选同一帧内的触底加载，都不能覆盖或拼接到新结果。`KindWallWatchFilterTest` 用真实 ViewModel 与 Compose 验证观看筛选的单选语义（TalkBack 可读选中状态）、筛空说明和一键清除。

鸿蒙首页逻辑测试直接运行生产 `HomeRows.ets`；`library-index-gate.test.cjs` 运行生产 `LatestRequestGate.ets`，覆盖「旧墙晚到后才取索引」、旧索引失败、轮询期间切筛选等交错，并检查单库页在任何 await 之前取得查询身份：

```sh
HARMONY_TYPESCRIPT_PATH=<TypeScript模块路径> \
  node --test apps/harmonyos/scripts/tests/library-watch.test.cjs apps/harmonyos/scripts/tests/library-index-gate.test.cjs
```

这类筛选/偏好改动可以用自动化测试、编译和模拟器验证提交审阅。上述测试不构成 Android/TV/鸿蒙真机验收，也不覆盖播放、解码或遥控器硬件行为；是否接受以及何时发布仍由维护者决定。鸿蒙主机逻辑测试不能替代 DevEco/ArkTS 编译。
