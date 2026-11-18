import Combine
import SickPLSControlCore
import Foundation
import XCTest
import PlanariumDomain
@testable import PlanariumPresets

@MainActor final class PresetRecoveryTests: XCTestCase {
    func testRestartUserAndFactoryPresetAndSceneAt90And361() async throws {
        for count in [90, 361] { for (factory, collision) in [(false, false), (true, false), (true, true)] {
            let h = PresetHarness(); defer { h.removeDirectory() }
            let preferences = UserDefaults(suiteName: "RecoveryTests-\(UUID())")!
            let recovery = PresetRecoveryStore(url: h.directory.appendingPathComponent("Recovery.json"))
            var doc = h.root.document.document
            let geometry = ProfileGeometryIdentity(operatingMode: count == 90 ? "MMK" : "fullScan", pointCount: count, startAngleDegrees: -90, endAngleDegrees: 90)
            let tick = geometry.tickSpan(at: count == 90 ? 20 : 79)!.lower
            let layer = SpatialDocumentLayer(id: UUID(), name: "Restart layer", color: .blue,
                isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                cells: [PolarDeviceLattice(tick: tick, rawCentimeters: 100)!],
                routings: [.init(target: .midiNote(channel: 0), program: .singleNote(note: 60, velocity: 100, transition: .legato))], cellOverrides: [:])
            doc.spatial = try .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id)
            let scene = UUID(), otherScene = UUID()
            doc.scenes = [.init(id: scene, name: "Scene", activeLayerIDs: Set(doc.spatial.layers.map(\.id))),
                          .init(id: otherScene, name: "Last played", activeLayerIDs: Set(doc.spatial.layers.map(\.id)))]
            doc.currentSceneID = scene
            let preset = InstrumentPresetV6(name: "Restart", document: doc)
            let library = factory ? try FactoryPresetLibrary(presets: [preset]) : .empty
            if !factory { try h.store.save(PresetV6Codec.encode(preset), as: "Restart") }
            if collision {
                var user = preset; user.document.beatsPerMinute = 77
                try h.store.save(PresetV6Codec.encode(user), as: "Restart")
            }
            let first = PresetControlModel(store: h.store, documentOwner: h.root.document, factoryPresets: library)
            first.configureRecovery(defaults: preferences, store: recovery)
            let name = collision ? "Factory · Restart" : "Restart"
            let identity = factory ? "Factory · Restart" : "Restart"
            XCTAssertNotNil(first.load(name, decision: .discard))
            XCTAssertEqual(preferences.string(forKey: "presetLastName"), identity)
            h.root.document.selectScene(otherScene)
            try await waitForScene(h, otherScene)
            first.rememberCurrentScene()
            XCTAssertEqual(preferences.string(forKey: "presetLastScene"), otherScene.uuidString)
            let second = PresetControlModel(store: h.store, documentOwner: h.root.document, factoryPresets: library)
            second.configureRecovery(defaults: preferences, store: recovery); second.restoreStartup()
            try await waitForScene(h, otherScene)
            XCTAssertEqual(second.lastLoadedName, name)
            XCTAssertEqual(h.root.document.document.beatsPerMinute, 120)
            XCTAssertEqual(h.root.document.document.currentSceneID, otherScene)
            XCTAssertFalse(try InstrumentCompiler.compile(h.root.document.document).hits(tick: tick, raw: 100).isEmpty)
            XCTAssertEqual(h.root.document.document.spatial.layers, doc.spatial.layers)
            XCTAssertFalse(h.root.audio.isRunning)
        } }
    }
    func testLateSnapshotAfterSuccessfulSaveCannotWinOnRestart() throws {
        let h = PresetHarness(); defer { h.removeDirectory() }
        let defaults = UserDefaults(suiteName: "RecoveryRace-\(UUID())")!
        let url = h.directory.appendingPathComponent("Recovery.json")
        let recovery = PresetRecoveryStore(url: url)
        h.presets.configureRecovery(defaults: defaults, store: recovery)
        h.presets.draftName = "Saved"; XCTAssertTrue(h.presets.save())
        h.presets.draftSummary = "Older unsaved snapshot"
        h.presets.captureRecoveryIfNeeded(now: .distantFuture); recovery.flush()
        let delayedBytes = try XCTUnwrap(recovery.read()?.data)
        h.presets.draftSummary = "Latest successful save"; XCTAssertTrue(h.presets.save())
        recovery.flush()
        // Recreate the crash cutpoint: old write landed, deletion has not.
        try delayedBytes.write(to: url, options: .atomic)
        let restarted = PresetControlModel(store: h.store, documentOwner: h.root.document, factoryPresets: .empty)
        restarted.configureRecovery(defaults: defaults, store: recovery); restarted.restoreStartup()
        XCTAssertEqual(restarted.lastLoadedName, "Saved")
        XCTAssertEqual(restarted.draftSummary, "Latest successful save")
        XCTAssertNotEqual(restarted.notice, "Recovered – not saved")
        recovery.flush()
    }
    private func waitForScene(_ harness: PresetHarness, _ id: UUID) async throws {
        let deadline = Date().addingTimeInterval(5)
        while harness.root.document.document.currentSceneID != id, Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(harness.root.document.document.currentSceneID, id)
    }
    func testRecoveryNewerOlderCorruptMissingOptionOffAndSaveClear() throws {
        let h = PresetHarness(); defer { h.removeDirectory() }
        let preferences = UserDefaults(suiteName: "RecoveryTests-\(UUID())")!
        let url = h.directory.appendingPathComponent("Recovery.json"), recovery = PresetRecoveryStore(url: url)
        h.presets.configureRecovery(defaults: preferences, store: recovery)
        h.presets.draftName = "Saved"; XCTAssertTrue(h.presets.save())
        let saved = try h.store.load("Saved")
        h.presets.recoveryNow = { Date(timeIntervalSince1970: 90) }
        h.presets.draftSummary = "Unsaved"; h.presets.captureRecoveryIfNeeded(now: Date(timeIntervalSince1970: 100))
        recovery.flush(); XCTAssertNotNil(try recovery.read())
        let originalDate = try XCTUnwrap(recovery.read()?.modified)
        h.presets.recoveryNow = { Date(timeIntervalSince1970: 101) }
        h.presets.draftSummary = "Later"; h.presets.captureRecoveryIfNeeded(now: Date(timeIntervalSince1970: 109)); recovery.flush()
        XCTAssertEqual(try recovery.read()?.modified, originalDate)
        preferences.set(0.0, forKey: "presetLastSaved")
        let restarted = PresetControlModel(store: h.store, documentOwner: h.root.document, factoryPresets: .empty)
        restarted.configureRecovery(defaults: preferences, store: recovery); restarted.restoreStartup()
        XCTAssertEqual(restarted.notice, "Recovered – not saved"); XCTAssertEqual(restarted.draftSummary, "Unsaved")
        XCTAssertEqual(try h.store.load("Saved"), saved)
        preferences.set(Date.distantFuture.timeIntervalSince1970, forKey: "presetLastSaved")
        restarted.restoreStartup(); XCTAssertEqual(restarted.lastLoadedName, "Saved")
        restarted.draftName = "Saved"; XCTAssertTrue(restarted.save()); recovery.flush(); XCTAssertNil(try recovery.read())
        try Data("broken".utf8).write(to: url, options: .atomic)
        preferences.set(0.0, forKey: "presetLastSaved"); restarted.restoreStartup()
        XCTAssertEqual(restarted.notice, "Recovery rejected – empty workspace")
        recovery.clear(); recovery.flush()
        preferences.set("Missing", forKey: "presetLastName"); restarted.restoreStartup()
        XCTAssertEqual(restarted.notice, "Last preset missing – empty workspace")
        let emptyRoot = PresetHarness(); defer { emptyRoot.removeDirectory() }
        let initial = emptyRoot.root.document.document
        let empty = PresetControlModel(store: h.store, documentOwner: emptyRoot.root.document, factoryPresets: .empty)
        empty.configureRecovery(defaults: preferences, store: recovery); empty.reopenLastPreset = false; empty.restoreStartup()
        XCTAssertNil(empty.lastLoadedName); XCTAssertNil(empty.notice)
        XCTAssertEqual(emptyRoot.root.document.document, initial)
    }
}

