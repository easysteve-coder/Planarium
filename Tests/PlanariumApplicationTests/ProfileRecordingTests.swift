import XCTest
import Foundation
import PlanariumDomain
import PlanariumRuntime
import SickPLSCore
@testable import PlanariumApplication

private final class RecordingSource: RuntimeProfileSource, @unchecked Sendable {
    private let lock = NSLock()
    private var receiver: (@Sendable (ProfileSourceEvent) -> Void)?
    private var count = 0
    var bindings: Int { lock.lock(); defer { lock.unlock() }; return count }
    func bind(_ receive: @escaping @Sendable (ProfileSourceEvent) -> Void) {
        lock.lock(); count += 1; receiver = receive; lock.unlock()
    }
    func send(_ event: ProfileSourceEvent) {
        lock.lock(); let callback = receiver; lock.unlock(); callback?(event)
    }
}
private final class RecordingClock: RuntimeClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time = 0.0
    private var jobs: [UUID: (Double, DispatchQueue, @Sendable () -> Void)] = [:]
    var now: Double { lock.lock(); defer { lock.unlock() }; return time }
    func schedule(at deadline: Double, on queue: DispatchQueue, _ action: @escaping @Sendable () -> Void) -> RuntimeCancellation {
        let id = UUID(); lock.lock(); jobs[id] = (deadline, queue, action); lock.unlock()
        return .init { [weak self] in self?.remove(id) }
    }
    private func remove(_ id: UUID) { lock.lock(); jobs[id] = nil; lock.unlock() }
    func advance(to next: Double) {
        lock.lock(); time = next
        let ready = jobs.filter { $0.value.0 <= next }; for id in ready.keys { jobs[id] = nil }; lock.unlock()
        for (_, queue, action) in ready.values { queue.async(execute: action) }
    }
}
private final class ForwardedProfiles: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ProfileFrame] = []
    func receive(_ event: ProfileSourceEvent) { if case .frame(let frame) = event { lock.lock(); values.append(frame); lock.unlock() } }
    var frames: [ProfileFrame] { lock.lock(); defer { lock.unlock() }; return values }
}

