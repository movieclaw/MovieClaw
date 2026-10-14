import SwiftUI

@MainActor @Observable
final class ChatGPTSignIn {
    struct Page: Identifiable { let id = UUID(); let url: URL }
    var page: Page?
    var busy = false
    var exchanging = false
    var error: String?
    var connected: API.LlmProviderView?
    private var loopback: ChatGPTLoopback?
    private var work: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var generation = UUID()

    func begin(api: APIClient, providerID: Int?, onConnected: @escaping () -> Void) {
        cancel()
        error = nil
        connected = nil
        busy = true
        let attempt = generation
        work = Task {
            do {
                let receiver = try ChatGPTLoopback()
                loopback = receiver
                let port = try await receiver.start()
                let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "MovieClaw"
                let pending = try await api.llmChatgptAuthorize(body: .init(
                    redirectUri: "http://127.0.0.1:\(port)/auth/callback", appName: name, providerId: providerID
                ))
                try Task.checkCancellation()
                guard generation == attempt else { return }
                guard let url = URL(string: pending.authorizeUrl), url.scheme == "https",
                      url.host == "auth.openai.com", url.path == "/api/accounts/authorize" else {
                    throw APIError.network("服务器返回的 ChatGPT 登录网址无效。")
                }
                receiver.expect(state: pending.state)
                receiver.onCallback = { [weak self] result in
                    guard let self, self.generation == attempt else { return }
                    self.exchanging = true
                    self.page = nil
                    self.loopback?.stop()
                    self.loopback = nil
                    self.work = Task {
                        do {
                            let callback = try result.get()
                            let provider: API.LlmProviderView = try await api.send("POST", "/llm/chatgpt/complete", body: API.ChatGPTCompletePayload(
                                attemptId: pending.attemptId, state: callback.state, code: callback.code, clientId: callback.clientID
                            ), timeout: 120)
                            try Task.checkCancellation()
                            guard self.generation == attempt else { return }
                            self.connected = provider
                            self.finish()
                            onConnected()
                        } catch {
                            if self.generation == attempt { self.fail(error) }
                        }
                    }
                }
                page = Page(url: url)
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(600)) } catch { return }
                    guard let self, self.generation == attempt else { return }
                    self.fail(APIError.network("登录已超时，请重新打开 ChatGPT 登录页面。"))
                }
            } catch {
                if generation == attempt { fail(error) }
            }
        }
    }

    func browserDismissed() { if !exchanging { cancel() } }

    func cancel() {
        generation = UUID()
        work?.cancel()
        work = nil
        finish()
    }

    private func fail(_ cause: Error) {
        error = cause is CancellationError ? nil : cause.localizedDescription
        generation = UUID()
        work?.cancel()
        work = nil
        finish()
    }

    private func finish() {
        timeout?.cancel()
        timeout = nil
        loopback?.stop()
        loopback = nil
        page = nil
        busy = false
        exchanging = false
    }
}
