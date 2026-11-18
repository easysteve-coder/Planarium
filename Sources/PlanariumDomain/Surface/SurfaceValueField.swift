import Foundation
import PLSDeviceValues

/// What a surface's CC or scale assignment does over the surface, asked of the same value plan the
/// runtime uses (`CompiledValuePlan` over the surface's own cells, with the axis in the world
/// frame). The preview is drawn from this and nothing else: there is no second CC or note
/// calculator, and no gate, note-off or panic ever comes from it.
///
/// A sample is taken at the cell's anchor (its ring). The runtime of a continuous value uses the
/// measured distance of the hand, which lies anywhere inside the cell, so the live value differs
/// from the sample by that offset projected on the axis, scaled by the surface's extent and the
/// curve; no bound is claimed here. A scale is evaluated from the cell only, so sample and live
/// note are equal. The preview is a picture of the assignment, not a guarantee of any live value.
public struct SurfaceValueField: Sendable {
    public struct Sample: Equatable, Sendable {
        /// Position along the axis, 0 at the start and 1 at the end of the surface's own extent.
        public let fraction: Double
        public let value: SpatialEvaluatedValue
    }

    public enum Legend: Equatable, Sendable {
        /// The assignment has no course over the surface (constant, chord, single note, program, random scale).
        case none
        /// Along the arrow: `startValue` at its start, `endValue` at its tip, `curve` as the course
        /// between them seen from the start (an inverse range runs the program backwards, which
        /// swaps the values and mirrors the curve).
        case continuous(controller: UInt8?, startValue: Double, endValue: Double, curve: SpatialValueCurve)
        /// The notes the scale allows, lowest first; the arrow points toward the highest.
        case scale(notes: [Int])
    }

    public let routingID: UUID
    public let target: SpatialRoutingTarget
    public let legend: Legend
    /// World angle the arrow points to (toward the higher value or the higher note), in program convention.
    public let arrowDegrees: Double?
    /// Extent of the surface's cells projected on the axis, in centimetres (start, end).
    public let projectionCentimeters: ClosedRange<Double>?
    private let plan: CompiledValuePlan

    public enum Failure: Error, Equatable { case unknownRouting }

    public init(surface: SpatialSurface, routingID: UUID) throws {
        guard let routing = surface.materializedRoutings().first(where: { $0.id == routingID }) else { throw Failure.unknownRouting }
        self.routingID = routingID
        target = routing.target
        plan = CompiledValuePlan(program: routing.program, cells: surface.cells)
        arrowDegrees = SurfaceAxis.arrowDegrees(of: routing.program)
        switch routing.program {
        case let .continuous(minimum, maximum, _, curve):
            if SurfaceAxis.risesAgainstDirection(routing.program) {
                legend = .continuous(controller: routing.target.controllerNumber, startValue: maximum, endValue: minimum, curve: curve.mirrored)
            } else {
                legend = .continuous(controller: routing.target.controllerNumber, startValue: minimum, endValue: maximum, curve: curve)
            }
            projectionCentimeters = plan.minimumProjection...plan.maximumProjection
        case .scale:
            legend = .scale(notes: plan.allowedNotes)
            projectionCentimeters = plan.minimumProjection...plan.maximumProjection
        default:
            legend = .none
            projectionCentimeters = nil
        }
    }

    public func sample(_ cell: PolarDeviceLattice) -> Sample {
        .init(fraction: plan.fraction(for: cell, distance: nil), value: plan.value(activeCell: cell, candidateDistanceCentimeters: nil))
    }

    /// The fraction along the arrow, 0 at its start and 1 at its tip. Where the value or the note
    /// rises against the program angle (inverse CC range, descending scale) the runtime's fraction
    /// runs backwards, the arrow's does not.
    public func arrowFraction(_ cell: PolarDeviceLattice) -> Double {
        let fraction = plan.fraction(for: cell, distance: nil)
        return SurfaceAxis.risesAgainstDirection(plan.program) ? 1 - fraction : fraction
    }
}
