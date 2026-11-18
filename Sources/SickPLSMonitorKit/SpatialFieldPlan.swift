import Foundation
import CoreGraphics
import PlanariumDomain

/// Document geometry plus discrete audibility/label presentation. No profile,
/// viewport or gesture participates in region construction; fill and outline
/// share exactly these components.
public struct SpatialFieldPlan {
    public struct Region {
        public let layerID: UUID
        public let cells: [PolarMetricGridCell]
        public let fill: CGPath
        public let outline: CGPath
        public let cellPaths: [CGPath]
        public let cellMesh: CGPath
        public let boundary: [Boundary]
        public let label: String?
        public let anchor: PolarMetricGridCell
        public let center: CGPoint
        public let bounds: CGRect
        public let hasOwnValue: Bool
    }
    public struct Label {
        public let regionIndex: Int
        public let cell: PolarMetricGridCell
        public let center: CGPoint
        public let opacity: Double
    }
    /// Selection only chooses a prepared immutable array. Ownership and
    /// placement belong to document preparation, never to a pointer event.
    public func labels(selectedLayerID: UUID) -> [Label] {
        labelsBySelectedLayer[selectedLayerID] ?? unselectedLabels
    }
    private var labelsBySelectedLayer: [UUID: [Label]] = [:]
    private var unselectedLabels: [Label] = []
    private func prepareLabels(selectedLayerID: UUID?, owners: [PolarMetricGridCell: UUID]) -> [Label] {
        CanvasTimingProbe.recordOnMain("plan.prepareLabels")
        return regions.enumerated().compactMap { index, region in
            guard isDisplayed(region.layerID), region.label != nil, let cell = labelCell(for: region, owners: owners) else { return nil }
            return .init(regionIndex: index, cell: cell, center: Self.center(.init(cell: cell, grid: grid)), opacity: (region.layerID == selectedLayerID ? 1 : 0.6) * audibilityOpacity[region.layerID, default: 1])
        }
    }
    public enum Boundary: Equatable {
        case arc(radius: Double, start: Double, end: Double)
        case radial(inner: Double, outer: Double, bearing: Double)
    }
    public let identity = UUID()
    public let regions: [Region]
    public let grid: MetricSquareGrid
    public let layers: [SpatialInstrumentLayer]
    /// Independent presentation key; changing scenes retains all paths,
    /// components and adjacency in this geometry plan.
    public private(set) var audibilityOpacity: [UUID: Double]
    public private(set) var showsInactiveLayers = true
    public mutating func setShowsInactiveLayers(_ value: Bool) {
        guard value != showsInactiveLayers else { return }; showsInactiveLayers = value; prepareLabelSelections()
    }
    public func isDisplayed(_ id: UUID) -> Bool { showsInactiveLayers || audibilityOpacity[id] == 1 }
    public mutating func updateAudibility(workspace: SpatialInstrumentWorkspace) {
        let next = Self.audibility(workspace)
        guard next != audibilityOpacity else { return }
        audibilityOpacity = next
        prepareLabelSelections()
    }
    private static func audibility(_ workspace: SpatialInstrumentWorkspace) -> [UUID: Double] {
        let audible = SpatialLayerAudibility.audibleIDs(workspace.layers.map { ($0.id, $0.isActive, $0.isSoloed) })
        return Dictionary(uniqueKeysWithValues: workspace.layers.filter(\.isVisible).map { ($0.id, audible.contains($0.id) ? 1.0 : 0.3) })
    }
    private mutating func prepareLabelSelections() {
        // Audibility changes occlusion as well as opacity. Reuse geometry but
        // refresh the exposed label anchors for each selection, once per scene.
        // Build the common paint order once. Selecting a layer only changes
        // ownership of its own cells, and cannot overtake the audible group.
        labelsBySelectedLayer.removeAll(keepingCapacity: true)
        var owners = labelOwners(selectedLayerID: nil)
        let audible = Set(layers.filter { audibilityOpacity[$0.id] == 1 }.map(\.id))
        unselectedLabels = prepareLabels(selectedLayerID: nil, owners: owners)
        for layer in layers where isDisplayed(layer.id) {
            let changed = layer.polarCells.filter { audible.contains(layer.id) || !audible.contains(owners[$0] ?? layer.id) }
                .map { ($0, owners[$0]) }
            for (cell, _) in changed { owners[cell] = layer.id }
            labelsBySelectedLayer[layer.id] = prepareLabels(selectedLayerID: layer.id, owners: owners)
            for (cell, owner) in changed { owners[cell] = owner }
        }
    }
    public init(workspace: SpatialInstrumentWorkspace) { self.init(workspace: workspace, excludingLayers: []) }
    /// - Parameter excludingLayers: layers drawn by someone else (the surface editor draws surface-backed
    ///   layers from their real forms instead of from their coarse cell projection).
    public init(workspace: SpatialInstrumentWorkspace, excludingLayers: Set<UUID>) {
        grid = workspace.grid
        layers = workspace.layers.filter { $0.isVisible && !excludingLayers.contains($0.id) }
        audibilityOpacity = Self.audibility(workspace)
        // A common dyadic tessellation makes shared arcs byte-identical,
        // including a ring change with two smaller angular neighbors.
        let arcStep: Double = (layers.flatMap { $0.polarCells }.map {
            let segment = PolarMetricCellSegment(cell: $0, grid: workspace.grid)
            return segment.endBearingDegrees-segment.startBearingDegrees
        }.min() ?? 4.0) / 4.0
        var result: [Region] = []
        for layer in layers {
            let cells = layer.polarCells.sorted { ($0.ring, $0.angularIndex) < ($1.ring, $1.angularIndex) }
            let values = SpatialInstrumentEvaluator().cellValues(layerID: layer.id, cells: cells, workspace: workspace)
            let sceneActions = Dictionary(uniqueKeysWithValues: cells.compactMap { cell in
                SpatialScenePresentation.action(cell: cell, layer: layer).map { (cell, $0) }
            })
            let releaseTargets = Dictionary(uniqueKeysWithValues: cells.compactMap { cell in
                SpatialReleaseLayerPresentation.target(cell: cell, layer: layer).map { (cell, $0) }
            })
            let segments = Dictionary(uniqueKeysWithValues: cells.map { ($0, PolarMetricCellSegment(cell: $0, grid: workspace.grid)) })
            let adjacency = Dictionary(uniqueKeysWithValues: cells.map { cell in
                (cell, Self.candidates(cell, grid: workspace.grid).filter { candidate in
                    segments[candidate] != nil && Self.neighbors(cell,candidate,segments: segments)
                })
            })
            var remaining = Set(cells)
            for seed in cells where remaining.remove(seed) != nil {
                var component = [seed], cursor = 0
                while cursor < component.count {
                    let current = component[cursor]; cursor += 1
                    for candidate in adjacency[current]! where remaining.contains(candidate) && values[current] == values[candidate] && sceneActions[current] == sceneActions[candidate] && releaseTargets[current] == releaseTargets[candidate] {
                        remaining.remove(candidate); component.append(candidate)
                    }
                }
                component.sort { ($0.ring, $0.angularIndex) < ($1.ring, $1.angularIndex) }
                let parts = component.map { segments[$0]! }
                let paths = parts.map { Self.path($0, angularStepDegrees: arcStep) }
                let cellMesh = CGMutablePath(); paths.forEach { cellMesh.addPath($0) }
                // Adjacent cells share one annular band for filling. Internal
                // radial edges belong only to the optional cell mesh, never
                // to thousands of separately tessellated fill subpaths.
                let fill = Self.mergedFill(parts, angularStepDegrees: arcStep)
                let boundary = Self.boundary(component, segments: segments, adjacency: adjacency)
                let outline = CGMutablePath()
                for edge in boundary {
                    switch edge {
                    case let .arc(radius, start, end): Self.appendArc(to: outline, radius: radius, start: start, end: end, move: true, step: arcStep)
                    case let .radial(inner, outer, bearing):
                        outline.move(to: Self.point(inner, bearing)); outline.addLine(to: Self.point(outer, bearing))
                    }
                }
                // Area-weighted polar mean (radius and bearing). A Cartesian
                // centroid of a wide ring band falls into its hole and would
                // pin the label to the inner edge.
                var weight = 0.0, radius = 0.0, bearing = 0.0
                for part in parts {
                    let a = part.startBearingDegrees * .pi / 180, b = part.endBearingDegrees * .pi / 180
                    let area = (b-a) * (pow(part.outerRadiusMeters,2)-pow(part.innerRadiusMeters,2)) / 2
                    let radial = (pow(part.outerRadiusMeters,3)-pow(part.innerRadiusMeters,3)) / 3
                    weight += area; radius += radial * (b-a)
                    bearing += area * (part.startBearingDegrees+part.endBearingDegrees) / 2
                }
                let centroid = Self.point(radius / max(weight, 1e-12), bearing / max(weight, 1e-12))
                let anchor = component.min { lhs, rhs in
                    let l = Self.center(segments[lhs]!), r = Self.center(segments[rhs]!)
                    let ld = hypot(l.x-centroid.x,l.y-centroid.y), rd = hypot(r.x-centroid.x,r.y-centroid.y)
                    return abs(ld-rd) < 1e-10 ? (lhs.ring,lhs.angularIndex) < (rhs.ring,rhs.angularIndex) : ld < rd
                }!
                result.append(.init(layerID: layer.id, cells: component, fill: fill, outline: outline,
                    cellPaths: paths, cellMesh: cellMesh, boundary: boundary,
                    label: sceneActions[seed].map { SpatialScenePresentation.name($0, scenes: workspace.scenes) }
                        ?? releaseTargets[seed].map { "Release " + SpatialReleaseLayerPresentation.name($0, workspace: workspace) }
                        ?? values[seed].flatMap { value in layer.routings.first.flatMap { SpatialCellLabel.text(for: value, target: $0.target, preferredChordName: layer.name) } },
                    anchor: anchor, center: Self.center(segments[anchor]!), bounds: fill.boundingBoxOfPath,
                    hasOwnValue: component.contains { SpatialCellLabel.hasOwnValue(cell: $0, layer: layer) }))
            }
        }
        regions = result
        prepareLabelSelections()
    }

