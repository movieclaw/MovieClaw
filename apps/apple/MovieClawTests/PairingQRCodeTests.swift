import Testing
@testable import MovieClaw

/// 扫码批准设备登录：二维码只认 MovieClaw 的登录链接 / 配对码，站内链接落到独立的批准页
struct PairingQRCodeTests {
    @Test func parsesServerLoginLinks() {
        #expect(PairingQRCode.parse("http://192.168.1.10:3000/activate?code=MCLW-7F3K")
            == .init(code: "MCLW-7F3K", host: "192.168.1.10:3000"))
        #expect(PairingQRCode.parse("https://movie.example.com/activate/?code=mclw-7f3k")
            == .init(code: "MCLW-7F3K", host: "movie.example.com"))
        // 旧版服务端给的批准地址
        #expect(PairingQRCode.parse("http://nas:3000/settings/devices?code=MCLW-AB12")
            == .init(code: "MCLW-AB12", host: "nas:3000"))
        // 只编了配对码本身
        #expect(PairingQRCode.parse(" MCLW-AB12 \n") == .init(code: "MCLW-AB12", host: nil))
    }

    @Test func rejectsOtherQRCodes() {
        #expect(PairingQRCode.parse("WIFI:S:home;T:WPA;P:secret;;") == nil)
        #expect(PairingQRCode.parse("https://example.com/pay?code=MCLW-7F3K") == nil)
        #expect(PairingQRCode.parse("http://nas:3000/activate") == nil)
        #expect(PairingQRCode.parse("http://nas:3000/activate?code=hello-world") == nil)
        #expect(PairingQRCode.parse("ftp://nas/activate?code=MCLW-7F3K") == nil)
        // 随便一个四个字母的二维码不能当成配对码（手输时才允许省略前缀）
        #expect(PairingQRCode.parse("ABCD") == nil)
    }

    /// 与 Web normalizePairingCode 同一口径
    @Test func normalizesTypedCodes() {
        #expect(PairingQRCode.normalize("7f3k") == "MCLW-7F3K")
        #expect(PairingQRCode.normalize("mclw 7f3k") == "MCLW-7F3K")
        #expect(PairingQRCode.normalize("MCLW—7F3K") == "MCLW-7F3K")
        #expect(PairingQRCode.normalize("MCLW-7F3") == nil)
        #expect(PairingQRCode.normalize("") == nil)
    }

    @MainActor
    @Test func activateLinksOpenTheApprovalPage() {
        #expect(AppRoute(webPath: "/activate?code=MCLW-7F3K") == .deviceApproval(code: "MCLW-7F3K"))
        #expect(AppRoute(webPath: "/activate") == .deviceApproval(code: nil))
        #expect(AppRoute(webPath: "/settings/devices?code=MCLW-7F3K") == .deviceApproval(code: "MCLW-7F3K"))
        #expect(AppRoute(webPath: "/settings/devices") == .settingsSection(.devices))
    }
}
