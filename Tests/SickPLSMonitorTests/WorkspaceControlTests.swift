import Combine
import PlanariumDomain
import Foundation
import XCTest
import PlanariumInput
import PlanariumPresets
import SickPLSMonitorKit
@testable import SickPLSMonitor

@MainActor final class WorkspaceControlTests: XCTestCase {
    func testPerformanceLossAndReturnRestoreExactLayoutAndKeepPreferencesLocal() throws {
        let name = "Perform-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = WorkspaceControlModel(defaults: defaults)
        model.accept(.streaming(portPath: "offline", pointCount: 90))
        model.setVisible(.layers, false); model.setVisible(.channelStrip, false); model.selectTab(.cell)
        let previous = model.preferences
        var canvas = MetricCanvasInteractionState()
        model.togglePerformance(canvas: &canvas)
        XCTAssertTrue(canvas.isPerformanceLocked)
        model.accept(.failed(portPath: "offline", message: "Lost"))
        XCTAssertTrue(model.inputLost); XCTAssertEqual(model.preferences, previous)
        model.setVisible(.setup, true); model.setVisible(.layers, true); model.selectTab(.layers)
        XCTAssertEqual(model.preferences, previous)
        let stage = WorkspaceLayout.forAvailableWidth(900, visibility: model.preferences.visibility, mode: model.mode)
        XCTAssertEqual(stage.rows[0].areas, [.field, .channelStrip])
        model.togglePerformance(canvas: &canvas); XCTAssertEqual(model.preferences, previous)
        XCTAssertFalse(canvas.isPerformanceLocked)
        XCTAssertEqual(WorkspaceControlModel(defaults: defaults).preferences, previous)
        model.accept(.opening(portPath: "offline")); XCTAssertTrue(model.preferences.setup)
    }
    func testScannerAndSimulationRecoveryRespectManualOpenAndResetOnReconnect() throws {
        for simulated in [false, true] {
            let name = "LayoutControl-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            let model = WorkspaceControlModel(defaults: defaults)
            let opening: MeasurementSessionStatus = simulated ? .simulation(.opening(serviceName: "Offline")) : .opening(portPath: "offline-port")
            let waiting: MeasurementSessionStatus = simulated ? .simulation(.openWithoutProfile(serviceName: "Offline")) : .openWithoutProfile(portPath: "offline-port")
            let streaming: MeasurementSessionStatus = simulated ? .simulation(.streaming(serviceName: "Offline", pointCount: 90)) : .streaming(portPath: "offline-port", pointCount: 90)
            model.accept(.idle); model.accept(opening); model.accept(waiting)
            XCTAssertTrue(model.preferences.setup)
            model.accept(streaming); XCTAssertFalse(model.preferences.setup)
            model.setVisible(.setup, true)
            var publications = 0
            let subscription = model.objectWillChange.sink { publications += 1 }
            for _ in 20...30 {
                model.accept(simulated ? .simulation(.streaming(serviceName: "Offline", pointCount: 90)) : .streaming(portPath: "offline-port", pointCount: 90))
                XCTAssertTrue(model.preferences.setup)
            }
            XCTAssertEqual(publications, 0)
            subscription.cancel()
            model.accept(simulated ? .simulation(.failed(serviceName: "Offline", message: "Lost")) : .failed(portPath: "offline-port", message: "Lost"))
            XCTAssertTrue(model.preferences.setup)
            model.accept(.idle); model.accept(opening); model.accept(waiting); model.accept(streaming)
            XCTAssertFalse(model.preferences.setup)
            model.accept(.idle); XCTAssertTrue(model.preferences.setup)
        }
    }
    func testAllVisibilityAndTabChangesPersistWithoutTouchingPresetOrUndo() throws {
        let fixture = try MonitorRootFixture()
        let before = try PresetV5Codec.encode(.init(name: "Layout invariant", document: fixture.root.document.document))
        let layout = try LayoutWorkspaceFixture(fixture: fixture)
        defer { layout.cleanDefaults() }
        layout.workspace.accept(.idle)
        for area in [WorkspaceLayout.Area.setup, .layers, .cell, .channelStrip] { layout.workspace.setVisible(area, false) }
        layout.workspace.selectTab(.cell)
        let restored = WorkspaceControlModel(defaults: try XCTUnwrap(UserDefaults(suiteName: layout.suiteName)))
        restored.accept(.idle)
        XCTAssertEqual(restored.preferences, layout.workspace.preferences)
        XCTAssertEqual(restored.preferences.inspectorTab, .cell)
        XCTAssertEqual(try PresetV5Codec.encode(.init(name: "Layout invariant", document: fixture.root.document.document)), before)
        XCTAssertFalse(fixture.root.document.canUndo)
        var done = false; fixture.root.terminate { done = true }
        let deadline = Date().addingTimeInterval(3)
        while !done, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
        XCTAssertTrue(done)
    }
}

