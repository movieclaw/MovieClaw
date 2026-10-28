# iPhone Duo 适配

> 状态：P0 与 P1 已实现（2026-10-27，分支 `claude/iphone-duo-adaptation`），见 §10；P2 与上架未做。
> 关联：[ipad.md](ipad.md)（宽版式、侧边栏外壳都从这里来）、[ios-app.md](ios-app.md)、[reels.md](reels.md)、
> [ios-release-checklist.md](ios-release-checklist.md)。

## 0. 一句话

**内屏当「口袋里的 iPad」用，外屏当「更宽更矮的 iPhone」用。**

iPad 适配时建好的宽版式（`CardMetrics.wide`、Mac 式详情页、侧边栏外壳、居中表单）已经覆盖了内屏的大部分需要。
它们现在没在 Duo 上生效，是因为开关全挂在「是不是 iPad」（`userInterfaceIdiom == .pad`）上，而 Duo 报的是 `.phone`。
所以分三步：

1. 把这些判断换成尺寸类别；
2. 补上 Duo 独有的三件事：竖排系统栏、折痕（半折、桌面模式）、开合时内容不断；
3. 在播放器和「片段」上做出 Netflix 那样的大屏体验。

## 1. 设备事实

### 1.1 两块屏

| | 外屏（合上） | 内屏（展开） |
|---|---|---|
| 尺寸 | 5.4 英寸 | 7.6 英寸（物理 1878×2670 @430ppi） |
| 渲染 | 1398×2034 px @3x | 2007×2853 px @3x，再缩放到物理像素（同当年的 Plus） |
| **点** | **466×678**（竖） | **669×951**（竖）/ **951×669**（横；展开时的自然方向，折痕竖在正中） |
| 宽高比 | 1.46 | 1.42 |
| 尺寸类别 | 竖：紧凑宽 × 常规高；横：紧凑 × 紧凑 | **横竖都是常规 × 常规** |
| 系统栏 | 状态栏、灵动岛、摄像头都在**右侧**竖排；标签栏、工具栏、返回键也竖排到右侧 | 横：竖排在右侧（同外屏）；竖：回到上下横排 |
| 圆角 | 左 8 / 右 59（左边挨着铰链） | 四角 55 |

点尺寸与圆角取自 Xcode 27.1 自带的 iPhone Duo 模拟器设备描述（`iPhone Duo.simdevicetype`），
与 App Store 截图规格（内屏 2007×2853、外屏 1398×2034）一致。

两点值得记住：

- **1 点的物理大小和 iPhone 完全一样**（约 153 点/英寸；iPad mini 163、13 英寸 iPad 132），而且是拿在手里、按手机的距离看。
- 内屏约为 iPad mini（744×1133）的 85%～90%，比任何一台 iPhone 都宽得多（Pro Max 竖屏 440）。

### 1.2 姿态

| 姿态 | 用哪块屏 | 要点 |
|---|---|---|
| 合上竖拿 | 外屏 466×678 | 手机版式；内容要让出右侧约 70 点的竖排系统栏（按截图估） |
| 合上横放（「帐篷」立在桌上） | 外屏 678×466 | 紧凑 × 紧凑；适合看片 |
| 展开，书本横向 | 内屏 951×669 | 宽版式；竖排系统栏在右 |
| 展开竖拿 | 内屏 669×951 | 宽版式；横排系统栏 |
| 半折，书本（折痕竖向） | 内屏左右两半 | 折痕上的按钮难点：按钮躲开折痕，滚动内容不用躲 |
| 半折，桌面 / 笔记本（折痕横向） | 内屏上下两半 | 上半看（视频），下半点（控制） |
| 分屏 50/50 | 内屏的一半，约 475 宽 | 回到紧凑宽度，即手机版式；竖排栏在各自的外侧边（可能在左） |
| 画中画钉在顶部 | 内屏 | 视频钉在上方，App 被纵向压缩 |

### 1.3 用哪个 SDK 编，决定了 Duo 上的样子

