import XCTest
import PlanariumDomain
@testable import PlanariumAudio

final class AudioLifecycleContractTests: XCTestCase {
    @MainActor func testLatestStartStopWinsAcrossEveryRetireBranch() throws {
        for branch in 0..<3 {
            for startLast in [false, true] {
                let h = try Harness(); defer { h.finish() }
                h.host.apply(.init(instrument: plugin(1, state: 1)))
                h.components.succeed(0, h.unit()); try h.host.start()
                switch branch {
                case 0: h.host.apply(.init(instrument: plugin(1, state: 2)))
                case 1: h.host.apply(.init(instrument: plugin(2)))
                default: h.host.configure(.init(sampleRate: 44_100))
                }
                if startLast { h.host.stop(); try h.host.start() }
                else { try h.host.start(); h.host.stop() }
                XCTAssertEqual(h.graph.starts, 1, "No start before retire ack")
                h.runtime.ack()
                if branch == 1 { h.components.succeed(1, h.unit()) }
                XCTAssertEqual(h.host.isRunning, startLast, "branch \(branch), latest start \(startLast)")
                XCTAssertEqual(h.graph.starts, startLast ? 2 : 1)
                XCTAssertEqual(h.runtime.schedules.isEmpty, !startLast)
                XCTAssertTrue(h.trace.events.contains("graph-stop"), "Stop must reach graph after Q ack")
                if !startLast {
                    try h.host.start()
                    XCTAssertTrue(h.host.isRunning); XCTAssertFalse(h.runtime.schedules.isEmpty)
                    XCTAssertEqual(h.graph.starts, 2, "Start after ack is also retained")
                }
            }
        }
    }
    @MainActor func testInstrumentReattachFailureKeepsUnaffectedInsertAndEditor() async throws {
        let h = try Harness(); defer { h.finish() }
        let insert = InstrumentInsert(id: UUID(), plugin: plugin(3, instrument: false))
        h.host.apply(.init(instrument: plugin(), inserts: [insert]))
        h.components.succeed(0, h.unit()); h.components.succeed(1, h.unit())
        let fx = try XCTUnwrap(h.host.inserts[insert.id]); fx.openEditor(title: "FX")
        let editor = fx.editor, window = fx.window
        try h.host.start(); h.graph.failingIdentities.insert(plugin().identity)
        h.host.configure(.init(sampleRate: 44_100)); try await acknowledgeRetireAndFade(h)
        XCTAssertTrue(h.host.inserts[insert.id] === fx)
        XCTAssertTrue(fx.editor === editor); XCTAssertTrue(fx.window === window)
        XCTAssertEqual(h.host.status[.insert(insert.id)], .loaded)
        guard case .failed = h.host.status[.instrument] else { return XCTFail("Instrument-local failure") }
        XCTAssertNil(h.host.instrument); XCTAssertEqual(h.components.requests.count, 2)
    }
    @MainActor func testGraphRestartFailureKeepsAllPluginInstancesAndRecoversByStart() async throws {
        let h = try Harness(); defer { h.finish() }
        let insert = InstrumentInsert(id: UUID(), plugin: plugin(3, instrument: false), bypassed: true)
        h.host.apply(.init(instrument: plugin(), inserts: [insert]))
        h.components.succeed(0, h.unit()); h.components.succeed(1, h.unit())
        let fx = try XCTUnwrap(h.host.inserts[insert.id]), instrument = try XCTUnwrap(h.host.instrument)
        try h.host.start(); h.graph.startFails = true
        h.host.configure(.init(sampleRate: 44_100)); try await acknowledgeRetireAndFade(h)
        XCTAssertFalse(h.host.isRunning)
        XCTAssertTrue(h.host.inserts[insert.id] === fx); XCTAssertTrue(h.host.instrument === instrument)
        XCTAssertEqual(h.host.status[.insert(insert.id)], .bypass)
        XCTAssertEqual(h.components.requests.count, 2)
        h.graph.startFails = false; try h.host.start()
        XCTAssertTrue(h.host.isRunning); XCTAssertTrue(h.host.instrument === instrument)
        XCTAssertEqual(h.host.status[.instrument], .loaded)
    }
}
