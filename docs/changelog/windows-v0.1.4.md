## Windows 0.1.4: PGS subtitles settle on the right route

This stability update corrects the follow-up state after Windows chooses native PGS playback or asks the server to burn PGS into an HLS stream.

> ✅ Same server requirements as 0.1.3. The app offers this update itself, or download it from https://github.com/movieclaw/MovieClaw/releases/tag/windows-v0.1.4.

### Fixed

- Starting playback with a saved embedded PGS track no longer asks the server to burn it in before the built-in player has had a chance to use the original track.
- When an HLS replacement stream already contains the requested burned-in PGS subtitle, the player accepts that result instead of repeatedly renegotiating playback. The subtitle remains selected while the native subtitle track stays off, so it is not drawn twice.

Full changes: [windows-v0.1.3 → windows-v0.1.4](https://github.com/movieclaw/MovieClaw/compare/windows-v0.1.3...windows-v0.1.4).

---

## 简体中文

## Windows 0.1.4：PGS 字幕会稳定落在正确通路

这是一次稳定性更新，修正 Windows 选择本地显示 PGS，或请求服务器把 PGS 压进 HLS 之后的后续状态。

> ✅ 对服务器的要求与 0.1.3 相同。App 会自己提示这次更新，也可以从 https://github.com/movieclaw/MovieClaw/releases/tag/windows-v0.1.4 下载。

### 修好了

- 带着已保存的内封 PGS 字幕开始播放时，会先让内置播放器尝试使用原文件里的轨道，不会一开始就要求服务器压制字幕。
- 替换后的 HLS 已经压入所选 PGS 时，播放器会接受结果，不会反复重新协商。字幕仍显示为已选，播放器自己的字幕轨保持关闭，不会重复绘制。

完整改动：[windows-v0.1.3 → windows-v0.1.4](https://github.com/movieclaw/MovieClaw/compare/windows-v0.1.3...windows-v0.1.4)。
