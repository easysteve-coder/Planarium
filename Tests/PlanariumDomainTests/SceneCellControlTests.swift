import XCTest
@testable import PlanariumDomain

final class SceneCellControlTests: XCTestCase {
    private struct Harness {
        let layer = UUID(), day = UUID(), night = UUID(), session = UUID()
        let documentSession = UUID(), routingID = UUID()
        let left = PolarDeviceLattice(ring: 100, sector: 40)!
        let right = PolarDeviceLattice(ring: 100, sector: 320)!
        let target = SpatialRoutingTarget.sceneSwitch(action: .next, dwellSeconds: 0.2)
        func instrument(ownTargets: Bool = true, missing: Bool = false, detection: DetectionConfiguration = .allStagesOff, revision: UInt64 = 0) throws -> CompiledInstrument {
            let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [
                .init(id: layer, name: "Switch", color: .orange, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                    cells: [left, right], routings: [.init(id: routingID, target: target, program: .constant(1))],
                    cellOverrides: ownTargets ? [left: [.init(target: target, value: .sceneSwitch(action: .scene(day)))],
                        right: [.init(target: target, value: .sceneSwitch(action: .scene(night)))]] : [:])
            ], selectedLayerID: layer)
            // Round-trip through the budgeted production codec before compiling.
            let decoded = try JSONDecoder().decode(SpatialDocument.self, from: JSONEncoder().encode(spatial))
            XCTAssertEqual(decoded, spatial)
            return try InstrumentCompiler.compile(.init(spatial: decoded, detection: detection, revision: .init(session: documentSession, counter: revision),
                scenes: missing ? [.init(id: night, name: "Night", activeLayerIDs: [])] : [
                    .init(id: day, name: "Day", activeLayerIDs: []), .init(id: night, name: "Night", activeLayerIDs: [])], currentSceneID: missing ? night : day))
        }
        func frame(_ sequence: UInt64, _ time: Double, _ orders: Set<Int>) throws -> ProfileFrame {
            let geometry = ProfileGeometryIdentity(operatingMode: "MMK", pointCount: 90, startAngleDegrees: -90, endAngleDegrees: 90)
            let points = try (0..<90).map { order in
                try XCTUnwrap(DeviceTickMeasurement(order: order, ticks: try XCTUnwrap(geometry.tickSpan(at: order)),
                    rawCentimeters: orders.contains(order) ? 100 : 500))
            }
            return .init(sessionID: session, sequence: sequence, time: time, measurements: points, geometry: geometry)
        }
    }
    func testTwoCellsChooseDayThenNightAtMMK90AndRearmOnlyAfterExit() throws {
        let h = Harness()
        var state = PlayEngine.step(PlayState(), .install(try h.instrument())).0
        state = PlayEngine.step(state, .sessionBegan(h.session)).0
        let day = PlayEngine.step(state, .frame(try h.frame(1, 0, [10])))
        XCTAssertEqual(day.1, [.sceneChanged(h.day)])
        let held = PlayEngine.step(day.0, .frame(try h.frame(3, 0.25, [10])))
        XCTAssertTrue(held.1.isEmpty)
        state = PlayEngine.step(held.0, .frame(try h.frame(4, 0.3, []))).0
        let night = PlayEngine.step(state, .frame(try h.frame(5, 0.4, [79])))
        XCTAssertEqual(night.1, [.sceneChanged(h.night)])
        XCTAssertEqual(night.0.instrument?.revision, day.0.instrument?.revision)
    }
    func testFallbackMissingSceneAndDirectCellToCellEntry() throws {
        let h = Harness()
        var state = PlayEngine.step(PlayState(), .install(try h.instrument(ownTargets: false))).0
        let fallback = PlayEngine.step(state, .frame(try h.frame(1, 0, [10])))
        XCTAssertEqual(fallback.1, [.sceneChanged(h.night)])
        let direct = PlayEngine.step(fallback.0, .frame(try h.frame(3, 0.25, [79])))
        XCTAssertEqual(direct.1, [.sceneChanged(h.day)])
        state = PlayEngine.step(PlayState(), .install(try h.instrument(missing: true))).0
        state = PlayEngine.step(state, .frame(try h.frame(1, 0, [10]))).0
        XCTAssertTrue(PlayEngine.step(state, .frame(try h.frame(2, 0.2, [10]))).1.isEmpty)
    }
    func testTwoHandsHaveIndependentEntriesAndDeterministicPrecedence() throws {
        let h = Harness()
        var state = PlayEngine.step(PlayState(), .install(try h.instrument())).0
        let first = PlayEngine.step(state, .frame(try h.frame(1, 0, [10])))
        XCTAssertEqual(first.1, [.sceneChanged(h.day)])
        let second = PlayEngine.step(first.0, .frame(try h.frame(2, 0.1, [10, 79])))
        XCTAssertEqual(second.1, [.sceneChanged(h.night)])
        let held = PlayEngine.step(second.0, .frame(try h.frame(3, 0.31, [10, 79])))
        XCTAssertTrue(held.1.isEmpty)
        state = PlayEngine.step(held.0, .frame(try h.frame(4, 0.4, []))).0
        let both = PlayEngine.step(state, .frame(try h.frame(5, 0.5, [79, 10])))
        XCTAssertEqual(both.1, [.sceneChanged(h.day), .sceneChanged(h.night)])
    }
    func testClickActivationUsesSameControlTransitionWithoutInstallOrMeasuredNoteOn() throws {
        let h = Harness(), instrument = try h.instrument()
        let state = PlayEngine.step(PlayState(), .install(instrument)).0
        let result = PlayEngine.step(state, .selectScene(h.day))
        XCTAssertEqual(result.1, [.sceneChanged(h.day)])
        XCTAssertEqual(result.0.instrument, instrument)
        XCTAssertEqual(result.0.processedProfileCount, 0)
        XCTAssertTrue(PlayEngine.step(result.0, .selectScene(UUID())).1.isEmpty)
    }
    func testGroupedAcceptedObjectsKeepBothSwitchCellsIndependent() throws {
        let h = Harness()
        let state = PlayEngine.step(PlayState(), .install(try h.instrument(detection: .ownerDefaults))).0
        let result = PlayEngine.step(state, .frame(try h.frame(1, 0, [10, 79])))
        XCTAssertEqual(result.1, [.sceneChanged(h.day), .sceneChanged(h.night)])
    }
    func testPanicBlocksBothHeldSwitchCellsUntilMeasuredExitAndReleaseReturnsPlayable() throws {
        let h = Harness()
        var state = PlayEngine.step(PlayState(), .install(try h.instrument())).0
        state = PlayEngine.step(state, .frame(try h.frame(1, 0, [10, 79]))).0
        state = PlayEngine.step(state, .panic).0
        state = PlayEngine.step(state, .frame(try h.frame(2, 0.1, [10, 79]))).0
        XCTAssertTrue(PlayEngine.step(state, .frame(try h.frame(3, 0.31, [10, 79]))).1.isEmpty)
        state = PlayEngine.step(state, .frame(try h.frame(4, 0.35, []))).0
        let reentered = PlayEngine.step(state, .frame(try h.frame(5, 0.4, [10, 79])))
        XCTAssertEqual(reentered.1, [.sceneChanged(h.day), .sceneChanged(h.night)])
        state = reentered.0
        for release: PlayInput in [.inputLost, .stop, .sleep, .wake, .terminate, .sessionEnded(h.session)] {
            let released = PlayEngine.step(state, release).0
            XCTAssertEqual(PlayEngine.step(released, .frame(try h.frame(7, 0.7, [10]))).1, [.sceneChanged(h.day)])
        }
    }
    func testUnchangedInstallBeforePanicPreservesBothMeasuredControlCarriers() throws {
        let h = Harness()
        var state = PlayEngine.step(PlayState(), .install(try h.instrument())).0
        state = PlayEngine.step(state, .frame(try h.frame(1, 0, [10, 79]))).0
        XCTAssertEqual(state.selection.sceneControlHandles.count, 2)
        let replacement = try h.instrument(revision: 1)
        state = PlayEngine.step(state, .install(replacement)).0
        XCTAssertEqual(state.selection.sceneControlHandles.count, 2)
        XCTAssertEqual(state.selection.measuredEntryHandles.count, 2)
        XCTAssertTrue(state.selection.sceneControlHandles.allSatisfy { $0.revision == replacement.revision })
        state = PlayEngine.step(state, .panic).0
        state = PlayEngine.step(state, .frame(try h.frame(2, 0.1, [10, 79]))).0
        XCTAssertTrue(PlayEngine.step(state, .frame(try h.frame(3, 0.31, [10, 79]))).1.isEmpty,
                      "Install followed by PANIC blocks both occupied controls until a measured exit")
        state = PlayEngine.step(state, .frame(try h.frame(4, 0.35, []))).0
        XCTAssertEqual(PlayEngine.step(state, .frame(try h.frame(5, 0.4, [10, 79]))).1, [.sceneChanged(h.day), .sceneChanged(h.night)])
    }
    func testEachCellSwitchesImmediatelyAfterConfiguredProfileConfirmation() throws {
        let h = Harness()
        var configuration = DetectionConfiguration.ownerDefaults
        configuration.cellSelection = .init(confirmationProfiles: 2)
        var state = PlayEngine.step(PlayState(), .install(try h.instrument(detection: configuration))).0
        state = PlayEngine.step(state, .frame(try h.frame(1, 0, [10, 79]))).0
        XCTAssertTrue(state.selection.sceneControlHandles.isEmpty)
        let confirmed = PlayEngine.step(state, .frame(try h.frame(2, 0.2, [10, 79])))
        XCTAssertEqual(confirmed.1, [.sceneChanged(h.day), .sceneChanged(h.night)])
        XCTAssertEqual(confirmed.0.selection.sceneControlHandles.count, 2)
        XCTAssertTrue(PlayEngine.step(confirmed.0, .frame(try h.frame(3, 0.41, [10, 79]))).1.isEmpty)
    }
}
