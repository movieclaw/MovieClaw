# MovieClaw 鸿蒙端：Apple 工程审阅与原生重写方案

> 结论先行：Apple 端 **77,024 行手写业务代码**是要转译的目标；鸿蒙端现有 **8,612 行手写 ArkTS**
> （另有 9,433 行由生成器自动产出的 API 层），完成度约 **11%**。
> 缺口不在接口层——`Endpoints.ets` / `Models.ets` 已与 iOS 侧逐条对齐（356 端点 / 486 模型），
> **缺的几乎全是页面**。

---

## 0. 铁律：逻辑照 iOS，**布局也照 iOS**，控件用华为原生

> **2026-10-02 用户补充定调**：之前只说了「UI 用华为原生」，容易被理解成版式也可以自己发挥——
> 不是的。**页面布局（什么放哪、放什么按钮、顺序与分组）要和 iOS 一致**；
> 「华为原生」指的是**控件用它家的**（`HdsTabs`、`bindSheet`、`SymbolGlyph`、系统材质…），
> 不是让你重新设计版式。做每个页面前**先打开 iOS 对应的那个 View 文件**，照着摆。

---

## 1. Apple 工程全貌

用户定的总原则，所有改动都按这条来：

- **逻辑一一对应**：iOS 怎么处理，鸿蒙就怎么处理——同样的事件顺序、同样的并发结构、
  同样的边界处理、同样的文案口径。只把语言从 Swift 换成 ArkTS，**行为不许自作主张**。
  移植每一处前，先去 iOS 端读对应的那段代码，照着写；不要「顺手优化」。
- **UI 用华为原生**：视觉与交互用 HDS / 系统控件（`HdsTabs`、系统材质、系统弹层…），
  不照抄 iOS 观感。UI 层的差异是**平台适配**，不算分叉。
- **判断标准**：一处改动如果**用户能观察到行为不一样**（数据旧了、顺序变了、
  该出现的东西没出现），就是分叉，必须改；如果只是实现手法不同（`LazyVGrid` vs
  `LazyForEach`、`async let` vs `Promise.all`），但结果一致，那是正确移植。

### 已经踩过的分叉（都是「看着像优化，其实是行为差异」）

| 分叉 | iOS 的真实行为 | 后果 |
|---|---|---|
| 给墙数据源加「指纹去重」（只看列数+条数+首尾 id，相同就跳过刷新） | `pager.refresh()` 每次都把新窗口**整体赋值**（`items = rows`），由 SwiftUI 按 id diff | 中间某条的海报更新了会被当成「没变」跳过 → **墙显示旧数据** |
| 详情页 `reload()` 写成串行 `await` | iOS 用 `async let` 七路并发 | 首屏耗时变成各路之和，管理员要串 8 个往返 |
| 账号头像只画了渐变圆 + 首字，没读 `avatar_url`（2026-10-07 修，**同一处疏漏共 4 个位置**） | `AvatarBadge` 是**两层**：底层渐变圆 + 首字，**上面还有一层** `if url != nil { RemoteImage(...) }`。iOS 用在「我的」页 56、`overviewCard` 72、`AccountSwitcherSheet` 40、成员行 38 | 底栏页签早已用同一份 `session.avatar_url` 显示真图，这四处却永远显示首字——**同一 App 内同一个账号在不同地方长得不一样，点进「我的」反而退化**。根因是只移植了 `AvatarBadge` 的底层那半 |
| 底栏头像页签**只有双击切回上一个账号，没有长按弹出切换账号抽屉**（2026-10-07 修） | iOS 是**长按**弹出 `AccountSwitcherSheet`（半屏抽屉），**双击**切回上一个账号；两个手势通过 `AccountGestureHub` 挂在窗口上，只收落在头像按钮里的触摸（0.45 秒长按 + 双击互斥） | 切换账号必须先进「我的」页再点「切换账号」，多两步，不符合「家里几个人共用 App、切换账号是高频操作」的设计意图。鸿蒙底栏头像页签之前只有双击，长按没接 |

发现新分叉时**补进这张表**，别只改代码。

### 有意保留的差异（鸿蒙 ≠ iOS，已确认、待用户裁决）

| 差异 | iOS 的行为 | 鸿蒙的行为 | 为什么先留着 |
|---|---|---|---|
| 图片缓存按账号隔离 | Nuke 按 **URL** 缓存（300MB 磁盘 + 内存），切账号**不清**；`AuthorizedDataLoader` 用「当且账号」的令牌 | 缓存键 = 「服务器+账号+URL」，切号后旧账号的条目读不到 | iOS 这套在换账号后会把上一个账号解出来的海报直接命中缓存返回——同一台服务器上两个权限不同的账号之间**会串图**。鸿蒙这处是在「修现有 4 个真 bug」里明确批准修的。**要真正两端一致，正确做法是两端一起修**（iOS 给 Nuke 加 cacheKey 前缀或切号清缓存），而不是把鸿蒙改回去。 |

**除这一条外，其余全部按「逻辑照 iOS」执行。** 发现新的「有意差异」必须补进本表并说明理由。

---


`MovieClaw/apps/apple/`，535 个 Swift 文件、195,576 行。但真正要转译的只是一部分：

| 目录 | 行数 | 是否要转译 | 说明 |
|---|---:|---|---|
| `Vendor/AetherEngine/` | 96,402 | **否** | FFmpeg 解封装 + 就地换封装成 HLS 给 AVPlayer 的自研播放内核（271 文件）。鸿蒙走系统媒体栈，整块不适用 |
| `Core/API/Generated/` | 13,587 | **已自动转译** | `tools/gen_api_arkts.py` 从生成的 Swift 转出 ArkTS，逐条对齐 |
| `MovieClawTests/` + `MovieClawUITests/` | 7,297 | 参考 | 测试用例是行为规格，转译时可当验收清单 |
| `MovieClaw/Features/` | 69,198 | 是 | 14 个功能模块，移植主战场 |
| `MovieClaw/Core/` | 15,433 | 是 | 网络、会话、令牌、快照、打点 |
| `MovieClaw/DesignSystem/` | 4,431 | 是 | 21 个自研组件 |
| `MovieClaw/App/` | 1,549 | 是 | 入口、AppModel 状态机、路由 |
| **手写业务代码合计** | **77,024** | | |

生成链路：后端 FastAPI 路由表 → `apps/apple/scripts/gen_api.py` → Swift → `tools/gen_api_arkts.py` → ArkTS。
两跳，好处是鸿蒙端不必重复实现一遍代码生成，代价是**依赖 iOS 端先重新生成**。

---

## 2. iOS 端已有的三条硬约定（鸿蒙要跟着走，别另立一套）

`docs/design/ios-app.md` §3 定的规矩，直接决定鸿蒙端的目录与写法：

1. **页面骨架三态**：`Loadable<T>` + `AsyncContent(state, retry:)`；空态 `EmptyState`、失败 `ErrorState`
   （后端的中文原因原样显示）。轮询用 `.polling(every:)`，随页面可见性与前后台启停。
2. **秒开三件套**：`PageSnapshots`（磁盘快照）+ `FirstScreenImages`（首屏图片预解码）+ `FirstFrameGate`（不急的启动工作等首帧）。
3. **视觉只定颜色与尺寸，控件一律用系统材质**——原文是「原生控件（列表、按钮、标签栏、工具栏）一律用系统的液态玻璃材质」。
   **这一条正好就是「用华为原生 UI」在鸿蒙上的落法**：iOS 用 `.glassEffect` / `.buttonStyle(.glass)`，
   鸿蒙用 HDS（`@kit.UIDesignKit`）。两边都是「跟随系统设计语言，不自绘观感」。

跨端身份约定：`请求标识 MovieClaw-<iOS|tvOS|Android>/<版本>`，Bundle ID 统一 `io.movieclaw.app`。

---

## 3. 鸿蒙原生能力盘点（已从本地 SDK 核实，非猜测）

本地 SDK：`/Applications/DevEco-Studio.app/Contents/sdk/default`，HarmonyOS 6.1.1 / API 24。

### 3.1 原生 UI —— HDS（`@kit.UIDesignKit`）

华为自己的设计系统组件，等于 iOS 那边的系统材质控件：

| 组件 | 替代 iOS 的什么 |
|---|---|
| `HdsNavigation` / `HdsNavDestination` | `NavigationStack` + 大标题 + 滚动模糊 |
| `HdsTabs` | `TabView`（含 `HdsTabsMiniBar` 滑动收起的小胶囊 = iOS 的 `tabBarMinimizeBehavior`） |
| `HdsListItemCard` / `HdsListItem` | `List` + `insetGrouped`（含左滑 `HdsSwipeActionOptions`） |
| `HdsActionBar` / `HdsSnackBar` | 工具栏 / Toast（对应 `Feedback`） |
| `HdsSideBar` / `HdsSideMenu` | 折叠屏、平板的分栏导航 |

### 3.2 沉浸光感 —— 真·系统能力，不是形容词

| API | 作用 |
|---|---|
| `hdsMaterial.MaterialType.IMMERSIVE` + `MaterialLevel.{EXQUISITE,GENTLE,SMOOTH}` | 沉浸材质，挂在 `systemMaterialEffect` 上 |
| `hdsEffect.PointLightSourceType` / `PointLightIlluminatedType`（BORDER / CONTENT / BORDER_CONTENT）| **点光源照亮**边框或内容，配 `PointLightOptions{color,intensity,height,bloom}` |
| `hdsEffect.EffectType.DUAL_EDGE_FLOW_LIGHT` / `UV_BACKGROUND_FLOW_LIGHT` | 边缘流光 / 背景流光 |
| `HdsVisualComponent` + `HdsSceneType.DUAL_EDGE_FLOW_LIGHT_WITH_BACKGROUND_MASK` | 双边缘流光 + 背景蒙版，由 `HdsSceneController` 控制起停 |
| `hdsEffect.PressShadowType` | 按压缩影（BLEND_GRADIENT / BLEND_WHITE） |

**系统已经内建好了，落在两个地方**（`SystemMaterialParams.systemMaterialEffect` 在 HDS 里只出现在这两处）：

- `TitleBarStyleOptions.systemMaterialEffect` —— 导航标题栏
- `HdsTabsFloatingStyle.systemMaterialEffect` —— 悬浮标签栏

也就是说，**顶栏与底栏的沉浸光感是打开就有**，不要自己用半透明白去模拟。
自定义场景（Hero、卡片按压、加载态）才需要自己拼 `hdsEffect` 的点光源 + 边缘流光。

#### 实测配方：悬浮沉浸导航栏（已在真机跑通）

底部导航栏已从自绘 `Tabs` 换成 HDS `HdsTabs`（`entry/src/main/ets/pages/MainTabsPage.ets`）：

```ts
import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';

HdsTabs({ barPosition: BarPosition.End, controller: this.tabsController }) {
  TabContent() { /* 页面 */ }.tabBar(this.TabBarIcon(tab, index))   // 自定义 builder 也算数
}
.barOverlap(true)                    // ★ 关键，见下
.barFloatingStyle({
  barSideMargin: 16,
  barBottomMargin: 12,
  adaptToHandedness: true,           // 智感握姿：页签栏跟随握持手
  systemMaterialEffect: {
    materialType: hdsMaterial.MaterialType.IMMERSIVE,
    materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
  }
})
```

**踩过的坑，按顺序记下来，省得重走：**

1. **只写 `barFloatingStyle` 不会悬浮**。页签栏仍是通栏平铺的黑条，跟没设一样。
   加上 **`.barOverlap(true)`** 才真正变成内缩的圆角胶囊、叠在内容之上、背后做毛玻璃。
   官方文档把 `barOverlap` 描述成「背后变模糊并叠加在 TabContent 之上」，没提它和悬浮的关系——
   但实测它就是那个开关。
2. **5 个页签时胶囊宽度上限 328vp**（文档口径：页签数 ≥4 时最大 328vp），
   所以手机上它是一条居中的短胶囊，不是通栏。
3. **材质会采样背后的内容**：胶囊下面的海报颜色会透上来（左侧是红色海报时胶囊左边就发暖）。
   这就是「沉浸光感」的实际观感，不是 bug。
4. **本机确认支持沉浸材质**：`hdsMaterial.getSystemMaterialTypes()` 返回 `[101]`（`IMMERSIVE`）。
   不支持时系统会退回，不会报错——排查时先量这个。
5. **`barOverlap` 会带来底部遮挡**：内容从胶囊下面穿过去，页面自己不空出高度，
   最后一行就被胶囊压住（首页最后一行海报标题实测被盖）。
   统一用 `Theme.tabBarInset`（76vp = 胶囊 48 + 边距 12 + 呼吸）给滚动内容留底部空间。
6. HDS 的完整中文文档在 **DevEco 安装目录里有离线副本**（官网是 SPA，抓不到）：
   `plugins/openharmony/ohos-info-center-view/static/hos/JsEtsAPIReference/`。
   查 HDS/ArkUI 接口时直接读这里，比联网快也更全。
7. **`miniBar` 试过、结论是不要用**（至少别指望它做「上滑收起」）。
   `HdsTabsFloatingStyle.miniBar` 配上 `miniBarBuilder` 之后，迷你栏会以一个小圆钮的形态
   **和页签栏并排显示**（`HdsBarLayoutMode.HORIZONTAL` 的默认排法），不是收起态。
   而控制器上的 `applyHideAnimation()` 会把**页签栏和迷你栏一起藏掉**
   （实测截图底部完全空白），随后 `applyMiniBarStyle(EXPAND)` 也召不回来。
   也就是说官方没给「页签栏收成迷你栏」的开箱行为，要做只能自己驱动，性价比低。
   当前的悬浮胶囊（`barOverlap` + `barFloatingStyle` + 沉浸材质）已经够用。
8. **`gradientMask` 建议显式设**：内容滑到页签栏下面时渐隐过去，而不是被硬切一刀
   （默认色是深色模式 `#99000000`，本项目底色纯黑，显式给 `Theme.bg` 更贴）。

对位关系很清楚：iOS 的 Hero 是「剧照推近 + 压暗托字 + 氛围取色」，
鸿蒙上是「**沉浸材质托底 + 点光源照亮边框/内容 + 边缘流光**」——
各自用各自系统的语言表达同一件事：内容浮在材质上、边缘在发光。

### 3.3 智能握持检测 —— 官方名叫「智感握姿」

`@ohos.multimodalAwareness.motion`（API 15+）：

```ts
import { motion } from '@kit.MultimodalAwarenessKit';
motion.on('holdingHandChanged', (s: motion.HoldingHandStatus) => { /* ... */ });
// HoldingHandStatus: NOT_HELD / LEFT_HAND_HELD / RIGHT_HAND_HELD / BOTH_HANDS_HELD / UNKNOWN_STATUS
motion.getRecentOperatingHandStatus()   // 左/右手操作（API 15+）
```
权限：`ohos.permission.DETECT_GESTURE`（user_grant，声明在 `module.json5` 的 `requestPermissions`）。

**但多数场景不用自己写**：`HdsTabsFloatingStyle.adaptToHandedness` 是系统内建的
「悬浮标签栏跟随握持手」，打开就有。自研订阅的必要性只在「不止标签栏要跟着动」时才成立。
另外 HDS 里还有 `MultiWindowEntryInAPP` 等系统件，说明这套组件的定位就是「原生体验开箱即用」。

---

## 4. 鸿蒙端身份识别的限制（**需后端配合，本次不改**）

> **边界说明**：`MovieClaw/` 是开源参考工程（含后端与 Apple 端），**只读**。
> 本节的改动全部落在它里面，因此本次**不做**，只作为给后端维护方的交接说明。

鸿蒙端现在是**借 android 位**在跑：

- `entry/src/main/ets/common/AppModel.ets:132` 登录时上报 `kind: 'android'`，
  代码注释自己写了「鸿蒙不在后端枚举 `Literal["ios","tvos","android"]` 里，借 android 位」。
- `entry/src/main/ets/api/ApiClient.ets:122` 的 UA 已经是 `MovieClaw-HarmonyOS/0.1.0 (...)`，
  但后端 `_APP_USER_AGENT` 正则只认 `iOS|tvOS|Android`，匹配不上。

要让鸿蒙成为一等公民，后端需要动四处（已实测过改动方案，UA 解析验证通过）：

| 位置 | 现状 | 需要 |
|---|---|---|
| `schemas/auth.py:221` | `kind: Literal["ios","tvos","android"]` | 加 `"harmonyos"`，否则登录 422 |
| `login_devices.py` `KINDS` | 只有 web/ios/tvos/android/cli/worker/manual | 加 `"harmonyos": KindSpec("HarmonyOS App", interactive=True, family="login")` |
| `login_devices.py` `APP_KINDS` | `("ios","tvos","android")` | 加 `"harmonyos"` |
| `playback/watch.py` | `_APP_CLIENTS` 三端 + `_APP_USER_AGENT` / `_APP_SYSTEM` 正则 | 加 `"HarmonyOS"` 与 `OpenHarmony`（见下） |

顺带两个实测发现，改后端时要注意：

1. **别用 `deviceInfo.osFullName` 拼系统名**。真机（VOL-AL00）上它返回
   `OpenHarmony-7.0.0.107`，带构建号且 OS 名是 OpenHarmony。正确的是
   `distributionOSName` + `distributionOSVersion` → `HarmonyOS 7.0.0`。
   所以后端的 `_APP_SYSTEM` 正则要同时认 `HarmonyOS` 和 `OpenHarmony`，分隔符可能是空格也可能是 `-`。
2. 同一批设备列表还有 `apps/web/lib/devices-display.ts:154` 的分组
   （`deviceGroupKey` 只把 ios/tvos/android 归「App」组，鸿蒙会掉进「命令行与转码器」）
   和 `apps/apple/.../DevicesSettingsView.swift:185` 的同类过滤。

不改后端也能跑（借位），代价是：活动页、webhook、播放上报里都认不出这是鸿蒙端，
「我的设备」里也是错的平台名。**在拿到后端改动权之前，这部分保持现状。**

---

## 5. 鸿蒙端现状与缺口

### 5.1 已完成

| 层 | 文件 | 状态 |
|---|---|---|
| API | `api/Endpoints.ets`(2832) `Models.ets`(6601) `JsonValue.ets`(91) | 生成器产物，356 端点 / 486 模型，与 iOS 对齐 |
| 网络 | `api/ApiClient.ets`(327) `common/ServerAddress.ets`(80) | 信封、错误映射、401 回调、UA、中文网络文案 |
| 会话 | `common/AppModel.ets`(193) `common/Permissions.ets`(63) | 单服务器单账号、登录/登出、令牌落 preferences |
| 主题/图片 | `theme/AppTheme.ets`(54) `common/RemoteImage.ets`(179) | token 全量、带令牌的图片内存缓存 |
| 媒体库 | `library/` 9 文件 | 首页 + 单库页骨架 + 全部合集 + 筛选，约 40% |
| 外壳 | `pages/Index.ets` `WelcomePage.ets` `MainTabsPage.ets` `MorePage.ets` | 欢迎页 35%、其余骨架 |

### 5.2 缺口（按「不改就不像能用」排序）

**A. 公共基建，所有模块的地基**

1. **`EventStream`（SSE 客户端）—— 完全没有**。Activity（`/jobs/stream`）、Search（`/search/torrents/stream`）、
   Agent（`/sessions/{id}/events`）三个模块全靠它。ArkTS 无 `EventSource`，
   需 `http.createHttp().requestInStream()` + `on('dataReceive', Callback<ArrayBuffer>)` 手写
   逐字节切行解析（**必须自己处理跨 chunk 的多字节 UTF-8**，否则中文乱码），支持 `Last-Event-ID` 续传。
2. **`VisiblePolling`（可见期轮询）—— 各页面自写 `setTimeout`**。iOS 的 `.polling` 能感知前后台、
   回前台补刷、间隔变更立即重起表；鸿蒙现有实现没有这些，且 `aboutToDisappear` 会误停被压栈的页面。
3. **`PageSnapshots`（磁盘快照）—— 完全没有**。iOS 冷启动第一帧就是完整页面（约 150KB 同步读），
   鸿蒙冷启动必过 loading。
4. **`SavedServers` + 多账号令牌（ASSET）—— 完全没有**。iOS 是「服务器 → 多账号 → 各自令牌」，
   鸿蒙只有单 origin 单 token，**切号即登出**；且令牌明文落 `preferences`（应换
   `@ohos.security.asset`）。这一条也卡住了「切换账号」这个功能。
5. **Router（27 条路由）—— 只有 2 条 `router_map`**。iOS 的 `AppRoute` 27 个 case + 每页签独立
   `NavigationStack` + webPath 深链解析 + 权限守卫，鸿蒙全无。

**B. 已知的正确性/性能缺陷（现有代码里就有的）**

| # | 位置 | 问题 | 后果 |
|---|---|---|---|
| 1 | `library/LibraryDetailPage.ets:1334` `TimelineSections` | `build()` 里只有一个空 `Stack(){}` | **非刮削库（家庭录像/照片库）整页静默空白**，类型检查全过、不报错 |
| 2 | 全仓库 | `LazyForEach` / `cachedCount` / `@Reusable` **各 0 处** | 海报墙 60 项一次性全建（`Scroll > Column > ForEach(chunked(...))`），大库必卡 |
| 3 | `common/RemoteImage.ets:43` | 缓存 key 是**裸 URL**，令牌取「当前账号」，切号时**不清缓存** | 换账号后同 URL 命中上一个账号的 `PixelMap`，**串号显示他人海报** |
| 4 | `common/RemoteImage.ets:76` | `createPixelMap()` 无 `desiredSize` | 全分辨率解码，一张海报几十 MB 内存 |
| 5 | `common/AppModel.ets:57` | 401 无条件踢人，**不比对令牌** | 切号瞬间在途的旧令牌 401 会把新会话踢下线 |
| 6 | `library/HomeRows.ets:17` 与 `library/LibraryWall.ets:29` | `WallSortDirection` **重复定义两份** | 迟早分叉 |
| 7 | `library/LibraryHomeView.ets:362` | `collections` 被降维成 `number[]` | 筛选条的合集 chip 拿不到完整对象，必然返工 |
| 8 | `pages/MainTabsPage.ets` 等多处 | 页签/行 `comingSoon(...)` 十余处 | 「查看全部」「条目详情」「播放器」「搜索」「管理媒体库」等主路径点了没反应 |

**C. 逐模块缺口**

| 模块 | iOS 行数 | 鸿蒙现状 | 主要缺口 |
|---|---:|---|---|
| Library | 20,252 | ~40% | 条目详情页（22 端点已绑定、纯缺页面）、管理页、合集详情、收藏页、待处理抽屉、照片墙/图床 |
| Settings | 10,500 | 0% | 18 个分区全无；`MorePage` 只有一行占位 |
| Player | 9,450 | 0% | 整块待做，且实现路径与 iOS 完全不同 |
| Subscriptions | 6,478 | 0% | 首页 Hero/日程/货架、规则组编辑器（1113 行）、7 个弹窗 |
| Activity | 5,563 | 0% | SSE 基线的第二个验证点；统计图表需自绘 |
| Search | 4,053 | 0% | 三垂直；ArkUI `Search` 无 token 能力，版式必须改 |
| Agent | 3,826 | 0% | SSE + 自研 Markdown 渲染器（716 行无对应库） |
| Discover | 2,563 | 0% | 建议作为 P0 首战：无 SSE 依赖，且能一次沉淀通用组件 |
| Reels | 2,167 | 0% | 短视频流 |
| Onboarding | 1,599 | ~35% | **缺 `needsSetup`（新服务器创建超管）→ 新用户直接走不通**；缺局域网发现、账号选择、连不上卡片 |
| Share | 811 | 0% | 访客免登录；Cookie jar 要自管 |
| Notices / About | 301 | 0% | About 是上架合规必需，成本低 |

**D. DesignSystem 21 个组件的去留**（4431 行）

不是所有组件都该转译，有几件在鸿蒙上是**多余的**：

| 处理 | 组件 | 原因 |
|---|---|---|
| **直接删** | `SheetFeedback`(27) | 它存在的唯一原因是 UIKit 不允许在已呈现的 sheet 上再弹 alert。鸿蒙 `bindSheet` 与页面同树同 UIContext，没这个限制 || **直接删** | `PlaceholderPage`(12) | 开发占位 |
| **直接删** | `TextNumberInterpolation`(16) | ArkTS 模板字符串**不会**自动给数字加千分位（iOS 踩的坑在鸿蒙不存在）；反过来要分组得显式 `Intl.NumberFormat` |
| **换成系统能力** | `HitArea`(20) | 鸿蒙 `.responseRegion({x:-8,y:-8,...})` 原生支持超出边界，不需要负 padding 技巧 |
| **换成系统能力** | `Feedback`/`ToastView`(199) | Toast → `promptAction.showToast`（API 18+ 的 `openToast` 支持按钮）；确认 → `AlertDialog`。**只有输入弹窗要自绘 `CustomDialog`** |
| **换成系统能力** | `SubscriptionKit`(397) | 表单弹层骨架改 `bindSheet` + `List` + `Toggle`/`Radio`/`Checkbox` 原生控件；`SubsFittedDetents` 手算高度删掉 |
| **换成系统能力** | `DiscoverFlowLayout`(113) | `Flex({wrap: FlexWrap.Wrap})` 原生换行，自研 Layout 无必要 |
| 要重做 | `ImmersiveHero`(425) | 换 Swiper + 渐变分层 + `effectKit` 取色 + `Refresh`；**删掉 `RefreshControlAboveContent` 的 zPosition 提层 hack** |
| 要重做 | `LibraryZoomableImage`(460) | iOS 内核是 UIScrollView，鸿蒙用 `GestureGroup(Exclusive)` + `.disableSwipe(scale>1)`；**建议接受"放大即禁翻页"这个降级**，不复刻嵌套手势协调 |
| 要重做 | `DiscoverPosterCard`(657) | **不要移植 window 级触摸观察者**；用 `onScrollStart` + 根层遮罩收起，长按换 `bindContextMenu` |
| 要重做 | `AgentMarkdown`(716) | 无原生替代；**不要用 `RichText`**，用 `MutableStyledString` + 移植块级解析器（约 340 行正则，可 1:1 搬） |
| 可直接搬 | `LibraryPosterCell` / `SectionHeader` / `EmptyState` 等 | 工程里已移植 4 个（`LibraryShared.ets`） |

**Token 层面**：`Theme.swift` 只定义了颜色 + 4 个尺寸，**字号、动效时长、透明度阶梯全都没 token 化**（散在其它 20 个文件里）。
鸿蒙侧要一次补齐：字阶（fp，HarmonyOS Sans 比 SF Pro 视觉重，**建议整体下调 1fp** 再校准行高）、
动效时长、白色透明阶梯（iOS 用了 22 档，收敛成 5 档）、`$r('sys.color.*')` 语义色。

**但别全换系统色**：品牌是「纯黑 + 冷银」，`sys.color.*` 跟着主题走会丢品牌。
只换语义色（`alert`/`confirm`/`warning`/`info`）、`comp_divider`、`font_secondary`/`font_tertiary`、交互态；
底色、银强调色保留自定义。

---

## 5.5 播放器：唯一一个「不能照抄」的模块

这是全工程最需要重新设计的一块，因为 iOS 的播放器**建立在 FFmpeg 上，而鸿蒙没有对等物**。

**iOS 是双引擎**：`AetherEngine`（FFmpeg 只拆容器 → 就地换封装成 HLS → 本机 `127.0.0.1` 喂给 AVPlayer；
解不了的编码走 FFmpeg/dav1d 软解 + `AVSampleBufferDisplayLayer`）+ 服务端 HLS 兜底。
`PlaybackController`（2293 行的状态机）管引擎选择、会话协商、进度上报、看门狗。

**鸿蒙只有一条路**：`media.AVPlayer`。而它的官方承诺格式只有 **mp4/mkv/ts + H264/H265 + AAC/MP3**，
比 iOS 那套窄得多。深处还有 `AVCodec`（`AVDemuxer` 解封装 + 解码器，支持 AVI/WMV/RM/MPEG-PS、VC-1/VP9/AV1、
AC3/DTS/TrueHD 等），但那是要自建 demux→decode→`XComponent(SURFACE)` 渲染 + 自己写 A/V 同步的量级。

所以鸿蒙播放器的骨架应该是「**服务端转码为主 + AVCodec 兜底为辅**」，而不是 iOS 的「本机换封装为主」。

**必然要服务端转码的四类**（片库画像里占比不低）：

| 内容 | 原因 |
|---|---|
| BDMV 目录 / BD·DVD ISO / MPLS·CLPI 导航 | 鸿蒙无原盘解封装 |
| 杜比视界 P5/P7/P8 | AVCodec 未列 DV profile/RPU 处理；`preferredHdr` 只到 HDR10/HDR Vivid |
| PGS / VobSub / DVB 图形字幕 | AVPlayer 只收外挂 SRT/VTT |
| TrueHD / DTS-HD / Atmos | 无全景声 MAT 透传公开 API，必须降级 |

**三个硬性合规点**（漏一个功能就废）：

1. **后台播放**：必须 `AVSession`（type `'video'`）**加** `BackgroundTasks Kit` 的 `AUDIO_PLAYBACK` 长时任务，
   两者缺一不可——不建 AVSession 退后台会被系统直接停止播放。且暂停时必须取消长时任务、恢复播放要重新申请。
2. **画中画**：`@ohos.PiPWindow` 要求 surface 可迁移，**必须用 `XComponent(type: SURFACE)`**，
   不能指望 `Video` 组件或 AVPlayer 默认 surface。
3. **音频焦点**：必须显式处理 `on('audioInterrupt')`，否则来电/其他应用播放时行为不可控。

**投屏是最大的能力缺口**：AirPlay 在鸿蒙**没有对等公开 API**——
分布式 AVSession 仅系统应用可用，文档明确「应用内投播当前暂未支持」，系统投播对三方仅音频。
真要做得自建 DLNA/UPnP（推服务端 HLS 地址给电视，改造量小）或申请 Cast+ SDK。**建议首版不做。**

**能借的部分（约 4200 / 11,617 行，36%）**：

| 处理 | 内容 |
|---|---|
| **逐行可搬（~2400 行）** | `PlaybackRouting`(479) 兜底策略纯函数、`PlaybackWatchdogs`(223) 停滞/掉帧/重连退避、`PlayerTracks`(210) 轨模型、`SubtitleOverlay` 的 WebVTT 解析、`SkipSegments`(48)、`PlaybackReportQueue`(110)、`LoadingSpeedMeter`/`BandwidthMeter` |
| **结构可借、实现要换（~1800 行）** | `PlaybackController` 的 Phase 状态机 / 单元切换 / 自动连播 / 记忆与沿用 / 心跳进度循环；`PlaybackAPI`(301) 纯 HTTP；`PlayerCapability`(91) 申报口径；`PlayerPreferences`(179)；`PlaybackRecord`(838) 的 QoE 字段 |
| **必须重写（~5250 行）** | `NativeEngine`(717)、`AVPlayerEngine`(465)、`PlayerSystemBridges`(206)、`NowPlayingBridge`(100)、`PlayerGestureLayer`(170)、以及 2430 行的 UI |

**手势可以照搬判定表**：iOS 用同一次触摸区分五种意图（<12pt 轻点、≤300ms 且在左右 1/3 双击跳转、
横主拖进度/纵主左亮度右音量、长按 500ms 二倍速、上下边缘 32pt 让给系统）。
ArkUI 的手势组合同样做不到「单击立即生效、第二下改判双击」，所以**照搬 `onTouch` + 纯函数判定表**
这套思路，把 `PlayerGestureLayer` 逐行改写成 ArkTS。亮度换 `setWindowBrightness()`（比 iOS 干净，
不影响系统全局），音量换 `setAppVolumePercentage()`（API 19+，应用级）。

**Reels（2167 行）**：竖滑刷片，刻意不复用 `PlaybackController`（不写观看记录、不要 PiP）。
鸿蒙用 `Swiper`（垂直）+ `Video` 组件即可，`ReelsStore` 的分页/调度/画质策略约 900 行可搬。
**唯一重活是字节缓存**：iOS 82ms 出画靠 AetherEngine 的跨启动片源字节缓存（上千行补丁），
鸿蒙没有等价物。建议先接受降级（转码 + 系统缓冲），自建缓存排到 P2。

---

## 6. 建议的落地顺序

**第 0 步 · 先修地基（不动新功能，**只改鸿蒙端**）**
修 §5.2-B 的缺陷（空壳页、图片缓存串号、401 误踢、懒加载缺失、重复定义）。
这一步不写新页面，但决定了后面所有页面是不是建在沙子上。
后端侧的 kind/UA 改动（见 §4）**不在此列**，等拿到后端改动权再说。

**第 0.5 步 · 播放器能力申报**（等做播放器时并行，用户已定「最后做」）
鸿蒙端**不能**照抄 iOS 报 `universal`。要在真机上逐项实测 `AVPlayer` 到底能吃多少格式，
写成 HarmonyOS 版的 `ClientCapability` 探测（`OH_AVCodec_GetCapabilityByCategory` + `OH_AVCapability_IsHardware`），
如实申报给 `/playback/decide`。**这一步不做，整个播放器没有片源可放**；同时要压测服务端转码容量——
原盘/ISO、杜比视界、图形字幕、TrueHD/DTS 这四类在鸿蒙上只能服务端转，会出现
「iOS 直出、鸿蒙转码」的体验断层，NAS 弱的话这是第一个会被用户发现的问题。

**第 1 步 · 公共层**
`EventStream` / `VisiblePolling` / `PageSnapshots` / `SavedServers`+ASSET / Router（27 路由 + 深链）/
`AsyncContent` 三态 / `PosterCard` / `ImmersiveHero`（用 HDS 沉浸光感重做）/ `SheetHost`+确认中心。
按 iOS 的 `DesignSystem` + `Core` 对位建，一次建好全模块复用。

**第 2 步 · 打通一条完整主路径**
Discover（列表 + 海报卡 + Hero + 筛选 + 无限滚动）→ Search（影视/媒体库两垂直）。
这两步之后「浏览 → 搜索 → 下载/订阅」就跑通了，且通用组件全部到位。

**第 3 步 · 补齐媒体库剩余面**
条目详情页（所有入口的终点）→ **播放器**（按 5.5 的方案：AVPlayer 骨架 + 后台播放合规 + 字幕 + 手势）→
管理页 / 合集详情 / 待处理抽屉 / 照片墙。

**第 4 步 · 管理面与长尾**
Activity（SSE + 图表自绘）→ Subscriptions（规则组编辑器放最后）→ Settings 18 分区 →
Notices / About → Agent（依赖最多新能力，放最后）→ Share / Reels。

**贯穿全程**：`HdsTabs`（含 `adaptToHandedness` 智感握姿）替换自绘 `Tabs`；
`HdsNavigation` 替换手写顶栏；沉浸光感用在 Hero、卡片按压、加载态三处。

---

## 7. 转译风险清单（照抄会踩坑的地方）

1. **`@Observable` 无等价物**。iOS 靠 Observation 自动追踪依赖；ArkTS 要 `@ObservedV2` + `@Trace` + `@ComponentV2`，
   漏一层就是「数据变了不刷新」且不报错。建议先定状态规范再动手。
2. **关联值枚举**。`Phase.ready(SessionView)`、27 个 `AppRoute`、`RootParameter` 都要改成
   class/interface + kind 判别，并手写 `equals/hash`（栈顶判断依赖相等性）。
3. **`@State` 包普通 class 不是响应式的**。现有代码靠「clone → 改 → 整体替换」和全量 `syncFromStore()` 绕过，
   漏抄一个字段就不刷新。深层对象（`SubsHomeState`、`AgentTurn.segments`）极易整体重绘。
4. **`ForEach` 的 key 决定正确性**。现有代码把选中态塞进 key（`${id}-0/1`）、用 `row.map(id).join('-')`，
   导致翻页时整块重建。流式追加（Agent）尤其需要稳定 key。
5. **沉浸布局不能照抄数值**。iOS 用负边距 + `contentMargins` 让 Hero 穿状态栏，
   鸿蒙走 `expandSafeArea` + 安全区，行为不同（本次修状态栏黑边已实测验证过这条）。
6. **ArkUI 没有的东西**：`Form`/`insetGrouped` 语义（Settings 43 个文件全受影响）、
   `Search` 的 token、系统 Markdown、Swift Charts、`presentationDetents` 的精确档位。
7. **`Toolbar` 类能力**：iOS 的 `tabViewBottomAccessory`（「接着看」条）、标签栏彩色小圆点、
   挂在窗口上的单页签长按手势，ArkTS 需要自绘或降级。
