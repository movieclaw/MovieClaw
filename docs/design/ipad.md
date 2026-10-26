# iPad 适配

> 状态：第一版（分支 `feat/ipad-adaptation`，2026-10-15）：外壳、Mac 同构侧边栏、照 Mac 版的详情页已实现。
> 关联：[ios-app.md](ios-app.md)（iPhone 版，同一个 App 目标）、[macos-app.md](macos-app.md)（侧边栏与菜单栏照它）、
> [tvos-app.md](tvos-app.md)。

## 0. 一句话

**iPad 版就是 iPhone 版，功能一样不少；外壳照 Mac 版**：宽窗口用侧边栏，窄窗口退回 iPhone 版式。
内容页按窗口的实际宽度排版，不按「是不是 iPad」分叉。

## 1. 现状：原样跑在 iPad 上

首版只上 iPhone（2026-09-28 决定），iPad 上一直按 iPhone 兼容模式运行。原型分支把设备族改成 `1,2`、
界面代码一行不动，在 13 英寸 iPad 模拟器上走了一遍（真实片库副本）：

| 页面 | 结论 |
|---|---|
| 标签栏 | 系统自动移到顶部（iPadOS 18 起），但只有图标、没有文字，也不能展开成侧边栏 |
| 首页、海报行 | 基本可用：卡片尺寸不变，多露出几张 |
| 海报墙（库、合集、订阅墙等） | 可用：已经是 `adaptive` 网格，宽屏自动排 6～7 列 |
| 条目详情 | **最差**：大图占满整个首屏；片名、轨道、播放键、简介全挤在一列，简介一行拉到 1300 点宽 |
| 设置、活动、「我的」 | 列表整宽拉伸，一行 1300 点，左右两端距离太远 |
| 订阅首页、发现 | 能看；大图偏大 |
| 弹层（订阅、加入合集等） | 系统在 iPad 上默认是居中表单，不用改 |
| 播放器 | 未测（副本没有片源）。另外：原生 iPad 构建上报 `userInterfaceIdiom == .pad`，服务端不再按手机限制码率和分辨率（`PlayerCapability.isPhone`），这是改进，但要验收 |

## 2. 原则

1. **按尺寸类别和实际宽度适配**：iPadOS 26 起窗口可以自由缩放，同一台 iPad 上既有 1376 点宽的窗口，也有 400 点宽的窗口。
   判断用 `horizontalSizeClass` 和容器宽度；`isPad` 只用于外壳（标签文字、侧边栏）。
2. **靠排版，不靠放大**：控件、卡片、字号保持原来的点数，多出来的空间用来多放内容、并排或留白（HIG）。
3. **长文本限宽**：正文、列表在宽窗口里限宽 720～880 点。
4. **iPhone 行为不变**：所有改动在紧凑宽度下走原来的分支。

## 3. 导航外壳

- `TabView` 用 `.sidebarAdaptable`：横屏默认展开侧边栏，竖屏收成顶部标签栏（带文字），窄窗口退回底部标签栏。
- **侧边栏和 Mac 版同构（已实现，2026-10-15 用户定三端统一）**：首页、我的收藏、订阅、发现、活动、我的（头像 + 昵称），
  然后「媒体库」分组逐个列库（带部数）、「合集」分组列首页合集（`PadSidebarLibraryTabs`，数据取首页同一份 `LibraryHomeStore`，
  口径同 `MacSidebar`）。iPhone 上媒体库页签在 iPad 上叫「首页」。
  - 导航状态：`Router.selection: ShellTab`（`.tab(MainTab)` / `.favorites` / `.mediaLibrary(id)` / `.collection(id)`），
    每一项一个导航栈（`paths[ShellTab]`），切走再切回来还在原来那一层，再点一次退回根页面（同 `MacRouter`）。
    侧边栏里的项都归「媒体库」页签（`mainTab`），路由归属、权限守卫、回首页按它算；在某个库里打开条目压在这个库的栈上。
  - 深链 `/library/{id}`（不带 view）在侧边栏里有这个库时直接选中它（`Router.sidebarLibraries`）。
  - 顶部标签栏只有固定的几个页签：收藏、两个分组用 `defaultVisibility(.hidden, for: .tabBar)` 藏起来——它要配合
    `tabViewCustomization` 才生效，所以侧边栏多了系统的「编辑」（同 Apple Music），改动按设备存。
  - 与 Mac 版的差别：系统把分组固定排在普通页签之后；账号没法钉在侧边栏最底下（iPadOS 不允许页签只藏在侧边栏、
    仍留在标签栏，试过 `tabViewSidebarBottomBar`），所以「我的」是普通的一项。
- 搜索：侧边栏模式下用侧边栏第一行的搜索框（照 Mac 版，不用 `Tab(role: .search)`，否则排不到第一位）；标签栏模式下保留右上角放大镜。
- 「接着看」条（`tabViewBottomAccessory`）：侧边栏模式下不显示，首页大图承担这个作用。
- 账号手势（长按头像切换、双击切回）：侧边栏底部的账号项点开就是切换浮层，不依赖手势。