@MainActor private final class RecoveryCountingOwner: PresetDocumentControlling {
    var document = try! FactoryPresetDocument.empty()
    var presetViewport: PresetViewport { .init(try! .build(centerXMeters: 0, centerYMeters: 0, metersPerPoint: 0.01)) }
    var onPresetChannelSnapshot: ((InstrumentChannel) -> Void)?
    var onPresetRecoveryChange: (() -> Void)?
    var onPresetRecoveryLockChange: (() -> Void)?
    var snapshots = 0
    var locked = false
    func snapshotPresetDocument() throws -> InstrumentDocument { snapshots += 1; return document }
    func applyPresetDocument(_ document: InstrumentDocument, restoringPluginStates: Bool) throws { self.document = document }
    func applyPresetViewport(_ viewport: PresetViewport) {}
    func applyLegacyPresetViewport(_ viewport: ScanPlaneViewport) {}
    func authorize(_ action: InstrumentAction) -> Bool { !locked }
}

@MainActor private final class RecoveryTestClock {
    var now = Date(timeIntervalSince1970: 100)
    var pending: (UUID, Date, @MainActor @Sendable () -> Void)?
    func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> AnyCancellable {
        let id = UUID(); pending = (id, now.addingTimeInterval(delay), action)
        return AnyCancellable { [weak self] in
            MainActor.assumeIsolated { if self?.pending?.0 == id { self?.pending = nil } }
        }
    }
    func advance(_ seconds: TimeInterval) {
        now.addTimeInterval(seconds)
        if let next = pending, next.1 <= now { pending = nil; next.2() }
    }
}

