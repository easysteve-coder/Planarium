import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import PlanariumApplication
import PlanariumAudio
import PlanariumInput
import PlanariumMIDI
import PlanariumDomain
import PlanariumScannerUI
import SickPLSCommissioningControl
import SickPLSSimulationControl
import SickPLSSetupControl
import PlanariumPresets
import SickPLSMonitorKit

@MainActor final class TerminationDelegate: NSObject, NSApplicationDelegate {
    var confirm: (() -> Bool)?
    var release: ((@escaping @MainActor () -> Void) -> Void)?
    private var pending = false
    func applicationDidFinishLaunching(_ notification: Notification) { ViewMenuRepair.install() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !pending else { return .terminateLater }
        guard confirm?() != false else { return .terminateCancel }
        guard let release else { return .terminateNow }
        pending = true
        release { [weak sender] in sender?.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

@MainActor final class AppModels {
    let root: PlanariumComposition
    let connection: StandardConnectionControlModel
    let scannerPassword: ScannerPasswordSettingsModel
    let scannerDevelopment: SetupConsoleModel
    let commissioning: CommissioningControlModel
    let simulation: SimulationConnectionControlModel
    let scannerWorkspace: ScannerWorkspaceModel
    let presets: PresetControlModel
    let spatialInstrument: SpatialInstrumentRuntimeModel
    let audioUnits: AudioCatalogModel
    let audioDevices: AudioOutputDeviceControlModel
    let lifecycle: AppLifecycleObserver
    let tempoTapShortcut: TempoTapShortcutMonitor
    let emergencyActions: EmergencyActionMonitor
    let usbStartup: ScannerUSBStartupMonitor
    private var recoveryScene: AnyCancellable?
    let workspace = WorkspaceControlModel()
    lazy var menuPresentation = MenuPresentationModel(instrument: spatialInstrument, workspace: workspace)
    init() {
        do {
            let root = try PlanariumComposition(midi: CoreMIDIConnection(), components: SystemPluginSource(), clockSinkFactory: { CoreMIDIClockSink.open($0) }, clockSourceFactory: { CoreMIDIClockSource.open($0, receive: $1, lost: $2) }, clockSourceChanges: { CoreMIDIClockSource.observeSources($0) }, footswitchDefaults: .standard, footswitchSourceFactory: { CoreMIDIClockSource.openFootswitch($0, receive: $1, lost: $2) })
            self.root = root
            self.emergencyActions = EmergencyActionMonitor(panic: { [weak root] in root?.document.panicAll() })
            OutputMonitorWindowController.shared.configure(display: root.display, instrument: root.document)
            self.audioDevices = AudioOutputDeviceControlModel(host: root.audio, preferences: UserDefaultsAudioOutputPreferences(), startAudio: { root.document.startSpatialAudio() })
            let passwordStore = UserDefaultsScannerPasswordStore()
            let presets = PresetControlModel(store: PresetFileStore.standard(), documentOwner: root.document)
            self.presets = presets
            self.spatialInstrument = root.document
            self.audioUnits = AudioCatalogModel(document: root.document, source: SystemAudioUnitComponentSource())
            self.scannerWorkspace = ScannerWorkspaceModel(input: root.input)
            let connection = StandardConnectionControlModel(coordinator: root.input,
                runProvider: SystemStandardConnectionRunFactory(passwordStore: passwordStore, allowsAutomaticCommissioning: false),
                releaseOutputs: { completion in
                    root.panic()
                    root.runtime.acknowledge { Task { @MainActor in completion() } }
                })
            self.connection = connection
            self.commissioning = CommissioningControlModel(coordinator: root.input, passwordStore: passwordStore)
            let simulation = SimulationConnectionControlModel(coordinator: root.input)
            self.simulation = simulation
            self.scannerPassword = ScannerPasswordSettingsModel(store: passwordStore)
            let scannerSetup = SetupConsoleModel()
            self.scannerDevelopment = scannerSetup
            let startupMonitor = ScannerUSBStartupMonitor(connection: connection, setup: scannerSetup, simulation: simulation)
            self.usbStartup = startupMonitor
            self.lifecycle = AppLifecycleObserver(root: root)
            self.tempoTapShortcut = TempoTapShortcutMonitor(tap: { root.document.tapTempo() }, cancelCapture: {
                guard root.document.isCapturingRoomContour else { return false }
                root.document.cancelRoomContourCapture(); return true
            })
            if let recovery = try? PresetRecoveryStore.standard() {
                presets.configureRecovery(defaults: .standard, store: recovery)
                presets.restoreStartup()
                recoveryScene = root.document.$document.map(\.currentSceneID).removeDuplicates().sink { [weak presets] _ in
                    // @Published emits before assignment; read on the next Main turn.
                    Task { @MainActor in presets?.rememberCurrentScene() }
                }

            }
            root.document.onWorkspaceChange = { [weak presets] workspace in presets?.noteSpatialWorkspace(workspace) }
        } catch { fatalError("Application composition failed") }
    }
    func configure(delegate: TerminationDelegate) {
        let startupMonitor = usbStartup, root = root, presets = presets, audioDevices = audioDevices
        delegate.release = { [weak self] completion in
            presets.stopRecovery(); self?.recoveryScene = nil
            startupMonitor.stop(); audioDevices.shutdown(); root.terminate(completion)
        }
        delegate.confirm = {
            guard presets.terminationPrompt != .none else { return true }
            let alert = NSAlert()
            alert.messageText = "Save changes before quitting?"
            alert.informativeText = presets.unsavedChangesDescription
            alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Don't Save"); alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            if response == .alertSecondButtonReturn { return presets.resolveTermination(.discard) == .terminate }
            if response == .alertFirstButtonReturn { return presets.resolveTermination(.save) == .terminate }
            return false
        }
    }

}

@MainActor @main struct SickPLSMonitorApp: App {
    @NSApplicationDelegateAdaptor(TerminationDelegate.self) private var delegate
    // Ownership only: AppModels never forwards its children's publications.
    @StateObject private var ownership: AppOwnership<AppModels>
    private var models: AppModels { ownership.models }
    init() {
        let models = AppModels()
        _ownership = StateObject(wrappedValue: AppOwnership(models))
        models.configure(delegate: delegate)
    }
    var body: some Scene {
        let _ = ViewEvaluationProbe.current?.record("app.body")
        WindowGroup("Planarium") {
            MainWindowContent(models: models)
        }.commands {
            PlanariumCommands(workspace: models.workspace, spatialInstrument: models.spatialInstrument,
                presets: models.presets, presentation: models.menuPresentation)
        }
        Settings {
            PlanariumSettingsView(workspace: models.workspace, spatialInstrument: models.spatialInstrument,
                scannerPassword: models.scannerPassword, scannerSetup: models.scannerDevelopment,
                connection: models.connection, commissioning: models.commissioning,
                input: models.root.input, midi: models.root.midi, recording: models.root.profileRecording, footswitch: models.root.footswitch, presets: models.presets)
        }
    }
}

private struct MainWindowContent: View {
    let models: AppModels
    var body: some View {
        ContentView(workspace: models.workspace, root: models.root, connection: models.connection,
            scannerSetup: models.scannerDevelopment, presets: models.presets, spatialInstrument: models.spatialInstrument,
            audioUnits: models.audioUnits, audioDevices: models.audioDevices, scannerWorkspace: models.scannerWorkspace,
            simulation: models.simulation)
            .onAppear { ViewMenuRepair.install() }
            .background(AudioOutputAlert(model: models.audioDevices, authorize: { models.spatialInstrument.authorize(.edit) }))
            .background(TempoTapWorkspaceRegistration(monitor: models.tempoTapShortcut))
            .onAppear { models.audioDevices.restoreAtStartup(); models.usbStartup.start(); models.root.midi.refresh() }
            .background(ScannerHandoffBridge(
                handoffs: models.scannerDevelopment.$pendingMonitorHandoff.eraseToAnyPublisher(),
                current: { models.scannerDevelopment.pendingMonitorHandoff },
                consume: { models.scannerDevelopment.consumeMonitorHandoff() },
                connect: { endpoint in
                    _ = models.connection.connectDevelopment(portPath: endpoint.portPath, baudRate: endpoint.baudRate)
                }))
    }
}

struct PlanariumCommands: Commands {
    let workspace: WorkspaceControlModel
    let spatialInstrument: SpatialInstrumentRuntimeModel
    let presets: PresetControlModel
    @ObservedObject var presentation: MenuPresentationModel
    private var menuController: InstrumentMenuController { .init(instrument: spatialInstrument, presets: presets) }
    var body: some Commands {
        let _ = ViewEvaluationProbe.current?.record("commands")
        WorkspaceCommands(instrument: spatialInstrument, presentation: presentation, presets: presets)
        CommandGroup(replacing: .newItem) {}
        CommandMenu("Preset") {
            Button("Save Preset") { menuController.save() }.keyboardShortcut("s", modifiers: .command)
            Button("Save Preset As…") { menuController.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Button("Import Preset…") { importPresets() }.keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Export Preset…") { exportPreset() }.keyboardShortcut("e", modifiers: [.command, .shift])
        }
        CommandMenu("Instrument") {
            EmergencyPanicMenuItem(panic: { spatialInstrument.panicAll() })
        }
        CommandMenu("Tempo") {
            Button("Tap Tempo (T)") { spatialInstrument.tapTempo() }
                .disabled(presentation.value.receivingClock)
        }
        CommandGroup(replacing: .undoRedo) {
            Button(presentation.value.undoTitle) { performUndo() }.disabled(!presentation.value.canUndo && !presentation.value.locked).keyboardShortcut("z", modifiers: .command)
            Button(presentation.value.redoTitle) { performRedo() }.disabled(!presentation.value.canRedo && !presentation.value.locked).keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
                    NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                }
            }.keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .appInfo) {
            Button("About Planarium") {
                let identity = PlanariumBuildIdentity.current
                NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Planarium", .applicationVersion: identity.aboutVersionText,
                    .credits: NSAttributedString(string: identity.standText)])
            }
        }
        CommandGroup(after: .toolbar) {
            Toggle("Button labels", isOn: Binding(get: { presentation.value.buttonLabels }, set: { workspace.setButtonLabels($0) }))
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
            Toggle("Setup", isOn: visibility(.setup)).keyboardShortcut("1", modifiers: .command)
            Toggle("Layers", isOn: visibility(.layers)).keyboardShortcut("2", modifiers: .command)
            Toggle("Cell", isOn: visibility(.cell)).keyboardShortcut("3", modifiers: .command)
            Toggle("Channel strip", isOn: visibility(.channelStrip)).keyboardShortcut("4", modifiers: .command)
            Button(presentation.value.mode == .perform ? "Leave Performance Mode" : "Performance Mode") { workspace.togglePerformance(canvas: spatialInstrument.canvas) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            Button("Zoom In") { _ = spatialInstrument.perform(.zoomIn) }.keyboardShortcut("+", modifiers: .command)
            Button("Zoom Out") { _ = spatialInstrument.perform(.zoomOut) }.keyboardShortcut("-", modifiers: .command)
            Button("Reset View") { _ = spatialInstrument.perform(.resetView) }.keyboardShortcut("0", modifiers: .command)
            Button("Zoom to Measurement") { _ = spatialInstrument.perform(.zoomToMeasurement) }
        }
        CommandGroup(after: .windowArrangement) {
            Button("Output Monitor") { OutputMonitorWindowController.shared.show() }.keyboardShortcut("m", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .help) { Button("Planarium Help") { HelpWindowController.shared.show() }.keyboardShortcut("?", modifiers: .command) }
    }
    private func visibility(_ area: WorkspaceLayout.Area) -> Binding<Bool> {
        Binding(get: { workspace.preferences.visibility[area] }, set: { visible in
            menuController.authoring { workspace.setVisible(area, visible) }
        })
    }
    private func performUndo() {
        if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView || responder is NSTextField {
            menuController.undo(textResponder: { responder.undoManager?.undo() })
        } else { menuController.undo() }
    }
    private func performRedo() {
        if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView || responder is NSTextField {
            menuController.redo(textResponder: { responder.undoManager?.redo() })
        } else { menuController.redo() }
    }
    private func exportPreset() {
        guard presets.authorizeMutation() else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = presets.exportFileName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        presets.export(to: url)
    }
    private func importPresets() {
        guard presets.authorizeMutation() else { return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK else { return }
        presets.importFiles(panel.urls)
    }
}

enum PlanariumSettingsTab: String, CaseIterable {
    case tempo, performance, scanner, development, support
    var title: String {
        switch self {
        case .tempo: return "Tempo & Sync"
        case .performance: return "Performance"
        case .scanner: return "Scanner"
        case .development: return "Scanner Development"
        case .support: return "Support"
        }
    }
}
struct PlanariumSettingsView: View {
    @ObservedObject var workspace: WorkspaceControlModel
    let spatialInstrument: SpatialInstrumentRuntimeModel
    let scannerPassword: ScannerPasswordSettingsModel
    let scannerSetup: SetupConsoleModel
    let connection: StandardConnectionControlModel
    let commissioning: CommissioningControlModel
    let input: InputOwner
    let midi: MIDIPortOwner
    let recording: ProfileRecordingModel
    var footswitch: PanicFootswitchModel? = nil
    var presets: PresetControlModel? = nil
    var sourceCatalog: () -> [MIDITargetDescription] = { CoreMIDIClockSource.sources() }
    @State var selectedTab: PlanariumSettingsTab = .tempo
    var body: some View {
        let _ = ViewEvaluationProbe.current?.record("settings")
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Button labels", isOn: Binding(get: { workspace.preferences.buttonLabels }, set: { workspace.setButtonLabels($0) }))
                .toggleStyle(ReadableCheckboxStyle()).help("Show captions on icon buttons · ⌘⇧L").padding(12)
            if workspace.mode == .perform {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Scanner Development").font(.title2.bold())
                    ProfileRecordingControls(recording: recording, instrument: spatialInstrument)
                    Text(InstrumentAction.performanceLockReason).font(.caption).foregroundColor(.secondary)
                }.padding(20).frame(width: 620)
            } else {
                HStack(spacing: 4) {
                    ForEach(PlanariumSettingsTab.allCases.filter { $0 != .performance || (footswitch != nil && presets != nil) }, id: \.self) { tab in
                        Button { selectedTab = tab } label: {
                            Text(tab.title).font(.system(size: 11)).lineLimit(2).multilineTextAlignment(.center).padding(.horizontal,4)
                                .frame(maxWidth: .infinity,minHeight: 36)
                        }.buttonStyle(.plain)
                            .auditedButtonSurface(tab.title,font: 11,foreground: selectedTab == tab ? .black : .white,
                                background: selectedTab == tab ? StageTheme.amber : HelmutChrome.control)
                            .accessibilityLabel(tab.title).accessibilityValue(selectedTab == tab ? "selected" : "not selected")
                    }
                }.padding(.horizontal,12)
                Group {
                    switch selectedTab {
                    case .performance:
                        if let footswitch, let presets { PerformanceSettingsView(footswitch: footswitch,presets: presets,sources: sourceCatalog) }
                    case .tempo:
                        TempoSyncSettingsView(workspace: workspace,instrument: spatialInstrument,midi: midi,sourceCatalog: sourceCatalog)
                    case .scanner:
                        ScannerPasswordSettingsView(model: scannerPassword)
                    case .development:
                        ScannerDevelopmentSettingsView(model: scannerSetup,connection: connection,coordinator: input,instrument: spatialInstrument,recording: recording)
                    case .support:
                        ScrollView { CommissioningControlView(model: commissioning).padding(20) }.frame(width: 460,height: 560)
                    }
                }.frame(maxWidth: .infinity,maxHeight: .infinity,alignment: .topLeading)

            }

        }.environment(\.fieldToolbarLabels, workspace.preferences.buttonLabels).stageSettings()
    }
}

struct WorkspaceCommands: Commands {
    let instrument: SpatialInstrumentRuntimeModel
    @ObservedObject var presentation: MenuPresentationModel
    let presets: PresetControlModel
    @FocusedValue(\.duplicateLayer) private var duplicateLayer
    var body: some Commands {
        let _ = ViewEvaluationProbe.current?.record("workspace.commands")
        CommandGroup(after: .pasteboard) {
            Button("Duplicate Layer") {
                InstrumentMenuController(instrument: instrument, presets: presets).duplicateLayer(duplicateLayer.map { action in { action() } })
            }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(duplicateLayer == nil && !presentation.value.locked)
            Menu("Transpose") {
                Button("Up one semitone") { _ = instrument.applyPitchOperation(.transpose(1)) }.keyboardShortcut(.upArrow, modifiers: .option)
                Button("Down one semitone") { _ = instrument.applyPitchOperation(.transpose(-1)) }.keyboardShortcut(.downArrow, modifiers: .option)
                Button("Up one octave") { _ = instrument.applyPitchOperation(.transpose(12)) }.keyboardShortcut(.upArrow, modifiers: [.option, .shift])
                Button("Down one octave") { _ = instrument.applyPitchOperation(.transpose(-12)) }.keyboardShortcut(.downArrow, modifiers: [.option, .shift])
                Button("Invert chord down") { _ = instrument.applyPitchOperation(.invertDown) }.keyboardShortcut("[", modifiers: [.option, .command])
                Button("Invert chord up") { _ = instrument.applyPitchOperation(.invertUp) }.keyboardShortcut("]", modifiers: [.option, .command])
            }.disabled(presentation.value.locked)
        }
    }
}
@MainActor final class AppLifecycleObserver: ObservableObject {
    private let tokens = LifecycleNotifications(center: NSWorkspace.shared.notificationCenter)
    init(root: PlanariumComposition) {
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in Task { @MainActor in root.sleep() } })
        tokens.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in Task { @MainActor in root.wake() } })
    }

}

