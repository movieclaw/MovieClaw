import Testing
import XCTest
import Observation
import Synchronization
@testable import MovieClaw

@MainActor
struct AgentTranscriptCacheTests {
    @Test func cachedReadsStillObserveMessageChanges() {
        let conversation = AgentConversation(id: "observation-test")
        _ = conversation.rows
        let changed = Mutex(false)
        withObservationTracking {
            _ = conversation.rows
        } onChange: {
            changed.withLock { $0 = true }
        }
        conversation.turns.append(AgentTurn(id: "new", input: "新问题", status: .running, startedAt: .now))
        #expect(changed.withLock { $0 })
        #expect(!conversation.rows.isEmpty)
    }

    @Test func rowsReflectStreamingRetryAndHandoffChanges() {
        let conversation = AgentConversation(id: "cache-test")
        #expect(conversation.rows.isEmpty)
        var turn = AgentTurn(id: "first", input: "问题", status: .running, startedAt: .now)
        turn.segments = [.text("第一段")]
        conversation.turns = [turn]
        let before = conversation.rows
        conversation.turns[0].segments.append(.text("第二段"))
        #expect(conversation.rows.count == before.count + 1)
        #expect(conversation.rows != before)
        conversation.handoff = (sourceId: "source", sourceTitle: "旧标题")
        #expect(conversation.rows.first?.content == .handoff(sourceId: "source", sourceTitle: "旧标题"))
        conversation.handoff?.sourceTitle = "新标题"
        #expect(conversation.rows.first?.content == .handoff(sourceId: "source", sourceTitle: "新标题"))
        conversation.handoff = nil
        conversation.turns.removeAll()
        #expect(conversation.rows.isEmpty)
        turn.segments = [.text("改写后的回答")]
        conversation.turns.append(turn)
        #expect(conversation.rows != before)
        #expect(conversation.rows.first?.spacing == 0)
    }
}

nonisolated final class AgentTranscriptCachePerformanceTests: XCTestCase {
    @MainActor func testUnchangedLongTranscriptReads() {
        let conversation = AgentConversation(id: "performance-test")
        let text = (0..<80).map { "## 推荐 \($0)\n\n" + String(repeating: "电影**剧情**与摄影。", count: 20) }.joined(separator: "\n\n")
        conversation.turns = (0..<120).map { index in
            var turn = AgentTurn(id: "\(index)", input: "推荐电影", status: .done, startedAt: .now)
            turn.segments = [.text(text)]
            return turn
        }
        let count = conversation.rows.count
        XCTAssertGreaterThan(count, 19000)
        measure {
            for _ in 0..<100 { XCTAssertEqual(conversation.rows.count, count) }
        }
    }
}
