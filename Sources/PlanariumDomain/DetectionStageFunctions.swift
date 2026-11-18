import Foundation

/// Pure stage calculations; temporal state remains owned by the pipeline.

extension DetectionBeamsConfiguration {
    public func virtualMMKWindowDegrees(distanceCentimeters: Double) -> Double {
        switch virtualMMKMode {
        case .raw: return 0
        case .fixed1: return 1
        case .fixed2: return 2
        case .adaptive: return Double(virtualMMKTargetWidthCentimeters) / max(distanceCentimeters, 1) * 180 / .pi
        }
    }

    public func virtualMMKWeight(fractionOfHalfWidth fraction: Double) -> Double {
        guard abs(fraction) <= 1 else { return 0 }
        if virtualMMKSoftness == 0 { return 1 }
        return pow(max(0, 1 - abs(fraction)), 1 + Double(virtualMMKSoftness) / 25)
    }

    internal func virtualMMK(_ measurements: [ProjectedScanMeasurement], geometry: ProfileGeometryIdentity) -> [ProjectedScanMeasurement] {
        guard self.virtualMMKMode != .raw, measurements.count > 1 else { return measurements }
        let step = abs((geometry.endAngleDegrees - geometry.startAngleDegrees) / Double(max(1, geometry.pointCount - 1)))
        guard step > 0 else { return measurements }
        // A complete profile is already indexed by measured order. Bound the
        // neighbour traversal to the angular window instead of scanning every
        // ray for each foreground point. Gapped/other inputs retain their
        // original traversal and tie order.
        let dense = measurements.count == geometry.pointCount && measurements.enumerated().allSatisfy { $0.offset == $0.element.order }
        let distances = dense ? [:] : Dictionary(uniqueKeysWithValues: measurements.map { ($0.order, Double($0.distanceCentimeters)) })
        func replacing(_ measurement: ProjectedScanMeasurement, distance: Double) -> ProjectedScanMeasurement {
            let clipped = UInt16(min(max(distance.rounded(), 0), Double(UInt16.max)))
            let scale = Double(clipped) / max(Double(measurement.distanceCentimeters), 1)
            return .init(order: measurement.order, normalizedIndex: measurement.normalizedIndex, distanceCentimeters: clipped,
                         fieldFlags: measurement.fieldFlags, point: .init(xMeters: measurement.point.xMeters * scale,
                                                                            yMeters: measurement.point.yMeters * scale))
        }
        if self.virtualMMKSoftness == 0,
           self.virtualMMKMode == .fixed1 || self.virtualMMKMode == .fixed2 {
            let degrees = self.virtualMMKMode == .fixed1 ? 1.0 : 2.0
            var minima: [Int: Double] = [:]
            for value in measurements {
                let bucket = Int(floor((Double(value.order) * step) / degrees))
                minima[bucket] = min(minima[bucket] ?? .greatestFiniteMagnitude, Double(value.distanceCentimeters))
            }
            return measurements.map { value in
                replacing(value, distance: minima[Int(floor((Double(value.order) * step) / degrees))] ?? Double(value.distanceCentimeters))
            }
        }
        return measurements.map { value in
            let widthDegrees = self.virtualMMKWindowDegrees(distanceCentimeters: Double(value.distanceCentimeters))
            let halfWidth = widthDegrees / 2
            guard halfWidth >= step / 2 else { return value }
            // Ceil deliberately includes the outer neighbour; the unchanged
            // angular comparison below decides the exact floating boundary.
            let radius = Int(min(Double(measurements.count), ceil(halfWidth / step)))
            let window = dense
                ? measurements[max(0, value.order - radius)..<min(measurements.count, value.order + radius + 1)]
                : measurements[...]
            let candidates = window.compactMap { other -> (distance: Double, weight: Double)? in
                let angularDistance = abs(Double(other.order - value.order)) * step
                guard angularDistance <= halfWidth else { return nil }
                // Softness makes edge rays progressively less dominant;
                // zero was handled above as the exact hard minimum.
                let weight = self.virtualMMKWeight(fractionOfHalfWidth: angularDistance / max(halfWidth, .leastNonzeroMagnitude))
                return (distances[other.order] ?? Double(other.distanceCentimeters), weight)
            }
            guard let nearest = candidates.map(\.distance).min() else { return value }
            if self.virtualMMKSoftness == 0 { return replacing(value, distance: nearest) }
            let edgeWeight = candidates.first(where: { $0.distance == nearest })?.weight ?? 1
            let mixed = Double(value.distanceCentimeters) * (1 - edgeWeight) + nearest * edgeWeight
            return replacing(value, distance: mixed)
        }
    }
}

