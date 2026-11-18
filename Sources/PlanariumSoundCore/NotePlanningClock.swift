import Darwin
import Dispatch
import Foundation

/// Dedicated deadline source. Its bounded queue is allocated before the
/// thread starts. Only queue access takes its lock; no render code uses it.
/// Callbacks execute on Q, including synthetic clocks used by tests.
package final class NotePlanningClock: RuntimeClock, @unchecked Sendable {
    private final class Jobs: @unchecked Sendable {
        struct Job {
            let id: UInt64
            let deadline: Double
            let source: DispatchSourceUserDataAdd
            let action: @Sendable () -> Void
            var ready = false
        }
        let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        let wake = DispatchSemaphore(value: 0)
        var slots: [Job?] = Array(repeating: nil, count: 16)
        var sources: [DispatchSourceUserDataAdd?] = Array(repeating: nil, count: 16)
        var queues: [DispatchQueue?] = Array(repeating: nil, count: 16)
        var sequence: UInt64 = 0
        var stopped = false
        var started = false
        var policyResult: Int32?
        var iterations: UInt64 = 0
        var sourceCreations = 0
        init() { lock.initialize(to: os_unfair_lock()) }
        deinit { lock.deinitialize(count: 1); lock.deallocate() }
    }
    private let jobs = Jobs()
    private let thread: Thread
    package init() {
        let jobs = self.jobs
        thread = Thread {
            var base = mach_timebase_info_data_t(); mach_timebase_info(&base)
            let ticksPerSecond = 1e9 * Double(base.denom) / Double(base.numer)
            var policy = thread_time_constraint_policy_data_t(
                period: UInt32(ticksPerSecond * 0.0005), computation: UInt32(ticksPerSecond * 0.0001),
                constraint: UInt32(ticksPerSecond * 0.0005), preemptible: 1)
            let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &policy) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_policy_set(pthread_mach_thread_np(pthread_self()), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
                }
            }
            os_unfair_lock_lock(jobs.lock); jobs.policyResult = result; os_unfair_lock_unlock(jobs.lock)
            while true {
                os_unfair_lock_lock(jobs.lock)
                if jobs.stopped { os_unfair_lock_unlock(jobs.lock); return }
                let now = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
                var next: Double?
                for index in jobs.slots.indices {
                    guard let job = jobs.slots[index], !job.ready else { continue }
                    if job.deadline <= now {
                        jobs.slots[index]?.ready = true
                        job.source.add(data: 1)
                    } else { next = min(next ?? job.deadline, job.deadline) }
                }
                os_unfair_lock_unlock(jobs.lock)
                let deadline = next.map { DispatchTime(uptimeNanoseconds: UInt64(max(0, $0 * 1e9))) } ?? .distantFuture
                _ = jobs.wake.wait(timeout: deadline)
                os_unfair_lock_lock(jobs.lock); jobs.iterations &+= 1; os_unfair_lock_unlock(jobs.lock)
            }
        }
        thread.name = "Planarium note deadlines"
    }
    package var policyResult: Int32? {
        os_unfair_lock_lock(jobs.lock); defer { os_unfair_lock_unlock(jobs.lock) }; return jobs.policyResult
    }
    /// Internal diagnostic, read by tests only; counts completed waits, not polling.
    package var wakeCount: UInt64 {
        os_unfair_lock_lock(jobs.lock); defer { os_unfair_lock_unlock(jobs.lock) }; return jobs.iterations
    }
    package var sourceCreationCount: Int {
        os_unfair_lock_lock(jobs.lock); defer { os_unfair_lock_unlock(jobs.lock) }; return jobs.sourceCreations
    }
    package var now: Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
    /// Bounded admission. Runtime treats rejection as cancellation of all its
    /// planned owners; no deadline callback is silently lost.
    package func trySchedule(at deadline: Double, on queue: DispatchQueue,
                     _ action: @escaping @Sendable () -> Void) -> RuntimeCancellation? {
        os_unfair_lock_lock(jobs.lock)
        guard let index = jobs.slots.firstIndex(where: { $0 == nil }), !jobs.stopped else {
            os_unfair_lock_unlock(jobs.lock); return nil
        }
        jobs.sequence &+= 1
        let id = jobs.sequence
        let jobs = self.jobs
        // A slot keeps its source across recurring deadlines on the same Q.
        // Only initial setup (or an explicit change of Q) constructs a source.
        if jobs.queues[index] !== queue {
            jobs.sources[index]?.cancel()
            let source = DispatchSource.makeUserDataAddSource(queue: queue)
            jobs.queues[index] = queue
            jobs.sources[index] = source
            jobs.sourceCreations += 1
            source.setEventHandler { [weak jobs] in
                guard let jobs else { return }
                os_unfair_lock_lock(jobs.lock)
                let job = jobs.slots[index]
                guard jobs.queues[index] === queue, job?.ready == true else {
                    os_unfair_lock_unlock(jobs.lock); return
                }
                jobs.slots[index] = nil
                os_unfair_lock_unlock(jobs.lock)
                job?.action()
            }
            source.activate()
        }
        let source = jobs.sources[index]!
        let previous = jobs.slots.compactMap { $0 }.filter { !$0.ready }.map(\.deadline).min()
        jobs.slots[index] = .init(id: id, deadline: deadline, source: source, action: action)
        let start = !jobs.started
        jobs.started = true
        os_unfair_lock_unlock(jobs.lock)
        if start { thread.start() }
        else if previous == nil || deadline < previous! { jobs.wake.signal() }
        return .init {
            os_unfair_lock_lock(jobs.lock)
            let job = jobs.slots[index]?.id == id ? jobs.slots[index] : nil
            if job != nil { jobs.slots[index] = nil }
            os_unfair_lock_unlock(jobs.lock)
            if job != nil { jobs.wake.signal() }
        }
    }
    package func schedule(at deadline: Double, on queue: DispatchQueue,
                  _ action: @escaping @Sendable () -> Void) -> RuntimeCancellation {
        // Protocol compatibility: rejected admission is inert. Production uses
        // trySchedule and explicitly releases owners on rejection.
        trySchedule(at: deadline, on: queue, action) ?? RuntimeCancellation {}
    }
    deinit {
        os_unfair_lock_lock(jobs.lock)
        jobs.stopped = true
        for index in jobs.slots.indices {
            jobs.sources[index]?.cancel(); jobs.slots[index] = nil
        }
        os_unfair_lock_unlock(jobs.lock)
        jobs.wake.signal()
    }
}
