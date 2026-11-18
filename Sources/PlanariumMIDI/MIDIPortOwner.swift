import Combine
import Foundation
import PlanariumMusicCore
import PlanariumSoundCore

public struct MIDITargetDescription: Identifiable, Equatable, Sendable {
    public let id: Int32
    public let name: String
    public init(id: Int32, name: String) { self.id = id; self.name = name }
}
@MainActor public protocol MIDIConnectionBoundary: AnyObject {
    func destinations() -> [MIDITargetDescription]
    func open(_ target: InstrumentMIDITarget) -> Result<any MIDISendBoundary, MIDIConnectionError>
    func close()
    var onDestinationsChanged: (@MainActor () -> Void)? { get set }
    func stopObservingDestinations()
    var onDestinationLost: (@MainActor () -> Void)? { get set }
    func makeIndependentConnection() -> (any MIDIConnectionBoundary)?
}
public extension MIDIConnectionBoundary {
    var onDestinationsChanged: (@MainActor () -> Void)? { get { nil } set {} }
    func stopObservingDestinations() {}
    /// Fakes must explicitly supply a fake sibling; no implicit real MIDI.
    func makeIndependentConnection() -> (any MIDIConnectionBoundary)? { nil }
}
public struct MIDIConnectionError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// Main owns the transport lifetime; Q owns the only port note book.
/// Changing selection during ack collapses to the latest document target.
@MainActor public final class MIDIPortOwner: ObservableObject {
    @Published public private(set) var destinations: [MIDITargetDescription] = []
    @Published public private(set) var notice: String?
    @Published public private(set) var isRunning = false
    @Published public private(set) var target: InstrumentMIDITarget?
    private let preferences: UserDefaults
    public func programCountsFromOne(for uid: Int32) -> Bool {
        preferences.object(forKey: "midi.programCountsFromOne.\(uid)") as? Bool ?? true
    }
    public func rememberProgramCounting(_ value: Bool, for uid: Int32) {
        preferences.set(value, forKey: "midi.programCountsFromOne.\(uid)")
    }
    private let runtime: any OutputPortHost
    private let transport: any MIDIConnectionBoundary
    private var portID: UUID?
    private var retiring = false
    private var closed = false
    private var hasBound = false
    private var completions: [@MainActor () -> Void] = []
    private let destination: SpatialOutputDestination
    private var layerOwners: [Int32: MIDIPortOwner] = [:]
    private var pendingChildShutdowns = 0
    public init(runtime: any OutputPortHost, transport: any MIDIConnectionBoundary, destination: SpatialOutputDestination = .midi, preferences: UserDefaults = .standard) {
        self.runtime = runtime; self.transport = transport; self.preferences = preferences
        self.destination = destination
        transport.onDestinationLost = { [weak self] in self?.lost() }
        transport.onDestinationsChanged = { [weak self] in
            guard let self, !self.closed else { return }
            self.refresh()
            if !self.isRunning && self.target != nil { self.reconcile() }
        }
        refresh()
    }
    public func refresh() { guard !closed else { return }; destinations = transport.destinations() }
    public func apply(_ target: InstrumentMIDITarget?) {
        guard !closed, self.target != target else { return }
        self.target = target; reconcile()
    }
    public func apply(_ target: InstrumentMIDITarget?, layerTargets: [InstrumentMIDITarget]) {
        guard !closed else { return }
        apply(target)
        let requested = Dictionary(layerTargets.filter { $0.uniqueID != target?.uniqueID }.map { ($0.uniqueID, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, owner) in layerOwners { owner.apply(requested[id]) }
        for (id, target) in requested where layerOwners[id] == nil {
            guard let connection = transport.makeIndependentConnection() else {
                notice = "MIDI layer destination unavailable"; continue
            }
            let owner = MIDIPortOwner(runtime: runtime, transport: connection, destination: .midiEndpoint(uniqueID: id))
            layerOwners[id] = owner; owner.apply(target)
        }
    }
    public func retry() { guard !closed else { return }; reconcile() }
    public func shutdown(_ completion: @escaping @MainActor () -> Void) {
        completions.append(completion)
        guard !closed else { reconcile(); return }
        closed = true; target = nil
        pendingChildShutdowns = layerOwners.count
        for owner in layerOwners.values {
            owner.shutdown { [weak self] in
                guard let self else { return }
                self.pendingChildShutdowns -= 1; self.reconcile()
            }
        }
        reconcile()
    }
    private func lost() { notice = "MIDI destination unavailable"; reconcile() }
    private func reconcile() {
        guard !retiring else { return }
        if let portID {
            retiring = true
            runtime.retire(portID) { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.transport.close() // ack is the first disposal point
                    self.portID = nil; self.retiring = false; self.isRunning = false
                    self.reconcile()
                }
            }
            return
        }
        guard !closed, let target else {
            if closed && pendingChildShutdowns == 0 {
                transport.onDestinationLost = nil
                transport.onDestinationsChanged = nil
                transport.stopObservingDestinations()
                let callbacks = completions; completions.removeAll(); callbacks.forEach { $0() }
            }
            return
        }
        switch transport.open(target) {
        case .success(let boundary):
            let id = UUID(); portID = id
            // Reset all sixteen channels, including channels used by an earlier
            // binding/session of this endpoint whose note book is no longer here.
            runtime.attach(RuntimePorts.midi(id: id, boundary: boundary, resetOnBind: hasBound, destination: destination, uniqueID: target.uniqueID))
            hasBound = true
            isRunning = true; notice = nil
        case .failure(let error): notice = error.message; isRunning = false
        }
    }
}
