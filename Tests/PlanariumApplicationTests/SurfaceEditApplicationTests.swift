import XCTest
@testable import PlanariumApplication
import PlanariumDomain
import SickPLSMonitorKit

@MainActor final class SurfaceEditApplicationTests: XCTestCase {
    func testSurfaceEditsCommitOnceUndoCleanlyAndRejectWithoutTrace() throws {
        let f = try RootFixture(), owner = f.root.document
        defer { f.root.terminate {} }
        owner.canvas.updateWorkspace { workspace in
            workspace.updateSelectedLayer { layer in
                layer.polarCells = Set((8..<12).flatMap { ring in (8..<12).map { PolarMetricGridCell(ring: ring, angularIndex: $0) } })
            }
        }
        let layerID = owner.document.spatial.layers[owner.document.spatial.layers.firstIndex { $0.id == owner.document.spatial.selectedLayerID }!].id
        let original = owner.document
        let depth = owner.historyDepth

        XCTAssertTrue(owner.applySurfaceEdit(.promoteLayer(layerID: layerID)))
        XCTAssertEqual(owner.historyDepth, depth + 1, "one edit, one undo step")
        let promoted = owner.document
        XCTAssertTrue(promoted.spatial.layers.first { $0.id == layerID }!.isSurfaceBacked)
        XCTAssertEqual(owner.compiledInstrument.revision, owner.document.revision)

        // A rejected edit leaves document, history and installed instrument untouched.
        let revision = owner.document.revision
        XCTAssertFalse(owner.applySurfaceEdit(.moveSurfaces(ids: [UUID()], dxCm: 1, dyCm: 0)))
        XCTAssertFalse(owner.applySurfaceEdit(.promoteLayer(layerID: layerID)))
        XCTAssertEqual(owner.document, promoted)
        XCTAssertEqual(owner.document.revision, revision)
        XCTAssertEqual(owner.historyDepth, depth + 1)

        XCTAssertTrue(owner.undo())
        XCTAssertEqual(owner.document.spatial.layers.first { $0.id == layerID }!.cells,
                       original.spatial.layers.first { $0.id == layerID }!.cells)
        XCTAssertFalse(owner.document.spatial.layers.first { $0.id == layerID }!.isSurfaceBacked)
        XCTAssertTrue(owner.redo())
        XCTAssertTrue(owner.document.spatial.layers.first { $0.id == layerID }!.isSurfaceBacked)
    }

    // MARK: Undo series

    /// An owner whose selected layer is one rectangular surface (promoted, then replaced by a shape).
    private func shapedOwner(_ f: RootFixture) throws -> (owner: SpatialInstrumentRuntimeModel, layerID: UUID) {
        let owner = f.root.document
        owner.canvas.updateWorkspace { workspace in
            workspace.updateSelectedLayer { layer in
                layer.polarCells = Set((8..<12).flatMap { ring in (8..<12).map { PolarMetricGridCell(ring: ring, angularIndex: $0) } })
            }
        }
        let layerID = owner.document.spatial.selectedLayerID
        XCTAssertTrue(owner.applySurfaceEdit(.promoteLayer(layerID: layerID)))
        XCTAssertTrue(owner.applySurfaceEdit(.replaceMaskWithShape(surfaceID: layerID, shape: .rectangle(widthCm: 20, heightCm: 10), transform: .init(xCm: 0, yCm: 100))))
        return (owner, layerID)
    }
    private func x(_ owner: SpatialInstrumentRuntimeModel, _ id: UUID) -> Double {
        owner.document.spatial.layers.flatMap(\.surfaces).first { $0.id == id }!.transform.xCm
    }

    func testSeparateEditsAreSeparateUndoStepsByDefault() throws {
        let f = try RootFixture(); defer { f.root.terminate {} }
        let (owner, id) = try shapedOwner(f)
        let depth = owner.historyDepth
        XCTAssertTrue(owner.applySurfaceEdit(.moveSurfaces(ids: [id], dxCm: 5, dyCm: 0)))
        XCTAssertTrue(owner.applySurfaceEdit(.moveSurfaces(ids: [id], dxCm: 5, dyCm: 0)))
        XCTAssertEqual(owner.historyDepth, depth + 2, "two separate moves are two undo steps")
        XCTAssertTrue(owner.undo()); XCTAssertEqual(x(owner, id), 5)
        XCTAssertTrue(owner.undo()); XCTAssertEqual(x(owner, id), 0)
    }

