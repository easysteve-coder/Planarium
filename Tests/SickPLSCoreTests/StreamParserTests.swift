import XCTest
@testable import SickPLSCore

final class StreamParserTests: XCTestCase {

    func testDeliversSingleFrameFedAsOneChunk() throws {
        var parser = StreamParser()
        let frame = try Frame.build(address: 0x81, payload: [0x31])

        let delivered = parser.feed(frame.encoded())

        XCTAssertEqual(delivered, [frame])
    }

    func testDeliversMultipleBackToBackFramesOfDifferentLengths() throws {
        // fixtures-and-testing.md §6/§8: mehrere Frames back-to-back,
        // unterschiedliche Längen, alle unabhängig voneinander erkannt.
        var parser = StreamParser()
        let first = try Frame.build(address: 0x81, payload: [])
        let second = try Frame.build(address: 0x81, payload: [0x31])
        let third = try Frame.build(address: 0x81, payload: [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11])

        let delivered = parser.feed(first.encoded() + second.encoded() + third.encoded())

        XCTAssertEqual(delivered, [first, second, third])
    }

    func testResultIsIndependentOfChunkSize() throws {
        // fixtures-and-testing.md §8: gleiches Ergebnis unabhängig von der
        // Chunk-Größe der Eingabe -- hier im Extremfall 1 Byte pro Aufruf.
        let first = try Frame.build(address: 0x00, payload: [0x31])
        let second = try Frame.build(address: 0x81, payload: [0xDE, 0xAD, 0xBE, 0xEF])
        let noise: [UInt8] = [0xAA, 0x00, 0x02, 0xFF] // enthält ein irreführendes 0x02
        let stream = noise + first.encoded() + second.encoded()

        var wholeChunkParser = StreamParser()
        let deliveredWhole = wholeChunkParser.feed(stream)

        var byteByByteParser = StreamParser()
        var deliveredByteByByte: [Frame] = []
        for byte in stream {
            deliveredByteByByte.append(contentsOf: byteByByteParser.feed([byte]))
        }

        XCTAssertEqual(deliveredWhole, [first, second])
        XCTAssertEqual(deliveredByteByByte, deliveredWhole)
    }

    func testSkipsNoiseBeforeFrameWithoutExternalError() throws {
        var parser = StreamParser()
        let frame = try Frame.build(address: 0x00, payload: [0x31])
        let noise: [UInt8] = [0x00, 0x01, 0xFF, 0xFE, 0x00]

        let delivered = parser.feed(noise + frame.encoded())

        XCTAssertEqual(delivered, [frame])
    }

    func testDiscardsInvalidCandidateByteWiseNotFrameWise() throws {
        // Konstruiert nach wire-protocol.md §5a: ein CRC-ungültiger Kandidat
        // A deklariert eine Länge, deren "Payload" tatsächlich den validen
        // Frame B enthält (B beginnt 4 Byte nach As STX, innerhalb der von A
        // deklarierten Framelänge). Eine (falsche) frameweise
        // Fehlerrückgewinnung würde beim Verwerfen von A die kompletten 11
        // Byte überspringen und B damit verlieren. Byteweises Verwerfen
        // (nur das führende STX von A) findet B trotzdem.
        var parser = StreamParser()
        let b = try Frame.build(address: 0x00, payload: [0x31])
        XCTAssertEqual(b.encoded(), [0x02, 0x00, 0x01, 0x00, 0x31, 0x15, 0x12])

        let corruptedCandidateAHeader: [UInt8] = [0x02, 0xFF, 0x05, 0x00] // STX, Adr, Länge=5 (LE)
        let buffer = corruptedCandidateAHeader + b.encoded()
        // buffer = 02 FF 05 00 | 02 00 01 00 31 15 12 (A "verschluckt" B als eigene Payload+Trailer)

        let delivered = parser.feed(buffer)

        XCTAssertEqual(delivered, [b])
    }

    func testAdditionalNoiseBetweenFramesDoesNotBreakSubsequentFraming() throws {
        var parser = StreamParser()
        let first = try Frame.build(address: 0x00, payload: [0x31])
        let second = try Frame.build(address: 0x00, payload: [0x31])
        // Vollständiger, aber ungültiger STX-Kandidat: Länge 0xFFFF (>812)
        // wird sofort verworfen (nicht: unvollständig -> Warten).
        let noise: [UInt8] = [0x02, 0xAB, 0xFF, 0xFF]

        let delivered = parser.feed(first.encoded() + noise + second.encoded())

        XCTAssertEqual(delivered, [first, second])
    }

