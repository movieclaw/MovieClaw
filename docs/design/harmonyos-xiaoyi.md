# 小艺集成：意图框架 + 小艺建议 + 小艺智能体（鸿蒙端）

> 状态：**草案**（待评审，未落码）。
> 相关设计：[mcp-server.md](mcp-server.md)（服务端 MCP 工具面——智能体路径的桥）、
> [agent-cli-integration.md](agent-cli-integration.md)（产品内 Agent 服务目录）、
> [subscription.md](subscription.md)（订阅域）、
> [playback-history-sync.md](playback-history-sync.md)（观看进度同步——续播卡片数据源）、
> [push-payload.md](push-payload.md)（推送协议——新集事件源）、
> [cloud-push.md](cloud-push.md)（推送事件清单）。
> 适配工程：`apps/harmonyos`（API 24，Navigation + 路由表，全仓无 Push Kit）。

---

## 0. 一句话与效果速览

把鸿蒙端接入小艺三件套——**意图框架**（小艺对话/搜索直达「继续播放、播放指定片、
订阅、搜片」）、**小艺建议·习惯推荐**（继续观看卡片 + 订阅新集上架提醒，补齐鸿蒙端
没有的推送位）、**小艺智能体**（云插件桥接服务端既有 MCP 工具面，免开 App 对话式
搜片、订阅、查在播）——服务端 v1 零新增能力，全部复用已上线的 API 与 MCP 端点。

**完成后的体验（用户视角）**

| 场景 | 用户做什么 | 发生什么 |
| --- | --- | --- |
| 续播 | 对手机说「小艺，继续播放」 | MovieClaw 打开，接着上次进度放 |
| 播指定片 | 「用 MovieClaw 放《流浪地球》」 | 命中唯一结果直接进详情/播放；多结果进搜索结果页 |
| 订阅新片 | 「帮我订阅《XXX》」 | 跳到订阅确认页，人工点「订阅」（不静默落库） |
| 继续观看卡片 | 看一眼负一屏 | 需先打开设置里的「允许小艺根据观看记录推荐」开关（默认关）；小艺建议出「继续观看《小城良方》」，点卡片直达续播 |
| 新集提醒 | 负一屏瞥一眼 | 「你订阅的《XXX》第 N 集上架了」卡片（有延迟；真正实时的提醒依赖 Push Kit，见 §5.2） |
| 免开 App | 在小艺里问「《小城良方》更到几集了」 | 小艺直接回答集数，不用打开 MovieClaw |
| 免开 App | 「帮我订阅《XXX》」 | 小艺确认后落库（或引导打开 App 确认，见 §6.4） |

---

## 1. 目标与非目标

**目标**

1. 语音 / 小艺搜索直达（P1）：继续播放、播放指定影片、订阅影片（半程，落到
   确认页）、打开订阅墙 / 订阅详情、站内搜索。
2. 小艺建议·习惯推荐（P2）：常用接续（继续观看卡片，带续播位置）、常用推新
   （订阅新集上架提醒）。
3. 小艺智能体（P3）：在小艺里对话式「帮我订阅《XXX》」「《小城良方》更到几集了」
   「现在谁在看什么」，云插件直连服务端 MCP 端点。
4. 订阅影片全链路（用户点名诉求）：语音→确认页、智能体→subscriptions 工具、
   小艺建议→新集卡片，三个入口全覆盖（§7 横向汇总）。

**非目标（v1 明确不做）**

- 不做端侧 A2A（API 24 才起步的新机制，生态太新，先观察）。
- 不做 MCP 的 OAuth（沿用 mcp-server.md §2.3 的静态 Bearer 立场）。
- 不做成员级智能体授权（权限面原则与 MCP 端点一致：v1 只对管理员）。
- 语音不做全自动订阅：订阅是重操作，语音只到确认页，订阅按钮仍人工点
  （智能体路径同样带确认，见 §6.4）。
- 不做播放控制类意图（暂停/快进）：App 在前台时系统播控已覆盖，语音绕一圈无增益。
- 不做小艺输入法、拖拽给小艺等散点集成。
- 不做 Push Kit 接入（实时推送是独立议题，见 §5.2 的取舍记录，不并入本方案）。
- v1 智能体工具面不含 `session` 域、不暴露 `search_torrents`；停订 / 删除类
  操作不进工具面，一律回复 App 深链（§6.1 / §6.2，评审意见 #1 #2）。
