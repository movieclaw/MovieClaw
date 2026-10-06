import Foundation

/// AE#447: the closed evidence a served TARGETDURATION may be sealed from. Both terms are facts the
/// source produced; neither can be manufactured by the engine waiting.
struct LiveCadenceEvidence: Sendable, Equatable {
    /// Longest inter-arrival interval that has ENDED, nil until one has.
    var closedCadenceSeconds: Double?
    /// Longest segment duration (EXTINF) the upstream has actually served, nil until the first arrival.
    var servedSegmentDurationSeconds: Double?
    /// AE#684: the media the join took, summed EXTINF, nil until it has joined.
    var joinBacklogSeconds: Double? = nil
    /// AE#684: the reader has handed over the whole join and its consumer is waiting on it for more.
    /// nil where nothing can say.
    var joinIsSpent: Bool? = nil
}

/// Turns the OBSERVED arrival cadence of a live ingest source (`LiveArrivalCadenceMeter`, surfaced by the
/// reader as `LiveIngestSourceInfo.observedLiveCadenceSeconds`) into two LL-HLS decisions, re-evaluated on
/// every manifest render. Replaces trusting the upstream's self-reported `#EXT-X-TARGETDURATION`, which a
/// bursty relay/IPTV origin under-reports, leaving blocking-reload wrongly enabled until the held
/// `?_HLS_msn=` reload trips `-15410` (AetherEngine#167).
///
/// Gate (blocking-reload eligibility): starts OFF; latches ON only after `disciplineObservationSeconds` of
/// uninterrupted disciplined cadence; latches permanently OFF (terminal `.bursty`) the moment a burst is
/// observed. The monotonic OFF -> ON -> OFF(terminal) path is deliberate: ON<->OFF flapping would itself
/// trip `-15410` as AVPlayer's in-flight blocking reload straddles the advert change, and a source that was
/// disciplined long enough to earn the ON is very unlikely to burst afterwards.
///
/// Floor (`#EXT-X-TARGETDURATION`): the monotonic max of MEASURED evidence, so AVPlayer's 1.5x-TD
/// unchanged-playlist patience always covers the real inter-batch gap (anti `-12888`). Two terms, both
/// observations and both CLOSED: the longest inter-arrival interval that has ended, and the longest
/// segment the upstream has actually served. Deliberately not the open gap the gate itself opens. The
/// upstream's self-reported `#EXT-X-TARGETDURATION` is NOT one of them (AE#447). It used to seed the
/// floor, which made a packager's habitual padding (`segment + 1`, and the RFC only requires
/// `>= ceil(max EXTINF)`) the session's served TD, and the first-serve gate then asked for `3 x` that
/// padding before serving anything: a measured 1.08 s toll per zap on a 2.000 s source advertising 3.
/// It protected nothing in exchange, because the very source shape this class exists for (#167) is the
/// relay that advertises a normal TD while delivering in batches. The advert rides along as
/// `selfReportedTargetDurationSeconds` so the seal log can report what was claimed against what was
/// measured, but nothing derives from it.
///
/// Thread-safe: read from the server's socket-handling threads on each render.
final class LiveCadencePolicy: @unchecked Sendable {
    enum GateState { case observing, disciplined, bursty }

    private let observe: @Sendable () -> Double?
    /// The closed evidence the floor is built from (AE#447).
    private let observeSealEvidence: (@Sendable () -> LiveCadenceEvidence)?
    /// The upstream's advertised TARGETDURATION. Carried for the seal log only, never derived from.
    let selfReportedTargetDurationSeconds: Double?
    private let clock: @Sendable () -> Double
    private let burstThresholdSeconds: Double
    private let disciplineObservationSeconds: Double

    private let lock = NSLock()
    private var state: GateState = .observing
    private var firstObservationTime: Double?
    /// AE#447: the running floor, the monotonic max of the CLOSED evidence. Not "the observed cadence":
    /// the open gap the gate holds open is deliberately not in here.
    private var measuredFloorSeconds: Double
    /// AE#684: the served-segment term of that floor, kept apart. Monotonic like the floor.
    private var longestUpstreamSegmentSeconds: Double = 0
    /// AE#684: what the join took. First value wins: a reopen joins again, and its seal is long taken.
    private var joinedBacklogSeconds: Double?
    /// AE#684: latched once true, so a later delivery that fills the reader again cannot unspend it.
    private var joinSpent: Bool?

