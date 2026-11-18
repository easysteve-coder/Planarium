import XCTest
import Foundation
import PlanariumAudio
import PlanariumDomain
import PlanariumInput
import SickPLSMonitorKit
@testable import PlanariumPresets

@MainActor final class PresetV5ProductionTests: XCTestCase {
    func testMixerAndEditorEventsAdvanceDecisionGeneration() async throws {
        let h = try V5Harness()
        let owner = h.root.document
        let initial = owner.presetChangeGeneration
        let plugin = owner.presetPluginChangeGeneration
        var channel = owner.document.channel; channel.pan = 0.5
        owner.updateChannel(channel)
        XCTAssertGreaterThan(owner.presetChangeGeneration, initial)
        XCTAssertEqual(owner.presetPluginChangeGeneration, plugin)
        let edited = owner.presetChangeGeneration
        XCTAssertTrue(owner.undo())
        XCTAssertGreaterThan(owner.presetChangeGeneration, edited)
        let undone = owner.presetChangeGeneration
        h.root.audio.onEditorClosed?()
        XCTAssertGreaterThan(owner.presetChangeGeneration, undone)
        XCTAssertGreaterThan(owner.presetPluginChangeGeneration, plugin)
        await h.finish()
    }

    func testPendingLoadRejectsNativeEditorChangeWithoutDocumentRevisionForSaveAndDiscard() async throws {
        for decision in [PresetLoadDecision.save, .discard] {
            let h = try V5Harness()
            try h.write(.init(name: "A", document: v5Document()))
            try h.write(.init(name: "B", document: v5Document()))
            XCTAssertNotNil(h.presets.load("A")); await h.settle()
            h.root.document.canvas.renameSelectedLayer("Dirty")
            XCTAssertNil(h.presets.load("B"))
            let revision = h.root.document.document.revision
            let unit = try XCTUnwrap(h.source.units.last)
            unit.state = Data([241, 242]); h.root.audio.onEditorClosed?()
            XCTAssertEqual(h.root.document.document.revision, revision, "Native editor state has no document revision")
            let current = try h.root.document.snapshotPresetDocument(), saved = try h.store.load("A")
            let writes = h.source.units.map { $0.applied.count }
            h.presets.resolvePendingLoad(decision)
            XCTAssertEqual(try h.root.document.snapshotPresetDocument(), current)
            XCTAssertEqual(h.source.units.map { $0.applied.count }, writes)
            XCTAssertEqual(try h.store.load("A"), saved)
            XCTAssertEqual(h.presets.lastLoadedName, "A")
            XCTAssertEqual(h.presets.notice, "Changed meanwhile – choose again")
            let deadline = Date().addingTimeInterval(2)
            while h.presets.pendingLoadName == nil, Date() < deadline { await Task.yield() }
            XCTAssertEqual(h.presets.pendingLoadName, "B")
            h.presets.resolvePendingLoad(decision); await h.settle()
            XCTAssertEqual(h.presets.lastLoadedName, "B")
            let captured = try PresetDocumentReader.read(h.store.load("A")).get().replacing(current)
            XCTAssertEqual(captured.channel, decision == .save ? current.channel : try PresetDocumentReader.read(saved).get().replacing(current).channel)
            XCTAssertEqual(h.graph.starts, 0)
            await h.finish()
        }
    }

    func testPendingDiscardDoesNotReadNativeSnapshot() async throws {
        let h = try V5Harness()
        try h.write(.init(name: "A", document: v5Document()))
        XCTAssertNotNil(h.presets.load("A")); await h.settle()
        h.root.document.canvas.renameSelectedLayer("Dirty"); XCTAssertNil(h.presets.load("A"))
        h.source.units.last!.readFails = true
        let current = h.root.document.document
        h.presets.resolvePendingLoad(.discard)
        XCTAssertNotEqual(h.root.document.document.revision, current.revision)
        XCTAssertNil(h.presets.pendingLoadID)
        XCTAssertEqual(h.presets.lastLoadedName, "A")
        await h.finish()
    }