    func testANudgeSeriesIsOneUndoStepAndEndingItClosesIt() throws {
        let f = try RootFixture(); defer { f.root.terminate {} }
        let (owner, id) = try shapedOwner(f)
        let depth = owner.historyDepth
        owner.beginSurfaceEditSeries()
        for _ in 0..<3 { XCTAssertTrue(owner.applySurfaceEdit(.moveSurfaces(ids: [id], dxCm: 2, dyCm: 0))) }
        owner.endSurfaceEditSeries()
        XCTAssertEqual(x(owner, id), 6)
        XCTAssertEqual(owner.historyDepth, depth + 1, "the burst is one undo step")
        XCTAssertTrue(owner.applySurfaceEdit(.moveSurfaces(ids: [id], dxCm: 2, dyCm: 0)))
        XCTAssertEqual(owner.historyDepth, depth + 2, "after the series ended a new edit is its own step")
        XCTAssertTrue(owner.undo()); XCTAssertEqual(x(owner, id), 6)
        XCTAssertTrue(owner.undo()); XCTAssertEqual(x(owner, id), 0, "one undo returns the whole burst")
        XCTAssertTrue(owner.redo()); XCTAssertEqual(x(owner, id), 6)
    }

    func testNoOpAnotherKindOfEditAndUndoEndTheSeries() throws {
        let f = try RootFixture(); defer { f.root.terminate {} }
        let (owner, id) = try shapedOwner(f)
        var depth = owner.historyDepth
        // A no-op edit ends the series: the move after it is a step of its own.
        owner.beginSurfaceEditSeries()
        XCTAssertTrue(owner.applySurfaceEdit(.moveSurfaces(ids: [id], dxCm: 2, dyCm: 0)))
        XCTAssertTrue(owner.applySurfaceEdit(.moveSurfaces(ids: [id], dxCm: 0, dyCm: 0)))
        XCTAssertTrue(owner.applySurfaceEdit(.moveSurfaces(ids: [id], dxCm: 2, dyCm: 0)))
        XCTAssertEqual(owner.historyDepth, depth + 2)
        owner.endSurfaceEditSeries(); depth = owner.historyDepth
        // Another kind of edit ends it too.
        owner.beginSurfaceEditSeries()
        XCTAssertTrue(owner.applySurfaceEdit(.moveSurfaces(ids: [id], dxCm: 1, dyCm: 0)))
        XCTAssertTrue(owner.applySurfaceEdit(.rotateSurfaces(ids: [id], degrees: 10, aroundXCm: 0, aroundYCm: 100)))
        XCTAssertTrue(owner.applySurfaceEdit(.moveSurfaces(ids: [id], dxCm: 1, dyCm: 0)))
        XCTAssertEqual(owner.historyDepth, depth + 3, "move, rotate, move are three kinds in a row")
        owner.endSurfaceEditSeries(); depth = owner.historyDepth
        // Undo ends it: the next edit does not merge into a step that was taken back.
        owner.beginSurfaceEditSeries()
        XCTAssertTrue(owner.applySurfaceEdit(.moveSurfaces(ids: [id], dxCm: 3, dyCm: 0)))
        XCTAssertTrue(owner.undo())
        XCTAssertTrue(owner.applySurfaceEdit(.moveSurfaces(ids: [id], dxCm: 3, dyCm: 0)))
        XCTAssertEqual(owner.historyDepth, depth + 1)
        XCTAssertFalse(owner.canRedo)
    }

    func testARejectedEditKeepsTheSeriesOpenAndASeriesBackAtItsStartLeavesNoStep() throws {
        let f = try RootFixture(); defer { f.root.terminate {} }
        let (owner, id) = try shapedOwner(f)
        var depth = owner.historyDepth
        owner.beginSurfaceEditSeries()
        XCTAssertTrue(owner.applySurfaceEdit(.moveSurfaces(ids: [id], dxCm: 2, dyCm: 0)))
        XCTAssertFalse(owner.applySurfaceEdit(.moveSurfaces(ids: [UUID()], dxCm: 2, dyCm: 0)))
        XCTAssertFalse(owner.applySurfaceEdit(.moveSurfaces(ids: [id], dxCm: .infinity, dyCm: 0)))
        XCTAssertTrue(owner.applySurfaceEdit(.moveSurfaces(ids: [id], dxCm: 2, dyCm: 0)))
        owner.endSurfaceEditSeries()
        XCTAssertEqual(owner.historyDepth, depth + 1, "rejections neither split nor end the burst")
        XCTAssertEqual(x(owner, id), 4)
        depth = owner.historyDepth
        owner.beginSurfaceEditSeries()
        XCTAssertTrue(owner.applySurfaceEdit(.moveSurfaces(ids: [id], dxCm: 7, dyCm: 0)))
        XCTAssertTrue(owner.applySurfaceEdit(.moveSurfaces(ids: [id], dxCm: -7, dyCm: 0)))
        owner.endSurfaceEditSeries()
        XCTAssertEqual(owner.historyDepth, depth, "a burst that ended where it began is no undo step")
    }

