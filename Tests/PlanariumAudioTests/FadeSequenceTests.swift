import XCTest
import PlanariumDomain
@testable import PlanariumAudio

@MainActor final class FadeSequenceTests: XCTestCase {
    private func loaded() throws -> Harness {
        let h = try Harness()
        h.host.apply(.init(instrument: plugin(), inserts: [.init(id: UUID(), plugin: plugin(3, instrument: false))]))
        h.components.succeed(0, h.unit()); h.components.succeed(1, h.unit())
        return h
    }
    private func toggle(_ h: Harness, bypassed: Bool) {
        var channel = h.host.channel; channel.inserts[0].bypassed = bypassed; h.host.apply(channel)
    }
    private func drain(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(0.5)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(condition())
    }
    func testBypassKeepsLoadedInsertConnectedAndDoesNotRequestFade() throws {
        let h = try loaded(); defer { h.finish() }; try h.host.start()
        let unit = try XCTUnwrap(h.host.inserts.values.first?.unit as? FakeUnit)
        let original = h.graph.ordered; h.trace.events.removeAll()
        toggle(h, bypassed: true)
        XCTAssertEqual(h.graph.ordered, original)
        XCTAssertEqual(h.graph.fadeRequests, [])
        XCTAssertEqual(unit.bypasses, [false, true])
        XCTAssertEqual(h.host.status[.insert(h.host.channel.inserts[0].id)], .bypass)
        toggle(h, bypassed: false)
        XCTAssertEqual(h.graph.ordered, original)
        XCTAssertEqual(h.graph.fadeRequests, [])
        XCTAssertEqual(unit.bypasses, [false, true, false])
    }
    func testQuickChangesCoalesceToLatestAndPreserveMutedIntent() async throws {
        let h = try loaded(); defer { h.finish() }; try h.host.start()
        let original = h.graph.ordered
        toggle(h, bypassed: true); toggle(h, bypassed: false); toggle(h, bypassed: true)
        var channel = h.host.channel; channel.muted = true; h.host.apply(channel)
        XCTAssertEqual(h.graph.fadeRequests, []); XCTAssertEqual(h.graph.ordered, original)
        XCTAssertTrue(h.graph.muted)
        channel.muted = false; h.host.apply(channel); XCTAssertFalse(h.graph.muted)
        toggle(h, bypassed: false); toggle(h, bypassed: true)
        XCTAssertEqual(h.graph.fadeRequests, [])
        XCTAssertEqual(h.graph.ordered, original)
    }
    func testReorderCoalescesAndRemovedInstanceLivesUntilSilence() async throws {
        let h = try loaded(); defer { h.finish() }
        var channel = h.host.channel
        channel.inserts.append(.init(id: UUID(), plugin: plugin(4, instrument: false)))
        h.host.apply(channel); h.components.succeed(2, h.unit()); try h.host.start()
        let removed = try XCTUnwrap(h.host.inserts[channel.inserts[0].id])
        channel.inserts.reverse(); h.host.apply(channel)
        channel.inserts.removeLast(); h.host.apply(channel)
        XCTAssertNotNil(removed.unit); XCTAssertTrue(h.graph.attached.contains(removed.id))
        h.graph.reportFadeReached(); try await drain { removed.unit == nil }
        XCTAssertEqual(h.graph.ordered, [try XCTUnwrap(h.host.inserts[channel.inserts[0].id]).id])
        XCTAssertFalse(h.graph.attached.contains(removed.id))
        XCTAssertEqual(h.graph.fadeRequests, [true, false])
    }
    func testStoppedGraphConnectsImmediatelyWithoutRenderWait() throws {
        let h = try loaded(); defer { h.finish() }
        toggle(h, bypassed: true)
        XCTAssertEqual(h.graph.ordered.count, 1); XCTAssertTrue(h.graph.fadeRequests.isEmpty)
        toggle(h, bypassed: false)
        XCTAssertEqual(h.graph.ordered.count, 1); XCTAssertTrue(h.graph.fadeRequests.isEmpty)
    }
    func testEveryAbortBoundaryInBothOrdersRestoresLatestTopologyAndPlayback() async throws {
        // stop, shutdown, rebuild, instrument replacement, state-refresh retire.
        for branch in 0..<5 {
            for fadeFirst in [false, true] {
                let h = try loaded(); defer { h.finish() }; try h.host.start()
                h.host.setMeterVisible(true)
                if fadeFirst { toggle(h, bypassed: true) }
                switch branch {
                case 0: h.host.stop()
                case 1: h.host.shutdown()
                case 2: h.host.configure(.init(sampleRate: 44_100))
                case 3:
                    var channel = h.host.channel; channel.instrument = plugin(2); h.host.apply(channel)
                default:
                    var channel = h.host.channel; channel.instrument = plugin(1, state: 7); h.host.apply(channel)
                }
                if !fadeFirst && branch != 1 { toggle(h, bypassed: true) }
                if branch <= 2 { XCTAssertNil(h.graph.meter, "Tap removed before blocked Q, branch \(branch)") }
                try await acknowledgeRetireAndFade(h)
                if branch == 3 {
                    XCTAssertEqual(h.components.requests.count, 3, "Replacement load must not remain blocked by an obsolete fade")
                    guard h.components.requests.count == 3 else { continue }
                    h.components.succeed(2, h.unit())
                }
                if branch == 0 { try h.host.start() }
                let connects = h.graph.connections
                try await Task.sleep(nanoseconds: 90_000_000)
                XCTAssertEqual(h.graph.connections, connects, "Obsolete task must never rewire after \(branch)")
                XCTAssertFalse(h.graph.transitionSilent, "No hanging fade after \(branch), first \(fadeFirst)")
                XCTAssertEqual(h.graph.ordered.count, branch == 1 ? 0 : 1)
                XCTAssertEqual(h.host.isRunning, branch != 1)
                XCTAssertEqual(h.graph.meter != nil, branch != 1)
                if branch != 1 {
                    XCTAssertEqual(Set(h.graph.ordered).count, h.graph.ordered.count)
                }
            }
        }
    }
    func testStopThenStartWhileRetirePendingCannotLeaveTargetZero() async throws {
        let h = try loaded(); defer { h.finish() }; try h.host.start()
        toggle(h, bypassed: true); h.host.stop(); try h.host.start()
        h.runtime.ack(); XCTAssertTrue(h.host.isRunning)
        XCTAssertFalse(h.graph.transitionSilent); XCTAssertEqual(h.graph.ordered.count, 1)
        try await Task.sleep(nanoseconds: 90_000_000)
        XCTAssertFalse(h.graph.transitionSilent)
    }
    func testMuteUsesFadeWithoutChangingFaderOrRetiringNotes() throws {
        let h = try loaded(); defer { h.finish() }; try h.host.start()
        var channel = h.host.channel; channel.levelDecibels = -6; h.host.apply(channel)
        channel.muted = true; h.host.apply(channel)
        XCTAssertTrue(h.graph.muted); XCTAssertEqual(h.graph.levels.last, -6)
        XCTAssertFalse(h.graph.levels.contains(-120)); XCTAssertTrue(h.runtime.retirements.isEmpty)
        h.host.stop(); h.runtime.ack(); try h.host.start(); XCTAssertTrue(h.graph.muted)
        channel.muted = false; h.host.apply(channel); XCTAssertFalse(h.graph.muted)
    }
    func testFakeStopAndConfigureMatchNativeTapAndResourceLifetime() throws {
        let h = try loaded(); defer { h.finish() }; try h.host.start(); h.host.setMeterVisible(true)
        _ = h.graph.fade(silent: true); h.graph.stop()
        XCTAssertNil(h.graph.meter); XCTAssertFalse(h.graph.running); XCTAssertFalse(h.graph.transitionSilent)
        XCTAssertFalse(h.graph.attached.isEmpty, "Native stop retains nodes")
        try h.graph.configure(.init(sampleRate: 44_100))
        XCTAssertTrue(h.graph.attached.isEmpty); XCTAssertTrue(h.graph.ordered.isEmpty)
    }
    func testRebuildFailureDuringFadeCancelsWaitAndRecoveryIsAudible() async throws {
        let h = try loaded(); defer { h.finish() }; try h.host.start()
        toggle(h, bypassed: true); h.graph.configurationFails = true
        h.host.configure(.init(sampleRate: 44_100)); try await acknowledgeRetireAndFade(h)
        XCTAssertFalse(h.host.isRunning); XCTAssertNotNil(h.host.graphFailure)
        let connects = h.graph.connections
        try await Task.sleep(nanoseconds: 90_000_000)
        XCTAssertEqual(h.graph.connections, connects); XCTAssertFalse(h.graph.transitionSilent)
        h.graph.configurationFails = false
        h.host.configure(.init(sampleRate: 44_100))
        XCTAssertEqual(h.components.requests.count, 4, "Recovery loads must not be blocked by a stale sequence")
        guard h.components.requests.count == 4 else { return }
        h.components.succeed(2, h.unit()); h.components.succeed(3, h.unit())
        try h.host.start(); XCTAssertFalse(h.graph.transitionSilent)
        toggle(h, bypassed: false); h.graph.reportFadeReached()
        try await drain { h.graph.ordered.count == 1 }
    }
    func testPendingOrFailedInsertDoesNotFadeUntilRetryActuallyLoads() async throws {
        let h = try loaded(); defer { h.finish() }; try h.host.start()
        let original = h.graph.ordered
        let insert = InstrumentInsert(id: UUID(), plugin: plugin(4, instrument: false))
        var channel = h.host.channel; channel.inserts.append(insert); h.host.apply(channel)
        XCTAssertEqual(h.components.requests.count, 3); XCTAssertTrue(h.graph.fadeRequests.isEmpty)
        h.components.fail(2); channel.pan = 0.5; h.host.apply(channel)
        XCTAssertTrue(h.graph.fadeRequests.isEmpty); XCTAssertEqual(h.graph.ordered, original)
        h.host.retry(.insert(insert.id)); XCTAssertEqual(h.components.requests.count, 4)
        h.components.succeed(3, h.unit())
        XCTAssertEqual(h.graph.fadeRequests, [true]); XCTAssertEqual(h.graph.ordered, original)
        h.graph.reportFadeReached(); try await drain { h.graph.ordered.count == 2 }
        XCTAssertEqual(h.graph.fadeRequests, [true, false])
    }
}
