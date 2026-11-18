import XCTest
import PlanariumDomain
@testable import PlanariumAudio

final class AudioHostTests: XCTestCase {
    @MainActor func testUnspecifiedStateCaptureReadsOnlyEmptySlotsOncePerInstance() throws {
        let h = try Harness(); defer { h.finish() }
        h.host.apply(.init(instrument: plugin(), inserts: [.init(id: UUID(), plugin: plugin(3, instrument: false, state: 9))]))
        let effect = h.unit(), instrument = h.unit()
        instrument.state = Data([8])
        h.components.succeed(0, effect); h.components.succeed(1, instrument)
        XCTAssertEqual(try h.host.captureUnspecifiedChannelState()?.instrument?.state, Data([8]))
        XCTAssertEqual(instrument.stateReads, 1); XCTAssertEqual(effect.stateReads, 0)
        var channel = h.host.channel; channel.pan = 0.5; h.host.apply(channel)
        XCTAssertNil(try h.host.captureUnspecifiedChannelState())
        XCTAssertEqual(instrument.stateReads, 1); XCTAssertEqual(effect.stateReads, 0)
        XCTAssertEqual(try h.host.snapshotChannel().instrument?.state, Data([8]))
        XCTAssertEqual(instrument.stateReads, 2); XCTAssertEqual(effect.stateReads, 1)
    }
    @MainActor func testP8DeviceSelectionConfirmsOnlyAfterAckAndKeepsOldSelectionOnFailure() async throws {
        let h = try Harness(); defer { h.finish() }
        let catalog = FakeOutputCatalog()
        let a = AudioOutputDevice(id: 7, name: "A", isSystemOutput: false, uid: "a")
        let b = AudioOutputDevice(id: 8, name: "B", isSystemOutput: false, uid: "b")
        let system = AudioOutputDevice(id: 0, name: "System Output", isSystemOutput: true)
        catalog.devices = [system, a, b]
        let display = AudioOutputDeviceControlModel(host: h.host, catalog: catalog)
        defer { display.shutdown() }
        h.host.apply(.init(instrument: plugin(), inserts: [.init(id: UUID(), plugin: plugin(3, instrument: false))]))
        h.components.succeed(0, h.unit()); h.components.succeed(1, h.unit())
        try h.host.start(); h.host.setMeterVisible(true)
        display.selectDevice(a)
        XCTAssertTrue(display.selectedDevice.isSystemOutput, "Pending selection is not confirmed")
        XCTAssertFalse(h.host.isMeterActive)
        try await acknowledgeRetireAndFade(h); XCTAssertEqual(display.selectedDevice, a); XCTAssertTrue(h.host.isMeterActive)
        display.selectDevice(system); XCTAssertEqual(display.selectedDevice, a)
        try await acknowledgeRetireAndFade(h); XCTAssertEqual(display.selectedDevice, system); XCTAssertTrue(h.host.isMeterActive)
        display.selectDevice(a); try await acknowledgeRetireAndFade(h)
        display.selectDevice(b); try await acknowledgeRetireAndFade(h)
        XCTAssertEqual(display.selectedDevice, b); XCTAssertTrue(h.host.isMeterActive)
        XCTAssertEqual(h.host.inserts.count, 1); XCTAssertNotNil(h.host.instrument)
        h.graph.configurationFails = true
        display.selectDevice(system); XCTAssertEqual(display.selectedDevice, b)
        try await acknowledgeRetireAndFade(h); XCTAssertEqual(display.selectedDevice, b)
        XCTAssertFalse(h.host.isMeterActive); XCTAssertNotNil(display.notice)
    }
    @MainActor func testSameInstrumentPresetKeepsInstanceEditorAndPort() throws {
        let h = try Harness(); defer { h.finish() }
        h.host.apply(.init(instrument: plugin(1, state: 1)))
        let unit = h.unit(); h.components.succeed(0, unit)
        let original = try XCTUnwrap(h.host.instrument)
        original.openEditor(title: "A")
        let editor = original.editor; let window = original.window
        h.host.apply(.init(instrument: plugin(1, state: 2), levelDecibels: -6))
        XCTAssertTrue(h.host.instrument === original)
        XCTAssertTrue(original.editor === editor); XCTAssertTrue(original.window === window)
        XCTAssertEqual(h.components.requests.count, 1); XCTAssertEqual(h.runtime.retirements, [original.id])
        XCTAssertEqual(unit.states, [Data([1])], "state cannot touch parameter objects before Q retires")
        h.runtime.ack()
        XCTAssertEqual(unit.states, [Data([1]), Data([2])])
        XCTAssertEqual(h.runtime.attachments, [original.id, original.id]); XCTAssertEqual(h.graph.configurations.count, 1)
        XCTAssertEqual(h.graph.levels, [0, -6])
        h.host.apply(h.host.channel)
        XCTAssertEqual(unit.states.count, 2); XCTAssertEqual(unit.editorRequests, 1)
        XCTAssertEqual(h.host.lastSteps, [])
    }
    @MainActor func testInsertsPreserveBypassAndInstancesAcrossStateOrderAndRemoval() throws {
        let h = try Harness(); defer { h.finish() }
        var x = InstrumentInsert(id: UUID(), plugin: plugin(3, instrument: false), bypassed: true)
        let y = InstrumentInsert(id: UUID(), plugin: plugin(4, instrument: false))
        h.host.apply(.init(instrument: plugin(), inserts: [x, y]))
        let ux = h.unit(), uy = h.unit(), ui = h.unit()
        h.components.succeed(0, ux); h.components.succeed(1, uy); h.components.succeed(2, ui)
        let ix = try XCTUnwrap(h.host.inserts[x.id]), iy = try XCTUnwrap(h.host.inserts[y.id])
        h.host.apply(.init(instrument: plugin(1, state: 7), inserts: [y, x], levelDecibels: -3))
        XCTAssertEqual(h.graph.ordered, [iy.id, ix.id]); XCTAssertTrue(h.host.inserts[x.id] === ix)
        XCTAssertEqual(ux.bypasses, [true]); XCTAssertEqual(h.host.status[.insert(x.id)], .bypass)
        XCTAssertEqual(h.host.status[.insert(y.id)], .loaded); XCTAssertEqual(h.components.requests.count, 3)
        h.runtime.ack() // the instrument state refresh is separate from insert lifetime
        x.bypassed = false
        h.host.apply(.init(instrument: plugin(1, state: 7), inserts: [y, x]))
        XCTAssertEqual(h.graph.ordered, [iy.id, ix.id])
        XCTAssertEqual(ux.bypasses, [true, false]); XCTAssertEqual(h.host.status[.insert(x.id)], .loaded)
        ix.openEditor(title: "insert")
        h.trace.events.removeAll()
        h.host.apply(.init(instrument: plugin(1, state: 7), inserts: [y]))
        XCTAssertNil(ix.unit); XCTAssertEqual(h.graph.ordered, [iy.id]); XCTAssertEqual(h.runtime.retirements.count, 1)
        XCTAssertEqual(h.trace.events.prefix(4), ["editor-release", "window-clear", "window-close", "graph-remove"])
    }
    @MainActor func testInsertLoadAndFormatFailuresAreLocalAndRetryIsExplicit() throws {
        let h = try Harness(); defer { h.finish() }
        let x = InstrumentInsert(id: UUID(), plugin: plugin(3, instrument: false), bypassed: true)
        let y = InstrumentInsert(id: UUID(), plugin: plugin(4, instrument: false))
        h.host.apply(.init(instrument: plugin(), inserts: [x, y]))
        h.components.fail(0); h.components.succeed(1, h.unit()); h.components.succeed(2, h.unit())
        XCTAssertEqual(h.host.status[.insert(x.id)], .failed("unavailable"))
        XCTAssertEqual(h.host.status[.insert(y.id)], .loaded); XCTAssertEqual(h.host.status[.instrument], .loaded)
        XCTAssertEqual(h.graph.ordered.count, 1); XCTAssertNotNil(h.graph.source)
        h.host.apply(h.host.channel); XCTAssertEqual(h.components.requests.count, 3)
        h.host.retry(.insert(x.id)); XCTAssertEqual(h.host.status[.insert(x.id)], .loading)
        h.components.succeed(3, h.unit()); XCTAssertEqual(h.host.status[.insert(x.id)], .bypass)
        XCTAssertEqual(h.graph.ordered.count, 2)
        let z = InstrumentInsert(id: UUID(), plugin: plugin(5, instrument: false))
        h.graph.failingIdentities.insert(z.plugin.identity)
        h.host.apply(.init(instrument: plugin(), inserts: [x, y, z]))
        h.components.succeed(4, h.unit())
        guard case .failed = h.host.status[.insert(z.id)] else { return XCTFail("Format error must be local") }
        XCTAssertEqual(h.graph.ordered.count, 2); XCTAssertEqual(h.runtime.retirements.count, 0)
    }
    @MainActor func testRetireAckBeforeNextChannelChange() throws {
        let h = try Harness(); defer { h.finish() }
        h.host.apply(.init(instrument: plugin(1))); h.components.succeed(0, h.unit())
        let old = try XCTUnwrap(h.host.instrument); old.openEditor(title: "old")
        h.trace.events.removeAll()
        h.host.apply(.init(instrument: plugin(2)))
        XCTAssertEqual(h.runtime.retirements, [old.id]); XCTAssertNotNil(old.unit)
        XCTAssertTrue(h.graph.attached.contains(old.id)); XCTAssertNotNil(old.editor)
        XCTAssertEqual(h.components.requests.count, 1)
        h.runtime.ack()
        XCTAssertNil(old.unit); XCTAssertNil(old.editor); XCTAssertFalse(h.graph.attached.contains(old.id))
        XCTAssertEqual(h.trace.events.prefix(6), ["retire", "ack", "editor-release", "window-clear", "window-close", "graph-remove"])
        h.host.apply(.init(instrument: plugin(3)))
        let obsolete = h.unit(); h.components.succeed(1, obsolete)
        XCTAssertNil(h.host.instrument); XCTAssertEqual(h.components.requests.count, 3)
        h.components.succeed(2, h.unit()); XCTAssertEqual(h.host.instrument?.identity, plugin(3).identity)
        XCTAssertEqual(h.runtime.attachments.count, 2)
    }
    @MainActor func testNextChannelChangesBeforeAckUseLatestValueEvenReturningToOldIdentity() throws {
        let h = try Harness(); defer { h.finish() }
        h.host.apply(.init(instrument: plugin(1))); h.components.succeed(0, h.unit())
        let old = try XCTUnwrap(h.host.instrument)
        h.host.apply(.init(instrument: plugin(2)))
        h.host.apply(.init(instrument: plugin(3)))
        h.host.apply(.init(instrument: plugin(1, state: 9)))
        XCTAssertEqual(h.runtime.retirements, [old.id]); XCTAssertNotNil(old.unit)
        XCTAssertEqual(h.components.requests.count, 1)
        h.runtime.ack()
        XCTAssertNil(old.unit); XCTAssertEqual(h.components.requests[1].identity, plugin(1).identity)
        let next = h.unit(); h.components.succeed(1, next)
        XCTAssertFalse(h.host.instrument === old); XCTAssertEqual(next.states, [Data([9])])
    }
    @MainActor func testShutdownWhileRetiringAndWhileLoading() throws {
        let h = try Harness()
        h.host.apply(.init(instrument: plugin())); h.components.succeed(0, h.unit())
        let old = try XCTUnwrap(h.host.instrument)
        h.host.apply(.init(instrument: plugin(2)))
        var done = false
        h.host.shutdown { done = true }
        XCTAssertFalse(done); XCTAssertNotNil(old.unit)
        h.runtime.ack(); XCTAssertTrue(done); XCTAssertNil(old.unit)
        XCTAssertEqual(h.components.requests.count, 1)
        h.host.apply(.init(instrument: plugin(3))); XCTAssertEqual(h.components.requests.count, 1)
        let loading = try Harness()
        loading.host.apply(.init(instrument: plugin()))
        loading.host.shutdown(); loading.components.succeed(0, loading.unit())
        XCTAssertNil(loading.host.instrument); XCTAssertEqual(loading.runtime.attachments.count, 0)
    }
    @MainActor func testPendingLoadUsesNewestStateAndIgnoresRemovedInsertCompletion() throws {
        let h = try Harness(); defer { h.finish() }
        let x = InstrumentInsert(id: UUID(), plugin: plugin(3, instrument: false))
        h.host.apply(.init(instrument: plugin(), inserts: [x]))
        h.host.apply(.init(instrument: plugin(1, state: 6)))
        h.components.succeed(0, h.unit())
        let unit = h.unit(); h.components.succeed(1, unit)
        XCTAssertEqual(unit.states, [Data([6])]); XCTAssertTrue(h.host.inserts.isEmpty)
        XCTAssertEqual(h.graph.attached.count, 1)
    }
    @MainActor func testSnapshotAndLocalStateFailure() throws {
        let h = try Harness(); defer { h.finish() }
        let x = InstrumentInsert(id: UUID(), plugin: plugin(3, instrument: false, state: 1))
        h.host.apply(.init(instrument: plugin(1, state: 2), inserts: [x]))
        let ux = h.unit(), ui = h.unit()
        h.components.succeed(0, ux); h.components.succeed(1, ui)
        ux.state = Data([9]); ui.state = Data([8])
        let snapshot = try h.host.snapshotChannel()
        XCTAssertEqual(snapshot.instrument?.state, Data([8])); XCTAssertEqual(snapshot.inserts[0].plugin.state, Data([9]))
        ux.stateFails = true
        var next = h.host.channel; next.inserts[0].plugin.state = Data([7]); h.host.apply(next)
        guard case .failed = h.host.status[.insert(x.id)] else { return XCTFail("state error") }
        XCTAssertEqual(h.host.status[.instrument], .loaded); XCTAssertEqual(h.runtime.retirements.count, 0)
        ux.stateFails = false; h.host.retry(.insert(x.id)); XCTAssertEqual(h.host.status[.insert(x.id)], .loaded)
    }
    @MainActor func testDeviceRateRebuildRetiresAndKeepsInstancesEditorsAndState() async throws {
        let h = try Harness(); defer { h.finish() }
        let x = InstrumentInsert(id: UUID(), plugin: plugin(3, instrument: false), bypassed: true)
        h.host.apply(.init(instrument: plugin(), inserts: [x], levelDecibels: -6))
        h.components.succeed(0, h.unit()); h.components.succeed(1, h.unit())
        let old = try XCTUnwrap(h.host.instrument); old.openEditor(title: "I")
        let editor = old.editor
        try h.host.start()
        h.host.configure(.init(sampleRate: 44_100)); h.host.configure(.init(deviceID: 7, sampleRate: 48_000))
        XCTAssertEqual(h.graph.configurations.count, 1); XCTAssertNotNil(old.unit)
        try await acknowledgeRetireAndFade(h)
        XCTAssertEqual(h.graph.configurations.last, .init(deviceID: 7, sampleRate: 48_000))
        XCTAssertTrue(h.host.instrument === old); XCTAssertTrue(old.editor === editor)
        XCTAssertEqual(h.components.requests.count, 2); XCTAssertEqual(h.graph.starts, 2)
        XCTAssertEqual(h.runtime.attachments, [old.id, old.id]); XCTAssertEqual(h.host.status[.insert(x.id)], .bypass)
    }
    @MainActor func testInvalidComponentAndDuplicateInsertIDsAreLocal() throws {
        let h = try Harness(); defer { h.finish() }
        let x = InstrumentInsert(id: UUID(), plugin: plugin(3, instrument: false))
        h.host.apply(.init(instrument: plugin(4, instrument: false), inserts: [x, x]))
        XCTAssertEqual(h.components.requests.count, 0)
        guard case .failed = h.host.status[.instrument], case .failed = h.host.status[.insert(x.id)] else { return XCTFail("validation") }
        h.host.apply(.init(instrument: plugin(), inserts: [x])); h.host.retry(.insert(x.id))
        XCTAssertEqual(h.components.requests.count, 2)
    }
    @MainActor func testConfigurationFailureHasExplicitRecoveryAndNeverReleasesBoundInstrument() throws {
        let h = try Harness(); defer { h.finish() }
        let x = InstrumentInsert(id: UUID(), plugin: plugin(3, instrument: false))
        h.host.apply(.init(instrument: plugin(), inserts: [x]))
        h.components.succeed(0, h.unit()); h.components.succeed(1, h.unit())
        let old = try XCTUnwrap(h.host.instrument)
        h.graph.configurationFails = true
        h.host.configure(.init(sampleRate: 44_100))
        XCTAssertNotNil(old.unit); XCTAssertTrue(h.graph.attached.contains(old.id))
        h.runtime.ack()
        XCTAssertNil(old.unit); XCTAssertTrue(h.host.inserts.isEmpty)
        guard case .failed = h.host.status[.instrument], case .failed = h.host.status[.insert(x.id)] else { return XCTFail("configuration status") }
        h.host.apply(h.host.channel); XCTAssertEqual(h.components.requests.count, 2)
        h.graph.configurationFails = false
        h.host.configure(.init(sampleRate: 44_100))
        XCTAssertEqual(h.components.requests.count, 4)
        h.components.succeed(2, h.unit()); h.components.succeed(3, h.unit())
        XCTAssertEqual(h.host.status[.instrument], .loaded)
        XCTAssertEqual(h.host.status[.insert(x.id)], .loaded)
    }
    @MainActor func testDuplicateOfLoadedInsertIsRemovedWithoutGraphCycle() throws {
        let h = try Harness(); defer { h.finish() }
        let x = InstrumentInsert(id: UUID(), plugin: plugin(3, instrument: false))
        h.host.apply(.init(inserts: [x])); h.components.succeed(0, h.unit())
        h.host.apply(.init(inserts: [x, x]))
        XCTAssertTrue(h.graph.ordered.isEmpty); XCTAssertTrue(h.host.inserts.isEmpty)
        guard case .failed = h.host.status[.insert(x.id)] else { return XCTFail("duplicate status") }
    }

