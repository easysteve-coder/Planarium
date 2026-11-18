import Foundation
import PlanariumDomain

/// Factory files take the same v1–v6 reader as owner files.
public struct FactoryPresetLibrary: Sendable {
    private let files: [String: Data]
    public init(presets: [InstrumentPresetV6]) throws {
        precondition(Set(presets.map(\.name)).count == presets.count)
        files = try Dictionary(uniqueKeysWithValues: presets.map { ($0.name, try PresetDocumentWriter.encode($0)) })
    }
    private init(files: [String: Data]) { self.files = files }
    public var names: [String] { files.keys.sorted() }
    public func data(named name: String) -> Data? { files[name] }
    public static let empty = FactoryPresetLibrary(files: [:])
    public static let standard: FactoryPresetLibrary = {
        let directory = Bundle.module.resourceURL!.appendingPathComponent("Resources")
        let urls = try! FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let pairs = urls.filter { $0.lastPathComponent.hasSuffix(".sickpreset.json") }.map { url -> (String, Data) in
            let data = try! Data(contentsOf: url)
            return (url.lastPathComponent.replacingOccurrences(of: ".sickpreset.json", with: ""), data)
        }
        return FactoryPresetLibrary(files: Dictionary(uniqueKeysWithValues: pairs))
    }()
}

/// Fixed seed for generated factory channels, independent of a workstation.
public enum FactoryPresetDocument {
    public static func empty() throws -> InstrumentDocument {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let layer = SpatialDocumentLayer(id: id, name: "Layer", color: .blue,
            isVisible: true, isActive: true, isLocked: false, isSoloed: false,
            cells: [], routings: [], cellOverrides: [:])
        return InstrumentDocument(spatial: try .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: id),
            channel: .init(instrument: .init(identity: .init(componentType: 0x61756D75,
                componentSubType: 0x646C7320, componentManufacturer: 0x6170706C))),
            revision: .init(session: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, counter: 0))
    }
}

/// The first game-controller preset: it plays at once on Apple's built-in
/// instrument (always present), so a pad is musical within a minute.
/// Drums on the symbol buttons and R1 (General MIDI channel 10), a melody on the
/// right stick with filter on R2 and sustain on L1, and the chords I–V–vi–IV
/// on the d-pad. Identifiers are fixed, so the resource is regenerated
/// byte-identically from the blank factory channel.
extension FactoryPresetDocument {
    public static let controllerFirstNotesName = "Factory 02 Controller First Notes"

    public static func controllerFirstNotes(from blank: InstrumentDocument) throws -> InstrumentDocument {
        guard let strip = blank.channels.first?.id else { throw ChannelPresetCodec.Failure.invalid }
        let instrument = ControllerAssistantOutput.audioUnit(stripID: strip, channel: 0)
        var layout = ControllerAssistant.drums.applied(to: .init(), output: .audioUnit(stripID: strip, channel: 9))
        layout = ControllerAssistant.melody.applied(to: layout, output: instrument, rootMIDINote: 60)
        let dpad: [ControllerElement: ControllerElement] = [.cross: .dpadDown, .circle: .dpadRight, .square: .dpadLeft, .triangle: .dpadUp]
        let chords = ControllerAssistant.chords.assignments(output: instrument, rootMIDINote: 48).map { chord -> ControllerAssignment in
            var moved = chord; moved.element = dpad[chord.element] ?? chord.element; return moved
        }
        layout.assignments += chords
        for index in layout.assignments.indices {
            layout.assignments[index].id = fixedID(0xC000 + index)
            layout.assignments[index].routing.id = fixedID(0xC100 + index)
        }
        var document = blank
        document.controller = layout
        return document
    }

    private static func fixedID(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", value))!
    }
}