    /// Muted layers remain editable underneath audible layers. Selection
    /// breaks ties only within an audibility group, never against sound.
    public func paintOrder(selectedLayerID: UUID) -> [SpatialInstrumentLayer] {
        let displayed = layers.filter { isDisplayed($0.id) }
        let selectedLast = displayed.filter { $0.id != selectedLayerID } + displayed.filter { $0.id == selectedLayerID }
        return selectedLast.filter { audibilityOpacity[$0.id] != 1 }
            + selectedLast.filter { audibilityOpacity[$0.id] == 1 }
    }

    private func labelOwners(selectedLayerID: UUID?) -> [PolarMetricGridCell: UUID] {
        CanvasTimingProbe.recordOnMain("plan.labelOwners")
        var owners: [PolarMetricGridCell: UUID] = [:]
        let order = selectedLayerID.map { paintOrder(selectedLayerID: $0) }
            ?? (layers.filter { isDisplayed($0.id) && audibilityOpacity[$0.id] != 1 } + layers.filter { audibilityOpacity[$0.id] == 1 })
        for layer in order { for cell in layer.polarCells { owners[cell] = layer.id } }
        return owners
    }
    public func labelCell(for region: Region, selectedLayerID: UUID) -> PolarMetricGridCell? {
        labelCell(for: region, owners: labelOwners(selectedLayerID: selectedLayerID))
    }
    private func labelCell(for region: Region, owners: [PolarMetricGridCell: UUID]) -> PolarMetricGridCell? {
        guard audibilityOpacity[region.layerID] == 1 else { return nil }
        let exposed = region.cells.filter { owners[$0] == region.layerID }
        if exposed.contains(region.anchor) { return region.anchor }
        return exposed.min { lhs, rhs in
            let l = Self.center(.init(cell: lhs, grid: grid)), r = Self.center(.init(cell: rhs, grid: grid))
            let ld = hypot(l.x-region.center.x,l.y-region.center.y), rd = hypot(r.x-region.center.x,r.y-region.center.y)
            return abs(ld-rd) < 1e-10 ? (lhs.ring,lhs.angularIndex) < (rhs.ring,rhs.angularIndex) : ld < rd
        }
    }
    public static func center(_ part: PolarMetricCellSegment) -> CGPoint {
        point((part.innerRadiusMeters+part.outerRadiusMeters)/2, (part.startBearingDegrees+part.endBearingDegrees)/2)
    }
    private static func candidates(_ cell: PolarMetricGridCell, grid: MetricSquareGrid) -> [PolarMetricGridCell] {
        let segment = PolarMetricCellSegment(cell: cell,grid: grid)
        var result: [PolarMetricGridCell] = [.init(ring: cell.ring,angularIndex: cell.angularIndex-1),.init(ring: cell.ring,angularIndex: cell.angularIndex+1)]
        for ring in [cell.ring-1,cell.ring+1] where ring >= 0 {
            let step = PolarMetricCellSegment.angularStepDegrees(outerRadiusMeters: Double(ring+1)*grid.cellSizeMeters,radialHeightMeters: grid.cellSizeMeters)
            let lower = Int(floor((segment.startBearingDegrees+180)/step))
            let upper = Int(ceil((segment.endBearingDegrees+180)/step))-1
            for index in lower...max(lower,upper) { result.append(.init(ring: ring,angularIndex: index)) }
        }
        return result
    }
    private static func neighbors(_ a: PolarMetricGridCell, _ b: PolarMetricGridCell,
                                  segments: [PolarMetricGridCell: PolarMetricCellSegment]) -> Bool {
        if a.ring == b.ring { return abs(a.angularIndex-b.angularIndex) == 1 }
        guard abs(a.ring-b.ring) == 1, let l = segments[a], let r = segments[b] else { return false }
        return min(l.endBearingDegrees,r.endBearingDegrees) > max(l.startBearingDegrees,r.startBearingDegrees) + 1e-10
    }
    private static func boundary(_ cells: [PolarMetricGridCell], segments: [PolarMetricGridCell: PolarMetricCellSegment],
                                 adjacency: [PolarMetricGridCell: [PolarMetricGridCell]]) -> [Boundary] {
        let members = Set(cells)
        var edges: [Boundary] = []
        for cell in cells {
            let part = segments[cell]!
            let adjacent = adjacency[cell]!.filter { members.contains($0) }.map { segments[$0]! }
            for radius in [part.innerRadiusMeters, part.outerRadiusMeters] where radius > 0 {
                var intervals = [(part.startBearingDegrees,part.endBearingDegrees)]
                for other in adjacent where
                    (radius == part.innerRadiusMeters ? other.outerRadiusMeters == radius : other.innerRadiusMeters == radius) {
                    intervals = intervals.flatMap { a,b -> [(Double,Double)] in
                        let lo = max(a,other.startBearingDegrees), hi = min(b,other.endBearingDegrees)
                        guard hi > lo else { return [(a,b)] }
                        var rest: [(Double,Double)] = []
                        if a < lo { rest.append((a,lo)) }; if hi < b { rest.append((hi,b)) }
                        return rest
                    }
                }
                edges += intervals.map { .arc(radius: radius, start: $0.0, end: $0.1) }
            }
            for bearing in [part.startBearingDegrees,part.endBearingDegrees] {
                let shared = adjacent.contains { other in
                    other.innerRadiusMeters == part.innerRadiusMeters && other.outerRadiusMeters == part.outerRadiusMeters &&
                    (bearing == part.startBearingDegrees ? other.endBearingDegrees == bearing : other.startBearingDegrees == bearing) }
                if !shared { edges.append(.radial(inner: part.innerRadiusMeters, outer: part.outerRadiusMeters, bearing: bearing)) }
            }
        }
        return edges
    }
    private static func mergedFill(_ parts: [PolarMetricCellSegment], angularStepDegrees: Double) -> CGPath {
        let fill = CGMutablePath()
        var run: PolarMetricCellSegment?
        for part in parts {
            if let previous = run, previous.innerRadiusMeters == part.innerRadiusMeters,
               previous.outerRadiusMeters == part.outerRadiusMeters,
               previous.endBearingDegrees == part.startBearingDegrees {
                run = .init(innerRadiusMeters: previous.innerRadiusMeters, outerRadiusMeters: previous.outerRadiusMeters,
                    startBearingDegrees: previous.startBearingDegrees, endBearingDegrees: part.endBearingDegrees)
            } else {
                if let run { fill.addPath(path(run, angularStepDegrees: angularStepDegrees)) }
                run = part
            }
        }
        if let run { fill.addPath(path(run, angularStepDegrees: angularStepDegrees)) }
        return fill
    }

