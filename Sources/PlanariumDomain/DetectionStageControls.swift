import Foundation

public enum DetectionStage: String, CaseIterable, Sendable {
    case room, beams, groups, edge, core, representative, time, cells

    public var controls: [DetectionControlDescriptor] {
        switch self {
        case .room: SpatialRoomContourConfiguration.controls
        case .beams: DetectionBeamsConfiguration.controls
        case .groups: DetectionGroupsConfiguration.controls
        case .edge: DetectionEdgeConfiguration.controls
        case .core: DetectionCoreConfiguration.controls
        case .representative: DetectionRepresentativeConfiguration.controls
        case .time: DetectionTimeConfiguration.controls
        case .cells: DetectionCellsConfiguration.controls
        }
    }
}

/// A regulator's complete presentation and edit contract. Reads and writes
/// are pure value operations; the document owner remains the edit authority.
public struct DetectionControlDescriptor: Sendable, Identifiable {
    public enum ID: String, CaseIterable, Sendable {
        case contourTolerance, mmk, targetWidth, softness, grouping, minimumGap, minimumPoints
        case minimumAngle, edgePoints, coreWidth, representative, offset, smoothing, window, weight
        case confirmation, snap, holdMargin
    }
    public enum Style: Sendable { case knob, rotary }
    public let id: ID
    public let name: String
    public let symbol: String
    public let tooltip: String
    public let unit: String
    public let values: [Int]
    public let defaultValue: Int
    public let style: Style
    public let labels: [String]
    public let overlay: DetectionOverlayControl
    public let lockedInPerform: Bool = true
    private let read: @Sendable (DetectionConfiguration) -> Int
    private let write: @Sendable (inout DetectionConfiguration, Int) -> Void
    private let available: @Sendable (DetectionConfiguration, Bool) -> Bool
    private let display: @Sendable (Int) -> String

    public init(id: ID, name: String, symbol: String, tooltip: String, unit: String = "",
                values: [Int], defaultValue: Int, style: Style = .knob, labels: [String] = [],
                overlay: DetectionOverlayControl = .probe,
                read: @escaping @Sendable (DetectionConfiguration) -> Int,
                write: @escaping @Sendable (inout DetectionConfiguration, Int) -> Void,
                available: @escaping @Sendable (DetectionConfiguration, Bool) -> Bool = { _, _ in true },
                display: (@Sendable (Int) -> String)? = nil) {
        self.id = id; self.name = name; self.symbol = symbol; self.tooltip = tooltip; self.unit = unit
        self.values = values; self.defaultValue = defaultValue; self.style = style; self.labels = labels
        self.overlay = overlay; self.read = read; self.write = write; self.available = available
        self.display = display ?? { "\($0)\(unit.isEmpty ? "" : " " + unit)" }
    }
    public func value(in configuration: DetectionConfiguration) -> Int { read(configuration) }
    public func formattedValue(in configuration: DetectionConfiguration) -> String { formatted(value(in: configuration)) }
    public func formatted(_ value: Int) -> String {
        if !labels.isEmpty, values.indices.contains(value) { return labels[value] }
        return display(value)
    }
    public func isAvailable(configuration: DetectionConfiguration, hasMatchingContour: Bool, performing: Bool) -> Bool {
        (!performing || !lockedInPerform) && available(configuration, hasMatchingContour)
    }
    public func applying(_ value: Int, to configuration: DetectionConfiguration,
                         hasMatchingContour: Bool, performing: Bool) -> DetectionConfiguration {
        guard values.contains(value) || value == defaultValue, isAvailable(configuration: configuration,
            hasMatchingContour: hasMatchingContour, performing: performing) else { return configuration }
        var next = configuration; write(&next, value); return next
    }
    private static let byID = Dictionary(uniqueKeysWithValues: DetectionStage.allCases.flatMap(\.controls).map { ($0.id, $0) })
    public static func descriptor(_ id: ID) -> Self { byID[id]! }
}

