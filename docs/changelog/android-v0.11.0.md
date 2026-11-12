## Android 0.11.0: Find local titles by actor, and close Episodes safely

Local and NFO cast cards can now open the same library filtered to one actor. This release also fixes the Android 0.10.0 crash when closing the in-player episode drawer or choosing another episode. The Android interface remains Chinese.

> ✅ Works with MovieClaw Server 0.33.0 or later, the same as 0.10.0. The new actor-filtered wall requires Server 0.48.0 or later. Install from https://movieclaw.io/download/android.apk

### Highlights

#### Find the rest of an actor's work in a local library

On an item detail page, tap an actor who has no online person page. Android opens that same library with **演员：姓名** as a removable condition; tap the condition or **清空** to return to the full library. Actors with an online person page still open that page, and directors without one remain static.

### Fixed

- Closing the **选集** drawer, pressing back while it is open, or choosing another episode no longer crashes the app during the closing animation.

Thanks to @Migflyway and @anlan-home. Full changes: [android-v0.10.0 → android-v0.11.0](https://github.com/movieclaw/MovieClaw/compare/android-v0.10.0...android-v0.11.0).

---

## 简体中文

## Android 0.11.0：按演员找本地作品，选集抽屉也能安全收起

本地库和 NFO 库里的演员卡现在可以打开同库中这位演员的作品。Android 0.10.0 关闭播放器选集抽屉或换集时的闪退也已修好。Android 界面仍是中文。

> ✅ 搭配 MovieClaw 服务器 0.33.0 或更新版本即可使用，与 0.10.0 相同。新的演员筛选海报墙需要服务器 0.48.0 或更新版本。从 https://movieclaw.io/download/android.apk 安装。

### 本版亮点

#### 在本地库里继续看这位演员的作品

在条目详情页点没有在线影人页的演员，Android 会打开同一媒体库，并显示可移除的「演员：姓名」条件。点这项条件或「清空」即可回到整库。带在线影人页的演员仍进入影人页；没有影人页的导演仍不可点。

### 修好了

- 打开播放器「选集」后，点关闭、按返回键或选择另一集时，App 不会再在收起动画中闪退。

感谢 @Migflyway 与 @anlan-home。完整改动：[android-v0.10.0 → android-v0.11.0](https://github.com/movieclaw/MovieClaw/compare/android-v0.10.0...android-v0.11.0)。
