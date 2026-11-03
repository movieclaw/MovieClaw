package io.movieclaw.android.core.network

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.contentOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import java.net.Inet4Address
import java.net.NetworkInterface
import java.security.SecureRandom
import java.util.Base64
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.coroutines.resume

private val Context.addressStore by preferencesDataStore(name = "mc_addresses")

/**
 * 内外双地址自动选连（docs/design/server-addresses.md §4；iOS `ServerRoutes` 的对应物）。
 *
 * 服务器的身份是登录地址（[SessionRepository] 不迁移）；这里只维护一张「路由表」：
 * 拉地址簿 → 按当前网络预筛 → 竞速探测（/health?nonce= 验实例号 + proof）→
 * 把选中的地址挂进 [ApiFactory.setRoutedBase]，之后的请求自动走新地址。
 *
 * 预筛与竞速口径照设计稿：只剩蜂窝不试内网；开着 VPN 不等于能回家（出国代理也是系统 VPN），
 * 内网探测通了才算经 VPN 回家；记过的网络（含 VPN 隧道）直接用记忆（后台核实）；
 * 内网 1.5s / 外网 5s 超时；外网晚 250ms 发（Happy Eyeballs）；先通先用。
 */
@Singleton
class ServerAddressBook @Inject constructor(
    @ApplicationContext private val context: Context,
    private val apiFactory: ApiFactory,
) {
    data class Entry(val url: String, val kind: String, val source: String)

    data class Selection(
        val origin: String,
        /** 当前选中的入口（绝对地址，含协议+主机+端口） */
        val url: String,
        val kind: String,
        val fingerprint: String,
        /** 是否本轮竞速验证过（false = 按记忆直接用，后台核实） */
        val verified: Boolean,
    )

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val json = Json { ignoreUnknownKeys = true }
    private val probeClient = OkHttpClient.Builder()
        .connectTimeout(5, TimeUnit.SECONDS)
        .readTimeout(5, TimeUnit.SECONDS)
        .build()

    private val _selection = MutableStateFlow<Selection?>(null)
    val selection: StateFlow<Selection?> = _selection.asStateFlow()

    private val _book = MutableStateFlow<List<Entry>>(emptyList())
    val book: StateFlow<List<Entry>> = _book.asStateFlow()

    /** 上一次成功拉到的地址簿：网络刚断开/刚出门时当前入口不可达，用它直接竞速（§4.5） */
    @Volatile private var lastBook: ServerAddressesView? = null

    @Volatile private var selecting = false
    @Volatile private var reselectQueued = false
    @Volatile private var callbackRegistered = false

    /** 供 RemoteImage / 取流拼地址用：返回该登录 origin 当前应使用的入口 base（无则原样返回） */
    fun baseFor(origin: String?): String? {
        val s = _selection.value ?: return null
        if (s.origin != origin) return null
        return s.url.trimEnd('/')
    }

    /** 冷启动 / 登录后 / 网络变化时调用：选一个地址并挂上 */
    fun selectAndApply(origin: String?) {
        if (origin.isNullOrBlank()) return
        if (selecting) {
            // 选路期间又来了事件（比如连着换网络）：记一笔，本轮结束后再选一次，不能丢
            reselectQueued = true
            return
        }
        selecting = true
        scope.launch {
            // finally 复位：任何异常/超时都不能把「正在选路」永久卡住
            // （否则网络变化与设置页「重新选择」会被永久忽略，见 PR #1001 评审）
            try {
                val won = runCatching { select(origin) }.getOrDefault(false)
                scheduleRetryIfLost(origin, won)
            } finally {
                selecting = false
                registerNetworkCallback()
                if (reselectQueued) {
                    reselectQueued = false
                    _selection.value?.let { selectAndApply(it.origin) }
                }
            }
        }
    }

    /** 设置 → 网络：手动重选（忽略记忆里的结论重新竞速） */
    fun reselect(origin: String?) {
        scope.launch {
            context.addressStore.edit { prefs ->
                val fp = fingerprint()
                prefs.remove(stringPreferencesKey(key(fp)))
            }
            selectAndApply(origin)
        }
    }

    // ── 事件驱动（§4.5） ──

    private val backgroundedAt = java.util.concurrent.atomic.AtomicLong(0L)
    @Volatile private var lastHardErrorAt = 0L

    init {
        // 请求层硬错误 → 重新选路；同一波失败只触发一次
        ServerRoutes.onHardError = {
            val now = android.os.SystemClock.elapsedRealtime()
            if (now - lastHardErrorAt >= 15_000L) {
                lastHardErrorAt = now
                _selection.value?.let { selectAndApply(it.origin) }
            }
        }
    }

    /** 连续几轮一个入口都没验过（同一个网络上）；验过一次或换了网络就清零 */
    @Volatile private var lostRounds = 0
    @Volatile private var lostFingerprint: String? = null

    /**
     * 一轮下来一个都没验过（刚换网络还没通、外网探测恰好超时）：之后不会再有网络事件叫醒选路，
     * 手里只剩登录地址——稍后补试几次，别等到冷启动才恢复。
     */
    private fun scheduleRetryIfLost(origin: String, won: Boolean) {
        val fp = fingerprint()
        if (won || fp != lostFingerprint) {
            lostRounds = 0
            lostFingerprint = fp
        }
        if (won || lostRounds >= LOST_RETRY_DELAYS_MS.size) return
        val wait = LOST_RETRY_DELAYS_MS[lostRounds++]
        scope.launch {
            delay(wait)
            // 期间换了账号 / 服务器就不补了（新账号自己会选）
            _selection.value?.takeIf { it.origin == origin }?.let { selectAndApply(it.origin) }
        }
    }

    fun onAppBackground() {
        backgroundedAt.set(android.os.SystemClock.elapsedRealtime())
    }

    /** 回前台且在后台超过 10 分钟：重选一次（与可达性的「久别回来」同口径） */
    fun onAppForeground() {
        val at = backgroundedAt.getAndSet(0L)
        if (at == 0L) return
        if (android.os.SystemClock.elapsedRealtime() - at < 10 * 60_000L) return
        _selection.value?.let { selectAndApply(it.origin) }
    }

    private val selectionMutex = Mutex()

    /** 播放断流：串行等待正在进行的选路，再强制竞速一轮；不能只发事件就重开旧入口。 */
    suspend fun reselectAndAwait(origin: String) = withContext(Dispatchers.IO) {
        selectionMutex.withLock { selectLocked(origin, force = true) }
    }

    /** 选一轮；返回本轮是否有入口验证通过（没有的话调用方稍后再试） */
    private suspend fun select(origin: String): Boolean = selectionMutex.withLock { selectLocked(origin) }

    private suspend fun selectLocked(origin: String, force: Boolean = false): Boolean {
        val api = apiFactory.forOrigin(origin)
        val fp = fingerprint()
        val previousSelection = _selection.value
        val networkJustChanged = previousSelection != null && previousSelection.fingerprint != fp
        val cached = lastBook
        // 网络刚变（Wi-Fi 掉线 / 出门 / 回家）且手里有上次的地址簿：直接拿它竞速。
        // 此时当前入口往往已经不可达，先去内网入口拉地址簿会干等 5 秒超时，切换就“感觉没反应”。
        // 当前入口没验过（上一轮一个都没通、这是补试）同理：别先去它那儿拉地址簿。
        val currentUnverified = previousSelection?.verified == false
        val fetched = if ((force || networkJustChanged || currentUnverified) && cached != null) {
            null
        } else {
            runCatching { api.serverAddresses().dataOrThrow() }.getOrNull()
        }
        if (fetched != null) lastBook = fetched
        val book = fetched ?: cached ?: return false
        val entries = book.addresses.map { Entry(it.url.trimEnd('/'), it.kind, it.source) }
        _book.value = entries
        val loginUrl = origin.trimEnd('/')
        val candidates = (entries.map { it.url } + loginUrl).distinct()

        val net = readNetwork()
        val remembered = withTimeoutOrNull(2_000) {
            context.addressStore.data.first()[stringPreferencesKey(key(fp))]
        }?.trimEnd('/')
        val rememberedValid = remembered?.let { r -> candidates.firstOrNull { it == r } }

        val plan = planRoutes(
            entries = entries,
            loginUrl = loginUrl,
            remembered = rememberedValid.takeUnless { force },
            cellular = net?.cellularOnly == true,
            vpn = net?.vpn != null,
            inSameSubnet = { inSameSubnet(it, net) },
        )
        val lanOrdered = plan.lan
        val wanOrdered = plan.wan
        val prePick = plan.prePick

        // 当前在外网、网络变化后预筛出了内网候选：只探内网，不重探外网（§4.5）
        val previous = _selection.value
        val onlyLanUpgrade = !force && previous != null && previous.kind != "lan" &&
            previous.fingerprint != fp && lanOrdered.isNotEmpty()
        val wanToRace = if (onlyLanUpgrade) emptyList() else wanOrdered
        if (onlyLanUpgrade) android.util.Log.i("McRoutes", "外网回内网：只探内网候选")

        if (prePick != null) {
            val trusted = listOf(loginUrl, prePick).distinct()
            ServerTrust.allow(origin, trusted)
            apply(origin, prePick, kindOf(entries, prePick), verified = false, alternates = trusted)
            android.util.Log.i("McRoutes", "预选 $prePick")
        } else if (isStaleLan(previousSelection, fp)) {
            // 网络变了又预选不出：上个网络的内网入口（连同 lan / vpn 路线）不留着等竞速，先回登录地址（#1089）
            ServerTrust.allow(origin, listOf(loginUrl))
            apply(origin, loginUrl, "login", verified = false, alternates = listOf(loginUrl))
        }

        // 竞速核实：每个候选独立超时；第一个通过就切；内网后到就升级（§4.3）
        val nonce = newNonce()
        val verified = mutableListOf<String>()
        raceRoutes(
            lan = lanOrdered,
            wan = wanToRace,
            nonce = nonce,
            instanceId = book.instanceId,
            hostKey = book.hostKey,
        ) { url, isLan ->
            if (url !in verified) verified += url
            val trusted = (listOf(loginUrl) + verified).distinct()
            ServerTrust.allow(origin, trusted)
            if (shouldSwitchTo(_selection.value, fp, url, isLan)) {
                apply(origin, url, kindOf(entries, url), verified = true, alternates = trusted)
                android.util.Log.i(
                    "McRoutes",
                    "验证通过 $url（${if (isLan) "内网" else "外网"}），已切换",
                )
            }
        }

        val settle = settleRound(_selection.value, fp, prePicked = prePick != null, verified = verified)
        if (settle.fallbackToLogin) {
            // 一个都验不过（出门、服务器不可达…）：回到登录地址本身
            ServerTrust.allow(origin, listOf(loginUrl))
            apply(origin, loginUrl, "login", verified = false, alternates = listOf(loginUrl))
        }
        if (settle.remember) {
            _selection.value?.let { rememberChoice(fp, it.url) }
        }
        val finalUrl = (_selection.value?.url ?: loginUrl).trimEnd('/')
        ServerRoutes.alternates = (verified + loginUrl).map { it.trimEnd('/') }
            .filter { it != finalUrl }
            .distinct()
        return verified.isNotEmpty()
    }

    private fun apply(
        origin: String,
        url: String,
        kind: String,
        verified: Boolean,
        alternates: List<String>,
    ) {
        val apiBase = url + "/api/v1"
        if (url.trimEnd('/') == origin.trimEnd('/')) {
            apiFactory.setRoutedBase(origin, null)
        } else {
            apiFactory.setRoutedBase(origin, apiBase)
        }
        // 图片等按 origin 拼 URL 的地方跟着换入口
        ServerRoutes.provider = { o -> if (o == null || o == origin) url.trimEnd('/') else null }
        ServerRoutes.entry = url.trimEnd('/')
        // 服务端按这个头判内外网（§5.2）：内网走 lan；经 VPN 回家走 vpn；其余 wan。
        // 开着 VPN 不等于回家（出国代理也是系统 VPN）：没验过的不标 vpn，探测通过才算（#1089）
        ServerRoutes.route = routeFor(kind, url).let {
            if (!verified && it == ServerRoutes.Route.VPN) ServerRoutes.Route.WAN else it
        }
        // 其它已验证入口：当前地址硬错误时幂等请求换过去
        ServerRoutes.alternates = alternates.map { it.trimEnd('/') }
            .filter { it != url.trimEnd('/') }
            .distinct()
        _selection.value = Selection(origin, url, kind, fingerprint(), verified)
        android.util.Log.i(
            "McRoutes",
            "当前入口 $url（${if (verified) "已验证" else "预选"}，路线 ${ServerRoutes.route.header}，" +
                "备选 ${ServerRoutes.alternates.size} 个）",
        )
    }

    /** 路线判定：内网地址 + VPN 通路且不在任何实体网卡网段里 → vpn（§4.9）；其余按 lan / wan */
    private fun routeFor(kind: String, url: String): ServerRoutes.Route {
        if (kind != "lan") return ServerRoutes.Route.WAN
        return if (isVpnRoute(url)) ServerRoutes.Route.VPN else ServerRoutes.Route.LAN
    }

    private fun isVpnRoute(lanUrl: String): Boolean {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return false
        val network = cm.activeNetwork ?: return false
        val caps = cm.getNetworkCapabilities(network) ?: return false
        if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return false
        // 代理 App 的 TUN（Clash / Surge 一类）地址在 198.18.0.0/15：不算 VPN 回家
        val proxyTun = cm.getLinkProperties(network)?.linkAddresses.orEmpty().any { link ->
            val a = link.address
            a is Inet4Address && a.address.let {
                (it[0].toInt() and 0xff) == 198 && (it[1].toInt() and 0xff) == 18
            }
        }
        if (proxyTun) return false
        // 内网地址落在任一实体网卡的 /24 里 → 就是普通局域网（VPN 只是并存）
        val host = runCatching { java.net.URI(lanUrl).host }.getOrNull() ?: return false
        return !hostInPhysicalSubnet(host)
    }

    private fun hostInPhysicalSubnet(host: String): Boolean {
        val prefix = host.substringBeforeLast('.', "")
        if (prefix.isEmpty()) return false
        return runCatching {
            java.util.Collections.list(NetworkInterface.getNetworkInterfaces()).any { iface ->
                val name = iface.name.orEmpty()
                val physical = !name.startsWith("tun") && !name.startsWith("ppp") &&
                    !name.startsWith("rmnet") && !name.startsWith("dummy")
                iface.isUp && !iface.isLoopback && physical &&
                    java.util.Collections.list(iface.inetAddresses).any { addr ->
                        addr is Inet4Address && addr.hostAddress?.startsWith("$prefix.") == true
                    }
            }
        }.getOrDefault(false)
    }

    private fun kindOf(entries: List<Entry>, url: String): String =
        entries.firstOrNull { it.url == url }?.kind
            ?: if (isPrivateLiteral(url)) "lan" else "wan"

    private data class ProbeResult(val url: String, val isLan: Boolean, val ok: Boolean)

    /**
     * 竞速并**边验边切**（§4.3）：每个候选独立超时；第一个通过校验的立刻回调；
     * 外网先通过时继续等内网，内网在超时前通过就再回调一次（调用方负责升级、不回退）。
     */
    private suspend fun raceRoutes(
        lan: List<String>,
        wan: List<String>,
        nonce: String,
        instanceId: String,
        hostKey: String,
        onVerified: suspend (url: String, isLan: Boolean) -> Unit,
    ): List<String> {
        if (lan.isEmpty() && wan.isEmpty()) return emptyList()
        val verified = mutableListOf<String>()
        val results = Channel<ProbeResult>(Channel.UNLIMITED)
        return kotlinx.coroutines.coroutineScope {
            val jobs = mutableListOf<Job>()
            lan.forEach { url ->
                jobs += launch {
                    val ok = runCatching {
                        verifyHealth(url, nonce, instanceId, hostKey, LAN_PROBE_TIMEOUT_MS)
                    }.getOrDefault(false)
                    results.send(ProbeResult(url, true, ok))
                }
            }
            // 有内网候选时外网晚 250ms 发；只有外网候选时立即发（§4.3）
            val wanDelay = if (lan.isNotEmpty()) WAN_PROBE_DELAY_MS else 0L
            wan.forEach { url ->
                jobs += launch {
                    if (wanDelay > 0) delay(wanDelay)
                    val ok = runCatching {
                        verifyHealth(url, nonce, instanceId, hostKey, WAN_PROBE_TIMEOUT_MS)
                    }.getOrDefault(false)
                    results.send(ProbeResult(url, false, ok))
                }
            }
            var remaining = lan.size + wan.size
            withTimeoutOrNull(RACE_TIMEOUT_MS) {
                while (remaining > 0) {
                    val r = results.receive()
                    remaining--
                    if (!r.ok) continue
                    verified += r.url
                    onVerified(r.url, r.isLan)
                    // 内网已通：不再等外网，立即收敛
                    if (r.isLan) break
                }
            }
            jobs.forEach { it.cancel() }
            verified
        }
    }

    private data class ProbeResponse(val code: Int, val specHash: String?, val body: String?)

    /**
     * GET /health?nonce= → 三关（§4.8）：响应带 `X-Movieclaw-Spec-Hash`、instance_id 一致、
     * proof 能用 host_key 验过（旧服务器没有 host_key 时只校验前两关）。
     * 每个候选独立超时；超时会 cancel 掉在飞的 HTTP 请求。
     */
    private suspend fun verifyHealth(
        url: String,
        nonce: String,
        instanceId: String,
        hostKey: String,
        timeoutMs: Long,
    ): Boolean {
        val call = probeClient.newCall(
            Request.Builder()
                .url(url.trimEnd('/') + "/api/v1/health?nonce=" + nonce)
                .build(),
        )
        val response = withTimeoutOrNull(timeoutMs) {
            suspendCancellableCoroutine<ProbeResponse?> { cont ->
                cont.invokeOnCancellation { runCatching { call.cancel() } }
                call.enqueue(object : okhttp3.Callback {
                    override fun onFailure(call: okhttp3.Call, e: java.io.IOException) {
                        if (cont.isActive) cont.resume(null)
                    }

                    override fun onResponse(call: okhttp3.Call, response: okhttp3.Response) {
                        val parsed = response.use { resp ->
                            ProbeResponse(
                                code = resp.code,
                                specHash = resp.header("X-Movieclaw-Spec-Hash"),
                                body = runCatching { resp.body?.string() }.getOrNull(),
                            )
                        }
                        if (cont.isActive) cont.resume(parsed)
                    }
                })
            }
        } ?: return false
        // 第一关：门户页 / 反代错误页没有这个头
        if (response.specHash.isNullOrBlank()) return false
        if (response.code != 200 && response.code != 401 && response.code != 403) return false
        val body = response.body ?: return false
        val obj = runCatching { json.parseToJsonElement(body).jsonObject }.getOrNull() ?: return false
        // 无信封结构：instance_id / proof 在顶层；spec hash 在响应头（body 里没有）
        val id = obj["instance_id"]?.jsonPrimitive?.contentOrNull ?: return false
        if (id != instanceId) return false
        val proof = obj["proof"]?.jsonPrimitive?.contentOrNull
        if (hostKey.isNotEmpty()) {
            if (proof.isNullOrEmpty()) return false
            if (!verifyHealthProof(hostKey, nonce, id, proof)) return false
        }
        return true
    }

    private fun newNonce(): String {
        val bytes = ByteArray(16)
        SecureRandom().nextBytes(bytes)
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
    }

    // ── 网络指纹与回调 ──

    private fun key(fingerprint: String) = "chosen_" + fingerprint.hashCode().toString()

    /** 记这个网络选中的入口；只留最近 8 个网络（§4.4） */
    private suspend fun rememberChoice(fingerprint: String, url: String) {
        context.addressStore.edit { prefs ->
            val hash = fingerprint.hashCode().toString()
            prefs[stringPreferencesKey("chosen_$hash")] = url
            prefs[stringPreferencesKey("at_$hash")] = System.currentTimeMillis().toString()
            val chosen = prefs.asMap().keys.filter { it.name.startsWith("chosen_") }
            if (chosen.size > 8) {
                val oldest = chosen.sortedBy { k ->
                    prefs[stringPreferencesKey("at_" + k.name.removePrefix("chosen_"))]
                        ?.toLongOrNull() ?: 0L
                }
                oldest.take(oldest.size - 8).forEach { k ->
                    prefs.remove(k)
                    prefs.remove(stringPreferencesKey("at_" + k.name.removePrefix("chosen_")))
                }
            }
        }
    }

    /** 网络指纹见 [NetSnapshot.fingerprint]（不读 Wi-Fi 名，不需要定位权限） */
    internal fun fingerprint(): String = readNetwork()?.fingerprint ?: "unknown"

    /**
     * 读当前网络。开着 VPN 时默认网络是隧道本身：实体网络（Wi-Fi / 有线 / 蜂窝）另找，
     * 传输类型和网段按实体网络算，隧道网段单独记。
     */
    private fun readNetwork(): NetSnapshot? {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return null
        val active = cm.activeNetwork ?: return null
        val activeCaps = cm.getNetworkCapabilities(active) ?: return null
        val vpn = activeCaps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
        val (physical, caps) = if (!vpn) active to activeCaps else physicalNetwork(cm) ?: (active to activeCaps)
        val transport = when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cell"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "eth"
            else -> "other"
        }
        val cellularOnly = caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) &&
            !caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) &&
            !caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
        return NetSnapshot(
            transport = transport,
            subnet = subnetOf(cm.getLinkProperties(physical)),
            vpn = if (vpn) subnetOf(cm.getLinkProperties(active)) else null,
            cellularOnly = cellularOnly,
        )
    }

    /** VPN 底下的实体网络：Wi-Fi > 有线 > 蜂窝 */
    private fun physicalNetwork(cm: ConnectivityManager): Pair<android.net.Network, NetworkCapabilities>? {
        @Suppress("DEPRECATION")
        val all = cm.allNetworks
        return all.mapNotNull { n -> cm.getNetworkCapabilities(n)?.let { n to it } }
            .filter { (_, c) ->
                !c.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
                    c.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            }
            .minByOrNull { (_, c) ->
                when {
                    c.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> 0
                    c.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> 1
                    c.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> 2
                    else -> 3
                }
            }
    }

    private fun subnetOf(lp: android.net.LinkProperties?): String =
        lp?.linkAddresses
            ?.mapNotNull { it.address as? Inet4Address }
            ?.firstOrNull()
            ?.hostAddress
            ?.substringBeforeLast('.', "0.0.0.0")
            ?.let { "$it.0/24" }
            ?: "nosubnet"

    private fun inSameSubnet(url: String, net: NetSnapshot?): Boolean {
        val subnet = net?.subnet ?: return false
        if (subnet == "nosubnet") return false
        val host = runCatching { java.net.URI(url).host }.getOrNull() ?: return false
        return host.startsWith(subnet.removeSuffix(".0/24") + ".")
    }

    /** 网络变化 → 重新选路（事件驱动，不轮询） */
    private fun registerNetworkCallback() {
        if (callbackRegistered) return
        callbackRegistered = true
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
        val request = android.net.NetworkRequest.Builder().build()
        runCatching {
            cm.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
                private var lastFingerprint = fingerprint()
                override fun onCapabilitiesChanged(network: android.net.Network, caps: NetworkCapabilities) {
                    val fp = fingerprint()
                    if (fp != lastFingerprint) {
                        lastFingerprint = fp
                        _selection.value?.let { selectAndApply(it.origin) }
                    }
                }
            })
        }
    }
}

