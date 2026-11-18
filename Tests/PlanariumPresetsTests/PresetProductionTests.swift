@testable import LegacyPresetTestSupport
import XCTest
import Foundation
import PlanariumDomain
@testable import PlanariumPresets
@testable import PlanariumPresets

@MainActor final class PresetProductionTests: XCTestCase {
    func testPendingLoadRejectsNewDocumentOrDescriptionForSaveAndDiscard() async throws {
        for decision in [PresetLoadDecision.save, .discard] {
            for changeDescription in [false, true] {
                let h = PresetHarness(); defer { h.removeDirectory() }
                h.presets.draftName = "A"; XCTAssertTrue(h.presets.save())
                h.presets.draftName = "B"; XCTAssertTrue(h.presets.save())
                XCTAssertNotNil(h.presets.load("A"))
                h.root.document.canvas.renameSelectedLayer("Dirty")
                XCTAssertNil(h.presets.load("B"))
                if changeDescription { h.presets.draftSummary = "New description" }
                else { h.root.document.canvas.renameSelectedLayer("Newer") }
                let document = h.root.document.document
                let saved = try h.store.load("A")
                h.presets.resolvePendingLoad(decision)
                XCTAssertEqual(h.root.document.document, document)
                XCTAssertEqual(try h.store.load("A"), saved, "Stale Save must not write the file either")
                XCTAssertEqual(h.presets.lastLoadedName, "A")
                XCTAssertEqual(h.presets.notice, "Changed meanwhile – choose again")
                await assertRepeatedDecision(h.presets, name: "B")
                h.presets.resolvePendingLoad(decision)
                XCTAssertEqual(h.presets.lastLoadedName, "B")
                XCTAssertNil(h.presets.pendingLoadName)
                XCTAssertTrue(h.root.document.undo())
                XCTAssertEqual(h.root.document.document.spatial, document.spatial,
                               "Successful load remains one undo step")
                XCTAssertEqual(try h.store.load("A") == saved, decision == .discard)
            }
        }
    }

    func testPendingDiscardRejectsRevisionEvenWhenUndoRestoresIdenticalSemantics() async throws {
        let h = PresetHarness(); defer { h.removeDirectory() }
        h.presets.draftName = "A"; XCTAssertTrue(h.presets.save()); XCTAssertNotNil(h.presets.load("A"))
        h.root.document.canvas.renameSelectedLayer("Dirty")
        XCTAssertNil(h.presets.load("A"))
        let original = h.root.document.document
        h.root.document.endContinuousEdit()
        h.root.document.canvas.renameSelectedLayer("Temporary")
        XCTAssertTrue(h.root.document.undo())
        XCTAssertEqual(h.root.document.document.spatial, original.spatial)
        XCTAssertNotEqual(h.root.document.document.revision, original.revision)
        let newer = h.root.document.document
        h.presets.resolvePendingLoad(.discard)
        XCTAssertEqual(h.root.document.document, newer)
        XCTAssertEqual(h.presets.notice, "Changed meanwhile – choose again")
        await assertRepeatedDecision(h.presets, name: "A")
    }

    func testAnotherPresetLoadInvalidatesPendingSaveAndDiscard() async throws {
        for decision in [PresetLoadDecision.save, .discard] {
            let h = PresetHarness(); defer { h.removeDirectory() }
            for name in ["A", "B", "C"] { h.presets.draftName = name; XCTAssertTrue(h.presets.save()) }
            XCTAssertNotNil(h.presets.load("A"))
            h.root.document.canvas.renameSelectedLayer("Dirty")
            XCTAssertNil(h.presets.load("B"))
            XCTAssertNotNil(h.presets.load("C", decision: .discard))
            let current = h.root.document.document, saved = try h.store.load("C")
            h.presets.resolvePendingLoad(decision)
            XCTAssertEqual(h.root.document.document, current)
            XCTAssertEqual(h.presets.lastLoadedName, "C")
            XCTAssertEqual(try h.store.load("C"), saved)
            XCTAssertEqual(h.presets.notice, "Changed meanwhile – choose again")
            await assertRepeatedDecision(h.presets, name: "B")
            h.presets.resolvePendingLoad(.cancel)
            XCTAssertNil(h.presets.pendingLoadName)
            XCTAssertEqual(h.root.document.document, current)
        }
    }

