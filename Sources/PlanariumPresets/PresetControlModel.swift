import Combine
import Foundation
import PlanariumDomain
import SickPLSControlCore


@MainActor public protocol PresetDocumentControlling: AnyObject {
    var document: InstrumentDocument { get }
    var presetHasOpenPluginEditors: Bool { get }
    var presetChangeGeneration: UInt64 { get }
    var presetPluginChangeGeneration: UInt64 { get }
    var presetViewport: PresetViewport { get }
    var onPresetRecoveryChange: (() -> Void)? { get set }
    var onPresetRecoveryLockChange: (() -> Void)? { get set }
    var onPresetChannelSnapshot: ((InstrumentChannel) -> Void)? { get set }
    func commitPendingPresetEdits()
    func snapshotPresetDocument() throws -> InstrumentDocument
    func snapshotPresetDocument(comparingTo reference: InstrumentDocument) throws -> InstrumentDocument
    func setPresetComparisonReference(_ document: InstrumentDocument)
    func presetAuthoringDocument(comparingTo reference: InstrumentDocument) throws -> InstrumentDocument
    func applyPresetDocument(_ document: InstrumentDocument, restoringPluginStates: Bool) throws
    func applyPresetViewport(_ viewport: PresetViewport)
    func applyLegacyPresetViewport(_ viewport: ScanPlaneViewport)
    func restorePresetScene(_ id: UUID)
    func authorize(_ action: InstrumentAction) -> Bool
}

public extension PresetDocumentControlling {
    var presetHasOpenPluginEditors: Bool { false }
    var presetChangeGeneration: UInt64 { 0 }
    var presetPluginChangeGeneration: UInt64 { 0 }
    var onPresetRecoveryChange: (() -> Void)? { get { nil } set {} }
    var onPresetRecoveryLockChange: (() -> Void)? { get { nil } set {} }
    func restorePresetScene(_ id: UUID) {
        guard document.scenes.contains(where: { $0.id == id }) else { return }
        var next = document; next.currentSceneID = id
        try? applyPresetDocument(next, restoringPluginStates: false)
    }
    func commitPendingPresetEdits() {}
    func setPresetComparisonReference(_ document: InstrumentDocument) {}
    func presetAuthoringDocument(comparingTo reference: InstrumentDocument) throws -> InstrumentDocument { document }
    func snapshotPresetDocument(comparingTo reference: InstrumentDocument) throws -> InstrumentDocument {
        try snapshotPresetDocument()
    }
}

public enum PresetLoadDecision: Equatable, Sendable {
    case save
    case discard
    case cancel
}

public enum PresetConfirmationDecision: Equatable, Sendable {
    case none
    case confirmationRequired
}

public enum PresetTerminationPrompt: Equatable, Sendable {
    case none
    case save(name: String)
    case unsavedWithoutTarget
}

public enum PresetTerminationResult: Equatable, Sendable {
    case terminate
    case stayRunning
    case cancel
}

