import Foundation

/// AE#641: a live channel whose audio the bridge cannot decode plays video-only instead of stalling.
///
/// The load-time cascade already ends in video-only when no pipeline can be BUILT (AE#462). A bridge
/// that is built and then decodes nothing reaches no such tail: on VOD the first segment cut fails
/// and the session surfaces `audioBridgeProducedNoOutput` (AE#396), but a live FLAC bridge builds its
/// sample entry from the encoder's extradata, so segments keep being cut with an audio track that
/// never carries a sample. AVPlayer presents the first picture and waits on the audio for as long as
/// the session lasts, with nothing surfaced. The reporter's channel was DTS-HD labelled as MPEG audio.
///
/// Nothing inside the session reaches it: a producer rebuild hands the same decoder the same bytes.
/// So the session is rebuilt with that stream marked undecodable, the cascade takes its video-only
/// tail, and `audioDelivery` reads `.droppedNoPipeline`, the fact a host ladder demotes on.
extension AetherEngine {

    /// What a load keeps of the undecodable streams: the session's own rebuilds keep them, which is
    /// what keeps them video-only, and a host load is a new source and starts clean.
    nonisolated static func undecodableAudioStreamIndicesAcrossLoad(
        _ current: Set<Int32>, sessionPreservingReload: Bool
    ) -> Set<Int32> {
        sessionPreservingReload ? current : []
    }

    @MainActor
    func dropUndecodableLiveAudio(streamIndex: Int32, bridgeSummary: String) async {
        guard undecodableLiveAudioStreamIndices.insert(streamIndex).inserted else {
            EngineLog.emit(
                "[AetherEngine] AE#641 stream \(streamIndex) is already marked undecodable "
                + "(\(bridgeSummary)); the session is already video-only for it",
                category: .engine
            )
            return
        }
        EngineLog.emit(
            "[AetherEngine] AE#641 the live audio bridge decoded nothing from stream \(streamIndex) "
            + "(\(bridgeSummary)); rebuilding the session video-only instead of serving an audio "
            + "track that will never be filled",
            category: .engine
        )
        do {
            try await startTakeoverRebuild { _ in }.value
            EngineLog.emit(
                "[AetherEngine] AE#641 rebuilt video-only, audio delivery = \(audioDelivery.rawValue)",
                category: .engine)
        } catch is CancellationError {
            EngineLog.emit(
                "[AetherEngine] AE#641 video-only rebuild superseded; nothing to do", category: .engine)
        } catch {
            EngineLog.emit(
                "[AetherEngine] AE#641 video-only rebuild refused (\(error)); the session keeps its "
                + "silent audio track",
                category: .engine)
        }
    }
}
