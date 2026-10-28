# 内容语言：发现页与媒体库跟随界面语言

> 状态：已实施（2026-10-27，基于 main 540b06981）。
> 接续 [i18n.md](i18n.md) §8.5 / D9。交互演示：https://claude.ai/artifact/KzB4T4sK3mimPY1CxQDEdh

## 1. 一句话

**看到的跟界面语言，写下来的跟媒体库语言。** 不新增任何设置项。

| | 现在 | 改后 |
|---|---|---|
| 发现页片名、简介、类型 | 管理员设的元数据主语言，全站一样 | 读者的界面语言（中文 → `zh-CN`，English → `en-US`） |
| 媒体库片名、简介 | 主语言 | 读者的界面语言；TMDB 没有这条译文时显示主语言 |
| 类型、国家、视频类型等标签 | 刮削语言的名字，或写死的中文 | 读者的界面语言 |
| 分集标题、文件夹与文件名、NFO、海报文字、Jellyfin 输出、通知与日志 | 主语言 | 主语言（不变） |
| 设置页 | 「元数据语言」 | 同一张卡片改名「媒体库语言」，说明写清它只管写下来的东西 |

主语言为什么不跟人：它写进数据库和磁盘，全家共用一份。跟着人切换，文件夹就会因为谁打开过而改名。

## 2. 读者语言

唯一入口 `movieclaw_api/i18n/content.py`：

```python
READER_TMDB_LANGUAGE = {"zh-Hans": "zh-CN", "en": "en-US"}
CONTENT_LANGUAGES = ("zh-CN", "en-US")   # 刮削时顺手存下的两份译文

def reader_language() -> str             # current_locale → TMDB 语言标签
def display_title(item) -> str           # 媒体库片名
def display_overview(translations, overview) -> str|None  # 媒体库简介
def display_genres(kind, names, ids, scrape_language) -> list[str]
```

`current_locale` 由中间件按 `Accept-Language` 协商；不带语言头的老客户端协商为 `zh-Hans`，
因此老客户端看到的一切与升级前相同。

## 3. 发现页按读者语言取数

- `services/media_discover.py` 的 `get_media_service()` 从「全站一个」改为「每种读者语言一个」
  （`dict[语言, MediaDiscoverService]`，最多两个）。领域包 `MediaDiscoverService` 本身不改签名：
  它构造时绑定的语言就是这份实例的语言，进程内缓存天然按语言分开，不必给每个缓存键加前缀；
- 院线地区仍取 `effective_region()`；`invalidate_discover_language()` 关闭全部实例（初始化页改地区时用）；
- 豆瓣不动：各端的豆瓣入口与统一搜索的「全部」照旧（英文读者也能搜到豆瓣，片名保持来源语言，
  这是国际化时定下的口径，见 tests/e2e/test_i18n_search_results_browser.py）；
- 发现页详情的国家、语言、视频类型：领域包改为同时给出代码（`MediaFacts.country_codes` /
  `language_code`；`MediaVideo.kind` 先放 TMDB 原始类型），接口层按读者语言出名字（§5）。豆瓣详情没有代码，原样透传。

## 4. 媒体库存中英两份片名简介

### 4.1 存

刮削的详情请求本来就带 `append_to_response=translations`，`fetch_media_profile` 从里面取
`CONTENT_LANGUAGES` 里**与主语言不同语种**的那几份（主语言是 zh-CN 时只取 en-US，反之亦然；
主语言是日语时两份都取），**零额外请求**：

| 字段 | 取值 |
|---|---|
| 片名 | 该语言译名；没有且该语言就是原声语言 → 原名；英文再回落已有的 `english_title` 规则 |
| 简介 | 该语言译文；没有就不存（tagline 详情页不展示，不存） |

落两列（都可空，NULL = 存量未刮过或没有译文）：

- `media_item.title_translations`：`{"en-US": "Severance"}`——片名进列表（海报墙、继续观看、人物页），
  放身份表免得列表查询为它 JOIN；
- `media_metadata.overview_translations`：`{"en-US": "..."}`——简介只在
  详情 / 大图出现，放展示表，海报墙查询不带它。

**主语言那一份从不存**：显示时就不需要知道条目的主语言是什么，也不会因为 NFO 吸收、手动改名后
库内原列与 TMDB 译文不一致而显示错版本。存量随定时刷新自愈，不写回填任务。

### 4.2 显示

`display_title(item) = item.title_translations[读者语言] or item.title`，简介同理。
读者语言与主语言同语种时字典里没有这一项，走原列——中文账号看中文库与现状逐字节相同。

套用的出口（都是「给人看」的视图）：海报墙卡片、图片墙分组、条目详情、首页大图（简介、类型）、
继续观看 / 下一集、人物页作品、播放器顶栏标题。操作提示、通知、日志、NFO、Jellyfin 兼容接口
仍用主语言原列。

分集标题与简介不做：分集文本不在 translations 里，每多一种语言每季要多请求一次。

### 4.3 片名 Logo 与宣传语

片名 Logo 是库语言的文字图（《阿甘正传》的 Logo 写着「阿甘正傳」），宣传语没有存译文。条目有
读者语言的片名、正以那门语言显示时（`in_reader_language`：`title_translations` 里有读者语言），
条目详情、首页大图、继续观看、刷片四个出口的 `logo_url` 返回空、刷片的宣传语返回空；各端本来
就有「没有 Logo 就显示文字片名」的分支，客户端不用改。还没刷出译名的条目照旧给 Logo——文字片名
也是库语言，换掉只会更难看（NAS 实测里的《醉梦》）。主语言那份从不存，中文读者看中文库照旧。