    func testCancellingAGestureRestoresTheStartWithoutAnyUndoOrRedoStep() throws {
        let f = try RootFixture(); defer { f.root.terminate {} }
        let (owner, id) = try shapedOwner(f)
        let before = owner.document, depth = owner.historyDepth
        owner.beginSurfaceEditSeries()
        for _ in 0..<4 { XCTAssertTrue(owner.applySurfaceEdit(.moveSurfaces(ids: [id], dxCm: 3, dyCm: 1))) }
        XCTAssertNotEqual(x(owner, id), 0)
        XCTAssertTrue(owner.cancelSurfaceEditSeries())
        XCTAssertEqual(x(owner, id), 0)
        XCTAssertEqual(owner.document.spatial.layers, before.spatial.layers)
        XCTAssertEqual(owner.historyDepth, depth); XCTAssertFalse(owner.canRedo)
        XCTAssertEqual(owner.compiledInstrument.revision, owner.document.revision)
        // Cancelling a gesture that changed nothing is harmless.
        owner.beginSurfaceEditSeries()
        XCTAssertTrue(owner.cancelSurfaceEditSeries())
        XCTAssertEqual(owner.historyDepth, depth)
    }

    func testCancelKeepsTheRedoBranchWhetherTheGestureMovedOrReturnedToItsStart() throws {
        let f = try RootFixture(); defer { f.root.terminate {} }
        let (owner, id) = try shapedOwner(f)
        XCTAssertTrue(owner.applySurfaceEdit(.moveSurfaces(ids: [id], dxCm: 10, dyCm: 0)))
        XCTAssertTrue(owner.undo()); XCTAssertTrue(owner.canRedo)
        let before = owner.document.spatial, depth = owner.historyDepth
        owner.beginSurfaceEditSeries()
        XCTAssertTrue(owner.applySurfaceEdit(.moveSurfaces(ids: [id], dxCm: 3, dyCm: 0)))
        XCTAssertTrue(owner.cancelSurfaceEditSeries())
        XCTAssertEqual(owner.document.spatial, before); XCTAssertEqual(owner.historyDepth, depth)
        XCTAssertTrue(owner.canRedo)
        // Out and back, then cancel: the unchanged series must not have eaten the redo branch either.
        owner.beginSurfaceEditSeries()
        XCTAssertTrue(owner.applySurfaceEdit(.moveSurfaces(ids: [id], dxCm: 3, dyCm: 0)))
        XCTAssertTrue(owner.applySurfaceEdit(.moveSurfaces(ids: [id], dxCm: -3, dyCm: 0)))
        XCTAssertTrue(owner.cancelSurfaceEditSeries())
        XCTAssertEqual(owner.historyDepth, depth); XCTAssertTrue(owner.canRedo)
        XCTAssertTrue(owner.redo()); XCTAssertEqual(x(owner, id), 10)
        // A confirmed change still discards redo.
        XCTAssertTrue(owner.undo())
        owner.beginSurfaceEditSeries()
        XCTAssertTrue(owner.applySurfaceEdit(.moveSurfaces(ids: [id], dxCm: 3, dyCm: 0)))
        owner.endSurfaceEditSeries()
        XCTAssertFalse(owner.canRedo); XCTAssertEqual(owner.historyDepth, depth + 1)
    }

    func testCancelOnAFullHistoryBufferRestoresTheEvictedOldestEntry() throws {
        let f = try RootFixture(); defer { f.root.terminate {} }
        let (owner, id) = try shapedOwner(f)
        for i in 0..<110 { XCTAssertTrue(owner.applySurfaceEdit(.moveSurfaces(ids: [id], dxCm: i.isMultiple(of: 2) ? 1 : -1, dyCm: 0))) }
        XCTAssertEqual(owner.historyDepth, 100)
        let before = owner.document.spatial
        owner.beginSurfaceEditSeries()
        XCTAssertTrue(owner.applySurfaceEdit(.moveSurfaces(ids: [id], dxCm: 5, dyCm: 0)))
        XCTAssertEqual(owner.historyDepth, 100)
        XCTAssertTrue(owner.cancelSurfaceEditSeries())
        XCTAssertEqual(owner.document.spatial, before)
        XCTAssertEqual(owner.historyDepth, 100)
        var undone = 0
        while owner.undo() { undone += 1 }
        XCTAssertEqual(undone, 100)
    }

