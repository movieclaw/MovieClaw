import Testing
import SwiftUI
import UIKit
@testable import MovieClaw

@MainActor
struct AgentCompanionTests {
    @Test func companionDoesNotReserveComposerSpace() {
        func size(companion: AgentCompanionState?) -> CGSize {
            let composer = AgentComposer(draft: .constant(AgentDraft()), onSubmit: {}).agentCompanionAnchor()
            let page = companion.map { AnyView(composer.agentCompanion($0, attentive: false)) } ?? AnyView(composer)
            let host = UIHostingController(rootView: page)
            return host.sizeThatFits(in: CGSize(width: 390, height: 1000))
        }
        let plain = size(companion: nil)
        for state in AgentCompanionState.allCases {
            let floating = size(companion: state)
            #expect(abs(floating.height - plain.height) < 0.5, "宠物不应增加输入区高度")
            #expect(abs(floating.width - plain.width) < 0.5, "宠物不应增加输入区宽度")
        }
    }

    @Test func followsRealTurnOutcomeRatherThanToolErrors() throws {
        var turn = AgentTurn(id: "pet", input: "找电影", status: .running, startedAt: .now)
        #expect(AgentCompanionState.resolve(turn: turn, busy: true) == .working)
        let decoder = JSONDecoder()
        let failedTool = try decoder.decode(AgentStreamEvent.self, from: Data(#"{"type":"tool_result","tool_result":{"tool_call_id":"search","name":"bash","output":"retry","is_error":true,"elapsed_ms":1}}"#.utf8))
        AgentTimeline.apply(failedTool, to: &turn)
        #expect(AgentCompanionState.resolve(turn: turn, busy: turn.isRunning) == .working)
        let done = try decoder.decode(AgentStreamEvent.self, from: Data(#"{"type":"agent_done","result":{"elapsed_ms":20,"steps":1,"usage":{"prompt_tokens":1,"completion_tokens":1}}}"#.utf8))
        AgentTimeline.apply(done, to: &turn)
        #expect(AgentCompanionState.resolve(turn: turn, busy: turn.isRunning) == .complete)
        turn.stopped = true
        #expect(AgentCompanionState.resolve(turn: turn, busy: false) == .idle)
        turn.stopped = false
        turn.interrupted = true
        #expect(AgentCompanionState.resolve(turn: turn, busy: false) == .failed)
        turn.interrupted = false
        turn.status = .error
        #expect(AgentCompanionState.resolve(turn: turn, busy: false) == .failed)
        #expect(AgentCompanionState.resolve(turn: turn, busy: false, unavailable: true) == .idle)
        #expect(AgentCompanionState.resolve(turn: nil, busy: false) == .idle)
    }

    @Test func bundledAtlasHasTransparentCompleteFrames() throws {
        let image = try #require(UIImage(named: "AgentMoonCompanion")?.cgImage)
        #expect(image.width * 6 == image.height * 4)
        #expect(image.width % 4 == 0 && image.height % 6 == 0)
        // 画进固定 RGBA 缓冲，逐格验证不是空白素材，也没有把概念图的深色底带进来。
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: width, height: height,
                                               bitsPerComponent: 8, bytesPerRow: width * 4,
                                               space: CGColorSpaceCreateDeviceRGB(),
                                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let cell = width / 4
        for row in 0 ..< 6 {
            for column in 0 ..< 4 {
                var visible = 0
                var edgeResidue = 0
                for y in row * cell ..< (row + 1) * cell {
                    for x in column * cell ..< (column + 1) * cell {
                        let alpha = pixels[(y * width + x) * 4 + 3]
                        if alpha > 20 { visible += 1 }
                        // 留白必须完全透明；旧图集中 alpha 1～20 的雾状背景会漏过有效像素检查。
                        if x % cell == 0 || x % cell == cell - 1 || y % cell == 0 || y % cell == cell - 1 {
                            if alpha != 0 { edgeResidue += 1 }
                        }
                    }
                }
                #expect(visible > cell * cell / 12, "第 \(row) 行第 \(column) 列缺少角色")
                #expect(visible < cell * cell * 3 / 4, "第 \(row) 行第 \(column) 列没有透明留白")
                #expect(edgeResidue == 0, "第 \(row) 行第 \(column) 列边缘残留半透明背景")
            }
        }
    }
}