- P2 上报默认关闭：设置里显式开关「允许小艺根据观看记录推荐」，不开则零上报
  （§5.1，评审意见 #3）。

---

## 2. 小艺入口调研（截至 2026-11）

### 2.1 三条集成面

| 集成面 | 机制 | 系统入口 | 版本门槛 |
| --- | --- | --- | --- |
| 意图框架 Intents Kit | 配置文件（预定义意图）/ 装饰器（自定义意图，CodeGenie 生成五类装饰器） | 小艺对话、小艺搜索、小艺建议 | 配置文件 API 11+；装饰器 API 20+ |
| 小艺建议·习惯推荐 | 意图共享：`insightIntent.shareIntent` 上报意图执行数据（动作模式、百分比、实体） | 负一屏 / 桌面卡片 | 同上 + 小艺开放平台意图注册 |
| 小艺智能体 Agent Framework | 小艺开放平台建智能体 + 云插件（公网 HTTPS）/ 意图插件；App 内 FunctionComponent 拉起 | 小艺对话（免开 App） | FunctionComponent API 20+（6.0.0(20)） |

习惯推荐三分类：**常用接续**（长视频、音乐、有声、课程——本产品正中长视频）、
常用复访（导航、打车、小游戏）、常用推新（资讯、短视频）。

### 2.2 硬约束（来自官方文档与 FAQ 的实测坑）

1. **意图框架代码不可被 ArkGuard 混淆**——否则小艺拉起 App 即闪退
   （FAQ：意图框架调试助手联调闪退）。意图执行文件与路由参数对象必须进
   keep 清单；这条 CI 守护不了（混淆只在发布构建触发），进发布检查单。
2. **意图插件注册需团队账号**（个人账号不能在 DevEco 里 Add Intent Plugin）；
   装饰器生成依赖 DevEco Studio 6.0.0 Beta2+ 的 CodeGenie（HarmonyOS Ask）。
3. **小艺开放平台审核一致性**：后台识别的「APP 名称」必须与 AGC 应用名一致
   （FAQ：意图注册审核 APP 名称不一致）。
4. **云插件域名强制公网 HTTPS/WSS**，URL 强制精确匹配、不能带尾巴
   （FAQ：云插件调用云函数报错域名只支持 HTTPS 和 WSS）——只有配置了
   外部地址（server_addresses）的实例用得了智能体，局域网实例明确写进文案。
5. **上线链路长**：本地联调 → AGC 上架 → 小艺开放平台注册意图 → 审核 → 上线。
   意图不是发了就能用，审核周期要排进里程碑（§9）。

### 2.3 与现有资产的对接点

- **路由表**：意图落点全部是既有 NavDestination（`router_map.json`：
  `player`、`libraryItem`、`subscriptionWall`、`subscriptionDetail`、
  `discoverDetail`、`search`、`searchResults`）。意图执行器只做「意图参数 →
  路由参数」的翻译 + `pushPathByName`，不复刻页面逻辑；路由参数对象沿用
  `LibraryRouteParams.ets` 的既有模式（条目 / 订阅带 id）。
- **服务端 MCP**（已上线，mcp-server.md）：管理员自建端点勾选服务域
  （search / discover / subscriptions / playback / session / jobs…），静态
  Bearer、无状态 POST、工具面可按端点精选——智能体要的能力已经全在，
  服务端 v1 零新增。
- **鸿蒙端无推送**：全仓鸿蒙端无 Push Kit 集成（iOS 走 APNs 中继 + 端到端加密，
  鸿蒙没有对应链路）。「新集提醒」在鸿蒙端是空缺——小艺建议的常用推新
  恰好补这个位（§5.2 给出两条路径的取舍）。
- **观看进度**：续播位置已同步（playback-history-sync），习惯推荐卡片要的
  「当前百分比」有现成数据源；首页 `ResumeAccessory` 即「最近续播」数据源，
  ContinuePlay 无片名时直接复用。
