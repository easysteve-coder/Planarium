import Foundation
import PLSDeviceValues

/// Anzeige-only Teststrahlen fuer die Regler der Detektion. Sie durchlaufen
/// den Produktdetektor, werden aber nie an Runtime oder Ausgaenge weitergereicht.
public struct DetectionProbePresentation: Equatable, Sendable {
    /// Visible metric rectangle, supplied by the canvas (including pan/zoom).
    public struct Bounds: Equatable, Sendable {
        public let x: ClosedRange<Double>
        public let y: ClosedRange<Double>
        public init(x: ClosedRange<Double>, y: ClosedRange<Double>) { self.x = x; self.y = y }
        public func contains(_ point: MetricScanPoint) -> Bool { x.contains(point.xMeters) && y.contains(point.yMeters) }
        fileprivate func limit(bearing: Double) -> Double {
            let radians = bearing * .pi / 180
            let dx = sin(radians), dy = cos(radians)
            let horizontal = abs(dx) < 1e-9 ? Double.infinity : (dx > 0 ? x.upperBound : x.lowerBound) / dx
            let vertical = abs(dy) < 1e-9 ? Double.infinity : (dy > 0 ? y.upperBound : y.lowerBound) / dy
            return max(0, min(horizontal, vertical))
        }
    }
    public struct Mark: Equatable, Sendable {
        public let point: MetricScanPoint
        public let accepted: Bool
        public let merged: Bool
        public let pairID: Int?
        public let acceptedObjectIndices: Set<Int>
        public let measuredOrders: Set<Int>
    }

    public let marks: [Mark]
    public let representatives: [MetricScanPoint]
    /// Test evidence for the exact input passed to the display-only detector.
    public let insertedMeasurements: [DeviceTickMeasurement]
    public let objects: [DetectionObject]
    public let measuredPoints: [ProjectedScanMeasurement]

    public static func make(frame: ProfileFrame, instrument: CompiledInstrument,
                            contour: SpatialRoomContour?, bounds: Bounds? = nil) -> Self {
        var pipeline = SpatialDetectionPipeline(configuration: instrument.detection)
        return make(frame: frame, instrument: instrument, contour: contour, bounds: bounds, pipeline: &pipeline)
    }

    private static func make(frame: ProfileFrame, instrument: CompiledInstrument,
                             contour: SpatialRoomContour?, bounds: Bounds?, pipeline: inout SpatialDetectionPipeline,
                             radialOffsetCentimeters: Int = 0) -> Self {
        let probes = Probe.make(frame: frame, contour: contour, bounds: bounds, configuration: instrument.detection,
                                radialOffsetCentimeters: radialOffsetCentimeters)
        // At coarse scanner geometries neighbouring synthetic silhouettes can
        // quantize to the same beam. A scanner profile has one value per ray.
        let probeByOrder = Dictionary(probes.flatMap(\.measurements).map { ($0.order, $0) },
                                      uniquingKeysWith: { nearer, _ in nearer })
        // Keep every real beam. A synthetic ray may only replace it when it is
        // nearer, exactly as an inserted foreground object would occlude a wall.
        let realByOrder = Dictionary(frame.measurements.map { ($0.order, $0) }, uniquingKeysWith: { first, _ in first })
        let measurements = realByOrder.merging(probeByOrder) { real, probe in
            probe.rawCentimeters < real.rawCentimeters ? probe : real
        }.values.sorted { $0.order < $1.order }
        let probeFrame = ProfileFrame(sessionID: frame.sessionID, sequence: frame.sequence,
                                      time: frame.time, measurements: measurements,
                                      geometry: frame.geometry, sourceIdentifier: frame.sourceIdentifier)
        let selection = pipeline.selectForPresentation(frame: probeFrame, instrument: instrument, contour: contour)
        let accepted = selection.objects.map(\.representative.point)
        let visibleProbes = probes.map { probe in
            Set(probe.measurements.filter { probeByOrder[$0.order] == $0 &&
                (realByOrder[$0.order]?.rawCentimeters ?? UInt16.max) >= $0.rawCentimeters }.map(\.order))
        }
        let memberships = visibleProbes.map { orders in
            Set(selection.objects.indices.filter { !orders.isDisjoint(with: selection.objects[$0].measuredOrders) })
        }
        return .init(marks: probes.enumerated().map { index, probe in
            let merged = probes.indices.contains { other in
                other != index && probe.pairID != nil && probes[other].pairID == probe.pairID &&
                !memberships[index].isDisjoint(with: memberships[other])
            }
            return .init(point: probe.center, accepted: !memberships[index].isEmpty,
                         merged: merged, pairID: probe.pairID, acceptedObjectIndices: memberships[index], measuredOrders: visibleProbes[index])
        }, representatives: accepted, insertedMeasurements: measurements, objects: selection.objects,
           measuredPoints: probeFrame.projectedMeasurements)
    }

