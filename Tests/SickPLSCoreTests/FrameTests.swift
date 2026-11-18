import XCTest
@testable import SickPLSCore

final class FrameTests: XCTestCase {

    // MARK: - Roundtrip

    func testRoundTripEncodingAndDecodingPreservesAddressAndPayload() throws {
        let original = try Frame.build(address: 0x81, payload: [0x01, 0x02, 0x03, 0xFF])

        let result = Frame.decodeExact(from: original.encoded())

        switch result {
        case .success(let decoded):
            XCTAssertEqual(decoded, original)
        case .failure(let error):
            XCTFail("Roundtrip schlug fehl: \(error)")
        }
    }

    func testRoundTripWithEmptyPayload() throws {
        let original = try Frame.build(address: 0x00, payload: [])

        let result = Frame.decodeExact(from: original.encoded())

        XCTAssertEqual(try result.get(), original)
    }

    func testRoundTripWithMaximumPayloadLength() throws {
        let payload = [UInt8](repeating: 0x5A, count: SickPLSFrameConstants.payloadMaxLength)
        let original = try Frame.build(address: 0x00, payload: payload)

        let result = Frame.decodeExact(from: original.encoded())

        XCTAssertEqual(try result.get(), original)
    }

    // MARK: - Little-Endian

    func testEncodedLengthFieldIsLittleEndian() throws {
        // 0x0104 = 260 Byte Payload -> Längenfeld muss [0x04, 0x01] sein, nicht [0x01, 0x04].
        let payload = [UInt8](repeating: 0x00, count: 0x0104)
        let frame = try Frame.build(address: 0x00, payload: payload)

        let bytes = frame.encoded()

        XCTAssertEqual(bytes[2], 0x04, "Low-Byte des Längenfelds zuerst")
        XCTAssertEqual(bytes[3], 0x01, "High-Byte des Längenfelds zuletzt")
    }

    func testEncodedChecksumTrailerIsLittleEndian() {
        // Bekannter Vektor aus SickCRC16Tests: addr=0x01, payload=DE AD BE EF -> crc=0xF818.
        let frame = try! Frame.build(address: 0x01, payload: [0xDE, 0xAD, 0xBE, 0xEF])

        let bytes = frame.encoded()

        XCTAssertEqual(bytes[bytes.count - 2], 0x18, "Low-Byte des CRC zuerst")
        XCTAssertEqual(bytes[bytes.count - 1], 0xF8, "High-Byte des CRC zuletzt")
    }

    func testKnownFullFrameEncoding() {
        // addr=0x00, payload=[0x31] -> vollständiger Frame, unabhängig via Python-Port berechnet.
        let frame = try! Frame.build(address: 0x00, payload: [0x31])

        XCTAssertEqual(frame.encoded(), [0x02, 0x00, 0x01, 0x00, 0x31, 0x15, 0x12])
    }

    func testDecodeReadsLengthFieldAsLittleEndianNotBigEndian() {
        // Längenfeld 0x0104 (260) als [0x04, 0x01] geschrieben. Eine
        // fälschlich Big-Endian lesende Decodierung würde 0x0401 (1025)
        // erwarten und den Frame als unvollständig statt als vollständig
        // erkennen -- explizit benannter Gegentest zu Finding N5(b).
        let payload = [UInt8](repeating: 0x00, count: 0x0104)
        let frame = try! Frame.build(address: 0x00, payload: payload)

        let result = Frame.decodeExact(from: frame.encoded())

        XCTAssertEqual(try result.get(), frame)
    }

    // MARK: - Falsches STX

    func testDecodeRejectsWrongStartByte() {
        let bytes: [UInt8] = [0x03, 0x00, 0x01, 0x00, 0x31, 0x15, 0x12]

        let result = Frame.decodeExact(from: bytes)

        XCTAssertEqual(result, .failure(.invalidStartByte(0x03)))
    }

    func testDecodeRejectsEmptyBuffer() {
        let result = Frame.decodeExact(from: [UInt8]())

        XCTAssertEqual(result, .failure(.incompleteHeader(available: 0, required: SickPLSFrameConstants.headerLength)))
    }

    // MARK: - Unvollständig

    func testDecodeRejectsIncompleteHeader() {
        let bytes: [UInt8] = [0x02, 0x00, 0x01] // nur 3 von 4 Header-Byte

        let result = Frame.decodeExact(from: bytes)

        XCTAssertEqual(result, .failure(.incompleteHeader(available: 3, required: SickPLSFrameConstants.headerLength)))
    }

    func testDecodeRejectsIncompletePayloadAndTrailer() {
        // Header sagt 1 Byte Payload an, Puffer endet aber direkt danach (kein Trailer).
        let bytes: [UInt8] = [0x02, 0x00, 0x01, 0x00, 0x31]

        let result = Frame.decodeExact(from: bytes)

        XCTAssertEqual(result, .failure(.incompleteFrame(available: 5, required: 7)))
    }

    // MARK: - Längenfehler / > 812

    func testDecodeRejectsPayloadLengthAboveMaximum() {
        let length = UInt16(SickPLSFrameConstants.payloadMaxLength + 1) // 813
        let bytes: [UInt8] = [0x02, 0x00, UInt8(length & 0xFF), UInt8((length >> 8) & 0xFF)]

        let result = Frame.decodeExact(from: bytes)

        XCTAssertEqual(result, .failure(.payloadLengthExceedsMaximum(length)))
    }