- **App 内 Agent**：`chat` 路由（ChatPage）已有产品 Agent（session 域），
  小艺智能体与其共用同一套服务端能力，不另起炉灶（§6.6）。

### 2.4 前置条件清单（平台与账号侧——评审后第一周确认项）

以下任何一条**不满足只影响上线，不影响开发与本地联调**（意图框架调试开关
不要求上架）：

| # | 事项 | 为什么需要 | 确认方式 |
| --- | --- | --- | --- |
| 1 | AGC 账号形态（个人 / 团队、实名认证状态）——**已确认：团队/企业账号** | 意图插件注册需团队账号；个人账号需先升级或入队 | 登录 AGC 管理中心查看 |
| 2 | 鸿蒙 App 的 AGC 上架状态——**已确认：审核中**（上架由我们自己操作，不依赖外部确认） | 意图注册审核要求应用已上架 AppGallery；未上架则 P1/P2 无法正式上线，只能本地联调 | AGC「我的应用」列表 |
| 3 | DevEco Studio 6.0.0 Beta2+ 与 CodeGenie 可用性 | 装饰器生成走 CodeGenie（HarmonyOS Ask） | 本机 DevEco 版本 |
| 4 | 小艺开放平台入口与垂类 | 意图注册入口：管理中心 → 生态服务 → 智慧服务 → 小艺开放平台；影视垂类 schema 以注册页当日为准 | 登录开放平台预览 |
| 5 | 审核一致性 | 开放平台后台识别的「APP 名称」= AGC 应用名，否则驳回 | FAQ faqs-intents-kit-2 |

---

## 3. 总体架构

```
小艺（对话 / 搜索 / 建议 / 智能体）
  │
  ├─ P1 意图框架 ──> 意图执行器（App 内，不可混淆，统一一个执行文件）
  │                    │  解析意图参数 → 片名解析（本地库优先）→ pushPathByName（既有路由表）
  │                    ▼
  │               player / libraryItem / subscriptionWall /
  │               subscriptionDetail / discoverDetail / search / searchResults
  │
  ├─ P2 习惯推荐 ──> 意图共享上报（shareIntent：EXECUTED + currentPercentage + 实体）
  │                    ▲  进度 = playback-history-sync；新集 = 订阅 diff（前台轻轮询，§5.2）
  │                    ▼
  │               小艺建议卡片（继续观看 / 新集上架）──点卡片──> 回到 P1 意图
  │
  └─ P3 智能体 ──> 小艺开放平台「MovieClaw 智能体」
                     │  云插件（公网 HTTPS）
                     ▼
                 服务端既有 MCP 端点 /mcp/xiaoyi（静态 Bearer）
                     │  工具面：search / discover / subscriptions / playback
                     │        （四域只读 + subscriptions_create，§6.1-2 排除清单）
                     ▼
                 既有 API（鉴权 / 校验 / 错误形态一字不改）
```

三层各自独立交付：P1 是 App 内改动，P2 依赖 P1 的意图定义，P3 是云侧配置 +
（视调研结论）一个服务端转译薄层，三者可分别提测上线。

---

## 4. P1 意图框架：语音与小艺搜索直达

### 4.1 意图清单与用户体验（v1 全量六个）

| 意图名 | 触发示例 | 落点（既有路由） | 无结果时的行为 |
| --- | --- | --- | --- |
| ContinuePlay | 「继续播放」「接着看《小城良方》」 | `player`（带片目 id + 续播位置） | 无片名 → 取最近一条续播（ResumeAccessory 同数据源）；有片名但无进度 → 按 PlayItem 走 |
| PlayItem | 「用 MovieClaw 放《流浪地球》」 | 本地库唯一命中 → `libraryItem`；多命中 → `searchResults` | 本地库无 → `discover` 搜索结果页（`discoverCollection`） |
| SubscribeVoice | 「帮我订阅《XXX》」 | `discoverDetail`（订阅确认区） | 搜不到 → 落 `search` 让用户手动输入 |
| OpenSubscriptions | 「看看我的订阅」 | `subscriptionWall` | — |
| OpenSubscriptionDetail | 「《XXX》的订阅详情」 | `subscriptionDetail`（订阅 id） | 片名在订阅列表中无匹配 → `subscriptionWall` |
| SearchInApp | 「在 MovieClaw 里搜 XXX」 | `search` | — |

