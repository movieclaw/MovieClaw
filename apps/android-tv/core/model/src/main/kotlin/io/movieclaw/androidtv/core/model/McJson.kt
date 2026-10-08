package io.movieclaw.androidtv.core.model

import kotlinx.serialization.json.Json

/**
 * 全工程唯一的 JSON 配置。对新旧服务端双向宽容（docs/design/androidtv-app.md §3.2）：
 * - 未知字段忽略（新服务端多出来的字段）；
 * - 缺字段取默认值、非空字段遇到 null 也取默认值（老服务端没有的字段）；
 * - 请求里为 null 的可选字段不编码，由服务端取它自己的默认值。
 */
val McJson: Json = Json {
    ignoreUnknownKeys = true
    coerceInputValues = true
    explicitNulls = false
    encodeDefaults = true
}