| 编译用的 SDK | 内屏 | 外屏 |
|---|---|---|
| iOS 26 及更早 | 不缩放，居中显示，四周留空 | 只用状态栏和摄像头左边那块 |
| iOS 27.0 | 铺满大部分，右边让出状态栏 | 同上 |
| iOS 27.1 起 | 铺满，系统栏改竖排 | 铺满，系统栏改竖排 |

**我们的现状**：0.5～0.7 用的是 27.0 SDK；**0.11.0（10-25 归档、10-26 传 TestFlight）已经是 27.1 SDK**。
也就是说现在这一版在 Duo 上已经全屏、系统栏竖排，但版式还是手机的。

工具链：本机和 CI（自建的 `xcode-27` 机器）都是 Xcode 27.1，27.1 的新接口可以直接用。
最低系统仍是 iOS 26，新接口要包在 `if #available(iOS 27.1, *)` 里。

App Store：Duo 截图（内屏 2007×2853、外屏 1398×2034）目前可选，**2027 年 4 月起用 27.1 SDK 编的 App 必须提供**。
提交了 Duo 截图，商品页就会显示「为 iPhone Duo 优化」的徽标。

## 2. 苹果的要点

摘自官方文档、人机界面指南和 5 场技术讲座（链接见 §9）：

1. **按尺寸类别和容器尺寸排版，不按设备、不按方向。** 苹果明确说：别把「常规宽度」当成「iPad」，
   iPhone App 现在可能遇到任何尺寸类别组合；内屏上的样子应该是 iPad 版式的自然延伸。
2. **别读 `UIScreen.main`**：两块屏时有歧义，将来会弃用。尺寸在会话中途会变（开合），每次布局都要重新取。
3. **系统容器优先**：TabView（内屏可以变侧边栏）、NavigationSplitView（外屏自动收成一栏）、
   表单（内屏居中）、菜单、提示框都会自动适配，也会自动躲开折痕。
4. **竖排系统栏**：只有导航栈和标签栏自带的栏会竖排，自绘的 `UIToolbar` 之类不算。
   工具栏项要同时给图标和文字：竖排时只显示图标，挤进溢出菜单时要用文字；纯文字项和自定义视图不会竖排。
   新接口有 `axisBehavior`、`visibilityPriority`、`ToolbarOverflowMenu`、`toolbarVerticalEdge`；「⋯」留给系统的溢出菜单。
5. **安全区不对称**：左右边距不相等，竖排栏可能在右也可能在左（分屏）。背景图可以铺到竖排栏下面，可交互的内容留在安全区里。
6. **保留区域**（27.1）：折痕是「分隔」区域，半折时有效，全开时宽度为 0；内屏摄像头是「遮挡」区域，开相机时才有效。
   接口：`GeometryProxy.reservedRegions(kind:)`、`UIView.reservedRegions(kind:)`。
7. **排列容器 `ArrangementView`**（27.1）：放一主一辅两个视图。`split` 是宽了左右分、高了上下分；
   `overlay` 是叠放，半折时把主视图挪到折痕的后侧或下侧。官方举的例子正是「播放器 + 接下来播放」。
8. **折痕**：按钮别放在折痕上，可滚动内容不用躲；网格用偶数列；折叠时做小调整，别大挪动。
9. **桌面模式可选**：上半放内容、下半放可点的控制。但**每种姿态的功能和层级要一样**，别把功能绑在某个姿态上。
10. **同一个体验**：开合不丢状态。内屏可以多显示一层（邮件：外屏是列表或正文，内屏两者并排）。
11. **全幅图片**：`.fill` 在更宽的屏上会裁掉主体，要按比例在 fill 和 fit 之间选。
12. **多任务**：所有 App 都会进 50/50 分屏；Duo 是第一台支持多窗口的 iPhone（只在内屏）；画中画可以钉在顶部。
13. 铰链接口（`onHingeChange`、`UIHingeInteraction`）给交互和特效用；排版用上面的区域和排列接口。

## 3. Netflix 与同行怎么做