extension PresetRecoveryTests {
    func testProductionCommitsAndLockReachRecoveryWithoutPolling() throws {
        let h = PresetHarness(); defer { h.removeDirectory() }
        let clock = RecoveryTestClock()
        h.presets.configureRecovery(defaults: UserDefaults(suiteName: "RecoveryProduction-\(UUID())")!,
                                   store: PresetRecoveryStore(url: h.directory.appendingPathComponent("production.json")))
        h.presets.recoveryNow = { clock.now }
        h.presets.scheduleRecovery = { clock.schedule($0, $1) }
        XCTAssertNil(clock.pending)
        h.root.document.updateMasterLevel(-6)
        XCTAssertNotNil(clock.pending, "Mixer document commit must mark recovery")
        clock.advance(10); XCTAssertNil(clock.pending)
        h.root.document.canvas.setPerformanceLocked(true)
        h.root.document.updateMasterLevel(-9)
        clock.advance(10); XCTAssertNil(clock.pending)
        h.root.document.canvas.setPerformanceLocked(false)
        XCTAssertNotNil(clock.pending, "Unlock must resume the retained generation")
        clock.advance(0); XCTAssertNil(clock.pending)
        h.root.audio.onEditorClosed?()
        XCTAssertNotNil(clock.pending, "Native editor close must reach recovery")
        h.presets.stopRecovery()
        XCTAssertNil(clock.pending)
        h.root.document.updateMasterLevel(-12)
        XCTAssertNil(clock.pending, "Termination must not rearm recovery")
    }

    func testEventDebounceHasNoIdleSnapshotsAndDefersPerformanceLock() throws {
        let h = PresetHarness(); defer { h.removeDirectory() }
        let owner = RecoveryCountingOwner(), clock = RecoveryTestClock()
        let model = PresetControlModel(store: h.store, documentOwner: owner, factoryPresets: .empty)
        model.configureRecovery(defaults: UserDefaults(suiteName: "RecoveryEvents-\(UUID())")!,
                                store: PresetRecoveryStore(url: h.directory.appendingPathComponent("events.json")))
        model.recoveryNow = { clock.now }
        model.scheduleRecovery = { clock.schedule($0, $1) }
        owner.snapshots = 0 // Initialization establishes the comparison baseline.
        for _ in 0..<3 {
            clock.advance(10)
            model.captureRecoveryIfNeeded(now: clock.now)
        }
        XCTAssertEqual(owner.snapshots, 0, "Idle windows must never probe native plugin state")
        owner.onPresetRecoveryChange?()
        clock.advance(9); XCTAssertEqual(owner.snapshots, 0)
        clock.advance(1); XCTAssertEqual(owner.snapshots, 1)
        clock.advance(30); XCTAssertEqual(owner.snapshots, 1)
        owner.onPresetRecoveryChange?(); clock.advance(4)
        model.draftSummary = "Description"; clock.advance(4)
        owner.onPresetRecoveryChange?(); clock.advance(9)
        XCTAssertEqual(owner.snapshots, 1)
        clock.advance(1); XCTAssertEqual(owner.snapshots, 2)
        owner.locked = true; owner.onPresetRecoveryLockChange?()
        owner.onPresetRecoveryChange?(); clock.advance(10)
        XCTAssertEqual(owner.snapshots, 2)
        clock.advance(30); XCTAssertEqual(owner.snapshots, 2)
        owner.locked = false; owner.onPresetRecoveryLockChange?(); clock.advance(0)
        XCTAssertEqual(owner.snapshots, 3)
        clock.advance(30); XCTAssertEqual(owner.snapshots, 3)
        model.stopRecovery()
    }
}

