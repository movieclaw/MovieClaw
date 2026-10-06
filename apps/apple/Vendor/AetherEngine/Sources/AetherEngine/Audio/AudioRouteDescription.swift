import Foundation
import AVFoundation

/// The audio route as one log fragment, shared by every host that writes a route line, so the native and
/// the software path describe the same route in the same words and a diff between their logs is a diff
/// of routes, not of formats.
enum AudioRouteDescription {

    /// `output=… preferred=… max=… ports=[name[type, ch=n], …] latency=…ms io=…ms`, or nil where there is
    /// no `AVAudioSession`. The output latency is the field AE#395 needs: a buffered AirPlay route delays
    /// sound by seconds where HDMI delays it by milliseconds, and a feed that is fine on one is late on
    /// the other.
    static func current() -> String? {
        #if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        let ports = session.currentRoute.outputs.map { port in
            "\(port.portName)[\(port.portType.rawValue), ch=\(port.channels?.count ?? -1)]"
        }.joined(separator: ", ")
        return "output=\(session.outputNumberOfChannels) preferred=\(session.preferredOutputNumberOfChannels) "
            + "max=\(session.maximumOutputNumberOfChannels) ports=[\(ports)] "
            + "latency=\(String(format: "%.0f", session.outputLatency * 1000))ms "
            + "io=\(String(format: "%.1f", session.ioBufferDuration * 1000))ms"
        #else
        return nil
        #endif
    }

    #if os(iOS) || os(tvOS)
    /// AE#395: one line per route change, for the process rather than per engine (a multiview runs several).
    /// A change mid-session leaves the session's start line describing a route that is gone, and a user
    /// switching output to test a theory is exactly that case. Installed on first touch, never removed.
    static let changeLogger: Void = {
        _ = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: nil
        ) { note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).map(String.init) ?? "?"
            guard let route = current() else { return }
            EngineLog.emit("[AetherEngine] audioRoute changed reason=\(reason) \(route)", category: .engine)
        }
    }()
    #endif
}
