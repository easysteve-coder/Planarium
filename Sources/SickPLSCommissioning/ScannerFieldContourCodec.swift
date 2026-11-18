import PLSDeviceValues

/// Pure payload codec next to CommissioningTelegram. No transport, sender,
/// address, read command, field identity or commit contract is implied.
public enum ScannerFieldContourCodec {
    public enum CodecError: Error, Equatable, Sendable {
        case missingHeader
        case unexpectedCommand(UInt8)
        case unknownSegmentCode(UInt8)
        case wrongLength(expected: Int, actual: Int)
        case unsupportedWireSegmentCount(Int)
    }
    public static func decode(_ payload: [UInt8]) throws -> ScannerFieldContour {
        guard payload.count >= 2 else { throw CodecError.missingHeader }
        guard payload[0] == 0x43 else { throw CodecError.unexpectedCommand(payload[0]) }
        let segments: ScannerFieldContour.SegmentCount
        switch payload[1] {
        case 0x5A: segments = .ninety
        case 0xFE: segments = .threeSixty
        default: throw CodecError.unknownSegmentCode(payload[1])
        }
        let expected = 2 + 2 * (segments.rawValue + 1)
        guard payload.count == expected else { throw CodecError.wrongLength(expected: expected, actual: payload.count) }
        var radii: [UInt16] = [], status: [UInt8] = []
        for index in 0...segments.rawValue {
            let word = UInt16(payload[2 + index * 2]) | UInt16(payload[3 + index * 2]) << 8
            radii.append(word & 0x1FFF); status.append(UInt8(word >> 13))
        }
        return try .build(segments: segments, radiiCentimeters: radii, statusBits: status)
    }
    public static func encode(_ contour: ScannerFieldContour) throws -> [UInt8] {
        let code: UInt8
        switch contour.segments {
        case .ninety: code = 0x5A
        case .threeSixty: code = 0xFE
        case .oneEighty: throw CodecError.unsupportedWireSegmentCount(180)
        }
        var bytes: [UInt8] = [0x43, code]
        for index in contour.radiiCentimeters.indices {
            let word = contour.radiiCentimeters[index] | UInt16(contour.statusBits[index]) << 13
            bytes.append(UInt8(word & 0xFF)); bytes.append(UInt8(word >> 8))
        }
        return bytes
    }
}
