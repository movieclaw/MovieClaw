import Foundation
import Testing
@testable import AetherEngine

/// 软件通路的点播时间轴：容器起点明显不为 0 的片源，装载时就把起点定为 session zero（原引擎补丁 P35，
/// 引擎 7.48 起由上游按 `resumeSessionZero` 对每个点播冷装载预测），发布的是从 0 算的内容时间，定位时再加回源时间轴。
struct SWClockAnchorPolicyTests {
    @Test func farOriginBecomesSessionZero() {
        // 《戴珍珠耳环》VC-1 原盘：raw 从 599.996 秒起
        #expect(SWClockAnchorPolicy.resumeSessionZero(sourceOriginSeconds: 599.996) == 599.996)
    }

    @Test func smallOriginKeepsRawAxis() {
        // DVD、B 帧 MP4 这类几百毫秒的起点照旧按 raw，行为不变
        #expect(SWClockAnchorPolicy.resumeSessionZero(sourceOriginSeconds: 0.28) == 0)
        #expect(SWClockAnchorPolicy.resumeSessionZero(sourceOriginSeconds: 0) == 0)
        #expect(SWClockAnchorPolicy.resumeSessionZero(sourceOriginSeconds: .nan) == 0)
    }

    @Test func resumeOnFarOriginSourceStaysAligned() {
        // 续播到内容 600 秒：定位与锚点都在源轴 1199.996，首样本落在那里不触发重锚，发布时间 = raw − 起点
        let zero = SWClockAnchorPolicy.resumeSessionZero(sourceOriginSeconds: 599.996)
        let anchor = 600 + zero
        let resolution = SWClockAnchorPolicy.resolve(initialSeconds: anchor, firstSampleSeconds: anchor + 0.04)
        #expect(resolution == .init(anchorSeconds: anchor, sessionZeroSeconds: 0))
        #expect(SWClockAnchorPolicy.sourceSeconds(forSession: 300, sessionZeroSeconds: zero) == 899.996)
    }
}
