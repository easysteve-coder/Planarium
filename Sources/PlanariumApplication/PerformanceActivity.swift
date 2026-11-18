import Foundation

@MainActor public protocol PerformanceActivityBoundary {
    func begin() -> NSObjectProtocol
    func end(_ token: NSObjectProtocol)
}

@MainActor public struct SystemPerformanceActivity: PerformanceActivityBoundary {
    public init() {}
    public func begin() -> NSObjectProtocol {
        ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical, .idleDisplaySleepDisabled],
            reason: "Planarium live performance")
    }
    public func end(_ token: NSObjectProtocol) { ProcessInfo.processInfo.endActivity(token) }
}

/// Composition owns one activity, independent of the number of active inputs.
@MainActor public final class PerformanceActivity {
    private let boundary: any PerformanceActivityBoundary
    private var token: NSObjectProtocol?
    private var terminated = false
    public init(boundary: any PerformanceActivityBoundary) { self.boundary = boundary }
    public func update(audio: Bool, scanner: Bool) {
        guard !terminated else { return }
        if audio || scanner {
            if token == nil { token = boundary.begin() }
        } else { release() }
    }
    public func terminate() { terminated = true; release() }
    private func release() {
        if let token { boundary.end(token); self.token = nil }
    }
}
