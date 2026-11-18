import SickPLSCore

public enum SimulationLinkConstants {
    public static let bonjourServiceType = "_planarium-sim._tcp"
    public static let scannerSourceAddress: UInt8 = 0x81
    public static let silenceLimitSeconds = 2.0
    public static let openTimeoutSeconds = 5.0
}

public enum B0TelegramEncodingError: Error, Equatable, Sendable {
    case measurementOutOfRange(UInt16)
}

public enum B0TelegramEncoder {
    public static func frameBytes(
        values: [UInt16], trailingByte: UInt8 = 0
    ) throws -> [UInt8] {
        guard values.count <= 0x03FF else { throw B0TelegramEncodingError.measurementOutOfRange(UInt16.max) }
        guard let invalid = values.first(where: { $0 > B0ScanProfile.measurementValueMaximum }) else {
            var payload: [UInt8] = [
                B0ScanProfile.commandByte,
                UInt8(values.count & 0xFF),
                UInt8((values.count >> 8) & 0x03)
            ]
            payload.reserveCapacity(4 + values.count * 2)
            for value in values {
                payload.append(UInt8(value & 0xFF))
                payload.append(UInt8((value >> 8) & 0x1F))
            }
            payload.append(trailingByte)
            return try Frame.build(address: SimulationLinkConstants.scannerSourceAddress, payload: payload).encoded()
        }
        throw B0TelegramEncodingError.measurementOutOfRange(invalid)
    }
}
