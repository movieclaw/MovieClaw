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

    private func message(_ code: URLError.Code) -> String {
        let url = URL(string: "http://movie.example.com:8080/api/v1/health")!
        return APIClient.networkMessage(URLError(code, userInfo: [NSURLErrorFailingURLErrorKey: url]))
    }

    /// 每条连接错误都说清原因、点出是哪台服务器，并带错误码方便对照反馈
    @Test(arguments: [
        URLError.Code.cannotFindHost, .cannotConnectToHost, .timedOut, .networkConnectionLost,
        .appTransportSecurityRequiresSecureConnection, .secureConnectionFailed, .serverCertificateUntrusted,
        .serverCertificateHasBadDate, .httpTooManyRedirects, .badServerResponse,
    ])
    func namesServerAndCode(code: URLError.Code) {
        let text = message(code)
        #expect(text.contains("「movie.example.com:8080」"))
        #expect(text.hasSuffix("（错误码 \(code.rawValue)）"))
    }

    /// ATS 拦截（-1022）要说清原因和出路，不能只剩一个错误码
    @Test func atsBlockIsExplained() {
        let text = message(.appTransportSecurityRequiresSecureConnection)
        #expect(text.contains("更新到最新版"))
        #expect(text.contains("https"))
    }

    /// 没有出错地址时不出现空的主机名
    @Test func fallsBackWithoutURL() {
        let text = APIClient.networkMessage(URLError(.cannotConnectToHost))
        #expect(text.hasPrefix("服务器拒绝连接"))
    }
}
