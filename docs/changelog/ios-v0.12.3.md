## iPhone and iPad 0.12.3: The player closes when nothing is next

A movie, or the last episode of a season, no longer sits on the final frame. The player closes and leaves you on that title.

> ✅ Works with MovieClaw Server 0.28.0 or later, the same as 0.12.2. This build is the unsigned IPA at https://github.com/movieclaw/MovieClaw/releases/tag/ios-v0.12.3. It is not on TestFlight.

### Fixed

- When a movie or the last episode of the season ends, and there is no next episode, the player closes. If you started from Home, a poster wall, or search, that title is placed on top, and Back returns to the page you came from. If you were already on the title, a second copy is not added. A next episode still shows **Up next** and counts down. A clip that reaches the end, and shared playback, only close the player.

Full changes: [ios-v0.12.2 → ios-v0.12.3](https://github.com/movieclaw/MovieClaw/compare/ios-v0.12.2...ios-v0.12.3).

---

## 简体中文

## iPhone 与 iPad 0.12.3：没有下一集时关掉播放器

电影，或这一季的最后一集，不再停在最后一帧。播放器关掉，落在这部片上。

> ✅ 搭配 MovieClaw 服务器 0.28.0 或更新版本即可使用，与 0.12.2 相同。这一版是未签名 IPA：https://github.com/movieclaw/MovieClaw/releases/tag/ios-v0.12.3。没有上传到 TestFlight。

### 修好了

- 电影或本季最后一集放完，又没有下一集时，播放器会关掉。从首页、海报墙或搜索起播的，这部片压在原来的页面上，返回回到来的地方。本来就在这部片上起播的，不会再压一层。有下一集时仍显示「即将播放」并倒计时。片段放到终点，以及分享播放，只关掉播放器。

完整改动：[ios-v0.12.2 → ios-v0.12.3](https://github.com/movieclaw/MovieClaw/compare/ios-v0.12.2...ios-v0.12.3)。
