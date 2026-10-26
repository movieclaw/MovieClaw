## Windows 0.1.0: MovieClaw for Windows gets its own releases

MovieClaw for Windows lets you browse and play your MovieClaw library on a Windows 10 or 11 PC, with a built-in player. It needs a MovieClaw server. From this version on it is released on its own, and its version numbers restart at 0.1.0. It also has optional Discover and subscriptions pages, and tells you about new Windows versions.

> ⚠️ **Install this version by hand**: MovieClaw Desktop 1.0.x keeps saying it is up to date and will not offer it. Quit MovieClaw Desktop (closing its window quits it), then download `MovieClaw-Windows-0.1.0-Setup-x64.exe` from https://github.com/movieclaw/MovieClaw/releases/tag/windows-v0.1.0 and run it. Later versions are offered in the app.
>
> ✅ Same server requirements as MovieClaw Desktop 1.0.4, which shipped with MovieClaw Server 0.37.0.

### Highlights

#### Your library and a full player on the PC

Watching on a computer usually meant a browser tab. Now you browse your libraries, search titles and people, keep favorites and open movie and episode details in a desktop app. Before playing you can pick the file version, audio track and subtitles; the player has resume, next episode, skip intro, playback speed, quality, picture-in-picture and media keys. Progress syncs with your server, so other devices continue where you stopped.

- Right-click during playback to open **Playback info (播放信息)**.
- ISO images cannot be played in the Windows app yet; DVD bitmap subtitles are not shown.

#### Discover and subscriptions, only if you want them

Find new titles from TMDB or Douban, open title and people pages, subscribe, and follow download and import progress, without opening the web page. Both entries are off by default: go to Settings → Navigation entries and turn on **Discover (发现)** or **My subscriptions (我的订阅)**.

- The choice is saved per computer, server and account.
- My subscriptions needs an account with subscription permission.
- Sites and downloaders are set up on the server's web page. Administrators can jump there from My subscriptions → **Import chain (入库链路)** → **Open server settings (打开服务器配置)**.

#### New versions come to you, checked before installing

A few seconds after it starts, the app checks GitHub for a new Windows version and tells you when there is one. You can also check from Settings → About → **Check for updates (检查更新)** or the tray icon menu. Before installing, the app checks that the download is intact and looks for a digital signature.

- Installers are not code-signed yet, so the app asks you to confirm **Install the unsigned update anyway (仍然安装未签名的更新)**.
- Known issue: the update dialog shows only the first part of the English notes, as plain text. Click **Open release page (打开发布页面)** for the full notes.
- Using the portable version: in-app updates download the installer, not a new ZIP. To stay portable, download the new `portable-x64.zip` from the release page instead.

### More features and improvements

- **AI subtitles for administrators**: On a title's details page, administrators can click **Generate AI subtitles (AI 生成字幕)** to have the server make single-language or bilingual subtitles. This needs reference subtitles and an AI model configured on the server.
- **Several accounts**: Add accounts under Settings → Account → **Add account (添加账号)**, and switch between them from the account button at the bottom of the sidebar.

### Before you start

- Windows 10 or 11, 64-bit (x64). The installer adds Microsoft WebView2 when it is missing; the portable ZIP needs WebView2 already installed.
- On first launch, use **LAN discovery (局域网发现)** or enter your server's address, then sign in with your username and password.
- Known issue: the sign-in page shows "compatibility sign-in (兼容登录)" and suggests upgrading the server for device pairing. No server version supports this yet, so you can ignore it.
- Discover and My subscriptions are off by default; see above for how to turn them on.
- Settings → Friends and watch privacy needs the server plugin "服务器观看动态" (server watch presence). The plugin is not shipped with the server and has no public download yet.
- The interface is in Chinese only.
- The installer is not code-signed, so Windows usually shows a SmartScreen warning the first time you run it.

### Moving from an earlier build

Apart from the points below, this version works the same as MovieClaw Desktop 1.0.4.

- **Getting it**: 1.0.x does not update to 0.1.0 by itself; quit it and install by hand as described at the top. The version number is lower than 1.0.4, but this build is newer.
- **Your data**: The server address, saved accounts and sign-in are kept. Playback settings, Discover and subscriptions switches and recent searches may also carry over.
- **Name**: The app is now called "MovieClaw" in Windows and "MovieClaw for Windows" under Settings → About. It may install next to "MovieClaw Desktop" instead of replacing it.
- **Collections**: The sidebar no longer has a **Collections (合集)** section. The same collections are still cards on Home in the **My libraries (我的媒体库)** row, and on a title's details page under **In collections (所属合集)**.
- **If you used the installer**: Once the new version works, uninstall MovieClaw Desktop from Windows Settings → Apps. We recommend leaving "delete application data" unchecked, because it may also clear the new version's local settings, such as playback preferences.
- **If you used the portable version**: Download `MovieClaw-Windows-0.1.0-portable-x64.zip` from the link at the top and unzip it into a new folder. Quit the old version, run `movieclaw-desktop.exe` from the new folder, and once it works, delete the old folder. Your server address and accounts are stored outside the folder and are kept.

Thanks to @sexyfeifan, who built the Windows client and keeps improving it.

---

## 简体中文

