import XCTest
import PlanariumDomain
@testable import PlanariumPresets

final class HarmonyScenePresetTests: XCTestCase {
    func testOldHarmony28Through30BytesRemainIdenticalExceptRetiredRoomSettingThroughProductionCodec() throws {
        for name in names {
            let url = try XCTUnwrap(Bundle.module.resourceURL?.appendingPathComponent("Fixtures/Generated/\(name).sickpreset.json"))
            let bytes = try Data(contentsOf: url)
            let value = try JSONDecoder().decode(InstrumentPresetV5.self, from: bytes)
            XCTAssertEqual(try PresetV5Codec.encode(value), try omittingLegacyRoomSetting(bytes), name)
        }
    }
    private let names = [
        "Harmony 28 Twelve-Bar Blues",
        "Harmony 29 Picardy Switch",
        "Harmony 30 Mode Wheel"
    ]

    private func document(named name: String) throws -> InstrumentDocument {
        let url = try XCTUnwrap(Bundle.module.resourceURL?
            .appendingPathComponent("Fixtures/Generated/\(name).sickpreset.json"))
        let reading = try PresetDocumentReader.read(Data(contentsOf: url)).get()
        XCTAssertEqual(reading.sourceVersion, 5)
        XCTAssertEqual(reading.name, name)
        let document = try reading.replacing(FactoryPresetDocument.empty())
        XCTAssertNoThrow(try InstrumentCompiler.compile(document), "\(name) must compile through the production path")
        return document
    }

    func testFactorySceneControlsHaveZeroDwellWhileLegacyFilesRemainReadable() throws {
        var controls = 0
        for name in FactoryPresetLibrary.standard.names {
            let reading = try PresetDocumentReader.read(XCTUnwrap(FactoryPresetLibrary.standard.data(named: name))).get()
            let document = try reading.replacing(FactoryPresetDocument.empty())
            for layer in document.spatial.layers { for routing in layer.routings {
                if case .sceneSwitch(_, let dwell) = routing.target {
                    XCTAssertEqual(dwell, 0, name)
                    controls += 1
                }
            } }
        }
        XCTAssertGreaterThan(controls, 0)
        let legacy = try document(named: names[2])
        XCTAssertTrue(legacy.spatial.layers.flatMap(\.routings).contains {
            if case .sceneSwitch(_, let dwell) = $0.target { return dwell > 0 }
            return false
        }, "The old fixture still exercises legacy nonzero values")
    }