| App | 外屏 | 内屏 | 半折 / 桌面 |
|---|---|---|---|
| Netflix | 竖向的 Clips 信息流（像抖音） | 展开后接着看；Clips 随开合、转动在竖版和横版之间切换；首页 Billboard 重做，加了动态视觉效果 | 新的播放控制在全屏、折叠、立起时都能用；**放成笔记本时控制落到下半屏，画面在上半屏** |
| Prime Video | | 大画布浏览电影、剧集 | 上半播放，下半是 X-Ray（演员、花絮） |
| MLB | | 比分、数据、排行 | 上半是比赛直播，下半是数据 |
| Paramount+ | | 更丰富的播放控制，浏览更宽 | 立在桌上免手持观看 |
| 爱奇艺 | | | 播放控制随姿态调整 |

Netflix 的出发点是把大屏的沉浸感随身带着。几家的共同做法：

1. 外屏做「随手刷」：短片段、快速浏览；
2. 内屏做「沉浸看」：更大的海报墙、首屏大图；
3. 桌面模式「上看下点」；
4. 开合时内容不断，从刚才的位置接着。

反面例子：评测里提到，没适配的 App 在 Duo 上有黑边、控件位置别扭、要点一下才放大，像当年 iPad 上跑的 iPhone App。

## 4. 我们现在在 Duo 上什么样

### 4.1 外屏实拍

环境：Xcode 27.1 的 iPhone Duo 模拟器，main 540b06981，合成测试片库（海报是占位图）。

- **首页**：系统 TabView 自动变成右侧竖排的胶囊；顶栏的「▶ ⋯ 搜索」竖排到状态栏下面；
  横滑行从竖排栏下面穿过，标题行右端的「查看全部」停在安全区内。**能用。**
- **详情页**：返回键和「⋯」竖排；正文和按钮排在约 395 点宽的区域里，正常。
  剧照只铺到安全区，右侧竖排栏下面是一条纯色，没有像 iPad 那样铺到栏下。
- **播放器竖拿**：16:9 的画面只占中间一条（466×262），上下大片是黑的。横放（帐篷）时画面是 678×381。
- **「接着看」条**：没看到它。同一账号的首页有「接下来继续」，按理会出现，推测竖排标签栏下系统不显示底部附件（待确认）。

### 4.2 内屏（按代码推断）

模拟器的开合只能在 DeviceHub 的图形界面里拨，`simctl` 和 XCUITest 都没有铰链接口（已核实），所以内屏没拍到。下表是读代码推出来的：

| 位置 | 现在的判断 | 内屏上的结果 |
|---|---|---|
| 卡片尺寸、Mac 式详情页、列表限宽、居中表单、剧照铺到侧边栏下 | `CardMetrics.forWindow`：常规宽度**且是 iPad**（`RemoteImage.swift:180`） | 全部走手机分支：手机详情页被拉到 951 宽（大图约 415 高，按钮横跨八九百点），列表一行拉满；带半屏档的弹层会变成 iPad 上踩过的「半高窄面板」（`AdaptiveDetents`） |
| 外壳 | `MainTabView.isPad`（`MainTabView.swift:497`） | 没有侧边栏，不逐个列库，页签只有图标 |
| 播放器转屏 | `PlayerOrientation.appControlsRotation` 判 idiom 是 `.phone`（`PlayerSystemBridges.swift:79`） | **退不出播放器**：内屏展开时画面宽大于高，被当成横屏，左上角变成「退出横屏」，点了去请求转竖屏（`PlayerScreen.swift:737`）。苹果说内屏要按尺寸类别走、不按 App 的方向设置——请求要么没反应，要么把竖版界面横着摆，两种都不对。横屏键同理。iPad 当初踩的就是这个坑 |
| 片段 | 进页面时锁竖屏（`ReelsView.swift:103`） | 内屏不认这个锁，信息流排在 951×669 的宽屏里，中间一条小横带 |
| 头像页签的手势 | 取「最右边」那个按钮当头像（`TabBarAccountGestures.swift:83`） | 竖排标签栏里各按钮横坐标相同，取到的不一定是头像：长按切换账号、双击切回可能挂到别的页签上（外屏同样） |
| 屏幕尺寸 | `UIScreen.main`（`RemoteImage.swift:56`）；手机详情页的大图高度按它算 | 两块屏时有歧义：取图档位、大图高度可能按外屏算 |
| 服务端能力上报 | `PlayerCapability.isPhone` 判 idiom（只有系统播放器那条路用到） | 内屏仍按手机限到 1080p，影响小 |