    func testFeedAcrossMultipleCallsAssemblesFrameSplitMidHeaderAndMidPayload() throws {
        var parser = StreamParser()
        let frame = try Frame.build(address: 0x81, payload: [0x01, 0x02, 0x03, 0x04, 0x05])
        let bytes = frame.encoded()

        let firstChunk = Array(bytes[0..<2])   // mitten im Header
        let secondChunk = Array(bytes[2..<6])  // Rest Header + Teil Payload
        let thirdChunk = Array(bytes[6...])    // Rest Payload + Trailer

        XCTAssertEqual(parser.feed(firstChunk), [])
        XCTAssertEqual(parser.feed(secondChunk), [])
        XCTAssertEqual(parser.feed(thirdChunk), [frame])
    }

    func testEmptyFeedReturnsNoFrames() {
        var parser = StreamParser()

        XCTAssertEqual(parser.feed([UInt8]()), [])
    }

    func testBufferStaysBoundedByMaximumFrameLengthAcrossNoise() {
        // Beweis der in StreamParser.swift dokumentierten Invariante: nach
        // jedem feed(_:) ist der Puffer entweder leer oder kürzer als
        // SickPLSFrameConstants.maxFrameLength (818) -- unabhängig davon, wie
        // viel Rauschen zuvor ankam.
        var parser = StreamParser()
        let denseNoise = (0..<50_000).map { UInt8(($0 * 37 + 5) % 256) } // enthält viele zufällige 0x02-Bytes

        _ = parser.feed(denseNoise)

        XCTAssertLessThan(parser.bufferedByteCount, SickPLSFrameConstants.maxFrameLength)
    }

    // MARK: - SICK-007: finish() (Batch-Semantik-Abschluss)

    func testFinishFlushesIncompleteTrailingCandidateUsingBatchSemantics() throws {
        // Arbeitsbeispiel aus review-sick-004.md Finding M1: ein STX-Byte,
        // das sich erst rückwirkend als Rauschen herausstellt (Länge 0x0081
        // passt nicht mehr in den Rest des Streams), gefolgt vom
        // eigentlichen, vollständigen Frame (Adresse 0x81, leere Payload).
        var parser = StreamParser()
        let stream: [UInt8] = [0x02, 0x02, 0x81, 0x00, 0x00, 0x11, 0x88]

        let fedFrames = parser.feed(stream)
        XCTAssertEqual(fedFrames, [], "feed() allein darf den unvollständigen Kandidaten nicht ausliefern")

        let expected = try Frame.build(address: 0x81, payload: [])
        let finishedFrames = parser.finish()

        XCTAssertEqual(finishedFrames, [expected])
        XCTAssertEqual(parser.diagnostics.discardedCandidatesAtFinish, 1)
        XCTAssertEqual(parser.diagnostics.validFrames, 1)
    }

    func testFinishOnEmptyBufferReturnsNoFrames() {
        var parser = StreamParser()

        XCTAssertEqual(parser.finish(), [])
        XCTAssertEqual(parser.diagnostics, StreamParser.Diagnostics())
    }

    func testFinishLeavesBufferEmpty() {
        var parser = StreamParser()
        _ = parser.feed([0x02, 0x81, 0x00]) // unvollständiger Header, kann nie vollständig werden

        _ = parser.finish()

        XCTAssertEqual(parser.bufferedByteCount, 0)
    }

    func testFinishIsIdempotentOnAlreadyDrainedParser() throws {
        var parser = StreamParser()
        let frame = try Frame.build(address: 0x81, payload: [0x31])
        _ = parser.feed(frame.encoded())

        XCTAssertEqual(parser.finish(), [])
        XCTAssertEqual(parser.finish(), [], "ein zweiter finish()-Aufruf auf bereits leerem Puffer liefert nichts Neues")
    }

    func testResultIsIndependentOfChunkSizeAcrossMatrixWithFinish() throws {
        // fixtures-and-testing.md §8, erweitert um finish(): dieselbe
        // Bytefolge -- inklusive eines am Ende absichtlich unvollständigen
        // Kandidaten -- muss über verschiedene Chunk-Größen hinweg exakt
        // dasselbe Ergebnis liefern, sobald finish() den Abschluss markiert.
        let noiseA: [UInt8] = [0xAA, 0x00, 0xFE]
        let first = try Frame.build(address: 0x00, payload: [0x31])
        let noiseB: [UInt8] = [0x00, 0xFF] // kein STX enthalten
        let second = try Frame.build(address: 0x81, payload: [0xDE, 0xAD, 0xBE, 0xEF])
        let incompleteTail: [UInt8] = [0x02, 0x81, 0x00] // unvollständiger Header (3 von 4 Byte)

        let stream = noiseA + first.encoded() + noiseB + second.encoded() + incompleteTail

        var referenceParser = StreamParser()
        var reference = referenceParser.feed(stream)
        reference.append(contentsOf: referenceParser.finish())
        XCTAssertEqual(reference, [first, second])

        for chunkSize in [1, 2, 3, 5, 7, 11, stream.count] {
            var parser = StreamParser()
            var delivered: [Frame] = []
            var index = stream.startIndex
            while index < stream.endIndex {
                let end = min(index + chunkSize, stream.endIndex)
                delivered.append(contentsOf: parser.feed(stream[index..<end]))
                XCTAssertLessThan(
                    parser.bufferedByteCount,
                    SickPLSFrameConstants.maxFrameLength,
                    "Chunkgröße \(chunkSize): Pufferinvariante nach diesem feed()-Aufruf verletzt"
                )
                index = end
            }
            delivered.append(contentsOf: parser.finish())

            XCTAssertEqual(delivered, reference, "Chunkgröße \(chunkSize) liefert ein abweichendes Ergebnis")
        }
    }

