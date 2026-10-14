## Windows 0.1.0: MovieClaw on your Windows desktop

The first independent Windows release brings your server's library, native playback and optional discovery and subscriptions to Windows 10/11 x64.

> **Moving from a 1.0.x community build?** Download and install this Windows release manually. The new Windows channel starts at 0.1.0; earlier builds do not discover it automatically. A separately deployed MovieClaw server is required.

### Highlights

#### Watch your library with desktop controls

Browse libraries, search, open favorites and continue where you left off. Before playback, choose the file version, audio track and subtitle; during playback, use keyboard shortcuts, fullscreen or picture in picture. Media keys work with Windows, and the computer stays awake while you watch. Playback progress syncs back to your server.

#### Choose whether discovery and subscriptions belong in your sidebar

Open **Settings → Navigation** to enable **Discovery** and **My Subscriptions**. Browse titles and people, subscribe with your preferences or server rules, and follow download and import progress. Availability follows your server APIs and account permissions; server source and downloader setup opens in the web console. Collections are no longer a separate sidebar entry.

### More features and improvements

- **AI subtitles for administrators**: Preview or generate single-language and bilingual subtitles from reference subtitles using the server's configured AI model. Monitor, cancel or retry jobs and select completed subtitles; audio-only transcription is not included.
- **Optional viewing activity**: With the watch-presence server plugin, choose whether to view friends or share watching activity. Both options start off; sharing is limited to selected libraries that are neither hidden nor adult.
- **A separate Windows update channel**: The app finds Windows releases directly, verifies package hashes and opens the matching Windows release page. Portable updates use manual replacement.
- **Installer and portable ZIP**: The installer includes the player and can install WebView2 when missing; the portable ZIP requires WebView2 already installed.

### Before you update

- Sign in with your server account. Native device login requires the server to advertise Windows support; QR pairing is hidden while that support is unavailable.
- Official packages may be unsigned. Their signature status is recorded in the release manifest, and an unsigned update asks for confirmation before installation.

Thanks to @sexyfeifan for the Windows client.

---

## 简体中文

## Windows 0.1.0：在 Windows 桌面上打开自己的片库

首个独立 Windows 版本，把服务器片库、原生播放，以及可选的发现与订阅带到 Windows 10/11 x64。

> **正在使用 1.0.x 社区版？** 请手动下载并安装本次 Windows 版本。新 Windows 渠道从 0.1.0 开始，旧版不会自动发现它。客户端需要连接单独部署的 MovieClaw 服务器。

### 本版亮点

#### 用桌面操作，看自己的片库

浏览媒体库、搜索、打开收藏，并从上次看到的位置继续。播放前可选择文件版本、音轨和字幕，播放中可用键盘快捷键、全屏或画中画。支持 Windows 媒体键，看片时保持电脑唤醒，观看进度会同步回服务器。

#### 发现和订阅，由你决定要不要放进侧栏

在「设置 → 导航」开启「发现」与「我的订阅」，可浏览作品与人物，按个人偏好或服务器规则订阅，并跟踪下载和入库进度。功能取决于服务器接口与账号权限，资源站点和下载器配置会打开网页管理台。合集不再单独占用侧栏入口。

### 其他新功能与改进

- **管理员可用 AI 字幕**：使用参考字幕与服务器配置的 AI 模型，预览或生成单语、双语字幕；查看任务进度、取消或重试，并选择完成的字幕。暂不支持没有参考字幕的纯音频转写。
- **观影动态可自选**：安装观看动态服务器插件后，可选择看好友动态或分享自己的观看状态，默认都关闭；分享仅限选中的非隐藏、非成人媒体库。
- **独立 Windows 更新渠道**：直接查找 Windows 版本，校验安装包哈希，打开对应的 Windows 发布页。便携版需要手动替换更新。
- **安装包与便携 ZIP**：安装包附带播放器，缺少 WebView2 时可一并安装；便携 ZIP 需要电脑已经安装 WebView2。

### 升级须知

- 使用服务器账号登录。原生设备登录需要服务器声明支持 Windows，尚未支持时二维码配对入口会隐藏。
- 官方安装包可能未签名，实际签名状态记录在发布清单中；安装未签名更新前会请你确认。

感谢 @sexyfeifan 带来 Windows 客户端。