## 5. 原则

1. **版式看尺寸类别，卡片大小看观看距离。**
   - 宽版式（侧边栏外壳、Mac 式详情页、列表限宽、居中表单）的开关改成「常规宽 × 常规高」：
     内屏和 iPad 打开；Pro Max 横屏（紧凑高）和分屏仍是手机版式。
   - 卡片放大一档（海报 168）原本是给 iPad 的补偿，因为 iPad 离眼睛远。Duo 的 1 点和 iPhone 一样大，也按手机的距离看，
     所以**卡片维持手机尺寸，一行多排几张**。这是唯一建议继续看 idiom 的地方：它在这里代表「离眼睛多远」，不代表版式。
2. **开合只改排版，不改功能**，状态不丢（当前页、导航栈、播放进度）。
3. **系统容器先行，自绘的控件自己躲**：标签栏、导航栏、表单交给系统；
   播放器控制层、片段页的胶囊、首页大图这些自绘的，要自己处理不对称安全区、摄像头遮挡和折痕。
4. **外屏随手刷，内屏沉浸看，桌面模式上看下点**（同 Netflix）。
5. **iPhone 和 iPad 现有行为不变**：紧凑分支不动，「iPhone 截图与 main 逐像素一致」仍是验收标准。

## 6. 方案

### 6.1 P0：先别出错

改动都不大，现在的 TestFlight 版就需要。

| # | 改什么 | 文件 |
|---|---|---|
| 1 | 播放器的「App 能不能转屏」改按尺寸类别：常规宽 × 常规高（内屏、iPad）时方向跟随设备，不显示横屏键，返回键永远是「退出播放」；其余情况（外屏、普通 iPhone）照旧 | `PlayerSystemBridges.swift:79`、`PlayerScreen.swift:715,737`、`PlayerControls.swift:58,350` |
| 2 | `CardMetrics.forWindow` 改为「常规宽 × 常规高」才开宽版式；把 `isWide`（版式）和卡片尺寸（观看距离）拆成两件事，Duo 内屏是宽版式配手机卡片 | `RemoteImage.swift:94-197`；`TabRoot`（`MainTabView.swift:545`）要多传纵向尺寸类别；`CardMetrics.current` |
| 3 | 外壳的 `isPad` 换成按尺寸类别算的「侧边栏外壳」，经环境值传给 `AppTopBar`、`LibraryHomeView`；开合切换见 §6.2 | `MainTabView.swift`、`PadSidebar.swift`、`LibraryHomeView.swift:55` |
| 4 | 头像页签按页签顺序取最后一个按钮（竖排时就是最下面那个），不再取「最右边」 | `TabBarAccountGestures.swift:83` |
| 5 | 不读 `UIScreen.main`：窗口场景连上之后用 `windowScene.screen`；手机详情页的大图高度按页面尺寸算 | `RemoteImage.swift:53-86`、`LibraryItemDetailView.swift:336` |

做完 1～3，内屏就从「拉长的 iPhone」变成「iPad 版式」（这些代码 iPad 适配时都写好了），播放器也不会再退不出。

### 6.2 外壳与开合

- 内屏用 iPad 那套 `.sidebarAdaptable` 外壳，逐个列库与合集（2026-10-15 已定三端统一侧边栏）。
- **宽度账**：书本横向 951 点，展开侧边栏（约 300 点）后内容区约 620 点；收起时竖排标签栏只占约 70 点，内容区约 880 点。
  苹果说内屏侧边栏「适合信息密集的 App，不是每个都需要」，要用得显式写 `.defaultTabBarPlacement(.sidebar)`。
  建议**默认交给系统**，用户想要再展开；系统的默认状态以模拟器为准再定。
- **开合切换是新问题**：iPad 很少在侧边栏和标签栏之间来回切，Duo 每开合一次就切一次。要保证两件事：
  - 合上时如果停在侧边栏里的某个库或合集（`ShellTab.mediaLibrary` / `.collection`），外屏回到「媒体库」页签，
    把这个库压在栈上，返回能回到首页。反方向已经有 `Router.adoptSidebarLibraries`。
  - TabView 的风格别跟着开合切换，切风格可能整棵重建、丢掉导航栈。倾向于固定用 `.sidebarAdaptable`
    （紧凑宽度下系统本来就画普通标签栏），侧边栏专属的库和合集分组常驻、对标签栏隐藏。
    **先验证 iPhone 底栏逐像素不变**，不变再这么做。
