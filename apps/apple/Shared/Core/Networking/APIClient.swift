import Foundation

/// 业务接口统一错误。
///
/// 后端的业务错误已经是可读中文（`message` 字段），原样透出给用户；
/// 网络层失败（断网、超时、证书）在这里换成能行动的中文，
/// 与 Web 端 `lib/http.ts` 的兜底文案保持一致，避免用户对着英文系统错误猜原因。
nonisolated enum APIError: LocalizedError, Sendable {
    /// 服务器返回了非 2xx；message 取自响应体 `message`，没有则给通用文案
    case http(status: Int, message: String, code: String?)
    /// 连不上 / 被中断
    case network(String)
    /// 超时
    case timeout
    /// 响应不是预期的 JSON 结构（多半是两端版本不一致）
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case let .http(_, message, _): message
        case let .network(message): message
        case .timeout: "服务器响应太慢，请求已取消——请稍后重试"
        case let .decoding(detail): "服务器返回的数据无法解析（App 与服务器版本可能不一致）：\(detail)"
        }
    }

    var status: Int? {
        if case let .http(status, _, _) = self { return status }
        return nil
    }

    var isUnauthorized: Bool { status == 401 }
}

/// 后端统一响应信封：`success / code / message / data`（见 CLAUDE.md「项目约定」）。
nonisolated struct APIEnvelope<T: Decodable & Sendable>: Decodable, Sendable {
    let success: Bool
    let code: String?
    let message: String?
    let data: T
}

/// 没有 data 的接口（或调用方不关心 data）用它占位解码。
nonisolated struct Empty: Codable, Sendable {}

/// 错误响应体：`success / code / message / details`
private nonisolated struct APIErrorBody: Decodable {
    let message: String?
    let code: String?
}

/// 通知：任何业务接口返回 401（令牌被注销、密码被改、账号停用）。`object` 是出事的那台服务器（`ServerAddress`），
/// `userInfo["token"]` 是被拒的那枚令牌。由 AppModel 监听后回到登录页，对应 Web 端 `redirectToLoginOn401`；
/// 只认当前令牌的 401。
nonisolated extension Notification.Name {
    static let apiUnauthorized = Notification.Name("MovieClaw.apiUnauthorized")
}

