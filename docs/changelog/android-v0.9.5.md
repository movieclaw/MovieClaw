## Android 0.9.5: Find what you have not finished

Library home rows and poster walls can now distinguish titles you have not started from titles you started but have not finished. This release also corrects subtitle handling after HLS route changes. The Android interface remains Chinese.

> ✅ Works with MovieClaw Server 0.33.0 or later, the same as 0.9.4. The new **未看完 (Unfinished)** condition requires Server 0.47.0 or later. Install from https://movieclaw.io/download/android.apk

### Highlights

#### Continue from the titles that still have something left

Choose **未看完** while customizing a library home row to include movies you have not finished and series with available episodes left to watch. **未看** remains a separate choice for titles you have never started. Opening **查看全部** keeps the row's watch condition and sorting; a filtered empty wall explains why and offers **清除观看筛选**.

### Fixed

- Switching a library's watch condition, sorting, or A–Z position quickly no longer lets a slower response for the previous choice replace or mix into the current list.
- Embedded text subtitles remain visible through the subtitle overlay on affected HLS playback paths instead of disappearing.
- The old **取消压制，播放器本地渲染** action implied that the player would always resume local rendering. It is now **取消压制并关闭字幕**, and it turns subtitles off and remembers that choice.

Thanks to @o1xhack. Full changes: [android-v0.9.4 → android-v0.9.5](https://github.com/movieclaw/MovieClaw/compare/android-v0.9.4...android-v0.9.5).

---

## 简体中文

## Android 0.9.5：找出还没看完的作品

资料库首页行和海报墙现在能区分「从没开始看」与「已经开始、但还没看完」。这一版也修正了 HLS 通路切换后的字幕处理。Android 界面仍是中文。

> ✅ 搭配 MovieClaw 服务器 0.33.0 或更新版本即可使用，与 0.9.4 相同。新的「未看完」条件需要服务器 0.47.0 或更新版本。从 https://movieclaw.io/download/android.apk 安装。

### 本版亮点

#### 从还有内容没看完的作品继续

自定义资料库首页行时选择「未看完」，会包含还没看完的电影，以及仍有在架集数没看完的剧集。「未看」仍是另一项，只包含从未开始的作品。点「查看全部」时会保留首页行的观看条件和排序；筛选结果为空时，页面会说明原因，并提供「清除观看筛选」。

### 修好了

- 快速切换资料库的观看条件、排序或 A–Z 位置时，较慢返回的旧请求不会再覆盖或混入当前列表。
- 受影响的 HLS 播放通路中，内封文字字幕会继续由字幕层显示，不会再消失。
- 原来的「取消压制，播放器本地渲染」会让人误以为播放器一定能恢复本地显示。现在入口改为「取消压制并关闭字幕」，执行后会关闭字幕并记住这次选择。

感谢 @o1xhack。完整改动：[android-v0.9.4 → android-v0.9.5](https://github.com/movieclaw/MovieClaw/compare/android-v0.9.4...android-v0.9.5)。
