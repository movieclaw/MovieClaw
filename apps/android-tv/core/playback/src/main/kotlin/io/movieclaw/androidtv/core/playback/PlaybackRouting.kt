package io.movieclaw.androidtv.core.playback

import androidx.media3.common.PlaybackException
import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface
import java.util.concurrent.ConcurrentHashMap
import kotlin.concurrent.thread

/** 播放失败的归因（对应 Apple 端 EngineFailureCause；Exo 没有落盘分片，没有「存储写满」这一类） */
enum class FailureCause { Network, SourceMissing, Decode, DecodeFinal }

/**
 * 播放失败之后下一步做什么（docs/design/player-engine.md §3「兜底阶梯」，对照 Apple 端 PlaybackRouting.swift FailurePolicy）。
 *
 * - 网络问题不换播放方式、不降码率：同档原地重开（新会话 = 新 token），预算用完原文件直连报错、服务端流降档；
 * - 片源不在了（404）直接说明；
 * - Exo 直连原文件一时出问题先原位重开一次，确定解不了才改走服务端 HLS；服务端流放不了就逐级降档。
 */
object FailurePolicy {
    data class Input(
        val cause: FailureCause,
        /** 在直连原文件（没有服务端会话流） */
        val playsOriginalFile: Boolean,
        /** 连接类失败还能同档重开（[NetworkRestartBudget] 没用完） */
        val restartAllowed: Boolean,
        /** 还能先原位重开一次（[NativeRetryBudget]） */
        val nativeRetryAllowed: Boolean = false,
    )

    enum class Response {
        /** 同片源原地重开（新会话 = 新取流令牌）；原文件直连时先等片源取得到 */
        Reconnect,
        /** 一时出了问题：原位重开 */
        RetryNative,
        /** 原文件直连一直取不到片源：落错误页 */
        FailNetwork,
        /** 片源不在了（404） */
        FailSourceMissing,
        /** 本机确定解不了原文件：改拉服务端 HLS */
        FallbackToServerStream,
        /** 服务端这一档放不了（或反复连不上）：逐级降档 */
        StepDownTier,
    }

    fun decide(input: Input): Response = when (input.cause) {
        FailureCause.Network -> when {
            input.restartAllowed -> Response.Reconnect
            // 服务端流连续重开都没出画：多半是这一档的换封装 / 转码出了问题；原文件直连连不上就是连不上
            input.playsOriginalFile -> Response.FailNetwork
            else -> Response.StepDownTier
        }
        FailureCause.SourceMissing -> Response.FailSourceMissing
        FailureCause.Decode -> when {
            !input.playsOriginalFile -> Response.StepDownTier
            input.nativeRetryAllowed -> Response.RetryNative
            else -> Response.FallbackToServerStream
        }
        FailureCause.DecodeFinal -> if (input.playsOriginalFile) Response.FallbackToServerStream else Response.StepDownTier
    }

    /**
     * Exo 的错误码 → 归因。[httpStatus] 是取流回的 HTTP 状态（有的话）：直连原文件时 404 是文件不在了；
     * 服务端流的分片 404 多半是会话被回收，换新会话就好，按网络处理。401 / 403 是取流令牌过期，同样按网络处理。
     * 「格式本机不支持」类是确定解不了（重开也一样），其余解码 / 解封装错误先当一时的问题。
     */
    fun classify(errorCode: Int, httpStatus: Int?, playsOriginalFile: Boolean): FailureCause = when {
        playsOriginalFile && (httpStatus == 404 || errorCode == PlaybackException.ERROR_CODE_IO_FILE_NOT_FOUND) -> FailureCause.SourceMissing
        errorCode in FINAL_DECODE -> FailureCause.DecodeFinal
        errorCode in 2000..2999 || errorCode == PlaybackException.ERROR_CODE_BEHIND_LIVE_WINDOW ||
            errorCode == PlaybackException.ERROR_CODE_TIMEOUT -> FailureCause.Network
        else -> FailureCause.Decode
    }

