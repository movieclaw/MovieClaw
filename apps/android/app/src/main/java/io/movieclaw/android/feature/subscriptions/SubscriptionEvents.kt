package io.movieclaw.android.feature.subscriptions

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue

/**
 * 订阅数据的"变更信号"。
 *
 * 订阅详情页是**独立的导航目标**，在它里面取消订阅后返回列表，列表 Composable 并没有被重建
 * （单 Activity + Compose Navigation，Activity 也不走 onResume），所以列表还拿着旧数据——
 * 表现就是"取消后返回卡片还在，冷启动才消失"（用户反馈）。
 *
 * Compose 侧直接观察 [revision] 重新拉一次即可，不必引入额外的结果传递机制。
 */
object SubscriptionEvents {
    /** 每次订阅数据发生变化（取消订阅 / 新建订阅）自增 */
    var revision by mutableIntStateOf(0)
        private set

    fun notifyChanged() {
        revision++
    }
}
