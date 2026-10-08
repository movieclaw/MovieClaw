package io.movieclaw.android.core.model

/**
 * TMDB 类型名称（跨库墙的标题）：与 Web `lib/genre-labels.ts` / iOS `GenreLabels` 同表，
 * 27 项逐条一致；唯一真相源在后端 `movieclaw_media.genres`（上游有跨端契约测试比对完整名称表）。
 *
 * 首页类型色块的 `label` 由服务端下发（`/libraries/kinds/{kind}/genres`），这份表只服务一个场景：
 * 墙页从路由里只拿到 genre id（`kind/movie?genre=18`），标题要按 id 反查名字——与 Web/iOS
 * 在墙里查表是同一条路；查不到时用上游的兜底文案「类型 N」。
 */
object GenreLabels {
    val names: Map<Int, String> = mapOf(
        28 to "动作",
        12 to "冒险",
        16 to "动画",
        35 to "喜剧",
        80 to "犯罪",
        99 to "纪录",
        18 to "剧情",
        10751 to "家庭",
        14 to "奇幻",
        36 to "历史",
        27 to "恐怖",
        10402 to "音乐",
        9648 to "悬疑",
        10749 to "爱情",
        878 to "科幻",
        10770 to "电视电影",
        53 to "惊悚",
        10752 to "战争",
        37 to "西部",
        10759 to "动作冒险",
        10762 to "儿童",
        10763 to "新闻",
        10764 to "真人秀",
        10765 to "科幻奇幻",
        10766 to "肥皂剧",
        10767 to "脱口秀",
        10768 to "战争政治",
    )

    fun nameOf(id: Int): String = names[id] ?: "类型 $id"
}
