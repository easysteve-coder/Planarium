import CoreMIDI
import Darwin
import Foundation
import Dispatch
import PlanariumDomain
import PlanariumRuntime

/// Main owns client/port disposal; Q receives only immutable handles.
@MainActor public final class CoreMIDIConnection: MIDIConnectionBoundary {
    private var client = MIDIClientRef()
    private var catalogClient = MIDIClientRef()
    private var port = MIDIPortRef()
    private var endpoint = MIDIEndpointRef()
    private var virtualSource = false
    public var onDestinationsChanged: (@MainActor () -> Void)?
    public var onDestinationLost: (@MainActor () -> Void)?
    public init() {}
    public func makeIndependentConnection() -> (any MIDIConnectionBoundary)? { CoreMIDIConnection() }
    public func stopObservingDestinations() {
        if catalogClient != 0 { MIDIClientDispose(catalogClient); catalogClient = 0 }
    }
    public func destinations() -> [MIDITargetDescription] {
        if catalogClient == 0 {
            // Catalog lifetime is independent of an open output, so additions
            // also refresh an unbound or missing saved destination.
            _ = MIDIClientCreateWithBlock("Planarium Destinations" as CFString, &catalogClient) { [weak self] notification in
                switch notification.pointee.messageID {
                case .msgSetupChanged, .msgObjectAdded, .msgObjectRemoved, .msgPropertyChanged:
                    DispatchQueue.main.async { [weak self] in self?.onDestinationsChanged?() }
                default: break
                }
            }
        }
        return (0..<MIDIGetNumberOfDestinations()).compactMap { index in
            let endpoint = MIDIGetDestination(index)
            var id: Int32 = 0
            guard endpoint != 0, MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &id) == noErr else { return nil }
            var name: Unmanaged<CFString>?
            let label: String
            if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name) == noErr, let value = name?.takeRetainedValue() {
                label = value as String
            } else { label = "MIDI \(id)" }
            return .init(id: id, name: label)
        }
    }
    public func open(_ target: InstrumentMIDITarget) -> Result<any MIDISendBoundary, MIDIConnectionError> {
        guard client == 0 else { return .failure(.init("MIDI connection already open")) }
        var object = MIDIObjectRef(); var type = MIDIObjectType.other
        guard target.uniqueID == 0 || (MIDIObjectFindByUniqueID(target.uniqueID, &object, &type) == noErr && type == .destination) else {
            return .failure(.init("MIDI destination unavailable"))
        }
        let result = MIDIClientCreateWithBlock("Planarium" as CFString, &client) { [weak self] notification in
            guard notification.pointee.messageID == .msgObjectRemoved else { return }
            let removed = notification.withMemoryRebound(to: MIDIObjectAddRemoveNotification.self, capacity: 1) { $0.pointee.child }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.endpoint == removed else { return }
                self.onDestinationLost?()
            }
        }
        guard result == noErr else { client = 0; return .failure(.init("MIDI client could not open")) }
        if target.uniqueID == 0 {
            guard MIDISourceCreate(client, "Planarium" as CFString, &endpoint) == noErr else {
                MIDIClientDispose(client); client = 0; return .failure(.init("MIDI source could not open"))
            }
            virtualSource = true
            return .success(CoreMIDISendBoundary(port: 0, endpoint: endpoint, uniqueID: nil))
        }
        guard MIDIOutputPortCreate(client, "Planarium Out" as CFString, &port) == noErr else {
            MIDIClientDispose(client); client = 0
            return .failure(.init("MIDI port could not open"))
        }
        endpoint = object
        return .success(CoreMIDISendBoundary(port: port, endpoint: endpoint, uniqueID: target.uniqueID))
    }
    public func close() {
        if virtualSource, endpoint != 0 { MIDIEndpointDispose(endpoint) }
        if port != 0 { MIDIPortDispose(port) }
        if client != 0 { MIDIClientDispose(client) }
        port = 0; client = 0; endpoint = 0; virtualSource = false
    }
}

public struct CoreMIDISendBoundary: MIDISendBoundary, PlannedNoteBoundary {
    private let port: MIDIPortRef
    private let endpoint: MIDIEndpointRef
    private let expectedUniqueID: Int32?
    private let ticksPerSecond: Double
    init(port: MIDIPortRef, endpoint: MIDIEndpointRef, uniqueID: Int32?) {
        self.port = port
        self.endpoint = endpoint
        expectedUniqueID = uniqueID
        var base = mach_timebase_info_data_t(); mach_timebase_info(&base)
        ticksPerSecond = 1e9 * Double(base.denom) / Double(base.numer)
    }
    public var planningLead: Double { 0 }
    public func sendPlanned(bytes: [UInt8], deadline: Double, now: Double) -> PortSendResult {
        guard let timestamp = Self.plannedTimestamp(deadline: deadline, now: now, ticksPerSecond: ticksPerSecond) else { return .faulted }
        return send(bytes: bytes, timestamp: timestamp)
    }
    static func plannedTimestamp(deadline: Double, now: Double, ticksPerSecond: Double) -> UInt64? {
        guard deadline.isFinite, now.isFinite, deadline >= 0, deadline <= now,
              ticksPerSecond.isFinite, ticksPerSecond > 0 else { return nil }
        if now > deadline { return 0 }
        let ticks = deadline * ticksPerSecond
        guard ticks >= 0, ticks < Double(UInt64.max) else { return nil }
        return UInt64(ticks.rounded())
    }
    public func cancelPlanned(bytes: [UInt8], deadline: Double, now: Double) -> PortSendResult { send(bytes: bytes) }
    public func send(bytes: [UInt8]) -> PortSendResult { send(bytes: bytes, timestamp: 0) }
    private func send(bytes: [UInt8], timestamp: MIDITimeStamp) -> PortSendResult {
        guard endpoint != 0 else { return .unbound }
        guard !bytes.isEmpty else { return .faulted }
        // A removed endpoint cannot silently turn into a virtual-only success.
        if let expectedUniqueID {
            var uniqueID: Int32 = 0
            guard port != 0, MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uniqueID) == noErr,
                  uniqueID == expectedUniqueID else { return .unbound }
        }
        var packets = MIDIPacketList()
        let first = MIDIPacketListInit(&packets)
        let added = bytes.withUnsafeBufferPointer {
            MIDIPacketListAdd(&packets, MemoryLayout<MIDIPacketList>.size,
                             first, timestamp, $0.count, $0.baseAddress!)
        }
        guard Int(bitPattern: added) != 0 else { return .faulted }
        let result = expectedUniqueID == nil ? MIDIReceived(endpoint, &packets) : MIDISend(port, endpoint, &packets)
        return result == noErr ? .sent : .faulted
    }
}