**片名解析策略（PlayItem / SubscribeVoice / OpenSubscriptionDetail 共用）**：

1. 先查本地媒体库（library 搜索，带别名/译名归一，沿用服务端既有搜索的归一逻辑）；
2. 本地无 → 查 discover（TMDB/豆瓣），拿到片目 id；
3. 唯一命中直达落点；多命中落 `searchResults` / `discoverCollection` 让用户选；
4. 全程服务端既有接口，意图执行器只编排，不新增搜索逻辑。

### 4.2 意图参数定义

| 意图名 | 入参（意图参数） | 出参 |
| --- | --- | --- |
| ContinuePlay | `title?: string`（可选片名） | 无显式出参；副作用=跳转 `player` |
| PlayItem | `title: string`（必填片名） | 跳转目标路由 |
| SubscribeVoice | `title: string` | 跳转目标路由 |
| OpenSubscriptions | 无 | — |
| OpenSubscriptionDetail | `title: string` | 跳转目标路由 |
| SearchInApp | `keyword: string` | — |

参数尽量少：语音识别的片名归一、错别字容错全部交给服务端既有搜索（它已有
别名/译名/拼音容错），意图侧不做 NLP。

### 4.3 工程落地（鸿蒙端）

**(a) 意图注册文件**（`entry/src/main/resources/base/profile/insight_intent.json`，
装饰器生成后同构）：

```json
{
  "insightIntents": [
    {
      "intentName": "ContinuePlay",
      "domain": "VideoDomain",
      "intentVersion": "1.0.0",
      "srcEntry": "./ets/insight/XiaoyiIntentExecutor.ets",
      "uiAbility": { "ability": "EntryAbility", "executeMode": ["foreground"] }
    }
    // …其余五个意图同构，domain 一致，srcEntry 同一个执行文件
  ]
}
```

- 全部 `executeMode: foreground`（v1 意图都要见 UI，无后台执行场景）。
- `domain` 与垂类命名以小艺开放平台注册页当日为准（自定义意图垂域），
  此处 `VideoDomain` 为示意。

**(b) 意图执行器骨架**（`entry/src/main/ets/insight/XiaoyiIntentExecutor.ets`，
统一一个执行文件）：

```text
onIntent(name, params):
  route = switch (name):
    ContinuePlay          -> resolveContinuePlay(params.title)   // 最近续播或片名解析
    PlayItem              -> resolvePlayItem(params.title)
    SubscribeVoice        -> resolveDiscoverDetail(params.title)
    OpenSubscriptions     -> static("subscriptionWall")
    OpenSubscriptionDetail-> resolveSubscriptionDetail(params.title)
    SearchInApp           -> static("search", { keyword: params.keyword })
  navPathStack.pushPathByName(route.name, route.param)
```

- 执行器不 import 页面组件，只产出「路由名 + 参数」，与页面解耦；
- 片名解析（§4.1）封装为独立 service（纯函数 + 服务端调用），可单测；
- **冷启动时序**：意图可能出现在 App 未启动（EntryAbility onCreate）或后台
  （onNewWant）两种时机，NavPathStack 在首页 Navigation 就绪前不可用。执行器
  引入一个**待跳转队列**：就绪前缓存意图，就绪后依次执行——避免冷启动直接
  push 丢失（也规避渲染期改状态引发的崩溃）。意图与 App Link（§d）走同一个
  分发器与同一个队列。

**(c) 页面零改动承诺**：六个意图不新增/修改任何 NavDestination 页面，
只做路由跳转与参数传入——评审 diff 应该只有 `insight/` 新目录、`module.json5`、
`router_map.json` 不动。

**(d) App Linking**（`module.json5` 补 `skills > uris`，当前只有
`entity.system.home`）：

```json5
"skills": [
  { /* 既有 home 项不动 */ },
  {
    "entities": ["entity.system.browsable"],
    "actions": ["ohos.want.action.viewData"],
    "uris": [{ "scheme": "https", "host": "<appgalley 核验域名>" }]
  }
]
```