extension DetectionGroupsConfiguration {
    internal func makeGroups(_ measurements: [ProjectedScanMeasurement]) -> [[ProjectedScanMeasurement]] {
        guard self.groupingEnabled else { return measurements.map { [$0] } }
        guard !measurements.isEmpty else { return [] }
        var result: [[ProjectedScanMeasurement]] = [[measurements[0]]]
        for measurement in measurements.dropFirst() {
            guard let last = result.last?.last else { continue }
            if measurement.order == last.order + 1,
               abs(Int(measurement.distanceCentimeters) - Int(last.distanceCentimeters)) <= Int(self.groupingJumpCentimeters) {
                result[result.count - 1].append(measurement)
            } else {
                result.append([measurement])
            }
        }
        return result.filter { $0.count >= self.groupingMinimumPoints }
    }

    internal func distance(of group: [ProjectedScanMeasurement]) -> Double {
        group.map { Double($0.distanceCentimeters) }.min() ?? .greatestFiniteMagnitude
    }

    internal func separatedGroups(_ groups: [[ProjectedScanMeasurement]], measurements: [DeviceTickMeasurement]) -> [[ProjectedScanMeasurement]] {
        guard self.minimumAngleDegrees > 0 else { return groups }
        let spans = Dictionary(measurements.map { ($0.order, $0.ticks) }, uniquingKeysWith: { first, _ in first })
        let candidates = groups.map { group in
            let values = group.compactMap { spans[$0.order] }
            return (group: group, distance: distance(of: group),
                lower: values.map(\.lower).min() ?? 0, upper: values.map(\.upper).max() ?? 360)
        }
        var kept: [(group: [ProjectedScanMeasurement], distance: Double, lower: Int, upper: Int)] = []
        for candidate in candidates.sorted(by: {
            $0.distance == $1.distance ? $0.group[0].order < $1.group[0].order : $0.distance < $1.distance
        }) {
            let shadowed = kept.contains { near in
                guard near.distance < candidate.distance else { return false }
                let gap = max(0, max(candidate.lower - near.upper, near.lower - candidate.upper))
                return gap < self.minimumAngleDegrees * 2
            }
            if !shadowed { kept.append(candidate) }
        }
        return kept.map(\.group).sorted { $0[0].order < $1[0].order }
    }
}

extension DetectionEdgeConfiguration {
    internal func trimEdges(_ group: [ProjectedScanMeasurement], minimumPoints: Int) -> [ProjectedScanMeasurement] {
        guard edgePoints > 0 else { return group }
        let minimum = max(1, minimumPoints)
        var lower = 0, upper = group.count
        // Compare inward at each step; strictly farther by >3 cm. Never
        // discard the nearer finger, or cross the minimum-points floor.
        for _ in 0..<edgePoints {
            guard upper - lower > minimum else { break }
            if Int(group[lower].distanceCentimeters) - Int(group[lower + 1].distanceCentimeters) > Self.thresholdCentimeters { lower += 1 }
            else { break }
        }
        for _ in 0..<edgePoints {
            guard upper - lower > minimum else { break }
            if Int(group[upper - 1].distanceCentimeters) - Int(group[upper - 2].distanceCentimeters) > Self.thresholdCentimeters { upper -= 1 }
            else { break }
        }
        return Array(group[lower..<upper])
    }
}