    private val FINAL_DECODE = setOf(
        PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED,
        PlaybackException.ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES,
        PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED,
        PlaybackException.ERROR_CODE_DECODER_INIT_FAILED,
    )
}

/**
 * 解码失败后先确认片源取不取得到（取一个字节，5 秒超时）：起播那一刻断线、超时，Exo 只知道「打不开」，
 * 不能当成解不了；404 是文件不在了——这两种换播放方式都没用
 */
object SourceProbe {
    sealed interface Verdict {
        /** 取得到（或令牌过期——开新会话换张令牌就取得到） */
        data object Reachable : Verdict
        data object Missing : Verdict
        data class Unreachable(val why: String) : Verdict
    }

    fun verdict(status: Int): Verdict = when (status) {
        in 200..299, 401, 403 -> Verdict.Reachable
        404 -> Verdict.Missing
        else -> Verdict.Unreachable("HTTP $status")
    }
}

/**
 * 网速跟不上时的「换低画质」提示（只提示、从不自动切）。每个播放单元最多一次，条件全部满足才给：
 * 1. 只算用户想看的时候：暂停期间不计；
 * 2. 触发（满足其一）：一次连续等满 8 秒；或开播后最近 5 分钟里卡了 2 次（起播、跳转、恢复后 10 秒内的缓冲不计）；
 * 3. 等待期间实测加载速度低于码率的 90%（一次长等看最快的一秒，反复卡看中位数）。
 */
class QualitySuggestion {
    data class Offer(val measuredBps: Double, val requiredBps: Double, val maxHeight: Int)

    private class Stall(val start: Int, var seconds: Int, val speeds: MutableList<Double>)

    private var clock = 0
    private var graceUntil = GRACE_SECONDS
    private val stalls = mutableListOf<Stall>()
    private var stalling = false
    var waitSeconds = 0
        private set
    private val waitSpeeds = mutableListOf<Double>()
    var offered = false
        private set

    /** 起播、跳转、从暂停恢复：接下来 10 秒的缓冲不算「卡」；新的一段等待从这一刻算起 */
    fun restartGrace() {
        graceUntil = clock + GRACE_SECONDS
        stalling = false
        waitSeconds = 0
        waitSpeeds.clear()
    }

    /** 每秒一次，只在用户想看时调用 */
    fun tick(stalled: Boolean, seeking: Boolean, loadingBps: Double?) {
        clock += 1
        stalls.removeAll { it.start + it.seconds < clock - WINDOW_SECONDS }
        val speed = loadingBps?.takeIf { it > 0 }
        if (stalled) {
            waitSeconds += 1
            speed?.let { waitSpeeds += it }
        } else {
            waitSeconds = 0
            waitSpeeds.clear()
        }
        if (!stalled || seeking || clock <= graceUntil) {
            stalling = false
            return
        }
        if (!stalling) {
            stalls += Stall(clock, 0, mutableListOf())
            stalling = true
        }
        stalls.last().seconds += 1
        speed?.let { stalls.last().speeds += it }
    }

    fun offer(streamBitrate: Double?, currentHeight: Int?): Offer? {
        if (offered || streamBitrate == null || streamBitrate <= 0) return null
        val measured = when {
            // 一次长等取最快的一秒：冷起播时引擎一段一段地取，逐秒读数时有时无，最快那秒最接近线路能力
            waitSeconds >= LONG_WAIT_SECONDS -> waitSpeeds.maxOrNull() ?: return null
            stalls.size >= MIN_STALLS -> {
                val speeds = stalls.flatMap { it.speeds }.sorted()
                if (speeds.isEmpty()) return null
                speeds[speeds.size / 2]
            }
            else -> return null
        }
        if (measured >= streamBitrate * LINK_MARGIN) return null
        val height = recommendedHeight(measured, currentHeight) ?: return null
        offered = true
        return Offer(measured, streamBitrate, height)
    }