小艺搜索结果与 P2 卡片可直开路由；域名要过 AGC AppGallery Connect 的域名校验，
具体 host 评审时定。

**(e) ArkGuard keep 清单**（混淆规则文件追加）：

```
# 意图框架代码不可混淆（faqs-intents-kit：拉起即闪退）
-keep file path "entry/src/main/ets/insight/.*"
-keep file path "entry/src/main/ets/library/LibraryRouteParams.ets"
```

（规则文件路径以当前工程混淆配置为准；`LibraryRouteParams` 因被意图执行器
引用一并 keep。）

### 4.4 联调与上线 checklist

1. 真机开「设置 → 系统 → 开发者选项 → 意图框架调试」；
2. 用意图调试助手 Agent 联调（API 20+；设备不要求上架）；
3. AGC 上架 / 确认上架状态（§2.4-2）；
4. 小艺开放平台注册意图（入口见 §2.4-4；APP 名称一致性见 §2.4-5）；
5. 提审 → 根据驳回意见修正 → 上线；
6. 发布构建（含混淆）真机冒烟：小艺拉起六意图各一次（进 release-prep 检查单）；
7. 灰度顺序：先只提审 `ContinuePlay` 一个意图摸全流程（审核时长、卡片形态先见
   实物），其余五个意图复用同一套流程批量提审。

---

## 5. P2 小艺建议：习惯推荐卡片

### 5.1 常用接续（继续观看）

**体验**：负一屏/桌面小艺建议出「继续观看《小城良方》S01E18」，点卡片 →
ContinuePlay 意图 → `player` 带续播位置（闭环回 P1）。

**隐私开关，默认关闭**（评审意见 #3）：shareIntent 会把片名、季集、观看进度
和观看时段上报到小艺平台——私人媒体库的观看记录是敏感数据，必须用户显式
同意。设置新增「允许小艺根据观看记录推荐」开关，**默认关**；打开时一句话
说明会上报什么；关闭时**完全不上报**（shareIntent 零调用，含进度与完成态）。
开关只管 P2 上报，不影响 P1 语音直达。

**上报数据映射**（`insightIntent.shareIntent`，字段名以平台当日 schema 为准，
下表是数据来源的映射关系）：

| 共享字段 | 来源 |
| --- | --- |
| `intentName` / `intentVersion` / `identifier` | 意图注册信息 + 平台标识 |
| `intentActionInfo.actionMode` | `EXECUTED`（起播成功后上报） |
| `intentActionInfo.currentPercentage` | `position / duration`（playback-history-sync 的续播位置） |
| `intentActionInfo.executedTimeSlots` | 起播/停止时段 |
| `intentEntityInfo.entityId` | 片目 id（剧集带季集） |
| `intentEntityInfo.displayName` | 片名（剧集格式：`小城良方 S01E18`） |
| `intentEntityInfo.logo` | **v1 不带**（评审意见 #3）——避免把服务端地址 + 带签名的图片 URL 交给平台，签名有效期也免管；后续版本再评估 |
| `intentEntityInfo` 其余字段（时长、描述等） | 片目元数据 |

**上报时机与节流**：

| 时机 | 说明 |
| --- | --- |
| `player` 起播成功 | 一次（actionMode=EXECUTED） |
| 进度落盘（playback-history-sync 心跳） | 节流上报：每 30s 或百分比变化 >5% 才报一次 |
| 播放结束 | 上报完成态（percentage=100） |

### 5.2 常用推新（订阅新集上架）——关键取舍

鸿蒙端无 Push Kit，App **无法被服务端实时唤醒**，新集感知有两条路径：

| 路径 | 机制 | 实时性 | 工作量 | 结论 |
| --- | --- | --- | --- | --- |
| **轻路径（v1 采纳）** | App 前台期间低频拉「订阅 diff」（15 分钟级，复用订阅页既有数据接口），检测到新集上架 → 上报意图共享（推新类） | 卡片有延迟（下次打开 App 后才可能出现） | 小（App 内一个前台定时器 + diff 判断） | **v1 采用** |
| Push Kit 路径 | 服务端对接华为推送（AGC 凭证、公网回调），推「小艺通知」/通知卡片 | 实时 | 大（服务端新增一条推送通道 + 凭证管理，工作量对标 iOS 的 cloud-push 链路） | 独立议题单独立项，不并入本方案 |

