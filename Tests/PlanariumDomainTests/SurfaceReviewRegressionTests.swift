import XCTest
@testable import PlanariumDomain

/// Supervisor review 24.10. (FLÄCHENEDITOR-KERN-1): four measured defects and their neighbours.
/// Origin: `.agent_handoff/runs/surface-core-1/SurfaceSupervisorCounterprobeTests.swift`.
final class SurfaceReviewRegressionTests: XCTestCase {
    private func cell(_ ring: Int, _ tick: Int) -> PolarDeviceLattice { PolarDeviceLattice(ring: ring, sector: tick)! }
    private func layer(_ id: UUID = UUID(), surfaces: [SpatialSurface]) -> SpatialDocumentLayer {
        .init(id: id, name: "L", color: .orange, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
              cells: [], routings: [], cellOverrides: [:], surfaces: surfaces)
    }
    private func document(_ layers: [SpatialDocumentLayer]) throws -> InstrumentDocument {
        InstrumentDocument(spatial: try SpatialDocument(latticeVersion: .polarDeviceV2, layers: layers, selectedLayerID: layers[0].id),
                           detection: .allStagesOff, revision: .init(session: UUID(), counter: 1))
    }
    private func rect(_ routing: SpatialRouting) throws -> SpatialSurface {
        try SpatialSurface(presentation: .init(name: "r", color: .orange),
                           form: .shape(.rectangle(widthCm: 40, heightCm: 20), .init(xCm: 0, yCm: 100)), routings: [routing])
    }
    private func position(_ c: PolarDeviceLattice) -> (x: Double, y: Double) {
        let p = SurfaceGrid.point(ring: c.ring, tick: c.sector); return (p.x, p.y)
    }
    private func scalar(_ v: SpatialEvaluatedValue) -> Double {
        if case .scalar(let value) = v { return value }
        XCTFail("not a scalar"); return .nan
    }
    private func curved(_ curve: SpatialValueCurve, _ f: Double) -> Double {
        switch curve {
        case .linear: return f
        case .easeIn: return f * f
        case .easeOut: return 1 - (1 - f) * (1 - f)
        }
    }

    // MARK: 1 — the arrow, the fraction and the legend follow the real course of the value

    func testInverseCCArrowPointsTowardTheHigherValue() throws {
        let routing = SpatialRouting(target: .midiCC(channel: 0, controller: 74),
                                     program: .continuous(minimum: 1, maximum: 0, directionDegrees: 0, curve: .easeIn))
        let s = try rect(routing)
        let field = try SurfaceValueField(surface: s, routingID: routing.id)
        XCTAssertEqual(SurfaceAxis.normalized(try XCTUnwrap(field.arrowDegrees)), 180)
        let left = s.cells.min { position($0).x < position($1).x }!, right = s.cells.max { position($0).x < position($1).x }!
        XCTAssertGreaterThan(field.arrowFraction(left), field.arrowFraction(right))
        XCTAssertGreaterThan(scalar(field.sample(left).value), scalar(field.sample(right).value), "the value really is higher at the tip")
    }

