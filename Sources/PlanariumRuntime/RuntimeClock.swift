import Dispatch
import Foundation

public struct RuntimeCancellation: Sendable {
    private let cancelWork: @Sendable () -> Void
    public init(_ cancel: @escaping @Sendable () -> Void) { cancelWork = cancel }
    public func cancel() { cancelWork() }
}

/// Input timestamps and deadlines use the same monotonic seconds epoch.
/// Scheduling must enqueue the callback, never invoke it inline.
public protocol RuntimeClock: Sendable {
    func scheduleCoalescible(at deadline: Double, tolerance: Double, on queue: DispatchQueue,
                             _ action: @escaping @Sendable () -> Void) -> RuntimeCancellation
    var now: Double { get }
    func schedule(at deadline: Double, on queue: DispatchQueue,
                  _ action: @escaping @Sendable () -> Void) -> RuntimeCancellation
}

public extension RuntimeClock {
    func scheduleCoalescible(at deadline: Double, tolerance: Double, on queue: DispatchQueue,
                             _ action: @escaping @Sendable () -> Void) -> RuntimeCancellation {
        schedule(at: deadline, on: queue, action)
    }
}

public struct MonotonicRuntimeClock: RuntimeClock {
    public init() {}
    public var now: Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
    public func schedule(at deadline: Double, on queue: DispatchQueue,
                         _ action: @escaping @Sendable () -> Void) -> RuntimeCancellation {
        scheduleCoalescible(at: deadline, tolerance: 0, on: queue, action)
    }
    public func scheduleCoalescible(at deadline: Double, tolerance: Double, on queue: DispatchQueue,
                                     _ action: @escaping @Sendable () -> Void) -> RuntimeCancellation {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + max(0, deadline - now), leeway: .nanoseconds(Int(max(0, tolerance) * 1_000_000_000)))
        timer.setEventHandler(handler: action)
        timer.resume()
        return RuntimeCancellation { timer.cancel() }
    }
}
