import XCTest
@testable import SickPLSCore

final class B0ScanProfileTests: XCTestCase {

    /// Baut eine B0-Payload aus einzelnen (Messwert, field_flags)-Paaren,
    /// unabhängig von der Bit-Packing-Logik in `B0ScanProfile.decode`
    /// (hier wird byteweise zusammengesetzt, nicht maskiert/geschoben wie
    /// dort), damit der Test die Entpackung tatsächlich prüft statt sich
    /// selbst zu bestätigen.
    private func makePayload(
        partialScanIndex: UInt8,
        unmodeledHeaderBits: UInt8 = 0,
        measurements: [(value: UInt16, fieldFlags: UInt8)],
        trailingBytes: [UInt8] = []
    ) -> [UInt8] {
        let n = measurements.count
        let numberOfMeasurementsHighBits = UInt8((n >> 8) & 0x03)
        let byte2 = numberOfMeasurementsHighBits
            | ((partialScanIndex & 0x03) << 3)
            | (unmodeledHeaderBits & 0b1110_0100) // Bit 2 und 5-7, nie Bit 0-1/3-4 überschreiben
        var payload: [UInt8] = [
            B0ScanProfile.commandByte,
            UInt8(n & 0xFF),
            byte2,
        ]
        for m in measurements {
            let lo = UInt8(m.value & 0xFF)
            let hi = UInt8((m.value >> 8) & 0x1F) | ((m.fieldFlags & 0x07) << 5)
            payload.append(lo)
            payload.append(hi)
        }
        payload.append(contentsOf: trailingBytes)
        return payload
    }

    // MARK: - 90 / 180 / 361 Punkte, in Tabellenlänge (mit dem real erwarteten Zusatzbyte)

    func testDecodesNinetyMeasurementsWithOneTrailingByte() {
        let measurements = (0..<90).map { i -> (value: UInt16, fieldFlags: UInt8) in
            (value: UInt16((i * 37) % 8192), fieldFlags: UInt8(i % 8))
        }
        let payload = makePayload(partialScanIndex: 0, measurements: measurements, trailingBytes: [0xAA])
        XCTAssertEqual(payload.count, 184) // Tabellenlänge b0-scan-profile.md §3

        let result = B0ScanProfile.decode(from: payload)

        guard case .success(let profile) = result else {
            XCTFail("Decodierung schlug fehl: \(result)")
            return
        }
        XCTAssertEqual(profile.measurements.count, 90)
        XCTAssertEqual(profile.partialScanIndex, 0)
        XCTAssertEqual(profile.trailingBytes, [0xAA])
        for (decoded, expected) in zip(profile.measurements, measurements) {
            XCTAssertEqual(decoded.value, expected.value)
            XCTAssertEqual(decoded.fieldFlags, expected.fieldFlags)
        }
    }

    func testDecodesOneHundredEightyMeasurementsWithOneTrailingByte() {
        let measurements = (0..<180).map { i -> (value: UInt16, fieldFlags: UInt8) in
            (value: UInt16((i * 53) % 8192), fieldFlags: UInt8((i * 3) % 8))
        }
        let payload = makePayload(partialScanIndex: 2, measurements: measurements, trailingBytes: [0x00])
        XCTAssertEqual(payload.count, 364) // Tabellenlänge b0-scan-profile.md §3

        let result = B0ScanProfile.decode(from: payload)

        guard case .success(let profile) = result else {
            XCTFail("Decodierung schlug fehl: \(result)")
            return
        }
        XCTAssertEqual(profile.measurements.count, 180)
        XCTAssertEqual(profile.partialScanIndex, 2)
        XCTAssertEqual(profile.trailingBytes, [0x00])
        for (decoded, expected) in zip(profile.measurements, measurements) {
            XCTAssertEqual(decoded.value, expected.value)
            XCTAssertEqual(decoded.fieldFlags, expected.fieldFlags)
        }
    }