    // MARK: - SICK-007: maximaler Frame (812 Byte Payload)

    func testHandlesMaximumSizeFrameFedAsOneChunk() throws {
        let payload = (0..<SickPLSFrameConstants.payloadMaxLength).map { UInt8(($0 * 71 + 3) % 256) }
        let frame = try Frame.build(address: 0x81, payload: payload)
        XCTAssertEqual(frame.encoded().count, SickPLSFrameConstants.maxFrameLength)

        var parser = StreamParser()
        let noise: [UInt8] = [0x00, 0xFF, 0xFE] // kein STX enthalten

        let delivered = parser.feed(noise + frame.encoded())

        XCTAssertEqual(delivered, [frame])
        XCTAssertEqual(parser.diagnostics.validFrames, 1)
        XCTAssertEqual(parser.diagnostics.skippedNoiseBytes, noise.count)
    }

    func testHandlesMaximumSizeFrameSplitAcrossMultipleFeedCalls() throws {
        let payload = (0..<SickPLSFrameConstants.payloadMaxLength).map { UInt8(($0 * 197 + 11) % 256) }
        let frame = try Frame.build(address: 0x02, payload: payload)
        let bytes = frame.encoded()

        var parser = StreamParser()
        let firstChunk = Array(bytes[0..<2])           // mitten im Header
        let secondChunk = Array(bytes[2..<400])         // Rest Header + Teil Payload
        let thirdChunk = Array(bytes[400...])           // Rest Payload + Trailer

        XCTAssertEqual(parser.feed(firstChunk), [])
        XCTAssertEqual(parser.feed(secondChunk), [])
        XCTAssertEqual(parser.feed(thirdChunk), [frame])
        XCTAssertEqual(parser.diagnostics.validFrames, 1)
    }

    // MARK: - SICK-007: Diagnosezähler

    func testDiagnosticsStartAtZero() {
        let parser = StreamParser()

        XCTAssertEqual(parser.diagnostics, StreamParser.Diagnostics())
    }

    func testDiagnosticsAccumulateAcrossMultipleFeedAndFinishCallsWithoutResetting() throws {
        var parser = StreamParser()

        // 1) Reines Rauschen, kein STX enthalten.
        _ = parser.feed([0x00, 0x01, 0xFF, 0xFE, 0x00])
        XCTAssertEqual(parser.diagnostics.skippedNoiseBytes, 5)
        XCTAssertEqual(parser.diagnostics.validFrames, 0)

        // 2) Ein valider Frame.
        let first = try Frame.build(address: 0x00, payload: [0x31])
        XCTAssertEqual(parser.feed(first.encoded()), [first])
        XCTAssertEqual(parser.diagnostics.validFrames, 1)

        // 3) Ein überlanger Kandidat (Länge 0xFFFF > 812), danach 3 Rauschbytes.
        _ = parser.feed([0x02, 0xAB, 0xFF, 0xFF])
        XCTAssertEqual(parser.diagnostics.discardedCandidatesOversize, 1)
        XCTAssertEqual(parser.diagnostics.skippedNoiseBytes, 5 + 3)

        // 4) Ein CRC-ungültiger Kandidat, der einen validen Frame "verschluckt"
        //    (Konstruktion wie testDiscardsInvalidCandidateByteWiseNotFrameWise).
        let second = try Frame.build(address: 0x00, payload: [0x31])
        XCTAssertEqual(second.encoded(), [0x02, 0x00, 0x01, 0x00, 0x31, 0x15, 0x12])
        let corruptedHeader: [UInt8] = [0x02, 0xFF, 0x05, 0x00]
        XCTAssertEqual(parser.feed(corruptedHeader + second.encoded()), [second])
        XCTAssertEqual(parser.diagnostics.discardedCandidatesChecksumMismatch, 1)
        XCTAssertEqual(parser.diagnostics.skippedNoiseBytes, 5 + 3 + 3)
        XCTAssertEqual(parser.diagnostics.validFrames, 2)

        // 5) Ein am Ende unvollständiger Kandidat: bei feed() unverändert,
        //    erst bei finish() als "discardedCandidatesAtFinish" gezählt.
        _ = parser.feed([0x02, 0x81, 0x00, 0x00])
        XCTAssertEqual(parser.diagnostics.discardedCandidatesAtFinish, 0)
        XCTAssertEqual(parser.finish(), [])
        XCTAssertEqual(parser.diagnostics.discardedCandidatesAtFinish, 1)

        // Zähler bleiben über einen weiteren finish()-Aufruf hinweg erhalten
        // (keine Rücksetzautomatik) -- der Puffer ist jetzt leer, es ändert
        // sich also nichts mehr.
        XCTAssertEqual(parser.finish(), [])
        XCTAssertEqual(parser.diagnostics.discardedCandidatesAtFinish, 1)
        XCTAssertEqual(parser.diagnostics.validFrames, 2)
    }

