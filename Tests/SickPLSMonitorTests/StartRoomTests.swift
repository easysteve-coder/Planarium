import AppKit
import SwiftUI
import XCTest
import Dispatch
@testable import PlanariumApplication
import PlanariumDomain
import PlanariumInput
import PlanariumRuntime
import SickPLSCore
import SickPLSCommissioning
import SickPLSActiveControl
import SickPLSMonitorKit
import SickPLSCommissioningControl
import SickPLSSetupControl
import SickPLSMacTransport
@testable import SickPLSMonitor

/// Schedules use the real queue contract, but time advances only by the test.
private final class RoomManualClock: RuntimeClock, @unchecked Sendable {
    private struct Tick { let id: UUID; let time: Double; let queue: DispatchQueue; let action: @Sendable () -> Void }
    private let lock = NSLock()
    private var time: Double = 10
    private var ticks: [Tick] = []
    private var tolerances: [Double] = []
    var scheduledTolerances: [Double] { lock.lock(); defer { lock.unlock() }; return tolerances }
    func scheduleCoalescible(at deadline: Double, tolerance: Double, on queue: DispatchQueue, _ action: @escaping @Sendable () -> Void) -> RuntimeCancellation {
        lock.lock(); tolerances.append(tolerance); lock.unlock()
        return schedule(at: deadline, on: queue, action)
    }
    var now: Double { lock.lock(); defer { lock.unlock() }; return time }
    func schedule(at deadline: Double, on queue: DispatchQueue, _ action: @escaping @Sendable () -> Void) -> RuntimeCancellation {
        let id = UUID()
        lock.lock(); ticks.append(.init(id: id, time: deadline, queue: queue, action: action)); lock.unlock()
        return .init { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.ticks.removeAll { $0.id == id }; self.lock.unlock()
        }
    }
    func advance(to value: Double) {
        lock.lock(); time = value
        let due = ticks.filter { $0.time <= value }
        ticks.removeAll { $0.time <= value }; lock.unlock()
        due.forEach { $0.queue.async(execute: $0.action) }
    }
}

