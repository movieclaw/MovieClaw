package io.movieclaw.androidtv.core.session

import io.movieclaw.androidtv.core.model.generated.DeviceAuthorizeRequest
import io.movieclaw.androidtv.core.model.generated.DeviceAuthorizeView
import io.movieclaw.androidtv.core.model.generated.DeviceTokenRequest
import io.movieclaw.androidtv.core.model.generated.DeviceTokenView
import io.movieclaw.androidtv.core.network.ApiException
import io.movieclaw.androidtv.core.network.ServerAddress
import io.movieclaw.androidtv.core.network.UnreachableException
import io.movieclaw.androidtv.core.network.generated.McApi
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay

/** 扫码登录的状态行（TVPairingLogin.Status） */
sealed interface PairingStatus {
    data object Requesting : PairingStatus
    data object Waiting : PairingStatus
    data object SigningIn : PairingStatus
    data class Failed(val message: String) : PairingStatus
}

/**
 * 扫码登录（TVPairingLogin.swift，协议见 docs/design/device-auth.md §2）：`authorize` 拿到配对码与只有本机知道的
 * device_code，按服务端给的间隔轮询 `token`——未批准继续等、429 退避、批准后拿到令牌（只交付这一次）、
 * 拒绝或过期就停下，让人重新发起（不静默重试）。
 *
 * 比 Apple 端多两处（docs 里「要修而不是照抄」）：发起前先测服务器（健康、最低版本、是否初始化），
 * 不是 MovieClaw / 版本太旧时直接说清楚；拿到令牌后登录失败就停下报错，不再接着轮询一个已经兑换掉的码。
 */
object Pairing {
    const val UNSUPPORTED = "这台服务器还不支持扫码登录，请先把服务器升级到最新版，或改用账号密码登录"
    const val EXPIRED = "配对码已过期，请换一个码重新扫"
    const val DENIED = "在手机上点了拒绝。要登录的话请换一个码重新扫"

    /** 一次轮询之后怎么办 */
    sealed interface Step {
        /** 接着等，下次隔 [interval] 秒 */
        data class Wait(val interval: Long) : Step
        data class Granted(val token: String) : Step
        data class Fail(val message: String) : Step
    }

    /** 轮询结果 → 下一步（纯函数）：null = 还没批准；429 退避 2 秒；400 拒绝 / 过期；网络抖动下一轮接着等 */
    fun step(result: Result<DeviceTokenView?>, interval: Long): Step {
        val error = result.exceptionOrNull()
        if (error == null) {
            val granted = result.getOrNull() ?: return Step.Wait(interval)
            return Step.Granted(granted.token)
        }
        if (error is ApiException) {
            if (error.status == 429) return Step.Wait(interval + 2)
            if (error.status == 400) return Step.Fail(if (error.code == "AUTHORIZATION_DENIED") DENIED else EXPIRED)
        }
        return Step.Wait(interval)
    }

    /** 发起配对失败的说明：老服务器不认这种配对（或没有配对接口）只能用账号密码 */
    fun authorizeFailure(error: Throwable): String =
        if (error is ApiException && error.status in setOf(400, 404, 405)) UNSUPPORTED else error.message ?: "申请配对码失败"

    /** 批准页地址给人看的写法：去掉 `http(s)://`、末尾斜杠（「192.168.1.10:3000/activate」） */
    fun displayAddress(uri: String): String = uri.removePrefix("https://").removePrefix("http://").removeSuffix("/")

    /**
     * 发起前测一下服务器：是不是 MovieClaw、版本够不够、初始化了没有。有问题返回给人看的说明，没问题返回 null。
     * 文案与账号密码登录（AppModel.probe）一致。
     */
    suspend fun precheck(api: McApi, server: ServerAddress): String? = try {
        val health = api.healthCheck()
        val version = health.version
        when {
            health.status != "ok" -> "服务器状态异常：${health.status}"
            version != null && !Versions.atLeast(version, AppModel.MIN_SERVER_VERSION) -> AppModel.serverTooOld(version)
            !api.authBootstrapStatus().initialized -> "这台服务器还没初始化：请先在浏览器里打开 ${server.displayString} 创建管理员账号。"
            else -> null
        }
    } catch (e: ApiException) {
        "该地址能访问，但不是 MovieClaw 服务器（请填写浏览器打开 MovieClaw 时地址栏里的地址）"
    } catch (e: UnreachableException) {
        e.message
    }

    /**
     * 发起 → 轮询，直到批准（[signIn]）、被拒、过期或出错。协程取消即停（「换一个码」、离开页面）。
     * [now] 与 [sleep] 可替换，单元测试用假时钟。
     */
    suspend fun run(
        api: McApi,
        server: ServerAddress,
        request: DeviceAuthorizeRequest,
        onChallenge: (DeviceAuthorizeView?) -> Unit,
        onStatus: (PairingStatus) -> Unit,
        signIn: suspend (token: String) -> Unit,
        now: () -> Long = System::currentTimeMillis,
        sleep: suspend (Long) -> Unit = { delay(it) },
    ) {
        onStatus(PairingStatus.Requesting)
        onChallenge(null)
        precheck(api, server)?.let { return onStatus(PairingStatus.Failed(it)) }
        val started = try {
            api.authDeviceAuthorize(request)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            return onStatus(PairingStatus.Failed(authorizeFailure(e)))
        }
        onChallenge(started)
        onStatus(PairingStatus.Waiting)
        var interval = maxOf(1, started.interval)
        val deadline = now() + started.expiresIn * 1000
        while (true) {
            sleep(interval * 1000)
            if (now() > deadline) return onStatus(PairingStatus.Failed(EXPIRED))
            val result = try {
                Result.success(api.authDeviceToken(DeviceTokenRequest(started.deviceCode)))
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Result.failure(e)
            }
            when (val next = step(result, interval)) {
                is Step.Wait -> interval = next.interval
                is Step.Fail -> return onStatus(PairingStatus.Failed(next.message))
                is Step.Granted -> {
                    onStatus(PairingStatus.SigningIn)
                    try {
                        signIn(next.token)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        onStatus(PairingStatus.Failed(e.message ?: "登录失败"))
                    }
                    return
                }
            }
        }
    }
}
