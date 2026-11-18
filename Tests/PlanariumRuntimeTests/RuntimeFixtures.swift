import XCTest
import Dispatch
import Foundation
import PlanariumDomain
import PlanariumRuntime
import SickPLSControlCore

// Test-only fakes guard every field with their respective lock. These are the
// external boundaries, not alternate implementations of Runtime or Router.
final class FakeClock: RuntimeClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time: Double = 10
    private var tasks: [UUID: (Double, DispatchQueue, @Sendable () -> Void)] = [:]
    var now: Double { lock.lock(); defer { lock.unlock() }; return time }
    var deadlines: [Double] { lock.lock(); defer { lock.unlock() }; return tasks.values.map { $0.0 }.sorted() }
    func schedule(at deadline: Double, on queue: DispatchQueue,
                  _ action: @escaping @Sendable () -> Void) -> RuntimeCancellation {
        let id = UUID()
        lock.lock(); tasks[id] = (deadline, queue, action); lock.unlock()
        return .init { [weak self] in self?.cancel(id) }
    }
    private func cancel(_ id: UUID) { lock.lock(); tasks[id] = nil; lock.unlock() }
    func advance(_ value: Double) {
        lock.lock()
        time = value
        let due = tasks.filter { $0.value.0 <= value }.sorted { $0.value.0 < $1.value.0 }
        for (id, _) in due { tasks[id] = nil }
        lock.unlock()
        for (_, task) in due { task.1.async(execute: task.2) }
    }
}
final class FakeBoundary: MIDISendBoundary, AUScheduleBoundary, @unchecked Sendable {
    struct Receipt: Sendable { let bytes: [UInt8]; let time: UInt64 }
    private let lock = NSLock()
    private var log: [Receipt] = []
    private var current: PortSendResult = .sent
    private var params: [(SpatialAudioUnitParameterTarget, Double)] = []
    private var sound = Set<Int>()
    private var violations = 0
    private var hook: (@Sendable ([UInt8]) -> Void)?
    var result: PortSendResult {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
    var receipts: [Receipt] { lock.lock(); defer { lock.unlock() }; return log }
    var sounding: Set<Int> { lock.lock(); defer { lock.unlock() }; return sound }
    var duplicateOns: Int { lock.lock(); defer { lock.unlock() }; return violations }
    var parameters: [(SpatialAudioUnitParameterTarget, Double)] { lock.lock(); defer { lock.unlock() }; return params }
    func setHook(_ value: (@Sendable ([UInt8]) -> Void)?) { lock.lock(); hook = value; lock.unlock() }
    func send(bytes: [UInt8]) -> PortSendResult {
        lock.lock()
        let status = current
        let callback = hook
        if status == .sent {
            log.append(.init(bytes: bytes, time: DispatchTime.now().uptimeNanoseconds))
            let ch = Int(bytes[0] & 15)
            let key = ch * 128 + Int(bytes[1])
            switch bytes[0] & 0xF0 {
            case 0x90:
                if !sound.insert(key).inserted { violations += 1 }
            case 0x80: sound.remove(key)
            case 0xB0 where bytes[1] == 123: sound = sound.filter { $0 / 128 != ch }
            default: break
            }
        }
        lock.unlock()
        callback?(bytes)
        return status
    }
    func scheduleMIDI(bytes: [UInt8]) -> PortSendResult { send(bytes: bytes) }
    func scheduleParameter(_ target: SpatialAudioUnitParameterTarget, normalizedValue: Double) -> PortSendResult {
        lock.lock(); defer { lock.unlock() }
        if current == .sent { params.append((target, normalizedValue)) }
        return current
    }
}
final class FakeProfileSource: RuntimeProfileSource {
    private var receiver: (@Sendable (ProfileSourceEvent) -> Void)?
    func bind(_ receive: @escaping @Sendable (ProfileSourceEvent) -> Void) { receiver = receive }
    func deliver(_ event: ProfileSourceEvent) { receiver?(event) }
}

class RuntimeTestCase: XCTestCase {
    let session = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
    let other = UUID(uuidString: "00000000-0000-0000-0000-000000000022")!
    let midiID = UUID(uuidString: "00000000-0000-0000-0000-000000000023")!
    let auID = UUID(uuidString: "00000000-0000-0000-0000-000000000024")!
    func compiled(_ revision: UInt64 = 1, notes: Bool = true,
                  transition: SpatialNoteTransition = .legato, layerCount: Int = 1,
                  fullArea: Bool = false, scalar: Bool = false, performanceArea: Bool = false, detection: DetectionConfiguration = .allStagesOff) throws -> CompiledInstrument {
        let rings = performanceArea ? Array(stride(from: 10, through: 200, by: 6)) + [100, 120] : (fullArea ? Array(1...200) : [100, 120])
        let cells = Set(rings.flatMap { ring in
            (fullArea || performanceArea ? Array(0...360) : [180]).compactMap { PolarDeviceLattice(ring: ring, sector: $0) }
        })
        let layers = (0..<layerCount).map { layerIndex -> SpatialDocumentLayer in
            var routes: [SpatialRouting] = notes ? [
                .init(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", layerIndex * 3 + 100))!, target: .midiNote(channel: UInt8(layerIndex % 16)), program: .scale(
                    rootMIDINote: 60, lowestMIDINote: 60, highestMIDINote: 72,
                    scale: .chromatic, directionDegrees: 90, ascending: true, transition: transition)),
                .init(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", layerIndex * 3 + 101))!, target: .audioUnitNote(channel: UInt8(layerIndex % 16), stripID: InstrumentChannel.legacyID), program: .scale(
                    rootMIDINote: 60, lowestMIDINote: 60, highestMIDINote: 72,
                    scale: .chromatic, directionDegrees: 90, ascending: true, transition: transition))
            ] : []
            if scalar { routes.append(.init(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", layerIndex * 3 + 102))!, target: .midiCC(channel: 0, controller: 74), program: .constant(0.5))) }
            return .init(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", layerIndex + 1))!, name: "Runtime layer \(layerIndex)", color: .orange, isVisible: true,
                         isActive: true, isLocked: false, isSoloed: false,
                         cells: cells, routings: routes, cellOverrides: [:])
        }
        let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: layers,
                                          selectedLayerID: layers[0].id)
        return try InstrumentCompiler.compile(.init(spatial: spatial, detection: detection,
            revision: .init(session: session, counter: revision)))
    }
    func profile(_ sequence: UInt64 = 1, session id: UUID? = nil, ring: UInt16 = 100,
                 empty: Bool = false, time: Double = 10, full: Bool = false) -> ProfileFrame {
        let measurements: [DeviceTickMeasurement] = empty ? [] : (full ? Array(0...360) : [180]).map {
            DeviceTickMeasurement(order: $0, ticks: .point($0)!,
                rawCentimeters: full && !(170...189).contains($0) ? 300 : ring)!
        }
        return .init(sessionID: id ?? session, sequence: sequence, time: time, measurements: measurements)
    }
    func composition(clock: FakeClock = FakeClock(), midi: FakeBoundary = FakeBoundary(),
                     au: FakeBoundary = FakeBoundary(), source: FakeProfileSource? = nil) -> PerformanceComposition {
        PerformanceRuntimeFactory.make(clock: clock, ports: [
            RuntimePorts.midi(id: midiID, boundary: midi), RuntimePorts.audioUnit(id: auID, boundary: au)
        ], source: source)
    }
    func flush(_ runtime: PerformanceRuntime, file: StaticString = #filePath, line: UInt = #line) {
        let done = expectation(description: "Q acknowledged asynchronously on Main")
        runtime.retire(UUID(uuidString: "00000000-0000-0000-0000-000000000000")!) {
            XCTAssertTrue(Thread.isMainThread, file: file, line: line)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
    }
    func start(_ c: PerformanceComposition, instrument: CompiledInstrument? = nil) throws {
        c.runtime.install(try instrument ?? compiled())
        c.runtime.sessionBegan(session)
        c.runtime.frame(profile())
        flush(c.runtime)
    }
}