## 4. 页面

| 页面 | 宽窗口做法 | 进度 |
|---|---|---|
| 首页 | 加首屏「接下来继续」大图（照 Mac 版 §4.1：16:9 铺开、延伸到侧边栏底下）；下面的海报行不变 | 待做 |
| 条目详情 | **照 Mac 版**（已实现）：剧照铺满大图区（高 = 页面宽 × 9/16，420～页面高 82%），左下角片名 Logo → 事实行 → 类型 → 第几集 → 简介（4 行可展开）→ 一排按钮（主按钮写明哪一集从哪儿接、看过一段多「从头播放」、收藏 / 已看是圆形玻璃钮、末尾「剩余 X」），右下角导演 / 主演；系列合集链接、挑版本与音轨字幕、电影下载、刷新提示放在大图下面（限宽 720），再往下分集、演职员等同手机 | 已实现 |
| 海报墙 | 不改 | — |
| 设置 | 先限宽（**原型已实现**，`padReadableWidth`）；再改两栏（`NavigationSplitView`，左分区、右内容，`/settings/{section}` 落到右栏） | 部分 |
| 活动、「我的」 | 限宽（**原型已实现**）。遗留：「我的」页的分组小标题、底部 AI 输入框仍是整宽 | 部分 |
| 活动二级页、订阅详情 | 列表 → 详情两栏 | 待做 |
| AI 会话 | 右侧检查器（`.inspector`，⌥⌘I），自动带上当前页的上下文；窄窗口时变成底部弹层；iPhone 不变 | 待定 |
| 订阅首页、发现 | 大图限高（≤ 窗口高度 60%） | 待做 |
| 弹层 | 表单类统一 `.presentationSizing(.form)` | 待做 |
| 播放器 | 画面适配任意窗口比例；画中画（关掉播放器后小窗继续播）作为 iPad 重点验收项 | 待验收 |

### 4.1 卡片尺寸（2026-10-15 用户定：宽窗口照 Mac 版）

比例由素材定（海报 2:3、剧照 16:9），只换大小。照搬手机尺寸时 13 英寸一行排 8 张海报，且 iPad 离眼睛远（约 40～45 厘米），
看上去反而比手机小约 15%。`CardMetrics`（`Shared/DesignSystem/RemoteImage.swift`）两套，`TabRoot` 按 `horizontalSizeClass` 注入
环境值 `cardMetrics`（台前调度拉窄自动退回手机那套），首屏预载按 `CardMetrics.current` 取、地址与页面一致：

| | 手机 | 宽窗口（= Mac `MacMetrics`） | 13 英寸横屏一行 |
|---|---|---|---|
| 首页 / 相似 / 系列海报 | 124 | 168 | 约 5.5 张 |
| 发现、订阅海报行 | 126 | 168 | |
| 接下来继续、分集（16:9） | 200 | 296 | 约 3.5 张 |
| 我的媒体库库卡 | 230 | 296 | |
| 订阅「刚刚入库」 | 264 | 296 | |
| 演职员（2:3） | 96 | 128 | |
| 海报墙最小列宽 | 140 | 150（6 列） | |
| 横滑行间距 | 12 | 18 | |

页边距也在这套里（`edge`：手机 16，宽窗口 32 同 Mac），iOS 页面里的 `Theme.pagePadding` 全部换成 `cards.edge`。
**宽版式只给 iPad**（`CardMetrics.forWindow`：常规宽度且是 iPad）：iPhone Pro Max 横屏也是常规宽度，仍按手机排，
详情页大图区、列表限宽同样以 `cards.isWide` 为准。类型色块保持 196（同网页与 Mac）；离线片库、发现页网格未接。
iPad mini 竖屏（744 点，也是常规宽度）详情页文字比 16:9 大图区高：大图区跟着长高，顶上给标签栏留 120 点。

## 5. 输入

