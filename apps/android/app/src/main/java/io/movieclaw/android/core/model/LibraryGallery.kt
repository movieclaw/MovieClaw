package io.movieclaw.android.core.model

import kotlinx.serialization.Serializable

/**
 * 图廊里的一张图（服务端 `LibraryGalleryImageView`）：条目的海报 / 剧照 / 分集剧照 / 章节场景图之一。
 *
 * 除了看图还能一键进条目详情、从这一帧起播——所以每张图都带着它在作品里的坐标
 * （季集号 + 起播秒数），拼播放地址时不必再查详情。
 */
@Serializable
data class LibraryGalleryImageView(
    /** poster=海报 / backdrop=横幅剧照 / still=分集剧照 / chapter=章节场景图 */
    val kind: String = "poster",
    /** 图片地址：本地资产相对路径或 TMDB 图床绝对地址（走缓存代理） */
    val url: String = "",
    /** 宽高比：海报按真实像素或 2:3 惯例，剧照与场景图 16:9（瀑布流排版用） */
    val aspect: Float = 1f,
    /** 角标文案：海报 / 剧照 / 第 N 集 / 章节标题 */
    val label: String = "",
    val season: Int? = null,
    val episode: Int? = null,
    /** 章节场景图对应的起播秒数（「从此处播放」）；其它图为 null */
    val tSeconds: Double? = null,
)

/** 图廊按条目分的一组（一部作品的全部图），墙上是一段标题 + 一面瀑布流（服务端 `LibraryGalleryGroupView`） */
@Serializable
data class LibraryGalleryGroupView(
    val mediaItemId: Long = 0,
    /** 这一组的详情落点库：收藏跨库，每组各带自己的落点库 */
    val libraryId: Long = 0,
    val kind: String = "movie",
    val title: String = "",
    val year: Int? = null,
    /** 当前观看者是否收藏了这部作品：瓦片右上角的心形角标与灯箱里那颗心的初始态 */
    val isFavorite: Boolean = false,
    val images: List<LibraryGalleryImageView> = emptyList(),
)
