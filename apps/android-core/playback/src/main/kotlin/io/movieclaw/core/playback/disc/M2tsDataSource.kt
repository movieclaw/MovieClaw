package io.movieclaw.core.playback.disc

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener

/**
 * 蓝光剪辑（m2ts，192 字节一包）→ Exo 的 TS 解析器认的 188 字节包：每包去掉开头 4 字节的到达时间戳
 * （disc-clip-play.md §4.1）。
 *
 * 偏移按包换算：读出来的第 L 字节是第 L / 188 包的第 L % 188 字节，在原文件的 (L / 188) × 192 + 4 + L % 188。
 * 长度一律报「未知」：Exo 的 TS 解析器知道长度就去文件尾读 PCR 估时长、拖动时按时间二分（几十 GB 的剪辑上
 * 每次拖动是好几个 Range 请求），这两样都由服务端给的入口点表代替（[BluRayClipExtractor]）。
 */
@UnstableApi
class M2tsDataSource(private val upstream: DataSource) : DataSource {
    private val buffer = ByteArray(PACKET * 64)
    private var start = 0
    private var end = 0
    /** buffer[start] 在它那一包（192 字节）里的位置 */
    private var inPacket = 0

    override fun open(dataSpec: DataSpec): Long {
        val position = physical(dataSpec.position)
        val length = if (dataSpec.length == C.LENGTH_UNSET.toLong()) {
            C.LENGTH_UNSET.toLong()
        } else {
            physical(dataSpec.position + dataSpec.length - 1) + 1 - position
        }
        upstream.open(dataSpec.buildUpon().setPosition(position).setLength(length).build())
        start = 0
        end = 0
        inPacket = HEADER + (dataSpec.position % TS).toInt()
        return C.LENGTH_UNSET.toLong()
    }

    override fun read(target: ByteArray, offset: Int, length: Int): Int {
        if (length == 0) return 0
        var written = 0
        while (written < length) {
            if (start == end) {
                // 已经交出了一些就先返回，别为凑满再阻塞一次网络读
                if (written > 0) break
                val n = upstream.read(buffer, 0, buffer.size)
                if (n == C.RESULT_END_OF_INPUT) return C.RESULT_END_OF_INPUT
                start = 0
                end = n
                continue
            }
            if (inPacket < HEADER) {
                val skip = minOf(HEADER - inPacket, end - start)
                start += skip
                inPacket += skip
                continue
            }
            val n = minOf(PACKET - inPacket, end - start, length - written)
            System.arraycopy(buffer, start, target, offset + written, n)
            start += n
            written += n
            inPacket += n
            if (inPacket == PACKET) inPacket = 0
        }
        return written
    }

    override fun addTransferListener(transferListener: TransferListener) = upstream.addTransferListener(transferListener)

    override fun getUri(): Uri? = upstream.uri

    override fun getResponseHeaders(): Map<String, List<String>> = upstream.responseHeaders

    override fun close() = upstream.close()

    class Factory(private val upstream: DataSource.Factory) : DataSource.Factory {
        override fun createDataSource(): DataSource = M2tsDataSource(upstream.createDataSource())
    }

    companion object {
        const val PACKET = 192
        const val TS = 188
        const val HEADER = PACKET - TS

        /** 去头后的偏移 → 原文件里的偏移 */
        fun physical(position: Long): Long = position / TS * PACKET + HEADER + position % TS
    }
}
