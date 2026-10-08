package io.movieclaw.androidtv.core.session

import io.movieclaw.androidtv.core.model.McJson
import io.movieclaw.androidtv.core.model.generated.DeviceAuthorizeRequest
import io.movieclaw.androidtv.core.model.generated.DeviceTokenView
import io.movieclaw.androidtv.core.network.ApiException
import io.movieclaw.androidtv.core.network.ApiTransport
import io.movieclaw.androidtv.core.network.ServerAddress
import io.movieclaw.androidtv.core.network.UnreachableException
import io.movieclaw.androidtv.core.network.generated.McApi
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.KSerializer
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.ConnectException

class PairingTest {
    private val server = ServerAddress.parse("192.168.1.10:3000")!!
    private val request = DeviceAuthorizeRequest("androidtv", "客厅电视", "androidtv-x", "Android 12 · BRAVIA", "0.1.0")

    @Test
    fun pollStepTransitions() {
        assertEquals(Pairing.Step.Wait(5), Pairing.step(Result.success(null), 5))
        assertEquals(Pairing.Step.Granted("tok"), Pairing.step(Result.success(DeviceTokenView(token = "tok")), 5))
        assertEquals(Pairing.Step.Wait(7), Pairing.step(Result.failure(ApiException(429, "RATE_LIMITED", "慢点")), 5))
        assertEquals(Pairing.Step.Fail(Pairing.DENIED), Pairing.step(Result.failure(ApiException(400, "AUTHORIZATION_DENIED", "x")), 5))
        assertEquals(Pairing.Step.Fail(Pairing.EXPIRED), Pairing.step(Result.failure(ApiException(400, "EXPIRED_TOKEN", "x")), 5))
        // 网络抖动：下一轮接着等，间隔不变
        assertEquals(Pairing.Step.Wait(5), Pairing.step(Result.failure(UnreachableException("nas", ConnectException())), 5))
        assertEquals(Pairing.Step.Wait(5), Pairing.step(Result.failure(ApiException(500, null, "x")), 5))
    }

    @Test
    fun authorizeFailures() {
        assertEquals(Pairing.UNSUPPORTED, Pairing.authorizeFailure(ApiException(404, null, "找不到")))
        assertEquals(Pairing.UNSUPPORTED, Pairing.authorizeFailure(ApiException(400, "VALIDATION", "x")))
        assertEquals("服务器出错了（500）", Pairing.authorizeFailure(ApiException(500, null, "服务器出错了（500）")))
    }

    @Test
    fun displayAddressDropsSchemeAndSlash() {
        assertEquals("192.168.1.10:3000/activate", Pairing.displayAddress("http://192.168.1.10:3000/activate/"))
        assertEquals("mc.example.com/activate", Pairing.displayAddress("https://mc.example.com/activate"))
    }

    /** 假服务器：按路径给响应；token 接口依次吐出 [tokens] 里的结果 */
    private class FakeServer(
        var health: String = """{"status":"ok","version":"0.33.0"}""",
        var initialized: Boolean = true,
        var authorize: () -> String = { """{"user_code":"MCLW-AB12","device_code":"dev","verification_uri":"http://192.168.1.10:3000/activate","verification_uri_complete":"http://192.168.1.10:3000/activate?code=MCLW-AB12","interval":5,"expires_in":300}""" },
        val tokens: ArrayDeque<() -> String?> = ArrayDeque(),
    ) : ApiTransport {
        val calls = mutableListOf<String>()

        override suspend fun <T> send(
            method: String,
            path: String,
            query: List<Pair<String, String>>,
            body: JsonElement?,
            response: KSerializer<T>,
            enveloped: Boolean,
        ): T {
            calls += path
            val data: String? = when (path) {
                "/health" -> health
                "/auth/bootstrap" -> """{"initialized":$initialized}"""
                "/auth/device/authorize" -> authorize()
                "/auth/device/token" -> tokens.removeFirst()()
                else -> error(path)
            }
            return McJson.decodeFromJsonElement(response, data?.let { McJson.parseToJsonElement(it) } ?: JsonNull)
        }
    }

    private class Recorder {
        val statuses = mutableListOf<PairingStatus>()
        val sleeps = mutableListOf<Long>()
        val signedIn = mutableListOf<String>()
        var clock = 0L
    }

    private fun run(fake: FakeServer, signIn: suspend (String) -> Unit = {}): Recorder {
        val rec = Recorder()
        runBlocking {
            Pairing.run(
                McApi(fake), server, request,
                onChallenge = {},
                onStatus = { rec.statuses += it },
                signIn = { rec.signedIn += it; signIn(it) },
                now = { rec.clock },
                sleep = { rec.sleeps += it; rec.clock += it },
            )
        }
        return rec
    }

    @Test
    fun waitsThenSignsInWithGrantedToken() {
        val fake = FakeServer(tokens = ArrayDeque(listOf({ null }, { throw ApiException(429, null, "慢") }, { null }, { """{"token":"mc_tok","granted_by":"admin"}""" })))
        val rec = run(fake)
        assertEquals(listOf(PairingStatus.Requesting, PairingStatus.Waiting, PairingStatus.SigningIn), rec.statuses)
        assertEquals(listOf("mc_tok"), rec.signedIn)
        // 429 之后间隔加 2 秒
        assertEquals(listOf(5_000L, 5_000L, 7_000L, 7_000L), rec.sleeps)
    }

    @Test
    fun deniedAndExpiredStop() {
        val denied = run(FakeServer(tokens = ArrayDeque(listOf({ throw ApiException(400, "AUTHORIZATION_DENIED", "x") }))))
        assertEquals(PairingStatus.Failed(Pairing.DENIED), denied.statuses.last())

        // 一直没人批准：过了有效期就停（300 秒 / 每次 5 秒）
        val pending = FakeServer(tokens = ArrayDeque(List(100) { { null } }))
        val expired = run(pending)
        assertEquals(PairingStatus.Failed(Pairing.EXPIRED), expired.statuses.last())
        assertEquals(60, pending.calls.count { it == "/auth/device/token" })
    }

    @Test
    fun precheckStopsBeforeAuthorize() {
        val old = FakeServer(health = """{"status":"ok","version":"0.27.3"}""")
        assertEquals(PairingStatus.Failed(AppModel.serverTooOld("0.27.3")), run(old).statuses.last())
        assertTrue("/auth/device/authorize" !in old.calls)

        val fresh = FakeServer(initialized = false)
        val status = run(fresh).statuses.last() as PairingStatus.Failed
        assertTrue(status.message.startsWith("这台服务器还没初始化"))

        val unsupported = FakeServer(authorize = { throw ApiException(404, null, "找不到") })
        assertEquals(PairingStatus.Failed(Pairing.UNSUPPORTED), run(unsupported).statuses.last())
    }

    @Test
    fun signInFailureIsReportedNotRetried() {
        val fake = FakeServer(tokens = ArrayDeque(listOf({ """{"token":"t"}""" })))
        val rec = run(fake) { throw ApiException(401, null, "登录已失效，请重新登录") }
        assertEquals(PairingStatus.Failed("登录已失效，请重新登录"), rec.statuses.last())
        assertEquals(1, fake.calls.count { it == "/auth/device/token" })
    }
}
