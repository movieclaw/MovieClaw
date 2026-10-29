## Android 0.9.0: A download queue you can reorder

Reorder offline downloads, open clips from the library home, and check a series air schedule. The Android interface remains Chinese in this release.

> ✅ Works with MovieClaw Server 0.33.0 or later. The air schedule and the “subscribed from episode N” note need Server 0.44.0; on an older server they stay hidden. Install from https://movieclaw.io/download/android.apk

### Highlights

#### Decide what downloads next

Open 我的 → **下载 (Downloads)**. Drag the queue, or long-press and choose **优先下载 (Prioritize download)**. On cellular, a hotspot, or a metered network, a download shows **等待 Wi-Fi (Waiting for Wi-Fi)** until you choose **使用蜂窝网络下载 (Download over cellular)** or join Wi-Fi.

- A download that was interrupted can continue after the app is started again in the background. If the server’s resume point does not match, that file starts over.
- If the local copy will not play, playback falls back to the server when the server is reachable, with the notice **本机副本打不开，改从服务器播放**.

#### Pull down on the library home to watch clips

Keep pulling down on the library home. When it says **松手，开始欣赏 (Release to start watching)**, let go and clips open. The first time, a tip explains the gesture.

- The top bar no longer has a clips button. With TalkBack on, the **片段 (Clips)** button stays.
- The entry is hidden while you are browsing offline. A server older than 0.30.0 says clips are not supported yet.

#### See when the next episode airs

On a series that is still airing, open **播出日历 (Air schedule)** under the season. **订阅追更 (Follow new episodes)** subscribes from there.

- The card stays hidden offline, and when the server does not send a schedule.

### Before you update

- Losing the network no longer replaces the library home with offline mode. A banner offers **看手机上的 N 部** (on a tablet, **看平板上的 N 部**). You choose when to browse downloads. After you are back online, the app can return on its own and shows **已连上服务器**.
- Files already downloaded stay on the device. Deleting a download still keeps watch progress.
- A finished season can show a note that it is subscribed from episode N and that earlier episodes will not be searched or downloaded. You set the start episode on the website.

Full changes: [android-v0.8.0 → android-v0.9.0](https://github.com/movieclaw/MovieClaw/compare/android-v0.8.0...android-v0.9.0).

---

## 简体中文

## Android 0.9.0：下载队列可以自己排

离线下载可以调整顺序，媒体库首页下拉进入片段，剧集也可以看播出日历。这一版界面仍是中文。

> ✅ 搭配 MovieClaw 服务器 0.33.0 或更新版本即可使用。播出日历和「从第 N 集起订阅」的说明需要服务器 0.44.0；旧服务器上这两处先不出现。从 https://movieclaw.io/download/android.apk 安装。

### 本版亮点

#### 自己决定下一部先下哪部

打开「我的 → 下载」。拖动队列，或长按后选「优先下载」。用蜂窝网络、个人热点或计费网络时，下载会显示「等待 Wi-Fi」，直到你点「使用蜂窝网络下载」或连上 Wi-Fi。

- 下载被打断后，App 在后台再次启动时可以接着下。服务器给的续传起点对不上时，这个文件会从头再下。
- 本机副本打不开、而服务器又连得上时，会改从服务器播放，并提示「本机副本打不开，改从服务器播放」。

#### 在媒体库首页下拉，开始看片段

在媒体库首页一直往下拉。出现「松手，开始欣赏」后松开，就进入片段。第一次会有一张提示说明这个手势。

- 顶栏不再放片段按钮。开着 TalkBack 时，下拉用不了，**片段**按钮仍留在顶栏。
- 正在离线浏览时，这个入口不出现。服务器低于 0.30.0 时，会提示还不支持片段。

#### 看下一集什么时候播

仍在播出的剧，季的下面可以打开「播出日历」。「订阅追更」会从这里订上。

- 离线时不显示。服务器没有把日程发下来时也不显示。

### 升级须知

- 断网后，媒体库首页不再自动换成离线模式。横幅上有「看手机上的 N 部」（平板上是「看平板上的 N 部」），由你决定要不要看已下载的片子。重新连上之后，App 可以自己回到在线，并提示「已连上服务器」。
- 已经下载的文件仍留在设备上。删除下载时，观看进度仍会保留。
- 已经完结的季可以显示一行说明：从第 N 集起订阅，更早的集不会搜索，也不会下载。起始集在网页上设置。

完整改动：[android-v0.8.0 → android-v0.9.0](https://github.com/movieclaw/MovieClaw/compare/android-v0.8.0...android-v0.9.0)。
