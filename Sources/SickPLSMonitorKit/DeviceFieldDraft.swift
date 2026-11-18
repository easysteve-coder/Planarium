import Foundation
import PlanariumDomain

/// Mac-local reference areas. They cannot enter an instrument document or a preset.
public struct DeviceFieldDraft: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case protective, warning
        public var title: String { self == .protective ? "Protective field" : "Warning field" }
        public var maximumMeters: Double { self == .protective ? 4 : 50 }
        public var output: String { self == .protective ? "OSSD 1/2" : "WEAK SIGNAL" }
    }
    public let kind: Kind
    public var area: [PolarMetricCellSegment]
    public var segments: ScannerFieldContour.SegmentCount
    public var lastExportedRadii: [UInt16]?
    public var lastExportedSegments: ScannerFieldContour.SegmentCount?
    public init(kind: Kind, area: [PolarMetricCellSegment] = [], segments: ScannerFieldContour.SegmentCount = .threeSixty) {
        self.kind = kind; self.area = area; self.segments = segments
    }
    public enum Validation: Equatable, Sendable {
        case valid(ScannerFieldContour)
        case invalid(String)
    }
    public var validation: Validation {
        if area.contains(where: { $0.outerRadiusMeters > kind.maximumMeters }) {
            return .invalid("\(kind.title) exceeds \(Int(kind.maximumMeters)) m.")
        }
        switch ScannerFieldRepresentation.contour(area: area, segments: segments) {
        case .success(let value): return .valid(value)
        case .failure(let reason):
            let text: String
            switch reason {
            case .emptyArea: text = "Empty field."
            case .invalidCell: text = "Invalid geometry."
            case .outsideForwardSemicircle: text = "Outside the forward semicircle."
            case .doesNotReachScanner: text = "Island: the field must reach the scanner."
            case .ringOrRadialGap: text = "Ring or radial gap in the field."
            case .radiusOutside13Bits: text = "Radius exceeds the contour value range."
            case .angularDetailBelowSegmentResolution: text = "Angular detail is too fine for the selected segment count."
            }
            return .invalid(text)
        }
    }
    public var status: String {
        switch validation {
        case .valid: return segments == .oneEighty ? "Representable · 180 wire format unverified; export unavailable." : "Representable · \(segments.rawValue) segments."
        case .invalid(let reason): return reason
        }
    }
    public var exportDifference: String {
        guard let old = lastExportedRadii, let oldSegments = lastExportedSegments else { return "No previous export." }
        guard case .valid(let contour) = validation else { return "Draft invalid; differs from last export." }
        guard oldSegments == segments else { return "Segment count differs from last export." }
        guard old.count == contour.radiiCentimeters.count else { return "Previous export point count is invalid." }
        let changed = zip(old, contour.radiiCentimeters).filter { $0 != $1 }.count
        return changed == 0 ? "Matches last export." : "\(changed) radii differ from last export."
    }
    public mutating func recordExport(_ contour: ScannerFieldContour) {
        lastExportedRadii = contour.radiiCentimeters; lastExportedSegments = contour.segments
    }
    public static func semicircle(kind: Kind, radius: Double) -> Self {
        .init(kind: kind, area: [.init(innerRadiusMeters: 0, outerRadiusMeters: radius, startBearingDegrees: -90, endBearingDegrees: 90)])
    }
    /// A 2×2 m rectangle rooted at the scanner, sampled in half-degree sectors.
    public static func rectangle(kind: Kind, width: Double = 2, depth: Double = 2) -> Self {
        .init(kind: kind, area: (0..<360).map { index in
            let start = -90 + Double(index) * 0.5, angle = (start + 0.25) * .pi / 180
            let radius = min(width / 2 / max(1e-10, abs(sin(angle))), depth / max(1e-10, cos(angle)))
            return .init(innerRadiusMeters: 0, outerRadiusMeters: radius, startBearingDegrees: start, endBearingDegrees: start + 0.5)
        })
    }
}

public struct DeviceFieldDrafts: Codable, Equatable, Sendable {
    public var protective = DeviceFieldDraft(kind: .protective)
    public var warning = DeviceFieldDraft(kind: .warning)
    public var showInEdit = true
    public var showInPerformance = true
    public init() {}
    public subscript(kind: DeviceFieldDraft.Kind) -> DeviceFieldDraft {
        get { kind == .protective ? protective : warning }
        set { if kind == .protective { protective = newValue } else { warning = newValue } }
    }
}
public enum DeviceFieldDraftStore {
    public static let key = "de.planarium.device-fields.v1.drafts"
    public static func load(from defaults: UserDefaults) -> DeviceFieldDrafts {
        guard let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(DeviceFieldDrafts.self, from: data),
              value.protective.kind == .protective, value.warning.kind == .warning,
              [value.protective, value.warning].allSatisfy({ draft in
                  let exportValid: Bool
                  switch (draft.lastExportedRadii, draft.lastExportedSegments) {
                  case (nil, nil): exportValid = true
                  case (let radii?, let segments?): exportValid = radii.count == segments.rawValue + 1 && radii.allSatisfy { $0 <= 0x1FFF }
                  case (.some, nil), (nil, .some): exportValid = false
                  }
                  return exportValid && draft.area.allSatisfy {
                      [$0.innerRadiusMeters, $0.outerRadiusMeters, $0.startBearingDegrees, $0.endBearingDegrees].allSatisfy(\.isFinite)
                          && $0.innerRadiusMeters >= 0 && $0.outerRadiusMeters > $0.innerRadiusMeters && $0.outerRadiusMeters <= 81.91
                          && $0.startBearingDegrees >= -90 && $0.endBearingDegrees <= 90 && $0.startBearingDegrees < $0.endBearingDegrees
                  }
              }) else { return .init() }
        return value
    }
    public static func save(_ value: DeviceFieldDrafts, to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
