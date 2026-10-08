package io.movieclaw.android.core.discovery

import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import io.movieclaw.android.core.network.GeneralChannel
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface
import java.net.SocketTimeoutException
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient

/**
 * 局域网自动发现,规则与 iOS ServerDiscovery 一致:
 * Jellyfin 兼容 UDP 7359 单播扫 /24(不用组播,兼容 Docker bridge),
 * 候选(响应包内地址 → 源 IP)再以 GET /api/v1/health 验证。
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
        val hosts = LinkedHashSet<String>()
        for (subnet in subnets) {
            runCatching {
                DatagramSocket().use { socket ->
                    socket.broadcast = true
                    socket.soTimeout = 300
                    val payload = DISCOVERY_QUERY.toByteArray(Charsets.US_ASCII)
                    for (i in 1..254) {
                        runCatching {
                            socket.send(
                                DatagramPacket(payload, payload.size, InetAddress.getByName("$subnet$i"), DISCOVERY_PORT)
                            )
                        }
                    }
                    val buffer = ByteArray(2048)
                    val deadline = System.currentTimeMillis() + RESPONSE_WINDOW_MS
                    while (System.currentTimeMillis() < deadline) {
                        val packet = DatagramPacket(buffer, buffer.size)
                        try {
                            socket.receive(packet)
                        } catch (_: SocketTimeoutException) {
                            break
                        }
                        val announced = parseAnnouncedHost(String(buffer, 0, packet.length))
                        val host = announced ?: packet.address?.hostAddress
                        if (!host.isNullOrEmpty()) hosts += host
                    }
                }
            }
        }
        verifyHosts(hosts.toList())
    }

    private suspend fun verifyHosts(hosts: List<String>): List<String> {
        val verified = mutableListOf<String>()
        val probeClient = client.newBuilder()
            .connectTimeout(2, TimeUnit.SECONDS)
            .readTimeout(2, TimeUnit.SECONDS)
            .callTimeout(3, TimeUnit.SECONDS)
            .build()
        outer@ for (host in hosts) {
            for (port in VERIFY_PORTS) {
                val origin = "http://$host:$port"
                val ok = withContext(Dispatchers.IO) {
                    runCatching {
                        val request = okhttp3.Request.Builder().url("$origin/api/v1/health").build()
                        probeClient.newCall(request).execute().use { response ->
                            response.isSuccessful && response.body?.string().orEmpty().let { body ->
                                body.contains("movieclaw", ignoreCase = true) || body.contains("spec_hash")
                            }
                        }
                    }.getOrDefault(false)
                }
                if (ok) {
                    verified += origin
                    if (verified.size >= MAX_RESULTS) break@outer
                    break
                }
            }
        }
        return verified
    }

    private fun parseAnnouncedHost(body: String): String? =
        ADDRESS_REGEX.find(body)?.groupValues?.get(1)
            ?.removePrefix("http://")
            ?.substringBefore(":")
            ?.trim()
            ?.takeIf { it.isNotEmpty() }

    private fun localSubnets(): List<String> = runCatching {
        NetworkInterface.getNetworkInterfaces().asSequence()
            .filter { it.isUp && !it.isLoopback }
            .flatMap { it.inetAddresses.asSequence() }
            .filter { it is Inet4Address && it.isSiteLocalAddress }
            .mapNotNull { it.hostAddress?.substringBeforeLast('.')?.plus(".") }
            .distinct()
            .toList()
    }.getOrDefault(emptyList())

    private companion object {
        const val DISCOVERY_PORT = 7359
        const val DISCOVERY_QUERY = "who is JellyfinServer?"
        const val RESPONSE_WINDOW_MS = 2500L
        const val MAX_RESULTS = 5
        val VERIFY_PORTS = listOf(3000, 8096, 80, 8000)
        val ADDRESS_REGEX = Regex("\"Address\"\\s*:\\s*\"([^\"]+)\"")
    }
}