    func testSceneWithSixActiveLayersEncodesDeterministicallyInUUIDOrder() throws {
        let ids = try (1...6).map { value in
            try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value)))
        }
        let scene = SpatialScene(id: try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111")),
                                 name: "Stable", activeLayerIDs: Set(ids.reversed()))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let first = try encoder.encode(scene)
        let second = try encoder.encode(scene)
        XCTAssertEqual(first, second)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        XCTAssertEqual(object["activeLayerIDs"] as? [String], ids.map(\.uuidString))
        XCTAssertEqual(try JSONDecoder().decode(SpatialScene.self, from: first), scene)
    }

    func testGeneratedScenePresetsImportWithTheirSceneContracts() throws {
        let expectations: [(String, [String], [Int])] = [
            (names[0], ["Major Blues", "Minor Blues"], [5, 5]),
            (names[1], ["Day", "Night"], [6, 6]),
            (names[2], ["Lydian", "Ionian", "Mixolydian", "Dorian", "Aeolian", "Phrygian"], [6, 6, 6, 6, 6, 6])
        ]
        for (name, sceneNames, activeCounts) in expectations {
            let document = try document(named: name)
            XCTAssertEqual(document.scenes.map(\.name), sceneNames, name)
            XCTAssertEqual(document.scenes.map { $0.activeLayerIDs.count }, activeCounts, name)
            XCTAssertEqual(document.currentSceneID, document.scenes.first?.id, name)

            let controlLayers = document.spatial.layers.filter { layer in
                layer.routings.contains { if case .sceneSwitch = $0.target { return true }; return false }
            }
            let controls = Set(controlLayers.map(\.id))
            let musicalLayers = document.spatial.layers.filter { !controls.contains($0.id) }
            for control in controlLayers {
                for musical in musicalLayers {
                    XCTAssertTrue(control.cells.isDisjoint(with: musical.cells),
                                  "switch \(control.name) overlaps \(musical.name) in \(name)")
                }
            }
            let controlsFromRouting = Set(document.spatial.layers.compactMap { layer in
                layer.routings.contains { if case .sceneSwitch = $0.target { return true }; return false } ? layer.id : nil
            })
            XCTAssertEqual(controls, controlsFromRouting)
            XCTAssertFalse(controls.isEmpty, name)
            for scene in document.scenes {
                XCTAssertTrue(controls.isDisjoint(with: scene.activeLayerIDs), "control layer entered \(scene.name)")
                let layers = document.spatial.layers.filter { scene.activeLayerIDs.contains($0.id) }
                var occupied = Set<PolarDeviceLattice>()
                for layer in layers {
                    XCTAssertTrue(occupied.isDisjoint(with: layer.cells), "duplicate musical cell in \(name), \(scene.name)")
                    occupied.formUnion(layer.cells)
                }
            }
            let selected = Set(document.scenes.first!.activeLayerIDs).union(controls)
            XCTAssertEqual(Set(document.spatial.layers.filter(\.isActive).map(\.id)), selected, name)
        }

        for name in Array(names.prefix(2)) {
            let document = try document(named: name)
            let g7 = try XCTUnwrap(document.spatial.layers.first { $0.name == "G7" })
            XCTAssertTrue(document.scenes.allSatisfy { $0.activeLayerIDs.contains(g7.id) }, "G7 must be shared by both scenes in \(name)")
        }
    }

    func testPicardySwitchAtNinetyPointsKeepsHeldFThenStartsFmAfterReentry() throws {
        let document = try document(named: names[1])
        let instrument = try InstrumentCompiler.compile(document)
        let f = try XCTUnwrap(document.spatial.layers.first { $0.name == "F" })
        let fm = try XCTUnwrap(document.spatial.layers.first { $0.name == "Fm" })
        let control = try XCTUnwrap(document.spatial.layers.first { layer in
            layer.routings.contains { if case .sceneSwitch = $0.target { return true }; return false }
        })
        XCTAssertEqual(f.cells, fm.cells)
        let geometry = ProfileGeometryIdentity(operatingMode: "MMK", pointCount: 90,
                                               startAngleDegrees: -90, endAngleDegrees: 90)
        func measurement(_ cell: PolarDeviceLattice) throws -> DeviceTickMeasurement {
            let order = try XCTUnwrap((0..<90).first {
                guard let span = geometry.tickSpan(at: $0) else { return false }
                return span.lower...span.upper ~= cell.sector
            })
            return try XCTUnwrap(DeviceTickMeasurement(order: order,
                ticks: try XCTUnwrap(geometry.tickSpan(at: order)), rawCentimeters: UInt16(cell.ring)))
        }
        // A 90-point sample covers several ticks. An arbitrary Set.first
        // can straddle the switch/G7 boundary and legitimately play G7 too.
        // This contract isolates held F/Fm and a single switch carrier.
        func isolatedCell(in cells: Set<PolarDeviceLattice>, expected: Set<UUID>) throws -> PolarDeviceLattice {
            try XCTUnwrap(try cells.sorted { ($0.ring, $0.sector) < ($1.ring, $1.sector) }.first { cell in
                let sample = try measurement(cell)
                return Set(instrument.hits(span: sample.ticks, raw: sample.rawCentimeters).map(\.layerID)) == expected
            })
        }
        let fCell = try isolatedCell(in: f.cells, expected: [f.id, fm.id])
        let controlCell = try isolatedCell(in: control.cells, expected: [control.id])
        let session = UUID()
        func frame(_ sequence: UInt64, _ time: Double, _ cells: [PolarDeviceLattice]) throws -> ProfileFrame {
            .init(sessionID: session, sequence: sequence, time: time,
                  measurements: try cells.map(measurement), geometry: geometry)
        }
        func ons(_ events: [MusicEvent]) -> [Int] {
            events.compactMap { if case let .noteOn(_, _, note) = $0 { return Int(note.number) }; return nil }.sorted()
        }
        func offs(_ events: [MusicEvent]) -> Int {
            events.filter { if case .noteOff = $0 { return true }; return false }.count
        }

        var state = PlayEngine.step(PlayState(), .install(instrument)).0
        state = PlayEngine.step(state, .sessionBegan(session)).0
        let soundingF = PlayEngine.step(state, .frame(try frame(1, 0, [fCell])))
        state = soundingF.0
        XCTAssertEqual(ons(soundingF.1), [57, 60, 65])

        let switched = PlayEngine.step(state, .frame(try frame(2, 0.01, [fCell, controlCell])))
        state = switched.0
        XCTAssertTrue(switched.1.contains { if case .sceneChanged(document.scenes[1].id) = $0 { return true }; return false })
        XCTAssertEqual(offs(switched.1), 0, "the held F must continue through the scene switch")
        XCTAssertTrue(ons(switched.1).isEmpty)

        let held = PlayEngine.step(state, .frame(try frame(3, 0.3, [fCell, controlCell])))
        state = held.0
        XCTAssertEqual(offs(held.1), 0)
        XCTAssertTrue(ons(held.1).isEmpty, "newly active Fm must wait for reentry")

        let left = PlayEngine.step(state, .frame(try frame(4, 0.4, [])))
        state = left.0
        XCTAssertEqual(offs(left.1), 3)
        let reentered = PlayEngine.step(state, .frame(try frame(5, 0.5, [fCell])))
        XCTAssertEqual(ons(reentered.1), [60, 65, 68])
    }

    func testMMK90BoundarySpanCanMeasureSwitchAndSharedG7Together() throws {
        let document = try document(named: names[1])
        let instrument = try InstrumentCompiler.compile(document)
        let control = try XCTUnwrap(document.spatial.layers.first { $0.name == "Previous scene" })
        let g7 = try XCTUnwrap(document.spatial.layers.first { $0.name == "G7" })
        let boundary = try XCTUnwrap(PolarDeviceLattice(ring: 150, sector: 67))
        XCTAssertTrue(control.cells.contains(boundary))
        XCTAssertFalse(g7.cells.contains(boundary))
        let geometry = ProfileGeometryIdentity(operatingMode: "MMK", pointCount: 90,
            startAngleDegrees: -90, endAngleDegrees: 90)
        let span = try XCTUnwrap((0..<90).compactMap { geometry.tickSpan(at: $0) }.first {
            $0.lower...$0.upper ~= boundary.sector
        })
        XCTAssertEqual(Set(instrument.hits(span: span, raw: UInt16(boundary.ring)).map(\.layerID)), [control.id, g7.id])
    }

    func testModeWheelRightSwitchMakesIonianBrighterAtNinetyPoints() throws {
        let document = try document(named: names[2])
        let instrument = try InstrumentCompiler.compile(document)
        let darker = try XCTUnwrap(document.spatial.layers.first { $0.name == "Darker" })
        let brighter = try XCTUnwrap(document.spatial.layers.first { $0.name == "Brighter" })
        let geometry = ProfileGeometryIdentity(operatingMode: "MMK", pointCount: 90,
                                               startAngleDegrees: -90, endAngleDegrees: 90)
        func measurement(_ cell: PolarDeviceLattice) throws -> DeviceTickMeasurement {
            let order = try XCTUnwrap((0..<90).first {
                guard let span = geometry.tickSpan(at: $0) else { return false }
                return span.lower...span.upper ~= cell.sector
            })
            return try XCTUnwrap(DeviceTickMeasurement(order: order,
                ticks: try XCTUnwrap(geometry.tickSpan(at: order)), rawCentimeters: UInt16(cell.ring)))
        }
        let session = UUID()
        func frame(_ sequence: UInt64, _ time: Double, _ cells: [PolarDeviceLattice]) throws -> ProfileFrame {
            .init(sessionID: session, sequence: sequence, time: time,
                  measurements: try cells.map(measurement), geometry: geometry)
        }
        func changed(_ events: [MusicEvent], to id: UUID) -> Bool {
            events.contains { if case .sceneChanged(id) = $0 { return true }; return false }
        }

        var state = PlayEngine.step(PlayState(), .install(instrument)).0
        state = PlayEngine.step(state, .sessionBegan(session)).0
        let ionian = PlayEngine.step(state, .frame(try frame(1, 0, [try XCTUnwrap(darker.cells.first)])))
        state = ionian.0
        XCTAssertTrue(changed(ionian.1, to: document.scenes[1].id), "left must make Lydian darker into Ionian")
        state = PlayEngine.step(state, .frame(try frame(3, 0.3, []))).0
        let lydian = PlayEngine.step(state, .frame(try frame(4, 0.4, [try XCTUnwrap(brighter.cells.first)])))
        XCTAssertTrue(changed(lydian.1, to: document.scenes[0].id), "right must make Ionian brighter into Lydian")
    }
}
