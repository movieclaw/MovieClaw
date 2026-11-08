## Windows 0.1.3: PGS subtitles follow the playback path

The built-in player now keeps the selected PGS image subtitle in the first playback session. A directly played file uses its embedded track; a stream that cannot carry the subtitle asks the server to burn it into the picture instead.

> ✅ Same server requirements as 0.1.2. The app offers this update itself, or download it from https://github.com/movieclaw/MovieClaw/releases/tag/windows-v0.1.3.

### Fixed

- A directly played file uses the PGS track embedded in the original file instead of attaching a separate subtitle file.
- On a playback path that cannot carry PGS, selecting the track renegotiates playback for server burn-in instead of attaching an unreadable subtitle file.
- The first playback session now includes the subtitle selected on the detail page, including an embedded PGS track.

Thanks to @jasonhorga. Full changes: [windows-v0.1.2 → windows-v0.1.3](https://github.com/movieclaw/MovieClaw/compare/windows-v0.1.2...windows-v0.1.3).

---

## 简体中文

## Windows 0.1.3：PGS 字幕会跟着播放通路正确处理

内置播放器现在会在第一次建立播放会话时带上已经选好的 PGS 图形字幕。直放原文件时使用内封轨；通路带不了字幕时，改由服务器把字幕压进画面。

> ✅ 对服务器的要求与 0.1.2 相同。App 会自己提示这次更新，也可以从 https://github.com/movieclaw/MovieClaw/releases/tag/windows-v0.1.3 下载。

### 修好了

- 直放原文件时，会直接使用文件里的 PGS 内封轨，不再另外旁挂一份字幕文件。
- 播放通路带不了 PGS 时，选择字幕会重新协商为服务端压制，不再旁挂一个播放器读不了的字幕文件。
- 第一次建立播放会话时，会带上详情页已经选好的字幕，包括内封 PGS。

感谢 @jasonhorga。完整改动：[windows-v0.1.2 → windows-v0.1.3](https://github.com/movieclaw/MovieClaw/compare/windows-v0.1.2...windows-v0.1.3)。