@MainActor final class ProfileRecordingTests: XCTestCase {
    private func ack(_ model: ProfileRecordingModel) {
        let done = DispatchSemaphore(value: 0); model.acknowledge { done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
    }
    private func publish() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    }
    private func frame(_ session: UUID, _ sequence: UInt64, time: Double = 0) throws -> ProfileFrame {
        let raw = try B0ScanProfile.build(partialScanIndex: 0, measurements: (0..<361).map {
            try .build(value: $0 == 180 ? 30 : 300, fieldFlags: UInt8($0 % 8))
        })
        return .init(sessionID: session, sequence: sequence, time: time,
            measurements: try FullScanProfileAdapter.measurements(from: raw),
            geometry: .fullScan361, sourceIdentifier: "recording-fixture", rawProfile: raw)
    }
    func testTenSecondsCopiesEveryProfileThroughOneBindingWhileMainIsBlockedAndRoundTripsRawGeometry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RANDPUNKTE-recording-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = RecordingClock(), recorder = ProfileRecordingModel(directory: directory, clock: clock)
        let source = RecordingSource()
        let forwarded = ForwardedProfiles()
        RecordingProfileSource(source: source, recorder: recorder, roomCapture: RoomCaptureWorker()).bind { forwarded.receive($0) }
        let session = UUID(); source.send(.began(session))
        var configuration = DetectionConfiguration.ownerDefaults
        configuration.roomContour = .init(isEnabled: true, toleranceCentimeters: 7)
        recorder.begin(detection: configuration, contour: nil); ack(recorder)
        let first = try frame(session, 1)
        // Synchronous loop deliberately prevents Main publication/coalescing.
        for sequence: UInt64 in 1...250 {
            source.send(.frame(try frame(session, sequence, time: Double(sequence - 1) / 25)))
        }
        ack(recorder)
        clock.advance(to: 5); ack(recorder); publish()
        XCTAssertEqual(recorder.progress, 0.5, accuracy: 0.001)
        XCTAssertTrue(recorder.isRecording)
        clock.advance(to: 10); ack(recorder); publish()
        XCTAssertFalse(recorder.isRecording); XCTAssertEqual(recorder.progress, 1)
        let url = try XCTUnwrap(recorder.savedURL)
        let data = try Data(contentsOf: url)
        let recording = try JSONDecoder().decode(ProfileRecording.self, from: data)
        XCTAssertEqual(recording.scans.count, 250)
        XCTAssertEqual(recording.durationSeconds, 10)
        XCTAssertEqual(recording.detection, configuration)
        XCTAssertEqual(recording.roomFilter, configuration.roomContour)
        XCTAssertEqual(try recording.scans[0].frame().rawProfile, first.rawProfile)
        XCTAssertEqual(try recording.scans[0].frame().measurements, first.measurements)
        XCTAssertEqual(try recording.scans[0].frame().geometry, first.geometry)
        XCTAssertEqual(recording.scans[249].time, 9.96, accuracy: 0.001)
        XCTAssertEqual(source.bindings, 1)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("telegram"))
        XCTAssertEqual(forwarded.frames.count, 250)
        for (scan, forwardedFrame) in zip(recording.scans, forwarded.frames) {
            XCTAssertEqual(try scan.frame(), forwardedFrame)
        }
    }
    func testNoInputLossSessionChangeCancelRestartAndWriteFailureAreVisibleAndRecover() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RANDPUNKTE-recording-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = RecordingClock(), recorder = ProfileRecordingModel(directory: directory, clock: clock)
        let session = UUID()
        recorder.begin(detection: .ownerDefaults, contour: nil); ack(recorder)
        clock.advance(to: 10); ack(recorder); publish()
        XCTAssertFalse(recorder.isRecording); XCTAssertTrue(recorder.notice.contains("No profiles"))
        for endFirst in [false, true] {
            recorder.begin(detection: .ownerDefaults, contour: nil)
            if endFirst { recorder.receive(.ended(session, reason: .failure)) }
            recorder.receive(.frame(try frame(session, 1)))
            recorder.receive(.ended(session, reason: .failure))
            ack(recorder); publish()
            XCTAssertFalse(recorder.isRecording); XCTAssertNil(recorder.savedURL)
        }
        recorder.begin(detection: .ownerDefaults, contour: nil)
        recorder.receive(.frame(try frame(session, 1))); recorder.receive(.began(UUID()))
        ack(recorder); publish()
        XCTAssertTrue(recorder.notice.contains("session changed"))
        recorder.begin(detection: .ownerDefaults, contour: nil)
        recorder.receive(.frame(try frame(session, 1)))
        recorder.cancel()
        recorder.begin(detection: .legacyDefaults, contour: nil)
        recorder.receive(.frame(try frame(session, 2)))
        recorder.receive(.frame(try frame(session, 2))) // duplicate
        ack(recorder); clock.advance(to: 20); ack(recorder); publish()
        let saved = try XCTUnwrap(recorder.savedURL)
        let recording = try JSONDecoder().decode(ProfileRecording.self, from: Data(contentsOf: saved))
        XCTAssertEqual(recording.scans.map(\.sequence), [2]); XCTAssertEqual(recording.detection, .legacyDefaults)
        // A regular file cannot become the recordings directory.
        let failed = ProfileRecordingModel(directory: saved, clock: clock)
        failed.begin(detection: .ownerDefaults, contour: nil); failed.receive(.frame(try frame(session, 1)))
        ack(failed); clock.advance(to: 30); ack(failed); publish()
        XCTAssertFalse(failed.isRecording); XCTAssertTrue(failed.notice.contains("could not be saved"))
        XCTAssertNil(failed.savedURL)
    }
    func testBlockedRecordingWorkerDoesNotBlockForwardingOrDropPreDeadlineProfile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RANDPUNKTE-recording-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = RecordingClock(), recorder = ProfileRecordingModel(directory: directory, clock: clock)
        let source = RecordingSource(), forwarded = ForwardedProfiles(), session = UUID()
        RecordingProfileSource(source: source, recorder: recorder, roomCapture: RoomCaptureWorker()).bind { forwarded.receive($0) }
        recorder.begin(detection: .ownerDefaults, contour: nil); ack(recorder)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        recorder.acknowledge { entered.signal(); _ = release.wait(timeout: .now() + 5) }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        clock.advance(to: 9.99)
        source.send(.frame(try frame(session, 1, time: 9.99)))
        XCTAssertEqual(forwarded.frames.count, 1, "Playing receives the profile even while the recording worker is blocked")
        clock.advance(to: 10)
        release.signal(); ack(recorder); publish()
        let recording = try JSONDecoder().decode(ProfileRecording.self, from: Data(contentsOf: XCTUnwrap(recorder.savedURL)))
        XCTAssertEqual(recording.scans.map(\.sequence), [1], "Use ingress time, not the later queue execution time")
    }
}

