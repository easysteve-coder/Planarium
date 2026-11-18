import PlanariumAudio
import PlanariumDomain
import PlanariumRuntime
import AppKit
import Combine
import SwiftUI
import PlanariumApplication
import SickPLSCore
import SickPLSControlCore
import SickPLSMonitorKit
import PlanariumPresets
import PlanariumMIDI
import XCTest
@testable import SickPLSMonitor

private final class ProbeOutput: MIDISendBoundary, AUScheduleBoundary, @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [[UInt8]] = []
    var sent: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return messages }
    func send(bytes: [UInt8]) -> PortSendResult {
        lock.lock(); defer { lock.unlock() }; messages.append(bytes); return .sent
    }
    func scheduleMIDI(bytes: [UInt8]) -> PortSendResult { send(bytes: bytes) }
    func scheduleParameter(_ target: SpatialAudioUnitParameterTarget, normalizedValue: Double) -> PortSendResult {
        XCTFail("The probe must never send AU parameters"); return .sent
    }
}

@MainActor private final class ProbeMIDI: MIDIConnectionBoundary {
    var onDestinationLost: (@MainActor () -> Void)?
    let output = ProbeOutput()
    func destinations() -> [MIDITargetDescription] { [.init(id: 1, name: "Offline probe output")] }
    func open(_ target: InstrumentMIDITarget) -> Result<any MIDISendBoundary, MIDIConnectionError> { .success(output) }
    func close() {}
}

private struct ProbeClock: RuntimeClock {
    let now: Double = 0
    func schedule(at deadline: Double, on queue: DispatchQueue, _ fire: @escaping @Sendable () -> Void) -> RuntimeCancellation {
        RuntimeCancellation {}
    }
}