    private static func point(_ radius: Double, _ bearing: Double) -> CGPoint {
        .init(x: sin(bearing * .pi / 180)*radius, y: cos(bearing * .pi / 180)*radius)
    }
    private static func appendArc(to path: CGMutablePath, radius: Double, start: Double, end: Double, move: Bool, step: Double) {
        let count = max(2, Int((abs(end-start)/step).rounded()))
        for i in 0...count {
            let p = point(radius,start+(end-start)*Double(i)/Double(count))
            if i == 0 && move { path.move(to: p) } else { path.addLine(to: p) }
        }
    }
    private static func path(_ part: PolarMetricCellSegment, angularStepDegrees _: Double) -> CGPath {
        let path = CGMutablePath()
        path.move(to: point(part.outerRadiusMeters, part.startBearingDegrees))
        curvedArc(to: path, radius: part.outerRadiusMeters, start: part.startBearingDegrees, end: part.endBearingDegrees)
        path.addLine(to: point(part.innerRadiusMeters, part.endBearingDegrees))
        if part.innerRadiusMeters > 0 {
            curvedArc(to: path, radius: part.innerRadiusMeters, start: part.endBearingDegrees, end: part.startBearingDegrees)
        }
        path.closeSubpath()
        return path
    }

    /// Short native circular arcs avoid thousands of oversampled straight
    /// edges in the compositor. Splitting at 22.5° keeps curvature accurate
    /// far below the 1-cm document lattice, also at maximum editor zoom.
    private static func curvedArc(to path: CGMutablePath, radius: Double, start: Double, end: Double) {
        let count = max(1, Int(ceil(abs(end - start) / 22.5)))
        for index in 0..<count {
            let a = start + (end - start) * Double(index) / Double(count)
            let b = start + (end - start) * Double(index + 1) / Double(count)
            path.addArc(center: .zero, radius: radius, startAngle: (90 - a) * .pi / 180,
                endAngle: (90 - b) * .pi / 180, clockwise: end > start)
        }
    }
}