@MainActor final class StartRoomTests: XCTestCase {
    private func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    func testSceneUSBWatchUsesSharedSetupRouteAndStopsWatchingOnCancellation() throws {
        for initial in [[], ["/dev/cu.usbserial-A"], ["/dev/cu.usbserial-B", "/dev/cu.usbserial-A"]] {
            let clock = RoomManualClock(), fixture = try MonitorRootFixture(clock: clock)
            let layout = try LayoutWorkspaceFixture(fixture: fixture)
            defer { layout.cleanDefaults(); fixture.root.terminate {} }
            let listing = MutableUSBListing(), opener = OfflineSetupOpener()
            listing.paths = ["/dev/cu.Bluetooth-Incoming-Port"] + initial
            let connection = StandardConnectionControlModel(coordinator: fixture.root.input, runProvider: ImageNoRuns(),
                portListing: listing, releaseOutputs: { completion in completion() })
            let setup = SetupConsoleModel(opener: opener)
            let changes = ManualUSBChanges()
            let watch = ScannerUSBStartupMonitor(connection: connection, setup: setup, simulation: layout.view.simulation, clock: clock, changes: changes)
            watch.start(); watch.start()
            let deadline = Date().addingTimeInterval(3)
            while (connection.deviceSetupActive || setup.isBusy), Date() < deadline { drain() }
            XCTAssertFalse(connection.deviceSetupActive)
            XCTAssertEqual(opener.paths, initial.sorted())
            XCTAssertEqual(fixture.root.input.portOwner, .free)
            if initial.isEmpty { XCTAssertEqual(connection.notice, StandardConnectionControlModel.noUSBAdapterNotice) }
            listing.paths.append("/dev/cu.usbmodem-LATER")
            clock.advance(to: 11); changes.changed?(); drain()
            let nextDeadline = Date().addingTimeInterval(3)
            while (connection.deviceSetupActive || setup.isBusy), Date() < nextDeadline { drain() }
            XCTAssertEqual(opener.paths, initial.sorted() + (["/dev/cu.usbmodem-LATER"] + initial).sorted())
            listing.paths.append("/dev/cu.usbserial-STOPPED")
            if initial.count == 1 { clock.advance(to: 20); watch.stop() }
            else { watch.stop(); clock.advance(to: 20) }
            drain()
            XCTAssertFalse(opener.paths.contains("/dev/cu.usbserial-STOPPED"))
        }
    }
    func testUSBNotificationCancellationGenerationAndFallbackLeeway() throws {
        for notificationsAvailable in [false, true] {
            let clock = RoomManualClock(), fixture = try MonitorRootFixture(clock: clock), layout = try LayoutWorkspaceFixture(fixture: fixture)
            defer { layout.cleanDefaults(); fixture.root.terminate {} }
            let listing = MutableUSBListing()
            let connection = StandardConnectionControlModel(coordinator: fixture.root.input, runProvider: ImageNoRuns(), portListing: listing)
            let changes = ManualUSBChanges(); changes.available = notificationsAvailable
            let watch = ScannerUSBStartupMonitor(connection: connection, setup: layout.view.scannerSetup, simulation: layout.view.simulation, clock: clock, changes: changes)
            let beforeRegistration = listing.calls
            changes.onStart = { XCTAssertEqual(listing.calls, beforeRegistration, "Install notifications before the first listing") }
            watch.start(); changes.onStart = nil
            if notificationsAvailable { XCTAssertTrue(clock.scheduledTolerances.isEmpty) }
            else { XCTAssertEqual(clock.scheduledTolerances, [0.2]) }
            let old = changes.changed
            if notificationsAvailable { old?() } else { clock.advance(to: 11); drain() }
            watch.stop()
            let count = listing.calls
            old?(); clock.advance(to: 20); drain()
            XCTAssertEqual(listing.calls, count, "Neither a queued notification nor a queued poll may restart after stop")
            watch.start(); let restarted = listing.calls
            old?(); drain()
            XCTAssertEqual(listing.calls, restarted, "Previous generation cannot operate a restarted monitor")
            watch.stop()
        }
    }
    private func profile(count: Int = 90, distance: UInt16 = 200, session: UUID, sequence: UInt64, time: Double) throws -> ProfileFrame {
        let raw = try B0ScanProfile.build(partialScanIndex: 0, measurements: (0..<count).map { _ in try .build(value: distance, fieldFlags: 0) })
        return .init(sessionID: session, sequence: sequence, time: time,
            measurements: try FullScanProfileAdapter.measurements(from: raw), geometry: try FullScanProfileAdapter.geometry(from: raw), rawProfile: raw)
    }
    private func deliver(_ profile: ProfileFrame, to fixture: MonitorRootFixture) throws {
        fixture.root.runtime.frame(profile)
        let done = expectation(description: "Actual runtime frame")
        fixture.root.runtime.acknowledge { done.fulfill() }; wait(for: [done], timeout: 5)
        let frame = try XCTUnwrap(fixture.root.runtime.mailbox.read())
        fixture.root.document.noteDisplay(frame)
        fixture.root.document.roomCapture.receive(.frame(profile))
        waitCapture(fixture.root.document)
    }
    func testCountdownRejectsEarlyAndDelayedOldProfilesThenCapturesExactly125() throws {
        for count in [90, 361] {
            let clock = RoomManualClock(), fixture = try MonitorRootFixture(clock: clock), owner = fixture.root.document
            defer { fixture.root.terminate {} }
            let session = UUID(); fixture.root.runtime.sessionBegan(session)
            owner.beginRoomContourCapture()
            XCTAssertEqual(owner.contourCapture.countdownSeconds, 3)
            try deliver(profile(count: count, distance: 20, session: session, sequence: 1, time: 10.9), to: fixture)
            XCTAssertEqual(owner.roomContourCaptureProgress, 0)
            clock.advance(to: 11); drain(); XCTAssertEqual(owner.contourCapture.countdownSeconds, 2)
            clock.advance(to: 12); drain(); XCTAssertEqual(owner.contourCapture.countdownSeconds, 1)
            try deliver(profile(count: count, distance: 20, session: session, sequence: 2, time: 12.999), to: fixture)
            XCTAssertEqual(owner.roomContourCaptureProgress, 0)
            clock.advance(to: 13); drain(); XCTAssertNil(owner.contourCapture.countdownSeconds)
            // Main was delayed: receipt time, not delivery time, decides admission.
            try deliver(profile(count: count, distance: 20, session: session, sequence: 3, time: 12.9999), to: fixture)
            XCTAssertEqual(owner.roomContourCaptureProgress, 0)
            for index in 0..<125 {
                try deliver(profile(count: count, session: session, sequence: UInt64(index + 4), time: 13 + Double(index) * 0.04), to: fixture)
                XCTAssertEqual(owner.roomContourCaptureProgress, Double((index + 1) * 100 / 125) / 100, accuracy: 1e-9)
                XCTAssertEqual(owner.isCapturingRoomContour, index < 124)
            }
            XCTAssertEqual(try XCTUnwrap(owner.roomContour).nearestDistancesCentimeters, Array(repeating: UInt16(200), count: count))
            XCTAssertEqual(owner.contourCapture.targetProfileCount, 125)
        }
    }
    func testInputFailureCancelsWithoutAnyDisplayReaderInCountdownAndRecording() throws {
        for recording in [false, true] {
            let clock = RoomManualClock(), fixture = try MonitorRootFixture(clock: clock), owner = fixture.root.document
            defer { fixture.root.terminate {} }
            let source = HeldFailedStream()
            XCTAssertEqual(fixture.root.input.connectSimulation(serviceName: "Offline failed stream", opener: source), .connecting)
            owner.beginRoomContourCapture()
            if recording {
                clock.advance(to: 13)
                let value = try profile(session: try XCTUnwrap(fixture.root.input.session.sessionID), sequence: 1, time: clock.now)
                owner.roomCapture.receive(.frame(value))
                waitCapture(owner)
                XCTAssertEqual(owner.roomContourCaptureProgress, 0)
            }
            source.release.signal()
            let deadline = Date().addingTimeInterval(3)
            while owner.isCapturingRoomContour, Date() < deadline { drain() }
            XCTAssertFalse(owner.isCapturingRoomContour)
            XCTAssertEqual(owner.contourCapture.notice, "Capture cancelled: scanner input lost")
            XCTAssertNil(owner.contourCapture.countdownSeconds)
        }
    }
    func testCancellationMatrixPreservesPreviousContourAndStaleTicksCannotRestart() throws {
        for phase in ["countdown", "recording"] {
            for cause in ["button", "escape", "loss", "preset", "perform", "session", "geometry"] {
                let clock = RoomManualClock(), fixture = try MonitorRootFixture(clock: clock), owner = fixture.root.document
                defer { fixture.root.terminate {} }
                let session = UUID(); fixture.root.runtime.sessionBegan(session)
                let contour = SpatialRoomContour(geometry: .init(pointCount: 90, angleResolutionDegrees: 180 / 89, startAngleDegrees: -90, sourceIdentifier: "scanner:default"),
                    nearestDistancesCentimeters: Array(repeating: 300, count: 90), spreadCentimeters: Array(repeating: 0, count: 90))
                fixture.root.runtime.roomContour(contour)
                try deliver(profile(session: session, sequence: 1, time: 10), to: fixture)
                owner.beginRoomContourCapture()
                if phase == "recording" {
                    clock.advance(to: 13); drain()
                    try deliver(profile(session: session, sequence: 2, time: 13), to: fixture)
                }
                switch cause {
                case "button": RoomContourCaptureButton(capture: owner.contourCapture, instrument: owner).toggleCapture()
                case "escape":
                    let cells = SpatialActiveCellDisplayModel()
                    let view = CartesianScanFieldView(editor: owner.canvas, profile: nil, activeCellDisplay: cells,
                        spatialInstrument: owner, simulationBadge: AnyView(EmptyView()))
                    let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
                    XCTAssertTrue(view.handleCanvasKey(event, canvasSize: .init(width: 740, height: 900)))
                case "loss":
                    fixture.root.runtime.sessionEnded(session)
                    let done = expectation(description: "Input loss"); fixture.root.runtime.acknowledge { done.fulfill() }; wait(for: [done], timeout: 5)
                    owner.roomCapture.receive(.ended(session, reason: .failure))
                    waitCapture(owner)
                case "preset": try owner.applyPresetDocument(owner.document, restoringPluginStates: false)
                case "perform": owner.canvas.setPerformanceLocked(true)
                case "session":
                    let next = UUID(); fixture.root.runtime.sessionBegan(next)
                    try deliver(profile(session: next, sequence: 1, time: clock.now), to: fixture)
                case "geometry": try deliver(profile(count: 361, session: session, sequence: 3, time: clock.now), to: fixture)
                default: XCTFail("Unknown test cause")
                }
                XCTAssertFalse(owner.isCapturingRoomContour, "\(phase) / \(cause)")
                XCTAssertEqual(owner.roomContour, contour, "\(phase) / \(cause)")
                XCTAssertTrue(owner.contourCapture.notice?.hasPrefix("Capture cancelled") == true)
                XCTAssertNil(owner.contourCapture.countdownSeconds)
                clock.advance(to: 20); drain()
                XCTAssertFalse(owner.isCapturingRoomContour)
            }
        }
    }
    func testPerformAllowsNewCaptureAndLateOldCountdownCannotChangeNextCapture() throws {
        let clock = RoomManualClock(), fixture = try MonitorRootFixture(clock: clock), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        owner.canvas.setPerformanceLocked(true)
        owner.beginRoomContourCapture(); XCTAssertTrue(owner.isCapturingRoomContour)
        clock.advance(to: 12) // callbacks queued but not delivered
        owner.cancelRoomContourCapture(); owner.beginRoomContourCapture()
        drain(); XCTAssertEqual(owner.contourCapture.countdownSeconds, 3)
        clock.advance(to: 13); drain(); XCTAssertEqual(owner.contourCapture.countdownSeconds, 2)
        owner.canvas.setPerformanceLocked(false)
        XCTAssertFalse(owner.isCapturingRoomContour)
        XCTAssertEqual(owner.contourCapture.notice, "Capture cancelled: performance mode changed")
    }
    func testEscapeCancelsWithControlFocusOnlyInRegisteredInstrumentWindow() throws {
        let clock = RoomManualClock(), fixture = try MonitorRootFixture(clock: clock), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        let monitor = TempoTapShortcutMonitor(tap: {}, cancelCapture: {
            guard owner.isCapturingRoomContour else { return false }
            owner.cancelRoomContourCapture(); return true
        })
        defer { monitor.stop() }
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 280, height: 180), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        monitor.register(try XCTUnwrap(window.contentView))
        let field = NSTextField(frame: .init(x: 0, y: 0, width: 240, height: 30))
        window.contentView?.addSubview(field); XCTAssertTrue(window.makeFirstResponder(field))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        owner.beginRoomContourCapture()
        XCTAssertNotNil(monitor.handle(event, keyWindow: nil, modalWindow: nil))
        XCTAssertTrue(owner.isCapturingRoomContour)
        XCTAssertNotNil(monitor.handle(event, keyWindow: window, modalWindow: window))
        XCTAssertTrue(owner.isCapturingRoomContour)
        XCTAssertNil(monitor.handle(event, keyWindow: window, modalWindow: nil))
        XCTAssertFalse(owner.isCapturingRoomContour)
        XCTAssertNotNil(monitor.handle(event, keyWindow: window, modalWindow: nil))
    }
    func testCountdownAndPortListsRenderWideAndNarrowOffline() throws {
        let clock = RoomManualClock(), fixture = try MonitorRootFixture(clock: clock), owner = fixture.root.document
        let layout = try LayoutWorkspaceFixture(fixture: fixture)
        defer { layout.cleanDefaults(); fixture.root.display.stop(); fixture.root.terminate {} }
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = UUID(); fixture.root.runtime.sessionBegan(session)
        try deliver(profile(session: session, sequence: 1, time: clock.now), to: fixture)
        fixture.root.display.read()
        owner.beginRoomContourCapture()
        var sequence: UInt64 = 1
        for second in [3, 2, 1] {
            if second != 3 {
                let target = 13 - Double(second)
                // Keep the fake scanner live at 25 Hz while the clock advances.
                // A one-second jump without input correctly trips runtime loss.
                while clock.now < target {
                    clock.advance(to: min(target, clock.now + 0.04)); sequence += 1
                    try deliver(profile(session: session, sequence: sequence, time: clock.now), to: fixture)
                }
                fixture.root.display.read(); drain()
            }
            for width in [1728, 1024] { try render(layout.view, width: width, height: 1000, name: "room-countdown-\(second)-\(width)", directory: directory) }
            XCTAssertEqual(owner.contourCapture.countdownSeconds, second)
            XCTAssertEqual(owner.contourCapture.notice, "Hands out · \(second)")
            for width in [420, 280] {
                try render(VStack(alignment: .leading) {
                    Text("Room").font(.headline)
                    RoomContourCaptureButton(capture: owner.contourCapture, instrument: owner)
                    RoomContourCaptureStatus(capture: owner.contourCapture, contour: nil)
                }.padding(), width: width, height: 180, name: "room-module-\(second)-\(width)", directory: directory)
            }
            if second == 3 {
                for width in [740, 380] {
                    try render(CartesianScanFieldView(editor: owner.canvas, profile: nil, activeCellDisplay: SpatialActiveCellDisplayModel(),
                        spatialInstrument: owner, simulationBadge: AnyView(EmptyView()), detectionInitiallyExpanded: true),
                        width: width, height: 1200, name: "room-detection-\(width)", directory: directory)
                }
            }
        }
        layout.workspace.togglePerformance(canvas: owner.canvas)
        owner.beginRoomContourCapture()
        XCTAssertTrue(owner.isCapturingRoomContour)
        for width in [1728, 1024] {
            try render(layout.view, width: width, height: 1000, name: "room-countdown-perform-\(width)", directory: directory)
        }
        XCTAssertEqual(owner.contourCapture.countdownSeconds, 3)
        owner.cancelRoomContourCapture()
        layout.workspace.togglePerformance(canvas: owner.canvas)
        let connection = StandardConnectionControlModel(coordinator: fixture.root.input, runProvider: ImageNoRuns(), portListing: ImagePorts())
        connection.refreshPorts()
        for all in [false, true] {
            connection.showsAllPorts = all
            for width in [420, 280] {
                try render(VStack(alignment: .leading, spacing: 12) {
                    ConnectionBarView(model: connection, scannerSetup: layout.view.scannerSetup)
                    Divider()
                    ScannerPortListView(model: connection)
                }.padding(), width: width, height: 420, name: "usb-ports-all-\(all)-\(width)", directory: directory)
            }
        }
    }
    private func render(_ view: some View, width: Int, height: Int, name: String, directory: URL) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark).foregroundColor(.white).background(StageTheme.workspace))
        host.appearance = NSAppearance(named: .darkAqua); host.wantsLayer = true
        host.frame = .init(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded(); drain(); host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }
}
private struct ImagePorts: SerialPortListing {
    func availablePortPaths() -> [String] { ["/dev/cu.Bluetooth-Incoming-Port", "/dev/cu.debug-console", "/dev/cu.JBLTUNE520BT", "/dev/cu.POST", "/dev/cu.PRE", "/dev/cu.usbserial-BG03R8Q4"] }
}
private final class MutableUSBListing: SerialPortListing {
    var paths: [String] = []
    private(set) var calls = 0
    func availablePortPaths() -> [String] { calls += 1; return paths }
}
private final class HeldFailedStream: ScanByteStreamOpening, @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    func openStream() throws -> SerialPortFileDescriptor {
        _ = release.wait(timeout: .now() + 3)
        throw ScanByteStreamOpenError.unreachable
    }
}
private final class OfflineSetupOpener: ActiveControlSerialPortOpener, @unchecked Sendable {
    private let lock = NSLock()
    private var attempts: [String] = []
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return attempts }
    func open(atPath path: String, baudRate: SerialPortBaudRate) throws -> ActiveControlSerialPort {
        lock.lock(); attempts.append(path); lock.unlock()
        throw NSError(domain: "OfflineSetupOpener", code: 1)
    }
}
private struct ImageNoRuns: StandardConnectionRunProviding {
    func makeRun(portPath: String, measurementMode: ScannerMeasurementMode, onProgress: @escaping StandardConnectionProgressHandler) throws -> StandardConnectionRun {
        XCTFail("Offline rendering must not start a connection")
        throw NSError(domain: "ImageNoRuns", code: 1)
    }
}

@MainActor private func waitCapture(_ owner: SpatialInstrumentRuntimeModel) {
    let done = DispatchSemaphore(value: 0)
    owner.roomCapture.acknowledge { done.signal() }
    XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
    RunLoop.main.run(until: Date().addingTimeInterval(0.001))
}

@MainActor private final class ManualUSBChanges: ScannerUSBChangeWatching {
    var changed: (() -> Void)?
    var available = true
    var onStart: (() -> Void)?
    func start(_ changed: @escaping @MainActor @Sendable () -> Void) -> Bool { self.changed = changed; onStart?(); return available }
    func stop() { changed = nil }
}
