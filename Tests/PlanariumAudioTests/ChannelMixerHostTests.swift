import XCTest
import PlanariumDomain
@testable import PlanariumAudio

@MainActor final class ChannelMixerHostTests: XCTestCase {
    private func plugin() -> InstrumentPlugin {
        .init(identity: .init(componentType: 0x61756D75, componentSubType: 1, componentManufacturer: 2), state: Data([7]))
    }
    func testSeparateInstancesSchedulesSoloAndSnapshotPreserveEachStrip() throws {
        let h = try Harness()
        let second = UUID()
        var channels = [InstrumentChannel(instrument: plugin()), InstrumentChannel(instrument: plugin(), id: second, name: "Lead")]
        try h.host.applyMixer(channels, masterLevelDecibels: -3)
        h.components.succeed(0, h.unit()); h.components.succeed(1, h.unit())
        let firstInstance = try XCTUnwrap(h.host.instrument)
        let child = try XCTUnwrap(h.host.host(for: second)), secondInstance = try XCTUnwrap(child.instrument)
        XCTAssertFalse(firstInstance === secondInstance)
        XCTAssertEqual(h.runtime.stripIDs[firstInstance.id], InstrumentChannel.legacyID)
        XCTAssertEqual(h.runtime.stripIDs[secondInstance.id], second)
        channels[1].soloed = true
        try h.host.applyMixer(channels, masterLevelDecibels: -6)
        XCTAssertTrue(h.graph.muted); XCTAssertFalse(h.graph.branches[0].muted)
        XCTAssertFalse(try h.host.snapshotMixer()[0].muted, "Solo gating must not overwrite authored mute")
        channels[1].muted = true
        try h.host.applyMixer(channels, masterLevelDecibels: 0)
        XCTAssertTrue(h.graph.branches[0].muted)
        // Reordering changes no instance, schedule or ownership.
        try h.host.applyMixer(channels.reversed(), masterLevelDecibels: 0)
        XCTAssertTrue(h.host.instrument === firstInstance); XCTAssertTrue(child.instrument === secondInstance)
        XCTAssertEqual(h.components.requests.count, 2)
        var done = false; h.host.shutdown { done = true }
        XCTAssertFalse(done)
        for index in h.runtime.acknowledgements.indices { h.runtime.ack(index) }
        XCTAssertTrue(done); XCTAssertNil(firstInstance.unit); XCTAssertNil(secondInstance.unit)
    }
    func testRemovalRetiresBeforeFadeAndGraphReleaseInBothAckOrders() async throws {
        for childFirst in [false, true] {
            let h = try Harness(), second = UUID()
            let channels = [InstrumentChannel(instrument: plugin()), InstrumentChannel(instrument: plugin(), id: second)]
            try h.host.applyMixer(channels, masterLevelDecibels: 0)
            h.components.succeed(0, h.unit()); h.components.succeed(1, h.unit())
            try h.host.start()
            let rootInstance = try XCTUnwrap(h.host.instrument)
            let child = try XCTUnwrap(h.host.host(for: second)), instance = try XCTUnwrap(child.instrument)
            try h.host.applyMixer([channels[0]], masterLevelDecibels: 0)
            XCTAssertNil(h.host.host(for: second)); XCTAssertNotNil(instance.unit)
            XCTAssertEqual(h.runtime.retirements, [instance.id])
            var done = false; h.host.shutdown { done = true }
            XCTAssertFalse(done)
            for index in childFirst ? [0, 1] : [1, 0] { h.runtime.ack(index) }
            XCTAssertNotNil(instance.unit); XCTAssertNotNil(rootInstance.unit)
            h.graph.reportFadeReached(); h.graph.branches[0].reportFadeReached()
            let deadline = Date().addingTimeInterval(1)
            while !done && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertTrue(done); XCTAssertNil(instance.unit); XCTAssertNil(rootInstance.unit)
        }
    }
    func testLateLoadCannotResurrectRemovedStrip() throws {
        let h = try Harness(), second = UUID()
        try h.host.applyMixer([.init(), .init(instrument: plugin(), id: second)], masterLevelDecibels: 0)
        try h.host.applyMixer([.init()], masterLevelDecibels: 0)
        h.components.succeed(0, h.unit())
        XCTAssertNil(h.host.host(for: second)); XCTAssertTrue(h.runtime.attachments.isEmpty)
        h.host.shutdown()
    }
    func testRemovedInsertLivesThroughRetireFadeAndShutdownInBothOrders() async throws {
        for childFirst in [false, true] {
            let h = try Harness(), second = UUID(), insertID = UUID()
            let effect = InstrumentPlugin(identity: .init(componentType: 0x61756678, componentSubType: 3, componentManufacturer: 2))
            let channels = [InstrumentChannel(instrument: plugin()), InstrumentChannel(instrument: plugin(), inserts: [.init(id: insertID, plugin: effect)], id: second)]
            try h.host.applyMixer(channels, masterLevelDecibels: -12)
            for index in h.components.requests.indices { h.components.succeed(index, h.unit()) }
            let child = try XCTUnwrap(h.host.host(for: second)), insert = try XCTUnwrap(child.inserts[insertID])
            try h.host.start()
            h.trace.events.removeAll()
            try h.host.applyMixer([channels[0]], masterLevelDecibels: -12)
            XCTAssertNotNil(insert.unit)
            XCTAssertFalse(h.trace.events.contains("graph-remove"))
            var done = false; h.host.shutdown { done = true }
            for index in childFirst ? [0, 1] : [1, 0] { h.runtime.ack(index) }
            XCTAssertFalse(done); XCTAssertNotNil(insert.unit)
            XCTAssertFalse(h.trace.events.contains("graph-remove"))
            h.graph.reportFadeReached(); h.graph.branches[0].reportFadeReached()
            let deadline = Date().addingTimeInterval(1)
            while !done && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertTrue(done); XCTAssertNil(insert.unit)
        }
    }
    func testLatestConfigurationWinsBothBarrierPhasesIncludingRevert() throws {
        for phase in [0, 1] { for revert in [false, true] {
            let h = try Harness(), second = UUID(), original = h.host.configuration
            try h.host.applyMixer([.init(instrument: plugin()), .init(instrument: plugin(), id: second)], masterLevelDecibels: -12)
            h.components.succeed(0, h.unit()); h.components.succeed(1, h.unit())
            h.host.configure(.init(deviceID: 101, sampleRate: 44_100))
            if phase == 1 { h.runtime.ack(0) }
            let latest = revert ? original : AudioHostConfiguration(deviceID: 202, sampleRate: 96_000)
            h.host.configure(latest)
            if phase == 0 { h.runtime.ack(0) }
            h.runtime.ack(1)
            XCTAssertEqual(h.host.configuration, latest)
            XCTAssertEqual(h.graph.configurations.last, latest)
            XCTAssertEqual(h.graph.branches[0].configurations.last, latest)
            XCTAssertEqual(h.graph.masterLevels.last, -12)
            h.host.configure(latest)
            XCTAssertEqual(h.runtime.retirements.count, 2)
            h.host.shutdown()
            for index in 2..<h.runtime.acknowledgements.count { h.runtime.ack(index) }
        } }
    }
    func testMasterRestoredAfterSingleStripRebuild() throws {
        for level in [-120.0, -12, 6] {
            let h = try Harness()
            try h.host.applyMixer([.init(instrument: plugin())], masterLevelDecibels: level)
            h.components.succeed(0, h.unit())
            h.host.configure(.init(sampleRate: 44_100)); h.runtime.ack(0)
            XCTAssertEqual(h.graph.masterLevels.last, level)
            h.host.shutdown(); h.runtime.ack(1)
        }
    }
    func testConfigurationWaitsForAllStripsAndConsumesLatestMixer() async throws {
        let h = try Harness(), second = UUID(), third = UUID()
        let channels = [InstrumentChannel(instrument: plugin()), InstrumentChannel(instrument: plugin(), id: second)]
        try h.host.applyMixer(channels, masterLevelDecibels: 0)
        h.components.succeed(0, h.unit()); h.components.succeed(1, h.unit())
        h.host.configure(.init(sampleRate: 44_100))
        XCTAssertEqual(h.graph.configurations.count, 1)
        h.graph.reportConfigurationChange() // detach notification cannot revert 44.1 kHz intent
        try h.host.applyMixer([channels[0], .init(instrument: plugin(), id: third)], masterLevelDecibels: -12)
        h.runtime.ack(0)
        XCTAssertEqual(h.graph.configurations.count, 1)
        h.runtime.ack(1)
        XCTAssertEqual(h.graph.configurations.last?.sampleRate, 44_100)
        XCTAssertNil(h.host.host(for: second)); XCTAssertNotNil(h.host.host(for: third))
        XCTAssertEqual(h.graph.masterLevels.last, -12)
        var done = false; h.host.shutdown { done = true }
        for index in 2..<h.runtime.acknowledgements.count { h.runtime.ack(index) }
        XCTAssertTrue(done)
    }
    func testConfigurationCanRevertToCurrentWhileSiblingBarrierIsPending() throws {
        let h = try Harness(), second = UUID()
        try h.host.applyMixer([.init(instrument: plugin()), .init(instrument: plugin(), id: second)], masterLevelDecibels: 0)
        h.components.succeed(0, h.unit()); h.components.succeed(1, h.unit())
        let original = h.host.configuration
        h.host.configure(.init(sampleRate: 44_100))
        h.host.configure(original)
        h.runtime.ack(0); h.runtime.ack(1)
        XCTAssertEqual(h.host.configuration, original)
        XCTAssertEqual(h.graph.branches[0].configurations.last, original)
        var done = false; h.host.shutdown { done = true }
        for index in 2..<h.runtime.acknowledgements.count { h.runtime.ack(index) }
        XCTAssertTrue(done)
    }
    func testConfigurationKeepsSiblingInstancesEditorsAndLiveStateAndShutdownDuringBarrier() throws {
        for terminateDuringChange in [false, true] {
            let h = try Harness(), second = UUID()
            let channels = [InstrumentChannel(instrument: plugin()), InstrumentChannel(instrument: plugin(), id: second)]
            try h.host.applyMixer(channels, masterLevelDecibels: 0)
            let firstUnit = h.unit(), secondUnit = h.unit()
            h.components.succeed(0, firstUnit); h.components.succeed(1, secondUnit)
            let firstInstance = try XCTUnwrap(h.host.instrument)
            let child = try XCTUnwrap(h.host.host(for: second)), secondInstance = try XCTUnwrap(child.instrument)
            secondInstance.openEditor(title: "Fake")
            let editor = secondInstance.editor
            firstUnit.state = Data([91]); secondUnit.state = Data([92])
            h.host.configure(.init(sampleRate: 44_100))
            var done = false
            if terminateDuringChange { h.host.shutdown { done = true } }
            h.runtime.ack(0)
            if !terminateDuringChange {
                XCTAssertEqual(h.graph.configurations.count, 1)
                h.runtime.ack(1)
                XCTAssertTrue(h.host.instrument === firstInstance); XCTAssertTrue(child.instrument === secondInstance)
                XCTAssertTrue(secondInstance.editor === editor)
                XCTAssertEqual(try firstInstance.readState(), Data([91])); XCTAssertEqual(try secondInstance.readState(), Data([92]))
                XCTAssertEqual(h.components.requests.count, 2)
                XCTAssertEqual(h.graph.branches[0].configurations.last?.sampleRate, 44_100)
                h.host.shutdown { done = true }
            }
            for index in (terminateDuringChange ? 1 : 2)..<h.runtime.acknowledgements.count { h.runtime.ack(index) }
            XCTAssertTrue(done)
            XCTAssertNil(firstInstance.unit); XCTAssertNil(secondInstance.unit)
        }
    }
}
