import XCTest
@testable import PlanariumDomain

/// Production path with fakes only: compile → PlayEngine → music events, at 90 and 361 rays.
final class SurfaceProductionTests: XCTestCase {
    private let session = UUID(), layerID = UUID(), controlID = UUID()
    private let aID = UUID(), bID = UUID()
    private func geometry(_ count: Int) -> ProfileGeometryIdentity {
        .init(operatingMode: count == 90 ? "MMK" : "fullScan", pointCount: count, startAngleDegrees: -90, endAngleDegrees: 90)
    }
    private func spot(_ count: Int, _ order: Int) -> SurfaceTransform {
        let span = geometry(count).tickSpan(at: order)!
        let p = SurfaceGrid.point(ring: 100, tick: (span.lower + span.upper) / 2)
        return .init(xCm: p.x, yCm: p.y)
    }
    private func note(_ n: Int, transition: SpatialNoteTransition) -> SpatialRouting {
        .init(target: .midiNote(channel: 0), program: .singleNote(note: n, velocity: 100, transition: transition))
    }
    private func surface(_ id: UUID, at transform: SurfaceTransform, _ routing: SpatialRouting) throws -> SpatialSurface {
        try SpatialSurface(id: id, presentation: .init(name: "S", color: .orange),
                           form: .shape(.rectangle(widthCm: 12, heightCm: 12), transform), routings: [routing])
    }
    private func document(_ count: Int, transition: SpatialNoteTransition = .retrigger, withRelease: Bool = false) throws -> InstrumentDocument {
        let a = try surface(aID, at: spot(count, count / 3), note(60, transition: transition))
        let b = try surface(bID, at: spot(count, count * 2 / 3), note(62, transition: transition))
        var layers = [SpatialDocumentLayer(id: layerID, name: "Two", color: .orange, isVisible: true, isActive: true, isLocked: false,
                                           isSoloed: false, cells: [], routings: [], cellOverrides: [:], surfaces: [a, b])]
        if withRelease {
            let g = geometry(count)
            layers.append(SpatialDocumentLayer(id: controlID, name: "Release", color: .blue, isVisible: true, isActive: true, isLocked: false,
                isSoloed: false, cells: [PolarDeviceLattice(ring: 100, sector: g.tickSpan(at: count - 5)!.lower)!],
                routings: [.init(target: .releaseLayer(layerID: layerID), program: .constant(1))], cellOverrides: [:]))
        }
        return .init(spatial: try .init(latticeVersion: .polarDeviceV2, layers: layers, selectedLayerID: layerID),
                     detection: .allStagesOff, revision: .init(session: session, counter: 1))
    }
    private func frame(_ count: Int, _ orders: Set<Int>, _ time: Double) -> ProfileFrame {
        let g = geometry(count)
        return .init(sessionID: session, sequence: UInt64(time * 1000), time: time,
            measurements: (0..<count).map { DeviceTickMeasurement(order: $0, ticks: g.tickSpan(at: $0)!, rawCentimeters: orders.contains($0) ? 100 : 500)! }, geometry: g)
    }
    private func start(_ document: InstrumentDocument) throws -> PlayState {
        PlayEngine.step(PlayEngine.step(.init(), .install(try InstrumentCompiler.compile(document))).0, .sessionBegan(session)).0
    }
    private func step(_ state: inout PlayState, _ count: Int, _ orders: Set<Int>, _ time: Double) -> [MusicEvent] {
        let result = PlayEngine.step(state, .frame(frame(count, orders, time))); state = result.0; return result.1
    }
    private func ons(_ events: [MusicEvent]) -> [UInt8] {
        events.compactMap { if case .noteOn(_, _, let n) = $0 { return n.number }; return nil }.sorted()
    }
    private func offs(_ events: [MusicEvent]) -> [UInt8] {
        events.compactMap { if case .noteOff(_, _, let n) = $0 { return n.number }; return nil }.sorted()
    }

    func testEachHandPlaysOnlyItsOwnSurfaceAndBothTogether() throws {
        for count in [90, 361] {
            let a = count / 3, b = count * 2 / 3
            var state = try start(document(count))
            XCTAssertEqual(ons(step(&state, count, [a], 10)), [60], "\(count)")
            XCTAssertEqual(ons(step(&state, count, [a, b], 10.1)), [62], "second hand adds only its own note")
            XCTAssertEqual(state.soundingNoteCount, 2)
            XCTAssertEqual(offs(step(&state, count, [b], 10.2)), [60])
            XCTAssertEqual(offs(step(&state, count, [], 10.3)), [62])
        }
    }

    func testPanicReleasesEveryPartitionOfTheLayer() throws {
        for count in [90, 361] {
            var state = try start(document(count))
            _ = step(&state, count, [count / 3, count * 2 / 3], 10)
            XCTAssertEqual(state.soundingNoteCount, 2)
            let result = PlayEngine.step(state, .panic)
            XCTAssertEqual(offs(result.1), [60, 62]); XCTAssertEqual(result.0.soundingNoteCount, 0)
        }
    }

    func testReleaseLayerTargetingTheLayerReleasesAllItsSurfaces() throws {
        for count in [90, 361] {
            var state = try start(document(count, transition: .toggle, withRelease: true))
            let a = count / 3, b = count * 2 / 3
            XCTAssertEqual(ons(step(&state, count, [a], 10)), [60])
            _ = step(&state, count, [], 10.01)
            XCTAssertEqual(ons(step(&state, count, [b], 10.02)), [62])
            XCTAssertEqual(state.soundingNoteCount, 2, "toggle holds both after the hands left")
            let released = step(&state, count, [count - 5], 10.5)
            XCTAssertEqual(offs(released), [60, 62], "release names the layer, both partitions are released (\(count))")
            XCTAssertEqual(state.soundingNoteCount, 0)
        }
    }
}
