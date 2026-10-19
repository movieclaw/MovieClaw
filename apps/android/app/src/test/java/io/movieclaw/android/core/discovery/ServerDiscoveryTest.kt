package io.movieclaw.android.core.discovery

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ServerDiscoveryTest {
    private fun parse(json: String, source: String = "192.168.1.10") = ServerDiscovery.parse(json, source)

    @Test
    fun parsesBothReplyFormats() {
        assertEquals(
            ServerDiscovery.Reply(listOf("http://192.168.1.10:3300", "https://m.example.com"), "192.168.1.10", native = true),
            parse("""{"type":"movieclaw.discovery","version":1,"name":"NAS","addresses":["http://192.168.1.10:3300","",5,"https://m.example.com"]}"""),
        )
        assertEquals(ServerDiscovery.Reply(emptyList(), "192.168.1.10", native = true), parse("""{"type":"movieclaw.discovery","addresses":[]}"""))
        assertEquals(
            ServerDiscovery.Reply(listOf("http://172.17.0.2:3000"), "192.168.1.10"),
            parse("""{"Address":"http://172.17.0.2:3000","Id":"x","Name":"NAS","EndpointAddress":null}"""),
        )
        assertNull(parse("""{"Name":"x"}"""))
        assertNull(parse("""{"Address":""}"""))
        assertNull(parse("who is JellyfinServer?"))
    }

    /** Docker 桥接 + 宿主端口 3300:旧客户端会丢掉端口只试固定几个,现在按应答里的端口拼来源 IP */
    @Test
    fun candidatesKeepPortsFromReplies() {
        val merged = ServerDiscovery.merged(
            listOf(
                ServerDiscovery.Reply(listOf("http://172.17.0.2:3000"), "192.168.1.10"),
                ServerDiscovery.Reply(listOf("http://10.0.0.5:3300"), "192.168.1.10", native = true),
            ),
        )
        assertEquals(listOf(ServerDiscovery.Reply(listOf("http://10.0.0.5:3300", "http://172.17.0.2:3000"), "192.168.1.10", true)), merged)
        assertEquals(
            listOf("http://10.0.0.5:3300", "http://172.17.0.2:3000", "http://192.168.1.10:3300", "http://192.168.1.10:3000"),
            ServerDiscovery.candidates(merged.single()),
        )
        assertEquals(listOf("http://192.168.1.10:3000"), ServerDiscovery.candidates(ServerDiscovery.Reply(emptyList(), "192.168.1.10", true)))
    }

    @Test
    fun manualInputWithoutPortTriesCommonPorts() {
        assertEquals(
            listOf("http://192.168.1.10:3000", "http://192.168.1.10", "https://192.168.1.10"),
            ServerDiscovery.manualAlternatives(" 192.168.1.10 "),
        )
        assertEquals(listOf("http://192.168.1.10:3300"), ServerDiscovery.manualAlternatives("192.168.1.10:3300"))
        assertEquals(listOf("http://192.168.1.10"), ServerDiscovery.manualAlternatives("http://192.168.1.10"))
        assertEquals(listOf("https://m.example.com"), ServerDiscovery.manualAlternatives("https://m.example.com/"))
    }
}