/// Observer installation is Main-only; exclusive token ownership allows
/// NotificationCenter removal during destruction without touching NSWorkspace.
private final class LifecycleNotifications: @unchecked Sendable {
    private let center: NotificationCenter
    private var values: [NSObjectProtocol] = []
    init(center: NotificationCenter) { self.center = center }
    @MainActor func append(_ value: NSObjectProtocol) { values.append(value) }
    deinit { for value in values { center.removeObserver(value) } }
}

/// Retains the composition for the App lifetime. No child publication is
/// forwarded; only views explicitly observing a child can be invalidated.
@MainActor final class AppOwnership<Models>: ObservableObject {
    let models: Models
    init(_ models: Models) { self.models = models }
}

private struct AudioOutputAlert: View {
    @ObservedObject var model: AudioOutputDeviceControlModel
    let authorize: () -> Bool
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .alert("Audio output changed", isPresented: Binding(
                get: { model.pendingDeviceAlert != nil },
                set: { if !$0 { model.acknowledgeDeviceAlert() } }
            )) {
                if model.canRestoreDevice {
                    Button("Restore saved output") {
                        if authorize() { model.restoreDesiredDevice() }
                        model.acknowledgeDeviceAlert()
                    }
                }
                Button("OK") { model.acknowledgeDeviceAlert() }
            } message: { Text(model.pendingDeviceAlert ?? "") }
    }
}


/// Consolidate native/legacy View menus while preserving native item targets.
/// CommandGroup uses the standard View menu; this also handles restored menus.
@MainActor enum ViewMenuRepair {
    static func install() {
        guard let menu = NSApp.mainMenu else { return }
        let views = menu.items.filter { $0.title == "View" }
        guard let first = views.first, let destination = first.submenu else { return }
        for duplicate in views.dropFirst() {
            if let source = duplicate.submenu {
                for item in source.items { source.removeItem(item); destination.addItem(item) }
            }
            menu.removeItem(duplicate)
        }
    }
}