@MainActor
final class InspectorTrackingTests: XCTestCase {
    func testAuditionNativePressDragReleaseToolFocusAndDeactivateWideNarrow() throws {
        _ = NSApplication.shared
        for width in [900, 360] {
            let midi = ProbeMIDI(), fixture = try MonitorRootFixture(clock: ProbeClock(), midi: midi), owner = fixture.root.document
            defer { fixture.root.terminate {} }
            owner.selectMIDITarget(.init(uniqueID: 1))
            let cells = [PolarMetricGridCell(ring: 3, angularIndex: 16), .init(ring: 4, angularIndex: 16), .init(ring: 5, angularIndex: 16)]
            let target = SpatialRoutingTarget.midiNote(channel: 0)
            owner.canvas.updateWorkspace { workspace in
                workspace.updateSelectedLayer { layer in
                    layer.polarCells = Set(cells)
                    layer.routings = [.init(target: target, program: .singleNote(note: 60, velocity: 90, transition: .legato))]
                }
            }
            owner.canvas.updateWorkspace { workspace in
                workspace.updateSelectedLayer { layer in
                    layer.polarCellOverrides = [cells[1]: [.init(target: target, value: .note(number: 62, velocity: 90))],
                                               cells[2]: [.init(target: target, value: .note(number: 64, velocity: 90))]]
                }
            }
            owner.canvas.updateWorkspace { _ = $0.addScene(name: "Audition scene") }
            owner.canvas.select(tool: .audition)
            let host = NSHostingView(rootView: CartesianScanFieldView(editor: owner.canvas, profile: nil,
                activeCellDisplay: SpatialActiveCellDisplayModel(), spatialInstrument: owner, simulationBadge: AnyView(EmptyView()))
                .environment(\.colorScheme, .dark).preferredColorScheme(.dark))
            host.appearance = NSAppearance(named: .darkAqua)
            let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: width, height: 1000),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            defer { window.close() }
            host.frame = .init(x: 0, y: 0, width: width, height: 1000)
            func pump() { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.03)); host.layoutSubtreeIfNeeded() }
            func flush() {
                let done = expectation(description: "Audition Q barrier")
                fixture.root.runtime.acknowledge { done.fulfill() }
                wait(for: [done], timeout: 5); pump()
            }
            pump()
            func pointer(_ view: NSView) -> ScanFieldPointerEvents.PointerView? {
                if let found = view as? ScanFieldPointerEvents.PointerView, !found.isKeyboardOnly { return found }
                return view.subviews.compactMap(pointer).first
            }
            let native = try XCTUnwrap(pointer(host))
            owner.canvas.select(tool: .select)
            let keyP = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "p",
                charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35))
            XCTAssertTrue(native.onKeyCommand?(keyP) == true); XCTAssertEqual(owner.canvas.tool, .audition); pump()
            func gesture(_ phase: NSEvent.EventType, _ cell: PolarMetricGridCell) {
                let area = PolarMetricCellSegment(cell: cell, grid: owner.canvas.workspace.grid)
                let metric = area.point(radiusMeters: area.midpoint.radiusMeters, bearingDegrees: area.midpoint.bearingDegrees)
                let point = owner.canvas.displayGeometry(canvasSize: native.bounds.size).screenPoint(for: metric)
                native.onPrimaryDrag?(phase, point, []); flush()
            }
            var documentPublications = 0
            let observation = owner.objectWillChange.sink { documentPublications += 1 }
            gesture(.leftMouseDown, cells[0])
            XCTAssertTrue(midi.output.sent.contains { $0 == [0x90, 60, 90] })
            gesture(.leftMouseDragged, cells[1]); gesture(.leftMouseDragged, cells[2])
            XCTAssertEqual(midi.output.sent.filter { $0.first == 0x90 }.suffix(3).map { $0[1] }, [60, 62, 64])
            let directory = TestImageDirectory.make(); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("audition-\(width).png"))
            gesture(.leftMouseUp, cells[2]); XCTAssertNil(owner.auditionPoint)
            XCTAssertTrue(midi.output.sent.contains { $0 == [0x80, 64, 0] })
            XCTAssertEqual(documentPublications, 0, "Pointer presentation belongs to CanvasSession")
            observation.cancel()
            for release in ["deactivate", "focus", "tool", "hand", "panic", "perform", "escape", "scene", "preset", "stop"] {
                owner.canvas.setPerformanceLocked(false); owner.canvas.holdHand(false); owner.canvas.select(tool: .audition)
                gesture(.leftMouseDown, cells[0]); XCTAssertNotNil(owner.auditionPoint)
                let before = midi.output.sent.count
                switch release {
                case "deactivate": NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
                case "focus": native.onFocusLost?()
                case "tool": owner.canvas.select(tool: .select)
                case "hand": owner.canvas.holdHand(true)
                case "panic": owner.panicAll()
                case "perform": owner.canvas.setPerformanceLocked(true)
                case "escape":
                    let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "",
                        charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53))
                    XCTAssertTrue(native.onKeyCommand?(key) == true)
                case "scene": owner.selectScene(try XCTUnwrap(owner.document.scenes.first?.id))
                case "preset": try owner.applyPresetDocument(owner.document)
                case "stop": owner.stopSpatialMode()
                default: XCTFail("Unknown release")
                }
                flush(); XCTAssertNil(owner.auditionPoint)
                XCTAssertTrue(midi.output.sent.dropFirst(before).contains { $0[0] == 0x80 && $0[1] == 60 }, release)
                owner.audition(nil); flush()
            }
        }
    }

    func testProgramChangeInspectorsRenderWideNarrowEditAndPerform() throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        defer {
            var done = false; fixture.root.terminate { done = true }
            let deadline = Date().addingTimeInterval(3)
            while !done, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
            XCTAssertTrue(done)
        }
        owner.canvas.updateWorkspace { workspace in
            workspace.updateSelectedLayer {
                $0.name = "Effect programs"
                $0.polarCells = [.init(ring: 3, angularIndex: 8)]
                $0.routings = [.init(target: .midiProgramChange(channel: 15),
                    program: .programChange(.init(program: 127, countsFromOne: true, bankMSB: 2, bankLSB: 3)))]
            }
        }
        let audio = AudioCatalogModel(document: owner, source: EmptyCatalog())
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cell = PolarMetricGridCell(ring: 3, angularIndex: 8), size = CGSize(width: 800, height: 800)
        let center = SpatialFieldPlan.center(.init(cell: cell, grid: owner.canvas.workspace.grid))
        let point = MetricCanvasGeometry(size: size, viewport: owner.canvas.viewport).screenPoint(for: .init(xMeters: center.x, yMeters: center.y))
        _ = owner.canvas.selectCell(atScreenPoint: point, canvasSize: size)
        XCTAssertEqual(owner.canvas.selectedPolarCell, cell)
        for banks in [false, true] {
            owner.canvas.setPerformanceLocked(false)
            owner.canvas.updateWorkspace { workspace in
                workspace.updateSelectedLayer { layer in
                    layer.routings[0].program = .programChange(.init(program: 127, countsFromOne: true,
                        bankMSB: banks ? 127 : nil, bankLSB: banks ? 0 : nil))
                    layer.polarCellOverrides[cell] = [.init(target: layer.routings[0].target,
                        value: .programChange(.init(program: 0, countsFromOne: false,
                            bankMSB: banks ? 0 : nil, bankLSB: banks ? 127 : nil)))]
                }
            }
            for perform in [false, true] {
                owner.canvas.setPerformanceLocked(perform)
                for width in [360, 600] {
                    try render(LayerInspectorView(editor: owner.canvas, audioUnits: audio, midiOutput: fixture.root.midi,
                        spatialInstrument: owner, evaluationCounter: nil), width: CGFloat(width), height: 850,
                        name: "pc-nummer-layer-bank-\(banks)-\(perform ? "perform" : "edit")-\(width).png", in: directory, darkAppearance: true)
                    try render(CellInspectorView(editor: owner.canvas), width: CGFloat(width), height: 600,
                        name: "pc-nummer-cell-bank-\(banks)-\(perform ? "perform" : "edit")-\(width).png", in: directory, darkAppearance: true)
                }
            }
        }
    }
    private final class ProfileTick: ObservableObject {
        @Published var value = 0
    }

    private struct Harness: View {
        @ObservedObject var tick: ProfileTick
        @StateObject var editor: CanvasSession
        let audioUnits: AudioCatalogModel
        let midiOutput: MIDIPortOwner
        let spatialInstrument: SpatialInstrumentRuntimeModel
        let counter: InspectorEvaluationCounter

        init(
            tick: ProfileTick,
            state: MetricCanvasInteractionState = MetricCanvasInteractionState(),
            audioUnits: AudioCatalogModel,
            midiOutput: MIDIPortOwner,
            spatialInstrument: SpatialInstrumentRuntimeModel,
            counter: InspectorEvaluationCounter
        ) {
            self.tick = tick
            _editor = StateObject(wrappedValue: CanvasSession(state: state))
            self.audioUnits = audioUnits
            self.midiOutput = midiOutput
            self.spatialInstrument = spatialInstrument
            self.counter = counter
        }

        var body: some View {
            let _ = tick.value
            StableSpatialLayerInspectorView(
                editor: editor,
                audioUnits: audioUnits,
                midiOutput: midiOutput,
                spatialInstrument: spatialInstrument,
                evaluationCounter: counter
            )
            .equatable()
        }
    }

    private struct StripHarness: View {
        @State private var master = 0.7
        @State private var selectedEntry: ChannelStripEntry = .audioOutput
        @State private var channelName = "PLANARIUM"
        @State private var channelColor = Color.blue
        let audioDevices: AudioOutputDeviceControlModel

        var body: some View {
            HelmutStripSurface(
                master: $master, selectedEntry: $selectedEntry, audioIsRunning: false,
                audioSummary: "gestoppt", midiSummary: "aus", effectSlots: [],
                audioUnitEffects: [], audioUnitInstruments: [], selectedAudioUnitInstrument: nil,
                isMuted: false, isSoloed: false, toggleMute: {}, toggleSolo: {},
                instrumentIsOn: false, instrumentPreparation: .empty, instrumentCanToggle: false,
                toggleInstrument: {}, selectAudioUnitInstrument: { _ in },
                openAudioUnitInstrument: { _ in }, assignEffect: { _, _ in },
                toggleEffect: { _ in }, openEffect: { _ in },
                outputLeftPeak: { 0 }, outputRightPeak: { 0 },
                channelName: $channelName, channelColor: $channelColor,
                pan: 0, setPan: { _ in }, midiDestinations: nil,
                selectedMIDIDestinationID: nil, selectMIDIDestination: { _ in },
                refreshMIDIDestinations: {}, midiNotice: nil, audioDevices: audioDevices
            )
        }
    }

    private struct DetectionHarness: View {
        @StateObject var editor: CanvasSession
        let profile: B0ScanProfile
        var contour: SpatialRoomContour? = nil
        var matches = true
        var expanded = false
        var stagePreview = false
        var forceProbe = false
        var forceOverlay: DetectionOverlayControl? = nil
        var scannerFlags = false
        let cells = SpatialActiveCellDisplayModel()
        let preview = DetectionCanvasPreview()
        @ObservedObject var spatialInstrument: SpatialInstrumentRuntimeModel

        init(
            state: MetricCanvasInteractionState,
            profile: B0ScanProfile,
            contour: SpatialRoomContour? = nil, matches: Bool = true, expanded: Bool = false, forceProbe: Bool = false,
            spatialInstrument: SpatialInstrumentRuntimeModel, forceOverlay: DetectionOverlayControl? = nil,
            stagePreview: Bool = false, scannerFlags: Bool = false, selection: DeviceLatticeSelection? = nil
        ) {
            _editor = StateObject(wrappedValue: CanvasSession(state: state))
            self.profile = profile
            if let selection {
                let frame = ProfileFrame(sessionID: UUID(), sequence: 2, time: 0.08,
                    measurements: try! FullScanProfileAdapter.measurements(from: profile), rawProfile: profile)
                // Keep the authored surface background fixed across regulator pairs.
                // Only the actual confirmation evidence is varied in this replay.
                let display = DeviceLatticeSelection(activeHandles: [:],candidateDistancesCentimeters: [:],
                    confirmationProgress: selection.confirmationProgress)
                cells.update(.init(profile: frame, selection: display), workspace: spatialInstrument.canvas.workspace)
            } else { cells.update(profile: profile, activeCells: [:]) }
            self.contour = contour; self.matches = matches; self.expanded = expanded; self.forceProbe = forceProbe
            self.forceOverlay = forceOverlay
            self.stagePreview = stagePreview
            self.scannerFlags = scannerFlags
            self.spatialInstrument = spatialInstrument
            spatialInstrument.noteDisplay(.init(contour: contour, selection: .init(activeHandles: [:], candidateDistancesCentimeters: [:], contourMatches: matches)))
        }

        var body: some View {
            CartesianScanFieldView(
                editor: editor,
                profile: profile,
                activeCellDisplay: cells,
                spatialInstrument: spatialInstrument,
                simulationBadge: AnyView(Text("SIM").font(.caption2)),
                scannerFlagBits: .constant(scannerFlags),
                detectionInitiallyExpanded: expanded, detectionStagePreview: stagePreview,
                forceDetectionProbe: forceProbe, forceDetectionOverlay: forceOverlay, detectionPreview: preview
            )
            .padding(10)
            .background(StageTheme.canvas)
            .preferredColorScheme(.dark)
        }
    }

    func testRawScanUniformFlagsAndOverlayRenderWideAndNarrow90And361() throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for count in [90, 361] {
            let profile = try B0ScanProfile.build(partialScanIndex: 0, measurements: (0..<count).map { index in
                try .build(value: abs(index - count / 2) < 3 ? 90 : 180,
                           fieldFlags: UInt8(index % 8))
            })
            for style in ["uniform", "flags", "overlay"] {
                for width in [740, 380] {
                    let view = DetectionHarness(state: .init(), profile: profile, spatialInstrument: owner,
                        forceOverlay: style == "overlay" ? .minimumPoints : nil, scannerFlags: style == "flags")
                    try render(view, width: CGFloat(width), height: 700,
                        name: "budget-raw-\(count)-\(style)-\(width).png", in: directory,
                        background: StageTheme.canvas, darkAppearance: true)
                }
            }
        }
    }

    func testLiveProfileTickDoesNotReevaluateInspectorBody() {
        let fixture = try! MonitorRootFixture()
        let spatialInstrument = fixture.root.document
        let audioUnits = AudioCatalogModel(document: spatialInstrument, source: EmptyCatalog())
        let midiOutput = fixture.root.midi
        let counter = InspectorEvaluationCounter()
        let tick = ProfileTick()
        let host = NSHostingView(rootView: Harness(
            tick: tick,
            audioUnits: audioUnits,
            midiOutput: midiOutput,
            spatialInstrument: spatialInstrument,
            counter: counter
        ))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 500)
        host.layoutSubtreeIfNeeded()
        pumpMainRunLoop(for: 0.5)
        let before = counter.count

        tick.value += 1
        pumpMainRunLoop(for: 0.05)

        XCTAssertGreaterThanOrEqual(before, 1)
        XCTAssertEqual(counter.count, before)
    }

    func testKeyboardLabelsStaySingleLineAtInspectorWidth() {
        let expected = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
        for pitchClass in 0..<12 {
            let note = 60 + pitchClass
            let label = PianoKeyboardModel.keyLabel(for: note, selected: true, keyWidth: 12)
            XCTAssertEqual(label, expected[pitchClass])
            XCTAssertFalse(label.contains("\n"))
            XCTAssertEqual(PianoKeyboardModel.keyLabel(for: note, selected: true, keyWidth: 30),
                           PianoKeyboardModel.displayName(for: note))
        }
    }

    @MainActor
    func testInspectorRendersWideAndNarrowScaleAndChordProofImages() throws {
        let fixture = try! MonitorRootFixture()
        let spatialInstrument = fixture.root.document
        let audioUnits = AudioCatalogModel(document: spatialInstrument, source: EmptyCatalog())
        let midiOutput = fixture.root.midi
        let runDirectory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)

        for (name, program) in [
            ("inspector-scale", SpatialValueProgram.scale(
                rootMIDINote: 60, lowestMIDINote: 48, highestMIDINote: 84,
                scale: .major, directionDegrees: 90, ascending: true, transition: .legato
            )),
            ("inspector-chord", SpatialValueProgram.chord(
                notes: [60, 64, 67], velocity: 100, transition: .retrigger
            ))
        ] {
            let cellSpace = Set((0..<20).flatMap { ring in
                (0..<72).map { PolarMetricGridCell(ring: ring, angularIndex: $0) }
            })
            let workspace = SpatialInstrumentWorkspace(layers: [SpatialInstrumentLayer(
                name: name,
                color: .orange,
                polarCells: cellSpace,
                routings: [SpatialRouting(
                    target: .midiNote(channel: 0), program: program
                )]
            )])
            var state = MetricCanvasInteractionState()
            state.replaceWorkspace(workspace)
            let address = PolarMetricCellSegment(cell: .init(ring: 3, angularIndex: 12), grid: workspace.grid)
            let geometry = MetricCanvasGeometry(size: .init(width: 840, height: 720), viewport: state.viewport)
            _ = state.extendSelection(
                toScreenPoint: geometry.screenPoint(for: address.point(radiusMeters: address.midpoint.radiusMeters, bearingDegrees: address.midpoint.bearingDegrees)),
                canvasSize: CGSize(width: 840, height: 720)
            )
            XCTAssertNotNil(state.selectedPolarCell)
            let tick = ProfileTick()
            let counter = InspectorEvaluationCounter()
            let root = Harness(
                tick: tick,
                state: state,
                audioUnits: audioUnits,
                midiOutput: midiOutput,
                spatialInstrument: spatialInstrument,
                counter: counter
            )
            try render(root, width: 840, name: "\(name)-wide.png", in: runDirectory)
            try render(root, width: 360, name: "\(name)-narrow.png", in: runDirectory)
            let inspectorWidth = CGFloat(ChannelStripLayout.inspectorWidth)
            try render(root, width: inspectorWidth, name: "kanalzug-\(name)-220.png", in: runDirectory)
            let measured = try sizeThatFits(root, width: inspectorWidth)
            XCTAssertLessThanOrEqual(measured.width, inspectorWidth + 0.5)
        }

        let ccCell = PolarMetricGridCell(ring: 1, angularIndex: 2)
        let ccWorkspace = SpatialInstrumentWorkspace(layers: [SpatialInstrumentLayer(
            name: "CC", color: .blue, polarCells: [ccCell],
            routings: [SpatialRouting(target: .midiCC(channel: 0, controller: 74), program: .constant(0.5))]
        )])
        var ccState = MetricCanvasInteractionState()
        ccState.replaceWorkspace(ccWorkspace)
        let ccRoot = Harness(tick: ProfileTick(), state: ccState, audioUnits: audioUnits,
                             midiOutput: midiOutput, spatialInstrument: spatialInstrument,
                             counter: InspectorEvaluationCounter())
        let inspectorWidth = CGFloat(ChannelStripLayout.inspectorWidth)
        try render(ccRoot, width: inspectorWidth, name: "kanalzug-inspector-cc-220.png", in: runDirectory)
        XCTAssertLessThanOrEqual(try sizeThatFits(ccRoot, width: inspectorWidth).width, inspectorWidth + 0.5)

        let devices = AudioOutputDeviceControlModel(host: fixture.root.audio)
        let stripRoot = StripHarness(audioDevices: devices)
        try render(stripRoot, width: CGFloat(ChannelStripLayout.stripWidth), name: "kanalzug-strip-72.png", in: runDirectory)
        let mainCard = AudioOutputDeviceCardView(model: devices).preferredColorScheme(.dark)
        try render(mainCard, width: 300, name: "kanalzug-main-card-wide.png", in: runDirectory,
                   background: Color(red: 0.115, green: 0.118, blue: 0.130))

        try render(ccRoot, width: inspectorWidth, name: "kanalzug-ebene-row-220.png", in: runDirectory)

        let layerStates = [
            SpatialInstrumentLayer(name: "Normal", color: .blue, isActive: true, isSoloed: false),
            SpatialInstrumentLayer(name: "Muted", color: .orange, isActive: false, isSoloed: false),
            SpatialInstrumentLayer(name: "Solo", color: .green, isActive: true, isSoloed: true)
        ]
        var layerState = MetricCanvasInteractionState()
        layerState.replaceWorkspace(SpatialInstrumentWorkspace(layers: layerStates))
        let layerRoot = Harness(tick: ProfileTick(), state: layerState, audioUnits: audioUnits,
                                midiOutput: midiOutput, spatialInstrument: spatialInstrument,
                                counter: InspectorEvaluationCounter())
        try render(layerRoot, width: 840, name: "inspector-layer-mute-solo-wide.png", in: runDirectory)
        try render(layerRoot, width: inspectorWidth, name: "inspector-layer-mute-solo-narrow.png", in: runDirectory)
        XCTAssertLessThanOrEqual(try sizeThatFits(layerRoot, width: inspectorWidth).width, inspectorWidth + 0.5)

        let control = SpatialInstrumentLayer(name: "Scene control", color: .green, isActive: true,
            routings: [.init(target: .sceneSwitch(action: .next, dwellSeconds: 0.2), program: .constant(1))])
        var sceneWorkspace = SpatialInstrumentWorkspace(layers: [layerStates[0], layerStates[1], control], preserveLayerStructure: true)
        _ = sceneWorkspace.addScene(name: "Verse")
        sceneWorkspace.selectScene(sceneWorkspace.scenes[0].id)
        sceneWorkspace.selectLayer(control.id)
        var sceneState = MetricCanvasInteractionState()
        sceneState.replaceWorkspace(sceneWorkspace)
        let sceneRoot = Harness(tick: ProfileTick(), state: sceneState, audioUnits: audioUnits,
                                midiOutput: midiOutput, spatialInstrument: spatialInstrument,
                                counter: InspectorEvaluationCounter())
        try render(sceneRoot, width: 840, name: "harmonie-scenes-wide.png", in: runDirectory)
        try render(sceneRoot, width: inspectorWidth, name: "harmonie-scenes-narrow.png", in: runDirectory)
        try render(sceneRoot, width: 840, name: "harmonie-1-inspector-switch-wide.png", in: runDirectory)
        try render(sceneRoot, width: inspectorWidth, name: "harmonie-1-inspector-switch-narrow.png", in: runDirectory)
        XCTAssertLessThanOrEqual(try sizeThatFits(sceneRoot, width: inspectorWidth).width, inspectorWidth + 0.5)

        let mutedCell = PolarMetricGridCell(ring: 3, angularIndex: 3)
        var mutedFieldState = MetricCanvasInteractionState()
        mutedFieldState.replaceWorkspace(SpatialInstrumentWorkspace(layers: [
            SpatialInstrumentLayer(name: "Active", color: .blue, polarCells: [ccCell]),
            SpatialInstrumentLayer(name: "Muted", color: .orange, isActive: false, polarCells: [mutedCell])
        ]))
        let fieldProfile = try B0ScanProfile.build(partialScanIndex: 0,
            measurements: (0..<90).map { _ in try .build(value: 180, fieldFlags: 0) })
        let mutedField = DetectionHarness(state: mutedFieldState, profile: fieldProfile, spatialInstrument: spatialInstrument)
        try render(mutedField, width: 840, name: "harmonie-1-field-muted-wide.png", in: runDirectory)
        try render(mutedField, width: 360, name: "harmonie-1-field-muted-narrow.png", in: runDirectory)

        var emptyState = MetricCanvasInteractionState()
        emptyState.replaceWorkspace(SpatialInstrumentWorkspace(layers: [SpatialInstrumentLayer(
            name: "Ohne Ausgang", color: .orange, polarCells: [ccCell], routings: []
        )]))
        let emptyRoot = Harness(tick: ProfileTick(), state: emptyState, audioUnits: audioUnits,
                                midiOutput: midiOutput, spatialInstrument: spatialInstrument,
                                counter: InspectorEvaluationCounter())
        try render(emptyRoot, width: inspectorWidth, name: "kanalzug-ebene-ohne-ausgang-220.png", in: runDirectory)
        XCTAssertLessThanOrEqual(try sizeThatFits(emptyRoot, width: inspectorWidth).width, inspectorWidth + 0.5)
    }

    @MainActor
    /// Owner contract 07.10: disclosure changes the rendered surface, while
    /// returning to its original state reproduces the original image.
    func testDetectionDisclosureChangesTheRenderedSurfaceAndRestoresIt() throws {
        let fixture = try MonitorRootFixture()
        let profile = try B0ScanProfile.build(partialScanIndex: 0,
            measurements: (0..<90).map { _ in try .build(value: 180, fieldFlags: 0) })
        var interaction = MetricCanvasInteractionState()
        interaction.replaceWorkspace(fixture.root.document.canvas.workspace)
        func harness(_ expanded: Bool) -> DetectionHarness {
            DetectionHarness(state: interaction, profile: profile, expanded: expanded, spatialInstrument: fixture.root.document)
        }
        let host = NSHostingView(rootView: harness(false))
        host.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        func header() throws -> Data {
            for _ in 0..<3 { host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); pumpMainRunLoop(for: 0.02) }
            let rect = NSRect(x: 0, y: 900 - 260, width: 1440, height: 260)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: rect))
            host.cacheDisplay(in: rect, to: bitmap)
            return try XCTUnwrap(bitmap.tiffRepresentation)
        }
        let first = try header()
        host.rootView = harness(true)
        let second = try header()
        XCTAssertNotEqual(first, second, "Expanding detection must visibly reveal its six modules")
        host.rootView = harness(false)
        XCTAssertEqual(try header(), first)
    }

    func testDetectionControlsHaveOneAccessibilityIdentifierAndConfirmationIsNotInToolbar() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let field = try String(contentsOf: root.appendingPathComponent("Sources/SickPLSMonitor/CartesianScanFieldView.swift"))
        let knobs = try String(contentsOf: root.appendingPathComponent("Sources/SickPLSMonitor/DetectionKnobs.swift"))
        let surface = field + knobs
        let identifiers = [
            "detection.capture", "detection.contourTolerance", "detection.fit", "detection.margin",
            "detection.mmk", "detection.targetWidth", "detection.softness", "detection.grouping",
            "detection.minimumGap", "detection.minimumPoints", "detection.minimumAngle", "detection.representative",
            "detection.offset", "detection.smoothing", "detection.confirmation", "detection.snap", "detection.holdMargin"
        ]
        for identifier in identifiers {
            XCTAssertEqual(surface.components(separatedBy: identifier).count - 1, 1, "\(identifier) must name exactly one detection regulator")
        }
        let toolbarStart = try XCTUnwrap(field.range(of: "private func toolbar"))
        let toolbarEnd = try XCTUnwrap(field.range(of: "private var displayOptions"))
        let toolbar = String(field[toolbarStart.lowerBound..<toolbarEnd.lowerBound])
        XCTAssertFalse(toolbar.contains("Picker(\"Confirm"), "Counterprobe: restoring Confirm to the toolbar must make this test red")
    }

    func testDetectionEvidenceRendersWideAndNarrowRoomAndPerformanceStates() throws {
        let fixture = try MonitorRootFixture()
        defer { fixture.root.terminate {} }
        let owner = fixture.root.document
        let profile = try B0ScanProfile.build(partialScanIndex: 0,
            measurements: (0..<361).map { _ in try .build(value: 180, fieldFlags: 0) })
        let geometry = SpatialRoomContour.Geometry(pointCount: 361, angleResolutionDegrees: 0.5, startAngleDegrees: -90, sourceIdentifier: "test")
        let steady = SpatialRoomContour(geometry: geometry, nearestDistancesCentimeters: Array(repeating: 180, count: 361), spreadCentimeters: Array(repeating: 2, count: 361))
        var restlessSpread = Array<UInt16?>(repeating: 2, count: 361); restlessSpread[180] = 17
        let restless = SpatialRoomContour(geometry: geometry, nearestDistancesCentimeters: Array(repeating: 180, count: 361), spreadCentimeters: restlessSpread)
        let runDirectory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        for evidence in [("no-room", Optional<SpatialRoomContour>.none, false), ("room-steady", Optional(steady), false), ("room-restless", Optional(restless), false), ("perform", Optional(restless), true)] {
            var configuration = owner.document.detection
            configuration.roomContour.isEnabled = evidence.1 != nil
            owner.updateDetectionConfiguration(configuration)
            owner.canvas.setPerformanceLocked(evidence.2)
            var state = MetricCanvasInteractionState()
            state.replaceWorkspace(owner.canvas.workspace)
            for width in [740, 380] {
                try render(DetectionHarness(state: state, profile: profile, contour: evidence.1, expanded: true, spatialInstrument: owner), width: CGFloat(width), height: width == 380 ? 1200 : 900, name: "detektion-\(evidence.0)-\(width).png", in: runDirectory, background: StageTheme.workspace, darkAppearance: true)
            }
        }
        owner.canvas.setPerformanceLocked(false)
        var probeState = MetricCanvasInteractionState()
        probeState.replaceWorkspace(owner.canvas.workspace)
        for width in [740, 380] {
            try render(DetectionHarness(state: probeState, profile: profile, expanded: true, forceProbe: true,
                                        spatialInstrument: owner), width: CGFloat(width), height: width == 380 ? 1200 : 900,
                       name: "detektion-probe-\(width).png", in: runDirectory, background: StageTheme.workspace, darkAppearance: true)
        }
    }

    private func overlayRoom(_ count: Int, meters: Double) -> [UInt16] {
        // Owner 920: a low, irregular tabletop contour around one metre.
        // Keep the same shape for the 4 m comparison, not an empty field.
        (0..<count).map { index in
            let angle = (-90 + Double(index) * 180 / Double(count-1)) * .pi / 180
            return UInt16((meters * 100 * (0.96 + 0.04 * cos(angle * 3))).rounded())
        }
    }

    func testOverlayProbePlacementFollowsOwnerRoomAndVisibleBoundsWithoutOcclusion() throws {
        let fixture = try MonitorRootFixture()
        defer { fixture.root.terminate {} }
        let owner = fixture.root.document
        owner.updateDetectionConfiguration(.init(minimumAngleDegrees: 0, virtualMMKMode: .raw))
        for meters in [1.0, 4.0] {
            for count in [90, 361] {
                let distances = overlayRoom(count, meters: meters)
                let raw = try B0ScanProfile.build(partialScanIndex: 0, measurements: distances.map { try .build(value: $0, fieldFlags: 0) })
                let geometry = try FullScanProfileAdapter.geometry(from: raw)
                let frame = ProfileFrame(sessionID: UUID(), sequence: 1, time: 0,
                    measurements: try FullScanProfileAdapter.measurements(from: raw), geometry: geometry, sourceIdentifier: "owner-room")
                let contour = SpatialRoomContour(geometry: .init(pointCount: count, angleResolutionDegrees: 180 / Double(count-1),
                    startAngleDegrees: -90, sourceIdentifier: frame.sourceIdentifier),
                    nearestDistancesCentimeters: distances.map(Optional.some), spreadCentimeters: [])
                let bounds = DetectionProbePresentation.Bounds(x: (-meters*1.1)...(meters*1.1), y: -0.05...(meters*1.1))
                let probe = DetectionProbePresentation.make(frame: frame, instrument: owner.compiledInstrument, contour: contour, bounds: bounds)
                XCTAssertFalse(probe.marks.isEmpty)
                if count == 361 { XCTAssertEqual(probe.marks.count, 12, "All three groups must fit the Owner room") }
                var occupied = Set<Int>()
                for mark in probe.marks {
                    XCTAssertTrue(bounds.contains(mark.point))
                    XCTAssertFalse(mark.measuredOrders.isEmpty, "No ghost may be occluded by the real room")
                    XCTAssertTrue(occupied.isDisjoint(with: mark.measuredOrders), "No probe may shadow another")
                    occupied.formUnion(mark.measuredOrders)
                    for ray in probe.insertedMeasurements where mark.measuredOrders.contains(ray.order) {
                        XCTAssertLessThan(Int(ray.rawCentimeters), Int(distances[ray.order]) - 3)
                    }
                }
                // The adaptive groups use 30/55/80% of local free room. A
                // restored fixed 1.8 m layout fails these foreground assertions.
                for mark in probe.marks {
                    XCTAssertLessThan(hypot(mark.point.xMeters, mark.point.yMeters), meters * 0.9)
                }
                for width in [380.0, 740.0] {
                    for mirrored in [false, true] {
                        let canvas = MetricCanvasGeometry(size: .init(width: width, height: 300),
                            viewport: try .build(centerXMeters: 0, centerYMeters: meters/2,
                                metersPerPoint: meters * 2.3 / width), isHorizontallyMirrored: mirrored)
                        let anchored = MetricCanvasGeometry(size: .init(width: width, height: 360),
                            viewport: try .build(centerXMeters: 0, centerYMeters: 179 * meters * 2.3 / width,
                                metersPerPoint: meters * 2.3 / width), isHorizontallyMirrored: mirrored)
                        let anchoredBounds = try XCTUnwrap(DetectionOverlayLabelLayout.probeBounds(anchored))
                        let anchoredProbe = DetectionProbePresentation.make(frame: frame, instrument: owner.compiledInstrument,
                            contour: contour, bounds: anchoredBounds)
                        if count == 361 { XCTAssertEqual(anchoredProbe.marks.count, 12, "Scanner anchored at bottom must retain all groups") }
                        XCTAssertTrue(anchoredProbe.marks.allSatisfy { anchored.isVisible($0.point) })
                        let labels = probe.marks.map { DetectionOverlayPresentation.Label(point: $0.point,
                            text: String(format: "%.2f m · detected", hypot($0.point.xMeters, $0.point.yMeters)), tone: .kept) }
                        let placed = DetectionOverlayLabelLayout.place(labels, geometry: canvas)
                        XCTAssertEqual(placed.count, labels.count)
                        for (index, value) in placed.enumerated() {
                            XCTAssertTrue(canvas.canvasRect.contains(value.rect))
                            XCTAssertFalse(placed.prefix(index).contains { $0.rect.intersects(value.rect) })
                        }
                    }
                }
                // No contour: current measurements still bound the probes.
                let unrecorded = DetectionProbePresentation.make(frame: frame, instrument: owner.compiledInstrument, contour: nil, bounds: bounds)
                XCTAssertEqual(unrecorded.marks, probe.marks)
            }
        }
        let tiny = ProfileFrame(sessionID: UUID(), sequence: 1, time: 0, measurements: [], geometry: .fullScan361)
        XCTAssertTrue(DetectionProbePresentation.make(frame: tiny, instrument: owner.compiledInstrument, contour: nil,
            bounds: .init(x: -0.1...0.1, y: 0...0.1)).marks.isEmpty)
    }

    func testOverlayRepresentativeAndOffsetUseActualStageEvidence() throws {
        let fixture = try MonitorRootFixture()
        defer { fixture.root.terminate {} }
        let owner = fixture.root.document
        for meters in [0.0, 1.0, 4.0] {
            let distances = meters == 0 ? [] : overlayRoom(361, meters: meters)
            let measurements = distances.enumerated().compactMap { order, value in
                DeviceTickMeasurement(order: order, ticks: ProfileGeometryIdentity.fullScan361.tickSpan(at: order)!, rawCentimeters: value)
            }
            let frame = ProfileFrame(sessionID: UUID(), sequence: 1, time: 0, measurements: measurements, geometry: .fullScan361,
                sourceIdentifier: "representative-room")
            let contour = meters == 0 ? nil : SpatialRoomContour(geometry: .init(pointCount: 361, angleResolutionDegrees: 0.5,
                startAngleDegrees: -90, sourceIdentifier: frame.sourceIdentifier),
                nearestDistancesCentimeters: distances.map(Optional.some), spreadCentimeters: [])
            for (core, mmk) in [(UInt8(0), VirtualMMKMode.raw), (3, .adaptive)] {
                var positions: [[MetricScanPoint]] = []
                for mode in [DetectionRepresentativeMode.mean, .median, .nearestPoint, .nearestPointWithOffset] {
                    // Keep this geometric oracle at its recorded tolerance;
                    // different probe depths can make Mean and Median coincide.
                    let configuration = DetectionConfiguration(representative: mode, representativeOffsetCentimeters: 10,
                        roomContour: .init(isEnabled: meters > 0, toleranceCentimeters: 3), minimumAngleDegrees: 0, virtualMMKMode: mmk, edgePoints: 0, coreWidthCentimeters: core)
                    owner.updateDetectionConfiguration(configuration)
                    let probe = DetectionProbePresentation.make(frame: frame, instrument: owner.compiledInstrument, contour: contour)
                    let replay = ProfileFrame(sessionID: frame.sessionID, sequence: frame.sequence, time: frame.time,
                        measurements: probe.insertedMeasurements, geometry: frame.geometry, sourceIdentifier: frame.sourceIdentifier)
                    let overlay = DetectionOverlayPresentation.measured(control: mode == .nearestPointWithOffset ? .offset : .representative,
                        frame: replay, instrument: owner.compiledInstrument, contour: contour)
                    if meters == 4 && core == 3 {
                        XCTAssertTrue(probe.objects.allSatisfy { $0.representativeInput.count <= 3 },
                            "The Mean/Median coincidence is justified only by this measured core geometry")
                    }
                    if mode != .nearestPointWithOffset {
                        XCTAssertTrue(overlay.labels.allSatisfy { $0.text == "Playing point" })
                    }
                    positions.append(probe.representatives)
                    XCTAssertFalse(overlay.shapes.isEmpty)
                    XCTAssertEqual(DetectionControlDescriptor.descriptor(mode == .nearestPointWithOffset ? .offset : .representative).overlay,
                        mode == .nearestPointWithOffset ? .offset : .representative)
                    if mode == .nearestPointWithOffset {
                        let arrows = overlay.shapes.filter { $0.points.count == 2 && $0.lineWidth == 2.5 }
                        XCTAssertFalse(arrows.isEmpty)
                        for arrow in arrows {
                            XCTAssertEqual(hypot(arrow.points[1].xMeters-arrow.points[0].xMeters,
                                arrow.points[1].yMeters-arrow.points[0].yMeters), 0.1, accuracy: 1e-9)
                        }
                    }
                }
                for left in positions.indices {
                    for right in positions.indices where right > left {
                        // At 4 m a 3 cm core may hold only 1–3 real rays;
                        // Mean and Median can legitimately select the same one.
                        if meters == 4 && core == 3 && left == 0 && right == 1 {
                            XCTAssertEqual(positions[left], positions[right])
                        } else {
                            XCTAssertNotEqual(positions[left], positions[right])
                        }
                    }
                }
            }
        }
    }

    func testOverlayMinimumAngleNeverClassifiesCapturedWallPointsAsObjects() throws {
        let fixture = try MonitorRootFixture()
        defer { fixture.root.terminate {} }
        let owner = fixture.root.document
        owner.updateDetectionConfiguration(.init(roomContour: .init(isEnabled: true), minimumAngleDegrees: 60))
        let distances = overlayRoom(361, meters: 1)
        let raw = try B0ScanProfile.build(partialScanIndex: 0, measurements: distances.map { try .build(value: $0, fieldFlags: 0) })
        let frame = ProfileFrame(sessionID: UUID(), sequence: 1, time: 0,
            measurements: try FullScanProfileAdapter.measurements(from: raw), geometry: .fullScan361, sourceIdentifier: "owner")
        let contour = SpatialRoomContour(geometry: .init(pointCount: 361, angleResolutionDegrees: 0.5,
            startAngleDegrees: -90, sourceIdentifier: frame.sourceIdentifier),
            nearestDistancesCentimeters: distances.map(Optional.some), spreadCentimeters: [])
        XCTAssertTrue(DetectionOverlayPresentation.measured(control: .minimumAngle, frame: frame, instrument: owner.compiledInstrument, contour: contour).pointTones.isEmpty)
        let probe = DetectionProbePresentation.make(frame: frame, instrument: owner.compiledInstrument, contour: contour)
        let inserted = ProfileFrame(sessionID: frame.sessionID, sequence: 1, time: 0,
            measurements: probe.insertedMeasurements, geometry: frame.geometry, sourceIdentifier: frame.sourceIdentifier)
        let classified = DetectionOverlayPresentation.measured(control: .minimumAngle, frame: inserted, instrument: owner.compiledInstrument, contour: contour)
        XCTAssertFalse(classified.pointTones.isEmpty)
        XCTAssertFalse(classified.shapes.isEmpty, "Accepted objects cast angular shadow sectors")
        for ray in inserted.measurements where ray.rawCentimeters == distances[ray.order] {
            XCTAssertNil(classified.pointTones[ray.order], "A wall is never a rejected/shadowed object")
        }
    }
    func testOverlayInteractionDragWinsAcrossHoverExitAndResets() {
        var interaction = DetectionOverlayInteraction()
        interaction.hover(.minimumGap, inside: true)
        XCTAssertEqual(interaction.active, .minimumGap)
        interaction.edit(.minimumGap, editing: true)
        interaction.hover(.minimumGap, inside: false)
        interaction.hover(.softness, inside: true)
        XCTAssertEqual(interaction.active, .minimumGap)
        interaction.edit(.minimumGap, editing: false)
        XCTAssertEqual(interaction.active, .softness)
        interaction.hover(.softness, inside: false)
        XCTAssertNil(interaction.active)
        // Smoothing and Window share an overlay. A new enter may arrive
        // before the preceding control's exit; one exit must not hide both.
        interaction.hover(.smoothing, inside: true)
        interaction.hover(.smoothing, inside: true)
        interaction.hover(.smoothing, inside: false)
        XCTAssertEqual(interaction.active, .smoothing)
        interaction.hover(.smoothing, inside: false)
        XCTAssertNil(interaction.active)
        interaction.edit(.confirmation, editing: true)
        interaction.reset()
        XCTAssertNil(interaction.active)
        for control in DetectionOverlayControl.allCases {
            XCTAssertFalse(control.isAvailable(configuration: .ownerDefaults, hasMatchingContour: true, performing: true))
        }
        XCTAssertFalse(DetectionOverlayControl.contourTolerance.isAvailable(configuration: .ownerDefaults, hasMatchingContour: false, performing: false))
        XCTAssertFalse(DetectionOverlayControl.targetWidth.isAvailable(configuration: .allStagesOff, hasMatchingContour: false, performing: false))
        XCTAssertFalse(DetectionOverlayControl.softness.isAvailable(configuration: .allStagesOff, hasMatchingContour: false, performing: false))
        XCTAssertFalse(DetectionOverlayControl.minimumPoints.isAvailable(configuration: .allStagesOff, hasMatchingContour: false, performing: false))
    }

    func testOverlayContourBandUsesToleranceAndGreysExactlyFilteredPoints() throws {
        let geometry = ProfileGeometryIdentity.fullScan361
        let measurements = [UInt16(196), 199, 204, 205].enumerated().compactMap {
            DeviceTickMeasurement(order: 178 + $0.offset, ticks: geometry.tickSpan(at: 178 + $0.offset)!, rawCentimeters: $0.element)
        }
        let contour = SpatialRoomContour(geometry: .init(pointCount: 361, angleResolutionDegrees: 0.5,
            startAngleDegrees: -90, sourceIdentifier: "test"), nearestDistancesCentimeters: Array(repeating: 200, count: 361), spreadCentimeters: [])
        let points = geometry.project(measurements)
        func show(_ tolerance: UInt16, room: SpatialRoomContour? = contour, matches: Bool = true) -> DetectionOverlayPresentation {
            .contourTolerance(contour: room, matches: matches, configuration: .init(isEnabled: true, toleranceCentimeters: tolerance), measurements: points)
        }
        let small = show(1), large = show(4)
        XCTAssertNotEqual(small.shapes, large.shapes)
        XCTAssertEqual(Set(small.pointTones.keys), [179, 180, 181])
        XCTAssertEqual(Set(large.pointTones.keys), [178, 179, 180, 181])
        for tolerance: UInt16 in [1, 4, 10] {
            let overlay = show(tolerance)
            for value in points {
                XCTAssertEqual(overlay.pointTones[value.order] == .rejected,
                    !contour.filters(distanceCentimeters: value.distanceCentimeters, at: value.order, toleranceCentimeters: tolerance))
            }
            XCTAssertTrue(overlay.shapes.flatMap(\.points).allSatisfy {
                let radius = hypot($0.xMeters, $0.yMeters)
                return radius <= 2.000000001 && radius >= 2 - Double(tolerance)/100 - 1e-9
            })
            XCTAssertTrue(overlay.shapes.allSatisfy { $0.strokeOpacity == 0 }, "The band must not introduce an unlabeled detection-limit line")
        }
        XCTAssertEqual(show(4, room: nil), .empty)
        XCTAssertEqual(show(4, matches: false), .empty)
    }

    func testOverlayGroupColoursUseRealPointMembershipForMinimumPointsAndAngle() throws {
        let fixture = try MonitorRootFixture()
        defer { fixture.root.terminate {} }
        let owner = fixture.root.document, geometry = ProfileGeometryIdentity.fullScan361
        let measurements = [28: UInt16(50), 29: 50, 180: 180, 181: 180].sorted { $0.key < $1.key }.compactMap {
            DeviceTickMeasurement(order: $0.key, ticks: geometry.tickSpan(at: $0.key)!, rawCentimeters: $0.value)
        }
        let frame = ProfileFrame(sessionID: UUID(), sequence: 1, time: 0, measurements: measurements, geometry: geometry)
        var configuration = DetectionConfiguration(minimumAngleDegrees: 0, virtualMMKMode: .raw)
        func show() -> DetectionOverlayPresentation {
            owner.updateDetectionConfiguration(configuration)
            return .measured(control: .minimumPoints, frame: frame, instrument: owner.compiledInstrument, contour: nil)
        }
        XCTAssertTrue(show().pointTones.values.allSatisfy { $0 == .kept })
        configuration.groupingMinimumPoints = 3
        XCTAssertTrue(show().pointTones.values.allSatisfy { $0 == .rejected })
        configuration.groupingMinimumPoints = 1
        configuration.minimumAngleDegrees = 90
        let shadowed = show()
        XCTAssertEqual(shadowed.pointTones[28], .kept)
        XCTAssertEqual(shadowed.pointTones[180], .rejected)
        configuration.minimumAngleDegrees = 0
        configuration.roomContour = .init(isEnabled: true)
        owner.updateDetectionConfiguration(configuration)
        func contour(_ source: String) -> SpatialRoomContour {
            .init(geometry: .init(pointCount: 361, angleResolutionDegrees: 0.5, startAngleDegrees: -90, sourceIdentifier: source),
                  nearestDistancesCentimeters: Array(repeating: 20, count: 361), spreadCentimeters: [])
        }
        let matched = DetectionOverlayPresentation.measured(control: .minimumPoints, frame: frame, instrument: owner.compiledInstrument, contour: contour(frame.sourceIdentifier))
        XCTAssertTrue(matched.pointTones.isEmpty, "Contour points are room, never rejected objects")
        let mismatch = DetectionOverlayPresentation.measured(control: .minimumPoints, frame: frame, instrument: owner.compiledInstrument, contour: contour("another source"))
        XCTAssertTrue(mismatch.pointTones.values.allSatisfy { $0 == .kept }, "A foreign contour cannot filter the display detector")
    }

    func testOverlayCellMarginsShrinkAndExpandAndCollapseWithoutInversion() {
        let segment = PolarMetricCellSegment(innerRadiusMeters: 0.5, outerRadiusMeters: 1,
            startBearingDegrees: -30, endBearingDegrees: 30)
        let zero = DetectionOverlayPresentation.cellMargins(segments: [segment], centimeters: 0, outside: false)
        let inner = DetectionOverlayPresentation.cellMargins(segments: [segment], centimeters: 10, outside: false)
        let outer = DetectionOverlayPresentation.cellMargins(segments: [segment], centimeters: 5, outside: true)
        XCTAssertNotEqual(zero, inner); XCTAssertNotEqual(zero, outer)
        let innerRadii = inner.shapes[0].points.map { hypot($0.xMeters, $0.yMeters) }
        XCTAssertEqual(innerRadii.min()!, 0.6, accuracy: 1e-9)
        XCTAssertEqual(innerRadii.max()!, 0.9, accuracy: 1e-9)
        let outerRadii = outer.shapes[0].points.map { hypot($0.xMeters, $0.yMeters) }
        XCTAssertEqual(outerRadii.min()!, 0.45, accuracy: 1e-9)
        XCTAssertEqual(outerRadii.max()!, 1.05, accuracy: 1e-9)
        let tiny = PolarMetricCellSegment(innerRadiusMeters: 0, outerRadiusMeters: 0.05, startBearingDegrees: -5, endBearingDegrees: 5)
        XCTAssertTrue(DetectionOverlayPresentation.cellMargins(segments: [tiny], centimeters: 10, outside: false).shapes.isEmpty)
    }

    func testOverlayTimeHistoryFollowsRealDisplayTransitions() throws {
        let fixture = try MonitorRootFixture()
        defer { fixture.root.terminate {} }
        let owner = fixture.root.document
        let frame = ProfileFrame(sessionID: UUID(), sequence: 0, time: 0, measurements: [], geometry: .fullScan361)
        var configuration = DetectionConfiguration(temporalSmoothing: .off, groupingJumpCentimeters: 30,
            minimumAngleDegrees: 0, virtualMMKMode: .raw)
        owner.updateDetectionConfiguration(configuration)
        let raw = DetectionOverlayPresentation.smoothing(frame: frame, instrument: owner.compiledInstrument, contour: nil)
        configuration.temporalSmoothing = .mean(window: 8)
        owner.updateDetectionConfiguration(configuration)
        let smooth = DetectionOverlayPresentation.smoothing(frame: frame, instrument: owner.compiledInstrument, contour: nil)
        XCTAssertNotEqual(raw, smooth)
        XCTAssertEqual(raw.shapes[0].points.count, 2)
        XCTAssertTrue(smooth.shapes.contains { $0.lineWidth == 2.5 && $0.strokeOpacity == 1 })
        XCTAssertTrue(smooth.shapes.contains { $0.tone == .rejected })
        XCTAssertGreaterThan(Set(smooth.shapes.map(\.strokeOpacity)).count, 1)
        func lastRadius(_ value: DetectionOverlayPresentation) -> Double {
            let point = value.shapes.last!.points.last!
            return hypot(point.xMeters, point.yMeters)
        }
        XCTAssertLessThan(lastRadius(smooth), lastRadius(raw))
    }

    func testOverlayEvidenceDoesNotChangeProductionDetectionOrPopulateRuntimeMembership() throws {
        let fixture = try MonitorRootFixture()
        defer { fixture.root.terminate {} }
        let owner = fixture.root.document
        let raw = try B0ScanProfile.build(partialScanIndex: 0,
            measurements: (0..<361).map { try .build(value: abs($0 - 180) < 3 ? 100 : 200, fieldFlags: 0) })
        let frame = ProfileFrame(sessionID: UUID(), sequence: 1, time: 0,
            measurements: try FullScanProfileAdapter.measurements(from: raw), geometry: .fullScan361)
        var configuration = DetectionConfiguration(minimumAngleDegrees: 0)
        configuration.temporalSmoothing = .mean(window: 4)
        owner.updateDetectionConfiguration(configuration)
        var musical = SpatialDetectionPipeline(configuration: configuration)
        var display = SpatialDetectionPipeline(configuration: configuration)
        for _ in 0..<8 {
            let result = musical.select(frame: frame, instrument: owner.compiledInstrument, contour: nil)
            let evidence = display.selectForPresentation(frame: frame, instrument: owner.compiledInstrument, contour: nil)
            XCTAssertEqual(result.activeHandles, evidence.activeHandles)
            XCTAssertEqual(result.representative, evidence.representative)
            XCTAssertEqual(result.filteredOrders, evidence.filteredOrders)
            XCTAssertEqual(result.objects.map(\.center), evidence.objects.map(\.center))
            XCTAssertEqual(result.objects.map(\.diameterMeters), evidence.objects.map(\.diameterMeters))
            XCTAssertTrue(result.objects.allSatisfy { $0.measuredOrders.isEmpty })
            XCTAssertTrue(result.objects.allSatisfy { $0.groupPoints.isEmpty && $0.representativeInput.isEmpty },
                "Overlay geometry must not be allocated in musical detection")
            XCTAssertTrue(evidence.objects.allSatisfy { !$0.measuredOrders.isEmpty })
            XCTAssertTrue(evidence.objects.allSatisfy { !$0.groupPoints.isEmpty && !$0.representativeInput.isEmpty })
        }
    }

    func testClearOverlayWallAndSnapEvidenceWideAndNarrow() throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        let target = SpatialRoutingTarget.midiNote(channel: 0)
        let a = PolarMetricGridCell(ring: 2, angularIndex: 7)
        let b = PolarMetricGridCell(ring: 2, angularIndex: 8)
        let directory = TestImageDirectory.make().appendingPathComponent("einblendungen-klar")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let distances = (0..<361).map { (170...190).contains($0) ? UInt16(100) : UInt16(200) }
        let raw = try B0ScanProfile.build(partialScanIndex: 0, measurements: distances.map { try .build(value: $0, fieldFlags: 0) })
        let contour = SpatialRoomContour(geometry: .init(pointCount: 361, angleResolutionDegrees: 0.5,
            startAngleDegrees: -90, sourceIdentifier: "owner-room"), nearestDistancesCentimeters: Array(repeating: 200, count: 361), spreadCentimeters: [])
        for different in [false, true] {
            let layer = SpatialInstrumentLayer(name: "C major / C or D major", color: .blue, polarCells: [a,b],
                routings: [.init(target: target, program: .chord(notes: [60,64,67], velocity: 90, transition: .retrigger))],
                polarCellOverrides: different ? [b: [.init(target: target, value: .chord(notes: [62,66,69], velocity: 90))]] : [:])
            owner.canvas.replaceWorkspace(.init(grid: .quarterMeter, layers: [layer], preserveLayerStructure: true))
            for tolerance: UInt16 in [1,10] {
                var configuration = DetectionConfiguration(roomContour: .init(isEnabled: true, toleranceCentimeters: tolerance))
                configuration.cellSelection.boundaryMarginCentimeters = 3
                owner.updateDetectionConfiguration(configuration)
                XCTAssertFalse(DetectionOverlayPresentation.cellMargins(instrument: owner.compiledInstrument,
                    layerID: layer.id, centimeters: 3).shapes.isEmpty, "The image must contain the compiled Snap boundary")
                for control in [DetectionOverlayControl.contourTolerance, .edgeMargin] {
                    for width in [740,380] {
                        var state = MetricCanvasInteractionState(viewport: try .build(centerXMeters: 0, centerYMeters: 1,
                            metersPerPoint: 4.6 / Double(width)))
                        state.replaceWorkspace(owner.canvas.workspace)
                        try render(DetectionHarness(state: state, profile: raw, contour: contour, expanded: true,
                            spatialInstrument: owner, forceOverlay: control), width: CGFloat(width), height: width == 380 ? 1800 : 1150,
                            name: "clear-\(control.rawValue)-\(different ? "different" : "same")-t\(tolerance)-\(width).png", in: directory,
                            background: StageTheme.workspace, darkAppearance: true)
                    }
                }
            }
        }
    }

    func testDetectionOverlayEvidenceRendersEveryControlWideAndNarrow() throws {
        let fixture = try MonitorRootFixture()
        defer { fixture.root.terminate {} }
        let owner = fixture.root.document
        for meters in [1.0, 4.0] {
            let layerID = owner.document.spatial.selectedLayerID
            let cells = Set((Int(meters*35)..<Int(meters*65)).flatMap { raw in
                (140...219).compactMap { PolarDeviceLattice(tick: $0, rawCentimeters: UInt16(raw)) }
            })
            let layer = SpatialDocumentLayer(id: layerID, name: "Overlay cells", color: .blue,
                isVisible: true, isActive: true, isLocked: false, isSoloed: false, cells: cells, routings: [], cellOverrides: [:])
            let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layerID)
            try owner.edit { $0.spatial = spatial }
            let distances = overlayRoom(361, meters: meters)
            let raw = try B0ScanProfile.build(partialScanIndex: 0, measurements: distances.map { try .build(value: $0, fieldFlags: 0) })
            let contour = SpatialRoomContour(geometry: .init(pointCount: 361, angleResolutionDegrees: 0.5,
                startAngleDegrees: -90, sourceIdentifier: "owner-room"), nearestDistancesCentimeters: distances.map(Optional.some), spreadCentimeters: [])
            let directory = TestImageDirectory.make().appendingPathComponent("overlays2-room-\(Int(meters))m")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for descriptor in DetectionStage.allCases.flatMap(\.controls) {
                let variants = descriptor.id == .representative ? [0, 1, 2, 3] :
                    descriptor.id == .smoothing ? [0, 1, 2, 3] : [descriptor.values.first!, descriptor.values.last!]
                for value in variants {
                    var configuration = DetectionConfiguration(roomContour: .init(isEnabled: true), minimumAngleDegrees: 0)
                    if descriptor.id == .offset { configuration.representative = .nearestPointWithOffset }
                    if descriptor.id == .window { configuration.temporalSmoothing = .mean(window: 4) }
                    if descriptor.id == .weight { configuration.temporalSmoothing = .exponential(alpha: 0.5) }
                    if descriptor.id == .targetWidth { configuration.virtualMMKSoftness = 0 }
                    if descriptor.id == .softness { configuration.virtualMMKTargetWidthCentimeters = 5 }
                    if descriptor.id == .minimumGap { configuration.virtualMMKMode = .raw }
                    configuration = descriptor.applying(value, to: configuration, hasMatchingContour: true, performing: false)
                    owner.updateDetectionConfiguration(configuration)
                    for width in [740, 380] {
                        var state = MetricCanvasInteractionState(viewport: try .build(centerXMeters: 0, centerYMeters: meters * 0.5,
                            metersPerPoint: meters * 2.3 / Double(width)))
                        state.replaceWorkspace(owner.canvas.workspace)
                        try render(DetectionHarness(state: state, profile: raw, contour: contour, expanded: true,
                            spatialInstrument: owner, forceOverlay: descriptor.overlay), width: CGFloat(width), height: width == 380 ? 1200 : 1150,
                            name: "\(descriptor.id.rawValue)-\(value)-\(width).png", in: directory,
                            background: StageTheme.workspace, darkAppearance: true)
                    }
                }
            }
        }
    }

    func testDetectionProbeUsesDisplayPipelineAndChangesWithGroupingRules() throws {
        let fixture = try MonitorRootFixture()
        defer { fixture.root.terminate {} }
        let owner = fixture.root.document
        let frame = ProfileFrame(sessionID: UUID(), sequence: 1, time: 0, measurements: [], geometry: .fullScan361)
        var configuration = owner.document.detection
        configuration.virtualMMKMode = .raw
        configuration.minimumAngleDegrees = 0
        configuration.groupingJumpCentimeters = 1
        owner.updateDetectionConfiguration(configuration)
        let ordinary = DetectionProbePresentation.make(frame: frame, instrument: owner.compiledInstrument, contour: nil)
        XCTAssertFalse(ordinary.marks.isEmpty)
        XCTAssertTrue(ordinary.marks[8].accepted, "The far finger must start detected")
        XCTAssertFalse(ordinary.marks.contains(where: \.merged), "A 1 cm radial gap must keep the hand pairs separate")

        configuration.groupingMinimumPoints = 10
        owner.updateDetectionConfiguration(configuration)
        let strict = DetectionProbePresentation.make(frame: frame, instrument: owner.compiledInstrument, contour: nil)
        XCTAssertLessThan(strict.marks.filter(\.accepted).count, ordinary.marks.filter(\.accepted).count,
                          "Counterprobe: bypassing SpatialDetectionPipeline would keep rejected probe fingers visible")
        XCTAssertFalse(strict.marks[8].accepted, "Minimum points 10 must reject the far finger")

        configuration.groupingMinimumPoints = 1
        configuration.minimumAngleDegrees = 90
        owner.updateDetectionConfiguration(configuration)
        let shadowed = DetectionProbePresentation.make(frame: frame, instrument: owner.compiledInstrument, contour: nil)
        XCTAssertFalse(shadowed.marks[8].accepted, "Minimum angle 90 must reject the shadowed far finger")

        var wideGap = owner.document.detection
        wideGap.groupingMinimumPoints = 1
        wideGap.minimumAngleDegrees = 0
        wideGap.groupingJumpCentimeters = 30
        owner.updateDetectionConfiguration(wideGap)
        let merged = DetectionProbePresentation.make(frame: frame, instrument: owner.compiledInstrument, contour: nil)
        XCTAssertTrue(merged.marks.contains(where: \.merged), "A wide minimum gap must merge the paired probe hands")

    }

    func testDetectionProbeShowsVirtualMMKMinimumOnTheNearFinger() throws {
        let fixture = try MonitorRootFixture()
        defer { fixture.root.terminate {} }
        let owner = fixture.root.document
        // A real wall behind the probes: the MMK minimum needs neighbouring rays.
        let raw = try B0ScanProfile.build(partialScanIndex: 0,
            measurements: (0..<361).map { _ in try .build(value: 190, fieldFlags: 0) })
        let geometry = try FullScanProfileAdapter.geometry(from: raw)
        let frame = ProfileFrame(sessionID: UUID(), sequence: 1, time: 0,
            measurements: try FullScanProfileAdapter.measurements(from: raw, geometry: geometry), geometry: geometry)
        func nearFingerRepresentative(_ mode: VirtualMMKMode) throws -> DetectionRepresentative {
            var configuration = owner.document.detection
            configuration.groupingMinimumPoints = 1
            configuration.minimumAngleDegrees = 0
            configuration.virtualMMKMode = mode
            configuration.virtualMMKSoftness = 0
            owner.updateDetectionConfiguration(configuration)
            let probe = DetectionProbePresentation.make(frame: frame, instrument: owner.compiledInstrument, contour: nil)
            let index = try XCTUnwrap(probe.marks[0].acceptedObjectIndices.sorted().first)
            let object = probe.objects[index]
            return object.representative
        }
        // DetectionObject clamps every displayed diameter to at least 4 cm.
        // For this 1.5 cm finger, compare the actual displayed representative:
        // adaptive minimum flattens the curved silhouette's neighbouring rays.
        let rawRepresentative = try nearFingerRepresentative(.raw)
        let adaptive = try nearFingerRepresentative(.adaptive)
        XCTAssertGreaterThan(rawRepresentative.distanceCentimeters, adaptive.distanceCentimeters,
                             "Adaptive MMK must move the displayed representative towards the spatial minimum; bypassing MMK turns this red")
        XCTAssertGreaterThan(adaptive.distanceCentimeters, 0)
    }

    func testDetectionProbeObjectsUseTheirAvailableRoomFractions() throws {
        let fixture = try MonitorRootFixture()
        defer { fixture.root.terminate {} }
        let frame = ProfileFrame(sessionID: UUID(), sequence: 1, time: 0, measurements: [], geometry: .fullScan361)
        let probe = DetectionProbePresentation.make(frame: frame, instrument: fixture.root.document.compiledInstrument, contour: nil)
        XCTAssertEqual(probe.marks.count, 12)
        for (index, fraction) in [(0, 0.30), (4, 0.55), (8, 0.80)] {
            let point = probe.marks[index].point
            // Empty-room fallback: 2.5 m minus 12 cm probe reserve and
            // the approved 5 cm session tolerance.
            XCTAssertEqual(hypot(point.xMeters, point.yMeters), (2.5 - 0.17) * fraction, accuracy: 0.000_001)
        }
    }

    func testForcedDetectionProbeLeavesProductionMIDIAndAUAndCellsUnchanged() throws {
        let midi = ProbeMIDI(), au = ProbeOutput()
        let fixture = try MonitorRootFixture(clock: ProbeClock(), midi: midi)
        let root = fixture.root, owner = root.document
        func acknowledge() {
            let done = expectation(description: "Production runtime acknowledged")
            root.runtime.acknowledge { done.fulfill() }
            wait(for: [done], timeout: 5)
        }
        defer {
            let done = expectation(description: "Offline composition terminated")
            root.terminate { done.fulfill() }; wait(for: [done], timeout: 5)
        }
        root.runtime.attach(RuntimePorts.audioUnit(boundary: au))
        let liveID = UUID(), probeID = UUID()
        let targets: [SpatialRoutingTarget] = [.midiNote(channel: 0), .audioUnitNote(channel: 0, stripID: InstrumentChannel.legacyID)]
        func layer(_ id: UUID, cells: Set<PolarDeviceLattice>, note: Int) -> SpatialDocumentLayer {
            .init(id: id, name: "Offline \(note)", color: .blue, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                  cells: cells, routings: targets.map { .init(target: $0, program: .singleNote(note: note, velocity: 100, transition: .legato)) }, cellOverrides: [:])
        }
        let live = layer(liveID, cells: [try XCTUnwrap(PolarDeviceLattice(tick: 180, rawCentimeters: 100))], note: 60)
        let probeCells = Set((24...32).flatMap { tick in (50...52).compactMap { PolarDeviceLattice(tick: tick, rawCentimeters: $0) } })
        let ghost = layer(probeID, cells: probeCells, note: 72)
        try owner.edit { document in
            document.spatial = try! .init(latticeVersion: .polarDeviceV2, layers: [live, ghost], selectedLayerID: liveID)
            document.detection = .init(temporalSmoothing: .mean(window: 4), representative: .nearestPointWithOffset,
                cellSelection: .init(boundaryMarginCentimeters: 2, confirmationProfiles: 3), continuousBacklashCentimeters: 2,
                roomContour: .init(isEnabled: true), minimumAngleDegrees: 0)
            document.midiTarget = .init(uniqueID: 1)
        }
        var detection = owner.document.detection
        detection.roomContour = .init(isEnabled: true)
        owner.updateDetectionConfiguration(detection)
        let session = UUID()
        root.runtime.sessionBegan(session); acknowledge()
        let raw = try B0ScanProfile.build(partialScanIndex: 0,
            measurements: (0..<361).map { try .build(value: $0 == 180 ? 100 : 190, fieldFlags: 0) })
        let geometry = try FullScanProfileAdapter.geometry(from: raw)
        let frame = ProfileFrame(sessionID: session, sequence: 1, time: 0,
            measurements: try FullScanProfileAdapter.measurements(from: raw, geometry: geometry), geometry: geometry, rawProfile: raw)
        root.runtime.frame(frame); acknowledge()
        let before = try XCTUnwrap(root.runtime.mailbox.read())
        XCTAssertEqual(Set(before.selection.activeHandles.keys), [liveID])
        XCTAssertTrue(midi.output.sent.contains([0x90, 60, 100]))
        XCTAssertTrue(au.sent.contains([0x90, 60, 100]))
        let midiBefore = midi.output.sent, auBefore = au.sent

        let contour = SpatialRoomContour(geometry: .init(pointCount: 361, angleResolutionDegrees: 0.5,
            startAngleDegrees: -90, sourceIdentifier: "scanner:default"), nearestDistancesCentimeters: Array(repeating: 190, count: 361), spreadCentimeters: [])
        var state = MetricCanvasInteractionState()
        state.replaceWorkspace(owner.canvas.workspace)
        var host = NSHostingView(rootView: DetectionHarness(state: state, profile: raw, contour: contour, expanded: true, spatialInstrument: owner))
        host.frame = .init(x: 0, y: 0, width: 740, height: 900)
        func image() throws -> Data {
            for _ in 0..<3 { host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); pumpMainRunLoop(for: 0.02) }
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return try XCTUnwrap(bitmap.tiffRepresentation)
        }
        let withoutProbe = try image()
        host.rootView = DetectionHarness(state: state, profile: raw, contour: contour, expanded: true, forceProbe: true, spatialInstrument: owner)
        XCTAssertNotEqual(try image(), withoutProbe, "The production canvas must actually draw the forced probe")
        for control in DetectionOverlayControl.allCases where control != .probe {
            host.rootView = DetectionHarness(state: state, profile: raw, contour: contour, expanded: true, spatialInstrument: owner, forceOverlay: control)
            if control.isAvailable(configuration: owner.document.detection, hasMatchingContour: true, performing: false) {
                XCTAssertNotEqual(try image(), withoutProbe, "The isolation check must visibly draw \(control)")
            } else {
                XCTAssertEqual(try image(), withoutProbe, "Unavailable \(control) must not display an overlay")
            }
        }
        let presentation = DetectionProbePresentation.make(frame: frame, instrument: owner.compiledInstrument, contour: nil)
        XCTAssertFalse(presentation.marks.isEmpty)
        // Feeding presentation.insertedMeasurements into this ingress must
        // fail the raw-profile comparison below even while smoothing delays
        // the musical response of the painted ghost/72 cell.
        let nextMeasured = ProfileFrame(sessionID: session, sequence: 2, time: 0,
            measurements: frame.measurements, geometry: geometry, rawProfile: raw)
        root.runtime.frame(nextMeasured); acknowledge()
        let after = try XCTUnwrap(root.runtime.mailbox.read())
        XCTAssertEqual(after.processedProfiles, before.processedProfiles + 1, "The comparison must process a fresh measured profile")
        XCTAssertEqual(midi.output.sent, midiBefore, "A visible probe must leave every fake MIDI byte unchanged")
        XCTAssertEqual(au.sent, auBefore, "A visible probe must leave every fake AU byte unchanged")
        XCTAssertEqual(after.selection.activeHandles, before.selection.activeHandles, "The display probe must never switch production cells")
        XCTAssertEqual(after.profile?.measurements, frame.measurements, "Synthetic rays must never reach runtime ingress")

        host.rootView = DetectionHarness(state: state, profile: raw, contour: contour, expanded: true, spatialInstrument: owner)
        XCTAssertEqual(try image(), withoutProbe, "Leaving the probe must remove its marks and legend")

        state.setPerformanceLocked(true)
        // A StateObject retains its initial CanvasSession across root changes.
        // Mount the Perform state once, then vary only the forcing input.
        host = NSHostingView(rootView: DetectionHarness(state: state, profile: raw, contour: contour, expanded: true, spatialInstrument: owner))
        host.frame = .init(x: 0, y: 0, width: 740, height: 900)
        let performWithoutProbe = try image()
        host.rootView = DetectionHarness(state: state, profile: raw, contour: contour, expanded: true, forceProbe: true, spatialInstrument: owner)
        XCTAssertEqual(try image(), performWithoutProbe, "Perform must suppress even an explicitly forced probe")
        for control in DetectionOverlayControl.allCases {
            host.rootView = DetectionHarness(state: state, profile: raw, contour: contour, expanded: true, spatialInstrument: owner, forceOverlay: control)
            XCTAssertEqual(try image(), performWithoutProbe, "Perform must suppress \(control)")
        }
    }

    func testDetectionProbeKeepsWallInputAndFindsRoomRelativeForegroundWithContour() throws {
        let fixture = try MonitorRootFixture()
        defer { fixture.root.terminate {} }
        let owner = fixture.root.document
        var configuration = owner.document.detection
        configuration.groupingMinimumPoints = 1
        configuration.groupingJumpCentimeters = 10
        configuration.roomContour = .init(isEnabled: true, toleranceCentimeters: 3)
        owner.updateDetectionConfiguration(configuration)
        let raw = try B0ScanProfile.build(partialScanIndex: 0,
            measurements: (0..<361).map { _ in try .build(value: 190, fieldFlags: 0) })
        let geometry = try FullScanProfileAdapter.geometry(from: raw)
        let frame = ProfileFrame(sessionID: UUID(), sequence: 1, time: 0,
            measurements: try FullScanProfileAdapter.measurements(from: raw, geometry: geometry), geometry: geometry)
        let contour = SpatialRoomContour(
            geometry: .init(pointCount: 361, angleResolutionDegrees: 0.5, startAngleDegrees: -90, sourceIdentifier: "test"),
            nearestDistancesCentimeters: Array(repeating: 190, count: 361),
            spreadCentimeters: Array(repeating: 1, count: 361)
        )
        let presentation = DetectionProbePresentation.make(frame: frame, instrument: owner.compiledInstrument, contour: contour)
        XCTAssertTrue(presentation.insertedMeasurements.contains { $0.rawCentimeters == 190 }, "Wall rays must remain in the inserted profile")
        XCTAssertTrue(presentation.insertedMeasurements.contains { $0.rawCentimeters < 170 }, "Room-relative foreground probes must occlude their rays")
        XCTAssertTrue(presentation.objects.contains { $0.representative.distanceCentimeters < 187 },
                      "Contour filtering must not remove the foreground probe")
    }

    func testEdgePointsCoreWidthAndRecordingRenderWideNarrowAndPerform() throws {
        let fixture = try MonitorRootFixture()
        defer { fixture.root.terminate {} }
        let owner = fixture.root.document
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let raw = try B0ScanProfile.build(partialScanIndex: 0, measurements: (0..<361).map { order in
            try .build(value: (161...199).contains(order) ? 30 : ([159, 201].contains(order) ? 46 : ([160, 200].contains(order) ? 38 : 200)), fieldFlags: 0)
        })
        let frame = ProfileFrame(sessionID: UUID(), sequence: 1, time: 0,
            measurements: try FullScanProfileAdapter.measurements(from: raw), geometry: .fullScan361)
        let contour = SpatialRoomContour(geometry: .init(pointCount: 361, angleResolutionDegrees: 0.5,
            startAngleDegrees: -90, sourceIdentifier: "scanner:default"),
            nearestDistancesCentimeters: Array(repeating: 200, count: 361), spreadCentimeters: [])
        for edge: UInt8 in 0...2 { for core: UInt8 in [0, 2, 3, 5] {
            owner.updateDetectionConfiguration(.init(groupingJumpCentimeters: 24, roomContour: .init(isEnabled: true, toleranceCentimeters: 3), minimumAngleDegrees: 0,
                virtualMMKMode: .raw, edgePoints: edge, coreWidthCentimeters: core))
            var pipeline = SpatialDetectionPipeline()
            for width in [740, 380] {
                var state = MetricCanvasInteractionState(viewport: try .build(centerXMeters: 0, centerYMeters: 1.05,
                    metersPerPoint: width == 380 ? 0.011 : 0.006))
                state.replaceWorkspace(owner.canvas.workspace)
                let harness = DetectionHarness(state: state, profile: raw, contour: contour, expanded: true, forceProbe: true, spatialInstrument: owner)
                owner.noteDisplay(.init(profile: frame, contour: contour, selection: pipeline.select(frame: frame, instrument: owner.compiledInstrument, contour: contour)))
                XCTAssertEqual(owner.latestDetectionObjects.count, 1)
                try render(harness, width: CGFloat(width), height: width == 380 ? 1400 : 1000,
                    name: "randpunkte-edge-\(edge)-core-\(core)-\(width).png", in: directory, background: StageTheme.workspace, darkAppearance: true)
            }
        }}
        let closeRaw = try B0ScanProfile.build(partialScanIndex: 0, measurements: (0..<361).map { order in
            try .build(value: (161...199).contains(order) ? 30 : ([159, 201].contains(order) ? 46 : ([160, 200].contains(order) ? 38 : 0)), fieldFlags: 0)
        })
        let closeFrame = ProfileFrame(sessionID: UUID(), sequence: 1, time: 0,
            measurements: try FullScanProfileAdapter.measurements(from: closeRaw), geometry: .fullScan361)
        for edge: UInt8 in [0, 2] {
            owner.updateDetectionConfiguration(.init(groupingJumpCentimeters: 24, roomContour: .init(isEnabled: true, toleranceCentimeters: 3), minimumAngleDegrees: 0,
                virtualMMKMode: .raw, edgePoints: edge, coreWidthCentimeters: 3))
            for width in [740, 380] {
                var state = MetricCanvasInteractionState(viewport: try .build(centerXMeters: 0, centerYMeters: 0.3, metersPerPoint: 0.0015))
                state.replaceWorkspace(owner.canvas.workspace)
                let harness = DetectionHarness(state: state, profile: closeRaw, contour: contour, expanded: false, spatialInstrument: owner)
                var pipeline = SpatialDetectionPipeline()
                owner.noteDisplay(.init(profile: closeFrame, contour: contour, selection: pipeline.select(frame: closeFrame, instrument: owner.compiledInstrument, contour: contour)))
                XCTAssertEqual(owner.latestDetectionObjects.count, 1)
                try render(harness, width: CGFloat(width), height: 600, name: "randpunkte-close-edge-\(edge)-core-3-\(width).png",
                    in: directory, background: StageTheme.workspace, darkAppearance: true)
            }
        }
        for performing in [false, true] {
            owner.canvas.setPerformanceLocked(performing)
            for recording in [false, true] {
                let model = ProfileRecordingModel(directory: directory.appendingPathComponent("unused-recording-output"))
                if recording { model.begin(detection: owner.document.detection, contour: nil) }
                for width in [620, 380] {
                    try render(ProfileRecordingControls(recording: model, instrument: owner).padding(), width: CGFloat(width), height: 220,
                        name: "record-profiles-perform-\(performing)-active-\(recording)-\(width).png", in: directory,
                        background: StageTheme.workspace, darkAppearance: true)
                }
                model.cancel()
            }
        }
        owner.canvas.setPerformanceLocked(true)
        let before = owner.document.detection
        var changed = before; changed.edgePoints = before.edgePoints == 2 ? 0 : 2; changed.coreWidthCentimeters = 10
        owner.updateDetectionConfiguration(changed)
        XCTAssertEqual(owner.document.detection, before)
    }

    func testDetectionStageProposalRendersRealViewsWideAndNarrow() throws {
        let fixture = try MonitorRootFixture()
        let owner = fixture.root.document
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let profile = try B0ScanProfile.build(partialScanIndex: 0,
            measurements: (0..<361).map { _ in try .build(value: 180, fieldFlags: 0) })
        for (name, method, performing) in [("off", DetectionTemporalSmoothing.off, false),
            ("mean", .mean(window: 4), false), ("exponential", .exponential(alpha: 0.3), false),
            ("perform", .mean(window: 4), true)] {
            owner.canvas.setPerformanceLocked(false)
            owner.updateDetectionConfiguration(.ownerDefaults.replacingTemporalSmoothing(method))
            owner.canvas.setPerformanceLocked(performing)
            for width in [1728, 1024, 740, 380] {
                var state = MetricCanvasInteractionState()
                state.replaceWorkspace(owner.canvas.workspace)
                state.setPerformanceLocked(performing)
                let harness = DetectionHarness(state: state, profile: profile, expanded: true,
                    spatialInstrument: owner, stagePreview: true)
                try render(harness, width: CGFloat(width), height: width == 380 ? 1240 : 900,
                    name: "detektion-stufen-\(name)-\(width).png", in: directory,
                    background: StageTheme.workspace, darkAppearance: true)
            }
        }
    }

    func testDetectionSurfaceRendersReviewStatesInWideAndNarrowWidths() throws {
        let fixture = try! MonitorRootFixture()
        let spatialInstrument = fixture.root.document
        let runDirectory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)

        let profile = try B0ScanProfile.build(
            partialScanIndex: 0,
            measurements: (0..<361).map { _ in try! .build(value: 180, fieldFlags: 0) }
        )
        let cells = Set((0..<40).flatMap { ring in
            (0..<144).map { PolarMetricGridCell(ring: ring, angularIndex: $0) }
        })
        let contour = SpatialRoomContour(
            geometry: .init(
                pointCount: 361,
                angleResolutionDegrees: 0.5,
                startAngleDegrees: -90,
                sourceIdentifier: "scanner:default"
            ),
            nearestDistancesCentimeters: Array(repeating: 180, count: 361),
            spreadCentimeters: Array(repeating: 2, count: 361)
        )

        let states: [(name: String, configuration: DetectionConfiguration, matches: Bool, showContour: Bool)] = [
            ("standard", .ownerDefaults, true, false),
            ("raumkontur-streuung", .init(roomContour: .init(isEnabled: true, toleranceCentimeters: 5)), true, true),
            ("raumkontur-mismatch", .init(roomContour: .init(isEnabled: true, toleranceCentimeters: 5)), false, true),
            ("overlay-konturlinie", .init(roomContour: .init(isEnabled: true, toleranceCentimeters: 5)), true, true)
        ]

        for stateCase in states {
            let workspace = SpatialInstrumentWorkspace(
                grid: .fiveCentimeter,
                layers: [SpatialInstrumentLayer(
                    name: "Detektion",
                    color: .orange,
                    polarCells: cells,
                    routings: []
                )],
                detectionConfiguration: stateCase.configuration
            )
            var interaction = MetricCanvasInteractionState()
            interaction.replaceWorkspace(workspace)
            for expanded in [false, true] {
                let root = DetectionHarness(
                    state: interaction,
                    profile: profile,
                    contour: stateCase.showContour ? contour : nil, matches: stateCase.matches, expanded: expanded,
                    spatialInstrument: spatialInstrument
                )
                for width in [1440, 1190, 900, 420] {
                    try render(root, width: CGFloat(width), name: "blockc-\(stateCase.name)\(expanded ? "-expanded" : "")-\(width).png", in: runDirectory,
                               background: Color(red: 0.08, green: 0.09, blue: 0.11))
                }
            }
        }
    }

    func testRundeEEightMeasuredOverlaysRenderSmallLargeWideNarrow() throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        let directory = TestImageDirectory.make().appendingPathComponent("runde-e")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hand: [UInt16] = [106,106,100,103,109,109,109,109]
        func profile(previous: Bool = false) throws -> B0ScanProfile {
            try .build(partialScanIndex: 0, measurements: (0..<361).map { order in
                let distance: UInt16 = (170..<178).contains(order) ? (previous ? 180 : hand[order-170]) : (230..<238).contains(order) ? 140 : 400
                return try .build(value: distance, fieldFlags: 0)
            })
        }
        let raw = try profile(), previous = try profile(previous: true)
        let controls: [DetectionOverlayControl] = [.minimumGap,.minimumPoints,.minimumAngle,.confirmation,.targetWidth,.softness,.representative,.offset]
        for control in controls {
            for large in [false,true] {
                var configuration = DetectionConfiguration(temporalSmoothing: .off, groupingJumpCentimeters: 10, groupingMinimumPoints: 1,
                    representative: .mean, representativeOffsetCentimeters: 0, roomContour: .init(isEnabled: true, toleranceCentimeters: 5),
                    minimumAngleDegrees: 0, virtualMMKMode: .raw, virtualMMKTargetWidthCentimeters: 2, virtualMMKSoftness: 0,
                    edgePoints: 0, coreWidthCentimeters: 0)
                switch control {
                case .minimumGap: configuration.groupingJumpCentimeters = large ? 30 : 1
                case .minimumPoints: configuration.groupingMinimumPoints = large ? 10 : 1
                case .minimumAngle: configuration.minimumAngleDegrees = large ? 90 : 0
                case .confirmation: configuration.cellSelection.confirmationProfiles = large ? 4 : 1
                case .targetWidth: configuration.virtualMMKMode = .adaptive; configuration.virtualMMKTargetWidthCentimeters = large ? 5 : 1
                case .softness: configuration.virtualMMKMode = .adaptive; configuration.virtualMMKTargetWidthCentimeters = 5; configuration.virtualMMKSoftness = large ? 100 : 0
                case .representative: configuration.representative = large ? .nearestPoint : .mean
                case .offset: configuration.representative = .nearestPointWithOffset; configuration.representativeOffsetCentimeters = large ? 10 : 0
                default: XCTFail("Unexpected control")
                }
                let cells = Set((90...200).flatMap { ring in (168...178).compactMap { tick in
                    try? LegacyLatticeMigration.project(PolarDeviceLattice(ring: ring,sector: tick)!, in: .fiveCentimeter)
                } })
                let workspace = SpatialInstrumentWorkspace(grid: .fiveCentimeter, layers: [.init(name: "Replay",color: .blue,polarCells: cells,routings: [])],
                    detectionConfiguration: configuration, preserveLayerStructure: true)
                owner.canvas.replaceWorkspace(workspace)
                let contour = SpatialRoomContour(geometry: .init(pointCount: 361, angleResolutionDegrees: 0.5, startAngleDegrees: -90, sourceIdentifier: "scanner:default"),
                    nearestDistancesCentimeters: Array(repeating: 400,count: 361),spreadCentimeters: [])
                let instrument = owner.compiledInstrument
                var pipeline = SpatialDetectionPipeline(configuration: configuration)
                func frame(_ profile: B0ScanProfile, sequence: UInt64) throws -> ProfileFrame {
                    .init(sessionID: UUID(),sequence: sequence,time: Double(sequence)/25,
                        measurements: try FullScanProfileAdapter.measurements(from: profile),rawProfile: profile)
                }
                _ = pipeline.select(frame: try frame(previous,sequence: 1),instrument: instrument,contour: contour)
                let selected = pipeline.select(frame: try frame(raw,sequence: 2),instrument: instrument,contour: contour)
                if control == .confirmation && large {
                    XCTAssertEqual(selected.confirmationProgress.first?.observedProfiles,1)
                }
                var state = MetricCanvasInteractionState(viewport: try .build(centerXMeters: 0.3, centerYMeters: 1.5, metersPerPoint: 0.0035))
                state.replaceWorkspace(workspace)
                for width in [740,380] {
                    let view = DetectionHarness(state: state, profile: raw, contour: contour, expanded: false,
                        spatialInstrument: owner, forceOverlay: control, selection: selected)
                    var rendered: DetectionOverlayPresentation?
                    view.preview.didRender = { _,overlay in rendered = overlay }
                    try render(view,width: CGFloat(width),height: width == 380 ? 1240 : 900,
                        name: "overlay-\(control.rawValue)-\(large ? "large" : "small")-\(width).png",in: directory,
                        background: StageTheme.workspace,darkAppearance: true)
                    if control == .confirmation && large {
                        XCTAssertEqual(rendered?.labels.first?.text,"1 / 4 · waiting", "Canvas must read the actual pending selector state")
                    }
                }
            }
        }
        print("RUNDE-E images: \(directory.path)")
    }

    @MainActor
    private func render<Content: View>(
        _ view: Content,
        width: CGFloat,
        height: CGFloat = 900,
        name: String,
        in directory: URL,
        background: Color = .white,
        darkAppearance: Bool = false
    ) throws {
        let host = NSHostingView(rootView: view.background(background))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        if darkAppearance { host.appearance = NSAppearance(named: .darkAqua) }
        host.wantsLayer = true
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(width),
            pixelsHigh: Int(height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: .alphaFirst,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { throw NSError(domain: "InspectorRendering", code: 1) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "InspectorRendering", code: 2)
        }
        try data.write(to: directory.appendingPathComponent(name))
    }

    private func sizeThatFits<Content: View>(_ view: Content, width: CGFloat) throws -> CGSize {
        let controller = NSHostingController(rootView: view)
        return controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    private func pumpMainRunLoop(for duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
    }
}