extension SpatialRoomContourConfiguration {
    public static let defaults = Self()
    public static let legacyDefaults = Self()
    public static let controls: [DetectionControlDescriptor] = [
        .init(id: .contourTolerance, name: "Contour tolerance", symbol: "house", tooltip: "Permitted variation at the captured wall.",
            unit: "cm", values: Array(1...30), defaultValue: Int(defaults.toleranceCentimeters), overlay: .contourTolerance,
            read: { Int($0.room.toleranceCentimeters) }, write: { $0.room.toleranceCentimeters = UInt16($1) },
            available: { $1 && $0.room.isEnabled })
    ]
}
extension DetectionBeamsConfiguration {
    public static let controls: [DetectionControlDescriptor] = [
        .init(id: .mmk, name: "Virtual MMK", symbol: "dot.radiowaves.left.and.right", tooltip: "Spatial minimum before grouping.",
            values: Array(0...3), defaultValue: 3, style: .rotary, labels: VirtualMMKMode.allCases.map(\.label),
            read: { VirtualMMKMode.allCases.firstIndex(of: $0.beams.virtualMMKMode) ?? 0 },
            write: { $0.beams.virtualMMKMode = VirtualMMKMode.allCases[$1] }),
        .init(id: .targetWidth, name: "Target width", symbol: "arrow.left.and.right", tooltip: "Adaptive beam window width; available only in Adaptive mode.",
            unit: "cm", values: Array(1...5), defaultValue: 2, overlay: .targetWidth,
            read: { Int($0.beams.virtualMMKTargetWidthCentimeters) }, write: { $0.beams.virtualMMKTargetWidthCentimeters = UInt8($1) },
            available: { configuration, _ in configuration.beams.virtualMMKMode == .adaptive }),
        .init(id: .softness, name: "Softness", symbol: "circle.lefthalf.filled", tooltip: "Softens the beam-window edge; unavailable at raw 0.5°.",
            unit: "%", values: Array(stride(from: 0, through: 100, by: 10)), defaultValue: 45, overlay: .softness,
            read: { Int($0.beams.virtualMMKSoftness) }, write: { $0.beams.virtualMMKSoftness = UInt8($1) },
            available: { configuration, _ in configuration.beams.virtualMMKMode != .raw }, display: { $0 == 0 ? "Hard" : "\($0) %" })
    ]
}
extension DetectionGroupsConfiguration {
    public static let controls: [DetectionControlDescriptor] = [
        .init(id: .grouping, name: "Grouping", symbol: "circle.grid.3x3", tooltip: "Group neighbouring beams.",
            values: [0, 1], defaultValue: 1, style: .rotary, labels: ["Off", "On"],
            read: { $0.groups.groupingEnabled ? 1 : 0 }, write: { $0.groups.groupingEnabled = $1 == 1 }),
        .init(id: .minimumGap, name: "Minimum gap", symbol: "arrow.up.and.down", tooltip: "Radial distance that separates objects.",
            unit: "cm", values: Array(1...30), defaultValue: 10, overlay: .minimumGap,
            read: { Int($0.groups.groupingJumpCentimeters) }, write: { $0.groups.groupingJumpCentimeters = UInt16($1) },
            available: { configuration, _ in configuration.groups.groupingEnabled }),
        .init(id: .minimumPoints, name: "Minimum points", symbol: "ellipsis", tooltip: "Few-point groups are discarded.",
            values: Array(1...10), defaultValue: 1, overlay: .minimumPoints,
            read: { $0.groups.groupingMinimumPoints }, write: { $0.groups.groupingMinimumPoints = $1 },
            available: { configuration, _ in configuration.groups.groupingEnabled }),
        .init(id: .minimumAngle, name: "Minimum angle", symbol: "angle", tooltip: "Angular spacing required between objects.",
            unit: "°", values: Array(stride(from: 0, through: 90, by: 5)), defaultValue: 20, overlay: .minimumAngle,
            read: { $0.groups.minimumAngleDegrees }, write: { $0.groups.minimumAngleDegrees = $1 },
            display: { $0 == 0 ? "Off" : "\($0)°" })
    ]
}
extension DetectionEdgeConfiguration {
    public static let controls: [DetectionControlDescriptor] = [
        .init(id: .edgePoints, name: "Edge points", symbol: "scissors", tooltip: "Removes up to one or two farther end rays per side when the inward radial step exceeds 3 cm. Keeps at least Minimum points; nearer finger rays remain.",
            values: [0, 1, 2], defaultValue: 1, style: .rotary, labels: ["Off", "1", "2"],
            read: { Int($0.edge.edgePoints) }, write: { $0.edge.edgePoints = UInt8($1) },
            available: { configuration, _ in configuration.groups.groupingEnabled })
    ]
}
extension DetectionCoreConfiguration {
    public static let controls: [DetectionControlDescriptor] = [
        .init(id: .coreWidth, name: "Core width", symbol: "rectangle.center.inset.filled", tooltip: "Playing width around the middle measured beam after Edge points. Only this core feeds the representative, smoothing and cells; the disc keeps the whole object. Target width instead controls the spatial minimum window per beam.",
            unit: "cm", values: Array(0...10), defaultValue: 3,
            read: { Int($0.core.coreWidthCentimeters) }, write: { $0.core.coreWidthCentimeters = UInt8($1) },
            available: { configuration, _ in configuration.groups.groupingEnabled }, display: { $0 == 0 ? "Off" : "\($0) cm" })
    ]
}
extension DetectionRepresentativeConfiguration {
    public static let controls: [DetectionControlDescriptor] = [
        .init(id: .representative, name: "Representative", symbol: "scope", tooltip: "Chooses the point representing each object.",
            values: Array(0...3), defaultValue: 0, labels: ["Mean", "Nearest", "Median", "Pt + offset"], overlay: .representative,
            read: { [.mean, .nearestPoint, .median, .nearestPointWithOffset].firstIndex(of: $0.representativeStage.representative) ?? 0 },
            write: { $0.representativeStage.representative = [.mean, .nearestPoint, .median, .nearestPointWithOffset][$1] }),
        .init(id: .offset, name: "Offset", symbol: "arrow.up", tooltip: "Only applies to Point + offset.",
            unit: "cm", values: Array(0...10), defaultValue: 0, overlay: .offset,
            read: { Int($0.representativeStage.representativeOffsetCentimeters) }, write: { $0.representativeStage.representativeOffsetCentimeters = UInt16($1) },
            available: { configuration, _ in configuration.representativeStage.representative == .nearestPointWithOffset })
    ]
}
extension DetectionTimeConfiguration {
    public var switchIndex: Int {
        guard smoothingEnabled else { return 0 }
        switch temporalSmoothing {
        case .off: return 0
        case .mean: return 1
        case .median: return 2
        case .exponential: return 3
        }
    }
    public var window: Int {
        switch temporalSmoothing {
        case .mean(let n), .median(let n): return n
        case .off, .exponential: return 4
        }
    }
    public mutating func selectMethod(_ index: Int) {
        switch index {
        case 0: smoothingEnabled = false
        case 1: temporalSmoothing = .mean(window: window); smoothingEnabled = true
        case 2: temporalSmoothing = .median(window: window); smoothingEnabled = true
        case 3:
            if case .exponential = temporalSmoothing {} else { temporalSmoothing = .exponential(alpha: 0.5) }
            smoothingEnabled = true
        default: break
        }
    }
    public static let controls: [DetectionControlDescriptor] = [
        .init(id: .smoothing, name: "Smoothing", symbol: "clock", tooltip: "Smooth each beam over time.",
            values: Array(0...3), defaultValue: 0, style: .rotary, labels: ["OFF", "MEAN", "MEDIAN", "EXP"], overlay: .smoothing,
            read: { $0.time.switchIndex }, write: { $0.time.selectMethod($1) }),
        .init(id: .window, name: "Window", symbol: "square.stack", tooltip: "Number of recent scans used by Mean and Median smoothing.",
            unit: "scans", values: Array(2...8), defaultValue: 4, overlay: .smoothing,
            read: { min(max($0.time.window, 2), 8) }, write: {
                if case .median = $0.time.temporalSmoothing { $0.time.temporalSmoothing = .median(window: $1) }
                else { $0.time.temporalSmoothing = .mean(window: $1) }
            }, available: { configuration, _ in configuration.time.switchIndex == 1 || configuration.time.switchIndex == 2 }),
        .init(id: .weight, name: "Weight α", symbol: "scalemass", tooltip: "Exponential weight of the newest measurement.",
            values: Array(1...9), defaultValue: 5, overlay: .smoothing,
            read: { if case .exponential(let alpha) = $0.time.temporalSmoothing { return Int((alpha * 10).rounded()) }; return 5 },
            write: { $0.time.temporalSmoothing = .exponential(alpha: Double($1) / 10) },
            available: { configuration, _ in if case .exponential = configuration.time.temporalSmoothing { return true }; return false },
            display: { String(format: "%.1f", Double($0) / 10) })
    ]
}
extension DetectionCellsConfiguration {
    public static let controls: [DetectionControlDescriptor] = [
        .init(id: .confirmation, name: "Confirmation", symbol: "checkmark", tooltip: "Requires consecutive scans in a new cell before switching.",
            unit: "scans", values: Array(1...4), defaultValue: 1, overlay: .confirmation,
            read: { $0.cells.cellSelection.confirmationProfiles }, write: { $0.cells.cellSelection.confirmationProfiles = $1 },
            display: { "\($0) scan\($0 == 1 ? "" : "s")" }),
        .init(id: .snap, name: "Snap", symbol: "square.grid.2x2", tooltip: "Resists crossing a cell border.",
            unit: "cm", values: Array(0...10), defaultValue: 0, overlay: .edgeMargin,
            read: { Int($0.cells.cellSelection.boundaryMarginCentimeters) }, write: { $0.cells.cellSelection.boundaryMarginCentimeters = UInt16($1) }),
        .init(id: .holdMargin, name: "Hold margin", symbol: "pause", tooltip: "Keeps continuous values calm near their last position.",
            unit: "cm", values: Array(0...5), defaultValue: 0, overlay: .holdMargin,
            read: { Int($0.cells.continuousBacklashCentimeters) }, write: { $0.cells.continuousBacklashCentimeters = UInt16($1) })
    ]
}

