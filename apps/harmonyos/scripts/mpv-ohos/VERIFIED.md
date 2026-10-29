# 播放器（libmpv）验收记录

日期：2026-10-27 凌晨（自动验收） · 设备：Pura X View 模拟器（HarmonyOS 7.0.0, 1320×2232）
服务端：局域网 MovieClaw 实例（地址与库规模略去）

## 结论

**播放器可用。** mpv 引擎（dex2oat/mpv 内嵌 libmpv）在模拟器上完成全链路验收：
起播、直出、服务端转码档、字幕、交互、画中画、进度上报全部通过。
模拟器跑通的路径在真机上没有已知分叉（同一 libmpv.so，同一系统库面），
建议真机再过一遍「来电打断 / 后台播放 / 蓝牙耳机插拔」三项模拟器做不了的场景。

## 逐项结果

| # | 验收项 | 结果 | 备注 |
|---|---|---|---|
| 1 | 安装/启动/登录进媒体库 | ✅ | |
| 2 | mpv 引擎加载（NAPI + libmpv.so） | ✅ | 修复 SONAME/zlib 后正常 |
| 3 | 直出档播放（原始 mp4 直流） | ✅ | 电影 / 剧集各一，档位显示「直出」 |
| 4 | 换壳直通档 | ✅ | 电影 |
| 5 | 硬件转码档（服务端 VAAPI→HLS） | ✅ | 剧集 S01E195/196 |
| 6 | 视频渲染（vo_gpu + EGL-ohos） | ✅ | ~230MB/s 纹理上传 |
| 7 | 音频（ao_ohaudio） | ✅ | 系统日志见 6 声道渲染器采样流动 |
| 8 | 字幕（libass 内封轨中文渲染） | ✅ | 内封中文轨正常，/system/fonts 字体 |
| 9 | 时长/进度显示 | ✅ | mpv duration/time-pos → 秒级 UI |
| 10 | 单击唤出控制条 | ✅ | 修复手势层丢失后 |
| 11 | 双击左右 ∓10s | ✅ | 8:24→8:54（+20s 两次） |
| 12 | 横滑拖进度 | ✅ | 半屏 ≈ +45s，落点 HUD 正常 |
| 12b | 进度条点按跳转 | ✅ | 修复：进度条 Row 的 onTouch 与根手势层同场收不到（同手势层问题），补了 onClick 兜底（79% 点击 → 104:31 精确落点）；真机若 onTouch 正常则拖动走原路径，两者同位置双 seek 无副作用 |
| 13 | 暂停/恢复 | ✅ | |
| 14 | 横屏 ⇄ 竖屏往返 | ✅ | surface 随窗口 resize，播放不中断 |
| 15 | 画中画（surface 迁移） | ✅ | 小窗内视频+字幕持续渲染 |
| 16 | 音轨面板 | ✅ | 跟随默认 ✓ + chi·aac·2声道 |
| 17 | 字幕面板 | ✅ | 列出会话字幕；本片无外挂轨只显示「关闭字幕」 |
| 18 | 服务端跳过段（片头/片尾标记 + 跳过片头按钮） | ✅ | |
| 19 | 退出保存进度 + 媒体库迷你续播条 | ✅ | 「看到 52% · 剩 9 分」 |
| 20 | 重进续播 | ✅ | 从服务端记忆位置起播 |
| 21 | 进度上报（10s）+ 会话心跳（15s） | ✅ | POST 正常 |
| 22 | 播完 → completed → 重播 | ✅ | 修复 mpv idle 后按播放无效的问题 |
| 23 | 自动连播卡（剧集播完→下一集倒计时） | ⚠️ 未完整验证 | 逻辑走 PlayerPage 原路径未动；本次验收片源是电影（无下一集）。真机看一集剧集播完即可确认 |
| 24 | 长稳播放 | ✅ | 连续播放 40+ 分钟（02:18–03:00 soak，跨 3 个片源会话）：无崩溃/无卡死，进度按实时推进；RSS 稳定 ~1.05–1.06 GB（含 mpv 解复用缓存，无增长趋势） |
| 25 | 复查轮（lint/自审/修复） | ✅ | 见文末「复查轮」；修复后冒烟通过 |
| 25 | 来电打断/后台播放/蓝牙插拔 | ☐ 模拟器无法测 | ao_ohaudio 已接焦点中断钩子 → PlaybackGuard，真机验证 |

