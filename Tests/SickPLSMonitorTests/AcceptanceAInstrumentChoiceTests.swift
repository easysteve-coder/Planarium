import XCTest
import AVFoundation
import PlanariumAudio
import PlanariumDomain
import PlanariumRuntime
@testable import SickPLSMonitor

@MainActor final class AcceptanceAInstrumentChoiceTests: XCTestCase {
    func testStopCancelsPendingChoiceAndObsoleteLoadCannotStart() async throws {
        let source = ChoiceComponents(), graph = MonitorGraph(); graph.permitsStart = true
        let f = try MonitorRootFixture(components: source, graph: graph)
        let a = SpatialAudioUnitIdentity(componentType: 0x61756d75, componentSubType: 1, componentManufacturer: 2)
        let b = SpatialAudioUnitIdentity(componentType: 0x61756d75, componentSubType: 3, componentManufacturer: 2)
        f.root.document.selectInstrument(a)
        let obsolete = source.completion
        f.root.document.selectInstrument(b)
        obsolete?(.success(ChoiceUnit()))
        XCTAssertEqual(graph.starts, 0); XCTAssertNil(f.root.audio.instrument)
        f.root.audio.stop()
        source.completion?(.success(ChoiceUnit()))
        XCTAssertEqual(f.root.audio.status[.instrument], .loaded)
        XCTAssertFalse(f.root.audio.isRunning); XCTAssertEqual(graph.starts, 0)
        await withCheckedContinuation { continuation in f.root.terminate { continuation.resume() } }
    }
    func testSynchronousSuccessfulChoiceAlsoStartsAfterLoading() async throws {
        let source = ChoiceComponents(); source.immediate = true
        let graph = MonitorGraph(); graph.permitsStart = true
        let f = try MonitorRootFixture(components: source, graph: graph)
        f.root.document.selectInstrument(.init(componentType: 0x61756d75, componentSubType: 1, componentManufacturer: 2))
        XCTAssertEqual(graph.starts, 1); XCTAssertTrue(f.root.audio.isRunning)
        await withCheckedContinuation { continuation in f.root.terminate { continuation.resume() } }
    }
    func testDocumentChoiceStartsOnlyAfterSuccessfulLoadAndFailureStaysFailed() async throws {
        for fails in [false, true] {
            let source = ChoiceComponents(), graph = MonitorGraph(); graph.permitsStart = true
            let f = try MonitorRootFixture(components: source, graph: graph)
            let identity = SpatialAudioUnitIdentity(componentType: 0x61756d75, componentSubType: 1, componentManufacturer: 2)
            f.root.document.selectInstrument(identity)
            XCTAssertEqual(f.root.document.document.channel.instrument?.identity, identity)
            XCTAssertEqual(f.root.audio.status[.instrument], .loading)
            XCTAssertEqual(graph.starts, 0)
            source.completion?(fails ? .failure(.init("Synthetic choice failure")) : .success(ChoiceUnit()))
            if fails {
                XCTAssertEqual(graph.starts, 0)
                XCTAssertEqual(f.root.audio.status[.instrument], .failed("Synthetic choice failure"))
            } else {
                XCTAssertEqual(graph.starts, 1)
                XCTAssertTrue(f.root.audio.isRunning)
                XCTAssertEqual(f.root.audio.status[.instrument], .loaded)
            }
            await withCheckedContinuation { continuation in f.root.terminate { continuation.resume() } }
        }
    }
}
@MainActor private final class ChoiceComponents: PluginComponentSource {
    var immediate = false
    var completion: (@MainActor @Sendable (Result<any PluginUnit, PluginLoadError>) -> Void)?
    func load(_ identity: SpatialAudioUnitIdentity, completion: @escaping @MainActor @Sendable (Result<any PluginUnit, PluginLoadError>) -> Void) {
        self.completion = completion
        if immediate { completion(.success(ChoiceUnit())) }
    }
}
@MainActor private final class ChoiceUnit: PluginUnit {
    var audioNode: AVAudioUnit? { nil }
    func readState() throws -> Data { Data() }
    func setState(_ state: Data) throws {}
    func setBypass(_ bypassed: Bool) {}
    func scheduleBoundary(identity: SpatialAudioUnitIdentity) -> any AUScheduleBoundary { ChoiceSchedule() }
    func requestEditor(_ completion: @escaping @MainActor @Sendable (any PluginEditor) -> Void) { XCTFail("No real editor") }
}
private struct ChoiceSchedule: AUScheduleBoundary {
    func scheduleMIDI(bytes: [UInt8]) -> PortSendResult { .sent }
    func scheduleParameter(_ target: SpatialAudioUnitParameterTarget, normalizedValue: Double) -> PortSendResult { .sent }
}