    /// Every direction, both range orders and all curves: the independent world-space oracle says where
    /// the value is high; the arrow, its fraction and the legend must agree with it.
    func testArrowFractionAndLegendAgreeWithTheRealCourseForEveryRangeCurveAndDirection() throws {
        for (low, high) in [(0.0, 1.0), (1.0, 0.0), (0.2, 0.7), (0.9, 0.3)] {
            for curve in SpatialValueCurve.allCases {
                for direction in [0.0, 90, 180, -90, 45, -135] {
                    let routing = SpatialRouting(target: .midiCC(channel: 0, controller: 1),
                        program: .continuous(minimum: low, maximum: high, directionDegrees: direction, curve: curve))
                    let s = try rect(routing)
                    let field = try SurfaceValueField(surface: s, routingID: routing.id)
                    let label = "\(low)→\(high) \(curve) \(direction)°"
                    let arrow = try XCTUnwrap(field.arrowDegrees)
                    // Oracle for the arrow: the cell with the larger value lies further along the arrow.
                    let ax = cos(arrow * .pi / 180), ay = sin(arrow * .pi / 180)
                    let along = s.cells.map { c -> (cell: PolarDeviceLattice, p: Double) in
                        let p = position(c); return (c, p.x * ax + p.y * ay)
                    }
                    let start = along.min { $0.p < $1.p }!.cell, tip = along.max { $0.p < $1.p }!.cell
                    XCTAssertEqual(field.arrowFraction(start), 0, accuracy: 0.02, label)
                    XCTAssertEqual(field.arrowFraction(tip), 1, accuracy: 0.02, label)
                    XCTAssertGreaterThanOrEqual(scalar(field.sample(tip).value), scalar(field.sample(start).value) - 1e-9, label)
                    for c in s.cells.prefix(300) {
                        let g = field.arrowFraction(c)
                        guard case .continuous(_, let legendStart, let legendEnd, let legendCurve) = field.legend else {
                            return XCTFail("no continuous legend")
                        }
                        // The legend, read as start + (end − start)·curve(g), reproduces the compiled value.
                        XCTAssertEqual(legendStart + (legendEnd - legendStart) * curved(legendCurve, g),
                                       scalar(field.sample(c).value), accuracy: 1e-9, "\(label) legend")
                    }
                    guard case .continuous(_, let legendStart, let legendEnd, _) = field.legend else { return XCTFail() }
                    XCTAssertEqual(max(low, high), max(legendStart, legendEnd), label)
                    XCTAssertEqual(low <= high ? high : low, legendEnd, "the tip carries the higher value (\(label))")
                }
            }
        }
    }

    func testDescendingAndAscendingScaleArrowsPointTowardTheHigherNote() throws {
        for ascending in [true, false] {
            for direction in [0.0, 90, 180, -45] {
                let routing = SpatialRouting(target: .midiNote(channel: 0), program: .scale(rootMIDINote: 60, lowestMIDINote: 48,
                    highestMIDINote: 84, scale: .major, directionDegrees: direction, ascending: ascending, transition: .retrigger))
                let s = try rect(routing)
                let field = try SurfaceValueField(surface: s, routingID: routing.id)
                func note(_ c: PolarDeviceLattice) -> Int {
                    if case .notes(let notes, _) = field.sample(c).value { return Int(notes.first!.number) }
                    XCTFail(); return -1
                }
                let arrow = try XCTUnwrap(field.arrowDegrees)
                let ax = cos(arrow * .pi / 180), ay = sin(arrow * .pi / 180)
                let sorted = s.cells.sorted { position($0).x * ax + position($0).y * ay < position($1).x * ax + position($1).y * ay }
                let label = "ascending \(ascending) \(direction)°"
                XCTAssertLessThan(note(sorted.first!), note(sorted.last!), label)
                XCTAssertLessThan(field.arrowFraction(sorted.first!), field.arrowFraction(sorted.last!), label)
                // Cells whose projections tie (to rounding) may sit on either side of a note boundary.
                func projection(_ c: PolarDeviceLattice) -> Double { position(c).x * ax + position(c).y * ay }
                for (lower, upper) in zip(sorted, sorted.dropFirst()) where projection(upper) - projection(lower) > 1e-6 {
                    XCTAssertGreaterThanOrEqual(note(upper), note(lower) - 0, label)
                }
                guard case .scale(let notes) = field.legend else { return XCTFail("no scale legend") }
                XCTAssertEqual(notes.first, notes.min())
                XCTAssertEqual(note(sorted.last!), notes.last, label)
            }
        }
    }

    func testAssignmentsWithoutACourseHaveNoArrow() throws {
        for program in [SpatialValueProgram.constant(0.5), .singleNote(note: 60, velocity: 100, transition: .retrigger),
                        .chord(notes: [60, 64], velocity: 100, transition: .retrigger), .programChange(.init(program: 3))] {
            let routing = SpatialRouting(target: .midiCC(channel: 0, controller: 1), program: program)
            let field = try SurfaceValueField(surface: try rect(routing), routingID: routing.id)
            XCTAssertNil(field.arrowDegrees); XCTAssertEqual(field.legend, .none); XCTAssertNil(field.projectionCentimeters)
        }
    }