/// Surface grouping is not execution order: Edge/Core/Representative are
/// shown inside Groups; cell confirmation is shown in Time.
public enum DetectionModule: String, CaseIterable, Sendable {
    case room, fit, beams, groups, time, cells
    public var title: String { rawValue.capitalized }
    public var symbol: String {
        switch self {
        case .room: "house"
        case .fit: "arrow.down.right.and.arrow.up.left"
        case .beams: "dot.radiowaves.left.and.right"
        case .groups: "circle.grid.3x3"
        case .time: "clock"
        case .cells: "square.grid.2x2"
        }
    }
    public func controls(configuration: DetectionConfiguration) -> [DetectionControlDescriptor] {
        switch self {
        case .room: return DetectionStage.room.controls
        case .fit: return [] // Room-fit is a document operation, not detection.
        case .beams: return DetectionStage.beams.controls
        case .groups:
            let ids: [DetectionControlDescriptor.ID] = [.grouping, .minimumGap, .minimumPoints, .edgePoints,
                .coreWidth, .minimumAngle, .representative, .offset]
            return ids.map(DetectionControlDescriptor.descriptor)
        case .time:
            let parameter: DetectionControlDescriptor.ID
            if case .exponential = configuration.time.temporalSmoothing { parameter = .weight } else { parameter = .window }
            return [.smoothing, parameter, .confirmation].map(DetectionControlDescriptor.descriptor)
        case .cells: return [.snap, .holdMargin].map(DetectionControlDescriptor.descriptor)
        }
    }
}