8. **文案与状态口径强耦合**。`SubscriptionPresentation`(590) + `SubscriptionsHomeModel`(696)
   承载大量与 Web 逐字对齐的中文文案。**先原样搬逻辑再改渲染**，顺手「优化」会导致
   Web / iOS / 鸿蒙 三端对同一台服务器说不同的话。
9. **接口漂移**。`Endpoints.ets` 是 iOS 生成物的快照；iOS 仍在活跃开发。
   鸿蒙 UI 手写期间要定期重跑 `gen_api_arkts.py` 并 diff。
10. **合规声明不可照抄**。About 页的 8 个开源组件（AetherEngine / FFmpeg / dav1d / LibDovi / Nuke…）
    是 iOS 特有依赖；鸿蒙用系统播放栈，这份清单必须按实际依赖重写，否则是虚假声明。
11. **播放器不是「转译」而是「重做」**。iOS 那套「FFmpeg 本机换封装」在鸿蒙没有对等物，
    整体变成「服务端转码为主 + AVCodec 兜底」。原盘、杜比视界、图形字幕、TrueHD/DTS 四类
    在鸿蒙上只能转码——这是**产品能力差异，不是实现细节**，要提前跟用户讲清楚。
12. **后台播放有强制合规要求**。`AVSession` + `AUDIO_PLAYBACK` 长时任务缺一不可，
    时序要求（暂停取消、播放重申请）比 iOS 严格，漏了会被系统直接掐断播放。
13. **`NavPathStack` 的路由参数会被序列化，`instanceof` 恒为 false**。
    `pushPathByName(name, new XxxParams(id))` 传过去的对象，到 `onReady` 的
    `ctx.pathInfo.param` 已经是个**普通对象**（实测打印出来是 `{"libraryId":1}`），
    所以 `param instanceof XxxParams` 永远不成立——**按字段取值并校验，不要依赖原型链**。
    这个坑的表现极具迷惑性：页面进去了、返回键也在、就是永远停在「正在加载」，
    而且因为下一页面的加载入口在 `onReady` 里，连一条日志都不会打（本项目的电影库/剧集库打不开就是这个）。
14. **iOS 用 `async let` 并发取数的地方，移植时不要写成串行 `await`**。
    详情页首屏在 iOS 是一次并发发出 7 路请求；串行 await 时首屏耗时是这七路之和，
    管理员账号要串 8 个往返，弱网下和网页能差出好几秒。**移植时逐条对照 iOS 的并发结构。**
15. **轮询的重排要放在函数开头**。`reload()` 末尾才 `scheduleNextPoll()` 的话，
    一旦某一路请求挂住不返回，就没有下一次轮询，页面永久卡死、连重试入口都出不来
    （失败态要 `loadFailed && libraries === null` 同时成立才会显示）。
16. **`@Builder` 是按值传参、且不会因「参数对象的内部字段变了」而重绘**——
    这是移植「数据层原地改对象、界面按字段分支」这类 iOS 写法时最容易中招的一条。
    发现页的行是 `DiscoverRow` 对象（`state` 从「加载中」原地改成「已加载」），
    只用 `ref` 当 `ForEach` 的键时，框架认为这一项没变、不重建 → **19 行数据全到了，界面还停在骨架**。
    解法：**把参与渲染的字段编进 `ForEach` 的键**（见 `DiscoverRow.renderKey()`
    = `ref|state|条数`），状态一变键就变，框架才会重建这一行。
    同理，凡是「`@State` 里放一堆可变对象、就地改字段」的地方都要这样处理，
    否则就得把状态拆成 `@Prop` 基本类型传给子组件。

---

### 7.x 非装饰成员只赋值一次（本项目已踩 3 次）

ArkUI 里**子组件的非装饰成员变量只在构造时赋值一次，父组件之后传的新值不会同步**——
要用 `@Prop`。三次踩坑都表现为「**数据是对的、界面是旧的**」，不报错、不警告、编译通过：

| 位置 | 症状 |
|---|---|
| `FilterSheetContent.facets/loading` | 筛选面板二级维度永远显示「正在数各档位…」 |
| `FilterConditionRow.facets` | 「筛出 N 部」永远是全库总数 |
| `FilterPillGroup.facets` | 档位上的数字不更新 |
| `LibraryCollectionsGrid.collections` | 新建的合集在数据里有、页面上不出现 |

**判据**：凡是「父组件会 later 传进来的可变状态」（View 对象、数组、筛选条件），一律 `@Prop`。
已扫过全项目，其余可疑点：`AllCollectionsPage` 的 `options/counts/collection/covers`、
`LibraryHomeView` 的 `item`（都还没验出症状，改动前先确认）。

## 8. 模拟器验证手法（踩过的坑，别再踩）

**`uinput` 分两套命令，拖拽/滚动用哪套都不生效——模拟器不投递合成滚动手势。**

- `-T` 是触摸：`-c x y` 点击、`-m` 平滑移动、`-g` 拖拽手势（要求按住 ≥500ms）
- `-M` 是鼠标：`-s` 滚轮、`-g` 拖拽
- **实测结论：点击（`-T -c`）完全正常；上面所有拖拽/滚动写法在模拟器上都不产生滚动事件**
  （用 `onDidScroll` 探针验证过：三种写法跑完，探针一次都没触发）。
  排查时差点误判成「`Refresh` 包 `Scroll` 导致页面滚不动」——**不是**，
  去掉 `Refresh` 一样不动，属于测试环境限制。

**要验证滚动，用「程序化滚动 + 探针」这套组合，不要靠手势注入**：

1. 给容器挂 `Scroller`，在数据到位后 `setTimeout(() => scroller.scrollTo({ yOffset: 1100 }), 2500)`；
2. 容器上挂 `.onDidScroll(() => hilog.info(...))` / `.onReachEnd(...)`；
3. 看日志 + 截图，既证明「能滚」，又能把折叠以下的内容翻出来截图验证。

**判断「界面有没有变」时一定要做对照截图。** 发现页那次「拖拽后差异 139 万像素」
看着像滚动成功，其实**不拖拽、只等 5 秒也是 139 万**——那是 Hero 轮播自己在换。
带自动轮播/动画的页面上，像素差完全不能当滚动证据。

---

## 9. 待确认的产品决策

1. **Share（访客分享页）鸿蒙端要不要做？** 811 行，要自管 cookie jar 做分享解锁。
2. **「外观」相关**：iOS 端明确不做网页的主题/背景图设置。鸿蒙是否同样只保留纯黑 + 系统材质？
3. **沉浸光感用在哪些页面**？建议先定 1-2 处（订阅首页 Hero、播放器控制层）验证效果，再推广。
4. **智感握姿用系统内建还是自研**？`HdsTabsFloatingStyle.adaptToHandedness` 开箱即用；
   自研（`motion.on('holdingHandChanged')`）只有在「不止标签栏要跟着手走」时才值得。

---

## 10. 架构决策（用户已拍板）

### 决策一：补多服务器 × 多账号
### 决策二：状态管理走 V2（`@ObservedV2` / `@Trace` / `@ComponentV2`）

两条是**配套**的：多账号会往 `AppModel` 里塞进 `savedServers` / `expiredUsername` /
`pendingNotice` / `resumePoint` 一堆状态，继续用「单例字段变了 UI 不知道、全靠手工拷 `@State`」
那套写法会立刻失控。所以**先立 V2 范式，再在上面搭多账号**。

### 分批计划

| 批次 | 内容 | 验收 |
|---|---|---|
| **A. 立 V2 范式** ✅ | 把 discover 模块当试点迁到 V2：`DiscoverFeed` / `DiscoverStore` 改 `@ObservedV2` + `@Trace`，`DiscoverPage` 改 `@ComponentV2`，**删掉 `renderKey()` 那个把状态编进 ForEach key 的补丁** | 片单行照样从骨架切成内容；代码里不再需要「编 key」这种手工同步 |
| **B. 令牌与服务器记录** ✅ | `TokenVault`（`@ohos.security.asset` 关键资产）按「服务器 + 用户名」存一枚；`SavedServers` 存 Preferences | **已完成**：关键资产 4 项设备自检通过；`SavedServers` 纯函数 10 个单测通过（`hvigorw test`） |
| **C. AppModel 重写** ✅ | 7 个 phase（`launching` / `needsServer` / `needsSetup` / `needsLogin` / `chooseAccount` / `unreachable` / `ready`）+ `reconnect` / `switchAccount` / `switchToPreviousAccount` / `removeAccount` / `refreshAccounts` / `logout` / `logoutEverywhere` / `resumePoint` / `pendingNotice` | 对齐 iOS `AppModel.swift` 逐条；冷启动、切号、断网各自落到正确的 phase |
| **D. 外壳接多账号** ✅ | 欢迎页账号列表、`needsSetup` 建管理员、`unreachable` 重试卡片、双击头像切回上一账号、退出全部账号、设置里的账号管理 | 模拟器上逐条走通 |
| **E. 渐进迁移其余 store** | `LibraryHomeStore`、`LibraryDetailPage` 的墙数据源等 | 每迁一个删掉对应的手工 `@State` 拷贝 |

### 批次 B 落地的两块存储

- **`common/TokenVault.ets`** —— `@ohos.security.asset` 的封装。别名 = `「origin#用户名小写」`，
  `Accessibility.DEVICE_FIRST_UNLOCKED`（对应 iOS 的 `AfterFirstUnlockThisDeviceOnly`），
  另外设 `REQUIRE_PASSWORD_SET = false`，否则**设备没设锁屏时会存不进去**。
  关键资产没有「按前缀列举」的接口，所以另开一个 Preferences 只存**别名索引**给「退出全部账号」用；
  **令牌本身只在关键资产里，不要退回 Preferences 明文存**。
- **`common/SavedServers.ets`** —— 服务器/账号快照。核心是五个纯函数
  （`touching` / `replacingAccounts` / `upserting` / `removingAccount` / `snapshot`），
  与 iOS 逐条对应，已补单测 `entry/src/test/SavedServers.test.ets`（`hvigorw test` 可跑）。
  `ServerAddress` 不能直接 JSON 序列化，落盘时转成 `{origin, accounts, lastUsed}` 的 DTO。

### 活动页（本轮，管理员）

`entry/src/main/ets/activity/ActivityPage.ets`（对应 iOS `Features/Activity/ActivityView.swift` 的**任务中心**部分），
接进底栏「活动」页签（原本是占位）。

iOS 那版是「一页总览」（需要处理 → 正在播放 → 正在下载 → 进行中 → 最近播放 → 观看统计 → 最近完成），
数据来自外壳常驻的 `ShellBadges`（SSE + 轮询）。**鸿蒙这边没有外壳级推送通道，所以本页自己轮询**
（5 秒一轮，实测 32 秒触发 7 次，符合预期）。分三组：**需要处理 → 进行中 → 最近完成**，
worker 没在跑时顶部出警示条（队列不会有人处理，必须让人看见）。

实测：摘要「1 个任务进行中」；进行中卡片显示「剧集库 / library_skip_segments」+ 进度条 65% + 取消；
最近完成列出「重复文件 / 剧集库」若干条。

**没做**：正在播放（设备会话）、最近播放、观看统计（iOS `WatchStats` 829 + `WatchHistory` 201）、
浏览范围切换、二级页；任务卡片的完整动作（换种、交给 AI、删除文件）只做了重试 / 忽略 / 取消。
**动作按钮没在真实任务上点过**——当时唯一在跑的是用户自己的 `library_skip_segments`（65%），
取消它会打断真实刮削，所以只按端点签名接上、没有实点。

### 订阅页（上一轮）

`entry/src/main/ets/subscriptions/SubscriptionsPage.ets`（对应 iOS `SubscriptionsView` 的「我的订阅」），
配一个 `SubscriptionsNavHost` 接进底栏第二个页签（原来那个页签是占位）。

版式按 iOS 的意图拆：**接下来（今天/本周到达）→ 刚刚入库 → 剧集订阅 / 电影订阅**，
剧集/电影各自**在追的排前面**（`imported + downloaded + grabbed > 0` 视为在追）。
订阅海报带底部进度条 + 「已入库 193/206」。
轮询节奏照 iOS：接下来 10 秒、刚刚入库 20 秒。

实测（模拟器）：25 部在追 / 接下来 27 集（带「今天」徽标）/ 刚刚入库 14 集 /
剧集订阅 16 部（进度条 193/206、57/84、39/52）/ 电影订阅 8 部，全部正常。

**没做**：沉浸 Hero 轮播（iOS 366 行）、日程条、订阅详情页、订阅弹层（`SubscribeSheet` 524 行）、
升级重下、剧集清理、链路体检。列表里的行点了会明确提示建设中。

**已知小瑕疵**：「刚刚入库」的剧照位在服务端还没刮到 `still_url` 时是占位图标，
没有回退到该订阅的海报（`RecentArrivalView.media.poster_url` 那个接口没填）。

### 搜索页（上一轮）

`entry/src/main/ets/search/SearchPage.ets`（对应 iOS `SearchHomeView` + `SearchResultsView`）。
三个竖向同 iOS：**媒体库**（搜已入库）/ **影视条目**（豆瓣·TMDB 元数据）/ **资源**（跨站点搜种子）。

已落地并**在模拟器上点过**：
- 搜索框（按竖向给不同占位文案，回车提交）+ 竖向切换 chips + 空态提示；
- **媒体库搜索**：`searchLibraryItems`，结果按库分组（库名 + N 部），点行进条目详情页；
- **影视条目搜索**：`searchTitles`，海报网格，点进发现详情页；
- **搜索历史**：`searchHistoryList/Delete/Clear`，点了回填并直接搜、长按删除、「清空」带确认。

**没做**：资源搜索（iOS `TorrentResultsView` 842 行 + `TorrentSearchLogic` 541 +
`TorrentActions` 343 + 下载目标选择 416，是独立的一大块）、按分类浏览、范围标记、
搜索预设。竖向上「资源」点了会明确提示建设中。

踩到一处**后端枚举与本地模式名不一致**：条目搜索回来的历史 `vertical` 是 `titles`
而不是 `media`，直接映射会把原始字符串显示给用户（实测标签显示成 "titles"）。
现在 `verticalLabel()` 按后端值映射并留中文兜底。

### 批次 D 落地情况与验证边界

已落地并**在模拟器上点过**：
- `Index` 按 7 phase 切页：启动转圈 / 「连不上」重试卡（带「换个服务器」）/ **账号选择列表** /
  欢迎页（`needsServer`·`needsSetup`·`needsLogin`）/ 主界面；
- 「更多」页：当前账号卡、**本机账号列表**（跨服务器，点了直接切、长按移除）、添加账号、
  服务器卡（点了进登录页）、退出登录、**退出全部账号**（账号数 > 1 时才出现）；
- **双击头像页签**切回上一账号（`TapGesture({count:2})`，单点仍是切页签）；
- `pendingNotice`：换账号后主界面整棵重建，提示先存在 `AppModel` 里、由新的主界面取走再弹。

验证边界（**这两条没验到，别当成已验**）：
- **实际切号没跑通**——后端 `/auth/accounts` 返回空、只有 `DongShu` 一个账号；
  想借第二台服务器（`mc.dongshu.fun:99`）造第二个账号，但模拟器到它的延迟 5 秒，登录超时。
  没去改用户的服务器数据。切号的**存储与纯函数**已由 `SavedServers` 的 10 个单测覆盖，
  **网络那一段（`authMe` + `activate`）与 `switchAccount` 未经端到端验证**。
- `logoutEverywhere` 同理（要 >1 个账号才会出现入口）。

验过的两条：双击头像在只有一个账号时正确提示「这台设备上只有当前这一个账号」；
退出登录走完 `revokeDevice → TokenVault.delete → SavedServers 更新 → leaveCurrentServer →
needsLogin`，回到欢迎页且表单已展开、服务器地址预填、**用户名留空**（与 iOS 一致：主动退出不预填）。

### V2 的硬约束（批次 A/C 实测，血证）

1. **`@ObservedV2` 的类不能写成「静态字段初始化器建单例」**：
   ```ts
   static readonly shared: AppModel = new AppModel();   // ❌ 观察钩子没装上
   ```
   静态字段初始化器在**类定义阶段**就执行，早于装饰器生效，那样建出来的实例
   `@Trace` 字段变化**不会通知任何组件**。实测表现：`phase` 已经是 `ready`，
   界面还停在启动转圈上，而且日志显示流程全跑完了——非常难查。
   **要写惰性单例**（`static get shared()` 里 `new`），`AppModel` / `DiscoverStore` 都已改过来。
2. **`@Trace` 要经由 `@Local` / `@Param` 持有的对象读到才会建立订阅。**
   直接读一个静态单例（哪怕类标了 `@ObservedV2`）不算。所以入口组件里写
   `@Local private model: AppModel = AppModel.shared;` 再用 `this.model.phase`。
3. **`build()` 里除了根容器不能再有语句**（连一行 `hilog` 都会报
   "build method can have only one root node"）——想打点就放进 `@Builder` 或方法里。

### 生成器的第三处系统性问题：`raw()` 被当成 `send()`

iOS 的 `APIClient` 有两条调用路径，**语义不同**：
- `send(...)`：拆信封，取 `{"data": …}` 里的 `data`；
- `raw(...)`：直接按响应体解析（`Self.decoder.decode(T.self, from: data)`）。

后端少数「裸」接口直接返回扁平对象——典型的就是 `/api/v1/health` 返回
`{"status":"ok",…}`。生成器早先把两者一律转成 `client.get(...)`（拆信封），
于是 `envelope.data` 是 `undefined`，客户端拿到 undefined 再去读 `.status` 就抛
`TypeError`。**表现是启动时 `reconnect()` 直接失败、界面永远停在转圈。**

修法：生成器识别 `try await raw(` → 生成 `this.client.rawGet<T>(path)`
（`ApiClient` 本来就有 `rawGet`，只是没人用）。全仓只有 `healthCheck` 一个端点走 `raw`，
所以影响面就这一个，但它是**启动必经之路**，坏了整个 App 进不去。

### V2 迁移踩到的坑（批次 A 实测）

1. **`@Computed` 不能在事件处理器里当「取当前值」用**。它缓存结果、按渲染周期失效：
   在 `@Local` 字段刚改完、紧接着同步调用方法时读它，拿到的是**旧值**。
   发现页切视角就是这么坏的——`build` 里重算了（标题变了），但 `load()` 里读到旧 feed，
   于是「这个视角已经加载过」直接 return，新视角永远停在骨架。
   **结论：要按状态推导出一个值并传给命令式代码时，用普通字段显式赋值，别用 `@Computed`。**
2. V2 下**不需要**把状态编进 `ForEach` 的 key 了。行对象标 `@ObservedV2`、会变的字段标 `@Trace`，
   再把这一行做成独立的 `@ComponentV2` 子组件，字段一变**那一行自己重绘**，与 key 无关。
   发现页的 `DiscoverRowView` 就是这么落的，`renderKey()` 那个补丁已删。
3. V1 组件里放 V2 子组件没问题（`DiscoverNavHost` 是 V1，里面装的 `DiscoverPage` 是 `@ComponentV2`）。
   跨组件传参在 V2 用 `@Require @Param`，组件内部状态用 `@Local`。

### 关键实现约束（抄 iOS 时别抄错）

- **令牌存关键资产，不存 Preferences**。iOS 用钥匙串且有 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
  （不进 iCloud、不随备份到另一台机器——令牌代表「这台设备」）；鸿蒙对应用
  `@ohos.security.asset` 的 `add/query/remove`，同样按「服务器 origin + 用户名小写」做键。
  **当前实现把令牌明文存在 Preferences 里，这一批要换掉。**
- **切账号不联网**。多账号完全在本机：切号就是换一枚令牌，没有账号数上限，
  同一主机的不同端口（`origin` 含端口）互不覆盖。
- **令牌失效时只删令牌、保留账号快照**：用户点那个账号只需重新输密码（`expiredUsername` 预填）。
- **`pendingNotice` 要延迟弹**：切账号后主界面整棵重建，当场弹的提示会丢，
  所以先存下来、由新的主界面出现时取走再弹。
- **`resumePoint`**：401 被踢后记下「当时在哪个页签、栈里什么路径」，重新登录后回到原处。


---

## 10.5 差距盘点（第 51 轮做的，**按文件核对，不凭印象**）

**背景**：第 50 轮对比 iOS 活动页时发现差了整整三段，而我此前几轮一直在说「页面基本收口了」。
这说明那个判断来自「**我做的那些都验过了**」，而不是「**iOS 有的我都做了**」。所以做一次逐文件核对。

**量级**（都是 `find`/`ls` 实数的，不是估的）：

- iOS `Features/` 下 **146 个 `.swift` 文件**（其中各功能目录的直接子文件 117 个，其余在子目录里）；
- 鸿蒙 **37 个页面/组件文件**（`*Page.ets` / `*View.ets` / `*Section.ets` / `*Sheet.ets`）。

**约 1 : 4**。而且**不是一比一对应**：我的 37 个里有一批是 iOS 没有的（设置 12 个分区，
iOS 那边只有 2 个文件 + `Sections/` 子目录），所以真实的功能覆盖比这个比例看起来还要低。

| iOS 目录 | 文件数 | 鸿蒙 | 状态 |
|---|---|---|---|
| Library | 37 | 16 | 缺 20+，见下 |
| Subscriptions | 13 | 3 | 缺规则组编辑器 / 订阅墙 / 洗版 |
| Activity | 11 | 1 | **缺三段 + 全部二级页** |
| **Agent** | **10** | **0** | **整块没有** |
| Search | 9 | 2 | **缺资源搜索整块** |
| Discover | 8 | 2 | 缺人物页 / 合集页 / 筛选 |
| Player | 7 | 1 | 缺手势层 / 菜单 / 诊断面板 |
| Root | 5 | 3 | 接近 |
| **Share** | **3** | **0** | **整块没有** |
| Onboarding | 3 | 1 | 缺欢迎卡片与登录面板的细分 |
| **DeviceApproval** | **3** | **0** | **整块没有**（扫码 / 配对码） |
| **Reels** | **2** | **0** | **整块没有**（片段） |
| Notices | 1 | 1 | ✅ |
| **About** | **1** | **0** | 没有 |
| Settings | 2 + Sections | 12 | **超出**（鸿蒙这边反而更细） |

### 整块没有的（六块）

1. **Agent / AI 会话页**（10 文件）——`AgentConversationView` / `AgentComposer` / `AgentTimeline` /
   `AgentTranscriptRows` / `AgentSkills` / `AgentMediaCards` / `AgentNewSessionView`。
   上一轮做的「交给 AI 分析」只到「起会话」，**没有地方读**。
2. **资源搜索**（`Search` 里 5 个文件）——`TorrentResultsView` / `TorrentSearch*` / `TorrentActions` /
   `DownloadTargetDialog`。搜索页的「资源」竖项目前是「建设中」。
3. **Reels / 片段**（2 文件）——媒体库首页那两处「片段」死路就是它。
4. **Share / 分享**（3 文件）——`SharePageView` / `ShareItemView` / `ShareLinkKit`；
   合集与媒体的「分享…」都还没有。
5. **DeviceApproval / 设备批准**（3 文件）——扫码与配对码；设备页只做了「看与注销」，没做「批准新设备」。
6. **About / 关于**（1 文件）——「我的」页那一行还是 toast。

### 部分缺失的（按目录）

- **Library**：回收站、重复文件、分享页签、图床/照片墙与灯箱、章节条、字幕生成与预览、
  媒体轨道、元数据刷新、重新识别、转移/删除条目、添加到合集、封面选择、系列详情页……
- **Subscriptions**：**规则组编辑器**、订阅墙、**洗版（`UpgradeRunSheet`）**、媒体来源标注。
- **Activity**：正在播放 / 正在下载 / 观看统计**三段**，以及全部「查看全部」**二级页**、任务中心面板。
- **Search**：资源搜索整块（同上）。
- **Discover**：人物页（`PersonDetailView`）、发现合集页、筛选。
- **Player**：手势层（拖动进度 / 亮度 / 音量）、菜单（清晰度 / 倍速）、诊断面板、系统桥（`PlayerSystemBridges`）。

### 结论

**「能用」这条线做到了**：登录/多账号、媒体库浏览、条目详情、发现、搜索（媒体库 + 影视条目）、
订阅全链、活动、设置 12 分区、播放器（协商/降档/合规三件套/字幕/音轨/章节）。
**「iOS 有的都有」还差得远**：整块六块 + 各目录的部分缺失，加上服务端 VAAPI 那个不在本仓库的问题。

## 11. 落地记录（逐轮）

### 播放器（本轮，**第一切片；有一个未解决的集成错误**）

`player/PlayerPage.ets`，按 §5.5 的设计做：**服务端转码为主 + 本机 AVPlayer**，
而不是 iOS 那套「本机换封装为主」。链路是
**能力上报 → `playbackSessionStart` 拿 `stream_url` → `XComponent(SURFACE)` + `AVPlayer` 播放**。

已完成并**渲染验证**的部分：

- **视频面必须是 `XComponent(type: SURFACE)`**（画中画要求 surface 可迁移，
  用 `Video` 组件以后得推倒重来）；surface id 走 `XComponentController.getXComponentSurfaceId()`
  （`XComponentContext` 不是公开类型）；
- **能力如实上报**：只报官方承诺的那一档（mp4/mkv/ts + H264/H265 + AAC/MP3），
  `hdr_passthrough = false`（杜比视界 AVCodec 不支持）——
  **虚报会让服务端判「能直出」，用户看到的是黑屏而不是「需要转码」**；
- 控制条：返回 / 标题 / 播放暂停 / 进度 / 时间 / ±10 分钟 / 「详情」（帧出这一档是怎么判的）；
- 进度每 10 秒上报、退出时显式收掉转码会话（不收服务端会一直转）；
- **失败时把服务端的理由原样显示**——这条设计当场见效：屏幕上直接出现
  `request validation failed`，而不是我自己编的「播放失败」。

**422 已解决（靠抓原始响应体，不再猜）**。日志里拿到真话：

```json
"details":[{"location":["body","season_number"],"message":"Input should be a valid integer","input":null}, ...]
```

两件事一次说清：

1. **字段名是 `details`（复数）**，不是 FastAPI 标准的 `detail`——我上一轮加的透出逻辑**键名就找错了**，
   所以它「没生效」不是因为它没用，是因为我没看对地方。现在两个都认。
2. **真正的原因是 `season_number` / `episode_number` 传了 `null`**，而后端 schema 是 `int = 0`（不可空）。
   改成传 `0` 之后**协商成功**——控制条显示「**转码（第 3 档）**」，服务端判了档并回了流地址。

**根因找到了，不在客户端——是服务端的转码编码器起不来。**

「三方对照」先把平台排除掉：

| 对照 | 结果 |
|---|---|
| AVPlayer 播公开 HTTPS HLS | ✅ 播放 |
| AVPlayer 播 Mac 上用**明文 HTTP** 提供的 MP4 | ✅ 播放（Mac 日志确认 `GET /probe.mp4 200`） |
| 我们后端的 HLS | ❌ `IO resource not found` |

然后用**后端自己的日志**（就是「设置 → 系统日志」读的那份）拿到了真话：

```
GET .../index.m3u8    status_code=200   ← AVPlayer 确实取到了播放列表
GET .../seg00000.m4s  status_code=404
GET .../init.mp4      status_code=404   ← 且每 15 秒重试一次，无限
本地转码进程异常退出：退出码=218
  stderr: [vost#0:0/h264_vaapi] Could not open encoder before EOF
          Terminating thread with return code -38 (Function not implemented)
```

**服务端的 `h264_vaapi` 硬件编码器打不开**，所以转码档根本没有分片可出；
客户端那句 `IO resource not found` 是 404 的如实转述。**播放器客户端这条链路是通的。**

**本轮在客户端补上的两个缺口**（都是契约的另一半，之前漏了）：

1. **降档回路**：这一档放不了时，把**失败档位**报回服务端再要一次（`failed_tiers`）。
2. **起播看门狗**：**AVPlayer 在 HLS 上取不到分片时不报错，只是每 15 秒无限重试**（日志实测）
   ——所以「这一档放不了」**不能等 `error` 事件**，只能自己计时（25 秒）。
   这正是 iOS 那个 2293 行 `PlaybackController` 里叫「看门狗」的东西。

### 播放器的系统合规壳（本轮）

`player/PlaybackGuard.ets`：把 §5.5 点名的三件「漏一个功能就废」的事收在一处。

- **后台播放**：`AVSession`（type `'video'`）**加** `BackgroundTasks` 长时任务，**缺一不可**；
  且**暂停时释放长时任务、恢复时重新申请**（一直挂着会被判滥用）。
- **音频焦点**：`on('audioInterrupt')`，只在「我们本来在播」时才自动恢复
  ——用户自己按的暂停不该被这次中断翻回来。
- **系统媒体控制**：AVSession 的 play / pause 命令接上播放器，否则锁屏与通知栏的按钮是死的。

**踩到两个 API 细节**（都靠日志里的真话定位，没靠猜）：

1. **`startBackgroundRunning` 报 `9800005 Continuous Task verification failed. The bgMode is invalid.`**
   ——错误只说「模式无效」，**不告诉你「得先在清单里声明」**：要在 `abilities[]` 里加
   `"backgroundModes": ["audioPlayback"]`。另外权限 `ohos.permission.KEEP_BACKGROUND_RUNNING`
   也必须有（已确认进了包）。
2. **`InterruptEvent` 的字段是 `hintType`**（不是 `interruptHint`）；
   **`AVMetadata.duration` 是 `number`（秒）**，不是字符串。

**验证方式**：服务端的转码档目前是坏的（见上），播放到不了 `playing`，合规壳就走不到。
所以临时把播放源换成 Mac 上一个已知好的 HTTP 视频，**让 `playing` 真的发生**，
才验到「长时任务申请成功、播放正常」。——**这正是上一轮「先做已知好的对照」那条经验的复用。**

**画中画本轮补上了**（§5.5 三个合规点至此全齐）：

- 视频面从一开始就按 `XComponent(type: SURFACE)` 做，就是为了这一步——`PiPWindow`
  要求 surface 可迁移，用 `Video` 组件或默认 surface 到这儿就得推倒重来；
- **两种进入方式都接上**：`setAutoStartEnabled(true)`（按 Home / 上滑回桌面自动缩成小窗，同 iOS）
  与控制条上的「画中画」按钮；
- `isPiPEnabled()` 先问系统支不支持，不支持就明说而不是硬来；
- 小窗被关掉时**把自动进入关掉**，免得用户回桌面又被缩进去出不来。

实测：点「画中画」后右上角出现小窗、视频继续播、按钮变「退出小窗」；
系统日志 `WMSPiP: NotifyPipWindowSizeChange` / `PipSizeChange` 确认是系统级的画中画在跑。

**§5.5 的三个合规点现在全部完成**：后台播放（AVSession + 长时任务）、音频焦点
（`on('audioInterrupt')`）、画中画（`PiPWindow`）。

### 字幕轨切换（本轮）

后端把 `subtitle_urls` 与 `decision.subtitles` **按同一序**生成（`for s in view.subtitles`），
所以两边**用同一个下标就能对上**，不必再拿 `track_ref` 去匹配。

外挂字幕在鸿蒙上要走**两步**——`addSubtitleFromUrl` 只是**加载**，加载完还要
`getTrackDescription()` 拿到它的 track index，再 `selectTrack` 才是**选中**；关字幕用 `deselectTrack`。
（`MultiMedia` 的 `MD_KEY_TRACK_INDEX` / `MD_KEY_TRACK_TYPE` 是**字符串字面量**
`'track_index'` / `'track_type'`，不是 `media` 上的常量。）

实测：控 制条上「字幕 ✓ / 字幕」按钮 + 面板（标题、说明、「关闭字幕」带对勾）；
探针视频本身没有字幕轨所以列表为空，真实会话里按后端序列出语言 / 类型 / AI / 默认。

**又踩到 `bindSheet` 只能绑一个**：播放器页本来就绑了「播放详情」，
这轮加「字幕」时又绑了一个 → 后绑的覆盖前面的，字幕面板一直打不开。
**第 23 轮在媒体库页踩过、也写进了文档，这轮还是犯了。**
已合成单槽位（`sheetKind` 切换）。

**顺手做了全项目审计，又挖出 4 个同样的**（都在设置分区里，各有一个弹层是死的）：

| 文件 | 死掉的那个弹层 |
|---|---|
| `LogsSection.ets` | 自动刷新档选择 |
| `WebhookSection.ets` | 投递记录 |
| `McpSection.ets` | 端点自检结果 |
| `MembersSection.ets` | 一次性密码展示 |

全部合成单槽位。**其中「一次性密码展示」最要命**——建成员 / 重置密码后密码只出现一次，
那个弹层打不开就等于**密码直接丢了**。（`LlmSection.ets` 也是 2 处，但分属两个 struct，没问题。）

规律已经很清楚了：**每加一个弹层，先看宿主是不是已经绑了一个**。
以后再写 `bindSheet`，一律先 `grep -c` 宿主文件。

### 音轨切换 + 章节跳转（本轮）

**音轨**：切音轨**要重新协商一次会话**，不是本机切轨——后端把 `audio_track` 当决策输入
（选了非默认轨可能把「直出」顶成「重封装」，因为直出时只放默认轨），所以前端硬切是错的。
重开时清空失败台账、尽量保留播放位置。

实测（面板拿到的是**真实数据**）：那部片有 7 条音轨——`chi · eac3 · 6 声道 · 默认` /
`chi · dts · 6 声道` / `chi · flac · 2 声道` 等，带语言、编码、声道数与默认标记。

**章节**：横向可滚的章节条，点一下跳到那一章；**没有章节就整条不占位**。
高亮逻辑是「当前播放位置落在**哪一章**」，不是「所有已过的章都亮」——
后者会让用户看不出自己在哪儿。章节来自会话的 `chapters`（后端按片头片尾 / 内封标记算）。

**还没做**：`AVCodec` 兜底、投屏（§5.5 建议首版不做）。

### 设置：播放——**设置 12/12 收尾**

`settings/PlaybackSection.ets`（对应 iOS `PlaybackSettingsView` / Web `PlaybackSection`）。

iOS 这一页有三块，本轮做了前两块（它们共用一个策略接口）：

- **硬件加速**（这是**事实**不是开关）：显示服务端探测到的结论与可用后端。
  实测服务端是 Linux，探到 **VAAPI**，卡片显绿色「有硬件加速可用」；
- **三颗开关**：进度条预览 / 转码缓存 / 允许软件转码。**都是「改即存」**（乐观更新、失败回滚），
  没有保存按钮，同 iOS。副标题写的是**后果**（「很吃 CPU，机器弱就别开」「占磁盘」），
  不是参数名。

**没做**：**远程转码 worker**。它的端点是 `/transcode-worker/config` 与 `/transcode-worker/status`，
**这两个端点没有被生成进鸿蒙的 API 客户端**（`Endpoints.ets` 里只有 9 处 `transcode`，都是别的东西）。
所以这不是「没来得及做」，而是**要先补生成器或手写端点**才能做。
iOS 那条「开关是意图、Worker 连接是现实，两件事分开说」的设计要点，也留到那时。

### 设置线完成（12/12）

设备 · 系统日志 · 成员 · 模型接入 · AI 设定 · Webhook · 消息推送 · 网络 · 更新与维护 · MCP 服务 ·
刮削与整理 · 播放。

### 设置：刮削与整理（上一轮）

`settings/ScrapeSection.ets`（对应 iOS `ScrapeSettingsView` / Web `scrape-settings-section`）。

结构与 Web 一致：**四个并列分节**（元数据 / 图片 / 命名与整理 / 目录写入），
每节若干张**手风琴卡片**——**默认全收起、同时只开一张**，**折叠头直接摊出当前值的人话摘要**，
一屏扫完全站配置。实测摘要：「分级地区：中国、美国」「海报 default · 最小宽 500px」。

保存交互照搬 Web：**整页一个草稿，改任意一项即置脏，底部「保存」整体 PUT**，未改动时保存键禁用。

**一条语义细节照做了**：**编辑态用「生效值」起步**——语言优先级跟随环境变量时存的是空列表，
这时显示的是**当前生效的语言**；不改就不保存，语义不变（iOS 注释点名过）。

本轮修了两处摘要的兜底（都是「后端返回空串表示用默认档」导致的）：
尺寸档会拼成「海报 · 背景 · 剧照」这种**没有值的摘要**；语言优先级会显示「未设置」，
而实际是**跟随环境变量**、其实生效了——改成如实写「跟随环境变量」，别让用户以为没配就没生效。

