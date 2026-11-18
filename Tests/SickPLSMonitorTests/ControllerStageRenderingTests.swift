import AppKit
import SwiftUI
import XCTest
import PlanariumApplication
import PlanariumControllerCore
import PlanariumDomain
import PlanariumRuntime
@testable import SickPLSMonitor

/// The drawn game controller: idle, played by the mouse, and with the
/// assignment inspector, each wide and narrow. Images go to runs/controller-stage.
@MainActor final class ControllerStageRenderingTests: XCTestCase {
    private var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agent_handoff/runs/controller-stage")
    }

    func testIdlePlayedAndInspectorStatesWideAndNarrow() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = try MonitorRootFixture()
        defer { fixture.root.terminate {} }
        let model = fixture.root.document, stage = model.controllerStage, display = fixture.root.display
        func view(editable: Bool, mouse: Bool = true, selected: ControllerElement? = nil) -> some View {
            ControllerStageView(display: display, instrument: model, stage: stage, editable: editable, playsWithMouse: mouse, selected: selected)
        }
        for (width, height) in [(900, 460), (380, 300)] {
            try render(view(editable: true), width: width, height: height, name: "idle-\(width).png")
        }

        var layout = ControllerAssistant.drums.applied(to: .empty, output: .midi(channel: 9))
        layout = ControllerAssistant.melody.applied(to: layout, output: .midi(channel: 0))
        var sectors = layout
        for index in 0..<4 {
            sectors.assignments.append(.init(name: "Pad \(index + 1)", color: SpatialLayerColor.palette[index + 4], element: .touchpad,
                zone: .sector(index: index, count: 4),
                routing: .init(target: .midiNote(channel: 2), program: .singleNote(note: 48 + index, velocity: 90, transition: .retrigger))))
        }
        XCTAssertTrue(model.setControllerLayout(sectors))
        XCTAssertEqual(model.document.controller, sectors, "the layout is part of the document")
        XCTAssertTrue(model.canUndo)

        stage.press(.cross, true)
        stage.setValue(.r2, 0.7)
        stage.setPosition(.rightStick, .init(x: 0.8, y: 0.4))
        stage.setPosition(.touchpad, .init(x: 0.5, y: 0.1))
        display.setVisible(true); display.start()
        let deadline = Date().addingTimeInterval(3)
        while (display.frame?.controller.playingAssignmentIDs.count ?? 0) < 3 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02)); display.read()
        }
        let playing = try XCTUnwrap(display.frame?.controller.playingAssignmentIDs)
        let kick = try XCTUnwrap(sectors.assignments.first { $0.name == "Kick" })
        XCTAssertTrue(playing.contains(kick.id), "the simulated press plays the kick")
        let look = ControllerElementLook.make(.cross, layout: sectors, display: try XCTUnwrap(display.frame?.controller), simulated: stage.simulated)
        XCTAssertTrue(look.playing && look.held)
        XCTAssertFalse(ControllerElementLook.make(.circle, layout: sectors, display: try XCTUnwrap(display.frame?.controller), simulated: stage.simulated).playing)
        for (width, height) in [(900, 460), (380, 300)] {
            try render(view(editable: false), width: width, height: height, name: "played-\(width).png")
            try render(view(editable: true, mouse: false, selected: .rightStick), width: width, height: height + 260, name: "inspector-\(width).png")
        }
        stage.releaseSimulation()
        XCTAssertEqual(stage.simulated, .neutral)
    }

    /// Codex review 18.11.: pad movement redraws only the native layer; the
    /// SwiftUI stage body is not evaluated again (LIVE-NATIV contract).
    func testPadMovementRedrawsTheNativeLayerOnly() throws {
        let fixture = try MonitorRootFixture()
        defer { fixture.root.terminate {} }
        let model = fixture.root.document, stage = model.controllerStage
        XCTAssertTrue(model.setControllerLayout(ControllerAssistant.melody.applied(to: .empty, output: .midi(channel: 0))))
        let host = NSHostingView(rootView: ControllerStageView(display: fixture.root.display, instrument: model, stage: stage, editable: false))
        host.frame = .init(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let probe = ViewEvaluationProbe(); ViewEvaluationProbe.current = probe
        defer { ViewEvaluationProbe.current = nil }
        for step in 0..<20 {
            let angle = Double(step) * .pi / 10
            stage.setPosition(.rightStick, .init(x: cos(angle) * 0.9, y: sin(angle) * 0.9))
            stage.setValue(.r2, Double(step) / 20)
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        }
        stage.releaseSimulation()
        XCTAssertGreaterThan(probe.counts["controller.liveDraw"] ?? 0, 5, "the native layer follows the pad")
        XCTAssertEqual(probe.counts["controller.stageBody"] ?? 0, 0, "no SwiftUI stage rebuild per movement")
        window.contentView = nil
    }

    func testInspectorRulesKeepWhatAnAssignmentPlaysWhenMovingOutputs() {
        let strip = UUID()
        let cc = SpatialRoutingTarget.midiCC(channel: 3, controller: 11)
        XCTAssertEqual(ControllerAssignmentEditing.retarget(cc, to: .audioUnit(stripID: strip, channel: 3)), .audioUnitCC(channel: 3, controller: 11, stripID: strip))
        XCTAssertEqual(ControllerAssignmentEditing.retarget(.audioUnitNote(channel: 1, stripID: strip), to: .midi(channel: 1)), .midiNote(channel: 1))
        let made = ControllerAssignmentEditing.make(.r2, kind: .control, output: .midi(channel: 0), color: .blue)
        XCTAssertEqual(ControllerAssignmentEditing.kind(of: made), .control)
        if case .continuous = made.routing.program {} else { XCTFail("a trigger sends its travel") }
        let button = ControllerAssignmentEditing.make(.l1, kind: .control, output: .midi(channel: 0), color: .blue)
        XCTAssertEqual(button.routing.program, .constant(1), "a button switches its controller")
        XCTAssertEqual(ControllerAssignmentEditing.noteName(60), "C4")
    }

    private func render<Content: View>(_ view: Content, width: Int, height: Int, name: String) throws {
        let host = NSHostingView(rootView: view.preferredColorScheme(.dark).background(StageTheme.workspace))
        host.appearance = NSAppearance(named: .darkAqua); host.wantsLayer = true
        host.frame = .init(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.15)); host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name))
    }
}
