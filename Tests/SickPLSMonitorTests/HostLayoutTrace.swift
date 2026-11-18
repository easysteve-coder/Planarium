import AppKit
import ObjectiveC

/// Diagnostic only (SICK_LAYOUT_TRACE=1): counts `layout` per view class found
/// in a mounted hierarchy (classes implementing their own `layout`).
enum HostLayoutTrace {
    nonisolated(unsafe) static var counts: [String: Int] = [:]
    nonisolated(unsafe) private static var swizzled: Set<ObjectIdentifier> = []
    @MainActor static func install(in root: NSView) {
        var classes: [AnyClass] = []
        func walk(_ view: NSView) {
            var current: AnyClass? = type(of: view)
            while let cls = current, ObjectIdentifier(cls) != ObjectIdentifier(NSView.self) {
                if !swizzled.contains(ObjectIdentifier(cls)) { classes.append(cls); swizzled.insert(ObjectIdentifier(cls)) }
                current = class_getSuperclass(cls)
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        let selector = #selector(NSView.layout)
        for cls in classes {
            var own: UInt32 = 0
            guard let methods = class_copyMethodList(cls, &own) else { continue }
            let method = (0..<Int(own)).map { methods[$0] }.first { method_getName($0) == selector }
            free(methods)
            guard let method else { continue }
            let name = String(cString: class_getName(cls))
            typealias Fn = @convention(c) (AnyObject, Selector) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Fn.self)
            let block: @convention(block) (AnyObject) -> Void = { object in
                counts[name, default: 0] += 1
                original(object, selector)
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
    }
}
