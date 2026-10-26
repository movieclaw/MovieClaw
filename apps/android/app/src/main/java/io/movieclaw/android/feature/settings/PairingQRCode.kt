package io.movieclaw.android.feature.settings

/**
 * 设备登录二维码的解析（iOS `PairingQRCode` 的对应物）：电视、命令行等发起配对后显示的
 * 二维码，内容是服务端给的 `verification_uri_complete`——`http(s)://<服务器>/activate?code=MCLW-XXXX`
 * （旧版服务端是 `/settings/devices?code=…`）。也接受只编了配对码本身的二维码。
 *
 * 只认这几种：相机对着别的二维码（Wi-Fi、网址、付款码）时不能把人带进批准页，
 * 扫码页据此提示「这不是 MovieClaw 的登录二维码」并继续扫。
 */
internal object PairingQRCode {
    data class Scanned(
        /** 规整后的配对码（大写、带 MCLW- 前缀） */
        val code: String,
        /** 二维码里的服务器「主机:端口」，用来在查不到时提示「设备连的可能是另一台服务器」；纯配对码时为 null */
        val host: String?,
    )

    fun parse(text: String): Scanned? {
        val raw = text.trim()
        // 纯文本必须带 MCLW 前缀：手输时只打后四位也认，扫码时随便一个四个字母的二维码可不能算
        if (raw.uppercase().startsWith("MCLW")) return normalize(raw)?.let { Scanned(it, null) }
        val components = runCatching { java.net.URI(raw) }.getOrNull() ?: return null
        val scheme = components.scheme?.lowercase() ?: return null
        if (scheme != "http" && scheme != "https") return null
        val host = components.host ?: return null
        val path = components.path?.removeSuffix("/") ?: ""
        if (!path.endsWith("/activate") && !path.endsWith("/settings/devices")) return null
        val value = components.rawQuery?.split('&')
            ?.firstOrNull { it.startsWith("code=") }
            ?.substringAfter("code=")
            ?.let { java.net.URLDecoder.decode(it, "UTF-8") }
            ?: return null
        val code = normalize(value) ?: return null
        return Scanned(code, components.port.takeIf { it > 0 }?.let { "$host:$it" } ?: host)
    }

    /**
     * 配对码规整（同 Web `normalizePairingCode` / iOS `normalize`）：去掉空格与各种横线、转大写，
     * 「MCLW7F3K」「mclw-7f3k」「7F3K」都认成 MCLW-7F3K；正文必须恰好 4 位字母数字，否则返回 null
     */
    fun normalize(raw: String): String? {
        val separators = setOf(' ', '-', '_', '－', '—', '–')
        val compact = raw.uppercase().filter { it !in separators && !it.isWhitespace() }
        val body = if (compact.length == 8 && compact.startsWith("MCLW")) compact.drop(4) else compact
        if (body.length != 4) return null
        if (!body.all { it in 'A'..'Z' || it in '0'..'9' }) return null
        return "MCLW-$body"
    }
}
