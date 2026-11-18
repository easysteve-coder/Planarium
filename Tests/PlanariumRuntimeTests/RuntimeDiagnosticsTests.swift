import XCTest
import Foundation
import Dispatch
import PlanariumDomain
import SickPLSCore
@testable import PlanariumRuntime

final class RuntimeDiagnosticsTests: RuntimeTestCase {
    func testTwoSecondBacklogAt90And361IsReportedBeforeBlockedQReturns() throws {
        for count in [90, 361] {
            let midi = FakeBoundary(), c = composition(midi: midi)
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            midi.setHook { bytes in
                if bytes[0] & 0xF0 == 0x90 { entered.signal(); _ = release.wait(timeout: .now() + 10) }
            }
            defer { release.signal() }
            c.runtime.install(try compiled()); c.runtime.sessionBegan(session); c.runtime.frame(profile())
            XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
            midi.setHook(nil)
            let geometry = ProfileGeometryIdentity(operatingMode: count == 90 ? "MMK" : "fullScan",
                pointCount: count, startAngleDegrees: -90, endAngleDegrees: 90)
            for sequence in 2...51 {
                c.runtime.frame(.init(sessionID: session, sequence: UInt64(sequence), time: 10,
                    measurements: profile().measurements, geometry: geometry))
            }
            XCTAssertEqual(c.runtime.diagnostics.overflowProfiles, 0, "Exactly 50 queued profiles remain within budget")
            c.runtime.frame(.init(sessionID: session, sequence: 52, time: 10,
                measurements: profile().measurements, geometry: geometry))
            XCTAssertEqual(c.runtime.diagnostics.overflowProfiles, 1,
                "51 queued profiles at the measured 25 Hz exceed two seconds; must be visible even while Q blocks")
            XCTAssertEqual(c.runtime.inputBacklogStatus, .overloaded)
            release.signal(); flush(c.runtime)
            XCTAssertTrue(midi.sounding.isEmpty, "Backlog must release outputs rather than keep playing")
        }
    }
    func testProfileAndPanicTimingsComeFromRuntimeForNinetyAndFullProfiles() throws {
        for count in [90, 361] {
            let clock = FakeClock(), midi = FakeBoundary(), source = FakeProfileSource()
            let c = composition(clock: clock, midi: midi, source: source)
            c.runtime.install(try compiled(fullArea: true))
            source.deliver(.began(session))
            let raw = try B0ScanProfile.build(partialScanIndex: 0, measurements: (0..<count).map { _ in try .build(value: 100, fieldFlags: 0) })
            let frame = ProfileFrame(sessionID: session, sequence: 1, time: 9.995,
                measurements: try FullScanProfileAdapter.measurements(from: raw),
                geometry: try FullScanProfileAdapter.geometry(from: raw), rawProfile: raw)
            source.deliver(.frame(frame)); flush(c.runtime)
            XCTAssertEqual(c.runtime.diagnostics.processedProfiles, 1)
            let sample = try XCTUnwrap(c.runtime.diagnostics.profileTimings.last)
            XCTAssertEqual(sample.requestedAt, frame.time)
            XCTAssertEqual(sample.queueMilliseconds, 5, accuracy: 0.001)
            XCTAssertEqual(sample.totalMilliseconds, 5, accuracy: 0.001)
            XCTAssertEqual(c.mailbox.read()?.profile?.geometry.pointCount, count)
            midi.setHook { _ in clock.advance(clock.now + 0.001) }
            c.runtime.panic(); flush(c.runtime)
            let panic = try XCTUnwrap(c.runtime.diagnostics.panicTimings.last)
            XCTAssertGreaterThan(panic.totalMilliseconds, 0)
            XCTAssertEqual(c.runtime.diagnostics.panicTimingCount, 1)
            XCTAssertEqual(midi.sounding.count, 0)
        }
    }
    func testOverflowCountIsAvailableEvenWhileOutputBlocksQ() throws {
        let midi = FakeBoundary(), clock = FakeClock()
        let runtime = PerformanceRuntime(clock: clock, mailbox: DisplayFrameMailbox(), profileCapacity: 1)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        midi.setHook { bytes in if bytes[0] & 0xF0 == 0x90 { entered.signal(); _ = release.wait(timeout: .now() + 5) } }
        defer { release.signal() }
        runtime.attach(RuntimePorts.midi(boundary: midi)); runtime.install(try compiled()); runtime.sessionBegan(session)
        runtime.frame(profile())
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        runtime.frame(profile(2)); runtime.frame(profile(3))
        XCTAssertEqual(runtime.diagnostics.overflowProfiles, 1, "A1 overflows must not wait for Q publication")
        release.signal(); flush(runtime)
    }
    func testTimingStorageIsBoundedAndTotalCountSurvivesReplacement() {
        let recorder = RuntimeTimingRecorder()
        for value in 0..<2_050 {
            recorder.record(.init(requestedAt: Double(value), completedAt: Double(value), queueMilliseconds: 0, totalMilliseconds: Double(value)))
        }
        let snapshot = recorder.snapshot(processed: 2_050, discarded: 0, overflow: 0)
        XCTAssertEqual(snapshot.profileTimings.count, 2_048)
        XCTAssertEqual(snapshot.profileTimingCount, 2_050)
        XCTAssertEqual(snapshot.profileTimings.map(\.requestedAt).min(), 2)
        XCTAssertEqual(snapshot.profileTimings.map(\.ordinal).min(), 3)
        XCTAssertEqual(snapshot.profileTimings.map(\.ordinal).max(), 2_050)
    }
}
