import XCTest
import Foundation
import PlanariumDomain
@testable import PlanariumPresets
import PlanariumRuntime

final class VortragPresetTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private var directory: URL { root.appendingPathComponent(".agent_handoff/runs/vortrag-preset") }
    private func cells(_ radii: ClosedRange<Int>, _ sectors: ClosedRange<Int>) -> Set<PolarDeviceLattice> {
        Set(radii.flatMap { r in sectors.map { PolarDeviceLattice(ring: r, sector: $0)! } })
    }
    func testGenerateLoadAndAuditionOwnerPreset() throws {
        let reading = try PresetDocumentReader.read(Data(contentsOf: root.appendingPathComponent("Sources/PlanariumPresets/Resources/Harmony 30 Mode Wheel.sickpreset.json"))).get()
        let original = InstrumentPresetV6(name: reading.name, document: try reading.replacing(FactoryPresetDocument.empty()))
        var doc = original.document
        let drum = InstrumentChannel(instrument: .init(identity: .init(componentType: 0x61756d75, componentSubType: 0x44736d70, componentManufacturer: 0x446c6479)), id: UUID(uuidString: "A0000000-0000-0000-0000-000000000003")!, name: "Drums", color: .blue)
        doc.channels.append(drum)
        let bassID = UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!
        let bassLayerID = UUID(uuidString: "A0000000-0000-0000-0000-000000000002")!
        let synth = InstrumentPlugin(identity: .init(componentType: 0x61756d75, componentSubType: 0x53675854, componentManufacturer: 0x566d6241))
        doc.channels.append(.init(instrument: synth, id: bassID, name: "Bass", color: .orange))
        var layers = doc.spatial.layers.map { l -> SpatialDocumentLayer in
            let routes: [SpatialRouting] = l.routings.map { r in
                var r = r
                if case let .chord(notes, velocity, _) = r.program { r.program = .chord(notes: notes, velocity: velocity, transition: .holdUntilNext) }
                return r
            }
            return .init(id: l.id, name: l.name, color: l.color, isVisible: l.isVisible, isActive: l.isActive,
                         isLocked: l.isLocked, isSoloed: l.isSoloed, cells: l.cells,
                         routings: routes, cellOverrides: l.cellOverrides, toggleGuardSeconds: l.toggleGuardSeconds, commonNotes: l.commonNotes, midiTarget: l.midiTarget)
        }
        let drumLayer = SpatialDocumentLayer(id: UUID(uuidString: "A0000000-0000-0000-0000-000000000004")!, name: "Drums", color: .blue, isVisible: true, isActive: true, isLocked: false, isSoloed: false, cells: cells(15...40, 30...70), routings: [.init(target: .audioUnitNote(channel: 0, stripID: drum.id), program: .singleNote(note: 36, velocity: 100, transition: .toggle))], cellOverrides: [:])
        let a = cells(15...40, 250...275), b = cells(15...40, 310...335)
        let noteTarget = SpatialRoutingTarget.audioUnitNote(channel: 0, stripID: bassID)
        let bass = SpatialDocumentLayer(id: bassLayerID, name: "Bass", color: .orange, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
            cells: a.union(b), routings: [.init(target: noteTarget, program: .singleNote(note: 36, velocity: 100, transition: .holdUntilNext)),
                .init(target: .audioUnitCC(channel: 0, controller: 74, stripID: bassID), program: .continuous(minimum: 0, maximum: 1, directionDegrees: 35, curve: .linear))],
            cellOverrides: Dictionary(uniqueKeysWithValues: b.map { ($0, [.init(target: noteTarget, value: .note(number: 31, velocity: 100))]) }))
        for added in [drumLayer, bass] {
            for old in original.document.spatial.layers { XCTAssertTrue(added.cells.isDisjoint(with: old.cells), "Overlap \(old.name)") }
            XCTAssertTrue(added.cells.allSatisfy { $0.ring <= 200 })
        }
        XCTAssertTrue(drumLayer.cells.isDisjoint(with: bass.cells))
        layers.append(contentsOf: [drumLayer, bass])
        doc.spatial = try .init(latticeVersion: .polarDeviceV2, layers: layers, selectedLayerID: bass.id)
        for i in doc.scenes.indices { doc.scenes[i].activeLayerIDs.formUnion([drumLayer.id, bass.id]) }
        let preset = InstrumentPresetV6(name: "Harmony 30 Vortrag", document: doc, viewport: PresetViewport(try .build(centerXMeters: 0, centerYMeters: 0.9, metersPerPoint: 0.003)), summary: "Owner-Vortrag: Akkorde Hold till next trigger; Drums Toggle C2; Bass C2/G1 mit CC 74. Im Synth CC 74 dem Filter zuweisen.")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("Harmony 30 Vortrag.sickpreset.json")
        let encoded = try PresetV6Codec.encode(preset)
        try encoded.write(to: output)
        let delivery = root.appendingPathComponent("runs/vortrag-preset")
        try FileManager.default.createDirectory(at: delivery, withIntermediateDirectories: true)
        let deliveryFile = delivery.appendingPathComponent(output.lastPathComponent)
        try encoded.write(to: deliveryFile)
        XCTAssertEqual(try Data(contentsOf: deliveryFile), encoded)
        let loaded = try PresetDocumentReader.read(Data(contentsOf: deliveryFile)).get().replacing(FactoryPresetDocument.empty())
        XCTAssertEqual(loaded.channels.count, original.document.channels.count + 2)
        XCTAssertEqual(loaded.spatial.layers.count, original.document.spatial.layers.count + 2)
        XCTAssertEqual(Array(loaded.channels.prefix(original.document.channels.count)), original.document.channels)
        for (before, after) in zip(original.document.spatial.layers, loaded.spatial.layers) {
            XCTAssertEqual(before.cells, after.cells)
            XCTAssertEqual(before.name, after.name)
            XCTAssertEqual(before.id, after.id)
            XCTAssertEqual(before.routings.map(\.target), after.routings.map(\.target))
        }
        for (before, after) in zip(original.document.scenes, loaded.scenes) {
            XCTAssertEqual(before.id, after.id); XCTAssertEqual(before.name, after.name)
            XCTAssertEqual(after.activeLayerIDs.subtracting([drumLayer.id, bass.id]), before.activeLayerIDs)
        }
        XCTAssertEqual(loaded.channels, doc.channels)
        XCTAssertEqual(loaded.spatial, doc.spatial)
        XCTAssertEqual(loaded.scenes, doc.scenes)
        XCTAssertEqual(loaded.channels.first?.instrument, original.document.channels.first?.instrument)
        for l in loaded.spatial.layers { for r in l.routings { if case let .chord(_, _, transition) = r.program { XCTAssertEqual(transition, .holdUntilNext) } } }
        for scene in loaded.scenes {
            XCTAssertTrue(scene.activeLayerIDs.isSuperset(of: [drumLayer.id, bass.id]))
            var sceneDoc = loaded; sceneDoc.currentSceneID = scene.id
            let drumSink = VortragSink(), bassSink = VortragSink()
            let clock = VortragClock()
            let runtime = PerformanceRuntime(clock: clock, mailbox: DisplayFrameMailbox())
            runtime.attach(RuntimePorts.audioUnit(stripID: drum.id, boundary: drumSink))
            runtime.attach(RuntimePorts.audioUnit(stripID: bassID, boundary: bassSink))
            runtime.install(try InstrumentCompiler.compile(sceneDoc)); flush(runtime)
            func audition(_ r: Double?, _ sector: Double = 50) {
                clock.advance()
                let angle = (sector / 2 - 90) * Double.pi / 180
                runtime.audition(r.map { .init(xMeters: sin(angle) * $0 / 100, yMeters: cos(angle) * $0 / 100) }); flush(runtime)
            }
            audition(25); XCTAssertEqual(drumSink.notes, [36])
            audition(nil); XCTAssertEqual(drumSink.notes, [36])
            audition(25); XCTAssertTrue(drumSink.notes.isEmpty)
            audition(nil); audition(18, 270); XCTAssertEqual(bassSink.notes, [36])
            let low = bassSink.cc.last
            audition(37, 270); XCTAssertNotEqual(low, bassSink.cc.last)
            audition(nil); XCTAssertEqual(bassSink.notes, [36])
            audition(18, 320); XCTAssertEqual(bassSink.notes, [31])
            let fifthLow = bassSink.cc.last
            audition(37, 320); XCTAssertNotEqual(fifthLow, bassSink.cc.last)
            audition(nil); audition(25); XCTAssertEqual(drumSink.notes, [36])
            runtime.panic(); flush(runtime)
            XCTAssertTrue(drumSink.notes.isEmpty); XCTAssertTrue(bassSink.notes.isEmpty)
            audition(nil); audition(25, 270)
            XCTAssertEqual(bassSink.notes, [36])
            audition(nil); audition(25); XCTAssertEqual(drumSink.notes, [36])
            runtime.stop(); flush(runtime)
            XCTAssertTrue(drumSink.notes.isEmpty); XCTAssertTrue(bassSink.notes.isEmpty)
        }
    }
    private func flush(_ runtime: PerformanceRuntime) {
        let done = expectation(description: "Q acknowledged")
        runtime.retire(UUID()) { done.fulfill() }
        wait(for: [done], timeout: 10)
    }
}
private final class VortragSink: AUScheduleBoundary, @unchecked Sendable {
    private let lock = NSLock()
    private var sounding: Set<Int> = []
    private var controls: [UInt8] = []
    var notes: Set<Int> { lock.lock(); defer { lock.unlock() }; return sounding }
    var cc: [UInt8] { lock.lock(); defer { lock.unlock() }; return controls }
    func scheduleMIDI(bytes: [UInt8]) -> PortSendResult {
        lock.lock(); defer { lock.unlock() }
        switch bytes[0] & 0xf0 {
        case 0x90: sounding.insert(Int(bytes[1]))
        case 0x80: sounding.remove(Int(bytes[1]))
        case 0xb0 where bytes[1] == 123: sounding.removeAll()
        case 0xb0 where bytes[1] == 74: controls.append(bytes[2])
        default: break
        }
        return .sent
    }
    func scheduleParameter(_ target: SpatialAudioUnitParameterTarget, normalizedValue: Double) -> PortSendResult { .sent }
}

private final class VortragClock: RuntimeClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time = 10.0
    var now: Double { lock.lock(); defer { lock.unlock() }; return time }
    func advance() { lock.lock(); time += 1; lock.unlock() }
    func schedule(at deadline: Double, on queue: DispatchQueue, _ action: @escaping @Sendable () -> Void) -> RuntimeCancellation { .init {} }
}
