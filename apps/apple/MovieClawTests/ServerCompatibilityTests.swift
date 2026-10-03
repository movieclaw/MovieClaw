import Foundation
import Testing
@testable import MovieClaw

/// 登录前的服务器兼容检查与连接错误文案
struct ServerCompatibilityTests {
    @Test(arguments: [
        ("0.27.0", true),
        ("0.9.0", true),
        ("0.28.0", false),
        ("0.30.1", false),
        ("1.0.0", false),
    ])
    func versionGate(version: String, tooOld: Bool) {
        #expect(AppModel.isServerTooOld(version) == tooOld)
    }

    @Test func tooOldMessageNamesBothVersions() {
        let known = AppModel.ConnectError.serverTooOld(version: "0.27.0").localizedDescription
        #expect(known.contains("v0.27.0"))
        #expect(known.contains("v\(AppModel.minimumServerVersion)"))
        // 旧服务器不报版本：不能出现空的版本号占位
        let unknown = AppModel.ConnectError.serverTooOld(version: nil).localizedDescription
        #expect(unknown.hasPrefix("服务器版本太旧"))
    }

    /// ATS 拦截（-1022）要说清原因，不能只剩一个错误码
    @Test func atsBlockIsExplained() {
        let message = APIClient.networkMessage(URLError(.appTransportSecurityRequiresSecureConnection))
        #expect(message.contains("https"))
        #expect(!message.contains("-1022"))
    }
}
