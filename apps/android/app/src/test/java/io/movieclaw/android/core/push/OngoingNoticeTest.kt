package io.movieclaw.android.core.push

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** 常驻通知内容：变量渲染、三种显示方式、连接异常优先。 */
class OngoingNoticeTest {
    private fun item(title: String, episode: String, state: String, progress: Double? = null, eta: Long? = null) =
        StreamStatusSnapshot.Item(title, episode, progress, eta, state)

    private val busy = StreamStatusSnapshot(
        server = "家里的 NAS",
        today = StreamStatusSnapshot.Today(imported = 5, updated = 2),
        downloads = StreamStatusSnapshot.Downloads(
            active = 4,
            speed = 6_500_000,
            progress = 0.46,
            items = listOf(
                item("牧神记", "E12", "downloading", 0.78, 120),
                item("遮天", "E135", "downloading", 0.41, 540),
                item("仙逆", "E160", "stalled", 0.0),
            ),
        ),
    )
    private val idle = busy.copy(downloads = StreamStatusSnapshot.Downloads())
    private val member = busy.copy(downloads = null)
    private val connected = PushStreamStatus.Connected(0)

    @Test fun `variables render from the snapshot and unknown braces stay`() {
        assertEquals(
            "🦀 4 个在下 · 6.2 MB/s · 今天入库 5 集 / 2 部 · 家里的 NAS {别的}",
            OngoingNotice.render("🦀 {下载数} 个在下 · {速度} · 今天入库 {今日入库} 集 / {今日更新} 部 · {服务器名} {别的}", busy),
        )
        assertEquals("0 · 0 KB/s", OngoingNotice.render("{下载数} · {速度}", idle))
        // 看不到下载、还没收到快照：不拿 0 冒充
        assertEquals("– · 5", OngoingNotice.render("{下载数} · {今日入库}", member))
        assertEquals("– · – · –", OngoingNotice.render("{下载数} · {今日入库} · {服务器名}", null))
    }

    @Test fun `connection problems win over any snapshot`() {
        for (mode in OngoingMode.entries) {
            val retrying = OngoingNotice.build(mode, "🦀 {下载数}", PushStreamStatus.Retrying("连不上服务器", 0), busy)
            assertEquals("实时通知已断开", retrying.title)
            assertEquals("连不上服务器，会自动重连", retrying.text)
            assertFalse(retrying.openDownloads)
            assertEquals(null, retrying.progress)
            assertEquals("正在连接服务器…", OngoingNotice.build(mode, "", PushStreamStatus.Connecting, busy).title)
        }
    }

    @Test fun `smart shows the download board while something downloads`() {
        val view = OngoingNotice.build(OngoingMode.SMART, "", connected, busy)
        assertEquals("下载中 4 个 · ↓ 6.2 MB/s", view.title)
        assertEquals("牧神记 E12 · 遮天 E135 · 仙逆 E160 等 4 个", view.text)
        assertEquals(
            listOf("牧神记 E12　78% · 2 分钟", "遮天 E135　41% · 9 分钟", "仙逆 E160　等待做种", "还有 1 个"),
            view.lines,
        )
        assertEquals(46, view.progress)
        assertFalse(view.indeterminate)
        assertTrue(view.openDownloads)
        // 没有体积算不出整体进度：不定进度条
        val unknown = OngoingNotice.build(OngoingMode.SMART, "", connected, busy.copy(downloads = busy.downloads!!.copy(progress = null)))
        assertTrue(unknown.indeterminate)
    }

    @Test fun `smart falls back to the custom text, or a useful default`() {
        val default = OngoingNotice.build(OngoingMode.SMART, "  ", connected, idle)
        assertEquals("今天入库 5 集", default.title)
        assertEquals("已连接 · 家里的 NAS", default.text)
        assertFalse(default.openDownloads)
        assertEquals("📺 今天 2 部有更新", OngoingNotice.build(OngoingMode.SMART, "📺 今天 {今日更新} 部有更新", connected, member).title)
        // 连上了但服务器还没发快照（或是旧版本服务器）
        val empty = OngoingNotice.build(OngoingMode.SMART, "", connected, null)
        assertEquals("今天入库 – 集", empty.title)
        assertEquals("已连接", empty.text)
    }

    @Test fun `download board always shows downloads, idle state included`() {
        val view = OngoingNotice.build(OngoingMode.DOWNLOADS, "🦀", connected, idle)
        assertEquals("下载全部完成", view.title)
        assertEquals("今天已入库 5 集 · 已连接，有新通知会立即提醒", view.text)
        assertFalse(view.openDownloads)
        val nothingToday = idle.copy(today = StreamStatusSnapshot.Today())
        assertEquals("已连接，有新通知会立即提醒", OngoingNotice.build(OngoingMode.DOWNLOADS, "", connected, nothingToday).text)
        // 看不到下载的账号：退回自定义文字
        assertEquals("🦀 5", OngoingNotice.build(OngoingMode.DOWNLOADS, "🦀 {今日入库}", connected, member).title)
    }

    @Test fun `custom text ignores downloads`() {
        val view = OngoingNotice.build(OngoingMode.CUSTOM, "🦀 {下载数} 个在下 · 今天入库 {今日入库} 集", connected, busy)
        assertEquals("🦀 4 个在下 · 今天入库 5 集", view.title)
        assertEquals("已连接 · 家里的 NAS", view.text)
        assertTrue(view.lines.isEmpty())
        assertFalse(view.openDownloads)
    }

    @Test fun `mode keys round trip and default to smart`() {
        for (mode in OngoingMode.entries) assertEquals(mode, OngoingMode.of(mode.key))
        assertEquals(OngoingMode.SMART, OngoingMode.of(null))
        assertEquals(OngoingMode.SMART, OngoingMode.of("today"))
    }

    @Test fun `long etas read in days and absurd ones are dropped`() {
        assertEquals(null, OngoingNotice.etaText(0))
        assertEquals("约 2 天", OngoingNotice.etaText(2L * 86_400 + 600))
        assertEquals("约 30 天", OngoingNotice.etaText(30L * 86_400))
        assertEquals(null, OngoingNotice.etaText(4_144_224)) // 真实快照：约 48 天
        assertTrue(OngoingNotice.etaText(120)!!.isNotBlank())
    }
}
