import CoreMIDI
import Darwin
import Foundation
import PlanariumSoundCore

/// Constructed, sent, flushed and disposed exclusively by MIDIClockDriver.q.
/// Host timestamps share Dispatch uptime's mach_absolute_time epoch. The
/// macOS-12 compile spike is recorded in the TEMPO-1 handoff.
public final class CoreMIDIClockSink: MIDIClockSink, @unchecked Sendable {
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private let endpoint: MIDIEndpointRef
    private let uniqueID: Int32
    private let ticksPerSecond: Double
    private let lossLock = NSLock()
    private var lost = false
    private init?(id: Int32) {
        var object = MIDIObjectRef(); var type = MIDIObjectType.other
        guard id != 0, MIDIObjectFindByUniqueID(id, &object, &type) == noErr, type == .destination else { return nil }
        endpoint = object; uniqueID = id
        var base = mach_timebase_info_data_t()
        guard mach_timebase_info(&base) == KERN_SUCCESS, base.numer > 0, base.denom > 0 else { return nil }
        ticksPerSecond = 1_000_000_000 * Double(base.denom) / Double(base.numer)
        guard MIDIClientCreateWithBlock("Planarium Clock" as CFString, &client, { [weak self] notification in
            guard notification.pointee.messageID == .msgObjectRemoved else { return }
            let removed = notification.withMemoryRebound(to: MIDIObjectAddRemoveNotification.self, capacity: 1) { $0.pointee.child }
            guard let self, removed == self.endpoint else { return }
            self.lossLock.lock(); self.lost = true; self.lossLock.unlock()
        }) == noErr else { return nil }
        guard MIDIOutputPortCreate(client, "Planarium Clock Out" as CFString, &port) == noErr else {
            MIDIClientDispose(client); client = 0; return nil
        }
    }
    public static func open(_ id: Int32) -> (any MIDIClockSink)? { CoreMIDIClockSink(id: id) }
    private var available: Bool {
        lossLock.lock(); let removed = lost; lossLock.unlock()
        guard !removed else { return false }
        var id: Int32 = 0
        return port != 0 && MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &id) == noErr && id == uniqueID
    }
    public func send(_ byte: UInt8, at time: Double) -> PortSendResult {
        guard available else { return .unbound }
        guard [0xf8, 0xfa, 0xfc].contains(byte), let ticks = Self.timestamp(for: time, ticksPerSecond: ticksPerSecond) else { return .faulted }
        var packets = MIDIPacketList(); let first = MIDIPacketListInit(&packets)
        var value = byte
        let added = MIDIPacketListAdd(&packets, MemoryLayout<MIDIPacketList>.size, first, ticks, 1, &value)
        guard Int(bitPattern: added) != 0 else { return .faulted }
        return MIDISend(port, endpoint, &packets) == noErr ? .sent : .faulted
    }
    public func flush() -> PortSendResult {
        guard available else { return .unbound }
        return MIDIFlushOutput(endpoint) == noErr ? .sent : .faulted
    }
    static func timestamp(for time: Double, ticksPerSecond: Double) -> UInt64? {
        let ticks = (time * ticksPerSecond).rounded()
        guard time.isFinite, time >= 0, ticksPerSecond.isFinite, ticksPerSecond > 0,
              ticks >= 0, ticks < Double(UInt64.max) else { return nil }
        return UInt64(ticks)
    }
    public func close() {
        if port != 0 { MIDIPortDispose(port) }
        if client != 0 { MIDIClientDispose(client) }
        port = 0; client = 0
    }
}
