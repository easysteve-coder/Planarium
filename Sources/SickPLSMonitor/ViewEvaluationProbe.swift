import Foundation

/// Installed only by the offline production-view harness; no publication.
@MainActor final class ViewEvaluationProbe {
    static var current: ViewEvaluationProbe?
    private(set) var counts: [String: Int] = [:]
    func record(_ name: String) { counts[name, default: 0] += 1 }
    private(set) var instanceCounts: [String: [UUID: Int]] = [:]
    func record(_ name: String, instance: UUID?) {
        record(name)
        if let instance { instanceCounts[name, default: [:]][instance, default: 0] += 1 }
    }
    func reset() { counts.removeAll(); instanceCounts.removeAll() }
}