    func testReverseKeepsTheArrowOnTheHigherValueForAnInverseRange() throws {
        let routing = SpatialRouting(target: .midiCC(channel: 0, controller: 1),
                                     program: .continuous(minimum: 1, maximum: 0, directionDegrees: 0, curve: .linear))
        let s = try rect(routing), doc = try document([layer(surfaces: [s])])
        let flipped = try SurfaceEditor.apply(.reverseAxis(surfaceID: s.id, routingID: routing.id), to: doc).spatial.layers[0].surfaces[0]
        let before = try SurfaceValueField(surface: s, routingID: routing.id), after = try SurfaceValueField(surface: flipped, routingID: routing.id)
        XCTAssertEqual(SurfaceAxis.normalized(try XCTUnwrap(before.arrowDegrees) + 180), SurfaceAxis.normalized(try XCTUnwrap(after.arrowDegrees)), accuracy: 1e-9)
    }

    // MARK: 2 — a copied layer releases itself, not the original

    private func selfReleasingLayer(note: Int = 60, other: UUID? = nil) throws -> (layer: SpatialDocumentLayer, noteCell: PolarDeviceLattice, releaseCell: PolarDeviceLattice) {
        let id = UUID(), target = SpatialRoutingTarget.releaseLayer(layerID: id)
        let noteCell = cell(100, 100), releaseCell = cell(100, 120)
        var overrides: [PolarDeviceLattice: [SpatialCellAction]] = [releaseCell: [.init(target: target, value: .releaseLayer(layerID: id))]]
        if let other { overrides[cell(100, 140)] = [.init(target: .releaseLayer(layerID: other), value: .releaseLayer(layerID: other))] }
        var routings = [SpatialRouting(target: .midiNote(channel: 0), program: .singleNote(note: note, velocity: 100, transition: .toggle)),
                        SpatialRouting(target: target, program: .constant(1))]
        if let other { routings.append(SpatialRouting(target: .releaseLayer(layerID: other), program: .constant(1))) }
        let surface = try SpatialSurface(presentation: .init(name: "self", color: .orange),
            form: .legacyMask(.init(cells: Set(overrides.keys).union([noteCell]), cellOverrides: overrides)), routings: routings)
        return (layer(id, surfaces: [surface]), noteCell, releaseCell)
    }

    func testDuplicatedLayerRetargetsItsOwnReleaseAndKeepsForeignReferences() throws {
        let foreign = UUID()
        let (original, _, releaseCell) = try selfReleasingLayer(other: foreign)
        let doc = try document([original])
        let copied = try SurfaceEditor.duplicatingLayer(original.id, in: doc).spatial.layers[1]
        let surface = copied.surfaces[0]
        XCTAssertNotEqual(copied.id, original.id)
        let targets = surface.routings.map(\.target)
        XCTAssertTrue(targets.contains(.releaseLayer(layerID: copied.id)), "own release now names the copy")
        XCTAssertFalse(targets.contains(.releaseLayer(layerID: original.id)), "no reference back to the original")
        XCTAssertTrue(targets.contains(.releaseLayer(layerID: foreign)), "another layer's release stays")
        let own = try XCTUnwrap(surface.cellOverrides[releaseCell]?.first)
        XCTAssertEqual(own.target, .releaseLayer(layerID: copied.id)); XCTAssertEqual(own.value, .releaseLayer(layerID: copied.id))
        let other = try XCTUnwrap(surface.cellOverrides[cell(100, 140)]?.first)
        XCTAssertEqual(other.target, .releaseLayer(layerID: foreign)); XCTAssertEqual(other.value, .releaseLayer(layerID: foreign))
        // The original is untouched.
        XCTAssertEqual(try SurfaceEditor.duplicatingLayer(original.id, in: doc).spatial.layers[0], original)
    }

    /// Compiled: a hand in the copy evaluates a release of the copy, never of the original.
    func testCompiledCopyEvaluatesItsOwnReleaseTarget() throws {
        let (original, noteCell, _) = try selfReleasingLayer()
        let withCopy = try SurfaceEditor.duplicatingLayer(original.id, in: document([original]))
        let copy = withCopy.spatial.layers[1]
        let instrument = try InstrumentCompiler.compile(withCopy)
        let copyPartition = try XCTUnwrap(instrument.layers.first { $0.id == copy.surfaces[0].id })
        let evaluations = try instrument.evaluate(active: [copyPartition.id: CompiledActiveCell(layerID: copyPartition.id, cell: noteCell, revision: instrument.revision)])
        // Partitions without a hand evaluate inactive (false); only the copy's own control fires.
        let released = evaluations.compactMap { evaluation -> UUID? in
            if case .releaseLayer(let id) = evaluation.target, case .boolean(true) = evaluation.value { return id }; return nil
        }
        XCTAssertEqual(released, [copy.id])
    }

