import XCTest
import SickPLSControlCore
import SickPLSCore
@testable import PlanariumDomain

final class DeviceLatticeSelectorTests: XCTestCase {
    private let revision = SpatialDocumentRevision(testCounter: 41)

    private func cell(_ ring: Int, _ sector: Int) throws -> PolarDeviceLattice {
        try XCTUnwrap(PolarDeviceLattice(ring: ring, sector: sector))
    }

    private func measurement(_ order: Int, _ ring: Int, _ sector: Int) throws -> DeviceTickMeasurement {
        try XCTUnwrap(DeviceTickMeasurement(
            order: order, ticks: try XCTUnwrap(.point(sector)), rawCentimeters: UInt16(ring)
        ))
    }

    private func spanMeasurement(_ order: Int, _ ring: Int, _ lower: Int, _ upper: Int) throws -> DeviceTickMeasurement {
        try XCTUnwrap(DeviceTickMeasurement(
            order: order, ticks: try XCTUnwrap(DeviceTickSpan(lower: lower, upper: upper)),
            rawCentimeters: UInt16(ring)
        ))
    }

    private func document(
        layers: [SpatialDocumentLayer]
    ) throws -> SpatialDocument {
        try SpatialDocument(
            latticeVersion: .polarDeviceV2, layers: layers, selectedLayerID: layers[0].id
        )
    }

    private func layer(
        id: UUID = UUID(), cells: Set<PolarDeviceLattice>, routings: [SpatialRouting] = []
    ) -> SpatialDocumentLayer {
        SpatialDocumentLayer(
            id: id, name: "M-4a1", color: .orange, isVisible: true, isActive: true,
            isLocked: false, isSoloed: false, cells: cells, routings: routings,
            cellOverrides: [:]
        )
    }

    private func compiled(
        cells: Set<PolarDeviceLattice>, routings: [SpatialRouting] = []
    ) throws -> (CompiledInstrument, UUID) {
        let id = UUID()
        let instrument = try SpatialInstrumentCompiler.compile(
            try document(layers: [layer(id: id, cells: cells, routings: routings)]),
            revision: revision
        )
        return (instrument, id)
    }

    func testSpanUsesSmallestPaintedTickAndRawDistanceThenOrder() throws {
        let first = try cell(120, 181)
        let second = try cell(120, 183)
        let (instrument, layerID) = try compiled(cells: [first, second])
        var selector = DeviceLatticeSelector()
        let result = selector.step(
            measurements: [try spanMeasurement(0, 120, 180, 183)], instrument: instrument,
            geometry: .fullScan361, configuration: .disabled
        )
        XCTAssertEqual(result.activeHandles[layerID]?.cell, first)
        XCTAssertEqual(selector.indexRequestCount, 1)
    }

    func testSelectionIsIndependentPerLayerAndOnlyEligibleLayersAreReturned() throws {
        let aID = UUID(); let bID = UUID()
        let a = layer(id: aID, cells: [try cell(100, 100)])
        let b = layer(id: bID, cells: [try cell(200, 100)])
        let inactive = SpatialDocumentLayer(
            id: UUID(), name: "inactive", color: .blue, isVisible: true, isActive: false,
            isLocked: false, isSoloed: false, cells: [try cell(300, 100)], routings: [],
            cellOverrides: [:]
        )
        let instrument = try SpatialInstrumentCompiler.compile(
            try document(layers: [a, b, inactive]), revision: revision
        )
        var selector = DeviceLatticeSelector()
        let result = selector.step(
            measurements: [try measurement(0, 100, 100), try measurement(1, 200, 100)],
            instrument: instrument, geometry: .fullScan361, configuration: .disabled
        )
        XCTAssertEqual(Set(result.activeHandles.keys), [aID, bID])
        XCTAssertFalse(result.activeHandles.keys.contains(inactive.id))
    }

