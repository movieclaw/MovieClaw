package io.movieclaw.android.core.network

import retrofit2.HttpException
import java.io.IOException

/** 把异常翻译成面向动作的中文提示(对齐 iOS APIError 风格) */
fun friendlyMessage(e: Throwable): String = when (e) {
    is ApiException -> e.message
    is HttpException -> when (e.code()) {
        401 -> "登录状态已失效,请重新登录"
        403 -> "当前账号没有该功能的权限"
        429 -> "请求过于频繁,请稍后再试"
        else -> "请求失败(HTTP ${e.code()})"
    }
    is IOException -> "网络连接失败,请检查服务器地址与局域网"
    else -> e.message ?: "发生未知错误"
}
