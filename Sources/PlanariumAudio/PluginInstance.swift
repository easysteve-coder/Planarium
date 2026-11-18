import AppKit
import Foundation
import PlanariumDomain
@_spi(AudioHost) import PlanariumRuntime
import PlanariumHostClockDSP

/// One AU, one editor for its whole lifetime, at most one window. Many AUs
/// hand out their own editor only once per instance (owner run 07.10.2026:
/// a second request fell back to the generic view). Closing the window
/// detaches the editor view from every window, which stops its drawing;
/// the controller is released only with the AU. AudioHost controls removal
/// from the graph; beginRelease -> graph.remove -> finishRelease is mandatory.
@MainActor public final class PluginInstance {
    public var onEditorClosed: (() -> Void)?
    public let id = UUID()
    public let identity: SpatialAudioUnitIdentity
    private(set) var unit: (any PluginUnit)?
    public private(set) var editor: (any PluginEditor)?
    public private(set) var window: (any PluginWindow)?
    private let windows: any PluginWindowFactory
    private var editorRequested = false
    private var editorGeneration: UInt64 = 0
    private var releaseStarted = false
    private var wantsEditor = false
    private var editorAllowed: @MainActor () -> Bool = { true }
    private var editorOffscreen = false
    private var editorTitle = "Plug-in"
    private var appliedState: Data?
    private var snapshotState: Data?
    private var snapshotFingerprint: Data?
    private var appliedFingerprint: Data?
    private var comparisonState: Data?
    private var comparisonFingerprint: Data?
    private var appliedBypass: Bool?
    private var reportedBypass: Bool?
    private var bypassMailbox: PluginBypassMailbox?
    var effectiveBypass: Bool { reportedBypass ?? appliedBypass ?? false }
    private var unspecifiedState: Data?
    private var hostClockBinding: PlanariumHostClockBinding?
    // A plug-in may cache the host blocks across resource allocation. Keep
    // their C cursor alive for the whole instance, not just one graph attach.
    func bindHostClock(_ clock: HostMusicalClock, sampleRate: Double, offline: Bool) throws -> PlanariumHostClockBinding {
        if let hostClockBinding {
            hostClockBinding.configure(withClock: clock.storage, sampleRate: sampleRate, offline: offline)
            return hostClockBinding
        }
        guard let node = unit?.audioNode,
              let binding = PlanariumHostClockBinding(unit: node.auAudioUnit, owner: node, clock: clock.storage, sampleRate: sampleRate, offline: offline) else {
            throw PluginLoadError("Host musical context allocation failed")
        }
        hostClockBinding = binding
        return binding
    }

