package io.movieclaw.android.feature.subscriptions

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * 订阅弹层的宿主。
 *
 * 它是**浮在当前页面之上**的底部抽屉，而不是一个导航目标——之前做成 `subscribe?titleRef=…`
 * 路由，导航过去之后原页面已经离开组合，抽屉的遮罩就压在一片空黑上（用户报的"点订阅后
 * 整页变黑"）。现在的行为与 HTML 原型一致：只压暗当前页，上层升起抽屉。
 *
 * 触发点全站统一走这里（发现页 hero / 卡片 / 详情页 / 媒体库条目），关闭即还原。
 */
object SubscribeSheetHost {

    /**
     * 打开抽屉时先摆出来的内容（卡片上本来就有）。有了它，抽屉**立刻**显示标题/海报，
     * 不必先转圈等 title-preview —— 剧集预检要枚举季与在库数，本来就更慢（用户反馈"点订阅有点慢"）。
     */
    data class Seed(val title: String, val posterUrl: String?, val year: Int?, val kind: String?)

    private var titleRef by mutableStateOf<String?>(null)
    private var seed by mutableStateOf<Seed?>(null)

    /** 打开某个作品的订阅抽屉（ref 为空则忽略） */
    fun open(titleRef: String, seed: Seed? = null) {
        if (titleRef.isNotBlank()) {
            this.titleRef = titleRef
            this.seed = seed
        }
    }

    fun close() {
        titleRef = null
        seed = null
    }

    /**
     * 由宿主（AppNav）注册的「把这条从订阅索引里摘掉」。
     *
     * 取消订阅的 VM 拿不到索引单例（它由 AppNav 经 EntryPoint 取出），而**已知的改动**
     * 比"重拉一次"更及时：实机日志显示 DELETE 刚成功时列表接口还返回着刚删掉的那条，
     * 光重拉会把卡片画回「已订阅」。
     */
    var removeFromIndex: (Long) -> Unit = {}

    /** 在 NavHost 之后调用一次；有目标时渲染抽屉 */
    @Composable
    fun Render(onOpenSubscription: (Long) -> Unit) {
        val ref = titleRef ?: return
        SubscribeScreen(
            titleRefOverride = ref,
            seedTitle = seed?.title,
            seedPosterUrl = seed?.posterUrl,
            seedYear = seed?.year,
            seedKind = seed?.kind,
            onBack = { close() },
            onCreated = { close() },
            onOpenSubscription = { id ->
                close()
                onOpenSubscription(id)
            },
        )
    }
}

/**
 * 从订阅索引里摘掉某条（取消订阅成功后立刻调用）。
 *
 * 顶层函数而不是 `SubscribeSheetHost.removeFromIndex`：后者在 VM 里出现了
 * 解析不到的怪现象（同包、对象却在那个文件里不可见），而这只是转发一次，不值得纠缠。
 */
fun removeSubscriptionFromIndex(subscriptionId: Long) {
    SubscribeSheetHost.removeFromIndex(subscriptionId)
}
