import Foundation
import Network

nonisolated struct ChatGPTCallback: Sendable {
    let code: String
    let state: String
    let clientID: String?

    /// Only a state-bound callback from the browser may finish an attempt.
    static func parse(_ request: String, port: UInt16, state: String) -> Result<Self, CallbackError>? {
        let lines = request.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("/"),
              let url = URLComponents(string: "http://127.0.0.1:\(port)\(parts[1])"),
              url.path == "/auth/callback" else { return nil }
        let hosts = lines.dropFirst().compactMap { line -> String? in
            guard let colon = line.firstIndex(of: ":"), line[..<colon].lowercased() == "host" else { return nil }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard hosts == ["127.0.0.1:\(port)"] else { return nil }
        let query = Dictionary(grouping: url.queryItems ?? [], by: \.name)
        guard query["state"]?.count == 1, query["state"]?.first?.value == state else { return nil }
        if query["error"] != nil { return .failure(.denied) }
        guard query["code"]?.count == 1, let code = query["code"]?.first?.value,
              !code.isEmpty, code.count <= 4096, (query["client_id"]?.count ?? 0) <= 1 else { return nil }
        return .success(Self(code: code, state: state, clientID: query["client_id"]?.first?.value))
    }

    enum CallbackError: LocalizedError, Sendable {
        case denied
        var errorDescription: String? { "ChatGPT 授权未完成，请重新登录并允许使用订阅。" }
    }
}

/// The phone receives OpenAI's required loopback callback; the NAS still owns PKCE and tokens.
@MainActor
final class ChatGPTLoopback {
    private let listener: NWListener
    private var ready: CheckedContinuation<UInt16, Error>?
    private var connections: [UUID: NWConnection] = [:]
    private var expectedState: String?
    private var closed = false
    private var consumed = false
    var onCallback: (@MainActor @Sendable (Result<ChatGPTCallback, ChatGPTCallback.CallbackError>) -> Void)?

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                switch state {
                case .ready:
                    if let port = self.listener.port?.rawValue { self.finishStart(.success(port)) }
                case .failed:
                    self.finishStart(.failure(APIError.network("无法启动本机登录回调，请重试。")))
                    self.stop()
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
    }

    func start() async throws -> UInt16 {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                listener.start(queue: .main)
            }
        } onCancel: {
            Task { @MainActor in self.stop() }
        }
    }

    func expect(state: String) { expectedState = state }

    func stop() {
        closed = true
        listener.cancel()
        finishStart(.failure(CancellationError()))
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        expectedState = nil
        onCallback = nil
    }

    private func finishStart(_ result: Result<UInt16, Error>) {
        let continuation = ready
        ready = nil
        continuation?.resume(with: result)
    }

    private func accept(_ connection: NWConnection) {
        guard !closed, !consumed, connections.count < 8 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        receive(connection, id: id, buffer: Data())
    }

    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, !self.closed, self.connections[id] != nil else { connection.cancel(); return }
                var bytes = buffer
                if let data { bytes.append(data) }
                guard bytes.count <= 16_384, error == nil else { self.remove(connection, id: id); return }
                guard let text = String(data: bytes, encoding: .utf8), text.contains("\r\n\r\n") else {
                    if complete { self.remove(connection, id: id) }
                    else { self.receive(connection, id: id, buffer: bytes) }
                    return
                }
                let result = self.expectedState.flatMap { state in
                    self.listener.port.flatMap { ChatGPTCallback.parse(text, port: $0.rawValue, state: state) }
                }
                guard !self.consumed, let result else {
                    self.respond(connection, id: id, status: "400 Bad Request", message: "Invalid callback.")
                    return
                }
                self.consumed = true
                let callback = self.onCallback
                self.respond(connection, id: id, status: "200 OK", message: "Login received. Return to the app.") {
                    callback?(result)
                }
            }
        }
    }

    private func respond(_ connection: NWConnection, id: UUID, status: String, message: String, finished: (@MainActor @Sendable () -> Void)? = nil) {
        let body = Data(message.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in
                self?.remove(connection, id: id)
                finished?()
            }
        })
    }

    private func remove(_ connection: NWConnection, id: UUID) {
        connection.cancel()
        connections[id] = nil
    }
}