v1 用户文案写明：「新集提醒可能在你下次打开 App 后出现」。轻路径零服务端改动；
diff 接口若订阅页现有接口不够用，允许加一个只读聚合接口（服务端唯一可能新增点，
评审时定）。

**价值与预期**（评审意见 #4）：轻路径的 diff 只在 App 前台跑——检测到新集时
用户本来就在 App 里，卡片「离 App 提醒」的价值有限。接受它作为 v1 的占位，
但验收预期写死：**v1 的新集卡片不承诺实时、不承诺离 App 提醒；真正有用的
新集提醒依赖 Push Kit（实时推送），那是独立立项**。P2 验收只看「前台同步后
卡片出现且点开直达」，不拿「及时提醒」当验收项。

### 5.3 字段以平台当日 schema 为准

shareIntent 实体字段（影视垂类）以小艺开放平台注册页当日为准，本文不预写死
（参考音乐垂类的官方样例结构：意图名/版本/标识 + actionMode + 时段 + 百分比 +
实体名/ID/展示名/logo/时长）。

---

## 6. P3 小艺智能体：免开 App 的对话控制

### 6.1 形态与桥接

- 小艺开放平台创建「MovieClaw 智能体」：人格化 prompt（媒体管家）+ 工具集。
- 桥接 = **云插件 → 服务端既有 MCP 端点**：
  1. 管理员在「设置 → MCP 服务」新建 `xiaoyi` 端点，勾四域：`search`、
     `discover`、`subscriptions`、`playback`（复用 mcp-server.md §4.1 的
     服务目录勾选）。**v1 不勾 `session` 域**（评审意见 #1）：session 是
     产品内 Agent 的长链任务入口，能间接调动 Agent 的全部能力，等于把
     「最小工具面」又放大回管理员全权限；而令牌要交给小艺云侧（第三方
     平台）保管，v1 从严——等智能体跑稳后再单独评估。
  2. **工具级排除（本方案唯一服务端改动，已拍板）**（评审意见 #1 #2）：
     MCP 端点目前按域勾选，`search_torrents` 与 subscriptions 的停订/删除类
     写工具都在域内，域级勾选排除不掉。给 mcp-server 加「端点排除工具」
     清单——通用安全增强（任何对外端点都能按工具级收口），单独小 PR，
     用例：被排除工具不出现在 tools/list、直接调用被拒。`xiaoyi` 端点排除
     `search_torrents` + subscriptions 的全部写工具（只保留
     `subscriptions_create`）；智能体降级纯只读仅作备选存档；
  3. 云插件 URL 填公网地址（server_addresses 已有外部地址设置）；
  4. **云插件契约与 MCP 的协议差异**（鉴权头、JSON 形态）——P3 开工首日实测
     后二选一：
     - **直连**：云插件能透传 Bearer + 自定义头 → 直接填 MCP URL，零代码；
     - **转译薄层**：不能透传 → 服务端新增 `POST /api/v1/xiaoyi/plugin`
       （云插件协议 ↔ MCP JSON-RPC 转译，无状态、静态 Bearer、进 OpenAPI、
       长出 `mclaw xiaoyi …` 命令，对齐 mcp-server 管理面风格；预估 ≤150 行
       + 契约测试）。

- 鉴权：静态 Bearer（端点令牌），立场与 mcp-server.md §2.3 一致；令牌可随时
  吊销 = 智能体随时断供，管理面已有。
- 权限：v1 管理员级——智能体能做的事等价于管理员在命令行做的事
  （mcp-server.md §1 的既有立场，不重开讨论）。

### 6.2 工具面（端点勾选后的展开工具示例）

| 域 | 展开工具示例（默认 expand_tools=true，§mcp-server 4.1） | 智能体用途 | v1 边界 |
| --- | --- | --- | --- |
| search | `search_titles` | 片名→片目 id 解析 | `search_torrents` 不暴露（§6.1） |
| discover | `discover_trending`、`discover_detail`… | 「找一部 2024 年的科幻片」 | 只读 |
| subscriptions | `subscriptions_list`、`subscriptions_detail` 等只读工具 + `subscriptions_create` | 订阅查询与创建（核心诉求） | 只读 + create；**停订 / 删除工具不进工具面** |
| playback | `playback_activity`… | 「现在谁在看什么」 | 只读 |

