## Android TV 0.7.4: Read every synopsis in full

A truncated synopsis on a detail page can now take focus and open a full-screen reading view. This release also keeps PGS image subtitles local when the playback path can display them. The Android TV interface remains Chinese.

> ✅ Works with MovieClaw Server 0.28.0 or later, the same as 0.7.3. Install from https://movieclaw.io/download/androidtv.apk

### Highlights

#### Open the full synopsis with the remote

When the main synopsis is longer than three lines, move focus to it and press select to open **完整简介 (Full Overview)**. Use Up and Down when the full text is longer than one screen, then press Back to return focus to the synopsis. A short synopsis stays ordinary text and does not add another focus stop.

Long-press an episode and choose **完整简介** to read past its four-line preview. The long-press menu now also contains **标为已看 / 标为未看** instead of changing watched state immediately. Closing the reading view returns focus to that episode card.

### More features and improvements

- **PGS subtitles stay local when possible**: Direct files and Blu-ray clips keep their original video while the player draws PGS subtitles. If the current path cannot display one, the subtitle menu offers explicit server burn-in and explains that it is slower and reduces picture quality.

Thanks to @jasonhorga. Full changes: [androidtv-v0.7.3 → androidtv-v0.7.4](https://github.com/movieclaw/MovieClaw/compare/androidtv-v0.7.3...androidtv-v0.7.4).

---

## 简体中文

## Android TV 0.7.4：每一段简介都能看完整

详情页里被截断的简介现在可以接住焦点，并打开全屏阅读页。这一版也会在播放通路支持时由播放器本地显示 PGS 图形字幕。Android TV 界面仍是中文。

> ✅ 搭配 MovieClaw 服务器 0.28.0 或更新版本即可使用，与 0.7.3 相同。从 https://movieclaw.io/download/androidtv.apk 安装。

### 本版亮点

#### 用遥控器打开完整简介

首屏简介超过三行时，把焦点移到简介上并按确认，就能打开「完整简介」。全文超过一屏时用上下键滚动，再按返回键回到简介。没有被截断的短简介仍是普通文字，不会多出一个焦点停靠点。

长按一张分集卡，再选「完整简介」，可以阅读超过四行预览的分集简介。长按菜单现在也会列出「标为已看 / 标为未看」，不会一长按就直接切换观看状态。关掉阅读页后，焦点会回到那张分集卡。

### 其他新功能与改进

- **能本地显示的 PGS 字幕不再转码**：直放文件和蓝光片段会保留原画面，由播放器绘制 PGS。当前通路显示不了时，字幕菜单会明确提供服务端压制，并说明速度更慢、画质会降低。

感谢 @jasonhorga。完整改动：[androidtv-v0.7.3 → androidtv-v0.7.4](https://github.com/movieclaw/MovieClaw/compare/androidtv-v0.7.3...androidtv-v0.7.4)。