    func testNearestCandidateWinsAndTiesUseOriginalOrder() throws {
        let near = try cell(100, 200); let far = try cell(120, 200)
        let (instrument, layerID) = try compiled(cells: [near, far])
        var selector = DeviceLatticeSelector()
        let nearResult = selector.step(
            measurements: [try measurement(0, 120, 200), try measurement(1, 100, 200)],
            instrument: instrument, geometry: .fullScan361, configuration: .disabled
        )
        XCTAssertEqual(nearResult.activeHandles[layerID]?.cell, near)
        selector.reset()
        let tieResult = selector.step(
            measurements: [try measurement(5, 100, 200), try measurement(2, 100, 200)],
            instrument: instrument, geometry: .fullScan361, configuration: .disabled
        )
        XCTAssertEqual(tieResult.activeHandles[layerID]?.cell, near)
        XCTAssertEqual(tieResult.candidateDistancesCentimeters[layerID], 100)
    }

    func testHoldGeometryUsesRadialAndOverlappingTickBounds() throws {
        let cell = try self.cell(100, 200)
        let geometry = DeviceLatticeHoldGeometry()
        let margin = SpatialHysteresisConfiguration(radialMarginCentimeters: 5, angularMarginTicks: 2,
                                                     switchConfirmationProfiles: 1,
                                                     continuousBacklashCentimeters: 0)
        XCTAssertTrue(geometry.contains(try measurement(0, 95, 200), in: cell, margin: margin))
        XCTAssertTrue(geometry.contains(try measurement(0, 105, 198), in: cell, margin: margin))
        XCTAssertFalse(geometry.contains(try measurement(0, 94, 200), in: cell, margin: margin))
        XCTAssertFalse(geometry.contains(try measurement(0, 100, 203), in: cell, margin: margin))
        XCTAssertTrue(geometry.contains(try spanMeasurement(0, 100, 202, 206), in: cell, margin: margin))
        XCTAssertFalse(geometry.contains(try spanMeasurement(0, 100, 203, 206), in: cell, margin: margin))
        let zero = try self.cell(100, 0); let max = try self.cell(100, 360)
        XCTAssertTrue(geometry.contains(try measurement(0, 100, 0), in: zero, margin: margin))
        XCTAssertTrue(geometry.contains(try measurement(0, 100, 360), in: max, margin: margin))
        let noMargin = SpatialHysteresisConfiguration.disabled
        XCTAssertFalse(geometry.contains(try measurement(0, 101, 1), in: zero, margin: noMargin))
    }

    func testQ1ExtremePublicHysteresisConfigurationIsClampedWithoutTrap() throws {
        let configuration = SpatialHysteresisConfiguration(
            radialMarginCentimeters: .max, angularMarginTicks: .max,
            switchConfirmationProfiles: Int.max,
            continuousBacklashCentimeters: .max)
        XCTAssertEqual(configuration.radialMarginCentimeters, 20)
        XCTAssertEqual(configuration.angularMarginTicks, 10)
        XCTAssertEqual(configuration.switchConfirmationProfiles, 4)
        XCTAssertEqual(configuration.continuousBacklashCentimeters, 5)
        XCTAssertNoThrow(DeviceLatticeHoldGeometry().contains(
            try measurement(0, 100, 200), in: try cell(100, 200), margin: configuration))
    }

    func testHeldCellUsesUnpaintedMeasurementAndClearsOutsideIt() throws {
        let held = try cell(100, 200)
        let (instrument, layerID) = try compiled(cells: [held])
        var selector = DeviceLatticeSelector()
        _ = selector.step(measurements: [try measurement(0, 100, 200)], instrument: instrument,
                          geometry: .fullScan361, configuration: .disabled)
        let holdConfig = SpatialHysteresisConfiguration(radialMarginCentimeters: 5, angularMarginTicks: 2,
                                                        switchConfirmationProfiles: 1,
                                                        continuousBacklashCentimeters: 0)
        let heldResult = selector.step(measurements: [try measurement(0, 105, 200)], instrument: instrument,
                                       geometry: .fullScan361, configuration: holdConfig)
        XCTAssertEqual(heldResult.activeHandles[layerID]?.cell, held)
        let cleared = selector.step(measurements: [try measurement(0, 106, 200)], instrument: instrument,
                                    geometry: .fullScan361, configuration: holdConfig)
        XCTAssertNil(cleared.activeHandles[layerID])
    }