    /// - Parameters:
    ///   - observe: reader's current `observedLiveCadenceSeconds`; nil until the first upstream arrival.
    ///   - cutTargetSeconds: local segment cut target; the burst threshold is 1.5x it (matching the prior
    ///     self-reported gate so disciplined sources behave identically once proven).
    ///   - disciplineObservationSeconds: sustained clean-cadence window required before enabling
    ///     blocking-reload.
    ///   - observeSealEvidence: the two closed terms the floor is built from, read per render:
    ///     the longest inter-arrival interval that has ENDED, and the longest segment duration (EXTINF)
    ///     the upstream has actually served. The second is a measured lower bound on the steady-state
    ///     cadence: an upstream cutting 4 s segments cannot sustain 0.5 s, however small the intervals
    ///     look during a join burst. Neither can be inflated by the gate's own wait (AE#447).
    ///   - selfReportedTargetDurationSeconds: the upstream's advertised `#EXT-X-TARGETDURATION`.
    ///     Reported, never obeyed; see the class note.
    ///   - clock: monotonic seconds; injectable for tests.
    init(
        observe: @escaping @Sendable () -> Double?,
        cutTargetSeconds: Double,
        disciplineObservationSeconds: Double = 12,
        observeSealEvidence: (@Sendable () -> LiveCadenceEvidence)? = nil,
        selfReportedTargetDurationSeconds: Double? = nil,
        clock: @escaping @Sendable () -> Double = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
    ) {
        self.observe = observe
        self.observeSealEvidence = observeSealEvidence
        self.selfReportedTargetDurationSeconds = selfReportedTargetDurationSeconds
        self.clock = clock
        self.burstThresholdSeconds = cutTargetSeconds * 1.5
        self.disciplineObservationSeconds = disciplineObservationSeconds
        self.measuredFloorSeconds = 0
    }

    /// Advance the latch and the running floor from a fresh observation. Idempotent for a given
    /// (cadence, now): the max only grows and the state only advances, so the two per-render reads
    /// (gate + floor) cannot disagree or double-count.
    private func advanceLocked() {
        let now = clock()
        // The floor takes only what has closed. The segment duration is evidence on its own: it bounds
        // the steady-state cadence from below even before a single interval has closed, which is exactly
        // the window in which the seal is taken.
        if let evidence = observeSealEvidence?() {
            if let served = evidence.servedSegmentDurationSeconds, served > 0 {
                measuredFloorSeconds = max(measuredFloorSeconds, served)
                longestUpstreamSegmentSeconds = max(longestUpstreamSegmentSeconds, served)
            }
            if joinedBacklogSeconds == nil, let joined = evidence.joinBacklogSeconds, joined > 0 {
                joinedBacklogSeconds = joined
            }
            if let spent = evidence.joinIsSpent, joinSpent != true {
                joinSpent = spent
            }
            if let closed = evidence.closedCadenceSeconds, closed > 0 {
                measuredFloorSeconds = max(measuredFloorSeconds, closed)
            }
        }
        // The open-gap-inclusive cadence still drives the gate: a source that has gone quiet is bursty
        // while it is quiet, and that verdict is about the source, not about a number we serve.
        guard let cadence = observe() else { return }
        if firstObservationTime == nil { firstObservationTime = now }
        switch state {
        case .bursty:
            break
        case .observing:
            if cadence > burstThresholdSeconds {
                state = .bursty
            } else if let t0 = firstObservationTime, now - t0 >= disciplineObservationSeconds {
                state = .disciplined
            }
        case .disciplined:
            if cadence > burstThresholdSeconds { state = .bursty }
        }
    }

    /// AE#684: the longest segment the upstream has served, on its own. Inside the floor above it is
    /// one more term of a max that is divided by the client's patience; a segment duration is the
    /// period the upstream delivers at, not a worst case, so the seal takes it whole
    /// (`LiveEdgePolicy.targetDurationForUpstreamSegment`). nil until the first arrival.
    var upstreamSegmentDurationSeconds: Double? {
        lock.lock(); defer { lock.unlock() }
        advanceLocked()
        return longestUpstreamSegmentSeconds > 0 ? longestUpstreamSegmentSeconds : nil
    }

    /// AE#684: whether the join has been handed over and consumed, bar the GOP the next upstream
    /// delivery will close. A fact from the reader, nil where there is none to ask.
    var joinIsSpent: Bool? {
        lock.lock(); defer { lock.unlock() }
        advanceLocked()
        return joinSpent
    }

    /// AE#684: the media the join listed (summed EXTINF), for the seal line. nil until it has joined.
    var joinBacklogSeconds: Double? {
        lock.lock(); defer { lock.unlock() }
        advanceLocked()
        return joinedBacklogSeconds
    }

    var blockingReloadEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        advanceLocked()
        return state == .disciplined
    }

    /// Running floor: the monotonic max of every MEASURED term (arrival cadence, upstream segment
    /// duration). `nil` while nothing has been measured, which leaves the served TARGETDURATION to
    /// `ceil(max EXTINF)` and the cut-target floor alone (AE#447).
    var targetDurationFloorSeconds: Double? {
        lock.lock(); defer { lock.unlock() }
        advanceLocked()
        return measuredFloorSeconds > 0 ? measuredFloorSeconds : nil
    }
}
