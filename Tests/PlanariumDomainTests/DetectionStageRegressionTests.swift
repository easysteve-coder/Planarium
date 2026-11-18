import XCTest
import CryptoKit
@testable import PlanariumDomain

/// SHA-256 evidence frozen on cc3802d before the stage refactor. Floating
/// geometry is recorded by bit pattern, musical events through their values.
final class DetectionStageRegressionTests: XCTestCase {
    private let id = UUID(uuidString: "00000000-0000-0000-0000-000000000023")!
    private let session = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!

    func testContourToleranceDefaultResetAndStoredRecording() throws {
        XCTAssertEqual(SpatialRoomContourConfiguration().toleranceCentimeters, 5)
        XCTAssertEqual(SpatialRoomContourConfiguration.defaults.toleranceCentimeters, 5)
        XCTAssertEqual(SpatialRoomContourConfiguration.legacyDefaults.toleranceCentimeters, 5)
        XCTAssertEqual(DetectionConfiguration.ownerDefaults.room.toleranceCentimeters, 5)
        let control = DetectionControlDescriptor.descriptor(.contourTolerance)
        XCTAssertEqual(control.name, "Contour tolerance")
        XCTAssertEqual(control.values, Array(1...30))
        XCTAssertEqual(control.defaultValue, 5)
        var configuration = DetectionConfiguration.ownerDefaults
        configuration.room = .init(isEnabled: true, toleranceCentimeters: 3)
        let reset = control.applying(control.defaultValue, to: configuration, hasMatchingContour: true, performing: false)
        XCTAssertEqual(reset.room.toleranceCentimeters, 5)
        let stored = ProfileRecording(capturedAt: .init(timeIntervalSince1970: 0), detection: configuration, contour: nil, scans: [])
        let bytes = try JSONEncoder().encode(stored)
        let restored = try JSONDecoder().decode(ProfileRecording.self, from: bytes)
        XCTAssertEqual(restored.roomFilter.toleranceCentimeters, 3)
        XCTAssertEqual(restored.detection.room.toleranceCentimeters, 3)
        XCTAssertEqual(restored.detection.room.isEnabled, true)
        var fieldless = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        fieldless.removeValue(forKey: "roomFilter")
        let legacy = try JSONDecoder().decode(ProfileRecording.self, from: JSONSerialization.data(withJSONObject: fieldless))
        XCTAssertEqual(legacy.roomFilter.toleranceCentimeters, 5)
        XCTAssertEqual(legacy.detection.room.toleranceCentimeters, 5)
        XCTAssertEqual(try JSONDecoder().decode(DetectionConfiguration.self, from: Data("{}".utf8)).room.toleranceCentimeters, 5)
    }

    func testDenseMMKWindowsMatchGappedTraversalIncludingTiesAndAngularEdges() {
        for count in [90, 361] {
            let geometry = ProfileGeometryIdentity(operatingMode: "fullScan", pointCount: count,
                startAngleDegrees: -90, endAngleDegrees: 90)
            let measurements = (0..<count).map { order in
                DeviceTickMeasurement(order: order, ticks: geometry.tickSpan(at: order)!,
                    rawCentimeters: abs(order - count / 2) < 3 ? (order == count / 2 ? 12 : 90) : 250)!
            }
            let points = geometry.project(measurements)
            for mode in VirtualMMKMode.allCases {
                for width: UInt8 in [1, 2, 5] {
                    for softness: UInt8 in [0, 45, 100] {
                        let beams = DetectionBeamsConfiguration(virtualMMKMode: mode,
                            virtualMMKTargetWidthCentimeters: width, virtualMMKSoftness: softness)
                        let dense = beams.virtualMMK(points, geometry: geometry)
                        // Removing the distant first wall ray forces the original
                        // gapped traversal. It is outside every foreground window;
                        // equal wall distances cannot alter any remaining ray.
                        let gapped = beams.virtualMMK(Array(points.dropFirst()), geometry: geometry)
                        XCTAssertEqual(Array(dense.dropFirst()), gapped,
                            "rays=\(count) mode=\(mode) width=\(width) softness=\(softness)")
                    }
                }
            }
            if count == 361 {
                let beams = DetectionBeamsConfiguration(virtualMMKMode: .fixed2, virtualMMKSoftness: 45)
                let dense = beams.virtualMMK(points, geometry: geometry)
                let reversed = beams.virtualMMK(Array(points.reversed()), geometry: geometry)
                // The two 90-cm neighbours tie in distance but not in weight.
                // Legacy selection uses the first nearest ray in input order.
                XCTAssertEqual(dense.first { $0.order == 177 }?.distanceCentimeters, 227)
                XCTAssertEqual(reversed.first { $0.order == 177 }?.distanceCentimeters, 250)
            }
        }
    }

