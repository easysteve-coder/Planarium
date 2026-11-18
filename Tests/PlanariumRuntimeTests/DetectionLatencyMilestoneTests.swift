import Dispatch
import Foundation
import XCTest
import PlanariumDomain
import PlanariumRuntime

/// An opt-in release-build milestone probe.  It uses the real runtime and
/// detection pipeline but only locked fake MIDI/AU boundaries; it never opens
/// an app, audio engine, MIDI endpoint, or scanner.
final class DetectionLatencyMilestoneTests: RuntimeTestCase {
    private static let profileRateHz = 25.0
    private static let profileMilliseconds = 1_000.0 / profileRateHz
    private static let sampleCount = 101

    func testDetectionEntryAndReleaseLatencyFor90And361WhenExplicitlyEnabled() throws {
        #if DEBUG
        throw XCTSkip("Detection latency milestone is measured with swift test -c release")
        #else
        guard ProcessInfo.processInfo.environment["PLANARIUM_DETECTION_LATENCY"] == "1" else {
            throw XCTSkip("Opt in: PLANARIUM_DETECTION_LATENCY=1 swift test -c release --disable-swift-testing --filter DetectionLatencyMilestoneTests")
        }

        for pointCount in [90, 361] {
            for configuration in configurations {
                let entry = try samples(pointCount: pointCount, configuration: configuration, transition: .entry)
                let release = try samples(pointCount: pointCount, configuration: configuration, transition: .release)
                // Confirmation is a cell-switch rule. A first measured hand
                // entry has no preceding cell and therefore takes one scan.
                let expectedEntryProfiles = 1
                let expectedReleaseProfiles = 1
                XCTAssertEqual(entry.profileCounts, Set([expectedEntryProfiles]), "entry must require its configured measured profiles")
                XCTAssertEqual(release.profileCounts, Set([expectedReleaseProfiles]), "an empty measured profile must release immediately")
                print(report(pointCount: pointCount, configuration: configuration, entry: entry, release: release))
            }
        }
        #endif
    }

    private struct ProbeConfiguration {
        let snapCentimeters: UInt16
        let confirmationProfiles: Int
        var configuration: DetectionConfiguration {
            // Every stage below is intentionally on: mean smoothing, adjacent
            // point grouping, selection snap and optional confirmation.
            DetectionConfiguration(temporalSmoothing: .mean(window: 4), groupingEnabled: true,
                groupingJumpCentimeters: 10, groupingMinimumPoints: 1, representative: .mean,
                cellSelection: .init(boundaryMarginCentimeters: snapCentimeters,
                                     confirmationProfiles: confirmationProfiles))
        }
    }

    private var configurations: [ProbeConfiguration] {
        [UInt16(0), 5, 10].flatMap { snap in
            [1, 2].map { confirmation in
                .init(snapCentimeters: snap, confirmationProfiles: confirmation)
            }
        }
    }

    private enum Transition { case entry, release }

    private struct Samples {
        let milliseconds: [Double]
        let profileCounts: Set<Int>
    }

    private func samples(pointCount: Int, configuration: ProbeConfiguration, transition: Transition) throws -> Samples {
        var milliseconds: [Double] = []
        var profileCounts = Set<Int>()
        for _ in 0..<Self.sampleCount {
            let midi = FakeBoundary(), au = FakeBoundary()
            let composition = self.composition(midi: midi, au: au)
            composition.runtime.install(try latencyInstrument(configuration: configuration.configuration))
            composition.runtime.sessionBegan(session)

            var sequence: UInt64 = 0
            func deliver(_ handDistance: UInt16?) {
                sequence += 1
                composition.runtime.frame(profile(pointCount: pointCount, sequence: sequence, handDistance: handDistance))
                flush(composition.runtime)
            }
            switch transition {
            case .entry:
                let started = DispatchTime.now().uptimeNanoseconds
                var profiles = 0
                while profiles < 2 && midi.sounding.isEmpty {
                    deliver(100); profiles += 1
                }
                XCTAssertFalse(midi.sounding.isEmpty, "the measured target cell must produce its own Note-On")
                let ended = try lastReceiptTime(midi: midi, au: au, expectedStatus: 0x90, after: started)
                XCTAssertFalse(au.sounding.isEmpty, "hand in a cell must reach the fake AU too")
                milliseconds.append(Double(ended - started) / 1_000_000)
                profileCounts.insert(profiles)
            case .release:
                for _ in 0..<configuration.confirmationProfiles { deliver(100) }
                XCTAssertFalse(midi.sounding.isEmpty, "setup must first produce the measured Note-On")
                let started = DispatchTime.now().uptimeNanoseconds
                var profiles = 0
                while profiles < 2 && !midi.sounding.isEmpty { deliver(nil); profiles += 1 }
                XCTAssertTrue(midi.sounding.isEmpty, "the measured exit must release within one profile")
                let ended = try lastReceiptTime(midi: midi, au: au, expectedStatus: 0x80, after: started)
                XCTAssertTrue(au.sounding.isEmpty, "hand out of the cell must release the fake AU too")
                milliseconds.append(Double(ended - started) / 1_000_000)
                profileCounts.insert(profiles)
            }
            composition.runtime.stop()
            flush(composition.runtime)
        }
        return .init(milliseconds: milliseconds, profileCounts: profileCounts)
    }

