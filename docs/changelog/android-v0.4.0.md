## Android 0.4.0: One player for phone and TV

The phone app now plays with the same engine as the Android TV app. Blu-ray discs play straight from the disc with every track, image subtitles work, and the title page gets the ⋯ menu that iPhone and the web already have. The new engine leans on the server for more formats, so read "Before you update".

> ✅ Works with MovieClaw Server 0.33.0 or later, the same as 0.3.2. Playing Blu-ray straight from the disc needs Server 0.39.0 or later, which requires a Docker image update; on Server 0.33 Blu-ray ISOs can't play at all. Download from https://movieclaw.io/download/android.apk and install it over the current app.

### Highlights

#### Blu-ray with every track, as on the disc

Blu-ray folders made of several clips used to be converted by the server: one audio track, TrueHD reduced to AC-3, and no image subtitles on any Blu-ray folder. With Server 0.39.0, Blu-ray folders and ISOs play straight from the disc: switch between all audio tracks, keep TrueHD and DTS-HD MA instead of their lossy core, and turn on PGS subtitles. Just press play.

- Blu-ray ISOs already in the library need one manual scan on the server first (library page ⋯ → Scan library).
- On Server 0.34 to 0.38, Blu-ray folders and ISOs play through the server; the phone no longer reads ISOs itself.
- DVDs, including DVD ISOs, now play through the server on Server 0.34 or later. VC-1 Blu-rays play through the server too.

#### Everything for a title, in one ⋯ menu

The library title page had no menu, so adding to a collection or fixing a wrong match meant opening the web. Now tap the ⋯ button (更多操作) at the top right of a title page. Some items appear only when they apply.

- Members see **Search resources (搜索资源)**, **Add to collection (加入合集…)**, **Upgrade (洗版…)** with subscription permission, and **Clear watch history (清除观看记录…)** for their own history.
- Administrators also get **Share (分享…)**, **Fix identification (修正识别结果…)**, **Refresh metadata (刷新元数据)**, **Regenerate chapters (重新生成章节)**, **Change artwork (更换图片…)**, **Transfer to another library (转移到其他库…)** and **Delete (删除影片)**, which removes the files from disk.

### More features and improvements

- **Image subtitles**: PGS subtitles can be picked on the title page and in the player instead of showing as unsupported. When the server is converting the video, it burns them into the picture, which needs server transcoding.
- **Blu-ray in Reels**: Blu-ray folders now play in Reels instead of showing "not supported".

### Fixed

- Choosing an audio track sometimes played a different one, for example English when you picked Mandarin.

### Before you update

- The **Playback engine (播放引擎)** choice between MPV and Exo in the player's quality menu is gone; there is only one engine now.
- Videos the phone can't decode itself (such as VC-1 and WMV, or 4K AV1 on older phones) are now converted by the server, and AVI, MOV and M2TS files are repackaged by the server before playing. Both need a server that can transcode.
- On phones whose screen can't show HDR, HDR and Dolby Vision titles may now be converted to SDR by the server, which needs hardware transcoding there.
- When playing the original file, **Timing (时间轴)** in the subtitle menu has no effect on embedded subtitles; the menu says so. On external ASS subtitles, a non-zero offset drops their styling.
- At the end of a season, the next-episode card no longer moves on to the next season, as on iPhone, the web and TV.

Thanks to @anlan-home. Full changes: [android-v0.3.2 → android-v0.4.0](https://github.com/movieclaw/MovieClaw/compare/android-v0.3.2...android-v0.4.0).

---

## 简体中文

## Android 0.4.0：手机和电视用同一个播放器

手机 App 现在和 Android TV 版用同一套播放引擎。蓝光原盘可以直接读盘播放、每条音轨都在，图形字幕能显示了，详情页也有了 iPhone 和网页上早就有的 ⋯ 菜单。新引擎有更多格式要靠服务器处理，请先看「升级须知」。

> ✅ 搭配 MovieClaw 服务器 0.33.0 或更新版本即可使用，与 0.3.2 相同。直接播放蓝光原盘需要服务器 0.39.0 或更新版本（这个服务器版本需要更新 Docker 镜像）；服务器 0.33 上蓝光 ISO 无法播放。从 https://movieclaw.io/download/android.apk 下载，覆盖安装。

### 本版亮点

#### 蓝光原盘，每条音轨都在

以前多段剪辑的蓝光目录要由服务器转换：只有一条音轨，TrueHD 还会退成 AC-3，蓝光目录也显示不了图形字幕。搭配服务器 0.39.0，蓝光目录和蓝光 ISO 现在直接读盘播放：所有音轨都能切换，TrueHD、DTS-HD MA 不再退成有损的核心音轨，PGS 字幕也能打开。直接点播放就行。

- 已入库的蓝光 ISO 要先在服务器的库页「⋯ → 扫描库」扫一次。
- 服务器 0.34～0.38 上，蓝光目录和 ISO 经服务器播放；手机不再自己读 ISO。
- DVD（包括 DVD 镜像）在服务器 0.34 或更新版本上改为经服务器播放；VC-1 编码的蓝光也经服务器播放。

#### 一部片的操作，都在一个 ⋯ 里

以前媒体库详情页没有菜单，想加入合集或者改正认错的片，只能去网页。现在点详情页右上角的 ⋯（更多操作）。部分项只在适用时出现。

- 成员能看到「搜索资源」「加入合集…」「洗版…」（需要订阅权限）和「清除观看记录…」（只清自己的）。
- 管理员还有「分享…」「修正识别结果…」「刷新元数据」「重新生成章节」「更换图片…」「转移到其他库…」和「删除影片」（会从磁盘删除文件）。

### 其他新功能与改进

- **图形字幕**：PGS 字幕在详情页和播放器里都能选，不再显示「本机暂不支持」。服务器转码播放时，字幕会由服务器压进画面，需要服务器能转码。
- **刷片能放蓝光目录**：刷片里遇到蓝光目录可以播放了，不再提示「暂不支持」。

### 修好了

- 选音轨时有时放出来的是另一条（比如选了国语却是英语）的问题已修复。

### 升级须知

- 播放器「画质」菜单里 MPV 和 Exo 二选一的「播放引擎」选项去掉了，现在只有一个引擎。
- 手机自己解不了的视频（如 VC-1、WMV，以及老机型上的 4K AV1）改由服务器转换，AVI、MOV、M2TS 这类文件也改由服务器换封装后播放，都需要服务器能转码。
- 屏幕不支持 HDR 的手机上，HDR 和杜比视界片子可能改由服务器转成 SDR，需要服务器有硬件转码。
- 直接播放原文件时，字幕菜单里的「时间轴」对内封字幕不生效，菜单里会注明；外挂 ASS 字幕调了时间轴后，特效样式会丢失。
- 一季看完时，下一集卡片不再接到下一季，与 iPhone、网页、电视一致。

感谢 @anlan-home 的贡献。完整改动：[android-v0.3.2 → android-v0.4.0](https://github.com/movieclaw/MovieClaw/compare/android-v0.3.2...android-v0.4.0)。
