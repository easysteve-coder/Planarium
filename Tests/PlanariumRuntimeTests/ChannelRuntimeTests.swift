import XCTest
import PlanariumDomain
import PlanariumRuntime

final class ChannelRuntimeTests: RuntimeTestCase {
    private let secondStrip = UUID(uuidString: "00000000-0000-0000-0000-000000000031")!
    func testAUControlsUseSelectedStripSharedEncodingAndFrameOrder() throws {
        let clock = FakeClock(), runtime = PerformanceRuntime(clock: clock, mailbox: .init())
        let first = FakeBoundary(), second = FakeBoundary(), midi = FakeBoundary()
        second.setHook { _ in XCTAssertFalse(Thread.isMainThread, "AU scheduling must stay on Q") }
        runtime.attach(RuntimePorts.audioUnit(stripID: InstrumentChannel.legacyID, boundary: first))
        runtime.attach(RuntimePorts.audioUnit(stripID: secondStrip, boundary: second))
        runtime.attach(RuntimePorts.midi(boundary: midi))
        let targets: [(SpatialRoutingTarget, SpatialValueProgram)] = [
            (.audioUnitNote(channel: 5, stripID: secondStrip), .singleNote(note: 60, velocity: 99, transition: .legato)),
            (.audioUnitCC(channel: 5, controller: 11, stripID: secondStrip), .constant(1)),
            (.audioUnitPitchBend(channel: 5, stripID: secondStrip), .constant(0.5)),
            (.audioUnitChannelPressure(channel: 5, stripID: secondStrip), .constant(0.25)),
            (.audioUnitProgramChange(channel: 5, stripID: secondStrip), .programChange(.init(program: 2, countsFromOne: false, bankMSB: 7, bankLSB: 9)))
        ]
        let layer = SpatialDocumentLayer(id: session, name: "Controls", color: .blue, isVisible: true,
            isActive: true, isLocked: false, isSoloed: false, cells: [PolarDeviceLattice(ring: 100, sector: 180)!],
            routings: targets.map { .init(target: $0.0, program: $0.1) }, cellOverrides: [:])
        let document = InstrumentDocument(spatial: try .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: session),
            detection: .allStagesOff, revision: .init(session: session, counter: 1), channels: [.init(), .init(id: secondStrip)])
        runtime.install(try InstrumentCompiler.compile(document)); runtime.sessionBegan(session)
        runtime.frame(profile()); flush(runtime)
        XCTAssertTrue(first.receipts.isEmpty); XCTAssertTrue(midi.receipts.isEmpty)
        let messages = second.receipts.map(\.bytes)
        XCTAssertEqual(messages, [[0x95, 60, 99], [0xB5, 11, 127], [0xE5, 0, 64], [0xD5, 32],
            [0xB5, 0, 7], [0xB5, 32, 9], [0xC5, 2]])
        XCTAssertTrue(zip(second.receipts, second.receipts.dropFirst()).allSatisfy { $0.time <= $1.time })
        let display = try XCTUnwrap(runtime.mailbox.read()?.ports.first { $0.destination.stripID == secondStrip })
        XCTAssertEqual(display.sentCC, 3); XCTAssertEqual(display.sentPC, 1)
        runtime.frame(profile(2)); flush(runtime)
        XCTAssertEqual(second.receipts.filter { $0.bytes.first == 0xC5 }.count, 1)
        runtime.terminate(ack: {}); flush(runtime)
    }

    func testAUAndMIDISustainAndBendReleaseMatrixAndRetry() throws {
        for au in [true, false] { for branch in 0..<13 {
            let clock = FakeClock(), runtime = PerformanceRuntime(clock: clock, mailbox: .init()), sink = FakeBoundary()
            let portID = UUID()
            runtime.attach(au ? RuntimePorts.audioUnit(id: portID, stripID: secondStrip, boundary: sink)
                : RuntimePorts.midi(id: portID, boundary: sink))
            let targets: [SpatialRoutingTarget] = au
                ? [.audioUnitCC(channel: 15, controller: 64, stripID: secondStrip), .audioUnitPitchBend(channel: 15, stripID: secondStrip)]
                : [.midiCC(channel: 15, controller: 64), .midiPitchBend(channel: 15)]
            let layer = SpatialDocumentLayer(id: session, name: "Pedal and bend", color: .blue, isVisible: true,
                isActive: true, isLocked: false, isSoloed: false, cells: [PolarDeviceLattice(ring: 100, sector: 180)!],
                routings: targets.map { .init(target: $0, program: .constant(1)) }, cellOverrides: [:])
            var document = InstrumentDocument(spatial: try .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: session),
                detection: .allStagesOff, revision: .init(session: session, counter: 1), channels: [.init(), .init(id: secondStrip)])
            runtime.install(try InstrumentCompiler.compile(document)); runtime.sessionBegan(session)
            runtime.frame(profile()); flush(runtime)
            XCTAssertEqual(sink.receipts.map(\.bytes), [[0xBF, 64, 127], [0xEF, 127, 127]])
            switch branch {
            case 0: runtime.panic()
            case 1: runtime.stop()
            case 2: runtime.sleep()
            case 3: runtime.wake()
            case 4: runtime.terminate(ack: {})
            case 5: runtime.sessionEnded(session)
            case 6: runtime.sessionEnded(session, reason: .failure)
            case 7: runtime.sessionBegan(other)
            case 8: runtime.retire(portID) {}
            case 9:
                let nextLayer = SpatialDocumentLayer(id: session, name: "Changed", color: .blue, isVisible: true, isActive: true, isLocked: false, isSoloed: false, cells: layer.cells, routings: [], cellOverrides: [:])
                document.spatial = try .init(latticeVersion: .polarDeviceV2, layers: [nextLayer], selectedLayerID: session)
                document.revision = try document.revision.advanced()
                runtime.install(try InstrumentCompiler.compile(document))
            case 10: runtime.releaseAudioForConfigurationChange()
            case 12: clock.advance(20); flush(runtime)
            case 11:
                sink.result = .faulted; runtime.panic(); flush(runtime)
                sink.result = .sent; runtime.panic()
            default: XCTFail("Uncovered release path")
            }
            flush(runtime)
            let resets = Array(sink.receipts.map(\.bytes).dropFirst(2))
            if branch == 10 && !au { XCTAssertTrue(resets.isEmpty) }
            else {
                XCTAssertTrue(resets.contains([0xBF, 64, 0]), "sustain \(au) / \(branch)")
                XCTAssertTrue(resets.contains([0xEF, 0, 64]), "bend \(au) / \(branch)")
            }
            runtime.terminate(ack: {}); flush(runtime)
        } }
    }

    func testProgramDisplayOriginDoesNotAlterWireByteAndAUFailurePreventsProgram() {
        for origin in [true, false] {
            let selection = SpatialProgramChange(program: 2, countsFromOne: origin, bankMSB: 3, bankLSB: 4)
            XCTAssertEqual(selection.displayedProgram, origin ? 3 : 2)
            XCTAssertEqual(MusicEventMIDIEncoding.programMessages(channel: 15, selection: selection),
                [[0xBF, 0, 3], [0xBF, 32, 4], [0xCF, 2]])
        }
        let sink = FakeBoundary(); sink.result = .faulted
        var port = RuntimePorts.audioUnit(stripID: secondStrip, boundary: sink)
        XCTAssertEqual(port.send(.programChange(destination: .audioUnit(stripID: secondStrip), channel: 0,
            selection: .init(program: 2, bankMSB: 3, bankLSB: 4))), .faulted)
        XCTAssertTrue(sink.receipts.isEmpty)
        sink.result = .sent
        XCTAssertEqual(port.send(.programChange(destination: .audioUnit(stripID: secondStrip), channel: 0,
            selection: .init(program: 2, bankMSB: 3, bankLSB: 4))), .sent)
        XCTAssertEqual(sink.receipts.map(\.bytes), [[0xB0, 0, 3], [0xB0, 32, 4], [0xC0, 2]])
    }

    func testPanicCoversAllBoundPortsWithoutDocumentAndAfterStripRemovalWhenOffFails() throws {
        for installed in [false, true] {
            let runtime = PerformanceRuntime(clock: FakeClock(), mailbox: DisplayFrameMailbox())
            let ports = [InstrumentChannel.legacyID, secondStrip].map { strip in
                OutputPort(destination: .audioUnit(stripID: strip)) { event in
                    if case .noteOff = event { return .faulted }
                    return .sent
                }
            }
            for port in ports { runtime.attach(port) }
            if installed {
                let cell = PolarDeviceLattice(ring: 100, sector: 180)!
                let layer = SpatialDocumentLayer(id: session, name: "Both", color: .blue, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                    cells: [cell], routings: [InstrumentChannel.legacyID, secondStrip].map { .init(target: .audioUnitNote(channel: 15, stripID: $0), program: .chord(notes: [60], velocity: 100, transition: .toggle)) }, cellOverrides: [:])
                var doc = InstrumentDocument(spatial: try .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: session), detection: .allStagesOff, revision: .init(session: session, counter: 1), channels: [.init(), .init(id: secondStrip)])
                runtime.install(try InstrumentCompiler.compile(doc)); runtime.sessionBegan(session)
                runtime.frame(profile()); flush(runtime)
                XCTAssertEqual(runtime.mailbox.read()?.ports.map(\.soundingNotes), [1, 1])
                doc.channels.removeLast(); doc.revision = try doc.revision.advanced()
                runtime.install(try InstrumentCompiler.compile(doc)); flush(runtime)
                XCTAssertEqual(runtime.mailbox.read()?.ports.last?.soundingNotes, 1)
            }
            runtime.panic(); flush(runtime)
            XCTAssertEqual(runtime.mailbox.read()?.ports.map(\.soundingNotes), [0, 0])
            for port in runtime.mailbox.read()?.ports ?? [] { XCTAssertGreaterThanOrEqual(port.counts.sent, 16) }
            runtime.terminate(ack: {}); flush(runtime)
        }
    }
    func testBothStripsReleaseMatrixAndUnintentionalLossAt90And361() throws {
        for count in [90, 361] { for path in 0..<10 {
            let first = FakeBoundary(), second = FakeBoundary(), clock = FakeClock(), runtime = PerformanceRuntime(clock: clock, mailbox: DisplayFrameMailbox())
            runtime.attach(RuntimePorts.audioUnit(id: auID, stripID: InstrumentChannel.legacyID, boundary: first))
            runtime.attach(RuntimePorts.audioUnit(id: other, stripID: secondStrip, boundary: second))
            let cell = PolarDeviceLattice(ring: 100, sector: 180)!
            let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [
                .init(id: session, name: "Pads and lead", color: .blue, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                    cells: [cell], routings: [
                        .init(target: .audioUnitNote(channel: 0, stripID: InstrumentChannel.legacyID), program: .chord(notes: [60, 64, 67], velocity: 100, transition: .holdUntilNext)),
                        .init(target: .audioUnitNote(channel: 0, stripID: secondStrip), program: .chord(notes: [76], velocity: 100, transition: .toggle))], cellOverrides: [:])], selectedLayerID: session)
            var document = InstrumentDocument(spatial: spatial, detection: .allStagesOff, revision: .init(session: session, counter: 1), channels: [.init(), .init(id: secondStrip)])
            runtime.install(try InstrumentCompiler.compile(document)); runtime.sessionBegan(session)
            let geometry = ProfileGeometryIdentity(operatingMode: count == 90 ? "MMK" : "fullScan", pointCount: count, startAngleDegrees: -90, endAngleDegrees: 90)
            runtime.frame(.init(sessionID: session, sequence: 1, time: 10,
                measurements: (0..<count).map { DeviceTickMeasurement(order: $0, ticks: geometry.tickSpan(at: $0)!, rawCentimeters: $0 == count / 2 ? 100 : 500)! }, geometry: geometry))
            flush(runtime)
            XCTAssertEqual(first.sounding.count, 3); XCTAssertEqual(second.sounding.count, 1)
            switch path {
            case 0: clock.advance(20)
            case 1: runtime.sessionEnded(session, reason: .failure)
            case 2: runtime.panic()
            case 3: runtime.stop()
            case 4: runtime.sleep()
            case 5: runtime.wake()
            case 6: runtime.terminate(ack: {})
            case 7: runtime.sessionEnded(session)
            case 8: runtime.sessionBegan(UUID())
            case 9:
                document.channels.removeLast(); document.revision = try document.revision.advanced()
                runtime.install(try InstrumentCompiler.compile(document))
            default: XCTFail("Uncovered path")
            }
            flush(runtime)
            XCTAssertEqual(first.sounding.count, path < 2 || path == 9 ? 3 : 0, "Pads path \(path), \(count)")
            XCTAssertEqual(second.sounding.count, path < 2 ? 1 : 0, "Lead path \(path), \(count)")
            runtime.stop(); flush(runtime)
        } }
    }
    func testRemovingOneStripReleasesItsPhysicalNotesBeforeRemovalAndKeepsSibling() {
        let first = FakeBoundary(), second = FakeBoundary()
        var router = OutputRouter()
        router.attach(RuntimePorts.audioUnit(id: auID, stripID: InstrumentChannel.legacyID, boundary: first))
        router.attach(RuntimePorts.audioUnit(id: other, stripID: secondStrip, boundary: second))
        let notes: [MusicEvent] = [
            .noteOn(destination: .audioUnit(stripID: InstrumentChannel.legacyID), channel: 0, note: .init(number: 60, velocity: 100)),
            .noteOn(destination: .audioUnit(stripID: secondStrip), channel: 0, note: .init(number: 60, velocity: 100))]
        router.route(notes, sounding: notes, allowOn: true)
        XCTAssertEqual(router.retire(other)?.soundingNotes, 0)
        XCTAssertTrue(second.sounding.isEmpty)
        XCTAssertEqual(second.receipts.last?.bytes, [0x80, 60, 0])
        XCTAssertEqual(first.sounding.count, 1)
        XCTAssertEqual(router.display.map(\.soundingNotes), [1])
        _ = router.retire(auID)
    }
}