- **指针**：海报卡悬停时上浮、加深投影，左下浮出播放键、右下浮出「⋯」（`.hoverEffect` + `onHover`，同 Mac 版 §4.2）；触摸时不出现。
- **右键**：现有的长按 `contextMenu` 右键直接可用；补「在新窗口中打开」（P3）。
- **键盘**：沿用 Mac 版同一套快捷键：⌘1～9 切换侧边栏项、⌘F 搜索、⌘[ 返回、⌘R 刷新；播放器里空格、← →、⌘→ 下一集。
  用 `.keyboardShortcut`，按住 ⌘ 时系统自动列出全部快捷键。
- **菜单栏**（iPadOS 26）：命令用 `.commands` 声明，复用 Mac 版的「前往 / 账号 / 播放」菜单。
- **拖放**：海报可以拖进侧边栏的合集项；片名和链接可以拖给别的 App（`.draggable`）。

## 6. 多任务

- 方向：四个方向都支持（已加 `UISupportedInterfaceOrientations~ipad`），这样才能参与分屏和自由窗口。
- 窄窗口：外壳自动退回 iPhone 版式；内容页走紧凑宽度分支，不用另写。
- 多窗口（P3）：`UIApplicationSupportsMultipleScenes`，「在新窗口中打开」某部片；每个窗口有自己的 `Router`。
  播放器和账号状态是全局的：同一时刻只允许一个播放器，切账号时所有窗口一起重建。

## 7. 分期

| 期 | 内容 | 验收 |
|---|---|---|
| P0 外壳 ✅ | 设备族 `1,2`、四个方向、`sidebarAdaptable`、页签文字；详情页宽布局；列表页限宽；卡片尺寸与页边距；iPhone 回归 | 13 英寸 / mini 横竖屏截图；iPhone 截图与 main 逐像素一致；iPhone UI 全量与 main 对比 |
| P1 Mac 同构侧边栏 | ✅ 侧边栏逐个列库和合集；待定：侧边栏搜索、首页大图 | 侧边栏每一项保留各自的导航栈；切换账号后整棵重建 |
| P2 两栏与检查器 | 设置两栏、活动和订阅详情两栏、AI 检查器、表单弹层 | 深链接（推送、AI 卡片）在 iPad 上落到正确的栏 |
| P3 输入与多窗口 | 指针悬停、快捷键、菜单栏、拖放、多窗口、画中画 | 接妙控键盘的真机走查；台前调度下拖动窗口尺寸不闪不乱 |
| 上架 | App Store Connect 补 iPad 截图（13 英寸），审核会在 iPad 上测；`ios-release-checklist.md` 加 iPad 项 | — |

## 8. 原型分支里有什么

- `project.yml`：主 App 和两个通知扩展 `TARGETED_DEVICE_FAMILY: "1,2"`；iPad 支持四个方向。
- `Router`：`ShellTab` 分栈、`currentPath`、`select`、`resumePoint`、`sidebarLibraries`；单测 `PadSidebarRouterTests`。
- `MainTabView` + `Features/Root/PadSidebar.swift`：iPad 用 `.sidebarAdaptable`，页签带文字，侧边栏逐个列库与合集。
  iPad 上不挂底栏头像的账号手势与活动页签的状态点（UIKit 桥按标签栏顺序对位，侧边栏对不上），改为：
  活动页签用系统角标写需要处理的任务数、「我的」有更新时角标「新版本」，切换账号放到「我的」页右上角（`open-account-switcher`）。
  侧边栏的库清单晚于冷启动深链到达时，`Router.adoptSidebarLibraries` 把压在首页栈上的库页挪成选中侧边栏那一项。
- `Shared/DesignSystem/RemoteImage.swift` 的 `CardMetrics`：卡片尺寸与页边距两套，见 §4.1。
- `LibraryItemDetailView`：常规宽度下照 Mac 版排（`wideStage`、`wideActions`、`stageCredits`、`wideExtras`）；
  手机版式不变（片名区拆出 `seriesCollectionRows`、`statusBanners`，播放键文案收进 `playButtonState` 两边共用）。
- `DesignSystem/PadReadableWidth.swift`：列表页限宽居中。注意 iPadOS 26 的侧边栏浮在内容上，`contentMargins`
  从滚动视图的边算起、与安全区取大，所以边距 = 安全区 + 居中余量。用在设置首页、活动、「我的」。
- `MovieClawUITests/IPadOrientationUITests.swift`：转动模拟器方向、点掉通知授权弹窗的辅助用例（无界面启动的模拟器没有旋转
  快捷键，`simctl` 也没有旋转命令，App 内 `requestGeometryUpdate` 在 iPadOS 26 上也转不动）。
- `MovieClawUITests/IPadPlayerUITests.swift`：iPad 横屏起播 → 控制层 → 画中画 → 回桌面小窗接着播。
  现有行为：开画中画后全屏播放器不收起（显示「正在画中画中播放」），切出 App 才由小窗接管；
  「开画中画后收起播放器、在 App 里接着逛」是 P3 的目标。

## 9. 怎么验收

- 编译：`MC_SIM="<iPad 模拟器名>" MC_DERIVED=build-ipad scripts/build.sh`（并行开发时单独 `simctl create` 一台 iPad）。
- 横竖屏：`scripts/test.sh -only-testing:MovieClawUITests/IPadOrientationUITests/testRotateLandscape`，再用 `scripts/shot.sh` 截图。
- 数据：用真实片库的只读副本起一个最小后端（只起数据库与配置，不起任务队列、IM 通道、局域网发现），模拟器 App 用
  `-mcServer` 直连。截图前先确认副本里没有不宜公开的库。