/**
 * Ed25519：proof = sign("movieclaw-health\n" + instance_id + "\n" + nonce)，base64url。
 *
 * 直接用 i2p 的 [net.i2p.crypto.eddsa.EdDSAEngine]，**不能**走 `Signature.getInstance("EdDSA")`：
 * Android 的系统密码库没有这个算法名（实测 Android 16 报 NoSuchAlgorithmException），i2p 也没注册成 Provider，
 * 结果是服务器一带主机公钥，所有入口都验不过、自动选连只剩预选和回登录地址。JVM 单测里 JDK 自带 EdDSA，掩盖了这一点。
 */
internal fun verifyHealthProof(hostKeyB64: String, nonce: String, instanceId: String, proofB64: String): Boolean = runCatching {
    val spec = net.i2p.crypto.eddsa.spec.EdDSANamedCurveTable.getByName(
        net.i2p.crypto.eddsa.spec.EdDSANamedCurveTable.ED_25519,
    )
    val publicKey = net.i2p.crypto.eddsa.EdDSAPublicKey(
        net.i2p.crypto.eddsa.spec.EdDSAPublicKeySpec(Base64.getUrlDecoder().decode(hostKeyB64), spec),
    )
    val verifier = net.i2p.crypto.eddsa.EdDSAEngine(java.security.MessageDigest.getInstance(spec.hashAlgorithm))
    verifier.initVerify(publicKey)
    verifier.update("movieclaw-health\n$instanceId\n$nonce".toByteArray(Charsets.UTF_8))
    verifier.verify(Base64.getUrlDecoder().decode(proofB64))
}.getOrDefault(false)

