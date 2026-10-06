/// Which of the process-wide outputs a load may drive (Sodalite#175). One engine is `.primary`; an
/// engine running beside it, such as a multiview tile, is `.secondary`. See `SharedOutputCoordinator`.
public enum SharedOutputRole: String, Sendable, Equatable {
    /// Drives the panel (display criteria) and may own Now Playing. The default, and the only role a
    /// host with one engine ever needs.
    case primary
    /// Never writes display criteria and never owns Now Playing, whatever the host set for either.
    case secondary
}
