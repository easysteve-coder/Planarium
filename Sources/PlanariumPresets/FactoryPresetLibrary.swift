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
