import Foundation

/// Stages own their parameters and historic flat coding keys. The aggregate
/// remains the preset wire adapter; no nested keys are added to saved files.

public struct DetectionTimeConfiguration: Codable, Equatable, Sendable {
    public var smoothingEnabled: Bool
    public var temporalSmoothing: DetectionTemporalSmoothing
    public init(smoothingEnabled: Bool = true, temporalSmoothing: DetectionTemporalSmoothing = .off) {
        self.smoothingEnabled = smoothingEnabled
        self.temporalSmoothing = temporalSmoothing
    }
    public static let defaults = Self()
    public static let legacyDefaults = Self()

    public var effective: Self {
        var value = self
        if !smoothingEnabled { value.temporalSmoothing = .off }
        value.smoothingEnabled = true
        return value
    }
    public mutating func setSmoothingEnabled(_ enabled: Bool) {
        if enabled, temporalSmoothing == .off { temporalSmoothing = .mean(window: 4) }
        smoothingEnabled = enabled
    }

    private enum CodingKeys: String, CodingKey { case smoothingEnabled, temporalSmoothing }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        smoothingEnabled = try values.decodeIfPresent(Bool.self, forKey: .smoothingEnabled) ?? true
        temporalSmoothing = try values.decodeIfPresent(DetectionTemporalSmoothing.self, forKey: .temporalSmoothing) ?? .off
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        if !smoothingEnabled { try values.encode(false, forKey: .smoothingEnabled) }
        try values.encode(temporalSmoothing, forKey: .temporalSmoothing)
    }
}

public struct DetectionBeamsConfiguration: Codable, Equatable, Sendable {
    public var virtualMMKMode: VirtualMMKMode
    public var virtualMMKTargetWidthCentimeters: UInt8
    public var virtualMMKSoftness: UInt8
    public init(virtualMMKMode: VirtualMMKMode = .adaptive, virtualMMKTargetWidthCentimeters: UInt8 = 2, virtualMMKSoftness: UInt8 = 45) {
        self.virtualMMKMode = virtualMMKMode
        self.virtualMMKTargetWidthCentimeters = min(max(virtualMMKTargetWidthCentimeters, 1), 5)
        self.virtualMMKSoftness = min(virtualMMKSoftness, 100)
    }
    public static let defaults = Self()
    public static let legacyDefaults = Self(virtualMMKMode: .raw)

    private enum CodingKeys: String, CodingKey { case virtualMMKMode, virtualMMKTargetWidthCentimeters, virtualMMKSoftness }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        virtualMMKMode = try values.decodeIfPresent(VirtualMMKMode.self, forKey: .virtualMMKMode) ?? .raw
        virtualMMKTargetWidthCentimeters = min(max(try values.decodeIfPresent(UInt8.self, forKey: .virtualMMKTargetWidthCentimeters) ?? 2, 1), 5)
        virtualMMKSoftness = min(try values.decodeIfPresent(UInt8.self, forKey: .virtualMMKSoftness) ?? 45, 100)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        if virtualMMKMode != .raw {
            try values.encode(virtualMMKMode, forKey: .virtualMMKMode)
            try values.encode(virtualMMKTargetWidthCentimeters, forKey: .virtualMMKTargetWidthCentimeters)
            try values.encode(virtualMMKSoftness, forKey: .virtualMMKSoftness)
        }
    }
}

public struct DetectionGroupsConfiguration: Codable, Equatable, Sendable {
    public var groupingEnabled: Bool
    public var groupingJumpCentimeters: UInt16
    public var groupingMinimumPoints: Int
    public var minimumAngleDegrees: Int
    public init(groupingEnabled: Bool = true, groupingJumpCentimeters: UInt16 = 10, groupingMinimumPoints: Int = 1, minimumAngleDegrees: Int = 20) {
        self.groupingEnabled = groupingEnabled
        self.groupingJumpCentimeters = min(max(groupingJumpCentimeters, 1), 30)
        self.groupingMinimumPoints = min(max(groupingMinimumPoints, 1), 10)
        self.minimumAngleDegrees = min(max(minimumAngleDegrees, 0), 90)
    }
    public static let defaults = Self()
    public static let legacyDefaults = Self()

