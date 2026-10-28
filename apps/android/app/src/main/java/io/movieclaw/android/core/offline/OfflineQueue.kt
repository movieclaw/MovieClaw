package io.movieclaw.android.core.offline

/**
 * 下载顺序（docs/design/offline-download.md §5.5，iOS `OfflineQueue`）：进行中的单元排成一队，顺序就是优先级。
 * 一次只下一个，排第一、能下的那个独占带宽，其余的排着（不是给后面的限速）
 */
object OfflineQueue {
    data class Entry(val fileId: Long, val mediaItemId: Long, val inQueue: Boolean)

    /** 下载顺序：调过的按编号，没调过的按加入时间（Unix 秒，远大于编号，自然排在调过的后面）；同键按季集、文件号 */
    val order: Comparator<OfflineUnit> = compareBy<OfflineUnit>({ it.queueOrder ?: (it.createdAt / 1000.0) }, { it.createdAt }, { it.season }, { it.episode }, { it.fileId })

    /** 进行中的单元（含暂停、失败）：正在下的排最前（它确实在别人前面，比如继续下载的那集排在它前面、但不打断它），其余按下载顺序 */
    fun entries(units: Collection<OfflineUnit>): List<Entry> =
        units.filter { it.isActive }
            .sortedWith(compareBy<OfflineUnit> { it.state != OfflineUnit.State.downloading }.then(order))
            .map { Entry(it.fileId, it.mediaItemId, it.inQueue) }

    /** 排在它前面、还会轮到的有几个 */
    fun ahead(fileId: Long, queue: List<Entry>): Int {
        val index = queue.indexOfFirst { it.fileId == fileId }
        return if (index < 0) 0 else queue.subList(0, index).count { it.inQueue }
    }

    /** 「优先下载」有没有意义：已经排在最前、正在轮到它的不用；暂停、出错的能（优先顺带继续） */
    fun canPrioritize(fileId: Long, queue: List<Entry>): Boolean {
        val entry = queue.firstOrNull { it.fileId == fileId } ?: return false
        return !entry.inQueue || ahead(fileId, queue) > 0
    }

    /** 整部剧「优先下载」有没有意义：别的条目有排在它某一集前面的 */
    fun canPrioritizeItem(itemId: Long, queue: List<Entry>): Boolean {
        val firstOther = queue.indexOfFirst { it.mediaItemId != itemId && it.inQueue }
        val lastMine = queue.indexOfLast { it.mediaItemId == itemId }
        return firstOther >= 0 && lastMine >= 0 && firstOther < lastMine
    }

    /** 新顺序：给定的（去重、只认队里的）排最前，其余的接在后面、保持原来的先后 */
    fun order(front: List<Long>, queue: List<Entry>): List<Long> {
        val known = queue.map { it.fileId }.toSet()
        val listed = front.filter { it in known }.distinct()
        return listed + queue.map { it.fileId }.filter { it !in listed }
    }
}