/// Preset UI owns file decisions only. The document owner validates and
/// installs one revision; absent channel metadata preserves the whole live
/// channel. Loading never starts the audio graph. Viewport is presentation.
@MainActor public final class PresetControlModel: ObservableObject {
    @Published public private(set) var names: [String] = []
    @Published public var draftName = "" {
        didSet {
            if !restoringDraft, draftName != oldValue, !authorizeMutation() {
                restoringDraft = true; draftName = oldValue; restoringDraft = false
            }
        }
    }
    @Published public var draftSummary = "" {
        didSet {
            if !restoringDraft, draftSummary != oldValue, !applyingLoadedSummary, !authorizeMutation() {
                restoringDraft = true; draftSummary = oldValue; restoringDraft = false
            } else if !restoringDraft, !applyingLoadedSummary, draftSummary != oldValue {
                noteRecoveryChange()
            }
        }
    }
    @Published public private(set) var loadedSummary = ""
    @Published public private(set) var menuSummaries: [String: String] = [:]
    @Published public private(set) var notice: String?
    @Published public private(set) var lastLoadedName: String?
    @Published public private(set) var isRecovered = false
    /// Der aus dem Preset geladene Ausschnitt -- von der Ansicht zu
    /// übernehmen und danach zu quittieren.
    @Published public private(set) var viewportToApply: ScanPlaneViewport?
    @Published public private(set) var pendingLoadName: String?
    @Published public private(set) var pendingSaveName: String?
    @Published public private(set) var pendingDeleteName: String?
    @Published public var isSaveAsPresented = false {
        didSet { if isSaveAsPresented, !authorizeMutation() { isSaveAsPresented = false } }
    }
    @Published public var isDescriptionEditorPresented = false {
        didSet { if isDescriptionEditorPresented, !authorizeMutation() { isDescriptionEditorPresented = false } }
    }
    @Published public var reopenLastPreset = true {
        didSet { recoveryDefaults?.set(reopenLastPreset, forKey: "reopenLastPreset") }
    }
    private var recoveryDefaults: UserDefaults?
    private var recoveryStore: PresetRecoveryStore?
    private var recoveryStopped = false
    private var recoveryRevision: UInt64 = 0
    private var recoveredRevision: UInt64 = 0
    private var recoveryDeadline: Date?
    private var recoveryDebounce: AnyCancellable?
    var recoveryNow: () -> Date = Date.init
    var scheduleRecovery: (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> AnyCancellable = { delay, action in
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        return AnyCancellable { timer.invalidate() }
    }
    public func stopRecovery() { recoveryStopped = true; recoveryDebounce = nil }
    public func noteRecoveryChange() {
        guard !recoveryStopped, recoveryStore != nil, !restoringStartup, !applyingLoadedSummary else { return }
        recoveryRevision &+= 1
        recoveryDeadline = recoveryNow().addingTimeInterval(10)
        armRecovery()
    }
    private func armRecovery() {
        recoveryDebounce = nil
        guard !recoveryStopped, recoveryRevision != recoveredRevision, let deadline = recoveryDeadline else { return }
        recoveryDebounce = scheduleRecovery(max(0, deadline.timeIntervalSince(recoveryNow()))) { [weak self] in
            guard let self else { return }
            self.captureRecoveryIfNeeded(now: self.recoveryNow())
        }
    }
    public func recoveryLockChanged() { armRecovery() }
    private var restoringStartup = false

    /// Explicit opt-in keeps test/document-only models independent of app preferences.
    public func configureRecovery(defaults: UserDefaults, store: PresetRecoveryStore) {
        recoveryStopped = false
        recoveryDefaults = defaults; recoveryStore = store
        reopenLastPreset = defaults.object(forKey: "reopenLastPreset") as? Bool ?? true
    }
    public func restoreStartup() {
        guard reopenLastPreset, let defaults = recoveryDefaults else { return }
        restoringStartup = true
        defer { restoringStartup = false }
        do {
            if let recovery = try recoveryStore?.read(),
               recovery.modified.timeIntervalSince1970 > defaults.double(forKey: "presetLastSaved") {
                let reading = try PresetDocumentReader.read(recovery.data).get()
                let generation = defaults.string(forKey: "presetRecoveryGeneration")
                let matchesGeneration = generation.map { reading.name == "Recovery_" + $0 } ?? true
                if matchesGeneration {
                    let next = try reading.replacing(documentOwner.document)
                    try documentOwner.applyPresetDocument(next, restoringPluginStates: true)
                    if let viewport = reading.viewport { documentOwner.applyPresetViewport(viewport) }
                    draftSummary = reading.summary; loadedSummary = reading.summary
                    lastLoadedName = defaults.string(forKey: "presetLastName").map(startupPresetName)
                    draftName = lastLoadedName.map(displayName(for:)) ?? "Untitled"
                    isRecovered = true
                    notice = "Recovered – not saved"
                    return
                }
                // A queued older snapshot can finish after Save but before its
                // queued deletion. A crash in that gap must still reopen Save.
                recoveryStore?.clear()
            }
            guard let name = defaults.string(forKey: "presetLastName") else { return }
            let scene = defaults.string(forKey: "presetLastScene").flatMap(UUID.init(uuidString:))
            // Keep persisted factory identity independent of user-name collisions,
            // while the loaded selection uses the current library's display key.
            let loadName = startupPresetName(name)
            guard (factoryData(named: name) != nil || storedNames.contains(name)), load(loadName, decision: .discard) != nil else {
                notice = "Last preset missing – empty workspace"; return
            }
            if let scene { documentOwner.restorePresetScene(scene) }
        } catch { notice = "Recovery rejected – empty workspace" }
    }
    private func startupPresetName(_ identity: String) -> String {
        guard identity.hasPrefix(Self.factoryPrefix) else { return identity }
        let name = String(identity.dropFirst(Self.factoryPrefix.count))
        return storedNames.contains(name) ? identity : name
    }
    public var recoveryTooltip: String {
        let text = "Recovered after restart – not saved. Save to keep, or load the preset again to discard."
        return lastLoadedName.map(isFactoryPreset) == true ? text + " Factory preset unchanged." : text
    }
    public func rememberCurrentScene() {
        recoveryDefaults?.set(documentOwner.document.currentSceneID?.uuidString, forKey: "presetLastScene")
    }
    public func captureRecoveryIfNeeded(now: Date = Date()) {
        guard !recoveryStopped, recoveryStore != nil, recoveryRevision != recoveredRevision,
              let deadline = recoveryDeadline, now >= deadline else { return }
        recoveryDebounce = nil
        guard documentOwner.authorize(.edit) else { return }
        let generation = recoveryDefaults?.string(forKey: "presetRecoveryGeneration") ?? UUID().uuidString
        recoveryDefaults?.set(generation, forKey: "presetRecoveryGeneration")
        if let preset = try? capture(name: "Recovery_" + generation) {
            recoveryStore?.write(preset); recoveredRevision = recoveryRevision
        }
    }
    private func rememberPreset(_ name: String) {
        guard !restoringStartup else { return }
        recoveryDebounce = nil; recoveredRevision = recoveryRevision; recoveryDeadline = nil
        let identity = isFactoryPreset(name) && !name.hasPrefix(Self.factoryPrefix) ? Self.factoryPrefix + name : name
        recoveryDefaults?.set(identity, forKey: "presetLastName")
        recoveryDefaults?.set(UUID().uuidString, forKey: "presetRecoveryGeneration")
        rememberCurrentScene()
        // Loading establishes a new baseline just as saving does.
        recoveryDefaults?.set(Date().timeIntervalSince1970, forKey: "presetLastSaved")
        recoveryStore?.clear()
    }
    private var applyingLoadedSummary = false
    private var restoringDraft = false
    @discardableResult public func authorizeMutation() -> Bool {
        guard documentOwner.authorize(.edit) else {
            notice = InstrumentAction.performanceLockReason
            return false
        }
        return true
    }

    private let store: PresetFileStore
    private let factoryPresets: FactoryPresetLibrary
    private let documentOwner: any PresetDocumentControlling
    private var storedNames: Set<String> = []
    private static let factoryPrefix = "Factory · "
    /// Der zuletzt von der Ansicht gemeldete Ausschnitt.
    public private(set) var knownViewport: ScanPlaneViewport = .fullField
    private var referenceDocument: InstrumentDocument?
    private var referenceAuthoringDocument: InstrumentDocument?
    private var referenceSummary = ""
    private var referencePluginGeneration: UInt64 = 0
    /// Decisions use deterministic authoring marks, never fresh AU state.
    private struct PendingLoad {
        let id = UUID()
        let name: String
        let revision: SpatialDocumentRevision
        let generation: UInt64
        let hasOpenEditors: Bool
        let summary: String
    }
    private var pendingLoad: PendingLoad?
    public var pendingLoadID: UUID? { pendingLoad?.id }

    public init(store: PresetFileStore, documentOwner: any PresetDocumentControlling,
                factoryPresets: FactoryPresetLibrary = .standard) {
        self.store = store; self.documentOwner = documentOwner; self.factoryPresets = factoryPresets
        referencePluginGeneration = documentOwner.presetPluginChangeGeneration
        refresh(); referenceDocument = try? semanticDocument(documentOwner.snapshotPresetDocument())
        referenceAuthoringDocument = semanticDocument(documentOwner.document)
        if let referenceDocument { documentOwner.setPresetComparisonReference(referenceDocument) }
        documentOwner.onPresetRecoveryChange = { [weak self] in
            self?.objectWillChange.send()
            self?.noteRecoveryChange()
        }
        documentOwner.onPresetRecoveryLockChange = { [weak self] in self?.recoveryLockChanged() }
        documentOwner.onPresetChannelSnapshot = { [weak self] channel in self?.captureUnspecifiedStates(channel) }
    }
    public var isDirty: Bool { !unsavedChangeReasons.isEmpty }
    public var unsavedChangeReasons: [String] {
        var reasons: [String] = []
        if isRecovered { reasons.append("Recovered after restart – not saved") }
        if draftSummary != referenceSummary { reasons.append("Description changed") }
        if documentOwner.presetHasOpenPluginEditors || documentOwner.presetPluginChangeGeneration != referencePluginGeneration { reasons.append("Plugin settings changed") }
        guard let referenceDocument = referenceAuthoringDocument,
              let snapshot = try? documentOwner.presetAuthoringDocument(comparingTo: referenceDocument) else {
            return reasons + ["Instrument settings unavailable"]
        }
        let current = semanticDocument(snapshot)
        if current.spatial != referenceDocument.spatial { reasons.append("Surfaces or layers changed") }
        if current.scenes != referenceDocument.scenes || current.currentSceneID != referenceDocument.currentSceneID { reasons.append("Scenes changed") }
        if current.beatsPerMinute != referenceDocument.beatsPerMinute { reasons.append("Tempo changed") }
        if current.detection != referenceDocument.detection { reasons.append("Detection settings changed") }
        if current.channels != referenceDocument.channels {
            var withoutStates = current
            for index in withoutStates.channels.indices {
                guard let saved = referenceDocument.channels.first(where: { $0.id == withoutStates.channels[index].id }) else { continue }
                if withoutStates.channels[index].instrument?.identity == saved.instrument?.identity {
                    withoutStates.channels[index].instrument?.state = saved.instrument?.state ?? Data()
                }
                for insert in withoutStates.channels[index].inserts.indices {
                    if let old = saved.inserts.first(where: { $0.id == withoutStates.channels[index].inserts[insert].id && $0.plugin.identity == withoutStates.channels[index].inserts[insert].plugin.identity }) {
                        withoutStates.channels[index].inserts[insert].plugin.state = old.plugin.state
                    }
                }
            }
            var onlyStates = referenceDocument; onlyStates.channels = current.channels
            var comparableStates = referenceDocument; comparableStates.channels = withoutStates.channels
            if !equivalent(onlyStates, comparableStates) { reasons.append("Plugin settings changed") }
            if withoutStates.channels != referenceDocument.channels { reasons.append("Channels changed") }
        }
        // Catch every persisted field, including future additions.
        if !equivalent(current, referenceDocument), reasons.isEmpty { reasons.append("Instrument settings changed") }
        return reasons
    }
    public var unsavedChangesDescription: String { unsavedChangeReasons.joined(separator: " · ") }
    /// Passive reads and decisions use authoring values and editor events.
    public var presentationIsDirty: Bool {
        if isRecovered { return true }
        guard !documentOwner.presetHasOpenPluginEditors, draftSummary == referenceSummary, documentOwner.presetPluginChangeGeneration == referencePluginGeneration, referenceDocument != nil,
              let referenceAuthoringDocument,
              let current = try? documentOwner.presetAuthoringDocument(comparingTo: referenceAuthoringDocument) else { return true }
        return !equivalent(semanticDocument(current), referenceAuthoringDocument)
    }

    public var terminationPrompt: PresetTerminationPrompt {
        guard isDirty else { return .none }
        guard let lastLoadedName, !isFactoryPreset(lastLoadedName) else {
            return .unsavedWithoutTarget
        }
        return .save(name: lastLoadedName)
    }

    @discardableResult
    public func resolveTermination(_ decision: PresetLoadDecision) -> PresetTerminationResult {
        guard isDirty else { return .terminate }
        switch decision {
        case .cancel:
            return .cancel
        case .discard:
            return .terminate
        case .save:
            guard let lastLoadedName, !isFactoryPreset(lastLoadedName) else {
                notice = "Save failed: No savable last-loaded preset."
                return .stayRunning
            }
            return save(name: lastLoadedName) ? .terminate : .stayRunning
        }
    }

    public func refresh() {
        do {
            let stored = try store.list()
            storedNames = Set(stored)
            names = factoryPresets.names.map { storedNames.contains($0) ? Self.factoryPrefix + $0 : $0 } + stored
            menuSummaries = Dictionary(uniqueKeysWithValues: names.map { name in
                let data = factoryData(named: name) ?? (try? store.load(name))
                let root = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                return (name, root?["summary"] as? String ?? "")
            })
        } catch {
            notice = "Preset list unreadable: \(error)"
        }
    }

    // MARK: - Aufnehmen

    /// Captures the authoritative fine lattice and current AU states on Main.
    public func capture(name: String) throws -> InstrumentPresetV6 {
        documentOwner.commitPendingPresetEdits()
        return .init(name: name, document: try documentOwner.snapshotPresetDocument(), viewport: documentOwner.presetViewport, summary: draftSummary)
    }
    /// Die Ansicht meldet ihren aktuellen Ausschnitt.
    public func noteViewport(_ viewport: ScanPlaneViewport) {
        objectWillChange.send()
        knownViewport = viewport
    }

    public func noteSpatialWorkspace(_ workspace: SpatialInstrumentWorkspace) {
        _ = workspace
        objectWillChange.send()
    }

    @discardableResult
    public func save() -> Bool {
        let name = draftName.trimmingCharacters(in: .whitespaces)
        return save(name: name)
    }

    @discardableResult
    private func save(name: String) -> Bool {
        guard authorizeMutation() else { return false }
        guard !isFactoryPreset(name) else {
            notice = "Factory presets are read-only. Please choose a different name."
            return false
        }
        guard PresetFileStore.isValidName(name) else {
            notice = "Invalid name: letters, digits, spaces, - and _ (1…64 characters)."
            return false
        }
        do {
            guard draftSummary.count <= InstrumentPresetV6.maximumSummaryCharacters else {
                notice = "Save failed: Description must be 1000 characters or fewer."
                return false
            }
            let captured = try capture(name: name)
            let data = try PresetDocumentWriter.encode(captured)
            try store.save(data, as: name)
            isRecovered = false
            notice = "Saved: \(name)"
            referenceDocument = semanticDocument(captured.document)
            documentOwner.setPresetComparisonReference(captured.document)
            referenceAuthoringDocument = semanticDocument(documentOwner.document)
            referencePluginGeneration = documentOwner.presetPluginChangeGeneration
            referenceSummary = captured.summary
            if lastLoadedName == name { loadedSummary = captured.summary }
            rememberPreset(name)
            refresh()
            return true
        } catch {
            notice = "Save failed: preset or snapshot rejected."
            return false
        }
    }

    public func delete(_ name: String) {
        delete(name, confirmed: true)
    }

    public func deleteDecision(for name: String) -> PresetConfirmationDecision {
        isFactoryPreset(name) ? .none : .confirmationRequired
    }

    public func delete(_ name: String, confirmed: Bool) {
        guard confirmed else { return }
        guard authorizeMutation() else { return }
        guard !isFactoryPreset(name) else {
            notice = "Factory presets cannot be deleted."
            return
        }
        do {
            try store.delete(name)
            if lastLoadedName == name {
                // The document remains live, but it no longer represents a
                // persisted preset.  Keeping a deleted name in the picker
                // would claim a loaded preset that cannot be selected.
                lastLoadedName = nil
                loadedSummary = ""
            }
            notice = nil
            refresh()
        } catch {
            notice = "Delete failed: \(error)"
        }
    }

    // MARK: - Laden

    /// Lädt ein Preset nach der Reihenfolge im Typkommentar. Gibt das
    /// aufgelöste Preset zurück oder `nil`, wenn nichts verändert wurde.
    @discardableResult
    public func load(_ name: String) -> PresetReading? {
        guard !isDirty else {
            pendingLoad = loadCheckpoint(name)
            pendingLoadName = name
            notice = "Unsaved changes – decision required."
            return nil
        }
        return loadResolved(name)
    }

    @discardableResult
    public func load(_ name: String, decision: PresetLoadDecision) -> PresetReading? {
        if decision == .cancel { cancelPendingLoad(); return nil }
        if let pending = pendingLoad, pending.name == name {
            guard pending.revision == documentOwner.document.revision,
                  pending.summary == draftSummary,
                  pending.generation == documentOwner.presetChangeGeneration,
                  pending.hasOpenEditors == documentOwner.presetHasOpenPluginEditors else {
                repeatLoadDecision(name)
                return nil
            }
            cancelPendingLoad()
        }
        switch decision {
        case .cancel:
            return nil
        case .discard:
            return loadResolved(name)
        case .save:
            guard let lastLoadedName, !isFactoryPreset(lastLoadedName) else {
                notice = "Save failed: No savable last-loaded preset."
                return nil
            }
            guard save(name: lastLoadedName) else { return nil }
            return loadResolved(name)
        }
    }

    private func loadResolved(_ name: String) -> PresetReading? {
        guard documentOwner.authorize(.loadPreset) else { return nil }
        applyingLoadedSummary = true
        defer { applyingLoadedSummary = false }
        do {
            let data = try factoryData(named: name) ?? store.load(name)
            let reading = try PresetDocumentReader.read(data).get()
            let live = reading.includesChannel ? documentOwner.document : try documentOwner.snapshotPresetDocument()
            let next = try reading.replacing(live)
            try documentOwner.applyPresetDocument(next, restoringPluginStates: reading.sourceVersion >= 5 && reading.includesChannel)
            if let viewport = reading.viewport { documentOwner.applyPresetViewport(viewport) }
            if let viewport = reading.legacyViewport {
                documentOwner.applyLegacyPresetViewport(viewport); viewportToApply = viewport
            }
            lastLoadedName = name
            isRecovered = false
            loadedSummary = reading.summary; draftSummary = reading.summary
            referencePluginGeneration = documentOwner.presetPluginChangeGeneration
            referenceSummary = reading.summary
            // The desired preset state is the reference. Pending/failed AU work
            // and later editor changes cannot be swallowed by a failed snapshot.
            referenceDocument = semanticDocument(next)
            referenceAuthoringDocument = semanticDocument(documentOwner.document)
            if reading.sourceVersion < 5, let snapshot = try? documentOwner.snapshotPresetDocument() {
                referenceDocument = semanticDocument(snapshot)
            } else if let snapshot = try? documentOwner.snapshotPresetDocument() {
                for channel in snapshot.channels { captureUnspecifiedStates(channel) }
            }
            if let referenceDocument { documentOwner.setPresetComparisonReference(referenceDocument) }
            notice = "Loaded: \(name) – nothing started."
            if let migration = reading.loadNotice { notice = "Loaded: \(name). \(migration)" }
            rememberPreset(name)
            return reading
        } catch {
            notice = "Not loaded, nothing changed: preset rejected."
            return nil
        }
    }

    public func resolvePendingLoad(_ decision: PresetLoadDecision, confirmationID: UUID? = nil) {
        guard let pending = pendingLoad else { return }
        _ = load(pending.name, decision: decision)
    }

    public func cancelPendingLoad(confirmationID: UUID? = nil) {
        pendingLoad = nil
        pendingLoadName = nil
    }

    private func loadCheckpoint(_ name: String) -> PendingLoad {
        .init(name: name, revision: documentOwner.document.revision,
              generation: documentOwner.presetChangeGeneration,
              hasOpenEditors: documentOwner.presetHasOpenPluginEditors, summary: draftSummary)
    }

    private func repeatLoadDecision(_ name: String) {
        let checkpoint = loadCheckpoint(name)
        pendingLoad = checkpoint
        pendingLoadName = nil
        notice = "Changed meanwhile – choose again"
        // Let SwiftUI finish dismissing the old alert before presenting the
        // new decision. A cancel or another request invalidates this task.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.pendingLoad?.id == checkpoint.id else { return }
            self.pendingLoadName = name
        }
    }

