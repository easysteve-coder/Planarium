import Foundation
import PlanariumAudio
import PlanariumInput
import PlanariumMIDI
import PlanariumRuntime

/// Public diagnostics admit typed numbers and fixed vocabulary only. Foreign
/// names, paths, error descriptions, raw profiles and plugin state never enter.
struct DiagnosticSnapshot {
    let time: Double
    let sessionID: UUID?
    let inputStatus: String
    let baudRate: Int?
    let points: Int?
    let unsupported: UInt64
    let rejectedPoints: Int?
    let rejectedPartial: UInt8?
    let validFrames: Int
    let crcErrors: Int
    let parserRejected: Int
    let parserOversize: Int
    let parserAtFinish: Int
    let noiseBytes: Int
    let inputRate: Double?
    let profileAge: Double?
    let partialIndex: UInt8?
    let trailingByteCount: Int?
    let displaySkipped: Int
    let inputBatches: Int
    let readsWithSeveralProfiles: Int
    let runtime: RuntimeDiagnostics
    let ports: [OutputPortDisplay]
    let retiredPort: OutputPortDisplay?
    let unconfirmed: [UnconfirmedNoteOff]
    let audioRunning: Bool
    let audioFaulted: Bool
    let sampleRate: Double
    let midiRunning: Bool
    let midiFaulted: Bool
    let slotStates: [String]
    var auChannelNumbers: [UUID: Int] = [:]

    @MainActor static func read(input: InputOwner, runtime: PerformanceRuntime,
                               host: AudioHost, midi: MIDIPortOwner) -> Self {
        let state = input.session.state
        let status = DiagnosticInputPresentation.status(state.connection)
        let baud: Int?
        switch state.connection {
        case .connecting(_, let rate), .connected(_, let rate): baud = Int(rate.rawValue)
        default: baud = nil
        }
        let frame = runtime.mailbox.read()
        func slot(_ value: ChannelSlotStatus?) -> String {
            switch value {
            case .loading: return "loading"
            case .loaded: return "loaded"
            case .bypass: return "bypassed"
            case .failed: return "failed"
            case nil: return "unloaded"
            }
        }
        var value = Self(time: runtime.diagnosticTime, sessionID: input.session.sessionID,
            inputStatus: status, baudRate: baud, points: state.profileGeometry.geometry?.pointCount,
            unsupported: state.profileGeometry.unsupportedProfiles,
            rejectedPoints: state.profileGeometry.rejectedPointCount,
            rejectedPartial: state.profileGeometry.rejectedPartialScanIndex,
            validFrames: state.diagnostics.validFrames,
            crcErrors: state.diagnostics.discardedCandidatesChecksumMismatch,
            parserRejected: state.diagnostics.discardedCandidates,
            parserOversize: state.diagnostics.discardedCandidatesOversize,
            parserAtFinish: state.diagnostics.discardedCandidatesAtFinish,
            noiseBytes: state.diagnostics.skippedNoiseBytes,
            inputRate: state.profileRateHz,
            profileAge: state.lastProfileReceivedAt.map { max(0, Date().timeIntervalSince($0)) },
            partialIndex: state.lastProfile?.partialScanIndex,
            trailingByteCount: state.lastProfile?.trailingBytes.count,
            displaySkipped: state.skippedProfiles,
            inputBatches: input.session.deliveredProfileBatches, readsWithSeveralProfiles: input.session.readsWithSeveralProfiles,
            runtime: runtime.diagnostics, ports: frame?.ports ?? [], retiredPort: frame?.retiredPort,
            unconfirmed: runtime.unconfirmedNoteOffs,
            audioRunning: host.isRunning, audioFaulted: host.graphFailure != nil,
            sampleRate: host.configuration.sampleRate, midiRunning: midi.isRunning, midiFaulted: midi.notice != nil,
            slotStates: ["Instrument: " + slot(host.status[.instrument])] + host.channel.inserts.enumerated().map {
                "Insert \($0.offset + 1): " + slot(host.status[.insert($0.element.id)])
            })
        value.auChannelNumbers = Dictionary(uniqueKeysWithValues: host.mixerChannels.enumerated().map { ($0.element.id, $0.offset + 1) })
        if value.auChannelNumbers.isEmpty { value.auChannelNumbers[host.channel.id] = 1 }
        return value
    }
    var lines: [String] {
        var values = ["Input: \(inputStatus)",
            "Baud rate: \(baudRate.map(String.init) ?? "not applicable")",
            "Points per profile: \(points.map(String.init) ?? "unavailable")",
            "RX valid frames / CRC errors / rejected candidates: \(validFrames) / \(crcErrors) / \(parserRejected)",
            "RX oversize / discarded at finish / skipped noise bytes: \(parserOversize) / \(parserAtFinish) / \(noiseBytes)",
            "Input rate: \(inputRate.map { String(format: "%.2f Hz", $0) } ?? "unavailable") · last profile age: \(profileAge.map { String(format: "%.2f s", $0) } ?? "unavailable")",
            "Partial scan / trailing byte count: \(partialIndex.map(String.init) ?? "unavailable") / \(trailingByteCount.map(String.init) ?? "unavailable")",
            "Input status batches / reads with several profiles: \(inputBatches) / \(readsWithSeveralProfiles)",
            "Display skipped profiles: \(displaySkipped)", "Unsupported profiles: \(unsupported)",
            "Profiles / excluded / overflows: \(runtime.processedProfiles) / \(runtime.discardedProfiles) / \(runtime.overflowProfiles)",
            "Audio: \(audioRunning ? "running" : "stopped") · graph \(audioFaulted ? "failed" : "ready") · \(Int(sampleRate)) Hz",
            "MIDI: \(midiRunning ? "bound" : "unbound") · \(midiFaulted ? "failed" : "ready")"] + slotStates
        if let rejectedPoints, let rejectedPartial {
            values.append("Rejected geometry: \(rejectedPoints) points · partial scan \(rejectedPartial)")
        }
        values += ports.enumerated().map { index, port in
            let output = port.destination.stripID.flatMap { auChannelNumbers[$0] }.map { "AU Ch \($0)" } ?? String(describing: port.destination)
            return "Port \(index + 1) (\(output)): \(port.result) · sent \(port.counts.sent) · failed \(port.counts.faulted) · unbound \(port.counts.unbound) · CC \(port.sentCC) · PC \(port.sentPC) · held notes \(port.soundingNotes)"
        }
        if let port = retiredPort {
            values.append("Retired port (\(port.destination)): sent \(port.counts.sent) · failed \(port.counts.faulted) · unbound \(port.counts.unbound)")
        }
        values.append("Unconfirmed Note-Offs: \(unconfirmed.count)")
        values += unconfirmed.map {
            "Unconfirmed Note-Off: port=\($0.portID.uuidString) · \($0.destination) · channel=\($0.channel) · note=\($0.note)"
        }
        return values
    }
}

