## iPhone and iPad 0.8.0: Your downloads, even without a connection

You can now download movies and episodes to your iPhone and watch them with no signal: on a plane, on the subway, or when the server at home is down. Without a connection, the Library tab switches to what's on your phone, and what you watch there syncs back once you reconnect.

> ✅ Works with MovieClaw Server 0.28.0 or later, the same as 0.7.0. Downloading to iPhone needs Server 0.38.0 or later. That server version requires a Docker image update. On older servers, the download options don't appear. Install from TestFlight, or sideload the unsigned IPA from https://github.com/movieclaw/MovieClaw/releases/tag/ios-v0.8.0. It's no longer attached to the server release.

### Highlights

#### Take a movie or a whole season with you

Streaming from home stops the moment you lose signal. Now you can download ahead of time and play straight from your iPhone. Open a title in the library, tap the ⋯ button (更多操作) at the top right → **Download (下载)**, pick a quality, then tap **Download** at the top right of the sheet.

- Choose the original file, or a 1080p / 720p / 480p version below the source's resolution that the server converts while you download. Their sizes are estimates (marked ≈) and aren't always smaller than the original.
- Smaller versions need a server that can transcode, and HDR titles need a GPU or the Mac transcoder; otherwise only the original is offered. They turn HDR into SDR, keep one stereo audio track, and leave out image-based subtitles (PGS).
- Blu-ray and DVD folders and ISO images can't be downloaded yet.
- For shows, choose this episode, the next few, the unwatched ones, or all that remain; episodes already on your iPhone are skipped. You can also long-press an episode card → **Download this episode (下载这一集)**.
- Downloads use Wi-Fi only by default, and may not run on Wi-Fi in Low Data Mode or on an iPhone hotspot. To allow cellular: Me → Downloads → the gear button (下载设置) → **Use cellular data for downloads (使用蜂窝网络下载)**.
- The app leaves 2 GB free. If a download won't fit, the sheet shows how much space is needed and you can't start it.

#### When the server is out of reach, your downloads are still there

Without a connection to your server, you used to see nothing at all. Now, when your iPhone has no network (for example in airplane mode), the Library tab switches to the titles on your iPhone, with a row to pick up where you left off. It may also switch if the server can't be reached right after you open the app, or after the app has been in the background for more than 10 minutes. When the server answers again, the app goes back online by itself, or you can tap **Reconnect (重新连接)**.

- A slow network doesn't switch you offline. If the home screen reports a connection error, tap **Watch the N on iPhone (看 iPhone 上的 N 部)** to switch yourself.
- Offline mode only appears when at least one finished download is on your iPhone.
- What you watch offline is added to your progress and history once you reconnect, with the time you actually watched it.
- While offline, Discover, Subscriptions, Activity, Search, AI sessions and Settings show a placeholder. Title pages are read-only.
- Known issue: while offline, the ▶ button (片段) and the ⋯ menu at the top of the Library tab, the cast on title pages, and the AI message box on the Me tab (administrators) still respond but can't load or send. Use them once you're back online.

### More features and improvements

- **One page for all downloads**: Me → **Downloads (下载)** lists downloads in progress, downloaded titles, a suggestion to delete what you've finished, other accounts' downloads on this iPhone, and storage used. Swipe or long-press a title to delete it; this only removes the iPhone copy and keeps your watch progress. While something downloads, a bar on the Library home opens this page.
- **Downloads run one at a time**: progress shows on the episode card, or above the Play button for movies. To stop a movie, tap ⋯ → **Cancel download (取消下载)**. For a show, long-press the episode card to pause or cancel, or tap ⋯ → **Cancel all downloads (取消全部下载)**. Downloads may also continue in the background or with the phone locked.
- **Downloaded titles play from your iPhone, even when you're connected**: you get the quality you downloaded, and the resume point follows the server when it's reachable. To stream from the server again, delete the iPhone copy. To change quality, long-press the **Local (本机)** row under Files → **Download another quality (改下其他画质)**; the old copy is deleted right away.
- **Signing out asks about downloads**: when you sign out of the current account, you can delete its downloads or keep them for the next time you sign in. **Sign out of all accounts (退出全部账号)** offers to delete every download on this iPhone.

### For administrators