    /// A reproducible moving ghost, with history exclusively in this local
    /// detector. Frame sequence advances its phase even in an empty room.
    public static func smoothingTraces(frame: ProfileFrame, instrument: CompiledInstrument,
                                       contour: SpatialRoomContour?, bounds: Bounds? = nil) -> [[MetricScanPoint]] {
        motionTraces(frame: frame, instrument: instrument, contour: contour, bounds: bounds).smooth
    }

    public static func motionTraces(frame: ProfileFrame, instrument: CompiledInstrument,
                                    contour: SpatialRoomContour?, bounds: Bounds? = nil)
        -> (raw: [[MetricScanPoint]], smooth: [[MetricScanPoint]]) {
        var pipeline = SpatialDetectionPipeline(configuration: instrument.detection)
        var rawConfiguration = instrument.detection
        rawConfiguration.time.smoothingEnabled = false
        let rawInstrument = instrument.withDocumentSettings(detection: rawConfiguration, channel: instrument.channel,
            channels: instrument.channels, masterLevelDecibels: instrument.masterLevelDecibels,
            midiTarget: instrument.midiTarget, scenes: instrument.scenes, currentSceneID: instrument.currentSceneID)
        var rawPipeline = SpatialDetectionPipeline(configuration: rawConfiguration)
        var traces = Array(repeating: [MetricScanPoint](), count: 12)
        var rawTraces = traces
        let motion = [0, 14, 2, 16, 4, 18, 6, 20]
        for sample in motion.indices {
            let phase = (sample + Int(frame.sequence % UInt64(motion.count))) % motion.count
            let result = make(frame: frame, instrument: instrument, contour: contour,
                              bounds: bounds, pipeline: &pipeline, radialOffsetCentimeters: motion[phase])
            let raw = make(frame: frame, instrument: rawInstrument, contour: contour,
                           bounds: bounds, pipeline: &rawPipeline, radialOffsetCentimeters: motion[phase])
            for index in result.marks.indices {
                guard let object = result.marks[index].acceptedObjectIndices.sorted().first else { continue }
                traces[index].append(result.objects[object].representative.point)
            }
            for index in raw.marks.indices {
                guard let object = raw.marks[index].acceptedObjectIndices.sorted().first else { continue }
                rawTraces[index].append(raw.objects[object].representative.point)
            }
        }
        let length: Int
        switch instrument.detection.effective.time.temporalSmoothing {
        case .mean(let n), .median(let n): length = min(max(n, 2), motion.count)
        case .off, .exponential: length = motion.count
        }
        return (rawTraces.map { Array($0.suffix(length)) }, traces.map { Array($0.suffix(length)) })
    }

    private struct Probe {
        let center: MetricScanPoint
        let measurements: [DeviceTickMeasurement]
        let pairID: Int?