**没做**：「N 个库已覆盖」标记（要拉各库覆盖情况，回答「在全局改了为什么不生效」）、
命名模板的实时预览、图片尺寸档的候选枚举（这里是文本框，后端校验）。

### 设置：MCP 服务（上一轮）

`settings/McpSection.ets`（对应 iOS `MCPSettingsView` / Web `mcp-section`，设计见 `docs/design/mcp-server.md`）。

Web 是 4xl 宽的开发者控制台（列表 → 详情三栏 → 新建都在同一块内容区原地切换），
**iOS 改成系统层级**：列表一屏、详情 push、新建弹层（成功后原地换成**令牌专屏**）。本轮做列表与新建：

- **列表**：总开关、地址前缀、服务关闭时的提示、「已配置 N 个端点」+ 新建端点、空态；
  端点行是**状态点 / 名称 / 路径 / 服务标签 / 工具数 · 展开折叠 · 超时 · 令牌提示**，
  缺服务时另起一行标出来；
- **行内操作**：**自检**（弹层显示协议版本 / 工具数 / 耗时 / 探针结果 / 警告条数与逐条原文）、
  **轮换令牌**、启用开关、删除（都带二次确认）；
- **新建弹层**：名称、说明、**开放能力多选**（按服务域，带命令数与说明）、展开工具、创建后立即可用；
  成功后**令牌只出现一次**（关掉即丢，文案写明「忘了只能再轮换一次」）。

实测：`https://mc.dongshu.fun:99`、「已配置 0 个端点」、关闭态提示、空态引导。

**没做**：详情页三栏（概览 / 工具 / 设置，iOS 的 `SettingsBMCPEndpointDetail`）、
令牌专屏后自动推入新端点详情、用量统计（`StatusView.usage`）。

**一个我重复犯的错**：方法名又写成了 `rotate`，再次撞上 ArkUI 组件内置的 `rotate` 属性。
Webhook 那轮刚踩过一次、也写进了文档，这轮还是犯了——**说明光记在文档里不够，
得变成动手前的检查**。往后写组件方法名前，先扫一眼基类已占用的属性名（`rotate` / `width` /
`height` / `margin` / `scale` 等）。

### 设置：更新与维护（上一轮）

`settings/AppMaintenanceSection.ets`（对应 iOS `AppMaintenanceSettingsView` / Web `settings-view` 的 `AppSection`）。

iOS 是三个胶囊页签，**默认停在「版本与更新」**——因为这一页的高频入口就是「有可用更新」，
用户带着「来更新」的意图落地。本轮做了前两个：

- **版本与更新**：当前版本 / 检查更新 / 更新日志（折叠）/ 一键更新 / **更新进度轮询** /
  GitHub Token（私有仓库或老被限流时要用）；
- **缓存管理**：磁盘总量与占用条、缓存 / 数据分项、**逐目录明细**（标题 + 一句话用途 + 重建代价）
  与按目录清理，清完给「删掉 N 项、释放 X」。

两条值得说的安全处理：

1. **更新前两次确认**：一般情况提示「会重启后端，正在跑的下载与扫描会中断」；
   若服务端把这一版标成 `latest_known_bad`，**再叠一层警告**并让用户明确选「仍要更新」；
   `compatible == false` 直接拦住（运行时要求不满足）。
2. **更新期间的请求失败是正常的**（后端正在重启），所以进度轮询故意**吞掉异常继续轮**，
   而不是弹错误——这点不写清楚的话，用户会以为更新挂了。

实测：当前版本 0.30.0 /「已是最新」/ 看更新日志 / 检查更新；GitHub Token 显示「已配置（****WEk8）」。

**没做**：**定时任务**页签（`ScheduledTasksPanel`）、回滚到历史版本、页签上的更新蓝点
（要外壳常驻轮询，见 iOS 的 `ShellBadges`）。

**MCP 服务本轮也没做**——两件事加起来超过一轮的量，按上一轮说的「做不完就如实说」，
只交了更新与维护这一块。

### 设置：网络（上一轮）

`settings/NetworkSection.ets`（对应 iOS `NetworkSettingsView` / Web `network-config-section`）。

**iOS 的交互模型是「自动保存，立即生效」**——这是它和别的分区最不一样的地方，照做了：

- 代理方式 / 服务开关**点按即落库**；地址输入框**提交（回车）才落库**；
- **没有「保存」按钮**——所以顶部加了一条会自己消失的状态行（保存中 / 已保存 / 保存失败），
  否则用户没有任何反馈；
- **保存请求串行化**：用一条 Promise 链，快速连点开关时按顺序落库，
  **避免旧请求覆盖新配置**（这条是 iOS 注释里点名的）；
- 「测试」可随时点，但**先等在途保存落库**再测——测的才是此刻看到的配置。

分组：代理（三选一 + 手动地址 + **环境变量探测结果**）→ 走代理的服务（8 项，各带开关与逐项测试）
→ 镜像地址（高级，默认折叠）。

实测：代理「跟随环境变量」+「部署环境里探测到代理：http://192.168.50.100:7890」；
8 个服务（TMDB 元数据 / 图片回源 / 豆瓣 / AI 模型 / Telegram / Discord / 飞书 / 事件 Webhook）。

**没做**：PT 站点分区、**外部访问**（对外端口要全量重启，得单独二次确认）、
说明文字的 ⓘ 气泡（这里直接写在字段下面）。

**MCP 服务本轮没做**——原计划一起做，但看过之后发现它是**三个屏**（列表 + 详情三栏 + 新建弹层带令牌专屏），
比网络大一倍有余，硬塞会让两边都只做一半。留下一轮。

### 设置：消息推送（上一轮）

`settings/PushSection.ets`（对应 iOS `PushSettingsView` / Web `im-push-section`）。

iOS 把两类设定**按分段标签分开**，因为它们回答两个**完全不同的问题**——照做：

- **接入通道**：我接了哪些账号？跨平台统一列表（Telegram / Discord / 飞书 / 微信）+
  「新增通道」；**切换标签时另一侧卸载、回来重新拉**（同 iOS）；
- **推送内容**：什么事件会推给我？两个事件开关（**逐项即时保存**）+ 一键测试推送。

绑定流程：`channelsImBindingsStart(channel, {token})` → 拿**一次性配对码** → 弹层展示
「把这段配对码发给 <bot_name>」→ 用户去 IM 里发完，回来点「我已完成，刷新」查状态。

实测：分段标签 + 平台胶囊（Telegram / Discord / 飞书 / 微信）+ 提示文案 +「新增通道」+ 空态。

**没做**：微信的扫码绑定、飞书的专属绑定流程（这两家有各自的挑战流程与二维码，
Telegram / Discord 走的是通用配对码）；绑定后的**自动轮询**（先用「我已完成，刷新」手动确认）。

**一个必填字段的坑**：`ImBindTokenPayload.token` 是**必填**的（后端用它区分「同一账号重复发起」
的同一次挑战），我按直觉传了空对象，编译期直接报出来。

### 设置：Webhook（上一轮）

`settings/WebhookSection.ets`（对应 iOS `WebhookSettingsView` / Web `webhook-section`，Stripe 式管理页）。

三层结构照抄：

1. **总开关 + 目标列表**：一行一个 endpoint，**状态点显示最近一次投递结果**，
   行内给「发送测试 / 记录 / 编辑」与启用开关；
2. **编辑弹层**（新建与编辑共用）：显示名、URL、外发格式、**订阅事件按目录分组**
   ——目录随 `webhookShow` 下发，**后端新增领域事件时前端零改动**；
3. **一次性密钥展示条**：新建 / 轮换后后端**只在那一次响应里给明文**，立刻展示并提示保存
   （关掉即丢，文案写明「只显示这一次」）。

**一条关键约定照做了**：`PUT /webhook` 是**全量保存**——一次提交总开关与**全部 endpoint**，
任何增删改都要把其余 endpoint 原样带上（只丢只读字段）。iOS 注释里特意说明这是为了
「避免两端各自拼出不同的配置」；不这么做的话，改一个目标会把其他目标清掉。

实测：总开关（当前关）+「添加目标」+ 全量保存说明。当前没配目标，是正确空态。

**没做**：Jellyfin 模板与附加请求头的细调、网络出口（egress scope）、投递记录的全量列表
（行内只显示最近一次）。

**一个命名坑**：方法名不能叫 `rotate`——会和 ArkUI 组件内置的 `rotate` 属性撞名，
报「not assignable to the same property in base type 'CustomComponent'」。改成 `rotateSecret`。
这类「组件基类已占用的名字」还有 `width` / `height` / `margin` 等，写组件方法时要避开。

### 设置：模型接入 + AI 设定（上一轮）

这一对是 iOS 特意分开的**两个问题**，照抄：
**模型接入**回答「怎么连上」（可接多家，官方 + 中转 + 自建并存），
**AI 设定**回答「什么场景用哪个模型」。合成一页就丢了 iOS 的这个分工。

**`settings/LlmSection.ets` → 模型接入**（对应 iOS `LLMSettingsView`）：

- 每个实例一张**状态卡**（状态点、名字、`类型 · 默认模型`、可用/待测试/测试中、上次错误、最近检查时间）；
- 新建 / 编辑走**弹层**（iOS 在手机上也从 Web 的原地展开改成弹层），
  供应商用**预设胶囊**选（`llmPresets`），选了预设自动填名字 / Base URL / 默认模型，
  `requires_base_url` 的才显示 Base URL 输入框；
- 保存后后端**异步**做一次最小对话验证 → 所以任一实例处于 **待测试 / 测试中时每 2 秒刷新，
  全部落定就停**（空闲时零请求）；
- 重新测试 / 删除（删除二次确认，文案说明「用它跑的场景会退回默认模型」）。

实测：两个实例——`DeepSeek-v4-flash`（deepseek）与`黑白`（openai_compat），都是「可用」+ 最近检查时间。

**`LlmSection.ets` → AI 设定**（对应 iOS `AIDefaultsSettingsView`）：

- 两项：**智能体**（AI 对话、分析与自动处理）与**字幕处理**（翻译与生成字幕）；
- 选项来自 `llmModels`（所有已接入实例的模型清单）；
- **选择即保存**，**乐观更新、失败回滚**；另一项若已失效（不在清单里）**不能原样回传**，
  传 null 让服务端按推荐补齐——这条是 iOS 注释里点名的坑，照做；
- 显示的是「用户选的，没有就用服务端的推荐值」，所以永远是真实生效的那个；
- 一个都没接入时给空态，引导去「模型接入」。

实测：两项都显示 `deepseek-v4-pro · DeepSeek-v4-…`。

**踩到一次同类限制**：`LlmProviderPayload` / `LlmDefaultsPayload` 都是可选字段为主的接口，
对象字面量又被 ArkTS 拒——照旧用类实现绕开（本项目第 4、5 次）。

### 设置：成员分区（上一轮）

`settings/MembersSection.ets`（对应 iOS `MembersSettingsView` / Web `members-section`）：
成员账号、能力与资源范围的唯一管理入口。

iOS 的组织方式照抄：

- **列表只负责扫描状态**——头像、启用点、**功能权限徽标**、媒体库范围、最近活动与设备数；
  创建 / 编辑用**独立弹层**，不在列表里展开长表单；
- 每行的 ⋯ 菜单承载**编辑 / 重置密码 / 停用或启用 / 让设备下线 / 删除**；
- **创建与重置产生的明文密码只在一次性结果弹层里出现**，关掉后前端不再保留
  ——与后端「仅返回一次」的凭据语义一致（我在文案里也写明了「忘了只能再重置一次」）。

实测：页头「成员账号 / 管理登录状态、功能权限和可见媒体库」+「添加成员」；
成员行显示「小王吧 · @wangling · 订阅 · 全部媒体库 · 最近 3 天前 · 1 台设备」。

**两处接口与直觉不符，都靠编译期发现**：

1. **创建成员是两步**——`MemberCreateRequest` **只收** `username / password / nickname`，
   能力（订阅 / 搜索 / 直接下载）与媒体库范围都在 `MemberUpdateRequest` 里。
   所以「建账号 → 再用 Update 设能力」，别指望一次建到位；
2. **`MemberUpdateRequest` 全是可选字段**，对象字面量又被 ArkTS 拒（`arkts-no-untyped-obj-literals`）
   ——这是本项目第 3 次踩这条，照旧用类实现绕开。

**没做**：站点范围（`all_sites` / `site_ids`，要拉站点目录）、头像上传、内容年龄上限的细调。

### 设置：系统日志分区（上一轮）

`settings/LogsSection.ets`（对应 iOS `LogsSettingsView` / Web `system-logs-section`），在线日志查看器：

- **按天列表**（`logsDays`）+ 日期选择；内容 `logsRead(day, tail)`，超长默认只取末尾，**可「加载全部」**；
- 按后端固定格式「**时间 | 级别 | 模块 | 内容**」解析成条目，**异常堆栈等续行归并进上一条**；
  文件开头就是续行时（tail 把堆栈拦腰截断）单独成条兜底，不把内容丢掉；
- **级别筛选带条数**（全部 / 错误 / 警告 / 信息 / 调试）+ 关键字搜索（匹配内容或模块）；
- 自动刷新 关 / 3s / **10s（默认）** / 30s，**只对当天日志生效，看历史日期时暂停**。

实测：全部 2000 / 错误 0 / 警告 75 / 信息 1925 / 调试 0，条目解析与续行归并都对。

**没做**：tail -f 式跟随（停底部自动滚入 + 「N 条新日志」回底）、全屏查看、搜索高亮。

### 抓到 8 个「运行时空白」的图标（本轮最值钱的发现）

加日志分区时想给「系统日志」配个图标，试了 `sys.symbol.terminal` 才发现**不存在**。
顺手把设置页那 14 个图标全查了一遍——**8 个是错的**：

| 写错的 | 实际不存在 |
|---|---|
| 消息推送 | `bubble_left_and_bubble_right` |
| 网络 | `globe` |
| 成员 | `person_2_badge_key` |
| 刮削与整理 | `photo_on_rectangle` |
| 播放 | `play_rectangle` |
| MCP 服务 | `powerplug` |
| 模型接入 | `sparkles` |
| 系统日志 | `terminal` |

**为什么一直没发现**：图标是写成 `SymbolGlyph($r(item.symbol))` 传**变量**的，
而**传变量时编译期不校验资源是否存在**——名字错了要到运行时才发现，表现为**图标位置空白，不报错**。

修法不只是换名字：把 `iconFor(symbol)` 改成**直接的 `$r(...)` 分派**（一长串 if），
这样编译期就会逐个校验。改完立刻又抓出 `photo` 也不存在，一并换成 `picture`。

**这条值得推广**：凡是「按名字查资源」的地方（图标、颜色、字符串），
只要可能拼错，就应该让编译器来查，而不是等运行时看空白。

### 设置分区开张（上一轮）：索引页 + 设备分区

iOS 的设置是 **18 个分区、约 10.5k 行**，是剩下最大的一块。本轮按计划**先做骨架**。
清单与分组**照抄 iOS `AppRoute.swift` 的 `SettingsSection`**（title / subtitle / systemImage 逐条对齐，
那些小字讲的是「这一区能解决什么」）：

| 组 | 分区 |
|---|---|
| 账号 | 设备、成员 |
| 媒体库 | 刮削与整理、播放 |
| 通知与集成 | 消息推送、Webhook、模型接入、MCP 服务、AI 设定 |
| 系统 | 更新与维护、网络、系统日志 |

两条 iOS 的规矩照做了：

- **「个人信息」不列进设置目录**——iOS 明确去掉了这个重复入口（2026-09-27），入口是「我的」页头像卡
  （上一轮已接）；
- **`overview / subscription / sites / downloaders / importWatch` 不列出**——iOS 的
  `availableInApp == false`：资源与下载的配置只在网页端管（为降低审核按「便利文件共享」条款拒审的风险）。
  这几项在鸿蒙这边也就不列。

**设备分区做实了**（`SettingsSectionPage.ets`）：当前这台**置顶**并带「当前」徽标、
注销键对它**置灰**（不能注销自己，得换一台设备操作）、超管有「只看我的设备 / 全部成员」开关、
每个设备显示类型 · 平台 · 版本与最近活跃时间，底部写明注销语义
（「注销即断：它正在播的片、正在跑的转码会一并停止」——iOS 原话）。

实测：列出 8 台设备，当前这台是 `emulator`。

**其余分区**显示「这一分区鸿蒙端还在做，先用网页端管理」——**措辞上说实话，不假装已支持**
（iOS 那边这个位置是给「App 不提供的分区」用的，说「请在网页端管理」，语义不同）。

**踩到符号名的坑**：iOS 的 `systemImage` 是 SF Symbols 的名字，鸿蒙的 `sys.symbol.*` 是另一套，
**名字像不代表存在**（`laptopcomputer` / `hammer` / `gearshape_2` 都不存在）。
试了几个之后改用**项目里已经编译通过的符号**做候选，比逐个去翻 SDK 的符号表省事得多。

### 我的收藏（上一轮）+ 首页「查看全部」分化

首页各行的「查看全部」原来**共用一个三点菜单**（`comingSoon('全部内容')`），
所以收藏行、库行、合集行点了都只弹提示。本轮拆开，各去各的：

| 行 | 去处 |
|---|---|
| 收藏行 | 新增的**我的收藏**墙 |
| 库行 | 单库页 `libraryDetail` |
| 合集行 | 合集详情 `collectionDetail` |

新增 `library/FavoritesPage.ets`（对应 iOS `FavoritesView` / Web `favorites-view`）：
**跨库的一面墙**——分页拉 `playbackFavorites`（每页 60），整面钉死 2:3，
**每格落回它自己所属的库**（跨库墙的关键，不能都往一个库跳），排序记在本机。

实测：进页正常，空态「还没有收藏 / 在影片详情页点「收藏」，就会出现在这里。」（这个账号确实没收藏过）。

**没做**：图床浏览（iOS 的第二种形态）、「回到上次浏览的位置」。

**踩到一个 ArkTS 限制**：`@Builder` 里**不能写 `const`**（「Only UI component syntax can be
written here」），而闭包又会**丢掉 `instanceof` 的类型收窄**——两个限制叠起来，
「按行类型决定跳哪儿」就没法写在 `@Builder` 里。解法是抽成方法、把收窄后的类型当参数传进去。

### 自定义首页（上一轮）

`library/LibraryCustomizeSheet.ets`（对应 iOS `LibraryCustomizeView` / Web `library-customize-view`），
以弹出表单呈现（iOS 也是 `AppSheet.customizeHome`）。

iOS 把这件事组织成**「编辑列表」**（不照搬 Web 的原地展开）：主清单只做两件事——
**行首圆圈显隐、排序**；每行下面一行小字说清来源与排序；**恢复默认**是清单最底部的红字
（二次确认，不占右上角，那里是 ✓ 完成）；**保存**是每次改动落本地草稿、**400ms 防抖后整份 PUT**。

实测清单：接下来继续 / 我的收藏 / 我的媒体库（都是「内置」）、最近添加的电影库（「电影库 · 最近添加的电影库」）、
最近添加的剧集库。底部「恢复默认布局」。

**与 iOS 的差异**：iOS 用拖拽把手排序，这里用「上移 / 下移」两个按钮——
ArkUI 的 `List.onMove` 要先进编辑态，为一个次要交互改整页结构不划算；
iOS 自己在「管理媒体库」里也承认手机上没有拖拽、改走按钮面板。

**踩到的三件事**：

1. **`PUT /ui/preferences` 真的是整体覆盖**（核过后端 `routes/ui.py` + `settings/schemas.py`：
   `UiPreferencesSetting` 的字段都有默认值，缺字段会被重置），所以其余偏好必须原样带回。
   但不能把「视图类型」直接当「写入类型」用——ArkTS 禁结构化类型（`arkts-no-structural-typing`）。
   最后用 `Record<string, Object>` 承载整份偏好再序列化。
2. **ArkTS 拒绝「全可选接口」的对象字面量**（`arkts-no-untyped-obj-literals`）：
   `HomeUiPrefsInput` / `UiPreferencesSettingInput` 的所有字段都带 `?`，写 `{...}` 会报
   「must correspond to some explicitly declared class or interface」。用类实现绕开。
3. **又一个「锚点不唯一」**：`comingSoon('自定义首页')` 在文件里有**两处**——
   一处是空态框里的按钮（我改的是这处），另一处才是 ⋯ 菜单（`LibraryNavHost`）。
   菜单项改完仍是 `comingSoon`，点了只弹 toast，于是我在模拟器上连点四次都"没反应"。
   菜单与弹层不在同一层，最后用 `@Prop @Watch` 的信号把它传过去。

### 筛选面板「二级维度永远在加载」——一个已修的老 bug（本轮最重要的发现）

验「存为合集」时发现筛选面板一直停在「正在数各档位还剩多少部…」，25 秒不动。

查下来的根因**不是接口慢、也不是失败**：`FilterSheetContent` 的 `facets` / `loading`
写成了**普通成员**。ArkUI 里**非装饰成员只在构造时赋值一次，之后不更新**——
所以 facet 早就拉回来了，子组件却永远看不到，永远显示加载文案。

改成 `@Prop` 后全部恢复。实测面板现在显示：

- **找片**：评分（≥9 0 / ≥8 5 / ≥7 31）、片长（≤60' 0 / 60-90' 3 / 90-120' 28 / >120' 30）、
  原始语言（zh 40 / en 19 / cn 1 / ms 1）
- **查库**：分辨率（2160p 57 / 1080p 1）、动态范围（HDR 33 / SDR 28）、库存状态（文件失联 0 / 没刮到档案 0）

也就是说：**这六个二级维度一直是坏的**，只是没人点开过筛选面板的下面半截。
第一级四维（类型/年代/地区/观看）看起来正常，因为它们不依赖 facet。

顺手把「加载中」与「拿不到」分开（原先拉取失败也置 `facets=null`，
和加载中同貌 → 失败会永远转下去），失败时给一句话 + 「重试」。

### 存为合集（本轮，**已实现未端到端验证**）

`library/SaveAsCollectionSheet.ets`（对应 iOS `SaveAsCollectionSheet`），接在单库页的
`onSaveAsCollection` 上，走同一个弹层槽位。

给 `LibraryFilter` 补了 `rules()`——把它转成后端的规则数组（对应 iOS `LibraryFilter.rules`）：
**维内 OR、维间 AND**，每维一条 `{field, op: 'any_of', values}`，
字段名用后端的维度名（`genres` / `origin_countries` / `decades` / `watch` / `rating_gte` /
`runtimes` / `languages` / `resolutions` / `hdr` / `stock` / `series_key`）。
（`LibraryWall` 里本来就有反向的 `fromRules`，两边现在配对了。）

界面照 iOS 的设计：**合集不是一个新概念，是「存好的筛选」**——只问两件事，起名字 +
**用后果的语言**问「以后新出的片算不算」：

- **自动收录**：「以后符合这组条件的片都算进来，随着入库自己长大。」
- **固定这批**：「就现在墙上这些，以后新入库的不会再进来。」→ 走 `payload.snapshot`，
  由服务端把此刻的命中集定格成名单（客户端不必回传上千个 id）。

**验证到哪一步**（本轮补验）：

- ✅ 入口可达：筛选生效后，已选条件行出现「动态范围 HDR × | 清空 | **存为合集** | 筛出 N 部」；
- ✅ 弹层渲染正确：合集名自动取「HDR」、条件数「会存下当前这 1 个筛选条件」、
  两个模式带后果式描述（自动收录 / 固定这批）；
- ✅ 提交路径走通：点「存为合集」后弹层关闭（我的代码里 `onClose()` 只在 `collectionCreate`
  成功后才调）。

**上一轮的两个疑点用日志探针查清了，结论都是「功能是好的，界面没更新」**：

- `collectionCreate` **成功**了（日志：`created id=23`，且 `collectionList` 里确实有 `collection 22 HDR`）；
- 墙筛选**也生效**（日志：`wall(HDR) first5=5` 正常返回）。

真正的问题还是**非装饰成员不更新**，本文件里是**第三处**：

- `FilterConditionRow.facets` → 「筛出 N 部」一直显示全库总数（HDR 生效时仍写 61，
  而 HDR 档位自己显示 33）；
- `FilterPillGroup.facets` → 档位上的数字同理；
- `LibraryCollectionsGrid.collections` → **新建的合集在数据里有了，页面上却不出现**
  （这才是「HDR 找不到」的真正原因）。

三处都改成 `@Prop` 后：合集 tab 出现了「我的合集」分组（修之前只有系列合集那一组），
「筛出 N 部」也跟着筛选变了。

**这一轮最大的教训**：同一个坑（ArkUI 非装饰成员只赋值一次）在这个项目里出现了**三次**，
而且三次都表现为「数据是对的、界面是旧的」，不报错、不警告。我已经扫了一遍全项目
同类写法，剩下的可疑点记在 §7 风险清单里。

### 整理文件名（上一轮）

`library/OrganizeSheet.ets`（对应 iOS `LibraryOrganizeSheet` / Web `library-organize-dialog`），
单库页 ⋯ 菜单里的「整理文件名」接上。

**批量改名是半不可逆操作，交互按「手术确认单」打造**（iOS 原话），四条都照做：

1. **先看后动**：打开即拉完整预览（`workflowLibraryOrganizeFilesPreview`，只读不动磁盘）——
   每条显示「原名 → 新名」，跳过项逐条给原因，带附属文件的标注出来；
2. **风险前置**：无法一键撤销 / 做种会断 / 播放器会重识别三条风险醒目告知，
   勾「我已了解」执行键才亮（置灰态见截图）；
3. **执行可离场**：确认后任务在后端跑（`workflowLibraryOrganizeFilesStart`），
   面板里轮询单库详情画进度，关掉不影响；
4. **结果可追溯**：完成页给出改名 / 附属 / 已合规 / 跳过 / 清理目录的完整账目，错误原文逐条列出。

完成判定用了 iOS 注释里特意点的**两个凭据**（见过 `organizing=true`，或 `last_organize`
换了新结论）——只看 `organizing=false` 不行：POST 受理后后台任务才起跑，
首轮轮询可能落在起跑前的空档，那时拿到的还是上一次的旧结论。

实测《电影库》：将重命名 60 个文件（共扫描 63 / 已合规 0 / 要改名 60 / 跳过 3 / 附属 6），
改名清单逐条可查。

### 顺手修的一个隐蔽坑：一个组件只能绑一个 `bindSheet`

加完这个弹层后点「整理文件名」没反应。查下来是 **`LibraryDetailPage` 这一个
`NavDestination` 上绑了三个 `bindSheet`**（章节 / 编辑库 / 整理文件名）——
ArkUI 里**一个组件只能绑一个，后绑的覆盖前面的**，所以实际只有最后绑的那个生效。

也就是说：**「章节」弹层一直是坏的**（它是最早绑的），只是没人点过所以没发现。
现在合成**单槽位 + 内容切换**（`sheetKind` 决定渲染哪个），三个弹层都恢复。

这条属于「静默失效」——不报错、不警告，只是点了没反应。

### 新建媒体库向导（上一轮）

`library/LibraryCreatePage.ets`（对应 iOS `ManageCreateLibraryForm`），补掉「管理媒体库」死路
（单库页 ⋯ 菜单与首页空态「创建第一个媒体库」两处入口都接上）。

iOS 的向导**只问必答题**：① 选类型 → ② 名称、根目录、可见范围 → ③（影视库）收藏范围。
本轮做了 ① ② 与创建（`POST /libraries`，建完立刻 `libraryScanStart` 一轮，同 iOS 的「创建并开始扫描」）。
「创建并开始扫描」在库名或根目录为空时置灰（同 iOS 的 `ready`）。

四张类型卡的文案**逐字照抄** iOS 的 `ManageKindCard`（「自动识别影片，补齐简介、评分、演职员与海报剧照；
一部片一个目录。」这类），因为它讲的是**后果**而不是参数。

根目录用鸿蒙原生的**文件夹选择器**（`DocumentViewPicker` 的 FOLDER 模式，见 `common/FolderPicker.ets`），
对应 iOS 那边 `.fileImporter` 的目录模式。实测走到第 2 步：电影库 / 库名占位「电影库」/ 根目录（0）/
「+ 添加目录」/ 谁能看到（全部成员 · 仅管理员）。

**没做**：第 ③ 步收藏范围（地区 / 类型）——要拉后端的 `ManageRoutingOptions`，
留到「设置 → 刮削」那批；以及 iOS「管理媒体库」的另外三个页签（回收站 / 重复文件 / 分享，
`LibraryManageView` 744 行 + 三个独立文件）。

### 编辑媒体库表单（上一轮）

`library/LibraryFormSheet.ets`（对应 iOS `LibraryFormSheet` 的编辑态 `ManageEditLibraryForm`），
补掉 2 处「编辑库」死路（单库页的 ⋯ 菜单与页面内入口），以 `bindSheet` 呈现（同 iOS 的 `.sheet`）。

**iOS 的设计要点是"分层"**：按用途分区折叠、**默认全收起、同时只开一个**，
折叠态的摘要行先回答「这个库配成了什么样」，改哪项点哪项。本轮做了三个分区：

- **基本信息**：名称可改；**类型创建后不可改**，只读展示；根目录只读列出；
- **扫描与监控**：实时监控 / 自动清理缺失 / 生成缩略图（影视库还有提取章节图、检测媒体片段），
  摘要行把打开的项拼成一句话（实测「实时监控 · 缩略图」）；
- **可见范围**：谁能看到（全部成员 / 仅管理员 / 指定成员）+ 首页不显示 + 自动系列合集。

保存只提交表单里有的字段，其余传 null 让后端保持原值。

踩到一个枚举坑：`access_mode` 后端实际用的值是 **`everyone`**，不是 `all`/`public`。
我按想当然写了 `all`/`public`/`admin`/`members`，结果摘要行把原始值 `everyone` 直接显示给了用户。
核 iOS 源码确认（`LibraryFormSheet.swift:95` 就是 `@State private var accessMode = "everyone"`，
它的文案是「全部成员」）。

另：`LibraryDetailPage` 是 **V1 组件**（`@Component`），弹层开关得用 `@State` 不是 `@Local`。

**没做**：封面、收藏范围、刮削设置三个分区（iOS 有）、新建库向导。

### 待处理事项抽屉（上一轮）

`library/IssueDrawerPage.ets`（对应 iOS `Features/Library/IssueDrawer.swift`），
**一次补掉 5 处死路**：单库页三个角标（缺失 / 待识别 / 身份复核）各带自己的初始页签，
条目列表里「去待处理认领」带待识别，⋯ 菜单里的「待处理」用缺失。

结构照 iOS：**顶栏**（关闭 + 居中「待处理」+ 计数胶囊）→ **搜索框**（占位随页签变）→
**页签**（缺失 N / 待识别 N / 身份复核 N，计数为 0 时不带数字）→ **一句话说明**（`tab.explanation`）
→ 清单。三类行各不相同：缺失是「一部作品一条 + 挂它缺的文件」，待识别是「一组一条 + 原因 + 体积」，
身份复核是「当前身份 vs 建议身份」。刷新照 iOS 30 秒一轮；**拉取失败且已有数据时不打扰**
（保留上次结果，下轮自愈）。

**没做**：批量操作、**认领面板**（`IssueClaimPanels` 430 行——把未识别文件认领到某部作品的流程，
这是这块最有用的动作、也是最大的一块）、「放错库了」的类型不符引导、已忽略页签。

### 顺手修的一个通用布局坑：自绘顶栏被压扁

`IssueDrawerPage` 的顶栏写成了 `.height(44)` + `.padding({ top: Theme.statusBarInset })`，
结果「关闭 / 待处理」被挤进状态栏里——**ArkUI 的 padding 算在 height 之内**，
写死 44 再扣掉 39 的状态栏，内容只剩 5px。

查了一下这个写法我在 **5 个页面**都用了（个人信息、合集详情、订阅详情、搜索结果、事项抽屉），
全部改成 `.height(44 + Theme.statusBarInset)`。前 4 个当时「看着还行」是因为内容恰好挤在底边，
**不是没问题**。

### 合集详情页（上一轮）

`library/CollectionDetailPage.ets`（对应 iOS `Features/Library/CollectionDetailView.swift`），
**一次补掉 4 处死路**（全部合集页 2 处、单库页 2 处）。媒体库浏览链到这里闭环：
媒体库首页 → 单库页 → 合集 → 条目 → 播放。

结构照 iOS：**页头**（名称 + 「N 部」+ 可见性「只有我可见 / 已隐藏」+ 一行说明它是**怎么来的**
——系列 / 固定名单 / 自动收录）→ **排序胶囊**（默认档是合集自己的序：系列叫「按上映顺序」、
手动合集叫「自定顺序」）→ **海报墙**（分页 60，滚到底自动续，点格进条目详情）。

实测（《坏蛋联盟（系列）》）：页头显示「1 部」「✦ 自动收录 · 按条件自动归集」，
排序胶囊「按上映时间」，墙上是《坏蛋联盟2》2025 ★7.6。

一处**看着像 bug 其实是照抄**：顶栏和页头都显示了合集名。
iOS 那边 `.navigationTitle(collection?.name)` 在压栈页是 inline 显示，页头又用 `.title2` 大写显示一次
——两处都有，是有意为之，不是我重复渲染。

**没做**：⋯ 管理菜单（改名 / 分享 / 改条件 / 整理顺序 / 显示在首页 / 隐藏 / 删除）、
自动收录条件详情弹层、系列合集把「库里缺的那几部」按上映时间插进墙里、图床浏览。

### 订阅详情页（上一轮）

`subscriptions/SubscriptionDetailPage.ets`（对应 iOS `SubscriptionDetailView` / Web
`subscription-inspector-view`），订阅列表点行进来（原来只会弹提示）。

结构照 iOS 三块：**摘要卡**（海报身份 → 配置事实「已勾选 N 季 · 自动续订已开」→ 收录进度条 →
操作区：立即搜索 / 开关自动续订 / 取消订阅）→ **单集履历**（按季分组、可折叠，一集一条，
带抓取标题与上次拒绝原因）→ **排查记录**（最近活动流水）。

刷新节奏也照 iOS：**有在途投递（`grabbed` / `downloaded`）时 5 秒一轮，没有则零请求**——
订阅页列表本来就在轮询，详情页不做无谓的定时拉取。

实测（《斗破苍穹》）：已勾选 5 季 · 自动续订已开 · 追踪中、已入库 9/34（26%）；
第 4 季展开显示 E01–E03 与「已入库」，第 5 季 31 集折叠；
排查记录里能看到「搜索关键词 730/856 条」「已投递 S05E142 等 18 集，来自 mteam」。

**没做**：「更多」管理面板（调整订阅、洗一轮版、更换规则组）、实时下载进度、
取消订阅的**移除预览**（带删种 / 删文件选项，我这里走简单确认）。

**两处模型与 iOS 对不上，按鸿蒙这边实际字段写**：
- `SearchNowView` 只有 `reset_count`（重新排队的缺口工单数），没有 iOS 那边的 `started`；
- `SubscriptionFollowFuturePayload` 的字段是 `enabled`（不是 `follow_future`）。

### 全局订阅弹层（上一轮）

在此之前，发现页/发现详情页的「订阅追踪」「订阅影片」**点了只会弹提示**——是唯一一处
「高频入口点了什么也不发生」的地方，所以优先补掉。

- `subscriptions/SubscribeCenter.ets`：全局入口，对应 iOS 的 `router.present(.subscribe(...))`。
  任何页面 `SubscribeCenter.present(titleRef, title)`，由外壳统一弹出（回调式，非轮询）。
- `subscriptions/SubscribeSheet.ets`：弹层内容，对应 iOS `SubscribeSheet` / Web `subscribe-dialog`。
  流程照 iOS：先 `uiSubscriptionsPreviewTitle` 预检，按**三态**分流——
  `ready`（剧集勾季 + 自动续订 + ✓）、`ambiguous`（豆瓣歧义，候选海报墙选一个后带新引用重新预检）、
  `not_found`（TMDB 未收录）；已订阅则进**管理态**（提示 + 取消订阅）。
- 默认值照 iOS：剧集勾后端 `suggested_seasons`（没有就勾全部已播季）；**在播剧开自动续订**
  （判据是最新一季 `aired_count < episode_count`）。
- 外壳 `MainTabsPage` 用 `bindSheet` 托管（iOS 那边是 form sheet）。

实测：电影（《大学炸弹客》——ready 态、✓ 高亮可用）；剧集（《兰香如故》——
「追踪哪些季」第 1 季已勾选「已播 40/47 集」、自动续订默认开）。

