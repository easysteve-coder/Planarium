import Foundation

/// The control axis of a surface with a CC or scale assignment: the direction in which the value
/// (or the pitch) rises. It lives in the routing's `directionDegrees`; for a shaped surface that
/// angle is measured in the surface's own frame, so the axis follows every move, turn and
/// mirror of the surface without any program being rewritten. This is the one place that
/// converts between the frames and between the two angle conventions.
///
/// Conventions
/// - Program angle `d`: mathematical angle from +x, counter-clockwise (0 = right, 90 = front).
///   The projection of a cell is x·cos d + y·sin d (see CompiledValuePlan).
/// - Bearing `β`: 0° front, + right (the scanner's convention). `d = 90 − β`.
/// - Surface placement: mirror the local x, then rotate counter-clockwise, then move.
public enum SurfaceAxis {
    /// Program angle for a bearing. 0° front → 90, 90° right → 0, -90° left → 180, 180° back → -90.
    public static func programDegrees(fromBearing bearing: Double) -> Double { normalized(90 - bearing) }
    public static func bearing(fromProgramDegrees degrees: Double) -> Double { normalized(90 - degrees) }

    /// Maps into (-180, 180]. A value already inside is returned bit for bit.
    public static func normalized(_ degrees: Double) -> Double {
        guard degrees.isFinite, !(degrees > -180 && degrees <= 180) else { return degrees }
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 } else if value <= -180 { value += 360 }
        return value
    }

    /// World angle of a local angle: v_w = R(rotation)·M·v_l, so `a_w = (mirror ? 180 − a : a) + rotation`.
    public static func worldDegrees(local angle: Double, transform: SurfaceTransform) -> Double {
        normalized((transform.mirrorX ? 180 - angle : angle) + transform.rotationDegrees)
    }
    /// Inverse of `worldDegrees`, used when the axis is dragged in the world.
    public static func localDegrees(world angle: Double, transform: SurfaceTransform) -> Double {
        let turned = angle - transform.rotationDegrees
        return normalized(transform.mirrorX ? 180 - turned : turned)
    }

    /// The program's own angle, if the program has a spatial course.
    public static func directionDegrees(of program: SpatialValueProgram) -> Double? {
        switch program {
        case .continuous(_, _, let degrees, _), .scale(_, _, _, _, let degrees, _, _): return degrees
        case .constant, .randomScale, .chord, .singleNote, .programChange: return nil
        }
    }

    public static func replacingDirection(of program: SpatialValueProgram, with degrees: Double) -> SpatialValueProgram {
        switch program {
        case let .continuous(minimum, maximum, _, curve):
            return .continuous(minimum: minimum, maximum: maximum, directionDegrees: degrees, curve: curve)
        case let .scale(root, low, high, scale, _, ascending, transition):
            return .scale(rootMIDINote: root, lowestMIDINote: low, highestMIDINote: high, scale: scale,
                          directionDegrees: degrees, ascending: ascending, transition: transition)
        default: return program
        }
    }

    /// Swaps the end that is low and the end that is high. A CC turns by half a turn; a scale flips `ascending`.
    public static func reversed(_ program: SpatialValueProgram) -> SpatialValueProgram {
        switch program {
        case let .continuous(minimum, maximum, degrees, curve):
            return .continuous(minimum: minimum, maximum: maximum, directionDegrees: degrees > 0 ? degrees - 180 : degrees + 180, curve: curve)
        case let .scale(root, low, high, scale, degrees, ascending, transition):
            return .scale(rootMIDINote: root, lowestMIDINote: low, highestMIDINote: high, scale: scale,
                          directionDegrees: degrees, ascending: !ascending, transition: transition)
        default: return program
        }
    }

    /// The program as the runtime must see it: the local angle replaced by its world angle.
    public static func worldProgram(_ program: SpatialValueProgram, transform: SurfaceTransform) -> SpatialValueProgram {
        guard let local = directionDegrees(of: program) else { return program }
        return replacingDirection(of: program, with: worldDegrees(local: local, transform: transform))
    }

    /// True when the value or the note rises against the program's own angle: a CC whose
    /// maximum lies below its minimum, a scale that does not ascend. The arrow then points half a
    /// turn away from `directionDegrees`.
    public static func risesAgainstDirection(_ program: SpatialValueProgram) -> Bool {
        switch program {
        case .continuous(let minimum, let maximum, _, _): return maximum < minimum
        case .scale(_, _, _, _, _, let ascending, _): return !ascending
        default: return false
        }
    }

    /// Direction the arrow points to, toward the higher value or the higher note (world frame).
    public static func arrowDegrees(of program: SpatialValueProgram) -> Double? {
        guard let degrees = directionDegrees(of: program) else { return nil }
        return risesAgainstDirection(program) ? normalized(degrees + 180) : degrees
    }
}

extension SpatialValueCurve {
    /// The curve seen from the other end of the course: c'(g) = 1 − c(1 − g).
    var mirrored: SpatialValueCurve {
        switch self {
        case .linear: return .linear
        case .easeIn: return .easeOut
        case .easeOut: return .easeIn
        }
    }
}
