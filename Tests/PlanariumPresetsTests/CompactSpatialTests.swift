import XCTest
import Foundation
import PlanariumDomain
import SickPLSControlCore
@testable import PlanariumPresets

final class CompactSpatialTests: XCTestCase {
    func testAUControlTargetsAndExplicitProgramOriginRoundTripWithoutMIDIOutput() throws {
        let strip = UUID(), cell = PolarDeviceLattice(ring: 100, sector: 180)!
        let targets: [SpatialRoutingTarget] = [.audioUnitCC(channel: 15, controller: 11, stripID: strip),
            .audioUnitProgramChange(channel: 15, stripID: strip), .audioUnitPitchBend(channel: 15, stripID: strip),
            .audioUnitChannelPressure(channel: 15, stripID: strip)]
        for target in targets {
            let program = SpatialProgramChange(program: 2, countsFromOne: false, bankMSB: 3, bankLSB: 4)
            let layer = SpatialDocumentLayer(id: UUID(), name: "AU control", color: .blue, isVisible: true,
                isActive: true, isLocked: false, isSoloed: false, cells: [cell],
                routings: [.init(target: target, program: target.isProgramChange ? .programChange(program) : .constant(0.75))],
                cellOverrides: [cell: [.init(target: target, value: target.isProgramChange ? .programChange(program) : .scalar(0.25))]])
            let document = InstrumentDocument(spatial: try .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id), revision: .init(session: UUID(), counter: 1), channels: [.init(id: strip)])
            let bytes = try PresetV6Codec.encode(.init(name: "AU controls", document: document))
            let decoded = try PresetDocumentReader.read(bytes).get().replacing(document)
            XCTAssertEqual(decoded, document)
            XCTAssertEqual(try PresetV6Codec.encode(.init(name: "AU controls", document: decoded)), bytes)
            XCTAssertEqual(target.retargeted(to: .midi, stripID: strip).retargeted(to: .audioUnit, stripID: strip), target)
            XCTAssertFalse(SpatialInstrumentWorkspace(layers: [.init(name: "AU", color: .blue,
                routings: layer.routings)]).requiresMIDIOutput)
        }
    }

    func testInvalidOverlappingAndAmbiguousRangesRejectWithoutEchoingInventedMarker() throws {
        let bytes = try PresetV5Codec.encode(.init(name: "Invalid ranges", document: v5Document()))
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let invalid: [Any] = [ [[0, 0, 2], [0, 2, 3]], [[0, 3, 2]], [[8191, 0, 1]], [[0, 0, 361]], [[0, 0]], [[0, 0, 1, 2]], [["INVENTED-BC-RANGE-MARKER", 0, 1]] ]
        for value in invalid {
            var root = original
            var document = root["document"] as! [String: Any]
            var spatial = document["spatial"] as! [String: Any]
            var layers = spatial["layers"] as! [[String: Any]]
            layers[0]["cells"] = value
            spatial["layers"] = layers; document["spatial"] = spatial; root["document"] = document
            guard case .failure(let error) = PresetDocumentReader.read(try JSONSerialization.data(withJSONObject: root)) else {
                XCTFail("Malformed range accepted"); continue
            }
            XCTAssertFalse(String(describing: error).contains("INVENTED-BC-RANGE-MARKER"))
        }
        var root = original
        var document = root["document"] as! [String: Any]
        var spatial = document["spatial"] as! [String: Any]
        var layers = spatial["layers"] as! [[String: Any]]
        layers[0]["cellOverrides"] = [["cell": ["ring": 0, "sector": 0], "range": [0, 0, 1], "actions": []]]
        spatial["layers"] = layers; document["spatial"] = spatial; root["document"] = document
        if case .success = PresetDocumentReader.read(try JSONSerialization.data(withJSONObject: root)) { XCTFail("Ambiguous override accepted") }
    }
    func testCanonicalMergedRangesAndLosslessBoundaryRoundTrip() throws {
        var doc = try v5Document()
        let source = doc.spatial.layers[0]
        let cells = Set([0, 8190].flatMap { ring in [0, 1, 2, 5, 359, 360].map { PolarDeviceLattice(ring: ring, sector: $0)! } })
        let actions = [SpatialCellAction(target: .audioUnitNote(channel: 0, stripID: InstrumentChannel.legacyID), value: .note(number: 60, velocity: 90))]
        let layer = SpatialDocumentLayer(id: source.id, name: source.name, color: source.color,
            isVisible: true, isActive: true, isLocked: false, isSoloed: false,
            cells: cells, routings: source.routings, cellOverrides: Dictionary(uniqueKeysWithValues: cells.map { ($0, actions) }))
        doc.spatial = try .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id)
        let bytes = try PresetV5Codec.encode(.init(name: "Ranges", document: doc))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let spatial = try XCTUnwrap((root["document"] as? [String: Any])?["spatial"] as? [String: Any])
        let wire = try XCTUnwrap((spatial["layers"] as? [[String: Any]])?.first)
        XCTAssertEqual(wire["cells"] as? [[Int]], [[0,0,2],[0,5,5],[0,359,360],[8190,0,2],[8190,5,5],[8190,359,360]])
        XCTAssertEqual((wire["cellOverrides"] as? [[String: Any]])?.count, 6)
        let reading = try PresetDocumentReader.read(bytes).get()
        XCTAssertEqual(try PresetV5Codec.decode(bytes).document, doc, "Frozen V5 decoder remains lossless")
        XCTAssertEqual(try reading.replacing(doc), try LegacyChannelMigration.applying(to: doc))
        let migrated = try PresetV6Codec.encode(.init(name: "Ranges", document: reading.replacing(doc)))
        XCTAssertEqual(try PresetV6Codec.encode(.init(name: "Ranges", document: PresetDocumentReader.read(migrated).get().replacing(doc))), migrated)
    }

    func testSeededSparseSetsAndExpandedV5Import() throws {
        var seed: UInt64 = 781
        for iteration in 0..<25 {
            var doc = try v5Document()
            let old = doc.spatial.layers[0]
            var cells = Set<PolarDeviceLattice>()
            for _ in 0..<250 {
                seed = seed &* 6364136223846793005 &+ 1
                cells.insert(PolarDeviceLattice(ring: Int(seed % 8191), sector: Int((seed >> 32) % 361))!)
            }
            let layer = SpatialDocumentLayer(id: old.id, name: old.name, color: old.color, isVisible: true,
                isActive: true, isLocked: false, isSoloed: false, cells: cells, routings: old.routings,
                cellOverrides: old.cellOverrides)
            doc.spatial = try .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: old.id)
            var root = try XCTUnwrap(JSONSerialization.jsonObject(with: PresetV5Codec.encode(.init(name: "Random", document: doc))) as? [String: Any])
            var value = root["document"] as! [String: Any]
            var spatial = value["spatial"] as! [String: Any]
            var layers = spatial["layers"] as! [[String: Any]]
            layers[0]["cells"] = cells.map { ["ring": $0.ring, "sector": $0.sector] }
            layers[0]["cellOverrides"] = old.cellOverrides.map { ["cell": ["ring": $0.key.ring, "sector": $0.key.sector], "actions": try! JSONSerialization.jsonObject(with: JSONEncoder().encode($0.value))] }
            spatial["layers"] = layers; value["spatial"] = spatial; root["document"] = value
            let reading = try PresetDocumentReader.read(JSONSerialization.data(withJSONObject: root)).get()
            let expected = try LegacyChannelMigration.applying(to: doc)
            XCTAssertEqual(try reading.replacing(doc), expected, "iteration \(iteration)")
            let compact = try PresetV6Codec.encode(.init(name: "Random", document: reading.replacing(doc)))
            XCTAssertEqual(try PresetDocumentReader.read(compact).get().replacing(doc), expected)
            XCTAssertEqual(try PresetV6Codec.encode(.init(name: "Random", document: PresetDocumentReader.read(compact).get().replacing(doc))), compact)
        }
    }
}
