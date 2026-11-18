import AppKit
import Foundation
import SwiftUI
import PlanariumDomain
import PlanariumApplication

enum LayerClipboard {
    static let type = NSPasteboard.PasteboardType("de.sick.pls.monitor.layers")
    static func copy(_ layers: [SpatialInstrumentLayer], to pasteboard: NSPasteboard = .general) {
        guard let data = try? JSONEncoder().encode(layers) else { return }
        pasteboard.clearContents()
        _ = pasteboard.setData(data, forType: type)
    }
    static func pastedLayers(from pasteboard: NSPasteboard = .general) -> [SpatialInstrumentLayer]? {
        guard let data = pasteboard.data(forType: type), let layers = try? JSONDecoder().decode([SpatialInstrumentLayer].self, from: data), !layers.isEmpty else { return nil }
        return layers
    }
}

enum LayerContextMenuAction: CaseIterable {
    case duplicate, copy, paste

    var title: String {
        switch self {
        case .duplicate: return "Duplicate"
        case .copy: return "Copy"
        case .paste: return "Paste"
        }
    }

    func isEnabled(canPaste: Bool) -> Bool {
        self != .paste || canPaste
    }
}

struct DuplicateLayerAction: Equatable {
    let owner: SpatialInstrumentRuntimeModel
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.owner === rhs.owner }
    @MainActor func callAsFunction() { owner.duplicateLayer() }
}
private struct DuplicateLayerKey: FocusedValueKey { typealias Value = DuplicateLayerAction }
extension FocusedValues {
    var duplicateLayer: DuplicateLayerAction? {
        get { self[DuplicateLayerKey.self] }
        set { self[DuplicateLayerKey.self] = newValue }
    }
}
