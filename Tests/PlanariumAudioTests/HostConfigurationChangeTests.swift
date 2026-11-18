import AVFoundation
import CoreAudio
import XCTest
import PlanariumDomain
@testable import PlanariumAudio

@MainActor final class HostConfigurationChangeTests: XCTestCase {
    func testOutputPreferenceUsesUIDAcrossRestartAndRestoresEnabledOnlyOnce() throws {
        let h = try Harness(); defer { h.finish() }
        let catalog = FakeOutputCatalog(), settings = FakeOutputPreferences()
        settings.deviceUID = "audiobox"; settings.deviceName = "Old device name"; settings.audioEnabled = true
        catalog.devices[2] = .init(id: 72, name: "AudioBox iTwo", isSystemOutput: false, uid: "audiobox", sampleRate: 44_100)
        let model = AudioOutputDeviceControlModel(host: h.host, catalog: catalog, preferences: settings,
            startAudio: { XCTFail("Startup restoration must not require Edit permission") })
        defer { model.shutdown() }
        XCTAssertEqual(h.graph.starts, 0)
        model.restoreAtStartup(); model.restoreAtStartup()
        XCTAssertEqual(h.host.configuration.deviceID, 72)
        XCTAssertEqual(model.selectedDevice.name, "AudioBox iTwo")
        XCTAssertTrue(model.outputSummary.contains("44.1 kHz")); XCTAssertNil(model.notice)
        XCTAssertEqual(model.currentSampleRate, 48_000, "The processing picker is separate from the actual device rate")
        XCTAssertEqual(h.graph.starts, 1)
        h.host.stop(); XCTAssertFalse(settings.audioEnabled)
        model.selectDevice(catalog.devices[0]); XCTAssertNil(settings.deviceUID)
        XCTAssertTrue(model.outputSummary.contains("Built-in Output (System)"))
        model.selectDevice(catalog.devices[2]); XCTAssertEqual(settings.deviceUID, "audiobox")
        XCTAssertEqual(catalog.observations, 1)
    }
    func testMissingRememberedOutputAtStartIsVisibleAndDoesNotStartAudio() throws {
        let h = try Harness(); defer { h.finish() }
        let catalog = FakeOutputCatalog(), settings = FakeOutputPreferences()
        settings.deviceUID = "audiobox"; settings.deviceName = "AudioBox iTwo"; settings.audioEnabled = true
        catalog.devices.removeLast()
        let model = AudioOutputDeviceControlModel(host: h.host, catalog: catalog, preferences: settings)
        defer { model.shutdown() }
        model.restoreAtStartup()
        XCTAssertEqual(h.graph.starts, 0); XCTAssertNil(h.host.configuration.deviceID)
        XCTAssertTrue(try XCTUnwrap(model.notice).contains("AudioBox iTwo not found"))
        XCTAssertTrue(try XCTUnwrap(model.notice).contains("Built-in Output"))
        XCTAssertEqual(model.stripSummary, "Audio off – click to start")
        XCTAssertTrue(settings.audioEnabled, "A missing device preserves restart intent")
        XCTAssertEqual(settings.deviceUID, "audiobox")
        XCTAssertEqual(model.pendingDeviceAlert, model.notice)
        model.acknowledgeDeviceAlert(); model.refresh()
        XCTAssertNil(model.pendingDeviceAlert, "The same missing device does not repeatedly interrupt")
        catalog.devices.append(.init(id: 99, name: "AudioBox iTwo", isSystemOutput: false, uid: "audiobox"))
        catalog.changed?(); XCTAssertTrue(model.canRestoreDevice)
        model.restoreDesiredDevice()
        XCTAssertEqual(h.host.configuration.deviceID, 99); XCTAssertEqual(h.graph.starts, 1)
        XCTAssertNil(model.notice)
    }
    func testOutputLossAndReturnKeepWarningUntilExplicitRestoreAndUnregister() async throws {
        let h = try Harness(); defer { h.finish() }
        let catalog = FakeOutputCatalog(), settings = FakeOutputPreferences()
        let model = AudioOutputDeviceControlModel(host: h.host, catalog: catalog, preferences: settings)
        model.selectDevice(catalog.devices[2])
        try h.host.start()
        let remembered = catalog.devices.removeLast()
        catalog.changed?()
        XCTAssertNil(h.host.configuration.deviceID)
        XCTAssertEqual(settings.deviceUID, "audiobox")
        XCTAssertTrue(try XCTUnwrap(model.notice).contains("not found"), "A fallback must never be silent")
        catalog.devices.append(.init(id: 99, name: remembered.name, isSystemOutput: false, uid: remembered.uid))
        catalog.changed?()
        XCTAssertTrue(model.canRestoreDevice); XCTAssertNil(h.host.configuration.deviceID)
        XCTAssertTrue(try XCTUnwrap(model.notice).contains("available again"))
        model.restoreDesiredDevice()
        XCTAssertEqual(h.host.configuration.deviceID, 99); XCTAssertNil(model.notice)
        XCTAssertFalse(model.canRestoreDevice)
        model.shutdown(); XCTAssertNil(catalog.changed)
        let configurations = h.graph.configurations.count
        catalog.changed?(); XCTAssertEqual(h.graph.configurations.count, configurations)
    }
    func testOutputLossUsesExistingRetireBeforeReconfigurationBoundary() async throws {
        let h = try Harness(); defer { h.finish() }
        let catalog = FakeOutputCatalog()
        let model = AudioOutputDeviceControlModel(host: h.host, catalog: catalog)
        defer { model.shutdown() }
        model.selectDevice(catalog.devices[2])
        h.host.apply(.init(instrument: plugin())); h.components.succeed(0, h.unit())
        try h.host.start()
        let configurations = h.graph.configurations.count
        let instance = try XCTUnwrap(h.host.instrument)
        catalog.devices.removeLast(); catalog.changed?()
        XCTAssertEqual(h.runtime.retirements, [instance.id])
        XCTAssertEqual(h.graph.configurations.count, configurations, "Do not rebuild before Q releases audio notes")
        try await acknowledgeRetireAndFade(h)
        XCTAssertNil(h.host.configuration.deviceID)
        XCTAssertTrue(h.host.isRunning)
        XCTAssertTrue(try XCTUnwrap(model.notice).contains("not found"))
    }
    func testOutputChoiceReturningToOriginalCancelsPendingDeviceAndKeepsLastIntent() async throws {
        let h = try Harness(); defer { h.finish() }
        let catalog = FakeOutputCatalog()
        let model = AudioOutputDeviceControlModel(host: h.host, catalog: catalog)
        defer { model.shutdown() }
        model.refresh()
        h.host.apply(.init(instrument: plugin())); h.components.succeed(0, h.unit())
        try h.host.start()
        model.selectDevice(catalog.devices[2])
        model.selectDevice(catalog.devices[0])
        try await acknowledgeRetireAndFade(h)
        XCTAssertNil(h.host.configuration.deviceID)
        XCTAssertTrue(model.selectedDevice.isSystemOutput)
        XCTAssertEqual(h.runtime.retirements.count, 1)
    }
    func testAudioEnablePreferenceSurvivesSuspensionAndShutdownButExplicitStopClearsIt() throws {
        let h = try Harness(); defer { h.finish() }
        let catalog = FakeOutputCatalog(), settings = FakeOutputPreferences()
        let model = AudioOutputDeviceControlModel(host: h.host, catalog: catalog, preferences: settings)
        defer { model.shutdown() }
        model.refresh(); model.startAudio()
        XCTAssertTrue(settings.audioEnabled)
        h.host.suspendPlayback()
        XCTAssertFalse(h.host.isRunning); XCTAssertTrue(settings.audioEnabled)
        try h.host.start()
        h.host.stop(); XCTAssertFalse(settings.audioEnabled)
        try h.host.start(); h.host.shutdown()
        XCTAssertTrue(settings.audioEnabled, "Closing the app must not save Audio off")
    }
    func testNativeCatalogRegistrationCoalescesAndRemovesExactListenersInBothOrders() async {
        for queuedBeforeRemove in [false, true] {
            var listeners: [UInt32: AudioObjectPropertyListenerBlock] = [:]
            var removals: [UInt32] = [], deliveries = 0
            var observer: AudioCatalogObservation? = AudioCatalogObservation(changed: { deliveries += 1 }, register: { selector, block in
                listeners[selector] = block; return noErr
            }, unregister: { selector, _ in removals.append(selector); return noErr })
            XCTAssertEqual(Set(listeners.keys), [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice])
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            for block in listeners.values { block(1, &address); block(1, &address) }
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(deliveries, 1)
            if queuedBeforeRemove { for block in listeners.values { block(1, &address) } }
            observer?.remove(); observer = nil
            XCTAssertEqual(Set(removals), Set(listeners.keys)); XCTAssertEqual(removals.count, 2)
            if !queuedBeforeRemove { for block in listeners.values { block(1, &address) } }
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(deliveries, 1, "Removed/queued callbacks cannot revive a catalog session")
        }
    }
    func testNativeCatalogRegistrationFailureIsVisibleAndOnlySuccessfulListenerIsRemoved() {
        var removed: [UInt32] = []
        let observer = AudioCatalogObservation(changed: {}, register: { selector, _ in
            selector == kAudioHardwarePropertyDevices ? noErr : -50
        }, unregister: { selector, _ in removed.append(selector); return noErr })
        XCTAssertTrue(observer.notice?.contains("notifications unavailable") == true)
        observer.remove()
        XCTAssertEqual(removed, [kAudioHardwarePropertyDevices])
    }
    func testNativeStopInvalidatesScheduleBeforeMainDeliveryAndOldProbeCannotRevive() throws {
        let engine = AVAudioEngine()
        let graph = AVAudioGraph(makeEngine: { engine }, selectDevice: { _, _ in })
        try graph.configure(.init(offline: true))
        var callbacks = 0
        graph.observeConfigurationChange { callbacks += 1 }
        defer { graph.close() }
        try graph.start()
        let oldProbe = graph.scheduleAvailabilityProbe()
        XCTAssertTrue(oldProbe())
        let posted = DispatchSemaphore(value: 0)
        let notification = NativeStopNotification(engine)
        DispatchQueue.global().async { notification.post(); posted.signal() }
        XCTAssertEqual(posted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(callbacks, 0, "Main delivery is deliberately withheld")
        XCTAssertFalse(oldProbe(), "Q must see unbound immediately at notification ingress")
        try graph.configure(.init(offline: true)); try graph.start()
        XCTAssertFalse(oldProbe(), "An obsolete binding cannot become available with the new engine generation")
        XCTAssertTrue(graph.scheduleAvailabilityProbe()())
    }
    private func drain() async throws { try await Task.sleep(nanoseconds: 5_000_000) }

    func testNativeOwnEngineRebuildRestartForeignEngineAndShutdown() async throws {
        let engine = AVAudioEngine()
        var builds = 0
        let graph = AVAudioGraph(makeEngine: { builds += 1; return engine }, selectDevice: { _, _ in })
        let trace = Trace()
        let host = try AudioHost(components: FakeComponents(), graph: graph, runtime: FakeRuntime(trace: trace),
            windows: FakeWindows(trace: trace), configuration: .init(offline: true))
        defer { host.shutdown() }
        host.apply(host.channel)
        try host.start()
        let foreign = AVAudioEngine()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: foreign)
        try await drain()
        XCTAssertNil(host.configurationNotice)
        XCTAssertTrue(host.isRunning)
        for _ in 0..<3 {
            // Burst coalesces; configure cancels its old observer and replaces it.
            for _ in 0..<3 { NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine) }
            try await drain()
            XCTAssertTrue(host.isRunning)
            XCTAssertEqual(engine.attachedNodes.subtracting([engine.mainMixerNode, engine.outputNode]).count, 5)
            XCTAssertTrue(engine.isInManualRenderingMode)
            XCTAssertEqual(host.configurationNotice, "Audio output changed; rebuilding")
        }
        XCTAssertEqual(builds, 1, "System/offline rebuild retains its engine")
        host.shutdown()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        try await drain()
        XCTAssertFalse(host.isRunning)
        XCTAssertFalse(engine.isRunning)
    }

    func testNativeObserverExactlyOnceRebuildReplacementAndQueuedShutdown() async throws {
        var engines: [AVAudioEngine] = []
        let graph = AVAudioGraph(makeEngine: { let e = AVAudioEngine(); engines.append(e); return e }, selectDevice: { _, _ in })
        var events = 0
        graph.observeConfigurationChange { events += 1 }
        defer { graph.observeConfigurationChange(nil); graph.stop() }
        for _ in 0..<3 { try graph.configure(.init(deviceID: 7)) }
        let old = try XCTUnwrap(engines.last)
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: old)
        try await drain(); XCTAssertEqual(events, 1)
        try graph.configure(.init())
        let current = try XCTUnwrap(engines.last)
        XCTAssertFalse(old === current)
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: old)
        try await drain(); XCTAssertEqual(events, 1)
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: current)
        try await drain(); XCTAssertEqual(events, 2)
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: current)
        graph.observeConfigurationChange(nil)
        try await drain(); XCTAssertEqual(events, 2, "Queued callback after unregister is inert")
        graph.observeConfigurationChange { events += 1 }
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: current)
        try await drain(); XCTAssertEqual(events, 3)
    }

    func testFakeChangeRetiresBeforeRebuildPreservesInstancesAndMeter() async throws {
        let h = try Harness(); defer { h.finish() }
        let insert = InstrumentInsert(id: UUID(), plugin: plugin(3, instrument: false))
        h.host.apply(.init(instrument: plugin(), inserts: [insert]))
        h.components.succeed(0, h.unit()); h.components.succeed(1, h.unit())
        let old = try XCTUnwrap(h.host.instrument), effect = try XCTUnwrap(h.host.inserts[insert.id])
        try h.host.start(); h.host.setMeterVisible(true)
        h.graph.reportConfigurationChange()
        XCTAssertFalse(h.host.isRunning); XCTAssertTrue(h.host.playbackRequested)
        XCTAssertFalse(h.host.isMeterActive); XCTAssertNotNil(old.unit)
        XCTAssertEqual(h.graph.configurations.count, 1)
        h.runtime.ack()
        XCTAssertEqual(h.graph.configurations.count, 2); XCTAssertEqual(h.graph.starts, 2)
        XCTAssertTrue(h.host.isRunning); XCTAssertTrue(h.host.isMeterActive)
        XCTAssertTrue(h.host.instrument === old); XCTAssertTrue(h.host.inserts[insert.id] === effect)
        h.host.shutdown(); h.runtime.ack(1)
        h.graph.reportFadeReached(); try await drain()
        h.graph.reportConfigurationChange()
        XCTAssertEqual(h.graph.configurations.count, 2); XCTAssertFalse(h.host.isRunning)
        XCTAssertNil(h.graph.configurationHandler)
    }

    func testDisappearedDeviceFallsBackToSystemWithVisibleNotice() throws {
        let h = try Harness(); defer { h.finish() }
        let display = AudioOutputDeviceControlModel(host: h.host)
        h.host.configure(.init(deviceID: 7)); try h.host.start()
        h.graph.unavailableDevices = [7]
        h.graph.reportConfigurationChange()
        XCTAssertNil(h.host.configuration.deviceID)
        XCTAssertTrue(h.host.isRunning)
        XCTAssertEqual(h.graph.configurations.map(\.deviceID), [nil, 7, 7, nil])
        XCTAssertTrue(display.selectedDevice.isSystemOutput)
        XCTAssertEqual(display.notice, "Selected audio device unavailable; using System Output")
        h.graph.reportConfigurationChange()
        XCTAssertNil(h.host.configuration.deviceID); XCTAssertTrue(h.host.isRunning)
    }

    func testChangeAndLatestStopStartInBothOrdersAlsoWhileRetirePending() throws {
        for startLast in [false, true] {
            for changeFirst in [false, true] {
                let h = try Harness(); defer { h.finish() }
                h.host.apply(.init(instrument: plugin())); h.components.succeed(0, h.unit())
                try h.host.start()
                if changeFirst { h.graph.reportConfigurationChange() }
                h.host.stop()
                if !changeFirst { h.graph.reportConfigurationChange() }
                if startLast { try h.host.start() }
                h.graph.reportConfigurationChange() // repeat during blocked Q
                XCTAssertEqual(h.runtime.retirements.count, 1)
                h.runtime.ack()
                XCTAssertEqual(h.host.isRunning, startLast)
                XCTAssertEqual(h.graph.configurations.count, 2)
                XCTAssertEqual(h.graph.starts, startLast ? 2 : 1)
            }
        }
    }

    func testStoppedGraphRebuildDoesNotStartAndFailureRecoversExplicitly() throws {
        let h = try Harness(); defer { h.finish() }
        h.graph.reportConfigurationChange()
        XCTAssertEqual(h.graph.configurations.count, 2); XCTAssertEqual(h.graph.starts, 0)
        try h.host.start(); h.graph.configurationFails = true
        h.graph.reportConfigurationChange()
        XCTAssertFalse(h.host.isRunning); XCTAssertNotNil(h.host.graphFailure)
        h.graph.configurationFails = false
        h.host.configure(h.host.configuration); try h.host.start()
        XCTAssertTrue(h.host.isRunning)
    }

    func testFakeConnectAndTapFailuresAreVisibleLocalAndExplicitRetry() throws {
        let h = try Harness(); defer { h.finish() }
        let bad = InstrumentInsert(id: UUID(), plugin: plugin(3, instrument: false))
        let good = InstrumentInsert(id: UUID(), plugin: plugin(4, instrument: false))
        h.graph.connectionFailures[bad.plugin.identity] = .init("Synthetic connection rejection")
        h.host.apply(.init(instrument: plugin(), inserts: [bad, good]))
        for i in 0..<3 { h.components.succeed(i, h.unit()) }
        XCTAssertEqual(h.host.status[.insert(bad.id)], .failed("Synthetic connection rejection"))
        XCTAssertNil(h.host.inserts[bad.id]); XCTAssertNotNil(h.host.inserts[good.id])
        XCTAssertEqual(h.graph.ordered, [try XCTUnwrap(h.host.inserts[good.id]).id])
        h.host.apply(h.host.channel); XCTAssertEqual(h.components.requests.count, 3)
        h.graph.connectionFailures.removeAll(); h.host.retry(.insert(bad.id)); h.components.succeed(3, h.unit())
        XCTAssertEqual(h.host.status[.insert(bad.id)], .loaded)
        h.graph.meterFails = true; h.host.setMeterVisible(true); try h.host.start()
        XCTAssertFalse(h.host.isMeterActive); XCTAssertTrue(h.host.graphFailure?.contains("Synthetic tap rejection") == true)
        h.graph.meterFails = false; h.host.setMeterVisible(true)
        XCTAssertTrue(h.host.isMeterActive)
    }

    func testInstrumentRejectedDuringRebuildNeverReattachesItsRetiringSchedule() async throws {
        let h = try Harness(); defer { h.finish() }
        h.host.apply(.init(instrument: plugin())); h.components.succeed(0, h.unit())
        let old = try XCTUnwrap(h.host.instrument)
        try h.host.start()
        h.graph.connectionFailures[old.identity] = .init("Rebuilt instrument connection refused")
        h.host.configure(.init(sampleRate: 44_100))
        try await acknowledgeRetireAndFade(h)
        XCTAssertEqual(h.runtime.attachments, [old.id], "A rejected schedule cannot reattach behind its pending retire")
        XCTAssertEqual(h.runtime.retirements, [old.id, old.id])
        guard case .failed = h.host.status[.instrument] else { return XCTFail("Rejected instrument remains failed") }
        try await acknowledgeRetireAndFade(h)
        XCTAssertNil(old.unit); XCTAssertNil(h.host.instrument)
        XCTAssertTrue(h.runtime.schedules.isEmpty)
        XCTAssertTrue(h.host.isRunning, "The remaining graph may continue")
    }
}
private final class NativeStopNotification: @unchecked Sendable {
    private let engine: AVAudioEngine
    init(_ engine: AVAudioEngine) { self.engine = engine }
    func post() { NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine) }
}