extension DetectionCoreConfiguration {
    internal func corePoints(_ group: [ProjectedScanMeasurement]) -> [ProjectedScanMeasurement] {
        guard coreWidthCentimeters > 0, !group.isEmpty else { return group }
        let middle = group[group.count / 2].point
        let radius = max(hypot(middle.xMeters, middle.yMeters), .leastNonzeroMagnitude)
        let core = group.filter {
            abs($0.point.xMeters * middle.yMeters / radius - $0.point.yMeters * middle.xMeters / radius) <= Double(coreWidthCentimeters) / 200 + 1e-12
        }
        return core.isEmpty ? [group[group.count / 2]] : core
    }

    internal func coreStrip(_ group: [ProjectedScanMeasurement]) -> [MetricScanPoint] {
        guard coreWidthCentimeters > 0, !group.isEmpty else { return [] }
        let middle = group[group.count / 2].point
        let bearing = atan2(middle.xMeters, middle.yMeters)
        let half = Double(coreWidthCentimeters) / 200
        let extent = group.map { hypot($0.point.xMeters, $0.point.yMeters) }.max()! + 1
        return [(-half, 0.0), (half, 0.0), (half, extent), (-half, extent)].map { tangent, radial in
            .init(xMeters: tangent * cos(bearing) + radial * sin(bearing), yMeters: -tangent * sin(bearing) + radial * cos(bearing))
        }
    }
}

extension DetectionRepresentativeConfiguration {
    internal func makeRepresentative(_ group: [ProjectedScanMeasurement]) -> DetectionRepresentative {
        guard let nearest = group.min(by: {
            $0.distanceCentimeters == $1.distanceCentimeters ? $0.order < $1.order : $0.distanceCentimeters < $1.distanceCentimeters
        }) else { return DetectionRepresentative(point: .init(xMeters: 0, yMeters: 0)) }
        switch self.representative {
        case .nearestPoint:
            return DetectionRepresentative(point: nearest.point)
        case .nearestPointWithOffset:
            let radius = hypot(nearest.point.xMeters, nearest.point.yMeters) + Double(self.representativeOffsetCentimeters) / 100
            let scale = radius / max(hypot(nearest.point.xMeters, nearest.point.yMeters), 0.000_001)
            return DetectionRepresentative(point: .init(xMeters: nearest.point.xMeters * scale, yMeters: nearest.point.yMeters * scale))
        case .mean:
            let x = group.reduce(0) { $0 + $1.point.xMeters } / Double(group.count)
            let y = group.reduce(0) { $0 + $1.point.yMeters } / Double(group.count)
            return representativeOnMeasuredPoint(near: .init(xMeters: x, yMeters: y), in: group)
        case .median:
            let xs = group.map(\.point.xMeters).sorted()
            let ys = group.map(\.point.yMeters).sorted()
            return representativeOnMeasuredPoint(
                near: .init(xMeters: xs[xs.count / 2], yMeters: ys[ys.count / 2]), in: group
            )
        }
    }

    private func representativeOnMeasuredPoint(
        near target: MetricScanPoint,
        in group: [ProjectedScanMeasurement]
    ) -> DetectionRepresentative {
        let measured = group.min { lhs, rhs in
            let leftDistance = hypot(lhs.point.xMeters - target.xMeters, lhs.point.yMeters - target.yMeters)
            let rightDistance = hypot(rhs.point.xMeters - target.xMeters, rhs.point.yMeters - target.yMeters)
            return leftDistance == rightDistance ? lhs.order < rhs.order : leftDistance < rightDistance
        } ?? group[0]
        return DetectionRepresentative(point: measured.point)
    }
}

extension DetectionTimeConfiguration {
    internal var historyCapacity: Int {
        switch temporalSmoothing {
        case .mean(let n), .median(let n): return max(max(1, n), 8)
        case .off, .exponential: return 8
        }
    }

