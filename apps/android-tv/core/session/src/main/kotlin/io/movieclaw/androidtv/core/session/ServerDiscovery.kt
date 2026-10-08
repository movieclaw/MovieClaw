package io.movieclaw.androidtv.core.session

import android.content.Context
import android.net.ConnectivityManager
import io.movieclaw.androidtv.core.network.ServerAddress
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.Request
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface
import java.net.SocketTimeoutException
import java.util.concurrent.TimeUnit

/**
 * 局域网自动发现 MovieClaw 服务器（逐项对齐 Apple 端 `Shared/Core/Networking/ServerDiscovery.swift`）。
 *
 * 协议：后端实现了 Jellyfin 的局域网发现（`src/movieclaw_jellyfin/udp.py`）——监听 UDP 7359，收到
 * 「who is JellyfinServer?」就向发送方单播回 `{"Address","Name","Id"}`。服务器不主动广播。
 *
 * 逐个单播、不发广播：Docker 桥接部署时广播进不了容器，发给宿主 IP 的单播却能经端口映射转进去。
 * 所以对电视所在网段（最多一个 /24）逐个问一遍，再收集应答。
 *
 * 应答里的地址不一定能直接用（容器内网 IP、公网域名），于是按「应答地址 → 来源 IP + 应答端口 → 来源 IP + 3000」
 * 依次试 `/api/v1/health`，第一个确认是 MovieClaw 的才算数——顺带排除局域网里真正的 Jellyfin。
 *
 * 与 Apple 端的差别：Apple 只取第一台；这里一轮里所有应答都探测，找到几台列几台。
 */
object ServerDiscovery {
    data class Found(val address: ServerAddress, val name: String)

    /** 一条发现应答：JSON 里的 Address、Name，加上报文的来源 IP */
    data class Reply(val address: String, val name: String, val source: String)

    const val PORT = 7359
    /** 与 Jellyfin 客户端发的询问一字不差（后端按大小写不敏感的包含关系匹配） */
    const val QUERY = "who is JellyfinServer?"
    /** 后端对外端口的默认值（docker-compose 的 3000:3000） */
    const val DEFAULT_PORT = 3000
    /** 最多问多少个地址 */
    private const val MAX_HOSTS = 1024

    private val json = Json { ignoreUnknownKeys = true }

    /**
     * 找局域网里的 MovieClaw：每轮对整个网段问一遍、等 1.2 秒收应答；某一轮找到了就停（这一轮里的全部列出），
     * 最多 [rounds] 轮、间隔 [intervalMs]。每确认一台就回调 [onFound]（累计的列表），界面可以边找边显示。
     * 电视没连局域网（找不到私有网段）时直接返回空。
     */
    suspend fun discover(
        http: OkHttpClient,
        context: Context? = null,
        rounds: Int = 8,
        intervalMs: Long = 2_000,
        onFound: (List<Found>) -> Unit = {},
    ): List<Found> {
        val hosts = withContext(Dispatchers.IO) { localHosts(context) }
        if (hosts.isEmpty()) return emptyList()
        val probe = http.newBuilder().callTimeout(2_500, TimeUnit.MILLISECONDS).build()
        val found = mutableListOf<Found>()
        for (round in 0 until rounds) {
            val replies = withContext(Dispatchers.IO) { sweep(hosts, listenMs = 1_200) }
            for (reply in replies) {
                val address = firstMovieClaw(probe, candidates(reply)) ?: continue
                if (found.none { it.address == address }) {
                    found += Found(address, reply.name)
                    onFound(found.toList())
                }
            }
            if (found.isNotEmpty()) return found
            if (round < rounds - 1) delay(intervalMs)
        }
        return found
    }

    // ---- 地址推导（纯函数，有单元测试） ----

    /** 一条应答可能对应的服务器地址，按可信度排序、去重 */
    fun candidates(reply: Reply): List<ServerAddress> {
        val list = mutableListOf<ServerAddress>()
        fun add(raw: String) {
            val address = ServerAddress.parse(raw) ?: return
            if (address !in list) list += address
        }
        add(reply.address)
        val port = explicitPort(reply.address) ?: DEFAULT_PORT
        add("http://${reply.source}:$port")
        add("http://${reply.source}:$DEFAULT_PORT")
        return list
    }

    /** 地址里写明的端口（同 URLComponents.port：没写就是 null，不按协议补默认端口） */
    private fun explicitPort(raw: String): Int? {
        val authority = raw.substringAfter("://", missingDelimiterValue = raw).substringBefore('/').substringBefore('?')
        val hostPort = authority.substringAfterLast('@')
        if (hostPort.startsWith("[")) return hostPort.substringAfter("]:", "").toIntOrNull()
        return hostPort.substringAfter(':', "").toIntOrNull()
    }

    /** 解析应答报文；不是合法的发现应答（不是 JSON、没有 Address）返回 null */
    fun parse(data: ByteArray, source: String): Reply? {
        val obj = runCatching { json.parseToJsonElement(data.decodeToString()) as? JsonObject }.getOrNull() ?: return null
        val address = obj["Address"]?.let { runCatching { it.jsonPrimitive.contentOrNull }.getOrNull() }
            ?.takeIf { it.isNotEmpty() } ?: return null
        val name = obj["Name"]?.let { runCatching { it.jsonPrimitive.contentOrNull }.getOrNull() }
            ?.takeIf { it.isNotEmpty() } ?: "MovieClaw"
        return Reply(address, name, source)
    }

