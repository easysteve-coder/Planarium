import Foundation
import PlanariumDomain

/// Derived from routing; never stored as a second document hierarchy.
public struct SpatialLayerGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let color: SpatialLayerColor
    public let layers: [SpatialInstrumentLayer]
    public let target: SpatialRoutingTarget?
    public let midiTarget: InstrumentMIDITarget?
    public var layerIDs: Set<UUID> { Set(layers.map(\.id)) }
    public static func groups(workspace: SpatialInstrumentWorkspace, document: InstrumentDocument) -> [Self] {
        func key(_ layer: SpatialInstrumentLayer) -> String {
            guard let target = layer.routings.first?.target else { return "none" }
            switch target {
            case .sceneSwitch, .releaseLayer, .midiAllNotesOff, .audioUnitAllNotesOff, .boolean: return "control"
            default: break
            }
            if target.destination == .audioUnit { return "au:\((target.stripID ?? SpatialRoutingTarget.missingStripID).uuidString)" }
            if target.destination == .midi { return "midi:\(String((layer.midiTarget ?? document.midiTarget)?.uniqueID ?? 0)):\(target.midiChannel ?? 0)" }
            return "control"
        }
        var keys = document.channels.map { "au:\($0.id.uuidString)" }
        for layer in workspace.layers where !keys.contains(key(layer)) { keys.append(key(layer)) }
        return keys.compactMap { id in
            let layers = workspace.layers.filter { key($0) == id }
            guard let first = layers.first else { return nil }
            let target = first.routings.first?.target
            let channel = document.channels.first { $0.id == target?.stripID }
            let midi = first.midiTarget ?? document.midiTarget
            let name: String
            if id == "none" { name = "No output" }
            else if id == "control" { name = "Control" }
            else if id.hasPrefix("au:") { name = channel?.name ?? "Unavailable AU" }
            else { name = "MIDI \(midi?.uniqueID.description ?? "Default") · Ch \(Int(target?.midiChannel ?? 0) + 1)" }
            return Self(id: id, name: name, color: channel?.color ?? first.color, layers: layers, target: target, midiTarget: midi)
        }
    }
    /// Same bulk command, projection, loss confirmation and release path as inspector edits.
    public func retarget(_ layer: inout SpatialInstrumentLayer) {
        guard let target else { layer.routings = []; return }
        let replacement: SpatialRoutingTarget
        if id == "control" { replacement = target }
        else {
            replacement = (layer.routings.first?.target ?? target)
                .retargeted(to: target.destination, stripID: target.stripID ?? SpatialRoutingTarget.missingStripID)
                .withMIDIChannel(target.destination == .midi ? target.midiChannel ?? 0 : layer.routings.first?.target.midiChannel ?? 0)
        }
        SpatialCellBulkEdit.retarget(&layer, to: replacement, fallbackProgram: layers[0].routings[0].program)
        layer.midiTarget = midiTarget
    }
}
