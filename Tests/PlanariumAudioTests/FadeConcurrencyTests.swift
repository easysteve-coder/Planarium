import AVFoundation
import Foundation
import PlanariumFadeDSP
import XCTest

/// Sole worker owns PCM/render fields; sole test thread publishes commands.
/// Both retain this allocation until the worker acknowledges completion.
private final class ConcurrentFadeStorage: @unchecked Sendable {
    let state: OpaquePointer
    let buffer: AVAudioPCMBuffer
    init() throws {
        state = try XCTUnwrap(planarium_fade_create())
        buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!, frameCapacity: 64))
        buffer.frameLength = 64
    }
    deinit { planarium_fade_destroy(state) }
    func render() {
        let data = buffer.floatChannelData!
        let buffers = buffer.mutableAudioBufferList
        for _ in 0..<20_000 {
            for i in 0..<64 { data[0][i] = 0.25; data[1][i] = 0.25 }
            planarium_fade_render(state, buffers, 64)
        }
    }
}
final class FadeConcurrencyTests: XCTestCase {
    func testAtomicCommandsAndRenderAcknowledgementsAcrossThreads() throws {
        let storage = try ConcurrentFadeStorage()
        XCTAssertEqual(planarium_fade_lock_free(storage.state), 1)
        let started = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        DispatchQueue(label: "fade-test-render").async {
            started.signal(); storage.render(); done.signal()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        for i in 0..<20_000 {
            let token = planarium_fade_request(storage.state, i % 2 == 0 ? 1 : 0)
            _ = planarium_fade_reached(storage.state, token)
        }
        guard done.wait(timeout: .now() + 10) == .success else {
            XCTFail("Render worker did not stop; do not touch its render fields"); return
        }
        // Worker has stopped: the test thread may now own render fields.
        let final = planarium_fade_request(storage.state, 1)
        for _ in 0..<8 { planarium_fade_render(storage.state, storage.buffer.mutableAudioBufferList, 64) }
        XCTAssertEqual(planarium_fade_reached(storage.state, final), 1)
        XCTAssertEqual(storage.buffer.floatChannelData![0][63], 0)
        XCTAssertEqual(storage.buffer.floatChannelData![1][63], 0)
    }
}