    func testSwitchRequiresConfiguredConfirmationProfilesAndEmptyClears() throws {
        let old = try cell(100, 200); let next = try cell(80, 200)
        let (instrument, layerID) = try compiled(cells: [old, next])
        var selector = DeviceLatticeSelector()
        let config = SpatialHysteresisConfiguration(radialMarginCentimeters: 0, angularMarginTicks: 0,
                                                    switchConfirmationProfiles: 2,
                                                    continuousBacklashCentimeters: 0)
        _ = selector.step(measurements: [try measurement(0, 100, 200)], instrument: instrument,
                          geometry: .fullScan361, configuration: config)
        let transition = [try measurement(0, 100, 200), try measurement(1, 80, 200)]
        let first = selector.step(measurements: transition, instrument: instrument,
                                  geometry: .fullScan361, configuration: config)
        XCTAssertEqual(first.activeHandles[layerID]?.cell, old)
        let second = selector.step(measurements: transition, instrument: instrument,
                                   geometry: .fullScan361, configuration: config)
        XCTAssertEqual(second.activeHandles[layerID]?.cell, next)
        XCTAssertTrue(selector.step(measurements: [], instrument: instrument, geometry: .fullScan361,
                                    configuration: config).isEmpty)
        let afterEmpty = selector.step(measurements: [try measurement(0, 85, 200)], instrument: instrument,
                                       geometry: .fullScan361,
                                       configuration: SpatialHysteresisConfiguration(radialMarginCentimeters: 5,
                                                                                    angularMarginTicks: 2,
                                                                                    switchConfirmationProfiles: 2,
                                                                                    continuousBacklashCentimeters: 0))
        XCTAssertTrue(afterEmpty.isEmpty)
        let unusableProfile = try B0ScanProfile.build(
            partialScanIndex: 0,
            measurements: (0..<361).map { _ in try! B0ScanProfile.Measurement.build(value: 0, fieldFlags: 0) }
        )
        XCTAssertTrue(selector.step(measurements: try FullScanProfileAdapter.measurements(from: unusableProfile,
                                                                                            geometry: .fullScan361),
                                    instrument: instrument, geometry: .fullScan361, configuration: config).isEmpty)
    }

    func testRevisionAndGeometryResetState() throws {
        let old = try cell(100, 200); let next = try cell(80, 200)
        let (instrument, layerID) = try compiled(cells: [old, next])
        var selector = DeviceLatticeSelector()
        _ = selector.step(measurements: [try measurement(0, 100, 200)], instrument: instrument,
                          geometry: .fullScan361, configuration: .disabled)
        let changedGeometry = ProfileGeometryIdentity(operatingMode: "test", pointCount: 361,
                                                       startAngleDegrees: -90, endAngleDegrees: 90)
        let result = selector.step(measurements: [try measurement(0, 80, 200)], instrument: instrument,
                                   geometry: changedGeometry, configuration: .disabled)
        XCTAssertEqual(result.activeHandles[layerID]?.cell, next)
        XCTAssertEqual(result.activeHandles[layerID]?.revision, revision)
        let newRevision = SpatialDocumentRevision(testCounter: 42)
        let secondInstrument = try SpatialInstrumentCompiler.compile(
            try document(layers: [layer(id: layerID, cells: [old, next])]), revision: newRevision
        )
        var pendingSelector = DeviceLatticeSelector()
        let config = SpatialHysteresisConfiguration(radialMarginCentimeters: 0, angularMarginTicks: 0,
                                                    switchConfirmationProfiles: 2,
                                                    continuousBacklashCentimeters: 0)
        _ = pendingSelector.step(measurements: [try measurement(0, 100, 200)], instrument: instrument,
                                 geometry: .fullScan361, configuration: config)
        let fresh = pendingSelector.step(measurements: [try measurement(0, 100, 200), try measurement(1, 80, 200)],
                                         instrument: secondInstrument, geometry: .fullScan361, configuration: config)
        XCTAssertEqual(fresh.activeHandles[layerID]?.revision, newRevision)
        XCTAssertEqual(fresh.activeHandles[layerID]?.cell, next)
    }

