## HarmonyOS 1.0.0: Native playback with a familiar phone interface

MovieClaw for HarmonyOS introduces native AVPlayer playback with MPV fallback, refreshed player controls, and an app navigation bar aligned with the iPhone interface.

> Requires HarmonyOS 6.1.1 (API 24) or later on ARM64. Installing the HAP requires authorization under its Huawei signing profile; a GitHub download is not an AppGallery release. Playback and interface changes have been verified on an ARM64 emulator; physical-device validation remains separate.

### Playback

- Native AVPlayer is preferred. When a supported fallback condition is met, playback switches to MPV.
- Choose audio tracks, subtitles, playback speed and picture layout from compact player menus.
- Play and pause buttons now update with the playback state.

### App navigation

- A centered icon bar shows the current account avatar in My.
- When scrolling down, recent playback moves into the same row as the navigation button. It keeps the artwork, title and play control, and hides its close button until expanded.
- The AI input appears in the administrator's My tab, with space reserved above the navigation bar.

### Validation

Playback testing used a NAS library with 144 format samples and 57 audio-track samples. Per-sample failures and server delivery issues remain documented; this does not claim that every format or device is supported. Final navigation regression passed 42 logic tests and four end-to-end scenarios.

---

## 简体中文

## 鸿蒙 1.0.0：原生播放与统一的手机交互

MovieClaw 鸿蒙版优先使用系统 AVPlayer 播放，并提供 MPV 降级，更新播放器控制界面，同时将应用底部导航与 iPhone 的交互风格对齐。

> 需要 ARM64 设备和鸿蒙 6.1.1（API 24）或更新版本。HAP 的安装受华为签名 Profile 的授权范围约束，GitHub 下载不等于应用市场发布。播放与界面改动已在 ARM64 模拟器验证，真机验收另行进行。

### 播放体验

- 优先使用系统 AVPlayer，满足支持的降级条件时切换 MPV。
- 可在紧凑菜单中切换音轨、字幕、播放倍速和画面显示方式。
- 播放与暂停按钮随实际播放状态更新。

### 应用导航

- 居中的图标底栏显示当前账号头像。
- 向下滚动时，最近播放整体下移到导航按钮同一行并缩窄，保留封面、片名和播放入口，展开前隐藏关闭按钮。
- 管理员的 AI 输入位于「我的」页签，并为底部导航留出空间。

### 验证范围

使用 NAS 媒体库覆盖了 144 个格式样本和 57 个音轨样本；逐项失败与服务端供片问题均保留记录，不代表所有格式和设备都已支持。最终导航回归通过 42 项逻辑测试和 4 项端到端场景。