extension WorkspaceControlTests {
    func testRundeADragPublishesAtDisplayCadenceReleaseFlushesAndEscapeRestoresOneUndo() throws {
        let fixture = try MonitorRootFixture()
        defer { fixture.root.terminate {} }
        let owner = fixture.root.document
        for kind in ["pan", "fader", "detection", "velocity"] {
            let drag = ControlDragSession()
            let original = owner.document
            var publications = 0, commits = 0
            let observation = owner.$document.dropFirst().sink { _ in publications += 1 }
            var value = 0.0
            let write: (Double) -> Void = { next in
                commits += 1; value = next
                switch kind {
                case "pan":
                    var channel = owner.document.channels[0]; channel.pan = next / 100
                    owner.updateChannel(channel)
                case "fader": owner.updateMasterLevel(-next)
                case "detection":
                    var config = owner.document.detection
                    config.groupingJumpCentimeters = UInt16(next)
                    owner.updateDetectionConfiguration(config)
                default: break // The inspector's pending velocity draft has no document commit.
                }
            }
            // Measured reproduction of the previous per-event setter path.
            owner.beginContinuousEdit()
            let roundTripStart = ProcessInfo.processInfo.systemUptime
            for step in 1...50 { write(Double(step)) }
            let roundTripMS = (ProcessInfo.processInfo.systemUptime - roundTripStart) * 1000 / 50
            owner.endContinuousEdit()
            if kind != "velocity" { XCTAssertTrue(owner.undo()) }
            commits = 0; publications = 0; value = 0
            drag.begin(0, write: write, editing: { if $0 { owner.beginContinuousEdit() } else { owner.endContinuousEdit() } })
            let start = ProcessInfo.processInfo.systemUptime
            for step in 1...50 {
                drag.change(Double(step), live: kind != "velocity")
                XCTAssertEqual(drag.displayed, Double(step))
            }
            let localMS = (ProcessInfo.processInfo.systemUptime - start) * 1000 / 50
            XCTAssertEqual(commits, 0, kind)
            XCTAssertEqual(publications, 0, kind)
            if kind != "velocity" {
                RunLoop.main.run(until: Date().addingTimeInterval(0.065))
                XCTAssertEqual(commits, 1, kind)
                XCTAssertEqual(publications, 1, kind)
            }
            drag.finish()
            XCTAssertEqual(commits, 1, kind); XCTAssertEqual(value, 50)
            let dragPublications = publications
            if kind != "velocity" {
                XCTAssertTrue(owner.undo()); XCTAssertEqual(owner.document.channels, original.channels)
                XCTAssertEqual(owner.document.masterLevelDecibels, original.masterLevelDecibels)
                XCTAssertEqual(owner.document.detection, original.detection)
            }
            observation.cancel()
            print("RUNDE-A \(kind) previous_setter_ms=\(roundTripMS) local_pointer_ms=\(localMS) commits=\(commits) publications=\(dragPublications)")
        }
        let drag = ControlDragSession()
        let before = owner.document.masterLevelDecibels
        drag.begin(before, write: owner.updateMasterLevel, editing: { if $0 { owner.beginContinuousEdit() } else { owner.endContinuousEdit() } })
        drag.change(-12, live: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.065))
        XCTAssertEqual(owner.document.masterLevelDecibels, -12)
        drag.cancel()
        XCTAssertEqual(owner.document.masterLevelDecibels, before)
        XCTAssertFalse(owner.canUndo, "Escape must not leave an empty undo step")
        drag.begin(before, write: owner.updateMasterLevel)
        drag.change(-20, live: true) // Remaining events from the cancelled drag are ignored.
        drag.finish()
        RunLoop.main.run(until: Date().addingTimeInterval(0.065))
        XCTAssertEqual(owner.document.masterLevelDecibels, before)
        drag.begin(before, write: owner.updateMasterLevel)
        drag.change(-6, live: false); drag.finish()
        XCTAssertEqual(owner.document.masterLevelDecibels, -6)
    }

    func testRundeADragFineMotionDoesNotJumpWhenOptionChangesAndReleaseHasNoLateWrite() throws {
        let detents = Array(stride(from: 0, through: 100, by: 10))
        XCTAssertEqual(DetectionKnob.draggedValue(startValue: 45, values: detents, translationY: 0), 45)
        XCTAssertEqual(DetectionKnob.draggedValue(startValue: 45, values: detents, translationY: -5.9), 45)
        XCTAssertEqual(DetectionKnob.draggedValue(startValue: 45, values: detents, translationY: -6), 50)
        XCTAssertEqual(DetectionKnob.draggedValue(startValue: 45, values: detents, translationY: 6), 40)
        XCTAssertEqual(DetectionKnob.draggedValue(startValue: 45, values: detents, translationY: 12), 30)
        XCTAssertEqual(DetectionKnob.draggedValue(startValue: 45, values: detents, translationY: 0), 45)
        let drag = ControlDragSession()
        var values: [Double] = []
        drag.begin(0, write: { values.append($0) })
        XCTAssertEqual(drag.translated(10, fine: false), 10)
        XCTAssertEqual(drag.translated(20, fine: true), 11)
        XCTAssertEqual(drag.translated(30, fine: false), 21)
        drag.change(3, live: true); drag.change(7, live: true); drag.finish()
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        XCTAssertEqual(values, [7])
        drag.begin(7, write: { values.append($0) }); drag.change(9, live: true); drag.cancel(); drag.finish()
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        XCTAssertEqual(values, [7])
    }

    func testRundeAButtonLabelsPersistInWorkspaceWithoutDocumentFieldOrInspectorWork() throws {
        let fixture = try MonitorRootFixture(), layout = try LayoutWorkspaceFixture(fixture: fixture)
        defer { layout.cleanDefaults(); fixture.root.terminate {} }
        let menu = MenuPresentationModel(instrument: fixture.root.document, workspace: layout.workspace)
        let original = fixture.root.document.document
        var documentChanges = 0, fieldChanges = 0
        let a = fixture.root.document.$document.dropFirst().sink { _ in documentChanges += 1 }
        let b = fixture.root.document.canvas.objectWillChange.sink { fieldChanges += 1 }
        XCTAssertTrue(layout.workspace.preferences.buttonLabels)
        for flag in [false, true, false] {
            layout.workspace.setButtonLabels(flag)
            RunLoop.main.run(until: Date().addingTimeInterval(0.015))
            XCTAssertEqual(menu.value.buttonLabels, flag, "Settings changes must refresh the View menu too")
            let restored = WorkspaceControlModel(defaults: try XCTUnwrap(UserDefaults(suiteName: layout.suiteName)))
            XCTAssertEqual(restored.preferences.buttonLabels, flag)
        }
        XCTAssertEqual(fixture.root.document.document, original)
        XCTAssertEqual(documentChanges, 0); XCTAssertEqual(fieldChanges, 0)
        XCTAssertFalse(fixture.root.document.canUndo)
        a.cancel(); b.cancel()
    }
}
