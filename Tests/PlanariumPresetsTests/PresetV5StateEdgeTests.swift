import XCTest
import Foundation
import PlanariumAudio
import PlanariumDomain
import SickPLSMonitorKit
@testable import PlanariumPresets

@MainActor final class PresetV5StateEdgeTests: XCTestCase {
    func testOpenInstrumentAndInsertEditorsRequireOneDecisionWithoutReadingState() async throws {
        for insert in [false, true] {
            for decision in [PresetLoadDecision.cancel, .discard, .save] {
                let h = try V5Harness()
                let document = try v5Document()
                try h.write(.init(name: "A", document: document))
                try h.write(.init(name: "B", document: document))
                XCTAssertNotNil(h.presets.load("A")); await h.settle()
                XCTAssertFalse(h.root.document.presetHasOpenPluginEditors)
                XCTAssertFalse(h.presets.isDirty)
                XCTAssertNotNil(h.presets.load("B")); await h.settle()
                XCTAssertNotNil(h.presets.load("A")); await h.settle()
                let instance = try XCTUnwrap(insert ? h.root.audio.inserts[document.channel.inserts[0].id] : h.root.audio.instrument)
                let unit = try XCTUnwrap(h.source.units.first { $0.applied.last == (insert ? document.channel.inserts[0].plugin.state : document.channel.instrument?.state) })
                unit.editorToReturn = V5Editor()
                instance.openEditor(title: "Offline fake", offscreen: true)
                XCTAssertNotNil(instance.window)
                unit.state = Data([234, 235]); unit.volatileReads = true
                let reads = h.source.units.map(\.stateReads)
                XCTAssertTrue(h.root.document.presetHasOpenPluginEditors)
                XCTAssertTrue(h.presets.isDirty)
                XCTAssertTrue(h.presets.presentationIsDirty)
                XCTAssertEqual(h.presets.terminationPrompt, .save(name: "A"))
                XCTAssertNil(h.presets.load("B"))
                XCTAssertNotNil(h.presets.pendingLoadID)
                XCTAssertEqual(h.source.units.map(\.stateReads), reads)
                h.presets.resolvePendingLoad(decision)
                XCTAssertNil(h.presets.pendingLoadID, "An editor remaining open must not repeat the question")
                XCTAssertEqual(h.presets.lastLoadedName, decision == .cancel ? "A" : "B")
                if decision == .cancel {
                    h.presets.draftName = "A"
                    XCTAssertTrue(h.presets.save())
                    XCTAssertTrue(h.presets.isDirty, "An editor still open after Save remains a possible edit")
                    instance.closeEditor()
                    XCTAssertFalse(h.root.document.presetHasOpenPluginEditors)
                    XCTAssertTrue(h.presets.isDirty, "Opening then closing since Save/Load remains a possible edit")
                    XCTAssertTrue(h.presets.save())
                    XCTAssertFalse(h.presets.isDirty)
                }
                await h.finish()
            }
        }
    }

    func testOpeningEditorDuringPendingDecisionRequiresOnlyOneNewQuestion() async throws {
        let h = try V5Harness()
        let document = try v5Document()
        try h.write(.init(name: "A", document: document)); try h.write(.init(name: "B", document: document))
        XCTAssertNotNil(h.presets.load("A")); await h.settle()
        h.root.document.canvas.renameSelectedLayer("Dirty")
        XCTAssertNil(h.presets.load("B"))
        let old = h.presets.pendingLoadID
        let instance = try XCTUnwrap(h.root.audio.instrument)
        let unit = try XCTUnwrap(h.source.units.first { $0.applied.last == document.channel.instrument?.state })
        unit.editorToReturn = V5Editor(); instance.openEditor(title: "Offline", offscreen: true)
        h.presets.resolvePendingLoad(.discard)
        XCTAssertNotEqual(h.presets.pendingLoadID, old)
        XCTAssertNotNil(h.presets.pendingLoadID)
        XCTAssertEqual(h.presets.lastLoadedName, "A")
        h.presets.resolvePendingLoad(.discard)
        XCTAssertNil(h.presets.pendingLoadID)
        XCTAssertEqual(h.presets.lastLoadedName, "B")
        await h.finish()
    }