代价：英文读者看中文库时，有译名的条目 Logo 都换成文字片名，库里挑到的本来就是英文 Logo 的也一起藏掉。
以后可在同一次图片请求里顺手记一个读者语言的 Logo，再按读者挑（零额外请求，多一列与是否下载
到本地的取舍），本次不做。

订阅页不动：它的片名同时是手动选种的搜索词，Logo 与片名保持同一语言。

## 5. 代码类标签按读者语言出

领域包只给代码，接口层按 `current_locale` 出名字：

- **类型**：发现页由 TMDB 按读者语言返回（§3）。媒体库详情 / 首页大图用 `display_genres`：
  读者与条目 `scrape_language` 不同语种且有 `genre_ids` 时走 `genre_label()`；同语种原样用库内名字；
- **国家 / 语言**：地区用 `media_labels.country_label()` 的消息键，没有键的用 Babel/CLDR 本地化名（只在发现页
  详情这么做，筛选面板沿用 `country_label` 原样给代码）；
  语言用已有的 `labels.language_name()`（TMDB 的 `cn` 归到粤语）。与筛选面板、订阅页同一套名字，
  中文读者因此会看到两处小变化：「中国香港」→「香港」、「汉语普通话」→「中文」；
- **视频类型**：`media.videoKinds.*` 五个消息键（预告片 / 先导预告 / 片段 / 花絮 / 幕后）；
- 删除 `movieclaw_media/service.py` 里写死的 `_COUNTRY_NAMES`、`_LANGUAGE_NAMES` 与 `_VIDEO_KINDS` 中文值。

## 6. 顺带修的搜索词问题（主语言或界面不是中文时才发作）

1. **PT 站搜索词丢中文名**：召回词是 `(english_title, title, original_title)`（`subscription/wanted_search.py`），
   主语言为英文时 `title` 是英文，中文名就没了，而内置站点全是中文 PT 站。改为
   `(english_title, 中文译名, title, original_title)`，中文译名取 `title_translations["zh-CN"]`；
   中文库里这一项不存在，召回词与现状完全相同；
2. **豆瓣收敛用错语言**：豆瓣条目转 TMDB 时用主语言搜索，再拿 TMDB 返回的片名比对豆瓣中文名
   （`media_library.resolve_douban`）。主语言为英文时比的是英文名，必然对不上。改为固定 `zh-CN`。

还有一个是本方案自己带出来、合并前补上的：

3. **「搜索资源」丢中文名**：条目详情与发现页详情的「搜索资源」以显示出来的片名为主词、再加英文名和
   原名。片名按读者语言显示后，英文读者的主词成了英文，外语片的中文名就没了。两个详情接口各加一个
   可空字段 `chinese_title`（只在显示出来的片名不是中文时给），网页的 `titleSearchAlso` 把它加进同搜词，
   顺序与召回词一致（英文名 → 中文名 → 原名）。库详情的中文名：库语言是中文时取 `title`，否则取
   `title_translations["zh-CN"]`；发现页详情取同一次请求 translations 里的 zh-CN 译名，华语片取原名。
   iPhone / 鸿蒙发现页详情的同名按钮暂未接，老客户端忽略该字段。

## 7. 设置页

`settings.scrape.metadataLanguage` 改为「媒体库语言 / Library language」；说明改为：
「写进媒体库的语言：文件夹与文件名、NFO、海报文字、分集标题，以及外部播放器看到的信息。
每个人看到的片名和简介跟各自的界面语言。」优先级与回落规则不变。

## 8. 兼容

- 接口：除两个详情接口各多一个可空字段 `chinese_title` 外，OpenAPI 与 main 一致（导出比对），其余只是
  字段的值按读者语言变化；Apple 生成为可选 `String?`，安卓解码器开了 `ignoreUnknownKeys`；
- 老客户端（不带语言头）：协商为 `zh-Hans`，与升级前相同；
- 迁移：两列可空 JSON，`add_column` / `drop_column`，不重建表。

## 9. 明确不做

分集译文、海报按人、默认字幕按人、新设置项、初始化页改动、各端豆瓣入口。上一版盘点过的分级与
院线地区写死 CN、看得懂的语言写死中文、AI 字幕目标语写死 `chs`、默认字幕按库语言等，只影响
非中文家庭且各自可独立修，本次不纳入。

## 10. 验证

- 单测：发现页同一接口先英后中结果不同、各自缓存；译文只存非主语种、空字段不存；显示选择
  （有译文用译文、无译文回落、同语种走原列）；类型 / 国家 / 视频类型按语言出名字；
  召回词在中文库与现状一致、英文库插入中文名；豆瓣收敛固定 zh-CN；
- 端到端（真实后端进程 + 假 TMDB 服务 + 真实 HTTP 请求）：
  1. 中文账号：发现页、媒体库详情、首页大图与升级前一致；
  2. 英文账号、中文库：发现页英文；媒体库片名简介英文、分集中文、类型国家英文；
  3. 主语言 en-US 的库：中文账号看到中文片名简介；召回词含中文名；
  4. 不带语言头的请求（老客户端）：中文。
