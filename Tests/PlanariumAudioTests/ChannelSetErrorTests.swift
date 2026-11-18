import XCTest
import PlanariumMusicCore
@testable import PlanariumAudio

/// The host's own second barrier for channel sets (documents are validated by
/// their compiler first). Since 18.11.2026 it reports `ChannelSetError`, a sound
/// core type, instead of the scanner compiler's error.
@MainActor final class ChannelSetErrorTests: XCTestCase {
    func testTooManyChannelsIsRejectedBeforeAnyGraphChange() throws {
        let harness = try Harness()
        defer { harness.finish() }
        let channels = (0...InstrumentChannel.maximumCount).map { InstrumentChannel(id: UUID(), name: "Ch \($0)") }
        let before = harness.trace.events
        XCTAssertThrowsError(try harness.host.applyMixer(channels, masterLevelDecibels: 0)) {
            XCTAssertEqual($0 as? ChannelSetError, .tooManyChannels(InstrumentChannel.maximumCount + 1))
        }
        XCTAssertEqual(harness.trace.events, before, "a rejected set touches nothing")
    }

    func testDuplicateChannelIDIsRejected() throws {
        let harness = try Harness()
        defer { harness.finish() }
        let id = UUID()
        XCTAssertThrowsError(try harness.host.applyMixer([.init(id: id, name: "A"), .init(id: id, name: "B")], masterLevelDecibels: 0)) {
            XCTAssertEqual($0 as? ChannelSetError, .duplicateChannelID)
        }
    }
}
