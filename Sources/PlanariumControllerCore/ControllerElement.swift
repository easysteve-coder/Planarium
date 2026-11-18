import Foundation

/// One physical input of a game controller. The cases follow the PS5 DualSense;
/// other gamepads map their own buttons onto the same roles.
public enum ControllerElement: String, Codable, CaseIterable, Hashable, Sendable, Comparable {
    case cross, circle, square, triangle
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case l1, r1, l2, r2, l3, r3
    case create, options, home, touchpadButton
    case leftStick, rightStick, touchpad

    public enum Kind: Sendable, Equatable { case button, trigger, stick, surface }

    public var kind: Kind {
        switch self {
        case .l2, .r2: return .trigger
        case .leftStick, .rightStick: return .stick
        case .touchpad: return .surface
        default: return .button
        }
    }

    /// A two-dimensional element (stick, touch surface) can be divided into sectors.
    public var isPositional: Bool { kind == .stick || kind == .surface }

    /// Short English name for the interface.
    public var displayName: String {
        switch self {
        case .cross: return "Cross"
        case .circle: return "Circle"
        case .square: return "Square"
        case .triangle: return "Triangle"
        case .dpadUp: return "D-pad up"
        case .dpadDown: return "D-pad down"
        case .dpadLeft: return "D-pad left"
        case .dpadRight: return "D-pad right"
        case .l1: return "L1"
        case .r1: return "R1"
        case .l2: return "L2"
        case .r2: return "R2"
        case .l3: return "L3"
        case .r3: return "R3"
        case .create: return "Create"
        case .options: return "Options"
        case .home: return "Home"
        case .touchpadButton: return "Touchpad click"
        case .leftStick: return "Left stick"
        case .rightStick: return "Right stick"
        case .touchpad: return "Touchpad"
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// A position on a stick or the touchpad, normalized to -1…1, y up.
public struct ControllerPoint: Equatable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x.isFinite ? min(max(x, -1), 1) : 0
        self.y = y.isFinite ? min(max(y, -1), 1) : 0
    }
    public static let center = ControllerPoint(x: 0, y: 0)
    public var magnitude: Double { min(1, hypot(x, y)) }
    /// Clockwise bearing from straight up, 0..<360.
    public var bearingDegrees: Double {
        let degrees = atan2(x, y) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }
}

/// The complete, normalized state of one controller at one instant. A report
/// is applied as a whole, so a stick's x and y never come from two reports.
public struct ControllerState: Equatable, Sendable {
    public var pressed: Set<ControllerElement>
    /// Analog triggers 0…1.
    public var values: [ControllerElement: Double]
    /// Sticks and touch surface; a touch surface without contact has no entry.
    public var positions: [ControllerElement: ControllerPoint]

    public init(pressed: Set<ControllerElement> = [], values: [ControllerElement: Double] = [:],
                positions: [ControllerElement: ControllerPoint] = [:]) {
        self.pressed = pressed.filter { $0.kind == .button }
        self.values = values.filter { $0.key.kind == .trigger }.mapValues { $0.isFinite ? min(max($0, 0), 1) : 0 }
        self.positions = positions.filter { $0.key.isPositional }
    }

    public static let neutral = ControllerState()

    public func value(_ element: ControllerElement) -> Double { values[element] ?? 0 }
    public func position(_ element: ControllerElement) -> ControllerPoint? { positions[element] }

    /// Merges a second input (the on-screen simulation) into a measured state:
    /// buttons add, triggers take the larger value, a simulated position wins.
    public func merging(_ other: ControllerState) -> ControllerState {
        var result = self
        result.pressed.formUnion(other.pressed)
        for (element, value) in other.values { result.values[element] = max(result.values[element] ?? 0, value) }
        for (element, point) in other.positions { result.positions[element] = point }
        return result
    }
}

/// What a controller source reports to the runtime, in its own order.
public enum ControllerInputEvent: Sendable, Equatable {
    /// A controller became the source's device. A fresh session id per connection.
    case connected(session: UUID, name: String)
    /// Complete state after one report. `sequence` grows within a session.
    case state(session: UUID, sequence: UInt64, time: Double, ControllerState)
    /// The device left; only this source's outputs are released.
    case disconnected(session: UUID)
}