    func testVolatileFullStateNeverRepeatsDecisionAndSaveStillCapturesState() async throws {
        for decision in [PresetLoadDecision.cancel, .discard, .save] {
            let h = try V5Harness()
            var document = try v5Document(); document.channel.inserts = []
            try h.write(.init(name: "A", document: document))
            try h.write(.init(name: "B", document: document))
            XCTAssertNotNil(h.presets.load("A")); await h.settle()
            let unit = try XCTUnwrap(h.source.units.first)
            unit.volatileReads = true
            let reads = unit.stateReads
            XCTAssertFalse(h.presets.isDirty)
            XCTAssertTrue(h.presets.unsavedChangeReasons.isEmpty)
            XCTAssertNotNil(h.presets.load("B")); await h.settle()
            XCTAssertNil(h.presets.pendingLoadID)
            // Reload establishes A as the save target; keep the volatile fake.
            XCTAssertNotNil(h.presets.load("A")); await h.settle()
            let beforeDecisionReads = unit.stateReads
            h.root.audio.onEditorClosed?()
            XCTAssertTrue(h.presets.isDirty)
            XCTAssertNil(h.presets.load("B"))
            XCTAssertEqual(unit.stateReads, beforeDecisionReads, "Dirty checks and checkpoints must never read fullState")
            let id = h.presets.pendingLoadID
            h.presets.resolvePendingLoad(decision, confirmationID: id)
            XCTAssertNil(h.presets.pendingLoadID)
            for _ in 0..<10 { await Task.yield() }
            XCTAssertNil(h.presets.pendingLoadName)
            XCTAssertEqual(h.presets.lastLoadedName, decision == .cancel ? "A" : "B")
            if decision == .save {
                let saved = try PresetDocumentReader.read(h.store.load("A")).get().replacing(document)
                XCTAssertNotEqual(saved.channel.instrument?.state, document.channel.instrument?.state)
                XCTAssertGreaterThan(unit.stateReads, beforeDecisionReads)
            }
            XCTAssertGreaterThanOrEqual(unit.stateReads, reads)
            await h.finish()
        }
    }