        static func make(frame: ProfileFrame, contour: SpatialRoomContour?, bounds: Bounds?,
                         configuration: DetectionConfiguration, radialOffsetCentimeters: Int = 0) -> [Probe] {
            let geometry = frame.geometry
            guard geometry.pointCount > 1, geometry.startAngleDegrees == -90, geometry.endAngleDegrees == 90 else { return [] }
            let step = (geometry.endAngleDegrees - geometry.startAngleDegrees) / Double(max(1, geometry.pointCount - 1))
            let contourGeometry = SpatialRoomContour.Geometry(pointCount: geometry.pointCount,
                angleResolutionDegrees: step, startAngleDegrees: geometry.startAngleDegrees, sourceIdentifier: frame.sourceIdentifier)
            let room = contour.flatMap { $0.compatibility(with: contourGeometry) ? $0 : nil }
            let measured = Dictionary(frame.measurements.map { ($0.order, Double($0.rawCentimeters) / 100) }, uniquingKeysWith: min)
            func available(_ order: Int) -> Double {
                let bearing = geometry.startAngleDegrees + Double(order) * step
                var limit = bounds?.limit(bearing: bearing) ?? Double.infinity
                if let value = measured[order], value > 0 { limit = min(limit, value) }
                if let room {
                    let index = Int(((bearing - room.geometry.startAngleDegrees) / room.geometry.angleResolutionDegrees).rounded())
                    if room.nearestDistancesCentimeters.indices.contains(index), let wall = room.nearestDistancesCentimeters[index] {
                        limit = min(limit, Double(wall) / 100)
                    }
                }
                return min(limit.isFinite ? limit : 2.5, Double(UInt16.max) / 100)
            }
            // Unequal angular slots leave space for the wider silhouettes at
            // the near distance. Whole groups are omitted when they cannot fit.
            let slots = [(-82.0, -8.0, 0.30), (-5.0, 45.0, 0.55), (48.0, 82.0, 0.80)]
            var result: [Probe] = []
            for (id, slot) in slots.enumerated() {
                let first = Int(ceil((slot.0 + 90) / step)), last = Int(floor((slot.1 + 90) / step))
                // Placement is independent of Offset. The outer fifth and
                // silhouette clearance also accommodate its 10 cm range.
                let clearance = Double(configuration.room.toleranceCentimeters) / 100 + 0.12
                let free = max(0, (first...last).map(available).min()! - clearance)
                let radius = free * slot.2
                guard radius >= 0.18 else { continue }
                let widths = [1.5, 8.0, 8.0, 8.0]
                let counts = widths.map { max(1, Int(ceil(2 * atan(($0 / 200) / radius) * 180 / .pi / step))) }
                // A one-ray shoulder per side. The two hands are adjacent
                // rays at different depths: Min. gap uses real membership.
                let shoulder = geometry.pointCount < 180 ? 0 : 1
                let lengths = counts.map { $0 + 2 * shoulder }
                let gap = max(2, Int(ceil(2 / step)))
                let total = lengths.reduce(0, +) + 2 * gap
                guard total <= last - first + 1 else { continue }
                var cursor = first + (last - first + 1 - total) / 2
                var group: [Probe] = []
                for index in widths.indices {
                    let lower = cursor + shoulder, upper = cursor + lengths[index] - shoulder - 1
                    let midpoint = (lower + upper) / 2
                    let motion = min(Double(radialOffsetCentimeters), max(0, free * (1 - slot.2) * 100 - 12))
                    let distance = radius * 100 + (index == 3 ? 6 : 0) + motion
                    let rays = (cursor..<(cursor + lengths[index])).compactMap { order -> DeviceTickMeasurement? in
                        guard let ticks = geometry.tickSpan(at: order) else { return nil }
                        let fraction = Double(order - lower) / Double(max(1, upper - lower))
                        // An asymmetric, stepped hand makes the actual measured
                        // Mean/Median/Nearest choice visible, including its core.
                        let depth = fraction < 0.2 ? 6 : fraction < 0.45 ? 0 : fraction < 0.7 ? 3 : 9
                        let mixedDepth = order < lower || order > upper ? 8 : 0
                        let rawDistance = UInt16(max(1, Int(distance) + depth + mixedDepth))
                        return DeviceTickMeasurement(order: order, ticks: ticks,
                                                     rawCentimeters: rawDistance)
                    }
                    let bearing = geometry.startAngleDegrees + Double(midpoint) * step
                    let radians = bearing * .pi / 180
                    group.append(.init(center: .init(xMeters: sin(radians) * distance / 100,
                        yMeters: cos(radians) * distance / 100), measurements: rays, pairID: index >= 2 ? id : nil))
                    cursor += lengths[index] + (index < 2 ? gap : 0)
                }
                guard group.flatMap(\.measurements).allSatisfy({ ray in
                    let bearing = geometry.startAngleDegrees + Double(ray.order) * step
                    let radians = bearing * .pi / 180, radius = Double(ray.rawCentimeters) / 100
                    return radius < available(ray.order) - Double(configuration.room.toleranceCentimeters) / 100 &&
                        (bounds?.contains(.init(xMeters: sin(radians) * radius, yMeters: cos(radians) * radius)) ?? true)
                }) else { continue }
                result += group
            }
            return result
        }
    }
}

/// Each regulator selects one pure metric presentation. No output boundary,
/// runtime owner, or musical detector is reachable from this value.
public enum DetectionOverlayControl: String, CaseIterable, Hashable, Sendable {
    case probe, contourTolerance, minimumGap, minimumPoints, minimumAngle
    case edgeMargin, holdMargin, smoothing, confirmation, targetWidth, softness, representative, offset

    public func isAvailable(configuration: DetectionConfiguration, hasMatchingContour: Bool, performing: Bool) -> Bool {
        let id: DetectionControlDescriptor.ID
        switch self {
        case .probe: return !performing
        case .contourTolerance: id = .contourTolerance
        case .minimumGap: id = .minimumGap
        case .minimumPoints: id = .minimumPoints
        case .minimumAngle: id = .minimumAngle
        case .edgeMargin: id = .snap
        case .holdMargin: id = .holdMargin
        case .smoothing: id = .smoothing
        case .confirmation: id = .confirmation
        case .targetWidth: id = .targetWidth
        case .softness: id = .softness
        case .representative: id = .representative
        case .offset: id = .offset
        }
        return DetectionControlDescriptor.descriptor(id).isAvailable(configuration: configuration,
            hasMatchingContour: hasMatchingContour, performing: performing)
    }