    func testRevisionSessionSeparatesSameCounterAndRejectsForeignHandle() throws {
        let layerID = UUID()
        let first = try cell(100, 200)
        let second = try cell(101, 200)
        let sessionA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let sessionB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let revisionA = SpatialDocumentRevision(session: sessionA, counter: 1)
        let revisionB = SpatialDocumentRevision(session: sessionB, counter: 1)
        let instrumentA = try SpatialInstrumentCompiler.compile(
            try document(layers: [layer(id: layerID, cells: [first])]), revision: revisionA)
        let instrumentB = try SpatialInstrumentCompiler.compile(
            try document(layers: [layer(id: layerID, cells: [second])]), revision: revisionB)
        let handleA = try XCTUnwrap(instrumentA.hits(tick: 200, raw: 100).first)

        XCTAssertNotEqual(revisionA, revisionB)
        XCTAssertEqual(try revisionA.advanced().session, sessionA)
        XCTAssertEqual(try revisionA.advanced().counter, 2)
        XCTAssertThrowsError(try instrumentB.validate([layerID: handleA])) { error in
            XCTAssertEqual(error as? CompiledInstrumentError, .foreignActiveHandle)
        }

        var selector = DeviceLatticeSelector()
        _ = selector.step(measurements: [try measurement(0, 100, 200)], instrument: instrumentA,
                          geometry: .fullScan361, configuration: .disabled)
        let afterSessionChange = selector.step(
            measurements: [try measurement(0, 100, 200)], instrument: instrumentB,
            geometry: .fullScan361, configuration: .disabled)
        XCTAssertNil(afterSessionChange.activeHandles[layerID])
    }

    func testHeldGapResetsPendingAndRequiresConsecutiveCandidates() throws {
        let old = try cell(100, 200); let next = try cell(80, 200)
        let (instrument, layerID) = try compiled(cells: [old, next])
        var selector = DeviceLatticeSelector()
        let config = SpatialHysteresisConfiguration(radialMarginCentimeters: 5, angularMarginTicks: 2,
                                                    switchConfirmationProfiles: 2,
                                                    continuousBacklashCentimeters: 0)
        _ = selector.step(measurements: [try measurement(0, 100, 200)], instrument: instrument,
                          geometry: .fullScan361, configuration: config)
        let candidateAndHold = [try measurement(0, 80, 200), try measurement(1, 100, 201)]
        let first = selector.step(measurements: candidateAndHold, instrument: instrument,
                                  geometry: .fullScan361, configuration: config)
        XCTAssertEqual(first.activeHandles[layerID]?.cell, old)
        let heldOnly = selector.step(measurements: [try measurement(0, 100, 201)], instrument: instrument,
                                     geometry: .fullScan361, configuration: config)
        XCTAssertEqual(heldOnly.activeHandles[layerID]?.cell, old)
        let afterGap = selector.step(measurements: candidateAndHold, instrument: instrument,
                                     geometry: .fullScan361, configuration: config)
        XCTAssertEqual(afterGap.activeHandles[layerID]?.cell, old)
        let consecutive = selector.step(measurements: candidateAndHold, instrument: instrument,
                                        geometry: .fullScan361, configuration: config)
        XCTAssertEqual(consecutive.activeHandles[layerID]?.cell, next)
    }

    func testSwitchRequiresRadialDistanceLeadOfMarginInBothDirections() throws {
        let held = try cell(100, 200)
        let nearer = try cell(97, 250)
        let clearlyNearer = try cell(94, 250)
        let (instrument, layerID) = try compiled(cells: [held, nearer, clearlyNearer])
        let configuration = SpatialHysteresisConfiguration(radialMarginCentimeters: 5,
                                                           angularMarginTicks: 0,
                                                           switchConfirmationProfiles: 2,
                                                           continuousBacklashCentimeters: 0)

        func profile(_ raw: UInt16) throws -> [DeviceTickMeasurement] {
            [try measurement(0, 100, 200), try measurement(1, Int(raw), 250)]
        }

        var selector = DeviceLatticeSelector()
        _ = selector.step(measurements: [try measurement(0, 100, 200)], instrument: instrument,
                          geometry: .fullScan361, configuration: configuration)
        for _ in 0..<3 {
            let result = selector.step(measurements: try profile(97), instrument: instrument,
                                       geometry: .fullScan361, configuration: configuration)
            XCTAssertEqual(result.activeHandles[layerID]?.cell, held)
        }

        selector.reset()
        _ = selector.step(measurements: [try measurement(0, 100, 200)], instrument: instrument,
                          geometry: .fullScan361, configuration: configuration)
        let first = selector.step(measurements: try profile(94), instrument: instrument,
                                  geometry: .fullScan361, configuration: configuration)
        XCTAssertEqual(first.activeHandles[layerID]?.cell, held)
        let second = selector.step(measurements: try profile(94), instrument: instrument,
                                   geometry: .fullScan361, configuration: configuration)
        XCTAssertEqual(second.activeHandles[layerID]?.cell, clearlyNearer)
    }