    func testEditorEventsRemainDirtyUntilSavedAndMixerUndoRestoresCleanContent() async throws {
        let h = try V5Harness()
        var value = try v5Document(); value.channel.inserts = []
        try h.write(.init(name: "State", document: value))
        XCTAssertNotNil(h.presets.load("State")); await h.settle()
        let unit = try XCTUnwrap(h.source.units.first)
        unit.musicalStateFingerprint = Data([1])
        h.presets.draftName = "Saved"; XCTAssertTrue(h.presets.save())
        unit.state = Data([90]) // Same controls, different editor/meter data.
        h.root.audio.instrument?.openEditor(title: "Fake")
        h.root.audio.instrument?.closeEditor()
        h.root.audio.onEditorClosed?() // Fake editor source does not create a native window.
        XCTAssertTrue(h.presets.isDirty, "Closing the editor is the explicit change event")
        XCTAssertTrue(h.presets.save())
        XCTAssertEqual(h.presets.terminationPrompt, .none)
        h.presets.noteViewport(.fullField)
        XCTAssertFalse(h.presets.isDirty)
        unit.musicalStateFingerprint = Data([2]); unit.state = Data([91]); h.root.audio.onEditorClosed?()
        XCTAssertTrue(h.presets.isDirty)
        XCTAssertEqual(h.presets.unsavedChangeReasons, ["Plugin settings changed"])
        unit.musicalStateFingerprint = Data([1]); unit.state = Data([92])
        XCTAssertTrue(h.presets.isDirty, "An editor change event remains dirty until Save or Load")
        XCTAssertTrue(h.presets.save())
        var changed = h.root.document.document.channel; changed.pan = 0.5
        h.root.document.updateChannel(changed)
        XCTAssertTrue(h.presets.isDirty)
        XCTAssertTrue(h.presets.unsavedChangeReasons.contains("Channels changed"))
        XCTAssertTrue(h.root.document.undo()); await h.settle()
        XCTAssertFalse(h.presets.isDirty)
        unit.musicalStateFingerprint = Data([2]); unit.state = Data([93])
        XCTAssertTrue(h.presets.save())
        let saved = try PresetDocumentReader.read(h.store.load("Saved")).get().replacing(FactoryPresetDocument.empty())
        XCTAssertEqual(saved.channel.instrument?.state, Data([93]), "Save still captures the full native state")
        unit.state = Data([94]); XCTAssertFalse(h.presets.isDirty)
        await h.finish()
    }
    func testSavedProjectStaysCleanAfterRuntimeScenePlayingButAuthorsStillMakeItDirty() async throws {
        let h = try V5Harness(factoryPresets: .standard)
        XCTAssertNotNil(h.presets.load("Harmony 29 Picardy Switch", decision: .discard))
        h.presets.draftName = "Played"; XCTAssertTrue(h.presets.save())
        let owner = h.root.document
        let next = try XCTUnwrap(owner.document.scenes.last?.id)
        owner.selectScene(next)
        await withCheckedContinuation { continuation in h.root.runtime.acknowledge { continuation.resume() } }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(owner.document.currentSceneID, next)
        XCTAssertFalse(h.presets.isDirty, "Playing a stored scene must not ask to save again")
        XCTAssertFalse(h.presets.presentationIsDirty)
        owner.canvas.renameSelectedLayer("Authored after playing")
        XCTAssertTrue(h.presets.isDirty)
        XCTAssertTrue(owner.undo())
        XCTAssertFalse(h.presets.isDirty, "Undo of the real edit returns to the saved content, with live scene retained")
        XCTAssertFalse(h.presets.presentationIsDirty)
        owner.canvas.updateWorkspace(named: "Authored activity") { $0.updateSelectedLayer { $0.isActive.toggle() } }
        await withCheckedContinuation { continuation in h.root.runtime.acknowledge { continuation.resume() } }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(h.presets.isDirty, "Real activity edits must not be hidden by a previous runtime projection")
        XCTAssertTrue(owner.undo())
        XCTAssertFalse(h.presets.isDirty)
        XCTAssertTrue(h.presets.save())
        let saved = try PresetDocumentReader.read(h.store.load("Played")).get().replacing(FactoryPresetDocument.empty())
        XCTAssertEqual(saved.currentSceneID, next, "Explicit Save still captures the chosen initial scene")
        await h.finish()
    }
    func testMetadataEditAfterV5LoadKeepsFineMasksOverridesAndMultipleRoutings() async throws {
        let h = try V5Harness()
        let original = try v5Document()
        try h.write(.init(name: "Fine", document: original))
        XCTAssertNotNil(h.presets.load("Fine")); await h.settle()
        h.root.document.canvas.renameSelectedLayer("Renamed")
        let spatial = h.root.document.document.spatial
        XCTAssertEqual(spatial.layers.count, original.spatial.layers.count)
        XCTAssertEqual(spatial.layers[0].cells, original.spatial.layers[0].cells)
        let migrated = try LegacyChannelMigration.applying(to: original)
        XCTAssertEqual(spatial.layers[0].cellOverrides, migrated.spatial.layers[0].cellOverrides)
        XCTAssertEqual(spatial.layers[0].routings, migrated.spatial.layers[0].routings)
        h.presets.draftName = "Edited"; XCTAssertTrue(h.presets.save())
        let saved = try PresetDocumentReader.read(h.store.load("Edited")).get().replacing(FactoryPresetDocument.empty())
        XCTAssertEqual(saved.spatial, spatial)
        await h.finish()
    }
    func testOwnerFileAndSameNamedFactoryAreBothSelectableWithoutShadowOrMigration() async throws {
        var factory = try v5Document(); factory.channel.pan = 0.625
        let h = try V5Harness(factoryPresets: FactoryPresetLibrary(presets: [.init(name: "Shared", document: factory)]))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(FrozenPresetFixtures.polarVersion3.utf8)) as? [String: Any])
        legacy.removeValue(forKey: "instrumentChannel")
        let original = try JSONSerialization.data(withJSONObject: legacy)
        try h.store.save(original, as: "Shared")
        h.presets.refresh()
        XCTAssertEqual(h.presets.names, ["Factory · Shared", "Shared"])
        XCTAssertTrue(h.presets.isFactoryPreset("Factory · Shared")); XCTAssertFalse(h.presets.isFactoryPreset("Shared"))
        XCTAssertNotNil(h.presets.load("Shared")); XCTAssertNil(h.root.document.document.channel.instrument)
        XCTAssertNotNil(h.presets.load("Factory · Shared", decision: .discard)); await h.settle()
        XCTAssertEqual(h.root.document.document.channel, factory.channel)
        XCTAssertEqual(try h.store.load("Shared"), original)
        await h.finish()
    }
    func testFullStateBytesRequireEditorEventToBecomeDirty() async throws {
        let h = try V5Harness()
        var value = try v5Document(); value.channel.inserts = []
        let fullState: [String: Any] = ["parameter": 0.375, "payload": Data([1, 2, 3])]
        value.channel.instrument?.state = try PropertyListSerialization.data(fromPropertyList: fullState, format: .binary, options: 0)
        try h.write(.init(name: "State", document: value))
        XCTAssertNotNil(h.presets.load("State")); await h.settle()
        let unit = h.source.units[0]
        unit.state = try PropertyListSerialization.data(fromPropertyList: fullState, format: .xml, options: 0)
        XCTAssertFalse(h.presets.isDirty)
        let writes = unit.applied.count
        XCTAssertNotNil(h.presets.load("State")); await h.settle()
        XCTAssertEqual(unit.applied.count, writes, "semantically unchanged state is no graph/state work")
        unit.state = try PropertyListSerialization.data(fromPropertyList: ["parameter": 0.5], format: .binary, options: 0)
        XCTAssertFalse(h.presets.isDirty, "Fresh bytes alone are not an authoring event")
        h.root.audio.onEditorClosed?()
        XCTAssertTrue(h.presets.isDirty)
        await h.finish()
    }
    func testOrdinaryDocumentEditRetainsEditorStateWhileExplicitReloadRestoresIt() async throws {
        let h = try V5Harness()
        try h.write(.init(name: "State", document: v5Document()))
        XCTAssertNotNil(h.presets.load("State")); await h.settle()
        let unit = h.source.units.last!
        unit.state = Data([155])
        h.root.document.canvas.renameSelectedLayer("Edited")
        XCTAssertEqual(unit.state, Data([155])); XCTAssertTrue(h.presets.isDirty)
        XCTAssertNotNil(h.presets.load("State", decision: .discard)); await h.settle()
        XCTAssertEqual(unit.state, Data([9, 10])); XCTAssertFalse(h.presets.isDirty)
        await h.finish()
    }
    func testPresetSwitchDuringDeferredLoadUsesLatestStateAndLoadsOnlyOnce() async throws {
        let h = try V5Harness()
        h.source.deferred = true
        var a = try v5Document(); a.channel.inserts = []
        var b = a; b.channel.instrument?.state = Data([77])
        try h.write(.init(name: "A", document: a)); try h.write(.init(name: "B", document: b))
        XCTAssertNotNil(h.presets.load("A")); XCTAssertNotNil(h.presets.load("B", decision: .discard))
        XCTAssertEqual(h.source.identities.count, 1)
        h.source.finishNext(); await h.settle()
        XCTAssertEqual(h.source.units[0].state, Data([77])); XCTAssertFalse(h.presets.isDirty)
        XCTAssertEqual(h.graph.starts, 0); XCTAssertEqual(h.windows.makes, 0)
        await h.finish()
    }
    func testMalformedLegacyDetectionOrV5ViewportNeverPartiallyInstalls() async throws {
        let h = try V5Harness()
        let before = h.root.document.document
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(FrozenPresetFixtures.polarVersion3.utf8)) as? [String: Any])
        var workspace = try XCTUnwrap(legacy["spatialWorkspace"] as? [String: Any])
        workspace["detectionConfiguration"] = ["groupingMinimumPoints": "INVENTED-P6-DETECTION"]
        legacy["spatialWorkspace"] = workspace
        try h.store.save(JSONSerialization.data(withJSONObject: legacy), as: "Detection")
        XCTAssertNil(h.presets.load("Detection")); XCTAssertEqual(h.root.document.document, before)
        var modern = try XCTUnwrap(JSONSerialization.jsonObject(with: PresetV5Codec.encode(.init(name: "View", document: v5Document()))) as? [String: Any])
        modern["viewport"] = ["centerXMeters": 0, "centerYMeters": 0, "metersPerPoint": -1]
        try h.store.save(JSONSerialization.data(withJSONObject: modern), as: "View")
        XCTAssertNil(h.presets.load("View")); XCTAssertEqual(h.root.document.document, before)
        XCTAssertFalse(h.root.document.canUndo); XCTAssertEqual(h.source.identities.count, 0)
        await h.finish()
    }
    func testInsertOrderAndBypassUndoRestoreSavedWholeChannelAndDirty() async throws {
        let h = try V5Harness()
        try h.write(.init(name: "Inserts", document: v5Document()))
        XCTAssertNotNil(h.presets.load("Inserts")); await h.settle()
        let before = try h.root.audio.snapshotChannel()
        var next = before; next.inserts.reverse(); next.inserts[0].bypassed.toggle()
        h.root.document.updateChannel(next); XCTAssertTrue(h.presets.isDirty)
        XCTAssertTrue(h.root.document.undo()); await h.settle()
        XCTAssertEqual(try h.root.audio.snapshotChannel(), before); XCTAssertFalse(h.presets.isDirty)
        XCTAssertTrue(h.root.document.redo()); await h.settle(); XCTAssertTrue(h.presets.isDirty)
        await h.finish()
    }
}