    public var legend: String {
        switch self {
        case .probe: "Probe · color: detected · pale: rejected · double ring: merged"
        case .contourTolerance: "Contour tolerance · fixed wall · shaded inner band · grey: filtered points"
        case .minimumGap: "Minimum gap · Allowed depth step"
        case .minimumPoints: "Minimum points · color: kept · pale: rejected"
        case .minimumAngle: "Minimum angle · Required spacing"
        case .edgeMargin: "Snap · inner region border distance"
        case .holdMargin: "Hold margin · outer cell distance guide"
        case .smoothing: "Smoothing · grey: raw · cyan: smoothed · bright: newest"
        case .confirmation: "Confirm · measured cell change"
        case .targetWidth: "Target width · window at this hand"
        case .softness: "Softness · Fade the window edge"
        case .representative: "Representative · Playing point"
        case .offset: "Offset · arrow: measured point to playing point"
        }
    }
}

public struct DetectionOverlayInteraction: Equatable, Sendable {
    public private(set) var hovered: [DetectionOverlayControl] = []
    public private(set) var editing: DetectionOverlayControl?
    public init() {}
    public var active: DetectionOverlayControl? { editing ?? hovered.last }
    public mutating func hover(_ control: DetectionOverlayControl, inside: Bool) {
        if inside { hovered.append(control) }
        else if let index = hovered.firstIndex(of: control) { hovered.remove(at: index) }
    }
    public mutating func edit(_ control: DetectionOverlayControl, editing: Bool) {
        if editing { self.editing = control }
        else if self.editing == control { self.editing = nil }
    }
    public mutating func reset() { hovered.removeAll(); editing = nil }
}

public struct DetectionOverlayPresentation: Equatable, Sendable {
    public enum Tone: Equatable, Sendable { case guide, kept, rejected, merged }
    public struct Shape: Equatable, Sendable {
        public let points: [MetricScanPoint]
        public let isClosed: Bool
        public let fillOpacity: Double
        public let tone: Tone
        public var strokeOpacity: Double = 1
        public var lineWidth: Double = 1
    }
    public struct Label: Equatable, Sendable {
        public let point: MetricScanPoint
        public let text: String
        public let tone: Tone
        public init(point: MetricScanPoint, text: String, tone: Tone) {
            self.point = point; self.text = text; self.tone = tone
        }
    }
    public let shapes: [Shape]
    public let labels: [Label]
    /// Classification at the real scan's measured orders, independent of ghosts.
    public let pointTones: [Int: Tone]
    public static let empty = Self(shapes: [], labels: [], pointTones: [:])

