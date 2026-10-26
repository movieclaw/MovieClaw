## Android 0.7.0: Smart subscriptions on your phone

Subscribing from the phone now uses smart selection, as on the web and iPhone: it picks the quality and asks once whether you need subtitles for a language. With Server 0.42.0, long MP4 films with TrueHD sound, which could close the app, are now repackaged.

> ✅ Works with MovieClaw Server 0.33.0 or later, the same as 0.6.0. Smart selection and the MP4 fix need Server 0.42.0, released right after this app (no Docker image update needed). The app offers this update itself, or download it from https://movieclaw.io/download/android.apk.

### Highlights

#### Subscribe the smart way from your phone

Smart selection was only on the web and iPhone, so the phone always subscribed with rule sets. Now the subscribe sheet opens in **Smart selection (智能选择)** and shows the quality it will look for, how long it waits and which subtitles it needs. The first time a language comes up, administrators answer once whether they need subtitles, and **Change quality (改画质)** can apply to just this title or be remembered for similar ones. To use a rule set instead, pick **Selection method (选择方式)** → **Rules (规则模式)**.

- On a server older than 0.42.0 the sheet subscribes with rule sets, as in 0.6.0.
- The sheet starts in Smart selection every time; it doesn't remember that you picked Rules.
- If smart settings were never saved, administrators tap **Set up smart preferences (设置智能偏好)** first. Members are asked to wait for an administrator or pick Rules.
- Administrators reach the settings with **Edit settings (修改设置)** in the sheet: quality, source, wait times, plus **Languages I understand (看得懂的语言)** and **Quality habits (画质习惯)**. The phone has no other entry; on the web they are under Settings → Subscription rules → Smart settings.
- A smart subscription's page shows its target quality, upgrades and subtitle rule, and the episodes still waiting. The person who subscribed and administrators can tap **Download current candidate now (立即下载当前候选)** or wait longer (1 more day for a film, 2 hours for an episode).
- When it is waiting for subtitles, **Download the original this time (这次先下原版)** grabs it anyway, and administrators are then asked whether they understand the language. These subtitle steps need Server 0.42.0; the other waiting actions also work on older servers.

### Fixed

- The page of a smart subscription made on the web or iPhone showed Rule set #0 (规则组 #0) instead of its smart target.
- With Server 0.42.0: a long MP4 with TrueHD sound, such as some 4K Dolby Vision MP4s, could close the whole app shortly after playback started. The server now repackages these files for the app instead of sending the original; the picture isn't re-encoded. MKV files were never affected.

Full changes: [android-v0.6.0 → android-v0.7.0](https://github.com/movieclaw/MovieClaw/compare/android-v0.6.0...android-v0.7.0).

---

## 简体中文

## Android 0.7.0：手机上也能智能订阅

在手机上订阅现在和网页、iPhone 一样用智能选择：它替你挑画质，碰到一种语言只问一次要不要字幕。搭配服务器 0.42.0，可能让 App 闪退的带 TrueHD 音轨长 MP4 会改为换封装播放。

> ✅ 搭配 MovieClaw 服务器 0.33.0 或更新版本即可使用，与 0.6.0 相同。智能选择和 MP4 的修复需要服务器 0.42.0，它紧随这个 App 发布（不用更新 Docker 镜像）。App 会自己提示这次更新，也可以从 https://movieclaw.io/download/android.apk 下载。

### 本版亮点

#### 在手机上也能智能订阅

以前智能选择只在网页和 iPhone 上有，手机上订阅一律按规则组来。现在订阅弹层默认就是「智能选择」，写明要找的画质、最多等多久、需要什么字幕。第一次碰到某种语言时，管理员回答一次要不要字幕；「改画质」可以只改这一部，也可以记成同类作品的习惯。想按规则组订阅，在「选择方式」里选「规则模式」。

- 服务器早于 0.42.0 时，弹层照旧按规则组订阅，与 0.6.0 相同。
- 弹层每次打开都是「智能选择」，不会记住你上次选了规则模式。
- 智能设置还没保存过时，管理员要先点「设置智能偏好」；成员会看到请管理员先完成设置、或改选规则模式的提示。
- 管理员在弹层里点「修改设置」进入智能设置：画质、片源、等待时间，以及「看得懂的语言」和「画质习惯」。手机上只有这一个入口；网页在「设置 → 订阅规则 → 智能设置」。
- 智能订阅的详情页写出智能目标、后续洗版和字幕要求，并列出还在等的集。发起订阅的人和管理员可以点「立即下载当前候选」，或再多等一会儿（电影延长 1 天、剧集一集延长 2 小时）。
- 在等字幕版时，「这次先下原版」会直接下原版，之后再问管理员看不看得懂这种语言。等字幕这几步需要服务器 0.42.0；其他等待操作在旧服务器上也能用。

### 修好了

- 在网页或 iPhone 上建的智能订阅，手机详情页显示「规则组 #0」而不是智能目标的问题已修复。
- 搭配服务器 0.42.0：带 TrueHD 音轨的长 MP4（如部分 4K 杜比视界 MP4）开始播放后不久可能让整个 App 闪退。现在服务器会给 App 换封装播放，不再直接给原文件，画面不转码。MKV 一直不受影响。

完整改动：[android-v0.6.0 → android-v0.7.0](https://github.com/movieclaw/MovieClaw/compare/android-v0.6.0...android-v0.7.0)。