    func testOldDialogDecidesCurrentRequestAndCancelAlwaysCloses() async throws {
        for cancel in [false, true] {
            let h = PresetHarness(); defer { h.removeDirectory() }
            for name in ["A", "B"] { h.presets.draftName = name; XCTAssertTrue(h.presets.save()) }
            h.root.document.canvas.renameSelectedLayer("Dirty")
            XCTAssertNil(h.presets.load("A"))
            let oldID = try XCTUnwrap(h.presets.pendingLoadID)
            XCTAssertNil(h.presets.load("B"))
            let before = h.root.document.document
            h.presets.resolvePendingLoad(cancel ? .cancel : .discard, confirmationID: oldID)
            XCTAssertNil(h.presets.pendingLoadID)
            XCTAssertNil(h.presets.pendingLoadName)
            if cancel { XCTAssertEqual(h.root.document.document, before) }
            else { XCTAssertEqual(h.presets.lastLoadedName, "B") }
        }
        let h = PresetHarness(); defer { h.removeDirectory() }
        h.root.document.canvas.renameSelectedLayer("Dirty")
        XCTAssertNil(h.presets.load("A"))
        h.presets.cancelPendingLoad(confirmationID: UUID())
        XCTAssertNil(h.presets.pendingLoadID)
    }

    func testCancelDuringRepeatDoesNotResurrectOldDialog() async throws {
        let h = PresetHarness(); defer { h.removeDirectory() }
        h.presets.draftName = "A"; XCTAssertTrue(h.presets.save())
        h.root.document.canvas.renameSelectedLayer("Dirty"); XCTAssertNil(h.presets.load("A"))
        h.root.document.canvas.renameSelectedLayer("Newer"); h.presets.resolvePendingLoad(.discard)
        h.presets.cancelPendingLoad()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(h.presets.pendingLoadName)
        XCTAssertEqual(h.root.document.document.spatial.layers[0].name, "Newer")
    }

    private func assertRepeatedDecision(_ model: PresetControlModel, name: String,
                                        file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(2)
        while model.pendingLoadName == nil, Date() < deadline { await Task.yield() }
        XCTAssertEqual(model.pendingLoadName, name, file: file, line: line)
    }