    /// Played with fakes: the control layer names the original, so releasing it leaves the (moved,
    /// differently tuned) copy sounding, and the original's note is the one that ends.
    func testReleaseFromAControlLayerEndsTheOriginalOnlyNotItsCopy() throws {
        let session = UUID()
        let noteCell = cell(100, 100), controlCell = cell(100, 120)
        let ownerID = UUID()
        let owner = layer(ownerID, surfaces: [try SpatialSurface(presentation: .init(name: "n", color: .orange), form: .legacyMask(.init(cells: [noteCell])),
            routings: [SpatialRouting(target: .midiNote(channel: 0), program: .singleNote(note: 60, velocity: 100, transition: .toggle))])])
        let control = SpatialDocumentLayer(id: UUID(), name: "Release", color: .blue, isVisible: true, isActive: true, isLocked: false,
            isSoloed: false, cells: [controlCell], routings: [.init(target: .releaseLayer(layerID: ownerID), program: .constant(1))], cellOverrides: [:])
        let base = InstrumentDocument(spatial: try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [owner, control], selectedLayerID: ownerID),
                                      detection: .allStagesOff, revision: .init(session: UUID(), counter: 1))
        let withCopy = try SurfaceEditor.duplicatingLayer(ownerID, in: base)
        let copyLayer = try XCTUnwrap(withCopy.spatial.layers.first { $0.id != ownerID && $0.id != control.id })
        let copySurface = copyLayer.surfaces[0]
        var routings = copySurface.routings
        routings[0].program = .singleNote(note: 72, velocity: 100, transition: .toggle)
        var doc = try SurfaceEditor.apply(.setRoutings(surfaceID: copySurface.id, routings: routings), to: withCopy)
        doc = try SurfaceEditor.apply(.shiftMask(surfaceID: copySurface.id, rings: 20), to: doc)
        let g = ProfileGeometryIdentity(operatingMode: "MMK", pointCount: 90, startAngleDegrees: -90, endAngleDegrees: 90)
        func order(of c: PolarDeviceLattice) -> Int { (0..<90).first { (g.tickSpan(at: $0)!.lower...g.tickSpan(at: $0)!.upper).contains(c.sector) }! }
        func frame(_ t: Double, _ hands: [(Int, UInt16)]) -> ProfileFrame {
            .init(sessionID: session, sequence: UInt64(t * 1000), time: t, measurements: (0..<90).map { o in
                DeviceTickMeasurement(order: o, ticks: g.tickSpan(at: o)!, rawCentimeters: hands.first { $0.0 == o }?.1 ?? 500)!
            }, geometry: g)
        }
        var state = PlayEngine.step(PlayEngine.step(.init(), .install(try InstrumentCompiler.compile(doc))).0, .sessionBegan(session)).0
        func play(_ t: Double, _ hands: [(Int, UInt16)]) -> [MusicEvent] {
            let r = PlayEngine.step(state, .frame(frame(t, hands))); state = r.0; return r.1
        }
        func notes(_ events: [MusicEvent], on: Bool) -> [UInt8] {
            events.compactMap { event -> UInt8? in
                switch (event, on) {
                case (.noteOn(_, _, let n), true), (.noteOff(_, _, let n), false): return n.number
                default: return nil
                }
            }.sorted()
        }
        let n = order(of: noteCell), r = order(of: controlCell)
        XCTAssertEqual(notes(play(10, [(n, 100)]), on: true), [60])
        _ = play(10.01, [])
        XCTAssertEqual(notes(play(10.02, [(n, 120)]), on: true), [72])
        _ = play(10.03, [])
        XCTAssertEqual(state.soundingNoteCount, 2, "both toggled notes are held")
        XCTAssertEqual(notes(play(11, [(r, 100)]), on: false), [60], "the release names the original layer")
        XCTAssertEqual(state.soundingNoteCount, 1, "the copy keeps sounding")
        _ = play(11.01, [])
        XCTAssertEqual(notes(PlayEngine.step(state, .panic).1, on: false), [72], "panic still ends everything")
    }

    // MARK: 3 — absurd offsets are rejections, not crashes

    func testExtremeMaskOffsetsAreRejectedAtomically() throws {
        let c = cell(100, 180)
        let mask = try SpatialSurface(presentation: .init(name: "mask", color: .orange), form: .legacyMask(.init(cells: [c])))
        let doc = try document([layer(surfaces: [mask])])
        for ticks in [Int.max, Int.min, Int.max - 100, 361, -361, 181] {
            XCTAssertThrowsError(try SurfaceEditor.apply(.rotateMask(surfaceID: mask.id, ticks: ticks), to: doc), "ticks \(ticks)")
        }
        for rings in [Int.max, Int.min, Int.max - 50, -100, 100_000] {
            XCTAssertThrowsError(try SurfaceEditor.apply(.shiftMask(surfaceID: mask.id, rings: rings), to: doc), "rings \(rings)")
        }
        XCTAssertEqual(doc.spatial.layers[0].surfaces, [mask])
        // Honest offsets still work, including the largest that stays on the grid.
        XCTAssertEqual(try SurfaceEditor.apply(.rotateMask(surfaceID: mask.id, ticks: 180), to: doc).spatial.layers[0].surfaces[0].cells, [cell(100, 360)])
        XCTAssertEqual(try SurfaceEditor.apply(.rotateMask(surfaceID: mask.id, ticks: -180), to: doc).spatial.layers[0].surfaces[0].cells, [cell(100, 0)])
        XCTAssertEqual(try SurfaceEditor.apply(.shiftMask(surfaceID: mask.id, rings: 5), to: doc).spatial.layers[0].surfaces[0].cells, [cell(105, 180)])
    }

    // MARK: 4 — the surface limit is per layer; the other budgets stay global

    private func masks(_ count: Int) throws -> [SpatialSurface] {
        try (0..<count).map { _ in try SpatialSurface(presentation: .init(name: "m", color: .orange), form: .legacyMask(.init(cells: [cell(100, 180)]))) }
    }
    func testSurfaceLimitCountsPerLayerNotAcrossTheDocument() throws {
        let a = layer(surfaces: try masks(33)), b = layer(surfaces: try masks(33))
        XCTAssertNoThrow(try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [a, b], selectedLayerID: a.id))
    }
    func testExactlySixtyFourSurfacesInOneLayerPassAndSixtyFiveFail() throws {
        let ok = layer(surfaces: try masks(64))
        XCTAssertNoThrow(try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [ok], selectedLayerID: ok.id))
        let tooMany = layer(surfaces: try masks(65))
        XCTAssertThrowsError(try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [tooMany], selectedLayerID: tooMany.id)) {
            XCTAssertEqual($0 as? SpatialDocumentError, .budgetExceeded(.surfacesPerLayer))
        }
    }
    func testPartitionBudgetStillCountsTheWholeDocument() throws {
        let full = try (0..<16).map { _ in layer(surfaces: try masks(64)) }
        XCTAssertNoThrow(try SpatialDocument(latticeVersion: .polarDeviceV2, layers: full, selectedLayerID: full[0].id), "1024 partitions fit")
        let over = full + [layer(surfaces: try masks(1))]
        XCTAssertThrowsError(try SpatialDocument(latticeVersion: .polarDeviceV2, layers: over, selectedLayerID: over[0].id)) {
            XCTAssertEqual($0 as? SpatialDocumentError, .budgetExceeded(.partitions))
        }
    }
    func testEditorAddingTheSixtyFifthSurfaceToALayerIsRejectedAtomically() throws {
        let full = layer(surfaces: try masks(64))
        let doc = try document([full])
        let draft = SurfaceDraft(presentation: .init(name: "x", color: .green), shape: .rectangle(widthCm: 10, heightCm: 10), transform: .init(xCm: 0, yCm: 100))
        XCTAssertThrowsError(try SurfaceEditor.apply(.addSurface(layerID: full.id, draft), to: doc)) {
            XCTAssertEqual($0 as? SurfaceEditError, .document(.budgetExceeded(.surfacesPerLayer)))
        }
    }
}