    func testBacklashDoesNotPublishEverySmallDistanceChange() throws {
        let cells = Set(100...104).map { try! cell($0, 200) }
        let (instrument, layerID) = try compiled(cells: Set(cells))
        var selector = DeviceLatticeSelector()
        let config = SpatialHysteresisConfiguration(radialMarginCentimeters: 5, angularMarginTicks: 0,
                                                    switchConfirmationProfiles: 1,
                                                    continuousBacklashCentimeters: 2)
        _ = selector.step(measurements: [try measurement(0, 100, 200)], instrument: instrument,
                          geometry: .fullScan361, configuration: config)
        let next = selector.step(measurements: [try measurement(0, 101, 200)], instrument: instrument,
                                 geometry: .fullScan361, configuration: config)
        XCTAssertEqual(next.candidateDistancesCentimeters[layerID], 100)
        let far = selector.step(measurements: [try measurement(0, 103, 200)], instrument: instrument,
                                geometry: .fullScan361, configuration: config)
        XCTAssertEqual(far.candidateDistancesCentimeters[layerID], 101)
        let noise = [101, 100, 101]
        for value in noise {
            let result = selector.step(measurements: [try measurement(0, value, 200)], instrument: instrument,
                                        geometry: .fullScan361, configuration: config)
            XCTAssertEqual(result.candidateDistancesCentimeters[layerID], 101)
        }
        selector.reset()
        let reset = selector.step(measurements: [try measurement(0, 100, 200)], instrument: instrument,
                                  geometry: .fullScan361, configuration: config)
        XCTAssertEqual(reset.candidateDistancesCentimeters[layerID], 100)
    }

    func testHeldWithoutCandidateKeepsFilteredDistanceOnHandle() throws {
        let first = try cell(100, 200)
        let second = try cell(103, 200)
        let (instrument, layerID) = try compiled(cells: [first, second])
        let configuration = SpatialHysteresisConfiguration(
            radialMarginCentimeters: 5, angularMarginTicks: 0,
            switchConfirmationProfiles: 1, continuousBacklashCentimeters: 2)
        var selector = DeviceLatticeSelector()

        let entry = selector.step(measurements: [try measurement(0, 100, 200)], instrument: instrument,
                                  geometry: .fullScan361, configuration: configuration)
        XCTAssertEqual(entry.activeHandles[layerID]?.candidateDistanceCentimeters, 100)

        let moved = selector.step(measurements: [try measurement(0, 103, 200)], instrument: instrument,
                                  geometry: .fullScan361, configuration: configuration)
        XCTAssertEqual(moved.activeHandles[layerID]?.cell, first)
        XCTAssertEqual(moved.activeHandles[layerID]?.candidateDistanceCentimeters, 101)

        let held = selector.step(measurements: [try measurement(0, 102, 200)], instrument: instrument,
                                 geometry: .fullScan361, configuration: configuration)
        XCTAssertEqual(held.candidateDistancesCentimeters[layerID], 101)
        XCTAssertEqual(held.activeHandles[layerID]?.candidateDistanceCentimeters, 101)

        XCTAssertTrue(selector.step(measurements: [], instrument: instrument,
                                    geometry: .fullScan361, configuration: configuration).isEmpty)
        let reentered = selector.step(measurements: [try measurement(0, 103, 200)], instrument: instrument,
                                      geometry: .fullScan361, configuration: configuration)
        XCTAssertEqual(reentered.activeHandles[layerID]?.cell, second)
        XCTAssertEqual(reentered.activeHandles[layerID]?.candidateDistanceCentimeters, 103)
        XCTAssertEqual(reentered.candidateDistancesCentimeters[layerID], 103)
    }

