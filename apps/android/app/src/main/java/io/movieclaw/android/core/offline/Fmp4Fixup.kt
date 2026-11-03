package io.movieclaw.android.core.offline

import java.io.File
import java.io.RandomAccessFile

/**
 * 转码档（服务端导出的分片 MP4）下完后的一处修补：导出按文件绝对时间转码（`-copyts`），音轨第一个分片的
 * `tfdt` 是负的（AAC 起始补偿，实测 −1024）。iOS 的引擎（FFmpeg）照读；Exo 的 FragmentedMp4Extractor 读到
 * 负值直接报错（「Top bit not zero」），整份打不开。这里把负的 `tfdt` 原地改成 0（只动这 8 个字节，
 * 第一段音频晚约 20 毫秒，其余分片不受影响）。只读盒子头、按偏移跳着走，几百 MB 的文件也是毫秒级。
 */
object Fmp4Fixup {
    /** 返回改了几处 */
    fun clampNegativeTfdt(file: File): Int {
        var fixed = 0
        RandomAccessFile(file, "rw").use { raf ->
            val length = raf.length()
            var pos = 0L
            while (pos + 8 <= length) {
                val (size, type, header) = box(raf, pos, length) ?: break
                if (type == "moof") fixed += walk(raf, pos + header, pos + size, setOf("traf"))
                pos += size
            }
        }
        return fixed
    }

    /** 在 [start, end) 里找容器 [containers] 往下走，遇到 tfdt 就修 */
    private fun walk(raf: RandomAccessFile, start: Long, end: Long, containers: Set<String>): Int {
        var fixed = 0
        var pos = start
        while (pos + 8 <= end) {
            val (size, type, header) = box(raf, pos, end) ?: break
            when {
                type in containers -> fixed += walk(raf, pos + header, pos + size, emptySet())
                type == "tfdt" -> {
                    raf.seek(pos + header)
                    val version = raf.readUnsignedByte()
                    if (version == 1) {
                        raf.seek(pos + header + 4)
                        if (raf.readLong() < 0) {
                            raf.seek(pos + header + 4)
                            raf.writeLong(0)
                            fixed += 1
                        }
                    }
                }
            }
            pos += size
        }
        return fixed
    }

    /**
     * 补一个分片索引（`sidx`）：导出是边转边写的分片 MP4，没有索引；iOS 的引擎（FFmpeg）照样能拖，
     * Exo 的 FragmentedMp4Extractor 没有 `sidx` 就当成不能拖动（续播点、拖进度条全部从头放）。
     * 按视频轨每个分片的起点与时长写一张表，插在 `moov` 之后（整份改写一次，几秒钟）。
     * 分片里的数据偏移都相对 `moof`（default-base-is-moof），插进字节不影响；不是这种写法的不动。返回是否补上了
     */
    fun addSegmentIndex(file: File): Boolean {
        data class Fragment(val start: Long, var end: Long, var time: Long? = null, var duration: Long = 0)
        val fragments = mutableListOf<Fragment>()
        var moovEnd = -1L
        var refTrack = -1L
        var timescale = 0L
        val trexDuration = mutableMapOf<Long, Long>()
        RandomAccessFile(file, "r").use { raf ->
            val length = raf.length()
            var pos = 0L
            var pendingStyp: Long? = null
            while (pos + 8 <= length) {
                val (size, type, header) = box(raf, pos, length) ?: return false
                when (type) {
                    "sidx" -> return false
                    "moov" -> {
                        moovEnd = pos + size
                        val tracks = mutableListOf<Triple<Long, String, Long>>()
                        children(raf, pos + header, pos + size) { cPos, cSize, cType, cHeader ->
                            when (cType) {
                                "trak" -> readTrack(raf, cPos + cHeader, cPos + cSize)?.let { tracks += it }
                                "mvex" -> children(raf, cPos + cHeader, cPos + cSize) { tPos, _, tType, tHeader ->
                                    if (tType == "trex") {
                                        raf.seek(tPos + tHeader + 4)
                                        val id = raf.readInt().toLong() and 0xFFFFFFFFL
                                        raf.readInt()
                                        trexDuration[id] = raf.readInt().toLong() and 0xFFFFFFFFL
                                    }
                                }
                            }
                        }
                        val ref = tracks.firstOrNull { it.second == "vide" } ?: tracks.firstOrNull() ?: return false
                        refTrack = ref.first
                        timescale = ref.third
                    }
                    "styp" -> pendingStyp = pos
                    "moof" -> {
                        fragments.lastOrNull()?.end = pendingStyp ?: pos
                        val fragment = Fragment(pendingStyp ?: pos, length)
                        pendingStyp = null
                        if (!readFragment(raf, pos + header, pos + size, refTrack, trexDuration[refTrack] ?: 0) { time, duration ->
                                fragment.time = time
                                fragment.duration = duration
                            }
                        ) return false
                        fragments += fragment
                    }
                }
                pos += size
            }
        }
        if (moovEnd < 0 || timescale <= 0 || fragments.isEmpty() || fragments.size > 65535 || fragments.any { it.time == null }) return false
        val count = fragments.size
        val sidx = java.nio.ByteBuffer.allocate(44 + 12 * count)
        sidx.putInt(44 + 12 * count).put("sidx".toByteArray(Charsets.ISO_8859_1))
        sidx.put(1).put(byteArrayOf(0, 0, 0))
        sidx.putInt(refTrack.toInt()).putInt(timescale.toInt())
        sidx.putLong(fragments.first().time!!).putLong(0)
        sidx.putShort(0).putShort(count.toShort())
        for (f in fragments) {
            val size = f.end - f.start
            if (size <= 0 || size > Int.MAX_VALUE) return false
            sidx.putInt(size.toInt()).putInt(f.duration.toInt()).putInt(0x90000000.toInt())
        }
        val tmp = File(file.parentFile, file.name + ".idx")
        java.io.FileInputStream(file).channel.use { input ->
            java.io.FileOutputStream(tmp).channel.use { output ->
                var copied = 0L
                while (copied < moovEnd) copied += input.transferTo(copied, moovEnd - copied, output)
                output.write(java.nio.ByteBuffer.wrap(sidx.array()))
                val length = input.size()
                var rest = moovEnd
                while (rest < length) rest += input.transferTo(rest, length - rest, output)
                output.force(true)
            }
        }
        if (!tmp.renameTo(file)) {
            tmp.delete()
            return false
        }
        return true
    }

