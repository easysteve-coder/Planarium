import Foundation
import SickPLSCore

/// Portable raw-profile evidence, independent of telegrams, ports and UI.
public struct ProfileRecording: Codable, Sendable {
    public let version: Int
    public let capturedAt: Date
    public let durationSeconds: Double
    public let detection: DetectionConfiguration
    /// DetectionConfiguration deliberately omits the session room filter in
    /// preset coding. A recording must preserve it for faithful evaluation.
    public let roomFilter: SpatialRoomContourConfiguration
    public let contour: SpatialRoomContour?
    public let scans: [Scan]

    public init(capturedAt: Date, durationSeconds: Double = 10, detection: DetectionConfiguration,
                contour: SpatialRoomContour?, scans: [Scan]) {
        version = 1; self.capturedAt = capturedAt; self.durationSeconds = durationSeconds
        self.detection = detection; roomFilter = detection.roomContour; self.contour = contour; self.scans = scans
    }

    private enum CodingKeys: String, CodingKey {
        case version, capturedAt, durationSeconds, detection, roomFilter, contour, scans
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        capturedAt = try values.decode(Date.self, forKey: .capturedAt)
        durationSeconds = try values.decode(Double.self, forKey: .durationSeconds)
        roomFilter = try values.decodeIfPresent(SpatialRoomContourConfiguration.self, forKey: .roomFilter) ?? .init()
        var configuration = try values.decode(DetectionConfiguration.self, forKey: .detection)
        configuration.roomContour = roomFilter; detection = configuration
        contour = try values.decodeIfPresent(SpatialRoomContour.self, forKey: .contour)
        scans = try values.decode([Scan].self, forKey: .scans)
    }

    public struct Scan: Codable, Sendable {
        public struct Sample: Codable, Sendable {
            public let order: Int
            public let lowerTick: Int
            public let upperTick: Int
            public let rawCentimeters: UInt16
        }
        public struct RawSample: Codable, Sendable {
            public let value: UInt16
            public let fieldFlags: UInt8
        }
        public let sessionID: UUID
        public let sequence: UInt64
        public let time: Double
        public let sourceIdentifier: String
        public let operatingMode: String
        public let pointCount: Int
        public let startAngleDegrees: Double
        public let endAngleDegrees: Double
        public let measurements: [Sample]
        public let rawMeasurements: [RawSample]?

        public init(_ frame: ProfileFrame) {
            sessionID = frame.sessionID; sequence = frame.sequence; time = frame.time
            sourceIdentifier = frame.sourceIdentifier
            operatingMode = frame.geometry.operatingMode; pointCount = frame.geometry.pointCount
            startAngleDegrees = frame.geometry.startAngleDegrees; endAngleDegrees = frame.geometry.endAngleDegrees
            measurements = frame.measurements.map { .init(order: $0.order, lowerTick: $0.ticks.lower,
                upperTick: $0.ticks.upper, rawCentimeters: $0.rawCentimeters) }
            rawMeasurements = frame.rawProfile?.measurements.map { .init(value: $0.value, fieldFlags: $0.fieldFlags) }
        }

        public func frame() throws -> ProfileFrame {
            let geometry = ProfileGeometryIdentity(operatingMode: operatingMode, pointCount: pointCount,
                startAngleDegrees: startAngleDegrees, endAngleDegrees: endAngleDegrees)
            guard time.isFinite, [90, 180, 361].contains(pointCount), startAngleDegrees == -90, endAngleDegrees == 90,
                  Set(measurements.map(\.order)).count == measurements.count else { throw RecordingError.invalidScan }
            let values = try measurements.map { sample -> DeviceTickMeasurement in
                guard let ticks = DeviceTickSpan(lower: sample.lowerTick, upper: sample.upperTick),
                      geometry.tickSpan(at: sample.order) == ticks,
                      let value = DeviceTickMeasurement(order: sample.order, ticks: ticks, rawCentimeters: sample.rawCentimeters)
                else { throw RecordingError.invalidScan }
                return value
            }.sorted { $0.order < $1.order }
            let raw = try rawMeasurements.map { samples -> B0ScanProfile in
                guard samples.count == pointCount else { throw RecordingError.invalidScan }
                return try .build(partialScanIndex: 0, measurements: samples.map { try .build(value: $0.value, fieldFlags: $0.fieldFlags) })
            }
            return .init(sessionID: sessionID, sequence: sequence, time: time, measurements: values,
                         geometry: geometry, sourceIdentifier: sourceIdentifier, rawProfile: raw)
        }
    }
    public enum RecordingError: Error { case invalidScan, unsupportedVersion }
}
