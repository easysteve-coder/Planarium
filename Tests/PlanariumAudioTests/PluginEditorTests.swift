import AppKit
import AVFoundation
import AudioToolbox
import XCTest
import SwiftUI
import PlanariumDomain
@testable import PlanariumAudio

final class PluginEditorTests: XCTestCase {
    @MainActor func testExplicitChoiceOpensEditorExactlyOnceAndOnlyLatestPendingChoice() throws {
        let h = try Harness(); defer { h.finish() }
        h.host.apply(.init(instrument: plugin()))
        h.host.openEditorWhenLoaded(at: .instrument, identity: identity(), title: "first", allowed: { true })
        h.host.apply(.init(instrument: plugin(2)))
        h.host.openEditorWhenLoaded(at: .instrument, identity: identity(2), title: "second", allowed: { true })
        let first = h.unit(), second = h.unit()
        h.components.succeed(0, first)
        XCTAssertEqual(first.editorRequests, 0)
        h.components.succeed(1, second)
        XCTAssertEqual(second.editorRequests, 1); XCTAssertEqual(h.windows.windows.count, 1)
        h.host.apply(h.host.channel)
        XCTAssertEqual(h.windows.windows.count, 1)
    }
    @MainActor func testChoiceEditorIsSuppressedByPresetHistoryPerformAndFailure() throws {
        for cancellation in ["preset", "perform", "failure", "remove"] {
            let h = try Harness()
            var allowed = true
            h.host.apply(.init(instrument: plugin()))
            h.host.openEditorWhenLoaded(at: .instrument, identity: identity(), title: "chosen", allowed: { allowed })
            if cancellation == "preset" { h.host.apply(h.host.channel, restoringPluginStates: true) }
            if cancellation == "perform" { allowed = false }
            if cancellation == "remove" { h.host.apply(.init()) }
            let unit = h.unit()
            if cancellation == "failure" { h.components.fail(0) } else { h.components.succeed(0, unit) }
            XCTAssertEqual(unit.editorRequests, 0, cancellation)
            XCTAssertTrue(h.windows.windows.isEmpty, cancellation)
            h.finish()
        }
        let h = try Harness(); defer { h.finish() }
        h.host.apply(.init(instrument: plugin()), restoringPluginStates: true)
        let unit = h.unit(); h.components.succeed(0, unit)
        XCTAssertEqual(unit.editorRequests, 0, "Document load itself never asks for an editor")
    }
    @MainActor func testInsertChoiceAlsoOpensAfterLoadAndImmediateLoadedChoiceWorks() throws {
        let h = try Harness(); defer { h.finish() }
        let id = UUID()
        h.host.apply(.init(inserts: [.init(id: id, plugin: plugin(2, instrument: false))]))
        h.host.openEditorWhenLoaded(at: .insert(id), identity: identity(2, instrument: false), title: "FX", allowed: { true })
        let unit = h.unit(); h.components.succeed(0, unit)
        XCTAssertEqual(unit.editorRequests, 1); XCTAssertEqual(h.windows.windows.count, 1)
        h.host.instance(at: .insert(id))?.closeEditor()
        h.host.openEditorWhenLoaded(at: .insert(id), identity: identity(2, instrument: false), title: "FX", allowed: { true })
        XCTAssertEqual(unit.editorRequests, 1); XCTAssertEqual(h.windows.windows.count, 2)
    }
    @MainActor func testNativeEditorCompletionCannotOpenAfterPerformHistoryOrReplacement() throws {
        for cancellation in ["perform", "history", "replacement"] {
            let h = try Harness()
            var allowed = true
            h.host.apply(.init(instrument: plugin()))
            let unit = h.unit(); unit.deferEditor = true
            h.components.succeed(0, unit)
            h.host.openEditorWhenLoaded(at: .instrument, identity: identity(), title: "chosen", allowed: { allowed })
            if cancellation == "perform" { allowed = false }
            if cancellation == "history" { h.host.cancelPendingChosenEditors() }
            if cancellation == "replacement" { h.host.apply(.init(instrument: plugin(2))) }
            unit.editorCompletion?(unit.editor)
            XCTAssertTrue(h.windows.windows.isEmpty, cancellation)
            h.finish()
        }
    }
    @MainActor func testBypassFromInstanceCoalescesOnMainAndStripClickResolvesDisplayOverride() async throws {
        let h = try Harness(); defer { h.finish() }
        let id = UUID()
        let channel = InstrumentChannel(inserts: [.init(id: id, plugin: plugin(2, instrument: false))])
        h.host.apply(channel)
        let unit = h.unit(); h.components.succeed(0, unit)
        let receive = try XCTUnwrap(unit.bypassObservation)
        await Task.detached { receive(true); receive(false); receive(true) }.value
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(h.host.status[.insert(id)], .bypass)
        XCTAssertFalse(h.host.channel.inserts[0].bypassed, "Native UI bypass is a display-only override")
        h.host.apply(channel)
        XCTAssertEqual(h.host.status[.insert(id)], .bypass, "An unrelated document publication keeps the live status")
        h.host.setInsertBypassFromStrip(id, bypassed: false)
        XCTAssertEqual(h.host.status[.insert(id)], .loaded)
        XCTAssertEqual(unit.bypasses.last, false)
    }
    @MainActor func testBypassObservationUnregistersAndRejectsLateEventsForEveryReleaseOrder() async throws {
        for queuedBeforeRelease in [true, false] {
            let h = try Harness()
            let id = UUID()
            h.host.apply(.init(inserts: [.init(id: id, plugin: plugin(2, instrument: false))]))
            let unit = h.unit(); h.components.succeed(0, unit)
            let late = try XCTUnwrap(unit.bypassObservation)
            if queuedBeforeRelease { late(true) }
            h.host.apply(.init())
            XCTAssertNil(unit.bypassObservation, "The native listener must be removed")
            XCTAssertEqual(unit.bypassUnregistrations, 1)
            if !queuedBeforeRelease { late(true) }
            for _ in 0..<20 { await Task.yield() }
            XCTAssertNil(h.host.status[.insert(id)])
            h.finish()
        }
    }
    @MainActor func testBypassMailboxCoalescesBurstAndCancellationDropsQueuedValues() async {
        var received: [Bool] = []
        let mailbox = PluginBypassMailbox { received.append($0) }
        for _ in 0..<100 { mailbox.send(true); mailbox.send(false) }
        XCTAssertTrue(received.isEmpty, "Ingress never calls UI work synchronously")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(received, [false], "A burst queues one delivery with the last value")
        mailbox.send(true); mailbox.cancel()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(received, [false])
        mailbox.send(true)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(received, [false])
    }
    @MainActor func testNativeOfficialBypassAndV2PropertyUpdateStripWithoutAudioAndUnregister() async throws {
        let h = try Harness(); defer { h.finish() }
        let id = UUID(), node = AVAudioUnitEQ(numberOfBands: 1)
        let unit = SystemPluginUnit(unit: node)
        h.host.apply(.init(inserts: [.init(id: id, plugin: plugin(2, instrument: false))]))
        h.components.requests[0].complete(.success(unit))
        node.auAudioUnit.shouldBypassEffect = true
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(h.host.status[.insert(id)], .bypass)
        var bypass: UInt32 = 0
        XCTAssertEqual(AudioUnitSetProperty(node.audioUnit, kAudioUnitProperty_BypassEffect, kAudioUnitScope_Global, 0,
            &bypass, UInt32(MemoryLayout<UInt32>.size)), noErr)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(h.host.status[.insert(id)], .loaded, "v2 changes must cross the official AU bridge")
        h.host.apply(.init())
        node.auAudioUnit.shouldBypassEffect = true
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(h.host.status[.insert(id)])
    }
    @MainActor func testNativeMusicalFingerprintDetectsControlChangeAndReturnWithoutAudio() throws {
        let h = try Harness(); defer { h.finish() }
        let id = UUID(), node = AVAudioUnitEQ(numberOfBands: 1)
        let unit = SystemPluginUnit(unit: node)
        h.host.apply(.init(inserts: [.init(id: id, plugin: plugin(2, instrument: false))]))
        h.components.requests[0].complete(.success(unit))
        let instance = try XCTUnwrap(h.host.inserts[id])
        let baseline = try instance.readState()
        instance.pinComparisonState(baseline)
        XCTAssertNotNil(unit.musicalStateFingerprint)
        node.globalGain = 3
        XCTAssertFalse(InstrumentPluginState.equivalent(try instance.readState(comparingTo: baseline), baseline))
        node.globalGain = 0
        XCTAssertEqual(try instance.readState(comparingTo: baseline), baseline)
    }
    @MainActor func testSavedFingerprintSurvivesIncidentalSnapshotsAndUnrelatedReconciliation() throws {
        let h = try Harness(); defer { h.finish() }
        let id = UUID()
        let channel = InstrumentChannel(inserts: [.init(id: id, plugin: plugin(2, instrument: false, state: 1))])
        h.host.apply(channel)
        let unit = h.unit(); unit.musicalStateFingerprint = Data([1]); h.components.succeed(0, unit)
        let instance = try XCTUnwrap(h.host.inserts[id])
        unit.state = Data([7])
        var saved = channel; saved.inserts[0].plugin.state = try instance.readState()
        h.host.setComparisonReference([saved])
        for i in 8...100 { unit.state = Data([UInt8(i)]); _ = try instance.readState() }
        h.host.apply(channel)
        XCTAssertEqual(try instance.readState(comparingTo: Data([7])), Data([7]))
        unit.musicalStateFingerprint = Data([2])
        XCTAssertEqual(try instance.readState(comparingTo: Data([7])), Data([100]))
        unit.musicalStateFingerprint = Data([1])
        XCTAssertEqual(try instance.readState(comparingTo: Data([7])), Data([7]))
    }
    @MainActor func testNewInstrumentChoiceSupersedesPendingStopRetirement() throws {
        let h = try Harness(); defer { h.finish() }
        h.host.apply(.init(instrument: plugin())); h.components.succeed(0, h.unit())
        try h.host.start(); h.host.stop()
        h.host.apply(.init(instrument: plugin(2)))
        h.host.playSelectedInstrumentWhenLoaded(identity(2))
        h.runtime.ack()
        h.components.succeed(1, h.unit())
        XCTAssertEqual(h.graph.starts, 2); XCTAssertTrue(h.host.isRunning)
        XCTAssertEqual(h.host.status[.instrument], .loaded)
    }
    /// Owner 07.10.2026: Reopening showed the generic view because AUs hand
    /// out their own editor once per instance. Closing detaches the editor
    /// from every window (no drawing, no stutter); reopening reuses it; the
    /// controller is released together with the AU.
    @MainActor func testNativeCloseDetachesEditorTenTimesReopenReusesItAndReleaseFreesIt() throws {
        _ = NSApplication.shared
        let h = try Harness(); defer { h.finish() }
        let unit = h.unit()
        weak var released: NSViewController?
        unit.editorFactory = {
            let controller = NSViewController()
            controller.view = NSView(frame: .init(x: 0, y: 0, width: 400, height: 250))
            released = controller
            return AppKitPluginEditor(controller: controller)
        }
        let host = try AudioHost(components: h.components, graph: h.graph, runtime: h.runtime,
                                 windows: AppKitPluginWindows(), configuration: .init(offline: true))
        defer { host.shutdown(); if host.instrument != nil { h.runtime.ack(h.runtime.acknowledgements.count - 1) } }
        host.apply(.init(instrument: plugin())); h.components.succeed(0, unit)
        let instance = try XCTUnwrap(host.instrument)
        var recoveryEvents = 0
        host.onEditorClosed = { recoveryEvents += 1 }
        for iteration in 1...10 {
            try autoreleasepool {
                instance.openEditor(title: "Offline", offscreen: true)
                let window = try XCTUnwrap(instance.window as? AppKitPluginWindow)
                let container = try XCTUnwrap(window.nativeWindow.contentViewController)
                XCTAssertEqual(container.children.count, 1)
                XCTAssertFalse(window.nativeWindow.styleMask.contains(.resizable))
                let panel = try XCTUnwrap(window.nativeWindow as? NSPanel, "Floating panel, not a focus-taking window")
                XCTAssertTrue(panel.becomesKeyOnlyIfNeeded); XCTAssertTrue(panel.isFloatingPanel)
                XCTAssertFalse(panel.hidesOnDeactivate)
                window.nativeWindow.close() // native titlebar path, not instance.closeEditor
                XCTAssertTrue(container.children.isEmpty)
                XCTAssertEqual(recoveryEvents, iteration)
            }
            let controller = try XCTUnwrap(released)
            XCTAssertNil(controller.view.superview, "Closed editor is out of every view tree")
            XCTAssertNil(controller.view.window)
            XCTAssertNil(controller.parent)
            XCTAssertNotNil(instance.editor); XCTAssertNil(instance.window)
            XCTAssertEqual(unit.editorRequests, 1, "The AU is asked for its editor exactly once")
        }
        host.apply(.init()); h.runtime.ack(h.runtime.acknowledgements.count - 1)
        XCTAssertNil(instance.editor)
        XCTAssertNil(released, "Releasing the AU releases its editor")
    }
    @MainActor func testInsertOffLeavesSignalPathAndRetainsStateAndOrder() throws {
        let h = try Harness(); defer { h.finish() }
        let a = UUID(), b = UUID()
        var channel = InstrumentChannel(inserts: [
            .init(id: a, plugin: plugin(2, instrument: false, state: 7)),
            .init(id: b, plugin: plugin(3, instrument: false, state: 8))])
        h.host.apply(channel)
        let first = h.unit(), second = h.unit()
        h.components.succeed(0, first); h.components.succeed(1, second)
        let firstID = try XCTUnwrap(h.host.inserts[a]?.id), secondID = try XCTUnwrap(h.host.inserts[b]?.id)
        h.graph.render(); XCTAssertEqual(h.graph.rendered[firstID], 1)
        channel.inserts[0].bypassed = true; h.host.apply(channel)
        XCTAssertEqual(h.graph.ordered, [firstID, secondID])
        h.graph.render(); XCTAssertEqual(h.graph.rendered[firstID], 2)
        XCTAssertEqual(first.state, Data([7]))
        channel.inserts[0].bypassed = false; h.host.apply(channel)
        XCTAssertEqual(h.graph.ordered, [firstID, secondID])
        h.graph.render(); XCTAssertEqual(h.graph.rendered[firstID], 3)
        XCTAssertEqual(first.states, [Data([7])]); XCTAssertEqual(h.components.requests.count, 2)
    }
    @MainActor func testTwoEditorsHaveSeparateWindowsAndSizesAndCloseRequestsAgain() throws {
        let h = try Harness(); defer { h.finish() }
        let first = FakeEditor(size: .init(width: 900, height: 650), trace: h.trace)
        let second = FakeEditor(size: .init(width: 300, height: 170), trace: h.trace)
        h.host.apply(.init(instrument: plugin()))
        let unit = h.unit(editor: first); h.components.succeed(0, unit)
        let instance = try XCTUnwrap(h.host.instrument)
        instance.openEditor(title: "first"); instance.closeEditor(); instance.openEditor(title: "again")
        XCTAssertEqual(unit.editorRequests, 1); XCTAssertEqual(h.windows.windows.count, 2)
        XCTAssertNotNil(instance.unit); XCTAssertNotNil(instance.editor)
        h.host.apply(.init(instrument: plugin(2))); h.runtime.ack()
        h.components.succeed(1, h.unit(editor: second))
        h.host.instrument?.openEditor(title: "second")
        XCTAssertEqual(h.windows.windows.count, 3)
        XCTAssertEqual(h.windows.windows[0].contentSize, first.initialSize)
        XCTAssertEqual(h.windows.windows[2].contentSize, second.initialSize)
        XCTAssertFalse(h.windows.windows[1] === h.windows.windows[2])
    }
    @MainActor func testPreferredSizeOnlyAndFrameOnlyBothGrowAndShrinkThroughProductionObservers() async throws {
        for preferred in [true, false] {
            let h = try Harness()
            let controller = NSViewController()
            controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
            controller.view.postsFrameChangedNotifications = false
            if preferred { controller.preferredContentSize = NSSize(width: 400, height: 200) }
            let editor = AppKitPluginEditor(controller: controller)
            h.host.apply(.init(instrument: plugin()))
            h.components.succeed(0, h.unit(editor: editor))
            h.host.instrument?.openEditor(title: "sizing")
            let window = try XCTUnwrap(h.windows.windows.first)
            for size in [NSSize(width: 800, height: 600), NSSize(width: 220, height: 140), NSSize(width: 230, height: 110)] {
                if preferred { controller.preferredContentSize = size }
                else { controller.view.setFrameSize(size) }
                for _ in 0..<8 { await Task.yield() }
                XCTAssertEqual(window.contentSize, size, "\(preferred ? "preferred" : "frame") must follow both directions")
            }
            h.finish()
            XCTAssertFalse(controller.view.postsFrameChangedNotifications)
            let count = window.resizeCount
            controller.preferredContentSize = NSSize(width: 900, height: 900)
            controller.view.setFrameSize(NSSize(width: 900, height: 900))
            for _ in 0..<8 { await Task.yield() }
            XCTAssertEqual(window.resizeCount, count)
        }
    }
    @MainActor func testFrameEventOverridesStalePreferredSize() async throws {
        let h = try Harness(); defer { h.finish() }
        let controller = NSViewController()
        controller.view = NSView(frame: .init(x: 0, y: 0, width: 600, height: 400))
        controller.preferredContentSize = .init(width: 600, height: 400)
        h.host.apply(.init(instrument: plugin()))
        h.components.succeed(0, h.unit(editor: AppKitPluginEditor(controller: controller)))
        h.host.instrument?.openEditor(title: "frame")
        controller.view.setFrameSize(.init(width: 200, height: 120))
        for _ in 0..<8 { await Task.yield() }
        XCTAssertEqual(h.windows.windows[0].contentSize, .init(width: 200, height: 120))
    }
    @MainActor func testFeedbackInvalidSizesAndEqualContentDoNotLoop() throws {
        let h = try Harness(); defer { h.finish() }
        let editor = FakeEditor(trace: h.trace)
        h.host.apply(.init(instrument: plugin())); h.components.succeed(0, h.unit(editor: editor))
        h.host.instrument?.openEditor(title: "loop")
        let window = h.windows.windows[0]; window.feedback = true
        editor.resize(.init(width: 800, height: 600))
        XCTAssertEqual(window.resizeCount, 2)
        editor.resize(.init(width: 800.1, height: 600.1))
        editor.resize(.init(width: 0, height: 100))
        editor.resize(.init(width: CGFloat.nan, height: 100))
        XCTAssertEqual(window.resizeCount, 2)
        editor.resize(.init(width: 200, height: 150)); XCTAssertEqual(window.resizeCount, 3)
    }
    @MainActor func testAsyncEditorRequestedOnceAndLateEditorCannotReopenReleasedInstance() throws {
        let h = try Harness(); defer { h.finish() }
        let unit = h.unit(); unit.deferEditor = true
        h.host.apply(.init(instrument: plugin())); h.components.succeed(0, unit)
        let instance = try XCTUnwrap(h.host.instrument)
        instance.openEditor(title: "one"); instance.openEditor(title: "two")
        XCTAssertEqual(unit.editorRequests, 1); XCTAssertTrue(h.windows.windows.isEmpty)
        let late = unit.editorCompletion
        instance.closeEditor()
        late?(unit.editor)
        XCTAssertNotNil(instance.editor, "A late editor is kept for the next open")
        XCTAssertTrue(h.windows.windows.isEmpty, "but does not reopen a closed window")
        instance.openEditor(title: "again")
        XCTAssertEqual(unit.editorRequests, 1); XCTAssertEqual(h.windows.windows.count, 1)
        h.host.apply(.init()); h.runtime.ack()
        unit.editorCompletion?(unit.editor)
        XCTAssertNil(instance.editor); XCTAssertNil(instance.unit); XCTAssertEqual(h.windows.windows.count, 1)
    }
    @MainActor func testHostedEditorControllerSurvivesOfflineStopStateRefreshAndRestart() async throws {
        // Fake AU/graph, production host + native offscreen editor window.
        // An NSHostingController represents modern AU controllers that own
        // gesture/rendering lifecycle, rather than just a naked NSView.
        _ = NSApplication.shared
        let trace = Trace(), components = FakeComponents()
        let graph = FakeGraph(trace: trace), runtime = FakeRuntime(trace: trace)
        let host = try AudioHost(components: components, graph: graph, runtime: runtime,
                                 windows: AppKitPluginWindows(), configuration: .init(offline: true))
        defer { host.shutdown(); if host.instrument != nil { runtime.ack(runtime.acknowledgements.count - 1) } }
        let controller = NSHostingController(rootView: Text("Fake AU editor").onTapGesture {})
        controller.preferredContentSize = .init(width: 400, height: 240)
        let editor = AppKitPluginEditor(controller: controller)
        let unit = FakeUnit(trace: trace, editor: editor)
        unit.state = Data([7])
        host.apply(.init(instrument: plugin()))
        components.succeed(0, unit)
        let instance = try XCTUnwrap(host.instrument)
        try host.start()
        host.stop()
        instance.openEditor(title: "Fake AU (offline)", offscreen: true)
        let window = try XCTUnwrap(instance.window as? AppKitPluginWindow)
        let owner = try XCTUnwrap(window.nativeWindow.contentViewController, "Window must own a container controller, not just the plugin view")
        XCTAssertFalse(owner === controller)
        XCTAssertTrue(controller.parent === owner)
        XCTAssertTrue(owner.children.contains { $0 === controller })
        XCTAssertTrue(controller.view.superview === owner.view)
        XCTAssertFalse(window.nativeWindow.isVisible)
        runtime.ack()
        XCTAssertFalse(host.isRunning)
        var channel = try host.snapshotChannel()
        channel.instrument?.state = Data([8]) // genuine restore requires another Q retirement
        host.apply(channel)
        try host.start()
        XCTAssertEqual(graph.starts, 1, "Start during retire must wait for Q ack")
        runtime.ack(1)
        XCTAssertEqual(graph.starts, 2)
        XCTAssertTrue(host.instrument === instance)
        XCTAssertTrue(instance.window === window)
        XCTAssertTrue(controller.parent === owner)
        XCTAssertEqual(unit.editorRequests, 1)
        host.shutdown(); runtime.ack(2)
        graph.reportFadeReached()
        try await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertNil(controller.parent)
        XCTAssertNil(window.nativeWindow.contentViewController)
        XCTAssertNil(window.nativeWindow.contentView)
    }
}