    func testMovingCoreIsSmoothedBeforeCellChoiceAndMeasuredExitReleasesNote() throws {
        let cells = Set((100...119).map { PolarDeviceLattice(ring: $0, sector: 180)! })
        let layer = SpatialDocumentLayer(id: id, name: "Moving core", color: .blue, isVisible: true,
            isActive: true, isLocked: false, isSoloed: false, cells: cells,
            routings: [.init(id: session, target: .midiNote(channel: 0), program: .singleNote(note: 60, velocity: 90, transition: .legato))], cellOverrides: [:])
        let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: id)
        let configuration = DetectionConfiguration(temporalSmoothing: .mean(window: 4), minimumAngleDegrees: 0,
            virtualMMKMode: .raw, edgePoints: 0, coreWidthCentimeters: 3)
        let instrument = try InstrumentCompiler.compile(.init(spatial: spatial, detection: configuration,
            revision: .init(session: session, counter: 1), editorGrid: .quarterMeter))
        func frame(_ sequence: UInt64, distance: UInt16?) -> ProfileFrame {
            .init(sessionID: session, sequence: sequence, time: Double(sequence) / 25,
                measurements: distance.map { [DeviceTickMeasurement(order: 180, ticks: .point(180)!, rawCentimeters: $0)!] } ?? [])
        }
        var pipeline = SpatialDetectionPipeline()
        var play = PlayEngine.step(PlayState(), .install(instrument)).0
        for (sequence, distance, expected) in [(UInt64(1), UInt16(100), 100.0), (2, 120, 110.0)] {
            let input = frame(sequence, distance: distance)
            let selection = pipeline.selectForPresentation(frame: input, instrument: instrument, contour: nil)
            XCTAssertEqual(try XCTUnwrap(selection.representative).distanceCentimeters, expected, accuracy: 1e-12)
            XCTAssertNotNil(selection.activeHandles[id], "The measured mean remains in the painted cell")
            play = PlayEngine.step(play, .frame(input)).0
            XCTAssertEqual(play.soundingNoteCount, 1)
        }
        let exited = PlayEngine.step(play, .frame(frame(3, distance: nil)))
        XCTAssertEqual(exited.0.soundingNoteCount, 0)
        XCTAssertTrue(exited.1.contains { if case .noteOff = $0 { return true }; return false })
    }

    func testDescriptorsEditTheirStageAndBlockPerformWithoutChangingStoredValues() throws {
        let controls = DetectionStage.allCases.flatMap(\.controls)
        XCTAssertEqual(Set(controls.map(\.id)), Set(DetectionControlDescriptor.ID.allCases))
        XCTAssertEqual(controls.count, DetectionControlDescriptor.ID.allCases.count)
        var configuration = DetectionConfiguration.ownerDefaults
        configuration.room.isEnabled = true
        configuration.time.selectMethod(1)
        configuration.representativeStage.representative = .nearestPointWithOffset
        for control in controls {
            if control.id == .weight { configuration.time.selectMethod(3) }
            if control.id == .window { configuration.time.selectMethod(1) }
            let value = try XCTUnwrap(control.values.first { $0 != control.value(in: configuration) })
            let before = configuration
            XCTAssertEqual(control.applying(value, to: before, hasMatchingContour: true, performing: true), before, control.id.rawValue)
            if control.isAvailable(configuration: before, hasMatchingContour: true, performing: false) {
                let changed = control.applying(value, to: before, hasMatchingContour: true, performing: false)
                XCTAssertNotEqual(changed, before, control.id.rawValue)
                XCTAssertEqual(control.value(in: changed), value, control.id.rawValue)
            }
            XCTAssertEqual(control.applying(-99, to: before, hasMatchingContour: true, performing: false), before)
        }
        let softness = DetectionControlDescriptor.descriptor(.softness)
        configuration.virtualMMKSoftness = 70
        XCTAssertEqual(softness.applying(45, to: configuration, hasMatchingContour: false, performing: false).virtualMMKSoftness, 45,
            "The historic default lies between detents and remains a valid double-click reset")
        let width = DetectionControlDescriptor.descriptor(.targetWidth)
        configuration.virtualMMKMode = .raw
        XCTAssertEqual(width.applying(5, to: configuration, hasMatchingContour: false, performing: false), configuration)
        configuration.virtualMMKMode = .adaptive
        XCTAssertEqual(width.applying(5, to: configuration, hasMatchingContour: false, performing: false).beams.virtualMMKTargetWidthCentimeters, 5)
        configuration.temporalSmoothing = .median(window: 6)
        configuration.time.selectMethod(0)
        XCTAssertEqual(configuration.temporalSmoothing, .median(window: 6))
        configuration.time.selectMethod(1)
        XCTAssertEqual(configuration.effective.temporalSmoothing, .mean(window: 6))
    }

    func testStageDecodersPreserveHistoricMissingValuesAndFlatEncoding() throws {
        let legacy = try JSONDecoder().decode(DetectionConfiguration.self, from: Data("{}".utf8))
        XCTAssertEqual(legacy.beams, .legacyDefaults)
        XCTAssertEqual(legacy.edge, .legacyDefaults)
        XCTAssertEqual(legacy.core, .legacyDefaults)
        XCTAssertEqual(legacy.room, .legacyDefaults)
        var configured = DetectionConfiguration.ownerDefaults
        configured.room = .init(isEnabled: true, toleranceCentimeters: 20)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(configured)) as? [String: Any])
        for key in ["room", "beams", "groups", "edge", "core", "time", "cells", "representativeStage"] {
            XCTAssertNil(object[key], "Stage nesting must never reach the preset wire format")
        }
        let decoded = try JSONDecoder().decode(DetectionConfiguration.self, from: encoder.encode(configured))
        configured.room = .init()
        XCTAssertEqual(decoded, configured, "Room remains session-only; ProfileRecording stores it separately")
    }

    func testSavedRandpunkteRecordingReplayIsBitIdentical() throws {
        // Same rays as RANDPUNKTE's saved synthetic-hand-recording.json;
        // regenerate the portable recording to avoid depending on run folders.
        let scans = (0..<80).map { scan -> ProfileRecording.Scan in
            var rays = Dictionary(uniqueKeysWithValues: (161...199).map { ($0, UInt16(30)) })
            for side in [-1, 1] {
                let count = ((scan * (side == -1 ? 17 : 31) + (side == -1 ? 3 : 7)) % 11) % 2 + 1
                let first = side == -1 ? 160 : 200
                rays[first] = UInt16(42 + (scan * (side == -1 ? 7 : 13) % 5))
                rays[first + side] = count == 2 ? rays[first]! + 20 : nil
            }
            let measurements = rays.keys.sorted().map {
                DeviceTickMeasurement(order: $0, ticks: ProfileGeometryIdentity.fullScan361.tickSpan(at: $0)!, rawCentimeters: rays[$0]!)!
            }
            return .init(.init(sessionID: session, sequence: UInt64(scan + 1), time: Double(scan + 1) / 25, measurements: measurements))
        }
        let source = ProfileRecording(capturedAt: Date(timeIntervalSince1970: 0),
            detection: .init(groupingJumpCentimeters: 24, minimumAngleDegrees: 0, virtualMMKMode: .raw, edgePoints: 0, coreWidthCentimeters: 0),
            contour: nil, scans: scans)
        let recording = try JSONDecoder().decode(ProfileRecording.self, from: JSONEncoder().encode(source))
        XCTAssertEqual(recording.scans.count, 80)
        var evidence = ""
        for edge: UInt8 in [0, 1, 2] {
            for core: UInt8 in [0, 2, 3, 5] {
                for representative in DetectionRepresentativeMode.allCases {
                    var configuration = recording.detection
                    configuration.edgePoints = edge; configuration.coreWidthCentimeters = core
                    configuration.representative = representative
                    configuration.temporalSmoothing = .mean(window: 4)
                    let cells = Set((20...220).flatMap { ring in (140...220).map { PolarDeviceLattice(ring: ring, sector: $0)! } })
                    let layer = SpatialDocumentLayer(id: id, name: "Recorded hand", color: .blue, isVisible: true,
                        isActive: true, isLocked: false, isSoloed: false, cells: cells,
                        routings: [.init(id: session, target: .midiNote(channel: 0), program: .singleNote(note: 60, velocity: 90, transition: .legato))], cellOverrides: [:])
                    let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: id)
                    let instrument = try InstrumentCompiler.compile(.init(spatial: spatial, detection: configuration,
                        revision: .init(session: session, counter: 1), editorGrid: .quarterMeter))
                    var pipeline = SpatialDetectionPipeline()
                    for scan in recording.scans {
                        let result = pipeline.selectForPresentation(frame: try scan.frame(), instrument: instrument, contour: recording.contour)
                        for object in result.objects {
                            evidence += "\(object.center.xMeters.bitPattern),\(object.center.yMeters.bitPattern),\(object.diameterMeters.bitPattern),\(object.representative.point.xMeters.bitPattern),\(object.representative.point.yMeters.bitPattern),\(object.measuredOrders),\(object.coreOrders),\(object.discardedEdgeOrders);"
                        }
                        if let handle = result.activeHandles[id] { evidence += "\(handle.cell.ring),\(handle.cell.sector);" }
                        if let distance = result.candidateDistancesCentimeters[id] { evidence += "\(distance.bitPattern);" }
                    }
                }
            }
        }
        let hash = SHA256.hash(data: Data(evidence.utf8)).map { String(format: "%02x", $0) }.joined()
        print("RANDPUNKTE saved recording digest \(hash)")
        XCTAssertEqual(hash, "0920b9baa6bbf9d10b40104949167b8bc26ccd3f7d2e958d702389b93c6e7690")
    }

    func testRandpunkteRecordingReplayAndMusicAreBitIdentical() throws {
        var evidence = ""
        var eventCount = 0
        for count in [90, 361] {
            let geometry = ProfileGeometryIdentity(operatingMode: "full", pointCount: count,
                startAngleDegrees: -90, endAngleDegrees: 90)
            let scans = (0..<80).map { scan -> ProfileRecording.Scan in
                let measurements = (0..<count).compactMap { order -> DeviceTickMeasurement? in
                    let bearing = -90 + Double(order) * 180 / Double(count - 1)
                    let center = Double(scan % 21 - 10)
                    let radial = scan % 17 < 12 ? 100 + scan % 9 : 180
                    let distance = abs(bearing - center) < 7 ? radial + Int(abs(bearing - center)) * 4 : 300
                    return .init(order: order, ticks: geometry.tickSpan(at: order)!, rawCentimeters: UInt16(distance))
                }
                return .init(.init(sessionID: session, sequence: UInt64(scan + 1), time: Double(scan) / 25,
                    measurements: measurements, geometry: geometry))
            }
            let contour = SpatialRoomContour(geometry: .init(pointCount: count,
                angleResolutionDegrees: 180 / Double(count - 1), startAngleDegrees: -90, sourceIdentifier: "scanner:default"),
                nearestDistancesCentimeters: Array(repeating: 300, count: count), spreadCentimeters: [])
            for core: UInt8 in [0, 3] {
                for edge: UInt8 in [0, 1, 2] {
                    for method: DetectionTemporalSmoothing in [.off, .mean(window: 4), .median(window: 3), .exponential(alpha: 0.3)] {
                        for mode in VirtualMMKMode.allCases {
                            var config = DetectionConfiguration(temporalSmoothing: method, groupingJumpCentimeters: 24,
                                representative: .mean, cellSelection: .init(boundaryMarginCentimeters: 5, confirmationProfiles: 2),
                                roomContour: .init(isEnabled: true), minimumAngleDegrees: 20, virtualMMKMode: mode,
                                edgePoints: edge, coreWidthCentimeters: core)
                            config.continuousBacklashCentimeters = 2
                            let recording = ProfileRecording(capturedAt: Date(timeIntervalSince1970: 0), detection: config,
                                contour: contour, scans: scans)
                            let replay = try JSONDecoder().decode(ProfileRecording.self, from: JSONEncoder().encode(recording))
                            let cells = Set((90...190).flatMap { ring in (140...220).map { PolarDeviceLattice(ring: ring, sector: $0)! } })
                            let route = SpatialRouting(id: session, target: .midiNote(channel: 0),
                                program: .scale(rootMIDINote: 60, lowestMIDINote: 60, highestMIDINote: 72,
                                    scale: .chromatic, directionDegrees: 90, ascending: true, transition: .legato))
                            let layer = SpatialDocumentLayer(id: id, name: "Replay", color: .blue, isVisible: true,
                                isActive: true, isLocked: false, isSoloed: false, cells: cells, routings: [route], cellOverrides: [:])
                            let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: id)
                            // This frozen replay predates the new-instrument default; retain its 25-cm fixture.
                            let instrument = try InstrumentCompiler.compile(.init(spatial: spatial, detection: replay.detection,
                                revision: .init(session: session, counter: 1), editorGrid: .quarterMeter))
                            var pipeline = SpatialDetectionPipeline()
                            var play = PlayEngine.step(PlayState(), .install(instrument)).0
                            play = PlayEngine.step(play, .roomContour(replay.contour)).0
                            for scan in replay.scans {
                                let frame = try scan.frame()
                                let result = pipeline.selectForPresentation(frame: frame, instrument: instrument, contour: replay.contour)
                                evidence += "\(count):\(core):\(edge):\(method):\(mode):\(scan.sequence);"
                                for object in result.objects {
                                    evidence += "\(object.center.xMeters.bitPattern),\(object.center.yMeters.bitPattern),\(object.diameterMeters.bitPattern),\(object.representative.point.xMeters.bitPattern),\(object.representative.point.yMeters.bitPattern),\(object.measuredOrders),\(object.coreOrders),\(object.discardedEdgeOrders);"
                                }
                                let step = PlayEngine.step(play, .frame(frame)); play = step.0
                                eventCount += step.1.count
                                evidence += String(describing: step.1)
                            }
                            let stop = PlayEngine.step(play, .stop)
                            evidence += String(describing: stop.1)
                            XCTAssertEqual(stop.0.soundingNoteCount, 0)
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(eventCount, 100)
        // Event descriptions carry module-qualified type names; the digest freezes
        // the music, not the module a type lives in. Under the former single
        // PlanariumDomain module this evidence hashed to f3292dc9…f157a6
        // (checked on 18.11.2026 when the music values moved to PlanariumMusicCore).
        let neutral = evidence.replacingOccurrences(of: #"Planarium[A-Za-z]+\."#, with: "", options: .regularExpression)
        let hash = SHA256.hash(data: Data(neutral.utf8)).map { String(format: "%02x", $0) }.joined()
        print("RANDPUNKTE replay digest \(hash), events \(eventCount)")
        XCTAssertEqual(hash, "e1bf939f9af9cdadeee22a81f7cd25ec2d28f589f200530a23f3d8452093ab39")
    }
}
