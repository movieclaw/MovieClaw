import Foundation
import AVFoundation
import CoreMedia

/// Audio output via AVSampleBufferAudioRenderer + AVSampleBufferRenderSynchronizer. The synchronizer is the
/// **master clock** for the whole player: video frames check synchronizer.currentTime() to decide presentation.
final class AudioOutput: @unchecked Sendable {

    let renderer: AVSampleBufferAudioRenderer
    let synchronizer: AVSampleBufferRenderSynchronizer

    private let lock = NSLock()

    /// AE#464: the host's audio presentation offset, applied to every buffer on its way into the
    /// renderer. Guarded because the host writes it from the main actor while the demux thread reads
    /// it in `enqueue`.
    private var presentationOffset: CMTime = .zero

    /// One line per offset change, not per buffer. Reset by `setPresentationOffset`.
    private var loggedOffsetInEffect = false

    /// Audit DEC-106: retired by every `flush()` and `stop()`, under `lock`. A feed loop reads it before
    /// it reads a packet and enqueues through `enqueue(sampleBuffer:ifEpoch:)`, which compares under the
    /// same lock, so a buffer decided on before a seek's flush can no longer land after it.
    private var _epoch: UInt64 = 0
    var epoch: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return _epoch
    }

    init() {
        renderer = AVSampleBufferAudioRenderer()
        synchronizer = AVSampleBufferRenderSynchronizer()
        synchronizer.addRenderer(renderer)

        // Spatial audio for AirPods Pro/Max and HomePod: renderer spatializes multichannel when system-enabled.
        renderer.allowedAudioSpatializationFormats = .multichannel

        // Rate changes ride the synchronizer timebase, and this renderer's algorithm is what decides
        // whether they keep pitch (#434). Pinned here, while the timebase is still stopped.
        AudioRatePolicy.apply(to: renderer)
        observeAutomaticFlush()
    }

    deinit {
        if let automaticFlushObserver {
            NotificationCenter.default.removeObserver(automaticFlushObserver)
        }
    }

    /// The synchronizer's rate. A stopped clock and a running clock whose timebase has stalled read
    /// differently here and nowhere else, which is the whole reason AE#549 needs it (see
    /// `RendererClockResume`).
    var rate: Float {
        synchronizer.rate
    }

    /// AE#395: the renderer's own view of its queue, for the diagnostic line: `status/sufficient/error`.
    /// A session that is silent on one route while its clock runs at 1.00 has nothing else that could
    /// say whether the renderer is playing what it was given, and the renderer error was only ever
    /// logged in DEBUG builds.
    var diagRendererState: String {
        let status: String
        switch renderer.status {
        case .rendering: status = "rendering"
        case .failed: status = "failed"
        case .unknown: status = "unknown"
        @unknown default: status = "?"
        }
        let sufficient = renderer.hasSufficientMediaDataForReliablePlaybackStart ? "y" : "n"
        let error = (renderer.error as NSError?).map { "\($0.domain)/\($0.code)" } ?? "-"
        return "\(status)/\(sufficient)/\(error)"
    }

    /// AE#549: how often this renderer has flushed itself, for the diagnostic line.
    var automaticFlushCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _automaticFlushCount
    }

    private var automaticFlushObserver: NSObjectProtocol?
    private var _automaticFlushCount = 0

    /// Where the AE#549 flush runs. The posting thread must never wait on `lock`: `enqueue` holds it
    /// across `renderer.enqueue` (DEC-106), and a renderer that posts from inside that call would make the
    /// feed thread wait on a lock it already holds, with every `flush()` / `stop()` / `seekClock()` behind it.
    private let automaticFlushQueue = DispatchQueue(label: "engine.audio.autoflush")

    /// AE#549: the renderer throws its queue away when the route changes under it, and posts the
    /// timestamp of the first sample it dropped. Nothing in the engine observed that, so the lead
    /// that was discarded was neither re-fed nor mentioned anywhere.
    ///
    /// Two things happen here, both out of the header's own guidance. The second flush is its stated
    /// best practice: the notification arrives on an arbitrary thread, so a buffer enqueued
    /// concurrently with it survives, and a survivor sits in the queue stamped far ahead of the
    /// timebase, muting the session for as long as it takes the clock to reach it. Re-feeding from
    /// the timebase is deliberately NOT attempted: the demuxer stands at the audio lead by then and
    /// the sources this happens to are exactly the ones that cannot seek backwards, so the honest
    /// outcome is a gap of up to that lead, and then sync as before.
    ///
    /// The line is also the witness the field log lacked. Across an automatic flush the timebase
    /// keeps RUNNING at its rate, so a session that froze did not freeze because of this, and only a
    /// log carrying both can tell the two apart.
    private func observeAutomaticFlush() {
        automaticFlushObserver = NotificationCenter.default.addObserver(
            forName: .AVSampleBufferAudioRendererWasFlushedAutomatically,
            object: renderer,
            queue: nil
        ) { [weak self] note in
            guard let self else { return }
            let flushedFrom = (note.userInfo?[AVSampleBufferAudioRendererFlushTimeKey] as? NSValue)?
                .timeValue.seconds
            automaticFlushQueue.async { [weak self] in
                guard let self else { return }
                lock.lock()
                _automaticFlushCount += 1
                let count = _automaticFlushCount
                renderer.flush()
                lock.unlock()
                EngineLog.emit(
                    "[AudioOutput] AE#549 renderer flushed itself (#\(count)): "
                    + "dropped from \(flushedFrom.map { String(format: "%.3f", $0) } ?? "unknown")s, "
                    + "clock at \(String(format: "%.3f", currentTimeSeconds))s rate=\(rate); "
                    + "audio returns once the feed reaches the clock",
                    category: .swPlayback
                )
            }
        }
    }

    /// Add the video renderer to the synchronizer for automatic A/V sync + frame pacing. The display layer's
    /// `sampleBufferRenderer`, never the layer: addRenderer(layer) still type-checks but on tvOS 26+ fails with
    /// FigVideoQueueRemote err=-12080 after the first enqueue. Taken as the renderer rather than read off the
    /// layer here, because the layer is main-actor isolated in the 27 SDKs and this runs off it (#351).
    func attachVideoRenderer(_ videoRenderer: AVSampleBufferVideoRenderer) {
        synchronizer.addRenderer(videoRenderer)
    }

    /// Remove the video renderer and block until removal completes. The synchronizer detaches asynchronously;
    /// if the caller immediately assigns displayLayer.controlTimebase for a new Atmos session the layer is briefly
    /// owned by both (Apple-documented UB). Symptom: first PCM->Atmos switch after launch throws FigVideoQueueRemote
    /// err=-12080 and the display layer stops rendering (audio keeps going). The semaphore wait (sub-100ms) makes
    /// the handoff deterministic.
    func detachVideoRenderer(_ videoRenderer: AVSampleBufferVideoRenderer) {
        let semaphore = DispatchSemaphore(value: 0)
        synchronizer.removeRenderer(videoRenderer, at: synchronizer.currentTime()) { _ in
            semaphore.signal()
        }
        let result = semaphore.wait(timeout: .now() + .seconds(1))
        #if DEBUG
        if result == .timedOut {
            EngineLog.emit("[AudioOutput] detachVideoRenderer: timed out waiting for synchronizer removal", category: .swPlayback)
        }
        #endif
    }

    var volume: Float {
        get { renderer.volume }
        set { renderer.volume = newValue }
    }

    /// Set playback speed (0.5-2.0). Hosts own rate state (lastRate/pausedByHost); this object is stateless about it.
    func setRate(_ rate: Float) {
        let at = synchronizer.currentTime()
        EngineLog.emit("[AudioOutput] setRate \(rate) at t=\(String(format: "%.3f", at.seconds))", category: .swPlayback)
        synchronizer.setRate(rate, time: at)
    }

    /// Pause audio (and the master clock). Hosts resume via setRate (pausedByHost pattern); deliberately no resume() here.
    func pause() {
        let at = synchronizer.currentTime()
        EngineLog.emit("[AudioOutput] pause at t=\(String(format: "%.3f", at.seconds))", category: .swPlayback)
        synchronizer.setRate(0.0, time: at)
    }

    /// Pause the master clock, at `latest` if it has already run past it. A park deferred to the last
    /// sample runs whenever its task is scheduled, and on a starved main actor that is after the clock
    /// has walked on (#694: 1.149 s on a 1.0 s source on a CI runner).
    func pause(notAfter latest: Double) {
        let now = synchronizer.currentTime()
        let seconds = SoftwareEndOfMediaClock.parkSeconds(clockSeconds: CMTimeGetSeconds(now), notAfter: latest)
        let at = seconds.map { CMTime(seconds: $0, preferredTimescale: 90000) } ?? now
        EngineLog.emit("[AudioOutput] pause at t=\(String(format: "%.3f", at.seconds))", category: .swPlayback)
        synchronizer.setRate(0.0, time: at)
    }

    /// AE#464: set the audio presentation offset. Positive presents audio later than video, which on
    /// this path means stamping its samples further ahead on the synchronizer's timeline: at clock
    /// time t the renderer then plays what was recorded at t minus the offset, while the video layer
    /// still presents t. Applied to buffers enqueued from here on; the samples already inside the
    /// renderer keep the previous offset until something flushes them.
    func setPresentationOffset(seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        presentationOffset = seconds == 0 ? .zero : CMTime(seconds: seconds, preferredTimescale: 90000)
        loggedOffsetInEffect = false
    }

    /// Enqueue a decoded audio CMSampleBuffer. Always enqueues (renderer buffers internally); gating on
    /// isReadyForMoreMediaData dropped early samples before the synchronizer started, giving silence.
    ///
    /// Audit DEC-106: with `epoch`, the buffer is enqueued only if no flush has retired that epoch, and the
    /// comparison and the enqueue happen under the lock `flush` takes. Returns false, enqueuing nothing,
    /// for a buffer that predates a flush.
    ///
    /// AE#464: this is where a lip-sync offset is applied, and the position is the point. It is past
    /// the audio tap (whose `sourceTime` is documented as the SOURCE axis and feeds transcription),
    /// past the decoder's gapless clock (which would absorb a sub-100 ms offset as rounding), and
    /// past the caller's `lastEnqueuedAudioPtsSec` bookkeeping (whose lead is measured against the
    /// synchronizer clock, i.e. against the source axis too). Only the renderer sees the shift.
    @discardableResult
    func enqueue(sampleBuffer: CMSampleBuffer, ifEpoch epoch: UInt64? = nil) -> Bool {
        lock.lock()
        if let epoch, epoch != _epoch {
            lock.unlock()
            return false
        }
        let offset = presentationOffset
        let delivered = offset == .zero ? sampleBuffer : Self.retimed(sampleBuffer, by: offset)
        var offsetLine: String?
        if offset != .zero, !loggedOffsetInEffect, delivered !== sampleBuffer {
            loggedOffsetInEffect = true
            // Release-visible, once per offset change: an offset that was set and an offset that is being
            // DELIVERED are different claims, and without this line the difference is only measurable with
            // a capture card. The two timestamps are the whole proof.
            let source = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            offsetLine = "[AudioOutput] AE#464 audio delay in effect: "
                + String(format: "%+.0f ms", offset.seconds * 1000)
                + String(format: " (sample at %.3fs delivered at %.3fs)", source, source + offset.seconds)
        }
        renderer.enqueue(delivered)
        #if DEBUG
        afterRendererEnqueueForTesting?()
        #endif
        lock.unlock()
        if let offsetLine { EngineLog.emit(offsetLine, category: .swPlayback) }

        #if DEBUG
        // Once per session: first enqueue + any renderer rejection, to distinguish "nothing enqueued" from
        // "renderer rejected our format".
        if !_loggedFirstEnqueue {
            _loggedFirstEnqueue = true
            let fmt = CMSampleBufferGetFormatDescription(sampleBuffer).flatMap {
                CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
            }
            let sr = fmt.map { "\($0.mSampleRate)Hz" } ?? "?"
            let ch = fmt.map { "\($0.mChannelsPerFrame)ch" } ?? "?"
            let count = CMSampleBufferGetNumSamples(sampleBuffer)
            EngineLog.emit("[AudioOutput] first enqueue: \(sr) \(ch), \(count) samples, renderer.error=\(String(describing: renderer.error))", category: .swPlayback)
        } else if let err = renderer.error, !_loggedRendererError {
            _loggedRendererError = true
            EngineLog.emit("[AudioOutput] renderer error: \(err)", category: .swPlayback)
        }
        #endif
        return true
    }

    #if DEBUG
    /// Test-only: runs inside `enqueue`'s locked section, right after the renderer took the buffer, which
    /// is where a renderer that posts its notifications from inside `enqueue` would post them.
    var afterRendererEnqueueForTesting: (@Sendable () -> Void)?
    private var _loggedFirstEnqueue = false
    private var _loggedRendererError = false
    #endif

    /// The shift itself, pure so it can be checked without a renderer. Every timing entry moves
    /// by `offset`, presentation and decode alike; an entry with no valid presentation stamp is left
    /// alone rather than given one. A copy that cannot be made is delivered unshifted: an audible
    /// lip-sync error is a far better outcome than a dropped buffer, which is silence.
    static func retimed(_ sampleBuffer: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer {
        guard offset != .zero else { return sampleBuffer }
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer,
                                                     entryCount: 0,
                                                     arrayToFill: nil,
                                                     entriesNeededOut: &count) == noErr,
              count > 0 else { return sampleBuffer }
        var timings = [CMSampleTimingInfo](repeating: .invalid, count: Int(count))
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer,
                                                     entryCount: count,
                                                     arrayToFill: &timings,
                                                     entriesNeededOut: nil) == noErr else {
            return sampleBuffer
        }
        for i in timings.indices where timings[i].presentationTimeStamp.isValid {
            timings[i].presentationTimeStamp = CMTimeAdd(timings[i].presentationTimeStamp, offset)
            if timings[i].decodeTimeStamp.isValid {
                timings[i].decodeTimeStamp = CMTimeAdd(timings[i].decodeTimeStamp, offset)
            }
        }
        var shifted: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                                    sampleBuffer: sampleBuffer,
                                                    sampleTimingEntryCount: count,
                                                    sampleTimingArray: &timings,
                                                    sampleBufferOut: &shifted) == noErr,
              let shifted else { return sampleBuffer }
        return shifted
    }

    var currentTime: CMTime {
        synchronizer.currentTime()
    }

    var currentTimeSeconds: Double {
        let t = CMTimeGetSeconds(currentTime)
        return t.isFinite ? t : 0
    }

    /// Whether the audio renderer can accept more samples. The combined demux loop normally paces on the
    /// video renderer; in background-audio-only mode (video dropped) it paces on this instead, so it does
    /// not buffer the rest of the file unbounded.
    var isReadyForMoreMediaData: Bool {
        renderer.isReadyForMoreMediaData
    }

    /// Flush the audio renderer (call on seek).
    func flush() {
        lock.lock()
        defer { lock.unlock() }
        _epoch &+= 1
        renderer.flush()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        _epoch &+= 1
        synchronizer.setRate(0.0, time: .zero)
        renderer.flush()
    }

    /// Atomically jump the master clock to a time and resume at a rate. The ONLY way the clock is (re)anchored:
    /// demux loops call it once on the first decoded packet, seek paths call it directly. Avoids the
    /// falling-through-time races that pause -> flush -> setRate would expose.
    func seekClock(to time: CMTime, rate: Float) {
        lock.lock()
        defer { lock.unlock() }
        EngineLog.emit("[AudioOutput] seekClock to=\(String(format: "%.3f", time.seconds)) rate=\(rate)", category: .swPlayback)
        synchronizer.setRate(rate, time: time)
    }
}