/** 一轮没验过任何入口后的补试间隔（见 [ServerAddressBook.scheduleRetryIfLost]） */
private val LOST_RETRY_DELAYS_MS = longArrayOf(5_000L, 15_000L, 45_000L)

/**
 * 竞速里某个入口验证通过，要不要切过去（§4.3：先通先用、内网后到就升级、不从内网退回外网）。
 *
 * 「手里已有验证过的入口就不换」只对**这个网络上**验过的成立：出门后手里那条还是家里验过的内网地址，
 * 外网验过了也不切的话，就一直挂在连不上的内网上（蜂窝下连内网多是超时＝软错误，不会再触发重选），
 * 只能冷启动恢复。
 */
internal fun shouldSwitchTo(
    current: ServerAddressBook.Selection?,
    fingerprint: String,
    url: String,
    isLan: Boolean,
): Boolean {
    if (current == null || !current.verified || current.fingerprint != fingerprint) return true
    if (current.url.trimEnd('/') == url) return true
    return isLan && current.kind != "lan"
}

/** 一轮竞速后的收尾：要不要回登录地址、要不要把当前入口记到这个网络名下 */
internal data class RoundSettle(val fallbackToLogin: Boolean, val remember: Boolean)

/**
 * - 回登录地址：没有预选、手里也没有能用的入口时。手里那条若是**别的网络上**选的内网入口、本轮又没验过，
 *   也不能接着用（换了网络，内网多半已不可达）；别的网络上验过的外网入口照旧保留（§4.5 外网回内网只探内网）。
 * - 记忆：只记本轮在这个网络上真验过的入口，别把上个网络的结论记到新网络名下。
 */
