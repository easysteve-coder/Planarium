import XCTest
@testable import PlanariumApplication
import PlanariumDomain
import PlanariumPresets
import SickPLSMonitorKit

/// FLÄCHENEDITOR-UI-1: the surface editor's pointer, key and inspector paths, driven the way the field drives them.
@MainActor final class SurfaceEditorModelTests: XCTestCase {
    @MainActor struct Rig {
        let f: RootFixture
        let owner: SpatialInstrumentRuntimeModel
        let editor: SurfaceEditorModel
        let geometry: MetricCanvasGeometry
        var space: SurfaceCanvasSpace { SurfaceCanvasSpace(geometry) }
        func screen(_ x: Double, _ y: Double) -> CGPoint { space.screen(.init(x: x, y: y)) }
        var surfaces: [SpatialSurface] { owner.document.spatial.layers.flatMap(\.surfaces) }
        var sent: Int { f.midi.sends.reduce(0) { $0 + $1.sent.count } }
        func drag(from a: (Double, Double), to b: (Double, Double), modifiers: SurfaceModifiers = []) {
            editor.pointerDown(at: screen(a.0, a.1), geometry: geometry, modifiers: modifiers)
            editor.pointerDragged(to: screen((a.0 + b.0) / 2, (a.1 + b.1) / 2), modifiers: modifiers)
            editor.pointerDragged(to: screen(b.0, b.1), modifiers: modifiers)
            editor.pointerUp(at: screen(b.0, b.1), modifiers: modifiers)
        }
        func click(_ p: (Double, Double), modifiers: SurfaceModifiers = []) {
            editor.pointerDown(at: screen(p.0, p.1), geometry: geometry, modifiers: modifiers)
            editor.pointerUp(at: screen(p.0, p.1), modifiers: modifiers)
        }
    }
    private func rig() throws -> Rig {
        let f = try RootFixture(), owner = f.root.document
        owner.surfaceEditor.setMode(.surfaces)
        return Rig(f: f, owner: owner, editor: owner.surfaceEditor, geometry: owner.canvas.displayGeometry(canvasSize: CGSize(width: 900, height: 700)))
    }

    // MARK: Drawing

    func testEachShapeIsDrawnAsOneSurfaceWithOneUndoStep() throws {
        let r = try rig(); defer { r.f.root.terminate {} }
        let depth = r.owner.historyDepth
        r.editor.select(tool: .rectangle); r.drag(from: (-30, 80), to: (30, 120))
        XCTAssertEqual(r.surfaces.count, 1)
        guard case .shape(.rectangle(let w, let h), let t)? = r.surfaces.first?.form else { return XCTFail("rectangle expected") }
        XCTAssertEqual(w, 60, accuracy: 0.5); XCTAssertEqual(h, 40, accuracy: 0.5)
        XCTAssertEqual(t.xCm, 0, accuracy: 0.5); XCTAssertEqual(t.yCm, 100, accuracy: 0.5)
        XCTAssertEqual(r.owner.historyDepth, depth + 1, "one gesture, one undo step")
        XCTAssertEqual(r.editor.selectedSurfaceIDs, [r.surfaces[0].id], "the new surface is chosen")

        r.editor.select(tool: .circle); r.drag(from: (-80, 100), to: (-60, 100))
        XCTAssertEqual(r.surfaces.count, 2)
        guard case .shape(.circle(let radius), _)? = r.surfaces.last?.form else { return XCTFail("circle expected") }
        XCTAssertEqual(radius, 20, accuracy: 0.5)

        r.editor.select(tool: .ringSector); r.drag(from: (0, 150), to: (60, 120))
        XCTAssertEqual(r.surfaces.count, 3)
        guard case .shape(.ringSector, let identity)? = r.surfaces.last?.form else { return XCTFail("ring sector expected") }
        XCTAssertEqual(identity, .identity, "a ring sector stays centred on the scanner")

        r.editor.select(tool: .polygon)
        for p in [(60.0, 80.0), (100, 80), (100, 130), (60, 120)] { r.click(p) }
        XCTAssertNotNil(r.editor.polygon)
        XCTAssertTrue(r.editor.finishPolygon())
        XCTAssertEqual(r.surfaces.count, 4)
        guard case .shape(.polygon(let points), _)? = r.surfaces.last?.form else { return XCTFail("polygon expected") }
        XCTAssertEqual(points.count, 4)
        XCTAssertEqual(r.owner.historyDepth, depth + 4)
        for _ in 0..<4 { XCTAssertTrue(r.owner.undo()) }
        XCTAssertTrue(r.surfaces.isEmpty)
        XCTAssertEqual(r.sent, 0, "drawing, undoing and previewing never start a note")
    }