@MainActor final class RoomIngressCaptureTests: XCTestCase {
    private func acknowledge(_ worker: RoomCaptureWorker) {
        let done = DispatchSemaphore(value: 0); worker.acknowledge { done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
    }
    private func frame(_ id: UUID, _ sequence: UInt64, points: Int = 361, distance: UInt16 = 200) throws -> ProfileFrame {
        let raw = try B0ScanProfile.build(partialScanIndex: 0,
            measurements: (0..<points).map { _ in try .build(value: distance, fieldFlags: 0) })
        return .init(sessionID: id, sequence: sequence, time: 3 + Double(sequence - 1) / 25,
            measurements: try FullScanProfileAdapter.measurements(from: raw),
            geometry: try FullScanProfileAdapter.geometry(from: raw), rawProfile: raw)
    }
    func testProductionIngressCaptures125WithoutMainOrDisplayAndPublishesAtMost100ProgressValues() throws {
        for points in [90, 361] {
            let clock = RecordingClock(), f = try RootFixture(clock: clock), owner = f.root.document
            XCTAssertEqual(f.root.input.connectDevelopment(portPath: "/dev/cu.offline", baudRate: .baud500000), .connecting(baudRate: .baud500000))
            f.root.display.start(); f.root.display.setVisible(false)
            owner.beginRoomContourCapture(); clock.advance(to: 3)
            var progress = 0
            let token = owner.contourCapture.$progress.dropFirst().sink { _ in progress += 1 }
            defer { token.cancel(); f.root.terminate {} }
            for index in 1...125 {
                f.scanner.descriptors[0].append(.bytes(try f.bytes(index >= 124 ? 90 : 200, pointCount: points)))
            }
            f.scanner.descriptors[0].append(.closed)
            // EOF closes R only after all 125 frames have entered the existing
            // binding. Do not pace this burst through Main or confuse musical
            // backlog release under TSan with loss in the capture branch.
            let until = Date().addingTimeInterval(5)
            while f.scanner.descriptors[0].count == 0, Date() < until { Thread.sleep(forTimeInterval: 0.001) }
            XCTAssertEqual(f.scanner.descriptors[0].count, 1)
            acknowledge(owner.roomCapture)
            XCTAssertEqual(progress, 0); XCTAssertNil(owner.roomContour)
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            XCTAssertFalse(owner.isCapturingRoomContour)
            let contour = try XCTUnwrap(owner.roomContour)
            XCTAssertEqual(contour.geometry.pointCount, points)
            XCTAssertEqual(contour.nearestDistancesCentimeters[points == 90 ? 45 : 180], 90)
            XCTAssertLessThanOrEqual(progress, 100); XCTAssertEqual(owner.roomContourCaptureProgress, 1)
            XCTAssertNil(f.root.display.frame, "No measurement pane or display pump participated")
        }
    }
    func testSingleBindingSessionLossSwitchGeometryGapAndCompletionOrder() throws {
        let ended = RoomCaptureWorker(), priorLoss = CaptureReports(), priorSession = UUID()
        ended.receive(.began(priorSession)); ended.receive(.ended(priorSession, reason: .failure))
        ended.begin(at: 3) { priorLoss.append($0) }; acknowledge(ended)
        XCTAssertEqual(priorLoss.failures, ["Capture cancelled: scanner input lost"], "End before begin must not wait for an already ended session")

        for cause in ["end", "switch", "geometry", "gap", "cancel"] {
            for finishFirst in [false, true] {
                let source = RecordingSource(), worker = RoomCaptureWorker(), reports = CaptureReports()
                let recorder = ProfileRecordingModel(clock: RecordingClock()), forwarded = ForwardedProfiles()
                RecordingProfileSource(source: source, recorder: recorder, roomCapture: worker).bind { forwarded.receive($0) }
                let id = UUID(); source.send(.began(id)); worker.begin(at: 3) { reports.append($0) }
                let count: UInt64 = finishFirst ? 125 : 64
                for n in 1...count { source.send(.frame(try frame(id, n))) }
                switch cause {
                case "end": source.send(.ended(id, reason: .failure))
                case "switch": source.send(.began(UUID()))
                case "geometry": source.send(.frame(try frame(id, count + 1, points: 90)))
                case "gap": source.send(.frame(try frame(id, count + 2)))
                case "cancel": worker.cancel()
                default: XCTFail("Unknown fixture")
                }
                acknowledge(worker)
                XCTAssertEqual(source.bindings, 1)
                XCTAssertEqual(reports.completed.count, finishFirst ? 1 : 0, cause)
                XCTAssertEqual(reports.failures.count, !finishFirst && cause != "cancel" ? 1 : 0, cause)
                // A new session can capture again; no previous samples leak.
                let next = UUID(); source.send(.began(next)); worker.begin(at: 3) { reports.append($0) }
                for n: UInt64 in 1...125 { source.send(.frame(try frame(next, n, distance: 300))) }
                acknowledge(worker)
                XCTAssertEqual(reports.completed.last?.nearestDistancesCentimeters, Array(repeating: UInt16(300), count: 361))
            }
        }
    }
    func testIdleFramesNeverEnqueueAndBeginKeepsGeometryBaselineInBothOrders() throws {
        for beginFirst in [false, true] {
            let worker = RoomCaptureWorker(), reports = CaptureReports(), id = UUID()
            worker.receive(.began(id))
            for n: UInt64 in 1...50 { worker.receive(.frame(try frame(id, n))) }
            acknowledge(worker)
            XCTAssertEqual(worker.queuedFrameCount, 0)
            if beginFirst {
                worker.begin(at: 3) { reports.append($0) }
                worker.receive(.frame(try frame(id, 51, points: 90)))
                acknowledge(worker)
                XCTAssertEqual(reports.failures, ["Capture cancelled: scanner geometry changed"])
                XCTAssertEqual(worker.queuedFrameCount, 1)
            } else {
                worker.receive(.frame(try frame(id, 51, points: 90)))
                worker.begin(at: 3) { reports.append($0) }
                for n: UInt64 in 52...176 { worker.receive(.frame(try frame(id, n, points: 90))) }
                acknowledge(worker)
                XCTAssertEqual(reports.completed.count, 1)
                XCTAssertEqual(reports.completed.first?.geometry.pointCount, 90)
            }
            let settled = worker.queuedFrameCount
            for n: UInt64 in 177...200 { worker.receive(.frame(try frame(id, n, points: 90))) }
            acknowledge(worker)
            XCTAssertEqual(worker.queuedFrameCount, settled, "Completion/failure closes the ingress gate")
            worker.begin(at: 3) { reports.append($0) }; worker.cancel()
            for n: UInt64 in 201...225 { worker.receive(.frame(try frame(id, n, points: 90))) }
            acknowledge(worker)
            XCTAssertEqual(worker.queuedFrameCount, settled, "Cancel closes the gate at submission")
            worker.begin(at: 3) { reports.append($0) }
            for n: UInt64 in 226...350 { worker.receive(.frame(try frame(id, n, points: 90))) }
            acknowledge(worker)
            XCTAssertEqual(reports.completed.last?.geometry.pointCount, 90, "A new begin reopens the gate")
        }
    }

    func testOldCompletionCannotDisarmAlreadyQueuedReplacementCapture() throws {
        let worker = RoomCaptureWorker(), old = CaptureReports(), replacement = CaptureReports(), id = UUID()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        worker.acknowledge { entered.signal(); release.wait() }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        worker.begin(at: 3) { old.append($0) }
        for n: UInt64 in 1...125 { worker.receive(.frame(try frame(id, n))) }
        worker.begin(at: 3) { replacement.append($0) }
        release.signal(); acknowledge(worker)
        for n: UInt64 in 126...250 { worker.receive(.frame(try frame(id, n))) }
        acknowledge(worker)
        XCTAssertEqual(old.completed.count, 1); XCTAssertEqual(replacement.completed.count, 1)
    }

    func testQueuedOldCompletionCannotFinishCancelledOrRestartedCapture() throws {
        let f = try RootFixture(clock: RecordingClock()), owner = f.root.document, id = UUID()
        defer { f.root.terminate {} }
        owner.beginRoomContourCapture()
        for n: UInt64 in 1...125 { owner.roomCapture.receive(.frame(try frame(id, n))) }
        acknowledge(owner.roomCapture) // completion queued on Main
        owner.cancelRoomContourCapture(); owner.beginRoomContourCapture()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertTrue(owner.isCapturingRoomContour); XCTAssertNil(owner.roomContour)
        XCTAssertEqual(owner.roomContourCaptureProgress, 0)
    }
}
private final class CaptureReports: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [RoomCaptureWorker.Update] = []
    func append(_ update: RoomCaptureWorker.Update) { lock.lock(); values.append(update); lock.unlock() }
    var completed: [SpatialRoomContour] {
        lock.lock(); defer { lock.unlock() }; return values.compactMap { if case .completed(let value) = $0 { return value }; return nil }
    }
    var failures: [String] {
        lock.lock(); defer { lock.unlock() }; return values.compactMap { if case .failed(let value) = $0 { return value }; return nil }
    }
}
