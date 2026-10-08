package io.movieclaw.android.core.playback

import android.util.Base64
import androidx.media3.common.C
import androidx.media3.datasource.ByteArrayDataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultHttpDataSource
import io.movieclaw.android.core.model.MatroskaCuesView
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(application = android.app.Application::class, sdk = [34])
class CuesServingDataSourceTest {
    private val original = "abcdefghijklmnop".toByteArray()
    private val cues = MatroskaCuesView(5, Base64.encodeToString("XYZ".toByteArray(), Base64.NO_WRAP), 3)
    private fun spec(position: Long, length: Long = C.LENGTH_UNSET.toLong()) =
        DataSpec.Builder().setUri("https://example.com/movie.mkv").setPosition(position).setLength(length).build()
    private fun readAll(source: CuesServingDataSource): String {
        val output = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(2)
        while (true) {
            val read = source.read(buffer, 0, buffer.size)
            if (read == C.RESULT_END_OF_INPUT) break
            output.write(buffer, 0, read)
        }
        return output.toString("UTF-8")
    }

    @Test fun fileHeaderAndAfterIndexPassThroughAcrossReopen() {
        val source = CuesServingDataSource(ByteArrayDataSource(original), cues)
        assertEquals(4L, source.open(spec(0, 4)))
        assertEquals("abcd", readAll(source))
        assertEquals(4L, source.open(spec(8, 4)))
        assertEquals("ijkl", readAll(source))
        source.close()
    }

    @Test fun localIndexHonorsBoundedRequestAndZeroRead() {
        val source = CuesServingDataSource(ByteArrayDataSource(original), cues)
        assertEquals(1L, source.open(spec(6, 1)))
        assertEquals(0, source.read(ByteArray(0), 0, 0))
        assertEquals("Y", readAll(source))
        source.close()
    }

    @Test fun requestCrossesLocalIndexIntoOriginalFile() {
        val source = CuesServingDataSource(ByteArrayDataSource(original), cues)
        assertEquals(6L, source.open(spec(6, 6)))
        assertEquals("YZijkl", readAll(source))
        source.close()
    }

    @Test fun malformedIndexPassesThroughEveryOpen() {
        val source = CuesServingDataSource(ByteArrayDataSource(original), cues.copy(data = "!"))
        repeat(2) {
            assertEquals(3L, source.open(spec(5, 3)))
            assertEquals("fgh", readAll(source))
        }
        source.close()
    }

    @Test fun httpScenarioReadsHeaderIndexAndTailAndPropagatesFailure() {
        val server = MockWebServer()
        server.start()
        val source = CuesServingDataSource(DefaultHttpDataSource.Factory().createDataSource(), cues)
        fun remote(position: Long, length: Long) = spec(position, length).buildUpon()
            .setUri(server.url("/movie.mkv").toString()).build()
        try {
            server.enqueue(MockResponse().setBody("abcdefghijklmnop"))
            assertEquals(4L, source.open(remote(0, 4)))
            assertEquals("abcd", readAll(source))
            server.takeRequest()
            server.enqueue(MockResponse().setResponseCode(206).setHeader("Content-Range", "bytes 8-11/16").setBody("ijkl"))
            assertEquals(6L, source.open(remote(6, 6)))
            assertEquals("YZijkl", readAll(source))
            assertEquals("bytes=8-11", server.takeRequest().getHeader("Range"))
            server.enqueue(MockResponse().setResponseCode(503))
            assertThrows(java.io.IOException::class.java) { source.open(remote(6, 6)) }
            assertEquals(C.RESULT_END_OF_INPUT, source.read(ByteArray(4), 0, 4))
            server.enqueue(MockResponse().setBody("abcdefghijklmnop"))
            source.open(remote(0, 4))
            assertEquals("abcd", readAll(source))
        } finally { source.close(); server.shutdown() }
    }
}
