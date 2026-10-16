## Android 0.4.0: One player for phone and TV

The phone app now plays with the same engine as the Android TV app. Blu-ray discs play straight from the disc, image subtitles work, and the title page gets the ⋯ menu that iPhone and the web already have.

> ✅ Works with MovieClaw Server 0.33.0 or later, the same as 0.3.2. Playing Blu-ray straight from the disc needs Server 0.39.0 or later, which requires a Docker image update. Download from https://movieclaw.io/download/android.apk and install it over the current app.

### Highlights

#### Blu-ray with every track, as on the disc

Blu-ray folders used to be converted by the server, which kept only part of the audio and dropped image subtitles. With Server 0.39.0, Blu-ray folders and ISOs play straight from the disc: switch between all audio tracks, hear TrueHD and DTS-HD MA losslessly, and turn on PGS subtitles. Just press play.

- On older servers, Blu-ray folders and ISOs play through the server; the phone no longer reads ISOs itself.
- DVDs and VC-1 discs still play through the server.

#### Everything for a title, in one ⋯ menu

The library title page had no menu, so sharing, adding to a collection or fixing a wrong match meant opening the web. Now tap the ⋯ button (更多操作) at the top right of a title page.

- Everyone sees Search resources, Add to collection and Share, depending on their permissions.
- Administrators also get Upgrade, Re-identify, Refresh metadata, Regenerate chapter images, Change artwork, Transfer to another library, Delete from library and Clear watch history.

### More features and improvements

- **Image subtitles**: PGS subtitles can be picked on the title page and in the player instead of showing as unsupported.
- **Subtitle timing for downloaded subtitles**: **Timing (时间轴)** in the subtitle style menu now shifts external subtitles too.
- **Surround sound stays surround**: 5.1 audio is no longer converted to stereo on the server when the phone can play it.

### Fixed

- Choosing an audio or subtitle track sometimes played a different one, for example English when you picked Mandarin.
- A film could start with the wrong audio track while the menu showed the right one ticked.

### Before you update

- The **Playback engine (播放引擎)** choice between MPV and Exo is gone; there is only one engine now.
- For embedded subtitles in the original file, **Timing (时间轴)** has no effect; the menu says so.
- At the end of a season, the next episode card no longer moves on to the next season, as on iPhone, the web and TV.
- VC-1 videos are no longer decoded on the phone; the server converts them.

Thanks to @anlan-home. Full changes: [android-v0.3.2 → android-v0.4.0](https://github.com/movieclaw/MovieClaw/compare/android-v0.3.2...android-v0.4.0).

---

## 简体中文

## Android 0.4.0：手机和电视用同一个播放器

手机 App 现在和 Android TV 版用同一套播放引擎。蓝光原盘可以直接播放，图形字幕能显示了，详情页也有了 iPhone 和网页上早就有的 ⋯ 菜单。

> ✅ 搭配 MovieClaw 服务器 0.33.0 或更新版本即可使用，与 0.3.2 相同。直接播放蓝光原盘需要服务器 0.39.0 或更新版本（这个服务器版本需要更新 Docker 镜像）。从 https://movieclaw.io/download/android.apk 下载，覆盖安装。

### 本版亮点

#### 蓝光原盘，每条音轨都在

以前蓝光目录要由服务器转换，只留下部分音轨，图形字幕也没了。搭配服务器 0.39.0，蓝光目录和蓝光 ISO 现在都直接读盘播放：所有音轨都能切换，TrueHD、DTS-HD MA 无损播放，PGS 字幕也能打开。直接点播放就行。

- 旧服务器上，蓝光目录和 ISO 经服务器播放；手机不再自己读 ISO。
- DVD 和 VC-1 编码的原盘仍经服务器播放。

#### 一部片的操作，都在一个 ⋯ 里

以前媒体库详情页没有菜单，想分享、加入合集或者改正认错的片，只能去网页。现在点详情页右上角的 ⋯（更多操作）。

- 按各自的权限，大家都能看到「搜索资源」「加入合集」「分享」。
- 管理员还有洗版、重新识别、刷新元数据、重新生成章节图、更换图片、转移到其他库、从媒体库删除和清除观看记录。

### 其他新功能与改进

- **图形字幕**：PGS 字幕在详情页和播放器里都能选，不再显示「本机暂不支持」。
- **外挂字幕能调时间轴**：字幕外观里的「时间轴」现在对外挂字幕也生效。
- **环绕声不再降成立体声**：手机能播 5.1 音轨时，服务器不再把它转成双声道。

### 修好了

- 选音轨或字幕时，有时放出来的是另一条（比如选了国语却是英语）的问题已修复。
- 起播时放错音轨、菜单却勾着正确那条的问题已修复。

### 升级须知

- 「播放引擎」里 MPV 和 Exo 二选一的选项去掉了，现在只有一个引擎。
- 原文件里的内封字幕，「时间轴」调整对它不生效，菜单里会注明。
- 一季看完时，下一集卡片不再接到下一季，与 iPhone、网页、电视一致。
- VC-1 视频不再在手机上解码，改由服务器转换。

感谢 @anlan-home 的贡献。完整改动：[android-v0.3.2 → android-v0.4.0](https://github.com/movieclaw/MovieClaw/compare/android-v0.3.2...android-v0.4.0)。
