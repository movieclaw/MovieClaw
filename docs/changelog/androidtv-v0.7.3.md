## Android TV 0.7.3: The season shows when the next episode airs

On a series that is still airing, the detail page shows **播出日历 (Air schedule)** under the season. Episodes that have not aired are no longer greyed out as missing. The Android TV interface remains Chinese in this release.

> ✅ Works with MovieClaw Server 0.28.0 or later, the same as 0.7.2. The air schedule needs Server 0.44.0; on an older server the strip stays hidden and unaired episodes stay greyed out as missing. Install from https://movieclaw.io/download/androidtv.apk

### Highlights

#### See the next air date under the season

Open a series whose current season still has an air date today or later. Under the season picker, one line names what airs today or next. Move up from the episodes and press select to open **播出日历 (Air schedule)**. The schedule fills the screen. Focus starts on today, or on the next air date. Move up and down a day at a time. Move left for **补这一集 (Find this episode)** and **订阅追更 (Follow new episodes)**. Press Back to close the schedule and return to the line. While you are confirming a subscription, Back returns to **订阅追更** first. On a missing episode, the whole row is **补这一集**.

An episode that has not aired no longer looks like a missing file. Its still shows the air date. Today’s episode is marked **今天播出 (Airs today)**. An episode that has aired and is not in the library stays missing and cannot be played.

**订阅追更** uses the subscription already on the server. If smart selection has never been saved, the panel says **首次订阅要先在手机或网页上完成智能设置 (Finish setting up smart selection on your phone or the web first).** A member who cannot edit that setup sees the existing notice to ask an administrator.

### Fixed

- Confirming **订阅追更 (Follow new episodes)** after smart selection changed while the panel was open used to fail, and pressing confirm again failed the same way. The summary is read again. Press confirm once more. It does not send the old draft again.

Full changes: [androidtv-v0.7.2 → androidtv-v0.7.3](https://github.com/movieclaw/MovieClaw/compare/androidtv-v0.7.2...androidtv-v0.7.3).

---

## 简体中文

## Android TV 0.7.3：这一季会写明下一集什么时候播

还在播出的剧，详情页在选季下面显示「播出日历」。还没播的集不再被当成缺集置灰。这一版界面仍是中文。

> ✅ 搭配 MovieClaw 服务器 0.28.0 或更新版本即可使用，与 0.7.2 相同。播出日历需要服务器 0.44.0；更旧的服务器上这条不出现，还没播的集仍按缺集置灰。从 https://movieclaw.io/download/androidtv.apk 安装。

### 本版亮点

#### 选季下面能看到下一次播出

打开一部本季还有今天或以后播出日期的剧。选季下面有一行，写今天或下次更新哪几集。从分集往上落到这一行，按确认打开「播出日历」。日程铺满屏幕。焦点落在今天，或下一个播出日。上下一天一天走。往左是「补这一集」和「订阅追更」。返回键关掉日程，回到这一行。正在确认订阅时，返回键先回到「订阅追更」。缺了的那一行，整行就是「补这一集」。

还没播的集不再看起来像缺了文件。剧照位换成播出日。今天播出的集会标「今天播出」。已经播出、库里却没有的集仍是缺集，不能点播。

「订阅追更」用的是服务器上已有的订阅。智能选择还没保存过时，面板写「首次订阅要先在手机或网页上完成智能设置」。不能改这项设置的成员，仍看到请管理员先完成的说明。

### 修好了

- 面板开着的时候智能选择被改过，再确认「订阅追更」会失败，再按一次还是失败。现在会重新读一遍摘要。再按一次确认。不会再用打开时的旧稿提交。

完整改动：[androidtv-v0.7.2 → androidtv-v0.7.3](https://github.com/movieclaw/MovieClaw/compare/androidtv-v0.7.2...androidtv-v0.7.3)。