**工具面即权限边界**（评审意见 #2）：prompt 约束与 `destructiveHint` 注解对
模型只是建议，不是安全边界。v1 的安全边界做在工具面上：`xiaoyi` 端点的工具面
= 四域只读 + `subscriptions_create`（依赖 §6.1-2 的排除清单），`search_torrents`
与停订 / 删除类工具**不在工具面里**——模型想调也调不到。唯一保留的写操作
`subscriptions_create` 执行前必须确认；确认不了（平台无确认卡片）就回复 App
深链落到 P1 的订阅确认页，与语音路径同一落点、体验统一。`destructiveHint`
注解保留给将来若放开的工具。

### 6.3 智能体 prompt 骨架（云侧配置，示意）

```text
你是 MovieClaw 的媒体管家，帮管理员打理自建媒体库。
- 只读类问题（查订阅、查在播、查更新）直接用工具回答；
- 建订阅前必须先复述片名+季集请求确认，确认后才调用；平台没有确认卡片时，
  回复 App 链接让用户在 App 的订阅确认页完成；
- 停订、删除类操作你没有对应工具，一律回复 App 链接引导用户去对应页面；
- 搜不到结果时如实说明，不编造片名或链接；
- 涉及账号/令牌的操作一律拒绝并引导去 App 设置页。
```

（prompt 是行为引导，不是安全边界——真正的边界在 §6.2 的工具面构成。）

### 6.4 典型对话（含订阅确认）

| 用户说 | 处理（工具面见 §6.2） | 确认策略 |
| --- | --- | --- |
| 「帮我订阅《XXX》」 | `search_titles` 解析片目 → 复述片名+季集请求确认 → `subscriptions_create`；平台无确认卡片 → 回复 App 深链落到 P1 订阅确认页（与语音路径同一落点） | **必须确认** |
| 「《小城良方》更到几集了」 | `subscriptions_detail` → 回复集数与缺口 | 只读，无确认 |
| 「现在谁在看什么」 | `playback_activity` → 回复在播 | 只读，无确认 |
| 「找一部 2024 年以后的科幻片」 | `discover_*` → 回复清单 | 只读，无确认 |
| 「把《XXX》的订阅停了」 | **无工具**（停订不在 v1 工具面）→ 回复 App 深链到 `subscriptionDetail`，人工操作 | 深链兜底 |

### 6.5 与 App 内 Chat 的关系

- App 内 `chat` 路由（ChatPage）已有产品 Agent（session 域）；小艺智能体是
  「免开 App」入口。v1 智能体不勾 session 域（§6.1），两者暂不共享工具面；
  智能体跑稳后再评估接入 session——届时复用同一套能力，不另起炉灶。
- App 内用 FunctionComponent 挂「问小艺」入口拉起智能体：可选，v1 不做。

---

## 7. 订阅影片专项（横向汇总）

| 入口 | 体验 | 服务端改动 | 鸿蒙端改动 |
| --- | --- | --- | --- |
| 小艺语音 | 「帮我订阅 XXX」→ `discoverDetail` 确认页，人工点订阅 | 0 | SubscribeVoice 意图 |
| 小艺智能体 | 对话订阅，确认后 `subscriptions_create` 落库；停订/删除回复 App 深链 | 1~2（工具级排除小增强 + 视调研转译薄层；MCP 已上线） | 0（云侧配置） |
| 小艺建议 | 新集上架卡片 → 直达播放 | 0~1（视 diff 接口需要） | 新集事件 → 意图共享上报 |
| 既有入口 | discoverDetail / 订阅墙（不变） | 0 | 0 |

---

## 8. 风险与开放问题（评审要拍的板）

1. **AGC 上架状态**（§2.4-2）——**已确认：审核中**（上架由我们自己操作，
   不依赖外部确认）。通过则 P1/P2 按正常口径推进；被驳回则先修复再提，
   P1 上线顺延——不影响开发与本地联调。
