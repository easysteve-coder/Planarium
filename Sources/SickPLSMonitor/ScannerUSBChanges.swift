import Foundation
import IOKit
import IOKit.serial

@MainActor protocol ScannerUSBChangeWatching: AnyObject {
    func start(_ changed: @escaping @MainActor @Sendable () -> Void) -> Bool
    func stop()
}

/// IOKit lists BSD serial services without opening any port. Registration,
/// callbacks and destruction are serialized on a private queue. Destroying the
/// port precedes releasing its callback context; callbacks never wait on Main.
final class ScannerUSBChanges: ScannerUSBChangeWatching {
    private final class Context: @unchecked Sendable {
        let changed: @MainActor @Sendable () -> Void
        init(_ changed: @escaping @MainActor @Sendable () -> Void) { self.changed = changed }
        func drain(_ iterator: io_iterator_t, notify: Bool) {
            while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
            if notify { DispatchQueue.main.async(execute: changed) }
        }
    }
    private final class Resources: @unchecked Sendable {
        let queue = DispatchQueue(label: "de.planarium.serial-notifications", qos: .utility)
        var port: IONotificationPortRef?
        var iterators: [io_iterator_t] = []
        var context: Context?
        func close() {
            if let port { IONotificationPortDestroy(port) }
            port = nil
            iterators.forEach { IOObjectRelease($0) }; iterators.removeAll()
            context = nil
        }
        deinit { queue.sync { close() } }
    }
    private let resources = Resources()
    @MainActor func start(_ changed: @escaping @MainActor @Sendable () -> Void) -> Bool {
        let context = Context(changed)
        return resources.queue.sync { [resources] in
            resources.close()
            guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return false }
            resources.port = port; resources.context = context
            IONotificationPortSetDispatchQueue(port, resources.queue)
            for name in [kIOFirstMatchNotification, kIOTerminatedNotification] {
                var iterator: io_iterator_t = 0
                let result = IOServiceAddMatchingNotification(port, name, IOServiceMatching(kIOSerialBSDServiceValue), { raw, iterator in
                    guard let raw else { return }
                    Unmanaged<Context>.fromOpaque(raw).takeUnretainedValue().drain(iterator, notify: true)
                }, Unmanaged.passUnretained(context).toOpaque(), &iterator)
                guard result == KERN_SUCCESS else { resources.close(); return false }
                resources.iterators.append(iterator)
                context.drain(iterator, notify: false) // Arm; initial listing belongs to start().
            }
            return true
        }
    }
    @MainActor func stop() { resources.queue.sync { [resources] in resources.close() } }
}