- Members can download to their devices by default. To stop a member, on the web go to Settings → Members → Edit member → turn off **Download videos to device (下载影片到设备)**; the iPhone app doesn't have this switch.
- Turning it off stops new and unfinished downloads; copies already on the phone still play. Downloads in Infuse and other players may be blocked too.
- Smaller versions use the same transcoding as playback (GPU, Mac transcoder, or software transcoding if you enabled it). Only one is converted at a time, and it waits while playback needs the transcoder. Each file is deleted once the phone finishes downloading it, unless another device at home still needs it.
- Known issue: cancelling or deleting a download on iPhone doesn't stop its conversion on the server. Everything already queued, such as a whole season, is still converted, and the copies stay for at least 72 hours. To stop it, stop the container, delete the `cache/offline-exports` folder in the data directory, then start the container. Unfinished smaller-quality downloads for the account signed in on the iPhone start over by themselves a while after the app is next opened; if one shows an error, delete it and download it again.
- Known issue: if the Mac transcoder goes offline while the server has no other way to convert (an HDR title, or software transcoding off), the current conversion stays at **Waiting for the transcoder (等待转码器空闲)** and everything behind it waits too. Bring the transcoder back online, or clear the queue as in the previous item.

### Before you update

- The title page's ⋯ menu no longer has **Search resources (搜索资源)**. Go back to the tab's home page, tap the magnifier button (搜索) at the top right, switch to **Resources (资源)**, and type the title. It's no longer filled in for you.
- The title page's ⋯ menu no longer has **Clear watch history (清除观看记录)**. In the app you can only clear by time or by library, from the ⋯ next to **Continue Watching (接下来继续)** on the Library home, which appears when that row is showing. The web title page can still clear a single title.
- The rest of that menu is regrouped: Download, Add to collection and Share (administrators) sit in one row at the top. Administrators find the maintenance actions under **Manage (管理)**, and **Delete (删除影片)** is now **Delete from library (从媒体库删除)**.
- Downloads aren't included in iPhone backups. After moving to a new iPhone or restoring from a backup, download them again.
- If you go back to 0.7.0, downloaded files may stay on your iPhone and use space without being visible. Delete them in Me → Downloads before downgrading.