2. **团队账号**（§2.4-1）——**已确认：团队/企业账号**，满足意图插件要求，
   无阻塞。
3. **云插件契约**（P3 前置调研）：请求/响应契约、鉴权头、能否透传 Bearer——
   决定桥接层是零代码还是 ≤150 行转译。开工首日实测。
4. **审核周期**：意图注册 + 智能体上架审核时长未知，先提 ContinuePlay 摸底；
   里程碑按「一次驳回 + 修复」预留。
5. **影视垂类 schema**：shareIntent 实体字段以开放平台注册页当日为准，不预写死。
6. **误操作面**（评审意见 #2 后已收紧）：智能体的安全边界做在工具面——只读
   四域 + `subscriptions_create`，停订/删除无工具、深链兜底（§6.2/§6.4）；
   语音路径的确认页兜底不变。
7. **混淆回归**：keep 清单是长期维护项，CI 守护不了；发布检查单
   （release-prep）加一条「小艺拉起冒烟」。
8. **局域网实例**：无公网地址的实例用不了智能体——与 mcp-server.md 的代价
   声明口径一致，文案写明。
9. **冷启动时序**（§4.3-b）：意图在 Navigation 就绪前到达的排队问题，是 P1
   实现里最容易翻车的点，联调用例必须覆盖「杀进程后语音拉起」。
10. **工具级排除清单**（§6.1-2，评审意见 #1 #2 的落地依赖）——**已拍板**：
    走 mcp-server「端点排除工具」清单（独立小 PR）：本身就是通用安全增强
    （以后任何对外端点都能按工具级收口），改动小、可单测，也保住语音/对话
    「订阅这部」的核心体验；用例：被排除工具不出现在 tools/list、直接调用
    被拒。智能体降级纯只读仅作文档备选。不阻塞 P1/P2。

---

## 9. 里程碑与验收（DoD）

| 阶段 | 内容 | 预估 | DoD（完成即验收） |
| --- | --- | --- | --- |
| P0 前置确认 | §2.4 五项逐条确认 | 2 天 | 五项结论写回本文档（上架状态/账号形态落定） |
| P1a | ContinuePlay 单意图全流程（含提审） | 3 天开发 + 审核等待 | 真机：说「继续播放」→ `player` 带续播位置；杀进程后语音拉起同样成立 |
| P1b | 其余五个意图批量 | 1 周 | 六意图全语音用例真机走查 + 录屏取证（沿用 PR #1242 标准）；混淆包冒烟六连 |
| P2 | 习惯推荐上报（接续 + 推新） | 1 周 | 隐私开关默认关、关闭时零上报；打开后负一屏出继续观看卡片、点卡片续播闭环；新集卡片（前台同步后）直达；上报节流不超约定频率 |
| P3 | 智能体 MVP（含云插件实测） | 2 周 | 小艺里一条龙：订阅（确认后落库）→ 查更 → 查在播；停订请求返回 App 深链；令牌吊销后智能体即断供 |

---

## 10. 测试策略

- **单测**：意图执行器「参数 → 路由参数」翻译表（六意图 × 有/无片名 × 命中/多命中/
  无命中）；片名解析 service（mock 服务端搜索）；待跳转队列（就绪前入队、就绪后
  依序执行、去重）。
- **上报体测试**：shareIntent 数据映射（百分比换算、节流阈值、100% 完成态），
  mock 平台 schema；**隐私开关关闭时 shareIntent 零调用**（含进度与完成态，
  §5.1 开关的守护测试）。
- **联调**：意图调试助手 Agent（不要求上架）。
- **真机**：语音全链路走查 + 录屏取证；**冷启动用例**（杀进程后语音拉起）单独
  覆盖；发布混淆包小艺拉起冒烟（防 §2.2-1）。
- **服务端**：工具级排除清单（§6.1-2）生效性测试进 `tests/mcp_server/`
  （排除的工具不出现在端点 `tools/list`、直调被拒）；若需转译薄层（§6.1-4），
  契约测试进 `tests/`（对齐 `tests/mcp_server/` 风格）；diff 聚合接口
  （若 §5.2 需要）常规 route 测试。
