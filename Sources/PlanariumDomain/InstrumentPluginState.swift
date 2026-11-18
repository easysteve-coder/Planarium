import Foundation

public enum InstrumentPluginState {
    /// AU fullState is an opaque property list. Equal property-list values
    /// can have different binary/XML encodings; unknown blobs compare exactly.
    public static func equivalent(_ lhs: Data, _ rhs: Data) -> Bool {
        if lhs == rhs { return true }
        guard let left = try? PropertyListSerialization.propertyList(from: lhs, options: [], format: nil),
              let right = try? PropertyListSerialization.propertyList(from: rhs, options: [], format: nil),
              let object = left as? NSObject else { return false }
        return object.isEqual(right)
    }
}