internal fun settleRound(
    current: ServerAddressBook.Selection?,
    fingerprint: String,
    prePicked: Boolean,
    verified: List<String>,
): RoundSettle {
    val fallback = !prePicked && (current == null || !current.verified || isStaleLan(current, fingerprint))
    val remember = !fallback && current != null && current.verified &&
        current.fingerprint == fingerprint && current.url in verified
    return RoundSettle(fallbackToLogin = fallback, remember = remember)
}

/** 手里那条是**别的网络上**选的内网入口：换了网络，内网多半已不可达，lan / vpn 路线也不再成立 */
internal fun isStaleLan(current: ServerAddressBook.Selection?, fingerprint: String): Boolean =
    current != null && current.kind == "lan" && current.fingerprint != fingerprint

/**
 * 本机网络：实体网络的传输类型与 IPv4 /24；[vpn] 为 VPN 隧道的 /24（隧道没有 IPv4 时为 `nosubnet`），没开 VPN 为 null。
 */
internal data class NetSnapshot(
    val transport: String,
    val subnet: String,
    val vpn: String?,
    val cellularOnly: Boolean,
) {
    /**
     * 网络指纹 = 传输类型 + IPv4 /24，开着 VPN 时再加隧道网段：开关 VPN、换一条隧道（回家的 WireGuard ↔ 出国代理）
     * 都算换了网络，要重新选、记忆也分开（#1089）。没开 VPN 时与旧格式相同，已记的结论不失效。
     */
    val fingerprint: String get() = "$transport|$subnet" + (vpn?.let { "|vpn:$it" } ?: "")
}