struct DiagnosticMeasurementWindow {
    let begin: DiagnosticSnapshot
    let end: DiagnosticSnapshot
    let interrupted: Bool
    var lines: [String] {
        let profiles = end.runtime.profileTimings.filter {
            $0.ordinal > begin.runtime.profileTimingCount && $0.ordinal <= end.runtime.profileTimingCount &&
            $0.requestedAt >= begin.time && $0.completedAt <= end.time
        }
        let panics = end.runtime.panicTimings.filter {
            $0.ordinal > begin.runtime.panicTimingCount && $0.ordinal <= end.runtime.panicTimingCount &&
            $0.requestedAt >= begin.time && $0.completedAt <= end.time
        }
        let pads = end.runtime.controllerAggregate.since(begin.runtime.controllerAggregate)
        let reset = begin.sessionID != end.sessionID
        var lines = ["Completed measurement window\(interrupted || reset ? " (interrupted)" : "")",
            String(format: "Duration: %.2f s", max(0, end.time - begin.time)),
            "Profiles / excluded / overflows: \(end.runtime.processedProfiles - begin.runtime.processedProfiles) / \(end.runtime.discardedProfiles - begin.runtime.discardedProfiles) / \(end.runtime.overflowProfiles - begin.runtime.overflowProfiles)",
            "Profile → router return: " + Self.summary(profiles.map(\.totalMilliseconds)),
            "Queue wait (includes input decode handoff): " + Self.summary(profiles.map(\.queueMilliseconds)),
            "Panic → router return: " + Self.summary(panics.map(\.totalMilliseconds)),
            "Controller reports processed / refused: \(pads.processed) / \(pads.refused)",
            "Controller report → router return (whole window): " + Self.histogramSummary(pads.latency, width: ControllerReportAggregate.latencyBinMilliseconds),
            "Controller queue wait (whole window): " + Self.histogramSummary(pads.queueWait, width: ControllerReportAggregate.latencyBinMilliseconds),
            "Controller report interval (whole window): " + Self.histogramSummary(pads.interval, width: ControllerReportAggregate.intervalBinMilliseconds),
            "Timing storage: latest 2048 samples per kind; total profile / panic samples \(end.runtime.profileTimingCount) / \(end.runtime.panicTimingCount); controller figures count every report"]
        let duration = end.time - begin.time
        if duration > 0 {
            lines.append(String(format: "Processed profile rate: %.2f Hz", Double(end.runtime.processedProfiles - begin.runtime.processedProfiles) / duration))
            lines.append(String(format: "Controller report rate (processed): %.2f Hz", Double(pads.processed) / duration))
        }
        for (index, port) in end.ports.enumerated() {
            let old = begin.ports.first { $0.id == port.id }
            lines.append("Window port \(index + 1) (\(port.destination)) sent / failed / unbound: \(port.counts.sent - (old?.counts.sent ?? 0)) / \(port.counts.faulted - (old?.counts.faulted ?? 0)) / \(port.counts.unbound - (old?.counts.unbound ?? 0))")
        }
        if reset { lines.append("RX counters: unavailable across an input session change") }
        else {
            lines.append("RX valid frames / CRC errors / rejected candidates: \(max(0, end.validFrames - begin.validFrames)) / \(max(0, end.crcErrors - begin.crcErrors)) / \(max(0, end.parserRejected - begin.parserRejected))")
            lines.append("RX oversize / discarded at finish / skipped noise bytes: \(max(0, end.parserOversize - begin.parserOversize)) / \(max(0, end.parserAtFinish - begin.parserAtFinish)) / \(max(0, end.noiseBytes - begin.noiseBytes))")
        }
        if end.runtime.profileTimingCount - begin.runtime.profileTimingCount > UInt64(profiles.count) || end.runtime.panicTimingCount - begin.runtime.panicTimingCount > UInt64(panics.count) {
            lines.append("Timing summary incomplete: samples outside this window or replaced in bounded storage")
        }
        return lines
    }
    /// Quantiles of a whole-window histogram, given as the upper edge of their
    /// 0.1 ms bin; the last bin is open ("> limit").
    static func histogramSummary(_ bins: [UInt64], width: Double) -> String {
        guard let q = ControllerReportAggregate.quantiles(bins, width: width) else { return "unavailable (no samples)" }
        func edge(_ value: Double, last: Bool) -> String { String(format: last ? "> %.1f" : "≤ %.1f", value) }
        let limit = Double(bins.count - 1) * width
        func shown(_ value: Double) -> String { edge(value, last: value >= limit && q.openEnded) }
        return "n \(q.count) · p50 \(shown(q.p50)) · p95 \(shown(q.p95)) · p99 \(shown(q.p99)) · max \(shown(q.max)) ms (\(width < 1 ? "0.1" : "1") ms bins)"
    }
    static func summary(_ samples: [Double]) -> String {
        let values = samples.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard !values.isEmpty else { return "unavailable (no samples)" }
        let median = values[(values.count - 1) / 2]
        let p95 = values[min(values.count - 1, Int(ceil(Double(values.count) * 0.95)) - 1)]
        let p99 = values[min(values.count - 1, Int(ceil(Double(values.count) * 0.99)) - 1)]
        return String(format: "n %d · p50 %.2f · p95 %.2f · p99 %.2f · max %.2f · Δ %.2f ms", values.count, median, p95, p99, values.last!, p99 - median)
    }
}
enum DiagnosticReportPresentation {
    static func copyText(_ snapshot: DiagnosticSnapshot, window: DiagnosticMeasurementWindow,
                         build: PlanariumBuildIdentity = .current) -> String {
        // Bundle fields are validated too: never trust an arbitrary string at
        // the public report boundary, even when a fixture supplies it.
        func checked(_ value: String, pattern: String) -> String {
            value.range(of: pattern, options: .regularExpression) == value.startIndex..<value.endIndex ? value : "unknown"
        }
        let version = checked(build.marketingVersion, pattern: "^[0-9]+(?:\\.[0-9]+)*$")
        let number = checked(build.buildNumber, pattern: "^[0-9]+$")
        let revision = checked(build.gitRevision, pattern: "^[0-9a-f]+(?:\\+local|\\+lokal)?$")
        return (["Version \(version) · Build \(number)", "Revision \(revision)"] + snapshot.lines + [""] + window.lines).joined(separator: "\n")
    }
}

enum DiagnosticInputPresentation {
    static func status(_ connection: ConnectionStatus) -> String {
        switch connection {
        case .disconnected: return "disconnected"
        case .connecting: return "scanner connecting"
        case .connected: return "scanner connected"
        case .simulationConnecting: return "simulation connecting"
        case .simulationConnected: return "simulation connected"
        case .failed: return "scanner failed"
        case .simulationFailed: return "simulation failed"
        }
    }
}
