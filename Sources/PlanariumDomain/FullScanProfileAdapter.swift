import PLSDeviceValues
import SickPLSCore

public enum FullScanProfileAdapterError: Error, Equatable, Sendable {
    case unsupportedProfileGeometry
}

public enum FullScanProfileAdapter {
    /// Observed product modes. B0 has no independent angle metadata; partial
    /// scans therefore cannot assert the forward semicircle and are rejected.
    public static func geometry(from profile: B0ScanProfile) throws -> ProfileGeometryIdentity {
        let count = profile.measurements.count
        guard profile.partialScanIndex == 0, [90, 180, 361].contains(count) else {
            throw FullScanProfileAdapterError.unsupportedProfileGeometry
        }
        let span = ScanAngularSpan.forwardSemicircle
        return .init(operatingMode: count == 90 ? "segmentMinimum" : "fullScan",
                     pointCount: count, startAngleDegrees: span.startDegrees, endAngleDegrees: span.endDegrees)
    }

    public static func measurements(
        from profile: B0ScanProfile,
        geometry suppliedGeometry: ProfileGeometryIdentity? = nil
    ) throws -> [DeviceTickMeasurement] {
        let geometry = try geometry(from: profile)
        guard suppliedGeometry == nil || suppliedGeometry == geometry else {
            throw FullScanProfileAdapterError.unsupportedProfileGeometry
        }
        return profile.measurements.enumerated().compactMap { index, measurement in
            guard let ticks = geometry.tickSpan(at: index) else { return nil }
            return DeviceTickMeasurement(
                order: index, ticks: ticks, rawCentimeters: measurement.value
            )
        }
    }

    public static func adapt(
        _ profile: B0ScanProfile,
        geometry: ProfileGeometryIdentity? = nil
    ) throws -> [DeviceTickMeasurement] {
        try measurements(from: profile, geometry: geometry)
    }
}
