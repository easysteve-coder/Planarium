import Foundation
import PLSDeviceValues

/// A routing's immutable value preparation. Geometry-dependent values are
/// reduced to one projection extent per tick; runtime evaluation only touches
/// the selected routing and active cell.
internal struct CompiledValuePlan: Equatable, Sendable {
    let program: SpatialValueProgram
    let minimumProjectionByTick: [Double]
    let maximumProjectionByTick: [Double]
    let minimumProjection: Double
    let maximumProjection: Double
    let directionSin: Double
    let directionCos: Double
    let allowedNotes: [Int]

    init(program: SpatialValueProgram, cells: [PolarDeviceLattice]) {
        self.program = program
        let direction: Double
        switch program {
        case .continuous(_, _, let degrees, _),
             .scale(_, _, _, _, let degrees, _, _): direction = degrees
        case .randomScale: direction = 0
        case .constant, .chord, .singleNote, .programChange: direction = 0
        }
        let radians = direction * .pi / 180
        directionSin = sin(radians)
        directionCos = cos(radians)

        var minimums = Array(repeating: Double.infinity, count: PolarDeviceLattice.maxTick + 1)
        var maximums = Array(repeating: -Double.infinity, count: PolarDeviceLattice.maxTick + 1)
        for cell in cells {
            let bearing = (-90 + 0.5 * Double(cell.sector)) * .pi / 180
            let coefficient = sin(bearing) * directionCos + cos(bearing) * directionSin
            let projection = Double(cell.ring) * coefficient
            minimums[cell.sector] = min(minimums[cell.sector], projection)
            maximums[cell.sector] = max(maximums[cell.sector], projection)
        }
        minimumProjectionByTick = minimums
        maximumProjectionByTick = maximums
        minimumProjection = minimums.filter(\.isFinite).min() ?? 0
        maximumProjection = maximums.filter(\.isFinite).max() ?? 0

        switch program {
        case let .scale(root, low, high, scale, _, _, _),
             let .randomScale(root, low, high, scale, _, _):
            let lower = min(max(min(low, high), 0), 127)
            let upper = min(max(max(low, high), 0), 127)
            let pitchClasses = Set(scale.semitoneOffsets.map { (($0 + root) % 12 + 12) % 12 })
            allowedNotes = Array(lower...upper).filter {
                pitchClasses.contains(($0 % 12 + 12) % 12)
            }
        default:
            allowedNotes = []
        }
    }

    func value(
        activeCell: PolarDeviceLattice?,
        candidateDistanceCentimeters: Double?
    ) -> SpatialEvaluatedValue {
        let hasActiveCell = activeCell != nil
        switch program {
        case .programChange(let selection): return hasActiveCell ? .programChange(selection) : .inactive
        case .constant(let value):
            return hasActiveCell ? .scalar(value) : .inactive
        case let .singleNote(note, velocity, transition):
            return .notes(hasActiveCell ? [.init(number: UInt8(clamping: note), velocity: velocity)] : [], transition: transition)
        case let .chord(notes, velocity, transition):
            let result = hasActiveCell ? notes.map {
                SpatialPlayedNote(number: UInt8(clamping: min(max($0, 0), 127)), velocity: velocity)
            } : []
            return .notes(Set(result), transition: transition)
        case .scale(_, _, _, _, _, let ascending, let transition):
            guard let activeCell else { return .notes([], transition: transition) }
            return .notes([SpatialPlayedNote(number: UInt8(clamping: note(
                fraction: fraction(for: activeCell, distance: nil), ascending: ascending
            )), velocity: 100)], transition: transition)
        case .randomScale(let root, _, _, _, let seed, let transition):
            guard let activeCell else { return .notes([], transition: transition) }
            let note = allowedNotes.isEmpty
                ? min(max(root, 0), 127)
                : allowedNotes[Int(deterministicHash(seed: seed, cell: activeCell)
                                   % UInt64(allowedNotes.count))]
            return .notes([SpatialPlayedNote(number: UInt8(clamping: note), velocity: 100)], transition: transition)
        case let .continuous(minimum, maximum, _, curve):
            guard let activeCell else { return .inactive }
            let fraction = fraction(for: activeCell, distance: candidateDistanceCentimeters)
            let shaped: Double
            switch curve {
            case .linear: shaped = fraction
            case .easeIn: shaped = fraction * fraction
            case .easeOut: shaped = 1 - pow(1 - fraction, 2)
            }
            return .scalar(minimum + (maximum - minimum) * shaped)
        }
    }

    func fraction(for cell: PolarDeviceLattice, distance: Double?) -> Double {
        let radius = distance ?? Double(cell.ring)
        let bearing = (-90 + 0.5 * Double(cell.sector)) * .pi / 180
        let projection = radius * (sin(bearing) * directionCos + cos(bearing) * directionSin)
        guard maximumProjection > minimumProjection else { return 0 }
        return min(max((projection - minimumProjection) / (maximumProjection - minimumProjection), 0), 1)
    }

    private func note(fraction: Double, ascending: Bool) -> Int {
        guard !allowedNotes.isEmpty else { return 0 }
        let adjusted = ascending ? fraction : 1 - fraction
        return allowedNotes[min(Int((adjusted * Double(allowedNotes.count)).rounded(.down)), allowedNotes.count - 1)]
    }

    private func deterministicHash(seed: UInt64, cell: PolarDeviceLattice) -> UInt64 {
        var value = seed ^ UInt64(cell.sector) &* 0x9E3779B97F4A7C15
        value ^= UInt64(cell.ring) &* 0xBF58476D1CE4E5B9
        value ^= value >> 30; value &*= 0xBF58476D1CE4E5B9
        value ^= value >> 27; value &*= 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
}