### 条目级管理动作（本轮）

`LibraryItemDetailPage` 顶栏加 **⋯ 菜单**（仅管理员可见）：**刷新元数据 / 重新识别 / 转移条目 / 删除条目**。
库级的元数据刷新早就有（`LibraryDetailPage` 的 `metaLabel` + 停止），缺的是条目级。

**「刷新元数据」和「重新识别」的区别要在文案上立住**：前者只重拉 TMDB 的资料与图片、**不动身份**；
后者是身份认错了才用。用户看到「海报旧了」该点刷新，看到「认成了别的片」该点重新识别——
**混在一起会让人用错工具，然后以为功能坏了**。所以菜单里分成两条，各带各的说明。

**重新识别的结果逐项报**：`identified` / `unidentified` / `skipped_missing`（文件不在）/
`kept_on_error`（出错但保留了原匹配）。其中 **`changed` 时要说「已经换成另一条，返回后请重新打开」**
——换了条目意味着用户现在看的这个页面已经不是同一部片了，不明说的话他会以为数据错了。

**删除沿用回收站的安全口径**：确认框写的是「文件会进回收站（不是直接删除，之后还能恢复）」，
而不是「会被删除」。

实测：⋯ 菜单正常展开（刷新元数据 / 重新识别 / 转移条目 / 删除条目）。
**四个动作都没执行**——都会真的改数据（重拉元数据 / 改身份 / 移文件 / 移除条目）。

**没做**：**转移条目的向导**（`libraryItemsTransfer` 需要选目标库与目标位置，是个独立表单，
现在点了只说明「还没做」）、**换海报**（`ArtworkPickerSheet`）、逐条的元数据刷新进度面板
（库级有，条目级只有「已开始」提示）。

### 订阅洗版（本轮）——订阅线最后一块### 订阅洗版（本轮）——订阅线最后一块

`SubscriptionDetailPage` 的顶栏「洗版」入口 + `UpgradeSheet`。

- **入口条件显示**：只有存在 `wanted[].upgrade.active` 的单元时才出现。
- **预览**来自 `wanted[].upgrade`（`active` / `current_label` / `target_label` / `search_attempts`），
  不需要额外请求。
- **执行**是 `POST /subscriptions/{id}/upgrade-runs`，返回报告（`summary` / `counts` / `units`）。
- 报告里**把 `counts` 直方图翻成人话逐类列出**：
  「可洗版（已排入）/ 已投递新版本，等待入库验证 / 已达洗版目标 / 不参与比较 / 已暂停」。
  **只说「完成」会让用户以为全都换新了**，而这四类的结果完全不同。
- 确认框写清「旧版本不会立刻删，新版本入库验证通过之后旧版才进回收站」
  ——这正是回收站里那 22 个 `upgrade_replaced` 的来源。

**验证时顺手发现并修掉一个 UX 缺陷**：这条订阅的「可洗单元」是 0，
而「开始洗版」按钮**仍然可点**——点了只会白跑一趟，还会让用户以为洗过了。
改成 0 个单元时按钮禁用并写「没有可洗的单元」。

**验证边界**：面板渲染、条件显示、计数文案都验了（截图里「会给 0 个单元去找更好的版本」
如实反映这条订阅的状态）。**没有点「开始洗版」**——它会真的去各站点搜索并投递种子。
验面板时临时把入口条件放开成 `if (true)`，验完已恢复。

### 活动页剩下三段（本轮）——第 51 轮盘点时说过要补的

`ActivityPage` 补上 **正在播放 / 正在下载 / 观看统计**，至此 iOS 活动页的七段齐了。

- **正在播放**（`playbackActivity`）：谁 · 哪台设备 · 实时速率 · 连接数 · 进度条。
  **`paused` 要显出来**——一条停在 40% 不动的会话，和「正在播但用户暂停了」是两件不同的事，
  不区分的话用户会以为卡住了。
- **正在下载**：`已传 / 总大小 · 速率 · 成员` + 进度条；另外把 `hidden_*_count` 也写出来
  （「另有 N 条」），否则管理员会以为漏了。
- **观看统计**：活动页只露**一张近 7 天摘要卡**（同 iOS「历史与统计只露一小段」）：
  播放次数 / 观看时长 / 看完 / 活跃成员，并与上一周期对比。
  **没有上一周期就不给方向词**，而是写明「还没有上一个周期可比（历史不够长）」
  ——比编一个「+0%」诚实。

实测：**26 播放次数 / 2.8 小时 / 5 看完 / 2 活跃成员**（真实数据）；
正在播放/下载为空是因为当前确实没有会话在跑，属正确表现。

**本轮犯的错值得单独记**：三段一开始被我插进了 `ActiveSection()` 里，
而那个 builder **只在「有进行中任务」时才渲染**——所以「没有整理任务在跑时，
正在播放/正在下载/观看统计全都不见了」。
**这不是逻辑错，是位置错**：我把 UI 放进了一个有条件的容器里。
教训：**往已有页面插版块前，先看那个容器本身是不是带条件的**。

### 重复文件（本轮）——和回收站配套

`library/DuplicatesPage.ets`（对应 iOS `Features/Library/ManageDuplicateFiles.swift`）。
入口：库详情页 ⋯ 菜单的「重复文件」。

解决的问题：同一个单元（一集 / 一部电影）在库里有**多份**文件（不同来源、不同画质、洗版留下的旧版）。

**核心 UX 是「后端已经替你挑好了」**：每份文件带 `suggested` 与 `suggest_reason`，
界面把**推荐的那份用绿框高亮 + 「推荐」标 + 写明为什么**。
实测截图里那句「**为什么推荐它：同档，实测码率更高**」就是关键——
两份都是 `2160p hevc`，没有这句理由用户只能瞎选。

**三种粒度都做**（同 iOS）：

- **按份**：保留这一份，其余进回收站；
- **按季选版本**（`keep_version`）：同一版本横跨几十集时不用点几十次；
- **全保留**（`keep_all`）：这一季不做去重；
- 另有**长按组胶囊按推荐整组处理**（`libraryDuplicatesResolveAll`）。

**沿用回收站那轮的安全设计**：所有「保留」的后果都是「**其余的进回收站**」而不是直接删，
确认框里写的也是「会进回收站（不是直接删除，之后还能恢复）」。

实测（**用户的真实库**）：**289 个单元有多份 · 可省 1017 GB**（533 个文件 / 16 部作品），
分组「可以放心清理 9 / 建议清理 4 / 需要你决定…」，展开后文件级对比与推荐理由都正确。
**没有执行任何保留/清理操作**——那会把用户的文件移进回收站。

**又撞见一个自己写的静默缺陷**：`showVersionPicker` 里算了一串版本名却没用上，
而且**永远只弹第 0 个版本**。改成 `bindMenu` 把每个版本都列出来。
这类「编译得过、点了不对」的错这几轮反复出现（`this.this.openReels()` 也是），
**说明我写完一个分支后没有走一遍它**。

### 回收站（本轮）——**全 App 唯一会真正删文件的地方**

`library/RecycleBinPage.ets`（对应 iOS `Features/Library/ManageRecycleBin.swift`）。
入口：库详情页 ⋯ 菜单的「回收站」（只看这个库）。

**这里每一个判断都围绕「别让人误删」**：

1. **`purge_after` 用红字写清**：回收站里的文件到点会被**自动彻底删掉**。
   「以为反正在回收站里、其实已经没了」是最糟的误解，所以每条都标「最早 N 天内一到就自动彻底删除」。
2. **`kept_in_place` 单独说明**：这类文件**没有被移动**，只是从媒体库摘掉了记录。
   和真被移走的混在一起说「已删除」，用户会以为磁盘空间回来了——所以概览上写
   「其中 N 个『留在原位』：磁盘空间没有释放」，用警示色。
3. **恢复不确认、彻底删除必须确认**：恢复是安全的，删除不是。确认框里写清
   **具体条数 + 具体体积 + 不可撤销 + 不进系统回收站**。
4. **批量结果分开说**：`done` / `failed` / `remaining` 三段都报，并给出**第一个失败的原因**。
   只说「完成」会掩盖「一部分失败了」，而用户以为都成功了就不会再去看。
5. **筛选和刷新后清空选中**：`picked` 里的 id 可能已经不在列表里了，
   留着会让用户「选中了一个看不见的东西」然后批量删掉。

实测（**用户的真实回收站**）：23 个文件 / 34.03 GB，原因筛选
（`upgrade_replaced 22` / `upgrade_refuted 1`）与条目卡片（「洗版替换: 1080p WEB-DL → 2160p WEB-DL」、
红字倒计时）都正确。**没有执行任何删除或恢复**——那是真实副作用。

**还没做**：重复文件（`libraryDuplicatesList` / `Resolve` / `ResolveAll` / `Scan`，iOS 的
`ManageDuplicateFiles.swift`）、跨库的回收站入口（现在只能从某个库里进）、
单条目的「恢复这一个 / 删这一个」快捷操作。

### 设备批准（本轮，手输配对码这条链路）

`settings/DeviceApprovalPage.ets`（对应 iOS `Features/DeviceApproval/`，626 行）。

流程照 iOS 与网页 `/activate`：输入配对码 → `authDevicesRequest(code)` 查这条请求 →
**卡片**上摊开设备 / 类型 / 平台 / 版本 / 来源 IP / 配对码 / 剩余有效 / 申请的权限 →
「批准登录 / 拒绝」→ 结果卡。

**两条照 iOS 的设计判断**（它的注释写得很清楚）：

1. **批准 / 拒绝放在卡片里、不放导航栏**：导航栏的「取消 / 完成」是编辑类表单的确认；
   这里是一个**有安全后果的决定**，所以用底部卡片里的大按钮——拇指够得着、看完信息顺手按。
2. **查到码也不自动批准**：人必须看过卡片再按，这是防钓鱼的那道闸。

**两个自己加的判断**：

- **拒绝时把后果说清**：「如果这不是你要登录的设备，说明有人拿到了你的配对码，建议顺手改一下密码」
  ——拒绝本身不解决「码怎么泄的」这个问题。
- **批准前再确认一次**，并把 `requires_admin` 单独标出来（申请管理员权限和不申请是两回事）。

实测：入口（设置 → 设备 → 批准新设备登录）与页面渲染正常；
用一个无效码走通查询链路，屏幕上出现**后端原样返回的**「配对请求不存在或已过期，请让设备重新发起」。

**本轮没做**：**扫码**（需要相机权限 + `@ohos.multimedia.camera` + 码识别，
iOS 的 `PairingScannerScreen` 239 行就干这个）、「我的」页右上角的扫码入口、`/activate?code=` 深链。
**手输配对码这条链路是完整的**，扫码只是更快的入口。

### 播放器手势层 + 长按倍速（本轮）

`player/PlayerPage.ets`，对应 iOS `PlayerGestureLayer.swift`（判定阈值逐字照搬：
`activatePx 12` / `edgeGuard 32` / `doubleTapWindow 300ms` / `holdDelay 500ms` /
`fullSweepRatio 0.6` / `adjustTopExclude 0.12` / `adjustBottomExclude 0.24`）。

- **单击 = 切控制条**（不为等双击延迟，第一下就生效）；**双击左右三分之一 = ∓10 秒**
  （先把第一下切过的控制层恢复原状，净效果只剩跳转）；
- **横滑 = 拖进度**：满屏一划 90 秒，**落点读数 + 松手才跳**——iOS 的 `scrubFollow`
  途中跟随在鸿蒙这边会打爆服务端转码器（HLS 跳转要重新取分片），这是**已记录的行为差异**；
- **竖滑**：左半屏 = 亮度（`setWindowBrightness`，退出恢复 -1 跟随系统）；右半屏 = 音量——
  鸿蒙三方应用改不了系统音量，与 iOS 音量不可调时同款降级文案「音量由系统侧键控制」；
- **按住 500ms = 2 倍速**（`SPEED_FORWARD_2_00_X`，抬手恢复；暂停时不起）；
- 控制条自动隐藏 3s→**4s**（iOS 对齐）；`chromeMustStayVisible()`（暂停 || 弹层开着）常显。
- 顺手修掉一个既存 bug：统计面板的 X 键写的是没人用的 `showStats`，实际该收 `showSheet`。

**本轮最值钱的坑：控制条的全屏容器会吞掉所有触摸**。ArkUI 的 `Column`/`Stack`
即使没有背景也在命中测试范围内——控制条的内容 Column 是全屏的（`Blank()` 撑布局），
把「点画面收控制条」整个挡死了，模拟器实测单击毫无反应。SwiftUI 的空容器天然不挡，
所以 iOS 没这个问题；鸿蒙侧的修法是两层：

1. 控制条根 Stack 加 `hitTestBehavior(HitTestMode.Transparent)`——按钮照常响应，
   渐变垫与空白处穿透给下层手势层；
2. **穿透是把双刃剑**：按钮上的触摸也会送一份给手势层（UIKit 只给最上面的按钮），
   所以手势层在控制条可见时要显式忽略三个禁区——顶栏 / 底栏整条 + 中央三键自己的横向范围，
   用 `onAreaChange` 量出实际位置（对应 iOS `gestureExclusions` 的
   `topBarFrame` / `bottomBarFrame`，中央三键是 ArkUI 平台差异多出来的）。

另一个隐性炸弹：`layerHeight` 初值 0，而底缘守卫是
`touch.y >= layerHeight - 32`——首次布局前任何触摸都会被 `y >= -32` 吞掉。
改成量出来（>0）才启用底缘守卫。

**验证边界**（模拟器，`devecocli ui` 逐步验的）：单击收 / 唤控制条、
禁区内的点不误切控制条、按钮仍可点（音轨面板开合）、右半屏竖滑出音量降级 HUD、
左半屏竖滑出亮度 HUD（太阳图标）、横滑出落点读数（`+0:00`）——**全部通过**。
**没法验的**（都需要真的在播）：双击 ∓10 秒、长按 2 倍速、4 秒自动隐藏、松手跳转——
卡在**服务端转码老问题**（VAAPI，ffmpeg 起转即退，`分片尚未就绪`），
客户端整条链路（协商 → 降档 → 原样展示服务端理由）行为正确。

### 分享（上一轮，主人侧）

`library/ShareSheet.ets`（对应 iOS `Library/LibraryShareSheet.swift`）+ 条目详情页顶栏的分享键。

按 iOS 的话术与档位：有效期 **1 / 3 / 7 / 30 天 / 永久**、可选密码、
建好后显示 **链接 + 复制 + 访问次数 + 创建时间 + 有效期至 + 密码 + 最近访问**，以及「停止分享」（带二次确认）。

**两个刻意的判断**：

- **复制失败要如实说**：`pasteboard` 可能失败，静默失败会让用户以为链接已经在剪贴板里了，
  所以失败时提示「复制失败，请手动选中链接」，同时链接本身开了 `copyOption` 可长按选中。
- **停止分享要二次确认并把后果说清**：「停止后这条链接立刻失效，**已经拿到链接的人也打不开了**」
  ——这条撤销是**对外**生效的，不是本地隐藏。

**踩到的坑**：

1. **`SharePanel` 混用了 V1/V2 装饰器**：`@Prop` 是 V1 的、`@Event` 是 V2 的，
   混在一起直接报 `'@Prop' decorator can only be used in a 'struct' decorated with '@Component'`。
   调用方 `LibraryItemDetailPage` 是 V1，所以组件也统一成 V1（`@Prop` + 普通回调字段）。
2. **`LibraryItemDetailPage` 是 V1 `@Component`，不能用 `@Local`**——又踩了一次
   （文档里早写了「V1 页面用 `@State`」，但写的时候还是顺手写了 `@Local`）。
3. **`sys.symbol.square_and_arrow_up` 不存在**（又是照着 iOS 的 SF Symbol 名字猜的）——
   改用已验证的 `sys.symbol.paperplane`。

**验证边界**：面板渲染、档位选择、密码输入都验了（截图）；
**没有点「生成链接」**——它会在用户服务器上真的建一条公开链接，属于真实副作用，不擅自执行。

**还没做**：访客侧的分享页（iOS `Features/Share/` 811 行：探针 → 密码解锁 → 影片/合集页）、
合集详情的分享入口、`已完成` 的「重新生成」档位。

### 隐藏系统手势指示条（上一轮）

用户早前说过「底部那条黑/白条要去掉」。我按自己的理解猜了几轮都不确定，**直接问了**，
答案是**最底部系统的手势导航指示条（「小白条」）**。

修法（`EntryAbility.applyImmersiveLayout`）：

```ts
mainWindow.setSpecificSystemBarEnabled('navigationIndicator', false);
```

**关键是别用错 API**：`setWindowSystemBarEnable([])` 看着更直接，但它会把**状态栏一起关掉**
——那就把「沉浸通知栏」也弄没了，和需求正好相反。
`SpecificSystemBar` 是 `'status' | 'navigation' | 'navigationIndicator'` 三选一，
精确关掉指示条、保留沉浸状态栏。

实测：小白条消失，悬浮页签栏正常收在底部。

**方法论上的教训**：这条需求我前面几轮一直在按自己的理解推进（以为是标签栏遮挡、以为是黑带），
文档里也写了「单列」。**其实一句话就能问清楚，我却拖了三轮**。
「用户描述模糊 + 有多个候选解释 + 修法互斥」时，**问的代价远低于猜错一轮**。

### 关于页

`about/AboutPage.ets`（对应 iOS `Features/About/AboutView.swift`，102 行）。
结构与文案照 iOS：版本 / 项目主页 / 隐私政策 + 隐私说明 footer、开源组件、数据来源（TMDB）。

**但组件清单不照抄**：iOS 那份列的是 AetherEngine / FFmpeg / Nuke 这些 **Apple 端专有**依赖
（`apps/apple/Shared/About/OpenSourceComponent.swift`）。鸿蒙端是纯 ArkTS、只用系统 Kit 与 HDS，
**没有随包分发的第三方库**——照抄一份不属于这个平台的清单是错的，所以如实写清并说明为什么。

**三个踩坑**：

1. **`Text` 不解析 Markdown**：我按写文档的习惯在文案里加了 `**强调**`，结果**星号原样显示在界面上**。
   ArkUI 要用 `StyledString` 才有富文本，普通字符串就是纯文本。
2. **异步 `getBundleInfoForSelf` 拿不到版本**：屏幕上一直显示 `—`，
   而 ArkCompiler 的日志里明明写着 `entry|entry|1.0.0`。换 **`getBundleInfoForSelfSync`** 立刻就有值。
3. **`ApplicationInfo` 上没有版本字段**（版本在 `BundleInfo` 上）——我原本写的兜底读了个不存在的属性。

实测：版本 `1.0.0（1000000）`、三个分区与链接都在。
「我的」页那行原先硬编码的「版本 0.1.0」也换成了「版本与开源许可」。

### 片段 / Reels（上一轮）——**全项目 `comingSoon` 死路清零**

`reels/ReelsPage.ets`（对应 iOS `ReelsView` 878 行；**本轮是 v1**）。

形态照 iOS：**整页上下滑**（`Swiper(vertical)`，不是列表），每页是某部片里的一段。
版式也照它：纯黑底、左上是片名 + 年份 + 类型（点了去详情页）、左下简介、
右侧一列按钮、最底下一条**细进度线（按片段算，不按整部片）**、点空白处暂停 / 继续。

**一个必须做对的资源问题**：**一个时刻只存在一个播放器**——翻页时先把上一个 `release()` 掉
再起这一个。不这么做的话滑十几页会开十几个解码器，直接就爆了。

**两处踩坑**（都是同一类：字段读串了）：
`ReelPlayView` **没有** `file_id`（在 `ReelSegmentView` 上），`ReelSegmentView` **没有** `ordinal`
（那是 `ReelSubtitleView` 的字幕轨序号）——我又一次把 `grep` 的邻近输出当成了同一个接口的字段。
**而且 `ReelItemView` 里根本没有季集号**，所以片段跳详情页时定位不到具体某一集，
传 `null` 让详情页自己决定，**而不是瞎传一个 0**。教训还是老的：**读模型要用精确行范围**。

**顺手修掉一个既存 bug**：媒体库首页的 `openReels()` 里写着 `this.this.openReels()`
（一个 `this` 打了两遍），而且蜂窝确认的「取消」分支原本走的是 `comingSoon('片段')`。
语法能过、但两条路径都不通——**这类「编译得过、点了没反应」的错这次是顺路撞见的，不是查出来的**。

**v1 没做**（iOS 有）：手势层（双击 ∓10 秒 / 长按 2 倍速）、暂停标记与实时加载速度、
剧照模糊铺满整页、`全屏观看` 的**片段模式**（现在只能从片段起点放整片，时间轴不是那一段）、
画质胶囊、片尾自动翻页、「全部 ⌄」类型筛选、收藏 / 已看 / 分享三个按钮
（**客户端没有切换收藏的端点，所以不做死按钮**）、导演行（人物页还没做）。

**两个已知问题**：
1. **画面是黑的**——片段流同样要转码，撞的是服务端 VAAPI 那个老问题；
2. **标签栏盖住了「全屏观看」**：iOS 规格要求片段页**隐藏底部标签栏**，
   但鸿蒙这边标签栏挂在 `MainTabsPage` 上，压栈的页面藏不掉它。
   先用 `Theme.tabBarInset` 让位；**「隐藏标签栏」是架构层面的事**，单列。

### 站点资源搜索（上一轮）——搜索页那个「建设中」的竖项解锁了

`search/TorrentResultsPage.ets`（对应 iOS `TorrentResultsView` 842 行 + 模型/逻辑 1400 行；**本轮是 v1**）。

自上而下照 iOS：**状态行**（总数 + 各站点报错）→ **排序胶囊** → **结果列表**。
行点按开操作面板：**下载** / **投给订阅** / **复制标题** / **打开站点**。

**几个照 iOS 的判断**：

- **排序在前端做**：`searchTorrents` **没有排序参数**，所以排序是本地排（做种 / 体积 / 时间）；
- **站点报错要显出来**：`sites[]` 里任何一个站返回 `error` 都要在状态行标出来，
  否则用户会奇怪「怎么少了一个站的结果」——**静默少站比报错更糟**；
- **下载要两步**：先 `dlResolveTarget` 问清「存到哪个库 / 哪个路径」，**确认对话框里把去向说清楚**，
  再 `dlSubmit`；`already_exists` 时要明说「该种子已在下载器中，未重复添加」（同 iOS 的文案）；
- **免费标记**（`free`）是站点限免，要显眼——它直接影响用户下哪个。

实测（关键词「爆水管」）：**共 180 个结果**，排序胶囊可用，
行内 `免费` 绿标 / `22.07 GB · 做种 360 · 下载 21 · HDSky · 13 小时前` 都正确。

**v1 没做**（iOS 有）：视图切换（分组 / 列表 / 图览）、条件胶囊的筛选维度（分类 / 站点多选）、
浏览图片（图览）、站点详情页、分页加载、手动选种横幅的完整流程（订阅详情页还没接进来）。

### AI 会话页（上一轮）——六块空缺里最大的一块

`agent/ChatPage.ets`（对应 iOS `Features/Agent/` 那 10 个文件里的会话视图部分）。

**关键发现：后端的 `entries` 是原始 JSON 数组**（三种 entry：`message` / `compaction` / `handoff`，
各自有自己的稳定 id），所以**要自己摊成界面行**，不是拿一个现成的消息列表。
摊法：`message` 按 `role` 分用户/AI/工具；`content` **可能是字符串、也可能是分段数组**
（`[{type:'text', text:'…'}]`）两种都要认；只有 `tool_calls` 没有正文时列工具名，
**不显示空气泡**；`compaction` / `handoff` 渲染成**居中的标记行**而不是伪装成消息
——不这样的话用户会觉得「AI 怎么突然忘了前面」。

**刷新用轮询不是 SSE**：iOS 走 `/sessions/{id}/events` 的 SSE，而**鸿蒙的 API 客户端没有流式方法**
（`ApiClient` 只有一次性 `http.request`）。所以 `running` 期间每 1.5 秒重拉整份 transcript，
停止时立刻停轮询。代价是重复传输，但**语义等价、且不需要改客户端**；
要真流式得先给 `ApiClient` 加 SSE（`http.createHttp` 的 `on('dataReceive')`）。

实测（打开一条真实会话）：用户气泡右对齐、AI 气泡左对齐、**工具结果单独一种弱化样式**
（标签 `mclaw` 用琥珀色、内容用次要色，不和 AI 的正文混在一起）；
输入区在 `running` 期间禁用并提示「等这一轮跑完…」。

**上一轮那半截链路闭合了**：「交给 AI 分析」起的会话，现在有地方读——工单面板底部加了「打开会话」。

**还没做**：新建会话、会话列表页（「我的」页的「最近会话」段）、分支/重命名/删除、
附件、`AgentSkills`（技能面板）、`AgentMediaCards`（会话里的媒体卡）。

### 活动页：全部忽略 + 最近播放（上一轮）

活动页原先只有单任务的「重试 / 忽略 / 取消」，缺 iOS 的**批量与分段**。本轮补两样：

1. **「全部忽略」**（`jobsDismissAll`）——iOS 把它放在「需要处理」的**版块头右侧**，
   并且**就地动作不带右箭头**（带箭头的才是「去下一页」）。`SectionHeader` 早就留了 `trailing` 参数，
   一直没用上，这轮接上：只在有失败任务时出现，在途显示「正在忽略…」，
   二次确认里**把条数说清楚**（"把 5 个失败任务都忽略掉？"），并说明忽略只是从这屏收起、不删任务。
2. **「最近播放」**段（`playbackHistory`）——iOS 的「历史与统计只露一小段」，这里露最近 3 条，
   一行说清「谁 · 哪台设备 · 看了多久 · 看完没」。

**对比 iOS 还差的段**：iOS 的活动页有 **需要处理 / 正在播放 / 正在下载 / 进行中 / 最近播放 /
观看统计 / 最近完成** 七段，外加各自的二级页（「查看全部」压栈）。我现在有
需要处理 / 最近播放 / 进行中 / 最近完成，**缺「正在播放」「正在下载」「观看统计」三段与全部二级页**。

**验证边界（两个新东西都没验到）**：两者都是**条件渲染**，而当前服务端上
**没有失败任务、这个账号也没有播放记录**（之前查收藏墙时也是空的），所以两段都没出现。
我没有去**制造**一条失败任务或播放记录来凑验证——那是往用户数据里写东西。
要验的话路径很明确：跑一个会失败的整理任务 / 在网页端播一下，两段就会出现。

### 「交给 AI 分析」（上一轮）

`settings/HandoffCenter.ets`（对应 iOS `ActivityHandoffButton` / Web `HandoffButton`）。

产品语义照 iOS：每条待处理事项有**两个出口**——第一个是确定性的（去处理 / 重试 / 删除），
这个按钮负责「**不知道该怎么办**」：**工单由后端带着现场自检组装（前端不拼）**，
起会话后跳到会话页；**未接入模型时整个不渲染**。

流程是**两步**（iOS 把它包成一个方法，本质也是两步）：
① `sessionHandoffPrompt({kind, ref})` → `{title, prompt}`；
② `sessionStart({content: prompt})` → `{session_id}`（工单就是会话的**首条用户消息**）。
`kind` 取值与后端一致：`notice`（ref = 告警 id）/ `download`（info_hash）/ `job`（任务 id）。

**做在哪**：待处理事项抽屉的顶栏（那一屏本来就是「需要用户行动才能推进的运行时问题」，
「交给 AI 分析」是它天然的第二出口）。可用性用 `llmModels().length > 0` 判断并缓存
——**给一个点了必然失败的按钮比不给更糟**。

实测：按钮按条件渲染出来了（说明可用性探测正确）。

**验证边界**：**没有点它**。点下去会真的起一个 AI 会话、消耗模型额度、让它跑工具——
和之前「订阅 ✓」「取消任务」是同一类真实副作用，我不擅自执行。所以只验到
「按条件渲染 + 两步链路编译通过」，**没有验到工单内容与会话建立**。

**还差最后一段**：**鸿蒙端没有 AI 会话页**（`ChatPage`），所以工单面板里明说了
「这份工单先在网页端的会话里看」——**不静默起一个用户看不到的会话**。
会话页是独立的一大块（流式消息、工具调用展示、附件），留到之后。

**规则组与入库库也补上了**。iOS 的设计要点是：**后端会路由**（按适用范围挑规则组、按收藏范围挑库），
界面要把**路由结论和理由**摊给用户，改了才藏起理由。照做：

- 预检成功后拉 `subscriptionsPreviewDownloadRouting` 拿路由结论；
- **入库媒体库**：显示选中的库；**没改过时副标题写路由的理由**，改了就不显示（同 iOS）；
- **订阅规则**：管理员才出现（`canManage`），且只在有规则组时占位；
- **投递预检**：显示「将存到 `<路径>`」；**改库就重拉**（对应 iOS 的 `.task(id:)` 依赖
  `[prepared.media, libraryId]`）；
- 提交时把 `library_id` / `rule_set_id` 带上——没改过就是路由结论，改过就是用户选的。

实测（《兰香如故》）：入库媒体库自动选中「**剧集库**」、订阅规则「自动选择」、
「将存到 `/downloads/Media/TV.Shows`」——**都是后端真实的路由结论**。

**还没做**：快捷新建规则组（`RuleSetEditorSheet`）、洗版变体（`upgrade`）。

**验证边界**：**没有真的点下 ✓**。那会在用户的服务器上真的建一条订阅并触发搜索与下载
（有实际副作用），所以只验到「弹层弹出 + 预检正确 + 确认键可用」，创建那一步没走。

### 版式对齐进度（逐页做，对照 iOS 的 View 文件）

| 页面 | 状态 | 说明 |
|---|---|---|
| 媒体库首页 | ✅ 本轮 | 见下 |
| 条目详情 | ✅ 本轮 | 见下 |
| 发现 | ✅ 本轮 | 见下 |
| 搜索 | ✅ 本轮（结构 + 行版式） | 见下 |
| 订阅 | ◐ Hero 已补（本轮）；日程条待做 | 见下 |
| 活动 | 待做 | iOS 是系统分组列表（行自带按压高亮、左滑操作） |
| 更多 | ✅ 本轮 + 新增个人信息页 | 见下 |

**更多页（本轮）**：对照 iOS `Features/Root/MorePage.swift`（iOS 设置式分组列表）。三处偏离：

1. **账号切换不该占这一页的行**。iOS 的设计是：切换走底部头像页签的长按/双击（高频），
   「我的」页只留一张**带箭头的账户卡**（点进个人信息）；能看见的兜底入口「切换账号」与
   「退出登录」一起放在**个人信息页最底部**（iOS 账户详情页惯例）。
   我上一版把账号列表和退出按钮都堆在「我的」页上。
   → 新增 `settings/ProfilePage.ets`（个人信息页）+ `profile` 路由承载它们；
   「我的」页只留账户卡（昵称/身份小字用 iOS 的 `identityLine`：昵称≠用户名才带 `@用户名`）。
2. **服务器不是可点卡片**：iOS 是「服务器设置」标题 + **下面一行小字写当前地址**（副标题写法），
   回答「这些设置改的是哪台」；我原来做成了点了会跳登录页的卡片。
3. 加导航宿主 `MoreNavHost`——「更多」页签原来没有 `Navigation`，压不了栈。

**活动页（上一轮）**：对照 iOS `ActivityView` / `ActivityDashboardRows`：

1. **版块头按 iOS 重做**：iOS 的 `ActivitySectionHeader` 是「可选 8×8 色点（需要处理用危险色）
   + 标题 + 计数（灰、等宽）+ 右侧动作（带右箭头）」；我原来只有「标题 + 计数」。
2. **行改成系统分组列表**：iOS 除「需要处理」外都用系统 `List` 的 insetGrouped 行
   （源码注释明确写了「需要处理」保留完整卡片——每种故障的补救动作不同，压成一行反而要多点一层）。
   我原来是全区自绘卡片。现在「进行中 / 最近完成」用 `List` + 行内进度条 + 分隔线，
   **左滑取消**用 `ListItem.swipeAction()`（对应 iOS 的 `swipeActions`，红底）。

踩到一个 SDK 差异：**本版本的 `List` 没有 `listStyle(ListStyleOptions.GROUPED)`**，
用「圆角底 + 边框 + 分隔线」自己做出同样的分组观感。

**订阅页（上一轮）**：补上 iOS 的沉浸 Hero（`SubsHomeHero`，高度 500、8 秒轮播）。

关键发现：**订阅 Hero 和发现 Hero 是两种版式**，iOS 源码注释里明确区分——
发现页是「编辑推荐」：**文字左对齐、指示器靠右下**；
订阅页是「时间驱动」：**片名 Logo 居中、大号细体时刻、指示器居中**。
我上一版是按发现页那套处理订阅页的，等于把两种版式做成了一种。

现在订阅页按其自身版式实现：居中 Logo（没有就写片名）、状态行（小圆点 + 「第 N 季 · 下一集 SxxExx」）、
大号时刻（今天/明天/N 天后），指示器居中。版块顺序也改成 iOS 的：
**Hero → 刚刚入库 → 日程 → 剧集订阅 → 电影订阅**（原来是「接下来」在最前）。

两处数据上的现实约束（不是偷懒，是接口没有）：
- `TodayArrivalView` **只有文字、没有任何图片字段**，所以 Hero 的剧照/Logo 取自它所属**订阅**的
  `media`（`MediaBrief` 有 backdrop/poster/logo）；
- iOS 的 Hero 时刻是「下载中 → 马上就好 / 正在整理」这类**实时状态**，需要 `SubscriptionsHomeModel`
  那套 696 行的排程模型；鸿蒙现在只用「下一集还有几天」这一个维度，够撑起版式但不含实时态。

**没做**：日程条（`SubsHomeSchedule`，日期条 + 当天议程）、订阅详情页、订阅弹层。

**搜索页（上一轮，结构）**：把上一轮留下的两条结构偏离补完：

1. **结果独立成页**：iOS 是 `.searchable` 提交后**压栈到 `SearchResultsView`**，页标题写
   `搜索“关键词”`；上一版我是就地在首页画结果。现在新增 `search/SearchResultsPage.ets` +
   `searchResults` 路由，首页只管输入与历史。
2. **换用原生 `Search` 组件**：iOS 那边是系统 `.searchable`，鸿蒙的原生对应件就是 `Search`
   （带放大镜、清除键、圆角胶囊），不再自绘 `TextInput`。

踩到两个坑：
- **`NavDestination` 的标题栏在沉浸式布局下不避让状态栏**——标题直接压在时间/电量上（截图可见）。
  与 `Navigation` 的 `menus()` 是同一类问题。结果页改成自绘顶栏（返回 + 居中标题）。
- 结果页的关键词要用在**页标题**里，所以 `keyword` / `mode` 必须是 `@Local`；
  写成普通成员时赋值不触发重绘，标题会空成 `搜索“”`（编译不报错，只能靠截图发现）。

**搜索页（上一轮，行版式）**：对照 iOS `SearchHomeView` 的 `scopeRow` / `historyButton` / `detailLine`：

1. **补上提交行**：iOS 关键词非空时顶部有一条「搜索“xxx”」行（强调色放大镜、固定宽 26 的图标列
   + 标题 + 副标题「豆瓣与 TMDB 影视条目」/「已入库的影片」），我原来只能靠软键盘回车提交。
2. **历史行重排**：iOS 是「图标列（宽 26）+ 标题 + 副标题」两行结构，副标题格式是
   `<范围> · <相对时间>[ · 快照]`（`detailLine`）；我原来是一行「关键词 + 范围标签」，信息少一半。
3. **竖向标签文案错了**：iOS 的 `scopeLabel` 对 `titles` 用的是**「影视」**，我写成了「条目」。

**还没改（下一轮）**：iOS 提交后是**压栈到独立的结果页**（`SearchResultsView`），我现在是就地展示；
另外 iOS 用系统 `.searchable` + `.searchScopes`（搜索栏 + 范围栏），鸿蒙的原生对应件是 `Search` 组件，
我现在是自绘的 `TextInput`。这两条属于「结构」而不只是「行版式」，留到下一轮一起改。

**发现页（上一轮）**：对照 iOS `DiscoverHero` + `DiscoverHeroSlide`，Hero 整块按 iOS 重排：

1. **眉行缺失**：iOS 顶部有一行 `今日精选 · 电影/剧集`（caption semibold、字距 2.5、accent2 色），我完全没做。
2. **元信息行不是拼字符串**：iOS 是 `HStack(spacing: 10)` 把「★评分 / 年份 / 类型 / 时长 / ● 在库」
   分开放，**类型用 ` / ` 连接**，末尾还有个绿点「在库」标记；我原来是自己拼的一行文本。
