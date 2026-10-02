import Foundation

/// 设备登录二维码的解析：电视（Apple TV）、命令行等发起配对后显示的二维码，内容是服务端给的
/// `verification_uri_complete`——`http(s)://<服务器>/activate?code=MCLW-XXXX`
/// （旧版服务端是 `/settings/devices?code=…`）。也接受只编了配对码本身的二维码。
///
/// 只认这几种：相机对着别的二维码（Wi-Fi、网址、付款码）时不能把人带进批准页，
/// 扫码页据此提示「这不是 MovieClaw 的登录二维码」并继续扫。
enum PairingQRCode {
    struct Scanned: Equatable {
        /// 规整后的配对码（大写、带 MCLW- 前缀）
        let code: String
        /// 二维码里的服务器「主机:端口」，用来在查不到时提示「电视连的可能是另一台服务器」；纯配对码时为 nil
        let host: String?
    }

    static func parse(_ text: String) -> Scanned? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 纯文本必须带 MCLW 前缀：手输时只打后四位也认，扫码时随便一个四个字母的二维码可不能算
        if raw.uppercased().hasPrefix("MCLW"), let code = normalize(raw) { return Scanned(code: code, host: nil) }
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host
        else { return nil }
        let path = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        guard path.hasSuffix("/activate") || path.hasSuffix("/settings/devices"),
              let value = components.queryItems?.first(where: { $0.name == "code" })?.value,
              let code = normalize(value)
        else { return nil }
        return Scanned(code: code, host: components.port.map { "\(host):\($0)" } ?? host)
    }

    /// 配对码规整（同 Web `normalizePairingCode`）：去掉空格与各种横线、转大写，
    /// 「MCLW7F3K」「mclw-7f3k」「7F3K」都认成 MCLW-7F3K；正文必须恰好 4 位字母数字，否则返回 nil
    static func normalize(_ raw: String) -> String? {
        let separators: Set<Character> = [" ", "-", "_", "－", "—", "–"]
        let compact = String(raw.uppercased().filter { !separators.contains($0) && !$0.isWhitespace })
        let body = compact.count == 8 && compact.hasPrefix("MCLW") ? String(compact.dropFirst(4)) : compact
        guard body.count == 4, body.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return "MCLW-\(body)"
    }
}