    public func saveDecision(for name: String) -> PresetConfirmationDecision {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard PresetFileStore.isValidName(trimmed), !isFactoryPreset(trimmed) else { return .none }
        guard names.contains(trimmed), trimmed != lastLoadedName else { return .none }
        return .confirmationRequired
    }

    public func requestSave() {
        guard authorizeMutation() else { return }
        guard let lastLoadedName, !isFactoryPreset(lastLoadedName) else {
            beginSaveAs()
            return
        }
        _ = save(name: lastLoadedName)
    }

    /// Starts a library save with a name appropriate for the loaded state.
    /// The existing replacement decision remains the sole overwrite gate.
    public func beginSaveAs() {
        guard authorizeMutation() else { return }
        documentOwner.commitPendingPresetEdits()
        let loadedName = lastLoadedName.map(displayName(for:))
        if let loadedName {
            draftName = isFactoryPreset(lastLoadedName ?? "") ? "\(loadedName) Copy" : loadedName
        } else if draftName.trimmingCharacters(in: .whitespaces).isEmpty {
            draftName = "Preset"
        }
        isSaveAsPresented = true
    }

    public func editDescription() {
        guard authorizeMutation() else { return }
        isDescriptionEditorPresented = true
    }

    /// Saves the name and description currently entered in the Save As sheet.
    /// A successful Save As becomes the loaded library preset.
    public func commitSaveAs() {
        guard authorizeMutation() else { return }
        let name = draftName.trimmingCharacters(in: .whitespaces)
        if saveDecision(for: name) == .confirmationRequired {
            pendingSaveName = name
        } else if save(name: name) {
            adoptSavedPreset(named: name)
            isSaveAsPresented = false
        }
    }

