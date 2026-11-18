import Foundation
import XCTest
import PlanariumRuntime
@testable import PlanariumMIDI

final class PanicFootswitchTests: XCTestCase {
    func testBackgroundPanicDoesNotNeedMainAndHandlesRunningStatusAndThresholds() {
        let pressed = DispatchSemaphore(value: 0)
        let input = PanicFootswitchInput(panic: { pressed.signal() }, changed: { _, _ in })
        input.configure(trigger: .init(status: 0x92, number: 60, value: 100), learning: false, enabled: true)
        let worker = DispatchQueue(label: "fake footswitch")
        let run = {
            worker.async { input.receive([0x92, 60, 0, 0x91, 60, 100, 0x92, 60]); input.receive([100]) }
            XCTAssertEqual(pressed.wait(timeout: .now() + 1), .success)
            XCTAssertEqual(pressed.wait(timeout: .now() + 0.02), .timedOut)
        }
        if Thread.isMainThread { run() } else { DispatchQueue.main.sync(execute: run) }
        input.configure(trigger: .init(status: 0xb0, number: 64, value: 64), learning: false, enabled: true)
        input.receive([0xb0, 64, 63, 64, 64, 64, 127])
        XCTAssertEqual(pressed.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(pressed.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(pressed.wait(timeout: .now() + 0.02), .timedOut)
    }
    func testRetiredSourceCannotTriggerAfterReconnect() {
        let pressed = DispatchSemaphore(value: 0)
        let input = PanicFootswitchInput(panic: { pressed.signal() }, changed: { _, _ in })
        let retired = input.invalidate()
        let current = input.invalidate()
        input.configure(trigger: .init(status: 0x90, number: 60, value: 100), learning: false, enabled: true)
        input.invalidate(expected: retired)
        input.receive([0x90, 60, 100], epoch: retired)
        XCTAssertEqual(pressed.wait(timeout: .now() + 0.02), .timedOut)
        input.receive([0x90, 60, 100], epoch: current)
        XCTAssertEqual(pressed.wait(timeout: .now() + 1), .success)
    }
    func testLearnAcceptsNoteAndCCButNoReleaseOrWrongChannel() {
        let learned = TriggerBox()
        let input = PanicFootswitchInput(panic: { learned.fire() }, changed: { trigger, fired in if !fired { learned.set(trigger) } })
        for (status, value): (UInt8, UInt8) in [(0x95, 1), (0xb7, 64)] {
            input.configure(trigger: nil, learning: true, enabled: true)
            input.receive([0x90, 60, 0, 0xb0, 64, 63]); XCTAssertNil(learned.take())
            input.receive([status, 65, value])
            XCTAssertEqual(learned.take(), .init(status: status, number: 65, value: value))
            input.receive([status ^ 1, 65, value]); XCTAssertEqual(learned.fired, 0)
        }
    }
}
private final class TriggerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var trigger: PanicFootswitchTrigger?
    private(set) var fired = 0
    func set(_ value: PanicFootswitchTrigger?) { lock.lock(); trigger = value; lock.unlock() }
    func take() -> PanicFootswitchTrigger? { lock.lock(); defer { lock.unlock() }; let value = trigger; trigger = nil; return value }
    func fire() { lock.lock(); fired += 1; lock.unlock() }
}

@MainActor final class PanicFootswitchSourceTests: XCTestCase {
    func testMissingSourceLearnAndReturnInBothOrdersAndPersistence() async {
        for disappearsFirst in [false, true] {
            let fake = FootswitchSourceFake()
            let defaults = UserDefaults(suiteName: "FootswitchTests-\(UUID())")!
            let model = PanicFootswitchModel(defaults: defaults, factory: { fake.open($0, $1, $2) }, sourceChanges: { fake.observe($0) }, panic: {})
            defer { model.shutdown() }
            model.selectSource(123)
            XCTAssertEqual(model.status, "not set")
            if disappearsFirst { fake.lose(); await settle(); model.learn() }
            else { model.learn(); fake.lose(); await settle() }
            XCTAssertEqual(model.status, "source missing")
            fake.restore(); await settle(); XCTAssertEqual(model.status, "waiting…")
            fake.send([0x93, 70, 80]); await settle()
            XCTAssertEqual(model.status, "ready"); XCTAssertEqual(model.trigger, .init(status: 0x93, number: 70, value: 80))
            model.shutdown(); fake.restore(); await settle(); XCTAssertFalse(model.available)
            let restored = PanicFootswitchModel(defaults: defaults, factory: { fake.open($0, $1, $2) }, panic: {})
            XCTAssertEqual(restored.sourceID, 123); XCTAssertEqual(restored.status, "ready")
            restored.clear(); XCTAssertNil(restored.trigger); XCTAssertEqual(restored.status, "not set"); restored.shutdown()
        }
    }
    private func settle() async { for _ in 0..<5 { await Task.yield() }; try? await Task.sleep(nanoseconds: 10_000_000) }
}
private final class FootswitchSourceFake: @unchecked Sendable {
    private let lock = NSLock()
    private var present = true
    private var receive: (@Sendable (MIDIClockPacket) -> Void)?
    private var lost: (@Sendable () -> Void)?
    private var changed: (@Sendable () -> Void)?
    func open(_ id: Int32, _ receive: @escaping @Sendable (MIDIClockPacket) -> Void, _ lost: @escaping @Sendable () -> Void) -> (any MIDIClockSource)? {
        lock.lock(); defer { lock.unlock() }
        guard present else { return nil }; self.receive = receive; self.lost = lost; return FootswitchHandle()
    }
    func observe(_ changed: @escaping @Sendable () -> Void) -> PlanariumRuntime.RuntimeCancellation {
        lock.lock(); self.changed = changed; lock.unlock(); return .init {}
    }
    func lose() { lock.lock(); present = false; let callback = lost; lock.unlock(); callback?() }
    func restore() { lock.lock(); present = true; let callback = changed; lock.unlock(); callback?() }
    func send(_ bytes: [UInt8]) { lock.lock(); let callback = receive; lock.unlock(); callback?(.init(bytes: bytes, timestamp: 0, arrival: 0)) }
}
private struct FootswitchHandle: MIDIClockSource { func close() {} }