    /// Explanations use this acquisition only. No inserted rays or invented history.
    public static func measured(control: DetectionOverlayControl, frame: ProfileFrame?,
                                instrument: CompiledInstrument, contour: SpatialRoomContour?,
                                confirmation: [DetectionConfirmationProgress] = []) -> Self {
        let origin = MetricScanPoint(xMeters: 0, yMeters: 0)
        func notice(_ text: String) -> Self {
            .init(shapes: [], labels: [.init(point: origin, text: text, tone: .guide)], pointTones: [:])
        }
        guard let frame else { return notice("Move your hand into view") }
        let config = instrument.detection
        let geometry = SpatialRoomContour.Geometry(pointCount: frame.geometry.pointCount,
            angleResolutionDegrees: (frame.geometry.endAngleDegrees-frame.geometry.startAngleDegrees) / Double(max(1, frame.geometry.pointCount-1)),
            startAngleDegrees: frame.geometry.startAngleDegrees, sourceIdentifier: frame.sourceIdentifier)
        let foreground = config.room.filter(frame.projectedMeasurements, contour: contour, geometry: geometry,
            matches: contour?.compatibility(with: geometry) ?? false).measurements.filter { UsableRawDistance.contains($0.distanceCentimeters) }
        guard !foreground.isEmpty else { return notice("Move your hand into view") }
        var pipeline = SpatialDetectionPipeline(configuration: config)
        let selection = pipeline.selectForPresentation(frame: frame, instrument: instrument, contour: contour)
        guard let evidence = selection.groupingEvidence else { return notice("Move your hand into view") }
        let beams = evidence.measurements
        let allGroups = evidence.groupsBeforeMinimumPoints
        let eligible = evidence.groupsBeforeAngularSeparation
        let acceptedOrders = evidence.acceptedOrders
        let classified = Dictionary(uniqueKeysWithValues: beams.map { ($0.order, acceptedOrders.contains($0.order) ? Tone.kept : .rejected) })
        let showsClassification = control == .minimumGap || control == .minimumPoints || control == .minimumAngle
        let tones = showsClassification ? classified : Dictionary(uniqueKeysWithValues: foreground.map { ($0.order,Tone.kept) })
        let anchor = foreground.min { $0.distanceCentimeters == $1.distanceCentimeters ? $0.order < $1.order : $0.distanceCentimeters < $1.distanceCentimeters }!
        let radius = hypot(anchor.point.xMeters, anchor.point.yMeters)
        let bearing = atan2(anchor.point.xMeters, anchor.point.yMeters) * 180 / .pi
        var shapes: [Shape] = [], labels: [Label] = []
        switch control {
        case .minimumGap:
            let pairs = zip(beams, beams.dropFirst()).filter { $1.order == $0.order + 1 }
            guard let pair = pairs.max(by: { abs(Int($0.0.distanceCentimeters)-Int($0.1.distanceCentimeters)) < abs(Int($1.0.distanceCentimeters)-Int($1.1.distanceCentimeters)) }) else {
                return notice("Move your hand into view")
            }
            let start = pair.0.point
            let r = hypot(start.xMeters, start.yMeters), angle = atan2(start.xMeters, start.yMeters) * 180 / .pi
            let end = point(radius: r + Double(config.groupingJumpCentimeters)/100, bearing: angle)
            let merged = allGroups.contains { group in group.contains { $0.order == pair.0.order } && group.contains { $0.order == pair.1.order } }
            let tone: Tone = !acceptedOrders.contains(pair.0.order) || !acceptedOrders.contains(pair.1.order) ? .rejected : merged ? .merged : .kept
            shapes.append(.init(points: [start,end], isClosed: false, fillOpacity: 0, tone: tone, lineWidth: 2.5))
            shapes.append(.init(points: [pair.0.point,pair.1.point], isClosed: false, fillOpacity: 0, tone: .guide, strokeOpacity: 0.4))
            labels.append(.init(point: end, text: "\(config.groupingJumpCentimeters) cm · Allowed depth step · \(merged ? "joined" : "separate")", tone: tone))
        case .minimumPoints:
            for group in allGroups {
                let tone: Tone = group.count >= config.groupingMinimumPoints ? .kept : .rejected
                let xs = group.map { $0.point.xMeters }, ys = group.map { $0.point.yMeters }
                let left = xs.min()!-0.015, right = xs.max()!+0.015, bottom = ys.min()!-0.015, top = ys.max()!+0.015
                shapes.append(.init(points: [.init(xMeters: left,yMeters: bottom),.init(xMeters: left,yMeters: top),
                    .init(xMeters: right,yMeters: top),.init(xMeters: right,yMeters: bottom)], isClosed: true, fillOpacity: 0, tone: .guide))
                labels.append(.init(point: group[group.count/2].point,
                    text: "\(group.count) points / need \(config.groupingMinimumPoints) · \(tone == .kept ? "kept" : "ignored")", tone: tone))
            }
        case .minimumAngle:
            if let near = eligible.min(by: { config.groups.distance(of: $0) < config.groups.distance(of: $1) }),
               let first = near.first, let last = near.last {
                let lower = atan2(first.point.xMeters, first.point.yMeters)*180 / .pi - Double(config.minimumAngleDegrees)
                let upper = atan2(last.point.xMeters, last.point.yMeters)*180 / .pi + Double(config.minimumAngleDegrees)
                let r = config.groups.distance(of: near)/100
                let arc = (0...32).map { point(radius: r, bearing: max(-90,min(90,lower+(upper-lower)*Double($0)/32))) }
                shapes.append(.init(points: [origin]+arc+[origin], isClosed: true, fillOpacity: 0.08, tone: .guide))
                labels.append(.init(point: first.point, text: "Required spacing · \(config.minimumAngleDegrees)°", tone: .guide))
            }
        case .confirmation:
            guard !confirmation.isEmpty else { return .init(shapes: [],labels: [.init(point: anchor.point,text: "No cell change",tone: .guide)],pointTones: tones) }
            for item in confirmation {
                let at = point(radius: Double(item.target.cell.ring)/100, bearing: PolarDeviceLattice.bearingDegrees(forTick: item.target.cell.sector))
                let count = min(item.observedProfiles, config.cellSelection.confirmationProfiles)
                labels.append(.init(point: at, text: "\(count) / \(config.cellSelection.confirmationProfiles) · \(count >= config.cellSelection.confirmationProfiles ? "ready" : "waiting")",
                    tone: count >= config.cellSelection.confirmationProfiles ? .kept : .guide))
            }
        case .targetWidth, .softness:
            guard config.virtualMMKMode != .raw else { return notice("Select a beam window") }
            let width = config.beams.virtualMMKWindowDegrees(distanceCentimeters: radius*100)
            for slice in 0..<24 {
                let lower = -1 + Double(slice)/12, upper = lower + 1.0/12
                let weight = config.beams.virtualMMKWeight(fractionOfHalfWidth: (lower+upper)/2)
                shapes.append(.init(points: [point(radius: max(0,radius-0.12), bearing: bearing+width*lower/2),
                    point(radius: radius+0.12, bearing: bearing+width*lower/2),
                    point(radius: radius+0.12, bearing: bearing+width*upper/2),
                    point(radius: max(0,radius-0.12), bearing: bearing+width*upper/2)], isClosed: true,
                    fillOpacity: weight*0.8, tone: .guide, strokeOpacity: 0))
            }
            shapes.append(.init(points: [point(radius: max(0,radius-0.12), bearing: bearing-width/2),
                point(radius: radius+0.12, bearing: bearing-width/2),point(radius: radius+0.12, bearing: bearing+width/2),
                point(radius: max(0,radius-0.12), bearing: bearing+width/2)], isClosed: true, fillOpacity: 0, tone: .guide))
            if control == .softness {
                var runs: [[ProjectedScanMeasurement]] = []
                for beam in beams {
                    if runs.last?.last?.order == beam.order-1 { runs[runs.count-1].append(beam) }
                    else { runs.append([beam]) }
                }
                shapes += runs.map { .init(points: $0.map(\.point), isClosed: false, fillOpacity: 0, tone: .kept, lineWidth: 2) }
            }
            labels.append(.init(point: anchor.point, text: control == .targetWidth ? "Window at this hand · \(config.virtualMMKTargetWidthCentimeters) cm" :
                (config.virtualMMKSoftness == 0 ? "Use a hard window edge" : "Fade the window edge · \(config.virtualMMKSoftness)%"), tone: .guide))
        case .representative, .offset:
            for object in selection.objects {
                shapes.append(.init(points: object.groupPoints, isClosed: false, fillOpacity: 0, tone: .guide, strokeOpacity: 0.4))
                if config.representative == .nearestPointWithOffset {
                    var raw = config.representativeStage; raw.representative = .nearestPoint
                    let from = raw.makeRepresentative(object.representativeInput).point, to = object.representative.point
                    shapes.append(.init(points: [from,to], isClosed: false, fillOpacity: 0, tone: .kept, lineWidth: 2.5))
                    let dx = to.xMeters-from.xMeters, dy = to.yMeters-from.yMeters, length = hypot(dx,dy)
                    if length > 0 {
                        let size = min(0.025,length/2)
                        shapes.append(.init(points: [.init(xMeters: to.xMeters-size*(dx+dy)/length, yMeters: to.yMeters-size*(dy-dx)/length), to,
                            .init(xMeters: to.xMeters-size*(dx-dy)/length, yMeters: to.yMeters-size*(dy+dx)/length)], isClosed: false, fillOpacity: 0, tone: .kept))
                    }
                }
                let p = object.representative.point, d = 0.012
                let ring = (0..<16).map { index in
                    let angle = Double(index)*2 * .pi/16
                    return MetricScanPoint(xMeters: p.xMeters+cos(angle)*d,yMeters: p.yMeters+sin(angle)*d)
                }
                shapes.append(.init(points: ring, isClosed: true, fillOpacity: 0, tone: .kept, lineWidth: 2))
                labels.append(.init(point: p, text: "Playing point", tone: .kept))
            }
        default: return .empty
        }
        if labels.isEmpty { return notice("Move your hand into view") }
        return .init(shapes: shapes, labels: labels, pointTones: tones)
    }

