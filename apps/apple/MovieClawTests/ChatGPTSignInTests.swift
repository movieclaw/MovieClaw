import Foundation
import Testing
@testable import MovieClaw

@MainActor
struct ChatGPTSignInTests {
    private func request(_ query: String, host: String = "127.0.0.1:1455", method: String = "GET") -> String {
        "\(method) /auth/callback?\(query) HTTP/1.1\r\nHost: \(host)\r\n\r\n"
    }

    @Test func acceptsOnlyStateBoundLoopbackCallbacks() throws {
        let result = ChatGPTCallback.parse(request("state=expected&code=code&client_id=oaiapp_test"), port: 1455, state: "expected")
        let callback = try #require(result).get()
        #expect(callback.code == "code")
        #expect(callback.clientID == "oaiapp_test")
        #expect(ChatGPTCallback.parse(request("state=wrong&code=code"), port: 1455, state: "expected") == nil)
        #expect(ChatGPTCallback.parse(request("state=expected&code=code", host: "localhost:1455"), port: 1455, state: "expected") == nil)
        #expect(ChatGPTCallback.parse(request("state=expected&code=code", method: "POST"), port: 1455, state: "expected") == nil)
    }

    @Test func rejectsDuplicateFieldsAndPreservesDeniedAuthorization() throws {
        for query in ["state=expected&state=expected&code=c", "state=expected&code=c&code=d", "state=expected&code=c&client_id=a&client_id=b", "state=expected&code="] {
            #expect(ChatGPTCallback.parse(request(query), port: 1455, state: "expected") == nil)
        }
        let result = try #require(ChatGPTCallback.parse(request("state=expected&error=access_denied"), port: 1455, state: "expected"))
        if case .success = result { Issue.record("Denied authorization must not become a successful callback") }
    }

    @Test func realListenerReceivesCallbackOnlyOnceAndClosesOnCancel() async throws {
        let receiver = try ChatGPTLoopback()
        defer { receiver.stop() }
        let port = try await receiver.start()
        receiver.expect(state: "expected")
        var received = 0
        let (events, continuation) = AsyncStream<Bool>.makeStream()
        receiver.onCallback = { _ in received += 1; continuation.yield(true) }
        let session = URLSession(configuration: .ephemeral)
        let invalid = URL(string: "http://127.0.0.1:\(port)/auth/callback?state=wrong&code=c")!
        let (_, invalidResponse) = try await session.data(from: invalid)
        #expect((invalidResponse as? HTTPURLResponse)?.statusCode == 400)
        #expect(received == 0)
        let valid = URL(string: "http://127.0.0.1:\(port)/auth/callback?state=expected&code=c")!
        let (body, response) = try await session.data(from: valid)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(!String(decoding: body, as: UTF8.self).contains("code=c"))
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == true)
        #expect(received == 1)
        var replay = URLRequest(url: valid)
        replay.timeoutInterval = 2
        do {
            let (_, response) = try await session.data(for: replay)
            #expect((response as? HTTPURLResponse)?.statusCode != 200)
        } catch { }
        #expect(received == 1)
        receiver.stop()
        var request = URLRequest(url: valid)
        request.timeoutInterval = 2
        do {
            _ = try await session.data(for: request)
            Issue.record("Cancelled listener must not remain reachable")
        } catch { }
    }
}
