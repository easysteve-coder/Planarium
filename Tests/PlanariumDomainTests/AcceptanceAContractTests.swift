import XCTest
import SickPLSCore
@testable import PlanariumDomain

final class AcceptanceAContractTests: XCTestCase {
    func testRoomContourRestlessBeamStatusUsesPerBeamScatterRatherThanWorstGlobalSpread() {
        let geometry = SpatialRoomContour.Geometry(pointCount: 3, angleResolutionDegrees: 1, startAngleDegrees: -1, sourceIdentifier: "test")
        let steady = SpatialRoomContour(geometry: geometry, nearestDistancesCentimeters: [100, 100, 100], spreadCentimeters: [16, 0, 15])
        XCTAssertEqual(steady.restlessBeamIndexes, [])
        XCTAssertEqual(steady.restlessBeamCount, 0)
        let one = SpatialRoomContour(geometry: geometry, nearestDistancesCentimeters: [100, 100, 100], spreadCentimeters: [17, 0, 15])
        XCTAssertEqual(one.restlessBeamIndexes, [0])
        XCTAssertEqual(one.restlessBeamCount, 1)
        let several = SpatialRoomContour(geometry: geometry, nearestDistancesCentimeters: [100, 100, 100], spreadCentimeters: [17, 19, 0])
        XCTAssertEqual(several.restlessBeamIndexes, [0, 1])
    }
    private let session = UUID()
    private func frame(_ count: Int, _ samples: [Int: UInt16], sequence: UInt64 = 1) throws -> ProfileFrame {
        let raw = try B0ScanProfile.build(partialScanIndex: 0, measurements: (0..<count).map {
            try .build(value: samples[$0] ?? 8191, fieldFlags: 0)
        })
        return .init(sessionID: session, sequence: sequence, time: Double(sequence) / 25,
            measurements: try FullScanProfileAdapter.measurements(from: raw),
            geometry: try FullScanProfileAdapter.geometry(from: raw), rawProfile: raw)
    }
    private func instrument(_ count: Int, _ samples: [Int: UInt16], angle: Int = 20,
                            transition: SpatialNoteTransition = .legato) throws -> CompiledInstrument {
        let geometry = try frame(count, samples).geometry
        let layers = samples.sorted { $0.key < $1.key }.enumerated().map { offset, pair in
            let ticks = geometry.tickSpan(at: pair.key)!
            let cell = PolarDeviceLattice(ring: Int(pair.value), sector: ticks.lower)!
            let route = SpatialRouting(id: UUID(), target: .midiNote(channel: UInt8(offset)),
                program: .chord(notes: [60 + offset], velocity: 100, transition: transition))
            return SpatialDocumentLayer(id: UUID(), name: "Hand", color: .blue, isVisible: true,
                isActive: true, isLocked: false, isSoloed: false, cells: [cell], routings: [route], cellOverrides: [:])
        }
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(DetectionConfiguration())) as? [String: Any])
        json["minimumAngleDegrees"] = angle
        let config = try JSONDecoder().decode(DetectionConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
        let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: layers, selectedLayerID: layers[0].id)
        return try InstrumentCompiler.compile(.init(spatial: spatial, detection: config, revision: .newSession()))
    }
    func testNearestStableRoomBoundaryRejectsScatteredWallAndOneInwardOutlier90And361() throws {
        for count in [90, 361] {
            let raw = try frame(count, [:])
            let geometry = SpatialRoomContour.Geometry(pointCount: count,
                angleResolutionDegrees: (raw.geometry.endAngleDegrees - raw.geometry.startAngleDegrees) / Double(count - 1),
                startAngleDegrees: raw.geometry.startAngleDegrees, sourceIdentifier: raw.sourceIdentifier)
            // Two full scatter cycles, plus ONE spurious near return.
            let samples: [UInt16] = [20] + Array(192...208).map(UInt16.init) + Array(192...208).map(UInt16.init)
            let contour = try XCTUnwrap(SpatialRoomContour.measured(profiles: samples.map { Array(repeating: $0, count: count) },
                capturedAt: Date(timeIntervalSince1970: 0), geometry: geometry))
            XCTAssertEqual(contour.effectiveBoundaryCentimeters(at: count / 2, toleranceCentimeters: 3), 189)
            for wall: UInt16 in 192...208 {
                XCTAssertFalse(contour.filters(distanceCentimeters: wall, at: count / 2, toleranceCentimeters: 3))
            }
            XCTAssertTrue(contour.filters(distanceCentimeters: 100, at: count / 2, toleranceCentimeters: 3))
            let compiled = try instrument(count, [count / 2: 100]).withDocumentSettings(
                detection: .init(roomContour: .init(isEnabled: true, toleranceCentimeters: 3)), channel: .init())
            var pipeline = SpatialDetectionPipeline()
            for wall: UInt16 in [192, 200, 208] {
                let selected = pipeline.select(frame: try frame(count, [count / 2: wall]), instrument: compiled, contour: contour)
                XCTAssertTrue(selected.objects.isEmpty); XCTAssertTrue(selected.isEmpty)
            }
        }
    }
    func testMinimumAngleKeepsNearestAndUsesWholeMMKSpans90And361() throws {
        for count in [90, 361] {
            let middle = count / 2
            let ten = count == 90 ? 5 : 20
            let thirty = count == 90 ? 15 : 60
            for (offset, expected) in [(ten, 1), (thirty, 2)] {
                let samples: [Int: UInt16] = [middle: 100, middle + offset: 140]
                var pipeline = SpatialDetectionPipeline()
                let selected = pipeline.select(frame: try frame(count, samples), instrument: try instrument(count, samples), contour: nil)
                XCTAssertEqual(selected.objects.count, expected, "\(count), offset \(offset)")
                XCTAssertEqual(selected.activeHandles.count, expected)
                XCTAssertEqual(pipeline.select(frame: try frame(count, samples), instrument: try instrument(count, samples, angle: 0), contour: nil).objects.count, 2)
            }
        }
    }
    func testPanicBlocksOnlyTouchedCellPerLayerUntilMeasuredExit90And361() throws {
        for count in [90, 361] {
            for transition: SpatialNoteTransition in [.legato, .holdUntilNext, .overlap(milliseconds: 25)] {
                let first = count / 3, other = 2 * count / 3
                let samples: [Int: UInt16] = [first: 100, other: 140]
                let compiled = try instrument(count, samples, transition: transition)
                var state = PlayEngine.step(PlayState(), .install(compiled)).0
                state = PlayEngine.step(state, .sessionBegan(session)).0
                state = PlayEngine.step(state, .frame(try frame(count, [first: 100]))).0
                XCTAssertEqual(state.soundingNoteCount, 1)
                state = PlayEngine.step(state, .panic).0
                XCTAssertEqual(state.soundingNoteCount, 0)
                state = PlayEngine.step(state, .frame(try frame(count, [first: 100], sequence: 2))).0
                XCTAssertEqual(state.soundingNoteCount, 0, "held cell after panic")
                state = PlayEngine.step(state, .panic).0
                state = PlayEngine.step(state, .frame(try frame(count, [first: 100], sequence: 2))).0
                XCTAssertEqual(state.soundingNoteCount, 0, "repeated panic retains blocked cell")
                state = PlayEngine.step(state, .frame(try frame(count, samples, sequence: 3))).0
                XCTAssertEqual(state.soundingNoteCount, 1, "other layer immediately plays")
                state = PlayEngine.step(state, .frame(try frame(count, [other: 140], sequence: 4))).0
                state = PlayEngine.step(state, .frame(try frame(count, samples, sequence: 5))).0
                XCTAssertEqual(state.soundingNoteCount, 2, "exit and re-entry unlock")
            }
        }
    }
    func testMinimumAngleSurvivesDocumentEncodingAndLegacyDefaults() throws {
        var legacy = try JSONDecoder().decode(DetectionConfiguration.self, from: Data("{}".utf8))
        XCTAssertEqual(legacy.minimumAngleDegrees, 20)
        legacy.minimumAngleDegrees = 7
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        XCTAssertEqual(json["minimumAngleDegrees"] as? Int, 7)
        XCTAssertEqual(try JSONDecoder().decode(DetectionConfiguration.self, from: JSONEncoder().encode(legacy)), legacy)
    }
    func testMinimumAngleUsesSpanGapAtThresholdRatherThanMMKCenters() throws {
        for count in [90, 361] {
            let middle = count / 2, offset = count == 90 ? 10 : 40
            let samples: [Int: UInt16] = [middle: 100, middle + offset: 140]
            var pipeline = SpatialDetectionPipeline()
            let result = pipeline.select(frame: try frame(count, samples), instrument: try instrument(count, samples), contour: nil)
            XCTAssertEqual(result.objects.count, count == 90 ? 1 : 2,
                "MMK spans have a smaller gap than their 20-degree center separation")
        }
    }
    func testMinimumAngleRejectsInvalidDocumentValuesAndPersistsZeroAndNinety() throws {
        for degrees in [0, 90] {
            var value = DetectionConfiguration(); value.minimumAngleDegrees = degrees
            XCTAssertEqual(try JSONDecoder().decode(DetectionConfiguration.self, from: JSONEncoder().encode(value)), value)
        }
        let valid = try instrument(361, [180: 100])
        for degrees in [-1, 91] {
            var config = valid.detection; config.minimumAngleDegrees = degrees
            let layer = SpatialDocumentLayer(id: UUID(), name: "Validation", color: .blue,
                isVisible: true, isActive: true, isLocked: false, isSoloed: false, cells: [], routings: [], cellOverrides: [:])
            let doc = InstrumentDocument(spatial: try .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id), detection: config, revision: .newSession())
            XCTAssertThrowsError(try InstrumentCompiler.compile(doc))
        }
    }
    func testFastLegatoChordChangesTenPerSecondHaveNoDuplicateOffOrEmptySound90And361() throws {
        for count in [90, 361] {
            let tick = try frame(count, [:]).geometry.tickSpan(at: count / 2)!.lower
            let a = PolarDeviceLattice(ring: 100, sector: tick)!, b = PolarDeviceLattice(ring: 120, sector: tick)!
            let target = SpatialRoutingTarget.midiNote(channel: 0)
            let layer = SpatialDocumentLayer(id: UUID(), name: "Fast legato", color: .blue,
                isVisible: true, isActive: true, isLocked: false, isSoloed: false, cells: [a, b],
                routings: [.init(target: target, program: .chord(notes: [60, 64, 67], velocity: 100, transition: .legato))],
                cellOverrides: [b: [.init(target: target, value: .chord(notes: [62, 65, 69], velocity: 100))]])
            let doc = InstrumentDocument(spatial: try .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id), detection: .allStagesOff, revision: .newSession())
            var state = PlayEngine.step(PlayState(), .install(try InstrumentCompiler.compile(doc))).0
            var sounding = Set<Int>(), ons = 0, offs = 0, gaps = 0
            for i in 0..<100 {
                let input = try frame(count, [count / 2: i % 2 == 0 ? 100 : 120], sequence: UInt64(i + 1))
                // Supplied timing models 10 actual cell changes per second.
                let paced = ProfileFrame(sessionID: input.sessionID, sequence: input.sequence, time: Double(i) / 10,
                    measurements: input.measurements, geometry: input.geometry, rawProfile: input.rawProfile)
                let result = PlayEngine.step(state, .frame(paced)); state = result.0
                for event in result.1 {
                    switch event {
                    case .noteOn(_, _, let note): XCTAssertTrue(sounding.insert(Int(note.number)).inserted); ons += 1
                    case .noteOff(_, _, let note): XCTAssertNotNil(sounding.remove(Int(note.number))); offs += 1
                    default: XCTFail("Unexpected fast-change event")
                    }
                    if sounding.isEmpty { gaps += 1 }
                }
                XCTAssertEqual(sounding, Set(i % 2 == 0 ? [60, 64, 67] : [62, 65, 69]))
            }
            print("ABNAHME-A fast legato rays=\(count) changes=100 rate=10Hz on=\(ons) off=\(offs) event-level empty gaps=\(gaps)")
            XCTAssertEqual(ons, 300); XCTAssertEqual(offs, 297); XCTAssertEqual(gaps, 0)
            let stop = PlayEngine.step(state, .stop)
            XCTAssertEqual(stop.1.count, 3); XCTAssertEqual(stop.0.soundingNoteCount, 0)
        }
    }
}