    /// The pipeline owns the EXP accumulator. Passing it in place avoids a
    /// dictionary copy-on-write on every profile while preserving value state.
    internal func smooth(_ current: [ProjectedScanMeasurement], history: [[ProjectedScanMeasurement]], exponential: inout [Int: Double], advanceExponential: Bool) -> [ProjectedScanMeasurement] {
        guard !history.isEmpty else { return current }
        // Traverse the retained profiles once, preserving sample order and
        // gaps. Exponential smoothing needs only its previous per-order value.
        var samplesByOrder: [Int: [UInt16]] = [:]
        switch temporalSmoothing {
        case .mean, .median:
            for profile in history {
                for point in profile { samplesByOrder[point.order, default: []].append(point.distanceCentimeters) }
            }
        case .off, .exponential: break
        }
        let result = current.map { measurement in
            let sameOrder = samplesByOrder[measurement.order] ?? []
            let value: Double
            switch temporalSmoothing {
            case .mean(let window):
                value = sameOrder.suffix(max(1, window)).map { Double($0) }.reduce(0, +) / Double(max(1, sameOrder.suffix(max(1, window)).count))
            case .median(let window):
                let values = sameOrder.suffix(max(1, window)).map { Double($0) }.sorted()
                value = values.isEmpty ? Double(measurement.distanceCentimeters) : values[values.count / 2]
            case .exponential(let alpha):
                let previous = exponential[measurement.order] ?? Double(measurement.distanceCentimeters)
                value = advanceExponential ? alpha * Double(measurement.distanceCentimeters) + (1 - alpha) * previous : previous
                if advanceExponential { exponential[measurement.order] = value }
            case .off:
                value = Double(measurement.distanceCentimeters)
            }
            return ProjectedScanMeasurement(
                order: measurement.order,
                normalizedIndex: measurement.normalizedIndex,
                distanceCentimeters: UInt16(min(max(value.rounded(), 0), Double(UInt16.max))),
                fieldFlags: measurement.fieldFlags,
                point: MetricScanPoint(
                    xMeters: measurement.point.xMeters * value / max(Double(measurement.distanceCentimeters), 1),
                    yMeters: measurement.point.yMeters * value / max(Double(measurement.distanceCentimeters), 1)
                )
            )
        }
        return result
    }
}

extension SpatialRoomContourConfiguration {
    internal func filter(_ measurements: [ProjectedScanMeasurement], contour: SpatialRoomContour?,
                         geometry: SpatialRoomContour.Geometry, matches: Bool) -> (measurements: [ProjectedScanMeasurement], rejectedOrders: Set<Int>) {
        let exactGeometry = contour?.geometry == geometry
        var rejected = Set<Int>()
        let kept = measurements.filter { measurement in
            if isEnabled, let contour, matches,
               !(exactGeometry
                 ? contour.filters(distanceCentimeters: measurement.distanceCentimeters, at: measurement.order,
                                   toleranceCentimeters: toleranceCentimeters)
                 : contour.filters(distanceCentimeters: measurement.distanceCentimeters,
                                   bearingDegrees: geometry.startAngleDegrees + Double(measurement.order) * geometry.angleResolutionDegrees,
                                   spanDegrees: geometry.angleResolutionDegrees, toleranceCentimeters: toleranceCentimeters)) {
                rejected.insert(measurement.order); return false
            }
            return true
        }
        return (kept, rejected)
    }
}

extension DetectionCellsConfiguration {
    /// Value-state transformation, with no hidden history or output boundary.
    /// The caller remains the sole owner of Snap/confirmation/backlash state.
    internal func select(_ measurements: [DeviceTickMeasurement], instrument: CompiledInstrument,
                         geometry: ProfileGeometryIdentity, state: inout DeviceLatticeSelector) -> DeviceLatticeSelection {
        state.step(measurements: measurements, instrument: instrument, geometry: geometry,
                   configuration: selectorConfiguration)
    }

    internal var selectorConfiguration: SpatialHysteresisConfiguration {
        .init(radialMarginCentimeters: cellSelection.boundaryMarginCentimeters,
              angularMarginTicks: 0, switchConfirmationProfiles: cellSelection.confirmationProfiles,
              continuousBacklashCentimeters: continuousBacklashCentimeters,
              snapCentimeters: cellSelection.boundaryMarginCentimeters)
    }
}