    init(identity: SpatialAudioUnitIdentity, unit: any PluginUnit, windows: any PluginWindowFactory) {
        self.identity = identity; self.unit = unit; self.windows = windows
    }
    public var parameters: [AudioUnitParameterDescriptor] { unit?.parameterDescriptors ?? [] }
    public func readState() throws -> Data {
        guard let unit else { throw PluginLoadError("Plug-in has been released") }
        let state = try unit.readState()
        snapshotState = state; snapshotFingerprint = unit.musicalStateFingerprint
        return state
    }
    public func readState(comparingTo reference: Data) throws -> Data {
        if let fingerprint = unit?.musicalStateFingerprint,
           comparisonState == reference, comparisonFingerprint == fingerprint { return reference }
        guard let unit else { throw PluginLoadError("Plug-in has been released") }
        // A dirty probe must not replace the saved baseline fingerprint.
        return try unit.readState()
    }
    /// Pin exactly the saved/load reference, never an incidental snapshot.
    /// Memory is bounded to the applied, most recent and saved states, with
    /// Data sharing their existing immutable storage.
    func pinComparisonState(_ state: Data?) {
        if state == comparisonState, comparisonFingerprint != nil { return }
        comparisonState = state; comparisonFingerprint = nil
        guard let state else { return }
        if state == snapshotState { comparisonFingerprint = snapshotFingerprint }
        else if state == appliedState { comparisonFingerprint = appliedFingerprint }
    }
    var needsUnspecifiedStateCapture: Bool { unspecifiedState == nil }
    func captureUnspecifiedState() throws -> Data {
        if let unspecifiedState { return unspecifiedState }
        let state = try readState()
        unspecifiedState = state
        return state
    }
    func needsStateRefresh(_ data: Data) -> Bool { !data.isEmpty && appliedState != data }
    /// Explicit preset restoration must also detect edits made inside the AU
    /// since the previous command. Invalidating the cache changes no AU state;
    /// the instrument still retires Q before the subsequent fullState write.
    func prepareStateRestore(_ data: Data) {
        guard !data.isEmpty else { return }
        if let current = try? readState(), InstrumentPluginState.equivalent(current, data) {
            appliedState = data
        } else { appliedState = nil }
    }
    func applyState(_ data: Data) throws {
        guard data != appliedState else { return }
        // Empty domain data means no stored state, not a reset of this AU.
        if !data.isEmpty { try unit?.setState(data) }
        appliedState = data
        appliedFingerprint = unit?.musicalStateFingerprint
    }
    func applyBypass(_ bypassed: Bool) {
        guard bypassed != appliedBypass else { return }
        reportedBypass = nil
        unit?.setBypass(bypassed); appliedBypass = bypassed
    }
    func setBypassFromStrip(_ value: Bool) {
        appliedBypass = nil; applyBypass(value)
    }
    func observeBypass(_ changed: @escaping @MainActor @Sendable (Bool) -> Void) {
        bypassMailbox?.cancel()
        let mailbox = PluginBypassMailbox { [weak self] value in
            guard let self, !self.releaseStarted else { return }
            self.reportedBypass = value
            changed(value)
        }
        bypassMailbox = mailbox
        unit?.observeBypass { [mailbox] value in mailbox.send(value) }
    }
    func scheduleBoundary() -> (any AUScheduleBoundary)? {
        unit?.scheduleBoundary(identity: identity)
    }
    public func openEditor(title: String, offscreen: Bool = false, allowed: @escaping @MainActor () -> Bool = { true }) {
        guard !releaseStarted, allowed(), let unit else { return }
        editorAllowed = allowed
        wantsEditor = true; editorOffscreen = offscreen; editorTitle = title
        if let window { window.show(offscreen: offscreen); return }
        if let editor { present(editor); return }
        guard !editorRequested else { return }
        editorRequested = true
        let generation = editorGeneration
        unit.requestEditor { [weak self] editor in
            guard let self, !self.releaseStarted, self.editorGeneration == generation else { editor.stopObserving(); return }
            self.editor = editor
            if self.wantsEditor { self.present(editor) }
        }
    }
    public func closeEditor() {
        wantsEditor = false
        let closing = window
        dismantleEditor()
        closing?.close()
    }
    private func dismantleEditor() {
        let wasOpen = window != nil
        wantsEditor = false
        editor?.stopObserving()
        window?.clearEditor()
        window = nil
        if wasOpen { onEditorClosed?() }
        // A pending request stays valid: its editor is kept for the next open.
    }
    private func releaseEditor() {
        editorGeneration &+= 1
        editorRequested = false
        editor = nil
    }
    private func present(_ editor: any PluginEditor) {
        guard editorAllowed() else { wantsEditor = false; return }
        let size = Self.valid(editor.initialSize) ? editor.initialSize : NSSize(width: 640, height: 480)
        let window = windows.make(title: editorTitle, size: size)
        self.window = window
        window.observeClose { [weak self] in self?.dismantleEditor() }
        window.install(editor)
        window.resize(size)
        editor.observeSize { [weak self] size in
            guard let self, !self.releaseStarted, Self.valid(size), let window = self.window else { return }
            // Compare content with content, including shrink in either axis.
            guard abs(window.contentSize.width - size.width) > 0.5 ||
                    abs(window.contentSize.height - size.height) > 0.5 else { return }
            window.resize(size)
        }
        window.show(offscreen: editorOffscreen)
    }
    private static func valid(_ size: NSSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 1 && size.height > 1
    }
    func beginRelease() {
        releaseStarted = true; wantsEditor = false
        bypassMailbox?.cancel(); bypassMailbox = nil
        unit?.observeBypass(nil)
        closeEditor()
        releaseEditor()
    }
    func finishRelease() { hostClockBinding = nil; unit = nil }
}