## 本次修掉的问题（按发现顺序）

### A. 构建/加载层（scripts/mpv-ohos/）
1. libmpv SONAME `libmpv.so.2` 与 HAP 打包名不符 → NAPI 模块加载失败。
   `patchelf --set-soname libmpv.so`。
2. 应用命名空间无 libz.so.1 → zlib 改挂私有名 `libmovieclaw_z.so` 随 HAP 打包。
3. fork 引用不存在的 `vo_ohcodec.c/vo_ohcodec_osd.c`、漏提交 `ohos_surface_size` 成员、
   `ff_ohcodec_discard_buffer` 符号错位 → 4 个幂等补丁（patches/）。

### B. PlayerPage 既有 bug（重构 2f91836f 遗留，与引擎无关）
4. **手势层绑定丢失**：onGesture 状态机死代码 → 控制条收起后永远唤不出来。
   按作者注释里验证过的方案绑回根 Stack（全屏子层在视频页收不到触摸）。
5. **`.overlay(UpNextOverlay)` 吞点击**：overlay 宿主空内容也是全尺寸 + Default 命中
   + zIndex 置顶，整个播放页所有按钮（音轨/字幕/画质/详情/进度条）全部失效。
   改为 Stack 内条件子节点 + 容器 `HitTestMode.None`。
6. Controls 空白轻点层与根手势层双 toggle → 移除前者，统一 handleTap。

### C. 引擎行为
7. mpv 播完进 idle 后按「播放」无效 → MpvPlayer.play() 在 completed 态重新 loadfile
   （对齐 AVPlayer「播完按播放=重播」语义）。
8. 进度条点按 seek 兜底：Row 的 onTouch 在模拟器上不触发（与手势层同款命中问题），
   补 `.onClick` 路径（ClickEvent.x 为组件内 vp，与 progressBarWidth 同单位）。

## 复查轮（03:00，自审 + linter）

- `devecocli check lint`：player 目录 0 问题（修掉 PlayerPrefs `await` 联合类型的 5 个
  lint error——`ready` 改为恒 Promise，init 幂等判据改挂 store）。
- 修 4K 字幕字号：字号锚视频宽，prepare 时拿不到宽度走 1080 回退 → video-reconfig
  时重算 applySubStyle。
- 焦点中断钩子改登记制（g_active 向量广播）：多实例不互相顶掉、销毁不误清钩子。
- createPlayer 加兜底：native 创建异常走 onPlaybackFailed 降档回路，不再未处理 rejection。
- 环境惊魂：compatibleSdkVersion 被工具改成 "26.0.0"（与 target 6.1.1(24) 冲突构建失败）
  ——已复原，**若再出现请检查是否用了别的 DevEco/CLI 版本动过工程**。
- 复查后冒烟：字幕渲染（重算字号）✓ 进度推进 ✓ 进程稳定 ✓。

## 真机验收轮（10-27 上午，HUAWEI Pura X 真机（局域网），HarmonyOS NEXT）

用户报告 4 个问题 → 定位与修复：

| # | 问题 | 根因 | 修复 | 真机结果 |
|---|---|---|---|---|
| 1 | **播放无画面**（黑屏有声音） | 真机 EGL 严格：surfaceId 窗口初建几何为 0 + mpegl 选的 config 与 NativeWindow 不匹配 → eglCreateWindowSurface 失败（模拟器宽松掩盖了它） | `patches/apply-egl-fix.py`：几何为 0 先 SET 占位 1280x720；失败后枚举全部 WINDOW_BIT+GLES2+RGB8 config 逐个重试 | ✅ 直出/转码档全出画面 |
| 2a | **物理旋转不转横屏** | 播放页从未设置传感器跟随（只有「横屏」按钮锁向） | onReady 设 `AUTO_ROTATION`（无视系统旋转锁，同 iOS）；按钮切换改 `AUTO_ROTATION ⇄ AUTO_ROTATION_LANDSCAPE`；退出仍恢复 UNSPECIFIED | ✅ 代码就位（传感器需手转验证） |
| 2b | **画中画不能继续播放** | 同问题 1：EGL 失败 → 小窗里只有黑屏/不渲染 | 随问题 1 修复 | ✅ 小窗视频持续渲染，Back 退出且进度保存 |
| 3 | **音量/亮度手势失灵** | 两层：①真机 SURFACE XComponent 消费触摸，根 Stack 的 onTouch 收不到（模拟器宽松）②控制条显示时中央三键禁区拒绝手势认领 | ①XComponent 加 `HitTestMode.None` 穿透 ②禁区起点滑动不生效属 iOS 同款语义（控制条显示时手势让位按钮）；控制条收起后手势可用；音量手势从「侧键提示」升级为**真调系统媒体音量**（`AudioManager.setVolume(MEDIA, level)`，预热读级别+滑动实时写入+HUD 显示 N/15） | ✅ 音量手势实时生效（applySystemVolume 连续触发）；亮度同通道 |
| 4 | **启动慢**（无缓存） | LibraryHomeStore 只有内存态，冷启动等全部网络请求 | 磁盘快照 `cacheDir/library-home-cache.json`（96KB）：刷新成功后落盘；冷启动同步恢复缓存立即上屏，网络完成后二次刷新（stale-while-revalidate）；行清单也走缓存 | ✅ 冷启动 ~3 秒满数据上屏，5.5 秒网络刷新替换 |