    func testDecodeAcceptsPayloadLengthAtMaximum() throws {
        let payload = [UInt8](repeating: 0x00, count: SickPLSFrameConstants.payloadMaxLength)
        let frame = try Frame.build(address: 0x00, payload: payload)

        let result = Frame.decodeExact(from: frame.encoded())

        XCTAssertEqual(try result.get(), frame)
    }

    func testBuildRejectsPayloadAboveMaximum() {
        let payload = [UInt8](repeating: 0x00, count: SickPLSFrameConstants.payloadMaxLength + 1)

        XCTAssertThrowsError(try Frame.build(address: 0x00, payload: payload)) { error in
            XCTAssertEqual(error as? Frame.BuildError, .payloadTooLarge(SickPLSFrameConstants.payloadMaxLength + 1))
        }
    }

    // MARK: - CRC-Fehler

    func testDecodeRejectsChecksumMismatchInTrailer() throws {
        let frame = try Frame.build(address: 0x00, payload: [0x31])
        var bytes = frame.encoded()
        bytes[bytes.count - 1] ^= 0xFF // Trailer verfälschen, Struktur bleibt gültig

        let result = Frame.decodeExact(from: bytes)

        // Konkrete Werte geprüft, nicht nur Ungleichheit -- ein vertauschtes
        // received/computed-Labelpaar (Finding N1) würde sonst unbemerkt
        // bleiben (Finding N5a).
        XCTAssertEqual(result, .failure(.checksumMismatch(received: 0x1215 ^ 0xFF00, computed: 0x1215)))
    }

    func testDecodeRejectsChecksumMismatchFromCorruptedPayloadByte() throws {
        // Fixtures-and-testing.md §6 nennt als Kontraktfall ausdrücklich
        // "kaputte CRC" durch einen verfälschten Payload-Wert bei
        // unverändertem Trailer (fixtures-and-testing.md Referenztest
        // `test_corrupted_payload_is_rejected`), nicht nur einen verfälschten
        // Trailer (Finding N5b).
        let frame = try Frame.build(address: 0x00, payload: [0x31])
        var bytes = frame.encoded()
        bytes[4] ^= 0xFF // Payload-Byte verfälschen, Trailer bleibt unangetastet

        let result = Frame.decodeExact(from: bytes)

        // Unabhängig via Python-Port nachgerechnet (0x31 XOR 0xFF = 0xCE als
        // Payload-Byte -> CRC über 02 00 01 00 CE).
        XCTAssertEqual(result, .failure(.checksumMismatch(received: 0x1215, computed: 0x12EA)))
    }

    // MARK: - Prefix vs. Exact

    func testDecodePrefixIgnoresTrailingBytesAfterCompleteFrame() throws {
        let frame = try Frame.build(address: 0x00, payload: [0x31])
        let bytes = frame.encoded() + [0x02, 0x00, 0x00, 0x00]

        let result = Frame.decodePrefix(from: bytes)

        switch result {
        case .success(let decoded):
            XCTAssertEqual(decoded.frame, frame)
            XCTAssertEqual(decoded.consumedBytes, frame.encoded().count)
        case .failure(let error):
            XCTFail("decodePrefix schlug fehl: \(error)")
        }
    }

    func testDecodeExactRejectsTrailingBytesAfterCompleteFrame() throws {
        let frame = try Frame.build(address: 0x00, payload: [0x31])
        let bytes = frame.encoded() + [0x02, 0x00, 0x00, 0x00]

        let result = Frame.decodeExact(from: bytes)

        XCTAssertEqual(result, .failure(.trailingBytes(consumed: frame.encoded().count, total: bytes.count)))
    }

    func testDecodePrefixReportsConsumedBytesForMultiFrameBuffer() throws {
        let first = try Frame.build(address: 0x00, payload: [0x31])
        let second = try Frame.build(address: 0x01, payload: [0xDE, 0xAD, 0xBE, 0xEF])
        let bytes = first.encoded() + second.encoded()

        let firstResult = Frame.decodePrefix(from: bytes)
        guard case .success(let firstDecoded) = firstResult else {
            XCTFail("Erster Frame nicht decodiert: \(firstResult)")
            return
        }
        XCTAssertEqual(firstDecoded.frame, first)
        XCTAssertEqual(firstDecoded.consumedBytes, first.encoded().count)

        let remaining = Array(bytes[firstDecoded.consumedBytes...])
        let secondResult = Frame.decodeExact(from: remaining)
        XCTAssertEqual(try secondResult.get(), second)
    }

    func testDecodePrefixWorksOnArraySliceWithoutCopy() throws {
        // Belegt die Collection/Slice-Generik aus Finding M3: ein
        // ArraySlice mit nicht-nullbasiertem Index muss funktionieren.
        let frame = try Frame.build(address: 0x81, payload: [0x01, 0x02, 0x03])
        let padded = [0xAA, 0xBB] + frame.encoded()
        let slice = padded[2...] // startIndex == 2, kein Kopieren

        let result = Frame.decodePrefix(from: slice)

        XCTAssertEqual(try result.get().frame, frame)
    }

    // MARK: - Build-Invariante (N2)

    func testBuildAtExactlyMaximumPayloadLengthSucceeds() throws {
        let payload = [UInt8](repeating: 0x00, count: SickPLSFrameConstants.payloadMaxLength)

        XCTAssertNoThrow(try Frame.build(address: 0x00, payload: payload))
    }
}
