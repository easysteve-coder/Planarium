import Foundation
import PLSDeviceValues

/// Where a world point lies relative to a surface. The editor picks surfaces with this and with
/// nothing else, so what a click selects is what the rasteriser would fill.
public extension SpatialSurface {
    /// The original shape and its placement; `nil` for an exact mask.
    var placedShape: SurfacePlacedShape? {
        if case .shape(let shape, let transform) = form { return SurfacePlacedShape(shape: shape, transform: transform) }
        return nil
    }

    /// Does the surface contain this world point (centimetres, +x right, +y forward)? A shape answers
    /// with the predicate the rasteriser uses; an exact mask answers with the cell under the point.
    func containsWorldPoint(xCm: Double, yCm: Double) -> Bool {
        guard xCm.isFinite, yCm.isFinite else { return false }
        switch form {
        case .shape(let shape, let transform):
            return SurfacePlacedShape(shape: shape, transform: transform).contains(x: xCm, y: yCm)
        case .legacyMask(let mask):
            guard yCm >= 0 else { return false }
            let radius = hypot(xCm, yCm), bearing = atan2(xCm, yCm) * 180 / .pi
            let ring = (radius).rounded(), tick = ((bearing + 90) / 0.5).rounded()
            guard ring >= 1, ring <= Double(PolarDeviceLattice.maxRing), tick >= 0, tick <= Double(PolarDeviceLattice.maxTick),
                  let cell = PolarDeviceLattice(ring: Int(ring), sector: Int(tick)) else { return false }
            return mask.cells.contains(cell)
        }
    }

    /// Box around the footprint in world centimetres: the outline of a shape, or the cells of a mask.
    var worldBounds: SurfaceBounds {
        if let placed = placedShape { return placed.worldBounds }
        var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
        for cell in derivation.cells {
            let p = SurfaceGrid.point(ring: cell.ring, tick: cell.sector)
            minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        guard minX.isFinite else { return SurfaceBounds(minX: 0, maxX: 0, minY: 0, maxY: 0) }
        return SurfaceBounds(minX: minX, maxX: maxX, minY: minY, maxY: maxY)
    }
}
