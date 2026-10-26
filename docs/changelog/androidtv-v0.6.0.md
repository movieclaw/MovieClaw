## Android TV 0.6.0: Find your way in a big library

Poster walls now name the poster you're on, and a library can jump by letter, year or rating and filter by genre, decade and quality, the same as on Apple TV. With Server 0.42.0, long MP4 films with TrueHD sound, which could close the app, are now repackaged.

> ✅ Works with MovieClaw Server 0.28.0 or later, the same as 0.5.0. The MP4 fix needs Server 0.42.0, released right after this app (no Docker image update needed). The app offers this update itself, or download it from https://movieclaw.io/download/androidtv.apk.

### Highlights

#### Know which poster is which, and jump straight there

In a library of thousands, posters with only English or artwork on them were hard to tell apart, and reaching the middle meant holding the remote down. Now the focused poster shows its title and year along the bottom. In a library sorted by title, release date or rating, press right from the last column to reach the index on the right: up and down pick a letter, year or score, select jumps there, and left goes back. Holding a direction shows where you are, such as "第 1204 部 / 共 3000 部".

- Titles run A–Z and #, with Chinese titles under the first letter of their pinyin. Release dates list every year from 2000 on and decades before that. Ratings are 9+, 8+, 7+, below 7 and unrated.
- Letters and years with nothing in them are dimmed and skipped.
- Sorted by date added there is no index; holding a direction shows the month instead, such as "2026 年 8 月".
- The title band appears on every poster wall: libraries, collections, and **View all (查看全部)** from a Home row.

#### Narrow a library down

The sort button only offered four sorts and unwatched-only. It is now **Sort & filter (排序与筛选)**, and under **Filter (筛选)** it adds **Genre (类型)**, **Decade (年代)** and **Quality (画质)**, each option with its count. The library title shows what you picked and how many titles match, such as "科幻 · 2010 年代 · 未看 · 49 部". If nothing matches, buttons like "去掉“4K”可看 12 部" drop one condition, or **Clear all conditions (清除全部条件)** starts over.

- Pick one genre, one decade and one quality (4K, 1080p and so on, or HDR) at a time. Options with no titles are greyed out.
- Sort and **Unwatched only (只看没看过的)** are still remembered per library on this TV; genre, decade and quality clear when you leave the library.
- Collections get a sort button too. It starts in collection order (合集顺序) and is remembered per collection.

### More features and improvements

- **Pages start fresh**: a library or other page you left with Back opens from the top when you open it again, as on Apple TV. Pages under other tabs stay where they were when you switch tabs.

### Fixed

- With Server 0.42.0: a long MP4 with TrueHD sound, such as some 4K Dolby Vision MP4s, could close the whole app about ten seconds into playback, every time. The server now repackages these files for the app instead of sending the original; the picture isn't re-encoded. MKV files were never affected.

Full changes: [androidtv-v0.5.0 → androidtv-v0.6.0](https://github.com/movieclaw/MovieClaw/compare/androidtv-v0.5.0...androidtv-v0.6.0).

---

## 简体中文

## Android TV 0.6.0：大库里也找得到片

海报墙会写出你停在哪一部，媒体库能按字母、年份或评分跳转，也能按类型、年代、画质筛选，和 Apple TV 一样。搭配服务器 0.42.0，可能让 App 闪退的带 TrueHD 音轨长 MP4 会改为换封装播放。

> ✅ 搭配 MovieClaw 服务器 0.28.0 或更新版本即可使用，与 0.5.0 相同。MP4 的修复需要服务器 0.42.0，它紧随这个 App 发布（不用更新 Docker 镜像）。App 会自己提示这次更新，也可以从 https://movieclaw.io/download/androidtv.apk 下载。

### 本版亮点

#### 认得出是哪一部，也能一下跳过去

几千部的库里，只印英文或只有艺术字的海报很难分清是哪部，想到中间只能一直按住遥控器。现在停在哪张海报上，它底部就写出片名和年份。媒体库按片名、上映或评分排序时，在最右一列按右键进入右侧的索引条：上下选字母、年份或分数，按确认跳过去，按左键回到海报。按住方向键快速滚动时，屏幕上会提示你在哪，如「第 1204 部 / 共 3000 部」。

- 片名按 A–Z 和 # 排，中文片名按拼音首字母归档。上映从 2000 年起每年一档，更早的按年代。评分分 9+、8+、7+、7 分以下和未评分。
- 没有片的字母和年份压暗，上下移动时自动跳过。
- 按添加时间排序时没有索引条，按住方向键提示的是月份，如「2026 年 8 月」。
- 片名暗带在所有海报墙上都有：媒体库、合集，以及首页某一行的「查看全部」。

#### 把一个库缩小到想看的

以前排序按钮里只有四种排序和「只看没看过的」。现在它叫「排序与筛选」，「筛选」一节里新增「类型」「年代」「画质」，每个选项写着有几部。库名旁写出你选的条件和命中部数，如「科幻 · 2010 年代 · 未看 · 49 部」。筛空时会给出「去掉“4K”可看 12 部」这样的按钮，或用「清除全部条件」重来。

- 类型、年代、画质（4K、1080p 等，或 HDR）各一次选一个。没有片的选项置灰。
- 排序和「只看没看过的」照旧按库记在这台电视上；类型、年代、画质离开这个库就清空。
- 合集也有了排序按钮，默认是「合集顺序」，按合集记住。

### 其他新功能与改进

- **页面重新开始**：用返回键离开的媒体库等页面，再打开时从头开始，和 Apple TV 一样。切换页签时，其他页签里的页面保持原样。

### 修好了

- 搭配服务器 0.42.0：带 TrueHD 音轨的长 MP4（如部分 4K 杜比视界 MP4）开始播放十来秒后整个 App 闪退、每次都一样的问题，现在服务器会给 App 换封装播放，不再直接给原文件，画面不转码。MKV 一直不受影响。

完整改动：[androidtv-v0.5.0 → androidtv-v0.6.0](https://github.com/movieclaw/MovieClaw/compare/androidtv-v0.5.0...androidtv-v0.6.0)。