    public static func contourTolerance(contour: SpatialRoomContour?, matches: Bool,
                                        configuration: SpatialRoomContourConfiguration,
                                        measurements: [ProjectedScanMeasurement], geometry: ProfileGeometryIdentity? = nil) -> Self {
        guard configuration.isEnabled, matches, let contour,
              contour.geometry.pointCount > 0, contour.geometry.angleResolutionDegrees > 0 else { return .empty }
        let tolerance = Double(configuration.toleranceCentimeters) / 100
        var shapes: [Shape] = [], inner: [MetricScanPoint] = [], outer: [MetricScanPoint] = []
        func flush() {
            if inner.count > 1 { shapes.append(.init(points: inner + outer.reversed(), isClosed: true, fillOpacity: 0.18, tone: .guide, strokeOpacity: 0)) }
            inner.removeAll(); outer.removeAll()
        }
        for (index, wall) in contour.nearestDistancesCentimeters.enumerated() {
            guard let wall else { flush(); continue }
            let bearing = contour.geometry.startAngleDegrees + Double(index) * contour.geometry.angleResolutionDegrees
            inner.append(point(radius: max(0, Double(wall) / 100 - tolerance), bearing: bearing))
            outer.append(point(radius: Double(wall) / 100, bearing: bearing))
        }
        flush()
        let step = geometry.map { ($0.endAngleDegrees - $0.startAngleDegrees) / Double(max(1, $0.pointCount - 1)) }
            ?? contour.geometry.angleResolutionDegrees
        let tones = Dictionary(uniqueKeysWithValues: measurements.compactMap { value -> (Int, Tone)? in
            let bearing = geometry.map { $0.startAngleDegrees + Double(value.order) * step }
                ?? atan2(value.point.xMeters, value.point.yMeters) * 180 / .pi
            guard !contour.filters(distanceCentimeters: value.distanceCentimeters,
                bearingDegrees: bearing, spanDegrees: step,
                toleranceCentimeters: configuration.toleranceCentimeters) else { return nil }
            return (value.order, .rejected)
        })
        return .init(shapes: shapes, labels: [], pointTones: tones)
    }

