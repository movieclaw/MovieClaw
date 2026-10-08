@file:androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)

package io.movieclaw.android.core.playback

import android.util.Base64
import android.util.Log
import androidx.media3.common.C
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import io.movieclaw.android.core.model.MatroskaCuesView

/**
 * MKV 精简索引注入 —— 引擎补丁 P58 的 Exo 对应物（iOS 在 AVIOReader 里做）。
 *
 * 服务端随会话下发的 Cues 只含视频轨索引点（字幕轨多的片子原索引有几百 KB 到几 MB，
 * 慢线上单独下要好几秒）。解复用器按 SeekHead 找索引时，这里直接给本地字节，原索引不用下载。
 *
 * 语义照 iOS AVIOReader 的 P58：
 * - 只拦截**起点落在 Cues 区间内**的请求；起点在 Cues 之前/之后原样透传
 *   （起点在前面但会越过 Cues 的请求不截——那些字节就是原文件内容，交给解析器）；
 * - 请求越过 Cues 末尾的部分**接原文件**：本地字节读完透明续上游，调用方无感
 *   （直接短读会让 Exo 把这次 open 当成资源结束，播放就断了）；
 * - base64 解码失败永久透传（服务端给什么用什么，不能因为这个断播）。
 *
 * 带 `McExo` 日志：装机测试用它验证 Exo 是否真的按 SeekHead 点读 Cues——
 * 没点读这层就是透明透传，无害。
 */
internal class CuesServingDataSource(
    private val upstream: DataSource,
    private val cues: MatroskaCuesView,
) : DataSource {

    /** 本次 open 的本地字节（起点在 Cues 区间内时才非空） */
    private var local: ByteArray? = null
    private var localPos = 0

    /** 本地字节读完后是否接得上上游（请求越过 Cues 末尾时 open 里已经续上） */
    private var tailOpen = false

    /** base64 只解一次；失败 null = 这个数据源永久透传 */
    private var decoded: ByteArray? = null
    private var decodeTried = false

    private fun decoded(): ByteArray? {
        if (!decodeTried) {
            decodeTried = true
            decoded = runCatching { Base64.decode(cues.data, Base64.NO_WRAP) }
                .onFailure { Log.w(TAG, "精简索引解码失败，透传原文件: ${it.message}") }
                .getOrNull()
                ?.takeIf { it.isNotEmpty() }
        }
        return decoded
    }

    override fun open(dataSpec: DataSpec): Long {
        close()
        val bytes = decoded() ?: return openUpstream(dataSpec)
        val start = dataSpec.position
        val cuesEnd = cues.offset + bytes.size
        // 起点不在 Cues 区间内：原样透传（多数请求走这里，日志只在 debug 级）
        if (start < cues.offset || start >= cuesEnd) {
            Log.d(TAG, "透传 pos=$start len=${dataSpec.length} (cues ${cues.offset}..$cuesEnd)")
            return openUpstream(dataSpec)
        }
        val remaining = bytes.size - (start - cues.offset).toInt()
        val count = if (dataSpec.length == C.LENGTH_UNSET.toLong()) remaining else minOf(remaining.toLong(), dataSpec.length).toInt()
        local = bytes.copyOfRange((start - cues.offset).toInt(), (start - cues.offset).toInt() + count)
        localPos = 0
        val localLen = local!!.size.toLong()
        val requested = dataSpec.length
        Log.i(
            TAG,
            "命中Cues pos=$start len=$requested -> 本地${localLen}B " +
                "(精简${bytes.size}B/原${cues.originalBytes}B)",
        )
        // 越过 Cues 末尾的部分接原文件：subrange 保持同一 uri/请求头，position 自动 +localLen，
        // 长度 -localLen（原请求未定长则仍为未定长）
        val tailSpec = if (requested == C.LENGTH_UNSET.toLong() || requested > localLen) {
            dataSpec.subrange(localLen)
        } else {
            null
        }
        if (tailSpec == null) return localLen
        val tailLen = openUpstream(tailSpec)
        return if (tailLen == C.LENGTH_UNSET.toLong()) C.LENGTH_UNSET.toLong() else localLen + tailLen
    }

    private fun openUpstream(spec: DataSpec): Long {
        tailOpen = true
        return try { upstream.open(spec) } catch (e: Exception) {
            close()
            throw e
        }
    }

    override fun read(target: ByteArray, offset: Int, length: Int): Int {
        if (length == 0) return 0
        val bytes = local
        if (bytes != null && localPos < bytes.size) {
            val n = minOf(length, bytes.size - localPos)
            System.arraycopy(bytes, localPos, target, offset, n)
            localPos += n
            return n
        }
        // 本地字节读完（或本来就没命中）：续上游；没续上说明这次请求到这儿就完了
        return if (tailOpen) upstream.read(target, offset, length) else C.RESULT_END_OF_INPUT
    }

    override fun getUri(): android.net.Uri? = upstream.getUri()

    override fun addTransferListener(transferListener: TransferListener) {
        upstream.addTransferListener(transferListener)
    }

    override fun close() {
        local = null
        localPos = 0
        tailOpen = false
        runCatching { upstream.close() }
    }

    private companion object {
        const val TAG = "McExo"
    }
}
