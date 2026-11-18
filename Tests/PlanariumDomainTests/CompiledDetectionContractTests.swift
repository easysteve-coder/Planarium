import XCTest
import PlanariumDomain
import SickPLSCore
import SickPLSControlCore

/// D1–D9 use the compiled production entry, never the legacy workspace selector.
final class CompiledDetectionContractTests: XCTestCase {
    private func snapInstrument(_ addresses: [PolarMetricGridCell], ownNotes: [PolarMetricGridCell: Int] = [:],
                                snap: UInt16 = 5, confirmation: Int = 1, program: SpatialValueProgram? = nil,
                                grid: MetricSquareGrid = .quarterMeter) throws -> CompiledInstrument {
        let target = SpatialRoutingTarget.midiNote(channel: 0)
        let cells = try addresses.reduce(into: Set<PolarDeviceLattice>()) {
            $0.formUnion(try LegacyLatticeMigration.migrate($1, in: grid).cells)
        }
        var overrides: [PolarDeviceLattice: [SpatialCellAction]] = [:]
        for (address, note) in ownNotes {
            for cell in try LegacyLatticeMigration.migrate(address, in: grid).cells {
                overrides[cell] = [.init(target: target, value: .note(number: note, velocity: 90))]
            }
        }
        let layer = SpatialDocumentLayer(id: layerID, name: "Snap", color: .blue, isVisible: true,
            isActive: true, isLocked: false, isSoloed: false, cells: cells,
            routings: [.init(target: target, program: program ?? .singleNote(note: 60, velocity: 90, transition: .toggle))], cellOverrides: overrides)
        let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layerID)
        var config = DetectionConfiguration.allStagesOff
        config.cellSelection = .init(boundaryMarginCentimeters: snap, confirmationProfiles: confirmation)
        return try InstrumentCompiler.compile(.init(spatial: spatial, detection: config, revision: .newSession(), editorGrid: grid))
    }

    func testSnapRadialUsesOuterBoundaryOfEqualContentSurfaceAndReturnCancelsSwitch() throws {
        let a = PolarMetricGridCell(ring: 4, angularIndex: 16)
        let b = PolarMetricGridCell(ring: 5, angularIndex: 16)
        let c = PolarMetricGridCell(ring: 6, angularIndex: 16)
        let compiled = try snapInstrument([a, b, c], ownNotes: [b: 60, c: 64])
        var pipeline = SpatialDetectionPipeline()
        func select(_ raw: UInt16) throws -> PolarDeviceLattice? {
            pipeline.select(frame: try frame([185: raw]), instrument: compiled, contour: nil).activeHandles[layerID]?.cell
        }
        let entered = try XCTUnwrap(select(101))
        for raw: UInt16 in [120, 149, 154, 155, 149, 154] {
            XCTAssertEqual(try select(raw), entered, "Internal edges and returning before Snap must hold")
        }
        let switched = try XCTUnwrap(select(156))
        XCTAssertEqual(switched.ring, 156)
        XCTAssertEqual(try select(145), switched, "Exactly 5 cm from the inner edge still holds")
        XCTAssertEqual(try select(144)?.ring, 144)
        XCTAssertEqual(try select(95)?.ring, 144)
        XCTAssertNil(try select(94))
        XCTAssertEqual(try select(100)?.ring, 100, "Entry from empty has no Snap delay")
    }

    func testSnapSidewaysUsesSameCentimeterTravelAtFiftyAndOneHundredEightyCentimeters() throws {
        for radius in [50, 180] {
            let ring = radius / 25
            let step = PolarMetricCellSegment.angularStepDegrees(outerRadiusMeters: Double(ring + 1) * 0.25, radialHeightMeters: 0.25)
            let index = Int(180 / step)
            let a = PolarMetricGridCell(ring: ring, angularIndex: index)
            let b = PolarMetricGridCell(ring: ring, angularIndex: index + 1)
            let compiled = try snapInstrument([a, b], ownNotes: [b: 64])
            var pipeline = SpatialDetectionPipeline()
            let edgeTick = (step * 2 + 180)
            let heldTick = Int(floor(edgeTick + 5 / (Double(radius) * .pi / 360)))
            let crossedTick = heldTick + 1
            func select(_ tick: Int) throws -> PolarDeviceLattice? {
                pipeline.select(frame: try frame([tick: UInt16(radius)]), instrument: compiled, contour: nil).activeHandles[layerID]?.cell
            }
            let entered = try XCTUnwrap(select(181))
            XCTAssertEqual(try select(Int(ceil(edgeTick))), entered)
            XCTAssertEqual(try select(heldTick), entered, "radius=\(radius), within 5 cm")
            XCTAssertEqual(try select(181), entered)
            XCTAssertEqual(try select(heldTick), entered)
            XCTAssertEqual(try select(crossedTick)?.sector, crossedTick, "radius=\(radius), beyond 5 cm")
            XCTAssertNil(try select(300), "Measured exit beyond the surface releases")
        }
    }

    func testSnapFractionalDrawnAngleAndConfirmationFollowSurfaceRatherThanFineSegments() throws {
        let a = PolarMetricGridCell(ring: 7, angularIndex: 32)
        let b = PolarMetricGridCell(ring: 7, angularIndex: 33)
        let compiled = try snapInstrument([a, b], ownNotes: [b: 64], snap: 6, confirmation: 2)
        var pipeline = SpatialDetectionPipeline()
        func select(_ tick: Int) throws -> PolarDeviceLattice? {
            pipeline.select(frame: try frame([tick: 180]), instrument: compiled, contour: nil).activeHandles[layerID]?.cell
        }
        let entered = try XCTUnwrap(select(181))
        // At tick 195 the arc is 5.89 cm from the drawn edge (191.25),
        // rather than 6.28 cm from the last painted tick (191).
        XCTAssertEqual(try select(195), entered)
        XCTAssertEqual(try select(196), entered)
        XCTAssertEqual(try select(197)?.sector, 197, "Two moving fine candidates in one surface confirm together")
    }

    func testSnapZeroPreservesImmediateFineSelectionAndOldPresetKeyKeepsValue() throws {
        let a = PolarMetricGridCell(ring: 4, angularIndex: 16)
        let compiled = try snapInstrument([a], snap: 0)
        var pipeline = SpatialDetectionPipeline()
        XCTAssertEqual(pipeline.select(frame: try frame([185: 101]), instrument: compiled, contour: nil).activeHandles[layerID]?.cell.ring, 101)
        XCTAssertEqual(pipeline.select(frame: try frame([185: 110]), instrument: compiled, contour: nil).activeHandles[layerID]?.cell.ring, 110)
        XCTAssertTrue(pipeline.select(frame: try frame([185: 125]), instrument: compiled, contour: nil).isEmpty)
        let legacy = Data(#"{"boundaryMarginCentimeters":4,"confirmationProfiles":2}"#.utf8)
        let restored = try JSONDecoder().decode(DetectionCellSelection.self, from: legacy)
        XCTAssertEqual(restored.boundaryMarginCentimeters, 4)
        XCTAssertEqual(try JSONDecoder().decode(DetectionCellSelection.self, from: JSONEncoder().encode(restored)), restored)
        XCTAssertEqual(DetectionCellSelection(boundaryMarginCentimeters: 20).boundaryMarginCentimeters, 10)
        let ten = try snapInstrument([a], snap: 10)
        XCTAssertEqual(ten.detection.cellSelection.boundaryMarginCentimeters, 10)
        pipeline.reset()
        let entered = pipeline.select(frame: try frame([185: 101]), instrument: ten, contour: nil).activeHandles[layerID]?.cell
        XCTAssertEqual(pipeline.select(frame: try frame([185: 135]), instrument: ten, contour: nil).activeHandles[layerID]?.cell, entered)
        XCTAssertTrue(pipeline.select(frame: try frame([185: 136]), instrument: ten, contour: nil).isEmpty)
    }

    func testSnapConcaveSurfaceDoesNotFillItsHoleOrJoinDisconnectedEqualContents() throws {
        let addresses = [PolarMetricGridCell(ring: 4, angularIndex: 16),
            .init(ring: 4, angularIndex: 17), .init(ring: 5, angularIndex: 16), .init(ring: 4, angularIndex: 20)]
        let compiled = try snapInstrument(addresses)
        var pipeline = SpatialDetectionPipeline()
        let entered = pipeline.select(frame: try frame([185: 101]), instrument: compiled, contour: nil).activeHandles[layerID]?.cell
        XCTAssertEqual(pipeline.select(frame: try frame([200: 124]), instrument: compiled, contour: nil).activeHandles[layerID]?.cell, entered)
        XCTAssertTrue(pipeline.select(frame: try frame([214: 136]), instrument: compiled, contour: nil).isEmpty,
            "The missing inner corner is outside both arms of the L")
        _ = pipeline.select(frame: try frame([185: 101]), instrument: compiled, contour: nil)
        XCTAssertEqual(pipeline.select(frame: try frame([275: 110]), instrument: compiled, contour: nil).activeHandles[layerID]?.cell.sector, 275,
            "A disconnected equal-content island has its own Snap boundary")
    }

    func testSnapKeepsAtLeastTheDrawnCellWhenProgramVariesAcrossItsFineRays() throws {
        let a = PolarMetricGridCell(ring: 4, angularIndex: 16)
        let programs: [SpatialValueProgram] = [
            .scale(rootMIDINote: 60, lowestMIDINote: 60, highestMIDINote: 84, scale: .chromatic,
                   directionDegrees: 90, ascending: true, transition: .legato),
            .randomScale(rootMIDINote: 60, lowestMIDINote: 60, highestMIDINote: 84, scale: .chromatic,
                         seed: 7, transition: .legato),
            .continuous(minimum: 0, maximum: 1, directionDegrees: 90, curve: .linear)
        ]
        for program in programs {
            let compiled = try snapInstrument([a], program: program)
            var pipeline = SpatialDetectionPipeline()
            let entered = pipeline.select(frame: try frame([185: 101]), instrument: compiled, contour: nil).activeHandles[layerID]?.cell
            XCTAssertEqual(pipeline.select(frame: try frame([185: 124]), instrument: compiled, contour: nil).activeHandles[layerID]?.cell, entered)
            XCTAssertEqual(pipeline.select(frame: try frame([185: 130]), instrument: compiled, contour: nil).activeHandles[layerID]?.cell, entered)
            XCTAssertTrue(pipeline.select(frame: try frame([185: 131]), instrument: compiled, contour: nil).isEmpty)
        }
    }

    func testSnapDrawnContentBoundariesRemainIndependentPerLayer() throws {
        let a = try LegacyLatticeMigration.migrate(.init(ring: 4, angularIndex: 16), in: .quarterMeter).cells
        let b = try LegacyLatticeMigration.migrate(.init(ring: 5, angularIndex: 16), in: .quarterMeter).cells
        let secondID = UUID(), target = SpatialRoutingTarget.midiNote(channel: 0)
        func layer(_ id: UUID, split: Bool) -> SpatialDocumentLayer {
            .init(id: id, name: "Independent Snap", color: .orange, isVisible: true, isActive: true,
                isLocked: false, isSoloed: false, cells: a.union(b),
                routings: [.init(target: target, program: .singleNote(note: 60, velocity: 90, transition: .legato))],
                cellOverrides: split ? Dictionary(uniqueKeysWithValues: b.map { ($0, [.init(target: target, value: .note(number: 64, velocity: 90))]) }) : [:])
        }
        let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2,
            layers: [layer(layerID, split: false), layer(secondID, split: true)], selectedLayerID: layerID)
        var config = DetectionConfiguration.allStagesOff
        config.cellSelection = .init(boundaryMarginCentimeters: 5)
        let compiled = try InstrumentCompiler.compile(.init(spatial: spatial, detection: config, revision: .newSession()))
        var pipeline = SpatialDetectionPipeline()
        _ = pipeline.select(frame: try frame([185: 101]), instrument: compiled, contour: nil)
        let moved = pipeline.select(frame: try frame([185: 131]), instrument: compiled, contour: nil)
        XCTAssertEqual(moved.activeHandles[layerID]?.cell.ring, 101)
        XCTAssertEqual(moved.activeHandles[secondID]?.cell.ring, 131)
        let held = pipeline.select(frame: try frame([185: 155]), instrument: compiled, contour: nil)
        XCTAssertEqual(held.activeHandles[layerID]?.cell.ring, 101)
        XCTAssertEqual(held.activeHandles[secondID]?.cell.ring, 131)
        XCTAssertTrue(pipeline.select(frame: try frame([185: 156]), instrument: compiled, contour: nil).isEmpty)
    }

    func testSnapPartialImportedMaskUsesTheProjectedDrawnCell() throws {
        // Frozen imported surface: its explicit 25-cm raster is part of this oracle.
        let painted = PolarDeviceLattice(ring: 80, sector: 200)!
        let layer = SpatialDocumentLayer(id: layerID, name: "Partial import", color: .orange,
            isVisible: true, isActive: true, isLocked: false, isSoloed: false, cells: [painted],
            routings: [.init(target: .midiNote(channel: 0), program: .singleNote(note: 60, velocity: 90, transition: .toggle))], cellOverrides: [:])
        let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layerID)
        var config = DetectionConfiguration.allStagesOff
        config.cellSelection = .init(boundaryMarginCentimeters: 5)
        let compiled = try InstrumentCompiler.compile(.init(spatial: spatial, detection: config, revision: .newSession(), editorGrid: .quarterMeter))
        var pipeline = SpatialDetectionPipeline()
        _ = pipeline.select(frame: try frame([200: 80]), instrument: compiled, contour: nil)
        let held = pipeline.select(frame: try frame([200: 105]), instrument: compiled, contour: nil)
        XCTAssertEqual(held.activeHandles[layerID]?.cell, painted)
        XCTAssertEqual(held.sceneControlHandles.first?.cell, painted)
        XCTAssertTrue(pipeline.select(frame: try frame([200: 106]), instrument: compiled, contour: nil).isEmpty)
        _ = pipeline.select(frame: try frame([200: 80]), instrument: compiled, contour: nil)
        XCTAssertEqual(pipeline.select(frame: try frame([208: 80]), instrument: compiled, contour: nil).activeHandles[layerID]?.cell, painted)
        XCTAssertTrue(pipeline.select(frame: try frame([211: 80]), instrument: compiled, contour: nil).isEmpty)
    }

    func testSnapExactRadialMarginAtNonBinaryGridEdgeStillHolds() throws {
        let compiled = try snapInstrument([.init(ring: 3, angularIndex: 16)], grid: .tenCentimeter)
        var pipeline = SpatialDetectionPipeline()
        let entered = pipeline.select(frame: try frame([185: 35]), instrument: compiled, contour: nil).activeHandles[layerID]?.cell
        XCTAssertNotNil(entered)
        XCTAssertEqual(pipeline.select(frame: try frame([185: 25]), instrument: compiled, contour: nil).activeHandles[layerID]?.cell, entered)
        XCTAssertTrue(pipeline.select(frame: try frame([185: 24]), instrument: compiled, contour: nil).isEmpty)
    }

    func testSnapUnconfirmedToggleCandidateCannotHoldAndFireAfterReturning() throws {
        let a = PolarMetricGridCell(ring: 4, angularIndex: 16), b = PolarMetricGridCell(ring: 5, angularIndex: 16)
        let compiled = try snapInstrument([a, b], ownNotes: [b: 64], confirmation: 2)
        var pipeline = SpatialDetectionPipeline()
        func select(_ raw: UInt16) throws -> DeviceLatticeSelection {
            pipeline.select(frame: try frame([185: raw]), instrument: compiled, contour: nil)
        }
        let entered = try select(101)
        XCTAssertTrue(entered.sceneControlHandles.isEmpty)
        XCTAssertEqual(try select(101).sceneControlHandles.first?.cell.ring, 101)
        let pending = try select(131)
        XCTAssertEqual(pending.activeHandles[layerID]?.cell.ring, 101)
        XCTAssertTrue(pending.sceneControlHandles.isEmpty)
        let returned = try select(124)
        XCTAssertEqual(returned.activeHandles[layerID]?.cell.ring, 101)
        XCTAssertTrue(returned.sceneControlHandles.isEmpty, "Returning cannot confirm the cell that has been left")
        XCTAssertEqual(returned.measuredEntryHandles.first?.cell.ring, 124)
    }
    func testOwnerRun2EveryRepresentativeModePreservesBothMMKSpansWithGroupingOnAndOff() throws {
        for count in [90, 361] {
            let firstIndex = count == 90 ? 20 : 79
            let firstID = UUID(), secondID = UUID()
            let layers = [(firstID, 79, 100...103), (secondID, count == 90 ? 83 : 80, 130...133)].map { id, tick, rings in
                SpatialDocumentLayer(id: id, name: "Span edge", color: .blue, isVisible: true, isActive: true,
                    isLocked: false, isSoloed: false, cells: Set(rings.map { PolarDeviceLattice(ring: $0, sector: tick)! }),
                    routings: [], cellOverrides: [:])
            }
            let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: layers, selectedLayerID: firstID)
            for grouping in [true, false] {
                for mode in DetectionRepresentativeMode.allCases {
                    let config = DetectionConfiguration(temporalSmoothing: .mean(window: 3), groupingEnabled: grouping,
                        representative: mode, representativeOffsetCentimeters: 3, minimumAngleDegrees: 0)
                    let compiled = try InstrumentCompiler.compile(.init(spatial: spatial, detection: config, revision: .newSession()))
                    var pipeline = SpatialDetectionPipeline()
                    let selected = pipeline.select(frame: try frame([firstIndex: 100, firstIndex + 1: 130], count: count), instrument: compiled, contour: nil)
                    XCTAssertEqual(selected.activeHandles.count, 2, "\(count) \(mode) grouping=\(grouping)")
                    XCTAssertEqual(selected.activeHandles[firstID]?.cell.sector, 79)
                    XCTAssertEqual(selected.activeHandles[secondID]?.cell.sector, count == 90 ? 83 : 80)
                }
            }
        }
    }
    func testOwnerRun2ConfirmationAndHysteresisRemainIndependentPerLayerFor90And361() throws {
        for count in [90, 361] {
            let firstIndex = count == 90 ? 20 : 79
            let secondIndex = count == 90 ? 30 : 120
            let firstID = UUID(), secondID = UUID()
            func layer(_ id: UUID, tick: Int, distances: [Int]) -> SpatialDocumentLayer {
                let target = SpatialRoutingTarget.midiNote(channel: 0)
                return .init(id: id, name: "Independent object", color: .blue, isVisible: true, isActive: true,
                    isLocked: false, isSoloed: false,
                    cells: Set(distances.map { PolarDeviceLattice(ring: $0, sector: tick)! }),
                    routings: [.init(target: target, program: .singleNote(note: 60, velocity: 90, transition: .legato))],
                    cellOverrides: [PolarDeviceLattice(ring: distances[1], sector: tick)!: [.init(target: target, value: .note(number: 64, velocity: 90))]])
            }
            let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [
                layer(firstID, tick: 79, distances: [100, 130]),
                layer(secondID, tick: 120, distances: [130, 160])], selectedLayerID: firstID)
            let compiled = try InstrumentCompiler.compile(.init(spatial: spatial,
                detection: .init(groupingEnabled: true, representative: .nearestPoint,
                                 cellSelection: .init(boundaryMarginCentimeters: 2, confirmationProfiles: 2), minimumAngleDegrees: 0), revision: .newSession()))
            var pipeline = SpatialDetectionPipeline()
            func select(_ a: UInt16, _ b: UInt16, _ sequence: UInt64) throws -> DeviceLatticeSelection {
                pipeline.select(frame: try frame([firstIndex: a, secondIndex: b], count: count, sequence: sequence), instrument: compiled, contour: nil)
            }
            let initial = try select(100, 130, 1)
            XCTAssertEqual(initial.activeHandles.count, 2)
            let pending = try select(130, 160, 2)
            XCTAssertEqual(pending.activeHandles[firstID]?.cell.ring, 100)
            XCTAssertEqual(pending.activeHandles[secondID]?.cell.ring, 130)
            let firstConfirmed = try select(130, 130, 3)
            XCTAssertEqual(firstConfirmed.activeHandles[firstID]?.cell.ring, 130)
            XCTAssertEqual(firstConfirmed.activeHandles[secondID]?.cell.ring, 130)
            XCTAssertEqual(try select(130, 160, 4).activeHandles[secondID]?.cell.ring, 130)
            XCTAssertEqual(try select(130, 160, 5).activeHandles[secondID]?.cell.ring, 160)
        }
    }
    func testSmoothingOffOnPreservesStoredMethodAndNextFrameUsesItFor90And361() throws {
        for count in [90, 361] {
            for method in [DetectionTemporalSmoothing.mean(window: 7), .median(window: 5), .exponential(alpha: 0.3)] {
                var settings = DetectionConfiguration(temporalSmoothing: method, groupingJumpCentimeters: 19,
                    groupingMinimumPoints: 2, representativeOffsetCentimeters: 7)
                settings.setSmoothingEnabled(false)
                XCTAssertEqual(settings.temporalSmoothing, method)
                let saved = try JSONEncoder().encode(settings)
                settings = try JSONDecoder().decode(DetectionConfiguration.self, from: saved)
                XCTAssertFalse(settings.smoothingEnabled)
                XCTAssertEqual(settings.temporalSmoothing, method)
                XCTAssertEqual(settings.groupingJumpCentimeters, 19)
                settings.groupingEnabled = false
                var pipeline = SpatialDetectionPipeline()
                let index = count / 2
                _ = pipeline.select(frame: try frame([index: 100], count: count), instrument: try instrument(settings), contour: nil)
                _ = pipeline.select(frame: try frame([index: 100], count: count, sequence: 2), instrument: try instrument(settings), contour: nil)
                let selected = pipeline.select(frame: try frame([index: 110], count: count, sequence: 3), instrument: try instrument(settings), contour: nil)
                XCTAssertEqual(selected.representative?.distanceCentimeters ?? -1, 110, accuracy: 0.001)
                settings.setSmoothingEnabled(true)
                XCTAssertEqual(settings.temporalSmoothing, method)
                _ = pipeline.select(frame: try frame([index: 100], count: count, sequence: 2), instrument: try instrument(settings), contour: nil)
                _ = pipeline.select(frame: try frame([index: 100], count: count, sequence: 3), instrument: try instrument(settings), contour: nil)
                let smoothed = pipeline.select(frame: try frame([index: 110], count: count, sequence: 4), instrument: try instrument(settings), contour: nil)
                XCTAssertLessThan(smoothed.representative?.distanceCentimeters ?? 999, 110)
            }
        }
    }
    private let layerID = UUID(), session = UUID()
    private func instrument(_ configuration: DetectionConfiguration) throws -> CompiledInstrument {
        // D1–D9 historical boundaries were specified in the 25-cm editor projection.
        let cells = Set((50...180).flatMap { raw in (0...360).compactMap { PolarDeviceLattice(tick: $0, rawCentimeters: UInt16(raw)) } })
        let layer = SpatialDocumentLayer(id: layerID, name: "Detection", color: .blue, isVisible: true,
            isActive: true, isLocked: false, isSoloed: false, cells: cells, routings: [], cellOverrides: [:])
        let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layerID)
        return try InstrumentCompiler.compile(.init(spatial: spatial, detection: configuration, revision: .newSession(), editorGrid: .quarterMeter))
    }
    private func frame(_ samples: [Int: UInt16], count: Int = 361, sequence: UInt64 = 1) throws -> ProfileFrame {
        let raw = try B0ScanProfile.build(partialScanIndex: 0, measurements: (0..<count).map { try .build(value: samples[$0] ?? 8191, fieldFlags: 0) })
        return .init(sessionID: session, sequence: sequence, time: Double(sequence) / 25,
            measurements: try FullScanProfileAdapter.measurements(from: raw), geometry: try FullScanProfileAdapter.geometry(from: raw), rawProfile: raw)
    }
    func testD1RadialTraversalAndD2AngularTraversalUseExactProductionCells() throws {
        let compiled = try instrument(.ownerDefaults)
        var pipeline = SpatialDetectionPipeline()
        for raw in 50...150 {
            let result = pipeline.select(frame: try frame([180: UInt16(raw)]), instrument: compiled, contour: nil)
            XCTAssertEqual(result.activeHandles[layerID]?.cell, PolarDeviceLattice(tick: 180, rawCentimeters: UInt16(raw)))
        }
        for raw in [80, 120, 180] {
            for tick in 140...220 {
                let result = pipeline.select(frame: try frame([tick: UInt16(raw)]), instrument: compiled, contour: nil)
                XCTAssertEqual(result.activeHandles[layerID]?.cell, PolarDeviceLattice(tick: tick, rawCentimeters: UInt16(raw)))
            }
        }
    }
    func testD3RepresentativesGroupingMinimumJumpAndOffsetAffectCompiledSelection() throws {
        let input = try frame([179: 80, 180: 100, 181: 100])
        var config = DetectionConfiguration(groupingEnabled: true, groupingJumpCentimeters: 30, groupingMinimumPoints: 2, representative: .mean)
        var pipeline = SpatialDetectionPipeline()
        let mean = pipeline.select(frame: input, instrument: try instrument(config), contour: nil)
        XCTAssertEqual(mean.candidateDistancesCentimeters[layerID], 100)
        config.representative = .nearestPoint
        XCTAssertEqual(pipeline.select(frame: input, instrument: try instrument(config), contour: nil).candidateDistancesCentimeters[layerID], 80)
        config.representative = .nearestPointWithOffset; config.representativeOffsetCentimeters = 5
        XCTAssertEqual(pipeline.select(frame: input, instrument: try instrument(config), contour: nil).candidateDistancesCentimeters[layerID], 85)
        config.groupingJumpCentimeters = 5; config.representative = .nearestPoint
        XCTAssertEqual(pipeline.select(frame: input, instrument: try instrument(config), contour: nil).candidateDistancesCentimeters[layerID], 100)
        config.groupingMinimumPoints = 4
        XCTAssertTrue(pipeline.select(frame: input, instrument: try instrument(config), contour: nil).isEmpty)
    }
    func testD4AllStagesOffMatchesRawCompiledSelection() throws {
        let compiled = try instrument(.allStagesOff), input = try frame([100: 90, 180: 100, 220: 80])
        var pipeline = SpatialDetectionPipeline(), selector = DeviceLatticeSelector()
        XCTAssertEqual(pipeline.select(frame: input, instrument: compiled, contour: nil).activeHandles,
            selector.step(measurements: input.measurements, instrument: compiled, geometry: input.geometry, configuration: .disabled).activeHandles)
    }
    func testD5BoundaryAndD6ConfirmationOperateOnTheCompiledPath() throws {
        let held = try instrument(.ownerDefaults.replacingCellSelection(.init(boundaryMarginCentimeters: 2, confirmationProfiles: 1)))
        var pipeline = SpatialDetectionPipeline()
        let initial = pipeline.select(frame: try frame([180: 99]), instrument: held, contour: nil).activeHandles[layerID]?.cell
        XCTAssertEqual(pipeline.select(frame: try frame([180: 101]), instrument: held, contour: nil).activeHandles[layerID]?.cell, initial)
        XCTAssertEqual(pipeline.select(frame: try frame([180: 103]), instrument: held, contour: nil).activeHandles[layerID]?.cell, initial,
            "No effective-content boundary inside this painted surface")
        XCTAssertEqual(pipeline.select(frame: try frame([180: 202]), instrument: held, contour: nil).activeHandles[layerID]?.cell, initial)
        XCTAssertTrue(pipeline.select(frame: try frame([180: 203]), instrument: held, contour: nil).isEmpty)
        let confirmed = try instrument(.ownerDefaults.replacingCellSelection(.init(boundaryMarginCentimeters: 0, confirmationProfiles: 2)))
        pipeline.reset()
        let old = pipeline.select(frame: try frame([180: 99]), instrument: confirmed, contour: nil).activeHandles[layerID]?.cell
        XCTAssertEqual(pipeline.select(frame: try frame([180: 103], sequence: 2), instrument: confirmed, contour: nil).activeHandles[layerID]?.cell, old)
        XCTAssertNotEqual(pipeline.select(frame: try frame([180: 103], sequence: 3), instrument: confirmed, contour: nil).activeHandles[layerID]?.cell, old)
        pipeline.reset()
        _ = pipeline.select(frame: try frame([180: 99]), instrument: confirmed, contour: nil)
        _ = pipeline.select(frame: try frame([180: 103], sequence: 2), instrument: confirmed, contour: nil)
        XCTAssertEqual(pipeline.select(frame: try frame([180: 110], sequence: 3), instrument: confirmed, contour: nil).activeHandles[layerID]?.cell, old,
            "A different candidate must begin its own consecutive confirmation")
        XCTAssertEqual(pipeline.select(frame: try frame([180: 110], sequence: 4), instrument: confirmed, contour: nil).activeHandles[layerID]?.cell,
            PolarDeviceLattice(tick: 180, rawCentimeters: 110))
    }
    func testD7AllSmoothingModesAndD9LiveConfigurationUseNextCompiledFrame() throws {
        for (mode, expected) in [(DetectionTemporalSmoothing.mean(window: 3), 100.0 + 10.0 / 3.0), (.median(window: 3), 100.0), (.exponential(alpha: 0.5), 105.0)] {
            let compiled = try instrument(.ownerDefaults.replacingTemporalSmoothing(mode))
            var pipeline = SpatialDetectionPipeline()
            _ = pipeline.select(frame: try frame([180: 100]), instrument: compiled, contour: nil)
            _ = pipeline.select(frame: try frame([180: 100], sequence: 2), instrument: compiled, contour: nil)
            let result = pipeline.select(frame: try frame([180: 110], sequence: 3), instrument: compiled, contour: nil)
            XCTAssertEqual(result.representative?.distanceCentimeters ?? -1, expected, accuracy: 0.01)
            let changed = try instrument(.ownerDefaults.replacingTemporalSmoothing(.off))
            XCTAssertEqual(pipeline.select(frame: try frame([180: 110], sequence: 4), instrument: changed, contour: nil).representative?.distanceCentimeters ?? -1, 110, accuracy: 0.01)
        }
    }
    func testExponentialSmoothingUsesItsPreviousFilteredValue() throws {
        let compiled = try instrument(.ownerDefaults.replacingTemporalSmoothing(.exponential(alpha: 0.5)))
        var pipeline = SpatialDetectionPipeline()
        _ = pipeline.select(frame: try frame([180: 100]), instrument: compiled, contour: nil)
        _ = pipeline.select(frame: try frame([180: 110], sequence: 2), instrument: compiled, contour: nil)
        XCTAssertEqual(pipeline.select(frame: try frame([180: 120], sequence: 3), instrument: compiled, contour: nil).representative?.distanceCentimeters ?? -1, 112.5, accuracy: 0.01)
    }
    func testD8DocumentRoundtripKeepsEveryControlAndCompilerReceivesIt() throws {
        let configuration = DetectionConfiguration(temporalSmoothing: .median(window: 4),
            groupingEnabled: false, groupingJumpCentimeters: 17, groupingMinimumPoints: 3,
            representative: .nearestPointWithOffset, representativeOffsetCentimeters: 7,
            cellSelection: .init(boundaryMarginCentimeters: 3, confirmationProfiles: 2),
            continuousBacklashCentimeters: 2, roomContour: .init(isEnabled: true, toleranceCentimeters: 9))
        let layer = SpatialDocumentLayer(id: layerID, name: "Stored", color: .blue, isVisible: true,
            isActive: true, isLocked: false, isSoloed: false, cells: [], routings: [], cellOverrides: [:])
        let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layerID)
        let document = InstrumentDocument(spatial: spatial, detection: configuration, revision: .newSession())
        let restored = try JSONDecoder().decode(InstrumentDocument.self, from: JSONEncoder().encode(document))
        var persisted = configuration; persisted.roomContour = .init()
        XCTAssertEqual(restored.detection, persisted)
        XCTAssertEqual(try InstrumentCompiler.compile(restored).detection, persisted)
        XCTAssertEqual(try InstrumentCompiler.compile(document).detection, configuration, "The live compiler still receives runtime contour controls")
    }
    func testRoomContourFiltersMatchingGeometryAndMismatchRemainsVisible() throws {
        let compiled = try instrument(.init(roomContour: .init(isEnabled: true, toleranceCentimeters: 5)))
        let input = try frame([180: 100])
        func contour(start: Double) -> SpatialRoomContour {
            .init(geometry: .init(pointCount: 361, angleResolutionDegrees: 0.5, startAngleDegrees: start, sourceIdentifier: "scanner:default"),
                nearestDistancesCentimeters: Array(repeating: 100, count: 361), spreadCentimeters: Array(repeating: 0, count: 361))
        }
        var pipeline = SpatialDetectionPipeline()
        let filtered = pipeline.select(frame: input, instrument: compiled, contour: contour(start: -90))
        XCTAssertTrue(filtered.isEmpty); XCTAssertEqual(filtered.filteredOrders, [180]); XCTAssertTrue(filtered.contourMatches)
        let mismatch = pipeline.select(frame: input, instrument: compiled, contour: contour(start: 0))
        XCTAssertFalse(mismatch.isEmpty); XCTAssertFalse(mismatch.contourMatches)
        XCTAssertFalse(pipeline.select(frame: try frame([180: 80]), instrument: compiled, contour: contour(start: -90)).isEmpty)
    }
}


extension CompiledDetectionContractTests {
    func testDetectionPreviewReusesMusicalIndexAndPreservesAllOtherCompiledSettings() throws {
        let original = try snapInstrument([.init(ring: 2, angularIndex: 180)]).stampingScene(generation: 42, replacing: true)
        var configuration = original.detection
        configuration.groupingJumpCentimeters = 23
        let preview = original.previewingDetection(configuration)
        XCTAssertEqual(preview.detection, configuration)
        XCTAssertNotEqual(original.detection, configuration)
        XCTAssertEqual(preview.previewingDetection(original.detection), original)
        for tick in 0...360 {
            XCTAssertEqual(preview.hits(tick: tick, raw: 60), original.hits(tick: tick, raw: 60))
        }
    }
}
