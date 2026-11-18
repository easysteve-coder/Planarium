import Combine
import Foundation

/// Display telemetry, separate from connection state. RX supplies monotonic
/// read time; there is no timer and no additional profile/status subscription.
@MainActor public final class ProfileRateDisplayModel: ObservableObject {
    @Published public private(set) var hertz: Double?
    private var lastRefresh: TimeInterval?
    public init() {}

    func observe(_ rate: Double?, at time: TimeInterval) {
        guard time.isFinite else { return }
        if let previous = lastRefresh, time - previous < 1 { return }
        lastRefresh = time
        let next = rate.flatMap { $0.isFinite && $0 > 0 ? ($0 * 100).rounded() / 100 : nil }
        if hertz != next { hertz = next }
    }
    /// Clear stale rate immediately at a real connection boundary. A later
    /// session may start with an unrelated monotonic origin.
    func reset() {
        lastRefresh = nil
        if hertz != nil { hertz = nil }
    }
}