    func testScaleToggleMigrationIsVisibleOnRealPresetLoad() throws {
        let h = PresetHarness(); defer { h.removeDirectory() }
        var document = h.root.document.document
        let layer = SpatialDocumentLayer(id: UUID(), name: "Old Toggle", color: .orange,
            isVisible: true, isActive: true, isLocked: false, isSoloed: false, cells: [],
            routings: [.init(target: .midiNote(channel: 0), program: .scale(rootMIDINote: 60,
                lowestMIDINote: 48, highestMIDINote: 84, scale: .major, directionDegrees: 90,
                ascending: true, transition: .toggle))], cellOverrides: [:])
        document.spatial = try .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id)
        try h.store.save(PresetV6Codec.encode(.init(name: "OldToggle", document: document)), as: "OldToggle")
        XCTAssertNotNil(h.presets.load("OldToggle", decision: .discard))
        XCTAssertEqual(h.root.document.canvas.workspace.selectedNoteTransition, .retrigger)
        XCTAssertEqual(h.presets.notice, "Loaded: OldToggle. Scale / Random scale: Toggle changed to Retrigger.")
        XCTAssertFalse(h.root.audio.isRunning); XCTAssertFalse(h.root.midi.isRunning)
    }
    func testSaveUpdatesTheLoadedLibraryPresetWithoutAReplacementPrompt() throws {
        let h = PresetHarness(); defer { h.removeDirectory() }
        h.presets.draftName = "Own"; XCTAssertTrue(h.presets.save())
        XCTAssertNotNil(h.presets.load("Own"))
        h.root.document.canvas.renameSelectedLayer("Changed by Save")
        XCTAssertTrue(h.presets.isDirty)

        h.presets.requestSave()

        XCTAssertNil(h.presets.pendingSaveName)
        XCTAssertFalse(h.presets.isSaveAsPresented)
        let saved = try PresetDocumentReader.read(h.store.load("Own")).get()
        XCTAssertEqual(try saved.replacing(FactoryPresetDocument.empty()).spatial.layers[0].name, "Changed by Save")
        XCTAssertFalse(h.presets.isDirty)
    }

    func testSaveAsUsesExistingReplacementDecisionAndAdoptsItsNewPreset() throws {
        let h = PresetHarness(); defer { h.removeDirectory() }
        h.presets.draftName = "Taken"; XCTAssertTrue(h.presets.save())
        h.presets.draftName = "Fresh"
        h.presets.beginSaveAs()
        h.presets.draftName = "Taken"
        h.presets.commitSaveAs()
        XCTAssertEqual(h.presets.pendingSaveName, "Taken")
        XCTAssertTrue(h.presets.isSaveAsPresented)
        h.presets.resolvePendingSave(confirmed: true)
        XCTAssertEqual(h.presets.lastLoadedName, "Taken")
        XCTAssertFalse(h.presets.isSaveAsPresented)
    }

    func testSaveWithoutALoadedPresetAndFactoryPresetOpensSaveAs() throws {
        let h = PresetHarness(); defer { h.removeDirectory() }
        h.presets.requestSave()
        XCTAssertTrue(h.presets.isSaveAsPresented)
        h.presets.isSaveAsPresented = false

        let factory = PresetControlModel(store: h.store, documentOwner: h.root.document, factoryPresets: .standard)
        XCTAssertNotNil(factory.load("Factory 00 Blank Channel", decision: .discard))
        factory.requestSave()
        XCTAssertTrue(factory.isSaveAsPresented)
        XCTAssertEqual(factory.draftName, "Factory 00 Blank Channel Copy")
    }
    func testAbsentLegacyChannelPreservesWholeLiveChannelAndImportsInOneRevision() throws {
        let h = PresetHarness(); defer { h.removeDirectory() }
        let identity = SpatialAudioUnitIdentity(componentType: 0x61756d75, componentSubType: 7, componentManufacturer: 8)
        let fx = SpatialAudioUnitIdentity(componentType: 0x61756678, componentSubType: 9, componentManufacturer: 8)
        let channel = InstrumentChannel(instrument: .init(identity: identity, state: Data([11])),
            inserts: [.init(id: UUID(), plugin: .init(identity: fx, state: Data([22])), bypassed: true)],
            levelDecibels: -8, midiTarget: nil, pan: 0.7, muted: true, soloed: true)
        h.root.document.updateChannel(channel)
        let loadCount = h.source.loads
        var workspace = h.root.document.canvas.workspace
        workspace.setChannelName("Imported")
        var record = h.legacyRecord(name: "Absent")
        record.spatialWorkspace = workspace; record.instrumentChannel = nil
        try h.store.save(PresetCodec.encode(record), as: "Absent")
        let before = h.root.document.document.revision.counter
        XCTAssertNotNil(h.presets.load("Absent", decision: .discard))
        XCTAssertEqual(h.root.document.document.revision.counter, before+1)
        XCTAssertEqual(h.root.document.document.channel, channel)
        XCTAssertEqual(h.root.audio.channel, channel)
        XCTAssertEqual(h.source.loads, loadCount, "no state load or new AU request from absent channel")
        XCTAssertFalse(h.root.audio.isRunning); XCTAssertFalse(h.root.midi.isRunning)
    }
    func testV4ReadKeepsFineLatticeAndDoesNotGoThroughV3Codec() throws {
        let h = PresetHarness(); defer { h.removeDirectory() }
        let base = h.legacyRecord(name: "V4")
        let old = h.root.document.document.spatial.layers[0]
        let layer = SpatialDocumentLayer(id: old.id, name: "Fine", color: old.color, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
            cells: [.init(ring: 21, sector: 181)!], routings: [], cellOverrides: [:])
        let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id)
        let record = InstrumentPresetV4(settingsOf: base, spatialDocument: spatial)
        try h.store.save(JSONEncoder().encode(record), as: "V4")
        XCTAssertNotNil(h.presets.load("V4")); XCTAssertEqual(h.root.document.document.spatial, spatial)
        XCTAssertFalse(h.root.audio.isRunning); XCTAssertEqual(h.source.loads, 0)
    }
    func testMalformedPresetIsAtomicAndCreatesNoHistoryEntry() throws {
        let h = PresetHarness(); defer { h.removeDirectory() }
        try h.store.save(Data("{\"formatVersion\":99}".utf8), as: "Broken")
        let before = h.root.document.document
        XCTAssertNil(h.presets.load("Broken")); XCTAssertEqual(h.root.document.document, before)
        XCTAssertFalse(h.root.document.canUndo); XCTAssertEqual(h.source.loads, 0)
    }
    func testSaveUsesV6AndReloadsRepresentableCanvas() throws {
        let h = PresetHarness(); defer { h.removeDirectory() }
        h.root.document.canvas.renameSelectedLayer("Saved layer")
        h.presets.draftName = "Saved"; XCTAssertTrue(h.presets.save())
        let data = try h.store.load("Saved")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["formatVersion"] as? Int, 6)
        h.root.document.canvas.renameSelectedLayer("Changed")
        XCTAssertTrue(h.presets.isDirty); XCTAssertNotNil(h.presets.load("Saved", decision: .discard))
        XCTAssertEqual(h.root.document.document.spatial.layers[0].name, "Saved layer")
        XCTAssertFalse(h.presets.isDirty)
    }
    func testDirtyUndoReturnsToSavedSemanticDocument() throws {
        let h = PresetHarness(); defer { h.removeDirectory() }
        h.presets.draftName = "Saved"; XCTAssertTrue(h.presets.save())
        var channel = h.root.document.document.channel; channel.pan = 0.8
        h.root.document.updateChannel(channel); XCTAssertTrue(h.presets.isDirty)
        XCTAssertTrue(h.root.document.undo()); XCTAssertFalse(h.presets.isDirty)
        XCTAssertTrue(h.root.document.redo()); XCTAssertTrue(h.presets.isDirty)
    }
    func testPendingLoadSaveDeleteAndTerminationCancelStayInert() throws {
        let h = PresetHarness(); defer { h.removeDirectory() }
        h.presets.draftName = "A"; XCTAssertTrue(h.presets.save()); XCTAssertNotNil(h.presets.load("A"))
        h.root.document.canvas.renameSelectedLayer("Dirty")
        XCTAssertNil(h.presets.load("A")); XCTAssertEqual(h.presets.pendingLoadName, "A")
        h.presets.resolvePendingLoad(.cancel); XCTAssertNil(h.presets.pendingLoadName); XCTAssertTrue(h.presets.isDirty)
        XCTAssertEqual(h.presets.resolveTermination(.cancel), .cancel)
        h.presets.requestDelete("A"); h.presets.resolvePendingDelete(confirmed: false)
        XCTAssertEqual(try h.store.list(), ["A"])
        XCTAssertFalse(h.root.audio.isRunning); XCTAssertEqual(h.source.loads, 0)
    }
    func testDeletingTheLoadedPresetClearsOnlyThePickerIdentity() throws {
        let h = PresetHarness(); defer { h.removeDirectory() }
        h.presets.draftName = "A"; XCTAssertTrue(h.presets.save())
        XCTAssertNotNil(h.presets.load("A")); XCTAssertEqual(h.presets.lastLoadedName, "A")
        let document = h.root.document.document
        h.presets.requestDelete("A"); h.presets.resolvePendingDelete(confirmed: true)
        XCTAssertNil(h.presets.lastLoadedName)
        XCTAssertFalse(h.presets.names.contains("A"))
        XCTAssertEqual(h.root.document.document, document, "Deleting a file must not change the live document")
    }
    func testCancelingPendingPresetLoadKeepsTheLoadedPickerIdentity() throws {
        let h = PresetHarness(); defer { h.removeDirectory() }
        h.presets.draftName = "A"; XCTAssertTrue(h.presets.save())
        h.presets.draftName = "B"; XCTAssertTrue(h.presets.save())
        XCTAssertNotNil(h.presets.load("A")); XCTAssertEqual(h.presets.lastLoadedName, "A")
        h.root.document.canvas.renameSelectedLayer("Dirty")
        XCTAssertNil(h.presets.load("B")); XCTAssertEqual(h.presets.pendingLoadName, "B")
        h.presets.resolvePendingLoad(.cancel)
        XCTAssertEqual(h.presets.lastLoadedName, "A", "Counterprobe: changing this to B would display an unloaded preset")
        XCTAssertTrue(h.presets.isDirty)
    }
    func testTerminatingWithSaveFailureStaysRunning() throws {
        let h = PresetHarness(); defer { h.removeDirectory() }
        h.presets.draftName = "A"; XCTAssertTrue(h.presets.save()); XCTAssertNotNil(h.presets.load("A"))
        h.root.document.canvas.renameSelectedLayer("Changed")
        try FileManager.default.removeItem(at: h.directory)
        try Data([1]).write(to: h.directory)
        XCTAssertEqual(h.presets.resolveTermination(.save), .stayRunning)
        XCTAssertTrue(h.presets.notice?.contains("Save failed") == true)
    }
}
