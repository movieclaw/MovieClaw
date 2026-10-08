package io.movieclaw.android.core.playback

import android.app.Application
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.TransferListener
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [34])
class SourceByteCacheTest {
    @Test fun prefetchIsReusedAfterTokenChangeAndCacheMissKeepsTransferListener() = runBlocking {
        val context = RuntimeEnvironment.getApplication()
        val server = MockWebServer().also { it.start() }
        var transferred = 0
        val listener = object : TransferListener {
            override fun onTransferInitializing(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {}
            override fun onTransferStart(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {}
            override fun onTransferEnd(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {}
            override fun onBytesTransferred(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean, bytesTransferred: Int) {
                if (isNetwork) transferred += bytesTransferred
            }
        }
        val key = SourceByteCache.key(1, 8, server.url("/").toString())!!
        val factory = DefaultHttpDataSource.Factory().setTransferListener(listener)
        var reader: DataSource? = null
        try {
            server.enqueue(MockResponse().setResponseCode(206).setHeader("Content-Range", "bytes 0-3/8").setBody("abcd"))
            assertEquals(4L, SourceByteCache.prefetch(context, server.url("/file?token=a").toString(), key, listOf(0L to 4L)))
            assertEquals("bytes=0-3", server.takeRequest().getHeader("Range"))
            reader = SourceByteCache.playbackFactory(context, factory).createDataSource()
            val spec = DataSpec.Builder().setUri(server.url("/file?token=b").toString()).setKey(key).setLength(4).build()
            reader.open(spec)
            val bytes = ByteArray(4)
            assertEquals(4, reader.read(bytes, 0, 4))
            assertEquals("abcd", String(bytes))
            assertEquals(1, server.requestCount)
            assertEquals(0, transferred)
            reader.close()
            server.enqueue(MockResponse().setResponseCode(206).setHeader("Content-Range", "bytes 4-7/8").setBody("efgh"))
            reader.open(spec.buildUpon().setPosition(4).build())
            assertEquals(4, reader.read(bytes, 0, 4))
            assertEquals("efgh", String(bytes))
            assertEquals(4, transferred)
            assertEquals("bytes=4-7", server.takeRequest().getHeader("Range"))
        } finally { reader?.close(); SourceByteCache.clear(context); server.shutdown() }
    }
}
