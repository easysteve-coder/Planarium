/// Frameworkfreie Beschreibung eines schreibbaren Parameters einer bereits
/// geladenen Audio Unit. `address` ist autoritativ, `identifier` dient der
/// sichtbaren Versionsprüfung und darf nie still auf eine andere Adresse
/// umgedeutet werden.
public struct AudioUnitParameterDescriptor: Equatable, Hashable, Sendable {
    public let componentType: UInt32
    public let componentSubType: UInt32
    public let componentManufacturer: UInt32
    public let address: UInt64
    public let identifier: String
    public let displayName: String
    public let minimumValue: Float
    public let maximumValue: Float
    public let unitName: String?

    public init(
        componentType: UInt32, componentSubType: UInt32, componentManufacturer: UInt32,
        address: UInt64, identifier: String, displayName: String,
        minimumValue: Float, maximumValue: Float, unitName: String?
    ) {
        self.componentType = componentType
        self.componentSubType = componentSubType
        self.componentManufacturer = componentManufacturer
        self.address = address
        self.identifier = identifier
        self.displayName = displayName
        self.minimumValue = minimumValue
        self.maximumValue = maximumValue
        self.unitName = unitName
    }
}
