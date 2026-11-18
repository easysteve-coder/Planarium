import Foundation
import PlanariumMusicCore

/// Q-owned musical cursor. Its deadlines are converted to absolute samples
/// by the AU boundary; wakeup time is never used as the output timestamp.
package struct ArpeggioProducer {
    package struct Input: Equatable {
        package let channel: UInt8
        package let note: SpatialPlayedNote
        package init(channel: UInt8, note: SpatialPlayedNote) { self.channel = channel; self.note = note }
    }
    package init() {}
    package var inputs: [Input] = []
    package var next: Double?
    package var index = 0
    package var random: UInt64 = 0x617270
    package var immediate = false
    package var plannedTempo = 120.0
    package var lastPlanned: Double?
    package var plannedRate: ArpeggiatorEffect.Rate?
    package var lastSwingFactor = 1.0
    package mutating func modulateRate(_ rate: ArpeggiatorEffect.Rate, tempo: Double, notBefore now: Double) {
        if let plannedRate, rate != plannedRate {
            if let lastPlanned {
                let interval = rate.beats * 60 / tempo * lastSwingFactor
                let deadline = lastPlanned + interval
                // Keep the phase without replaying elapsed grid points.
                next = deadline + max(0, ceil((now - deadline) / interval)) * interval
            } else {
                // Nothing has reached the ring: update() may align the
                // pending first Sync step to the new grid.
                next = nil
            }
        }
        plannedRate = rate
    }
    package mutating func retime(tempo: Double, changedAt time: Double) {
        if let deadline = next, tempo != plannedTempo {
            next = time + (deadline - time) * plannedTempo / tempo
        }
        plannedTempo = tempo
    }

    package mutating func update(_ sounding: [Input], at now: Double, effect: ArpeggiatorEffect, beat: Double, tempo: Double) {
        let retained = inputs.filter { sounding.contains($0) }
        inputs = retained + sounding.filter { !retained.contains($0) }
        if inputs.isEmpty { next = nil; lastPlanned = nil; plannedRate = nil; index = 0; return }
        if next == nil {
            let rawRemainder = beat.truncatingRemainder(dividingBy: effect.rate.beats)
            let remainder = rawRemainder < 0 ? rawRemainder + effect.rate.beats : rawRemainder
            let wait = effect.syncToBeat ? (effect.rate.beats - remainder) * 60 / tempo : 0
            next = now + wait
            immediate = !effect.syncToBeat
            index = 0
            plannedTempo = tempo
            plannedRate = effect.rate
        }
    }
    package mutating func step(effect: ArpeggiatorEffect, tempo: Double) -> (Input, Double, Double, Bool)? {
        guard let deadline = next, !inputs.isEmpty else { return nil }
        var tones: [Input] = []
        for octave in 0..<effect.octaves {
            for input in inputs where Int(input.note.number) + octave * 12 <= 127 {
                tones.append(.init(channel: input.channel, note: .init(number: input.note.number + UInt8(octave * 12), velocity: input.note.velocity)))
            }
        }
        guard !tones.isEmpty else { return nil }
        if effect.direction != .asPlayed { tones.sort { ($0.note.number, $0.channel) < ($1.note.number, $1.channel) } }
        let cursor: Int
        switch effect.direction {
        case .up, .asPlayed: cursor = index % tones.count
        case .down: cursor = tones.count - 1 - index % tones.count
        case .upDown:
            let period = max(1, tones.count * 2 - 2), phase = index % period
            cursor = phase < tones.count ? phase : period - phase
        case .random:
            random = random &* 6364136223846793005 &+ 1
            cursor = Int((random >> 32) % UInt64(tones.count))
        }
        let selected = tones[cursor]
        let output = Input(channel: selected.channel, note: .init(number: selected.note.number,
            velocity: effect.velocity == 0 ? selected.note.velocity : UInt8(effect.velocity)))
        let straight = effect.rate == .quarter || effect.rate == .eighth || effect.rate == .sixteenth || effect.rate == .thirtySecond
        let swing = straight ? effect.swing / 100 : 0
        let duration = effect.rate.beats * 60 / tempo * (index % 2 == 0 ? 1 + swing : 1 - swing)
        let first = immediate; immediate = false
        lastPlanned = deadline; plannedRate = effect.rate
        lastSwingFactor = index % 2 == 0 ? 1 + swing : 1 - swing
        next = deadline + duration; index += 1
        return (output, deadline, deadline + duration * effect.gate / 100, first)
    }
}
