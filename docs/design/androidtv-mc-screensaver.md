# MC 海报屏保：媒体库待机轮播（DayDream）——小设计

> 状态：设计稿（2026-10-25）。是 [androidtv-home.md](androidtv-home.md) §13.3 的第 3 步；
> 配合 aerial fork（「MovieClaw 桌面」aerial 版）使用，也可独立于换桌面功能使用。
> 未实现；排期在换桌面 P1 之后。

## 0. 一句话

电视待机时，屏保轮播**你媒体库的海报与剧照**，角标 MovieClaw——待机的每一分钟都在说「这是你的片库」，
也是「MC 是这台电视的默认播放器」事实三件套（§13.2）的最后一环。

## 1. 形态

- **同一个 APK 里的 DreamService**（`io.movieclaw.androidtv.dream.LibraryDream`）：不新增应用、不需要新签名与发版渠道，
  随 MC Android TV 正常发版。用户在 系统设置 → 屏保 里选「MovieClaw」；插件的 agent 也可以经 adb 直接设
  （`settings put secure screensaver_components io.movieclaw.androidtv/io.movieclaw.androidtv.dream.LibraryDream`，
  adb shell 自带该权限，免 root——aerial-tv 同款路径，§12 已验证）。
- **渲染是独立的轻实现**：不复用 AppRoot/导航栈（桌面壳一节的教训——重组件不进常驻前台职责）。
  DreamService 里一个自持协程作用域 + 简单 Compose/View 画层：全屏剧照 Ken Burns 慢移、底部小字片名/年份/进度
  （继续观看条目显示「继续看 S1E3 · 剩 20 分钟」）、右下 MC 角标。约 10 秒淡入淡出切换。
- **内存与故障纪律**：解码按屏宽降采样；图片只保留当前+下一张的强引用；任何异常（服务器不可达、解码失败）
  都退回「已缓存的海报 → 纯 MC 标 + 时钟」逐级降级，**绝不重试轰炸、绝不崩溃循环**——屏保是最不能失败的表面（§2③）。

## 2. 数据源与缓存

- 复用 MC Android TV 现有的服务器客户端与登录态：继续观看列表（现成接口）+ 媒体库海报/剧照（首页正在用的图片 URL）。
- **缓存**：App 每次回前台时顺手把「继续观看 + 最近入库」条目的剧照落盘（上限 ~40 张，LRU）；
  DreamService 只读这份磁盘缓存——**待机时一帧网络都不拉**（待机 Wi-Fi 可能已断、也不该唤醒网络），
  新鲜度靠 App 使用期内的顺手更新。
- 无登录/空库时：MC 标 + 时钟 + 「打开 MovieClaw 看片」一句话，不加任何网络逻辑。

## 3. 与 aerial 桌面的协调（单槽互斥）

- `screensaver_components` 是系统单槽：aerial fork 与 MC 屏保只能占一个。
- **唯一写者是插件**（经 adb），由用户对话决定：install/home 的 say 里问「待机看航拍还是你的海报墙？」——
  航拍 = aerial 自己的模式（fork 的 `--es screensaver aerial`）；海报墙 = 设 MC 的 DreamService。
- aerial fork 不自动抢槽（上游默认行为待 P1 验收时实测；若实测会抢，fork 补丁里关掉它的自动设置）。

## 4. 分期与验收

| 阶段 | 内容 | 验收 |
|---|---|---|
| S1 | DreamService + 缓存 + 降级链；插件 agent 问句与 `settings put` | 模拟器：登录本地 dev server，待机触发轮播、断服务器回退缓存、空库显示标+时钟 |
| S2 | 继续观看卡（含剧集/剩余时间文案）、 Ken Burns 参数打磨 | 真机 N1：待机温度/内存与系统屏保持平，遥控器唤醒即回 MC |
| S3 | 与 aerial fork 的问句接线进 install/home | agent 对话走查（§11 P1 的对话驱动验收一并覆盖） |

工作量估计：MC 侧 1–2 天，插件侧半天。
