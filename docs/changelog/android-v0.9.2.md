## Android 0.9.2: The air schedule is easier to scan

On a series, the season progress bar is gone. A dropped stream retries before the first frame, and playback picks an address again before it reconnects. The Android interface remains Chinese in this release.

> ✅ Works with MovieClaw Server 0.33.0 or later, the same as 0.9.1. Install from https://movieclaw.io/download/android.apk

### Highlights

#### The air schedule reads as two lines

Open a series that still has an air date today or later. Under the episodes title, the progress bar and its legend are gone. The first line names what airs today or next, with the expected arrival on the right. The second line is the cadence, how many episodes are left, and the finale. **播出日历 › (Air schedule)** opens the sheet: a large remaining count, a collapsed summary of what already aired with the find action, and rows grouped into **本周 (This week)**, **下周 (Next week)**, and **之后 (Later)**. The weekday sits on its own line. The date, the dot, the episode number, and the status share one row. A gap appears only when a real break skips a cadence weekday. The same layout is on the website in Server 0.46.0. On an older server the schedule still uses the dates that server already sends.

### Fixed

- If the stream drops before the first frame, MovieClaw shows **连接中断，正在重连…** and tries again, instead of opening the error page immediately.
- Playback stays on the address chosen for this session. When the stream drops, MovieClaw picks an address again before it asks for a new session, instead of keeping an address that no longer answers.
- Inside **播出日历 (Air schedule)** and **全部分集 (All episodes)**, a drag on a blank area, a divider, or a fixed button no longer pulls the sheet closed. The list still scrolls. Drag the sheet header, tap the dimmed area, or press back to close it.
- After **检查更新 (Check for updates)** downloads a new version, if the system has no session confirmation screen, MovieClaw opens the standard install screen for that same APK instead of stopping. On a phone this screen is usually present; the fallback is the same path the TV uses.

Full changes: [android-v0.9.1 → android-v0.9.2](https://github.com/movieclaw/MovieClaw/compare/android-v0.9.1...android-v0.9.2).

---

## 简体中文

## Android 0.9.2：播出日历更好读

剧集详情里，本季进度条没有了。画面出来之前断流会再试一次，重连前也会重新选地址。这一版界面仍是中文。

> ✅ 搭配 MovieClaw 服务器 0.33.0 或更新版本即可使用，与 0.9.1 相同。从 https://movieclaw.io/download/android.apk 安装。

### 本版亮点

#### 播出日历改成两行

打开一部本季还有今天或以后播出日期的剧。在分集标题下面，进度条和图例没有了。第一行写今天或下次更新的集，右边是预计入库时间。第二行是更新节奏、还剩几集，以及大结局。点「播出日历 ›」打开面板：上面是还剩多少集，已播出的摘要可以收起，里面有补集；下面按「本周」「下周」「之后」分组。星期单独一行。日期、圆点、集数和状态在同一行上对齐。只有真的跳过了一个播出日，才会出现停更分隔。网页要服务器 0.46.0 才是同一套版式。更早的服务器上，日历仍用那台服务器已经给出的播出日期。

### 修好了

- 第一帧出来之前断流，会显示「连接中断，正在重连…」并再试，不再立刻打开错误页。
- 播放停在这一次选定的地址上。断流之后，会先重新选地址，再向服务器要新的播放会话，不再死守一个已经不应答的地址。
- 在「播出日历」和「全部分集」里，空白处、分隔线或固定按钮上的拖动不再把底部面板拖走。列表照常滚动。要关掉，拖面板头部、点外面的遮罩，或按返回键。
- 「检查更新」下载完新版本之后，如果系统没有会话确认页，会改用同一份 APK 的标准安装界面，不再停在装不上。手机上通常有这个确认页；这条退路和电视是同一条。

完整改动：[android-v0.9.1 → android-v0.9.2](https://github.com/movieclaw/MovieClaw/compare/android-v0.9.1...android-v0.9.2)。