    /// Uses the compiled Snap partition shared by selection and Snap holding.
    public static func cellMargins(instrument: CompiledInstrument, layerID: UUID,
                                   centimeters: UInt16) -> Self {
        // A layer of surfaces is shown through all of its partitions.
        let layers = instrument.layers.filter { instrument.ownerLayerID(of: $0.id) == layerID }
        guard !layers.isEmpty else { return .empty }
        let shapes = layers.flatMap { layer in
            layer.snapGeometry.keys.sorted { ($0.ring, $0.sector) < ($1.ring, $1.sector) }.flatMap {
                regionMargins(segments: layer.snapGeometry[$0] ?? [], centimeters: centimeters).shapes
            }
        }
        return .init(shapes: shapes, labels: [], pointTones: [:])
    }

    /// Each exposed edge is offset once. Shared region edges never appear.
    internal static func regionMargins(segments: [PolarMetricCellSegment], centimeters: UInt16) -> Self {
        let margin = Double(centimeters) / 100
        var shapes: [Shape] = []
        func same(_ a: Double, _ b: Double) -> Bool { abs(a-b) < 1e-9 }
        func key(_ value: Double) -> Double { (value * 100_000_000).rounded() }
        let byInner = Dictionary(grouping: segments) { key($0.innerRadiusMeters) }
        let byOuter = Dictionary(grouping: segments) { key($0.outerRadiusMeters) }
        let byStart = Dictionary(grouping: segments) { key($0.startBearingDegrees) }
        let byEnd = Dictionary(grouping: segments) { key($0.endBearingDegrees) }
        func exposed(_ start: Double, _ end: Double, covers: [(Double, Double)]) -> [(Double, Double)] {
            var intervals = [(start, end)]
            for (lower, upper) in covers {
                intervals = intervals.flatMap { a, b -> [(Double, Double)] in
                    guard upper > a + 1e-9, lower < b - 1e-9 else { return [(a,b)] }
                    return [(a, min(b, lower)), (max(a, upper), b)].filter { $0.1 > $0.0 + 1e-9 }
                }
            }
            return intervals
        }
        guard let nearest = segments.map(\.innerRadiusMeters).min(),
              let farthest = segments.map(\.outerRadiusMeters).max(),
              farthest - margin > max(0, nearest + margin) else { return .empty }
        for segment in segments {
            let inner = max(0, segment.innerRadiusMeters + margin)
            let outer = segment.outerRadiusMeters - margin
            for (radius, neighbourRadius, isInner) in [(inner, segment.innerRadiusMeters, true), (outer, segment.outerRadiusMeters, false)] {
                guard radius > 1e-9 else { continue }
                let neighbours = (isInner ? byOuter[key(neighbourRadius)] : byInner[key(neighbourRadius)]) ?? []
                let covers = neighbours.map { ($0.startBearingDegrees, $0.endBearingDegrees) }
                // Adjacent rings have different angular subdivisions.
                for (edgeStart, edgeEnd) in exposed(segment.startBearingDegrees, segment.endBearingDegrees, covers: covers) {
                    func angularShared(_ bearing: Double, start: Bool) -> Bool {
                        let neighbours = (start ? byEnd[key(bearing)] : byStart[key(bearing)]) ?? []
                        return neighbours.contains {
                            $0.innerRadiusMeters <= neighbourRadius + 1e-9 && $0.outerRadiusMeters >= neighbourRadius - 1e-9
                        }
                    }
                    let shift = margin / max(radius, 0.0001) * 180 / .pi
                    let start = edgeStart + (same(edgeStart, segment.startBearingDegrees) && !angularShared(edgeStart, start: true) ? shift : 0)
                    let end = edgeEnd - (same(edgeEnd, segment.endBearingDegrees) && !angularShared(edgeEnd, start: false) ? shift : 0)
                    guard end > start else { continue }
                    let steps = max(2, Int(ceil((end-start)/3)))
                    shapes.append(.init(points: (0...steps).map { point(radius: radius, bearing: start +
                        (end-start) * Double($0)/Double(steps)) },
                        isClosed: false, fillOpacity: 0, tone: .guide))
                }
            }
            for (bearing, isStart) in [(segment.startBearingDegrees, true), (segment.endBearingDegrees, false)] {
                let neighbours = (isStart ? byEnd[key(bearing)] : byStart[key(bearing)]) ?? []
                let covers = neighbours.map { ($0.innerRadiusMeters, $0.outerRadiusMeters) }
                for (start, end) in exposed(segment.innerRadiusMeters, segment.outerRadiusMeters, covers: covers) {
                    // A shared ring edge is not an inset boundary. In
                    // particular, several thin rings can form one wide region.
                    let innerShared = (byOuter[key(segment.innerRadiusMeters)] ?? []).contains {
                        $0.startBearingDegrees <= bearing + 1e-9 && $0.endBearingDegrees >= bearing - 1e-9
                    }
                    let outerShared = (byInner[key(segment.outerRadiusMeters)] ?? []).contains {
                        $0.startBearingDegrees <= bearing + 1e-9 && $0.endBearingDegrees >= bearing - 1e-9
                    }
                    let lower = same(start, segment.innerRadiusMeters) && !innerShared ? inner : start
                    let upper = same(end, segment.outerRadiusMeters) && !outerShared ? outer : end
                    guard upper > lower else { continue }
                    shapes.append(.init(points: [lower, upper].map { radius in
                        point(radius: radius, bearing: bearing + margin / max(radius, 0.0001) * 180 / .pi * (isStart ? 1 : -1))
                    }, isClosed: false, fillOpacity: 0, tone: .guide))
                }
            }
        }
        return .init(shapes: shapes, labels: [], pointTones: [:])
    }

