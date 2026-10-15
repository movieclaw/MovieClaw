package io.movieclaw.core.playback.disc

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.datasource.ByteArrayDataSource
import androidx.media3.datasource.DataSpec
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class M2tsDataSourceTest {
    /** 每包 4 字节到达时间戳（0xEE）+ 188 字节内容，内容按包号与位置编码，去头后应正好是 [ts] */
    private val m2ts = ByteArray(5 * 192) { i -> if (i % 192 < 4) 0xEE.toByte() else ((i / 192) * 7 + i % 192 - 4).toByte() }
    private val ts = ByteArray(5 * 188) { i -> ((i / 188) * 7 + i % 188).toByte() }

    private fun read(position: Long, length: Long = C.LENGTH_UNSET.toLong()): ByteArray {
        val source = M2tsDataSource(ByteArrayDataSource(m2ts))
        val reported = source.open(DataSpec.Builder().setUri(Uri.EMPTY).setPosition(position).setLength(length).build())
        assertEquals("长度一律报未知，TS 解析器才不去文件尾估时长", C.LENGTH_UNSET.toLong(), reported)
        val out = java.io.ByteArrayOutputStream()
        val chunk = ByteArray(37) // 故意不对齐包长，覆盖跨包的读
        while (true) {
            val n = source.read(chunk, 0, chunk.size)
            if (n == C.RESULT_END_OF_INPUT) break
            out.write(chunk, 0, n)
        }
        source.close()
        return out.toByteArray()
    }

    @Test
    fun `strips the arrival timestamp of every packet`() {
        assertArrayEquals(ts, read(0))
    }

    @Test
    fun `opens in the middle of a packet`() {
        val from = 188 * 2 + 50
        assertArrayEquals(ts.copyOfRange(from, ts.size), read(from.toLong()))
    }

    @Test
    fun `a bounded read stops at the same byte of the stripped stream`() {
        assertArrayEquals(ts.copyOfRange(150, 450), read(150, 300))
    }

    @Test
    fun `maps stripped offsets onto the file`() {
        assertEquals(4, M2tsDataSource.physical(0))
        assertEquals(191, M2tsDataSource.physical(187))
        assertEquals(196, M2tsDataSource.physical(188))
    }
}
