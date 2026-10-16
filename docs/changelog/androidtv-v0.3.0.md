## Android TV 0.3.0: Blu-ray with every track

Blu-ray discs now play straight from the disc on your TV, with all their audio tracks, lossless sound and image subtitles. Picking an audio or subtitle track also plays the one you picked.

> ✅ Works with MovieClaw Server 0.28.0 or later, the same as 0.2.2. Playing Blu-ray straight from the disc needs Server 0.39.0 or later, which requires a Docker image update. Download from https://movieclaw.io/download/androidtv.apk and install it over the current app.

### Highlights

#### Blu-ray, as on the disc

Blu-ray folders and ISOs used to be converted by the server, which kept only part of the audio and dropped image subtitles. With Server 0.39.0 they play straight from the disc: switch between all audio tracks, hear TrueHD and DTS-HD MA losslessly, and turn on PGS subtitles. Just press play.

- On older servers, Blu-ray still plays through the server as before.
- DVDs and VC-1 discs still play through the server.

### Fixed

- Choosing an audio or subtitle track sometimes played a different one, for example English when you picked Mandarin.
- A film could start with the wrong audio track while the menu showed the right one ticked.

Full changes: [androidtv-v0.2.2 → androidtv-v0.3.0](https://github.com/movieclaw/MovieClaw/compare/androidtv-v0.2.2...androidtv-v0.3.0).

---

## 简体中文

## Android TV 0.3.0：蓝光原盘，每条音轨都在

蓝光原盘现在在电视上直接读盘播放，所有音轨、无损音频和图形字幕都在。选音轨和字幕时，放出来的也就是你选的那条。

> ✅ 搭配 MovieClaw 服务器 0.28.0 或更新版本即可使用，与 0.2.2 相同。直接播放蓝光原盘需要服务器 0.39.0 或更新版本（这个服务器版本需要更新 Docker 镜像）。从 https://movieclaw.io/download/androidtv.apk 下载，覆盖安装。

### 本版亮点

#### 蓝光原盘，和盘里一样

以前蓝光目录和蓝光 ISO 要由服务器转换，只留下部分音轨，图形字幕也没了。搭配服务器 0.39.0，现在直接读盘播放：所有音轨都能切换，TrueHD、DTS-HD MA 无损播放，PGS 字幕也能打开。直接点播放就行。

- 旧服务器上，蓝光照旧经服务器播放。
- DVD 和 VC-1 编码的原盘仍经服务器播放。

### 修好了

- 选音轨或字幕时，有时放出来的是另一条（比如选了国语却是英语）的问题已修复。
- 起播时放错音轨、菜单却勾着正确那条的问题已修复。

完整改动：[androidtv-v0.2.2 → androidtv-v0.3.0](https://github.com/movieclaw/MovieClaw/compare/androidtv-v0.2.2...androidtv-v0.3.0)。