    func testSleepDoesNotCancelAStopAlreadyWaitingForRetireAck() async throws {
        let h = try V5Harness()
        try h.root.document.applyPresetDocument(v5Document()); await h.settle()
        try h.root.audio.start()
        h.root.audio.stop(); h.root.sleep()
        await h.settle()
        XCTAssertFalse(h.root.audio.isRunning)
        h.root.wake(); await h.settle()
        XCTAssertFalse(h.root.audio.isRunning, "Wake must preserve the latest explicit Stop intent")
        await h.finish()
    }
    func testLiveChannelSurvivesSimulationAndScannerConnectDisconnect() async throws {
        let h = try V5Harness()
        XCTAssertNil(h.root.document.document.channel.instrument)
        XCTAssertTrue(h.root.document.document.channel.inserts.isEmpty)
        try h.root.document.applyPresetDocument(v5Document()); await h.settle()
        h.source.units.last!.state = Data([241])
        let live = try h.root.audio.snapshotChannel()
        let instance = h.root.audio.instrument
        let writes = h.source.units.map { $0.applied.count }
        for start in [true, false, true] {
            if start { try h.root.audio.start() } else { h.root.audio.stop() }
            await h.settle()
            XCTAssertEqual(try h.root.audio.snapshotChannel(), live)
            XCTAssertTrue(h.root.audio.instrument === instance)
            XCTAssertEqual(h.source.units.map { $0.applied.count }, writes)
        }
        for simulation in [true, false] {
            if simulation { h.root.input.connectSimulation(serviceName: "Synthetic source", opener: h.scanner) }
            else { h.root.input.connectDevelopment(portPath: "/dev/cu.synthetic", baudRate: .baud38400) }
            for _ in 0..<50 { await Task.yield() }
            XCTAssertEqual(try h.root.audio.snapshotChannel(), live)
            h.root.input.disconnect()
            for _ in 0..<1_000 {
                if !h.root.input.isAwaitingPortRelease { break }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertFalse(h.root.input.isAwaitingPortRelease)
            XCTAssertEqual(try h.root.audio.snapshotChannel(), live)
            XCTAssertTrue(h.root.audio.instrument === instance)
            XCTAssertEqual(h.source.units.map { $0.applied.count }, writes)
        }
        await h.finish()
    }
    func testEveryHarmonyPreservesLiveChannelAndEditorStateThroughProductionRoot() async throws {
        let h = try V5Harness(factoryPresets: .standard)
        try h.root.document.applyPresetDocument(v5Document()); await h.settle()
        h.source.units.last!.state = Data([233, 234])
        let channel = try h.root.audio.snapshotChannel()
        let instance = h.root.audio.instrument
        let loads = h.source.identities.count
        let stateWrites = h.source.units.map { $0.applied.count }
        let names = FactoryPresetLibrary.standard.names.filter { $0.hasPrefix("Harm") }
        XCTAssertEqual(names.count, 30)
        for name in names {
            XCTAssertNotNil(h.presets.load(name, decision: .discard), name); await h.settle()
            XCTAssertEqual(try h.root.audio.snapshotChannel(), channel, name)
            XCTAssertEqual(h.root.document.document.channel, channel, name)
            XCTAssertEqual(h.root.document.document.channelName, "Channel", name)
            XCTAssertEqual(h.root.document.document.channelColor, .blue, name)
            XCTAssertTrue(h.root.audio.instrument === instance, name)
            XCTAssertEqual(h.source.identities.count, loads, name)
            XCTAssertEqual(h.source.units.map { $0.applied.count }, stateWrites, name)
            XCTAssertFalse(h.presets.isDirty, name)
        }
        await h.finish()
    }
    func testSavingCapturesLivePluginStatesFineMaskAndWholeChannel() async throws {
        let h = try V5Harness()
        let value = try v5Document()
        try h.root.document.applyPresetDocument(value)
        await h.settle()
        h.source.units.last!.state = Data([201, 202, 203])
        h.source.units[0].state = Data([211])
        let expected = try h.root.document.snapshotPresetDocument()
        h.presets.draftName = "Snapshot"
        XCTAssertTrue(h.presets.save())
        let data = try h.store.load("Snapshot")
        let restored = try PresetDocumentReader.read(data).get().replacing(FactoryPresetDocument.empty())
        XCTAssertEqual(restored, expected)
        XCTAssertEqual(restored.channel.instrument?.state, Data([201, 202, 203]))
        XCTAssertEqual(restored.channel.inserts[0].plugin.state, Data([211]))
        XCTAssertEqual(restored.spatial.layers[0].cells, value.spatial.layers[0].cells)
        XCTAssertEqual(restored.spatial.layers[0].cellOverrides, try LegacyChannelMigration.applying(to: value).spatial.layers[0].cellOverrides)
        XCTAssertFalse(h.presets.isDirty)
        XCTAssertTrue(h.presets.save()); XCTAssertEqual(try h.store.load("Snapshot"), data)
        XCTAssertEqual(h.graph.starts, 0); XCTAssertEqual(h.windows.makes, 0)
        XCTAssertTrue(h.source.units.allSatisfy { $0.editorRequests == 0 && $0.schedule.sends == 0 })
        await h.finish()
    }
    func testSameInstrumentChangedPresetStateUsesSameInstanceInOneRevisionAndStartsNothing() async throws {
        let h = try V5Harness()
        let a = InstrumentPresetV5(name: "A", document: try v5Document())
        var b = a; b.name = "B"; b.document.channel.instrument?.state = Data([99])
        b.document.channel.inserts.reverse(); b.document.channel.inserts[0].bypassed = true
        try h.write(a); try h.write(b)
        XCTAssertNotNil(h.presets.load("A")); await h.settle()
        let instance = try XCTUnwrap(h.root.audio.instrument)
        let loads = h.source.identities.count
        let revision = h.root.document.document.revision
        let inserts = h.root.audio.inserts
        XCTAssertNotNil(h.presets.load("B", decision: .discard)); await h.settle()
        XCTAssertEqual(h.root.document.document.revision.session, revision.session)
        XCTAssertEqual(h.root.document.document.revision.counter, revision.counter + 1)
        XCTAssertTrue(h.root.audio.instrument === instance)
        XCTAssertEqual(h.source.identities.count, loads)
        XCTAssertEqual(try h.root.audio.snapshotChannel(), try LegacyChannelMigration.applying(to: b.document).channel)
        XCTAssertEqual(h.graph.connections, b.document.channel.inserts.map { inserts[$0.id]!.id })
        XCTAssertFalse(h.presets.isDirty)
        XCTAssertEqual(h.graph.starts, 0); XCTAssertEqual(h.windows.makes, 0)
        XCTAssertTrue(h.source.units.allSatisfy { $0.editorRequests == 0 && $0.schedule.sends == 0 })
        await h.finish()
    }
    func testEditorStateChangesAreDirtyWithoutDocumentEditAndSaveDiscardCancelWork() async throws {
        let h = try V5Harness()
        try h.write(.init(name: "A", document: v5Document()))
        XCTAssertNotNil(h.presets.load("A")); await h.settle()
        let revision = h.root.document.document.revision
        let unit = h.source.units.last!
        unit.state = Data([87]); h.root.audio.onEditorClosed?()
        XCTAssertEqual(h.root.document.document.revision, revision)
        XCTAssertTrue(h.presets.isDirty)
        XCTAssertNil(h.presets.load("A")); XCTAssertEqual(h.presets.pendingLoadName, "A")
        h.presets.resolvePendingLoad(.cancel)
        XCTAssertEqual(unit.state, Data([87])); XCTAssertTrue(h.presets.isDirty)
        XCTAssertNotNil(h.presets.load("A", decision: .save)); await h.settle()
        XCTAssertEqual(try PresetDocumentReader.read(h.store.load("A")).get().replacing(FactoryPresetDocument.empty()).channel.instrument?.state, Data([87]))
        XCTAssertFalse(h.presets.isDirty)
        unit.state = Data([88]); h.root.audio.onEditorClosed?(); XCTAssertTrue(h.presets.isDirty)
        XCTAssertNotNil(h.presets.load("A", decision: .discard)); await h.settle()
        XCTAssertEqual(unit.state, Data([87])); XCTAssertFalse(h.presets.isDirty)
        await h.finish()
    }
    func testSnapshotFailureDoesNotOverwriteFileOrClearDirtyOrEchoForeignText() async throws {
        let h = try V5Harness()
        try h.write(.init(name: "A", document: v5Document()))
        XCTAssertNotNil(h.presets.load("A")); await h.settle()
        let before = try h.store.load("A")
        h.source.units.last!.readFails = true
        h.root.audio.onEditorClosed?()
        h.presets.draftName = "A"
        XCTAssertTrue(h.presets.isDirty); XCTAssertFalse(h.presets.save())
        XCTAssertEqual(try h.store.load("A"), before)
        XCTAssertEqual(h.presets.resolveTermination(.save), .stayRunning)
        XCTAssertFalse(h.presets.notice?.contains("INVENTED-STATE-ERROR") == true)
        await h.finish()
    }
    func testInvalidV5DocumentIsAtomicIncludingHistoryViewportAndPluginLoads() async throws {
        let h = try V5Harness()
        let before = h.root.document.document
        let view = h.root.document.canvas.viewport
        let data = try PresetV5Codec.encode(.init(name: "Invalid", document: v5Document()))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var document = try XCTUnwrap(root["document"] as? [String: Any])
        var channel = try XCTUnwrap(document["channel"] as? [String: Any])
        channel["pan"] = 2; document["channel"] = channel; root["document"] = document
        try h.store.save(JSONSerialization.data(withJSONObject: root), as: "Invalid")
        XCTAssertNil(h.presets.load("Invalid"))
        XCTAssertEqual(h.root.document.document, before); XCTAssertEqual(h.root.document.canvas.viewport, view)
        XCTAssertFalse(h.root.document.canUndo); XCTAssertEqual(h.source.identities.count, 0)
        XCTAssertNil(h.presets.lastLoadedName); XCTAssertFalse(h.presets.isDirty)
        await h.finish()
    }
    func testAbsentChannelInEveryLegacyVersionPreservesEntireLiveChannelThroughProductionRoot() async throws {
        let h = try V5Harness()
        let value = try v5Document()
        try h.root.document.applyPresetDocument(value); await h.settle()
        let channel = h.root.document.document.channel
        let instance = h.root.audio.instrument
        let count = h.source.identities.count
        let fixtures = [FrozenPresetFixtures.historicalVersion1, FrozenPresetFixtures.historicalVersion2,
            FrozenPresetFixtures.polarVersion3, FrozenPresetV4Fixtures.record]
        for (index, fixture) in fixtures.enumerated() {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(fixture.utf8)) as? [String: Any])
            object.removeValue(forKey: "instrumentChannel")
            let name = "Legacy \(index)"
            try h.store.save(JSONSerialization.data(withJSONObject: object), as: name)
            let revision = h.root.document.document.revision.counter
            XCTAssertNotNil(h.presets.load(name, decision: .discard), name)
            XCTAssertEqual(h.root.document.document.channel, channel, name)
            XCTAssertEqual(h.root.document.document.revision.counter, revision + 1, name)
            XCTAssertTrue(h.root.audio.instrument === instance, name)
            XCTAssertEqual(h.source.identities.count, count, name)
        }
        XCTAssertEqual(h.graph.starts, 0); XCTAssertEqual(h.windows.makes, 0)
        await h.finish()
    }
    func testV5NativeViewportSavesWithoutOldViewportRepresentabilityAndSelectionIsNotDirty() async throws {
        let h = try V5Harness()
        let view = try MetricCanvasViewport.build(centerXMeters: 111, centerYMeters: -222, metersPerPoint: 0.001)
        h.root.document.canvas.applyPresetViewport(view)
        h.presets.draftName = "View"; XCTAssertTrue(h.presets.save())
        h.root.document.canvas.resetViewport()
        XCTAssertFalse(h.presets.isDirty)
        XCTAssertNotNil(h.presets.load("View")); XCTAssertEqual(h.root.document.canvas.viewport, view)
        await h.finish()
    }
    func testDelayedDefaultPluginStateBecomesReferenceOnceThenEditorChangesAreDirty() async throws {
        let h = try V5Harness()
        h.source.deferred = true
        var value = try v5Document(); value.channel.inserts = []; value.channel.instrument?.state = Data()
        try h.write(.init(name: "Default", document: value))
        XCTAssertNotNil(h.presets.load("Default"))
        h.source.finishNext(); await h.settle()
        XCTAssertFalse(h.presets.isDirty)
        h.source.units[0].state = Data([102]); h.root.audio.onEditorClosed?(); XCTAssertTrue(h.presets.isDirty)
        await h.finish()
    }
    func testEveryFactoryLoadsThroughProductionRootInOneRevisionWithoutStartingOrOpeningWindows() async throws {
        let h = try V5Harness(factoryPresets: .standard)
        for name in FactoryPresetLibrary.standard.names {
            let before = h.root.document.document.revision.counter
            XCTAssertNotNil(h.presets.load(name, decision: .discard), name); await h.settle()
            XCTAssertEqual(h.root.document.document.revision.counter, before + 1, name)
            XCTAssertFalse(h.presets.isDirty, name)
        }
        XCTAssertEqual(h.graph.starts, 0); XCTAssertEqual(h.windows.makes, 0)
        XCTAssertTrue(h.source.units.allSatisfy { $0.editorRequests == 0 && $0.schedule.sends == 0 })
        await h.finish()
    }
}