- 外屏的竖排标签栏系统已经自动处理（实拍）；「接着看」条的去向待确认。

### 6.3 竖排系统栏（外屏全程，内屏横向）

- 顶栏按钮从「只有图标 + 读屏名字」改成 `Label(标题, systemImage:)`：竖排时只显示图标，挤进溢出菜单时才有文字。
- 媒体库顶栏自己的「⋯」菜单，27.1 起并进系统的 `ToolbarOverflowMenu`，免得空间不够时出现两个「⋯」；搜索给 `visibilityPriority(.high)`。
- 剧照、首页大图这类背景，在有竖排栏时铺到栏下面，做法同 `PadBackdropUnderSidebar`：
  竖排栏是液态玻璃，自己会模糊下面的画面，不用耗资源的 `backgroundExtensionEffect`。
- 弹层：外屏上表单的工具栏默认竖排；只有一个关闭键的控件型弹层用 `toolbarVerticalBehavior(.disabled)`。逐个过一遍弹层。
- 自绘的栏要自己让位：播放器顶栏右侧的胶囊、片段页的「全部 ⌄」胶囊。外屏右上角是摄像头，
  按不对称的安全区排（`bounds.inset(by: safeAreaInsets)`，别假设左右边距相等）。
- 片段页（实施时发现）：系统把返回键竖排到右侧，压在画面横带上。试过对这一页关掉竖排（`toolbarVerticalBehavior(.disabled)`，
  只有挂在 NavigationStack 上才生效），但外屏横排时状态栏和导航按钮挤在同一行，片名胶囊放不下；
  改为横带避开左右安全区，不画到竖排栏底下。

### 6.4 播放器：最该出彩的地方

| 姿态 | 做法 |
|---|---|
| 外屏竖拿 | 同 iPhone，横屏键照旧 |
| 外屏横放（帐篷） | 画面 678×381，比普通 iPhone 竖着看大得多；按 iPhone 横屏处理 |
| 内屏全开（书本横向 951×669） | 16:9 画面 951×535，上下各留约 67 点黑边；不显示横屏键，返回就是退出。可选：控制条落在上下黑边里，不压画面 |
| 内屏竖拿 | 画面在上，控制层照常；方向跟随设备 |
| **桌面模式**（内屏竖向半折，折痕横向） | 上半放画面（等比完整显示），下半是控制台：播放暂停、±10 秒、进度条（带缩略图）、音轨字幕、下一集和分集条、章节。功能和全屏时完全一样，只是换了位置 |
| 书本半折（折痕竖向） | 画面不动；正中的「后退 / 播放 / 前进」三颗按钮正好落在折痕上，整组挪到一侧（苹果叫「位移」） |

实现（实际做法见 §10：没用 `ArrangementView`，在现有布局上读折痕区域）：

- 桌面模式优先用 `ArrangementView` 的 `overlay`：主视图是控制层，辅视图是画面。
  全开时控制层叠在画面上（同现在）；半折时系统把主视图挪到折痕下侧，正好「上看下点」，过渡动画也是系统的。
  控制层落在下半屏时换成「控制台」排法（读 `overlayArrangementZIndex` 或可用区域大小）。不合适再退回自己读 `reservedRegions(kind: .division)`。
- 书本半折的位移：读折痕区域，中部按钮组整体挪到折痕外面。
- 全程不重建画面：开合时播放器视图只是变尺寸，引擎图层不能因为 `.id` 之类的原因重建（参考引擎画面在重建时一帧硬切的旧坑）。
- `PlayerCapability.isPhone` 改按屏幕尺寸判断，不按 idiom（只有系统播放器那条路用到，排在最后）。

### 6.5 片段：我们的 Netflix Clips

