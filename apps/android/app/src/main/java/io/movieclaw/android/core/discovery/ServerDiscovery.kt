package io.movieclaw.android.core.discovery

import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import io.movieclaw.android.core.network.GeneralChannel
import io.movieclaw.android.core.network.ServerAddress
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface
import java.net.SocketTimeoutException
import java.net.URI
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import okhttp3.OkHttpClient

/**
 * 局域网自动发现,规则与 iOS ServerDiscovery 一致(协议见 docs/design/lan-discovery.md):
 * 对 /24 逐个单播 UDP 7359(不用组播,兼容 Docker bridge),每个地址问两句——自家的
 * 「who is MovieClawServer?」与 Jellyfin 的「who is JellyfinServer?」(v0.40.0 及更早的服务器只认后者)。
 * 同一来源的应答合并,候选(应答地址 → 来源 IP + 应答里出现过的端口 → 来源 IP + 3000)
 * 再以 GET /api/v1/health 验证。
 */
@Singleton
class ServerDiscovery @Inject constructor(
    @ApplicationContext private val context: Context,
    @GeneralChannel private val client: OkHttpClient,
) {

    suspend fun findFirst(): String? = candidates().firstOrNull()

    suspend fun candidates(): List<String> = withContext(Dispatchers.IO) {
        val subnets = localSubnets()
        if (subnets.isEmpty()) return@withContext emptyList()
        val replies = mutableListOf<Reply>()
        for (subnet in subnets) {
            runCatching {
                DatagramSocket().use { socket ->
                    socket.soTimeout = 300
                    val payloads = QUERIES.map { it.toByteArray(Charsets.US_ASCII) }
                    for (i in 1..254) {
                        val target = InetAddress.getByName("$subnet$i")
                        for (payload in payloads) {
                            runCatching { socket.send(DatagramPacket(payload, payload.size, target, DISCOVERY_PORT)) }
                        }
                    }
                    val buffer = ByteArray(4096)
                    val deadline = System.currentTimeMillis() + RESPONSE_WINDOW_MS
                    while (System.currentTimeMillis() < deadline) {
                        val packet = DatagramPacket(buffer, buffer.size)
                        try {
                            socket.receive(packet)
                        } catch (_: SocketTimeoutException) {
                            break
                        }
                        val source = (packet.address as? Inet4Address)?.hostAddress ?: continue
                        parse(String(buffer, 0, packet.length), source)?.let { replies += it }
                    }
                }
            }
        }
        val verified = mutableListOf<String>()
        for (reply in merged(replies)) {
            val origin = firstMovieClaw(candidates(reply)) ?: continue
            if (origin !in verified) verified += origin
            if (verified.size >= MAX_RESULTS) break
        }
        verified
    }

    /**
     * 手填的地址只写了主机(如 `192.168.1.10`)时依次试 3000 / 80 / https,用第一个确认是 MovieClaw 的;
     * 写了协议或端口、或都不是 MovieClaw 时原样返回,让登录那步报原因
     */
    suspend fun settle(input: String): String {
        val alternatives = manualAlternatives(input)
        if (alternatives.size <= 1) return input
        return withContext(Dispatchers.IO) { firstMovieClaw(alternatives) } ?: input
    }

    private fun firstMovieClaw(origins: List<String>): String? {
        val probeClient = client.newBuilder()
            .connectTimeout(2, TimeUnit.SECONDS)
            .readTimeout(2, TimeUnit.SECONDS)
            .callTimeout(3, TimeUnit.SECONDS)
            .build()
        return origins.firstOrNull { origin ->
            runCatching {
                val request = okhttp3.Request.Builder().url("$origin/api/v1/health").build()
                probeClient.newCall(request).execute().use { response ->
                    response.isSuccessful && response.body?.string().orEmpty().let { body ->
                        body.contains("movieclaw", ignoreCase = true) || body.contains("spec_hash")
                    }
                }
            }.getOrDefault(false)
        }
    }

    private fun localSubnets(): List<String> = runCatching {
        NetworkInterface.getNetworkInterfaces().asSequence()
            .filter { it.isUp && !it.isLoopback }
            .flatMap { it.inetAddresses.asSequence() }
            .filter { it is Inet4Address && it.isSiteLocalAddress }
            .mapNotNull { it.hostAddress?.substringBeforeLast('.')?.plus(".") }
            .distinct()
            .toList()
    }.getOrDefault(emptyList())

    /** 一条应答(或同一来源合并后的):候选地址、来源 IP;[native] = 自家协议的应答 */
    data class Reply(val addresses: List<String>, val source: String, val native: Boolean = false)

    companion object {
        private const val DISCOVERY_PORT = 7359
        /** 自家询问在前;Jellyfin 的询问与 Jellyfin 客户端发的一字不差 */
        private val QUERIES = listOf("who is MovieClawServer?", "who is JellyfinServer?")
        private const val RESPONSE_WINDOW_MS = 2500L
        private const val MAX_RESULTS = 5
        private const val DEFAULT_PORT = 3000

        /** 解析应答;不是发现应答返回 null。自家应答的地址列表可以为空(只能靠来源 IP 拼) */
        fun parse(body: String, source: String): Reply? {
            val obj = runCatching { Json.parseToJsonElement(body) as? JsonObject }.getOrNull() ?: return null
            fun text(element: Any?) = (element as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull?.takeIf(String::isNotEmpty)
            if (text(obj["type"]) == "movieclaw.discovery") {
                val addresses = (obj["addresses"] as? JsonArray).orEmpty().mapNotNull(::text)
                return Reply(addresses, source, native = true)
            }
            val address = text(obj["Address"]) ?: return null
            return Reply(listOf(address), source)
        }

        /** 同一来源 IP 的应答合并成一条(自家应答的地址在前) */
        fun merged(replies: List<Reply>): List<Reply> =
            replies.groupBy { it.source }.map { (source, group) ->
                val ordered = group.sortedByDescending { it.native }
                Reply(ordered.flatMap { it.addresses }.distinct(), source, ordered.first().native)
            }

        /** 一条应答可能对应的服务器 origin,按可信度排序、去重 */
        fun candidates(reply: Reply): List<String> {
            val list = mutableListOf<String>()
            fun add(raw: String) {
                val origin = ServerAddress.normalize(raw)?.origin ?: return
                if (origin !in list) list += origin
            }
            reply.addresses.forEach(::add)
            val ports = reply.addresses.mapNotNull { runCatching { URI(it).port }.getOrNull()?.takeIf { p -> p > 0 } }
            for (port in ports + DEFAULT_PORT) add("http://${reply.source}:$port")
            return list
        }

        /** 手填地址要试的 origin:只写了主机时是 主机:3000 / 主机 / https://主机,否则只有它自己 */
        fun manualAlternatives(input: String): List<String> {
            val normalized = ServerAddress.normalize(input) ?: return emptyList()
            val text = input.trim()
            val explicitPort = runCatching { URI("http://$text").port }.getOrDefault(-1) > 0
            if ("://" in text || explicitPort) return listOf(normalized.origin)
            val host = normalized.host
            return listOf("http://$host:$DEFAULT_PORT", "http://$host", "https://$host")
        }
    }
}