    func testAClickWithoutADragNeverDrawsAndAPolygonDraftCanBeTakenBackAndDiscarded() throws {
        let r = try rig(); defer { r.f.root.terminate {} }
        let before = r.owner.document, depth = r.owner.historyDepth
        r.editor.select(tool: .rectangle); r.click((0, 100))
        XCTAssertEqual(r.owner.document, before); XCTAssertEqual(r.owner.historyDepth, depth)
        XCTAssertEqual(r.editor.hint, "Drag to draw a surface")
        r.editor.select(tool: .polygon)
        r.click((0, 80)); r.click((40, 80)); r.click((40, 120))
        XCTAssertEqual(r.editor.polygon?.points.count, 3)
        XCTAssertTrue(r.editor.removeLastPolygonPoint())
        XCTAssertEqual(r.editor.polygon?.points.count, 2)
        XCTAssertFalse(r.editor.finishPolygon(), "two corners are no area")
        XCTAssertNotNil(r.editor.hint)
        XCTAssertTrue(r.editor.cancelEverything())
        XCTAssertNil(r.editor.polygon)
        XCTAssertEqual(r.owner.document, before); XCTAssertEqual(r.owner.historyDepth, depth)
    }

    func testAnInvalidPolygonIsNamedAndNothingIsCommitted() throws {
        let r = try rig(); defer { r.f.root.terminate {} }
        let before = r.owner.document
        r.editor.select(tool: .polygon)
        // A bow tie crosses itself.
        for p in [(0.0, 80.0), (40, 120), (40, 80), (0, 120)] { r.click(p) }
        XCTAssertNotNil(r.editor.polygon?.message)
        XCTAssertFalse(r.editor.finishPolygon())
        XCTAssertEqual(r.owner.document, before)
        XCTAssertNotNil(r.editor.polygon, "the draft stays so the corner can be taken back")
        XCTAssertTrue(r.editor.removeLastPolygonPoint()); XCTAssertTrue(r.editor.removeLastPolygonPoint())
        r.click((60, 100))
        XCTAssertTrue(r.editor.finishPolygon(), "taking corners back repairs the polygon")
        XCTAssertEqual(r.surfaces.count, 1)
    }