    /**
     * 某个 IPv4 地址所在网段里要问的全部主机（数值，0..2³²-1）。
     * 掩码比 /24 宽时只扫本机所在的 /24：六万多个地址逐个问太慢，家庭网络也几乎都是 /24。本机地址也在其中。
     */
    fun subnetHosts(address: Long, prefixLength: Int): List<Long> {
        val netmask = if (prefixLength <= 0) 0L else (0xFFFFFFFFL shl (32 - prefixLength.coerceAtMost(32))) and 0xFFFFFFFFL
        val mask = netmask or 0xFFFFFF00L
        val network = address and mask
        val broadcast = network or (mask.inv() and 0xFFFFFFFFL)
        if (broadcast <= network + 1) return emptyList()
        return (network + 1 until broadcast).toList()
    }

    /** 私有网段（RFC 1918）：只在家庭 / 公司局域网里扫 */
    fun isPrivate(address: Long): Boolean =
        address shr 24 == 10L || address shr 20 == 0xAC1L || address shr 16 == 0xC0A8L

    fun dotted(address: Long): String =
        "${address shr 24 and 0xFF}.${address shr 16 and 0xFF}.${address shr 8 and 0xFF}.${address and 0xFF}"

    private fun numeric(address: Inet4Address): Long =
        address.address.fold(0L) { acc, byte -> (acc shl 8) or (byte.toLong() and 0xFF) }

    // ---- 网络 ----

    /**
     * 电视当前连着的局域网（Wi-Fi / 有线）里要问的全部地址；最多 1024 个。
     * 先看系统当前网络的地址（ConnectivityManager），再补上逐个网卡列出来的（有的系统版本对普通 App 只给其中一种）。
     */
    private fun localHosts(context: Context?): List<Long> {
        val addresses = mutableListOf<Pair<InetAddress, Int>>()
        runCatching {
            val connectivity = context?.getSystemService(ConnectivityManager::class.java)
            connectivity?.getLinkProperties(connectivity.activeNetwork)?.linkAddresses?.forEach {
                addresses += it.address to it.prefixLength
            }
        }
        runCatching {
            NetworkInterface.getNetworkInterfaces()?.toList().orEmpty()
                .filter { it.isUp && !it.isLoopback && !it.isVirtual }
                .forEach { nic -> nic.interfaceAddresses.forEach { addresses += it.address to it.networkPrefixLength.toInt() } }
        }
        val hosts = LinkedHashSet<Long>()
        for ((address, prefix) in addresses) {
            val ip = address as? Inet4Address ?: continue
            val value = numeric(ip)
            if (!isPrivate(value)) continue
            hosts += subnetHosts(value, prefix)
        }
        return hosts.take(MAX_HOSTS)
    }

    /** 对每个地址发一次询问，然后在 [listenMs] 内收集所有应答（阻塞，放在 IO 线程上跑） */
    private fun sweep(hosts: List<Long>, listenMs: Long): List<Reply> {
        val socket = runCatching { DatagramSocket() }.getOrNull() ?: return emptyList()
        socket.use {
            // 收包超时 150 毫秒：没有应答时按时返回，好检查截止时间
            it.soTimeout = 150
            val message = QUERY.encodeToByteArray()
            hosts.forEachIndexed { index, host ->
                runCatching { it.send(DatagramPacket(message, message.size, InetAddress.getByName(dotted(host)), PORT)) }
                // 每 32 个包歇 2 毫秒：一口气灌几百个包，网卡发送队列满了会丢包
                if (index % 32 == 31) Thread.sleep(2)
            }
            val replies = mutableListOf<Reply>()
            val buffer = ByteArray(4096)
            val deadline = System.currentTimeMillis() + listenMs
            while (System.currentTimeMillis() < deadline) {
                val packet = DatagramPacket(buffer, buffer.size)
                try {
                    it.receive(packet)
                } catch (_: SocketTimeoutException) {
                    continue
                } catch (_: Exception) {
                    break
                }
                val source = (packet.address as? Inet4Address)?.hostAddress ?: continue
                val reply = parse(packet.data.copyOfRange(packet.offset, packet.offset + packet.length), source) ?: continue
                if (reply !in replies) replies += reply
            }
            return replies
        }
    }

    /** 在候选地址里找第一个确认是 MovieClaw 的：并发探测，按候选顺序取第一个通过的 */
    private suspend fun firstMovieClaw(http: OkHttpClient, candidates: List<ServerAddress>): ServerAddress? = coroutineScope {
        val passed = candidates.map { candidate -> async(Dispatchers.IO) { isMovieClaw(http, candidate) } }.awaitAll()
        firstPassing(candidates, passed)
    }

    /** 候选与探测结果一一对应，取列表顺序里第一个通过的 */
    fun <T> firstPassing(candidates: List<T>, passed: List<Boolean>): T? =
        candidates.indices.firstOrNull { passed.getOrElse(it) { false } }?.let(candidates::get)

    /** `GET /api/v1/health` 返回 200 且 `status == "ok"` 才算 MovieClaw（超时 2.5 秒，路由不到的候选别拖住） */
    private fun isMovieClaw(http: OkHttpClient, server: ServerAddress): Boolean = runCatching {
        val url = server.apiBase.newBuilder().addPathSegment("health").build()
        http.newCall(Request.Builder().url(url).header("Accept", "application/json").build()).execute().use { response ->
            if (response.code != 200) return@use false
            isHealthy(response.body.string())
        }
    }.getOrDefault(false)

    /** 健康检查的响应体是不是 `{"status": "ok", ...}` */
    fun isHealthy(body: String): Boolean {
        val obj = runCatching { json.parseToJsonElement(body) as? JsonObject }.getOrNull() ?: return false
        return obj["status"]?.let { runCatching { it.jsonPrimitive.contentOrNull }.getOrNull() } == "ok"
    }
}
