## iPhone and iPad 0.12.0: Pull down for clips

The library home opens clips with a pull, series show an air schedule, and the download queue can be reordered.

> ✅ Works with MovieClaw Server 0.28.0 or later. The air schedule and the “subscribed from episode N” note need Server 0.44.0; on an older server they stay hidden. Install the TestFlight build. The unsigned IPA is at https://github.com/movieclaw/MovieClaw/releases/tag/ios-v0.12.0

### Highlights

#### Pull down on the library home to watch clips

Keep pulling down on the library home. When it says **Release to start watching**, let go and **Clips** opens. The first time, a tip explains the gesture.

- The top bar no longer has a Clips button. With VoiceOver on, the **Clips** button stays, because a pull is not available.
- The entry is hidden while the library is offline.

#### See when the next episode airs

On a series, open **Air schedule** under the season. It shows what has aired, what is missing, and the next date. **Follow new episodes** subscribes from there.

- The card stays hidden offline, and on a server that does not send a schedule.

#### Put the next download first

In **Downloads**, drag the queue to reorder it, or choose **Prioritize download**. On cellular, a hotspot, or Low Data Mode, a download shows **Waiting for Wi-Fi** until you choose **Download over cellular** or join Wi-Fi.

### More features and improvements

- **iPhone Duo.** On the inner screen, playback can sit in a tabletop console: previous and next episode are on their own row, and diagnostics move to the top bar. iPad wide layouts use the wider card metrics. Other iPhones are unchanged.
- **Subscribed from episode N.** A finished season can show a note that earlier episodes will not be searched or downloaded. You set the start episode on the website. The note stays hidden until Server 0.44.0 sends it.

Full changes: [ios-v0.11.0 → ios-v0.12.0](https://github.com/movieclaw/MovieClaw/compare/ios-v0.11.0...ios-v0.12.0).

---

## 简体中文

## iPhone 与 iPad 0.12.0：下拉就能刷片段

媒体库首页下拉进入片段，剧集看得到播出日历，下载队列也可以调整顺序。

> ✅ 搭配 MovieClaw 服务器 0.28.0 或更新版本即可使用。播出日历和「从第 N 集起订阅」的说明需要服务器 0.44.0；旧服务器上这两处先不出现。请安装 TestFlight 构建。未签名 IPA 在 https://github.com/movieclaw/MovieClaw/releases/tag/ios-v0.12.0

### 本版亮点

#### 在媒体库首页下拉，开始看片段

在媒体库首页一直往下拉。出现「松手，开始欣赏」后松开，就进入「片段」。第一次会有一张提示说明这个手势。

- 顶栏不再放「片段」按钮。开着旁白时，下拉用不了，**片段**按钮仍留在顶栏。
- 媒体库处于离线时，这个入口不出现。

#### 看下一集什么时候播

在剧集详情里，季的下面打开「播出日历」。已播、缺集和下一次更新日期都在这里。「订阅追更」会从这里订上。

- 离线时不显示。服务器没有把日程发下来时也不显示。

#### 让下一部先下载

在「下载」里拖动队列改顺序，或选择「优先下载」。用蜂窝网络、个人热点或低数据模式时，下载会显示「等待 Wi-Fi」，直到你点「使用蜂窝网络下载」或连上 Wi-Fi。

### 其他新功能与改进

- **iPhone Duo。** 内屏播放可以收成桌面控制台：上一集和下一集单独一行，诊断移到顶栏。iPad 的宽版式使用更宽的卡片。其他 iPhone 没有变化。
- **从第 N 集起订阅。** 已经完结的季可以显示一行说明：更早的集不会搜索，也不会下载。起始集在网页上设置。服务器 0.44.0 还没把这个字段发下来时，这行说明不出现。

完整改动：[ios-v0.11.0 → ios-v0.12.0](https://github.com/movieclaw/MovieClaw/compare/ios-v0.11.0...ios-v0.12.0)。
