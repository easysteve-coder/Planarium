import AppKit
import AudioToolbox
import AVFoundation
import XCTest
import PlanariumDomain
import PlanariumRuntime
@testable import PlanariumAudio

/// Owner-gated production composition. Manual rendering exclusively: no
/// engine output on a device, no third-party components, no fronted window.
final class AppleOfflineAudioHostTests: XCTestCase {
    /// Explicit inventory only: instantiate and read descriptors, no graph,
    /// resource allocation, editor request, MIDI, rendering or device output.
    @MainActor func testOwnerPluginParameterInventoryWithoutAudio() async throws {
        guard ProcessInfo.processInfo.environment["SICK_PLUGIN_INVENTORY"] == "1" else {
            throw XCTSkip("Offline parameter inventory requires SICK_PLUGIN_INVENTORY=1")
        }
        _ = NSApplication.shared
        let source = SystemPluginSource()
        let catalog = SystemAudioUnitComponentSource()
        // AU registration/validation completes asynchronously in a fresh CLI.
        _ = catalog.effectComponentDescriptions()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let registered = catalog.effectComponentDescriptions() + catalog.instrumentComponentDescriptions()
        for component in registered { print("PLUGIN-REGISTERED\t\(component.name)\t\(component.manufacturerName)") }
        let components = registered.filter {
            $0.name.contains("UADx") || $0.name.contains("EchoBoy Jr") || $0.componentManufacturer == kAudioUnitManufacturer_Apple
        }
        print("PLUGIN-INVENTORY\tcomponent\ttype/sub/manufacturer\taddress\tidentifier\tname\tmin\tmax\tofficial-bypass")
        for component in components {
            let identity = SpatialAudioUnitIdentity(componentType: component.componentType,
                componentSubType: component.componentSubType, componentManufacturer: component.componentManufacturer)
            var result: Result<any PluginUnit, PluginLoadError>?
            source.load(identity) { result = $0 }
            for _ in 0..<400 {
                if result != nil { break }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            let code = String(format: "%08X/%08X/%08X", identity.componentType, identity.componentSubType, identity.componentManufacturer)
            guard let result, case .success(let unit) = result else {
                print("PLUGIN-INVENTORY\t\(component.name)\t\(code)\tLOAD FAILED OR TIMED OUT")
                continue
            }
            let bypass = unit.audioNode?.auAudioUnit.shouldBypassEffect == true
            let parameters = unit.parameterDescriptors
            if parameters.isEmpty { print("PLUGIN-INVENTORY\t\(component.name)\t\(code)\tNO WRITABLE PARAMETERS\t\(bypass)") }
            for parameter in parameters {
                print("PLUGIN-INVENTORY\t\(component.name)\t\(code)\t\(parameter.address)\t\(parameter.identifier)\t\(parameter.displayName)\t\(parameter.minimumValue)\t\(parameter.maximumValue)\t\(bypass)")
            }
        }
        XCTAssertFalse(components.isEmpty)
    }
    @MainActor private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return condition()
    }
    @MainActor func testAppleDLSReverbDelayOfflinePresetsBypassAndSeparateEditors() throws {
        guard ProcessInfo.processInfo.environment["SICK_REAL_AUDIO"] == "1" else {
            throw XCTSkip("Apple-AU-Prüfstand nur durch Supervisor mit SICK_REAL_AUDIO=1; ausschließlich offline")
        }
        _ = NSApplication.shared
        func apple(_ type: OSType, _ sub: OSType) -> InstrumentPlugin {
            .init(identity: .init(componentType: type, componentSubType: sub, componentManufacturer: kAudioUnitManufacturer_Apple))
        }
        let runtime = PerformanceRuntime(clock: MonotonicRuntimeClock(), mailbox: DisplayFrameMailbox())
        let graph = AVAudioGraph()
        let host = try AudioHost(components: SystemPluginSource(), graph: graph,
            runtime: PerformanceAudioPort(runtime: runtime), windows: AppKitPluginWindows(),
            configuration: .init(offline: true))
        defer {
            var done = false
            host.shutdown { done = true }
            XCTAssertTrue(waitUntil { done }, "Retire must acknowledge before graph release")
        }
        let reverb = InstrumentInsert(id: UUID(), plugin: apple(kAudioUnitType_Effect, kAudioUnitSubType_MatrixReverb), bypassed: true)
        let delay = InstrumentInsert(id: UUID(), plugin: apple(kAudioUnitType_Effect, kAudioUnitSubType_Delay))
        var channel = InstrumentChannel(instrument: apple(kAudioUnitType_MusicDevice, kAudioUnitSubType_DLSSynth), inserts: [reverb, delay])
        host.apply(channel)
        XCTAssertTrue(waitUntil { host.status.values.allSatisfy { $0 != .loading } })
        XCTAssertEqual(host.status[.instrument], .loaded)
        XCTAssertEqual(host.status[.insert(reverb.id)], .bypass)
        XCTAssertEqual(host.status[.insert(delay.id)], .loaded)
        let instrument = try XCTUnwrap(host.instrument)
        let reverbInstance = try XCTUnwrap(host.inserts[reverb.id])
        let delayInstance = try XCTUnwrap(host.inserts[delay.id])
        try host.start()
        let schedule = try XCTUnwrap(instrument.scheduleBoundary())
        XCTAssertEqual(schedule.scheduleMIDI(bytes: [0x90, 60, 100]), .sent)
        var peak: Float = 0
        for _ in 0..<128 {
            let buffer = try graph.renderOffline()
            guard let data = buffer.floatChannelData else { return XCTFail("No float PCM") }
            for ch in 0..<Int(buffer.format.channelCount) {
                for frame in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[ch][frame])) }
            }
        }
        XCTAssertTrue(peak.isFinite && peak > 0, "Apple DLS must render nonzero samples offline")
        XCTAssertEqual(schedule.scheduleMIDI(bytes: [0x80, 60, 0]), .sent)
        host.stop()
        instrument.openEditor(title: "Apple DLS (offline)", offscreen: true)
        delayInstance.openEditor(title: "Apple Delay (offline)", offscreen: true)
        XCTAssertTrue(waitUntil { instrument.window != nil && delayInstance.window != nil })
        let first = try XCTUnwrap(instrument.window as? AppKitPluginWindow)
        let second = try XCTUnwrap(delayInstance.window as? AppKitPluginWindow)
        XCTAssertFalse(first.nativeWindow === second.nativeWindow)
        XCTAssertFalse(first.nativeWindow.isVisible); XCTAssertFalse(second.nativeWindow.isVisible)
        for instance in [instrument, delayInstance] {
            let editor = try XCTUnwrap(instance.editor as? AppKitPluginEditor)
            let window = try XCTUnwrap(instance.window)
            let original = editor.initialSize
            for size in [NSSize(width: original.width + 100, height: original.height + 70),
                         NSSize(width: max(150, original.width - 70), height: max(120, original.height - 50))] {
                editor.viewController.preferredContentSize = size
                XCTAssertTrue(waitUntil { abs(window.contentSize.width - size.width) < 0.6 && abs(window.contentSize.height - size.height) < 0.6 })
            }
            for size in [NSSize(width: 700, height: 500), NSSize(width: 240, height: 180)] {
                editor.viewController.view.setFrameSize(size)
                XCTAssertTrue(waitUntil { abs(window.contentSize.width - size.width) < 0.6 && abs(window.contentSize.height - size.height) < 0.6 })
            }
        }
        channel = try host.snapshotChannel()
        channel.levelDecibels = -6
        channel.inserts.reverse()
        host.apply(channel)
        XCTAssertTrue(host.instrument === instrument)
        XCTAssertTrue(host.inserts[reverb.id] === reverbInstance)
        XCTAssertTrue(instrument.window === first)
        XCTAssertEqual(host.status[.insert(reverb.id)], .bypass)
        channel.inserts[channel.inserts.firstIndex(where: { $0.id == reverb.id })!].bypassed = false
        host.apply(channel)
        XCTAssertEqual(host.status[.insert(reverb.id)], .loaded)
        try host.start()
        // Applying the captured state retires Q before changing fullState.
        // start() records a request during that retire; rendering is valid
        // only after its acknowledgement has actually restarted the graph.
        XCTAssertTrue(waitUntil { host.isRunning && host.status[.instrument] == .loaded },
                      "State-refresh retire must acknowledge before offline rendering resumes")
        XCTAssertEqual(schedule.scheduleMIDI(bytes: [0x90, 64, 100]), .sent)
        _ = try graph.renderOffline()
        XCTAssertEqual(schedule.scheduleMIDI(bytes: [0x80, 64, 0]), .sent)
        print("UMBAU-P4 Apple offline: DLS/MatrixReverb/Delay, peak=\(peak), same instance/editor, bypass/order/state, separate offscreen windows, preferred/frame grow+shrink")
    }
}