/** 预筛结果：参加竞速的内网 / 外网候选（已排序），以及不发请求先用的入口（null = 不预选） */
internal data class RoutePlan(val lan: List<String>, val wan: List<String>, val prePick: String?)

/**
 * 预筛 + 预选（§4.2 / §4.4，不发请求）。
 * - 只剩蜂窝不试内网；开着 VPN 时内网值得一试（Tailscale / WireGuard 回家），但只是参加竞速；
 * - 候选排序：记忆 > 同网段内网 > 登录地址（非纯蜂窝）> 外网；
 * - 预选只能用「本来就信得过」的入口：登录地址本身，或 https（证书已验过主机名）。http 内网记忆要等 /health 验过。
 *   登录地址是内网 IP、人却不在那个网段时不预选它，先走 https 外网——**开着 VPN 也一样**：出国代理
 *   （Shadowrocket 一类）也是系统 VPN，常把私网段排除在隧道外，内网探测通了才算经 VPN 回家（#1089）。
 *   这个网络（含这条隧道）记过登录地址时照旧直接用。
 */
internal fun planRoutes(
    entries: List<ServerAddressBook.Entry>,
    loginUrl: String,
    remembered: String?,
    cellular: Boolean,
    vpn: Boolean,
    inSameSubnet: (String) -> Boolean,
): RoutePlan {
    val lanReachable = !cellular || vpn
    val lanCandidates = entries.filter { it.kind == "lan" }
        .map { it.url }
        .filter { lanReachable }
    val wanCandidates = entries.filter { it.kind == "wan" }.map { it.url }
    val inSubnet = lanCandidates.firstOrNull { !cellular && inSameSubnet(it) }

    fun ordered(list: List<String>): List<String> {
        val rememberedOne = remembered?.takeIf { it in list }
        val inSubnetOne = inSubnet?.takeIf { it in list }
        return listOfNotNull(rememberedOne, inSubnetOne) + list.filter { it != rememberedOne && it != inSubnetOne }
    }

    val lan = ordered(
        lanCandidates.ifEmpty { listOfNotNull(loginUrl.takeIf { isPrivateLiteral(it) }) },
    )
    val wan = ordered(
        (wanCandidates + listOfNotNull(loginUrl.takeIf { wanCandidates.isEmpty() && !cellular }))
            .filter { it !in lanCandidates }
            .distinct(),
    )

    val loginUsable = !isPrivateLiteral(loginUrl) || remembered == loginUrl ||
        (!cellular && inSameSubnet(loginUrl))
    val prePick = buildList {
        remembered?.let(::add)
        inSubnet?.let(::add)
        add(loginUrl)
        addAll(wan)
    }.distinct().firstOrNull { url ->
        if (url == loginUrl) loginUsable else url.startsWith("https://")
    }
    return RoutePlan(lan = lan, wan = wan, prePick = prePick)
}

