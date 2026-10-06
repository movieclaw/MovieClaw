import Foundation

/// Stateless plain-text sanitizer for subtitle cues: strips ASS/SSA markup and normalizes inline
/// escapes into plain text. Used by `WebVTTBuilder` for the native WebVTT rendition.
enum MovTextSampleBuilder {

    /// Strip ASS/SSA override blocks (`{\...}`) and normalize inline escapes to plain text.
    ///
    /// Audit SUB-1: one forward pass. Removing each block in place shifted the whole remaining cue
    /// per block, quadratic on a remote cue made of many small blocks (karaoke tracks emit one per
    /// syllable). An unclosed `{` keeps itself and everything after it, as before.
    static func sanitize(_ assText: String) -> String {
        var s = SubtitleRectText.strippingOverrideBlocks(assText)
        s = s.replacingOccurrences(of: "\\N", with: "\n")
        s = s.replacingOccurrences(of: "\\n", with: "\n")
        s = s.replacingOccurrences(of: "\\h", with: " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