3. **指示器样式与位置都错了**：iOS 是**右下角**（trailing 20 / bottom 16）的「**8 秒填满**」式胶囊
   （当前格随时间填充，不是圆点跳变）；我原来用的是居中圆点。鸿蒙的 `DotIndicator` **不支持定位**，
   所以自绘了一个，并用 100ms 定时器驱动 `heroFill`。
4. **文字区留白**：iOS 是左右各 16、底部 28、**右侧额外留 60 给指示器**。
5. 补上 iOS 有的：**原名行**（caption、white 0.55）、**订阅影片键**（有订阅权限时）。
   Hero 高度 iOS 固定 520，这里按屏高六成封顶取 440（小屏不至于把内容全顶下去）。

**条目详情（上一轮）**：对照 iOS `LibraryItemDetailView` 的 `header` / `factsLine` / `playAction`，
改掉四处偏离：

1. **事实行的顺序和内容错了**：我原来写的是「★评分 · 年份 · 时长」，iOS 是
   **年份 · 时长 · ★评分 · 分辨率 · HDR**，而且分辨率/HDR 我根本没做
   （还带 iOS 那套名字映射：`2160p → 4K`、`1440p → 2K`、`4320p → 8K`，
   HDR 按「杜比视界 > HDR10+ > HDR10 > HLG > HDR」排序）。
2. **类型不该是胶囊**：iOS 是纯文本用 ` · ` 连接。
3. **动作行结构不对**：iOS 是**播放键独占一行通栏**，下面一行才是「收藏 · 标为已看」；
   我原来三颗挤一行。顺带补上 iOS 有的续播进度条 +「剩余 X 分钟」+「看过 N 次」。
4. **多了一行原名**（iOS 不显示 `original_title`），并补上 iOS 有而我没有的
   **Logo 标题**（有 `logo_url` 就用 Logo，最多 260×96）、**剧集当前集行**（「第 N 季 第 M 集 - 集名」）、
   **系列 / 合集行**（标签宽 34 + 值，合集最多列 3 个再收「还有 N 个」）。

**媒体库首页（上一轮）**：

- 行内版式本来就一致（行间距 24、行内 12、横滚 12 / 库卡 14、海报格宽 124、统计行 top 4），
  这部分核对下来**逐值相同**，没动。
- 改的是**页面级顶栏**：原来是自己画的 `Row`（固定 28px 标题），
  iOS 那边是 `.navigationTitle("媒体库")` + `.toolbarTitleDisplayMode(.inlineLarge)`
  ——**大标题，滚动时收缩成 inline**。鸿蒙的原生对应能力是
  `Navigation.titleMode(NavigationTitleMode.Free)`（不滚动 Full 高度、滚动收到 Mini）。
  已改成用 `Navigation` 的原生标题栏 + `.menus()` 放右上角动作，自绘的 `TopBar` 已删。
- 右上角动作顺序照 iOS 工具栏：**⋯ · 搜索 · 片段**（片段是主操作放最右）。
- 踩到一个坑：**沉浸式布局下 `Navigation` 会把 `menus()` 贴到最顶端、压住状态栏**
  （大标题自己会避让，menus 不会），得在 menus 的 builder 上自己补 `Theme.statusBarInset`。

### 沉浸式布局（已做）

`EntryAbility.onWindowStageCreate` 里加了 `setWindowLayoutFullScreen(true)` + 避让区读取。
之前**完全没配窗口**，底部一直有一条系统留白的黑带（用户明确要求去掉），
现在内容铺到状态栏与底部导航条下面。

代价是**系统不再替我们避让**，所以：

- `common/WindowInsets.ets` 记下开窗后读到的 `TYPE_SYSTEM` / `TYPE_NAVIGATION_INDICATOR` 高度（vp）；
- `Theme.statusBarInset` = 状态栏高度，**每页自己的顶栏都要加上它**，否则标题压到时间/电量上（实测踩过）；
  沉浸大图的页面例外：图铺到状态栏下面，但**返回键要往下挪这么多**；
- `Theme.tabBarInset` 改成 `76 + WindowInsets.bottom`（悬浮页签栏 + 小白条），
  调用点不用改（getter 顶掉了原来的 `static readonly`）。

实测：底部黑带从距底 140px 收到 40px（剩下的是悬浮栏自己 12vp 的边距 + 小白条），
顶部各页标题不再压状态栏，条目详情页的返回键落在状态栏下方、剧照仍铺到状态栏后面。

### 播放器手势层验证补遗 + 人物页（本轮，第 2 优先级完成）

**人物页**（对照 iOS `PersonDetailView` / `DiscoveredPersonView`，两条入口全通）：

- `PersonDetailPage`（媒体库内影人，路由 `person`）：`PersonHeaderCard`（带头像、原名、统计带）、
  参演/职位分区（`CreditCards`，海报 + 角色 + 集数徽带），入口来自库内条目详情的演职员行。
- `DiscoveredPersonPage`（TMDB 影人，路由 `discoveredPerson`）：发现页条目演职员行、
  Reels 导演行进入；结构与库内影人页同源，数据走 TMDB。
- 跨页签入口：`ShellChrome.openTab` 已打通，搜索人物行也能跳（见下）。

验证（模拟器）：搜索「刘德华」→ 人物行 → 影人页显示「库内 2 部 · 参演 2」（猎金游戏 饰 Todd Cheung、
长安的荔枝 饰 Yang Guozhong）。长按 2× 的运行时验证仍受 uiautomator 限制（注入触点会被 dump 打断），留待真机。

### 搜索区全量对齐（本轮）——按 iOS 架构重写

对照 `SearchHomeView.swift` / `SearchResultsView.swift` / `SearchScope.swift`，整块重构：

**架构对齐（和旧版最大的差别）**：

1. **媒体库模式不再压结果页**：iOS 是**页内实时结果**（敲字 300ms 防抖，回车只收键盘），
   旧鸿蒙版是回车压栈 —— 已改成 `SearchPage` 内嵌 `LibrarySearchResults(live: true)`，
   顺带解掉了之前「模拟器输入法回车不触发 `onSubmit`」导致媒体库搜索 E2E 走不通的死结。
2. **结果页只挂两个垂直**：`SearchResultsPage` 顶栏换成**关键词胶囊**（点它把词回传搜索页改词重搜，
   对应 iOS `keywordCapsule → router.editSearch`，草稿走 `AppStorage` 的 `mc_search_draft`），
   下面是「媒体库 | 影视」分段；**资源**仍是独立压栈页（torrent 专项对齐留到下一轮）。
3. **切换保活**：iOS 用 `ZStack` + opacity 切垂直、切走不卸载；鸿蒙对应件是
   `Stack` + `.visibility(Visible/None)`，加 visited 标记做惰性挂载（第一次切到才请求）。
   注意 **`@Builder` 调用不能链属性**，所以影视分区抽成了独立组件 `MediaSearchResultsView`。
4. **权限裁剪**（`SearchAccess.ets`，对齐 iOS `SearchAccess.resolve`）：影视=`canSubscribe`、
   资源=`canSearch`、媒体库=管理员恒开/成员有可见库即可；模式 chips 只在 >1 个可用时显示。

**历史对齐**：按 vertical 查询（`GET /search/history?vertical=`，库模式**完全不显示历史**，旧版全显示是错的）；
客户端按关键词 trim+lower 分组；行文案 `<范围> · <相对时间>[ · 快照]`；点带快照的行**回放服务端快照**
（`GET /search/history/{id}/results`），结果页横幅「N 前的快照 · 重新搜索」，快照 404 回退实时搜索；
左滑删单条/整组、按 vertical 清空，均带确认。输入词会过滤历史组（iOS 同款）。

**媒体库实时结果**（`LibrarySearchResults.ets`，搜索页/结果页共用）：联想胶囊（只列片名、去重、
带命中原因但「名称匹配」不显示）→ 人物横滚行（72 头像 → `person` 路由）→ 两列海报墙
（命中原因注脚 + 季集/分辨率 footnote）→ 滚动到底自动续页（游标 + `media_item_id` 去重）；
换词不清旧结果（不闪骨架屏），代次号丢弃过期响应。

**验证（模拟器，布局 dump）**：媒体库实时搜索（联想「猎金游戏/长安的荔枝 · 演员：刘德华」、人物行、影片墙）
→ 人物页 → 返回；影视提交行 → 结果页（豆瓣 10 条 + TMDB 分区）；历史分组 + 清空入口；
快照回放（山海经：横幅 + TMDB 27 条）→ 重新搜索（实时豆瓣 10 条）；胶囊 → 搜索页带词返回；
结果页切媒体库垂直（山海经密码 · 2025 · 2160p）。全部通过。

**顺手修的**：`Models.ets` 里 `TitleSearchHistoryResultsView` 重复定义（声明合并禁令）合并成一份，
`items` 从 `Record<string, JsonValue>[]` 改成 `DiscoveredTitleView[]`；发现死端点
`searchLibraryItems` 换成真的 `GET /search/library`（后端不记历史，与 iOS 假设一致）。

**工具链备忘**：模拟器两侧缘滑动手势会唤出 GestureDock（不是返回），
返回要用 `hdc shell "uitest uiInput keyEvent Back"`；API 前缀是 `/api/v1`。

### 活动二级页（本轮，第 3 优先级完成）——活动页收进 NavHost，三个「查看全部」落地

对照 iOS `ActivityPages.swift`（`ActivityTasksPage/ActivityPlaysPage/ActivityStatsPage` 三个 push 页）：

**架构**：活动 tab 换成 `ActivityNavHost`（同 LibraryNavHost 模式）——`Navigation(navStack){ ActivityPage }`，
`hideTitleBar(true)`、Stack 模式；`ActivityPage` 根从 `NavDestination` 改回 `Column`（它现在是 Navigation
的首页内容，不是被推的目的地）。四个「查看全部」入口：进行中（有活跃任务才出现）/ 最近播放 / 观看统计
（header 行 + StatsCard 本体都可点）/ 最近完成（`查看全部 65 个` 带总数）。
路由注册在 `router_map.json`（`activityTasks/activityPlays/activityStats`，字段名是 `buildFunction`）。

**进行中/已结束页**（`ActivityTasksPage.ets`，`ActivityTasksParams{mode}` 带 `.of()` 兜底）：
进行中 = `jobsList(activeOnly=true, limit=200)` **客户端再过滤 running+queued**（后端 activeOnly
会连已成功的一起返回，实测 20 条里 0 条在跑）；已结束 = `jobsList(limit=100)` 按 `finished_at??created_at`
倒序、按天分组（今天早些时候/昨天/N月N日）。行 = 库·任务名·状态徽标·相对时间；滑动操作沿用活动页
`swipeAction({end})` 模式（取消带 AlertDialog 确认 / 撤销忽略限 failed+dismissed / 重新执行限
非 system 取消）。列表数据在 `load()` 里更新 `JobListDataSource`（不能在 build 里动），
`sameAs(id,revision)` 防重复 `onDataReloaded`。`onShown` 重载。

**最近播放页**（`ActivityPlaysPage.ets`）：`playbackHistory(30, before 游标, memberId?, scope)` 代次防错乱；
滚动到底哨兵 `ListItem` 续页（`has_more`/`next_cursor`），取完显示「已经到最早的记录了」；按天分组带
`${count} 场`；行 = 时刻 + 28×42 海报 + `SxxEyy` + 成员·设备 + 状态（播放中/看完✓/看到N%/播放过）+ 看了N分钟；
行可点（`browsable && library_id>0` → `libraryItem`）。右上筛选 `bindMenu`：成员（全部成员/超级管理员/
`membersList` 成员）+ 浏览范围（我的浏览范围=`visible` / 全部含隐藏库=`all`），切完清空重拉。

**观看统计页**（`ActivityStatsPage.ets`）：`playbackStatsWatch(days, tzOffset=-getTimezoneOffset(), …)`
（后端要分钟数，东八区 480）。周期 chips 7/30/90；2×2 指标卡（观看时长/播放场次/看完率/活跃成员，
`previous_available` 时带 ↑绿↓红 环比）；最受欢迎 TOP3（排名徽标 蝉联/上期第n/新上榜 按
`previous_favorites` id 对照，**排序直传后端**——后端按「看过成员数>时长>场次」排，猎金游戏 2 人 0 分钟
排第一是对的，别在客户端按时长重排）；趋势图 `days<60` 按天、否则按周分桶，本期实色 + 上期 30% 透明度
Stack 底对齐，标签每 `⌈total/8⌉` 个露一个；按成员/按客户端/看得最多（前 5 + 展开全部）/按播放方式
（by_tier 场次）；热力图 7×24（rgba(127,176,255, 0.15+0.85*ms/max)，行 0 = 周一）。空态带
「看全部成员 / 看最近90天」快捷 chips。

**验证（模拟器，布局 dump）**：活动页四区块 + 计数；最近播放页（分组/行/看完✓/分页到底/筛选菜单
成员 3 项+范围 2 项/切「全部含隐藏库」chip 更新且重拉/点行进条目详情）；观看统计页（7→90 天切换、
指标卡环比、TOP3 徽标、趋势图本期上期、四张分布卡、热力图标题）；已结束页（昨天 17 个分组、完成徽标）。
全部通过。**进行中页**因无长任务未走到活体（触发整库扫描几秒就完成）；与已结束页同组件同路由，仅
过滤条件不同，按对称性验收。滑动操作 uitest 注入不了 `swipeAction`（已知限制），沿用活动页已验模式。

**坑**：
- `@ComponentV2` 的普通成员不能由父组件初始化——`ActivityPage` 的 `navStack` 必须 `@Require @Param`。
- `FontWeight.Black` 不存在（只有 Bold/Bolder）；`sys.symbol.chart/line_3_horizontal_decrease/chart_bar`
  都不是有效符号，验证方法是 grep SDK 的 `sysResource.js`（`chart1/chart2` 只是文字大小属性的名字）。
- 模拟器注入输入偶发坐标抖动：两次「莫名切回媒体库 tab / 落到我的 tab」，同序列复现不出，
  静置 30s + 受控滑动均稳定，进程 PID 全程未变——是 uitest/HdsTabs 动画竞态，不是代码问题。
  排查思路记录：先 `ps` 确认进程没重启，再无输入静置观察，再原序列复现。
- 活动页区块会随 SSE 实时增删位移，dump 出的坐标要**同一条命令链里立即用**，隔一条命令就可能漂 200px 点错卡片。

### 第 6X 轮：分享查看页（访客侧，对齐 iOS SharePageView/ShareItemView）

**深链入口**（`common/ShareLinks.ets` + `EntryAbility`）：`onCreate`/`onNewWant` 里
`slugFromWantUri(want.uri)`（解析 `/s/{slug}`，兜底 `parameters['shareSlug']`，方便 `aa start --ps`）→
`ShareRouter.shared().handOff(slug)`（`@ObservedV2` + `@Trace pendingSlug` 单例中转）。消费方两条路：
冷启动由**首个建起来的页签**在 `aboutToAppear` 里 `NavStacks.register(key, stack)` 后
`takePending()` 接走（只有可见页签会构建，≈当前页签）；运行中再点链接由 `MainTabsPage` 的
`@Monitor('shareRouter.pendingSlug')` 接走，push 到 `NavStacks.of(NavStacks.currentKey)`——
`currentKey` 在 `aboutToAppear` 置「媒体库」、`.onChange` 随页签更新。`takePending()` 原子清零
（UI 单线程），不会重复消费。五个 NavHost（媒体库/发现/订阅/活动/我的）都注册了。

**访客页**（`share/SharePage.ets`，路由表 `sharePage`）：探针 `shareProbe` → 四态机
loading/locked/unavailable/collection/item。`requires_password && !unlocked` → `ShareGate`
（MOVIECLAW 字标 + 需要密码 + 密码框 + 打开，错误横幅「密码不对，请重新输入」；
`shareUnlock` 成功后服务端 Set-Cookie）。404（SHARE_NOT_FOUND/SHARE_EXPIRED）→
「分享不存在或已取消 / 请向分享者确认链接是否仍然有效。」；网络 0 →「无法连接到服务器…」。
合集分享 → `CollectionView`（名称 + `N 部` + 海报网格，列数按屏宽算 `n*104+(n-1)*12≤avail`，
沿用 LibraryCollectionsGrid 的手工分行模式）；点格子进 `ShareItemView`（带 `fromCollection`，
顶栏出现「返回合集」）。条目分享 → 直接 `ShareItemView`。

**访客条目页**（`share/ShareItemView.ets`，~850 行，照抄 iOS ShareItemView）：
顶栏（返回 + 返回合集 + MOVIECLAW + `链接 {shareExpiryHint}`：N 天/小时/分钟后失效、已失效）；
剧照铺底（backdrop ?? poster）+ 三段渐变压到 #07080C；标题区（28 号标题、剧集副标题、
年份·片长·分辨率·HDR、类型、`容器·编码·体积`，单文件不显「共 N 个版本」）；音轨字幕
（语言分组 chips `中文 ×2`/`英语 AAC` + 「全部轨道」展开行内列表，AUDIO_CODEC_LABELS 全套）；
播放块（播放/继续观看 + 看到 hh:mm:ss，无文件「暂时没有可播放的文件。」）；简介 4 行展开；
剧集块（多季 `bindMenu` 菜单、「在库 X/Y 集」、16:9 剧照卡、「缺」角标、未入库 0.45 透明度、
选中 2px 描边、默认选第一个有文件的季）；章节块（章节卡点按直接 `playFrom(frame_ms ?? start_ms)`，
iOS 的剧照灯箱本轮不做）；演职员（导演卡 + 演员表，无链接）；相关链接（TMDB/IMDb/豆瓣 ↗）。

**Cookie**（`ApiClient`）：静态 `cookies` 罐（`StoredCookie{origin,name,value,path}`），
`perform()` 每次请求按 origin+path 前缀匹配拼 `Cookie` 头、响应后抓 `set-cookie`（string 或 array）；
`RemoteImage.download()` 同样带上——**密码分享的封面/剧照也要 cookie**，漏了会全部裂图。

**分享播放**（`PlayerPage`）：`PlayerParams` 加第 6 参 `shareSlug`；negotiate 走
`sharePlaybackSessionStart(slug, body)`；进度 10 秒上报在分享态**只写本地**（`ShareLocalProgress`
preferences，key `progress.{slug}.{itemId}.{season}x{episode}`）+ `sharePlaybackProgress`
（活动页实时会话用），不打 `playbackMetricReport`；退出时 `sharePlaybackSessionStop`。

**主人侧顺手对齐**（`ShareSheet`）：有效期只留 1/3/7/30 天（后端 schema 就这四档，「永久」是错的）；
已有卡片改 iOS 结构——链接/密码两行各带复制键（密码带锁标）+「复制链接和密码」
（`shareCopyText`：《标题》 链接：… 密码：…，粘进聊天框直接可用）+「取消分享」。

**验证（模拟器，布局 dump）**：冷启动 `-U http://…/s/{slug}` 直达；无密码分享直接进条目页
（过期提示/规格/轨道/演职员/相关链接全渲染）；点播放进播放器（分享协商，失败态如实展示服务端
报错）；温启动 `aa start -U` 再点链接（onNewWant → @Monitor 推栈）；取消分享后旧链接 →
「分享不存在或已取消」；带密码分享 → 门禁页 → 错密码报「密码不对，请重新输入」→ 对密码解锁进
条目页（cookie 生效）；主人侧建带密码分享（面板出现密码行+锁标）→ 取消分享。两条测试分享已全部撤销。
**合集访客页未实测**：主人侧合集分享入口在合集详情的 ⋯ 管理菜单里（本轮标注「先不做」），
没有入口就造不出合集分享；视图代码与条目页共用同一探针/门禁机制，待下轮补 ⋯ 菜单后一并验。

**后端 bug（上报，不在本仓修）**：`POST /api/v1/share/{slug}/playback/sessions` 在
192.168.50.4:13000 上必 500（curl 模拟 web 播放器同样复现，`client: "web"` + device_id 也 500）；
同参数 `/playback/decide` 正常（tier 3 转码），`/playback/progress` 正常——崩点在会话路由
decide 之后的段，分享访客 principal（member_id=-1）。**iOS 的分享播放走同一端点，同样受影响**，
需要服务端排查。客户端已把 500 如实展示在播放器失败态。

**坑**：
- `FontWeight.SemiBold` 不存在（Normal/Regular/Medium/Bold/Bolder/Lighter/Light）——用 Medium。
- `SymbolGlyph` 没有 `.textAlign()`；固定尺寸圆形底要让图标居中，得包一层 `Stack()`（默认居中）。
- 通用渐变属性是 `.linearGradient({...})`，不是 `.backgroundGradient`。
- `@Builder` 方法调用返回 void，不能链属性——要包 `Column() { this.Xxx() }` 再 `.padding()`。
- `TextInput` 的 `uitest uiInput inputText` 是**追加**不是替换，连续两次输入会串成 `99991234`；
  清空只能重启页面。keyEvent 67 也不是退格。测密码门禁：杀进程重开（字段清零）再一次性输入。
- 4K HEVC 条目（功夫女足）分享播放因上述后端 500 没法走到解码；本地进度（ShareLocalProgress）
  的「继续观看/看到 hh:mm」展示随之未活体验证，代码路径与普通播放共用。

### 第 6Y 轮：合集详情 ⋯ 管理菜单（对齐 iOS `CollectionDetailView.menu`）

**范围**：补齐合集详情页的 ⋯ 管理菜单——改名 / 分享… / 改条件… / 整理顺序… /
显示在首页（从首页移除）/ 恢复显示 / 隐藏这个合集 / 删除合集。这是上一轮留言的
「主人侧合集分享入口」，也是合集访客页 E2E 的前置。

**改动**：
- `library/CollectionDetailPage.ets`：顶栏改为自绘（返回 + 名称 + `sys.symbol.more` 的 ⋯），
  ⋯ 用 `bindMenu` 挂 `ActionsMenu()`；新增改名弹层、分享弹层（复用 `SharePanel`）、
  整理顺序弹层（上移/下移/✕ 移出 + 保存）、条件编辑器（复用 `LibraryFilterBar`，取消/保存条件）。
- 权限口径逐条对齐 iOS：`manageable` 才给改名/隐藏/删除（超管或成员自建）、
  `Permissions.canManageLibraries`（= admin）才给分享、改条件限「本库视图 + editable + 规则驱动」、
  整理顺序限「editable + 名单驱动」、隐藏 vs 删除按 `kind === 'user'` 分流。
- 首页开关复用自定义页那份偏好：`LibraryHomePrefs` + `PUT /ui/preferences`（整体覆盖，
  其余偏好原样带回），新行 id 用 `row:` + 6 位 base36（同 iOS `HomeRows.newRowId`）。
- `library/ShareSheet.ets`：`SharePanel` 加一个 `intro` 文案入参，合集分享传整册的说法
  （同 iOS 一个分享弹层两种目标）。
- `library/LibraryCustomizeSheet.ets`：导出 `HomePrefsInput` 供合集页拼整份偏好体。

**本页状态模型降级为 V1（`@Component` + `@State`）**：`LibraryFilterBar`、`SharePanel`
都是 V1 `@Component`，两个已验证的宿主（`LibraryDetailPage` / `LibraryItemDetailPage`）也都是 V1；
V2 宿主内嵌 V1 子组件本项目还没有先例，为免踩混合观测的坑，直接跟兄弟页保持一致。

**顺带修掉一个真 bug（影响面很大）**：合集页默认档（自定顺序）原来把空串当排序参数发出去
（`sort=`），后端当成未知排序字段 → **名单返回空**——任何规则驱动 / 名单驱动的合集
（HDR、手建合集）都是「N 部」却一面墙全空，系列合集因为默认档解析成了 `release_date` 才幸免。
改为默认档**不传** `sort`（同 iOS 传 nil）。修复后 HDR(33 部)、手建合集(45 部) 一面墙正常渲染。

**实测（模拟器 127.0.0.1:5555）**：
- HDR（规则驱动、自建）：⋯ 菜单 = 改名/分享…/改条件…/显示在首页/删除合集（无「整理顺序」✓）；
- 用筛选「年代 2020s」+「固定这批」建了个一次性合集（45 部，名单驱动）：
  菜单 = 改名/分享…/整理顺序…/显示在首页/删除合集（无「改条件」✓）；
- 分享…：建链接 → 链接/访问次数/创建于/有效期至/复制链接/取消分享 → 取消分享二次确认后回到建单表
  （`shareView = null` 时面板确实切回创建态）；显示在首页 → 菜单变「从首页移除」，
  重进页面（重新 GET 偏好）仍是「从首页移除」→ 确实落库，再点回来复原；
- 改名：弹层预填、保存后顶栏与页头同步改名，再改回原名（`inputText` 追加 + `keyEvent 2055` 删尾字符）；
- 整理顺序：下移一行 → 保存 → 墙上顺序确实换位；✕ 移出 → 合集「N 部」实时变 N-1；
- 删除合集：二次确认文案（「只删掉这层视图，里面的影片一部都不会少」）→ 删除 → 返回列表，刷新后
  20 个合集且测试合集消失。测试数据已清理干净。

**坑（新增）**：
- `uitest uiInput keyEvent 2055` = 退格（OpenHarmony `KEYCODE_DEL`），`keyEvent 2` = 返回；
  之前记的「keyEvent 67 不是退格」中的正确值是 2055，清空输入框可以tap末尾后连按 2055。
- 弹层里 `TextInput` 聚焦后软键盘会顶起弹层，**遮住下方的按钮**；先 `keyEvent 2` 收键盘再点按钮。
- `SheetSize.FIT_CONTENT` 可用（弹层贴内容高度）。
- 全部合集页的**列表 body 会在删除后短暂陈旧**（表头计数已刷新）；退出重进即正确，属该页既有行为，
  与本次改动无关，未在本次修。

**合集访客页 E2E（补上第 6X 轮欠的那笔）**：HDR 合集（33 部）建 7 天链接 →
`aa start -a EntryAbility -b com.example.movie_claw -U 'https://mc.dongshu.fun:99/s/<slug>'` 冷启 →
免登录直接进合集名 + 「33 部」+ 三列海报网格 → 点一格切到那一部的影片页（顶栏「返回合集 / MOVIECLAW /
链接 7 天后失效」，海报/规格/音轨/字幕/播放/简介/演职员俱在）→「返回合集」回到网格 →
主人侧再进合集 ⋯ → 分享… 读到同一条链接（跨重启还在）→ 取消分享（二次确认）→ 面板回建单态 →
再用同 slug 冷启 → 「分享不存在或已取消」。测试分享已撤销。
`aa start -U` 之所以可用：显式指定 ability（`-a EntryAbility -b <bundle>`）时 URI 直接进 want.uri，
不依赖 module.json5 的 skills 过滤器（本项目只登记了 home skill）。

### 第 6Z 轮：更换图片（`ArtworkPickerSheet`）

**范围**：条目详情 ⋯ 菜单里的「更换图片…」（对齐 iOS `ArtworkPickerSheet.swift` / Web
`artwork-picker-dialog`，设计 docs/design/metadata.md 6.3）——背景 / 海报两页签、
候选网格、「当前」徽标、加锁横幅 + 恢复自动选图、点选即落盘并回调重载。

**改动**：
- 新文件 `library/ArtworkPickerSheet.ets`（V1 `@Component`，宿主是 V1 的条目详情页）：
  - 页签分段控件；候选按列切行（海报 3 列 / 背景 1 列，口径同 iOS adaptive 最小宽 116 / 220）；
  - 「当前」按后端 `current_poster` / `current_backdrop` 比对（**不用列表第一张推断**，同 iOS 注释）；
  - 背景页给无语言候选标「无文字」；小字 caption 尺寸 + 语言；
  - 应用时该格盖 loading、其余格降透明度，禁用重复点击；保存失败挂在网格上方（不清网格）；
  - 加锁横幅的「恢复自动选图」= `file_path: null` 解锁；
  - 候选图地址走 `ImageUrls.resolve`（TMDB 远程图 → 后端 `/images/proxy`）。
- `library/LibraryItemDetailPage.ets`：菜单加「更换图片…」（门禁 `detail.source === 'tmdb'`，
  对齐 iOS `let scraped = detail.source == "tmdb"`）；`bindSheet` 挂在内容 `Stack` 上
  （分享弹层已挂在 `NavDestination`，避免一个节点两个 sheet 互相覆盖）。

**实测（模拟器，剧集条目「杀，为了活着」S01E01）**：⋯ 菜单出现「更换图片…」→ 弹层「背景」页
1 列候选（首格「当前」+「无文字」，caption 1920×1080 / 3840×2160）→ 切「海报」3 列
（2000×3000 · zh 首格带「当前」）→ 点第 2 张 → 「当前」徽标移到该格、加锁横幅出现
（「当前海报由你手动选定，刷新元数据不会覆盖」+「恢复自动选图」）→ 点「恢复自动选图」→ 横幅消失、
解锁。**测试后已把海报改回原图**（再选回第一张 2000×3000 再解锁），条目图片与加锁状态回到原样。

**观察（不是本次引入）**：这张条目页的头部「标为已看 / 已看完」在**首次渲染**时与剧集行的「已看」
自相矛盾（S01E01 已看、头部却写「标为已看」）；选图触发的 `reload()` 后头部变成「已看完」，
但**冷启重进又回到「标为已看」**——说明是首屏 `watched` 快照陈旧，不是数据被改。未深究（超本轮范围）。

### 第 7A 轮：转移向导（`TransferItemSheet`）

**范围**：条目详情 ⋯ 菜单的「转移到其他库…」（对齐 iOS `TransferItemSheet.swift` / Web
`TransferDialog` + `TransferPlanPreview` + `TransferResult`）。此前这里只弹一句
「转移条目的向导还没做」。

**改动**：
- 新文件 `library/TransferItemSheet.ets`（V1 `@Component`）：选目标库 → 选中即只读预检
  `GET …/items/{id}/transfer-preview` → 确认转移 `POST …/items/{id}/transfers` →
  每 1s 轮询 `GET /libraries/{id}/item-transfer-status` 直到结论页。
  - 目标库口径与后端 `assert_transferable` 一致：**比的是「库」的来源**，不是条目的来源；
    候选 = 同 kind + 同 source + 非当前库（`libraryList(kind, 'all')` 后按 `source` 过滤）；
  - 文案按库能力分叉：`capabilities.scraped === false` 的库讲「这个条目的文件（连同 NFO/字幕）」，
    否则讲「磁盘上的整个条目目录」——照抄影视库的说法会让一文件一条目的库用户误解；
  - 预览三块：`blocked`（红）不给执行、`cross_device`（黄，讲硬链接断开与占用翻倍）、
    `moves`（源 → 目标，等宽字体）+ `skips`（跳过原因）+ 「N 个路径 · 体积 · M 个缺失记录随迁」；
  - 结论页：`moved_paths` / `errors` / 「已随迁 N 条库存记录（体积），清理空目录 K 个」，订阅改挂时补一句；
  - 进行中不给「取消」（弹层不可下滑关闭），底栏只留进度；轮询用 `setInterval` + `aboutToDisappear` 清理
    （刻意不用前后台暂停的轮询——用户正盯着这几十秒）。
- `library/LibraryItemDetailPage.ets`：`转移到其他库…` 打开弹层（替换原来的 toast 占位），
  `bindSheet` 挂在顶栏 `Row` 上（分享挂 `NavDestination`、换图挂内容 `Stack`，三个 sheet 三个锚点）。

**实测（模拟器）**：⋯ → 转移到其他库… → 弹层顶栏「转移到其他媒体库 / 取消」、
「把「光阴之外」转移到其他媒体库」、影视库口径的整目录说明、「转 移 到」、
**空态**「没有其他剧集库可选——请先在「媒体库」页新建一个，再回来转移。」（该服务器每类只有一个库）。

**未实测**：**预检与执行**——本环境「电影 / 剧集」各只有一个库，选不出目标库，`transfer-preview`
与 `transfers` 都走不到。执行会真的搬磁盘目录（并与做种目录解硬链接），**不在验证阶段触发**。
同 iOS 轮次的做法：破坏性动作只验到「入口 + 只读预检的入口条件」，执行留给用户真需要时。

### 第 7B 轮：扫码登录（Scan Kit，补上第 5X 轮欠的「扫码」）

**范围**：设备批准页的**扫码入口**（对齐 iOS `PairingScannerScreen` + `PairingQRCode`）。
此前这里只写了「扫码登录鸿蒙端还没做（要接相机与码识别）」。

**为什么用 Scan Kit 而不是自己接相机**：`scanBarcode.startScanForResult` 用的是**系统扫码界面**——
取景、对焦、识别、权限都由扫码服务负责，应用**不必声明相机权限**、也不必自绘取景框
（iOS 那 239 行自绘取景框是为了在 App 内联体验；鸿蒙这里换成系统 UI 更稳，且同样的数据更少）。
`@kit.ScanKit` 在本地 SDK 有 d.ts（`startScanForResult(context, options?)` → `Promise<ScanResult>`），
`scanTypes: [scanCore.ScanType.QR_CODE]` 只扫二维码。

**改动**：
- 新文件 `common/PairingCode.ets`：`PairingScan.parse/normalize`，逐条对齐 iOS `PairingQRCode.swift`
  ——认 `/activate?code=`、旧版 `/settings/devices?code=`、以及带 `MCLW` 前缀的纯码；
  **裸的四位码扫码时不认**（手输才认）；正文必须恰好 4 位字母数字；地址用字符串手工拆
  （同 `ShareLinks.slugFromWantUri`），不引 `@ohos.url`。
- `settings/DeviceApprovalPage.ets`：表单顶部加「扫描二维码」主按钮 + 「或手动输入配对码」分隔，
  扫到码 → 填进输入框 → 走既有的 `lookup()`（**不自动批准**，人还是要在卡片上看过再按，同 iOS）；
  扫到非登录码 → 「这不是 MovieClaw 的登录二维码，换一张试试」；
  用户自己在扫码界面点取消（`BusinessError 1000500002`）→ **什么都不提示**（别把「取消」写成「失败」）；
  其它错误（模拟器/无扫码服务）→ 「这台设备上用不了相机扫码，请改为手动输入配对码」。
- 新文件 `entry/src/test/PairingCode.test.ets`：5 个用例（activate 地址、旧版路径、纯码、别的二维码一律不认、
  normalize 的四种形态）；`List.test.ets` 里注册。**这是扫码的第一道闸**：解析错了会把用户带去
  批准陌生设备的页面（钓鱼面），所以用例都围绕「只认这几种」写。

**实测（模拟器）**：
- 单元测试 `hvigorw test` 通过（覆盖报告里 `PairingScan.parse/queryValue/normalize` 均有覆盖）。
  第一版用例把「`code=ab12-cd34`（8 位无 MCLW 前缀）也能认」写成了期望——**跑出来是红的**，
  回头核对 iOS 才确认实现是对的、用例是错的：8 位无前缀正文一律拒绝，已改正并补了这条断言。
- 真机侧：设置 → 设备 → 批准新设备登录 → 点「扫描二维码」→ **系统扫码界面确实起来了**
  （首启弹「安全访问相机」告知页、标题「扫描二维码」、底部有「图库」入口）→ 关掉扫码页 → Picker
  以「用户取消」返回，**页面上不出现任何提示**，输入框与按钮都还在 → 手输 `AB12CD34` → 后端原话
  「配对请求不存在或已过期，请让设备重新发起」（手输链路无回归）。

**未实测**：**真正扫到一张 MovieClaw 登录二维码**——模拟器相册是空的、`/storage/media/...` 无写权限
（非 root），没法把生成的二维码图片塞进图库喂给「图库」入口；真机对着电视扫码才是这条链路的完整闭环。
解析逻辑由上面的单测兜住。

**仍未做**（明确留白）：「我的」页右上角的扫码入口、站内链接 `/activate?code=…` 的深链。

### 第 7C 轮：批准设备登录改成**华为原生弹窗**（`openCustomDialog`）

**起因（用户要求）**：iOS 的「批准设备登录」是**弹层**（全屏 cover + 底部卡片），鸿蒙这边原来是
push 出来的整页，形态不对；随后用户又明确要求**用华为原生的弹窗**实现（不要自绘的全屏浮层）。

