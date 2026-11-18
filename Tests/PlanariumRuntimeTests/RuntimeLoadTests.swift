import XCTest
import Dispatch
import Foundation
import PlanariumRuntime
import PlanariumDomain
import SickPLSControlCore

final class RuntimeLoadTests: RuntimeTestCase {
    func testMailboxConcurrentReadWriteTakeAndRetireInBothOrdersUnderLoad() throws {
        let c = composition()
        let instrument = try compiled()
        c.runtime.install(instrument); c.runtime.sessionBegan(session); flush(c.runtime)
        let all = DispatchGroup()
        let queue = DispatchQueue(label: "runtime-test.producers", attributes: .concurrent)
        let id = session
        let measurements = profile().measurements
        for producer in 0..<4 {
            all.enter()
            queue.async {
                for i in 0..<1_000 {
                    c.runtime.frame(.init(sessionID: id, sequence: UInt64(producer * 1_000 + i),
                                          time: 10, measurements: measurements))
                    if i % 20 == 0 {
                        let portID = UUID(), boundary = FakeBoundary()
                        let port = RuntimePorts.audioUnit(id: portID, boundary: boundary)
                        // Both orders including independent ack callbacks.
                        if i % 40 == 0 {
                            c.runtime.retire(portID) {}
                            c.runtime.attach(port)
                            c.runtime.retire(portID) { XCTAssertTrue(boundary.sounding.isEmpty) }
                        } else {
                            c.runtime.attach(port)
                            c.runtime.retire(portID) { XCTAssertTrue(boundary.sounding.isEmpty) }
                        }
                    }
                }
                all.leave()
            }
        }
        for reader in 0..<4 {
            all.enter()
            queue.async {
                for i in 0..<8_000 {
                    let snapshot = (reader + i) % 2 == 0 ? c.mailbox.read() : c.mailbox.take()
                    if let snapshot {
                        XCTAssertEqual(snapshot.revision, instrument.revision)
                        for cell in snapshot.activeCells { XCTAssertEqual(cell.revision, snapshot.revision) }
                        XCTAssertEqual(Set(snapshot.ports.map(\.id)).count, snapshot.ports.count)
                    }
                }
                all.leave()
            }
        }
        let done = expectation(description: "concurrent producers/readers complete")
        all.notify(queue: .main) { done.fulfill() }
        wait(for: [done], timeout: 30)
        flush(c.runtime)
        XCTAssertEqual(c.mailbox.read()?.ports.count, 2)
        let stopped = expectation(description: "terminated under readers")
        c.runtime.terminate { stopped.fulfill() }
        wait(for: [stopped], timeout: 10)
        XCTAssertEqual(c.mailbox.read()?.ports.map(\.soundingNotes), [0, 0])
    }
    func testTwentyFiveHzTestReaderSeesOnlyNewestCompleteFrame() throws {
        let c = composition(), done = expectation(description: "25Hz reader")
        let samples = DisplaySampleCounter()
        let reader = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "runtime-test.25hz"))
        reader.schedule(deadline: .now(), repeating: .milliseconds(40))
        reader.setEventHandler {
            if let frame = c.mailbox.take() {
                XCTAssertEqual(frame.activeCells.count, frame.selection.activeHandles.count)
                samples.record(frame)
            }
        }
        reader.resume()
        try start(c)
        let runtime = c.runtime, id = session, measurements = profile().measurements
        DispatchQueue.global().async {
            for i in 0..<500 {
                runtime.frame(.init(sessionID: id, sequence: UInt64(i), time: 10, measurements: measurements))
                Thread.sleep(forTimeInterval: 0.001)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { done.fulfill() }
        }
        wait(for: [done], timeout: 10)
        reader.cancel()
        XCTAssertGreaterThan(samples.count, 5)
        XCTAssertLessThan(samples.count, 25)
        c.runtime.stop(); flush(c.runtime)
    }
    /// 10,000 paced profiles + 10,000 panics; no source/UI/audio/device work.
    /// Timing ends at the LAST fake port send, before mailbox/ack observation.
    func testProfileAndPanicLatencyTenThousandSamples() throws { try measureLatency(pointCount: 361) }
    func testMMK90ProfileAndPanicLatencyTenThousandSamples() throws { try measureLatency(pointCount: 90) }
    func testDetectionEnabledLatency90TenThousandSamples() throws { try measureDetectionLatency(pointCount: 90) }
    func testDetectionEnabledLatency361TenThousandSamples() throws { try measureDetectionLatency(pointCount: 361) }
    private func measureDetectionLatency(pointCount: Int) throws {
        #if DEBUG
        throw XCTSkip("Detection latency budget is measured with swift test -c release")
        #else
        guard ProcessInfo.processInfo.environment["PLANARIUM_DETECTION_LATENCY"] == "1" else {
            throw XCTSkip("Opt in: PLANARIUM_DETECTION_LATENCY=1 swift test -c release --disable-swift-testing --filter RuntimeLoadTests/testDetectionEnabledLatency")
        }
        for (name, configuration) in [("owner", DetectionConfiguration.ownerDefaults),
            ("mean4", DetectionConfiguration.ownerDefaults.replacingTemporalSmoothing(.mean(window: 4))),
            ("median4", DetectionConfiguration.ownerDefaults.replacingTemporalSmoothing(.median(window: 4))),
            ("exponential", DetectionConfiguration.ownerDefaults.replacingTemporalSmoothing(.exponential(alpha: 0.5)))] {
            try measureLatency(pointCount: pointCount, detection: configuration, label: name, preserveHistory: true)
        }
        #endif
    }
    private func measureLatency(pointCount: Int, detection: DetectionConfiguration = .allStagesOff,
                                label: String = "off", preserveHistory: Bool = false) throws {
        let clock = FakeClock(), midi = FakeBoundary(), au = FakeBoundary()
        let c = composition(clock: clock, midi: midi, au: au)
        // 16 layers, about 10,000 cells each, covering every direction at 32 rings
        // through the owner's 0...2m play area; two notes + CC per layer.
        // All 361 returns are usable: 20 hand hits plus 341 wall returns at
        // 300 cm, outside the painted 0...2m area. Runtime processes ALL of them.
        let instrument = try compiled(layerCount: 16, scalar: true, performanceArea: true, detection: detection)
        try start(c, instrument: instrument)
        var profileTimes: [Double] = [], panicTimes: [Double] = []
        var warmedFrame: ProfileFrame?
        for i in 0..<10_000 {
            let raw = UInt16(preserveHistory ? 100 : i % 2 == 0 ? 100 : 120)
            let geometry = ProfileGeometryIdentity(operatingMode: pointCount == 90 ? "segmentMinimum" : "fullScan",
                pointCount: pointCount, startAngleDegrees: -90, endAngleDegrees: 90)
            let frame = ProfileFrame(sessionID: session, sequence: UInt64(i + 2), time: 10,
                measurements: (0..<pointCount).map { index in
                    DeviceTickMeasurement(order: index, ticks: geometry.tickSpan(at: index)!,
                        rawCentimeters: (pointCount == 90 ? 42...46 : 170...189).contains(index) ? raw : 300)!
                }, geometry: geometry)
            warmedFrame = frame
            if preserveHistory && i == 0 {
                for _ in 0..<8 { c.runtime.frame(frame); flush(c.runtime) }
                XCTAssertEqual(c.mailbox.read()?.revision, instrument.revision)
                XCTAssertFalse(c.mailbox.read()?.selection.objects.isEmpty ?? true, "The latency fixture must exercise active detection")
            }
            let began = DispatchTime.now().uptimeNanoseconds
            let previousReceipts = midi.receipts.count
            c.runtime.frame(frame); flush(c.runtime)
            XCTAssertGreaterThan(midi.receipts.count, previousReceipts, "Every measured profile reaches the fake sink")
            let last = max(try XCTUnwrap(midi.receipts.last).time, try XCTUnwrap(au.receipts.last).time)
            XCTAssertGreaterThanOrEqual(last, began)
            profileTimes.append(Double(last - began) / 1e6)
            if preserveHistory { continue }
            let panicBegan = DispatchTime.now().uptimeNanoseconds
            c.runtime.panic(); flush(c.runtime)
            let lastPanic = max(midi.receipts.last!.time, au.receipts.last!.time)
            panicTimes.append(Double(lastPanic - panicBegan) / 1e6)
            XCTAssertTrue(midi.sounding.isEmpty); XCTAssertTrue(au.sounding.isEmpty)
        }
        if preserveHistory {
            for _ in 0..<10_000 {
                let warmed = try XCTUnwrap(warmedFrame)
                // Panic now requires an actual measured exit before re-entry.
                c.runtime.frame(.init(sessionID: session, sequence: warmed.sequence, time: warmed.time,
                    measurements: [], geometry: warmed.geometry)); flush(c.runtime)
                c.runtime.frame(try XCTUnwrap(warmedFrame)); flush(c.runtime)
                let began = DispatchTime.now().uptimeNanoseconds
                c.runtime.panic(); flush(c.runtime)
                let last = max(midi.receipts.last!.time, au.receipts.last!.time)
                panicTimes.append(Double(last - began) / 1e6)
                XCTAssertTrue(midi.sounding.isEmpty); XCTAssertTrue(au.sounding.isEmpty)
            }
        }
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        print("A9 build=\(build) detection=\(label) filledHistory=\(preserveHistory)")
        func stats(_ values: [Double]) -> (Double, Double, Double) {
            let sorted = values.sorted()
            return (sorted[values.count / 2], sorted[(values.count * 99) / 100], sorted.last!)
        }
        let p = stats(profileTimes), panic = stats(panicTimes)
        print(String(format: "Contract A9 latency n=10000 rays=%d layers=16 cells=%d profile p50=%.3f p99=%.3f max=%.3f ms; panic p50=%.3f p99=%.3f max=%.3f ms", pointCount, instrument.statistics.indexedAddressCount, p.0, p.1, p.2, panic.0, panic.1, panic.2))
        XCTAssertLessThanOrEqual(p.1, 20, "4x runtime p99 target")
        XCTAssertLessThanOrEqual(p.1 - p.0, 2, "Owner jitter target p99-p50")
        XCTAssertLessThan(p.2, 40, "Owner profile maximum")
        XCTAssertLessThanOrEqual(panic.1, 5, "Owner panic p99 target")
        XCTAssertLessThanOrEqual(panic.2, 10, "Owner panic maximum")
        XCTAssertEqual(c.mailbox.read()?.overflowProfiles, 0)
        XCTAssertEqual(c.mailbox.read()?.discardedProfiles, 0)
    }

}
// Test-only locked reader statistics; no shared mutable field is unguarded.
private final class DisplaySampleCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var samples = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return samples }
    func record(_ frame: DisplayFrame) { lock.lock(); samples += 1; lock.unlock() }
}
