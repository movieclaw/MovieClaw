# 智能订阅的记忆

日期：2026-10-21。来源：issue #883（智能选择抓到生肉；希望记住订阅方式）。

## 1 结论

智能订阅只有一套规则，默认值来自片子自己的信息；遇到新情况才问，一次订阅最多一个系统主动的问题；记住的东西都看得见、能删。

- **看得懂的语言**：作品语言看不懂时，资源的字幕或音轨里要有一种看得懂的语言。中文默认看得懂。第一次碰到某种语言时在订阅弹层里问一次，答案写进列表。
- **画质习惯**：管理员在弹层里改了画质，才问「以后也这样吗」，范围由用户自己点：只这部、所有电影/剧集、某地区、某播出平台（仅剧集）。
- **系列沿用**：同系列上一部单独改过的画质，续集自动沿用。

不做：音轨偏好、按剧情类型或评分的习惯、默认订阅模式开关（只要智能模式能避开生肉，就没有理由再切规则模式）。

## 2 作品事实与优先级

| 事实 | 管什么 | 来源 |
|---|---|---|
| 原始语言 | 字幕 | `media_metadata.original_language`；TMDB 把粤语记作 `cn`，映射为 `yue` |
| 电影或剧集 | 画质 | 订阅类型 |
| 地区 | 画质 | `origin_countries` 第一个 |
| 播出平台 | 画质 | 剧集 `studios` 第一个（电影的 studios 是制作公司，不用） |
| 系列 | 画质 | `series_key` |

同一项被多层设置时按固定顺序取：这部单独设的 > 系列上一部 > 平台 > 地区 > 电影或剧集 > 默认。每条习惯只存改过的那一项。弹层写明用了哪条（`quality_note`），被盖住的那条也写出来（`quality_shadow`）。

旧数据「上映很久的老片不用等」已由现有等待逻辑覆盖：等待从最早的站点发布时间起算，老片的截止早已过去。

## 3 字幕要求

- 判断「看得懂」按字幕**或**音轨：任一看得懂的语言都算。国语配音（`cmn`）算中文；看得懂英语的人，日语片带英文字幕也能看。
- 作品语言未知时不加要求。
- 只有看不懂的原版时不下载，状态 `awaiting_subtitles`，按原版的发布时间起算等待；到期改为 `deadline_awaiting_subtitles`，知会一次（事件 `subscription.awaiting_subtitles`），继续等，出现字幕版立即选择。
- 「这次先下原版」复用立即下载当前候选；之后追问「你看得懂 X 吗」，答看得懂就写进列表。
- 洗版与换源同样守字幕要求：不会把带字幕的版本换成看不懂的原版。

## 4 数据与接口

- `smart_memory`（单行）：`languages`、`habits`、`revision`（乐观并发，冲突与智能设置同一个 409 `SMART_VERSION_CONFLICT`）。
- `subscription.smart_overrides`：这部单独设的画质，或订阅时从同系列沿用来的画质。
- `SmartPolicy.watchable_languages`：非空即有字幕要求。
- 智能设置合并成一套：`GET/PUT /subscriptions/smart-defaults`（画质、洗版、最低要求共用；电影与剧集各一个等待上限）。迁移时两类画质不同的老用户，剧集的值变成一条「所有剧集」习惯，行为不变。旧的按类型接口保留。
- `PrepareView.smart`：解析结果与整句文案（问题、字幕行、画质来源、范围选项）。文案全部由服务端生成，Web、iOS、Android 只负责显示。
- 创建订阅新增 `smart_language_answer`、`smart_resolution`、`smart_source`、`smart_scope`、`smart_memory_revision`。
- `GET/PATCH /subscriptions/smart-memory`（管理员）：设一种语言看不看得懂，或删一条习惯。

## 5 谁能写记忆

记忆归管理员：成员订阅时只看到结论那一行，不被提问，传了选择也不写记忆。插件、助手、命令行和没升级的客户端只传旧字段：照常应用已有记忆，没问过的语言按「要字幕」处理，不写新记忆。

类型设置或记忆一变，所有智能订阅重新解析；在等的单元立即重新决策（只缩短不延长，手动延长保留），已经下载的不受影响。

## 6 验收

| 场景 | 位置 |
|---|---|
| 纯规则：语言、优先级、范围、等字幕、洗版守字幕 | `tests/matcher/test_smart_memory.py` |
| 接口：问一次、记住、冲突、成员、旧调用方 | `tests/api/test_smart_memory_routes.py` |
| 真实匹配链路：等字幕、到期知会一次、先下原版 | `tests/api/test_smart_memory_selection.py` |
| 设置合并迁移 | `tests/api/test_smart_memory_migration.py` |
| Web 浏览器全流程（含手机布局、成员） | `tests/e2e/test_smart_memory_browser.py` |
| iPhone / iPad 模拟器全流程 | `apps/apple/MovieClawUITests/SmartMemoryUITests.swift` |
| Android 模拟器全流程 | `tests/e2e/test_smart_memory_android.py` |

各端共用的隔离后端：`tests/e2e/_smart_memory_api_launcher.py`（假 TMDB，`/__lab/release` 模拟站点出现资源）。