    private func profile(pointCount: Int, sequence: UInt64, handDistance: UInt16?) -> ProfileFrame {
        let geometry = ProfileGeometryIdentity(operatingMode: pointCount == 90 ? "segmentMinimum" : "fullScan",
                                               pointCount: pointCount, startAngleDegrees: -90, endAngleDegrees: 90)
        let handOrder = pointCount == 90 ? 45 : 180
        let measurements: [DeviceTickMeasurement] = (0..<pointCount).compactMap { order in
            guard order != handOrder || handDistance != nil else { return nil }
            let distance = order == handOrder ? handDistance! : 300
            return DeviceTickMeasurement(order: order, ticks: geometry.tickSpan(at: order)!, rawCentimeters: distance)
        }
        return .init(sessionID: session, sequence: sequence, time: 10 + Double(sequence) / Self.profileRateHz,
                     measurements: measurements, geometry: geometry)
    }

    private func latencyInstrument(configuration: DetectionConfiguration) throws -> CompiledInstrument {
        let near = PolarDeviceLattice(ring: 100, sector: 180)!
        let far = PolarDeviceLattice(ring: 101, sector: 180)!
        let midi = SpatialRoutingTarget.midiNote(channel: 0)
        let audio = SpatialRoutingTarget.audioUnitNote(channel: 0, stripID: InstrumentChannel.legacyID)
        let program = SpatialValueProgram.singleNote(note: 60, velocity: 100, transition: .legato)
        let layer = SpatialDocumentLayer(id: session, name: "Latency", color: .orange, isVisible: true,
            isActive: true, isLocked: false, isSoloed: false, cells: [near, far],
            routings: [.init(target: midi, program: program), .init(target: audio, program: program)],
            cellOverrides: [near: [.init(target: midi, value: .note(number: 60, velocity: 100)),
                                  .init(target: audio, value: .note(number: 60, velocity: 100))],
                            far: [.init(target: midi, value: .note(number: 72, velocity: 100)),
                                  .init(target: audio, value: .note(number: 72, velocity: 100))]])
        let document = InstrumentDocument(spatial: try .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: session),
            detection: configuration, revision: .init(session: session, counter: 1))
        return try InstrumentCompiler.compile(document)
    }

    private func lastReceiptTime(midi: FakeBoundary, au: FakeBoundary, expectedStatus: UInt8, after start: UInt64) throws -> UInt64 {
        let midiTime = try XCTUnwrap(midi.receipts.last(where: { $0.time >= start && $0.bytes[0] & 0xF0 == expectedStatus })?.time)
        let auTime = try XCTUnwrap(au.receipts.last(where: { $0.time >= start && $0.bytes[0] & 0xF0 == expectedStatus })?.time)
        return max(midiTime, auTime)
    }

    private func report(pointCount: Int, configuration: ProbeConfiguration, entry: Samples, release: Samples) -> String {
        let entryStats = statistics(entry.milliseconds), releaseStats = statistics(release.milliseconds)
        let entryNominal = Self.profileMilliseconds
        let releaseNominal = Self.profileMilliseconds
        return String(format: "BUEHNE-FEST-F rays=%d smooth=mean4 grouping=on snap=%dcm confirm=%d " +
                      "entry profiles=%d nominal=%.0fms p50=%.3f p95=%.3f max=%.3fms " +
                      "release profiles=1 nominal=%.0fms p50=%.3f p95=%.3f max=%.3fms n=%d",
                      pointCount, configuration.snapCentimeters, configuration.confirmationProfiles,
                      1, entryNominal, entryStats.0, entryStats.1, entryStats.2,
                      releaseNominal, releaseStats.0, releaseStats.1, releaseStats.2, Self.sampleCount)
    }

    private func statistics(_ values: [Double]) -> (Double, Double, Double) {
        let sorted = values.sorted()
        return (sorted[sorted.count / 2], sorted[Int((Double(sorted.count - 1) * 0.95).rounded(.up))], sorted.last!)
    }
}