调试期间的环境事实（重要）：
- **真机 hilog 默认 WARNING 级**：`hilog.info` 全部不可见，调试要用 `hilog.error`（或改缓冲级别）。
- **`devecocli ui swipe` 在真机注入的事件不到达应用**；改用 `hdc shell uitest uiInput swipe` 正常。
- 真机上点击手势要避让控制条禁区（顶部/底部 band + 中央三键），与 iOS `point(inside:)` 同语义。

遗留（用户手测）：物理旋转横屏（传感器行为，hdc 无法模拟）；来电打断/锁屏后台/蓝牙路由。

## 竖屏详情布局（10-27 上午，用户需求）

竖屏播放剧集时视频贴顶（16:9 实高），下方整体是可滚动的详情页（B 站式上下分屏）：

- **当前集块**：片名标题、`第 N 集` + 集名 + 观看状态（未看/看到 N%/已看完/未在位）、本集简介（3 行）；
- **选集**：横向滑动的剧照卡片（still_url），当前集 accent 描边 + 底部进度条，
  点卡片换集（`switchToEpisode`，收尾协议与自动连播相同：补发 stop → 重协商）；
- 进入/换集后选集列表**自动滚到当前集**（卡片 148+10vp 步进，Scroller.scrollTo）；
- 电影（无分集）/横屏/fill/stretch 自动回退全屏视频 + 浮层控制的现有形态；
- **控制条分区**：详情模式下顶栏/中央三键/底栏限制在视频区内（外层容器定高），
  不再浮在详情页上；横屏与全屏模式不变；
- **手势分区**：视频面穿透到根手势层（拖进度/亮度/音量/双击照旧），
  详情区 `stopPropagation` 自消费（滚动/点选不会误触发控制条 toggle）。

真机（Pura X）验证：剧集（示例 S01E06）完整展示 + 自动滚动 + 高亮正确；
电影（示例）正确回退全屏。lint：player/library 新增代码 0 问题。

### 横屏在真机不转的结论

代码路径正确：WMS 已接受窗口的 AUTO_ROTATION 请求（container requestOrientation: 5）、
模拟器横竖屏往返通过。真机抓到系统侧 `OnDisplayRotationChanged rotation:0 ret:1`
——**Pura X 折叠（外屏）状态下系统强制竖屏，横屏请求被系统忽略**（设备行为）。
展开内屏后传感器旋转与「横屏」按钮应正常；真机横屏铺满需求可用控制条「画面」菜单
的铺满裁切（fill）模式。

## 真机验收清单（8:00 验收时建议顺序）

1. 装到手机直接播一部电影（直出）+ 一集剧集（任意档）。
2. 播放中：单击唤控制条 / 双击快进 / 横滑拖进度 / 长按 2 倍速。
3. 字幕面板选一条外挂字幕 → 确认 libass 渲染 + 样式编辑生效。
4. 来电 → 应自动暂停；挂断 → 自动恢复（焦点钩子）。
5. Home 键 → 自动进小窗；回 app → 恢复全屏。
6. 锁屏后台播 5 分钟（AVSession + 长时任务），锁屏控制中心播控可用。
7. 蓝牙耳机插拔（音频路由切换）。
8. 剧集播到片尾 → 连播卡出现 → 倒计时自动换集。