    public func resolvePendingSave(confirmed: Bool) {
        if confirmed, !authorizeMutation() { return }
        guard let name = pendingSaveName else { return }
        pendingSaveName = nil
        guard confirmed else { return }
        if save(name: name), isSaveAsPresented {
            adoptSavedPreset(named: name)
            isSaveAsPresented = false
        }
    }

    public func requestDelete(_ name: String) {
        guard authorizeMutation() else { return }
        if deleteDecision(for: name) == .confirmationRequired {
            pendingDeleteName = name
        } else {
            delete(name, confirmed: true)
        }
    }

    public func resolvePendingDelete(confirmed: Bool) {
        guard let name = pendingDeleteName else { return }
        pendingDeleteName = nil
        delete(name, confirmed: confirmed)
    }

    public func isFactoryPreset(_ name: String) -> Bool {
        factoryData(named: name) != nil
    }

    /// The export is deliberately encoded anew with the V6 encoder, rather
    /// than copying a library file: it is the current, complete document.
    public var exportFileName: String {
        let candidate = lastLoadedName ?? draftName.trimmingCharacters(in: .whitespaces)
        let name = PresetFileStore.isValidName(candidate) ? candidate : "Preset"
        return "\(name).\(PresetFileStore.fileExtension)"
    }

    public func export(to url: URL) {
        guard authorizeMutation() else { return }
        // The chosen filename is the portable preset's identity.  Library
        // identity remains untouched, so Export can never replace a preset.
        let filename = url.lastPathComponent
        let suffix = ".\(PresetFileStore.fileExtension)"
        let name = (filename.hasSuffix(suffix)
            ? String(filename.dropLast(suffix.count))
            : url.deletingPathExtension().lastPathComponent).trimmingCharacters(in: .whitespaces)
        guard PresetFileStore.isValidName(name) else {
            notice = "Export failed: Invalid file name; use letters, digits, spaces, - and _ (1…64 characters)."
            return
        }
        do {
            let data = try PresetDocumentWriter.encode(capture(name: name))
            try data.write(to: url, options: .atomic)
            notice = "Exported: \(name)"
        } catch {
            notice = "Export failed: current preset was not written."
        }
    }