    private inline fun children(raf: RandomAccessFile, start: Long, end: Long, visit: (Long, Long, String, Int) -> Unit) {
        var pos = start
        while (pos + 8 <= end) {
            val (size, type, header) = box(raf, pos, end) ?: return
            visit(pos, size, type, header)
            pos += size
        }
    }

    /** trak 里的（轨号、类型、时间刻度） */
    private fun readTrack(raf: RandomAccessFile, start: Long, end: Long): Triple<Long, String, Long>? {
        var id = -1L
        var handler = ""
        var scale = 0L
        children(raf, start, end) { pos, size, type, header ->
            when (type) {
                "tkhd" -> {
                    raf.seek(pos + header)
                    val version = raf.readUnsignedByte()
                    raf.seek(pos + header + if (version == 1) 20 else 12)
                    id = raf.readInt().toLong() and 0xFFFFFFFFL
                }
                "mdia" -> children(raf, pos + header, pos + size) { mPos, _, mType, mHeader ->
                    when (mType) {
                        "mdhd" -> {
                            raf.seek(mPos + mHeader)
                            val version = raf.readUnsignedByte()
                            raf.seek(mPos + mHeader + if (version == 1) 20 else 12)
                            scale = raf.readInt().toLong() and 0xFFFFFFFFL
                        }
                        "hdlr" -> {
                            raf.seek(mPos + mHeader + 8)
                            handler = ByteArray(4).also { raf.readFully(it) }.toString(Charsets.ISO_8859_1)
                        }
                    }
                }
            }
        }
        return if (id >= 0) Triple(id, handler, scale) else null
    }

    /** moof 里参考轨那一段的（起点、时长）；数据偏移不是相对 moof 的返回 false */
    private fun readFragment(
        raf: RandomAccessFile, start: Long, end: Long, track: Long, trexDuration: Long, found: (Long, Long) -> Unit,
    ): Boolean {
        var ok = true
        children(raf, start, end) { pos, size, type, header ->
            if (type != "traf") return@children
            var id = -1L
            var defaultDuration = trexDuration
            var time: Long? = null
            var duration = 0L
            children(raf, pos + header, pos + size) { tPos, _, tType, tHeader ->
                when (tType) {
                    "tfhd" -> {
                        raf.seek(tPos + tHeader)
                        val flags = raf.readInt() and 0xFFFFFF
                        id = raf.readInt().toLong() and 0xFFFFFFFFL
                        if (flags and 0x01 != 0) ok = false  // 绝对的 base_data_offset：插字节会错位
                        var skip = 0
                        if (flags and 0x01 != 0) skip += 8
                        if (flags and 0x02 != 0) skip += 4
                        if (flags and 0x08 != 0) {
                            raf.seek(tPos + tHeader + 8 + skip)
                            defaultDuration = raf.readInt().toLong() and 0xFFFFFFFFL
                        }
                    }
                    "tfdt" -> {
                        raf.seek(tPos + tHeader)
                        val version = raf.readUnsignedByte()
                        raf.seek(tPos + tHeader + 4)
                        time = if (version == 1) raf.readLong() else raf.readInt().toLong() and 0xFFFFFFFFL
                    }
                    "trun" -> {
                        raf.seek(tPos + tHeader)
                        val flags = raf.readInt() and 0xFFFFFF
                        val samples = raf.readInt().toLong() and 0xFFFFFFFFL
                        if (flags and 0x100 == 0) {
                            duration += samples * defaultDuration
                        } else {
                            var offset = 8L
                            if (flags and 0x01 != 0) offset += 4
                            if (flags and 0x04 != 0) offset += 4
                            val perSample = listOf(0x100, 0x200, 0x400, 0x800).count { flags and it != 0 } * 4L
                            for (i in 0 until samples) {
                                raf.seek(tPos + tHeader + offset + i * perSample)
                                duration += raf.readInt().toLong() and 0xFFFFFFFFL
                            }
                        }
                    }
                }
            }
            if (id == track) time?.let { found(it, duration) }
        }
        return ok
    }

    /** 盒子的（总长、类型、头长）；长度不合理时返回 null */
    private fun box(raf: RandomAccessFile, pos: Long, end: Long): Triple<Long, String, Int>? {
        raf.seek(pos)
        var size = raf.readInt().toLong() and 0xFFFFFFFFL
        val type = ByteArray(4).also { raf.readFully(it) }.toString(Charsets.ISO_8859_1)
        var header = 8
        if (size == 1L) {
            size = raf.readLong()
            header = 16
        } else if (size == 0L) {
            size = end - pos
        }
        if (size < header || pos + size > end) return null
        return Triple(size, type, header)
    }
}