internal fun isPrivateLiteral(url: String): Boolean {
    val host = runCatching { java.net.URI(url).host }.getOrNull() ?: return false
    return host.startsWith("10.") || host.startsWith("192.168.") ||
        Regex("^172\\.(1[6-9]|2\\d|3[01])\\.").containsMatchIn(host)
}

/** 竞速总超时：内网 1.5s、外网 5s，再留 1.5s 余量；到点没赢家就回登录地址。 */
private const val RACE_TIMEOUT_MS = 6_500L

/** 单候选探测超时（§4.3）：内网 1.5s、外网 5s；外网晚 250ms 发（Happy Eyeballs） */
private const val LAN_PROBE_TIMEOUT_MS = 1_500L
private const val WAN_PROBE_TIMEOUT_MS = 5_000L
private const val WAN_PROBE_DELAY_MS = 250L

/**
 * 「先通先用」竞速（评审问题 2 的修复）：内网候选立即探测、外网晚 [wanDelayMs] 发（Happy Eyeballs 思路），
 * 任何一路先回 true 即返回；全部失败或到 [timeoutMs] 仍未成功就返回 null，调用方据此回落到登录地址。
 *
 * 独立成函数是为了可单测：不需要真实网络即可验证「全部失败会返回」「先成功者胜」。
 */
internal suspend fun <T> raceFirst(
    lan: List<T>,
    wan: List<T>,
    timeoutMs: Long,
    probe: suspend (candidate: T, timeoutMs: Long) -> Boolean,
    lanTimeoutMs: Long = 1_500L,
    wanTimeoutMs: Long = 5_000L,
    wanDelayMs: Long = 250L,
): T? = kotlinx.coroutines.coroutineScope {
    val winner = java.util.concurrent.atomic.AtomicReference<T?>(null)

    suspend fun run(candidate: T, timeout: Long) {
        if (probe(candidate, timeout)) winner.compareAndSet(null, candidate)
    }

    lan.forEach { candidate -> launch { run(candidate, lanTimeoutMs) } }
    wan.forEach { candidate ->
        launch {
            kotlinx.coroutines.delay(wanDelayMs)
            run(candidate, wanTimeoutMs)
        }
    }
    kotlinx.coroutines.withTimeoutOrNull(timeoutMs) {
        while (winner.get() == null) kotlinx.coroutines.delay(50)
    }
    winner.get()
}