    /// Every selected file is validated independently.  A bad neighbour can
    /// never prevent a good preset from reaching the library.
    public func importFiles(_ urls: [URL]) {
        guard authorizeMutation() else { return }
        var imported: [String] = []
        var rejected: [String] = []
        for url in urls {
            var stage = "file read"
            do {
                let data = try Data(contentsOf: url)
                stage = "preset validation"
                let reading = try PresetDocumentReader.read(data).get()
                let name = uniqueImportedName(reading.name)
                // The library has one stable wire format.  Reading remains
                // backwards compatible, but imported legacy input is never
                // retained as a second persistence dialect.
                // Importing builds a library document, not a patch against
                // whatever preset happens to be open.  This fixed seed makes
                // identical legacy input produce identical canonical V6 bytes.
                let seed = try FactoryPresetDocument.empty()
                stage = "format conversion"
                let canonical = try PresetDocumentWriter.encode(.init(name: name, document: try reading.replacing(seed), viewport: reading.viewport, includesChannel: reading.includesChannel, summary: reading.summary))
                stage = "library write"
                try store.save(canonical, as: name)
                imported.append(name)
                storedNames.insert(name)
            } catch {
                // Explain the failed boundary, never echo parser contents,
                // paths or plug-in state from the exception.
                rejected.append("\(url.lastPathComponent) (\(stage))")
            }
        }
        refresh()
        if rejected.isEmpty { notice = "Imported: \(imported.joined(separator: ", "))" }
        else if imported.isEmpty { notice = "Not imported: \(rejected.joined(separator: ", "))" }
        else { notice = "Imported: \(imported.joined(separator: ", ")). Not imported: \(rejected.joined(separator: ", "))" }
    }