**最终做法（原生自定义弹窗）**：
- 宿主 `settings/SettingsSectionPage.ets` 调
  `this.getUIContext().getPromptAction().openCustomDialog(options)`：
  - `builder` 指向 `@Builder ApprovalCard()`（V2 里用箭头函数包一层）；
  - `alignment: DialogAlignment.Bottom`（卡片贴底）；
  - `keyboardAvoidMode: KeyboardAvoidMode.DEFAULT` —— **输入法避让交给系统**；
  - `autoCancel: true` + `maskColor` + `backgroundColor` + `cornerRadius`：遮罩、圆角、底色都是系统弹窗的；
  - 系统返回的 `dialogId` 存下来，卡片里的「取消 / 完成」回调 `closeCustomDialog(dialogId)`。
- 新 `settings/DeviceApprovalDialog.ets`（V1 `@Component`，取代 `DeviceApprovalPage.ets` /
  中间的 `DeviceApprovalSheet.ets`）**只画卡片内容**：标题 + 说明、配对码输入（大号等宽）、
  「继续」+「扫描二维码」+「取消」、审批卡（设备图标 / 名称 / 平台、大号配对码 +「先核对与设备屏幕上
  显示的配对码完全一致」、「将获得…」、来源 IP、批准登录 / 拒绝 / 取消）、结果卡（完成）。
  不再自绘星空底、不再自带关闭圆钮、不再自己算键盘高度。
- 新 `common/DeviceText.ets`：`clientType` / `grant` / `symbol`，文案照抄 iOS `DeviceText`
  （本地符号库没有 terminal / tv，就近取 `computer` / `media_center`）。
- `router_map.json` 里的 `deviceApproval` 路由与旧页面文件删除（不再是页面）。

**输入法避让：三条弯路（记下来别再走）**
1. `bindContentCover` + 自己听 `keyboardHeightChange` 补 padding → **完全不生效**（contentCover
   分层里改状态推不动布局）；
2. `bindSheet` 靠框架避让 → 只顶上去一部分（实测卡片只抬 405px，仍被键盘盖住），
   自己按「卡片底边 − 键盘顶边」补 `translate` 能成，但要读 `getWindowAvoidArea(TYPE_KEYBOARD)`、
   还要用卡片自己的 `onAreaChange` 当基准（用弹层根节点会多顶 460px）——**能跑但麻烦**；
3. **最终**：原生弹窗的 `keyboardAvoidMode` 一句话搞定——键盘弹起时弹窗**整体收缩到键盘之上**。

**实测（模拟器）**：
- 打开：出现系统 `Dialog` 节点（贴底、带遮罩），卡片内容齐全；
- 输入框聚焦：**弹窗自动收缩到键盘之上**（Dialog 底边 1757 = 键盘顶边，正好贴着，没有任何空隙差）；
- 输入非法码 → 卡片内提示形如 `MCLW-7F3K`；改成一个有效码 → 审批卡渲染；
- **审批卡渲染正确**：恰好用户在 Mac 上发起了配对，弹窗里出现真实请求
  「DS Mac mini · macOS 26.6.2 · Mac16,10」+ `MCLW-XXXX` 大号配对码 +
  「将获得：这台 Mac 以你的超级管理员身份登录」+「来源 192.168.50.2」+ 批准登录 / 拒绝 / 取消。
  **这是真人的登录请求，本轮只验到渲染，没有点批准或拒绝**（多次出现的新请求也原样留着）；
- 「取消」→ 弹窗关闭（`closeCustomDialog` 生效）。

**配对码输入改成格子（用户要求，偏离 iOS/Web 的单输入框）**
- **8 个字符位全拆** + 中间一个固定的 `-`：九格里八个可输（`MCLW` 也要照设备敲，不是预置的）；
  字母**一律转大写**，数字原样（`ab12cd34` → 格子显示 `AB12CD34`）。
- 实现：上面铺一个 **0.01 透明度的真 `TextInput`** 收键盘（`maxLength(8)` + 只留字母数字 + 转大写），
  格子只负责显示。**不要用四个 `TextInput` 拼**：中文输入法会先出候选词，一格一字符的焦点跳转
  在这种输入法下很难做稳；透明输入框退格、粘贴、英文键盘都还是系统行为。
- **坑**：
  1. `opacity(0)` 的输入框在部分版本上不参与命中，点上去拿不到焦点 → 用 `opacity(0.01)`；
  2. **`@Builder` 方法按值传参会把值冻住**：格子写成 `@Builder CodeCell(ch, …)` 时，父组件状态变了
     格子也不刷新（实测：输入框里明明有 `AB12`，格子一直空）→ 必须做成独立的 `@Component` 用 `@Prop` 收参；
  3. `ForEach` 按 key 缓存条目、键不变就不重建，键若只含下标同样不会刷新 → 九格干脆**写死不循环**。
- **「继续」点不动的 bug（用户报）**：拆格子后判据还写着 `this.code`（那是扫码/深链才赋值的整串码），
  手输时它一直是空串 → 按钮看着灰、点了也被拦。改成按 `this.chars` 判（有字符即可点；
  不满八位时 `lookup()` 会就地提示「配对码形如 MCLW-7F3K…」）。

**批准 / 拒绝一按到底（用户要求）**
- 去掉「批准前再确认」那一层 `showAlertDialog`（用户：点了批准还要再弹一个窗，不是我想要的）；
  也去掉审批卡里的「取消」（上一个版本留下的）。
- 现在：按「批准登录」→ 直接进结果卡「已批准」；按「拒绝」→ 直接进「已拒绝」（同 iOS `resultContent`）。

**事故记录（诚实留档）**：验证期间用户正在 Mac 上发起配对，一次点「继续」前的落点判断失误，
**误触了审批卡的「拒绝」**，把那条真实请求拒掉了（结果卡显示「已拒绝 · 这台设备不会登录（DS Mac mini）」）。
按卡片自己的文案，重新发起配对即可。此后验证一律先 dump 坐标、并在没有待批请求的状态下做。

### 第 7D 轮：长按头像页签的「切换账号」也改用华为原生弹窗

**改动**（同 7C 的手法，用户要求）：
- `pages/MainTabsPage.ets`：长按「我的」页签（0.45s，`LongPressGesture`）不再 `bindSheet`，
  改为 `getUIContext().getPromptAction().openCustomDialog({ builder, height, width, alignment: Bottom,
  keyboardAvoidMode, autoCancel, maskColor, backgroundColor, cornerRadius })`；`dialogId` 存下来，
  卡片里的「关闭」回调 `closeCustomDialog`。
- 高度**按屏幕算**（`display.getDefaultDisplaySync().height` → vp × 0.6），对应 iOS
  `.presentationDetents([.medium, .large])` 的 medium 手感，不写死数字。
- 原先为了「同一组件挂两个 sheet 不生效」而套的那层 `Stack`（外层切换账号 / 内层订阅弹层）不再需要：
  订阅弹层仍挂 `bindSheet`，切换账号走命令式弹窗，只剩一层绑定了。
- 内容组件 `common/AccountSwitcherSheet.ets` 没动（它自带「切换账号 / 关闭」标题栏，仍是卡片的内容）。

**实测（模拟器）**：长按头像页签 → 出现系统 `Dialog`（贴底、六成屏高、带遮罩），卡片内容齐全
（账号分组、添加账号、退出全部账号）；点卡片里的「关闭」→ 关闭；点遮罩 → 关闭。

### 第 7E 轮：批准弹窗自适应屏宽 + 批准/拒绝震一下（真机）

**需求（用户）**：① 批准设备登录的弹窗宽度要跟着屏幕走；② 批准成功 / 拒绝之后弹窗震一下。

**改动**：
- **自适应宽度**：`openCustomDialog` 的 `width` = `px2vp(display.getDefaultDisplaySync().width) - 32`
  （占满屏宽、左右各留 16vp），不写死数字。
  - 真机实测（VOL-AL00，1320×2232px / 518vp 宽）：日志算出 `dialogWidth=486vp`，
    实际卡片 + 两侧 24vp 内边距 = 1241px ≈ 486vp ✓，即宽度确实跟着屏幕走。
- **触觉反馈**：新 `common/Haptics.ets`（`startVibration({type:'time',duration}, {id:0,usage:'notification'})`）
  - 批准成功 → `notifySuccess()`（60ms，比普通点击长一点，对应 iOS `.success` 通知反馈）；
  - 拒绝 → `notify()`（30ms）；
  - **失败静默**（模拟器/无马达/被禁用只记一条 debug 日志），功能不被它拖累。
- `module.json5` 声明 `ohos.permission.VIBRATE`（normal 级，装上即授予；已用 `bm dump` 核对已授予）。

### 第 7F 轮：「切换账号」改用 ArkUI 高级组件弹窗（`CustomContentDialogV2`）

**背景**：用户要求把长按头像页签的「切换账号」也换成华为原生组件。三套候选都做出来对比过：

| 变体 | 做法 | 结论 |
| --- | --- | --- |
| 自绘（原样） | 自绘行 + 自绘动作行 + 自绘标题栏 | 保留为内容行（见下） |
| **HDS 列表卡片** | `HdsListItemCard`（`textItem.primaryText/secondaryText`）+ `HdsActionBar` | **未通过**：`HdsListItemCard` 传了 options 但**什么都不画**（行整块消失、无日志无报错），排查成本高，放弃 |
| **高级组件弹窗** | `CustomContentDialogV2({ primaryTitle, contentBuilder })` | **✅ 用户选定** |
| 系统选择弹窗 | `ActionSheet.show({ title, message, sheets: [{title, action}] })` | 能做，但**分组与行内按钮没了**（账号只能平铺、底部动作各占一行），不合用 |

**最终实现**：
- `common/AccountSwitcherSheet.ets`：`build()` 直接返回
  `CustomContentDialogV2({ primaryTitle: '切换账号', contentBuilder: this.DialogBody })`；
  正文（说明一行 + 按服务器分组的账号行 + 底部「添加账号 / 退出全部账号」）抽成 `DialogBody()` 复用；
  去掉自绘 `TitleBar`（标题由高级组件画）与 HDS 变体代码。
- `pages/MainTabsPage.ets`：长按头像页签 → `openCustomDialog`（遮罩 / 贴底 / 六成屏高 / 点遮罩可关），
  builder 里就是上面那个组件；删掉系统 `ActionSheet` 那条分支与 `SheetEntry`。
- 临时对比开关（「我的」页那张卡）与 `common/AccountSwitcherPrefs.ets` **已删除**。

**实测（真机 VOL-AL00）**：长按头像页签 → 弹窗出现，**标题「切换账号」由高级组件画**，
内容为账号行（DongShu · 当前 · @DongShu · 超级管理员）+「添加账号 / 退出全部账号」+ 底部说明；
点遮罩关闭 ✓。

### 第 7G 轮：切换账号弹窗「列表空 / 行宽 / 高度」三个问题（真机）

用户报：① 高级组件弹窗里**没有账户列表**；② 每行内容要自适应宽度；③ 弹窗高度要随账号多少自适应。

**① 列表为空的真因（两个叠加）**：
- 我们原来看 `AppModel.savedServers` 的快照。打开弹窗会先画快照、再逐台 `refreshAccounts()` **用服务器返回的账号列表整份替换**——
  这台服务器返回的列表里**不包含这台设备的会话**（设备登录/配对进来的会话不在「账号列表」里），
  于是刷新后 `accounts` 变空 → 整块列表消失（第一次打开有、刷新完再打开就没了，现象很迷惑）。
- 修法（比 iOS 更稳）：新增 `effectiveServers()`——本机快照 + **保证当前会话的那个账号一定在列**
  （快照没有就用 `SavedServers.snapshot()` + `upserting()` 合成一条当前账号）。这样无论服务器列表含不含它、
  快照是否被清过，用户自己的账号都看得见。
- 同时补上 iOS 的加载态：`loading` 记录正在拉取的服务器，**该台账号为空且正在拉取时给一行转圈**
  （同 iOS `freshness == .loading`）——原来这种情况是一块空白，最容易被当成「坏了」。

**② 行宽自适应**：行/动作行都是 `.width('100%')`，由弹窗宽度决定（弹窗宽 = 屏宽 − 32vp），
真机实测说明行 x101–1219、动作行 x235–1177，都铺满可用宽度。

**③ 高度随账号数自适应**：`openCustomDialog` **不再写 height**（原来是写死的六成屏高），
改由内容决定；内容侧给列表 `constraintSize({ maxHeight: 屏高 × 0.6 })`——
账号少弹窗就矮、账号多就高，超过上限内部滚动。

**真机实测（VOL-AL00）**：长按头像页签 → 弹窗内容与 iOS 一致：
`切换账号`（高级组件画的标题）→ 说明行「本机已登录的账号，点击即可切换，不用再输密码。」→
账号行（头像 + DongShu + @DongShu · 超级管理员 + 右侧「✓ 当前」）→「添加账号」「退出全部账号」→
页脚「添加账号时改一下服务器地址，就能登录到另一台 MovieClaw。」；等服务器刷新跑完再打开，
**列表依旧在**（合并当前会话生效）。

### 第 7H 轮：切换账号弹窗两侧留白收紧

用户反馈：弹窗两侧空得还是多。

**两层留白叠一起了**：① 弹窗宽度写成「屏宽 − 32」（左右各 16vp）；
② ArkUI 高级组件的内容区自带一层约 24vp 留白；③ 我们内容自己还有 16vp。
三层叠起来文字离屏幕边 ~40vp（真机 101px / 1320px）。

**改法（对齐 iOS：切换账号是整宽的半屏抽屉，行内容离边就是 List 的 16pt）**：
- 弹窗宽度改成**整屏宽**（`width = px2vp(屏宽)`，左右不留外边距）；
- `CustomContentDialogV2.contentAreaPadding = { start: 0, end: 0 }`，去掉高级组件那层；
- 左右留白只由我们内容的 16vp 决定。

真机实测（1320px 宽）：说明行 40/39px、动作行文字 174/81px —— 左右留白从 ~101px 收到 ~40px（16vp），
和 iOS 的 16pt 内边距一致。账号行因为外面还套了一层圆角卡片，内容再缩进一层（头像 ~102px），
如果嫌深可以把那层卡片去掉（iOS 是普通 List，没有卡片）。

### 第 7I 轮：两个弹窗统一成「自绘卡片」（用户拍板）

用户问「切换账号和批准登录的不是同一个组件么？」——确实不是：**两者都用 `openCustomDialog`，但内容层不同**：
- 批准设备登录：内容是我们自绘的卡片（`DeviceApprovalDialog`），弹窗底色 `Theme.surfaceRaised`；
- 切换账号：内容外面套了 ArkUI 高级组件 `CustomContentDialogV2`（标题栏和 #2b2d30 面板是它画的），
  弹窗底色 `Theme.bg`（#000）。

这层差异还直接造成「底部一条颜色不一致的窄边」：高级组件的面板盖不到弹窗底部安全区，
那块露出的是我们的弹窗底色（纯黑）。截图取样：面板 #2b2d30 / 底部条 #000。

**用户选择：都保持自绘卡片**（去掉高级组件）。改动：
- `common/AccountSwitcherSheet.ets`：`build()` 回到 `Column { TitleBar(); DialogBody() }`，
  自己画标题栏（「切换账号」+ 右侧「关闭」），不再引 `CustomContentDialogV2` / `LengthMetrics`；
- `pages/MainTabsPage.ets`：`openAccountSwitcher` 的选项与批准登录**逐项对齐**——
  `width = 屏宽 − 32`、`alignment: Bottom`、`maskColor: rgba(0,0,0,0.6)`、`backgroundColor: Theme.surfaceRaised`、
  `cornerRadius: Theme.cardRadius`、`keyboardAvoidMode: DEFAULT`、`autoCancel: true`；
  高度仍不写（内容决定，列表 `maxHeight = 屏高 × 0.6` 封顶）。

**真机实测（VOL-AL00，截图核对）**：两张卡宽度、圆角、底色、贴底位置一致；切换账号卡片
自绘标题栏「切换账号 / 关闭」+ 说明行 + 账号卡（头像 / 昵称 / @用户名 · 角色 / ✓当前 / ✕）+
「添加账号 / 退出全部账号」+ 页脚；**底部那条黑边消失**。

### 第 7J 轮：个人信息页对齐 iOS（内容 / 功能一致，控件用华为原生）

原来这页只有「本机账号列表 + 退出登录」，iOS 那边是四块内容（`ProfileSettingsView`）。本轮按 iOS 重写：

| 区块 | iOS 内容 | 本轮实现 |
| --- | --- | --- |
| 账号总览 | 头像 72（点按选图 → 压 512px JPEG → `POST /auth/avatar`）、昵称、身份徽章、@用户名 | 同；点头像 → **系统图库 `PhotoViewPicker`** → `ImagePacker` 压到 512px JPEG → 写应用缓存 → `request.uploadFile` 走系统上传代理 → 再 `authMe()` 刷会话 |
| 账号信息 | 昵称原地编辑（≤32 字，`PUT /auth/profile`）、用户名只读 | 同（编辑 → 原生 `TextInput` + 取消/保存） |
| 安全 | 当前 / 新（≥8 位）/ 确认三格 → `PUT /auth/password`；有配对的命令行/转码器时可勾「一并注销」 | 同；三格用 `InputType.Password`（系统安全键盘 + 眼睛图标），勾选用原生 `Toggle`，**`pairedCount === 0` 时不显示**（与 iOS 同条件） |
| 观看历史 | 清空全部观看记录（二次确认 → `DELETE /playback/history?scope=all`） | 同 |
| 底部 | 「切换账号」行（打开切换弹窗）+ 页脚说明；单独一组居中红字「退出登录」 | 同；切换账号直接复用切换弹窗（同一套卡片样式） |

**控件一律华为原生**：`List` / `ListItem`、`TextInput`(`InputType.Password`)、`Toggle`、`Button`(`ButtonType.Capsule`)、
`LoadingProgress`、系统图库 `PhotoViewPicker`、系统上传代理 `request.uploadFile`；卡片容器沿用本 App 既有圆角卡。
JSON 校验与 iOS 一致：新密码 ≥8 位、两次一致；三格没填满时「修改密码」不可点。

**真机实测（VOL-AL00，截图核对）**：页面结构逐块对上；密码三格显示系统的眼睛图标；
点「编辑」出现输入框 + 取消/保存；点头像**确实拉起系统图库**（picker 打开，安全访问提示可关）；
点「清空」出现二次确认（未确认，避免真清数据）。

**用户反馈并修掉**：「观看历史」与「切换账号」两张卡贴在一起——那两张卡之间的节奏丢了
（上面每张卡有小标题的 14 顶部留白，切换账号卡没有小标题）→ 给它补 18 的 `margin-top`，现在与其它分组一致。

**没执行（都是真实改动数据的动作，留给用户自己按）**：保存昵称、上传头像、改密码、清空观看记录。

### 第 7K 轮：「关于」从「我的」页迁到设置页底部（用户要求）

- `pages/MorePage.ets`：删掉 `AboutCard()`（及 build 里的调用），「我的」页现在只剩账号卡 + 服务器设置卡 + 页脚。
- `settings/SettingsIndexPage.ets`：在 AppFooter 之前加一个「关于 MovieClaw」分组（`ListItemGroup` + `AboutRow`），
  排布与上面各分区行完全一致（图标列 20/宽 28 + 主标题 16 + 副标题 12 + 右箭头，行内 padding 16/12，
  颜色走 `$r('app.color.*')` 跟随系统深浅色），点进 `about` 页。

**真机实测（VOL-AL00）**：「我的」页不再有「关于」；设置页滚到底部出现
「关于 MovieClaw / 版本与开源许可」→ 点进去正常打开关于页（版本 1.0.0、项目主页）。

### 第 7L 轮：「我的」页对齐 iOS：最近会话 + 右上角扫码 / 搜索

**① 最近会话（管理员，逻辑与功能照 iOS `MorePage`）**
- `pages/MorePage.ets`：页面从 `Scroll + Column` 改成 **`List`**（`swipeAction` 只挂在 `ListItem` 上，不改就没法做原生左滑）；
  新增「最近会话」组（`ListItemGroup`，卡片观感与设置页一致）：
  - **新会话** 行（`plus` 图标）→ 进会话页开新会话；
  - 没有会话时给一句提示；会话行 = 运行中小蓝点 + 标题（标题 → 最近一条用户消息 → 「未命名会话」）；
  - **分页**：每页 20、滑到最后一条自动续下一页、按 id 去重（同 iOS 的 `.onAppear` + `hasMore`）；
  - **左滑**三个纯图标操作（续接 / 重命名 / 删除，顺序同 iOS）+ **长按菜单**同样三项；
    续接与删除先二次确认、重命名先弹输入框（原生 `TextInput` 弹层，初值就是当前标题、最多 80 字）。
- `agent/ChatPage.ets`：支持**新会话**——`ChatParams` 允许空 id（没带参数 = 新会话），
  进来先给「新会话」首屏、不拉轨迹/不开流；发第一条消息后服务端返回 `session_id`，再接上它拉轨迹、开事件流。

**② 右上角两个按钮（扫码 / 搜索，华为原生图标）**
- `pages/MoreNavHost.ets`：`Navigation.menus(this.TopMenus())`，胶囊里两个 `SymbolGlyph`
  （`sys.symbol.qrcode` / `sys.symbol.magnifyingglass`，系统符号＝华为原生图标）：
  扫码 → 拉起批准弹窗并**直接开扫码界面**（给 `DeviceApprovalDialog` 加了 `scanFirst`）；
  搜索 → 进搜索页；没有搜索权限就不给这个入口（同 iOS `canOpenSearch`）。
- **坑**：数组式 `.menus([NavigationMenuItem...])` 会被 Navigation 贴到最顶端**压住状态栏**
  （沉浸式布局下不避让）；而且链式里 `.padding()` 会被前面的 `.padding(3)` 覆盖（同一属性后写的赢）。
  改用 **`@Builder` 形式的 menus**（同 `LibraryNavHost` 的做法）并用 **`.margin({ top: Theme.statusBarInset })`** 让位。

**实测（模拟器 127.0.0.1:5555；真机当时掉线）**：
- 「我的」页出现「最近会话」组：新会话 + 两条真实会话；
- 点会话行 → 进会话页 ✓；点「新会话」→ 空会话页 ✓；
- **左滑**会话行 → 三个原生图标按钮出现（续接 / 重命名 / 删除）✓ → 点「重命名」→ 弹层打开且初值就是当前标题 ✓（随后取消，未改数据）；
- 右上角胶囊按钮在标题同一行、状态栏之下 ✓；点扫码 → **系统扫码界面打开** ✓；点搜索 → 进搜索页 ✓。
- **没执行**（会真改数据）：续接、保存重命名、删除会话。

**真机侧已验证**：装机、启动、进入「设置 → 设备 → 批准新设备登录」、弹窗打开且宽度自适应。

### 第 8Y 轮：闭环迭代（详情页 + 订阅弹层逐值对平）

按用户要求「自己迭代、就要和 iOS 对齐、「我的」子树不碰」继续逐屏照抄。

**详情页**（对照 `SubscriptionDetailView.swift` / `SubscriptionWantedViews.swift`）
- 正文：`VStack(spacing: 16)`、顶部 padding 8（原 22 / 4）。
- 摘要卡：圆角 **18**（原 `Theme.cardRadius`=16）；抬头 `.caption.weight(.semibold)`（12/600）；
  片名 `.title3.weight(.bold)` = **20/700**；年份 `.body` = **17** + `white.opacity(0.45)`；
  原名/订阅于 `.subheadline` = **15** + `white.opacity(0.55)`；状态词 `.subheadline` = **15**。
- **补上 ProgressStrip 的标题行**：「收录进度」15/600 + 右侧「N / M 集」15；进度条高 **4 → 6**（capsule）。
- 操作按钮文字 `.subheadline.weight(.semibold)` = 15；搜索轮次摘要 `.subheadline.weight(.medium)` = 15。
- **季分组**：`VStack(spacing: 14)`（原 10）；季头计数改成 iOS 的 **`已排/总数`**（如 `25/31`，原来写「31 集」）；
  季头/洗版中/集行说明全部 **15**；季头 padding 16/11；单集行 padding 16/11。
- **删掉我编的「单集履历」标题**（iOS `WantedBreakdown` 无标题）。
- 排查记录：头部 15/600 + 条数 15；时间轴句子 `.subheadline` = 15。

**订阅弹层**（对照 `SubscribeSheet.swift`）
- 头部片名 `.title3.weight(.semibold)` = **20/600**；meta `.subheadline` = **15**；「媒体库已有」`.footnote` = **13**；
  季行季名改成 body = **17**。

**实测**：详情页装机截图核对 —— 「收录进度 10 / 34 集」标题行出现、进度条变粗、季头显示 `第 5 季 25/31`、
「单集履历」标题消失 ✓。`arkts_check` 0 报错 + BUILD SUCCESSFUL + 已装机。

**下一步（继续闭环）**：洗版页 / 规则集编辑器 / 海报墙 / 媒体源标注 逐值对平；并把发现的「自己编的东西」清掉。

**（同轮续）洗版页 / 洗版报告 / 片源标注 / 海报墙 逐值对平**（对照 `UpgradeRunSheet.swift` /
`MediaSourceAnnotationSheet.swift` / `SubscriptionWallView.swift`）
- 洗版页：副标题 `.subheadline` = 15；规则行 `SubsChoiceRow` = 17 / 13、「按订阅当前的规则组洗版」17；
  库存季行 17 / 13；脚注 13。
- 洗版报告：摘要 `SubsNoticeRow` = 15；季头 15；集行集号 15；说明 `.footnote` = 13；页脚 13。
- 片源标注：文件名 15、体积 `.footnote` = 13、「共 N 个文件…」13、档位行 `SubsChoiceRow` = 17 / 13。
- 海报墙：汇总 `.subheadline` = 15；分段名 `.title3.weight(.bold)` = 20/700；条数 `.subheadline` = 15。

**实测（装机截图）**：海报墙汇总 15、分段名 20/700、条数 15 ✓。

**（同轮续 2）规则集编辑器逐值对平**（对照 `RuleSetEditorView.swift` + 共用件 `SubscriptionKit.swift`）
- 字段标题 `field(_:)` = `.subheadline.weight(.semibold)` = **15/600**（原 14/Medium）
- 折叠头 `collapsible` = `.body.weight(.semibold)` = **17/600**（原 15/Medium）、摘要 `.footnote` = **13**
- `SubsToggleChip` / `SubsTriChip` = `.subheadline.weight(.medium)` = **15/500**、padding **h12/v6**；
  序号角标 `.system(size: 10, weight: .semibold)`、**16×16**（原 10/14×14）
- `SubsToggleRow` 标题 = **17**、说明 `.footnote` = **13**；`LabeledContent` 标题 = **17**
- 回执正文 `.subheadline` = **15**

`arkts_check` 0 报错 + BUILD SUCCESSFUL + 已装机。

**待办交接（下一轮直接照做，iOS 行号已定位）**

1. **Hero 选题来源**（`SubscriptionsHomeModel.swift:268-317` `heroSlides`）：
   顺序 = `pipeline`（`presentation.stageOrder>0`，整理中优先于下载中 → 再按预计时刻）
   → `fresh`（入库 ≤ `freshArrivalWindow` = 48h，按入库时间倒序）
   → `today`（`daysAhead==0 && stageOrder==0`，按预计时刻）
   → `older`（>48h 的入库）
   → `upcoming`（最小的正数 `daysAhead`，且 `stageOrder==0`）；
   一部作品只占一张、上限 `maxHeroSlides` = 5；**全空时退路** = 在追优先（`status=="active"`）、
   再按 `updatedAt` 倒序取前 3 的 `restingSlide`。
2. **三种 slide 的内容**（`slide(group)` 319-375 / `slide(card)` 377-393 / `restingSlide` 395-412）：
   eyebrow（tone + pulse）、clockLabel/clock（同日写时刻、明天写「明天」、否则「M月D日 HH:mm」）、
   detail、footnote、progress、play/resumePercent；`stage` = downloading/organizing/today/arrived/upcoming/resting。
   —— 要**替换我现在自己编的** `heroStatus()`（「第 5 季 · 下一集 S05E142」）。
3. **Hero 视觉**（`SubscriptionsHomeHero.swift`）：Ken Burns 慢推近、上滑视差下沉 + 文字淡出、
   底部氛围色（`ImmersiveHeroAmbient`，主色取自当前剧照 —— 鸿蒙要读 `image.PixelMap` 采样）、预载下一张的剧照与 Logo。
4. **详情页手动选种**：iOS `SubscriptionDetailView` 的 `manual-pick` → 推搜索页并带 `forSubscription`
   （鸿蒙要在 `search/SearchParams` + 搜索结果页加「投给本订阅」= `subscriptionsDownloadSelectedTorrent`）。
5. **规则组复制**：iOS 只从「设置 → 订阅规则」进；设置在「我的」子树 → 按用户约束不碰，故暂不做。

### 第 8X 轮：按「开发闭环」返工——逐值照抄 iOS（不再凭观感填数）

用户点出：我在**近似**而不是**照抄** iOS 的字号/字重/尺寸（＝瞎写），且没走「改 → 构建 → 装机 → 对照 iOS」这个闭环。
本轮开始按闭环做，先把已改过的屏逐值对平：

- **骨架屏**按 iOS 原文重写（`common/SkeletonBlock.ets`）：`DiscoverSkeletonBlock` 白 0.04↔0.08、
  0.9 秒 easeInOut 往复（`animateTo({iterations:-1, playMode:AlternateReverse})`）；`DiscoverRowSkeleton`
  是**标题 + 4 张 126×189、圆角 `posterRadius`**、末尾 `clip`；`SubsHomeHeroSkeleton` = 圆角 0 的闪烁块撑满 Hero 高。
  （之前我写的是 3 张 / 124 / `Theme.surface` / 不闪 —— 错的。）
- **删掉我编的标题**：iOS 详情页正文是 `摘要卡 → 搜索轮次摘要 → WantedBreakdown → 排查记录`，
  `WantedBreakdown` **没有标题**；鸿蒙这里多出的「单集履历」是我加的，已删。
- **逐值照抄**（每处注释写清对应 iOS 哪一行）：版块标题 `.title3.weight(.bold)` = 20/700（原 19/600）；
  一排计数 `.footnote` = 13；「刚刚入库」标题 `.subheadline.weight(.semibold)` = 15、第二行 `.footnote` = 13、
  第三行 `.caption` = 12；日程时刻 `.system(size: 20, weight: .semibold)`、右箭头 `.system(size: 12, weight: .semibold)`；
  Hero 状态行 `.subheadline.weight(.semibold)` = 15、脚注 `.footnote` = 13；里程碑站名/说明/单集行说明 = 15、
  补充行/种子行 `.caption` = 12；事实行值 `.subheadline.weight(.medium)` = 15；海报卡第二行 `.caption` = 12、流向行 `.caption2` = 11。

**实测（模拟器装机截图）**：订阅首页版块标题变粗变大、卡片三行字号与 iOS 一致；Hero 状态行/脚注字号对平。

**下一步**：继续按闭环逐屏逐值对平（详情页 → 订阅弹层 → 洗版页 → 规则集编辑器 → 海报墙），并把发现的「我编的东西」一并清掉。

### 第 8W 轮：1:1 返工（第二批）——洗版变体 / 调整订阅清理追问 / 空态切页签 / 骨架屏 / 洗版入口

- **洗版报告抽成共用组件** `subscriptions/UpgradeReportView.ets`（对应 iOS `UpgradeRunReportView`）：
  摘要 + 按季逐集 + 可选「标注片源」；洗版页与订阅弹层共用（「完成」由宿主给）。
- **订阅弹层洗版变体**（iOS `request.upgrade`）：标题「订阅并洗版」、季按库存预填、自动续订默认关、
  只列带洗版目标的组（空态给指引）、`canSubmit` 要求选到带目标的组、建完立刻体检并在弹层内出报告。
  `MainTabsPage` 把 `SubscribeCenter` 的 `upgrade` 透传进来。
- **洗版入口并轨**：媒体库条目详情 ⋯ 菜单加「洗版」（同 iOS `upgrade`）——已有订阅 → 进订阅详情并直接打开
  洗一轮版（`SubscriptionParams.openUpgradeRun`）；没有 → 以洗版模式打开订阅弹层。
- **调整订阅补 iOS 细节**：`droppedWithProgress` 警示；**减季后的清理追问**（`SeasonCleanupContent`：
  预览数量 + 两个开关 + 「保留内容」+ 后台清理文案）；**投递预检脚注**（选库即预演，调整态只说监听目录）。
- **首页空态**「去发现剧集」改成**切到发现页签**（走 `ShellChrome.openTab('discover')`，不再是 toast）。
- **订阅首页加载态换成骨架屏**（同 iOS `loadingSkeleton`）：Hero 块 + 「刚刚入库」「剧集订阅」两行占位。
  （详情页加载态 iOS 本来就是转圈 + 文案，已一致。）

**实测**：每块 `arkts_check` 0 报错 + `hvigorw assembleHap` **BUILD SUCCESSFUL**（本轮未逐屏复验）。

**仍未做（下一批）**
- Hero 的**选题来源**（iOS 从「下载中/整理中 → 刚到 → 今天 → 预告 → 休息中」挑，上限 5）与
  **Ken Burns / 视差 / 氛围底色 / 预载**：氛围底色需要从图片取主色（iOS `ImmersiveHeroAmbientColor`），
  鸿蒙要读 `image.PixelMap` 采样，属独立技术活；视差要先接页面滚动偏移。
- 详情页**手动选种**（需搜索模块支持 `forSubscription` 投递）。
- 「去发现剧集」只切页签，**没有按类型过滤**（发现页当前没有 kind 参数）。
- 规则组**复制**：iOS 只从「设置」进，而设置在「我的」子树 → 按约束不动。

### 第 8V 轮：按「接近 1:1」口径返工订阅模块（用户：只允许「iOS 原生组件 vs 华为原生组件」这一处差异）

**口径**（用户重申）：目标接近 1:1，不许自己简化或另发明；**「我的」页面及从「我的」能进去的页面一律不动**；
其余用华为原生组件实现。

**本批已改（每块 arkts_check + 构建通过）**
1. 详情页操作区对齐 iOS `actions`：只留 `立即搜索`（条件 = `canTune && wanted>0 && status!=paused`）+ `更多`
   （`showMore = canSubscribe || isAdmin`）；`暂停追踪` 从顶层移进「更多」。
2. 「更多」菜单补全 iOS `SubscriptionManageSheet` 的门槛：`调整订阅/洗一轮版/自动续订/暂停` 需 `canTune`、
   `更换规则组` 需管理员、`取消订阅` 需 `canSubscribe`。
3. 详情页标题改成**影片名**（iOS `navigationTitle(detail?.media.title ?? "")`）。
4. 「更换规则组」补**条件摘要芯片**（`RuleSetText.summary`，空=全不限）。
5. 取消订阅面板补 iOS `SubscriptionCancelSheet` 的说明与提示：两个开关各带描述（可恢复性 / 回收站保留天数）、
   数量为 0 时禁用、勾选后出现「清理在后台进行…」、以及 `retained_cross_season` 的保留提示。
6. 「刚刚入库」卡与海报卡补**长按菜单**（iOS `contextMenu`）：播放 / 查看订阅详情 / 查看影片详情。
7. 洗版页补「**新建规则组…**」（管理员），返回本页 `onShown` 重拉规则组（不覆盖已选）。
8. 日程日期条改为**站点日历（UTC）**口径：由 `expected_day - days_ahead` 反推站点「今天」，星期/日号按 UTC 取。
9. **里程碑链补回竖轨线**：用「内容列左边框」画线（避开百分比/权重高度的坑），节点改 `Circle().stroke()`
   （`Circle + border` 在 ArkUI 会画成方框）。
10. 详情页补 iOS 的**预测轮询**：`forecast_pending` 时 1.5 秒只重取详情、最多 40 次；再有 30 秒静默全量刷新
    （仅在途投递时真的发请求）。

**实测**：详情页标题为「斗破苍穹」、操作区为「立即搜索 + 更多」✓；里程碑链出现竖轨线且卡点（搜索）为橙色描边节点 ✓。

**仍未做（下一批）**
- 订阅弹层**洗版变体**（`request.upgrade`）；
- 「调整订阅」减季后的**清理追问**（iOS `SeasonCleanupContent`）与投递预检脚注；
- 首页 / 详情**骨架屏**；Hero 的 **Ken Burns / 视差 / 氛围底色 / 预载** 与**选题来源**（下载中 → 刚到 → 今天 → 预告）；
- 详情页**手动选种**（需搜索模块支持 `forSubscription`）；首页空态**切到发现页 tab**；
- 规则组**复制**（iOS 仅从「设置」进入，而设置在「我的」子树里 → 按约束不动，无合规入口）。

### 第 8U 轮：季头迷你进度条（用户要求，对齐 iOS）+ 收起的季不再被刷新打开

