package io.movieclaw.android.feature.subscriptions

import io.movieclaw.android.core.model.FollowFutureRequest
import io.movieclaw.android.core.model.TrackingStateRequest
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNamingStrategy
import org.junit.Assert.assertEquals
import org.junit.Test

/** 订阅详情两个动作的请求体，对齐服务端 schemas/subscription.py 的字段名 */
@OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)
class SubscriptionActionsContractTest {
    // 与 HttpClients 里的全局配置一致
    private val json = Json { namingStrategy = JsonNamingStrategy.SnakeCase; encodeDefaults = true }

    @Test fun followFutureSendsEnabled() {
        // SubscriptionFollowFuturePayload.enabled；以前发 follow_future → 422
        assertEquals("""{"enabled":true}""", json.encodeToString(FollowFutureRequest(true)))
    }

    @Test fun trackingStateSendsState() {
        assertEquals("""{"state":"active"}""", json.encodeToString(TrackingStateRequest("active")))
    }
}