    // MARK: - SICK-008: Summenzähler, öffentliche Diagnostics-Konstruktion, Byte-Bilanz

    func testDiscardedCandidatesIsSumOfAllThreeSubCounters() throws {
        var parser = StreamParser()
        _ = parser.feed([0x02, 0xAB, 0xFF, 0xFF]) // Oversize-Kandidat (Länge 0xFFFF > 812)

        let frame = try Frame.build(address: 0x00, payload: [0x31])
        let corruptedHeader: [UInt8] = [0x02, 0xFF, 0x05, 0x00]
        _ = parser.feed(corruptedHeader + frame.encoded()) // CRC-Fehler + validen Frame verschluckt

        _ = parser.feed([0x02, 0x81, 0x00, 0x00]) // am Ende unvollständig
        _ = parser.finish()

        XCTAssertEqual(parser.diagnostics.discardedCandidatesOversize, 1)
        XCTAssertEqual(parser.diagnostics.discardedCandidatesChecksumMismatch, 1)
        XCTAssertEqual(parser.diagnostics.discardedCandidatesAtFinish, 1)
        XCTAssertEqual(parser.diagnostics.discardedCandidates, 3, "discardedCandidates muss die Summe aller drei Ursachen sein")
    }

    func testDiagnosticsPublicInitIsUsableOutsideModuleAndEquatable() {
        // Revisor-Review SICK-007, Finding N2: ohne öffentlichen Init war
        // StreamParser.Diagnostics() außerhalb des Moduls nicht konstruierbar.
        let fresh = StreamParser.Diagnostics()

        XCTAssertEqual(fresh, StreamParser().diagnostics)
        XCTAssertEqual(fresh.discardedCandidates, 0)
    }

    func testByteBalanceInvariantHoldsAcrossNoiseValidAndInvalidCandidatesAndFinish() throws {
        // Revisor-Review SICK-007, Finding N3: jedes zugeführte Byte muss
        // genau einen Verbleib haben -- eine echte Erhaltungsgröße:
        //   skippedNoiseBytes + Summe(ausgelieferte Framebytes)
        //     + discardedCandidates + Restpuffer == zugeführte Bytes
        var parser = StreamParser()
        var totalBytesFed = 0
        var delivered: [Frame] = []

        func feed(_ bytes: [UInt8]) {
            totalBytesFed += bytes.count
            delivered.append(contentsOf: parser.feed(bytes))
        }

        feed([0x00, 0x01, 0xFF, 0xFE, 0x00]) // reines Rauschen, kein STX

        let first = try Frame.build(address: 0x00, payload: [0x31])
        feed(first.encoded())

        feed([0x02, 0xAB, 0xFF, 0xFF]) // überlanger Kandidat, danach 3 Rauschbytes

        let second = try Frame.build(address: 0x00, payload: [0x31])
        let corruptedHeader: [UInt8] = [0x02, 0xFF, 0x05, 0x00]
        feed(corruptedHeader + second.encoded()) // CRC-Fehler verschluckt validen Frame

        feed([0x02, 0x81, 0x00, 0x00]) // am Ende unvollständiger Kandidat
        delivered.append(contentsOf: parser.finish())

        let deliveredFrameBytes = delivered.reduce(0) { $0 + $1.encoded().count }
        let accountedFor =
            parser.diagnostics.skippedNoiseBytes
            + deliveredFrameBytes
            + parser.diagnostics.discardedCandidates
            + parser.bufferedByteCount

        XCTAssertEqual(delivered, [first, second])
        XCTAssertEqual(accountedFor, totalBytesFed, "jedes zugeführte Byte muss genau einen Verbleib haben")
    }
}