片段页本来就是竖向信息流，「全屏观看」交给正片播放器的片段模式（`PlaybackClip`）横着放，退出时靠 `router.clipReturn` 接着刷。
Netflix「外屏刷、展开接着看」那套管道我们已经有了，只差触发：

- 外屏：原样，竖向信息流、锁竖屏。
- **在片段页展开**：当前这一条自动进「全屏观看」，在内屏的大画面上接着放，不从头开始；
  **合上**：退回信息流里的同一条、同一个位置。
- 在内屏上直接打开片段页：信息流改成左边大画面（约 2/3 宽），右边是片名、简介和收藏 / 详情 / 已看 / 分享，上下滑仍是换一条。

### 6.6 用好内屏的大屏（P1～P2）

| 页面 | 内屏做法 | 出处 |
|---|---|---|
| 首页 | 首屏大图（照 Mac 版的「接下来继续」大图，限高 60%），相当于 Netflix 的 Billboard；下面的海报行一行多排几张 | ipad.md §4 待做项 |
| 海报墙 | 按手机卡片尺寸排，约 6 列；有折痕的设备取偶数列，让折痕落在两列之间 | 人机界面指南 |
| 条目详情 | 先用现成的 Mac 式大图区（全开时 951×535，正好一屏）；剧集再考虑横向时右侧常驻分集列表（多显示一层） | ipad.md |
| 设置、活动、订阅详情 | 列表加详情两栏（`NavigationSplitView`，合上自动收成一栏），和 iPad P2 共用一份 | ipad.md P2 |
| AI 会话 | 内屏横向时放在右侧检查器里，带上当前页的上下文 | ipad.md P2 |
| 多窗口 | 「在新窗口中打开」某部片，只在内屏可用 | ipad.md P3 |

### 6.7 暂不做

- 用铰链角度做特效：没有合适的场景。
- 场景附件（外屏同时显示内容）：目前公开的只有拍照用的 `CameraCaptureAccessory`，看片用不上。
- 在外屏开新窗口：系统不允许。

## 7. 分期与验收

| 期 | 内容 | 验收 |
|---|---|---|
| P0 | §6.1 的五项 | 单测：`CardMetrics` 的尺寸类别真值表、`appControlsRotation` 按尺寸类别、竖排和横排标签栏的头像定位。DeviceHub 里展开，从详情页起播，点返回能退出。iPhone 截图与 main 逐像素一致，iPad 不变 |
| P1a | 外壳开合（§6.2）、竖排系统栏（§6.3） | 各姿态逐页截图：合上竖拿 / 横放、展开横向 / 竖向、分屏在左 / 在右。停在侧边栏的某个库时合上再展开，导航栈不丢 |
| P1b | 播放器桌面模式与位移（§6.4）、片段开合接续（§6.5） | 端到端：外屏起播 → 展开后接着放、不卡顿 → 半折成桌面模式，控制落到下半屏且功能齐全 → 合上仍在播。片段页刷到第 3 条 → 展开进全屏观看、从同一位置接着 → 合上回到第 3 条 |
| P2 | §6.6 | 同 iPad 的 P2、P3 |
| 上架 | App Store Connect 补 Duo 截图（拿徽标，2027 年 4 月起必需）；`ios-release-checklist.md` 加 Duo 项；审核备注写明 | — |

测试手段：

- Xcode 27.1 自带 iPhone Duo 模拟器。开合、半折、分屏只能在 DeviceHub 里点（`simctl` 和 XCUITest 都没有铰链接口），
  所以姿态相关的验收靠人工走查加截图；尺寸类别判断、区域计算这些逻辑写单测。
- 别用 `simctl io <设备> screenConfig --display=<外屏> power off` 模拟合上：内屏不会接管，模拟器还会卡死（调研时踩过）。
- 两块屏分别截图：`simctl io <设备> enumerate` 查屏幕 UUID（每次开机都会变），再 `simctl io <设备> screenshot --display=<UUID>`。

## 8. 已定（2026-10-27 用户按推荐拍板）

