import XCTest
@testable import SickPLSMonitorKit

final class MacOSPaket3aTests: XCTestCase {
    @MainActor func testDraggedValueMathStaysWithinMainFrameBudget() {
        let steps = 100_000
        var value = 0.5
        let start = DispatchTime.now().uptimeNanoseconds
        for index in 0..<steps {
            value = FaderMath.dragged(startValue: value, translationY: Double((index % 7) - 3), travel: 165)
        }
        let nanosecondsPerStep = (DispatchTime.now().uptimeNanoseconds - start) / UInt64(steps)
        XCTAssertLessThan(nanosecondsPerStep, 50_000, "Fader math must leave a 60 Hz main-frame budget for drawing")
        print("FADER-MAIN math=\(nanosecondsPerStep)ns/step samples=\(steps) final=\(value)")
    }

    func testDraggingStartsAtTheGrabbedValueWithoutJump() {
        XCTAssertEqual(FaderMath.dragged(startValue: 0.5, translationY: 0, travel: 100), 0.5, accuracy: 1e-12)
        XCTAssertEqual(FaderMath.dragged(startValue: 0.5, translationY: -20, travel: 100), 0.7, accuracy: 1e-12)
        XCTAssertEqual(FaderMath.dragged(startValue: 0.5, translationY: 100, travel: 100), 0, accuracy: 1e-12)
        XCTAssertEqual(FaderMath.dragged(startValue: 0.9, translationY: -50, travel: 100), 1, accuracy: 1e-12)
        XCTAssertEqual(FaderMath.dragged(startValue: 0.4, translationY: 10, travel: 0), 0.4, accuracy: 1e-12)
    }

    func testKeyboardAndAccessibilityStepsAreClamped() {
        XCTAssertEqual(FaderMath.stepped(0.5, up: true), 0.55, accuracy: 1e-12)
        XCTAssertEqual(FaderMath.stepped(0.5, up: false), 0.45, accuracy: 1e-12)
        XCTAssertEqual(FaderMath.stepped(0.98, up: true), 1, accuracy: 1e-12)
        XCTAssertEqual(FaderMath.stepped(0.02, up: false), 0, accuracy: 1e-12)
    }

    func testFaderAndEvidenceExportUseTheAccessibleAndVisiblePaths() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let surface = try String(
            contentsOf: root.appendingPathComponent("Sources/SickPLSMonitor/HelmutChannelSurface.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(surface.contains("FaderMath.dragged("))
        let session = try String(contentsOf: root.appendingPathComponent("Sources/SickPLSMonitor/StageTheme.swift"), encoding: .utf8)
        XCTAssertTrue(surface.contains("let clamped = max(0, min(1, drag.displayed ?? value))"), "The cap follows the immediate local draft")
        XCTAssertTrue(surface.contains("FaderLaw.decibelLabel(forPosition: drag.displayed ?? value)"), "VoiceOver must report the same draft as the visible cap")
        let displayed = try XCTUnwrap(session.range(of: "displayed = value\n        guard live"))
        let pending = try XCTUnwrap(session.range(of: "pending = Task { @MainActor"))
        XCTAssertLessThan(displayed.lowerBound, pending.lowerBound, "Publish the visible draft before scheduling output coalescing")
        XCTAssertTrue(session.contains("self.pending = nil; self.flush()"))
        XCTAssertTrue(session.contains("pending?.cancel(); pending = nil; flush(); clear()"), "Release flushes the last draft before clearing it")
        XCTAssertTrue(surface.contains("accessibilityAdjustableAction"))
        XCTAssertTrue(surface.contains("onMoveCommand"))
        XCTAssertFalse(surface.contains("1 - Double(drag.location.y / geometry.size.height)"))

        let evidence = try String(
            contentsOf: root.appendingPathComponent("Sources/SickPLSMonitor/ConnectionEvidenceView.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(evidence.contains("try? model.evidenceExportText().write"))
        XCTAssertTrue(evidence.contains("saveError = \"Could not save the evidence report."))
    }
}