    public static func cellMargins(segments: [PolarMetricCellSegment], centimeters: UInt16, outside: Bool) -> Self {
        let margin = Double(centimeters) / 100
        let shapes = segments.compactMap { segment -> Shape? in
            let inner = outside ? max(0, segment.innerRadiusMeters - margin) : segment.innerRadiusMeters + margin
            let outer = outside ? segment.outerRadiusMeters + margin : segment.outerRadiusMeters - margin
            guard outer > inner else { return nil }
            let steps = max(2, Int(ceil(abs(segment.endBearingDegrees - segment.startBearingDegrees) / 3)))
            var points: [MetricScanPoint] = []
            for radius in [outer, inner] {
                let angularMargin = asin(min(1, margin / max(radius, 0.0001))) * 180 / .pi * (outside ? -1 : 1)
                let start = segment.startBearingDegrees + angularMargin, end = segment.endBearingDegrees - angularMargin
                guard end > start else { return nil }
                let arc = (0...steps).map { point(radius: radius, bearing: start + (end-start) * Double($0) / Double(steps)) }
                points += radius == outer ? arc : arc.reversed()
            }
            return .init(points: points, isClosed: true, fillOpacity: 0, tone: .guide)
        }
        return .init(shapes: shapes, labels: [], pointTones: [:])
    }

    public static func smoothing(frame: ProfileFrame, instrument: CompiledInstrument, contour: SpatialRoomContour?,
                                 bounds: DetectionProbePresentation.Bounds? = nil) -> Self {
        let traces = DetectionProbePresentation.motionTraces(frame: frame, instrument: instrument, contour: contour, bounds: bounds)
        var shapes: [Shape] = [], labels: [Label] = []
        for (series, tone) in [(traces.raw, Tone.rejected), (traces.smooth, Tone.kept)] {
            for index in stride(from: 1, to: series.count, by: 4) {
                let trace = series[index]
                guard trace.count > 1 else { continue }
                for index in 1..<trace.count {
                    shapes.append(.init(points: [trace[index-1], trace[index]], isClosed: false, fillOpacity: 0, tone: tone,
                        strokeOpacity: 0.18 + 0.82 * Double(index) / Double(trace.count-1), lineWidth: tone == .kept ? 2.5 : 1.2))
                }
                if let point = trace.last { labels.append(.init(point: point, text: tone == .kept ? "smooth" : "raw", tone: tone)) }
            }
        }
        return .init(shapes: shapes, labels: labels, pointTones: [:])
    }

    private static func point(radius: Double, bearing: Double) -> MetricScanPoint {
        let radians = bearing * .pi / 180
        return .init(xMeters: sin(radians) * radius, yMeters: cos(radians) * radius)
    }
}
