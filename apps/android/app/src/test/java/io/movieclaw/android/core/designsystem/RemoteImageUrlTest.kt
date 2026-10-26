package io.movieclaw.android.core.designsystem

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * 图片地址解析的边界：**服务端下发的站内绝对地址可能是另一个入口的域名**
 * （内网 IP 连访时，库封面字段回的是外网域名）。这种地址必须按当前入口重写，
 * 不能当外链塞进 `/images/proxy`——服务端域名白名单会直接 400（实机日志）。
 */
class RemoteImageUrlTest {

    private val base = "http://192.168.5.211:3010"

    @Test
    fun `外链图走服务端代理`() {
        val url = resolveImageUrl("https://image.tmdb.org/t/p/w500/abc.jpg", base, 720)
        assertEquals(
            "$base/api/v1/images/proxy?url=https%3A%2F%2Fimage.tmdb.org%2Ft%2Fp%2Fw500%2Fabc.jpg&w=720",
            url,
        )
    }

    @Test
    fun `另一个入口域名下的站内地址按当前入口重写`() {
        val url = resolveImageUrl("http://gaojianyu.fun:3010/api/v1/libraries/1/cover", base, 720)
        assertEquals("$base/api/v1/libraries/1/cover?w=720", url)
    }

    @Test
    fun `站内绝对地址保留原有查询参数`() {
        val url = resolveImageUrl("https://gaojianyu.fun/api/v1/libraries/1/cover?v=3", base, 720)
        assertEquals("$base/api/v1/libraries/1/cover?v=3&w=720", url)
    }

    @Test
    fun `当前入口自己的绝对地址同样直连`() {
        val url = resolveImageUrl("$base/api/v1/images/assets/12/poster.jpg", base, 240)
        assertEquals("$base/api/v1/images/assets/12/poster.jpg?w=240", url)
    }

    @Test
    fun `相对路径补 api 前缀`() {
        val url = resolveImageUrl("/images/assets/12/poster.jpg", base, 240)
        assertEquals("$base/api/v1/images/assets/12/poster.jpg?w=240", url)
    }
}