    @MainActor func testExplicitStopRetiresBeforeGraphStopAndStartReattachesSameInstance() throws {
        let h = try Harness(); defer { h.finish() }
        h.host.apply(.init(instrument: plugin())); h.components.succeed(0, h.unit())
        let old = try XCTUnwrap(h.host.instrument)
        try h.host.start(); h.trace.events.removeAll()
        h.host.stop()
        XCTAssertEqual(h.trace.events, ["retire"])
        XCTAssertTrue(h.host.isRunning)
        h.runtime.ack()
        XCTAssertFalse(h.host.isRunning); XCTAssertTrue(h.host.instrument === old)
        XCTAssertTrue(h.runtime.schedules.isEmpty)
        try h.host.start()
        XCTAssertTrue(h.host.isRunning); XCTAssertEqual(h.runtime.attachments, [old.id, old.id])
    }

    @MainActor func testDeviceDisplayUsesOnlyConfirmedConfigurationAndReportsFailure() throws {
        let h = try Harness(); defer { h.finish() }
        let display = AudioOutputDeviceControlModel(host: h.host)
        h.host.configure(.init(sampleRate: 44_100)); XCTAssertEqual(display.currentSampleRate, 44_100)
        h.graph.configurationFails = true
        h.host.configure(.init(sampleRate: 96_000)); XCTAssertEqual(display.currentSampleRate, 44_100)
        XCTAssertTrue(display.notice?.contains("Audio configuration:") == true)
    }

}