    private func uniqueImportedName(_ proposed: String) -> String {
        let base = PresetFileStore.isValidName(proposed) ? proposed : "Imported Preset"
        let occupied = Set(names.map { $0.hasPrefix(Self.factoryPrefix) ? String($0.dropFirst(Self.factoryPrefix.count)) : $0 })
        guard !occupied.contains(base) else {
            var number = 2
            while occupied.contains("\(base) \(number)") { number += 1 }
            return "\(base) \(number)"
        }
        return base
    }
    private func factoryData(named name: String) -> Data? {
        if name.hasPrefix(Self.factoryPrefix) {
            return factoryPresets.data(named: String(name.dropFirst(Self.factoryPrefix.count)))
        }
        return storedNames.contains(name) ? nil : factoryPresets.data(named: name)
    }

    private func displayName(for name: String) -> String {
        name.hasPrefix(Self.factoryPrefix) ? String(name.dropFirst(Self.factoryPrefix.count)) : name
    }

    private func adoptSavedPreset(named name: String) {
        lastLoadedName = name
        loadedSummary = draftSummary
    }

    /// Die Ansicht hat den Ausschnitt übernommen.
    public func acknowledgeViewport() {
        viewportToApply = nil
    }

    /// Empty saved state means the AU's initial/retained state. Capture it
    /// once when the host actually loads, then editor changes remain dirty.
    private func captureUnspecifiedStates(_ snapshot: InstrumentChannel) {
        guard var reference = referenceDocument else { return }
        guard let channelIndex = reference.channels.firstIndex(where: { $0.id == snapshot.id }) else { return }
        if let plugin = snapshot.instrument, reference.channels[channelIndex].instrument?.identity == plugin.identity,
           reference.channels[channelIndex].instrument?.state.isEmpty == true {
            reference.channels[channelIndex].instrument?.state = plugin.state
        }
        for index in reference.channels[channelIndex].inserts.indices where reference.channels[channelIndex].inserts[index].plugin.state.isEmpty {
            let old = reference.channels[channelIndex].inserts[index]
            if let insert = snapshot.inserts.first(where: { $0.id == old.id && $0.plugin.identity == old.plugin.identity }) {
                reference.channels[channelIndex].inserts[index].plugin.state = insert.plugin.state
            }
        }
        referenceDocument = reference
        documentOwner.setPresetComparisonReference(reference)
    }

