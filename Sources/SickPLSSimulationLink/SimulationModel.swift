import Darwin

public struct SimulationPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct SimulationHand: Equatable, Sendable {
    public var center: SimulationPoint
    public var radiusCm: Double
    public init(center: SimulationPoint, radiusCm: Double) { self.center = center; self.radiusCm = radiusCm }
    public init(x: Double, y: Double, radiusCm: Double) { self.init(center: SimulationPoint(x: x, y: y), radiusCm: radiusCm) }
}

public enum SimulationBackground: Equatable, Sendable {
    case rangeEnd
    case room(widthCm: Double, depthCm: Double)
}

public enum ProfileSampling: Hashable, Sendable {
    case minimumPerBin
    case singleRay
}

public struct SimulationConfiguration: Equatable, Sendable {
    public var pointCount: Int
    public var background: SimulationBackground
    public var sampling: ProfileSampling
    public var noiseEnabled: Bool
    public init(pointCount: Int = 361, background: SimulationBackground = .rangeEnd,
                sampling: ProfileSampling = .minimumPerBin, noiseEnabled: Bool = false) {
        self.pointCount = pointCount; self.background = background; self.sampling = sampling; self.noiseEnabled = noiseEnabled
    }
}

public struct SplitMix64: Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    public mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        let width = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(nextUInt64() % width)
    }
}

public enum SimulatedScanner {
    public static func profileValues(hands: [SimulationHand], configuration: SimulationConfiguration,
                                     rng: inout SplitMix64) -> [UInt16] {
        guard configuration.pointCount > 1 else { return [] }
        let count = configuration.pointCount
        return (0..<count).map { index in
            let centerAngle = -90.0 + 180.0 * Double(index) / Double(count - 1)
            let angles: [Double]
            if count == 90 && configuration.sampling == .minimumPerBin {
                let halfBin = 90.0 / 89.0
                let lo = max(-90.0, centerAngle - halfBin)
                let hi = min(90.0, centerAngle + halfBin)
                let first = Int((lo * 2.0).rounded(.up))
                let last = Int((hi * 2.0).rounded(.down))
                angles = first <= last ? (first...last).map { Double($0) / 2.0 } : [centerAngle]
            } else { angles = [centerAngle] }
            let distance = angles.compactMap { rayDistance(angle: $0, hands: hands, background: configuration.background) }.min() ?? 8191.0
            if distance >= 8191.0 { return 8191 }
            var value = Int(distance.rounded())
            if configuration.noiseEnabled { value += rng.nextInt(in: -3...3) }
            return UInt16(min(8190, max(1, value)))
        }
    }

    private static func rayDistance(angle: Double, hands: [SimulationHand], background: SimulationBackground) -> Double? {
        let radians = angle * .pi / 180.0
            let dx = sin(radians), dy = cos(radians)
        var best: Double?
        for hand in hands {
            let radius = max(0.0, hand.radiusCm)
            let length = sqrt(hand.center.x * hand.center.x + hand.center.y * hand.center.y)
            let center: SimulationPoint
            if length < radius + 1.0 {
                center = length < 1.0
                    ? SimulationPoint(x: 0, y: radius + 1.0)
                    : SimulationPoint(x: hand.center.x / length * (radius + 1.0), y: hand.center.y / length * (radius + 1.0))
            } else { center = hand.center }
            let projection = dx * center.x + dy * center.y
            let perpendicular = center.x * center.x + center.y * center.y - projection * projection
            let discriminant = radius * radius - perpendicular
            guard discriminant >= 0 else { continue }
            let hit = projection - sqrt(discriminant)
            guard hit > 0 else { continue }
            if best == nil || hit < best! { best = hit }
        }
        if let best { return best }
        guard case let .room(width, depth) = background else { return nil }
        var walls: [Double] = []
        if dx > 0 { walls.append((width / 2.0) / dx) }
        if dx < 0 { walls.append((-width / 2.0) / dx) }
        if dy > 0 { walls.append(depth / dy) }
        return walls.filter { $0 > 0 }.min()
    }
}

