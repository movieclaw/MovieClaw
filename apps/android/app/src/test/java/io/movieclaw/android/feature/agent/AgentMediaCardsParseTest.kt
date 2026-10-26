package io.movieclaw.android.feature.agent

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 生成式 UI 卡片参数解析回归（对齐 iOS `AgentMediaCards.parse`）：
 * 组件白名单、逐项校验（编号必须正整数、title_ref 形态、季集成对）、按编号去重。
 * 模型生成的参数任何字段都可能缺失或错型——单项不合法跳过，整组画不了返回 null。
 */
class AgentMediaCardsParseTest {

    private fun parse(args: String) =
        AgentMediaCards.parse("show_media_cards_v1", Json.parseToJsonElement(args))

    @Test fun titleCardsParseAndDedupe() {
        val group = parse(
            """{"component":"title","title":"  推荐这几部  ",
               "items":[{"title_ref":"tmdb:movie:603"},{"title_ref":"tmdb:movie:603"},{"title_ref":"douban:123456"}]}"""
        )
        assertNotNull(group)
        assertEquals("推荐这几部", group!!.title)
        assertEquals(2, group.cards.size)
        assertEquals(AgentMediaCardKind.TITLE, group.cards[0].spec.kind)
        assertEquals("tmdb:movie:603", group.cards[0].spec.titleRef)
        assertTrue(group.cards[0].loading)
    }

    @Test fun titleRefAssembledFromTmdbIdAndType() {
        val group = parse("""{"component":"title","items":[{"tmdb_id":1399,"media_type":"tv"},{"tmdb_id":1399,"media_type":"person"}]}""")
        assertNotNull(group)
        assertEquals(1, group!!.cards.size)
        assertEquals("tmdb:tv:1399", group.cards[0].spec.titleRef)
    }

    @Test fun libraryItemKeepsSeasonEpisodeOnlyInPairs() {
        val group = parse(
            """{"component":"library_item","items":[{"media_item_id":11,"season_number":2,"episode_number":3},{"media_item_id":12,"season_number":2}]}"""
        )
        assertNotNull(group)
        assertEquals(2, group!!.cards.size)
        assertEquals(2, group.cards[0].spec.season)
        assertEquals(3, group.cards[0].spec.episode)
        assertNull(group.cards[1].spec.season)
        assertNull(group.cards[1].spec.episode)
    }

    @Test fun libraryAndSubscriptionCards() {
        val library = parse("""{"component":"library","items":[{"library_id":1},{"library_id":0}]}""")
        assertNotNull(library)
        assertEquals(1, library!!.cards.size)
        assertEquals(1L, library.cards[0].spec.libraryId)

        val subs = parse("""{"component":"subscription","items":[{"subscription_id":7}]}""")
        assertNotNull(subs)
        assertEquals(AgentMediaCardKind.SUBSCRIPTION, subs!!.cards[0].spec.kind)
        assertEquals(7L, subs.cards[0].spec.subscriptionId)
    }

    @Test fun malformedItemsSkipAndEmptyGroupsReturnNull() {
        assertNull(AgentMediaCards.parse("show_media_cards_v1", null))
        assertNull(parse("""{"component":"book","items":[{"library_id":1}]}"""))
        assertNull(parse("""{"component":"title","items":[{"title_ref":"tt1234567"}]}"""))
        assertNull(parse("""{"component":"title"}"""))
        assertNull(parse("""{"component":"title","items":[]}"""))
        // 混合：坏项跳过，好项保留
        val group = parse("""{"component":"title","items":[{"title_ref":"oops"},{"title_ref":"tmdb:movie:1"}]}""")
        assertNotNull(group)
        assertEquals(1, group!!.cards.size)
    }

    @Test fun otherToolsAreNotParsed() {
        assertNull(
            AgentMediaCards.parse(
                "search_torrents",
                Json.parseToJsonElement("""{"component":"title","items":[{"title_ref":"tmdb:movie:1"}]}"""),
            )
        )
        assertTrue(AgentMediaCards.isMediaCardsTool("show_media_cards_v1"))
        assertFalse(AgentMediaCards.isMediaCardsTool("show_media_cards_v2"))
    }

    @Test fun failedCardsCarrySpecAndNoActions() {
        val group = parse("""{"component":"library_item","items":[{"media_item_id":9}]}""")
        assertNotNull(group)
        val failed = AgentMediaCards.failed(group!!.cards[0].spec)
        assertTrue(failed.failed)
        assertFalse(failed.loading)
        assertNull(failed.open)
        assertNull(failed.play)
    }
}
