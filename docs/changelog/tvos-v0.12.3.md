## Apple TV 0.12.3: Playback speed is in the panel

Swipe down and **Speed** is the fourth column, next to subtitles, audio, and quality. When nothing is next, the player closes and leaves you on that title.

> ✅ Works with MovieClaw Server 0.28.0 or later, the same as 0.12.1. Install the TestFlight build. This GitHub release is the notes only.

### Highlights

#### Speed sits in the fourth column

Swipe down during playback. The panel is **Subtitles**, **Audio track**, **Quality**, and **Speed**. The steps are 0.5×, 0.75×, **Normal**, 1.25×, 1.5×, and 2×, the same as on iPhone. Moving into **Speed** lands on the speed you are using, not on 0.5×. A speed other than **Normal** stays as a badge next to the remaining time. The choice is remembered for this title, including the next episode and the next time you open it. Another title starts at **Normal**.

### Fixed

- When a movie or the last episode of the season ends, and there is no next episode, the player closes. If you started from Home, a poster wall, or search, that title is placed on top, and Back returns to the page you came from. If you were already on the title, a second copy is not added. A next episode still shows **Up next** and counts down. A clip that reaches the end, and shared playback, only close the player.

The GitHub release contains release notes only. Installation requires the corresponding TestFlight build.

Full changes: [tvos-v0.12.1 → tvos-v0.12.3](https://github.com/movieclaw/MovieClaw/compare/tvos-v0.12.1...tvos-v0.12.3).

---

## 简体中文

## Apple TV 0.12.3：倍速在播放面板里

下滑打开面板，第四栏是「倍速」，挨着字幕、音轨和画质。没有下一集时，播放器关掉，落在这部片上。

> ✅ 搭配 MovieClaw 服务器 0.28.0 或更新版本即可使用，与 0.12.1 相同。请安装 TestFlight 构建。这个 GitHub Release 只有说明。

### 本版亮点

#### 倍速是第四栏

播放时下滑。面板是「字幕」「音轨」「画质」「倍速」。档位是 0.5×、0.75×、「正常」、1.25×、1.5×、2×，和 iPhone 相同。移进「倍速」时落在当前档，而不是 0.5×。不是「正常」时，剩余时间旁边会留着这个档位。选择按这部片记住，下一集和再次打开都带着。换一部片从「正常」开始。

### 修好了

- 电影或本季最后一集放完，又没有下一集时，播放器会关掉。从首页、海报墙或搜索起播的，这部片压在原来的页面上，返回回到来的地方。本来就在这部片上起播的，不会再压一层。有下一集时仍显示「即将播放」并倒计时。片段放到终点，以及分享播放，只关掉播放器。

GitHub 发布页仅提供版本说明，安装仍需对应的 TestFlight 构建。

完整改动：[tvos-v0.12.1 → tvos-v0.12.3](https://github.com/movieclaw/MovieClaw/compare/tvos-v0.12.1...tvos-v0.12.3)。
