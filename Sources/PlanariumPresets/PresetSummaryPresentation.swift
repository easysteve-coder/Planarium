import Foundation

/// Split only for display; persisted prose and the menu tooltip remain verbatim.
public struct PresetSummaryPresentation: Equatable, Sendable {
    public let body: String
    public let source: String
    public let tooltip: String
    public var isVisible: Bool { !tooltip.isEmpty }
    public init(_ summary: String) {
        tooltip = summary
        if let range = summary.range(of: "Source: ") {
            body = String(summary[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            source = String(summary[range.lowerBound...])
        } else { body = summary; source = "" }
    }
}