Full changes: [ios-v0.7.0 → ios-v0.8.0](https://github.com/movieclaw/MovieClaw/compare/ios-v0.7.0...ios-v0.8.0).

---

## 简体中文

## iPhone 与 iPad 0.8.0：没网也能看下好的片

现在可以把电影和剧集下载到 iPhone，没有信号也能看：在飞机上、地铁里，或者家里服务器停了的时候。没有连接时，「媒体库」页签会换成手机上的内容；离线看的进度，连上后会同步回服务器。

> ✅ 搭配 MovieClaw 服务器 0.28.0 或更新版本即可使用，与 0.7.0 相同。下载到 iPhone 需要服务器 0.38.0 或更新版本。这个服务器版本需要更新 Docker 镜像。更旧的服务器上不会出现下载入口。从 TestFlight 安装，或到 https://github.com/movieclaw/MovieClaw/releases/tag/ios-v0.8.0 下载未签名 IPA 侧载。IPA 不再附在服务器的 Release 上。

### 本版亮点

#### 把一部电影或一整季带在身上

从家里串流，一没信号就看不了。现在可以提前下好，直接在 iPhone 上播放。在媒体库打开一部片，点右上角的「⋯」按钮（更多操作）→「下载」，选好画质，再点面板右上角的「下载」。

- 可以下原文件，也可以下比原片分辨率低的 1080p / 720p / 480p 版本，由服务器边转边下。较小画质的大小是预计值（带 ≈），不一定比原文件小。
- 较小画质需要服务器能转码，HDR 影片还需要显卡或 Mac 转码器，否则只能下原文件。它会把 HDR 转成 SDR，只保留一条立体声音轨，不带图形字幕（PGS）。
- 蓝光、DVD 原盘目录和 ISO 镜像暂时不能下载。
- 剧集可以选这一集、接下来几集、未看的集或剩下的全部；已在 iPhone 上的集会跳过。也可以长按分集卡 →「下载这一集」。
- 默认只在 Wi-Fi 下下载；开了低数据模式的 Wi-Fi 和 iPhone 热点上可能也不会下。要用蜂窝网络：我的 → 下载 → 右上角的齿轮按钮（下载设置）→ 打开「使用蜂窝网络下载」。
- 下载前会给 iPhone 留出 2 GB 空间。放不下时，面板会写明需要多少空间，并且不能开始。

#### 服务器连不上，下好的片子还在

以前连不上家里的服务器，App 里什么都看不了。现在 iPhone 没有网络（比如开了飞行模式）时，「媒体库」页签会换成 iPhone 上的片子，并带一行「接着看」。刚打开 App 时，或者在后台超过 10 分钟再回来时连不上服务器，也可能自动切过去。服务器能连上后会自动回到在线，也可以点「重新连接」。

- 网慢不会被切到离线。首页提示连接失败时，可以点「看 iPhone 上的 N 部」自己切过去。
- iPhone 上至少有一部已经下好的片子，才会进入离线模式。
- 离线时看的进度和观看历史，连上后会补到服务器上，时间按你实际观看的时间记。
- 离线时，发现、订阅、活动、搜索、AI 会话和设置会显示占位页；影片详情页只能看、不能改。
- 已知问题：离线时，媒体库顶部的 ▶ 按钮（片段）和「⋯」菜单、详情页的演职员、管理员「我的」页的 AI 输入框仍能点，但加载不出来或发送失败。连上服务器后再用。

### 其他新功能与改进

- **所有下载集中在一页**：「我的 → 下载」里有正在下载的、已下载的条目、「删除已看完的」建议、这台 iPhone 上其他账号的下载，以及占用的空间。左滑或长按条目可以删除；只删 iPhone 上的副本，观看进度会保留。有下载在进行时，媒体库首页会出现一条提示条，点它进这一页。
- **一次下一个**：进度显示在分集卡上，电影显示在播放键上方。电影要停下，点「⋯」→「取消下载」；剧集长按分集卡可以暂停或取消，或点「⋯」→「取消全部下载」。切到后台、锁屏后可能也会接着下。
- **下载过的片子，连着服务器时也放 iPhone 上的这份**：画质是你下载时选的那一档；能连上服务器时，续播点仍以服务器为准。想改回从服务器播放，删掉 iPhone 上的副本即可。要换画质，在「文件」里长按标着「本机」的那一行 →「改下其他画质」；旧的副本会马上删除。
- **退出登录时会问要不要删下载**：退出当前账号时，可以删掉它的下载，也可以保留（重新登录同一账号还能接着看）。「退出全部账号」时会问要不要删掉这台 iPhone 上的全部下载。

### 管理员须知

- 成员默认可以把影片下载到自己的设备。要禁止某个成员，在网页上进入 设置 → 成员 → 编辑成员，关闭「下载影片到设备」；iPhone App 里没有这个开关。
- 关闭后，成员不能再下新的，没下完的也会停下；已经下到手机上的照常能看。Infuse 等播放器的下载可能也会被禁止。
- 较小画质和播放用同一套转码（显卡、Mac 转码器，或你开启的软件转码）。一次只转一个；播放需要转码时，下载的转码会先让路。手机下完后，转码出来的文件会删除，家里其他设备还要用的除外。
- 已知问题：在 iPhone 上取消或删除下载，服务器上的转码不会跟着停。已经排上的（比如一整季）仍会全部转完，副本至少保留 72 小时。要立即停止：停掉容器，删除数据目录下的 `cache/offline-exports` 文件夹，再启动容器。iPhone 上当前登录账号没下完的较小画质下载，下次打开 App 后过一会儿会自动从头开始；个别显示出错的，删掉后重新下载。
- 已知问题：Mac 转码器离线、而服务器又没有别的办法转（HDR 影片，或没开软件转码）时，正在转的会一直停在「等待转码器空闲」，后面排着的也跟着等。让转码器重新上线即可，或按上一条停容器清理。

### 升级须知

- 影片详情页的「⋯」菜单不再有「搜索资源」。回到页签首页，点右上角的放大镜按钮（搜索），切到「资源」，再输入片名；不会再自动填好片名。
- 影片详情页的「⋯」菜单不再有「清除观看记录」。App 里只能在媒体库首页「接下来继续」旁的「⋯」里，按时间或按媒体库清空（这一行显示时才有）。网页版影片详情页仍可以只清一部。
- 这个菜单的其余部分也重新整理了：下载、加入合集、分享（仅管理员）排在顶部一行。管理员用的维护操作收进「管理」子菜单，「删除影片」改叫「从媒体库删除」。
- 下载的片子不进 iPhone 备份；换新 iPhone 或从备份恢复后需要重新下载。
- 如果退回 0.7.0，已下载的文件可能仍留在 iPhone 上占用空间，但看不到。退回前请先在「我的 → 下载」里删除。

完整改动：[ios-v0.7.0 → ios-v0.8.0](https://github.com/movieclaw/MovieClaw/compare/ios-v0.7.0...ios-v0.8.0)。