public struct ScreenPoint: Equatable, Sendable { public var x: Double; public var y: Double; public init(x: Double, y: Double) { self.x = x; self.y = y } }

public struct FieldScreenMapping: Equatable, Sendable {
    public let fieldWidthCm: Double; public let fieldDepthCm: Double; public let viewWidth: Double; public let viewHeight: Double
    public let scale: Double; public let originX: Double; public let originY: Double
    public init(fieldWidthCm: Double, fieldDepthCm: Double, viewWidth: Double, viewHeight: Double) {
        self.fieldWidthCm = fieldWidthCm; self.fieldDepthCm = fieldDepthCm; self.viewWidth = viewWidth; self.viewHeight = viewHeight
        scale = min(viewWidth / fieldWidthCm, viewHeight / fieldDepthCm)
        originX = (viewWidth - fieldWidthCm * scale) / 2.0
        originY = (viewHeight - fieldDepthCm * scale) / 2.0
    }
    public var scannerScreenPoint: ScreenPoint { ScreenPoint(x: originX + fieldWidthCm * scale / 2.0, y: originY + fieldDepthCm * scale) }
    public func screenPoint(for point: SimulationPoint) -> ScreenPoint { ScreenPoint(x: originX + (point.x + fieldWidthCm / 2.0) * scale, y: originY + (fieldDepthCm - point.y) * scale) }
    public func fieldPoint(for point: ScreenPoint) -> SimulationPoint { SimulationPoint(x: (point.x - originX) / scale - fieldWidthCm / 2.0, y: fieldDepthCm - (point.y - originY) / scale) }
}

public struct PlanariumRGBAColor: Equatable, Sendable { public let red: Double; public let green: Double; public let blue: Double; public let alpha: Double; public init(red: Double, green: Double, blue: Double, alpha: Double = 1) { self.red = red; self.green = green; self.blue = blue; self.alpha = alpha } }
public enum PlanariumPalette {
    public static let workspace = PlanariumRGBAColor(red: 0.08, green: 0.08, blue: 0.09)
    public static let canvas = PlanariumRGBAColor(red: 0.10, green: 0.10, blue: 0.11)
    public static let border = PlanariumRGBAColor(red: 0.28, green: 0.24, blue: 0.18)
    public static let amber = PlanariumRGBAColor(red: 1.00, green: 0.55, blue: 0.00)
    public static let amberBright = PlanariumRGBAColor(red: 1.00, green: 0.80, blue: 0.20)
    public static let grid = PlanariumRGBAColor(red: 0.55, green: 0.42, blue: 0.20, alpha: 0.55)
}

/// Test tool for unattended runs (`-PlanariumAutoSweep`): two hands move
/// slowly and independently through the playing area, 0.3–1.5 m and
/// ±40°, never crossing the centre line. A pure function of elapsed time,
/// so a run is reproducible.
public enum AutoSweepPath {
    public static let handRadiusCm = 4.5
    public static func hands(at seconds: Double) -> [SimulationHand] {
        func hand(radiusPeriod: Double, anglePeriod: Double, minAngle: Double, maxAngle: Double) -> SimulationHand {
            let r = 90 + 60 * sin(2 * .pi * seconds / radiusPeriod)                 // 30 … 150 cm
            let mid = (minAngle + maxAngle) / 2, half = (maxAngle - minAngle) / 2
            let angle = (mid + half * sin(2 * .pi * seconds / anglePeriod)) * .pi / 180
            return SimulationHand(x: r * sin(angle), y: r * cos(angle), radiusCm: handRadiusCm)
        }
        return [hand(radiusPeriod: 7, anglePeriod: 11, minAngle: -40, maxAngle: -8),
                hand(radiusPeriod: 9, anglePeriod: 13, minAngle: 8, maxAngle: 40)]
    }
}