- **季头右侧迷你进度条**（同 iOS `seasonHeader`）：**收起态才显示**，48×4 的胶囊，
  按「已排（非 wanted）/ 总数」比例填充；全排完=绿、否则=黄。
  新增 `arrangedInSeason` / `seasonBarWidth` / `seasonBarColor`。
- **修掉「收起第 5 季又被自动打开」**：`initSeasons` 原先把「展开列表为空」当成「没初始化」，
  而这部订阅有在途下载、每 5 秒静默刷新一次详情 → 收起后下一轮又被打开。改成独立的一次性标志
  `seasonsInitialized`（同 iOS），季的默认展开只在首载算一次。

**实测（模拟器装机实跑）**：
- 收起「第 5 季」后等 8 秒（>1 个轮询周期）再 dump：只剩两个季头、没有任何集行 → 保持收起 ✓
- 两个季头收起时右侧都出现迷你进度条：`第 5 季 31 集` 是**黄色部分填充**、`第 4 季 3 集` 是**绿色满格** ✓

### 第 8T 轮：排查记录改成 iOS 的「折叠时间线」（用户：要按时间回放每一步）

对应 iOS `ActivityLogSection` + `ActivityTimelineView`：
- 版块改成**默认收起**的折叠卡：头部一行 `排查记录` + 条数 + 右侧 chevron（点亮开），展开后才是时间线。
- 展开后按时间**逐站回放**：每个节点一个**按活动类型着色**的圆点（`WantedLogic.activityColor`：
  抓取/命中/下载/入库/换版推广=绿、洗版=青、拒绝/投递失败/入库失败=红、暂停/停滞/校验失败/规格不符=黄、其余=蓝），
  圆点之间用一条竖线连起来（最后一站不画线），右侧是后端写好的中文句子 + 相对时间。
- 新增 `WantedModel.activityColor`；排版用 `Stack` + 内容列左边框画竖线（**不用百分比/权重高度**，避开上一轮踩过的坑）。

**实测（模拟器装机实跑）**：详情底部「排查记录 100 ›」默认收起 ✓；点开后是一条竖线串起来的圆点时间线——
拒绝记录是红点、`用户触发立即搜索` 是蓝点、`已投递…` 是绿点，句子与「8 天前」都在 ✓。

### 第 8S 轮：单集履历排序与里程碑链布局（用户实测反馈）

- **单集履历整体降序**：季按「最新一季在最上、特别篇 0 最后」（`seasonNumbers` 改 `b - a`，对齐 iOS
  `WantedBreakdown` 的 `sorted(by: >)`），**季内集号也从大到小**（`wantedOfSeason` 改 `b - a`，用户要求，
  这里与 iOS 的升序不同，按用户口径）。默认展开的季随之变成最新一季。
- **里程碑链布局修复**：上一轮用 `Flex({ alignItems: ItemAlign.Stretch })` 让竖轨自适应行高，
  结果在「内容决定高度」的父容器里 Flex 会撑满**可用高度**（Scroll 里＝整屏），一站把整链撑到 ~1100px，
  搜索/投递被顶到屏外。改成普通 `Row` + 内容高度（去掉了节点之间的竖线连接；节点靠 `margin top` 对齐站名）。
  代价：少了 iOS 那条竖轨线。

**实测（模拟器 127.0.0.1:5555，装机实跑）**：单集履历首块为「第 5 季 31 集」，集序 E219 → E214（降序）✓；
展开一集，`播出 → 搜索 → 投递 → 下载 → 入库 → 洗版` 六站一屏内紧凑排列 ✓；实时下载态（`已提交` +
`2% · 已在下载器中暂停` + 进度细线）✓；`预测窗口` 态显示预测区间与重点探测站 ✓。

### 第 8R 轮：订阅模块二轮对齐（用户：「我都要，你一个一个都给我对齐」）

**新增 / 抽出**
- `subscriptions/WantedModel.ets`：追踪项呈现逻辑（`SubsColor` / `Milestone` / `WantedPresentation` /
  `ReleaseForecast` / `WantedLogic`：`presentation` / `downloadNote` / `resourceTimingNote` / `milestones` /
  `stuckIndex` / `pendingFailures`）——对应 iOS `SubscriptionPresentation.swift`。
- `subscriptions/SubscriptionsHomeModel.ets`：首页判定逻辑（`ShelfStanding` / `ShelfSplit` / `CollectionMeta` /
  `SubsHome`）从 `SubscriptionsPage` 抽出，首页与海报墙共用（顺序、状态签、计数两处一致）。
- `subscriptions/SubsPosterCard.ets`：海报卡组件（首页横滑与海报墙共用）。
- `subscriptions/SubscriptionWallPage.ets`（route `subscriptionWall`）：完整海报墙——汇总 + 进行中 /
  已暂停 / 已收齐（电影叫已入库）三段 + 「规则组 → 媒体库」流向。

**详情页**
- 单集履历从「一行」改成 iOS 的「集号 + 状态胶囊（微型链）+ 说明 + 下载进度 + 可展开里程碑链」
  （播出 → 搜索 → 投递 → 下载 → 入库 → 洗版）；入库失败时胶囊转红。
- 补「搜索轮次摘要」`SearchRoundBar`。
- 实时下载快照（`active-downloads`）随 5 秒轮询刷新；失败活动（入库/投递失败）按工单回查。
- 「更多」菜单补齐：调整订阅… / 洗一轮版 / 自动续订 / 更换规则组… / 暂停·恢复 / 取消订阅；
  弹层用 `sheetKind` 分发（调整订阅 / 更换规则组 / 管理员取消带移除预览）。
- 「立即搜索」补二次确认；管理员取消走 `subscriptionsDelete(deleteTorrents, deleteLibraryFiles)`，
  成员走 `subscriptionsUnsubscribe`。

**首页**
- Hero 补主按钮（有刚入库→播放，否则→查看订阅）、状态点 tone、脚注、当季收录进度线。
- 「刚刚入库」卡补片名 Logo 叠图、播放角标、「新 N 集」chip、底部续播线；点击直接起播。
- 海报行标题可点「›」压栈海报墙；横滑限 20 张，超出末尾放「查看全部」卡。
- 版块间距 26 → 36。

**订阅弹层**：规则行下补品质摘要（空 = 「全不限」警示）。

**实测**：每块 `arkts_check` 0 报错 + `hvigorw assembleHap` **BUILD SUCCESSFUL**。

**仍未做**（按缺口性质分类）
- 依赖后端/别的模块：详情页「手动选种」（要搜索模块支持 `forSubscription` 投递）；
  日程议程行「时刻 + 状态点」列（`TodayArrivalView` 无钟点字段）。
- 纯工作量：首页 / 详情骨架屏；Hero 的 Ken Burns / 视差 / 氛围底色 / 预载；
  订阅弹层的洗版变体（`upgrade`）；规则集编辑器「复制规则组」。
- 依赖全局能力：空态按钮切到发现页 tab（没有「切 tab」入口）。
- 未做的小项：详情页 `forecast_pending` 1.5 秒轮询与 30 秒静默刷新；「调整订阅」减季后的清理追问。

### 第 8Q 轮：缺口三页补齐（第 5 步）——片源标注 / 洗一轮版 / 规则集编辑器

用户拍板「三页都补」。三页都走 `router_map.json` 注册 + `NavDestination` 根节点。

**新增文件**
- `subscriptions/RuleSetModel.ets`：规则组领域模型（词表、`RuleSetSpec` 解析/序列化、`RuleSetText` 人话、
  `UpgradeLadderPreview`、`RuleSetScope`、`LibraryRoutingOptions` + 进程内缓存）——对应 iOS `RuleSetEditorModel.swift`。
- `subscriptions/MediaSourceAnnotationPage.ets`（route `mediaSourceAnnotation`）：三段式
  （待标注文件列表 / 档位单选含后果说明 / 确认标注）。
- `subscriptions/UpgradeRunPage.ets`（route `upgradeRun`）：确认段（选带洗版目标的规则组 /
  并入范围外库存季 / 暂停提示改「恢复并触发」）+ 报告段（按季逐集状态 + 管理员「标注片源」入口）。
- `subscriptions/RuleSetEditorPage.ets`（route `ruleSetEditor`）：表单化编辑器（名称 / 适用范围 /
  分辨率 / 片源 / 画质与来源 / 下载与限制 / 洗版 / 回执），`RuleSetEditorBody` 可复用。

**接线**
- 订阅详情：右上「洗版」改为压栈 `upgradeRun` 页（**删掉原先内联的洗版 sheet** 及其状态/方法）；
  季头对「无法确认档位」的季加管理员「标注片源」入口。
- 订阅弹层：规则区块改为管理员恒显示；规则选择弹层加「新建规则组…」→ 压栈 `ruleSetEditor`；
  打开规则选择时重拉规则组清单（从编辑器返回后能看到新组）。

**实测**：`arkts_check` 0 报错；`hvigorw assembleHap` → **BUILD SUCCESSFUL**。

**没做 / 缺口**：编辑器没有「复制规则组」入口（iOS 支持）；洗版页里没有「新建规则组…」（iOS 有，这里从订阅弹层进）；
规则组的「洗版目标」是从 `spec.upgrade_source` 派生的（与 iOS `typedSpec` 一致，模型无数值字段）；
设备侧未实跑（没起模拟器）。

### 第 8P 轮：订阅弹层对齐 iOS（第 4 步）——字段 / 校验 / 文案 / 按钮

对照 `SubscribeSheet.swift` 比对并补齐。

- **文案**：加载 `正在获取条目信息…`；歧义标题改 `找到多个可能的条目，请确认你订阅的是哪一部`；
  `not_found` 换 iOS 原文（「订阅依赖 TMDB 的别名与季集数据…」）；已订阅态改
  `该电影/剧集已在订阅中，movieclaw 正在持续追踪资源。`。
- **已订阅管理态补「查看订阅详情」**（走当前页签的栈 push `subscriptionDetail`，同 iOS `router.push(.subscription)`）。
- **就绪态**：季选择补脚注 `勾选即要整季（含未播集）`；补「媒体库已有，订阅后不会重复下载」
  （用预检的 `movie_owned`）。
- **取消订阅确认**文案对齐成员路径（`取消订阅《标题》？` + `将取消你的订阅关注；已经下载或入库的文件不会被删除。`
  + 取消键「先不」），结果按后端 `cleanup_job_id` 分两种。

**没做**：洗版变体（`upgrade`，依赖 `UpgradeRunSheet`）、规则组的品质摘要与「全不限」警示、
菜单末尾「新建规则组…」（依赖第 5 步的规则集编辑器）、入库库选择行没标「（默认）」。

**实测**：`arkts_check` 0 报错；`hvigorw assembleHap` → **BUILD SUCCESSFUL**。

### 第 8O 轮：订阅首页对齐 iOS（第 3 步）——海报行分组 / 卡片形态 / 文案

按 §3.3，对照 `SubscriptionsView` + `SubscriptionsHomeSections` + `SubscriptionsHomeHero`
（判定逻辑在 `Shared/Subscriptions/SubscriptionsHomeModel.swift`，一并移植）。

- **海报行分组**（对应 iOS `shelf`）：一排拆成「进行中 / 歇着」。进行中按「此刻最要紧」排
  （下载中·整理中 0 → 新集 1 → 今天更新 2 → 某天更新 3.x → 洗版中 4 → 缺集·找资源中 5 →
  追更中 6 → 未上映 7）；暂停与已收齐排在竖排小字分隔线（`暂停·入库 / 暂停·收齐 / 已暂停 / 已收齐`）后面。
  移植了 `standing` / `shelf` / `meta` / `collectionMeta` / `seasonProgress` / `missingAired` /
  `released` / `fullyCollected` / `countSummary`。
- **卡片形态**：海报左上加状态小签（已暂停 / 下载中 / 整理中 / 新 N 集 / 今天更新 / 缺 N 集 /
  找资源中 / 未上映 / 洗版中），底部改「当季收录比例」细线；第二行换成 iOS `meta`
  （`第 1 季 · 3 / 12`、`已收齐 · 第 1 季`、`2025 · 已入库`…）；暂停 / 已收齐压暗。
- **版块标题**：右侧计数用 `countSummary`（`N 部进行中 · 共 M 部` / `共 M 部`）；「刚刚入库」
  多于 1 部才显示 `N 部`；日程显示选中日的 `N 部`。
- **「刚刚入库」卡**：补第三行 note（`3 分钟前入库 · 共 2 集新内容 · 看到 40%`）；
  电影第二行改为 `2025 · 电影`。
- **空态文案**：`从一部想看的作品开始` + 按权限分的说明 + `去发现剧集`；失败态标题改 `订阅列表加载失败`。

**实测**：`arkts_check` 0 报错；`hvigorw assembleHap` → **BUILD SUCCESSFUL**。

**没做 / 缺口**（留给第 5 步或更大工程）：
- 海报行的「› / 查看全部」与海报墙 `SubscriptionWallView`（第 5 步缺口页）——所以横滑不做「查看全部」卡；
- Hero 的 Ken Burns / 视差 / 氛围底色（`ImmersiveHeroAmbient`）/ 预载：当前 Hero 能用，但没这些；
- 加载态是转圈 + 文案，iOS 是骨架屏；
- 空态按钮点了仍是 toast（iOS 是切到发现页 tab；鸿蒙没暴露「切 tab」入口）；
- 日程议程行没有「时刻 + 状态点」列（`TodayArrivalView` 没有钟点字段）；
- 右上角：iOS 订阅首页没有菜单（注释里的「链路体检」钮并不在这三个文件里），鸿蒙保留「N 部在追」计数。

### 第 8N 轮：订阅详情页对齐 iOS（第 2 步）+ 全局顶栏组件化

按 `docs/subscription-refactor-plan.md` §3.2 走。

**① `PageTopBar` 从 `@Builder` 函数改成 `@ComponentV2`**（`@Param title` + `@Event onBack`）——
`@Builder` 的简单类型参数按值传递，标题变了不刷新（订阅详情从「订阅详情」切「电影/剧集订阅」最明显）。
全站 16 处调用点改成对象参数 `PageTopBar({ title: …, onBack: … })`。顺带让 7 个动态标题页
（影人、搜索、发现详情、设置分区、会话、订阅详情）跟着状态刷新。

**② `SubscriptionDetailPage` 摘要卡补齐 iOS 字段**（对照 `SubscriptionDetailView.swift`）：
- 抬头：左「电影订阅 / 剧集订阅」（accent2 + 字距 3）、右状态点 + 状态词；
- 海报身份：海报改 80 宽 + 片名（带年份）+ 原名（与主标题不同才显示）+ **「订阅于 {created_at}」**；
- **配置事实行**（上下细分隔线）：`收录范围`（电影=正片 / 未勾选季 / 第 N、M 季）、
  `自动续订`（已开启/已关闭，电影不显示）、`规则组`（仅管理员；查规则组清单显示组名，查不到退化成 #id）；
- 操作区：`立即搜索` / `暂停·恢复追踪` / **`更多`**（`bindMenu`：自动续订：已开启/已关闭、取消订阅）。

**③ 取消订阅文案对齐 iOS**：`取消订阅《标题》？` + `将取消你的订阅关注；已经下载或入库的文件不会被删除。`，
取消键「先不」；结果按后端 `cleanup_job_id` 分两种——有清理任务说「已取消订阅，正在后台清理关联内容（可在任务中心查看进度）」，
否则「已取消订阅」。

**④ 单集状态词表对齐 iOS**：`已收齐`（原写成「已完结」）、`已收齐 · 洗版中（N）`、`追踪中 · 洗版中（N）`、
季头 `正片`（电影，且不带「N 集」计数）、`洗版中 N`；集行电影行首写 `正片` 而不是 E01。

**实测**：`arkts_check` 17 个改动文件 0 报错；`hvigorw assembleHap` → **BUILD SUCCESSFUL**。

**没验的**：
- 没起模拟器，没走装机/截图（第 1、2 步的界面合没合 iOS 仍是「代码层对齐」）；
- 「规则组」只显示组名，没显示 iOS 的「组名 · 洗到 X」——`RuleSetView` 模型里没有 `upgrade_target` 字段；
- 管理员取消订阅仍走单一确认（iOS 的「删下载任务 / 删媒体库文件」勾选面板属第 5 步的缺口页）。

### 第 8M 轮：订阅重构开工 · 第 1 步「全局溢出清扫」（卡片 margin + 行内 width('100%')）

按 `docs/subscription-refactor-plan.md` §3.1 开工。全局搜 `.margin({ left: Theme.pagePadding, right: Theme.pagePadding })`，
命中 6 处，全部是「区块/卡片挂 margin，自身或内部行用 `width('100%')`」的组合 —— 百分比按**屏幕宽**解析，
再加上 margin，整体就顶出屏幕右缘。

**改法**：横向留白从卡片的 `margin` 挪到外层**区块级 padding**（外层 `width('100%') + padding`，卡片
`width('100%')` 不再带 margin）。padding 是盒内计算的，不额外占宽，所以不再溢出。

| 文件 | 位置 |
| --- | --- |
| `subscriptions/SubscriptionsPage.ets` | `ScheduleRow` 的「当天议程」卡（外层新增 `Column` 包一层 padding） |
| `activity/ActivityPage.ets` | `WorkerWarning` |
| `activity/ActivityPage.ets` | `AttentionSection` 的「需要处理」卡 |
| `activity/ActivityPage.ets` | `ActiveSection` 的 `List` |
| `activity/ActivityPage.ets` | `RecentSection` 的 `List` |
| `library/IssueDrawerPage.ets` | `SearchField` 搜索框 |

**实测**：`arkts_check` 三个文件 0 报错；`hvigorw assembleHap` → **BUILD SUCCESSFUL**。

**没验的**：本轮未起模拟器，没量 `dumpLayout` 的右缘坐标（硬标准见计划 §5）；`ActivityPage` 里
`SessionsList` / `DownloadsList` / `StatsCard` 等**本来就没有横向留白**（满宽贴边），与已留白的卡片观感不一致 ——
不在本步口径内，留给后续统一。

### 第 8L 轮：海报墙列数按屏宽自适应（2~4 列）+ 媒体库详情「两个标题叠一起」

**① 一行几个海报：改成统一的自适应口径**
原来每个海报墙各写各的：媒体库详情按 `(屏宽-32+12)/152` 算（440vp 手机上会算出 **2 列**）、
收藏页和合集详情干脆**写死 2 列**，而且卡片宽度是硬编码的 `.width('48%') + margin right 2%`。

现在统一走 `Theme.posterColumns()`：扣掉页面左右留白后，按「每格约 118vp（含 12 间距）」估算再夹到 **2..4**：
- 360vp 小屏 → 2 列；**440vp 常规手机 → 3 列**（同 iOS 媒体库）；折叠屏 / 平板 → 4 列（封顶）

用到的页面：`LibraryDetailPage`（删掉它自己那份公式）、`FavoritesPage`、`CollectionDetailPage`；
后两者顺带把行内布局从「48% 宽」改成 `layoutWeight(1)` 等分 + **末行补等宽空位**（不满一行时卡片不会被拉宽）。

**② 媒体库详情顶部两个「电影库」叠在一起**
库头（22pt 库名 + 统计）是滚动内容的第一项，而自绘顶栏（17pt 库名 + 返回 + ⋯）是**浮在上面**的——
两者都从顶部开始画，于是大字小字重叠。修法：库头顶部留出顶栏的高度（`padding top: 52`）。

**实测（模拟器）**：媒体库详情的海报墙 **3 列**、等宽对齐、末行无拉伸 ✓；顶部只剩顶栏里那一个「电影库」，
库头（大标题 + 默认徽标 + 统计 + 作品/合集分段）完整可见、不再重叠 ✓。

**其它页面**：这一轮只碰海报网格与媒体库详情；播放器按用户要求不动。

### 第 8K 轮：整站页面结构改用华为官方那套（系统避让安全区）

**问题**：页面结构一直用的是「窗口铺满整屏（`setWindowLayoutFullScreen(true)`）+ 每个页面自己拿
`WindowInsets` 做上/下留白」。这套写法要求**每一页、每一种顶栏形态各自算对**，于是反复出事：
状态栏压标题、右上角胶囊盖电量、底部多出一条空带、系统标题栏与自绘顶栏行为不一致……
（8H~8J 三轮都是在修它的症状，不是在修根因。）

**改法（根因）**：回到华为官方的页面结构——**由系统避让安全区**：

1. `EntryAbility`：`setWindowLayoutFullScreen(false)`。内容区 = 安全区，任何页面都不可能压到状态栏 / 手势条；
   `WindowInsets` 仍然照旧记录（状态栏 / 手势条高度），但**只给沉浸式页面自己用**。
2. `Theme.statusBarInset` 恒为 **0**（系统已经避让）：所有 `PageTopBar` 与各页顶栏里的
   `+ Theme.statusBarInset` 自动退化成「不加」，**二十多个调用点一处都不用改**。
3. `Theme.tabBarInset`：`60 + WindowInsets.bottom * 2` → **72**（胶囊 48 + 抬起 12 + 呼吸 12；
   手势条已由系统让开，不再重复加）。`MainTabsPage` 的 `barBottomMargin` 同步改成 12。
4. **沉浸式页面**（要主动钻进状态栏的那几个）保持原观感：改成读**真实**的 `WindowInsets.top` 做顶部偏移，
   并显式 `.expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP …])`：
   - `library/LibraryItemDetailPage`（巨幅剧照）、`subscriptions/SubscriptionsPage`（顶部轮播）、
     `discover/DiscoverPage`（首屏大图）；`pages/WelcomePage` 本来就有 `expandSafeArea`，不用动。

**实测（模拟器）**：
- 「我的」：标题与右上角胶囊同一行、都在状态栏之下 ✓；
- 「媒体库」：大标题与右上角胶囊（片段 / ⋯ / 搜索）都在状态栏之下 ✓；
- 「发现」：标题与菜单在状态栏之下，首屏大图在其下方 ✓；
- **条目详情（沉浸式）**：巨幅剧照仍然铺到状态栏下面（时钟压在图上），返回键与右上角两个按钮
  按 `WindowInsets.top` 正确让开 ✓；
- 播放页：顶栏（返回 / 播放 · 转码 / 画中画）在状态栏之下 ✓；
- 底部悬浮页签仍贴在安全区底部、内容不再被压 ✓。

**意义**：这轮之后，「页面压状态栏 / 底部空带」这一类问题在**结构上**不会再出现——
新增页面只要用 `PageTopBar`（或普通顶栏）就自动是对的；要做沉浸式大图才需要显式 `expandSafeArea`。

**真机还需确认**：真机的状态栏/手势条尺寸与模拟器不同（值由系统给，逻辑不受影响），
但沉浸式页面的观感（大图铺进状态栏的幅度）建议在真机上再看一眼。

### 第 8J 轮：「我的」页不能滑动（用户报）

自绘顶栏是挂在 `List` **外面**的（`Column { TopBar; List(layoutWeight 1) }`）——顶部那条
（约 90vp，含状态栏避让）成了一个「拖不动」的死区；内容再多，从这一带往下拖也不滚。

**修法**：把顶栏挪进 `List` 的第一项（`ListItem() { this.TopBar() }`），整页合成一个滚动体——
在**任何一段**（包括标题行）都能拖动滚动，标题与右上角按钮随内容滚走（同 iOS 大标题的手感）。
另外给 `List` 加 `.edgeEffect(EdgeEffect.Spring)`：内容不足一屏时也有回弹反馈，不会觉得「滑不动」。
顶栏自己的左右留白去掉（外层 `List` 已给 16），只保留状态栏避让与上下呼吸。

**实测（模拟器）**：页面版式不变（标题与胶囊同一行、在状态栏之下）✓；
顶栏现在是列表第一项，拖动任意位置都作用在同一个 `List` 上 ✓（这台模拟器上会话少、内容不足一屏，
真机上会话多时才有明显滚动位移）。

### 第 8I 轮：底部「我的」页签在二级页里点不回去 + 标题与右上角按钮不在同一行（用户报）

**① 在二级页里点底部「我的」页签没反应**
`HdsTabs.onChange` **只在换页签时触发**，点已经选中的页签不触发 → 没有回退逻辑。
修法：另挂 `onTabBarClick(index)`——点到的就是当前页签时，取该页签的 `NavPathStack`（`NavStacks.of(title)`）
`clear()` 回根页（iOS 标准行为：在二级页点同一个页签 = 退回首页）。

**② 标题与右上角按钮不在同一水平线 → 试着改 Mini 标题，结果整行画进状态栏（溢出）**
- 原来用 Navigation 的系统标题栏（`Free` 大标题 + `menus`）：沉浸式布局下大标题在菜单**下一行**，
  用户要求同一行；
- 改成 `Mini` 后系统把这一行**画进状态栏里**（标题压住时钟、胶囊盖住电量图标），再给标题加
  `padding({ top: statusBarInset })` 也只是「压得少一点」——根上就是系统标题栏在沉浸式下不避让。

**最终修法**：这一页不再用系统标题栏，**顶栏自绘**（与其它页面的 `PageTopBar` 一个路子）：
`MorePage.TopBar()` = 左「我的」（28pt Bold）+ 右胶囊（扫码 / 搜索），整行
`.padding({ top: Theme.statusBarInset + 8 })`——标题与按钮同一行、且都在状态栏之下。
扫码 / 搜索 / 批准弹窗的逻辑从 `MoreNavHost` 搬进 `MorePage`（宿主只剩 `.hideTitleBar(true)` + Navigation 本体）。

**实测（模拟器）**：二级页（设置）里点底部「我的」→ 立刻回到「我的」首页 ✓；
「我的」页标题与右上角胶囊同一行、时钟与电量都完整可见（不再溢出）✓；
顺手看了媒体库 / 发现两个页签的顶栏，都没有压状态栏 ✓。

**教训**：沉浸式布局（`setWindowLayoutFullScreen(true)`）下**别依赖系统标题栏**——它不避让状态栏；
本项目统一走自绘 `PageTopBar` 才稳。

### 第 8H 轮：「我的」页右上角两个按钮跟背景没对齐

**现象**：扫码 / 搜索那个胶囊的右缘和下面的卡片（账号卡、服务器设置、最近会话）不在一条线上。

**原因**：胶囊用的是 `.margin({ top: Theme.statusBarInset, right: 12 })`，而页面内容的左右留白是
`Theme.pagePadding`（16）——差了 4vp，肉眼就是「没对齐」。

**修法**：右边距改用同一个 token：`.margin({ top: Theme.statusBarInset, right: Theme.pagePadding })`。
顺带把媒体库宿主的右上角胶囊也统一成 `Theme.pagePadding`（它原本写的是 8，同样和内容对不齐，
两个页签的右上角看起来不一样）。

**实测（模拟器）**：胶囊右缘与账号卡 / 服务器设置 / 最近会话卡的右缘在同一条竖线上 ✓。

### 第 8G 轮：服务器设置页（设置首页）间距与字号整理（用户：间距不整齐、字小一点）

`settings/SettingsIndexPage.ets` 原来同一份版式里混着几套尺寸（组间距 20、组头 13、主标题 16、
图标 20/列宽 28、行内边距 12、分隔线缩进 58 与图标列**对不齐**）。这轮统一成一套尺度：

| 部位 | 改前 | 改后 |
| --- | --- | --- |
| 组间距（List space） | 20 | **14** |
| 组头 | 13pt，左 4 / 上 10 / 下 4 | **12pt**，左 6 / 上 12 / 下 6 |
| 行内边距 | 16 / 12 / 12 | **16 / 上 11 / 下 11** |
| 图标 | 20pt，列宽 28 | **18pt，列宽 26** |
| 行内间距（Row space） | 14 | **12** |
| 主标题 / 副标题 | 16 / 12 | **15 / 12** |
| 右箭头 | 14 | **13** |
| 标题与副标题间距 | 3 | **2** |
| 分隔线缩进 startMargin | 58（与 26+12+16 的图标列不一致） | **54**（图标列 26 + 间距 12 + 左内边距 16，正好对齐文字列） |

「关于 MovieClaw」那一行用同一套值（它就是设置里的一项，不该另起一套）。

**实测（模拟器）**：三个分组（账号 / 媒体库 / 通知与集成）的组间距、组头留白、行高、图标列与
分隔线缩进都对上了，整体更紧凑、字号收了一档 ✓。

### 第 8F 轮：MCP 服务页按 iOS 重做（列表 + 端点详情三栏）

对照 iOS `MCPSettingsView` + `SettingsBMCPEndpointDetail` + `SettingsBMCPKit` / `SettingsBMCPToolCatalog` 重排
「设置 → MCP 服务」，全部鸿蒙原生组件。

**列表页**
- **总开关卡**：标题「启用 MCP 服务」+ 等宽副标题 `{base_url}/mcp/<端点>`（未配外部地址时写
  「（未配置外部地址）/mcp/<端点>」，同 iOS）+ 开关；
- 头行从卡里挪到卡外（同 iOS 的 section header）：「还没有 MCP 端点。」/「已配置 N 个端点。」+「＋ 新建端点」；
- **服务已关闭提示**（关着但还留着端点时）：说明「端点一律返回 404，配置与令牌保留」；
- **空态**照 iOS 的长说明（端点是给 AI 客户端的入口…每个端点工具目录独立）+「点上面的「＋ 新建端点」开始。」；
- **端点行**（`EndpointRow`，同 iOS `row`）：状态点（绿=在跑 / 灰=停用，停用整行 55% 透明）+
  名称 / `/mcp/{slug}` 等宽 / **服务标签**（最多 3 个，多的收成「+N」，未选写「未选服务」）+
  「N 个工具 · 一命令一工具 / 一服务一工具 · 最近调用」+ 右箭头；**整行可点进详情**；
- 下拉刷新（`Refresh`）替代原来散在行内的操作；原来每行的自检 / 轮换 / 删除 / 启停都收进了详情。

**端点详情**（iOS 是 push 出来的页面，这里用同内容的 `bindSheet` 承载：**概览 / 工具 / 设置** 三栏，分段切换）
- **概览**：端点地址 / 令牌前缀 / 工具数 / 调用形态 / 最近调用 / 服务（等宽值行）+ 缺服务提示 +
  连接自检（按钮 + 结果卡：通过与否、协议版本、工具数、耗时、warnings）；
- **工具**：按该端点勾选的服务算出的工具目录（`mcpEndpointsPreview`，工具名 + 说明）；
- **设置**：端点启停 + 「编辑配置」（复用原表单，**表单这次补上了编辑分支**：非空 `formId` 走
  `mcpEndpointsUpdate`，标题变「编辑端点」、按钮变「保存」）+ 轮换令牌 + 删除端点。

**实测（模拟器）**：MCP 列表页——总开关卡（含 `/mcp/<端点>` 地址前缀）、头行「还没有 MCP 端点。」+
「＋ 新建端点」、空态长说明、页脚提示 ✓。
**没验的**：端点行与详情三栏（这台服务器上还没有 MCP 端点，要建一个才能看）——建端点会写真实数据，留给真机。

**与 iOS 的一处偏差**：详情在 iOS 是 push 的独立页面，这里做成底部弹层（内容与分栏一致）。
要改成真正的 push 页面需要动 `router_map.json` 与新增页面文件，等有需要再换。

### 第 8E 轮：修两个用户报的问题（分段/开关点不动、页面每 15 秒闪一下）

**① 「滑块不跟手」——分段控件点完高亮不动（用户：不是一个，是你写都是这个问题）**

根因是 ArkUI 的规则：**`@Builder` 的参数默认按值传递，参数变化不会触发 UI 刷新**。
我此前把「分段/开关」都写成
```ts
@Builder ScopeSegment(label: string, selected: boolean, action: () => void) { … }
```
点一下状态确实变了，但 builder 拿到的还是旧值 → 高亮不动（开关同理：拨了又弹回去）。

修法：新增 `common/SettingsControls.ets`，把这几类控件做成 **`@ComponentV2` 组件**（`@Param` 是响应式的）：

- `SettingsSegmentChip`（一格分段）/ `SettingsTwoStateSegment`（两格：全部 / 指定）
- `SettingsSwitchRow`（左标题 + 说明，右开关）

替换范围：设备页「我的设备 / 全部成员」、手工令牌的「完全权限 / 仅限转码」、成员编辑页的
「全部媒体库 / 指定媒体库」「全部启用站点 / 指定站点」与三个能力开关、推送内容页两个事件开关、
播放设置页三个开关。**契约定死**：控件不持有状态，状态永远由页面持有、通过回调改（单向数据流）。

**② 页面时不时闪一下——是 15 秒的设备轮询在切加载态**

设备页为了在线状态会自动轮询（同 iOS `.polling(every: 15)`），但它调的是会 `loading = true` 的
`loadDevices()` → **每 15 秒整页变成「正在加载设备…」再切回来**，视觉上就是闪一下。

修法：
- 轮询与下拉刷新走**静默模式**（`loadDevices(silent: true)`，不碰 `loading`）；
- 顺手补上 iOS 的 `.refreshable`：设备页改成 `Refresh({ refreshing: $$this.refreshing })` 包住滚动区，
  下拉即静默重拉。

**实测（模拟器）**：点「仅限转码」→ 高亮**跟着移到右边**（修好前纹丝不动）✓；
在设备页连续 18 次（每秒一次 dump，跨过 15 秒轮询点）**一次都没出现加载态** ✓。

**待办（下一步）**：MCP 服务页与其附属页面按 iOS 重构。

### 第 8D 轮：IM 推送页按 iOS 重做（接入通道 / 推送内容 + 平台绑定弹层）

对照 iOS `PushSettingsView` + `SettingsBPushChannels` + `SettingsBPushContent` + `SettingsBPushBindSheet` 重排
「设置 → 消息推送」，全部鸿蒙原生组件。

**接入通道**
- **平台元数据**照 iOS `SettingsBPushChannel` 收在一个类里（label / summary / howTo / tokenHint / unbindMessage / boundToast 四家各一份），
  文案改一处就够；
- **跨平台一张列表**（原来是「先选平台再看该平台的账号」）：一次拉 weixin + telegram + discord + feishu，
  任一失败即整体失败（与其半张列表让用户以为某通道掉了，不如让他重试），归一成 `PushAccountRow`；
  ⚠️ ArkTS 是**标称类型**，微信的 `WeixinAccountView` 不能直接当 `ImAccountView` 用，中间加了一层 `PushAccount` 拷贝字段；
- 简介行（行内等宽 `/reset` `/stop`）、错误提示卡、头行「已接入 N 个账号。」+「＋ 新增通道」、
  行 = 图标方块 + 平台名 + **状态胶囊**（运行中绿 / 未运行灰 / 需重新绑定红）+ 详情（绑定人 · 绑定于 X；飞书是「群机器人 · 绑定于 X」）+「解绑」（危险色），
  空态卡（图标 + 标题 + 说明 + 主按钮）；
- **新增通道**：一张平台选择面板（平台名 + 一句话说明，同 iOS 的菜单内容），点选即开绑定弹层。

**绑定弹层按平台分派**（原来只有「token → 配对码」一种）
- **微信**：拉起挑战拿二维码（`RemoteImage` 渲染）→ **每 1.5 秒轮询**状态（pending / scanned / need_verify_code / confirmed / expired），
  `need_verify_code` 时出验证码输入 + 「确认」；过期给「重新生成二维码」；
- **飞书**：Webhook 地址 + 可选签名密钥 →「完成接入」（`channelsImFeishuBind`）；
- **Telegram / Discord**：沿用配对码流程（`我已完成，刷新`）；
- 绑定成功统一用该平台的 `boundToast` 提示并重拉列表。

**推送内容**：措辞照 iOS（`开始下载` / `入库完成` + 各自说明），加「测试推送」行（名称 + 说明 + 「发送测试」按钮），
事件开关仍是逐项即时保存（乐观更新、失败回滚）。

**实测（模拟器）**：分段标签、简介（`/reset` `/stop` 等宽）、「已接入 1 个账号。」+「＋ 新增通道」、
微信账号行（运行中胶囊 + 详情 + 解绑）✓；点「＋ 新增通道」→ 四家平台 + 一句话说明的面板 ✓。
**没验的**：四家的实际绑定回路（微信扫码要真手机、飞书要真 Webhook、Telegram/Discord 要真 token）。

**待办（下一步）**：MCP 服务页与其附属页面（弹层/编辑器）按 iOS 对应页面重构。

### 第 8C 轮：模型接入页按 iOS 重做（列表 + 接入表单）

对照 iOS `LLMSettingsView` + `SettingsBLLMProviderCard` + `SettingsBLLMProviderForm` 重排「设置 → 模型接入」，
全部用鸿蒙原生组件。

