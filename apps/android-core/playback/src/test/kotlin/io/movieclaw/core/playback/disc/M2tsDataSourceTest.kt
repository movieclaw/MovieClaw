package io.movieclaw.core.playback.disc

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.datasource.ByteArrayDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
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
        assertEquals(1156, M2tsDataSource.physical(1128))
        assertEquals(76_800_000_191L, M2tsDataSource.physical(75_200_000_187L))
    }

    @Test
    fun `batch reads preserve bytes across upstream and caller boundaries`() {
        for (chunk in listOf(1, 3, 191, 193, 8191, Int.MAX_VALUE)) {
            val packets = if (chunk < 192) 9 else 1025
            val raw = ByteArray(packets * 192 + 101) { (it * 31 + it / 192).toByte() }
            val stripped = raw.filterIndexed { i, _ -> i % 192 >= 4 }.toByteArray()
            val upstream = ChunkedSource(raw, chunk)
            val source = M2tsDataSource(upstream)
            for (position in listOf(0, 1, 187, 188, 189, 1128)) {
                source.open(DataSpec.Builder().setUri(Uri.EMPTY).setPosition(position.toLong()).build())
                assertArrayEquals("chunk=$chunk position=$position", stripped.copyOfRange(position, stripped.size), drain(source))
                source.close()
            }
        }
    }

    @Test
    fun `bounded reads cover every intra-packet start and reset unread data on reopen`() {
        val raw = m2ts + m2ts
        val stripped = ts + ts
        val upstream = ChunkedSource(raw, Int.MAX_VALUE)
        val source = M2tsDataSource(upstream)
        for (position in 0 until 188) {
            source.open(DataSpec.Builder().setUri(Uri.EMPTY).setPosition(position.toLong()).setLength(564).build())
            assertEquals(M2tsDataSource.physical(position.toLong()), upstream.opened!!.position)
            assertEquals(M2tsDataSource.physical(position + 563L) + 1 - upstream.opened!!.position, upstream.opened!!.length)
            assertArrayEquals(stripped.copyOfRange(position, position + 564), drain(source))
            source.close()
            // 故意留下未交付的缓冲字节；下一次 open 必须丢掉它们。
            source.open(DataSpec.Builder().setUri(Uri.EMPTY).build())
            assertEquals(1, source.read(ByteArray(1), 0, 1))
            source.close()
        }
    }

    @Test
    fun `large reads amortize upstream calls without waiting to fill the caller buffer`() {
        val raw = ByteArray(2048 * 192)
        val upstream = ChunkedSource(raw, Int.MAX_VALUE)
        val source = M2tsDataSource(upstream)
        source.open(DataSpec.Builder().setUri(Uri.EMPTY).build())
        val target = ByteArray(raw.size)
        assertEquals(0, source.read(target, 0, 0))
        assertEquals(0, upstream.reads)
        val first = source.read(target, 0, target.size)
        assertTrue(first > 0)
        assertEquals("已有数据就返回，不为了填满调用方缓冲再读网络", 1, upstream.reads)
        assertEquals(2048 * 188 - first, drain(source).size)
        assertTrue("整包输入应摊薄上游调用（含 EOF），原来需要 33 次", upstream.reads < 16)
        assertEquals(0, source.read(target, 0, 0))
        source.close()
    }

    private fun drain(source: DataSource): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        val sizes = intArrayOf(1, 187, 188, 189, 9400, 65000)
        val target = ByteArray(sizes.max() + 10)
        var call = 0
        while (true) {
            val length = sizes[call++ % sizes.size]
            target.fill(0x55)
            val n = source.read(target, 5, length)
            if (n == C.RESULT_END_OF_INPUT) break
            assertTrue(n in 1..length)
            assertTrue(target.take(5).all { it == 0x55.toByte() })
            assertEquals(0x55.toByte(), target[5 + n])
            out.write(target, 5, n)
        }
        return out.toByteArray()
    }

    private class ChunkedSource(
        bytes: ByteArray,
        private val chunk: Int,
        private val delegate: DataSource = ByteArrayDataSource(bytes),
    ) : DataSource by delegate {
        var reads = 0
        var opened: DataSpec? = null

        override fun open(dataSpec: DataSpec): Long {
            opened = dataSpec
            return delegate.open(dataSpec)
        }

        override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
            reads++
            return delegate.read(buffer, offset, minOf(length, chunk))
        }
    }
}
