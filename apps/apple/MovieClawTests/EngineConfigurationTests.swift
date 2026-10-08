import Testing
import AetherCore

/// MovieClaw 的引擎配置（`AetherPlayback.configureEngine`）：引擎 fork 的下游开关默认都是上游行为，
/// MovieClaw 用的那套由 AetherCore 逐项打开。漏开一项不会报错，只会让起播、跳转悄悄变慢或画面变样，所以逐项核对
struct EngineConfigurationTests {
    @Test func movieClawEnablesEveryDownstreamSwitch() {
        #expect(AetherPlayback.engineConfigurationSnapshot == [
            "vodSegmentTargetSeconds": "2.0",
            "vodFirstSegmentTargetSeconds": "1.0",
            "progressiveSegmentDelivery": "true",
            "declaresIndependentMediaSegments": "true",
            "seekSnapDecodeBudgetSeconds": "0.2",
            "startSnapDecodeBudgetSeconds": "0.05",
            "presentsSDRAsSRGB": "true",
            "softwareClockIgnoresEarlyFirstSample": "true",
            "parkSecondaryTrueHDDuringProbe": "true",
            "cuePrewarmTargetsStart": "true",
            "prefetchesMatroskaCues": "true",
            "prefetchesMP4TailMoov": "true",
            "usesHostMatroskaCues": "true",
            "prioritizesIndexPrefetch": "true",
            "waitsOnProgressingPrefetch": "true",
            "skipsDetourOnSlowLink": "true",
            "persistsSourceByteCache": "true",
            "sourceByteCacheKeepsSpareRuns": "true",
            "sourceByteCacheTrimKeepsMetadata": "true",
        ])
    }

    /// 窗口段数按分片时长折算（`NativeEngine.segmentWindowScale`）读的是这个值：配置没生效就会按 4 秒折算
    @Test func segmentTargetReadsTheConfiguredValue() {
        #expect(AetherPlayback.segmentTargetSeconds == 2)
    }
}
