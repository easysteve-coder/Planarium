import Foundation
import PlanariumDomain
import PlanariumRuntime
import SickPLSMonitorKit

/// The existing input binding must deliver profiles losslessly, before any
/// coalescing: acquisition rejects sequence gaps. The lock orders submissions
/// and protects the armed flag plus the latest ingress baseline; only queue
/// touches acquisition state. Idle frames never enqueue work. Main receives
/// integer percentages and the final reduction, never raw profiles.
final class RoomCaptureWorker: @unchecked Sendable {
    enum Update: Sendable { case progress(Int), completed(SpatialRoomContour), failed(String) }
    private let lock = NSLock()
    private var armed = false
    private var ingressLast: ProfileFrame?
    private var generation: UInt64 = 0
    private var captureGeneration: UInt64 = 0 // queue only
    private var frameSubmissions = 0
    internal var queuedFrameCount: Int {
        lock.lock(); defer { lock.unlock() }; return frameSubmissions
    }
    private let queue = DispatchQueue(label: "de.planarium.room-capture", qos: .userInitiated)
    private let recorder = SpatialRoomContourRecorder()
    private var inputEnded = false
    private var session: UUID?
    private var expectedSession: UUID?
    private var last: ProfileFrame?
    private var geometry: ProfileGeometryIdentity?
    private var deadline = 0.0
    private var count = 0
    private var percent = 0
    private var report: (@Sendable (Update) -> Void)?

    func begin(at deadline: Double, report: @escaping @Sendable (Update) -> Void) {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1; armed = true
        let current = generation, baseline = ingressLast
        queue.async { [self] in
            captureGeneration = current
            if let baseline { session = baseline.sessionID; inputEnded = false }
            last = baseline
            recorder.cancel(); self.deadline = deadline; count = 0; percent = 0
            expectedSession = session; geometry = last?.geometry; self.report = report
            if inputEnded { fail("scanner input lost") }
        }
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        armed = false; generation &+= 1
        queue.async { [self] in report = nil; recorder.cancel() }
    }
    func acknowledge(_ completion: @escaping @Sendable () -> Void) {
        lock.lock(); defer { lock.unlock() }
        queue.async(execute: completion)
    }
    func receive(_ event: ProfileSourceEvent) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .frame(let value):
            if ingressLast?.sessionID != value.sessionID || (ingressLast?.sequence ?? 0) < value.sequence {
                ingressLast = value
            }
            guard armed else { return }
            frameSubmissions += 1
        case .began(let id):
            if ingressLast?.sessionID != id { ingressLast = nil }
        case .ended(let id, _):
            if ingressLast == nil || ingressLast?.sessionID == id { ingressLast = nil }
        }
        queue.async { [self] in
            switch event {
            case .began(let id):
                if report != nil, let expectedSession, expectedSession != id { fail("scanner session changed") }
                if session != id { last = nil }
                session = id; inputEnded = false
                if report != nil { expectedSession = id }
            case .ended(let id, _):
                if report != nil, expectedSession == nil || expectedSession == id { fail("scanner input lost") }
                if session == nil || session == id { session = nil; last = nil; inputEnded = true }
            case .frame(let value):
                let previous = last
                last = value
                session = value.sessionID; inputEnded = false
                guard report != nil else { return }
                if let expectedSession, expectedSession != value.sessionID { fail("scanner session changed"); return }
                expectedSession = value.sessionID
                guard let raw = value.rawProfile,
                      (try? FullScanProfileAdapter.geometry(from: raw)) == value.geometry else {
                    fail("invalid scanner geometry"); return
                }
                if let geometry, geometry != value.geometry { fail("scanner geometry changed"); return }
                geometry = value.geometry
                if let previous, previous.sessionID == value.sessionID, previous.sequence >= value.sequence {
                    last = previous; return
                }
                guard value.time.isFinite, value.time >= deadline else { return }
                if count > 0, let previous, value.sequence != previous.sequence + 1 {
                    fail("scanner profiles missing"); return
                }
                if count == 0 { recorder.begin(sourceIdentifier: value.sourceIdentifier, targetProfileCount: 125) }
                recorder.append(raw); count += 1
                if count == 125 {
                    guard let contour = recorder.finish(), contour.nearestDistancesCentimeters.contains(where: { $0 != nil }) else {
                        fail("no usable wall measurements"); return
                    }
                    report?(.completed(contour)); report = nil; disarm()
                } else {
                    let next = count * 100 / 125
                    if next > percent || count == 1 { percent = next; report?(.progress(next)) }
                }
            }
        }
    }
    private func disarm() {
        lock.lock(); defer { lock.unlock() }
        // An older completion must not disarm a newly submitted begin.
        if generation == captureGeneration { armed = false }
    }
    private func fail(_ reason: String) {
        report?(.failed("Capture cancelled: " + reason)); report = nil; recorder.cancel(); disarm()
    }
}