    func testDecodesThreeHundredSixtyOneMeasurementsWithOneTrailingByte() {
        // 361 > 255 -- deckt zwangsläufig den Übertrag der num_measurements-
        // High-Bits aus Byte 2 (payload[2] & 0x03) mit ab.
        let measurements = (0..<361).map { i -> (value: UInt16, fieldFlags: UInt8) in
            (value: UInt16((i * 11) % 8192), fieldFlags: UInt8((i * 5) % 8))
        }
        let payload = makePayload(partialScanIndex: 3, measurements: measurements, trailingBytes: [0xFF])
        XCTAssertEqual(payload.count, 726) // Tabellenlänge b0-scan-profile.md §3

        let result = B0ScanProfile.decode(from: payload)

        guard case .success(let profile) = result else {
            XCTFail("Decodierung schlug fehl: \(result)")
            return
        }
        XCTAssertEqual(profile.measurements.count, 361)
        XCTAssertEqual(profile.partialScanIndex, 3)
        XCTAssertEqual(profile.trailingBytes, [0xFF])
        for (decoded, expected) in zip(profile.measurements, measurements) {
            XCTAssertEqual(decoded.value, expected.value)
            XCTAssertEqual(decoded.fieldFlags, expected.fieldFlags)
        }
    }

    // MARK: - Ohne Zusatzbyte (Feldstruktur-Länge weiterhin gültig, nicht nur Tabellenlänge)

    func testDecodesNinetyMeasurementsWithoutTrailingByte() {
        let measurements = (0..<90).map { i -> (value: UInt16, fieldFlags: UInt8) in
            (value: UInt16(i), fieldFlags: 0)
        }
        let payload = makePayload(partialScanIndex: 1, measurements: measurements)
        XCTAssertEqual(payload.count, 183) // exakt 3+2*90, kein Zusatzbyte

        let result = B0ScanProfile.decode(from: payload)

        guard case .success(let profile) = result else {
            XCTFail("Decodierung schlug fehl: \(result)")
            return
        }
        XCTAssertEqual(profile.measurements.count, 90)
        XCTAssertEqual(profile.trailingBytes, [], "Ohne Zusatzbyte muss trailingBytes leer bleiben")
    }

    func testDecodeAcceptsZeroMeasurementsWithoutTrailingByte() {
        let payload: [UInt8] = [B0ScanProfile.commandByte, 0x00, 0x00]

        let result = B0ScanProfile.decode(from: payload)

        guard case .success(let profile) = result else {
            XCTFail("Decodierung schlug fehl: \(result)")
            return
        }
        XCTAssertEqual(profile.measurements, [])
        XCTAssertEqual(profile.trailingBytes, [])
    }

    // MARK: - Erhalt der Trailer-Rohdaten (trailingBytes)

    func testTrailingBytesAreReturnedUnmodifiedRegardlessOfCount() {
        // Nicht auf 1 Byte hartkodiert: mehrere überzählige Bytes müssen
        // ebenso vollständig und unverändert erhalten bleiben.
        let measurements = [(value: UInt16(42), fieldFlags: UInt8(3))]
        let extra: [UInt8] = [0x01, 0x02, 0x03, 0xFE, 0xFF]
        let payload = makePayload(partialScanIndex: 0, measurements: measurements, trailingBytes: extra)

        let result = B0ScanProfile.decode(from: payload)

        XCTAssertEqual(try result.get().trailingBytes, extra)
    }

    func testTrailingBytesDoNotAffectMeasurementDecoding() {
        // Das Vorhandensein von trailingBytes darf die Messwert-Decodierung
        // nicht verändern -- gleiche Messwerte mit und ohne Zusatzbyte.
        let measurements = [(value: UInt16(0x1FFF), fieldFlags: UInt8(7))]
        let withoutTrailer = makePayload(partialScanIndex: 0, measurements: measurements)
        let withTrailer = makePayload(partialScanIndex: 0, measurements: measurements, trailingBytes: [0x77])

        let resultWithout = try! B0ScanProfile.decode(from: withoutTrailer).get()
        let resultWith = try! B0ScanProfile.decode(from: withTrailer).get()

        XCTAssertEqual(resultWithout.measurements, resultWith.measurements)
        XCTAssertEqual(resultWithout.trailingBytes, [])
        XCTAssertEqual(resultWith.trailingBytes, [0x77])
    }

    // MARK: - Erhalt der Header-Rohdaten (rawHeaderByte2)

