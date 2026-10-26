## Apple TV 0.10.0: Find anything in a big library

Poster walls now name the poster in focus, and an index on the right jumps to a letter, year or score. Libraries can be filtered by genre, decade and quality right from the couch. The app can also use your home address when you signed in with a domain.

> ✅ Works with MovieClaw Server 0.28.0 or later, the same as 0.9.2. Using the home address needs Server 0.42.0, released shortly after this app. Install from TestFlight.

### Highlights

#### Jump to the middle of a few thousand titles

In a big library, posters were hard to tell apart, and reaching the middle meant holding the remote for ages. Now the poster in focus shows its title and year along its bottom edge. Sorted by title, release date or rating, an index runs down the right: press right from the last column, move up or down, and press select to jump there; press left to go back. Hold a direction to scroll fast and the middle of the screen shows where you are, such as "第 1204 部 / 共 3000 部".

- Titles index from A to Z, with Chinese titles under their pinyin initial and the rest under #.
- Years go one by one back to 2000, then by decade. Ratings go 9+, 8+, 7+, below 7, and unrated.
- Empty letters or years are dimmed and skipped.
- Sorted by date added there's no index; scrolling fast shows the month titles were added.
- After a jump, the rows above load as you move up. **Sort & filter (排序与筛选)** at the top is reachable again once you're back at the start; jumping to the first entry on the index gets you there.

#### Narrow it down from the couch

Before, a library on the TV could only be sorted or limited to unwatched titles. Now the button at the top right is **Sort & filter**, with Genre (类型), Decade (年代) and Quality (画质) menus for resolution or HDR. Each option shows how many titles it leaves, and the title line sums it up, such as "科幻 · 2010 年代 · 未看 · 312 部". When nothing matches, the page offers a way out, such as "去掉“西部”可看 516 部", or **Clear all conditions (清除全部条件)**.

- Options with no matches are greyed out.
- Sort and **Unwatched only (只看没看过的)** are still remembered for each library. Genre, decade and quality clear when you leave the page.

### More features and improvements

- **Sorting collections**: a collection's page has its own sort menu. It starts in the collection's own order (合集顺序) and is remembered for each collection. Collections have no index.
- **Home address at home**: if you signed in with your domain, the app uses the server's home address while it can reach it, so streams don't go out and back through the domain. This needs Server 0.42.0. The server learns addresses from the ones administrators use, or an administrator adds one on the web under Settings → Network → **Access addresses (访问地址)**.

Full changes: [tvos-v0.9.2 → tvos-v0.10.0](https://github.com/movieclaw/MovieClaw/compare/tvos-v0.9.2...tvos-v0.10.0).

---

## 简体中文

## Apple TV 0.10.0：大库里也找得到

海报墙上焦点所在的那张会写出片名，右边的索引条能直接跳到某个字母、年份或分数段。坐在沙发上也能按类型、年代和画质筛选。用域名登录的话，App 现在也会改用家里的地址。

> ✅ 搭配 MovieClaw 服务器 0.28.0 或更新版本即可使用，与 0.9.2 相同。改用家里地址需要服务器 0.42.0，它会在这个 App 之后不久发布。从 TestFlight 安装。

### 本版亮点

#### 几千部片子，也能直接跳到中间

以前库一大，海报认不出是哪部，想到中间要按住遥控器很久。现在焦点所在的海报底部会写出「片名 · 年份」。按片名、上映或评分排序时，右边有一条索引：在最右一列再按右键进去，上下选，按确认键跳过去，按左键回来。按住方向键快速滚动时，屏幕中央会显示当前位置，如「第 1204 部 / 共 3000 部」。

- 片名按 A–Z 排，中文片名按拼音首字母归入，其余归在 #。
- 年份从最新一年逐年排到 2000 年，更早的按年代。评分分成 9+、8+、7+、7 分以下和未评分。
- 没有片子的字母或年份压暗，上下选时直接跳过。
- 按添加时间排序时没有索引条，快速滚动时显示片子是哪年哪月添加的。
- 跳转之后，上面的几排在往上走时才陆续补上；回到最前面才能再按到顶部的「排序与筛选」，在索引条上跳到第一档最快。

#### 坐在沙发上就能筛

以前电视上的媒体库只能排序和只看没看过的。现在右上角的按钮是「排序与筛选」，里面有「类型」「年代」「画质」（分辨率或 HDR）三个菜单。每一项都写着选了还剩几部，标题旁会汇总当前条件，如「科幻 · 2010 年代 · 未看 · 312 部」。筛空时页面给出出路，如「去掉“西部”可看 516 部」，或「清除全部条件」。

- 一部都没有的选项置灰。
- 排序和「只看没看过的」仍按库记住；类型、年代、画质离开页面就清空。

### 其他新功能与改进

- **合集可以排序**：合集页有了自己的排序菜单，默认是合集自己的顺序（合集顺序），按合集记住。合集页没有索引条。
- **在家走家里地址**：用域名登录的话，App 在连得上家里地址时就改用它，播放不再绕外网走一圈。需要服务器 0.42.0。服务器从管理员用过的地址里自动记下地址，管理员也可以在网页的「设置 → 网络 → 访问地址」里手动添加。

完整改动：[tvos-v0.9.2 → tvos-v0.10.0](https://github.com/movieclaw/MovieClaw/compare/tvos-v0.9.2...tvos-v0.10.0)。