    private enum CodingKeys: String, CodingKey { case groupingEnabled, groupingJumpCentimeters, groupingMinimumPoints, minimumAngleDegrees }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        groupingEnabled = try values.decodeIfPresent(Bool.self, forKey: .groupingEnabled) ?? true
        groupingJumpCentimeters = try values.decodeIfPresent(UInt16.self, forKey: .groupingJumpCentimeters) ?? 10
        groupingMinimumPoints = try values.decodeIfPresent(Int.self, forKey: .groupingMinimumPoints) ?? 1
        minimumAngleDegrees = try values.decodeIfPresent(Int.self, forKey: .minimumAngleDegrees) ?? 20
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(groupingEnabled, forKey: .groupingEnabled)
        try values.encode(groupingJumpCentimeters, forKey: .groupingJumpCentimeters)
        try values.encode(groupingMinimumPoints, forKey: .groupingMinimumPoints)
        if minimumAngleDegrees != 20 { try values.encode(minimumAngleDegrees, forKey: .minimumAngleDegrees) }
    }
}

public struct DetectionEdgeConfiguration: Codable, Equatable, Sendable {
    public static let thresholdCentimeters = 3
    public var edgePoints: UInt8
    public init(edgePoints: UInt8 = 1) {
        self.edgePoints = min(edgePoints, 2)
    }
    public static let defaults = Self()
    public static let legacyDefaults = Self(edgePoints: 0)

    private enum CodingKeys: String, CodingKey { case edgePoints }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        edgePoints = min(try values.decodeIfPresent(UInt8.self, forKey: .edgePoints) ?? 0, 2)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        if edgePoints > 0 { try values.encode(edgePoints, forKey: .edgePoints) }
    }
}

public struct DetectionCoreConfiguration: Codable, Equatable, Sendable {
    public var coreWidthCentimeters: UInt8
    public init(coreWidthCentimeters: UInt8 = 3) {
        self.coreWidthCentimeters = min(coreWidthCentimeters, 10)
    }
    public static let defaults = Self()
    public static let legacyDefaults = Self(coreWidthCentimeters: 0)

    private enum CodingKeys: String, CodingKey { case coreWidthCentimeters }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        coreWidthCentimeters = min(try values.decodeIfPresent(UInt8.self, forKey: .coreWidthCentimeters) ?? 0, 10)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        if coreWidthCentimeters > 0 { try values.encode(coreWidthCentimeters, forKey: .coreWidthCentimeters) }
    }
}

public struct DetectionRepresentativeConfiguration: Codable, Equatable, Sendable {
    public var representative: DetectionRepresentativeMode
    public var representativeOffsetCentimeters: UInt16
    public init(representative: DetectionRepresentativeMode = .mean, representativeOffsetCentimeters: UInt16 = 0) {
        self.representative = representative
        self.representativeOffsetCentimeters = min(representativeOffsetCentimeters, 10)
    }
    public static let defaults = Self()
    public static let legacyDefaults = Self()

    private enum CodingKeys: String, CodingKey { case representative, representativeOffsetCentimeters }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        representative = try values.decodeIfPresent(DetectionRepresentativeMode.self, forKey: .representative) ?? .mean
        representativeOffsetCentimeters = try values.decodeIfPresent(UInt16.self, forKey: .representativeOffsetCentimeters) ?? 0
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(representative, forKey: .representative)
        try values.encode(representativeOffsetCentimeters, forKey: .representativeOffsetCentimeters)
    }
}

public struct DetectionCellsConfiguration: Codable, Equatable, Sendable {
    public var cellSelection: DetectionCellSelection
    public var continuousBacklashCentimeters: UInt16
    public init(cellSelection: DetectionCellSelection = .init(), continuousBacklashCentimeters: UInt16 = 0) {
        self.cellSelection = cellSelection
        self.continuousBacklashCentimeters = min(continuousBacklashCentimeters, 5)
    }
    public static let defaults = Self()
    public static let legacyDefaults = Self()

    private enum CodingKeys: String, CodingKey { case cellSelection, continuousBacklashCentimeters }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        cellSelection = try values.decodeIfPresent(DetectionCellSelection.self, forKey: .cellSelection) ?? .init()
        continuousBacklashCentimeters = try values.decodeIfPresent(UInt16.self, forKey: .continuousBacklashCentimeters) ?? 0
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(cellSelection, forKey: .cellSelection)
        try values.encode(continuousBacklashCentimeters, forKey: .continuousBacklashCentimeters)
    }
}