    func testRawHeaderByte2PreservesUnmodeledBits() {
        // Bit 2 und 5-7 von Byte 2 sind laut b0-scan-profile.md §1
        // "unbelegt/unmodelliert" -- decode() darf sie weder verwerfen noch
        // fälschlich in partialScanIndex/num_measurements einfließen lassen.
        let unmodeled: UInt8 = 0b1110_0100 // exakt Bit 2 und 5-7 gesetzt
        let payload = makePayload(
            partialScanIndex: 1,
            unmodeledHeaderBits: unmodeled,
            measurements: [(value: 5, fieldFlags: 0)]
        )

        let result = B0ScanProfile.decode(from: payload)

        guard case .success(let profile) = result else {
            XCTFail("Decodierung schlug fehl: \(result)")
            return
        }
        XCTAssertEqual(profile.rawHeaderByte2, payload[2], "rawHeaderByte2 muss Byte 2 exakt und unverändert enthalten")
        XCTAssertEqual(profile.rawHeaderByte2 & 0b1110_0100, unmodeled)
        XCTAssertEqual(profile.partialScanIndex, 1, "unmodellierte Bits dürfen nicht in partialScanIndex lecken")
        XCTAssertEqual(profile.measurements.count, 1, "unmodellierte Bits dürfen nicht in num_measurements lecken")
    }

    func testMeasurementValueAndFieldFlagsBitBoundaries() {
        // lo=0xFF, hi=0x1F -> value = 0x1FFF = 8191 (Maximum, 13 Bit), flags = 0
        // lo=0x00, hi=0xE0 -> value = 0, flags = 0b111 = 7 (Maximum, 3 Bit)
        // lo=0xFF, hi=0xFF -> value = 8191, flags = 7 (beide Maxima gleichzeitig)
        let payload: [UInt8] = [
            B0ScanProfile.commandByte, 0x03, 0x00, // num_measurements = 3, partialScanIndex = 0
            0xFF, 0x1F,
            0x00, 0xE0,
            0xFF, 0xFF,
        ]

        let result = B0ScanProfile.decode(from: payload)

        guard case .success(let profile) = result else {
            XCTFail("Decodierung schlug fehl: \(result)")
            return
        }
        XCTAssertEqual(profile.measurements, [
            .init(value: 8191, fieldFlags: 0),
            .init(value: 0, fieldFlags: 7),
            .init(value: 8191, fieldFlags: 7),
        ])
    }

    func testPartialScanIndexAllFourValues() {
        for index: UInt8 in 0...3 {
            let payload = makePayload(partialScanIndex: index, measurements: [])
            let result = B0ScanProfile.decode(from: payload)
            XCTAssertEqual(try result.get().partialScanIndex, index, "partialScanIndex \(index)")
        }
    }

    // MARK: - SICK-007: informations-erhaltender Rundlauf (Payload -> decode -> repack)

    func testDecodeThenRepackRoundTripIsLossless() throws {
        // review-sick-006.md Finding N3: Verlustfreiheit war bislang nur
        // einzeln je Feld getestet (trailingBytes, rawHeaderByte2), nicht als
        // Ganzes gepinnt. `repack` ist absichtlich unabhängig von
        // `makePayload` (nutzt `rawHeaderByte2` direkt statt Einzelbits neu
        // zusammenzusetzen), damit der Test nicht sich selbst bestätigt.
        func repack(_ profile: B0ScanProfile) -> [UInt8] {
            var payload: [UInt8] = [
                B0ScanProfile.commandByte,
                UInt8(profile.measurements.count & 0xFF),
                profile.rawHeaderByte2,
            ]
            for measurement in profile.measurements {
                let lo = UInt8(measurement.value & 0xFF)
                let hi = UInt8((measurement.value >> 8) & 0x1F) | ((measurement.fieldFlags & 0x07) << 5)
                payload.append(lo)
                payload.append(hi)
            }
            payload.append(contentsOf: profile.trailingBytes)
            return payload
        }

        let measurementsA = (0..<90).map { i -> (value: UInt16, fieldFlags: UInt8) in
            (value: UInt16((i * 37) % 8192), fieldFlags: UInt8(i % 8))
        }
        let measurementsB = (0..<361).map { i -> (value: UInt16, fieldFlags: UInt8) in
            (value: UInt16((i * 11) % 8192), fieldFlags: UInt8((i * 5) % 8))
        }

        let payloads: [[UInt8]] = [
            makePayload(partialScanIndex: 0, measurements: []),
            makePayload(partialScanIndex: 0, measurements: measurementsA, trailingBytes: [0xAA]),
            makePayload(
                partialScanIndex: 3,
                unmodeledHeaderBits: 0b1110_0100,
                measurements: measurementsB,
                trailingBytes: [0x01, 0x02, 0x03]
            ),
            // Bit-Grenzwerte (13-Bit-/3-Bit-Maxima), siehe testMeasurementValueAndFieldFlagsBitBoundaries.
            [B0ScanProfile.commandByte, 0x03, 0x00, 0xFF, 0x1F, 0x00, 0xE0, 0xFF, 0xFF],
        ]

        for payload in payloads {
            let profile = try B0ScanProfile.decode(from: payload).get()
            XCTAssertEqual(repack(profile), payload, "Rundlauf payload -> decode -> repack muss bytegleich sein")
        }
    }

