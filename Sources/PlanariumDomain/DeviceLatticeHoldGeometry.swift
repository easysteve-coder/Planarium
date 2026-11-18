import Foundation
import PLSDeviceValues

/// Reine Halteprüfung für das V2-Geräteraster. Sie bildet keine Zelle aus
/// einer Spanne; sie prüft nur eine bereits gewählte, revisionsgebundene Zelle.
public struct DeviceLatticeHoldGeometry: Sendable {
    public init() {}

    internal func contains(_ measurement: DeviceTickMeasurement, active: PolarDeviceLattice,
                           layer: CompiledInstrumentLayer, margin: SpatialHysteresisConfiguration) -> Bool {
        guard let snap = margin.snapCentimeters, snap > 0 else {
            return contains(measurement, in: active, margin: margin)
        }
        guard let anchor = layer.snapRegionByCell[active], let segments = layer.snapGeometry[anchor] else { return false }
        let radius = Double(measurement.rawCentimeters)
        let lower = PolarDeviceLattice.bearingDegrees(forTick: measurement.ticks.lower)
        let upper = PolarDeviceLattice.bearingDegrees(forTick: measurement.ticks.upper)
        return segments.contains { segment in
            let radialDistance = max(segment.innerRadiusMeters * 100 - radius,
                                     radius - segment.outerRadiusMeters * 100, 0)
            guard radialDistance <= Double(snap) + 1e-9 else { return false }
            let angleDistance = max(segment.startBearingDegrees - upper,
                                    lower - segment.endBearingDegrees, 0)
            let arcDistance = radius * angleDistance * .pi / 180
            return arcDistance <= Double(snap) + 1e-9
        }
    }

    public func contains(
        _ measurement: DeviceTickMeasurement,
        in cell: PolarDeviceLattice,
        margin: SpatialHysteresisConfiguration
    ) -> Bool {
        let radialDistance = abs(Int(measurement.rawCentimeters) - cell.ring)
        guard radialDistance <= Int(margin.radialMarginCentimeters) else { return false }
        let lower = max(0, cell.sector - margin.angularMarginTicks)
        let upper = min(PolarDeviceLattice.maxTick, cell.sector + margin.angularMarginTicks)
        return measurement.ticks.lower <= upper && measurement.ticks.upper >= lower
    }
}