    func testEndingASeriesAtItsStartKeepsRedoAndTheEvictedOldestEntry() throws {
        let f = try RootFixture(); defer { f.root.terminate {} }
        let (owner, id) = try shapedOwner(f)
        XCTAssertTrue(owner.applySurfaceEdit(.moveSurfaces(ids: [id], dxCm: 10, dyCm: 0)))
        XCTAssertTrue(owner.undo()); XCTAssertTrue(owner.canRedo)
        let depth = owner.historyDepth
        owner.beginSurfaceEditSeries()
        XCTAssertTrue(owner.applySurfaceEdit(.moveSurfaces(ids: [id], dxCm: 3, dyCm: 0)))
        XCTAssertTrue(owner.applySurfaceEdit(.moveSurfaces(ids: [id], dxCm: -3, dyCm: 0)))
        owner.endSurfaceEditSeries()
        XCTAssertEqual(owner.historyDepth, depth); XCTAssertTrue(owner.canRedo)
        XCTAssertTrue(owner.redo()); XCTAssertEqual(x(owner, id), 10)
        // Full buffer: the series' first edit evicts the oldest record; returning to the start brings it back.
        for i in 0..<110 { XCTAssertTrue(owner.applySurfaceEdit(.moveSurfaces(ids: [id], dxCm: i.isMultiple(of: 2) ? 1 : -1, dyCm: 0))) }
        XCTAssertEqual(owner.historyDepth, 100)
        owner.beginSurfaceEditSeries()
        XCTAssertTrue(owner.applySurfaceEdit(.moveSurfaces(ids: [id], dxCm: 4, dyCm: 0)))
        XCTAssertTrue(owner.applySurfaceEdit(.moveSurfaces(ids: [id], dxCm: -4, dyCm: 0)))
        owner.endSurfaceEditSeries()
        var undone = 0
        while owner.undo() { undone += 1 }
        XCTAssertEqual(undone, 100)
    }

    func testAConfirmedEditOfAnyOtherKindClosesTheSeriesSoCancelIsANoOp() throws {
        let f = try RootFixture(); defer { f.root.terminate {} }
        let (owner, id) = try shapedOwner(f)
        let depth = owner.historyDepth
        // Surface edit without a coalescing key.
        owner.beginSurfaceEditSeries()
        XCTAssertTrue(owner.applySurfaceEdit(.moveSurfaces(ids: [id], dxCm: 3, dyCm: 0)))
        XCTAssertTrue(owner.applySurfaceEdit(.setPresentation(surfaceID: id, .init(name: "confirmed rename", color: .green))))
        let committed = owner.document.spatial
        XCTAssertEqual(owner.historyDepth, depth + 2)
        XCTAssertTrue(owner.cancelSurfaceEditSeries())
        XCTAssertEqual(owner.document.spatial, committed); XCTAssertEqual(owner.historyDepth, depth + 2)
        XCTAssertTrue(owner.undo()); XCTAssertEqual(x(owner, id), 3, "undo takes back the rename, not the confirmed move")
        // Edit through the owner's generic path while a series is open.
        owner.beginSurfaceEditSeries()
        XCTAssertTrue(owner.applySurfaceEdit(.moveSurfaces(ids: [id], dxCm: 2, dyCm: 0)))
        try owner.edit(name: "Channel name") { $0.channelName = "Foreign" }
        let named = owner.document, namedDepth = owner.historyDepth
        XCTAssertTrue(owner.cancelSurfaceEditSeries())
        XCTAssertEqual(owner.document, named); XCTAssertEqual(owner.historyDepth, namedDepth)
        XCTAssertTrue(owner.undo())
        XCTAssertNotEqual(owner.document.channelName, "Foreign")
        XCTAssertEqual(x(owner, id), 5, "the confirmed move before the foreign edit survives the cancel")
    }

