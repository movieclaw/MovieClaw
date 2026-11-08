## Android 0.9.4: PGS subtitles stay local when they can

PGS image subtitles are now drawn by the player during direct playback and Blu-ray clip playback. Choosing one no longer silently turns the whole video into a server transcode when the current path can display it. The Android interface remains Chinese in this release.

> ✅ Works with MovieClaw Server 0.33.0 or later, the same as 0.9.3. Install from https://movieclaw.io/download/android.apk

### More features and improvements

- **Local PGS playback**: Direct files and Blu-ray clips keep their original video while the player draws the selected PGS track. Track changes and reconnects keep the selection.
- **Explicit server burn-in**: When the current playback path cannot display the selected image subtitle, the subtitle menu offers **此字幕需服务端转码才能显示（较慢、画质略降）**. Choose it to burn the subtitle into the picture; choose **取消压制，播放器本地渲染** to return to local rendering when available.

Thanks to @jasonhorga. Full changes: [android-v0.9.3 → android-v0.9.4](https://github.com/movieclaw/MovieClaw/compare/android-v0.9.3...android-v0.9.4).

---

## 简体中文

## Android 0.9.4：能本地显示的 PGS 字幕不再转码

直放和蓝光片段播放时，PGS 图形字幕现在由播放器自己绘制。当前通路能显示字幕时，选择 PGS 不会再悄悄把整部视频改成服务端转码。这一版界面仍是中文。

> ✅ 搭配 MovieClaw 服务器 0.33.0 或更新版本即可使用，与 0.9.3 相同。从 https://movieclaw.io/download/android.apk 安装。

### 其他新功能与改进

- **本地显示 PGS**：直放文件和蓝光片段会保留原画面，由播放器绘制选中的 PGS 字幕。切换字幕或断线重连后也会保留选择。
- **明确选择服务端压制**：当前播放通路显示不了所选图形字幕时，字幕菜单会出现「此字幕需服务端转码才能显示（较慢、画质略降）」。选它会把字幕压进画面；可以本地显示时，选「取消压制，播放器本地渲染」即可恢复。

感谢 @jasonhorga。完整改动：[android-v0.9.3 → android-v0.9.4](https://github.com/movieclaw/MovieClaw/compare/android-v0.9.3...android-v0.9.4)。