    // MARK: - Fehler: falscher Code

    func testDecodeRejectsEmptyPayload() {
        let result = B0ScanProfile.decode(from: [])

        XCTAssertEqual(result, .failure(.emptyPayload))
    }

    func testDecodeRejectsWrongCommandByte() {
        let payload: [UInt8] = [0xB1, 0x00, 0x00]

        let result = B0ScanProfile.decode(from: payload)

        XCTAssertEqual(result, .failure(.unexpectedCommandByte(0xB1)))
    }

    // MARK: - Fehler: zu kurze Payloads

    func testDecodeRejectsPayloadWithOnlyCommandByte() {
        let result = B0ScanProfile.decode(from: [B0ScanProfile.commandByte])

        XCTAssertEqual(result, .failure(.payloadTooShortForHeader(available: 1, required: 3)))
    }

    func testDecodeRejectsPayloadTooShortForHeader() {
        let payload: [UInt8] = [B0ScanProfile.commandByte, 0x05] // nur 2 von 3 Header-Byte

        let result = B0ScanProfile.decode(from: payload)

        XCTAssertEqual(result, .failure(.payloadTooShortForHeader(available: 2, required: 3)))
    }

    func testDecodeRejectsPayloadTooShortForMeasurements() {
        // Header behauptet 2 Messpunkte (4 Byte), Payload liefert nur 1 Byte davon.
        let payload: [UInt8] = [B0ScanProfile.commandByte, 0x02, 0x00, 0xAA]

        let result = B0ScanProfile.decode(from: payload)

        XCTAssertEqual(
            result,
            .failure(.payloadTooShortForMeasurements(numberOfMeasurements: 2, required: 7, available: 4))
        )
    }

    func testDecodeRejectsPayloadOneByteShortOfMeasurementsEvenWithoutTrailer() {
        // Grenzfall: genau 1 Byte fehlt am Ende des letzten Messpunkts --
        // das bleibt ein harter Fehler, auch nach der Lockerung für
        // überzählige (nicht: fehlende) Bytes.
        let full = makePayload(partialScanIndex: 0, measurements: [(value: 1, fieldFlags: 0)])
        let oneShort = Array(full.dropLast())

        let result = B0ScanProfile.decode(from: oneShort)

        XCTAssertEqual(
            result,
            .failure(.payloadTooShortForMeasurements(numberOfMeasurements: 1, required: 5, available: 4))
        )
    }

    // MARK: - SICK-008: öffentliche, validierende Konstruktion für synthetische Profile

    func testMeasurementBuildAcceptsBoundaryValues() throws {
        let measurement = try B0ScanProfile.Measurement.build(value: 8191, fieldFlags: 7)

        XCTAssertEqual(measurement.value, 8191)
        XCTAssertEqual(measurement.fieldFlags, 7)
    }

