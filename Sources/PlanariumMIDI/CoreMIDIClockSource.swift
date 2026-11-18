import CoreMIDI
import Darwin
import Foundation
import PlanariumSoundCore

/// CoreMIDI copies timestamped bytes into immutable callbacks without Main.
/// Clock mode filters realtime bytes; footswitch mode preserves channel messages.
/// The owning receiver/model disposes its source handle.
public final class CoreMIDIClockSource: MIDIClockSource, @unchecked Sendable {
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private let endpoint: MIDIEndpointRef
    private init?(id: Int32, allBytes: Bool = false, receive: @escaping @Sendable (MIDIClockPacket) -> Void, lost: @escaping @Sendable () -> Void) {
        var object = MIDIObjectRef(); var type = MIDIObjectType.other
        guard id != 0, MIDIObjectFindByUniqueID(id, &object, &type) == noErr, type == .source else { return nil }
        endpoint = object
        var base = mach_timebase_info_data_t()
        guard mach_timebase_info(&base) == KERN_SUCCESS, base.numer > 0, base.denom > 0 else { return nil }
        let secondsPerTick = Double(base.numer) / Double(base.denom) / 1_000_000_000
        let selectedEndpoint = endpoint
        guard MIDIClientCreateWithBlock("Planarium Clock Input" as CFString, &client, { notification in
            guard notification.pointee.messageID == .msgObjectRemoved else { return }
            let removed = notification.withMemoryRebound(to: MIDIObjectAddRemoveNotification.self, capacity: 1) { $0.pointee.child }
            if removed == selectedEndpoint { lost() }
        }) == noErr else { return nil }
        guard MIDIInputPortCreateWithBlock(client, "Planarium Clock In" as CFString, &port, { list, _ in
            let arrival = Double(mach_absolute_time()) * secondsPerTick
            Self.read(list, arrival: arrival, secondsPerTick: secondsPerTick, allBytes: allBytes, receive: receive)
        }) == noErr else { close(); return nil }
        guard MIDIPortConnectSource(port, endpoint, nil) == noErr else { close(); return nil }
    }
    public static func open(_ id: Int32, receive: @escaping @Sendable (MIDIClockPacket) -> Void,
                            lost: @escaping @Sendable () -> Void) -> (any MIDIClockSource)? {
        CoreMIDIClockSource(id: id, receive: receive, lost: lost)
    }
    public static func openFootswitch(_ id: Int32, receive: @escaping @Sendable (MIDIClockPacket) -> Void,
                                      lost: @escaping @Sendable () -> Void) -> (any MIDIClockSource)? {
        CoreMIDIClockSource(id: id, allBytes: true, receive: receive, lost: lost)
    }
    /// Kept independently of the selected endpoint, including while absent.
    public static func observeSources(_ changed: @escaping @Sendable () -> Void) -> RuntimeCancellation {
        let observer = ClockSourceObserver(changed)
        return RuntimeCancellation { observer.close() }
    }
    public static func sources() -> [MIDITargetDescription] {
        (0..<MIDIGetNumberOfSources()).compactMap { index in
            let endpoint = MIDIGetSource(index)
            var id: Int32 = 0
            guard endpoint != 0, MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &id) == noErr else { return nil }
            var name: Unmanaged<CFString>?
            let label: String
            if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name) == noErr, let value = name?.takeRetainedValue() { label = value as String }
            else { label = "MIDI \(id)" }
            return .init(id: id, name: label)
        }
    }
    /// Also exercised with an in-memory variable-size MIDIPacketList; copying
    /// its first fixed-size Swift tuple would truncate packets above 256 bytes.
    static func read(_ list: UnsafePointer<MIDIPacketList>, arrival: Double, secondsPerTick: Double,
                     allBytes: Bool = false, receive: (MIDIClockPacket) -> Void) {
        var packet = UnsafeRawPointer(list).advanced(by: MemoryLayout<MIDIPacketList>.offset(of: \.packet)!).assumingMemoryBound(to: MIDIPacket.self)
        for _ in 0..<list.pointee.numPackets {
            let bytes = UnsafeRawBufferPointer(start: UnsafeRawPointer(packet).advanced(by: MemoryLayout<MIDIPacket>.offset(of: \.data)!), count: Int(packet.pointee.length))
            let realtime = allBytes ? Array(bytes) : bytes.filter { $0 == 0xf8 || $0 == 0xfa || $0 == 0xfb || $0 == 0xfc }
            if !realtime.isEmpty {
                receive(.init(bytes: realtime, timestamp: Double(packet.pointee.timeStamp) * secondsPerTick, arrival: arrival))
            }
            packet = UnsafePointer(MIDIPacketNext(packet))
        }
    }
    public func close() {
        if port != 0 { MIDIPortDisconnectSource(port, endpoint); MIDIPortDispose(port) }
        if client != 0 { MIDIClientDispose(client) }
        port = 0; client = 0
    }
}

/// Receiver Q serializes construction/cancellation. CoreMIDI only invokes the
/// immutable callback; disposal is protected against repeated cancellation.
private final class ClockSourceObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var client = MIDIClientRef()
    init(_ changed: @escaping @Sendable () -> Void) {
        _ = MIDIClientCreateWithBlock("Planarium Clock Sources" as CFString, &client) { notification in
            if notification.pointee.messageID == .msgObjectAdded { changed() }
        }
    }
    func close() {
        lock.lock(); let old = client; client = 0; lock.unlock()
        if old != 0 { MIDIClientDispose(old) }
    }
    deinit { close() }
}
