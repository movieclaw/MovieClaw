## Mac 0.12.6: A paused player gets out of the way

With **Window → Float while playing** enabled, a player you pause now returns to the normal window level instead of covering other apps. Resume playback and it floats again. Playback also gains several reliability fixes.

> ✅ Works with MovieClaw Server 0.31.0 or later, the same as 0.12.4. Download from https://movieclaw.io/en/download and replace the old app. The direct-download edition updates itself.

### Fixed

- **Window → Float while playing** now follows actual user playback: pause and the window returns to the normal level; resume and it floats again. Startup buffering and stream switches do not make the window jump between levels, and disabling the setting keeps it at the normal level.
- Leaving playback after a long session is less likely to pause the interface, rewinding no longer drops image subtitles in affected streams, and AirPlay audio recovers correctly after seeking.

Full changes: [macos-v0.12.4 → macos-v0.12.6](https://github.com/movieclaw/MovieClaw/compare/macos-v0.12.4...macos-v0.12.6).

---

## 简体中文

## Mac 0.12.6：暂停后，播放器会让开别的窗口

打开「窗口 → 播放时置顶」后，播放器一暂停就会回到普通窗口层级，不再挡住其他 App；继续播放时再恢复置顶。播放还修正了几处可靠性问题。

> ✅ 搭配 MovieClaw 服务器 0.31.0 或更新版本即可使用，与 0.12.4 相同。从 https://movieclaw.io/zh/download 下载并替换旧版 App。官网直装版会自己更新。

### 修好了

- 「窗口 → 播放时置顶」现在会跟随用户实际播放：暂停后回到普通层级，继续播放后再置顶。起播缓冲和换流不会让窗口层级来回跳；关掉开关后也会一直保持普通层级。
- 长时间观看后退出播放器时，界面卡顿的情况会减少；受影响的片源往回拖动时不会再丢图形字幕；AirPlay 拖动进度后也能恢复声音。

完整改动：[macos-v0.12.4 → macos-v0.12.6](https://github.com/movieclaw/MovieClaw/compare/macos-v0.12.4...macos-v0.12.6)。