| 决策 | 定了什么 |
|---|---|
| 发版节奏 | P0 单独尽快发，大屏优化随后 |
| 内屏侧边栏 | 默认收起、可展开；Duo 上若没有展开入口，就不要侧边栏（库从「媒体库」页进，同 iPhone） |
| 卡片尺寸 | 手机尺寸（海报 124），宽版式只管排法；看过再微调 |
| 播放器桌面模式 | 做，先试 `ArrangementView`；书本半折时中部按钮组挪开 |
| 片段 | 正在播放时展开，自动进全屏观看；合上回到原来那一条、原来的位置；暂停时不自动进 |
| Duo 截图与徽标 | 桌面模式、片段接续做完再交（2027-04 前必须交） |
| 技术取舍 | 标签栏风格不随开合切换（先验证 iPhone 底栏逐像素不变）；控制条不放进黑边 |

仍待确认：竖排标签栏下 `tabViewBottomAccessory`（「接着看」条）去了哪里。

## 9. 资料

苹果：

- [Get ready for iPhone Duo](https://developer.apple.com/iphone-duo/)、[Three steps to make your app shine on iPhone Duo](https://developer.apple.com/iphone-duo/prepare/)
- [Preparing your app for iPhone Duo](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo)
- [人机界面指南：Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)
- 技术讲座：[Prepare your app](https://developer.apple.com/videos/play/tech-talks/111461/)、
  [Design for iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111466/)、
  [Raise the bar](https://developer.apple.com/videos/play/tech-talks/111462/)（竖排系统栏）、
  [Strike a pose](https://developer.apple.com/videos/play/tech-talks/111463/)（保留区域、排列容器）、
  [Leverage multiple displays and scenes](https://developer.apple.com/videos/play/tech-talks/111464/)（铰链、分屏、多窗口）
- [截图规格](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications)、
  [技术规格](https://www.apple.com/iphone-duo/specs/)、
  [新闻稿：开发者为 iPhone Duo 带来的新体验](https://www.apple.com/newsroom/2026/10/developers-bring-incredible-new-app-experiences-to-iphone-duo/)

Netflix 与同行：

- [What's on Netflix：Netflix 为 iPhone Duo 重新设计了 App](https://www.whats-on-netflix.com/news/netflix-has-redesigned-its-mobile-app-for-iphone-duo-whats-different/)
- [TechCrunch：These clever apps show off the iPhone Duo's potential](https://techcrunch.com/2026/10/24/these-clever-apps-show-off-the-iphone-duos-potential/)

## 10. 实现情况（2026-10-27）

| 项 | 做法 | 代码 |
|---|---|---|
| 版式判断 | `WindowLayout.isWide`：常规宽 × 常规高才是宽版式；宽版式、侧边栏外壳、居中表单、列表限宽都按它 | `Shared/DesignSystem/RemoteImage.swift` |
| 卡片尺寸 | `CardMetrics.forWindow(wide:)`：宽版式时 iPad 用 `wide`（168）、其余用 `widePhone`（手机卡片尺寸、页边距 24）；有折痕时网格取偶数列（`evenColumns`，`TabRoot` 读保留区域） | 同上、`MainTabView.swift` `TabRoot` |
| 外壳 | 侧边栏外壳只给 iPad（`sidebarShell` = iPad 且宽版式）。Duo 内屏实测：可展开侧边栏的标签栏样式在 Duo 上没有展开入口，系统还把侧边栏专用的收藏、各个库塞进竖排标签栏、把「活动」「我的」挤进「⋯」，片段页也藏不掉标签栏——按 §8「没有展开入口就不要侧边栏」，Duo 始终是手机外壳，竖排横排交给系统。iPad 窗口拉窄时 `Router.collapseSidebarSelection` 折回「媒体库」页签并清掉侧边栏库清单 | `MainTabView.swift`、`Router.swift` |
| 头像手势 | 按页签顺序取最后一个按钮（竖排取最下，`lastTabIndex`） | `TabBarAccountGestures.swift` |
| 屏幕 | `ImageWidth` 取前台窗口场景的屏，冷启动才退回 `UIScreen.main` | `RemoteImage.swift` |
| 播放器转屏 | `appControlsRotation(wide:)`：宽版式不转屏、返回即退出；展开时 `followDevice` 解开外屏的方向锁 | `PlayerSystemBridges.swift`、`PlayerControls.swift`、`PlayerScreen.swift` |
| 桌面模式控制台 | 2026-10-28 用户看过桌面模式后要求照 Netflix 把下半屏卡片化，看过第一版平铺卡片后又要求更好看、更有创意，定稿为「便当盒」（`PlayerTabletopDeck`）：顶栏、进度条之下，左边大播放卡（白色实心播放键 + 两侧前进后退 + 已播 / 总长），右边 2×2 方块（音轨、字幕、画质、画面，写当前值，打开面板时反白）；剧集的「下一集」是播放卡里时间旁的一枚小胶囊（原先是独占一行的带剧照横幅，真机桌面模式控制台比模拟的矮，把右侧方块挤得叠在一起，用户指出后收进播放卡；片尾另有带倒计时的下一集卡片）；最下面倍速是直接可点的分段条（白色药丸滑动），播放诊断收成末尾小圆钮。底下垫本集剧照（电影用海报）的模糊氛围色（`DeckAmbience`，小图静态模糊，无逐帧开销），卡片是液态玻璃。音轨、字幕面板从折痕往上长、盖在画面上；画质、画面是系统菜单（与「⋯」同一份选项，开菜单时收起面板）；临时卡片仍浮在画面右下角 | `PlayerTabletopDeck.swift`、`PlayerScreen.swift`（`tabletopChrome`）、`PlayerControls.swift` |
| 桌面模式 / 书本半折 | `PlayerFold`：读生效的分隔区域，横向折痕时画面收进上半屏、控制层落到下半屏并常显；竖向折痕时中部按钮组挪到右半边（放不下时不出屏）。没用 `ArrangementView`：控制层是一整套叠层，拆不成「一主一辅」 | `PlayerFold.swift`、`PlayerScreen.swift` |
| 片段 | 在片段页展开、正在播放时自动进全屏观看；全屏观看中合上，退回信息流原来那一条与位置；宽页面横带限高 58%；横带避开左右安全区 | `ReelsView.swift`、`PlayerScreen.swift` |
| 竖排栏 | 顶栏按钮改 `Label`（带标题）；详情页剧照在有竖排栏时铺到栏下（`BackdropUnderVerticalBar`，读 `toolbarVerticalEdge`） | `MainTabView.swift`、`LibraryHomeView.swift`、`ImmersiveHero.swift`、`LibraryItemDetailView.swift` |

没做：搜索的 `visibilityPriority`、「⋯」并进 `ToolbarOverflowMenu`（外屏没出现两个「⋯」，等真出现再做）；§6.6 的 P2；上架截图。

### 10.1 测试

- 单测 `MovieClawTests/IPhoneDuoLayoutTests`（22 项，连同 `PadSidebarRouterTests`）：版式档真值表、卡片列数与偶数列、
  转屏开关、折痕排法（含不出屏）、横排 / 竖排标签栏的头像定位、合上时的路由。
- Duo 模拟器外屏实拍：首页（系统竖排标签栏、底栏样式固定后无变化）、详情页（剧照铺到竖栏下）、片段页（横带避开竖排栏）、
  播放器用 `-mcSimulateFold tabletop|book` 假装有折痕核对两种排法。
- iPhone 17（iOS 27.0）回归：main 与本分支同一组页面逐像素对比，差异只有两轮之间变化的播放进度；iPad mini 回归：
  库页、详情页一致（只有玻璃按钮边缘约 500 像素的抗锯齿差）。
- 内屏（2026-10-28，用户在 DeviceHub 里展开后实测）：首页宽版式、手机外壳竖排标签栏、接着看条；详情页 Mac 式大图区；
  海报墙 6 列手机尺寸卡片；片段页标签栏隐藏、横带限高；播放器点返回直接退出；用户实测真实桌面模式画面在上、控制在下。
  桌面模式控制台在内屏竖向（669×951，与真机桌面模式同尺寸）配合 `-mcSimulateFold tabletop` 点过：音轨方块反白并打开面板、
  倍速分段条点 1.5× 后药丸与进度条角标更新、暂停；剧照会撑开布局的坑已修（氛围图挂在不占尺寸的框上）。
- 没测到：片段页展开 / 合上的自动接续（要连续拨铰链）。