    func testOneIndexRequestPerUsableMeasurementNotPerRouting() throws {
        let routings = (0..<8).map { _ in
            SpatialRouting(target: .boolean(name: "x"), program: .constant(1))
        }
        let (instrument, _) = try compiled(cells: [try cell(100, 200)], routings: routings)
        var selector = DeviceLatticeSelector()
        _ = selector.step(measurements: [try measurement(0, 100, 200), try measurement(1, 101, 200)],
                          instrument: instrument, geometry: .fullScan361, configuration: .disabled)
        XCTAssertEqual(selector.indexRequestCount, 2)
    }

    func testFullScanAdapterKeepsOriginalIndicesAndSkipsOnlyUnusableValues() throws {
        var values = Array(repeating: UInt16(100), count: 361)
        values[1] = 0
        values[359] = 0
        let profile = try B0ScanProfile.build(
            partialScanIndex: 0,
            measurements: values.map { try! B0ScanProfile.Measurement.build(value: $0, fieldFlags: 0) }
        )
        let adapted = try FullScanProfileAdapter.measurements(from: profile)
        XCTAssertEqual(adapted.map { $0.order }, [0] + Array(2...358) + [360])
        XCTAssertEqual(adapted.first?.ticks, DeviceTickSpan.point(0))
        XCTAssertEqual(adapted.last?.ticks, DeviceTickSpan.point(360))
    }

    func testFullScanAdapterRejectsOtherCountsAndGeometry() throws {
        let profile = try B0ScanProfile.build(
            partialScanIndex: 0,
            measurements: (0..<89).map { _ in try! B0ScanProfile.Measurement.build(value: 100, fieldFlags: 0) }
        )
        XCTAssertThrowsError(try FullScanProfileAdapter.measurements(from: profile)) { error in
            XCTAssertEqual(error as? FullScanProfileAdapterError, .unsupportedProfileGeometry)
        }
        let wrong = ProfileGeometryIdentity(operatingMode: "partial", pointCount: 361,
                                            startAngleDegrees: -45, endAngleDegrees: 45)
        XCTAssertThrowsError(try FullScanProfileAdapter.measurements(from: profile, geometry: wrong))
        let partial = try B0ScanProfile.build(
            partialScanIndex: 1,
            measurements: (0..<361).map { _ in try! B0ScanProfile.Measurement.build(value: 100, fieldFlags: 0) }
        )
        XCTAssertThrowsError(try FullScanProfileAdapter.measurements(from: partial)) { error in
            XCTAssertEqual(error as? FullScanProfileAdapterError, .unsupportedProfileGeometry)
        }
    }

    func testValidateRejectsUnpaintedCell() throws {
        let painted = try cell(100, 200)
        let (instrument, layerID) = try compiled(cells: [painted])
        let foreign = try XCTUnwrap(PolarDeviceLattice(ring: 100, sector: 201))
        let handle = CompiledActiveCell(layerID: layerID, cell: foreign, revision: revision,
                                        candidateDistanceCentimeters: 100)
        XCTAssertThrowsError(try instrument.validate([layerID: handle])) { error in
            XCTAssertEqual(error as? CompiledInstrumentError, .foreignActiveHandle)
        }
    }

    func testLegacySelectorAndHoldGeometryHaveNoMonitorPresetOrBenchmarkCallers() throws {
        let paths = [
            "Sources/SickPLSMonitor/", "Sources/PlanariumPresets/", "Sources/SickPolarBenchmark/"
        ]
        for path in paths {
            let files = try FileManager.default.subpathsOfDirectory(atPath: path)
            for file in files where file.hasSuffix(".swift") {
                let source = try String(contentsOfFile: "\(path)\(file)", encoding: .utf8)
                XCTAssertFalse(source.contains("DeviceLatticeSelector"), path + file)
                XCTAssertFalse(source.contains("DeviceLatticeHoldGeometry"), path + file)
            }
        }
    }
}
