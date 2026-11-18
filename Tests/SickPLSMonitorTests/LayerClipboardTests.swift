import AppKit
import XCTest
import PlanariumDomain
@testable import SickPLSMonitor

@MainActor final class LayerClipboardTests: XCTestCase {
    func testNamedPasteboardTransfersLayersAndRejectsForeignOrBrokenContent() throws {
        let board = NSPasteboard(name: .init("de.sick.pls.monitor.tests.\(UUID().uuidString)"))
        let source = SpatialInstrumentLayer(name: "Lead", color: .orange,
                                            polarCells: [.init(ring: 1, angularIndex: 2)],
                                            routings: [.init(target: .midiNote(channel: 0), program: .constant(0.5))])
        LayerClipboard.copy([source], to: board)
        let copied = try XCTUnwrap(LayerClipboard.pastedLayers(from: board))
        var destination = SpatialInstrumentWorkspace(layers: [SpatialInstrumentLayer(name: "Base", color: .blue)], preserveLayerStructure: true)
        let inserted = try XCTUnwrap(destination.insertCopiedLayers(copied).first)
        let layer = try XCTUnwrap(destination.layers.first { $0.id == inserted })
        XCTAssertNotEqual(layer.id, source.id)
        XCTAssertNotEqual(layer.routings[0].id, source.routings[0].id)
        XCTAssertEqual(layer.polarCells, source.polarCells)

        board.clearContents()
        XCTAssertTrue(board.setString("foreign", forType: .string))
        XCTAssertNil(LayerClipboard.pastedLayers(from: board))
        XCTAssertTrue(board.setData(Data("broken".utf8), forType: LayerClipboard.type))
        XCTAssertNil(LayerClipboard.pastedLayers(from: board))
        XCTAssertEqual(destination.layers.count, 2)
    }

    func testContextMenuPresentsExchangeActionsAndDisablesEmptyPaste() {
        XCTAssertEqual(LayerContextMenuAction.allCases.map(\.title), ["Duplicate", "Copy", "Paste"])
        XCTAssertTrue(LayerContextMenuAction.duplicate.isEnabled(canPaste: false))
        XCTAssertTrue(LayerContextMenuAction.copy.isEnabled(canPaste: false))
        XCTAssertFalse(LayerContextMenuAction.paste.isEnabled(canPaste: false))
        XCTAssertTrue(LayerContextMenuAction.paste.isEnabled(canPaste: true))
    }

    // Native UI behavior is covered by CanvasWindowContractTests.
}