    /// B8: a performance lock that arrives between the start of a gesture and its cancel refuses the
    /// cancel without touching the gesture's safety copy; back in Edit the cancel is exact.
    func testCancelRefusedByThePerformanceLockKeepsTheGestureAndSucceedsBackInEditMode() throws {
        let f = try RootFixture(); defer { f.root.terminate {} }
        let (owner, id) = try shapedOwner(f)
        // A redo branch that the gesture itself drops.
        XCTAssertTrue(owner.applySurfaceEdit(.moveSurfaces(ids: [id], dxCm: 7, dyCm: 0)))
        XCTAssertTrue(owner.undo()); XCTAssertTrue(owner.canRedo)
        let before = owner.document, depth = owner.historyDepth

        owner.beginSurfaceEditSeries()
        for _ in 0..<3 { XCTAssertTrue(owner.applySurfaceEdit(.moveSurfaces(ids: [id], dxCm: 2, dyCm: 0))) }
        let moved = owner.document, movedDepth = owner.historyDepth
        owner.canvas.setPerformanceLocked(true)
        XCTAssertFalse(owner.cancelSurfaceEditSeries(), "locked: refused")
        XCTAssertEqual(owner.document, moved, "no partial change")
        XCTAssertEqual(owner.historyDepth, movedDepth, "no false history")
        XCTAssertEqual(owner.compiledInstrument.revision, owner.document.revision)
        XCTAssertFalse(owner.applySurfaceEdit(.moveSurfaces(ids: [id], dxCm: 1, dyCm: 0)), "the lock still refuses authoring")
        XCTAssertEqual(owner.document, moved)

        owner.canvas.setPerformanceLocked(false)
        XCTAssertTrue(owner.cancelSurfaceEditSeries(), "the same gesture can still be cancelled")
        XCTAssertEqual(owner.document.spatial.layers, before.spatial.layers)
        XCTAssertEqual(owner.historyDepth, depth)
        XCTAssertTrue(owner.canRedo, "the redo branch from before the gesture is back")
        XCTAssertTrue(owner.redo()); XCTAssertEqual(x(owner, id), 7)
    }

    func testCancelRefusedByTheLockBeforeTheGestureProducedAnythingStaysOpenAsWell() throws {
        let f = try RootFixture(); defer { f.root.terminate {} }
        let (owner, id) = try shapedOwner(f)
        XCTAssertTrue(owner.applySurfaceEdit(.moveSurfaces(ids: [id], dxCm: 7, dyCm: 0)))
        XCTAssertTrue(owner.undo())
        let before = owner.document, depth = owner.historyDepth
        owner.beginSurfaceEditSeries()
        owner.canvas.setPerformanceLocked(true)
        XCTAssertFalse(owner.cancelSurfaceEditSeries())
        XCTAssertEqual(owner.document, before); XCTAssertEqual(owner.historyDepth, depth)
        owner.canvas.setPerformanceLocked(false)
        XCTAssertTrue(owner.applySurfaceEdit(.moveSurfaces(ids: [id], dxCm: 4, dyCm: 0)), "the series is still the open one")
        XCTAssertTrue(owner.cancelSurfaceEditSeries())
        XCTAssertEqual(owner.document.spatial.layers, before.spatial.layers)
        XCTAssertEqual(owner.historyDepth, depth); XCTAssertTrue(owner.canRedo)
    }

    func testAResizeThatWouldChangeTheFrameIsRefusedWithAHintAndNoTrace() throws {
        let f = try RootFixture(); defer { f.root.terminate {} }
        let (owner, id) = try shapedOwner(f)
        let before = owner.document, depth = owner.historyDepth
        XCTAssertFalse(owner.applySurfaceEdit(.resizeSurface(id: id, shape: .ringSector(fromCm: 40, toCm: 60, fromDegrees: -30, toDegrees: 30), transform: .identity)))
        XCTAssertEqual(owner.document, before); XCTAssertEqual(owner.historyDepth, depth)
        XCTAssertEqual(owner.notice, "Resize keeps the kind of shape; a ring sector and a placed shape cannot be exchanged")
    }

    func testDuplicatingALayerThroughTheOwnerGivesTheCopyItsOwnRelease() throws {
        let f = try RootFixture(); defer { f.root.terminate {} }
        let (owner, id) = try shapedOwner(f)
        let own = SpatialRouting(target: .releaseLayer(layerID: id), program: .constant(1))
        XCTAssertTrue(owner.applySurfaceEdit(.setRoutings(surfaceID: id, routings: [own])))
        let depth = owner.historyDepth
        owner.duplicateLayer(id)
        XCTAssertEqual(owner.historyDepth, depth + 1)
        let copy = try XCTUnwrap(owner.document.spatial.layers.first { $0.id != id })
        XCTAssertEqual(copy.surfaces[0].routings.map(\.target), [.releaseLayer(layerID: copy.id)])
        XCTAssertEqual(owner.document.spatial.layers.first { $0.id == id }!.surfaces[0].routings.map(\.target), [.releaseLayer(layerID: id)])
        XCTAssertEqual(owner.compiledInstrument.ownerLayerID(of: copy.surfaces[0].id), copy.id)
    }
}