extension PresetRecoveryTests {
    func testRecoveredMarkerKeepsUserFactoryAndCollisionIdentityUntilSuccessfulSaveOrReload() throws {
        for (factory,collision) in [(false,false),(true,false),(true,true)] {
            let h = PresetHarness(); defer { h.removeDirectory() }
            let suite = "RecoveryMarker-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let recovery = PresetRecoveryStore(url: h.directory.appendingPathComponent("Recovery.json"))
            let original = InstrumentPresetV6(name: "Original",document: h.root.document.document)
            let library = factory ? try FactoryPresetLibrary(presets: [original]) : .empty
            let factoryBytes = library.data(named: "Original")
            if !factory || collision {
                var stored = original
                if collision { stored.document.beatsPerMinute = 77 }
                try h.store.save(PresetV6Codec.encode(stored),as: "Original")
            }
            let name = collision ? "Factory · Original" : "Original"
            let first = PresetControlModel(store: h.store,documentOwner: h.root.document,factoryPresets: library)
            var models = [first]
            defer { models.forEach { $0.stopRecovery() }; recovery.flush() }
            first.configureRecovery(defaults: defaults,store: recovery)
            XCTAssertNotNil(first.load(name,decision: .discard))
            try h.root.document.edit { $0.beatsPerMinute = 137 }
            first.captureRecoveryIfNeeded(now: .distantFuture); recovery.flush(); first.stopRecovery()
            defaults.set(0.0,forKey: "presetLastSaved")
            let restored = PresetControlModel(store: h.store,documentOwner: h.root.document,factoryPresets: library)
            models.append(restored); restored.configureRecovery(defaults: defaults,store: recovery); restored.restoreStartup()
            XCTAssertTrue(restored.isRecovered); XCTAssertTrue(restored.presentationIsDirty); XCTAssertTrue(restored.isDirty)
            XCTAssertEqual(restored.lastLoadedName,name); XCTAssertEqual(restored.draftName,"Original")
            XCTAssertEqual(restored.recoveryTooltip.contains("Factory preset unchanged"),factory)
            XCTAssertEqual(h.root.document.document.beatsPerMinute,137)
            restored.draftName = "invalid/name"; XCTAssertFalse(restored.save()); XCTAssertTrue(restored.isRecovered)
            XCTAssertNil(restored.load(name,decision: .cancel)); XCTAssertTrue(restored.isRecovered)
            restored.requestSave()
            if factory {
                XCTAssertTrue(restored.isSaveAsPresented); XCTAssertTrue(restored.isRecovered)
                XCTAssertEqual(restored.draftName,"Original Copy")
                restored.commitSaveAs()
            }
            XCTAssertFalse(restored.isRecovered)
            XCTAssertEqual(library.data(named: "Original"),factoryBytes)
            if collision { XCTAssertEqual(try PresetV6Codec.decode(h.store.load("Original")).document.beatsPerMinute,77) }
            try h.root.document.edit { $0.beatsPerMinute = 149 }
            restored.captureRecoveryIfNeeded(now: .distantFuture); recovery.flush(); restored.stopRecovery()
            defaults.set(0.0,forKey: "presetLastSaved")
            let again = PresetControlModel(store: h.store,documentOwner: h.root.document,factoryPresets: library)
            models.append(again); again.configureRecovery(defaults: defaults,store: recovery); again.restoreStartup()
            XCTAssertTrue(again.isRecovered)
            XCTAssertNil(again.load("Missing",decision: .discard)); XCTAssertTrue(again.isRecovered)
            XCTAssertNotNil(again.load(name,decision: .discard)); XCTAssertFalse(again.isRecovered)
            XCTAssertEqual(h.root.document.document.beatsPerMinute,factory ? 120 : 137)
        }
    }
    func testRecoveredUntitledWorkspaceRemainsMarkedWhileSaveAsIsCancelled() throws {
        let h = PresetHarness(); defer { h.removeDirectory() }
        let suite = "RecoveryUntitled-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recovery = PresetRecoveryStore(url: h.directory.appendingPathComponent("Recovery.json"))
        let first = PresetControlModel(store: h.store,documentOwner: h.root.document,factoryPresets: .empty)
        first.configureRecovery(defaults: defaults,store: recovery)
        try h.root.document.edit { $0.beatsPerMinute = 137 }
        first.captureRecoveryIfNeeded(now: .distantFuture); recovery.flush(); first.stopRecovery()
        let restored = PresetControlModel(store: h.store,documentOwner: h.root.document,factoryPresets: .empty)
        defer { restored.stopRecovery(); recovery.flush() }
        restored.configureRecovery(defaults: defaults,store: recovery); restored.restoreStartup()
        XCTAssertTrue(restored.isRecovered); XCTAssertNil(restored.lastLoadedName); XCTAssertEqual(restored.draftName,"Untitled")
        restored.requestSave(); XCTAssertTrue(restored.isSaveAsPresented); XCTAssertTrue(restored.isRecovered)
        restored.isSaveAsPresented = false; XCTAssertTrue(restored.isRecovered)
        restored.requestSave(); restored.commitSaveAs(); XCTAssertFalse(restored.isRecovered)
    }
}
