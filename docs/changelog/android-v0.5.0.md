## Android 0.5.0: Updates itself

The app now finds and installs its own updates, so this is the last version you download by hand. A playback diagnostics panel, like the one on iPhone, shows what's going on when a video stutters or won't play.

> ⚠️ Download this version by hand from https://movieclaw.io/download/android.apk and install it over the current app; 0.4.0 can't update itself. It works with MovieClaw Server 0.33.0 or later, the same as 0.4.0.

### Highlights

#### No more checking the website for new versions

New versions used to mean visiting the download page and installing over the app. Now the app checks once a day after you sign in and offers **Update now (立即更新)**, **Skip this version (跳过这一版)** or **Later (以后再说)**. To check yourself, tap the version line at the bottom of **Me (我的)**, which ends in **检查更新**.

- The app downloads from GitHub. When GitHub is unreachable, it downloads through your server instead; that needs Server 0.40.0.
- The first time, Android asks you to allow MovieClaw to install apps.
- Every download is checked against its published checksum before it is installed.
- If the installed app is signed differently (for example a test build you built yourself), the update can't install over it. The app says so: uninstall first, which clears your sign-in and settings.

#### See why a video stutters

When playback stuttered or wouldn't start, there was no way to tell whether the phone, the network or the server was the problem. In the player, tap the sliders button (画质) and turn on **Playback diagnostics (播放诊断)** at the bottom of the menu. A panel at the top left shows the decoder, HDR and audio output, what the server is doing to the file, dropped frames, bitrate and buffering. It stays on screen when the controls hide, so it's easy to screenshot for a bug report.

Thanks to @WadeChenn. Full changes: [android-v0.4.0 → android-v0.5.0](https://github.com/movieclaw/MovieClaw/compare/android-v0.4.0...android-v0.5.0).

---

## 简体中文

## Android 0.5.0：自己会更新了

App 现在能自己发现并安装新版本，这是最后一个需要手动下载的版本。播放器里也有了和 iPhone 一样的「播放诊断」面板，卡顿或放不出来时能看到问题出在哪。

> ⚠️ 这一版需要手动从 https://movieclaw.io/download/android.apk 下载，覆盖安装；0.4.0 不能自己更新。搭配 MovieClaw 服务器 0.33.0 或更新版本即可使用，与 0.4.0 相同。

### 本版亮点

#### 不用再去官网看有没有新版

以前有新版要自己去下载页下载、覆盖安装。现在登录后 App 每天检查一次，有新版时可以选「立即更新」「跳过这一版」或「以后再说」。想手动检查，点「我的」页底部以「检查更新」结尾的版本号那一行。

- App 从 GitHub 下载；连不上 GitHub 时改经你的服务器下载，这需要服务器 0.40.0。
- 第一次更新时，系统会要求允许 MovieClaw 安装应用。
- 每个下载的安装包都会先对照发布的校验值，核对无误才安装。
- 本机装的包签名不同时（比如自己编的测试包），新版装不上去。App 会提示需要先卸载，卸载会清掉登录和设置。

#### 卡顿时看看问题出在哪

以前播放卡顿或放不出来，分不清是手机、网络还是服务器的问题。现在在播放器里点调节图标（画质），在菜单最底部打开「播放诊断」，左上角的面板会显示解码器、HDR 与音频输出、服务器对这个文件做了什么、掉帧、码率和缓冲。控制条隐藏时面板仍在，方便截图反馈问题。

感谢 @WadeChenn 的贡献。完整改动：[android-v0.4.0 → android-v0.5.0](https://github.com/movieclaw/MovieClaw/compare/android-v0.4.0...android-v0.5.0)。