## Windows 0.1.0：Windows 版有了自己的发布渠道

MovieClaw for Windows 让你在 Windows 10 或 11 电脑上浏览和播放 MovieClaw 媒体库，自带播放器，需要搭配一台 MovieClaw 服务器。从这一版起它单独发布，版本号从 0.1.0 重新开始。它还有可选的发现与订阅页面，有新版时会提示你。

> ⚠️ **这一版需要手动安装**：MovieClaw Desktop 1.0.x 会一直显示已是最新版本，不会提示这次更新。请先退出 MovieClaw Desktop（关掉窗口就会退出），再从 https://github.com/movieclaw/MovieClaw/releases/tag/windows-v0.1.0 下载 `MovieClaw-Windows-0.1.0-Setup-x64.exe` 并运行。之后的新版本 App 会自己提示。
>
> ✅ 对服务器的要求与随 MovieClaw 服务器 0.37.0 发布的 MovieClaw Desktop 1.0.4 相同。

### 本版亮点

#### 在电脑上看片，有一个完整的播放器

以前在电脑上看片通常要开浏览器。现在可以在桌面 App 里浏览媒体库、搜索片名和影人、收藏、打开电影和单集详情。播放前可以选文件版本、音轨和字幕；播放器支持续播、下一集、跳过片头、倍速、画质、画中画和键盘媒体键。观看进度同步到服务器，在其他设备上能接着看。

- 播放时右键可以打开「播放信息」。
- Windows 版暂时播不了 ISO 镜像，也不显示 DVD 位图字幕。

#### 发现与订阅，想用再打开

不用打开网页，就能从 TMDB 或豆瓣找新片、看影片和影人页面、订阅，并跟进下载和入库进度。两个入口默认关闭：到「设置 → 导航入口」打开「发现」或「我的订阅」。

- 开关按这台电脑、服务器和账号分别保存。
- 「我的订阅」需要账号有订阅权限。
- 站点和下载器在服务器网页上设置。管理员可以从「我的订阅 → 入库链路」里点「打开服务器配置」跳过去。

#### 新版本自己来，装前先核对

App 启动几秒后会到 GitHub 检查有没有 Windows 新版，有就提示你。也可以在「设置 → 关于 → 检查更新」或托盘图标菜单里手动检查。安装前，App 会核对下载的文件是否完整，并检查数字签名。

- 安装包暂时没有代码签名，App 会请你确认「仍然安装未签名的更新」。
- 已知问题：更新对话框里只显示英文说明的开头，而且是未排版的原文。点「打开发布页面」可以看完整说明。
- 用便携版的话：App 内更新下载的是安装包，不是新的压缩包。想继续用便携版，请到发布页下载新的 `portable-x64.zip`。

### 其他新功能与改进

- **管理员可以生成 AI 字幕**：在影片详情页，管理员点「AI 生成字幕」，就能让服务器生成单语或双语字幕。需要有参考字幕，并在服务器上配置好 AI 模型。
- **多个账号**：在「设置 → 账号 → 添加账号」里添加，再从侧栏底部的账号按钮切换。

### 开始之前

- 需要 64 位（x64）的 Windows 10 或 11。安装包会在缺少时装上 Microsoft WebView2；便携版需要电脑上已经有 WebView2。
- 第一次打开时用「局域网发现」或填写服务器地址，然后用用户名和密码登录。
- 已知问题：登录页会显示「兼容登录」，并提示升级服务器后可以用设备配对。目前还没有服务器版本支持，忽略即可。
- 「发现」和「我的订阅」默认关闭，打开方法见上文。
- 「设置 → 好友与观看隐私」需要服务器安装「服务器观看动态」插件。这个插件不随服务器附带，目前也没有公开发布。
- 界面只有中文。
- 安装包没有代码签名，第一次运行时 Windows 通常会弹出 SmartScreen 警告。

### 从旧版迁移

除以下几点外，功能与 MovieClaw Desktop 1.0.4 相同。

- **怎么拿到**：1.0.x 不会自己更新到 0.1.0，请按开头的提示先退出旧版，再手动安装。版本号比 1.0.4 小，但这一版更新。
- **数据**：服务器地址、已保存的账号和登录状态都会保留。播放设置、发现与订阅的开关和最近搜索也可能一并保留。
- **名字**：App 在 Windows 里改叫「MovieClaw」，「设置 → 关于」里显示「MovieClaw for Windows」。它可能装在「MovieClaw Desktop」旁边，而不是替换它。
- **合集**：侧栏不再有「合集」一节。同样的合集仍是首页「我的媒体库」一行里的卡片，也在影片详情页的「所属合集」里。
- **用的是安装版**：确认新版能用后，到 Windows「设置 → 应用」里卸载 MovieClaw Desktop。建议卸载时不要勾选删除应用数据，因为这可能连带清掉新版的本机设置，比如播放偏好。
- **用的是便携版**：从开头的链接下载 `MovieClaw-Windows-0.1.0-portable-x64.zip`，解压到一个新文件夹。退出旧版，运行新文件夹里的 `movieclaw-desktop.exe`，确认能用后删掉旧文件夹。服务器地址和账号存在文件夹之外，会保留。

感谢 @sexyfeifan 开发了 Windows 客户端，并持续改进。
