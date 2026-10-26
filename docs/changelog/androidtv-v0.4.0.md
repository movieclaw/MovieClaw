## Android TV 0.4.0: Updates itself

The TV app now finds and installs its own updates, so this is the last version you sideload by hand. A playback diagnostics panel, like the one on iPhone, shows what's going on when a video stutters or won't play.

> ⚠️ Install this version by hand from https://movieclaw.io/download/androidtv.apk over the current app; 0.3.0 can't update itself. It works with MovieClaw Server 0.28.0 or later, the same as 0.3.0.

### Highlights

#### No more sideloading every new version

Updating the TV app used to mean downloading the APK and installing it again. Now the app checks once a day after you sign in and offers **Update now (立即更新)**, **Skip this version (跳过这一版)** or **Later (以后再说)**. To check yourself, use **Check for updates (检查更新)** at the bottom of the **Who's watching (谁在看)** page.

- The app downloads from GitHub. When the TV can't reach GitHub, it downloads through your server instead; that needs Server 0.40.0.
- The first time, Android asks you to allow MovieClaw to install apps.
- Every download is checked against its published checksum before it is installed.
- If the installed app is signed differently (for example a test build you built yourself), the update can't install over it. The app says so: uninstall first, which clears your sign-in and settings.

#### See why a video stutters

When playback stuttered or wouldn't start, there was no way to tell whether the TV, the network or the server was the problem. During playback, press up to reach the row above the progress bar and choose **Playback diagnostics (播放诊断)**; it's there for films too, not just episodes. A panel at the top left shows the decoder, HDR and audio output, what the server is doing to the file, dropped frames, bitrate and buffering. Press Back to close it.

Thanks to @WadeChenn. Full changes: [androidtv-v0.3.0 → androidtv-v0.4.0](https://github.com/movieclaw/MovieClaw/compare/androidtv-v0.3.0...androidtv-v0.4.0).

---

## 简体中文

## Android TV 0.4.0：自己会更新了

电视 App 现在能自己发现并安装新版本，这是最后一个需要手动安装的版本。播放时也有了和 iPhone 一样的「播放诊断」面板，卡顿或放不出来时能看到问题出在哪。

> ⚠️ 这一版需要手动从 https://movieclaw.io/download/androidtv.apk 下载，覆盖安装；0.3.0 不能自己更新。搭配 MovieClaw 服务器 0.28.0 或更新版本即可使用，与 0.3.0 相同。

### 本版亮点

#### 不用每次都手动装新版

以前更新电视 App 要自己下载 APK、重新安装。现在登录后 App 每天检查一次，有新版时可以选「立即更新」「跳过这一版」或「以后再说」。想手动检查，到「谁在看」页底部点「检查更新」。

- App 从 GitHub 下载；电视连不上 GitHub 时改经你的服务器下载，这需要服务器 0.40.0。
- 第一次更新时，系统会要求允许 MovieClaw 安装应用。
- 每个下载的安装包都会先对照发布的校验值，核对无误才安装。
- 本机装的包签名不同时（比如自己编的测试包），新版装不上去。App 会提示需要先卸载，卸载会清掉登录和设置。

#### 卡顿时看看问题出在哪

以前播放卡顿或放不出来，分不清是电视、网络还是服务器的问题。现在播放时按上键到进度条上方那一行，选「播放诊断」；电影和剧集都有。左上角的面板会显示解码器、HDR 与音频输出、服务器对这个文件做了什么、掉帧、码率和缓冲。按返回键关闭。

感谢 @WadeChenn 的贡献。完整改动：[androidtv-v0.3.0 → androidtv-v0.4.0](https://github.com/movieclaw/MovieClaw/compare/androidtv-v0.3.0...androidtv-v0.4.0)。
