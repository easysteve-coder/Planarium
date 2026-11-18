import XCTest
@testable import SickPLSCore

/// Testvektoren, unabhängig von `SickCRC16` berechnet: mit einem separaten
/// Python-Port von `SickPLSMessage::_computeCRC` (BSD SickToolbox, siehe
/// Quellenverweis in `CRC16.swift`), nicht aus der Swift-Implementierung
/// selbst abgeleitet. So deckt ein Übersetzungsfehler in `SickCRC16` diese
/// Tests auf, statt sich selbst zu bestätigen.
final class SickCRC16Tests: XCTestCase {
    func testEmptyInputReturnsZero() {
        XCTAssertEqual(SickCRC16.compute([]), 0x0000)
    }

    func testHeaderOnlyAddressZeroLengthZero() {
        let bytes: [UInt8] = [0x02, 0x00, 0x00, 0x00]
        XCTAssertEqual(SickCRC16.compute(bytes), 0x0810)
    }

    func testStatusRequestAddressZeroSingleBytePayload() {
        let bytes: [UInt8] = [0x02, 0x00, 0x01, 0x00, 0x31]
        XCTAssertEqual(SickCRC16.compute(bytes), 0x1215)
    }

    func testAddressOneFourBytePayload() {
        let bytes: [UInt8] = [0x02, 0x01, 0x04, 0x00, 0xDE, 0xAD, 0xBE, 0xEF]
        XCTAssertEqual(SickCRC16.compute(bytes), 0xF818)
    }

    func testAddressZeroEightBytesAllOnesPayload() {
        let bytes: [UInt8] = [0x02, 0x00, 0x08, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        XCTAssertEqual(SickCRC16.compute(bytes), 0x00AA)
    }

    /// Die vier Vektoren oben setzen Bit 15 von `crc` nie, durchlaufen also
    /// nie den Polynomzweig (`crc ^= 0x8005`) -- eine falsche
    /// Polynomkonstante würde von ihnen kaum entlarvt (Revisor-Review
    /// SICK-003, Finding N4, Mutationsprobe: nur 2 von 5 Vektoren trennscharf
    /// gegen ein falsches Polynom). Dieser lange, wechselhafte 812-Byte-Vektor
    /// (deterministisch erzeugt, `(i * 167 + 13) % 256`) durchläuft den
    /// Polynomzweig wiederholt und deckt zugleich die maximale Payload-Länge ab.
    func testLongVariedPayloadExercisesPolynomialBranch() {
        let payload = (0..<SickPLSFrameConstants.payloadMaxLength).map { UInt8(($0 * 167 + 13) % 256) }
        let bytes: [UInt8] = [0x02, 0x81, 0x2C, 0x03] + payload // Länge 812 = 0x032C, Little-Endian

        XCTAssertEqual(SickCRC16.compute(bytes), 0x8BF8)
    }
}
