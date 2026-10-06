import Foundation

/// Longest program the engine parses, plans or serves (audit NET-101, HLS-102). One week: a whole-program
/// subtitle playlist puts a whole film in one EXTINF, so the per-entry ceiling has to equal the program
/// ceiling, and a 30 h marathon must parse under the same rule the subtitle proxy serves it by.
enum MediaDurationCeiling {
    static let seconds: Double = 7 * 24 * 3600
}