    companion object {
        const val GRACE_SECONDS = 10
        const val WINDOW_SECONDS = 300
        const val MIN_STALLS = 2
        const val LONG_WAIT_SECONDS = 8
        const val LINK_MARGIN = 0.9

        /** 比当前低、码率留两成余量装得下实测速度的最高一档；都装不下给最低档；已在最低档返回 null */
        fun recommendedHeight(bps: Double, below: Int?): Int? {
            val ladder = listOf(1080 to 6_000_000.0, 720 to 3_000_000.0, 480 to 1_500_000.0)
            val lower = ladder.filter { (height, _) -> below == null || height < below }
            return lower.firstOrNull { it.second <= bps * 0.8 }?.first ?: lower.lastOrNull()?.first
        }
    }
}

/**
 * 播放时的网络环境：画质按它分开记（[QualityMemory]）。
 * 「在家」= 服务器地址是私有 IPv4、且本机某个网卡与它同网段；私有但网段对不上 =「在外面」（VPN 回家等）；
 * 公网地址 =「分不清」（在家经路由器回流和在外面连的是同一个地址，硬猜会把在家说成外网）。
 */
enum class PlaybackNetwork(val key: String, val label: String?) {
    Home("home", "家里网络"),
    Away("away", "外网"),
    Unknown("unknown", null);

    data class Interface(val address: Long, val netmask: Long)

    companion object {
        fun classify(serverIPv4: Long?, interfaces: List<Interface>): PlaybackNetwork {
            if (serverIPv4 == null || !isPrivate(serverIPv4)) return Unknown
            val same = interfaces.any { it.netmask != 0L && it.netmask != 0xFFFFFFFFL && it.address and it.netmask == serverIPv4 and it.netmask }
            return if (same) Home else Away
        }

        /** RFC 1918 私有网段（10/8、172.16/12、192.168/16） */
        fun isPrivate(ip: Long): Boolean = ip shr 24 == 10L || ip shr 20 == 0xAC1L || ip shr 16 == 0xC0A8L

        fun parseIPv4(text: String): Long? {
            val parts = text.split(".")
            if (parts.size != 4) return null
            var value = 0L
            for (part in parts) {
                val byte = part.toIntOrNull()?.takeIf { it in 0..255 && part.isNotEmpty() } ?: return null
                value = value shl 8 or byte.toLong()
            }
            return value
        }

        /** 当前环境。IPv4 地址直接判；域名用后台查到的地址（还没查到就发起查询，这次先算「分不清」） */
        fun current(host: String): PlaybackNetwork {
            val ip = parseIPv4(host) ?: resolved(host)
            return classify(ip, localInterfaces())
        }

        private val resolvedHosts = ConcurrentHashMap<String, Long>()
        private val pending = ConcurrentHashMap.newKeySet<String>()

        private fun resolved(host: String): Long? {
            val hit = resolvedHosts[host]
            if (hit == null && pending.add(host)) {
                thread(name = "mc-resolve", isDaemon = true) {
                    runCatching {
                        InetAddress.getAllByName(host).filterIsInstance<Inet4Address>().firstOrNull()
                            ?.let { address -> parseIPv4(address.hostAddress ?: "") }
                    }.getOrNull()?.let { resolvedHosts[host] = it }
                    pending.remove(host)
                }
            }
            return hit
        }

        private fun localInterfaces(): List<Interface> = runCatching {
            NetworkInterface.getNetworkInterfaces()?.toList().orEmpty()
                .filter { it.isUp && !it.isLoopback }
                .flatMap { nic ->
                    nic.interfaceAddresses.mapNotNull { address ->
                        val ip = (address.address as? Inet4Address)?.hostAddress?.let(::parseIPv4) ?: return@mapNotNull null
                        val prefix = address.networkPrefixLength.toInt()
                        val mask = if (prefix <= 0) 0L else (0xFFFFFFFFL shl (32 - prefix)) and 0xFFFFFFFFL
                        Interface(ip, mask)
                    }
                }
        }.getOrDefault(emptyList())
    }
}