    func testMeasurementExposesDocumentedCentimetersAndMetersWithoutCalibration() throws {
        let zero = try B0ScanProfile.Measurement.build(value: 0, fieldFlags: 0)
        let oneCentimeter = try B0ScanProfile.Measurement.build(value: 1, fieldFlags: 0)
        let oneMeter = try B0ScanProfile.Measurement.build(value: 100, fieldFlags: 0)
        let realCaptureExample = try B0ScanProfile.Measurement.build(value: 925, fieldFlags: 6)

        XCTAssertEqual(zero.distanceCentimeters, 0)
        XCTAssertEqual(zero.distanceMeters, 0, accuracy: 0)
        XCTAssertEqual(oneCentimeter.distanceCentimeters, 1)
        XCTAssertEqual(oneCentimeter.distanceMeters, 0.01, accuracy: 1e-12)
        XCTAssertEqual(oneMeter.distanceCentimeters, 100)
        XCTAssertEqual(oneMeter.distanceMeters, 1.0, accuracy: 0)
        XCTAssertEqual(realCaptureExample.distanceCentimeters, 925)
        XCTAssertEqual(realCaptureExample.distanceMeters, 9.25, accuracy: 1e-12)
        XCTAssertEqual(realCaptureExample.value, 925, "Die neue Einheit darf den Drahtwert nicht verändern")
        XCTAssertEqual(realCaptureExample.fieldFlags, 6)
    }

    func testMeasurementBuildRejectsValueAboveThirteenBits() {
        XCTAssertThrowsError(try B0ScanProfile.Measurement.build(value: 8192, fieldFlags: 0)) { error in
            XCTAssertEqual(
                error as? B0ScanProfile.Measurement.BuildError,
                .valueExceedsThirteenBits(8192)
            )
        }
    }

    func testMeasurementBuildRejectsFieldFlagsAboveThreeBits() {
        XCTAssertThrowsError(try B0ScanProfile.Measurement.build(value: 0, fieldFlags: 8)) { error in
            XCTAssertEqual(
                error as? B0ScanProfile.Measurement.BuildError,
                .fieldFlagsExceedThreeBits(8)
            )
        }
    }

    func testBuildProducesProfileEquivalentToDecodingTheSameLogicalContent() throws {
        // Kein synthetisches Profil darf sich von einem regulär decodierten
        // unterscheiden, das denselben logischen Inhalt beschreibt --
        // sonst wäre `build` eine zweite, abweichende Quelle der Wahrheit.
        let measurements = try (0..<10).map { i in
            try B0ScanProfile.Measurement.build(value: UInt16((i * 37) % 8192), fieldFlags: UInt8(i % 8))
        }

        let built = try B0ScanProfile.build(partialScanIndex: 2, measurements: measurements, trailingBytes: [0xAA])

        let payload = makePayload(
            partialScanIndex: 2,
            measurements: measurements.map { (value: $0.value, fieldFlags: $0.fieldFlags) },
            trailingBytes: [0xAA]
        )
        let decoded = try B0ScanProfile.decode(from: payload).get()

        XCTAssertEqual(built, decoded)
    }

    func testBuildDefaultsToEmptyTrailingBytes() throws {
        let profile = try B0ScanProfile.build(partialScanIndex: 0, measurements: [])

        XCTAssertEqual(profile.trailingBytes, [])
    }

    func testBuildRejectsPartialScanIndexAboveTwoBits() {
        XCTAssertThrowsError(try B0ScanProfile.build(partialScanIndex: 4, measurements: [])) { error in
            XCTAssertEqual(
                error as? B0ScanProfile.BuildError,
                .partialScanIndexExceedsTwoBits(4)
            )
        }
    }

    func testBuildRejectsMeasurementCountAboveTransportableRange() throws {
        let oneTooMany = try (0..<1024).map { _ in try B0ScanProfile.Measurement.build(value: 0, fieldFlags: 0) }

        XCTAssertThrowsError(try B0ScanProfile.build(partialScanIndex: 0, measurements: oneTooMany)) { error in
            XCTAssertEqual(
                error as? B0ScanProfile.BuildError,
                .measurementCountExceedsTransportableRange(1024)
            )
        }
    }

    func testBuildAcceptsMaximumTransportableMeasurementCount() throws {
        let maximum = try (0..<1023).map { _ in try B0ScanProfile.Measurement.build(value: 0, fieldFlags: 0) }

        let profile = try B0ScanProfile.build(partialScanIndex: 1, measurements: maximum)

        XCTAssertEqual(profile.measurements.count, 1023)
        XCTAssertEqual(profile.partialScanIndex, 1)
    }
}
