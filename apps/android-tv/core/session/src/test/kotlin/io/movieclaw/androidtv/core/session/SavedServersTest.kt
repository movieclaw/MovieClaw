package io.movieclaw.androidtv.core.session

import io.movieclaw.androidtv.core.network.ServerAddress
import org.junit.Assert.assertEquals
import org.junit.Test

class SavedServersTest {
    private val nas = ServerAddress.parse("192.168.1.10:3000")!!
    private val other = ServerAddress.parse("10.0.0.2:3000")!!
    private fun acc(name: String, active: Boolean = false) = AccountSnapshot(name, name, active = active)

    @Test
    fun activeAccountMovesToFrontAndOthersBecomeInactive() {
        var list = SavedServers.upserting(emptyList(), nas, acc("admin", true))
        list = SavedServers.upserting(list, nas, acc("xiaoyu", true))
        assertEquals(listOf("xiaoyu" to true, "admin" to false), list.single().accounts.map { it.username to it.active })
    }

    @Test
    fun touchingSortsMostRecentFirstAndPruneKeepsCurrent() {
        var list = SavedServers.touching(emptyList(), nas, listOf(acc("admin", true)), at = 1)
        list = SavedServers.touching(list, other, emptyList(), at = 2)
        assertEquals(listOf(other.toString(), nas.toString()), list.map { it.origin })
        assertEquals(listOf(nas.toString()), SavedServers.pruned(list, keeping = null).map { it.origin })
        assertEquals(2, SavedServers.pruned(list, keeping = other).size)
    }

    @Test
    fun removingAccountLeavesTheRest() {
        val list = SavedServers.upserting(SavedServers.upserting(emptyList(), nas, acc("a", true)), nas, acc("b", true))
        assertEquals(listOf("a"), SavedServers.removingAccount(list, "b", nas).single().accounts.map { it.username })
    }
}