/// MovieClaw 业务接口客户端。
///
/// 认证用**设备令牌**（docs/design/login-devices.md）：`POST /auth/device/login` 用账号密码换一枚
/// 长期有效的令牌，存钥匙串（`TokenVault`），每个请求带 `Authorization: Bearer`。App 是服务端
/// 「我的设备」里的一台，注销、改密下线都按设备生效；不再借用网页的会话 Cookie——URLSession
/// 彻底不收发 Cookie，免得残留的旧 Cookie 抢在令牌前面被服务端认走。
///
/// 路径约定：调用方传 `/auth/me` 这种以 `/` 开头、相对 `/api/v1` 的路径，
/// 与 Web 端 `lib/api/*.ts` 里的写法逐字一致，方便对照移植。
nonisolated struct APIClient: Sendable {
    let server: ServerAddress
    /// 当前账号的设备令牌；为空表示未登录（只能调健康检查、初始化、登录这类公开接口）
    let token: String?
    let session: URLSession

    /// 统一的 JSON 编解码器。不设 key 策略：生成的模型都显式写了 CodingKeys
    /// （snake_case ↔ camelCase），而 convertFromSnakeCase 会连字典的键一起改写。
    static let decoder = JSONDecoder()
    static let encoder = JSONEncoder()

    /// App 全局共用的 URLSession：凭证只走 Authorization 头（设备令牌），不收发任何 Cookie。
    static let sharedSession = makeSession("api")

    /// 外壳常驻数据专用的 URLSession：活动标签的任务 SSE、下载器 / 播放活动轮询与活动总览的预取
    /// （`ShellBadges` 的两个数据仓）走这里，配置与 `sharedSession` 相同，只是连接池独立。
    /// 用它建客户端时照样要带上当前账号的令牌（`APIClient(server:token:session:)`）。
    ///
    /// URLSession 对同一台主机的并发连接有上限，HTTP/1.1 下超出的请求在本机排队：`/jobs/stream` 这条 SSE
    /// 常年占着一条连接，发现页冷启动一次并发二十来个请求又会把活动数据挤到队尾——模拟器连 NAS 实测，
    /// 活动相关请求在本机排队等连接近 1 秒，服务端处理只要 14～120ms。分开后两边互不挤占。
    static let liveSession = makeSession("live")

    /// 播放器专用的 URLSession：起播协商（决策、开会话）、心跳、进度上报走这里，连接池同样独立。
    /// 点播放时页面上可能正有一批慢请求（发现页的 TMDB 列表一次并发二十来个、每个一两秒）占满连接，
    /// 起播请求排在它们后面就要多等几秒——模拟器冷启动直达播放页实测，决策请求在本机排队 8 秒，
    /// 服务端处理只要 17 毫秒。
    static let playbackSession = makeSession("playback")

    /// 预连播放专用连接池：发一个不要鉴权的 HEAD，把 TCP / TLS 握手先做掉，之后开会话落在已连好的连接上。
    /// 真机（经反向代理的 HTTPS 域名）：冷连接开会话约 105 毫秒，热连接约 63 毫秒。见 `PlaybackPreconnect`
    static func preconnectPlayback(_ url: URL) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 5)
        request.httpMethod = "HEAD"
        playbackSession.dataTask(with: request).resume()
    }

    private static func makeSession(_ name: String) -> URLSession {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 60
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        let session = URLSession(configuration: config)
        session.sessionDescription = name
        return session
    }

    /// 所有请求带的 User-Agent：`MovieClaw-iOS/0.1.0 (iPhone18,4; iOS 26.0; build 1)`，
    /// Apple TV 上是 `MovieClaw-tvOS/0.1.0 (AppleTV14,1; tvOS 26.0; build 1)`（见 `ClientPlatform`）。
    /// App 与网页共用登录会话和播放上报接口，服务端只能靠它认出「这是原生 App」——
    /// 活动页据此显示「MovieClaw iOS · iPhone」和 App 版本，而不是「MovieClaw Web · 浏览器」
    static let userAgent: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(ClientPlatform.product)/\(version) (\(machineModel); \(ClientPlatform.osName) \(ClientPlatform.osVersion); build \(build))"
    }()

    /// 机型标识（iPhone18,4）；模拟器上取它模拟的机型
    static var machineModel: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    init(server: ServerAddress, token: String? = nil, session: URLSession = APIClient.sharedSession) {
        self.server = server
        self.token = token
        self.session = session
    }

    /// 给请求补上设备令牌（调用方已显式设了 Authorization 的不覆盖）
    func authorized(_ request: URLRequest) -> URLRequest {
        guard let token, request.value(forHTTPHeaderField: "Authorization") == nil else { return request }
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: - 地址

    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        // path 里可能自带查询串（与 Web 端写法一致），拆开后再合并 query
        let parts = trimmed.split(separator: "?", maxSplits: 1).map(String.init)
        var components = URLComponents(url: server.apiBase.appending(path: parts[0]), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = []
        if parts.count > 1 {
            items += URLComponents(string: "?\(parts[1])")?.queryItems ?? []
        }
        items += query
        if !items.isEmpty { components.queryItems = items }
        return components.url!
    }

    // MARK: - 请求
    //
    // 请求与解码一律在后台线程（`@concurrent`）：本工程开着「易上手并发」，不标的话非隔离的 async 函数
    // 跟着调用方跑——页面在主线程发请求，响应就在主线程解码。订阅清单一次 274KB，冷启动一拨十几个响应
    // 挤在首帧前后解码，模拟器实测主线程上光解码就占 30～60ms。

    /// 发请求并拆信封，返回 `data`。
    @concurrent
    func send<T: Decodable & Sendable>(
        _ method: String = "GET",
        _ path: String,
        query: [URLQueryItem] = [],
        body: (any Encodable & Sendable)? = nil,
        timeout: TimeInterval? = nil,
        as type: T.Type = T.self
    ) async throws -> T {
        let envelope: APIEnvelope<T> = try await raw(method, path, query: query, body: body, timeout: timeout)
        return envelope.data
    }

    /// 发请求并拆信封，同时带回响应头（播放记录读开会话响应的 `Server-Timing`，docs/design/playback-qoe.md §2）。
    @concurrent
    func sendReturningHeaders<T: Decodable & Sendable>(
        _ method: String,
        _ path: String,
        body: (any Encodable & Sendable)? = nil,
        as type: T.Type = T.self
    ) async throws -> (T, [String: String]) {
        var request = URLRequest(url: url(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Self.encoder.encode(body)
        }
        let (data, headers) = try await performReturningHeaders(request)
        do {
            return (try Self.decoder.decode(APIEnvelope<T>.self, from: data).data, headers)
        } catch {
            throw APIError.decoding(Self.describe(error))
        }
    }

    /// 不拆信封（少数接口如 `/health` 直接返回对象）。
    @concurrent
    func raw<T: Decodable & Sendable>(
        _ method: String = "GET",
        _ path: String,
        query: [URLQueryItem] = [],
        body: (any Encodable & Sendable)? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> T {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let timeout { request.timeoutInterval = timeout }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Self.encoder.encode(body)
        }
        let data = try await perform(request)
        if T.self == Empty.self, data.isEmpty { return Empty() as! T }
        let decodeStarted = PerfTrace.enabled ? PerfTrace.now() : 0
        defer { if PerfTrace.enabled { PerfTrace.decoded(path, bytes: data.count, started: decodeStarted) } }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(Self.describe(error))
        }
    }

    /// multipart 上传（头像、字幕、种子文件等）。
    @concurrent
    func upload<T: Decodable & Sendable>(
        _ path: String,
        fields: [String: String] = [:],
        file: (name: String, filename: String, mimeType: String, data: Data),
        as type: T.Type = T.self
    ) async throws -> T {
        let boundary = "MovieClaw-\(UUID().uuidString)"
        var body = Data()
        for (key, value) in fields {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n")
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(file.name)\"; filename=\"\(file.filename)\"\r\n")
        body.append("Content-Type: \(file.mimeType)\r\n\r\n")
        body.append(file.data)
        body.append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: url(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let data = try await perform(request)
        do {
            return try Self.decoder.decode(APIEnvelope<T>.self, from: data).data
        } catch {
            throw APIError.decoding(Self.describe(error))
        }
    }

    /// 执行请求、统一处理错误；返回响应体原始字节。
    func perform(_ request: URLRequest) async throws -> Data {
        try await performReturningHeaders(request).0
    }

    /// 同 `perform`，另外带回响应头（键为小写）
    func performReturningHeaders(_ request: URLRequest) async throws -> (Data, [String: String]) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: authorized(request), delegate: PerfTrace.enabled ? PerfTrace.NetworkMetrics.shared : nil)
        } catch let error as URLError {
            switch error.code {
            case .timedOut: throw APIError.timeout
            case .cancelled: throw CancellationError()
            default: throw APIError.network(Self.networkMessage(error))
            }
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.network("服务器响应异常")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let body = try? Self.decoder.decode(APIErrorBody.self, from: data)
            let message = body?.message ?? "请求失败（HTTP \(http.statusCode)）"
            if http.statusCode == 401, !Self.isAuthEndpoint(request.url) {
                // 带上是哪台服务器、用的哪枚令牌：切换账号时会去问别的服务器 / 别的账号，刚退出的旧令牌
                // 也可能还有请求在路上——它们的 401 不能把当前会话踢下线
                NotificationCenter.default.post(name: .apiUnauthorized, object: server, userInfo: token.map { ["token": $0] })
            }
            throw APIError.http(status: http.statusCode, message: message, code: body?.code)
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key.lowercased()] = value }
        }
        return (data, headers)
    }

    /// 这些接口的 401 不是「会话过期」，不能把用户踢回登录页：
    /// - 登录 / 初始化本身：401 = 密码错误；
    /// - 访客分享 `/share/*`（含分享播放）：401 = 需要分享密码或密码错误（同 Web `/s/` 页不跳登录）。
    private static func isAuthEndpoint(_ url: URL?) -> Bool {
        guard let path = url?.path else { return false }
        return path.hasSuffix("/auth/login") || path.hasSuffix("/auth/device/login")
            || path.hasSuffix("/auth/bootstrap") || path.contains("/api/v1/share/")
    }

    static func networkMessage(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet: "设备未联网，请检查网络后重试"
        case .cannotFindHost, .dnsLookupFailed: "找不到该服务器，请检查地址是否正确"
        case .cannotConnectToHost: "无法连接到服务器：地址或端口不对，或服务器未启动"
        case .networkConnectionLost: "网络连接中断，请重试"
        case .timedOut: "连接服务器超时：请确认地址和端口正确、服务器在运行，且手机与服务器网络互通"
        // ATS 拦截明文 http（Info.plist 已放开，正常不会出现；留着兜底，免得只剩一个错误码）
        case .appTransportSecurityRequiresSecureConnection:
            "系统拦截了不安全的 http 连接，请改用 https 地址，或使用局域网 IP 地址连接"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            "HTTPS 证书校验失败，请检查服务器证书，或改用 http 地址"
        default: "网络中断或请求失败，请检查连接后重试（\(error.code.rawValue)）"
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case let DecodingError.keyNotFound(key, ctx):
            "缺少字段 \(key.stringValue)（\(ctx.codingPath.map(\.stringValue).joined(separator: "."))）"
        case let DecodingError.typeMismatch(_, ctx), let DecodingError.valueNotFound(_, ctx):
            "字段类型不符 \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
        case let DecodingError.dataCorrupted(ctx):
            "数据损坏 \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
        default: error.localizedDescription
        }
    }
}

private nonisolated extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
