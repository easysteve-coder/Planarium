import AppKit
import XCTest
@testable import SickPLSMonitor

final class CanvasArchitectureRulesTests: XCTestCase {
    func testOneInputSeamAndNoNestedHistoryOrSnapshotRollback() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent("Sources/" + path)) }
        for path in ["SickPLSMonitor/CartesianScanFieldView.swift", "SickPLSMonitor/DeviceFieldEditorView.swift"] {
            XCTAssertFalse(try source(path).contains("DragGesture("), path)
        }
        XCTAssertFalse(try source("SickPLSMonitor/ScanFieldPointerEvents.swift").contains("addLocalMonitorForEvents"))
        for path in ["SickPLSMonitorKit/MetricCanvasInteractionState.swift", "SickPLSMonitorKit/CanvasOwners.swift"] {
            XCTAssertFalse(try source(path).contains("undoStack"), path)
        }
        for path in ["SickPLSMonitor/SpatialLayerInspectorView.swift", "SickPLSMonitor/CellInspectorView.swift", "PlanariumApplication/SpatialInstrumentRuntimeModel.swift"] {
            let text = try source(path)
            XCTAssertFalse(text.contains("preservingView"), path)
            XCTAssertFalse(text.contains("canvas = oldValue"), path)
            XCTAssertFalse(text.contains("@Published public var canvas"), path)
            XCTAssertFalse(text.contains("Binding<MetricCanvasInteractionState>"), path)
        }
    }

    @MainActor func testPictogramAssetsExistAndApplesAvailabilityMapAllowsMacOS12() throws {
        let symbols = ["cursorarrow", "paintbrush.pointed", "delete.left", "hand.raised", "square.grid.2x2", "waveform", "flag",
            "slider.horizontal.3", "circle.grid.3x3", "house", "square.stack.3d.up", "square.dashed", "pencil.and.outline", "eye",
            "arrow.clockwise", "square.and.arrow.down", "square.and.arrow.up", "trash", "pencil", "info.circle", "arrow.uturn.backward",
            "speaker.slash", "headphones", "speaker.wave.2", "plus", "pianokeys", "exclamationmark.octagon.fill", "xmark",
            "doc.on.doc", "checkmark", "play.fill", "stop.fill", "waveform.path.ecg", "circle.lefthalf.fill", "rectangle",
            "minus.magnifyingglass", "plus.magnifyingglass", "scope", "record.circle", "stop.circle", "arrow.down.right.and.arrow.up.left",
            "arrow.up.and.down", "arrow.left.and.right", "arrow.up.left.and.arrow.down.right", "arrow.up.and.down.and.arrow.left.and.right", "hand.raised.fill"]
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Apple symbol-availability resource unavailable on this host") }
        let data = try Data(contentsOf: url)
        let dictionary = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let names = try XCTUnwrap(dictionary["symbols"] as? [String: String])
        let releases = try XCTUnwrap(dictionary["year_to_release"] as? [String: [String: String]])
        for symbol in symbols {
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol)
            let year = try XCTUnwrap(names[symbol], symbol)
            let version = try XCTUnwrap(releases[year]?["macOS"], symbol)
            XCTAssertLessThanOrEqual(Double(version) ?? .infinity, 12, "\(symbol) requires macOS \(version)")
        }
    }
}