**① 列表页**（原来是「顶部一张带『添加』按钮的头卡 + 平铺卡片 + 底部一句说明」）
- **简介卡**：空态与非空态两套措辞（同 iOS `introText`）；
- **空态卡**：图标方块（`wand_and_stars`，48×48、圆角 14）+「还没有接入模型供应商」+
  「支持 OpenAI、阿里云百炼，以及任何 OpenAI 兼容端点（如自建 vLLM / Ollama）。」+ 全宽主按钮「接入模型供应商」；
- **供应商卡**（逐个照 `SettingsBLLMProviderCard`）：第一行「名称 + 状态胶囊」，
  第二行副标题（失败时直接写失败原因；否则「供应商 · N 个自定义模型 · 上次检查 X」），
  中间三行值（API 端点 / 连接测试模型 / User-Agent——只有用户覆盖过 UA 才显示），
  底部**三等分**「编辑配置 / 重新测试 / 删除」（删除红）；忙碌或测试中时「重新测试」灰显；
- **新增入口**挪到列表末尾（全宽「＋ 接入另一家供应商」，同 iOS），顶栏不再放「添加」；
- **状态胶囊**四态：已连接（绿）/ 测试中（蓝）/ 待测试（灰）/ 连接失败（红）+ 圆点（同 iOS `SettingsBLLMStatus`）；
  轮询沿用原有逻辑：有实例在待测试 / 测试中就 2 秒一轮，全都落定就停。

**② 接入表单**（对齐 `SettingsBLLMProviderForm`）
- 顶栏只有「✕ + 标题」（新建＝「接入模型供应商」，编辑＝「编辑「名字」」），**保存键挪到底部全宽**「保存并测试连接」；
- **供应商卡**：预设 chips + 选中供应商的提示（名称 + `providerHint`，如「聚合 Qwen / DeepSeek / Kimi / GLM」）
  + 脚注「保存后系统会自动测试连接。」；
- **连接信息卡**：`实例名（可选）`（占位按预设名）、`API 端点`（标签按预设分三种：`API 端点 *` 必填 /
  `API 端点（可选）` / 固定端点渠道**整行不显示**）、`API Key`（密码态 + 显示/隐藏眼睛，
  编辑时占位「出于安全，请重新填写」）、**高级设置**折叠里的 `User-Agent`（占位＝该预设的默认 UA）；
- **连接测试模型卡**：预设带目录就列成 chips（每个带能力短标：思考 / 档位可控 / 视觉 / 视频），
  自定义端点则退回手填输入框；
- 踩坑：`@Builder` 里不能声明局部变量（`const preset = …` 直接编译报「Only UI component syntax can be written here」），
  改成 `presetNameOf()` / `presetHintOf()` / `presetDefaultUaOf()` 这类取值方法。

**实测（模拟器）**：列表页简介 / 卡片（状态胶囊、副标题、值行、三等分操作行）/「＋ 接入另一家供应商」✓；
表单页「供应商 chips + 提示 + 脚注」「实例名 / API Key（带眼睛）」「连接测试模型 chips 带能力短标」
「底部全宽 保存并测试连接」✓；固定端点渠道按 iOS 隐藏端点与高级设置 ✓。

**还没做**：自定义端点的「自定义模型（填写参数）」子表单（iOS 的 thinking 方言 / 档位 / 模态那一套）、
实例名撞名时的自动加序号、`submitHint` 那类保存前校验提示。

### 第 8B 轮：编辑成员按 iOS 重做 + 重置密码改用「批准登录」样式的弹窗

**① 编辑 / 添加成员**（对照 iOS `EditMemberSheet` 逐节重排，原来是「用户名/密码/昵称 + 能力三开关 + 媒体库」三张卡）：
- **身份卡**（编辑态）：头像 + 昵称 + `@用户名` + 状态胶囊（已启用＝绿底绿字 / 已停用＝灰）；
- **基本信息**：编辑态用户名只读灰显，昵称可改；新建态给用户名 + 初始密码；
- **功能权限**：改成 iOS 的措辞（订阅追踪 / 资源搜索 / 一键下载）并加组脚注；
  **一键下载依赖资源搜索**——关掉搜索时它灰显不可点、且保存时按 `allow_search && allow_direct_download` 上报；
- **内容分级**：新增（`content_age_limit` + `allow_unrated`）——chips「不限 / 6 / 12 / 16 / 18 岁以下」，
  设了上限才出现「未分级的作品也给看」；保存时**不限 = 传 -1**（协议里 -1=取消上限、null=不改动，两者不能混）；
- **媒体库范围**：把开关换成分段（全部媒体库 / 指定媒体库）+ chips；「全部库」时**「指定成员」的库仍要单独勾选**，
  并且保存时只保留这些库的显式授权（iOS 的 `selectedModeIds` 口径）；
- **可搜索站点**：新增——只有开了资源搜索才出现；分段（全部启用站点 / 指定站点）+ chips，数据来自 `siteCatalog()`。
- 顺手删掉旧的 `PasswordSheet`（并用脚本修掉自己造成的重复代码块：`s.index` 取到比 `end` 更靠后的位置时切片会复制中段）。

**② 重置密码的结果改用原生弹窗**（新增 `settings/MemberCredentialDialog.ets`，与 `DeviceRenameDialog` / 批准登录同构）：
`openCustomDialog`（底部对齐、宽度=屏宽-32、遮罩 0.6、`surfaceRaised` 底、`cardRadius` 圆角、输入法避让）拉起；
卡片里是标题（`「小王吧」的新密码`）+ 账号 / 密码两行（点一下即复制，密码等宽字体）+
「密码只在这里显示一次…」的说明 + 「复制全部登录信息」次按钮 + 全宽「完成」主按钮。

**实测（模拟器）**：编辑面板六节都在，`一键下载` 在搜索关着时灰显、内容分级 chips 与脚注正常 ✓；
点「重置密码」→ 确认 → 弹出与批准登录同款卡片（标题 + 账号/密码 + 复制 + 完成）✓。

**没验的**：保存编辑（会真的改成员）、站点/媒体库 chips 的勾选与保存回路、新建成员的凭据弹窗。

### 第 8A 轮：成员卡片重构（最近活动挪到右上 / ⋯ 菜单摊成卡片底部操作条）

用户要求：**最近时间显示在原来右侧按钮的位置**，**按钮里的功能放到卡片底部、用横线竖线隔开**。

- 右上角原来那颗 `⋯`（`bindMenu`）换成 `Text(this.activityText(member))`（`最近 8 天前` / `从未登录`），右对齐、单行；
  该成员正忙（`busyId`）时这一角换来转圈（原来转圈是替换 ⋯ 的）。
- 卡片下半新增**操作条**：`Divider()`（横线，通栏）隔开身份信息与操作，
  然后五项等分平铺：`编辑 | 重置密码 | 停用/启用 | 让设备下线 | 删除` —— 项与项之间是 1px、16 高的**竖线** `Divider().vertical(true)`，
  每项 `layoutWeight(1)` 居中、上下 11 的内边距（点得到）；`删除` 用 `Theme.danger`。
- 身份信息里原来的「最近 N 天前」那行删掉（已挪到右上），卡片更紧凑。
- 顺带删掉 `MemberMenu`（菜单内容整体搬进操作条后它就是死代码了）。

**实测（模拟器）**：卡片右上显示 `最近 8 天前` ✓；底部操作条 `编辑 | 重置密码 | 停用 | 让设备下线 | 删除（红）`，
横线在上、竖线分格 ✓；点「编辑」照常弹出「编辑成员」面板 ✓。

### 第 7Z 轮：成员页整块内容垂直居中（用户问「为什么居中显示」）

**现象**：设置 → 成员，内容（成员账号卡 + 成员卡 + 页脚）整块挤在屏幕中间，上下各一大片空白。

**原因**：页面级滚动区写的是
```ts
Scroll() { Column() { … } }.layoutWeight(1).scrollBar(BarState.Off)
```
没设对齐 —— 而**通用属性 `align` 的默认值是 `Alignment.Center`**：内容比视口矮时，
整块内容就在滚动区里垂直居中了。设备页内容多、铺满视口，所以同样的问题一直没露出来。

**修法**：所有页面级滚动区显式 `.align(Alignment.TopStart)`（内容顶对齐、不足则留白在下方）：
`MembersSection` / `LlmSection` / `McpSection` / `NetworkSection` / `PlaybackSection` / `ScrapeSection` /
`WebhookSection` / `SettingsSectionPage`（设备页那个 Scroll）。

**实测（模拟器）**：成员页内容从标题下方开始排，空白落到下方 ✓。

### 第 7Y 轮：改名弹窗与「批准登录」弹窗同一套样式（用户要求）

上一轮只是把 `bindSheet` 收成了底部卡片，样式还是自己的；这轮直接换成**和批准登录一模一样**的呈现：

- 新增 `settings/DeviceRenameDialog.ets`（V1 `@Component`，与 `DeviceApprovalDialog` 同构）：
  `Column({space: 20}).padding(24)` + 标题 24 Bold + 副标题 13 textMuted + 输入框（`surfaceRaised`、圆角 12、高 52）
  + 全宽主按钮「保存」（`Theme.accent` 圆角 18，名字没变/为空时灰显）+ 全宽次按钮「取消」（`glassFill` 圆角 18）。
  改名请求与错误提示都在组件内部（与批准弹窗一样「一按到底」，失败就地报错）。
- 宿主 `SettingsSectionPage` 用 `openCustomDialog`（`DialogAlignment.Bottom`、宽度 = 屏宽 - 32、
  `keyboardAvoidMode: DEFAULT`、`autoCancel`、`maskColor` 0.6、`backgroundColor: surfaceRaised`、`cornerRadius: cardRadius`）
  拉起，参数与 `openApproval()` 逐项一致；关弹窗走 `closeCustomDialog(dialogId)`。
- 顺手删掉页面里那份只给 `bindSheet` 用的改名代码（`renameText` / `renameBusy` / `saveRename` / `RenameSheet`），
  弹层只剩「清理」一个，`DeviceSheet()` 不再分派。

**实测（模拟器）**：点「改名」→ 底部弹出与批准登录同款卡片（遮罩、标题、说明、输入框预填当前名字），
键盘弹出时卡片整体让位 ✓。

**补**（用户要求）：弹窗里两个按钮**水平并排**——`Row({space:10})` + 各 `layoutWeight(1)`：
左「取消」（glassFill）、右「保存」（accent，名字没变/为空时灰显）。

### 第 7X 轮：改名改成弹窗（用户：不要一整个页面）

**现象**：点「改名」弹出来的面板占满整屏，像跳了一个页面。

**原因**：`RenameSheet()` 的内容上写着 `.height('100%')`（那是它当年当页面用留下来的），
`bindSheet` 的 `SheetSize.FIT_CONTENT` 会照内容量高度 → 内容要 100%，面板就撑满整屏。

**修法**：去掉 `.height('100%')`，只留左右/上下内边距，面板按内容收成底部一张卡（同 MorePage 的重命名弹层）。

**实测（模拟器）**：「改名」弹层现在只占屏幕底部一块，上面的设备列表还看得见，输入框预填当前名字、取消/保存可用 ✓。

### 第 7W 轮：设备行图标对齐 iOS + 尾部改成「改名 / 注销」两颗竖排按钮

1. **图标按 iOS 的口径换一轮**（`DeviceText.symbolOf`，iOS 是 cpu / iphone / appletv / laptopcomputer /
   globe / play.rectangle / terminal）：鸿蒙原生符号库里没有 cpu/globe/terminal 的同名字形，
   取语义最接近的 —— 转码链路（worker、仅转码令牌）→ `memory_module`（芯片）、
   ios/android → `pad_and_iphone`、tvos → `TV_tv`、macos → `computer`、web → `website`（浏览器那个 www 球）、
   jellyfin → `video`、其余（命令行 / 令牌）→ `code`。
   踩坑：`ohos_ic_public_device_*` 这些名字在 `sysResource.js` 里查得到，但 **ArkTS 资源名校验不认**
   （编译报 `Unknown resource name`），只能用 `sys.symbol.*` 里已暴露的名字。
2. **尾部按钮**：原来的 `⋯`（`bindMenu`）换成**两颗竖排按钮**（右对齐）——`改名`（灰）在上、`注销`（红）在下；
   本机那行 `注销` = 退出登录（走 `AppModel.logout`），非本机走注销确认。
3. **图标垂直居中**：行的对齐仍是顶对齐（文字块顶对齐，同 iOS `HStack(alignment: .top)`），
   单独给图标 `.alignSelf(ItemAlign.Center)`，让它在整行里垂直居中（用户要求）。
4. **顺带修掉一个死代码**：`RenameSheet` 一直定义了但**从来没挂 `bindSheet`**（点「改名」没反应）。
   现在页面上的弹层合并成**一个** `bindSheet` + `sheetKind`（`'rename'` / `'cleanup'`）分发
   （同一个组件挂两个 `bindSheet` 只有最后那个生效——这个坑在 7Q 已经踩过一次）。

**实测（模拟器）**：每行图标换成手机 / 浏览器（www）/ 桌面等，且**在行内垂直居中** ✓；
尾部是竖排的「改名 / 注销（红）」✓；点「改名」弹出改名面板（预填当前名字、取消/保存）✓。

### 第 7V 轮：设备页对齐 iOS（用户：优化设备页，照 iOS，用华为原生组件）

对着 iOS `Features/Settings/Sections/DevicesSettingsView.swift`（691 行）重做「设置 → 设备」。原来只有
「批准入口 + 一个开关 + 一坨平铺列表 + 每行一个『注销』」，现在是 iOS 的四段结构：

1. **批准新设备登录**入口（`qrcode` 图标 + 「扫码或输入 Apple TV、Mac、命令行、转码器上的配对码」）。
2. **范围**：超管的「我的设备 / 全部成员」两格分段（iOS 的 `.pickerStyle(.segmented)`）。
   鸿蒙没有分段控件，`Toggle(Button)` 的默认配色不受控（实测未选中那格会变蓝），所以用两格 `Text` + 明确底色，
   跟输入区档位 chips 一个路子（仍是原生组件）。
3. **分组列表**（对应 iOS `groups`）：`网页与 App`（web/ios/tvos/macos/android）、
   `命令行与转码器`（cli/worker/manual）、`播放器`（jellyfin），每组带 iOS 原样的组脚注。
   - 行：**按形态给的图标**（`DeviceText.symbolOf(kind, scope)`：转码链路齿轮 / 手机 / 媒体中心 / 桌面 / 浏览器 / 播放器 / 命令行）
     + 在线（转码器长连接）时右下角亮绿点；名字（2 行，`BREAK_ALL` 断行）+ `本机` chip（accentSoft 胶囊）；
     两行说明用 `DeviceText.identityParts` / `activityParts` + `metaLine`（不断行空格，窄屏只在「· 」后换行）；
     超过 90 天没用过给一条黄色提示。
   - **⋯ 菜单**（原生 `bindMenu`）：`改名`（可改名时才给，接上原来就有的改名面板）/ `注销`（本机 = 退出登录，走 `AppModel.logout`）。
     踩坑：给图标另挂一个空 `onClick` 会把 `bindMenu` 的默认点击触发吃掉，点了不弹——去掉就好了。
4. **清理长期没用的设备**：只有本机一台时不出现；面板里滑杆选天数（7–365，`Slider`）+ **先 dry-run 列清单**，
   确认后才真清（对应 iOS `DeviceCleanupSheet`）。为此补了接口 `POST /auth/devices/cleanup` 与
   `DeviceCleanupRequest/Item/View` 三个模型（路径与字段照 iOS 生成层）。
5. **手工创建令牌**（超管）：说明 → 表单（名字 + 完全权限/仅限转码分段 + 「将获得」说明卡）→
   **一次性凭据卡**（两行环境变量 / 转码器启动参数，等宽可选中，`复制` / `仅复制令牌`；
   关闭要过确认「明文只显示这一次」）。地址优先「对外访问地址」（`appShow().external_url`），没配就回落当前服务器并说破。
6. **15 秒静默轮询**（iOS `.polling(every: 15)`）：在线状态会变（转码器连上/断开），页面开着时每 15 秒重拉一次，
   离开页面清定时器。

**实测（模拟器）**：设备页四段都到位——批准入口 ✓、分段（选中格是浅色强调底）✓、`网页与 App` 分组 + 每行图标/本机 chip/
两行说明 ✓、`播放器` 组 + 组脚注「Infuse 等 Jellyfin 客户端。」✓、`清理长期没用的设备` 入口 ✓、手工令牌表单与「将获得」卡 ✓；
`⋯` 弹出「改名 / 注销（红）」✓。

**没验的**：清理面板的 dry-run 清单与真清（要制造「长期没用」的设备才能看到效果）、令牌创建（会真建一枚令牌）、
改名/注销的成功路径。iOS 有而这边没做的：推送状态那行（`LoginDeviceView` 里没有 push 信息）。

### 第 7U 轮：长会话名只显示开头几个字（用户：能显示多少显示多少，剩下用…）

**现象**：会话标题形如 `微信 · o9cq801SDGl5FanX4t2Zq8g72Zko@im.wechat` 时，行里只显示「微信 · …」——
后面那一长串明明放得下大半行。

**原因**：ArkUI `Text` 默认断行规则（`WordBreak.NORMAL`）把长串英文当成**一个整词**，一个词放不下就整段丢掉，
只在省略号前留了中文字；`maxLines(1) + Ellipsis` 本身没问题。

**修法**：这些单行标题加 `.wordBreak(WordBreak.BREAK_ALL)` —— 先按字符填满整行，再在末尾省略：
- `pages/MorePage.ets` 的会话行标题；
- `common/PageTopBar.ets` 的页面标题（会话页顶栏用的就是它，同一个毛病）。

**实测（模拟器）**：「微信 · o9cq801SDGl5FanX4t2Zq8g72Zk…」——整行填满后才省略 ✓。

### 第 7T 轮：「我的」页不动态刷新最近会话（用户报）

**现象**：在「新会话」里建了会话、发完消息退回「我的」，列表里看不到新会话（要杀进程重进才有）。

**原因**：「最近会话」只在 `MorePage.aboutToAppear` 拉一次；而会话页是**压在上面的整屏页**
（`ShellChrome` 那套），退出回来时「我的」页不会重建 → 不重拉。

**修法**（照 `ShellChrome` 的单例写法）：新增 `agent/AgentSessionsSignal.ets`——`@ObservedV2` 单例 + `@Trace version`；
- 会话页：新建出会话时（拿到 `session_id`）和**离开会话页时** `bump()`（用户可能直接切页签走，不走 `aboutToDisappear`）；
- 「我的」页：`@Local sessionsSignal = AgentSessionsSignal.shared` + `@Monitor('sessionsSignal.version')` → `loadSessions()`。

**实测（模拟器）**：新会话发「动态刷新测试」→ 退回「我的」→ 列表**顶部立刻出现「动态刷新测试」**（带运行中小蓝点），无需重启 ✓。

### 第 7S 轮：新建会话发第一条消息报红（用户报「添加新会话会有红色报错」）

**现象**：进「新会话」发第一条消息 → 时间线里出现红色错误卡。

**定位（实测抓到原文）**：`request validation failed：body.session_id String should have…` ——
新会话没有 id，`send()` 仍把 `session_id: ''` 塞进 `session_start` 请求体，服务端 schema 要求它是合法会话号，
**空串直接 422**（这个 bug 在旧版就在，只是新会话页以前没人这么走）。

**修法**：**没有 id 就整条不带**（`payload` 只放 `content`，`sessionId` 非空才写 `session_id`），
服务端据此建新会话；id 由响应的 `session_id` 回填后再接事件流（原逻辑不变）。

**实测（模拟器）**：新会话发「现在几点」→ 不再报红，出现「思考中…」折叠块 + 实时耗时页脚，运行中被正常接上 ✓。

**顺带记一笔**：`SessionStartPayload` 里 `model` / `thinking_level` 同样是「没动过就不带」，语义一致。

### 第 7R 轮：「＋」补全（图片 / 技能）+ 输入框「/」技能快选（用户要求）

**① `＋` 补全**（对齐 iOS `AgentPlusMenu`）：面板里先「上传图片」三来源，再「使用技能」清单。
- 新增 `agent/AgentAttachments.ets`：照片图库（`photoAccessHelper.PhotoViewPicker`，多选、上限 4）、
  拍照（`cameraPicker.pick`）、选取文件（`picker.DocumentViewPicker`，只收 jpg/jpeg/png/gif/webp）；
  压缩口径同 iOS/Web——**最长边 2048、JPEG 0.85**（`image.ImagePacker`），**GIF 原样上传**（压缩丢动画帧）；
  没有原名时兜底「图片.jpg」。
- **上传用系统 http 的 multipart（`multiFormDataList`）而不是 `request.uploadFile`**：
  上传代理拿不到响应体，而这里必须读回 `attachment_id`（`POST /api/v1/sessions/attachments`，字段名 `file`，
  带 `Authorization: Bearer` + 分享 cookie）。
- 附件托盘（卡内、输入框上方）：缩略图 + 文件名 + ✕ 移除；上传中转圈、失败红字；一条消息最多 4 张。
- 发送时带 `attachments: [attachment_id…]`；发送成功清空托盘；**有图没字也能发**（`canSubmit` 同 iOS：
  没在跑、没有上传中的图、草稿或图片非空）。

**② 「/」技能快选**（对齐 iOS `AgentComposer.slashQuery` / `slashMenu`）：
- `AgentSkills.ets` 新增 `slashQuery(text)`（行首或空白后的 `/xxx`，`skill:` 前缀按名字过滤）与
  `slashMatches(query, skills)`（名称/描述包含即命中，最多 8 条）；
- 草稿一变就重算，命中就在**卡片内、输入框上方**展开「使用技能」面板（候选没到就先现拉技能清单）；
- 选中：抹掉输入的查询串，把 `/skill:名字 ` 插到草稿最前（服务端发送时展开，气泡里再渲染成 chip）。

**实测（模拟器）**：`＋` 面板 = 上传图片（照片图库/拍照/选取文件）+ 使用技能清单 ✓；
点「照片图库」拉起系统图库（`已选 0/4`，多选上限正确）✓；输入框敲 `/` → 卡内展开「使用技能」候选 ✓。
**没跑完的**：模拟器图库无照片，拍照无摄像头，所以「选图 → 压缩 → 上传 → 进托盘 → 随消息发出」这条链
（代码与头像上传同一套原生能力）要真机补验。

### 第 7Q 轮：输入区「＋」与模型入口点了没反应

**根因**：同一个组件上挂了**两个 `bindSheet`**（模型面板 + 技能面板）——ArkUI 只有最后挂的那个生效，
于是「模型」入口点了没反应；「＋」也只是刚加进 7P，用户手上那版还没有。

**修法**：合并成**一个** `bindSheet` + `sheetKind` 分发（`'model'` / `'plus'`，同 `LogsSection` 的 `SheetKind` 写法）：
`＋` → `sheetKind='plus'` 并现拉技能清单；模型文案 → `sheetKind='model'`；选模型后台`showComposerSheet=false` 收起。

**实测（模拟器）**：模型入口点开 → 模型清单（deepseek-v4-flash / vision-exp / 黑白 / z-ai/glm-5.3…）+ 当前模型的
「该模型不支持调节思考强度」✓；`＋` 点开 → 「使用技能」面板列出服务端技能（名称 + 描述）✓。

**教训**：一个组件只能挂一个 `bindSheet`；要多个弹层就用状态量分发内容，不要挂多个 modifier。

### 第 7P 轮：输入区改成 iOS 的「一张圆角卡」（用户：你看看 ios 的输入框啊）

对着 iOS `AgentComposer.body` 逐块重做（原来是一根整宽色带里放一个自成一体的输入胶囊 + 一行工具条，和 iOS 不是一个东西）：

```
┌─ 圆角 22 的卡（白 5% 底 + 白 7% 描边）──────────────┐
│  多行输入（最多 6 行，15pt，左/右 16、上 14、下 4）    │
│  ＋(44×44)   模型文案 + ▼(高 44)        →(44×44, 圆角12)│
└────────────────────────────────────────────────┘
       卡外是页面底色，左右各留 12
```

- 多行输入换 `TextArea`（iOS 是 `TextField(axis: .vertical).lineLimit(2...6)`）：`maxLines(6)` + 无边框透明底；
  占位文案也照 iOS 四态：`随心输入，描述一个新任务…` / 生成中 `生成中，可先输入下一条…` / 改写 `修改问题后发送，将从这里重新生成回答`。
- 工具行照 iOS：左边 `＋`（44×44，打开「使用技能」面板，点一项把 `/skill:名字 ` 插到草稿最前——
  同 iOS 的 chip 行语义，发送时服务端展开）；中间是**纯文字**的模型入口（`resolve(...)?.label ?? '模型'` + `chevron_down`，
  不再是自己画的小胶囊）；右边 44×44、圆角 12、白 10% 底的**发送箭头**（生成中变成一个小方块 = 停止，空草稿时 0.4 透明度）。
- 面板/弹层：模型面板（模型 + 思维链档位）、「＋」技能面板都用 `bindSheet` 挂在页面根 Column 上。
- **没做**：`＋` 里的「上传图片（照片图库 / 拍照 / 选取文件）」——鸿蒙客户端没有附件上传接口
  （iOS 走 `POST /sessions/attachments` multipart），要等接口层补上；也没做输入框里「/」触发的技能快选浮层。

**实测（模拟器）**：卡式输入区、占位文案、＋、模型文案 + ▼、发送箭头（空草稿半透明）都对上 iOS ✓；
点 ＋ 出「使用技能」面板并列出服务端技能（skill-creator + 描述）✓。

### 第 7O 轮：会话页四条用户反馈（贴底 / 字号 / 键盘顶起 / 切换模型）

1. **打开会话要停在最新回答**：懒加载列表一次 `scrollToIndex` 跳不到真底部（只量到可视区附近的行高），
   改成**贴底连打**（`startStick()` 每 70ms 到底一次、最多 8 次，直到高度稳定）；
   进页面后 1.5s 内为「贴底期」（`pinnedToBottom`），期间内容长高一直锚在底部，用户一拖动就结束。
2. **整体字太大**：正文档 17 → **15**（`AgentTimeline.TEXT_SIZE`），气泡 16→15、思考正文 14→13、
   「处理过程」头 14→13、工具行 13→12、页脚/压缩卡/续接卡/错误卡 13→12、流式光标 12→10。
3. **点输入框要像批准弹窗那样被键盘顶起来**：实测系统只保证**焦点输入框**露在键盘上方
   （`KeyboardAvoidMode.OFFSET` 只算焦点框），输入区里输入框**下面**的工具行（模型/档位/发送）会被键盘盖住。
   做法：`ChatPage` 自己 `window.getLastWindow()` + `win.on('keyboardHeightChange')` 记键盘高度（vp），
   键盘在时输入区底padding = **60**（不是整个键盘高：系统已经顶过一次，再加整个高度会把输入区顶到屏幕上三分之一；
   也不留小白条——那时手势条已被键盘盖住）。60 是实测值：输入框 + 工具行正好都露出来、且与键盘上沿留约 10vp。
   键盘弹出/收起同时触发贴底连打，最新消息始终留在输入框上方。页面消失 `off` 掉监听。
4. **切换模型等功能**（对齐 iOS `AgentComposer` 的模型胶囊 + `AgentModelMenu`）：
   - `agent/AgentCatalog.ets`：模型清单缓存（一分钟）+ `AgentThinking`（词汇表排序、控件形态：空=隐藏 / 一档=两格 / 多档=chips、
     档位展示名）；`AgentCatalog.displayLabel` 给胶囊文案。
   - `AgentTurn` 增加 `modelRef` / `thinkingLevel`（从 user 轨迹信封的 `model` / `thinking_level` 解析），
     输入区按最近一轮有值的显示「会话当前生效」的模型与档位（同 iOS `turns.last(where:)`）。
   - 输入区下方工具行：只留**一个** `模型胶囊`（`wand_and_stars` 图标 + 文案 + `chevron_down`）+ 右侧发送/停止——
     档位调节就在这个面板里（用户指出单独的「思维链」胶囊是重复入口，已去掉）；
     胶囊区 `layoutWeight(1) + clip`，宽度不够只压胶囊、不把发送键挤出屏幕（首次实测发送键被挤出过）。
   - 点胶囊开 `bindSheet` 面板：模型列表（选中打勾；选模型即收起并把档位清回默认）+ 思维链档位 chips
     （默认 / 各档；该模型没有档位菜单时显示「该模型不支持调节思考强度」）。
   - 线上值语义同 iOS：**没动过不传**（`model` / `thinking_level` 不带，服务端沿用上一条），显式选「默认」传 `default`；
     `sessionStart` / `sessionRetry` 都带上。

**实测（模拟器 127.0.0.1:5555）**：进会话直接停在最新回答（页脚「44s 复制」在底部）✓；字号收小后正文/列表/表格正常 ✓；
点输入框键盘弹起后**输入框 + 模型胶囊 + 思维链胶囊 + 发送都在键盘上方** ✓；点模型胶囊出面板、切到「deepseek-v4-flash（黑白）」后
胶囊文案与勾选同步、该模型显示「不支持调节思考强度」✓；表格（Grid）列边框对齐 ✓。

**仍未做**（iOS 有、鸿蒙这轮没做）：输入区的 `＋`（上传图片 / 技能快选菜单）、未接入模型时的锁定态与「去接入」引导、
模型/档位选择的本机记忆（iOS 写 UserDefaults，这里只保留在当前页面实例）。

### 第 7N 轮：会话内容显示对齐 iOS（用户要求：照 iOS 显示，只用原生组件）

**背景**：鸿蒙会话页原先只有一个简版渲染——「谁 + 时间」抬头 + 整宽灰底气泡，AI 正文也不解析 Markdown。
iOS 那边是 4 个文件、约 1500 行 Swift 的完整呈现模型。本轮按用户拍板的「全量对齐」补齐。

**新增（`entry/src/main/ets/agent/`）**
- `AgentTimeline.ets`：轮次模型（`AgentTurn` / `AgentSegment` / `AgentProcessItem` / `AgentToolCall` / `AgentStreamEvent`）
  - `AgentTimeline.turnsFrom(entries)`：轨迹 entries → 展示轮次（user 开新一轮、assistant 的 thinking/text/tool_calls 按序并入、
    tool 消息按 `tool_call_id` 合并回执、`finish_reason=aborted` → 已停止、没以「无工具调用的正文」收尾 → 已中断）；
  - `AgentTimeline.parse(entries, running)`：运行中的会话**丢弃最后一轮已落盘的局部产出**，整轮交给事件流重建（同 iOS，避免重复）；
  - `applyEvent(turn, event)`：SSE 事件归约（thinking/text 增量并入末尾段、tool_call_start/delta/result 增补工具条目、
    context_compacted / agent_done / agent_error / agent_cancelled）；
  - `processStatus` / `processSummary` / `duration` 与工具 `summary()` / `inputDetail()`（bash 取 command、其余美化 JSON）。
- `AgentMarkdown.ets` + `AgentMarkdownViews.ets`：自研块级 Markdown（标题/段落/围栏代码/有序无序任务列表含嵌套/引用/
  分隔线/GFM 表格/图片）+ 行内样式（粗体/斜体/删除线/行内代码/链接）。行内用原生 `Text + Span`（`textBackgroundStyle`
  做行内代码底色、`decoration` 做链接下划线），代码块横向滚动 + 右上角常驻复制（系统剪贴板 `pasteboard`），
  表格用 **Grid + `columnsTemplate('1fr 1fr …')`**（单元格自动撑满行高，列的描边才对得齐）。
- `AgentTurnViews.ets`：用户气泡（右侧、半透明、点一下浮现「改写/复制」、长按同款菜单、技能 chip + 图片缩略图）、
  「处理过程」折叠块（进行中实时状态 + 呼吸、完成后一句话总结、展开见思考与工具行）、工具行（单行摘要 + 进度/✓/✗，
  点开参数高亮 + 输出，输出高 176 可滚）、压缩卡片、续接卡片、错误卡、轮次页脚（进行中进度环 + 实时秒数；完成 = 已停止/已中断 +
  耗时 + 复制）、流式光标。
- `AgentMediaCards.ets`：`show_media_cards_v1` 生成式 UI（编号 → 现取 `libraryGet` / `discoverGetTitleDetails` /
  `subscriptionsGet` / `playbackItemInfo` 绘卡；加载与失败占同样尺寸，失败显示「未找到 ……」；点卡走 `libraryDetail` /
  `discoverDetail` / `subscriptionDetail` / `libraryItem` 原生路由）。
- `AgentTranscriptRows.ets`：轮次 → 段落级行（提问/处理过程/卡片组/每个 Markdown 块/光标/压缩/错误/页脚），
  间距逐值照 iOS（轮间 32、问答间 12、段间 10、段内块间 0.75em、标题前 +0.65em）。

**改写（`ChatPage.ets` 重写）**：消息列改为按行懒加载；发送走乐观轮次 + 事件流归约（80ms 批量合并，终态立即冲刷）；
断线按 `Last-Event-ID` 退避续传；「改写这条提问」进本地编辑态、输入框顶部提示条 + 取消、发送时二次确认后调 `sessionRetry`；
正文链接站内走原生路由（`/sessions/{id}`）、外链交系统浏览器；不再在消息列末尾塞全局 AppFooter（iOS 会话页没有）。

**实测（模拟器 127.0.0.1:5555）**：进入会话 → 用户气泡右侧、AI 整栏正文不套气泡 ✓；「已思考，调用 2 次工具」折叠块 ✓，
点开见思考正文与工具行 ✓；正文 Markdown：标题加粗、有序/无序/嵌套列表、行内代码底色、链接蓝色下划线 ✓；
轮次页脚「2 分 32 秒 + 复制」✓；表格用细描边渲染 ✓（当轮截图验证；随后把表格改成 Grid 撑满行高，未再抓到该会话复验）；
底部「回到最新消息」按钮 ✓；输入框不再被小白条压住 ✓。

**没验的**（这几条真机上要再走一遍）：`show_media_cards_v1` 生成式卡片（可达的两个会话里没有这类工具调用）、
改写重问（会真改服务端轨迹）、发送后的实时流式观感（要真发起一轮）、复制按钮点击。

### 第 7M 轮：整屏页底部操作条被系统手势条压住（用户报：会话页「说点什么…」被遮住）

**现象**：会话页底部输入框「说点什么…」和发送键下半截被屏幕最下面的**小白条**（系统手势条）盖住。

**根因**（真机/模拟器实测定位，不是布局溢出）：
- `EntryAbility` 开了 `setWindowLayoutFullScreen(true)`，窗口铺满整屏 → **系统不再替我们避让**，
  内容会画到状态栏 / 手势条下面（`common/WindowInsets.ets` 里已记录 top=38.9vp、bottom=28vp）。
- 会话页是**整屏页**（`ShellChrome` 已把悬浮页签栏收起），所以当初 Composer 故意**不留** `tabBarInset`
  （怕多出一条空带）——但连**手势条那 28vp 也没留**。
- 实测输入框 `y[2674-2821]`，屏幕高 2856px、手势条占最下 84px（2772-2856）→ 输入框底部 49px 落在手势条下面，视觉上就是「被遮住」。

**修法**：`theme/AppTheme.ets` 新增 `Theme.safeBottomInset`（= `WindowInsets.bottom`，只让手势条，
**不含**悬浮页签胶囊——别拿 `tabBarInset` 顶，那个会多出空带），三处底部**不滚动**的操作条改用它：
- `agent/ChatPage.ets` 的 `Composer()`：`bottom: 10 + Theme.safeBottomInset`；
- `library/RecycleBinPage.ets` 的 `ActionBar()`（回收站批量条）：`bottom: 8 + Theme.safeBottomInset`；
- `settings/LogsSection.ets` 的 `Footer()`（日志页脚注）：`bottom: 8 + Theme.safeBottomInset`。

**实测（模拟器）**：改后输入框 `y[2576-2723]`，底部离屏 133px、离手势条上沿 49px，输入框与发送键完整可见 ✓。

**教训**：整屏页里**任何贴底且不滚动**的元素都要自己让开 `WindowInsets.bottom`；
滚动列表的最后一项则用 `Theme.tabBarInset`（页签页）或额外 `+ safeBottomInset`（整屏页）。
**真机侧待用户确认**：震动只在**真的批准/拒绝了一条请求**时才触发，而那是用户自己的登录请求，
不便代按——请在手边的设备上按一次「批准登录」或「拒绝」感受一下（代码路径：`decide()` 成功后调用 Haptics）。