    private func equivalent(_ lhs: InstrumentDocument, _ rhs: InstrumentDocument) -> Bool {
        var comparable = lhs
        for channelIndex in comparable.channels.indices {
            guard let rightChannel = rhs.channels.first(where: { $0.id == comparable.channels[channelIndex].id }) else { continue }
            if let left = comparable.channels[channelIndex].instrument, let right = rightChannel.instrument,
               InstrumentPluginState.equivalent(left.state, right.state) { comparable.channels[channelIndex].instrument?.state = right.state }
            for index in comparable.channels[channelIndex].inserts.indices {
                if let right = rightChannel.inserts.first(where: { $0.id == comparable.channels[channelIndex].inserts[index].id }),
                   InstrumentPluginState.equivalent(comparable.channels[channelIndex].inserts[index].plugin.state, right.plugin.state) {
                    comparable.channels[channelIndex].inserts[index].plugin.state = right.plugin.state
                }
            }
        }
        return comparable == rhs
    }

    private func semanticDocument(_ value: InstrumentDocument) -> InstrumentDocument {
        var copy = value
        copy.detection.roomContour = .init()
        copy.revision = SpatialDocumentRevision(session: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, counter: 0)
        if let first = copy.spatial.layers.first, let spatial = try? copy.spatial.replacingLayers(copy.spatial.layers, selectedLayerID: first.id) { copy.spatial = spatial }
        return copy
    }
}
