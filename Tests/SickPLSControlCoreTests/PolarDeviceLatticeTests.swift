import XCTest
import Foundation
@testable import SickPLSControlCore

final class PolarDeviceLatticeTests: XCTestCase {
    func testEveryRingHasEveryTickIncludingNearScanner() {
        for ring in [1, 10, 56, 57, PolarDeviceLattice.maxRing] {
            XCTAssertEqual(PolarDeviceLattice.sectorCount(forRing: ring), 361)
            let cells = (0...PolarDeviceLattice.maxTick).compactMap {
                PolarDeviceLattice(ring: ring, sector: $0)
            }
            XCTAssertEqual(cells.count, 361)
            XCTAssertEqual(Set(cells.map(\.sector)).count, 361)
        }
    }

    func testTick359And360RemainDistinct() {
        let before = PolarDeviceLattice(tick: 359, rawCentimeters: 56)
        let end = PolarDeviceLattice(tick: 360, rawCentimeters: 56)
        XCTAssertNotEqual(before?.sector, end?.sector)
        XCTAssertEqual(before?.sector, 359)
        XCTAssertEqual(end?.sector, 360)
    }

    func testRawValueIsTheOneCentimeterRing() {
        XCTAssertNil(PolarDeviceLattice.ring(forRawCentimeters: 0))
        XCTAssertEqual(PolarDeviceLattice.ring(forRawCentimeters: 1), 1)
        XCTAssertEqual(PolarDeviceLattice.ring(forRawCentimeters: 8190), 8190)
        XCTAssertNotEqual(
            PolarDeviceLattice(tick: 180, rawCentimeters: 100)?.ring,
            PolarDeviceLattice(tick: 180, rawCentimeters: 101)?.ring
        )
    }

    func testBoundaryAndInvalidAddresses() {
        XCTAssertNotNil(PolarDeviceLattice(ring: 0, sector: 0))
        XCTAssertNotNil(PolarDeviceLattice(ring: 0, sector: 360))
        XCTAssertNotNil(PolarDeviceLattice(ring: PolarDeviceLattice.maxRing, sector: 360))
        XCTAssertNil(PolarDeviceLattice(ring: -1, sector: 0))
        XCTAssertNil(PolarDeviceLattice(ring: PolarDeviceLattice.maxRing + 1, sector: 0))
        XCTAssertNil(PolarDeviceLattice(ring: 0, sector: 361))
        XCTAssertNil(PolarDeviceLattice(tick: -1, rawCentimeters: 100))
        XCTAssertNil(PolarDeviceLattice(tick: 361, rawCentimeters: 100))
        XCTAssertNil(PolarDeviceLattice(tick: 180, rawCentimeters: 0))
        XCTAssertNil(PolarDeviceLattice(tick: 180, rawCentimeters: 8191))
    }

    func testSectorIsExactlyTheTickAtEveryRing() {
        for ring in 0...PolarDeviceLattice.maxRing {
            for tick in [0, 1, 179, 180, 359, 360] {
                XCTAssertEqual(PolarDeviceLattice.sector(forTick: tick, inRing: ring), tick)
            }
        }
    }

    func testCodableRoundTripsV2BoundaryCells() throws {
        let cells = [
            try XCTUnwrap(PolarDeviceLattice(ring: 0, sector: 360)),
            try XCTUnwrap(PolarDeviceLattice(ring: 56, sector: 359)),
            try XCTUnwrap(PolarDeviceLattice(ring: PolarDeviceLattice.maxRing, sector: 360))
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for cell in cells {
            let data = try encoder.encode(cell)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(Set(object.keys), ["ring", "sector"])
            XCTAssertEqual(try decoder.decode(PolarDeviceLattice.self, from: data), cell)
        }
    }

    func testCodableRejectsEveryInvalidRingSectorPair() throws {
        let decoder = JSONDecoder()
        let invalidPairs = [
            (ring: 0, sector: 361),
            (ring: -1, sector: 0),
            (ring: PolarDeviceLattice.maxRing + 1, sector: 0)
        ]

        for pair in invalidPairs {
            let data = Data("{\"ring\":\(pair.ring),\"sector\":\(pair.sector)}".utf8)
            do {
                _ = try decoder.decode(PolarDeviceLattice.self, from: data)
                XCTFail("Ungültige V2-Adresse wurde dekodiert: \(pair)")
            } catch let error as DecodingError {
                guard case .dataCorrupted = error else {
                    return XCTFail("Erwartet dataCorrupted für \(pair), erhalten: \(error)")
                }
            }
        }
    }

    func testCodableRejectsMissingSectorAndStringRing() throws {
        let decoder = JSONDecoder()

        do {
            _ = try decoder.decode(PolarDeviceLattice.self, from: Data(#"{"ring":1}"#.utf8))
            XCTFail("Fehlendes sector wurde dekodiert")
        } catch let error as DecodingError {
            guard case .keyNotFound(let key, _) = error else {
                return XCTFail("Erwartet keyNotFound(sector), erhalten: \(error)")
            }
            XCTAssertEqual(key.stringValue, "sector")
        }

        do {
            _ = try decoder.decode(
                PolarDeviceLattice.self,
                from: Data(#"{"ring":"1","sector":0}"#.utf8)
            )
            XCTFail("String-ring wurde dekodiert")
        } catch let error as DecodingError {
            guard case .typeMismatch(let type, _) = error else {
                return XCTFail("Erwartet typeMismatch(Int), erhalten: \(error)")
            }
            XCTAssertEqual(String(reflecting: type), "Swift.Int")
        }
    }
}