    func testDrawingIntoALayerWithOlderCellsPromotesAndAddsInOneUndoStep() throws {
        let r = try rig(); defer { r.f.root.terminate {} }
        let cells = Set((0..<6).flatMap { ring in (0..<6).map { PolarDeviceLattice(ring: 40 + ring, sector: 170 + $0)! } })
        let old = SpatialDocumentLayer(id: UUID(), name: "Old", color: .blue, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
            cells: cells, routings: [.init(target: .midiNote(channel: 0), program: .chord(notes: [60, 64, 67], velocity: 100, transition: .retrigger))], cellOverrides: [:])
        let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [old], selectedLayerID: old.id)
        try r.owner.edit { $0.spatial = spatial }
        let original = r.owner.document, depth = r.owner.historyDepth
        // Looking at the layer and choosing it changes nothing.
        r.editor.select(tool: .select); r.click((0, 45))
        XCTAssertEqual(r.owner.document, original); XCTAssertEqual(r.owner.historyDepth, depth)
        r.editor.select(tool: .rectangle); r.drag(from: (60, 80), to: (100, 120))
        XCTAssertEqual(r.owner.historyDepth, depth + 1, "conversion and the new surface are one step")
        let layer = r.owner.document.spatial.layers.first { $0.id == original.spatial.selectedLayerID }!
        XCTAssertEqual(layer.surfaces.count, 2, "the exact old area and the new surface")
        XCTAssertTrue(r.owner.undo())
        XCTAssertEqual(r.owner.document.spatial.layers, original.spatial.layers, "undo returns the cell layer exactly")
        XCTAssertFalse(r.owner.document.spatial.layers[0].isSurfaceBacked)
    }

    // MARK: Selecting

    func testClickShiftBoxAndEmptyFieldSelectByTheActualShape() throws {
        let r = try rig(); defer { r.f.root.terminate {} }
        r.editor.select(tool: .rectangle); r.drag(from: (-60, 80), to: (-20, 120))
        r.editor.select(tool: .circle); r.drag(from: (60, 100), to: (80, 100))
        let ids = r.surfaces.map(\.id)
        XCTAssertEqual(ids.count, 2)
        r.editor.select(tool: .select)
        r.click((-40, 100)); XCTAssertEqual(r.editor.selectedSurfaceIDs, [ids[0]])
        r.click((60, 100), modifiers: .shift); XCTAssertEqual(r.editor.selectedSurfaceIDs, Set(ids), "shift adds")
        r.click((60, 100), modifiers: .shift); XCTAssertEqual(r.editor.selectedSurfaceIDs, [ids[0]], "shift on a chosen surface takes it out")
        // The corner of the circle's box lies outside the circle itself.
        r.click((75, 115)); XCTAssertEqual(r.editor.selectedSurfaceIDs, [], "empty field clears")
        r.drag(from: (-100, 60), to: (100, 140)); XCTAssertEqual(r.editor.selectedSurfaceIDs, Set(ids), "a box selects what it touches")
        r.click((0, 180)); XCTAssertTrue(r.editor.selectedSurfaceIDs.isEmpty)
        XCTAssertEqual(r.sent, 0)
    }

    // MARK: Gestures

    func testMovingByDragIsOneCommitEscapeAbandonsWithoutTrace() throws {
        let r = try rig(); defer { r.f.root.terminate {} }
        r.editor.select(tool: .rectangle); r.drag(from: (-20, 80), to: (20, 120))
        r.editor.select(tool: .select)
        let before = r.owner.document, depth = r.owner.historyDepth, revision = r.owner.document.revision
        // Escape in the middle of a drag.
        r.editor.pointerDown(at: r.screen(0, 100), geometry: r.geometry, modifiers: [])
        r.editor.pointerDragged(to: r.screen(30, 100), modifiers: [])
        XCTAssertNotNil(r.editor.preview, "a sketch is shown")
        XCTAssertEqual(r.owner.document, before, "the sketch is not in the document")
        XCTAssertTrue(r.editor.cancelGesture())
        r.editor.pointerUp(at: r.screen(30, 100), modifiers: [])
        XCTAssertEqual(r.owner.document, before); XCTAssertEqual(r.owner.historyDepth, depth)
        XCTAssertEqual(r.owner.document.revision, revision)
        // The real drag is exactly one step.
        r.drag(from: (0, 100), to: (30, 110))
        XCTAssertEqual(r.owner.historyDepth, depth + 1)
        guard case .shape(_, let t)? = r.surfaces.first?.form else { return XCTFail() }
        XCTAssertEqual(t.xCm, 30, accuracy: 0.2); XCTAssertEqual(t.yCm, 110, accuracy: 0.2)
        XCTAssertTrue(r.owner.undo())
        XCTAssertEqual(r.owner.document.spatial.layers, before.spatial.layers)
        XCTAssertTrue(r.owner.redo())
        XCTAssertEqual(r.sent, 0)
    }

    func testAnEditRedoBranchIsDroppedByANewGestureAndTheHistoryKeepsItsLimit() throws {
        let r = try rig(); defer { r.f.root.terminate {} }
        r.editor.select(tool: .rectangle); r.drag(from: (-20, 80), to: (20, 120))
        r.editor.select(tool: .select)
        r.drag(from: (0, 100), to: (10, 100))
        XCTAssertTrue(r.owner.undo()); XCTAssertTrue(r.owner.canRedo)
        r.drag(from: (0, 100), to: (0, 110))
        XCTAssertFalse(r.owner.canRedo, "a new edit ends the redo branch")
        for step in 0..<130 { _ = r.editor.nudge(dxCm: step % 2 == 0 ? 1 : -1, dyCm: 0, keyCode: 124); r.editor.endNudge() }
        XCTAssertLessThanOrEqual(r.owner.historyDepth, 100, "the undo buffer keeps its limit")
    }

    func testPerformanceModeRefusesEditingAndDropsASketch() throws {
        let r = try rig(); defer { r.f.root.terminate {} }
        r.editor.select(tool: .rectangle)
        r.editor.pointerDown(at: r.screen(-20, 80), geometry: r.geometry, modifiers: [])
        r.editor.pointerDragged(to: r.screen(20, 120), modifiers: [])
        XCTAssertNotNil(r.editor.gesture)
        r.owner.canvas.setPerformanceLocked(true)
        XCTAssertNil(r.editor.gesture, "locking drops the sketch")
        let before = r.owner.document
        r.editor.pointerUp(at: r.screen(20, 120), modifiers: [])
        r.editor.pointerDown(at: r.screen(-20, 80), geometry: r.geometry, modifiers: [])
        XCTAssertNil(r.editor.gesture)
        XCTAssertFalse(r.editor.deleteSelection())
        XCTAssertEqual(r.owner.document, before)
    }

    func testANudgeBurstIsOneUndoStepAndTheKeyReleaseClosesIt() throws {
        let r = try rig(); defer { r.f.root.terminate {} }
        r.editor.select(tool: .rectangle); r.drag(from: (-20, 80), to: (20, 120))
        let depth = r.owner.historyDepth
        for _ in 0..<5 { XCTAssertTrue(r.editor.nudge(dxCm: 1, dyCm: 0, keyCode: 124)) }
        r.editor.keyReleased(124)
        XCTAssertEqual(r.owner.historyDepth, depth + 1)
        guard case .shape(_, let t)? = r.surfaces.first?.form else { return XCTFail() }
        XCTAssertEqual(t.xCm, 5, accuracy: 0.001)
        XCTAssertTrue(r.owner.undo())
        guard case .shape(_, let back)? = r.surfaces.first?.form else { return XCTFail() }
        XCTAssertEqual(back.xCm, 0, accuracy: 0.001)
    }

    func testSurfaceSeriesAndMixerEditsNeverShareAnUndoBoundary() throws {
        let r = try rig(); defer { r.f.root.terminate {} }
        r.editor.select(tool: .rectangle); r.drag(from: (-20, 80), to: (20, 120))
        let id = r.surfaces[0].id
        var depth = r.owner.historyDepth
        // A nudge burst, then a mixer drag: two boundaries.
        _ = r.editor.nudge(dxCm: 2, dyCm: 0, keyCode: 124)
        r.owner.beginContinuousEdit()
        r.owner.updateMasterLevel(-6)
        r.owner.endContinuousEdit()
        r.editor.endNudge()
        XCTAssertEqual(r.owner.historyDepth, depth + 2, "surface burst and mixer drag are separate steps")
        XCTAssertTrue(r.owner.undo())
        XCTAssertEqual(r.owner.document.masterLevelDecibels, 0, accuracy: 0.001, "the first undo takes back only the fader")
        guard case .shape(_, let kept)? = r.surfaces.first(where: { $0.id == id })?.form else { return XCTFail() }
        XCTAssertEqual(kept.xCm, 2, accuracy: 0.001)
        // A mixer drag first, then a nudge.
        depth = r.owner.historyDepth
        r.owner.beginContinuousEdit()
        r.owner.updateMasterLevel(-3)
        _ = r.editor.nudge(dxCm: 1, dyCm: 0, keyCode: 124)
        r.owner.endContinuousEdit()
        r.editor.endNudge()
        XCTAssertEqual(r.owner.historyDepth, depth + 2)
    }

    func testADocumentChangeDropsStaleSelectionAndSketch() throws {
        let r = try rig(); defer { r.f.root.terminate {} }
        r.editor.select(tool: .rectangle); r.drag(from: (-20, 80), to: (20, 120))
        XCTAssertEqual(r.editor.selectedSurfaceIDs.count, 1)
        r.editor.select(tool: .select)
        r.editor.pointerDown(at: r.screen(0, 100), geometry: r.geometry, modifiers: [])
        r.editor.pointerDragged(to: r.screen(10, 100), modifiers: [])
        XCTAssertNotNil(r.editor.gesture)
        XCTAssertTrue(r.owner.undo())
        XCTAssertNil(r.editor.gesture, "a document change ends the drag in progress")
        XCTAssertTrue(r.editor.selectedSurfaceIDs.isEmpty, "the surface no longer exists")
    }

    // MARK: Commands

    func testDuplicateDeleteAndPasteWorkOnTheSelectionAndNotAcrossPresets() throws {
        let r = try rig(); defer { r.f.root.terminate {} }
        SurfaceEditorModel.resetClipboard()
        r.editor.select(tool: .rectangle); r.drag(from: (-20, 80), to: (20, 120))
        XCTAssertTrue(r.editor.duplicateSelection())
        XCTAssertEqual(r.surfaces.count, 2)
        XCTAssertEqual(r.editor.selectedSurfaceIDs.count, 1, "the copy is chosen")
        XCTAssertTrue(r.editor.copySelection()); XCTAssertTrue(r.editor.pasteSelection())
        XCTAssertEqual(r.surfaces.count, 3)
        XCTAssertTrue(r.editor.selectAll())
        XCTAssertTrue(r.editor.deleteSelection()); XCTAssertTrue(r.surfaces.isEmpty)
        XCTAssertTrue(r.owner.undo()); XCTAssertEqual(r.surfaces.count, 3)
        // Another preset session never receives pasted surfaces or silently retargets them.
        XCTAssertTrue(r.editor.copySelection() || r.editor.selectAll() && r.editor.copySelection())
        let other = try rig(); defer { other.f.root.terminate {} }
        let count = other.surfaces.count
        XCTAssertFalse(other.editor.pasteSelection())
        XCTAssertEqual(other.surfaces.count, count)
        XCTAssertEqual(other.editor.hint, "Surfaces keep the outputs of their own preset; they can only be pasted there")
    }


    // MARK: Nacharbeit UI-1: sketch, series, clipboard, range

    func testAnUndoDropsThePolygonBeingClickedTogetherButANudgeBurstSurvivesItsOwnInstalls() throws {
        let r = try rig(); defer { r.f.root.terminate {} }
        r.editor.select(tool: .rectangle); r.drag(from: (-20, 80), to: (20, 120))
        r.editor.select(tool: .polygon)
        for p in [(-20.0, 140.0), (20, 140), (0, 170)] { r.click(p) }
        XCTAssertEqual(r.editor.polygon?.points.count, 3)
        XCTAssertTrue(r.owner.undo())
        XCTAssertNil(r.editor.polygon, "an old draft must not travel into another document state")
        XCTAssertTrue(r.surfaces.isEmpty)
        XCTAssertTrue(r.owner.redo())
        r.editor.select(tool: .select)
        XCTAssertTrue(r.editor.select(Set(r.surfaces.map(\.id))))
        let depth = r.owner.historyDepth
        XCTAssertTrue(r.editor.nudge(dxCm: 1, dyCm: 0, keyCode: 124)); XCTAssertTrue(r.editor.nudge(dxCm: 1, dyCm: 0, keyCode: 124))
        r.editor.keyReleased(124)
        XCTAssertEqual(r.owner.historyDepth, depth + 1, "the burst's own installs do not end it")
        // Clicking a corner is not a document change either.
        r.editor.select(tool: .polygon)
        r.click((0, 150)); r.click((30, 150))
        XCTAssertEqual(r.editor.polygon?.points.count, 2)
    }

    func testHoldingAnInspectorStepperIsOneUndoStepAndCancelRestoresEverything() throws {
        let r = try rig(); defer { r.f.root.terminate {} }
        r.editor.select(tool: .rectangle); r.drag(from: (-10, 90), to: (10, 110))
        let original = try XCTUnwrap(r.editor.singleSurface?.placedShape?.shape)
        let depth = r.owner.historyDepth
        r.editor.beginAdjusting()
        for width in [21.0, 22, 23] { XCTAssertTrue(r.editor.setSize(widthCm: width)) }
        r.editor.endAdjusting()
        XCTAssertEqual(r.owner.historyDepth, depth + 1)
        XCTAssertEqual(r.editor.singleSurface?.placedShape?.shape, .rectangle(widthCm: 23, heightCm: 20))
        XCTAssertTrue(r.owner.undo())
        XCTAssertEqual(r.editor.singleSurface?.placedShape?.shape, original, "one undo returns to where the hold began")
        XCTAssertTrue(r.owner.redo())
        XCTAssertEqual(r.editor.singleSurface?.placedShape?.shape, .rectangle(widthCm: 23, heightCm: 20))
        // Cancelling a held stepper returns document and history to the start.
        let before = r.owner.document, stack = r.owner.historyDepth
        r.editor.beginAdjusting()
        XCTAssertTrue(r.editor.setSize(widthCm: 40)); XCTAssertTrue(r.editor.setSize(widthCm: 41))
        XCTAssertTrue(r.editor.cancelAdjusting())
        XCTAssertEqual(r.owner.historyDepth, stack)
        XCTAssertEqual(r.editor.singleSurface?.placedShape?.shape, before.spatial.layers.flatMap(\.surfaces).first?.placedShape?.shape)
        // Without a held series every inspector step is its own undo step, and one command of several edits stays one step.
        XCTAssertTrue(r.editor.setSize(widthCm: 31)); XCTAssertTrue(r.editor.setSize(widthCm: 32))
        XCTAssertEqual(r.owner.historyDepth, stack + 2)
        XCTAssertEqual(r.sent, 0)
    }

    func testCutKeepsTheSurfaceOnTheClipboardForPastingAndRefusesWhatItCannotKeep() throws {
        let r = try rig(); defer { r.f.root.terminate {} }
        SurfaceEditorModel.resetClipboard()
        r.editor.select(tool: .rectangle); r.drag(from: (-20, 80), to: (20, 120))
        XCTAssertTrue(r.editor.rename("Pad"))
        let original = try XCTUnwrap(r.surfaces.first)
        XCTAssertTrue(r.editor.cutSelection())
        XCTAssertTrue(r.surfaces.isEmpty)
        XCTAssertTrue(r.editor.pasteSelection(), "Command-X, Command-V brings the object back")
        let pasted = try XCTUnwrap(r.surfaces.first)
        XCTAssertEqual(r.surfaces.count, 1)
        XCTAssertNotEqual(pasted.id, original.id, "a new identity, never the removed one")
        XCTAssertEqual(pasted.placedShape, original.placedShape, "a cut surface comes back where it was")
        XCTAssertEqual(pasted.routings.map(\.program), original.routings.map(\.program))
        XCTAssertEqual(pasted.routings.map(\.target), original.routings.map(\.target))
        XCTAssertTrue(Set(pasted.routings.map(\.id)).isDisjoint(with: original.routings.map(\.id)))
        XCTAssertEqual(r.editor.selectedSurfaceIDs, [pasted.id])
        // The second paste lands beside the first, and one undo takes one paste back.
        let depth = r.owner.historyDepth
        XCTAssertTrue(r.editor.pasteSelection())
        XCTAssertEqual(r.surfaces.count, 2); XCTAssertEqual(r.owner.historyDepth, depth + 1)
        XCTAssertEqual(r.surfaces.last?.placedShape?.transform.xCm ?? 0, (original.placedShape?.transform.xCm ?? 0) + 10, accuracy: 0.11)
        XCTAssertTrue(r.owner.undo()); XCTAssertEqual(r.surfaces.count, 1)
        XCTAssertTrue(r.editor.select(Set(r.surfaces.map(\.id))))
        // A copy keeps the original and pastes beside it.
        XCTAssertTrue(r.editor.copySelection()); XCTAssertTrue(r.editor.pasteSelection())
        XCTAssertEqual(r.surfaces.count, 2)
        // The layer is gone: nothing is pasted anywhere else.
        SurfaceEditorModel.resetClipboard()
        XCTAssertFalse(r.editor.pasteSelection()); XCTAssertEqual(r.editor.hint, "Nothing copied")
        XCTAssertEqual(r.sent, 0)
    }

    func testCutOfAnExactAreaFromAnOlderPresetIsRefusedAndRemovesNothing() throws {
        let r = try rig(); defer { r.f.root.terminate {} }
        SurfaceEditorModel.resetClipboard()
        let cells = Set((0..<6).flatMap { ring in (0..<6).map { PolarDeviceLattice(ring: 40 + ring, sector: 170 + $0)! } })
        let old = SpatialDocumentLayer(id: UUID(), name: "Old", color: .blue, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
            cells: cells, routings: [.init(target: .midiNote(channel: 0), program: .singleNote(note: 60, velocity: 100, transition: .retrigger))], cellOverrides: [:])
        try r.owner.edit { $0.spatial = try! SpatialDocument(latticeVersion: .polarDeviceV2, layers: [old], selectedLayerID: old.id) }
        XCTAssertTrue(r.owner.applySurfaceEdits([.promoteLayer(layerID: old.id)], undoName: "Convert"))
        let mask = try XCTUnwrap(r.surfaces.first)
        XCTAssertTrue(mask.isLegacyMask)
        XCTAssertTrue(r.editor.select([mask.id]))
        let before = r.owner.document, depth = r.owner.historyDepth
        XCTAssertFalse(r.editor.cutSelection())
        XCTAssertEqual(r.owner.document, before, "a refused cut removes nothing")
        XCTAssertEqual(r.owner.historyDepth, depth)
        XCTAssertEqual(r.editor.hint, "An exact area from an older preset cannot be copied or cut; duplicate it instead")
        XCTAssertFalse(r.editor.pasteSelection(), "nothing reached the clipboard")
        XCTAssertTrue(r.editor.duplicateSelection(), "duplicating the exact area still works")
    }

    func testChangingAnEndChannelOutputOrCurveOfAnInverseControllerRangeKeepsItsDirectionOnATurnedMirroredSurface() throws {
        let r = try rig(); defer { r.f.root.terminate {} }
        r.editor.select(tool: .rectangle); r.drag(from: (-30, 80), to: (30, 120))
        XCTAssertTrue(r.editor.setPlays(try XCTUnwrap(r.surfaces.first?.routings.first).id, .controller))
        let id = try XCTUnwrap(r.surfaces.first?.routings.first).id
        XCTAssertTrue(r.editor.setPlacement(rotationDegrees: 30, mirrored: true))
        func state() throws -> (coding: SurfaceValueCoding, program: SpatialValueProgram, target: SpatialRoutingTarget) {
            let surface = try XCTUnwrap(r.surfaces.first)
            let routing = try XCTUnwrap(surface.routings.first { $0.id == id })
            return (try XCTUnwrap(SurfaceValueCoding(surface: surface, routingID: id)), routing.program, routing.target)
        }
        // A really inverse stored program: the value falls along the programmed direction.
        XCTAssertTrue(r.editor.setValueRange(id, from: 100, to: 20))
        let inverse = try state()
        guard case .continuous(let minimum, let maximum, _, _) = inverse.program else { return XCTFail() }
        XCTAssertGreaterThan(minimum, maximum, "stored inverse: the first value is the larger one")
        XCTAssertTrue(SurfaceAxis.risesAgainstDirection(inverse.program))
        let arrow = try XCTUnwrap(inverse.coding.arrow)
        func assertSameCourse(_ now: (coding: SurfaceValueCoding, program: SpatialValueProgram, target: SpatialRoutingTarget), _ legend: String, line: UInt = #line) throws {
            XCTAssertTrue(SurfaceAxis.risesAgainstDirection(now.program), "still inverse", line: line)
            XCTAssertEqual(now.coding.legend, legend, line: line)
            let a = try XCTUnwrap(now.coding.arrow)
            XCTAssertEqual(a.arrowBearingDegrees, arrow.arrowBearingDegrees, accuracy: 0.01, line: line)
            XCTAssertEqual(a.start.x, arrow.start.x, accuracy: 0.01, line: line)
            XCTAssertEqual(a.tip.y, arrow.tip.y, accuracy: 0.01, line: line)
        }
        // Change only the value at the arrow's tip, then the one at its start.
        XCTAssertTrue(r.editor.setValueRange(id, from: 20, to: 90))
        try assertSameCourse(try state(), "CC74 · 20 → 90")
        XCTAssertTrue(r.editor.setValueRange(id, from: 10, to: 90))
        try assertSameCourse(try state(), "CC74 · 10 → 90")
        // Curve, controller number, channel and output all go through the older assignment draft.
        XCTAssertTrue(r.editor.updateRouting(id) { $0.curve = .easeIn })
        try assertSameCourse(try state(), "CC74 · 10 → 90 · slow finish")
        XCTAssertTrue(r.editor.updateRouting(id) { $0.target = $0.target.withControllerNumber(21); $0.ccNumber = 21 })
        try assertSameCourse(try state(), "CC21 · 10 → 90 · slow finish")
        XCTAssertTrue(r.editor.setChannel(id, channel: 5))
        try assertSameCourse(try state(), "CC21 · 10 → 90 · slow finish")
        XCTAssertEqual(try state().target, .audioUnitCC(channel: 4, controller: 21, stripID: r.owner.document.channels[0].id))
        XCTAssertTrue(r.editor.setOutput(id, stripID: nil))
        try assertSameCourse(try state(), "CC21 · 10 → 90 · slow finish")
        XCTAssertEqual(try state().target, .midiCC(channel: 4, controller: 21))
        // Entering a start above the end deliberately turns the course around; a range that is not inverse stays that way.
        XCTAssertTrue(r.editor.setValueRange(id, from: 127, to: 0))
        XCTAssertFalse(SurfaceAxis.risesAgainstDirection(try state().program))
        XCTAssertTrue(r.editor.setChannel(id, channel: 2)); XCTAssertTrue(r.editor.updateRouting(id) { $0.curve = .linear })
        XCTAssertFalse(SurfaceAxis.risesAgainstDirection(try state().program))
        XCTAssertEqual(r.sent, 0)
    }

    func testANewSurfaceGoesToTheTopmostLayerOfAMultiLayerSelectionNotToAChanceLayer() throws {
        let r = try rig(); defer { r.f.root.terminate {} }
        let bottom = r.owner.document.spatial.selectedLayerID
        let layer = SpatialDocumentLayer(id: UUID(), name: "Top", color: .blue, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                                         cells: [], routings: [], cellOverrides: [:])
        try r.owner.edit { $0.spatial = try! $0.spatial.replacingLayers($0.spatial.layers + [layer], selectedLayerID: bottom) }
        let a = try XCTUnwrap(r.editor.addSurface(shape: .rectangle(widthCm: 20, heightCm: 20), transform: .init(xCm: -40, yCm: 70), toLayer: bottom))
        let b = try XCTUnwrap(r.editor.addSurface(shape: .rectangle(widthCm: 20, heightCm: 20), transform: .init(xCm: 40, yCm: 70), toLayer: layer.id))
        for _ in 0..<12 {
            XCTAssertTrue(r.editor.select([a, b]))
            XCTAssertEqual(r.owner.canvas.workspace.selectedLayerID, layer.id, "always the layer higher in the stack")
        }
    }

    // MARK: Inspector

    func testInspectorCommandsAreValidatedEditsWithTheirOwnUndo() throws {
        let r = try rig(); defer { r.f.root.terminate {} }
        r.editor.select(tool: .rectangle); r.drag(from: (-20, 80), to: (20, 120))
        let depth = r.owner.historyDepth
        XCTAssertTrue(r.editor.setPlacement(xCm: 15, yCm: 90))
        XCTAssertTrue(r.editor.setSize(widthCm: 50))
        XCTAssertTrue(r.editor.setPlacement(rotationDegrees: 30))
        guard case .shape(.rectangle(let w, _), let t)? = r.surfaces.first?.form else { return XCTFail() }
        XCTAssertEqual(w, 50); XCTAssertEqual(t.xCm, 15); XCTAssertEqual(t.yCm, 90); XCTAssertEqual(t.rotationDegrees, 30)
        XCTAssertEqual(r.owner.historyDepth, depth + 3)
        let before = r.owner.document
        XCTAssertFalse(r.editor.setSize(widthCm: -4), "a refused number changes nothing")
        XCTAssertEqual(r.owner.document, before); XCTAssertNotNil(r.editor.hint)
        XCTAssertTrue(r.editor.rename("Front pad"))
        XCTAssertEqual(r.surfaces.first?.presentation.name, "Front pad")
        XCTAssertFalse(r.editor.rename("   "))
        XCTAssertTrue(r.editor.setColor(.init(red: 0.2, green: 0.4, blue: 0.6)))
        XCTAssertTrue(r.editor.setValueColors([.init(red: 1, green: 0, blue: 0), .init(red: 0, green: 0, blue: 1)]))
        XCTAssertEqual(r.surfaces.first?.presentation.valueColors.count, 2)
        XCTAssertEqual(r.sent, 0)
    }

    func testScaleAndControllerAssignmentsKeepTheirOutputAndGetAnArrow() throws {
        let r = try rig(); defer { r.f.root.terminate {} }
        r.editor.select(tool: .rectangle); r.drag(from: (-30, 80), to: (30, 120))
        let routing = try XCTUnwrap(r.surfaces.first?.routings.first)
        let stripID = r.owner.document.channels[0].id
        XCTAssertEqual(SurfacePlays.of(routing), .note)
        XCTAssertTrue(r.editor.setPlays(routing.id, .scale))
        let scale = try XCTUnwrap(r.surfaces.first?.routings.first)
        XCTAssertEqual(SurfacePlays.of(scale), .scale)
        XCTAssertEqual(scale.target, .audioUnitNote(channel: 0, stripID: stripID), "the output stays")
        XCTAssertNotNil(SurfaceValueCoding(surface: r.surfaces[0], routingID: scale.id)?.arrow)
        XCTAssertTrue(r.editor.setArrow(scale.id, bearingDegrees: 90))
        let coding = try XCTUnwrap(SurfaceValueCoding(surface: r.surfaces[0], routingID: scale.id))
        XCTAssertEqual(coding.arrow?.arrowBearingDegrees ?? 0, 90, accuracy: 0.01)
        XCTAssertTrue(r.editor.reverseArrow(scale.id))
        XCTAssertEqual(SurfaceAxis.normalized(SurfaceValueCoding(surface: r.surfaces[0], routingID: scale.id)?.arrow?.arrowBearingDegrees ?? 0), SurfaceAxis.normalized(270), accuracy: 0.01)
        XCTAssertTrue(r.editor.setPlays(scale.id, .controller))
        let cc = try XCTUnwrap(r.surfaces.first?.routings.first)
        XCTAssertEqual(SurfacePlays.of(cc), .controller)
        XCTAssertEqual(cc.target, .audioUnitCC(channel: 0, controller: 74, stripID: stripID))
        XCTAssertTrue(r.editor.setValueRange(cc.id, from: 127, to: 0))
        XCTAssertTrue(r.editor.addRouting(copying: cc.id))
        XCTAssertEqual(r.surfaces.first?.routings.count, 2, "several assignments are kept separately")
        XCTAssertTrue(r.editor.removeRouting(cc.id))
        XCTAssertEqual(r.surfaces.first?.routings.count, 1)
        XCTAssertEqual(r.sent, 0)
    }

    func testTheDrawnShapeWithAxisColoursAndAssignmentSurvivesSaveAndLoad() throws {
        let r = try rig(); defer { r.f.root.terminate {} }
        r.editor.select(tool: .polygon)
        for p in [(-40.0, 80.0), (40, 80), (50, 130), (-50, 130)] { r.click(p) }
        XCTAssertTrue(r.editor.finishPolygon())
        let id = r.surfaces[0].id
        let routingID = r.surfaces[0].routings[0].id
        XCTAssertTrue(r.editor.setPlays(routingID, .controller))
        XCTAssertTrue(r.editor.setArrow(routingID, bearingDegrees: 30))
        XCTAssertTrue(r.editor.setValueColors([.init(red: 1, green: 0, blue: 0), .init(red: 0, green: 1, blue: 0), .init(red: 0, green: 0, blue: 1)]))
        // The production writer (V7, because the document holds surfaces) and reader.
        let data = try PresetDocumentWriter.encode(InstrumentPresetV6(name: "Drawn", document: r.owner.document))
        let loaded = try PresetDocumentReader.read(data).get().replacing(r.owner.document)
        let before = try XCTUnwrap(r.surfaces.first)
        let after = try XCTUnwrap(loaded.spatial.layers.flatMap(\.surfaces).first { $0.id == id })
        XCTAssertEqual(after.form, before.form)
        XCTAssertEqual(after.routings, before.routings)
        XCTAssertEqual(after.presentation, before.presentation)
        XCTAssertEqual(after.cells, before.cells)
    }

    func testPlayingAreaCanBeChosenAndAnOutsideSurfaceIsRefusedOrClipped() throws {
        let r = try rig(); defer { r.f.root.terminate {} }
        r.editor.select(tool: .rectangle); r.drag(from: (-20, 80), to: (20, 120))
        var settings = r.owner.document.spatial.surfaceSettings
        settings.playArea = .rectangle(xMinCm: -100, xMaxCm: 100, yMinCm: 0, yMaxCm: 150)
        XCTAssertTrue(r.editor.setPlayingArea(settings))
        let before = r.owner.document
        XCTAssertFalse(r.editor.setPlacement(yCm: 400), "outside the playing area is refused, not clamped")
        XCTAssertEqual(r.owner.document, before)
        settings.outsidePolicy = .clip
        XCTAssertTrue(r.editor.setPlayingArea(settings))
        XCTAssertTrue(r.editor.setPlacement(yCm: 140), "partly outside is clipped under the clip policy")
    }
}
